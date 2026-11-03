# MCP operation baseline

These observations are a small, single-host baseline, not an agent trial or a
statistical performance estimate. `operation-samples.json` retains all five
sequential observations per case and arm, in nanoseconds. Cold initialization
is the first response arrival relative to collector entry; subsequent offsets
are arrival times on the same process. The requests are queued together. The
difference between adjacent arrivals is a serial response interval, including
observer scheduling and output transport, not an isolated request/response
latency. Responses read in one chunk share an arrival time. Do not use a
percentile from five samples. Initialization ranges over these cases were
129.20–186.36 ms for the preserved binary and 120.71–175.85 ms for the current
binary; these include sandbox setup and process startup.

The two arms use different revisions and stdlib trees, so their timing
differences cannot be attributed to instrumentation. Baseline binary SHA-256
`4b05aab61552d290a0e33d2b6f2f825290ecc61e24d9138f7fbaa829a19ee503`, revision
`0d10b7998`, stdlib tree `01191f84f4b7c5473462e97a156162032700f621`;
current binary SHA-256
`b4ac81697fcf063f29a8019eb6c02bc62645469b9aeee1a42840706d4bc9efe8`, source
revision `c8b56e74194da900d61eaa9d543ef7c21073568b`, stdlib tree
`5711790df259679a658505648a66384443cf66fd`. The current binary was rebuilt with
a dirty worktree after the Python harness edits. Each arm used its own root and
`MEDAKA_STRICT=1`. Different identities establish drift, not a freshness verdict
for an arbitrary source edit.

## Answer observations

All five repetitions of each case had the same response text and `isError` in
each arm, and those fields agreed between arms. This excludes response metadata,
which differs between revisions, and does not establish full protocol parity.
The task contracts in `scripts/mcp_bench/tasks.json` supply the independent
source/spec rubrics. Protocol-success records are not semantic grades.

| Task and control | Observed against the independent rubric |
| --- | --- |
| Imported definitions, A and B | Both intra-file definition lookups returned no match. The required declarations are in alpha and beta respectively; cross-file definition lookup is unsupported by this tool. |
| Shadow references and parameter | The top-level reference lookup returned no locations rather than the reference in `g`; the parameter-body definition lookup returned the top-level declaration rather than the parameter. These observations do not satisfy the lexical-scope rubric. |
| Stdlib filter and list re-export | Symbols of core include `filter`; symbols of list do not establish the re-export. The list control needs the source import/export evidence in the task rubric; it is not established by this operation. |
| Diagnostic repair and incomplete expression | The bad addition produced `T-NO-IMPL`, the incomplete expression `P-PARSE`, and the corrected inline source had no diagnostics. The operation does not execute the expression or establish its result 3. |
| Dispatch and other type | Type-at returned `describe : a -> String` and check reported no diagnostics. Neither response identifies the selected implementation or answers the String control; those answers are unsupported by these operations. |
| Worktree validation and same-path control | An inline check succeeds in each root. MCP does not answer the procedural identity and freshness questions in this probe; the task rubric requires building and checking the edited worktree. |

An independently materialized changed source removed the bad-addition
diagnostic in each arm. It used a new worker and workspace, so it is not a
same-session invalidation test. Missing binaries produced `startup_failure` in
all five attempts per arm. Each real case produced five collector `success`
records per arm; diagnostic responses still contain tool-level `isError` and
must be read as such. No CPU, process-tree peak RSS, allocation, retained heap,
or context counters were available; they are not inferred from wall time.

## Reproduction and evidence

The Linux host supplied root-owned cgroup v2, private PID/mount namespaces and
credential-drop authority. Run on an authorized host, with the two roots
prepared and their hashes verified, using a new private output path:

```sh
python3 scripts/mcp_bench/operations.py --baseline-root "$BASELINE_ROOT" --instrumented-root "$CURRENT_ROOT" --output "$PRIVATE_OUTPUT"
python3 -m unittest discover -s scripts/mcp_bench -p operation_test.py
sh test/diff_compiler_mcp_collector.sh
```

The output contains responses and absolute paths: keep it private. The selected
raw evidence is `operations-identified.json`, SHA-256
`01a428d8b59e99ba17fcd82a46ee22f962ce1d3866529aefa385875154c6ab6d` in the
sprint evidence directory. Earlier raw runs are retained there: one with the
collector gate overlapping, one subsequent repeat, and an initial exploratory
run. The selected run followed a rebuild and used the fingerprint above.

Five sequential `make medaka` observations exited zero: 67.895, 1.513, 1.444,
1.411 and 1.405 seconds. The first rebuilt stage B because the dirty revision
changed its cache key; the remaining four were cache hits. This is build-cost
context, not five cold builds. Raw build log SHA-256
`97ef5258890263a5de4b202f8778988009f85d887bfbb5d5b28ded449c227f64`.
