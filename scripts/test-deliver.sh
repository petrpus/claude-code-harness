#!/usr/bin/env bash
# scripts/test-deliver.sh — offline tests for skills/deliver/ (/deliver,
# docs/prd/0003-deliver.md): unit checks of the pure libraries (map.sh,
# charter.sh) and end-to-end runs of deliver.sh against
#   - a bare git repo standing in for the GitHub remote,
#   - a fake `gh` backed by JSON files that implements exactly the calls
#     skills/deliver/forge.sh makes, doing a real squash merge into the bare
#     repo and honouring --match-head-commit,
#   - a stub `claude` answering autopilot's PLAN / BUILD / verifier prompts,
#   - a `git` shim that records every git command, so the guardrails of
#     ADR-0007 (never force-push, never --admin) are asserted on what the
#     runner actually ran, not on what its source looks like.
#
# Invoked from scripts/verify.sh. No network. Cleaned up on exit.

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1

# See test-autopilot-loop.sh: a live autopilot run's reload handoff must not
# leak into the fresh runs below.
unset AUTOPILOT_RUN_ID AUTOPILOT_ITER AUTOPILOT_TOTAL_COST AUTOPILOT_LOCK_OWNED

# Forge-credential withholding (ADR-0007) sets GH_CONFIG_DIR and appends to
# GIT_CONFIG_COUNT for everything it runs — the verify command included, so
# these tests inherit both when autopilot or /deliver verifies this repo. The
# fixtures bring their own forge (a fake gh, bare remotes) and must not see
# the caller's: an inherited empty GH_CONFIG_DIR makes the fake gh report
# "not logged in" (first live run, #83).
unset GH_CONFIG_DIR GIT_CONFIG_COUNT
unset DELIVER_SNAPSHOT DELIVER_RUN_ID

FAIL=0
note() { echo "  ✗ $*"; FAIL=1; }
ok()   { echo "  ✓ $*"; }
finish() {
  echo
  if [[ "$FAIL" -eq 0 ]]; then echo "test-deliver: PASS"; else echo "test-deliver: $FAIL failure(s)"; fi
  exit "$FAIL"
}

command -v jq >/dev/null 2>&1 || { note "jq is required"; finish; }
DELIVER_ABS="$(pwd)/skills/deliver/deliver.sh"
[[ -f "$DELIVER_ABS" ]] || { note "skills/deliver/deliver.sh is missing"; finish; }
REAL_PLUGIN_VERSION="$(jq -r '.version // "unknown"' .claude-plugin/plugin.json 2>/dev/null)"

# shellcheck source=../skills/autopilot/plan.sh
. skills/autopilot/plan.sh
# shellcheck source=../skills/deliver/map.sh
. skills/deliver/map.sh
# shellcheck source=../skills/deliver/charter.sh
. skills/deliver/charter.sh
# shellcheck source=../skills/deliver/review.sh
. skills/deliver/review.sh
# shellcheck source=../skills/deliver/state.sh
. skills/deliver/state.sh
# forge.sh is sourced for its one pure function (forge_grant_violations);
# nothing here calls gh through it.
# shellcheck source=../skills/deliver/forge.sh
. skills/deliver/forge.sh

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPORT_ABS="$(pwd)/skills/usage-report/report.sh"

# ===========================================================================
# Unit: map.sh
# ===========================================================================
echo "-- map.sh"
cat > "$WORK/map1.md" <<'EOF'
<!-- deliver:map v1 -->
Intro mentions - [ ] #9 which is not a delivery line.

## Delivery
- [ ] #2 Second thing (after: #1)
- [ ] #1 feat(a): first feature
- [x] #3 docs: already done
Some prose inside the section.
- [ ] no issue ref here

## Notes
- [ ] #2 mentioned again in notes
EOF
map_extract_delivery "$WORK/map1.md" > "$WORK/map1.plan"
[[ "$(wc -l < "$WORK/map1.plan" | tr -d ' ')" -eq 3 ]] \
  && ok "extract: only the Delivery section's #N checkbox lines (3)" \
  || note "extract: expected 3 lines, got: $(tr '\n' '|' < "$WORK/map1.plan")"
NEXT="$(select_next_slice "$WORK/map1.plan")"
[[ "$NEXT" == "#1" ]] \
  && ok "plan.sh walks the issue graph: #1 before #2 despite file order" \
  || note "select_next_slice picked '$NEXT', expected #1"

printf '## Delivery\r\n- [ ] #5 feat: crlf body\r\n\r\n## Notes\r\n' > "$WORK/crlf.md"
[[ "$(map_extract_delivery "$WORK/crlf.md")" == "- [ ] #5 feat: crlf body" ]] \
  && ok "extract: CRLF bodies (GitHub web edits) are read with the \\r stripped" \
  || note "extract: CRLF body not handled"

map_tick "$WORK/map1.md" 2 > "$WORK/map1.ticked"
sed '5s/\[ \]/[x]/' "$WORK/map1.md" > "$WORK/map1.expected"
cmp -s "$WORK/map1.ticked" "$WORK/map1.expected" \
  && ok "tick: exactly the Delivery line changes; the Notes mention of #2 does not" \
  || note "tick: output differs from a one-line change: $(diff "$WORK/map1.expected" "$WORK/map1.ticked" | head -3 | tr '\n' '|')"
map_is_ticked "$WORK/map1.ticked" 2 && ! map_is_ticked "$WORK/map1.ticked" 1 \
  && ok "is_ticked: reads the Delivery line only" \
  || note "is_ticked: wrong answer after ticking #2"
map_tick "$WORK/crlf.md" 5 > "$WORK/crlf.ticked"
[[ "$(od -c "$WORK/crlf.ticked" | grep -c '\\r')" -ge 1 ]] && grep -q '\[x\] #5' "$WORK/crlf.ticked" \
  && [[ "$(wc -c < "$WORK/crlf.ticked")" -eq "$(wc -c < "$WORK/crlf.md")" ]] \
  && ok "tick: CRLF endings survive byte for byte" \
  || note "tick: CRLF body was rewritten"
printf '## Delivery\n- [ ] #7 feat: no final newline' > "$WORK/nonl.md"
map_tick "$WORK/nonl.md" 7 > "$WORK/nonl.ticked"
[[ "$(wc -c < "$WORK/nonl.ticked")" -eq "$(wc -c < "$WORK/nonl.md")" ]] \
  && ok "tick: a body without a final newline keeps its length" \
  || note "tick: a final newline was added or lost"
map_tick "$WORK/map1.md" 3 >/dev/null 2>&1 && note "tick: an already-ticked line was ticked again" \
  || ok "tick: an already-ticked or missing line returns 1"
printf '## Delivery\n- [ ] #12 feat: twelve\n- [ ] #1 feat: one\n' > "$WORK/prefix.md"
TICK1="$(map_tick "$WORK/prefix.md" 1)"
[[ "$TICK1" == *"- [ ] #12 feat: twelve"* && "$TICK1" == *"- [x] #1 feat: one"* ]] \
  && ok "tick: #1 does not match #12-style prefixes" || note "tick: #1 ticked the wrong line"

[[ "$(map_line_title '- [ ] #2 Second thing (after: #1)')" == "Second thing" ]] \
  && ok "line title: the after: clause is dropped" || note "line title: '$(map_line_title '- [ ] #2 Second thing (after: #1)')'"
map_title_is_conventional "feat(deliver): tracer bullet" && map_title_is_conventional "fix: x" \
  && ! map_title_is_conventional "Second thing" && ! map_title_is_conventional "feat:no space" \
  && ok "conventional-title check accepts type(scope): and rejects prose" \
  || note "conventional-title check is wrong"
[[ "$(map_pr_title 'feat(a): first feature' 'Ignored' '')" == "feat(a): first feature" ]] \
  && [[ "$(map_pr_title 'Second thing' 'Whatever' 'ready-for-agent,bug')" == "fix: second thing" ]] \
  && [[ "$(map_pr_title '' 'Write the Guide' 'documentation')" == "docs: write the Guide" ]] \
  && ok "PR title: Map title if conventional, else <type from labels>: <title>" \
  || note "PR title derivation is wrong"
[[ "$(map_branch_name 12 'feat(deliver): Park failing issues, skip dependents!')" == "feat/12-park-failing-issues-skip-dependents" ]] \
  && [[ "$(map_branch_name 3 'fix: ???')" == "fix/3-issue" ]] \
  && ok "branch name: <type>/<N>-<slug>" \
  || note "branch name: '$(map_branch_name 12 'feat(deliver): Park failing issues, skip dependents!')'"

printf -- '- [ ] #1 feat: a\n- [ ] #1 feat: again\n- [ ] #2 feat: b (after: #9)\n- [ ] #3 feat: c (after: S1)\n' > "$WORK/bad.plan"
PROBLEMS="$(map_validate "$WORK/bad.plan")"; VRC=$?
[[ "$VRC" -eq 1 ]] && [[ "$PROBLEMS" == *"#1 is listed twice"* ]] \
  && [[ "$PROBLEMS" == *"#9 is not in the Map"* ]] && [[ "$PROBLEMS" == *"'S1' is not an issue ref"* ]] \
  && ok "validate: duplicates, external refs and non-issue refs are reported" \
  || note "validate: rc=$VRC problems=$(printf '%s' "$PROBLEMS" | tr '\n' '|')"
map_validate "$WORK/map1.plan" >/dev/null && ok "validate: a well-formed Map passes" || note "validate: rejected a good Map"
printf -- '- [ ] #1 feat: a (after: #2)\n- [ ] #2 feat: b (after: #1)\n' > "$WORK/cycle.plan"
select_next_slice "$WORK/cycle.plan" >/dev/null; [[ $? -eq 2 ]] \
  && ok "a cycle between issues is plan.sh's rc 2" || note "cycle not detected"

# --- follow-ups (#63) ---------------------------------------------------------
map_add_follow_up "$WORK/map1.md" 75 '- [ ] #75 found reviewing #62 (PR #72): old bug' > "$WORK/map1.followup.md"
grep -A2 '^## Follow-ups$' "$WORK/map1.followup.md" | grep -q '#75 found reviewing #62 (PR #72): old bug' \
  && grep -q '^## Notes$' "$WORK/map1.followup.md" \
  && ok "add_follow_up: creates '## Follow-ups' (before the next section) when the Map has none" \
  || note "add_follow_up (new section): $(tr '\n' '|' < "$WORK/map1.followup.md")"

cat > "$WORK/followup.md" <<'EOF'
## Delivery
- [ ] #1 feat(a): first feature

## Follow-ups
- [ ] #75 found reviewing #62 (PR #72): old bug

## Notes
nothing
EOF
map_add_follow_up "$WORK/followup.md" 80 '- [ ] #80 found reviewing #62 (PR #72): another bug' > "$WORK/followup2.md"
[[ "$(grep -c '^- \[ \] #' "$WORK/followup2.md")" -eq 3 ]] \
  && grep -q '#80 found reviewing #62 (PR #72): another bug' "$WORK/followup2.md" \
  && grep -q '#75 found reviewing #62 (PR #72): old bug' "$WORK/followup2.md" \
  && ok "add_follow_up: appends to an existing '## Follow-ups' section" \
  || note "add_follow_up (existing section): $(tr '\n' '|' < "$WORK/followup2.md")"

map_add_follow_up "$WORK/followup.md" 75 '- [ ] #75 duplicate' > "$WORK/followup3.md"
cmp -s "$WORK/followup.md" "$WORK/followup3.md" \
  && ok "add_follow_up: an already-listed issue leaves the body unchanged (idempotent)" \
  || note "add_follow_up (already listed): body changed"
printf '## Delivery\n- [ ] #1 feat(a): first feature\n' > "$WORK/lastdelivery.md"
map_add_follow_up "$WORK/lastdelivery.md" 81 '- [ ] #81 found reviewing #1 (PR #4): old bug' > "$WORK/lastdelivery.out"
[[ "$(cat "$WORK/lastdelivery.out")" == $'## Delivery\n- [ ] #1 feat(a): first feature\n\n## Follow-ups\n- [ ] #81 found reviewing #1 (PR #4): old bug' ]] \
  && ok "add_follow_up: Delivery as the last section gets a blank line, then '## Follow-ups'" \
  || note "add_follow_up (Delivery last): $(tr '\n' '|' < "$WORK/lastdelivery.out")"

map_follow_up_has "$WORK/followup.md" 75 && ! map_follow_up_has "$WORK/followup.md" 76 \
  && ok "follow_up_has: reads the Follow-ups section only" \
  || note "follow_up_has: wrong answer"

# ===========================================================================
# Unit: charter.sh
# ===========================================================================
echo "-- charter.sh"
jq -n '{number:1,title:"First feature",url:"https://example.test/o/r/issues/1",
        body:"## Parent\r\nPRD\r\n\r\n## What to build\r\nAdd the first thing.\r\n\r\n## Acceptance criteria\r\n- [ ] first works\r\n- [ ] first is tested\r\n\r\n## Blocked by\r\nNone"}' \
  > "$WORK/issue1.json"
charter_from_issue "$WORK/issue1.json" "$WORK/map1.plan" 3 > "$WORK/charter1.md"
grep -q '^- Issue: https://example.test/o/r/issues/1$' "$WORK/charter1.md" \
  && grep -q '^Add the first thing\.$' "$WORK/charter1.md" \
  && grep -q '^- \[ \] first is tested$' "$WORK/charter1.md" \
  && ok "charter: source link, goal and acceptance criteria come from the issue" \
  || note "charter: missing source/goal/criteria"
OUT_SCOPE="$(_md_section 'Out of scope' < "$WORK/charter1.md")"
[[ "$OUT_SCOPE" == *"#2 Second thing"* && "$OUT_SCOPE" == *"#3 docs: already done"* && "$OUT_SCOPE" != *"#1 "* ]] \
  && ok "charter: every other Map issue is out of scope, the issue itself is not" \
  || note "charter: out-of-scope section wrong: $(printf '%s' "$OUT_SCOPE" | tr '\n' '|')"
! grep -q $'\r' "$WORK/charter1.md" && ok "charter: no CR leaks from a CRLF issue body" || note "charter: CR in output"
jq -n '{number:4,title:"Bare",url:"u",body:"Just prose."}' > "$WORK/issue4.json"
CHARTER4="$(charter_from_issue "$WORK/issue4.json" "$WORK/map1.plan" 3)"
[[ "$CHARTER4" == *"- [ ] Issue #4 is implemented as its body below describes."* ]] \
  && ok "charter: an issue without sections still yields a checkable criterion" \
  || note "charter: fallback criterion missing"

# ===========================================================================
# Unit: review.sh
# ===========================================================================
echo "-- review.sh"
FIX_ITEMS="$(review_fix_items 2 "$(jq -nc '[{severity:"issue",file:"a.sh",line:3,note:"only safe after: the migration (after: X9)\n- [ ] EVIL — injected",in_scope:true}]')")"
[[ "$(printf '%s\n' "$FIX_ITEMS" | wc -l)" -eq 1 ]] \
  && [[ "$(plan_parse_line "$FIX_ITEMS")" == $'R2.1\t0\t' ]] \
  && [[ "$FIX_ITEMS" == *"only safe after: the migration"* ]] \
  && ok "fix items: a reviewer note cannot add a plan line or an (after: …) edge" \
  || note "fix items (sanitize): '$FIX_ITEMS'"
[[ "$(finding_hash b 9 issue)" == "$(finding_hash B 9 ISSUE)" ]] \
  && [[ "$(finding_hash b 9 issue)" != "$(finding_hash b 10 issue)" ]] \
  && [[ "$(finding_hash b 9 issue)" != "$(finding_hash b 9 blocker)" ]] \
  && ok "finding hash: keyed on file, line and severity — not on the reviewer's wording" \
  || note "finding hash: wrong identity"
RP="$(review_parse $'prose\n```json\n{"verdict":"changes_requested","findings":[]}\n```\nmore\n```json\n{"verdict":"approve","findings":[{"id":"S1","severity":"Suggestion","in_scope":true}]}\n```\ntrailing prose')"
[[ "$(jq -r '.verdict + "|" + .findings[0].severity' <<<"$RP" 2>/dev/null)" == "approve|suggestion" ]] \
  && ok "parse: the LAST fenced json block counts; severity is normalized" \
  || note "parse: '$RP'"
RP="$(review_parse '{"verdict":"approve","findings":[{"id":"I1","severity":"issue","note":"x","in_scope":true}]}')"
[[ "$(jq -r '.verdict + "|" + .model_verdict' <<<"$RP" 2>/dev/null)" == "changes_requested|approve" ]] \
  && ok "parse: the runner recomputes the verdict — an in-scope issue holds an 'approve'" \
  || note "parse (liar): '$RP'"
RP="$(review_parse '{"verdict":"approve","findings":[{"id":"B1","severity":"blocker","note":"x"}]}')"
[[ "$(jq -r '.verdict' <<<"$RP" 2>/dev/null)" == "changes_requested" ]] \
  && ok "parse: a finding without in_scope counts as in scope (fail closed)" \
  || note "parse (missing in_scope): '$RP'"
RP="$(review_parse '{"verdict":"changes_requested","findings":[{"id":"I1","severity":"issue","in_scope":false},{"id":"S1","severity":"suggestion","in_scope":true}]}')"
[[ "$(jq -r '.verdict' <<<"$RP" 2>/dev/null)" == "approve" ]] \
  && ok "parse: out-of-scope issues and suggestions never block" \
  || note "parse (out of scope): '$RP'"
HB=abcdef0123456789abcdef0123456789abcdef01
RP="$(review_parse "$(printf 'Clean.\n```json\n{"verdict":"approve","findings":[],"head":"%s"}\n```\nThe format example is:\n```json\n{"verdict":"approve","findings":[{"id":"B1","severity":"blocker","in_scope":true}]}\n```\n' "$HB")" "$HB")"
[[ "$(jq -r '.verdict' <<<"$RP" 2>/dev/null)" == "approve" ]] \
  && ok "parse: with a head, only a block naming that head counts — a restated example is ignored" \
  || note "parse (example after the verdict): '$RP'"
review_parse "$(printf '```json\n{"verdict":"approve","findings":[],"head":"%s"}\n```\n' 1111111111111111111111111111111111111111)" "$HB" >/dev/null \
  && note "parse: a verdict for another head was accepted" \
  || ok "parse: a verdict naming a different head is no verdict"
FENCE_REPO="$WORK/fence"; mkdir -p "$FENCE_REPO"
( cd "$FENCE_REPO" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base \
  && printf 'doc\n~~~~~~~\ncode\n~~~~~~~\n' > f.md && git add f.md && git -c user.email=t@t -c user.name=t commit -q -m head )
FENCE_OUT="$(cd "$FENCE_REPO" && review_diff "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)")"
grep -qx '~~~~~~~~diff' <<<"$FENCE_OUT" \
  && ok "diff fence: longer than any tilde run in the diff (7 in the diff → 8)" \
  || note "diff fence: $(grep -m1 'diff$' <<<"$FENCE_OUT")"
# A removed line and an unchanged context line carrying tilde runs count too.
# f.md was doc / 7 tildes / code / 7 tildes; keep the first tilde line as
# context, drop the second, add no tilde line — only context and removed
# lines carry tildes, and the fence must still be 8.
( cd "$FENCE_REPO" && printf 'doc\n~~~~~~~\ncode changed\n' > f.md && git add f.md \
  && git -c user.email=t@t -c user.name=t commit -q -m head2 )
FENCE_OUT2="$(cd "$FENCE_REPO" && review_diff "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)")"
grep -q '^ ~~~~~~~$' <<<"$FENCE_OUT2" && grep -q '^-~~~~~~~$' <<<"$FENCE_OUT2" && ! grep -q '^+~' <<<"$FENCE_OUT2" \
  && grep -qx '~~~~~~~~diff' <<<"$FENCE_OUT2" \
  && ok "diff fence: context and removed tilde lines size it too (no added tildes; 7 → 8)" \
  || note "diff fence (removed/context): $(grep -m1 'diff$' <<<"$FENCE_OUT2")"
( cd "$FENCE_REPO" && printf 'plain\n' > g.txt && git add g.txt && git -c user.email=t@t -c user.name=t commit -q -m plain )
FENCE_OUT3="$(cd "$FENCE_REPO" && review_diff "$(git rev-parse HEAD~1)" "$(git rev-parse HEAD)")"
grep -qx '~~~~~diff' <<<"$FENCE_OUT3" \
  && ok "diff fence: a diff without tildes gets the 5-tilde default" \
  || note "diff fence (none): $(grep -m1 'diff$' <<<"$FENCE_OUT3")"
[[ "$(printf 'plain\n' | md_tilde_fence)" == "~~~~~" ]] \
  && [[ "$(printf 'x\n   ~~~~~~\n' | md_tilde_fence)" == "~~~~~~~" ]] \
  && [[ "$(printf '+  ~~~~~~\n' | md_tilde_fence)" == "~~~~~~~" ]] \
  && [[ "$(printf '~~~~~~~~~~~~\n' | md_tilde_fence)" == "~~~~~~~~~~~~~" ]] \
  && ok "md_tilde_fence: one longer than any run that could close it (indented up to 3, after a diff marker), floor 5" \
  || note "md_tilde_fence: $(printf 'x\n   ~~~~~~\n' | md_tilde_fence) / $(printf 'x\n    ~~~~~~~~~\n' | md_tilde_fence)"
review_parse 'Could you clarify?' >/dev/null && note "parse: prose was accepted as a verdict" \
  || ok "parse: prose without a JSON block is no verdict"
review_parse '{"verdict":"lgtm","findings":[]}' >/dev/null && note "parse: an off-contract verdict was accepted" \
  || ok "parse: a verdict other than approve/changes_requested is no verdict"
review_parse '{"verdict":"approve","findings":"none"}' >/dev/null && note "parse: non-array findings accepted" \
  || ok "parse: findings that are not an array are no verdict"

# ===========================================================================
# Unit: state.sh (#61 S1 — state.json, events.jsonl, status.json, cost sums)
# ===========================================================================
echo "-- state.sh"
ST="$WORK/state1"; mkdir -p "$ST"
state_init "$ST" 3 "integration/x" "run-1" "0.6.0"
jq -e '.map==3 and .base=="integration/x" and .run_id=="run-1" and .runner_version=="0.6.0" and .active_seconds==0 and (.issues=={})' "$ST/state.json" >/dev/null \
  && ok "state_init: run identity, active_seconds 0, an empty issues map" \
  || note "state_init: $(cat "$ST/state.json" 2>/dev/null)"
state_issue_update "$ST" 1 '{"state":"building","branch":"feat/1-x"}'
state_issue_update "$ST" 1 '{"round":1}'
jq -e '.issues["1"].state=="building" and .issues["1"].branch=="feat/1-x" and .issues["1"].round==1' "$ST/state.json" >/dev/null \
  && ok "state_issue_update: shallow-merges into one issue, keeping fields set by an earlier call" \
  || note "state_issue_update: $(jq -c .issues "$ST/state.json" 2>/dev/null)"
state_set_active_seconds "$ST" 42
[[ "$(jq -r .active_seconds "$ST/state.json")" == "42" ]] \
  && ok "state_set_active_seconds: updates the run-level field" || note "active_seconds not set"
state_event "$ST" 1 building ""
state_event "$ST" "" stopped "STOP file present"
EV2="$(sed -n 2p "$ST/events.jsonl")"
[[ "$(wc -l < "$ST/events.jsonl" | tr -d ' ')" -eq 2 ]] \
  && [[ "$(jq -r .issue <<<"$EV2")" == "null" ]] && [[ "$(jq -r .event <<<"$EV2")" == "stopped" ]] \
  && ok "state_event: appended, one row per transition; a run-level event carries no issue" \
  || note "events.jsonl: $(tr '\n' '|' < "$ST/events.jsonl")"
mkdir -p "$ST/issues/1"
printf '%s\n' '{"phase":"plan","cost_usd":1}' '{"phase":"build","cost_usd":2}' '{"phase":"iteration","cost_usd":99}' \
  > "$ST/issues/1/run-a.jsonl"
printf '%s\n' '{"phase":"review","cost_usd":4}' > "$ST/run-run-1.jsonl"
[[ "$(state_total_cost "$ST")" == "7" ]] \
  && ok "state_total_cost: sums the runner's own log and every issue's log, excluding phase:iteration" \
  || note "state_total_cost: $(state_total_cost "$ST")"
EMPTY="$WORK/state-empty"; mkdir -p "$EMPTY"
[[ "$(state_total_cost "$EMPTY")" == "0" ]] \
  && ok "state_total_cost: no logs on disk yet is 0, not an error" \
  || note "state_total_cost (empty): $(state_total_cost "$EMPTY")"
state_write_status "$ST" running 1 2 0 7 120
jq -e '.state=="running" and .current_issue==1 and .merged_count==2 and .parked_count==0 and .cost_usd==7 and .elapsed_s==120' "$ST/status.json" >/dev/null \
  && ok "state_write_status: the run's headline fields" || note "status.json: $(cat "$ST/status.json" 2>/dev/null)"
state_write_status "$ST" done "" 2 0 7 130
[[ "$(jq -r .current_issue "$ST/status.json")" == "null" ]] \
  && ok "state_write_status: no current issue writes null, not the empty string" \
  || note "status.json current_issue: $(jq .current_issue "$ST/status.json" 2>/dev/null)"
[[ "$(state_clip_num 5 10)" == "5" && "$(state_clip_num 10 5)" == "5" && "$(state_clip_num -1 5)" == "0" ]] \
  && ok "state_clip_num: min(remaining, requested); a negative remaining floors at 0" \
  || note "state_clip_num: $(state_clip_num 5 10)/$(state_clip_num 10 5)/$(state_clip_num -1 5)"

# ===========================================================================
# Unit: forge_grant_violations (ADR-0007 for --extra-allowed-tools)
# ===========================================================================
echo "-- forge_grant_violations"
GV_MISSED=0
for g in 'Bash' 'Bash(*)' 'Bash(:*)' 'Bash(gh:*)' 'Bash(git push:*)' 'Bash(git:*)' 'Bash(git  push origin x)' \
         'Bash(env gh:*)' 'Bash(/usr/bin/gh:*)' 'Bash(command gh:*)' 'Bash(env git push:*)' \
         'Bash(/usr/bin/git push:*)' 'Bash(/usr/bin/git:*)' 'Bash(command git push:*)' \
         'Bash(GH_HOST=x gh pr merge:*)' 'Bash(timeout 60 gh:*)' 'Bash(nohup env git push)' \
         'Bash(sh -c:*)' 'Bash(bash -c:*)' 'Bash(bash:*)' 'Bash(xargs:*)' 'Bash(eval:*)' \
         'Bash(find:*)' 'Bash(python3 -c:*)' 'Bash(gh *)' 'Bash(foo * bar)' 'Read, Bash , Grep' \
         'Bash("gh":*)' "Bash('git' push)" 'Bash(\gh:*)' 'Bash(g\h pr merge)' 'Bash($HOME/gh:*)' \
         'Bash(env -i gh:*)' 'Bash(env -u X gh)' 'Bash(nice -n 5 git push)' 'Bash(timeout -s KILL 5 gh:*)' \
         'Bash(exec -a x gh)' 'Bash(jq; gh pr merge)' 'Bash(jq && gh)' 'Bash(jq | gh)' 'Bash(`gh`)' \
         'Bash($(gh))' 'Bash(gh:*' 'Bash(GH=1 jq)' 'Bash(jq > /tmp/x)' \
         'Bash(GH:*)' 'Bash(Git push:*)' 'Bash(gh-dash:*)' 'Bash(glab push:*)' 'Bash(lab:*)' \
         'Bash(deno run:*)' 'Bash(deno eval:*)' 'Bash(deno run data:application/typescript,x%281%29:*)' \
         'Bash(npx gh:*)' 'Bash(npm exec gh:*)' 'Bash(pnpm dlx gh:*)' 'Bash(yarn dlx git push:*)' \
         'Bash(bunx gh:*)' 'Bash(corepack pnpm dlx gh:*)'; do
  forge_grant_violations "$g" >/dev/null && { note "grant '$g' was NOT refused"; GV_MISSED=1; }
done
[[ "$GV_MISSED" -eq 0 ]] && ok "refuses blanket, wildcard, quoted/escaped, wrapped, chained, redirected, malformed, gh/git (any case), package-runner grants (59 forms)"
GV_MISSED=0
for g in 'Bash(jq:*)' 'Bash(bash scripts/test-deliver.sh)' 'Bash(bash scripts/x.sh:*)' 'Read,Grep' \
         'Bash(shellcheck:*)' 'Bash(git-lfs:*)' 'Bash(python3 tools/gen.py)' 'Bash(printf a,b)' 'Bash(make test *)'; do
  forge_grant_violations "$g" >/dev/null || { note "grant '$g' was refused: $(forge_grant_violations "$g")"; GV_MISSED=1; }
done
[[ "$GV_MISSED" -eq 0 ]] && ok "allows ordinary tool grants and interpreters running a named script"
WHY="$(forge_grant_violations 'Bash(jq:*),Bash(/usr/bin/gh:*)')"
[[ "$WHY" == "Bash(/usr/bin/gh:*): runs gh"* && "$(grep -c . <<<"$WHY")" -eq 1 ]] \
  && ok "names exactly the offending rule and why" || note "reason was: $WHY"

# ===========================================================================
# Static: the forge surface (ADR-0007)
# ===========================================================================
echo "-- forge surface"
GH_CALLERS="$(grep -lE '(^|[;&|(]|[[:space:]])gh[[:space:]]+(issue|pr|api|repo|auth|label|run|release)([[:space:]]|$)' skills/deliver/*.sh skills/autopilot/*.sh 2>/dev/null | tr '\n' ' ')"
[[ "$GH_CALLERS" == "skills/deliver/forge.sh " ]] \
  && ok "only skills/deliver/forge.sh calls gh" \
  || note "gh is called outside forge.sh: $GH_CALLERS"
FORGE_USERS="$(grep -rlE '(\.|source)[[:space:]].*forge\.sh' skills agents hooks 2>/dev/null | tr '\n' ' ')"
[[ "$FORGE_USERS" == "skills/deliver/deliver.sh " ]] \
  && ok "only skills/deliver/deliver.sh sources forge.sh" \
  || note "forge.sh is sourced by: $FORGE_USERS"
grep -qE 'Bash\(gh|Bash\(git push' skills/autopilot/loop.sh \
  && note "a model phase in loop.sh is granted gh or git push" \
  || ok "no model phase in loop.sh is granted gh or git push"

# ===========================================================================
# End to end
# ===========================================================================
echo "-- deliver.sh end to end"
REAL_GIT="$(command -v git)"
BIN="$WORK/bin"; mkdir -p "$BIN"

# --- git shim: records every command the runner (and its children) run ------
cat > "$BIN/git" <<EOF
#!/usr/bin/env bash
[[ -n "\${GIT_CMD_LOG:-}" ]] && printf '%s\n' "\$*" >> "\$GIT_CMD_LOG"
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$BIN/git"

# --- fake gh ------------------------------------------------------------------
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
# Fake gh over $FAKE_GH_DIR/{issues,prs}/<n>.json. Implements the calls in
# skills/deliver/forge.sh, nothing more; anything else exits 64 so an
# unexpected call fails loudly instead of passing silently.
set -uo pipefail
S="${FAKE_GH_DIR:?}"
printf '%s\n' "$*" >> "$S/calls"
mkdir -p "$S/issues" "$S/prs"
# #61 S1: drop a STOP file into the run dir the moment it exists (the first
# real gh call happens after deliver.sh has already created it) — lets a
# test place STOP before the run's very first issue without knowing its
# dynamic run-id ahead of time.
if [[ -n "${FAKE_GH_TOUCH_STOP:-}" ]]; then
  rd="$(ls -d tmp/deliver/*/ 2>/dev/null | head -1)"
  [[ -n "$rd" ]] && : > "${rd}STOP"
fi
# Same, but only on the Nth (default: first) call whose argv starts with
# $FAKE_GH_STOP_ON (e.g. "pr checks": a STOP that lands during a CI wait).
if [[ -n "${FAKE_GH_STOP_ON:-}" && "$*" == "$FAKE_GH_STOP_ON"* && ! -f "$S/.stopped-on" ]]; then
  stop_seen="$(( $(cat "$S/.stop-on-count" 2>/dev/null || echo 0) + 1 ))"
  echo "$stop_seen" > "$S/.stop-on-count"
  if [[ "$stop_seen" -ge "${FAKE_GH_STOP_ON_NTH:-1}" ]]; then
    touch "$S/.stopped-on"
    rd="$(ls -d tmp/deliver/*/ 2>/dev/null | head -1)"
    [[ -n "$rd" ]] && : > "${rd}STOP"
  fi
fi
# #61 S3: simulate the runner being killed right after a PR exists — SIGKILL
# the deliver.sh pid (from the run's lock file) the moment a PR is on disk
# and this is not the "pr create" call itself, so the PR really was opened
# (and pr-open already recorded, since state_issue_update runs immediately
# after forge_pr_create returns, before deliver.sh's next gh call) and the
# kill lands synchronously, deterministically, before this call's own result
# reaches deliver.sh — leaving a stale lock behind, exactly as an external
# `kill -9` would.
if [[ -n "${FAKE_GH_KILL_AFTER_PR_OPEN:-}" && ! -f "$S/.killed-after-pr-open" && "$*" != "pr create"* ]]; then
  shopt -s nullglob; _prs=("$S"/prs/*.json); shopt -u nullglob
  if [[ ${#_prs[@]} -gt 0 ]]; then
    touch "$S/.killed-after-pr-open"
    rd="$(ls -d tmp/deliver/*/ 2>/dev/null | head -1)"
    if [[ -n "$rd" && -f "${rd}lock" ]]; then
      kill -9 "$(cat "${rd}lock" 2>/dev/null)" 2>/dev/null
      sleep 0.2
    fi
  fi
fi
arg() { # --flag value from "$@"
  local want="$1"; shift
  while [[ $# -gt 0 ]]; do [[ "$1" == "$want" ]] && { printf '%s' "$2"; return 0; }; shift; done
  return 1
}
has() { local want="$1"; shift; for a in "$@"; do [[ "$a" == "$want" ]] && return 0; done; return 1; }
next_num() {
  local max=0 f n
  for f in "$S"/issues/*.json "$S"/prs/*.json; do
    [[ -f "$f" ]] || continue; n="$(basename "$f" .json)"; (( n > max )) && max="$n"
  done
  echo $(( max + 1 ))
}
[[ "${1:-}" == "--version" ]] && { echo "gh version 2.60.0 (fake)"; exit 0; }
# Like real gh: with GH_CONFIG_DIR set to a dir holding no hosts.yml and no
# token in the environment, there is no one to be.
if [[ -n "${GH_CONFIG_DIR:-}" && ! -f "$GH_CONFIG_DIR/hosts.yml" && -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
  echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2
  printf 'UNAUTH %s\n' "$*" >> "$S/calls"
  exit 4
fi
cmd="${1:-} ${2:-}"; shift 2 2>/dev/null || true
case "$cmd" in
  "auth status") [[ -n "${FAKE_GH_UNAUTH:-}" ]] && exit 1; exit 0 ;;
  "issue view")
    f="$S/issues/$1.json"; [[ -f "$f" ]] || { echo "no issue $1" >&2; exit 1; }
    cat "$f" ;;
  "issue edit")
    f="$S/issues/$1.json"; [[ -f "$f" ]] || exit 1
    if b="$(arg --body-file "$@")"; then
      jq --rawfile body "$b" '.body = $body' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    elif l="$(arg --add-label "$@")"; then
      grep -qx "$l" "$S/labels" 2>/dev/null || { echo "could not add label: '$l' not found" >&2; exit 1; }
      jq --arg l "$l" '.labels = ((.labels // []) | map(select(.name != $l)) + [{name:$l}])' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    elif l="$(arg --remove-label "$@")"; then
      jq --arg l "$l" '.labels = ((.labels // []) | map(select(.name != $l)))' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    else exit 64; fi ;;
  "label create")
    grep -qx "$1" "$S/labels" 2>/dev/null && { echo "label already exists" >&2; exit 1; }
    echo "$1" >> "$S/labels" ;;
  "pr ready")
    f="$S/prs/$1.json"; [[ -f "$f" ]] || exit 1; has --undo "$@" || exit 64
    jq '.isDraft = true' "$f" > "$f.tmp" && mv "$f.tmp" "$f" ;;
  "pr close")
    f="$S/prs/$1.json"; [[ -f "$f" ]] || exit 1
    jq '.state="CLOSED"' "$f" > "$f.tmp" && mv "$f.tmp" "$f" ;;
  "issue comment")
    f="$S/issues/$1.json"; b="$(arg --body-file "$@")" || exit 64
    jq --rawfile body "$b" '.comments = ((.comments // []) + [{body:$body}])' "$f" > "$f.tmp" && mv "$f.tmp" "$f" ;;
  "pr create")
    base="$(arg --base "$@")"; head="$(arg --head "$@")"; title="$(arg --title "$@")"; b="$(arg --body-file "$@")" || exit 64
    oid="$(git ls-remote origin "refs/heads/$head" | cut -f1)"
    [[ -n "$oid" ]] || { echo "head branch $head not on remote" >&2; exit 1; }
    n="$(next_num)"
    jq -n --argjson n "$n" --arg base "$base" --arg head "$head" --arg title "$title" \
          --rawfile body "$b" --arg oid "$oid" \
       '{number:$n,state:"OPEN",baseRefName:$base,headRefName:$head,title:$title,body:$body,headRefOid:$oid}' \
       > "$S/prs/$n.json"
    echo "https://github.com/o/r/pull/$n" ;;
  "issue create")
    title="$(arg --title "$@")"; b="$(arg --body-file "$@")" || exit 64
    label="$(arg --label "$@")" || label=""
    if [[ -n "$label" ]]; then
      grep -qx "$label" "$S/labels" 2>/dev/null || { echo "could not add label: '$label' not found" >&2; exit 1; }
    fi
    n="$(next_num)"
    jq -n --argjson n "$n" --arg title "$title" --rawfile body "$b" --arg label "$label" \
       '{number:$n,title:$title,body:$body,state:"OPEN",url:("https://github.com/o/r/issues/" + ($n|tostring)),
         labels:(if $label=="" then [] else [{name:$label}] end),comments:[]}' \
       > "$S/issues/$n.json"
    echo "https://github.com/o/r/issues/$n" ;;
  "issue list")
    search="$(arg --search "$@")" || search=""
    jqexpr="$(arg --jq "$@")" || jqexpr=""
    matches="[]"
    for f in "$S"/issues/*.json; do
      [[ -f "$f" ]] || continue
      if [[ -z "$search" ]] || grep -qF "$search" "$f"; then
        matches="$(jq --argjson m "$matches" '. as $it | $m + [{number: $it.number}]' "$f")"
      fi
    done
    if [[ -n "$jqexpr" ]]; then printf '%s' "$matches" | jq -r "$jqexpr"; else printf '%s' "$matches"; fi ;;
  "pr view")
    f="$S/prs/$1.json"; [[ -f "$f" ]] || exit 1; cat "$f" ;;
  "pr list")
    head="$(arg --head "$@")"
    shopt -s nullglob; files=("$S"/prs/*.json); shopt -u nullglob
    if [[ ${#files[@]} -eq 0 ]]; then echo '[]'; else
      jq -n --arg h "$head" '[ inputs | select(.headRefName == $h) | {number, state} ]' "${files[@]}"
    fi ;;
  "pr edit")
    f="$S/prs/$1.json"; [[ -f "$f" ]] || exit 1
    b="$(arg --body-file "$@")" || exit 64
    jq --rawfile body "$b" '.body = $body' "$f" > "$f.tmp" && mv "$f.tmp" "$f" ;;
  "pr checks")
    n="$1"; f="$S/prs/$n.json"; [[ -f "$f" ]] || exit 1
    # A per-PR checks script at $S/ci/<n>: one JSON array of
    # {name,state,bucket,link} per line, one per poll — the last line
    # repeats once the script is exhausted. No script file at all: no
    # checks reported (ci_wait's "no CI" / grace path); like real gh,
    # nothing goes to stdout.
    script="$S/ci/$n"
    [[ -f "$script" ]] || { echo "no checks reported on the '$n' branch" >&2; exit 8; }
    cnt="$(( $(cat "$S/ci/$n.count" 2>/dev/null || echo 0) + 1 ))"
    echo "$cnt" > "$S/ci/$n.count"
    total="$(wc -l < "$script" | tr -d ' ')"
    [[ "$cnt" -gt "$total" ]] && cnt="$total"
    sed -n "${cnt}p" "$script" ;;
  "run view")
    # forge_ci_failed_log (#60): the fake run's log lives at $S/runs/<id>.log;
    # a run with no log on file (an id that never came from a /runs/ link in
    # a fixture's checks script) prints nothing, like a real run whose log
    # rotated away.
    id="$1"; shift; has --log-failed "$@" || exit 64
    f="$S/runs/$id.log"; [[ -f "$f" ]] && cat "$f"
    exit 0 ;;
  "pr comment")
    f="$S/prs/$1.json"; [[ -f "$f" ]] || exit 1; b="$(arg --body-file "$@")" || exit 64
    jq --rawfile body "$b" '.comments = ((.comments // []) + [{body:$body}])' "$f" > "$f.tmp" && mv "$f.tmp" "$f" ;;
  "pr merge")
    n="$1"; shift; f="$S/prs/$n.json"; [[ -f "$f" ]] || exit 1
    if has --squash "$@"; then strategy=squash
    elif has --merge "$@"; then strategy=merge
    else echo "fake gh: only --squash or --merge is modelled" >&2; exit 64
    fi
    has --admin "$@" && { echo "fake gh: --admin used" >&2; exit 65; }
    sha="$(arg --match-head-commit "$@")"; subject="$(arg --subject "$@")"; b="$(arg --body-file "$@")"
    # A repo mode: --squash is always refused (branch protection forbids it);
    # forge_pr_merge is expected to notice and fall back to --merge itself.
    if [[ "$strategy" == squash && -f "$S/no_squash" ]]; then
      echo "GraphQL: Squash merges are not allowed on this repository" >&2; exit 1
    fi
    # A one-shot refusal: the first pr-merge call (whatever its strategy)
    # fails, the next one succeeds — deliver.sh's final-verify retry.
    if [[ -n "${FAKE_GH_MERGE_REFUSE_ONCE:-}" && ! -f "$S/.merge_refused_once" ]]; then
      touch "$S/.merge_refused_once"
      echo "merge refused (fake, once)" >&2; exit 1
    fi
    base="$(jq -r .baseRefName "$f")"; head="$(jq -r .headRefName "$f")"
    remote="$(git remote get-url origin)"
    tmp="$(mktemp -d)"
    git clone -q "$remote" "$tmp/c" || exit 1
    cur="$(git -C "$tmp/c" rev-parse "origin/$head")"
    if [[ -n "$sha" && "$cur" != "$sha" ]]; then
      echo "Head branch was modified. Review and try the merge again." >&2; rm -rf "$tmp"; exit 1
    fi
    [[ -n "${FAKE_GH_MERGE_FAIL:-}" ]] && { echo "merge refused (fake)" >&2; rm -rf "$tmp"; exit 1; }
    ( cd "$tmp/c" && git -c advice.detachedHead=false checkout -q "$base" \
        && if [[ "$strategy" == squash ]]; then
             git merge -q --squash "origin/$head" >/dev/null \
               && git -c user.email=gh@fake -c user.name=fake-gh commit -q -m "$subject" -m "$(cat "${b:-/dev/null}")"
           else
             git -c user.email=gh@fake -c user.name=fake-gh merge -q --no-ff -m "$subject" "origin/$head" >/dev/null
           fi \
        && git push -q origin "$base" ) || { rm -rf "$tmp"; exit 1; }
    moid="$(git -C "$tmp/c" rev-parse HEAD)"; rm -rf "$tmp"
    if [[ -n "${FAKE_GH_AFTER_FIRST_MERGE_BODY:-}" && ! -f "$S/.edited" ]]; then
      touch "$S/.edited"
      jq --arg l "$FAKE_GH_AFTER_FIRST_MERGE_BODY" '.body |= sub("## Notes"; ($l + "\n\n## Notes"))' \
        "$S/issues/3.json" > "$S/issues/3.json.tmp" && mv "$S/issues/3.json.tmp" "$S/issues/3.json"
    fi
    jq --arg m "$moid" '.state="MERGED" | .mergeCommit={oid:$m}' "$f" > "$f.tmp" && mv "$f.tmp" "$f" ;;
  *) echo "fake gh: unsupported call: $cmd $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$BIN/gh"

# --- stub claude: autopilot's three phases -----------------------------------
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
prompt="$*"
plan="$(printf '%s' "$prompt" | grep -oE '[^[:space:],"]*IMPLEMENTATION_PLAN\.md' | head -1)"
emit() { printf '{"result":%s,"total_cost_usd":0.01,"usage":{"input_tokens":0,"output_tokens":0}}\n' "$1"; }
review_json() { # verdict findings-json [head]
  printf 'Report: looked at the diff.\n\n```json\n{"verdict":"%s","findings":%s,"resolved":[],"head":"%s"}\n```\n' "$1" "$2" "${3-$head}"
}
head="$(printf '%s' "$prompt" | grep -oE 'Head: `[0-9a-f]{40}`' | head -1 | tr -d '`' | cut -d' ' -f2)"
common_root() { cd "$(git rev-parse --git-common-dir)/.." && pwd; }
case "$prompt" in
  *"# Agent: code-reviewer"*)
    if [[ -n "${STUB_REVIEW_LOG:-}" ]]; then
      tools=""; dis=""; perm=""; prev=""
      for a in "$@"; do
        case "$prev" in --allowedTools) tools="$a" ;; --disallowedTools) dis="$a" ;; --permission-mode) perm="$a" ;; esac
        prev="$a"
      done
      inl=no; [[ "$prompt" == *"### Diff"* && "$prompt" == *"+++ b/work/issue-"* ]] && inl=yes
      printf '%s\t%s\t%s\t%s\t%s\n' "$(pwd)" "$tools" "$dis" "$perm" "$inl" >> "$STUB_REVIEW_LOG"
    fi
    if [[ -n "${STUB_REVIEW_PROMPT_DIR:-}" ]]; then
      mkdir -p "$STUB_REVIEW_PROMPT_DIR"
      printf '%s' "$prompt" > "$STUB_REVIEW_PROMPT_DIR/$(date +%s%N)-$$-$RANDOM.txt"
    fi
    mode="${STUB_REVIEW:-approve}"
    if [[ "$mode" == "garbage-once" ]]; then
      if [[ -f "${STUB_REVIEW_STATE:?}" ]]; then mode=approve; else touch "$STUB_REVIEW_STATE"; mode=garbage; fi
    fi
    if [[ "$mode" == "blocker-once" ]]; then
      if [[ -f "${STUB_REVIEW_STATE:?}" ]]; then mode=approve; else touch "$STUB_REVIEW_STATE"; mode=blocker; fi
    fi
    case "$mode" in
      approve)    r="$(review_json approve '[{"id":"S1","severity":"suggestion","file":"a","line":1,"note":"nit","in_scope":true}]')" ;;
      blocker)    r="$(review_json changes_requested '[{"id":"B1","severity":"blocker","file":"a","line":1,"note":"broken","in_scope":true}]')" ;;
      liar)       r="$(review_json approve '[{"id":"I1","severity":"issue","file":"a","line":1,"note":"real problem","in_scope":true}]')" ;;
      outofscope) # Worded differently on every call, as a fresh reviewer would.
                  r="$(review_json approve "[{\"id\":\"I1\",\"severity\":\"issue\",\"file\":\"b\",\"line\":9,\"note\":\"old bug, take $$-$RANDOM\",\"in_scope\":false,\"issue_title\":\"fix: old bug\"}]")" ;;
      garbage)    r="I would need more context to review this. Could you clarify the scope?" ;;
      mutate)     ( cd "$(common_root)" && git switch -q -c scratch-by-reviewer )
                  r="$(review_json approve '[]')" ;;
      mutate-ref) ( cd "$(common_root)" && git update-ref refs/heads/integration/x "$(git rev-parse HEAD~0^{commit})" "$(git rev-parse integration/x)" 2>/dev/null \
                      || git update-ref refs/remotes/origin/integration/x "$(git rev-parse HEAD)" )
                  r="$(review_json approve '[]')" ;;
      mutate-tmp) ( cd "$(common_root)" && for f in tmp/deliver/*/issues/*/PROMPT.md; do echo "injected" >> "$f"; done )
                  r="$(review_json approve '[]')" ;;
      mutate-hook) printf '#!/bin/sh\nexit 0\n' > "$(git rev-parse --git-common-dir)/hooks/pre-push"
                  r="$(review_json approve '[]')" ;;
      example-after)
                  r="$(review_json approve '[]')
As required, the format example is:
$(review_json changes_requested '[{"id":"B1","severity":"blocker","file":"src/a.ts","line":42,"note":"example","in_scope":true}]' "")" ;;
      wrong-head) r="$(review_json approve '[]' 0000000000000000000000000000000000000000)" ;;
    esac
    printf '{"result":%s,"total_cost_usd":0.02,"usage":{"input_tokens":0,"output_tokens":0}}\n' "$(printf '%s' "$r" | jq -Rs .)"
    exit 0 ;;
  *"PLAN phase"*|*"autonomous run is stuck"*)
    if [[ "${STUB_PLAN_SLICES:-1}" == "2" ]]; then
      printf -- '- [ ] S1 — part one\n- [ ] S2 — part two (after: S1)\n\nSTATUS: in-progress\n' > "$plan"
    else
      printf -- '- [ ] S1 — the work\n\nSTATUS: in-progress\n' > "$plan"
    fi
    emit '"planned"' ;;
  *"ONE iteration of an autonomous BUILD loop"*)
    [[ -n "${STUB_BUILD_SLEEP:-}" ]] && sleep "$STUB_BUILD_SLEEP"
    # Simulate a concurrent push to the integration branch, mid-build, so
    # final_verify meets a base that moved (#60): a separate clone commits
    # to $STUB_ADVANCE_BASE_PATH and pushes it straight to origin/integration/x,
    # once (a marker file, since BUILD can run more than once per issue).
    if [[ -n "${STUB_ADVANCE_BASE_PATH:-}" && -n "${STUB_ADVANCE_BASE_MARKER:-}" && ! -f "$STUB_ADVANCE_BASE_MARKER" ]]; then
      touch "$STUB_ADVANCE_BASE_MARKER"
      adv_remote="$(git remote get-url origin 2>/dev/null)"
      if [[ -n "$adv_remote" ]]; then
        adv_tmp="$(mktemp -d)"
        ( cd "$adv_tmp" && git clone -q "$adv_remote" c 2>/dev/null \
            && cd c && git switch -q integration/x \
            && mkdir -p "$(dirname "$STUB_ADVANCE_BASE_PATH")" \
            && printf 'advanced by someone else\n' > "$STUB_ADVANCE_BASE_PATH" \
            && git add "$STUB_ADVANCE_BASE_PATH" \
            && git -c user.email=other@test.est -c user.name=other commit -q -m "advance base" \
            && git push -q origin integration/x ) >/dev/null 2>&1
        rm -rf "$adv_tmp"
      fi
    fi
    # A BUILD that tries the forge itself (ADR-0007): record what happened.
    if [[ -n "${STUB_FORGE_PROBE:-}" ]]; then
      gh auth status >/dev/null 2>&1; echo "gh=$?" >> "$STUB_FORGE_PROBE"
      echo "helper=[$(git config --get-all credential.helper | tail -1)]" >> "$STUB_FORGE_PROBE"
      echo "token=${GH_TOKEN-<unset>}" >> "$STUB_FORGE_PROBE"
    fi
    [[ -n "${STUB_TURNS_LOG:-}" ]] && { grep -oE -- '--max-turns [0-9]+' <<<"$*" >> "$STUB_TURNS_LOG" || true; }
    if [[ -n "${STUB_BUILD_LOG:-}" ]]; then
      prev=""; for a in "$@"; do [[ "$prev" == "--allowedTools" ]] && printf '%s\n' "$a" >> "$STUB_BUILD_LOG"; prev="$a"; done
    fi
    n="$(printf '%s' "$plan" | grep -oE 'issues/[0-9]+' | cut -d/ -f2)"
    if [[ "${STUB_MODE:-progress}" == "progress" && ",${STUB_STALL_ISSUES:-}," != *",$n,"* ]]; then
      sel="$(printf '%s' "$prompt" | grep -oE 'plan item `[^`]+`' | head -1 | sed -E 's/plan item `([^`]+)`/\1/')"
      # A STOP that lands while BUILD works on plan item $STUB_STOP_ON_SLICE
      # (once): the item still gets built and committed, the run stops after.
      if [[ -n "${STUB_STOP_ON_SLICE:-}" && "$sel" == "$STUB_STOP_ON_SLICE" && ! -f "${STUB_STOP_MARKER:?}" ]]; then
        touch "$STUB_STOP_MARKER"
        stop_rd="$(ls -d tmp/deliver/*/ 2>/dev/null | head -1)"
        [[ -n "$stop_rd" ]] && : > "${stop_rd}STOP"
      fi
      [[ ",${STUB_NOWORK_ISSUES:-}," == *",$n,"* ]] || { mkdir -p work && echo "issue $n slice $sel" >> "work/issue-$n.txt"; }
      awk -v id="$sel" 'BEGIN{d=0} { if (!d && $0 ~ ("^- \\[ \\] " id "([[:space:]]|$)")) { sub(/^- \[ \]/, "- [x]"); d=1 } print }' \
        "$plan" > "$plan.tmp" && mv "$plan.tmp" "$plan"
      grep -q '^- \[ \]' "$plan" || sed -i 's/^STATUS: in-progress/STATUS: done/' "$plan"
    fi
    emit '"built"' ;;
  *) emit '"{\"pass\": true}"' ;;
esac
EOF
chmod +x "$BIN/claude"

# new_fixture <name>
#   $WORK/<name>/{remote.git,repo,gh,state}: a bare remote with main and
#   integration/x, a clone on integration/x, and a fake-gh store holding
#   issues #1 (feature), #2 (bug, after #1) and map #3.
new_fixture() {
  local d="$WORK/$1" with4="${2:-}"
  mkdir -p "$d/gh/issues" "$d/state"
  git init -q --bare --initial-branch=main "$d/remote.git"
  git clone -q "$d/remote.git" "$d/repo" 2>/dev/null
  git -C "$d/repo" config user.email t@t.est
  git -C "$d/repo" config user.name test
  printf 'tmp/\n' > "$d/repo/.gitignore"
  printf '# app\n' > "$d/repo/README.md"
  git -C "$d/repo" add -A && git -C "$d/repo" commit -q -m init
  git -C "$d/repo" push -q origin HEAD:main 2>/dev/null
  git -C "$d/repo" switch -q -c integration/x
  git -C "$d/repo" push -q -u origin integration/x 2>/dev/null
  jq -n '{number:1,title:"First feature",url:"https://github.com/o/r/issues/1",state:"OPEN",
          labels:[{name:"ready-for-agent"}],comments:[],
          body:"## What to build\nAdd the first thing.\n\n## Acceptance criteria\n- [ ] first works\n\n## Blocked by\nNone"}' \
     > "$d/gh/issues/1.json"
  jq -n '{number:2,title:"Second thing",url:"https://github.com/o/r/issues/2",state:"OPEN",
          labels:[{name:"ready-for-agent"},{name:"bug"}],comments:[],
          body:"## What to build\nFix the second thing.\n\n## Acceptance criteria\n- [ ] second works\n\n## Blocked by\n- #1"}' \
     > "$d/gh/issues/2.json"
  jq -n --rawfile body <(printf '<!-- deliver:map v1 -->\nTest map.\n\n## Delivery\n- [ ] #2 Second thing (after: #1)\n- [ ] #1 feat(a): first feature\n\n## Notes\nnothing\n') \
     '{number:3,title:"Map: test",url:"https://github.com/o/r/issues/3",state:"OPEN",labels:[{name:"map"}],comments:[],body:$body}' \
     > "$d/gh/issues/3.json"
  printf 'map\nready-for-agent\nbug\n' > "$d/gh/labels"
  if [[ "$with4" == "with4" ]]; then
    # #4 is independent of #1/#2 — it must still merge when #1 is parked.
    jq -n '{number:4,title:"Independent thing",url:"https://github.com/o/r/issues/4",state:"OPEN",
            labels:[{name:"ready-for-agent"}],comments:[],
            body:"## What to build\nAn unrelated thing.\n\n## Acceptance criteria\n- [ ] it works"}' \
       > "$d/gh/issues/4.json"
    jq '.body |= sub("## Notes"; "- [ ] #4 feat: independent thing\n\n## Notes")' "$d/gh/issues/3.json" > "$d/x" \
      && mv "$d/x" "$d/gh/issues/3.json"
  fi
}

# run_deliver <name> [extra env as VAR=value...] -- [deliver args...]
run_deliver() {
  local name="$1"; shift
  local d="$WORK/$name" envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  ( cd "$d/repo" && env PATH="$BIN:$PATH" FAKE_GH_DIR="$d/gh" XDG_STATE_HOME="$d/state" \
      GIT_CMD_LOG="$d/git.calls" ${envs[@]+"${envs[@]}"} \
      bash "$DELIVER_ABS" --map 3 --verify-cmd true --issue-max-iterations 1 \
        --ci-poll-seconds 0 --ci-grace-seconds 0 "$@" \
      >"$d/out" 2>"$d/err" )
}


# path_without <dir> <tool>... — a PATH directory holding every executable of
# the current PATH except the named tools (the test bin's shims included).
path_without() {
  local out="$1" p f b skip; shift
  mkdir -p "$out"
  local IFS=:
  for p in $BIN:$PATH; do
    [[ -d "$p" ]] || continue
    for f in "$p"/*; do
      b="${f##*/}"; skip=0
      for t in "$@"; do [[ "$b" == "$t" ]] && skip=1; done
      [[ "$skip" -eq 1 || -e "$out/$b" || ! -x "$f" ]] && continue
      ln -s "$f" "$out/$b"
    done
  done
}

# parked_one <name> — issue #1 is parked: labelled needs-human (and no longer
# ready-for-agent), one comment saying it was parked, the Map unticked.
parked_one() {
  local d="$WORK/$1"
  [[ "$(jq -r '[.labels[].name] | sort | join(",")' "$d/gh/issues/1.json")" == "needs-human" ]] \
    && jq -r '.comments[-1].body' "$d/gh/issues/1.json" | grep -q '^\*\*Parked by `/deliver`\*\*' \
    && [[ "$(jq -r .body "$d/gh/issues/3.json")" == *"- [ ] #1 "* ]]
}
# held <name> — #1 got as far as PR #4, which is now a draft, unmerged; #1 is
# parked, #2 (after #1) was skipped, integration/x is untouched, and the
# checkout is back on integration/x, clean.
held() {
  local d="$WORK/$1"
  [[ "$(jq -r .state "$d/gh/prs/4.json" 2>/dev/null)" == "OPEN" ]] \
    && [[ "$(jq -r .isDraft "$d/gh/prs/4.json" 2>/dev/null)" == "true" ]] \
    && ! grep -q '^pr merge' "$d/gh/calls" \
    && parked_one "$1" \
    && [[ ! -f "$d/gh/prs/5.json" ]] \
    && [[ "$(git -C "$d/remote.git" rev-parse integration/x)" == "$(git -C "$d/remote.git" rev-parse main)" ]] \
    && [[ "$(git -C "$d/repo" branch --show-current)" == "integration/x" && -z "$(git -C "$d/repo" status --porcelain)" ]]
}

EXTRABAD_VALUES=('Bash' 'Bash(env gh:*)' 'Read, Bash(/usr/bin/git  push origin x)')
PCTBAD_VALUES=(1.5 0)

# ===========================================================================
# Fixture jobs run in parallel, capped at $TEST_DELIVER_JOBS (default:
# nproc), so the wall time below is the slowest single fixture, not the sum
# of all of them. Every fixture already lives under its own $WORK/<name>/
# (remote, repo, gh store, XDG state — see new_fixture/run_deliver above),
# and the git/gh/claude shims log to per-fixture STUB_*_LOG/STATE paths, so
# no job touches another job's state; the only thing a job produces that the
# assertions below need is its exit code, written to $WORK/<name>/rc since a
# background job's $? does not reach the parent shell.
#
# The park fixture's two reruns are a genuine exception: they mutate and
# re-read the same $WORK/park/ state the first park job left behind, so they
# stay foreground calls placed after the initial `wait`, not jobs.
# ===========================================================================
JOBS_CAP="${TEST_DELIVER_JOBS:-$(nproc 2>/dev/null || echo 4)}"
[[ "$JOBS_CAP" =~ ^[0-9]+$ && "$JOBS_CAP" -ge 1 ]] || JOBS_CAP=4
bg() { # bg <job-fn> [args...] — semaphore over background jobs via wait -n
  while [[ "$(jobs -pr | wc -l)" -ge "$JOBS_CAP" ]]; do wait -n 2>/dev/null || break; done
  "$@" &
}

job_happy() {
  new_fixture happy
  git -C "$WORK/happy/remote.git" rev-parse main > "$WORK/happy/main_before"
  run_deliver happy STUB_REVIEW_LOG="$WORK/happy/review.log"
  echo $? > "$WORK/happy/rc"
}
job_extra() {
  new_fixture extra
  run_deliver extra STUB_BUILD_LOG="$WORK/extra/build.log" STUB_REVIEW_LOG="$WORK/extra/review.log" -- --extra-allowed-tools 'Bash(jq:*),Bash(bash scripts/x.sh)'
  echo $? > "$WORK/extra/rc"
}
job_extrabad() { # <index> <grant>
  local name="extrabad$1"
  new_fixture "$name"
  run_deliver "$name" -- --extra-allowed-tools "$2"
  echo $? > "$WORK/$name/rc"
}
job_nocreds() {
  new_fixture nocreds
  run_deliver nocreds GH_TOKEN=runner-token STUB_FORGE_PROBE="$WORK/nocreds/probe" -- \
    --verify-cmd "gh auth status >/dev/null 2>&1; echo verify-gh=\$? >> '$WORK/nocreds/probe'; true"
  echo $? > "$WORK/nocreds/rc"
}
job_pct() {
  new_fixture pct
  run_deliver pct STUB_BUILD_SLEEP=4 -- --per-call-timeout 2 --issue-max-iterations 1
  echo $? > "$WORK/pct/rc"
}
job_pctbad() { # <index> <seconds>
  local name="pctbad$1"
  new_fixture "$name"
  run_deliver "$name" -- --per-call-timeout "$2"
  echo $? > "$WORK/$name/rc"
}
job_pace() {
  new_fixture pace
  run_deliver pace STUB_PLAN_SLICES=2 -- --issue-max-iterations 2 --verify-cmd "echo v >> '$WORK/pace/count'"
  echo $? > "$WORK/pace/rc"
}
job_paceall() {
  new_fixture paceall
  run_deliver paceall STUB_PLAN_SLICES=2 -- --issue-max-iterations 2 --verify-cmd "echo v >> '$WORK/paceall/count'" --verify-every-iteration
  echo $? > "$WORK/paceall/rc"
}
job_pacebad() {
  new_fixture pacebad
  run_deliver pacebad -- --verify-every-iteration --iteration-verify-cmd true
  echo $? > "$WORK/pacebad/rc"
}
job_onmain() {
  new_fixture onmain
  git -C "$WORK/onmain/repo" switch -q main
  run_deliver onmain
  echo $? > "$WORK/onmain/rc"
}
job_dirty() {
  new_fixture dirty
  echo junk > "$WORK/dirty/repo/untracked.txt"
  run_deliver dirty
  echo $? > "$WORK/dirty/rc"
}
job_nomap() {
  new_fixture nomap
  jq '.body = "no delivery section here"' "$WORK/nomap/gh/issues/3.json" > "$WORK/nomap/x" && mv "$WORK/nomap/x" "$WORK/nomap/gh/issues/3.json"
  run_deliver nomap
  echo $? > "$WORK/nomap/rc"
}
job_behind() {
  new_fixture behind
  git -C "$WORK/behind/repo" commit -q --allow-empty -m "local only"
  run_deliver behind
  echo $? > "$WORK/behind/rc"
}
job_notool() { # <tool>
  local tool="$1"
  new_fixture "no$tool"
  path_without "$WORK/no$tool/bin" "$tool"
  ( cd "$WORK/no$tool/repo" && env PATH="$WORK/no$tool/bin" FAKE_GH_DIR="$WORK/no$tool/gh" \
      XDG_STATE_HOME="$WORK/no$tool/state" \
      "$(command -v bash)" "$DELIVER_ABS" --map 3 --verify-cmd true >"$WORK/no$tool/out" 2>"$WORK/no$tool/err" )
  echo $? > "$WORK/no$tool/rc"
}
job_unauth() {
  new_fixture unauth
  run_deliver unauth FAKE_GH_UNAUTH=1
  echo $? > "$WORK/unauth/rc"
}
job_midedit() {
  new_fixture midedit
  run_deliver midedit FAKE_GH_AFTER_FIRST_MERGE_BODY='- [ ] #2 Second thing (after: #1)' --
  echo $? > "$WORK/midedit/rc"
}
job_park() {
  new_fixture park with4
  run_deliver park STUB_STALL_ISSUES=1 -- --issue-max-iterations 2
  echo $? > "$WORK/park/rc"
}
job_park2() {
  new_fixture park2
  echo needs-human >> "$WORK/park2/gh/labels"
  run_deliver park2 STUB_STALL_ISSUES=1 -- --issue-max-iterations 2
  echo $? > "$WORK/park2/rc"
}
job_parklate() {
  new_fixture parklate with4
  git -C "$WORK/parklate/repo" branch feat/4-independent-thing
  run_deliver parklate
  echo $? > "$WORK/parklate/rc"
}
job_parkverify() {
  new_fixture parkverify
  run_deliver parkverify -- --verify-cmd '! git log -1 --format=%s | grep -q "(green)"'
  echo $? > "$WORK/parkverify/rc"
}
job_parknowork() {
  new_fixture parknowork
  run_deliver parknowork STUB_NOWORK_ISSUES=1
  echo $? > "$WORK/parknowork/rc"
}
job_rvblock()   { new_fixture rvblock;    run_deliver rvblock    STUB_REVIEW=blocker;                                                  echo $? > "$WORK/rvblock/rc"; }
job_rvliar()    { new_fixture rvliar;     run_deliver rvliar     STUB_REVIEW=liar;                                                     echo $? > "$WORK/rvliar/rc"; }
# --- fix rounds (#63) ---------------------------------------------------------
job_rvblockonce() {
  new_fixture rvblockonce
  run_deliver rvblockonce STUB_REVIEW=blocker-once STUB_REVIEW_STATE="$WORK/rvblockonce/review.state" \
    STUB_REVIEW_PROMPT_DIR="$WORK/rvblockonce/prompts"
  echo $? > "$WORK/rvblockonce/rc"
}
job_rvblockrounds2() {
  new_fixture rvblockrounds2
  run_deliver rvblockrounds2 STUB_REVIEW=blocker -- --max-fix-rounds 1
  echo $? > "$WORK/rvblockrounds2/rc"
}
job_rvblockrounds1() {
  new_fixture rvblockrounds1
  run_deliver rvblockrounds1 STUB_REVIEW=blocker -- --max-fix-rounds 0
  echo $? > "$WORK/rvblockrounds1/rc"
}
job_rvoos()     { new_fixture rvoos;      run_deliver rvoos      STUB_REVIEW=outofscope;                                               echo $? > "$WORK/rvoos/rc"; }
job_rvgarbage() { new_fixture rvgarbage;  run_deliver rvgarbage  STUB_REVIEW=garbage STUB_REVIEW_LOG="$WORK/rvgarbage/review.log";      echo $? > "$WORK/rvgarbage/rc"; }
job_rvretry()   { new_fixture rvretry;    run_deliver rvretry    STUB_REVIEW=garbage-once STUB_REVIEW_STATE="$WORK/rvretry/review.state"; echo $? > "$WORK/rvretry/rc"; }
job_rvmutate()  { new_fixture rvmutate;   run_deliver rvmutate   STUB_REVIEW=mutate;                                                    echo $? > "$WORK/rvmutate/rc"; }
job_rvmutatevariant() { # <mutate-ref|mutate-tmp|mutate-hook>
  local m="$1" name="rv$1"
  new_fixture "$name"
  run_deliver "$name" STUB_REVIEW="$m"
  echo $? > "$WORK/$name/rc"
}
job_rvexample()   { new_fixture rvexample;   run_deliver rvexample   STUB_REVIEW=example-after; echo $? > "$WORK/rvexample/rc"; }
job_rvwronghead() { new_fixture rvwronghead; run_deliver rvwronghead STUB_REVIEW=wrong-head;     echo $? > "$WORK/rvwronghead/rc"; }
job_refused() {
  new_fixture refused
  run_deliver refused FAKE_GH_MERGE_FAIL=1
  echo $? > "$WORK/refused/rc"
}
job_stopfile() {
  new_fixture stopfile
  run_deliver stopfile FAKE_GH_TOUCH_STOP=1
  echo $? > "$WORK/stopfile/rc"
}
job_budget() {
  new_fixture budget
  run_deliver budget -- --budget-usd 0.06
  echo $? > "$WORK/budget/rc"
}

# --- #61 S3: --resume / --retry ------------------------------------------------
job_killresume() {
  new_fixture killresume
  run_deliver killresume FAKE_GH_KILL_AFTER_PR_OPEN=1
  echo $? > "$WORK/killresume/rc1"
  run_deliver killresume STUB_REVIEW_LOG="$WORK/killresume/review.log" -- --resume
  echo $? > "$WORK/killresume/rc"
}
job_budgetresume() {
  new_fixture budgetresume
  run_deliver budgetresume -- --budget-usd 0.06
  echo $? > "$WORK/budgetresume/rc1"
  run_deliver budgetresume -- --resume --budget-usd 100
  echo $? > "$WORK/budgetresume/rc"
}
job_stopresume() {
  new_fixture stopresume
  run_deliver stopresume FAKE_GH_TOUCH_STOP=1
  echo $? > "$WORK/stopresume/rc1"
  run_deliver stopresume -- --resume
  echo $? > "$WORK/stopresume/rc"
}
job_locklive() {
  new_fixture locklive
  local d="$WORK/locklive"
  sleep 60 & local holder=$!
  mkdir -p "$d/repo/tmp/deliver/fakerun-live"
  jq -n --argjson map 3 --arg base integration/x --arg run_id fakerun-live --arg version 0.0.0 \
     '{run_id:$run_id, map:$map, base:$base, runner_version:$version, active_seconds:0, issues:{}}' \
     > "$d/repo/tmp/deliver/fakerun-live/state.json"
  echo "$holder" > "$d/repo/tmp/deliver/fakerun-live/lock"
  run_deliver locklive -- --resume
  echo $? > "$d/rc"
  kill "$holder" 2>/dev/null
}
job_lockstale() {
  new_fixture lockstale
  local d="$WORK/lockstale"
  ( exit 0 ) & local deadpid=$!
  wait "$deadpid" 2>/dev/null
  mkdir -p "$d/repo/tmp/deliver/fakerun-stale"
  jq -n --argjson map 3 --arg base integration/x --arg run_id fakerun-stale --arg version 0.0.0-test \
     '{run_id:$run_id, map:$map, base:$base, runner_version:$version, active_seconds:7, issues:{}}' \
     > "$d/repo/tmp/deliver/fakerun-stale/state.json"
  echo "$deadpid" > "$d/repo/tmp/deliver/fakerun-stale/lock"
  run_deliver lockstale -- --resume
  echo $? > "$d/rc"
}
job_retry() {
  new_fixture retry with4
  run_deliver retry STUB_STALL_ISSUES=1 -- --issue-max-iterations 2
  echo $? > "$WORK/retry/rc1"
  run_deliver retry -- --resume --retry '#1'
  echo $? > "$WORK/retry/rc"
}
job_stopfixresume() {
  # A STOP while BUILD works on review fix item R1.1; --resume must finish
  # that fix round (not redo it, not skip it, not spend a second round).
  new_fixture stopfix
  run_deliver stopfix STUB_REVIEW=blocker-once STUB_REVIEW_STATE="$WORK/stopfix/review.state" \
    STUB_STOP_ON_SLICE=R1.1 STUB_STOP_MARKER="$WORK/stopfix/stop.marker"
  echo $? > "$WORK/stopfix/rc1"
  cp "$(ls -d "$WORK"/stopfix/repo/tmp/deliver/*/ | head -1)state.json" "$WORK/stopfix/state1.json" 2>/dev/null
  run_deliver stopfix STUB_REVIEW=blocker-once STUB_REVIEW_STATE="$WORK/stopfix/review.state" -- --resume
  echo $? > "$WORK/stopfix/rc"
}
job_stopciresume() {
  # A STOP during the CI wait (after an approving review): --resume goes
  # straight back to CI and the merge — no second review call.
  new_fixture stopci
  run_deliver stopci FAKE_GH_STOP_ON="pr checks" STUB_REVIEW_LOG="$WORK/stopci/review.log"
  echo $? > "$WORK/stopci/rc1"
  run_deliver stopci STUB_REVIEW_LOG="$WORK/stopci/review.log" -- --resume
  echo $? > "$WORK/stopci/rc"
}
job_stopcifixresume() {
  # A STOP while BUILD works on CI fix item C1 (CI red, then green): --resume
  # must finish that CI fix round — no second round, C1 once, then merge.
  new_fixture stopcifix
  mkdir -p "$WORK/stopcifix/gh/ci" "$WORK/stopcifix/gh/runs"
  printf '%s\n%s\n' \
    '[{"name":"build","state":"FAILURE","bucket":"fail","link":"https://github.com/o/r/actions/runs/556/job/1"}]' \
    '[{"name":"build","state":"SUCCESS","bucket":"pass","link":"https://github.com/o/r/actions/runs/556/job/1"}]' \
    > "$WORK/stopcifix/gh/ci/4"
  printf 'Error: red\n' > "$WORK/stopcifix/gh/runs/556.log"
  run_deliver stopcifix STUB_STOP_ON_SLICE=C1 STUB_STOP_MARKER="$WORK/stopcifix/stop.marker" -- --issue-max-iterations 2
  echo $? > "$WORK/stopcifix/rc1"
  cp "$(ls -d "$WORK"/stopcifix/repo/tmp/deliver/*/ | head -1)state.json" "$WORK/stopcifix/state1.json" 2>/dev/null
  run_deliver stopcifix STUB_REVIEW_LOG="$WORK/stopcifix/review.log" -- --resume --issue-max-iterations 2
  echo $? > "$WORK/stopcifix/rc"
}
job_stopciredresume() {
  # Red → CI fix round → the second CI wait is interrupted (STOP on the 2nd
  # poll, still pending) → --resume finds CI red again: one CI fix round per
  # issue, so it parks — it must not spend a second round on the new head.
  new_fixture stopcired
  mkdir -p "$WORK/stopcired/gh/ci" "$WORK/stopcired/gh/runs"
  printf '%s\n%s\n%s\n' \
    '[{"name":"build","state":"FAILURE","bucket":"fail","link":"https://github.com/o/r/actions/runs/557/job/1"}]' \
    '[{"name":"build","state":"IN_PROGRESS","bucket":"pending","link":"https://github.com/o/r/actions/runs/557/job/1"}]' \
    '[{"name":"build","state":"FAILURE","bucket":"fail","link":"https://github.com/o/r/actions/runs/557/job/1"}]' \
    > "$WORK/stopcired/gh/ci/4"
  printf 'Error: still red\n' > "$WORK/stopcired/gh/runs/557.log"
  run_deliver stopcired FAKE_GH_STOP_ON="pr checks" FAKE_GH_STOP_ON_NTH=2 -- --issue-max-iterations 2
  echo $? > "$WORK/stopcired/rc1"
  run_deliver stopcired -- --resume --issue-max-iterations 2
  echo $? > "$WORK/stopcired/rc"
}
job_maxturns() {
  # #96: every loop.sh run gets --max-turns, 200 unless given.
  new_fixture maxturns
  run_deliver maxturns STUB_TURNS_LOG="$WORK/maxturns/turns.log"
  echo $? > "$WORK/maxturns/rc"
  new_fixture maxturns50
  run_deliver maxturns50 STUB_TURNS_LOG="$WORK/maxturns50/turns.log" -- --max-turns 50
  echo $? > "$WORK/maxturns50/rc"
  new_fixture maxturnsbad
  run_deliver maxturnsbad -- --max-turns 0
  echo $? > "$WORK/maxturnsbad/rc"
}
job_retrynotparked() {
  # --retry on an issue the run left in flight (PR open, not parked) must be
  # refused, and must not close the PR or delete the branch (#61 review I1).
  new_fixture retrynotparked
  run_deliver retrynotparked FAKE_GH_KILL_AFTER_PR_OPEN=1
  echo $? > "$WORK/retrynotparked/rc1"
  run_deliver retrynotparked -- --resume --retry '#1'
  echo $? > "$WORK/retrynotparked/rc"
}
job_refusedonce() {
  new_fixture refusedonce
  run_deliver refusedonce FAKE_GH_MERGE_REFUSE_ONCE=1
  echo $? > "$WORK/refusedonce/rc"
}
job_squash() {
  new_fixture squash
  touch "$WORK/squash/gh/no_squash"
  run_deliver squash
  echo $? > "$WORK/squash/rc"
}
job_baseadv_clean() {
  new_fixture baseadv
  git -C "$WORK/baseadv/remote.git" rev-parse main > "$WORK/baseadv/main_before"
  run_deliver baseadv STUB_ADVANCE_BASE_PATH=advanced.txt STUB_ADVANCE_BASE_MARKER="$WORK/baseadv/advance.marker"
  echo $? > "$WORK/baseadv/rc"
}
job_baseadv_conflict() {
  new_fixture baseadvconflict with4
  run_deliver baseadvconflict STUB_ADVANCE_BASE_PATH=work/issue-1.txt STUB_ADVANCE_BASE_MARKER="$WORK/baseadvconflict/advance.marker" -- --issue-max-iterations 1
  echo $? > "$WORK/baseadvconflict/rc"
}

# --- ci_wait (#60): PR #4 is always issue #1's, #5 issue #2's (deterministic
# next_num order — see new_fixture). A fixture's $gh/ci/<pr> file is the fake
# gh's per-PR checks script: one JSON array of {name,state,bucket,link} per
# poll, repeating its last line once exhausted; no file at all is "no checks
# reported" (ci_wait's grace / "no CI" path). --ci-poll-seconds 0 and
# --ci-grace-seconds 0 keep the polling loop instant in tests.
job_ci_none() {
  new_fixture cinone
  run_deliver cinone -- --ci-poll-seconds 0 --ci-grace-seconds 0
  echo $? > "$WORK/cinone/rc"
}
job_ci_pending_green() {
  new_fixture cigreen
  mkdir -p "$WORK/cigreen/gh/ci"
  printf '%s\n%s\n' \
    '[{"name":"build","state":"IN_PROGRESS","bucket":"pending","link":"http://x/1"}]' \
    '[{"name":"build","state":"SUCCESS","bucket":"pass","link":"http://x/1"}]' \
    > "$WORK/cigreen/gh/ci/4"
  run_deliver cigreen -- --ci-poll-seconds 0 --ci-grace-seconds 0
  echo $? > "$WORK/cigreen/rc"
}
job_ci_fail() {
  # A checks script that stays FAILURE forever (its one line repeats): the
  # fix round (#60) gets tried once — the stub `claude` "fixes" it, ticking
  # C1 — but the CI script still says FAILURE on the second poll, so this is
  # "CI red twice", parked without a third attempt, the second failure's log
  # tail in the park comment.
  new_fixture cifail
  mkdir -p "$WORK/cifail/gh/ci" "$WORK/cifail/gh/runs"
  printf '%s\n' '[{"name":"build","state":"FAILURE","bucket":"fail","link":"https://github.com/o/r/actions/runs/777/job/2"}]' \
    > "$WORK/cifail/gh/ci/4"
  printf 'assert failed: flaky_widget expected 3\n' > "$WORK/cifail/gh/runs/777.log"
  run_deliver cifail -- --ci-poll-seconds 0 --ci-grace-seconds 0 --issue-max-iterations 2
  echo $? > "$WORK/cifail/rc"
}
job_ci_fail_no_rounds() {
  # --max-fix-rounds 0: the budget is gone before the first red check, so no
  # fix round is attempted — parked straight away, with the log tail.
  new_fixture cinoround
  mkdir -p "$WORK/cinoround/gh/ci" "$WORK/cinoround/gh/runs"
  printf '%s\n' '[{"name":"lint","state":"FAILURE","bucket":"fail","link":"https://github.com/o/r/actions/runs/888/job/3"}]' \
    > "$WORK/cinoround/gh/ci/4"
  printf 'lint: trailing whitespace in src/a.sh\n' > "$WORK/cinoround/gh/runs/888.log"
  run_deliver cinoround -- --ci-poll-seconds 0 --ci-grace-seconds 0 --max-fix-rounds 0
  echo $? > "$WORK/cinoround/rc"
}
job_ci_fail_after_review_round() {
  # One shared budget: a review fix round spends --max-fix-rounds 1, so the
  # red check that follows finds no round left and parks at once.
  new_fixture cishared
  mkdir -p "$WORK/cishared/gh/ci" "$WORK/cishared/gh/runs"
  printf '%s\n' '[{"name":"lint","state":"FAILURE","bucket":"fail","link":"https://github.com/o/r/actions/runs/889/job/3"}]' \
    > "$WORK/cishared/gh/ci/4"
  printf 'lint: trailing whitespace in src/a.sh\n' > "$WORK/cishared/gh/runs/889.log"
  run_deliver cishared STUB_REVIEW=blocker-once STUB_REVIEW_STATE="$WORK/cishared/review.state" \
    -- --ci-poll-seconds 0 --ci-grace-seconds 0 --max-fix-rounds 1
  echo $? > "$WORK/cishared/rc"
}
job_ci_fail_then_green() {
  # Red on the first poll, green on the second (the fix round's own ci_wait):
  # the failed check's link names a run id the fake gh has a log for, so the
  # fix round's plan item carries a real log tail.
  new_fixture cifixgreen
  mkdir -p "$WORK/cifixgreen/gh/ci" "$WORK/cifixgreen/gh/runs"
  printf '%s\n%s\n' \
    '[{"name":"build","state":"FAILURE","bucket":"fail","link":"https://github.com/o/r/actions/runs/555/job/1"}]' \
    '[{"name":"build","state":"SUCCESS","bucket":"pass","link":"https://github.com/o/r/actions/runs/555/job/1"}]' \
    > "$WORK/cifixgreen/gh/ci/4"
  printf 'Error: something exploded\nBuild failed at step 3\n' > "$WORK/cifixgreen/gh/runs/555.log"
  run_deliver cifixgreen -- --ci-poll-seconds 0 --ci-grace-seconds 0 --issue-max-iterations 2
  echo $? > "$WORK/cifixgreen/rc"
}
job_ci_timeout() {
  new_fixture citimeout
  mkdir -p "$WORK/citimeout/gh/ci"
  printf '%s\n' '[{"name":"build","state":"IN_PROGRESS","bucket":"pending","link":"http://x/1"}]' \
    > "$WORK/citimeout/gh/ci/4"
  run_deliver citimeout -- --ci-poll-seconds 1 --ci-timeout 1 --ci-grace-seconds 0
  echo $? > "$WORK/citimeout/rc"
}

bg job_happy
bg job_extra
for i in "${!EXTRABAD_VALUES[@]}"; do bg job_extrabad "$i" "${EXTRABAD_VALUES[$i]}"; done
bg job_nocreds
bg job_pct
for i in "${!PCTBAD_VALUES[@]}"; do bg job_pctbad "$i" "${PCTBAD_VALUES[$i]}"; done
bg job_pace
bg job_paceall
bg job_pacebad
bg job_onmain
bg job_dirty
bg job_nomap
bg job_behind
bg job_notool jq
bg job_notool gh
bg job_unauth
bg job_midedit
bg job_park
bg job_park2
bg job_parklate
bg job_parkverify
bg job_parknowork
bg job_rvblock
bg job_rvliar
bg job_rvblockonce
bg job_rvblockrounds2
bg job_rvblockrounds1
bg job_rvoos
bg job_rvgarbage
bg job_rvretry
bg job_rvmutate
bg job_rvmutatevariant mutate-ref
bg job_rvmutatevariant mutate-tmp
bg job_rvmutatevariant mutate-hook
bg job_rvexample
bg job_rvwronghead
bg job_refused
bg job_stopfile
bg job_budget
bg job_killresume
bg job_budgetresume
bg job_stopresume
bg job_locklive
bg job_lockstale
bg job_retry
bg job_retrynotparked
bg job_maxturns
bg job_stopfixresume
bg job_stopciresume
bg job_stopcifixresume
bg job_stopciredresume
bg job_refusedonce
bg job_squash
bg job_baseadv_clean
bg job_baseadv_conflict
bg job_ci_none
bg job_ci_pending_green
bg job_ci_fail
bg job_ci_fail_no_rounds
bg job_ci_fail_after_review_round
bg job_ci_fail_then_green
bg job_ci_timeout
wait

# ===========================================================================
# Assertions — same fixtures, same order, same wording as before parallelism;
# only $? became "$(cat .../rc)" since a background job's exit code does not
# reach this shell any other way.
# ===========================================================================

# --- happy path: two dependent issues ----------------------------------------
H="$WORK/happy"
MAIN_BEFORE="$(cat "$WORK/happy/main_before")"
RC="$(cat "$WORK/happy/rc")"
[[ "$RC" -eq 0 ]] && ok "happy path: two dependent issues delivered (exit 0)" \
  || note "happy path exited $RC: $(tail -3 "$H/err" | tr '\n' '|')"
SUBJECTS="$(git -C "$H/remote.git" log --format=%s "$MAIN_BEFORE..integration/x")"
EXPECTED="$(printf 'fix: second thing (#5)\nfeat(a): first feature (#4)')"
[[ "$SUBJECTS" == "$EXPECTED" ]] \
  && ok "happy path: integration/x gained exactly two squash commits, #1 first, conventional subjects" \
  || note "happy path: integration/x log is: $(printf '%s' "$SUBJECTS" | tr '\n' '|')"
[[ "$(git -C "$H/remote.git" rev-parse main)" == "$MAIN_BEFORE" ]] \
  && ok "happy path: main is untouched" || note "happy path: main moved"
MAPBODY="$(jq -r .body "$H/gh/issues/3.json")"
[[ "$MAPBODY" == *"- [x] #2 Second thing (after: #1)"* && "$MAPBODY" == *"- [x] #1 feat(a): first feature"* ]] \
  && ok "happy path: both Delivery lines are ticked on the Map" \
  || note "happy path: map body is: $(printf '%s' "$MAPBODY" | tr '\n' '|')"
[[ "$(jq -r '.comments | length' "$H/gh/issues/1.json")" -eq 1 && "$(jq -r '.comments | length' "$H/gh/issues/2.json")" -eq 1 ]] \
  && jq -r '.comments[0].body' "$H/gh/issues/1.json" | grep -q 'Merged into `integration/x` via #4' \
  && ok "happy path: each issue gets one 'merged via #PR' comment" \
  || note "happy path: issue comments missing or wrong"
[[ "$(jq -r .state "$H/gh/issues/1.json")" == "OPEN" ]] \
  && ok "happy path: issues stay open (they close with the final PR, ADR-0008)" \
  || note "happy path: an issue was closed"
jq -r .baseRefName "$H/gh/prs/4.json" | grep -qx integration/x && jq -r .body "$H/gh/prs/4.json" | grep -q '^Refs #1 · Part of map #3$' \
  && ok "happy path: PRs target the integration branch and say Refs, not Closes" \
  || note "happy path: PR #4 base/body wrong"
[[ "$(git -C "$H/repo" branch --show-current)" == "integration/x" && -z "$(git -C "$H/repo" status --porcelain)" ]] \
  && [[ "$(git -C "$H/repo" rev-parse HEAD)" == "$(git -C "$H/remote.git" rev-parse integration/x)" ]] \
  && ok "happy path: the checkout ends clean on integration/x, in sync with origin" \
  || note "happy path: checkout ends on '$(git -C "$H/repo" branch --show-current)', dirty or out of sync"
[[ -z "$(git -C "$H/repo" branch --list 'feat/*' 'fix/*')" && -z "$(git -C "$H/remote.git" branch --list 'feat/*' 'fix/*')" ]] \
  && ok "happy path: issue branches are deleted locally and on the remote" \
  || note "happy path: leftover branches: $(git -C "$H/remote.git" branch --list 'feat/*' 'fix/*' | tr '\n' ' ')"
git -C "$H/remote.git" show integration/x:work/issue-1.txt >/dev/null 2>&1 \
  && git -C "$H/remote.git" show integration/x:work/issue-2.txt >/dev/null 2>&1 \
  && ok "happy path: both issues' work landed on integration/x" \
  || note "happy path: work files missing on integration/x"
SNAPS=("$H"/state/claude-code-harness/deliver/*/runner/skills/deliver/deliver.sh)
[[ -f "${SNAPS[0]}" ]] && grep -q "running from private copy" "$H/err" \
  && ok "happy path: the runner re-executed from a private copy outside the worktree" \
  || note "happy path: no private runner copy under \$XDG_STATE_HOME"
RUNDIR="$(ls -d "$H"/repo/tmp/deliver/*/ 2>/dev/null | head -1)"
[[ -f "$RUNDIR/issues/1/PROMPT.md" && -f "$RUNDIR/issues/1/status.json" && -f "$RUNDIR/issues/2/pr-body.md" ]] \
  && grep -q '^- #2 Second thing — delivered by its own issue' "$RUNDIR/issues/1/PROMPT.md" \
  && ok "happy path: per-issue autopilot state dirs hold the charter, status and PR body" \
  || note "happy path: per-issue state missing under $RUNDIR"
PHASES=",$(cat "$RUNDIR"issues/1/run-*.jsonl 2>/dev/null | jq -r '.phase' | sort -u | tr '\n' ',')"
[[ "$PHASES" == *",plan,"* && "$PHASES" == *",build,"* ]] \
  && ok "happy path: issue #1's own run log shows loop.sh actually ran a plan and a build phase" \
  || note "happy path: issue #1's run log phases were: $PHASES"

# --- the review step on the happy path (#59) ---------------------------------
for pr in 4 5; do
  jq -r '.comments[0].body // ""' "$H/gh/prs/$pr.json" > "$WORK/happy/pr$pr.comment"
done
grep -q '^<!-- deliver:review issue=1 round=1 head=[0-9a-f]\{40\} -->$' "$WORK/happy/pr4.comment" \
  && grep -qF '**Runner verdict: approve**' "$WORK/happy/pr4.comment" \
  && grep -q '^<!-- deliver:review issue=2 round=1 ' "$WORK/happy/pr5.comment" \
  && ok "review: each PR gets one marked review comment with the runner's verdict before it merges" \
  || note "review: PR comments missing or unmarked: $(head -2 "$WORK/happy/pr4.comment" | tr '\n' '|')"
REVIEW_CWDS="$(cut -f1 "$WORK/happy/review.log" 2>/dev/null)"
[[ "$(grep -c . <<<"$REVIEW_CWDS")" -eq 2 ]] && ! grep -qxF "$H/repo" <<<"$REVIEW_CWDS" \
  && [[ -z "$(git -C "$H/repo" worktree list --porcelain | grep -c '^worktree ' | grep -vx 1)" ]] \
  && ok "review: ran twice, each time in a throwaway worktree (not the checkout), all removed afterwards" \
  || note "review: cwds were: $(tr '\n' ' ' <<<"$REVIEW_CWDS"); worktrees: $(git -C "$H/repo" worktree list | wc -l)"
REVIEW_PERMS="$(cut -f2-4 "$WORK/happy/review.log" | sort -u)"
[[ "$REVIEW_PERMS" == $'Read,Grep,Glob\tBash,Edit,Write,MultiEdit,NotebookEdit,WebFetch,WebSearch,Task,Agent,TodoWrite,Skill\tdefault' ]] \
  && ok "review: no shell and no write tool — Read/Grep/Glob allowed, Bash/Edit/Write disallowed, default mode" \
  || note "review: permissions were '$(tr '\t' '|' <<<"$REVIEW_PERMS")'"
[[ "$(cut -f5 "$WORK/happy/review.log" | sort -u)" == "yes" ]] \
  && ok "review: the runner inlines the commits, stat and diff into the prompt" \
  || note "review: the diff was not inlined"
[[ "$(cat "$RUNDIR"/run-*.jsonl 2>/dev/null | jq -s '[.[] | select(.phase=="review" and .verdict=="approve")] | length')" -eq 2 ]] \
  && ok "review: both calls are in the run's own log (phase review, issue, verdict, cost)" \
  || note "review: run log rows missing under $RUNDIR"
[[ "$(jq -r .body "$H/gh/prs/4.json")" != *"nit"* && "$(cat "$RUNDIR"issues/1/IMPLEMENTATION_PLAN.md 2>/dev/null)" != *"nit"* ]] \
  && jq -r '.comments[0].body' "$H/gh/prs/4.json" | grep -q 'nit' \
  && ok "review: a suggestion's note never lands in the plan or PR body, only the review comment" \
  || note "review: suggestion 'nit' leaked into the plan or PR body, or missing from the comment"

# --- forge.sh: marker dedupe and PR lookup (#61 S2, on the happy fixture) -----
PR1="$(jq -r '.issues["1"].pr' "$RUNDIR/state.json")"
HEAD1="$(jq -r .headRefOid "$H/gh/prs/$PR1.json")"
MARKER1="$(review_marker 1 1 "$HEAD1")"
PATH="$BIN:$PATH" FAKE_GH_DIR="$H/gh" forge_pr_comment_has_marker "$PR1" "$MARKER1" \
  && ok "forge_pr_comment_has_marker: finds the marker actually posted on PR #$PR1" \
  || note "forge_pr_comment_has_marker: did not find '$MARKER1' on PR #$PR1"
PATH="$BIN:$PATH" FAKE_GH_DIR="$H/gh" forge_pr_comment_has_marker "$PR1" "$(review_marker 1 99 deadbeef)" \
  && note "forge_pr_comment_has_marker: found a marker that was never posted" \
  || ok "forge_pr_comment_has_marker: misses a marker that was never posted"
MERGED_MARKER="<!-- deliver:merged issue=1 pr=$PR1 -->"
PATH="$BIN:$PATH" FAKE_GH_DIR="$H/gh" forge_issue_comment_has_marker 1 "$MERGED_MARKER" \
  && ok "forge_issue_comment_has_marker: finds the merged-notice marker on issue #1" \
  || note "forge_issue_comment_has_marker: did not find '$MERGED_MARKER' on issue #1"
PATH="$BIN:$PATH" FAKE_GH_DIR="$H/gh" forge_issue_comment_has_marker 1 "<!-- deliver:park issue=1 -->" \
  && note "forge_issue_comment_has_marker: found a park marker on an issue that was never parked" \
  || ok "forge_issue_comment_has_marker: misses a marker that was never posted"
BRANCH1="$(jq -r .headRefName "$H/gh/prs/$PR1.json")"
FOUND_PR="$(PATH="$BIN:$PATH" FAKE_GH_DIR="$H/gh" forge_pr_for_branch "$BRANCH1")"
[[ "$FOUND_PR" == "$PR1" ]] \
  && ok "forge_pr_for_branch: finds the (now-merged) PR opened for the branch, by name alone" \
  || note "forge_pr_for_branch: expected #$PR1, got '$FOUND_PR'"
PATH="$BIN:$PATH" FAKE_GH_DIR="$H/gh" forge_pr_for_branch "feat/999-does-not-exist" \
  && note "forge_pr_for_branch: found a PR for a branch that never had one" \
  || ok "forge_pr_for_branch: no PR for a branch that never had one"
# The exact guard review_issue/park_issue/the merged comment use in deliver.sh:
# post only when the marker is absent. Calling it twice for the same head must
# still add exactly one comment — this is what makes review_issue idempotent
# across a resume (#61 S3 will call it again for an issue already reviewed).
echo "a second review attempt for the same head" > "$WORK/happy/dup-comment.md"
for _ in 1 2; do
  PATH="$BIN:$PATH" FAKE_GH_DIR="$H/gh" forge_pr_comment_has_marker "$PR1" "$MARKER1" \
    || PATH="$BIN:$PATH" FAKE_GH_DIR="$H/gh" forge_pr_comment "$PR1" "$WORK/happy/dup-comment.md"
done
POST_CALLS="$(grep -c "^pr comment $PR1 " "$H/gh/calls")"
[[ "$(jq -r '.comments | length' "$H/gh/prs/$PR1.json")" -eq 1 && "$POST_CALLS" -eq 1 ]] \
  && ok "review comment dedupe: the marker guard run twice on the same head posts one comment" \
  || note "review comment dedupe: PR #$PR1 has $(jq -r '.comments | length' "$H/gh/prs/$PR1.json") comment(s) after $POST_CALLS 'pr comment' call(s)"

# --- run state (#61 S1): state.json / events.jsonl / status.json / lock -------
jq -e '.map==3 and .base=="integration/x" and (.runner_version|type=="string") and (.active_seconds|type=="number")
       and .issues["1"].state=="merged" and .issues["2"].state=="merged"
       and (.issues["1"].pr|type=="number") and (.issues["1"].head|type=="string")' "$RUNDIR/state.json" >/dev/null \
  && ok "state.json: run identity and both issues recorded merged, with their pr and head" \
  || note "state.json: $(cat "$RUNDIR/state.json" 2>/dev/null)"
[[ -s "$RUNDIR/events.jsonl" ]] && jq -e . "$RUNDIR/events.jsonl" >/dev/null 2>&1 \
  && [[ "$(jq -c 'select(.event=="merged")' "$RUNDIR/events.jsonl" 2>/dev/null | wc -l | tr -d ' ')" -eq 2 ]] \
  && ok "events.jsonl: one valid JSON row per transition, both merges recorded" \
  || note "events.jsonl: $(tr '\n' '|' < "$RUNDIR/events.jsonl" 2>/dev/null)"
jq -e '.state=="done" and .merged_count==2 and .parked_count==0 and (.cost_usd|type=="number") and (.elapsed_s|type=="number")' \
  "$RUNDIR/status.json" >/dev/null \
  && ok "status.json: final run headline (state, merged/parked counts, cost, elapsed)" \
  || note "status.json: $(cat "$RUNDIR/status.json" 2>/dev/null)"
[[ ! -f "$RUNDIR/lock" ]] && ok "lock file is removed on exit" || note "lock file left behind: $(cat "$RUNDIR/lock")"
USAGE_OUT="$(bash "$REPORT_ABS" "$RUNDIR" 2>&1)"; USAGE_RC=$?
[[ "$USAGE_RC" -eq 0 && "$USAGE_OUT" == *"## Per run"* ]] \
  && ok "run-<id>.jsonl stays in loop.sh's schema: /usage-report's aggregation reads it without error" \
  || note "usage-report: rc=$USAGE_RC, out: $(head -3 <<<"$USAGE_OUT" | tr '\n' '|')"

# --- guardrails (ADR-0007), over every command the runner ran ----------------
if grep -E '(^| )push( |$)' "$H/git.calls" | grep -qE -- '(--force|--force-with-lease|(^| )-f( |$)|(^| )-[a-zA-Z]*f[a-zA-Z]*( |$))'; then
  note "guardrail: a git push with a force flag was run: $(grep -E 'push' "$H/git.calls" | grep -E -- '-f|--force' | head -1)"
else
  ok "guardrail: no force push in $(grep -cE '(^| )push( |$)' "$H/git.calls") git push call(s)"
fi
grep -q -- '--admin' "$H/gh/calls" && note "guardrail: gh was called with --admin" \
  || ok "guardrail: gh was never called with --admin"
grep -E '^pr merge' "$H/gh/calls" | grep -q -- '--match-head-commit [0-9a-f]\{40\}' \
  && ok "guardrail: every merge is pinned to a verified head (--match-head-commit)" \
  || note "guardrail: a merge was not pinned to its head sha"

# --- --extra-allowed-tools reaches BUILD, and never a forge grant ----------------
RC="$(cat "$WORK/extra/rc")"
[[ "$RC" -eq 0 ]] && [[ "$(grep -c . "$WORK/extra/build.log")" -ge 2 ]] \
  && ! grep -v 'Bash(jq:\*),Bash(bash scripts/x.sh)' "$WORK/extra/build.log" | grep -q . \
  && ok "--extra-allowed-tools is appended to every BUILD call's allowlist" \
  || note "--extra-allowed-tools: exit $RC, build allowlists: $(sort -u "$WORK/extra/build.log" 2>/dev/null | head -2 | tr '\n' '|')"
[[ "$(cut -f2 "$WORK/extra/review.log" 2>/dev/null | sort -u)" == "Read,Grep,Glob" ]] \
  && ok "--extra-allowed-tools never reaches the reviewer (its allowlist stays Read,Grep,Glob)" \
  || note "--extra-allowed-tools: reviewer allowlist was '$(cut -f2 "$WORK/extra/review.log" 2>/dev/null | sort -u | tr '\n' '|')'"
for i in "${!EXTRABAD_VALUES[@]}"; do
  bad="${EXTRABAD_VALUES[$i]}"; name="extrabad$i"
  RC="$(cat "$WORK/$name/rc")"
  if [[ "$RC" -eq 1 ]] && grep -q 'extra-allowed-tools refused (ADR-0007)' "$WORK/$name/err" && [[ ! -s "$WORK/$name/gh/calls" ]]; then
    ok "--extra-allowed-tools '$bad' is refused before any forge call"
  else
    note "--extra-allowed-tools '$bad': exit $RC"
  fi
done

# --- a model phase has no forge credentials; the runner has its own (#77) ------
RC="$(cat "$WORK/nocreds/rc")"
PROBE="$(sort -u "$WORK/nocreds/probe" 2>/dev/null | tr '\n' ' ')"
[[ "$RC" -eq 0 ]] && [[ "$PROBE" == "gh=4 helper=[] token=<unset> verify-gh=4 " ]] \
  && grep -q '^UNAUTH auth status' "$WORK/nocreds/gh/calls" \
  && [[ "$(jq -r .state "$WORK/nocreds/gh/prs/5.json")" == "MERGED" ]] \
  && ok "BUILD's gh and the verify command's gh are unauthenticated, git has no helper, while the runner (GH_TOKEN) still merges" \
  || note "no-creds: exit $RC, probe '$PROBE'"

# --- --per-call-timeout reaches autopilot (#83) ---------------------------------
# A BUILD that outlives the bound is cut off (exit 124) and the issue parks.
RC="$(cat "$WORK/pct/rc")"
PCT_BUILD="$(cat "$WORK"/pct/repo/tmp/deliver/*/issues/1/run-*.jsonl 2>/dev/null | jq -r 'select(.phase=="build") | .exit_code' | sort -u | tr '\n' ' ')"
[[ "$RC" -eq 2 && "$PCT_BUILD" == "124 " ]] \
  && ok "--per-call-timeout bounds autopilot's calls (BUILD cut off with 124, issue parked)" \
  || note "--per-call-timeout: exit $RC, build exit codes '$PCT_BUILD'"
for i in "${!PCTBAD_VALUES[@]}"; do
  bad="${PCTBAD_VALUES[$i]}"; name="pctbad$i"
  RC="$(cat "$WORK/$name/rc")"
  [[ "$RC" -eq 1 ]] && grep -q 'takes whole seconds' "$WORK/$name/err" && [[ ! -s "$WORK/$name/gh/calls" ]] \
    && ok "--per-call-timeout $bad is refused before any forge call" \
    || note "--per-call-timeout $bad: exit $RC"
done

# --- pacing (#88): full verify once per autopilot run by default ---------------
# Per issue: autopilot's completion verify + deliver's own final verify = 2.
# With --verify-every-iteration autopilot verifies each of its 2 iterations.
RC="$(cat "$WORK/pace/rc")"
PACE_DEFAULT="$(wc -l < "$WORK/pace/count" 2>/dev/null | tr -d ' ')"
RC2="$(cat "$WORK/paceall/rc")"
PACE_ALL="$(wc -l < "$WORK/paceall/count" 2>/dev/null | tr -d ' ')"
[[ "$RC" -eq 0 && "$PACE_DEFAULT" -eq 4 && "$RC2" -eq 0 && "$PACE_ALL" -eq 6 ]] \
  && ok "deliver runs autopilot's full verify once per issue by default (4 runs for 2 issues; 6 with --verify-every-iteration)" \
  || note "pacing: default exit $RC / $PACE_DEFAULT verify runs, every-iteration exit $RC2 / $PACE_ALL"
RC="$(cat "$WORK/pacebad/rc")"
[[ "$RC" -eq 1 && ! -s "$WORK/pacebad/gh/calls" ]] \
  && ok "--iteration-verify-cmd with --verify-every-iteration is refused before any forge call" \
  || note "pacing flag conflict: exit $RC"

# --- refusals ------------------------------------------------------------------
RC="$(cat "$WORK/onmain/rc")"
[[ "$RC" -eq 1 ]] && grep -q "refusing to merge into 'main'" "$WORK/onmain/err" && [[ ! -s "$WORK/onmain/gh/calls" ]] \
  && ok "refuses main (exit 1) before any forge call" \
  || note "on main: exit $RC, gh calls: $(tr '\n' '|' < "$WORK/onmain/gh/calls" 2>/dev/null)"

RC="$(cat "$WORK/dirty/rc")"
[[ "$RC" -eq 1 ]] && grep -q "working tree is dirty" "$WORK/dirty/err" && [[ ! -s "$WORK/dirty/gh/calls" ]] \
  && ok "refuses a dirty tree (exit 1) before any forge call" \
  || note "dirty tree: exit $RC"

RC="$(cat "$WORK/nomap/rc")"
[[ "$RC" -eq 1 ]] && grep -q "has no '## Delivery' lines" "$WORK/nomap/err" \
  && ok "refuses a Map without a Delivery section" || note "no-delivery map: exit $RC"

RC="$(cat "$WORK/behind/rc")"
[[ "$RC" -eq 1 ]] && grep -q "not in sync with origin" "$WORK/behind/err" \
  && ok "refuses an integration branch that is not in sync with origin" || note "out-of-sync branch: exit $RC"

# --- missing tools: refused before anything is copied or called --------------
for tool in jq gh; do
  RC="$(cat "$WORK/no$tool/rc")"
  [[ "$RC" -eq 1 ]] && grep -q "'$tool'" "$WORK/no$tool/err" \
    && [[ -z "$(ls -A "$WORK/no$tool/state" 2>/dev/null)" && ! -s "$WORK/no$tool/gh/calls" ]] \
    && ok "refuses a machine without $tool (exit 1), with no runner copy and no forge call" \
    || note "without $tool: exit $RC, err: $(tail -1 "$WORK/no$tool/err")"
done
RC="$(cat "$WORK/unauth/rc")"
[[ "$RC" -eq 1 ]] && grep -q "not authenticated" "$WORK/unauth/err" \
  && [[ -z "$(ls -A "$WORK/unauth/state" 2>/dev/null)" ]] \
  && ok "refuses an unauthenticated gh before copying the runner" \
  || note "unauthenticated gh: exit $RC, state: $(ls -A "$WORK/unauth/state" 2>/dev/null)"

# --- a Map edited mid-run into an invalid one stops with its own name ----------
RC="$(cat "$WORK/midedit/rc")"
[[ "$RC" -eq 1 ]] && grep -q "became invalid mid-run" "$WORK/midedit/err" \
  && ok "a Map edited mid-run into a duplicate line stops with a validation error" \
  || note "mid-run invalid Map: exit $RC, err: $(tail -1 "$WORK/midedit/err")"

# --- parking (#58): an issue that does not finish is set aside ----------------
# #1 stalls in autopilot; #2 waits on #1; #4 is independent. #1 is parked,
# #2 skipped, #4 still delivered — and the run says so with exit 2.
P="$WORK/park"
RC="$(cat "$WORK/park/rc")"
[[ "$RC" -eq 2 ]] && ok "park: a stalled issue parks, the run carries on and ends partial (exit 2)" \
  || note "park: exit $RC — $(tail -2 "$P/err" | tr '\n' '|')"
parked_one park && ! grep -q '^pr create.*--head feat/1-' "$P/gh/calls" \
  && jq -r '.comments[-1].body' "$P/gh/issues/1.json" | grep -q "autopilot ended 'stuck'\|autopilot ended 'iteration-cap'" \
  && jq -r '.comments[-1].body' "$P/gh/issues/1.json" | grep -q 'Autopilot: state `' \
  && ok "park: #1 is labelled needs-human (ready-for-agent removed), commented with the cause and autopilot's state, no PR" \
  || note "park: #1 labels=$(jq -c '[.labels[].name]' "$P/gh/issues/1.json") comment=$(jq -r '.comments[-1].body' "$P/gh/issues/1.json" | head -1)"
grep -qx 'needs-human' "$P/gh/labels" \
  && ok "park: the needs-human label is created when the repo lacks it" || note "park: needs-human label not created"
MAPB="$(jq -r .body "$P/gh/issues/3.json")"
[[ "$MAPB" == *"- [ ] #1 "* && "$MAPB" == *"- [ ] #2 "* && "$MAPB" == *"- [x] #4 "* ]] \
  && [[ "$(git -C "$P/remote.git" log --format=%s main..integration/x)" == "feat: independent thing (#5)" ]] \
  && ok "park: #2 (after #1) is skipped, independent #4 is still delivered — one commit on integration/x" \
  || note "park: map=$(printf '%s' "$MAPB" | grep '#' | tr '\n' '|') log=$(git -C "$P/remote.git" log --format=%s main..integration/x | tr '\n' '|')"
grep -q 'parked: #1' "$P/err" && grep -q 'skipped (blocked by a parked issue): #2' "$P/err" \
  && ok "park: the run's summary names what was parked and what was skipped" \
  || note "park: summary line missing: $(tail -1 "$P/err")"
[[ "$(git -C "$P/repo" branch --show-current)" == "integration/x" && -z "$(git -C "$P/repo" status --porcelain)" ]] \
  && git -C "$P/repo" rev-parse --verify -q refs/heads/feat/1-first-feature >/dev/null \
  && ok "park: the checkout ends clean on integration/x; the parked issue's branch is kept for a human" \
  || note "park: checkout on '$(git -C "$P/repo" branch --show-current)' or branch feat/1-first-feature gone"

# An existing needs-human label is used as is, not an error.
RC="$(cat "$WORK/park2/rc")"
[[ "$RC" -eq 2 ]] && parked_one park2 \
  && ok "park: a repo that already has needs-human parks the same way" || note "park with existing label: exit $RC"

# Running again while #1 still carries needs-human: #1 is left alone (no new
# branch, no new comment) and #2 is skipped again — partial, not a crash. This
# rerun genuinely must follow the first park run (it reads and extends the
# state that run left behind), so it stays a foreground call, not a job.
N_COMMENTS="$(jq '.comments | length' "$P/gh/issues/1.json")"
run_deliver park STUB_STALL_ISSUES=1 -- --issue-max-iterations 2
RC=$?
[[ "$RC" -eq 2 ]] && [[ "$(jq '.comments | length' "$P/gh/issues/1.json")" -eq "$N_COMMENTS" ]] \
  && grep -q '#1: labelled needs-human (parked earlier) — left alone' "$P/err" \
  && grep -q 'skipped (blocked by a parked issue): #2' "$P/err" \
  && ok "park, run again: a needs-human issue is left alone and its dependents skipped (exit 2, no new comment)" \
  || note "park rerun with label: exit $RC — $(tail -1 "$P/err")"

# A human removes the label but not the old branch: the run must not die on
# it — the issue is parked again with that reason, the rest carries on. Also
# a foreground rerun for the same reason as above.
jq '.labels = [{name:"ready-for-agent"}]' "$P/gh/issues/1.json" > "$P/x" && mv "$P/x" "$P/gh/issues/1.json"
run_deliver park STUB_STALL_ISSUES=1 -- --issue-max-iterations 2
RC=$?
[[ "$RC" -eq 2 ]] && jq -r '.comments[-1].body' "$P/gh/issues/1.json" | grep -q 'branch `feat/1-first-feature` from an earlier attempt still exists' \
  && parked_one park \
  && ok "park, run again without the label: the leftover branch re-parks #1 (with the reason), the run is not killed" \
  || note "park rerun without label: exit $RC — $(tail -1 "$P/err")"

# A later issue hitting a leftover branch, after earlier issues merged in the
# same run, must be parked in its own name — not with the previous issue's
# PR and branch (review round 2 of #58 found exactly that).
RC="$(cat "$WORK/parklate/rc")"
PL="$WORK/parklate"
C4="$(jq -r '.comments[-1].body' "$PL/gh/issues/4.json")"
[[ "$RC" -eq 2 ]] && [[ "$(jq -r '[.labels[].name] | join(",")' "$PL/gh/issues/4.json")" == "needs-human" ]] \
  && [[ "$C4" == *'branch `feat/4-independent-thing` from an earlier attempt'* ]] \
  && [[ "$C4" != *"PR: #"* && "$C4" != *"fix/2-second-thing"* ]] \
  && ! grep -q '^pr ready' "$PL/gh/calls" \
  && [[ "$(jq -r .state "$PL/gh/prs/6.json")" == "MERGED" ]] \
  && ok "park: a leftover branch met after earlier merges parks that issue in its own name (no stale PR/branch, no pr ready)" \
  || note "park late: exit $RC; #4 comment: $(head -3 <<<"$C4" | tr '\n' '|'); pr ready calls: $(grep -c '^pr ready' "$PL/gh/calls")"

# verify passes during autopilot but fails on the finished head (it fails
# only once HEAD is autopilot's final "green" checkpoint).
RC="$(cat "$WORK/parkverify/rc")"
[[ "$RC" -eq 2 ]] && parked_one parkverify \
  && jq -r '.comments[-1].body' "$WORK/parkverify/gh/issues/1.json" | grep -q 'verify failed on the head' \
  && ! grep -q '^pr create' "$WORK/parkverify/gh/calls" \
  && ok "park: verify failing on the finished head parks the issue before anything is pushed" \
  || note "park on verify: exit $RC — $(tail -1 "$WORK/parkverify/err")"

RC="$(cat "$WORK/parknowork/rc")"
[[ "$RC" -eq 2 ]] && parked_one parknowork \
  && jq -r '.comments[-1].body' "$WORK/parknowork/gh/issues/1.json" | grep -q 'done without a single commit' \
  && ok "park: autopilot reporting done without a commit parks the issue" \
  || note "park on no commit: exit $RC — $(tail -1 "$WORK/parknowork/err")"

# --- review verdicts that hold a PR (#59) — the issue is parked (#58) ----------
RC="$(cat "$WORK/rvblock/rc")"
[[ "$RC" -eq 2 ]] && held rvblock && jq -r '.comments[0].body' "$WORK/rvblock/gh/prs/4.json" | grep -q 'Runner verdict: changes_requested' \
  && ok "review: an in-scope blocker parks the issue — PR back to draft, review posted, nothing merged, #2 skipped (exit 2)" \
  || note "review blocker: exit $RC"

RC="$(cat "$WORK/rvliar/rc")"
[[ "$RC" -eq 2 ]] && held rvliar \
  && jq -r '.comments[0].body' "$WORK/rvliar/gh/prs/4.json" | grep -qF '**Runner verdict: changes_requested** (reviewer said: approve)' \
  && ok "review: 'approve' with an in-scope issue is overruled by the runner" \
  || note "review liar: exit $RC"

# --- bounded in-scope fix rounds on the same PR (#63) --------------------------
RC="$(cat "$WORK/rvblockonce/rc")"
RVBO="$WORK/rvblockonce"
RUNDIR_RVBO="$(ls -d "$RVBO"/repo/tmp/deliver/*/ 2>/dev/null | head -1)"
ROWS_RVBO="$(cat "$RUNDIR_RVBO"run-*.jsonl 2>/dev/null | jq -s '[.[] | select(.phase=="review" and .issue==1)] | length')"
ROUND2_HAS_B1=0
for f in "$RVBO"/prompts/*.txt; do
  [[ -f "$f" ]] || continue
  grep -q 'Issue #1, review round 2' "$f" 2>/dev/null && grep -q '"id":"B1"' "$f" 2>/dev/null && ROUND2_HAS_B1=1
done
[[ "$RC" -eq 0 ]] && [[ "$ROWS_RVBO" -eq 2 ]] \
  && grep -qE '^- \[x\] R1\.1' "$RUNDIR_RVBO"issues/1/IMPLEMENTATION_PLAN.md 2>/dev/null \
  && [[ "$ROUND2_HAS_B1" -eq 1 ]] \
  && [[ "$(jq -r .state "$RVBO/gh/prs/4.json")" == "MERGED" ]] \
  && [[ "$(jq -r .body "$RVBO/gh/issues/3.json")" == *"- [x] #1 "* && "$(jq -r .body "$RVBO/gh/issues/3.json")" == *"- [x] #2 "* ]] \
  && ok "fix round: blocker-once → round 2 approves — R1.1 fixed and ticked, round 2's prompt inlines round 1's finding id, PR merged, Map ticked" \
  || note "fix round blocker-once: exit $RC, review rows(issue1)=$ROWS_RVBO, round2-has-B1=$ROUND2_HAS_B1"

RC="$(cat "$WORK/rvblockrounds2/rc")"
RVBR2="$WORK/rvblockrounds2"
RUNDIR_RVBR2="$(ls -d "$RVBR2"/repo/tmp/deliver/*/ 2>/dev/null | head -1)"
ROWS_RVBR2="$(cat "$RUNDIR_RVBR2"run-*.jsonl 2>/dev/null | jq -s '[.[] | select(.phase=="review" and .issue==1)] | length')"
[[ "$RC" -eq 2 ]] && held rvblockrounds2 && [[ "$ROWS_RVBR2" -eq 2 ]] \
  && jq -r '.comments[-1].body' "$RVBR2/gh/issues/1.json" | grep -q 'after 2 review(s) and no fix rounds are left (--max-fix-rounds 1, PR #4)' \
  && ok "fix rounds: an always-blocker verdict with --max-fix-rounds 1 parks after exactly 2 reviews" \
  || note "fix rounds --max-fix-rounds 1: exit $RC, review rows=$ROWS_RVBR2"

RC="$(cat "$WORK/rvblockrounds1/rc")"
RVBR1="$WORK/rvblockrounds1"
RUNDIR_RVBR1="$(ls -d "$RVBR1"/repo/tmp/deliver/*/ 2>/dev/null | head -1)"
ROWS_RVBR1="$(cat "$RUNDIR_RVBR1"run-*.jsonl 2>/dev/null | jq -s '[.[] | select(.phase=="review" and .issue==1)] | length')"
[[ "$RC" -eq 2 ]] && held rvblockrounds1 && [[ "$ROWS_RVBR1" -eq 1 ]] \
  && jq -r '.comments[-1].body' "$RVBR1/gh/issues/1.json" | grep -q 'after 1 review(s) and no fix rounds are left (--max-fix-rounds 0, PR #4)' \
  && ok "fix rounds: --max-fix-rounds 0 parks after exactly one review" \
  || note "fix rounds --max-fix-rounds 0: exit $RC, review rows=$ROWS_RVBR1"

RC="$(cat "$WORK/rvoos/rc")"
RVOOS="$WORK/rvoos"
HASH_RVOOS="$(finding_hash b 9 issue)"
MAP_BODY_RVOOS="$(jq -r .body "$RVOOS/gh/issues/3.json" 2>/dev/null)"
TRIAGE_COUNT="$(jq -s '[.[] | select([.labels[]?.name] | index("needs-triage"))] | length' "$RVOOS"/gh/issues/*.json 2>/dev/null)"
# STUB_REVIEW=outofscope reports the same b:9 finding, worded differently,
# for both #1's and #2's review — the fixture's own way of reprocessing the same finding twice —
# so the dedupe (forge_issue_search) is exercised without a second run.
[[ "$RC" -eq 0 && "$(jq -r .state "$RVOOS/gh/prs/4.json")" == "MERGED" && "$(jq -r .state "$RVOOS/gh/prs/6.json")" == "MERGED" ]] \
  && [[ "$TRIAGE_COUNT" -eq 1 ]] \
  && [[ -f "$RVOOS/gh/issues/5.json" ]] \
  && [[ "$(jq -r '[.labels[].name] | join(",")' "$RVOOS/gh/issues/5.json")" == "needs-triage" ]] \
  && jq -r .body "$RVOOS/gh/issues/5.json" | grep -qF 'map #3' \
  && jq -r .body "$RVOOS/gh/issues/5.json" | grep -qF 'PR #4' \
  && jq -r .body "$RVOOS/gh/issues/5.json" | grep -qF 'b:9' \
  && jq -r .body "$RVOOS/gh/issues/5.json" | grep -qF "<!-- deliver:finding $HASH_RVOOS -->" \
  && [[ "$(grep -c '^- \[ \] #5 ' <<<"$MAP_BODY_RVOOS")" -eq 1 ]] \
  && grep -A3 '^## Follow-ups$' <<<"$MAP_BODY_RVOOS" | grep -q '#5 found reviewing #1 (PR #4)' \
  && [[ "$MAP_BODY_RVOOS" == *"- [x] #1 "* && "$MAP_BODY_RVOOS" == *"- [x] #2 "* ]] \
  && jq -r .body "$RVOOS/gh/prs/4.json" | grep -qF '#5 — fix: old bug' \
  && ok "review: an out-of-scope finding does not block the merge; becomes one needs-triage follow-up (Map Follow-ups + PR body), never duplicated when the same finding recurs on #2's review" \
  || note "review out-of-scope: exit $RC"

RC="$(cat "$WORK/rvgarbage/rc")"
[[ "$RC" -eq 2 ]] && held rvgarbage && [[ "$(grep -c . "$WORK/rvgarbage/review.log")" -eq 2 ]] \
  && jq -r '.comments[0].body' "$WORK/rvgarbage/gh/prs/4.json" | grep -q 'Runner verdict: no verdict' \
  && ok "review: no usable verdict is retried once, then parks the issue (fail closed)" \
  || note "review garbage: exit $RC, calls $(grep -c . "$WORK/rvgarbage/review.log" 2>/dev/null)"

RC="$(cat "$WORK/rvretry/rc")"
[[ "$RC" -eq 0 ]] && [[ "$(cat "$WORK"/rvretry/repo/tmp/deliver/*/run-*.jsonl | jq -s '[.[] | select(.phase=="review") | .verdict] | join(",")')" == '"no_verdict,approve,approve"' ]] \
  && ok "review: one inconclusive reply then a real verdict proceeds (logged as no_verdict, approve)" \
  || note "review retry: exit $RC"

RC="$(cat "$WORK/rvmutate/rc")"
[[ "$RC" -eq 1 ]] && grep -q 'SAFETY BREACH' "$WORK/rvmutate/err" && ! grep -q '^pr merge' "$WORK/rvmutate/gh/calls" \
  && [[ "$(jq -r .body "$WORK/rvmutate/gh/issues/3.json")" != *"[x]"* ]] \
  && ok "review: a reviewer that moves the runner's checkout fails the whole run, nothing merges" \
  || note "review mutate: exit $RC, err: $(tail -1 "$WORK/rvmutate/err")"

for m in mutate-ref mutate-tmp mutate-hook; do
  RC="$(cat "$WORK/rv$m/rc")"
  [[ "$RC" -eq 1 ]] && grep -q 'SAFETY BREACH' "$WORK/rv$m/err" && ! grep -q '^pr merge' "$WORK/rv$m/gh/calls" \
    && ok "review: $m (a write the checkout's status cannot see) is still a safety breach" \
    || note "review $m: exit $RC, err: $(tail -1 "$WORK/rv$m/err")"
done

RC="$(cat "$WORK/rvexample/rc")"
[[ "$RC" -eq 0 && "$(jq -r .state "$WORK/rvexample/gh/prs/4.json")" == "MERGED" ]] \
  && ok "review: a clean verdict followed by the restated format example still merges" \
  || note "review example-after: exit $RC"

RC="$(cat "$WORK/rvwronghead/rc")"
[[ "$RC" -eq 2 ]] && held rvwronghead \
  && ok "review: a verdict for a different head is no verdict (parked)" \
  || note "review wrong-head: exit $RC"

# --- a merge refused twice by the forge parks the issue (#60) ----------------
RC="$(cat "$WORK/refused/rc")"
R="$WORK/refused"
[[ "$RC" -eq 2 ]] && parked_one refused && [[ "$(jq -r .isDraft "$R/gh/prs/4.json")" == "true" ]] \
  && [[ "$(git -C "$R/remote.git" rev-parse integration/x)" == "$(git -C "$R/remote.git" rev-parse main)" ]] \
  && [[ "$(grep -c '^pr merge' "$R/gh/calls")" -eq 2 ]] \
  && jq -r '.comments[-1].body' "$WORK/refused/gh/issues/1.json" | grep -q 'the forge refused to merge PR #4 twice' \
  && ok "a merge refused twice by the forge (with a final-verify retry in between) parks the issue" \
  || note "refused merge: exit $RC, pr merge calls: $(grep -c '^pr merge' "$R/gh/calls" 2>/dev/null)"

# --- a merge refused once, then accepted after a final-verify retry (#60) ----
RC="$(cat "$WORK/refusedonce/rc")"
RO="$WORK/refusedonce"
[[ "$RC" -eq 0 ]] && [[ "$(jq -r .state "$RO/gh/prs/4.json")" == "MERGED" ]] \
  && [[ "$(grep -c '^pr merge 4' "$RO/gh/calls")" -eq 2 ]] \
  && ok "a merge refused once retries through final-verify and then succeeds" \
  || note "refused-once merge: exit $RC, pr merge calls for #4: $(grep -c '^pr merge 4' "$RO/gh/calls" 2>/dev/null)"

# --- a repo that forbids squash merges gets a plain --merge instead (#60) ----
RC="$(cat "$WORK/squash/rc")"
SQ="$WORK/squash"
MOID_SQ="$(jq -r '.mergeCommit.oid // ""' "$SQ/gh/prs/4.json" 2>/dev/null)"
[[ "$RC" -eq 0 ]] && [[ -n "$MOID_SQ" ]] \
  && grep -q '^pr merge 4 --squash' "$SQ/gh/calls" && grep -q '^pr merge 4 --merge' "$SQ/gh/calls" \
  && [[ "$(git -C "$SQ/remote.git" rev-list --parents -n1 "$MOID_SQ" | wc -w)" -eq 3 ]] \
  && ok "a repo that forbids squash merges gets a plain --merge instead, still pinned to the verified head" \
  || note "squash fallback: exit $RC, calls: $(grep '^pr merge 4' "$SQ/gh/calls" 2>/dev/null | tr '\n' '|')"

# --- final-verify folds in a base that moved, cleanly (#60) -------------------
BA="$WORK/baseadv"
RC="$(cat "$BA/rc")"
MAIN_BEFORE_BA="$(cat "$BA/main_before" 2>/dev/null)"
LOG_BA="$(git -C "$BA/remote.git" log --format=%s "$MAIN_BEFORE_BA..integration/x" 2>/dev/null)"
[[ "$RC" -eq 0 ]] && [[ "$(grep -c . <<<"$LOG_BA")" -eq 3 ]] \
  && grep -qx 'advance base' <<<"$LOG_BA" \
  && grep -qx 'fix: second thing (#5)' <<<"$LOG_BA" && grep -qx 'feat(a): first feature (#4)' <<<"$LOG_BA" \
  && ! grep -E '(^| )push( |$)' "$BA/git.calls" | grep -qE -- '(--force|--force-with-lease|(^| )-f( |$)|(^| )-[a-zA-Z]*f[a-zA-Z]*( |$))' \
  && ok "a moved integration branch is merged into the issue branch, re-verified, pushed and merged (no force push)" \
  || note "base-advance clean: exit $RC, log: $(tr '\n' '|' <<<"$LOG_BA")"

# --- final-verify aborts on a conflicting base move; independent issues continue (#60) --
BC="$WORK/baseadvconflict"
RC="$(cat "$BC/rc")"
C1_BC="$(jq -r '.comments[-1].body' "$BC/gh/issues/1.json" 2>/dev/null)"
LOG_BC="$(git -C "$BC/remote.git" log --format=%s main..integration/x 2>/dev/null)"
[[ "$RC" -eq 2 ]] \
  && [[ "$(jq -r '[.labels[].name]|join(",")' "$BC/gh/issues/1.json")" == "needs-human" ]] \
  && [[ "$C1_BC" == *"the base branch \`integration/x\` moved"* && "$C1_BC" == *"work/issue-1.txt"* ]] \
  && ! grep -q '^pr create.*--head feat/1-' "$BC/gh/calls" \
  && [[ "$(git -C "$BC/repo" branch --show-current)" == "integration/x" && -z "$(git -C "$BC/repo" status --porcelain)" ]] \
  && [[ "$(jq -r .state "$BC/gh/prs/5.json" 2>/dev/null)" == "MERGED" ]] \
  && [[ "$(grep -c . <<<"$LOG_BC")" -eq 2 ]] && grep -qx 'advance base' <<<"$LOG_BC" \
  && grep -qx 'feat: independent thing (#5)' <<<"$LOG_BC" \
  && ok "a conflicting base move aborts the merge, parks the issue (no PR ever opened) and lets an independent issue still merge" \
  || note "base-advance conflict: exit $RC, #1 comment: $(head -3 <<<"$C1_BC" | tr '\n' '|'), log: $(tr '\n' '|' <<<"$LOG_BC")"

# --- ci_wait (#60) ------------------------------------------------------------
# no checks reported at all: "no CI", both issues merge anyway.
CN="$WORK/cinone"
RC="$(cat "$CN/rc")"
CN_RUNDIR="$(ls -d "$CN"/repo/tmp/deliver/*/ 2>/dev/null | head -1)"
[[ "$RC" -eq 0 ]] && [[ "$(jq -r .state "$CN/gh/prs/4.json")" == "MERGED" && "$(jq -r .state "$CN/gh/prs/5.json")" == "MERGED" ]] \
  && jq -r '.comments[-1].body' "$CN/gh/issues/1.json" | grep -qF 'CI: no CI reported.' \
  && [[ "$(cat "$CN_RUNDIR"/run-*.jsonl 2>/dev/null | jq -s '[.[] | select(.phase=="ci" and .verdict=="none")] | length')" -eq 2 ]] \
  && ok "CI: no checks reported at all merges anyway, recorded as 'no CI' in the run log and the merge comment" \
  || note "ci none: exit $RC, PR states $(jq -r .state "$CN/gh/prs/4.json" 2>/dev/null)/$(jq -r .state "$CN/gh/prs/5.json" 2>/dev/null)"

# pending then green merges, without a "no CI" note on that issue.
CG="$WORK/cigreen"
RC="$(cat "$CG/rc")"
CG_RUNDIR="$(ls -d "$CG"/repo/tmp/deliver/*/ 2>/dev/null | head -1)"
[[ "$RC" -eq 0 ]] && [[ "$(jq -r .state "$CG/gh/prs/4.json")" == "MERGED" ]] \
  && [[ "$(grep -c '^pr checks 4' "$CG/gh/calls")" -ge 2 ]] \
  && ! jq -r '.comments[-1].body' "$CG/gh/issues/1.json" | grep -qF 'CI:' \
  && [[ "$(cat "$CG_RUNDIR"/run-*.jsonl 2>/dev/null | jq -s '[.[] | select(.phase=="ci" and .verdict=="pass")] | length')" -ge 1 ]] \
  && ok "CI: pending polled until green, then merged (no 'no CI' note once CI reported)" \
  || note "ci pending->green: exit $RC, pr checks calls $(grep -c '^pr checks 4' "$CG/gh/calls" 2>/dev/null)"

# a failed check gets one fix round (#60); still red after it parks the issue.
CF="$WORK/cifail"
RC="$(cat "$CF/rc")"
CF_RUNDIR="$(ls -d "$CF"/repo/tmp/deliver/*/ 2>/dev/null | head -1)"
[[ "$RC" -eq 2 ]] && held cifail \
  && jq -r '.comments[-1].body' "$CF/gh/issues/1.json" | grep -qF 'CI failed again on PR #4 after fix round 1: build' \
  && jq -r '.comments[-1].body' "$CF/gh/issues/1.json" | grep -qxF 'assert failed: flaky_widget expected 3' \
  && jq -r '.comments[-1].body' "$CF/gh/issues/1.json" | grep -qx '~~~~~' \
  && grep -qF 'flaky_widget' "$CF_RUNDIR/issues/1/ci-fail-2.log" \
  && grep -q '^- \[x\] C1 Fix red CI: build$' "$CF_RUNDIR/issues/1/IMPLEMENTATION_PLAN.md" \
  && ! grep -q 'C2 Fix red CI' "$CF_RUNDIR/issues/1/IMPLEMENTATION_PLAN.md" \
  && [[ "$(cat "$CF_RUNDIR/issues/1/ROUNDS_USED" 2>/dev/null)" == "1" ]] \
  && [[ "$(cat "$CF_RUNDIR"/run-*.jsonl 2>/dev/null | jq -cs '[.[] | select(.phase=="ci" and .issue==1 and .verdict=="fail")] | map(.round) | sort')" == "[1,2]" ]] \
  && ok "CI: a red check gets one fix round (the fix round itself ran, C1 ticked); still red after it parks with the log tail, fenced (PR back to draft, #2 skipped)" \
  || note "ci fail twice: exit $RC, comment: $(jq -r '.comments[-1].body' "$CF/gh/issues/1.json" 2>/dev/null | tr '\n' '|')"

# no fix rounds left: parked on the first red check, log tail in the comment,
# no plan item appended and autopilot not resumed.
CR="$WORK/cinoround"
RC="$(cat "$CR/rc")"
CR_RUNDIR="$(ls -d "$CR"/repo/tmp/deliver/*/ 2>/dev/null | head -1)"
[[ "$RC" -eq 2 ]] && held cinoround \
  && jq -r '.comments[-1].body' "$CR/gh/issues/1.json" | grep -qF 'CI failed on PR #4: lint (no fix rounds left)' \
  && jq -r '.comments[-1].body' "$CR/gh/issues/1.json" | grep -qxF 'lint: trailing whitespace in src/a.sh' \
  && grep -q '^run view 888' "$CR/gh/calls" \
  && ! grep -q 'Fix red CI' "$CR_RUNDIR/issues/1/IMPLEMENTATION_PLAN.md" \
  && ok "CI: a red check with no fix rounds left (--max-fix-rounds 0) parks at once, log tail in the park comment, no fix item" \
  || note "ci fail, no rounds: exit $RC, comment: $(jq -r '.comments[-1].body' "$CR/gh/issues/1.json" 2>/dev/null | tr '\n' '|')"

# shared budget: the review's fix round spent the only round, so the red
# check after it parks straight away — R1.1 in the plan, no C1 item.
CS="$WORK/cishared"
RC="$(cat "$CS/rc")"
CS_RUNDIR="$(ls -d "$CS"/repo/tmp/deliver/*/ 2>/dev/null | head -1)"
[[ "$RC" -eq 2 ]] && held cishared \
  && [[ "$(cat "$CS_RUNDIR/issues/1/ROUNDS_USED" 2>/dev/null)" == "1" ]] \
  && grep -qE '^- \[x\] R1\.1' "$CS_RUNDIR/issues/1/IMPLEMENTATION_PLAN.md" \
  && ! grep -q 'Fix red CI' "$CS_RUNDIR/issues/1/IMPLEMENTATION_PLAN.md" \
  && jq -r '.comments[-1].body' "$CS/gh/issues/1.json" | grep -qF 'CI failed on PR #4: lint (no fix rounds left)' \
  && ok "fix rounds: review and CI share one budget — a review round spent it, the red check parks at once" \
  || note "shared budget: exit $RC, rounds=$(cat "$CS_RUNDIR/issues/1/ROUNDS_USED" 2>/dev/null), comment: $(jq -r '.comments[-1].body' "$CS/gh/issues/1.json" 2>/dev/null | tr '\n' '|')"

# red then green: the fix round's log tail lands in the plan, C1 gets ticked,
# and the re-verified, re-pushed head merges once CI is green.
CX="$WORK/cifixgreen"
RC="$(cat "$CX/rc")"
CX_RUNDIR="$(ls -d "$CX"/repo/tmp/deliver/*/ 2>/dev/null | head -1)"
[[ "$RC" -eq 0 ]] && [[ "$(jq -r .state "$CX/gh/prs/4.json")" == "MERGED" && "$(jq -r .state "$CX/gh/prs/5.json")" == "MERGED" ]] \
  && grep -q '^- \[x\] C1 Fix red CI: build$' "$CX_RUNDIR/issues/1/IMPLEMENTATION_PLAN.md" \
  && grep -qF 'CI check `build` failed on PR #4.' "$CX_RUNDIR/issues/1/IMPLEMENTATION_PLAN.md" \
  && grep -qF 'Build failed at step 3' "$CX_RUNDIR/issues/1/ci-fail-1.log" \
  && [[ "$(cat "$CX_RUNDIR"/run-*.jsonl 2>/dev/null | jq -cs '[.[] | select(.phase=="ci" and .issue==1)] | map(.round) | sort')" == "[1,2]" ]] \
  && ok "CI: a red check's fix round can turn CI green — merged, plan shows C1 ticked, run log records both CI polls" \
  || note "ci fix round to green: exit $RC, plan: $(grep -c '\[x\]' "$CX_RUNDIR/issues/1/IMPLEMENTATION_PLAN.md" 2>/dev/null)"

# CI stuck pending past the timeout parks the issue too, no fix round (it
# never actually failed).
CT="$WORK/citimeout"
RC="$(cat "$CT/rc")"
[[ "$RC" -eq 2 ]] && held citimeout \
  && jq -r '.comments[-1].body' "$CT/gh/issues/1.json" | grep -qF 'CI still pending after 1s on PR #4' \
  && ok "CI: still pending after --ci-timeout parks the issue" \
  || note "ci timeout: exit $RC"

# --- STOP file present before the run's first issue (#61 S1) ------------------
RC="$(cat "$WORK/stopfile/rc")"
SF="$WORK/stopfile"
SFRUNDIR="$(ls -d "$SF"/repo/tmp/deliver/*/ 2>/dev/null | head -1)"
[[ "$RC" -eq 6 ]] && [[ -n "$SFRUNDIR" && -f "${SFRUNDIR}STOP" ]] \
  && [[ "$(jq -r .state "${SFRUNDIR}status.json" 2>/dev/null)" == "stopped" ]] \
  && [[ ! -f "$SF/gh/prs/4.json" ]] && ! grep -q '^pr create' "$SF/gh/calls" 2>/dev/null \
  && ok "a STOP file present before the run's first issue: exit 6, state 'stopped', no PR opened" \
  || note "STOP file: exit $RC, status=$(cat "${SFRUNDIR}status.json" 2>/dev/null), prs=$(ls "$SF/gh/prs" 2>/dev/null | tr '\n' ' ')"

# --- a global budget small enough to trip after the first issue (#61 S1) ------
# #1's own inner run (plan+build+verify calls, ~$0.03) plus its review (~$0.02)
# comes to ~$0.05, under the $0.06 cap, so #1 merges; #2's own inner run pushes
# the total past it, so the run stops before #2 finishes — the merge #1
# already made is not undone.
RC="$(cat "$WORK/budget/rc")"
BD="$WORK/budget"
BDRUNDIR="$(ls -d "$BD"/repo/tmp/deliver/*/ 2>/dev/null | head -1)"
[[ "$RC" -eq 4 ]] && [[ "$(jq -r .state "${BDRUNDIR}status.json" 2>/dev/null)" == "budget_exhausted" ]] \
  && [[ "$(jq -r .state "$BD/gh/prs/4.json" 2>/dev/null)" == "MERGED" ]] \
  && [[ ! -f "$BD/gh/prs/5.json" ]] \
  && [[ "$(jq -r '.issues["2"].state // "none"' "${BDRUNDIR}state.json" 2>/dev/null)" != "merged" ]] \
  && ok "a global budget cap small enough to trip after the first issue: exit 4, #1 merged, #2 left unfinished (resumable)" \
  || note "budget cap: exit $RC, status=$(cat "${BDRUNDIR}status.json" 2>/dev/null), issues=$(jq -c .issues "${BDRUNDIR}state.json" 2>/dev/null)"
jq -e '(.issues["1"].issue_budget_usd // 10) < 10 and (.issues["2"].issue_budget_usd // 10) < 10' "${BDRUNDIR}state.json" >/dev/null 2>&1 \
  && ok "clipped per-issue caps are recorded on state.json: less than the default --issue-budget-usd (10)" \
  || note "clipped caps: issues=$(jq -c .issues "${BDRUNDIR}state.json" 2>/dev/null)"

# --- #61 S3: --resume after the runner is killed right after a PR opens -------
RC1="$(cat "$WORK/killresume/rc1")"
RC="$(cat "$WORK/killresume/rc")"
KR="$WORK/killresume"
[[ "$RC1" -ge 128 ]] \
  && ok "kill+resume: the first attempt is killed right after PR #4 opens (terminated by signal)" \
  || note "kill+resume: first attempt exited $RC1 (expected a signal kill)"
[[ "$RC" -eq 0 ]] \
  && ok "kill+resume: --resume finishes the run (exit 0)" \
  || note "kill+resume: --resume exited $RC — $(tail -3 "$KR/err" | tr '\n' '|')"
[[ "$(jq -r .state "$KR/gh/prs/4.json" 2>/dev/null)" == "MERGED" && "$(jq -r .state "$KR/gh/prs/5.json" 2>/dev/null)" == "MERGED" ]] \
  && ok "kill+resume: both issues' PRs end up merged" \
  || note "kill+resume: PR states #4=$(jq -r .state "$KR/gh/prs/4.json" 2>/dev/null) #5=$(jq -r .state "$KR/gh/prs/5.json" 2>/dev/null)"
[[ "$(jq -r '.comments | length' "$KR/gh/prs/4.json" 2>/dev/null)" -eq 1 ]] \
  && [[ "$(grep -c '^pr create' "$KR/gh/calls" 2>/dev/null)" -eq 2 ]] \
  && ok "kill+resume: the issue resumed at pr-open gets exactly one PR and one review comment, not two" \
  || note "kill+resume: PR #4 comments=$(jq -r '.comments|length' "$KR/gh/prs/4.json" 2>/dev/null), pr-create calls=$(grep -c '^pr create' "$KR/gh/calls" 2>/dev/null)"

# --- #61 S3: --resume after a global budget cap ---------------------------------
RC1="$(cat "$WORK/budgetresume/rc1")"
RC="$(cat "$WORK/budgetresume/rc")"
BR="$WORK/budgetresume"
[[ "$RC1" -eq 4 ]] \
  && ok "budget+resume: a small global budget trips after the first issue (exit 4)" \
  || note "budget+resume: first attempt exited $RC1"
[[ "$RC" -eq 0 ]] \
  && ok "budget+resume: --resume with a larger --budget-usd finishes the run (exit 0)" \
  || note "budget+resume: --resume exited $RC — $(tail -3 "$BR/err" | tr '\n' '|')"
[[ "$(jq -r .state "$BR/gh/prs/4.json" 2>/dev/null)" == "MERGED" && "$(jq -r .state "$BR/gh/prs/5.json" 2>/dev/null)" == "MERGED" ]] \
  && ok "budget+resume: both issues end up merged" \
  || note "budget+resume: PR states #4=$(jq -r .state "$BR/gh/prs/4.json" 2>/dev/null) #5=$(jq -r .state "$BR/gh/prs/5.json" 2>/dev/null)"

# --- #61 S3: --resume after a STOP file -----------------------------------------
RC1="$(cat "$WORK/stopresume/rc1")"
RC="$(cat "$WORK/stopresume/rc")"
SR="$WORK/stopresume"
[[ "$RC1" -eq 6 ]] \
  && ok "stop+resume: a STOP file present before the first issue stops the run (exit 6)" \
  || note "stop+resume: first attempt exited $RC1"
[[ "$RC" -eq 0 ]] \
  && ok "stop+resume: --resume after a STOP finishes the run (exit 0)" \
  || note "stop+resume: --resume exited $RC — $(tail -3 "$SR/err" | tr '\n' '|')"
[[ "$(jq -r .state "$SR/gh/prs/4.json" 2>/dev/null)" == "MERGED" && "$(jq -r .state "$SR/gh/prs/5.json" 2>/dev/null)" == "MERGED" ]] \
  && ok "stop+resume: both issues end up merged" \
  || note "stop+resume: PR states #4=$(jq -r .state "$SR/gh/prs/4.json" 2>/dev/null) #5=$(jq -r .state "$SR/gh/prs/5.json" 2>/dev/null)"

# --- #61 S3: --resume refuses a live lock, removes a stale one ------------------
RC="$(cat "$WORK/locklive/rc")"
LL="$WORK/locklive"
[[ "$RC" -eq 1 ]] && grep -q 'refusing to resume a live run' "$LL/err" \
  && ok "resume: a lock whose pid is still alive is refused, not removed" \
  || note "live lock: exit $RC — $(tail -3 "$LL/err" | tr '\n' '|')"

RC="$(cat "$WORK/lockstale/rc")"
LS="$WORK/lockstale"
[[ "$RC" -eq 0 ]] \
  && ok "resume: a stale lock (dead pid) is removed and the run proceeds (exit 0)" \
  || note "stale lock: exit $RC — $(tail -3 "$LS/err" | tr '\n' '|')"
grep -q 'removing a stale lock' "$LS/err" \
  && ok "resume: the stale-lock removal is logged" \
  || note "stale lock: no removal message: $(tail -3 "$LS/err" | tr '\n' '|')"
grep -q "plugin version changed since run fakerun-stale started (0.0.0-test -> $REAL_PLUGIN_VERSION)" "$LS/err" \
  && ok "resume: a plugin.json version different from the one state.json recorded is warned about, not refused" \
  || note "version warning: $(grep -o 'plugin version changed.*' "$LS/err" | head -1)"

# --- #61 S3: --retry '#N' on a parked issue starts a fresh inner run ------------
RC1="$(cat "$WORK/retry/rc1")"
RC="$(cat "$WORK/retry/rc")"
RT="$WORK/retry"
# parked_one checks issue #1's *current* state, which --retry has since moved
# on from (needs-human removed, Map line ticked) — this checks the historical
# park comment instead, which --retry never removes.
[[ "$RC1" -eq 2 ]] \
  && jq -r '[.comments[].body] | join("\n")' "$RT/gh/issues/1.json" | grep -q '^\*\*Parked by `/deliver`\*\*' \
  && ok "retry: the first attempt stalls on #1, parks it, still delivers independent #4 (exit 2)" \
  || note "retry: first attempt exited $RC1"
[[ "$RC" -eq 0 ]] \
  && ok "retry: --resume --retry '#1' finishes the run (exit 0)" \
  || note "retry: --resume --retry exited $RC — $(tail -3 "$RT/err" | tr '\n' '|')"
MAPB_RT="$(jq -r .body "$RT/gh/issues/3.json")"
[[ "$MAPB_RT" == *"- [x] #1 "* && "$MAPB_RT" == *"- [x] #2 "* && "$MAPB_RT" == *"- [x] #4 "* ]] \
  && [[ "$(jq -r '[.labels[].name] | index("needs-human")' "$RT/gh/issues/1.json")" == "null" ]] \
  && ok "retry: #1 is delivered on a fresh branch, #2 (after #1) follows, needs-human is gone" \
  || note "retry: map=$(printf '%s' "$MAPB_RT" | grep '#' | tr '\n' '|') labels=$(jq -c '[.labels[].name]' "$RT/gh/issues/1.json")"
RTRUNDIR="$(ls -d "$RT"/repo/tmp/deliver/*/ 2>/dev/null | head -1)"
grep -q '"issue":1,"event":"retry"' "${RTRUNDIR}events.jsonl" 2>/dev/null \
  && ok "retry: the retry transition for #1 is recorded in events.jsonl" \
  || note "retry: events.jsonl missing a retry row for #1: $(tr '\n' '|' < "${RTRUNDIR}events.jsonl" 2>/dev/null)"

# --- #61 review: a STOP mid-fix-round, then --resume, finishes that round ------
SF="$WORK/stopfix"
RC1="$(cat "$SF/rc1")"; RC="$(cat "$SF/rc")"
SFRUNDIR="$(ls -d "$SF"/repo/tmp/deliver/*/ 2>/dev/null | head -1)"
[[ "$RC1" -eq 6 && "$(jq -r '.issues["1"].fix // empty' "$SF/state1.json" 2>/dev/null)" == "review" ]] \
  && [[ "$RC" -eq 0 ]] \
  && [[ "$(jq -r .state "$SF/gh/prs/4.json")" == "MERGED" && "$(jq -r .state "$SF/gh/prs/5.json")" == "MERGED" ]] \
  && [[ "$(cat "${SFRUNDIR}issues/1/ROUNDS_USED" 2>/dev/null)" == "1" ]] \
  && [[ "$(grep -c '^- \[.\] R1\.1' "${SFRUNDIR}issues/1/IMPLEMENTATION_PLAN.md")" -eq 1 ]] \
  && [[ "$(jq -r '[.comments[].body | select(contains("deliver:review issue=1 "))] | length' "$SF/gh/prs/4.json")" -eq 2 ]] \
  && ok "resume: a STOP mid-review-fix-round (state fix=review) is finished on --resume — one round spent, R1.1 once, round 2 approves, merged" \
  || note "stop mid-fix: rc1=$RC1 fix=$(jq -r '.issues["1"].fix // "-"' "$SF/state1.json" 2>/dev/null) rc=$RC rounds=$(cat "${SFRUNDIR}issues/1/ROUNDS_USED" 2>/dev/null) — $(tail -3 "$SF/err" | tr '\n' '|')"

SC="$WORK/stopci"
RC1="$(cat "$SC/rc1")"; RC="$(cat "$SC/rc")"
[[ "$RC1" -eq 6 && "$RC" -eq 0 ]] \
  && [[ "$(jq -r .state "$SC/gh/prs/4.json")" == "MERGED" ]] \
  && [[ "$(wc -l < "$SC/review.log" 2>/dev/null)" -eq 2 ]] \
  && grep -q -- '--resume continuing at: ci' "$SC/err" \
  && ok "resume: a STOP during the CI wait resumes at CI — the approved head is not reviewed again (2 reviews for 2 issues)" \
  || note "stop in CI: rc1=$RC1 rc=$RC reviews=$(wc -l < "$SC/review.log" 2>/dev/null) — $(tail -3 "$SC/err" | tr '\n' '|')"

SX="$WORK/stopcifix"
RC1="$(cat "$SX/rc1")"; RC="$(cat "$SX/rc")"
SXRUNDIR="$(ls -d "$SX"/repo/tmp/deliver/*/ 2>/dev/null | head -1)"
[[ "$RC1" -eq 6 && "$(jq -r '.issues["1"].fix // empty' "$SX/state1.json" 2>/dev/null)" == "ci" ]] \
  && [[ "$RC" -eq 0 && "$(jq -r .state "$SX/gh/prs/4.json")" == "MERGED" ]] \
  && [[ "$(cat "${SXRUNDIR}issues/1/ROUNDS_USED" 2>/dev/null)" == "1" ]] \
  && [[ "$(grep -c '^- \[.\] C1 Fix red CI: build$' "${SXRUNDIR}issues/1/IMPLEMENTATION_PLAN.md")" -eq 1 ]] \
  && grep -q -- '--resume continuing at: ci-fix' "$SX/err" \
  && [[ "$(wc -l < "$SX/review.log" 2>/dev/null)" -eq 1 ]] \
  && ok "resume: a STOP mid-CI-fix-round (state fix=ci) is finished on --resume — one round, C1 once, no second review of #1, merged" \
  || note "stop mid-CI-fix: rc1=$RC1 fix=$(jq -r '.issues["1"].fix // "-"' "$SX/state1.json" 2>/dev/null) rc=$RC rounds=$(cat "${SXRUNDIR}issues/1/ROUNDS_USED" 2>/dev/null) reviews=$(wc -l < "$SX/review.log" 2>/dev/null) — $(tail -3 "$SX/err" | tr '\n' '|')"

SR2="$WORK/stopcired"
RC1="$(cat "$SR2/rc1")"; RC="$(cat "$SR2/rc")"
SR2RUNDIR="$(ls -d "$SR2"/repo/tmp/deliver/*/ 2>/dev/null | head -1)"
[[ "$RC1" -eq 6 && "$RC" -eq 2 ]] \
  && [[ "$(cat "${SR2RUNDIR}issues/1/ROUNDS_USED" 2>/dev/null)" == "1" ]] \
  && ! grep -q 'C2 Fix red CI' "${SR2RUNDIR}issues/1/IMPLEMENTATION_PLAN.md" \
  && jq -r '.comments[-1].body' "$SR2/gh/issues/1.json" | grep -qF 'CI failed again on PR #4 after its fix round: build' \
  && ok "resume: CI red again after the fix round parks on --resume too — no second CI round on the new head" \
  || note "stop in 2nd CI wait: rc1=$RC1 rc=$RC rounds=$(cat "${SR2RUNDIR}issues/1/ROUNDS_USED" 2>/dev/null) — $(tail -3 "$SR2/err" | tr '\n' '|')"

# --- #96: --max-turns reaches every BUILD call ---------------------------------
[[ "$(cat "$WORK/maxturns/rc")" -eq 0 && -s "$WORK/maxturns/turns.log" ]] \
  && [[ "$(sort -u "$WORK/maxturns/turns.log")" == "--max-turns 200" ]] \
  && [[ "$(cat "$WORK/maxturns50/rc")" -eq 0 && "$(sort -u "$WORK/maxturns50/turns.log")" == "--max-turns 50" ]] \
  && ok "--max-turns reaches every BUILD call (default 200 for /deliver, --max-turns 50 honoured)" \
  || note "max-turns: default=$(sort -u "$WORK/maxturns/turns.log" 2>/dev/null | tr '\n' ' ') custom=$(sort -u "$WORK/maxturns50/turns.log" 2>/dev/null | tr '\n' ' ')"
[[ "$(cat "$WORK/maxturnsbad/rc")" -eq 1 ]] && grep -q -- '--max-turns takes a positive whole number' "$WORK/maxturnsbad/err" \
  && [[ ! -s "$WORK/maxturnsbad/gh/calls" ]] \
  && ok "--max-turns 0 is refused before any forge call" \
  || note "--max-turns 0: exit $(cat "$WORK/maxturnsbad/rc")"

# --- #61 review I1: --retry refuses an issue that is not parked -----------------
RC="$(cat "$WORK/retrynotparked/rc")"
RN="$WORK/retrynotparked"
[[ "$(cat "$RN/rc1")" -ge 128 && "$RC" -eq 1 ]] \
  && grep -qE "records #1 as '[a-z-]+', not parked" "$RN/err" \
  && [[ "$(jq -r .state "$RN/gh/prs/4.json" 2>/dev/null)" == "OPEN" ]] \
  && ! grep -q '^pr close' "$RN/gh/calls" \
  && [[ -n "$(git -C "$RN/remote.git" rev-parse --verify -q "refs/heads/$(jq -r .headRefName "$RN/gh/prs/4.json")")" ]] \
  && ok "retry: --retry on an in-flight (pr-open) issue is refused — PR stays open, branch kept" \
  || note "retry not parked: rc1=$(cat "$RN/rc1") rc=$RC — $(tail -2 "$RN/err" | tr '\n' '|'), PR #4=$(jq -r .state "$RN/gh/prs/4.json" 2>/dev/null)"

finish
