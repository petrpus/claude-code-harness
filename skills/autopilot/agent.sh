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
#     AGENT_BASH_TIMEOUT_MS  the Bash tool's default and maximum command time
#                       inside the call (default: AGENT_TIMEOUT). Claude Code's
#                       own default is 2 minutes — shorter than many verify
#                       commands, so BUILD never saw verify finish (#86).
#     AGENT_TRANSCRIPT_DIR  if set, each call's reply is kept there as
#                       <seq>-<phase>.md, so a failed iteration can be read
#                       instead of inferred
#
#   Results (globals, set by every call, dry runs included):
#     AGENT_LAST_RC, AGENT_LAST_JSON, AGENT_LAST_RESULT, AGENT_LAST_COST,
#     AGENT_LAST_DURATION, AGENT_LAST_IN_TOKENS, AGENT_LAST_OUT_TOKENS,
#     AGENT_LAST_TURNS, AGENT_LAST_CACHE_READ, AGENT_LAST_CACHE_CREATION,
#     AGENT_LAST_COST_UNKNOWN (1 when `timeout` killed the call: the cost it
#     had run up is unknowable, and AGENT_LAST_COST's 0 means "unknown", not
#     "free"; 0 otherwise, dry runs included),
#     AGENT_LAST_SUBTYPE (the reply's `subtype`: "success", or an error such
#     as "error_max_turns" — the call ran out of --max-turns, #96)
#
#   Missing fields (a stub, a crashed call, a dry run) read as 0 / "" — the
#   output shape is never a hard requirement. Needs jq and coreutils timeout.
#
#   Every call runs WITHOUT MCP servers: `--strict-mcp-config` with an empty
#   `--mcp-config`, so none of the user's or the project's configured servers
#   (a mailbox, a recordings service, a browser) is started for an autonomous
#   call that never asked for them (first live run, #83).
#
#   Every call runs WITHOUT forge credentials (ADR-0007): see
#   agent_withhold_forge_credentials below. A model phase that reaches `gh`
#   or `git push` anyway — through a script it edited and may run, say —
#   meets an unauthenticated gh and a git with no credential source.

# agent_withhold_forge_credentials — call inside the subshell that runs the
# model, never in the runner's own shell (the runner keeps its credentials
# for the forge operations it alone performs):
#   - gh: tokens in the environment unset, GH_CONFIG_DIR pointed at an empty
#     private dir — gh then has no host and no keyring entry to use;
#   - git over https: every credential helper cleared (an empty
#     credential.helper appended through GIT_CONFIG_COUNT resets the whole
#     list, the URL-specific `gh auth git-credential` and a plaintext `store`
#     included), and no prompt or askpass to fall back on;
#   - git over ssh: no agent socket, and an ssh command that always fails.
#
# What this does and does not stop: it stops a model phase from acting on the
# forge by accident or by following instructions (an issue body that says
# "push this") — the credentials are simply not where gh and git look. It
# does NOT stop a model that deliberately points them back (`git -c
# credential.helper=store push`, `GH_CONFIG_DIR=~/.config/gh gh …`), because
# the model runs as the same user and can read those files. That needs an
# OS / network sandbox (see ADR-0007). Also out of reach of the environment:
# a remote that needs no credentials (a local path), a ~/.netrc entry (git's
# https transport reads it directly), and a bare `ssh` with a passphrase-less
# key speaking the git protocol itself.
# agent_noforge_dir — ensure AGENT_NOFORGE_DIR is an empty private dir (one
# per process, reused). Returns 1 if it cannot be made.
agent_noforge_dir() {
  if [[ -z "${AGENT_NOFORGE_DIR:-}" || ! -d "$AGENT_NOFORGE_DIR" ]]; then
    AGENT_NOFORGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-noforge.XXXXXX" 2>/dev/null)" || AGENT_NOFORGE_DIR=""
  fi
  [[ -n "$AGENT_NOFORGE_DIR" && -d "$AGENT_NOFORGE_DIR" ]]
}

# agent_cleanup — remove the private dir; for the caller's EXIT trap.
# rmdir, never rm -rf: the dir is meant to stay empty, and if anything ever
# wrote into it, leaving it for a human beats deleting what we did not create.
agent_cleanup() {
  [[ -n "${AGENT_NOFORGE_DIR:-}" && -d "$AGENT_NOFORGE_DIR" ]] && rmdir "$AGENT_NOFORGE_DIR" 2>/dev/null
  AGENT_NOFORGE_DIR=""
  return 0
}

# agent_run_without_forge_credentials <cmd> [args…] — run a command the
# runner executes but a model may have written (the verify command, which
# BUILD can edit) under the same withheld credentials as a model call.
# Returns the command's exit code, or 125 with AGENT_REFUSED=1 when
# credentials cannot be withheld and nothing ran — the flag, not the code,
# tells a refusal apart from a command that itself exits 125.
agent_run_without_forge_credentials() {
  AGENT_REFUSED=0
  agent_noforge_dir || { AGENT_REFUSED=1; return 125; }
  ( agent_withhold_forge_credentials; "$@" )
}

agent_withhold_forge_credentials() {
  unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN SSH_AUTH_SOCK
  export GH_CONFIG_DIR="${AGENT_NOFORGE_DIR:?}"
  export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=false SSH_ASKPASS=false GIT_SSH_COMMAND=false
  local n="${GIT_CONFIG_COUNT:-0}"
  export "GIT_CONFIG_KEY_$n=credential.helper" "GIT_CONFIG_VALUE_$n="
  export GIT_CONFIG_COUNT=$(( n + 1 ))
}

agent_run() {
  local phase="$1" model="$2" allowed="$3" perm="$4" prompt="$5" cwd="${6:-}"
  local t0 t1 out rc errlog="${AGENT_STDERR_LOG:-/dev/null}"
  # Resolve a relative log path before the call changes directory into cwd.
  [[ "$errlog" == /* ]] || errlog="$PWD/$errlog"
  printf -v t0 '%(%s)T' -1   # builtin clock: no fork, no `date` (#78)
  if [[ "${AGENT_DRY_RUN:-0}" -eq 1 ]]; then
    echo "[dry-run] would run $phase on $model (perm=$perm)" >&2
    out='{"result":"dry-run","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0}}'
    rc=0
  else
    local -a extra=()
    [[ -n "${AGENT_DISALLOWED_TOOLS:-}" ]] && extra=(--disallowedTools "$AGENT_DISALLOWED_TOOLS")
    agent_noforge_dir || true
    local bash_ms="${AGENT_BASH_TIMEOUT_MS:-$(( ${AGENT_TIMEOUT:-1200} * 1000 ))}"
    out="$(
      export BASH_DEFAULT_TIMEOUT_MS="$bash_ms" BASH_MAX_TIMEOUT_MS="$bash_ms"
      # No private gh dir means credentials cannot be withheld: refuse the
      # call (125, like an unusable cwd) rather than run it with them.
      [[ -n "$AGENT_NOFORGE_DIR" && -d "$AGENT_NOFORGE_DIR" ]] || exit 125
      agent_withhold_forge_credentials
      # 125: "could not even start the command" (the xargs/env convention),
      # so an unusable cwd is told apart from anything claude itself returns.
      if [[ -n "$cwd" ]]; then cd "$cwd" || exit 125; fi
      timeout "${AGENT_TIMEOUT:-1200}" claude -p "$prompt" \
        --model "$model" --output-format json \
        --permission-mode "$perm" --allowedTools "$allowed" \
        --max-turns "${AGENT_MAX_TURNS:-80}" \
        --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
        ${extra[@]+"${extra[@]}"} 2>>"$errlog"
    )"
    rc=$?
  fi
  printf -v t1 '%(%s)T' -1

  AGENT_LAST_RC="$rc"
  AGENT_LAST_JSON="$out"
  AGENT_LAST_DURATION=$(( t1 - t0 ))
  # rc 124 is timeout's kill; an empty reply after a call that ran to the
  # limit is the same thing seen through a wrapper that ate the code.
  AGENT_LAST_COST_UNKNOWN=0
  if [[ "${AGENT_DRY_RUN:-0}" -ne 1 ]]; then
    if [[ "$rc" -eq 124 ]] || { [[ -z "$out" ]] && (( AGENT_LAST_DURATION >= ${AGENT_TIMEOUT:-1200} )); }; then
      AGENT_LAST_COST_UNKNOWN=1
    fi
  fi
  # One jq pass: every field or its default, tab-separated. A non-JSON reply
  # (a crash, a timeout's empty output) falls through to the all-defaults line.
  local fields
  fields="$(printf '%s' "$out" | jq -r '[
      (.total_cost_usd // 0), (.usage.input_tokens // 0), (.usage.output_tokens // 0),
      (.num_turns // 0), (.usage.cache_read_input_tokens // 0),
      (.usage.cache_creation_input_tokens // 0), (.subtype // "-")
    ] | map(tostring) | join("\t")' 2>/dev/null)" || fields=""
  [[ -n "$fields" ]] || fields=$'0\t0\t0\t0\t0\t0\t-'
  IFS=$'\t' read -r AGENT_LAST_COST AGENT_LAST_IN_TOKENS AGENT_LAST_OUT_TOKENS \
    AGENT_LAST_TURNS AGENT_LAST_CACHE_READ AGENT_LAST_CACHE_CREATION AGENT_LAST_SUBTYPE <<<"$fields"
  [[ "$AGENT_LAST_SUBTYPE" == "-" ]] && AGENT_LAST_SUBTYPE=""
  AGENT_LAST_RESULT="$(printf '%s' "$out" | jq -r '.result // ""' 2>/dev/null)" || AGENT_LAST_RESULT=""
  if [[ -n "${AGENT_TRANSCRIPT_DIR:-}" ]] && mkdir -p "$AGENT_TRANSCRIPT_DIR" 2>/dev/null; then
    # Continue after the files already there: a resumed or reloaded run is a
    # new process, and must not overwrite the replies of the one before.
    # Assumes one writer per directory (loop.sh's lock guarantees it for its
    # state dir); give a second writer its own directory.
    if [[ -z "${AGENT_CALL_SEQ:-}" ]]; then
      AGENT_CALL_SEQ="$(find "$AGENT_TRANSCRIPT_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
    fi
    AGENT_CALL_SEQ=$(( AGENT_CALL_SEQ + 1 ))
    printf '<!-- %s · model %s · exit %s · %ss -->\n%s\n' "$phase" "$model" "$rc" "$AGENT_LAST_DURATION" \
      "$AGENT_LAST_RESULT" > "$AGENT_TRANSCRIPT_DIR/$(printf '%03d' "$AGENT_CALL_SEQ")-$phase.md" 2>/dev/null || true
  fi
  return "$rc"
}
