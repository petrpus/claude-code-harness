---
name: commit-agent
description: Pre-commit policy gate. Invoke before any mutating git operation (commit, amend, rebase, merge, cherry-pick, reset that moves HEAD, push). Read-only git ops bypass this.
---

# Skill: /commit-agent

Pre-commit policy gate. **Always invoke before** any git operation that mutates
the index, `HEAD`, or remote (commit, amend, rebase, merge, cherry-pick, reset,
push).

Read-only ops (`status`, `diff`, `log`, `show`, `branch` listing) bypass this
skill.

## Inputs

- Current working tree state (`git status`)
- Staged + unstaged diffs (`git diff`, `git diff --cached`)
- Recent log (`git log -10 --oneline`)
- Active branch
- Most recent verify status (project-specific — e.g. `tmp/.last-verify-status`)
- Issue / PR being worked on (if any)

## What the skill does

### 1. Pre-flight checks

| Check | Action |
|---|---|
| Working tree empty | Skip — nothing to commit |
| On `main` / `master` | Block — must be feature branch |
| Verify is red (status != ok) | Block — fix root cause first |
| Verify is stale (>30 min) | Warn (don't block); recommend re-running verify |
| Mixed concerns (refactor + feature) | Warn; suggest separating |
| > 50 files changed | Warn; consider splitting |
| Includes `console.log` / `debugger` | Warn (lint should catch; double check) |
| Touches generated/derived files directly | Block — must regenerate via the proper skill |

### 2. Compose commit plan

Output a **commit plan**:

- **Boundaries**: which files go in which commit (if multi-commit needed)
- **Messages**: conventional commit prefix (feat / fix / docs / chore / refactor / test) + scope + concise summary
- **Body**: explains the WHY (not the WHAT — the diff covers WHAT)
- **Co-author trailer** if applicable

For each commit:

```
<type>(<scope>): <subject>

<body — why, not what>

Co-Authored-By: <author> <email>
```

### 3. Show plan to user

Present the commit plan with:
- Files in each commit
- Proposed message(s)
- Pre-flight findings (warns + blocks)

**Wait for explicit user approval** before executing in interactive mode.

In autonomous / cloud mode (when explicitly enabled), proceed per the runtime
policy.

### 4. Execute

Per the approved plan:

```bash
git add <files>
git commit -m "$(cat <<'EOF'
<message>
EOF
)"
```

Use HEREDOC for commit messages (no escaping needed).

### 5. Post-commit verify (optional)

If multiple commits, re-run verify between commits to catch regressions early.

## Anti-patterns

- **Skipping the plan-review step** — even for "obvious" commits
- **Bundling unrelated changes** — separate refactor and feature
- **Force pushing without explicit user reason** — never default; require justification
- **Editing commit messages "to be nice"** — keep them accurate
- **Pushing red verify** — verify must be green or explicit risk-accepted in PR description

## Mode dependency

This skill operates in two modes:

| Mode | Behavior |
|---|---|
| **Interactive** (default) | Prepare → wait for approval → execute |
| **Autonomous** (cloud) | Execute per runtime policy without waiting (when explicitly enabled) |

Default for any session started manually by the user is **interactive**.
