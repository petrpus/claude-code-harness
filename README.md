# claude-code-harness

Universal code-dev harness for [Claude Code](https://docs.claude.com/claude-code). One repo, distributed as an Anthropic plugin, used across all code-development projects.

## What's inside

| Area | What |
|---|---|
| **Skills (Pocock-derived, vendored)** | `caveman`, `codebase-design`, `diagnose`, `domain-modeling`, `grill-me`, `grill-with-docs`, `grilling`, `handoff`, `improve-codebase-architecture`, `prototype`, `research`, `tdd`, `to-issues`, `to-prd`, `triage`, `write-a-skill`, `zoom-out` |
| **Skills (Vercel Labs)** | `find-skills` |
| **Skills (own — workflow)** | `next`, `commit-agent`, `implement-issue`, `start-feature`, `migration-check`, `worklog`, `harness-init`, `harness-doctor` |
| **Skills (own — autonomy & infra)** | `autopilot` (controlled long autonomous runs), `cost-discipline` (token/tool/fanout doctrine), `usage-report` (spend), `project-infra` (verify/CI/devcontainer), `openapi-sync`, `code-map` |
| **Agents** | `code-reviewer` (independent cold-diff review, sonnet), `verifier` (adversarial 11-shortcuts gate, haiku) |
| **Hooks** | `inject-git-context` (UserPromptSubmit), `on-stop` + `session-log` (Stop), `pre-bash` (push-from-main / force-push / rm -rf guards), `pre-commit-gate` (verify freshness warn), `pre-edit` (`.env` + lockfile blocks); all parse stdin JSON via `hooks/lib.sh` |

Pocock-derived content is vendored ad-hoc from [`mattpocock/skills`](https://github.com/mattpocock/skills). Ideas (not files) from [`Archive228/loopkit`](https://github.com/Archive228/loopkit) were re-engineered into `autopilot`, `verifier`, and `cost-discipline`. See `docs/pocock-sync-log.md` for provenance and upstream SHAs.

## Long autonomous runs (autopilot)

For controlled multi-step work that runs unattended without risking quality or
safety:

```bash
/project-infra verify          # ensure an objective verify command exists
# scaffold tmp/autopilot/PROMPT.md from a PRD or issue, then:
${CLAUDE_PLUGIN_ROOT}/skills/autopilot/loop.sh --max-iterations 10 --budget-usd 10
```

Each iteration is a fresh `claude -p` with state on disk; the runner enforces
hard gates (machine verify + secret scan + adversarial haiku verifier), caps
(iteration/time/budget), git checkpoints, and a JSONL run log. Cheap models
verify, mid implements, top plans — see `docs/model-policy.md`.

## Install

In any code-dev project:

```bash
/plugin marketplace add git@github.com:petrpus/claude-code-harness.git
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

## Guide

A full visual guide — content map, usage, typical workflows, and best practices —
lives at [`docs/guide.html`](docs/guide.html) (self-contained, offline, open it
in any browser).

## Credits & acknowledgements

This harness stands on the work of others. Vendored skills keep their upstream
authorship; the sync log (`docs/pocock-sync-log.md`) records exactly what came
from where and at which commit.

- **[Matt Pocock](https://github.com/mattpocock) — [`mattpocock/skills`](https://github.com/mattpocock/skills)**
  — the vendored engineering & productivity skills (`codebase-design`,
  `domain-modeling`, `diagnose`, `tdd`, `to-prd`, `to-issues`, `triage`,
  `grill-*`, `grilling`, `research`, `improve-codebase-architecture`,
  `prototype`, `handoff`, `write-a-skill`, `zoom-out`, `caveman`) and the
  CONTEXT.md + ADR + verify-loop conventions the harness assumes.
- **[Vercel Labs](https://github.com/vercel-labs) — [`vercel-labs/skills`](https://github.com/vercel-labs/skills)**
  — the `find-skills` skill and the `npx skills` ecosystem.
- **[Archive228](https://github.com/Archive228) — [`loopkit`](https://github.com/Archive228/loopkit) (MIT)**
  — the adversarial-verify "shortcuts" checklist, the fresh-context loop with
  state on disk, and the context-budget / tool-restraint / subagent-fanout
  doctrine. These **ideas were re-engineered** (not copied) into `autopilot`,
  the `verifier` agent, and `cost-discipline`.
- **[Anthropic](https://www.anthropic.com) — [Claude Code](https://docs.claude.com/claude-code)**
  — the platform this plugin extends (skills, agents, hooks, headless `claude -p`).

Own skills, agents, hooks, and the loop engine are authored in this repo.
Licensed under [MIT](LICENSE).

## Versioning

Semver in `plugin.json` + git tags; `CHANGELOG.md` is the human record and
`scripts/check-consistency.sh` asserts the two agree. Tag on the merge commit on
`main`, never on a feature branch. The harness can generate CI/CD for *consumer*
projects (`/project-infra ci`); the harness repo itself has no pipeline yet.
