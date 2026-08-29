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

**Survey 2026-08-28 @ `6654f6b`** (no content re-vendored — survey only, during the
PRD 0002 grill): every vendored `SKILL.md` diffed against `6654f6b`. Bulk of the drift
is the upstream em-dash purge (`3216582`) and ticket/spec terminology — cosmetic, not
adopted. Substantive upstream changes worth a future targeted re-sync:
`tdd` restructured (new **tautological-tests** anti-pattern, seams-first "test only at
pre-agreed seams", refactoring moved out of the loop into their `code-review` skill —
that last bit conflicts with our autopilot BUILD prompt's red-green-refactor, so any
re-sync is a cherry-pick, not a copy). `writing-great-skills` was **renamed and
restructured to `productivity/writing-for-agents`** (`1fc6573`, 2026-07-23) — our
`write-a-skill` row's upstream path is stale; the successor's context-pointer /
information-hierarchy doctrine is strong and a re-sync candidate. `zoom-out` is still
404 → **now Frozen** (was Watch). `batch-grill-me` is gone upstream → dropped from the
watch list. New upstream skills surveyed and *not* adopted: `engineering/implement` +
`in-progress/implement-spec` (thin; our `implement-issue` is richer),
`in-progress/retro` (environment-retrospective — interesting shape, overlaps
`harness-doctor`/`usage-report` territory; watch), `misc/git-guardrails-claude-code`
(blocks *all* `git push`; our `pre-bash.sh` guards are more surgical — nothing to
adopt), `wait-what`, `to-questionnaire`, `wizard`, writing-track skills.

Previous survey: re-surveyed at upstream **`ed37663`** (2026-07-24) — every row below was diffed
against `ed37663` on that date (so `Last reviewed` is bulk-bumped), but
`Vendored SHA` moves only for rows whose content we actually re-copied this pass
(`to-issues`, `to-prd`). The rest either match an older vendored copy or diverge
for a documented reason; a full collection re-vendor to `ed37663` remains future
work. Upstream keeps its category folders (`engineering/`, `productivity/`,
`in-progress/`, …) and the **grill delegation model**; we keep our local dir
names and our self-contained grill skills. This pass renamed two upstream skills
into our names: `to-tickets`→`to-issues`, `to-spec`→`to-prd` (local patches).

| Skill | Upstream path @ed37663 | Vendored SHA | First vendored | Last reviewed | Notes |
|---|---|---|---|---|---|
| caveman | — (removed upstream) | `17972a1` | 2026-05-16 | 2026-07-24 | **Frozen.** 404 upstream — deleted from the collection. Kept locally at its last-vendored SHA. |
| codebase-design | `skills/engineering/codebase-design/` | `6eeb81b` | 2026-06-21 | 2026-07-24 | incl. `DEEPENING.md`, `DESIGN-IT-TWICE.md`. Identical @ed37663. |
| diagnose | `skills/engineering/diagnosing-bugs/` | `43d464d` | 2026-05-16 | 2026-07-24 | **Local patch**: upstream dir/name is `diagnosing-bugs`; we keep `diagnose`. Local divergence (own additions) — not re-synced this pass. |
| domain-modeling | `skills/engineering/domain-modeling/` | `6eeb81b` | 2026-06-21 | 2026-07-24 | incl. `ADR-FORMAT.md`, `CONTEXT-FORMAT.md` (lockstep — see below). Identical @ed37663. |
| grill-me | `skills/*/grill-me/` | `2a1ad17` | 2026-05-16 | 2026-07-24 | **Divergence**: upstream is a thin delegator to `/grilling`. We keep our self-contained version so the skill stands alone. |
| grill-with-docs | `skills/engineering/grill-with-docs/` | `3c4ac97` | 2026-05-16 | 2026-07-24 | **Divergence**: upstream delegates to `/grilling` + `/domain-modeling`. We keep our self-contained version. |
| grilling | `skills/productivity/grilling/` | `66f92b6` | 2026-07-06 | 2026-07-24 | Standalone relentless-interview loop. Minor upstream diff @ed37663; deferred (no behaviour change). |
| research | `skills/engineering/research/` | `66f92b6` | 2026-07-06 | 2026-07-24 | Delegates investigation to a background agent against primary sources. Identical @ed37663. |
| handoff | `skills/productivity/handoff/` | `85c644d` | 2026-05-16 | 2026-07-24 | Minor upstream diff @ed37663; deferred. (Upstream `claude-handoff` intentionally skipped — overlaps this.) |
| improve-codebase-architecture | `skills/engineering/improve-codebase-architecture/` | `3ad8fa7` | 2026-05-16 | 2026-07-24 | incl. `DEEPENING.md` (lockstep), `INTERFACE-DESIGN.md`, `LANGUAGE.md`. Upstream diverged @ed37663; deferred. |
| prototype | `skills/engineering/prototype/` | `c91bdc5` | 2026-05-16 | 2026-07-24 | incl. `LOGIC.md`, `UI.md`. Minor upstream diff @ed37663; deferred. |
| tdd | `skills/engineering/tdd/` | `75beb30` | 2026-05-16 | 2026-07-24 | Upstream diverged further @ed37663 (code-review ref + more); deferred — our bundled resources differ in layout. |
| to-issues | `skills/engineering/to-tickets/` | `ed37663` | 2026-05-16 | 2026-07-24 | **Local patch** (rename): upstream is `to-tickets`. Adopted blocking edges, one-context-window slice sizing, prefactoring-first, expand–contract (incl. integration-branch variant); dropped HITL/AFK typing; kept GitHub-Issues-via-`gh` wording. `disable-model-invocation` NOT adopted — see note. |
| to-prd | `skills/engineering/to-spec/` | `ed37663` | 2026-05-16 | 2026-07-24 | **Local patch** (rename): upstream is `to-spec`. Adopted seams-first step (prefer existing seams, highest possible, ideal one); kept PRD terminology + template. `disable-model-invocation` NOT adopted — see note. |
| triage | `skills/engineering/triage/` | `de4f182` | 2026-05-16 | 2026-07-24 | incl. `AGENT-BRIEF.md`, `OUT-OF-SCOPE.md`. Upstream diverged @ed37663; deferred. |
| write-a-skill | `skills/productivity/writing-for-agents/` (renamed upstream `1fc6573`) | `2f252b3` | 2026-05-16 | 2026-08-28 | **Local patch**: we keep `write-a-skill`. Upstream renamed `writing-great-skills` → `writing-for-agents` and restructured around context pointers / information hierarchy — re-sync candidate, cherry-pick (our S4 extensions must survive). |
| zoom-out | — (removed upstream) | `6ecebab` | 2026-05-16 | 2026-08-28 | **Frozen.** Still 404 at `6654f6b` (two surveys in a row) — deleted upstream. Kept locally at its last-vendored SHA. |
| resolving-merge-conflicts | `skills/engineering/resolving-merge-conflicts/` | `ed37663` | 2026-07-24 | 2026-07-24 | **New vendor.** Verbatim from upstream (14 lines, no resources): see current state → primary sources → resolve each hunk → run checks → finish. |

**`disable-model-invocation` — evaluated, NOT adopted.** Upstream `to-tickets`
and `to-spec` carry `disable-model-invocation: true`. We drop it: `start-feature`
and `next` compose `/to-issues` and `/to-prd` programmatically, and we can't
guarantee the flag preserves that indirect invocation across Claude Code
versions. Keeping them model-invocable is the safe choice; revisit if the flag's
semantics are confirmed to allow skill-to-skill calls.

**Skipped intentionally** (documented so a future sync doesn't re-add them):
`setup-matt-pocock-skills` (conventions baked into `docs/architecture.md`),
`claude-handoff` (overlaps `handoff`), `loop-me` (the harness ships its own
`autopilot` loop; two loop doctrines would conflict), `code-review` skill (we
ship the `code-reviewer` agent), `ask-matt`, `teach`. **`wayfinder`** has
graduated from `in-progress/` upstream but stays skipped — it depends on
upstream's tracker-doc infra and overlaps our `to-prd` / `to-issues` / `triage`
flow. **Watch list**: `in-progress/retro` (environment retrospectives — surfaced @6654f6b). `batch-grill-me` was on this list @ed37663 but is gone upstream @6654f6b — dropped. `zoom-out` graduated to Frozen above.

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
| find-skills | `skills/find-skills/SKILL.md` | `e173b8c` | 2026-05-16 | 2026-08-28 | Byte-identical to upstream `435076e` (2026-08-28 survey). Earlier: synced `--owner` flag; removed the `skills check` line. |

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

Surveyed 2026-08-28 @ `5ae033e`: upstream grew from a loop runner into a 50-skill
collection (July 2026, "loop & harness track"). Directly relevant prior art, ideas
only (still nothing vendored): **`hitl-escalate`** — trigger taxonomy (ambiguous spec /
missing credential / destructive action / 3+ verify fails), a 5-line escalation message
shape ending in `Choices:`, a `BLOCKED.md` exit contract, and the warning that
escalating on solvable problems trains humans to ignore the channel → recorded as prior
art for our M2 (`ASK.md`). **`evaluator-calibration`** + **`self-eval-bias`** — verifier
anti-drift doctrine (binary verdicts ✓ we do; fresh context per grading ✓ we do;
quote-the-artifact evidence ✓ mostly; per-criterion verdict-distribution logging and
held-out-fail spot-checks → fed into PRD 0002 S3/S2). **`model-routing`** — claims a
cheap executor + *frontier judge* beats a frontier executor with no judge ("Elvis
finding"); inverse of our haiku-verifier policy — recorded as an open question in
`docs/model-policy.md`, to be answered with S3 data, not adopted.

Not vendored as files — its **ideas** were re-engineered into own components:
the adversarial-verify checklist → `agents/verifier.md`; the fresh-context loop
with state on disk → `skills/autopilot/`; the context-budget / tool-restraint /
subagent-fanout doctrine → `skills/cost-discipline/`; MEMORY.md discipline →
autopilot's `tmp/autopilot/MEMORY.md` prune rule.
