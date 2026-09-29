# Map format

The **Map** is the delivery contract `/deliver` consumes (ADR-0008). It is a
GitHub issue labelled `map` — never `ready-for-agent`. `skills/deliver/map.sh`
is the parser; this file mirrors what it actually reads.

## Body

```markdown
<!-- deliver:map v1 -->
Parent PRD: docs/prd/0003-deliver.md

## Delivery
- [ ] #61 feat(autopilot): loop.sh state-dir and stop-file seams
- [ ] #62 feat(deliver): one issue to a merged PR (after: #61)
- [x] #64 fix(autopilot): gates see committed and untracked work

## Follow-ups
- [ ] #75 found reviewing #62 (PR #72): <title>

## Notes
Free text — ASCII DAG, decisions. Ignored by the parser.
```

## Rules

- **Only `## Delivery` is machine-read.** Headings match `## Delivery` /
  `## Follow-ups` exactly (trailing spaces and CRLF endings are tolerated).
- **A Delivery line** is `- [ ] #<N> <title> (after: #A, #B)`. `-` or `*` bullets
  both parse. Prose and checkboxes without a `#N` id are ignored.
- **`after:` is the edge list** — the Map's edges are the source of truth. Each
  ref must be an issue ref (`#N`) that is itself listed in Delivery; anything
  else is a pre-flight error. Each child issue's `## Blocked by` stays as the
  human-facing mirror; pre-flight warns on a mismatch and the Map wins.
- **Each issue appears once.** A duplicate is a pre-flight error; cycles are
  rejected too.
- **`[x]` means delivered** (by the runner or by hand); the runner skips
  ticked lines. Mark pre-existing work `[x]`.
- **The title is the squash subject** when it is a conventional commit
  (`type(scope): description`, description ≤ 72 chars); otherwise the runner
  derives `<type>: <issue title>` from the issue's labels.
- **The runner edits the body in exactly two ways:** ticking one Delivery line
  and appending under `## Follow-ups`. Progress goes into comments. Follow-ups
  are `needs-triage` issues; adding them to Delivery is a human decision.
- Hand-written maps work as long as they have a `## Delivery` section.
