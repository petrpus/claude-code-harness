# Handoff — claude-code-harness setup

## Where we are

This repo holds the universal Claude Code harness for code-dev projects.
Plan + decisions: `~/.claude/plans/ok-zd-se-mi-effervescent-truffle.md` (global path, visible from any session).

## What's done

- **Etapa 0**: verified Anthropic plugin manifest supports hooks (`hookify` plugin reference: `~/.claude/plugins/marketplaces/claude-plugins-official/plugins/hookify/`)
- **Etapa 1**: skeleton + manifest + README + architecture/install docs + pocock-sync-log + initial commit
- **Etapa 2**: 15 skills vendored (13 Pocock + find-skills + own /next) — see `docs/pocock-sync-log.md`
- **Etapa 3**: orchestration skills + code-reviewer ported and translated (commit-agent, implement-issue, start-feature, migration-check, agents/code-reviewer.md)
- **Etapa 4**: 5 hooks ported (`pre-edit` slimmed to .env + lockfiles only; `pre-bash` minus prisma-reset warn) + `hooks/hooks.json` wiring them under `${CLAUDE_PLUGIN_ROOT}`
- **Etapa 5**: `templates/project-settings.template.json` extracted (generic baseline, 101-specific WebFetch + Read paths + cursor-kit dropped)

All committed locally on `main`. **Not yet pushed.**

## What's next (resume here)

### Push to GitHub — needs user approval first
```
gh repo create petrpus/claude-code-harness --private --source=. --push --description "Universal Claude Code harness for code-dev projects (skills, agents, hooks, templates)."
```
Private under `petrpus`. Don't push without confirming with the user.

### Etapa 6 — migrate 101-intranet
**Gated**: don't start until current `feat/admin-sidebar-flatten` work in 101 is committed/merged. Confirm with the user before touching 101.

Then in a fresh branch `chore/harness-migration` in 101:
1. `/plugin marketplace add git@github.com:petrpus/claude-code-harness.git && /plugin install claude-code-harness`
2. `rm -rf 101/.claude/agents/`
3. `rm 101/.claude/skills/{commit-agent,implement-issue,start-feature,migration-check}/SKILL.md && rmdir those dirs`
4. `rm 101/.claude/hooks/{inject-git-context,on-stop,pre-bash,pre-commit-gate,post-edit}.sh`
5. Translate remaining 101 skills (build-client-html, port-from-agenius, regenerate-product-docs, spec-gap) to EN
6. Split 101 `pre-edit.sh` → keep only 101-specific guards (docs/product/ block, schema.prisma + docs/spec warns); rename to `pre-edit.local.sh`
7. Move prisma-migrate-reset warn into `pre-bash.local.sh`
8. Update 101 `.claude/settings.json`:
   - drop the migrated permission baseline (now from plugin template)
   - keep only 101-specific permissions (WebFetch domains, agenius Read, cursor-kit, docker edit)
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

## Notes for picking this up

- The orchestration skills (commit-agent, implement-issue, start-feature, migration-check) and the code-reviewer agent were translated from Czech to English while being made generic. 101-specific bits (entity names like `Reservation`/`Sale`, the `docs/product/` block) were removed; project-specific extensions are meant to live in `CLAUDE.md` or local hooks.
- `hooks/hooks.json` uses `${CLAUDE_PLUGIN_ROOT}` so paths resolve correctly when consumed via `/plugin install`. Don't change to `${CLAUDE_PROJECT_DIR}` — that's only correct when hooks live inside the project itself, which is the 101 baseline pre-migration.
- The vendor commit (`vendor: initial skill set …`) also accidentally included the 4 own-authored orchestration skills. Documented in the follow-up `feat:` commit body. Not a real problem; just don't re-vendor those.

## Files of interest

- `~/.agents/skills/` — original Pocock sources (kept until Etapa 7 cleanup)
- `~/.agents/.skill-lock.json` — original SHAs (will be removed in Etapa 7)
- `~/Code/101-intranet/.claude/{skills,agents,hooks,settings.json}` — 101 sources still in place
- `~/.claude/plugins/marketplaces/claude-plugins-official/plugins/hookify/hooks/hooks.json` — reference format for `hooks/hooks.json`

## Constraint

This task list is local to this work-tree. The plan file at `~/.claude/plans/ok-zd-se-mi-effervescent-truffle.md` is global. The 101 session (sidebar work) is unaffected — we only touch 101 in Etapa 6, and that's gated on sidebar work being done.
