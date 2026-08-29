# Holdout scenarios

<!--
docs/adr/0006-holdout-scenarios-hidden-by-location.md

DO NOT copy this file into the repo, and do NOT save it under tmp/autopilot/
(tmp/autopilot/HOLDOUT.md is explicitly unsupported — BUILD can already read
everything else in tmp/autopilot/, so a holdout placed there is not hidden at
all). Save it outside the worktree instead:

  ${XDG_STATE_HOME:-$HOME/.local/state}/autopilot/<run-id>/HOLDOUT.md   (default)

or point `--holdout <path>` at wherever you keep it. The runner `cat`s this
file and inlines its content into the verifier's prompt only — BUILD never
sees the path or the content.

Write scenarios in Given/When/Then form, one per heading, each with a short
id (H1, H2, ...) the verifier can cite back in its verdict's
`holdout.failed` list and that will show up in FEEDBACK.md if unmet.
-->

## H1: <short scenario title>

- Given: <starting state>
- When: <the action the change should support>
- Then: <the observable, checkable outcome>

## H2: <short scenario title>

- Given: …
- When: …
- Then: …
