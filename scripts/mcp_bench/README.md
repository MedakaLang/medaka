# MCP baseline task contracts

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

The CI job `MCP collector privileged behavior` runs
`sudo env MEDAKA_MCP_REQUIRE_AUTHORITY=1 sh test/diff_compiler_mcp_collector.sh`
on `ubuntu-latest` with a five-minute job timeout. It assumes sudo grants root,
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
