# PRD 0003 — `/deliver`: a Map of issues to merged PRs, one command (0.6.0)

Status: **grilled — issues cut** (see § Slice map) · Date: 2026-09-27
ADRs: **new: [0007](../adr/0007-runner-may-merge-model-may-not.md) (runner may merge, model may not — supersedes PRD 0002 contract item 4), [0008](../adr/0008-map-issue-is-the-delivery-contract.md) (Map issue format)** · builds on [0005](../adr/0005-plan-dag-in-implementation-plan.md) (plan grammar reused for the issue graph)
Glossary: [CONTEXT.md](../../CONTEXT.md). This PRD splits **Slice** (a plan item inside one autopilot run) from **Issue** (one branch, one PR) and adds **Map**, **Delivery run**, **Integration branch**, **Review round**, **Follow-up** and **Parked issue**.

## Background

The workflow that works in practice, done by hand with this harness's skills:

1. Interactive: `/grill-with-docs` → `/to-prd` → `/to-issues`.
2. For a defined set of issues (ideally listed in a separate map issue), per
   issue: branch off the current branch → implement → verify → PR against the
   current branch → independent review → fixes and follow-up issues → verify →
   merge → next issue.

Step 2 has no automation, and the pieces that exist disagree with it:

- `autopilot` (`loop.sh`) runs one branch with no `gh` (PRD 0002, by design).
  Its state dir is hardcoded to `tmp/autopilot/`, so it cannot run once per issue.
- `implement-issue` stops for plan approval, assumes `--base=main`, reviews
  before committing, calls `gh pr create` without `--base`, and never merges.
- `code-reviewer` diffs `main..<branch>`, returns Markdown only, and has mutated
  the live working tree (#52).
- Nothing creates or reads a map issue, nothing walks the issue graph, and the
  labels disagree (`implement-issue` wants `ready`, `to-issues` sets
  `ready-for-agent`, `to-prd` labels the PRD `ready-for-agent` too).

## Goal

`/deliver #<map>` delivers every issue in a Map as its own reviewed, verified,
squash-merged PR into an integration branch, in dependency order, unattended,
with hard caps. A human then merges one integration → main PR.

## Decisions (grill, 2026-09-27)

1. **Architecture: a deterministic bash runner over `loop.sh`.**
   `skills/deliver/deliver.sh` owns the issue graph, branches and every `gh`
   call. For each issue it runs the existing `loop.sh` as the inner engine, with
   the issue as charter. The model never holds `gh` (ADR-0007).
2. **Merge base: the current branch, never `main`/`master` without
   `--allow-main`.** On `main` the skill offers `--create-integration`
   (`integration/<map-slug>`). At the end the runner opens the integration →
   default PR with the `Closes` list; a human merges it.
3. **Follow-ups are filed, not executed.** Out-of-scope review findings become
   `needs-triage` issues listed under the Map's `## Follow-ups`.
4. **Launch: `/deliver #<map>` → detached `tmux` → Monitor.** Read-only
   pre-flight, a run plan, one confirmation, then `tmux new-session -d -s
   deliver-<map>`. The session reports milestones. `/deliver --status`,
   `/deliver --stop` and `/deliver #<map> --resume` work from any session. The
   runner also runs from a terminal: `deliver.sh --map <N> --yes`.
5. **Per-issue planning stays on opus.** Every issue gets loop.sh's normal PLAN
   phase on `--plan-model opus`. Cost is shown in the run plan, not optimised
   away.
6. **Name: `/deliver`.** A new own skill, not a mode of `/autopilot`.
7. **Bootstrap: D0a and D1 are built interactively** on `integration/deliver`,
   one PR per issue, following the manual workflow. After that the runner
   delivers the rest of this Map (§ Execution model).

## Design

### Two levels, one engine

| Level | Graph | Unit | Owner | Branches / forge |
|---|---|---|---|---|
| Delivery run | Map `## Delivery` (issue refs) | Issue | `deliver.sh` | one branch + PR per issue, squash merge into the integration branch |
| Autopilot run | `IMPLEMENTATION_PLAN.md` (plan-local ids) | Slice | `loop.sh` | checkpoint commits on the issue branch, no forge |

Both graphs use the `plan.sh` grammar, so `select_next_slice()` schedules
issues as well as slices (ADR-0008).

New files in `skills/deliver/`:

| File | Responsibility |
|---|---|
| `SKILL.md` | `/deliver`: pre-flight via `deliver.sh --plan-only --json`, run plan + cost estimate, one confirmation, tmux launch, Monitor, `--status` / `--stop` / `--resume`. No orchestration logic. |
| `deliver.sh` | Runner: args, preconditions, private runner copy, per-issue state machine, global caps, lock, STOP file. The only caller of `forge.sh`. |
| `map.sh` | Pure: extract `## Delivery` to plan grammar, tick one line, append a follow-up, validate a conventional title, rewrite external refs. |
| `charter.sh` | Pure: issue JSON + Map → `PROMPT.md` per `PROMPT.template.md` (the other Map issues listed as out of scope). |
| `forge.sh` | Every `gh` call. The surface the fake `gh` in tests emulates. |
| `review.sh` | Throwaway review worktree, reviewer prompt, verdict parsing, post-review assertions. |
| `state.sh` | Atomic `state.json`, `events.jsonl`, `status.json`, cost sums. |
| `MAP-FORMAT.md` | The Map contract (ADR-0008), referenced by `/to-issues` and `/start-feature`. |

Shared extraction: `skills/autopilot/agent.sh` — the model-call core of
`run_claude()` (`agent_run <phase> <model> <allowed> <perm> <prompt> [cwd]`).
`loop.sh` and `deliver.sh` both call it; #42 later swaps the backend there.

**Private runner copy.** At start `deliver.sh` copies `skills/`, `agents/` and
`.claude-plugin/plugin.json` to
`${XDG_STATE_HOME:-~/.local/state}/claude-code-harness/deliver/<run-id>/runner/`
and re-execs from there. BUILD can therefore never edit the script bash is
reading, even when the harness is developed with `--plugin-dir .`. R1
self-reload never fires under `/deliver`; runner changes take effect on the
next `--resume`, which makes a fresh copy.

### `loop.sh` seams (backward compatible)

- `--state-dir <dir>` (default `tmp/autopilot`); derived paths move below the
  argument parser.
- `--stop-file <path>`, checked with the caps each iteration → state `stopped`,
  exit 6.
- Iteration gates see the whole iteration: record `ITER_BASE_SHA` before BUILD,
  `git add -A` before the gates, diff against `ITER_BASE_SHA`. BUILD loses
  `Bash(git add:*)` / `Bash(git commit:*)`. Today a BUILD commit blinds the
  secret scan and the verifier, and untracked files are never scanned.
- Resume fidelity: sum cost excluding `phase:"iteration"` rows (today counted
  twice); restore `START_EPOCH` from the run log (today the time cap resets).
- `detect_verify_cmd` in `allowlist.sh`: `package.json` (as today),
  `scripts/verify.sh`, a Makefile `verify:` target.

Exit 4 keeps covering budget cap and stuck; `deliver.sh` reads
`status.json .state` to tell them apart. Exit 5 stays reserved for #40.

### Per-issue state machine

```
pending → preparing → building → pr-open → reviewing(k) ⇄ fixing(k) → final-verify → merging → merged
                         │                        └───────── any failure below ─────────┐
                         └──────────────────────────────────────────────────────────────┴→ parked
skipped: a (transitive) blocker is parked         closed-externally: a human closed the issue
```

- **preparing:** fetch; assert clean tree on the integration branch;
  `git switch -c <type>/<N>-<slug> origin/<integration>`; write the charter.
- **building:** `loop.sh --state-dir tmp/deliver/<run>/issues/<N> --stop-file
  … --plan-model opus` with per-issue caps clipped to what the global caps have
  left. `done` → pr-open. `stuck` or a per-issue cap → parked. The global budget
  running out → the whole run stops `capped` and the issue stays resumable.
  Exit 1 → the run is `failed` (systemic precondition).
- **pr-open:** `git push -u origin <branch>` (never force), `gh pr create --base
  <integration> --body-file`, comment on the issue.
- **reviewing(k):** see § Review. In-scope blocker or issue with `k < rounds`
  (default 2) → fixing. Rounds exhausted, or no verdict twice → parked.
- **fixing(k):** append `R<k>.<j>` items to the issue's plan, re-open `STATUS`,
  run `loop.sh` again on the same state dir, push fast-forward, back to
  reviewing(k+1).
- **final-verify:** if the integration branch moved, `git merge --no-edit
  origin/<integration>` (conflict → abort, park), verify, push. Always run
  verify on the exact head in a clean tree. Wait for `gh pr checks` up to a
  timeout; no checks after a grace period means no CI. Red CI → one fixing round
  with the failed-log tail as the plan item, else park.
- **merging:** `gh pr merge --squash --delete-branch --match-head-commit <sha>
  --subject "<title> (#<pr>)"`. Fall back to `--merge` when the repo forbids
  squash. Refused merge → back to final-verify once, then park. Never `--admin`.
- **merged:** `git pull --ff-only`; delete the local branch the runner created;
  tick the Map line; comment on the issue.
- **parked:** label `needs-human`, drop `ready-for-agent`, comment with the inner
  state, cost and the last `FEEDBACK.md`, convert the PR to draft. Dependents
  become `skipped`; independent issues continue.

Between phases the runner checks the STOP file, the global caps, and that the
checkout is still clean and on the expected branch. A human touching the
checkout stops the run (`failed`); it is never auto-fixed.

**State:** `tmp/deliver/<run-id>/` — `state.json` (resume truth), `status.json`
(Monitor / `--status`), `events.jsonl`, `run-<id>.jsonl` (deliver's own model
calls, same schema as loop.sh so `/usage-report` reads it), `map.plan.md`,
`STOP`, `lock`, and `issues/<N>/` as the inner state dir plus review and PR
files. Pre-flight refuses if `tmp/` is not gitignored.

**Resume** reconciles every non-terminal issue with GitHub: ticked or PR
`MERGED` → merged; issue closed → closed-externally; `needs-human` → parked
(`--retry #N` starts a fresh inner run); an open PR → re-enter review at the
recorded round (review comments carry a `<!-- deliver:review issue=N round=k
head=<sha> -->` marker, so nothing is posted twice); a pushed branch without a PR
→ pr-open or building with `--resume-run`.

**Exit codes:** 0 all merged and final PR opened · 1 precondition / runner error ·
2 partial (something parked or skipped) · 3 time cap · 4 budget cap ·
6 stopped · 5 reserved (#40).

### Review

`agents/code-reviewer.md` changes:

- Takes `--base=<ref> --head=<ref>` and diffs `<base>...<head>`. The default base
  is the repo's default branch, never a literal `main`.
- New section **Working tree is read-only** (#52): no checkout / switch / branch
  creation / revert / restore / stash / reset, no writes under `tmp/`, no verify
  in the live tree. Experiments use `git worktree add "$(mktemp -d)" <ref>` or
  `git show <ref>:<path>`.
- Every finding carries `in_scope`: required by the charter or introduced by
  this diff. Anything else is out of scope.
- A mandatory final fenced JSON block:
  `{"verdict":"approve|changes_requested","findings":[{"id","severity":"blocker|issue|suggestion","file","line","note","in_scope","issue_title"}],"resolved":[…]}`.
  `changes_requested` if and only if an in-scope blocker or issue exists.
  Interactive use keeps "the user decides".

The runner (`review.sh`): records branch, HEAD, `git status --porcelain`,
`tmp/.last-verify-status` and `git worktree list`; creates
`git worktree add --detach "$(mktemp -d)" <head>`; runs the reviewer on sonnet
with `Read, Grep, Glob, Bash(git diff:*), Bash(git log:*), Bash(git show:*)` in
that worktree, with the charter inlined; parses the last JSON block (invalid →
retry once → park); removes the worktree; asserts every recorded value is
unchanged — a violation fails the **whole run**, not the issue. It posts the
report with `gh pr comment --body-file` (self-approval is impossible on GitHub).
In-scope findings become fix items. Out-of-scope issues and blockers become
follow-ups (`needs-triage`, deduplicated by a finding hash in the body, appended
to the Map). Suggestions only appear in the PR comment.

### PR title, body, final PR

- **Title:** the Map line's title if it is a conventional commit; else
  `<type>: <issue title>` with `fix` for `bug`, `docs` for `documentation`,
  `feat` otherwise. The branch prefix follows the type.
- **Body:** `Refs #N · Part of map #M` (deliberately not `Closes`), ticked plan
  items, verification (command, head, iterations, cost), review link and rounds,
  follow-ups filed.
- **Final PR** (integration → default): created or updated at the end.
  `Closes #N` per merged issue, `Closes #<map>` only when every Delivery line is
  ticked; parked and skipped issues and follow-ups listed separately. Recommended
  merge style: a merge commit, so per-issue commits survive and the release tag
  lands on the merge commit.

### Launch and pre-flight

`/deliver #<map>` runs `deliver.sh --plan-only --json` (read-only) and checks:
`gh auth status` and version, `jq`, `tmux` (fallback `setsid nohup`), clean tree,
non-default base (or `--allow-main`), verify green on the base, `tmp/` ignored,
Map parses, the DAG is acyclic, external refs are closed, labels exist
(bootstrapped: `map`, `prd`, `ready-for-agent`, `needs-human`,
`needs-triage`), and branch protection on the integration branch (warning). The
run plan shows the ordered issues, the caps and a cost estimate (~$6–8 per issue
until real runs give a mean). One confirmation, then tmux; Monitor re-arms and
also reports `runner-dead` when the lock PID is gone before a terminal state.

### Alignment with existing skills

- `implement-issue`: label `ready-for-agent`; `--base` defaulting to the repo's
  default branch; verify on the base; commit before review; reviewer gets
  `--base/--head`; assert branch and verify status around the review;
  `gh pr create --base`; out-of-scope findings → `needs-triage` issues; pointer
  to `/deliver` for a set.
- `to-prd` labels the PRD `prd`; `to-issues` publishes the Map when
  `skills/deliver/MAP-FORMAT.md` exists. Both are recorded local patches in the
  sync-log.
- `start-feature`: `prd` / `ready-for-agent`; Blocked-by DAG instead of "no
  waits on #X"; ends with `/deliver #<map>`. `next`: pointer to `/deliver`.
- `triage`'s dangling `/setup-matt-pocock-skills` reference stays as upstream
  and is listed as a known mismatch in CLAUDE.md.
- `harness-doctor`: tmux, jq, `gh auth`, labels, `tmp/` ignored. `harness-init`:
  label bootstrap.
- `check-consistency.sh`: deliver flags ↔ `skills/deliver/SKILL.md`;
  `MAP-FORMAT.md` referenced by `to-issues` and `start-feature`.
- Docs: `CONTEXT.md`, `architecture.md` (two-level model, ADR-0007 rule),
  `model-policy.md`, `LOOP-PROTOCOL.md`, `autopilot/SKILL.md` (new flags; the
  Stop-gate paragraph rewritten as manual), README, `docs/guide.html` and
  `docs/index.html` (a "Deliver a map" path; version string, which still says
  0.5.1).

## Execution model for building 0.6.0

- **Phase A (by hand, this session).** D0a then D1 on `integration/deliver`,
  one PR each, reviewed and merged by the manual workflow. Their Map lines are
  ticked by hand.
- **Phase B (dogfood).** Install a build of `integration/deliver` from a
  separate clone (never the dev checkout) and run `deliver.sh --map <map>` on
  `integration/deliver`. It skips ticked lines. D2 (park), D3 (review) and D6
  (resume) come first in the Map because they make the runner safe to leave
  alone; watch the run closely until they are merged. Each merged runner change
  takes effect after a reinstall and `--resume`.
- The installed plugin cache currently holds 0.5.1; install 0.5.2 before any
  `loop.sh` use from the cache.

## Autonomy contract

1. One **Issue** = one branch = one PR into `integration/deliver`, squash-merged.
   Inside it, one **Slice** = one plan item = one checkpoint commit.
2. An issue starts only when all its Map `after:` blockers are merged.
3. `scripts/verify.sh` passes on the exact head before every merge. Slices that
   touch `loop.sh` extend `scripts/test-autopilot-loop.sh`; slices that touch the
   runner extend `scripts/test-deliver.sh`.
4. ADR-0007 holds from the first commit: no model phase gets `gh` or
   `git push`.
5. Every issue updates the docs it touches; HTML stays self-contained.
6. Commit messages: English, conventional commits.
7. Never touch: `plugin.json` version and the `CHANGELOG.md` top entry (D11 only),
   `tmp/` contents, the Design lane (ADR-0003), vendored skills beyond the
   recorded local patches in D9.
8. A `tmp/autopilot/` directory from 0.5.x still loads; `loop.sh` without the
   new flags behaves as 0.5.2.

## Slice map

| Id | Issue | Title | Blocked by | Label |
|---|---|---|---|---|
| D0a | | loop.sh `--state-dir` + `--stop-file` seams | — | ready-for-agent |
| D0b | | Iteration gates see the whole iteration; BUILD loses git add/commit | — | ready-for-agent |
| D0c | | Extract `agent.sh`; fix the loop-test plugin copy | — | ready-for-agent |
| D0d | | Resume fidelity + `detect_verify_cmd` | — | ready-for-agent |
| D1 | | Tracer bullet: `deliver.sh --map` → branch → loop.sh → PR → verify → squash merge → tick | D0a | ready-for-agent |
| D2 | | Park failing issues, skip dependents | D1 | ready-for-agent |
| D3 | | Independent review in a throwaway worktree (reviewer contract, #52) | D1, D0c | ready-for-agent |
| D4 | | Review fix rounds + follow-up issues | D2, D3 | ready-for-agent |
| D5 | | CI wait + base-moved handling | D2 | ready-for-agent |
| D6 | | State, resume, stop, global caps | D2 | ready-for-agent |
| D7 | | Final integration → default PR; `--allow-main` / `--create-integration` | D1 | ready-for-agent |
| D8 | | `/deliver` skill: pre-flight, tmux, Monitor, status/stop/resume | D6, D7 | ready-for-agent |
| D9 | | MAP-FORMAT + label alignment across to-prd / to-issues / start-feature / implement-issue / next | — | ready-for-agent |
| D10 | | Docs, glossary, harness-doctor/init for 0.6.0 | D4, D5, D8, D9 | ready-for-agent |
| D11 | | Release 0.6.0 (**HITL**) | D10 | needs-grill |

## Test strategy

`scripts/test-deliver.sh`, a new section of `scripts/verify.sh`, offline and
under ~30 s:

- **Fixtures:** a bare `remote.git`; a clone with `main` and `integration/x`;
  `PATH` stubs. Stub `claude` extends the loop stub (plan path read from the
  prompt; review modes `approve | blocker-once | out-of-scope | garbage |
  mutate-tree`). Fake `gh` is backed by JSON files, implements exactly the
  `forge.sh` calls, performs a real squash merge into the bare repo, honours
  `--match-head-commit`, has CI modes `none | pass | fail | pending` and a
  base-advance hook, and logs every call.
- **End-to-end:** happy path with two dependent issues; refuse `main`; blocker →
  fix round; out-of-scope follow-up; park + skip + independent issue merged;
  resume after kill without duplicate PR or review comment; base moved (and
  conflict → park); CI fail / none; reviewer mutates the tree → run `failed`;
  budget cap; STOP; guardrails (no `--force`, `-f` push or `--admin` in the
  trace).
- **Unit:** `map.sh` (section bounds, byte-identical tick, idempotent append,
  title validation, external refs, `#N` DAG incl. a cycle), `charter.sh`,
  verdict parsing, resume reconciliation over a gh-JSON fixture.

## Out of scope

- Parallel issues (#39 M1). State and locking are per run so M1 can add workers.
- Asking a human mid-issue (#40 M2); a parked issue is the only pause.
- Other forges and backends (#42 M4); `forge.sh` and `agent.sh` are the seams.
- Executing follow-ups in the run that found them.
- Per-issue holdouts.
- A `--worktree` mode that leaves the user's checkout free during a run.

## Risks

- **Cost.** 0.5.0 spent $34.51 on 8 issues on one branch. Per issue this adds an
  opus PLAN, a sonnet review per round and a likely fix round. Hard bound:
  `min(--budget-usd, N × --issue-budget-usd)`.
- **The runner bypasses permission rules and guards** (ADR-0007
  consequences) — covered by the guardrail tests.
- **Map body edit races** — single-line edits, read-back, retries.
- **Branch protection requiring reviews** blocks the runner; it parks with the
  reason.
- **The checkout is unusable during a run**; touching it stops the run.
