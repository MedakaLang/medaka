# Pi sprint adapter

Use the shared workflow in `.claude/skills/sprint-plan/SKILL.md`,
`.claude/skills/sprint-orchestrator/SKILL.md`, and
`.claude/skills/sprint-packet/SKILL.md`. This adapter replaces harness mechanics,
not the six-section packet, acceptance ceiling, one end review, or merge queue.
Do not use the Codex adapter's spawn/wait commands in Pi.

## Prerequisites and roles

Pi discovers the canonical skills through `.agents/skills`; do not copy them.
Project context comes from `AGENTS.md`. The roles below explicitly read their
shared role bodies, so those bodies remain the workflow authority; ignore their
Claude frontmatter and apply this adapter's setup, models, and command handling.
Fresh worktrees may not inherit the parent's saved Pi trust decision. Required
skill/role reads are explicit; do not grant blanket trust to make them load.

**Subagents are an extension, not a Pi built-in.** This adapter requires the
installed `subagent` extension with the following contract: project-agent
scope, fresh child context, tool allowlists, automatic retained git worktrees
for any role with shell/write access, and non-blocking `subagent_start` plus
`subagent_status`/`subagent_cancel`. The upstream example alone is not
sufficient: verify the active tool descriptions and smoke-test isolation before
a sprint. Do not silently fall back to sharing a writable checkout. Local extension implementation on this installation:
`~/.pi/agent/extensions/subagent/` (not shipped by this repository).

Pass `agentScope: "project"` on every sprint dispatch. The default `"user"`
scope contains generic agents, not these sprint roles. Keep project-agent
confirmation enabled; approve only this trusted repository. Agent definitions
are discovered on each call, without `/reload`. A new session or `/reload`
is needed to refresh already-loaded project context/skills after edits.

| Shared role | Pi agent | Configured model / reasoning |
|---|---|---|
| Routine implementer, including settled fixes | `sprint-implementer` | `openrouter/openai/gpt-6-luna:high` |
| Implementer with a named unresolved semantic/algorithmic decision | `sprint-semantic-implementer` | `openrouter/openai/gpt-6-sol:high` |
| End correctness reviewer, including builds and adversarial probes | `sprint-reviewer` | `openrouter/openai/gpt-6-sol:high` |
| End style pass, source-only | `sprint-style` | `openrouter/openai/gpt-6-luna:high` |
| Wrap-up retro | `sprint-retro` | `openrouter/openai/gpt-6-luna:high` |

Keep the user's chosen planner/orchestrator model. For implementation, start
Luna/high. These GPT-6 roles use the OpenRouter API (billed separately from a
ChatGPT subscription): the Codex/ChatGPT provider rejects `gpt-6-terra` and
OpenRouter does not list that model. Verify live provider availability before
changing defaults again. Severity, coupled files, compiler internals, and test
volume alone do not justify Sol: name the decision the implementer still has to resolve.
Reconsider Sol if planning settles it; a fix does not inherit its reviewer's
tier. A permission/build failure is not a reason to upgrade the model.

The extension has no per-call model override. An explicit user model choice
requires updating the relevant role's `model` before dispatch, not merely
mentioning a different model in the task. Record the configured model in the
packet and verify the effective selection from the child transcript or the
child's `PI_PROVIDER`, `PI_MODEL`, and `PI_REASONING_LEVEL` shell variables.
Do not print credentials or dump the whole environment.

## Worktrees and packet §2

`cwd` is the **source checkout**, not the writer's eventual directory. The
extension mints a unique worktree and branch from that checkout's **HEAD**,
not from `main` or a remote ref. Uncommitted source files are NOT copied into
the worktree. Before dispatch, commit the intended input, pin its SHA, and
verify the source checkout's HEAD equals the packet base. Do not prepare a
second writer tree.

**Agent prompts are an exception:** discovery reads `.pi/agents` from the
parent SESSION's working directory, not the supplied `cwd` or the new worktree.
A dirty wrapper changes the child prompt despite an unchanged worktree HEAD.
Before dispatch, require both commands below to succeed with empty output in
the session's project tree (even if `cwd` names a different source checkout):

```sh
git -C <SESSION_TREE> diff --exit-code <base-sha> -- .pi/agents
git -C <SESSION_TREE> status --short --untracked-files=all --ignored -- .pi/agents
```

The status command alone exits 0 even when dirty: inspect its output. A dirty,
untracked, ignored, or base-mismatched role must be committed/aligned before
use. This pins repository-owned prompts, not the user's global extensions,
settings or model service. Keep those stable for the sprint too.

The extension appends the actual absolute worktree path, branch, and base to
the child's assignment. In packet §2, bind `TREE` to that injected path; use
these commands with literal resolved paths/SHAs (one command per shell call):

```sh
git -C <TREE> rev-parse --show-toplevel
git -C <TREE> rev-parse HEAD
make -C <TREE> medaka
```

The first output must equal the injected path; HEAD must equal §1's pinned
base. A mismatch is BLOCKED, never a license to reset or merge. Keep the
extension's unique local branch: do not run the shared Claude role's
`checkout -B slice-work` / `checkout -B review-head` or fetch/FETCH_HEAD setup.
Build in this tree; never borrow another tree's emitter. Resolve every read,
edit, fmt/lint target, and command against its absolute path.

Reports and packets live outside disposable trees, under the one authoritative
absolute sprint directory in the brief. They are intentionally shared handoff
artifacts, not permission to inspect another worker's compiler/build outputs.
A reviewer gets its own worktree at the pinned review head and may write
reports, scratch programs, and build artifacts, but never edit tracked source.
A style agent has only read/search tools and shares the source checkout;
freeze that checkout at the same review SHA until it returns. Its complete
inline report is persisted by the orchestrator. The retro may write only its
assigned report. Tool restrictions and worktrees are not a security sandbox;
shell-capable children must still respect ownership and permission denials.

Give every assignment its absolute source cwd, packet/contract path, ownership,
acceptance checks (or review scope), report path, and pinned base. Example:

```json
{
  "agent": "sprint-implementer",
  "agentScope": "project",
  "cwd": "/absolute/sprint-checkout",
  "task": "Execute /absolute/sprint-dir/packets/S-example.md. Source cwd: /absolute/sprint-checkout; base: <sha>. Work only in the injected worktree. Ownership and checks: packet sections 5 and 6. Report: /absolute/sprint-dir/reports/S-example.md. Push only to the packet's unique writer ref."
}
```

Workers commit by owned path and push only to the packet's unique writer ref;
only the orchestrator merges the reported SHA into the sprint branch and owns
PRs/issues/CI. Do not use `chain` for dependent slices: integrate each returned
commit before minting the next child's worktree. A chain does not integrate git.

## Completion, review, and recovery

Use `subagent_start` for each slice; it returns a job ID and worktree as soon
as the isolated workspace is ready, **not** a completion verdict. Do useful
independent packet/CI work while it runs. On the completion notification (or
later), call `subagent_status` with that ID and read its final report; never
spin on status or infer completion from a tool exit. `subagent_cancel` stops a
job owned by this Pi process and retains its worktree. On session shutdown or
`/reload`, in-flight jobs are cancelled rather than silently orphaned; inspect
the saved job status, worktree and processes on resumption. These jobs do not
survive a Pi process exit as running jobs. Every dispatch is fresh, including
fixes; there is no child resume/send-message handle. For a refused slice,
revise the packet and dispatch fresh after recovering useful owned edits.

For the one end correctness review and style pass, start two jobs against the
same pinned SHA and collect both results; the style job has read-only tools.
Parallel writers still require the shared disjointness proof and serial
integration. Children cannot delegate or ask interactive questions: they
return BLOCKED and the parent resolves the question. Direct user
stop/pause/correction instructions override the packet's refusal policy.

Run finite shell commands in the foreground with a suitable `timeout` in
seconds. Pi's `bash` returns completion and exit status, not Codex process or
cell handles. Do not background builds or CI watchers and then poll in model
turns; use a bounded foreground command and wait for its actual exit. Redirect
`medaka build` output to a log, preserve its exit code, then read the log; do
not pipe it into `tail`. If a command is denied, report the blocker, not a
weaker source-only substitute. Never claim an unrun check passed.

A successful start/status tool exit is not a successful slice: read the
report's verdict and evidence. Save the job ID, returned worktree/branch and
child session-file path in the existing STATUS.md row, not a new ledger. Shell-capable roles report
`PI_SESSION_FILE`; source-only reports remain in the parent tool result.
Child transcripts are retained under `~/.pi/agent/sessions/subagents/` on this
installation; the tool does not return a resumable agent ID.

**After compaction/resume:** read this adapter, CONTRACT.md, STATUS.md and
NOTES.md, then query each recorded job ID and inspect any interrupted child's
transcript, worktree and active processes before retrying. Cancellation or a
failed job can leave work behind. Do
not run two builds in one tree or redispatch while the old process still runs.
The installed extension retains worktrees even on failure/cancellation; it
does not promise process-tree cleanup. Stop/report if ownership is unclear.

After integration or an explicitly discarded smoke test, verify there is no
active process, no unpreserved edit, and all required commits/reports are safe.
Remove only that session's worktrees, their unique branches, and adjacent
worktree metadata files. Do not prune other sessions' trees or erase failed
work before deciding what to recover. No remote-ref deletion without approval.

## Readiness smoke test (manual, not a CI gate)

Before the first sprint or after changing the extension:

1. Dispatch `sprint-implementer` with a disposable, explicitly no-push smoke
   assignment. Verify a distinct worktree, exact base, actual model, and an
   on-disk report. Exercise `write`, `edit`, a local commit, and confirm the
   parent checkout did not change. Do not call this a pushed `LANDED` slice.
2. In that tree build with `make medaka`, then check/run/build a tiny program
   with `MEDAKA_STRICT=1`. Assert exit status and exact output from both engines.
3. Dispatch the actual `sprint-reviewer`, not generic `reviewer`; verify Sol
   selection, shell/probe/report access and no tracked-source edits. Exercise
   the concurrent source-only style return and `subagent_status`/cancel as well.
4. Verify GitHub read access with `gh api repos/MedakaLang/medaka` (select only
   repository name and permissions). This does not prove push, workflow
   dispatch, or merge rights; verify those by readback when genuinely needed.
5. Preserve the smoke reports outside disposable trees, inspect the parent
   diff, and reap only smoke-owned worktrees/processes. Report untested paths
   (especially cancellation and remote writes) rather than signing them off.
