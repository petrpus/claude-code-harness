"""scripts/test-clockify-app.py — drives a running skills/worklog/worklog-app.py --service clockify.

Called by scripts/test-clockify.sh, which starts the server against its stub
`curl` and passes APP_URL, STUB_DIR, BATCH, CLOCKIFY_PROJECTS and the stub's
ids. Uses urllib, so the requests to the page never go through the stub curl
on PATH. The Harvest flavour (guards, key, Host, body checks) is covered by
scripts/test-harvest-app.py; this one covers what differs: string ids, a
project without tasks, billable passed through, and intervals.
"""

import json
import os
import urllib.error
import urllib.request

E = os.environ
base, key = E["APP_URL"].split("/#k=")
P1, P2, P3, T1, E1 = E["P1"], E["P2"], E["P3"], E["T1"], E["E1"]
fails = 0


def call(path, body=None):
    h = {"X-Worklog-Key": key, **({"Content-Type": "application/json"} if body is not None else {})}
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, json.loads(raw) if "json" in r.headers.get("Content-Type", "") else raw
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")


def check(cond, good, bad):
    global fails
    print(f"  ✓ {good}" if cond else f"  ✗ {bad}")
    fails += 0 if cond else 1


def log_lines(name):
    path = os.path.join(E["STUB_DIR"], name)
    return open(path).read().splitlines() if os.path.exists(path) else []


code, page = call("/")
check(code == 200 and b"Worklog" in page and key.encode() not in page and b"Harvest now" not in page,
      "the page is served without the key or a hard-coded tracker name", f"page {code}")

code, st = call("/api/state")
check(code == 200 and st["service"] == "Clockify" and st["flag"] == "--clockify" and st["project_id"] == P1,
      "state names Clockify and keeps the guessed project (a string id)", f"state {code}: {st}")
projects = {p["project_id"]: p for p in st.get("projects", [])}
check(projects.get(P1, {}).get("task_id") == T1 and projects[P1]["loggable"]
      and projects.get(P2, {}).get("task_id") is None and projects[P2]["loggable"]
      and projects.get(P3, {}).get("loggable") is False,
      "a project without tasks is loggable without one; one without the named task is not",
      f"projects {st.get('projects')}")

code, ent = call(f"/api/entries?project={P1}")
check(code == 200 and ent and all(e["task_id"] == T1 for e in ent) and E1 in [e["id"] for e in ent],
      "entries are those of the project's Programming task", f"entries {code}: {ent}")
code, _ = call("/api/entries?project=12345")
check(code == 400, "entries refuses a project id that is not a Clockify id", f"numeric project got {code}")

before = len(log_lines("posts.log"))
code, res = call("/api/apply", {"project_id": P2, "date": "2026-10-15", "hours": 2, "notes": "x", "entry_id": None})
post = json.loads(log_lines("posts.log")[-1]) if len(log_lines("posts.log")) > before else {}
check(code == 200 and res["action"] == "created" and isinstance(res["entry"]["id"], str)
      and post.get("billable") is False and "taskId" not in post and post.get("start") == "2026-10-15T07:00:00Z",
      "create on a project without tasks sends no task and the project's billable flag",
      f"create {code}: {res} post={post}")
row = next((r for r in json.load(open(E["BATCH"])) if r["date"] == "2026-10-15"), {})
check(row.get("entry_id") == res.get("entry", {}).get("id") and row.get("project_id") == P2,
      "the batch gets the string entry id and project written back", f"row {row}")

code, res = call("/api/apply", {"project_id": P1, "date": "2026-10-14", "hours": 1, "notes": "", "entry_id": None})
check(code == 409, "a create on a day that already has an entry is refused (no double-logging)", f"duplicate create got {code}: {res}")

code, res = call("/api/apply", {"project_id": P1, "date": "2026-10-14", "hours": 1.5, "notes": "edited", "entry_id": E1})
put = log_lines("puts.log")[-1] if log_lines("puts.log") else ""
check(code == 200 and res["action"] == "updated" and put.startswith(E1 + " ")
      and json.loads(put.split(" ", 1)[1]).get("end") == "2026-10-14T08:30:00Z",
      "update by a string id moves the end of the interval", f"update {code}: {res} put={put}")

for bad in ({"entry_id": 7}, {"project_id": 5}, {"project_id": "nope"}, {"entry_id": E1.upper()[:-1] + "Z"}):
    code, _ = call("/api/apply", {"project_id": P1, "date": "2026-10-14", "hours": 1, "notes": "", "entry_id": None, **bad})
    check(code == 400, f"apply refuses {bad}", f"{bad} got {code}")
code, _ = call("/api/apply", {"project_id": P2, "date": "2026-10-14", "hours": 1, "notes": "", "entry_id": E1})
check(code == 400, "apply refuses to update an entry of another project", f"cross-project update got {code}")

code, _ = call("/api/project", {"project_id": P3})
check(code == 400, "a project without the named task cannot be chosen", f"project P3 got {code}")
code, _ = call("/api/project", {"project_id": 5})
check(code == 400, "a numeric project id is refused", f"numeric project got {code}")
code, _ = call("/api/project", {"project_id": P2})
mapping = json.load(open(E["CLOCKIFY_PROJECTS"]))
check(code == 200 and mapping == {"/repo/a": P2}, "choosing a project remembers its string id for the repo", f"mapping {mapping}")

code, _ = call("/api/done", {})
check(code == 200, "done is accepted", f"done got {code}")

raise SystemExit(1 if fails else 0)
