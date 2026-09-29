# In-scope review findings are fixed in bounded rounds on the same PR

ADR-0008 already let the runner park an issue on `changes_requested`
(#58) or run an independent review before anything merges (#59), but a real
blocker then meant a human had to release the park, edit the plan by hand,
and re-run `/deliver` — for findings the reviewer had already named
precisely. Map #68's #63 closes that loop for findings that are actually the
issue's fault.

## Decision

1. **A fix round stays on the same branch and the same PR.** No new branch,
   no new issue, no new autopilot state dir — `loop.sh` runs again on the
   `--state-dir` it already used, so BUILD sees the same charter, memory and
   feedback, and only the plan changed underneath it. It is a fresh run, not
   a `--resume-run`: a first run that spent most of `--issue-max-iterations`
   would otherwise leave a fix round no room to work. (A CI fix round,
   ADR-0010, does resume.)
2. **Only in-scope `blocker` / `issue` findings become plan items.**
   `review_fix_items` (`skills/deliver/review.sh`) turns round `k`'s findings
   into `- [ ] R<k>.<j> — <severity> <file>:<line>: <note>` lines
   (`append_fix_round_items`, `skills/deliver/deliver.sh`), and reopens
   `STATUS:` to `in-progress`. Out-of-scope findings are the Map's problem,
   not this PR's (ADR-0008 decision 7, built by #63's second slice);
   suggestions are never actionable — a `changes_requested` verdict with no
   in-scope blocker or issue is a reviewer contract violation and parks the
   issue instead of starting a round.
3. **A fix round earns no new trust.** After it, `deliver_issue` re-runs
   every gate the first run had: an autopilot exit 1 or a dirty tree stops
   the whole run, anything short of `done` (or a run with no new commit)
   parks the issue, and the full verify command runs again on the exact new
   head with no forge credentials in reach (ADR-0007 decision 6) before
   anything is pushed.
4. **The push is fast-forward only, never forced.** The branch is the
   runner's own and nothing else should be writing to it, but a rejected
   push means something did — a reason to stop the run, not to overwrite
   whatever is there (ADR-0007 decision 5).
5. **The new head is reviewed again as round `k+1`, with round `k`'s
   findings inlined into the prompt** (`review_prompt`'s
   `previous_findings_json` argument) so the reviewer judges the diff
   against what it asked for last time, not cold. The round's PR comment
   names which of those ids the runner's parse marked `resolved`
   (`review_parse`, unchanged from #59).
6. **Rounds come out of the issue's `--max-fix-rounds` budget (default 2).**
   It is the same per-issue counter (`round_budget_use`, `$dir/ROUNDS_USED`)
   a red CI draws from (ADR-0010), so review and CI together can never cost
   more than that many extra autopilot runs. A review still requesting
   changes once the budget is gone parks the issue, naming the review count
   and the PR — same outcome as a first-round park, just later and with more
   of what the review named already fixed. `--max-fix-rounds 0` parks on the
   first `changes_requested`, which is #58's original behaviour.
7. **The PR body is rewritten from the plan after every fix round**
   (`write_pr_body` + the new `forge_pr_set_body`), so a human reading the PR
   sees the same checklist the runner is driving from, not the opening
   snapshot.

## Considered options

**A fresh branch/PR per round (rejected).** Splits one issue's review across
multiple PRs, which the reviewer, the Map and `gh pr view` all assume is one
thing; it would also need its own dependency bookkeeping to supersede the
prior PR.

**Unbounded rounds (rejected).** A reviewer that never approves — a broken
prompt, an unfixable ask, a genuine disagreement — would loop the issue
forever. A cap forces it to a human via the same park path everything else
already uses.

## Consequences

A fix round costs one more autopilot run, one more full verify and one more
review call than a plain approve — the same budget flags
(`--issue-max-iterations`, `--issue-max-minutes`, `--issue-budget-usd`) meant
for one run now cover up to `1 + --max-fix-rounds` of them, so a charter that
was already tightly budgeted may need more headroom. A review round spent
early leaves one fewer for a red CI later, and the other way round.
