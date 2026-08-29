# Implementation plan

<!--
Written by the PLAN phase from PROMPT.md; seed manually only if you want to
steer decomposition. Each item is an INDEPENDENTLY VERIFIABLE vertical slice:
when checked, the app still works and the verify command proves it. The loop
picks one unblocked, unparked item per iteration (select_next_slice(),
docs/adr/0005-*.md).

Give each slice a short id as the first token after the checkbox, and add
"(after: <id>, <id>)" only when the later slice genuinely cannot be verified
without the earlier one having landed. The clause must be LAST on the line and
hold ids only — prose inside it parses as bogus ids and fails the run. No id /
no after: clause = unblocked from the start — prefer several slices being
ready at once (a WIDE Plan DAG) over one long chain: a slice deep in a chain
can't be set aside when it fails without also blocking everything behind it.

The test for an edge is CONSUMPTION, not order: X gets "after: Y" only when X
reads a file, field, function or flag that Y creates. Name that in the slice's
body; if you can't name it, delete the edge. Slices that document or release
the work are naturally terminal — that's expected, and it's no reason to also
chain the feature slices to each other.

The final STATUS line is the sentinel gate — the loop sets it to `done` only
when every box is ticked and verify is green.
-->

- [ ] S1 — <smallest end-to-end increment that verify can prove>
- [ ] S2 — <builds on S1> (after: S1)
- [ ] S3 — <independent of S2, also only needs S1> (after: S1)

STATUS: in-progress
