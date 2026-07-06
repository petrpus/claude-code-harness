#!/usr/bin/env bash
# Stop hook — appends a structured JSONL entry to tmp/session-log.jsonl on
# each turn end. Raw capture only; `/worklog` collapses these into a human
# digest. Always exits 0. No-op outside a git repo or without a writable tmp/.
#
# Stop fires per turn, so entries are per-turn — expect several per session.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib.sh"

read_stdin_json
cd_repo_root

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
mkdir -p tmp 2>/dev/null || exit 0
[[ -w tmp ]] || exit 0

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
BRANCH="$(git branch --show-current 2>/dev/null || echo detached)"
DIRTY_N="$(git status --porcelain 2>/dev/null | grep -c . || echo 0)"
LAST_COMMIT="$(git log -1 --pretty=%s 2>/dev/null || echo '')"
CWD="$(pwd)"
SID="$(hook_session_id)"

if have_jq; then
  jq -cn \
    --arg ts "$TS" --arg sid "$SID" --arg cwd "$CWD" --arg branch "$BRANCH" \
    --argjson dirty "${DIRTY_N:-0}" --arg last "$LAST_COMMIT" \
    '{ts:$ts, session_id:$sid, cwd:$cwd, branch:$branch, dirty_files:$dirty, last_commit:$last, event:"stop"}' \
    >> tmp/session-log.jsonl 2>/dev/null || true
else
  # No jq — write a minimal, safely-escaped line (fields with no user quotes).
  printf '{"ts":"%s","branch":"%s","dirty_files":%s,"event":"stop"}\n' \
    "$TS" "$BRANCH" "${DIRTY_N:-0}" >> tmp/session-log.jsonl 2>/dev/null || true
fi

exit 0
