# Model policy — model-tiering for cost-conscious autonomy

The harness spends the cheapest model that can do a job correctly, and reserves
the expensive one for the work that actually needs it. This is a cost lever, not
a quality compromise: verification and mechanical checks are *better* done by a
skeptical cheap model run many times than by one expensive pass.

## Tiers

| Tier | Model | Use for |
|---|---|---|
| **cheap** | `haiku` | Verification, adversarial gates, mechanical/greppable checks, lint triage, log parsing, secret-scans, classification. High volume, low judgement. |
| **mid** | `sonnet` | Implementation, code review, refactoring, most day-to-day agent work. The default working tier. |
| **top** | `opus` | Planning, architecture, decomposition (PRD → plan), domain modeling, grilling, resolving genuinely hard trade-offs. Low volume, high judgement. |
| **escalation** | `--escalate-model` (default `opus`) | Rung 2 of autopilot's stuck ladder (S4B) — a slice's *next* BUILD attempt only, after it has failed twice on `--build-model`; the slice returns to `--build-model` once it ticks. `none` disables escalation outright. Never applied to the verifier — the cheap adversarial tier is the point. |

`fable` is available as a fast planning-tier model where latency matters more
than depth; treat it as an alternative top-tier for planning, not for
implementation.

## Where it's encoded

- **Agents** pin their tier in frontmatter:
  - `agents/verifier.md` → `model: haiku` (cheap adversarial gate).
  - `agents/code-reviewer.md` → `model: sonnet` (mid; prevents an opus-priced
    review when the main session runs opus).
- **autopilot** (`skills/autopilot/loop.sh`) defaults: `--plan-model opus`,
  `--build-model sonnet`, `--verify-model haiku`, `--escalate-model opus`.
  Every phase is overridable per run. Escalation counts against the same
  `--budget-usd` as everything else — no separate ceiling — but a single
  escalated call costing more than 25% of what's left logs a warning, since
  an escalation that's burning the budget fast is worth a human noticing.
- **Subagent fanout** (`cost-discipline`): fan work out to the cheapest tier
  that fits; pin the model explicitly so a fanned-out fleet doesn't inherit an
  expensive main-session model.

## The rule of thumb

> Plan once with the smartest model. Build with a competent one. Verify often
> with a cheap, skeptical one. Never let the verify tier be the same instance
> that wrote the code.

Verification must be adversarial and independent — a fresh cheap model that
assumes the code is broken catches shortcuts the author's own model rationalizes
away. That is why the gate is haiku running `agents/verifier.md`, not the build
model checking its own work.

## How we measure

Claims about model tiering (does the escalation rung earn its cost? does the
repo-map digest actually save tokens?) are checked against data, not
intuition. Every `claude -p` call and every iteration outcome is logged to
`tmp/autopilot/run-<id>.jsonl` (S3A); `tmp/autopilot/status.json` carries
per-run aggregates recomputed on every write (S3B: `gate_fail_rate`,
`cost_per_ticked_slice`, `mean_dag_width`, `escalations`, …); and
`bash skills/usage-report/report.sh` renders a per-run table, a per-shortcut
verdict-distribution histogram, and the repo-map on/off token comparison
across however many runs are on disk. See
`skills/autopilot/LOOP-PROTOCOL.md` § Per-run aggregates for field
definitions.

**How we measure (0.5.0).** `run_aggregates` in `skills/autopilot/loop.sh` writes
per-run figures into `tmp/autopilot/status.json`; `/usage-report` renders them across
runs. Two cautions learned from the first run: an average must be taken over what was
actually *measured* — reading a missing metric as `0` put `mean_dag_width` below the
minimum any measured iteration could produce — and a metric added mid-run only covers
the iterations after it landed, so early figures are partial by construction, not wrong.

**Open question (2026-08-28, loopkit survey).** Loopkit's `model-routing` claims the
opposite corner of the grid: a *cheap executor + frontier judge* beats a frontier
executor with no judge, arguing a weak judge is worse than no judge and that judge
cost stays low because it only reads the diff. Our tiering (sonnet build, haiku
judge) sits on the other diagonal. Not adopted — but it is an empirical question,
and PRD 0002 S3's metrics (holdout failures, gate-fail rates, per-shortcut verdict
distribution) are what an answer would be made of. Revisit with data.
