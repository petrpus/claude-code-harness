---
name: code-map
description: Generate a self-contained, offline, interactive HTML module/dependency map from tmp/repo-map.json. `/code-map [--granularity=dir|file]` — default is top-level source directories, `--granularity=file` maps individual files. Use when the user wants to visualize module dependencies, see which files/directories are most depended-on, or understand a codebase's shape at a glance.
---

# Skill: /code-map

Renders `tmp/repo-map.json` — the Schema v1 nodes+edges map maintained by
`skills/repo-map/` — as a fully offline, air-gapped HTML page. No CDN, no
build step, no dependency added to the consumer repo, and no import scan of
its own: `skills/repo-map/build-repo-map.sh` owns the one scan implementation
(a grep backend, or a Graphify `graph.json` adapter when one is already on
disk — see `docs/adr/0004-graphify-as-optional-repo-map-backend.md`).

## Workflow

1. **Ensure a fresh map.** Run `skills/repo-map/build-repo-map.sh` (or invoke
   `skills/repo-map/query.sh stats`, which regenerates as a side effect when
   stale) so `tmp/repo-map.json` reflects current HEAD, honoring the
   staleness rules: an absent map or a `schema_version` mismatch always
   regenerates; a `grep`-backend map whose `git_head` doesn't match current
   HEAD regenerates; a `graphify`-backend map under drift tolerance serves
   with a staleness note instead of forcing a regeneration nothing can
   actually re-run. Read the resulting `tmp/repo-map.json`.
2. **Choose granularity.** `$ARGUMENTS` may contain `--granularity=dir`
   (default) or `--granularity=file`.
   - `file`: use each node's `id` as-is.
   - `dir`: collapse each node `id` to its top-level source directory (e.g.
     `src/api/client.ts` → `src/api`), drop edges whose endpoints collapse to
     the same directory (intra-module, not inter-module), and re-aggregate
     `weight` across edges that now share the same collapsed `(from, to)`
     pair.
3. **Project onto the render shape.** Size each node by its `fan_in` (nodes
   with more dependents render larger — the "what's load-bearing here" signal
   this map exists to surface). Write `docs/maps/modules.json`:
   ```json
   {
     "nodes": [{ "id": "src/api", "label": "src/api", "size": 4 }],
     "edges": [{ "from": "src/components", "to": "src/api" }]
   }
   ```
   `id` is the stable key edges reference; `label` is what's displayed
   (usually the same, but kept as a separate field since a future revision
   may want shorter display labels without touching edge references).
4. **Render.** Copy [code-map.template.html](code-map.template.html) to
   `docs/maps/index.html`, injecting the JSON into the
   `<script id="graph-data" type="application/json">` placeholder (replace
   the placeholder content, don't append).

## Scope note

Cycle detection/highlighting is deferred (planned v0.3). This version ships
fan-in sizing + a force-directed layout only — a node's size already hints at
central modules, but the template does not flag cycles. Graph traversal
queries (transitive impact, path between two files) are out of scope for both
`code-map` and `repo-map` — see `skills/repo-map/SKILL.md`.

## Bundled files

- `code-map.template.html` — the fully self-contained (no CDN) HTML page
  instantiated to `docs/maps/index.html`. Vanilla JS force layout on SVG;
  works air-gapped once generated.
