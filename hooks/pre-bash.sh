#!/usr/bin/env bash
# PreToolUse hook for Bash — conditional guards beyond settings.json deny.
#
# Static pattern deny (force-push literals, rm -rf /) lives in settings.json.
# This hook adds CONTEXT-dependent logic that a static pattern can't express
# — chiefly "push from main" (needs the current branch).
#
# This is defense-in-depth against model mistakes, NOT a sandbox: shell
# quoting can always defeat regex segmentation. The hard layer is
# settings.json deny + the permission system. We just raise the bar and
# catch the common compound-command evasions (`cd x && git push`,
# `git -C . push`, `env FOO=1 git push`).
#
# Contract: reads tool_input.command from the JSON on stdin.
#   exit 0 = allow · exit 2 = BLOCK (stderr shown to Claude).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib.sh"

read_stdin_json
CMD="$(hook_tool_command)"
[[ -z "$CMD" ]] && exit 0

cd_repo_root

# Ask git a question with a known answer before trusting its answer to the one
# that matters. A git that errors returns an empty branch; a git that prints
# nonsense returns a branch name that merely *looks* valid, and "not main" is
# indistinguishable from "safe" — which is how a broken git silently disables
# the only guard that knows about branches.
GIT_OK=0
[[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" == "true" ]] && GIT_OK=1
BRANCH="$(git branch --show-current 2>/dev/null || echo '')"

# Split the command string into segments on shell operators so a guard sees
# each simple command on its own. Newlines/&&/||/|/;/& all separate.
# (Pragmatic: does not parse quoting — see header note.)
#
# Done with bash string operations rather than `tr | sed`: a guard that shells
# out to split its input has that tool as a silent single point of failure. A
# broken `sed` produced no segments, nothing matched, and the hook allowed
# `rm -rf /` at exit 0 with no warning — a guard failing open is a choice, one
# failing open because a coreutil misbehaved is not.
split_segments() {
  local s="$1"
  s="${s//$'\n'/;}"
  s="${s//&&/$'\n'}"
  s="${s//||/$'\n'}"
  s="${s//|/$'\n'}"
  s="${s//;/$'\n'}"
  s="${s//&/$'\n'}"
  # Trailing newline guaranteed so `read` in the while loop consumes the
  # final segment even when the command has no trailing separator.
  printf '%s\n' "$s"
}

# Collapse tabs and runs of spaces, and wrap in sentinels so callers can match
# whole words with a single glob. Pure bash, for the reason above.
seg_words() {
  local s="${1//$'\t'/ }"
  while [[ "$s" == *"  "* ]]; do s="${s//  / }"; done
  printf ' %s ' "$s"
}

# Return 0 if a segment is a `git ... push` invocation (allowing -C dir and
# leading env assignments / env prefix).
seg_is_git_push() {
  # Normalise whitespace to single spaces, add sentinels.
  local seg; seg="$(seg_words "$1")"
  # Must contain a `git` word and a `push` word after it.
  [[ "$seg" == *" git "* ]] || return 1
  # Strip everything up to the first ` git `; the rest are git args.
  local after="${seg#* git }"
  # `push` must appear as a whitespace-delimited word in the git args.
  [[ " $after " == *" push "* ]]
}

# Return 0 if a segment carries a force-push flag (--force or standalone -f).
# --force-with-lease is handled by the caller as the sanctioned escape hatch.
seg_has_force() {
  local seg; seg="$(seg_words "$1")"
  [[ "$seg" == *" --force "* || "$seg" == *" -f "* ]]
}

# Return 0 if a segment is a dangerous broad `rm -rf` against a root-ish target.
seg_is_dangerous_rm() {
  local seg; seg="$(seg_words "$1")"
  [[ "$seg" == *" rm "* ]] || return 1
  # Needs a recursive+force flag (any order/combination).
  [[ "$seg" == *" -rf "* || "$seg" == *" -fr "* || \
     "$seg" == *" -r "*" -f "* || "$seg" == *" -f "*" -r "* || \
     "$seg" == *" -Rf "* || "$seg" == *" --recursive "* ]] || return 1
  # Root-ish target anywhere in the segment.
  local repo_root; repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"
  case "$seg" in
    *" / "*|*" /* "*|*" ~ "*|*" ~/ "*|*' $HOME '*|*" . "*|*" ./ "*|*" .. "*|*" ../ "*) return 0 ;;
  esac
  [[ -n "$repo_root" && "$seg" == *" $repo_root "* ]] && return 0
  return 1
}

while IFS= read -r seg; do
  [[ -z "${seg// }" ]] && continue

  if seg_is_git_push "$seg"; then
    # The push-from-main rule is the one guard settings.json deny cannot
    # express, because it needs the current branch. If git couldn't tell us,
    # this guard is not guarding — say so rather than waving the push through
    # as though the branch had been checked and found safe.
    if [[ "$GIT_OK" -ne 1 || -z "$BRANCH" ]]; then
      echo "claude-code-harness: could not determine the current branch (git unavailable, not a repo, or detached HEAD) — the push-from-main guard did NOT run for this command." >&2
    elif [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]]; then
      echo "Push from \`$BRANCH\` blocked. Use a feature branch." >&2
      echo "  git checkout -b feat/<area>-<short-desc>" >&2
      exit 2
    fi
    if seg_has_force "$seg" && [[ "$seg" != *"--force-with-lease"* ]]; then
      echo "Force push blocked. Use --force-with-lease only if explicitly justified." >&2
      exit 2
    fi
  fi

  if seg_is_dangerous_rm "$seg"; then
    echo "Refusing broad 'rm -rf' against root / home / repo root. Target a specific subdirectory." >&2
    exit 2
  fi

  # Advisory only — never blocks.
  if [[ " $seg " == *" npm install -g "* || " $seg " == *" npm i -g "* ]]; then
    echo "Global npm install detected. Prefer a project-local dependency." >&2
  fi
done < <(split_segments "$CMD")

exit 0
