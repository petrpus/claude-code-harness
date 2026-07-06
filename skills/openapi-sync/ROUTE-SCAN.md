# Route-scan cheat-sheet

Practical grep/ripgrep recipes to enumerate routes per framework. Run from
the repo root; narrow the path glob to the project's actual source dir
(`src/`, `app/`, `server/`, …).

Prefer `rg` (ripgrep) when available; `grep -rn` fallbacks are given too.

## Express

**Find routes:**

```bash
rg -n "\.(get|post|put|patch|delete|all)\(\s*['\"]" --glob '*.{js,ts}' src/
# router.get('/users/:id', ...) or app.post('/users', ...)
```

- **Method**: the verb in `.get(` / `.post(` / etc.
- **Path**: the first string literal argument. Watch for a `router` mounted
  with a prefix — grep `app.use\(['\"]([^'\"]+)['\"],\s*\w+Router\)` and
  prepend that prefix to routes found in the mounted router file.
- **Params**: Express path params use `:id` syntax → convert to OpenAPI
  `{id}`. Query params: grep the handler body for `req.query.<name>`. Body:
  grep for `req.body` destructuring or a validation middleware
  (`zod`/`joi`/`express-validator`) applied to the route.

## Fastify

**Find routes:**

```bash
rg -n "fastify\.route\(\{" --glob '*.{js,ts}' -A 5 src/
rg -n "fastify\.(get|post|put|patch|delete)\(\s*['\"]" --glob '*.{js,ts}' src/
```

- **Method**: either the `.get(`/`.post(` shorthand, or the `method:` field
  inside a `fastify.route({...})` object.
- **Path**: the string literal, or the `url:`/`path:` field in `.route({})`.
  Fastify uses `:id` params like Express → `{id}`.
- **Params/body**: Fastify route objects often carry a `schema:` field
  (JSON Schema for `params`/`querystring`/`body`/`response`) — that schema
  maps almost directly to OpenAPI parameters/requestBody/responses; prefer it
  over inferring from handler code when present.

## Hono

**Find routes:**

```bash
rg -n "\b\w+\.(get|post|put|patch|delete|all)\(\s*['\"]" --glob '*.{js,ts}' src/
# app.get('/users/:id', (c) => ...)
```

- **Method/path**: same shape as Express (`app.<verb>('/path', handler)`).
  Hono also supports `:id` params → `{id}`.
- **Params**: look for `c.req.param('id')` (path), `c.req.query('q')`
  (query), `c.req.json()` / `c.req.parseBody()` (body). If `@hono/zod-validator`
  is used, grep `zValidator\(['\"](param|query|json)['\"],` — the zod schema
  passed there is the parameter/body shape.

## Next.js — App Router

**Find route files:**

```bash
rg -l "" --glob 'app/**/route.{js,ts}'
```

Each `app/**/route.ts` is one path. Convert the directory path to a URL:
strip the `app/` prefix and trailing `/route.ts`, convert `[param]` →
`{param}`, `[...slug]` → `{slug}` (catch-all — note as such in the
description), and drop route-group segments in parens, e.g. `(marketing)`.

```bash
rg -n "^export (async )?function (GET|POST|PUT|PATCH|DELETE)" app/**/route.ts
```

- **Method**: the exported function name is the HTTP verb.
- **Params**: dynamic segments become path params. Query params: grep the
  handler for `request.nextUrl.searchParams.get(`. Body: grep for
  `await request.json()` and any zod/valibot schema parsing it right after.

## Next.js — Pages Router (API routes)

**Find route files:**

```bash
rg -l "" --glob 'pages/api/**/*.{js,ts}'
```

Path = file path under `pages/api/` with `.ts`/`.js` stripped, `[param]` →
`{param}`. `index.ts` maps to the parent directory path.

```bash
rg -n "req\.method" pages/api/**/*.ts
```

- **Method**: usually an `if (req.method === 'POST')` branch inside a single
  default-exported handler — one file can serve multiple methods; each
  branch is a separate OpenAPI operation on the same path.
- **Params**: `req.query.<name>` (also carries dynamic route params in the
  Pages Router), `req.body`.

## React Router (route modules / data router)

**Find route definitions:**

```bash
rg -n "path:\s*['\"]" --glob 'routes.{ts,tsx}' app/ src/
rg -n "createBrowserRouter|createRoutesFromElements" --glob '*.{ts,tsx}' src/ app/
```

React Router route modules are primarily for UI, but data routes with
`loader`/`action` exports double as an API surface (framework mode):

```bash
rg -n "^export (const|async function) (loader|action)" app/routes/**/*.tsx
```

- **Path**: the `path:` field in the route config, or (framework mode) the
  filename convention (`app/routes/users.$id.tsx` → `/users/:id` →
  `{id}`).
- **Method**: `loader` → GET, `action` → handles POST/PUT/PATCH/DELETE — grep
  the action body for `request.method` branching if it supports more than
  one write verb.
- **Params**: `params.id` inside `loader`/`action`; query via
  `new URL(request.url).searchParams`; body via `await request.formData()` or
  `await request.json()`.

## General tips

- Always resolve router mount prefixes (`app.use('/api/v1', router)`) before
  recording a path — otherwise the spec paths won't match real URLs.
- When a validation library (zod, joi, yup, JSON Schema) wraps the handler,
  prefer deriving the OpenAPI parameter/requestBody schema from that
  validator over re-deriving it from ad-hoc property access — it's already
  the structured source of truth.
- If a path is registered in more than one file (e.g. re-exported router),
  de-duplicate by `(method, path)` before diffing against the spec.
