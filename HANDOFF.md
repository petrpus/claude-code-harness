# Handoff — claude-code-harness setup

## Where we are

This repo holds the universal Claude Code harness for code-dev projects.
Plan + decisions: `~/.claude/plans/ok-zd-se-mi-effervescent-truffle.md` (global path, visible from any session).

## What's done

- Etapa 0: ✅ verified Anthropic plugin manifest supports hooks (see `hookify` plugin in `~/.claude/plugins/marketplaces/claude-plugins-official/plugins/hookify/`)
- Etapa 1 partial:
  - dir skeleton (`.claude-plugin/`, `skills/`, `agents/`, `hooks/`, `templates/`, `scripts/`, `docs/`)
  - `.claude-plugin/plugin.json` — manifest
  - `README.md` — install + what's inside
  - `docs/architecture.md` — 3-layer model + conventions
  - `docs/install.md` — install steps + per-project bootstrap
  - `.gitignore`

## What's next (resume here)

### Etapa 1 — finish
- [ ] `docs/pocock-sync-log.md` (starter table — SHAs from `~/.agents/.skill-lock.json`)
- [ ] `git init` (this dir) + first commit
- [ ] `gh repo create petrpus/claude-code-harness --private --source=. --push`

### Etapa 2 — vendor Pocock + Vercel + `next` (file copies, no translation)
Source: `~/.agents/skills/<name>/SKILL.md`
Target: `~/Code/claude-code-harness/skills/<name>/SKILL.md`

Copy these verbatim (already EN):
- caveman, diagnose, grill-me, grill-with-docs, handoff, improve-codebase-architecture, prototype, tdd, to-issues, to-prd, triage, write-a-skill, zoom-out (Pocock)
- find-skills (Vercel Labs)
- next (own, already EN)

**Skip**: `setup-matt-pocock-skills` — we baked conventions into `docs/architecture.md`.

Record SHAs in `docs/pocock-sync-log.md`: read `~/.agents/.skill-lock.json` for `skillFolderHash` per skill.

### Etapa 3 — port + translate orchestration skills (CZ → EN)
Source: `~/Code/101-intranet/.claude/skills/<name>/SKILL.md`
Target: `~/Code/claude-code-harness/skills/<name>/SKILL.md`

Translate to English while copying:
- `commit-agent` — strip cursor-kit references (keep the gate logic generic)
- `implement-issue` — wraps Pocock `/tdd` + code-reviewer agent + verify + PR
- `start-feature` — wraps Pocock `/grill-with-docs` + `/to-prd` + `/to-issues`
- `migration-check` — Prisma-generic migration safety check

Also port agent:
- `~/Code/101-intranet/.claude/agents/code-reviewer.md` → `~/Code/claude-code-harness/agents/code-reviewer.md` (translate to EN)

### Etapa 4 — port hooks (split generic vs 101-specific)
Source: `~/Code/101-intranet/.claude/hooks/`

Copy 1:1 to `~/Code/claude-code-harness/hooks/` (these are already generic):
- inject-git-context.sh
- on-stop.sh
- pre-commit-gate.sh

Adapt while copying:
- `pre-bash.sh` — drop the prisma-migrate-reset warn (101-specific). Keep push-from-main block, force-push block, rm -rf guards, global-npm warn.
- `pre-edit.sh` — keep only `.env*` block + lockfile block. Drop the `docs/product/` block and `docs/spec/`/`schema.prisma` warns (those become 101 `pre-edit.local.sh`).

Skip:
- `post-edit.sh` (0 bytes, dead)

Then write `hooks/hooks.json` registering all five hooks with `${CLAUDE_PLUGIN_ROOT}/hooks/<file>.sh` paths. Reference format: `~/.claude/plugins/marketplaces/claude-plugins-official/plugins/hookify/hooks/hooks.json`.

### Etapa 5 — settings template
Extract generic patterns from `~/Code/101-intranet/.claude/settings.json` into `templates/project-settings.template.json`:

**Allow** (keep):
- git operations (status/diff/log/branch/checkout/add/commit/fetch/pull/push/rebase/stash)
- pnpm:*, npm run:*, npx:*, node:*, tsx:*
- gh pr:*, gh issue:*, gh api:*, gh repo:*
- docker:*, docker compose:*
- prisma:*, playwright:*, vitest:*
- Edit/Write on common dirs: app/, tests/, scripts/, prisma/, public/, .claude/, .github/, *.config.*
- WebSearch
- WebFetch on common docs: github.com, raw.githubusercontent.com, reactrouter.com, prisma.io, tailwindcss.com, ui.shadcn.com

**Drop** (101-specific):
- WebFetch domains: 101auto/tipcars/sauto/mobile.de/etc scrapers, ares.gov.cz, gocardless, cebia, dataovozidlech
- `Read(//home/petrpus/Code/agenius-intranet/**)`
- `Bash(cursor-kit:*)`
- `Edit(docker/**)` (this is 101-internal infra)

**Deny** (keep):
- force-push, hard reset, clean -f, rm -rf /, rm -rf .git
- Write/Edit on `.env`

Don't add `Write/Edit(docs/product/**)` deny — that's 101-specific.

### Etapa 6 — migrate 101-intranet
**Important: DO NOT START until current sidebar work (`feat/admin-sidebar-flatten`) is committed/merged.**

Then in a fresh branch `chore/harness-migration` in 101:
1. `/plugin marketplace add github:petrpus/claude-code-harness && /plugin install claude-code-harness`
2. `rm -rf 101/.claude/agents/`
3. `rm 101/.claude/skills/{commit-agent,implement-issue,start-feature,migration-check}/SKILL.md && rmdir those dirs`
4. `rm 101/.claude/hooks/{inject-git-context,on-stop,pre-bash,pre-commit-gate,post-edit}.sh`
5. Translate remaining 101 skills (build-client-html, port-from-agenius, regenerate-product-docs, spec-gap) to EN
6. Split 101 `pre-edit.sh` → leave only 101-specific guards; rename to `pre-edit.local.sh`
7. Move prisma-migrate-reset warn into `pre-bash.local.sh`
8. Update 101 `.claude/settings.json`:
   - drop the migrated permission baseline (now from plugin template)
   - keep only 101-specific permissions (WebFetch domains, app/tests/etc globs already there)
   - rewire hooks: drop the migrated ones (plugin handles them), keep just `pre-edit.local.sh` and `pre-bash.local.sh`
9. Smoke test: new chat in 101 → `/next`, `/implement-issue`, code-reviewer agent, hooks (push-from-main block, inject-git-context).
10. PR + merge.

### Etapa 7 — cleanup global
After 101 migration verified:
```bash
rm -rf ~/.agents/
rm ~/.claude/skills/*    # dead symlinks
```

Keep `~/.claude/settings.json` as-is (3 lines, fine).

### Etapa 8 — adopt in other repos
Per repo (e.g. `agenius-intranet`):
1. `/plugin install claude-code-harness`
2. Copy `templates/project-settings.template.json` to `.claude/settings.json` + project tweaks.

## Files of interest

- `~/.agents/skills/` — source for Etapa 2 vendoring
- `~/.agents/.skill-lock.json` — SHAs for `docs/pocock-sync-log.md`
- `~/Code/101-intranet/.claude/skills/{commit-agent,implement-issue,start-feature,migration-check}/SKILL.md` — source for Etapa 3 (translate CZ → EN)
- `~/Code/101-intranet/.claude/agents/code-reviewer.md` — source for Etapa 3 (translate CZ → EN)
- `~/Code/101-intranet/.claude/hooks/*.sh` — source for Etapa 4 (split)
- `~/Code/101-intranet/.claude/settings.json` — source for Etapa 5 (extract generic baseline)
- `~/.claude/plugins/marketplaces/claude-plugins-official/plugins/hookify/hooks/hooks.json` — reference format for our `hooks/hooks.json`

## Constraint

This task list is local to this work-tree. The plan file at `~/.claude/plans/ok-zd-se-mi-effervescent-truffle.md` is global. The 101 session (sidebar work) is unaffected — we only touch 101 in Etapa 6, and that's gated on sidebar work being done.
