#!/usr/bin/env bash
# scripts/test-fault-injection.sh — one invariant, swept across every tool the
# repo-map generator shells out to.
#
# This exists because the same defect kept coming back wearing different hats:
# a PCRE2-less ripgrep, then a missing scanner, then a scanner that exits
# non-zero — each time producing a valid-JSON, plausible, *silently wrong* map
# at exit 0, and each fix closing only the variant in front of it. Guarding
# failure modes one at a time is a losing game. This asserts the property
# instead:
#
#   For any fault injected into any tool the generator uses, the generator
#   must EITHER exit non-zero, OR write a map whose GRAPH — nodes and edges —
#   is identical to the known-good one.
#
# Provenance is held to a weaker rule on purpose. `git_head` and `worktree_sig`
# are allowed to degrade: outside a git repo there is no HEAD to record, and a
# script cannot tell a broken `git` from an absent one. But a degraded stamp
# turns staleness checking off, so the degradation has to be *announced* — a map
# that quietly stops refreshing looks exactly like one that is always right.
#
# So: wrong graph at exit 0 is a failure, always. Degraded provenance at exit 0
# is a failure unless the run said so on stderr.
#
# Faults are injected by prepending a shim directory to PATH for the generator
# run only, so this script's own commands keep working normally. Three modes,
# because they fail differently: a tool that errors, a tool that succeeds while
# saying nothing (the nastiest — it looks like a legitimately empty result), and
# a tool that emits junk.
#
# Invoked from scripts/verify.sh. Cleaned up on exit.

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1

FAIL=0
note() { echo "  ✗ $*"; FAIL=1; }
ok()   { echo "  ✓ $*"; }

GEN="skills/repo-map/build-repo-map.sh"
[[ -f "$GEN" ]] || { note "$GEN is missing"; echo; echo "test-fault-injection: $FAIL failure(s)"; exit 1; }

FIX="$(mktemp -d)"
SHIM="$(mktemp -d)"
cleanup() { rm -rf "$FIX" "$SHIM"; }
trap cleanup EXIT

# A fixture with enough shape that a wrong answer is visibly wrong: a resolved
# relative import, an alias import, a dropped bare specifier, and a Python edge.
mkdir -p "$FIX/src/lib"
git -C "$FIX" init -q
cat > "$FIX/tsconfig.json" <<'EOF'
{ "compilerOptions": { "paths": { "@/*": ["src/*"] } } }
EOF
printf "import foo from './lib/foo.js';\nimport _ from 'lodash';\n" > "$FIX/src/main.js"
printf "import util from '@/lib/util';\n" > "$FIX/src/other.js"
: > "$FIX/src/lib/foo.js"
: > "$FIX/src/lib/util.js"
printf "from .helper import thing\n" > "$FIX/src/mod.py"
: > "$FIX/src/helper.py"
git -C "$FIX" add -A >/dev/null 2>&1
git -C "$FIX" -c user.email=t@t.est -c user.name=test commit -q -m fixture

# The graph is the load-bearing part; provenance is compared separately.
graph_of()      { jq -S '{nodes, edges}' "$1" 2>/dev/null; }
provenance_of() { jq -Sc '{schema_version, git_head, worktree_sig, backend}' "$1" 2>/dev/null; }

MAP="$FIX/tmp/repo-map.json"
if ! bash "$GEN" "$FIX" >/dev/null 2>&1 || [[ ! -f "$MAP" ]]; then
  note "could not build the baseline map"
  echo; echo "test-fault-injection: $FAIL failure(s)"; exit 1
fi
BASE_GRAPH="$(graph_of "$MAP")"
BASE_PROV="$(provenance_of "$MAP")"
BASE_EDGES="$(jq '.edges | length' "$MAP" 2>/dev/null)"
[[ "${BASE_EDGES:-0}" -ge 3 ]] \
  && ok "baseline map has $BASE_EDGES edges to get wrong" \
  || note "baseline has only ${BASE_EDGES:-0} edges — the sweep would prove little"

# Tools the generator shells out to. `git` is included deliberately: it decides
# git_head and the worktree signature.
TOOLS="awk jq git find sort grep sed tr cksum date mkdir head cat"

make_shim() { # tool mode
  rm -f "$SHIM"/*
  case "$2" in
    fail)   printf '#!/bin/sh\nexit 3\n' > "$SHIM/$1" ;;
    silent) printf '#!/bin/sh\nexit 0\n' > "$SHIM/$1" ;;
    junk)   printf '#!/bin/sh\necho "@@junk@@"\nexit 0\n' > "$SHIM/$1" ;;
  esac
  chmod +x "$SHIM/$1"
}

for tool in $TOOLS; do
  for mode in fail silent junk; do
    make_shim "$tool" "$mode"
    rm -f "$MAP"
    RUN_ERR="$(PATH="$SHIM:$PATH" bash "$GEN" "$FIX" 2>&1 >/dev/null)"
    rc=$?

    if [[ "$rc" -ne 0 ]]; then
      ok "$tool/$mode: refused (exit $rc)"
      continue
    fi
    if [[ ! -f "$MAP" ]]; then
      ok "$tool/$mode: exited 0 but wrote no map"
      continue
    fi

    if [[ "$(graph_of "$MAP")" != "$BASE_GRAPH" ]]; then
      note "$tool/$mode: exit 0 with a WRONG GRAPH — silently wrong output"
      continue
    fi
    if [[ "$(provenance_of "$MAP")" == "$BASE_PROV" ]]; then
      ok "$tool/$mode: survived intact"
    elif [[ -n "$RUN_ERR" ]]; then
      ok "$tool/$mode: graph correct, degraded provenance announced"
    else
      note "$tool/$mode: provenance silently degraded — staleness checking is now off with no warning"
    fi
  done
done

# Restore a good map so a later stage isn't reading wreckage.
rm -f "$SHIM"/*
bash "$GEN" "$FIX" >/dev/null 2>&1

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "test-fault-injection: PASS"
else
  echo "test-fault-injection: $FAIL failure(s)"
fi
exit "$FAIL"
