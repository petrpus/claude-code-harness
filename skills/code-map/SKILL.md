---
name: code-map
description: Generate a self-contained, offline, interactive HTML module/dependency map from import/require edges. `/code-map [--granularity=dir|file]` — default is top-level source directories, `--granularity=file` maps individual files. Use when the user wants to visualize module dependencies, see which files/directories are most depended-on, or understand a codebase's shape at a glance.
---

# Skill: /code-map

Builds a nodes+edges dependency graph from static import/require scanning and
renders it as a fully offline, air-gapped HTML page — no CDN, no build step,
no dependency added to the consumer repo.

## Workflow

1. **Choose granularity.** `$ARGUMENTS` may contain `--granularity=dir`
   (default) or `--granularity=file`.
   - `dir`: nodes are top-level source directories under `src/`, `app/`,
     `lib/`, or `packages/` (whichever exist) — one level deep, e.g.
     `src/api`, `src/components`, `src/utils`.
   - `file`: nodes are individual source files.
2. **Scan import edges** with Grep:
   ```bash
   rg -n "^\s*import .* from ['\"]([^'\"]+)['\"]" --glob '*.{js,jsx,ts,tsx,mjs,cjs}'
   rg -n "require\(['\"]([^'\"]+)['\"]\)" --glob '*.{js,jsx,ts,tsx,mjs,cjs}'
   rg -n "^\s*from ([\w.]+) import" --glob '*.py'
   rg -n "^\s*import ([\w.]+)" --glob '*.py'
   ```
   For each match, the source is the file being scanned; the target is the
   imported specifier.
3. **Resolve edges to internal modules only.**
   - Drop bare specifiers that resolve to `node_modules` or a stdlib module
     (no relative prefix `./`/`../`, and not a path/tsconfig alias the
     project defines — check `tsconfig.json` `paths` / `jsconfig.json` for
     aliases like `@/*` and resolve those too).
   - Resolve relative imports to an actual file (try the literal path, then
     `.ts`/`.tsx`/`.js`/`.jsx`/`/index.*` suffixes).
   - At `dir` granularity, collapse the resolved file path to its top-level
     source directory (drop edges where source and target collapse to the
     same directory — those are intra-module, not inter-module).
4. **Build the graph.** De-duplicate edges. Compute each node's `size` as its
   fan-in (count of distinct incoming edges) — nodes with more dependents
   render larger, which is the "what's load-bearing here" signal this map
   exists to surface.
5. **Write `docs/maps/modules.json`**:
   ```json
   {
     "nodes": [{ "id": "src/api", "label": "src/api", "size": 4 }],
     "edges": [{ "from": "src/components", "to": "src/api" }]
   }
   ```
   `id` is the stable key edges reference; `label` is what's displayed
   (usually the same, but keep them separate fields since a future revision
   may want shorter display labels without touching edge references).
6. **Render.** Copy [code-map.template.html](code-map.template.html) to
   `docs/maps/index.html`, injecting the JSON into the
   `<script id="graph-data" type="application/json">` placeholder (replace
   the placeholder content, don't append).

## Scope note

Cycle detection/highlighting is deferred (planned v0.3). This version ships
fan-in sizing + a force-directed layout only — a node's size already hints at
central modules, but the template does not flag cycles.

## Bundled files

- `code-map.template.html` — the fully self-contained (no CDN) HTML page
  instantiated to `docs/maps/index.html`. Vanilla JS force layout on SVG;
  works air-gapped once generated.
