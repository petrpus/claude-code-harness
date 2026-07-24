# PRD 0001 — Harness upgrade to 0.3.0 (vendor re-sync, verify gate, doctrine) + 0.4.x map

Status: **approved** · Date: 2026-07-24 · Analysis: [docs/research/2026-07-harness-upgrade.md](../research/2026-07-harness-upgrade.md)
ADRs: [0001](../adr/0001-repo-map-as-file-not-mcp.md) · [0002](../adr/0002-opt-in-stop-gate-exception.md) · [0003](../adr/0003-ui-skills-live-in-design-harness.md)
Glossary: [CONTEXT.md](../../CONTEXT.md) — this PRD uses its terms (Slice, Blocking edge, Verify gate, Local patch, …).

## Goal

Bring the harness up to date with upstream skill improvements and mid-2026
agentic best practices. The S-slices (S0–S6) run **autonomously in a cloud
session**; the M-slices are captured on the tracker with `needs-grill` and
will be planned interactively later.

## Autonomy contract (binding for the cloud session)

1. One Slice = one issue = one branch (`feat/`- or `vendor/`-prefixed) = one PR.
2. A slice may start only when all its Blocking edges are merged.
3. Gate before every PR: `scripts/verify.sh` must pass (after S0 lands; S0
   itself is gated by `scripts/check-consistency.sh` + the hook test matrix).
4. The agent merges its own PR when the gate is green and the PR contains only
   the slice's scope. **Exception: S6 (release) is HITL** — open the PR, do
   not merge; the human merges and tags.
5. Every slice updates the docs it touches **including the published HTML**
   (`docs/guide.html`, `docs/index.html` — served by GitHub Pages from
   `main:/docs`) when it changes user-facing behavior.
6. Commit messages: English, conventional commits; vendor syncs use the
   sync-log commit convention (`vendor: re-sync … to <short-sha>`).
7. Never touch: `plugin.json` version and `CHANGELOG.md` top entry (S6 only),
   `tmp/` contents, anything in the Design lane (ADR-0003).

## Slice map

| Slice | Title | Blocked by | Label | Target |
|---|---|---|---|---|
| S0 | `scripts/verify.sh` — the harness's own Verify | — | ready-for-agent | 0.3.0 |
| S1 | Vendor re-sync: pocock → `ed37663`, vercel → `e173b8c` | S0 | ready-for-agent | 0.3.0 |
| S2 | implement-issue: adopt upstream test cadence | S0 | ready-for-agent | 0.3.0 |
| S3 | U1 — `require-verify-before-stop` template (ADR-0002) | S0 | ready-for-agent | 0.3.0 |
| S4 | U2 — official doctrine into write-a-skill + architecture.md | S0 | ready-for-agent | 0.3.0 |
| S5 | Docs refresh: guide.html, index.html, README for 0.3.0 | S1, S2, S3, S4 | ready-for-agent | 0.3.0 |
| S6 | Release 0.3.0 — bump, CHANGELOG, tag (**HITL**) | S5 | needs-grill* | 0.3.0 |
| M1 | Grill + design the repo-map layer (U3, ADR-0001) | S6 | needs-grill | 0.4.x |
| M2 | Implement repo-map.json + `repo-map` skill | M1 | needs-grill | 0.4.x |
| M3 | Autopilot tune-up (U4): metrics, per-iteration spec, gate/map wiring | M2 | needs-grill | 0.4.x |
| M4 | Add design-harness entry to marketplace.json | external: repo exists | needs-grill | 0.4.x |

\* S6 carries `needs-grill` semantics operationally (agent stops at PR); it is
listed here so the run has an explicit finish line.

## Slice specifications

### S0 — `scripts/verify.sh`

The harness demands a Verify command from consumer projects but has none
itself. Create `scripts/verify.sh`:

- Runs, in order: `scripts/check-consistency.sh`; the hook test matrix — for
  each guard hook, feed representative stdin-JSON cases and assert exit codes
  (block cases exit 2, allow cases exit 0); `bash -n` over `hooks/*.sh`,
  `scripts/*.sh`, `skills/**/*.sh` (check-consistency already covers most —
  do not duplicate, just ensure full coverage).
- Hook matrix cases minimum: pre-bash blocks `git push` on main, force-push,
  broad `rm -rf`, and allows a plain `ls`; segment-split catches
  `cd x && git push --force`; pre-edit blocks `.env` and lockfiles, allows
  `.env.example`. Follow `docs/architecture.md` § Hook contract (stdin JSON,
  exit 2; hooks fail open without jq).
- Writes `tmp/.last-verify-status` in the format the freshness hooks read
  (see `hooks/pre-commit-gate.sh` / `hooks/on-stop.sh` for the expected
  format; keep compatible).
- Exit non-zero on any failure. No network. Runnable from repo root.
- DoD: `scripts/verify.sh` green; `docs/architecture.md` gains a short
  "Verifying the harness itself" note; on-stop/pre-commit-gate freshness
  warnings stop firing after a green run.

### S1 — Vendor re-sync (bulk, one PR)

Per `docs/pocock-sync-log.md` procedure. Upstream SHAs are pinned:
mattpocock/skills @ `ed37663cc5fbef691ddfecd080dff42f7e7e350d`,
vercel-labs/skills @ `e173b8c88f2581cfdaa1b6767c6519a08155790e`. GitHub
API/codeload are proxy-blocked — fetch per-file from
`raw.githubusercontent.com/<owner>/<repo>/<sha>/<path>` (sleep/retry on 429).

1. **`skills/to-issues/` ← upstream `skills/engineering/to-tickets/`**:
   adopt content — blocking edges per ticket, slices sized to one context
   window, prefactoring-first, expand–contract sequencing for wide refactors
   (incl. integration-branch variant), drop HITL/AFK typing. Keep dir and
   frontmatter name `to-issues` (Local patch). Keep our tracker wording
   (GitHub Issues via `gh`). Evaluate upstream `disable-model-invocation:
   true` — adopt only if it doesn't break `/next` and `start-feature` flows
   that invoke it programmatically; record the choice in the sync-log row.
2. **`skills/to-prd/` ← upstream `skills/engineering/to-spec/`**: adopt
   seams-first step (prefer existing seams, highest possible, "ideal is
   one"), keep PRD terminology and name `to-prd` (Local patch); same
   `disable-model-invocation` evaluation.
3. **Vendor `skills/resolving-merge-conflicts/`** from upstream as-is (14
   lines, no resources). New sync-log row.
4. **`skills/find-skills/`**: sync `--owner` flag + removed `check` mention
   from vercel-labs @ `e173b8c`.
5. **Sync-log update**: bump Last-reviewed/SHA on all pocock rows to
   `ed37663` (bulk), update wayfinder note (graduated from in-progress; still
   skipped: depends on upstream tracker-doc infra + overlaps our
   to-prd/to-issues/triage flow), add batch-grill-me to the watch note, add
   the two rename local patches and the new vendor row.
- Commit: `vendor: re-sync pocock skills to ed37663` (+ separate small
  commit for vercel). DoD: verify.sh green (check-consistency walks skills
  and sync-log rows both directions — the new skill needs its row).

### S2 — implement-issue test cadence

Do NOT vendor upstream `implement`. Into `skills/implement-issue/SKILL.md`'s
BUILD phase, weave the cadence: *typecheck continuously, run single test
files continuously, run the full suite once at the end* (before the reviewer
agent + verify gate steps, which stay). Keep the skill's existing structure
and tone. DoD: verify.sh green; no other skill references break.

### S3 — `require-verify-before-stop` template (U1, ADR-0002)

- New `templates/require-verify-before-stop.sh`: Stop hook reading stdin
  JSON (use the same jq pattern as `hooks/lib.sh`; fail open without jq),
  exits 2 with a one-line reason while `tmp/.last-verify-status` is missing,
  stale, or failing; exits 0 otherwise. Never wired into `hooks/hooks.json`
  (ADR-0002).
- Document in `templates/project-settings.template.json` vicinity + a short
  section in `docs/architecture.md` ("Verification tiers: reminders by
  default, opt-in gate for unattended runs").
- Extend `skills/autopilot/SKILL.md`: autopilot MAY enable this gate for its
  run and MUST remove it on run end.
- DoD: verify.sh green; template passes the same stdin-JSON matrix style
  (block when stale, allow when fresh); ADR-0002 referenced from both docs.

### S4 — doctrine into write-a-skill + architecture.md (U2)

- `skills/write-a-skill/`: add checklist items — SKILL.md body < 500 lines;
  reference files exactly one level deep from SKILL.md (no nested chains);
  TOC inside long reference files; description in third person stating what
  + when; gerund naming preference (respect existing local names).
- `docs/architecture.md`: new short section on decomposition doctrine —
  single agent by default; subagents only for context protection /
  parallelization / specialization; decompose by context, not by problem
  phase; verification subagent (our `verifier`) called out as the sanctioned
  pattern. Cite the official sources from the research doc.
- DoD: verify.sh green; no contradiction with existing docs (grep for
  conflicting guidance).

### S5 — docs refresh

Update `docs/guide.html` + `docs/index.html` (GitHub Pages) and `README.md`
to reflect: new skill `resolving-merge-conflicts`, verify.sh, the opt-in
stop gate, updated to-issues/to-prd capabilities. Keep both HTML files
self-contained/offline. DoD: verify.sh green; no external resources in the
HTML (grep `src=|<link|@import|url(http`).

### S6 — release 0.3.0 (HITL)

Bump `plugin.json` to 0.3.0, add CHANGELOG entry summarizing S0–S5, update
`.claude-plugin/marketplace.json` if it pins a version. Open the PR and
STOP — the human merges and tags `v0.3.0` on the merge commit on main.

### M-slices (outline only — each starts with a grill)

- **M1/M2 — repo-map layer** (ADR-0001): second output of code-map,
  `tmp/repo-map.json` (modules, edges, in/out degree, entry points) + a
  `repo-map` query skill; autopilot loads it at iteration start. Schema
  design, staleness policy, and query surface are M1 grill topics.
- **M3 — autopilot tune-up**: per-iteration spec files
  (`tmp/autopilot/iteration-N.md`), run-log metrics
  (tool-calls-before-first-edit, verify-fail rate), optional wiring of the
  S3 gate and the M2 map.
- **M4 — marketplace entry for design-harness**: one JSON entry, blocked on
  the design-harness repo existing (concept draft: `tmp/design-harness-koncept.md`,
  to be grilled in that repo).

## Out of scope

- Anything in the Design lane (ADR-0003) beyond the M4 marketplace entry.
- Watch-list items (Agent Teams, nested subagents, adaptive model selection,
  `/goal`) — unverified against official docs; do not build on them.
- Changing default hook behavior (reminders stay exit 0; ADR-0002).

## Risks

- Upstream `disable-model-invocation` flag may interact with our skills'
  programmatic invocation — S1 evaluates instead of blindly adopting.
- verify.sh freshness format must match what the existing hooks parse —
  S0 reads the hook source first, contract over assumption.
- Bulk sync-log edits are easy to get inconsistent — check-consistency
  enforces rows ↔ dirs both directions and runs inside verify.sh.
