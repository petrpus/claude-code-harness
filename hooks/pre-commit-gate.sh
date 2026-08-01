#!/usr/bin/env bash
# PreToolUse hook for `git commit` — warns (never blocks) on stale/red verify.
#
# Some commits (docs-only, WIP before a context switch) legitimately don't
# need a fresh verify. This hook just makes staleness visible.
#
# Contract: reads tool_input.command from stdin. Always exits 0 (warn-only,
# stderr).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib.sh"

read_stdin_json
CMD="$(hook_tool_command)"

# Only act on `git commit` (word-boundary, allowing a leading `cd x && `).
case " $CMD " in
  *" git commit "*|*" git commit"|"git commit "*|"git commit") : ;;
  *) exit 0 ;;
esac

cd_repo_root
STATUS_FILE="tmp/.last-verify-status"

if [[ ! -f "$STATUS_FILE" ]]; then
  echo "No verify recorded yet for this repo. Consider running before commit." >&2
  exit 0
fi

NOW="$(now_epoch)"
MTIME="$(mtime_of "$STATUS_FILE")"
AGE_SEC=$(( NOW - MTIME ))
STATUS="$(cat "$STATUS_FILE" 2>/dev/null || echo 'unknown')"

# Either clock unknown → the age is meaningless; say nothing about staleness
# rather than reporting a nonsense number.
if [[ "$NOW" -gt 0 && "$MTIME" -gt 0 && "$AGE_SEC" -gt 1800 ]]; then
  echo "Last verify was $((AGE_SEC / 60)) min ago. Consider re-running before commit." >&2
fi

if [[ "$STATUS" != "ok" && "$STATUS" != "unknown" ]]; then
  echo "Last verify status: $STATUS (not 'ok'). Make sure verify is green before push." >&2
fi

exit 0
