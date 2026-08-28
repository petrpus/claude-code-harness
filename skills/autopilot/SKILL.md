---
name: autopilot
description: >-
  Run a long, controlled autonomous coding session ("řízený běh") — a loop that
  implements a plan slice by slice with hard verify gates, cost/iteration/time
  caps, per-iteration git checkpoints, and a structured run log. Use for
  unattended multi-step work derived from a PRD or GitHub issue. Triggers:
  "spusť autopilota", "run the loop", "autonomní běh", "let it run until done".
---

# autopilot — controlled long autonomous runs

A safe re-engineering of the fresh-context loop: every iteration is a **new**
`claude -p` session, all state lives on disk in `tmp/autopilot/`, and the runner
(not the model) enforces the gates. The model can't fake "done" — the runner
re-runs verify itself, scans the diff for secrets, and has a cheap adversarial
verifier hunt for shortcuts before any iteration counts as complete.

Full protocol, gate semantics, and safety rationale: **LOOP-PROTOCOL.md**.
Model tiers: `docs/model-policy.md`.

## When to use

- You have a well-specified task (a PRD from `/to-prd`, or a GitHub issue) that
  needs several implement→verify cycles.
- You want it to run unattended without risking quality or safety.

Do **not** use it for exploratory work with no acceptance criteria, or on `main`
(the runner refuses both).

## How to run

1. **Provision a verify command** if the project has none: `/project-infra verify`.
   The loop refuses to start without an objective gate.
2. **Scaffold the charter.** Create `tmp/autopilot/PROMPT.md` from
   `PROMPT.template.md` — derive it from a PRD or issue, and fill in the source
   link and acceptance criteria (these are mandatory; they're what the verifier
   checks against). Leave `IMPLEMENTATION_PLAN.md` absent — the PLAN phase writes
   it — or seed it from `PLAN.template.md`.
   Optionally, write acceptance scenarios the build model must never see from
   `HOLDOUT.template.md`, saved **outside the worktree** (default location
   below, or point `--holdout <path>` at your own) — never under
   `tmp/autopilot/`, which BUILD already reads freely.
3. **Be on a feature branch with a clean tree.**
4. **Start the run:**

   ```bash
   ${CLAUDE_PLUGIN_ROOT}/skills/autopilot/loop.sh \
     --max-iterations 10 --max-minutes 120 --budget-usd 10
   ```

   Defaults: plan=opus, build=sonnet, verify=haiku (override with
   `--plan-model` / `--build-model` / `--verify-model`). `--dry-run` prints the
   plan of calls without spending. `--resume-run` continues an interrupted run,
   adopting its prior run id, iteration count and accumulated cost from disk
   (R1) instead of starting over at iteration 0 / cost 0. `--holdout <path>`
   overrides the default holdout location
   (`${XDG_STATE_HOME:-$HOME/.local/state}/autopilot/<run-id>/HOLDOUT.md`);
   omit it and a missing file just disables gate (e). Every BUILD prompt also
   carries a compact repo-map digest (`skills/repo-map/digest.sh`) — stats,
   top hotspots, and deps/rdeps for any file the selected slice names — as a
   navigational hint, not ground truth; `--no-repo-map` turns it off.

   If this repo *is* the autopilot harness's own source, a slice can
   legitimately be to fix `loop.sh`/`plan.sh`/`allowlist.sh` — the runner
   notices its own sourced files changed on disk and re-execs itself under the
   same run id before the next iteration (R1), so a live run picks up the fix
   without a human restart. See `LOOP-PROTOCOL.md` § Runner self-reload.

## What you get

- `tmp/autopilot/status.json` — live state, iterations, accumulated `$` cost.
- `tmp/autopilot/run-<id>.jsonl` — one line per phase (model, duration, cost,
  tokens, verdict) — feed it to `/usage-report`.
- A git checkpoint commit per iteration (`autopilot: iteration N (...)`) for
  clean rollback.

## Gates (all must pass to finish)

1. `STATUS: done` sentinel in the plan.
2. **Machine verify** (gate b) — the runner executes the verify command itself.
3. **Secret scan** (gate c) — the iteration diff is grepped for keys/tokens/private keys.
4. **Semantic verify** (gate d) — haiku runs `agents/verifier.md` adversarially
   against the diff (the 17-shortcuts checklist).
5. **Holdout** (gate e) — when `--holdout <path>` (or its default location) points
   at a `HOLDOUT.md`, the runner inlines its content into the verifier prompt
   only (never into BUILD's) and the verifier independently checks each
   Given/When/Then scenario against the diff. A missing file disables this
   gate with a one-line notice, not an error — see `docs/adr/0006-*.md`.

Any failure appends to `FEEDBACK.md`, resets the sentinel, checkpoints WIP, and
feeds the next iteration. A holdout failure is fingerprinted `holdout`, distinct
from a generic semantic-verify failure (`verify_agent`), so stuck detection can
tell them apart. Same failure twice → one automatic replan; three times → abort.
Exit codes: 0 done · 2 iteration cap · 3 time cap · 4 budget/stuck.

Gate (d) parses the verifier's output three ways, not just pass/fail: a reply
that isn't a JSON object with a boolean `.pass` (refusal prose, a clarifying
question, garbled/fenced non-JSON) is a **gate malfunction** — the verifier
declined to judge, which is not the same as it finding a shortcut. This adds
no new gate; it's still gate (d) misbehaving. The runner retries it once
against the same unchanged diff before treating it as a failure; if the retry
is also inconclusive, that's fingerprinted `no_verdict` (distinct from
`verify_agent`) and FEEDBACK.md names the malfunction instead of quoting the
refusal as findings — still blocking, still counted on the stuck ladder, so a
permanently broken gate still terminates the run.

Each iteration, the runner first picks which plan item to build:
`select_next_slice()` (`plan.sh`) walks `IMPLEMENTATION_PLAN.md` as a **Plan
DAG** — optional `(after: <id>, <id>)` annotations on a slice's checkbox line
— and hands BUILD the one unblocked, unparked slice it selected (a plan with
no annotations degrades to "first unchecked box," unchanged from 0.4.0). A
broken DAG (a cycle, or an `after:` naming an id that doesn't exist) is a
**Plan-dependency failure**, not a gate: it replans immediately and never
goes through the retry/escalate/park ladder above — a plan bug can't be fixed
by retrying the same build. See `docs/adr/0005-*.md`.

## Safety

Never runs with `--dangerously-skip-permissions`. Plugin hooks + settings deny
stay active (they fire in headless mode too), so the push-from-main and
`.env`/secret guards apply mid-run. For fully unattended runs, run inside a
devcontainer (`/project-infra devcontainer`). Before opening a PR, do a manual
`/security-review` pass — the loop's secret scan is a floor, not a full audit.

**Opt-in Stop gate.** For a run, autopilot MAY register
`templates/require-verify-before-stop.sh` as a Stop hook in the project's
`.claude/settings.json` — the deterministic verification tier (ADR-0002), so a
turn cannot end on a stale or failing verify. If it does, it **MUST remove that
hook entry on run end** (success or abort), leaving the project's Stop config
exactly as it found it. The runner's own machine-verify gate is unaffected
either way; the Stop gate only adds belt-and-suspenders for the interactive
iterations.
