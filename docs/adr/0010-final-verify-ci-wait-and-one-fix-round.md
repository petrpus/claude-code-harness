# Final-verify re-enters on a moved base or a fixed CI check; CI gets one fix round

Issue #60 (PRD 0003 § final-verify / merging, ADR-0007 decision 5) closed two
gaps left after the tracer bullet (#57): the runner could merge a head it had
not actually verified once the base moved underneath it, and it had no
opinion about CI at all — a red check and a green one were merged the same
way. This ADR is where issue #60 asked the plan-item that built it (S3) to
record the decisions.

## Decision

1. **`final_verify <n> <dir>` is its own step**, pulled out of `deliver_issue`
   so it can be re-entered rather than inlined once. It fetches, and only
   when `origin/$BASE` is not already an ancestor of the head does it merge:
   `git merge --no-edit origin/$BASE` on the issue branch. A conflict aborts
   the merge and parks with the conflicting paths in `PARK_REASON`, leaving
   the branch exactly as it was. A clean merge re-verifies in a clean tree
   and pushes the merged head as a fast-forward through a new
   `forge_push_update` — plain `git push`, never forced (ADR-0007 decision
   5); a rejected push stops the run rather than forcing past it.
2. **A merge refusal retries `final_verify` exactly once.** `forge_pr_merge`
   tries `--squash` first and falls back to `--merge` when the forge reports
   the repo forbids squash — that is a repo setting, not a race, so it is not
   a "refusal" for this purpose. Any other refusal sends `deliver_issue` back
   through `final_verify` (the base may have moved again while review or CI
   was running) and retries the merge once; a second refusal parks. This
   keeps the "verify the exact head you merge" invariant even when the base
   is moving quickly, without retrying forever.
3. **`ci_wait` sits between review and merge**, polling `forge_pr_checks`
   (`gh pr checks --json name,state,bucket,link`) every `--ci-poll-seconds`
   until nothing is `pending` or `--ci-timeout` passes. No checks reported at
   all is not the same as "no CI ever coming": only after
   `--ci-grace-seconds` with an empty checks array does the run treat it as
   "no CI" and merge anyway (recorded via `deliver_logline ci … none` and a
   `CI: no CI reported.` note on the merge comment) — a repo with CI that
   simply hasn't scheduled checks yet must not be mistaken for one with none.
   Still-pending at the timeout parks, because the runner cannot tell that
   case from CI that will never finish.
4. **A red check spends one fix round, not an automatic park.** `ci_wait`
   records the failing checks (`CI_FAILED_JSON`) and returns "park", but
   `deliver_issue` intercepts a `fail` result before parking and asks
   `round_budget_use` for a round against the issue's shared counter
   (`$dir/ROUNDS_USED`, budget `--max-fix-rounds`, default 2 — the same
   counter #63's review fix rounds draw from, so the two mechanisms
   cannot together give an issue more total fix attempts than the budget
   allows). If a round is available, `ci_fix_round`:
   - fetches the failed run's log tail via `forge_ci_failed_log`
     (`gh run view <id> --log-failed`, last 200 lines, written to
     `issues/<n>/ci-fail-<k>.log` for the record),
   - appends one plan item `- [ ] C<round> Fix red CI: <check>` to the
     issue's `IMPLEMENTATION_PLAN.md`, with the log tail fenced as data (a
     wider tilde-fence than any fence already in the log, so nothing in the
     log can close it early) — data for the model to read, never a plan
     line the runner itself parses,
   - re-opens `STATUS: in-progress` and runs autopilot again on the same
     state dir — a fresh `loop.sh` run since #61 (ADR-0012 decision 7): a
     `--resume-run` restored the first run's clock, so a long build plus a
     long CI wait tripped `--issue-max-minutes` before the fix even began,
   - and, once autopilot ends `done` on a clean tree, goes back through
     `final_verify` → `forge_push_update` → `ci_wait` — the fix is just
     another change to the head, and it gets the same verify-then-CI
     treatment as the original one.
5. **No round left, a second red CI, or autopilot not finishing the fix
   parks**, with the failed run's log tail in the park comment in all three
   cases (`PARK_LOG`, rendered fenced inside a `<details>` block — data,
   never inlined into the one-line reason): the fix round's own
   `ci-fail-<k>.log` when autopilot did not finish, a freshly fetched one
   for the second failure, or for the first when no round was left. A
   dirty tree after the resumed run, or `loop.sh` exiting 1
   (refused to resume), stops the whole run rather than parking — those are
   runner/autopilot-seam failures, not something about this issue's code.

## Considered options

**Treat every red check as an immediate park (rejected).** That was the
state before #60 and it works, but it turns a one-line lint failure or a
flaky test into a manual park for the user to re-drive by hand, when
autopilot already has everything it needs (the failing check's name and log)
to attempt the fix itself.

**An unbounded number of CI fix rounds (rejected).** A check that is red for
a structural reason (the branch genuinely doesn't work) would otherwise loop
forever, burning the same budget #63 needs for review rounds. A shared,
finite counter forces the same trade-off #63 makes for review: fix once,
park otherwise.

**Re-verify without re-polling CI after a fix round (rejected).** The fix
itself is a code change; skipping `ci_wait` the second time would merge a
head whose CI result was never actually observed, defeating the point of
`ci_wait` in the first place.

## Consequences

An issue can now cost up to `1 + MAX_FIX_ROUNDS` autopilot runs instead of
one (fresh `loop.sh` runs since #61, ADR-0012 decision 7; a CI fix round is
granted at most once per issue, `ci_fixed`), so the run log's `ci` lines carry a `<round>` field — a fix round's
second poll must be told apart from the first when reading `run-*.jsonl`
back. `ROUNDS_USED` lives in the issue's state dir, not committed, like the
rest of autopilot's state; a run resumed from a different state dir starts
the counter over.
