#!/usr/bin/env bash
# skills/autopilot/allowlist.sh — BUILD-phase tool grants derived from the
# project's verify command. Sourced by loop.sh; kept in its own file so the
# derivation is testable without running a whole autonomous run (scripts/
# verify.sh asserts it directly).
#
# The BUILD prompt instructs the model to run the verify command, but loop.sh's
# static allowlist mirrors a JS project template — a repo whose verify is its
# own script would have that call *denied*, leaving BUILD unable to prove a
# slice before ticking it. So the resolved verify command is granted, and
# nothing broader: `Bash(bash:*)` derived from `bash scripts/verify.sh` would
# hand BUILD arbitrary shell under acceptEdits, which is the opposite of an
# allowlist.

# Interpreters whose name says nothing about what will be run. A prefix grant
# on any of these is a grant on everything they can execute.
_AUTOPILOT_INTERPRETERS="bash sh dash zsh ksh env python python3 node ruby perl make npm pnpm yarn npx deno bun"

# verify_grants <verify-cmd>
#   Echoes the comma-separated tool grants for that command. Always includes the
#   exact command; adds a `<binary>:*` prefix grant only when the leading token
#   names a real program rather than an interpreter.
verify_grants() {
  local cmd="$1" head base word
  [[ -z "$cmd" ]] && return 0
  head="${cmd%% *}"
  base="${head##*/}"

  for word in $_AUTOPILOT_INTERPRETERS; do
    if [[ "$base" == "$word" ]]; then
      printf 'Bash(%s)' "$cmd"
      return 0
    fi
  done

  printf 'Bash(%s),Bash(%s:*)' "$cmd" "$head"
}

# verify_grants_are_narrow <verify-cmd>
#   True when the prefix grant was withheld — loop.sh logs in that case, so a
#   run whose BUILD cannot invoke verify says why instead of failing obscurely.
verify_grants_are_narrow() {
  [[ "$(verify_grants "$1")" != *':*)' ]]
}

# detect_verify_cmd
#   Echoes the verify command for the current directory, trying project types
#   in order (package.json -> scripts/verify.sh -> Makefile) and falling
#   through on a miss at each step. Empty output and a non-zero exit when none
#   of them apply — the caller decides what "no verify command" means.
detect_verify_cmd() {
  if [[ -f package.json ]] && jq -e '.scripts.verify' package.json >/dev/null 2>&1; then
    if [[ -f pnpm-lock.yaml ]]; then
      printf 'pnpm verify'
    else
      printf 'npm run verify'
    fi
    return 0
  fi

  if [[ -f scripts/verify.sh ]]; then
    printf 'bash scripts/verify.sh'
    return 0
  fi

  local mf
  for mf in Makefile makefile GNUmakefile; do
    if [[ -f "$mf" ]] && grep -qE '^verify:' "$mf"; then
      printf 'make verify'
      return 0
    fi
  done

  return 1
}
