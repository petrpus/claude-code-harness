#!/usr/bin/env bash
# skills/worklog/harvest.sh — Harvest API v2 helper for /worklog --harvest.
#
# Plain curl + jq against api.harvestapp.com; no MCP server, no SDK. The token
# never leaves this machine: it is read from a config file (or the environment),
# handed to curl through a config on stdin (never argv, so it is not in `ps`),
# and sent only to Harvest.
#
# Config, first match wins per key:
#   environment:  HARVEST_ACCESS_TOKEN, HARVEST_ACCOUNT_ID
#   file:         $HARVEST_CONFIG, default ~/.config/harvest/env
#                 (KEY=VALUE lines, written by `setup`, mode 0600)
#
# Commands (every one prints JSON unless --text is given):
#   setup [account]                read the token from $HARVEST_ACCESS_TOKEN or
#                                  a hidden prompt (never argv), resolve the
#                                  account (exact name, then name substring,
#                                  or id) and write the config file
#   accounts                       accounts the token can see
#   me                             the current user
#   projects [--text]              active project assignments with their tasks
#   entries <from> <to> [--project ID] [--text]
#                                  the current user's time entries in the window
#   log <date> <hours> --project ID --task ID [--notes TEXT|--notes-file F]
#                                  create one time entry
#   log-batch <file.json> --project ID --task ID [--dry-run] [--force]
#                                  one entry per row of [{date,hours,notes}];
#                                  on success the row gets "entry_id" written
#                                  back into the file, and rows that already
#                                  carry one are skipped unless --force (which
#                                  keeps the old id under "previous_entry_ids")
#   delete <entry_id>              delete a time entry (undo for log/log-batch)
#
# Exit codes: 0 ok · 1 usage/config error (also: curl or jq missing, a network
# failure, an unparseable response) · 2 Harvest refused (HTTP ≥ 400, so an
# expired or revoked token is 2, not 1).

set -uo pipefail

API="${HARVEST_API_BASE:-https://api.harvestapp.com/v2}"
ID_API="${HARVEST_ID_API_BASE:-https://id.getharvest.com/api/v2}"
CONFIG="${HARVEST_CONFIG:-$HOME/.config/harvest/env}"
UA="code-harness worklog (https://github.com/petrpus/claude-code-harness)"
# A hung connection must not block a batch forever.
CONNECT_TIMEOUT="${HARVEST_CONNECT_TIMEOUT:-10}"
MAX_TIME="${HARVEST_MAX_TIME:-60}"

die()   { echo "harvest: $*" >&2; exit 1; }
usage() { sed -n '2,/^[^#]/{/^#/p}' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v jq   >/dev/null 2>&1 || die "jq is required"

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
        HARVEST_ACCESS_TOKEN|HARVEST_ACCOUNT_ID|HARVEST_ACCOUNT_NAME) ;;
        *) continue ;;
      esac
      # Environment wins over the file.
      [[ -n "${!key:-}" ]] && continue
      export "$key=$val"
    done < "$CONFIG"
  fi
}
need_token()   { [[ -n "${HARVEST_ACCESS_TOKEN:-}" ]] || die "no token — run: harvest.sh setup [account]  (or export HARVEST_ACCESS_TOKEN)"; }
need_account() { [[ -n "${HARVEST_ACCOUNT_ID:-}" ]]   || die "no account id — run: harvest.sh setup [account]  (or export HARVEST_ACCOUNT_ID)"; }

# need_val OPTION "$@-from-the-option-on": an option that takes a value must
# have one. Without this, `--task` as the last word made `shift 2` fail, and
# with no `set -e` the option loop never advanced.
need_val() { [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 needs a value"; }

# ------------------------------------------------------------------ http ---
# request METHOD URL [JSON-BODY] → body on stdout; exit 2 on HTTP ≥ 400.
request() {
  local method="$1" url="$2" body="${3:-}" out code tok
  # The bearer header goes in through `-K -` (a curl config on stdin) so the
  # token is never part of curl's argv.
  local -a args=(-sS -K - -X "$method" "$url"
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME"
    -H "User-Agent: $UA" -H "Accept: application/json")
  [[ "$url" == "$API"* && -n "${HARVEST_ACCOUNT_ID:-}" ]] && args+=(-H "Harvest-Account-Id: $HARVEST_ACCOUNT_ID")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data "$body")
  # A curl config string treats \ as an escape: escape it before the quotes.
  tok="${HARVEST_ACCESS_TOKEN//\\/\\\\}"; tok="${tok//\"/\\\"}"
  [[ "$tok" == *[$'\r\n']* ]] && die "the token contains a line break"
  out="$(printf 'header = "Authorization: Bearer %s"\n' "$tok" \
        | curl "${args[@]}" -w $'\n%{http_code}' 2>&1)" || die "curl failed: $out"
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  if [[ "$code" -ge 400 ]]; then
    echo "harvest: HTTP $code from $method ${url#"$API"}: $(jq -r '.message // .error_description // .error // .' <<<"$out" 2>/dev/null || echo "$out")" >&2
    exit 2
  fi
  printf '%s' "$out"
}

# paged URL KEY → concatenated JSON array of every page's KEY.
paged() {
  local url="$1" key="$2" page acc='[]'
  while [[ -n "$url" && "$url" != "null" ]]; do
    page="$(request GET "$url")" || exit $?
    # Both documents go in on stdin: a 100-row page passed with --argjson can
    # exceed the 128 KiB argv limit for one argument (the E2BIG of #119), and
    # an unchecked failure here returned a silently short list.
    acc="$(printf '%s\n%s' "$acc" "$page" | jq -cs --arg k "$key" '.[0] + (.[1][$k] // [])')" \
      || die "unreadable $key page from Harvest"
    url="$(jq -r '.links.next // empty' <<<"$page")" || die "unreadable $key page from Harvest"
  done
  printf '%s' "$acc"
}

# ---------------------------------------------------------------- checks ---
is_date()  { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -d "$1" >/dev/null 2>&1; }
is_hours() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v h="$1" 'BEGIN{exit !(h>0 && h<=24)}'; }
is_id()    { [[ "$1" =~ ^[0-9]+$ ]]; }

# -------------------------------------------------------------- commands ---
cmd_setup() {
  local want="${1:-}" token="${HARVEST_ACCESS_TOKEN:-}"
  [[ "$want" == -* ]] && die "usage: harvest.sh setup [account-name-or-id]  (token via \$HARVEST_ACCESS_TOKEN or the prompt)"
  if [[ -z "$token" ]]; then
    # Hidden prompt on the terminal, plain stdin otherwise (pipes, tests):
    # the token must not appear on a command line or in shell history.
    if [[ -t 0 ]]; then read -rs -p "Harvest personal access token: " token; echo; else IFS= read -r token; fi
  fi
  [[ -n "$token" ]] || die "no token given"
  HARVEST_ACCESS_TOKEN="$token"
  local accounts chosen n
  accounts="$(request GET "$ID_API/accounts" | jq -c '[.accounts[] | select(.product == "harvest") | {id, name}]')" || exit $?
  n="$(jq 'length' <<<"$accounts")"
  [[ "$n" -gt 0 ]] || die "the token sees no Harvest account"
  if [[ -n "$want" ]]; then
    # Exact id or exact name (case-insensitive) wins; only when nothing matches
    # exactly does a substring count, so "Acme" is not ambiguous beside
    # "Acme Sandbox".
    chosen="$(jq -c --arg w "$want" '
      ($w | ascii_downcase) as $lw
      | ([.[] | select((.id|tostring) == $w or (.name|ascii_downcase) == $lw)]) as $exact
      | if ($exact|length) > 0 then $exact else [.[] | select(.name|ascii_downcase|contains($lw))] end' <<<"$accounts")"
  else
    chosen="$accounts"
  fi
  case "$(jq 'length' <<<"$chosen")" in
    1) ;;
    0) echo "no account matches '$want'. Available:" >&2; jq -r '.[] | "  \(.id)\t\(.name)"' <<<"$accounts" >&2; exit 1 ;;
    *) echo "several accounts match — give the exact name or the id:" >&2; jq -r '.[] | "  \(.id)\t\(.name)"' <<<"$chosen" >&2; exit 1 ;;
  esac
  local id name
  id="$(jq -r '.[0].id' <<<"$chosen")"; name="$(jq -r '.[0].name' <<<"$chosen")"
  is_id "$id" || die "Harvest returned a non-numeric account id: $id"
  # One KEY=VALUE per line: a line break in the name must not start a new key.
  name="${name//[$'\r\n']/ }"
  mkdir -p "$(dirname "$CONFIG")"
  umask 077
  printf 'HARVEST_ACCESS_TOKEN=%s\nHARVEST_ACCOUNT_ID=%s\nHARVEST_ACCOUNT_NAME=%s\n' "$token" "$id" "$name" > "$CONFIG"
  chmod 600 "$CONFIG"
  echo "wrote $CONFIG — account $id ($name)"
}

cmd_accounts() {
  need_token
  request GET "$ID_API/accounts" | jq '[.accounts[] | select(.product == "harvest") | {id, name}]'
}

cmd_me() {
  need_token; need_account
  request GET "$API/users/me" | jq '{id, first_name, last_name, email, timezone}'
}

cmd_projects() {
  need_token; need_account
  local text=0; [[ "${1:-}" == "--text" ]] && text=1
  local json
  json="$(paged "$API/users/me/project_assignments?per_page=100" project_assignments)" || exit $?
  json="$(jq '[.[] | select(.is_active) | {
      project_id: .project.id, project: .project.name, code: .project.code, client: .client.name,
      tasks: [.task_assignments[] | select(.is_active) | {task_id: .task.id, task: .task.name}]
    }] | sort_by(.client, .project)' <<<"$json")"
  if [[ "$text" -eq 1 ]]; then
    jq -r '.[] | "\(.project_id)\t\(.client) / \(.project)\(if .code and .code != "" then " [" + .code + "]" else "" end)",
                 (.tasks[] | "\t\(.task_id)\t\(.task)")' <<<"$json"
  else
    printf '%s\n' "$json"
  fi
}

cmd_entries() {
  need_token; need_account
  local from="${1:-}" to="${2:-}"; shift 2 2>/dev/null || die "usage: harvest.sh entries <from> <to> [--project ID] [--text]"
  is_date "$from" && is_date "$to" || die "dates must be YYYY-MM-DD"
  local project="" text=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project) need_val "$@"; project="$2"; shift 2 ;;
      --text) text=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ -z "$project" ]] || is_id "$project" || die "--project must be a numeric id"
  local me url json
  me="$(request GET "$API/users/me" | jq -r '.id')" || exit $?
  url="$API/time_entries?user_id=$me&from=$from&to=$to&per_page=100"
  [[ -n "$project" ]] && url="$url&project_id=$project"
  json="$(paged "$url" time_entries)" || exit $?
  json="$(jq '[.[] | {id, date: .spent_date, hours, project_id: .project.id, project: .project.name, task: .task.name, notes}] | sort_by(.date, .id)' <<<"$json")"
  if [[ "$text" -eq 1 ]]; then
    jq -r 'group_by(.date)[] | "\(.[0].date)\t\(map(.hours) | add) h\t" + (map("\(.project) / \(.task) \(.hours) h") | join("; "))' <<<"$json"
  else
    printf '%s\n' "$json"
  fi
}

# post_entry DATE HOURS PROJECT TASK NOTES → created entry as JSON
post_entry() {
  local body
  body="$(jq -nc --arg d "$1" --argjson h "$2" --argjson p "$3" --argjson t "$4" --arg n "$5" \
    '{spent_date: $d, hours: $h, project_id: $p, task_id: $t, notes: $n}')"
  request POST "$API/time_entries" "$body" | jq -c '{id, date: .spent_date, hours, project: .project.name, task: .task.name}'
}

cmd_log() {
  need_token; need_account
  local d="${1:-}" h="${2:-}"; shift 2 2>/dev/null || die "usage: harvest.sh log <date> <hours> --project ID --task ID [--notes TEXT|--notes-file F]"
  local project="" task="" notes=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project) need_val "$@"; project="$2"; shift 2 ;;
      --task) need_val "$@"; task="$2"; shift 2 ;;
      # Empty notes are legitimate, so --notes only needs a next word.
      --notes) [[ $# -ge 2 ]] || die "--notes needs a value"; notes="$2"; shift 2 ;;
      --notes-file) need_val "$@"; [[ -r "$2" ]] || die "cannot read $2"; notes="$(cat "$2")"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  is_date "$d" || die "date must be YYYY-MM-DD"
  is_hours "$h" || die "hours must be a number in (0, 24]"
  is_id "$project" && is_id "$task" || die "--project and --task must be numeric ids"
  post_entry "$d" "$h" "$project" "$task" "$notes"
}

cmd_log_batch() {
  need_token; need_account
  local file="${1:-}"; shift 1 2>/dev/null || die "usage: harvest.sh log-batch <file.json> --project ID --task ID [--dry-run] [--force]"
  [[ -f "$file" ]] || die "no such file: $file"
  local project="" task="" dry=0 force=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project) need_val "$@"; project="$2"; shift 2 ;;
      --task) need_val "$@"; task="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      --force) force=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  is_id "$project" && is_id "$task" || die "--project and --task must be numeric ids"
  jq -e 'type == "array" and all(.[]; type == "object")' "$file" >/dev/null 2>&1 \
    || die "$file must hold a JSON array of {date, hours, notes} objects"

  # Validate every row before touching Harvest: a batch is all-or-nothing in
  # intent, so a typo in row 9 must not leave rows 1–8 logged.
  local bad
  bad="$(jq -r --argjson force "$force" '
    to_entries[] | .value as $r | .key as $i
    | if ($r.entry_id != null and $force == 0) or ($r.skip == true) then empty
      elif ($r.date|type) != "string" or ($r.date|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")|not) then "row \($i): bad date \($r.date)"
      elif ($r.hours|type) != "number" or $r.hours <= 0 or $r.hours > 24 then "row \($i) (\($r.date)): hours must be in (0, 24], got \($r.hours)"
      elif $r.notes != null and ($r.notes|type) != "string" then "row \($i) (\($r.date)): notes must be a string"
      else empty end' "$file")" || die "could not validate $file"
  # An empty $bad must mean "every row passed", never "jq failed".
  [[ -z "$bad" ]] || die $'invalid rows:\n'"$bad"
  # The regex above only checks the shape; an impossible day (2026-13-45) is
  # caught here, still before the first request.
  local d
  while IFS= read -r d; do
    is_date "$d" || die "invalid rows: $d is not a real date"
  done < <(jq -r --argjson force "$force" '.[] | select((.entry_id == null or $force == 1) and (.skip != true)) | .date' "$file")

  local rows n i row h notes created id
  rows="$(jq -c --argjson force "$force" '[to_entries[] | select((.value.entry_id == null or $force == 1) and (.value.skip != true))]' "$file")"
  n="$(jq 'length' <<<"$rows")"
  if [[ "$n" -eq 0 ]]; then echo "nothing to log: every row is already logged (entry_id) or skipped" >&2; echo '[]'; return 0; fi

  if [[ "$dry" -eq 1 ]]; then
    jq --argjson p "$project" --argjson t "$task" '[.[] | .value | {date, hours, notes, project_id: $p, task_id: $t, dry_run: true}]' <<<"$rows"
    return 0
  fi

  local results='[]'
  for ((i = 0; i < n; i++)); do
    row="$(jq -c ".[$i]" <<<"$rows")"
    d="$(jq -r '.value.date' <<<"$row")"; h="$(jq -r '.value.hours' <<<"$row")"; notes="$(jq -r '.value.notes // ""' <<<"$row")"
    if ! created="$(post_entry "$d" "$h" "$project" "$task" "$notes")"; then
      echo "harvest: batch stopped at $d — rows before it are logged (see entry_id in $file), rows after it are not" >&2
      printf '%s\n' "$results"
      return 2
    fi
    id="$(jq -r '.id' <<<"$created")"
    if ! is_id "$id"; then
      echo "harvest: Harvest answered $d without an entry id — check \`entries\` for that day before running the batch again" >&2
      printf '%s\n' "$results"
      return 2
    fi
    results="$(printf '%s\n%s' "$results" "$created" | jq -cs '.[0] + [.[1]]')"
    # Write the id back row by row so an interrupted batch leaves an exact
    # record. A --force run keeps the id it replaces, so every entry the file
    # ever created stays reachable for `delete`. If the write-back fails the
    # entry exists in Harvest but the file does not know — stop right there
    # and say so, or the next run would log the day again.
    if ! jq --argjson k "$(jq '.key' <<<"$row")" --argjson id "$id" '
         .[$k] |= (if .entry_id != null then .previous_entry_ids = ((.previous_entry_ids // []) + [.entry_id]) else . end | .entry_id = $id)' \
         "$file" > "$file.tmp" 2>/dev/null || ! mv "$file.tmp" "$file"; then
      rm -f "$file.tmp"
      echo "harvest: entry $id ($d, $h h) was created but could not be recorded in $file — add \"entry_id\": $id to that row by hand before running the batch again" >&2
      printf '%s\n' "$results"
      return 2
    fi
    echo "logged $d $h h → entry $id" >&2
  done
  printf '%s\n' "$results"
}

cmd_delete() {
  need_token; need_account
  local id="${1:-}"
  is_id "$id" || die "usage: harvest.sh delete <entry_id>"
  request DELETE "$API/time_entries/$id" >/dev/null && echo "deleted entry $id"
}

# ------------------------------------------------------------------ main ---
cmd="${1:-}"; shift 1 2>/dev/null || true
# `setup` replaces the config, so it must not read the token it is replacing:
# a rerun after the token expired would silently write the stale one back.
[[ "$cmd" == setup ]] || load_config
case "$cmd" in
  setup)     cmd_setup "$@" ;;
  accounts)  cmd_accounts "$@" ;;
  me)        cmd_me "$@" ;;
  projects)  cmd_projects "$@" ;;
  entries)   cmd_entries "$@" ;;
  log)       cmd_log "$@" ;;
  log-batch) cmd_log_batch "$@" ;;
  delete)    cmd_delete "$@" ;;
  -h|--help|help|"") usage ;;
  *) die "unknown command: $cmd (try --help)" ;;
esac
