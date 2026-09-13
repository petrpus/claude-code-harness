#!/usr/bin/env bash
# PreToolUse hook for Write|Edit — blocks edits to secrets and lock files.
#
# Contract: reads tool_input.file_path from the JSON on stdin.
#   exit 0 = allow · exit 2 = BLOCK (stderr shown to Claude).
#
# Project-specific blocks (auto-generated docs, schema files) belong in a
# project-local hook registered alongside this one.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib.sh"

read_stdin_json
PATH_ARG="$(hook_tool_file_path)"

[[ -z "$PATH_ARG" ]] && exit 0

base="$(basename "$PATH_ARG")"

# Allow committed env files FIRST — these are documentation and test defaults,
# not secrets: .env.example is meant to be edited (project-infra's `env` mode
# writes it; .gitignore un-ignores it), and .env.test carries test-environment
# defaults that Vitest/Playwright read.
#
# Matched on the FULL basename, so `.env.test.local` is not covered here and
# falls through to the block below — the `.local` suffix is the conventional
# marker for the uncommitted, secret-bearing variant of any of these.
case "$base" in
  .env.example|*.env.example|.env.template|*.env.template|.env.sample|*.env.sample|.env.test|*.env.test)
    exit 0
    ;;
esac

# Block real .env files (secrets).
case "$base" in
  .env|.env.*|*.env)
    echo "Don't edit .env files via agent — keep secrets out of agent context." >&2
    echo "(.env.example / .env.template are allowed for documenting variable names.)" >&2
    exit 2
    ;;
esac

# Block direct lock-file edits.
case "$base" in
  pnpm-lock.yaml|package-lock.json|yarn.lock|bun.lockb|Cargo.lock|poetry.lock)
    echo "Don't edit lock files directly. Run your package manager (e.g. \`pnpm install <pkg>\`) instead." >&2
    exit 2
    ;;
esac

exit 0
