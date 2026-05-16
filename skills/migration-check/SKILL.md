---
name: migration-check
description: Safety check for a Prisma migration. Detects dangerous changes (data loss, breaking schema changes, indexes on huge tables) and proposes safer alternatives.
---

# Skill: /migration-check

Run **before** committing a Prisma migration. Finds dangerous changes and
suggests a safer path.

## Input

Optional path to a migration (defaults to the newest one in
`prisma/migrations/`).

## What it checks

### Category 1: Data loss

- Drop column → 🔴 BLOCKER (data loss)
- Drop table → 🔴 BLOCKER
- Type change (e.g. `VARCHAR(255)` → `INT`) → 🔴 BLOCKER (data conversion)
- Drop enum value that is in use → 🔴 BLOCKER

**Safer alternative:** two-phase migration.
1. Add new column, dual-write code change, backfill
2. Drop old column in a separate migration

### Category 2: Breaking changes

- Add NOT NULL without DEFAULT → 🟠 WARN (existing rows fail)
- Rename column → 🟠 WARN (breaks running code; suggest add new + dual write + drop old)
- Add UNIQUE constraint on a column with duplicates → 🔴 BLOCKER

### Category 3: Performance

- Add INDEX on a large table without `CONCURRENTLY` → 🟡 NOTICE
- Add FK constraint without `NOT VALID` + `VALIDATE CONSTRAINT` → 🟡 NOTICE (locks table)
- Add column with DEFAULT on a large table → 🟡 NOTICE (rewrites table)

### Category 4: Convention

- Migration filename doesn't match `<verb>_<subject>` → 🟡 NOTICE
  (`add_`, `drop_`, `rename_`, `alter_` — no "fix" in the name)
- Migration has no Prisma comment header → 🟡 NOTICE

## Output

Markdown report:

```markdown
# Migration check: 20260213_<name>.sql

## 🔴 Blockers (2)

- DROP COLUMN `customers.legacy_id`
  - Risk: data loss
  - Alternative: first mark as nullable, verify no `WHERE legacy_id IS NOT NULL`,
    then drop in a follow-up migration

## 🟠 Warnings (1)

- ADD COLUMN `cases.new_field NOT NULL`
  - Risk: existing rows fail
  - Alternative: first add as `NULL` + backfill script + `ALTER ... SET NOT NULL`
    in the next migration

## 🟡 Notices (0)

(none)
```

## Hook integration

A `PreToolUse` hook on Write/Edit into `prisma/migrations/` can invoke
`/migration-check` automatically. If there are 🔴 blockers, the hook blocks
the commit until the user resolves them.

## Anti-patterns

- **No "I know what I'm doing" override** — if there's a blocker, resolve it or
  rewrite the plan; don't go silent
- **No inline data backfill in the migration** — backfill is a separate script
  run before the `SET NOT NULL` migration
