# Install

## In a new project

Four lines inside a Claude Code session at the project root:

```
/plugin marketplace add github:petrpus/claude-code-harness
/plugin install claude-code-harness
/harness-init
/harness-doctor
```

What each does:

| Step | Effect |
|---|---|
| `marketplace add` | Registers this repo as a plugin source |
| `install` | Installs skills, agents, hooks globally for your user |
| `/harness-init` | Bootstraps `.claude/settings.json` + `tmp/` in the current project |
| `/harness-doctor` | Read-only sanity check; flags stale local files, missing config |

After `/harness-init` you'll typically want to:
- Add project-specific WebFetch domains, Read paths, allow patterns to `.claude/settings.json`
- Create `CLAUDE.md` at the repo root with project rules
- (Optional) Add project-local hooks at `.claude/hooks/*.local.sh` for project-specific guards

## Updating

When the harness repo changes:

```
/plugin update claude-code-harness
```

Updates are **per-project manual** — a push to the harness repo doesn't propagate until each project runs `/plugin update`. That's intentional: one project upgrading can't break another.

After updating, re-run `/harness-doctor` to catch any newly-shadowed local files.

## Uninstalling

```
/plugin uninstall claude-code-harness
```

## Cloud Claude Code

Plugin installs are per-user globally, so they apply to cloud sessions as long as you're signed in with the same account. The plugin is private; cloud will request access on first install.

## Migrating from the legacy setup

If you have the old `~/.agents/` install from Pocock's CLI:

```bash
rm -rf ~/.agents
rm -rf ~/.claude/skills      # dead symlinks if any
```

If a project already has `.claude/skills/`, `.claude/agents/code-reviewer.md`, or `.claude/hooks/*.sh` that the plugin now provides, **don't delete them blind** — run `/harness-doctor` first; it'll list exactly what's stale and shadow which plugin file.
