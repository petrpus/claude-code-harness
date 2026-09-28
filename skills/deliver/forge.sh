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
#   This is defence in depth, not the boundary: BUILD edits files and may run
#   the verify command and scripts it can edit, so an allowlist alone can
#   never stop a model phase from reaching gh. Withholding forge credentials
#   from model phases is that boundary (#77, map #68).
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
    base="${toks[0]##*/}"; next="${toks[1]:-}"
    case "$base" in
      gh|git|hub)
        echo "$rule: runs $base — forge operations are the runner's alone (ADR-0007)"; bad=1 ;;
      env|command|builtin|exec|nohup|nice|ionice|time|stdbuf|timeout|setsid|flock|chroot|unshare|strace|ltrace|\
      xargs|eval|sudo|su|doas|pkexec|ssh|parallel|watch|find|script|expect)
        echo "$rule: $base runs other commands"; bad=1 ;;
      sh|bash|zsh|dash|ksh|fish|python|python3|perl|ruby|node|deno)
        if [[ -z "$next" || "$next" == -* ]]; then
          echo "$rule: $base without a script path runs arbitrary code"; bad=1
        fi ;;
    esac
  done
  return "$bad"
}
