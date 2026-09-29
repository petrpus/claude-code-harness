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

> **Status: in progress (map #68).** Built: the straight path (#57), the
> independent review (#59), parking (#58), final-verify's base-moved
> handling and merge retry, the CI wait with its fix round (#60), bounded
> review fix rounds with follow-up issues (#63), and run state / resume /
> stop / global caps (#61). Not yet: the tmux launcher.

## When an issue does not make it

An issue that cannot reach its merge is **parked** and the run carries on:
autopilot did not finish (stuck, or an iteration / time / budget cap), it
finished without a commit, verify failed on its head, the review held its PR
(changes requested, or no usable verdict twice), the integration branch moved
into a conflict, CI failed or stayed pending past `--ci-timeout`, or the forge
refused the merge twice. Before merging, **final-verify** re-fetches and, if
the integration branch moved, merges it into the issue branch (a conflict
parks the issue; a clean merge is re-verified and pushed); a merge the forge
refuses goes back through final-verify once — a repo whose branch protection
forbids squash merges gets a plain `--merge` instead, tried automatically,
before that ever counts as a refusal. Parking:

- labels the issue `needs-human` (created if the repo lacks it) and removes
  `ready-for-agent`;
- turns its PR, if one was opened, back into a draft;
- comments on the issue with the cause, autopilot's state and cost, and
  autopilot's last feedback;
- keeps the issue branch (local, and on the remote once pushed) for a human.

Issues that wait on a parked one (transitively) are **skipped**; independent
ones continue. The run ends with exit **2** and a summary naming both lists.

A failure of the machinery itself — the forge unreachable, autopilot refusing
to start, a dirty checkout, a review that changed the checkout — is not an
issue's fault: it ends the run with exit 1, where it is.

## How to run (terminal)

1. Be on a clean **integration branch** (never `main`/`master`), in sync with
   `origin`, with `tmp/` gitignored.
2. Run the runner from the **installed plugin copy**:

   ```bash
   <plugin>/skills/deliver/deliver.sh --map <N> [--verify-cmd '<cmd>'] \
     [--issue-max-iterations 10] [--issue-max-minutes 120] [--issue-budget-usd 10] \
     [--review-model sonnet] [--extra-allowed-tools '<csv>'] [--per-call-timeout <s>] \
     [--plan-max-items 3] [--verify-every-iteration] [--iteration-verify-cmd '<cmd>'] \
     [--ci-poll-seconds 30] [--ci-timeout 1800] [--ci-grace-seconds 120] \
     [--max-fix-rounds 2] [--budget-usd <n>] [--max-minutes <n>] \
     [--resume [--retry '#N']]
   ```

   The verify command is detected like autopilot's (`package.json` `verify`
   script) unless `--verify-cmd` is given. The `--issue-*` caps and
   `--extra-allowed-tools` (appended to autopilot BUILD's allowlist — e.g.
   `'Bash(bash scripts/test-deliver.sh),Bash(jq:*)'` for a shell project) are
   passed to each issue's `loop.sh` run. The check fails closed (ADR-0007:
   no model phase holds a forge operation): a `Bash(...)` rule is accepted
   only as a **plain command** — words of `[A-Za-z0-9._/+=:@%,-]`, optionally
   ending in `:*` or ` *` — whose program (by basename, any letter case) is
   not a forge CLI (`gh`, `gh-*`, `git`, `hub`, `glab`, `lab`), not a program
   that runs other programs (`env`, `command`, `timeout`, `nice`, `xargs`,
   `eval`, `sudo`, `ssh`, `find`, …), not a package runner (`npx`, `npm`,
   `pnpm`, `yarn`, `bunx`, `deno`, `uvx`, …) and not an interpreter without a
   script path (`bash -c`, `bash:*`, `python3 -c`).
   Quotes, backslashes, `$`, `;`, `|`, `&`, redirections, a leading `VAR=`,
   wildcards inside the command, a blanket `Bash` and malformed rules are
   refused outright. This is defence in depth, not the boundary, and cannot
   be complete: BUILD edits files and runs the verify command, and
   autopilot's own base allowlist already grants `npx`, `pnpm` and `node`. Keeping forge credentials away from model
   phases is the boundary, and is tracked in #77 (map #68).

## The review step

Before any PR merges, `agents/code-reviewer.md` reviews its exact head in one
`claude -p` call on `--review-model` (sonnet by default):

- with **no shell and no write tool**: `Read, Grep, Glob` only, Bash / Edit /
  Write disallowed, `default` permission mode. (A git allowlist is not
  read-only — `git diff --output=<file>` writes.) The runner inlines the
  commits, stat and diff into the prompt instead;
- in a **throwaway `git worktree`** of the head, never in your checkout;
- with the issue's charter inlined — it decides what is in scope;
- between two snapshots of your checkout: every ref (the base and
  remote-tracking refs included), `HEAD`, `git status`, the repo's config,
  hooks and `info/`, the worktree list, and the content of every file under
  `tmp/`. Any difference is a **safety breach** and ends the whole run (#52).

The reviewer ends with a JSON block that must name the head under review;
a block without it (a restated format example, say) is not read. The runner
then **recomputes** the verdict itself — `changes_requested` if and only if
there is an in-scope blocker or issue — so a reply that lists a blocker and
says "approve" still holds the PR. A reply with no usable verdict is retried
once, then holds the PR (fail closed). The report is posted as a PR comment
(GitHub does not let the PR's author formally approve it) under a
`<!-- deliver:review issue=N round=k head=<sha> -->` marker.

## Review fix rounds (`--max-fix-rounds`, default 2)

A `changes_requested` verdict does not park the issue outright. Every
in-scope `blocker` / `issue` finding of that round becomes a fresh plan item
(`- [ ] R<k>.<j> — <severity> <file>:<line>: <note>`) appended to the issue's
`IMPLEMENTATION_PLAN.md`, its `STATUS:` line is reopened to `in-progress`, and
`loop.sh` runs again on the **same** `--state-dir` — so BUILD sees the same
charter, memory and feedback, and only fixes what the review named. Each
round is a fresh autopilot run with its own `--issue-max-*` caps; how many
rounds an issue may spend is what `--max-fix-rounds` bounds.
Out-of-scope findings and suggestions never become plan items — a suggestion
never appears anywhere but the review's own PR comment.

Once that round's autopilot run reports done, the same gates as the first run
apply: an autopilot exit 1 or a dirty tree stops the whole run, anything
short of `done` (or a run with no new commit) parks the issue, the full
verify runs again on the new head, and the branch is pushed **fast-forward
only** — never forced; a rejected (non-fast-forward) push stops the run. The
PR body is rewritten from the current plan (`forge_pr_set_body`, `gh pr edit
--body-file`), and the new head is reviewed again as round `k+1`, with round
`k`'s findings inlined into the prompt so the reviewer can judge what was
fixed — the round's PR comment lists the ids it marks `resolved`.

Each fix round spends one round from the issue's `--max-fix-rounds` budget,
the same counter a red CI draws from (below). A review still requesting
changes once the budget is gone parks the issue, with a reason naming the
review count and the PR; `--max-fix-rounds 0` parks on the first
`changes_requested`. Decision record: `docs/adr/0011-*.md`.

## Out-of-scope findings become follow-up issues

Every out-of-scope `blocker` / `issue` finding (suggestions are never
followed up — they only ever appear in the review's PR comment) becomes a
`needs-triage` issue instead of a plan item, in every round, whether that
round approves or requests changes:

- a **finding hash** (sha256 of its normalized `file`, `line` and `severity` — not the note, which a fresh reviewer words differently every round)
  is its identity across rounds, autopilot re-runs and separate `/deliver`
  invocations. `forge_issue_search` looks for an open or closed issue already
  carrying `<!-- deliver:finding <hash> -->`; only when there is none does
  `gh issue create --label needs-triage` open a new one (label created if the
  repo lacks it), titled from the finding's `issue_title` (else a conventional
  fallback) and linking the Map, the PR and the `file:line`;
- the follow-up (found or freshly created) is appended under the Map's
  `## Follow-ups` section (`map_add_follow_up`, `docs/adr/0008-*.md` decision
  7) — created if the Map has none yet, and only once per issue number, with
  the same re-read/write/read-back retry as ticking a Delivery line;
- it is also listed in the PR body's `## Follow-ups` section
  (`forge_pr_set_body`), kept in sync after every round that finds one.

A follow-up is **recorded, never executed** by the run that found it: it
never touches `## Delivery`, gets no branch and no autopilot run — adding it
to a Map's Delivery section is a human decision made after triage.

## The CI wait

Once the review approves, `ci_wait` polls `gh pr checks` (`forge_pr_checks`)
every `--ci-poll-seconds` (default 30) before the PR may merge:

- **no check reported at all** once `--ci-grace-seconds` (default 120) has
  passed is **"no CI"** — the runner logs it (`ci` phase, verdict `none`) and
  merges anyway, noting `CI: no CI reported.` on the issue's merge comment;
- **all reported checks pass** (nothing left `pending`): merges, logged with
  verdict `pass`;
- **any reported check fails**: spends one round from the issue's shared
  `--max-fix-rounds` budget (default 2, shared with the review fix
  rounds above). The fix round fetches the failed run's log tail
  (`forge_ci_failed_log`, `gh run view <id> --log-failed`), appends a
  `- [ ] C<round> Fix red CI: <check>` plan item with the log fenced as data,
  reopens `STATUS: in-progress` and resumes autopilot (`loop.sh
  --resume-run`); a clean finish goes back through final-verify and
  `ci_wait`. No round left, autopilot not finishing the fix, or CI still red
  after the round parks — with the failed checks' names in the reason and
  the failed run's log tail in the park comment — logged with verdict
  `fail`;
- **still `pending` past `--ci-timeout`** (default 1800 s): parks ("CI still
  pending after …"), no fix round (the check never actually failed); logged
  with verdict `timeout`.

**Pacing.** An issue is already one PR-sized slice, so by default autopilot
gets `--plan-max-items 3` (a small plan; `--plan-max-items 0` lifts it) and
`--verify-at-completion`: after each item BUILD runs only the tests covering
it, and the full verify runs once, when the plan is complete — then again as
this runner's final verify on the head. `--iteration-verify-cmd '<cmd>'` adds
a cheap check after every item; `--verify-every-iteration` restores the full
verify per item.

`--per-call-timeout <s>` bounds every model call — autopilot's and the
review — in whole seconds (default 1200). Raise it when the verify command is
slow: BUILD runs verify itself, and in this repo (`scripts/verify.sh` ≈ 6 min)
the default cut the first BUILD off after a couple of runs.

**Stopping a run.** Ctrl-C in the terminal does not stop it: `timeout` runs
each `claude -p` in its own process group, so the signal never reaches the
call, and the runner waits for it. Instead, drop a `STOP` file at
`tmp/deliver/<run-id>/STOP` (e.g. `touch tmp/deliver/*/STOP`) — it is checked
between phases (before a branch, after a build, before a PR, before a
review, before a merge) and passed to every `loop.sh` call as `--stop-file`,
so a build already in flight stops the same way. The run ends with exit
**6**, state `stopped`, the in-flight issue left non-terminal — resumable.

**Global caps.** `--budget-usd <n>` / `--max-minutes <n>` bound the whole
run: total cost sums the runner's own model calls and every issue's inner
`loop.sh` run (excluding `loop.sh`'s own per-iteration summary rows); active
time is this run's accumulated `active_seconds`, which survives a
`--resume`. Checked at the same phase boundaries as the STOP file. Tripping
a cap ends the run with exit **4** (budget) or **3** (time), state
`budget_exhausted` / `time_exhausted`, the in-flight issue left non-terminal.
Each issue's own `--issue-budget-usd` / `--issue-max-minutes` is clipped to
whatever the global cap has left before that issue's `loop.sh` call, so no
single issue can spend past the point the whole run is allowed to reach.

**Resuming a run.** `--resume` picks the newest `tmp/deliver/*/state.json`
for this `--map`, removes a stale `lock` (a pid no longer alive; a live one
refuses the run outright), switches the checkout back to the run's recorded
base if needed, makes a fresh private runner copy (warning on stderr, never
refusing, when `plugin.json`'s version differs from the one `state.json`
recorded), restores `active_seconds`, then reconciles every issue this run's
state still calls non-terminal against GitHub — **GitHub wins**
(`docs/adr/0012-*.md`): the Map tick or a merged PR settles an issue as
merged, the issue closed settles it as closed-externally, `needs-human`
settles it as parked. Anything else resumes exactly where this run's own
`state.json` left it: a pushed head without a PR gets one; an open PR is
re-entered at the review round `state.json` recorded (the round's marker —
issue, round, head — keeps a review the interrupted attempt already posted
from being posted twice), with fix rounds, the CI wait and the merge after it
as usual; a local copy of the branch ahead of origin (a fix round that
committed but never pushed) is re-verified and pushed first, one that
diverged stops the run; a local-only branch resumes autopilot with `loop.sh
--resume-run`. A leftover branch this run's state does *not* know about is
still parked, unchanged from #58 — `--resume` only continues a branch its
own run started.

`--retry '#N'` (with `--resume`, and only for an issue this run recorded as
parked — anything else is refused, since it would discard live work) forgets a parked issue's recorded
branch/PR, closes/deletes what it left behind, drops `needs-human`, and
gives it a fresh inner run — same as the park comment's own "To retry" line
says.

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
- Run state in `tmp/deliver/<run-id>/` — `state.json` (resume truth: map,
  base, runner version, active time, per-issue state/branch/PR/round/head),
  `events.jsonl` (one row per issue-state transition), `status.json` (the
  run's current headline), a `lock` (this process's pid, removed on exit),
  the Map as read, the runner's own model calls in `run-<run-id>.jsonl`
  (loop.sh's schema plus `issue`/`round`, readable by `/usage-report`), and
  per issue `issues/<N>/` (autopilot state dir: charter, plan, run log,
  status, PR body, `review-<k>.md/.json`).

Exit codes: 0 every Delivery line merged · 1 precondition or runner failure ·
2 partial (something was parked, and whatever waits on it skipped) · 3 global
`--max-minutes` reached · 4 global `--budget-usd` reached · 6 stopped (a
`STOP` file was present). 3, 4 and 6 leave the run resumable with `--resume`.
