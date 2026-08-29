# The Plan DAG lives inside IMPLEMENTATION_PLAN.md, and the stuck ladder gets a fourth rung

Building on the autopilot loop described in `skills/autopilot/LOOP-PROTOCOL.md`:
before this slice, BUILD always took "the first unchecked box" — the plan was a
flat, ordered list, and dependency between slices was expressed only by
writing them in the right order and hoping BUILD never got ahead of itself.
That degrades badly the moment a plan is wider than a chain: two independent
slices that could both start immediately still had to run in file order, and
a slice that failed repeatedly blocked everything after it even when a
sibling slice had nothing to do with the failure.

## Decisions

1. **Annotations live inside the checklist, not a second file.** A slice line
   may carry `(after: <id>, <id>)`. This is one plan artefact — greppable,
   diffable, survives a fresh-context iteration without the runner having to
   correlate two files. A separate `plan.json` alongside the checklist was
   considered and rejected: it invites drift (the human or the model edits
   the checklist and forgets the JSON, or vice versa), and every consumer of
   plan state would need to read both.
2. **Ids are plan-local, not issue numbers.** The id is just the first
   whitespace-delimited token after the checkbox (`S1`, `M2`, a bare word).
   A run is commonly derived from one GitHub issue or PRD, and a plan-local id
   space keeps the plan self-contained — `select_next_slice()` never needs to
   resolve an id against `gh issue view`, and a plan copied between runs
   doesn't collide on issue numbers that mean nothing to it.
3. **A plan with no annotations parses to "everything unblocked."** A line
   without an `after:` clause has no blockers, so `select_next_slice()`
   degrades exactly to "first unchecked box" — 0.4.0 behaviour, unchanged
   (contract item 8). This was the deciding reason to put the DAG in the
   checklist's own syntax rather than requiring every plan to declare one:
   the common case (a short linear plan) needs zero new syntax to keep
   working.
4. **A broken DAG is a plan bug, not a build bug.** An `after:` clause naming
   an id that appears nowhere in the plan, or a cycle among `after:` edges,
   fingerprints as `plan_dag` and goes straight to replan — bypassing the
   stuck ladder entirely (decision 6). Retrying the same BUILD call, or
   escalating it to a stronger model, cannot fix a graph the PLAN phase wrote
   wrong; only rewriting the plan can.
5. **Parallel execution is out of scope.** `select_next_slice()` returns
   exactly one id — the runner still executes one `claude -p` BUILD call per
   iteration. A wider DAG makes parallel execution possible later (multiple
   worktrees, one per ready slice — tracked as M1), but this slice does not
   attempt it; the payoff here is scheduling freedom, not concurrency.
6. **The stuck ladder gains a rung, driven by per-slice state.** Failing the
   *same slice* now escalates in four steps — retry (same model) → escalate
   (a stronger model, S4B) → park (skip it, try a sibling) → replan (when
   nothing unparked remains, unparking everything) → abort if a post-replan
   attempt still fails. The per-slice `fails` counter that drives this lands
   in S4A's `tmp/autopilot/slices.json`; this slice only defines where
   `select_next_slice()` plugs into it (a `parked-ids` argument, default
   empty) and what the runner does with the two failure shapes it can already
   produce: a broken DAG (rung-bypassing replan, decision 4) and "every
   remaining candidate is parked or blocked by a parked one" (also a replan,
   because parking has run out of room to make progress).
7. **Parking is worthless on a chain, so plan width is a quality criterion.**
   Parking a slice only buys the runner anything if some *other* unblocked
   slice exists to run instead. On a plan shaped as one long chain, parking
   the one slice at the front makes every slice behind it unreachable too —
   parking degenerates into an expensive way to reach the same replan a plain
   retry-then-abort would have reached anyway, just slower and after wasting
   a park attempt. The PLAN prompt (`loop.sh`, `PLAN.template.md`) therefore
   asks the plan model to prefer several slices being simultaneously ready
   over a long dependency chain, and to justify every `after:` edge rather
   than add one merely to preserve a reading order: an edge should exist only
   when the later slice genuinely cannot be verified without the earlier one
   having landed.

## Considered and rejected

**A second `plan.json` next to the checklist.** Rejected per decision 1 — two
sources of truth for the same information, one of which a human is expected
to edit by hand (the checklist), invites drift that a single-file design
doesn't have to defend against.

**Issue numbers as ids.** Rejected per decision 2 — couples plan-local
scheduling to the GitHub issue tracker's numbering, which is meaningless
inside a single run and would require a network call (`gh issue view`) just
to validate the DAG.

**Treating a broken DAG as an ordinary gate failure.** Rejected per decision
4 — folding `plan_dag` into the existing verify/secret/semantic gate
fingerprints would let a plan bug consume two retries and an escalation
before ever reaching a replan, wasting a build model's time on a call that
cannot possibly fix the actual problem.

## Consequences

`select_next_slice()` (`skills/autopilot/plan.sh`) is pure parsing with no
`claude` dependency, so it's unit-tested directly (`scripts/verify.sh`) as
well as exercised end-to-end through `loop.sh` (`scripts/test-autopilot-loop.sh`).
The two test surfaces cover different things: the unit tests prove the parser
and the DAG algorithm are correct in isolation (diamond graphs, cycles,
malformed lines); the loop tests prove the wiring — that the selected id and
its line actually reach `build_prompt()` in dependency order, and that a
`plan_dag` failure really does replan immediately rather than waiting for the
stuck ladder's normal two-strikes rule.

A plan written without ids or `after:` clauses pays no tax: `select_next_slice()`
walks it exactly as "first unchecked box," so every 0.4.0-era
`tmp/autopilot/` directory keeps working unmodified.

## Update (S4A) — the per-slice ladder state lands

Decision 6 above sketched the shape; this slice implements it. Notes worth
recording that weren't decidable until the code existed:

- **State is a plain jq-manipulated JSON blob, not a bash associative array**
  (`skills/autopilot/slices.sh`), unlike `plan.sh`'s own hand-rolled parser.
  The state's shape is trivial (an object keyed by id, three scalar fields
  each) and every operation on it — reconcile, record a failure, park,
  retire, read a count back out — is a one-line `jq` filter; hand-parsing it
  in bash would only add a second, slower implementation of what `jq`
  already does correctly. `plan.sh` earns its own parser because Markdown
  checkbox syntax isn't JSON; `slices.sh`'s file already is.
- **Reconciliation keys on UNTICKED ids only**, not every id in the plan.
  Passing every id (ticked or not) into the reconcile step would zero-init a
  just-ticked slice's record right back into existence on the very next
  iteration, undoing "ticking a slice retires its record" one iteration
  later. `loop.sh` filters `PLAN_IDS[]` by `PLAN_ROW_TICKED[]` before calling
  `slices_reconcile()`, so a ticked id simply stops appearing in the set the
  state is reconciled against and drops out for good.
- **Rung 4's "one replan" is tracked by an in-process flag
  (`PARK_REPLAN_DONE`), not written to `slices.json`.** It answers "has this
  *process* already spent its one park-exhaustion reprieve," which is a
  question about the run's control flow, not about any slice's retry count —
  putting it in the state file would conflate the two and complicate
  reconciliation for no benefit. It is deliberately NOT threaded through the
  R1 reload / `--resume-run` env handoff the way `RUN_ID`/`ITER`/`TOTAL_COST`
  are: a fresh process (whether a manual `--resume-run` or an R1 self-reload)
  earns its own fresh chance at rung 4, on the theory that a human or a
  runner-code fix intervening is itself a reason to give the stuck episode
  one more look rather than treat it as already spent.
- **A plan whose selected line carries no real id** (the degenerate case
  `select_next_slice()` never selects anything for) falls back to the
  pre-S4A fingerprint-repetition ladder verbatim, rather than trying to key
  per-slice state on an empty string. In practice this is rare — the id is
  just the first token after the checkbox, so almost any real checklist line
  produces *something* — but it is the honest fallback for the one case
  where no id exists to track.

## Update (S4B) — rung 2, escalation

Decision 6 sketched a four-step ladder (retry → escalate → park → replan →
abort — five words, four transitions); this slice fills in the "escalate"
step S4A deliberately left as "just retry again."

- **The escalation decision reads `slices.json`'s `fails` counter BEFORE this
  iteration's own attempt**, the same reconciled state `select_next_slice()`
  and the park check already read this iteration. `fails >= 2` means the
  slice has already failed twice; this one BUILD call runs on
  `--escalate-model` instead of `--build-model`. There is no separate
  "de-escalate" transition — `slices_retire()` (on a tick) or
  `slices_clear()` (on a replan) already remove the record that made the
  slice eligible, so the very next BUILD call for it, or for any other
  slice, is back on `--build-model` simply because there is nothing left to
  read `fails >= 2` from.
- **`--escalate-model none` is a first-class value, not an error.** It skips
  the escalation check entirely, which degrades rung 2 to exactly what S4A
  shipped — "just retry again" — verbatim. This was the deciding reason not
  to make escalation mandatory: a run against a project with no meaningfully
  stronger model available (or one where the cost of an escalation is judged
  not worth it) should be able to opt out without losing the rest of the
  ladder.
- **The cost guard warns; it does not cap.** A hard per-escalation ceiling
  was considered and rejected — it would just convert "the slice never gets
  rescued" into "the run aborts mid-rescue," which is worse: the whole point
  of rung 2 is to spend more to fix what rung 1 couldn't. Escalation is
  already bounded by the run's own `--budget-usd`, the same ceiling every
  other call answers to. The 25%-of-remaining-budget threshold is a
  judgement call, not a derived number: cheap enough to fire on a run that's
  actually being eaten by escalations, loose enough not to fire on a single
  ordinary-priced call late in a small budget.
- **Escalation never touches the verifier.** `--verify-model` is read once at
  startup and never reassigned; only the BUILD call's model argument is
  computed per iteration. This follows directly from `docs/model-policy.md`'s
  rule of thumb — the adversarial gate's value comes from being cheap and run
  often, not from being smart, and escalating it would blur exactly the
  build/verify asymmetry the tiering exists to preserve.
- **Escalation does not reset stuck detection.** An escalated call that still
  fails increments the same per-slice `fails` counter as any other failure —
  there is no separate "gave it the strong model and it still couldn't"
  state. A slice opus can't rescue still parks on its 3rd failure exactly
  like one sonnet couldn't rescue; escalation changes which model gets an
  attempt, never whether that attempt's outcome counts toward the ladder.
