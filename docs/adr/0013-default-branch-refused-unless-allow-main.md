# The default branch is refused unless `--allow-main`; no final PR then

ADR-0007 has the runner merge per-issue PRs into the checked-out branch, and
ADR-0008 makes that an integration branch a human later merges into the
default branch through one final PR (#62). Starting on `main`/`master` was
refused outright, which is the right default — a run there lands unreviewed
work on the branch everyone ships from — but it left no way to use `/deliver`
on a repo with no integration-branch workflow.

## Decision

1. **`main` / `master` is refused unless `--allow-main` is passed.** The
   refusal happens in the base-branch precondition, before any forge call,
   and its message names `--allow-main`.
2. **With the flag, `$BASE` is the default branch.** Per-issue PRs target it
   (`--base main`, the unchanged flow) and are merged by the runner as usual.
   Since there is no integration branch to hand over, **no final PR is
   opened**: `final_pr` already skips when `$BASE` is the default branch, so
   the decision needs no extra code path. No PR ever has `main` as its head.
3. **The flag is recorded in `state.json`** (`allow_main: true`). `--resume`
   reads it, so resuming a run that is on `main` does not re-refuse and the
   caller does not have to repeat the flag.

## Consequences

- Opting in is explicit and per run; the safe behaviour stays the default.
- Issues close through the Map/issue mechanics of the per-issue PRs alone —
  there is no final `Closes #N` PR under `--allow-main`.
