# The Map issue is the delivery contract; the issue graph reuses the plan grammar

`/deliver` (PRD 0003) needs a machine-readable answer to "which issues, in what
order". Until now that lived in hand-written map issues (#13, #45): an ASCII DAG
plus prose, readable by people only, kept off agents with a `needs-grill` label.

## Decisions

1. **The Map is a GitHub issue labelled `map`.** It never carries
   `ready-for-agent`. Its body has three sections; only `## Delivery` is parsed:

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

2. **A Delivery line uses the plan grammar with issue refs as ids.**
   `- [ |x] #<N> <title> (after: #A, #B)` is the line format `plan.sh` already
   parses, so `select_next_slice()` walks the issue graph unchanged. This does
   not contradict ADR-0005 decision 2 (plan ids are plan-local): that decision is
   about `IMPLEMENTATION_PLAN.md` inside one run. The Map is a different
   artefact one level up, where the issue number *is* the natural id.
3. **The Map's edges are the source of truth.** Each child issue's
   `## Blocked by` section stays as the human-facing mirror. Pre-flight compares
   the two and warns on a mismatch; the Map wins. An `after:` ref to an issue
   outside the Map is dropped if that issue is closed and is a pre-flight error
   if it is open.
4. **`[x]` means delivered**, by the runner or by hand. The runner skips ticked
   lines — which is also how pieces built before the runner existed are marked.
5. **The title on a Delivery line is the squash subject** when it matches the
   conventional-commit pattern; otherwise the runner derives one from the issue.
6. **The runner edits the body in exactly two ways:** ticking one line and
   appending under `## Follow-ups`. Each edit re-reads the body, changes one
   line, writes it back with `--body-file`, reads it again to confirm, and
   retries if a concurrent human edit dropped it. All progress reporting goes
   into comments, never into the body.
7. **Follow-ups are recorded, never executed by the run that found them.** An
   out-of-scope review finding becomes a `needs-triage` issue linked to the Map
   and the PR. Adding it to Delivery is a human decision after triage.
8. **The final integration → default PR carries `Closes #N`** for every merged
   issue, and `Closes #<map>` only when every Delivery line is ticked.

## Considered options

**GitHub sub-issues and native "blocked by" relationships (rejected for now).**
They are not uniformly available across plans and the `gh` CLI, a fake of them
for offline tests is much larger than a Markdown parser, and they are invisible
in a plain-text body. The Map can later mirror them without changing the runner.

**Read edges from each child's `## Blocked by` (rejected).** It needs one API
call per issue before the order is known, spreads the contract over N bodies,
and those sections are prose written by `/to-issues`, not a grammar.

## Consequences

`/to-issues` gains a step that publishes the Map (a recorded local patch on a
vendored skill). Hand-written maps such as #45 keep working as long as they
have a `## Delivery` section.
