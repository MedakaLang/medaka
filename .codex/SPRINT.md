# Codex sprint adapter

Use the same workflow as Claude: `.claude/skills/sprint-plan/SKILL.md`,
`.claude/skills/sprint-orchestrator/SKILL.md`, and
`.claude/skills/sprint-packet/SKILL.md` are the operating instructions.
Read the skill for the current phase. This file translates harness mechanics;
it does not add a review round, a ledger, or per-slice acceptance checks.

## Keep the implementation loop moving

Running `sprint-orchestrator` requests delegation to the sprint roles below.
Keep one implementer working while you prepare the next packet. Integrate a
successful return and dispatch the next ready slice without waiting for CI or
repeating the worker's checks. A report finding goes into NOTES.md for the end
review unless it blocks a later slice. A packet's 3–5 checks remain the ceiling.

Use the shared workflow's one end review and parallel style pass, fix round,
and merge queue. Do not substitute the general compiler roles: their separate
design/implementation/verification contracts are not the sprint workflow.
Keep STATUS.md and NOTES.md as the resumable state. Do not revive the retired
seats, per-slice reviewer pairs, or continuation/verification ledgers.

## Dispatch and models

The agent definitions in `.codex/agents/` load the corresponding Claude role
body. Ignore that body's Claude-specific frontmatter and apply these mappings:

| Claude role or tier | Codex dispatch |
|---|---|
| `sprint-implementer`, routine `sonnet` slice | `sprint_implementer` with `gpt-5.6-terra`, `high` (the repository defaults in `.codex/config.toml`) |
| `sprint-implementer`, tricky `opus` slice or justified upgrade | `sprint_implementer` with explicit `gpt-5.6-sol`, `high` |
| `sprint-reviewer` | `sprint_reviewer` (Sol, high) |
| `sprint-retro` | `sprint_retro` (Terra, high) |
| End-round style pass | General agent with Terra/high, loading `.claude/skills/style-review/SKILL.md`; read-only work, no build |

These are workflow tiers using this repository's model choices, not a claim
of model equivalence. Preserve an explicit user model selection. Record the
resolved model in the packet. The implementer role deliberately leaves its
model unset: routine slices inherit the Terra/high defaults from
`.codex/config.toml`, while a tricky slice or justified upgrade passes
Sol/high explicitly at dispatch.

### Choosing an implementation tier

For Codex planning and every fix packet, start at **Terra/high**. Choose
from the reasoning still left to the implementer, not the issue's severity or
subsystem. A settled remedy with named sites, an existing pattern, and bounded
acceptance checks stays Terra even for an S0, compiler internals, several
coupled files, or a large test matrix.

Use **Sol/high** when the implementer must resolve a specific open semantic or
algorithmic decision where competing plausible answers require substantial
reasoning. Name that decision in the contract or fix packet's model justification;
"cross-cutting", "high risk", and "compiler work" alone are not justifications.
For example, propagating an already-chosen representation through its consumers
is Terra; deciding an unresolved coherence rule and its consequences can warrant
Sol. If planning settles the decision, reconsider whether implementation still
needs Sol.

A review finding does not inherit the reviewer's tier. If the reproducer,
invariant, and remedy are settled, the repair remains Terra; "confirmed S0" or
"compiler state loss" alone does not justify Sol. Keep directly related cleanup
in the same bounded packet; do not create extra dispatches to separate cheap work.

When uncertain, start Terra and use the existing refusal/upgrade path for a
concrete reasoning blocker. Missing prerequisites, permissions, or a broken
build need repair, not an automatic model upgrade. Do not add a design agent,
review round, or model-share quota. This default concerns implementation only:
retain the selected planner model and the Sol end reviewer above.

Use native subagent tools and fresh context for every new dispatch, including
fixes and retro. With a tool that offers `fork_turns`, use `none`: the packet
and cited files are the handoff.
Pass the packet's absolute path and the assigned worktree path. Save the
returned agent ID beside that slice in STATUS.md so the user can find it with
`/agent`; no separate agent registry. Reuse a worker for a bounded continuation
of the same packet, not as a permanent seat across unrelated slices.

### Resume checkpoint

After compaction or session resume, read this section before the next wait or
dispatch. Preserve it by reference in the compaction handoff, alongside any
active agent IDs, process sessions, and outer cell handles; do not create a ledger.

- Re-establish both wait durations from the effective host instructions, not
  just the inner poll: 180,000 outer / 170,000 inner when three-minute idle
  waits are allowed, or 60,000 / 55,000 under a one-minute cap. Put the pragma
  on every long execution call, including the initial command.
- Resume an outstanding outer cell before polling its process; do not restart
  a command because its handle was omitted from a summary. Require process exit.
- New dispatches still use `fork_turns: none`; a fix still needs its own model
  decision under the rubric above. Compaction does not change either default.

## Worktrees and packet setup

Codex's native spawn does not imply Claude's `isolation: "worktree"`.
The orchestrator prepares a distinct writer worktree and unique local branch
at the packet's exact sprint-head SHA before dispatch, using `git worktree add
-b <unique-writer-branch> <absolute-writer-path> <base-sha>`. Put the real paths,
base SHA, and writer push ref in packet §2; no extra transport document.

If the harness provides worktree isolation explicitly, use it and the shared
packet's sync recipe instead. Otherwise replace that recipe's worktree mint
and checkout with a HEAD check in the prepared tree, then the normal build.
The worker checks the assigned tree's HEAD against the packet base; it does
not rediscover placement or merge main. Branches are unique per live worker,
including reviews; never reset another worker's `slice-work` branch.

Native spawn may retain the orchestrator's cwd. Override the shared role's
bare `git rev-parse --show-toplevel` setup: use
`git -C <assigned-worktree> rev-parse --show-toplevel` and
`git -C <assigned-worktree> rev-parse HEAD`. Set command tools' `workdir` to
that absolute path, use `git -C` / `make -C`, and resolve every file read or
edit against it. A worktree path in the brief does not change the tool's cwd.

Choose worktree and report locations writable under the active permissions.
Use the existing sprint directory when available; otherwise keep the same
layout under an allowed scratch root, such as `/var/tmp/medaka-scratch/sprints/`.
Supply one authoritative sprint directory in the brief. A permission failure
is an environment problem to resolve, not a reason to share the orchestrator's
checkout or ask a worker to proceed without a build.

Workers stage by owned path, commit, and push to the packet's unique writer
ref. Only the orchestrator integrates the reported SHA into the sprint branch
and owns PR/issue/CI operations. Proven-disjoint parallel writers still follow
the shared workflow's dispatch-time disjointness check and serial integration.

## Reports, waits, and intervention

Workers write the shared role's report directly and incrementally to the
assigned path; they return the verdict and path. Reviewers may write their
report and build/probe artifacts, but do not edit source. The retro writes
`<sprint-dir>/RETRO.md`. If a report path is unexpectedly unwritable, return
the complete report for the orchestrator to persist; this is a fallback, not
a mandatory relay on every dispatch. Preserve the packet's five author
self-check answers inside Notes.

### Waiting for agents

The one-minute cadence is a host instruction, not the wait tool's ceiling.
For a local installation that should allow longer idle waits, Codex's
user/profile `developer_instructions` can explicitly permit interruptible
waits up to three minutes and meaningful-change updates while idle, retaining
the active-work cadence and all interruption/permission rules. Verify the
effective instructions in a fresh session; this adapter cannot override a
higher-priority host rule.

Custom roles replace the inherited `developer_instructions` field. The three
sprint role TOMLs therefore carry the idle-wait policy themselves; keep their
policy paragraphs identical. Validate a fresh `sprint_implementer` and
`sprint_reviewer`, not just a generic child, after changing this configuration.

Prepare the next packet during useful overlap, then hold one
`collaboration.wait_agent` call while there is no independent work. Use the
longest timeout permitted by the host instructions: for example, 180,000 ms
when allowed, or 60,000 ms when the host caps waits at one minute. A long wait
can return early for a message or completion; its timeout is not a mandatory
delay. Do not shorten it to audit status, read unchanged reports, or send
"still running?" messages.

A wakeup is not necessarily completion. Handle progress, questions, and user
intervention, then wait again for the outstanding workers' final reports.
An ordinary timeout means continue waiting, not redispatch or failure. Do not
end the orchestrator turn hoping a child's final answer will restart it:
automatic resumption was not observed in the tested harness. Honor host
progress-update requirements; these instructions do not override them.
Send inter-agent updates when the recipient needs to act, such as a blocker or
question. The final reply already delivers the report; do not duplicate it
with `send_message`, which can wake the recipient for the same result twice.

### Waiting for commands

A returned process `session_id` means the command is still running. Finish
every build, gate, and CI watcher inside the turn that starts it. For a known
long command, use `exec_command`'s 30,000 ms initial yield, then poll the same
process with `write_stdin` and an empty `chars`. Use substantial waits rather
than repeated 1,000 ms polls; a wait does not rerun the command.

With `functions.exec`, set the OUTER yield too: its default 30,000 ms can
return a running cell halfway through a longer process poll, adding another
model turn just to wait on the wait. Choose both durations within the host's
limits, leaving room for the result to return:

| Host permits idle waits up to | Outer `functions.exec` yield | Inner `write_stdin` wait |
|---|---:|---:|
| Three minutes | 180,000 ms | 170,000 ms |
| One minute | 60,000 ms | 55,000 ms |

For the three-minute case, put the pragma on the first line and substitute the
actual process handle for `processSessionId`:

```javascript
// @exec: {"yield_time_ms": 180000, "max_output_tokens": 2500}
const result = await tools.write_stdin({
  session_id: processSessionId, chars: "", yield_time_ms: 170000,
  max_output_tokens: 2000
});
text(result);
```

Under a one-minute cap, change BOTH numbers to the table's shorter pair.
Use that outer pragma for the initial long `exec_command` call too. If the
host requires shorter waits, reduce both durations while retaining headroom.
If an outer call still yields a `cell_id`, resume it with `functions.wait`
before issuing another process poll. A cell handle and a process handle are
different; never poll the same process concurrently. Preserve `session_id`,
`exit_code`, and output in the tool result, not only stdout. Empty output and
progress text are not success. Even `Script completed` from the outer tool
only means its JavaScript finished: if the enclosed result still has a process
`session_id` and no `exit_code`, continue polling. Require an explicit process
exit code; report nonzero as a failure. Do not end a worker turn with a command
still active.

For CI, prefer the existing `scripts/pr.sh watch` process over repeated model
turns issuing individual status queries. Apply the same command-wait pattern.
Measurements and a manual reproduction recipe live in
[the workflow dossier](../.claude/dossier/workflow.md#w-codex-waits).

### Intervention

The packet's refusal license protects its scope from informal amendments.
It does not override a direct user instruction to stop, pause, or correct the
task. Honor that intervention, let the orchestrator reconcile any changed
scope in the packet, and continue only under the revised assignment. For the
shared workflow's small direct fixes, wait until no worker owns the affected
paths and no build is reading them; do not race the implementer.
