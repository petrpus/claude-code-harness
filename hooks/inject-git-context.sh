#!/usr/bin/env bash
# UserPromptSubmit hook — injects current git context + verify status
# into agent context at start of each turn.
#
# Reads project verify status from tmp/.last-verify-status (convention).
# Projects that don't follow that convention will just see "never".

# Best-effort injection: never hard-fail a turn. No `set -e` (a non-zero exit on
# UserPromptSubmit can disrupt the turn), and capture full status before trimming
# to avoid SIGPIPE from `git status | head` under pipefail.
set -uo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 0

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
