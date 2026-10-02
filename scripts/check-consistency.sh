#!/usr/bin/env bash
# scripts/check-consistency.sh — self-verify for the code-harness plugin repo
# (repository and marketplace: claude-code-harness).
#
# Run from the repo root (or anywhere inside it). Non-zero exit on any failure.
# Checks structural invariants that are easy to break during a vendor sync or a
# skill addition. This is the repo's own "verify" — the integration pass and any
# future contributor should run it before committing.

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1

FAIL=0
note() { echo "  ✗ $*"; FAIL=1; }
ok()   { echo "  ✓ $*"; }
section() { echo; echo "== $1 =="; }

# ---------------------------------------------------------------------------
section "shell syntax (bash -n)"
while IFS= read -r f; do
  bash -n "$f" 2>/dev/null && ok "$f" || note "$f has a syntax error"
done < <(find hooks scripts skills -name '*.sh' -type f 2>/dev/null | sort)

# ---------------------------------------------------------------------------
section "JSON validity"
if command -v jq >/dev/null 2>&1; then
  for j in .claude-plugin/plugin.json .claude-plugin/marketplace.json \
           hooks/hooks.json templates/project-settings.template.json; do
    [[ -f "$j" ]] || { note "$j missing"; continue; }
    jq empty "$j" 2>/dev/null && ok "$j" || note "$j is invalid JSON"
  done
else
  echo "  (jq not available — skipping JSON validation)"
fi

# ---------------------------------------------------------------------------
# A deny glob matches a substring of the command, so an unanchored short flag
# matches inside operands too: `Bash(git push *-f*)` denied every branch named
# feat/...-full, fix/...-first, feat/...-filter. Claude Code's matcher can't be
# exercised from here, so this is the closest thing to a test for L1 — assert
# the shape instead of the behaviour. `-rf` in `rm -rf /*` is untouched: the
# offending shape is `*-f`, a wildcard running straight into the flag.
section "settings template: short-flag denies are whitespace-anchored"
TPL=templates/project-settings.template.json
if command -v jq >/dev/null 2>&1 && [[ -f "$TPL" ]]; then
  UNANCHORED="$(jq -r '.permissions.deny[]? | select(contains("*-f"))' "$TPL" 2>/dev/null)"
  if [[ -n "$UNANCHORED" ]]; then
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      note "deny '$p' matches '-f' inside operands; anchor it as '<cmd> -f*', '<cmd> * -f *', '<cmd> * -f'"
    done <<<"$UNANCHORED"
  else
    ok "no unanchored '*-f' deny pattern"
  fi
  for p in 'Bash(git push -f*)' 'Bash(git push * -f *)' 'Bash(git push * -f)' \
           'Bash(git clean -f*)' 'Bash(git clean * -f *)' 'Bash(git clean * -f)'; do
    if jq -e --arg p "$p" '.permissions.deny | index($p)' "$TPL" >/dev/null 2>&1; then
      ok "deny has $p"
    else
      note "deny is missing $p"
    fi
  done
else
  echo "  (jq not available or template missing — skipping deny-glob check)"
fi

# ---------------------------------------------------------------------------
# Write/Edit derive from the Read deny, so a Read deny matching a file a project
# is supposed to COMMIT makes that file uncreatable and any Edit/Write allow
# above it dead. `Read(.env.*)` did exactly that to .env.example and .env.test.
# Assert the property (does any deny pattern match this filename?) rather than
# the spelling of one known-bad glob.
section "settings template: committed env files are not deny-matched"
if command -v jq >/dev/null 2>&1 && [[ -f "$TPL" ]]; then
  for f in .env.example .env.test; do
    HIT=""
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      g="${entry#*(}"; g="${g%)}"
      # shellcheck disable=SC2254 — $g is intentionally a glob here.
      case "$f" in $g) HIT="$entry"; break ;; esac
    done < <(jq -r '.permissions.deny[]? | select(startswith("Read(") or startswith("Edit(") or startswith("Write("))' "$TPL" 2>/dev/null)
    if [[ -n "$HIT" ]]; then
      note "$f is matched by deny '$HIT' — deny wins over allow, so the file cannot be written"
    else
      ok "$f is not caught by any deny pattern"
    fi
  done
  # The secret-bearing names must stay denied — narrowing must not empty the list.
  for f in .env .env.local .env.production .env.staging; do
    HIT=""
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      g="${entry#*(}"; g="${g%)}"
      # shellcheck disable=SC2254 — $g is intentionally a glob here.
      case "$f" in $g) HIT="$entry"; break ;; esac
    done < <(jq -r '.permissions.deny[]? | select(startswith("Read("))' "$TPL" 2>/dev/null)
    [[ -n "$HIT" ]] && ok "$f is still read-denied" || note "$f is no longer read-denied"
  done
else
  echo "  (jq not available or template missing — skipping env-file deny check)"
fi

# ---------------------------------------------------------------------------
section "version == changelog top entry"
PV="$(jq -r '.version' .claude-plugin/plugin.json 2>/dev/null || echo '?')"
CV="$(grep -m1 -oE '## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo '?')"
[[ "$PV" == "$CV" ]] && ok "plugin.json $PV == CHANGELOG $CV" \
  || note "plugin.json version ($PV) != CHANGELOG top ($CV)"

# ---------------------------------------------------------------------------
# ADR-0014: Claude Code reserves plugin names that pass as Anthropic's own
# (claude-*, anthropic-*, cc-plugin-*, or `claude` as a word). The plugin was
# renamed through the marketplace's append-only `renames` map; this keeps the map
# and the names in step, then runs Claude Code's own validator when it's here.
section "plugin name, renames map, claude plugin validate --strict"
PNAME="$(jq -r '.name' .claude-plugin/plugin.json 2>/dev/null || echo '?')"
if [[ "$PNAME" =~ (^|-)(claude|anthropics?)(-|$) || "$PNAME" =~ ^cc-plugin- ]]; then
  note "plugin name '$PNAME' is reserved or reads as Anthropic's own (ADR-0014)"
else
  ok "plugin name '$PNAME' avoids the reserved forms"
fi
jq -e --arg n "$PNAME" '.plugins | length == 1 and .[0].name == $n' .claude-plugin/marketplace.json >/dev/null 2>&1 \
  && ok "marketplace entry is named '$PNAME'" || note "marketplace plugins[0].name != plugin.json name '$PNAME'"
jq -e --arg n "$PNAME" '.renames["claude-code-harness"] == $n' .claude-plugin/marketplace.json >/dev/null 2>&1 \
  && ok "renames maps the pre-0.7.0 name claude-code-harness -> $PNAME (append-only)" \
  || note "marketplace renames must keep \"claude-code-harness\": \"$PNAME\" (ADR-0014; never delete a renames entry)"
[[ -f CLAUDE.md ]] && note "CLAUDE.md is back at the plugin root — keep contributor context in .claude/CLAUDE.md (ADR-0014)" \
  || ok "no CLAUDE.md at the plugin root"
if command -v claude >/dev/null 2>&1 && claude plugin validate --help >/dev/null 2>&1; then
  for target in . .claude-plugin/plugin.json skills agents; do
    if out="$(claude plugin validate "$target" --strict 2>&1)"; then
      ok "claude plugin validate --strict $target"
    else
      note "claude plugin validate --strict $target failed:"
      printf '%s\n' "$out" | sed 's/^/      /'
    fi
  done
else
  echo "  (claude CLI with 'plugin validate' not on PATH — skipping; CI runs it through npx)"
fi

# ---------------------------------------------------------------------------
section "every skill has SKILL.md with frontmatter name == dir"
for d in skills/*/; do
  name="$(basename "$d")"
  sk="$d/SKILL.md"
  [[ -f "$sk" ]] || { note "$name: no SKILL.md"; continue; }
  fmname="$(awk '/^name:/{sub(/^name:[[:space:]]*/,"");print;exit}' "$sk")"
  desc="$(awk '/^description:/{found=1} END{print found}' "$sk")"
  [[ "$fmname" == "$name" ]] || note "$name: frontmatter name '$fmname' != dir"
  [[ "$desc" == "1" ]] || note "$name: missing description in frontmatter"
done
ok "walked $(find skills -maxdepth 1 -type d | tail -n +2 | wc -l | tr -d ' ') skills"

# ---------------------------------------------------------------------------
# Shell form, quoted placeholder, run through bash (docs/architecture.md § Plugin
# layout): an unquoted ${CLAUDE_PLUGIN_ROOT} splits on a space in the plugin path
# and fails `claude plugin validate --strict`; a bare script path stops working
# when a repackager strips the exec bit.
section "every hooks.json command is 'bash \"\${CLAUDE_PLUGIN_ROOT}/…\"' and resolves"
if command -v jq >/dev/null 2>&1; then
  while IFS= read -r cmd; do
    # shellcheck disable=SC2016 — the placeholder is matched literally.
    if [[ "$cmd" != 'bash "${CLAUDE_PLUGIN_ROOT}/'*'"' ]]; then
      note "hooks.json command is not in the bash \"\${CLAUDE_PLUGIN_ROOT}/…\" form: $cmd"
      continue
    fi
    # shellcheck disable=SC2016
    rel="${cmd#'bash "${CLAUDE_PLUGIN_ROOT}/'}"; rel="${rel%\"}"
    [[ -f "$rel" ]] && ok "$rel" || note "hooks.json references missing $rel"
  done < <(jq -r '.hooks[][]?.hooks[]?.command' hooks/hooks.json 2>/dev/null | sort -u)
fi

# ---------------------------------------------------------------------------
section "agents have frontmatter name == filename"
for a in agents/*.md; do
  [[ -f "$a" ]] || continue
  base="$(basename "$a" .md)"
  fmname="$(awk '/^name:/{sub(/^name:[[:space:]]*/,"");print;exit}' "$a")"
  [[ "$fmname" == "$base" ]] && ok "$base" || note "$a: name '$fmname' != filename"
done

# ---------------------------------------------------------------------------
# Claude Code still loads a SKILL.md whose header isn't valid YAML, so nothing
# at runtime notices — but `npx skills`, skills-ref and claude.ai uploads skip
# or reject it (project-infra shipped that way until 0.7.0). Parse the header
# for real, keep keys to known fields (typos are silent otherwise), and budget
# what Claude sees in EVERY session: the descriptions of skills without
# disable-model-invocation (ADR-0015). Needs python3 + PyYAML; CI installs it.
section "skill + agent frontmatter (YAML, names, keys, listing budget)"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  python3 - <<'PY' || FAIL=1
import glob, re, sys, yaml

# Agent Skills spec fields, then the Claude Code-only ones (code.claude.com/docs/en/skills).
SPEC = {"name", "description", "license", "compatibility", "metadata", "allowed-tools"}
CLAUDE_SKILL = {"when_to_use", "argument-hint", "arguments", "disable-model-invocation",
                "user-invocable", "disallowed-tools", "model", "effort", "context", "agent",
                "background", "hooks", "paths", "shell"}
AGENT = {"name", "description", "tools", "disallowedTools", "model", "permissionMode",
         "maxTurns", "skills", "mcpServers", "hooks", "memory", "background", "omitClaudeMd",
         "effort", "isolation", "color", "initialPrompt", "experimental"}
# ADR-0015: the user-invoked-only set. zoom-out keeps its upstream flag. A skill
# another skill composes must never be added here — the flag blocks that call.
USER_ONLY = {"autopilot", "deliver", "harness-init", "zoom-out"}
# Characters of description (+ when_to_use) in the always-on skill listing.
# 6849 at 0.7.0. Raise it on purpose, never just to get green.
LISTING_BUDGET = 7200
NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")

failed = False
def bad(msg):
    global failed
    failed = True
    print(f"  ✗ {msg}")

def header(path):
    text = open(path, encoding="utf-8").read()
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    if not m:
        return None, "no YAML frontmatter"
    try:
        data = yaml.safe_load(m.group(1))
    except yaml.YAMLError as e:
        return None, "frontmatter is not valid YAML (" + str(e).splitlines()[0] + ") — quote values containing ': ' or use a '>-' block"
    if not isinstance(data, dict):
        return None, "frontmatter is not a YAML mapping"
    return data, None

skills = sorted(glob.glob("skills/*/SKILL.md"))
visible = 0
for path in skills:
    d = path.split("/")[1]
    data, err = header(path)
    if err:
        bad(f"{path}: {err}")
        continue
    name, desc = data.get("name"), data.get("description")
    if name != d:
        bad(f"{path}: name {name!r} != directory {d!r}")
    if not isinstance(name, str) or not NAME_RE.match(name) or len(name) > 64:
        bad(f"{path}: name {name!r} is not 1-64 lowercase letters, digits and single hyphens")
    if not isinstance(desc, str) or not desc.strip():
        bad(f"{path}: missing description")
        continue
    if len(desc) > 1024:
        bad(f"{path}: description is {len(desc)} chars (Agent Skills max 1024)")
    unknown = sorted(set(data) - SPEC - CLAUDE_SKILL)
    if unknown:
        bad(f"{path}: unknown frontmatter key(s) {unknown}")
    dmi = data.get("disable-model-invocation") is True
    if dmi and d not in USER_ONLY:
        bad(f"{path}: disable-model-invocation outside ADR-0015's user-only set {sorted(USER_ONLY)}")
    if d in USER_ONLY and not dmi:
        bad(f"{path}: must carry disable-model-invocation: true (ADR-0015)")
    if not dmi:
        visible += len(desc) + len(str(data.get("when_to_use") or ""))
print(f"  ✓ parsed {len(skills)} skill headers")
if visible > LISTING_BUDGET:
    bad(f"always-on skill descriptions are {visible} chars > LISTING_BUDGET {LISTING_BUDGET} — trim, or make a runner user-only (ADR-0015)")
else:
    print(f"  ✓ always-on skill descriptions: {visible} / {LISTING_BUDGET} chars")

agents = sorted(glob.glob("agents/*.md"))
for path in agents:
    data, err = header(path)
    if err:
        bad(f"{path}: {err}")
        continue
    unknown = sorted(set(data) - AGENT)
    if unknown:
        bad(f"{path}: unknown agent frontmatter key(s) {unknown}")
    if not isinstance(data.get("description"), str) or not data["description"].strip():
        bad(f"{path}: missing description")
print(f"  ✓ parsed {len(agents)} agent headers")
sys.exit(1 if failed else 0)
PY
elif [[ "${CI:-}" == "true" ]]; then
  note "python3 + PyYAML are required in CI for the frontmatter lint"
else
  echo "  (python3/PyYAML not available — skipping frontmatter lint)"
fi

# ---------------------------------------------------------------------------
section "sync-log rows <-> vendored dirs (both directions)"
# Every skill named in the sync-log Pocock/Vercel tables should exist; and this
# is advisory (own skills aren't in the table). We only warn on a table row that
# names a missing dir.
while IFS= read -r s; do
  [[ -d "skills/$s" ]] && ok "sync-log: $s exists" || note "sync-log names missing skill '$s'"
done < <(awk -F'|' '/^\| [a-z]/{gsub(/[ *]/,"",$2); if($2 && $2!="Skill") print $2}' docs/pocock-sync-log.md 2>/dev/null | grep -vE '^$' | sort -u)

# ---------------------------------------------------------------------------
section "duplicated resources in lockstep"
cmp_identical() { # file-a file-b
  if [[ -f "$1" && -f "$2" ]]; then
    cmp -s "$1" "$2" && ok "identical: $(basename "$1")" || note "DIVERGED: $1 vs $2"
  fi
}
cmp_identical skills/domain-modeling/ADR-FORMAT.md skills/grill-with-docs/ADR-FORMAT.md
cmp_identical skills/domain-modeling/CONTEXT-FORMAT.md skills/grill-with-docs/CONTEXT-FORMAT.md
# DEEPENING allowed to differ by exactly the one cross-reference line.
if [[ -f skills/codebase-design/DEEPENING.md && -f skills/improve-codebase-architecture/DEEPENING.md ]]; then
  d="$(diff skills/codebase-design/DEEPENING.md skills/improve-codebase-architecture/DEEPENING.md | grep -cE '^[<>]')"
  [[ "$d" -le 2 ]] && ok "DEEPENING within allowed 1-line diff" || note "DEEPENING diverged by more than the allowed line ($d changed lines)"
fi

# ---------------------------------------------------------------------------
section "no dangling references"
grep -rInE 'typescript-expert|CLAUDE_TOOL_(FILE_PATH|BASH_COMMAND)' \
  skills agents hooks docs 2>/dev/null | grep -v check-consistency \
  && note "dangling reference found (see above)" || ok "no typescript-expert / CLAUDE_TOOL_ refs"

# upstream-only skill names should not leak into our content as if they were ours
for bad in diagnosing-bugs writing-great-skills loop-me ask-matt; do
  hits="$(grep -rIl "/$bad\b" skills agents 2>/dev/null || true)"
  [[ -z "$hits" ]] && ok "no /$bad refs" || note "upstream-only name /$bad referenced in: $hits"
done

# ---------------------------------------------------------------------------
section "harness CI workflow exists and invokes scripts/verify.sh"
CI_WORKFLOW=".github/workflows/verify.yml"
if [[ -f "$CI_WORKFLOW" ]]; then
  ok "$CI_WORKFLOW exists"
  grep -q 'scripts/verify\.sh' "$CI_WORKFLOW" \
    && ok "$CI_WORKFLOW invokes scripts/verify.sh" \
    || note "$CI_WORKFLOW does not invoke scripts/verify.sh"
else
  note "$CI_WORKFLOW is missing"
fi

# ---------------------------------------------------------------------------
section "autopilot flags <-> SKILL.md (every loop.sh flag is documented)"
LOOP_SH="skills/autopilot/loop.sh"
SKILL_MD="skills/autopilot/SKILL.md"
if [[ -f "$LOOP_SH" && -f "$SKILL_MD" ]]; then
  while IFS= read -r flag; do
    grep -qF -- "$flag" "$SKILL_MD" \
      && ok "$flag documented in SKILL.md" \
      || note "$flag parsed by loop.sh's case block but not mentioned in $SKILL_MD"
  done < <(grep -oE '^ *--[a-z][a-z-]*\)' "$LOOP_SH" | sed -E 's/^ *(--[a-z-]+)\).*/\1/' | sort -u)
else
  note "$LOOP_SH or $SKILL_MD missing"
fi

# ---------------------------------------------------------------------------
section "docs/*.html stay self-contained (no external resources)"
if grep -rInE 'src=|<link|@import|url\(http' docs/*.html 2>/dev/null; then
  note "docs/*.html reference an external resource (see above)"
else
  ok "no src=/<link/@import/url(http) in docs/*.html"
fi

# ---------------------------------------------------------------------------
section "Map format + front-half alignment (ADR-0008)"
MAPF="skills/deliver/MAP-FORMAT.md"
[[ -f "$MAPF" ]] && ok "$MAPF exists" || note "$MAPF is missing"
for s in to-issues start-feature; do
  grep -q 'MAP-FORMAT\.md' "skills/$s/SKILL.md" \
    && ok "$s references MAP-FORMAT.md" || note "skills/$s/SKILL.md does not reference MAP-FORMAT.md"
done
grep -q '`prd`' skills/to-prd/SKILL.md \
  && ok "to-prd labels the PRD prd" || note "to-prd does not apply the prd label"
grep -q 'ready-for-agent' skills/start-feature/SKILL.md && grep -q '`prd`' skills/start-feature/SKILL.md \
  && ok "start-feature uses prd / ready-for-agent" || note "start-feature lacks prd / ready-for-agent labels"
grep -qi 'blocked by' skills/start-feature/SKILL.md \
  && ok "start-feature uses a Blocked-by DAG" || note "start-feature lacks Blocked-by wording"
grep -qiE 'no "?waits on' skills/start-feature/SKILL.md \
  && note "start-feature still says 'no waits on #X'" || ok "start-feature has no 'no waits on' wording"
grep -qF '/deliver #<map>' skills/start-feature/SKILL.md \
  && ok "start-feature ends with /deliver #<map>" || note "start-feature does not point to /deliver #<map>"
grep -q '/deliver' skills/next/SKILL.md \
  && ok "next points to /deliver" || note "next does not point to /deliver"
grep -E '^\| to-issues \|' docs/pocock-sync-log.md | grep -q 'Map-publishing' \
  && ok "sync-log records the to-issues Map-publishing patch" || note "sync-log to-issues row lacks the Map-publishing local patch"
grep -E '^\| to-prd \|' docs/pocock-sync-log.md | grep -q '`prd` label' \
  && ok "sync-log records the to-prd prd-label patch" || note "sync-log to-prd row lacks the \`prd\` label local patch"

# ---------------------------------------------------------------------------
section "implement-issue follows the /deliver contract"
II="skills/implement-issue/SKILL.md"
ii_has() { grep -qE -- "$1" "$II" && ok "implement-issue: $2" || note "implement-issue lacks: $2"; }
ii_has 'ready-for-agent' 'label ready-for-agent'
ii_has '`--base`.*default branch|default branch.*`--base`|--base=<[^>]*>.*default branch' '--base defaults to the repo default branch'
ii_has '[Vv]erify on the base' 'verify on the base'
ii_has '[Cc]ommit before (the )?review|commit .*before .*review' 'commit before review'
ii_has '--base=<base> --head=<branch>|--head=<' 'reviewer given --base / --head'
ii_has 'git rev-parse --abbrev-ref HEAD' 'branch assertion around the review'
ii_has 'last-verify-status' 'verify-status assertion around the review'
ii_has 'gh pr create --base' 'gh pr create --base'
ii_has 'needs-triage' 'out-of-scope findings filed as needs-triage issues'
grep -q 'setup-matt-pocock-skills' .claude/CLAUDE.md && grep -qi 'known upstream mismatch' .claude/CLAUDE.md \
  && ok ".claude/CLAUDE.md lists triage's /setup-matt-pocock-skills known upstream mismatch" \
  || note ".claude/CLAUDE.md lacks the triage /setup-matt-pocock-skills known-mismatch note"

# ---------------------------------------------------------------------------
section "harness-init bootstraps the workflow labels"
HI="skills/harness-init/SKILL.md"
for l in map prd ready-for-agent needs-human needs-triage; do
  grep -qE -- "gh label create $l( |\$)" "$HI" \
    && ok "harness-init creates label $l" || note "harness-init does not create label $l"
done
grep -q -- '--force' "$HI" && ok "harness-init label creation is idempotent (--force)" \
  || note "harness-init label creation is not idempotent (--force)"
grep -qiE 'without .?gh|no .?gh|skip.*label' "$HI" \
  && ok "harness-init degrades gracefully without gh/remote" \
  || note "harness-init label step lacks a graceful-degradation note"

# ---------------------------------------------------------------------------
section "deliver.sh flags <-> skills/deliver/SKILL.md"
DS="skills/deliver/deliver.sh"; DD="skills/deliver/SKILL.md"
# Every --flag in deliver.sh's argument case must appear in SKILL.md ...
RUNNER_FLAGS="$(awk '/^[[:space:]]*case "\$1" in/{c=1;next} c&&/^[[:space:]]*esac/{c=0} c' "$DS" \
  | grep -oE '^[[:space:]]*(-[a-z],?\|?)?--[a-z][a-z-]*' | grep -oE -- '--[a-z][a-z-]*' | sort -u)"
[[ -n "$RUNNER_FLAGS" ]] && ok "deliver.sh: found $(echo "$RUNNER_FLAGS" | wc -l | tr -d ' ') argument flags" \
  || note "deliver.sh: could not extract argument flags"
for f in $RUNNER_FLAGS; do
  [[ "$f" == "--help" ]] && continue
  grep -qE -- "${f}([^a-z-]|\$)" "$DD" && ok "SKILL.md mentions $f" || note "SKILL.md does not mention deliver.sh flag $f"
done
# ... and a flag in a SKILL.md deliver.sh command block must be one the runner accepts.
DOC_FLAGS="$(awk '/^[[:space:]]*```/{if(b&&blk~/deliver\.sh/)printf "%s",blk; b=!b; blk=""; next} b{blk=blk $0 "\n"}' "$DD" \
  | grep -oE -- '--[a-z][a-z-]*' | sort -u)"
for f in $DOC_FLAGS; do
  echo "$RUNNER_FLAGS" | grep -qx -- "$f" && ok "SKILL.md's $f is accepted by deliver.sh" \
    || note "SKILL.md documents $f, which deliver.sh does not accept"
done

# ---------------------------------------------------------------------------
section "harness-doctor names the deliver readiness checks"
HD="skills/harness-doctor/SKILL.md"
for pat in 'command -v tmux' 'setsid nohup' 'command -v jq' 'gh auth status' 'gh label list' 'git check-ignore -q tmp/'; do
  grep -qF -- "$pat" "$HD" && ok "harness-doctor names '$pat'" || note "harness-doctor does not name '$pat'"
done
for l in map prd ready-for-agent needs-human needs-triage; do
  grep -qF -- "\`$l\`" "$HD" && ok "harness-doctor names label $l" || note "harness-doctor does not name label $l"
done

# ---------------------------------------------------------------------------
section "architecture docs describe the two-level model"
AR="docs/architecture.md"
for pat in 'agent.sh' 'ADR-0007' '/deliver'; do
  grep -qF -- "$pat" "$AR" && ok "architecture.md mentions $pat" || note "architecture.md does not mention $pat"
done
# The Stop gate is not wired into loop.sh — SKILL.md must offer it as a manual
# option, not describe the runner registering/removing the hook.
if grep -qE 'autopilot MAY register|MUST remove that' skills/autopilot/SKILL.md; then
  note "autopilot SKILL.md still presents the Stop gate as implemented"
else
  ok "autopilot SKILL.md no longer presents the Stop gate as implemented"
fi
grep -qi 'manual' <(sed -n '/Stop gate/,$p' skills/autopilot/SKILL.md) \
  && ok "autopilot SKILL.md Stop gate paragraph is a manual option" \
  || note "autopilot SKILL.md Stop gate paragraph does not say it is manual"

# ---------------------------------------------------------------------------
section "own-skill inventories list every non-vendored skill"
SYNC="docs/pocock-sync-log.md"
README_OWN="$(grep -E '^\| \*\*Skills \(own' README.md || true)"
CLAUDE_OWN="$(awk '/^3\. \*\*Own\*\*/{b=1} b&&/Plus agents/{exit} b{print}' .claude/CLAUDE.md)"
DOCTOR_OWN="$(awk '/^- Own:/{b=1} b&&/^$/{exit} b{print}' skills/harness-doctor/SKILL.md)"
for d in skills/*/; do
  n="$(basename "$d")"
  grep -qE "^\| ${n} \|" "$SYNC" && continue   # vendored (Pocock or Vercel table)
  for pair in "README:$README_OWN" ".claude/CLAUDE.md:$CLAUDE_OWN" "harness-doctor:$DOCTOR_OWN"; do
    name="${pair%%:*}"; text="${pair#*:}"
    grep -qF -- "\`$n\`" <<<"$text" && ok "$name lists own skill $n" || note "$name own-skill list omits $n"
  done
done
grep -qF 'integration/<slug>' .claude/CLAUDE.md && ok ".claude/CLAUDE.md branch model covers integration branches" \
  || note ".claude/CLAUDE.md branch model does not cover integration/<slug> branches"

# ---------------------------------------------------------------------------
section "user guide pages: version + Deliver path + no external assets"
PV="$(jq -r .version .claude-plugin/plugin.json)"
for f in docs/guide.html docs/index.html; do
  grep -qF -- "v$PV" "$f" && ok "$f shows v$PV" || note "$f does not show plugin.json version v$PV"
  if grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' "$f" | grep -vqxF "v$PV"; then note "$f mentions a stale version string"; fi
  if grep -qE '<(script|img|iframe|link)[^>]*(src|href)=|rel="stylesheet"' "$f"; then
    note "$f loads an external asset"
  else
    ok "$f loads no external assets"
  fi
done
grep -qF 'id="deliver"' docs/guide.html && grep -qF '/deliver' docs/guide.html \
  && ok "guide.html has a Deliver a map path" || note "guide.html lacks a Deliver a map path (id=\"deliver\")"

echo
if [[ "$FAIL" -eq 0 ]]; then echo "check-consistency: PASS"; else echo "check-consistency: FAIL"; fi
exit "$FAIL"
