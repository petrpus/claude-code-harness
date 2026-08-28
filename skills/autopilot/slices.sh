#!/usr/bin/env bash
# skills/autopilot/slices.sh — S4A: runner-owned per-slice ladder state,
# tmp/autopilot/slices.json. Sourced by loop.sh alongside plan.sh/allowlist.sh
# — own file so the state machine is unit-testable without a run (scripts/
# verify.sh exercises it directly), same split as those two.
#
# This file is never named in any prompt (PLAN, BUILD and the verifier never
# see its path or content) — it drives the runner's own retry/park/replan
# bookkeeping, the opposite direction from HOLDOUT.md's "hidden by location"
# (docs/adr/0006-*.md): that file hides a test from the model, this one hides
# the runner's own scorekeeping, which the model has no business editing
# either way.
#
# Schema (docs/adr/0005-*.md decision 6 / PRD § S4):
#   {"plan_sig": "<cksum of the ordered slice ids>",
#    "slices": {"<id>": {"fails": <n>, "escalated": <bool>, "parked": <bool>}}}
# `plan_sig` is informational only — a human-readable signal that the file
# was last reconciled against a particular id sequence. Reconciliation itself
# never trusts it: every read walks the CURRENT plan's ids directly and
# drops/zero-inits from that, so a human editing the plan mid-run can't desync
# the state even on a read where plan_sig happens to be stale.
#
# Escalation (`escalated`) is written and read here but not yet acted on —
# S4B wires `--escalate-model` against it. S4A's own ladder only drives
# `fails` (rung 1 "retry") and `parked` (rung 3, at fails>=3).

# slices_plan_sig <id...>
#   cksum over the ids in the order given (plan file order). Never consulted
#   by slices_reconcile()'s own logic — see the schema note above — but
#   recorded so a human inspecting the file can tell whether it was last
#   reconciled against the plan now on disk.
slices_plan_sig() {
  printf '%s\n' "$@" | cksum | awk '{print $1"-"$2}'
}

# slices_read <state_file>
#   Echoes the file's JSON content, or an empty-state object when the file is
#   missing or not a parseable `{"slices": {...}}` object. Contract item 8:
#   missing state is never an error, and a corrupt file degrades to empty
#   rather than crashing the run.
slices_read() {
  local f="$1" content
  if [[ -f "$f" ]]; then
    content="$(cat "$f" 2>/dev/null)"
    if printf '%s' "$content" | jq -e 'type=="object" and ((.slices // {})|type)=="object"' >/dev/null 2>&1; then
      printf '%s' "$content"
      return 0
    fi
  fi
  echo '{"plan_sig":"","slices":{}}'
}

# slices_reconcile <state_file> <id...>
#   Echoes the reconciled JSON: only ids present in the CURRENT plan are kept
#   (an id the plan no longer has retires silently — e.g. a replan rewrote
#   it away), every id not yet in the state gets a zero-initialised record,
#   and plan_sig is refreshed to the current ordered id list. Does NOT write
#   the file; the caller (loop.sh) does that right after, once per iteration,
#   so every subsequent read this iteration already sees the reconciled shape.
#   Empty/blank ids (an id-less checkbox line) are never tracked — there is
#   nothing to key a retry counter on.
slices_reconcile() {
  local f="$1"; shift
  local sig cur ids_json
  sig="$(slices_plan_sig "$@")"
  cur="$(slices_read "$f")"
  ids_json="$(printf '%s\n' "$@" | awk 'NF' | jq -R -s -c 'split("\n") | map(select(length>0)) | unique')"
  printf '%s' "$cur" | jq -c --argjson ids "$ids_json" --arg sig "$sig" '
    (.slices // {}) as $old
    | { plan_sig: $sig,
        slices: (reduce ($ids[]) as $id
                   ({}; . + { ($id): ($old[$id] // {fails:0, escalated:false, parked:false}) })) }
  ' 2>/dev/null || echo '{"plan_sig":"","slices":{}}'
}

# slices_write <state_file> <json>
slices_write() {
  local f="$1" json="$2"
  printf '%s' "$json" > "$f" 2>/dev/null || true
}

# slices_clear <state_file>
#   A replan invalidates every per-slice count — the plan itself just
#   changed, so a slice's prior failures may not even apply to the revised
#   item carrying that id anymore. Also the mechanism by which rung 4 ("all
#   remaining candidates parked or blocked → replan, unparking everything")
#   actually unparks: there is no separate "unpark" operation, the whole file
#   is gone and the next reconcile zero-inits every id fresh.
slices_clear() {
  local f="$1"
  rm -f "$f" 2>/dev/null || true
}

# slices_get_fails <json> <id> -> the fails count, 0 if absent.
slices_get_fails() {
  printf '%s' "$1" | jq -r --arg id "$2" '(.slices[$id].fails // 0)' 2>/dev/null || echo 0
}

# slices_record_fail <json> <id> -> echoes json with that id's fails +1
#   (rung 1: every failure, whatever its gate fingerprint, counts toward the
#   SAME slice's ladder — a slice flailing across three different gates is
#   exactly as stuck as one failing the same gate three times, ADR-0005).
slices_record_fail() {
  printf '%s' "$1" | jq -c --arg id "$2" '
    .slices[$id] //= {fails:0, escalated:false, parked:false}
    | .slices[$id].fails += 1
  ' 2>/dev/null || printf '%s' "$1"
}

# slices_park <json> <id> -> echoes json with that id's parked=true (rung 3).
slices_park() {
  printf '%s' "$1" | jq -c --arg id "$2" '
    .slices[$id] //= {fails:0, escalated:false, parked:false}
    | .slices[$id].parked = true
  ' 2>/dev/null || printf '%s' "$1"
}

# slices_retire <json> <id> -> echoes json with that id's record removed.
#   A ticked slice is done; its failure history is moot from here on — if the
#   same id is ever reused (it shouldn't be, ids are meant to be unique on an
#   annotated plan), it starts fresh.
slices_retire() {
  printf '%s' "$1" | jq -c --arg id "$2" 'del(.slices[$id])' 2>/dev/null || printf '%s' "$1"
}

# slices_parked_csv <json> -> comma-separated ids with parked=true, in the
# exact shape select_next_slice()'s parked-ids argument expects.
slices_parked_csv() {
  printf '%s' "$1" | jq -r '[.slices | to_entries[] | select(.value.parked == true) | .key] | join(",")' 2>/dev/null || true
}

# slices_parked_count <json> -> integer count of parked ids (S3A's
# `parked_count` field, logged for real as of S4A).
slices_parked_count() {
  printf '%s' "$1" | jq -r '[.slices | to_entries[] | select(.value.parked == true)] | length' 2>/dev/null || echo 0
}
