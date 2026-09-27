#!/usr/bin/env bash
# skills/deliver/review.sh — the independent review step of /deliver
# (docs/prd/0003-deliver.md § Review). Sourced by deliver.sh; needs
# skills/autopilot/agent.sh (agent_run) and jq.
#
# The reviewer is agents/code-reviewer.md, inlined into one `claude -p` call
# (the same way loop.sh inlines agents/verifier.md) and run:
#   - in a throwaway `git worktree` of the exact head under review, never in
#     the runner's checkout;
#   - with a read-only allowlist (no Edit/Write, no git that changes state,
#     no gh);
#   - between two snapshots of the runner's checkout. Any difference is a
#     safety breach, not a bad review: the caller fails the whole run (#52 —
#     a reviewer that moved HEAD once would have sent the next commit to the
#     wrong branch).
#
# The verdict is the runner's, not the model's: review_parse() recomputes it
# from the findings by the rule in code-reviewer.md ("changes_requested iff an
# in-scope blocker or issue"), so a reviewer that lists a blocker and then
# says "approve" still holds the change.

REVIEW_ALLOWED_TOOLS="Read,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git show:*)"

# review_snapshot — the parts of the runner's checkout a review must not
# change: branch, HEAD, tree status, the verify-status file, the worktree list.
review_snapshot() {
  git branch --show-current 2>/dev/null
  git rev-parse HEAD 2>/dev/null
  git status --porcelain 2>/dev/null
  if [[ -f tmp/.last-verify-status ]]; then
    cksum < tmp/.last-verify-status
  else
    echo "verify-status: absent"
  fi
  git worktree list --porcelain 2>/dev/null
}

# review_prompt <agent_md> <issue> <round> <base_ref> <base_sha> <head_sha> <charter_file> [previous_findings_json]
review_prompt() {
  local agent="$1" n="$2" round="$3" base="$4" base_sha="$5" head_sha="$6" charter="$7" prev="${8:-}"
  local body prev_section=""
  body="$(sed '1{/^---$/!q;};1,/^---$/d' "$agent" 2>/dev/null)"
  if [[ -n "$prev" && "$prev" != "[]" ]]; then
    prev_section="
Findings of review round $(( round - 1 )) — for each one this head fixes, put its id in \"resolved\":
\`\`\`json
$prev
\`\`\`
"
  fi
  cat <<EOF
$body

---
## This review (set by the /deliver runner)

- Issue #$n, review round $round. Base: \`$base\` at \`$base_sha\`. Head: \`$head_sha\`.
- Your working directory is a throwaway checkout of the head. Read the diff
  with \`git diff $base_sha...$head_sha\`. The section "Working tree is
  read-only" applies in full.
- The charter below is the scope: a finding is \`in_scope\` when the charter
  requires it or this diff introduces it.
- Nobody can answer a question; decide, say why, and end with the JSON block.
$prev_section
## Charter

$(cat "$charter" 2>/dev/null)
EOF
}

# review_parse <raw_text>
#   Echoes the normalized verdict JSON
#     {"verdict":"approve|changes_requested","model_verdict":…,"findings":[…],"resolved":[…]}
#   or returns 1 when the reply carries no usable verdict (no JSON block, not
#   an object, or a "verdict" that is neither approve nor changes_requested —
#   a reviewer that did not follow the contract has not reviewed).
review_parse() {
  local raw="$1" block
  # The last ```json fenced block; a bare JSON object reply is accepted too.
  block="$(printf '%s\n' "$raw" | awk '
    /^[[:space:]]*```json[[:space:]]*$/ { inb=1; cur=""; next }
    inb && /^[[:space:]]*```[[:space:]]*$/ { inb=0; last=cur; next }
    inb { cur = cur $0 "\n" }
    END { printf "%s", last }')"
  [[ -n "$block" ]] || block="$raw"
  printf '%s' "$block" | jq -ce '
    select(type == "object")
    | select(.verdict == "approve" or .verdict == "changes_requested")
    | (.findings // []) as $f
    | select($f | type == "array")
    | {
        model_verdict: .verdict,
        findings: [ $f[] | select(type == "object")
                    | .severity = ((.severity // "suggestion") | ascii_downcase)
                    | .in_scope = (.in_scope != false) ],
        resolved: (.resolved // [])
      }
    | .verdict = (if any(.findings[]; .in_scope and (.severity == "blocker" or .severity == "issue"))
                  then "changes_requested" else "approve" end)
  ' 2>/dev/null
}

# review_run <issue> <round> <base_ref> <base_sha> <head_sha> <charter> <out_prefix> <model> [previous_findings_json]
#   Runs one review. Writes <out_prefix>.md (the reviewer's report) and, when
#   it parsed, <out_prefix>.json (review_parse output).
#   Returns 0 parsed, 2 no usable verdict, 3 SAFETY BREACH (the runner's
#   checkout changed during the review — the caller must stop the run),
#   4 the throwaway worktree could not be created.
review_run() {
  local n="$1" round="$2" base="$3" base_sha="$4" head_sha="$5" charter="$6" out="$7" model="$8" prev="${9:-}"
  local before after wt parsed prompt
  before="$(review_snapshot)"
  wt="$(mktemp -d "${TMPDIR:-/tmp}/deliver-review.XXXXXX")" || return 4
  if ! git worktree add -q --detach "$wt" "$head_sha" 2>/dev/null; then
    rmdir "$wt" 2>/dev/null; return 4
  fi
  prompt="$(review_prompt "$REVIEW_AGENT" "$n" "$round" "$base" "$base_sha" "$head_sha" "$charter" "$prev")"
  agent_run "review" "$model" "$REVIEW_ALLOWED_TOOLS" "acceptEdits" "$prompt" "$wt"
  git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
  git worktree prune 2>/dev/null
  after="$(review_snapshot)"
  printf '%s\n' "$AGENT_LAST_RESULT" > "$out.md"
  if [[ "$before" != "$after" ]]; then
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") > "$out.breach" 2>&1
    return 3
  fi
  parsed="$(review_parse "$AGENT_LAST_RESULT")" || return 2
  printf '%s\n' "$parsed" > "$out.json"
  return 0
}

# review_comment <issue> <round> <head_sha> <report_md> <verdict_json|""> > comment.md
#   The PR comment: a marker a resumed run can find (never post the same
#   review twice), the runner's verdict, then the reviewer's own report.
review_comment() {
  local n="$1" round="$2" head="$3" report="$4" vjson="$5" verdict model_verdict counts
  if [[ -n "$vjson" && -f "$vjson" ]]; then
    verdict="$(jq -r '.verdict' "$vjson")"
    model_verdict="$(jq -r '.model_verdict' "$vjson")"
    counts="$(jq -r '[(.findings | map(select(.in_scope and .severity=="blocker")) | length),
                       (.findings | map(select(.in_scope and .severity=="issue")) | length),
                       (.findings | map(select(.in_scope | not)) | length),
                       (.findings | map(select(.severity=="suggestion")) | length)]
                     | "in-scope blockers: \(.[0]) · in-scope issues: \(.[1]) · out of scope: \(.[2]) · suggestions: \(.[3])"' "$vjson")"
  else
    verdict="no verdict"; model_verdict="—"; counts="the reviewer's reply carried no usable JSON verdict"
  fi
  echo "<!-- deliver:review issue=$n round=$round head=$head -->"
  echo "## Independent review — round $round (\`code-reviewer\` via \`/deliver\`)"
  echo
  echo "**Runner verdict: $verdict** (reviewer said: $model_verdict) — $counts"
  echo
  echo "<details><summary>Reviewer's report</summary>"
  echo
  cat "$report"
  echo
  echo "</details>"
}
