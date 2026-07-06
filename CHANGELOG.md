# Changelog

All notable changes to claude-code-harness. Semver via git tags.

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
