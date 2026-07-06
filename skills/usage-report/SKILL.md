---
name: usage-report
description: Summarize Claude token usage and approximate USD cost over a recent window, by day and by model. Use when the user asks "how much have I spent", "usage report", "token usage", "co to stálo", or invokes /usage-report.
argument-hint: "[days-back, default 7]"
---

# /usage-report

Cost visibility digest. Pulls from whichever sources are available, in order
of preference, and clearly labels how approximate each number is.

## Inputs

- `$ARGUMENTS` — optional integer **X**, days back from today (inclusive).
  Defaults to `7`.

## Sources, in preference order

### 1. ccusage (preferred)

```bash
npx ccusage@latest --json
```

If `npx` resolves and the command succeeds, parse the JSON and build the
totals table from it directly (it already computes cost per model). This is
the most complete source — it reads Claude Code's local usage data across all
projects, not just this repo.

If `npx` fails (offline, not installed, non-zero exit) — say so in one line
and fall through to the sources below rather than stalling.

### 2. Autopilot run logs (harness first-class source)

```bash
ls tmp/autopilot/run-*.jsonl 2>/dev/null
```

Each line is JSON with `ts, run_id, iter, phase, model, duration_s, cost_usd,
input_tokens, output_tokens, exit_code, verdict`. Filter lines with `ts`
inside the last X days, then sum `cost_usd`, `input_tokens`, `output_tokens`
grouped by `(day, model)` and again by run. This source is exact for
autopilot-driven work — it's the runner's own accounting, not an estimate.

### 3. Transcript fallback (best-effort, approximate)

If neither of the above yields anything, note that per-message `usage`
blocks can be summed from Claude Code's local transcript JSONL files under
`~/.claude/projects/<project-slug>/*.jsonl` with `jq` (look for
`.message.usage.{input_tokens,output_tokens}` per line). This format is
undocumented and may change between Claude Code versions, so treat any total
from it as a rough approximation, not a bill — one short paragraph is enough
to explain this, don't build tooling around it.

## Pricing

Rates live in `PRICING.md` (bundled with this skill) — approximate, dated,
and explicitly not authoritative. Formula:

```
cost_usd = (input_tokens / 1e6) * in_price_per_million
         + (output_tokens / 1e6) * out_price_per_million
```

Only apply this formula to token counts that didn't already come with a
`cost_usd` (ccusage and autopilot logs both already compute cost — use their
numbers as-is; don't re-derive and risk disagreeing with them).

## Output

A compact table:

| Day | Model | Input tok | Output tok | Approx $ |
|---|---|---|---|---|

...followed by a totals row, and a one-line note on which source(s) fed the
table (ccusage / autopilot / transcript-fallback) and the pricing date from
`PRICING.md`.

## Save

After printing, ask the user (one sentence) whether to save the report. If
yes:

```bash
mkdir -p tmp
out="tmp/usage-report-$(date +%Y-%m-%d).md"
```

Overwrite without prompting if it already exists (regenerated artifact).

## Anti-patterns

- Presenting `PRICING.md` numbers as authoritative — always label them
  approximate and dated.
- Silently mixing sources without saying so — if ccusage covers most days but
  autopilot fills a gap, say which rows came from where.
- Building a persistent tool around the transcript-JSONL fallback — its
  schema isn't a stable contract.

## Edge cases

- **No sources available at all**: say so plainly, don't fabricate a table.
- **X = 0**: today only.
- **ccusage present but empty for the window**: fall through to autopilot logs
  rather than reporting an all-zero table.
