#!/usr/bin/env bash
# skills/deliver/map.sh — pure text functions over a Map issue body
# (docs/adr/0008-*.md). No network, no git: body text in, text out, so every
# rule here is unit-testable (scripts/test-deliver.sh) without a fake forge.
#
# Only the `## Delivery` section is machine-read. Its lines use the plan
# grammar plan.sh already parses, with issue refs as ids:
#   - [ ] #61 feat(x): title (after: #60, #59)
# so select_next_slice() walks the issue graph unchanged (ADR-0008 decision 2).
#
# Bodies edited in GitHub's web UI come back with CRLF line endings. Readers
# strip the \r; map_tick() leaves every byte it does not change alone.

# Conventional-commit subject: type, optional scope, optional !, ": ", 1-72
# chars of description. The same shape CLAUDE.md asks of every commit.
MAP_CONVENTIONAL_RE='^(feat|fix|docs|refactor|test|chore|perf|build|ci|style|revert)(\([a-z0-9._/-]+\))?!?: .{1,72}$'

# _map_delivery_lines <body_file>
#   Every line of the Delivery section (heading excluded), CR stripped.
_map_delivery_lines() {
  tr -d '\r' < "$1" | awk '
    /^##[[:space:]]+Delivery[[:space:]]*$/ { inside=1; next }
    /^##[[:space:]]/                        { inside=0 }
    inside { print }'
}

# map_extract_delivery <body_file>
#   The Delivery section's checkbox lines whose id is an issue ref (#N), in
#   file order — a plan file select_next_slice() can read directly. Prose,
#   blank lines and checkboxes without a #N id are dropped.
map_extract_delivery() {
  _map_delivery_lines "$1" | grep -E '^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]+#[0-9]+([[:space:]]|$)' || true
}

# map_validate <plan_file>
#   Structural checks select_next_slice() does not make. Echoes one problem
#   per line and returns 1 if any:
#   - an issue listed twice (one issue is one PR; a duplicate is a typo)
#   - an after: ref that is not an issue ref, or names an issue outside the
#     Map (ADR-0008 decision 3 — external refs are a pre-flight error here;
#     closed-issue pruning comes with resume)
# A cycle is left to select_next_slice() (rc 2), which already detects it.
map_validate() {
  local plan="$1" line parsed id ticked after b bad=0
  local -A seen=()
  while IFS= read -r line; do
    parsed="$(plan_parse_line "$line")" || continue
    IFS=$'\t' read -r id ticked after <<<"$parsed"
    if [[ -n "${seen[$id]:-}" ]]; then echo "issue $id is listed twice"; bad=1; fi
    seen["$id"]=1
  done < "$plan"
  while IFS= read -r line; do
    parsed="$(plan_parse_line "$line")" || continue
    IFS=$'\t' read -r id ticked after <<<"$parsed"
    for b in $after; do
      if [[ ! "$b" =~ ^#[0-9]+$ ]]; then
        echo "$id: after: '$b' is not an issue ref (#N)"; bad=1
      elif [[ -z "${seen[$b]:-}" ]]; then
        echo "$id: after: $b is not in the Map's Delivery section"; bad=1
      fi
    done
  done < "$plan"
  return "$bad"
}

# map_issue_number <id>  — "#61" -> "61"
map_issue_number() { printf '%s\n' "${1#\#}"; }

# map_line_title <line>
#   The free text after the issue ref, without the after: clause.
map_line_title() {
  local line="${1%$'\r'}" rest
  [[ "$line" =~ ^[[:space:]]*[-*][[:space:]]+\[[\ xX]\][[:space:]]+#[0-9]+[[:space:]]*(.*)$ ]] || return 1
  rest="${BASH_REMATCH[1]}"
  if [[ "$rest" =~ \(after:[^\)]*\)[[:space:]]*$ ]]; then
    rest="${rest%"${BASH_REMATCH[0]}"}"
  fi
  rest="${rest%"${rest##*[![:space:]]}"}"
  printf '%s\n' "$rest"
}

# map_title_is_conventional <title>
map_title_is_conventional() { [[ "$1" =~ $MAP_CONVENTIONAL_RE ]]; }

# map_pr_title <map_title> <issue_title> <labels_csv>
#   The squash subject (ADR-0008 decision 5): the Map line's title when it is
#   already a conventional commit; otherwise <type>: <issue title>, where the
#   type follows the issue's labels (bug → fix, documentation → docs, anything
#   else → feat). The description is cut to 72 characters.
map_pr_title() {
  local map_title="$1" issue_title="$2" labels=",$3," type desc
  if [[ -n "$map_title" ]] && map_title_is_conventional "$map_title"; then
    printf '%s\n' "$map_title"; return 0
  fi
  case "$labels" in
    *,bug,*)           type=fix ;;
    *,documentation,*) type=docs ;;
    *)                 type=feat ;;
  esac
  desc="${map_title:-$issue_title}"
  desc="$(printf '%s' "$desc" | tr -d '\r' | tr '\n' ' ' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  desc="$(printf '%s' "${desc:0:1}" | tr '[:upper:]' '[:lower:]')${desc:1}"
  printf '%s: %s\n' "$type" "${desc:0:72}"
}

# map_branch_name <number> <pr_title>
#   <type>/<N>-<slug>: the type from the conventional title, the slug from its
#   description — lowercase, runs of anything but [a-z0-9] become one dash,
#   at most 40 characters, no dash at either end.
map_branch_name() {
  local n="$1" title="$2" type desc slug
  type="${title%%[(:!]*}"
  desc="${title#*: }"
  slug="$(printf '%s' "$desc" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//')"
  slug="${slug:0:40}"; slug="${slug%%-}"
  while [[ "$slug" == *- ]]; do slug="${slug%-}"; done
  printf '%s/%s-%s\n' "${type:-feat}" "$n" "${slug:-issue}"
}

# map_tick <body_file> <number>
#   Prints the body with the first unticked Delivery line for #<number>
#   ticked. Every other byte — CRLF endings, a missing final newline, lines
#   outside Delivery that happen to mention the same issue — is unchanged.
#   Returns 1 (and prints nothing) when there is no such line.
map_tick() {
  local body="$1" n="$2" ln
  ln="$(awk -v n="$n" '
    { line=$0; sub(/\r$/, "", line) }
    line ~ /^##[[:space:]]+Delivery[[:space:]]*$/ { inside=1; next }
    line ~ /^##[[:space:]]/                        { inside=0 }
    inside && line ~ ("^[[:space:]]*[-*][[:space:]]+\\[ \\][[:space:]]+#" n "([[:space:]]|$)") { print NR; exit }
  ' "$body")"
  [[ -n "$ln" ]] || return 1
  sed "${ln}s/\\[ \\]/[x]/" "$body"
}

# map_is_ticked <body_file> <number>  — 0 when #<number>'s Delivery line is [x]
map_is_ticked() {
  _map_delivery_lines "$1" | grep -qE "^[[:space:]]*[-*][[:space:]]+\\[[xX]\\][[:space:]]+#$2([[:space:]]|\$)"
}

# _map_follow_up_lines <body_file>  — every line of '## Follow-ups' (heading
# excluded), CR stripped. Absent when the Map has no such section yet.
_map_follow_up_lines() {
  tr -d '\r' < "$1" | awk '
    /^##[[:space:]]+Follow-ups[[:space:]]*$/ { inside=1; next }
    /^##[[:space:]]/                          { inside=0 }
    inside { print }'
}

# map_follow_up_has <body_file> <number>  — 0 when #<number> is already
# listed under '## Follow-ups' (any checkbox state).
map_follow_up_has() {
  _map_follow_up_lines "$1" | grep -qE "^[[:space:]]*[-*][[:space:]]+\\[[ xX]\\][[:space:]]+#$2([[:space:]]|\$)"
}

# map_add_follow_up <body_file> <number> <line>
#   Prints the body with <line> appended under '## Follow-ups' — creating the
#   section (right after '## Delivery', or at the body's end when Delivery
#   runs to EOF) when the Map has none yet — unless #<number> is already
#   listed there, in which case the body is echoed unchanged: a follow-up
#   found again in a later review round or a re-run against the same forge
#   state is recorded once (#63). <line> is the full checklist line, e.g.
#   "- [ ] #75 found reviewing #62 (PR #72): <title>".
map_add_follow_up() {
  local body="$1" n="$2" line="$3"
  if map_follow_up_has "$body" "$n"; then
    cat "$body"
    return 0
  fi
  if grep -qE '^##[[:space:]]+Follow-ups[[:space:]]*$' <(tr -d '\r' < "$body"); then
    awk -v line="$line" '
      { raw=$0; l=$0; sub(/\r$/, "", l) }
      l ~ /^##[[:space:]]+Follow-ups[[:space:]]*$/ && !done { print raw; print line; done=1; next }
      { print raw }
    ' "$body"
  else
    awk -v line="$line" '
      { raw=$0; l=$0; sub(/\r$/, "", l) }
      in_delivery && l ~ /^##[[:space:]]/ && !inserted { print "## Follow-ups"; print line; print ""; inserted=1 }
      { print raw; last=l }
      l ~ /^##[[:space:]]+Delivery[[:space:]]*$/ { in_delivery=1 }
      END { if (!inserted) { if (NR > 0 && last !~ /^[[:space:]]*$/) print ""; print "## Follow-ups"; print line } }
    ' "$body"
  fi
}
