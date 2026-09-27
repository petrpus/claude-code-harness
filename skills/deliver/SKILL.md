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
autopilot's `loop.sh` with the issue as charter → verify the exact head →
push → PR into the integration branch → independent review → squash merge →
tick the Map line.
The runner holds every forge operation; no model phase ever gets `gh` or
`git push` (`docs/adr/0007-*.md`). Design: `docs/prd/0003-deliver.md`.

> **Status: in progress (map #68).** Built: the straight path (#57) and the
> independent review (#59). Not yet: review fix rounds, parking a failing
> issue, CI wait, resume, the tmux launcher. Any failure — including a review
> that requests changes — stops the run with the PR open and the issue branch
> checked out.

## How to run (terminal)

1. Be on a clean **integration branch** (never `main`/`master`), in sync with
   `origin`, with `tmp/` gitignored.
2. Run the runner from the **installed plugin copy**:

   ```bash
   <plugin>/skills/deliver/deliver.sh --map <N> [--verify-cmd '<cmd>'] \
     [--issue-max-iterations 10] [--issue-max-minutes 120] [--issue-budget-usd 10] \
     [--review-model sonnet]
   ```

   The verify command is detected like autopilot's (`package.json` `verify`
   script) unless `--verify-cmd` is given. The `--issue-*` caps are passed to
   each issue's `loop.sh` run.

## The review step

Before any PR merges, `agents/code-reviewer.md` reviews its exact head in one
`claude -p` call on `--review-model` (sonnet by default):

- in a **throwaway `git worktree`** of the head, never in your checkout, with a
  read-only allowlist (`Read, Grep, Glob`, `git diff/log/show`);
- with the issue's charter inlined — it decides what is in scope;
- between two snapshots of your checkout (branch, `HEAD`, `git status`,
  `tmp/.last-verify-status`, worktree list). Any difference is a **safety
  breach** and ends the whole run: a reviewer that moves `HEAD` would send the
  next commit or merge to the wrong place (#52).

The reviewer must end with a JSON block; the runner then **recomputes** the
verdict itself — `changes_requested` if and only if there is an in-scope
blocker or issue — so a reply that lists a blocker and says "approve" still
holds the PR. A reply with no usable verdict is retried once, then holds the
PR (fail closed). The report is posted as a PR comment (GitHub does not let
the PR's author formally approve it) under a
`<!-- deliver:review issue=N round=k head=<sha> -->` marker.

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
- Run state in `tmp/deliver/<run-id>/` — the Map as read, the runner's own
  model calls in `run-<run-id>.jsonl` (loop.sh's schema plus `issue`/`round`,
  readable by `/usage-report`), and per issue `issues/<N>/` (autopilot state
  dir: charter, plan, run log, status, PR body, `review-<k>.md/.json`).

Exit codes: 0 every Delivery line merged · 1 precondition failure or an issue
that did not reach its merge.
