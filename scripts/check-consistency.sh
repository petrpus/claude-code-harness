#!/usr/bin/env bash
# scripts/check-consistency.sh — self-verify for the claude-code-harness repo.
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
section "version == changelog top entry"
PV="$(jq -r '.version' .claude-plugin/plugin.json 2>/dev/null || echo '?')"
CV="$(grep -m1 -oE '## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo '?')"
[[ "$PV" == "$CV" ]] && ok "plugin.json $PV == CHANGELOG $CV" \
  || note "plugin.json version ($PV) != CHANGELOG top ($CV)"

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
section "every hooks.json command resolves to an existing file"
if command -v jq >/dev/null 2>&1; then
  while IFS= read -r cmd; do
    rel="${cmd/\$\{CLAUDE_PLUGIN_ROOT\}\//}"
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

echo
if [[ "$FAIL" -eq 0 ]]; then echo "check-consistency: PASS"; else echo "check-consistency: FAIL"; fi
exit "$FAIL"
