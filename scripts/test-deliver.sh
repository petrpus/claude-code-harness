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

# shellcheck source=../skills/autopilot/plan.sh
. skills/autopilot/plan.sh
# shellcheck source=../skills/deliver/map.sh
. skills/deliver/map.sh
# shellcheck source=../skills/deliver/charter.sh
. skills/deliver/charter.sh

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

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
# Static: the forge surface (ADR-0007)
# ===========================================================================
echo "-- forge surface"
GH_CALLERS="$(grep -lE '(^|[;&|(]|[[:space:]])gh[[:space:]]+(issue|pr|api|repo|auth|label|run|release)' skills/deliver/*.sh skills/autopilot/*.sh 2>/dev/null | tr '\n' ' ')"
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
cmd="${1:-} ${2:-}"; shift 2 2>/dev/null || true
case "$cmd" in
  "auth status") exit 0 ;;
  "issue view")
    f="$S/issues/$1.json"; [[ -f "$f" ]] || { echo "no issue $1" >&2; exit 1; }
    cat "$f" ;;
  "issue edit")
    f="$S/issues/$1.json"; b="$(arg --body-file "$@")" || exit 64
    jq --rawfile body "$b" '.body = $body' "$f" > "$f.tmp" && mv "$f.tmp" "$f" ;;
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
  "pr view")
    f="$S/prs/$1.json"; [[ -f "$f" ]] || exit 1; cat "$f" ;;
  "pr merge")
    n="$1"; shift; f="$S/prs/$n.json"; [[ -f "$f" ]] || exit 1
    has --squash "$@" || { echo "fake gh: only --squash is modelled" >&2; exit 64; }
    has --admin "$@" && { echo "fake gh: --admin used" >&2; exit 65; }
    sha="$(arg --match-head-commit "$@")"; subject="$(arg --subject "$@")"; b="$(arg --body-file "$@")"
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
        && git merge -q --squash "origin/$head" >/dev/null \
        && git -c user.email=gh@fake -c user.name=fake-gh commit -q -m "$subject" -m "$(cat "${b:-/dev/null}")" \
        && git push -q origin "$base" ) || { rm -rf "$tmp"; exit 1; }
    moid="$(git -C "$tmp/c" rev-parse HEAD)"; rm -rf "$tmp"
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
case "$prompt" in
  *"PLAN phase"*|*"autonomous run is stuck"*)
    printf -- '- [ ] S1 — part one\n- [ ] S2 — part two (after: S1)\n\nSTATUS: in-progress\n' > "$plan"
    emit '"planned"' ;;
  *"ONE iteration of an autonomous BUILD loop"*)
    if [[ "${STUB_MODE:-progress}" == "progress" ]]; then
      n="$(printf '%s' "$plan" | grep -oE 'issues/[0-9]+' | cut -d/ -f2)"
      sel="$(printf '%s' "$prompt" | grep -oE 'plan item `[^`]+`' | head -1 | sed -E 's/plan item `([^`]+)`/\1/')"
      mkdir -p work && echo "issue $n slice $sel" >> "work/issue-$n.txt"
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
  local d="$WORK/$1"
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
}

# run_deliver <name> [extra env as VAR=value...] -- [deliver args...]
run_deliver() {
  local name="$1"; shift
  local d="$WORK/$name" envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  ( cd "$d/repo" && env PATH="$BIN:$PATH" FAKE_GH_DIR="$d/gh" XDG_STATE_HOME="$d/state" \
      GIT_CMD_LOG="$d/git.calls" ${envs[@]+"${envs[@]}"} \
      bash "$DELIVER_ABS" --map 3 --verify-cmd true --issue-max-iterations 6 "$@" \
      >"$d/out" 2>"$d/err" )
}

# --- happy path: two dependent issues ----------------------------------------
new_fixture happy
MAIN_BEFORE="$(git -C "$WORK/happy/remote.git" rev-parse main)"
run_deliver happy
RC=$?
H="$WORK/happy"
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

# --- refusals ------------------------------------------------------------------
new_fixture onmain
git -C "$WORK/onmain/repo" switch -q main
run_deliver onmain
RC=$?
[[ "$RC" -eq 1 ]] && grep -q "refusing to merge into 'main'" "$WORK/onmain/err" && [[ ! -s "$WORK/onmain/gh/calls" ]] \
  && ok "refuses main (exit 1) before any forge call" \
  || note "on main: exit $RC, gh calls: $(tr '\n' '|' < "$WORK/onmain/gh/calls" 2>/dev/null)"

new_fixture dirty
echo junk > "$WORK/dirty/repo/untracked.txt"
run_deliver dirty
RC=$?
[[ "$RC" -eq 1 ]] && grep -q "working tree is dirty" "$WORK/dirty/err" && [[ ! -s "$WORK/dirty/gh/calls" ]] \
  && ok "refuses a dirty tree (exit 1) before any forge call" \
  || note "dirty tree: exit $RC"

new_fixture nomap
jq '.body = "no delivery section here"' "$WORK/nomap/gh/issues/3.json" > "$WORK/nomap/x" && mv "$WORK/nomap/x" "$WORK/nomap/gh/issues/3.json"
run_deliver nomap
RC=$?
[[ "$RC" -eq 1 ]] && grep -q "has no '## Delivery' lines" "$WORK/nomap/err" \
  && ok "refuses a Map without a Delivery section" || note "no-delivery map: exit $RC"

new_fixture behind
git -C "$WORK/behind/repo" commit -q --allow-empty -m "local only"
run_deliver behind
RC=$?
[[ "$RC" -eq 1 ]] && grep -q "not in sync with origin" "$WORK/behind/err" \
  && ok "refuses an integration branch that is not in sync with origin" || note "out-of-sync branch: exit $RC"

# --- an issue that does not finish stops the run, nothing is opened -----------
new_fixture stall
run_deliver stall STUB_MODE=stall -- --issue-max-iterations 2
RC=$?
S="$WORK/stall"
[[ "$RC" -eq 1 ]] && ! grep -q '^pr create' "$S/gh/calls" \
  && [[ "$(jq -r .body "$S/gh/issues/3.json")" != *"[x]"* ]] \
  && ok "an issue whose autopilot run does not finish stops the run: no PR, nothing ticked" \
  || note "stalled issue: exit $RC, calls: $(grep -c . "$S/gh/calls")"
[[ "$(git -C "$S/remote.git" rev-parse integration/x)" == "$(git -C "$S/remote.git" rev-parse main)" ]] \
  && ok "a stopped run leaves integration/x untouched" || note "stalled run moved integration/x"

# --- a merge refused by the forge stops the run -------------------------------
new_fixture refused
run_deliver refused FAKE_GH_MERGE_FAIL=1
RC=$?
[[ "$RC" -eq 1 ]] && grep -q "merge of PR #4 refused" "$WORK/refused/err" \
  && [[ "$(jq -r .body "$WORK/refused/gh/issues/3.json")" != *"[x]"* ]] \
  && ok "a refused merge stops the run and ticks nothing" || note "refused merge: exit $RC"

finish
