#!/usr/bin/env bash
# scripts/test-repo-map.sh — fixture-based contract tests for skills/repo-map/.
#
# Builds a throwaway fixture tree under a temp dir (never against this repo,
# whose file set changes), runs the generator against it, and asserts the
# Schema v1 contract. Invoked from scripts/verify.sh's "repo-map contract"
# section. Cleaned up on exit.

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1

FAIL=0
note() { echo "  ✗ $*"; FAIL=1; }
ok()   { echo "  ✓ $*"; }

FIXTURE="$(mktemp -d)"
COMMENT_FIXTURE="$(mktemp -d)"
cleanup() { rm -rf "$FIXTURE" "$COMMENT_FIXTURE"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Build the fixture tree.
#
#   src/main.js   -> src/lib/foo.js (relative), 'lodash' (bare, dropped)
#   src/lib/foo.js -> src/lib/util.js (relative)
#   src/other.js  -> src/lib/util.js (via tsconfig alias '@/lib/util')
#   src/third.js  -> src/lib/util.js (relative)
#   src/lib/util.js -> (nothing)      -- hotspot: fan_in == 3
#   src/dead.js   -> (nothing)        -- dead file: fan_in == 0, fan_out == 0
#   node_modules/lodash/index.js      -- must not become a node
mkdir -p "$FIXTURE/src/lib" "$FIXTURE/node_modules/lodash"
git -C "$FIXTURE" init -q

cat > "$FIXTURE/tsconfig.json" <<'EOF'
{ "compilerOptions": { "paths": { "@/*": ["src/*"] } } }
EOF

cat > "$FIXTURE/src/main.js" <<'EOF'
import foo from './lib/foo.js';
import _ from 'lodash';
EOF

cat > "$FIXTURE/src/lib/foo.js" <<'EOF'
import util from './util.js';
EOF

cat > "$FIXTURE/src/other.js" <<'EOF'
import util from '@/lib/util';
EOF

cat > "$FIXTURE/src/third.js" <<'EOF'
import util from './lib/util.js';
EOF

# Prose that reads like an import: the comment names util.js and the string
# literal names a real file, but neither is a dependency. Both must stay out of
# the graph — a phantom edge inflates the target's fan_in, which is what
# `hotspots` ranks on.
cat > "$FIXTURE/src/commented.js" <<'EOF'
// this helper was moved out of './lib/util.js'
import foo from './lib/foo.js';
EOF

: > "$FIXTURE/src/lib/util.js"
: > "$FIXTURE/src/dead.js"
cat > "$FIXTURE/node_modules/lodash/index.js" <<'EOF'
module.exports = {};
EOF

git -C "$FIXTURE" add -A >/dev/null 2>&1
git -C "$FIXTURE" -c user.email=t@t.est -c user.name=test commit -q -m fixture

# ---------------------------------------------------------------------------
GEN="skills/repo-map/build-repo-map.sh"
if [[ ! -f "$GEN" ]]; then
  note "$GEN does not exist yet"
  echo
  echo "test-repo-map: $FAIL failure(s)"
  exit 1
fi

GEN_ERR="$(mktemp)"
bash "$GEN" "$FIXTURE" >"$GEN_ERR" 2>&1
GEN_EXIT=$?
MAP="$FIXTURE/tmp/repo-map.json"

[[ "$GEN_EXIT" -eq 0 ]] && ok "generator exits 0" || note "generator exited $GEN_EXIT: $(cat "$GEN_ERR")"

if [[ ! -f "$MAP" ]]; then
  note "$MAP was not written"
  echo
  echo "test-repo-map: $FAIL failure(s)"
  rm -f "$GEN_ERR"
  exit 1
fi
rm -f "$GEN_ERR"

jq empty "$MAP" >/dev/null 2>&1 && ok "valid JSON" || note "invalid JSON"

for key in schema_version generated_at git_head backend backend_version nodes edges; do
  jq -e "has(\"$key\")" "$MAP" >/dev/null 2>&1 && ok "provenance key '$key' present" || note "provenance key '$key' missing"
done

[[ "$(jq -r '.schema_version' "$MAP" 2>/dev/null)" == "1" ]] && ok "schema_version == 1" || note "schema_version != 1"
[[ "$(jq -r '.backend' "$MAP" 2>/dev/null)" == "grep" ]] && ok "backend == grep" || note "backend != grep"

FIXTURE_HEAD="$(git -C "$FIXTURE" rev-parse --short HEAD)"
[[ "$(jq -r '.git_head' "$MAP" 2>/dev/null)" == "$FIXTURE_HEAD" ]] \
  && ok "git_head matches fixture HEAD" || note "git_head mismatch (want $FIXTURE_HEAD, got $(jq -r '.git_head' "$MAP" 2>/dev/null))"

BAD_NODES="$(jq '[.nodes[] | select((has("id") and has("label") and has("kind") and has("fan_in") and has("fan_out"))|not)] | length' "$MAP" 2>/dev/null)"
[[ "$BAD_NODES" == "0" ]] && ok "every node carries id/label/kind/fan_in/fan_out" || note "$BAD_NODES node(s) missing required fields"

BAD_EDGES="$(jq '[.edges[] | select((has("from") and has("to") and has("type"))|not)] | length' "$MAP" 2>/dev/null)"
[[ "$BAD_EDGES" == "0" ]] && ok "every edge carries from/to/type" || note "$BAD_EDGES edge(s) missing required fields"

DANGLING="$(jq '([.nodes[].id]) as $ids | [.edges[] | select(([.from,.to] - $ids) | length > 0)] | length' "$MAP" 2>/dev/null)"
[[ "$DANGLING" == "0" ]] && ok "all edge endpoints resolve to node ids" || note "$DANGLING edge(s) reference an unknown node id"

if jq -e '[.nodes[].id] | any(test("node_modules"))' "$MAP" >/dev/null 2>&1; then
  note "a node_modules path leaked into nodes"
else
  ok "node_modules excluded from nodes"
fi

if jq -e '[.edges[] | select(.to | test("lodash"))] | length == 0' "$MAP" >/dev/null 2>&1; then
  ok "bare 'lodash' import dropped (no edge)"
else
  note "an edge targeting 'lodash' survived — bare specifiers must be dropped"
fi

fan_in_of()  { jq -r --arg id "$1" '.nodes[] | select(.id==$id) | .fan_in'  "$MAP" 2>/dev/null; }
fan_out_of() { jq -r --arg id "$1" '.nodes[] | select(.id==$id) | .fan_out' "$MAP" 2>/dev/null; }

check_fan() {
  local id="$1" which="$2" want="$3" got
  if [[ "$which" == "fan_in" ]]; then got="$(fan_in_of "$id")"; else got="$(fan_out_of "$id")"; fi
  [[ "$got" == "$want" ]] && ok "$id $which == $want" || note "$id $which: want $want, got $got"
}

check_fan "src/lib/util.js" fan_in  3   # hotspot
check_fan "src/lib/util.js" fan_out 0
check_fan "src/main.js"     fan_in  0   # entry point
check_fan "src/main.js"     fan_out 1   # lodash dropped
check_fan "src/other.js"    fan_in  0
check_fan "src/other.js"    fan_out 1   # alias import resolved
check_fan "src/dead.js"     fan_in  0   # dead file
check_fan "src/dead.js"     fan_out 0

ALIAS_TARGET="$(jq -r '.edges[] | select(.from=="src/other.js") | .to' "$MAP" 2>/dev/null)"
[[ "$ALIAS_TARGET" == "src/lib/util.js" ]] \
  && ok "alias import '@/lib/util' resolves to src/lib/util.js" \
  || note "alias import resolved to '$ALIAS_TARGET', expected src/lib/util.js"

# ---------------------------------------------------------------------------
# query.sh — the five queries, against the fixture built above.
QUERY="skills/repo-map/query.sh"
if [[ ! -f "$QUERY" ]]; then
  note "$QUERY does not exist yet"
else
  DEPS_OUT="$(REPO_MAP_ROOT="$FIXTURE" bash "$QUERY" deps src/lib/foo.js 2>/dev/null)"
  [[ "$DEPS_OUT" == "src/lib/util.js" ]] \
    && ok "query deps src/lib/foo.js == src/lib/util.js" \
    || note "query deps src/lib/foo.js: got '$DEPS_OUT'"

  RDEPS_OUT="$(REPO_MAP_ROOT="$FIXTURE" bash "$QUERY" rdeps src/lib/util.js 2>/dev/null | sort | tr '\n' ',')"
  [[ "$RDEPS_OUT" == "src/lib/foo.js,src/other.js,src/third.js," ]] \
    && ok "query rdeps src/lib/util.js == foo.js,other.js,third.js" \
    || note "query rdeps src/lib/util.js: got '$RDEPS_OUT'"

  HOTSPOT_TOP="$(REPO_MAP_ROOT="$FIXTURE" bash "$QUERY" hotspots 2>/dev/null | head -1 | cut -f1)"
  [[ "$HOTSPOT_TOP" == "src/lib/util.js" ]] \
    && ok "query hotspots top == src/lib/util.js" \
    || note "query hotspots top: got '$HOTSPOT_TOP'"

  ENTRY_OUT="$(REPO_MAP_ROOT="$FIXTURE" bash "$QUERY" entry-points 2>/dev/null)"
  if grep -qxF "src/dead.js" <<< "$ENTRY_OUT"; then
    ok "query entry-points includes src/dead.js"
  else
    note "query entry-points does not include src/dead.js (got: $ENTRY_OUT)"
  fi

  STATS_OUT="$(REPO_MAP_ROOT="$FIXTURE" bash "$QUERY" stats 2>/dev/null)"
  STATS_NODES="$(jq -r '.nodes' <<< "$STATS_OUT" 2>/dev/null)"
  STATS_EDGES="$(jq -r '.edges' <<< "$STATS_OUT" 2>/dev/null)"
  [[ "$STATS_NODES" == "7" ]] && ok "query stats nodes == 7" || note "query stats nodes: got '$STATS_NODES'"
  [[ "$STATS_EDGES" == "5" ]] && ok "query stats edges == 5" || note "query stats edges: got '$STATS_EDGES'"

  # The commented-out specifier must not have become an edge.
  COMMENTED_DEPS="$(REPO_MAP_ROOT="$FIXTURE" bash "$QUERY" deps src/commented.js 2>/dev/null | sort | tr '\n' ',')"
  [[ "$COMMENTED_DEPS" == "src/lib/foo.js," ]] \
    && ok "line-comment specifier ignored (deps == foo.js only)" \
    || note "line-comment specifier leaked into deps: got '$COMMENTED_DEPS'"

  bash "$QUERY" bogus-subcommand >/dev/null 2>&1
  [[ "$?" -ne 0 ]] && ok "query unknown subcommand exits non-zero" || note "query unknown subcommand exited 0"

  bash "$QUERY" deps >/dev/null 2>&1
  [[ "$?" -ne 0 ]] && ok "query deps with missing file arg exits non-zero" || note "query deps with missing file arg exited 0"

  # -------------------------------------------------------------------------
  # Staleness — provenance comparison + lazy regeneration at read time.
  jq '.git_head = "deadbeef"' "$MAP" > "$MAP.tmp" && mv "$MAP.tmp" "$MAP"
  REPO_MAP_ROOT="$FIXTURE" bash "$QUERY" stats >/dev/null 2>&1
  RESTAMPED_HEAD="$(jq -r '.git_head' "$MAP" 2>/dev/null)"
  [[ "$RESTAMPED_HEAD" == "$FIXTURE_HEAD" ]] \
    && ok "bogus git_head re-stamped to real HEAD on next query" \
    || note "git_head after stale query: got '$RESTAMPED_HEAD', want '$FIXTURE_HEAD'"

  jq '.schema_version = 0' "$MAP" > "$MAP.tmp" && mv "$MAP.tmp" "$MAP"
  REPO_MAP_ROOT="$FIXTURE" bash "$QUERY" stats >/dev/null 2>&1
  RESTAMPED_SCHEMA="$(jq -r '.schema_version' "$MAP" 2>/dev/null)"
  [[ "$RESTAMPED_SCHEMA" == "1" ]] \
    && ok "schema_version 0 regenerates to 1" \
    || note "schema_version after stale query: got '$RESTAMPED_SCHEMA'"

  rm -f "$MAP"
  DELETED_STATS_OUT="$(REPO_MAP_ROOT="$FIXTURE" bash "$QUERY" stats 2>/dev/null)"
  if [[ -f "$MAP" ]] && jq -e '.nodes' <<< "$DELETED_STATS_OUT" >/dev/null 2>&1; then
    ok "deleted map regenerates and still answers"
  else
    note "deleted map did not regenerate/answer correctly"
  fi
fi

# ---------------------------------------------------------------------------
# Graphify adapter — consume a valid graph.json, fall back loudly on a
# malformed one. Reuses the fixture tree above.
GJSON="$FIXTURE/graph.json"
cat > "$GJSON" <<EOF
{
  "git_head": "$FIXTURE_HEAD",
  "nodes": [
    {"id": "src/lib/util.js#funcA", "file": "src/lib/util.js", "kind": "function"},
    {"id": "src/lib/util.js#funcB", "file": "src/lib/util.js", "kind": "function"},
    {"id": "src/main.js#main", "file": "src/main.js", "kind": "function"}
  ],
  "edges": [
    {"from": "src/main.js#main", "to": "src/lib/util.js#funcA", "type": "calls"},
    {"from": "src/main.js#main", "to": "src/lib/util.js#funcB", "type": "calls"},
    {"from": "src/main.js#main", "to": "src/lib/util.js#funcA", "type": "imports"}
  ]
}
EOF

GJ_ERR="$(mktemp)"
bash "$GEN" "$FIXTURE" >"$GJ_ERR" 2>&1
GJ_EXIT=$?
[[ "$GJ_EXIT" -eq 0 ]] && ok "graphify: generator exits 0" || note "graphify: generator exited $GJ_EXIT: $(cat "$GJ_ERR")"
rm -f "$GJ_ERR"

[[ "$(jq -r '.backend' "$MAP" 2>/dev/null)" == "graphify" ]] \
  && ok "graphify: backend == graphify" \
  || note "graphify: backend != graphify (got $(jq -r '.backend' "$MAP" 2>/dev/null))"

GJ_NODE_IDS="$(jq -r '[.nodes[].id] | sort | join(",")' "$MAP" 2>/dev/null)"
[[ "$GJ_NODE_IDS" == "src/lib/util.js,src/main.js" ]] \
  && ok "graphify: sub-file nodes collapsed to containing-file ids" \
  || note "graphify: node ids: got '$GJ_NODE_IDS'"

GJ_WEIGHT="$(jq -r '.edges[] | select(.from=="src/main.js" and .to=="src/lib/util.js" and .type=="calls") | .weight' "$MAP" 2>/dev/null)"
[[ "$GJ_WEIGHT" == "2" ]] && ok "graphify: weight aggregated to 2" || note "graphify: weight: got '$GJ_WEIGHT'"

# Two relationship types between the same file pair stay two edges — but `deps`
# answers "which files", so it must still name the target once.
GJ_PAIR_EDGES="$(jq '[.edges[] | select(.from=="src/main.js" and .to=="src/lib/util.js")] | length' "$MAP" 2>/dev/null)"
[[ "$GJ_PAIR_EDGES" == "2" ]] \
  && ok "graphify: calls + imports kept as two typed edges" \
  || note "graphify: expected 2 typed edges for the pair, got '$GJ_PAIR_EDGES'"

GJ_DEPS="$(REPO_MAP_ROOT="$FIXTURE" bash "$QUERY" deps src/main.js 2>/dev/null | tr '\n' ',')"
[[ "$GJ_DEPS" == "src/lib/util.js," ]] \
  && ok "graphify: deps de-duplicates across edge types" \
  || note "graphify: deps returned '$GJ_DEPS' (expected the target once)"

GJ_RDEPS="$(REPO_MAP_ROOT="$FIXTURE" bash "$QUERY" rdeps src/lib/util.js 2>/dev/null | tr '\n' ',')"
[[ "$GJ_RDEPS" == "src/main.js," ]] \
  && ok "graphify: rdeps de-duplicates across edge types" \
  || note "graphify: rdeps returned '$GJ_RDEPS' (expected the source once)"

GJ_UTIL_FANIN="$(jq -r '.nodes[] | select(.id=="src/lib/util.js") | .fan_in' "$MAP" 2>/dev/null)"
[[ "$GJ_UTIL_FANIN" == "1" ]] && ok "graphify: src/lib/util.js fan_in == 1" || note "graphify: fan_in: got '$GJ_UTIL_FANIN'"

GJ_BAD_NODES="$(jq '[.nodes[] | select((has("id") and has("label") and has("kind") and has("fan_in") and has("fan_out"))|not)] | length' "$MAP" 2>/dev/null)"
[[ "$GJ_BAD_NODES" == "0" ]] && ok "graphify: nodes carry mandatory-minimum fields" || note "graphify: $GJ_BAD_NODES node(s) missing mandatory fields"

GJ_BAD_EDGES="$(jq '[.edges[] | select((has("from") and has("to") and has("type"))|not)] | length' "$MAP" 2>/dev/null)"
[[ "$GJ_BAD_EDGES" == "0" ]] && ok "graphify: edges carry mandatory-minimum fields" || note "graphify: $GJ_BAD_EDGES edge(s) missing mandatory fields"

# Corrupt graph.json in place -> must fall back to grep, warn, exit 0. The
# same fallback branch also covers the drift-past-tolerance case (charter),
# so its stderr advice string is asserted here rather than in a third fixture.
echo 'not valid json {{{' > "$GJSON"
GJ2_ERR="$(mktemp)"
bash "$GEN" "$FIXTURE" >/dev/null 2>"$GJ2_ERR"
GJ2_EXIT=$?
[[ "$GJ2_EXIT" -eq 0 ]] \
  && ok "graphify fallback: generator still exits 0 on malformed graph.json" \
  || note "graphify fallback: exited $GJ2_EXIT"
[[ "$(jq -r '.backend' "$MAP" 2>/dev/null)" == "grep" ]] \
  && ok "graphify fallback: backend reverts to grep" \
  || note "graphify fallback: backend is $(jq -r '.backend' "$MAP" 2>/dev/null)"
if grep -qi "graphify" "$GJ2_ERR"; then
  ok "graphify fallback: stderr names graphify / advises re-running it"
else
  note "graphify fallback: stderr did not mention graphify: $(cat "$GJ2_ERR")"
fi
rm -f "$GJ2_ERR" "$GJSON"

# ---------------------------------------------------------------------------
# Comment stripping, on its own fixture so the counts above stay readable.
# Every specifier here except real1/real2 sits in a comment and must NOT become
# an edge. The two "tricky" lines are the reason stripping happens in one pass:
# a `//` inside a block, and a `/*` inside a line comment that must not open a
# block and swallow the rest of the file.
mkdir -p "$COMMENT_FIXTURE/src/lib"
git -C "$COMMENT_FIXTURE" init -q
cat > "$COMMENT_FIXTURE/src/app.js" <<'EOF'
/*
 * Legacy: import gone from './lib/blockmulti.js';
 */
/* inline: import x from './lib/blockinline.js'; */
// line: import y from './lib/linec.js';
/* tricky: // import z from './lib/nested1.js'; */
// tricky2: /* import w from './lib/nested2.js';
import real1 from './lib/real1.js'; /* trailing: import q from './lib/trail.js'; */
/* opener */ import real2 from './lib/real2.js';
EOF
for n in blockmulti blockinline linec nested1 nested2 trail real1 real2; do
  echo "export const x = 1;" > "$COMMENT_FIXTURE/src/lib/$n.js"
done
# No Python case here: no Python specifier form currently resolves to an edge
# at all (see the "python imports never resolve" issue), so a `#`-stripping
# assertion would be untestable through the graph. Asserting it via edges would
# pass for the wrong reason.
git -C "$COMMENT_FIXTURE" add -A >/dev/null 2>&1
git -C "$COMMENT_FIXTURE" -c user.email=t@t.est -c user.name=test commit -q -m fixture

if bash "$GEN" "$COMMENT_FIXTURE" >/dev/null 2>&1; then
  C_TARGETS="$(jq -r '[.edges[] | select(.from=="src/app.js") | .to] | sort | join(",")' \
    "$COMMENT_FIXTURE/tmp/repo-map.json" 2>/dev/null)"
  [[ "$C_TARGETS" == "src/lib/real1.js,src/lib/real2.js" ]] \
    && ok "comments: only real imports survive block/line stripping" \
    || note "comments: expected real1+real2, got '$C_TARGETS'"

else
  note "comments: generator failed on the comment fixture"
fi

# ---------------------------------------------------------------------------
# query.sh's own graphify drift branch — the one piece of staleness logic that
# lives in query.sh rather than the generator, and the adapter tests above only
# ever call the generator directly.
DRIFTF="$(mktemp -d)"
mkdir -p "$DRIFTF/src"
git -C "$DRIFTF" init -q
printf "export const a = 1;\n" > "$DRIFTF/src/a.js"
printf "export const b = 1;\n" > "$DRIFTF/src/b.js"
git -C "$DRIFTF" add -A >/dev/null 2>&1
git -C "$DRIFTF" -c user.email=t@t.est -c user.name=test commit -q -m one
DRIFT_HEAD="$(git -C "$DRIFTF" rev-parse --short HEAD)"
cat > "$DRIFTF/graph.json" <<EOF
{
  "git_head": "$DRIFT_HEAD",
  "nodes": [{"id": "n1", "file": "src/a.js"}, {"id": "n2", "file": "src/b.js"}],
  "edges": [{"from": "n1", "to": "n2", "type": "imports"}]
}
EOF
bash "$GEN" "$DRIFTF" >/dev/null 2>&1
# Move HEAD on so the map is one commit behind, without touching graph.json.
printf "export const c = 1;\n" > "$DRIFTF/src/c.js"
git -C "$DRIFTF" add -A >/dev/null 2>&1
git -C "$DRIFTF" -c user.email=t@t.est -c user.name=test commit -q -m two

DRIFT_ERR="$(mktemp)"
REPO_MAP_ROOT="$DRIFTF" bash "$QUERY" stats >/dev/null 2>"$DRIFT_ERR"
if grep -q "behind HEAD" "$DRIFT_ERR" && grep -q "serving as-is" "$DRIFT_ERR"; then
  ok "drift: under tolerance, graphify map served with a staleness note"
else
  note "drift: expected an under-tolerance note, got: $(cat "$DRIFT_ERR")"
fi
[[ "$(jq -r '.backend' "$DRIFTF/tmp/repo-map.json" 2>/dev/null)" == "graphify" ]] \
  && ok "drift: under tolerance the graphify map is kept" \
  || note "drift: map was regenerated despite being under tolerance"

REPO_MAP_DRIFT_TOLERANCE=0 REPO_MAP_ROOT="$DRIFTF" bash "$QUERY" stats >/dev/null 2>&1
[[ "$(jq -r '.backend' "$DRIFTF/tmp/repo-map.json" 2>/dev/null)" == "grep" ]] \
  && ok "drift: past tolerance query.sh regenerates and falls back to grep" \
  || note "drift: past tolerance the stale graphify map was still served"
rm -f "$DRIFT_ERR"

# ---------------------------------------------------------------------------
# An uncommitted edit doesn't move HEAD, so a map keyed only on HEAD would serve
# a stale answer for most of an agent's task.
DIRTYF="$(mktemp -d)"
mkdir -p "$DIRTYF/src"
git -C "$DIRTYF" init -q
printf "export const a = 1;\n" > "$DIRTYF/src/a.js"
: > "$DIRTYF/src/u.js"
git -C "$DIRTYF" add -A >/dev/null 2>&1
git -C "$DIRTYF" -c user.email=t@t.est -c user.name=test commit -q -m one
DIRTY_BEFORE="$(REPO_MAP_ROOT="$DIRTYF" bash "$QUERY" deps src/a.js 2>/dev/null)"
[[ -z "$DIRTY_BEFORE" ]] && ok "dirty: clean tree has no edge yet" \
  || note "dirty: unexpected initial edge '$DIRTY_BEFORE'"

# Add an import WITHOUT committing — HEAD is unchanged.
printf "import u from './u.js';\n" >> "$DIRTYF/src/a.js"
DIRTY_AFTER="$(REPO_MAP_ROOT="$DIRTYF" bash "$QUERY" deps src/a.js 2>/dev/null)"
[[ "$DIRTY_AFTER" == "src/u.js" ]] \
  && ok "dirty: uncommitted import is picked up at the same HEAD" \
  || note "dirty: uncommitted edit was invisible (got '$DIRTY_AFTER')"

# And an untracked new file must register too.
printf "import u from './u.js';\n" > "$DIRTYF/src/new.js"
DIRTY_NEW="$(REPO_MAP_ROOT="$DIRTYF" bash "$QUERY" rdeps src/u.js 2>/dev/null | sort | tr '\n' ',')"
[[ "$DIRTY_NEW" == "src/a.js,src/new.js," ]] \
  && ok "dirty: untracked file registers as staleness" \
  || note "dirty: untracked file missed (got '$DIRTY_NEW')"
rm -rf "$DIRTYF"

# ---------------------------------------------------------------------------
# Python resolution. Leading dots are level markers, not path separators, so
# `from .b import other` must land on the sibling and not a root-level b.py.
# stdlib must resolve to nothing, exactly as an unresolved bare JS specifier.
PYF="$(mktemp -d)"
mkdir -p "$PYF/src/lib"
git -C "$PYF" init -q
cat > "$PYF/src/mod.py" <<'EOF'
# commented: from src.lib.ghost import thing
from src.lib.a import thing
from .b import other
from lib.c import third
import src.lib.d
import os
from typing import Optional
EOF
for n in a b c d ghost; do : > "$PYF/src/lib/$n.py"; done
: > "$PYF/src/b.py"
git -C "$PYF" add -A >/dev/null 2>&1
git -C "$PYF" -c user.email=t@t.est -c user.name=test commit -q -m fixture

if bash "$GEN" "$PYF" >/dev/null 2>&1; then
  PY_EDGES="$(jq -r '[.edges[] | select(.from=="src/mod.py") | .to] | sort | join(",")' \
    "$PYF/tmp/repo-map.json" 2>/dev/null)"
  [[ "$PY_EDGES" == "src/b.py,src/lib/a.py,src/lib/c.py,src/lib/d.py" ]] \
    && ok "python: all four import forms resolve" \
    || note "python: got '$PY_EDGES'"

  PY_SIBLING="$(jq -r '[.edges[] | select(.from=="src/mod.py" and .to=="src/b.py")] | length' \
    "$PYF/tmp/repo-map.json" 2>/dev/null)"
  [[ "$PY_SIBLING" == "1" ]] \
    && ok "python: 'from .b' resolves to the sibling, not the repo root" \
    || note "python: relative import did not resolve to src/b.py"

  PY_GHOST="$(jq -r '[.edges[] | select(.to=="src/lib/ghost.py")] | length' \
    "$PYF/tmp/repo-map.json" 2>/dev/null)"
  [[ "$PY_GHOST" == "0" ]] && ok "python: '#' comment ignored" \
    || note "python: commented import became an edge"
else
  note "python: generator failed on the python fixture"
fi
rm -rf "$PYF"

# ---------------------------------------------------------------------------
# Scale. The first implementation forked a grep per candidate suffix per
# specifier and took over three minutes on 6,000 files, which made the "cheap
# regeneration" premise the staleness policy rests on false. A bound here is
# what would catch a regression back to that shape; the small fixtures above
# cannot.
SCALEF="$(mktemp -d)"
mkdir -p "$SCALEF/src"
git -C "$SCALEF" init -q
i=1
while [[ "$i" -le 800 ]]; do
  printf "import x from './m%s.js';\n" "$(( (i % 800) + 1 ))" > "$SCALEF/src/m$i.js"
  i=$(( i + 1 ))
done
git -C "$SCALEF" add -A >/dev/null 2>&1
git -C "$SCALEF" -c user.email=t@t.est -c user.name=test commit -q -m fixture
SCALE_START="$(date +%s)"
bash "$GEN" "$SCALEF" >/dev/null 2>&1
SCALE_SECS=$(( $(date +%s) - SCALE_START ))
SCALE_EDGES="$(jq -r '.edges | length' "$SCALEF/tmp/repo-map.json" 2>/dev/null)"
[[ "$SCALE_EDGES" == "800" ]] \
  && ok "scale: 800 files resolve to 800 edges" \
  || note "scale: expected 800 edges, got '$SCALE_EDGES'"
[[ "$SCALE_SECS" -le 10 ]] \
  && ok "scale: 800 files in ${SCALE_SECS}s (bound 10s)" \
  || note "scale: 800 files took ${SCALE_SECS}s — the per-candidate fork regressed"
rm -rf "$SCALEF"

# ---------------------------------------------------------------------------
# Outside a git repo both scripts claim to degrade gracefully rather than crash.
NOGIT="$(mktemp -d)"
mkdir -p "$NOGIT/src"
printf "import u from './u.js';\n" > "$NOGIT/src/a.js"
: > "$NOGIT/src/u.js"
if bash "$GEN" "$NOGIT" >/dev/null 2>&1; then
  ok "no-git: generator exits 0 outside a git repo"
  [[ "$(jq -r '.git_head' "$NOGIT/tmp/repo-map.json" 2>/dev/null)" == "" ]] \
    && ok "no-git: git_head is empty, not a crash" \
    || note "no-git: unexpected git_head"
  NOGIT_DEPS="$(REPO_MAP_ROOT="$NOGIT" bash "$QUERY" deps src/a.js 2>/dev/null)"
  [[ "$NOGIT_DEPS" == "src/u.js" ]] \
    && ok "no-git: query still answers" \
    || note "no-git: query returned '$NOGIT_DEPS'"
else
  note "no-git: generator failed outside a git repo"
fi
rm -rf "$NOGIT"

# ---------------------------------------------------------------------------
# A missing scanner must fail loudly. Without the guard the scan matches nothing
# and the generator writes a map with every node and no edges at all — valid
# JSON, exit 0, and completely wrong. REPO_MAP_AWK lets us simulate that without
# touching PATH.
AWK_ERR="$(mktemp)"
AWK_MAP_BEFORE="$(md5sum "$MAP" 2>/dev/null | cut -d' ' -f1)"
REPO_MAP_AWK="definitely-not-a-real-awk" bash "$GEN" "$FIXTURE" >"$AWK_ERR" 2>&1
AWK_EXIT=$?
[[ "$AWK_EXIT" -ne 0 ]] \
  && ok "missing awk: generator exits non-zero" \
  || note "missing awk: generator exited 0 — an edgeless map would look valid"
if grep -qi "awk" "$AWK_ERR"; then
  ok "missing awk: stderr names the missing dependency"
else
  note "missing awk: stderr did not name awk: $(cat "$AWK_ERR")"
fi
AWK_MAP_AFTER="$(md5sum "$MAP" 2>/dev/null | cut -d' ' -f1)"
[[ "$AWK_MAP_BEFORE" == "$AWK_MAP_AFTER" ]] \
  && ok "missing awk: existing map left untouched" \
  || note "missing awk: the existing map was overwritten"
rm -f "$AWK_ERR"

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "test-repo-map: PASS"
else
  echo "test-repo-map: $FAIL failure(s)"
fi
exit "$FAIL"
