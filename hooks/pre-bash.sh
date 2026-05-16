#!/usr/bin/env bash
# PreToolUse hook for Bash — conditional gates beyond settings.json deny.
#
# Pattern-based deny lives in settings.json. This hook adds LOGIC-based
# blocks (e.g. "push from main" — depends on current branch).
#
# Exit codes:
#   0 = allow
#   1 = block with reason in stderr

set -eo pipefail

CMD="${CLAUDE_TOOL_BASH_COMMAND:-}"

if [[ -z "$CMD" ]]; then
  exit 0
fi

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

BRANCH="$(git branch --show-current 2>/dev/null || echo '')"

# Block push from main / master
if [[ "$CMD" =~ ^git\ push ]] && [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]]; then
  echo "Push from \`$BRANCH\` blocked. Use a feature branch." >&2
  echo "  Create one: git checkout -b feat/<area>-<short-desc>" >&2
  exit 1
fi

# Block git push --force / -f even if user types it differently
if [[ "$CMD" =~ ^git\ push.*(--force|-f($|\ )) ]]; then
  echo "Force push blocked. Use --force-with-lease only if explicitly justified." >&2
  exit 1
fi

# Block broad rm in HOME / repo root
if [[ "$CMD" =~ ^rm\ -rf\ \./?$ ]] || [[ "$CMD" =~ ^rm\ -rf\ ~/?$ ]]; then
  echo "Refusing rm -rf of root / home. If you mean a subdirectory, be explicit." >&2
  exit 1
fi

# Warn on global npm install
if [[ "$CMD" =~ ^npm\ install\ -g ]] || [[ "$CMD" =~ ^npm\ i\ -g ]]; then
  echo "Global npm install detected. Prefer project-local dep. Continuing." >&2
fi

exit 0
