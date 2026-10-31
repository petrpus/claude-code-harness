#!/usr/bin/env bash
# skills/worklog/clockify.sh — Clockify API v1 helper for /worklog --clockify.
#
# Plain curl + jq against api.clockify.me; no MCP server, no SDK. Same command
# contract and JSON shapes as harvest.sh, so worklog-app.py drives either. The
# API key never leaves this machine: it is read from a config file (or the
# environment), handed to curl through a config on stdin (never argv, so it is
# not in `ps`), and sent only to Clockify.
#
# Clockify stores intervals, not hours. A new entry starts at
# $CLOCKIFY_DAY_START (default 09:00) in the user's Clockify time zone, or
# right after the user's last entry of that day when that ends later. A new
# number of hours keeps an entry's start and moves its end. An entry's date is
# the local date of its start; entries still running are left out.
#
# Config, first match wins per key:
#   environment:  CLOCKIFY_API_KEY, CLOCKIFY_WORKSPACE_ID, CLOCKIFY_USER_ID,
#                 CLOCKIFY_TIMEZONE, CLOCKIFY_API_BASE
#   file:         $CLOCKIFY_CONFIG, default ~/.config/clockify/env
#                 (KEY=VALUE lines, written by `setup`, mode 0600)
# CLOCKIFY_API_BASE defaults to https://api.clockify.me/api/v1; a workspace on
# a regional server needs that server's base (e.g. https://euc1.clockify.me/api/v1).
#
# Commands (every one prints JSON unless --text is given):
#   setup [workspace]              read the key from $CLOCKIFY_API_KEY or a
#                                  hidden prompt (never argv), resolve the
#                                  workspace (exact name or id, then name
#                                  substring), and write the config file with
#                                  the workspace, user id and time zone
#   workspaces                     workspaces the key can see
#   me                             the current user and the configured workspace
#   projects [--text]              active projects with their active tasks
#   entries <from> <to> [--project ID] [--text]
#                                  the current user's finished entries in the window
#   log <date> <hours> --project ID [--task ID] [--billable true|false]
#       [--notes TEXT|--notes-file F]
#                                  create one entry; billable defaults to the
#                                  project's setting
#   update <entry_id> [--hours H] [--notes TEXT|--notes-file F]
#                                  change the hours and/or notes of an entry,
#                                  keeping its project, task, tags and billable
#   delete <entry_id>              delete an entry (undo for log)
#
# Exit codes: 0 ok · 1 usage/config error (also: curl or jq missing, a network
# failure, an unparseable response) · 2 Clockify refused (HTTP ≥ 400, so a
# revoked key is 2, not 1).

set -uo pipefail

DEFAULT_API="https://api.clockify.me/api/v1"
CONFIG="${CLOCKIFY_CONFIG:-$HOME/.config/clockify/env}"
UA="code-harness worklog (https://github.com/petrpus/claude-code-harness)"
# A hung connection must not block the page forever.
CONNECT_TIMEOUT="${CLOCKIFY_CONNECT_TIMEOUT:-10}"
MAX_TIME="${CLOCKIFY_MAX_TIME:-60}"
DAY_START="${CLOCKIFY_DAY_START:-09:00}"
PAGE_SIZE="${CLOCKIFY_PAGE_SIZE:-200}"
MAX_PAGES=100

die()   { echo "clockify: $*" >&2; exit 1; }
usage() { sed -n '2,/^[^#]/{/^#/p}' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v jq   >/dev/null 2>&1 || die "jq is required"
[[ "$DAY_START" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "CLOCKIFY_DAY_START must be HH:MM"
[[ "$PAGE_SIZE" =~ ^[1-9][0-9]*$ ]] || die "CLOCKIFY_PAGE_SIZE must be a positive integer"

# ---------------------------------------------------------------- config ---
load_config() {
  if [[ -f "$CONFIG" ]]; then
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
      key="${line%%=*}"; val="${line#*=}"
      key="${key//[[:space:]]/}"
      # Only the keys `setup` writes. Anything else is not ours to export, and
      # an invalid name would abort the `${!key}` below.
      case "$key" in
        CLOCKIFY_API_KEY|CLOCKIFY_WORKSPACE_ID|CLOCKIFY_WORKSPACE_NAME|CLOCKIFY_USER_ID|CLOCKIFY_TIMEZONE|CLOCKIFY_API_BASE) ;;
        *) continue ;;
      esac
      # Environment wins over the file.
      [[ -n "${!key:-}" ]] && continue
      export "$key=$val"
    done < "$CONFIG"
  fi
}
set_api() { API="${CLOCKIFY_API_BASE:-$DEFAULT_API}"; API="${API%/}"; }
need_key()       { [[ -n "${CLOCKIFY_API_KEY:-}" ]] || die "no API key — run: clockify.sh setup [workspace]  (or export CLOCKIFY_API_KEY)"; }
need_workspace() {
  [[ -n "${CLOCKIFY_WORKSPACE_ID:-}" ]] || die "no workspace id — run: clockify.sh setup [workspace]  (or export CLOCKIFY_WORKSPACE_ID)"
  is_cid "$CLOCKIFY_WORKSPACE_ID" || die "CLOCKIFY_WORKSPACE_ID is not a Clockify id: $CLOCKIFY_WORKSPACE_ID"
  WS_URL="$API/workspaces/$CLOCKIFY_WORKSPACE_ID"
}

# need_val OPTION "$@-from-the-option-on": an option that takes a value must
# have one, or `shift 2` fails and the option loop never advances.
need_val() { [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 needs a value"; }

# ------------------------------------------------------------------ http ---
# request METHOD URL [JSON-BODY] → body on stdout; exit 2 on HTTP ≥ 400.
request() {
  local method="$1" url="$2" body="${3:-}" out code key
  # The key header goes in through `-K -` (a curl config on stdin) so it is
  # never part of curl's argv.
  local -a args=(-sS -K - -X "$method" "$url"
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME"
    -H "User-Agent: $UA" -H "Accept: application/json")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data "$body")
  # A curl config string treats \ as an escape: escape it before the quotes.
  key="${CLOCKIFY_API_KEY//\\/\\\\}"; key="${key//\"/\\\"}"
  [[ "$key" == *[$'\r\n']* ]] && die "the API key contains a line break"
  out="$(printf 'header = "X-Api-Key: %s"\n' "$key" \
        | curl "${args[@]}" -w $'\n%{http_code}' 2>&1)" || die "curl failed: $out"
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  [[ "$code" =~ ^[0-9]{3}$ ]] || die "no HTTP status from $method ${url#"$API"}"
  if [[ "$code" -ge 400 ]]; then
    echo "clockify: HTTP $code from $method ${url#"$API"}: $(jq -r '.message // .error // .' <<<"$out" 2>/dev/null || echo "$out")" >&2
    exit 2
  fi
  printf '%s' "$out"
}

# paged URL → every page of a JSON-array endpoint, concatenated. Clockify
# pages by page/page-size and has no next link: a short page is the last one.
paged() {
  local url="$1" sep='?' page n p=1 acc='[]'
  [[ "$url" == *\?* ]] && sep='&'
  while :; do
    page="$(request GET "$url${sep}page=$p&page-size=$PAGE_SIZE")" || exit $?
    # Both documents go in on stdin: a large page passed with --argjson can
    # exceed the 128 KiB argv limit for one argument (the E2BIG of #119).
    acc="$(printf '%s\n%s' "$acc" "$page" | jq -cs 'if (.[1]|type) == "array" then .[0] + .[1] else error("not an array") end')" \
      || die "unreadable page from Clockify: ${url#"$API"}"
    n="$(jq 'length' <<<"$page")" || die "unreadable page from Clockify: ${url#"$API"}"
    [[ "$n" -lt "$PAGE_SIZE" ]] && break
    p=$((p + 1))
    [[ "$p" -le "$MAX_PAGES" ]] || die "more than $MAX_PAGES pages from ${url#"$API"}"
  done
  printf '%s' "$acc"
}

# ---------------------------------------------------------------- checks ---
is_date()  { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -d "$1" >/dev/null 2>&1; }
is_hours() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v h="$1" 'BEGIN{exit !(h>0 && h<=24)}'; }
is_cid()   { [[ "$1" =~ ^[0-9a-fA-F]{24}$ ]]; }

# ----------------------------------------------------------------- times ---
# The user's Clockify time zone (empty: this machine's). An unknown zone name
# would make GNU date fall back to UTC silently and shift days, so setup
# refuses to store one.
tz() { printf '%s' "${CLOCKIFY_TIMEZONE:-}"; }
# local_to_utc DATE HH:MM[:SS] → that wall-clock time in the user's zone, as UTC ISO.
local_to_utc() {
  local spec="$1 $2"
  [[ -n "$(tz)" ]] && spec="TZ=\"$(tz)\" $spec"
  date -u -d "$spec" +%Y-%m-%dT%H:%M:%SZ
}
epoch_of() { date -u -d "$1" +%s; }
iso_of()   { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
# local_dates — stdin: one UTC ISO instant per line; stdout: its local date.
local_dates() {
  if [[ -n "$(tz)" ]]; then TZ="$(tz)" date -f - +%F; else date -f - +%F; fi
}
seconds_of_hours() { awk -v h="$1" 'BEGIN{printf "%d", h * 3600 + 0.5}'; }

user_id() {
  if [[ -n "${CLOCKIFY_USER_ID:-}" ]]; then
    is_cid "$CLOCKIFY_USER_ID" || die "CLOCKIFY_USER_ID is not a Clockify id: $CLOCKIFY_USER_ID"
    printf '%s' "$CLOCKIFY_USER_ID"
  else
    local id
    id="$(request GET "$API/user" | jq -r '.id')" || exit $?
    is_cid "$id" || die "Clockify returned no user id"
    printf '%s' "$id"
  fi
}

# normalize — stdin: raw Clockify entries; stdout: [{id, start, end, hours,
# project_id, project, task_id, task, notes}] without the running ones.
normalize() {
  jq -c 'def ts: sub("\\.[0-9]+Z$"; "Z");
    [.[] | select(.timeInterval.end != null)
     | {id,
        start: (.timeInterval.start | ts), end: (.timeInterval.end | ts),
        project_id: (.projectId // .project.id // null), project: (.project.name // null),
        task_id: ((.taskId // .task.id // "") | if . == "" then null else . end), task: (.task.name // null),
        notes: (.description // "")}
     | .hours = ((((.end | fromdate) - (.start | fromdate)) / 36 | round) / 100)]'
}

# with_dates — stdin: normalized entries; stdout: the same, each with the
# local date of its start.
with_dates() {
  local json dates
  json="$(cat)"
  dates="$(jq -r '.[].start' <<<"$json" | local_dates | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    || die "could not convert entry times to dates"
  printf '%s\n%s' "$json" "$dates" | jq -cs '.[1] as $d | [.[0] | to_entries[] | .value + {date: $d[.key]}]'
}

# fetch_entries FROM TO [PROJECT] → the user's finished entries whose start
# falls on a local date in [FROM, TO], sorted by date and start.
fetch_entries() {
  local from="$1" to="$2" project="${3:-}" uid s e url
  uid="$(user_id)" || exit $?
  # Noon of the day before and after, not midnight: in a few zones local
  # midnight falls in a DST gap and GNU date rejects it. The date filter
  # below trims the padding.
  s="$(local_to_utc "$(date -d "$from -1 day" +%F)" 12:00:00)" && e="$(local_to_utc "$(date -d "$to +1 day" +%F)" 12:00:00)" \
    || die "could not convert $from–$to to UTC"
  url="$WS_URL/user/$uid/time-entries?start=$s&end=$e&hydrated=true"
  [[ -n "$project" ]] && url="$url&project=$project"
  paged "$url" | normalize | with_dates \
    | jq -c --arg f "$from" --arg t "$to" '[.[] | select(.date >= $f and .date <= $t)] | sort_by(.date, .start)'
}

# -------------------------------------------------------------- commands ---
cmd_setup() {
  local want="${1:-}" key="${CLOCKIFY_API_KEY:-}"
  [[ "$want" == -* ]] && die "usage: clockify.sh setup [workspace-name-or-id]  (key via \$CLOCKIFY_API_KEY or the prompt)"
  if [[ -z "$key" ]]; then
    # Hidden prompt on the terminal, plain stdin otherwise (pipes, tests):
    # the key must not appear on a command line or in shell history.
    if [[ -t 0 ]]; then read -rs -p "Clockify API key: " key; echo; else IFS= read -r key; fi
  fi
  [[ -n "$key" ]] || die "no API key given"
  CLOCKIFY_API_KEY="$key"
  local user workspaces chosen
  user="$(request GET "$API/user")" || exit $?
  workspaces="$(request GET "$API/workspaces" | jq -c '[.[] | {id, name}]')" || exit $?
  [[ "$(jq 'length' <<<"$workspaces")" -gt 0 ]] || die "the key sees no Clockify workspace"
  if [[ -n "$want" ]]; then
    # Exact id or exact name (case-insensitive) wins; only when nothing
    # matches exactly does a substring count, so "Acme" is not ambiguous
    # beside "Acme Sandbox".
    chosen="$(jq -c --arg w "$want" '
      ($w | ascii_downcase) as $lw
      | ([.[] | select(.id == $w or (.name|ascii_downcase) == $lw)]) as $exact
      | if ($exact|length) > 0 then $exact else [.[] | select(.name|ascii_downcase|contains($lw))] end' <<<"$workspaces")"
  else
    chosen="$workspaces"
  fi
  case "$(jq 'length' <<<"$chosen")" in
    1) ;;
    0) echo "no workspace matches '$want'. Available:" >&2; jq -r '.[] | "  \(.id)\t\(.name)"' <<<"$workspaces" >&2; exit 1 ;;
    *) echo "several workspaces match — give the exact name or the id:" >&2; jq -r '.[] | "  \(.id)\t\(.name)"' <<<"$chosen" >&2; exit 1 ;;
  esac
  local id name uid zone
  id="$(jq -r '.[0].id' <<<"$chosen")"; name="$(jq -r '.[0].name' <<<"$chosen")"
  uid="$(jq -r '.id // empty' <<<"$user")"; zone="$(jq -r '.settings.timeZone // empty' <<<"$user")"
  is_cid "$id" || die "Clockify returned a malformed workspace id: $id"
  is_cid "$uid" || die "Clockify returned a malformed user id: $uid"
  if [[ -n "$zone" ]] && { [[ ! "$zone" =~ ^[A-Za-z0-9_+/-]+$ ]] || { [[ -d /usr/share/zoneinfo ]] && [[ ! -f "/usr/share/zoneinfo/$zone" ]]; }; }; then
    echo "clockify: unknown time zone '$zone' in the Clockify profile — using this machine's; set CLOCKIFY_TIMEZONE to override" >&2
    zone=""
  fi
  # One KEY=VALUE per line: a line break in the name must not start a new key.
  name="${name//[$'\r\n']/ }"
  mkdir -p "$(dirname "$CONFIG")"
  umask 077
  {
    printf 'CLOCKIFY_API_KEY=%s\nCLOCKIFY_WORKSPACE_ID=%s\nCLOCKIFY_WORKSPACE_NAME=%s\n' "$key" "$id" "$name"
    printf 'CLOCKIFY_USER_ID=%s\nCLOCKIFY_TIMEZONE=%s\n' "$uid" "$zone"
    [[ "$API" != "$DEFAULT_API" ]] && printf 'CLOCKIFY_API_BASE=%s\n' "$API"
  } > "$CONFIG"
  chmod 600 "$CONFIG"
  # Not "${zone:-…'s}": bash reads a ' inside ${…} in double quotes as a quote.
  local shown="$zone"; [[ -n "$shown" ]] || shown="this machine's"
  echo "wrote $CONFIG — workspace $id ($name), time zone $shown"
}

cmd_workspaces() {
  need_key
  request GET "$API/workspaces" | jq '[.[] | {id, name}]'
}

cmd_me() {
  need_key; need_workspace
  request GET "$API/user" | jq --arg ws "$CLOCKIFY_WORKSPACE_ID" --arg wn "${CLOCKIFY_WORKSPACE_NAME:-}" --arg tz "$(tz)" \
    '{id, name, email, timezone: (if $tz != "" then $tz else (.settings.timeZone // null) end), workspace_id: $ws, workspace: $wn}'
}

cmd_projects() {
  need_key; need_workspace
  local text=0; [[ "${1:-}" == "--text" ]] && text=1
  local json missing id tasks taskmap='{}'
  json="$(paged "$WS_URL/projects?archived=false&hydrated=true")" || exit $?
  # A hydrated project usually carries its tasks; one without the field gets
  # them from the project's own task list.
  missing="$(jq -r '.[] | select(.archived != true and .tasks == null) | .id' <<<"$json")" || die "unreadable projects from Clockify"
  for id in $missing; do
    is_cid "$id" || die "Clockify returned a malformed project id: $id"
    tasks="$(paged "$WS_URL/projects/$id/tasks?is-active=true")" || exit $?
    taskmap="$(printf '%s\n%s' "$taskmap" "$tasks" | jq -cs --arg id "$id" '.[0] + {($id): .[1]}')" || die "unreadable tasks of project $id"
  done
  json="$(printf '%s\n%s' "$json" "$taskmap" | jq -s '.[1] as $tm | [.[0][] | select(.archived != true) | {
      project_id: .id, project: .name, code: "", client: (.clientName // ""), billable: (.billable == true),
      tasks: [(.tasks // $tm[.id] // [])[] | select((.status // "ACTIVE") == "ACTIVE") | {task_id: .id, task: .name}]
    }] | sort_by(.client, .project)')" || die "unreadable projects from Clockify"
  if [[ "$text" -eq 1 ]]; then
    jq -r '.[] | "\(.project_id)\t\(if .client != "" then .client + " / " else "" end)\(.project)\(if .tasks == [] then " (no tasks)" else "" end)",
                 (.tasks[] | "\t\(.task_id)\t\(.task)")' <<<"$json"
  else
    printf '%s\n' "$json"
  fi
}

cmd_entries() {
  need_key; need_workspace
  local from="${1:-}" to="${2:-}"; shift 2 2>/dev/null || die "usage: clockify.sh entries <from> <to> [--project ID] [--text]"
  is_date "$from" && is_date "$to" || die "dates must be YYYY-MM-DD"
  local project="" text=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project) need_val "$@"; project="$2"; shift 2 ;;
      --text) text=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ -z "$project" ]] || is_cid "$project" || die "--project must be a Clockify id"
  local json
  json="$(fetch_entries "$from" "$to" "$project")" || exit $?
  if [[ "$text" -eq 1 ]]; then
    jq -r 'group_by(.date)[] | "\(.[0].date)\t\(map(.hours) | add) h\t" + (map("\(.project // "no project") / \(.task // "no task") \(.hours) h") | join("; "))' <<<"$json"
  else
    jq '.' <<<"$json"
  fi
}

cmd_log() {
  need_key; need_workspace
  local d="${1:-}" h="${2:-}"; shift 2 2>/dev/null || die "usage: clockify.sh log <date> <hours> --project ID [--task ID] [--billable true|false] [--notes TEXT|--notes-file F]"
  local project="" task="" billable="" notes=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project) need_val "$@"; project="$2"; shift 2 ;;
      --task) need_val "$@"; task="$2"; shift 2 ;;
      --billable) need_val "$@"; billable="$2"; shift 2 ;;
      # Empty notes are legitimate, so --notes only needs a next word.
      --notes) [[ $# -ge 2 ]] || die "--notes needs a value"; notes="$2"; shift 2 ;;
      --notes-file) need_val "$@"; [[ -r "$2" ]] || die "cannot read $2"; notes="$(cat "$2")"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  is_date "$d" || die "date must be YYYY-MM-DD"
  is_hours "$h" || die "hours must be a number in (0, 24]"
  is_cid "$project" || die "--project must be a Clockify id"
  [[ -z "$task" ]] || is_cid "$task" || die "--task must be a Clockify id"
  case "$billable" in
    true|false) ;;
    "") billable="$(request GET "$WS_URL/projects/$project" | jq -r '.billable == true')" || exit $? ;;
    *) die "--billable must be true or false" ;;
  esac
  # Start at the day's start, or after the user's last entry of that day.
  local day latest start_e end_e
  day="$(fetch_entries "$d" "$d")" || exit $?
  latest="$(jq -r '[.[].end | fromdate] | max // empty' <<<"$day")" || die "unreadable entries of $d"
  start_e="$(epoch_of "$(local_to_utc "$d" "$DAY_START")")" || die "could not convert $d $DAY_START"
  # After the last entry, unless that one runs past midnight: an entry's date
  # is the local date of its start, so it must not start on the next day.
  if [[ -n "$latest" && "$latest" -gt "$start_e" ]] && [[ "$(iso_of "$latest" | local_dates)" == "$d" ]]; then
    start_e="$latest"
  fi
  end_e=$((start_e + $(seconds_of_hours "$h")))
  local body
  body="$(jq -nc --arg s "$(iso_of "$start_e")" --arg e "$(iso_of "$end_e")" --argjson b "$billable" \
      --arg p "$project" --arg t "$task" --arg n "$notes" \
    '{start: $s, end: $e, billable: $b, description: $n, projectId: $p} + (if $t != "" then {taskId: $t} else {} end)')"
  request POST "$WS_URL/time-entries" "$body" \
    | jq -c --arg d "$d" --argjson h "$h" '{id, date: $d, hours: $h, project_id: .projectId, task_id: (.taskId // null)}'
}

cmd_update() {
  need_key; need_workspace
  local id="${1:-}"; shift 1 2>/dev/null || true
  is_cid "$id" || die "usage: clockify.sh update <entry_id> [--hours H] [--notes TEXT|--notes-file F]"
  local h="" notes="" has_notes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hours) need_val "$@"; h="$2"; shift 2 ;;
      --notes) [[ $# -ge 2 ]] || die "--notes needs a value"; notes="$2"; has_notes=1; shift 2 ;;
      --notes-file) need_val "$@"; [[ -r "$2" ]] || die "cannot read $2"; notes="$(cat "$2")"; has_notes=1; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ -n "$h" || "$has_notes" -eq 1 ]] || die "update needs --hours and/or --notes"
  [[ -z "$h" ]] || is_hours "$h" || die "hours must be a number in (0, 24]"
  # PUT replaces the whole entry: read it first and send back everything this
  # update does not change, or its tags, billable flag and fields are lost.
  local entry start end
  entry="$(request GET "$WS_URL/time-entries/$id")" || exit $?
  start="$(jq -r '.timeInterval.start // empty | sub("\\.[0-9]+Z$"; "Z")' <<<"$entry")" || die "unreadable entry $id"
  end="$(jq -r '.timeInterval.end // empty | sub("\\.[0-9]+Z$"; "Z")' <<<"$entry")" || die "unreadable entry $id"
  [[ -n "$start" ]] || die "entry $id has no start"
  [[ -n "$end" ]] || die "entry $id is still running — stop it in Clockify first"
  [[ -n "$h" ]] && end="$(iso_of $(( $(epoch_of "$start") + $(seconds_of_hours "$h") )))"
  local body
  body="$(jq -c --arg s "$start" --arg e "$end" --arg n "$notes" --argjson hn "$has_notes" '
    {start: $s, end: $e, billable: (.billable == true),
     description: (if $hn == 1 then $n else (.description // "") end),
     projectId: .projectId, taskId: ((.taskId // "") | if . == "" then null else . end),
     tagIds: (.tagIds // []), type: (.type // "REGULAR")}
    + (if ((.customFieldValues // []) | length) > 0
       then {customFields: [.customFieldValues[] | {customFieldId, value}]} else {} end)
    | with_entries(select(.value != null))' <<<"$entry")" || die "unreadable entry $id"
  local out date
  out="$(request PUT "$WS_URL/time-entries/$id" "$body")" || exit $?
  date="$(printf '%s\n' "$start" | local_dates)" || die "could not convert $start to a date"
  jq -c --arg d "$date" --arg s "$start" --arg e "$end" \
    '{id, date: $d, hours: (((($e | fromdate) - ($s | fromdate)) / 36 | round) / 100), project_id: .projectId, task_id: (.taskId // null)}' <<<"$out"
}

cmd_delete() {
  need_key; need_workspace
  local id="${1:-}"
  is_cid "$id" || die "usage: clockify.sh delete <entry_id>"
  request DELETE "$WS_URL/time-entries/$id" >/dev/null && echo "deleted entry $id"
}

# ------------------------------------------------------------------ main ---
cmd="${1:-}"; shift 1 2>/dev/null || true
# `setup` replaces the config, so it must not read the key it is replacing:
# a rerun after the key was revoked would silently write the stale one back.
[[ "$cmd" == setup ]] || load_config
set_api
case "$cmd" in
  setup)      cmd_setup "$@" ;;
  workspaces) cmd_workspaces "$@" ;;
  me)         cmd_me "$@" ;;
  projects)   cmd_projects "$@" ;;
  entries)    cmd_entries "$@" ;;
  log)        cmd_log "$@" ;;
  update)     cmd_update "$@" ;;
  delete)     cmd_delete "$@" ;;
  -h|--help|help|"") usage ;;
  *) die "unknown command: $cmd (try --help)" ;;
esac
