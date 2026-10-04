---
name: harness-init
description: Bootstrap a project for the code-harness plugin — copies the settings template into .claude/settings.json, ensures tmp/ is ignored, creates the workflow labels, and prints what to customize next. Run after installing the plugin.
disable-model-invocation: true
---

# Skill: /harness-init

Bootstraps a project to use the harness plugin. Idempotent — safe to re-run;
won't clobber existing config without asking.

## What it does

1. Confirms we're inside a git repo.
2. Creates `.claude/` if missing.
3. Copies `${CLAUDE_PLUGIN_ROOT}/templates/project-settings.template.json` →
   `.claude/settings.json`. If a settings file already exists, show the diff
   and ask the user whether to overwrite, merge manually, or skip.
4. Ensures `tmp/` exists (used by hooks for verify status) and that it's in
   `.gitignore`.
5. Prints a next-step checklist.

## Steps

### 1. Pre-flight

```bash
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
```

If empty: abort with "Run `git init` first or cd into a git repo."

### 2. Verify plugin reachable

`${CLAUDE_PLUGIN_ROOT}/templates/project-settings.template.json` must exist.
If not: abort with "Plugin not installed. Run `/plugin install code-harness@claude-code-harness` first."

### 3. Settings file

If `.claude/settings.json` doesn't exist:

```bash
mkdir -p "$PROJECT_ROOT/.claude"
cp "${CLAUDE_PLUGIN_ROOT}/templates/project-settings.template.json" \
   "$PROJECT_ROOT/.claude/settings.json"
```

If it exists: read both files, show the user what keys are in the template
but not in current settings, and ask whether to merge selected entries.
**Don't auto-overwrite** — manual merge is safer than diff.

### 4. tmp/ directory

```bash
mkdir -p "$PROJECT_ROOT/tmp"
```

If `.gitignore` exists and doesn't already ignore `tmp/`, append `tmp/` to it
(this also covers `tmp/autopilot/` run state and `tmp/session-log.jsonl`).
If `.gitignore` doesn't exist, create one with `tmp/` + `.env*` +
`!.env.example` + `node_modules/`. The `!.env.example` un-ignore is important:
`/project-infra env` writes `.env.example` and it should be committed.

### 5. Workflow labels

The workflow skills (`to-prd`, `to-issues`, `start-feature`, `implement-issue`,
`/deliver`) route work by GitHub labels. Create them idempotently:

```bash
if command -v gh >/dev/null 2>&1 && gh repo view >/dev/null 2>&1; then
  gh label create map             --force --color 5319E7 --description "Delivery map: DAG of issues for /deliver"
  gh label create prd             --force --color 0E8A16 --description "Product requirements document"
  gh label create ready-for-agent --force --color 1D76DB --description "Fully specified; an agent can pick it up"
  gh label create needs-human     --force --color D93F0B --description "Needs a human decision or action"
  gh label create needs-triage    --force --color FBCA04 --description "Needs triage before work"
fi
```

`--force` updates a label that already exists, so re-running is safe. If `gh`
is missing, unauthenticated, or the repo has no GitHub remote, skip this step
without failing (say "skipped label bootstrap: no gh/remote") — never abort init.

### 6. Print checklist

```
Harness initialized.

Next steps:
1. Edit .claude/settings.json:
   - Add project-specific WebFetch domains (APIs you scrape, docs you reference)
   - Add Read paths if porting from a sibling repo
   - Add allow patterns specific to this project (e.g. Bash(cursor-kit:*))
2. (Optional) Create CLAUDE.md with project rules, conventions, and entity-
   specific review checklist that extends the code-reviewer agent.
3. (Optional) Add project-local hooks at .claude/hooks/*.local.sh and register
   them in .claude/settings.json alongside the plugin hooks.
4. Run /project-infra to provision a verify command, CI, and a devcontainer
   (autopilot requires an objective verify command before it will run).
5. Run /harness-doctor to verify the setup.

New in this harness: /autopilot (controlled long autonomous runs) and
/deliver (a Map issue → one PR per issue), /cost-discipline + /usage-report
(token/cost awareness), /openapi-sync, /repo-map and /code-map (docs),
/project-infra (infra + CI/CD). /code-harness:autopilot, /code-harness:deliver
and this init are user-invoked only — Claude won't start them on its own.
```

## When not to use

- In a non-git directory (run `git init` first)
- In a project that already has heavy custom `.claude/settings.json` — review
  what's in the template and merge by hand instead of through this skill
