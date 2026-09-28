# state.json is resume truth; GitHub wins on reconcile

`--resume` (#61) has to answer two different questions with two different
sources: *what was this run doing* and *what actually happened since*.
`state.json` (`skills/deliver/state.sh`) is the only source for the first —
it is the one place the run's own view of each issue (branch, PR, round,
head) is written atomically, on every transition, by the process that made
it happen. Nothing else records that. But it is stale the moment a
network call, a review, or a human's own action lands after the last write
that reached disk — a run killed mid-review may say `pr-open` when the PR
has since been reviewed, merged and had its branch deleted by hand.

## Decision

1. `state.json` decides *which issue to look at and how* — its `branch`,
   `pr` and `state` fields are what `--resume` uses to find an issue's
   in-flight work at all. An issue this run's `state.json` has no record of
   is not "this run's to resume"; a leftover branch for it is still parked,
   unchanged from #58 (`deliver.sh`'s branch-exists dispatch only continues
   a branch its own `state.json` names).
2. For every issue `state.json` still calls non-terminal, `--resume`
   reconciles against GitHub once, before the graph walk, and **GitHub
   wins**: a Map tick or a `MERGED` PR settles the issue as merged even if
   `state.json` last said `pr-open`; the issue closed settles it as
   closed-externally; `needs-human` (added by a human, or by another
   machine) settles it as parked. `state.json` is corrected to match and the
   run carries on — never the other way around, and never by refusing to
   resume.
3. Anything reconcile does not settle (still building, a PR still open with
   no merge yet, pushed with no PR) is left exactly as `state.json` has it.
   The graph walk's own branch-exists dispatch (unchanged since #58, now
   informed by `state.json`) picks it up lazily, the moment it is reached —
   reconcile does not have to enumerate every possible in-flight shape.
4. Markers (`<!-- deliver:review issue=N round=k head=<sha> -->` and
   friends, #61 S2) are what make re-entering a phase safe once GitHub has
   won: a resumed run re-does the *check*, not the *write*, so a review or a
   park/merge comment that already landed is never posted twice.

## Consequences

A `--resume` always makes at least one GitHub read per non-terminal issue
before doing anything else — the cost of never trusting a state file that
cannot know what happened while the run was dead. An issue `--resume`
cannot re-read (the forge briefly unreachable) is left as `state.json` last
recorded it rather than guessed at; the next `--resume` tries again. Because
GitHub always wins, a human is free to intervene directly — tick the Map,
close the issue, merge the PR by hand, label it `needs-human` — and the next
`--resume` picks that up as truth without needing to know it happened.
