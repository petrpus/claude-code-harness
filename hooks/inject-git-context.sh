#!/usr/bin/env bash
# UserPromptSubmit hook — injects current git context + verify status into
# agent context at the start of each turn.
#
# stdout from UserPromptSubmit IS fed to the model as context. Reads verify
# status from tmp/.last-verify-status (harness convention); projects that
# don't follow it just see "never".
#
# Best-effort: never hard-fail a turn. No `set -e`; guard the `git status |
# head` pipe against SIGPIPE by capturing full status before trimming.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib.sh"

read_stdin_json
cd_repo_root

BRANCH="$(git branch --show-current 2>/dev/null || echo 'detached')"
DIRTY="$(git status --porcelain 2>/dev/null || true)"
LAST_VERIFY="$(cat tmp/.last-verify-status 2>/dev/null || echo 'never')"

echo "<git-context>"
echo "Git context (auto-injected):"
echo "- Branch: $BRANCH"

if [[ -n "$DIRTY" ]]; then
  echo "- Working tree: dirty"
  printf '%s\n' "$DIRTY" | head -10 | sed 's/^/  /'
else
  echo "- Working tree: clean"
fi

echo "- Last verify: $LAST_VERIFY"
echo "</git-context>"

exit 0
