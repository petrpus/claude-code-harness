# Under /deliver, the full verify runs once per issue, not once per plan item

Autopilot's gate (b) — the runner running the verify command itself — used to
run on every iteration, and for a reason: before that, an iteration whose plan
was not complete skipped it, and incremental work was checkpointed as "wip"
without the runner ever verifying it (see the comment at gate (b) in
`skills/autopilot/loop.sh`).

The live `/deliver` runs (map #82 → #56) measured what that costs when the
charter is a single issue. `/to-issues` had already cut the work to one PR;
autopilot's PLAN cut it again into six items, and each item paid a full
verify twice — once by BUILD before ticking, once by the runner — plus the
verifier: about fifteen minutes per item, ninety for the issue, most of it
waiting on `scripts/verify.sh`.

## Decision

1. `loop.sh --verify-at-completion` (opt-in) runs gate (b)'s full verify only
   on the iteration that completes the plan — `STATUS: done` **or** every box
   ticked, a deliberately looser condition than "both", so a BUILD that ticks
   the last box but forgets `STATUS` is still verified. Other iterations run
   `--iteration-verify-cmd` if one is given (a cheap check), otherwise no
   machine verify; BUILD proves its item with the tests that cover it.
2. The completing iteration is gated exactly as before: a red verify there is
   a failure — feedback, `STATUS` back to in-progress, the stuck ladder — so a
   run can still only exit `done` on a green full verify.
3. `loop.sh --plan-max-items <n>` tells PLAN and replan the charter is already
   one PR-sized slice: at most n items, documentation folded into the item it
   documents.
4. `/deliver` uses both by default (`--plan-max-items 3`,
   `--verify-at-completion`). It may, because another gate stands behind every
   issue: the runner's own full verify on the exact head before the PR, the
   independent review, and CI — nothing merges on an unverified head.
5. A bare autopilot run keeps verifying every iteration. Its charter may be a
   whole PRD with nothing behind it.

## Consequences

Iterations between completions are not machine-verified. A slice that breaks
something is found at completion rather than immediately, with more changes
in the diff to untangle; the verifier (gate d) still reviews every
iteration's diff, but without a green test run behind it. `status.json` counts
the deferred iterations (`verify_deferred`), because a run with deferrals
reports a structurally lower `gate_fail_rate` than one without.
