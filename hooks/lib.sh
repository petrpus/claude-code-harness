#!/usr/bin/env bash
# hooks/lib.sh — shared helpers for claude-code-harness hooks.
#
# Claude Code passes hook input as a JSON object on STDIN, e.g.:
#   {"session_id":"...","transcript_path":"...","cwd":"...",
#    "hook_event_name":"PreToolUse","tool_name":"Bash",
#    "tool_input":{"command":"git push"}}
#
# These helpers read that JSON ONCE and expose fields. Parsing is done
# strictly via `jq`. We deliberately do NOT ship a sed/grep JSON parser:
# regex-scraping arbitrary shell out of `tool_input.command` (quotes,
# escapes, newlines) both false-blocks and false-allows and gives fake
# confidence. Without jq we fail OPEN (allow) — the hard security layer is
# settings.json deny rules, which need no jq. `harness-doctor` flags a
# missing jq so the guards can be restored.
#
# No `set -e` anywhere in hooks (a stray non-zero mid-script must not abort
# a turn). `set -u` only, and even that is scoped by callers.

# Reads stdin into HOOK_INPUT (global). Safe to call once per hook.
read_stdin_json() {
  # -r: raw, -d '': slurp everything including newlines. Never blocks the
  # turn: if nothing is piped, HOOK_INPUT is empty and callers fail open.
  IFS= read -r -d '' HOOK_INPUT 2>/dev/null || true
  export HOOK_INPUT
}

# have_jq: 0 if jq is usable, 1 otherwise.
#
# "Present" isn't the question — "works" is. A jq that exists but errors leaves
# every guard reading an empty command and allowing the call, exactly as a
# missing one does, so both are proven the same way: run a known expression and
# check the known answer. The result is cached, because hooks fire on every
# tool call and one probe per hook process is the whole budget.
_HARNESS_JQ_STATE=""
have_jq() {
  if [[ -z "$_HARNESS_JQ_STATE" ]]; then
    if command -v jq >/dev/null 2>&1 && [[ "$(printf '{"_":1}' | jq -r '._' 2>/dev/null)" == "1" ]]; then
      _HARNESS_JQ_STATE=ok
    else
      _HARNESS_JQ_STATE=bad
    fi
  fi
  [[ "$_HARNESS_JQ_STATE" == "ok" ]]
}

# Failing open is the deliberate choice (see the header) — failing open
# *quietly* is not. Without this, a broken jq leaves the push-from-main, .env
# and rm -rf guards installed, listed in hooks.json, exiting 0, and not
# guarding anything, with nobody the wiser. Always stderr: stdout from a
# UserPromptSubmit hook is injected into the model's context.
_HARNESS_DEGRADED_WARNED=0
warn_guard_degraded() {
  [[ "$_HARNESS_DEGRADED_WARNED" -eq 1 ]] && return 0
  _HARNESS_DEGRADED_WARNED=1
  echo "claude-code-harness: jq is missing or not working — hook guards cannot read this tool call and are ALLOWING it. Install a working jq to restore the push-from-main, .env and rm -rf guards." >&2
  return 0
}

# json_field <jq-filter> — echoes the field value, empty string if jq is
# absent, input is empty, or the field is null/missing.
json_field() {
  local filter="$1"
  if [[ -z "${HOOK_INPUT:-}" ]]; then
    echo ""
    return 0
  fi
  if have_jq; then
    printf '%s' "$HOOK_INPUT" | jq -r "$filter // empty" 2>/dev/null || echo ""
  else
    warn_guard_degraded
    echo ""
  fi
}

# Convenience accessors for the common fields.
hook_tool_command()   { json_field '.tool_input.command'; }
hook_tool_file_path() { json_field '.tool_input.file_path'; }
hook_cwd()            { json_field '.cwd'; }
hook_session_id()     { json_field '.session_id'; }

# mtime_of <file> — epoch seconds of last modification, portable across
# GNU (`stat -c %Y`) and BSD/macOS (`stat -f %m`). Echoes 0 on failure.
# Always echoes a non-negative integer: a `stat` that exits 0 while printing
# nothing (or nonsense) would otherwise feed a bare word into $(( )), and an
# arithmetic syntax error there takes the whole hook down with a non-zero exit
# — a hook must not fail a turn because a coreutil misbehaved.
mtime_of() {
  local f="$1" m
  m="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
  [[ "$m" =~ ^[0-9]+$ ]] || m=0
  printf '%s' "$m"
}

# now_epoch — same contract for `date`.
now_epoch() {
  local n
  n="$(date +%s 2>/dev/null || echo 0)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

# cd into the repo top-level (or the hook cwd, or pwd). Never fails the hook.
cd_repo_root() {
  local target
  target="$(hook_cwd)"
  if [[ -n "$target" && -d "$target" ]]; then
    cd "$target" 2>/dev/null || true
  fi
  cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" 2>/dev/null || true
}
