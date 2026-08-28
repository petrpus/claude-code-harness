# autopilot — loop protocol & safety rationale

This is the detailed contract behind `loop.sh`. Read it before trusting a long
unattended run, or before changing the runner.

## The core idea (and what we fixed)

loopkit's insight: run each turn as a fresh `claude -p` with state on disk, so
context never rots. Its flaw: the loop had no teeth — no iteration cap, no
budget, verify failure only got `echo`'d and the loop continued, no logging, no
model pinning. autopilot keeps the insight and adds the enforcement.

**Fresh context each iteration.** `loop.sh` never passes the CLI `--resume`/
`--continue` — every `claude -p` starts clean. The `--resume-run` *flag on
loop.sh* is different: it only re-reads `tmp/autopilot/` disk state so a killed
run can pick up where it left off. Continuity comes from disk, not from a
growing window.

## State files (`tmp/autopilot/`)

| File | Role |
|---|---|
| `PROMPT.md` | Immutable charter for the run. Derived from a PRD or issue; must carry a source link + acceptance criteria. Never edited by the loop. |
| `IMPLEMENTATION_PLAN.md` | Checklist of independently verifiable vertical slices + a final `STATUS: in-progress\|done` line. Written by PLAN, ticked by BUILD, sentinel-checked by the gate. Slice lines may carry `(after: <id>, <id>)` — the **Plan DAG** the runner selects from each iteration (`plan.sh`, `docs/adr/0005-*.md`). |
| `MEMORY.md` | Durable cross-iteration notes. Mechanically pruned to the last 100 lines every iteration — instructions to the model are advisory; the cap is enforced by the runner. |
| `FEEDBACK.md` | Why the last gate failed. The next BUILD iteration must address it first. Cleared when consumed. |
| `status.json` | Live run state, iterations done, accumulated cost, HEAD sha. |
| `run-<id>.jsonl` | Structured per-phase log (see below). |
| `lock` | `PID run_id` — concurrency guard with stale-PID detection. |

## Iteration flow

```
PLAN  (once, if no plan)   opus     acceptEdits, write-only tools
  └─ writes IMPLEMENTATION_PLAN.md as verifiable vertical slices, ids +
     optional (after: ...) edges — a Plan DAG (docs/adr/0005-*.md)
loop:
  SELECT  select_next_slice()  runner   pure parsing (plan.sh), no `claude` call
    └─ picks the one unblocked, unparked slice to build this iteration
    └─ broken DAG (cycle / unknown after: id) → Plan-dependency failure,
       fingerprint plan_dag, straight to replan — bypasses the ladder below
  BUILD                    sonnet   acceptEdits + explicit --allowedTools
    └─ exactly the selected plan item, TDD (red-green-refactor), ADR if
       architectural, run verify, tick box, append MEMORY, set STATUS
  GATE b  machine verify   runner    executes the verify command itself
  GATE c  secret scan      runner    greps the diff for keys/tokens
  GATE d  semantic verify  haiku     agents/verifier.md, adversarial, JSON verdict
  then, gates green:
    STATUS: done          → checkpoint, exit 0
    more boxes ticked     → checkpoint "progress", continue (NOT a failure)
    nothing moved         → no-progress failure
  any gate red            → FEEDBACK.md, reset sentinel, checkpoint WIP, maybe replan
```

### Slice selection (S1B)

Before BUILD runs, the runner calls `select_next_slice()` (`plan.sh`, sourced
by `loop.sh`) over `IMPLEMENTATION_PLAN.md`'s Plan DAG and injects the chosen
id and its exact line into `build_prompt()`: "Do exactly the plan item `<id>`
selected by the runner … do not start any other item." On a plan with no
`after:` annotations at all, every slice is unblocked, so selection reduces
to "first unchecked box in file order" — 0.4.0 behaviour, unchanged.

A **Plan-dependency failure** (`select_next_slice()` returns 2: an `after:`
clause names an id that doesn't exist anywhere in the plan, or the `after:`
edges cycle) is explicitly **not** one of gates (b)–(d) above and is not
fingerprinted the same way a gate failure is: it feeds `FEEDBACK.md` and goes
straight to a replan pass every time it recurs, never through the
retry/park/abort ladder — a broken DAG is a defect in the plan the PLAN phase
wrote, and no amount of retrying or escalating the BUILD call can fix it.
"Every remaining candidate is parked, or blocked by a parked one" (return 3)
is handled the same way — replan, which also unparks everything (S4A); this
path is unreachable until S4A's per-slice state exists, since nothing calls
`select_next_slice()` with any parked ids yet.

`agents/verifier.md` gained shortcut **#14 — ticked a slice other than the
one assigned**: the verifier is told which id was selected this iteration
(`verify_prompt()`) and treats a checkbox change to any other slice as a
violation, even if that other slice is genuinely done — its diff wasn't
reviewed this iteration.

### Why completion is not a per-iteration gate

BUILD is told to do exactly **one** plan item per iteration, so on any plan
longer than one slice `STATUS: done` is false by construction until the last
one. Treating that as a gate failure — which this loop did until the flaw was
found in its first real run — made every intermediate iteration
indistinguishable from a genuine failure, fingerprinted them all identically,
and tripped the stuck detector after three. **A plan of more than three slices
could not finish**, and the loop applied pressure toward doing everything in a
single iteration: exactly the opposite of the slice-by-slice discipline it
exists to enforce.

So progress is *measured* instead: the runner counts ticked checkboxes in
`IMPLEMENTATION_PLAN.md` before and after BUILD. More ticked, with every gate
green, is progress — checkpointed and continued, and it resets the stuck
counter. Nothing ticked and not done is the real no-progress signal, and that
is what the stuck detector counts. `STATUS: done` keeps one job only: ending
the run.

Two consequences worth knowing. Gates (b)–(d) now run on **every** iteration;
previously the completion check short-circuited them, so incremental work was
committed as "wip" without the runner ever verifying it. And because progress
is read from checkboxes, a plan written without them can't be measured — the
runner says so and falls back to the iteration/time/budget caps rather than
inventing a failure.

### Why the runner runs verify, not the model

Gate (b) executes the verify command in the runner's own shell and reads the
exit code. The build model's *claim* that verify passed is never trusted —
shortcut #5 (modifying the verify command) and #10 ("done" without running it)
are exactly the failures a self-reported gate misses.

### Why a separate cheap verifier

Gate (d) is a **fresh haiku instance** that assumes the code is broken. An
author model rationalizes its own shortcuts; an independent skeptic on a cheap
model, run every iteration, is both cheaper and more honest. The checklist is
single-sourced in `agents/verifier.md` (the runner strips its frontmatter and
inlines the body). Verdict parsing is **fail-closed**: unparseable output counts
as a failure, never a pass.

### Permissions in headless mode

In `claude -p` there is no interactive prompt: tools that aren't pre-approved are
*denied*. `--permission-mode acceptEdits` only covers file edits, so BUILD is
given an explicit `--allowedTools` allowlist (test/build/git commands mirroring
the project template). The verify agent gets a **read-only** allowlist — a gate
with write access is a safety and consistency hole. The loop never uses
`--dangerously-skip-permissions`; plugin hooks fire in headless mode, so
push-from-main and `.env`/secret guards stay live.

## Caps & stuck detection

- `--max-iterations` (default 10), `--max-minutes` (120), `--budget-usd` (10).
  Cost is accumulated from each call's `total_cost_usd`; the budget is a hard
  ceiling checked every iteration.
- `--per-call-timeout` (1200s) wraps every `claude -p` and the verify command in
  `timeout`, so one hung call can't defeat `--max-minutes` (which is only checked
  between phases).
- **Stuck detection:** each gate failure is fingerprinted (gate id). The same
  fingerprint twice triggers one REPLAN pass with the plan model; a third time
  aborts with exit 4. This catches the tail case where the loop spins on one
  failure forever.

## Log format

Each line of `run-<id>.jsonl`:

```json
{"ts":"…","run_id":"…","iter":3,"phase":"build|plan|verify_cmd|secret_scan|verify_agent|replan",
 "model":"sonnet","duration_s":42,"cost_usd":0.11,"input_tokens":8000,"output_tokens":1200,
 "exit_code":0,"verdict":"pass|fail|"}
```

`/usage-report` reads these to attribute cost per run.

## PRD / ADR / TDD wiring

- **PRD in:** `PROMPT.md` must be derived from a `/to-prd` PRD or a GitHub issue,
  with acceptance criteria — that's the contract the verifier checks against.
- **ADR:** the BUILD prompt instructs a `docs/adr/` entry on any architectural
  decision; the verifier flags a missing one (invariant #13).
- **TDD:** the BUILD prompt mandates red-green-refactor per the `tdd` skill; the
  verifier flags a behavior change with no test (invariant #12).

## Recovery

A killed run leaves `tmp/autopilot/` intact and the lock is stale-detected on the
next start. Re-run with `--resume-run`. WIP checkpoints (`autopilot: iteration N
(wip, gate=…)`) let you `git reset` to any clean point. On abort, `FEEDBACK.md`
holds the last failure for a human to read.
