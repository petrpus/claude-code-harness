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
have_jq() { command -v jq >/dev/null 2>&1; }

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
mtime_of() {
  local f="$1"
  stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0
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
