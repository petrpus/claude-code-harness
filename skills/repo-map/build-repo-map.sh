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

# --- Canaries -------------------------------------------------------------
# Guarding each way a tool can break, one at a time, is a losing game: this
# script has already shipped three separate fixes for "dependency broken ->
# plausible but edgeless map at exit 0" (a PCRE2-less ripgrep, a missing
# scanner, a scanner that exits non-zero), and each fix left the next variant
# open. A tool that *succeeds and prints nothing* defeats all of them.
#
# So instead of predicting failure modes, run the real thing on a known input
# and check the known answer. Any breakage — absent, failing, silent, wrong
# version, wrong locale — produces the wrong answer and dies loudly here,
# rather than a map that is confidently wrong.
canary_fail() {
  echo "repo-map: self-check failed — $1" >&2
  echo "repo-map: the toolchain is not producing correct output; refusing to write a map" >&2
  exit 1
}

if [[ "$(jq -n --arg x 1 '[{key:"a",value:($x|tonumber)}] | from_entries | .a' 2>/dev/null)" != "1" ]]; then
  canary_fail "jq did not evaluate a known expression correctly"
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
    git -C "$ROOT" status --porcelain 2>/dev/null | grep -vE '[[:space:]]tmp/(repo-map\.json)?$'
    git -C "$ROOT" diff HEAD -- . ':(exclude)tmp/repo-map.json' 2>/dev/null
  } | cksum 2>/dev/null | tr -d ' \n'
}
WORKTREE_SIG="$(worktree_sig)"

# Provenance can legitimately degrade — outside a git repo there is no HEAD to
# record — but it must never degrade *quietly*: an empty git_head switches
# staleness checking off in query.sh, and an empty signature switches off
# dirty-tree detection. Both mean the map silently stops refreshing, which is
# indistinguishable from a map that is simply always right. Say it out loud.
[[ -z "$GIT_HEAD" ]] && \
  echo "repo-map: no git HEAD available — staleness tracking is disabled for this map" >&2
[[ -z "$WORKTREE_SIG" ]] && \
  echo "repo-map: could not fingerprint the working tree — uncommitted edits will not trigger a rebuild" >&2

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

# A `find` (or `sort`, or `grep`) that succeeds while producing nothing looks
# exactly like an empty repo, and the canaries above can't see it — they test
# the scanners, not the enumeration. git knows the answer independently, so ask
# it: an empty file list in a repo whose index holds source files is a broken
# toolchain, not an empty tree. Skipped outside a git repo, where there is no
# second opinion to be had.
if [[ ! -s "$FILES_LIST" && -n "$GIT_HEAD" ]]; then
  TRACKED_SRC="$(git -C "$ROOT" ls-files -- \
    '*.js' '*.jsx' '*.ts' '*.tsx' '*.mjs' '*.cjs' '*.py' 2>/dev/null | head -1)"
  [[ -n "$TRACKED_SRC" ]] && canary_fail "enumeration found no source files, but git tracks some (e.g. $TRACKED_SRC)"
fi

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
function firstquote(s,   i, best) {
  best = 0
  i = index(s, "\""); if (i > 0 && (best == 0 || i < best)) best = i
  i = index(s, "'");  if (i > 0 && (best == 0 || i < best)) best = i
  i = index(s, "`");  if (i > 0 && (best == 0 || i < best)) best = i
  return best
}
# Index of the quote closing the literal that opens at `start`; end of line if
# it never closes (a template literal spanning lines, say).
function strend(s, start,   q, i, c, n) {
  q = substr(s, start, 1)
  i = start + 1
  n = length(s)
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\\") { i += 2; continue }
    if (c == q) return i
    i++
  }
  return n
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
    # A comment marker inside a string literal is text, not a comment. Without
    # this, `const u = "http://x"; import z from "./y"` loses the import: the
    # // in the URL truncates the line and takes the real import with it.
    q = firstquote(line)
    if (q > 0 && (b == 0 || q < b) && (l == 0 || q < l)) {
      e = strend(line, q)
      out = out substr(line, 1, e)
      line = substr(line, e + 1)
      continue
    }
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
  # The imported names matter, not just the module: in `from . import sibling`
  # and `from pkg.sub import helper`, the name IS the module being depended on.
  # Dropping it attributes the edge to the package's __init__.py and leaves the
  # real file with fan_in 0 — looking dead while being imported.
  if (match(line, "^[ \t]*from[ \t]+[.A-Za-z0-9_]+[ \t]+import[ \t]+")) {
    m = substr(line, RSTART, RLENGTH)
    names = substr(line, RSTART + RLENGTH)
    sub("^[ \t]*from[ \t]+", "", m)
    sub("[ \t]+import[ \t]+$", "", m)
    gsub(/[ \t]+as[ \t]+[A-Za-z0-9_]+/, "", names)
    gsub(/[()\\]/, "", names)
    gsub(/[ \t]/, "", names)
    if (m != "") print FILENAME "\t" m "\t" names
  } else if (match(line, "^[ \t]*import[ \t]+[.A-Za-z0-9_]+[ \t]*$")) {
    m = substr(line, RSTART, RLENGTH)
    sub("^[ \t]*import[ \t]+", "", m)
    sub("[ \t]*$", "", m)
    if (m != "") print FILENAME "\t" m "\t"
  }
}
AWKPY

# Run both scanners on a known input and check the known answer — see the
# canary rationale near the top.
CANARY_DIR="$WORK/canary"
mkdir -p "$CANARY_DIR"
printf "/* x */ import a from './x.js'; // note\n" > "$CANARY_DIR/c.js"
printf "from .b import c\n" > "$CANARY_DIR/c.py"
CANARY_JS="$("$AWK" -f "$WORK/scan-js.awk" "$CANARY_DIR/c.js" 2>/dev/null)"
[[ "$CANARY_JS" == "$CANARY_DIR/c.js	./x.js" ]] \
  || canary_fail "the JS scanner returned '$CANARY_JS' for a known import"
CANARY_PY="$("$AWK" -f "$WORK/scan-py.awk" "$CANARY_DIR/c.py" 2>/dev/null)"
[[ "$CANARY_PY" == "$CANARY_DIR/c.py	.b	c" ]] \
  || canary_fail "the Python scanner returned '$CANARY_PY' for a known import"

grep -E '\.py$'  "$FILES_LIST" > "$PY_LIST" 2>/dev/null || : > "$PY_LIST"
grep -vE '\.py$' "$FILES_LIST" > "$JS_LIST" 2>/dev/null || : > "$JS_LIST"

# Batch so the argument list can't overflow on a large repo, and so a 10k-file
# tree costs ~20 awk processes rather than ~60,000.
# Existing-but-failing is a different failure from missing, and it lands in the
# same place: a map with every node and no edges, written at exit 0. Check the
# status of every awk run and surface what it said.
AWK_ERR="$WORK/awk-stderr.log"
: > "$AWK_ERR"

run_awk() { # out-file prog files...
  local out="$1" prog="$2"; shift 2
  if ! "$AWK" -f "$prog" "$@" >> "$out" 2>>"$AWK_ERR"; then
    echo "repo-map: '$AWK' failed while scanning — refusing to write a map with no edges" >&2
    [[ -s "$AWK_ERR" ]] && head -3 "$AWK_ERR" >&2
    exit 1
  fi
}

scan_batched() { # list-file awk-program out-file
  local list="$1" prog="$2" out="$3"
  local -a batch=()
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    batch+=("$f")
    if [[ "${#batch[@]}" -ge 500 ]]; then
      run_awk "$out" "$prog" "${batch[@]}"
      batch=()
    fi
  done < "$list"
  [[ "${#batch[@]}" -gt 0 ]] && run_awk "$out" "$prog" "${batch[@]}"
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
function depthof(p,   n, parts) {
  if (p == "" || p == ".") return 0
  return split(p, parts, "/")
}
# Emits every edge this import implies. An imported name that is itself a module
# wins over the package it lives in; when no name resolves (the names are
# ordinary symbols defined in __init__.py, or it's a plain `import a.b`), the
# module itself is the dependency.
function emit_py(from, mod, names,   level, base, i, k, n, arr, cb, ncb, cands, got, found) {
  level = 0
  while (substr(mod, 1, 1) == ".") { level++; mod = substr(mod, 2) }
  gsub(/\./, "/", mod)
  ncb = 0
  if (level > 0) {
    base = dirof(from)
    # `from ..x` in a file one directory deep can't resolve — Python wouldn't
    # run it either. Don't clamp at the root and match something unrelated.
    if (level - 1 > depthof(base) - (base == "." ? 0 : 1)) return
    for (i = 1; i < level; i++) base = dirof(base)
    cands[++ncb] = normalize(base (mod == "" ? "" : "/" mod))
  } else {
    cands[++ncb] = normalize(mod)
    base = from
    if (index(base, "/") > 0) { sub(/\/.*$/, "", base); cands[++ncb] = normalize(base "/" mod) }
  }

  for (k = 1; k <= ncb; k++) {
    cb = cands[k]
    if (cb == "") continue
    found = 0
    if (names != "") {
      n = split(names, arr, ",")
      for (i = 1; i <= n; i++) {
        if (arr[i] == "" || arr[i] == "*") continue
        got = hit(normalize(cb "/" arr[i]), ".py|/__init__.py")
        if (got != "" && got != from) { print from "\t" got "\timports"; found = 1 }
      }
    }
    if (found) return
    got = hit(cb, ".py|/__init__.py")
    if (got != "" && got != from) { print from "\t" got "\timports"; return }
  }
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
  if (FILENAME == PY_F) {
    # python rows carry a third field: the imported names
    t = index(spec, "\t")
    if (t > 0) { names = substr(spec, t + 1); spec = substr(spec, 1, t - 1) } else names = ""
    if (spec != "") emit_py(from, spec, names)
    next
  }
  to = resolve_js(from, spec)
  if (to != "" && to != from) print from "\t" to "\timports"
}
AWKRES

# Same treatment for the resolver: a known file list plus a known specifier has
# exactly one right answer.
printf 'src/x.js\n' > "$CANARY_DIR/files.txt"
: > "$CANARY_DIR/aliases.tsv"
printf 'src/a.js\t./x.js\n' > "$CANARY_DIR/raw.tsv"
CANARY_RES="$("$AWK" -v FILES_F="$CANARY_DIR/files.txt" -v ALIAS_F="$CANARY_DIR/aliases.tsv" \
  -v PY_F="" -f "$WORK/resolve.awk" \
  "$CANARY_DIR/files.txt" "$CANARY_DIR/aliases.tsv" "$CANARY_DIR/raw.tsv" 2>/dev/null)"
[[ "$CANARY_RES" == "src/a.js	src/x.js	imports" ]] \
  || canary_fail "the resolver returned '$CANARY_RES' for a known relative import"

: > "$EDGES"
resolve_awk() { # py-raw-file raw-file
  if ! "$AWK" -v FILES_F="$FILES_LIST" -v ALIAS_F="$ALIASES" -v PY_F="$1" \
       -f "$WORK/resolve.awk" "$FILES_LIST" "$ALIASES" "$2" >> "$EDGES" 2>>"$AWK_ERR"; then
    echo "repo-map: '$AWK' failed while resolving — refusing to write a map with no edges" >&2
    [[ -s "$AWK_ERR" ]] && head -3 "$AWK_ERR" >&2
    exit 1
  fi
}
[[ -s "$RAW" ]]    && resolve_awk ""         "$RAW"
[[ -s "$RAW_PY" ]] && resolve_awk "$RAW_PY"  "$RAW_PY"

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
