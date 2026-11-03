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
JSON-RPC bytes in a fresh temporary workspace and a separate process group. It
kills members of that group on completion or termination; detached descendants
can survive. The environment contains only PATH and a private HOME plus the
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
