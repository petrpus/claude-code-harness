#!/usr/bin/env bash
# skills/autopilot/plan.sh — pure parsing of the IMPLEMENTATION_PLAN.md
# checklist into a Plan DAG, and select_next_slice() over it. Sourced by
# loop.sh (wired in S1B); kept in its own file so slice selection is
# unit-testable without running a whole autonomous run — the same split as
# allowlist.sh.
#
# Plan line shape (docs/adr/0005-*.md): `- [ ] <id> — text (after: <id>, <id>)`.
# The id is plan-local (not an issue number) — just the first whitespace-
# delimited token after the checkbox. A line with no `(after: ...)` clause has
# no blockers, which means a 0.4.0-era plan with no annotations at all parses
# cleanly: every line is unblocked, so select_next_slice() degrades to "first
# unchecked box" — unchanged 0.4.0 behaviour (contract item 8).

# plan_parse_line <line>
#   Emits "<id>\t<ticked 0|1>\t<after ids, space-separated>" for a checkbox
#   line, nothing (exit 1) for any other line (headings, blank lines,
#   STATUS:). An id-less checkbox ("- [ ]" with nothing after it) emits an
#   empty id field — callers must treat that as unselectable, not as a parse
#   error, and never as a crash.
plan_parse_line() {
  local line="$1"
  [[ "$line" =~ ^[[:space:]]*[-*][[:space:]]+\[([xX\ ])\][[:space:]]*(.*)$ ]] || return 1
  local mark="${BASH_REMATCH[1]}" rest="${BASH_REMATCH[2]}"
  local ticked=0
  [[ "$mark" == "x" || "$mark" == "X" ]] && ticked=1

  local after_raw="" after_clause=""
  if [[ "$rest" =~ \(after:[[:space:]]*([^\)]*)\)[[:space:]]*$ ]]; then
    after_raw="${BASH_REMATCH[1]}"
    after_clause="${BASH_REMATCH[0]}"
    rest="${rest%"$after_clause"}"
  fi

  local -a id_tokens
  read -ra id_tokens <<<"$rest"
  local id="${id_tokens[0]:-}"

  local -a after_tokens=()
  local tok
  for tok in $(printf '%s' "$after_raw" | tr ',' ' '); do
    case "$tok" in
      '—'|'-'|'') continue ;;
    esac
    after_tokens+=("$tok")
  done

  printf '%s\t%s\t%s\n' "$id" "$ticked" "${after_tokens[*]}"
}

# plan_load <plan_file>
#   Populates the globals below from every checkbox line, in file order.
#   Missing file = empty plan (contract item 8: a 0.4.0-era run directory
#   without this file yet must never error).
#     PLAN_IDS[]          — id per checkbox row (may be "", may repeat)
#     PLAN_ROW_TICKED[]   — 0|1 per row
#     PLAN_ROW_AFTER[]    — space-separated blocker ids per row
#     PLAN_ROW_RAW[]      — the original line text per row, for the caller to
#                           inject the selected slice's own wording into a
#                           prompt instead of re-deriving it (loop.sh, S1B)
#     PLAN_ID_KNOWN{}     — id -> 1, for every non-empty id seen
#     PLAN_ID_TICKED{}    — id -> 1 if ANY row with that id is ticked, else 0
#   PLAN_ID_TICKED is an aggregate over possibly-repeated ids, which is only
#   ever consulted to resolve an after: reference — and after: is meaningful
#   only on annotated plans, where ids are unique by convention. An
#   unannotated 0.4.0 plan can repeat "first tokens" freely (e.g. every line
#   starting "- [ ] slice N") because nothing ever looks such an id up.
plan_load() {
  local file="$1" line parsed id ticked after
  PLAN_IDS=(); PLAN_ROW_TICKED=(); PLAN_ROW_AFTER=(); PLAN_ROW_RAW=()
  unset PLAN_ID_TICKED PLAN_ID_KNOWN
  declare -gA PLAN_ID_TICKED=()
  declare -gA PLAN_ID_KNOWN=()
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    parsed="$(plan_parse_line "$line")" || continue
    IFS=$'\t' read -r id ticked after <<<"$parsed"
    PLAN_IDS+=("$id")
    PLAN_ROW_TICKED+=("$ticked")
    PLAN_ROW_AFTER+=("$after")
    PLAN_ROW_RAW+=("$line")
    [[ -n "$id" ]] || continue
    PLAN_ID_KNOWN["$id"]=1
    if [[ "$ticked" == "1" ]]; then
      PLAN_ID_TICKED["$id"]=1
    else
      : "${PLAN_ID_TICKED[$id]:=0}"
    fi
  done < "$file"
}

# _plan_dfs <node> <chain-so-far>
#   Recursion-stack DFS over the after: edges (id depends on its after ids).
#   Sets PLAN_CYCLE_CHAIN and returns 1 on the first cycle found. Reads the
#   PLAN_* globals from the most recent plan_load; caller resets
#   PLAN_DFS_VISITED / PLAN_DFS_ONSTACK before the first call.
_plan_dfs() {
  local node="$1" chain="$2" idx b
  if [[ -n "${PLAN_DFS_ONSTACK[$node]:-}" ]]; then
    PLAN_CYCLE_CHAIN="$chain -> $node"
    return 1
  fi
  [[ -n "${PLAN_DFS_VISITED[$node]:-}" ]] && return 0
  PLAN_DFS_VISITED["$node"]=1
  PLAN_DFS_ONSTACK["$node"]=1
  for (( idx=0; idx<${#PLAN_IDS[@]}; idx++ )); do
    [[ "${PLAN_IDS[$idx]}" == "$node" ]] || continue
    for b in ${PLAN_ROW_AFTER[$idx]}; do
      _plan_dfs "$b" "$chain -> $b" || return 1
    done
  done
  unset "PLAN_DFS_ONSTACK[$node]"
  return 0
}

# _plan_dag_error
#   Validates the DAG built by the most recent plan_load: every after: id
#   must name a real slice, and the after: edges must not cycle. Echoes a
#   one-line reason and returns 1 on the first problem found; silent, returns
#   0, when the DAG is sound.
_plan_dag_error() {
  local i n="${#PLAN_IDS[@]}" id tok
  for (( i=0; i<n; i++ )); do
    id="${PLAN_IDS[$i]}"
    [[ -n "$id" ]] || continue
    for tok in ${PLAN_ROW_AFTER[$i]}; do
      if [[ -z "${PLAN_ID_KNOWN[$tok]:-}" ]]; then
        printf 'plan_dag: %s names unknown blocker %s\n' "$id" "$tok"
        return 1
      fi
    done
  done

  declare -gA PLAN_DFS_VISITED=()
  declare -gA PLAN_DFS_ONSTACK=()
  PLAN_CYCLE_CHAIN=""
  for (( i=0; i<n; i++ )); do
    id="${PLAN_IDS[$i]}"
    [[ -n "$id" ]] || continue
    [[ -n "${PLAN_DFS_VISITED[$id]:-}" ]] && continue
    if ! _plan_dfs "$id" "$id"; then
      printf 'plan_dag: cycle %s\n' "$PLAN_CYCLE_CHAIN"
      return 1
    fi
  done
  return 0
}

# select_next_slice <plan_file> [parked-ids]
#   parked-ids: space- or comma-separated, default none (S4A wires the real
#   tmp/autopilot/slices.json in; until then callers pass nothing and get
#   0.4.0 behaviour).
#
#   - Found a slice to run: echoes its id, returns 0. Slices are tried in
#     file order, so an unannotated plan gets "first unchecked box" exactly.
#   - The DAG itself is broken — an after: names an id that exists nowhere in
#     the plan, or the after: edges cycle: echoes one diagnostic line, returns
#     2 (fingerprint `plan_dag` — bypasses the stuck ladder entirely, ADR-0005).
#   - The DAG is sound but every remaining unchecked slice is parked, or
#     blocked (directly or transitively) by a parked one: returns 3, no
#     output (replan signal).
#   - Nothing left to schedule — every id is ticked, or the plan has none:
#     returns 1, no output.
select_next_slice() {
  local plan_file="$1" parked_csv="${2:-}"
  plan_load "$plan_file"

  if ! _plan_dag_error; then
    return 2
  fi

  local -A parked=()
  local p
  for p in $(printf '%s' "$parked_csv" | tr ',' ' '); do
    [[ -n "$p" ]] && parked["$p"]=1
  done

  local i n="${#PLAN_IDS[@]}" id work_remains=0 ready b
  for (( i=0; i<n; i++ )); do
    id="${PLAN_IDS[$i]}"
    [[ -n "$id" ]] || continue
    [[ "${PLAN_ROW_TICKED[$i]}" == "1" ]] && continue
    work_remains=1
    [[ -n "${parked[$id]:-}" ]] && continue
    ready=1
    for b in ${PLAN_ROW_AFTER[$i]}; do
      [[ "${PLAN_ID_TICKED[$b]:-0}" == "1" ]] || { ready=0; break; }
    done
    if [[ "$ready" -eq 1 ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done

  [[ "$work_remains" -eq 1 ]] && return 3
  return 1
}

# plan_selected_line <id>
#   Echoes the raw line text of the first *unticked* row carrying <id>, so a
#   caller that just got an id back from select_next_slice() can hand the
#   model the slice's own wording instead of re-deriving it. Reads the
#   PLAN_ROW_RAW/PLAN_IDS/PLAN_ROW_TICKED globals left behind by the most
#   recent plan_load (select_next_slice() calls it internally, so this works
#   immediately after a successful selection). Echoes nothing if not found.
plan_selected_line() {
  local id="$1" i n="${#PLAN_IDS[@]}"
  for (( i=0; i<n; i++ )); do
    if [[ "${PLAN_IDS[$i]}" == "$id" && "${PLAN_ROW_TICKED[$i]}" != "1" ]]; then
      printf '%s\n' "${PLAN_ROW_RAW[$i]}"
      return 0
    fi
  done
  return 1
}
