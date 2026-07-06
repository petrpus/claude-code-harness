---
name: cost-discipline
description: >-
  Doctrine for keeping token spend and context usage under control — read
  narrowly, batch tool calls, fan out subagents sparingly. Load before
  token-heavy work: large-scope reads/greps across a big codebase, fanning out
  multiple subagents, connecting new MCP servers, or any long session that
  risks context rot. Triggers: "keep this cheap", "watch the budget", "don't
  blow the context", "fan out subagents", "spawn agents for this".
---

# Cost discipline

Checklist, not prose. Apply before reading widely, calling tools, or fanning
out subagents.

## Context budget

- **Read only what the task needs.** Prefer `Grep`/targeted `Read` (with
  `offset`/`limit`) over whole-file or whole-directory reads. Don't read a
  500-line file to answer a question answerable by 10 lines of it.
- **Summarize, then drop.** Once a large tool output (log dump, test run,
  search sweep) has yielded its answer, don't keep re-quoting it — carry
  forward the conclusion, not the raw text.
- **Externalize durable state to disk** instead of holding it in context across
  a long session — the way `autopilot` writes `tmp/autopilot/status.json` and
  a per-iteration run log rather than re-deriving state from scrollback each
  turn. If you'll need a fact again in 20 turns, write it down now.
- **Watch for context rot.** Past roughly the mid-point of the context window,
  treat every further large read as a cost decision, not a default — ask
  whether a narrower read or a delegated subagent would get the same answer
  cheaper.

## Tool restraint

- **No speculative tool calls.** Don't grep "just in case" or read a file
  that's merely adjacent to the task. Each call costs tokens whether or not it
  helps.
- **Batch independent calls in one turn.** If two reads/greps don't depend on
  each other's output, issue them together rather than serially.
- **Mind standing MCP connections.** Every connected MCP server's tool
  descriptions are re-sent in the system prompt on every turn, whether used or
  not. Enable only the servers a session actually needs; disconnect the rest.

## Subagent fanout

- **Fan out only genuinely parallelizable, read-heavy work** — independent
  research/search tasks with no shared state. Don't parallelize work that
  needs to see each other's output.
- **Narrow scope per subagent.** One question or one directory per agent, not
  "go explore the repo." A tight brief is cheaper and more reliable than a
  broad one.
- **Pin the model per tier** — a fanned-out fleet must not silently inherit an
  expensive main-session model. Tiers and rationale: `docs/model-policy.md`
  (don't restate them here — link to it).
- **Cap fanout breadth.** A handful of agents, not dozens; each one adds a
  full context load plus its own tool calls.
- **A subagent returns a conclusion, not a file dump.** Brief it to report
  findings in prose/short lists; raw transcripts or full file contents belong
  on disk, not in the parent's context.

## Where to look for numbers

- Actual historical spend: `/usage-report`.
- Enforced budget in a long unattended run: `/autopilot`'s `--budget-usd` (and
  `--max-iterations` / `--max-minutes`) — caps are gates the runner enforces,
  not suggestions to the model.
