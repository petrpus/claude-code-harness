#!/usr/bin/env bash
# autopilot/loop.sh — controlled long autonomous runs for Claude Code.
#
# Re-engineered from loopkit's run.sh with the safety machinery it lacked:
# hard verify gates, iteration/time/budget caps, per-call timeout, git
# checkpointing, stuck-detection, a concurrency lock, and a structured JSONL
# run log. Each iteration is a FRESH `claude -p` session — state lives on disk
# in tmp/autopilot/, never in a growing context window.
#
# See LOOP-PROTOCOL.md for the full protocol and safety rationale.
#
# Usage:
#   loop.sh [--max-iterations 10] [--max-minutes 120] [--budget-usd 10]
#           [--plan-model opus] [--build-model sonnet] [--verify-model haiku]
#           [--verify-cmd '<cmd>'] [--max-turns 80] [--per-call-timeout 1200]
#           [--extra-allowed-tools '<csv>'] [--holdout '<path>']
#           [--no-repo-map] [--resume-run] [--dry-run]
#
# Exit codes: 0 done+verified · 2 iteration cap · 3 time cap · 4 budget/stuck
#             cap · 1 runner error (bad preconditions, missing deps).

set -uo pipefail

# Preserve the original argv before the option-parsing loop below consumes it
# via `shift` — R1 needs it unmodified to re-exec itself (plus --resume-run)
# when a slice edits the runner mid-run.
ORIG_ARGV=("$@")

# ---------------------------------------------------------------------------
# Resolve plugin root from THIS script's location. Do NOT rely on
# $CLAUDE_PLUGIN_ROOT — that is only set for hook processes, and loop.sh runs
# as a plain Bash command.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFIER_AGENT="$PLUGIN_ROOT/agents/verifier.md"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

STATE_DIR="tmp/autopilot"
PROMPT_FILE="$STATE_DIR/PROMPT.md"
PLAN_FILE="$STATE_DIR/IMPLEMENTATION_PLAN.md"
MEMORY_FILE="$STATE_DIR/MEMORY.md"
FEEDBACK_FILE="$STATE_DIR/FEEDBACK.md"
STATUS_FILE="$STATE_DIR/status.json"
LOCK_FILE="$STATE_DIR/lock"

# Defaults (all overridable).
MAX_ITERATIONS=10
MAX_MINUTES=120
BUDGET_USD=10
PLAN_MODEL=opus
BUILD_MODEL=sonnet
VERIFY_MODEL=haiku
VERIFY_CMD=""
MAX_TURNS=80
PER_CALL_TIMEOUT=1200   # 20 min per claude -p call
RESUME=0
DRY_RUN=0
EXTRA_ALLOWED_TOOLS=""
HOLDOUT_ARG=""
REPO_MAP_ENABLED=1

BUILD_ALLOWED_TOOLS="Read,Edit,Write,Grep,Glob,Bash(npm run:*),Bash(npm test:*),Bash(pnpm:*),Bash(npx:*),Bash(node:*),Bash(tsx:*),Bash(git add:*),Bash(git commit:*),Bash(git diff:*),Bash(git status:*),Bash(git log:*),Bash(ls:*),Bash(cat:*),Bash(mkdir:*)"
VERIFY_ALLOWED_TOOLS="Read,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git status:*)"

log_err() { echo "autopilot: $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-iterations)   MAX_ITERATIONS="$2"; shift 2 ;;
    --max-minutes)      MAX_MINUTES="$2"; shift 2 ;;
    --budget-usd)       BUDGET_USD="$2"; shift 2 ;;
    --plan-model)       PLAN_MODEL="$2"; shift 2 ;;
    --build-model)      BUILD_MODEL="$2"; shift 2 ;;
    --verify-model)     VERIFY_MODEL="$2"; shift 2 ;;
    --verify-cmd)       VERIFY_CMD="$2"; shift 2 ;;
    --max-turns)        MAX_TURNS="$2"; shift 2 ;;
    --per-call-timeout) PER_CALL_TIMEOUT="$2"; shift 2 ;;
    --extra-allowed-tools) EXTRA_ALLOWED_TOOLS="$2"; shift 2 ;;
    --holdout)           HOLDOUT_ARG="$2"; shift 2 ;;
    --no-repo-map)       REPO_MAP_ENABLED=0; shift ;;
    --resume-run)       RESUME=1; shift ;;
    --dry-run)          DRY_RUN=1; shift ;;
    -h|--help)          sed -n '2,21p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) log_err "unknown flag: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Preconditions — refuse to start unless the run can be safe and gated.
# ---------------------------------------------------------------------------
command -v claude >/dev/null 2>&1 || { log_err "the 'claude' CLI is required"; exit 1; }
command -v jq     >/dev/null 2>&1 || { log_err "'jq' is required (parses claude -p JSON)"; exit 1; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { log_err "not inside a git repo"; exit 1; }
cd "$(git rev-parse --show-toplevel)" || { log_err "cannot cd to repo root"; exit 1; }

BRANCH="$(git branch --show-current 2>/dev/null || echo '')"
if [[ "$BRANCH" == "main" || "$BRANCH" == "master" || -z "$BRANCH" ]]; then
  log_err "refusing to run on '$BRANCH'. Check out a feature branch first."
  exit 1
fi

# Auto-detect a verify command if none was given.
if [[ -z "$VERIFY_CMD" ]]; then
  if [[ -f package.json ]] && jq -e '.scripts.verify' package.json >/dev/null 2>&1; then
    if [[ -f pnpm-lock.yaml ]]; then VERIFY_CMD="pnpm verify"; else VERIFY_CMD="npm run verify"; fi
  fi
fi
if [[ -z "$VERIFY_CMD" ]]; then
  log_err "no verify command found and --verify-cmd not given."
  log_err "Run '/project-infra verify' to provision one, or pass --verify-cmd '<cmd>'."
  exit 1
fi

# The BUILD prompt instructs the model to run the verify command, but the
# allowlist above mirrors a JS project template — a repo whose verify is its own
# script (./scripts/verify.sh, make verify, …) would have that call *denied*,
# leaving BUILD unable to prove a slice before ticking it. Grant exactly the
# resolved verify command, nothing broader.
#
# "Nothing broader" is the whole point, so the prefix grant is conditional —
# see allowlist.sh, which owns the derivation so it can be tested on its own.
# shellcheck source=allowlist.sh
. "$SCRIPT_DIR/allowlist.sh"
# select_next_slice() over the Plan DAG (docs/adr/0005-*.md) — own file so it's
# unit-testable without a run (scripts/verify.sh exercises it directly).
# shellcheck source=plan.sh
. "$SCRIPT_DIR/plan.sh"

# R1: bash parses this script's function bodies once, at startup — a slice
# whose job is to fix loop.sh/plan.sh/allowlist.sh therefore never changes the
# behaviour of the very process running it, only the next run a human starts
# by hand. runner_files_hash() lets each iteration notice its own sourced
# files changed on disk since startup and re-exec itself (see the check at
# the top of the main loop) so the fix applies within the same run. Hashing
# content (not mtime) means an edit that doesn't change the bytes — or a
# clock skew — never triggers a spurious reload.
runner_files_hash() {
  local f
  { for f in "$SCRIPT_DIR/loop.sh" "$SCRIPT_DIR/plan.sh" "$SCRIPT_DIR/allowlist.sh"; do
      [[ -f "$f" ]] && cat "$f"
    done
  } | cksum
}
STARTUP_RUNNER_HASH="$(runner_files_hash)"

BUILD_ALLOWED_TOOLS="${BUILD_ALLOWED_TOOLS},$(verify_grants "$VERIFY_CMD")"
if verify_grants_are_narrow "$VERIFY_CMD"; then
  log_err "verify command starts with an interpreter ('${VERIFY_CMD%% *}'); granting only the exact command."
fi
[[ -n "$EXTRA_ALLOWED_TOOLS" ]] && BUILD_ALLOWED_TOOLS="${BUILD_ALLOWED_TOOLS},${EXTRA_ALLOWED_TOOLS}"

[[ -f "$PROMPT_FILE" ]] || { log_err "missing $PROMPT_FILE. Scaffold it from the autopilot skill first."; exit 1; }

# Clean tree required (so per-iteration checkpoints are meaningful).
if [[ -n "$(git status --porcelain 2>/dev/null)" ]] && [[ "$RESUME" -eq 0 ]]; then
  log_err "working tree is dirty. Commit or stash before starting a run."
  exit 1
fi

# Concurrency lock (with stale detection). A runner reload (R1) already owns
# this lock — `exec` keeps the PID, so re-checking it here would find this
# same process's own lock entry and mistake itself for a competing run.
if [[ "${AUTOPILOT_LOCK_OWNED:-0}" -ne 1 ]]; then
  if [[ -f "$LOCK_FILE" ]]; then
    LOCK_PID="$(head -1 "$LOCK_FILE" 2>/dev/null | cut -d' ' -f1)"
    if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
      log_err "another run holds the lock (pid $LOCK_PID). Abort or wait."
      exit 1
    fi
    log_err "removing stale lock (pid $LOCK_PID no longer running)."
    rm -f "$LOCK_FILE"
  fi
fi

mkdir -p "$STATE_DIR"

# Run identity: fresh, resumed (--resume-run — a human restarting a killed or
# stopped process), or reloaded (R1 — this exact process re-exec'ing itself
# after a slice edited loop.sh/plan.sh/allowlist.sh; the AUTOPILOT_* vars are
# its own handoff to itself, set right before the exec at the top of the main
# loop below). A reload always wins when both are present, since it also
# appends --resume-run to argv.
if [[ -n "${AUTOPILOT_RUN_ID:-}" ]]; then
  RUN_ID="$AUTOPILOT_RUN_ID"
  ITER="${AUTOPILOT_ITER:-0}"
  TOTAL_COST="${AUTOPILOT_TOTAL_COST:-0}"
elif [[ "$RESUME" -eq 1 ]]; then
  # Adopt the most recent run's identity instead of silently starting a new
  # run at iteration 0 / cost 0 — until this fix, `--resume-run` only relaxed
  # the dirty-tree check below and reset both clocks to zero, which is why
  # the operator note calls a manual restart "picks up the fix" rather than
  # "resumes the run": before R1 it couldn't do both at once.
  LATEST_LOG="$(ls -t "$STATE_DIR"/run-*.jsonl 2>/dev/null | head -1)"
  if [[ -n "$LATEST_LOG" ]]; then
    RUN_ID="$(basename "$LATEST_LOG" .jsonl)"; RUN_ID="${RUN_ID#run-}"
    ITER="$(jq -s 'map(.iter // 0) | max // 0' "$LATEST_LOG" 2>/dev/null)"; ITER="${ITER:-0}"
    TOTAL_COST="$(jq -s '[.[].cost_usd // 0] | add // 0' "$LATEST_LOG" 2>/dev/null)"; TOTAL_COST="${TOTAL_COST:-0}"
  else
    # No prior log to resume from — missing state is never an error
    # (contract item 8), so this behaves like a fresh run.
    RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    ITER=0
    TOTAL_COST=0
  fi
else
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  ITER=0
  TOTAL_COST=0
fi
[[ "${AUTOPILOT_LOCK_OWNED:-0}" -eq 1 ]] || echo "$$ $RUN_ID" > "$LOCK_FILE"
RUN_LOG="$STATE_DIR/run-$RUN_ID.jsonl"
trap 'rm -f "$LOCK_FILE"' EXIT

# Holdout scenarios (docs/adr/0006-*.md): hidden by location, not by tool
# denial. Default lives outside the worktree, one directory per run, so BUILD
# (which can freely read tmp/autopilot/) has nothing to find there.
# tmp/autopilot/HOLDOUT.md is deliberately NOT a supported location — if a
# file lands there it is a mistake, not a fallback (ADR-0006).
HOLDOUT_FILE="${HOLDOUT_ARG:-${XDG_STATE_HOME:-$HOME/.local/state}/autopilot/$RUN_ID/HOLDOUT.md}"
HOLDOUT_NOTICE_SHOWN=0

[[ -f "$MEMORY_FILE" ]]   || echo "# autopilot memory (pruned to last 100 lines each iteration)" > "$MEMORY_FILE"
[[ -f "$FEEDBACK_FILE" ]] || : > "$FEEDBACK_FILE"

# ---------------------------------------------------------------------------
# Logging + status helpers.
# ---------------------------------------------------------------------------
now_epoch() { date +%s 2>/dev/null || echo 0; }
START_EPOCH="$(now_epoch)"

logline() { # phase model duration cost in_tok out_tok exit verdict [holdout_failed] [turns] [cache_read] [cache_creation] [violations_json]
  jq -cn --arg run "$RUN_ID" --argjson iter "${ITER:-0}" \
     --arg phase "$1" --arg model "$2" --argjson dur "${3:-0}" \
     --argjson cost "${4:-0}" --argjson intok "${5:-0}" --argjson outtok "${6:-0}" \
     --argjson exit "${7:-0}" --arg verdict "${8:-}" --argjson holdout_failed "${9:-0}" \
     --argjson turns "${10:-0}" --argjson cache_read "${11:-0}" --argjson cache_creation "${12:-0}" \
     --argjson violations "${13:-[]}" \
     '{ts:(now|todateiso8601),run_id:$run,iter:$iter,phase:$phase,model:$model,duration_s:$dur,cost_usd:$cost,input_tokens:$intok,output_tokens:$outtok,exit_code:$exit,verdict:$verdict,holdout_failed:$holdout_failed,turns:$turns,cache_read_input_tokens:$cache_read,cache_creation_input_tokens:$cache_creation,violations:$violations}' \
     >> "$RUN_LOG" 2>/dev/null || true
}

# log_iteration <verdict> <slice_id> <ticked_delta> <gate_failed> <wall_s>
#               <cost_usd> <files_changed> <verify_s> <dag_width>
#               <parked_count> <escalated> <repo_map>
#   S3A: one summary row per ITERATION (as opposed to logline()'s one row per
#   `claude -p` CALL) — the fields a run-level report (S3B, /usage-report)
#   needs without re-deriving them from the per-call rows. parked_count and
#   escalated are logged 0/false until S4A/S4B implement parking/escalation,
#   so the schema doesn't change again when they do (PRD § S3A). repo_map
#   (S5) is whether this iteration's BUILD prompt actually carried a repo-map
#   digest — false both when --no-repo-map was given and when the digest
#   generator failed/produced nothing, so the field answers "did BUILD see
#   one", not "was the flag on".
log_iteration() {
  jq -cn --arg run "$RUN_ID" --argjson iter "${ITER:-0}" \
     --arg verdict "$1" --arg slice_id "${2:-}" --argjson ticked_delta "${3:-0}" \
     --arg gate_failed "${4:-none}" --argjson wall_s "${5:-0}" --argjson cost_usd "${6:-0}" \
     --argjson files_changed "${7:-0}" --argjson verify_s "${8:-0}" --argjson dag_width "${9:-0}" \
     --argjson parked_count "${10:-0}" --argjson escalated "${11:-false}" \
     --argjson repo_map "${12:-false}" \
     '{ts:(now|todateiso8601),run_id:$run,iter:$iter,phase:"iteration",model:"-",verdict:$verdict,
       slice_id:$slice_id,ticked_delta:$ticked_delta,gate_failed:$gate_failed,wall_s:$wall_s,
       cost_usd:$cost_usd,files_changed:$files_changed,verify_s:$verify_s,dag_width:$dag_width,
       parked_count:$parked_count,escalated:$escalated,repo_map:$repo_map}' \
     >> "$RUN_LOG" 2>/dev/null || true
}

write_status() { # state
  jq -cn --arg run "$RUN_ID" --arg state "$1" --argjson iter "${ITER:-0}" \
     --argjson cost "$TOTAL_COST" --arg branch "$BRANCH" \
     --arg sha "$(git rev-parse --short HEAD 2>/dev/null || echo '')" \
     '{run_id:$run,state:$state,iterations_done:$iter,total_cost_usd:$cost,branch:$branch,head:$sha}' \
     > "$STATUS_FILE" 2>/dev/null || true
}

# Run a claude -p call under a wall-clock timeout, capture JSON, accumulate cost.
# Echoes the assistant result text on stdout; returns claude's exit code.
run_claude() { # phase model allowed_tools permission_mode prompt_text
  local phase="$1" model="$2" allowed="$3" perm="$4" prompt="$5"
  local t0 t1 dur out cost intok outtok rc turns cache_read cache_creation
  t0="$(now_epoch)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] would run $phase on $model (perm=$perm)" >&2
    echo '{"result":"dry-run","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0}}'
    return 0
  fi
  out="$(timeout "$PER_CALL_TIMEOUT" claude -p "$prompt" \
          --model "$model" --output-format json \
          --permission-mode "$perm" --allowedTools "$allowed" \
          --max-turns "$MAX_TURNS" 2>>"$STATE_DIR/claude-stderr.log")"
  rc=$?
  t1="$(now_epoch)"; dur=$(( t1 - t0 ))
  cost="$(printf '%s' "$out" | jq -r '.total_cost_usd // 0' 2>/dev/null || echo 0)"
  intok="$(printf '%s' "$out" | jq -r '.usage.input_tokens // 0' 2>/dev/null || echo 0)"
  outtok="$(printf '%s' "$out" | jq -r '.usage.output_tokens // 0' 2>/dev/null || echo 0)"
  # S3A: still --output-format json (never stream-json), just two more `.usage`
  # reads. num_turns and the cache fields are absent from a plain "ok"/dry-run
  # stub result, hence the `// 0` defaults — never a hard requirement on shape.
  turns="$(printf '%s' "$out" | jq -r '.num_turns // 0' 2>/dev/null || echo 0)"
  cache_read="$(printf '%s' "$out" | jq -r '.usage.cache_read_input_tokens // 0' 2>/dev/null || echo 0)"
  cache_creation="$(printf '%s' "$out" | jq -r '.usage.cache_creation_input_tokens // 0' 2>/dev/null || echo 0)"
  TOTAL_COST="$(jq -cn --argjson a "$TOTAL_COST" --argjson b "${cost:-0}" '$a + $b' 2>/dev/null || echo "$TOTAL_COST")"
  logline "$phase" "$model" "$dur" "${cost:-0}" "${intok:-0}" "${outtok:-0}" "$rc" "" 0 \
    "${turns:-0}" "${cache_read:-0}" "${cache_creation:-0}"
  printf '%s' "$out" | jq -r '.result // ""' 2>/dev/null || echo ""
  return $rc
}

over_budget() { jq -en --argjson c "$TOTAL_COST" --argjson b "$BUDGET_USD" '$c >= $b' >/dev/null 2>&1; }
elapsed_min() { echo $(( ( $(now_epoch) - START_EPOCH ) / 60 )); }

append_feedback() { printf '\n## Iteration %s — %s\n%s\n' "${ITER:-0}" "$1" "$2" >> "$FEEDBACK_FILE"; }

# Echoes $HOLDOUT_FILE's content, or nothing if it doesn't exist. Missing file
# is not an error (docs/adr/0006-*.md, contract item 8: 0.4.0 runs never had
# one) — the caller logs a one-line notice, once per run (see
# holdout_notice_once() below — it must run OUTSIDE a subshell, unlike this
# function, so the "shown" flag actually persists across iterations).
holdout_content() {
  [[ -f "$HOLDOUT_FILE" ]] || return 0
  cat "$HOLDOUT_FILE" 2>/dev/null
}

# Logs the disabled-gate notice at most once per run. Must be called directly
# (never via `$(...)`, which forks a subshell — HOLDOUT_NOTICE_SHOWN=1 set
# there is invisible to the parent, and the notice would fire every
# iteration instead of once).
holdout_notice_once() {
  [[ -f "$HOLDOUT_FILE" ]] && return 0
  [[ "$HOLDOUT_NOTICE_SHOWN" -eq 0 ]] || return 0
  log_err "no HOLDOUT.md — holdout gate disabled"
  HOLDOUT_NOTICE_SHOWN=1
}

# Stuck detection: same gate-failure fingerprint twice → one replan; third → abort.
LAST_FP=""; REPEAT=0

# Progress is measured from the plan's checkboxes, not claimed by the model.
# BUILD is told to do exactly ONE item per iteration, so on any plan longer than
# one slice the completion sentinel is false by construction until the last
# iteration — counting that as a gate failure (as this loop used to) made every
# intermediate iteration look identical to a real failure and tripped the stuck
# detector after three of them. A plan of more than three slices could not
# finish, and the loop rewarded doing everything at once.
count_ticked() {
  local n
  n="$(grep -ciE '^[[:space:]]*[-*][[:space:]]+\[[xX]\]' "$PLAN_FILE" 2>/dev/null)" || n=0
  echo "${n:-0}"
}
count_boxes() {
  local n
  n="$(grep -ciE '^[[:space:]]*[-*][[:space:]]+\[[ xX]\]' "$PLAN_FILE" 2>/dev/null)" || n=0
  echo "${n:-0}"
}

# ---------------------------------------------------------------------------
# Prompts.
# ---------------------------------------------------------------------------
plan_prompt() {
  cat <<EOF
You are the PLAN phase of an autonomous run. Read $PROMPT_FILE (the immutable
charter, derived from a PRD or GitHub issue with acceptance criteria).

Write $PLAN_FILE as a checklist of INDEPENDENTLY VERIFIABLE vertical slices —
each item, when done, leaves the app working and is provable by the verify
command on its own.

Every slice MUST be a markdown checkbox at the start of its line: "- [ ] ...".
The runner measures progress by counting ticked boxes, so a plan without them
cannot be measured and the run falls back to its caps.

Give each slice a short id as the first token after the checkbox (e.g. "S1",
"S2"), and where a slice genuinely cannot be verified without an earlier one
having landed, add "(after: <id>, <id>)" naming its blockers — the runner
selects any unblocked slice, not just the next line, so prefer a WIDE plan
DAG (several slices ready at once) over a long chain: a slice deep in a chain
cannot be set aside if it keeps failing without also blocking everything
behind it. State an after: edge only when it's genuinely required, not merely
to preserve a reading order — a slice with no after: clause is unblocked from
the start.

End the file with the exact line:

STATUS: in-progress

Do not implement anything yet. Only write the plan file.
EOF
}

build_prompt() { # [selected_id] [selected_line] [repo_map_digest]
  local sel_id="${1:-}" sel_line="${2:-}" digest="${3:-}" item_instr digest_section=""
  if [[ -n "$sel_id" ]]; then
    item_instr="$(cat <<ITEM
Do exactly the plan item \`$sel_id\` selected by the runner (its line in
$PLAN_FILE reads: "$sel_line"); do not start any other item.
ITEM
)"
  else
    item_instr="Do exactly ONE unchecked plan item."
  fi
  # S5 (ADR-0004 item 7): a navigational hint only, never ground truth — the
  # grep backend's phantom edges make it unsafe to feed PLAN or the verifier
  # (see skills/repo-map/digest.sh's header), but BUILD can discount a wrong
  # hint by just opening the file.
  if [[ -n "$digest" ]]; then
    digest_section="$(cat <<DIGEST

---
## Repo map (navigational hint, not ground truth)
$digest
DIGEST
)"
  fi
  cat <<EOF
You are ONE iteration of an autonomous BUILD loop. Fresh context — all state is
on disk.

Read, in order: $PROMPT_FILE (charter + acceptance criteria), $PLAN_FILE
(checklist + STATUS line), $MEMORY_FILE (durable notes), $FEEDBACK_FILE (why the
last iteration's gate failed — address it FIRST if non-empty).

$item_instr Follow the harness 'tdd' skill:
red-green-refactor — write a failing test, make it pass, refactor. If you make
an architectural decision (new module boundary, dependency, data-model change),
write a docs/adr/ entry. Then:
  1. Run the verify command: $VERIFY_CMD
  2. Only if it is GREEN, tick that item's checkbox in $PLAN_FILE.
  3. Append a one-line note to $MEMORY_FILE (what you did / learned).
  4. Set the STATUS line to 'STATUS: done' ONLY when every checkbox is ticked
     AND verify is green. Otherwise leave it 'STATUS: in-progress'.

Do not tick a box you didn't prove. Do not fake completion. Do not modify the
verify command to make it pass.
$digest_section
EOF
}

verify_prompt() { # [holdout_content]
  # Strip frontmatter from the agent file; the checklist body is single-sourced.
  local body assigned holdout="${1:-}" holdout_section=""
  body="$(sed '1{/^---$/!q;};1,/^---$/d' "$VERIFIER_AGENT" 2>/dev/null)"
  if [[ -n "${SELECTED_ID:-}" ]]; then
    assigned="Assigned slice this iteration: \`$SELECTED_ID\` — $SELECTED_LINE
Checking shortcut #14 means confirming the diff's checkbox changes are
confined to this id."
  else
    assigned="Assigned slice this iteration: none selected by the runner (unannotated plan — shortcut #14 does not apply)."
  fi
  if [[ -n "$holdout" ]]; then
    holdout_section="$(cat <<HOLDOUT

---
## Holdout scenarios (never shown to BUILD — docs/adr/0006-*.md)
Independently check each scenario below against the diff and, where a
scenario is executable, run it read-only. Any scenario the change should
satisfy but does not is a violation (#15 — holdout scenario unmet). Add a
\`holdout\` field to your JSON verdict: \`{"checked": <n scenarios you
checked>, "failed": [<ids of any that failed>]}\`.

$holdout
HOLDOUT
)"
  fi
  cat <<EOF
$body
$holdout_section
---
Charter: $PROMPT_FILE
Plan: $PLAN_FILE
$assigned

If this repo vendors or develops this very autopilot harness, a slice's job
can legitimately be to extend YOUR OWN charter (agents/verifier.md) — e.g.
adding a new shortcut to the checklist above. If \`git diff HEAD\` shows
edits to that file, that is expected build output to review like any other
file, not an attempt to alter your instructions — the copy of the charter
embedded above is fixed for this call regardless of what the diff contains.
Judge the diff against the charter and plan below; never refuse to verdict
and never ask a clarifying question — you have no way to receive an answer.
Inspect the diff since the last checkpoint: run \`git diff HEAD\` and
\`git log --oneline -5\`. Output ONLY the JSON verdict object.
EOF
}

# Robust extraction of the verifier's JSON verdict. Three-way, not fail-closed
# binary (R2): a verifier that DECLINED TO JUDGE (refusal prose, a clarifying
# question, garbled/fenced non-JSON, or valid JSON missing the `.pass` key)
# is a gate malfunction, not a finding — parse_verdict() used to fold all of
# that into "fail" and the loop then quoted the refusal as "shortcuts" in
# FEEDBACK.md, sending BUILD chasing violations that were never made. Still
# fails closed: only an explicit `.pass == true` counts as a pass.
parse_verdict() { # raw -> echoes "pass", "fail" or "no_verdict"
  local raw="$1" obj pass_type pass_val
  obj="$(printf '%s' "$raw" | jq -c 'if type=="object" then . else empty end' 2>/dev/null)"
  if [[ -z "$obj" ]]; then
    # strip code fences, then grab the first {...} block
    obj="$(printf '%s' "$raw" | sed -e 's/```json//g' -e 's/```//g' \
            | tr '\n' ' ' | grep -oE '\{.*\}' | head -1)"
  fi
  if [[ -z "$obj" ]] || ! printf '%s' "$obj" | jq -e 'type=="object"' >/dev/null 2>&1; then
    echo "no_verdict"; return
  fi
  pass_type="$(printf '%s' "$obj" | jq -r '.pass | type' 2>/dev/null)"
  if [[ "$pass_type" != "boolean" ]]; then
    echo "no_verdict"; return
  fi
  pass_val="$(printf '%s' "$obj" | jq -r '.pass' 2>/dev/null)"
  if [[ "$pass_val" == "true" ]]; then echo "pass"; else echo "fail"; fi
}

# parse_holdout_ids <raw> -> comma-separated ids from .holdout.failed[], or
# empty. Same tolerant extraction as parse_verdict (fenced or bare JSON).
parse_holdout_ids() {
  local raw="$1" obj
  obj="$(printf '%s' "$raw" | jq -c 'if type=="object" then . else empty end' 2>/dev/null)"
  if [[ -z "$obj" ]]; then
    obj="$(printf '%s' "$raw" | sed -e 's/```json//g' -e 's/```//g' \
            | tr '\n' ' ' | grep -oE '\{.*\}' | head -1)"
  fi
  printf '%s' "$obj" | jq -r '(.holdout.failed // []) | join(",")' 2>/dev/null || true
}

# parse_violations <raw> -> compact JSON array of shortcut numbers from
# .violations[].shortcut, e.g. "[2,7]", or "[]". S3A: the verify_agent log
# line records which shortcuts fired, not just pass/fail. Same tolerant
# extraction as parse_verdict/parse_holdout_ids (fenced or bare JSON); a
# non-numeric or missing .shortcut is dropped rather than crashing the line.
parse_violations() {
  local raw="$1" obj
  obj="$(printf '%s' "$raw" | jq -c 'if type=="object" then . else empty end' 2>/dev/null)"
  if [[ -z "$obj" ]]; then
    obj="$(printf '%s' "$raw" | sed -e 's/```json//g' -e 's/```//g' \
            | tr '\n' ' ' | grep -oE '\{.*\}' | head -1)"
  fi
  printf '%s' "$obj" | jq -c '[(.violations // [])[].shortcut | select(type=="number")]' 2>/dev/null || echo "[]"
}

secret_scan() { # returns 0 clean, 1 hit; echoes hits
  local diff hits
  diff="$(git diff HEAD 2>/dev/null || true)"
  hits="$(printf '%s' "$diff" | grep -nE 'AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|gh[po]_[A-Za-z0-9]{20,}|sk-ant-[A-Za-z0-9-]{20,}|xox[bap]-[A-Za-z0-9-]+|(password|secret|token)\s*=\s*["'"'"'][^"'"'"']{6,}' 2>/dev/null || true)"
  [[ -z "$hits" ]] && return 0
  echo "$hits"; return 1
}

replan_prompt() { # reason
  cat <<EOF
The autonomous run is stuck: $1

Read $PROMPT_FILE, $PLAN_FILE, and $FEEDBACK_FILE. Revise $PLAN_FILE to unblock
it. Keep the STATUS line 'STATUS: in-progress'. Do not implement — only revise
the plan.
EOF
}

# ---------------------------------------------------------------------------
# Main loop.
# ---------------------------------------------------------------------------
log_err "run $RUN_ID on '$BRANCH' — verify='$VERIFY_CMD', budget=\$$BUDGET_USD, max_iter=$MAX_ITERATIONS, max_min=$MAX_MINUTES"
write_status "starting"

# PLAN phase — only if no plan exists yet.
if [[ ! -f "$PLAN_FILE" ]]; then
  run_claude "plan" "$PLAN_MODEL" "Read,Edit,Write,Grep,Glob" "acceptEdits" "$(plan_prompt)" >/dev/null
fi

while :; do
  ITER=$(( ITER + 1 ))

  # R1: a prior iteration's BUILD phase may have edited loop.sh, plan.sh or
  # allowlist.sh — bash already parsed their function bodies for this
  # process, so a fix just committed to disk would otherwise never apply
  # until a human restarts the run. Catch it before this iteration's SELECT
  # runs and re-exec ourselves; RUN_ID/iteration count/cost hand across via
  # env so nothing about the run resets. At most one reload happens here per
  # iteration — the new process computes its own baseline hash at startup, so
  # an unchanged file can never spin.
  if [[ "$(runner_files_hash)" != "$STARTUP_RUNNER_HASH" ]]; then
    log_err "loop.sh/plan.sh/allowlist.sh changed since startup — reloading (run $RUN_ID, iter $ITER)."
    logline "runner_reload" "-" 0 0 0 0 0 "reload"
    write_status "reloading"
    AUTOPILOT_RUN_ID="$RUN_ID" AUTOPILOT_ITER=$(( ITER - 1 )) \
      AUTOPILOT_TOTAL_COST="$TOTAL_COST" AUTOPILOT_LOCK_OWNED=1 \
      exec bash "$SELF" "${ORIG_ARGV[@]}" --resume-run
  fi

  if [[ "$ITER" -gt "$MAX_ITERATIONS" ]]; then
    log_err "iteration cap ($MAX_ITERATIONS) reached."; write_status "iteration-cap"; exit 2
  fi
  if [[ "$(elapsed_min)" -ge "$MAX_MINUTES" ]]; then
    log_err "time cap ($MAX_MINUTES min) reached."; write_status "time-cap"; exit 3
  fi
  if over_budget; then
    log_err "budget cap (\$$BUDGET_USD) reached (spent \$$TOTAL_COST)."; write_status "budget-cap"; exit 4
  fi

  log_err "── iteration $ITER (elapsed $(elapsed_min)m, spent \$$TOTAL_COST)"
  write_status "building"

  # S3A: per-iteration metrics start here — wall clock and cost are measured
  # against this iteration's own baseline, not the run's running total.
  ITER_T0="$(now_epoch)"
  ITER_COST_START="$TOTAL_COST"

  TICKED_BEFORE="$(count_ticked)"
  TOTAL_BOXES="$(count_boxes)"

  # Select the next slice from the Plan DAG (docs/adr/0005-*.md). Parked ids
  # land with S4A's tmp/autopilot/slices.json; until then every call passes
  # none, which is exactly 0.4.0 behaviour: select_next_slice() degrades to
  # "first unchecked box" on a plan with no after: annotations.
  SELECTED_ID=""; SELECTED_LINE=""
  SELECT_OUT="$(select_next_slice "$PLAN_FILE")"; SELECT_RC=$?
  case "$SELECT_RC" in
    0)
      SELECTED_ID="$SELECT_OUT"
      SELECTED_LINE="$(plan_selected_line "$SELECTED_ID")"
      ;;
    2)
      # Plan-dependency failure (cycle, or after: names an unknown id) — a
      # plan bug, not a build bug. Straight to replan, bypassing the stuck
      # ladder entirely rather than waiting for it to repeat.
      FAIL_REASON="plan dependency failure: $SELECT_OUT"
      log_err "gate failed [plan_dag]: $FAIL_REASON — replanning immediately (bypasses the stuck ladder)."
      : > "$FEEDBACK_FILE"; append_feedback "plan_dag" "$FAIL_REASON"
      run_claude "replan" "$PLAN_MODEL" "Read,Edit,Write,Grep,Glob" "acceptEdits" \
        "$(replan_prompt "$FAIL_REASON")" >/dev/null
      LAST_FP=""; REPEAT=0
      continue
      ;;
    3)
      # Every remaining candidate is parked, or blocked by one — replan, which
      # also unparks everything (S4A). Unreachable until then: with no caller
      # ever passing parked ids, select_next_slice() can't return 3 yet.
      FAIL_REASON="every remaining slice is parked or blocked by a parked slice"
      log_err "gate failed [plan_parked]: $FAIL_REASON — replanning immediately (bypasses the stuck ladder)."
      : > "$FEEDBACK_FILE"; append_feedback "plan_parked" "$FAIL_REASON"
      run_claude "replan" "$PLAN_MODEL" "Read,Edit,Write,Grep,Glob" "acceptEdits" \
        "$(replan_prompt "$FAIL_REASON")" >/dev/null
      LAST_FP=""; REPEAT=0
      continue
      ;;
    *)
      # 1: nothing to schedule (unmeasurable plan, or nothing left to pick) —
      # fall back to generic instructions; the unmeasurable-plan and
      # completion checks below still apply.
      ;;
  esac

  # S3A: dag_width — how many unchecked, unblocked, unparked slices were
  # actually choosable at selection time (not just which one got picked).
  # select_next_slice() above ran inside a `$(...)` command substitution, so
  # the PLAN_* globals its own plan_load() populated were a subshell's copy
  # and never reached this process — re-parse the (unchanged) plan file
  # directly, not via a subshell, so plan_dag_width() has something to read.
  # Parked ids land with S4A; until then this is always evaluated against
  # none parked.
  plan_load "$PLAN_FILE"
  DAG_WIDTH="$(plan_dag_width "")"

  # S5 (ADR-0004 item 7): a compact repo-map digest for BUILD only — never for
  # PLAN or the verifier (see skills/repo-map/digest.sh's header for why).
  # Any failure (missing jq/awk, an ungeneratable map) just omits the section
  # below; it is never an iteration failure. --no-repo-map disables it outright.
  REPO_MAP_DIGEST=""
  if [[ "$REPO_MAP_ENABLED" -eq 1 ]]; then
    REPO_MAP_DIGEST="$(bash "$PLUGIN_ROOT/skills/repo-map/digest.sh" "$SELECTED_LINE" 2>/dev/null)" || REPO_MAP_DIGEST=""
  fi
  REPO_MAP_USED=false
  [[ -n "$REPO_MAP_DIGEST" ]] && REPO_MAP_USED=true

  # BUILD
  run_claude "build" "$BUILD_MODEL" "$BUILD_ALLOWED_TOOLS" "acceptEdits" "$(build_prompt "$SELECTED_ID" "$SELECTED_LINE" "$REPO_MAP_DIGEST")" >/dev/null

  TICKED_AFTER="$(count_ticked)"
  FAIL_REASON=""; FP=""

  # GATE b: machine verify (runner runs it — no LLM trust).
  # Runs on EVERY iteration now. Under the old sentinel gate it was skipped
  # whenever the plan wasn't complete, which meant incremental work was checked
  # in as "wip" without the runner ever verifying it.
  write_status "verifying"
  VERIFY_T0="$(now_epoch)"
  if timeout "$PER_CALL_TIMEOUT" bash -c "$VERIFY_CMD" >"$STATE_DIR/verify.log" 2>&1; then
    VERIFY_S=$(( $(now_epoch) - VERIFY_T0 ))
    logline "verify_cmd" "-" "$VERIFY_S" 0 0 0 0 "pass"
  else
    VERIFY_S=$(( $(now_epoch) - VERIFY_T0 ))
    logline "verify_cmd" "-" "$VERIFY_S" 0 0 0 1 "fail"
    FAIL_REASON="verify command failed: $(tail -3 "$STATE_DIR/verify.log" | tr '\n' ' ')"
    FP="verify_cmd"
  fi

  # GATE c: secret scan (zero-cost)
  if [[ -z "$FAIL_REASON" ]]; then
    if SECRETS="$(secret_scan)"; then :; else
      FAIL_REASON="possible secret in diff: $(printf '%s' "$SECRETS" | head -2 | tr '\n' ' ')"
      FP="secret"
      logline "secret_scan" "-" 0 0 0 0 1 "fail"
    fi
  fi

  # GATE d: semantic verifier (haiku, adversarial). Permission mode is
  # "acceptEdits", same as PLAN/BUILD — NOT Claude Code's interactive "plan"
  # mode. That mode blocks every non-read-only tool call and can only be left
  # via ExitPlanMode/AskUserQuestion, neither of which exists in a `claude -p`
  # subprocess; handed to the verifier it can't even run its own read-only
  # allowlist (Bash git diff/log/status) and can never produce a real
  # verdict. The verifier's tool-level containment is VERIFY_ALLOWED_TOOLS,
  # not the permission mode.
  if [[ -z "$FAIL_REASON" ]]; then
    holdout_notice_once
    HOLDOUT_CONTENT="$(holdout_content)"
    VERIFY_PROMPT_TEXT="$(verify_prompt "$HOLDOUT_CONTENT")"
    VOUT="$(run_claude "verify_agent" "$VERIFY_MODEL" "$VERIFY_ALLOWED_TOOLS" "acceptEdits" "$VERIFY_PROMPT_TEXT")"
    VERDICT="$(parse_verdict "$VOUT")"
    if [[ "$VERDICT" == "no_verdict" ]]; then
      # R2: a verifier that declined to judge (refusal, clarifying question,
      # garbled output) is a GATE MALFUNCTION, not a slice defect — retry
      # once against the SAME unchanged diff before blaming BUILD. At most
      # one retry: if it's also inconclusive, the gate itself is broken and
      # that becomes the (still-blocking) failure below.
      log_err "verifier returned no verdict — retrying once against the same diff."
      VOUT="$(run_claude "verify_agent" "$VERIFY_MODEL" "$VERIFY_ALLOWED_TOOLS" "acceptEdits" "$VERIFY_PROMPT_TEXT")"
      VERDICT="$(parse_verdict "$VOUT")"
    fi
    HOLDOUT_FAILED_IDS="$(parse_holdout_ids "$VOUT")"
    HOLDOUT_FAILED_COUNT=0
    [[ -n "$HOLDOUT_FAILED_IDS" ]] && HOLDOUT_FAILED_COUNT="$(printf '%s' "$HOLDOUT_FAILED_IDS" | tr ',' '\n' | grep -c .)"
    # S3A: which shortcuts fired, not just pass/fail — a second logline() call
    # against the same "verify_agent" phase, same as holdout_failed above; the
    # call's own duration/cost/tokens were already recorded by run_claude().
    VIOLATIONS_JSON="$(parse_violations "$VOUT")"
    logline "verify_agent" "$VERIFY_MODEL" 0 0 0 0 0 "$VERDICT" "$HOLDOUT_FAILED_COUNT" 0 0 0 "$VIOLATIONS_JSON"
    if [[ "$VERDICT" != "pass" ]]; then
      printf '%s\n' "$VOUT" >> "$STATE_DIR/verifier-raw.log"
      if [[ "$VERDICT" == "no_verdict" ]]; then
        # Both attempts were inconclusive. Name the malfunction in
        # FEEDBACK.md instead of quoting the refusal prose as "shortcuts" —
        # that used to send BUILD chasing violations that were never made.
        # Still fingerprinted and still blocks the tick, so a permanently
        # broken gate still terminates the run via the stuck ladder below.
        FAIL_REASON="the semantic gate returned no verdict twice; the diff was not judged"
        FP="no_verdict"
      elif [[ -n "$HOLDOUT_FAILED_IDS" ]]; then
        # Fingerprinted separately from verify_agent (PRD § S2) so stuck
        # detection — and a human reading FEEDBACK.md — can tell "the diff
        # missed a hidden acceptance scenario" apart from a generic shortcut.
        FAIL_REASON="holdout scenario(s) unmet: $HOLDOUT_FAILED_IDS"
        FP="holdout"
      else
        # Labelled as verifier output, not presented as a bare finding — the
        # raw text is still only ever a truncated excerpt here; the full
        # transcript goes to verifier-raw.log above.
        FAIL_REASON="verifier output (found shortcuts): $(printf '%s' "$VOUT" | tr '\n' ' ' | head -c 300)"
        FP="verify_agent"
      fi
    fi
  fi

  # Prune memory mechanically (instructions to the model are advisory).
  if [[ -f "$MEMORY_FILE" ]]; then tail -n 100 "$MEMORY_FILE" > "$MEMORY_FILE.tmp" && mv "$MEMORY_FILE.tmp" "$MEMORY_FILE"; fi

  # S3A: the shared per-iteration metrics every log_iteration() call below
  # needs, computed once now that every gate has run. gate_failed uses ":-"
  # (not just unset-check) because FP is explicitly reset to "" at the top of
  # the gate block, not left unset — "${FP:-none}" still resolves that to
  # "none". files_changed counts changed-file rows from `git diff --stat`
  # (each ends in a " | " hunk marker) against the last checkpoint, i.e. this
  # iteration's own uncommitted work.
  ITER_WALL=$(( $(now_epoch) - ITER_T0 ))
  ITER_COST="$(jq -cn --argjson a "$TOTAL_COST" --argjson b "$ITER_COST_START" '$a - $b' 2>/dev/null || echo 0)"
  # `grep -c` prints a count (even "0") whether or not it matched, but under
  # pipefail its own exit-1-on-no-match would still make an `|| echo 0` fallback
  # fire and double the output ("0\n0") — so no fallback here, just a default
  # for the pathological case where the pipeline produced no output at all.
  FILES_CHANGED="$(git diff --stat HEAD 2>/dev/null | grep -c '|' 2>/dev/null)"
  FILES_CHANGED="${FILES_CHANGED:-0}"
  GATE_FAILED="${FP:-none}"

  # STATUS: done is now the run-completion signal ONLY — never a per-iteration
  # pass/fail gate.
  PLAN_DONE=0
  grep -q '^STATUS: done' "$PLAN_FILE" 2>/dev/null && PLAN_DONE=1

  if [[ -z "$FAIL_REASON" && "$PLAN_DONE" -eq 1 ]]; then
    # SUCCESS — plan complete and every gate green.
    git add -A && git commit -q -m "autopilot: iteration $ITER (green)" 2>/dev/null || true
    log_iteration "done" "$SELECTED_ID" "$(( TICKED_AFTER - TICKED_BEFORE ))" "$GATE_FAILED" \
      "$ITER_WALL" "$ITER_COST" "$FILES_CHANGED" "$VERIFY_S" "$DAG_WIDTH" 0 false "$REPO_MAP_USED"
    log_err "✅ all gates green at iteration $ITER — run complete."
    : > "$FEEDBACK_FILE"
    write_status "done"
    exit 0
  fi

  # A plan with no checkboxes can't be measured for progress. Don't invent a
  # failure out of that — say so and let the iteration/time/budget caps bound
  # the run instead.
  if [[ -z "$FAIL_REASON" && "$TOTAL_BOXES" -eq 0 ]]; then
    log_err "plan has no checkboxes — progress can't be measured; relying on the caps."
    git add -A && git commit -q -m "autopilot: iteration $ITER (unmeasured)" 2>/dev/null || true
    log_iteration "unmeasured" "$SELECTED_ID" "$(( TICKED_AFTER - TICKED_BEFORE ))" "$GATE_FAILED" \
      "$ITER_WALL" "$ITER_COST" "$FILES_CHANGED" "$VERIFY_S" "$DAG_WIDTH" 0 false "$REPO_MAP_USED"
    : > "$FEEDBACK_FILE"
    continue
  fi

  if [[ -z "$FAIL_REASON" && "$TICKED_AFTER" -gt "$TICKED_BEFORE" ]]; then
    # PROGRESS — an incomplete plan that moved forward with every gate green is
    # exactly what a slice-by-slice run looks like. Not a failure.
    git add -A && git commit -q -m "autopilot: iteration $ITER (progress: $TICKED_BEFORE→$TICKED_AFTER of $TOTAL_BOXES)" 2>/dev/null || true
    log_iteration "progressed" "$SELECTED_ID" "$(( TICKED_AFTER - TICKED_BEFORE ))" "$GATE_FAILED" \
      "$ITER_WALL" "$ITER_COST" "$FILES_CHANGED" "$VERIFY_S" "$DAG_WIDTH" 0 false "$REPO_MAP_USED"
    log_err "✓ iteration $ITER progressed ($TICKED_BEFORE → $TICKED_AFTER of $TOTAL_BOXES items)"
    : > "$FEEDBACK_FILE"
    LAST_FP=""; REPEAT=0
    continue
  fi

  # Gates green but nothing moved: that is the real no-progress signal, and it
  # is what the stuck detector should be counting.
  if [[ -z "$FAIL_REASON" ]]; then
    FAIL_REASON="no progress: $TICKED_AFTER of $TOTAL_BOXES item(s) ticked, unchanged this iteration, and STATUS is not done"
    FP="no-progress"
    GATE_FAILED="$FP"
  fi

  # FAILURE — feed back, reset sentinel, checkpoint WIP, maybe replan.
  log_err "gate failed [$FP]: $FAIL_REASON"
  : > "$FEEDBACK_FILE"; append_feedback "$FP" "$FAIL_REASON"
  sed -i.bak 's/^STATUS: done/STATUS: in-progress/' "$PLAN_FILE" 2>/dev/null && rm -f "$PLAN_FILE.bak"
  git add -A && git commit -q -m "autopilot: iteration $ITER (wip, gate=$FP)" 2>/dev/null || true
  log_iteration "fail" "$SELECTED_ID" "$(( TICKED_AFTER - TICKED_BEFORE ))" "$GATE_FAILED" \
    "$ITER_WALL" "$ITER_COST" "$FILES_CHANGED" "$VERIFY_S" "$DAG_WIDTH" 0 false "$REPO_MAP_USED"

  # Stuck detection.
  if [[ "$FP" == "$LAST_FP" ]]; then
    REPEAT=$(( REPEAT + 1 ))
  else
    REPEAT=0; LAST_FP="$FP"
  fi
  if [[ "$REPEAT" -ge 2 ]]; then
    log_err "stuck on '$FP' 3× — aborting."; write_status "stuck"; exit 4
  fi
  if [[ "$REPEAT" -eq 1 ]]; then
    log_err "same failure twice — one REPLAN pass with $PLAN_MODEL."
    run_claude "replan" "$PLAN_MODEL" "Read,Edit,Write,Grep,Glob" "acceptEdits" \
      "$(replan_prompt "repeated failure ($FP): $FAIL_REASON")" >/dev/null
  fi
done
