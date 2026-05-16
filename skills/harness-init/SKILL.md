---
name: harness-init
description: Bootstrap a project to use the claude-code-harness plugin. Copies the settings template into .claude/settings.json, ensures tmp/ exists for verify-status, and prints what to customize next. Run after `/plugin install claude-code-harness`.
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
If not: abort with "Plugin not installed. Run `/plugin install claude-code-harness` first."

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

If `.gitignore` exists and doesn't already ignore `tmp/`, append `tmp/` to it.
If `.gitignore` doesn't exist, create one with `tmp/` + `.env*` + `node_modules/`.

### 5. Print checklist

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
4. Run /harness-doctor to verify the setup.
```

## When not to use

- In a non-git directory (run `git init` first)
- In a project that already has heavy custom `.claude/settings.json` — review
  what's in the template and merge by hand instead of through this skill
