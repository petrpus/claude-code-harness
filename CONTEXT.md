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

**Slice**:
One independently-mergeable unit of roadmap work — one issue, one branch, one PR.
_Avoid_: task, ticket, step

**Blocking edge**:
A declared dependency between slices: the blocked slice must not start before its blockers merge.

**Plan DAG**:
The dependency structure of an autopilot plan, written as `after:` annotations on slice lines. The same idea as a **Blocking edge**, one level down: blocking edges order issues, a plan DAG orders plan items inside one run.

**Escalation**:
Running one slice's next BUILD on a stronger model after it has failed twice. Never applied to the verifier — the cheap adversarial tier is the point.

**Parked slice**:
A slice set aside after failing three times so the runner can pick another unblocked one. Its dependents stay unreachable, so parking only buys anything on a wide **Plan DAG**.
_Avoid_: skipped slice, deferred slice

**Ready-for-agent**:
Issue label marking a slice an autonomous agent may pick up without human interaction.

**Needs-grill**:
Issue label marking a slice that must not run autonomously — it awaits an interactive grill session first.

**Design lane**:
UI/design skills territory — deliberately outside this harness, owned by the separate design-harness plugin.

## Relationships

- The **Harness** ships **Skills**; each skill is exactly one of **Vendored**, **Own**, or **Frozen**
- Every **Vendored skill** has a row in the **Sync-log**; a **Local patch** is recorded on that row
- A **Guard**, a **Verify gate** and an **Iteration gate** are all **Gates**; they differ in what a failure stops — a tool call, a turn, an iteration
- A **Slice** is guarded by the **Verify gate** before its PR merges
- A **Holdout** is read by the verifier only; it is never an input to planning or building
- A **Slice** carries either the **Ready-for-agent** or the **Needs-grill** label, never both
- **Blocking edges** order **Slices**; a slice with no unmerged blockers may start
- A **Plan DAG** orders plan items within one run; **Escalation** then **parking** are what a slice gets when it keeps failing

## Example dialogue

> **Dev:** "Upstream renamed `to-issues` to `to-tickets` — do we rename our skill?"
> **Maintainer:** "No — we keep our name as a **local patch** and sync the content. The **sync-log** row records both the new SHA and the patch."
> **Dev:** "And can the cloud agent pick up the repo-map slice?"
> **Maintainer:** "Not yet — it's labelled **needs-grill**. Only **ready-for-agent** slices with all **blocking edges** merged are up for grabs."

## Flagged ambiguities

- "verify" was used for both the command and the freshness state — resolved: **Verify** is the command; freshness is a property read from `tmp/.last-verify-status`.
- "gate" vs "reminder" — resolved: a **Verify gate** blocks (exit 2); Stop-hook reminders never block (exit 0). The gate is an opt-in exception recorded in ADR-0002.
- "gate" was marked resolved above while still naming a third thing — autopilot's per-iteration checks, which block nothing and merely fail an iteration. Resolved: **Gate** is now the genus, and the three kinds are **Guard**, **Verify gate** and **Iteration gate**. An unqualified "gate" in prose is a smell.
