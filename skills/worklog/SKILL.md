---
name: worklog
description: Generate a per-day, per-author time-tracking summary from git commits across all local and remote branches. Optional integer argument = days back (default 3). With --harvest, turn the digest into Harvest time entries after the user edits notes and hours in a review table.
argument-hint: "[days-back, default 3] [--harvest]"
---

# /worklog

Daily commit-history digest for time tracking. Walks `git log --all` (local + remote refs), groups commits by date and author, and synthesizes each (day, author) block into a short headline + 4–8 bullets describing what was worked on. Not a commit log — a human-readable diary distilled from commit subjects and bodies.

## Inputs

- `$ARGUMENTS` — optional integer **X**, the number of days back from today (inclusive). Defaults to `3` (= today and the previous 3 days, so 4 calendar days).
- `--harvest` — after the digest, log the days into Harvest through the
  `## Harvest mode` flow below. The integer may come before or after the flag.

## Behavior

### 1. Parse the argument

```bash
HARVEST=0; X=""
for a in $ARGUMENTS; do
  case "$a" in --harvest) HARVEST=1 ;; *) X="$a" ;; esac
done
X="${X:-3}"
[[ "$X" =~ ^[0-9]+$ ]] || { echo "worklog: argument must be a non-negative integer"; exit 1; }
SINCE="$(date -d "${X} days ago" +%Y-%m-%d) 00:00:00"
UNTIL="$(date +%Y-%m-%d) 23:59:59"
```

### 2. Refresh remote refs (best-effort)

```bash
git fetch --all --quiet 2>/dev/null || true
```

Offline / no remote → continue silently with whatever refs are available.

### 3. Pull commits across all refs

```bash
git log --all --no-merges \
  --since="$SINCE" --until="$UNTIL" \
  --date=short \
  --pretty=format:'===COMMIT===%n%H%n%ad%n%an%n%ae%n%s%n%b%n'
```

Notes:
- `--all` covers local branches **and** remote-tracking branches; commits visible on multiple branches appear once.
- `--no-merges` strips merge noise. If the user explicitly asks for merges, drop that flag.
- Both subject (`%s`) and body (`%b`) are captured — the body often holds the real reasoning.

### 3b. Enrich with session activity (if present)

The harness `session-log.sh` Stop hook appends a per-turn JSONL entry to
`tmp/session-log.jsonl` (`{ts, session_id, cwd, branch, dirty_files,
last_commit, event}`). It captures work that never became a commit (research
turns, aborted attempts, long dirty-tree stretches).

```bash
[[ -f tmp/session-log.jsonl ]] && jq -c "select(.ts >= \"$(date -d "${X} days ago" +%Y-%m-%d)\")" tmp/session-log.jsonl 2>/dev/null
```

If the file exists, fold these into the digest as a secondary signal — commits
stay the **primary** record; session entries fill the gaps between them (e.g.
"several turns on branch X with no commit → exploratory/blocked"). Collapse the
many per-turn entries per (day, branch) into one line; don't list every turn.
If the file is absent or `jq` is missing, skip silently.

### 4. Group and synthesize

Group by `(date desc, author)`. For each block:

- **Headline**: 2–5 keyword phrases capturing the day's themes (comma-separated).
- **Bullets**: 4–8 lines, each one a *theme* of work — **not** one bullet per commit. Merge related commits (e.g. "fix X" + "test for X" + "follow-up to X" → one bullet). Drop trivial bumps (lockfile, version, formatting) unless they're the only thing that happened.
- **Language**: match the language of the commit messages. Czech commits → Czech summary. English commits → English summary. Mixed → match whichever dominates.
- **No hashes, no commit counts** — this output is for humans tracking time, not for code archaeology.

### 5. Render

```
### {author}

YYYY-MM-DD — {headline}
  - {bullet}
  - {bullet}
  ...

YYYY-MM-DD — {headline}
  - {bullet}
  ...
```

If multiple authors, render one `### {author}` section per author, days in descending order inside each section. Within the X-day window, days with zero commits are simply omitted.

### 6. Ask about saving

With `--harvest`, skip this step and continue with `## Harvest mode`.

After printing, ask the user (one sentence, no menu) whether to save the output as a markdown file to the project's `tmp/` directory.

If they confirm:

```bash
mkdir -p tmp
out="tmp/worklog-$(date -d "${X} days ago" +%Y-%m-%d)_to_$(date +%Y-%m-%d).md"
# write the rendered output to "$out"
```

Filename pattern: `tmp/worklog-{from}_to_{to}.md`. If the file already exists, overwrite without prompting (it's a regenerated artifact, not history).

## Harvest mode (`--harvest`)

Turns the digest into one Harvest time entry per day for **the user running the
skill** (their own commits only — never log another author's work). Harvest is
reached through `harvest.sh` (bundled, curl + jq, no MCP); the user edits the
batch in a static review table before anything is sent.

Paths below are relative to this skill's directory
(`${CLAUDE_PLUGIN_ROOT}/skills/worklog/`); `tmp/` is the consumer project's
gitignored `tmp/`.

### 0. Credentials

```bash
harvest.sh me
```

Exit 1 means there is no config yet. Tell the user to run, in their own
terminal (the token must not pass through the conversation, and it is never
an argument — `setup` asks for it on a hidden prompt, so it stays out of the
shell history and the process list):

```bash
${CLAUDE_PLUGIN_ROOT}/skills/worklog/harvest.sh setup [account-name]
```

It writes `~/.config/harvest/env` (mode 0600) with the token and the resolved
account id (exact name or id first, name substring as a fallback). Tokens come
from https://id.getharvest.com/developers. Stop here until `harvest.sh me`
succeeds.

### 1. Build the batch

Write `tmp/worklog-harvest-{from}_to_{to}.json`, one row per day the user has
commits (or session-log activity with no commit — say so in the notes):

```json
[{ "date": "2026-10-14", "hours": 7, "notes": "theme one (#321)\ntheme two" }]
```

- `notes` is the day's bullets joined with newlines, same language rules as
  the digest, issue/PR numbers kept. No headline, no hashes.
- `hours` is an **estimate**, and the table says so. Derive it from the
  day's shape rather than from the commit count: the span between the first
  and last commit of the day (session log included), scaled down for gaps
  longer than two hours; a day with a single small commit is 1–2 h, a day
  with a merged multi-PR feature is 6–8 h; round to the quarter hour; never
  exceed 10 h without the user asking for it. Say in the chat which rule
  produced each estimate only if the user asks.
- If the file already exists for the same window, reuse its rows (the user
  may have edited it or already logged some of them — rows with `entry_id`
  must survive).

### 2. Pick the project and task

```bash
harvest.sh projects --text
```

Ask with AskUserQuestion: one question for the project (client / project
name, id in the description), then one for the task of that project. If a
project has exactly one active task, take it without asking. Remember the
pair for the rest of the session.

### 3. Show what Harvest already holds

```bash
harvest.sh entries {from} {to} --project {project_id}
```

Merge the per-day sums into the batch as `logged` so the table shows them.
A day that already carries hours in Harvest is still logged again unless the
user drops it — this is their call, not the skill's; make it visible, don't
decide.

### 4. Review table

```bash
harvest-review.sh tmp/worklog-harvest-{from}_to_{to}.json tmp/worklog-harvest-{from}_to_{to}.html --project "{client} / {project}" --task "{task}"
```

Open it with the `human-review` skill and poll for feedback. (Without that
skill: print the `file://` link, let the user edit the JSON directly, and
continue from step 5 once they say so.) Each notes and
hours cell is labelled `{date} · notes` / `{date} · hours`, so every edit in
the batch names its row:

- `{date} · notes` → replace the row's `notes` with `after` (newlines per
  line; strip HTML).
- `{date} · hours` → parse `after` as a number; `0` means `"skip": true`,
  any value above `0` sets `hours` **and removes `skip`**.
- A comment on a row is an instruction about that row — apply it, re-render,
  keep polling until the user says they are done or the feedback carries no
  edits.

Re-render after every applied batch so the page reloads with the new state.

### 5. Confirm, then log

Print the final table in the chat (date, hours, first line of notes, total)
and ask with AskUserQuestion whether to send it. The write happens only on a
yes:

```bash
harvest.sh log-batch tmp/worklog-harvest-{from}_to_{to}.json --project {project_id} --task {task_id}
```

Each success writes the row's `entry_id` back into the JSON, so a rerun
skips it; a failure stops the batch at that row and prints which rows went
through. Report the created entries (date, hours, id) and, on a partial
failure, exactly which days are still missing. Undo is per entry:
`harvest.sh delete <entry_id>` (a `--force` rerun keeps the ids it replaced
under `previous_entry_ids`, so those stay deletable too).

### Rules

- Never run `log` / `log-batch` without the explicit yes from step 5, and
  never with `--force` unless the user asked to log a day twice.
- The HTML is a review surface, nothing else: no token, no script, no
  network. Logging goes through `harvest.sh` only.
- The user's `after` text is theirs — carry it verbatim into the JSON.
- If `harvest.sh` exits 2 (Harvest refused), show its message as is; don't
  retry on your own — a 422 usually means a locked period or a missing
  assignment, which the user has to fix in Harvest.

## Example output

```
### Petr Puš

2026-05-17 — harness, infra port, hledání
  - Migrace na claude-code-harness plugin
  - Port ApiResponse typu, useApiFetcher hooku a Sonner Toasteru
  - Warning když kritická nastavení padají na default
  - Trusted-proxy poznámka pro X-Forwarded-For
  - E2E: Playwright storageState místo manual loginu + zpřísnění čtyř locatorů
  - Fix: vehicle-photos server-sync gate na idle fetchers
  - Meilisearch top-bar search — tracer-bullet (vehicles), pak rozšíření na customers + cases
```

## Anti-patterns

- **One bullet per commit.** This is a digest, not a log — synthesize themes across commits.
- **Including merge commits.** They duplicate work already on the merged branches.
- **Inventing work.** If a day has only a "chore: bump deps" commit, say so honestly — don't pad.
- **Translating the summary.** Keep the language of the commits; don't auto-translate Czech → English or vice versa.
- **Writing to `/tmp` instead of `tmp/`.** The project-local `tmp/` dir matches existing harness convention (`tmp/.last-verify-status`).
- **Logging straight from the digest.** Harvest mode always goes through the review table and the explicit yes — an estimate the user never saw is not a time entry.
- **Putting the token in the page or the chat.** `harvest.sh setup` runs in the user's terminal; the skill only ever sees `harvest.sh me` succeed or fail.

## Edge cases

- **Not a git repo** → say so and stop.
- **No commits in the window** → say so explicitly, don't fabricate.
- **`git fetch` failed (offline)** → proceed with local refs, mention it in a one-line preamble so the user knows the digest may miss teammates' work.
- **Detached HEAD / shallow clone** → still works, but warn that history may be incomplete.
- **X = 0** → only today's commits.
- **`--harvest` with no commits by the user in the window** → say so and stop; there is nothing to log.
- **`--harvest` and `harvest.sh` exits 1 on `projects`** (no assignments) → the user has no active project in that Harvest account; stop and say so.
