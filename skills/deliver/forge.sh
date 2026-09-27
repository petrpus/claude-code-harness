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

# forge_pr_state <pr>  — OPEN | MERGED | CLOSED
forge_pr_state() {
  gh pr view "$1" --json state | jq -r '.state'
}
