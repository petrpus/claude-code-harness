#!/usr/bin/env bash
# skills/deliver/forge.sh — every forge mutation /deliver makes, in one file.
#
# ADR-0007: the runner may push, open and merge PRs, and write to issues; no
# model phase may. This file is the whole of that surface — deliver.sh is its
# only caller, and nothing else in the harness sources it. Keeping it small
# and explicit is what makes two things possible:
#   - the offline tests replace `gh` with a fake that implements exactly the
#     calls below (scripts/test-deliver.sh), and
#   - the guardrails are checkable by reading it: no force push, no --admin,
#     and remote branches are only ever deleted by name after a merge.
#
# All calls run in the current repo (gh resolves it from the origin remote).
# Bodies always go through files (--body-file), never argv, so no text a
# model wrote is ever parsed by a shell.

forge_preflight() {
  command -v gh >/dev/null 2>&1 || { echo "the 'gh' CLI is required"; return 1; }
  gh auth status >/dev/null 2>&1 || { echo "gh is not authenticated (run 'gh auth login')"; return 1; }
}

# forge_issue_json <number>  — number, title, body, url, labels, state
forge_issue_json() {
  gh issue view "$1" --json number,title,body,url,labels,state
}

# forge_issue_body <number> <out_file>  — the raw body, byte for byte
forge_issue_body() {
  forge_issue_json "$1" | jq -j '.body // ""' > "$2"
}

forge_issue_set_body() { gh issue edit "$1" --body-file "$2" >/dev/null; }   # <number> <file>
forge_issue_comment()  { gh issue comment "$1" --body-file "$2" >/dev/null; } # <number> <file>

# forge_issue_search <query>  — the number of the first open or closed issue
# whose title/body/comments match <query> (a finding-hash marker, #63), or
# nothing when there is none. Both states: a follow-up already triaged and
# closed must still dedupe against a recurring finding.
forge_issue_search() {
  gh issue list --search "$1" --state all --json number --jq '.[0].number // empty'
}

# forge_issue_create <title> <body_file> <label>  — a needs-triage follow-up
# issue (#63); echoes its number. The label must already exist
# (forge_label_ensure).
forge_issue_create() {
  local url
  url="$(gh issue create --title "$1" --body-file "$2" --label "$3")" || return 1
  url="$(printf '%s\n' "$url" | grep -oE '/issues/[0-9]+' | tail -1)"
  [[ -n "$url" ]] || return 1
  printf '%s\n' "${url##*/}"
}

# forge_pr_set_body <pr> <file>  — rewrite a PR's body (a fix round's updated
# plan, #63). Never touches the title.
forge_pr_set_body() { gh pr edit "$1" --body-file "$2" >/dev/null; }

# forge_push_branch <branch>  — first push of a branch the runner created.
# Never forced: a rejected push means someone else wrote the branch, and
# that is a reason to stop, not to overwrite.
forge_push_branch() { git push -q -u origin "$1"; }

# forge_push_update <branch>  — a later push of a branch already on the
# remote: final_verify folding in a moved integration branch, before or
# after the PR exists. Plain `git push`, never forced — a rejected push
# (someone else advanced the branch) stops the run rather than overwrite it.
forge_push_update() { git push -q origin "$1"; }

# forge_delete_remote_branch <branch>  — after its PR merged. Tolerates the
# forge having deleted it already (repos with auto-delete of head branches).
forge_delete_remote_branch() {
  if [[ -n "$(git ls-remote --heads origin "$1" 2>/dev/null)" ]]; then
    git push -q origin --delete "$1"
  fi
}

# forge_pr_create <base> <head> <title> <body_file>  — echoes the PR number
forge_pr_create() {
  local url
  url="$(gh pr create --base "$1" --head "$2" --title "$3" --body-file "$4")" || return 1
  url="$(printf '%s\n' "$url" | grep -oE '/pull/[0-9]+' | tail -1)"
  [[ -n "$url" ]] || return 1
  printf '%s\n' "${url##*/}"
}

# forge_pr_merge <pr> <head_sha> <subject> <body_file>
#   Squash merge, pinned to the head that was verified: if anything pushed to
#   the branch after verify, the forge refuses instead of merging unverified
#   code. The head branch is deleted separately (forge_delete_remote_branch)
#   so gh never touches the local checkout.
#   A repo whose branch protection forbids squash merges gets a plain merge
#   instead (--merge), still pinned to the same head. Any other refusal is
#   returned to the caller as is — deliver.sh retries once through
#   final_verify, then parks (#60).
forge_pr_merge() {
  local pr="$1" sha="$2" subject="$3" bodyf="$4" out rc
  out="$(gh pr merge "$pr" --squash --match-head-commit "$sha" --subject "$subject" --body-file "$bodyf" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  if [[ "$rc" -ne 0 ]] && grep -qi 'squash.*not allowed' <<<"$out"; then
    out="$(gh pr merge "$pr" --merge --match-head-commit "$sha" --subject "$subject" --body-file "$bodyf" 2>&1)"
    rc=$?
    printf '%s\n' "$out"
  fi
  return "$rc"
}

# forge_pr_comment <pr> <body_file>  — the review report. A comment, not a
# `gh pr review`: the runner authors the PR with the user's token, and GitHub
# refuses to let an author approve or request changes on their own PR.
forge_pr_comment() { gh pr comment "$1" --body-file "$2" >/dev/null; }

# forge_label_ensure <name> <color> <description> — create the label if the
# repo lacks it (gh refuses to add a label that does not exist). An existing
# label is left exactly as the repo has it.
forge_label_ensure() {
  # Every failure is swallowed, "already exists" and real ones alike: the add
  # that follows is what matters, and it reports its own failure.
  gh label create "$1" --color "$2" --description "$3" >/dev/null 2>&1 || true
}
forge_issue_add_label()    { gh issue edit "$1" --add-label "$2" >/dev/null; }    # <number> <label>
forge_issue_remove_label() { gh issue edit "$1" --remove-label "$2" >/dev/null; } # <number> <label>

# forge_pr_draft <pr> — back to draft: a parked issue's PR must not look
# ready to merge to a human skimming the PR list.
forge_pr_draft() { gh pr ready "$1" --undo >/dev/null; }

# forge_pr_close <pr> — closes without merging, never deleting the branch
# (forge_delete_remote_branch is the caller's own, explicit call): --retry #N
# discards an earlier attempt's PR before starting a fresh one (#61 S3).
forge_pr_close() { gh pr close "$1" >/dev/null; }

# forge_pr_state <pr>  — OPEN | MERGED | CLOSED
forge_pr_state() {
  gh pr view "$1" --json state | jq -r '.state'
}

# forge_pr_comment_has_marker <pr> <marker>  — true when a comment on the PR
# already carries this exact text. The dedupe key for review comments
# (review_comment's `<!-- deliver:review issue=N round=k head=<sha> -->`):
# a resumed run must never post the same review twice.
forge_pr_comment_has_marker() {
  gh pr view "$1" --json comments 2>/dev/null | jq -e --arg m "$2" \
    '[(.comments // [])[] | (.body // "") | select(contains($m))] | length > 0' >/dev/null 2>&1
}

# forge_issue_comment_has_marker <issue> <marker>  — same, for the issue's own
# comments: the park (`<!-- deliver:park issue=N -->`) and merged
# (`<!-- deliver:merged issue=N pr=P -->`) notices post there, not to a PR.
forge_issue_comment_has_marker() {
  gh issue view "$1" --json comments 2>/dev/null | jq -e --arg m "$2" \
    '[(.comments // [])[] | (.body // "") | select(contains($m))] | length > 0' >/dev/null 2>&1
}

# forge_pr_for_branch <branch>  — the number of the open or merged PR whose
# head is this branch; empty (rc 1) when there is none. A closed-without-merge
# PR does not count: that branch is free for a fresh attempt (--resume, #61 S3).
forge_pr_for_branch() {
  local n
  n="$(gh pr list --head "$1" --state all --json number,state 2>/dev/null \
       | jq -r '[.[] | select(.state=="OPEN" or .state=="MERGED")][0].number // empty')"
  [[ -n "$n" ]] || return 1
  printf '%s\n' "$n"
}

# forge_pr_checks <pr>  — JSON array of {name,state,bucket,link} for every
# check reported on the PR (ci_wait, #60). `gh pr checks` exits non-zero
# whenever a check is pending or failing, and again when none has reported
# yet at all — only the JSON on stdout matters here, so the exit code is not
# checked; no checks reported prints nothing on stdout, normalised to "[]".
forge_pr_checks() {
  local out
  out="$(gh pr checks "$1" --json name,state,bucket,link 2>/dev/null)"
  [[ -n "$out" ]] && printf '%s\n' "$out" || echo "[]"
  return 0
}

# forge_ci_failed_log <run_id> [lines]  — tail of a failed run's log
# (`gh run view <id> --log-failed`), <lines> lines (default 200; ci_wait's
# fix round, #60). Best-effort: a gh failure (rotated log, bad id) yields an
# empty string rather than stopping the caller — losing the log tail is a
# reason to hand the model less context, not to skip the fix round.
forge_ci_failed_log() {
  local run="$1" lines="${2:-200}"
  gh run view "$run" --log-failed 2>/dev/null | tail -n "$lines"
}

# forge_grant_violations <allowed_tools_csv>
#   Pure: which Claude Code permission rules in the list would hand a model
#   phase a forge operation (ADR-0007), or cannot be shown not to. Echoes one
#   "<rule>: <why>" per offending rule and returns 1 if there is any.
#
#   Fail closed: a `Bash(...)` rule is accepted only when its command is a
#   plain command — words made of [A-Za-z0-9._/+=:@%,-], separated by spaces,
#   optionally ending in `:*` or ` *` — and even then its program (by
#   basename) must not be gh / git / hub, a program that runs other programs
#   (env, command, exec, nice, timeout, xargs, eval, sudo, ssh, find, …), or
#   an interpreter without a script path (bash -c, bash:*, python3 -c).
#   Quotes, backslashes, $, ;, |, &, <, >, backticks, a leading VAR=value or
#   a wildcard inside the command are refused, not interpreted: each is a way
#   to spell `gh` that a denylist would have to anticipate. A blanket `Bash`
#   and a malformed rule are refused too. Rules for other tools pass.
#
#   This is defence in depth, not the boundary, and it cannot be complete:
#   BUILD edits files and may run the verify command and scripts it can
#   edit, and loop.sh's own base allowlist already grants npx / pnpm / node.
#   Withholding forge credentials from model calls is the boundary (#77).
forge_grant_violations() {
  local csv="$1" rule inner cmd base next bad=0 depth=0 cur="" ch i
  local -a rules=() toks=()
  local word='[A-Za-z0-9._/+=:@%,-]+'
  for (( i=0; i<${#csv}; i++ )); do
    ch="${csv:$i:1}"
    case "$ch" in
      "(") depth=$((depth+1)); cur+="$ch" ;;
      ")") (( depth > 0 )) && depth=$((depth-1)); cur+="$ch" ;;
      ",") if (( depth == 0 )); then rules+=("$cur"); cur=""; else cur+="$ch"; fi ;;
      *)   cur+="$ch" ;;
    esac
  done
  rules+=("$cur")
  for rule in "${rules[@]}"; do
    rule="$(printf '%s' "$rule" | tr '\t\n\r' '   ' | sed -E 's/^ +//; s/ +$//')"
    [[ -n "$rule" ]] || continue
    [[ "$rule" == Bash* ]] || continue
    if [[ "$rule" == "Bash" ]]; then echo "$rule: a blanket shell grant"; bad=1; continue; fi
    if [[ ! "$rule" =~ ^Bash\((.*)\)$ ]]; then echo "$rule: not a well-formed Bash(...) rule"; bad=1; continue; fi
    inner="${BASH_REMATCH[1]}"
    cmd="$(printf '%s' "$inner" | sed -E 's/:\*$//; s/ \*$//; s/^ +//; s/ +$//')"
    if [[ ! "$cmd" =~ ^${word}(\ +${word})*$ ]]; then
      echo "$rule: not a plain command (quotes, escapes, wildcards or shell syntax are refused)"; bad=1; continue
    fi
    read -ra toks <<<"$cmd"
    if [[ "${toks[0]}" == *=* ]]; then echo "$rule: starts with an environment assignment"; bad=1; continue; fi
    # Lowercased: on a case-insensitive filesystem (macOS, Windows) `GH`
    # resolves to the same binary as `gh`.
    base="$(printf '%s' "${toks[0]##*/}" | tr '[:upper:]' '[:lower:]')"; next="${toks[1]:-}"
    case "$base" in
      gh|gh-*|git|hub|glab|lab)
        echo "$rule: runs $base — forge operations are the runner's alone (ADR-0007)"; bad=1 ;;
      npx|npm|pnpm|yarn|bunx|bun|corepack|deno|pipx|uvx|uv)
        # Package runners execute whatever they are told to fetch or find,
        # and deno also runs code from a data: URL written into the grant.
        echo "$rule: $base runs programs and code it is handed"; bad=1 ;;
      env|command|builtin|exec|nohup|nice|ionice|time|stdbuf|timeout|setsid|flock|chroot|unshare|strace|ltrace|\
      xargs|eval|sudo|su|doas|pkexec|ssh|parallel|watch|find|script|expect)
        echo "$rule: $base runs other commands"; bad=1 ;;
      sh|bash|zsh|dash|ksh|fish|python|python3|perl|ruby|node)
        if [[ -z "$next" || "$next" == -* ]]; then
          echo "$rule: $base without a script path runs arbitrary code"; bad=1
        fi ;;
    esac
  done
  return "$bad"
}
