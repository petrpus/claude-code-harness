#!/usr/bin/env python3
"""skills/worklog/worklog-app.py — local review-and-log page for /worklog --harvest and --clockify.

    worklog-app.py <batch.json> --from YYYY-MM-DD --to YYYY-MM-DD
                   [--service harvest|clockify] [--project ID] [--repo KEY]
                   [--task-name NAME] [--port N] [--idle-minutes N] [--open]

Serves one page on 127.0.0.1: a project select, the user's entries in the
time tracker (--service, default harvest) for that project and task in the
window, and an editable proposal per day with a button that creates or
updates the entry. Every tracker call goes through the service's script next
to this file (harvest.sh or clockify.sh, which share one command contract),
so the token stays in that script's config and never reaches this process's
responses or the page.

The batch file holds the proposals ([{date, hours, notes}]) the skill derived
from the commits; each applied row gets its entry_id written back, so a rerun
of the page shows what already went to the tracker.

Project choice: a project remembered for --repo in the service's projects map
($HARVEST_PROJECTS, default ~/.config/harvest/projects.json, or
$CLOCKIFY_PROJECTS, default ~/.config/clockify/projects.json) wins over
--project, the skill's guess from context. Changing the select remembers the
new choice for --repo.

Ids are opaque: Harvest's are integers, Clockify's 24-hex-digit strings. A
Clockify project without any task is logged without one; a project whose
tasks do not include --task-name cannot be chosen, in either service.

Guards: the server binds 127.0.0.1 only, answers only to a Host header naming
that address and port (no DNS rebinding), and every /api call must carry the
per-run key from the URL fragment in an X-Worklog-Key header — a custom header
cross-site pages cannot send without a CORS preflight this server never grants.
A create on a day that already holds an entry of the project and task is
refused unless the page says the user picked "New entry", so a stale or failed
read of the entries cannot double-log a day.

Prints the page URL as the first stdout line, then one JSON line per applied
entry. Exits when the page sends Done, or after --idle-minutes without a
request (default 45; an open page pings every minute).
"""

import argparse
import datetime as dt
import hmac
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HERE = Path(__file__).resolve().parent
PAGE = HERE / "worklog-app.html"
MAX_BODY = 1 << 20


def _harvest_id(value):
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def _clockify_id(value):
    return value.lower() if isinstance(value, str) and re.fullmatch(r"[0-9a-fA-F]{24}", value) else None


SERVICES = {
    "harvest": {
        "name": "Harvest",
        "flag": "--harvest",
        "script": HERE / "harvest.sh",
        "projects_map": Path(os.environ.get("HARVEST_PROJECTS", Path.home() / ".config/harvest/projects.json")),
        "id": _harvest_id,
        "id_text": r"[0-9]{1,15}",
        "id_from_text": int,
        # Harvest has no entry without a task.
        "task_optional": False,
        "billable": False,
    },
    "clockify": {
        "name": "Clockify",
        "flag": "--clockify",
        "script": HERE / "clockify.sh",
        "projects_map": Path(os.environ.get("CLOCKIFY_PROJECTS", Path.home() / ".config/clockify/projects.json")),
        "id": _clockify_id,
        "id_text": r"[0-9a-fA-F]{24}",
        "id_from_text": str.lower,
        # A Clockify project may have no tasks at all; its entries carry none.
        "task_optional": True,
        # Clockify does not take a project's billable default on create.
        "billable": True,
    },
}


class ServiceError(Exception):
    """The service script failed or the tracker refused → 502."""


class Conflict(Exception):
    """The request would double-log a day → 409."""


SERVICE = SERVICES["harvest"]


def service(*args):
    script = SERVICE["script"]
    proc = subprocess.run(["bash", str(script), *args], capture_output=True, text=True, encoding="utf-8")
    if proc.returncode != 0:
        raise ServiceError(proc.stderr.strip() or f"{script.name} {args[0]} exited {proc.returncode}")
    return json.loads(proc.stdout) if proc.stdout.strip() else None


def service_with_notes(args, notes):
    # Notes go through a file: they are free text of any length.
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".txt", delete=False) as f:
        f.write(notes)
        path = f.name
    try:
        return service(*args, "--notes-file", path)
    finally:
        os.unlink(path)


def read_json(path, default):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default


def write_json(path, data):
    # A unique temp name in the same directory: two servers (two repos) may
    # write the projects map at the same time.
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def read_projects_map():
    path = SERVICE["projects_map"]
    try:
        mapping = read_json(path, {})
    except ValueError:
        mapping = None
    if not isinstance(mapping, dict):
        print(f"worklog-app: ignoring unreadable {path}", file=sys.stderr, flush=True)
        return {}
    return mapping


def as_id(value):
    """A service id from JSON, normalised, or None when it is not one."""
    return SERVICE["id"](value)


def is_hours(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and 0 < value <= 24


def check_batch(batch):
    if not isinstance(batch, list) or not all(isinstance(r, dict) and isinstance(r.get("date"), str) for r in batch):
        return "must hold a JSON array of {date, hours, notes} objects"
    dates = [r["date"] for r in batch]
    if len(dates) != len(set(dates)):
        return "holds a date twice"
    return None


class App:
    def __init__(self, opts):
        self.opts = opts
        self.key = secrets.token_urlsafe(24)
        self.lock = threading.Lock()
        self.last_request = time.monotonic()
        self.done = threading.Event()
        self.projects = None

    # ------------------------------------------------------------ state ---
    def window(self):
        start = dt.date.fromisoformat(self.opts.date_from)
        end = dt.date.fromisoformat(self.opts.date_to)
        return [(start + dt.timedelta(days=i)).isoformat() for i in range((end - start).days + 1)]

    def batch(self):
        batch = read_json(self.opts.batch, [])
        problem = check_batch(batch)
        if problem:
            raise ValueError(f"{self.opts.batch} {problem}")
        return batch

    def load_projects(self):
        if self.projects is None:
            want = self.opts.task_name.casefold()
            self.projects = []
            for p in service("projects"):
                task_id = next((t["task_id"] for t in p["tasks"] if t["task"].casefold() == want), None)
                self.projects.append({
                    "project_id": as_id(p["project_id"]),
                    "label": f'{p["client"]} / {p["project"]}' if p.get("client") else p["project"],
                    "task_id": task_id,
                    "loggable": task_id is not None or (SERVICE["task_optional"] and not p["tasks"]),
                    "billable": p.get("billable"),
                })
        return self.projects

    def selected_project(self):
        ids = {p["project_id"] for p in self.load_projects() if p["loggable"]}
        remembered = read_projects_map().get(self.opts.repo) if self.opts.repo else None
        for candidate in (as_id(remembered), self.opts.project):
            if candidate is not None and candidate in ids:
                return candidate
        return None

    def state(self):
        rows = {r["date"]: r for r in self.batch()}
        return {
            "service": SERVICE["name"],
            "flag": SERVICE["flag"],
            "from": self.opts.date_from,
            "to": self.opts.date_to,
            "task_name": self.opts.task_name,
            "projects": self.load_projects(),
            "project_id": self.selected_project(),
            "rows": [
                {
                    "date": d,
                    "hours": rows.get(d, {}).get("hours"),
                    "notes": rows.get(d, {}).get("notes") or "",
                    "entry_id": rows.get(d, {}).get("entry_id"),
                }
                for d in reversed(self.window())
            ],
        }

    def project(self, project_id):
        for p in self.load_projects():
            if p["project_id"] == project_id and p["loggable"]:
                return p
        raise ValueError(f"project {project_id} has no active {self.opts.task_name} task")

    def task_for(self, project_id):
        return self.project(project_id)["task_id"]

    def entries(self, project_id):
        task_id = self.task_for(project_id)
        rows = service("entries", self.opts.date_from, self.opts.date_to, "--project", str(project_id))
        return [e for e in rows if e["task_id"] == task_id]

    # ----------------------------------------------------------- writes ---
    def remember(self, project_id):
        self.project(project_id)
        if not self.opts.repo:
            return
        with self.lock:
            mapping = read_projects_map()
            mapping[self.opts.repo] = project_id
            write_json(SERVICE["projects_map"], mapping)

    def apply(self, body):
        project_id, date, hours = as_id(body.get("project_id")), body.get("date"), body.get("hours")
        notes, raw_entry, new = body.get("notes", ""), body.get("entry_id"), body.get("new") is True
        entry_id = None if raw_entry is None else as_id(raw_entry)
        if project_id is None:
            raise ValueError(f"project_id must be a {SERVICE['name']} id")
        if date not in self.window():
            raise ValueError(f"{date} is outside the window")
        if not is_hours(hours):
            raise ValueError("hours must be a number in (0, 24]")
        if not isinstance(notes, str):
            raise ValueError("notes must be text")
        if raw_entry is not None and entry_id is None:
            raise ValueError(f"entry_id must be a {SERVICE['name']} id or null")
        # Re-read the tracker on every write: the page's copy may be stale (a
        # second tab, an entry added in the tracker meanwhile).
        existing = [as_id(e["id"]) for e in self.entries(project_id) if e["date"] == date]
        if entry_id is not None:
            if entry_id not in existing:
                raise ValueError(f"entry {entry_id} is not a {self.opts.task_name} entry of this project on {date}")
            entry = service_with_notes(["update", str(entry_id), "--hours", str(hours)], notes)
            action = "updated"
        else:
            if existing and not new:
                raise Conflict(
                    f"{date} already holds entry {', '.join(f'#{i}' for i in existing)} in {SERVICE['name']} — "
                    "reload the page, or pick “New entry” to add another one"
                )
            project = self.project(project_id)
            args = ["log", date, str(hours), "--project", str(project_id)]
            if project["task_id"] is not None:
                args += ["--task", str(project["task_id"])]
            if SERVICE["billable"] and isinstance(project["billable"], bool):
                args += ["--billable", "true" if project["billable"] else "false"]
            entry = service_with_notes(args, notes)
            action = "created"
        print(json.dumps({"action": action, "date": date, "hours": hours, "entry_id": entry["id"]}), flush=True)
        result = {"action": action, "entry": entry}
        # The tracker already holds the entry; a failed write-back must not hide that.
        try:
            with self.lock:
                batch = self.batch()
                row = next((r for r in batch if r["date"] == date), None)
                if row is None:
                    row = {"date": date}
                    batch.append(row)
                    batch.sort(key=lambda r: r["date"], reverse=True)
                row.update(hours=hours, notes=notes, entry_id=entry["id"], project_id=project_id)
                write_json(self.opts.batch, batch)
        except (OSError, ValueError) as e:
            result["warning"] = f"entry #{entry['id']} is in {SERVICE['name']}, but {self.opts.batch} was not updated: {e}"
        return result


def make_handler(app, host_ok):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, code, payload):
            data = json.dumps(payload, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.end_headers()
            self.wfile.write(data)

        def guarded(self):
            app.last_request = time.monotonic()
            if self.headers.get("Host") not in host_ok:
                self.send(403, {"error": "wrong host"})
                return False
            path = urlparse(self.path).path
            if path.startswith("/api/") and not hmac.compare_digest(
                self.headers.get("X-Worklog-Key", "").encode(), app.key.encode()
            ):
                self.send(403, {"error": "missing or wrong key"})
                return False
            return True

        def run(self, fn):
            try:
                self.send(200, fn())
            except ValueError as e:
                self.send(400, {"error": str(e)})
            except Conflict as e:
                self.send(409, {"error": str(e)})
            except ServiceError as e:
                self.send(502, {"error": str(e)})

        def do_GET(self):
            if not self.guarded():
                return
            url = urlparse(self.path)
            if url.path == "/":
                csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'"
                data = PAGE.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Content-Security-Policy", csp)
                self.send_header("Cache-Control", "no-store")
                self.send_header("Referrer-Policy", "no-referrer")
                self.end_headers()
                self.wfile.write(data)
            elif url.path == "/api/state":
                self.run(app.state)
            elif url.path == "/api/ping":
                self.send(200, {})
            elif url.path == "/api/entries":
                project = parse_qs(url.query).get("project", [""])[0]
                if not re.fullmatch(SERVICE["id_text"], project):
                    self.send(400, {"error": f"project must be a {SERVICE['name']} id"})
                    return
                self.run(lambda: app.entries(SERVICE["id_from_text"](project)))
            else:
                self.send(404, {"error": "not found"})

        def do_POST(self):
            if not self.guarded():
                return
            if self.headers.get_content_type() != "application/json":
                self.send(415, {"error": "JSON only"})
                return
            length = self.headers.get("Content-Length", "")
            if not re.fullmatch(r"[0-9]{1,8}", length) or int(length) > MAX_BODY:
                self.send(400, {"error": "missing or oversized body"})
                return
            try:
                body = json.loads(self.rfile.read(int(length)) or b"{}")
            except ValueError:
                self.send(400, {"error": "unreadable JSON"})
                return
            if not isinstance(body, dict):
                self.send(400, {"error": "expected a JSON object"})
                return
            path = urlparse(self.path).path
            if path == "/api/project":
                project_id = as_id(body.get("project_id"))
                if project_id is None:
                    self.send(400, {"error": f"project_id must be a {SERVICE['name']} id"})
                    return
                self.run(lambda: (app.remember(project_id), {"project_id": project_id})[1])
            elif path == "/api/apply":
                self.run(lambda: app.apply(body))
            elif path == "/api/done":
                self.send(200, {"done": True})
                app.done.set()
            else:
                self.send(404, {"error": "not found"})

    return Handler


def main():
    global SERVICE
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("batch")
    ap.add_argument("--from", dest="date_from", required=True)
    ap.add_argument("--to", dest="date_to", required=True)
    ap.add_argument("--service", choices=sorted(SERVICES), default="harvest")
    ap.add_argument("--project")
    ap.add_argument("--repo", default="")
    ap.add_argument("--task-name", default="Programming")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--idle-minutes", type=float, default=45)
    ap.add_argument("--open", action="store_true", help="open the page in the default browser")
    opts = ap.parse_args()
    try:
        start = dt.date.fromisoformat(opts.date_from)
        end = dt.date.fromisoformat(opts.date_to)
    except ValueError:
        ap.error("--from and --to must be YYYY-MM-DD")
    if end < start or (end - start).days > 62:
        ap.error("the window must run forward and span at most 63 days")
    SERVICE = SERVICES[opts.service]
    if opts.project is not None:
        if not re.fullmatch(SERVICE["id_text"], opts.project):
            ap.error(f"--project must be a {SERVICE['name']} id")
        opts.project = SERVICE["id_from_text"](opts.project)
    try:
        problem = check_batch(read_json(opts.batch, []))
    except ValueError:
        problem = "is not valid JSON"
    if problem:
        ap.error(f"{opts.batch} {problem}")

    app = App(opts)
    server = ThreadingHTTPServer(("127.0.0.1", opts.port), None)
    port = server.server_address[1]
    server.RequestHandlerClass = make_handler(app, {f"127.0.0.1:{port}", f"localhost:{port}"})
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{port}/#k={app.key}"
    print(url, flush=True)
    if opts.open:
        webbrowser.open(url)

    while not app.done.wait(5):
        if time.monotonic() - app.last_request > opts.idle_minutes * 60:
            print(json.dumps({"exit": "idle"}), flush=True)
            break
    else:
        print(json.dumps({"exit": "done"}), flush=True)
    server.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
