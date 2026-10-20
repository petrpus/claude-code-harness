# The work branch, the `--into` branch and `--via` are chosen per run

ADR-0008 has a `/deliver` run merge every issue PR into an integration branch,
and #62 then always opened one final PR from that branch into the repo's
default branch. Projects that integrate somewhere else first — a `test` or
`staging` branch — and often by fast-forwarding the work branch rather than
through a PR got a PR into `main` they did not want after every run. The skill
never asked about it, because the runner had nothing to ask about.

## Decision

1. **Three values make a run's procedure**: the *work branch* (where issue
   PRs merge — what ADR-0008 calls the integration branch), the *`--into`*
   branch the work branch goes to at the end, and *`--via`*, how it gets
   there: `pr` | `ff` | `none`. Defaults: the checked-out branch, the default
   branch, `pr` — the pre-0.8.6 behaviour, so a terminal run without the
   flags is unchanged.
2. **`--work-branch <branch>`** switches to the branch, or cuts it off
   `origin/<into>` and pushes it when it exists neither locally nor on
   origin. `--create-integration` stays as a named shortcut for a new
   `integration/<map-slug>`, now also cut off `origin/<into>`.
3. **`--via pr`** is #62's final PR, aimed at `--into`; a human merges it.
   **`--via none`** integrates nothing.
4. **`--via ff` is a runner forge operation** (ADR-0007: the runner may
   write, a model phase may not): once every Delivery line merged, the runner
   moves `origin/<into>` to the work branch's tip with an unforced push. It
   is never forced and never a merge commit — not a fast-forward means it is
   not done, and the run says so. A partial run does not fast-forward:
   integrating half a Map is a human decision.
5. **`--via ff` into the default branch is refused**, before the run starts.
   The branch everyone ships from only changes through a PR a human merges,
   as ADR-0013 keeps it for `--allow-main`. An `--into` that already has
   commits the work branch lacks is refused up front as well, since the
   fast-forward could never succeed and the run would spend its budget first.
6. **The skill settles the procedure before launching.** Any of the three the
   user did not pass, `/deliver` proposes (the project's documented
   convention first) and the user approves or corrects explicitly; the
   launch then passes all three. `--yes` skips that question only when all
   three were given. Without a Map the skill proposes the path to one and
   starts no `/to-prd` (or `/start-feature`, `/to-issues`) on its own.
7. `--into` / `--via` are recorded in `state.json` (`integration`); `--resume`
   keeps them unless new ones are passed.

## Consequences

- The runner can now push to a branch other than issue branches and the work
  branch — only by fast-forward, only to a non-default branch, only after a
  complete run. Branch protection on `--into` can still refuse that push; it
  is then logged, not fatal.
- `Closes #N` only acts on the default branch, so after `--via ff` or
  `--via pr` into a non-default branch the issues stay open until the work
  reaches it. The final PR says so in its body.
- `--plan-only --json` reports the procedure as `integration`, with `given[]`
  naming the values the user passed, so the skill knows what it must ask.
