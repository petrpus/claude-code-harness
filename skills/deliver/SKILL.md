---
name: deliver
description: >-
  Deliver a Map issue — every issue in its Delivery section becomes its own
  PR into the current integration branch, built by autopilot, verified,
  squash-merged and ticked, in blocking-edge order. Use when the user asks to
  "deliver map #N", "run the map", "doruč mapu", or to work through a set of
  issues one PR at a time.
---

# deliver — a Map of issues to merged PRs

`/deliver` walks a **Map** (a `map`-labelled issue, `docs/adr/0008-*.md`) and,
per issue, in blocking-edge order: branch off the integration branch → run
autopilot's `loop.sh` with the issue as charter → push → PR into the
integration branch → verify the exact head → squash merge → tick the Map line.
The runner holds every forge operation; no model phase ever gets `gh` or
`git push` (`docs/adr/0007-*.md`). Design: `docs/prd/0003-deliver.md`.

> **Status: tracer bullet (#57).** Only the straight path exists: no
> independent review, no parking of a failing issue, no CI wait, no resume,
> no tmux launcher. Any failure stops the run with the issue branch checked
> out. Those arrive with the rest of map #68.

## How to run (terminal)

1. Be on a clean **integration branch** (never `main`/`master`), in sync with
   `origin`, with `tmp/` gitignored.
2. Run the runner from the **installed plugin copy**:

   ```bash
   <plugin>/skills/deliver/deliver.sh --map <N> [--verify-cmd '<cmd>'] \
     [--issue-max-iterations 10] [--issue-max-minutes 120] [--issue-budget-usd 10]
   ```

   The verify command is detected like autopilot's (`package.json` `verify`
   script) unless `--verify-cmd` is given. The `--issue-*` caps are passed to
   each issue's `loop.sh` run.

The runner first copies the plugin to
`${XDG_STATE_HOME:-~/.local/state}/claude-code-harness/deliver/<run-id>/runner/`
and re-executes from there, so a BUILD that edits the harness itself never
edits the script running it.

## What you get

- One squash commit per issue on the integration branch, subject = the Map
  line's conventional title (or `<type>: <issue title>`), `(#<pr>)` appended.
- The Map's Delivery lines ticked `[x]`, a comment on each merged issue.
  Issues stay open: GitHub closes them only when the final integration →
  default-branch PR merges.
- Run state in `tmp/deliver/<run-id>/` — the Map as read, and per issue
  `issues/<N>/` (autopilot state dir: charter, plan, run log, status, PR body).

Exit codes: 0 every Delivery line merged · 1 precondition failure or an issue
that did not reach its merge.
