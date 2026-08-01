# Graphify is an optional repo-map backend, never a dependency

Building on [0001-repo-map-as-file-not-mcp.md](0001-repo-map-as-file-not-mcp.md):
the repo-map layer stays a
plain JSON file on disk, and now gets a second, optional source for that file.
Graphify (`graphify.net`) can produce a much richer `graph.json` (calls,
inherits, confidence) than our own grep scan, but the harness never installs,
downloads, or pip-installs anything — so support is detection-only: if a
`graph.json` is already sitting in the consumer project, adapt it; otherwise
fall back to the grep backend. Graphify's MCP server stays out of scope,
per ADR-0001's file-not-MCP stance.

## Decisions

1. **Optional, never a dependency.** Detection only. No install/download/MCP.
2. **Our schema owns the contract**, versioned via `schema_version`. The
   mandatory minimum a consumer may rely on is `nodes[] {id, label, kind,
   fan_in, fan_out}` and `edges[] {from, to, type}`. Everything past that is
   best-effort enrichment — the grep backend emits only `type: "imports"`; the
   Graphify adapter may add `calls` / `inherits` edges and a `confidence`
   field.
3. **File-level granularity is canonical.** Graphify's sub-file nodes
   (functions, classes) collapse onto their containing file; their edge types
   survive, aggregated file→file with a `weight` count, so degree metrics stay
   comparable across backends regardless of which one produced the map.
4. **Staleness is a provenance stamp plus lazy regeneration at read time** —
   no git hook. A pre-commit hook was considered and rejected: it adds commit
   latency, `.git/hooks` management, and collides with projects already using
   husky or similar.
5. **The query surface is five jq-expressible queries**: `deps`, `rdeps`,
   `hotspots`, `entry-points`, `stats`. Anything needing graph traversal
   (transitive impact, path between two files) is explicitly deferred.
6. **The Graphify adapter is defensive.** It validates the shape before
   trusting it; on any mismatch it warns on stderr and falls back to the grep
   backend. A foreign format failure must never become a hard error.
7. **Autopilot gets a compact digest, not the whole graph.** Recorded here as
   the consumer contract; wiring it into `skills/autopilot/` is a separate
   slice (issue #11 / M3), not this one.
8. **The generator lives with `repo-map`; `code-map` renders.** This inverts
   ADR-0001's framing of the map as "a second output of `code-map`": there is
   one scan implementation (`skills/repo-map/build-repo-map.sh`), and
   `code-map` becomes a renderer over its output (`tmp/repo-map.json`).

## Consequences

Two backends must stay comparable under the same schema, so any future field
added to the grep backend's output has to make sense for (or be omittable by)
the Graphify adapter too — the schema, not either scanner, is the contract.

The two backends also differ in accuracy, and that difference is the point. A
regex scan cannot distinguish an import from a specifier quoted inside a string
literal, and it never sees dynamic `import()` or runtime-computed paths. Such
phantom edges inflate `fan_in`, the metric `hotspots` ranks on, so the cheap
backend's output is a navigational hint, not ground truth. Rather than chase
parsing accuracy we do not want to own, we accept that ceiling for the
zero-dependency tier and let projects that need precision run Graphify.
