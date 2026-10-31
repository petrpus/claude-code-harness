---
name: worklog
description: Generate a per-day, per-author time-tracking summary from git commits across all local and remote branches. Optional integer argument = days back (default 3). With --harvest or --clockify, open a local page to review the days against that time tracker and create or update the entries there.
argument-hint: "[days-back, default 3] [--harvest|--clockify]"
---

# /worklog

Daily commit-history digest for time tracking. Walks `git log --all` (local + remote refs), groups commits by date and author, and synthesizes each (day, author) block into a short headline + 4–8 bullets describing what was worked on. Not a commit log — a human-readable diary distilled from commit subjects and bodies.

## Inputs

- A number — optional integer **X**, the number of days back from today (inclusive). Defaults to `3` (= today and the previous 3 days, so 4 calendar days).
- `--harvest` or `--clockify` — after the digest, log the days into that time
  tracker through the `## Time-tracker mode` flow below. The integer may come
  before or after the flag; the two flags exclude each other.

## Behavior

### 1. Parse the argument

```bash
TRACKER=""; X=""
for a in $ARGUMENTS; do
  case "$a" in
    --harvest|--clockify)
      [[ -z "$TRACKER" || "$TRACKER" == "${a#--}" ]] || { echo "worklog: --harvest and --clockify exclude each other"; exit 1; }
      TRACKER="${a#--}" ;;
    *) X="$a" ;;
  esac
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

With `--harvest` or `--clockify`, skip this step and continue with `## Time-tracker mode`.

After printing, ask the user (one sentence, no menu) whether to save the output as a markdown file to the project's `tmp/` directory.

If they confirm:

```bash
mkdir -p tmp
out="tmp/worklog-$(date -d "${X} days ago" +%Y-%m-%d)_to_$(date +%Y-%m-%d).md"
# write the rendered output to "$out"
```

Filename pattern: `tmp/worklog-{from}_to_{to}.md`. If the file already exists, overwrite without prompting (it's a regenerated artifact, not history).

## Time-tracker mode (`--harvest` / `--clockify`)

Turns the digest into time entries for **the user running the skill** (their
own commits only — never log another author's work), on the **Programming**
task, in Harvest (`--harvest`) or Clockify (`--clockify`). The user reviews
and sends them on a local page: a project select, what the tracker already
holds for that project and task in the window, and an editable proposal per
day with a button that creates the entry or updates the existing one.

Each tracker is reached only through its bundled script, `harvest.sh` or
`clockify.sh` (curl + jq, no MCP). Both have the same commands (`setup`, `me`,
`projects`, `entries`, `log`, `update`, `delete`) and output shapes. Below,
`{tracker}` is `harvest` or `clockify` and `{tracker}.sh` its script.
`worklog-app.py` (python3, standard library only) serves the page on
127.0.0.1 and calls the script for every read and write, so the token never
reaches the page, the chat or this skill. The scripts live in this skill's
directory and are not on `PATH`: call them by the full path shown in each
step. `tmp/` is the consumer project's gitignored `tmp/`.

### 0. Credentials

```bash
${CLAUDE_PLUGIN_ROOT}/skills/worklog/{tracker}.sh me
```

Exit 1 with "no token", "no API key", "no account id" or "no workspace id"
means there is no config yet (exit 1 also covers a missing curl or jq, or a
network failure — say which). Exit 2 with HTTP 401 means the token or key
expired or was revoked: `setup` again replaces it. Tell the user, in two
numbered steps, how to get a token and then to run `setup` in **their own
terminal** (not through `!`: the token goes into a hidden prompt, never onto
a command line or into the conversation). Stop here until `me` succeeds.

**Harvest:**

1. create a personal access token at https://id.getharvest.com/developers
   (Create new personal access token) and copy it;
2. run:

```bash
${CLAUDE_PLUGIN_ROOT}/skills/worklog/harvest.sh setup [account-name]
```

It writes `~/.config/harvest/env` (mode 0600) with the token and the resolved
account id (exact name or id first, name substring as a fallback; the
argument is only needed when the token sees several accounts).

**Clockify:**

1. in Clockify, open Profile settings → Preferences → Advanced → Manage API
   keys, click Generate new, name the key and copy it (it is shown once; a
   workspace on its own subdomain needs a key generated for that workspace);
2. run:

```bash
${CLAUDE_PLUGIN_ROOT}/skills/worklog/clockify.sh setup [workspace-name]
```

It writes `~/.config/clockify/env` (mode 0600) with the key, the resolved
workspace (exact name or id first, name substring as a fallback; the argument
is only needed when the key sees several workspaces), the user id and the
time zone from the Clockify profile. A workspace on a regional server needs
that server's API base on the `setup` line, which `setup` then stores, e.g.
`CLOCKIFY_API_BASE=https://euc1.clockify.me/api/v1`.

### 1. Build the proposals

Write `tmp/worklog-{tracker}-{from}_to_{to}.json`, one row per day the user has
commits (or session-log activity with no commit — say so in the notes):

```json
[{ "date": "2026-10-14", "hours": 7, "notes": "theme one (#321)\ntheme two" }]
```

- `notes` is the day's bullets joined with newlines, same language rules as
  the digest, issue/PR numbers kept. No headline, no hashes.
- `hours` is an **estimate** the user corrects on the page. Derive it from the
  day's shape rather than from the commit count: the span between the first
  and last commit of the day (session log included), scaled down for gaps
  longer than two hours; a day with a single small commit is 1–2 h, a day
  with a merged multi-PR feature is 6–8 h; round to the quarter hour; never
  exceed 10 h. Say which rule produced an estimate only if the user asks.
- If the file already exists for the same window, keep its rows: the page
  wrote the user's edits and `entry_id`s into it.

### 2. Guess the project

```bash
${CLAUDE_PLUGIN_ROOT}/skills/worklog/{tracker}.sh projects --text
```

Pick the project that fits the repo from context (CLAUDE.md, README, the
remote's name, the client the code is for) and pass it as `--project`. It is
only the default of the select: a project the user chose earlier for this
repo (remembered in `~/.config/{tracker}/projects.json`) wins, and the user
can change it on the page. Projects without an active Programming task show
disabled. In Clockify, a project with no tasks at all (`(no tasks)` in the
listing) is logged without a task. If `projects` prints nothing, or no
project can be logged to, there is nothing the page could do — stop and say
so.

### 3. Open the page

Start the server as a background task (`run_in_background`), so this turn is
re-invoked when it exits; `--open` makes it open the page in the default
browser itself:

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/skills/worklog/worklog-app.py \
  tmp/worklog-{tracker}-{from}_to_{to}.json --service {tracker} --from {from} --to {to} \
  --project {project_id} --repo "$(git rev-parse --show-toplevel)" --open
```

Right after starting it, read the first line of the background task's output
— the URL, `http://127.0.0.1:<port>/#k=<key>` (the key in the fragment guards
the API) — and give it to the user as a link, in case the browser did not
open. Then tell them in two lines what the page does: each row's button
creates or updates that day's entry right away, “Send all changes” sends every
changed row after an inline confirm, and “Done — close” ends the session.
After that, do not poll: wait for the background task to finish.

The page lists every day of the window, newest first. A day that already has a
Programming entry in that project shows it, and the row's button updates it
(the target select can switch to a new entry instead); a day without one
creates it. The server re-reads the day from the tracker before every write
and refuses a plain create on a day that already has an entry (the user must
pick “New entry” for a second one), so a stale page cannot log a day twice. If
the entries cannot be read, every button stays disabled until a retry
succeeds. Every write goes through `{tracker}.sh log` / `update`, prints one
JSON line on the server's stdout and writes `entry_id` back into the
proposals file.

**Clockify stores intervals, not hours.** A new entry starts at 09:00 in the
user's Clockify time zone, or right after the user's last entry of that day
when that ends later (`CLOCKIFY_DAY_START=HH:MM` moves the 09:00). New hours
keep an entry's start and move its end. An update keeps the entry's tags,
billable flag and custom fields; a new entry is billable when its project is.
Entries still running are not shown and cannot be updated.

### 4. Report

When the server exits (`{"exit": "done"}`, or `{"exit": "idle"}` after 45
minutes without a request — an open page pings it every minute, so idle means
the tab was closed), read its stdout and report what reached the tracker:
date, hours, created/updated, entry id. If nothing was sent, say so. A row
that the tracker refused showed its message on the page; repeat it as is. In
Harvest a 422 usually means a locked period or a missing assignment; in
Clockify a 400 usually means a locked period or a required field the
workspace demands; a 429 is the rate limit, so wait and send again. The user
has to fix the first two in the tracker. Undo is per entry:
`{tracker}.sh delete <entry_id>`.

### Rules

- Every write to the tracker is a click of the user on the page. The skill
  never calls `log`, `update`, `log-batch` or `delete` itself, except `delete`
  when the user asks for it in the chat.
- The page and the server never see the token; it stays in
  `~/.config/{tracker}/env`, read only by `{tracker}.sh`.
- The server binds 127.0.0.1 only and exits on Done or when idle. Never expose
  it on another interface or forward its port. The key reaches the browser on
  its command line, so another account on the same machine could read it from
  the process list while the page is open — on a shared machine, close the
  page with Done as soon as you are finished.

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
- **Logging straight from the digest.** Time-tracker mode always goes through the page, where the user presses the button — an estimate the user never saw is not a time entry.
- **Putting the token in the page or the chat.** `{tracker}.sh setup` runs in the user's terminal; the skill only ever sees `{tracker}.sh me` succeed or fail.

## Edge cases

- **Not a git repo** → say so and stop.
- **No commits in the window** → say so explicitly, don't fabricate.
- **`git fetch` failed (offline)** → proceed with local refs, mention it in a one-line preamble so the user knows the digest may miss teammates' work.
- **Detached HEAD / shallow clone** → still works, but warn that history may be incomplete.
- **X = 0** → only today's commits.
- **`--harvest` / `--clockify` with no commits by the user in the window** → say so and stop; there is nothing to log.
- **`{tracker}.sh projects` prints `[]`** (no active assignments in Harvest, no active project in the Clockify workspace) → stop and say so.
- **`--harvest` / `--clockify` without python3** → say so; the page needs it. `{tracker}.sh log` / `update` still work by hand.
