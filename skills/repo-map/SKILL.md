---
name: repo-map
description: Machine-readable module/dependency map (tmp/repo-map.json, Schema v1) that agents query instead of grepping the tree. Grep backend scans JS/TS/Python import edges; a Graphify graph.json is adapted when one is already on disk. Use to answer "what depends on this file", "what does this file depend on", "what are the hotspots", or "what are the entry points" without a fresh grep sweep.
---

# Skill: /repo-map

Generates and queries `tmp/repo-map.json`, a Schema v1 nodes+edges map of the
repo's file-level import graph. `skills/code-map/SKILL.md` renders this same
map as an HTML page; this skill owns the one scan implementation.

This doc is intentionally thin for now — the full workflow (five queries,
staleness rules, Graphify adapter) lands as the later slices in
`tmp/autopilot/IMPLEMENTATION_PLAN.md` land. See `docs/adr/0004-graphify-as-optional-repo-map-backend.md`
for the design decisions behind the schema and backend split.

## Bundled files

- `build-repo-map.sh` — grep-backend generator. Scans JS/TS/Python
  import/require edges, resolves relative and tsconfig/jsconfig path-alias
  specifiers to real files, drops unresolved bare specifiers (external
  packages, stdlib), and writes `tmp/repo-map.json` with a provenance stamp
  (`schema_version`, `generated_at`, `git_head`, `backend`). Requires `jq`;
  degrades gracefully outside a git repo.
