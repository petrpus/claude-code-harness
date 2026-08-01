#!/usr/bin/env bash
# skills/repo-map/build-repo-map.sh — grep-backend generator for tmp/repo-map.json.
#
# Scans JS/TS/Python import/require edges, resolves relative and
# tsconfig/jsconfig path-alias specifiers to real files, drops unresolved bare
# specifiers (external packages, stdlib), and writes tmp/repo-map.json per
# Schema v1 (see docs/adr/0004-graphify-as-optional-repo-map-backend.md).
#
# Usage: build-repo-map.sh [root-dir]
#   root-dir defaults to the current git toplevel, or cwd outside a git repo.
#
# Requires: bash, jq, git, rg. Fails with a clear message if jq or rg is
# missing rather than emitting a malformed or edgeless map. Degrades gracefully
# outside a git repo (empty git_head, not a crash).

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "repo-map: jq is required to build tmp/repo-map.json" >&2
  exit 1
fi

# rg is as load-bearing as jq: without it every scan silently matches nothing
# and the map comes out with all its nodes and none of its edges — a map that
# is confidently, undetectably wrong. Fail loudly instead. REPO_MAP_RG exists
# so the guard itself is testable (and lets a caller point at a non-default
# ripgrep).
RG="${REPO_MAP_RG:-rg}"
if ! command -v "$RG" >/dev/null 2>&1; then
  echo "repo-map: ripgrep ('$RG') is required to build tmp/repo-map.json" >&2
  echo "repo-map: refusing to write an edgeless map that would look valid" >&2
  exit 1
fi

ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT" 2>/dev/null || { echo "repo-map: cannot cd into '$ROOT'" >&2; exit 1; }

GIT_HEAD=""
if git rev-parse --show-toplevel >/dev/null 2>&1; then
  GIT_HEAD="$(git rev-parse --short HEAD 2>/dev/null || echo "")"
fi
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

OUT_DIR="tmp"
OUT="$OUT_DIR/repo-map.json"
mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------------------
# Graphify adapter (optional, detection-only — see
# docs/adr/0004-graphify-as-optional-repo-map-backend.md). If a graph.json is
# already on disk, validate its shape defensively and, when trustworthy and
# not too stale, adapt it instead of running the grep scan below. Any
# rejection (absent is silent; malformed or too-stale warns) falls straight
# through to the grep backend — never a hard error, always exit 0.
DRIFT_TOLERANCE="${REPO_MAP_DRIFT_TOLERANCE:-20}"
GRAPH_JSON="$ROOT/graph.json"

fallback_notice() {
  echo "repo-map: $1 — falling back to grep backend; re-run Graphify and refresh graph.json for the richer map" >&2
}

try_graphify() {
  [[ -f "$GRAPH_JSON" ]] || return 1

  if ! jq empty "$GRAPH_JSON" >/dev/null 2>&1; then
    fallback_notice "graph.json is not valid JSON"
    return 1
  fi

  if ! jq -e '(.nodes | type) == "array" and (.edges | type) == "array"' "$GRAPH_JSON" >/dev/null 2>&1; then
    fallback_notice "graph.json is missing nodes[]/edges[] arrays"
    return 1
  fi

  if ! jq -e '.nodes | all(has("id") and has("file") and (.id | type) == "string" and (.file | type) == "string")' \
       "$GRAPH_JSON" >/dev/null 2>&1; then
    fallback_notice "graph.json nodes are missing id/file"
    return 1
  fi

  if ! jq -e '
        (.nodes | map(.id)) as $ids |
        .edges | all(has("from") and has("to") and has("type") and (([.from, .to] - $ids) | length == 0))
      ' "$GRAPH_JSON" >/dev/null 2>&1; then
    fallback_notice "graph.json edges reference unknown node ids"
    return 1
  fi

  local gj_head drift=""
  gj_head="$(jq -r '.git_head // empty' "$GRAPH_JSON" 2>/dev/null)"
  if [[ -n "$gj_head" && -n "$GIT_HEAD" ]]; then
    drift="$(git -C "$ROOT" rev-list --count "${gj_head}..${GIT_HEAD}" 2>/dev/null)" || drift=""
    if [[ -z "$drift" ]]; then
      fallback_notice "graph.json git_head '$gj_head' is not a known ancestor of HEAD"
      return 1
    fi
    if (( drift > DRIFT_TOLERANCE )); then
      fallback_notice "graph.json is $drift commit(s) behind HEAD (tolerance $DRIFT_TOLERANCE)"
      return 1
    fi
    if (( drift > 0 )); then
      echo "repo-map: using graphify backend, $drift commit(s) behind HEAD (tolerance $DRIFT_TOLERANCE)" >&2
    fi
  fi

  local out_head="${gj_head:-$GIT_HEAD}"
  local backend_version_raw
  backend_version_raw="$(jq -r '(.backend_version // .version // empty)' "$GRAPH_JSON" 2>/dev/null)"

  jq -n \
    --arg schema_version "1" \
    --arg generated_at "$GENERATED_AT" \
    --arg git_head "$out_head" \
    --arg backend_version_raw "$backend_version_raw" \
    --slurpfile gj "$GRAPH_JSON" \
    '
    ($gj[0]) as $g |
    ($g.nodes | reduce .[] as $n ({}; .[$n.id] = $n.file)) as $id2file |
    ($g.nodes | map(.file) | unique) as $files |
    ( $g.edges
      | map({from: $id2file[.from], to: $id2file[.to], type: .type})
      | map(select(.from != .to))
      | group_by([.from, .to, .type])
      | map({from: .[0].from, to: .[0].to, type: .[0].type, weight: length})
    ) as $edges |
    ($edges | group_by(.to)   | map({key: .[0].to,   value: (map(.from) | unique | length)}) | from_entries) as $fan_in |
    ($edges | group_by(.from) | map({key: .[0].from, value: (map(.to)   | unique | length)}) | from_entries) as $fan_out |
    {
      schema_version: ($schema_version | tonumber),
      generated_at: $generated_at,
      git_head: $git_head,
      backend: "graphify",
      backend_version: (if $backend_version_raw == "" then null else $backend_version_raw end),
      nodes: [ $files[] | {
        id: .,
        label: (split("/") | last),
        kind: "file",
        fan_in: ($fan_in[.] // 0),
        fan_out: ($fan_out[.] // 0)
      } ],
      edges: $edges
    }
    ' > "$OUT" || return 1

  echo "repo-map: wrote $OUT via graphify backend ($(jq '.nodes | length' "$OUT") nodes, $(jq '.edges | length' "$OUT") edges)" >&2
  return 0
}

if try_graphify; then
  exit 0
fi

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

FILES_LIST="$WORK/files.txt"
ALIASES="$WORK/aliases.tsv"
RAW="$WORK/raw-edges.tsv"
EDGES="$WORK/edges.tsv"

# ---------------------------------------------------------------------------
# 1. Enumerate candidate source files (repo-relative, '/'-normalized).
find . -type f \( -name '*.js' -o -name '*.jsx' -o -name '*.ts' -o -name '*.tsx' \
                -o -name '*.mjs' -o -name '*.cjs' -o -name '*.py' \) 2>/dev/null \
  | sed 's|^\./||' \
  | grep -vE '(^|/)(node_modules|\.git|tmp)(/|$)' \
  | sort -u > "$FILES_LIST"

# ---------------------------------------------------------------------------
# 2. Collect tsconfig/jsconfig path aliases as "prefix<TAB>replacement" rows,
#    e.g. "@/" -> "src/" from { "paths": { "@/*": ["src/*"] } }.
: > "$ALIASES"
for cfg in tsconfig.json jsconfig.json; do
  [[ -f "$cfg" ]] || continue
  jq -r '
    (.compilerOptions.paths // {}) | to_entries[]? |
    .key as $k | (.value[0] // "") as $v |
    "\($k)\t\($v)"
  ' "$cfg" 2>/dev/null | while IFS=$'\t' read -r key val; do
    [[ -z "$key" || -z "$val" ]] && continue
    printf '%s\t%s\n' "${key%\*}" "${val%\*}"
  done >> "$ALIASES"
done

# ---------------------------------------------------------------------------
# 3. Scan raw import specifiers into RAW as "file<TAB>specifier".
: > "$RAW"

# A specifier named inside a line comment — `// copied from './legacy/old'` —
# is prose, not a dependency, but it reads exactly like one to a regex. Left in,
# it invents an edge and inflates the target's fan_in, which is the very metric
# `hotspots` ranks on. Strip line comments before matching. A specifier inside a
# string literal still slips through: that is the accuracy ceiling of a regex
# backend, and precisely why the Graphify backend exists (see SKILL.md).
strip_line_comments() { # file comment-marker-regex
  sed -E "s:${2}.*$::" "$1" 2>/dev/null
}

scan_js() {
  local f="$1" src
  src="$(strip_line_comments "$f" '//')"
  # import ... from '...'  /  export ... from '...'
  printf '%s\n' "$src" | "$RG" -oN "from\s+['\"][^'\"]+['\"]" 2>/dev/null | sed -E "s/^from[[:space:]]+['\"]//; s/['\"]$//" \
    | while IFS= read -r spec; do [[ -n "$spec" ]] && printf '%s\t%s\n' "$f" "$spec"; done >> "$RAW"
  # bare side-effect import: import '...'
  printf '%s\n' "$src" | "$RG" -oN "^\s*import\s+['\"][^'\"]+['\"]" 2>/dev/null | sed -E "s/^[[:space:]]*import[[:space:]]+['\"]//; s/['\"]$//" \
    | while IFS= read -r spec; do [[ -n "$spec" ]] && printf '%s\t%s\n' "$f" "$spec"; done >> "$RAW"
  # require('...')
  printf '%s\n' "$src" | "$RG" -oN "require\(\s*['\"][^'\"]+['\"]" 2>/dev/null | sed -E "s/^require\([[:space:]]*['\"]//; s/['\"]$//" \
    | while IFS= read -r spec; do [[ -n "$spec" ]] && printf '%s\t%s\n' "$f" "$spec"; done >> "$RAW"
}

scan_py() {
  local f="$1" src
  src="$(strip_line_comments "$f" '#')"
  # from a.b import x
  printf '%s\n' "$src" | "$RG" -oN "^\s*from\s+[\w.]+\s+import" 2>/dev/null | sed -E "s/^[[:space:]]*from[[:space:]]+//; s/[[:space:]]+import$//" \
    | while IFS= read -r spec; do [[ -n "$spec" ]] && printf '%s\t%s\n' "$f" "${spec//./\/}"; done >> "$RAW"
  # import a.b (module-only form)
  printf '%s\n' "$src" | "$RG" -oN "^\s*import\s+[\w.]+\s*$" 2>/dev/null | sed -E "s/^[[:space:]]*import[[:space:]]+//; s/[[:space:]]+$//" \
    | while IFS= read -r spec; do [[ -n "$spec" ]] && printf '%s\t%s\n' "$f" "${spec//./\/}"; done >> "$RAW"
}

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    *.py) scan_py "$f" ;;
    *)    scan_js "$f" ;;
  esac
done < "$FILES_LIST"

# ---------------------------------------------------------------------------
# 4. Resolve each raw specifier to a file id in FILES_LIST; drop unresolved.
normalize_path() {
  local path="$1" IFS='/' part parts out=()
  read -ra parts <<< "$path"
  for part in "${parts[@]}"; do
    case "$part" in
      ""|".") continue ;;
      "..") [[ ${#out[@]} -gt 0 ]] && unset 'out[${#out[@]}-1]' ;;
      *) out+=("$part") ;;
    esac
  done
  local IFS='/'
  printf '%s' "${out[*]}"
}

resolve_specifier() {
  local from="$1" spec="$2" base="" fromdir candidate suffix
  fromdir="$(dirname "$from")"

  case "$spec" in
    ./*|../*)
      base="$(normalize_path "$fromdir/$spec")"
      ;;
    /*)
      base="$(normalize_path "${spec#/}")"
      ;;
    *)
      # bare specifier: only resolvable via a configured path alias.
      while IFS=$'\t' read -r prefix repl; do
        [[ -z "$prefix" ]] && continue
        case "$spec" in
          "$prefix"*)
            base="$(normalize_path "${repl}${spec#"$prefix"}")"
            break
            ;;
        esac
      done < "$ALIASES"
      ;;
  esac

  [[ -z "$base" ]] && return 1

  for suffix in "" ".ts" ".tsx" ".js" ".jsx" ".mjs" ".cjs" ".py" \
                "/index.ts" "/index.tsx" "/index.js" "/index.jsx" "/__init__.py"; do
    candidate="${base}${suffix}"
    if grep -qxF "$candidate" "$FILES_LIST"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

: > "$EDGES"
if [[ -s "$RAW" ]]; then
  while IFS=$'\t' read -r from spec; do
    [[ -z "$from" || -z "$spec" ]] && continue
    if to="$(resolve_specifier "$from" "$spec")"; then
      [[ "$from" == "$to" ]] && continue
      printf '%s\t%s\timports\n' "$from" "$to" >> "$EDGES"
    fi
  done < "$RAW"
fi

# De-duplicate edges, aggregating a weight = number of raw specifier lines
# between the same (from,to) pair.
DEDUPED_EDGES="$WORK/edges-deduped.tsv"
if [[ -s "$EDGES" ]]; then
  sort "$EDGES" | uniq -c | awk -F'\t' '{
    split($1, w, " "); weight=w[1]; sub(/^[ \t]*[0-9]+[ \t]+/, "", $0);
    print $0 "\t" weight
  }' > "$DEDUPED_EDGES"
else
  : > "$DEDUPED_EDGES"
fi

# ---------------------------------------------------------------------------
# 5. Assemble JSON via jq: nodes = every scanned file (+ fan_in/fan_out from
#    distinct edges), edges = deduped (from,to,type,weight).
jq -n \
  --arg schema_version "1" \
  --arg generated_at "$GENERATED_AT" \
  --arg git_head "$GIT_HEAD" \
  --arg backend "grep" \
  --rawfile files_raw "$FILES_LIST" \
  --rawfile edges_raw "$DEDUPED_EDGES" \
  '
  ($files_raw | split("\n") | map(select(length > 0))) as $files |
  ($edges_raw | split("\n") | map(select(length > 0) | split("\t") |
    {from: .[0], to: .[1], type: .[2], weight: (.[3] | tonumber)})) as $edges |
  ($edges | group_by(.to) | map({key: .[0].to, value: (map(.from) | unique | length)}) | from_entries) as $fan_in |
  ($edges | group_by(.from) | map({key: .[0].from, value: (map(.to) | unique | length)}) | from_entries) as $fan_out |
  {
    schema_version: ($schema_version | tonumber),
    generated_at: $generated_at,
    git_head: $git_head,
    backend: $backend,
    backend_version: null,
    nodes: [ $files[] | {
      id: .,
      label: (split("/") | last),
      kind: "file",
      fan_in: ($fan_in[.] // 0),
      fan_out: ($fan_out[.] // 0)
    } ],
    edges: $edges
  }
  ' > "$OUT"

echo "repo-map: wrote $OUT ($(jq '.nodes | length' "$OUT") nodes, $(jq '.edges | length' "$OUT") edges)" >&2
