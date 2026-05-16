#!/usr/bin/env bash
# PreToolUse hook for `git commit` — checks verify freshness.
#
# Warns (does not block) if the project verify was last run more than 30
# minutes ago, or was red. Some commits (docs-only, WIP before context
# switch) legitimately don't need a fresh verify. The hook just makes
# the staleness visible.

set -eo pipefail

CMD="${CLAUDE_TOOL_BASH_COMMAND:-}"

# Only act on `git commit` (not commit --amend, which is handled elsewhere)
if [[ ! "$CMD" =~ ^git\ commit($|\ ) ]]; then
  exit 0
fi

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

STATUS_FILE="tmp/.last-verify-status"

if [[ ! -f "$STATUS_FILE" ]]; then
  echo "No verify recorded yet for this repo. Consider running before commit." >&2
  exit 0
fi

AGE_SEC=$(( $(date +%s) - $(stat -c %Y "$STATUS_FILE" 2>/dev/null || stat -f %m "$STATUS_FILE" 2>/dev/null || echo 0) ))
STATUS=$(cat "$STATUS_FILE" 2>/dev/null || echo "unknown")

if [[ "$AGE_SEC" -gt 1800 ]]; then  # 30 min
  AGE_MIN=$((AGE_SEC / 60))
  echo "Last verify was ${AGE_MIN} min ago. Consider re-running before commit." >&2
fi

if [[ "$STATUS" != "ok" ]] && [[ "$STATUS" != "unknown" ]]; then
  echo "Last verify status: $STATUS (not 'ok'). Make sure verify is green before push." >&2
fi

exit 0
