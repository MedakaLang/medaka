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
and `response_bytes`. A finish has a success or tool_error outcome and numeric
nonnegative duration and response size; other events have null outcome. The
latter two measurements may be null outside finish. This is a preliminary host
contract: protocol rejection detail and server event serialization must be
reconciled by the telemetry and collector slices before integration.

Version 1 `validate_run` requires `schema_version`, `run_id`, `task_id`, `arm`,
`outcome`, `attempted`, `completed`, `passed`, `failed`, `skipped`.
Outcomes are success, incorrect, unsupported, startup_failure, tool_error,
protocol_error, crash, timeout, cancelled, observer_failure. Counts are
nonnegative integers, completed = passed + failed, attempted = completed +
skipped. Success requires at least one pass and no failures or skips. The
collector may need a versioned extension for resource metrics and detailed
protocol failures; these are not represented by this minimal schema.

Run `python3 -m unittest discover -s scripts/mcp_bench -p '*_test.py'`.
