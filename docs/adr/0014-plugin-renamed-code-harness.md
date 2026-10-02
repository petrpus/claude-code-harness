# The plugin is `code-harness`; the marketplace keeps `claude-code-harness`

Until 0.6.x the plugin and its self-marketplace were both named
`claude-code-harness`. Claude Code reserves plugin names that pass as one of
Anthropic's own: a name that starts with `claude-`, `anthropic-`, `anthropics-`
or `cc-plugin-` is an error, and `claude` as a whole word anywhere else is a
warning. On Claude Code 2.1.287, `claude plugin validate .` failed on
`plugins[0].name`, `claude plugin tag` refused to create the
`{name}--v{version}` tags that version-ranged plugin `dependencies` resolve
against, and `--strict` could not run in CI. Claude Code still loaded the
plugin — only the validator, `init` and `tag` check the name today (manifest
reference, § `name`) — but a documented "reserved" rule is not one to build on.
Another public plugin also ships under the name `claude-code-harness`.

## Decision

1. **The plugin is named `code-harness`.** It names what the plugin is, has no
   `claude` word, and keeps components short to type
   (`/code-harness:deliver`, agent `code-harness:verifier`).
2. **The marketplace keeps the name `claude-code-harness`**, and so does the
   repository. The validator accepts the marketplace name, and keeping it
   leaves every `marketplace add` URL and `extraKnownMarketplaces` entry
   working; only the half of the plugin id before `@` changes.
3. **The rename goes through the marketplace's `renames` map**
   (`"claude-code-harness": "code-harness"`). Claude Code ≥ 2.1.193 then
   rewrites `enabledPlugins` / `pluginConfigs` keys in the user, project and
   local scopes; a git-hosted marketplace additionally needs one
   `/plugin install code-harness@claude-code-harness` per machine. The map is
   **append-only history**: a future rename adds an entry, it never edits this
   one.
4. **`claude plugin validate --strict` is part of the harness's own verify.**
   `scripts/check-consistency.sh` runs it when the `claude` CLI is on `PATH`;
   CI runs it through `npx`, so a new platform rule fails a PR instead of a
   user's install.
5. **The contributor `CLAUDE.md` moves to `.claude/CLAUDE.md`.** The plugin root
   is the repo root (`"source": "./"`); Claude Code never loads a `CLAUDE.md` at
   a plugin root as context and the validator warns about one, which `--strict`
   turns into a failure. `.claude/CLAUDE.md` is an equivalent project-memory
   location for people working on this repo.

## Consequences

- Breaking for users: `/claude-code-harness:<skill>` becomes
  `/code-harness:<skill>`, and permission rules or docs that spell the old
  namespace stop matching. `harness-doctor` flags old ids and namespace
  strings; `docs/install.md` carries the migration steps. Claude Code older
  than 2.1.193 reports the old id as not found until it is reinstalled.
- `claude plugin tag` works from now on, which unblocks version-ranged
  `dependencies` for a separate design-harness plugin (#12).
- State that is not keyed by the plugin name keeps its name: `/deliver`'s
  runner snapshot under `${XDG_STATE_HOME}/claude-code-harness/` is unchanged,
  so runs started on 0.6.x resume after the upgrade.
- Historical documents (CHANGELOG entries, PRDs, earlier ADRs) keep the old
  name; they describe the past.
