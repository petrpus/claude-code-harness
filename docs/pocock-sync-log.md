# Vendor sync log

Skills vendored from external sources. We do **not** automate sync — when
something upstream changes that we want, we cherry-pick by hand and update this
file.

Procedure:
1. Fetch the source repo at the target commit. In this environment the GitHub
   API / codeload tarballs are blocked by the proxy — fetch per-file from
   `raw.githubusercontent.com/<owner>/<repo>/<sha>/<path>` (sleep/retry on 429).
2. Diff `SKILL.md` (and any bundled resource files) against our vendored copy.
3. Copy what we want. Where we keep a local dir name that differs from upstream,
   patch the frontmatter `name:` to match our dir and record it as a **local
   patch** below.
4. Commit. For a broad re-sync to a single upstream SHA, one bulk commit
   (`vendor: re-sync <source> skills to <short-sha>`) is more auditable than
   many; for a single skill, `vendor: sync <skill> from <short-sha>`.

## Pocock (`mattpocock/skills`)

Reviewed at upstream HEAD **`66f92b6`** (2026-07-05). Upstream reorganized skills
into category folders (`engineering/`, `productivity/`, `in-progress/`, …) and
moved to a **grill delegation model** (`grill-me`/`grill-with-docs` became thin
delegators to a new standalone `grilling` skill). We keep our local dir names
and our self-contained grill skills; see notes.

| Skill | Upstream path @66f92b6 | Vendored SHA | First vendored | Last reviewed | Notes |
|---|---|---|---|---|---|
| caveman | — (removed upstream) | `17972a1` | 2026-05-16 | 2026-07-06 | **Frozen.** 404 upstream at 66f92b6 — deleted from the collection. Kept locally at its last-vendored SHA. |
| codebase-design | `skills/engineering/codebase-design/` | `6eeb81b` | 2026-06-21 | 2026-07-06 | incl. `DEEPENING.md`, `DESIGN-IT-TWICE.md`. No material change @66f92b6. |
| diagnose | `skills/engineering/diagnosing-bugs/` | `43d464d` | 2026-05-16 | 2026-07-06 | **Local patch**: upstream dir/name is `diagnosing-bugs`; we keep `diagnose` (frontmatter name patched to match). |
| domain-modeling | `skills/engineering/domain-modeling/` | `6eeb81b` | 2026-06-21 | 2026-07-06 | incl. `ADR-FORMAT.md`, `CONTEXT-FORMAT.md` (lockstep — see below). |
| grill-me | `skills/*/grill-me/` | `2a1ad17` | 2026-05-16 | 2026-07-06 | **Divergence**: upstream is now a thin delegator to `/grilling`. We keep our self-contained version so the skill stands alone. |
| grill-with-docs | `skills/engineering/grill-with-docs/` | `3c4ac97` | 2026-05-16 | 2026-07-06 | **Divergence**: upstream now delegates to `/grilling` + `/domain-modeling`. We keep our self-contained version. |
| grilling | `skills/productivity/grilling/` | `66f92b6` | 2026-07-06 | 2026-07-06 | **New vendor.** Standalone relentless-interview loop; single file, no resources. |
| research | `skills/engineering/research/` | `66f92b6` | 2026-07-06 | 2026-07-06 | **New vendor.** Delegates investigation to a background agent against primary sources; single file. |
| handoff | `skills/productivity/handoff/` | `85c644d` | 2026-05-16 | 2026-07-06 | No material change. (Upstream `claude-handoff` intentionally skipped — overlaps this.) |
| improve-codebase-architecture | `skills/engineering/improve-codebase-architecture/` | `3ad8fa7` | 2026-05-16 | 2026-07-06 | incl. `DEEPENING.md` (lockstep), `INTERFACE-DESIGN.md`, `LANGUAGE.md`. |
| prototype | `skills/engineering/prototype/` | `c91bdc5` | 2026-05-16 | 2026-07-06 | incl. `LOGIC.md`, `UI.md`. |
| tdd | `skills/engineering/tdd/` | `75beb30` | 2026-05-16 | 2026-07-06 | Upstream has a minor doc fix (code-review ref) @66f92b6; deferred — no behavior change, our bundled resources differ in layout. |
| to-issues | `skills/engineering/to-issues/` | `b38c5aa` | 2026-05-16 | 2026-07-06 | No material change. |
| to-prd | `skills/engineering/to-prd/` | `d6eff3e` | 2026-05-16 | 2026-07-06 | No material change. |
| triage | `skills/engineering/triage/` | `de4f182` | 2026-05-16 | 2026-07-06 | incl. `AGENT-BRIEF.md`, `OUT-OF-SCOPE.md`. |
| write-a-skill | `skills/productivity/writing-great-skills/` | `2f252b3` | 2026-05-16 | 2026-07-06 | **Local patch**: upstream dir/name is `writing-great-skills`; we keep `write-a-skill`. |
| zoom-out | `skills/engineering/zoom-out/` | `6ecebab` | 2026-05-16 | 2026-07-06 | No material change. |

**Skipped intentionally** (documented so a future sync doesn't re-add them):
`setup-matt-pocock-skills` (conventions baked into `docs/architecture.md`),
`claude-handoff` (overlaps `handoff`), `wayfinder` / `loop-me` (upstream
in-progress; the harness ships its own `autopilot` loop and two loop doctrines
would conflict), `code-review` skill (we ship the `code-reviewer` agent),
`ask-matt`, `teach`.

### Duplicated bundled resources — keep in lockstep

Skills must stay self-contained dirs (plugin bundling), so shared resource files
are **copied**, not linked. These copies must stay byte-identical except where
noted; `scripts/check-consistency.sh` enforces it.

| Resource | Present in | Rule |
|---|---|---|
| `ADR-FORMAT.md` | domain-modeling, grill-with-docs | byte-identical |
| `CONTEXT-FORMAT.md` | domain-modeling, grill-with-docs | canonical = the richer version; keep identical |
| `DEEPENING.md` | codebase-design, improve-codebase-architecture | identical **except** the one cross-reference line (`SKILL.md` vs `LANGUAGE.md`) |

## Vercel Labs (`vercel-labs/skills`)

| Skill | Upstream path | Vendored SHA | First vendored | Last reviewed | Notes |
|---|---|---|---|---|---|
| find-skills | `skills/find-skills/SKILL.md` | `3013fde` | 2026-05-16 | 2026-07-06 | No material change. |

## Own (no external source)

Authored in this repo, no upstream. Tracked via git history, not the sync table.

- `skills/next/`, `skills/commit-agent/`, `skills/implement-issue/`,
  `skills/start-feature/`, `skills/migration-check/`, `skills/worklog/`,
  `skills/harness-init/`, `skills/harness-doctor/`
- `skills/autopilot/`, `skills/cost-discipline/`, `skills/usage-report/`,
  `skills/project-infra/`, `skills/openapi-sync/`, `skills/code-map/`
- `agents/code-reviewer.md`, `agents/verifier.md`
- `hooks/*.sh` + `hooks/hooks.json`
- `scripts/check-consistency.sh`

## Loopkit (`Archive228/loopkit`, MIT)

Not vendored as files — its **ideas** were re-engineered into own components:
the adversarial-verify checklist → `agents/verifier.md`; the fresh-context loop
with state on disk → `skills/autopilot/`; the context-budget / tool-restraint /
subagent-fanout doctrine → `skills/cost-discipline/`; MEMORY.md discipline →
autopilot's `tmp/autopilot/MEMORY.md` prune rule.
