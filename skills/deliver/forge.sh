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

# forge_push_branch <branch>  — first push of a branch the runner created.
# Never forced: a rejected push means someone else wrote the branch, and
# that is a reason to stop, not to overwrite.
forge_push_branch() { git push -q -u origin "$1"; }

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
forge_pr_merge() {
  gh pr merge "$1" --squash --match-head-commit "$2" --subject "$3" --body-file "$4"
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

# forge_pr_state <pr>  — OPEN | MERGED | CLOSED
forge_pr_state() {
  gh pr view "$1" --json state | jq -r '.state'
}

# forge_grant_violations <allowed_tools_csv>
#   Pure: which Claude Code permission rules in the list would hand a model
#   phase a forge operation (ADR-0007) or a way to run arbitrary commands
#   that reach one. Echoes one "<rule>: <why>" per offending rule and returns
#   1 if there is any. Rules are split on commas outside parentheses; for each
#   `Bash(...)` rule the command text is read the way a shell would run it:
#   leading VAR=value assignments and pass-through wrappers (env, command,
#   exec, nohup, nice, time, stdbuf, timeout <n>) are skipped, and the
#   program is judged by its basename — so `Bash(env gh:*)` and
#   `Bash(/usr/bin/git push:*)` are the same grant as `Bash(gh:*)` and
#   `Bash(git push:*)`.
#
#   This is defence in depth, not the boundary: BUILD edits files and may run
#   the verify command and scripts it can edit, so an allowlist alone can
#   never stop a model phase from reaching gh. Withholding forge credentials
#   from model phases is that boundary (#77, map #68).
forge_grant_violations() {
  local csv="$1" rule inner cmd tok base next bad=0 depth=0 cur="" ch i
  local -a rules=() toks=()
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
    rule="$(printf '%s' "$rule" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ -n "$rule" ]] || continue
    if [[ "$rule" == "Bash" ]]; then echo "$rule: a blanket shell grant"; bad=1; continue; fi
    [[ "$rule" == Bash\(*\) ]] || continue
    inner="${rule#Bash(}"; inner="${inner%)}"
    # Prefix (`cmd:*`) and trailing-wildcard (`cmd *`) forms name the same program.
    cmd="$(printf '%s' "$inner" | sed -E 's/:\*$//; s/[[:space:]]\*$//')"
    if [[ "$cmd" == *"*"* ]]; then echo "$rule: a wildcard inside the command"; bad=1; continue; fi
    read -ra toks <<<"$cmd"
    i=0
    while (( i < ${#toks[@]} )); do
      tok="${toks[$i]}"
      if [[ "$tok" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then i=$((i+1)); continue; fi
      case "${tok##*/}" in
        env|command|builtin|exec|nohup|nice|time|stdbuf) i=$((i+1)); continue ;;
        timeout) i=$((i+2)); continue ;;
      esac
      break
    done
    if (( i >= ${#toks[@]} )); then echo "$rule: no program named — as broad as Bash"; bad=1; continue; fi
    base="${toks[$i]##*/}"; next="${toks[$((i+1))]:-}"
    case "$base" in
      gh|git|hub)
        echo "$rule: runs $base — forge operations are the runner's alone (ADR-0007)"; bad=1 ;;
      xargs|eval|sudo|su|doas|ssh|parallel|watch|find|script)
        echo "$rule: $base runs other commands"; bad=1 ;;
      sh|bash|zsh|dash|ksh|fish|python|python3|perl|ruby|node|deno)
        if [[ -z "$next" || "$next" == -* ]]; then
          echo "$rule: $base without a script path runs arbitrary code"; bad=1
        fi ;;
    esac
  done
  return "$bad"
}

