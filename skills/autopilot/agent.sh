#!/usr/bin/env bash
# skills/autopilot/agent.sh — the one place a model is called: `claude -p`
# under a wall-clock timeout, JSON output parsed into globals. Sourced by
# loop.sh (every PLAN / BUILD / verifier call) and by /deliver's runner; the
# backend seam #42 (M4) will swap here.
#
# agent_run <phase> <model> <allowed_tools> <permission_mode> <prompt> [cwd]
#
#   Runs one call and returns its exit code. It prints NOTHING: the answer is
#   left in AGENT_LAST_RESULT. That is deliberate — a function that echoes
#   its answer invites `x="$(agent_run ...)"`, which runs it in a subshell
#   where every global it sets (the cost above all) is lost. loop.sh's
#   verifier calls did exactly that until this file existed, so their cost
#   never reached the budget cap.
#
#   Knobs (globals, read at call time):
#     AGENT_TIMEOUT     seconds per call (default 1200)
#     AGENT_MAX_TURNS   --max-turns (default 80)
#     AGENT_DRY_RUN     1 = don't call, return a zero-cost "dry-run" result
#     AGENT_STDERR_LOG  where claude's stderr is appended (default /dev/null)
#     AGENT_DISALLOWED_TOOLS  optional --disallowedTools list: tools the call
#                       may not use even if a permission mode would allow them
#
#   Results (globals, set by every call, dry runs included):
#     AGENT_LAST_RC, AGENT_LAST_JSON, AGENT_LAST_RESULT, AGENT_LAST_COST,
#     AGENT_LAST_DURATION, AGENT_LAST_IN_TOKENS, AGENT_LAST_OUT_TOKENS,
#     AGENT_LAST_TURNS, AGENT_LAST_CACHE_READ, AGENT_LAST_CACHE_CREATION
#
#   Missing fields (a stub, a crashed call, a dry run) read as 0 / "" — the
#   output shape is never a hard requirement. Needs jq and coreutils timeout.

agent_run() {
  local phase="$1" model="$2" allowed="$3" perm="$4" prompt="$5" cwd="${6:-}"
  local t0 t1 out rc errlog="${AGENT_STDERR_LOG:-/dev/null}"
  # Resolve a relative log path before the call changes directory into cwd.
  [[ "$errlog" == /* ]] || errlog="$PWD/$errlog"
  t0="$(date +%s 2>/dev/null || echo 0)"
  if [[ "${AGENT_DRY_RUN:-0}" -eq 1 ]]; then
    echo "[dry-run] would run $phase on $model (perm=$perm)" >&2
    out='{"result":"dry-run","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0}}'
    rc=0
  else
    local -a extra=()
    [[ -n "${AGENT_DISALLOWED_TOOLS:-}" ]] && extra=(--disallowedTools "$AGENT_DISALLOWED_TOOLS")
    out="$(
      # 125: "could not even start the command" (the xargs/env convention),
      # so an unusable cwd is told apart from anything claude itself returns.
      if [[ -n "$cwd" ]]; then cd "$cwd" || exit 125; fi
      timeout "${AGENT_TIMEOUT:-1200}" claude -p "$prompt" \
        --model "$model" --output-format json \
        --permission-mode "$perm" --allowedTools "$allowed" \
        --max-turns "${AGENT_MAX_TURNS:-80}" ${extra[@]+"${extra[@]}"} 2>>"$errlog"
    )"
    rc=$?
  fi
  t1="$(date +%s 2>/dev/null || echo 0)"

  AGENT_LAST_RC="$rc"
  AGENT_LAST_JSON="$out"
  AGENT_LAST_DURATION=$(( t1 - t0 ))
  # One jq pass: every field or its default, tab-separated. A non-JSON reply
  # (a crash, a timeout's empty output) falls through to the all-defaults line.
  local fields
  fields="$(printf '%s' "$out" | jq -r '[
      (.total_cost_usd // 0), (.usage.input_tokens // 0), (.usage.output_tokens // 0),
      (.num_turns // 0), (.usage.cache_read_input_tokens // 0),
      (.usage.cache_creation_input_tokens // 0)
    ] | map(tostring) | join("\t")' 2>/dev/null)" || fields=""
  [[ -n "$fields" ]] || fields=$'0\t0\t0\t0\t0\t0'
  IFS=$'\t' read -r AGENT_LAST_COST AGENT_LAST_IN_TOKENS AGENT_LAST_OUT_TOKENS \
    AGENT_LAST_TURNS AGENT_LAST_CACHE_READ AGENT_LAST_CACHE_CREATION <<<"$fields"
  AGENT_LAST_RESULT="$(printf '%s' "$out" | jq -r '.result // ""' 2>/dev/null)" || AGENT_LAST_RESULT=""
  return "$rc"
}
