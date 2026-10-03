# Install

The plugin is named **`code-harness`**; it ships from the **`claude-code-harness`**
marketplace (this repo). Until 0.6.x the plugin itself was also called
`claude-code-harness` — see [Migrating from `claude-code-harness`](#migrating-from-claude-code-harness-06x-and-earlier).

## In a new project

Four lines inside a Claude Code session at the project root:

```
/plugin marketplace add git@github.com:petrpus/claude-code-harness.git
/plugin install code-harness@claude-code-harness
/code-harness:harness-init
/code-harness:harness-doctor
```

What each does:

| Step | Effect |
|---|---|
| `marketplace add` | Registers this repo as a plugin source (the marketplace is named `claude-code-harness`) |
| `install` | Installs skills, agents, hooks globally for your user |
| `/code-harness:harness-init` | Bootstraps `.claude/settings.json` + `tmp/` in the current project |
| `/code-harness:harness-doctor` | Read-only sanity check; flags stale local files, missing config |

`harness-init`, `autopilot` and `deliver` are **user-invoked only**
(`disable-model-invocation`, ADR-0015): Claude will not start them on its own,
so type the slash command yourself.

After `/code-harness:harness-init` you'll typically want to:
- Add project-specific WebFetch domains, Read paths, allow patterns to `.claude/settings.json`
- Create `CLAUDE.md` at the repo root with project rules
- Run `/project-infra` to provision a verify command, CI, and a devcontainer
  (`autopilot` requires an objective verify command before it will run)
- (Optional) Add project-local hooks at `.claude/hooks/*.local.sh` for project-specific guards

**Note:** the guard hooks parse tool input with `jq` and fail open without it —
ensure `jq` is on `PATH` (`/harness-doctor` flags it if missing).

## Before the first `/deliver`

`/deliver` needs a little more than the rest of the harness: `gh` logged in
(`gh auth status`), `jq`, bash ≥ 4.2, `tmp/` in `.gitignore`, and the five
labels `map`, `prd`, `ready-for-agent`, `needs-human`, `needs-triage`
(`/harness-init` creates them). `tmux` is optional; it runs the launcher
detached. `/harness-doctor` checks tmux, the labels and the `tmp/` ignore. See `skills/deliver/SKILL.md`.

## Updating

When the harness repo changes:

```
/plugin update code-harness@claude-code-harness
```

Updates are **per-project manual** — a push to the harness repo doesn't propagate until each project runs `/plugin update`. That's intentional: one project upgrading can't break another.

After updating, re-run `/harness-doctor` to catch any newly-shadowed local files.

## Uninstalling

```
/plugin uninstall code-harness@claude-code-harness
```

## Migrating from `claude-code-harness` (0.6.x and earlier)

0.7.0 renamed the plugin from `claude-code-harness` to `code-harness`, because
Claude Code reserves plugin names that start with `claude-` for Anthropic's own
plugins (`claude plugin validate` errors on them, and `claude plugin tag` refuses
them). The marketplace keeps its name, so `extraKnownMarketplaces` and the
`marketplace add` URL do not change. See ADR-0014.

- **Claude Code ≥ 2.1.193** migrates you automatically: the marketplace's
  `renames` map rewrites `claude-code-harness@claude-code-harness` to
  `code-harness@claude-code-harness` in `enabledPlugins` (user, project and local
  scopes). Because this marketplace is a git repository, the plugin then reports
  `not cached` until you run, once per machine:

  ```
  /plugin install code-harness@claude-code-harness
  ```

- **Older Claude Code** reports `Plugin "claude-code-harness" not found in
  marketplace`. Uninstall the old name and install the new one, or upgrade Claude
  Code first.
- **Managed settings** that enable the old key keep working but show the rename
  notice until an admin updates `enabledPlugins` there.
- **Skill and agent names change namespace**: `/claude-code-harness:deliver` is now
  `/code-harness:deliver`, and the agents are `code-harness:code-reviewer` and
  `code-harness:verifier`. Update any project docs, permission rules
  (`Skill(claude-code-harness:…)`) or scripts that spell the old namespace.
  `/code-harness:harness-doctor` flags leftovers of the old name.

## Cloud Claude Code

Plugin installs are per-user globally, so they apply to cloud sessions as long as you're signed in with the same account. The plugin is private; cloud will request access on first install.

## Migrating from the legacy setup

If you have the old `~/.agents/` install from Pocock's CLI:

```bash
rm -rf ~/.agents
rm -rf ~/.claude/skills      # dead symlinks if any
```

If a project already has `.claude/skills/`, `.claude/agents/code-reviewer.md`, or `.claude/hooks/*.sh` that the plugin now provides, **don't delete them blind** — run `/harness-doctor` first; it'll list exactly what's stale and shadow which plugin file.
