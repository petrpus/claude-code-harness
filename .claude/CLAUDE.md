# CLAUDE.md — code-harness (repo `claude-code-harness`)

Context for agents working **on this repo**. This repo is itself a Claude Code
plugin (a "harness") distributed via an Anthropic plugin marketplace, not an
application. There is no app to run; the deliverable is the plugin's skills,
agent, and hooks.

## What this is

A universal code-dev harness for Claude Code. Installed once per machine
(`/plugin install code-harness@claude-code-harness`), it makes a curated set of
skills, two agents, and a few git/dev safety hooks available in every project. A
consumer project's own `.claude/` then holds **only** project-specific things.

Names: the plugin is `code-harness` (components are namespaced `code-harness:*`);
the repo and its self-marketplace stay `claude-code-harness`. Plugin names
starting with `claude-` are reserved by Claude Code, so 0.7.0 renamed the plugin
through the marketplace's append-only `renames` map (ADR-0014). Never rename the
plugin by editing `name` alone.

## Layout

```
.claude/CLAUDE.md      # this file — contributor context; a CLAUDE.md at the plugin
                       # root (= repo root) is never loaded and fails validate --strict
.claude-plugin/
  marketplace.json    # self-marketplace manifest (this repo is its own marketplace) + renames
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
3. **Own** — authored here, no upstream. Workflow: `next`, `commit-agent`,
   `implement-issue`, `start-feature`, `migration-check`, `worklog`,
   `harness-init`, `harness-doctor`. Autonomy & infra: `autopilot` (loop engine),
   `deliver` (Map → integration PR), `cost-discipline`, `usage-report`,
   `project-infra`, `openapi-sync`, `repo-map`, `code-map`.
   Plus agents `code-reviewer` (sonnet) + `verifier` (haiku). Loopkit ideas were
   re-engineered, not vendored (see sync-log's Loopkit section).

### Vendoring discipline (important)

Sync is **manual, never automated**. `docs/pocock-sync-log.md` is the source of
truth for what is vendored and at which upstream SHA. To pull an update:

1. Inspect the upstream repo at its target SHA or release tag. In this
   environment the GitHub API, github.com pages and codeload tarballs are
   proxy-blocked, but `git clone --filter=blob:none https://github.com/<owner>/<repo>.git`
   works and gives full history — diff tags/SHAs locally. Per-file
   `raw.githubusercontent.com/<owner>/<repo>/<sha>/<path>` is the fallback
   (sleep/retry on 429). Record **commit** SHAs (not `git ls-tree` tree hashes).
2. Diff `SKILL.md` (and any bundled resource files) against our vendored copy.
3. Copy what you want, then update the sync-log row: new SHA, review date, note
   what changed. Record local dir-name patches (e.g. `diagnose` ←
   `diagnosing-bugs`) explicitly.
4. Commit as `vendor: sync <skill> from <short-sha>`. For a **broad re-sync to
   one SHA**, a single `vendor: re-sync <source> to <short-sha>` commit is more
   auditable than many per-skill commits — bulk is the exception the sync-log
   procedure allows.

When vendoring, copy the **whole skill dir** including resource files (e.g.
`ADR-FORMAT.md`, `DEEPENING.md`). Keep frontmatter as upstream unless it conflicts
with our conventions below. We deliberately **skip** `setup-matt-pocock-skills` —
its bootstrapped conventions are baked into the skills and documented here instead.

### Known upstream mismatch

Vendored `triage` still tells the reader to run `/setup-matt-pocock-skills`,
which we skip on purpose (above). This dangling reference is a known upstream
mismatch; leave it as vendored and do not "fix" it locally.

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
  `/deliver` adds an integration level: `integration/<slug>` off `main`, per-issue
  branches off the integration branch, and one final integration PR into `main`.

## Hooks model

Wired in `hooks/hooks.json` as `bash "${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh"`
(quoted placeholder, run through `bash` — see `docs/architecture.md` § Plugin
layout for why not exec form). **All hooks read
tool input as JSON on stdin** (via `hooks/lib.sh`) — NOT from `$CLAUDE_TOOL_*`
env vars (those don't exist; assuming them is what made the pre-0.2.0 guards
silent no-ops). PreToolUse blocks with **exit 2**. See `docs/architecture.md` §
Hook contract.

- `PreToolUse` Write|Edit → `pre-edit.sh` (block `.env` + lockfile edits; allow `.env.example`)
- `PreToolUse` Bash → `pre-bash.sh` (push-from-main / force-push / rm -rf guards,
  segment-split for compound commands), `pre-commit-gate.sh` (verify-freshness warning)
- `UserPromptSubmit` → `inject-git-context.sh` (branch / dirty / verify status)
- `Stop` → `on-stop.sh` (uncommitted-changes + stale-verify reminders),
  `session-log.sh` (append per-turn JSONL to `tmp/session-log.jsonl`)

`hooks/lib.sh` parses stdin with `jq` only and **fails open** without it (the
hard layer is `settings.json` deny). Guard changes must keep the stdin-JSON
contract and the exit-2 block semantics. Run `scripts/check-consistency.sh` and
the hook test matrix (`echo '{"tool_input":{"command":"…"}}' | hooks/pre-bash.sh`)
after touching hooks.

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

## Skill frontmatter rules

`scripts/check-consistency.sh` lints every `skills/*/SKILL.md` and `agents/*.md`
frontmatter: it must parse as YAML (quote any value containing `: `, or use a
`>-` block — an unparseable header is still loaded by Claude Code but silently
skipped by `npx skills`), `name` must equal the directory and match the Agent
Skills name rule, `description` ≤ 1024 characters, keys must be known Agent
Skills / Claude Code fields, and the descriptions Claude sees in every session
(skills without `disable-model-invocation`) must fit the listing budget set in the
script. Grow that budget only on purpose. Paid or long-running runners
(`autopilot`, `deliver`) and `harness-init` are user-invoked only (ADR-0015);
never add `disable-model-invocation` to a skill another skill composes
(`to-issues`, `to-prd`, `grill-*`, `triage`) — it blocks skill-to-skill calls too.

## Versioning

Semver in `plugin.json` + git tags; `CHANGELOG.md` is the human record,
`scripts/check-consistency.sh` asserts they agree. Tag `v0.x.0` on the merge
commit on `main`, never on a feature branch. The harness generates CI/CD for
*consumer* projects (`/project-infra ci`); the harness repo runs its own
`.github/workflows/verify.yml` (`scripts/verify.sh`, then
`claude plugin validate --strict` through `npx`).
