---
name: orchestrator-wrapup
description: Close out an orchestration session cleanly — verify every issue encountered is tracked, every pinnable open bug has a self-draining fixture, all child worktrees and orphan processes and scratch artifacts are reaped, and any durable learnings are written into the docs/memories/skills so the next session inherits them. Run at the END of any multi-agent orchestration run (a bug-fix campaign, a bug hunt, a staged feature) — BEFORE you tell the user "done."
---

# Orchestrator session wrap-up

**The failure this prevents: loose ends evaporate.** Across a long run you spawn a dozen
agents, each surfacing friction, residuals, and "I'll remember that" items; you leave
worktrees, oracle pools, and scratch binaries behind; you learn three things that would
save the next orchestrator an hour. None of it survives unless you deliberately land it.
"Done" is not when the last PR merges — it is when the tree, the tracker, and the docs are
consistent with what you actually learned.

**The governing principle — DERIVE the state, do NOT trust your memory of it.** By the end
of a long session your recollection of what you filed / pinned / cleaned is the least
reliable record there is (that is the whole reason the tracker and `git worktree list`
exist). Every step below is a *re-derivation from ground truth*, not a checklist you tick
from memory. Run the commands.

---

## Mode — v8 sprint

When closing a `medaka-throughput-sprint` v8 run, use its compact run record:
`CONTRACT.md`, `STATUS.md`, `NOTES.md`, packets, and reports. `STATUS.md` and
`NOTES.md` are the only state ledgers; do not require `FRICTION.md`,
`DECISIONS.md`, `OBLIGATIONS.md`, `FINDINGS.md`, or reports with legacy six
sections. Derive residuals from `NOTES.md`, landed/refused/dropped rows, the
reviewer/retro reports, and PR/CI readbacks. The tracker, self-draining-pin,
safe-worktree, process, scratch, and learning guarantees below still apply.

Codex agent liveness is derived with `list_agents`, not Claude task lists. It
is evidence only: it does not attribute arbitrary worktree paths or PIDs to
this sprint. Interrupt only a positively identified task-owned live agent with
`interrupt_agent`; where ownership is unclear, hold and report rather than
stopping a sibling's work.

## Step 1 — every issue encountered is in the tracker

Sweep three sources, because each hides a different class of loose end:

1. **Agents' residual reports.** In an ordinary orchestration, re-read the
   agents' friction reports and your conversation. In a v8 sprint, read
   `NOTES.md` plus slice/review/retro reports instead. Surface bugs, gaps,
   missing stdlib functions, misleading errors, stale docs, and workarounds.
   Each is triaged into exactly one of: **immediate fix** (did it), **filed
   issue**, or **no-action-with-a-one-line-why**. "I'll remember it" is not a
   fourth option — you won't.
2. **Review RESIDUALS.** Conformance/craft reviews routinely return non-blocking findings
   (a narrower bug the fix left open, an over/under-coverage gap, a pre-existing bug the
   change exposed). Each becomes a follow-up issue — `verified` if you reproduced it,
   `needs-repro` if it is code-grounded but unbuilt (don't launder an agent's claim into a
   confident `verified`).
3. **In-tree markers.** `grep -rnE 'TODO|FIXME|WORKAROUND|XXX|HACK' <files-you-or-agents-touched>`
   — a workaround tagged in code that nobody filed becomes permanent architecture.

Then confirm nothing you *think* you filed silently no-op'd:

```sh
gh issue list --state open --author @me --limit 50 --json number,title   # read them back
# ⚠️ file → READ BACK → reference. gh's write path can silently no-op; a predicted
#    issue number is always wrong. Never assert "#N is filed" without reading it back.
```

Label every issue with severity (`S0>S1>S2>S3`) + workstream (`ws:*`) + `verified|needs-repro`.
A residual with no severity label is invisible to the next "what should I work on."

## Step 2 — every pinnable OPEN bug has a self-draining fixture

The tracker self-drains only if each open bug is *pinned* — a fixture that reproduces the
bug today and flips RED (naming the issue) the moment it is fixed. **Filing a bug means
owing it a fixture.** Derive what is unpinned; do not assume:

```sh
sh test/must_fail_census.sh --all      # lists OPEN bugs with no must_fail pin
```

For each open bug you filed this session, attach the fixture that fits its shape (do NOT
force a must_fail pin on a shape it can't express):

- **check-side** (check wrongly accepts / rejects, wrong diagnostic) → `test/must_fail_fixtures/<N>-slug/`
  (`cmd: check`, asserting the current wrong exit).
- **run≠build / build-crash** → the build/build-run verb of the must_fail suite, OR the
  `diff_compiler_engines` corpus (asserts eval==native==wasm on THIS box — #509-safe, no
  absolute-value pin), OR a `diff_compiler_build` regression program.
- **shadow / obligation** → `test/shadow_fixtures/` or `test/run_check_agreement_fixtures/`.

⚠️ A fixture directory is a **shared corpus** — adding one enrolls you in every gate that
reads that dir. Word-bound your grep for consumers and run them. A pin that can't be
expressed today (blocked on a missing verb) is itself a filed-issue, not a silent gap.

Some bugs are genuinely un-pinnable right now (needs a language feature to express, or the
repro is machine-specific). Say so in the issue — an un-pinnable bug is a tracked bug, not
an excused one.

## Step 3 — reap child worktrees (safely — the box is shared)

Isolated subagents may leave `worktree-agent-*` / `fix/*` worktrees. In a v8
Codex sprint the conductor-created worktrees persist until the conductor
explicitly reaps them; do not assume automatic harness cleanup. Other runners
may auto-remove an unchanged isolated worktree, while merged or abandoned ones
with commits can linger.

```sh
git worktree list
```

For each worktree that is NOT your own and NOT a live agent's:

🚨 **"Nothing unmerged" is NOT "safe to remove" — that check alone will destroy live work.**
This block used to read `log --oneline origin/main..HEAD` → *"empty ⇒ nothing unmerged ⇒
safe"*. Measured 2026-07-25: a **sibling orchestrator's locked, actively-in-use worktree
reported empty** — because an agent that has not committed yet is indistinguishable, by that
query, from an abandoned tree. Following the old line literally would have deleted a live
session's uncommitted work. **Three signals, all required, all derivable:**

```sh
git -C <wt> log --oneline origin/main..HEAD     # (1) empty  => nothing unmerged
git -C <wt> status --porcelain                  # (2) empty  => nothing UNCOMMITTED
git worktree list --porcelain | grep -A3 "^worktree <wt>$" | grep locked   # (3) NOT locked
# (4) and no live process is sitting in it — the decisive liveness signal:
for p in /proc/[0-9]*; do readlink "$p/cwd"; done 2>/dev/null | grep "^<wt>"
git worktree remove <wt>                        # only when (1)-(4) all agree
git worktree prune                              # metadata for already-deleted dirs only; always safe
```

`git worktree remove` drops the **directory, not the branch** — so with (1)–(4) satisfied
there is genuinely nothing to lose. `prune` is unconditionally safe.

🚨 **ATTRIBUTION IS USUALLY THE REAL BLOCKER, AND IT DOES NOT RESOLVE.** `git worktree list`
shows `agent-<id>` names that say **nothing** about which session spawned them, and Codex
`list_agents` does not map them to paths either. On a shared box with several orchestrators this means
you frequently **cannot** tell your own agents' trees from a sibling's. When a check is
structurally unable to attribute what it found: **REPORT AND HOLD, DO NOT ACT.** Never
`git worktree remove` a sibling *session's* tree even when (1)–(4) say it is harmless — a
sibling may still be reading an agent's tree for **evidence** (measured: an orchestrator was
mid-investigation of an agent that had just disproved their own prescribed fix, and that
proof existed only inside that worktree). Post the derived counts to the fleet and let each
owner reap their own.

## Step 4 — reap orphan processes (never a box-wide kill)

The lethal one is a bare `build_oracles.sh` → an `xargs -P` pool that outlives
its agent's turn, dragging the shared box's load average. Some non-v8 runners
may respawn it; a v8 Codex run must reason from the live agent/process state and
must not assume a respawning harness.

```sh
ps -eo pid,etimes,args | grep -E 'build_oracles|xargs -P|clang' | grep -v grep
```

Reaping order matters:
1. **Use Codex `interrupt_agent` on the positively identified owning live agent FIRST.** Derive the live set with `list_agents`; if you cannot attribute the process to a task you own, do not interrupt or kill it.
2. Reap **only that agent's** PIDs: `ps -eo pid,args | grep "agent-<id>" | grep -v grep | awk '{print $1}' | xargs -r kill`.
3. **NEVER** `pkill -f build_oracles.sh` / `pkill -f 'xargs -P'` box-wide — it kills other
   sessions' builds (the sandbox blocks it, correctly). A *live* agent's own fan-out is not
   an orphan; leave it.

## Step 5 — scratch, /tmp, and dangling build artifacts

- **Your scratchpad** (the session-specific dir in your system prompt) and **`/tmp`** (RAM-
  backed tmpfs here) accumulate `.mdk` probes, `.bin` binaries, `.ll` IR dumps. Remove the
  files you created; leave anything under another session's scratch path alone.
- **Stray build artifacts in the repo:** `git -C <repo> status --short` should be CLEAN.
  Watch for root-level demo binaries or `*.bin`/`*.ll` an agent left un-gitignored, and for
  a stray `./medaka`/`./medaka_emitter` rebuilt in a tree you didn't intend. `git status`
  must show nothing you didn't deliberately commit.
- **The stash stack is SHARED across worktrees** — leave no stash behind (`git stash list`);
  if you must set work aside, a tagged WIP commit is safer than a stash on this box.
- **Branch cleanup needs reachability proof.** A clean removed worktree does not
  make its branch disposable. Require `git merge-base --is-ancestor <branch>
  origin/main` before normal deletion. If false, preserve the ref or create an
  explicitly authorized archival ref; never delete unique commits. Equivalent
  cherry-picked content does not make unique commits recoverable.

## Step 6 — write the learnings down (so the next session inherits them)

The residual reports (or, for v8, `NOTES.md` and its reports) and the surprises
you hit are worth more than the fixes. Route each durable one to where it will
actually be found:

- **`.claude/ORCHESTRATING.md`** — a *role* learning (a watcher pattern that lied, a
  merge-queue nuance, a false-bounce race, "reproduce before you trust the diagnosis"
  confirmed again). This is the orchestrator's own log — append here.
- **`AGENTS.md` / `compiler/AGENTS.md`** — a *codebase* trap (a gate that silently no-ops, a
  golden family a change moves, a stale doc claim an agent hit). Fix the claim, don't just
  note it; a wrong doc re-arms itself for every next reader.
- **memories** (`/root/.claude/projects/-root-medaka/memory/`) — a durable decision or a
  hard-won operational fact (e.g. a settled semantics decision, a seed/fixpoint gotcha).
  One fact per file + a one-line `MEMORY.md` pointer. Don't record what the repo already
  encodes.
- **a skill** — if an agent was *misled by a skill*, fix the skill. The skills lie about the
  code more often than anything; a corrected skill saves the next agent a whole cycle.

⚠️ **DERIVE-don't-encode still applies to what you write.** Prefer a fact with a derivation
(a command that re-checks it) over a bare assertion that will rot. If a doc/skill/AGENTS.md
edit is warranted, it rides in THIS wrap-up PR (or its own small docs PR) — don't leave it
uncommitted.

## Step 7 — final verification + the honest report

1. `git fetch origin && git rev-parse origin/main` — confirm `main` is where you think, and
   green (the last merges landed, nothing bounced back to OPEN and got forgotten).
2. Re-list what you closed vs. what's still open (`gh issue list --state open` for the
   labels you worked). State the residuals plainly — a wrap-up that hides three open
   follow-ups is worse than one that names them.
3. Report to the user: what merged, what's tracked-but-open (with issue numbers), what you
   cleaned, and any learning you recorded. "Done, all green" is a claim — back it with the
   derived state.

---

**One-screen checklist:**

```
[ ] every residual (FRICTION reports, or v8 STATUS/NOTES/reports) / review residual / in-tree marker → filed (read back the #) or no-action'd
[ ] every open bug pinned (must_fail_census.sh --all is empty of yours), or explicitly un-pinnable
[ ] git worktree list → merged/abandoned agent trees removed; none with unmerged commits destroyed
[ ] ps … build_oracles|xargs -P → interrupt positively identified Codex owner, reap its PIDs only; no box-wide pkill
[ ] scratch + /tmp cleaned; repo git status clean; no stray stash
[ ] durable learnings → ORCHESTRATING.md / AGENTS.md / memory / skill (committed, not dangling)
[ ] main fetched + green; honest report with open-issue numbers
```
