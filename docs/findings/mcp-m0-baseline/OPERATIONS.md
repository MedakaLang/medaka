# MCP operation baseline

The legacy queued observations below are a small, single-host baseline, not an agent trial or a
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

## Legacy answer observations

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

## Legacy reproduction and evidence

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

## Interactive measurements and matched trace control

[measurement-samples.json](measurement-samples.json) is a separate matrix. All
80 records remain in execution order: seven cases plus missing binary, five
repetitions per case and arm. Order is off/on, on/off, off/on, on/off, off/on
within each case. These are operation probes, with no model calls or new agent
trials. The old 80 records and all twelve pilot rows remain byte-identical.

Both arms use compiler source `e48074520cac8862d1a758974d1921804feaa49f`, compiler
tree `d1d5d5873aa6d40f936e246544de09e1ce3a2d39`, stdlib tree
`a835d2a269facd35fdfdb4845bfd3d76c0511554`, and binary SHA-256
`406bc592b48ff1c7cc1108af1641efd026fee3685886570fa01f0cfcbb4ccf6e`.
Compiler and stdlib sources were clean; `MEDAKA_STRICT=1` was set on both arms.
The only arm difference is enabling `MEDAKA_MCP_TRACE`; the legacy TSV log is
disabled in both. Tracing and parsing the trace are both part of the observed
trace-enabled session. The collector implementation is otherwise identical.

The supervisor forwards stdin to the worker without first reading it to EOF.
For each request, the collector records a monotonic timestamp immediately before
writing/flushing its JSON line, waits for a complete response line, validates the
JSON-RPC envelope and the exact request ID/type, and only then sends the next
request. Receipt time is the observer's timestamp on the read containing the
newline, before validation; validation gates acceptance of that sample. RTT
therefore includes transport and observer scheduling, excludes subsequent
validation work, and has no queued-request ambiguity. Request IDs, send/receipt
offsets and every RTT are retained. Integer `1` and string `"1"` are distinct.
Missing, duplicate, stray and malformed responses fail validation. A delayed fake
worker independently verifies that the next request has not already arrived.

Startup remains separate: collector entry to the initialize response spans
126.53–294.34 ms over 70 successful sessions, including workspace/authority setup
and process startup. The 140 later responses have RTT 19.31–160.17 ms. This warm
pool includes expected tool-level diagnostic errors; the ten missing-binary
failures have no query latency. Their individual outcomes and total elapsed
observations remain in the matrix. Five observations for a given query/arm are
not a percentile estimate.

For each query and repetition, subtract trace-off RTT from trace-on RTT. All 70
signed deltas are represented by their underlying paired samples; the range is
−40,576,264 to +22,033,936 ns. The [versioned budget](../../../scripts/mcp_bench/budgets.json)
rounds the largest absolute delta into a regression guardrail. Alternating order
reduces systematic order bias, but shared host scheduling and cache behavior
remain uncontrolled. The negative differences are evidence of noise; they are
not a tracing speedup. This measures a same-binary operational overhead contrast,
without claiming an isolated nanosecond cost for instrumentation.

## Resource scope, host and independent semantics

Host: Debian Linux `6.12.95+deb13-amd64`, kernel build
`#1 SMP PREEMPT_DYNAMIC Debian 6.12.95-1 (2026-07-04)`, x86_64, AMD EPYC 9645
96-Core Processor with 12 logical CPUs exposed, MemTotal 32,864,932 kB. Toolchain:
Python 3.13.5, Debian clang 19.1.7, Boehm GC 8.2.8. This is one shared Linux
host; no macOS measurement is claimed.

Each session owns a fresh, private cgroup. The supervisor joins before forking
namespace init and executing the worker, so descendants inherit membership.
Every successful response observed three members: supervisor, namespace init and
worker. The external collector/reader stays outside. The supervisor's earlier
imports/CPU and pre-existing memory charges are outside this accounting window.
After termination, the authority kills surviving members and waits for the
kernel's `populated 0`, reads counters, then removes only its unique cgroup.

The current session delegation did not enable the memory controller. Its
`memory.peak` was absent, explicitly reported as unavailable in the first test.
For the final tests and matrix, `MEDAKA_MCP_CGROUP_PARENT` selected an existing
root-owned user slice with cpu/memory/pids enabled. No shared controller settings
were changed. Selection is root-only, inside the cgroup mount and requires a
root-owned parent without group/other write permission. Each run still creates
and cleans its own child.

`cpu.stat`'s `usage_usec * 1000` gives cumulative session CPU nanoseconds, including
exited descendants: 90,375,000–257,162,000 ns across the 70 successful sessions.
`memory.peak` gives the maximum kernel-accounted memory charge for this cgroup and
its descendants: 21,950,464–134,561,792 bytes. It includes anonymous, file and
kernel charges; shared pages may already be charged elsewhere. It is not the sum
of process RSS, retained heap or allocations. Kernel definitions are documented
in [cgroup v2](https://docs.kernel.org/admin-guide/cgroup-v2.html#memory-interface-files)
and its [CPU interface](https://docs.kernel.org/admin-guide/cgroup-v2.html#cpu-interface-files).
The compact records' `resources` hold these measured counters and scope. Their
legacy version-2 `record.cpu_ns`/`peak_rss_bytes` fields still describe unavailable
worker-only process metrics; they must not replace the cgroup observations.

The task rubrics and source/spec bases in
[tasks.json](../../../scripts/mcp_bench/tasks.json) remain the semantic oracle.
All 40 matched session pairs return identical response envelopes/payloads; each
query has stable answers across its five repetitions. This establishes trace
parity, not correctness of the known wrong/unsupported definition, reference,
dispatch and procedural-identity answers described above. The independent
diagnostic controls require `T-NO-IMPL` for string-plus-integer, `P-PARSE` for an
incomplete addition and no diagnostics for integer addition. They pass in every
new repetition. Changed-source now checks the bad file, writes `main = 1 + 2`,
then checks the same file in the same worker: all ten sessions remove
`T-NO-IMPL`. It establishes this edit's freshness, without proving arbitrary
worktree identity, import invalidation or the runtime result of addition.

The context-cost proxy copies all twelve existing pilot `inputTokens` values
and their host-evidence hashes: range 10,491–70,893 tokens. This is host-accounted
cumulative input, including cached/repeated input; it is not private context
occupancy. Budget version 2 freezes this explicitly named proxy, keeping
`context_usage` and peak RSS unavailable with reasons. Pilot timestamps, CPU/RSS
and read counts remain null. The new matrix recorded monotonic request offsets,
not UTC start/end; the metadata capture timestamp is explicitly a later capture.

## Interactive reproduction and immutable evidence

With the identical binary/stdlib verified, use unique output paths on an
authorized Linux host. `CGROUP_PARENT` must be an existing root-owned delegation
with the memory controller enabled for children; no host setting is modified:

```sh
MEDAKA_MCP_CGROUP_PARENT="$CGROUP_PARENT" python3 scripts/mcp_bench/operations.py --interactive-root "$CURRENT_ROOT" --output "$PRIVATE_RAW"
MEDAKA_MCP_REQUIRE_AUTHORITY=1 MEDAKA_TRIAL_REQUIRE_AUTHORITY=1 MEDAKA_MCP_CGROUP_PARENT="$CGROUP_PARENT" python3 -m unittest discover -s scripts/mcp_bench -p '*_test.py'
python3 scripts/mcp_bench/report.py --interactive-raw "$PRIVATE_RAW" --provenance "$PUBLIC_PROVENANCE" --pilot docs/findings/mcp-m0-baseline/pilot-results.json --output "$NEW_COMPACT_OUTPUT"
```

Keep raw payloads private. In the sprint evidence directory, `measurement-fix/`
retains `interactive-raw.json`, host metadata, the metadata capture and independent
audit scripts, and `SHA256.json`. The new raw SHA-256 is
`26b0c6b7ecd06c883ef39e6bdfd565a6443409e452dda7ff80973d3c1f9ab490`;
the preserved public pilot source SHA-256 is
`6b471a2a7f78a8e5e539610bfd6355f6b9143214528e02532a6f02468f9df877`.
The compact matrix contains raw and method-source fingerprints. Metadata records
that overflow-queue bounding and explicit broken-pipe cleanup were added after
collection; successful timing/accounting paths are unchanged. Its compactor is
deterministic for the retained raw bytes, provenance and pilot rows. The prior
queued and pilot artifacts are retained separately; their missing counters are
not filled with the new run's observations.
