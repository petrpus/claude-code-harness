---
name: next
description: Show the current priority queue from GitHub issues and start work on the next task. Use at session start when the user asks "what's next?" / "co je dál?" — or any time you need to know what to do next in a project.
---

# /next

Lightweight priority surface for GitHub-issue-driven projects. Two labels:

- **`next`** — exactly ONE issue at a time. The thing to do right now.
- **`up-next`** — small queue (target ≤ 5).
- No label = backlog.

## Behaviour

1. **Bootstrap labels if missing.** Run once per repo:

   ```bash
   gh label create next --color B60205 --description "Single 'do this now' issue" 2>/dev/null || true
   gh label create up-next --color FBCA04 --description "Small priority queue after 'next'" 2>/dev/null || true
   ```

   (Errors silently swallowed because labels may already exist.)

2. **Read state:**

   ```bash
   gh issue list --label next --state open --json number,title,body
   gh issue list --label up-next --state open --json number,title --jq '.[] | "#\(.number)  \(.title)"'
   gh issue list --state open --limit 8 --json number,title,labels --jq '[.[] | select((.labels | length) == 0)] | .[] | "#\(.number)  \(.title)"'
   git log --oneline -5
   ```

3. **Show the user** (concise, one section each):
   - **Next:** the one `next`-labeled issue with title + a one-line summary derived from the body.
   - **Queue:** numbered `up-next` list.
   - **Backlog tail:** up to 5 most-recent unlabeled open issues.
   - **Recent commits:** last 5 oneline.
   - **Suggestion:** if `next` exists, propose `/implement-issue <N>`. If no `next`, ask whether to promote from the queue.

4. **Wait for the user.** Don't auto-start `/implement-issue`. Don't pick from backlog without asking.

## Reassigning priority (inline, no separate skill)

When the user says any of these, run the gh commands and announce what you did:

| User says | Action |
|---|---|
| "udělej teď #X" / "do #X next" | `gh issue edit X --add-label next`; demote previous `next` to `up-next` |
| "zařaď #X do fronty" / "queue #X" | `gh issue edit X --add-label up-next` |
| "vyhoď #X z fronty" / "drop #X" | `gh issue edit X --remove-label up-next` |
| "tohle už není priorita" | `gh issue edit X --remove-label next --remove-label up-next` (keeps issue open, demotes to backlog) |

Always assert there's **at most one** `next`-labeled issue after any change:

```bash
count=$(gh issue list --label next --state open --json number --jq 'length')
[[ "$count" -le 1 ]] || echo "WARN: ${count} issues have label 'next' — expected at most 1"
```

## Anti-patterns

- Don't auto-run `/implement-issue` without explicit user confirmation.
- Don't create issues for vague priorities — ask the user to describe the work, then file with the right label.
- Don't add more than ~5 issues to `up-next` — if the queue grows past that, the convention has stopped working as a focus tool.

## Edge cases

- **Zero `next`, non-empty `up-next`:** show the queue and ask user to pick.
- **Multiple `next` labels (bug):** show all of them, ask user to pick which one stays.
- **No issues at all:** say so explicitly. Don't invent work.
- **Not in a git repo / no `gh` configured:** explain the prerequisite and stop. Don't try to fall back to a local TODO file — that's a different workflow.
