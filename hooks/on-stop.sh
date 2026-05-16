#!/usr/bin/env bash
# Stop hook — runs when the agent finishes a turn.
#
# - Warns if the working tree is dirty and no commit happened
# - Warns if the project verify hasn't been run in a while

set -eo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

DIRTY="$(git status --porcelain 2>/dev/null)"
LAST_VERIFY_AGE_SEC=0

if [[ -f tmp/.last-verify-status ]]; then
  LAST_VERIFY_AGE_SEC=$(( $(date +%s) - $(stat -c %Y tmp/.last-verify-status) ))
fi

WARNINGS=()

if [[ -n "$DIRTY" ]]; then
  WARNINGS+=("Working tree has uncommitted changes. Commit or stash before next session.")
fi

if [[ "$LAST_VERIFY_AGE_SEC" -gt 600 ]]; then
  WARNINGS+=("Verify hasn't been run in $((LAST_VERIFY_AGE_SEC / 60)) minutes. Run before pushing.")
fi

if [[ "${#WARNINGS[@]}" -gt 0 ]]; then
  echo "Session stop reminders:"
  for w in "${WARNINGS[@]}"; do
    echo "  - $w"
  done
fi
