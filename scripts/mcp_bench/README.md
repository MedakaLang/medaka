# MCP baseline task contracts

Interactive operation measurements use `operations.py --interactive-root ROOT
--output PRIVATE_RAW`. `measure_matched` runs five repetitions per case/arm,
alternates trace order, and uses one pinned compiler/stdlib for both arms. With
`interactive=True`, `run_process` forwards streaming stdin through the namespace
supervisor and waits for a validated response with the exact ID before sending
the next request. `exchange_callback` receives monotonic send/receipt offsets
and RTTs; initialization stays separate from queries. `before_request` supports
the same-session changed-file control in the host-owned disposable workspace.

`resource_callback` receives cumulative cgroup CPU nanoseconds and peak memory
charge bytes, or explicit unavailability reasons. Accounting includes supervisor
after migration, namespace init, worker and descendants, excluding the external
collector. Peak memory charge is not RSS. Root-only
`MEDAKA_MCP_CGROUP_PARENT` can select an existing private cgroup delegation with
memory enabled; the collector changes only its unique child. Portable worker-only
resource fields in version-2 Runs retain their existing unavailable meanings.

Budget schema version 2 extends version 1 with measured serial query latency,
same-binary absolute trace-delta guardrails, `peak_memory_charge_bytes` and
`input_tokens_context_proxy`. Every measurement requires a supported method,
nonzero sample count, observed maximum bounded by the limit, and an artifact
SHA-256. Missing/null evidence and false unavailable claims fail validation.
Private context occupancy (`context_usage`) stays unavailable; host-accounted
cumulative input tokens are only a context-cost proxy. `report.py` compacts raw
interactive evidence by an allowlist and computes ranges/maxima plus signed
matched deltas. It does not compute p95 from five samples or grade semantics
from arm parity. [Operation methods](../../docs/findings/mcp-m0-baseline/OPERATIONS.md)
record host scope, controls and reproduction commands.

`tasks.json` contains six independent tasks. Each `files` mapping is a trial
workspace, `prompt` and control questions are given to the agent, and `rubric`
plus control answers and their bases stay outside that workspace. A grader
checks each criterion and each control independently against its answer and
records pass/fail; unsupported capability is an outcome, not a pass or an
exclusion. Do not give the agent this directory or copy the task JSON into the
workspace. The `materialize` function in `schema_test.py` demonstrates this
boundary; production trial infrastructure must use the same allowlist and a
fresh isolated destination. It must not expose the checkout containing rubrics.
No task executes a model. Do not derive expected answers from MCP responses.
The compiler-edit scenario asks for a validation procedure; the grading rubric
requires the B-specific build and identity, not execution of a compiler edit.

All records are closed objects: missing or extra fields fail validation.
`validate_task` requires `id`, `category`, `prompt`, `files`, `controls`, and
`rubric`; controls contain `id`, `question`, `answer`, `basis` and rubric
criteria contain `id`, `answer`, `basis`. Files have safe relative paths.

Version 1 `validate_event` requires `schema_version`, `session_id`,
`request_id`, `tool`, `classification` (`probe` or `organic`), `event`
(`start`, `finish`, `protocol`, `cancel_requested`), `outcome`, `duration_ns`,
and `response_bytes`. A finish has a success, tool_error or protocol_error
outcome and nonnegative duration and response size. Other events require null
outcome and measurements. Request identifiers are server-generated sequence
numbers, never client request IDs. Session identifiers are supplied by the
collector. A cancel request is not evidence of cancellation.

Version 1 `validate_run` requires `schema_version`, `run_id`, `task_id`, `arm`,
`outcome`, `attempted`, `completed`, `passed`, `failed`, `skipped`.
Outcomes are success, incorrect, unsupported, startup_failure, tool_error,
protocol_error, crash, timeout, cancelled, observer_failure. Counts are
nonnegative integers, completed = passed + failed, attempted = completed +
skipped. Success requires at least one pass and no failures or skips. The
collector may need a versioned extension for resource metrics and detailed
protocol failures; these are not represented by this minimal schema.

Run `python3 -m unittest discover -s scripts/mcp_bench -p '*_test.py'`.

`collect.run_process(command, environment, transcript, limits)` runs newline
JSON-RPC bytes in a fresh temporary workspace under Linux cgroup v2 and a
private PID/mount namespace. It requires root authority, a root-owned writable
current cgroup delegation with `cgroup.kill`, namespace creation/mount authority,
and permission to drop user/group credentials. Missing authority returns
`unsupported` before executing the worker. Root UID alone does not establish
support. Other platforms return `unsupported` before launch; macOS remains
unimplemented and unvalidated.

The worker has a leased unprivileged UID, no supplementary groups or capabilities,
and `no_new_privs`; its cgroup mounts are read-only. It cannot signal its root
namespace init or address processes in another run's PID namespace. The collector
keeps the deadline outside this boundary, kills only its unique cgroup on every
exit, and waits for the kernel's `populated=0` acknowledgement before removal.
Namespace PID 1 exiting makes the kernel kill and reap the remaining namespace
members, including detached double forks. The private supervisor's environment
is fixed; the caller's explicit environment reaches only the unprivileged worker.
This process boundary does not provide a general filesystem or network sandbox.
Workers retain read access to public host files; do not put private grading
material in publicly readable host paths.

The required `compiler-soundness` CI job runs
`sudo env MEDAKA_MCP_REQUIRE_AUTHORITY=1 sh test/diff_compiler_mcp_collector.sh`
on `ubuntu-latest`. It assumes sudo grants root,
a writable private cgroup v2 delegation, cgroup.kill, PID/mount namespace and
credential-drop authority. Missing cgroup authority fails the suite; missing
namespace or credential authority fails the actual process tests. GitHub Actions
runner support for these assumptions must be validated by the orchestrator's CI.
For a bounded local host check use the same command under a five-minute timeout.

Host acceptance requires running the suite with those authorities. A restricted
run explicitly skips process tests when cgroup authority is unavailable while
still testing schema, reconciliation, and fail-before-launch behavior. Skips are
not evidence that host process containment passed. The environment contains only PATH and a private HOME plus the
explicit `environment` mapping. Pass a validated task as `limits["task"]` to
materialize its files and questions, without answers or rubric, into the workspace.
The collector returns a validated run without payloads. A caller that needs
answer comparison can supply `response_callback` in `limits`; this callback
receives sensitive responses and must keep them private. `trace=False` selects
an uninstrumented worker. Timeout and observed cancellation are distinct from
`cancel_requested` telemetry. Invalid protocol output is a protocol error;
missing or malformed telemetry and collector output limits are observer failures.

Version 2 run records extend version 1 with monotonic `wall_ns`, and explicit
`cpu_ns`, `peak_rss_bytes`, `resource_scope`, and `resource_reason`. The last
is a mapping from each resource metric to its unavailability reason, or null
when measured. Nonnegative values use nanoseconds and bytes respectively and
the named scope. On both Linux and macOS the portable collector reports CPU
and peak RSS unavailable for the worker process tree; it does not attribute
process-wide aggregate measurements to a run. Wall time includes process startup
and observation. `summarize` retains each metric value, scope, and reason.

`trials.py` provides pure preparation and import; it does not launch an agent or
assert that arm isolation is enforceable. `trial_manifest` exports only source
files, neutral prompt and control IDs/questions, with a fixed 600-second and
30-call limit. The host must enforce the limits and record attempts separately
from admissions. `import_transcript` returns a `trial-run-1` record containing
one or two attempts; a second attempt is accepted only after an infrastructure
error. Each attempt carries its outcome, answer, raw request/result bytes, actual
usage counters (null when unavailable), a completeness flag and a SHA-256
content reference to retained evidence. The caller owns persistence and must
verify that the referenced artifact matches its digest. Raw bytes require a
lossless encoding when persisted as JSON. An unknown outcome stays unknown.

`grade` consumes independent per-criterion and per-control judgments, each
with its task-spec basis and content-addressed evidence reference. The caller
must independently inspect the answer and artifacts against that basis; the
function cannot establish the truth of a supplied judgment or verify a digest.
Missing judgments and missing answers produce an unknown verdict, wrong controls
produce an incorrect verdict, and all criteria and controls remain in the
reported denominator. The task rubric and control answers stay outside the
trial workspace. No trial records are created by these functions.

`trial_host.py` is the trusted Linux launcher. The same campaign orchestrator
calls `launch(spec, output, cli, cli_hashes, original, original_hashes, auth_file)`
serially; this module does not schedule corpus tasks or grade answers. Use a
fresh, nonexistent output path. The caller supplies the neutral `trial_manifest`
and verified installed-distribution fingerprint maps, never the task rubric.
The launcher pins Codex CLI 0.166.0, Terra/high and the 600-second/30-admission
budget. `seconds` may shorten the deadline for synthetic controls. The clock
starts before sandbox and app-server setup. An independent watchdog closes
admission, interrupts the turn and kills active namespace roots at expiry or
budget exhaustion. Namespace PID teardown kills detached descendants. Attempts,
admissions, denials and dispatched operations are distinct recorded quantities.
Exhaustion can cancel already-admitted operations before dispatch or completion.

Build the identical shell toolchain for both arms in its own scratch checkout:

```text
python3 scripts/mcp_bench/build_cli_artifact.py /absolute/repository /new/scratch/artifact
```

The helper checks out baseline `0d10b7998`, removes the MCP module import and
server entry point in that scratch compiler, formats/lints, then builds normally.
It records the exact source patch, source identity, toolchain versions and every
installed-file hash. It does not borrow an emitter. Installed files are the
new CLI, its own built emitter, baseline stdlib and C runtime. Generated prelude
interface/tree/decl caches are omitted: their compiler fingerprint differs between
the preserved server and the CLI artifact. Goldens are omitted from the install.
Keep the original uninstrumented binary unchanged. The trusted MCP distribution
uses that preserved binary, with the same stdlib/runtime and built emitter;
record its file hashes separately. The preserved binary's expected SHA-256 is
`4b05aab61552d290a0e33d2b6f2f825290ecc61e24d9138f7fbaa829a19ee503`.

Both shell arms mount only system tools/libraries, a private proc/dev/tmp, one
fresh workspace, and the same read-only CLI distribution. Network, mount, user
and PID namespaces are fresh and capabilities are dropped. The original MCP
distribution is mounted only in the enabled arm's separate broker namespace;
the broker's private stdio is available only to trusted callbacks. MCP tools are
discovered from the real server's `tools/list`, using protocol `2024-11-05`.
Direct/copied/renamed CLI execution cannot restore its omitted server entry point.
No source checkout, campaign directory, home, auth store, grading material or
sibling workspace is mounted. Authentication is referenced only from the fresh
trusted app-server home; native shell, apps, plugins, web and multi-agent tools
are disabled. Dynamic shell/MCP callbacks reserve budget before dispatch.
Missing namespace authority or mismatched artifact hashes fails before agent
launch. The host is Linux-only; macOS is unavailable.

Each attempt retains app-server JSONL, host admissions/dispatch/results JSONL,
generated protocol schema fingerprints, result files and `summary.json` outside
the sandbox. Request/result bytes use base64. Account metadata notifications are
redacted. `result_bytes` counts callback payload bytes successfully written to
app-server stdio; each result separately records delivery. The transcript is the
authority for emitted wrappers and requests, including rejected callbacks.
Token counts come directly from `thread/tokenUsage/updated`; interruption leaves
`usage_complete=false` and preserves the last update, or null if absent. Private
model read/context counters, CPU and process-tree peak RSS remain unavailable
(null); context-window capacity is not a usage measurement. The caller must
retain and verify the returned JSONL hashes before importing or grading.
`run_with_retry` retains attempt 1 and permits exactly one fresh attempt after
`infrastructure_error`; task failures, cancellation, timeout and denials do not
retry. It records prelaunch infrastructure exceptions as well.

The existing collector gate discovers `trial_host_test.py`. Default runs execute
deterministic budget, artifact, workspace and retry controls and explicitly skip
privileged host tests. On an authorized Linux host with Codex installed, run:

```text
MEDAKA_TRIAL_REQUIRE_AUTHORITY=1 python3 -m unittest discover -s scripts/mcp_bench -p trial_host_test.py -v
```

This adds namespace/network canaries and scaled deadline controls, including a
synthetic app-server stream exercising the complete watchdog and detached child
cleanup. It does not execute a model. Actual tiny non-corpus model controls and
their immutable evidence belong to the campaign directory. A privileged test
skip does not establish isolation support.
