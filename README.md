# claude-code-harness

Universal code-dev harness for [Claude Code](https://docs.claude.com/claude-code). One repo, distributed as an Anthropic plugin, used across all code-development projects.

## What's inside

| Area | What |
|---|---|
| **Skills (Pocock-derived, vendored)** | `caveman`, `diagnose`, `grill-me`, `grill-with-docs`, `handoff`, `improve-codebase-architecture`, `prototype`, `tdd`, `to-issues`, `to-prd`, `triage`, `write-a-skill`, `zoom-out` |
| **Skills (Vercel Labs)** | `find-skills` |
| **Skills (own)** | `next`, `commit-agent`, `implement-issue`, `start-feature`, `migration-check` |
| **Agents** | `code-reviewer` (independent cold diff review) |
| **Hooks** | `inject-git-context` (UserPromptSubmit), `on-stop` (Stop), `pre-bash` (push-from-main / force-push / rm -rf guards), `pre-commit-gate` (verify freshness warn), `pre-edit` (`.env` + lockfile blocks) |

Pocock-derived content is vendored ad-hoc from [`mattpocock/skills`](https://github.com/mattpocock/skills). See `docs/pocock-sync-log.md` for what we have and which upstream SHA it came from.

## Install

In any code-dev project:

```bash
/plugin marketplace add github:petrpus/claude-code-harness
/plugin install claude-code-harness
```

That's it. Skills, agent, and hooks become available immediately.

## Per-project layout (after install)

The project's own `.claude/` keeps **only** project-specific:

```
your-project/.claude/
├── settings.json                 # permissions + WebFetch allowlist + project hook wiring
├── settings.local.json           # per-machine ad-hoc allows (gitignored)
├── skills/                       # project-specific skills only (domain stuff)
├── agents/                       # project-specific agents only
└── hooks/                        # project-specific hook wrappers (e.g. *.local.sh)
```

Generic skills/agent/hooks come from the plugin.

For project settings baseline (code-dev permissions: git/pnpm/gh/docker/playwright/vitest), see `templates/project-settings.template.json` — copy-merge into your project `settings.json`.

## Conventions baked in

The skills assume:

- **Issue tracker**: GitHub Issues (uses `gh` CLI). Skills like `to-issues`, `triage`, `next`, `implement-issue` call `gh issue ...`.
- **Domain language**: `CLAUDE.md` at repo root + `CONTEXT.md` (optional) + `docs/adr/` for architectural decisions.
- **Build / verify**: `npm run verify` or `pnpm verify`. Hooks read `tmp/.last-verify-status` for freshness.
- **Branch model**: feature branches off `main`. Pre-bash hook blocks `git push` from `main`/`master`.

If your project doesn't match these, you can still install the plugin and ignore individual skills. Hooks can be disabled per-project via project `settings.json`.

## Cherry-picking from upstream Pocock

Manual, on demand. When you want to check for updates:

1. Open the upstream repo: `https://github.com/mattpocock/skills`
2. Compare against `docs/pocock-sync-log.md` SHAs.
3. For each skill, decide: take new version, take diff, or skip.
4. Update `docs/pocock-sync-log.md` with new SHA + date.

We don't use Pocock's `setup-matt-pocock-skills` installer — conventions are baked into the skills directly (see above).

## Versioning

Semver via git tags. No CI/CD yet.
