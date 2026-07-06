---
name: openapi-sync
description: Generate or sync docs/api/openapi.yaml from route handler code (code is the source of truth) and render a browsable Redoc HTML page. `/openapi-sync [--check]` — default mode writes/updates the spec and HTML; `--check` mode is offline (pure grep + yaml diff, no network) and reports drift for CI. Use when the user wants an API spec, OpenAPI docs, route documentation, or asks "is our OpenAPI spec out of date".
---

# Skill: /openapi-sync

Code is the source of truth. This skill scans route handlers, then
authors/updates `docs/api/openapi.yaml` (OpenAPI 3.1) to match — it never
hand-invents endpoints the code doesn't have.

## Modes

`$ARGUMENTS` selects the mode; default is sync (read + write).

### sync (default)

1. **Detect the framework.** Check `package.json` deps / lockfile / source
   layout for Express, Fastify, Hono, Next.js (app or pages router), or React
   Router. If more than one is present, ask which to scan.
2. **Scan routes.** Use the grep recipes in [ROUTE-SCAN.md](ROUTE-SCAN.md) for
   the detected framework to enumerate path, method, and param locations.
3. **Author/update the spec.** Read `docs/api/openapi.yaml` if it exists.
   - For each discovered route not yet in the spec: add a path item — method,
     path (convert framework param syntax to OpenAPI `{param}` style),
     parameters (path/query from the handler signature or validation schema),
     and request/response shapes inferred from handler code (body parsing,
     TypeScript types/interfaces, zod/joi schemas if present, or the literal
     object shape returned).
   - For each path already in the spec: update method/params/shapes to match
     current code, but **preserve hand-written `description` and `summary`
     fields** — never overwrite prose a human wrote, only structural fields.
   - For paths in the spec no longer found in code: flag for removal, don't
     delete silently — ask.
   - Target OpenAPI 3.1 (`openapi: 3.1.0`).
4. **Lint (optional, best-effort).** If `npx` is available, run
   `npx @redocly/cli lint docs/api/openapi.yaml` and report warnings/errors.
   If `npx` fails or isn't installed, skip silently — this step never blocks
   generation.
5. **Render.** Copy [redoc.template.html](redoc.template.html) to
   `docs/api/index.html`, with the spec-url already pointing at
   `./openapi.yaml` (same directory, so no path rewrite needed unless the
   user asked for a different output location).

### --check (CI mode, fully offline)

No network calls, no npx, no writes. Pure grep + yaml comparison:

1. Re-run the same route scan as sync (step 2 above) → set of
   `(method, path)` discovered in code.
2. Parse `docs/api/openapi.yaml` → set of `(method, path)` under `paths:`.
   A plain YAML-path read is enough (top-level `paths:` keys + their HTTP
   verb keys) — no need for a full schema-validating parser.
3. Diff the two sets and report:
   - **Missing from spec** — routes in code, absent from `openapi.yaml`.
   - **Extra in spec** — paths in `openapi.yaml` with no matching route in
     code (stale/removed endpoints).
4. Print a summary block; end with a clear PASS/FAIL line so a CI step can
   grep for it, e.g.:
   ```
   openapi-sync --check: 2 missing, 1 extra — FAIL
   ```
   or `openapi-sync --check: spec matches code — PASS`. Exit non-zero (in the
   shell command you run) when drift is found, so CI fails the build.

## Notes

- Generation and `--check` are fully offline. Only **viewing**
  `docs/api/index.html` needs network, because the Redoc bundle itself loads
  from a CDN (see template comment) — this skill has no build step and adds
  no dependency to the consumer repo.
- Re-syncing is idempotent: running sync twice with no code changes should
  produce no diff.

## Bundled files

- `ROUTE-SCAN.md` — grep/ripgrep recipes per framework.
- `redoc.template.html` — the HTML instantiated to `docs/api/index.html`.
