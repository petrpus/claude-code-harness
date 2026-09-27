#!/usr/bin/env bash
# deliver/deliver.sh — deliver a Map issue: every issue in its Delivery
# section becomes its own PR into the current (integration) branch, built by
# autopilot's loop.sh, verified, squash-merged, and ticked on the Map — in
# blocking-edge order. docs/prd/0003-deliver.md, ADR-0007, ADR-0008.
#
# Every issue PR gets an independent review (agents/code-reviewer.md, in a
# throwaway worktree, #59) before it may merge. Not built yet: fix rounds,
# parking, CI wait, resume, the /deliver launcher — so a review that requests
# changes, like any other failure, stops the run where it is, with the PR open
# and the issue branch checked out for a human.
#
# Usage:
#   deliver.sh --map <N> [--verify-cmd '<cmd>']
#              [--issue-max-iterations 10] [--issue-max-minutes 120]
#              [--issue-budget-usd 10] [--review-model sonnet]
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
REVIEW_MODEL=sonnet

log()     { echo "deliver: $*" >&2; }
die()     { log "$*"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --map)                  MAP="${2#\#}"; shift 2 ;;
    --verify-cmd)           VERIFY_CMD="$2"; shift 2 ;;
    --issue-max-iterations) ISSUE_MAX_ITERATIONS="$2"; shift 2 ;;
    --issue-max-minutes)    ISSUE_MAX_MINUTES="$2"; shift 2 ;;
    --issue-budget-usd)     ISSUE_BUDGET_USD="$2"; shift 2 ;;
    --review-model)         REVIEW_MODEL="$2"; shift 2 ;;
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
# shellcheck source=../autopilot/agent.sh
. "$PLUGIN_ROOT/skills/autopilot/agent.sh"
# shellcheck source=review.sh
. "$SCRIPT_DIR/review.sh"
REVIEW_AGENT="$PLUGIN_ROOT/agents/code-reviewer.md"

# ---------------------------------------------------------------------------
# Preconditions — local and read-only first, so a refused run makes no forge
# call at all.
# ---------------------------------------------------------------------------
command -v jq  >/dev/null 2>&1 || die "'jq' is required"
command -v git >/dev/null 2>&1 || die "'git' is required"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repo"
cd "$(git rev-parse --show-toplevel)" || die "cannot cd to repo root"
[[ -f "$LOOP" ]] || die "autopilot runner not found at $LOOP"
[[ -f "$REVIEW_AGENT" ]] || die "reviewer charter not found at $REVIEW_AGENT"

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
RUN_LOG="$RUN_DIR/run-$RUN_ID.jsonl"
AGENT_STDERR_LOG="$RUN_DIR/claude-stderr.log"
# A run killed mid-review must not leave the reviewer's worktree behind.
trap 'review_cleanup' EXIT
trap 'review_cleanup; exit 130' INT TERM

# deliver_logline <phase> <issue> <round> <verdict> — one row per model call
# the runner itself makes, in loop.sh's run-log schema (plus issue/round), so
# /usage-report and the cost sums read deliver's calls like any other.
deliver_logline() {
  jq -cn --arg run "$RUN_ID" --arg phase "$1" --arg model "$REVIEW_MODEL" \
     --argjson issue "$2" --argjson round "$3" --arg verdict "$4" \
     --argjson dur "${AGENT_LAST_DURATION:-0}" --argjson cost "${AGENT_LAST_COST:-0}" \
     --argjson in "${AGENT_LAST_IN_TOKENS:-0}" --argjson out "${AGENT_LAST_OUT_TOKENS:-0}" \
     --argjson rc "${AGENT_LAST_RC:-0}" \
     '{ts:(now|todate),run_id:$run,iter:0,phase:$phase,model:$model,issue:$issue,round:$round,
       duration_s:$dur,cost_usd:$cost,input_tokens:$in,output_tokens:$out,exit_code:$rc,
       verdict:$verdict,holdout_failed:0}' >> "$RUN_LOG" 2>/dev/null || true
}

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
# Independent review of one PR head (review.sh). Returns 0 when the runner's
# verdict is approve, 1 otherwise; a checkout changed by the review is not an
# issue failure but a broken safety property, and ends the whole run.
# ---------------------------------------------------------------------------
review_issue() {
  local n="$1" pr="$2" base_sha="$3" head_sha="$4" dir="$5"
  local round=1 attempt rc out verdict comment="$dir/review-1.comment.md"
  for attempt in 1 2; do
    out="$dir/review-$round"
    review_run "$n" "$round" "$BASE" "$base_sha" "$head_sha" "$dir/PROMPT.md" "$out" "$REVIEW_MODEL"; rc=$?
    case "$rc" in
      0) deliver_logline review "$n" "$round" "$(jq -r '.verdict' "$out.json")"; break ;;
      2) # A failed call (timeout, crash) and an off-contract reply both leave
         # no verdict; the run log keeps them apart.
         if [[ "${AGENT_LAST_RC:-0}" -ne 0 ]]; then
           deliver_logline review "$n" "$round" call_failed
         else
           deliver_logline review "$n" "$round" no_verdict
         fi
         if [[ "$attempt" -eq 1 ]]; then
           log "#$n: the reviewer returned no usable verdict — retrying once."
           continue
         fi
         review_comment "$n" "$round" "$head_sha" "$out.md" "" > "$comment"
         forge_pr_comment "$pr" "$comment" || true
         log "#$n: no usable review verdict twice — stopping (PR #$pr stays open)."
         return 1 ;;
      3) deliver_logline review "$n" "$round" breach
         die "#$n: SAFETY BREACH — the checkout changed during the review of PR #$pr: $(tr '\n' ' ' < "$out.breach"). Stopping the run; nothing further is pushed or merged." ;;
      *) log "#$n: could not create the review worktree — stopping."; return 1 ;;
    esac
  done
  review_comment "$n" "$round" "$head_sha" "$out.md" "$out.json" > "$comment"
  forge_pr_comment "$pr" "$comment" || log "#$n: could not post the review on PR #$pr (continuing)"
  verdict="$(jq -r '.verdict' "$out.json")"
  if [[ "$verdict" != "approve" ]]; then
    log "#$n: review requests changes on PR #$pr — stopping (fix rounds arrive with #63). Findings: $out.json"
    return 1
  fi
  log "#$n: review approved PR #$pr"
  return 0
}

# ---------------------------------------------------------------------------
# One issue: branch → autopilot → push → PR → review → verify → merge → tick.
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

  # --- independent review of the pushed head, before anything merges ---
  review_issue "$n" "$pr" "$(git rev-parse "origin/$BASE")" "$head_sha" "$dir" || return 1

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
