#!/usr/bin/env bash
# skills/repo-map/digest.sh — compact repo-map digest for autopilot's BUILD
# prompt. Closes ADR-0004 item 7 (docs/adr/0004-*.md) / PRD 0002 § S5: autopilot
# gets a compact digest, not the whole graph.
#
# Usage: digest.sh [slice-hint-text]
#   slice-hint-text: the selected plan slice's own line (S1's SELECTED_LINE),
#   scanned for file paths worth a deps/rdeps lookup. Optional; with none the
#   digest is stats + hotspots only.
#
# Emits <= 40 lines to stdout:
#   stats: <one-line compact JSON from `query.sh stats`>
#   hotspots:
#     <id>\t<fan_in>          (top 10, from `query.sh hotspots 10`)
#   file: <path>               (once per distinct file path found in the hint
#     deps: a,b,c                that also has real deps/rdeps in the map)
#     rdeps: x,y                  (each capped at 8 entries)
#
# Uses query.sh's five queries only — never reads tmp/repo-map.json directly,
# so staleness/regeneration policy stays single-sourced in query.sh. Never a
# hard error: any query.sh failure (missing jq/awk, an ungeneratable map) means
# "no digest" — exit 1, nothing on stdout. The caller (loop.sh's
# build_prompt()) treats that as "omit the whole section," not an iteration
# failure — repo-map's own fault-injection contract already guarantees no
# WRONG graph reaches exit 0, so silence here is the only failure shape to
# handle.
#
# Do NOT wire this into plan_prompt() or verify_prompt() — PRD § S5: the grep
# backend's phantom edges would freeze into a plan `after:` edge that
# select_next_slice() then enforces as hard ordering, the opposite of what a
# wide Plan DAG needs. BUILD can discount a wrong hint by opening the file
# anyway; PLAN and the verifier must not be handed one at all.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
QUERY="$SCRIPT_DIR/query.sh"
LINE_CAP=40
DEPS_CAP=8
HINT="${1:-}"

[[ -f "$QUERY" ]] || exit 1

# stats is the canary: if query.sh can't even produce that, there is no map to
# digest at all and everything past here is skipped. A later deps/rdeps/hotspots
# call failing is not fatal — it just narrows the digest (best-effort, like any
# other repo-map consumer).
STATS="$(bash "$QUERY" stats 2>/dev/null)"
[[ -n "$STATS" ]] || exit 1
STATS_LINE="$(printf '%s' "$STATS" | jq -c '.' 2>/dev/null)"
[[ -n "$STATS_LINE" ]] || exit 1

{
  printf 'stats: %s\n' "$STATS_LINE"
  echo 'hotspots:'
  bash "$QUERY" hotspots 10 2>/dev/null | sed 's/^/  /'

  if [[ -n "$HINT" ]]; then
    declare -A seen=()
    for tok in $(printf '%s' "$HINT" | grep -oE '[A-Za-z0-9_./-]+\.[A-Za-z0-9]+' 2>/dev/null); do
      [[ -n "${seen[$tok]:-}" ]] && continue
      seen["$tok"]=1
      DEPS="$(bash "$QUERY" deps "$tok" 2>/dev/null | head -n "$DEPS_CAP" | tr '\n' ',' | sed 's/,$//')"
      RDEPS="$(bash "$QUERY" rdeps "$tok" 2>/dev/null | head -n "$DEPS_CAP" | tr '\n' ',' | sed 's/,$//')"
      # A token that resolves to no node in the map (a bare filename, prose
      # that merely looks path-shaped) has empty deps AND rdeps — skip it
      # rather than printing an empty entry.
      [[ -z "$DEPS" && -z "$RDEPS" ]] && continue
      printf 'file: %s\n' "$tok"
      printf '  deps: %s\n' "${DEPS:-none}"
      printf '  rdeps: %s\n' "${RDEPS:-none}"
    done
  fi
} | head -n "$LINE_CAP"
