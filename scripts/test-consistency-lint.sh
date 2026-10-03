#!/usr/bin/env bash
# scripts/test-consistency-lint.sh — negative tests for check-consistency's
# 0.7.0 checks.
#
# verify.sh only ever runs scripts/check-consistency.sh on a clean tree, so the
# new checks — the skill/agent frontmatter lint, the plugin-name and renames-chain
# checks, the hooks.json command form, the CI validate step and the claude-CLI
# version gate — would pass even if they could never fail. This copies the repo,
# breaks the copy on purpose and asserts each break is reported; and it asserts
# the legitimate variants stay green: a two-hop renames chain (ADR-0014 is
# append-only), a second plugin in the marketplace, and a claude CLI too old for
# `plugin validate --strict` (skipped, not failed).
#
# It also runs every hooks.json command the way Claude Code runs a shell-form
# hook (`sh -c`), from a plugin path containing a space and with the exec bits
# stripped: the guards must still block (exit 2) and the advisory hooks must
# still exit 0.
#
# Invoked from scripts/verify.sh. Cleaned up on exit.

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1

FAIL=0
note() { echo "  ✗ $*"; FAIL=1; }
ok()   { echo "  ✓ $*"; }

if ! command -v jq >/dev/null 2>&1; then
  if [[ "${CI:-}" == "true" ]]; then note "jq is required in CI"; else echo "  (jq not available — skipping)"; fi
  exit "$FAIL"
fi
HAVE_YAML=0
command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1 && HAVE_YAML=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A Claude Code too old for `plugin validate --strict`: it answers --version and
# fails anything else, so a version gate that lets it through turns the run red.
SHIM="$WORK/shim"
mkdir -p "$SHIM"
cat > "$SHIM/claude" <<'SH'
#!/bin/sh
[ "$1" = "--version" ] && { echo "2.1.100 (Claude Code)"; exit 0; }
echo "error: unknown option '--strict'" >&2
exit 1
SH
chmod +x "$SHIM/claude"

# copy_repo <dir> — the tracked and untracked-but-not-ignored files, as a new repo.
copy_repo() {
  mkdir -p "$1"
  git ls-files -co --exclude-standard -z | tar --null -T - -cf - | tar -xf - -C "$1"
  git -C "$1" init -q
}

# run_check <repo> <out> — check-consistency with the old claude first on PATH.
run_check() {
  (cd "$1" && PATH="$SHIM:$PATH" bash scripts/check-consistency.sh) > "$2" 2>&1
}

# expect <out> <fixed string> <what>
expect() {
  grep -qF -- "$2" "$1" && ok "reported: $3" || note "not reported: $3 (looked for: $2)"
}

# json_set <file> <jq filter>
json_set() {
  local tmp="$1.tmp"
  jq "$2" "$1" > "$tmp" && mv "$tmp" "$1"
}

# skill_fixture <name> <frontmatter lines…>
skill_fixture() {
  local d="skills/$1"; shift
  mkdir -p "$d"
  { echo '---'; printf '%s\n' "$@"; echo '---'; echo; echo 'Fixture.'; } > "$d/SKILL.md"
}

# ---------------------------------------------------------------------------
# Legitimate variants stay green.
GOOD="$WORK/good"
copy_repo "$GOOD"
(
  cd "$GOOD" || exit 1
  json_set .claude-plugin/marketplace.json \
    '.renames = {"claude-code-harness": "code-harness-interim", "code-harness-interim": .plugins[0].name}
     | .plugins += [{"name": "design-harness", "source": "./design", "description": "fixture"}]'
)
if run_check "$GOOD" "$WORK/good.out"; then
  ok "a two-hop renames chain and a second marketplace plugin pass"
else
  note "check-consistency failed on legitimate variants:"
  grep -F '✗' "$WORK/good.out" | sed 's/^/    /'
fi
expect "$WORK/good.out" "claude 2.1.100 is older than" "an old claude CLI skips the validator instead of failing"

# ---------------------------------------------------------------------------
# Every break is reported.
BAD="$WORK/bad"
copy_repo "$BAD"
(
  cd "$BAD" || exit 1
  skill_fixture zz-bad-yaml   'name: zz-bad-yaml' 'description: Does things. Triggers: "x", "y".'
  skill_fixture zz-wrong-name 'name: other-name' 'description: Fixture.'
  skill_fixture zz-typo-key   'name: zz-typo-key' 'description: Fixture.' 'allowed_tools: Bash'
  skill_fixture zz-long-desc  'name: zz-long-desc' "description: $(printf 'x%.0s' $(seq 1 1100))"
  skill_fixture zz-user-only  'name: zz-user-only' 'description: Fixture.' 'disable-model-invocation: true'
  sed -i.bak '/^disable-model-invocation: true$/d' skills/deliver/SKILL.md && rm -f skills/deliver/SKILL.md.bak
  sed -i.bak 's/^model: haiku$/modle: haiku/' agents/verifier.md && rm -f agents/verifier.md.bak
  # shellcheck disable=SC2016 — the placeholder is literal.
  json_set hooks/hooks.json '.hooks.PreToolUse[0].hooks[0].command = "${CLAUDE_PLUGIN_ROOT}/hooks/pre-edit.sh"'
  json_set .claude-plugin/marketplace.json 'del(.renames)'
  json_set .claude-plugin/plugin.json '.name = "claude-tools"'
  : > CLAUDE.md
  sed -i.bak '/plugin validate/d' .github/workflows/verify.yml && rm -f .github/workflows/verify.yml.bak
)
if run_check "$BAD" "$WORK/bad.out"; then
  note "check-consistency passed on a deliberately broken tree"
else
  ok "check-consistency fails on the broken tree"
fi
expect "$WORK/bad.out" "plugin name 'claude-tools' is reserved" "a reserved plugin name"
expect "$WORK/bad.out" "marketplace has no plugins[] entry named 'claude-tools'" "plugin.json and marketplace out of step"
expect "$WORK/bad.out" "renames chain from claude-code-harness ends at" "a deleted renames entry"
expect "$WORK/bad.out" "CLAUDE.md is back at the plugin root" "a CLAUDE.md at the plugin root"
expect "$WORK/bad.out" "hooks.json command is not in the bash" "an unquoted hooks.json command"
expect "$WORK/bad.out" "no longer runs claude plugin validate --strict" "the CI validate step removed"
if [[ "$HAVE_YAML" -eq 1 ]]; then
  expect "$WORK/bad.out" "skills/zz-bad-yaml/SKILL.md: frontmatter is not valid YAML" "invalid YAML frontmatter"
  expect "$WORK/bad.out" "name 'other-name' != directory 'zz-wrong-name'" "name != directory"
  expect "$WORK/bad.out" "unknown frontmatter key(s) ['allowed_tools']" "an unknown skill key"
  expect "$WORK/bad.out" "zz-long-desc/SKILL.md: description is 1100 chars" "a description over 1024 characters"
  expect "$WORK/bad.out" "zz-user-only/SKILL.md: disable-model-invocation outside" "the flag outside the ADR-0015 set"
  expect "$WORK/bad.out" "skills/deliver/SKILL.md: must carry disable-model-invocation" "a runner without the flag"
  expect "$WORK/bad.out" "unknown agent frontmatter key(s) ['modle']" "an unknown agent key"
  expect "$WORK/bad.out" "always-on skill descriptions are" "the listing budget overrun"
elif [[ "${CI:-}" == "true" ]]; then
  note "python3 + PyYAML are required in CI for the frontmatter-lint assertions"
else
  echo "  (python3/PyYAML not available — skipping the frontmatter-lint assertions)"
fi

# ---------------------------------------------------------------------------
# hooks.json commands, run as Claude Code runs them, from an awkward plugin path.
ROOT="$WORK/plugin root"
mkdir -p "$ROOT"
cp -R hooks "$ROOT/"
chmod a-x "$ROOT"/hooks/*.sh
MAIN_REPO="$WORK/mainrepo"
git init -q "$MAIN_REPO"
git -C "$MAIN_REPO" symbolic-ref HEAD refs/heads/main
CWD_JSON="$(printf '%s' "$MAIN_REPO" | sed 's/\\/\\\\/g; s/"/\\"/g')"
while IFS= read -r cmd; do
  name="${cmd%\"}"; name="${name##*/}"
  case "$name" in
    pre-bash.sh) input="{\"cwd\":\"$CWD_JSON\",\"tool_input\":{\"command\":\"git push\"}}"; want=2 ;;
    pre-edit.sh) input="{\"cwd\":\"$CWD_JSON\",\"tool_input\":{\"file_path\":\"$CWD_JSON/.env\"}}"; want=2 ;;
    *)           input="{\"cwd\":\"$CWD_JSON\",\"tool_input\":{\"command\":\"ls\"}}"; want=0 ;;
  esac
  printf '%s' "$input" | CLAUDE_PLUGIN_ROOT="$ROOT" sh -c "$cmd" >/dev/null 2>&1
  got=$?
  [[ "$got" == "$want" ]] && ok "$name runs from a spaced, non-exec plugin path (exit $got)" \
    || note "$name from a spaced, non-exec plugin path: expected exit $want, got $got"
done < <(jq -r '.hooks[][]?.hooks[]?.command' hooks/hooks.json)

echo
if [[ "$FAIL" -eq 0 ]]; then echo "test-consistency-lint: PASS"; else echo "test-consistency-lint: FAIL"; fi
exit "$FAIL"
