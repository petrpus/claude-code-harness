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
# shellcheck source=../skills/deliver/review.sh
. skills/deliver/review.sh

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
# Unit: review.sh
# ===========================================================================
echo "-- review.sh"
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
review_parse 'Could you clarify?' >/dev/null && note "parse: prose was accepted as a verdict" \
  || ok "parse: prose without a JSON block is no verdict"
review_parse '{"verdict":"lgtm","findings":[]}' >/dev/null && note "parse: an off-contract verdict was accepted" \
  || ok "parse: a verdict other than approve/changes_requested is no verdict"
review_parse '{"verdict":"approve","findings":"none"}' >/dev/null && note "parse: non-array findings accepted" \
  || ok "parse: findings that are not an array are no verdict"

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
  "auth status") [[ -n "${FAKE_GH_UNAUTH:-}" ]] && exit 1; exit 0 ;;
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
  "pr comment")
    f="$S/prs/$1.json"; [[ -f "$f" ]] || exit 1; b="$(arg --body-file "$@")" || exit 64
    jq --rawfile body "$b" '.comments = ((.comments // []) + [{body:$body}])' "$f" > "$f.tmp" && mv "$f.tmp" "$f" ;;
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
    mode="${STUB_REVIEW:-approve}"
    if [[ "$mode" == "garbage-once" ]]; then
      if [[ -f "${STUB_REVIEW_STATE:?}" ]]; then mode=approve; else touch "$STUB_REVIEW_STATE"; mode=garbage; fi
    fi
    case "$mode" in
      approve)    r="$(review_json approve '[{"id":"S1","severity":"suggestion","file":"a","line":1,"note":"nit","in_scope":true}]')" ;;
      blocker)    r="$(review_json changes_requested '[{"id":"B1","severity":"blocker","file":"a","line":1,"note":"broken","in_scope":true}]')" ;;
      liar)       r="$(review_json approve '[{"id":"I1","severity":"issue","file":"a","line":1,"note":"real problem","in_scope":true}]')" ;;
      outofscope) r="$(review_json approve '[{"id":"I1","severity":"issue","file":"b","line":9,"note":"old bug","in_scope":false,"issue_title":"fix: old bug"}]')" ;;
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
run_deliver happy STUB_REVIEW_LOG="$WORK/happy/review.log"
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
[[ "$REVIEW_PERMS" == $'Read,Grep,Glob\tBash,Edit,Write,MultiEdit,NotebookEdit,WebFetch,WebSearch\tdefault' ]] \
  && ok "review: no shell and no write tool — Read/Grep/Glob allowed, Bash/Edit/Write disallowed, default mode" \
  || note "review: permissions were '$(tr '\t' '|' <<<"$REVIEW_PERMS")'"
[[ "$(cut -f5 "$WORK/happy/review.log" | sort -u)" == "yes" ]] \
  && ok "review: the runner inlines the commits, stat and diff into the prompt" \
  || note "review: the diff was not inlined"
[[ "$(cat "$RUNDIR"/run-*.jsonl 2>/dev/null | jq -s '[.[] | select(.phase=="review" and .verdict=="approve")] | length')" -eq 2 ]] \
  && ok "review: both calls are in the run's own log (phase review, issue, verdict, cost)" \
  || note "review: run log rows missing under $RUNDIR"

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

# --- missing tools: refused before anything is copied or called --------------
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
for tool in jq gh; do
  new_fixture "no$tool"
  path_without "$WORK/no$tool/bin" "$tool"
  ( cd "$WORK/no$tool/repo" && env PATH="$WORK/no$tool/bin" FAKE_GH_DIR="$WORK/no$tool/gh" \
      XDG_STATE_HOME="$WORK/no$tool/state" \
      "$(command -v bash)" "$DELIVER_ABS" --map 3 --verify-cmd true >"$WORK/no$tool/out" 2>"$WORK/no$tool/err" )
  RC=$?
  [[ "$RC" -eq 1 ]] && grep -q "'$tool'" "$WORK/no$tool/err" \
    && [[ -z "$(ls -A "$WORK/no$tool/state" 2>/dev/null)" && ! -s "$WORK/no$tool/gh/calls" ]] \
    && ok "refuses a machine without $tool (exit 1), with no runner copy and no forge call" \
    || note "without $tool: exit $RC, err: $(tail -1 "$WORK/no$tool/err")"
done
new_fixture unauth
run_deliver unauth FAKE_GH_UNAUTH=1
RC=$?
[[ "$RC" -eq 1 ]] && grep -q "not authenticated" "$WORK/unauth/err" \
  && [[ -z "$(ls -A "$WORK/unauth/state" 2>/dev/null)" ]] \
  && ok "refuses an unauthenticated gh before copying the runner" \
  || note "unauthenticated gh: exit $RC, state: $(ls -A "$WORK/unauth/state" 2>/dev/null)"

# --- a Map edited mid-run into an invalid one stops with its own name ----------
new_fixture midedit
run_deliver midedit FAKE_GH_AFTER_FIRST_MERGE_BODY='- [ ] #2 Second thing (after: #1)' -- 
RC=$?
[[ "$RC" -eq 1 ]] && grep -q "became invalid mid-run" "$WORK/midedit/err" \
  && ok "a Map edited mid-run into a duplicate line stops with a validation error" \
  || note "mid-run invalid Map: exit $RC, err: $(tail -1 "$WORK/midedit/err")"

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

# --- review verdicts that hold a PR (#59) --------------------------------------
# held <name> <what> — the run stopped at #1 with PR #4 open and unmerged,
# nothing ticked and integration/x untouched.
held() {
  local d="$WORK/$1"
  [[ "$(jq -r .state "$d/gh/prs/4.json" 2>/dev/null)" == "OPEN" ]] \
    && ! grep -q '^pr merge' "$d/gh/calls" \
    && [[ "$(jq -r .body "$d/gh/issues/3.json")" != *"[x]"* ]] \
    && [[ "$(git -C "$d/remote.git" rev-parse integration/x)" == "$(git -C "$d/remote.git" rev-parse main)" ]]
}
new_fixture rvblock
run_deliver rvblock STUB_REVIEW=blocker
RC=$?
[[ "$RC" -eq 1 ]] && held rvblock && jq -r '.comments[0].body' "$WORK/rvblock/gh/prs/4.json" | grep -q 'Runner verdict: changes_requested' \
  && ok "review: an in-scope blocker holds the PR open, posts the review, merges nothing" \
  || note "review blocker: exit $RC"

new_fixture rvliar
run_deliver rvliar STUB_REVIEW=liar
RC=$?
[[ "$RC" -eq 1 ]] && held rvliar \
  && jq -r '.comments[0].body' "$WORK/rvliar/gh/prs/4.json" | grep -qF '**Runner verdict: changes_requested** (reviewer said: approve)' \
  && ok "review: 'approve' with an in-scope issue is overruled by the runner" \
  || note "review liar: exit $RC"

new_fixture rvoos
run_deliver rvoos STUB_REVIEW=outofscope
RC=$?
[[ "$RC" -eq 0 && "$(jq -r .state "$WORK/rvoos/gh/prs/4.json")" == "MERGED" ]] \
  && ok "review: an out-of-scope finding does not block the merge" \
  || note "review out-of-scope: exit $RC"

new_fixture rvgarbage
run_deliver rvgarbage STUB_REVIEW=garbage STUB_REVIEW_LOG="$WORK/rvgarbage/review.log"
RC=$?
[[ "$RC" -eq 1 ]] && held rvgarbage && [[ "$(grep -c . "$WORK/rvgarbage/review.log")" -eq 2 ]] \
  && jq -r '.comments[0].body' "$WORK/rvgarbage/gh/prs/4.json" | grep -q 'Runner verdict: no verdict' \
  && ok "review: no usable verdict is retried once, then holds the PR (fail closed)" \
  || note "review garbage: exit $RC, calls $(grep -c . "$WORK/rvgarbage/review.log" 2>/dev/null)"

new_fixture rvretry
run_deliver rvretry STUB_REVIEW=garbage-once STUB_REVIEW_STATE="$WORK/rvretry/review.state"
RC=$?
[[ "$RC" -eq 0 ]] && [[ "$(cat "$WORK"/rvretry/repo/tmp/deliver/*/run-*.jsonl | jq -s '[.[] | select(.phase=="review") | .verdict] | join(",")')" == '"no_verdict,approve,approve"' ]] \
  && ok "review: one inconclusive reply then a real verdict proceeds (logged as no_verdict, approve)" \
  || note "review retry: exit $RC"

new_fixture rvmutate
run_deliver rvmutate STUB_REVIEW=mutate
RC=$?
[[ "$RC" -eq 1 ]] && grep -q 'SAFETY BREACH' "$WORK/rvmutate/err" && ! grep -q '^pr merge' "$WORK/rvmutate/gh/calls" \
  && [[ "$(jq -r .body "$WORK/rvmutate/gh/issues/3.json")" != *"[x]"* ]] \
  && ok "review: a reviewer that moves the runner's checkout fails the whole run, nothing merges" \
  || note "review mutate: exit $RC, err: $(tail -1 "$WORK/rvmutate/err")"

for m in mutate-ref mutate-tmp mutate-hook; do
  new_fixture "rv$m"
  run_deliver "rv$m" STUB_REVIEW="$m"
  RC=$?
  [[ "$RC" -eq 1 ]] && grep -q 'SAFETY BREACH' "$WORK/rv$m/err" && ! grep -q '^pr merge' "$WORK/rv$m/gh/calls" \
    && ok "review: $m (a write the checkout's status cannot see) is still a safety breach" \
    || note "review $m: exit $RC, err: $(tail -1 "$WORK/rv$m/err")"
done

new_fixture rvexample
run_deliver rvexample STUB_REVIEW=example-after
RC=$?
[[ "$RC" -eq 0 && "$(jq -r .state "$WORK/rvexample/gh/prs/4.json")" == "MERGED" ]] \
  && ok "review: a clean verdict followed by the restated format example still merges" \
  || note "review example-after: exit $RC"

new_fixture rvwronghead
run_deliver rvwronghead STUB_REVIEW=wrong-head
RC=$?
[[ "$RC" -eq 1 ]] && held rvwronghead \
  && ok "review: a verdict for a different head is no verdict (held)" \
  || note "review wrong-head: exit $RC"

# --- a merge refused by the forge stops the run -------------------------------
new_fixture refused
run_deliver refused FAKE_GH_MERGE_FAIL=1
RC=$?
[[ "$RC" -eq 1 ]] && grep -q "merge of PR #4 refused" "$WORK/refused/err" \
  && [[ "$(jq -r .body "$WORK/refused/gh/issues/3.json")" != *"[x]"* ]] \
  && ok "a refused merge stops the run and ticks nothing" || note "refused merge: exit $RC"

finish
