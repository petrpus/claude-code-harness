# Install

## Primary: Anthropic plugin (recommended)

In any code-dev project (your repo root):

```bash
# Inside a Claude Code session:
/plugin marketplace add github:petrpus/claude-code-harness
/plugin install claude-code-harness
```

That installs the plugin globally per-user. Skills, agent, and hooks become available in **every** project automatically.

To update:

```bash
/plugin update claude-code-harness
```

To uninstall:

```bash
/plugin uninstall claude-code-harness
```

## Per-project setup (one-time, per repo)

After installing the plugin, do this once per project where you want full functionality:

### 1. Bootstrap baseline permissions

The plugin doesn't ship `settings.json` (Claude Code doesn't let plugins write to projects). Copy the template:

```bash
cp ~/.claude/plugins/claude-code-harness/templates/project-settings.template.json \
   your-project/.claude/settings.json
```

…or manually merge it into your existing `your-project/.claude/settings.json`. Adjust:

- WebFetch domains (defaults are generic — add your scrapers/docs)
- File globs for Edit/Write (defaults: `app/**`, `tests/**`, `prisma/**`, etc.)
- Project-specific hooks (the template only wires the plugin's hooks; add your own `pre-edit.local.sh` etc. if needed)

### 2. (Optional) Add project-specific hook wrappers

If your project has domain-specific guards (e.g. block edits to auto-generated docs), create:

```
your-project/.claude/hooks/pre-edit.local.sh
your-project/.claude/hooks/pre-bash.local.sh
```

…and register them in `your-project/.claude/settings.json` **alongside** the plugin hooks (both fire — they don't conflict).

### 3. Initialize verify status file

If your project uses `npm run verify` / `pnpm verify`:

```bash
mkdir -p tmp
echo "ok" > tmp/.last-verify-status
```

(Your verify script should write `ok` or `fail` to this file on completion. The hooks `inject-git-context`, `on-stop`, and `pre-commit-gate` read it.)

## Cloud Claude Code

Plugin installs are per-user globally, so they apply to cloud sessions too — as long as you're signed in with the same account. The plugin is private; cloud will request access to your private repos on first install.

## Removing the legacy `~/.agents/` setup

If you're migrating from Matt Pocock's CLI install:

```bash
rm -rf ~/.agents
rm -rf ~/.claude/skills      # dead symlinks
```

The plugin replaces what was there.
