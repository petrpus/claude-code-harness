# PRD 0002 — Harness upgrade to 0.5.0 (plan DAG, holdout verify, run metrics, CI) + 0.6.x parallelism

Status: **grilled — issues cut** (#31–#45; map #45) · Date: 2026-08-28 · Analysis: this PRD's § Background (no separate research doc; the July analysis in [docs/research/2026-07-harness-upgrade.md](../research/2026-07-harness-upgrade.md) still applies)
ADRs: [0001](../adr/0001-repo-map-as-file-not-mcp.md) · [0002](../adr/0002-opt-in-stop-gate-exception.md) · [0004](../adr/0004-graphify-as-optional-repo-map-backend.md) · **new: [0006](../adr/0006-holdout-scenarios-hidden-by-location.md) (holdout — written in grill), 0005 (plan DAG — to be written by S1)**
Glossary: [CONTEXT.md](../../CONTEXT.md) — this PRD uses its terms. The grill already added **Gate** (genus), **Iteration gate**, **Plan-dependency failure**, **Holdout**, **Plan DAG**, **Escalation** and **Parked slice**, and corrected the premature "gate resolved" entry in § Flagged ambiguities. No slice needs to add vocabulary; slices must *use* it.

## Background

The harness sits at the "Ralph loop + harness engineering" tier of the 2026 agentic-coding landscape: `autopilot` is a fresh-context loop with runner-enforced gates; hooks, settings deny, model policy and `verify.sh` are the harness layer. Three ideas from the wider field are not yet reflected and are cheap to adopt without changing the single-agent, file-not-MCP, no-`--dangerously-skip-permissions` stance:

1. **Pipeline as a graph, not a list** (StrongDM Attractor). `to-issues` already emits blocking edges between issues; `IMPLEMENTATION_PLAN.md` flattens them and the runner can only walk top-down. A plan DAG is the prerequisite for any later parallelism.
2. **Holdout scenarios** (StrongDM Software Factory). BUILD and the verifier currently read the same charter. Acceptance scenarios the build model never sees make "done" harder to fake than the 11-shortcuts checklist alone.
3. **Measure before optimising.** `run-<id>.jsonl` records cost and tokens but not the metrics the July roadmap (U4) asked for. Repo-map's claimed token savings remain unverified on our own runs.

Plus one debt item: the harness demands CI from consumer projects and has none (README, § Versioning).

## Goal

Ship 0.5.0 with a dependency-aware autopilot plan, an independent holdout gate, run metrics that let us evaluate repo-map and model tiering on real data, adaptive escalation on stuck runs, repo-map wired into the loop (closing ADR-0004 item 7), and CI on the harness itself. Capture the 0.6.x parallelism / async-HITL / multi-backend work on the tracker as `needs-grill`.

## Execution model (decided in the grill)

0.5.0 is built by **`loop.sh` autopilot on a single branch**, not by a cloud session
doing one PR per issue. This is a deliberate change from PRD 0001, and it is the only
model `loop.sh` actually supports: the runner commits to the current branch
(`git add -A && git commit`, one checkpoint per iteration) and has **no** `gh`, no
branch creation and no PR machinery — `BUILD_ALLOWED_TOOLS` does not grant `Bash(gh:*)`
and must not, since under `acceptEdits` that would also grant `gh pr merge`,
`gh issue close` and `gh api -X PATCH`.

- `tmp/autopilot/PROMPT.md` is this PRD; the PLAN phase derives its own DAG from it.
- GitHub issues from `/to-issues` are the **human-facing record and the charter source**,
  not PR units. They are closed by hand when the branch merges.
- The human opens one PR from the run branch at the end, confirms CI, merges, tags.

**The runner must be the installed plugin copy, never the repo copy.** Bash reads a
script by byte offset as it executes, and slices S1–S5 rewrite `skills/autopilot/loop.sh`.
Running `./skills/autopilot/loop.sh` from the worktree would have BUILD edit the file the
interpreter is mid-way through reading. Launch
`~/.claude/plugins/cache/claude-code-harness/claude-code-harness/0.4.0/skills/autopilot/loop.sh`
(a distinct inode from the worktree copy) so the runner executing the run and the code
under change are never the same file. `scripts/test-autopilot-loop.sh` keeps exercising
the worktree copy — that is where the new behaviour must be proven.

## Autonomy contract (binding for the run)

Amended from PRD 0001 by the grill:

1. One Slice = one plan item in `IMPLEMENTATION_PLAN.md` = one checkpoint commit. ~~one issue = one branch = one PR~~ — see Execution model.
2. A slice may start only when all its `after:` blockers are ticked (S1).
3. Gate before every checkpoint commit, not merely before the PR: `scripts/verify.sh` must pass — the runner re-runs it itself every iteration (`loop.sh` GATE b). Slices that touch `loop.sh` must also extend `scripts/test-autopilot-loop.sh` so the new behaviour is exercised against the stub `claude` — a runner change with no loop test is a verifier violation (invariant #12).
4. The agent never opens or merges a PR — it has no `gh`. The run ends at a cap or at `STATUS: done`; the human then opens the PR, confirms the S0 workflow is green, merges and tags. S7 (version bump + CHANGELOG) is the run's last plan item, not a separate HITL step; tagging stays on the merge commit on `main` per CLAUDE.md.
5. Every slice updates the docs it touches, including `docs/guide.html` / `docs/index.html`, when it changes user-facing behaviour. Keep both HTML files self-contained (no external resources).
6. Commit messages: English, conventional commits.
7. Never touch: `plugin.json` version and `CHANGELOG.md` top entry (S7 only), `tmp/` contents, anything in the Design lane (ADR-0003), vendored skills (no upstream sync in this PRD).
8. **Backward compatibility of run state.** A `tmp/autopilot/` directory written by 0.4.0 must still load: plans without dependency annotations behave exactly as today; a missing `HOLDOUT.md` disables the holdout gate with a one-line notice, never an error.

## Slice map

| Slice | Title | Blocked by | Label | Target |
|---|---|---|---|---|
| S0 | CI for the harness: GitHub Actions running `scripts/verify.sh` on PR + push to `main` | — | ready-for-agent | 0.5.0 |
| S1 | Plan DAG — blocking edges in `IMPLEMENTATION_PLAN.md`, runner picks only unblocked slices (ADR-0005) | S0 | ready-for-agent | 0.5.0 |
| S2 | Holdout scenarios — `HOLDOUT.md` read by the verifier only, hidden from BUILD (ADR-0006) | S0 | ready-for-agent | 0.5.0 |
| S3 | Run metrics (U4) — per-iteration/per-slice metrics in the run log + `/usage-report` reads them | S1 | ready-for-agent | 0.5.0 |
| S4 | Stuck ladder — escalate → park → replan → abort, per-slice state (ADR-0005) | S1, S3 | ready-for-agent | 0.5.0 |
| S5 | Repo-map digest into autopilot (ADR-0004 item 7; former M3 wiring) | S1 | ready-for-agent | 0.5.0 |
| S6 | Docs refresh for 0.5.0: guide.html, index.html, README, architecture.md, LOOP-PROTOCOL.md | S1–S5 | ready-for-agent | 0.5.0 |
| S7 | Release 0.5.0 — bump, CHANGELOG, tag (**HITL**) | S6 | needs-grill* | 0.5.0 |
| M1 | Parallel slices via git worktrees (per-worktree lock, merge gate) | S7 | needs-grill | 0.6.x |
| M2 | Async HITL node — `ASK.md` + `gh issue comment`, pause/resume | S7 | needs-grill | 0.6.x |
| M3 | `drift-check` skill — entropy management for CLAUDE.md / CONTEXT.md / ADRs | S0 | needs-grill | 0.6.x |
| M4 | Backend-agnostic runner (`run_agent()` adapter; `codex exec`) + `AGENTS.md` shim | S7 | needs-grill | 0.6.x |
| M5 | `project-infra` for Python (uv/pytest/ruff) and Go stacks; devcontainer installs `jq` | S0 | needs-grill | 0.6.x |

\* S7 carries `needs-grill` semantics operationally (agent stops at PR).

Dependency graph (for the tracker; blocking edges only):

```
S0 → S1 → S3 → S4 ↘
     S1 → S5 ────→ S6 → S7 → M1, M2, M4
S0 → S2 ─────────↗
S0 → M3, M5
```

(S5 unblocked from S3 in the grill: the digest itself needs only S1's selected-slice
line; the `repo_map` flag it writes into the run log is one field S3 merely *reads*
once it lands. Wider DAG — S1 fans into S3 and S5 in parallel — which also gives the
park rung a real chance to fire on this very run.)

## Slice specifications

### S0 — CI for the harness

The harness has no pipeline of its own. `scripts/verify.sh` is offline, deterministic, and runs in seconds, so CI is a thin wrapper.

- New `.github/workflows/verify.yml`: triggers on `pull_request` and `push` to `main`; `ubuntu-latest`; installs `jq` (apt) — the hook matrix depends on it and must not silently fail open in CI; runs `bash scripts/verify.sh`.
- Do **not** reuse `skills/project-infra/ci-workflow.template.yml` verbatim — that template targets npm consumer projects. Either parameterise the template so it can emit a bash-only variant (preferred: adds value to `/project-infra ci`), or write a dedicated workflow and note in the template's header why the harness's own workflow differs.
- `scripts/check-consistency.sh`: add an invariant that the workflow file exists and invokes `scripts/verify.sh`.
- README § Versioning: replace "the harness repo itself has no pipeline yet" with the new state. Branch protection on `main` requiring the check is a human step — list it in the PR description, do not attempt via `gh api`.
- DoD: `bash scripts/verify.sh` green locally and the check-consistency invariant passes. The workflow itself cannot be confirmed during the run — there is no PR and the runner has no `gh` — so **confirming the green Actions run is the human's step at PR time**, listed in the PR description alongside enabling branch protection.

### S1 — Plan DAG (ADR-0005)

Today the PLAN prompt asks for an ordered list and BUILD takes the first unchecked box. Introduce optional dependency annotations so the runner can select any slice whose blockers are ticked.

- **Format.** A slice line may carry an `after:` annotation: `- [ ] S3 — Write the query CLI (after: S1, S2)`. Slice ids are the first token after the checkbox (`S1`, `M2`, …). Lines without an id or without `after:` are unblocked. This keeps 0.4.0 plans valid unchanged (contract item 8).
- **Runner.** New helper `select_next_slice()` in a sourced `plan.sh` alongside `allowlist.sh` (own file, so it is unit-testable without a run): parse ids, ticked state and `after:` lists; return the first **unchecked, unparked** slice whose blockers are all ticked. If no such slice exists but unchecked slices remain, distinguish two cases:
  - blockers form a cycle, or an `after:` names an unknown id → **plan-dependency failure**, fingerprint `plan_dag`, feed FEEDBACK.md, straight to replan. This bypasses the stuck ladder entirely: a cycle is a plan bug, not a build bug, and retrying or escalating cannot fix it.
  - every remaining candidate is parked or blocked by a parked slice → **replan** (see the ladder in S4), which also unparks everything.
- **Parking blocks descendants.** A parked slice's dependents stay unreachable, so parking only buys anything on a *wide* graph; on a chain it is an expensive abort. This is the hard reason the PLAN prompt must prefer wide graphs over chains, and ADR-0005 records it.
- **BUILD prompt.** Change "Do exactly ONE unchecked plan item" to "Do exactly the plan item `<id>` selected by the runner (see below); do not start any other item". The runner injects the selected id and line into the prompt. The verifier's shortcut #6 already covers "ticked without evidence"; add to `agents/verifier.md` shortcut #14: *ticked a slice other than the one assigned*. Note the file's headings say "The 11 shortcuts" and "Plus two harness invariants" — adding #14 (S1) and #15 (S2) means restructuring those headings, not just appending, and the count in `SKILL.md` / `architecture.md` must follow.
- **PLAN prompt.** Ask the plan model to emit ids and `after:` edges, and to keep every slice provable by the verify command on its own. On width, instruct it to *justify* each edge rather than merely prefer few: "A slice whose blocker chain is deep cannot be parked when it fails — depth is a cost. State an `after:` edge only when the later slice genuinely cannot be verified without the earlier one." Sync `PLAN.template.md`.
- **Tests.** Extend `scripts/test-autopilot-loop.sh`: (a) linear plan without annotations behaves as 0.4.0; (b) diamond plan (S1 → S2, S3 → S4) selects S2 or S3 only after S1 is ticked and S4 only after both; (c) cycle → plan_dag failure → replan **without** passing through escalate/park; (d) unknown blocker id → same; (e) a parked slice is skipped by `select_next_slice()` and its dependents stay unreachable. Unit tests for the parser with malformed lines.
- **ADR-0005.** Record: annotation syntax lives inside the checklist (no second file — one plan artefact, greppable, survives fresh context); ids are plan-local, not issue numbers (a run may be one issue); parallel execution is explicitly out of scope here and deferred to M1; **and the four-rung stuck ladder decided in the grill (escalate → park → replan → abort), including why parking is worthless on a chain and therefore why plan width is a quality criterion, not a preference.**
- CONTEXT.md: add **Plan DAG** (the dependency structure of an autopilot plan, expressed as `after:` edges) — relate it to **Blocking edge** (same concept at issue level).
- DoD: verify.sh green; loop test cases (a)–(d) pass; LOOP-PROTOCOL.md § Iteration flow updated; a 0.4.0-era `tmp/autopilot/` fixture in the test still completes.

### S2 — Holdout scenarios (ADR-0006 — **decided in grill, ADR already written**)

- **Artefact.** `HOLDOUT.md` (optional): concrete scenarios in Given/When/Then form,
  written by the human (or derived from `/to-prd` output). It lives **outside the
  worktree** — default `${XDG_STATE_HOME:-$HOME/.local/state}/autopilot/<run-id>/HOLDOUT.md`,
  overridable with a new `--holdout <path>` flag. Ship `HOLDOUT.template.md` next to
  `PROMPT.template.md` with a header explaining that the file must not be copied into
  the repo.
- **Hiding it.** Nothing to deny: the runner `cat`s the file itself and inlines its
  *content* into the verifier prompt. BUILD's allowlist is **unchanged** — no
  `Bash(cat:*)` narrowing, no `Grep` restriction, no `--disallowedTools`. The path
  never appears in `build_prompt()` or `plan_prompt()`. `tmp/autopilot/HOLDOUT.md` is
  explicitly not a supported location; `pre-edit.sh` needs no new rule. See ADR-0006
  for the rejected alternatives (tool denial, mv-around-BUILD, advisory-only) and for
  the recorded residual hole (BUILD could guess the path).
- **Verifier checklist hardening** (adopted in the 2026-08-28 upstream survey): two new shortcuts in `agents/verifier.md` alongside S1's #14 and this slice's #15 — **#16 tautological test** (from Pocock `tdd`: the assertion recomputes the expected value the way the code does — `expect(add(a,b)).toBe(a+b)`, a hand-derived snapshot, a constant asserted against itself — so it passes by construction; #2 covers hardcoded *code*, this covers hollow *tests*, and BUILD writes tests every iteration) and **#17 off-spec done** (from loopkit `adversarial-verify`: code works, tests pass, but it solves a goal that is not the one the charter asks; #9 covers doing *less*, this covers doing *something else*). Rejected for now: "invented API" — the verify command's typecheck/tests catch hallucinated symbols earlier and cheaper than an LLM pass.
- **Verifier.** `verify_prompt()` appends the inlined scenarios when the file exists:
  "Independently check each scenario below against the diff and, where a scenario is
  executable, run it read-only. Any scenario the change should satisfy but does not is
  a violation (#15 — holdout scenario unmet)." Verdict schema gains
  `holdout: {checked: n, failed: [ids]}`. The verifier's read-only allowlist is
  unchanged — it receives text, not a file to open.
- **Runner.** Missing file → `log_err "no HOLDOUT.md — holdout gate disabled"` once per
  run; present → the `verify_agent` log line gains a `holdout_failed` count. A holdout
  failure is fingerprinted `holdout` (distinct from `verify_agent`) so stuck detection
  can tell them apart.
- **Tests.** Loop test: stub verifier returns a holdout failure → FEEDBACK.md mentions
  the scenario id; the BUILD stub asserts the holdout path and its content appear
  nowhere in the prompt it was handed. Test with the file absent → one notice, run
  proceeds, no error (contract item 8).
- CONTEXT.md: **Holdout** added during the grill.
- DoD: verify.sh green; loop tests pass; `skills/autopilot/SKILL.md` § Gates lists
  holdout as gate (e); LOOP-PROTOCOL.md documents `--holdout` and the out-of-worktree
  rule.

### S3 — Run metrics (U4)

Add the metrics the July roadmap asked for, so S4/S5 and the repo-map claims can be evaluated on data.

- Per `claude -p` call: `num_turns` from the JSON result (already available) → new field `turns`; plus the two cache-token fields above. Per iteration: `slice_id` (from S1), `ticked_delta`, `gate_failed` (`verify_cmd|secret|verify_agent|holdout|plan_dag|none`), `wall_s`, `cost_usd` (sum of phases), `files_changed` (`git diff --stat` count), `verify_s` (wall time of the verify command).
- ~~`tool_calls_before_first_edit` behind `--metrics full` / `--output-format stream-json`~~ — **cut in the grill, not deferred to a later slice.** `run_claude` is the single chokepoint every LLM call in the loop passes through, and the budget cap hangs off the `total_cost_usd` it extracts (`over_budget()`, `loop.sh:199`). A stream parser that fails silently returns cost 0, `TOTAL_COST` stops growing and `--budget-usd` quietly stops capping — a failure mode strictly worse than the missing metric, and one the proposed fault-injection test (metric → `null`) would not have caught. It would also need a second NDJSON stub, since the existing one emits a single object (`test-autopilot-loop.sh:44`).
- **Instead, measure the repo-map claim directly** — same `--output-format json`, same code path, two more `jq` reads in `logline()`: `cache_read_input_tokens` and `cache_creation_input_tokens` from `.usage`. `input_tokens + cache_read + cache_creation` on BUILD calls, split on S5's `repo_map` flag, answers "does repo-map save context?" without a proxy. `tool_calls_before_first_edit` counts *calls*, not tokens, and can point the wrong way — ten cheap greps outweigh one 3000-line read in call count but not in context. Revisit only if the cache fields turn out not to separate repo-map on from off.
- Per iteration, additionally (decided in the grill, feeds the S5 width question): `dag_width` — how many unchecked slices were unblocked and unparked when `select_next_slice()` chose — and `parked_count`.
- Per run: `status.json` gains `iterations`, `gate_fail_rate`, `cost_per_ticked_slice`, `replans`, `mean_dag_width`, `parked_total`, `escalations`.
- **Verdict-distribution logging** (adopted from loopkit's `evaluator-calibration` during the 2026-08-28 upstream survey): the `verify_agent` log line records the shortcut numbers of any violations (`violations: [2, 7]`), and `/usage-report` can render the per-shortcut histogram across runs. A criterion whose fail rate collapses without a spec change is verifier drift, not quality improvement — this is the cheap detector for it.
- `/usage-report`: read the new fields; add a "per run" table (slices ticked, cost per slice, gate-fail rate, mean turns) and, when both are present across runs in `tmp/autopilot/`, a repo-map on/off comparison keyed on the `repo_map` flag S5 will write. Until S5 lands the column is simply empty.
- DoD: verify.sh green; loop test asserts the new fields exist with correct types on a three-iteration stub run; `docs/model-policy.md` gets a one-paragraph "how we measure" pointer.

### S4 — The stuck ladder: escalate → park → replan → abort

Today's ladder is two rungs and keyed on a **global** fingerprint (`LAST_FP` / `REPEAT`,
`loop.sh:436–443`): second identical failure → replan the whole plan, third → abort the
run. With a DAG (S1) there is a cheaper move available between those, and a cheaper one
still before them. Decided in the grill:

| rung | trigger | action |
|---|---|---|
| 1 | slice fails once | FEEDBACK.md, retry the same slice on `--build-model` (as today) |
| 2 | slice fails twice | **escalate** — next BUILD for *that slice* runs on `--escalate-model` |
| 3 | slice fails three times | **park** it; `select_next_slice()` picks another unblocked slice |
| 4 | every remaining slice parked or blocked by a parked one | **replan** (unparks all) |
| 5 | the run fails again after a replan | **abort** (exit 4, as today) |

- **Counting changes from fingerprint-repetition to per-slice failures.** A slice that
  fails three times with three *different* fingerprints is flailing and should be parked
  just the same, so the rung is driven by a per-slice `fails` counter. The fingerprint
  survives for FEEDBACK.md, for the `plan_dag` bypass (S1), and for telling `holdout`
  apart from `verify_agent` (S2) — it is no longer what advances the ladder.
- **Per-slice state → `tmp/autopilot/slices.json`** (decided in the grill). Runner-owned:
  written and read only by `loop.sh`, never named in any prompt, so BUILD cannot see or
  edit it. Shape:
  `{"plan_sig": "<sha1 of the ordered slice ids>", "slices": {"S2": {"fails": 3, "escalated": true, "parked": true}}}`.
  On every read the ids are reconciled against the plan — an id no longer in the plan is
  dropped, an id not yet in the file gets a fresh zeroed record — so a human editing the
  plan mid-run cannot desync it. A missing file means empty state, which is what makes a
  0.4.0-era `tmp/autopilot/` load unchanged (contract item 8). Ticking a slice retires its
  record; replan clears the whole file. The ladder therefore survives `--resume-run`,
  which today resets everything except the plan's checkboxes — an interrupted run must
  not pay for the same `--escalate-model` call twice.
- **`--escalate-model <model>`** (default `opus`; `none` disables). The run log records
  the model actually used and `escalated: true` for that iteration. Once the slice is
  ticked, BUILD returns to `--build-model`. Never escalate the verifier — the cheap
  adversarial tier is the point (`docs/model-policy.md`).
- **Cost guard.** Escalation counts against `--budget-usd`; log a warning when a single
  escalated call exceeds 25 % of the remaining budget.
- **Backward compatibility.** `--escalate-model none` on a plan with no `after:`
  annotations must reproduce 0.4.0 behaviour exactly: one slice, no parking possible,
  replan on the second failure, abort on the third.
- **Tests.** (a) two failed BUILDs then an escalated third that passes → run completes,
  log shows one escalated iteration, no replan; (b) a slice failing 3× on a diamond plan
  is parked and the sibling slice runs next; (c) parked slice's dependent is never
  selected; (d) all-parked → exactly one replan, records cleared; (e) failure after
  replan → exit 4; (f) `--escalate-model none` + unannotated plan → byte-identical rung
  sequence to 0.4.0.
- **Docs.** `docs/model-policy.md` § Tiers gains an "Escalation" row; LOOP-PROTOCOL.md
  § Caps & stuck detection is rewritten around the five rungs. CONTEXT.md gains
  **Escalation** and **Parked slice**.
- DoD: verify.sh green; tests (a)–(f) pass.

### S5 — Repo-map digest into autopilot

Closes ADR-0004 item 7. The contract there: autopilot gets a **compact digest**, not the whole graph.

- New `skills/repo-map/digest.sh <slice-hint>`: emits ≤ 40 lines — `stats`, top-10 `hotspots`, and for each file path mentioned in the selected slice line (S1 gives us the line) its `deps`/`rdeps` (capped at 8 each). Uses `query.sh` only; regenerates the map lazily as today.
- `build_prompt()` appends the digest under a heading "Repo map (navigational hint, not ground truth)" when `tmp/repo-map.json` can be produced; on any generator failure the digest is omitted and the iteration proceeds (repo-map's fault-injection contract already guarantees no wrong graph at exit 0). New flag `--no-repo-map` to disable; run log records `repo_map: true|false` per iteration for S3's comparison.
- **Do not add the digest to PLAN or the verifier** — reaffirmed in the grill against the argument that plan width is now load-bearing. The grep backend emits phantom edges by design (ADR-0004 Consequences: "a navigational hint, not ground truth"). BUILD can discount a wrong hint because it opens the file anyway; PLAN cannot — it would write the phantom edge into the plan as `after:`, and from that moment `select_next_slice()` enforces it as hard ordering. A map fed to PLAN would therefore *narrow* the DAG with invented dependencies, which is the opposite of what parking needs. The verifier must judge the diff, not the map.
- Width is instead handled by the PLAN prompt (S1) and **measured** by S3: `dag_width` (unblocked candidates at selection time) and `parked_count`. If `dag_width` is persistently 1 on real runs, PLAN is decomposing blind and a plan-side map becomes a 0.6.x question answered on data.
- Tests: loop test asserts the BUILD prompt contains the heading when a fixture map exists and omits it under `--no-repo-map`; digest line cap asserted.
- DoD: verify.sh green; `skills/repo-map/SKILL.md` documents `digest`; ADR-0004 gets a footnote "item 7 implemented in 0.5.0 (S5)".

### S6 — Docs refresh

Update `README.md`, `docs/architecture.md` (autopilot state model, gate list, `slices.json`), `skills/autopilot/SKILL.md` + `LOOP-PROTOCOL.md`, `docs/guide.html`, `docs/index.html` to reflect S0–S5. **Use CONTEXT.md's vocabulary as settled in the grill**: there are **four Iteration gates** (verify, secret, semantic, holdout) and a **Plan-dependency failure**, which is not a gate — it is a defect in the plan that bypasses the stuck ladder. An unqualified "gate" in prose is a smell; **Gate** is the genus, **Guard** / **Verify gate** / **Iteration gate** are the kinds. Also cover: Plan DAG, the five-rung stuck ladder, Escalation, Parked slice, the new metrics and every new flag. S2 changed no deny list — say so where the old docs imply otherwise. The guide's pipeline diagram must show slice selection by the runner. Keep the HTML self-contained (grep `src=|<link|@import|url(http`). DoD: verify.sh green; every new flag in `loop.sh --help` appears in the docs (add a check-consistency invariant for that: flags parsed in the `case` block ↔ mentioned in SKILL.md).

### S7 — Release 0.5.0 (HITL)

Bump `plugin.json` to 0.5.0; CHANGELOG entry summarising S0–S6 in the existing Added/Changed/Fixed shape, including the ADR-0005/0006 references and the backward-compatibility note; update `marketplace.json` if it pins a version. Open the PR and STOP. The human merges, tags `v0.5.0` on the merge commit on `main`, and enables the required status check from S0.

### M-slices (outline only — each starts with a grill)

- **M1 — Parallel slices via worktrees.** With DAG plans (S1), independent unblocked slices can run as separate `loop.sh` instances, each in `git worktree add ../<repo>-<slice>` on branch `autopilot/<run>/<slice>`; lock becomes per-worktree; a merge gate rebases each finished slice onto the integration branch and re-runs verify before the next slice starts from it. Grill topics: shared `tmp/autopilot/` vs per-worktree state, budget split, what "stuck" means across workers, whether Claude Code's own worktree flag (if any — verify on docs) obviates this. Cap at 3 workers by default.
- **M2 — Async HITL node.** A BUILD iteration may write `tmp/autopilot/ASK.md` (question + options) instead of ticking; the runner posts it as `gh issue comment` on the source issue, marks the slice `waiting`, and either continues with other unblocked slices (M1) or exits with a new code 5. A reply on the issue (polled at start, or `--answer <file>`) is appended to FEEDBACK.md and the slice resumes. Grill: how to keep the model from over-asking (budget of one ask per slice?), and the verifier's stance on a slice that shipped with an unanswered ask. **Prior art (loopkit `hitl-escalate`, surveyed 2026-08-28):** its trigger taxonomy (ambiguous spec / missing credential / destructive action / 3+ verify fails), the 5-line message shape ending in `Choices:`, the `BLOCKED.md` exit contract, and its warning that escalating on solvable problems trains humans to ignore the channel — the last one is the answer-shaped version of our over-asking worry.
- **M3 — `drift-check` skill (entropy management).** Read-only report, haiku tier: CONTEXT.md terms vs identifiers actually used in `src/` and docs; ADR references to modules that no longer exist; `CLAUDE.md` length and duplicated rules; skills referencing removed flags. Emits a markdown report and, with `--file-issues`, one `gh issue` per finding with label `drift`. Intended as a weekly CI job in consumer projects (`/project-infra` gains a `drift` mode). Grill: thresholds, false-positive tolerance, whether to run it on the harness itself in S0's workflow.
- **M4 — Backend-agnostic runner.** Extract the `claude -p` invocation into `run_agent()` with a backend interface (prompt in, JSON `{result, cost_usd, usage, num_turns}` out, allowlist mapping), add a `codex exec` adapter as the second implementation, and ship an `AGENTS.md` that points other agents at `CLAUDE.md` + `CONTEXT.md`. Grill: allowlist semantics differ per backend (Codex sandbox vs Claude allowedTools) — decide whether a backend without equivalent permission scoping is allowed to run BUILD at all, or only PLAN/verify.
- **M5 — `project-infra` beyond JS.** Detect `pyproject.toml` (uv, pytest, ruff, mypy) and `go.mod` (go vet, go test, golangci-lint) and emit the matching verify chain, CI and devcontainer; devcontainer template always installs `jq`; autopilot's BUILD allowlist becomes stack-aware (derive from the detected toolchain the way `allowlist.sh` derives the verify grant). Grill: how much of `allowlist.sh` becomes a per-stack table.

## Tracker housekeeping (decided in the grill)

Done as part of `/to-issues`, not as a slice:

- **#11** (M3 autopilot tune-up) → **close as superseded**. Its metrics work is S3 and its map wiring is S5. The two leftovers are obsolete under this design and the closing comment must say why: the ADR-0002 stop-gate wiring would have stopped a `claude -p` session ending without verify, but the runner re-runs verify itself every iteration (GATE b) — it would guard the same thing twice and then have to un-wire a hook on run end; per-iteration spec files are replaced by the run log, FEEDBACK.md, `slices.json` and the plan itself.
- **#13** (roadmap map for 0.3.0 → 0.4.x) → **close**, superseded by a new 0.5.0 map issue. Its claim that the `v0.4.0` tag is missing is stale: the tag exists (`3e354eb` → `8402df0`).
- **#12** (design-harness marketplace entry) → **leave open**, still blocked externally on that repo existing (ADR-0003).
- **New `needs-grill` issue for 0.6.x**: "guard hooks fail open without jq — should they?", carrying the full analysis from #25's closing comment (the L1-deny coverage table and the three-way middle option). Not in 0.5.0: it is a policy change with its own ADR, off this PRD's axis, and it does not threaten the 0.5.0 run — BUILD's allowlist grants neither `git push` nor `rm`, so the guards in question have nothing to catch there. The point of the issue is that the analysis stops being buried in a closed issue's last comment.

## Out of scope

- Any orchestration beyond a single machine (Gas Town-style federation, Wasteland), and any MCP-based code graph (ADR-0001 stands).
- Vendor re-sync of Pocock/Vercel skills — separate PRD when upstream drift warrants it.
- Design lane (ADR-0003).
- Running BUILD with `--dangerously-skip-permissions`, or making any Stop hook block by default (ADR-0002 stands).
- Changing the Schema v1 contract of `tmp/repo-map.json`.

## Risks

- ~~**Path-scoped `Read` denial in headless mode may not exist.**~~ Retired in the grill: ADR-0006 hides the holdout by location, so no tool-denial flag is needed and the risk no longer applies. The residual risk is weaker — BUILD could guess the out-of-worktree path — and is accepted in the ADR.
- ~~**`stream-json` parsing in S3**~~ Retired in the grill: the parser is cut entirely (see S3), so `run_claude` keeps exactly one input format and the budget cap keeps its only cost source. No `--metrics` flag ships in 0.5.0.
- **DAG plans invite over-decomposition.** Plan-model prompt must keep "provable by verify on its own" as the slice criterion; S1's loop tests include a plan with a spurious edge to make sure the runner handles it, but prompt quality is a soft control — watch the `cost_per_ticked_slice` metric from S3 across the first real runs.
- **Escalation can hide a bad plan.** S4 leaves the replan/abort thresholds untouched so an opus-rescued slice still counts toward stuck detection on the next failure.
- **CI on a public repo runs on forks' PRs.** The workflow runs no secrets and nothing network-bound; keep it that way (no `pull_request_target`).