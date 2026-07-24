# UI/design skills live in a separate design-harness plugin, never here

UI polish is a real gap in agent-built apps, and mature UI skill collections
exist (ibelick/ui-skills, Anthropic frontend-design). We decided they must NOT
be vendored into this harness: they solve a different concern (taste and
visual iteration vs. dev workflow), the strongest ones are stack-specific
(`baseline-ui` mandates Tailwind + motion/react, unacceptable in a universal
harness), and the screenshot→critique→fix feedback loop is browser
infrastructure, not a skill. Instead, a separate `design-harness` plugin will
be listed as a second entry in this repo's marketplace manifest, so consumers
opt in per project.

This is a scope decision: a future vendor sync that finds attractive UI
skills upstream must route them to design-harness, not here.
