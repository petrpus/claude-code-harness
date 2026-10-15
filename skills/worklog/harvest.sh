#!/usr/bin/env bash
# skills/worklog/harvest.sh — Harvest API v2 helper for /worklog --harvest.
#
# Plain curl + jq against api.harvestapp.com; no MCP server, no SDK. The token
# never leaves this machine: it is read from a config file (or the environment)
# and sent only to Harvest.
#
# Config, first match wins per key:
#   environment:  HARVEST_ACCESS_TOKEN, HARVEST_ACCOUNT_ID
#   file:         $HARVEST_CONFIG, default ~/.config/harvest/env
#                 (KEY=VALUE lines, written by `setup`, mode 0600)
#
# Commands (every one prints JSON unless --text is given):
#   setup <token> [account]        resolve the Harvest account (name substring
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
#                                  carry one are skipped unless --force
#   delete <entry_id>              delete a time entry (undo for log/log-batch)
#
# Exit codes: 0 ok · 1 usage/config error · 2 Harvest refused (HTTP ≥ 400).

set -uo pipefail

API="${HARVEST_API_BASE:-https://api.harvestapp.com/v2}"
ID_API="${HARVEST_ID_API_BASE:-https://id.getharvest.com/api/v2}"
CONFIG="${HARVEST_CONFIG:-$HOME/.config/harvest/env}"
UA="code-harness worklog (https://github.com/petrpus/claude-code-harness)"

die()   { echo "harvest: $*" >&2; exit 1; }
usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

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
      # Environment wins over the file.
      [[ -n "${!key:-}" ]] && continue
      export "$key=$val"
    done < "$CONFIG"
  fi
}
need_token()   { [[ -n "${HARVEST_ACCESS_TOKEN:-}" ]] || die "no token — run: harvest.sh setup <token> [account]  (or export HARVEST_ACCESS_TOKEN)"; }
need_account() { [[ -n "${HARVEST_ACCOUNT_ID:-}" ]]   || die "no account id — run: harvest.sh setup <token> [account]  (or export HARVEST_ACCOUNT_ID)"; }

# ------------------------------------------------------------------ http ---
# request METHOD URL [JSON-BODY] → body on stdout; exit 2 on HTTP ≥ 400.
request() {
  local method="$1" url="$2" body="${3:-}" out code
  local -a args=(-sS -X "$method" "$url"
    -H "Authorization: Bearer $HARVEST_ACCESS_TOKEN"
    -H "User-Agent: $UA" -H "Accept: application/json")
  [[ "$url" == "$API"* && -n "${HARVEST_ACCOUNT_ID:-}" ]] && args+=(-H "Harvest-Account-Id: $HARVEST_ACCOUNT_ID")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data "$body")
  out="$(curl "${args[@]}" -w $'\n%{http_code}' 2>&1)" || die "curl failed: $out"
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
    acc="$(jq -c --argjson p "$page" --arg k "$key" '. + ($p[$k] // [])' <<<"$acc")"
    url="$(jq -r '.links.next // empty' <<<"$page")"
  done
  printf '%s' "$acc"
}

# ---------------------------------------------------------------- checks ---
is_date()  { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -d "$1" >/dev/null 2>&1; }
is_hours() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v h="$1" 'BEGIN{exit !(h>0 && h<=24)}'; }
is_id()    { [[ "$1" =~ ^[0-9]+$ ]]; }

# -------------------------------------------------------------- commands ---
cmd_setup() {
  local token="${1:-}" want="${2:-}"
  [[ -n "$token" ]] || die "usage: harvest.sh setup <token> [account-name-or-id]"
  HARVEST_ACCESS_TOKEN="$token"
  local accounts chosen n
  accounts="$(request GET "$ID_API/accounts" | jq -c '[.accounts[] | select(.product == "harvest") | {id, name}]')" || exit $?
  n="$(jq 'length' <<<"$accounts")"
  [[ "$n" -gt 0 ]] || die "the token sees no Harvest account"
  if [[ -n "$want" ]]; then
    chosen="$(jq -c --arg w "$want" '[.[] | select((.id|tostring) == $w or (.name|ascii_downcase|contains($w|ascii_downcase)))]' <<<"$accounts")"
  else
    chosen="$accounts"
  fi
  case "$(jq 'length' <<<"$chosen")" in
    1) ;;
    0) echo "no account matches '$want'. Available:" >&2; jq -r '.[] | "  \(.id)\t\(.name)"' <<<"$accounts" >&2; exit 1 ;;
    *) echo "several accounts match — name one:" >&2; jq -r '.[] | "  \(.id)\t\(.name)"' <<<"$chosen" >&2; exit 1 ;;
  esac
  local id name
  id="$(jq -r '.[0].id' <<<"$chosen")"; name="$(jq -r '.[0].name' <<<"$chosen")"
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
      --project) project="${2:-}"; shift 2 ;;
      --text) text=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
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
      --project) project="${2:-}"; shift 2 ;;
      --task) task="${2:-}"; shift 2 ;;
      --notes) notes="${2:-}"; shift 2 ;;
      --notes-file) notes="$(cat "${2:-/dev/null}")"; shift 2 ;;
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
      --project) project="${2:-}"; shift 2 ;;
      --task) task="${2:-}"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      --force) force=1; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  is_id "$project" && is_id "$task" || die "--project and --task must be numeric ids"
  jq -e 'type == "array"' "$file" >/dev/null 2>&1 || die "$file must hold a JSON array of {date, hours, notes}"

  # Validate every row before touching Harvest: a batch is all-or-nothing in
  # intent, so a typo in row 9 must not leave rows 1–8 logged.
  local bad
  bad="$(jq -r --argjson force "$force" '
    to_entries[] | .value as $r | .key as $i
    | if ($r.entry_id != null and $force == 0) or ($r.skip == true) then empty
      elif ($r.date|type) != "string" or ($r.date|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")|not) then "row \($i): bad date \($r.date)"
      elif ($r.hours|type) != "number" or $r.hours <= 0 or $r.hours > 24 then "row \($i) (\($r.date)): hours must be in (0, 24], got \($r.hours)"
      else empty end' "$file")"
  [[ -z "$bad" ]] || die $'invalid rows:\n'"$bad"

  local rows n i row d h notes created id
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
    # Write the id back row by row so an interrupted batch leaves an exact record.
    jq --argjson k "$(jq '.key' <<<"$row")" --argjson id "$id" '.[$k].entry_id = $id' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    results="$(jq -c --argjson c "$created" '. + [$c]' <<<"$results")"
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
load_config
cmd="${1:-}"; shift 1 2>/dev/null || true
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
