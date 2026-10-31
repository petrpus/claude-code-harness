#!/usr/bin/env bash
# scripts/test-clockify.sh — offline tests for skills/worklog/clockify.sh and
# worklog-app.py --service clockify (via scripts/test-clockify-app.py).
#
# A stub `curl` on PATH (python3) plays the Clockify API: the user, workspaces,
# paged hydrated projects and their tasks, paged time entries filtered by time
# and project, POST/GET/PUT/DELETE time-entries. It keeps the entries in a JSON
# file, records every call's argv and stdin, and refuses a POST on demand.
# Nothing touches the network or the real ~/.config/clockify. Invoked from
# scripts/verify.sh's "worklog clockify" section. Cleaned up on exit.

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1

FAIL=0
note() { echo "  ✗ $*"; FAIL=1; }
ok()   { echo "  ✓ $*"; }

if ! command -v jq >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "  (jq or python3 absent — skipping)"; exit 0
fi

C="$PWD/skills/worklog/clockify.sh"
A="$PWD/skills/worklog/worklog-app.py"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home"

WS=aaaaaaaaaaaaaaaaaaaaaaa1 USR=bbbbbbbbbbbbbbbbbbbbbbb1
P1=ccccccccccccccccccccccc1 P2=ccccccccccccccccccccccc2 P3=ccccccccccccccccccccccc3 P4=ccccccccccccccccccccccc4
T1=ddddddddddddddddddddddd1 T2=ddddddddddddddddddddddd2 T3=ddddddddddddddddddddddd3 T4=ddddddddddddddddddddddd4
E1=eeeeeeeeeeeeeeeeeeeeeee1 E2=eeeeeeeeeeeeeeeeeeeeeee2 E3=eeeeeeeeeeeeeeeeeeeeeee3
TAG=fffffffffffffffffffffff1 CF=99999999999999999999999a
export WS USR P1 P2 P3 P4 T1 T2 T3 T4 E1 E2 E3 TAG CF

# ---------------------------------------------------------------- stub curl ---
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env -S python3 -I
"""Clockify API stand-in. State lives in $STUB_DIR."""
import json, os, sys
from urllib.parse import urlparse, parse_qs

d = os.environ["STUB_DIR"]
E = os.environ
stdin = sys.stdin.read()
open(f"{d}/last-stdin", "w").write(stdin)
open(f"{d}/stdin.log", "a").write(stdin)
open(f"{d}/argv.log", "a").write(" ".join(sys.argv[1:]) + "\n")
open(f"{d}/env.log", "a").write(E.get("CLOCKIFY_EVIL", "") + "\n")

method, url, body, args = "GET", "", "", sys.argv[1:]
i = 0
while i < len(args):
    a = args[i]
    if a == "-X": method = args[i + 1]; i += 2
    elif a == "--data": body = args[i + 1]; i += 2
    elif a == "--max-time": open(f"{d}/max-time", "w").write(args[i + 1]); i += 2
    elif a in ("-H", "-K", "-w", "--connect-timeout"): i += 2
    elif a.startswith("http"): url = a; i += 1
    else: i += 1

def reply(code, payload):
    sys.stdout.write((payload if isinstance(payload, str) else json.dumps(payload)) + "\n" + str(code))
    sys.exit(0)

u = urlparse(url)
if u.netloc != "api.test":
    reply(404, {"message": f"stub: unknown host {u.netloc}"})
path = u.path.removeprefix("/api/v1")
q = {k: v[0] for k, v in parse_qs(u.query).items()}
open(f"{d}/calls.log", "a").write(f"{method} {path}?{u.query}\n")
ws = f"/workspaces/{E['WS']}"

projects = [
    {"id": E["P1"], "name": "P1", "clientName": "C", "billable": True, "archived": False,
     "tasks": [{"id": E["T1"], "name": "Programming", "status": "ACTIVE"},
               {"id": E["T2"], "name": "Meeting", "status": "ACTIVE"},
               {"id": E["T3"], "name": "Old", "status": "DONE"}]},
    {"id": E["P2"], "name": "P2", "clientName": "", "billable": False, "archived": False},
    {"id": E["P3"], "name": "P3", "clientName": "C", "billable": True, "archived": False,
     "tasks": [{"id": E["T4"], "name": "Design", "status": "ACTIVE"}]},
    {"id": E["P4"], "name": "Gone", "clientName": "C", "billable": True, "archived": True, "tasks": []},
]
by_id = {p["id"]: p for p in projects}
store = f"{d}/entries.json"
entries = json.load(open(store)) if os.path.exists(store) else []

def save():
    json.dump(entries, open(store, "w"))

def page(items):
    p, n = int(q.get("page", 1)), int(q.get("page-size", 50))
    return items[(p - 1) * n: p * n]

def hydrate(e):
    out = dict(e)
    if e.get("projectId"):
        out["project"] = {"id": e["projectId"], "name": by_id[e["projectId"]]["name"]}
    if e.get("taskId"):
        out["task"] = {"id": e["taskId"], "name": "Programming" if e["taskId"] == E["T1"] else "Other"}
    return out

if method == "GET" and path == "/user":
    reply(200, {"id": E["USR"], "name": "T U", "email": "t@u", "activeWorkspace": E["WS"],
                "settings": {"timeZone": E.get("STUB_TZ", "Europe/Prague")}})
if method == "GET" and path == "/workspaces":
    reply(200, [{"id": E["WS"], "name": "Acme"}, {"id": "aaaaaaaaaaaaaaaaaaaaaaa2", "name": "Acme Sandbox"}])
if method == "GET" and path == f"{ws}/projects":
    reply(200, page(projects))
if method == "GET" and path == f"{ws}/projects/{E['P2']}/tasks":
    reply(200, page([]))
if method == "GET" and path.startswith(f"{ws}/projects/"):
    pid = path.rsplit("/", 1)[1]
    reply(200, by_id[pid]) if pid in by_id else reply(404, {"message": "no project"})
if method == "GET" and path == f"{ws}/user/{E['USR']}/time-entries":
    hits = [e for e in entries
            if q["start"] <= e["timeInterval"]["start"] <= q["end"]
            and ("project" not in q or e.get("projectId") == q["project"])]
    reply(200, [hydrate(e) for e in page(hits)])
if method == "POST" and path == f"{ws}/time-entries":
    b = json.loads(body)
    open(f"{d}/posts.log", "a").write(json.dumps(b) + "\n")
    if os.path.exists(f"{d}/fail-on") and b["start"][:10] in open(f"{d}/fail-on").read().split():
        reply(400, {"message": "Entry is locked", "code": 501})
    n = int(open(f"{d}/next-id").read()) + 1 if os.path.exists(f"{d}/next-id") else 256
    open(f"{d}/next-id", "w").write(str(n))
    e = {"id": f"{n:024x}", "description": b.get("description", ""), "projectId": b.get("projectId"),
         "taskId": b.get("taskId"), "billable": b.get("billable", False), "tagIds": b.get("tagIds"),
         "timeInterval": {"start": b["start"], "end": b.get("end")}, "userId": E["USR"]}
    entries.append(e); save()
    reply(201, e)
if path.startswith(f"{ws}/time-entries/"):
    eid = path.rsplit("/", 1)[1]
    e = next((x for x in entries if x["id"] == eid), None)
    if e is None:
        reply(404, {"message": "no entry"})
    if method == "GET":
        reply(200, e)
    if method == "PUT":
        b = json.loads(body)
        open(f"{d}/puts.log", "a").write(f"{eid} {json.dumps(b)}\n")
        e.update(description=b.get("description", ""), projectId=b.get("projectId"), taskId=b.get("taskId"),
                 billable=b.get("billable", False), tagIds=b.get("tagIds"),
                 timeInterval={"start": b["start"], "end": b.get("end")})
        save()
        reply(200, e)
    if method == "DELETE":
        entries.remove(e); save()
        reply(204, "")
reply(404, {"message": f"stub: no route for {method} {path}"})
STUB
chmod +x "$T/bin/curl"

# Two finished entries and one running, seen from Europe/Prague (UTC+2 until
# 2026-10-25, then UTC+1): E1 09:00–11:00 local on 10-14 with a tag and a
# custom field, E2 still running, E3 at 01:30 local on 10-15 (23:30Z on 10-14).
jq -n --arg e1 "$E1" --arg e2 "$E2" --arg e3 "$E3" --arg p1 "$P1" --arg p2 "$P2" --arg t1 "$T1" --arg tag "$TAG" --arg cf "$CF" '[
  {id: $e1, description: "seeded", projectId: $p1, taskId: $t1, billable: true, tagIds: [$tag],
   customFieldValues: [{customFieldId: $cf, value: "x", name: "Ticket"}], type: "REGULAR",
   timeInterval: {start: "2026-10-14T07:00:00Z", end: "2026-10-14T09:00:00Z", duration: "PT2H"}},
  {id: $e2, description: "running", projectId: $p1, taskId: $t1, billable: true, tagIds: [],
   timeInterval: {start: "2026-10-14T10:00:00Z", end: null, duration: null}},
  {id: $e3, description: "night", projectId: $p2, taskId: null, billable: false, tagIds: null,
   timeInterval: {start: "2026-10-14T23:30:00.000Z", end: "2026-10-15T00:30:00.000Z", duration: "PT1H"}}
]' > "$T/entries.json"

export PATH="$T/bin:$PATH" STUB_DIR="$T" HOME="$T/home"
export CLOCKIFY_API_BASE="http://api.test/api/v1" CLOCKIFY_CONFIG="$T/home/clockify.env"
unset CLOCKIFY_API_KEY CLOCKIFY_WORKSPACE_ID CLOCKIFY_WORKSPACE_NAME CLOCKIFY_USER_ID CLOCKIFY_TIMEZONE CLOCKIFY_DAY_START CLOCKIFY_PAGE_SIZE

posts() { [[ -f "$T/posts.log" ]] && wc -l < "$T/posts.log" | tr -d ' ' || echo 0; }
last_post() { tail -1 "$T/posts.log" 2>/dev/null; }

# ------------------------------------------------------------------- setup ---
printf 'key-OLD\n' | bash "$C" setup Acme >/dev/null 2>&1
if grep -qx 'CLOCKIFY_API_KEY=key-OLD' "$CLOCKIFY_CONFIG" && grep -qx "CLOCKIFY_WORKSPACE_ID=$WS" "$CLOCKIFY_CONFIG" \
   && grep -qx "CLOCKIFY_USER_ID=$USR" "$CLOCKIFY_CONFIG" && grep -qx 'CLOCKIFY_TIMEZONE=Europe/Prague' "$CLOCKIFY_CONFIG"; then
  ok "setup resolves the exact workspace name beside a substring match and stores user and time zone"
else
  note "setup wrote: $(cat "$CLOCKIFY_CONFIG" 2>/dev/null)"
fi
[[ "$(stat -c %a "$CLOCKIFY_CONFIG" 2>/dev/null)" == 600 ]] && ok "config is mode 600" || note "config mode is $(stat -c %a "$CLOCKIFY_CONFIG")"
grep -qx 'CLOCKIFY_API_BASE=http://api.test/api/v1' "$CLOCKIFY_CONFIG" \
  && ok "setup stores a non-default API base (regional servers)" || note "setup did not store the API base"

printf 'key-NEW\n' | bash "$C" setup Acme >/dev/null 2>&1
grep -qx 'CLOCKIFY_API_KEY=key-NEW' "$CLOCKIFY_CONFIG" \
  && ok "setup rerun replaces the key instead of reusing the config's" \
  || note "setup rerun kept the stale key: $(grep KEY "$CLOCKIFY_CONFIG")"
if grep -q 'key-' "$T/argv.log"; then note "the API key appeared in curl's argv"
elif grep -q 'X-Api-Key: key-NEW' "$T/stdin.log"; then ok "the API key reaches curl on stdin, never argv"
else note "the API key never reached curl"; fi

printf 'k\n' | bash "$C" setup >/dev/null 2>&1 && note "setup without a name accepted several workspaces" \
  || ok "setup without a name refuses when several workspaces are visible"
printf 'k\n' | STUB_TZ='Mars/Olympus' CLOCKIFY_CONFIG="$T/home/tz.env" bash "$C" setup Acme >/dev/null 2>&1
grep -qx 'CLOCKIFY_TIMEZONE=' "$T/home/tz.env" \
  && ok "setup does not store an unknown time zone (GNU date would read it as UTC)" \
  || note "unknown zone stored: $(grep TIMEZONE "$T/home/tz.env")"

# The config's API base is used once the environment's is gone.
if (unset CLOCKIFY_API_BASE; bash "$C" me 2>/dev/null | jq -e --arg u "$USR" '.id == $u and .timezone == "Europe/Prague"' >/dev/null); then
  ok "me answers from the config alone (key, workspace, time zone, API base)"
else
  note "me failed without the environment"
fi
CLOCKIFY_API_KEY='a\b"c' CLOCKIFY_MAX_TIME=5 bash "$C" me >/dev/null 2>&1
grep -qF 'X-Api-Key: a\\b\"c"' "$T/last-stdin" \
  && ok "a key with \\ and \" is escaped for the curl config" || note "key escaping is wrong: $(cat "$T/last-stdin")"
[[ "$(cat "$T/max-time" 2>/dev/null)" == 5 ]] && ok "CLOCKIFY_MAX_TIME reaches curl as --max-time" || note "--max-time did not reach curl"
printf 'CLOCKIFY_EVIL=1\nnot a key value line\n9BAD=1\n' >> "$CLOCKIFY_CONFIG"
if bash "$C" me >/dev/null 2>&1 && [[ -z "$(tail -1 "$T/env.log")" ]]; then
  ok "config loader exports only the CLOCKIFY_* keys setup writes"
else
  note "config loader exported a foreign key or aborted on a malformed line"
fi

# ---------------------------------------------------------------- projects ---
PJ="$(bash "$C" projects 2>&1)"
if jq -e --arg p1 "$P1" --arg p2 "$P2" --arg p3 "$P3" --arg t1 "$T1" '
     [.[].project_id] == [$p2, $p1, $p3]
     and (.[1].tasks | map(.task_id)) == [$t1, "ddddddddddddddddddddddd2"]
     and .[0].tasks == [] and .[0].billable == false and .[1].billable == true and .[1].client == "C"' <<<"$PJ" >/dev/null 2>&1; then
  ok "projects drops archived ones and DONE tasks, fetches tasks a hydrated project lacks"
else
  note "projects: $PJ"
fi
grep -q "projects/$P2/tasks?is-active=true" "$T/calls.log" \
  && ok "a project without a tasks field gets them from its task list" || note "no task-list call for $P2"
bash "$C" projects --text 2>/dev/null | grep -qx "$P2	P2 (no tasks)" \
  && ok "projects --text marks a project without tasks" || note "projects --text: $(bash "$C" projects --text 2>&1 | head -3)"

# ----------------------------------------------------------------- entries ---
EJ="$(bash "$C" entries 2026-10-14 2026-10-15 2>&1)"
if jq -e --arg e1 "$E1" --arg e3 "$E3" --arg t1 "$T1" '
     length == 2
     and .[0].id == $e1 and .[0].date == "2026-10-14" and .[0].hours == 2 and .[0].task_id == $t1 and .[0].notes == "seeded"
     and .[1].id == $e3 and .[1].date == "2026-10-15" and .[1].hours == 1 and .[1].task_id == null' <<<"$EJ" >/dev/null 2>&1; then
  ok "entries: local dates from the profile's zone, hours from the interval, running entries left out"
else
  note "entries: $EJ"
fi
[[ "$(bash "$C" entries 2026-10-14 2026-10-15 --project "$P1" 2>/dev/null | jq -r --arg e1 "$E1" 'map(.id) == [$e1]')" == true ]] \
  && ok "entries --project filters to that project" || note "entries --project returned other rows"
grep -q 'start=2026-10-13T22:00:00Z&end=2026-10-15T21:59:59Z' "$T/calls.log" \
  && ok "the window is the local days, converted to UTC" || note "window query: $(grep time-entries "$T/calls.log" | tail -1)"
rm -f "$T/calls.log"
n="$(CLOCKIFY_PAGE_SIZE=1 bash "$C" entries 2026-10-14 2026-10-15 2>/dev/null | jq 'length')"
[[ "$n" == 2 ]] && grep -q 'page=4&page-size=1' "$T/calls.log" \
  && ok "entries pages until a short page" || note "paging: $n rows, calls: $(tr '\n' '|' < "$T/calls.log")"

# --------------------------------------------------------------------- log ---
bash "$C" log 2026-10-14 7.5 --project "$P1" --task "$T1" --notes "a\nb" > "$T/log1" 2>&1; rc=$?
if [[ "$rc" -eq 0 ]] && last_post | jq -e --arg p1 "$P1" --arg t1 "$T1" '
     .start == "2026-10-14T09:00:00Z" and .end == "2026-10-14T16:30:00Z"
     and .billable == true and .projectId == $p1 and .taskId == $t1 and .description == "a\\nb"' >/dev/null; then
  ok "log starts after the day's last finished entry and takes billable from the project"
else
  note "log rc=$rc out=$(cat "$T/log1") post=$(last_post)"
fi
jq -e '.date == "2026-10-14" and .hours == 7.5 and (.id | test("^[0-9a-f]{24}$"))' "$T/log1" >/dev/null 2>&1 \
  && ok "log prints the entry with its date and hours" || note "log output: $(cat "$T/log1")"
bash "$C" log 2026-10-16 2 --project "$P2" --billable false --notes "" >/dev/null 2>&1
last_post | jq -e '.start == "2026-10-16T07:00:00Z" and .end == "2026-10-16T09:00:00Z" and .billable == false and (has("taskId") | not)' >/dev/null \
  && ok "log on an empty day starts at 09:00 local and sends no task for a project without tasks" \
  || note "empty-day log: $(last_post)"
bash "$C" log 2026-10-27 1 --project "$P2" --billable false --notes "" >/dev/null 2>&1
last_post | jq -e '.start == "2026-10-27T08:00:00Z"' >/dev/null \
  && ok "09:00 local follows the zone's DST change" || note "DST: $(last_post)"
CLOCKIFY_DAY_START=13:15 bash "$C" log 2026-10-28 1 --project "$P2" --billable false --notes "" >/dev/null 2>&1
last_post | jq -e '.start == "2026-10-28T12:15:00Z"' >/dev/null \
  && ok "CLOCKIFY_DAY_START moves the start of a day" || note "day start: $(last_post)"

before="$(posts)"
for args in "log 2026-10-14 2 --project xyz" "log 2026-10-14 25 --project $P1" "log 2026-10-14 2 --project $P1 --task 12" \
            "log 2026-10-14 2 --project $P1 --billable maybe" "log 2026-10-14 2 --project" "log 2026-13-45 2 --project $P1" \
            "entries 2026-10-14 2026-10-15 --project 1" "update xyz --hours 1" "update $E1" "delete 42"; do
  # shellcheck disable=SC2086
  timeout 10 bash "$C" $args >/dev/null 2>&1; rc=$?
  [[ "$rc" -eq 1 ]] && ok "refused with exit 1: ${args}" || note "rc=$rc (124 = hang) for: $args"
done
[[ "$(posts)" -eq "$before" ]] && ok "no entry was sent for a refused command" || note "a refused command still POSTed"
CLOCKIFY_DAY_START=9am bash "$C" me >/dev/null 2>&1 && note "a malformed CLOCKIFY_DAY_START was accepted" \
  || ok "a malformed CLOCKIFY_DAY_START is refused"

echo 2026-10-20 > "$T/fail-on"
err="$(bash "$C" log 2026-10-20 1 --project "$P2" --billable false 2>&1 >/dev/null)"; rc=$?
[[ "$rc" -eq 2 && "$err" == *"HTTP 400"*"Entry is locked"* ]] \
  && ok "a refused create exits 2 with Clockify's message" || note "refused create rc=$rc: $err"
rm -f "$T/fail-on"

# ------------------------------------------------------------------ update ---
rm -f "$T/puts.log"
out="$(bash "$C" update "$E1" --hours 3 --notes "new notes" 2>&1)"; rc=$?
if [[ "$rc" -eq 0 ]] && sed "s/^$E1 //" "$T/puts.log" | jq -e --arg p1 "$P1" --arg t1 "$T1" --arg tag "$TAG" --arg cf "$CF" '
     .start == "2026-10-14T07:00:00Z" and .end == "2026-10-14T10:00:00Z" and .description == "new notes"
     and .billable == true and .projectId == $p1 and .taskId == $t1 and .tagIds == [$tag]
     and .customFields == [{customFieldId: $cf, value: "x"}]' >/dev/null; then
  ok "update keeps the start, moves the end, and sends back tags, billable and custom fields"
else
  note "update rc=$rc out=$out put=$(cat "$T/puts.log" 2>/dev/null)"
fi
jq -e '.date == "2026-10-14" and .hours == 3' <<<"$out" >/dev/null 2>&1 \
  && ok "update prints the entry's date and new hours" || note "update output: $out"
rm -f "$T/puts.log"
bash "$C" update "$E1" --notes "" >/dev/null 2>&1
sed "s/^$E1 //" "$T/puts.log" 2>/dev/null | jq -e '.end == "2026-10-14T10:00:00Z" and .description == ""' >/dev/null \
  && ok "update with only --notes leaves the interval alone" || note "notes-only update: $(cat "$T/puts.log" 2>/dev/null)"
bash "$C" update "$E2" --hours 1 >/dev/null 2>&1; rc=$?
[[ "$rc" -eq 1 ]] && ok "update refuses an entry that is still running" || note "running update rc=$rc"
bash "$C" update "$E3" --hours 2 >/dev/null 2>&1
grep "^$E3 " "$T/puts.log" | sed "s/^$E3 //" | jq -e '.start == "2026-10-14T23:30:00Z" and .end == "2026-10-15T01:30:00Z" and (has("taskId") | not)' >/dev/null \
  && ok "update reads fractional-second times and keeps an entry without a task" || note "E3 update: $(grep "^$E3 " "$T/puts.log")"

bash "$C" delete "$E3" 2>/dev/null | grep -qx "deleted entry $E3" && ! jq -e --arg e3 "$E3" 'any(.[]; .id == $e3)' "$T/entries.json" >/dev/null \
  && ok "delete removes the entry" || note "delete did not remove $E3"

# ---------------------------------------------------------------- the page ---
cat > "$T/app.json" <<'JSON'
[{"date":"2026-10-16","hours":3,"notes":"proposal"},{"date":"2026-10-14","hours":2,"notes":"edit me"}]
JSON
export CLOCKIFY_PROJECTS="$T/home/clockify-projects.json"
python3 "$A" "$T/app.json" --service clockify --from 2026-10-13 --to 2026-10-16 --project "$P1" --repo /repo/a \
  > "$T/app.out" 2> "$T/app.err" &
app_pid=$!
for _ in $(seq 50); do [[ -s "$T/app.out" ]] && break; sleep 0.1; done
url="$(head -1 "$T/app.out")"
if [[ "$url" =~ ^http://127\.0\.0\.1:[0-9]+/#k=.+ ]]; then
  ok "worklog-app (clockify) prints a loopback URL carrying the key in the fragment"
  APP_URL="$url" BATCH="$T/app.json" python3 scripts/test-clockify-app.py || FAIL=1
else
  note "worklog-app (clockify) did not start: $(cat "$T/app.err")"
fi
for _ in $(seq 50); do kill -0 "$app_pid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$app_pid" 2>/dev/null; then
  kill "$app_pid"; note "worklog-app (clockify) kept running after done"
elif grep -q '"exit": "done"' "$T/app.out" && grep -q '"action": "created"' "$T/app.out"; then
  ok "worklog-app (clockify) exits on done and prints each applied entry"
else
  note "worklog-app (clockify) stdout: $(cat "$T/app.out")"
fi
python3 "$A" "$T/app.json" --service clockify --from 2026-10-13 --to 2026-10-16 --project 12 >/dev/null 2>&1 \
  && note "worklog-app (clockify) accepted a numeric --project" || ok "worklog-app (clockify) refuses a --project that is not a Clockify id"

exit "$FAIL"
