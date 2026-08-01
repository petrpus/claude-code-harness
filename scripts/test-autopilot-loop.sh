#!/usr/bin/env bash
# scripts/test-autopilot-loop.sh — end-to-end control-flow tests for
# skills/autopilot/loop.sh, driven by a stub `claude` on PATH.
#
# The loop had no test at all, which is how it shipped with a gate that made
# any plan longer than three slices impossible to finish: BUILD does one item
# per iteration, the completion sentinel is therefore false until the last one,
# and counting that as a failure tripped the stuck detector on three perfectly
# good iterations. Nothing caught it because nothing ran the loop.
#
# The stub answers each phase the way a well-behaved (or deliberately
# misbehaving) agent would, so the runner's decisions — progress vs. failure,
# when to abort, which exit code — are exercised for real without spending a
# cent on `claude -p`.
#
# Invoked from scripts/verify.sh. Cleaned up on exit.

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1

FAIL=0
note() { echo "  ✗ $*"; FAIL=1; }
ok()   { echo "  ✓ $*"; }

LOOP="skills/autopilot/loop.sh"
[[ -f "$LOOP" ]] || { note "$LOOP is missing"; echo; echo "test-autopilot-loop: $FAIL failure(s)"; exit 1; }
LOOP_ABS="$(cd "$(dirname "$LOOP")" && pwd)/$(basename "$LOOP")"

command -v jq >/dev/null 2>&1 || { note "jq is required"; echo; echo "test-autopilot-loop: $FAIL failure(s)"; exit 1; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- the stub -------------------------------------------------------------
# Phases are told apart by the prompt text loop.sh sends. STUB_MODE picks the
# behaviour: tick one box per iteration, or never tick anything.
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
prompt="$*"
plan="tmp/autopilot/IMPLEMENTATION_PLAN.md"
emit() { printf '{"result":%s,"total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0}}\n' "$1"; }

case "$prompt" in
  *"PLAN phase"*|*"autonomous run is stuck"*)
    if [[ ! -f "$plan" || "$prompt" == *"autonomous run is stuck"* ]]; then
      { echo "# plan"
        for i in 1 2 3 4 5; do echo "- [ ] slice $i"; done
        echo
        echo "STATUS: in-progress"
      } > "$plan"
    fi
    emit '"planned"'
    ;;
  *"ONE iteration of an autonomous BUILD loop"*)
    if [[ "${STUB_MODE:-progress}" == "progress" ]]; then
      # touch a tracked file so the iteration has something to checkpoint
      mkdir -p src && date +%s%N >> src/work.txt
      # tick the first unticked box
      awk 'BEGIN{done=0} { if (!done && $0 ~ /^- \[ \]/) { sub(/^- \[ \]/, "- [x]"); done=1 } print }' \
        "$plan" > "$plan.tmp" && mv "$plan.tmp" "$plan"
      if ! grep -q '^- \[ \]' "$plan"; then
        sed -i 's/^STATUS: in-progress/STATUS: done/' "$plan"
      fi
    fi
    emit '"built"'
    ;;
  *"verdict"*|*"shortcut"*|*"Verdict"*)
    emit '"{\"pass\": true}"'
    ;;
  *)
    emit '"ok"'
    ;;
esac
STUB
chmod +x "$STUB_DIR/claude"

new_repo() { # dir
  mkdir -p "$1/tmp/autopilot"
  git -C "$1" init -q
  printf 'tmp/\n' > "$1/.gitignore"
  printf '# app\n' > "$1/README.md"
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" -c user.email=t@t.est -c user.name=test commit -q -m init
  git -C "$1" checkout -q -b feature
  cat > "$1/tmp/autopilot/PROMPT.md" <<'EOF'
# Autopilot charter
## Source
- issue: test
## Goal
Exercise the loop.
## Acceptance criteria
- [ ] All slices done.
EOF
}

run_loop() { # dir mode verify-cmd extra...
  local dir="$1" mode="$2" vcmd="$3"; shift 3
  ( cd "$dir" && PATH="$STUB_DIR:$PATH" STUB_MODE="$mode" \
      bash "$LOOP_ABS" --verify-cmd "$vcmd" --max-iterations 12 --max-minutes 30 --budget-usd 5 "$@" \
      >"$WORK/$(basename "$dir").out" 2>"$WORK/$(basename "$dir").err" )
}

runlog_verdicts() { # dir verdict
  cat "$1"/tmp/autopilot/run-*.jsonl 2>/dev/null \
    | jq -r 'select(.phase=="iteration") | .verdict' 2>/dev/null | grep -c "^$2$" || true
}

# --- 1. a five-slice plan must finish -------------------------------------
R1="$WORK/r1"; new_repo "$R1"
run_loop "$R1" progress true
RC1=$?
[[ "$RC1" -eq 0 ]] \
  && ok "five-slice plan runs to completion (exit 0)" \
  || note "five-slice plan exited $RC1 — expected 0 (stuck detector still misfiring?)"

PROGRESSED="$(runlog_verdicts "$R1" progressed)"
[[ "${PROGRESSED:-0}" -ge 4 ]] \
  && ok "run log records $PROGRESSED progressed iterations" \
  || note "run log shows ${PROGRESSED:-0} progressed iterations, expected >= 4"

DONE_ROWS="$(runlog_verdicts "$R1" done)"
[[ "${DONE_ROWS:-0}" -eq 1 ]] \
  && ok "run log distinguishes the completing iteration" \
  || note "expected exactly one 'done' row, got ${DONE_ROWS:-0}"

# Capture first, then match. `git log | grep -q` closes the pipe on the first
# hit, git takes SIGPIPE, and pipefail turns the whole pipeline non-zero — the
# exact trap CLAUDE.md warns about.
R1_LOG="$(git -C "$R1" log --oneline 2>/dev/null)"
case "$R1_LOG" in
  *"progress:"*) ok "progress iterations are checkpointed as progress, not wip" ;;
  *)             note "no progress checkpoint commits found" ;;
esac
case "$R1_LOG" in
  *"gate=sentinel"*) note "still producing 'gate=sentinel' wip commits on good iterations" ;;
  *)                 ok "no sentinel gate failures on good iterations" ;;
esac

# --- 2. no progress is still a failure, and still aborts -------------------
R2="$WORK/r2"; new_repo "$R2"
run_loop "$R2" stall true
RC2=$?
[[ "$RC2" -eq 4 ]] \
  && ok "three no-progress iterations abort with exit 4" \
  || note "stalled run exited $RC2 — expected 4"

grep -q "no-progress" "$WORK/r2.err" 2>/dev/null \
  && ok "stall is reported as no-progress, not as a sentinel failure" \
  || note "stall was not fingerprinted as no-progress"

[[ -s "$R2/tmp/autopilot/FEEDBACK.md" ]] \
  && ok "a failed iteration still feeds FEEDBACK.md" \
  || note "FEEDBACK.md is empty after a failed iteration"

# --- 3. a red verify is still an iteration failure ------------------------
R3="$WORK/r3"; new_repo "$R3"
run_loop "$R3" progress false
RC3=$?
[[ "$RC3" -eq 4 ]] \
  && ok "a failing verify command still aborts the run (exit 4)" \
  || note "run with a red verify exited $RC3 — expected 4"
grep -q "verify_cmd" "$WORK/r3.err" 2>/dev/null \
  && ok "the red verify is fingerprinted as verify_cmd" \
  || note "verify failure was not fingerprinted as verify_cmd"

# Every iteration must be verified now — under the old sentinel gate, verify was
# skipped entirely whenever the plan wasn't yet complete.
VERIFY_ROWS="$(cat "$R1"/tmp/autopilot/run-*.jsonl 2>/dev/null | jq -r 'select(.phase=="verify_cmd") | .verdict' 2>/dev/null | grep -c '^pass$' || true)"
[[ "${VERIFY_ROWS:-0}" -ge 5 ]] \
  && ok "verify ran on every iteration ($VERIFY_ROWS passes), not just the last" \
  || note "verify ran ${VERIFY_ROWS:-0} times across a 5-slice run — intermediate iterations went unverified"

# --- 4. the iteration cap still bounds an unmeasurable plan ---------------
R4="$WORK/r4"; new_repo "$R4"
printf '# plan with no checkboxes\n\nSTATUS: in-progress\n' > "$R4/tmp/autopilot/IMPLEMENTATION_PLAN.md"
( cd "$R4" && PATH="$STUB_DIR:$PATH" STUB_MODE=stall \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 2 --max-minutes 30 --budget-usd 5 \
    >"$WORK/r4.out" 2>"$WORK/r4.err" )
RC4=$?
[[ "$RC4" -eq 2 ]] \
  && ok "a plan with no checkboxes is bounded by the iteration cap (exit 2)" \
  || note "unmeasurable plan exited $RC4 — expected 2 (iteration cap)"

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "test-autopilot-loop: PASS"
else
  echo "test-autopilot-loop: $FAIL failure(s)"
fi
exit "$FAIL"
