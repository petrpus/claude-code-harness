# CLAUDE.md — claude-code-harness

Context for agents working **on this repo**. This repo is itself a Claude Code
plugin (a "harness") distributed via an Anthropic plugin marketplace, not an
application. There is no app to run; the deliverable is the plugin's skills,
agent, and hooks.

## What this is

A universal code-dev harness for Claude Code. Installed once per machine
(`/plugin install claude-code-harness`), it makes a curated set of skills, one
review agent, and a few git/dev safety hooks available in every project. A
consumer project's own `.claude/` then holds **only** project-specific things.

## Layout

```
.claude-plugin/
  marketplace.json    # self-marketplace manifest (this repo is its own marketplace)
  plugin.json         # the plugin manifest
skills/<name>/SKILL.md # one dir per skill; bundled resources sit flat alongside SKILL.md
agents/                # code-reviewer.md (independent cold-diff review)
hooks/                 # *.sh + hooks.json wiring
templates/             # project-settings.template.json (baseline for consumer projects)
docs/                  # architecture.md, install.md, pocock-sync-log.md
```

## Skill provenance — three buckets

1. **Vendored from Pocock** (`mattpocock/skills`) — cherry-picked by hand.
2. **Vendored from Vercel Labs** (`vercel-labs/skills`) — currently `find-skills`.
3. **Own** — authored here, no upstream (`next`, `commit-agent`, `implement-issue`,
   `start-feature`, `migration-check`, `worklog`, `harness-init`, `harness-doctor`).

### Vendoring discipline (important)

Sync is **manual, never automated**. `docs/pocock-sync-log.md` is the source of
truth for what is vendored and at which upstream SHA. To pull an update:

1. Clone/inspect the upstream repo at its current HEAD.
2. Diff `SKILL.md` (and any bundled resource files) against our vendored copy.
3. Copy what you want, then update the sync-log row: new SHA, new sync date, note
   what changed.
4. Commit as `vendor: sync <skill> from <short-sha>`.

When vendoring, copy the **whole skill dir** including resource files (e.g.
`ADR-FORMAT.md`, `DEEPENING.md`). Keep frontmatter as upstream unless it conflicts
with our conventions below. We deliberately **skip** `setup-matt-pocock-skills` —
its bootstrapped conventions are baked into the skills and documented here instead.

## Conventions the skills assume (for consumer projects)

- **Issue tracker**: GitHub Issues via the `gh` CLI (not GitHub MCP). Skills like
  `to-issues`, `triage`, `next`, `implement-issue` call `gh issue ...`.
- **Domain language**: `CONTEXT.md` (glossary only — no implementation detail) +
  `docs/adr/` for architectural decisions. `CONTEXT-MAP.md` at root signals a
  multi-context repo. `domain-modeling` maintains these; `codebase-design` supplies
  the deep-module vocabulary.
- **Build / verify**: `npm run verify` or `pnpm verify`. Hooks read
  `tmp/.last-verify-status` for freshness.
- **Branch model**: feature branches off `main`. The pre-bash hook blocks
  `git push` from `main`/`master` and blocks force-push and broad `rm -rf`.

## Hooks model

Wired in `hooks/hooks.json` against `${CLAUDE_PLUGIN_ROOT}`:

- `PreToolUse` Write|Edit → `pre-edit.sh` (block `.env` + lockfile edits)
- `PreToolUse` Bash → `pre-bash.sh` (push-from-main / force-push / rm -rf guards),
  `pre-commit-gate.sh` (verify-freshness warning)
- `UserPromptSubmit` → `inject-git-context.sh` (branch / dirty / verify status)
- `Stop` → `on-stop.sh` (uncommitted-changes + stale-verify reminders)

Hook rules:
- Hooks must degrade gracefully outside a git repo and when the verify-status file
  is absent — never hard-fail a consumer project that doesn't follow our conventions.
- `UserPromptSubmit` / `Stop` hooks should **always exit 0**. A non-zero exit there
  can disrupt the turn; injection/reminders are best-effort, not gates.
- Avoid `set -e` + `cmd | head` patterns: SIGPIPE under `pipefail` can abort the
  script before it prints. Guard those pipes.
- Don't emit reserved harness tags (e.g. `<system-reminder>`) from hook output; use
  a plain, non-reserved label for injected context.

## This repo does NOT need MCP servers

Nothing here calls MCP. GitHub interaction goes through the `gh` CLI. If a web/mobile
Claude Code session attaches account-level MCP connectors, that is environment
config, unrelated to this repo, and only adds session-init overhead.

## Versioning

Semver via git tags. No CI/CD yet.
