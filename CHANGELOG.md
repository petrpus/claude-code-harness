# Changelog

All notable changes to claude-code-harness. Semver via git tags.

## [Unreleased]

### Fixed
- `autopilot/loop.sh`: BUILD's `--allowedTools` allowlist mirrored a JS project
  template, so a repo whose verify is its own script (`./scripts/verify.sh`) had
  that call **denied** — the BUILD prompt told the model to run verify and the
  permission layer refused, leaving every slice unprovable before the runner's
  own gate. The resolved verify command is now granted explicitly, plus a new
  `--extra-allowed-tools` flag for run-specific grants.

## [0.3.0] — 2026-07-24

Upstream re-sync + the harness's own verify gate + agentic doctrine (PRD 0001,
slices S0–S5).

### Added
- `scripts/verify.sh` — the harness's own Verify gate: `check-consistency.sh` +
  a stdin-JSON **hook test matrix** (guard exit codes asserted — block=2,
  allow=0, via throwaway repos so branch-dependent guards are deterministic) +
  a `bash -n` syntax floor. Writes `tmp/.last-verify-status` (`ok`) in the
  format the freshness hooks read. Run before every PR; autopilot's
  machine-verify gate.
- `skills/resolving-merge-conflicts/` — new vendored Pocock skill.
- `templates/require-verify-before-stop.sh` — **opt-in** Stop-hook verify gate
  for unattended runs (exit 2 until verify is a fresh `ok`). Never wired into
  `hooks/hooks.json`; opt-in only (ADR-0002).
- `docs/architecture.md`: "Verifying the harness itself", "Verification tiers",
  and "Decomposition doctrine" (single agent by default; subagents only for
  context protection / parallelization / specialization; `verifier` as the
  sanctioned verification-subagent pattern; cites official Anthropic sources).

### Changed
- **Vendor re-sync to `ed37663`** (pocock) / `e173b8c` (vercel):
  - `to-issues` (← upstream `to-tickets`): blocking edges, one-context-window
    slice sizing, prefactoring-first, expand–contract for wide refactors (incl.
    integration-branch variant); dropped HITL/AFK typing. Kept the `to-issues`
    name (local patch) and GitHub-Issues-via-`gh` wording.
  - `to-prd` (← upstream `to-spec`): seams-first step (prefer existing seams,
    highest possible, ideal one). Kept PRD terminology + name.
  - `find-skills`: `--owner` scope flag; dropped the removed `skills check` line.
  - `docs/pocock-sync-log.md`: re-survey at `ed37663`, rename local patches,
    `disable-model-invocation` decision (not adopted), watch list.
- `skills/implement-issue/`: BUILD adopts the test cadence — typecheck + single
  test files continuously; full suite once at end of BUILD.
- `skills/write-a-skill/`: progressive-disclosure checklist — SKILL.md < 500
  lines, reference files one level deep, TOC in long refs, third-person
  description, gerund naming.
- `skills/autopilot/`: MAY enable the opt-in Stop gate for a run, MUST remove it
  on run end.
- README + `docs/guide.html` refreshed for 0.3.0.

## [0.2.1] — 2026-07-06

Documentation & distribution polish on top of 0.2.0.

### Added
- `docs/guide.html` — self-contained, offline, theme-aware visual guide (content
  map, install, six typical workflows, the autopilot gate pipeline, model-tiering
  table, best practices), with a repo link in the topbar and footer.
- `docs/index.html` — forwards to the guide so a GitHub Pages site served from
  `/docs` lands on it.
- README: Credits & acknowledgements crediting Matt Pocock (`mattpocock/skills`),
  Vercel Labs (`vercel-labs/skills`), Archive228 (`loopkit`, ideas re-engineered),
  and Anthropic (Claude Code); link to the guide.

### Notes
- GitHub Pages must be enabled once by the repo owner (Settings → Pages → Deploy
  from a branch → `main` / `/docs`). An Actions-based auto-enable was attempted
  and removed: the default `GITHUB_TOKEN` can't create a Pages site.

## [0.2.0] — 2026-07-06

The "autonomous harness" release — fuses a re-sync of the vendored Pocock skills
with ideas re-engineered from `Archive228/loopkit` and a set of own skills for
safe, cost-conscious long autonomous runs.

### Fixed
- **Guard hooks were silent no-ops.** `pre-edit`/`pre-bash`/`pre-commit-gate`
  read `$CLAUDE_TOOL_*` env vars that Claude Code never sets and "blocked" with
  exit 1 (which doesn't block). Rewritten against the real contract: tool input
  is JSON on stdin; PreToolUse blocks with exit 2. New `hooks/lib.sh` parses
  stdin via jq (fail-open without jq). Portable `stat`, no `set -e`.
- `pre-bash` guards now catch compound-command evasions (`cd x && git push`,
  `git -C . push`, `env FOO=1 git push`) via segment-split + word-boundary
  matching, and `.env.example` is no longer mis-blocked as a secret.
- `implement-issue` referenced a `typescript-expert` subagent that was never
  shipped — removed.
- `harness-doctor`'s stale-skill list omitted `codebase-design`,
  `domain-modeling`, and `worklog` — fixed, plus new skills, the verifier agent,
  and a jq check.

### Added
- **autopilot** — controlled long autonomous runs: fresh `claude -p` per
  iteration with state on disk, hard gates (sentinel, machine verify, secret
  scan, adversarial haiku verifier), iteration/time/budget caps, per-call
  timeout, git checkpoints, stuck-detection with auto-replan, concurrency lock,
  and a JSONL run log. `loop.sh` + `LOOP-PROTOCOL.md` + templates.
- **verifier** agent (haiku) — adversarial 11-shortcuts checklist, fail-closed
  JSON verdict; used as autopilot's semantic gate.
- **cost-discipline** (doctrine), **usage-report** (ccusage + run-log spend),
  **project-infra** (verify/env/CI/devcontainer provisioning), **openapi-sync**
  and **code-map** (documentation), and **docs/model-policy.md** (model tiering).
- **session-log.sh** Stop hook → `tmp/session-log.jsonl`; `/worklog` folds it in.
- Vendored **grilling** + **research** from Pocock `66f92b6`; `caveman` frozen
  (removed upstream).
- `LICENSE` (MIT), this `CHANGELOG.md`, and `scripts/check-consistency.sh`
  (repo self-verify).

### Changed
- `code-reviewer` agent pinned to `model: sonnet`.
- Vendored Pocock skills reviewed against upstream `66f92b6`; see
  `docs/pocock-sync-log.md` for per-skill status, local-patch dir renames, and
  the duplicated-resource lockstep table.
- Removed the stale internal `HANDOFF.md` (superseded by this changelog + docs).

## [0.1.0] — 2026-05/06

Initial harness: 15 vendored Pocock skills, 1 Vercel skill (find-skills), own
orchestration (next, commit-agent, implement-issue, start-feature,
migration-check, worklog, harness-init, harness-doctor), the code-reviewer
agent, git/dev hooks, and the self-marketplace manifest.
