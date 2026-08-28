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
loop.sh* is different: it re-reads `tmp/autopilot/` disk state, adopting the
most recent `run-<id>.jsonl`'s run id, iteration count and summed `cost_usd`
(R1), so a killed run picks up its identity and both clocks instead of
silently starting a new run at iteration 0 / cost 0. Continuity comes from
disk, not from a growing window.

### Runner self-reload (R1)

Bash parses `loop.sh`'s (and `plan.sh`'s/`allowlist.sh`'s/`slices.sh`'s) function bodies
once, at process startup. If this repo *is* the autopilot harness's own
source, a slice's job can legitimately be to fix the runner itself — but a
fix a BUILD phase just committed to disk never changes the behaviour of the
process that committed it, only a run a human starts afterwards by hand.
Before each iteration's SELECT, the loop hashes its own sourced files
(`runner_files_hash()`, a `cksum` of their concatenated content) and compares
against the hash taken at startup. On a mismatch it logs a `runner_reload`
line, writes `status.json`, and `exec`s itself with the original argv plus
`--resume-run` — `exec` keeps the PID, so the concurrency lock and the
dirty-tree guard must not re-trip on the process's own prior state.
`RUN_ID`/iteration count/accumulated cost hand across via
`AUTOPILOT_RUN_ID`/`AUTOPILOT_ITER`/`AUTOPILOT_TOTAL_COST`/
`AUTOPILOT_LOCK_OWNED`, which the startup block adopts ahead of the
`--resume-run` disk-based path above. At most one reload happens per
iteration — the new process computes its own baseline hash fresh at startup,
so an unchanged file can never spin.

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
| `slices.json` | Per-slice retry/park ladder state (S4A, `slices.sh`). Runner-owned; never named in any prompt. Missing = nothing has failed yet. |

`HOLDOUT.md` (optional, S2) is deliberately **not** one of these — it lives
outside the worktree entirely (below), because BUILD already reads
`tmp/autopilot/` freely. A `tmp/autopilot/HOLDOUT.md` is a mistake, not a
supported location (`docs/adr/0006-*.md`).

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
  BUILD           sonnet (or --escalate-model on rung 2)   acceptEdits + explicit --allowedTools
    └─ exactly the selected plan item, TDD (red-green-refactor), ADR if
       architectural, run verify, tick box, append MEMORY, set STATUS
  GATE b  machine verify   runner    executes the verify command itself
  GATE c  secret scan      runner    greps the diff for keys/tokens
  GATE d  semantic verify  haiku     agents/verifier.md, adversarial, JSON verdict
  GATE e  holdout          haiku     same call as gate d — HOLDOUT.md's content
                                      inlined into the verifier prompt only, if any
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
is rung 4 of the stuck ladder (below) — the first time it happens this run,
replan once and unpark everything; the second time, abort (rung 5). It needs
`slices.json` to have parked anything first, so on a run where nothing is
ever parked this path is simply never taken.

`agents/verifier.md` gained shortcut **#14 — ticked a slice other than the
one assigned**: the verifier is told which id was selected this iteration
(`verify_prompt()`) and treats a checkbox change to any other slice as a
violation, even if that other slice is genuinely done — its diff wasn't
reviewed this iteration.

### Holdout scenarios (S2, `docs/adr/0006-*.md`)

`--holdout <path>` points at a `HOLDOUT.md` of Given/When/Then acceptance
scenarios the build model must never see — otherwise BUILD and the verifier
read the same charter, and "done" is only as strict as what BUILD itself
chose to test. It defaults to
`${XDG_STATE_HOME:-$HOME/.local/state}/autopilot/<run-id>/HOLDOUT.md`, one
directory per run, **outside the worktree** — the hiding mechanism is
*where the file lives*, not a tool-permission denial (ADR-0006 explains why
denial was rejected: BUILD's own allowlist already grants `Bash(cat:*)` and
an unscopable `Grep`, so closing the hole by permissions would need several
coordinated, silently-failable changes). `tmp/autopilot/HOLDOUT.md` is
explicitly **not** a supported location: BUILD already reads everything else
in `tmp/autopilot/`, so a holdout placed there is not hidden at all.

The runner `cat`s the file itself and inlines its *content* — never the
path — into `verify_prompt()` only. `build_prompt()` and `plan_prompt()`
never mention `--holdout` or `$HOLDOUT_FILE`; BUILD's `--allowedTools`
allowlist is completely unchanged by this slice (no new denial, no `Grep`
narrowing, no `pre-edit.sh` rule). A missing file is not an error — logged
once per run (`no HOLDOUT.md — holdout gate disabled`) and the rest of the
run proceeds without gate (e), same as any 0.4.0-era run that never had one
(contract item 8).

When the file is present, the verifier's prompt gains an appendix asking it
to independently check each scenario against the diff (running it read-only
where it's executable) and to add a `holdout: {"checked": n, "failed":
[ids]}` field to its JSON verdict. Any id in `failed` is shortcut **#15 —
holdout scenario unmet** and is reported in `FEEDBACK.md` by id, so the next
BUILD iteration knows exactly which scenario broke without ever seeing its
text. A holdout failure is fingerprinted `holdout`, distinct from a generic
`verify_agent` failure, so the stuck ladder (and a human skimming the log)
can tell "missed a hidden scenario" apart from "cut some other corner."

### The stuck ladder (S4A, `docs/adr/0005-*.md` decision 6)

Counting changed from **fingerprint repetition** to **per-slice failures**. A
slice that fails three times with three *different* gate fingerprints
(`verify_cmd` once, `holdout` once, `verify_agent` once) is flailing exactly
as much as one failing the same gate three times, so what advances the ladder
is a per-slice `fails` counter, not which fingerprint fired — the fingerprint
still survives for `FEEDBACK.md`, the `plan_dag` bypass, and telling
`holdout` apart from `verify_agent`.

State lives in `tmp/autopilot/slices.json` (`skills/autopilot/slices.sh`),
runner-owned — written and read only by `loop.sh`, never named in any prompt:

```json
{"plan_sig": "<cksum of the ordered unticked slice ids>",
 "slices": {"S2": {"fails": 3, "escalated": false, "parked": true}}}
```

Every iteration reconciles this against the CURRENT plan before selecting: an
id that's ticked, or no longer in the plan at all, retires silently (drops
out — that's what makes "ticking a slice retires its record" durable rather
than something the next reconcile would undo); an id not yet seen starts at
zero. Missing/corrupt file reconciles to "nothing has failed yet" (contract
item 8), never an error — a 0.4.0-era `tmp/autopilot/` still loads.

| rung | trigger | action |
|---|---|---|
| 1 | a slice fails once | retry the same slice on `--build-model` |
| 2 | a slice fails twice | **escalate** (S4B) — the slice's *next* BUILD call runs on `--escalate-model` (default `opus`); `none` disables this rung, which just falls through to another `--build-model` retry, S4A's own pre-S4B behaviour exactly |
| 3 | a slice fails three times | **park** it (`select_next_slice()` skips it for a sibling) |
| 4 | every remaining candidate is parked or blocked by one | **replan** once, unparking everything (`slices_clear()`) |
| 5 | the run fails again after that replan | **abort** (exit 4) |

Rung 4's replan is a **one-time reprieve per stuck episode**, tracked by an
in-process flag (`PARK_REPLAN_DONE`, not persisted — a fresh process, whether
`--resume-run` or an R1 reload, gets its own fresh chance). Once it has
fired, the very next iteration failure — of any kind, not only a repeat of
"every candidate parked" — is rung 5 and aborts unconditionally; making
real progress resets the flag, so a later, unrelated slice getting stuck
still earns its own one replan.

A plan whose lines carry no ids at all still selects one (the first token
after the checkbox, however arbitrary), so the ladder above applies to
virtually every real plan. The exception is a genuinely id-less checkbox
line ("- [ ]" with nothing after it) or the case where `select_next_slice()`
has nothing left to schedule — there, `SELECTED_ID` is empty and the loop
falls back to the pre-S4A fingerprint-repetition ladder (same failure twice →
one replan, third time → abort) verbatim, since there is no id to key
per-slice state on.

`parked_count` (S3A's log field) is real as of S4A: the number of ids
`slices.json` marks parked at that iteration's selection time.

### Escalation (S4B, `docs/adr/0005-*.md` decision 6 update)

Rung 2 of the ladder above: before each BUILD call, the runner reads the
selected slice's `fails` counter from the (already reconciled) `slices.json`
state — NOT the count as of after this iteration's own outcome, the count
carried in from prior iterations. `fails >= 2` and `--escalate-model` isn't
`none` means this one BUILD call runs on the escalate model (default `opus`)
instead of `--build-model`; the very next BUILD call for a *different* slice,
or for this same slice once it ticks and `slices_retire()` drops its record,
is back on `--build-model` — there is no separate "de-escalate" step, only
the absence of a `fails >= 2` record to escalate against.

Escalation is **never applied to the verifier** — `--verify-model` is
untouched regardless of what BUILD ran on; the cheap adversarial tier is the
whole point of gate (d) (`docs/model-policy.md`). It also **does not reset
stuck detection**: an escalated call that still fails counts toward the same
per-slice `fails` counter as any other failure, so a slice opus can't rescue
either still parks on its 3rd failure — escalation only changes which model
gets the *attempt*, not whether that attempt's outcome counts.

**Cost guard.** Escalation counts against `--budget-usd` like any other call
— there is no separate ceiling, since a hard cap here would just move the
failure from "the slice never gets rescued" to "the run aborts mid-rescue"
without fixing anything. It only warns: if a single escalated call's own cost
exceeds 25% of what was left in the budget at the moment it started, the
runner logs a warning so a human skimming the log notices an escalation
that's burning the budget fast.

`escalated` (S3A's log field, `false` until this slice) is `true` only for
the one iteration whose BUILD call actually ran on `--escalate-model` — not
merely "the flag was set" or "this slice is eligible." The per-call `build`
row's own `model` field is the one that shows the escalate model's name.

### Repo-map digest (S5, ADR-0004 item 7)

Every BUILD prompt gets a compact `skills/repo-map/digest.sh` digest appended
under a fixed heading ("Repo map (navigational hint, not ground truth)"):
`stats`, the top-10 `hotspots`, and, for each file path found in the selected
slice's own line, its `deps`/`rdeps` (capped at 8 each) — at most 40 lines
total. `digest.sh` calls `query.sh` only, so staleness/regeneration stays
single-sourced there; any failure (missing `jq`/`awk`, an ungeneratable map)
just omits the section — never an iteration failure. `--no-repo-map` disables
it outright, and the per-iteration log row (see § Log format) records whether
BUILD actually got one that iteration.

This is deliberately BUILD-only. `plan_prompt()` and `verify_prompt()` never
see it: the grep backend's phantom edges (a specifier that only *looks* like
an import, quoted inside a string) are safe for BUILD to discount by opening
the file anyway, but PLAN would freeze one into a hard `after:` edge that
`select_next_slice()` then enforces as real ordering — narrowing the Plan DAG
with an invented dependency, the opposite of what parking (S4A) needs a wide
DAG for. The verifier judges the diff, not the map.

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
as a failure, never a pass — see the next section for what "counts as a
failure" now means in more detail.

### A refusal is not a verdict (R2)

`parse_verdict()` splits the verifier's raw output three ways, not two:
`pass` (a parseable JSON object with `.pass == true`), `fail` (parseable, `.pass
== false`), and `no_verdict` (no parseable JSON object at all, or one missing a
boolean `.pass` key). All three still block the tick — this changes
*attribution*, not strictness.

Before R2, `parse_verdict()` folded `no_verdict` into `fail`, which made a
verifier that *declined to judge* (refusal prose, a clarifying question it had
no way to get an answer to, output truncated by the per-call timeout)
indistinguishable from one that *found real shortcuts*. The loop then wrote
`verifier found shortcuts: <300 chars of refusal prose>` into `FEEDBACK.md` and
sent BUILD chasing violations that were never made — a real occurrence during
this harness's own 0.5.0 build, when the verifier's own charter file
(`agents/verifier.md`) showed up in the diff it was reviewing and it asked a
clarifying question instead of a verdict.

`no_verdict` is a **gate malfunction, not a slice defect**. On a `no_verdict`,
the runner retries gate (d) once, against the exact same unchanged diff,
before drawing any conclusion about BUILD's work — one retry only, so a
verifier that never recovers doesn't spin. If the retry also yields no
verdict, the failure is fingerprinted `no_verdict` (distinct from both
`verify_agent` and `holdout`) and `FEEDBACK.md` gets a sentence naming the
malfunction ("the semantic gate returned no verdict twice; the diff was not
judged") rather than the raw refusal text — the raw text still only ever goes
to `verifier-raw.log`, never presented as a finding. `no_verdict` is still
counted on the stuck ladder like any other fingerprint, so a permanently
broken gate still aborts the run instead of looping forever.

This adds **no new gate** — gate (d) is still one gate; `no_verdict` is a way
it can fail to render a verdict at all, the same way `plan_dag` is a way the
plan itself can fail to be walkable. Both bypass business-as-usual handling
for a structural reason, but only `plan_dag` bypasses the stuck ladder itself
(§ Slice selection above) — `no_verdict` still goes through it, because unlike
a broken Plan DAG, a flaky verifier gate might legitimately produce a real
verdict on the very next iteration's fresh diff.

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
- **Stuck detection (S4A):** on an annotated plan, driven by a per-slice
  `fails` counter (retry → park at 3 → replan once all candidates are parked
  or blocked → abort on the next failure) — see § The stuck ladder above. On
  a plan with no slice id to key that off of, the pre-S4A rule still applies
  verbatim: the same gate fingerprint twice triggers one REPLAN pass with the
  plan model, a third time aborts with exit 4. Either way this catches the
  tail case where the loop spins on one failure forever.

## Log format

Two shapes share `run-<id>.jsonl`: one row per `claude -p` **call**, and one
summary row per **iteration** (S3A). Both carry `ts`/`run_id`/`iter`/`phase`,
which is enough to tell them apart (`phase:"iteration"` vs. anything else).

Per-call row:

```json
{"ts":"…","run_id":"…","iter":3,"phase":"build|plan|verify_cmd|secret_scan|verify_agent|replan|runner_reload",
 "model":"sonnet","duration_s":42,"cost_usd":0.11,"input_tokens":8000,"output_tokens":1200,
 "exit_code":0,"verdict":"pass|fail|no_verdict|","holdout_failed":0,
 "turns":6,"cache_read_input_tokens":4000,"cache_creation_input_tokens":500,"violations":[]}
```

`runner_reload` (R1) is logged once, immediately before the `exec` that
re-loads a changed `loop.sh`/`plan.sh`/`allowlist.sh`/`slices.sh` — it costs nothing and
carries no tokens, but marks exactly where a run's identity carried across a
process replacement, which matters when reading `iter` back out as a
monotonic sequence.

`holdout_failed` (S2) is the count of ids in that call's `holdout.failed[]` —
0 on every phase except `verify_agent`, and 0 there too whenever no holdout
file was given or every scenario held.

`turns`/`cache_read_input_tokens`/`cache_creation_input_tokens` (S3A) come
straight out of `claude -p --output-format json`'s `.num_turns`/`.usage` —
still plain `json`, never `stream-json`; the budget cap's only cost source
stays `total_cost_usd`. `violations` (S3A) is only ever non-empty on a
`verify_agent` row: the `shortcut` numbers the verdict's `violations[]`
named, e.g. `[2,7]`.

Per-iteration row (S3A) — written once per iteration, after every gate has
run, in addition to (not instead of) the per-call rows above:

```json
{"ts":"…","run_id":"…","iter":3,"phase":"iteration","model":"-",
 "verdict":"done|unmeasured|progressed|fail","slice_id":"S3A","ticked_delta":1,
 "gate_failed":"verify_cmd|secret|verify_agent|holdout|plan_dag|no_verdict|none",
 "wall_s":180,"cost_usd":0.42,"files_changed":4,"verify_s":12,"dag_width":2,
 "parked_count":0,"escalated":false,"repo_map":true}
```

`slice_id` is the id `select_next_slice()` assigned that iteration (S1B), or
`""` on an unannotated plan. `gate_failed` mirrors the fingerprint the stuck
ladder tracked for that iteration, or `"none"` when every gate passed —
`plan_dag`/`plan_parked` iterations bypass the ladder entirely (they `continue`
before BUILD ever runs) and so never reach this row. `dag_width` is how many
unchecked, unblocked, unparked slices `select_next_slice()` could have picked
from, not just the one it did — a chain reads `1` every iteration, a wide plan
reads higher. `parked_count` (real as of S4A) is the number of ids
`slices.json` marked parked at that iteration's selection time. `escalated`
(real as of S4B) is `true` only for the one iteration whose BUILD call
actually ran on `--escalate-model` (§ Escalation above) — `false` on every
other iteration, including one where the slice was *eligible* to escalate
but `--escalate-model none` disabled it. `repo_map` (S5) is whether BUILD's prompt actually carried a
repo-map digest that iteration — `false` both under `--no-repo-map` and when
the digest generator produced nothing (missing `jq`/`awk`, an ungeneratable
map), so it answers "did BUILD see one," not "was the flag on."

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
next start. Re-run with `--resume-run`, which now (R1) adopts the killed run's id,
iteration count and accumulated cost from its `run-<id>.jsonl` instead of starting
a new run at iteration 0 / cost 0 — a missing log behaves like a fresh run
(contract item 8). WIP checkpoints (`autopilot: iteration N (wip, gate=…)`) let
you `git reset` to any clean point. On abort, `FEEDBACK.md` holds the last
failure for a human to read.

A *live* run whose own BUILD phase fixes `loop.sh`/`plan.sh`/`allowlist.sh`/`slices.sh`
does not need a manual restart at all — see Runner self-reload (R1) above; it
re-execs itself under the same run id automatically.
