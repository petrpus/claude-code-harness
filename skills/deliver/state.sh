#!/usr/bin/env bash
# skills/deliver/state.sh — deliver.sh's own resume truth and run reporting.
# docs/prd/0003-deliver.md § State / Resume / Exit codes, ADR-0007/0008.
#
# Every writer here is atomic (tmp file + mv) so a run killed mid-write never
# leaves a half-written state.json, status.json or lock behind — --resume
# (#61 S3) reads state.json as ground truth and must never see a torn file.
#
#   state.json    resume truth: map, base, runner_version, active_seconds,
#                 and one entry per issue touched this run: {state, branch,
#                 pr, round, head, issue_budget_usd, issue_max_minutes}.
#   events.jsonl  one row per issue-state transition (append-only).
#   status.json   the run's current headline, for Monitor / `--status`.
#   lock          the run's pid; deliver.sh removes it on exit.
#
# All functions take the run dir as their first argument, so a caller never
# has to source globals — deliver.sh is the only caller today.

# state_init <run_dir> <map> <base> <run_id> <runner_version>
state_init() {
  jq -n --argjson map "$2" --arg base "$3" --arg run_id "$4" --arg version "$5" \
     '{run_id:$run_id, map:$map, base:$base, runner_version:$version, active_seconds:0, issues:{}}' \
     > "$1/state.json.tmp" && mv "$1/state.json.tmp" "$1/state.json"
}

# state_issue_update <run_dir> <issue_number> <json_patch>  — shallow-merges
# $json_patch into .issues[<issue_number>]; existing fields not named in the
# patch are kept (a round bump does not erase a recorded branch/pr).
state_issue_update() {
  local rd="$1" n="$2" patch="$3"
  jq --arg n "$n" --argjson patch "$patch" \
     '.issues[$n] = ((.issues[$n] // {}) + $patch)' "$rd/state.json" \
     > "$rd/state.json.tmp" && mv "$rd/state.json.tmp" "$rd/state.json"
}

# state_set_active_seconds <run_dir> <seconds>
state_set_active_seconds() {
  jq --argjson s "$2" '.active_seconds = $s' "$1/state.json" \
    > "$1/state.json.tmp" && mv "$1/state.json.tmp" "$1/state.json"
}

# state_set_final_pr <run_dir> <pr> <base> <head>  — the integration → default
# PR (#62), recorded at the top level; rewritten when a later run updates it.
state_set_final_pr() {
  jq --argjson pr "$2" --arg base "$3" --arg head "$4" \
     '.final_pr = {number:$pr, base:$base, head:$head}' "$1/state.json" \
     > "$1/state.json.tmp" && mv "$1/state.json.tmp" "$1/state.json"
}

# state_event <run_dir> <issue_number_or_empty> <event> [reason]  — appended,
# never rewritten; a run's events.jsonl is its own transition log.
state_event() {
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg issue "${2:-}" \
     --arg event "$3" --arg reason "${4:-}" \
     '{ts:$ts, issue:(if $issue=="" then null else ($issue|tonumber? // $issue) end), event:$event, reason:$reason}' \
     >> "$1/events.jsonl"
}

# state_total_cost <run_dir>  — sum of cost_usd across the runner's own
# run-<id>.jsonl and every issue's inner run-*.jsonl, excluding
# phase:"iteration" rows (those are loop.sh's own per-iteration summaries,
# not model calls — counting them double-counts every plan/build call they
# wrap). Same exclusion loop.sh itself applies on resume.
state_total_cost() {
  local rd="$1"
  local -a files=()
  shopt -s nullglob
  files=("$rd"/run-*.jsonl "$rd"/issues/*/run-*.jsonl)
  shopt -u nullglob
  [[ ${#files[@]} -eq 0 ]] && { echo 0; return; }
  jq -s '[.[] | select(.phase != "iteration") | .cost_usd // 0] | add // 0' "${files[@]}" 2>/dev/null \
    || echo 0
}

# state_write_status <run_dir> <state> <current_issue_or_empty> <merged_count> <parked_count> <cost_usd> <elapsed_s>
state_write_status() {
  jq -cn --arg state "$2" --arg cur "${3:-}" --argjson merged "$4" --argjson parked "$5" \
     --argjson cost "$6" --argjson elapsed "$7" \
     '{state:$state, current_issue:(if $cur=="" then null else ($cur|tonumber? // $cur) end),
       merged_count:$merged, parked_count:$parked, cost_usd:$cost, elapsed_s:$elapsed}' \
     > "$1/status.json.tmp" && mv "$1/status.json.tmp" "$1/status.json"
}

# state_clip_num <remaining> <requested>  — min(remaining, requested), floored
# at 0; a negative remaining (already over) clips to 0, not to a negative cap
# that would read as "unbounded" to whatever parses it next.
state_clip_num() {
  jq -n --argjson r "$1" --argjson q "$2" 'if $r < 0 then 0 elif $q < $r then $q else $r end'
}
