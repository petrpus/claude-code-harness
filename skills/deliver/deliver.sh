#!/usr/bin/env bash
# deliver/deliver.sh — deliver a Map issue: every issue in its Delivery
# section becomes its own PR into the current (integration) branch, built by
# autopilot's loop.sh, verified, squash-merged, and ticked on the Map — in
# blocking-edge order. docs/prd/0003-deliver.md, ADR-0007, ADR-0008.
#
# Every issue PR gets an independent review (agents/code-reviewer.md, in a
# throwaway worktree, #59) before it may merge. A review that requests changes
# gets bounded fix rounds on the same PR (#63): its in-scope findings become
# plan items, autopilot runs again on the same state dir, and the new head is
# re-verified, pushed fast-forward and reviewed again; out-of-scope findings
# become needs-triage follow-up issues listed on the Map. Before merging,
# final_verify (#60) re-fetches and, if the integration branch moved, merges
# it into the issue branch — a conflict parks the issue; a clean merge is
# re-verified and pushed. A merge the forge refuses (repo forbids squash:
# retried as a plain --merge; anything else) goes back through final_verify
# once before giving up. An issue that cannot get there — autopilot did not
# finish, verify failed on its head, the review still held it with no fix
# rounds left, the base moved into a conflict, the forge refused the merge
# twice, or CI failed or timed out — is PARKED (#58): labelled needs-human,
# its PR back to draft, a comment saying why; issues that depend on it are
# skipped and independent ones continue. Before merging, ci_wait (#60) polls
# `gh pr checks` until nothing is pending or --ci-timeout passes; no checks at
# all after --ci-grace-seconds is "no CI" and merges anyway. A red check gets
# a fix round (#60): the failed run's log tail is appended to the issue's
# plan as a new item, autopilot resumes to fix it, and the head goes back
# through final_verify and ci_wait. Review and CI fix rounds draw from one
# per-issue budget (--max-fix-rounds); no rounds left, a second red CI, or
# autopilot not finishing a fix parks instead. A failure of the machinery
# itself (the forge unreachable, a dirty checkout, a review that touched the
# checkout) ends the run instead. Not built yet: the launcher.
#
# Usage:
#   deliver.sh --map <N> [--verify-cmd '<cmd>']
#              [--issue-max-iterations 10] [--issue-max-minutes 120]
#              [--issue-budget-usd 10] [--review-model sonnet]
#              [--extra-allowed-tools '<csv>'] [--per-call-timeout <s>]
#              [--plan-max-items 3] [--verify-every-iteration] [--iteration-verify-cmd '<cmd>']
#              [--ci-poll-seconds 30] [--ci-timeout 1800] [--ci-grace-seconds 120]
#              [--max-fix-rounds 2]
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
# non-terminal against GitHub — GitHub wins (docs/adr/0012-*.md) — before
# walking the graph exactly as a fresh run would: an issue whose branch this
# run's own state.json still names is continued (a pushed head without a PR
# gets one; an open PR is re-entered for review — round 1's dedupe marker,
# #61 S2, keeps that from posting twice — then merged; a local-only branch
# resumes autopilot with loop.sh --resume-run); any other leftover branch is
# still parked, unchanged from #58. --retry '#N' (with --resume) forgets a
# parked issue's recorded branch/PR, closes/deletes what it left behind,
# drops needs-human, and gives it a fresh inner run.
#
# --max-fix-rounds bounds the fix rounds one issue may spend, review and CI
# alike (docs/adr/0010-*.md, docs/adr/0011-*.md): every in-scope blocker/issue
# finding of a changes_requested round becomes a plan item (R<k>.<j>),
# autopilot runs again on the same issue state dir, the new head is verified,
# pushed fast-forward only, and reviewed again with the previous round's
# findings inlined. A review still requesting changes with no round left
# parks the issue, naming the review count and the PR.

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
CI_POLL_SECONDS=30
CI_TIMEOUT_SECONDS=1800
CI_GRACE_SECONDS=120
MAX_FIX_ROUNDS=2
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
    --ci-poll-seconds)      CI_POLL_SECONDS="$2"; shift 2 ;;
    --ci-timeout)           CI_TIMEOUT_SECONDS="$2"; shift 2 ;;
    --ci-grace-seconds)     CI_GRACE_SECONDS="$2"; shift 2 ;;
    --max-fix-rounds)       MAX_FIX_ROUNDS="$2"; shift 2 ;;
    --budget-usd)           BUDGET_USD="$2"; shift 2 ;;
    --max-minutes)          MAX_MINUTES="$2"; shift 2 ;;
    --resume)               RESUME=1; shift ;;
    --retry)                RETRY_ISSUE="${2#\#}"; shift 2 ;;
    -h|--help)              sed -n '2,82p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done
[[ "$MAP" =~ ^[0-9]+$ ]] || die "--map <issue number> is required"
[[ -z "$PER_CALL_TIMEOUT" || "$PER_CALL_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "--per-call-timeout takes whole seconds"
[[ "$PLAN_MAX_ITEMS" =~ ^[0-9]+$ ]] || die "--plan-max-items takes a whole number (0: no limit)"
[[ "$CI_POLL_SECONDS" =~ ^[0-9]+$ ]] || die "--ci-poll-seconds takes whole seconds"
[[ "$CI_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || die "--ci-timeout takes whole seconds"
[[ "$CI_GRACE_SECONDS" =~ ^[0-9]+$ ]] || die "--ci-grace-seconds takes whole seconds"
[[ "$MAX_FIX_ROUNDS" =~ ^[0-9]+$ ]] || die "--max-fix-rounds takes a whole number (0: no fix rounds)"
[[ -z "$BUDGET_USD" || "$BUDGET_USD" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--budget-usd takes a non-negative number"
[[ -z "$MAX_MINUTES" || "$MAX_MINUTES" =~ ^[1-9][0-9]*$ ]] || die "--max-minutes takes a whole number of minutes"
[[ -z "$RETRY_ISSUE" || "$RETRY_ISSUE" =~ ^[0-9]+$ ]] || die "--retry takes an issue number ('#N' or N)"
[[ -z "$RETRY_ISSUE" || "$RESUME" -eq 1 ]] || die "--retry only makes sense with --resume"
[[ -z "$ITERATION_VERIFY_CMD" || "$VERIFY_EVERY_ITERATION" -eq 0 ]] \
  || die "--iteration-verify-cmd is for the default mode; drop it with --verify-every-iteration"

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
# the issue branch, not the integration branch (docs/adr/0012-*.md).
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
  # Only a review row describes a model call; a ci row (#60) makes none, and
  # carrying the last review's AGENT_LAST_* figures into it would count that
  # review's cost twice — in /usage-report and in --budget-usd (#61).
  local model="$REVIEW_MODEL" dur="${AGENT_LAST_DURATION:-0}" cost="${AGENT_LAST_COST:-0}"
  local tin="${AGENT_LAST_IN_TOKENS:-0}" tout="${AGENT_LAST_OUT_TOKENS:-0}" rc="${AGENT_LAST_RC:-0}"
  if [[ "$1" != "review" ]]; then model=""; dur=0; cost=0; tin=0; tout=0; rc=0; fi
  jq -cn --arg run "$RUN_ID" --arg phase "$1" --arg model "$model" \
     --argjson issue "$2" --argjson round "$3" --arg verdict "$4" \
     --argjson dur "$dur" --argjson cost "$cost" \
     --argjson in "$tin" --argjson out "$tout" \
     --argjson rc "$rc" \
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
CI_NOTE=""  # ci_wait's note for the merge comment ("no CI reported"), per issue
PARK_REASON=""   # set by deliver_issue before it returns 10
PARK_LOG=""      # optionally, a log file whose tail the park comment carries (a red CI run's)
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

# add_map_follow_up <fn> <line>
#   Appends <line> under the Map's '## Follow-ups' section (map_add_follow_up,
#   map.sh) unless #<fn> is already listed there. Same re-read/write/read-back
#   retry as tick_map (ADR-0008 decision 6): a human editing the Map at the
#   same moment must not silently lose the runner's write. Never touches
#   '## Delivery' — a follow-up is recorded, not scheduled.
add_map_follow_up() {
  local fn="$1" line="$2" attempt fresh="$RUN_DIR/map.fresh.md" new="$RUN_DIR/map.new.md"
  for attempt in 1 2 3; do
    forge_issue_body "$MAP" "$fresh" || continue
    map_follow_up_has "$fresh" "$fn" && return 0
    map_add_follow_up "$fresh" "$fn" "$line" > "$new" || return 1
    forge_issue_set_body "$MAP" "$new" || continue
    forge_issue_body "$MAP" "$fresh" && map_follow_up_has "$fresh" "$fn" && return 0
  done
  return 1
}

# process_out_of_scope_findings <n> <pr> <dir> <round>
#   Every out-of-scope blocker/issue finding of round <round> (suggestions
#   skipped, review_out_of_scope_items) becomes a needs-triage follow-up
#   issue — or is matched to one that already carries its finding-hash marker
#   (forge_issue_search, dedupe) — appended under the Map's '## Follow-ups'
#   and recorded for this issue's PR body (#63). Never holds the verdict
#   (review_parse already keeps out-of-scope findings out of that) and never
#   executed: adding it to '## Delivery' is a human decision after triage
#   (ADR-0008 decision 7).
process_out_of_scope_findings() {
  local n="$1" pr="$2" dir="$3" round="$4" findings file line sev note issue_title
  local hash marker fn title body_file
  findings="$(jq -c '.findings' "$dir/review-$round.json" 2>/dev/null)" || return 0
  while IFS=$'\t' read -r file line sev note issue_title; do
    [[ -n "$file" ]] || continue
    hash="$(finding_hash "$file" "$line" "$sev")"
    marker="<!-- deliver:finding $hash -->"
    title="${issue_title:-fix: $sev at $file:$line}"
    fn="$(forge_issue_search "$hash")"
    if [[ -z "$fn" ]]; then
      body_file="$dir/follow-up-$hash.md"
      {
        echo "Found reviewing #$n (PR #$pr), part of map #$MAP."
        echo
        echo "- Severity: $sev"
        echo "- Location: \`$file:$line\`"
        if [[ -n "$note" ]]; then echo; echo "$note"; fi
        echo
        echo "$marker"
      } > "$body_file"
      forge_label_ensure needs-triage e4e669 "Out-of-scope review finding awaiting human triage before it joins a Map"
      fn="$(forge_issue_create "$title" "$body_file" needs-triage)" \
        || { log "#$n: could not create a follow-up issue for $file:$line — continuing"; continue; }
      log "#$n: follow-up issue #$fn created for out-of-scope $sev at $file:$line"
    else
      log "#$n: follow-up issue #$fn already carries this finding — reusing it"
    fi
    add_map_follow_up "$fn" "- [ ] #$fn found reviewing #$n (PR #$pr): $title" \
      || log "#$n: could not record follow-up #$fn on map #$MAP (continuing)"
    grep -q "^$fn"$'\t' "$dir/follow-ups.pr.list" 2>/dev/null \
      || printf '%s\t%s\n' "$fn" "$title" >> "$dir/follow-ups.pr.list"
  done < <(review_out_of_scope_items "$findings")
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
    [[ -n "$CI_NOTE" ]] && printf 'CI: %s.\n' "$CI_NOTE"
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
# recorded (docs/adr/0012-*.md): the Map tick or a MERGED PR settles it as
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
    st="$(jq -r '.state // empty' <<<"$entry")"
    if [[ "$n" == "$RETRY_ISSUE" ]]; then
      # Only a parked attempt is a dead end to discard. Anything else is work
      # in flight (building, a PR open, merging…) or already settled; closing
      # its PR and deleting its branch would throw away a live attempt.
      [[ "$st" == "parked" ]] \
        || die "--retry #$n: run $RUN_ID records #$n as '${st:-unknown}', not parked — --retry only discards a parked attempt (a plain --resume continues this one)."
      reconcile_retry "$n" "$entry"
      RETRY_MATCHED=1
      continue
    fi
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
# review_issue <n> <pr> <base_sha> <head_sha> <dir> <round> [prev_findings_json]
#   One review round. A repeated no-usable-verdict reply parks the issue
#   itself (PARK_REASON set here) — it is not a fix round; the caller (#63)
#   only turns a real changes_requested verdict into one, by checking whether
#   <dir>/review-<round>.json exists (only written when a verdict parsed).
review_issue() {
  local n="$1" pr="$2" base_sha="$3" head_sha="$4" dir="$5" round="$6" prev="${7:-[]}"
  local attempt rc out verdict comment="$dir/review-$round.comment.md"
  for attempt in 1 2; do
    out="$dir/review-$round"
    review_run "$n" "$round" "$BASE" "$base_sha" "$head_sha" "$dir/PROMPT.md" "$out" "$REVIEW_MODEL" "$prev"; rc=$?
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
           log "#$n: round $round — the reviewer returned no usable verdict — retrying once."
           continue
         fi
         review_comment "$n" "$round" "$head_sha" "$out.md" "" > "$comment"
         forge_pr_comment_has_marker "$pr" "$(review_marker "$n" "$round" "$head_sha")" \
           || forge_pr_comment "$pr" "$comment" || true
         PARK_REASON="round $round's reviewer returned no usable verdict twice (PR #$pr)"
         return 10 ;;
      3) deliver_logline review "$n" "$round" breach
         die "#$n: SAFETY BREACH — the checkout changed during round $round's review of PR #$pr: $(tr '\n' ' ' < "$out.breach"). Stopping the run; nothing further is pushed or merged." ;;
      *) log "#$n: could not create round $round's review worktree — stopping."; return 1 ;;
    esac
  done
  review_comment "$n" "$round" "$head_sha" "$out.md" "$out.json" > "$comment"
  # A --resume re-entering a round recomputes the same marker (issue, round,
  # head), so a review the interrupted attempt already posted is not posted
  # twice (#61).
  forge_pr_comment_has_marker "$pr" "$(review_marker "$n" "$round" "$head_sha")" \
    || forge_pr_comment "$pr" "$comment" || log "#$n: could not post round $round's review on PR #$pr (continuing)"
  verdict="$(jq -r '.verdict' "$out.json")"
  if [[ "$verdict" != "approve" ]]; then
    return 10
  fi
  log "#$n: round $round's review approved PR #$pr"
  return 0
}

# ---------------------------------------------------------------------------
# final_verify <n> <dir> — the head that will be pushed and merged, verified
# on top of the current base (#60). Runs on the issue branch (checked out by
# the caller). Fetches; if origin/$BASE is not an ancestor of HEAD, merges it
# in — a conflict aborts the merge and parks with the conflicting paths in
# PARK_REASON. Verify always runs, in a clean tree, on the (possibly merged)
# head; whenever HEAD ends up ahead of (or without) origin/$CUR_BRANCH — a
# base merge, or a re-entry after a CI fix round committed new work — it is
# pushed with forge_push_update. That covers the first call too (before the
# branch is ever pushed — a push here quietly becomes the branch's first).
# Returns 0 verified · 10 park (PARK_REASON set) · 1 stop the run.
# ---------------------------------------------------------------------------
final_verify() {
  local n="$1" dir="$2" verify_rc merged=0 head_now conflicts
  git fetch -q origin || { log "#$n: git fetch failed — stopping."; return 1; }
  if ! git merge-base --is-ancestor "origin/$BASE" HEAD; then
    if ! git merge -q --no-edit "origin/$BASE" > "$dir/base-merge.log" 2>&1; then
      conflicts="$(git diff --name-only --diff-filter=U | tr '\n' ' ')"
      git merge --abort
      PARK_REASON="the base branch \`$BASE\` moved and the merge conflicts on: ${conflicts:-(unknown paths)}"
      return 10
    fi
    merged=1
    log "#$n: \`$BASE\` moved — merged origin/$BASE into the issue branch ($(git rev-parse --short HEAD))"
  fi
  # Autopilot's BUILD may have edited what verify runs: no forge credentials.
  agent_run_without_forge_credentials bash -c "$VERIFY_CMD" > "$dir/final-verify.log" 2>&1
  verify_rc=$?
  if [[ "${AGENT_REFUSED:-0}" -eq 1 ]]; then
    log "#$n: forge credentials could not be withheld for verify (no private temp dir) — stopping the run."
    return 1
  fi
  head_now="$(git rev-parse HEAD)"
  if [[ "$verify_rc" -ne 0 ]]; then
    [[ -z "$(git status --porcelain)" ]] || { log "#$n: verify failed and left the checkout dirty — stopping."; return 1; }
    PARK_REASON="verify failed on the head autopilot finished with (\`${head_now:0:12}\`)"
    return 10
  fi
  [[ -z "$(git status --porcelain)" ]] || { log "#$n: verify changed the checkout — stopping."; return 1; }
  if [[ "$merged" -eq 1 || "$(git rev-parse "origin/$CUR_BRANCH" 2>/dev/null)" != "$head_now" ]]; then
    forge_push_update "$CUR_BRANCH" || { log "#$n: push failed — stopping."; return 1; }
  fi
  return 0
}

# ---------------------------------------------------------------------------
# ci_wait <n> <pr> <dir> <round> — between review and merge (#60). Polls
# forge_pr_checks every $CI_POLL_SECONDS until no reported check is pending
# or $CI_TIMEOUT_SECONDS passes. No checks reported at all once
# $CI_GRACE_SECONDS has elapsed is "no CI" — logged (deliver_logline ci) and
# merges anyway, same as all green; CI_NOTE is set for the merge comment. A
# reported failure sets CI_FAILED_JSON (the failing checks, name+link) and
# parks with their names — the caller may spend a fix round instead (#60);
# still pending at the timeout parks too, with no fix round (the check never
# actually failed). <round> is only for the run log, so a fix round's second
# poll is told apart from the first.
# Returns 0 merge (CI_NOTE, CI_RESULT set) · 10 park (PARK_REASON, CI_RESULT
# set) · 1 stop the run.
# ---------------------------------------------------------------------------
CI_NOTE=""
CI_RESULT=""
CI_FAILED_JSON="[]"
ci_wait() {
  local n="$1" pr="$2" dir="$3" round="${4:-1}" start now elapsed checks pending failed
  start="$(date +%s)"
  CI_NOTE=""; CI_RESULT=""; CI_FAILED_JSON="[]"
  while :; do
    checks="$(forge_pr_checks "$pr")"
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$checks" || checks="[]"
    now="$(date +%s)"; elapsed=$(( now - start ))
    if [[ "$(jq 'length' <<<"$checks")" -eq 0 ]]; then
      if [[ "$elapsed" -ge "$CI_GRACE_SECONDS" ]]; then
        log "#$n: no CI reported on PR #$pr after ${CI_GRACE_SECONDS}s — merging without it."
        deliver_logline ci "$n" "$round" none
        CI_NOTE="no CI reported"
        CI_RESULT="none"
        return 0
      fi
    else
      pending="$(jq '[.[] | select(.bucket == "pending")] | length' <<<"$checks")"
      if [[ "$pending" -eq 0 ]]; then
        CI_FAILED_JSON="$(jq -c '[.[] | select(.bucket == "fail")]' <<<"$checks")"
        failed="$(jq -r '.[].name' <<<"$CI_FAILED_JSON" | tr '\n' ',' | sed 's/,$//')"
        if [[ -n "$failed" ]]; then
          deliver_logline ci "$n" "$round" fail
          PARK_REASON="CI failed on PR #$pr: $failed"
          CI_RESULT="fail"
          return 10
        fi
        deliver_logline ci "$n" "$round" pass
        log "#$n: CI is green on PR #$pr"
        CI_RESULT="pass"
        return 0
      fi
    fi
    if [[ "$elapsed" -ge "$CI_TIMEOUT_SECONDS" ]]; then
      deliver_logline ci "$n" "$round" timeout
      PARK_REASON="CI still pending after ${CI_TIMEOUT_SECONDS}s on PR #$pr"
      CI_RESULT="timeout"
      return 10
    fi
    sleep "$CI_POLL_SECONDS"
  done
}

# round_budget_use <dir> — spends one fix round against the issue's shared
# budget (--max-fix-rounds, default 2; #63's review fix rounds draw from the
# same counter, kept in $dir/ROUNDS_USED — plain state, not committed, like
# the rest of the autopilot state dir). Echoes the round number just spent;
# returns 1 without spending anything when the budget is already gone.
round_budget_use() {
  local dir="$1" used
  used="$(cat "$dir/ROUNDS_USED" 2>/dev/null || echo 0)"
  [[ "$used" =~ ^[0-9]+$ ]] || used=0
  [[ "$used" -lt "$MAX_FIX_ROUNDS" ]] || return 1
  used=$(( used + 1 ))
  echo "$used" > "$dir/ROUNDS_USED"
  printf '%s\n' "$used"
}

# ci_failed_log_fetch <dir> — the tail of the failed run's log for the first
# failed check in CI_FAILED_JSON (ci_wait must have just set it), fetched with
# forge_ci_failed_log from the run id in the check's link and written to
# $dir/ci-fail-<k>.log, k counting this issue's red CI results (1, 2, …).
# Echoes the file's path; the file is empty when the link names no run or the
# log is gone — less context for whoever reads it, never a reason to stop.
ci_failed_log_fetch() {
  local dir="$1" k=1 link run_id logf
  while [[ -e "$dir/ci-fail-$k.log" ]]; do k=$(( k + 1 )); done
  logf="$dir/ci-fail-$k.log"
  link="$(jq -r '.[0].link // empty' <<<"$CI_FAILED_JSON")"
  run_id="$(grep -oE '/runs/[0-9]+' <<<"$link" | head -1 | grep -oE '[0-9]+')"
  if [[ -n "$run_id" ]]; then
    forge_ci_failed_log "$run_id" > "$logf" 2>/dev/null
  else
    : > "$logf"
  fi
  printf '%s\n' "$logf"
}

# ci_fix_round <n> <pr> <dir> <round> — one CI fix round (#60), spent by the
# caller against round_budget_use before this runs. Runs on the issue branch
# (checked out by the caller). Fetches the failed run's log tail
# (ci_failed_log_fetch), appends a new `- [ ] C<round> Fix red CI: <check>`
# item to the issue's IMPLEMENTATION_PLAN.md with the log fenced as data
# (read by the model, not parsed as a plan line), re-opens `STATUS:
# in-progress`, and resumes autopilot on the same state dir. A finished,
# clean run is re-verified (final_verify) and pushed; anything else parks
# with the log tail as PARK_LOG.
# Returns 0 fixed, re-verified and pushed · 10 park (PARK_REASON set) · 1
# stop the run.
# ---------------------------------------------------------------------------
ci_fix_round() {
  local n="$1" pr="$2" dir="$3" round="$4"
  local check logf plan="$dir/IMPLEMENTATION_PLAN.md" fence loop_rc status_state
  check="$(jq -r '.[0].name // "CI"' <<<"$CI_FAILED_JSON")"
  logf="$(ci_failed_log_fetch "$dir")"
  fence="$(md_tilde_fence < "$logf")"
  {
    echo
    echo "- [ ] C$round Fix red CI: $check"
    echo
    echo "CI check `$check` failed on PR #$pr. Tail of the failed run's log:"
    echo
    echo "$fence"
    cat "$logf"
    echo "$fence"
  } >> "$plan"
  sed -i.bak 's/^STATUS: done/STATUS: in-progress/' "$plan" 2>/dev/null && rm -f "$plan.bak"
  log "#$n: CI failed on PR #$pr (`$check`) — fix round $round: appended plan item C$round, resuming autopilot."

  run_autopilot "$dir" --resume-run; loop_rc=$?
  status_state="$(jq -r '.state // "?"' "$dir/status.json" 2>/dev/null || echo '?')"
  if [[ "$loop_rc" -eq 1 ]]; then
    log "#$n: autopilot refused to resume for the CI fix round (exit 1) — stopping the run."
    return 1
  fi
  if [[ -n "$(git status --porcelain)" ]]; then
    log "#$n: autopilot left a dirty tree after the CI fix round — stopping."
    return 1
  fi
  if [[ "$loop_rc" -ne 0 || "$status_state" != "done" ]]; then
    PARK_REASON="the CI fix round for PR #$pr did not finish (autopilot ended '$status_state', exit $loop_rc); failed check: `$check`"
    PARK_LOG="$logf"
    return 10
  fi

  final_verify "$n" "$dir"
  return $?
}

# ---------------------------------------------------------------------------
# Shared by an issue's first autopilot run and every fix round (#63):
# run_autopilot fires one loop.sh invocation with this run's flags;
# autopilot_gates checks its outcome; final_verify (above) re-verifies the
# head with no forge credentials in reach; write_pr_body (re)builds the PR body
# from the issue's current plan and latest autopilot status.
# ---------------------------------------------------------------------------

# run_autopilot <dir> [loop.sh flag…] — a review fix round starts a fresh
# loop.sh run on the same state dir (its own --issue-max-* caps; the number
# of rounds is what --max-fix-rounds bounds); a CI fix round passes
# --resume-run and continues the issue's run instead (#60).
run_autopilot() {
  local dir="$1"; shift
  local n="${dir##*/}" issue_budget_eff issue_minutes_eff loop_rc
  local -a loop_timeout=() loop_pace=() loop_extra=()
  [[ -n "$PER_CALL_TIMEOUT" ]] && loop_timeout=(--per-call-timeout "$PER_CALL_TIMEOUT")
  [[ "$PLAN_MAX_ITEMS" -gt 0 ]] && loop_pace+=(--plan-max-items "$PLAN_MAX_ITEMS")
  if [[ "$VERIFY_EVERY_ITERATION" -eq 0 ]]; then
    loop_pace+=(--verify-at-completion)
    [[ -n "$ITERATION_VERIFY_CMD" ]] && loop_pace+=(--iteration-verify-cmd "$ITERATION_VERIFY_CMD")
  fi
  [[ -n "$EXTRA_ALLOWED_TOOLS" ]] && loop_extra=(--extra-allowed-tools "$EXTRA_ALLOWED_TOOLS")
  # Per-issue caps never exceed what the global --budget-usd / --max-minutes
  # have left (#61); recorded on the issue's state before the call so a
  # --resume can see what this attempt was actually bounded by.
  issue_budget_eff="$(clipped_issue_budget)"
  issue_minutes_eff="$(clipped_issue_minutes)"
  state_issue_update "$RUN_DIR" "$n" \
    "$(jq -cn --argjson b "$issue_budget_eff" --argjson m "$issue_minutes_eff" \
         '{state:"building", issue_budget_usd:$b, issue_max_minutes:$m}')"
  # Indented line by line with a read loop, not sed: sed block-buffers into a
  # pipe, and a run log behind `| tee` then stayed empty for half an hour.
  bash "$LOOP" --state-dir "$dir" --verify-cmd "$VERIFY_CMD" ${loop_extra[@]+"${loop_extra[@]}"} \
    --max-iterations "$ISSUE_MAX_ITERATIONS" --max-minutes "$issue_minutes_eff" \
    --budget-usd "$issue_budget_eff" --stop-file "$RUN_DIR/STOP" \
    ${loop_timeout[@]+"${loop_timeout[@]}"} ${loop_pace[@]+"${loop_pace[@]}"} "$@" \
    2> >(while IFS= read -r line || [[ -n "$line" ]]; do printf '  %s\n' "$line"; done >&2)
  loop_rc=$?
  # loop.sh's own STOP-file exit is this run's stop, never a park (#61) — the
  # STOP file it found is the same one check_caps would find.
  [[ "$loop_rc" -eq 6 ]] && stop_run 6 stopped
  check_caps "after a build (#$n)"
  return "$loop_rc"
}

# autopilot_gates <n> <dir> <prev_head> <loop_rc>
#   Exit 1 (autopilot refusing to start) and a dirty tree left behind stop the
#   whole run (0 is not this issue's fault); anything short of a done status,
#   or a run that produced no commit beyond <prev_head>, parks this issue.
autopilot_gates() {
  local n="$1" dir="$2" prev_head="$3" loop_rc="$4" status_state
  status_state="$(jq -r '.state // "?"' "$dir/status.json" 2>/dev/null || echo '?')"
  if [[ "$loop_rc" -eq 1 ]]; then
    log "#$n: autopilot refused to start (exit 1) — stopping the run. State: $dir"
    return 1
  fi
  [[ -z "$(git status --porcelain)" ]] || { log "#$n: autopilot left a dirty tree — stopping."; return 1; }
  if [[ "$loop_rc" -ne 0 || "$status_state" != "done" ]]; then
    PARK_REASON="autopilot ended '$status_state' (exit $loop_rc) without finishing"
    return 10
  fi
  if [[ "$(git rev-parse HEAD)" == "$prev_head" ]]; then
    PARK_REASON="autopilot reported done without a single commit"
    return 10
  fi
  return 0
}

# write_pr_body <n> <dir> <head_sha>  — (re)builds the PR body from the
# issue's current plan and the latest autopilot status; used for the PR's
# opening body and, after every fix round, to keep it in sync (#63).
write_pr_body() {
  local n="$1" dir="$2" head_sha="$3" iters cost
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
    if [[ -s "$dir/follow-ups.pr.list" ]]; then
      echo
      echo "## Follow-ups"
      echo
      while IFS=$'\t' read -r fn ftitle; do
        echo "- #$fn — $ftitle"
      done < "$dir/follow-ups.pr.list"
    fi
    echo
    echo "Delivered by \`/deliver\` (claude-code-harness) — run \`$RUN_ID\`."
  } > "$dir/pr-body.md"
}

# append_fix_round_items <plan_file> <round> <findings_json>
#   Appends round <round>'s in-scope blocker/issue findings as fresh plan
#   items (review_fix_items, review.sh) and reopens the plan (STATUS:
#   in-progress) for another autopilot run. Returns 1, plan untouched, when
#   the round named nothing to fix — a changes_requested verdict with no
#   in-scope blocker/issue finding is a reviewer contract violation, not an
#   ordinary fix round.
append_fix_round_items() {
  local plan="$1" round="$2" findings="$3" items
  items="$(review_fix_items "$round" "$findings")"
  [[ -n "$items" ]] || return 1
  { grep -v '^STATUS:' "$plan" 2>/dev/null; printf '%s\n' "$items"; echo; echo 'STATUS: in-progress'; } \
    > "$plan.tmp" && mv "$plan.tmp" "$plan"
}

# ---------------------------------------------------------------------------
# One issue: branch → autopilot → push → PR → review (+ fix rounds) → CI →
# merge → tick.
# ---------------------------------------------------------------------------
# Returns 0 merged, 10 park (PARK_REASON says why), 11 already parked (left
# alone, skipped with its dependents), 1 end the run.
deliver_issue() {
  local id="$1" n dir line map_title issue_title labels state title branch
  local pr="" head_sha
  local loop_rc gate_rc fv_rc prev_head base_sha round prev_findings review_rc findings
  n="$(map_issue_number "$id")"
  dir="$RUN_DIR/issues/$n"
  mkdir -p "$dir"
  # Per-issue state starts empty: every early return below may park, and a
  # park must never name an earlier issue's PR or branch.
  CUR_PR=""; CUR_BRANCH=""; PARK_LOG=""; CI_NOTE=""
  CUR_ISSUE="$n"
  # A resumed issue keeps what an earlier attempt recorded (branch, PR,
  # review round) — state_issue_update merges, it never drops a field.
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
  # 0012-*.md); any other leftover branch — a stray one, or this branch under
  # a fresh (non-resuming) run — cannot be told apart from someone else's
  # work, so it still parks the issue and only the issue (#58).
  local resume_point="fresh" known_branch=""
  if git rev-parse --verify -q "refs/heads/$branch" >/dev/null 2>&1 \
     || [[ -n "$(git ls-remote --heads origin "$branch" 2>/dev/null)" ]]; then
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
    local -a loop_resume=()
    if [[ "$resume_point" == "fresh" ]]; then
      log "#$n: $title → $branch"
      git switch -q -c "$branch" "origin/$BASE" || return 1
      CUR_BRANCH="$branch"
    else
      git switch -q "$branch" || return 1
      loop_resume=(--resume-run)
    fi
    state_issue_update "$RUN_DIR" "$n" "$(jq -cn --arg b "$branch" '{state:"building", branch:$b}')"
    [[ -f "$dir/PROMPT.md" ]] || charter_from_issue "$dir/issue.json" "$MAP_PLAN" "$MAP" > "$dir/PROMPT.md"

    # --- autopilot, one run per issue in its own state dir ---
    # --extra-allowed-tools reaches autopilot's BUILD only — never the verifier
    # or the reviewer, and it is the caller's to keep free of gh / git push
    # (ADR-0007); the runner refuses such entries below. The fork point, not
    # HEAD, is what "no commit" is measured from: a resumed build may already
    # have committed before it was interrupted.
    prev_head="$(git merge-base HEAD "origin/$BASE")"
    run_autopilot "$dir" ${loop_resume[@]+"${loop_resume[@]}"}; loop_rc=$?
    autopilot_gates "$n" "$dir" "$prev_head" "$loop_rc"; gate_rc=$?
    [[ "$gate_rc" -eq 0 ]] || return "$gate_rc"

    # --- final-verify: the merged head that will be pushed and merged ---
    final_verify "$n" "$dir"; fv_rc=$?
    case "$fv_rc" in
      0)  ;;
      10) return 10 ;;
      *)  return 1 ;;
    esac
    head_sha="$(git rev-parse HEAD)"

    # --- PR ---
    write_pr_body "$n" "$dir" "$head_sha"
    check_caps "before a PR (#$n)"
    forge_push_branch "$branch" || { log "#$n: push failed — stopping."; return 1; }
    pr="$(forge_pr_create "$BASE" "$branch" "$title" "$dir/pr-body.md")" \
      || { log "#$n: opening the PR failed — stopping."; return 1; }
  else
    # Pushed on an earlier attempt (pr-needed: no PR yet; pr-open: PR $pr).
    # Review and any fix round work on the checked-out branch, so it must
    # match what origin has. A local copy ahead of origin (a fix round that
    # committed but never pushed) is re-verified and pushed by final_verify;
    # one that diverged from origin is not this run's to reconcile.
    git fetch -q origin || { log "#$n: git fetch failed — stopping."; return 1; }
    if git rev-parse --verify -q "refs/heads/$branch" >/dev/null 2>&1; then
      git switch -q "$branch" || return 1
    else
      git switch -q -c "$branch" --track "origin/$branch" || return 1
    fi
    if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$branch")" ]]; then
      if git merge-base --is-ancestor HEAD "origin/$branch"; then
        git merge -q --ff-only "origin/$branch" || return 1
      elif git merge-base --is-ancestor "origin/$branch" HEAD; then
        log "#$n: local \`$branch\` is ahead of origin — re-verifying and pushing it."
        final_verify "$n" "$dir" || return $?
      else
        log "#$n: local \`$branch\` and origin/$branch have diverged — stopping; reconcile by hand."
        return 1
      fi
    fi
    head_sha="$(git rev-parse HEAD)"
    write_pr_body "$n" "$dir" "$head_sha"
    if [[ "$resume_point" == "pr-needed" ]]; then
      check_caps "before a PR (#$n)"
      pr="$(forge_pr_create "$BASE" "$branch" "$title" "$dir/pr-body.md")" \
        || { log "#$n: opening the PR failed — stopping."; return 1; }
    fi
  fi
  CUR_PR="$pr"
  log "#$n: PR #$pr open"
  state_issue_update "$RUN_DIR" "$n" "$(jq -cn --argjson p "$pr" '{state:"pr-open", pr:$p}')"
  state_event "$RUN_DIR" "$n" pr-open ""

  # --- independent review, with bounded in-scope fix rounds (#63) ---
  # A --resume into an open PR picks up at the review round it recorded,
  # with that round's predecessor's findings inlined as before; the round's
  # marker (issue, round, head) keeps an already-posted review from being
  # posted twice (#61).
  base_sha="$(git rev-parse "origin/$BASE")"
  round=1; prev_findings="[]"
  if [[ "$resume_point" == "pr-open" ]]; then
    round="$(jq -r --arg n "$n" '.issues[$n].round // 1' "$RUN_DIR/state.json" 2>/dev/null)"
    [[ "$round" =~ ^[1-9][0-9]*$ ]] || round=1
    [[ "$round" -gt 1 && -f "$dir/review-$((round - 1)).json" ]] \
      && prev_findings="$(jq -c '.findings' "$dir/review-$((round - 1)).json")"
  fi
  while :; do
    check_caps "before a review (#$n)"
    state_issue_update "$RUN_DIR" "$n" "$(jq -cn --argjson r "$round" '{state:"reviewing", round:$r}')"
    review_issue "$n" "$pr" "$base_sha" "$head_sha" "$dir" "$round" "$prev_findings"
    review_rc=$?
    [[ "$review_rc" -eq 0 || "$review_rc" -eq 10 ]] || return "$review_rc"
    if [[ -f "$dir/review-$round.json" ]]; then
      process_out_of_scope_findings "$n" "$pr" "$dir" "$round"
      if [[ -s "$dir/follow-ups.pr.list" ]]; then
        write_pr_body "$n" "$dir" "$head_sha"
        forge_pr_set_body "$pr" "$dir/pr-body.md" || log "#$n: could not update PR #$pr's body (continuing)"
      fi
    fi
    [[ "$review_rc" -eq 0 ]] && break
    # A repeated no-usable-verdict reply parks the issue itself (PARK_REASON
    # already set inside review_issue) and never gets a fix round; only a
    # parsed changes_requested verdict (review-<round>.json on disk) does.
    [[ -f "$dir/review-$round.json" ]] || return 10
    if ! round_budget_use "$dir" >/dev/null; then
      PARK_REASON="the review still requests changes after $round review(s) and no fix rounds are left (--max-fix-rounds $MAX_FIX_ROUNDS, PR #$pr)"
      return 10
    fi
    findings="$(jq -c '.findings' "$dir/review-$round.json")"
    append_fix_round_items "$dir/IMPLEMENTATION_PLAN.md" "$round" "$findings" || {
      PARK_REASON="round $round's review requested changes but named no in-scope blocker or issue to fix (PR #$pr)"
      return 10
    }
    log "#$n: round $round requested changes — fix round $((round + 1)) on the same PR #$pr"
    prev_head="$(git rev-parse HEAD)"
    run_autopilot "$dir"; loop_rc=$?
    autopilot_gates "$n" "$dir" "$prev_head" "$loop_rc"; gate_rc=$?
    [[ "$gate_rc" -eq 0 ]] || return "$gate_rc"
    final_verify "$n" "$dir" || return $?
    head_sha="$(git rev-parse HEAD)"
    # final_verify may have merged a moved base in: review the next round
    # against it, or its diff would count the base's new commits as the PR's.
    base_sha="$(git rev-parse "origin/$BASE")"
    write_pr_body "$n" "$dir" "$head_sha"
    # final_verify pushes only when HEAD is ahead of origin's copy of the
    # branch; this push is a no-op otherwise and keeps the round's push
    # explicit. Fast-forward only — never forced: a rejected push means the branch
    # moved from under this run, and that is a reason to stop, not overwrite.
    forge_push_branch "$branch" || { log "#$n: push failed — stopping."; return 1; }
    forge_pr_set_body "$pr" "$dir/pr-body.md" || log "#$n: could not update PR #$pr's body (continuing)"
    prev_findings="$findings"
    round=$(( round + 1 ))
  done

  # --- wait for CI before merging, with one fix round for a red check (#60) ---
  state_issue_update "$RUN_DIR" "$n" '{"state":"ci-wait"}'
  ci_wait "$n" "$pr" "$dir" 1; local ci_rc=$?
  if [[ "$ci_rc" -eq 10 && "$CI_RESULT" == "fail" ]]; then
    local ci_round fix_rc
    if ci_round="$(round_budget_use "$dir")"; then
      ci_fix_round "$n" "$pr" "$dir" "$ci_round"; fix_rc=$?
      case "$fix_rc" in
        0) head_sha="$(git rev-parse HEAD)"
           ci_wait "$n" "$pr" "$dir" "$(( ci_round + 1 ))"; ci_rc=$?
           if [[ "$ci_rc" -eq 10 && "$CI_RESULT" == "fail" ]]; then
             PARK_REASON="CI failed again on PR #$pr after fix round $ci_round: $(jq -r '[.[].name] | join(",")' <<<"$CI_FAILED_JSON")"
             PARK_LOG="$(ci_failed_log_fetch "$dir")"
           fi
           ;;
        10) ;;  # PARK_REASON / PARK_LOG already set inside ci_fix_round
        *)  return 1 ;;
      esac
    else
      PARK_REASON="CI failed on PR #$pr: $(jq -r '[.[].name] | join(",")' <<<"$CI_FAILED_JSON") (no fix rounds left)"
      PARK_LOG="$(ci_failed_log_fetch "$dir")"
      ci_rc=10
    fi
  fi
  [[ "$ci_rc" -eq 0 ]] || return "$ci_rc"

  # --- merge (from the base, so the forge never has the head checked out) ---
  # A refusal (branch protection, a base that moved again, …) goes back
  # through final_verify exactly once before parking (#60); forge_pr_merge
  # already falls back to a plain --merge on its own when the repo forbids
  # squash, so that case never reaches this retry at all.
  check_caps "before a merge (#$n)"
  state_issue_update "$RUN_DIR" "$n" '{"state":"merging"}'
  git switch -q "$BASE" || return 1
  local merge_retried=0
  while :; do
    if forge_pr_merge "$pr" "$head_sha" "$title (#$pr)" "$dir/pr-body.md" > "$dir/merge.log" 2>&1; then
      break
    fi
    if [[ "$merge_retried" -eq 1 ]]; then
      PARK_REASON="the forge refused to merge PR #$pr twice: $(tail -1 "$dir/merge.log")"
      return 10
    fi
    merge_retried=1
    log "#$n: merge of PR #$pr was refused — retrying once via final-verify: $(tail -1 "$dir/merge.log")"
    git switch -q "$branch" || return 1
    final_verify "$n" "$dir"; fv_rc=$?
    case "$fv_rc" in
      0)  head_sha="$(git rev-parse HEAD)" ;;
      10) return 10 ;;
      *)  return 1 ;;
    esac
    git switch -q "$BASE" || return 1
  done
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
  # final_verify's own `git fetch` may have moved origin/$BASE ahead of the
  # local branch (the base moved, #60) — catching up is a fast-forward, not
  # a foreign mutation, so it is folded in here rather than treated as one.
  [[ -z "$(git status --porcelain)" ]] || die "#$n: cannot park — the checkout is dirty."
  git switch -q "$BASE" || die "#$n: cannot park — cannot switch back to '$BASE'."
  git fetch -q origin && git merge -q --ff-only "origin/$BASE" \
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
    if [[ -n "$PARK_LOG" && -s "$PARK_LOG" ]]; then
      local log_fence
      log_fence="$(md_tilde_fence < "$PARK_LOG")"
      echo
      echo "<details><summary>Failed CI log (tail)</summary>"
      echo
      echo "$log_fence"
      cat "$PARK_LOG"
      echo "$log_fence"
      echo
      echo "</details>"
    fi
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
