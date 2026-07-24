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
scripts/                       # verify.sh (the gate) + check-consistency.sh
docs/                          # this folder
```

`${CLAUDE_PLUGIN_ROOT}` is the path to this plugin at runtime — used in `hooks.json` to reference hook scripts. Note it is set **only for hook processes**; a plain Bash script (e.g. `skills/autopilot/loop.sh`) must resolve its own location from `${BASH_SOURCE[0]}`, not from `$CLAUDE_PLUGIN_ROOT`.

## Hook contract

Claude Code passes hook input as a **JSON object on stdin** — e.g.
`{"cwd":"…","tool_name":"Bash","tool_input":{"command":"git push"}}`. It does
**not** set `$CLAUDE_TOOL_*` env vars (a pre-0.2.0 mistake that made every guard
a silent no-op). Exit-code semantics:

| Event | Exit 0 | Exit 2 | stdout |
|---|---|---|---|
| `PreToolUse` | allow | **block** (stderr → Claude) | — |
| `UserPromptSubmit` | proceed | (avoid) | injected into model context |
| `Stop` | always | (avoid) | transcript-visible to the user, **not** fed to the model |

`hooks/lib.sh` centralizes stdin parsing. It uses `jq` only — there is no
sed/grep JSON parser, because regex-scraping arbitrary shell out of
`tool_input.command` both false-blocks and false-allows. Without `jq` the guards
**fail open** (allow) and `harness-doctor` flags the missing dependency; the hard
security layer is `settings.json` deny, which needs no jq. No hook uses `set -e`.

## Verifying the harness itself

The harness demands an objective Verify gate from consumer projects and now has
its own: `scripts/verify.sh`. It composes three offline layers —
`scripts/check-consistency.sh` (structural invariants), a **hook test matrix**
(each guard hook fed representative stdin-JSON with its exit code asserted —
block cases exit 2, allow cases exit 0, per the Hook contract above), and a
`bash -n` syntax floor over every `*.sh`. On a green run it writes `ok` to
`tmp/.last-verify-status` in the format the freshness hooks read
(`pre-commit-gate.sh`, `on-stop.sh`), so their staleness reminders go quiet.
Run it before every PR; the autopilot loop runs it as its machine-verify gate.

## Verification tiers: reminders by default, opt-in gate for unattended runs

Two tiers, chosen by how much autonomy the session has:

- **Reminders (default).** The Stop / pre-commit hooks (`on-stop.sh`,
  `pre-commit-gate.sh`) only *warn* on a stale or failing verify and **always
  exit 0**. A blocking Stop hook would hard-fail every consumer project that
  doesn't follow our verify convention, so the default never blocks.
- **Hard gate (opt-in).** For unattended runs, `templates/require-verify-before-stop.sh`
  is a Stop hook that **exits 2** until `tmp/.last-verify-status` reports a fresh
  `ok`, forcing verify to run before the turn ends. It is deliberately an
  exception to "Stop hooks always exit 0" and is safe only because it is opt-in:
  never wired into `hooks/hooks.json`, enabled consciously by a project (or by
  `autopilot` for the duration of a run), and Claude Code lifts the block after
  8 consecutive refusals so it cannot deadlock. See **ADR-0002**.

## Policy layering (single source of truth)

Three layers, each owning its rule kind — don't duplicate a rule across them:

- **L1 `settings.json` deny** — static string patterns (force-push, `rm -rf /`,
  reading/writing `.env`).
- **L2 `hooks/pre-bash.sh`** — context-dependent logic a static pattern can't
  express, chiefly "push **from** main" (needs the current branch).
- **L3 skills** (`commit-agent`) — workflow advice that references, never
  re-implements, L1/L2.

## autopilot state model

`skills/autopilot/` runs long autonomous work as a loop of **fresh `claude -p`
sessions** with all state on disk under `tmp/autopilot/` (`PROMPT.md` charter,
`IMPLEMENTATION_PLAN.md` + `STATUS:` sentinel, `MEMORY.md`, `FEEDBACK.md`,
`status.json`, `run-<id>.jsonl`, `lock`). The **runner** — not the model —
enforces the gates: it re-runs the verify command itself, scans the diff for
secrets, and has a cheap haiku `verifier` agent adversarially check the diff
before an iteration counts as done. See `skills/autopilot/LOOP-PROTOCOL.md` and
`docs/model-policy.md`.

## Decomposition doctrine (when to reach for subagents)

The harness defaults to **a single agent in one context**. Reach for subagents
only when there is a concrete reason:

- **Context protection** — a subtask would flood the main context with output
  you don't need to keep (broad searches, reading many files for one
  conclusion). The subagent returns the conclusion, not the file dumps.
- **Parallelization** — genuinely independent work that can run at once.
- **Specialization** — a task wants a different tool-set, model tier, or an
  adversarial stance (our `verifier` on haiku).

**Decompose by context, not by problem phase.** Do *not* split a task into a
planner → implementer → tester relay just because those are conceptual stages —
that multiplies context-handoff cost without buying isolation. Split when a
*chunk of context* can be sealed off and handed to an agent that returns a small
result. The **verification subagent** is the officially sanctioned pattern (an
independent agent that checks the primary agent's work); the harness ships it as
`agents/verifier.md` and wires it into `autopilot`.

Sources: [Building multi-agent systems — when and how](https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them),
[Effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents),
[Best practices for Claude Code](https://code.claude.com/docs/en/best-practices).
See also `skills/cost-discipline/` (the token-budget / subagent-restraint
doctrine) and `docs/research/2026-07-harness-upgrade.md` § B.

## Conventions assumed by skills

Skills baked here assume:

| Convention | Where it shows up |
|---|---|
| GitHub Issues for tracking | `next`, `to-issues`, `triage`, `implement-issue` |
| `gh` CLI authenticated | same |
| `CLAUDE.md` at repo root (project memory + entry point) | most skills |
| `CONTEXT.md` for shared domain glossary (optional) | `grill-with-docs`, `improve-codebase-architecture`, `zoom-out` |
| `docs/adr/` for architectural decision records | `grill-with-docs`, `improve-codebase-architecture` |
| `tmp/.last-verify-status` written by `npm run verify` (or `pnpm verify`) — content is `ok`, `fail`, or absent (provision with `/project-infra verify`) | `inject-git-context.sh`, `on-stop.sh`, `pre-commit-gate.sh`, `autopilot` |
| Feature branches off `main`/`master`, no direct commits to default branch | `pre-bash.sh`, `autopilot` |
| `.env`, lock files (`pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`) are never edited via agent (`.env.example` is allowed) | `pre-edit.sh` |
| `jq` available on `PATH` (guard hooks fail open without it) | `hooks/lib.sh` |

If a project breaks a convention, the corresponding skill/hook gets less useful — but the rest keep working.

## What's NOT in the harness (and why)

- **Project-specific gates** like blocking edits to auto-generated docs (`docs/product/`) or warning on `docs/spec/` changes — those are project-specific and live in per-repo `pre-edit.local.sh`.
- **Domain skills** like `build-client-html`, `port-from-agenius`, `regenerate-product-docs` — too project-specific to share.
- **Anthropic built-ins** like `/loop`, `/init`, `/review` — already shipped by Claude Code.

## Versioning + sync

- Semver in `plugin.json` + git tags (`v0.1.0`, `v0.2.0`, …). `CHANGELOG.md` is
  the human record; `scripts/check-consistency.sh` asserts the two agree.
- Tag `v0.x.0` on the **merge commit on `main`**, never on an unmerged feature
  branch. Push the tag together with `main`.
- Pocock upstream sync is **manual + ad-hoc** — see `docs/pocock-sync-log.md`.
- Breaking changes (removing a skill, renaming a hook event) get a major bump and
  a CHANGELOG note.

## CLAUDE_PLUGIN_ROOT vs CLAUDE_PROJECT_DIR (historical note)

`hooks.json` references scripts via `${CLAUDE_PLUGIN_ROOT}` (the plugin's own
path), not `${CLAUDE_PROJECT_DIR}` (the consumer repo). Using the project dir
would break the moment a project didn't vendor the hook scripts — the whole
point of shipping them in the plugin. `harness-doctor` flags any project that
re-registers these hooks under `.claude/`.
