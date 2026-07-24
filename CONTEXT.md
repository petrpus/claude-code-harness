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

**Guard**:
A PreToolUse hook that blocks a dangerous action with exit 2.
_Avoid_: check, validator

**Verify**:
The repo's single verification command; its result and timestamp land in `tmp/.last-verify-status`.

**Verify gate**:
A hard stop that refuses to proceed until Verify has passed — as opposed to a reminder, which merely nags.

**Slice**:
One independently-mergeable unit of roadmap work — one issue, one branch, one PR.
_Avoid_: task, ticket, step

**Blocking edge**:
A declared dependency between slices: the blocked slice must not start before its blockers merge.

**Ready-for-agent**:
Issue label marking a slice an autonomous agent may pick up without human interaction.

**Needs-grill**:
Issue label marking a slice that must not run autonomously — it awaits an interactive grill session first.

**Design lane**:
UI/design skills territory — deliberately outside this harness, owned by the separate design-harness plugin.

## Relationships

- The **Harness** ships **Skills**; each skill is exactly one of **Vendored**, **Own**, or **Frozen**
- Every **Vendored skill** has a row in the **Sync-log**; a **Local patch** is recorded on that row
- A **Slice** is guarded by the **Verify gate** before its PR merges
- A **Slice** carries either the **Ready-for-agent** or the **Needs-grill** label, never both
- **Blocking edges** order **Slices**; a slice with no unmerged blockers may start

## Example dialogue

> **Dev:** "Upstream renamed `to-issues` to `to-tickets` — do we rename our skill?"
> **Maintainer:** "No — we keep our name as a **local patch** and sync the content. The **sync-log** row records both the new SHA and the patch."
> **Dev:** "And can the cloud agent pick up the repo-map slice?"
> **Maintainer:** "Not yet — it's labelled **needs-grill**. Only **ready-for-agent** slices with all **blocking edges** merged are up for grabs."

## Flagged ambiguities

- "verify" was used for both the command and the freshness state — resolved: **Verify** is the command; freshness is a property read from `tmp/.last-verify-status`.
- "gate" vs "reminder" — resolved: a **Verify gate** blocks (exit 2); Stop-hook reminders never block (exit 0). The gate is an opt-in exception recorded in ADR-0002.
