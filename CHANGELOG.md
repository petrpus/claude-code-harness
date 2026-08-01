# Changelog

All notable changes to claude-code-harness. Semver via git tags.

## [Unreleased]

### Added
- `skills/repo-map/` — a machine-readable module/dependency map
  (`tmp/repo-map.json`, Schema v1) that agents query instead of grepping the
  tree: `build-repo-map.sh` (grep backend, JS/TS + Python import scan with
  tsconfig/jsconfig alias resolution, or an adapter for an existing Graphify
  `graph.json` when one is already on disk — detection only, never a
  dependency) and `query.sh` (`deps`, `rdeps`, `hotspots`, `entry-points`,
  `stats`, with provenance-stamp staleness and lazy regeneration at read
  time). See `docs/adr/0004-graphify-as-optional-repo-map-backend.md`.

### Changed
- `skills/code-map/`: stops running its own import scan and becomes a
  renderer over `tmp/repo-map.json`, so `repo-map` owns the one scan
  implementation and `code-map` just projects it to the render shape.

### Added
- **`scripts/test-fault-injection.sh` — one invariant swept across every tool
  the `repo-map` generator shells out to**, replacing the guard-per-failure-mode
  approach that let the same defect return three times in different clothes (a
  PCRE2-less ripgrep, a missing scanner, a scanner exiting non-zero — each fix
  closing only the variant in front of it). For each tool × each fault mode
  (errors / succeeds silently / emits junk) it asserts: the generator must
  either exit non-zero or write a map whose **graph** matches the known-good
  one. Provenance is held to a weaker rule — it may degrade, but the
  degradation must be announced, since a map that quietly stops refreshing
  looks exactly like one that is always right. 39 rows; the sweep was validated
  by neutralising the new self-checks and confirming it fails, including for
  `find` and `sort`, which no hand-written guard had ever covered.
- **Runtime self-checks ("canaries") in `build-repo-map.sh`.** Rather than
  predict how a tool can break, the generator runs its real awk programs and jq
  expression over a known input and compares against the known answer, and
  cross-checks its file enumeration against `git ls-files`. Absent, failing,
  silent, or wrong-version tools all produce a wrong answer and die loudly —
  including the mode that defeated every previous guard: a tool that **exits 0
  and prints nothing**.

### Fixed
- **A present-but-failing `awk` still produced a confident, edgeless map.** The
  guard proved the binary *existed*, not that it *ran*: every `awk` call
  discarded stderr and ignored its exit status, so a broken install wrote all
  nodes, no edges, and exited 0 — the same failure the missing-scanner guard was
  added to close, reached through a different door. Every `awk` invocation is
  now status-checked and its stderr surfaced.
- **`worktree_sig` never converged once the map was tracked.** The map's own
  path was excluded from `git status` but not from `git diff HEAD`, so as soon
  as `tmp/repo-map.json` was staged or committed, each regeneration's new
  `generated_at` changed the signature that triggered it — regenerating on every
  single query, forever. Both streams now exclude it.
- **A `//` inside a string literal truncated the line.** `const u =
  "http://x"; import z from "./y"` silently lost the import, because the URL's
  `//` read as a comment opener. The comment scanner is string-aware now; a
  specifier *inside* a string literal is still harvested, which remains the
  documented ceiling.
- **`from . import sibling` pointed at the wrong file.** The imported names were
  discarded, so a submodule import was attributed to the package's
  `__init__.py` and the real module kept `fan_in == 0` — looking dead while
  being imported. Names are now resolved as modules first, with the package as
  fallback. `from ..x` deeper than the file's own directory no longer clamps at
  the repo root and matches something unrelated.
- **`repo-map`'s generator was subprocess-bound**: three `rg` calls plus three
  `sed` calls per file, then a forked `grep` against the file list per candidate
  suffix per specifier. 6,000 files took **3m03s**, which made the "regeneration
  is cheap" premise the staleness policy rests on simply false — and since
  `query.sh` regenerates lazily and synchronously, the first query after any
  commit blocked the caller for minutes. Scanning and resolution now happen in
  `awk` (batched, and using awk's associative arrays for candidate lookup):
  **6,000 files in ~0.9s**, roughly 200× faster. Ripgrep is no longer a dependency at
  all; `awk` is guarded in its place.
- **Python imports never resolved.** Every form — `from a.b import x`,
  `import a.b`, `from .b import x` — reached the resolver as a bare specifier,
  and bare specifiers resolve only through a tsconfig alias no Python project
  has, so a Python repo got a nodes-only map asserting nothing depends on
  anything. Leading dots are now level markers (`from .b` is sibling-relative),
  absolute modules resolve from the repo root or the importing file's top-level
  directory, and stdlib still resolves to nothing.
- **A dirty working tree was invisible to staleness.** Freshness compared
  `git_head` only, so uncommitted edits — the state an agent is in for most of a
  task — were never picked up. Maps now carry a `worktree_sig` covering tracked
  edits by content and untracked paths, excluding the map itself so a project
  that doesn't gitignore `tmp/` can't invalidate it by writing it.
- `autopilot/loop.sh` granted BUILD far more than the verify command. The grant
  was derived from the command's first token plus a wildcard, so
  `--verify-cmd 'bash scripts/verify.sh'` added `Bash(bash:*)` — arbitrary shell
  under `acceptEdits`, the opposite of an allowlist. The prefix grant is now
  skipped when that token is an interpreter (`bash`, `make`, `python3`, …) and
  only the exact command is granted.
- `repo-map`'s generator had no guard on its scanner, though `jq`'s was there.
  With the scanner absent every scan matched nothing and the generator wrote a
  map with all its nodes and **zero edges** at exit 0 — valid JSON, plausible
  output, every query silently wrong. It now fails loudly; `REPO_MAP_AWK` makes
  the guard testable.
- `repo-map`'s `deps`/`rdeps` returned a target once per edge *type*, so the
  Graphify backend's `imports` + `calls` between one file pair listed it twice.
  These queries answer "which files", so they de-duplicate.
- `repo-map`'s grep backend counted specifiers named in **comments** as real
  edges (`// moved out of './lib/util'`, or a commented-out import in a JSDoc
  block, invented a dependency and inflated that file's `fan_in` — the metric
  `hotspots` ranks on). Both `//` lines and `/* … */` blocks are now stripped in
  a single pass, since stripping either form first mangles input the other
  needs: `//`-first turns `/* // */` into an unterminated block that swallows
  the file, and `/*`-first lets `// /* note` open a block that was never one.
  The residual ceiling (specifiers inside string literals, dynamic `import()`)
  is documented in the SKILL rather than left implied.
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
