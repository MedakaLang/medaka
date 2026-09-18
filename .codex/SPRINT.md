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

Use native subagent tools and fresh context for each slice. With a tool that
offers `fork_turns`, use `none`: the packet and cited files are the handoff.
Pass the packet's absolute path and the assigned worktree path. Save the
returned agent ID beside that slice in STATUS.md so the user can find it with
`/agent`; no separate agent registry. Reuse a worker for a bounded continuation
of the same packet, not as a permanent seat across unrelated slices.

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

A tool yielding a running session is not a completed build. Poll its handle
to completion in the same agent turn; do not end a turn to await a background
notification. The orchestrator prepares the next packet during useful overlap,
then waits for worker completion instead of repeatedly auditing status.

The packet's refusal license protects its scope from informal amendments.
It does not override a direct user instruction to stop, pause, or correct the
task. Honor that intervention, let the orchestrator reconcile any changed
scope in the packet, and continue only under the revised assignment. For the
shared workflow's small direct fixes, wait until no worker owns the affected
paths and no build is reading them; do not race the implementer.
