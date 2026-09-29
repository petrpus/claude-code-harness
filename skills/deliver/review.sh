#!/usr/bin/env bash
# skills/deliver/review.sh — the independent review step of /deliver
# (docs/prd/0003-deliver.md § Review). Sourced by deliver.sh; needs
# skills/autopilot/agent.sh (agent_run) and jq.
#
# The reviewer is agents/code-reviewer.md, inlined into one `claude -p` call
# (the way loop.sh inlines agents/verifier.md). Three layers keep it from
# changing anything the runner relies on (#52):
#
#   1. No write primitive at all. The reviewer gets Read / Grep / Glob only,
#      under the `default` permission mode (anything not allowed is denied in
#      a headless call), with Bash / Edit / Write explicitly disallowed. There
#      is no shell: `git diff --output=<file>` is a write, so even a
#      "read-only" git allowlist is not one. The runner computes the diff and
#      inlines it into the prompt instead.
#   2. A throwaway `git worktree` of the exact head as its working directory,
#      never the runner's checkout.
#   3. Two snapshots of the runner's checkout around the call — every ref
#      (branches, the base, remote-tracking refs, stash), HEAD, tracked and
#      untracked changes, the repo's config, hooks and info/, the worktree
#      list, and the content of every file under tmp/ (ignored, so invisible
#      to `git status`, yet it holds the charter, the PR body and the verify
#      status). Any difference is a safety breach and the caller ends the run.
#
# The verdict is the runner's, not the model's: review_parse() only accepts a
# JSON block that names the head under review (so a restated example from the
# reviewer's own instructions can never be mistaken for the verdict), and
# recomputes the verdict from its findings by the rule in code-reviewer.md.

REVIEW_ALLOWED_TOOLS="Read,Grep,Glob"
# Explicit, not left to allowlist omission: Task/Agent could start a subagent
# carrying its own tool grant (a shell, say), reopening the hole this closes.
REVIEW_DISALLOWED_TOOLS="Bash,Edit,Write,MultiEdit,NotebookEdit,WebFetch,WebSearch,Task,Agent,TodoWrite,Skill"
REVIEW_PERMISSION_MODE="default"
REVIEW_MAX_DIFF_BYTES="${REVIEW_MAX_DIFF_BYTES:-300000}"
REVIEW_WT=""   # the live throwaway worktree, for review_cleanup

# review_snapshot — everything a review must leave exactly as it found it.
review_snapshot() {
  local common f
  common="$(git rev-parse --git-common-dir 2>/dev/null)"
  echo "branch: $(git branch --show-current 2>/dev/null)"
  echo "HEAD: $(git rev-parse HEAD 2>/dev/null)"
  echo "-- status"; git status --porcelain 2>/dev/null
  echo "-- refs"; git for-each-ref --format='%(refname) %(objectname)' 2>/dev/null
  echo "-- repo files"
  for f in "$common/config" "$common/HEAD"; do [[ -f "$f" ]] && cksum < "$f"; done
  find "$common/hooks" "$common/info" -type f -exec cksum {} + 2>/dev/null | LC_ALL=C sort
  echo "-- worktrees"; git worktree list --porcelain 2>/dev/null
  echo "-- tmp"
  [[ -d tmp ]] && find tmp -type f -exec cksum {} + 2>/dev/null | LC_ALL=C sort
  return 0
}

# md_tilde_fence — stdin text; prints a tilde fence one longer than any
# tilde run that could open or close a fence inside it (optionally after a
# diff's +/-/space marker and up to three spaces of indent), never shorter
# than five. Backtick fences collide with every Markdown file that has code
# blocks; a fixed tilde fence with any text that happens to use one.
md_tilde_fence() {
  local longest
  longest="$(grep -oE '^[+ -]?[ ]{0,3}~+' | tr -cd '~\n' | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')"
  (( longest < 4 )) && longest=4
  printf '%*s' $(( longest + 1 )) '' | tr ' ' '~'
}

# review_diff <base_sha> <head_sha> — commits, stat and the diff itself,
# the diff cut at REVIEW_MAX_DIFF_BYTES with a note (the full head is in the
# reviewer's working directory to Read).
review_diff() {
  local base="$1" head="$2" diff bytes fence
  diff="$(git diff "$base...$head" 2>/dev/null)"
  fence="$(printf '%s\n' "$diff" | md_tilde_fence)"
  echo "### Commits"; echo
  git log --format='- %h %s' "$base..$head" 2>/dev/null
  echo; echo "### Diff stat"; echo; echo "$fence"
  git diff --stat "$base...$head" 2>/dev/null
  echo "$fence"; echo; echo "### Diff"; echo
  # ${#diff} and ${diff:0:N} count characters under a UTF-8 locale (the
  # normal case), so the cut never splits a multi-byte character there.
  bytes="${#diff}"
  echo "${fence}diff"
  if (( bytes > REVIEW_MAX_DIFF_BYTES )); then
    printf '%s\n' "${diff:0:$REVIEW_MAX_DIFF_BYTES}"
    echo "$fence"
    echo
    echo "(diff truncated at $REVIEW_MAX_DIFF_BYTES of $bytes characters — Read the changed files listed in the stat above from your working directory for the rest)"
  else
    printf '%s\n' "$diff"
    echo "$fence"
  fi
}

# review_prompt <agent_md> <issue> <round> <base_ref> <base_sha> <head_sha> <charter_file> [previous_findings_json]
review_prompt() {
  local agent="$1" n="$2" round="$3" base="$4" base_sha="$5" head_sha="$6" charter="$7" prev="${8:-}"
  local body prev_section=""
  body="$(sed '1{/^---$/!q;};1,/^---$/d' "$agent" 2>/dev/null)"
  if [[ -n "$prev" && "$prev" != "[]" ]]; then
    prev_section="
Findings of review round $(( round - 1 )) — list the id of every one this head fixes in \"resolved\":

$prev
"
  fi
  cat <<EOF
$body

---
## This review (set by the /deliver runner)

- Issue #$n, review round $round. Base: \`$base\` at \`$base_sha\`. Head: \`$head_sha\`.
- **You have no shell.** The commits, stat and diff are below; the head's
  files are in your working directory (a throwaway checkout) — use Read, Grep
  and Glob on them. Ignore the git commands in "What to do"; this section
  replaces them.
- The charter below is the scope: a finding is \`in_scope\` when the charter
  requires it or this diff introduces it.
- Your final JSON block **must** also carry \`"head": "$head_sha"\` — a block
  without it is not read as your verdict.
- Nobody can answer a question; decide, say why, and end with the JSON block.
$prev_section
## Charter

$(cat "$charter" 2>/dev/null)

## The change

$(review_diff "$base_sha" "$head_sha")
EOF
}

# _review_blocks <raw> — every fenced ```json block, NUL-separated.
_review_blocks() {
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*```json[[:space:]]*$/ { inb=1; cur=""; next }
    inb && /^[[:space:]]*```[[:space:]]*$/ { inb=0; printf "%s%c", cur, 0; next }
    inb { cur = cur $0 "\n" }'
}

# review_parse <raw_text> [head_sha]
#   Echoes the normalized verdict JSON
#     {"verdict":"approve|changes_requested","model_verdict":…,"head":…,"findings":[…],"resolved":[…]}
#   from the LAST fenced json block (or a bare JSON reply) that is a verdict
#   object — and, when head_sha is given, that names that head. Returns 1 when
#   there is none: no block, an off-contract verdict, findings that are not a
#   list, or no block bound to this head.
review_parse() {
  local raw="$1" head="${2:-}" block chosen="" found=0
  local -a blocks=()
  while IFS= read -r -d '' block; do blocks+=("$block"); done < <(_review_blocks "$raw")
  [[ ${#blocks[@]} -gt 0 ]] || blocks=("$raw")
  for block in "${blocks[@]}"; do
    if printf '%s' "$block" | jq -e --arg h "$head" '
         type == "object"
         and (.verdict == "approve" or .verdict == "changes_requested")
         and ((.findings // []) | type == "array")
         and ($h == "" or .head == $h)' >/dev/null 2>&1; then
      chosen="$block"; found=1
    fi
  done
  [[ "$found" -eq 1 ]] || return 1
  printf '%s' "$chosen" | jq -c '
    {
      model_verdict: .verdict,
      head: (.head // null),
      findings: [ (.findings // [])[] | select(type == "object")
                  | .severity = ((.severity // "suggestion") | ascii_downcase)
                  | .in_scope = (.in_scope != false) ],
      resolved: (.resolved // [])
    }
    | .verdict = (if any(.findings[]; .in_scope and (.severity == "blocker" or .severity == "issue"))
                  then "changes_requested" else "approve" end)'
}

# review_fix_items <round> <findings_json>
#   A review round's in-scope blocker/issue findings as fresh plan checklist
#   lines: "- [ ] R<round>.<j> — <severity> <file>:<line>: <note>", 1-based
#   per round (#63). Out-of-scope findings and suggestions never appear here
#   — they are only ever surfaced in the PR comment (review_comment below).
#   Everything after the id is reviewer-authored text crossing into plan
#   syntax, so it is flattened to one line (a newline could start a plan item
#   of its own) and any `(after:` in it is defused — a trailing `(after: …)`
#   is plan.sh's blocker clause, and a bogus one turns the plan into a DAG
#   error mid-round.
review_fix_items() {
  local round="$1" findings="$2"
  printf '%s' "$findings" | jq -r --arg round "$round" '
    def plan_safe: tostring | gsub("[[:cntrl:]]+"; " ") | gsub("\\(\\s*after\\s*:"; "(after -"; "i");
    [ .[] | select(.in_scope and (.severity == "blocker" or .severity == "issue")) ] |
    to_entries[] |
    "- [ ] R\($round).\(.key + 1) — " +
    ("\(.value.severity) \(.value.file // "?"):\(.value.line // "?"): \(.value.note // "")" | plan_safe)'
}

# review_out_of_scope_items <findings_json>
#   Every out-of-scope blocker/issue finding (suggestions are skipped, same
#   rule as review_fix_items, #63) as TSV rows: file, line, severity, note,
#   issue_title (the reviewer's suggested follow-up title, may be empty).
review_out_of_scope_items() {
  printf '%s' "$1" | jq -r '
    .[] | select((.in_scope | not) and (.severity == "blocker" or .severity == "issue")) |
    [ (.file // "?"), ((.line // "?") | tostring), .severity, (.note // ""), (.issue_title // "") ] | @tsv'
}

# finding_hash <file> <line> <severity>
#   sha256 of the finding's normalized file/line/severity — an out-of-scope
#   finding's identity across review rounds, autopilot re-runs and repeated
#   /deliver invocations against the same forge state (#63): unless an issue
#   already carries `<!-- deliver:finding <hash> -->`, a fresh one is opened.
#   The note is deliberately not part of it: every round is a fresh reviewer
#   call that words the same defect differently. An out-of-scope finding sits
#   in code the PR did not touch, so its line holds still between rounds.
finding_hash() {
  local norm
  norm="$(printf '%s\x1f%s\x1f%s' "$1" "$2" "$3" \
    | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed -E 's/^ +| +$//')"
  printf '%s' "$norm" | sha256sum | cut -d' ' -f1
}

# review_cleanup — remove the live throwaway worktree, if any. Safe to call
# repeatedly; deliver.sh also calls it from its EXIT/INT/TERM traps, so a
# killed run does not leave a worktree behind to confuse the next snapshot.
review_cleanup() {
  [[ -n "$REVIEW_WT" ]] || return 0
  git worktree remove --force "$REVIEW_WT" 2>/dev/null || rm -rf "$REVIEW_WT"
  git worktree prune 2>/dev/null
  REVIEW_WT=""
}

# review_run <issue> <round> <base_ref> <base_sha> <head_sha> <charter> <out_prefix> <model> [previous_findings_json]
#   Runs one review. Writes <out_prefix>.md (the reviewer's report),
#   <out_prefix>.json when it parsed, <out_prefix>.breach on a breach.
#   Returns 0 parsed, 2 no usable verdict (AGENT_LAST_RC tells a failed call
#   from an off-contract reply), 3 SAFETY BREACH (the runner's checkout
#   changed during the review — the caller must end the run), 4 the
#   throwaway worktree could not be created.
review_run() {
  local n="$1" round="$2" base="$3" base_sha="$4" head_sha="$5" charter="$6" out="$7" model="$8" prev="${9:-}"
  local before after scratch prompt parsed saved_log="${AGENT_STDERR_LOG:-}" saved_dis="${AGENT_DISALLOWED_TOOLS:-}"
  # Everything the call writes goes outside the checkout: the worktree under
  # a private scratch dir (not the literal `mktemp -d` of the PRD, so a
  # leftover is recognisable), claude's stderr beside it.
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/deliver-review.XXXXXX")" || return 4
  prompt="$(review_prompt "$REVIEW_AGENT" "$n" "$round" "$base" "$base_sha" "$head_sha" "$charter" "$prev")"
  before="$(review_snapshot)"
  REVIEW_WT="$scratch/head"
  if ! git worktree add -q --detach "$REVIEW_WT" "$head_sha" 2>/dev/null; then
    REVIEW_WT=""; rm -rf "$scratch"; return 4
  fi
  AGENT_STDERR_LOG="$scratch/claude-stderr.log"
  AGENT_DISALLOWED_TOOLS="$REVIEW_DISALLOWED_TOOLS"
  agent_run "review" "$model" "$REVIEW_ALLOWED_TOOLS" "$REVIEW_PERMISSION_MODE" "$prompt" "$REVIEW_WT"
  AGENT_STDERR_LOG="$saved_log"; AGENT_DISALLOWED_TOOLS="$saved_dis"
  review_cleanup
  after="$(review_snapshot)"
  # Only now write into the checkout: the report, and claude's stderr appended
  # to the run's log.
  printf '%s\n' "$AGENT_LAST_RESULT" > "$out.md"
  [[ -n "$saved_log" && -s "$scratch/claude-stderr.log" ]] && cat "$scratch/claude-stderr.log" >> "$saved_log"
  rm -rf "$scratch"
  if [[ "$before" != "$after" ]]; then
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") > "$out.breach" 2>&1
    return 3
  fi
  parsed="$(review_parse "$AGENT_LAST_RESULT" "$head_sha")" || return 2
  printf '%s\n' "$parsed" > "$out.json"
  return 0
}

# review_comment <issue> <round> <head_sha> <report_md> <verdict_json|""> > comment.md
#   The PR comment: a marker a resumed run can find (never post the same
#   review twice), the runner's verdict, then the reviewer's own report.
review_comment() {
  local n="$1" round="$2" head="$3" report="$4" vjson="$5" verdict model_verdict counts resolved=""
  if [[ -n "$vjson" && -f "$vjson" ]]; then
    verdict="$(jq -r '.verdict' "$vjson")"
    model_verdict="$(jq -r '.model_verdict' "$vjson")"
    counts="$(jq -r '[(.findings | map(select(.in_scope and .severity=="blocker")) | length),
                       (.findings | map(select(.in_scope and .severity=="issue")) | length),
                       (.findings | map(select(.in_scope | not)) | length),
                       (.findings | map(select(.severity=="suggestion")) | length)]
                     | "in-scope blockers: \(.[0]) · in-scope issues: \(.[1]) · out of scope: \(.[2]) · suggestions: \(.[3])"' "$vjson")"
    resolved="$(jq -r '(.resolved // []) | map(tostring) | join(", ")' "$vjson")"
  else
    verdict="no verdict"; model_verdict="—"; counts="the reviewer's reply carried no usable JSON verdict for this head"
  fi
  echo "<!-- deliver:review issue=$n round=$round head=$head -->"
  echo "## Independent review — round $round (\`code-reviewer\` via \`/deliver\`)"
  echo
  echo "**Runner verdict: $verdict** (reviewer said: $model_verdict) — $counts"
  if [[ "$round" -gt 1 && -n "$resolved" ]]; then
    echo
    echo "Resolved since round $((round - 1)): $resolved"
  fi
  echo
  echo "<details><summary>Reviewer's report</summary>"
  echo
  cat "$report"
  echo
  echo "</details>"
}
