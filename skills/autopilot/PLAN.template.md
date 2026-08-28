# Implementation plan

<!--
Written by the PLAN phase from PROMPT.md; seed manually only if you want to
steer decomposition. Each item is an INDEPENDENTLY VERIFIABLE vertical slice:
when checked, the app still works and the verify command proves it. The loop
picks one unblocked, unparked item per iteration (select_next_slice(),
docs/adr/0005-*.md).

Give each slice a short id as the first token after the checkbox, and add
"(after: <id>, <id>)" only when the later slice genuinely cannot be verified
without the earlier one having landed. No id / no after: clause = unblocked
from the start — prefer several slices being ready at once (a WIDE Plan DAG)
over one long chain: a slice deep in a chain can't be set aside when it fails
without also blocking everything behind it.

The final STATUS line is the sentinel gate — the loop sets it to `done` only
when every box is ticked and verify is green.
-->

- [ ] S1 — <smallest end-to-end increment that verify can prove>
- [ ] S2 — <builds on S1> (after: S1)
- [ ] S3 — <independent of S2, also only needs S1> (after: S1)

STATUS: in-progress
