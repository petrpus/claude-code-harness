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

# Forge-credential withholding (ADR-0007) sets GH_CONFIG_DIR and appends to
# GIT_CONFIG_COUNT for everything it runs — the verify command included, so
# these tests inherit both when autopilot or /deliver verifies this repo. The
# fixtures bring their own forge (a fake gh, bare remotes) and must not see
# the caller's: an inherited empty GH_CONFIG_DIR makes the fake gh report
# "not logged in" (first live run, #83).
unset GH_CONFIG_DIR GIT_CONFIG_COUNT

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

# S3B: usage-report/report.sh, exercised directly against combined run logs.
REPORT="skills/usage-report/report.sh"
[[ -f "$REPORT" ]] || { note "$REPORT is missing"; echo; echo "test-autopilot-loop: $FAIL failure(s)"; exit 1; }
REPORT_ABS="$(cd "$(dirname "$REPORT")" && pwd)/$(basename "$REPORT")"

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
[[ -n "${STUB_SLEEP:-}" ]] && sleep "$STUB_SLEEP"
prompt="$*"
# The plan path comes from the prompt, not a hardcoded tmp/autopilot/: every
# phase that touches the plan names it (loop.sh interpolates $PLAN_FILE), and
# --state-dir moves it. Fallback keeps any prompt that doesn't name it working.
plan="$(printf '%s' "$prompt" | grep -oE '[^[:space:],"]*IMPLEMENTATION_PLAN\.md' | head -1)"
plan="${plan:-tmp/autopilot/IMPLEMENTATION_PLAN.md}"
# S4B: a call's own `--model <name>` token is right there in `$*` (loop.sh
# passes it as a separate argv word, and prompt="$*" joins everything with
# spaces) — cheap enough to grep for rather than threading a new stub arg
# through every call site. STUB_ESCALATE_COST lets one test give only the
# escalated call an elevated cost, to exercise the 25%-of-remaining-budget
# warning without inflating every other call's cost too.
emit() { # result
  local cost="${STUB_COST_PER_CALL:-0}"
  if [[ -n "${STUB_ESCALATE_COST:-}" ]] \
     && printf '%s' "$prompt" | grep -q -- "--model ${STUB_ESCALATE_MODEL_NAME:-opus}"; then
    cost="$STUB_ESCALATE_COST"
  fi
  printf '{"result":%s,"total_cost_usd":%s,"usage":{"input_tokens":0,"output_tokens":0}}\n' "$1" "$cost"
}

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
    # #96: a BUILD that runs out of --max-turns — claude -p exits 1 with an
    # error_max_turns reply, having done part of the work and ticked nothing.
    if [[ -n "${STUB_BUILD_MAX_TURNS:-}" ]]; then
      mkdir -p src && echo "half done" >> src/partial.txt
      printf '{"type":"result","subtype":"error_max_turns","num_turns":81,"total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0}}\n'
      exit 1
    fi
    # --stop-file: simulate a caller requesting a stop while BUILD is busy.
    # The runner must finish this iteration and stop at the next boundary.
    [[ -n "${STUB_TOUCH_AFTER_BUILD:-}" ]] && touch "$STUB_TOUCH_AFTER_BUILD"
    # S2 (holdout scenarios): if this run is checking that holdout content
    # never reaches BUILD, flag it — the outer test asserts the file this
    # writes to stays empty.
    if [[ -n "${STUB_HOLDOUT_SENTINEL:-}" ]] \
       && printf '%s' "$prompt" | grep -qF "$STUB_HOLDOUT_SENTINEL"; then
      printf 'LEAK: holdout sentinel reached the BUILD prompt\n' >> "${STUB_LEAK_FILE:-/dev/null}"
    fi
    # S1 (issue #54): simulate a BUILD that leaves a secret behind — either by
    # committing it itself (pre-fix, when the allowlist still granted git
    # add/commit) or by leaving it in a new untracked file, which a
    # `git diff HEAD` never sees at all. Both must be caught now that
    # secret_scan() reads `git diff --cached $ITER_BASE_SHA` over the
    # runner's own `git add -A`.
    if [[ "${STUB_SECRET_MODE:-}" == "commit" ]]; then
      printf 'token = "AKIAABCDEFGHIJKLMNOP"\n' > secret.txt
      git add secret.txt >/dev/null 2>&1
      git commit -q -m "build: oops" >/dev/null 2>&1
    elif [[ "${STUB_SECRET_MODE:-}" == "lockindex" ]]; then
      # A held index lock: the runner's own `git add -A` after BUILD fails.
      printf 'work\n' > locked-work.txt
      : > "$(git rev-parse --git-dir)/index.lock"
    elif [[ "${STUB_SECRET_MODE:-}" == "untracked" ]]; then
      printf 'token = "AKIAABCDEFGHIJKLMNOP"\n' > secret_untracked.txt
    elif [[ "${STUB_SECRET_MODE:-}" == "nearby" ]]; then
      # Regression (#54 dogfooding): a secret-looking line already at
      # ITER_BASE_SHA, untouched by this iteration, must not fail the gate
      # just because an edit lands within the diff's context window (git's
      # default 3 lines) of it — `git diff`'s unified context reprints
      # unchanged lines around a real change, and a scan over the raw diff
      # text (rather than only its +/- lines) can't tell "shown as context"
      # from "added".
      sed -i 's/^unrelated line$/unrelated line, edited by BUILD/' config.txt
    elif [[ "${STUB_SECRET_MODE:-}" == "removed" ]]; then
      # #94: BUILD deletes an already-committed secret-looking line (a `-`
      # line in the diff) and edits next to it — it added nothing.
      sed -i -e '/AKIA/d' -e 's/^unrelated line$/unrelated line, edited by BUILD/' config.txt
    fi
    # S2 (issue #54): simulate a BUILD that commits a (non-secret) change
    # itself, moving HEAD before the runner's own `git add -A`/checkpoint —
    # the verifier's prompt must still diff the whole iteration against
    # ITER_BASE_SHA (recorded before this call ran), not HEAD, or a
    # same-iteration BUILD commit would make the change invisible to it.
    if [[ -n "${STUB_BUILD_SELF_COMMIT_FILE:-}" ]]; then
      printf 'build committed this itself\n' > "$STUB_BUILD_SELF_COMMIT_FILE"
      git add "$STUB_BUILD_SELF_COMMIT_FILE" >/dev/null 2>&1
      git commit -q -m "build: self-commit" >/dev/null 2>&1
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
      # S4B: STUB_ESCALATE_ID names an id that fails on whatever model it's
      # FIRST tried on and only ticks once the prompt shows the escalate
      # model was actually used (`--model <name>` in $*) — simulates a slice
      # genuinely rescued by a stronger model rather than one that just
      # happens to succeed on a later attempt regardless of model.
      if [[ -n "${STUB_ESCALATE_ID:-}" && "$sel_id" == "$STUB_ESCALATE_ID" ]] \
         && ! printf '%s' "$prompt" | grep -q -- "--model ${STUB_ESCALATE_MODEL_NAME:-opus}"; then
        :
      elif [[ -n "${STUB_FAIL_ID:-}" && "$sel_id" == "$STUB_FAIL_ID" ]]; then
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
    # S2 (issue #54): the stub verifier plays along with the prompt's own
    # instructions — it extracts the `git diff --cached <sha>` command the
    # prompt tells it to run and actually runs it (read-only, same as the
    # real verifier's allowlist), so the outer test can assert on what a
    # verifier obeying the prompt would actually have seen, not just on the
    # prompt text containing a SHA.
    if [[ -n "${STUB_VERIFY_DIFF_LOG:-}" ]]; then
      diff_cmd_seen="$(printf '%s' "$prompt" | grep -oE 'git diff --cached [0-9a-f]{7,40}' | head -1)"
      if [[ -n "$diff_cmd_seen" ]]; then
        $diff_cmd_seen > "$STUB_VERIFY_DIFF_LOG" 2>&1
      else
        : > "$STUB_VERIFY_DIFF_LOG"
      fi
    fi
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
  # Identity in the REPO config, not just -c on setup commits: the checkpoint
  # commits under test are made by loop.sh itself, whose plain `git commit`
  # has no identity on a fresh CI runner and is swallowed by `|| true` —
  # locally the global gitconfig masked this (caught by the first Actions run).
  git -C "$1" config user.email t@t.est
  git -C "$1" config user.name test
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

ls "$R8"/tmp/autopilot/calls/*-verify_agent.md >/dev/null 2>&1 \
  && note "a holdout-aware verifier reply was kept in calls/, where BUILD can read it (ADR-0006)" \
  || ok "with a holdout, the verifier's replies are not kept in calls/ (ADR-0006)"
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
# Every file loop.sh sources must be in the copy: a missing one is sourced
# with an error the runner does not stop on, and its functions then fail
# silently — slices.sh was missing here until #55, so tests 10-11 ran the
# ladder as no-ops.
cp "$LOOP_SRC_DIR/slices.sh" "$PLUGIN_COPY/skills/autopilot/slices.sh"
cp "$LOOP_SRC_DIR/agent.sh" "$PLUGIN_COPY/skills/autopilot/agent.sh"
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
# S2: --resume-run now also restores the time cap's start time from this
# log's earliest ts (see case 12c below) — a fixed past date here would trip
# a spurious time cap under --max-minutes 30 and has nothing to do with what
# THIS case tests (cost/iter adoption), so its rows are timestamped "now".
NOW_TS_12="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$R12/tmp/autopilot/run-$PRIOR_RUN_ID.jsonl" <<EOF
{"ts":"$NOW_TS_12","run_id":"$PRIOR_RUN_ID","iter":1,"phase":"build","model":"sonnet","duration_s":1,"cost_usd":1.25,"input_tokens":0,"output_tokens":0,"exit_code":0,"verdict":"","holdout_failed":0}
{"ts":"$NOW_TS_12","run_id":"$PRIOR_RUN_ID","iter":1,"phase":"iteration","model":"-","duration_s":0,"cost_usd":0,"input_tokens":0,"output_tokens":0,"exit_code":0,"verdict":"wip","holdout_failed":0}
{"ts":"$NOW_TS_12","run_id":"$PRIOR_RUN_ID","iter":2,"phase":"build","model":"sonnet","duration_s":1,"cost_usd":0.75,"input_tokens":0,"output_tokens":0,"exit_code":0,"verdict":"","holdout_failed":0}
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

# --- 12b. --resume-run excludes a phase:"iteration" row's own cost_usd from --
# the resumed total, even when that row is non-zero, so a per-iteration ------
# summary cost is never double-counted on top of the per-call rows it summarizes
R12B="$WORK/r12b"; new_repo "$R12B"
cat > "$R12B/tmp/autopilot/IMPLEMENTATION_PLAN.md" <<'EOF'
- [ ] slice 1
- [ ] slice 2

STATUS: in-progress
EOF
PRIOR_RUN_ID_12B="20260101T000000Z-999998"
# S2: see the NOW_TS_12 note above — same reasoning, this case tests cost
# summation, not the time cap.
NOW_TS_12B="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$R12B/tmp/autopilot/run-$PRIOR_RUN_ID_12B.jsonl" <<EOF
{"ts":"$NOW_TS_12B","run_id":"$PRIOR_RUN_ID_12B","iter":1,"phase":"build","model":"sonnet","duration_s":1,"cost_usd":1.25,"input_tokens":0,"output_tokens":0,"exit_code":0,"verdict":"","holdout_failed":0}
{"ts":"$NOW_TS_12B","run_id":"$PRIOR_RUN_ID_12B","iter":2,"phase":"build","model":"sonnet","duration_s":1,"cost_usd":0.75,"input_tokens":0,"output_tokens":0,"exit_code":0,"verdict":"","holdout_failed":0}
{"ts":"$NOW_TS_12B","run_id":"$PRIOR_RUN_ID_12B","iter":2,"phase":"iteration","model":"-","duration_s":0,"cost_usd":2.00,"input_tokens":0,"output_tokens":0,"exit_code":0,"verdict":"wip","holdout_failed":0}
EOF
( cd "$R12B" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 2 --max-minutes 30 --budget-usd 999 --resume-run \
    >"$WORK/r12b.out" 2>"$WORK/r12b.err" )
RC12B=$?
[[ "$RC12B" -eq 2 ]] \
  && ok "--resume-run (non-zero iteration-row cost) adopts the prior iteration count (hits the iteration cap immediately)" \
  || note "--resume-run (non-zero iteration-row cost) exited $RC12B — expected 2 (iteration cap)"

RESUMED_COST_12B="$(jq -r '.total_cost_usd // -1' "$R12B/tmp/autopilot/status.json" 2>/dev/null)"
COST_IS_TWO_12B="$(jq -n --argjson v "${RESUMED_COST_12B:--1}" '$v == 2' 2>/dev/null)"
[[ "$COST_IS_TWO_12B" == "true" ]] \
  && ok "--resume-run's cost total excludes the phase:\"iteration\" row's \$2 (1.25+0.75=2, not 4)" \
  || note "--resume-run's cost total is '$RESUMED_COST_12B', expected 2 (the iteration row's \$2 must not be added on top)"

# --- 12c. S2: the time cap survives resume — a ~2h-old prior run trips it --
# immediately, before any model call (#78's plausibility check on top of the
# restored value, not just the current clock).
R12C="$WORK/r12c"; new_repo "$R12C"
cat > "$R12C/tmp/autopilot/IMPLEMENTATION_PLAN.md" <<'EOF'
- [ ] slice 1
- [ ] slice 2

STATUS: in-progress
EOF
PRIOR_RUN_ID_12C="20260101T000000Z-999997"
OLD_TS_12C="$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
cat > "$R12C/tmp/autopilot/run-$PRIOR_RUN_ID_12C.jsonl" <<EOF
{"ts":"$OLD_TS_12C","run_id":"$PRIOR_RUN_ID_12C","iter":1,"phase":"build","model":"sonnet","duration_s":1,"cost_usd":0.1,"input_tokens":0,"output_tokens":0,"exit_code":0,"verdict":"","holdout_failed":0}
EOF
( cd "$R12C" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress STUB_CALL_LOG="$WORK/r12c.calls" \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 12 --max-minutes 30 --budget-usd 999 --resume-run \
    >"$WORK/r12c.out" 2>"$WORK/r12c.err" )
RC12C=$?
[[ "$RC12C" -eq 3 ]] \
  && ok "S2: --resume-run restores a ~2h-old start time and hits the time cap (exit 3)" \
  || note "S2: resume from a ~2h-old log exited $RC12C — expected 3 (time cap)"

STATE_12C="$(jq -r '.state // ""' "$R12C/tmp/autopilot/status.json" 2>/dev/null)"
[[ "$STATE_12C" == "time-cap" ]] \
  && ok "S2: status.json reports state 'time-cap' for the restored-start resume" \
  || note "S2: status.json state is '$STATE_12C', expected 'time-cap'"

[[ ! -s "$WORK/r12c.calls" ]] \
  && ok "S2: the restored time cap trips before any model call" \
  || note "S2: expected no model calls before the time cap, got: $(cat "$WORK/r12c.calls" 2>/dev/null)"

# --- 12d. S2: a prior run started seconds ago resumes with no time cap -----
R12D="$WORK/r12d"; new_repo "$R12D"
cat > "$R12D/tmp/autopilot/IMPLEMENTATION_PLAN.md" <<'EOF'
- [ ] slice 1
- [ ] slice 2

STATUS: in-progress
EOF
PRIOR_RUN_ID_12D="20260101T000000Z-999996"
RECENT_TS_12D="$(date -u -d '-5 seconds' +%Y-%m-%dT%H:%M:%SZ)"
cat > "$R12D/tmp/autopilot/run-$PRIOR_RUN_ID_12D.jsonl" <<EOF
{"ts":"$RECENT_TS_12D","run_id":"$PRIOR_RUN_ID_12D","iter":1,"phase":"build","model":"sonnet","duration_s":1,"cost_usd":0.1,"input_tokens":0,"output_tokens":0,"exit_code":0,"verdict":"","holdout_failed":0}
EOF
( cd "$R12D" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 2 --max-minutes 30 --budget-usd 999 --resume-run \
    >"$WORK/r12d.out" 2>"$WORK/r12d.err" )
RC12D=$?
[[ "$RC12D" -eq 2 ]] \
  && ok "S2: --resume-run with a seconds-old prior start runs normally (iteration cap, not time cap)" \
  || note "S2: resume from a seconds-old log exited $RC12D — expected 2 (iteration cap)"

STATE_12D="$(jq -r '.state // ""' "$R12D/tmp/autopilot/status.json" 2>/dev/null)"
[[ "$STATE_12D" == "iteration-cap" ]] \
  && ok "S2: status.json reports 'iteration-cap', not a spurious time cap" \
  || note "S2: status.json state is '$STATE_12D', expected 'iteration-cap'"

# --- 12e. S2: an unparseable prior ts falls back to the current clock, -----
# never reports a time cap.
R12E="$WORK/r12e"; new_repo "$R12E"
cat > "$R12E/tmp/autopilot/IMPLEMENTATION_PLAN.md" <<'EOF'
- [ ] slice 1
- [ ] slice 2

STATUS: in-progress
EOF
PRIOR_RUN_ID_12E="20260101T000000Z-999995"
cat > "$R12E/tmp/autopilot/run-$PRIOR_RUN_ID_12E.jsonl" <<EOF
{"ts":"not-a-timestamp","run_id":"$PRIOR_RUN_ID_12E","iter":1,"phase":"build","model":"sonnet","duration_s":1,"cost_usd":0.1,"input_tokens":0,"output_tokens":0,"exit_code":0,"verdict":"","holdout_failed":0}
EOF
( cd "$R12E" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 2 --max-minutes 30 --budget-usd 999 --resume-run \
    >"$WORK/r12e.out" 2>"$WORK/r12e.err" )
RC12E=$?
[[ "$RC12E" -eq 2 ]] \
  && ok "S2: an unparseable prior ts falls back to the current clock (iteration cap, not time cap)" \
  || note "S2: resume from an unparseable-ts log exited $RC12E — expected 2 (iteration cap)"

grep -q "restored start time" "$WORK/r12e.err" 2>/dev/null \
  && ok "S2: the unparseable restored start time is logged, not silently swallowed" \
  || note "S2: no fallback notice found in stderr for the unparseable ts"

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
  && ok "iteration rows carry a boolean 'escalated' (false here — this fixture never fails, so nothing escalates; see test 20 for a true case)" \
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

# --- 20. S4B: two failed BUILDs then an escalated third that passes --------
# (a) from the plan's own loop-test list. A gets flaky-then-rescued: it fails
# on --build-model (default sonnet — the escalate threshold is fails>=2, so
# the first two attempts run un-escalated) and only ticks once rung 2 hands
# it --escalate-model (default opus). STUB_ESCALATE_COST makes just that
# third call expensive enough to trip the 25%-of-remaining-budget warning
# too, so this one fixture covers both halves of S4B without a second run.
R20="$WORK/r20"; new_repo "$R20"
cat > "$R20/tmp/autopilot/IMPLEMENTATION_PLAN.md" <<'EOF'
- [ ] A — flaky twice, rescued by escalation (after: —)

STATUS: in-progress
EOF
( cd "$R20" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress STUB_ESCALATE_ID=A \
    STUB_ESCALATE_COST=3 STUB_CALL_LOG="$WORK/r20.calls" \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 10 --max-minutes 30 --budget-usd 5 \
    >"$WORK/r20.out" 2>"$WORK/r20.err" )
RC20=$?
[[ "$RC20" -eq 0 ]] \
  && ok "a slice rescued by escalation on its 3rd attempt completes the run (exit 0)" \
  || note "escalation-rescue run exited $RC20 — expected 0"

BUILD_MODEL_SEQ_20="$(cat "$R20"/tmp/autopilot/run-*.jsonl 2>/dev/null \
  | jq -r 'select(.phase=="build") | .model' 2>/dev/null | tr '\n' ',')"
[[ "$BUILD_MODEL_SEQ_20" == "sonnet,sonnet,opus," ]] \
  && ok "BUILD escalates to opus only on the 3rd attempt (fails 0,1 stay on --build-model): $BUILD_MODEL_SEQ_20" \
  || note "BUILD model sequence was '$BUILD_MODEL_SEQ_20', want sonnet,sonnet,opus,"

ESCALATED_SEQ_20="$(cat "$R20"/tmp/autopilot/run-*.jsonl 2>/dev/null \
  | jq -r 'select(.phase=="iteration") | .escalated' 2>/dev/null | tr '\n' ',')"
[[ "$ESCALATED_SEQ_20" == "false,false,true," ]] \
  && ok "the run log marks exactly one escalated iteration (the rescuing one): $ESCALATED_SEQ_20" \
  || note "iteration rows' escalated sequence was '$ESCALATED_SEQ_20', want false,false,true,"

REPLAN_CALLS_20="$(cat "$R20"/tmp/autopilot/run-*.jsonl 2>/dev/null | jq -r 'select(.phase=="replan")' 2>/dev/null | grep -c .)" || REPLAN_CALLS_20=0
[[ "${REPLAN_CALLS_20:-0}" -eq 0 ]] \
  && ok "escalation rescued the slice before the ladder ever reached a replan" \
  || note "expected no replan calls, saw ${REPLAN_CALLS_20:-0}"

grep -q "exceeds 25%" "$WORK/r20.err" 2>/dev/null \
  && ok "an escalated call costing more than 25% of the remaining budget is warned about" \
  || note "no 25%-of-remaining-budget warning found for the \$3 escalated call against a \$5 budget"

# --- 21. S4B: --escalate-model none + an unannotated plan reproduces the ---
# rung sequence exactly (f) from the plan's own loop-test list. Same
# five-"slice"-line unannotated fixture and STUB_MODE=stall as test 2 (every
# line's id is the plan-local token "slice", shared across all five rows,
# same as any real 0.4.0-era plan with no id/after: annotations) — the only
# difference from test 2 is passing --escalate-model none explicitly. In
# STUB_MODE=stall the BUILD stub never ticks regardless of which model it was
# asked for, so escalation (on or off) cannot change the outcome; this proves
# the flag being present-but-disabled perturbs neither the exit code, the
# timing, nor the ladder's own fingerprint/replan/abort sequence.
R21="$WORK/r21"; new_repo "$R21"
run_loop "$R21" stall true --escalate-model none
RC21=$?
[[ "$RC21" -eq "$RC2" ]] \
  && ok "--escalate-model none on an unannotated plan aborts exactly like the default (exit $RC21)" \
  || note "--escalate-model none exited $RC21, plain run (test 2) exited $RC2 — should match"

grep -q "no-progress" "$WORK/r21.err" 2>/dev/null \
  && ok "--escalate-model none still fingerprints the stall as no-progress, not escalation-related" \
  || note "stall under --escalate-model none was not fingerprinted as no-progress"

ITER_COUNT_21="$(cat "$R21"/tmp/autopilot/run-*.jsonl 2>/dev/null | jq -r 'select(.phase=="iteration") | .iter' 2>/dev/null | sort -un | tail -1)"
ITER_COUNT_2="$(cat "$R2"/tmp/autopilot/run-*.jsonl 2>/dev/null | jq -r 'select(.phase=="iteration") | .iter' 2>/dev/null | sort -un | tail -1)"
[[ "${ITER_COUNT_21:-0}" -eq "${ITER_COUNT_2:-0}" ]] \
  && ok "--escalate-model none takes exactly as many iterations to abort as the default ($ITER_COUNT_21)" \
  || note "--escalate-model none took ${ITER_COUNT_21:-0} iterations, default took ${ITER_COUNT_2:-0} — should match"

ESCALATED_SEQ_21="$(cat "$R21"/tmp/autopilot/run-*.jsonl 2>/dev/null \
  | jq -r 'select(.phase=="iteration") | .escalated' 2>/dev/null | tr '\n' ',')"
case "$ESCALATED_SEQ_21" in
  *true*) note "escalated:true appeared even though --escalate-model none disables escalation ($ESCALATED_SEQ_21)" ;;
  *)      ok "escalated stays false throughout with --escalate-model none" ;;
esac

# --- 22. S3B: per-run aggregates land in status.json -----------------------
# PRD § S3B: status.json gains iterations, gate_fail_rate, cost_per_ticked_slice,
# replans, mean_dag_width, parked_total, escalations. R20 (escalation-rescue,
# reused from test 20 above — its own run is not repeated here) is a clean
# fixture for the base-case numbers: 3 iterations (2 no-progress failures then
# a ticking success), exactly one escalated call costing $3 against an
# otherwise-free run, a single-slice plan (dag_width 1 throughout), no parks,
# no replans.
STATUS_22="$R20/tmp/autopilot/status.json"
[[ -f "$STATUS_22" ]] \
  && ok "status.json exists after the R20 run" \
  || note "status.json is missing at $STATUS_22"

field_22() { jq -r --arg f "$1" '.[$f]' "$STATUS_22" 2>/dev/null; }

[[ "$(field_22 iterations)" == "3" ]] \
  && ok "status.json .iterations == 3" \
  || note "status.json .iterations == '$(field_22 iterations)', want 3"

GFR_22="$(field_22 gate_fail_rate)"
jq -en --argjson g "${GFR_22:-null}" '$g != null and (($g - (2/3)) | fabs) < 0.001' >/dev/null 2>&1 \
  && ok "status.json .gate_fail_rate ≈ 2/3 (2 of 3 iterations failed a gate): $GFR_22" \
  || note "status.json .gate_fail_rate == '$GFR_22', want ≈ 0.6667"

[[ "$(field_22 cost_per_ticked_slice)" == "3" ]] \
  && ok "status.json .cost_per_ticked_slice == 3 (\$3 total / 1 slice ticked)" \
  || note "status.json .cost_per_ticked_slice == '$(field_22 cost_per_ticked_slice)', want 3"

[[ "$(field_22 replans)" == "0" ]] \
  && ok "status.json .replans == 0 (escalation rescued the slice before any replan)" \
  || note "status.json .replans == '$(field_22 replans)', want 0"

[[ "$(field_22 mean_dag_width)" == "1" ]] \
  && ok "status.json .mean_dag_width == 1 (a single-slice plan is width 1 throughout)" \
  || note "status.json .mean_dag_width == '$(field_22 mean_dag_width)', want 1"

[[ "$(field_22 parked_total)" == "0" ]] \
  && ok "status.json .parked_total == 0 (the slice never reached 3 fails — it was rescued at 2)" \
  || note "status.json .parked_total == '$(field_22 parked_total)', want 0"

[[ "$(field_22 escalations)" == "1" ]] \
  && ok "status.json .escalations == 1 (exactly the one rescued iteration)" \
  || note "status.json .escalations == '$(field_22 escalations)', want 1"

# R18 (park-exhaustion replan, reused from test 18) proves .replans is wired
# for real rather than hardcoded to 0.
REPLANS_18="$(jq -r '.replans' "$R18/tmp/autopilot/status.json" 2>/dev/null)"
[[ "${REPLANS_18:-0}" -ge 1 ]] \
  && ok "status.json .replans >= 1 on the run that hit a park-exhaustion replan (R18): $REPLANS_18" \
  || note "status.json .replans == '${REPLANS_18:-0}' on R18, want >= 1"

# A run with no prior log (nothing has happened yet) must not error out of
# write_status() — contract item 8, missing state is never a failure.
R22="$WORK/r22"; new_repo "$R22"
( cd "$R22" && PATH="$STUB_DIR:$PATH" STUB_MODE=stall STUB_VERIFY_FAIL=1 \
    STUB_CALL_LOG="$WORK/r22.calls" \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 6 --max-minutes 30 --budget-usd 5 \
    >"$WORK/r22.out" 2>"$WORK/r22.err" )
RC22=$?
[[ "$RC22" -eq 4 ]] \
  && ok "a verifier that always finds shortcut #7 aborts on the fingerprint ladder (exit 4)" \
  || note "the shortcut-#7 fixture exited $RC22 — expected 4"

# --- 23. S3B: /usage-report's report.sh renders across several run logs ----
# PRD § S3: /usage-report gains a "per run" table, a per-shortcut violation
# histogram across runs, and a repo-map on/off comparison — the column empty
# when only one side is present. Combine R17 (repo_map:true), R17B
# (repo_map:false) and R22 (verify_agent violations, shortcut #7) into one
# directory so all three sections have something real to render. R22's
# unannotated plan gives every line the same shared plan-local id ("slice" —
# the first token after the checkbox, same for all five "- [ ] slice N"
# lines), so it runs the per-slice ladder (retry x2, park at fails=3, one
# park-exhaustion replan, abort on the next failure): verify_agent actually
# runs on iterations 1, 2, 3 and 5 (the plan_parked iteration in between
# `continue`s before BUILD/verify ever run) — four violations, not three.
REPORTS_DIR="$WORK/reports"; mkdir -p "$REPORTS_DIR"
cp "$R17"/tmp/autopilot/run-*.jsonl "$REPORTS_DIR"/ 2>/dev/null
cp "$R17B"/tmp/autopilot/run-*.jsonl "$REPORTS_DIR"/ 2>/dev/null
cp "$R22"/tmp/autopilot/run-*.jsonl "$REPORTS_DIR"/ 2>/dev/null

REPORT_OUT="$(bash "$REPORT_ABS" "$REPORTS_DIR" 2>"$WORK/report.err")"
REPORT_RC=$?
[[ "$REPORT_RC" -eq 0 ]] \
  && ok "report.sh exits 0 against a directory of combined run logs" \
  || note "report.sh exited $REPORT_RC: $(cat "$WORK/report.err" 2>/dev/null)"

RUN_ROWS_23="$(printf '%s\n' "$REPORT_OUT" | grep -cE '^\| [0-9]{8}T[0-9]{6}Z-')"
[[ "${RUN_ROWS_23:-0}" -eq 3 ]] \
  && ok "the per-run table has one row per run (3 runs combined)" \
  || note "per-run table had ${RUN_ROWS_23:-0} run rows, want 3"

printf '%s\n' "$REPORT_OUT" | grep -qE '^\| 7 \| 4 \|' \
  && ok "the per-shortcut histogram counts shortcut #7 four times (R22's four verify_agent runs)" \
  || note "per-shortcut histogram is missing '| 7 | 4 |'"

printf '%s\n' "$REPORT_OUT" | grep -q "repo_map=true" \
  && printf '%s\n' "$REPORT_OUT" | grep -q "repo_map=false" \
  && ok "the repo-map comparison header shows both the on and off columns" \
  || note "repo-map comparison is missing an on or off column header"

# Neither side of the comparison row is the placeholder "—" — R17 and R17B
# each contribute exactly one real BUILD call to their side.
COMPARISON_ROW_23="$(printf '%s\n' "$REPORT_OUT" | grep -A2 'repo_map=true' | tail -1)"
case "$COMPARISON_ROW_23" in
  *'—'*) note "repo-map comparison row still shows a placeholder even though both sides have data: $COMPARISON_ROW_23" ;;
  *)     ok "repo-map comparison row has real numbers on both sides: $COMPARISON_ROW_23" ;;
esac

# report.sh must degrade gracefully (not error) against a directory with no
# run logs at all — contract item 8, a fresh repo that never ran autopilot.
EMPTY_DIR_23="$WORK/empty-reports"; mkdir -p "$EMPTY_DIR_23"
bash "$REPORT_ABS" "$EMPTY_DIR_23" >"$WORK/empty-report.out" 2>"$WORK/empty-report.err"
EMPTY_RC_23=$?
[[ "$EMPTY_RC_23" -eq 0 ]] \
  && ok "report.sh exits 0 against a directory with no run logs" \
  || note "report.sh exited $EMPTY_RC_23 against an empty directory — expected 0"

# --- 24. --state-dir: a run lives entirely in the given directory ----------
# /deliver runs one autopilot per issue, each in its own state dir. The whole
# run — charter, plan, logs, status, lock — must follow the flag, and the
# default tmp/autopilot/ must stay untouched.
R24="$WORK/r24"; new_repo "$R24"
mkdir -p "$R24/tmp/deliver/run1/issues/7"
mv "$R24/tmp/autopilot/PROMPT.md" "$R24/tmp/deliver/run1/issues/7/PROMPT.md"
run_loop "$R24" progress true --state-dir tmp/deliver/run1/issues/7
RC24=$?
S24="$R24/tmp/deliver/run1/issues/7"
[[ "$RC24" -eq 0 ]] \
  && ok "--state-dir: a five-slice run completes in a custom state dir (exit 0)" \
  || note "--state-dir run exited $RC24 — expected 0 ($(tail -2 "$WORK/r24.err" 2>/dev/null | tr '\n' ' '))"
[[ -f "$S24/IMPLEMENTATION_PLAN.md" && -f "$S24/status.json" && -f "$S24/MEMORY.md" ]] \
  && ls "$S24"/run-*.jsonl >/dev/null 2>&1 \
  && ok "--state-dir: plan, status, memory and run log all land in the given dir" \
  || note "--state-dir: expected plan/status/memory/run log under $S24"
[[ "$(jq -r '.state' "$S24/status.json" 2>/dev/null)" == "done" ]] \
  && ok "--state-dir: status.json in the given dir reports done" \
  || note "--state-dir: status.json state is '$(jq -r '.state' "$S24/status.json" 2>/dev/null)', expected done"
[[ -z "$(ls -A "$R24/tmp/autopilot" 2>/dev/null)" ]] \
  && ok "--state-dir: the default tmp/autopilot/ is left untouched" \
  || note "--state-dir: files appeared in tmp/autopilot/: $(ls -A "$R24/tmp/autopilot" | tr '\n' ' ')"
[[ ! -f "$S24/lock" ]] \
  && ok "--state-dir: the lock in the given dir is released on exit" \
  || note "--state-dir: lock left behind in $S24"

# Trailing slashes name the same directory, not a different one.
R24B="$WORK/r24b"; new_repo "$R24B"
mkdir -p "$R24B/tmp/other"
mv "$R24B/tmp/autopilot/PROMPT.md" "$R24B/tmp/other/PROMPT.md"
run_loop "$R24B" progress true --state-dir tmp/other//
RC24B=$?
[[ "$RC24B" -eq 0 && -f "$R24B/tmp/other/status.json" ]] \
  && ! grep -q 'tmp/other//' "$WORK/r24b.calls" 2>/dev/null \
  && ok "--state-dir: trailing slashes are stripped (tmp/other// → tmp/other)" \
  || note "--state-dir with trailing slashes exited $RC24B or leaked a doubled slash into prompts"

# --- 25. --state-dir: an un-ignored state dir is refused -------------------
# Checkpoints are `git add -A`; a state dir git tracks would commit the run's
# own charter, logs and lock into the branch.
R25="$WORK/r25"; new_repo "$R25"
mkdir -p "$R25/state"
cp "$R25/tmp/autopilot/PROMPT.md" "$R25/state/PROMPT.md"
git -C "$R25" add state/PROMPT.md >/dev/null 2>&1
git -C "$R25" commit -q -m "add state"
run_loop "$R25" progress true --state-dir state
RC25=$?
[[ "$RC25" -eq 1 ]] && grep -q "not gitignored" "$WORK/r25.err" 2>/dev/null \
  && ok "--state-dir: a state dir git does not ignore is refused (exit 1)" \
  || note "--state-dir: un-ignored state dir exited $RC25 — expected 1 with a 'not gitignored' error"
[[ "$(git -C "$R25" log --oneline | wc -l | tr -d ' ')" -eq 2 ]] \
  && ok "--state-dir: the refused run made no checkpoint commit" \
  || note "--state-dir: the refused run still committed"

# --- 26. --stop-file: a stop requested mid-run ends it at the next boundary -
# The stub touches the stop file during the first BUILD; the runner must let
# that iteration finish (gates + checkpoint) and exit 6 before the second.
R26="$WORK/r26"; new_repo "$R26"
STOP26="$R26/tmp/deliver-STOP"
( cd "$R26" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress STUB_TOUCH_AFTER_BUILD="$STOP26" \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 12 --max-minutes 30 --budget-usd 5 \
      --stop-file tmp/deliver-STOP \
    >"$WORK/r26.out" 2>"$WORK/r26.err" )
RC26=$?
[[ "$RC26" -eq 6 ]] \
  && ok "--stop-file: a stop requested during BUILD exits 6" \
  || note "--stop-file run exited $RC26 — expected 6"
[[ "$(jq -r '.state' "$R26/tmp/autopilot/status.json" 2>/dev/null)" == "stopped" ]] \
  && ok "--stop-file: status.json reports stopped" \
  || note "--stop-file: status.json state is '$(jq -r '.state' "$R26/tmp/autopilot/status.json" 2>/dev/null)', expected stopped"
[[ "$(jq -r '.iterations_done' "$R26/tmp/autopilot/status.json" 2>/dev/null)" == "1" ]] \
  && ok "--stop-file: the running iteration finished; status.json counts exactly 1" \
  || note "--stop-file: iterations_done is '$(jq -r '.iterations_done' "$R26/tmp/autopilot/status.json" 2>/dev/null)', expected 1"
R26_LOG="$(git -C "$R26" log --oneline 2>/dev/null)"
case "$R26_LOG" in
  *"iteration 1 "*) ok "--stop-file: the interrupted iteration was still checkpointed" ;;
  *)                note "--stop-file: no checkpoint commit for iteration 1" ;;
esac
[[ -z "$(git -C "$R26" status --porcelain 2>/dev/null)" && ! -f "$R26/tmp/autopilot/lock" ]] \
  && ok "--stop-file: the stop leaves a clean tree and releases the lock" \
  || note "--stop-file: dirty tree or lock left after stop"
[[ -f "$STOP26" ]] \
  && ok "--stop-file: the runner leaves the stop file to its owner" \
  || note "--stop-file: the runner deleted the stop file"

# Resuming with the file removed continues the same run to completion.
rm -f "$STOP26"
( cd "$R26" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 12 --max-minutes 30 --budget-usd 5 \
      --stop-file tmp/deliver-STOP --resume-run \
    >"$WORK/r26b.out" 2>"$WORK/r26b.err" )
RC26B=$?
[[ "$RC26B" -eq 0 && "$(ls "$R26"/tmp/autopilot/run-*.jsonl | wc -l | tr -d ' ')" -eq 1 ]] \
  && ok "--stop-file: --resume-run after the stop finishes the same run (exit 0, one run log)" \
  || note "--stop-file: resume after stop exited $RC26B / $(ls "$R26"/tmp/autopilot/run-*.jsonl | wc -l | tr -d ' ') run logs — expected 0 / 1"

# A stop file already present at start stops before PLAN spends anything.
R26C="$WORK/r26c"; new_repo "$R26C"
touch "$R26C/tmp/STOP"
run_loop "$R26C" progress true --stop-file tmp/STOP
RC26C=$?
[[ "$RC26C" -eq 6 ]] && ! grep -q "PLAN phase" "$WORK/r26c.calls" 2>/dev/null \
  && ok "--stop-file: a stop file present at start exits 6 before the PLAN call" \
  || note "--stop-file: pre-existing stop file exited $RC26C (or PLAN still ran) — expected 6 with no PLAN call"

# --- 27. --state-dir + --resume-run: the prior run is found in the given dir -
R27="$WORK/r27"; new_repo "$R27"
S27="$R27/tmp/deliver/run1/issues/9"
mkdir -p "$S27"
mv "$R27/tmp/autopilot/PROMPT.md" "$S27/PROMPT.md"
printf -- '- [ ] slice 1\n- [ ] slice 2\n\nSTATUS: in-progress\n' > "$S27/IMPLEMENTATION_PLAN.md"
PRIOR27="20260101T000000Z-424242"
# S2: a fixed past date would now also restore the time cap's start time and
# trip a spurious time cap under --max-minutes 30 — irrelevant to what this
# case tests (state-dir plumbing), so timestamped "now" like cases 12/12b.
printf '{"ts":"%s","run_id":"%s","iter":2,"phase":"build","model":"sonnet","duration_s":1,"cost_usd":0.5,"input_tokens":0,"output_tokens":0,"exit_code":0,"verdict":"","holdout_failed":0}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PRIOR27" \
  > "$S27/run-$PRIOR27.jsonl"
( cd "$R27" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 2 --max-minutes 30 --budget-usd 999 \
      --state-dir tmp/deliver/run1/issues/9 --resume-run \
    >"$WORK/r27.out" 2>"$WORK/r27.err" )
RC27=$?
[[ "$RC27" -eq 2 && "$(jq -r '.run_id' "$S27/status.json" 2>/dev/null)" == "$PRIOR27" ]] \
  && ok "--state-dir + --resume-run adopts the run log found in the given dir" \
  || note "--state-dir + --resume-run exited $RC27, run '$(jq -r '.run_id' "$S27/status.json" 2>/dev/null)' — expected 2 and $PRIOR27"

# --- 28. every call's cost reaches the budget, verifier calls included ------
# The verifier used to be called as `VOUT="$(run_claude ...)"`: the subshell
# logged its cost to the run log but dropped it from the in-memory total the
# budget cap and status.json read. A five-slice run is 1 PLAN + 5 BUILD +
# 5 verifier calls = 11 calls; at $0.10 each the total must be $1.10, not the
# $0.60 that leaves the verifier out.
R28="$WORK/r28"; new_repo "$R28"
( cd "$R28" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress STUB_COST_PER_CALL=0.1 \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 12 --max-minutes 30 --budget-usd 5 \
    >"$WORK/r28.out" 2>"$WORK/r28.err" )
RC28=$?
TOTAL28="$(jq -r '.total_cost_usd' "$R28/tmp/autopilot/status.json" 2>/dev/null)"
LOGSUM28="$(cat "$R28"/tmp/autopilot/run-*.jsonl | jq -s '[.[] | select(.phase != "iteration") | .cost_usd // 0] | add')"
[[ "$RC28" -eq 0 ]] && jq -en --argjson t "${TOTAL28:-0}" '($t - 1.1 | fabs) < 0.0001' >/dev/null 2>&1 \
  && ok "status.json total cost counts all 11 calls, verifier included (\$$TOTAL28)" \
  || note "status.json total cost is \$$TOTAL28 (exit $RC28) — expected \$1.1; verifier cost dropped?"
jq -en --argjson t "${TOTAL28:-0}" --argjson l "${LOGSUM28:-0}" '($t - $l | fabs) < 0.0001' >/dev/null 2>&1 \
  && ok "the in-memory total equals the run log's per-call sum (\$$LOGSUM28)" \
  || note "in-memory total \$$TOTAL28 != run log per-call sum \$$LOGSUM28"

# --- 29. --dry-run calls no model and logs no model rows --------------------
# A preview run must spend nothing and leave the run log as small as before
# agent.sh: no plan/build/verify_agent rows from calls that never happened.
R29="$WORK/r29"; new_repo "$R29"
( cd "$R29" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress STUB_CALL_LOG="$WORK/r29.calls" \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 1 --max-minutes 30 --budget-usd 5 --dry-run \
    >"$WORK/r29.out" 2>"$WORK/r29.err" )
[[ ! -s "$WORK/r29.calls" ]] \
  && ok "--dry-run never invokes claude" \
  || note "--dry-run invoked claude $(wc -l < "$WORK/r29.calls") time(s)"
PHASES29="$(cat "$R29"/tmp/autopilot/run-*.jsonl 2>/dev/null | jq -r '.phase' | sort -u | tr '\n' ' ')"
case " $PHASES29 " in
  *" plan "*|*" build "*|*" replan "*) note "--dry-run logged model-call rows: $PHASES29" ;;
  *) ok "--dry-run logs no plan/build/replan rows (phases: ${PHASES29:-none})" ;;
esac
[[ "$(cat "$R29"/tmp/autopilot/run-*.jsonl 2>/dev/null | jq -s '[.[] | select(.phase=="verify_agent" and .duration_s > 0)] | length')" -eq 0 ]] \
  && [[ "$(jq -r '.total_cost_usd' "$R29/tmp/autopilot/status.json" 2>/dev/null)" == "0" ]] \
  && ok "--dry-run spends \$0 and records no timed verifier call" \
  || note "--dry-run recorded a cost or a timed verifier call"

# --- 30. the clock does not depend on `date` (#78) --------------------------
# now_epoch used to be `date +%s || echo 0`: one failed `date` at startup made
# START_EPOCH 0 and the first cap check exited 3 ("time cap") on a healthy
# run. The stub `date` fails only its FIRST `+%s` read — the startup one —
# and answers every later one, which is exactly the shape of that bug (a
# `date` that always fails reads 0 twice and hides it).
DATE_BIN="$WORK/brokendate"; mkdir -p "$DATE_BIN"
REAL_DATE="$(command -v date)"
cat > "$DATE_BIN/date" <<DATESTUB
#!/bin/sh
if [ "\$1" = "+%s" ] && [ ! -f "$WORK/date-failed-once" ]; then
  : > "$WORK/date-failed-once"; exit 1
fi
exec "$REAL_DATE" "\$@"
DATESTUB
chmod +x "$DATE_BIN/date"; rm -f "$WORK/date-failed-once"
R30="$WORK/r30"; new_repo "$R30"
( cd "$R30" && PATH="$DATE_BIN:$STUB_DIR:$PATH" STUB_MODE=progress \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 12 --max-minutes 30 --budget-usd 5 \
    >"$WORK/r30.out" 2>"$WORK/r30.err" )
RC30=$?
[[ "$RC30" -eq 0 ]] && ! grep -q 'time cap' "$WORK/r30.err" \
  && ok "a \`date\` that fails once at startup no longer ends a healthy run as a time cap (exit 0)" \
  || note "with a failing date: exit $RC30 — $(grep -m1 'cap\|clock' "$WORK/r30.err")"

# --- 31. every model reply is kept in calls/ (#86) ---------------------------
# The run log says an iteration failed; only the reply says why. A five-slice
# run makes 1 PLAN + 5 BUILD + 5 verifier calls: eleven files, in order.
R31="$WORK/r31"; new_repo "$R31"
run_loop "$R31" progress true
RC31=$?
CALLS31="$(ls "$R31/tmp/autopilot/calls" 2>/dev/null | tr '\n' ' ')"
[[ "$RC31" -eq 0 && "$(ls "$R31/tmp/autopilot/calls" | wc -l | tr -d ' ')" -eq 11 ]] \
  && [[ "$CALLS31" == "001-plan.md 002-build.md 003-verify_agent.md "* ]] \
  && grep -q '^"built"$\|^built$' "$R31/tmp/autopilot/calls/002-build.md" \
  && ok "calls/ keeps all 11 replies of a five-slice run, numbered in call order" \
  || note "calls/ after a five-slice run: exit $RC31, '$CALLS31'"

# --- 32. S4: loop.sh auto-detects the verify command via detect_verify_cmd -
# No --verify-cmd given — the runner must fall back to allowlist.sh's
# detect_verify_cmd (S3) instead of the old inline package.json-only block.
R32="$WORK/r32"; new_repo "$R32"
mkdir -p "$R32/scripts"
cat > "$R32/scripts/verify.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$R32/scripts/verify.sh"
git -C "$R32" add -A >/dev/null 2>&1
git -C "$R32" -c user.email=t@t.est -c user.name=test commit -q -m "add scripts/verify.sh"
( cd "$R32" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress \
    bash "$LOOP_ABS" --max-iterations 1 --max-minutes 30 --budget-usd 5 \
    >"$WORK/r32.out" 2>"$WORK/r32.err" )
RC32=$?
[[ "$RC32" -ne 1 ]] \
  && ok "a scripts/verify.sh-only repo runs without --verify-cmd (exit $RC32, not 1)" \
  || note "a scripts/verify.sh-only repo exited 1 without --verify-cmd — expected auto-detection"
grep -q "verify='bash scripts/verify.sh'" "$WORK/r32.err" 2>/dev/null \
  && ok "startup log reports verify='bash scripts/verify.sh'" \
  || note "startup log missing verify='bash scripts/verify.sh': $(cat "$WORK/r32.err")"

R32B="$WORK/r32b"; new_repo "$R32B"
cat > "$R32B/Makefile" <<'EOF'
verify:
	@true
EOF
git -C "$R32B" add -A >/dev/null 2>&1
git -C "$R32B" -c user.email=t@t.est -c user.name=test commit -q -m "add Makefile"
( cd "$R32B" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress \
    bash "$LOOP_ABS" --max-iterations 1 --max-minutes 30 --budget-usd 5 \
    >"$WORK/r32b.out" 2>"$WORK/r32b.err" )
RC32B=$?
[[ "$RC32B" -ne 1 ]] \
  && ok "a Makefile-only repo runs without --verify-cmd (exit $RC32B, not 1)" \
  || note "a Makefile-only repo exited 1 without --verify-cmd — expected auto-detection"
grep -q "verify='make verify'" "$WORK/r32b.err" 2>/dev/null \
  && ok "startup log reports verify='make verify'" \
  || note "startup log missing verify='make verify': $(cat "$WORK/r32b.err")"

R32C="$WORK/r32c"; new_repo "$R32C"
( cd "$R32C" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress \
    bash "$LOOP_ABS" --max-iterations 1 --max-minutes 30 --budget-usd 5 \
    >"$WORK/r32c.out" 2>"$WORK/r32c.err" )
RC32C=$?
[[ "$RC32C" -eq 1 ]] && grep -q "no verify command found" "$WORK/r32c.err" 2>/dev/null \
  && ok "a repo with no detectable verify command still exits 1 with the expected message" \
  || note "a repo with no verify command exited $RC32C — expected 1 with 'no verify command found'"

# --- 33. S1 (#54): the runner owns the checkpoint commit and the secret ----
# scan sees the whole iteration, committed or not ---------------------------
# Both fixtures run a single iteration (--max-iterations 1): the WIP
# checkpoint the runner makes even on a gate failure commits the secret into
# history, so on a *second* iteration the same static content is no longer
# "new" against that iteration's own ITER_BASE_SHA and the gate would (rightly)
# stay quiet — the fixture only needs to prove iteration 1 itself caught it.
#
# (a) BUILD commits a secret itself (bypassing the runner's own checkpoint) —
# still caught, because the scan diffs the index against ITER_BASE_SHA
# (recorded before BUILD ran), not HEAD: `git diff HEAD` would see nothing
# once BUILD's own commit moved HEAD to match the working tree.
R33A="$WORK/r33a"; new_repo "$R33A"
( cd "$R33A" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress STUB_SECRET_MODE=commit \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 1 --max-minutes 30 --budget-usd 5 \
    >"$WORK/r33a.out" 2>"$WORK/r33a.err" )
RC33A=$?
GATE33A="$(cat "$R33A"/tmp/autopilot/run-*.jsonl 2>/dev/null | jq -rs 'map(select(.phase=="iteration"))[0].gate_failed' 2>/dev/null)"
[[ "$RC33A" -eq 2 && "$GATE33A" == "secret" ]] \
  && ok "a secret committed by BUILD itself fails iteration 1's gate (gate_failed=secret)" \
  || note "BUILD-committed secret: exit $RC33A (expected 2), gate_failed='$GATE33A'"
grep -q "possible secret in diff" "$R33A/tmp/autopilot/FEEDBACK.md" 2>/dev/null \
  && ok "FEEDBACK.md names the secret finding for a BUILD-side commit" \
  || note "FEEDBACK.md missing the secret finding: $(cat "$R33A/tmp/autopilot/FEEDBACK.md" 2>/dev/null)"

# (b) BUILD leaves the secret in a new untracked file, never staged or
# committed at all — a `git diff HEAD` would never see it at all (untracked
# files never appear in a diff against HEAD); `git add -A` + `git diff
# --cached ITER_BASE_SHA` must.
R33B="$WORK/r33b"; new_repo "$R33B"
( cd "$R33B" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress STUB_SECRET_MODE=untracked \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 1 --max-minutes 30 --budget-usd 5 \
    >"$WORK/r33b.out" 2>"$WORK/r33b.err" )
RC33B=$?
GATE33B="$(cat "$R33B"/tmp/autopilot/run-*.jsonl 2>/dev/null | jq -rs 'map(select(.phase=="iteration"))[0].gate_failed' 2>/dev/null)"
[[ "$RC33B" -eq 2 && "$GATE33B" == "secret" ]] \
  && ok "a secret left in a new untracked file fails iteration 1's gate (gate_failed=secret)" \
  || note "untracked secret: exit $RC33B (expected 2), gate_failed='$GATE33B'"
grep -q "possible secret in diff" "$R33B/tmp/autopilot/FEEDBACK.md" 2>/dev/null \
  && ok "FEEDBACK.md names the secret finding for an untracked secret file" \
  || note "FEEDBACK.md missing the secret finding: $(cat "$R33B/tmp/autopilot/FEEDBACK.md" 2>/dev/null)"

# (c) BUILD's own --allowedTools no longer grants git add/git commit — the
# runner owns the checkpoint, not BUILD. Across the whole run, "Bash(git
# add"/"Bash(git commit" could only ever have come from BUILD_ALLOWED_TOOLS —
# PLAN's tool list has no Bash at all, and the verifier's has only git
# diff/log/status — so a plain absence check over every call this run made
# is enough to prove the grant is gone.
grep -q 'ONE iteration of an autonomous BUILD loop' "$WORK/r1.calls" 2>/dev/null \
  && ! grep -qE 'Bash\(git add|Bash\(git commit' "$WORK/r1.calls" \
  && ok "BUILD_ALLOWED_TOOLS no longer grants git add/git commit" \
  || note "BUILD's allowed-tools still mention git add/git commit: $(grep -oE 'Bash\(git [a-z]+:[^)]*\)' "$WORK/r1.calls" | sort -u | tr '\n' ' ')"
grep -qF 'Do not run `git add` or `git commit`' "$WORK/r1.calls" 2>/dev/null \
  && ok "the BUILD prompt tells BUILD the runner stages and commits the checkpoint" \
  || note "the BUILD prompt doesn't mention the runner owning the commit"

# --- 34. S2 (#54): the verifier diffs the whole iteration against ----------
# ITER_BASE_SHA, not HEAD — a change BUILD committed itself must still be
# visible to the verifier, exactly as it must to the secret scan (test 33a).
R34="$WORK/r34"; new_repo "$R34"
PRE_SHA_34="$(git -C "$R34" rev-parse HEAD)"
( cd "$R34" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress \
    STUB_BUILD_SELF_COMMIT_FILE="build-own-commit.txt" \
    STUB_VERIFY_DIFF_LOG="$WORK/r34-verify.diff" STUB_CALL_LOG="$WORK/r34.calls" \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 1 --max-minutes 30 --budget-usd 5 \
    >"$WORK/r34.out" 2>"$WORK/r34.err" )
grep -qF "git diff --cached $PRE_SHA_34" "$WORK/r34.calls" 2>/dev/null \
  && ok "the verifier's prompt names the pre-BUILD SHA (ITER_BASE_SHA), not HEAD" \
  || note "verifier prompt doesn't name $PRE_SHA_34: $(grep -oE 'git diff[^\`]*' "$WORK/r34.calls" 2>/dev/null | sort -u | tr '\n' ' ')"
grep -qF "build-own-commit.txt" "$WORK/r34-verify.diff" 2>/dev/null \
  && ok "running the prompt's own diff command shows the file BUILD committed itself" \
  || note "the prompt's diff command missed BUILD's own commit: $(cat "$WORK/r34-verify.diff" 2>/dev/null)"
FC34="$(jq -s '[.[] | select(.phase=="iteration")][0].files_changed // -1' "$R34"/tmp/autopilot/run-*.jsonl 2>/dev/null)"
WANT34="$(git -C "$R34" diff --stat "$PRE_SHA_34" HEAD 2>/dev/null | grep -c '|')"
[[ "${WANT34:-0}" -ge 2 && "$FC34" == "$WANT34" ]] \
  && ok "the iteration row's files_changed counts BUILD's own commit too ($FC34 = the whole iteration's diff from ITER_BASE_SHA)" \
  || note "files_changed=$FC34, but the iteration changed $WANT34 file(s) since ITER_BASE_SHA"

# --- 35. secret_scan() ignores unchanged lines shown only as diff context --
# (regression, found dogfooding S1/S2 on this very repo: a plan-adjacent test
# edit landed within 3 lines of an already-committed AKIA-pattern fixture
# line and tripped the gate even though that line itself was untouched).
# secret_scan() must judge the actual change, not everything unified diff
# context reprints around it.
R35="$WORK/r35"; new_repo "$R35"
printf -- '- [ ] slice 1\n\nSTATUS: in-progress\n' > "$R35/tmp/autopilot/IMPLEMENTATION_PLAN.md"
printf 'unrelated line\ntoken = "AKIAABCDEFGHIJKLMNOP"\nunrelated line\n' > "$R35/config.txt"
git -C "$R35" add config.txt >/dev/null 2>&1
git -C "$R35" -c user.email=t@t.est -c user.name=test commit -q -m "add config.txt fixture"
( cd "$R35" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress STUB_SECRET_MODE=nearby \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 1 --max-minutes 30 --budget-usd 5 \
    >"$WORK/r35.out" 2>"$WORK/r35.err" )
RC35=$?
GATE35="$(cat "$R35"/tmp/autopilot/run-*.jsonl 2>/dev/null | jq -rs 'map(select(.phase=="iteration"))[0].gate_failed' 2>/dev/null)"
[[ "$RC35" -eq 0 && "$GATE35" == "none" ]] \
  && ok "an edit merely near a pre-existing secret-looking line (diff context) does not fail the gate" \
  || note "edit near a pre-existing secret line: exit $RC35 (expected 0), gate_failed='$GATE35', FEEDBACK='$(cat "$R35/tmp/autopilot/FEEDBACK.md" 2>/dev/null)'"

# --- 35b. secret_scan() ignores removed lines too (#94) -------------------
R35B="$WORK/r35b"; new_repo "$R35B"
printf -- '- [ ] slice 1\n\nSTATUS: in-progress\n' > "$R35B/tmp/autopilot/IMPLEMENTATION_PLAN.md"
# The fixture key is assembled at runtime so this test file's own added lines
# don't trip the very secret scan it exercises.
FAKE35B="AKIA""ABCDEFGHIJKLMNOP"
printf 'unrelated line\ntoken = "%s"\nunrelated line\n' "$FAKE35B" > "$R35B/config.txt"
git -C "$R35B" add config.txt >/dev/null 2>&1
git -C "$R35B" -c user.email=t@t.est -c user.name=test commit -q -m "add config.txt fixture"
( cd "$R35B" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress STUB_SECRET_MODE=removed \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 1 --max-minutes 30 --budget-usd 5 \
    >"$WORK/r35b.out" 2>"$WORK/r35b.err" )
RC35B=$?
GATE35B="$(cat "$R35B"/tmp/autopilot/run-*.jsonl 2>/dev/null | jq -rs 'map(select(.phase=="iteration"))[0].gate_failed' 2>/dev/null)"
[[ "$RC35B" -eq 0 && "$GATE35B" == "none" ]] \
  && ok "removing a pre-existing secret-looking line (a '-' diff line) does not fail the gate" \
  || note "removed secret line: exit $RC35B (expected 0), gate_failed='$GATE35B'"

# --- 36. The gates fail closed when the runner cannot stage the iteration ---
# (#54 review): a failed `git add -A` must not let the secret scan and the
# verifier read a partial index as "clean".
R36="$WORK/r36"; new_repo "$R36"
( cd "$R36" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress STUB_SECRET_MODE=lockindex \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 1 --max-minutes 30 --budget-usd 5 \
    >"$WORK/r36.out" 2>"$WORK/r36.err" )
GATE36="$(cat "$R36"/tmp/autopilot/run-*.jsonl 2>/dev/null | jq -rs 'map(select(.phase=="iteration"))[0].gate_failed' 2>/dev/null)"
rm -f "$R36/.git/index.lock"
[[ "$GATE36" == "stage" ]] && grep -q 'could not stage the iteration' "$R36/tmp/autopilot/FEEDBACK.md" 2>/dev/null \
  && ok "a failed git add -A fails the iteration (gate_failed=stage) instead of passing the gates on a partial index" \
  || note "held index lock: gate_failed='$GATE36', FEEDBACK='$(cat "$R36/tmp/autopilot/FEEDBACK.md" 2>/dev/null)'"

# --- 37. Files the verify command writes are scanned too ------------------------
# The runner stages again after GATE b: a secret in generated, non-ignored
# output would otherwise ride into the checkpoint commit unscanned.
R37="$WORK/r37"; new_repo "$R37"
( cd "$R37" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress \
    bash "$LOOP_ABS" --verify-cmd 'printf "token = \"AKIAABCDEFGHIJKLMNOP\"\n" > generated.txt' \
    --max-iterations 1 --max-minutes 30 --budget-usd 5 \
    >"$WORK/r37.out" 2>"$WORK/r37.err" )
GATE37="$(cat "$R37"/tmp/autopilot/run-*.jsonl 2>/dev/null | jq -rs 'map(select(.phase=="iteration"))[0].gate_failed' 2>/dev/null)"
[[ "$GATE37" == "secret" ]] \
  && ok "a secret the verify command wrote into a non-ignored file fails the secret gate" \
  || note "verify-written secret: gate_failed='$GATE37'"

# --- 38. A BUILD that runs out of --max-turns is named as such (#96) ---------
R38="$WORK/r38"; new_repo "$R38"
( cd "$R38" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress STUB_BUILD_MAX_TURNS=1 \
    STUB_CALL_LOG="$WORK/r38.calls" \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 1 --max-minutes 30 --budget-usd 5 --max-turns 42 \
    >"$WORK/r38.out" 2>"$WORK/r38.err" )
BUILD38="$(cat "$R38"/tmp/autopilot/run-*.jsonl 2>/dev/null | jq -rs '[.[] | select(.phase=="build")][0].verdict' 2>/dev/null)"
ITER38="$(cat "$R38"/tmp/autopilot/run-*.jsonl 2>/dev/null | jq -rcs '[.[] | select(.phase=="iteration")][0] | [.turn_limit, .gate_failed] | join(" ")' 2>/dev/null)"
grep -q -- '--max-turns 42' "$WORK/r38.calls" \
  && ok "--max-turns reaches claude -p" \
  || note "--max-turns 42 not in the calls: $(grep -oE -- '--max-turns [0-9]+' "$WORK/r38.calls" | sort -u | tr '\n' ' ')"
[[ "$BUILD38" == "turn-limit" && "$ITER38" == "true turn-limit" ]] \
  && grep -q 'BUILD ran out of turns (--max-turns 42)' "$R38/tmp/autopilot/FEEDBACK.md" \
  && ok "an error_max_turns BUILD reply is logged as turn-limit (call row, iteration row, FEEDBACK)" \
  || note "turn limit: build verdict='$BUILD38', iteration='$ITER38', FEEDBACK='$(head -c 300 "$R38/tmp/autopilot/FEEDBACK.md" 2>/dev/null)'"

R39="$WORK/r39"; new_repo "$R39"
( cd "$R39" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress STUB_BUILD_MAX_TURNS=1 \
    bash "$LOOP_ABS" --verify-cmd false --max-iterations 1 --max-minutes 30 --budget-usd 5 --max-turns 42 \
    >"$WORK/r39.out" 2>"$WORK/r39.err" )
ITER39="$(cat "$R39"/tmp/autopilot/run-*.jsonl 2>/dev/null | jq -rcs '[.[] | select(.phase=="iteration")][0] | [.turn_limit, .gate_failed] | join(" ")' 2>/dev/null)"
[[ "$ITER39" == "true verify_cmd" ]] && grep -q 'BUILD also ran out of turns' "$R39/tmp/autopilot/FEEDBACK.md" \
  && ok "a turn-limited BUILD whose work fails verify keeps gate_failed=verify_cmd, turn_limit:true, and FEEDBACK names the turn limit" \
  || note "turn limit + red verify: iteration='$ITER39', FEEDBACK='$(head -c 300 "$R39/tmp/autopilot/FEEDBACK.md" 2>/dev/null)'"

# --- 40-43. Pacing for one PR-sized issue (#88) ------------------------------
# /deliver hands autopilot an issue that is already a slice: a small plan, and
# the full verify once, at completion.
R40="$WORK/r40"; new_repo "$R40"
run_loop "$R40" progress true --plan-max-items 2
[[ $? -eq 0 ]] && grep -q 'most 2 items' "$WORK/r40.calls" && grep -q 'ONE issue, already sized' "$WORK/r40.calls" \
  && ok "--plan-max-items puts the size hint into the PLAN prompt" \
  || note "--plan-max-items hint missing from the PLAN prompt"
grep -q 'ONE issue, already sized' "$WORK/r1.calls" \
  && note "the size hint appears without --plan-max-items" \
  || ok "without --plan-max-items the PLAN prompt is unchanged"

R41="$WORK/r41"; new_repo "$R41"
run_loop "$R41" progress "echo x >> '$WORK/r41.verify-count'" --verify-at-completion
RC41=$?
VERDICTS41="$(cat "$R41"/tmp/autopilot/run-*.jsonl | jq -r 'select(.phase=="verify_cmd") | .verdict' | sort | uniq -c | tr -s ' ' | tr '\n' ',')"
[[ "$RC41" -eq 0 && "$(wc -l < "$WORK/r41.verify-count" | tr -d ' ')" -eq 1 ]] \
  && [[ "$VERDICTS41" == " 4 deferred, 1 pass," ]] \
  && ok "--verify-at-completion: a five-item run runs the full verify once, at completion (4 deferred, 1 pass)" \
  || note "--verify-at-completion: exit $RC41, verify ran $(wc -l < "$WORK/r41.verify-count" 2>/dev/null) time(s), verdicts '$VERDICTS41', stderr: $(tail -3 "$WORK/r41.err" | tr '\n' '|')"
grep -q 'Do NOT run the full verify command' "$WORK/r41.calls" && ! grep -q 'Run the verify command:' "$WORK/r41.calls" \
  && ok "--verify-at-completion: BUILD is told to run its item's tests, not the full verify" \
  || note "--verify-at-completion: BUILD prompt still asks for the full verify"
[[ "$(jq -r '.verify_deferred' "$R41/tmp/autopilot/status.json" 2>/dev/null)" == "4" \
   && "$(jq -r '.verify_deferred' "$R1/tmp/autopilot/status.json" 2>/dev/null)" == "0" ]] \
  && ok "status.json counts deferred gate-(b) runs (verify_deferred: 4 here, 0 in a bare run)" \
  || note "verify_deferred: '$(jq -r '.verify_deferred' "$R41/tmp/autopilot/status.json" 2>/dev/null)' with deferral, '$(jq -r '.verify_deferred' "$R1/tmp/autopilot/status.json" 2>/dev/null)' without"

# A completion whose full verify fails is not done: back to work, then done.
R42="$WORK/r42"; new_repo "$R42"
run_loop "$R42" progress "n=\$(cat '$WORK/r42.n' 2>/dev/null || echo 0); echo \$((n+1)) > '$WORK/r42.n'; [ \$n -ge 1 ]" --verify-at-completion
RC42=$?
[[ "$RC42" -eq 0 && "$(cat "$WORK/r42.n")" -eq 2 ]] \
  && [[ "$(cat "$R42"/tmp/autopilot/run-*.jsonl | jq -r 'select(.phase=="iteration") | .verdict' | tail -2 | tr '\n' ' ')" == "fail done " ]] \
  && ok "--verify-at-completion: a failing completion verify sends the run back, the next completion finishes it" \
  || note "failing completion verify: exit $RC42, verify ran $(cat "$WORK/r42.n" 2>/dev/null) time(s), stderr: $(tail -3 "$WORK/r42.err" | tr '\n' '|')"

R43="$WORK/r43"; new_repo "$R43"
run_loop "$R43" progress "echo full >> '$WORK/r43.count'" --verify-at-completion --iteration-verify-cmd "echo quick >> '$WORK/r43.count'"
RC43=$?
[[ "$RC43" -eq 0 && "$(sort "$WORK/r43.count" | uniq -c | tr -s ' ' | tr '\n' ',')" == " 1 full, 4 quick," ]] \
  && ok "--iteration-verify-cmd runs on every other iteration, the full verify once" \
  || note "--iteration-verify-cmd: exit $RC43, runs: $(sort "$WORK/r43.count" 2>/dev/null | uniq -c | tr '\n' ','), stderr: $(tail -3 "$WORK/r43.err" | tr '\n' '|'), status: $(cat "$R43/tmp/autopilot/status.json" 2>/dev/null)"
R43B="$WORK/r43b"; new_repo "$R43B"
run_loop "$R43B" progress true --iteration-verify-cmd true
RC43B=$?
R43C="$WORK/r43c"; new_repo "$R43C"
run_loop "$R43C" progress true --plan-max-items 0
RC43C=$?
[[ "$RC43B" -eq 1 && "$RC43C" -eq 1 ]] \
  && ok "--iteration-verify-cmd without --verify-at-completion and --plan-max-items 0 are refused" \
  || note "flag validation: exit $RC43B / $RC43C — expected 1 / 1"

# --- 44. a timed-out call records an unknown cost, not zero ----------------
# The stub sleeps past --per-call-timeout 1, so `timeout` kills every call.
R44="$WORK/r44"; new_repo "$R44"
( cd "$R44" && PATH="$STUB_DIR:$PATH" STUB_MODE=progress STUB_SLEEP=3 \
    bash "$LOOP_ABS" --verify-cmd true --max-iterations 1 --max-minutes 30 --budget-usd 5 \
      --per-call-timeout 1 >"$WORK/r44.out" 2>"$WORK/r44.err" )
[[ "$(cat "$R44"/tmp/autopilot/run-*.jsonl 2>/dev/null | jq -s '[.[] | select(.phase!="iteration" and .cost_unknown==true)] | length')" -ge 1 ]] \
  && ok "a timed-out call's run-log row carries cost_unknown:true" \
  || note "no cost_unknown:true row after a timeout: $(cat "$R44"/tmp/autopilot/run-*.jsonl 2>/dev/null | head -3)"
[[ "$(jq -r '.cost_unknown_calls' "$R44/tmp/autopilot/status.json" 2>/dev/null)" -ge 1 ]] \
  && ok "status.json counts the unknown-cost calls (cost_unknown_calls)" \
  || note "status.json cost_unknown_calls: $(cat "$R44/tmp/autopilot/status.json" 2>/dev/null)"
[[ "$(cat "$R1"/tmp/autopilot/run-*.jsonl | jq -s '[.[] | select(.cost_unknown==true)] | length')" -eq 0 \
   && "$(jq -r '.cost_unknown_calls' "$R1/tmp/autopilot/status.json")" == "0" ]] \
  && ok "a run with no timeout has cost_unknown_calls 0 and no unknown rows" \
  || note "a clean run reports unknown-cost calls"

# report.sh names the unknown-cost calls per day and model.
RU="$WORK/report-unknown"; mkdir -p "$RU"
printf '%s\n' '{"ts":"2026-09-01T10:00:00Z","run_id":"20260901T100000Z-1","iter":1,"phase":"build","model":"sonnet","cost_usd":0,"cost_unknown":true}' \
  '{"ts":"2026-09-01T11:00:00Z","run_id":"20260901T100000Z-1","iter":1,"phase":"plan","model":"sonnet","cost_usd":0.1,"cost_unknown":false}' > "$RU/run-20260901T100000Z-1.jsonl"
bash "$REPORT_ABS" "$RU" 2>/dev/null | grep -q '2026-09-01 | sonnet | 1 call(s) with unknown cost' \
  && ok "report.sh prints the count of calls with unknown cost per day/model" \
  || note "report.sh did not print the unknown-cost count"

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "test-autopilot-loop: PASS"
else
  echo "test-autopilot-loop: $FAIL failure(s)"
fi
exit "$FAIL"
