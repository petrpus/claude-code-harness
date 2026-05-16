# Vendor sync log

Skills vendored from external sources. We do **not** automate sync — when something
upstream changes that we want, we cherry-pick the new `SKILL.md` by hand and update
this table.

Procedure:
1. Open the source repo at the new commit.
2. Diff `SKILL.md` (and any bundled `resources/`) against our vendored copy.
3. Copy what we want, update the row below: new SHA, new sync date, note what changed.
4. Commit with message `vendor: sync <skill> from <short-sha>`.

## Pocock (`mattpocock/skills`)

| Skill | Upstream path | Vendored SHA | First vendored | Last synced | Notes |
|---|---|---|---|---|---|
| caveman | `skills/productivity/caveman/SKILL.md` | `17972a1` | 2026-05-16 | 2026-05-16 | initial vendor |
| diagnose | `skills/engineering/diagnose/SKILL.md` | `43d464d` | 2026-05-16 | 2026-05-16 | initial vendor |
| grill-me | `skills/productivity/grill-me/SKILL.md` | `2a1ad17` | 2026-05-16 | 2026-05-16 | initial vendor |
| grill-with-docs | `skills/engineering/grill-with-docs/SKILL.md` | `3c4ac97` | 2026-05-16 | 2026-05-16 | initial vendor |
| handoff | `skills/productivity/handoff/SKILL.md` | `85c644d` | 2026-05-16 | 2026-05-16 | initial vendor |
| improve-codebase-architecture | `skills/engineering/improve-codebase-architecture/SKILL.md` | `3ad8fa7` | 2026-05-16 | 2026-05-16 | initial vendor |
| prototype | `skills/engineering/prototype/SKILL.md` | `c91bdc5` | 2026-05-16 | 2026-05-16 | initial vendor |
| tdd | `skills/engineering/tdd/SKILL.md` | `75beb30` | 2026-05-16 | 2026-05-16 | initial vendor |
| to-issues | `skills/engineering/to-issues/SKILL.md` | `b38c5aa` | 2026-05-16 | 2026-05-16 | initial vendor |
| to-prd | `skills/engineering/to-prd/SKILL.md` | `d6eff3e` | 2026-05-16 | 2026-05-16 | initial vendor |
| triage | `skills/engineering/triage/SKILL.md` | `de4f182` | 2026-05-16 | 2026-05-16 | initial vendor |
| write-a-skill | `skills/productivity/write-a-skill/SKILL.md` | `2f252b3` | 2026-05-16 | 2026-05-16 | initial vendor |
| zoom-out | `skills/engineering/zoom-out/SKILL.md` | `6ecebab` | 2026-05-16 | 2026-05-16 | initial vendor |

**Skipped intentionally**: `setup-matt-pocock-skills`. The conventions it bootstraps
(GitHub Issues + `CLAUDE.md` + `docs/adr/`) are documented directly in
`docs/architecture.md`.

## Vercel Labs (`vercel-labs/skills`)

| Skill | Upstream path | Vendored SHA | First vendored | Last synced | Notes |
|---|---|---|---|---|---|
| find-skills | `skills/find-skills/SKILL.md` | `3013fde` | 2026-05-16 | 2026-05-16 | initial vendor |

## Own (no external source)

Authored in this repo, no upstream. Track changes via git history; not listed
in the sync table.

- `skills/next/`
- `skills/commit-agent/`
- `skills/implement-issue/`
- `skills/start-feature/`
- `skills/migration-check/`
- `skills/harness-init/`
- `skills/harness-doctor/`
- `agents/code-reviewer.md`
- `hooks/*.sh` + `hooks/hooks.json`
