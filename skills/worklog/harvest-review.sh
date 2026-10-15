#!/usr/bin/env bash
# skills/worklog/harvest-review.sh — render the worklog's Harvest batch as an
# editable review table.
#
#   harvest-review.sh <entries.json> <out.html> [--project "Client / Project"] [--task "Task"]
#
# entries.json: [{date, hours, notes, logged?, entry_id?}] — the file that
# harvest.sh log-batch later consumes. `logged` (hours already in Harvest for
# that day) and `entry_id` (already logged by a previous batch) are optional.
#
# The page is static: no script, no token, no network. Each notes and hours
# cell carries data-block="<date> · notes|hours", so the human-review skill
# reports the user's edits under exactly that label and the skill can map them
# back onto entries.json before logging.

set -uo pipefail

die() { echo "harvest-review: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required"

in="${1:-}"; out="${2:-}"; shift 2 2>/dev/null || die "usage: harvest-review.sh <entries.json> <out.html> [--project NAME] [--task NAME]"
[[ -f "$in" ]] || die "no such file: $in"
project="" task=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) project="${2:-}"; shift 2 ;;
    --task) task="${2:-}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
jq -e 'type == "array" and all(.[]; .date and .hours != null)' "$in" >/dev/null 2>&1 || die "$in must be a JSON array of {date, hours, notes}"

from="$(jq -r 'map(.date) | min' "$in")"; to="$(jq -r 'map(.date) | max' "$in")"

rows="$(jq -r '
  def esc: tostring | @html;
  def day: (.date | strptime("%Y-%m-%d") | strftime("%a"));
  .[] | "<tr\(if .entry_id then " class=\"logged\"" else "" end)>
  <td class=\"date\"><strong>\(.date|esc)</strong><small>\(day)</small></td>
  <td data-block=\"\(.date|esc) · notes\">\((.notes // "") | esc | gsub("\n"; "<br>"))</td>
  <td class=\"num\" data-block=\"\(.date|esc) · hours\">\(.hours|esc)</td>
  <td class=\"num muted\">\(if .entry_id then "entry \(.entry_id|esc)" elif .logged then "\(.logged|esc) h" else "" end)</td>
</tr>"' "$in")"
total="$(jq -r 'map(.hours) | add // 0' "$in")"

cat > "$out" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Worklog → Harvest ($from – $to)</title>
<style>
  :root { --bg:#f7f7f5; --fg:#1d1d1b; --muted:#6b6b66; --line:#dcdcd7; --card:#fff; --accent:#f36c21; }
  @media (prefers-color-scheme: dark) { :root { --bg:#161615; --fg:#ececea; --muted:#9a9a94; --line:#34342f; --card:#1f1f1d; } }
  * { box-sizing: border-box; }
  body { margin:0; padding:24px 16px 64px; background:var(--bg); color:var(--fg); font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif; }
  main { max-width:1100px; margin:0 auto; }
  h1 { font-size:20px; margin:0 0 4px; }
  .sub { color:var(--muted); margin:0 0 16px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:8px; padding:8px 16px; }
  table { width:100%; border-collapse:collapse; }
  th, td { text-align:left; vertical-align:top; padding:10px 8px; border-top:1px solid var(--line); }
  th { font-size:12px; color:var(--muted); font-weight:600; border-top:0; }
  td.date { white-space:nowrap; font-variant-numeric:tabular-nums; width:110px; }
  td.date small { display:block; color:var(--muted); }
  td.num { text-align:right; white-space:nowrap; font-variant-numeric:tabular-nums; width:70px; }
  td.muted { color:var(--muted); font-size:12px; width:110px; }
  tr.logged td { opacity:.55; }
  tfoot td { font-weight:600; }
  .hint { color:var(--muted); font-size:12px; margin-top:12px; }
</style>
</head>
<body>
<main>
  <h1>Worklog → Harvest</h1>
  <p class="sub" data-block="target">${project:+Project: <strong>$(printf '%s' "$project" | jq -Rr @html)</strong> · }${task:+Task: <strong>$(printf '%s' "$task" | jq -Rr @html)</strong> · }Window: $from – $to. Edit the notes and hours in place, then hit Send.</p>
  <section class="card">
    <table>
      <thead><tr><th>Date</th><th>Notes</th><th>Hours</th><th>In Harvest</th></tr></thead>
      <tbody>
$rows
      </tbody>
      <tfoot><tr><td>Total</td><td></td><td class="num">$total</td><td></td></tr></tfoot>
    </table>
    <p class="hint">Rows marked as logged already have a Harvest entry and will be skipped. Set a day's hours to 0 to leave it out.</p>
  </section>
</main>
</body>
</html>
HTML
echo "$out"
