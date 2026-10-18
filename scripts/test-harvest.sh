#!/usr/bin/env bash
# scripts/test-harvest.sh — offline tests for skills/worklog/harvest.sh and
# harvest-app.py (the local review-and-log page, via scripts/test-harvest-app.py).
#
# A stub `curl` on PATH plays the Harvest API (accounts, users/me, paged
# project assignments and time entries, POST/PATCH/DELETE time_entries), records
# every call's argv and stdin, and fails a POST on demand. Nothing touches the
# network or the real ~/.config/harvest. Invoked from scripts/verify.sh's
# "worklog harvest" section. Cleaned up on exit.

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1

FAIL=0
note() { echo "  ✗ $*"; FAIL=1; }
ok()   { echo "  ✓ $*"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "  (jq absent — skipping)"; exit 0
fi

H="$PWD/skills/worklog/harvest.sh"
A="$PWD/skills/worklog/harvest-app.py"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home"

# ---------------------------------------------------------------- stub curl ---
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Harvest API stand-in. State lives in $STUB_DIR.
d="$STUB_DIR"
cat > "$d/last-stdin"; cat "$d/last-stdin" >> "$d/stdin.log"
printf '%s\n' "$*" >> "$d/argv.log"
printf '%s\n' "${HARVEST_EVIL:-}" >> "$d/env.log"
method=GET url="" body=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data) body="$2"; shift 2 ;;
    --max-time) echo "$2" > "$d/max-time"; shift 2 ;;
    -H|-K|-w|--connect-timeout) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
reply() { printf '%s\n%s' "$2" "$1"; exit 0; }
case "$method $url" in
  "GET http://id.test/accounts")
    reply 200 '{"accounts":[{"id":11,"name":"Acme","product":"harvest"},{"id":12,"name":"Acme Sandbox","product":"harvest"},{"id":13,"name":"Other","product":"forecast"}]}' ;;
  "GET http://api.test/users/me")
    reply 200 '{"id":7,"first_name":"T","last_name":"U","email":"t@u","timezone":"UTC"}' ;;
  "GET http://api.test/users/me/project_assignments?per_page=100")
    reply 200 '{"project_assignments":[{"is_active":true,"project":{"id":1,"name":"P1","code":""},"client":{"name":"C"},"task_assignments":[{"is_active":true,"task":{"id":21,"name":"Dev"}}]}],"links":{"next":"http://api.test/pa2"}}' ;;
  "GET http://api.test/pa2")
    reply 200 '{"project_assignments":[{"is_active":true,"project":{"id":2,"name":"P2","code":"X"},"client":{"name":"C"},"task_assignments":[]},{"is_active":false,"project":{"id":3,"name":"Old","code":""},"client":{"name":"C"},"task_assignments":[]}],"links":{"next":null}}' ;;
  "GET http://api.test/time_entries?"*)
    # One page well over the 128 KiB a single argv string may hold.
    jq -nc '{time_entries: [range(100) as $i | {id: $i, spent_date: "2026-10-14", hours: 1,
             project: {id: 1, name: "P1"}, task: {id: 21, name: "Dev"}, notes: ("x" * 2000)}], links: {next: null}}' > "$d/big"
    reply 200 "$(cat "$d/big")" ;;
  "POST http://api.test/time_entries")
    printf '%s\n' "$body" >> "$d/posts.log"
    date="$(jq -r .spent_date <<<"$body")"
    if [[ -f "$d/fail-on" ]] && grep -qx "$date" "$d/fail-on"; then
      reply 422 '{"message":"locked period"}'
    fi
    if [[ -f "$d/no-id" ]]; then reply 201 "$(jq -c '{spent_date, hours}' <<<"$body")"; fi
    n=$(( $(cat "$d/next-id" 2>/dev/null || echo 100) + 1 )); echo "$n" > "$d/next-id"
    reply 201 "$(jq -c --argjson id "$n" '{id: $id, spent_date, hours, project: {name: "P1"}, task: {name: "Dev"}}' <<<"$body")" ;;
  "PATCH http://api.test/time_entries/"*)
    printf '%s %s\n' "${url##*/}" "$body" >> "$d/patches.log"
    reply 200 "$(jq -c --argjson id "${url##*/}" '{id: $id, spent_date: "2026-10-14", hours: (.hours // 1), project: {name: "P1"}, task: {name: "Dev"}}' <<<"$body")" ;;
  "DELETE http://api.test/time_entries/"*) reply 200 '{}' ;;
esac
reply 404 '{"message":"stub: no route for '"$method $url"'"}'
STUB
chmod +x "$T/bin/curl"

export PATH="$T/bin:$PATH" STUB_DIR="$T" HOME="$T/home"
export HARVEST_API_BASE="http://api.test" HARVEST_ID_API_BASE="http://id.test"
export HARVEST_CONFIG="$T/home/harvest.env"
unset HARVEST_ACCESS_TOKEN HARVEST_ACCOUNT_ID HARVEST_ACCOUNT_NAME

posts() { [[ -f "$T/posts.log" ]] && wc -l < "$T/posts.log" | tr -d ' ' || echo 0; }
reset_posts() { rm -f "$T/posts.log" "$T/fail-on" "$T/no-id"; }

# ------------------------------------------------------------------- setup ---
printf 'tok-OLD\n' | bash "$H" setup Acme >/dev/null 2>&1
if grep -qx 'HARVEST_ACCESS_TOKEN=tok-OLD' "$HARVEST_CONFIG" && grep -qx 'HARVEST_ACCOUNT_ID=11' "$HARVEST_CONFIG"; then
  ok "setup resolves the exact account name beside a substring match"
else
  note "setup did not write tok-OLD / account 11: $(cat "$HARVEST_CONFIG" 2>/dev/null)"
fi
[[ "$(stat -c %a "$HARVEST_CONFIG" 2>/dev/null)" == 600 ]] && ok "config is mode 600" || note "config mode is $(stat -c %a "$HARVEST_CONFIG")"

printf 'tok-NEW\n' | bash "$H" setup Acme >/dev/null 2>&1
grep -qx 'HARVEST_ACCESS_TOKEN=tok-NEW' "$HARVEST_CONFIG" \
  && ok "setup rerun replaces the token instead of reusing the config's" \
  || note "setup rerun kept the stale token: $(grep TOKEN "$HARVEST_CONFIG")"

if grep -q 'tok-' "$T/argv.log"; then note "the token appeared in curl's argv"
elif grep -q 'Bearer tok-NEW' "$T/stdin.log"; then ok "the token reaches curl on stdin, never argv"
else note "the token never reached curl"; fi

# curl's config syntax reads \ and " as escapes; the token must arrive intact.
HARVEST_ACCESS_TOKEN='a\b"c' HARVEST_MAX_TIME=5 bash "$H" me >/dev/null 2>&1
grep -qF 'Bearer a\\b\"c"' "$T/last-stdin" \
  && ok "a token with \\ and \" is escaped for the curl config" \
  || note "token escaping is wrong: $(cat "$T/last-stdin")"
[[ "$(cat "$T/max-time" 2>/dev/null)" == 5 ]] \
  && ok "HARVEST_MAX_TIME reaches curl as --max-time" || note "--max-time did not reach curl"

# Unknown keys in the config are not exported; a malformed line does not abort.
printf 'HARVEST_EVIL=1\nnot a key value line\n9BAD=1\n' >> "$HARVEST_CONFIG"
if bash "$H" me >/dev/null 2>&1 && [[ -z "$(tail -1 "$T/env.log")" ]]; then
  ok "config loader exports only the HARVEST_* keys setup writes"
else
  note "config loader exported a foreign key or aborted on a malformed line"
fi

# ----------------------------------------------------- dangling option flag ---
echo '[{"date":"2026-10-14","hours":2}]' > "$T/b.json"
for args in "log-batch $T/b.json --project 1 --task" "log 2026-10-14 2 --project" \
            "entries 2026-10-14 2026-10-15 --project" "log 2026-10-14 2 --notes-file"; do
  # shellcheck disable=SC2086
  timeout 10 bash "$H" $args >/dev/null 2>&1; rc=$?
  [[ "$rc" -eq 1 ]] && ok "trailing flag fails fast: ${args%% *} … ${args##* }" \
                    || note "trailing flag gave rc=$rc (124 = hang): $args"
done
timeout 10 bash "$H" update 5 --hours >/dev/null 2>&1; rc=$?
[[ "$rc" -eq 1 ]] && ok "trailing flag fails fast: update … --hours" || note "update trailing flag gave rc=$rc"

bash "$H" log 2026-10-14 2 --project 1 --task 21 --notes-file "$T/missing" >/dev/null 2>&1 \
  && note "--notes-file with a missing file still logged" || ok "--notes-file with a missing file is refused"
bash "$H" entries 2026-10-14 2026-10-15 --project '1&user_id=9' >/dev/null 2>&1 \
  && note "entries accepted a non-numeric --project" || ok "entries refuses a non-numeric --project"

# ---------------------------------------------------------- row validation ---
reset_posts
for bad in '[5]' '[{"date":"2026-10-14","hours":2,"notes":5}]' '[{"date":"2026-10-14","hours":"2"}]' \
           '[{"date":"2026-13-45","hours":2}]' '{"date":"2026-10-14"}'; do
  printf '%s\n' "$bad" > "$T/bad.json"
  bash "$H" log-batch "$T/bad.json" --project 1 --task 21 >/dev/null 2>&1; rc=$?
  [[ "$rc" -eq 1 ]] && ok "log-batch rejects $bad" || note "log-batch gave rc=$rc for $bad"
done
[[ "$(posts)" -eq 0 ]] && ok "no request was sent for an invalid batch" || note "an invalid batch still POSTed"

# ----------------------------------------------- batch, write-back, rerun ---
reset_posts
cat > "$T/batch.json" <<'EOF'
[{"date":"2026-10-13","hours":3,"notes":"done","entry_id":50},
 {"date":"2026-10-14","hours":7.5,"notes":"a\nb"},
 {"date":"2026-10-15","hours":2,"notes":null},
 {"date":"2026-10-16","hours":4,"skip":true}]
EOF
bash "$H" log-batch "$T/batch.json" --project 1 --task 21 >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 && "$(posts)" -eq 2 ]] \
   && jq -e '.[1].entry_id == 101 and .[2].entry_id == 102 and .[0].entry_id == 50 and (.[3] | has("entry_id") | not)' "$T/batch.json" >/dev/null; then
  ok "log-batch skips logged and skipped rows and writes each entry_id back"
else
  note "log-batch rc=$rc posts=$(posts): $(jq -c . "$T/batch.json")"
fi
reset_posts
out="$(bash "$H" log-batch "$T/batch.json" --project 1 --task 21 2>/dev/null)"
[[ "$out" == "[]" && "$(posts)" -eq 0 ]] && ok "a rerun of a finished batch sends nothing" || note "rerun posted $(posts) rows"

bash "$H" log-batch "$T/batch.json" --project 1 --task 21 --force >/dev/null 2>&1
jq -e '.[0].entry_id == 103 and .[0].previous_entry_ids == [50] and .[1].previous_entry_ids == [101]' "$T/batch.json" >/dev/null \
  && ok "--force keeps the replaced ids under previous_entry_ids" \
  || note "--force lost an id: $(jq -c . "$T/batch.json")"

# Leading zeros pass is_hours / is_id and jq reads them as numbers (007 → 7);
# guard that, so a stricter jq would fail here rather than mid-batch.
reset_posts
bash "$H" log 2026-10-24 007.50 --project 001 --task 021 --notes x >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]] && jq -e '.hours == 7.5 and .project_id == 1 and .task_id == 21' "$T/posts.log" >/dev/null 2>&1; then
  ok "log normalises leading-zero hours and ids to JSON numbers"
else
  note "leading zeros: rc=$rc body=$(cat "$T/posts.log" 2>/dev/null)"
fi
echo '[{"date":"2026-10-24","hours":1}]' > "$T/z.json"
bash "$H" log-batch "$T/z.json" --project 001 --task 021 --dry-run 2>/dev/null | jq -e '.[0].project_id == 1 and .[0].task_id == 21' >/dev/null \
  && ok "log-batch --dry-run normalises leading-zero ids" || note "log-batch --dry-run failed on leading-zero ids"

# --------------------------------------------- partial failure and resume ---
reset_posts
echo '[{"date":"2026-10-20","hours":1},{"date":"2026-10-21","hours":1},{"date":"2026-10-22","hours":1}]' > "$T/p.json"
echo 2026-10-21 > "$T/fail-on"
bash "$H" log-batch "$T/p.json" --project 1 --task 21 >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 2 ]] && jq -e '(.[0].entry_id | type) == "number" and .[1].entry_id == null and .[2].entry_id == null' "$T/p.json" >/dev/null; then
  ok "a refused row stops the batch with exit 2 and keeps the rows before it"
else
  note "partial failure rc=$rc: $(jq -c . "$T/p.json")"
fi
reset_posts
bash "$H" log-batch "$T/p.json" --project 1 --task 21 >/dev/null 2>&1
[[ "$(posts)" -eq 2 ]] && jq -e 'all(.[]; .entry_id != null)' "$T/p.json" >/dev/null \
  && ok "the rerun logs only the rows that were missing" || note "resume posted $(posts) rows"

reset_posts; touch "$T/no-id"
echo '[{"date":"2026-10-23","hours":1}]' > "$T/n.json"
bash "$H" log-batch "$T/n.json" --project 1 --task 21 >/dev/null 2>&1; rc=$?
[[ "$rc" -eq 2 ]] && jq -e '.[0] | has("entry_id") | not' "$T/n.json" >/dev/null \
  && ok "a reply without an entry id stops the batch, writes no null id" || note "no-id reply rc=$rc: $(cat "$T/n.json")"

# ------------------------------------------------------------- paged reads ---
n="$(bash "$H" projects 2>/dev/null | jq 'length')"
[[ "$n" == 2 ]] && ok "projects follows links.next and drops inactive assignments" || note "projects returned $n (want 2)"
n="$(bash "$H" entries 2026-10-14 2026-10-15 2>/dev/null | jq 'length')"
[[ "$n" == 100 ]] && ok "entries reads a page over 128 KiB (no E2BIG)" || note "entries returned '$n' rows from a large page (want 100)"

# ------------------------------------------------------------------ update ---
rm -f "$T/patches.log"
bash "$H" update 55 --hours 2.5 --notes $'a\nb' >/dev/null 2>&1; rc=$?
if [[ "$rc" -eq 0 ]] && grep -q '^55 ' "$T/patches.log" \
   && sed 's/^55 //' "$T/patches.log" | jq -e '.hours == 2.5 and .notes == "a\nb"' >/dev/null; then
  ok "update PATCHes the hours and notes of the given entry"
else
  note "update rc=$rc: $(cat "$T/patches.log" 2>/dev/null)"
fi
rm -f "$T/patches.log"
bash "$H" update 55 --notes "" >/dev/null 2>&1
sed 's/^55 //' "$T/patches.log" 2>/dev/null | jq -e '. == {notes: ""}' >/dev/null \
  && ok "update with only --notes leaves the hours alone" || note "update --notes sent: $(cat "$T/patches.log" 2>/dev/null)"
for args in "update 55" "update x --hours 1" "update 55 --hours 25"; do
  # shellcheck disable=SC2086
  bash "$H" $args >/dev/null 2>&1 && note "update accepted: $args" || ok "update refuses: $args"
done

# ---------------------------------------------------------------- the page ---
if ! command -v python3 >/dev/null 2>&1; then
  echo "  (python3 absent — skipping harvest-app)"; exit "$FAIL"
fi
rm -f "$T/patches.log"
cat > "$T/app.json" <<'JSON'
[{"date":"2026-10-15","hours":3,"notes":"proposal"},{"date":"2026-10-14","hours":2,"notes":"edit me"}]
JSON
export HARVEST_PROJECTS="$T/home/projects.json"
echo '["not", "a map"]' > "$HARVEST_PROJECTS"
python3 "$A" "$T/app.json" --from 2026-10-13 --to 2026-10-15 --project 1 --repo /repo/a --task-name Dev \
  > "$T/app.out" 2> "$T/app.err" &
app_pid=$!
for _ in $(seq 50); do [[ -s "$T/app.out" ]] && break; sleep 0.1; done
url="$(head -1 "$T/app.out")"
if [[ "$url" =~ ^http://127\.0\.0\.1:[0-9]+/#k=.+ ]]; then
  ok "harvest-app prints a loopback URL carrying the key in the fragment"
  APP_URL="$url" BATCH="$T/app.json" python3 scripts/test-harvest-app.py || FAIL=1
else
  note "harvest-app did not start: $(cat "$T/app.err")"
fi
for _ in $(seq 50); do kill -0 "$app_pid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$app_pid" 2>/dev/null; then
  kill "$app_pid"; note "harvest-app kept running after done"
elif grep -q '"exit": "done"' "$T/app.out" && grep -q '"action": "created"' "$T/app.out"; then
  ok "harvest-app exits on done and prints each applied entry"
else
  note "harvest-app stdout: $(cat "$T/app.out")"
fi
python3 "$A" "$T/app.json" --from 2026-10-15 --to 2026-10-13 >/dev/null 2>&1 \
  && note "harvest-app accepted a backwards window" || ok "harvest-app refuses a backwards window"
echo '[{"date":"2026-10-14","hours":1},{"date":"2026-10-14","hours":2}]' > "$T/dup.json"
python3 "$A" "$T/dup.json" --from 2026-10-13 --to 2026-10-15 >/dev/null 2>&1 \
  && note "harvest-app accepted a batch with a date twice" || ok "harvest-app refuses a batch with a date twice"

# A project remembered for the repo wins over the guess.
echo '{"/repo/a": 1}' > "$HARVEST_PROJECTS"
python3 "$A" "$T/app.json" --from 2026-10-13 --to 2026-10-15 --project 2 --repo /repo/a --task-name Dev \
  > "$T/app2.out" 2>/dev/null &
app_pid=$!
for _ in $(seq 50); do [[ -s "$T/app2.out" ]] && break; sleep 0.1; done
APP_URL="$(head -1 "$T/app2.out")" MODE=remembered python3 scripts/test-harvest-app.py \
  && ok "a project remembered for the repo wins over the guess" || note "the remembered project did not win"
wait "$app_pid" 2>/dev/null

exit "$FAIL"
