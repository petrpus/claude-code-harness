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
#           [--extra-allowed-tools '<csv>'] [--resume-run] [--dry-run]
#
# Exit codes: 0 done+verified · 2 iteration cap · 3 time cap · 4 budget/stuck
#             cap · 1 runner error (bad preconditions, missing deps).

set -uo pipefail

# ---------------------------------------------------------------------------
# Resolve plugin root from THIS script's location. Do NOT rely on
# $CLAUDE_PLUGIN_ROOT — that is only set for hook processes, and loop.sh runs
# as a plain Bash command.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFIER_AGENT="$PLUGIN_ROOT/agents/verifier.md"

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
    --resume-run)       RESUME=1; shift ;;
    --dry-run)          DRY_RUN=1; shift ;;
    -h|--help)          sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
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

# Concurrency lock (with stale detection).
if [[ -f "$LOCK_FILE" ]]; then
  LOCK_PID="$(head -1 "$LOCK_FILE" 2>/dev/null | cut -d' ' -f1)"
  if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
    log_err "another run holds the lock (pid $LOCK_PID). Abort or wait."
    exit 1
  fi
  log_err "removing stale lock (pid $LOCK_PID no longer running)."
  rm -f "$LOCK_FILE"
fi

mkdir -p "$STATE_DIR"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
echo "$$ $RUN_ID" > "$LOCK_FILE"
RUN_LOG="$STATE_DIR/run-$RUN_ID.jsonl"
trap 'rm -f "$LOCK_FILE"' EXIT

[[ -f "$MEMORY_FILE" ]]   || echo "# autopilot memory (pruned to last 100 lines each iteration)" > "$MEMORY_FILE"
[[ -f "$FEEDBACK_FILE" ]] || : > "$FEEDBACK_FILE"

# ---------------------------------------------------------------------------
# Logging + status helpers.
# ---------------------------------------------------------------------------
now_epoch() { date +%s 2>/dev/null || echo 0; }
START_EPOCH="$(now_epoch)"
TOTAL_COST=0

logline() { # phase model duration cost in_tok out_tok exit verdict
  jq -cn --arg run "$RUN_ID" --argjson iter "${ITER:-0}" \
     --arg phase "$1" --arg model "$2" --argjson dur "${3:-0}" \
     --argjson cost "${4:-0}" --argjson intok "${5:-0}" --argjson outtok "${6:-0}" \
     --argjson exit "${7:-0}" --arg verdict "${8:-}" \
     '{ts:(now|todateiso8601),run_id:$run,iter:$iter,phase:$phase,model:$model,duration_s:$dur,cost_usd:$cost,input_tokens:$intok,output_tokens:$outtok,exit_code:$exit,verdict:$verdict}' \
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
  local t0 t1 dur out cost intok outtok rc
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
  TOTAL_COST="$(jq -cn --argjson a "$TOTAL_COST" --argjson b "${cost:-0}" '$a + $b' 2>/dev/null || echo "$TOTAL_COST")"
  logline "$phase" "$model" "$dur" "${cost:-0}" "${intok:-0}" "${outtok:-0}" "$rc" ""
  printf '%s' "$out" | jq -r '.result // ""' 2>/dev/null || echo ""
  return $rc
}

over_budget() { jq -en --argjson c "$TOTAL_COST" --argjson b "$BUDGET_USD" '$c >= $b' >/dev/null 2>&1; }
elapsed_min() { echo $(( ( $(now_epoch) - START_EPOCH ) / 60 )); }

append_feedback() { printf '\n## Iteration %s — %s\n%s\n' "${ITER:-0}" "$1" "$2" >> "$FEEDBACK_FILE"; }

# Stuck detection: same gate-failure fingerprint twice → one replan; third → abort.
LAST_FP=""; REPEAT=0

# ---------------------------------------------------------------------------
# Prompts.
# ---------------------------------------------------------------------------
plan_prompt() {
  cat <<EOF
You are the PLAN phase of an autonomous run. Read $PROMPT_FILE (the immutable
charter, derived from a PRD or GitHub issue with acceptance criteria).

Write $PLAN_FILE as a checklist of INDEPENDENTLY VERIFIABLE vertical slices —
each item, when done, leaves the app working and is provable by the verify
command. Order them so each builds on the last. End the file with the exact
line:

STATUS: in-progress

Do not implement anything yet. Only write the plan file.
EOF
}

build_prompt() {
  cat <<EOF
You are ONE iteration of an autonomous BUILD loop. Fresh context — all state is
on disk.

Read, in order: $PROMPT_FILE (charter + acceptance criteria), $PLAN_FILE
(checklist + STATUS line), $MEMORY_FILE (durable notes), $FEEDBACK_FILE (why the
last iteration's gate failed — address it FIRST if non-empty).

Do exactly ONE unchecked plan item. Follow the harness 'tdd' skill:
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
EOF
}

verify_prompt() {
  # Strip frontmatter from the agent file; the checklist body is single-sourced.
  local body
  body="$(sed '1{/^---$/!q;};1,/^---$/d' "$VERIFIER_AGENT" 2>/dev/null)"
  cat <<EOF
$body

---
Charter: $PROMPT_FILE
Plan: $PLAN_FILE
Inspect the diff since the last checkpoint: run \`git diff HEAD\` and
\`git log --oneline -5\`. Output ONLY the JSON verdict object.
EOF
}

# Robust extraction of the verifier's JSON verdict (fail-closed).
parse_verdict() { # raw -> echoes "pass" or "fail"
  local raw="$1" obj
  obj="$(printf '%s' "$raw" | jq -c 'if type=="object" then . else empty end' 2>/dev/null)"
  if [[ -z "$obj" ]]; then
    # strip code fences, then grab the first {...} block
    obj="$(printf '%s' "$raw" | sed -e 's/```json//g' -e 's/```//g' \
            | tr '\n' ' ' | grep -oE '\{.*\}' | head -1)"
  fi
  local pass
  pass="$(printf '%s' "$obj" | jq -r '.pass // empty' 2>/dev/null)"
  if [[ "$pass" == "true" ]]; then echo "pass"; else echo "fail"; fi
}

secret_scan() { # returns 0 clean, 1 hit; echoes hits
  local diff hits
  diff="$(git diff HEAD 2>/dev/null || true)"
  hits="$(printf '%s' "$diff" | grep -nE 'AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|gh[po]_[A-Za-z0-9]{20,}|sk-ant-[A-Za-z0-9-]{20,}|xox[bap]-[A-Za-z0-9-]+|(password|secret|token)\s*=\s*["'"'"'][^"'"'"']{6,}' 2>/dev/null || true)"
  [[ -z "$hits" ]] && return 0
  echo "$hits"; return 1
}

# ---------------------------------------------------------------------------
# Main loop.
# ---------------------------------------------------------------------------
log_err "run $RUN_ID on '$BRANCH' — verify='$VERIFY_CMD', budget=\$$BUDGET_USD, max_iter=$MAX_ITERATIONS, max_min=$MAX_MINUTES"
write_status "starting"

# PLAN phase — only if no plan exists yet.
if [[ ! -f "$PLAN_FILE" ]]; then
  ITER=0
  run_claude "plan" "$PLAN_MODEL" "Read,Edit,Write,Grep,Glob" "acceptEdits" "$(plan_prompt)" >/dev/null
fi

ITER=0
while :; do
  ITER=$(( ITER + 1 ))

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

  # BUILD
  run_claude "build" "$BUILD_MODEL" "$BUILD_ALLOWED_TOOLS" "acceptEdits" "$(build_prompt)" >/dev/null

  FAIL_REASON=""; FP=""

  # GATE a: sentinel
  if ! grep -q '^STATUS: done' "$PLAN_FILE" 2>/dev/null; then
    FAIL_REASON="plan not marked done"; FP="sentinel"
  fi

  # GATE b: machine verify (runner runs it — no LLM trust)
  if [[ -z "$FAIL_REASON" ]]; then
    write_status "verifying"
    if timeout "$PER_CALL_TIMEOUT" bash -c "$VERIFY_CMD" >"$STATE_DIR/verify.log" 2>&1; then
      logline "verify_cmd" "-" 0 0 0 0 0 "pass"
    else
      logline "verify_cmd" "-" 0 0 0 0 1 "fail"
      FAIL_REASON="verify command failed: $(tail -3 "$STATE_DIR/verify.log" | tr '\n' ' ')"
      FP="verify_cmd"
    fi
  fi

  # GATE c: secret scan (zero-cost)
  if [[ -z "$FAIL_REASON" ]]; then
    if SECRETS="$(secret_scan)"; then :; else
      FAIL_REASON="possible secret in diff: $(printf '%s' "$SECRETS" | head -2 | tr '\n' ' ')"
      FP="secret"
      logline "secret_scan" "-" 0 0 0 0 1 "fail"
    fi
  fi

  # GATE d: semantic verifier (haiku, adversarial)
  if [[ -z "$FAIL_REASON" ]]; then
    VOUT="$(run_claude "verify_agent" "$VERIFY_MODEL" "$VERIFY_ALLOWED_TOOLS" "plan" "$(verify_prompt)")"
    VERDICT="$(parse_verdict "$VOUT")"
    logline "verify_agent" "$VERIFY_MODEL" 0 0 0 0 0 "$VERDICT"
    if [[ "$VERDICT" != "pass" ]]; then
      printf '%s\n' "$VOUT" >> "$STATE_DIR/verifier-raw.log"
      FAIL_REASON="verifier found shortcuts: $(printf '%s' "$VOUT" | tr '\n' ' ' | head -c 300)"
      FP="verify_agent"
    fi
  fi

  # Prune memory mechanically (instructions to the model are advisory).
  if [[ -f "$MEMORY_FILE" ]]; then tail -n 100 "$MEMORY_FILE" > "$MEMORY_FILE.tmp" && mv "$MEMORY_FILE.tmp" "$MEMORY_FILE"; fi

  if [[ -z "$FAIL_REASON" ]]; then
    # SUCCESS — all gates green.
    git add -A && git commit -q -m "autopilot: iteration $ITER (green)" 2>/dev/null || true
    log_err "✅ all gates green at iteration $ITER — run complete."
    : > "$FEEDBACK_FILE"
    write_status "done"
    exit 0
  fi

  # FAILURE — feed back, reset sentinel, checkpoint WIP, maybe replan.
  log_err "gate failed [$FP]: $FAIL_REASON"
  : > "$FEEDBACK_FILE"; append_feedback "$FP" "$FAIL_REASON"
  sed -i.bak 's/^STATUS: done/STATUS: in-progress/' "$PLAN_FILE" 2>/dev/null && rm -f "$PLAN_FILE.bak"
  git add -A && git commit -q -m "autopilot: iteration $ITER (wip, gate=$FP)" 2>/dev/null || true

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
      "The autonomous run is stuck. Read $PROMPT_FILE, $PLAN_FILE, and $FEEDBACK_FILE. Revise $PLAN_FILE to unblock the repeated failure. Keep the STATUS line 'STATUS: in-progress'. Do not implement — only revise the plan." >/dev/null
  fi
done
