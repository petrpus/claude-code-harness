#!/usr/bin/env bash
# scripts/verify.sh — installed by `/project-infra verify`.
#
# Runs the project's real verify chain, then records the outcome to
# tmp/.last-verify-status ("ok" or "fail") — the convention read by the
# claude-code-harness hooks (inject-git-context.sh, on-stop.sh,
# pre-commit-gate.sh) to decide how stale/fresh the last verify run is.
#
# No `set -e`: we need to capture the underlying command's exit code
# ourselves and still write the status file on failure, not abort first.
set -uo pipefail

# --- Adapt this section to your project -----------------------------------
# Default: run the `verify:inner` npm script (the actual typecheck+lint+test
# chain that `/project-infra verify` wrote into package.json). Override by
# exporting VERIFY_CMD before calling this script, e.g.:
#   VERIFY_CMD="pnpm run verify:inner" bash scripts/verify.sh
VERIFY_CMD="${VERIFY_CMD:-}"
if [[ -z "$VERIFY_CMD" ]]; then
  if [[ -f pnpm-lock.yaml ]]; then
    VERIFY_CMD="pnpm run verify:inner"
  else
    VERIFY_CMD="npm run verify:inner"
  fi
fi
# ---------------------------------------------------------------------------

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
mkdir -p "$REPO_ROOT/tmp"

echo "+ $VERIFY_CMD"
# shellcheck disable=SC2086
eval $VERIFY_CMD
STATUS=$?

if [[ $STATUS -eq 0 ]]; then
  echo "ok" > "$REPO_ROOT/tmp/.last-verify-status"
else
  echo "fail" > "$REPO_ROOT/tmp/.last-verify-status"
fi

exit $STATUS
