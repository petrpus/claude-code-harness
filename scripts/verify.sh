#!/usr/bin/env bash
# scripts/verify.sh — the harness's own Verify command.
#
# The harness demands an objective Verify gate from consumer projects; this is
# ours. The autopilot loop and any contributor run it before opening a PR.
# Offline layers, in the order they run (see the `section` headings below for
# the current list — the ones worth calling out here):
#   1. scripts/check-consistency.sh — structural invariants (skills, sync-log,
#      version==changelog, hooks.json form + resolution, skill/agent
#      frontmatter lint and listing budget, plugin name + renames map, and
#      `claude plugin validate --strict` when the CLI is on PATH, …).
#   2. Hook test matrix — each guard hook is fed representative stdin-JSON and
#      its exit code asserted (block cases exit 2, allow cases exit 0), per the
#      stdin-JSON / exit-2 contract in docs/architecture.md § Hook contract.
#   3. docs cross-references — every relative markdown link inside docs/adr/*.md
#      must resolve to a file that actually exists.
#   4. repo-map contract — scripts/test-repo-map.sh builds a fixture tree and
#      asserts skills/repo-map/build-repo-map.sh + query.sh's output against
#      Schema v1, the five queries, staleness, and the Graphify adapter.
#   5. code-map renders repo-map — skills/code-map/SKILL.md must point at
#      tmp/repo-map.json + the repo-map generator, not run its own import scan.
#   6. Fault injection, two contracts. scripts/test-fault-injection.sh sweeps
#      the repo-map generator: a broken tool must never yield a wrong graph at
#      exit 0. scripts/test-hook-faults.sh sweeps the hooks, where the contract
#      is inverted — they fail OPEN by design, so what must never happen is
#      failing open *silently*.
#   7. scripts/test-autopilot-loop.sh — drives loop.sh end-to-end against a
#      stub `claude`, so the runner's gating decisions are exercised for free.
#      scripts/test-deliver.sh does the same for skills/deliver/deliver.sh,
#      against a bare git remote and a fake `gh`.
#   8. bash -n over hooks/*.sh, scripts/*.sh, skills/**/*.sh — a syntax floor
#      that stands even if check-consistency's own walk regresses.
#
# On success writes tmp/.last-verify-status ("ok") in the format the freshness
# hooks read (hooks/pre-commit-gate.sh, hooks/on-stop.sh), so their staleness
# warnings stop firing after a green run. Non-zero exit on any failure. No
# network. Runnable from anywhere inside the repo.

set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 1

FAIL=0
# Same reason as in the test scripts: never let a caller's withheld-credential
# environment leak into verify's own checks (#83).
unset GH_CONFIG_DIR GIT_CONFIG_COUNT
# The loop and deliver suites run the way autopilot and /deliver run verify:
# with forge credentials withheld. A test that silently depends on the
# caller's environment then fails here, in CI, not only in a live run.
# shellcheck source=../skills/autopilot/agent.sh
. skills/autopilot/agent.sh
note() { echo "  ✗ $*"; FAIL=1; }
ok()   { echo "  ✓ $*"; }
section() { echo; echo "== $1 =="; }

# Temp git repos for the branch-dependent push guard (one on `main`, one on a
# feature branch), addressed via each case's .cwd so the matrix is deterministic
# regardless of the branch verify.sh itself runs on. Cleaned up on exit.
TMP_MAIN_REPO=""
TMP_FEAT_REPO=""
TMP_GATE_DIRS=()
cleanup() {
  [[ -n "$TMP_MAIN_REPO" && -d "$TMP_MAIN_REPO" ]] && rm -rf "$TMP_MAIN_REPO"
  [[ -n "$TMP_FEAT_REPO" && -d "$TMP_FEAT_REPO" ]] && rm -rf "$TMP_FEAT_REPO"
  local d
  for d in "${TMP_GATE_DIRS[@]:-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf "$d"; done
  agent_cleanup
  return 0
}
trap cleanup EXIT

# mk_gate_repo <status-or-"none"> <age-seconds> -> echoes a fresh temp git repo
# whose tmp/.last-verify-status holds <status> (skipped if "none"), with its
# mtime set <age-seconds> in the past. Used by the Stop-gate matrix below.
mk_gate_repo() {
  local status="$1" age="$2" repo
  repo="$(mktemp -d)"; TMP_GATE_DIRS+=("$repo")
  git -C "$repo" init -q >/dev/null 2>&1
  if [[ "$status" != "none" ]]; then
    mkdir -p "$repo/tmp"
    printf '%s\n' "$status" > "$repo/tmp/.last-verify-status"
    touch -d "@$(( $(date +%s) - age ))" "$repo/tmp/.last-verify-status" 2>/dev/null || true
  fi
  printf '%s' "$repo"
}

# ---------------------------------------------------------------------------
section "check-consistency"
if bash scripts/check-consistency.sh; then
  ok "check-consistency passed"
else
  note "check-consistency failed (see above)"
fi

# ---------------------------------------------------------------------------
section "hook test matrix"
# assert_hook <desc> <expected-exit> <hook-script> <stdin-json>
assert_hook() {
  local desc="$1" want="$2" hook="$3" json="$4" got
  printf '%s' "$json" | bash "$hook" >/dev/null 2>&1
  got=$?
  if [[ "$got" == "$want" ]]; then
    ok "$desc (exit $got)"
  else
    note "$desc: expected exit $want, got $got"
  fi
}

if ! command -v jq >/dev/null 2>&1; then
  echo "  (jq not available — guard hooks fail open without it; skipping matrix)"
else
  # A throwaway repo whose current branch is 'main', addressed via the hook's
  # .cwd field, so the push-from-main guard is exercised regardless of the
  # branch verify.sh itself runs on.
  TMP_MAIN_REPO="$(mktemp -d)"
  git -C "$TMP_MAIN_REPO" init -q >/dev/null 2>&1
  git -C "$TMP_MAIN_REPO" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
  MAIN_JSON_CWD="$(printf '%s' "$TMP_MAIN_REPO" | sed 's/\\/\\\\/g; s/"/\\"/g')"

  TMP_FEAT_REPO="$(mktemp -d)"
  git -C "$TMP_FEAT_REPO" init -q >/dev/null 2>&1
  git -C "$TMP_FEAT_REPO" symbolic-ref HEAD refs/heads/feat-x >/dev/null 2>&1
  FEAT_JSON_CWD="$(printf '%s' "$TMP_FEAT_REPO" | sed 's/\\/\\\\/g; s/"/\\"/g')"

  # pre-bash: blocks
  assert_hook "pre-bash blocks git push on main" 2 hooks/pre-bash.sh \
    "{\"cwd\":\"$MAIN_JSON_CWD\",\"tool_input\":{\"command\":\"git push\"}}"
  # Force-push cases run against the feature-branch repo so the block comes from
  # the force guard specifically, not the push-from-main guard (deterministic
  # regardless of the branch verify.sh itself runs on).
  assert_hook "pre-bash blocks force-push (feature branch)" 2 hooks/pre-bash.sh \
    "{\"cwd\":\"$FEAT_JSON_CWD\",\"tool_input\":{\"command\":\"git push --force\"}}"
  assert_hook "pre-bash segment-split catches cd && git push --force" 2 hooks/pre-bash.sh \
    "{\"cwd\":\"$FEAT_JSON_CWD\",\"tool_input\":{\"command\":\"cd sub && git push --force\"}}"
  # Short `-f`, in every position and bundled with another short option. The
  # bundled forms are the ones L1's deny used to catch only by accident, with a
  # glob so broad it also denied branches named `...-full` (issue #49); L1 is
  # anchored now, so L2 has to read a cluster for what it is.
  assert_hook "pre-bash blocks git push -f" 2 hooks/pre-bash.sh \
    "{\"cwd\":\"$FEAT_JSON_CWD\",\"tool_input\":{\"command\":\"git push -f origin x\"}}"
  assert_hook "pre-bash blocks trailing -f" 2 hooks/pre-bash.sh \
    "{\"cwd\":\"$FEAT_JSON_CWD\",\"tool_input\":{\"command\":\"git push origin x -f\"}}"
  assert_hook "pre-bash blocks bundled -fu" 2 hooks/pre-bash.sh \
    "{\"cwd\":\"$FEAT_JSON_CWD\",\"tool_input\":{\"command\":\"git push -fu origin x\"}}"
  assert_hook "pre-bash blocks bundled -uf" 2 hooks/pre-bash.sh \
    "{\"cwd\":\"$FEAT_JSON_CWD\",\"tool_input\":{\"command\":\"git push -uf origin x\"}}"
  assert_hook "pre-bash blocks broad rm -rf /" 2 hooks/pre-bash.sh \
    '{"tool_input":{"command":"rm -rf /"}}'
  assert_hook "pre-bash blocks broad rm -rf ~" 2 hooks/pre-bash.sh \
    '{"tool_input":{"command":"rm -rf ~"}}'
  # pre-bash: allows
  assert_hook "pre-bash allows plain ls" 0 hooks/pre-bash.sh \
    '{"tool_input":{"command":"ls -la"}}'
  assert_hook "pre-bash allows plain git push on a feature branch" 0 hooks/pre-bash.sh \
    "{\"cwd\":\"$FEAT_JSON_CWD\",\"tool_input\":{\"command\":\"git push\"}}"
  assert_hook "pre-bash allows --force-with-lease on a feature branch" 0 hooks/pre-bash.sh \
    "{\"cwd\":\"$FEAT_JSON_CWD\",\"tool_input\":{\"command\":\"git push --force-with-lease\"}}"
  # Issue #49's symptom: a branch name carrying '-f' is an operand, not a flag.
  # Only single-dash words are inspected, so these must stay allowed — and
  # --follow-tags must not be read as a force flag just because it contains 'f'.
  assert_hook "pre-bash allows pushing a branch named ...-full" 0 hooks/pre-bash.sh \
    "{\"cwd\":\"$FEAT_JSON_CWD\",\"tool_input\":{\"command\":\"git push -u origin feat/harness-roadmap-full-i18n\"}}"
  assert_hook "pre-bash allows pushing a branch named ...-first" 0 hooks/pre-bash.sh \
    "{\"cwd\":\"$FEAT_JSON_CWD\",\"tool_input\":{\"command\":\"git push -u origin fix/pre-bash-first-pass\"}}"
  assert_hook "pre-bash allows pushing a branch named ...-filter" 0 hooks/pre-bash.sh \
    "{\"cwd\":\"$FEAT_JSON_CWD\",\"tool_input\":{\"command\":\"git push -u origin feat/search-filter\"}}"
  assert_hook "pre-bash allows --follow-tags (contains 'f', not a force flag)" 0 hooks/pre-bash.sh \
    "{\"cwd\":\"$FEAT_JSON_CWD\",\"tool_input\":{\"command\":\"git push --follow-tags origin x\"}}"
  # A short option with an ATTACHED value swallows the rest of its token, so an
  # 'f' inside that value is not a force flag — the #49 false-positive class
  # reappearing one layer down if the cluster is searched instead of walked.
  assert_hook "pre-bash allows -o with an attached value containing 'f'" 0 hooks/pre-bash.sh \
    "{\"cwd\":\"$FEAT_JSON_CWD\",\"tool_input\":{\"command\":\"git push -oci.skip-if-forked=true origin x\"}}"
  # After a bare `--`, `-f` is a ref name, not the force flag.
  assert_hook "pre-bash allows a ref named -f after end-of-options" 0 hooks/pre-bash.sh \
    "{\"cwd\":\"$FEAT_JSON_CWD\",\"tool_input\":{\"command\":\"git push origin -- -f\"}}"

  # Forceful `git clean` deletes untracked files irreversibly. L1 can anchor
  # `-f` as its own token or at the head of a cluster, but not in the middle of
  # one, so `-df` / `-xdf` need this L2 backstop.
  assert_hook "pre-bash blocks git clean -df" 2 hooks/pre-bash.sh \
    '{"tool_input":{"command":"git clean -df"}}'
  assert_hook "pre-bash blocks git clean -xdf" 2 hooks/pre-bash.sh \
    '{"tool_input":{"command":"git clean -xdf"}}'
  assert_hook "pre-bash blocks git clean --force" 2 hooks/pre-bash.sh \
    '{"tool_input":{"command":"git clean --force"}}'
  assert_hook "pre-bash blocks git clean -fe (attached -e value)" 2 hooks/pre-bash.sh \
    '{"tool_input":{"command":"git clean -fe build"}}'
  assert_hook "pre-bash allows a git clean dry run" 0 hooks/pre-bash.sh \
    '{"tool_input":{"command":"git clean -nd"}}'
  assert_hook "pre-bash allows git clean -e with a value containing 'f'" 0 hooks/pre-bash.sh \
    '{"tool_input":{"command":"git clean -e dist/fixtures -d"}}'

  # A guard must read the command it was given, not the directory it runs in.
  # `for word in $after` glob-expanded `*`; in a directory holding a file called
  # `tag` that produced `origin tag`, which read as a tag-only push and skipped
  # the push-from-main guard for what is a plain branch push.
  TMP_GLOB_REPO="$(mktemp -d)"
  git -C "$TMP_GLOB_REPO" init -q >/dev/null 2>&1
  git -C "$TMP_GLOB_REPO" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
  : > "$TMP_GLOB_REPO/tag"
  GLOB_JSON_CWD="$(printf '%s' "$TMP_GLOB_REPO" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  assert_hook "pre-bash does not glob-expand a refspec into a fake tag push" 2 hooks/pre-bash.sh \
    "{\"cwd\":\"$GLOB_JSON_CWD\",\"tool_input\":{\"command\":\"git push origin *\"}}"

  # Tag pushes from main. A tag doesn't advance a branch, and blocking it broke
  # this repo's own release step (tag v0.x.0 on the merge commit on main). Needs
  # a repo with a real commit, tag and branch so the ambiguous bare-name form
  # can actually be resolved.
  TMP_TAG_REPO="$(mktemp -d)"; TMP_GATE_DIRS+=("$TMP_TAG_REPO")
  git -C "$TMP_TAG_REPO" init -q >/dev/null 2>&1
  git -C "$TMP_TAG_REPO" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
  printf 'x\n' > "$TMP_TAG_REPO/f"
  git -C "$TMP_TAG_REPO" add -A >/dev/null 2>&1
  git -C "$TMP_TAG_REPO" -c user.email=t@t.est -c user.name=test commit -q -m init
  git -C "$TMP_TAG_REPO" tag v9.9.9 >/dev/null 2>&1
  git -C "$TMP_TAG_REPO" branch relbranch >/dev/null 2>&1
  TAG_JSON_CWD="$(printf '%s' "$TMP_TAG_REPO" | sed 's/\\/\\\\/g; s/"/\\"/g')"

  assert_hook "pre-bash allows a bare tag name push from main" 0 hooks/pre-bash.sh \
    "{\"cwd\":\"$TAG_JSON_CWD\",\"tool_input\":{\"command\":\"git push origin v9.9.9\"}}"
  assert_hook "pre-bash allows refs/tags/... push from main" 0 hooks/pre-bash.sh \
    "{\"cwd\":\"$TAG_JSON_CWD\",\"tool_input\":{\"command\":\"git push origin refs/tags/v9.9.9\"}}"
  assert_hook "pre-bash allows --tags push from main" 0 hooks/pre-bash.sh \
    "{\"cwd\":\"$TAG_JSON_CWD\",\"tool_input\":{\"command\":\"git push origin --tags\"}}"
  assert_hook "pre-bash allows 'push origin tag <name>' from main" 0 hooks/pre-bash.sh \
    "{\"cwd\":\"$TAG_JSON_CWD\",\"tool_input\":{\"command\":\"git push origin tag v9.9.9\"}}"
  # …and everything that could still move a branch stays blocked.
  assert_hook "pre-bash blocks --follow-tags from main (pushes commits too)" 2 hooks/pre-bash.sh \
    "{\"cwd\":\"$TAG_JSON_CWD\",\"tool_input\":{\"command\":\"git push --follow-tags\"}}"
  assert_hook "pre-bash blocks a branch+tag push from main" 2 hooks/pre-bash.sh \
    "{\"cwd\":\"$TAG_JSON_CWD\",\"tool_input\":{\"command\":\"git push origin main v9.9.9\"}}"
  assert_hook "pre-bash blocks a non-tag ref that only looks like one" 2 hooks/pre-bash.sh \
    "{\"cwd\":\"$TAG_JSON_CWD\",\"tool_input\":{\"command\":\"git push origin relbranch\"}}"
  assert_hook "pre-bash still blocks force-pushing a tag from main" 2 hooks/pre-bash.sh \
    "{\"cwd\":\"$TAG_JSON_CWD\",\"tool_input\":{\"command\":\"git push --force origin refs/tags/v9.9.9\"}}"

  # Redirections are shell plumbing, not refs. Every test above was written
  # without one, so the guard shipped reading `2>&1` as a ref name: it counted
  # as an operand, git could not resolve a tag called "2>&1", and the release
  # step blocked in the form nearly everyone writes it. Caught by the v0.5.0
  # release, not by this matrix.
  assert_hook "pre-bash allows a tag push carrying 2>&1" 0 hooks/pre-bash.sh \
    "{\"cwd\":\"$TAG_JSON_CWD\",\"tool_input\":{\"command\":\"git push origin v9.9.9 2>&1\"}}"
  assert_hook "pre-bash allows a tag push carrying 2>&1 and a pipe" 0 hooks/pre-bash.sh \
    "{\"cwd\":\"$TAG_JSON_CWD\",\"tool_input\":{\"command\":\"git push origin v9.9.9 2>&1 | tail -2\"}}"
  assert_hook "pre-bash allows a tag push redirected to /dev/null" 0 hooks/pre-bash.sh \
    "{\"cwd\":\"$TAG_JSON_CWD\",\"tool_input\":{\"command\":\"git push origin refs/tags/v9.9.9 >/dev/null\"}}"
  # …and dropping redirections must not let a branch push through with one.
  assert_hook "pre-bash still blocks a branch push carrying 2>&1" 2 hooks/pre-bash.sh \
    "{\"cwd\":\"$TAG_JSON_CWD\",\"tool_input\":{\"command\":\"git push origin main 2>&1\"}}"
  assert_hook "pre-bash still blocks a bare push carrying 2>&1" 2 hooks/pre-bash.sh \
    "{\"cwd\":\"$TAG_JSON_CWD\",\"tool_input\":{\"command\":\"git push 2>&1 | tail -2\"}}"

  # pre-edit: blocks
  assert_hook "pre-edit blocks .env" 2 hooks/pre-edit.sh \
    '{"tool_input":{"file_path":"/repo/.env"}}'
  assert_hook "pre-edit blocks package-lock.json" 2 hooks/pre-edit.sh \
    '{"tool_input":{"file_path":"/repo/package-lock.json"}}'
  assert_hook "pre-edit blocks pnpm-lock.yaml" 2 hooks/pre-edit.sh \
    '{"tool_input":{"file_path":"/repo/pnpm-lock.yaml"}}'
  # pre-edit: allows
  assert_hook "pre-edit allows .env.example" 0 hooks/pre-edit.sh \
    '{"tool_input":{"file_path":"/repo/.env.example"}}'
  # .env.test carries test-environment defaults and is committed, so it has to
  # be writable — L1's deny no longer swallows it and L2 must agree (#50).
  assert_hook "pre-edit allows .env.test" 0 hooks/pre-edit.sh \
    '{"tool_input":{"file_path":"/repo/.env.test"}}'
  assert_hook "pre-edit allows a nested .env.test" 0 hooks/pre-edit.sh \
    '{"tool_input":{"file_path":"/repo/apps/web/.env.test"}}'
  assert_hook "pre-edit allows a normal source file" 0 hooks/pre-edit.sh \
    '{"tool_input":{"file_path":"/repo/src/index.ts"}}'
  # `.local` is the conventional marker for the uncommitted, secret-bearing
  # variant — widening the allow list must not reach it.
  assert_hook "pre-edit blocks .env.test.local" 2 hooks/pre-edit.sh \
    '{"tool_input":{"file_path":"/repo/.env.test.local"}}'
  assert_hook "pre-edit blocks .env.local" 2 hooks/pre-edit.sh \
    '{"tool_input":{"file_path":"/repo/.env.local"}}'
  assert_hook "pre-edit blocks .env.production" 2 hooks/pre-edit.sh \
    '{"tool_input":{"file_path":"/repo/.env.production"}}'

  # require-verify-before-stop template (opt-in Stop gate) — same stdin-JSON
  # style: block while verify is missing/stale/not-ok, allow when fresh + ok.
  GATE=templates/require-verify-before-stop.sh
  r_ok="$(mk_gate_repo ok 0)"
  r_missing="$(mk_gate_repo none 0)"
  r_fail="$(mk_gate_repo fail 0)"
  r_stale="$(mk_gate_repo ok 4000)"
  json_cwd() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  assert_hook "stop-gate allows fresh ok verify" 0 "$GATE" \
    "{\"hook_event_name\":\"Stop\",\"cwd\":\"$(json_cwd "$r_ok")\"}"
  assert_hook "stop-gate blocks when verify status missing" 2 "$GATE" \
    "{\"hook_event_name\":\"Stop\",\"cwd\":\"$(json_cwd "$r_missing")\"}"
  assert_hook "stop-gate blocks when verify status is fail" 2 "$GATE" \
    "{\"hook_event_name\":\"Stop\",\"cwd\":\"$(json_cwd "$r_fail")\"}"
  assert_hook "stop-gate blocks when verify is stale" 2 "$GATE" \
    "{\"hook_event_name\":\"Stop\",\"cwd\":\"$(json_cwd "$r_stale")\"}"
fi

# ---------------------------------------------------------------------------
section "docs cross-references"
if [[ -d docs/adr ]]; then
  while IFS= read -r adr; do
    adr_dir="$(dirname "$adr")"
    while IFS= read -r link; do
      [[ -z "$link" ]] && continue
      case "$link" in
        http://*|https://*|\#*) continue ;;
      esac
      target="${link%%#*}"
      [[ -z "$target" ]] && continue
      if [[ -f "$adr_dir/$target" ]]; then
        ok "$adr: link to $link resolves"
      else
        note "$adr: link to $link does not resolve (looked for $adr_dir/$target)"
      fi
    done < <(grep -oE '\]\([^)]+\)' "$adr" | sed -E 's/^\]\((.*)\)$/\1/')
  done < <(find docs/adr -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort)

  if [[ -f docs/adr/0004-graphify-as-optional-repo-map-backend.md ]]; then
    ok "docs/adr/0004-graphify-as-optional-repo-map-backend.md exists"
    if grep -q '0001-repo-map-as-file-not-mcp.md' docs/adr/0004-graphify-as-optional-repo-map-backend.md; then
      ok "ADR-0004 references ADR-0001"
    else
      note "ADR-0004 does not reference 0001-repo-map-as-file-not-mcp.md"
    fi
  else
    note "docs/adr/0004-graphify-as-optional-repo-map-backend.md is missing"
  fi
else
  echo "  (docs/adr absent — skipping)"
fi

# ---------------------------------------------------------------------------
section "repo-map contract"
if [[ -f scripts/test-repo-map.sh ]]; then
  if bash scripts/test-repo-map.sh; then
    ok "repo-map contract passed"
  else
    note "repo-map contract failed (see above)"
  fi
else
  note "scripts/test-repo-map.sh is missing"
fi

# ---------------------------------------------------------------------------
# Same failure class as the generator sweep, inverted contract: hooks fail OPEN
# by design, so what must never happen is failing open *silently*.
section "hook fault injection"
if [[ -f scripts/test-hook-faults.sh ]]; then
  if bash scripts/test-hook-faults.sh; then
    ok "hook fault injection passed"
  else
    note "hook fault injection failed (see above)"
  fi
else
  note "scripts/test-hook-faults.sh is missing"
fi

# ---------------------------------------------------------------------------
# The loop had no test at all until its gating flaw shipped and made any plan
# longer than three slices impossible to finish. This drives it end-to-end with
# a stub `claude`, so the runner's decisions are exercised without spending.
section "autopilot loop control flow"
if [[ -f scripts/test-autopilot-loop.sh ]]; then
  if agent_run_without_forge_credentials bash scripts/test-autopilot-loop.sh; then
    ok "autopilot loop control flow passed"
  else
    note "autopilot loop control flow failed (see above)"
  fi
else
  note "scripts/test-autopilot-loop.sh is missing"
fi

# ---------------------------------------------------------------------------
# /deliver holds every forge operation (ADR-0007), so its tests run against a
# bare git remote and a fake gh — offline, and asserting on the commands the
# runner actually ran (no force push, no --admin, merges pinned to a head).
section "deliver runner (map → PR → merge)"
if [[ -f scripts/test-deliver.sh ]]; then
  if agent_run_without_forge_credentials bash scripts/test-deliver.sh; then
    ok "deliver runner passed"
  else
    note "deliver runner failed (see above)"
  fi
else
  note "scripts/test-deliver.sh is missing"
fi

# ---------------------------------------------------------------------------
# The same defect kept returning in different clothes — a dependency breaks and
# the generator writes a plausible, silently wrong map at exit 0. This sweeps
# the class instead of guarding its instances one at a time.
section "fault injection (silently-wrong-output class)"
if [[ -f scripts/test-fault-injection.sh ]]; then
  if bash scripts/test-fault-injection.sh; then
    ok "fault injection passed"
  else
    note "fault injection failed (see above)"
  fi
else
  note "scripts/test-fault-injection.sh is missing"
fi

# ---------------------------------------------------------------------------
# The BUILD phase's tool grants are a permission surface: a prefix grant derived
# from an interpreter ('bash scripts/verify.sh' -> Bash(bash:*)) would hand an
# unattended run arbitrary shell. Assert the derivation directly.
section "autopilot verify-command grants"
if [[ -f skills/autopilot/allowlist.sh ]]; then
  # shellcheck source=/dev/null
  . skills/autopilot/allowlist.sh
  grant_case() { # verify-cmd expected
    local got; got="$(verify_grants "$1")"
    [[ "$got" == "$2" ]] && ok "grants for '$1'" || note "grants for '$1': got '$got', want '$2'"
  }
  grant_case './scripts/verify.sh'   'Bash(./scripts/verify.sh),Bash(./scripts/verify.sh:*)'
  grant_case 'bash scripts/verify.sh' 'Bash(bash scripts/verify.sh)'
  grant_case '/bin/sh ci.sh'          'Bash(/bin/sh ci.sh)'
  grant_case 'make verify'            'Bash(make verify)'
  grant_case 'npm run verify'         'Bash(npm run verify)'
  grant_case '/usr/local/bin/ci --strict' 'Bash(/usr/local/bin/ci --strict),Bash(/usr/local/bin/ci:*)'
  for c in 'bash x.sh' 'make verify' 'npx foo'; do
    verify_grants_are_narrow "$c" && ok "narrow-grant detected for '$c'" \
      || note "'$c' was not reported as a narrow grant"
  done
  verify_grants_are_narrow './scripts/verify.sh' \
    && note "'./scripts/verify.sh' wrongly reported as narrow" \
    || ok "prefix grant kept for a direct script path"

  # detect_verify_cmd: project-type precedence (package.json -> scripts/
  # verify.sh -> Makefile), each exercised in its own throwaway temp dir so
  # no test's fixture files leak into another's.
  detect_case() { # desc setup want_cmd want_rc
    local desc="$1" setup="$2" want_cmd="$3" want_rc="$4"
    local d out rc
    d="$(mktemp -d)"
    ( cd "$d" && eval "$setup" ) >/dev/null 2>&1
    out="$(cd "$d" && detect_verify_cmd)"; rc=$?
    rm -rf "$d"
    if [[ "$out" == "$want_cmd" && "$rc" -eq "$want_rc" ]]; then
      ok "detect_verify_cmd: $desc"
    else
      note "detect_verify_cmd: $desc: got '$out' (rc=$rc), want '$want_cmd' (rc=$want_rc)"
    fi
    # A fixture that detects a command must get exactly that command's grant
    # from verify_grants, with no broad interpreter prefix (Bash(bash:*),
    # Bash(make:*)) that would hand BUILD arbitrary shell/make access.
    if [[ "$rc" -eq 0 ]]; then
      local grants; grants="$(verify_grants "$out")"
      if [[ "$grants" == *"Bash($out)"* && "$grants" != *'Bash(bash:*)'* && "$grants" != *'Bash(make:*)'* ]]; then
        ok "verify_grants for detected '$out': narrow"
      else
        note "verify_grants for detected '$out': got '$grants'"
      fi
    fi
  }
  detect_case 'npm project' \
    'printf "{\"scripts\":{\"verify\":\"echo x\"}}" > package.json' \
    'npm run verify' 0
  detect_case 'pnpm project (pnpm-lock.yaml present)' \
    'printf "{\"scripts\":{\"verify\":\"echo x\"}}" > package.json; touch pnpm-lock.yaml' \
    'pnpm verify' 0
  detect_case 'package.json without a verify script falls through to scripts/verify.sh' \
    'printf "{\"scripts\":{\"test\":\"echo x\"}}" > package.json; mkdir -p scripts; : > scripts/verify.sh' \
    'bash scripts/verify.sh' 0
  detect_case 'scripts/verify.sh (need not be executable)' \
    'mkdir -p scripts; : > scripts/verify.sh' \
    'bash scripts/verify.sh' 0
  detect_case 'Makefile with a verify: target' \
    'printf "verify:\n\techo x\n" > Makefile' \
    'make verify' 0
  detect_case 'Makefile without a verify: target (only verify-all:)' \
    'printf "verify-all:\n\techo x\n" > Makefile' \
    '' 1
  detect_case 'empty directory' '' '' 1
  detect_case 'package.json wins over scripts/verify.sh' \
    'printf "{\"scripts\":{\"verify\":\"echo x\"}}" > package.json; mkdir -p scripts; : > scripts/verify.sh' \
    'npm run verify' 0
else
  note "skills/autopilot/allowlist.sh is missing"
fi

# ---------------------------------------------------------------------------
# select_next_slice() is pure parsing over a checklist file — no `claude`
# call needed, so it's exercised directly here rather than via the stub-
# driven scripts/test-autopilot-loop.sh (loop.sh doesn't call it yet; that's
# S1B). Six shapes: a 0.4.0-era unannotated plan, a diamond DAG walked to
# completion, a cycle, an unknown blocker id, a parked slice whose dependent
# becomes unreachable, and the malformed-line corner cases from the S1A spec.
section "autopilot plan DAG (plan.sh)"
if [[ -f skills/autopilot/plan.sh ]]; then
  # shellcheck source=/dev/null
  . skills/autopilot/plan.sh
  PLAN_TEST_DIR="$(mktemp -d)"; TMP_GATE_DIRS+=("$PLAN_TEST_DIR")

  # -- linear unannotated plan: degrades to "first unchecked box" -----------
  cat > "$PLAN_TEST_DIR/linear.md" <<'EOF'
- [x] alpha task one
- [x] beta task two
- [ ] gamma task three
EOF
  GOT="$(select_next_slice "$PLAN_TEST_DIR/linear.md")"; RC=$?
  [[ "$RC" -eq 0 && "$GOT" == "gamma" ]] \
    && ok "unannotated plan selects the first unchecked box" \
    || note "unannotated plan: got rc=$RC id='$GOT', want rc=0 id=gamma"

  # -- diamond: S1 -> {S2,S3} -> S4, walked to completion --------------------
  cat > "$PLAN_TEST_DIR/diamond.md" <<'EOF'
- [ ] S1 — root (after: —)
- [ ] S2 — left (after: S1)
- [ ] S3 — right (after: S1)
- [ ] S4 — join (after: S2, S3)
EOF
  tick_id() { # file id
    sed -i "s/^- \[ \] $2 /- [x] $2 /" "$1"
  }
  GOT="$(select_next_slice "$PLAN_TEST_DIR/diamond.md")"
  [[ "$GOT" == "S1" ]] && ok "diamond: root selected first" \
    || note "diamond: got '$GOT', want S1"
  tick_id "$PLAN_TEST_DIR/diamond.md" S1
  GOT="$(select_next_slice "$PLAN_TEST_DIR/diamond.md")"
  [[ "$GOT" == "S2" ]] && ok "diamond: S2 selected once S1 is ticked (S3 not yet ready to run)" \
    || note "diamond: got '$GOT', want S2"
  tick_id "$PLAN_TEST_DIR/diamond.md" S2
  GOT="$(select_next_slice "$PLAN_TEST_DIR/diamond.md")"
  [[ "$GOT" == "S3" ]] && ok "diamond: S4 stays blocked until S3 also ticks" \
    || note "diamond: got '$GOT', want S3"
  tick_id "$PLAN_TEST_DIR/diamond.md" S3
  GOT="$(select_next_slice "$PLAN_TEST_DIR/diamond.md")"
  [[ "$GOT" == "S4" ]] && ok "diamond: S4 selected only after both S2 and S3" \
    || note "diamond: got '$GOT', want S4"
  tick_id "$PLAN_TEST_DIR/diamond.md" S4
  select_next_slice "$PLAN_TEST_DIR/diamond.md" >/dev/null; RC=$?
  [[ "$RC" -eq 1 ]] && ok "diamond: nothing left once every id is ticked (rc=1)" \
    || note "diamond: expected rc=1 once complete, got $RC"

  # -- cycle: A <-> B --------------------------------------------------------
  cat > "$PLAN_TEST_DIR/cycle.md" <<'EOF'
- [ ] A — (after: B)
- [ ] B — (after: A)
EOF
  MSG="$(select_next_slice "$PLAN_TEST_DIR/cycle.md")"; RC=$?
  [[ "$RC" -eq 2 && "$MSG" == plan_dag:*cycle* ]] \
    && ok "cycle: plan_dag failure (rc=2), bypassing the stuck ladder" \
    || note "cycle: got rc=$RC msg='$MSG', want rc=2 and a plan_dag/cycle message"

  # -- unknown blocker id -----------------------------------------------------
  cat > "$PLAN_TEST_DIR/unknown.md" <<'EOF'
- [ ] X — (after: GHOST)
EOF
  MSG="$(select_next_slice "$PLAN_TEST_DIR/unknown.md")"; RC=$?
  [[ "$RC" -eq 2 && "$MSG" == plan_dag:*GHOST* ]] \
    && ok "unknown blocker id: plan_dag failure (rc=2), names the bad id" \
    || note "unknown blocker: got rc=$RC msg='$MSG', want rc=2 naming GHOST"

  # -- parked slice: skipped, its dependent becomes unreachable --------------
  cat > "$PLAN_TEST_DIR/parked.md" <<'EOF'
- [x] S1 — root (after: —)
- [ ] S2 — parked sibling (after: S1)
- [ ] S3 — ready sibling (after: S1)
- [ ] S4 — join (after: S2, S3)
EOF
  GOT="$(select_next_slice "$PLAN_TEST_DIR/parked.md" S2)"; RC=$?
  [[ "$RC" -eq 0 && "$GOT" == "S3" ]] \
    && ok "parked slice is skipped; its unblocked sibling still runs" \
    || note "parked: got rc=$RC id='$GOT', want rc=0 id=S3"
  tick_id "$PLAN_TEST_DIR/parked.md" S3
  select_next_slice "$PLAN_TEST_DIR/parked.md" S2 >/dev/null; RC=$?
  [[ "$RC" -eq 3 ]] \
    && ok "parked slice's dependent is unreachable: replan signal (rc=3)" \
    || note "parked: expected rc=3 once only the parked chain remains, got $RC"

  # -- malformed lines: never crash, never falsely select ---------------------
  NOID="$(plan_parse_line '- [ ]')"
  [[ "$(printf '%s' "$NOID" | cut -f1)" == "" ]] \
    && ok "malformed: id-less checkbox parses to an empty (unselectable) id" \
    || note "malformed: '- [ ]' should parse to an empty id, got '$NOID'"

  EMPTYAFTER="$(plan_parse_line '- [ ] T1 (after:)')"
  [[ "$(printf '%s' "$EMPTYAFTER" | cut -f3)" == "" ]] \
    && ok "malformed: empty after: clause parses as unblocked" \
    || note "malformed: '(after:)' should leave no blockers, got '$EMPTYAFTER'"

  WHITESPACE="$(plan_parse_line '-   [ ]   T2   (after:   T1 )')"
  [[ "$(printf '%s' "$WHITESPACE" | cut -f1)" == "T2" && "$(printf '%s' "$WHITESPACE" | cut -f3)" == "T1" ]] \
    && ok "malformed: stray whitespace around id/after: is trimmed" \
    || note "malformed: stray whitespace not trimmed, got '$WHITESPACE'"

  TICKEDAFTER="$(plan_parse_line '- [x] T3 (after: T1)')"
  [[ "$(printf '%s' "$TICKEDAFTER" | cut -f2)" == "1" ]] \
    && ok "malformed: after: on an already-ticked line parses without error" \
    || note "malformed: ticked line with after: mis-parsed, got '$TICKEDAFTER'"

  # -- the two readers that address PLAN_* globals directly -------------------
  # Both were the only uncovered functions in plan.sh and both died under
  # `set -u` when called before any plan_load(). A reader that dies inside
  # `$(...)` echoes nothing, so DAG_WIDTH would have gone silently empty
  # rather than loudly wrong. Called in a fresh `bash -u` so a plan_load()
  # earlier in THIS file cannot mask a regression.
  COLD_W="$(bash -uo pipefail -c '. skills/autopilot/plan.sh; plan_dag_width ""' 2>/dev/null)"
  [[ "$COLD_W" == "0" ]] \
    && ok "plan_dag_width without plan_load: answers 0, does not crash under set -u" \
    || note "plan_dag_width before plan_load should echo 0, got '$COLD_W'"

  bash -uo pipefail -c '. skills/autopilot/plan.sh; plan_selected_line S1' >/dev/null 2>&1; RC=$?
  [[ "$RC" -eq 1 ]] \
    && ok "plan_selected_line without plan_load: rc=1 (not found), does not crash" \
    || note "plan_selected_line before plan_load should exit 1, got $RC"

  # -- plan_dag_width counts what select_next_slice() could have chosen -------
  cat > "$PLAN_TEST_DIR/width.md" <<'WEOF'
- [x] W1 — root (after: —)
- [ ] W2 — left (after: W1)
- [ ] W3 — right (after: W1)
- [ ] W4 — join (after: W2, W3)
WEOF
  plan_load "$PLAN_TEST_DIR/width.md"
  [[ "$(plan_dag_width "")" == "2" ]] \
    && ok "plan_dag_width: diamond with the root ticked offers 2 candidates" \
    || note "plan_dag_width: expected 2 unblocked candidates, got '$(plan_dag_width "")'"
  [[ "$(plan_dag_width "W2")" == "1" ]] \
    && ok "plan_dag_width: parking one sibling drops the width to 1" \
    || note "plan_dag_width: parking W2 should leave 1, got '$(plan_dag_width "W2")'"
  [[ "$(plan_selected_line W3)" == *"right"* ]] \
    && ok "plan_selected_line: returns the unticked row's own wording" \
    || note "plan_selected_line W3 did not return its row"
  plan_selected_line W1 >/dev/null 2>&1 \
    && note "plan_selected_line should not return a ticked row (W1)" \
    || ok "plan_selected_line: a ticked row is not selectable"
else
  note "skills/autopilot/plan.sh is missing"
fi

section "autopilot run aggregates (run_aggregates)"
# mean_dag_width is an average, so an iteration that never measured width must
# leave the sample rather than enter it as 0. The real 0.5.0 run reported 0.67
# across six iterations that every one measured 1, because three earlier
# iterations predating the metric were read as zeros. The loop test's own plan
# is width 1 throughout, so only a MIXED log exposes this.
AGG_DIR="$(mktemp -d)"
AGG_LOG="$AGG_DIR/run-test.jsonl"
{
  printf '%s\n' '{"phase":"iteration","ticked_delta":1,"gate_failed":"none"}'
  printf '%s\n' '{"phase":"iteration","ticked_delta":1,"gate_failed":"none"}'
  printf '%s\n' '{"phase":"iteration","ticked_delta":1,"gate_failed":"none","dag_width":2}'
  printf '%s\n' '{"phase":"iteration","ticked_delta":1,"gate_failed":"none","dag_width":4}'
} > "$AGG_LOG"

AGG_OUT="$(RUN_LOG="$AGG_LOG" TOTAL_COST=8 bash -c '
  RUN_LOG="$1"; TOTAL_COST="$2"
  eval "$(sed -n "/^run_aggregates() {/,/^}$/p" skills/autopilot/loop.sh)"
  run_aggregates' _ "$AGG_LOG" 8 2>/dev/null)"

AGG_MEAN="$(printf '%s' "$AGG_OUT" | jq -r '.mean_dag_width' 2>/dev/null)"
[[ "$AGG_MEAN" == "3" ]] \
  && ok "mean_dag_width averages only measured iterations (2,4 -> 3, not 1.5)" \
  || note "mean_dag_width over a mixed log should be 3, got '$AGG_MEAN'"

AGG_ITERS="$(printf '%s' "$AGG_OUT" | jq -r '.iterations' 2>/dev/null)"
[[ "$AGG_ITERS" == "4" ]] \
  && ok "iterations still counts every iteration, measured or not" \
  || note "iterations should be 4, got '$AGG_ITERS'"

: > "$AGG_LOG"
EMPTY_AGG="$(RUN_LOG="$AGG_LOG" bash -c '
  RUN_LOG="$1"; TOTAL_COST=0
  eval "$(sed -n "/^run_aggregates() {/,/^}$/p" skills/autopilot/loop.sh)"
  run_aggregates' _ "$AGG_LOG" 2>/dev/null | jq -r '.mean_dag_width' 2>/dev/null)"
[[ "$EMPTY_AGG" == "0" ]] \
  && ok "an empty run log still aggregates to 0, never an error" \
  || note "empty log should give mean_dag_width 0, got '$EMPTY_AGG'"
rm -rf "$AGG_DIR"

# ---------------------------------------------------------------------------
section "autopilot per-slice ladder state (slices.sh)"
if [[ -f skills/autopilot/slices.sh ]]; then
  # shellcheck source=/dev/null
  . skills/autopilot/slices.sh
  SLICES_TEST_DIR="$(mktemp -d)"; TMP_GATE_DIRS+=("$SLICES_TEST_DIR")
  SLICES_TEST_FILE="$SLICES_TEST_DIR/slices.json"

  # -- missing file reconciles to "nothing has failed yet" (contract item 8) -
  GOT="$(slices_read "$SLICES_TEST_FILE")"
  [[ "$(printf '%s' "$GOT" | jq -r '.slices')" == "{}" ]] \
    && ok "a missing slices.json reads as empty state, not an error" \
    || note "slices_read on a missing file returned '$GOT', want empty .slices"

  # -- reconcile: zero-inits new ids, preserves an existing id's counters ----
  STATE="$(slices_reconcile "$SLICES_TEST_FILE" A B)"
  FAILS_A="$(slices_get_fails "$STATE" A)"
  [[ "$FAILS_A" == "0" ]] \
    && ok "reconcile zero-inits a brand-new id" \
    || note "expected A to start at fails=0, got '$FAILS_A'"

  STATE="$(slices_record_fail "$STATE" A)"
  STATE="$(slices_record_fail "$STATE" A)"
  FAILS_A="$(slices_get_fails "$STATE" A)"
  [[ "$FAILS_A" == "2" ]] \
    && ok "slices_record_fail increments that id's counter (2 calls -> 2)" \
    || note "expected A to be at fails=2 after two record_fail calls, got '$FAILS_A'"

  # -- last_turn_limit: set by a turn-limit failure, cleared by a later one --
  [[ "$(slices_get_last_turn_limit "$STATE" A)" == "false" ]] \
    && ok "last_turn_limit defaults to false (record_fail without the flag)" \
    || note "expected last_turn_limit=false after plain record_fail"
  STATE="$(slices_record_fail "$STATE" A true)"
  [[ "$(slices_get_last_turn_limit "$STATE" A)" == "true" && "$(slices_get_fails "$STATE" A)" == "3" ]] \
    && ok "slices_record_fail <id> true sets last_turn_limit and still counts the fail" \
    || note "turn-limit record_fail: last_turn_limit='$(slices_get_last_turn_limit "$STATE" A)' fails='$(slices_get_fails "$STATE" A)'"
  STATE="$(slices_record_fail "$STATE" A false)"
  [[ "$(slices_get_last_turn_limit "$STATE" A)" == "false" ]] \
    && ok "a later non-turn-limit failure clears last_turn_limit" \
    || note "last_turn_limit should be cleared by a non-turn-limit failure"
  OLD_SHAPE='{"plan_sig":"","slices":{"Z":{"fails":1,"escalated":false,"parked":false}}}'
  [[ "$(slices_get_last_turn_limit "$OLD_SHAPE" Z)" == "false" \
    && "$(slices_get_last_turn_limit "$OLD_SHAPE" nope)" == "false" \
    && "$(slices_get_last_turn_limit 'not json' Z)" == "false" ]] \
    && ok "an old-shape/absent/corrupt record reads last_turn_limit as false" \
    || note "getter should read false for old-shape, unknown id and corrupt json"
  STATE="$(slices_record_fail "$STATE" A false)"
  STATE="$(printf '%s' "$STATE" | jq -c '.slices.A.fails = 2')"

  slices_write "$SLICES_TEST_FILE" "$STATE"
  STATE="$(slices_reconcile "$SLICES_TEST_FILE" A B)"
  FAILS_A="$(slices_get_fails "$STATE" A)"
  [[ "$FAILS_A" == "2" ]] \
    && ok "a re-read/reconcile against the same ids preserves the counter (no reset)" \
    || note "reconcile against unchanged ids reset A's fails to '$FAILS_A', want 2 preserved"

  # -- reconcile: an id no longer passed in (ticked, or dropped by a replan) -
  #    retires silently, even though it was never explicitly retired --------
  STATE="$(slices_reconcile "$SLICES_TEST_FILE" A)"
  HAS_B="$(printf '%s' "$STATE" | jq -r '.slices | has("B")' 2>/dev/null)"
  [[ "$HAS_B" == "false" ]] \
    && ok "reconcile drops an id that's no longer passed in (ticked/removed)" \
    || note "B should have been dropped by reconcile, still present: $STATE"

  # -- park: fails>=3 in loop.sh's own ladder, but slices_park() itself is ---
  #    a plain setter, exercised directly here -------------------------------
  STATE="$(slices_park "$STATE" A)"
  [[ "$(slices_parked_csv "$STATE")" == "A" ]] \
    && ok "slices_park marks the id parked; slices_parked_csv reflects it" \
    || note "expected parked_csv 'A', got '$(slices_parked_csv "$STATE")'"
  [[ "$(slices_parked_count "$STATE")" == "1" ]] \
    && ok "slices_parked_count counts exactly the parked ids (1)" \
    || note "expected parked_count 1, got '$(slices_parked_count "$STATE")'"

  # -- retire: an explicit removal, independent of reconcile -----------------
  STATE="$(slices_retire "$STATE" A)"
  [[ "$(slices_get_fails "$STATE" A)" == "0" ]] \
    && ok "slices_retire removes the record outright (a fresh read for A is 0)" \
    || note "expected A's record gone after retire, still shows fails=$(slices_get_fails "$STATE" A)"

  # -- clear: the whole file is gone, exactly what a rung-4 replan needs -----
  slices_write "$SLICES_TEST_FILE" "$(slices_reconcile "$SLICES_TEST_FILE" A B C)"
  [[ -f "$SLICES_TEST_FILE" ]] \
    && ok "sanity: slices.json exists before slices_clear" \
    || note "setup for the clear test failed to write $SLICES_TEST_FILE"
  slices_clear "$SLICES_TEST_FILE"
  [[ ! -f "$SLICES_TEST_FILE" ]] \
    && ok "slices_clear removes the file entirely (a replan unparks everything)" \
    || note "slices.json still exists after slices_clear"

  # -- a corrupt file degrades to empty state, never crashes -----------------
  printf 'not json' > "$SLICES_TEST_FILE"
  GOT="$(slices_read "$SLICES_TEST_FILE")"
  [[ "$(printf '%s' "$GOT" | jq -r '.slices')" == "{}" ]] \
    && ok "a corrupt slices.json degrades to empty state instead of erroring" \
    || note "corrupt slices.json produced '$GOT', want empty .slices"
else
  note "skills/autopilot/slices.sh is missing"
fi

# ---------------------------------------------------------------------------
# agent_run() (skills/autopilot/agent.sh) is the single model-call seam for
# loop.sh and /deliver. Its contract is "print nothing, leave the answer in
# AGENT_LAST_*" — the echo-your-answer contract it replaced let loop.sh drop
# every verifier call's cost in a `$(...)` subshell.
section "autopilot model-call core (agent.sh)"
AGENT_DIR="$(mktemp -d)"
mkdir -p "$AGENT_DIR/bin" "$AGENT_DIR/cwd"
cat > "$AGENT_DIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
pwd > "$AGENT_PWD_FILE"
printf '%s\n' "$*" > "$AGENT_ARGS_FILE"
case "${STUB_AGENT_MODE:-ok}" in
  ok)    printf '{"result":"hi there","total_cost_usd":0.25,"num_turns":2,"usage":{"input_tokens":3,"output_tokens":4,"cache_read_input_tokens":5}}\n' ;;
  fail)  echo "not json at all"; exit 3 ;;
  sleep) sleep 5 ;;
esac
STUB
chmod +x "$AGENT_DIR/bin/claude"
AGENT_REPO="$(pwd)"
AGENT_OUT="$(cd "$AGENT_DIR" && PATH="$AGENT_DIR/bin:$PATH" AGENT_PWD_FILE="$AGENT_DIR/pwd" AGENT_ARGS_FILE="$AGENT_DIR/args" bash -c '
  . "$1/skills/autopilot/agent.sh"
  AGENT_MAX_TURNS=7; AGENT_STDERR_LOG=rel-stderr.log; AGENT_DISALLOWED_TOOLS="Bash,Write"
  agent_run build sonnet "Read,Grep" acceptEdits "the prompt" "$2/cwd" > "$2/stdout"; rc=$?
  cp "$2/args" "$2/args.first" 2>/dev/null; cp "$2/pwd" "$2/pwd.first" 2>/dev/null
  printf "%s|%s|%s|%s|%s|%s|%s\n" "$rc" "$AGENT_LAST_RESULT" "$AGENT_LAST_COST" "$AGENT_LAST_IN_TOKENS" \
    "$AGENT_LAST_OUT_TOKENS" "$AGENT_LAST_TURNS" "$AGENT_LAST_CACHE_READ"
  STUB_AGENT_MODE=fail agent_run build sonnet "Read" acceptEdits "p"; rc=$?
  printf "%s|%s|%s\n" "$rc" "$AGENT_LAST_RESULT" "$AGENT_LAST_COST"
  AGENT_TIMEOUT=1 STUB_AGENT_MODE=sleep agent_run build sonnet "Read" acceptEdits "p"; echo "$?"
  rm -f "$2/args"; AGENT_DRY_RUN=1 agent_run plan opus "Read" acceptEdits "p" 2>/dev/null; rc=$?
  printf "%s|%s|%s\n" "$rc" "$AGENT_LAST_RESULT" "$([[ -f "$2/args" ]] && echo called || echo not-called)"
' _ "$AGENT_REPO" "$AGENT_DIR" 2>/dev/null)"
AGENT_L1="$(sed -n 1p <<<"$AGENT_OUT")"; AGENT_L2="$(sed -n 2p <<<"$AGENT_OUT")"
AGENT_L3="$(sed -n 3p <<<"$AGENT_OUT")"; AGENT_L4="$(sed -n 4p <<<"$AGENT_OUT")"
AGENT_ARGS_FIRST="$(cat "$AGENT_DIR/args.first" 2>/dev/null)"
[[ "$AGENT_L1" == "0|hi there|0.25|3|4|2|5" ]] \
  && ok "agent_run parses result, cost, tokens, turns and cache reads into AGENT_LAST_*" \
  || note "agent_run globals wrong: '$AGENT_L1'"
[[ -f "$AGENT_DIR/rel-stderr.log" && ! -e "$AGENT_DIR/cwd/rel-stderr.log" ]] \
  && ok "a relative AGENT_STDERR_LOG resolves against the caller's directory, not the call's cwd" \
  || note "relative AGENT_STDERR_LOG landed in the wrong place (or nowhere)"
[[ ! -s "$AGENT_DIR/stdout" ]] \
  && ok "agent_run prints nothing (callers read AGENT_LAST_RESULT, never \$(...))" \
  || note "agent_run wrote to stdout: $(head -c 80 "$AGENT_DIR/stdout")"
[[ "$(cat "$AGENT_DIR/pwd.first" 2>/dev/null)" == "$AGENT_DIR/cwd" ]] \
  && ok "agent_run runs claude in the given cwd" \
  || note "agent_run cwd was '$(cat "$AGENT_DIR/pwd" 2>/dev/null)'"
[[ "$AGENT_ARGS_FIRST" == *"--max-turns 7"* && "$AGENT_ARGS_FIRST" == *"--model sonnet"* && "$AGENT_ARGS_FIRST" == *"--allowedTools Read,Grep"* \
   && "$AGENT_ARGS_FIRST" == *"--disallowedTools Bash,Write"* ]] \
  && ok "agent_run passes model, allowlist, AGENT_MAX_TURNS and AGENT_DISALLOWED_TOOLS through" \
  || note "agent_run args were: '$AGENT_ARGS_FIRST'"
[[ "$AGENT_ARGS_FIRST" == *'--strict-mcp-config --mcp-config {"mcpServers":{}}'* ]] \
  && ok "agent_run starts no MCP servers (--strict-mcp-config with an empty --mcp-config)" \
  || note "agent_run args were: '$AGENT_ARGS_FIRST'"
[[ "$AGENT_L2" == "3||0" ]] \
  && ok "a failing call returns its exit code with empty result and zero cost" \
  || note "failing call: '$AGENT_L2' — expected '3||0'"
[[ "$AGENT_L3" == "124" ]] \
  && ok "AGENT_TIMEOUT bounds a hung call (exit 124)" \
  || note "hung call returned '$AGENT_L3', expected 124"
[[ "$AGENT_L4" == "0|dry-run|not-called" ]] \
  && ok "AGENT_DRY_RUN returns a zero-cost dry-run result without calling claude" \
  || note "dry run: '$AGENT_L4'"

# ADR-0007: the model call runs without forge credentials; the caller keeps
# its own. The stub reports what it sees; the caller's environment is checked
# after the call.
cat > "$AGENT_DIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
{
  echo "GH_TOKEN=${GH_TOKEN-<unset>}"
  echo "GITHUB_TOKEN=${GITHUB_TOKEN-<unset>}"
  echo "SSH_AUTH_SOCK=${SSH_AUTH_SOCK-<unset>}"
  echo "GH_CONFIG_DIR_EMPTY=$([[ -d "${GH_CONFIG_DIR:-/nonexistent}" && -z "$(ls -A "$GH_CONFIG_DIR")" ]] && echo yes || echo no)"
  echo "GIT_SSH_COMMAND=${GIT_SSH_COMMAND-<unset>}"
  echo "GIT_TERMINAL_PROMPT=${GIT_TERMINAL_PROMPT-<unset>}"
  echo "GIT_ASKPASS=${GIT_ASKPASS-<unset>}"
  echo "LAST_HELPER=[$(git config --get-all credential.helper | tail -1)]"
  echo "USER_NAME=$(git config --get user.name)"
  echo "BASH_TIMEOUTS=${BASH_DEFAULT_TIMEOUT_MS-<unset>}/${BASH_MAX_TIMEOUT_MS-<unset>}"
} > "$AGENT_ENV_FILE"
printf '{"result":"ok","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0}}\n'
STUB
chmod +x "$AGENT_DIR/bin/claude"
AGENT_CALLER="$(cd "$AGENT_DIR" && PATH="$AGENT_DIR/bin:$PATH" AGENT_ENV_FILE="$AGENT_DIR/env" \
  GH_TOKEN=caller-token GITHUB_TOKEN=caller-token2 SSH_AUTH_SOCK=/tmp/caller.sock \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=kept-by-env bash -c '
  . "$1/skills/autopilot/agent.sh"
  AGENT_TIMEOUT=900 AGENT_TRANSCRIPT_DIR="$2/calls" agent_run build sonnet "Read" acceptEdits "p"
  AGENT_TIMEOUT=900 AGENT_TRANSCRIPT_DIR="$2/calls" agent_run verify_agent haiku "Read" acceptEdits "p"
  echo "$GH_TOKEN|$SSH_AUTH_SOCK|${GH_CONFIG_DIR-<unset>}|$GIT_CONFIG_COUNT"
' _ "$AGENT_REPO" "$AGENT_DIR" 2>/dev/null)"
AGENT_ENV="$(cat "$AGENT_DIR/env" 2>/dev/null)"
grep -qx 'BASH_TIMEOUTS=900000/900000' <<<"$AGENT_ENV" \
  && ok "the model's Bash tool may run a command as long as the call itself (AGENT_TIMEOUT → BASH_*_TIMEOUT_MS)" \
  || note "Bash tool timeouts in the call: $(grep BASH_TIMEOUTS <<<"$AGENT_ENV")"
[[ -f "$AGENT_DIR/calls/001-build.md" && -f "$AGENT_DIR/calls/002-verify_agent.md" ]] \
  && grep -q '^ok$' "$AGENT_DIR/calls/001-build.md" && head -1 "$AGENT_DIR/calls/001-build.md" | grep -q 'build · model sonnet · exit 0' \
  && ok "AGENT_TRANSCRIPT_DIR keeps each call's reply as <seq>-<phase>.md" \
  || note "transcripts: $(ls "$AGENT_DIR/calls" 2>/dev/null | tr '\n' ' ')"
AGENT_SEQ2="$(cd "$AGENT_DIR" && PATH="$AGENT_DIR/bin:$PATH" AGENT_ENV_FILE=/dev/null bash -c '
  . "$1/skills/autopilot/agent.sh"; AGENT_TRANSCRIPT_DIR="$2/calls" agent_run plan opus "Read" acceptEdits "p"
  ls "$2/calls" | tr "\n" " "' _ "$AGENT_REPO" "$AGENT_DIR" 2>/dev/null)"
[[ "$AGENT_SEQ2" == "001-build.md 002-verify_agent.md 003-plan.md " ]] \
  && ok "a new process continues the numbering instead of overwriting earlier replies" \
  || note "transcript numbering across processes: '$AGENT_SEQ2'"
grep -qx 'GH_TOKEN=<unset>' <<<"$AGENT_ENV" && grep -qx 'GITHUB_TOKEN=<unset>' <<<"$AGENT_ENV" \
  && grep -qx 'SSH_AUTH_SOCK=<unset>' <<<"$AGENT_ENV" && grep -qx 'GH_CONFIG_DIR_EMPTY=yes' <<<"$AGENT_ENV" \
  && ok "the model call sees no gh token, no ssh agent and an empty gh config dir (ADR-0007)" \
  || note "model call env: $(tr '\n' ' ' <<<"$AGENT_ENV")"
grep -qx 'LAST_HELPER=\[\]' <<<"$AGENT_ENV" && grep -qx 'GIT_SSH_COMMAND=false' <<<"$AGENT_ENV" \
  && grep -qx 'GIT_TERMINAL_PROMPT=0' <<<"$AGENT_ENV" && grep -qx 'GIT_ASKPASS=false' <<<"$AGENT_ENV" \
  && grep -qx 'USER_NAME=kept-by-env' <<<"$AGENT_ENV" \
  && ok "git in the model call has its credential helpers cleared, no prompt, no ssh — earlier GIT_CONFIG_* entries kept" \
  || note "model call git env: $(tr '\n' ' ' <<<"$AGENT_ENV")"
[[ "$AGENT_CALLER" == "caller-token|/tmp/caller.sock|<unset>|1" ]] \
  && ok "the caller keeps its own credentials after the call" \
  || note "caller env after the call: '$AGENT_CALLER'"
# If the private gh dir cannot be made, credentials cannot be withheld: both
# entry points must refuse (125) and run nothing.
rm -f "$AGENT_DIR/env" "$AGENT_DIR/ran"
AGENT_REFUSE="$(cd "$AGENT_DIR" && PATH="$AGENT_DIR/bin:$PATH" AGENT_ENV_FILE="$AGENT_DIR/env" \
  TMPDIR="$AGENT_DIR/does-not-exist" bash -c '
  . "$1/skills/autopilot/agent.sh"
  agent_run build sonnet "Read" acceptEdits "p"; a=$?
  agent_run_without_forge_credentials touch "$2/ran"; b=$?; r1="$AGENT_REFUSED"
  unset TMPDIR; agent_run_without_forge_credentials bash -c "exit 125"; c=$?; r2="$AGENT_REFUSED"
  echo "$a|$b|$AGENT_LAST_RC|${AGENT_LAST_RESULT}|$r1|$c|$r2"
' _ "$AGENT_REPO" "$AGENT_DIR" 2>/dev/null)"
[[ "$AGENT_REFUSE" == "125|125|125||1|125|0" && ! -e "$AGENT_DIR/env" && ! -e "$AGENT_DIR/ran" ]] \
  && ok "no private dir → both entry points refuse (125, AGENT_REFUSED=1) and run nothing; a command's own 125 is not a refusal" \
  || note "refusal path: '$AGENT_REFUSE', model ran: $([[ -e "$AGENT_DIR/env" ]] && echo yes || echo no), command ran: $([[ -e "$AGENT_DIR/ran" ]] && echo yes || echo no)"
AGENT_CLEAN="$(cd "$AGENT_DIR" && bash -c '
  . "$1/skills/autopilot/agent.sh"; agent_noforge_dir; d="$AGENT_NOFORGE_DIR"; agent_cleanup
  [[ -n "$d" && ! -e "$d" ]] && echo removed' _ "$AGENT_REPO")"
[[ "$AGENT_CLEAN" == "removed" ]] && ok "agent_cleanup removes the private dir" || note "agent_cleanup left the dir"
rm -rf "$AGENT_DIR"

# ---------------------------------------------------------------------------
section "code-map renders repo-map"
CODE_MAP_SKILL="skills/code-map/SKILL.md"
if [[ -f "$CODE_MAP_SKILL" ]]; then
  if grep -q 'tmp/repo-map\.json' "$CODE_MAP_SKILL"; then
    ok "$CODE_MAP_SKILL references tmp/repo-map.json"
  else
    note "$CODE_MAP_SKILL does not reference tmp/repo-map.json"
  fi

  if grep -q 'skills/repo-map/build-repo-map\.sh' "$CODE_MAP_SKILL"; then
    ok "$CODE_MAP_SKILL references the repo-map generator"
  else
    note "$CODE_MAP_SKILL does not reference skills/repo-map/build-repo-map.sh"
  fi

  if grep -qE '^\s*rg ' "$CODE_MAP_SKILL"; then
    note "$CODE_MAP_SKILL still carries its own rg-based import-scan instructions"
  else
    ok "$CODE_MAP_SKILL carries no import-scan instructions of its own"
  fi
else
  note "$CODE_MAP_SKILL is missing"
fi

# ---------------------------------------------------------------------------
section "shell syntax (bash -n)"
while IFS= read -r f; do
  if err="$(bash -n "$f" 2>&1)"; then
    ok "$f"
  else
    note "$f has a syntax error: $err"
  fi
done < <(find hooks scripts skills templates -name '*.sh' -type f 2>/dev/null | sort)

# ---------------------------------------------------------------------------
# Record status for the freshness hooks (single status word; "ok" == green).
mkdir -p tmp
echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "ok" > tmp/.last-verify-status
  echo "verify: PASS"
else
  echo "fail" > tmp/.last-verify-status
  echo "verify: FAIL"
fi
exit "$FAIL"
