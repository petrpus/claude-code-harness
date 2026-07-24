# Opt-in Stop-hook verify gate as an exception to "Stop hooks always exit 0"

The harness rule says UserPromptSubmit/Stop hooks must always exit 0 —
reminders, never gates — because a blocking Stop hook can disrupt a normal
interactive turn in consumer projects that don't follow our conventions. The
new `require-verify-before-stop` template (roadmap item U1) deliberately
breaks this: it exits 2 until `tmp/.last-verify-status` reports a fresh pass,
implementing the official "deterministic gate" verification tier for
unattended runs. It is safe only because it is **opt-in**: never wired in
`hooks/hooks.json`, shipped solely as a template a project (or autopilot)
enables consciously, and Claude Code lifts the block after 8 consecutive
refusals, so it cannot deadlock.

Considered: making the gate a default Stop hook — rejected; it would hard-fail
every consumer project without a verify command.
