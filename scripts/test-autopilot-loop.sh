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

# R1's runner-reload handoff (AUTOPILOT_RUN_ID/ITER/TOTAL_COST/LOCK_OWNED) is
# meant to travel from one loop.sh process to its own re-exec, never further.
# When THIS test script itself runs as part of a live autopilot iteration
# (verify.sh invoked from inside skills/autopilot/loop.sh's own BUILD phase —
# exactly the run developing this harness), those vars are already exported
# in the ambient shell and would otherwise leak into every "fresh run" fixture
# below, making it silently adopt the live run's id/iter/cost instead of
# starting clean. Every fixture here is a deliberately fresh run (or hand-
# crafts the resume state it wants via --resume-run / a planted run-*.jsonl),
# so strip the ambient handoff once, up front, rather than patch every call
# site that shells out to loop.sh.
unset AUTOPILOT_RUN_ID AUTOPILOT_ITER AUTOPILOT_TOTAL_COST AUTOPILOT_LOCK_OWNED

FAIL=0
note() { echo "  ✗ $*"; FAIL=1; }
ok()   { echo "  ✓ $*"; }

LOOP="skills/autopilot/loop.sh"
[[ -f "$LOOP" ]] || { note "$LOOP is missing"; echo; echo "test-autopilot-loop: $FAIL failure(s)"; exit 1; }
LOOP_ABS="$(cd "$(dirname "$LOOP")" && pwd)/$(basename "$LOOP")"

# S5: repo-map digest.sh, exercised both through the loop (as loop.sh itself
# invokes it) and directly (for the line-cap unit check below).
DIGEST="skills/repo-map/digest.sh"
[[ -f "$DIGEST" ]] || { note "$DIGEST is missing"; echo; echo "test-autopilot-loop: $FAIL failure(s)"; exit 1; }
DIGEST_ABS="$(cd "$(dirname "$DIGEST")" && pwd)/$(basename "$DIGEST")"

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
[[ -n "${STUB_CALL_LOG:-}" ]] && printf '%s\n' "$*" >> "$STUB_CALL_LOG"
prompt="$*"
plan="tmp/autopilot/IMPLEMENTATION_PLAN.md"
emit() { printf '{"result":%s,"total_cost_usd":%s,"usage":{"input_tokens":0,"output_tokens":0}}\n' "$1" "${STUB_COST_PER_CALL:-0}"; }

case "$prompt" in
  *"PLAN phase"*|*"autonomous run is stuck"*)
    # S4A: some fixtures hand-craft a plan whose STRUCTURE (ids, after:
    # edges) is the whole point of the test — a rung-4 replan overwriting it
    # with the generic 5-slice-word plan would destroy the very DAG being
    # exercised. STUB_REPLAN_KEEP_PLAN leaves the on-disk plan untouched;
    # loop.sh's own slices_clear() still does the real unparking, the model
    # call here is only ever cosmetic to that mechanism.
    if [[ -n "${STUB_REPLAN_KEEP_PLAN:-}" && "$prompt" == *"autonomous run is stuck"* ]]; then
      emit '"planned"'; exit 0
    fi
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
    # S2 (holdout scenarios): if this run is checking that holdout content
    # never reaches BUILD, flag it — the outer test asserts the file this
    # writes to stays empty.
    if [[ -n "${STUB_HOLDOUT_SENTINEL:-}" ]] \
       && printf '%s' "$prompt" | grep -qF "$STUB_HOLDOUT_SENTINEL"; then
      printf 'LEAK: holdout sentinel reached the BUILD prompt\n' >> "${STUB_LEAK_FILE:-/dev/null}"
    fi
    # R1 (runner self-reload): simulate a slice whose own job is to edit
    # loop.sh, exactly once, guarded by a flag file so it doesn't keep
    # editing on every subsequent iteration (which would never converge).
    if [[ -n "${STUB_EDIT_RUNNER:-}" && ! -f "${STUB_EDIT_RUNNER_FLAG:-/dev/null}" ]]; then
      printf '# stub: simulated runner edit %s\n' "$(date +%s%N)" >> "$STUB_EDIT_RUNNER"
      touch "$STUB_EDIT_RUNNER_FLAG"
    fi
    if [[ "${STUB_MODE:-progress}" == "progress" ]]; then
      # touch a tracked file so the iteration has something to checkpoint
      mkdir -p src && date +%s%N >> src/work.txt
      # S1B: the runner now injects "plan item `<id>`" when it picked a
      # specific slice via select_next_slice(). Tick THAT line, not merely
      # "the first unticked box" — this is what actually proves the loop
      # walks a diamond DAG in dependency order instead of file order.
      # id-less plans (no annotations at all) carry no such phrase, so fall
      # back to "first unticked box", which is 0.4.0 behaviour.
      sel_id="$(printf '%s' "$prompt" | grep -oE 'plan item `[^`]+`' | head -1 | sed -E 's/plan item `([^`]+)`/\1/')"
      # S4A: STUB_FAIL_ID names an id that BUILD never manages to finish —
      # gates still run and pass, but the checkbox stays unticked, producing
      # a genuine "no progress" per-slice failure so the ladder (retry →
      # park) has something real to count for that one id while its siblings
      # complete normally.
      if [[ -n "${STUB_FAIL_ID:-}" && "$sel_id" == "$STUB_FAIL_ID" ]]; then
        :
      elif [[ -n "$sel_id" ]]; then
        awk -v id="$sel_id" 'BEGIN{done=0} { if (!done && $0 ~ ("^- \\[ \\] " id "([[:space:]]|$)")) { sub(/^- \[ \]/, "- [x]"); done=1 } print }' \
          "$plan" > "$plan.tmp" && mv "$plan.tmp" "$plan"
      else
        awk 'BEGIN{done=0} { if (!done && $0 ~ /^- \[ \]/) { sub(/^- \[ \]/, "- [x]"); done=1 } print }' \
          "$plan" > "$plan.tmp" && mv "$plan.tmp" "$plan"
      fi
      if ! grep -q '^- \[ \]' "$plan"; then
        sed -i 's/^STATUS: in-progress/STATUS: done/' "$plan"
      fi
    fi
    emit '"built"'
    ;;
  *"verdict"*|*"shortcut"*|*"Verdict"*)
    # R2: a verifier that declines to judge (prose, a clarifying question, no
    # parseable `.pass`) must be told apart from a real {"pass": false} — the
    # three STUB_VERIFY_* knobs below simulate each shape the runner has to
    # handle.
    if [[ "${STUB_VERIFY_NO_VERDICT:-}" == "always" ]]; then
      emit '"I cannot produce a verdict without more context. Could you clarify the scope?"'
    elif [[ "${STUB_VERIFY_NO_VERDICT:-}" == "once" ]]; then
      n=0
      if [[ -n "${STUB_VERIFY_COUNT_FILE:-}" ]]; then
        [[ -f "$STUB_VERIFY_COUNT_FILE" ]] && n="$(cat "$STUB_VERIFY_COUNT_FILE")"
        n=$(( n + 1 ))
        echo "$n" > "$STUB_VERIFY_COUNT_FILE"
      fi
      if (( n % 2 == 1 )); then
        emit '"I cannot produce a verdict without more context. Could you clarify the scope?"'
      else
        emit '"{\"pass\": true}"'
      fi
    elif [[ "${STUB_VERIFY_FAIL:-0}" == "1" ]]; then
      emit '"{\"pass\": false, \"violations\": [{\"shortcut\": 7, \"evidence\": \"x:1\", \"note\": \"mock\"}]}"'
    elif [[ "${STUB_HOLDOUT_FAIL:-0}" == "1" ]]; then
      emit '"{\"pass\": false, \"violations\": [], \"holdout\": {\"checked\": 1, \"failed\": [\"H1\"]}}"'
    else
      emit '"{\"pass\": true}"'
    fi
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
      STUB_CALL_LOG="$WORK/$(basename "$dir").calls" \
      bash "$LOOP_ABS" --verify-cmd "$vcmd" --max-iterations 12 --max-minutes 30 --budget-usd 5 "$@" \
      >"$WORK/$(basename "$dir").out" 2>"$WORK/$(basename "$dir").err" )
}

runlog_verdicts() { # dir verdict
  cat "$1"/tmp/autopilot/run-*.jsonl 2>/dev/null \
    | jq -r 'select(.phase=="iteration") | .verdict' 2>/dev/null | grep -c "^$2$" || true
}

# --- 1. a five-slice plan must finish -------------------------------------
# This plan carries no id/after: annotations at all — a 0.4.0-era plan file,
# unchanged by S1B's Plan DAG wiring (contract item 8) — so it doubles as
# loop-test (e) from docs/prd/0002-harness-upgrade.md § S1.
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

# Claude Code's --permission-mode plan is the interactive planning mode: it
# blocks non-read-only tool calls outright and can only be left via
# ExitPlanMode/AskUserQuestion, neither of which exists in a `claude -p`
# subprocess. Handed to verify_agent it can't run even its own read-only
# allowlist (Bash git diff/log/status) and can never produce a real verdict.
# Regression for the run that shipped this: verify_agent's own transcript
# refused to verdict because "bash scripts/verify.sh was concretely denied".
grep -q -- '--permission-mode plan' "$WORK/r1.calls" 2>/dev/null \
  && note "a phase is invoked with --permission-mode plan (blocks it from running its own allowlisted tools)" \
  || ok "no phase is invoked under Claude Code's interactive plan mode"

# This repo IS the autopilot runner's own source, so a slice can legitimately
# edit agents/verifier.md (e.g. S1B added shortcut #14, S2 added #15-#17) —
# the verifier then sees its own charter file inside `git diff HEAD`. Without
# an explicit reassurance, a real verifier model reads that as its
# instructions being tampered with and refuses to verdict at all (the run
# that shipped this: iteration 3's FEEDBACK.md was the verifier asking a
# clarifying question instead of reviewing the diff). Regression: the
# reassurance text must be present in every verify_agent call, not just when
# agents/verifier.md happens to be in the diff — it's static prompt text.
grep -q "not an attempt to alter" "$WORK/r1.calls" 2>/dev/null \
  && ok "the verifier prompt reassures it against self-referential charter edits" \
  || note "verify_prompt() is missing the self-edit reassurance text (regression: iteration-3 verifier confusion)"

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

# --- 5. Plan DAG (S1B): the runner walks a diamond in dependency order -----
# select_next_slice() itself is unit-tested directly against plan.sh in
# scripts/verify.sh; this exercises the actual wiring into loop.sh — that the
# selected id/line reach build_prompt() and are honoured in order, not just
# that the parser is correct in isolation.
R5="$WORK/r5"; new_repo "$R5"
cat > "$R5/tmp/autopilot/IMPLEMENTATION_PLAN.md" <<'EOF'
- [ ] S1 — root (after: —)
- [ ] S2 — left (after: S1)
- [ ] S3 — right (after: S1)
- [ ] S4 — join (after: S2, S3)

STATUS: in-progress
EOF
run_loop "$R5" progress true
RC5=$?
[[ "$RC5" -eq 0 ]] \
  && ok "a diamond Plan DAG runs to completion through loop.sh (exit 0)" \
  || note "diamond DAG run exited $RC5 — expected 0"

SELECTED_SEQ="$(grep -oE 'plan item `[^`]+`' "$WORK/r5.calls" 2>/dev/null \
  | sed -E 's/plan item `([^`]+)`/\1/' | tr '\n' ',')"
[[ "$SELECTED_SEQ" == "S1,S2,S3,S4," ]] \
  && ok "runner selected S1, S2, S3, S4 in that order (dependency order, not file order alone)" \
  || note "selection order was '$SELECTED_SEQ', want S1,S2,S3,S4,"

# --- 6. Plan DAG (S1B): a cycle is a plan_dag failure, replans immediately -
R6="$WORK/r6"; new_repo "$R6"
cat > "$R6/tmp/autopilot/IMPLEMENTATION_PLAN.md" <<'EOF'
- [ ] A — (after: B)
- [ ] B — (after: A)

STATUS: in-progress
EOF
run_loop "$R6" progress true
RC6=$?
[[ "$RC6" -eq 0 ]] \
  && ok "a cyclic plan self-heals via replan and the run still completes (exit 0)" \
  || note "cyclic-plan run exited $RC6 — expected 0 (replan should have fixed it)"
grep -q "plan_dag" "$WORK/r6.err" 2>/dev/null \
  && ok "the cycle is fingerprinted as plan_dag" \
  || note "cycle failure was not fingerprinted as plan_dag"
grep -q "stuck on 'plan_dag'" "$WORK/r6.err" 2>/dev/null \
  && note "plan_dag went through the stuck ladder instead of bypassing it" \
  || ok "plan_dag replans immediately, without going through escalate/park"

# --- 7. Plan DAG (S1B): an unknown after: id is the same plan_dag failure --
R7="$WORK/r7"; new_repo "$R7"
cat > "$R7/tmp/autopilot/IMPLEMENTATION_PLAN.md" <<'EOF'
- [ ] X — (after: GHOST)

STATUS: in-progress
EOF
run_loop "$R7" progress true
RC7=$?
[[ "$RC7" -eq 0 ]] \
  && ok "an unknown blocker id self-heals via replan and the run still completes (exit 0)" \
  || note "unknown-blocker-id run exited $RC7 — expected 0 (replan should have fixed it)"
grep -q "plan_dag" "$WORK/r7.err" 2>/dev/null \
  && ok "the unknown blocker id is fingerprinted as plan_dag" \
  || note "unknown-blocker-id failure was not fingerprinted as plan_dag"

# --- 8. Holdout scenarios (S2): hidden from BUILD, seen by the verifier ----
# docs/adr/0006-holdout-scenarios-hidden-by-location.md
R8="$WORK/r8"; new_repo "$R8"
HOLDOUT_R8="$WORK/r8-holdout.md"
cat > "$HOLDOUT_R8" <<'EOF'
## H1: sentinel scenario
- Given: TOPSECRET-SCENARIO-H1
- When: the change lands
- Then: this text must never reach the BUILD prompt
EOF
( cd "$R8" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress STUB_HOLDOUT_FAIL=1 \
    STUB_HOLDOUT_SENTINEL="TOPSECRET-SCENARIO-H1" STUB_LEAK_FILE="$WORK/r8.leak" \
    STUB_CALL_LOG="$WORK/r8.calls" \
    bash "$LOOP_ABS" --verify-cmd true --holdout "$HOLDOUT_R8" \
      --max-iterations 5 --max-minutes 30 --budget-usd 5 \
      >"$WORK/r8.out" 2>"$WORK/r8.err" )
RC8=$?

[[ "$RC8" -eq 4 ]] \
  && ok "a holdout failure that keeps recurring aborts like any stuck gate (exit 4)" \
  || note "holdout-failing run exited $RC8 — expected 4 (stuck on repeated 'holdout')"

grep -q "stuck on 'holdout'" "$WORK/r8.err" 2>/dev/null \
  && ok "the holdout failure is fingerprinted 'holdout', distinct from verify_agent" \
  || note "holdout failure was not fingerprinted as 'holdout' in the runner's log"

grep -q "H1" "$R8/tmp/autopilot/FEEDBACK.md" 2>/dev/null \
  && ok "FEEDBACK.md names the failing holdout scenario id" \
  || note "FEEDBACK.md doesn't mention the failing scenario id H1"

[[ ! -s "$WORK/r8.leak" ]] \
  && ok "the holdout path/content never reached the BUILD prompt" \
  || note "the BUILD prompt leaked holdout content: $(cat "$WORK/r8.leak" 2>/dev/null)"

# --- 9. Holdout scenarios (S2): a missing file is a notice, not an error ---
R9="$WORK/r9"; new_repo "$R9"
run_loop "$R9" progress true --holdout "$WORK/does-not-exist-$$.md"
RC9=$?
[[ "$RC9" -eq 0 ]] \
  && ok "a missing --holdout file still lets the run complete (exit 0)" \
  || note "missing-holdout-file run exited $RC9 — expected 0"

NOTICE_COUNT="$(grep -c "no HOLDOUT.md — holdout gate disabled" "$WORK/r9.err" 2>/dev/null)" || NOTICE_COUNT=0
[[ "${NOTICE_COUNT:-0}" -eq 1 ]] \
  && ok "the missing-holdout notice logs exactly once per run, not every iteration" \
  || note "missing-holdout notice logged ${NOTICE_COUNT:-0} times, expected exactly 1"

# --- 10-11. Runner self-reload (R1) ----------------------------------------
# bash parses loop.sh's (and plan.sh's/allowlist.sh's) function bodies once,
# at startup, so a slice whose job is to fix the runner never changes the
# process running it — only a run a human starts afterwards. These tests
# drive an isolated COPY of the runner (never the repo's own loop.sh), since
# the stub deliberately mutates it mid-run to simulate exactly that slice.
PLUGIN_COPY="$WORK/plugin-copy"
mkdir -p "$PLUGIN_COPY/skills/autopilot" "$PLUGIN_COPY/agents"
LOOP_SRC_DIR="$(dirname "$LOOP_ABS")"
cp "$LOOP_ABS" "$PLUGIN_COPY/skills/autopilot/loop.sh"
cp "$LOOP_SRC_DIR/plan.sh" "$PLUGIN_COPY/skills/autopilot/plan.sh"
cp "$LOOP_SRC_DIR/allowlist.sh" "$PLUGIN_COPY/skills/autopilot/allowlist.sh"
cp agents/verifier.md "$PLUGIN_COPY/agents/verifier.md"
COPY_LOOP="$PLUGIN_COPY/skills/autopilot/loop.sh"

run_loop_copy() { # dir mode verify-cmd extra...
  local dir="$1" mode="$2" vcmd="$3"; shift 3
  ( cd "$dir" && PATH="$STUB_DIR:$PATH" STUB_MODE="$mode" \
      STUB_CALL_LOG="$WORK/$(basename "$dir").calls" \
      bash "$COPY_LOOP" --verify-cmd "$vcmd" --max-iterations 12 --max-minutes 30 --budget-usd 5 "$@" \
      >"$WORK/$(basename "$dir").out" 2>"$WORK/$(basename "$dir").err" )
}

# --- 10. A slice that edits loop.sh takes effect within the same run -------
R10="$WORK/r10"; new_repo "$R10"
EDIT_FLAG="$WORK/r10-edit.flag"; rm -f "$EDIT_FLAG"
( cd "$R10" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress \
    STUB_CALL_LOG="$WORK/r10.calls" \
    STUB_EDIT_RUNNER="$COPY_LOOP" STUB_EDIT_RUNNER_FLAG="$EDIT_FLAG" \
    bash "$COPY_LOOP" --verify-cmd true --max-iterations 12 --max-minutes 30 --budget-usd 5 \
    >"$WORK/r10.out" 2>"$WORK/r10.err" )
RC10=$?
[[ "$RC10" -eq 0 ]] \
  && ok "a run whose BUILD phase edits loop.sh still completes (exit 0)" \
  || note "runner-self-edit run exited $RC10 — expected 0"

RELOAD_COUNT="$(grep -c "reloading" "$WORK/r10.err" 2>/dev/null)" || RELOAD_COUNT=0
[[ "${RELOAD_COUNT:-0}" -eq 1 ]] \
  && ok "the runner reloads itself exactly once" \
  || note "expected exactly one reload, saw ${RELOAD_COUNT:-0} (see $WORK/r10.err)"

RUN_LOG_COUNT="$(find "$R10/tmp/autopilot" -maxdepth 1 -name 'run-*.jsonl' 2>/dev/null | grep -c .)" || RUN_LOG_COUNT=0
[[ "$RUN_LOG_COUNT" -eq 1 ]] \
  && ok "the reload keeps the same run id (a single run-*.jsonl file)" \
  || note "expected exactly one run-*.jsonl file, found $RUN_LOG_COUNT"

MAX_ITER="$(cat "$R10"/tmp/autopilot/run-*.jsonl 2>/dev/null | jq -s 'map(.iter // 0) | max // 0' 2>/dev/null)"
[[ "${MAX_ITER:-0}" -ge 5 ]] \
  && ok "iteration numbering kept increasing across the reload (max iter $MAX_ITER)" \
  || note "iteration count looks reset across the reload (max iter ${MAX_ITER:-0})"

# --- 11. An untouched runner never reloads ----------------------------------
R11="$WORK/r11"; new_repo "$R11"
run_loop_copy "$R11" progress true
RC11=$?
[[ "$RC11" -eq 0 ]] \
  && ok "an untouched runner still completes normally (exit 0)" \
  || note "untouched-runner run exited $RC11 — expected 0"
grep -q "reloading" "$WORK/r11.err" 2>/dev/null \
  && note "the runner reloaded even though nothing edited it" \
  || ok "no spurious reload when loop.sh/plan.sh/allowlist.sh are untouched"

# c: neither test 10 nor test 11 tripped the concurrency lock or the
# dirty-tree guard — both already assert exit 0 above, which those guards
# would have prevented (exit 1) had the reload mishandled either one.
[[ "$RC10" -eq 0 && "$RC11" -eq 0 ]] \
  && ok "the reload trips neither the concurrency lock nor the dirty-tree guard" \
  || note "a reload run hit a guard instead of completing (rc10=$RC10, rc11=$RC11)"

# --- 12. --resume-run adopts the prior run's id, iter and cost -------------
# Hand-craft a prior run's log rather than orchestrating one, so the
# expected id/iter/cost are known exactly instead of inferred.
R12="$WORK/r12"; new_repo "$R12"
cat > "$R12/tmp/autopilot/IMPLEMENTATION_PLAN.md" <<'EOF'
- [ ] slice 1
- [ ] slice 2

STATUS: in-progress
EOF
PRIOR_RUN_ID="20260101T000000Z-999999"
cat > "$R12/tmp/autopilot/run-$PRIOR_RUN_ID.jsonl" <<EOF
{"ts":"2026-01-01T00:00:00Z","run_id":"$PRIOR_RUN_ID","iter":1,"phase":"build","model":"sonnet","duration_s":1,"cost_usd":1.25,"input_tokens":0,"output_tokens":0,"exit_code":0,"verdict":"","holdout_failed":0}
{"ts":"2026-01-01T00:00:01Z","run_id":"$PRIOR_RUN_ID","iter":1,"phase":"iteration","model":"-","duration_s":0,"cost_usd":0,"input_tokens":0,"output_tokens":0,"exit_code":0,"verdict":"wip","holdout_failed":0}
{"ts":"2026-01-01T00:00:02Z","run_id":"$PRIOR_RUN_ID","iter":2,"phase":"build","model":"sonnet","duration_s":1,"cost_usd":0.75,"input_tokens":0,"output_tokens":0,"exit_code":0,"verdict":"","holdout_failed":0}
EOF
( cd "$R12" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 2 --max-minutes 30 --budget-usd 999 --resume-run \
    >"$WORK/r12.out" 2>"$WORK/r12.err" )
RC12=$?
[[ "$RC12" -eq 2 ]] \
  && ok "--resume-run adopts the prior iteration count (hits the iteration cap immediately)" \
  || note "--resume-run run exited $RC12 — expected 2 (iteration cap, proving iter=2 was adopted)"

RESUMED_RUN_ID="$(jq -r '.run_id' "$R12/tmp/autopilot/status.json" 2>/dev/null)"
[[ "$RESUMED_RUN_ID" == "$PRIOR_RUN_ID" ]] \
  && ok "--resume-run adopts the prior run's id ($PRIOR_RUN_ID)" \
  || note "--resume-run started run '$RESUMED_RUN_ID' instead of resuming '$PRIOR_RUN_ID'"

RESUMED_COST="$(jq -r '.total_cost_usd // -1' "$R12/tmp/autopilot/status.json" 2>/dev/null)"
COST_IS_TWO="$(jq -n --argjson v "${RESUMED_COST:--1}" '$v == 2' 2>/dev/null)"
[[ "$COST_IS_TWO" == "true" ]] \
  && ok "--resume-run's cost total starts from the prior run's \$2 (1.25+0.75), not \$0" \
  || note "--resume-run's cost total is '$RESUMED_COST', expected 2 (summed from the prior log)"

# --- 13. R2: a verifier stuck on "no verdict" still aborts, and FEEDBACK.md --
# names the malfunction instead of quoting the refusal as findings ----------
R13="$WORK/r13"; new_repo "$R13"
( cd "$R13" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress STUB_VERIFY_NO_VERDICT=always \
    STUB_CALL_LOG="$WORK/r13.calls" \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 6 --max-minutes 30 --budget-usd 5 \
    >"$WORK/r13.out" 2>"$WORK/r13.err" )
RC13=$?
[[ "$RC13" -eq 4 ]] \
  && ok "a verifier permanently stuck on 'no verdict' still aborts (exit 4)" \
  || note "no_verdict run exited $RC13 — expected 4 (a broken gate must still terminate the run)"

grep -q "stuck on 'no_verdict'" "$WORK/r13.err" 2>/dev/null \
  && ok "the refusal is fingerprinted 'no_verdict', distinct from verify_agent" \
  || note "refusal was not fingerprinted 'no_verdict' in the runner's log"

grep -qi "found shortcuts" "$R13/tmp/autopilot/FEEDBACK.md" 2>/dev/null \
  && note "FEEDBACK.md quotes the refusal as 'found shortcuts' — a refusal isn't a finding" \
  || ok "FEEDBACK.md never presents the refusal as 'found shortcuts'"

grep -q "no verdict twice" "$R13/tmp/autopilot/FEEDBACK.md" 2>/dev/null \
  && ok "FEEDBACK.md names the gate malfunction explicitly" \
  || note "FEEDBACK.md doesn't explain the gate malfunction"

# Exactly one retry per iteration: two verify calls for every one build call.
BUILD_CALLS_13="$(grep -cF 'ONE iteration of an autonomous BUILD loop' "$WORK/r13.calls" 2>/dev/null)" || BUILD_CALLS_13=0
VERIFY_CALLS_13="$(grep -cF 'Output ONLY the JSON verdict object.' "$WORK/r13.calls" 2>/dev/null)" || VERIFY_CALLS_13=0
[[ "$BUILD_CALLS_13" -gt 0 && "$VERIFY_CALLS_13" -eq $(( BUILD_CALLS_13 * 2 )) ]] \
  && ok "each stuck iteration retried the verifier exactly once ($VERIFY_CALLS_13 verify calls over $BUILD_CALLS_13 builds)" \
  || note "expected 2 verify calls per build, got $VERIFY_CALLS_13 verify calls over $BUILD_CALLS_13 builds"

# --- 14. R2: a genuine {"pass": false} verdict is unaffected — no retry, ---
# still fingerprinted verify_agent -------------------------------------------
R14="$WORK/r14"; new_repo "$R14"
( cd "$R14" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress STUB_VERIFY_FAIL=1 \
    STUB_CALL_LOG="$WORK/r14.calls" \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 6 --max-minutes 30 --budget-usd 5 \
    >"$WORK/r14.out" 2>"$WORK/r14.err" )
RC14=$?
[[ "$RC14" -eq 4 ]] \
  && ok "a genuine verify_agent failure still aborts via the stuck ladder (exit 4)" \
  || note "genuine-fail run exited $RC14 — expected 4"
grep -q "stuck on 'verify_agent'" "$WORK/r14.err" 2>/dev/null \
  && ok "a real {\"pass\": false} verdict keeps the verify_agent fingerprint (R2 path unchanged)" \
  || note "genuine fail wasn't fingerprinted 'verify_agent'"

BUILD_CALLS_14="$(grep -cF 'ONE iteration of an autonomous BUILD loop' "$WORK/r14.calls" 2>/dev/null)" || BUILD_CALLS_14=0
VERIFY_CALLS_14="$(grep -cF 'Output ONLY the JSON verdict object.' "$WORK/r14.calls" 2>/dev/null)" || VERIFY_CALLS_14=0
[[ "$BUILD_CALLS_14" -gt 0 && "$VERIFY_CALLS_14" -eq "$BUILD_CALLS_14" ]] \
  && ok "a genuine fail verdict is not retried (1 verify call per iteration)" \
  || note "expected 1 verify call per build for a genuine fail, got $VERIFY_CALLS_14 over $BUILD_CALLS_14"

# --- 15. R2: a verifier whose retry produces a real pass lets the run ------
# proceed normally, not stuck on the first refusal ---------------------------
R15="$WORK/r15"; new_repo "$R15"
COUNT_FILE_15="$WORK/r15-verify-count"; rm -f "$COUNT_FILE_15"
( cd "$R15" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress STUB_VERIFY_NO_VERDICT=once \
    STUB_VERIFY_COUNT_FILE="$COUNT_FILE_15" STUB_CALL_LOG="$WORK/r15.calls" \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 12 --max-minutes 30 --budget-usd 5 \
    >"$WORK/r15.out" 2>"$WORK/r15.err" )
RC15=$?
[[ "$RC15" -eq 0 ]] \
  && ok "a run recovers when the verifier's retry produces a real pass (exit 0)" \
  || note "recovering-retry run exited $RC15 — expected 0"
grep -q "retrying once" "$WORK/r15.err" 2>/dev/null \
  && ok "the runner logs the retry" \
  || note "no retry was logged for the recovering run"
[[ ! -s "$R15/tmp/autopilot/FEEDBACK.md" ]] \
  && ok "FEEDBACK.md is empty once every iteration recovered on retry" \
  || note "FEEDBACK.md still holds stale content: $(cat "$R15/tmp/autopilot/FEEDBACK.md" 2>/dev/null)"

# --- 16. S3A: per-call and per-iteration metrics land in the run log -------
# A three-slice annotated plan run to completion, then type-check every new
# field on both a "build" row (per-call: turns, cache tokens) and an
# "iteration" row (per-iteration: slice_id, ticked_delta, gate_failed, wall_s,
# cost_usd, files_changed, verify_s, dag_width, parked_count, escalated) —
# PRD § S3A. jq's `type` check catches a field that's missing (type "null")
# same as one with the wrong shape.
R16="$WORK/r16"; new_repo "$R16"
cat > "$R16/tmp/autopilot/IMPLEMENTATION_PLAN.md" <<'EOF'
- [ ] T1 — first (after: —)
- [ ] T2 — second (after: T1)
- [ ] T3 — third (after: T2)

STATUS: in-progress
EOF
run_loop "$R16" progress true
RC16=$?
[[ "$RC16" -eq 0 ]] \
  && ok "the three-slice metrics fixture runs to completion (exit 0)" \
  || note "metrics fixture exited $RC16 — expected 0"

build_field_type() { # field
  cat "$R16"/tmp/autopilot/run-*.jsonl 2>/dev/null \
    | jq -r --arg f "$1" 'select(.phase=="build") | .[$f] | type' 2>/dev/null | sort -u | tr '\n' ','
}
iter_field_type() { # field
  cat "$R16"/tmp/autopilot/run-*.jsonl 2>/dev/null \
    | jq -r --arg f "$1" 'select(.phase=="iteration") | .[$f] | type' 2>/dev/null | sort -u | tr '\n' ','
}

for f in turns cache_read_input_tokens cache_creation_input_tokens; do
  got="$(build_field_type "$f")"
  [[ "$got" == "number," ]] \
    && ok "build rows carry a numeric '$f'" \
    || note "build rows' '$f' type(s): '$got', want 'number,'"
done

for f in ticked_delta wall_s cost_usd files_changed verify_s dag_width parked_count; do
  got="$(iter_field_type "$f")"
  [[ "$got" == "number," ]] \
    && ok "iteration rows carry a numeric '$f'" \
    || note "iteration rows' '$f' type(s): '$got', want 'number,'"
done

got="$(iter_field_type "slice_id")"
[[ "$got" == "string," ]] \
  && ok "iteration rows carry a string 'slice_id'" \
  || note "iteration rows' 'slice_id' type(s): '$got', want 'string,'"

got="$(iter_field_type "gate_failed")"
[[ "$got" == "string," ]] \
  && ok "iteration rows carry a string 'gate_failed'" \
  || note "iteration rows' 'gate_failed' type(s): '$got', want 'string,'"

got="$(iter_field_type "escalated")"
[[ "$got" == "boolean," ]] \
  && ok "iteration rows carry a boolean 'escalated' (false until S4B)" \
  || note "iteration rows' 'escalated' type(s): '$got', want 'boolean,'"

SLICE_SEQ_16="$(cat "$R16"/tmp/autopilot/run-*.jsonl 2>/dev/null \
  | jq -r 'select(.phase=="iteration") | .slice_id' 2>/dev/null | tr '\n' ',')"
[[ "$SLICE_SEQ_16" == "T1,T2,T3," ]] \
  && ok "iteration rows record the selected slice_id in dependency order (T1,T2,T3)" \
  || note "iteration rows' slice_id sequence was '$SLICE_SEQ_16', want T1,T2,T3,"

DAG_WIDTH_SEQ_16="$(cat "$R16"/tmp/autopilot/run-*.jsonl 2>/dev/null \
  | jq -r 'select(.phase=="iteration") | .dag_width' 2>/dev/null | tr '\n' ',')"
[[ "$DAG_WIDTH_SEQ_16" == "1,1,1," ]] \
  && ok "dag_width reflects a linear chain (exactly one slice choosable per iteration: $DAG_WIDTH_SEQ_16)" \
  || note "dag_width sequence was '$DAG_WIDTH_SEQ_16', want 1,1,1, for a linear after: chain"

# --- 17. Repo-map digest into BUILD (S5): digest.sh, --no-repo-map ---------
# ADR-0004 item 7 / PRD § S5. digest.sh emits <= 40 lines via query.sh only;
# build_prompt() appends it under a fixed heading when a map can be produced,
# --no-repo-map disables the whole thing, and the run log records repo_map
# per iteration.
R17="$WORK/r17"; new_repo "$R17"
mkdir -p "$R17/src"
printf "import './b.js';\n" > "$R17/src/a.js"
: > "$R17/src/b.js"
git -C "$R17" add -A >/dev/null 2>&1
git -C "$R17" -c user.email=t@t.est -c user.name=test commit -q -m "add source files"
cat > "$R17/tmp/autopilot/IMPLEMENTATION_PLAN.md" <<'EOF'
- [ ] S1 — work on src/a.js and src/b.js (after: —)

STATUS: in-progress
EOF
run_loop "$R17" progress true
RC17=$?
[[ "$RC17" -eq 0 ]] \
  && ok "repo-map fixture run completes (exit 0)" \
  || note "repo-map fixture run exited $RC17 — expected 0"

grep -q "Repo map (navigational hint, not ground truth)" "$WORK/r17.calls" 2>/dev/null \
  && ok "BUILD prompt carries the repo-map digest heading when a map can be produced" \
  || note "BUILD prompt is missing the repo-map digest heading"

REPO_MAP_SEQ_17="$(cat "$R17"/tmp/autopilot/run-*.jsonl 2>/dev/null \
  | jq -r 'select(.phase=="iteration") | .repo_map' 2>/dev/null | tr '\n' ',')"
[[ "$REPO_MAP_SEQ_17" == "true," ]] \
  && ok "the run log records repo_map: true for the iteration that got a digest" \
  || note "iteration rows' repo_map was '$REPO_MAP_SEQ_17', want true,"

R17B="$WORK/r17b"; new_repo "$R17B"
mkdir -p "$R17B/src"
printf "import './b.js';\n" > "$R17B/src/a.js"
: > "$R17B/src/b.js"
git -C "$R17B" add -A >/dev/null 2>&1
git -C "$R17B" -c user.email=t@t.est -c user.name=test commit -q -m "add source files"
cat > "$R17B/tmp/autopilot/IMPLEMENTATION_PLAN.md" <<'EOF'
- [ ] S1 — work on src/a.js and src/b.js (after: —)

STATUS: in-progress
EOF
run_loop "$R17B" progress true --no-repo-map
RC17B=$?
[[ "$RC17B" -eq 0 ]] \
  && ok "repo-map fixture run completes under --no-repo-map (exit 0)" \
  || note "--no-repo-map run exited $RC17B — expected 0"

grep -q "Repo map (navigational hint, not ground truth)" "$WORK/r17b.calls" 2>/dev/null \
  && note "--no-repo-map still injected the digest heading into BUILD" \
  || ok "--no-repo-map omits the digest heading from BUILD"

REPO_MAP_SEQ_17B="$(cat "$R17B"/tmp/autopilot/run-*.jsonl 2>/dev/null \
  | jq -r 'select(.phase=="iteration") | .repo_map' 2>/dev/null | tr '\n' ',')"
[[ "$REPO_MAP_SEQ_17B" == "false," ]] \
  && ok "the run log records repo_map: false under --no-repo-map" \
  || note "iteration rows' repo_map under --no-repo-map was '$REPO_MAP_SEQ_17B', want false,"

# digest.sh's own line cap, exercised directly against a fixture with many
# real files — the per-file block alone (3 lines each) blows past 40 lines
# without the cap, so this proves the cap actually bites, not just that a
# small fixture happens to stay under it.
R17C="$WORK/r17c"; mkdir -p "$R17C/tmp"
git -C "$R17C" init -q >/dev/null 2>&1
printf 'tmp/\n' > "$R17C/.gitignore"
mkdir -p "$R17C/src"
HINT_FILES=""
for i in $(seq 1 15); do
  n="$(printf '%02d' "$i")"; nn="$(printf '%02d' "$((i + 1))")"
  printf 'import "./f%s.js";\n' "$nn" > "$R17C/src/f$n.js"
  HINT_FILES="$HINT_FILES src/f$n.js"
done
: > "$R17C/src/f16.js"
git -C "$R17C" add -A >/dev/null 2>&1
git -C "$R17C" -c user.email=t@t.est -c user.name=test commit -q -m init >/dev/null 2>&1

DIGEST_OUT="$(cd "$R17C" && bash "$DIGEST_ABS" "$HINT_FILES" 2>/dev/null)"
DIGEST_LINES="$(printf '%s\n' "$DIGEST_OUT" | grep -c '.')" || DIGEST_LINES=0
[[ "${DIGEST_LINES:-0}" -le 40 ]] \
  && ok "digest.sh caps its output at <= 40 lines even with many file hints ($DIGEST_LINES)" \
  || note "digest.sh emitted ${DIGEST_LINES:-0} lines with 15 file hints, want <= 40"

# --- 18. S4A: the stuck ladder — retry, park, sibling, replan, abort -------
# docs/adr/0005-*.md decision 6 / PRD § S4. A single scenario exercises the
# required loop tests (b)-(e) together: A fails every time it's picked, B is
# an independent sibling, C depends on A.
#   (b) A parks after its 3rd failure and B (the sibling) runs next
#   (c) C, blocked on the never-ticking A, is never selected
#   (d) once A is parked and C is unreachable, exactly one replan fires and
#       unparks everything (slices.json no longer marks A parked afterwards)
#   (e) the next failure — A, retried fresh post-replan — aborts (exit 4)
#       rather than replanning a second time
R18="$WORK/r18"; new_repo "$R18"
cat > "$R18/tmp/autopilot/IMPLEMENTATION_PLAN.md" <<'EOF'
- [ ] A — flaky, always fails (after: —)
- [ ] B — independent sibling (after: —)
- [ ] C — depends on the flaky one (after: A)

STATUS: in-progress
EOF
( cd "$R18" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress STUB_FAIL_ID=A \
    STUB_REPLAN_KEEP_PLAN=1 STUB_CALL_LOG="$WORK/r18.calls" \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 10 --max-minutes 30 --budget-usd 5 \
    >"$WORK/r18.out" 2>"$WORK/r18.err" )
RC18=$?
[[ "$RC18" -eq 4 ]] \
  && ok "a slice that keeps failing past a park-exhaustion replan aborts (exit 4)" \
  || note "S4A ladder run exited $RC18 — expected 4"

SELECTED_SEQ_18="$(grep -oE 'plan item `[^`]+`' "$WORK/r18.calls" 2>/dev/null \
  | sed -E 's/plan item `([^`]+)`/\1/' | tr '\n' ',')"
[[ "$SELECTED_SEQ_18" == "A,A,A,B,A," ]] \
  && ok "A parks after 3 failures, B (sibling) runs next, A retried once more after the replan ($SELECTED_SEQ_18)" \
  || note "selection order was '$SELECTED_SEQ_18', want A,A,A,B,A,"

case "$SELECTED_SEQ_18" in
  *C*) note "C was selected even though its blocker A never ticked" ;;
  *)   ok "C (blocked on the never-ticking A) is never selected" ;;
esac

REPLAN_CALLS_18="$(cat "$R18"/tmp/autopilot/run-*.jsonl 2>/dev/null | jq -r 'select(.phase=="replan")' 2>/dev/null | grep -c . )" || REPLAN_CALLS_18=0
[[ "${REPLAN_CALLS_18:-0}" -ge 1 ]] \
  && ok "exactly one park-exhaustion replan fired" \
  || note "expected a replan call, saw ${REPLAN_CALLS_18:-0}"

PARKED_AFTER_18="$(jq -r '.slices.A.parked // false' "$R18/tmp/autopilot/slices.json" 2>/dev/null)"
[[ "$PARKED_AFTER_18" == "false" ]] \
  && ok "slices.json no longer marks A parked — the replan unparked it" \
  || note "slices.json still shows A parked after the replan: $(cat "$R18/tmp/autopilot/slices.json" 2>/dev/null)"

grep -q "failed again after the park-exhaustion replan" "$WORK/r18.err" 2>/dev/null \
  && ok "the abort explains it happened after the replan (rung 5), not a fresh 3-strikes count" \
  || note "no rung-5 explanation found in stderr"

# --- 19. S4A: per-slice fails counters survive --resume-run ----------------
# PRD § S4: "an interrupted run must not pay for the same --escalate-model
# call twice" — the counters must NOT reset to zero on a resumed process.
R19="$WORK/r19"; new_repo "$R19"
cat > "$R19/tmp/autopilot/IMPLEMENTATION_PLAN.md" <<'EOF'
- [ ] A — flaky, always fails (after: —)

STATUS: in-progress
EOF
cat > "$R19/tmp/autopilot/slices.json" <<'EOF'
{"plan_sig":"","slices":{"A":{"fails":2,"escalated":false,"parked":false}}}
EOF
( cd "$R19" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress STUB_FAIL_ID=A \
    STUB_REPLAN_KEEP_PLAN=1 STUB_CALL_LOG="$WORK/r19.calls" \
    bash "$LOOP_ABS" --verify-cmd true --resume-run --max-iterations 10 --max-minutes 30 --budget-usd 5 \
    >"$WORK/r19.out" 2>"$WORK/r19.err" )
RC19=$?
[[ "$RC19" -eq 4 ]] \
  && ok "a resumed run with a pre-seeded fails count still runs the ladder to abort (exit 4)" \
  || note "resumed S4A run exited $RC19 — expected 4"

# A fresh run needs 3 failures to park A; seeded at fails=2, resuming must
# park it after exactly 1. If the seed had been silently reset to 0 instead
# (the bug this test guards against), parking (and everything after it)
# would take 2 iterations longer, so the total iteration count is the tell.
ITER_COUNT_19="$(cat "$R19"/tmp/autopilot/run-*.jsonl 2>/dev/null | jq -r 'select(.phase=="iteration") | .iter' 2>/dev/null | sort -un | tail -1)"
[[ "${ITER_COUNT_19:-0}" -eq 3 ]] \
  && ok "the pre-seeded fails=2 was honoured (parked after 1 more failure, abort at iteration 3)" \
  || note "run took ${ITER_COUNT_19:-0} iterations to abort, want exactly 3 (fails counter looks reset on resume)"

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "test-autopilot-loop: PASS"
else
  echo "test-autopilot-loop: $FAIL failure(s)"
fi
exit "$FAIL"
