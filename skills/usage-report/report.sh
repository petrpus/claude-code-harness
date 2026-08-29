#!/usr/bin/env bash
# skills/usage-report/report.sh — S3B: renders the mechanical part of
# /usage-report's "Autopilot run logs" source (SKILL.md § Sources 2) straight
# from on-disk JSONL, rather than leaving the arithmetic to be re-derived by
# hand each invocation. Same split as skills/repo-map/digest.sh: a pure,
# testable function over state already on disk.
#
# Renders three sections, per PRD 0002 § S3:
#   1. Per-run table — slices ticked, cost/slice, gate-fail rate, mean turns.
#   2. Per-shortcut violation histogram across every run found (a criterion
#      whose fail rate collapses without a spec change is verifier drift,
#      not quality improvement — this is the cheap detector for it).
#   3. A repo-map on/off comparison of mean input+cache tokens per BUILD
#      call, keyed on S5's `repo_map` flag. When only one side is present in
#      the logs given, that side of the comparison row is "—", not an error
#      and not a fabricated number.
#
# Usage: report.sh [state-dir]   (default: tmp/autopilot)
# A missing/empty state dir is not an error (contract item 8: a fresh repo
# has never run autopilot) — prints one line and exits 0.

set -uo pipefail
STATE_DIR="${1:-tmp/autopilot}"

command -v jq >/dev/null 2>&1 || { echo "usage-report: jq is required" >&2; exit 1; }

shopt -s nullglob
LOGS=("$STATE_DIR"/run-*.jsonl)
shopt -u nullglob

if [[ ${#LOGS[@]} -eq 0 ]]; then
  echo "No autopilot run logs found under $STATE_DIR."
  exit 0
fi

# --- 1. Per-run table -------------------------------------------------------
# "Calls" here means the phases that actually invoke `claude -p` (plan,
# build, verify_agent, replan) — verify_cmd/secret_scan/runner_reload rows
# carry no cost/turns of their own and would only dilute the mean.
echo "## Per run"
echo "| Run | Slices ticked | Cost/slice | Gate-fail rate | Mean turns |"
echo "|---|---|---|---|---|"
for log in "${LOGS[@]}"; do
  run_id="$(basename "$log" .jsonl)"; run_id="${run_id#run-}"
  jq -s -r --arg run "$run_id" '
    (map(select(.phase=="iteration"))) as $it
    | ($it | length) as $n
    | ($it | map(.ticked_delta // 0) | add // 0) as $ticked
    | (map(select(.phase=="plan" or .phase=="build" or .phase=="verify_agent" or .phase=="replan"))) as $calls
    | ($calls | map(.cost_usd // 0) | add // 0) as $cost
    | ($it | map(select(.gate_failed != "none" and .gate_failed != null)) | length) as $failed
    | ($calls | map(.turns // 0)) as $turns
    | (if ($turns|length) > 0 then (($turns|add) / ($turns|length)) else 0 end) as $mean_turns
    | (if $ticked > 0 then ((($cost / $ticked) * 1000) | round) / 1000 else null end) as $cps
    | (if $n > 0 then ((($failed / $n) * 100) | round) else 0 end) as $gfr_pct
    | "| \($run) | \($ticked) | \($cps // "—") | \($gfr_pct)% | \((($mean_turns * 10) | round) / 10) |"
  ' "$log"
done

ALL="$(cat "${LOGS[@]}" 2>/dev/null)"

# --- 2. Per-shortcut violation histogram across all runs --------------------
echo
echo "## Per-shortcut violations (across all runs)"
SHORTCUT_ROWS="$(printf '%s' "$ALL" | jq -s -r '
  [ .[] | select(.phase=="verify_agent") | (.violations // [])[] ]
  | group_by(.) | map({shortcut: .[0], count: length}) | sort_by(-.count)
  | .[] | "| \(.shortcut) | \(.count) |"
' 2>/dev/null)"
if [[ -n "$SHORTCUT_ROWS" ]]; then
  echo "| Shortcut | Count |"
  echo "|---|---|"
  printf '%s\n' "$SHORTCUT_ROWS"
else
  echo "No verifier violations recorded."
fi

# --- 3. Repo-map on/off comparison -------------------------------------------
# Joins each "build" row to the "repo_map" flag its own iteration row
# recorded (same run_id + iter — build rows themselves don't carry the
# flag), then compares mean input+cache tokens per call between the two
# sides. `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`
# per PRD § S3, not `input_tokens` alone — the whole point is measuring
# whether the digest displaces tokens that would otherwise be a fresh read.
echo
echo "## Repo-map on/off (mean input+cache tokens per BUILD call)"
COMPARISON_ROW="$(printf '%s' "$ALL" | jq -s -r '
  (map(select(.phase=="iteration")) | map({key: (.run_id+"#"+(.iter|tostring)), value: .repo_map}) | from_entries) as $rm
  | (map(select(.phase=="build"))
     # NOT `$rm[$key] // null` — jq'"'"'s `//` treats a literal `false` as
     # falsy too, which would silently turn every repo_map:false build row
     # into a dropped `null` and make the "off" side of the comparison
     # disappear even when real data exists for it. `has()` distinguishes
     # "key present, value false" from "key absent" correctly.
     | map(
         (.run_id+"#"+(.iter|tostring)) as $key
         | . + {repo_map: (if ($rm|has($key)) then $rm[$key] else null end)}
       )
     | map(select(.repo_map != null))
     | group_by(.repo_map)
     | map({repo_map: .[0].repo_map,
            mean: ((map(.input_tokens + .cache_read_input_tokens + .cache_creation_input_tokens) | add) / length)})
    ) as $groups
  | ($groups | map(select(.repo_map == true)) | (if length>0 then .[0].mean else null end)) as $on
  | ($groups | map(select(.repo_map == false)) | (if length>0 then .[0].mean else null end)) as $off
  | "| \($on // "—") | \($off // "—") |"
' 2>/dev/null)"
echo "| repo_map=true | repo_map=false |"
echo "|---|---|"
echo "${COMPARISON_ROW:-| — | — |}"
