#!/usr/bin/env bash
# skills/repo-map/query.sh — five jq-expressible queries over tmp/repo-map.json.
#
# Usage: query.sh <deps|rdeps|hotspots|entry-points|stats> [args]
#   deps <file>        what <file> imports (its outgoing edges)
#   rdeps <file>       what imports <file> (its incoming edges)
#   hotspots [N]       top-N nodes by fan_in, descending (default 10)
#   entry-points       nodes with fan_in == 0 (entry points AND dead files —
#                      see skills/repo-map/SKILL.md's honest caveat)
#   stats              node/edge counts and provenance
#
# Root defaults to the current git toplevel (or cwd outside a git repo);
# override with REPO_MAP_ROOT to point at a fixture tree (used by
# scripts/test-repo-map.sh).
#
# Staleness, per docs/adr/0004-graphify-as-optional-repo-map-backend.md:
#   - map absent, or schema_version != 1        -> regenerate
#   - backend "grep", git_head != current HEAD  -> regenerate (cheap, local)
#   - backend "graphify", git_head != current HEAD -> compute drift; under
#     REPO_MAP_DRIFT_TOLERANCE (default 20) commits, serve as-is with a
#     staleness note; past it, regenerate (build-repo-map.sh's own adapter
#     re-checks graph.json and falls back to grep past its own tolerance).
#
# Requires jq. Degrades gracefully outside a git repo.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
GEN="$SCRIPT_DIR/build-repo-map.sh"

usage() {
  cat >&2 <<'USAGE'
usage: query.sh <deps|rdeps|hotspots|entry-points|stats> [args]
  deps <file>       what <file> imports
  rdeps <file>      what imports <file>
  hotspots [N]      top-N nodes by fan_in (default 10)
  entry-points      nodes with fan_in == 0
  stats             node/edge counts and provenance
USAGE
}

if ! command -v jq >/dev/null 2>&1; then
  echo "repo-map: jq is required to query tmp/repo-map.json" >&2
  exit 1
fi

CMD="${1:-}"
if [[ -z "$CMD" ]]; then
  echo "repo-map: missing subcommand" >&2
  usage
  exit 1
fi
shift || true

case "$CMD" in
  deps|rdeps|hotspots|entry-points|stats) ;;
  *)
    echo "repo-map: unknown query '$CMD'" >&2
    usage
    exit 1
    ;;
esac

if [[ "$CMD" == "deps" || "$CMD" == "rdeps" ]]; then
  if [[ -z "${1:-}" ]]; then
    echo "repo-map: '$CMD' requires a <file> argument" >&2
    usage
    exit 1
  fi
fi

if [[ "$CMD" == "hotspots" && -n "${1:-}" && ! "${1}" =~ ^[0-9]+$ ]]; then
  echo "repo-map: hotspots N must be a non-negative integer" >&2
  usage
  exit 1
fi

ROOT="${REPO_MAP_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
MAP="$ROOT/tmp/repo-map.json"
DRIFT_TOLERANCE="${REPO_MAP_DRIFT_TOLERANCE:-20}"

current_head() {
  git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo ""
}

regenerate() {
  if [[ ! -f "$GEN" ]]; then
    echo "repo-map: generator not found at $GEN" >&2
    exit 1
  fi
  bash "$GEN" "$ROOT" >&2 || { echo "repo-map: failed to generate $MAP" >&2; exit 1; }
}

ensure_fresh() {
  if [[ ! -f "$MAP" ]]; then
    regenerate
    return
  fi

  if ! jq empty "$MAP" >/dev/null 2>&1; then
    regenerate
    return
  fi

  local schema
  schema="$(jq -r '.schema_version // 0' "$MAP" 2>/dev/null)"
  if [[ "$schema" != "1" ]]; then
    regenerate
    return
  fi

  local head map_head backend
  head="$(current_head)"
  [[ -z "$head" ]] && return   # not a git repo — serve whatever is on disk

  map_head="$(jq -r '.git_head // ""' "$MAP" 2>/dev/null)"
  [[ "$head" == "$map_head" ]] && return   # fresh

  backend="$(jq -r '.backend // "grep"' "$MAP" 2>/dev/null)"
  if [[ "$backend" == "grep" ]]; then
    regenerate
    return
  fi

  # backend == graphify: we cannot re-run Graphify ourselves. Under drift
  # tolerance, serve the existing map with a staleness note. Past it, fall
  # through to the generator, whose own adapter re-validates graph.json and
  # falls back to grep past its own tolerance.
  local drift=""
  if [[ -n "$map_head" ]]; then
    drift="$(git -C "$ROOT" rev-list --count "${map_head}..${head}" 2>/dev/null)" || drift=""
  fi

  if [[ -n "$drift" && "$drift" -le "$DRIFT_TOLERANCE" ]]; then
    echo "repo-map: graphify map is $drift commit(s) behind HEAD (tolerance $DRIFT_TOLERANCE) — serving as-is" >&2
  else
    regenerate
  fi
}

ensure_fresh

if [[ ! -f "$MAP" ]]; then
  echo "repo-map: no map at $MAP and generation did not produce one" >&2
  exit 1
fi

if ! jq empty "$MAP" >/dev/null 2>&1; then
  echo "repo-map: $MAP is not valid JSON" >&2
  exit 1
fi

case "$CMD" in
  # `unique` is load-bearing, not tidiness: edges dedupe on (from, to, type), so
  # a backend that reports several relationships between the same pair — the
  # Graphify adapter emitting both `imports` and `calls` — yields one row per
  # type. These queries answer "which files", not "which relationships".
  deps)
    jq -r --arg f "$1" '[.edges[] | select(.from == $f) | .to] | unique | .[]' "$MAP"
    ;;
  rdeps)
    jq -r --arg f "$1" '[.edges[] | select(.to == $f) | .from] | unique | .[]' "$MAP"
    ;;
  hotspots)
    N="${1:-10}"
    jq -r --argjson n "$N" '.nodes | sort_by(-.fan_in) | .[:$n] | .[] | "\(.id)\t\(.fan_in)"' "$MAP"
    ;;
  entry-points)
    jq -r '.nodes[] | select(.fan_in == 0) | .id' "$MAP"
    ;;
  stats)
    jq '{
      schema_version, backend, backend_version, git_head, generated_at,
      nodes: (.nodes | length),
      edges: (.edges | length)
    }' "$MAP"
    ;;
esac
