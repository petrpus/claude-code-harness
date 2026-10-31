"""scripts/test-harvest-app.py — drives a running skills/worklog/worklog-app.py --service harvest.

Called by scripts/test-harvest.sh, which starts the server against its stub
`curl` and passes APP_URL, STUB_DIR, BATCH and HARVEST_PROJECTS. Uses urllib,
so the requests to the page never go through the stub curl on PATH.
"""

import json
import os
import urllib.error
import urllib.request

base, key = os.environ["APP_URL"].split("/#k=")
port = base.rsplit(":", 1)[1]
fails = 0

if os.environ.get("MODE") == "remembered":
    req = urllib.request.Request(base + "/api/state", headers={"X-Worklog-Key": key})
    st = json.load(urllib.request.urlopen(req, timeout=20))
    req = urllib.request.Request(base + "/api/done", data=b"{}",
                                 headers={"X-Worklog-Key": key, "Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=20)
    raise SystemExit(0 if st["project_id"] == 1 else 1)


def call(path, body=None, headers=None):
    h = {"X-Worklog-Key": key, **({"Content-Type": "application/json"} if body is not None else {}), **(headers or {})}
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
            return r.status, json.loads(raw) if "json" in r.headers.get("Content-Type", "") else raw
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")


def check(cond, good, bad):
    global fails
    print(f"  ✓ {good}" if cond else f"  ✗ {bad}")
    fails += 0 if cond else 1


def posts():
    path = os.path.join(os.environ["STUB_DIR"], "posts.log")
    return open(path).read().count("\n") if os.path.exists(path) else 0


def patches():
    path = os.path.join(os.environ["STUB_DIR"], "patches.log")
    return open(path).read() if os.path.exists(path) else ""


code, _ = call("/api/state", headers={"X-Worklog-Key": "wrong"})
check(code == 403, "the API refuses a wrong key", f"wrong key got {code}")
code, _ = call("/api/state", headers={"X-Worklog-Key": ""})
check(code == 403, "the API refuses a missing key", f"missing key got {code}")
code, _ = call("/api/state", headers={"Host": f"evil.test:{port}"})
check(code == 403, "the server refuses a foreign Host header", f"foreign Host got {code}")
code, _ = call("/api/project", {"project_id": 1}, headers={"Content-Type": "text/plain"})
check(code == 415, "a POST that is not JSON is refused", f"text/plain POST got {code}")
code, _ = call("/api/ping")
check(code == 200, "ping answers (the open page keeps the server alive with it)", f"ping got {code}")

code, page = call("/")
check(code == 200 and b"Worklog" in page and key.encode() not in page,
      "the page is served and does not embed the key", f"page {code}")

code, st = call("/api/state")
check(code == 200 and [r["date"] for r in st["rows"]] == ["2026-10-15", "2026-10-14", "2026-10-13"]
      and st["rows"][2]["hours"] is None,
      "state lists every day of the window, newest first, with the proposals", f"state {code}: {st}")
check(st.get("project_id") == 1, "a corrupt projects map is ignored and the guess is used",
      f"project_id {st.get('project_id')}")
check([p["task_id"] for p in st["projects"]] == [21, None], "projects carry the id of the named task",
      f"projects {st.get('projects')}")

code, ent = call("/api/entries?project=1")
check(code == 200 and len(ent) == 100 and all(e["task_id"] == 21 for e in ent),
      "entries are those of the project's task", f"entries {code}")
code, _ = call("/api/entries?project=1%26user_id%3D9")
check(code == 400, "entries refuses a non-numeric project", f"non-numeric project got {code}")

code, res = call("/api/apply", {"project_id": 1, "date": "2026-10-15", "hours": 3, "notes": "proposal", "entry_id": None})
row = next(r for r in json.load(open(os.environ["BATCH"])) if r["date"] == "2026-10-15")
check(code == 200 and res["action"] == "created" and row["entry_id"] == res["entry"]["id"],
      "apply creates an entry and writes its id back into the batch", f"create {code}: {res}")

code, res = call("/api/apply", {"project_id": 1, "date": "2026-10-14", "hours": 2.5, "notes": "edited", "entry_id": 7})
check(code == 200 and res["action"] == "updated" and patches().startswith("7 "),
      "apply updates an existing entry of that day", f"update {code}: {res} {patches()}")
row = next(r for r in json.load(open(os.environ["BATCH"])) if r["date"] == "2026-10-14")
check(row["hours"] == 2.5 and row["notes"] == "edited" and row["entry_id"] == 7,
      "the batch keeps the edited proposal of an updated day", f"row {row}")

code, _ = call("/api/apply", {"project_id": 1, "date": "2026-10-15", "hours": 1, "notes": "", "entry_id": 7})
check(code == 400, "apply refuses to update an entry of another day", f"cross-day update got {code}")

before = posts()
code, res = call("/api/apply", {"project_id": 1, "date": "2026-10-14", "hours": 1, "notes": "", "entry_id": None})
check(code == 409 and posts() == before and "#0" in res["error"],
      "a create on a day that already has an entry is refused (no double-logging)", f"duplicate create got {code}: {res}")
code, res = call("/api/apply", {"project_id": 1, "date": "2026-10-14", "hours": 1, "notes": "", "entry_id": None, "new": True})
check(code == 200 and res["action"] == "created" and posts() == before + 1,
      "an explicit new entry beside existing ones is created", f"new entry got {code}: {res}")

for bad in ({"hours": 0}, {"hours": "2"}, {"hours": True}, {"date": "2026-10-20"}, {"notes": 5},
            {"project_id": True}, {"entry_id": [7]}, {"entry_id": "7"}):
    code, _ = call("/api/apply", {"project_id": 1, "date": "2026-10-14", "hours": 1, "notes": "", "entry_id": None, **bad})
    check(code == 400, f"apply refuses {bad}", f"{bad} got {code}")

code, _ = call("/api/project", {"project_id": 1})
mapping = json.load(open(os.environ["HARVEST_PROJECTS"]))
check(code == 200 and mapping == {"/repo/a": 1}, "choosing a project replaces a corrupt map with the choice", f"mapping {mapping}")
code, _ = call("/api/project", {"project_id": 2})
check(code == 400, "a project without the task cannot be chosen", f"project 2 got {code}")

req = urllib.request.Request(base + "/api/project", data=b"{}", method="POST",
                             headers={"X-Worklog-Key": key, "Content-Type": "application/json", "Content-Length": "-1"})
try:
    code = urllib.request.urlopen(req, timeout=5).status
except urllib.error.HTTPError as e:
    code = e.code
check(code == 400, "a negative Content-Length is refused, not read", f"negative length got {code}")

code, _ = call("/api/done", {})
check(code == 200, "done is accepted", f"done got {code}")

raise SystemExit(1 if fails else 0)
