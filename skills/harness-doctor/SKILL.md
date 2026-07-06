---
name: harness-doctor
description: Sanity-check that a project is correctly set up for claude-code-harness. Finds leftover stale skills/hooks/agents that the plugin now provides, missing settings, and other config drift. Read-only — never modifies anything.
---

# Skill: /harness-doctor

Validates that the project's `.claude/` is consistent with the harness plugin.
**Read-only**: reports findings, never edits.

## What it checks

### 1. Plugin reachable

`${CLAUDE_PLUGIN_ROOT}/templates/project-settings.template.json` exists.
If not: 🔴 — plugin isn't installed or env var isn't set.

### 2. `.claude/settings.json` present

If not: 🟠 — harness baseline isn't applied. Suggest `/harness-init`.

### 3. Stale local skills that the plugin now provides

Check `.claude/skills/` for any of these (each shadows the plugin version):

- Vendored: `caveman`, `codebase-design`, `diagnose`, `domain-modeling`,
  `grill-me`, `grill-with-docs`, `grilling`, `handoff`,
  `improve-codebase-architecture`, `prototype`, `research`, `tdd`, `to-issues`,
  `to-prd`, `triage`, `write-a-skill`, `zoom-out`, `find-skills`
- Own: `next`, `commit-agent`, `implement-issue`, `start-feature`,
  `migration-check`, `worklog`, `harness-init`, `harness-doctor`, `autopilot`,
  `cost-discipline`, `usage-report`, `project-infra`, `openapi-sync`, `code-map`

Each match → 🟠. Suggest `rm -rf .claude/skills/<name>/`.

### 4. Stale local agents

Check `.claude/agents/` for `code-reviewer.md` and `verifier.md`. Each present
→ 🟠 (plugin provides them).

### 5. Stale local hooks

Check `.claude/hooks/` for each of: `lib.sh`, `inject-git-context.sh`,
`on-stop.sh`, `session-log.sh`, `pre-bash.sh`, `pre-commit-gate.sh`,
`pre-edit.sh`. Each match → 🟠.

`.local.sh` files (e.g. `pre-edit.local.sh`) are project-specific overrides
and **fine** — don't flag those.

### 5b. jq available (hooks depend on it)

Run `command -v jq`. If missing → 🟡: "The Bash/edit guard hooks parse tool
input with jq and **fail open** (allow) without it — install jq to restore the
guards." (`inject-git-context` / `on-stop` still work; only the guards degrade.)

### 6. settings.json hook entries duplicating plugin hooks

Parse `.claude/settings.json` `hooks`. Any command path ending in one of the
harness hook filenames (see §5) and pointing under `${CLAUDE_PROJECT_DIR}/.claude/`
→ 🟠 (plugin registers them via `${CLAUDE_PLUGIN_ROOT}` automatically).

Entries pointing at `*.local.sh` are fine.

### 7. tmp/ directory

If `.claude/settings.json` or any hook references `tmp/.last-verify-status`
and `tmp/` doesn't exist → 🟡: "Create tmp/ for verify-status convention,
or remove the reference."

### 8. CLAUDE.md presence (soft)

If no `CLAUDE.md` in repo root → 🟡: "Plugin's code-reviewer benefits from
a project rule file."

## Output

```markdown
# Harness doctor — <project-name>

## 🔴 Errors (n)
- Plugin not installed (no CLAUDE_PLUGIN_ROOT). Run `/plugin install claude-code-harness`.

## 🟠 Issues (n)
- `.claude/skills/commit-agent/` exists locally; plugin provides it.
  Fix: `rm -rf .claude/skills/commit-agent/`
- `.claude/settings.json` registers `${CLAUDE_PROJECT_DIR}/.claude/hooks/pre-edit.sh`;
  plugin already registers it. Remove the local entry.

## 🟡 Notices (n)
- No `CLAUDE.md` in repo root. Plugin's code-reviewer benefits from a project rule file.
- `tmp/` directory missing; create it or remove the verify-status reference.

## ✅ Looks good
- Plugin reachable
- Settings file present
- No stale local hooks
- code-reviewer not duplicated locally
```

## When to run

- After `/harness-init`
- After `/plugin update` (to catch newly-shadowed things)
- When something behaves unexpectedly and you want to rule out config drift
- Before opening a PR that touches `.claude/`
