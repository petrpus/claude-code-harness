---
name: start-feature
description: Kick off non-trivial feature work from a spec section. Wraps Pocock's /grill-with-docs to align on scope, then /to-prd and /to-issues to break the work into independently-grabbable tasks.
---

# Skill: /start-feature

Use at the start of any larger feature (more than ~3 hours of work). The goal is
**alignment** before anyone touches a keyboard.

## Input

- Path to the spec section (e.g. `docs/spec/<domain>.md`)
- Optional scope filter (e.g. `--scope=workflow`, `--scope=billing`)

## What the skill does

### Step 1 — Load context

- Read the spec document
- Read `CONTEXT.md` (shared language)
- Read relevant ADRs in `docs/adr/`
- Identify overlapping entities and workflows

### Step 2 — Run `/grill-with-docs`

Use Pocock's skill in "grill on this spec section" mode. Goal:

- Resolve ambiguity in the spec
- Identify terms missing from `CONTEXT.md` (add them)
- Add an ADR if a decision hasn't been recorded
- Build a "contract" — what's in scope, what isn't

Output: updated `CONTEXT.md`, possibly a new ADR in `docs/adr/`.

### Step 3 — Synthesize via `/to-prd`

Synthesize the conversation into a PRD. Goal:

- Define user-facing behavior
- Define acceptance criteria
- Identify affected files and modules
- Identify test scenarios

Output: GitHub issue in PRD format (label: `prd`).

### Step 4 — Break down via `/to-issues`

Split the PRD into **vertical slice issues** (each delivers a working
end-to-end piece, not layer-by-layer).

Rules:

- Each issue is a vertical slice that declares its blockers in `## Blocked by`;
  together the issues form a Blocked-by DAG (an issue with no blockers can start
  immediately)
- Target size: 2–6 hours of orchestration
- Issue has acceptance criteria (testable)
- Issue links to the parent PRD issue

Output: list of GitHub issues, each labelled `ready-for-agent`, plus a **Map**
issue (label `map`) listing them in a `## Delivery` section — format in
`skills/deliver/MAP-FORMAT.md`.

### Step 5 — Triage

If you have more issues than capacity for one sprint, use Pocock's `/triage`
skill. Default labels:

- `ready-for-agent` — ready to grab
- `needs-human` — waiting on a human decision or something external
- `needs-triage` — not yet triaged (e.g. review follow-ups)
- `needs-design` — needs a UI mockup (claude.ai/design first)
- `needs-grill` — needs another alignment session

## Skill output

- Updated `CONTEXT.md` (if needed)
- New ADR in `docs/adr/` (if needed)
- Parent PRD issue (`prd`)
- Set of child issues with acceptance criteria (`ready-for-agent`)
- Map issue (`map`) with the Delivery DAG

## After the skill

Call `/deliver #<map>` to deliver the whole Map (one issue = one PR, in
dependency order). To implement a single issue instead, call
`/implement-issue <issue-number>`. Never more than one issue at a time on one
branch — keep 1 issue = 1 PR.

## Anti-patterns

- **Don't use for small bug fixes** — invoke `/diagnose` directly for those
- **Don't use if the spec is already crystal clear** — sometimes `/to-issues` is enough
- **Don't skip the grilling phase** — if there are no questions, it usually means
  you haven't asked enough
