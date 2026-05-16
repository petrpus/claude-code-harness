# Architecture

## Three-layer model

```
┌─────────────────────────────────────────┐
│  L1: Anthropic built-in (CLI)           │   /update-config, /loop, /init, /review, …
│  L2: claude-code-harness (this plugin)  │   Pocock + Vercel + own orchestration + generic hooks
│  L3: project .claude/ (per-repo)        │   only domain-specific skills/agents/hooks
└─────────────────────────────────────────┘
```

L1 ships with Claude Code. L3 stays in each repo. L2 is this plugin — same harness for every code project.

## Plugin layout

```
.claude-plugin/plugin.json     # manifest (name, description, author)
skills/<name>/SKILL.md         # auto-discovered by Claude Code
agents/<name>.md               # auto-discovered
hooks/hooks.json               # hook registration
hooks/*.sh                     # hook scripts (bash)
templates/                     # files copied into projects on first install
scripts/                       # tooling for ad-hoc maintenance (Pocock sync, etc.)
docs/                          # this folder
```

`${CLAUDE_PLUGIN_ROOT}` is the path to this plugin at runtime — used in `hooks.json` to reference hook scripts.

## Conventions assumed by skills

Skills baked here assume:

| Convention | Where it shows up |
|---|---|
| GitHub Issues for tracking | `next`, `to-issues`, `triage`, `implement-issue` |
| `gh` CLI authenticated | same |
| `CLAUDE.md` at repo root (project memory + entry point) | most skills |
| `CONTEXT.md` for shared domain glossary (optional) | `grill-with-docs`, `improve-codebase-architecture`, `zoom-out` |
| `docs/adr/` for architectural decision records | `grill-with-docs`, `improve-codebase-architecture` |
| `tmp/.last-verify-status` written by `npm run verify` (or `pnpm verify`) — content is `ok`, `fail`, or absent | `inject-git-context.sh`, `on-stop.sh`, `pre-commit-gate.sh` |
| Feature branches off `main`/`master`, no direct commits to default branch | `pre-bash.sh` |
| `.env`, lock files (`pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`) are never edited via agent | `pre-edit.sh` |

If a project breaks a convention, the corresponding skill/hook gets less useful — but the rest keep working.

## What's NOT in the harness (and why)

- **Project-specific gates** like blocking edits to auto-generated docs (`docs/product/`) or warning on `docs/spec/` changes — those are project-specific and live in per-repo `pre-edit.local.sh`.
- **Domain skills** like `build-client-html`, `port-from-agenius`, `regenerate-product-docs` — too project-specific to share.
- **Anthropic built-ins** like `/loop`, `/init`, `/review` — already shipped by Claude Code.

## Versioning + sync

- Semver tags on the repo (`v0.1.0`, `v0.2.0`, …).
- Pocock upstream sync is **manual + ad-hoc** — see `docs/pocock-sync-log.md` for state.
- Breaking changes (e.g. removing a skill, renaming a hook event) get a major bump and a CHANGELOG note.
