# MCP M0 baseline report

This is a pilot of one trial per task and arm, not population evidence or a causal comparison. The prompts were fixed without outcome-based tuning. The [pilot rows](pilot-results.json) contain all twelve independent judgments, costs, tool counts and evidence digests; [operation samples](operation-samples.json) contain all 80 runs. [Pilot details](PILOT.md) and [operation methods](OPERATIONS.md) give controls, reproduction commands and limitations. Private transcripts and paths are excluded.

| Task | Shell verdict | MCP verdict | Shell wall ms / tokens / result bytes | MCP wall ms / tokens / result bytes |
| --- | --- | --- | --- | --- |
| import-definition | correct | correct | 11842 / 16459 / 756 | 10827 / 28140 / 730 |
| shadow-references | correct | correct | 8470 / 10615 / 276 | 7411 / 20633 / 467 |
| stdlib-filter | incorrect | incorrect | 20070 / 71342 / 12612 | 10190 / 37713 / 13476 |
| repair-diagnostic | incorrect | incorrect | 6154 / 10879 / 424 | 10572 / 21314 / 1208 |
| dispatch | correct | correct | 10758 / 25632 / 3452 | 9776 / 27748 / 591 |
| worktree-validation | incorrect | incorrect | 12453 / 22228 / 696 | 14923 / 20956 / 456 |

All twelve host launches succeeded; that is separate from six correct and six incorrect answers. Each had one attempt, no denials or retries. The admission boundary allowed 30 operations and recorded attempts and denials; both arms used a verified CLI-only artifact, and the MCP arm additionally had the broker. Two MCP-arm trials made no MCP calls. Tool counts, individual rubric failures and fallback observations are in the rows. The repair agents reported read-only workspaces without a recorded write attempt; a same-mode synthetic append succeeded. No workspace restriction is inferred from their statements.

The operation corpus has seven cases and a missing-binary control, five observations per arm: 70 collector successes and 10 expected startup failures. Collector success is not semantic correctness. Definition and reference lookups produced wrong or empty results; cross-file definition, selected dispatch and procedural identity were unsupported by these queries. Diagnostic responses included tool-level errors. Changed-source testing used a fresh session and cannot establish same-session invalidation. Details and all samples are linked above.

The single Linux host used cgroup v2 and private PID/mount namespaces; its exact kernel and hardware identity were not retained, so they cannot be reproduced from this record. The exact binary hashes, source revisions and stdlib tree IDs are in [operations](OPERATIONS.md); the arms differ, so instrumentation overhead cannot be isolated. The pilot used `codex-cli 0.166.0`, `gpt-6.1-terra`, high effort; host and artifact hashes are in [pilot provenance](PILOT.md). The selected raw operations SHA-256 is `01a428d8b59e99ba17fcd82a46ee22f962ce1d3866529aefa385875154c6ab6d`; build log SHA-256 is `97ef5258890263a5de4b202f8778988009f85d887bfbb5d5b28ded449c227f64`. The private pilot manifest SHA-256 is `96df2362ab4ac1c0fd59c13b54a62f0cdbfb9b10348ba444cdb4cd4d93ba0186`. Audit instructions and reproduction commands are in the linked method documents.

The versioned [budgets](../../../scripts/mcp_bench/budgets.json) freeze rounded-up observed maxima on this host for cold first response and queued response intervals, with derivations in the file. Five repetitions per case do not support a p95. These provisional ceilings are not isolated query latency or an overhead comparison. Query round trips, instrumentation overhead, process-tree CPU and peak RSS, allocations, retained heap, read counts and private context occupancy remain unmeasured; host token accounting and response bytes are separate observables. The offline handshake of at most two seconds remains an untested hypothesis for the next sprint. No memory, context or latency threshold should be claimed until the corresponding measurement exists.
