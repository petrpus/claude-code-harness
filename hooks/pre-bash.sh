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
BRANCH="$(git branch --show-current 2>/dev/null || echo '')"

# Split the command string into segments on shell operators so a guard sees
# each simple command on its own. Newlines/&&/||/|/;/& all separate.
# (Pragmatic: does not parse quoting — see header note.)
split_segments() {
  # Trailing newline guaranteed so `read` in the while loop consumes the
  # final segment even when the command has no trailing separator.
  printf '%s\n' "$1" | tr '\n' ';' | sed -E 's/(\|\||&&|\||;|&)/\n/g'
}

# Return 0 if a segment is a `git ... push` invocation (allowing -C dir and
# leading env assignments / env prefix).
seg_is_git_push() {
  # Normalise whitespace to single spaces, add sentinels.
  local seg=" $(printf '%s' "$1" | tr -s ' \t' '  ') "
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
  local seg=" $(printf '%s' "$1" | tr -s ' \t' '  ') "
  [[ "$seg" == *" --force "* || "$seg" == *" -f "* ]]
}

# Return 0 if a segment is a dangerous broad `rm -rf` against a root-ish target.
seg_is_dangerous_rm() {
  local seg=" $(printf '%s' "$1" | tr -s ' \t' '  ') "
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
    if [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]]; then
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
