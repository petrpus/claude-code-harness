#!/usr/bin/env bash
# Pre-edit hook — runs before any Write or Edit tool call.
#
# Blocks:
# - Edits to .env files (sensitive)
# - Edits to lock files outside of `pnpm install` / `npm install` flow
#
# Project-specific blocks (e.g. auto-generated docs, schema files) belong
# in a project-local pre-edit.local.sh registered alongside this one.

set -eo pipefail

PATH_ARG="${CLAUDE_TOOL_FILE_PATH:-}"

if [[ -z "$PATH_ARG" ]]; then
  exit 0
fi

# Block .env edits
if [[ "$PATH_ARG" == *.env || "$PATH_ARG" == *.env.* ]]; then
  echo "Don't edit .env files via agent — keep secrets out of agent context."
  exit 1
fi

# Block lock file direct edits
if [[ "$PATH_ARG" == */pnpm-lock.yaml || "$PATH_ARG" == */package-lock.json || "$PATH_ARG" == */yarn.lock ]]; then
  echo "Don't edit lock files directly. Run \`pnpm install <pkg>\` (or your package manager equivalent) instead."
  exit 1
fi

exit 0
