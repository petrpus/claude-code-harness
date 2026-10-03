# Paid runners and the bootstrap are user-invoked only

Every model-invocable skill puts its `description` into the skill listing of
every session. Claude Code budgets that listing at about 1% of the context
window and, when it overflows, drops the descriptions of the least-used skills
first — so the harness's ~35 descriptions (≈ 8.7k characters before 0.7.0)
compete with each consumer project's own skills. Claude Code measured the
harness at ≈ 3.5k always-on tokens (`claude plugin details`).

Three skills start things whose timing a person should own: `autopilot` and
`deliver` launch long, unattended runs that spend real budget (hours, many
model calls, merges into an integration branch), and `harness-init` writes
`.claude/settings.json` and creates GitHub labels. None of them is composed by
another skill through the Skill tool — `deliver.sh` runs `loop.sh` directly,
and `next` / `start-feature` only point the user at `/deliver`.

`disable-model-invocation: true` removes a skill's description from the
listing and blocks Claude from invoking it, including when Claude follows
another skill's instructions; Claude is told to ask the user to run it instead.
It also keeps the skill out of subagent preloads and scheduled tasks. This is
the documented behaviour that the sync-log's open question about
`to-issues` / `to-prd` was waiting for.

## Decision

1. **`autopilot`, `deliver` and `harness-init` carry
   `disable-model-invocation: true`.** Only a person starts them, by typing
   `/code-harness:autopilot`, `/code-harness:deliver #<map>` or
   `/code-harness:harness-init`. The vendored, Frozen `zoom-out` keeps the flag
   it already carried upstream, so the **user-only set** the lint enforces is
   these three plus `zoom-out` — an inherited exception, not a fourth
   decision.
2. **A skill that another skill composes never carries the flag** —
   `to-issues`, `to-prd`, `grill-*`, `triage`, `tdd`, `codebase-design`,
   `domain-modeling` and anything a workflow skill tells Claude to run. The flag
   would break `start-feature` and `next`. (This closes the sync-log question:
   the upstream flag on `to-tickets` / `to-spec` stays dropped.)
3. **Skills that hand off to a user-only skill say so**: `start-feature` and
   `next` tell the user to run `/code-harness:deliver #<map>` rather than
   "calling" it.
4. **`scripts/check-consistency.sh` enforces it**: the three skills have the
   flag, the composed ones don't, and the descriptions that stay in the listing
   fit a budget set in the script. Raising the budget is a deliberate edit.

## Consequences

- Natural-language triggers ("spusť autopilota", "doruč mapu") no longer start
  a run; Claude answers with the command to type. That is the point: a paid,
  multi-hour run starts on a human keystroke.
- Their descriptions leave the always-on listing, and long descriptions of
  the remaining own skills were cut to about 250 characters. Vendored skills
  keep their upstream descriptions (vendoring discipline). Always-on skill
  descriptions went from ≈ 8,540 to 6,849 characters, and `claude plugin
  details` projects ≈ 3.1k always-on tokens instead of ≈ 3.5k.
- `disable-model-invocation` and `argument-hint` are Claude Code fields. A skill
  that carries one can't be uploaded to claude.ai or the Skills API as is;
  the three runners are Claude Code-only anyway.
