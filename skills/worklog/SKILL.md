---
name: worklog
description: Generate a per-day, per-author time-tracking summary from git commits across all local and remote branches. Optional integer argument = days back (default 3).
argument-hint: "[days-back, default 3]"
---

# /worklog

Daily commit-history digest for time tracking. Walks `git log --all` (local + remote refs), groups commits by date and author, and synthesizes each (day, author) block into a short headline + 4–8 bullets describing what was worked on. Not a commit log — a human-readable diary distilled from commit subjects and bodies.

## Inputs

- `$ARGUMENTS` — optional integer **X**, the number of days back from today (inclusive). Defaults to `3` (= today and the previous 3 days, so 4 calendar days).

## Behavior

### 1. Parse the argument

```bash
X="${ARGUMENTS:-3}"
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

After printing, ask the user (one sentence, no menu) whether to save the output as a markdown file to the project's `tmp/` directory.

If they confirm:

```bash
mkdir -p tmp
out="tmp/worklog-$(date -d "${X} days ago" +%Y-%m-%d)_to_$(date +%Y-%m-%d).md"
# write the rendered output to "$out"
```

Filename pattern: `tmp/worklog-{from}_to_{to}.md`. If the file already exists, overwrite without prompting (it's a regenerated artifact, not history).

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

## Edge cases

- **Not a git repo** → say so and stop.
- **No commits in the window** → say so explicitly, don't fabricate.
- **`git fetch` failed (offline)** → proceed with local refs, mention it in a one-line preamble so the user knows the digest may miss teammates' work.
- **Detached HEAD / shallow clone** → still works, but warn that history may be incomplete.
- **X = 0** → only today's commits.
