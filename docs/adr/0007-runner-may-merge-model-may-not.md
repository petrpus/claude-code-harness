# The runner may open and merge PRs; the model may not

PRD 0001 let the cloud agent merge its own PR when verify was green — one issue,
one branch, one PR. PRD 0002 replaced that for 0.5.0 with a single branch and no
`gh` at all (contract item 4: "The agent never opens or merges a PR"), because
`loop.sh` had no PR machinery and granting `Bash(gh:*)` to BUILD under
`acceptEdits` would also grant `gh pr merge`, `gh issue close` and
`gh api -X PATCH`.

The workflow that actually works in practice sits between the two: one PR per
issue into an integration branch, an independent review on each PR, and a merge
before the next issue starts. `/deliver` (PRD 0003) automates it. This ADR
records who is allowed to do what, and supersedes PRD 0002 contract item 4.

## Decision

1. **Every forge mutation lives in the deterministic bash runner.** Push,
   `gh pr create`, PR comments, `gh pr merge`, issue create / edit / comment /
   label — all go through `skills/deliver/forge.sh`, called only by
   `skills/deliver/deliver.sh`. #40's rule becomes general: *the runner posting
   is fine, the model posting is not.*
2. **No model phase is ever granted `gh` or `git push`.** That covers PLAN,
   BUILD, the verifier, the reviewer and any title/summary call. BUILD also
   loses `git add` / `git commit`: the runner owns checkpoint commits, and a
   commit made by BUILD blinds the secret scan and the verifier (both diff
   against the iteration's start).
3. **A merge needs every one of:** the inner `loop.sh` run ended `done`; the
   latest review verdict has no open in-scope blocker or issue; verify passed
   locally on the exact head being merged; CI is green or absent; and the merge
   is pinned with `--match-head-commit`.
4. **The merge target is an integration branch, not the default branch.** The
   runner refuses `main` / `master` unless `--allow-main` is passed. The
   integration → default PR is opened by the runner and merged by a human.
5. **The runner never force-pushes, never uses `--admin`, and only pushes or
   deletes branches it created** (recorded in its state). When the base moves,
   it merges the base into the issue branch locally, re-verifies and pushes a
   fast-forward.
6. **Model calls run without forge credentials** (#77). `agent_run`
   (`skills/autopilot/agent.sh`) starts every `claude -p` — PLAN, BUILD, the
   verifier, the reviewer — with the gh tokens unset, `GH_CONFIG_DIR` pointed
   at an empty private dir, every git credential helper cleared (an empty
   `credential.helper` appended through `GIT_CONFIG_COUNT`), no prompt or
   askpass, no ssh agent and a failing `GIT_SSH_COMMAND`. The verify command
   gets the same treatment, because BUILD may edit what it runs and the
   runner executes it. The runner's own forge calls keep the user's
   credentials.

## Three layers, one of them missing

Decision 2 is enforced in layers, and they are not equally strong:

1. **Allowlists** (`--allowedTools`, the reviewer's no-shell setup,
   `forge_grant_violations` for `--extra-allowed-tools`). Defence in depth
   only: BUILD edits files and runs the verify command, and autopilot's base
   allowlist already grants `npx`, `pnpm` and `node`, so an allowlist can
   never prove a model phase cannot reach `gh`.
2. **Withheld credentials** (decision 6). Stops a model phase from acting on
   the forge by accident or by following instructions — the credentials are
   not where `gh` and `git` look. It does not stop a model that deliberately
   points them back (`git -c credential.helper=store push`,
   `GH_CONFIG_DIR=~/.config/gh gh …`): the model runs as the same user and
   can read those files. A plaintext `~/.git-credentials` makes that easier;
   `harness-doctor` flags it. The environment cannot withhold a `~/.netrc`
   entry (git's https transport reads it directly) or keep a bare `ssh` with
   a passphrase-less key from speaking the git protocol itself.
3. **An OS or network sandbox** around model calls — the only layer that
   holds against a deliberate model. Not built; researched in #79.

## Considered options

**Grant `Bash(gh pr:*)` to BUILD (rejected).** A prefix allow on `gh pr` is a
merge permission. The model would decide when its own work is done and merge
it — exactly the self-assessment the runner-enforced gates exist to remove.

**A model-driven orchestration skill (rejected).** One Claude session walking
the issue set with subagents is less code and closer to how the workflow is done
by hand today. But its gates are advisory (the orchestrating model decides that
verify "passed"), it holds `gh pr merge`, its context grows with every issue, it
is not resumable after a crash, and it has no hard cost cap.

**Keep PRD 0002's single branch (rejected).** One PR at the end means one
review over the whole set — too large to review well, and a bad issue blocks the
rest instead of being parked.

## Consequences

The runner's own `git` and `gh` calls run inside one top-level Bash command, so
Claude Code's permission rules and the `pre-bash` guard do not see them. The
conservatism therefore has to live in the runner itself, and its tests must
assert it: the runner's command trace contains no `--force`, no `-f` push and no
`--admin`.

Issues merged into an integration branch do not close — GitHub only honours
`Closes #N` on merge to the default branch. The final PR carries the `Closes`
list; until it merges, the Map (ADR-0008) is the record of what is delivered.

Branch protection that requires an approving review blocks the runner, because
it authors the PRs with the user's token and GitHub refuses self-approval. The
issue is parked with that reason; the runner never works around it.
