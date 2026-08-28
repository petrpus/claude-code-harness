# Holdout scenarios are hidden by location, not by permissions

Autopilot's semantic gate has a structural weakness: `verify_prompt()` hands the
verifier the same `PROMPT.md` that BUILD was given, so the build model knows the
criteria it will be judged against and can write exactly the tests those criteria
name. A **Holdout** — acceptance scenarios in Given/When/Then form that the build
model never sees — fixes that, but only if "never sees" actually holds.

We hide it by **keeping it outside the worktree** rather than by denying tools.
The file lives at `${XDG_STATE_HOME:-$HOME/.local/state}/autopilot/<run-id>/HOLDOUT.md`
(overridable with `--holdout <path>`), the runner reads it with plain `cat` and
inlines its *content* into the verifier prompt. BUILD is never told the path and
there is nothing to read inside the repo.

## Considered options

**Deny the tools (rejected).** `--disallowedTools "Read(tmp/autopilot/HOLDOUT.md)"`
closes one of four routes. BUILD's allowlist (`loop.sh`) also grants `Bash(cat:*)`,
`Bash(ls:*)` and — decisively — `Grep`, which is a reader with a filter: the pattern
`.` matches every non-empty line and the tool prints them. `Grep` cannot be
path-scoped without cutting BUILD off from a tool it genuinely needs. Closing the
hole would take five coordinated changes (Read deny, `cat` narrowing, `Grep`,
`pre-edit.sh`, `.gitignore`), each able to fail silently — and a silently disabled
gate still reports green. It also depended on path-scoped `Read` denial existing in
headless mode at all, which was the PRD's own top risk.

**Move the file in and out around each BUILD call (rejected).** Correct in the happy
path, but `run_claude` wraps every call in `timeout` and the runner can be
interrupted. A kill inside the window leaves the holdout outside the repo, and by
the backward-compatibility contract a missing holdout disables the gate with a
notice — so the failure mode is a quietly weaker run.

**Accept it as advisory (rejected).** Keeping it in-repo and unhidden still gives the
verifier concrete scenarios instead of a generic checklist, but it forfeits the
anti-gaming property that justifies the slice. If we ever want that, the scenarios
belong in a `PROMPT.md` section and this ADR should be superseded.

## Consequences

The residual hole is guessing: BUILD could `ls ~/.local/state/autopilot/`. This is
security by obscurity and we record it as such — the claim is "the build model is
not handed the scenarios", not "the build model cannot obtain them". Hardening past
this needs process-level sandboxing, which is out of scope.

Holdouts stop being versioned with the project. That prevents accidental commits,
but a team wanting shared, reviewed holdouts must keep them somewhere else and point
`--holdout` at them. `tmp/autopilot/HOLDOUT.md` is deliberately *not* a supported
location; if a file appears there it is a mistake, not a fallback.

BUILD's allowlist is unchanged by this decision — no `Bash(cat:*)` narrowing, no
`Grep` restriction, no new `--disallowedTools` — so the hiding mechanism adds no new
way for a run to fail.
