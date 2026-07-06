#!/usr/bin/env bash
# Stop hook — runs when the agent finishes a turn.
#
# Warns (user-facing only) on a dirty tree or a stale verify. Per the repo's
# hook rules this ALWAYS exits 0 and never uses `set -e`. Note: Stop-hook
# stdout is transcript-visible to the user, NOT fed back to the model.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib.sh"

read_stdin_json
cd_repo_root

# No git repo → nothing to say.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

DIRTY="$(git status --porcelain 2>/dev/null || true)"
LAST_VERIFY_AGE_SEC=0
if [[ -f tmp/.last-verify-status ]]; then
  NOW="$(date +%s 2>/dev/null || echo 0)"
  LAST_VERIFY_AGE_SEC=$(( NOW - $(mtime_of tmp/.last-verify-status) ))
fi

WARNINGS=()
[[ -n "$DIRTY" ]] && WARNINGS+=("Working tree has uncommitted changes. Commit or stash before next session.")
[[ "$LAST_VERIFY_AGE_SEC" -gt 600 ]] && WARNINGS+=("Verify last ran $((LAST_VERIFY_AGE_SEC / 60)) min ago. Run before pushing.")

if [[ "${#WARNINGS[@]}" -gt 0 ]]; then
  echo "Session stop reminders:"
  for w in "${WARNINGS[@]}"; do echo "  - $w"; done
fi

exit 0
