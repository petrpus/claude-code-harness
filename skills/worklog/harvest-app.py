#!/usr/bin/env python3
"""skills/worklog/harvest-app.py — local review-and-log page for /worklog --harvest.

    harvest-app.py <batch.json> --from YYYY-MM-DD --to YYYY-MM-DD
                   [--project ID] [--repo KEY] [--task-name NAME]
                   [--port N] [--idle-minutes N] [--open]

Serves one page on 127.0.0.1: a project select, the user's Harvest entries for
that project and task in the window, and an editable proposal per day with a
button that creates or updates the entry. Every Harvest call goes through
harvest.sh next to this file, so the token stays in harvest.sh's config and
never reaches this process's responses or the page.

The batch file holds the proposals ([{date, hours, notes}]) the skill derived
from the commits; each applied row gets its entry_id written back, so a rerun
of the page shows what already went to Harvest.

Project choice: a project remembered for --repo in $HARVEST_PROJECTS (default
~/.config/harvest/projects.json) wins over --project, the skill's guess from
context. Changing the select remembers the new choice for --repo.

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
HARVEST = HERE / "harvest.sh"
PAGE = HERE / "harvest-app.html"
PROJECTS_MAP = Path(os.environ.get("HARVEST_PROJECTS", Path.home() / ".config/harvest/projects.json"))
MAX_BODY = 1 << 20


class HarvestError(Exception):
    """harvest.sh failed or Harvest refused → 502."""


class Conflict(Exception):
    """The request would double-log a day → 409."""


def harvest(*args):
    proc = subprocess.run(["bash", str(HARVEST), *args], capture_output=True, text=True, encoding="utf-8")
    if proc.returncode != 0:
        raise HarvestError(proc.stderr.strip() or f"harvest.sh {args[0]} exited {proc.returncode}")
    return json.loads(proc.stdout) if proc.stdout.strip() else None


def harvest_with_notes(args, notes):
    # Notes go through a file: they are free text of any length.
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".txt", delete=False) as f:
        f.write(notes)
        path = f.name
    try:
        return harvest(*args, "--notes-file", path)
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
    try:
        mapping = read_json(PROJECTS_MAP, {})
    except ValueError:
        mapping = None
    if not isinstance(mapping, dict):
        print(f"harvest-app: ignoring unreadable {PROJECTS_MAP}", file=sys.stderr, flush=True)
        return {}
    return mapping


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


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
            self.projects = [
                {
                    "project_id": p["project_id"],
                    "label": f'{p["client"]} / {p["project"]}',
                    "task_id": next((t["task_id"] for t in p["tasks"] if t["task"].casefold() == want), None),
                }
                for p in harvest("projects")
            ]
        return self.projects

    def selected_project(self):
        ids = {p["project_id"] for p in self.load_projects() if p["task_id"]}
        remembered = read_projects_map().get(self.opts.repo) if self.opts.repo else None
        for candidate in (remembered, self.opts.project):
            if candidate in ids:
                return candidate
        return None

    def state(self):
        rows = {r["date"]: r for r in self.batch()}
        return {
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

    def task_for(self, project_id):
        for p in self.load_projects():
            if p["project_id"] == project_id and p["task_id"]:
                return p["task_id"]
        raise ValueError(f"project {project_id} has no active {self.opts.task_name} task")

    def entries(self, project_id):
        task_id = self.task_for(project_id)
        rows = harvest("entries", self.opts.date_from, self.opts.date_to, "--project", str(project_id))
        return [e for e in rows if e["task_id"] == task_id]

    # ----------------------------------------------------------- writes ---
    def remember(self, project_id):
        self.task_for(project_id)
        if not self.opts.repo:
            return
        with self.lock:
            mapping = read_projects_map()
            mapping[self.opts.repo] = project_id
            write_json(PROJECTS_MAP, mapping)

    def apply(self, body):
        project_id, date, hours = body.get("project_id"), body.get("date"), body.get("hours")
        notes, entry_id, new = body.get("notes", ""), body.get("entry_id"), body.get("new") is True
        if not is_int(project_id):
            raise ValueError("project_id must be a number")
        if date not in self.window():
            raise ValueError(f"{date} is outside the window")
        if not is_hours(hours):
            raise ValueError("hours must be a number in (0, 24]")
        if not isinstance(notes, str):
            raise ValueError("notes must be text")
        if entry_id is not None and not is_int(entry_id):
            raise ValueError("entry_id must be a number or null")
        # Re-read Harvest on every write: the page's copy may be stale (a
        # second tab, an entry added in Harvest meanwhile).
        existing = [e["id"] for e in self.entries(project_id) if e["date"] == date]
        if entry_id is not None:
            if entry_id not in existing:
                raise ValueError(f"entry {entry_id} is not a {self.opts.task_name} entry of this project on {date}")
            entry = harvest_with_notes(["update", str(entry_id), "--hours", str(hours)], notes)
            action = "updated"
        else:
            if existing and not new:
                raise Conflict(
                    f"{date} already holds entry {', '.join(f'#{i}' for i in existing)} in Harvest — "
                    "reload the page, or pick “New entry” to add another one"
                )
            task_id = self.task_for(project_id)
            entry = harvest_with_notes(
                ["log", date, str(hours), "--project", str(project_id), "--task", str(task_id)], notes
            )
            action = "created"
        print(json.dumps({"action": action, "date": date, "hours": hours, "entry_id": entry["id"]}), flush=True)
        result = {"action": action, "entry": entry}
        # Harvest already holds the entry; a failed write-back must not hide that.
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
            result["warning"] = f"entry #{entry['id']} is in Harvest, but {self.opts.batch} was not updated: {e}"
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
            except HarvestError as e:
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
                if not re.fullmatch(r"[0-9]{1,15}", project):
                    self.send(400, {"error": "project must be a numeric id"})
                    return
                self.run(lambda: app.entries(int(project)))
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
                project_id = body.get("project_id")
                if not is_int(project_id):
                    self.send(400, {"error": "project_id must be a number"})
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
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("batch")
    ap.add_argument("--from", dest="date_from", required=True)
    ap.add_argument("--to", dest="date_to", required=True)
    ap.add_argument("--project", type=int)
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
