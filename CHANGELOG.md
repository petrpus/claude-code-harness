# Changelog

All notable changes to claude-code-harness. Semver via git tags.

## [Unreleased]

### Fixed
- **The push-from-main guard blocked pushing a tag**, which is this repo's own
  documented release step (`v0.x.0` on the merge commit on `main`) — found by
  hitting it while cutting 0.4.0. A tag doesn't advance a branch, so the rule
  has nothing to say about it. Tag-only pushes are recognised in their common
  forms (`origin v1.2.3`, `origin refs/tags/v1.2.3`, `--tags`, `origin tag
  v1.2.3`) and allowed; anything that could still move a branch is not —
  `--follow-tags` (which pushes commits too), a mixed branch+tag push, a bare
  name that resolves to a branch or is ambiguous, and force-pushing a tag all
  stay blocked.

## [0.4.0] — 2026-08-01

The repo-map layer (PRD 0001, M-slices M1–M2) plus a round of hardening on the
autopilot loop and the guard hooks.

Note on scope: `skills/repo-map/` ships here for the first time, so the defects
found and fixed while building it are not listed as fixes — no released version
ever had them. Its accuracy limits are documented in the skill itself. The
Fixed section below is regressions against 0.3.0 only.

### Added
- **`skills/repo-map/`** — a machine-readable file-level import graph on disk
  (`tmp/repo-map.json`, Schema v1) that agents query instead of grepping the
  tree: `deps`, `rdeps`, `hotspots`, `entry-points`, `stats`, all jq-expressible.
  Two backends under one schema — a zero-dependency scan of our own (JS/TS and
  Python, tsconfig/jsconfig alias resolution, comment-aware), and an adapter
  over an existing [Graphify](https://graphify.net) `graph.json` when a project
  already has one. Detection only, never an install; Graphify's MCP server stays
  out of scope per ADR-0001. Staleness is a provenance stamp plus lazy
  regeneration — including a `worktree_sig` so uncommitted edits, the state an
  agent queries from for most of a task, don't serve a stale map. Scanning and
  resolution run in batched `awk`: 6,000 files in about a second, which is what
  makes "regenerate on any drift" affordable. See
  `docs/adr/0004-graphify-as-optional-repo-map-backend.md`.
- **Three test harnesses**, each for a class the repo had no coverage for:
  - `scripts/test-fault-injection.sh` — every tool the repo-map generator shells
    out to, times three fault modes, asserting it can never produce a wrong
    graph at exit 0. Written after the same "broken dependency → plausible,
    silently wrong output" defect recurred three times in different clothes.
  - `scripts/test-hook-faults.sh` — the same sweep with the contract inverted,
    since hooks fail open by design: guards must block or announce, advisory
    hooks must always exit 0, never hang, and never write to stdout.
  - `scripts/test-autopilot-loop.sh` — drives `loop.sh` end-to-end against a
    stub `claude`, so the runner's gating decisions are exercised without cost.
    The loop previously had no test at all.
- **Runtime self-checks in `build-repo-map.sh`** — rather than predict how a
  tool can break, it runs its real awk programs and jq expression over a known
  input and compares the known answer, and cross-checks enumeration against
  `git ls-files`. Catches the mode that defeats every dependency guard: a tool
  that exits 0 and prints nothing.
- `skills/autopilot/allowlist.sh` — the BUILD phase's tool-grant derivation,
  extracted so `verify.sh` can assert it directly. It is a permission surface
  and had no test.

### Changed
- `skills/code-map/` stops running its own import scan and becomes a renderer
  over `tmp/repo-map.json`, so there is one scan implementation and two outputs.
- `scripts/verify.sh` grows the three sweeps above plus a grants assertion.

### Fixed
- **autopilot could not finish a plan of more than three slices.** BUILD does
  exactly one plan item per iteration, so `STATUS: done` is false by
  construction until the last one — and the loop counted that as a gate failure.
  Every intermediate iteration looked identical to a real failure, carried the
  same fingerprint, and tripped the stuck detector after three. The loop
  rewarded doing everything at once, inverting the slice-by-slice discipline it
  exists to enforce. Progress is measured from ticked checkboxes now, and
  `STATUS: done` only ends the run.
- **Intermediate autopilot iterations were never verified.** The completion
  check short-circuited machine verify, the secret scan and the semantic
  verifier, so incremental work was committed as "wip" with none of them having
  run. All three run every iteration.
- **autopilot's BUILD allowlist named only a JS toolchain**, so in a repo whose
  verify is its own script the call the BUILD prompt tells the model to make was
  denied outright, leaving every slice unprovable. The resolved verify command
  is granted explicitly — and narrowly: an interpreter-prefixed command
  (`bash scripts/verify.sh`) no longer widens the grant into arbitrary shell.
  New `--extra-allowed-tools` for run-specific grants.
- **Guard hooks stopped guarding, silently, when a tool they use broke.**
  Failing open without `jq` is deliberate; failing open quietly was not. And
  `jq` was never the only way in — `pre-bash.sh` split its input with
  `tr | sed`, so a broken `sed` produced no segments, nothing matched, and
  `rm -rf /` was allowed at exit 0 without a word. The segmenter is pure bash
  now, and any remaining fall-open path announces itself on stderr.
- **A broken `git` disabled the push-from-main guard with no trace** — the one
  rule `settings.json` deny cannot express, since it needs the branch. A `git`
  printing nonsense returned a branch name that merely looked valid, making
  "not main" indistinguishable from "safe".
- **`pre-commit-gate.sh` could exit non-zero**, which an advisory hook must never
  do: a `stat` or `date` exiting 0 while printing nothing fed a bare word into
  `$(( ))`, and `set -u` killed the hook on the unset result. `mtime_of` and the
  new `now_epoch` always return an integer.

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
