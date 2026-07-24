#!/usr/bin/env bash
# templates/require-verify-before-stop.sh — OPT-IN Stop-hook verify gate.
#
# The harness's default Stop hooks only *remind* about a stale or failing verify;
# they always exit 0 (see docs/architecture.md § Hook contract). This template is
# the opt-in HARD gate for UNATTENDED runs: it blocks the turn from ending
# (exit 2) while tmp/.last-verify-status is missing, stale, or not "ok", forcing
# the agent to run verify before it stops.
#
# It deliberately breaks the "Stop hooks always exit 0" rule — that is the whole
# point, and it is safe only because it is opt-in (ADR-0002):
#   - NEVER wired into hooks/hooks.json; the harness never turns it on by default.
#   - A project (or autopilot, for the duration of a run) opts in by registering
#     it as a Stop hook in its own .claude/settings.json.
#   - Claude Code lifts the block after 8 consecutive refusals, so it cannot
#     deadlock a session.
#
# Contract: reads the hook JSON on stdin (same jq pattern as hooks/lib.sh — this
# is a standalone template, so the helper is inlined, not sourced). Fails OPEN
# (exit 0) without jq. exit 0 = allow stop · exit 2 = block stop (stderr shown
# to Claude).
#
# Tunable: VERIFY_MAX_AGE_SEC (default 1800) — how old tmp/.last-verify-status
# may be before it counts as stale.

set -u

VERIFY_MAX_AGE_SEC="${VERIFY_MAX_AGE_SEC:-1800}"
STATUS_FILE="tmp/.last-verify-status"

# --- stdin JSON (mirrors hooks/lib.sh; fail open without jq) ----------------
IFS= read -r -d '' HOOK_INPUT 2>/dev/null || true
json_field() {
  [[ -z "${HOOK_INPUT:-}" ]] && { echo ""; return 0; }
  command -v jq >/dev/null 2>&1 || { echo ""; return 0; }
  printf '%s' "$HOOK_INPUT" | jq -r "$1 // empty" 2>/dev/null || echo ""
}

# cd to the repo root, honouring the hook's cwd (like hooks/lib.sh cd_repo_root).
CWD="$(json_field '.cwd')"
[[ -n "$CWD" && -d "$CWD" ]] && cd "$CWD" 2>/dev/null || true
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" 2>/dev/null || true

mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

if [[ ! -f "$STATUS_FILE" ]]; then
  echo "Verify gate: no verify recorded ($STATUS_FILE missing). Run verify before stopping." >&2
  exit 2
fi

NOW="$(date +%s 2>/dev/null || echo 0)"
AGE=$(( NOW - $(mtime_of "$STATUS_FILE") ))
STATUS="$(cat "$STATUS_FILE" 2>/dev/null || echo 'unknown')"

if [[ "$STATUS" != "ok" ]]; then
  echo "Verify gate: last verify status is '$STATUS' (not ok). Fix and re-run verify before stopping." >&2
  exit 2
fi
if [[ "$AGE" -gt "$VERIFY_MAX_AGE_SEC" ]]; then
  echo "Verify gate: last verify was $((AGE / 60)) min ago (> $((VERIFY_MAX_AGE_SEC / 60)) min). Re-run verify before stopping." >&2
  exit 2
fi

exit 0
