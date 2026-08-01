#!/usr/bin/env bash
# skills/repo-map/build-repo-map.sh — grep-backend generator for tmp/repo-map.json.
#
# Scans JS/TS import/require edges (relative, root-absolute, tsconfig/jsconfig
# path aliases) and Python imports (absolute from the repo root or the importing
# file's top-level directory, and explicit relative imports where leading dots
# are level markers), drops unresolved bare specifiers (external packages,
# stdlib), and writes tmp/repo-map.json per Schema v1 (see
# docs/adr/0004-graphify-as-optional-repo-map-backend.md).
#
# Usage: build-repo-map.sh [root-dir]
#   root-dir defaults to the current git toplevel, or cwd outside a git repo.
#
# Requires: bash, jq, git, awk. Fails with a clear message if jq or awk is
# missing rather than emitting a malformed or edgeless map. Degrades gracefully
# outside a git repo (empty git_head, not a crash).

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "repo-map: jq is required to build tmp/repo-map.json" >&2
  exit 1
fi

# awk does the scanning and the resolution, and is as load-bearing as jq:
# without it every scan matches nothing and the map comes out with all its nodes
# and none of its edges — confidently, undetectably wrong. Fail loudly instead.
# REPO_MAP_AWK exists so the guard itself is testable (and lets a caller point
# at a specific awk).
AWK="${REPO_MAP_AWK:-awk}"
if ! command -v "$AWK" >/dev/null 2>&1; then
  echo "repo-map: awk ('$AWK') is required to build tmp/repo-map.json" >&2
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

# git_head alone can't see an uncommitted edit, and an uncommitted edit is the
# state an agent spends most of a task in — so a map keyed only on HEAD goes
# quietly wrong exactly when it is most used. This signature covers tracked
# modifications (by content, so re-editing the same file still registers) and
# untracked paths. The map itself is excluded: a consumer project that doesn't
# gitignore tmp/ would otherwise invalidate the map by writing it, and every
# query would regenerate forever.
worktree_sig() {
  {
    git -C "$ROOT" status --porcelain 2>/dev/null | grep -v 'tmp/repo-map\.json'
    git -C "$ROOT" diff HEAD 2>/dev/null
  } | cksum 2>/dev/null | tr -d ' \n'
}
WORKTREE_SIG="$(worktree_sig)"

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
    --arg worktree_sig "$WORKTREE_SIG" \
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
      worktree_sig: $worktree_sig,
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
JS_LIST="$WORK/files-js.txt"
PY_LIST="$WORK/files-py.txt"
ALIASES="$WORK/aliases.tsv"
RAW="$WORK/raw-edges.tsv"
RAW_PY="$WORK/raw-edges-py.tsv"
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
: > "$RAW_PY"

# A specifier named in a comment — `// copied from './legacy/old'`, or a
# commented-out import inside a JSDoc block — is prose, not a dependency, but it
# reads exactly like one to a regex. Left in, it invents an edge and inflates the
# target's fan_in, the very metric `hotspots` ranks on.
#
# Both comment forms are stripped in ONE pass, because two passes break on input
# each would mangle for the other: stripping `//` first turns `/* // */` into an
# unterminated `/*` that swallows the rest of the file, and stripping `/*` first
# lets `// /* note` open a block that was only ever a line comment. So walk each
# line and honour whichever marker opens first.
#
# A specifier inside a *string literal* still slips through, as does one in a
# Python docstring (only `#` is stripped there — a triple-quote state machine
# risks swallowing real imports, which is worse than the phantom it prevents).
# That is the accuracy ceiling of a regex backend, and precisely why the
# Graphify backend exists (see SKILL.md).
# Comment stripping and specifier extraction happen in ONE awk program, run over
# a batch of files at a time. The earlier shape — three `rg` calls plus three
# `sed` calls per file, then a `grep` against the file list per candidate suffix
# per specifier — was subprocess-bound and took over three minutes on a
# 6,000-file tree, which made the "regeneration is cheap" premise the staleness
# policy rests on simply false.
cat > "$WORK/scan-js.awk" <<'AWKJS'
function quoted(s,   i, j, q) {
  i = index(s, "\"")
  j = index(s, "'")
  if (i == 0 && j == 0) return ""
  if (i == 0 || (j > 0 && j < i)) { q = "'"; i = j } else { q = "\"" }
  s = substr(s, i + 1)
  j = index(s, q)
  if (j == 0) return ""
  return substr(s, 1, j - 1)
}
function harvest(s, pat,   rest, spec) {
  rest = s
  while (match(rest, pat)) {
    spec = quoted(substr(rest, RSTART, RLENGTH))
    if (spec != "") print FILENAME "\t" spec
    rest = substr(rest, RSTART + RLENGTH)
  }
}
FNR == 1 { inblock = 0 }
{
  line = $0; out = ""
  while (length(line) > 0) {
    if (inblock) {
      p = index(line, "*/")
      if (p == 0) { line = ""; break }
      line = substr(line, p + 2); inblock = 0
      continue
    }
    b = index(line, "/*")
    l = index(line, "//")
    if (b == 0 && l == 0) { out = out line; break }
    if (l > 0 && (b == 0 || l < b)) { out = out substr(line, 1, l - 1); break }
    out = out substr(line, 1, b - 1)
    line = substr(line, b + 2); inblock = 1
  }
  harvest(out, "from[ \t]+[\"'][^\"']+[\"']")
  harvest(out, "require\\([ \t]*[\"'][^\"']+[\"']")
  if (match(out, "^[ \t]*import[ \t]+[\"'][^\"']+[\"']")) {
    spec = quoted(substr(out, RSTART, RLENGTH))
    if (spec != "") print FILENAME "\t" spec
  }
}
AWKJS

cat > "$WORK/scan-py.awk" <<'AWKPY'
{
  line = $0
  p = index(line, "#")
  if (p > 0) line = substr(line, 1, p - 1)
  if (match(line, "^[ \t]*from[ \t]+[.A-Za-z0-9_]+[ \t]+import")) {
    m = substr(line, RSTART, RLENGTH)
    sub("^[ \t]*from[ \t]+", "", m)
    sub("[ \t]+import$", "", m)
    if (m != "") print FILENAME "\t" m
  } else if (match(line, "^[ \t]*import[ \t]+[.A-Za-z0-9_]+[ \t]*$")) {
    m = substr(line, RSTART, RLENGTH)
    sub("^[ \t]*import[ \t]+", "", m)
    sub("[ \t]*$", "", m)
    if (m != "") print FILENAME "\t" m
  }
}
AWKPY

grep -E '\.py$'  "$FILES_LIST" > "$PY_LIST" 2>/dev/null || : > "$PY_LIST"
grep -vE '\.py$' "$FILES_LIST" > "$JS_LIST" 2>/dev/null || : > "$JS_LIST"

# Batch so the argument list can't overflow on a large repo, and so a 10k-file
# tree costs ~20 awk processes rather than ~60,000.
scan_batched() { # list-file awk-program out-file
  local list="$1" prog="$2" out="$3"
  local -a batch=()
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    batch+=("$f")
    if [[ "${#batch[@]}" -ge 500 ]]; then
      "$AWK" -f "$prog" "${batch[@]}" >> "$out" 2>/dev/null
      batch=()
    fi
  done < "$list"
  [[ "${#batch[@]}" -gt 0 ]] && "$AWK" -f "$prog" "${batch[@]}" >> "$out" 2>/dev/null
  return 0
}

scan_batched "$JS_LIST" "$WORK/scan-js.awk" "$RAW"
scan_batched "$PY_LIST" "$WORK/scan-py.awk" "$RAW_PY"

# ---------------------------------------------------------------------------
# 4. Resolve each raw specifier to a file id in FILES_LIST; drop unresolved.
#
# Both resolvers load the file list into an awk array — associative by
# definition and portable back to POSIX awk, unlike a bash 4 declare -A — so a
# candidate lookup is a hash hit rather than a forked grep over the whole list.
cat > "$WORK/resolve.awk" <<'AWKRES'
function normalize(p,   n, i, parts, out, no, res) {
  n = split(p, parts, "/")
  no = 0
  for (i = 1; i <= n; i++) {
    if (parts[i] == "" || parts[i] == ".") continue
    if (parts[i] == "..") { if (no > 0) no--; continue }
    out[++no] = parts[i]
  }
  res = ""
  for (i = 1; i <= no; i++) res = (res == "" ? out[i] : res "/" out[i])
  return res
}
function dirof(p) {
  if (index(p, "/") == 0) return "."
  sub(/\/[^\/]*$/, "", p)
  return p
}
function hit(base, sfxlist,   n, i, s, cand) {
  if (base == "") return ""
  n = split(sfxlist, s, "|")
  for (i = 1; i <= n; i++) {
    cand = base (s[i] == "@" ? "" : s[i])
    if (cand in files) return cand
  }
  return ""
}
# JS/TS: relative, root-absolute, or bare-via-tsconfig-alias.
function resolve_js(from, spec,   base, i) {
  base = ""
  if (substr(spec, 1, 2) == "./" || substr(spec, 1, 3) == "../")
    base = normalize(dirof(from) "/" spec)
  else if (substr(spec, 1, 1) == "/")
    base = normalize(substr(spec, 2))
  else {
    for (i = 1; i <= nalias; i++) {
      if (substr(spec, 1, length(apfx[i])) == apfx[i]) {
        base = normalize(arep[i] substr(spec, length(apfx[i]) + 1))
        break
      }
    }
  }
  return hit(base, "@|.ts|.tsx|.js|.jsx|.mjs|.cjs|/index.ts|/index.tsx|/index.js|/index.jsx")
}
# Python: leading dots are *level* markers, not path separators. `from .b import
# x` is sibling-relative; `from ..pkg.c import y` walks one package up. An
# absolute module is tried from the repo root and from the importing file's
# top-level directory, which is what a `src/`-rooted layout needs. Anything that
# resolves to neither is stdlib or site-packages and is dropped, exactly as an
# unresolved bare JS specifier is.
function resolve_py(from, mod,   level, base, i, top, got) {
  level = 0
  while (substr(mod, 1, 1) == ".") { level++; mod = substr(mod, 2) }
  gsub(/\./, "/", mod)
  if (level > 0) {
    base = dirof(from)
    for (i = 1; i < level; i++) base = dirof(base)
    return hit(normalize(base (mod == "" ? "" : "/" mod)), ".py|/__init__.py")
  }
  got = hit(normalize(mod), ".py|/__init__.py")
  if (got != "") return got
  top = from
  if (index(top, "/") == 0) return ""
  sub(/\/.*$/, "", top)
  return hit(normalize(top "/" mod), ".py|/__init__.py")
}
FILENAME == FILES_F { files[$0] = 1; next }
FILENAME == ALIAS_F {
  t = index($0, "\t")
  if (t > 0) { nalias++; apfx[nalias] = substr($0, 1, t - 1); arep[nalias] = substr($0, t + 1) }
  next
}
{
  t = index($0, "\t")
  if (t == 0) next
  from = substr($0, 1, t - 1)
  spec = substr($0, t + 1)
  if (from == "" || spec == "") next
  to = (FILENAME == PY_F) ? resolve_py(from, spec) : resolve_js(from, spec)
  if (to != "" && to != from) print from "\t" to "\timports"
}
AWKRES

: > "$EDGES"
[[ -s "$RAW" ]] && "$AWK" -v FILES_F="$FILES_LIST" -v ALIAS_F="$ALIASES" -v PY_F="" -f "$WORK/resolve.awk" \
  "$FILES_LIST" "$ALIASES" "$RAW" >> "$EDGES" 2>/dev/null
[[ -s "$RAW_PY" ]] && "$AWK" -v FILES_F="$FILES_LIST" -v ALIAS_F="$ALIASES" -v PY_F="$RAW_PY" -f "$WORK/resolve.awk" \
  "$FILES_LIST" "$ALIASES" "$RAW_PY" >> "$EDGES" 2>/dev/null

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
  --arg worktree_sig "$WORKTREE_SIG" \
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
    worktree_sig: $worktree_sig,
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
