# Autopilot charter

<!--
This is the IMMUTABLE charter for an autonomous run. Copy to
tmp/autopilot/PROMPT.md, fill every section, and do not let the loop edit it.
Derive it from a PRD (/to-prd output) or a GitHub issue — autopilot is for
executing a spec, not discovering one.
-->

## Source

<!-- Mandatory. Link the PRD file or issue this run implements. -->
- PRD / issue: <path or https://github.com/owner/repo/issues/NNN>

## Goal

<!-- One paragraph: what this run must achieve, in outcome terms. -->

## Acceptance criteria

<!--
Mandatory. Concrete, checkable statements — this is what the verifier checks
"done" against. Prefer observable behavior over implementation.
-->
- [ ] …
- [ ] …
- [ ] All acceptance tests pass under the project verify command.

## In scope

- …

## Out of scope

<!-- Anything the loop must NOT touch. The verifier flags silent scope creep. -->
- …

## Constraints & notes

<!-- Stack conventions, files to avoid, perf/security requirements, data-safety
     rules (e.g. no destructive migrations), etc. -->
- Follow the repo's `CLAUDE.md` and `CONTEXT.md`.
- Tests are required for every behavior change (TDD: red-green-refactor).
- Record any architectural decision as a `docs/adr/` entry.
