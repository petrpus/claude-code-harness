# Pricing reference — approximate, dated 2026-07

**These figures are approximate and for rough cost estimation only.** Verify
against current Anthropic pricing before relying on them for anything
budget-critical — list prices change, and volume/caching discounts are not
reflected here at all.

| Tier | Model id(s) referenced by this harness | Input $/1M tok (approx) | Output $/1M tok (approx) |
|---|---|---|---|
| top | `claude-opus-4-8` (opus) | ~$15 | ~$75 |
| mid | `claude-sonnet-5` (sonnet) | ~$3 | ~$15 |
| cheap | `claude-haiku-4-5` (haiku) | ~$1 | ~$5 |

`fable` (fast planning-tier) — no stable published per-token rate at time of
writing; treat as roughly opus-adjacent for planning-volume budgeting until a
real figure is confirmed.

## Formula

```
cost_usd = (input_tokens / 1e6) * in_price_per_million
         + (output_tokens / 1e6) * out_price_per_million
```

Note: prompt caching, batch API discounts, and long-context surcharges (if
any) are not modeled here — this is a back-of-envelope figure, not an invoice
reconciliation.
