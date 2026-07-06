# Branch protection

Printed by `/project-infra branch-protection` — **advice only, never
executed by the skill.** The user runs it themselves after reviewing it,
since it changes who can merge to `main`.

Requires `gh` authenticated with `repo` scope (admin on the repo, since
branch protection is an admin-only API).

```bash
gh api repos/{owner}/{repo}/branches/main/protection \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  -f required_status_checks.strict=true \
  -f 'required_status_checks.contexts[]=verify' \
  -F required_pull_request_reviews.required_approving_review_count=1 \
  -F enforce_admins=true \
  -F restrictions=null
```

Fill in `{owner}/{repo}` from `git remote get-url origin`, and swap the
`verify` context name for whatever the job is actually called in
`.github/workflows/ci.yml` (the `ci-workflow.template.yml` default names the
job `verify`).

What this does:

- `required_status_checks.contexts[]=verify` — the `verify` CI job must pass
  before merge. `strict=true` also requires the branch to be up to date with
  `main` first.
- `required_pull_request_reviews.required_approving_review_count=1` — at
  least one approving review before merge.
- `enforce_admins=true` — the rules apply to repo admins too, not just
  everyone else.
- `restrictions=null` — no additional push restrictions beyond the above
  (anyone with write access can still open PRs).

To loosen this later (e.g. drop the review requirement for a solo project),
re-run with `required_pull_request_reviews=null` instead of the `-F` line
above, or edit protection settings in the GitHub UI under Settings → Branches.
