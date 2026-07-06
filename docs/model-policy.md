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

`fable` is available as a fast planning-tier model where latency matters more
than depth; treat it as an alternative top-tier for planning, not for
implementation.

## Where it's encoded

- **Agents** pin their tier in frontmatter:
  - `agents/verifier.md` → `model: haiku` (cheap adversarial gate).
  - `agents/code-reviewer.md` → `model: sonnet` (mid; prevents an opus-priced
    review when the main session runs opus).
- **autopilot** (`skills/autopilot/loop.sh`) defaults: `--plan-model opus`,
  `--build-model sonnet`, `--verify-model haiku`. Every phase is overridable per
  run.
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
