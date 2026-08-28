#!/usr/bin/env bash
# scripts/verify.sh — the harness's own Verify command.
#
# The harness demands an objective Verify gate from consumer projects; this is
# ours. The autopilot loop and any contributor run it before opening a PR.
# Offline layers, in the order they run (see the `section` headings below for
# the current list — the ones worth calling out here):
#   1. scripts/check-consistency.sh — structural invariants (skills, sync-log,
#      version==changelog, hooks.json resolves, …).
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
  assert_hook "pre-edit allows a normal source file" 0 hooks/pre-edit.sh \
    '{"tool_input":{"file_path":"/repo/src/index.ts"}}'

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
  if bash scripts/test-autopilot-loop.sh; then
    ok "autopilot loop control flow passed"
  else
    note "autopilot loop control flow failed (see above)"
  fi
else
  note "scripts/test-autopilot-loop.sh is missing"
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
else
  note "skills/autopilot/plan.sh is missing"
fi

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
