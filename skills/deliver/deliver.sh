#!/usr/bin/env bash
# deliver/deliver.sh — deliver a Map issue: every issue in its Delivery
# section becomes its own PR into the current (integration) branch, built by
# autopilot's loop.sh, verified, squash-merged, and ticked on the Map — in
# blocking-edge order. docs/prd/0003-deliver.md, ADR-0007, ADR-0008.
#
# Tracer bullet (#57): the straight path only. No review, parking, CI wait,
# resume or /deliver skill yet — any failure stops the run where it is, with
# the issue branch left checked out for a human to inspect.
#
# Usage:
#   deliver.sh --map <N> [--verify-cmd '<cmd>']
#              [--issue-max-iterations 10] [--issue-max-minutes 120]
#              [--issue-budget-usd 10]
#
# Run it from a clean checkout of the integration branch (never main/master),
# in sync with origin. Exit codes: 0 every Delivery line merged ·
# 1 precondition failure, or an issue that did not make it to a merge.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOOP="$PLUGIN_ROOT/skills/autopilot/loop.sh"

ORIG_ARGV=("$@")
MAP=""
VERIFY_CMD=""
ISSUE_MAX_ITERATIONS=10
ISSUE_MAX_MINUTES=120
ISSUE_BUDGET_USD=10

log()     { echo "deliver: $*" >&2; }
die()     { log "$*"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --map)                  MAP="${2#\#}"; shift 2 ;;
    --verify-cmd)           VERIFY_CMD="$2"; shift 2 ;;
    --issue-max-iterations) ISSUE_MAX_ITERATIONS="$2"; shift 2 ;;
    --issue-max-minutes)    ISSUE_MAX_MINUTES="$2"; shift 2 ;;
    --issue-budget-usd)     ISSUE_BUDGET_USD="$2"; shift 2 ;;
    -h|--help)              sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done
[[ "$MAP" =~ ^[0-9]+$ ]] || die "--map <issue number> is required"

# shellcheck source=../autopilot/plan.sh
. "$PLUGIN_ROOT/skills/autopilot/plan.sh"
# shellcheck source=map.sh
. "$SCRIPT_DIR/map.sh"
# shellcheck source=charter.sh
. "$SCRIPT_DIR/charter.sh"
# shellcheck source=forge.sh
. "$SCRIPT_DIR/forge.sh"

# ---------------------------------------------------------------------------
# Preconditions — local and read-only first, so a refused run makes no forge
# call at all.
# ---------------------------------------------------------------------------
command -v jq  >/dev/null 2>&1 || die "'jq' is required"
command -v git >/dev/null 2>&1 || die "'git' is required"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repo"
cd "$(git rev-parse --show-toplevel)" || die "cannot cd to repo root"
[[ -f "$LOOP" ]] || die "autopilot runner not found at $LOOP"

BASE="$(git branch --show-current 2>/dev/null || true)"
case "$BASE" in
  "")          die "detached HEAD — check out the integration branch first." ;;
  main|master) die "refusing to merge into '$BASE'. Check out an integration branch (ADR-0007)." ;;
esac
[[ -z "$(git status --porcelain 2>/dev/null)" ]] || die "working tree is dirty. Commit or stash first."
git check-ignore -q tmp/deliver/.probe 2>/dev/null \
  || die "tmp/ is not gitignored — run state would be committed into issue branches."

if [[ -z "$VERIFY_CMD" ]]; then
  # Same detection as loop.sh (#56 moves both to allowlist.sh).
  if [[ -f package.json ]] && jq -e '.scripts.verify' package.json >/dev/null 2>&1; then
    if [[ -f pnpm-lock.yaml ]]; then VERIFY_CMD="pnpm verify"; else VERIFY_CMD="npm run verify"; fi
  fi
fi
[[ -n "$VERIFY_CMD" ]] || die "no verify command found and --verify-cmd not given."

git fetch -q origin || die "git fetch origin failed"
git rev-parse --verify -q "origin/$BASE" >/dev/null || die "'$BASE' is not on origin — push it first."
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$BASE")" ]] \
  || die "'$BASE' is not in sync with origin/$BASE — pull or push first."
# gh present and authenticated: read-only, and before the runner copy below,
# so a machine without a usable gh leaves nothing behind.
MSG_ERR="$(forge_preflight)" || die "$MSG_ERR"

# ---------------------------------------------------------------------------
# Private runner copy. BUILD edits files in this repo; when the repo is the
# harness itself, that can include this very script, which bash reads by
# byte offset while it runs (PRD 0002 § Execution model). Copy the plugin
# outside the worktree and run from there, so the code under change and the
# code running the change are never the same file — whoever launched us.
# ---------------------------------------------------------------------------
if [[ "${DELIVER_SNAPSHOT:-0}" != "1" ]]; then
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  SNAP="${XDG_STATE_HOME:-$HOME/.local/state}/claude-code-harness/deliver/$RUN_ID/runner"
  mkdir -p "$SNAP/.claude-plugin" || die "cannot create $SNAP"
  cp -R "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/agents" "$SNAP/" || die "cannot copy the runner to $SNAP"
  cp "$PLUGIN_ROOT/.claude-plugin/plugin.json" "$SNAP/.claude-plugin/" 2>/dev/null || true
  log "running from private copy $SNAP"
  DELIVER_SNAPSHOT=1 DELIVER_RUN_ID="$RUN_ID" exec bash "$SNAP/skills/deliver/deliver.sh" "${ORIG_ARGV[@]}"
fi
RUN_ID="${DELIVER_RUN_ID:?}"
RUN_DIR="tmp/deliver/$RUN_ID"
mkdir -p "$RUN_DIR"

# ---------------------------------------------------------------------------
# The Map.
# ---------------------------------------------------------------------------
MAP_BODY="$RUN_DIR/map.body.md"
MAP_PLAN="$RUN_DIR/map.plan.md"
MERGED=()   # issue numbers merged by this run

# refresh_map — re-read the Map from the forge (the source of truth: a human
# may tick a line by hand mid-run) and re-apply this run's own merges, so a
# failed remote tick can never make the runner deliver the same issue twice.
refresh_map() {
  local m
  forge_issue_body "$MAP" "$MAP_BODY" || return 1
  for m in ${MERGED[@]+"${MERGED[@]}"}; do
    map_tick "$MAP_BODY" "$m" > "$MAP_BODY.tmp" && mv "$MAP_BODY.tmp" "$MAP_BODY"
  done
  rm -f "$MAP_BODY.tmp"
  map_extract_delivery "$MAP_BODY" > "$MAP_PLAN"
}

refresh_map || die "cannot read map #$MAP"
[[ -s "$MAP_PLAN" ]] || die "map #$MAP has no '## Delivery' lines (docs/adr/0008-*.md)"
PROBLEMS="$(map_validate "$MAP_PLAN")" || die "map #$MAP is invalid: $(printf '%s' "$PROBLEMS" | tr '\n' ';')"
select_next_slice "$MAP_PLAN" >/dev/null; rc=$?
[[ "$rc" -eq 2 ]] && die "map #$MAP has a dependency cycle in its after: edges"

log "run $RUN_ID: map #$MAP into '$BASE' — verify='$VERIFY_CMD', $(grep -c '\[ \]' "$MAP_PLAN") issue(s) left"

# tick_map <number> — tick the issue's Delivery line on the forge. Re-read,
# change one line, write, read back; retried because a human editing the Map
# at the same moment can silently drop our write (ADR-0008 decision 6).
tick_map() {
  local n="$1" attempt fresh="$RUN_DIR/map.fresh.md" new="$RUN_DIR/map.new.md"
  for attempt in 1 2 3; do
    forge_issue_body "$MAP" "$fresh" || continue
    map_is_ticked "$fresh" "$n" && return 0
    map_tick "$fresh" "$n" > "$new" || return 1
    forge_issue_set_body "$MAP" "$new" || continue
    forge_issue_body "$MAP" "$fresh" && map_is_ticked "$fresh" "$n" && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# One issue: branch → autopilot → push → PR → verify → squash merge → tick.
# ---------------------------------------------------------------------------
deliver_issue() {
  local id="$1" n dir line map_title issue_title labels state title branch
  local pr head_sha status_state iters cost merged_sha
  n="$(map_issue_number "$id")"
  dir="$RUN_DIR/issues/$n"
  mkdir -p "$dir"

  forge_issue_json "$n" > "$dir/issue.json" || { log "#$n: cannot read the issue"; return 1; }
  state="$(jq -r '.state' "$dir/issue.json")"
  [[ "$state" == "OPEN" ]] || { log "#$n: issue is $state but unticked on the Map — tick it or reopen it."; return 1; }

  # select_next_slice ran in a $(...) subshell; load the globals here.
  plan_load "$MAP_PLAN"
  line="$(plan_selected_line "$id")"
  map_title="$(map_line_title "$line")"
  issue_title="$(jq -r '.title' "$dir/issue.json")"
  labels="$(jq -r '[.labels[]?.name] | join(",")' "$dir/issue.json")"
  title="$(map_pr_title "$map_title" "$issue_title" "$labels")"
  branch="$(map_branch_name "$n" "$title")"

  if git rev-parse --verify -q "refs/heads/$branch" >/dev/null \
     || [[ -n "$(git ls-remote --heads origin "$branch" 2>/dev/null)" ]]; then
    log "#$n: branch '$branch' already exists — resume is not supported yet (#61)."
    return 1
  fi
  log "#$n: $title → $branch"
  git switch -q -c "$branch" "origin/$BASE" || return 1

  charter_from_issue "$dir/issue.json" "$MAP_PLAN" "$MAP" > "$dir/PROMPT.md"

  # --- autopilot, one run per issue in its own state dir ---
  bash "$LOOP" --state-dir "$dir" --verify-cmd "$VERIFY_CMD" \
    --max-iterations "$ISSUE_MAX_ITERATIONS" --max-minutes "$ISSUE_MAX_MINUTES" \
    --budget-usd "$ISSUE_BUDGET_USD" 2> >(sed 's/^/  /' >&2)
  local loop_rc=$?
  status_state="$(jq -r '.state // "?"' "$dir/status.json" 2>/dev/null || echo '?')"
  if [[ "$loop_rc" -ne 0 || "$status_state" != "done" ]]; then
    log "#$n: autopilot ended '$status_state' (exit $loop_rc) — stopping. State: $dir"
    return 1
  fi
  [[ -z "$(git status --porcelain)" ]] || { log "#$n: autopilot left a dirty tree — stopping."; return 1; }
  [[ "$(git rev-list --count "origin/$BASE..HEAD")" -gt 0 ]] || { log "#$n: autopilot finished without a commit — stopping."; return 1; }

  # --- verify the exact head that will be merged ---
  head_sha="$(git rev-parse HEAD)"
  if ! bash -c "$VERIFY_CMD" > "$dir/final-verify.log" 2>&1; then
    log "#$n: verify failed on $head_sha — stopping. Log: $dir/final-verify.log"
    return 1
  fi
  [[ -z "$(git status --porcelain)" && "$(git rev-parse HEAD)" == "$head_sha" ]] \
    || { log "#$n: verify changed the checkout — stopping."; return 1; }

  # --- PR ---
  iters="$(jq -r '.iterations_done // 0' "$dir/status.json")"
  cost="$(jq -r '.total_cost_usd // 0' "$dir/status.json")"
  {
    echo "Refs #$n · Part of map #$MAP"
    echo
    echo "## What"
    echo
    grep -E '^[[:space:]]*[-*][[:space:]]+\[[xX]\]' "$dir/IMPLEMENTATION_PLAN.md" 2>/dev/null || echo "- (no plan items recorded)"
    echo
    echo "## Verification"
    echo
    echo "- \`$VERIFY_CMD\` passed on \`${head_sha:0:12}\`"
    echo "- autopilot: $iters iteration(s), \$$cost"
    echo
    echo "Delivered by \`/deliver\` (claude-code-harness) — run \`$RUN_ID\`."
  } > "$dir/pr-body.md"

  forge_push_branch "$branch" || { log "#$n: push failed — stopping."; return 1; }
  pr="$(forge_pr_create "$BASE" "$branch" "$title" "$dir/pr-body.md")" \
    || { log "#$n: opening the PR failed — stopping."; return 1; }
  log "#$n: PR #$pr opened"

  # --- merge (from the base, so the forge never has the head checked out) ---
  git switch -q "$BASE" || return 1
  if ! forge_pr_merge "$pr" "$head_sha" "$title (#$pr)" "$dir/pr-body.md" > "$dir/merge.log" 2>&1; then
    log "#$n: merge of PR #$pr refused — stopping. $(tail -1 "$dir/merge.log")"
    return 1
  fi
  [[ "$(forge_pr_state "$pr")" == "MERGED" ]] || { log "#$n: PR #$pr is not MERGED after merge — stopping."; return 1; }

  git fetch -q origin && git merge -q --ff-only "origin/$BASE" \
    || { log "#$n: cannot fast-forward '$BASE' to origin — stopping."; return 1; }
  merged_sha="$(git rev-parse --short HEAD)"
  git branch -q -D "$branch" 2>/dev/null || true
  forge_delete_remote_branch "$branch" || log "#$n: could not delete remote branch '$branch' (continuing)"

  MERGED+=("$n")
  tick_map "$n" || log "#$n: could not tick map #$MAP (continuing; this run will not redeliver it)"
  printf 'Merged into `%s` via #%s (`%s`) by `/deliver` run `%s`. Map #%s.\n' \
    "$BASE" "$pr" "$merged_sha" "$RUN_ID" "$MAP" > "$dir/issue-comment.md"
  forge_issue_comment "$n" "$dir/issue-comment.md" || true
  log "#$n: merged as $merged_sha"
  return 0
}

# ---------------------------------------------------------------------------
# Walk the issue graph.
# ---------------------------------------------------------------------------
while :; do
  refresh_map || die "cannot re-read map #$MAP"
  # The Map may have been edited since the last issue; a duplicate or a bad
  # ref should stop the run with its own name, not as a confusing later error.
  PROBLEMS="$(map_validate "$MAP_PLAN")" || die "map #$MAP became invalid mid-run: $(printf '%s' "$PROBLEMS" | tr '\n' ';')"
  NEXT="$(select_next_slice "$MAP_PLAN")"; rc=$?
  case "$rc" in
    0) ;;
    1) log "map #$MAP: every Delivery line is merged (${#MERGED[@]} this run)."; exit 0 ;;
    2) die "map #$MAP has a dependency cycle in its after: edges" ;;
    *) die "map #$MAP: nothing left that can start (select rc $rc)" ;;
  esac
  deliver_issue "$NEXT" || die "stopped at $NEXT — ${#MERGED[@]} issue(s) merged this run."
done
