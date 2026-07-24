# Repo-map layer is a plain JSON file on disk, not an MCP server

The planned "graph engineering" layer (machine-readable module/import map for
agents, roadmap item U3) will be a second output of the existing `code-map`
skill — `tmp/repo-map.json` — queried by a lightweight `repo-map` skill. We
deliberately do NOT ship it as an MCP code-graph server, although that is the
dominant community pattern. Reasons: this repo has a standing "no MCP needed"
policy (everything goes through CLI + files), a file survives fresh-context
autopilot iterations at zero session-init cost, and the file contract is
testable with plain shell. The trade-off: no live incremental updates — the
map is regenerated, not maintained.

Consequences: `repo-map.json`'s schema becomes a contract for autopilot and
any consumer skills; changing it later requires a versioned migration.
