---
name: project-infra
description: Provision and maintain a consumer project's Claude-session infrastructure and CI/CD — verify script, .env.example, GitHub Actions, devcontainer, branch protection. Modes via `/project-infra [audit|verify|env|ci|devcontainer|branch-protection|all]` (default audit). Triggers: "set up CI", "project has no verify command", "generate .env.example", "add a devcontainer", "protect the main branch".
---

# Skill: /project-infra

Provisions the infrastructure the harness (and `autopilot` in particular)
assumes a project already has: a machine-checkable verify command, a
`.env.example`, CI, and optionally a devcontainer + branch protection. Idempotent
where possible — re-running a mode should converge, not duplicate.

`autopilot` refuses to start without a verify command and tells users to run
`/project-infra verify` first — this skill is that interlock.

## Modes

`$ARGUMENTS` selects the mode; default is `audit`.

### audit (default, read-only)

Report what exists vs. missing. Never write anything.

1. `package.json` — read `scripts` for `verify`/`test`/`lint`/`typecheck`;
   read `dependencies`/`devDependencies` for `typescript`, `eslint`,
   `prettier`, `vitest`, `jest`.
2. `.env.example` present? Compare against live env usage (see **env** mode's
   grep recipes) to flag drift.
3. `.github/workflows/*.yml` present? Does any workflow run the verify script?
4. `.devcontainer/devcontainer.json` present?
5. `tmp/` dir present and gitignored (verify-status convention)?
6. Branch protection on `main` — can't be read without `gh api` write scope
   assumptions, so just note whether it looks configured (best-effort: `gh api
   repos/{owner}/{repo}/branches/main/protection` read-only call, tolerate 404).

Output a checklist (✅/❌ per item) and a proposed next-step list mapping
straight to the other modes, e.g. "No verify script → run `/project-infra
verify`".

### verify

Goal: an npm script named `verify` that chains typecheck + lint + test for
whatever's detected, plus a wrapper that records pass/fail for the hooks.

1. Detect package manager: `pnpm-lock.yaml` → pnpm, else `package-lock.json` /
   default → npm.
2. Detect stack from `package.json` deps and build a chain, e.g.:
   - `typescript` present → `tsc --noEmit`
   - `eslint` present → `eslint .`
   - `vitest` present → `vitest run`; else `jest` present → `jest`
   - Nothing detected → leave a `# TODO` placeholder chain and say so.
3. If `scripts.verify` is missing, add it as the underlying chain (e.g.
   `tsc --noEmit && eslint . && vitest run`) — this becomes `verify:inner`
   once the wrapper is installed (see step 4), or `verify` directly if you'd
   rather not wrap. Ask before overwriting an existing `verify` script.
4. Copy `verify-wrapper.template.sh` → `scripts/verify.sh` (`chmod +x`), and
   point `package.json`'s `verify` script at it:
   ```json
   "verify:inner": "tsc --noEmit && eslint . && vitest run",
   "verify": "bash scripts/verify.sh"
   ```
   The wrapper runs `verify:inner` (or whatever `$VERIFY_CMD` is set to),
   writes `ok`/`fail` to `tmp/.last-verify-status`, and exits with the
   underlying command's exit code.
5. `mkdir -p tmp` and ensure `tmp/` is gitignored.

Why: `hooks/inject-git-context.sh` and `on-stop.sh` read
`tmp/.last-verify-status`. Without this, those hooks silently report "never".
Installing the wrapper makes the harness's verify-freshness reminders
self-provisioning instead of a manual convention the project has to remember.

### env

Read-only scan + `.env.example` sync (never writes real values).

Grep recipes (adapt the glob to the project's source dirs):

```bash
grep -rhoE "process\.env\.[A-Z0-9_]+" --include='*.{ts,tsx,js,jsx,mjs,cjs}' src/ 2>/dev/null | sed 's/process\.env\.//' | sort -u
grep -rhoE "import\.meta\.env\.[A-Z0-9_]+" --include='*.{ts,tsx,js,jsx}' src/ 2>/dev/null | sed 's/import\.meta\.env\.//' | sort -u
grep -rhoE "os\.environ\[['\"][A-Z0-9_]+['\"]\]" --include='*.py' . 2>/dev/null | grep -oE "[A-Z0-9_]+" | sort -u
grep -rhoE "os\.getenv\(['\"][A-Z0-9_]+['\"]" --include='*.py' . 2>/dev/null | grep -oE "[A-Z0-9_]+" | sort -u
```

Union the results, drop obvious noise (`NODE_ENV`, `CI` — keep if unsure).
For each name, write a line to `.env.example`:

```
# <NAME> — used in <file:line where first seen>
<NAME>=
```

If `.env.example` already exists, keep existing entries/comments and only
append newly-discovered names (never remove — a name might be used in a
branch not currently scanned). Report any `.env.example` entries that no
longer appear in a live grep, as a note, not a deletion.

**Never** put a real value on the right-hand side — always empty or a
placeholder like `changeme`.

### ci

Instantiate `ci-workflow.template.yml` → `.github/workflows/ci.yml`. Ask
before overwriting an existing file. Swap `npm ci` / `npm run verify` for the
pnpm equivalents if pnpm was detected (see comments in the template).

### devcontainer

Instantiate `devcontainer.template.json` → `.devcontainer/devcontainer.json`.
This is for **Claude Code on the web** (or any devcontainer-based remote
environment) — pair it with the built-in `session-start-hook` skill to wire a
`SessionStart` hook so a fresh web session can immediately run tests/lint.

### branch-protection

Print (never execute) the `gh api` invocation from `BRANCH-PROTECTION.md`,
filled in with the repo's actual `{owner}/{repo}` (from `git remote get-url
origin`) and the workflow job name from the just-created (or existing)
`ci.yml`. Advice only — the user runs it themselves.

### all

Run **audit** first. Then, for each gap found, propose the corresponding mode
and ask once whether to apply all of them or pick individually. Never silently
apply — infra changes touch `package.json`, CI, and repo config, all of which
deserve a confirmation.

## Bundled files

- `verify-wrapper.template.sh` — the `scripts/verify.sh` wrapper installed by
  **verify**.
- `ci-workflow.template.yml` — the `.github/workflows/ci.yml` installed by
  **ci**.
- `devcontainer.template.json` — the `.devcontainer/devcontainer.json`
  installed by **devcontainer**.
- `BRANCH-PROTECTION.md` — the `gh api` recipe printed (never run) by
  **branch-protection**.

## When not to use

- On a project with a mature, already-working CI/verify setup — read what's
  there instead of overwriting it; prefer `audit` to confirm before touching
  anything.
- To actually change GitHub branch protection settings — this skill only
  prints the command; running it is a deliberate, separate decision by the
  user (it affects who can merge).
