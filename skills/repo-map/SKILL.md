---
name: repo-map
description: Machine-readable module/dependency map (tmp/repo-map.json, Schema v1) that agents query instead of grepping the tree. Grep backend scans JS/TS and Python import edges; a Graphify graph.json is adapted when one is already on disk. Use to answer "what depends on this file", "what does this file depend on", "what are the hotspots", or "what are the entry points" without a fresh grep sweep.
---

# Skill: /repo-map

Generates and queries `tmp/repo-map.json`, a Schema v1 nodes+edges map of the
repo's file-level import graph. `skills/code-map/SKILL.md` renders this same
map as an HTML page; this skill owns the one scan implementation.

## When to use this instead of grepping

Grepping the tree for "who imports `src/lib/util.ts`" re-scans every file,
every time, and only answers the one question you happened to grep for. This
skill answers five common questions from a map that's built once and reused:
"what does this file depend on", "what depends on this file", "what are the
load-bearing hotspots", "where are the entry points (and the dead files)",
and "how big is this codebase's import graph". Reach for it whenever an
agent's next step would otherwise be a fresh `rg`/`grep` sweep over import
statements.

## The five queries

```bash
skills/repo-map/query.sh deps <file>        # what <file> imports
skills/repo-map/query.sh rdeps <file>       # what imports <file>
skills/repo-map/query.sh hotspots [N]       # top-N nodes by fan_in (default 10)
skills/repo-map/query.sh entry-points       # nodes with fan_in == 0
skills/repo-map/query.sh stats              # node/edge counts + provenance
```

Each query regenerates the map first if it's stale or missing (see
Staleness, below), so there's no separate "build" step to remember. `<file>`
is the repo-relative path used as a node `id`, e.g. `src/lib/util.ts`.

Output shapes:
- `deps` / `rdeps` — one file path per line.
- `hotspots` — `id<TAB>fan_in`, one per line, highest `fan_in` first.
- `entry-points` — one file path per line.
- `stats` — a single JSON object: `{schema_version, backend, backend_version,
  git_head, generated_at, nodes, edges}` (`nodes`/`edges` are counts).

An unknown subcommand, or a missing `<file>` argument to `deps`/`rdeps`,
prints a usage message to stderr and exits non-zero — never a jq stack trace.

**Honest caveat on `entry-points`:** `fan_in == 0` surfaces two different
things at once — genuine entry points (the file nothing else imports because
it's the thing that gets run) *and* dead files (nothing imports them because
nothing uses them). The query doesn't try to tell them apart; read the list
with that in mind.

**Honest caveat on grep-backend accuracy:** the grep backend matches import
syntax with a regex; it does not parse. Comments — both `//` lines and `/* … */`
blocks — are stripped before matching, so a commented-out import or a JSDoc
example no longer invents an edge. What still slips through is a specifier
inside a *string literal*: `const s = "import x from './fake'"` reads as an
import and becomes one. Such phantom edges inflate the target's `fan_in`, which
is exactly what `hotspots` ranks on, so treat a surprising hotspot as a question
rather than a fact. Dynamic `import()`, re-exports through barrel files, and
runtime-computed specifiers are invisible to it. This is the accuracy ceiling of
a zero-dependency regex scan and the reason the Graphify backend exists: when
precision matters more than having no dependencies, run Graphify and let the
adapter pick its AST-derived graph up.

## Schema v1

```json
{
  "schema_version": 1,
  "generated_at": "2026-08-01T10:00:00Z",
  "git_head": "0b14690",
  "worktree_sig": "184727361",
  "backend": "grep",
  "backend_version": null,
  "nodes": [
    { "id": "src/api/client.ts", "label": "client.ts", "kind": "file",
      "fan_in": 3, "fan_out": 2 }
  ],
  "edges": [
    { "from": "src/app/page.tsx", "to": "src/api/client.ts",
      "type": "imports", "weight": 1 }
  ]
}
```

- `id` is the repo-relative path and the stable key edges reference.
- `fan_in` = distinct incoming edges (how load-bearing a file is); `fan_out`
  = distinct outgoing.
- `backend` is `"grep"` or `"graphify"`.
- `worktree_sig` fingerprints uncommitted work — see Staleness.

**How specifiers resolve.** JS/TS: relative (`./`, `../`), root-absolute, and
bare specifiers matched against `tsconfig.json`/`jsconfig.json` `paths` aliases;
anything left unresolved is an external package and is dropped. Python: leading
dots are *level* markers, not path separators, so `from .b import x` is
sibling-relative and `from ..pkg.c import y` walks one package up; an absolute
module is tried from the repo root and from the importing file's top-level
directory (what a `src/`-rooted layout needs). A module that resolves to neither
is stdlib or site-packages and is dropped, exactly as an unresolved bare JS
specifier is. The imported *names* count too: in `from . import sibling` and
`from pkg.sub import helper`, the name is the module being depended on, so the
edge points at `sibling.py` / `helper.py` when those files exist, and falls back
to the package's `__init__.py` only when the names are ordinary symbols defined
there.

**Mandatory minimum** a consumer may rely on regardless of backend:
`nodes[] {id, label, kind, fan_in, fan_out}` and `edges[] {from, to, type}`.
Everything else is best-effort enrichment — the grep backend emits only
`type: "imports"`; the Graphify adapter may add `calls` / `inherits` edge
types, a `weight` count, and a `confidence` field. Don't write a query that
assumes enrichment fields exist; they're present only when the graphify
backend produced them.

## Staleness

Every map carries a provenance stamp: `{generated_at, git_head, worktree_sig,
backend, schema_version}`. There is no git hook — regeneration is lazy, at read time,
inside `query.sh`:

- Map absent, or `schema_version` doesn't match this doc → regenerate. Never
  guess at an old shape.
- `backend: "grep"` and `git_head` != current HEAD → regenerate. It is cheap
  and fully local — a 6,000-file tree rebuilds in well under a second — so
  there's no reason to serve stale grep data.
- **`worktree_sig` != the current working tree** → regenerate (grep backend), or
  warn that only Graphify can re-read the tree (graphify backend). HEAD does not
  move when you edit a file, and an uncommitted edit is the state an agent
  queries from for most of a task, so a map keyed on HEAD alone would go quietly
  wrong exactly when it is used most. The signature covers tracked edits by
  content and untracked paths, and excludes `tmp/repo-map.json` itself so a
  project that doesn't gitignore `tmp/` can't invalidate the map by writing it.
- `backend: "graphify"` and `git_head` != current HEAD → we can't re-run
  Graphify ourselves, so a small amount of drift is tolerated:
  `REPO_MAP_DRIFT_TOLERANCE` commits (default 20, override via env var).
  Under tolerance, the existing map is served as-is with a staleness note on
  stderr naming the drift. Past tolerance, `query.sh` regenerates — which
  re-runs the Graphify adapter below, and it applies the same tolerance
  check against its own input, falling back to a fresh grep map (with advice
  to re-run Graphify) if `graph.json` itself is too far behind.

## The Graphify adapter

[Graphify](https://graphify.net) can produce a much richer `graph.json` than
this skill's own grep scan — call edges, inheritance edges, confidence
scores. The harness never installs, downloads, or otherwise depends on it:
support is **detection-only**. If a `graph.json` is already sitting at the
repo root when `build-repo-map.sh` runs, it's adapted; otherwise the grep
backend runs, silently, as if Graphify didn't exist. See
`docs/adr/0004-graphify-as-optional-repo-map-backend.md` for the full design
rationale; Graphify's MCP server is out of scope per
`docs/adr/0001-repo-map-as-file-not-mcp.md`'s file-not-MCP stance.

The adapter expects `graph.json` nodes to carry an `id` and a `file` field
(the path of the file the node belongs to) and edges to carry `from`, `to`,
`type` referencing those ids. Sub-file nodes (functions, classes, …) collapse
onto their containing file; surviving edge types aggregate file→file with a
`weight` count, and `fan_in`/`fan_out` are recomputed on the collapsed graph
so degree metrics stay comparable across backends. A `git_head` field on
`graph.json`, if present, is what drift is measured against — without it,
drift can't be tracked and the map is adapted without a freshness guarantee.

Any mismatch — invalid JSON, missing `nodes[]`/`edges[]` arrays, nodes
missing `id`/`file`, edges pointing at unknown ids, or drift past tolerance —
is never a hard error. `build-repo-map.sh` warns on stderr naming the reason
and falls straight through to the grep backend, exiting 0.

## Non-goals

- **Graph traversal** — transitive impact analysis, path-between-two-files —
  is explicitly deferred. The five queries above are all jq-expressible over
  a flat nodes+edges array; anything needing a real traversal is out of
  scope for now.
- `tmp/repo-map.json` is a regenerable artifact, not a source file — `tmp/`
  is gitignored and it must never be committed. A map you want to keep
  belongs under `docs/maps/` (that's what `code-map` writes).

## Requirements

`REPO_MAP_AWK` overrides which awk is used; it must name a **single
executable** (a path or a command name), not a multi-word invocation like
`"busybox awk"` — the guard resolves it with `command -v`.

`jq` and `awk` are required — `awk` does the scanning and the resolution, `jq`
assembles the JSON. `build-repo-map.sh` fails with a clear message if either is
missing, rather than writing a map with every node and no edges: valid JSON,
plausible output, and every answer silently wrong. No ripgrep, no Python, no
package manager. Both scripts degrade gracefully outside a git repo (empty
`git_head`, no crash) and never hard-fail a consumer project that doesn't
otherwise match the harness's conventions.

## Bundled files

- `build-repo-map.sh` — the generator. Scans JS/TS and Python import/require
  edges (relative paths and tsconfig/jsconfig `paths` aliases resolved,
  unresolved bare specifiers dropped), or adapts a Graphify `graph.json` when
  one is present and trustworthy, and writes `tmp/repo-map.json` with the
  provenance stamp above. Usage: `build-repo-map.sh [root-dir]` (defaults to
  the current git toplevel, or cwd outside a git repo).
- `query.sh` — the five queries above, plus the staleness/regeneration logic.
  Usage: `query.sh <deps|rdeps|hotspots|entry-points|stats> [args]`. Set
  `REPO_MAP_ROOT` to point it at a tree other than the current git toplevel
  (used by `scripts/test-repo-map.sh`'s fixture tests).
- `digest.sh [slice-hint]` — the compact digest `skills/autopilot/loop.sh`
  feeds BUILD (ADR-0004 item 7, closed in 0.5.0's S5): `stats`, the top-10
  `hotspots`, and, for each file path found in `slice-hint` (autopilot passes
  the selected plan slice's own line), its `deps`/`rdeps` (capped at 8 each).
  Calls `query.sh` only — never reads `tmp/repo-map.json` directly, so
  staleness/regeneration stays single-sourced there — and emits at most 40
  lines total, truncating rather than growing past it. Deliberately **not**
  wired into the PLAN or verifier prompts: BUILD can discount a wrong hint by
  opening the file anyway, but PLAN would freeze a phantom grep-backend edge
  into a hard `after:` ordering that `select_next_slice()` then enforces.
  Never a hard error — a missing map or any `query.sh` failure means "no
  digest" (exit 1, nothing on stdout); the caller omits the whole section
  rather than inject a partial one.
