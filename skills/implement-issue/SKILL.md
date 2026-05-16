---
name: implement-issue
description: Implement a single GitHub issue end-to-end. Composes Pocock's /tdd loop + the code-reviewer agent + verify gates + PR opening. One issue = one PR.
---

# Skill: /implement-issue

Use this to implement a single ready issue. **One issue = one branch = one PR.**
No mega-implementations.

## Input

- GitHub issue number (e.g. `42`)
- Optional: `--base=main` (default), `--draft=true` (open as draft PR)

## Pre-flight

The skill checks at start:

- Issue has label `ready` (otherwise fail with hint to call `/start-feature`)
- Working tree is clean (otherwise fail; user must commit / stash)
- Verify on `main` is green (otherwise fail; fix first)

## Phases

### 1. PLAN

- Read the issue + linked PRD + relevant spec
- Read `CONTEXT.md` (shared language)
- Identify affected files (predicted edits)
- Identify entities + types affected
- If TS types will be non-trivial, **invoke the `typescript-expert` subagent** (Pocock)

Output: short step-by-step plan (5–10 steps). **Show to user and wait for
approval.**

### 2. SCAFFOLD

After plan approval:

- Create branch `feat/<area>-<short-desc>` (from issue title)
- Generate skeletons:
  - Schema/model change (if needed) — fail-fast if migration is dangerous
    (delete column, NOT NULL without default, …) — see `/migration-check`
  - Route/handler scaffold
  - Component scaffold (with `data-testid` for E2E)
  - Test files (`*.test.ts` + `*.e2e.ts`)
- Stub all exports so the build passes but tests fail

### 3. BUILD — TDD loop (Pocock `/tdd`)

**Hand control to Pocock's `/tdd` skill.** It runs:

```
red → green → refactor → ┐
      ↑                  │
      └──────────────────┘
```

In each cycle:

1. Write failing test (red)
2. Write minimum code to pass (green)
3. Refactor — DRY, better names, decoupling
4. Run tests

If the agent stalls in BUILD (more than 2 cycles without progress), invoke
Pocock's `/diagnose` skill.

In parallel:

- No code outside the issue scope (rabbit holes → new issue, not a silent
  side-effect)
- No `any`, no `as Foo`
- No comments explaining WHAT

### 4. REVIEW — `code-reviewer` subagent

After BUILD completes, run the **`code-reviewer` agent** (in `agents/`).
The reviewer gets the diff and a checklist:

- [ ] No defensive `if (!x) return null` without reason
- [ ] No empty try/catch
- [ ] No mock implementations for features that should have been built
- [ ] No `console.log`
- [ ] Tests cover more than the happy path
- [ ] State machine changes go through the proper transition helper
- [ ] Permission checks in loader/action, not in the component
- [ ] No DB queries in components (always via loader)
- [ ] Migration has a sensible name (`add_`/`drop_`/`rename_<subject>`)
- [ ] New enum values are in the spec
- [ ] Spec still matches the implementation

The reviewer returns findings. The implementing agent responds (fix or justify),
then loops until the reviewer is satisfied or a meta-question is flagged for the
user.

### 5. VERIFY

Run the project's verify command (e.g. `pnpm verify`, `npm run verify`).

If anything fails — **find the root cause, don't patch the test**. If you're
stuck, invoke Pocock's `/diagnose`.

### 6. PR

Once verify is green:

- `git push -u origin <branch>`
- `gh pr create` with template description:

  ```markdown
  ## Issue
  Closes #<issue-number>

  ## What
  <bullets matching PRD acceptance criteria>

  ## Spec reference
  - `docs/spec/<...>.md` § <section>

  ## Test plan
  - [x] Unit tests pass
  - [x] E2E smoke tests pass
  - [x] Manual: <if anything specific>

  ## Deviations from spec
  <if any — otherwise "None">
  ```

- If `--draft=true`: open as draft
- Output: PR URL

### 7. Post-PR

- Update issue (linked PR)
- Regenerate any product/derived docs via the appropriate project skill (can be
  a separate PR / part of the next one)
- `/handoff` if the session was long and another session will continue

## When it fails

| Failure | What to do |
|---|---|
| TS types don't fit | `typescript-expert` subagent |
| Test keeps failing | `/diagnose` |
| Spec is ambiguous | Stop, invoke `/grill-with-docs` on that section |
| Issue turns out too big | Stop, go back to `/to-issues` and split |
| Conflict with `main` | Rebase, re-verify, continue |

## Anti-patterns

- **No "I'll fix the test by editing the test"** — find why it fails
- **No multi-issue PR** — one issue, one PR. If you stumble on something else,
  create an issue, not a dependent change
- **No silent scope creep** — if the code reviewer asks for a change outside the
  issue scope, **create a new issue**, don't expand the current PR
