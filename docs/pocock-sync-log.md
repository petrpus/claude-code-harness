# Vendor sync log

Skills vendored from external sources. We do **not** automate sync — when
something upstream changes that we want, we cherry-pick by hand and update this
file.

Procedure:
1. Fetch the source repo with history: `git clone --filter=blob:none
   https://github.com/<owner>/<repo>.git` (works through this environment's
   proxy, unlike the GitHub API, github.com pages and codeload tarballs).
   Anchor a survey on a **release tag** when upstream has one, read its
   CHANGELOG / pending changesets, and diff tag to tag locally. Per-file
   `raw.githubusercontent.com/<owner>/<repo>/<sha>/<path>` is the fallback
   (sleep/retry on 429). Never infer safety from semver: upstream ships renames
   and removals as "minor" releases.
2. Diff `SKILL.md` (and any bundled resource files) against our vendored copy.
   Diff the **whole** vendored set, not only the skills that look busy — the
   2026-07-24 and 2026-08-28 surveys skipped most of them and missed real drift.
3. Copy what we want. Where we keep a local dir name that differs from upstream,
   patch the frontmatter `name:` to match our dir and record it as a **local
   patch** below.
4. Record the **commit** SHA the content came from (with its date and, when
   there is one, the release tag) — not a `git ls-tree` tree hash. The tree hash
   of the skill dir may go in the Tree column as a content checksum
   (`git diff <tree> <commit>:<path>` works against it).
5. Commit. For a broad re-sync to a single upstream SHA, one bulk commit
   (`vendor: re-sync <source> skills to <short-sha>`) is more auditable than
   many; for a single skill, `vendor: sync <skill> from <short-sha>`.

## Pocock (`mattpocock/skills`)

**Survey 2026-10-02 @ `d81f3a1`** (2026-09-29, merge of PR #1120 = the v1.3
content; the newest tag is still `v1.2.3`, the 1.3.0 version PR is unmerged). No
content re-vendored — survey and log hygiene only, as part of 0.7.0. Every
vendored skill was diffed against `d81f3a1` from a full clone.
- **This log was wrong in two ways.** 11 "Vendored SHA" values were git **tree**
  hashes of the skill dir, not commits — they are converted below (the tree stays
  as a checksum). And the two previous surveys diffed only a few skills: our
  copies of `diagnose`, `tdd`, `triage`, `handoff`, `improve-codebase-architecture`,
  `prototype` and `grilling` lag substantive upstream changes that predate them
  (each row says what). `diagnose` has no local additions; `to-prd` has two
  undocumented ones (now recorded).
- **Inside the range** the only change to our vendored text is upstream's
  `CONTEXT.md` / `CONTEXT-MAP.md` → `GLOSSARY.md` / `GLOSSARY-MAP.md` rename, with
  no fallback. Decision for 0.7.0: **not adopted yet** — it lands with the bulk
  re-sync in 0.8.0 as an ADR (read `GLOSSARY.md`, else `CONTEXT.md`; write
  `GLOSSARY.md`), because it touches the autopilot prompt, the deliver charter,
  the code-reviewer agent and `check-consistency.sh`.
- **New in the upstream plugin**: `engineering/pr` (PR body with Summary /
  Evidence / Merge Danger — candidate for `implement-issue` and `/deliver`'s
  final PR; its text credits Dex Horthy's `show-me`, licence unverified),
  `engineering/retro` (environment retrospective from session logs — graduated
  from our watch list; needs `writing-for-agents`) and `engineering/implement-spec`
  (skipped, see below). **Removed upstream**: `resolving-merge-conflicts`
  (`daa01d8`, "No longer needed") → **Frozen** here.
- **Distribution**: upstream is now the `mattpocock-skills` plugin (official
  marketplace since 2026-08-05) and versions with Changesets. Depending on that
  plugin instead of vendoring stays rejected — our names, `gh` wording, Map
  publishing and self-contained grills diverge, and installing both loads every
  shared skill twice; `harness-doctor` §3b warns when both are enabled.

Previous survey **2026-08-28 @ `6654f6b`** (no content re-vendored, during the
PRD 0002 grill): bulk drift is the em-dash purge (`3216582`) and ticket/spec
terminology. Recorded then: the `tdd` restructure (tautological-tests
anti-pattern, seams-first, refactoring moved to `code-review` — conflicts with
our autopilot BUILD prompt's red-green-refactor, so cherry-pick, not copy) and the
`writing-great-skills` → `productivity/writing-for-agents` rename (`1fc6573`).
`zoom-out` became Frozen; `batch-grill-me` left the watch list (gone upstream).
New skills surveyed and not adopted then: `engineering/implement`,
`in-progress/implement-spec`, `misc/git-guardrails-claude-code` (blocks every
`git push`; our `pre-bash.sh` guards are more surgical), `wait-what`,
`to-questionnaire`, `wizard`, writing-track skills.

Survey **2026-07-24 @ `ed37663`**: re-copied `to-issues` and `to-prd` (renamed
upstream `to-tickets` / `to-spec`, kept as local patches) and vendored
`resolving-merge-conflicts`. Upstream keeps its category folders and the grill
delegation model; we keep our local dir names and self-contained grills.

| Skill | Upstream path @d81f3a1 | Vendored commit | Tree | First vendored | Last reviewed | Notes |
|---|---|---|---|---|---|---|
| caveman | — (removed upstream) | `ab45d5e` (2026-04-17) | `17972a1` | 2026-05-16 | 2026-10-02 | **Frozen.** Deleted from the collection; still absent @d81f3a1. Kept locally at that content. |
| codebase-design | `skills/engineering/codebase-design/` | `6eeb81b` (2026-06-18) | — | 2026-06-21 | 2026-10-02 | incl. `DEEPENING.md`, `DESIGN-IT-TWICE.md`. Cosmetic drift only: em-dash rewrites, harness-neutral subagent wording, the GLOSSARY rename. |
| diagnose | `skills/engineering/diagnosing-bugs/` | `7afa86d` (2026-04-28) | `43d464d` | 2026-05-16 | 2026-10-02 | **Local patch**: upstream dir/name is `diagnosing-bugs`; we keep `diagnose`. Otherwise byte-identical to upstream @`7afa86d` — **no own additions** (the old "local divergence" note was wrong). Upstream since: Phase 1 ends on "a tight loop that goes red", reproduce + minimise, `## Redact` (`efce423`, v1.2.3), post-mortem hand-off removed (`1dab982`). Re-sync candidate: take whole. |
| domain-modeling | `skills/engineering/domain-modeling/` | `6eeb81b` (2026-06-18) | — | 2026-06-21 | 2026-10-02 | incl. `ADR-FORMAT.md`, `CONTEXT-FORMAT.md` (lockstep — see below). @d81f3a1: GLOSSARY rename (`CONTEXT-FORMAT.md` → `GLOSSARY-FORMAT.md`) and a narrower description; waits for the 0.8.0 glossary ADR. Our richer `CONTEXT-FORMAT.md` is old, deliberate divergence. |
| grill-me | `skills/productivity/grill-me/` | `a6bdfd9` (2026-03-26) | `2a1ad17` | 2026-05-16 | 2026-10-02 | **Divergence**: upstream is a two-line user-invoked delegator to `/grilling`. We keep the self-contained version — upstream's own docs report that delegated loading is unreliable, and `start-feature` composes it. Its one-question-at-a-time wording predates upstream's round-based grilling (see `grilling`). |
| grill-with-docs | `skills/engineering/grill-with-docs/` | `e74f006` (2026-05-13) | `3c4ac97` | 2026-05-16 | 2026-10-02 | **Divergence**: upstream delegates to `/grilling` + `/domain-modeling` (user-invoked). We keep our self-contained version. |
| grilling | `skills/productivity/grilling/` | `66f92b6` (2026-07-05) | — | 2026-07-06 | 2026-10-02 | **Behaviour drift upstream** — the "no behaviour change" note was wrong from `a4b2009` (2026-07-16) on: the whole question frontier per round, numbered, each with a recommended answer; facts fetched by sub-agents (`a4b2009`, `294a2c9`, `85f83d3`). Re-sync candidate; the inline copies in grill-me / grill-with-docs would follow. |
| research | `skills/engineering/research/` | `66f92b6` (2026-07-05) | — | 2026-07-06 | 2026-10-02 | Delegates investigation to a background agent against primary sources. Cosmetic drift only (one em-dash line). |
| handoff | `skills/productivity/handoff/` | `918f3fe` (2026-05-06) | `85c644d` | 2026-05-16 | 2026-10-02 | Upstream since: "Redact any sensitive information…" (`feaaf42`), a suggested-skills section, OS temp dir, `disable-model-invocation`. Re-sync candidate: the Redact line. (Upstream `claude-handoff` intentionally skipped — overlaps this.) |
| improve-codebase-architecture | `skills/engineering/improve-codebase-architecture/` | `7afa86d` (2026-04-28) | `3ad8fa7` | 2026-05-16 | 2026-10-02 | incl. `DEEPENING.md` (lockstep), `INTERFACE-DESIGN.md`, `LANGUAGE.md`. Upstream restructured: vocabulary delegated to `codebase-design`, "Scope before you scan: YAGNI" (`45afd80`), an HTML report loading Tailwind and Mermaid from CDNs (not adoptable: offline rule), `disable-model-invocation`. Cherry-pick candidate: the YAGNI scoping. |
| prototype | `skills/engineering/prototype/` | `f304057` (2026-05-12) | `c91bdc5` | 2026-05-16 | 2026-10-02 | incl. `LOGIC.md`, `UI.md`. Upstream since: keep the prototype on a throwaway branch as a primary source (`371b9c9`), logic branch as a single HTML file (`6bcbcb0`). Cherry-pick candidate: the throwaway-branch rule. |
| tdd | `skills/engineering/tdd/` | `7afa86d` (2026-04-28) | `75beb30` | 2026-05-16 | 2026-10-02 | Our bundled resources keep the 2026-04-28 layout. Upstream since: tautological-test anti-pattern (`43ea088`), test only at pre-agreed seams (`e81f976`), refactor dropped from the loop (`80e9dcc`) — the last conflicts with autopilot's BUILD prompt, so cherry-pick, not copy. |
| to-issues | `skills/engineering/to-tickets/` | `ed37663` (2026-07-24) | — | 2026-05-16 | 2026-10-02 | **Local patch** (rename): upstream is `to-tickets`. Adopted blocking edges, one-context-window slice sizing, prefactoring-first, expand–contract (incl. integration-branch variant); dropped HITL/AFK typing; kept GitHub-Issues-via-`gh` wording. **Local patch** (deliver #64): added step 6, Map-publishing per `skills/deliver/MAP-FORMAT.md` (ADR-0008). `disable-model-invocation` NOT adopted — see note. Unchanged upstream in range. |
| to-prd | `skills/engineering/to-spec/` | `ed37663` (2026-07-24) | — | 2026-05-16 | 2026-10-02 | **Local patch** (rename): upstream is `to-spec`. Adopted seams-first step (prefer existing seams, highest possible, ideal one); kept PRD terminology + template. **Local patch** (deliver #64): the PRD gets the `prd` label instead of `ready-for-agent`. **Local patch** (recorded 2026-10-02, origin unknown): "A deep module … makes the best seam: it can be tested in isolation" and "which modules they want tests written for" — neither is upstream @`ed37663`. `disable-model-invocation` NOT adopted — see note. Unchanged upstream in range. |
| triage | `skills/engineering/triage/` | `179a14e` (2026-04-28) | `de4f182` | 2026-05-16 | 2026-10-02 | incl. `AGENT-BRIEF.md`, `OUT-OF-SCOPE.md`. Upstream since: PRs as a triage surface (`e00eadb`), a redundancy check plus an "Already implemented" wontfix that is *not* written to `.out-of-scope/`, "Verify the claim", grilling via the Skill tool, the GLOSSARY rename. Cherry-pick candidate: the redundancy check. The `/setup-matt-pocock-skills` mismatch persists (`.claude/CLAUDE.md`). |
| write-a-skill | `skills/productivity/writing-for-agents/` (renamed upstream `1fc6573`) | `985d8fc` (2026-02-03) | `2f252b3` | 2026-05-16 | 2026-10-02 | **Local patch**: we keep `write-a-skill` = upstream's February `write-a-skill` plus our S4 extensions (500-line cap, one-level references, TOC, naming, checklist). Upstream's `writing-for-agents` shares no text with it; `retro` depends on it, so adopting `retro` means vendoring `writing-for-agents` as its own dir. |
| zoom-out | — (removed upstream) | `7afa86d` (2026-04-28) | `6ecebab` | 2026-05-16 | 2026-10-02 | **Frozen.** Deleted upstream; still absent @d81f3a1. Keeps its upstream `disable-model-invocation: true` (ADR-0015's user-only set). |
| resolving-merge-conflicts | — (removed upstream `daa01d8`, 2026-09-24) | `ed37663` (2026-07-24) | — | 2026-07-24 | 2026-10-02 | **Frozen.** Removed upstream ("No longer needed"; archived in v1.3.0, nothing replaces it). Kept locally at `ed37663`; nothing in `autopilot/` or `deliver/` depends on it. |

**`disable-model-invocation` — closed 2026-10-02, stays NOT adopted** on
`to-issues` / `to-prd` (upstream's `to-tickets` / `to-spec` carry it). The
question was whether the flag still lets one skill invoke another; the Claude
Code skills docs (§ Control who invokes a skill) say it doesn't: only the user
can invoke such a skill, and Claude Code blocks the model's Skill-tool call even
when another skill asked for it. `start-feature` and `next` compose these two,
so they stay model-invocable. Where we *do* use the flag: ADR-0015.

**Skipped intentionally** (documented so a future sync doesn't re-add them):
`setup-matt-pocock-skills` (conventions baked into `docs/architecture.md`),
`claude-handoff` (overlaps `handoff`), `loop-me` (the harness ships its own
`autopilot` loop; two loop doctrines would conflict), `code-review` skill (we
ship the `code-reviewer` agent), `ask-matt`, `teach`. **`wayfinder`** stays
skipped — it depends on upstream's tracker-doc infra and overlaps our `to-prd` /
`to-issues` / `triage` flow. **`implement-spec`** (graduated in v1.3) is skipped:
it orchestrates subagents inside one session, which upstream itself says loses to
a deterministic loop for AFK work; its documented field failures (stale
blocked-by counts mid-run, parallel workers naming one thing differently, tests
silently skipping in worktrees) are input for parallel `/deliver` (#39).
**Candidates for the 0.8.0 re-sync**: `pr`, `retro` (+ `writing-for-agents`),
and the per-row candidates above.

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

| Skill | Upstream path | Vendored commit | First vendored | Last reviewed | Notes |
|---|---|---|---|---|---|
| find-skills | `skills/find-skills/SKILL.md` | `e173b8c` (2026-07-22) | 2026-05-16 | 2026-10-02 | Byte-identical to upstream HEAD `18f96ea` (2026-10-02); the file last changed in `773fb2c` (2026-07-06). Earlier: synced `--owner` flag; removed the `skills check` line. The CLI moved to 1.7.0 (SHA pinning, `add --json` audit verdicts) — nothing to vendor. |

## Own (no external source)

Authored in this repo, no upstream. Tracked via git history, not the sync table.

- `skills/next/`, `skills/commit-agent/`, `skills/implement-issue/`,
  `skills/start-feature/`, `skills/migration-check/`, `skills/worklog/`,
  `skills/harness-init/`, `skills/harness-doctor/`
- `skills/autopilot/`, `skills/deliver/`, `skills/cost-discipline/`,
  `skills/usage-report/`, `skills/project-infra/`, `skills/openapi-sync/`,
  `skills/repo-map/`, `skills/code-map/`
- `agents/code-reviewer.md`, `agents/verifier.md`
- `hooks/*.sh` + `hooks/hooks.json`
- `scripts/check-consistency.sh`

## Loopkit (`Archive228/loopkit`, MIT)

Surveyed **2026-10-02 @ `5ae033e`**: no upstream commits since 2026-07-15
("ship 8 upgrades + finn-loop preset"). Its July "loop & harness" skills still
hold ideas we haven't harvested, recorded as prior art (nothing vendored):
**`sprint-contract`** (3–7 script-decidable acceptance predicates, a runtime path
and an out-of-scope list, agreed with the evaluator before any code is written),
**`harness-stripping`** (ablate one harness component at a time on a fixed task
set — never the safety or cost caps), the **finn-loop** gate (a human approves the
spec by renaming `SPEC-PENDING.md` to `SPEC-APPROVED.md`; prior art for M2, #40)
and **`init-script-contract`** (kill processes by PID — "grep kills sibling
agents on shared sandboxes"; input for #39). Its numeric claims are unsourced and
not to be quoted.

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
