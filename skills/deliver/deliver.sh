#!/usr/bin/env bash
# deliver/deliver.sh — deliver a Map issue: every issue in its Delivery
# section becomes its own PR into the current (integration) branch, built by
# autopilot's loop.sh, verified, squash-merged, and ticked on the Map — in
# blocking-edge order. docs/prd/0003-deliver.md, ADR-0007, ADR-0008.
#
# Every issue PR gets an independent review (agents/code-reviewer.md, in a
# throwaway worktree, #59) before it may merge. An issue that cannot get there
# — autopilot did not finish, verify failed on its head, the review held it,
# the forge refused the merge — is PARKED (#58): labelled needs-human, its PR
# back to draft, a comment saying why; issues that depend on it are skipped
# and independent ones continue. A failure of the machinery itself (the forge
# unreachable, a dirty checkout, a review that touched the checkout) ends the
# run instead. Not built yet: fix rounds, CI wait, resume, the launcher.
#
# Usage:
#   deliver.sh --map <N> [--verify-cmd '<cmd>']
#              [--issue-max-iterations 10] [--issue-max-minutes 120]
#              [--issue-budget-usd 10] [--review-model sonnet]
#              [--extra-allowed-tools '<csv>'] [--per-call-timeout <s>]
#              [--plan-max-items 3] [--verify-every-iteration] [--iteration-verify-cmd '<cmd>']
#              [--budget-usd <n>] [--max-minutes <n>]
#              [--resume [--retry '#N']]
#
# Run it from a clean checkout of the integration branch (never main/master),
# in sync with origin. State lives under tmp/deliver/<run-id>/: state.json
# (resume truth), events.jsonl, status.json, run-<run-id>.jsonl (this
# runner's own model calls, loop.sh's schema, so /usage-report reads it) and
# a lock file holding this process's pid, removed on exit. A STOP file at
# tmp/deliver/<run-id>/STOP is checked between phases (before a branch, after
# a build, before a PR, before a review, before a merge) and passed to every
# loop.sh call as --stop-file, so a build stopped mid-run stops the same way.
# --budget-usd / --max-minutes cap the whole run (every inner run's cost and
# this run's active time, summed — see state.sh); each issue's own
# --issue-budget-usd / --issue-max-minutes is clipped to whatever the global
# caps have left before that issue's loop.sh call. Exit codes: 0 every
# Delivery line merged · 1 precondition or runner failure · 2 partial (an
# issue was parked; its dependents were skipped) · 3 global time cap ·
# 4 global budget cap · 6 stopped (STOP file present).
#
# --resume picks the newest tmp/deliver/*/state.json for this --map, removes
# a stale lock (a pid that is no longer alive; a live one refuses the run),
# switches the checkout back to that run's recorded base branch if it is not
# there already, makes a fresh private runner copy (warning on stderr when
# plugin.json's version differs from the one state.json recorded), restores
# active_seconds, then reconciles every issue this run's state still calls
# non-terminal against GitHub — GitHub wins (docs/adr/0010-*.md) — before
# walking the graph exactly as a fresh run would: an issue whose branch this
# run's own state.json still names is continued (a pushed head without a PR
# gets one; an open PR is re-entered for review — round 1's dedupe marker,
# #61 S2, keeps that from posting twice — then merged; a local-only branch
# resumes autopilot with loop.sh --resume-run); any other leftover branch is
# still parked, unchanged from #58. --retry '#N' (with --resume) forgets a
# parked issue's recorded branch/PR, closes/deletes what it left behind,
# drops needs-human, and gives it a fresh inner run.

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
EXTRA_ALLOWED_TOOLS=""
PER_CALL_TIMEOUT=""    # empty: loop.sh's default (1200 s)
# An issue is already one PR-sized slice (#88): a small plan, and the full
# verify once per autopilot run (at completion) — /deliver's own final verify,
# review and CI stand behind every merge anyway.
PLAN_MAX_ITEMS=3       # 0: no size hint
VERIFY_EVERY_ITERATION=0
ITERATION_VERIFY_CMD=""
REVIEW_MODEL=sonnet
BUDGET_USD=""          # empty: no global cap
MAX_MINUTES=""         # empty: no global cap
RESUME=0
RETRY_ISSUE=""         # set by --retry '#N'; only meaningful with --resume

log()     { echo "deliver: $*" >&2; }
die()     { log "$*"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --map)                  MAP="${2#\#}"; shift 2 ;;
    --verify-cmd)           VERIFY_CMD="$2"; shift 2 ;;
    --issue-max-iterations) ISSUE_MAX_ITERATIONS="$2"; shift 2 ;;
    --issue-max-minutes)    ISSUE_MAX_MINUTES="$2"; shift 2 ;;
    --issue-budget-usd)     ISSUE_BUDGET_USD="$2"; shift 2 ;;
    --extra-allowed-tools)  EXTRA_ALLOWED_TOOLS="$2"; shift 2 ;;
    --per-call-timeout)     PER_CALL_TIMEOUT="$2"; shift 2 ;;
    --plan-max-items)       PLAN_MAX_ITEMS="$2"; shift 2 ;;
    --verify-every-iteration) VERIFY_EVERY_ITERATION=1; shift ;;
    --iteration-verify-cmd) ITERATION_VERIFY_CMD="$2"; shift 2 ;;
    --review-model)         REVIEW_MODEL="$2"; shift 2 ;;
    --budget-usd)           BUDGET_USD="$2"; shift 2 ;;
    --max-minutes)          MAX_MINUTES="$2"; shift 2 ;;
    --resume)               RESUME=1; shift ;;
    --retry)                RETRY_ISSUE="${2#\#}"; shift 2 ;;
    -h|--help)              sed -n '2,55p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done
[[ "$MAP" =~ ^[0-9]+$ ]] || die "--map <issue number> is required"
[[ -z "$PER_CALL_TIMEOUT" || "$PER_CALL_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--per-call-timeout takes whole seconds"
[[ "$PLAN_MAX_ITEMS" =~ ^[0-9]+$ ]] || die "--plan-max-items takes a whole number (0: no limit)"
[[ -z "$ITERATION_VERIFY_CMD" || "$VERIFY_EVERY_ITERATION" -eq 0 ]] \
  || die "--iteration-verify-cmd is for the default mode; drop it with --verify-every-iteration"
[[ -z "$BUDGET_USD" || "$BUDGET_USD" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--budget-usd takes a non-negative number"
[[ -z "$MAX_MINUTES" || "$MAX_MINUTES" =~ ^[1-9][0-9]*$ ]] || die "--max-minutes takes a whole number of minutes"
[[ -z "$RETRY_ISSUE" || "$RETRY_ISSUE" =~ ^[0-9]+$ ]] || die "--retry takes an issue number ('#N' or N)"
[[ -z "$RETRY_ISSUE" || "$RESUME" -eq 1 ]] || die "--retry only makes sense with --resume"

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
# shellcheck source=state.sh
. "$SCRIPT_DIR/state.sh"
REVIEW_AGENT="$PLUGIN_ROOT/agents/code-reviewer.md"

# ADR-0007: no model phase may hold a forge operation. A BUILD grant that
# reaches gh or git (directly, via a wrapper or an absolute path) or that runs
# arbitrary commands is refused here, before anything else happens.
if [[ -n "$EXTRA_ALLOWED_TOOLS" ]]; then
  GRANT_PROBLEMS="$(forge_grant_violations "$EXTRA_ALLOWED_TOOLS")" \
    || die "--extra-allowed-tools refused (ADR-0007): $(printf '%s' "$GRANT_PROBLEMS" | tr '\n' ';')"
fi

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

# ---------------------------------------------------------------------------
# --resume: find the run, handle its lock, and get the checkout back onto its
# recorded base *before* the base-branch precondition below reads whatever
# branch happens to be checked out — a run killed mid-issue leaves that on
# the issue branch, not the integration branch (docs/adr/0010-*.md).
# ---------------------------------------------------------------------------
RESUME_RUN_ID=""
if [[ "$RESUME" -eq 1 ]]; then
  shopt -s nullglob
  for _cand in tmp/deliver/*/; do
    _cand="${_cand%/}"
    [[ -f "$_cand/state.json" ]] || continue
    [[ "$(jq -r '.map // empty' "$_cand/state.json" 2>/dev/null)" == "$MAP" ]] && RESUME_RUN_ID="${_cand#tmp/deliver/}"
  done
  shopt -u nullglob
  [[ -n "$RESUME_RUN_ID" ]] || die "--resume: no run found for map #$MAP under tmp/deliver/"
  RESUME_STATE_JSON="tmp/deliver/$RESUME_RUN_ID/state.json"
  RESUME_LOCK="tmp/deliver/$RESUME_RUN_ID/lock"
  if [[ -f "$RESUME_LOCK" ]]; then
    RESUME_OLD_PID="$(cat "$RESUME_LOCK" 2>/dev/null)"
    if [[ -n "$RESUME_OLD_PID" ]] && kill -0 "$RESUME_OLD_PID" 2>/dev/null; then
      die "run $RESUME_RUN_ID (map #$MAP) is still active (pid $RESUME_OLD_PID) — refusing to resume a live run"
    fi
    log "run $RESUME_RUN_ID: removing a stale lock (pid ${RESUME_OLD_PID:-?} not alive)"
    rm -f "$RESUME_LOCK"
  fi
  RESUME_BASE="$(jq -r '.base' "$RESUME_STATE_JSON")"
  RESUME_CUR_BRANCH="$(git branch --show-current 2>/dev/null || true)"
  if [[ "$RESUME_CUR_BRANCH" != "$RESUME_BASE" ]]; then
    [[ -z "$(git status --porcelain 2>/dev/null)" ]] \
      || die "--resume: checkout is dirty and not on '$RESUME_BASE' (this run's recorded base) — resolve by hand first."
    log "run $RESUME_RUN_ID: switching the checkout back to '$RESUME_BASE' (was on '${RESUME_CUR_BRANCH:-<detached>}')"
    git switch -q "$RESUME_BASE" || die "--resume: cannot switch to '$RESUME_BASE'"
  fi
fi

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
  RUN_ID="$RESUME_RUN_ID"
  [[ -n "$RUN_ID" ]] || RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  SNAP="${XDG_STATE_HOME:-$HOME/.local/state}/claude-code-harness/deliver/$RUN_ID/runner"
  mkdir -p "$SNAP/.claude-plugin" || die "cannot create $SNAP"
  cp -R "$PLUGIN_ROOT/skills" "$PLUGIN_ROOT/agents" "$SNAP/" || die "cannot copy the runner to $SNAP"
  cp "$PLUGIN_ROOT/.claude-plugin/plugin.json" "$SNAP/.claude-plugin/" 2>/dev/null || true
  log "running from private copy $SNAP"
  DELIVER_SNAPSHOT=1 DELIVER_RUN_ID="$RUN_ID" DELIVER_RESUME="$RESUME" DELIVER_RETRY_ISSUE="$RETRY_ISSUE" \
    exec bash "$SNAP/skills/deliver/deliver.sh" "${ORIG_ARGV[@]}"
fi
RUN_ID="${DELIVER_RUN_ID:?}"
RESUME="${DELIVER_RESUME:-0}"
RETRY_ISSUE="${DELIVER_RETRY_ISSUE:-}"
RUN_DIR="tmp/deliver/$RUN_ID"
mkdir -p "$RUN_DIR"
RUN_LOG="$RUN_DIR/run-$RUN_ID.jsonl"
AGENT_STDERR_LOG="$RUN_DIR/claude-stderr.log"
# The review call gets the same per-call bound as autopilot's calls.
[[ -n "$PER_CALL_TIMEOUT" ]] && AGENT_TIMEOUT="$PER_CALL_TIMEOUT"
# A run killed mid-review must not leave the reviewer's worktree behind, or
# a stale lock/pid file that a later --resume (#61 S3) would have to guess
# was ours.
trap 'rm -f "$RUN_DIR/lock" 2>/dev/null; review_cleanup; agent_cleanup' EXIT
trap 'rm -f "$RUN_DIR/lock" 2>/dev/null; review_cleanup; agent_cleanup; exit 130' INT TERM

# ---------------------------------------------------------------------------
# Run state (#61 S1): state.json (resume truth), events.jsonl, status.json,
# lock. A fresh run initializes all of it; --resume (S3) keeps the existing
# state.json (issues and all), restores active_seconds, and only warns — it
# never refuses — when this copy's plugin.json version differs from the one
# the run started with.
# ---------------------------------------------------------------------------
START_EPOCH="$(date +%s)"
ACTIVE_SECONDS_BASE=0
CUR_ISSUE=""
RUNNER_VERSION="$(jq -r '.version // "unknown"' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null)"
[[ -n "$RUNNER_VERSION" ]] || RUNNER_VERSION="unknown"
echo $$ > "$RUN_DIR/lock"
if [[ "$RESUME" -eq 1 && -f "$RUN_DIR/state.json" ]]; then
  RESUME_OLD_VERSION="$(jq -r '.runner_version // "unknown"' "$RUN_DIR/state.json")"
  ACTIVE_SECONDS_BASE="$(jq -r '.active_seconds // 0' "$RUN_DIR/state.json" 2>/dev/null || echo 0)"
  if [[ "$RESUME_OLD_VERSION" != "$RUNNER_VERSION" ]]; then
    log "WARNING: plugin version changed since run $RUN_ID started ($RESUME_OLD_VERSION -> $RUNNER_VERSION) — resuming anyway."
  fi
  jq --arg v "$RUNNER_VERSION" '.runner_version = $v' "$RUN_DIR/state.json" > "$RUN_DIR/state.json.tmp" \
    && mv "$RUN_DIR/state.json.tmp" "$RUN_DIR/state.json"
  # A STOP file is this run's own instruction to itself, not GitHub's or the
  # issue's; --resume is the human overriding it, so the old one (still on
  # disk if that is why the run last stopped) must not immediately stop the
  # resumed run again.
  rm -f "$RUN_DIR/STOP"
  state_event "$RUN_DIR" "" resumed "plugin version $RESUME_OLD_VERSION -> $RUNNER_VERSION"
else
  state_init "$RUN_DIR" "$MAP" "$BASE" "$RUN_ID" "$RUNNER_VERSION"
fi

# active_seconds_now — this run's persisted active time plus this process's
# own elapsed time; the figure both the time cap and status.json report.
active_seconds_now() { echo $(( ACTIVE_SECONDS_BASE + ( $(date +%s) - START_EPOCH ) )); }

# run_status <state> — refresh status.json with the run's current headline.
run_status() {
  state_write_status "$RUN_DIR" "$1" "$CUR_ISSUE" "${#MERGED[@]}" "${#PARKED[@]}" \
    "$(state_total_cost "$RUN_DIR")" "$(active_seconds_now)"
}

# stop_run <exit_code> <state_label> — a global cap or STOP tripped: persist
# where the run ended (issue left non-terminal, resumable) and exit. Never
# returns.
stop_run() {
  state_set_active_seconds "$RUN_DIR" "$(active_seconds_now)"
  run_status "$2"
  state_event "$RUN_DIR" "$CUR_ISSUE" "$2" ""
  log "run $2 (exit $1): ${#MERGED[@]} merged, ${#PARKED[@]} parked this run."
  exit "$1"
}

# check_caps <phase-label> — the STOP file, then the global budget, then the
# global time cap, in that order; the first one that trips ends the run via
# stop_run (never returns). Called between phases (before a branch, after a
# build, before a PR, before a review, before a merge) so an issue never
# starts a phase the run cannot afford to let finish.
check_caps() {
  local phase="$1"
  if [[ -e "$RUN_DIR/STOP" ]]; then
    log "STOP file present — stopping ($phase)."
    stop_run 6 stopped
  fi
  if [[ -n "$BUDGET_USD" ]]; then
    local cost; cost="$(state_total_cost "$RUN_DIR")"
    if jq -en --argjson c "$cost" --argjson b "$BUDGET_USD" '$c >= $b' >/dev/null 2>&1; then
      log "global budget cap (\$$BUDGET_USD) reached (spent \$$cost) — stopping ($phase)."
      stop_run 4 budget_exhausted
    fi
  fi
  if [[ -n "$MAX_MINUTES" ]]; then
    local elapsed_min=$(( $(active_seconds_now) / 60 ))
    if (( elapsed_min >= MAX_MINUTES )); then
      log "global time cap ($MAX_MINUTES min) reached (elapsed ${elapsed_min}m) — stopping ($phase)."
      stop_run 3 time_exhausted
    fi
  fi
}

# clipped_issue_budget / clipped_issue_minutes — this issue's own cap,
# reduced to whatever the global cap has left (never raised: a global cap
# always wins). No global cap set: the issue's own flag is unchanged.
clipped_issue_budget() {
  [[ -z "$BUDGET_USD" ]] && { echo "$ISSUE_BUDGET_USD"; return; }
  local rem
  rem="$(jq -n --argjson b "$BUDGET_USD" --argjson c "$(state_total_cost "$RUN_DIR")" \
           '(($b - $c) as $r | if $r < 0 then 0 else $r end)')"
  state_clip_num "$rem" "$ISSUE_BUDGET_USD"
}
clipped_issue_minutes() {
  [[ -z "$MAX_MINUTES" ]] && { echo "$ISSUE_MAX_MINUTES"; return; }
  local elapsed_min=$(( $(active_seconds_now) / 60 )) rem
  rem=$(( MAX_MINUTES - elapsed_min ))
  (( rem < 0 )) && rem=0
  if (( ISSUE_MAX_MINUTES < rem )); then echo "$ISSUE_MAX_MINUTES"; else echo "$rem"; fi
}

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
PARKED=()   # issue refs (#N) parked by this run
CLOSED=()   # issue refs (#N) closed on the forge without this run's help
PARK_REASON=""   # set by deliver_issue before it returns 10
CUR_PR=""        # the PR of the issue in flight, once opened
CUR_BRANCH=""    # its branch, once created

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

# record_merge <n> <pr> <branch> — after the PR for issue <n> is confirmed
# MERGED, whether this run just merged it or --resume reconciliation found it
# already was: fast-forward the base, drop the branch, tick the Map, comment
# on the issue, update state.json. The one place both paths leave identical
# bookkeeping behind.
record_merge() {
  local n="$1" pr="$2" branch="$3" merged_sha
  git fetch -q origin && git merge -q --ff-only "origin/$BASE" \
    || { log "#$n: cannot fast-forward '$BASE' to origin — stopping."; return 1; }
  merged_sha="$(git rev-parse --short HEAD)"
  if [[ -n "$branch" ]]; then
    git branch -q -D "$branch" 2>/dev/null || true
    forge_delete_remote_branch "$branch" || log "#$n: could not delete remote branch '$branch' (continuing)"
  fi
  MERGED+=("$n")
  tick_map "$n" || log "#$n: could not tick map #$MAP (continuing; this run will not redeliver it)"
  mkdir -p "$RUN_DIR/issues/$n"
  {
    echo "<!-- deliver:merged issue=$n pr=$pr -->"
    printf 'Merged into `%s` via #%s (`%s`) by `/deliver` run `%s`. Map #%s.\n' \
      "$BASE" "$pr" "$merged_sha" "$RUN_ID" "$MAP"
  } > "$RUN_DIR/issues/$n/issue-comment.md"
  forge_issue_comment_has_marker "$n" "<!-- deliver:merged issue=$n pr=$pr -->" \
    || forge_issue_comment "$n" "$RUN_DIR/issues/$n/issue-comment.md" || true
  state_issue_update "$RUN_DIR" "$n" "$(jq -cn --arg h "$merged_sha" --argjson p "$pr" '{state:"merged", head:$h, pr:$p}')"
  state_event "$RUN_DIR" "$n" merged ""
  run_status running
  log "#$n: merged as $merged_sha"
  return 0
}

# reconcile_retry <n> <state_json_entry> — --retry '#N' (with --resume):
# forget this issue's recorded branch/PR, close/delete what it left behind,
# drop needs-human, and remove its old issues/<N>/ state so the graph walk
# gives it a fresh inner run, as if it had never been attempted.
reconcile_retry() {
  local n="$1" entry="$2" branch pr
  branch="$(jq -r '.branch // empty' <<<"$entry")"
  pr="$(jq -r '.pr // empty' <<<"$entry")"
  log "#$n: --retry — discarding the recorded branch/PR and starting a fresh inner run."
  forge_issue_remove_label "$n" needs-human 2>/dev/null || true
  [[ -n "$pr" ]] && { forge_pr_close "$pr" || log "#$n: could not close the old PR #$pr (continuing)"; }
  if [[ -n "$branch" ]]; then
    git branch -q -D "$branch" 2>/dev/null || true
    forge_delete_remote_branch "$branch" || true
  fi
  jq --arg n "$n" 'del(.issues[$n])' "$RUN_DIR/state.json" > "$RUN_DIR/state.json.tmp" \
    && mv "$RUN_DIR/state.json.tmp" "$RUN_DIR/state.json"
  rm -rf "${RUN_DIR:?}/issues/$n"
  state_event "$RUN_DIR" "$n" retry ""
}

# reconcile_run — --resume only, called once before the graph walk. Every
# issue this run's state.json still calls non-terminal (not merged, not
# parked) is checked against GitHub, which wins over whatever state.json last
# recorded (docs/adr/0010-*.md): the Map tick or a MERGED PR settles it as
# merged; the issue itself closed settles it as closed-externally (skipped
# like a parked one, but no label or comment — a human closed it on purpose);
# needs-human settles it as parked. Anything else — still building, a PR
# still open, pushed with no PR yet — is left exactly as state.json has it;
# deliver_issue's branch-exists dispatch picks it up again, lazily, the
# moment the graph walk reaches it.
reconcile_run() {
  local n entry st branch pr
  for n in $(jq -r '.issues | keys[]' "$RUN_DIR/state.json" 2>/dev/null); do
    entry="$(jq -c --arg n "$n" '.issues[$n]' "$RUN_DIR/state.json")"
    if [[ "$n" == "$RETRY_ISSUE" ]]; then
      reconcile_retry "$n" "$entry"
      RETRY_MATCHED=1
      continue
    fi
    st="$(jq -r '.state // empty' <<<"$entry")"
    if [[ "$st" == "merged" ]]; then MERGED+=("$n"); continue; fi
    if [[ "$st" == "parked"  ]]; then PARKED+=("#$n"); continue; fi
    mkdir -p "$RUN_DIR/issues/$n"
    if ! forge_issue_json "$n" > "$RUN_DIR/issues/$n/issue.json" 2>/dev/null; then
      log "#$n: --resume could not re-read the issue — leaving it as recorded ($st)."
      continue
    fi
    if [[ "$(jq -r '.state' "$RUN_DIR/issues/$n/issue.json")" != "OPEN" ]]; then
      log "#$n: closed on the forge since this run started — closed-externally, left alone."
      CLOSED+=("#$n")
      state_issue_update "$RUN_DIR" "$n" '{"state":"closed-external"}'
      state_event "$RUN_DIR" "$n" closed-external ""
      continue
    fi
    if jq -e '[.labels[]?.name] | index("needs-human")' "$RUN_DIR/issues/$n/issue.json" >/dev/null 2>&1; then
      log "#$n: labelled needs-human — parked."
      PARKED+=("#$n")
      state_issue_update "$RUN_DIR" "$n" '{"state":"parked"}'
      state_event "$RUN_DIR" "$n" parked "needs-human, found on --resume"
      continue
    fi
    if map_is_ticked "$MAP_BODY" "$n"; then
      log "#$n: already ticked on the Map — merged."
      MERGED+=("$n")
      state_issue_update "$RUN_DIR" "$n" '{"state":"merged"}'
      continue
    fi
    branch="$(jq -r '.branch // empty' <<<"$entry")"
    [[ -n "$branch" ]] || continue
    if pr="$(forge_pr_for_branch "$branch")" && [[ "$(forge_pr_state "$pr")" == "MERGED" ]]; then
      log "#$n: PR #$pr already merged — catching up the bookkeeping."
      record_merge "$n" "$pr" "$branch" || die "#$n: --resume could not fast-forward '$BASE' after an already-merged PR"
    fi
  done
  if [[ -n "$RETRY_ISSUE" && "${RETRY_MATCHED:-0}" -ne 1 ]]; then
    die "--retry #$RETRY_ISSUE: no such issue in run $RUN_ID's state (nothing to retry)"
  fi
}

if [[ "$RESUME" -eq 1 ]]; then
  reconcile_run
  refresh_map || die "cannot re-read map #$MAP after --resume reconciliation"
fi

log "run $RUN_ID: map #$MAP into '$BASE' — verify='$VERIFY_CMD', $(grep -c '\[ \]' "$MAP_PLAN") issue(s) left"
run_status running

# ---------------------------------------------------------------------------
# Independent review of one PR head (review.sh). Returns 0 when the runner's
# verdict is approve, 10 (park) when the review holds the PR, 1 when the
# review could not run; a checkout changed by the review is not an issue
# failure but a broken safety property, and ends the whole run.
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
         forge_pr_comment_has_marker "$pr" "$(review_marker "$n" "$round" "$head_sha")" \
           || forge_pr_comment "$pr" "$comment" || true
         PARK_REASON="the reviewer returned no usable verdict twice (PR #$pr)"
         return 10 ;;
      3) deliver_logline review "$n" "$round" breach
         die "#$n: SAFETY BREACH — the checkout changed during the review of PR #$pr: $(tr '\n' ' ' < "$out.breach"). Stopping the run; nothing further is pushed or merged." ;;
      *) log "#$n: could not create the review worktree — stopping."; return 1 ;;
    esac
  done
  review_comment "$n" "$round" "$head_sha" "$out.md" "$out.json" > "$comment"
  forge_pr_comment_has_marker "$pr" "$(review_marker "$n" "$round" "$head_sha")" \
    || forge_pr_comment "$pr" "$comment" || log "#$n: could not post the review on PR #$pr (continuing)"
  verdict="$(jq -r '.verdict' "$out.json")"
  if [[ "$verdict" != "approve" ]]; then
    PARK_REASON="the review requests changes on PR #$pr (fix rounds arrive with #63)"
    return 10
  fi
  log "#$n: review approved PR #$pr"
  return 0
}

# ---------------------------------------------------------------------------
# One issue: branch → autopilot → push → PR → review → verify → merge → tick.
# ---------------------------------------------------------------------------
# Returns 0 merged, 10 park (PARK_REASON says why), 11 already parked (left
# alone, skipped with its dependents), 1 end the run.
# ensure_pr_body <dir> <n> <head_sha> — (re)writes $dir/pr-body.md from the
# issue's IMPLEMENTATION_PLAN.md and autopilot's status.json. Idempotent, so
# both a fresh PR and a --resume that only needs to open the PR for an
# already-pushed head call it the same way.
ensure_pr_body() {
  local dir="$1" n="$2" head_sha="$3" iters cost
  iters="$(jq -r '.iterations_done // 0' "$dir/status.json" 2>/dev/null || echo 0)"
  cost="$(jq -r '.total_cost_usd // 0' "$dir/status.json" 2>/dev/null || echo 0)"
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
    echo "- autopilot: ${iters:-0} iteration(s), \$${cost:-0}"
    echo
    echo "Delivered by \`/deliver\` (claude-code-harness) — run \`$RUN_ID\`."
  } > "$dir/pr-body.md"
}

# Returns 0 merged, 10 park (PARK_REASON says why), 11 already parked (left
# alone, skipped with its dependents), 1 end the run.
deliver_issue() {
  local id="$1" n dir line map_title issue_title labels state title branch
  local pr="" head_sha status_state iters cost
  n="$(map_issue_number "$id")"
  dir="$RUN_DIR/issues/$n"
  mkdir -p "$dir"
  # Per-issue state starts empty: every early return below may park, and a
  # park must never name an earlier issue's PR or branch.
  CUR_PR=""; CUR_BRANCH=""
  CUR_ISSUE="$n"
  state_issue_update "$RUN_DIR" "$n" '{"state":"preparing"}'

  forge_issue_json "$n" > "$dir/issue.json" || { log "#$n: cannot read the issue"; return 1; }
  state="$(jq -r '.state' "$dir/issue.json")"
  [[ "$state" == "OPEN" ]] || { log "#$n: issue is $state but unticked on the Map — tick it or reopen it."; return 1; }
  # Parked by an earlier run and not yet released by a human: leave it — no
  # new branch, no new comment — and skip what waits on it.
  if jq -e '[.labels[]?.name] | index("needs-human")' "$dir/issue.json" >/dev/null 2>&1; then
    log "#$n: labelled needs-human (parked earlier) — left alone, with everything that waits on it."
    return 11
  fi

  # select_next_slice ran in a $(...) subshell; load the globals here.
  plan_load "$MAP_PLAN"
  line="$(plan_selected_line "$id")"
  map_title="$(map_line_title "$line")"
  issue_title="$(jq -r '.title' "$dir/issue.json")"
  labels="$(jq -r '[.labels[]?.name] | join(",")' "$dir/issue.json")"
  title="$(map_pr_title "$map_title" "$issue_title" "$labels")"
  branch="$(map_branch_name "$n" "$title")"

  check_caps "before a branch (#$n)"

  # A branch left by an earlier attempt. A --resume whose own state.json
  # still names this exact branch for this issue continues it (docs/adr/
  # 0010-*.md); any other leftover branch — a stray one, or this branch under
  # a fresh (non-resuming) run — cannot be told apart from someone else's
  # work, so it still parks the issue and only the issue (#58).
  local resume_point="fresh"
  if git rev-parse --verify -q "refs/heads/$branch" >/dev/null 2>&1 \
     || [[ -n "$(git ls-remote --heads origin "$branch" 2>/dev/null)" ]]; then
    local known_branch=""
    [[ "$RESUME" -eq 1 ]] && known_branch="$(jq -r --arg n "$n" '.issues[$n].branch // empty' "$RUN_DIR/state.json" 2>/dev/null)"
    if [[ "$known_branch" != "$branch" ]]; then
      PARK_REASON="branch \`$branch\` from an earlier attempt still exists; delete it (locally and on origin), and close its PR if it has one, to start over — --resume only continues a branch its own state.json recorded"
      return 10
    fi
    CUR_BRANCH="$branch"
    if pr="$(forge_pr_for_branch "$branch")"; then
      resume_point="pr-open"
    elif [[ -n "$(git ls-remote --heads origin "$branch" 2>/dev/null)" ]]; then
      resume_point="pr-needed"
    else
      resume_point="building"
    fi
    log "#$n: --resume continuing \`$branch\` ($resume_point)"
  fi

  if [[ "$resume_point" == "fresh" || "$resume_point" == "building" ]]; then
    if [[ "$resume_point" == "fresh" ]]; then
      log "#$n: $title → $branch"
      git switch -q -c "$branch" "origin/$BASE" || return 1
      CUR_BRANCH="$branch"
    else
      git switch -q "$branch" || return 1
    fi
    state_issue_update "$RUN_DIR" "$n" "$(jq -cn --arg b "$branch" '{state:"building", branch:$b}')"
    [[ -f "$dir/PROMPT.md" ]] || charter_from_issue "$dir/issue.json" "$MAP_PLAN" "$MAP" > "$dir/PROMPT.md"

    # --- autopilot, one run per issue in its own state dir ---
    # --extra-allowed-tools reaches autopilot's BUILD only — never the verifier
    # or the reviewer, and it is the caller's to keep free of gh / git push
    # (ADR-0007); the runner refuses such entries below.
    # Indented line by line with a read loop, not sed: sed block-buffers into a
    # pipe, and a run log behind `| tee` then stayed empty for half an hour.
    local -a loop_timeout=() loop_pace=()
    [[ -n "$PER_CALL_TIMEOUT" ]] && loop_timeout=(--per-call-timeout "$PER_CALL_TIMEOUT")
    [[ "$PLAN_MAX_ITEMS" -gt 0 ]] && loop_pace+=(--plan-max-items "$PLAN_MAX_ITEMS")
    if [[ "$VERIFY_EVERY_ITERATION" -eq 0 ]]; then
      loop_pace+=(--verify-at-completion)
      [[ -n "$ITERATION_VERIFY_CMD" ]] && loop_pace+=(--iteration-verify-cmd "$ITERATION_VERIFY_CMD")
    fi
    local -a loop_extra=()
    [[ -n "$EXTRA_ALLOWED_TOOLS" ]] && loop_extra=(--extra-allowed-tools "$EXTRA_ALLOWED_TOOLS")
    local -a loop_resume=()
    [[ "$resume_point" == "building" ]] && loop_resume=(--resume-run)
    # Per-issue caps never exceed what the global --budget-usd / --max-minutes
    # have left (#61); recorded on the issue's state before the call so a
    # --resume can see what this attempt was actually bounded by.
    local issue_budget_eff issue_minutes_eff
    issue_budget_eff="$(clipped_issue_budget)"
    issue_minutes_eff="$(clipped_issue_minutes)"
    state_issue_update "$RUN_DIR" "$n" \
      "$(jq -cn --argjson b "$issue_budget_eff" --argjson m "$issue_minutes_eff" \
           '{issue_budget_usd:$b, issue_max_minutes:$m}')"
    bash "$LOOP" --state-dir "$dir" --verify-cmd "$VERIFY_CMD" ${loop_extra[@]+"${loop_extra[@]}"} \
      --max-iterations "$ISSUE_MAX_ITERATIONS" --max-minutes "$issue_minutes_eff" \
      --budget-usd "$issue_budget_eff" --stop-file "$RUN_DIR/STOP" \
      ${loop_timeout[@]+"${loop_timeout[@]}"} ${loop_pace[@]+"${loop_pace[@]}"} ${loop_resume[@]+"${loop_resume[@]}"} \
      2> >(while IFS= read -r line || [[ -n "$line" ]]; do printf '  %s\n' "$line"; done >&2)
    local loop_rc=$?
    status_state="$(jq -r '.state // "?"' "$dir/status.json" 2>/dev/null || echo '?')"
    # loop.sh's own STOP-file exit is this run's stop, never a park (#61) — the
    # STOP file it found is the same one check_caps below would find.
    [[ "$loop_rc" -eq 6 ]] && stop_run 6 stopped
    check_caps "after a build (#$n)"
    # Exit 1 is autopilot refusing to start (its preconditions) — the machinery,
    # not this issue. Anything else short of done is this issue not finishing.
    if [[ "$loop_rc" -eq 1 ]]; then
      log "#$n: autopilot refused to start (exit 1) — stopping the run. State: $dir"
      return 1
    fi
    [[ -z "$(git status --porcelain)" ]] || { log "#$n: autopilot left a dirty tree — stopping."; return 1; }
    if [[ "$loop_rc" -ne 0 || "$status_state" != "done" ]]; then
      PARK_REASON="autopilot ended '$status_state' (exit $loop_rc) without finishing"
      return 10
    fi
    if [[ "$(git rev-list --count "origin/$BASE..HEAD")" -eq 0 ]]; then
      PARK_REASON="autopilot reported done without a single commit"
      return 10
    fi

    # --- verify the exact head that will be merged ---
    head_sha="$(git rev-parse HEAD)"
    # Autopilot's BUILD may have edited what verify runs: no forge credentials.
    agent_run_without_forge_credentials bash -c "$VERIFY_CMD" > "$dir/final-verify.log" 2>&1
    local verify_rc=$?
    if [[ "${AGENT_REFUSED:-0}" -eq 1 ]]; then
      log "#$n: forge credentials could not be withheld for verify (no private temp dir) — stopping the run."
      return 1
    fi
    if [[ "$verify_rc" -ne 0 ]]; then
      [[ -z "$(git status --porcelain)" ]] || { log "#$n: verify failed and left the checkout dirty — stopping."; return 1; }
      PARK_REASON="verify failed on the head autopilot finished with (\`${head_sha:0:12}\`)"
      return 10
    fi
    [[ -z "$(git status --porcelain)" && "$(git rev-parse HEAD)" == "$head_sha" ]] \
      || { log "#$n: verify changed the checkout — stopping."; return 1; }

    ensure_pr_body "$dir" "$n" "$head_sha"
    check_caps "before a PR (#$n)"
    forge_push_branch "$branch" || { log "#$n: push failed — stopping."; return 1; }
    pr="$(forge_pr_create "$BASE" "$branch" "$title" "$dir/pr-body.md")" \
      || { log "#$n: opening the PR failed — stopping."; return 1; }
  elif [[ "$resume_point" == "pr-needed" ]]; then
    # Pushed on an earlier attempt, never got as far as opening the PR.
    head_sha="$(git ls-remote --heads origin "$branch" 2>/dev/null | awk '{print $1}')"
    [[ -n "$head_sha" ]] || { log "#$n: pushed branch \`$branch\` has no remote head — stopping."; return 1; }
    ensure_pr_body "$dir" "$n" "$head_sha"
    check_caps "before a PR (#$n)"
    pr="$(forge_pr_create "$BASE" "$branch" "$title" "$dir/pr-body.md")" \
      || { log "#$n: opening the PR failed — stopping."; return 1; }
  else
    # resume_point == pr-open: an earlier attempt already opened PR $pr.
    head_sha="$(git ls-remote --heads origin "$branch" 2>/dev/null | awk '{print $1}')"
    [[ -n "$head_sha" ]] || { log "#$n: PR #$pr's branch \`$branch\` has no remote head — stopping."; return 1; }
    ensure_pr_body "$dir" "$n" "$head_sha"
  fi

  CUR_PR="$pr"
  log "#$n: PR #$pr open"
  state_issue_update "$RUN_DIR" "$n" "$(jq -cn --argjson p "$pr" '{state:"pr-open", pr:$p}')"
  state_event "$RUN_DIR" "$n" pr-open ""

  # --- independent review of the pushed head, before anything merges ---
  # Review round is always 1 — fix rounds arrive with #63 — so a --resume
  # re-entering here recomputes the exact same marker (#61 S2) and never
  # posts the review comment twice, whether or not the earlier attempt
  # managed to post it before it was interrupted.
  check_caps "before a review (#$n)"
  state_issue_update "$RUN_DIR" "$n" '{"state":"reviewing","round":1}'
  review_issue "$n" "$pr" "$(git rev-parse "origin/$BASE")" "$head_sha" "$dir"
  local review_rc=$?
  [[ "$review_rc" -eq 0 ]] || return "$review_rc"

  # --- merge (from the base, so the forge never has the head checked out) ---
  check_caps "before a merge (#$n)"
  state_issue_update "$RUN_DIR" "$n" '{"state":"merging"}'
  git switch -q "$BASE" || return 1
  if ! forge_pr_merge "$pr" "$head_sha" "$title (#$pr)" "$dir/pr-body.md" > "$dir/merge.log" 2>&1; then
    PARK_REASON="the forge refused to merge PR #$pr: $(tail -1 "$dir/merge.log")"
    return 10
  fi
  [[ "$(forge_pr_state "$pr")" == "MERGED" ]] || { log "#$n: PR #$pr is not MERGED after merge — stopping."; return 1; }
  record_merge "$n" "$pr" "$branch" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# Park an issue: leave it for a human, say why, and keep going. The issue
# branch stays (local, and on the remote once pushed) for inspection.
# ---------------------------------------------------------------------------
park_issue() {
  local n="$1" dir="$RUN_DIR/issues/$1" comment="$RUN_DIR/issues/$1/park-comment.md"
  local st="$RUN_DIR/issues/$1/status.json"
  # Keyed on the reason, not just the issue: a real re-park for a different
  # cause (the #58 branch-exists rule after a label was removed by hand, say)
  # must still get its own comment. Only an exact repeat — the case a resume
  # can hit — is deduped.
  local marker="<!-- deliver:park issue=$n reason=$(printf '%s' "$PARK_REASON" | cksum | cut -d' ' -f1) -->"
  log "#$n: PARKED — $PARK_REASON"
  # Back to the base so the next issue starts clean; anything else means the
  # checkout is not in the state the runner left it, and parking stops there.
  [[ -z "$(git status --porcelain)" ]] || die "#$n: cannot park — the checkout is dirty."
  git switch -q "$BASE" || die "#$n: cannot park — cannot switch back to '$BASE'."
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$BASE")" ]] \
    || die "#$n: cannot park — '$BASE' no longer matches origin/$BASE."

  forge_label_ensure needs-human d93f0b "Parked by /deliver: needs a human decision before an agent retries it"
  forge_issue_add_label "$n" needs-human || log "#$n: could not add the needs-human label"
  forge_issue_remove_label "$n" ready-for-agent 2>/dev/null || true
  if [[ -n "$CUR_PR" ]]; then
    forge_pr_draft "$CUR_PR" || log "#$n: could not turn PR #$CUR_PR back into a draft"
  fi
  {
    echo "$marker"
    echo "**Parked by \`/deliver\`** (run \`$RUN_ID\`, map #$MAP): $PARK_REASON."
    echo
    if [[ -n "$CUR_PR" ]]; then
      echo "- PR: #$CUR_PR (back to draft) · branch \`$CUR_BRANCH\`"
    elif [[ -n "$CUR_BRANCH" ]]; then
      echo "- Branch: \`$CUR_BRANCH\` (local to the machine that ran /deliver; not pushed)"
    fi
    if [[ -f "$st" ]]; then
      jq -r '"- Autopilot: state `\(.state)`, \(.iterations_done) iteration(s), $\(.total_cost_usd)"' "$st" 2>/dev/null
    fi
    echo "- Issues that wait on this one are skipped in this run; independent ones continue."
    echo "- To retry: \`/deliver --map $MAP --resume --retry '#$n'\` — it removes \`needs-human\`, discards this attempt's branch${CUR_PR:+ and PR #$CUR_PR} for you, and starts a fresh one. While the label is on, a plain \`--resume\` leaves this issue alone."
    if [[ -s "$dir/FEEDBACK.md" ]]; then
      local fence
      fence="$(tail -n 40 "$dir/FEEDBACK.md" | md_tilde_fence)"
      echo
      echo "<details><summary>Autopilot's last feedback</summary>"
      echo
      echo "$fence"
      tail -n 40 "$dir/FEEDBACK.md"
      echo "$fence"
      echo
      echo "</details>"
    fi
  } > "$comment"
  forge_issue_comment_has_marker "$n" "$marker" \
    || forge_issue_comment "$n" "$comment" || log "#$n: could not post the parking comment"
  PARKED+=("#$n")
  state_issue_update "$RUN_DIR" "$n" '{"state":"parked"}'
  state_event "$RUN_DIR" "$n" parked "$PARK_REASON"
  run_status running
}

# finish — report what this run did and exit 0 (everything merged) or 2.
finish() {
  local i skipped=()
  plan_load "$MAP_PLAN"
  for (( i=0; i<${#PLAN_IDS[@]}; i++ )); do
    [[ "${PLAN_ROW_TICKED[$i]}" == "1" ]] && continue
    [[ " ${PARKED[*]:-} " == *" ${PLAN_IDS[$i]} "* ]] && continue
    [[ " ${CLOSED[*]:-} " == *" ${PLAN_IDS[$i]} "* ]] && continue
    skipped+=("${PLAN_IDS[$i]}")
  done
  log "map #$MAP: ${#MERGED[@]} merged this run${PARKED[*]:+, parked: ${PARKED[*]}}${CLOSED[*]:+, closed-externally: ${CLOSED[*]}}${skipped[*]:+, skipped (blocked by a parked issue): ${skipped[*]}}."
  CUR_ISSUE=""
  state_set_active_seconds "$RUN_DIR" "$(active_seconds_now)"
  if [[ ${#PARKED[@]} -eq 0 && ${#CLOSED[@]} -eq 0 && ${#skipped[@]} -eq 0 ]]; then
    run_status done
    exit 0
  fi
  run_status partial
  exit 2
}

# ---------------------------------------------------------------------------
# Walk the issue graph.
# ---------------------------------------------------------------------------
while :; do
  refresh_map || die "cannot re-read map #$MAP"
  # The Map may have been edited since the last issue; a duplicate or a bad
  # ref should stop the run with its own name, not as a confusing later error.
  PROBLEMS="$(map_validate "$MAP_PLAN")" || die "map #$MAP became invalid mid-run: $(printf '%s' "$PROBLEMS" | tr '\n' ';')"
  # Parked and closed-externally issues are passed as blocked slices:
  # select_next_slice never picks them or anything that waits on them (rc 3
  # once only those are left).
  NEXT="$(select_next_slice "$MAP_PLAN" "$(IFS=,; echo "${PARKED[*]:-} ${CLOSED[*]:-}" | tr ' ' ',')")"; rc=$?
  case "$rc" in
    0) ;;
    1|3) finish ;;
    2) die "map #$MAP has a dependency cycle in its after: edges" ;;
    *) die "map #$MAP: unexpected scheduler result (select rc $rc)" ;;
  esac
  PARK_REASON=""
  deliver_issue "$NEXT"; rc=$?
  case "$rc" in
    0)  ;;
    10) park_issue "$(map_issue_number "$NEXT")" ;;
    11) PARKED+=("$NEXT") ;;
    *)  die "stopped at $NEXT — ${#MERGED[@]} issue(s) merged this run." ;;
  esac
done
