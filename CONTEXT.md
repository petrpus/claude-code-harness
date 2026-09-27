# claude-code-harness

Universal code-dev harness distributed as a Claude Code plugin. This context covers
the vocabulary of the harness itself — how skills are sourced, guarded, verified,
and shipped to consumer projects.

## Language

**Harness**:
The plugin this repo ships — a curated set of skills, agents, and hooks installed once per machine.
_Avoid_: framework, toolkit

**Consumer project**:
A project that has the harness installed and follows its conventions.
_Avoid_: client project, target repo

**Skill**:
One directory under `skills/` with a `SKILL.md` and optional flat resource files.

**Vendored skill**:
A skill copied by hand from an upstream repo at a recorded SHA.
_Avoid_: imported skill, synced skill

**Own skill**:
A skill authored in this repo with no upstream.

**Frozen skill**:
A vendored skill whose upstream was deleted; kept at its last-vendored SHA, never re-synced.

**Local patch**:
A deliberate, recorded difference between our vendored copy and upstream — typically a kept dir/skill name.
_Avoid_: fork, divergence (divergence is the state; the patch is the recorded decision)

**Sync-log**:
`docs/pocock-sync-log.md` — the source of truth for what is vendored, from where, at which SHA.

**Gate**:
The genus: a check whose failure refuses to let something proceed. Three kinds, told apart by *what* they stop.
_Avoid_: validator

**Guard**:
A **Gate** on a tool call — a PreToolUse hook that blocks a dangerous action with exit 2.
_Avoid_: check, validator

**Verify**:
The repo's single verification command; its result and timestamp land in `tmp/.last-verify-status`.

**Verify gate**:
A **Gate** on the end of a turn — a hard stop that refuses to proceed until Verify has passed, as opposed to a reminder, which merely nags.

**Iteration gate**:
A **Gate** on one autopilot iteration. It exits nothing: a failure feeds FEEDBACK.md and the slice is retried. Four of them — verify, secret, semantic, holdout.
_Avoid_: gate (unqualified), check

**Plan-dependency failure**:
Not a **Gate** — a defect found in the plan itself (a cycle in the `after:` edges, or an edge naming an unknown slice id). It bypasses the stuck ladder entirely and goes straight to replan, because no amount of retrying or escalating fixes a plan that cannot be walked.

**Holdout**:
An acceptance scenario the verifier checks and the build model never sees. Lives outside the worktree so hiding it is a property of where it is, not of what BUILD is allowed to read.
_Avoid_: hidden test, secret spec

**Issue**:
One independently-mergeable unit of roadmap work — one GitHub issue, one branch, one PR.
_Avoid_: ticket, task

**Slice**:
One plan item inside one autopilot run — one checkpoint commit on the issue's branch.
_Avoid_: task, step

**Blocking edge**:
A declared dependency between issues: the blocked issue must not start before its blockers merge.

**Map**:
A GitHub issue labelled `map` whose `## Delivery` section lists the issues of one delivery with their blocking edges, in the plan grammar (ADR-0008). The machine-readable contract `/deliver` walks.
_Avoid_: epic, tracking issue, roadmap issue

**Integration branch**:
The branch a Delivery run merges issue PRs into — never the default branch unless explicitly allowed. A human merges it into the default branch.
_Avoid_: feature branch (that is an issue's own branch)

**Delivery run**:
One `/deliver` execution over a Map: per issue branch → autopilot run → PR → review → merge, in blocking-edge order.
_Avoid_: train, batch run

**Plan DAG**:
The dependency structure of an autopilot plan, written as `after:` annotations on slice lines. The same idea as a **Blocking edge**, one level down: blocking edges order issues, a plan DAG orders plan items inside one run.

**Escalation**:
Running one slice's next BUILD on a stronger model after it has failed twice. Never applied to the verifier — the cheap adversarial tier is the point.

**Parked slice**:
A slice set aside after failing three times so the runner can pick another unblocked one. Its dependents stay unreachable, so parking only buys anything on a wide **Plan DAG**.
_Avoid_: skipped slice, deferred slice

**Review round**:
One independent review of an issue's PR, followed — if it finds in-scope blockers or issues — by one fix run. A Delivery run allows a bounded number per issue.

**Follow-up**:
An out-of-scope review finding filed as a `needs-triage` issue and appended to the Map. Never executed by the run that found it.
_Avoid_: TODO, tech debt ticket

**Parked issue**:
An issue a Delivery run set aside (label `needs-human`) because its autopilot run, review rounds, CI or merge failed. Its dependents are skipped; independent issues continue. The issue-level counterpart of a **Parked slice**.

**Ready-for-agent**:
Issue label marking an issue an autonomous agent may pick up without human interaction.

**Needs-grill**:
Issue label marking an issue that must not run autonomously — it awaits an interactive grill session first.

**Design lane**:
UI/design skills territory — deliberately outside this harness, owned by the separate design-harness plugin.

## Relationships

- The **Harness** ships **Skills**; each skill is exactly one of **Vendored**, **Own**, or **Frozen**
- Every **Vendored skill** has a row in the **Sync-log**; a **Local patch** is recorded on that row
- A **Guard**, a **Verify gate** and an **Iteration gate** are all **Gates**; they differ in what a failure stops — a tool call, a turn, an iteration
- An **Issue** is verified on its exact head before its PR merges; a **Slice** passes the **Iteration gates** before its checkpoint commit
- A **Holdout** is read by the verifier only; it is never an input to planning or building
- An **Issue** carries either the **Ready-for-agent** or the **Needs-grill** label, never both
- **Blocking edges** order **Issues**; an issue with no unmerged blockers may start
- A **Plan DAG** orders **Slices** within one autopilot run; **Escalation** then **parking** are what a slice gets when it keeps failing
- A **Map** lists the **Issues** of one **Delivery run**; each issue gets its own autopilot run, and its **Slices** never cross issue boundaries
- A **Delivery run** merges into an **Integration branch**; a failing issue becomes a **Parked issue**, and review findings outside its scope become **Follow-ups**

## Example dialogue

> **Dev:** "Upstream renamed `to-issues` to `to-tickets` — do we rename our skill?"
> **Maintainer:** "No — we keep our name as a **local patch** and sync the content. The **sync-log** row records both the new SHA and the patch."
> **Dev:** "And can the cloud agent pick up the repo-map slice?"
> **Maintainer:** "Not yet — it's labelled **needs-grill**. Only **ready-for-agent** issues with all **blocking edges** merged are up for grabs."

## Flagged ambiguities

- "verify" was used for both the command and the freshness state — resolved: **Verify** is the command; freshness is a property read from `tmp/.last-verify-status`.
- "gate" vs "reminder" — resolved: a **Verify gate** blocks (exit 2); Stop-hook reminders never block (exit 0). The gate is an opt-in exception recorded in ADR-0002.
- "gate" was marked resolved above while still naming a third thing — autopilot's per-iteration checks, which block nothing and merely fail an iteration. Resolved: **Gate** is now the genus, and the three kinds are **Guard**, **Verify gate** and **Iteration gate**. An unqualified "gate" in prose is a smell.
- "slice" meant both an issue (PRD 0001, this glossary) and a plan item (PRD 0002, the code). Resolved by PRD 0003: an **Issue** is the branch/PR unit, a **Slice** is a plan item inside one autopilot run.
