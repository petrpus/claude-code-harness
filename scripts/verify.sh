#!/usr/bin/env bash
# scripts/verify.sh — the harness's own Verify command.
#
# The harness demands an objective Verify gate from consumer projects; this is
# ours. The autopilot loop and any contributor run it before opening a PR.
# Three offline layers:
#   1. scripts/check-consistency.sh — structural invariants (skills, sync-log,
#      version==changelog, hooks.json resolves, …).
#   2. Hook test matrix — each guard hook is fed representative stdin-JSON and
#      its exit code asserted (block cases exit 2, allow cases exit 0), per the
#      stdin-JSON / exit-2 contract in docs/architecture.md § Hook contract.
#   3. bash -n over hooks/*.sh, scripts/*.sh, skills/**/*.sh — a syntax floor
#      that stands even if check-consistency's own walk regresses.
#
# On success writes tmp/.last-verify-status ("ok") in the format the freshness
# hooks read (hooks/pre-commit-gate.sh, hooks/on-stop.sh), so their staleness
# warnings stop firing after a green run. Non-zero exit on any failure. No
# network. Runnable from anywhere inside the repo.

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1

FAIL=0
note() { echo "  ✗ $*"; FAIL=1; }
ok()   { echo "  ✓ $*"; }
section() { echo; echo "== $1 =="; }

# Temp git repos for the branch-dependent push guard (one on `main`, one on a
# feature branch), addressed via each case's .cwd so the matrix is deterministic
# regardless of the branch verify.sh itself runs on. Cleaned up on exit.
TMP_MAIN_REPO=""
TMP_FEAT_REPO=""
cleanup() {
  [[ -n "$TMP_MAIN_REPO" && -d "$TMP_MAIN_REPO" ]] && rm -rf "$TMP_MAIN_REPO"
  [[ -n "$TMP_FEAT_REPO" && -d "$TMP_FEAT_REPO" ]] && rm -rf "$TMP_FEAT_REPO"
  return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
section "check-consistency"
if bash scripts/check-consistency.sh; then
  ok "check-consistency passed"
else
  note "check-consistency failed (see above)"
fi

# ---------------------------------------------------------------------------
section "hook test matrix"
# assert_hook <desc> <expected-exit> <hook-script> <stdin-json>
assert_hook() {
  local desc="$1" want="$2" hook="$3" json="$4" got
  printf '%s' "$json" | bash "$hook" >/dev/null 2>&1
  got=$?
  if [[ "$got" == "$want" ]]; then
    ok "$desc (exit $got)"
  else
    note "$desc: expected exit $want, got $got"
  fi
}

if ! command -v jq >/dev/null 2>&1; then
  echo "  (jq not available — guard hooks fail open without it; skipping matrix)"
else
  # A throwaway repo whose current branch is 'main', addressed via the hook's
  # .cwd field, so the push-from-main guard is exercised regardless of the
  # branch verify.sh itself runs on.
  TMP_MAIN_REPO="$(mktemp -d)"
  git -C "$TMP_MAIN_REPO" init -q >/dev/null 2>&1
  git -C "$TMP_MAIN_REPO" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
  MAIN_JSON_CWD="$(printf '%s' "$TMP_MAIN_REPO" | sed 's/\\/\\\\/g; s/"/\\"/g')"

  TMP_FEAT_REPO="$(mktemp -d)"
  git -C "$TMP_FEAT_REPO" init -q >/dev/null 2>&1
  git -C "$TMP_FEAT_REPO" symbolic-ref HEAD refs/heads/feat-x >/dev/null 2>&1
  FEAT_JSON_CWD="$(printf '%s' "$TMP_FEAT_REPO" | sed 's/\\/\\\\/g; s/"/\\"/g')"

  # pre-bash: blocks
  assert_hook "pre-bash blocks git push on main" 2 hooks/pre-bash.sh \
    "{\"cwd\":\"$MAIN_JSON_CWD\",\"tool_input\":{\"command\":\"git push\"}}"
  # Force-push cases run against the feature-branch repo so the block comes from
  # the force guard specifically, not the push-from-main guard (deterministic
  # regardless of the branch verify.sh itself runs on).
  assert_hook "pre-bash blocks force-push (feature branch)" 2 hooks/pre-bash.sh \
    "{\"cwd\":\"$FEAT_JSON_CWD\",\"tool_input\":{\"command\":\"git push --force\"}}"
  assert_hook "pre-bash segment-split catches cd && git push --force" 2 hooks/pre-bash.sh \
    "{\"cwd\":\"$FEAT_JSON_CWD\",\"tool_input\":{\"command\":\"cd sub && git push --force\"}}"
  assert_hook "pre-bash blocks broad rm -rf /" 2 hooks/pre-bash.sh \
    '{"tool_input":{"command":"rm -rf /"}}'
  assert_hook "pre-bash blocks broad rm -rf ~" 2 hooks/pre-bash.sh \
    '{"tool_input":{"command":"rm -rf ~"}}'
  # pre-bash: allows
  assert_hook "pre-bash allows plain ls" 0 hooks/pre-bash.sh \
    '{"tool_input":{"command":"ls -la"}}'
  assert_hook "pre-bash allows plain git push on a feature branch" 0 hooks/pre-bash.sh \
    "{\"cwd\":\"$FEAT_JSON_CWD\",\"tool_input\":{\"command\":\"git push\"}}"
  assert_hook "pre-bash allows --force-with-lease on a feature branch" 0 hooks/pre-bash.sh \
    "{\"cwd\":\"$FEAT_JSON_CWD\",\"tool_input\":{\"command\":\"git push --force-with-lease\"}}"

  # pre-edit: blocks
  assert_hook "pre-edit blocks .env" 2 hooks/pre-edit.sh \
    '{"tool_input":{"file_path":"/repo/.env"}}'
  assert_hook "pre-edit blocks package-lock.json" 2 hooks/pre-edit.sh \
    '{"tool_input":{"file_path":"/repo/package-lock.json"}}'
  assert_hook "pre-edit blocks pnpm-lock.yaml" 2 hooks/pre-edit.sh \
    '{"tool_input":{"file_path":"/repo/pnpm-lock.yaml"}}'
  # pre-edit: allows
  assert_hook "pre-edit allows .env.example" 0 hooks/pre-edit.sh \
    '{"tool_input":{"file_path":"/repo/.env.example"}}'
  assert_hook "pre-edit allows a normal source file" 0 hooks/pre-edit.sh \
    '{"tool_input":{"file_path":"/repo/src/index.ts"}}'
fi

# ---------------------------------------------------------------------------
section "shell syntax (bash -n)"
while IFS= read -r f; do
  if err="$(bash -n "$f" 2>&1)"; then
    ok "$f"
  else
    note "$f has a syntax error: $err"
  fi
done < <(find hooks scripts skills templates -name '*.sh' -type f 2>/dev/null | sort)

# ---------------------------------------------------------------------------
# Record status for the freshness hooks (single status word; "ok" == green).
mkdir -p tmp
echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "ok" > tmp/.last-verify-status
  echo "verify: PASS"
else
  echo "fail" > tmp/.last-verify-status
  echo "verify: FAIL"
fi
exit "$FAIL"
