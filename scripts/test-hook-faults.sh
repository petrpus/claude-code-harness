#!/usr/bin/env bash
# scripts/test-hook-faults.sh — fault injection for the hooks.
#
# Companion to scripts/test-fault-injection.sh, which sweeps the same class for
# the repo-map generator. The invariant there — "exit non-zero or produce a
# correct result" — would be wrong here: hooks are specified to fail OPEN
# without jq, and UserPromptSubmit/Stop hooks must always exit 0 or they
# disrupt the turn. So the property is inverted, and split in two.
#
#   Guard hooks (PreToolUse), on input they are supposed to block:
#     must EITHER still block (exit 2) OR say on stderr that guarding is
#     degraded. Never a silent exit 0 — a guard that quietly stops guarding
#     looks exactly like a guard that found nothing wrong.
#
#   Advisory hooks (UserPromptSubmit / Stop):
#     must exit 0 under every fault, must not hang, and must not emit reserved
#     harness tags on stdout (which is injected into the model's context).
#
# The worry is concrete: fail-open means a broken jq leaves the push-from-main,
# .env and rm -rf guards installed, listed in hooks.json, exiting 0, and not
# guarding anything — and the one place that matters most is an unattended
# autopilot run, whose safety note says the plugin hooks stay active.
#
# Invoked from scripts/verify.sh. Cleaned up on exit.

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1

FAIL=0
note() { echo "  ✗ $*"; FAIL=1; }
ok()   { echo "  ✓ $*"; }

WORK="$(mktemp -d)"
SHIM="$WORK/shim"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$SHIM"

# A repo on main, so the branch-dependent push guard is exercised regardless of
# the branch this script runs on.
MAIN_REPO="$WORK/mainrepo"
mkdir -p "$MAIN_REPO"
git -C "$MAIN_REPO" init -q >/dev/null 2>&1
git -C "$MAIN_REPO" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
MAIN_CWD="$(printf '%s' "$MAIN_REPO" | sed 's/\\/\\\\/g; s/"/\\"/g')"

# A repo with a stale verify status, which is what the advisory freshness hooks
# have opinions about.
ADV_REPO="$WORK/advrepo"
mkdir -p "$ADV_REPO/tmp"
git -C "$ADV_REPO" init -q >/dev/null 2>&1
printf 'x\n' > "$ADV_REPO/file.txt"
printf 'ok\n' > "$ADV_REPO/tmp/.last-verify-status"
ADV_CWD="$(printf '%s' "$ADV_REPO" | sed 's/\\/\\\\/g; s/"/\\"/g')"

make_shim() { # tool mode
  rm -f "$SHIM"/*
  case "$2" in
    fail)   printf '#!/bin/sh\nexit 3\n' > "$SHIM/$1" ;;
    silent) printf '#!/bin/sh\nexit 0\n' > "$SHIM/$1" ;;
    junk)   printf '#!/bin/sh\necho "@@junk@@"\nexit 0\n' > "$SHIM/$1" ;;
  esac
  chmod +x "$SHIM/$1"
}

TOOLS="jq git stat date grep sed cat tr"
MODES="fail silent junk"

# --- guard hooks ----------------------------------------------------------
# Each case is "hook|description|stdin-json" and must be BLOCKED normally.
GUARD_CASES=(
  "hooks/pre-bash.sh|git push on main|{\"cwd\":\"$MAIN_CWD\",\"tool_input\":{\"command\":\"git push\"}}"
  "hooks/pre-bash.sh|force-push|{\"cwd\":\"$MAIN_CWD\",\"tool_input\":{\"command\":\"git push --force\"}}"
  "hooks/pre-bash.sh|rm -rf /|{\"tool_input\":{\"command\":\"rm -rf /\"}}"
  "hooks/pre-edit.sh|write to .env|{\"tool_input\":{\"file_path\":\"/repo/.env\"}}"
)

# Sanity: without any fault these must actually block, or the sweep below
# proves nothing.
for case_spec in "${GUARD_CASES[@]}"; do
  IFS='|' read -r hook desc json <<< "$case_spec"
  printf '%s' "$json" | bash "$hook" >/dev/null 2>&1
  [[ "$?" -eq 2 ]] \
    && ok "baseline: $(basename "$hook") blocks $desc" \
    || note "baseline: $(basename "$hook") did NOT block $desc — the sweep would prove nothing"
done

for tool in $TOOLS; do
  for mode in $MODES; do
    make_shim "$tool" "$mode"
    for case_spec in "${GUARD_CASES[@]}"; do
      IFS='|' read -r hook desc json <<< "$case_spec"
      err="$(printf '%s' "$json" | PATH="$SHIM:$PATH" bash "$hook" 2>&1 >/dev/null)"
      rc=$?
      if [[ "$rc" -eq 2 ]]; then
        continue                       # still blocking: nothing to report
      fi
      if [[ -n "$err" ]]; then
        continue                       # failed open, but said so
      fi
      note "$tool/$mode: $(basename "$hook") silently allowed '$desc' (exit $rc, no warning)"
    done
  done
done
GUARD_FAILED="$FAIL"
[[ "$GUARD_FAILED" -eq 0 ]] && ok "guard hooks: no silent allow across $(echo $TOOLS | wc -w)x$(echo $MODES | wc -w) faults"

# --- advisory hooks -------------------------------------------------------
ADVISORY=(
  "hooks/inject-git-context.sh|{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$ADV_CWD\",\"prompt\":\"hi\"}"
  "hooks/on-stop.sh|{\"hook_event_name\":\"Stop\",\"cwd\":\"$ADV_CWD\"}"
  "hooks/session-log.sh|{\"hook_event_name\":\"Stop\",\"cwd\":\"$ADV_CWD\",\"session_id\":\"s1\"}"
  "hooks/pre-commit-gate.sh|{\"cwd\":\"$ADV_CWD\",\"tool_input\":{\"command\":\"git commit -m x\"}}"
)

ADV_NOTES=0
adv_note() { note "$*"; ADV_NOTES=1; }
for tool in $TOOLS; do
  for mode in $MODES; do
    make_shim "$tool" "$mode"
    for case_spec in "${ADVISORY[@]}"; do
      IFS='|' read -r hook json <<< "$case_spec"
      out="$(printf '%s' "$json" | PATH="$SHIM:$PATH" timeout 10 bash "$hook" 2>/dev/null)"
      rc=$?
      if [[ "$rc" -eq 124 ]]; then
        adv_note "$tool/$mode: $(basename "$hook") hung (timed out)"
        continue
      fi
      if [[ "$rc" -ne 0 ]]; then
        adv_note "$tool/$mode: $(basename "$hook") exited $rc — an advisory hook must always exit 0"
        continue
      fi
      case "$out" in
        *"<system-reminder>"*)
          adv_note "$tool/$mode: $(basename "$hook") emitted a reserved harness tag on stdout" ;;
      esac
    done
  done
done
[[ "$ADV_NOTES" -eq 0 ]] \
  && ok "advisory hooks: always exit 0, no hangs, no reserved tags across every fault"

# --- the announcement itself ---------------------------------------------
# The whole point of the guard tier: a degraded guard has to be visible.
rm -f "$SHIM"/*
make_shim jq fail
DEGRADED_ERR="$(printf '{"cwd":"%s","tool_input":{"command":"git push"}}' "$MAIN_REPO" \
  | PATH="$SHIM:$PATH" bash hooks/pre-bash.sh 2>&1 >/dev/null)"
case "$DEGRADED_ERR" in
  *"ALLOWING"*) ok "a broken jq is announced as an allowed-through tool call" ;;
  *)            note "a broken jq produced no warning: '$DEGRADED_ERR'" ;;
esac
case "$DEGRADED_ERR" in
  *jq*) ok "the warning names jq, so the fix is obvious" ;;
  *)    note "the warning does not name the missing dependency" ;;
esac

# stdout must stay clean: for UserPromptSubmit it is injected into context.
DEGRADED_OUT="$(printf '{"hook_event_name":"UserPromptSubmit","cwd":"%s","prompt":"hi"}' "$ADV_REPO" \
  | PATH="$SHIM:$PATH" bash hooks/inject-git-context.sh 2>/dev/null)"
case "$DEGRADED_OUT" in
  *"ALLOWING"*|*"jq is missing"*)
    note "the degradation warning leaked to stdout, where it becomes model context" ;;
  *)
    ok "the warning stays on stderr, out of the model's context" ;;
esac

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "test-hook-faults: PASS"
else
  echo "test-hook-faults: $FAIL failure(s)"
fi
exit "$FAIL"
