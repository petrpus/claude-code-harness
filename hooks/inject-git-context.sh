#!/usr/bin/env bash
# UserPromptSubmit hook — injects current git context + verify status
# into agent context at start of each turn.
#
# Reads project verify status from tmp/.last-verify-status (convention).
# Projects that don't follow that convention will just see "never".

set -eo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

BRANCH="$(git branch --show-current 2>/dev/null || echo 'detached')"
DIRTY="$(git status --porcelain 2>/dev/null | head -10)"
LAST_VERIFY="$(cat tmp/.last-verify-status 2>/dev/null || echo 'never')"

echo "<system-reminder>"
echo "Git context (auto-injected):"
echo "- Branch: $BRANCH"

if [[ -n "$DIRTY" ]]; then
  echo "- Working tree: dirty"
  echo "$DIRTY" | sed 's/^/  /'
else
  echo "- Working tree: clean"
fi

echo "- Last verify: $LAST_VERIFY"
echo "</system-reminder>"
