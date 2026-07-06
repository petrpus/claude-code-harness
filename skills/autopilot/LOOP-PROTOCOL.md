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
| `IMPLEMENTATION_PLAN.md` | Checklist of independently verifiable vertical slices + a final `STATUS: in-progress\|done` line. Written by PLAN, ticked by BUILD, sentinel-checked by the gate. |
| `MEMORY.md` | Durable cross-iteration notes. Mechanically pruned to the last 100 lines every iteration — instructions to the model are advisory; the cap is enforced by the runner. |
| `FEEDBACK.md` | Why the last gate failed. The next BUILD iteration must address it first. Cleared when consumed. |
| `status.json` | Live run state, iterations done, accumulated cost, HEAD sha. |
| `run-<id>.jsonl` | Structured per-phase log (see below). |
| `lock` | `PID run_id` — concurrency guard with stale-PID detection. |

## Iteration flow

```
PLAN  (once, if no plan)   opus     acceptEdits, write-only tools
  └─ writes IMPLEMENTATION_PLAN.md as verifiable vertical slices
loop:
  BUILD                    sonnet   acceptEdits + explicit --allowedTools
    └─ one plan item, TDD (red-green-refactor), ADR if architectural,
       run verify, tick box, append MEMORY, set STATUS
  GATE a  sentinel         runner    grep '^STATUS: done'
  GATE b  machine verify   runner    executes the verify command itself
  GATE c  secret scan      runner    greps the diff for keys/tokens
  GATE d  semantic verify  haiku     agents/verifier.md, adversarial, JSON verdict
  ├─ all green → checkpoint commit, exit 0
  └─ any fail  → FEEDBACK.md, reset sentinel, checkpoint WIP, maybe replan
```

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
