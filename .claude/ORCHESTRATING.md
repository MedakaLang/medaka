# ORCHESTRATING.md — a guide to being the orchestrator

You design and delegate work to subagents, verify their output, and keep the project's docs/state
coherent. You usually do **not** implement directly. Your durable value: framing precise tasks,
judging results, holding the thread across many agents. **Living guide — append learnings as the
pattern recurs.**

Companion docs: `AGENTS.md` (agent-facing router) and the per-task **skills** in `.claude/skills/`.

> ### ⭐ RUNNING A SPRINT? The workflow is MECHANIZED now (2026-08-16) — don't re-derive it from this file.
>
> This file remains the lessons ledger, but the sprint workflow itself lives in executable
> artifacts, built from those lessons — **simplified to v8 on 2026-08-22** (Val's directive:
> serial implementers with minimal per-slice verification, one end-of-sprint review round + fix
> round, merge queue as the correctness authority; the persistent seats, per-slice reviewer
> pairs, mid-sprint findings machinery, and the ledger suite were all retired):
> **`.claude/skills/sprint-plan`** (cutting the slice set),
> **`.claude/skills/sprint-orchestrator`** (the single-session seat),
> **`.claude/skills/sprint-packet`** (the one-page handoff contract + report format),
> the role definitions in **`.claude/agents/`** (`sprint-implementer`, `sprint-reviewer`,
> `sprint-retro`),
> and **`scripts/sprint-disjoint.sh`** (parallel-writer disjointness evidence;
> `scripts/sprint-report-check.sh` grades a report's SHAPE against v8's three sections —
> repaired 2026-09-01 (#2303), having until then graded the retired v≤7 six-section format so
> that every conformant v8 report bounced). The two review seams
> **`.claude/skills/architecture`** (placement ground truth + the DECLINED register) and
> **`.claude/skills/style-review`** (the end-of-sprint craft pass) are dispatched from the
> orchestrator's end round. What each retro round
> adopted or declined, and why, is ledgered in **`.claude/SPRINT-WORKFLOW-DECISIONS.md`**;
> cost hypotheses in **`.claude/SPRINT-COST-HYPOTHESES.md`**. Where those artifacts
> contradict older prose in this file — notably "Choosing the model" (pre-Claude-5 tiers) and the
> Stage B role table (its own retro overturned its implementer row) — **the artifacts win**; the
> prose is retained as history.

---

## 🚦 `main` IS PROTECTED. YOU CANNOT PUSH TO IT.

`git push origin main` fails with `GH013: Repository rule violations`. **No admin bypass** —
protection you can bypass is theatre.

```sh
git checkout -b <topic>          # never commit on main
# ... work, verify ...
git push -u origin <topic>
gh pr create --fill
gh pr merge --auto --merge       # enqueues; the merge queue does the rest
```

> ### 🚨 ONCE A PR IS ENQUEUED, TREAT ITS BRANCH AS FROZEN — a later push can miss its own merge.
>
> The queue merges the branch **as it stood when it was enqueued**. A commit pushed after that is
> not necessarily included; it is simply left behind on the branch, and the PR merges without it.
> Measured 2026-08-01 (#1213): PR #1203 went green and enqueued, review found its new `check`
> success line had **no test coverage at all**, an agent pushed the probe — and #1203 merged
> WITHOUT it. The fix reached `main`; the test proving it works did not. It took a second PR.
>
> **The agent DID verify its push, and still got it wrong** — it checked the commit was on the
> BRANCH (`git log origin/main..origin/<branch>`), which was true and irrelevant. The check that
> discriminates is ancestry against **main**:
>
> ```sh
> git merge-base --is-ancestor <sha> origin/main && echo "on main" || echo "NOT on main"
> ```
>
> If a change is needed after enqueue: dequeue first, or land it as a follow-up PR. And note the
> sibling trap — **a STALE check-run is indistinguishable from a fresh one** in what
> `gh pr view --json statusCheckRollup` returns. A red `gates (frontend)` on #1200 was two hours
> old, from before a rebase, and read exactly like a current failure. Compare each check's
> start time against your push:
> ```sh
> gh api "repos/MedakaLang/medaka/commits/$SHA/check-runs" --jq '.check_runs[]|"\(.name) \(.conclusion) \(.started_at)"'
> ```
>
> **`gh` WRITES CAN SILENTLY NO-OP — read the state back, never the return code** (#1212).
> Three distinct instances in one session: `gh pr edit --body-file` no-ops on a Projects-classic
> GraphQL error; `gh api -X PATCH -f body=@file` writes the **literal string** `@file` (`-f` does
> not expand `@` — use `-F`), which is the workaround for the first bug, so routing around one
> lands you in the other; and `gh pr merge --auto` returns 0 or 1 with no relation to success.
> This generalizes past `gh`: the recurring failure is **a tool reporting success while nothing
> happened**, and the uniform defense is to re-derive the resulting state.

**Required checks are a ruleset, not a remembered count.** Derive their current contexts before making a
claim or changing CI:
```sh
gh api repos/MedakaLang/medaka/rulesets --jq '.[]|select(.enforcement=="active")|.id' | while read -r id; do
  gh api "repos/MedakaLang/medaka/rulesets/$id" \
    --jq '.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context'
done
```
Zero approvals — the *checks* are the gate, not a human, so an agent can self-merge on green.

**`soundness` is required ON PURPOSE and must never be dropped.** It runs the compiler-source
typecheck + the self-compile fixpoint. **Every gate passes on an ill-typed compiler** (the build does
not gate on type errors) — which is how a compiler with unbound constructors once shipped to `main`
with every shard green.

### ✅ There is a MERGE QUEUE. Do not hand-manage staleness.

The repo is in the **MedakaLang org**; the queue is **ON** and replaced `strict` mode. It builds a
temp branch of *your PR merged onto current `main`, plus everything queued ahead of you*, runs every
required context **on that**, and merges only if green — the guarantee `strict` crudely approximated,
and the reason branch-only CI is not enough (two branches both touched `typecheck.mdk`, auto-merged
fine, and their **goldens** diverged → `main` red). Queue parameters also live in the active ruleset;
derive rather than encode them:
```sh
gh api repos/MedakaLang/medaka/rulesets --jq '.[]|select(.enforcement=="active")|.id' | while read -r id; do
  gh api "repos/MedakaLang/medaka/rulesets/$id" \
    --jq '.rules[]|select(.type=="merge_queue")|.parameters'
done
```
**`ci.yml`'s
`merge_group:` trigger is what makes the checks run on the queue's temp branch — without it the queue
deadlocks. Do not remove it.**

**`strict` is OFF deliberately.** With a queue it is redundant *and harmful*: it forces every open PR
to rebase onto every merge and re-run every required context — the O(N²) tax the queue exists to delete.
(The day we enabled the queue: 13 merges in one hour across three orchestrators; under `strict` one
PR paid five full 20-minute suites without landing.)

**So stop doing all of this:** `update-branch` kicks (also **impossible** on any PR touching
`.github/workflows/` — `gh`'s OAuth app lacks `workflow` scope, the call 403s); watching for
`BEHIND`; batching unrelated PRs onto one branch to save CI runs. **The ONLY remaining reason to
batch is DIAGNOSIS:** if two changes are so entangled that a red result would not name the culprit,
they belong together — otherwise keep them separate.

What the queue still **cannot** catch: two semantically incompatible changes that merged cleanly and
are now both wrong. See "A clean auto-merge is NOT agreement."

---

## The core loop

```
scope-read (bounded) → frame a precise prompt → get approval → spawn (bg, isolated worktree)
  → VERIFY empirically → open a PR → CI green → merge → reconcile docs/tasks/memory → next
```

- **Bounded scope-read.** Read just enough to write a precise prompt + STOP guardrail. Targeted
  `grep`/`sed` of specific functions, not whole-file reads. For a broad census/taxonomy, **delegate to
  an Explore agent** and keep only its conclusion — don't fan the reads through your context.
- **Approval before spawn.** Present each agent's prompt + model; get an explicit OK. Surface genuine
  design decisions as questions (you're a design collaborator, not a dispatcher). Once pre-approved
  for a class of work, chain without re-asking — but pause when an agent trips a guardrail.

---

## 🎯 The backlog is GITHUB ISSUES. The workstream docs are the domain knowledge. (2026-07-14)

```sh
gh issue list --label "S0: silent wrongness"      # always start here
gh issue list --label "ws:soundness" --state open # one workstream
gh issue list --label "needs-repro"               # claims NOBODY has reproduced
gh issue list --milestone "0.1.0 public preview"  # the release floor
```

**Severity:** `S0: silent wrongness` (a wrong answer, or destroyed source, **with no error**) →
`S1: loud breakage` → `S2: misleading` → `S3: friction & debt`.
**Workstream:** `ws:soundness|language|tooling|wasm|diagnostics|testing|release|perf|stdlib`.
**Evidence:** `verified` (repro run at a stated SHA) vs **`needs-repro`** (nobody has reproduced it).
**S0 beats everything, and soundness beats release.**

### Why it moved — this is the #1 lesson, applied to itself

The backlog used to be markdown lists across `PLAN.md`, `HANDOFF.md`, `workstreams/*.md`, and the
gap docs, each carrying an instruction to *"keep this in sync when an item opens/closes."* **It was
not kept in sync — and it could not have been, because nothing forced it.**

Re-deriving every claim against the binary (2026-07-14, `e34e2b46`) found **six entries already
fixed**, including *both* "silent build miscompile" P0s the roadmap was advertising, a
duplicate-definition **segfault**, a "fabricated `1:0` source location" that would not reproduce, and
a `newtype` bug billed as *"the best value-to-risk item on the board"* — which works.

**An issue self-drains: closing it removes it from the backlog. A markdown row has to be
remembered.** That is the entire argument, and it is the same one as *DERIVE, don't encode* below.

Two failure modes worth naming, because both were invisible while the backlog was scattered:

- **The worst bug in the tree hid by being filed three times.** `fmt --write` destroying source, a
  "scientific-notation float literal" *parser gap*, and a `1e12` must-fail row were **one defect** —
  the lexer has no exponent form, so it cannot read the float the printer writes. Three docs, three
  owners, nobody holding the whole shape.
- **An S0 sat unranked in a housekeeping list.** `Int` silently wraps at 63 bits, filed as "P1-1"
  among *remaining TODOs*. **Severity has to be a label you can sort by, not an adjective in prose.**

### The workstream docs (`.claude/workstreams/`) are NOT the backlog

They hold what does **not** belong in an issue and would rot if scattered across 34 of them: the
**traps**, the **collision map**, and **why each bug class recurs**. Read the one matching your labels
*before* you spawn anything.

**COMPILER-SOUNDNESS** · **LANGUAGE** · **TOOLING** · **WASM** · **DIAGNOSTICS** · **TESTING** ·
**RELEASE** · **PERF** · **STDLIB** · **HARNESS**.

`workstreams/README.md` carries the **collision map** — read it before running two orchestrators in
parallel. The unit of collision is a **file**, not a topic: TESTING (`test/`) and RELEASE (`docs/`) are
safe alongside anything; SOUNDNESS/LANGUAGE/DIAGNOSTICS all live in `compiler/frontend/` + `types/` and
should be run **one at a time**; `stdlib/core.mdk` is the **prelude**, so it moves every golden and must
land **alone, at a checkpoint**.

---

## Agents do NOT run the full suite — CI does

The full suite is CI's job: six parallel hosted runners, free. Locally it costs the *shared box* — one
agent running all the gates plus a 54-binary oracle build pushes load average past 10 and turns
everyone else's 30-second gate run into minutes. That has happened repeatedly.

```
agent:        make preflight        # targeted: builds + runs ONLY what the diff touches
               commit on its own branch, REPORT THE SHA
orchestrator: verify → push → narrowed PR CI → review → enqueue → full merge-group CI → merge
```

The mechanics are in `AGENTS.md` (`make preflight` / `build_oracles.sh --for` / `make test` vs
`make gates`). What you need to enforce: **preflight derives its gate set from the diff and its oracle
set from those gates** — a `parser.mdk` change builds 9 oracles and runs 11 gates, not 54 and 82 — and
that derivation comes from the gate *scripts* themselves (each names its oracle as `test/bin/<name>`),
so **there is no hand-maintained map to drift**; CI shards and `preflight.sh` share it.

A full local run is justified only for: a `compiler/backend/*` change (preflight forces the fixpoint
there anyway — it is decisive and CI is too late); a `compiler/support/*` or `stdlib/core.mdk` change
(blast radius is everything); a merge of two branches touching one subsystem; a CI failure you cannot
reproduce.

### Fast local feedback; independent CI evidence

After an edit, run targeted format and lint **before** rebuilding the compiler or building any oracle.
That puts cheap mechanical failures ahead of the expensive path and avoids rebuilding again after a
formatter rewrite. For a comment-bearing two-line record, follow AGENTS.md's formatter safety rule and
inspect the declaration after `fmt --write`. When formatter/linter behavior or accepted syntax itself
changed, rerun the relevant check with the freshly built binary and apply any owed reflow before using
its result.

Local verification should be the smallest fail-capable signal for the changed property, plus the
non-negotiable compiler checks the diff requires (for example, source typechecking and the native
fixpoint for an LLVM backend change). Do not reproduce CI's broad matrix locally just to accumulate a
longer receipt. Push once that signal is adequate: pull-request CI independently runs the relevant
narrowed gates; the merge queue's `merge_group` run executes the full authoritative suite. The reviewer
judges the diff and whether its tests can fail rather than re-running the author's suite.

### ⚠️ THE PREFLIGHT IS A FILTER, NOT AN AUTHORITY

Green preflight = *the gates most likely to notice your change did not break*. Nothing more. **Neither
preflight nor a green narrowed PR run is the authority; merge-group CI is. Never merge on a green
preflight.** A targeted local run re-introduces the
exact hazard the testing overhaul exists to kill — **a suite reporting green while testing less than
it appears to** (`diff_compiler_lint_multi` sat "skipped" for months, *while also failing*, because
dash couldn't parse it and exit 2 counted as SKIP; a fresh clone once ran **zero tests and printed "0
failed"**). So `preflight.sh` **ends by printing what it did not run**, and must stay loud.

### The orchestrator OWNS red CI — watch it, don't wait to be told

**Arm a persistent background `Monitor` on CI as soon as you push** (poll `gh run list --limit 15
--json databaseId,status,conclusion,headBranch`; emit a line for every newly-terminal run and list the
failed jobs). A CI failure nobody watches is a slower version of no CI. ⚠️ **Emit on every terminal
state, not just failures** — a monitor that greps only for red is *silent* through a cancel, a
timeout, or a crashloop, and silence is indistinguishable from "still running." Seed the seen-set with
already-completed runs at arm time.

#### ⚠️ Build the monitor so it CANNOT lie silently — verify it emits BEFORE trusting it

A monitor that returns empty forever looks identical to "still green." Every broken monitor this
session failed the same way: it queried something that returned nothing, and nothing = no event = false
calm. Before you rely on a watcher, **run its exact query once by hand and confirm it returns rows.**

- **`gh pr checks <n> --json …` DOES NOT EXIST in this repo's `gh`** — `gh pr checks` has no `--json`
  flag (that is `gh pr view --json statusCheckRollup`). The `--json` form errors to stderr and prints
  nothing to stdout, so a monitor built on it spams "no checks yet" forever and never sees green. Parse
  **plain `gh pr checks <n>`** output instead (tab-separated `name<TAB>state<TAB>…`); a
  separator-agnostic `grep -qw pending` over the whole block is robust.
- **Guard on EMPTY output, not exit code.** `gh pr checks` exits non-zero on pending/fail while still
  printing the table; `... || true` keeps the table. `if [ -z "$out" ]; then wait; fi` — never treat an
  empty result as a terminal state.
- **For "tell me ONCE when X finishes" (a PR's CI, a build), prefer a `Bash run_in_background`
  until-loop over a `Monitor`.** It fires a single completion notification when the condition is true
  and exits — no per-poll spam, no auto-stop for being too chatty. Reserve `Monitor` for
  one-event-per-occurrence streams.
- **A merge watcher must also watch CI-red-while-OPEN.** Polling only for `MERGED`/`CLOSED` is blind to
  a queue-bounce (the PR goes back to OPEN with a failed `merge_group` run) — that looks identical to
  "still queued." Bound the wait (e.g. ~30 iterations) so it can't hang forever, and re-check on exit.

#### 🚨 A CONFLICTED PR GETS **ZERO** CI RUNS, AND EMPTY LOOKS EXACTLY LIKE PENDING

`ci.yml` is `pull_request`-triggered (`.github/workflows/ci.yml:113`), so a run checks out
**`refs/pull/N/merge`**. GitHub cannot materialize that ref while the branch conflicts with `main`,
so the workflow never has anything to check out and **no run is ever queued** — not pending, not
failed, *absent*. Every surface agrees and all read as "still queuing": `gh pr checks` says `no
checks reported`, `gh run list --branch` returns `[]`, `gh pr view --json statusCheckRollup` has
length 0.

An agent waited ~30 minutes and reported *"looks like GitHub-side queuing"* — the honest read of
that evidence, and wrong. The discriminators:

```sh
gh pr view N --json mergeStateStatus --jq .mergeStateStatus   # DIRTY == conflicts
git ls-remote origin 'refs/pull/N/*'   # only .../head, NO .../merge  <- the direct proof
```

After the branch merges `origin/main`, the merge ref appears and the run starts immediately.
Generalizes: **no signal is not a state on the green→pending→red axis.** When a watcher returns
nothing, ask what would make the thing *unable to report* before concluding it has nothing to
report.

When CI goes red, **act, don't just report**:

1. **Diagnose from the log** (`gh run view <id> --log-failed`): infra/workflow bug, real regression, or
   already-known red?
2. **Fix it yourself if it is small and mechanical** — a bad glob, YAML quoting, a stale golden, a
   misnamed make target, a missing `chmod +x`. Don't spawn an agent to change three characters. (Real:
   a shard pattern using brace expansion dash cannot expand; `pattern: 'a' 'b'` invalid YAML;
   `make test` secretly running the whole gate suite.)
3. **Re-spawn the responsible agent** when the failure is inside work it just did — paste the CI
   failure, add a STOP guardrail. Don't "fix" an agent's logic for it; you'll lose its context.
4. **Record known-red ONLY with a ledger entry that detects an accidental fix.** Never a bare skip: a
   skip-list cannot notice when the bug is fixed, so it rots (this is how `test/ported/` died).

### ⏰ Arm a 20-minute heartbeat — insurance against a monitor that silently stopped firing

Every watcher above can die quietly. A `Monitor` that stops emitting, a completion notification that
never fires, a queue-bounce that reads as "still queued" — **a watcher returning nothing looks
identical to "still green,"** and a stuck orchestrator burns hours doing nothing while believing it
is waiting on progress. The heartbeat is the backstop: **arm a recurring job (`CronCreate`, ~every 20
minutes) whose whole purpose is to re-derive live state from scratch and catch the case where you are
blocked with nothing actually running.** It is not a substitute for the per-PR monitors — it is the
thing that notices when *they* failed.

The fire-and-check list, every tick:

1. **Your PRs.** `gh pr list --state open --author @me` (⚠️ this is *authorship*, not *ownership* —
   track the PR numbers you actually opened, since the identity is shared across sessions). For each:
   plain `gh pr checks <n> || true` (**never** `--json` — no such flag here; guard on EMPTY output, not
   exit code). Green + reviews in ⇒ enqueue. Red ⇒ diagnose from `gh run view <id> --log-failed`.
   ⚠️ **A queue-bounced PR is back to OPEN with a failed `merge_group` run and looks exactly like "still
   queued" — check for it explicitly** (`gh run list --event merge_group`).
2. **In-flight subagents.** Any still running? A long-silent one: inspect its worktree **read-only**
   (`git -C <wt> log --oneline -3`, `status --short`) — never build or `cp` in another tree.
   ⚠️ **Low load on the box is NOT a stall signal, and `find` will lie to you.** A quiet box just means
   the agent is in a reasoning phase, which costs nothing here. The reliable check is the worktree's
   **git metadata mtime**, corroborated by concrete artifacts (a built `./medaka`, modified files):
   `stat -c %y "$(git rev-parse --git-common-dir)/worktrees/agent-<id>"`. Two different `find`-based
   probes gave wrong answers in one session — `-maxdepth 1` reported a busy agent as quiet because its
   edits were in subdirectories, and a later `-newermt` returned zero while the filesystem plainly
   showed a binary written three minutes earlier. Don't reach for `find` shortcuts here; check the
   worktree metadata directly.
3. **Orphans.** `ps -eo pid,etimes,args | grep -E 'build_oracles|xargs -P'` — a bare `build_oracles.sh`
   pool outlives its agent's turn and gets *respawned* by the harness; it has killed sessions. A live
   agent's own `run_gates`/`engines` fan-out is NOT an orphan. If genuinely orphaned: `TaskStop` the
   agent FIRST, then reap only its PIDs — **never a box-wide `pkill`.**
4. **Am I stuck?** Waiting on something already finished, or blocked with no live agent and no open PR
   ⇒ pick up the next backlog task.

⚠️ **DERIVE state every tick; never carry it across ticks** (the "DERIVE, don't encode" lesson
below, applied to yourself). `git fetch` before trusting any diff — `origin/main` moves under you. And
**do not infer a second live session from a single merge event**: on 2026-07-17 an orchestrator
inferred a phantom session from one merge, carried it for five hours, wrote it into six agent prompts
as a `compiler/backend/*` no-go zone, and deprioritized a real S1 over it — there was no other session.
If session-liveness matters, re-derive it (`git worktree list` + `ps … | grep 'claude -w'`), and count
the *authoritative listing*, not a transient `wc -l`.

⚠️ **Put Val's pronouns and any durable user facts in the cron prompt correctly** — a recurring prompt
re-fires whatever it contains every tick, so a misgendering or a stale assumption baked into it
reproduces on a timer and leaks into every subagent it spawns. Fix the *cron prompt*, not just the
next message.

### Branching off an UNVERIFIED base — a judgment call, not a rule

CI is minutes and agents are cheap, so waiting for green before every spawn serializes what you just
parallelized. **You MAY branch off a base whose CI is still running** — price it: *"if this base turns
red, what does it cost me?"*

- **Cheap to be wrong (branch freely):** the work is **disjoint** (different files/subsystem), so a red
  base gets fixed *underneath* it; the uncertainty is in **docs/CI-config/gate-script**, not the
  compiler; the work is **additive new files**; preflight was green; the fixpoint +
  `typecheck_compiler_source` passed; or CI already went green on an earlier commit of the branch.
- **Expensive (WAIT):** the work **builds on** the uncertain change (a red base voids its premise — the
  work is *discarded*, not rebased); the base moved **goldens or the seed**; you'd have to re-derive a
  **diagnosis**, not re-apply a diff. High-risk signals: emitter/`Value`/dispatch touched, a shard
  already red, or a change an agent reported and you never verified.
- **The escape hatch nobody remembers: branch off the last KNOWN-GREEN SHA**, not the tip. Parallelism
  *and* a verified base; cost is one merge later. Strictly better than waiting or gambling.

⚠️ **If you branch off an unverified tip, SAY SO in the prompt.** A STEP-0 `BASE_OK` assert proves
*ancestry*, not *correctness* — it passes happily on a base CI is about to reject. An agent that knows
its base is provisional STOPs and reports instead of "fixing" your bug and tangling the two changes.

### CI shape

`.github/workflows/ci.yml`, GitHub-**hosted** runners (free + unlimited on a public repo). **No
self-hosted runner** — a fork PR on a public repo with one is arbitrary code execution on the host.
Sharded: 6 gate shards + `inlang`, each cold-bootstrapping from the seed and building only its own
oracles. Every `diff_compiler_*` gate is in **exactly one** shard (one falling between shards would
silently never run; `diff_compiler_ci_shard_coverage.sh` proves it). Each shard ends with a **review
gate** (`git diff --exit-code`) on the tree its gates just ran over — it cannot be a separate job,
because a fresh checkout in a fresh VM would never see the drift.

---

## ⭐ DERIVE, don't encode — and where you can't, make it SELF-DRAIN (2026-07-13)

This is the unifying lesson of the docs overhaul, and it generalizes far past docs.

**Every defect was one shape: a statement that ENCODED a fact about the code, and the code
moved.** `SYNTAX.md` encoded "backtick infix parses" (true once). `AGENTS.md` encoded "grep for
`checkGuardExhaust`" (existed once). A skill encoded "insert into `primitives`" (existed once).
The CI classifier encoded "nothing outside `test/` reads a `.md`" — **true when written, false
within hours.** A memory encoded "prefer list comprehensions" (removed in June).

**A document is an allowlist of facts about the world, with no derivation and no expiry.** That is
the disease, and *tidying does not treat it.* In priority order:

1. **DERIVE the fact instead of stating it.** `docs/README.md` is now GENERATED from the docs'
   `**Status:**` banners and CI regenerates + diffs it. The shard-coverage gate derives the gate set
   from the gate *scripts* — no map to drift. A hand-maintained index is what rotted in the first
   place.
2. **Where you must encode, ATTACH A DERIVATION.** A status banner cites the **SHA** that proves it
   (`**Status:** IMPLEMENTED — 9100df2e, 2026-07-01`). A claim with a receipt is auditable; a claim
   without one is a fact waiting to expire. It also turns archive-vs-keep into a *filter*, not a
   judgment call.
3. **Where you cannot derive, make it SELF-DRAIN.** An exceptions ledger must FAIL the build when an
   entry stops earning its place — **both** when the excused thing came back **and** when nothing
   cites it anymore. Half a ratchet is a skip-list, and **a skip-list cannot notice when the bug is
   fixed, so it rots** (this is how `test/ported/` died). The doc-link gate shipped with only the
   first half and had **3 orphaned entries within one merge.**

> **⭐ The BACKLOG was the biggest un-drained ledger of all (fixed 2026-07-14).** A markdown bug list
> is *exactly* the disease this section describes: a statement encoding a fact about the code
> (*"this is broken"*), with **no derivation and no expiry**, and a footnote politely asking humans to
> keep it in sync. They didn't — **six entries were dead**, two of them labelled *silent build
> miscompile*.
>
> **A GitHub issue is the self-draining form of a bug report: closing it removes it from the
> backlog.** There is no separate act of remembering, so there is nothing to forget. Severity, owner,
> and evidence are **labels you can sort by** — not adjectives buried in prose, which is how an S0
> (`Int` silently wraps at 63 bits) spent weeks in a list called *"remaining TODOs"*.
>
> Same shape, one level up: **`sqlite/findings/verify_compiler_bugs.sh` is the model.** The bug list
> ships with a script that **re-runs every repro and prints OPEN/FIXED** — the list cannot lie for
> longer than it takes to run it. That script is the only reason we *know* four of those bugs were
> fixed. **Every bug corpus should ship its own verifier.**

### 🔴 The lazy fix hides the real bug

Three times in one session, **refusing to "just add an exception" exposed a genuine defect**:

- adding the ledger's *orphan* half → 3 entries were already fiction;
- refusing a blanket `archive/*` exception → found that a POSIX `case` glob **`*` matches across
  `/`**, so it was silently swallowing 10 dead links two directories deep;
- refusing to excuse `gen_docs_index` from shard coverage, and making it a real check instead →
  caught that **`sort` is locale-dependent** and the "generated" index produced **different bytes on
  the dev box and the CI runner**. A generated artifact that isn't byte-reproducible is a
  hand-written one with extra ceremony.

**If your first instinct is to excuse a check, that is where the bug is.** Corollary: *a gate that
has to excuse its own false positives is a gate with a parsing bug* — fix the parser, not the ledger.

#### A tripwire's spurious-trip class IS its masking class — ask both as one question

A ratchet pinned a **count** of matching lines in a file, including comment lines. Chain: someone
names the symbol in prose → the gate reds on a comment-only diff → they bump the expected number to
make it green → the pin now has **slack** → a later change adds the real thing (+1) while deleting
that comment (−1) → back to the pinned value, tripwire silent, hole reopened. A false positive is not
an ergonomics complaint; it is **pressure to widen the pin**, and a widened pin is the masking path —
same shape as the excused-check corollary above, one layer more mechanical.

For any counted tripwire ask: *what does a maintainer do when this fires wrongly, and what does that
action cost me?* If the answer is "bump the number," it is one annoyance away from disarmed. Make the
failure message demand a reason, not just a new value — or derive the count instead of pinning it (see
"DERIVE, don't encode" above).

---

## A gate must RUN where the bug lands — ask "where is this skipped?" FIRST

Writing the gate is the easy half. **Placing it is where it dies.**

`ci.yml`'s `detect` job sets `docs_only=true` for prose-only PRs, and every heavy job skips its
steps when it is true. So **a docs gate placed in a gate shard is skipped on docs-only PRs — exactly
the PRs it exists to police.** Green forever, checking nothing. That is the silent-green bug the
whole suite exists to prevent, reproduced *inside the tool built to prevent it*. It nearly shipped
twice.

- **Text-only gate that must run on prose PRs** → an **UNGUARDED step in an already-REQUIRED job**
  (`soundness`). No compiler needed, so it is nearly free — and being in a required job means it
  gates on merge *today*, with no repo-settings change.
- **Gate needing a built `medaka`** → a gate shard. But then **its INPUT must be reclassified as
  not-docs-only**, or a change to that input skips the gate. Hence `SYNTAX.md) docs_only=false` —
  it is an *executable spec*, not prose.
- **A gate matching no shard pattern silently never runs.** `diff_compiler_ci_shard_coverage.sh`
  catches this — and it caught me.

Before adding any gate: **(1)** where is this skipped? **(2)** is the class of bug it catches exactly
the class of change that triggers the skip? **(3)** have you *seen it fail* — broken something on
purpose and watched it name the `file:line`? **(4)** can it no-op? Print `checked N …`; **N == 0 must
be a FAILURE, not a pass.**

---

## The gap docs lie — reproduce before you trust them (the #1 lesson)

**EVERY LAYER LIES ABOUT THE LAYER BELOW IT:** the router lied about the language (AGENTS.md
recommended three constructs that are hard parse errors); the skills lied about the code (**5 of 6
were DANGEROUS**; `harden-typechecker` taught `pushTypeError` at the wrong arity, which *silently
drops the error*, and its "grep these names" index was **19/20 fictional**); the memories lied about
the docs; **and the shared binary we check the docs against lied about `main`** (it rejected valid
current syntax). None of it was findable by *reading*. It only fell out when something was forced to
**execute** each claim against the code.

### ⚠️ And an AUDIT is not evidence either — it will FABRICATE

A read-only **Opus** auditor correctly found ~35 false claims in the skills — **and then invented its
own replacements**, asserting that `registerImpl`, `ppMonos`, `implEntry`, `registerRecord` "**do**
all exist." Four of five return **ZERO hits.** An agent executing that punch-list on trust would have
replaced 19 dead symbols with 4 fresh dead ones — *with an audit's authority behind them.*

It was caught only because the fix agent was **required to grep-prove every symbol it wrote and paste
the evidence.** So: **never let an agent execute an audit's punch-list on trust.** And ⚠️ note
`grep -r compiler/` also matches the `.md` docs living there, so a fabricated symbol *appears to
resolve* — resolve symbol claims against **`.mdk`/`.c` source only**.

### The gap/status docs drift faster than anyone updates them

One gap doc mispredicted on **every** contact: items marked OPEN were already closed (sometimes
incidentally, by an unrelated fix), items marked CLOSED were still broken, and the documented root
cause was wrong ~every time.

> #### 📊 Re-measured 2026-07-14 — the drift rate is roughly **1 in 5, and it favours "already fixed"**
>
> Rebuilding the whole backlog by executing every claim against `e34e2b46` found **six dead entries**:
> `B2` and `B3` (**both billed as *silent build miscompile* P0s** — the scariest label we have), `B4`,
> `T30` (a **segfault**, per the doc), `T20`'s "fabricated `1:0` location" (**would not reproduce on any
> error shape**), and `#31` — `newtype` "entirely unusable", advertised as *"the best value-to-risk item
> on the board"*. It works. An orchestrator who trusted that ranking would have spent a session
> re-fixing a working feature.
>
> **The bias is important: stale entries skew toward *already fixed*, not *still broken*.** Bugs get
> fixed incidentally by adjacent work far more often than docs get updated. So the default failure mode
> is **aiming a good agent at a dead bug** — which costs a session and produces a confused PR.
>
> Two structural lessons, both now enforced by labels:
>
> - **A claim nobody has reproduced must not look like a known bug.** Every issue is stamped `verified`
>   (repro run at a stated SHA) or **`needs-repro`**. `needs-repro` is a *lead*, not a fact. **Closing
>   an issue as already-fixed is a GOOD outcome** — say so in the PR and delete the ledger rows citing
>   it.
> - **A bug filed in three places is invisible in all three.** `fmt --write` destroying source, a
>   "scientific-notation float literal" *parser gap*, and a `1e12` must-fail row were **one defect** —
>   the lexer has no exponent form, so it cannot read the float the printer writes. No single doc owned
>   enough of it to see the shape. **One tracker, one item, one root cause.**

### ⚠️ Check the SET, not one member — a plural noun in a backlog item is a claim about a set

An item that says *"the four X's"*, *"the warnings"*, *"both backends"*, *"the whole tree"* is a claim
about a **set**. **Enumerate it and check every member, or narrow the claim to what you actually ran.**
Reporting N after verifying 1 is worse than not verifying: it *retires the question*.

It happened here, to this very doc set: *"W-errors has no remaining exception — **it is fully
frozen**"* was written after checking the non-exhaustive-**match** warning and generalizing. The
**guard** warning still fabricates a `0:0` location (#99). The edit turned a hedged doc into a
confidently false one, stamped `verified`.

Same disease as *"a one-backend fix is a half fix"* (#59) and *"a parity gate cannot see a bug where
both backends are equally wrong"*. **The unit of verification must be the unit of the claim.**

- **Reproduce a "known gap" on current main before you scope or spawn a fix.** A throwaway repro
  (`run` = oracle, `build` + run = native, compare) takes a minute and repeatedly saved an Opus agent
  from being aimed at an already-closed gap.
- **Expect symptoms to SHIFT as upstream layers close** — one bug went "panic" → "garbage output" →
  "SIGSEGV one layer deeper" across successive fixes. Re-scope on what the binary does *now*.
- **Bake DIAGNOSE-FIRST into every route-fragile prompt:** *"the filed root cause is a starting point,
  almost certainly stale; trace it on current main; STOP and report if the probe disproves it."* A
  clean STOP-with-a-correct-diagnosis is a **success**.
- **A landing often closes adjacent gaps** (universal ctor mangling alone closed three parked gaps and
  mooted a fourth) — re-verify the set after a merge, before spawning the next agent.
- **An arc's stated PAYOFF is a claim to verify against the bug's own fixture, not a fact to
  inherit.** A planned stage titled around use-site ambiguity diagnostics read as "closing this stage
  closes these S0s." It didn't: those diagnostics detect a **scope** collision (two provenances
  visible in one module's scope), while the filed bugs were **table** collisions (two modules' same-
  named interfaces in one program-global registry, never in one scope) — confirmed from the fixture,
  whose `main.mdk` never even imports the colliding name. **The stage lived in one pipeline phase; the
  bug lived in a registry populated later — the phase mismatch was the tell.** Before accepting that
  planned work drains a listed bug, open that bug's fixture and check the mechanism matches; don't
  take the arc's own framing of its payoff at face value.
- **"Fixed" can be TRUE and MISLEADING — a one-backend fix is a half fix.** A partially-applied-ctor
  miscompile was fixed in the LLVM emitter and never reached WasmGC. The verifier said FIXED
  (correctly!), so I reverted the library's workaround, re-verified under native `build` — all green —
  and was one command from merging a library that **silently no longer compiled to wasm**. Only the
  wasm tandem gate caught it. **Re-verify a fix on every target the code actually ships to.**
- **A spot-check is not a diff.** I "verified" overflow-page reads by sampling a patterned payload;
  every sample matched. The path was **silently corrupting data** — my 1000-char pattern blocks hid a
  4-byte shift. An agent's byte-level `cmp` caught it (diverged at byte 1817) and overturned a
  "verified fact" I had already told the user. **For data fidelity compare bytes, not samples** — and
  bake "disprove my premises" into prompts (it fired three times in one session, always against me).

Run this as a **verified audit before any milestone**: fan out read-only agents by domain that
REPRODUCE each claimed item (don't recite the doc). It catches both directions —
already-fixed-but-marked-open *and* marked-closed-but-actually-broken.

---

## The agent-prompt skeleton

### 🔴 Five lines that stop agents dying — put these in EVERY prompt (2026-07-13)

Each is a failure actually watched happen this session:

1. **"Do NOT spawn sub-agents / forks. Sequential, yourself."** An agent given a 40-file census
   **fanned out to sub-forks, then ended its turn waiting on one** — producing nothing. The harness
   re-invoked it and it said *"I'll wait for the batches"* **forever**. Nested forks also fail with a
   *misleading success signal* (`Fork is not available inside a forked worker`, while one still
   reports success and produces nothing). **Remedy: `TaskStop <agentId>` FIRST**, or it respawns.

   ⚠️ **CONFIRMED AT SCALE 2026-08-01, and it is worse than "some agents do this": ~10 of ~14 agents
   in one session stalled reporting they were "waiting for a notification"** while their backgrounded
   `make preflight` / `make medaka` was running perfectly. **Task notifications do not reach
   subagents reliably.** Three agents then formed a *delegation loop* — each reporting "I resumed the
   original agent, it is working in the background" — with nobody executing; it cost ~3 idle cycles
   before I killed the chain and re-dispatched one agent with an explicit *"YOU are the implementer,
   there is no other agent"* framing.

   **Two lines that fix it, in every prompt that runs a long build:**
   - *"Run it BACKGROUNDED and POLL for the PID to exit: `until ! kill -0 <pid> 2>/dev/null; do sleep 10; done`.
     Do NOT await a notification."*
   - *"You are the implementer. Do not delegate, do not spawn a sub-agent, do not 'resume' another agent."*

   ⚠️ **`pgrep -f <pattern>` SELF-MATCHES — say so, because agents adapt the idiom above into it.**
   Two agents in one session rewrote the PID-poll as `pgrep -f '<pattern>'` and each burned a full
   600s tool timeout, because the polling wrapper's own command line *contains* the pattern it is
   grepping for, so the loop can never terminate. Poll a real PID, or grep the output FILE — never
   the process table for a pattern you also typed.

   **Orchestrator-side remedy that actually unblocked them:** don't nudge blindly — `ps aux | grep -E
   'preflight|make medaka'`, wait on the PID yourself, READ the log, and hand the agent the *result*.
   Also verify a `timeout`-wrapped build **succeeded** rather than being killed at the limit; a
   timed-out build leaves a stale binary and every measurement after it is meaningless.

   ⚠️ **CONFIRMED AGAIN 2026-08-02, and a run that dies this way is DEAD, not slow.** Three agents on
   one PR failed identically: the entire final output was a waiting message ("Standing by for the
   build-completion notification"), each had applied its edits correctly and **committed nothing**.
   `make medaka` is ~1.5-3 min — inside the tool ceiling — but looks long enough to background, so the
   instruction has to be explicit past "don't wait on a Task notification": *"run in the foreground,
   do not yield waiting for a build, do not end your turn before `git push` succeeds."*

   **Salvage recipe (the work is almost always recoverable):** check `git ls-remote origin <branch>`
   FIRST (usually unchanged ⇒ nothing pushed); find the edits via `git -C <agent-worktree> status
   --porcelain`; **extract the diff to a patch file yourself** and hand the replacement agent the
   patch — never have the new agent read the dead agent's worktree directly, since cross-tree reads
   can trip the isolation classifier and cost that session too (see "A fresh isolated worktree..."
   under Failure modes below).
2. **"APPEND each result to disk as you finish it. Never buffer for a final write."** If it dies
   halfway you want half a census on disk, not zero.
3. **"NEVER end your turn with anything still running"** + **"Do NOT build."** A docs/audit agent has
   no reason to run `make medaka` or `build_oracles.sh` (the latter spawns an `xargs -P` pool that
   **outlives the turn and gets RESPAWNED**). Say: *"this is pure text analysis; it needs no
   compiler — keep it that way."*
4. **"GREP-PROVE every symbol and path you write. Paste the proof."** `test -e <path>`, and
   `sed -n '<line>p' <file> | grep <sym>` — at the **exact cited line**, not "exists somewhere." *If
   you cannot verify it, DELETE the claim rather than guess.* **This is the single highest-value line
   in any prompt** — it is what caught the Opus auditor fabricating symbols.
   ⚠️ **This applies to YOU relaying a citation, not just to an agent writing one.** Two `file:line`
   citations were passed from one report into the next brief unchecked, and both were wrong the same
   way — they named where the *argument about* the code was written (a comment) rather than where the
   code itself lives. Both were caught only because the *receiving* agent re-grepped. A relayed
   citation is a claim you are re-asserting; one `grep -n` for the definition before you paste it into
   a prompt is the whole cost.
   ⚠️ **A relayed SCOPE CHARACTERISATION is the same claim, one level up.** The orchestrator told an
   agent a just-merged PR was "comments only, so the merge should be textual and trivial" — true of
   the *follow-up commit* the orchestrator had verified byte-by-byte, not of the whole PR, which also
   exported a function and added a call. The agent read the merged hunks instead of trusting the
   brief and caught it. Tell agents to verify a base's diff scope themselves (`git diff --stat`)
   rather than inherit the orchestrator's summary — "comment-only," "additive," "mechanical" are
   claims, and re-deriving one costs a single command.
5. **"Disproving me is a SUCCESS."** Say it explicitly. It fired **three times in one session**, every
   time against the orchestrator. An honest `UNVERIFIED` beats a confident wrong answer.

### 🎯 A sixth, now that the backlog is issues: **"REPRODUCE THE ISSUE BEFORE YOU FIX IT."**

Hand the agent an **issue number**, not a paraphrase — the issue carries the repro, the evidence
stamp, and the source citations, so there is no game of telephone. Then put this in the prompt:

> *"Start by running the repro in issue #N against the current binary. If it does NOT reproduce, STOP
> and report that — closing an issue as already-fixed is a **success**, not a failed task. Six items on
> this backlog turned out to be already fixed."*

Without that line an agent will *implement a fix for a bug that no longer exists*, and — because it
cannot see the bug — will "fix" something else to make its change look justified. **The
`needs-repro` label exists precisely so you can tell an agent which issues are leads rather than
facts.** When it lands, have the agent flip the label to `verified` (with the SHA) or close it.

Every delegated task prompt should contain, in order:

1. **One-line project framing** + the task.
2. **STEP 0 — choose + VERIFY BASE:** fetch `origin/main`, then record one immutable
   `TASK_BASE=$(git rev-parse origin/main)` when the task starts from current main. An explicitly chosen
   last-known-green or stacked SHA is also valid; state why. Create the worktree at exactly
   `$TASK_BASE`, then require `git rev-parse HEAD` to equal it. (An agent once silently built Phase 5 on
   a base missing two prior phases; a redo was needed.) Every downstream diff/checkout uses
   `$TASK_BASE`, never `origin/main`/`main`: this box shares one `.git` across worktrees, so those refs
   advance under you the moment any sibling fetches, and a moving ref is not a fixed point (#519).
3. **Environment rules:** how to build (`make -C <worktree> medaka`), the no-`eval`/PATH quirks, the
   `perl -e 'alarm N; exec @ARGV'` timeout shim.
4. **Context (verified facts):** the root cause + `file:line` pointers you already confirmed, and the
   precedent to mirror. Hand the agent the map, not a treasure hunt — this is where your bounded
   scope-read pays off.
   ⚠️ **A *fix site* is a guess, not a verified fact — don't hand it over as if it were one.** Naming
   a fix site converts your guess into the agent's constraint. One brief said "extend `noteHead` to
   record the decl-layer carriers"; `noteHead` is a `Ty -> (Ty, Bool)` callback handed to
   `mapTyInDecl`, which rewrites **Ty positions** — it can never observe a decl-node field. That
   impossibility *was* the defect's mechanism: the layer was ungraded precisely because the only
   observation hook couldn't reach it. Brief the defect and the required observation; let the agent
   choose the site. When an agent reports "the named site can't do this," treat it as a root-cause
   finding, not a detour — it is exactly the kind of thing item 7's STOP guardrail exists to surface.
5. **The task**, with latitude where the approach is uncertain.
6. **Gates:** exact commands + expected numbers. Rebuild `./medaka`, and prefix any `test/bin/*` gate
   with `FORCE=1 bash test/build_oracles.sh` (see Failure modes: stale-binary footguns).
7. **STOP guardrail:** *"if the probe disproves the hypothesis / the fix balloons / a design decision
   appears, STOP and report with options — do NOT force the prescribed fix."* Scope hypotheses are
   often wrong; make stopping safe and cheap.
8. **Output discipline:** commit on its own branch, REPORT the SHA, do NOT merge to main, don't re-mint
   expensive artifacts, and **stage BY PATH — never `git add -A`**.
9. **Report-back contract:** *"your final message is the ONLY thing I see — be self-contained, WAIT for
   gates and report real numbers, never end with background tasks running."*
10. **A friction report** (below).

⚠️ **Inherited MCP tools answer with YOUR binary, not the agent's.** A subagent
inherits the orchestrator's `medaka` MCP tools (it starts no per-worktree
server), so `medaka_check`/`medaka_type_at`/`medaka_lint` run the orchestrator's
compiler, frozen at your server-launch — NOT the agent's edits. For any agent
touching `compiler/*.mdk` or `stdlib/core.mdk`, put this in its prompt: *"the
inherited `medaka_*` MCP tools run the orchestrator's compiler, not your edits —
verify any compiler-source change with your OWN freshly-built `./medaka`, never
inherited `medaka_check`/`medaka_type_at`."* Non-compiler agents can trust them
freely. (This is why you keep your own binary + server current: it's what the
whole fleet inherits — see `docs/ops/MCP.md`.)

---

## Every agent prompt MUST demand a FRICTION REPORT

> **Surface everything that fought you** — any bug, gap, missing feature, workaround you had to invent,
> misleading error message, stale/wrong doc, or surprising behavior — **even if you worked around it
> and even if it is unrelated to your task.** If you did something ugly to make progress, say what and
> why. If an error message sent you down the wrong path, quote it. A clean report that hides three
> workarounds is worse than a messy one that names them.
>
> **Explicitly include MISSING STDLIB FUNCTIONS.** Did you hand-roll a helper `stdlib/` didn't have,
> reach for something obvious by name and find it absent, or write the same three-line utility twice?
> **Name it** — what you wanted, what you wrote instead, and where.

**Why this is not optional.** Agents are extremely good at *routing around* problems and never
mentioning them, and everything they route around is a bug the user hits later with less context. This
session agents silently worked around: `medaka run` unable to read `args`; `import … as` not parsing
despite SYNTAX.md advertising it; `emitProgram` name-colliding across two backends; `/bin/sh` being
dash so a gate could not even be parsed. **Every one was a real, filed-worthy defect that surfaced
only because an agent happened to mention it in passing.**

**The orchestrator TRIAGES every friction item into exactly one of three outcomes — decide, don't
defer.** First **reproduce it** (the gap docs lie, and so do agents — a plausible root cause is a
*claim*, not a fact; grep-prove it at the source before acting), then pick:

1. **Immediate fix** — small, mechanical, and blocking or high-value: a stale glob, a one-line
   directive, a golden re-bless, a doc that's actively breaking agents. Do it now (yourself if trivial,
   or fold into the responsible agent). Don't file a ticket for a three-character fix.
2. **File a GitHub issue** — real but not for right now, or out of your lane, or needs a decision.
   Label it (`S*` severity + `ws:*` + `verified`/`needs-repro`), and if you only reproduced the
   *symptom*, file the symptom as verified and the agent's *mechanism* as a hypothesis (`needs-repro`) —
   don't launder an unverified root cause into a confident issue. Closing something as already-fixed is
   also a valid triage outcome; say so.
3. **No action** — a non-issue, already fixed, or working-as-intended. Say *why* in one line so it
   doesn't come back as a mystery; don't silently drop it.

**Do not let it evaporate.** A stdlib gap found by USE comes with a real call site attached — worth far
more than one found by planning. (Every friction item this session resolved to one of these three; the
trap is treating "I'll remember it" as a fourth option — you won't.)

---

## Review every agent PR before merging — a REQUIRED step in the merge flow, not an optional extra

**The merge flow is: adequate local signal → narrowed PR CI → independent reviewer → enqueue →
merge-group CI. Never skip review.** An agent's own report is a claim, not a review — and a green CI on
a bad diff is still a bad diff. On **every** agent-authored PR, spawn the configured read-only
**`compiler-reviewer`** agent over the diff (playbook: **`.claude/skills/pr-review/SKILL.md`**) once the material
state is locally verified; it may run concurrently with PR CI. Enqueue only after it returns APPROVE.
It reports; you decide; the *authoring* agent fixes (it has the context). **Gates provide evidence only
for paths that actually ran; the reviewer judges test adequacy, discrimination, regressions, and craft.**

- **Point the reviewer at the risk this specific change carries**, not a generic pass: byte-exactness
  for a data path, behavior-equivalence for a consolidation/migration (does the canonical match the
  clone it replaced — keep-first vs keep-last, trailing-newline handling, first-match?), the
  newly-accepted frontier for a feature. A generic "review this" finds less than a targeted one.
- **A change YOU verified hands-on** (e.g. an emitter fix you built + ran the fixpoint + diffed RNG
  byte-for-byte yourself) can count as the review — you did the reviewer's job directly. Say so. But
  don't self-certify an agent's diff you only *read*; spawn the reviewer.
- Run it after adequate local verification; it can overlap with PR CI. Rerun or resume it after any
  material CI repair. There is no excuse to enqueue unreviewed.

It has twice returned **do-not-merge** on a diff whose own gates were green, both times on this repo's
#1 bug class (check green / run dies) — e.g. import aliasing left an aliased *interface method* unbound
(`check` 0 diagnostics, `run` E-PANIC, `build` emitter failure), and the author's regression fixture
**tested the bug it fixed, not the feature it shipped**.

### The base rate, measured: 6 reviews, 6 real defects, all on 12/12-green PRs

On 2026-07-24/25 **every** adversarial review run against a fully-green PR came back
needs-work. Not a selected sample — all six that ran:

| PR | what green CI could not see |
|---|---|
| #1004 | an S1 + two S2s (a wildcard arm skipped domain validation for new syntax) |
| #1007 | a confirmed regression **worse than the bug it fixed** — impl heads attributed to the wrong interface |
| #1010 | a **9–15× allocation regression** on two check-path sites; both perf arms structurally blind to it |
| #1011 | an **S0** — a program-global key with no scope re-kinded every arity-matching application graph-wide |
| #1021 | a **language regression** — four shapes that compiled and ran correctly on `main` were rejected |
| #1058 | a **new S0 introduced by the fix**, which relocated the defect instead of eliminating it |

**So: on this repo, for a compiler-semantics change, a green CI carries close to zero
information about correctness.** That is not a slogan — it is the observed rate. It is also why
the middle step above is *required* rather than advisable, and why "it's green, and it's late"
is the worst possible moment to skip it.

Two corollaries that cost real time in the same session:

- **An author's own reviewer still counts as one pass, but only one.** Three of the six were
  caught by a *sibling's* reviewer, not the author's.
- **Merging on partial evidence is expensive precisely when the evidence is partial.** #1058
  merged on roughly one and a half of three stated conditions; the skipped probe, re-run
  afterwards, found **two S0s** — one of them live on `main`. Post-merge verification works, but
  it converts a caught defect into a shipped one.

### 🎯 Reviewing a spec's CLAIMS is not reviewing its RULES

A spec PR (#1093, merged) got a two-pass adversarial conformance review: ~40 `file:line` code
references verified, three blockers found and fixed, both doc gates re-run, and the load-bearing
implementability claim confirmed by direct probe. It still shipped a **new normative rule that
licensed an S0** (#1094). §9's "Index fidelity" bullet said effect-index types are interchangeable
*"only where the row order `≤` permits, exactly as any other type argument"* — that is covariant
widening, and a contravariant indexed type (`data Sink e = MkSink ((Unit -> <e> Unit) -> Int)`)
makes it unsound. The bullet even contradicted itself within four lines. Corrected in #1099 (the
doc) and #1102 (the type-checker fix, see #1094).

The review was scoped around *"are this document's claims about the implementation true?"* —
a good question, and it caught real defects. It never asked *"is the rule this document
introduces sound?"*

A spec makes two kinds of statement needing two kinds of review: **descriptive** claims about
what the implementation does (check by probe), and **normative** rules the implementation must
satisfy (check by *trying to break the rule* — find a program the rule permits that is
unsound). Add the second question to any spec/design-doc review; "does the prose match the
code" alone will pass a rule that is internally wrong.

**The tell:** a rule stated in terms of an existing relation inherits that relation's bugs.
`≤` is correct for *arrows* and unsound for an *index*; the borrowed rule silently borrowed the
mismatch. A self-contradiction inside one bullet is a smell for exactly this — it usually means
the author knew the right answer in one clause and imported a wrong analogy in another.

### ⚠️ A verification probe must be ABLE to fail

An S0 fix once routed through a guard that desugars to `__fallthrough__` — a construct
`AGENTS.md`'s Traps section documents as a former run≠build miscompile source. The PR cited as
verification: *"the benign fixture gives `run` == `build` == 0."*

That comparison is structurally incapable of detecting a broken fallthrough: **`medaka run` and
`medaka build` typecheck with the SAME binary** (see `AGENTS.md`'s debugging section) — only the
execution engine differs, so the guard had already run identically in both arms before either
engine started. Both probes also only ever exercised the guard's *true* branch — never the
branch whose breakage was being ruled out.

The reviewer accepted the conclusion, rejected the reasoning, and supplied a real discriminator:
a case where a dead fallthrough would **flip the verdict** (two distinct open tails must fall
through to the delegation; if it were dead the tails would never link and the unsound program
would be accepted — it is rejected, so the fallthrough is live).

This is distinct from *"an audit is not evidence"* above (that is about trusting a claim
un-reproduced) and from *"a regression probe must succeed pre-fix"* (that is about a probe never
exercised against the broken state) — here both probes ran, and ran clean, and still proved
nothing, because **the two arms were never able to disagree in the first place.** A can't-fail
probe reads in a PR body exactly like a real one — same shape, same confident sentence, same
green result. General rule: **for every "I verified Z," name the observation that would have
shown ¬Z; if none exists, say "not established" instead.** Generalizable trap: **two
"independent" checks that share a pipeline stage give you ONE observation, not two.**

### ⚠️ Split a PRE-EXISTING defect out of the PR that merely REPLICATES it

A review of #1244 found that `resolve.mdk`'s `typeOriginExports` and `tyOriginScope` disagree
on re-export precedence: a module that both declares and re-exports the same name attributes it
to the re-exported source instead of the declarer. The mechanism was **pre-existing** — the
identical probe reproduces on the `data`/type side, which #1244 never touched — and the PR only
replicated it into a second namespace (interfaces).

Fixing it inside #1244 would have moved goldens well beyond the PR's own layer (its own filed
issue, #1245, says so: *"this fixes the type side too... expect golden movement beyond the
interface layer"*), so a red result would not have named its culprit. The split: the PR narrows
its now-overreaching claims and pins the wrong answer as a fixture; a separate issue owns the
ordering fix; and the fix is recorded as a **precondition on the downstream unit that will
first consume the value** rather than blocking the PR that merely inherited it. Keep the two
apart, and say in the issue why they were kept apart.

---

## ⚠️ A clean auto-merge is NOT agreement

**A clean `git merge` proves only that two changes did not touch the same LINES. It says nothing about
whether they agree.** Two agents changed the LLVM emitter in parallel; git flagged 2 conflicts and
cleanly auto-merged a **third break it could not see** — TMC had added a brand-new caller
(`emitGDispBody`'s `CDecision` arm) into the very machinery whose signature the other change was
rewriting (single scrutinee word → `roots : List String`). No conflict; the merged tree **crashed**. A
reviewer caught it, not git and not either author.

When two branches touch one subsystem:

1. **Do NOT resolve a semantic conflict yourself.** Hand it to the authoring agent — it knows what the
   code must *mean*; you know only what the lines look like. A wrong resolution in an emitter is a
   **silent miscompile**, not a build error.
2. **Grep the merged tree for every CALLER of any signature that changed** — not just the ones that
   conflicted. That is where the invisible break lives.
3. **Re-run the decisive gates ON THE MERGED TREE.** Pre-merge greens do not carry over. Cheapest
   first: `typecheck_compiler_source.sh` (catches a left-behind caller in ~5s — and **`make medaka`
   does NOT gate on type errors**, so nothing else will), then the fixpoint, then the differentials.

---

## Verifying a landing — never trust prose

"Done, all gates green" is a claim, not evidence. Verify, bounded to the decisive checks.

- **For a feature that EXPANDS the set of accepted programs, the decisive check is probing the
  newly-accepted FRONTIER yourself — not the agent's fixtures**, which cluster on the happy path.
  Num-polymorphic literals shipped four stages "all gates green," yet nobody tested a *user*
  polymorphic-literal fn applied to Float (`inc x = x + 1; inc 2.5`): it typechecked but **panicked at
  runtime** (a soundness hole) and separately built to **silent garbage** (an emitter gap the feature
  newly exposed). Both found in a 60-second hand-probe *after* the agents reported green. Ask: "what
  does this newly accept, and does it RUN *and* BUILD correctly across every instantiation (Int *and*
  Float)?" A clean fixpoint + green differentials do NOT cover behavior the corpus never had.
- `git log $TASK_BASE..<branch>` + `git diff --stat $TASK_BASE...<branch>` — the commits exist and the surface
  matches the report. **Use the pinned `$TASK_BASE` from STEP 0, never `main`/`origin/main`**: every worktree
  on this box shares one `.git`, so those refs move under a sibling's `git fetch` mid-task and a moving
  ref is not a fixed point to diff against (#519).
- **Pick the decisive check per change type.** Self-hosted emitter → the **fixpoint** (C3a/C3b): it
  recompiles the whole compiler and proves byte-for-byte self-reproduction. A code *transform* (TRMC) →
  an **IR-shape assertion** that it actually fired (grep the emitted body for *no* `call @mdk_<self>`):
  the differentials compare program OUTPUT, so a pure transform is invisible to them while a mis-route
  shows as wrong output. One decisive check beats re-running everything.
- **`FORCE=1 bash test/build_oracles.sh` before you re-run any `test/bin/*` gate yourself** — your own
  re-verify can read a stale oracle too (this masked a real prop regression as "9/0 unchanged" until a
  forced rebuild showed 5/4).
- `ps` for **orphan processes**, and treat an agent that ended with "waiting on the monitor…" as
  **unverified** — gate its commit yourself.
- Only after green: **push and open a PR** — the queue lands it; you cannot push `main`. If you combine
  branches locally first, do it on a topic branch and confirm it actually advanced (`git rev-parse
  <branch>` == the new tip): a "Fast-forward" printed on a *detached HEAD* is indistinguishable from one
  on the branch, and that silently stranded two phases (see Failure modes). Then reconcile
  docs/tasks/memory.

---

## Hand-offs that don't rot — make the bug list EXECUTABLE

"The gap docs lie" is the diagnosis; this is the remedy, and it should be the default whenever you hand
a list of defects to anyone. **Do not hand over prose. Hand over a script.**

- **Encode every verified repro in a status script** (`verify_<topic>.sh`) that re-runs each against the
  current binary and prints **OPEN / FIXED** per item. Status report, **not a gate** — always exit 0, so
  nobody wires it into CI and starts ignoring it. Banner the companion doc **"⚠️ DO NOT TRUST THIS LIST
  — RUN THE SCRIPT."** (While my branch was in flight another orchestrator fixed one of my P0s; the
  script detected it with **zero bookkeeping from either of us**. A static list would have been wrong
  within hours.)
- **Tag every workaround with a greppable marker** — `WORKAROUND(B2): … revert when B2 closes` — and
  have the script print the marker sites beneath its report. Then the command that says a bug is fixed
  also says which lines to delete; otherwise workarounds quietly become permanent architecture. (We
  carried 7 workarounds for 4 bugs.)
- **Separate what YOU reproduced from what an agent claimed** (✅ VERIFIED / 🟡 REPORTED). Agent
  root-causes were wrong often enough that a confident-but-wrong entry poisons the next person's search.
- **Distinguish the diagnosis from the inference.** An agent reported "we need `runST`". The
  *observation* (two authors hit the same wall, with measured cost) was gold; the *conclusion* was
  premature — the real defect was upstream, in what the effect actually meant. **Log what hurt, not what
  you'd build.**

---

## Choosing the model

> ⚠️ **SUPERSEDED for sprint work (2026-08-16, Claude 5 family):** the sprint roster's model
> assignments live in the `.claude/agents/*.md` frontmatter and the `sprint-orchestrator` skill's
> roster table — Sonnet 5 orchestrator seat, Opus 5 brain/breaker/planner, Sonnet 5 implementer
> default with packet-classified Opus 5 override, Haiku 4.5 verifier/scout, Fable 5 one-question
> consults only. The rows below predate the Claude 5 family; they remain useful as the task
> TAXONOMY (what is mechanical vs judgment work) but not as model names.

- **Sonnet** — surgical, scoped, additive, read-only, or mechanical-with-a-template work (wiring, one
  additive dispatch arm, audits).
- **Opus** — heavy/risky: real codegen, central-dispatch refactors, uncertain blast radius, or where
  debugging depth matters. Default for the hottest/most-load-bearing files.
- Escalate mid-pattern: a "simple" first step may be Sonnet; the general fix it ladders into is Opus.

### A mechanic edits; it does not discover

Use a mechanic only after a scout/designer has supplied a bounded edit packet: exact files and symbols,
the invariant to preserve, known caller/mirror set, and the one or two commands that grade the slice.
Its first substantive action should be an edit, not a fresh architecture census. Do not hand it a whole
hot-file refactor and ask it to rediscover ownership, call chains, and tests; that is design work and
will consume its bounded turn without producing a commit. Mechanics are prohibited for S0/S1 bugs,
typechecker or backend work, semantic decisions, architecture, and golden adjudication; a prompt calling
one of those tasks "mechanical" does not change the routing.

If a mechanic returns without an edit, the conductor must immediately narrow the work to a closed
ownership family, take over the mechanical change, or return to design. Retrying the same broad prompt
or merely increasing a tool budget repeats the routing failure.

---

## Do not commission a RED-BY-DESIGN gate. Commission a GREEN gate with a ledger. (2026-08-14)

Building an instrument for a defect that is **not yet fixed**, the obvious brief is *"it must land
RED — a green here is a failed bite."* I wrote exactly that. **The implementer landed it green with
a ledger and overturned me, correctly**, citing a header this tree already had:

> *"The gate is GREEN with rows present because a gate that lands red breaks `main` and teaches
> people to ignore it. **The rows are what keep the green honest.**"*
> — `test/IMPORT-ORDER-LEDGER.txt`

**The red mandate was worse on my own stated requirement.** I had asked the instrument to
discriminate four states (unfixed / shallow-fix / upstream-fix / deep-fix). A red-by-design gate
must be excluded from CI or it reds the tree for everyone — so it never runs and rots — and it
carries **one bit**, which cannot tell four states apart. The brief contradicted itself.

A ledger row instead pins **every distinct signature** the case produces, and reds in three
directions: **DRAINED**, **MOVED** (the partial fix — the case one bit cannot see), and a new
unledgered divergence. Reserve red-on-landing for `test/must_fail_fixtures/`, whose contract
already is *"assert this still reproduces, go red when it drains."*

Two follow-ons worth carrying:
- **Make the discriminator multi-channel** (exit code + sorted diagnostic codes + each verb's
  stdout), never a single verdict. A same/different reading collapses the states you care about —
  and distinguish a *resolve*-stage rejection from a *type*-stage one, or a deep fix reports as
  the upstream fix.
- **Prove the instrument can fail before trusting its green**, and separately prove the permuter
  actually rewrote the file: *"found nothing"* and *"moved nothing"* produce identical readings.

🎯 **The meta-lesson is about the brief, not the gate.** Mine described the prior art as *"five
cells, no wasm arm"* — accurate, and it omitted that the file is a fully-developed ledger harness
whose header argues against the design I was mandating. **Reading the file instead of my summary
reversed the bite's central decision.** DERIVE-don't-encode applies to the orchestrator's own
summary layer, which is exactly where nobody checks it.

## Parallelism & file hygiene

### 🚨 TELL EVERY AGENT TO WORK IN ITS OWN WORKTREE — SAY IT EXPLICITLY

⚠️ **But do NOT tell a second writer to "check out the existing PR branch."** One branch can be
checked out in only one worktree, and the first agent's worktree still holds it — `git checkout`
hard-fails, *after* the new agent has spent ~2-3 min cold-bootstrapping. Three writers hit this in
one session. Give them the working pattern instead: `git switch -c <local> origin/<branch>`, then
`git push origin HEAD:<branch>`. Have them confirm the real ref with `gh pr view <N> --json
headRefName` rather than trusting a branch name you relayed — I got one wrong.
(Also: an isolated session must run `git -C <its-own-worktree> worktree add`, not a bare
`git worktree add` from the shared checkout, which is refused.)

**Two agents in one session independently ended up building in the ORCHESTRATOR'S worktree.** The
harness injects the *orchestrator's* `CLAUDE.md`/`AGENTS.md` path into the agent's context, so an agent
that trusts that header `cd`s into **your** tree. One ran `make medaka` there concurrently with your own
build, writing the same `./medaka`/`./medaka_emitter`; it "succeeded" with exit 0 and was worthless.
Another's `git diff > patch` swept up a sibling's unstaged golden. Worst near-miss: an agent had
uncommitted **emitter** edits in the orchestrator's tree while the orchestrator ran `refresh_seed.sh` —
which could have baked an unreviewed emitter change into the seed, **the trust anchor**, and pushed it.
(Verified clean afterwards: a fixpoint from a *pristine* `origin/main` checkout gave C3a YES + C3b YES —
that drift detector is exactly what proves the seed was not contaminated. Do this if you suspect a leak.)

> Work ONLY in your own worktree. Do NOT `cd` into `/root/medaka` or any
> `.claude/worktrees/<other>` directory, and do NOT build there — the CLAUDE.md path in your
> context may point at someone else's tree; ignore it and use your own cwd.

For a task beginning from current main, query and fetch the remote tip before creating its worktree; pin
the task to that fetched commit, not to `/root/medaka`'s possibly stale checked-out `main`. A deliberately
stacked or last-known-green task instead uses its explicitly recorded parent SHA. Shared worktrees can lag
GitHub while other sessions advance refs, so a local `HEAD` alone is not a current-base proof.

On your side: **never run `refresh_seed.sh`, `make medaka`, or `git add -A` in a tree you have not just
confirmed clean** (`git status --short`). A shared worktree makes "capture my diff" unsound.

- **Cap concurrent write agents at 3 — a hard ceiling, not a target.** Each runs a heavy `make medaka`,
  and this box is shared with other sessions. Want a 4th? **Queue it**; spawn when a slot frees. Do NOT
  instead cap `JOBS` to fit more agents — that's the wrong lever (it makes each build *slower*, +54%,
  and starves everyone longer). Read-only agents (audits, scoping, reviewers) don't count against the 3
  — they don't build.
- **Check box load BEFORE spawning a build-heavy agent.** Run `uptime`; if the 1-min load average is
  already high (say >6–8 on this 12-core box) or ≥3 heavy builds are live, **queue, don't spawn** — a
  full local suite + oracle build pushes load past 10 and turns everyone's 30-second gate into minutes.
  This is a real cost to other agents on the box, not an aesthetic preference.
- Parallelize only **non-overlapping files**. Never two agents on one file; never pile agents onto the
  single hottest file. Sequential when they share a file.
- **The MERGE is where integration bugs live.** Two agents on genuinely disjoint files both reported
  green and git merged them with **zero conflicts** — and the merged tree had defects neither could see:
  git auto-merged A's `deriving (Eq)` on top of B's *deliberately hand-written* `impl Eq` (overlapping
  impls), and A's exhaustive `match` predated the new ADT constructor B added (latent panic). **"No
  conflict" means textually compatible, not semantically compatible.**
- **Read-only audits parallelize freely** — zero merge risk; good use of idle time while a write agent
  runs. For a broad review, **fan out by domain** (typecheck / emitter / parser / error-path); one
  consolidated agent is shallower.
- **Doc-edit hygiene under concurrency:** if an agent is concurrently *appending* to a shared doc (most
  append an "AS-BUILT" section at EOF), make your own edit a **mid-file insert** in a stable region — the
  3-way merge then auto-resolves instead of conflicting at EOF.
- 🚨 **Shared APPEND-TARGET REGISTRIES are a collision surface beyond source files and goldens.**
  Seven PRs ran across disjoint source files, serialized on source files and on the documented
  snapshot/LEG A goldens — and that was not enough: **#1436 was ejected from the merge queue**
  (`mergeable: CONFLICTING`) after **#1442** landed ahead of it. Neither PR's "owned" files
  conflicted; the collisions were all in files where two PRs each *add a row/line to a shared
  list*: `.github/workflows/ci.yml`'s `tools` shard `pattern:` — both PRs appended their new
  gate's name to the **same line** (confirmed: `gh pr diff 1436` and `gh pr diff 1442` both
  touch that identical `pattern:` string); `test/preflight.sh`'s change→gate selection map; and
  `test/MUST-FAIL-NOT-PINNABLE.txt`, where #1436 deleted the `#1348` row and **#1435** deleted
  the adjacent `#1360` row two lines above it. Treat any single-line list a gate reads as a
  registry — `ci.yml` shard patterns, `test/preflight.sh`'s map, `test/MUST-FAIL-NOT-PINNABLE.txt`,
  `test/CAPABILITY-EXCEPTIONS.txt`, `test/engine_divergence.txt` — and add it to the pre-dispatch
  serialization check alongside source files and goldens.
  - **Resolving one: take BOTH sides, then re-run the gate that validates the registry** —
    `sh test/diff_compiler_ci_shard_coverage.sh` for `ci.yml` (it fails a gate matching no shard
    pattern, i.e. a pattern one side's `--ours`/`--theirs` resolve would silently drop — see its
    own header, "A gate matching no shard pattern silently never runs"). Never `--ours`/`--theirs`
    on a registry: that doesn't fail loudly, it just **stops the other PR's gate from ever
    running again while every check stays green.**
  - **An enqueue that succeeded is not a merge.** `scripts/pr.sh enqueue` correctly verified queue
    membership at the time; the PR was ejected later when another PR landed ahead of it in the
    queue. A queued PR's state must be **read back** before you treat it as landed — never
    inferred from an earlier successful enqueue.

---

## Dogfooding as a bug-finding strategy

Building a real library in the language is the highest-yield bug finder we have — **but only if you
choose the work deliberately.**

- **Pick work that stresses NEW language surface, not more of the same shape.** Six SQL query features
  found **zero** compiler bugs — not luck: all the same shape (add an ADT node, an evaluator arm, an
  oracle). The moment the work had a *different* shape — a parser on a user-defined monad, byte-chain
  manipulation, a cross-project dependency — bugs fell out immediately. **Ask: "what part of the language
  does this exercise that nothing else has?"** If the answer is "nothing," it will find nothing.
- **Know which execution path your tests cover.** Every doctest runs under the **interpreter**, so a
  compiled-only bug is invisible to the entire suite: the SQL parser shipped **32/32 green doctests**
  while *every arithmetic operator in its grammar* was silently miscompiled natively. **Tell agents an
  interpreter-green result proves nothing, and require gates to run against a real `build`.**
- **Feed the system real input, not hand-built structures.** Every prior oracle built its query as an ADT
  by hand; none ever put a `NOT` over a nullable column. The first time we fed actual SQL *text* through
  the same engine it exposed a wrong-answer bug (3-valued logic collapsed to 2-valued) that had been
  sitting there the whole time.

---

## Principles

- **Close gaps principled, not piecemeal — but ladder up.** Prefer the general fix over a half-measure;
  surface the choice. Incremental is fine **iff** each bounded rung reusably composes into the general fix
  (or is a strict subset), not a throwaway it discards. Keep a proven fallback if it might balloon.
- **Bounded orchestrator research** — frame, don't exhaustively map.
- **Surface design decisions**; give recommendations, not surveys; act on sensible defaults rather than
  over-asking.
- **Defer expensive regenerations** (the seed) to real checkpoints, not after every sub-task.
- **For a large task delegated in pieces, grant "incremental-landing" permission and ask for the next
  gap.** Land a coherent gated chunk, stub the rest with a recognizable marker, REPORT the precise
  residual. The honest STOP with a precise punch-list (ideally + a pointer to where the fix already
  exists) is the deliverable, not a failure.

---

## Big architectural changes — the design→staged→seams playbook

For a large, route-fragile change (this session: TRMC), don't hand one agent the whole thing.

1. **Design-pass first** — a read-only Plan agent that confirms the problem *empirically*, recommends the
   mechanism, maps the touchpoints, and returns a decision-ready design with an explicit **"design forks
   (need a human decision)"** section. Persist it as a `*-DESIGN.md`: the implementation agents share one
   spec, and it is the future record. Two rules learned the hard way:
   - **Ask "does an existing spec already answer this?" FIRST, before reasoning from principles.** I was
     about to write a design doc from scratch; the reviewer found the question *was* already answered in
     a spec I hadn't read — and that **the implementation contradicted the spec**, which reframed the
     whole problem. One `grep` would have saved an hour of theorising.
   - **Hand the reviewer your hypothesis and tell it to BREAK it** — an independent model beats a second
     opinion that agrees. My soundness argument was demolished three ways and I reproduced all three
     counterexamples on the binary. **Ship the design with the rejected alternative and the
     counterexamples that kill it** — it is the proposal the next person will reach for, and it looks
     right until you try to break it.
2. **Surface the forks to the user**, lock scope, and write the locked scope into the design doc.
3. **Staged implementation agents** — one per sub-part, ascending risk, each **independently gated +
   merged** before the next branches (same file ⇒ sequential). Verify each landing's decisive check.
4. **Keep deferred-scope seams parameterized** so the deferred part is an *additive* later patch, not a
   rewrite (computed offsets, no "zero leading params" assumptions). Then **scope the deferred extension
   explicitly** (a read-only scoping agent) even while deferring it: it captures the seam knowledge,
   verifies whether a real target even exists (often none → defer is the principled call), and corrects
   the implementers' over-optimistic seam notes.

Re-mint the seed once at the **completed-change checkpoint**, not per sub-part. A *comment-only* edit to
an emitter-graph file does NOT invalidate the seed (emitted IR is identical); any logic change does.

---

## Your ROUTING comment is the frame later work is scoped against (2026-08-09)

`[[feedback_the_orchestrators_prose_is_the_unreviewed_artifact]]` covers PR bodies. **A routing comment
is worse**, and this session produced two instances in one day — both overturned by measurement within
hours, both already acted on by the time they were.

- **"The #1326/#1369 'indivisible' adjudication was wrong."** I argued the two needed different code
  changes in one function pair, so sharing a function ≠ sharing a mechanism. A two-arm differential
  showed they are coupled **through the table**: the re-export arm propagates exactly the rows the
  provenance filter removes, and each half alone is measured-unsafe in opposite directions. **The
  evidence was already in a source comment on the branch** (*"would propagate a poisoned row one hop
  further. Land them together"*) and I reasoned past it.
- **"#1383 IS the `universeFieldOwners` row."** Built on *"`headL owners` takes the first of a
  graph-global list, which explains the import-order dependence."* But `fieldOwnerNames` `sortUniqS`es
  (`typecheck.mdk`, and two further comments say so) — that read is **order-insensitive**. A design pass
  then measured the owner set to be a **singleton holding the right key** in both faces.

**Why routing is the dangerous kind.** A PR body describes work already done. A routing comment tells
the next agent *where the defect lives and what shape the fix has* — so a wrong one converts directly
into tracker structure and dispatched work. My #1383 routing caused an analysis-design gate to be added
to that issue **aimed at the wrong half**.

**Rules:**

1. **Before routing a defect to a mechanism, grep the mechanism.** "X takes the first element, therefore
   order matters" requires checking the list is unsorted. An explanation that *fits* the observed
   behaviour is not evidence it *causes* it.
2. **When retracting someone else's verdict, ask whether you are replacing their bad ARGUMENT with your
   bad VERDICT.** A right conclusion reached badly is still right; overturning it needs evidence about
   the conclusion. The original #1326/#1369 adjudication was right via a wrong argument — my
   "correction" was strictly worse, because a verdict is what the next agent acts on.
3. **Post retractions as new comments, never silent edits** — the earlier comment reads as the frame, so
   the correction must sit where the frame is, and must name what was already acted on so the downstream
   artifact gets re-aimed too.
4. **Hedge a relayed lead, and demand it be tested by INTERVENTION.** One lead I relayed
   (`argDispatchIdxRef`'s two write sites) was confirmed as a *fact* and refuted as the *cause* — the
   reader's value is discarded, so patching it is not a no-op, it is simply unused. That refutation only
   happened because the brief said *"check it actually accounts for the symptom rather than merely being
   adjacent."* Put that sentence in.

## Small operational facts that cost time this session (2026-08-09)

- **An agent that ESCALATES a decision and then completes will re-surface it every time something wakes
  it.** It has no way to learn its escalation was answered. Two agents re-reported stale "the open
  decision, unchanged" summaries three times between them. **`TaskStop` the agent once you have acted on
  its escalation** — the report is already in your context and on the PR.
- **Brief a PRIVATE scratch subdirectory.** Two agents collided writing the same `build.log` path under
  the shared session scratch dir.
- **`gh issue edit` / `gh pr edit` currently FAIL on this repo** with a Projects-classic GraphQL
  deprecation error. Use `gh api -X PATCH repos/<owner>/<repo>/issues/<N>` (or `.../pulls/<N>`), and
  read the state back — `gh` writes can silently no-op.
- **A wrap-up cannot reap worktrees from an isolated session.** The harness refuses git operations
  targeting another worktree, so `git worktree list` is derivable but every removal signal and the
  removal itself are not. That is *report-and-hold*, not a skipped step — post the derived list and let
  each owner reap.
- **A queue bounce is not automatically your break, and not automatically a flake either.** #1439 (a
  test-only fixture PR, 12/12 green) was dequeued by `gates (sqlite)`. The discriminator — gathered
  **before** re-enqueueing — was that the same gate passed on the **same base** in two other runs, and
  that the PR's diff could not reach it. Re-enqueued and it merged unchanged. Blind-retrying a
  deterministic red burned a round-trip on #1005; gathering the same-base evidence first is what
  separates the two cases.

---

## Failure modes seen

- **Agent commits on its OWN-named branch, not the `worktree-agent-<id>` branch.** Merging the
  worktree-id branch is then a silent no-op (a gate read 52/52 instead of 68/68). **Merge by the reported
  SHA**; confirm with `git branch --contains <sha>`.
- **A self-reported `BASE_OK` can be FALSE.** One agent reported `BASE_OK` while rooted at the
  *session-start* commit, missing every overnight landing. The catch was the orchestrator's own **`git
  diff --stat <main> <branch>`**: ~1400 spurious deletions and a recent fixture listed as *deleted*.
  **Always diff-stat the branch against current main before merging** — a surface that doesn't match the
  agent's "small additive change" report means a stale base. ⚠️ A shifted `origin/main` is ALSO a cause
  of a spurious surface, not only a stale agent base — this box shares one `.git`, so `origin/main`
  advances under a running diff the instant any sibling agent fetches. **The fix is the same either
   way: diff against the pinned `$TASK_BASE` from STEP 0, never a moving ref** (#519, and see HARNESS.md).
- **Stale-binary footguns.** (1) `make medaka`'s `find -newer` short-circuit can leave `./medaka` NOT
  carrying a lexer/compiler-graph change → `FORCE_EMITTER_REBUILD=1 make medaka` to verify one. (2) The
  `test/bin/*` oracles: `test/build_oracles.sh` **mtime-skips rebuilds**, so after a
  `typecheck.mdk`/`eval.mdk` change a gate silently runs OLD source. **RULE: run `FORCE=1 bash
  test/build_oracles.sh` before trusting ANY `test/bin/*` gate.** This bit three times in one session
  (two agents reached opposite conclusions; a real prop regression read as "unchanged"). A green/red on a
  stale binary means nothing.
- **The empty-report + RESPAWNING-oracle-pool mode** (recurred on MANY agents, Sonnet AND Opus). An agent
  ends its turn with a stray line ("Background scan in progress…") instead of a report, having launched a
  bare `build_oracles.sh` (an `xargs -P` pool) that didn't finish inside the turn — so every harness
  re-invoke RESTARTS the pool. Reaping alone doesn't work; it respawns, and the `TaskStop` + salvage loop
  is routine. **Remedy, in order: (1) `TaskStop <agentId>` FIRST to stop the respawn; (2) reap ONLY that
  agent's own PIDs (`ps -eo pid,args | grep "agent-<id>" | grep -v grep | awk '{print $1}' | xargs -r
  kill`) — NEVER a box-wide `pkill -f build_oracles.sh` / `pkill -f 'xargs -P'`, which kills other
  sessions' builds (the sandbox blocks it, correctly); (3) salvage or discard.** Salvage IF the WIP in its
  worktree is COMPLETE (`git -C <wt> status` + a grep for the target end-state): gate it yourself and
  commit on its branch; DISCARD + re-spawn if it is a partial hack. **Bake into every prompt: NEVER run
  bare `build_oracles.sh`; build one oracle with `FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one
  <name>`.**
- **Three shapes of report you must NOT act on:** ≈0 tool uses + a boilerplate/empty result (a *failed*
  run, not a completed one — re-spawn, sometimes as a different agent type); a stray monitor/tool echo
  returned as the "result"; and "all gates green" computed against STALE oracles or a stale `./medaka`.
  All three are unverified: inspect the branch from git and re-run the decisive gate with FORCE-rebuilt
  oracles + a fresh `make medaka`.
- **Salvaging a session-limit-killed agent.** It can die having committed NOTHING while its WIP is live in
  its worktree (`git -C <worktree> status`). Preserve it (commit on its branch), then verify INDEPENDENTLY
  from scratch — it left no report.
- **Stranded commits from a detached HEAD.** `git checkout <sha>` in a worktree DETACHES HEAD; a later
  `git merge --ff-only <branch>` then advances the *detached HEAD*, not the branch — the work lands on a
  dangling line. This stranded two verified phases (recovered via `git reflog <branch>`). **Never `git
  checkout <sha>` in a worktree** — to drop commits use `git reset --hard <sha>` ON the branch; to inspect
  an old commit use a throwaway `git worktree add`. After any checkout assert `git rev-parse
  --abbrev-ref HEAD` is a branch name, not `HEAD`.
- **Non-isolated background agents SHARE your worktree's filesystem + git HEAD.** An Agent spawned WITHOUT
  `isolation: worktree` runs in your working dir: it `git checkout -b`s there (leaving YOUR worktree on
  its branch) and its builds write the same `./medaka` artifacts as yours. So: **never run two
  build-heavy things at once**, and a clean `git status` doesn't prove an agent isn't mid-edit (it may
  just not have written yet). For parallel write-agents, pass `isolation: worktree`.
- **An agent can commit stray build-artifact binaries via `git add -A`** (once: 5 root-level demo
  binaries, ~250 KB each, alongside the real change). Caught by the pre-merge `git diff --stat` surface
  check. Fix: rebuild a CLEAN commit off main with only the intended files (`git checkout -B clean main`,
  then `git checkout <agent-sha> -- <good files>`) — do NOT merge the polluted commit. **Bake "stage BY
  PATH, never `git add -A`" into every prompt.**
- **A fresh isolated worktree has NO `./medaka_emitter` — and that is FINE: plain `make medaka`
  cold-bootstraps there, and a lagging seed does NOT break it** (a drifted seed only WARNS — `C3a WARN …
  lagging seed`). This is the thing agents most often misreport as "I broke the seed." ⚠️ Until
  2026-07-13 the advice to `cp` another worktree's emitter in first was **actively unsafe**: the build
  tested "is this emitter current?" by **mtime**, and `cp` stamps the copy with the *current* time — so
  the staler the emitter's origin, the FRESHER its copy time, the rebuild was skipped, and the ancient
  binary died on syntax it predated. A **provenance stamp** (`.medaka_emitter.srcstamp`, hashed from the
  compiler sources, never travels with a `cp`) fixed it; the `cp` is now a safe ~4 s speedup.
  **⚠️ But do NOT put that `cp` in a SUBAGENT's prompt, and tell isolated agents not to reach for
  it.** Safe-for-you ≠ safe-for-them: the `cp` *reads* another tree, which trips the auto-mode
  isolation classifier, and **the denial is stateful** — it carries forward and blocks every later
  `make` the agent attempts, *including a clean cold-bootstrap wholly inside its own worktree*. An
  Opus agent lost a full session to this on 2026-07-16 and could not build at all; its read-only
  diagnosis survived only because reads were unaffected. ⚠️ **It is not deterministic** — a second
  subagent in that same session did the identical `cp` and was never blocked, so you cannot predict
  it or test for it; you can only avoid it. `AGENTS.md` recommends the `cp` in the
  build section, so agents find it on their own — **pre-empt it explicitly in the prompt** ("do NOT
  cp an emitter from any other tree; plain `make -C <your-worktree> medaka` cold-bootstraps and is
  correct"). Cost of not borrowing: ~31 s, the seed-bootstrap step only — `cp` skips the
  `.medaka_emitter.srcstamp` provenance stamp, so stages A+B rebuild anyway (AGENTS.md
  [B-BORROW-EMITTER]; the ~4 s figure here was the pre-2026-07-16 understatement). Cost of
  borrowing: the agent.
- **⚠️ `cp` is NOT the only trigger — ordinary compound Bash trips the same denial** (#1148,
  OPEN, S2; ~32 occurrences across 5 sprints), with no cross-tree read anywhere: `cd X && …`,
  `;`-chains, heredocs, `for` loops, `python3 - <<EOF`, a pipe feeding `git` its args, a redirect
  combined with `-C`. **Put the remedy in every isolated agent's prompt:** one plain command per
  Bash call, multi-step work into a script file first, the mandatory build redirect
  ([D-BUILD-PIPE]) *inside* that script. ⚠️ **That is mitigation, not immunity** — see the
  `sh test/build_native_medaka.sh` bullet below, which is the build half of the same defect
  and the only workaround that has never been denied. And name the exit: an agent whose build
  is denied every way inside its OWN worktree reports BLOCKED — a no-build agent that keeps
  going produces existence claims it cannot support. The denial carries forward in some
  sessions and not others; do not model it as reliably stateful or reliably transient.
- **A construct-removal census MUST scan the always-loaded prelude (`stdlib/core.mdk`) for REAL uses** (not
  just doc-comment/string matches). A missed prelude use makes the *compiled* binary fail to load the
  prelude → it errors on EVERY program, mimicking a codegen/DCE miscompile (an Opus agent spent a 12-build
  bisection before another proved the emitted IR was byte-identical live-vs-dead). Grep the prelude first;
  there is no DCE miscompile.
- **⚠️ A GATE THAT CAN SILENTLY NO-OP WILL. "Green" is not "ran".** Three instances in one session: every
  wasm gate shelled out to `wasm-tools`, which **was not installed** — each printed `skipping` and
  **exited 0**, so the WasmGC tandem gate had never once executed on this machine (the standing "1 skip"
  everyone read past); `sqlite3`, the differential oracle for 18 gates, was also absent; and two oracle
  scripts had **never been able to pass** (each `mv`'d a binary onto itself, dying before a single
  assertion). **At session start, prove your gates execute: check the tool deps exist, and read assertion
  COUNTS, not exit codes.** A gate whose failure mode is "exit 0" manufactures confidence.
- **Stale worktree:** a long-lived orchestrator worktree drifts behind → `git merge origin/main` it before
  relying on its state (**never bare `git merge main`** — it SILENTLY NO-OPS when another worktree has
  `main` checked out).
- **Session start:** `git worktree list` + `ps` — check for other live sessions, orphan gate processes, and
  stale worktrees (prune merged ones; preserve your own, any running agent's, and branches with unmerged
  commits).
- A "surgical one-node" scope hypothesis turns out coupled to a deeper issue → the STOP guardrail catches
  it; re-scope rather than ship "panic-gone but output-wrong."

---

## Bookkeeping

- A `TaskList` chain for multi-step sub-projects (blockedBy dependencies); mark in_progress/completed as
  you go.
- After each landing, reconcile `PLAN.md`, and verify root-cause claims on the binary before trusting them
  in docs.
- Record durable workflow learnings in memory; record role learnings **here**.
- **Pin a must-fail fixture to the DEFECT issue, never the multi-PR STAGE issue.** A stage issue
  (e.g. an arc-tracking #1110) closes when the stage lands, long before the pinned defect is fixed —
  `must_fail_census.sh` then reports PINNED-BUT-CLOSED and the next reader has to work out which of
  the stage's PRs the pin meant. File a dedicated issue for the defect and retarget the pin to it.
  ⚠️ The retarget is not a one-line edit: `diff_compiler_must_fail.sh` cross-checks the fixture
  **directory name** against `claim.txt`'s `issue:` field (`test/diff_compiler_must_fail.sh:386,391`)
  and reports MALFORMED on a mismatch — `git mv` the directory too, so history follows.

### 🏁 At session end, run the `orchestrator-wrapup` skill — don't hand-roll the close-out

Before you tell the user "done," load **`.claude/skills/orchestrator-wrapup`**. "Done" is not
when the last PR merges — it is when the tree, the tracker, and the docs are consistent with what
you actually learned, and the shared box is clean. The skill is the derived (not from-memory)
checklist for that: every friction item / review residual / in-tree marker is **filed** (read the
issue number back — the write path can silently no-op); every open bug you filed is **pinned** with
a self-draining fixture (`test/must_fail_census.sh --all` lists the unpinned); child
`worktree-agent-*` trees are **removed** (never one with unmerged commits or a live agent); orphan
`build_oracles`/`xargs -P` pools are **reaped** (`TaskStop` the owner first, its PIDs only, never a
box-wide `pkill`); scratch/`/tmp`/stray artifacts are cleaned and `git status` is clean; and durable
learnings are written into ORCHESTRATING.md / AGENTS.md / memory / the misleading skill — committed,
not left dangling. The loose ends a long session accumulates evaporate unless you deliberately land
them.

---

## Medaka specifics

Build/seed mechanics live in `AGENTS.md`; what is orchestrator-specific:

- **Build in a worktree:** `make -C /absolute/path/to/worktree medaka` — the shell cwd resets between
  calls, so a bare `make medaka` would build the MAIN checkout.
- **Who re-mints the seed:** not agents. An emitter-graph change (`compiler/backend/llvm_emit.mdk` etc.)
  leaves `compiler/seed/emitter.ll.gz` STALE; agents just verify `test/selfcompile_fixpoint.sh` (it
  self-compiles fresh and never reads the committed seed). **You** re-mint at real checkpoints only — it
  is a multi-MB churn commit — with `sh test/refresh_seed.sh` (**run it TWICE**: not idempotent after a
  codegen change) then `test/bootstrap_from_seed.sh`.
- **The decisive emitter gate is the fixpoint** (C3a = native == interpreted emission; C3b = native
  reproduces its own IR), plus the byte-identical `diff_compiler_llvm` / `_modules` / `_typed` /
  `diff_compiler_build` differentials. These compare the native compiler against **checked-in goldens
  captured from itself** — there is no OCaml oracle (OCaml was removed 2026-06-26).
- **Decided invariants — do not relitigate** (see memory): retirement ≠ removal; lazy top-level nullary
  canonical; no catchable panics.
- **A new gap in a tool's native compile** (a tool pulled into the native graph for the first time) is the
  recurring shape: census it gap-tolerantly, then close each gap principled. `compiler/EMITTER-GAPS.md` is
  the gap ledger.

## 2026-07-21 — #814/#816 W3 arc (four adversarial rounds; three merged PRs)

- **A CI watcher parsing `gh pr checks` TEXT is blind to shard failures** — awk field-splitting
  on names containing spaces ("gates (tools)") silently dropped two RED shards and printed
  CI-DONE; the truth needed `gh pr checks N --json name,bucket` + jq (alarm on any
  `bucket=="fail"`, terminal on none pending). Re-derive: compare both forms on any run with a
  failed shard.
- **fmt BEFORE capture/bless, always.** A `fmt --write` after oracle builds / snapshot blessing
  re-stamps the source mtime: oracles read as stale (FORCE rebuild) and the snapshot SOURCE
  section moves (re-bless). fmt itself is no-op-clean on formatted files (verified: mtime
  preserved) — the hazard is purely ordering. Cost two full rebuild cycles this session.
- **The adversarial-review gate earned its keep AGAIN**: rounds 1–3 each found real
  check-green breaks (indirect obligation channels, the cross-module default seam, two wrong
  shadow-discriminator designs); round 4 was the first clean round. Same 4-round shape as
  #803. The structural cause is now filed (#837 binding identity, #838 unified obligations,
  #840 two-mode forks) — check those before designing the next soundness pass.
- **must_fail CONTROL-BROKE can be exactly backwards** (#831): the #814 pin's control encoded
  the issue's contested design premise, so "the ENVIRONMENT moved, not the bug" was wrong —
  the fix rejecting the control WAS the fix working. Verify which side moved before draining
  or reverting; never close/keep an issue on that message alone.

## The dispatch arc, 2026-07-24/25 — three fixes, one class, and a merge I got wrong

Seven independent defects lived on the dispatch surface where the tracker recorded one. Three
lessons generalise past this subsystem.

- 🚨 **I MERGED ON EVIDENCE I HAD MYSELF DECLARED INSUFFICIENT, AND IT SHIPPED AN S0.** I told a
  reviewer I would merge PR #1058 only if three things came back clean — a 25-row matrix, four
  named axes, and an order-permutation probe I called *"the one thing I most want tested."* I
  merged having received the matrix. The probe, run afterwards, found exactly the failure mode I
  had predicted in writing (#1072: most-specific-wins decided by module order). **A merge
  condition you state and then don't enforce is worse than never stating it** — it buys the
  reassurance without the check. If you name a gating probe, gate on it or withdraw it out loud.
- ⚠️ **"The matrix is clean" is not "nothing regressed" — and the reviewer's own `AXES.txt`
  said so.** That file exists to enumerate the axes a corpus does NOT vary. It was written,
  read by both of us, cited by me to the reviewer, and then both of us treated a clean matrix as
  sufficient. **A document that names its own blind spot only works if you re-read it at the
  moment you are about to conclude.** The axis that mattered here was *import visibility* — not a
  missing row, a missing dimension.
- ⚠️ **When two derivations disagree, ask what truncated the INPUT — do not unify the OUTPUT.**
  Three attempts at one S0 class: make the consumer tolerant (#1058 — closed 3 S0s, bought a
  spurious-arm S0); make the producer canonical (my prescription — **disproved by building it**,
  and it would have broken `eval`, which was right *because* a bare head defers the choice to a
  full-visibility runtime re-resolution); finally, widen the **selection universe** (#1081 — the
  stamp tables were built over a topological prefix, and route selection is a *global* minimum).
  Unifying two derivations' output agrees on the wrong answer faster and looks like progress
  because the encoding gets cleaner. **Diagnostic:** if your fix makes two consumers agree, check
  whether a *third* consumer of the same facts also changes — #1081 found two more, which was the
  evidence the input was the defect.
- **A passing probe of yours does not refute a failing probe of theirs.** An agent reported an
  eval-only S0; my reconstruction returned the *correct* answer and I nearly dropped the finding.
  Their default body made two sibling calls, mine made one — only two reproduces. Their worktree
  was still on disk. **Fetch the artifact; a prose repro under-specifies the load-bearing detail**,
  because the reporter did not know which detail was load-bearing either.
- **Scope a pre-push tripwire to where it can act.** My closing-keyword grep fires on keywords I
  am *describing*, and in an issue/PR **comment** those are inert — GitHub only acts on PR bodies
  and commit messages. High false-positive rate where risk is zero trained me to override it
  twice in one session. Grep bodies and commit messages; skip comments. *A warning you learn to
  ignore is worse than no warning.*


## Stage S of the typecheck arc, 2026-07-30 — building the gate found more than hunting would have

Twelve issues, three of them S0, from landing three PRs. **Six came out of BUILDING and
REVIEWING a conformance gate and its specs, not from looking for bugs.** #616's premise —
a spec with no executing gate accumulates divergence silently — is now measured rather
than argued: two of the S0s are invisible to `diff_compiler_engines` *by construction*,
because both engines agree on the wrong value.

- 🔴 **PROVING A NEGATIVE INSIDE ONE FILE IS NOT PROVING A NEGATIVE. Four wrong verdicts,
  one root cause.** An enforcement-table row saying "no implementing site" is a *negative
  existence claim*, and every one that failed this session failed the same way:
  - DICT §3 **W2** — grepped for the spec's words (Paterson, coverage condition,
    structurally smaller); the code calls it a **fuse** (`routeOfD`, depth-32, #217).
    *Wrong vocabulary.* (Backticks deliberately omitted: those are search strings that
    resolve to nothing, and `agent-doc-symbols` correctly flags a backticked one as a
    dead symbol claim — it caught this paragraph on its first run.)
  - DICT §5.1 **M2** — searched `typecheck.mdk` for `T-*` codes; the check is
    `MethodNotInInterface` in **`resolve.mdk`**, no `T-` code at all. *Wrong stage.*
  - DICT §8 **I4** field half — right file, but no search word covered
    `T-AMBIGUOUS-FIELD`. *Right place, wrong words.*
  - DICT §4.1 **G2** — a *positive* misread: "over non-expansive parts", written after
    reading the very line that refutes it, because the three sibling arms (`ETuple`,
    `EListLit`, `ERecordCreate`, all `allList`) made the wrong reading look obvious.

  **My guidance caused three of them.** I wrote *"search the implementation's vocabulary,
  not the spec's"* with synonym families (fuse/fuel/depth, guard/gate/check) — a purely
  **lexical** widening, and the example I cited was also lexical, which reinforced the
  incomplete reading. The rule is **vocabulary AND stage**. Index the *error constructors*
  (`ppResError`'s arms) rather than only `T-` codes.
- 🔴 **A spec-only (no-build) agent's "no site exists" is a HYPOTHESIS, not a finding.**
  Both M2 and I4 died to one probe each. The no-build constraint is right for a spec task
  — it is also exactly why the coordinator must probe the enforcement rows before merging.
  Budget for it; it is cheap and it caught two false claims in one round.
- ⭐ **Reviewing a rule ≠ reviewing its citations — and it found a memory-safety S0.**
  #1139 (clean typecheck → **segfault**) came from asking *"is §4.1 G3 sound?"*, tracing
  its premise to `isNonexpansive`, and finding the constructor arm tests only the LAST
  spine argument. Nobody was hunting a value-restriction bug. **And the comment directly
  above the defect specifies the correct rule** — so the code diverges from its own
  documentation, which makes the fix need no adjudication. Ask it of every normative
  paragraph.
- ⚠️ **A proposed LAW may be covering for an unenforced one.** An analysis proposed a sixth
  design law (L6, "elaboration output is total"). Adversarial review killed it: the
  flagship bug was an **L1 violation** — `ImplUniverse` is complete (unions `univHeadless`),
  `KeyBuckets` is not — with a working reference implementation 1200 lines away. The plan
  already prohibited it; what was missing was that the stage blast lists never named the
  incomplete copy. **Before adding a law, check whether an existing one is being violated
  unnoticed.** Its own completeness argument was circular (the bucket is exhaustive
  *because* the tyvar-headed entries were dropped at construction).
- ⚠️ **"Write the command, never the number" needs a caveat: a FILE grep is a candidate
  list, not an answer.** `grep -rln elaborateDict` over-counted the `Flat` consumer set by
  two (files that mention the symbol only to say they don't use it). Ship the command *plus*
  the narrowing step.
- ⚠️ **The closing-keyword trap fires from QUOTED material.** An agent nearly pasted a
  ledger's quotation of another issue's decision record — *"Both options close #817/#825
  equally"* — into a live comment, which would have closed two open issues. The precise
  rule (derived while dodging it): GitHub acts only when the keyword **directly precedes**
  the number, so `"#1095 is closed by the arc"` is inert and `"close #817"` is not. That
  is why a keyword scan yields both true and false positives, and why each hit needs a
  human look rather than an auto-rewrite.
- ⚠️ **I overstated my own issue count by four**, in a session spent enforcing
  derive-don't-encode on everyone else. `gh issue list --author @me --search created:<date>`
  is one command. Derive the tally before reporting it.
- ⚠️ **My worktree was 4 commits stale at wrap-up and a pin-status grep reported everything
  ABSENT.** I nearly reported a false alarm about missing fixtures. `git merge origin/main`
  before *any* wrap-up derivation — the state you are auditing is on `main`, not in your tree.

## The typecheck arc, 2026-07-31 — five merges, and SCOPING outperformed hunting 3-for-3

Val's lane: #1139 → #480 → #1146 → F-3 → A-spine. Merged `f3da5bb0` (#1139 memory-safety
S0), `ec51c28e` (#480, 8 forked implementations → 3), `c06fa1bf` (#1150 pinned + bug-fit
rows), `adda533c` + the #1146 PR-2 pair, `08821074` (#1154 pinned). Filed #1145, #1146,
#1147, #1148, #1150, #1154, #1155. **Withdrew a planned stage that could not build.**

- ⭐ **A READ-ONLY SCOPING PASS BEFORE EACH STAGE PAID OFF EVERY TIME — 3 for 3.** F-2
  (#1120) was withdrawn because all three of its design claims were false and the
  prescribed 2-module split is a **hard loader cycle**; #1146's stated mechanism was
  refuted and its counts were wrong (my "−3 duplicated judgments" was really −1); F-3's
  scoping found an **unfiled S0** (#1154) and proved the epic's "single-PR sized" wrong.
  Cost: one read-only agent each. The alternative was an implementer discovering it after
  hours — or worse, finding a shape that *does* build by exporting five pieces of
  inference state. **Scope the stage, then implement it.**
- 🔴 **FOUR OF MY OWN PRESCRIPTIONS WERE UNSAFE, AND AN AGENT CAUGHT EVERY ONE BY
  BUILDING.** (1) "replace the spelling heuristic with `isSome (lookupCtor env name)`" —
  introduced a **strictly worse S0**, because the ctor map is bare-name and graph-wide.
  (2) "put the comment on its own `--` line" — `medaka fmt` mangled unrelated comments.
  (3) "run bare `make medaka`" — denied by the classifier, repeatedly.
  (4) "wrap it in a scratch script" — **swallowed the exit code**, producing two false
  "this gate is broken" reports. None was catchable by reasoning. **Prescribe the
  intent and the constraint; let the agent derive the mechanism, and treat its
  divergence report as the deliverable it is.**
- ⭐ **"Ask the environment instead of guessing from spelling" is NOT automatically L2
  compliance.** A table keyed by a bare name *is* spelling. Before endorsing a lookup, ask
  **what is that table keyed by, and who writes to it.** Membership ≠ resolution.
- ⭐ **Reviewing a spec's ENFORCEMENT TABLE means asking whether each row actually
  enforces.** Twice this session a table cited a fixture that provably never exercises the
  clause it was listed under (proof: the fixture's golden contains a line emitted *from
  inside the block the gate skips*). A row that does not enforce is worse than no row — it
  retires the question. This is the L5 analogue of "review the rule, not its citations."
- ⚠️ **For an acceptance WIDENING, every existing golden passes by construction.** They all
  cover the narrower behaviour. The check that bites is a **declaration-order permutation
  differential** — permute and assert byte-identical output; it detects an order-decided
  winner *without knowing the right answer*. Corollary: make the ambiguous case **loud**
  before widening, and the blind spot closes by construction.
- ⚠️ **`sh test/build_native_medaka.sh`, not `make medaka`, in agent briefs.** Bare,
  foreground, in-worktree `make medaka` was denied for two agents — one *after* an
  identical invocation had succeeded minutes earlier — while the script (which is literally
  the Makefile target's body) has never been denied. Also: the EnterWorktree tool is a dead
  end here (an isolated agent's cwd is already the worktree, so there is nothing to enter),
  and cwd **does** persist between Bash calls, contra the note in `AGENTS.md`.
  ⚠️ Backticks deliberately omitted on those two tool names — `agent-doc-symbols` resolves
  every backticked token against `.mdk`/`.c` source and correctly flags a harness tool name
  as a dead symbol claim. It caught this very paragraph on its first run, in a doc that
  already warns about it.
- ⚠️ **Four agents died ending a turn with a build in flight**, returning a status line and
  producing nothing; one then lost its worktree *with* the build. Put the failure mode in
  the prompt **by name**, and say that partial verbatim results beat a status line.
- ⚠️ **Reproduce a friction item before filing it.** An agent reported the strongest gate in
  the tree silently exiting 0; the source says `exit 2` and the gate is correct — the
  wrapper *I* had prescribed ate the code. Filing it would have aimed someone at working
  code. Four agent claims this session did not survive checking.
- ⚠️ **An unreachable memory is not a memory.** The index had **87 orphaned entries**, one of
  which — *"ask what property the fix now RESTS ON"* — is precisely the check that would
  have caught prescription (1) above. It had been on disk for a week with nothing linking
  to it.

---

## Two ways the tooling manufactured a confident wrong reading, 2026-08-01 (F-3 lane, epic #1122)

Both were caught by cross-checking rather than by any gate. Neither presents as a failure —
that is what makes them expensive.

- 🚨 **A PR's HEAD CAN SILENTLY LAG ITS BRANCH REF, AND IT PRESENTS AS GREEN AND READY.**
  Measured on PR #1184. A push landed on the branch ref, but GitHub never fired the
  synchronize event: for 20+ minutes the PR's headRefOid — via both the REST-ish JSON field
  and GraphQL — reported the **previous** commit, the checks command said all pass (for that
  previous commit), and mergeStateStatus read CLEAN. The tell nobody looks at: **no CI run had
  ever started for the new SHA.**

  The danger is specific. **The merge queue merges the PR's head.** Enqueueing there would
  have merged the commit *without* the fix, while every signal on screen said the fix was
  included and verified. This is worse than the gh write failures already recorded in this
  file, which fail visibly on readback — this one presents as success.

  **Before enqueueing, cross-check three sources and require agreement.** Two of them agreeing
  is exactly the failure state:

  ```sh
  gh pr view <n> --json headRefOid --jq .headRefOid        # what the PR thinks
  git ls-remote origin <branch> | cut -c1-40               # what the ref actually is
  gh run list --branch <branch> --limit 3 --json headSha,status,conclusion \
    --jq '.[]|"\(.headSha[0:8]) \(.status) \(.conclusion)"'   # a run must exist FOR THAT SHA
  ```

  Remedy when they disagree: closing and reopening the PR (`gh pr close <n>` then
  `gh pr reopen <n>`) forces GitHub to re-sync the head and fires CI on the correct commit.
  Comments and review state survive. Verified to work.

  This is the same family as *"a tool reporting success while nothing happened"* under
  Repo/infra, and the remedy is the same: **verify the resulting state, not the return code —
  and here, not the PR's own idea of its state either.**

- ⚠️ **TWO TIMING TRAPS THAT PRODUCE A CONFIDENT WRONG DIAGNOSIS.**
  1. **Local clock vs GitHub UTC.** This box runs CEST (UTC+2) while GitHub timestamps are
     UTC, so a merge_group run created 3 minutes ago looks 2 hours stale next to uptime.
     Run `date -u` before comparing any GitHub timestamp to anything local. This nearly
     produced a "the queue is jammed" diagnosis on a perfectly healthy run.
  2. **Run logs are unavailable while the run is in progress** — the fetch refuses with
     *"logs will be available when it is complete"* — **even for a job already reported as
     failed.** So a red shard cannot be diagnosed until every *other* shard finishes.
     Useful in the gap: **derive candidates at source instead of waiting idle.** For a
     suspected stderr-capture golden move, sweep the shard's own scripts for `2>&1` and name
     the candidates before the log arrives; the log then confirms or refutes in one read
     rather than starting the investigation.

---

## Stage A-1 of the typecheck arc, 2026-08-02/03 — four PRs, and the recurring defect was a CLAIM REACHING PAST ITS EVIDENCE

#1234 → #1235 → #1238 → #1244 (rigid/mono separation, arc #1110, epic #1122). Every one of the
four merged 12/12 green and was reviewed adversarially. In all four the finding was **not wrong
code** — it was a *claim*, in a comment or a PR body, that asserted more than had been measured.
Different surface each time:

- **#1234** — the PR's own first commit (`e8b2483f`) never touched `compiler/entries/
  origin_agreement_main.mdk` or `test/diff_compiler_origin_agreement.sh`, so both still quoted
  `resolve.mdk`'s old *"FLAT (loader-less) DRIVERS GET NOTHING HERE"* text verbatim and described
  #1227 as still open, after the fix landed. Invisible to every gate: `compiler/entries/*.mdk` is
  not in the snapshot corpus (no `origin_agreement_main.md` under `test/snapshots/`), and a gate
  script's own prose is never diffed against anything. Caught in review, fixed in the same PR
  (`5fbca08c`).
- **#1238 round 1** — a source comment stated *"a rigid name is lexically lowercase and a real
  `TCon` name lexically uppercase,"* which licensed leaving four wildcards unarmed. Both halves are
  false at the edges: `identStartLower` accepts `_`, and a **real** head can legally be
  `__tupleN__` (`tupleCtorTyName` via `tyConBuiltin`) — so the two populations collide there.
  Measured: `data Bad = Bad __tuple2__ ; g : Bad -> (,) ; g (Bad v) = v` typechecked clean on
  `main` and produced `Type mismatch: (,) vs (,)` — an error whose two sides render identically —
  on the branch before the fix. Fixing it exposed a second, S0-shaped hole once the discriminating
  fixture's positive control deleted the new arm: not a different diagnostic, but **no diagnostic
  at all** (silent accept, exit 0).
- **#1238 round 3** — a fixture header claimed its program exercised the eleven exhaustive `Mono`
  match arms. `test/eval_fixtures/` is **typecheck-free**: none of its five consumers (this gate,
  `bootstrap_eval.sh`, `diff_compiler_core_ir.sh`, `diff_compiler_core_ir_roundtrip.sh`,
  `diff_compiler_snapshot_core_ir.sh` — none of whose entry points, `entries/eval_main.mdk:19`,
  `entries/core_ir_main.mdk:33`, `entries/core_ir_roundtrip_main.mdk:28`, `tools/snapshot.mdk:588`,
  imports `types.typecheck`) constructs a single `Mono` for a fixture here. The author's own
  positive control (delete an arm → fixture still green) supported the *wide* conclusion
  "typecheck is not reached" and the header wrote the *narrow* one, "the dispatch half is not
  reached" — the same species of overreach as the false naming invariant one round earlier, on a
  probe that was itself sound. `test/diff_compiler_eval.sh`'s own header now says this was "twice"
  written confidently and wrongly, and points a type-level assertion at
  `test/typecheck_error_fixtures/` or `test/typecheck_fixtures/` instead.
- **#1244** — three `resolve.mdk` comments plus the PR body asserted that a re-exported interface
  always attributes to its **definer**. True only where the re-exporter does not also declare the
  name itself: a module that both declares and re-exports the same interface attributes it to the
  re-exported source instead (filed #1245). The identical mechanism already reproduces on the
  `data`/type side, which #1244 never touched — so #1244 replicated a pre-existing defect into a
  second namespace rather than introducing one (see "Split a PRE-EXISTING defect..." above).

**Why it matters for orchestration:** no gate can see this class. Goldens pin *output*, not
*justifications* — a comment or a PR-body claim can be flatly false while every fixture stays
green. A false claim is exactly what the *next* agent inherits and builds on, so it propagates
silently instead of failing loudly. Add this to every review brief, as a question separate from
"is the code correct": **is every claim in this diff's comments and PR body supported by what was
actually run, or does it merely describe what the author expected to be true?**

---

## Stage A-2 of the typecheck arc, 2026-08-03/05 — role lessons, none about the code

- 🚨 **"Landing is serialized" is an instruction about ARMING, not a prediction about
  ordering.** Arming two PRs that both touch one file puts both in the merge queue, and the
  queue builds a temp branch of *your PR merged onto `main` plus everything queued ahead of
  you* — so two PRs that each merge cleanly onto `main` can still conflict with **each
  other**, and GitHub gives no signal for it: both read `mergeable: MERGEABLE`,
  `mergeStateStatus: CLEAN`, because each is evaluated against `main` alone, never against
  its queue siblings. Measured: two units collided in 4 files, two of them **goldens** — and
  goldens are re-cut, never text-merged (see the ledger entry above), so a queue auto-merge
  would have spliced two independent re-cuts. The check GitHub does not run for you, before
  arming a second PR that shares a file with one already armed:
  ```sh
  git merge-tree --write-tree --name-only origin/<branch-a> origin/<branch-b> | tail -20
  ```
  And a related trap in the same arming step: `gh pr merge --disable-auto` does **NOT**
  dequeue an already-queued PR — it returns *"already queued to merge"* and
  `isInMergeQueue` stays `true`. The GraphQL mutation is the only thing that pulls one
  back out:
  ```sh
  ID=$(gh api graphql -f query='{repository(owner:"MedakaLang",name:"medaka"){pullRequest(number:N){id}}}' --jq '.data.repository.pullRequest.id')
  gh api graphql -f query="mutation{dequeuePullRequest(input:{id:\"$ID\"}){mergeQueueEntry{id}}}"
  ```
- ⚠️ **A review finding relayed into a fix brief becomes a CONSTRAINT, not a claim.** When
  you hand an implementer *"the reviewer found X, therefore do Y,"* Y arrives as an
  instruction — pushing back on it costs the implementer credibility rather than earning it.
  Four times this session an agent had to contradict a brief of mine that had laundered a
  reviewer's *observation* into my own *inference*; each time they were right, and each time
  they had to run a control I had not. **Mark the epistemic status explicitly** — *"the
  reviewer OBSERVED X; whether that means Y is UNVERIFIED, check it"* — and say plainly that
  the agent may contradict it. A finding you did not reproduce yourself is a hypothesis with
  a reviewer's name attached to it, not a fact.
- ⭐ **Budget for the review yield; it does not decay.** Every behaviour-changing unit that
  entered adversarial review this arc came back with a real finding, all 12/12 green
  beforehand — including **two S0s introduced by the fix for another S0**, and one
  **quadratic that `make preflight` structurally cannot see** (it never selects
  `diff_compiler_perf_scaling.sh` on its own). One unit took **four** rounds; most took one
  or two. Rounds are not churn when each attacks a dimension the last did not — track *what
  dimension* each round covered, and stop when a round would only re-cover one already
  closed, not when the round count merely feels high. Split every review brief into two
  graded deliverables: *"is the code correct"* and *"is every claim in the comments, fixture
  headers, and PR body supported by what was actually run"* — grading the second can ride on
  the first once it is done.

  ⚠️ Prefer a fact with a **derivation** over a bare assertion — but **run any command you
  write, verbatim, and read its actual output** before trusting the derivation: this same
  arc shipped a `grep` with an un-escaped `|` in a BRE (no `-E`), which matched only its own
  comment text and "re-verified" a false claim. A command that cannot fail carries more
  authority than a wrong number does.

- ⭐⭐ **Run the two review lenses SEPARATELY — one adversarial, one conformance-plus-claims —
  and don't let either ride on the other.** One reviewer tries to break the fix; the other
  grades spec conformance **and** audits every claim in the PR body, code comments, fixture
  headers, and issue bodies against what was actually run. Grading them together lets the
  claim audit ride on the code review, which quietly drops it. Yield this session: **9 review
  passes, every one found a real defect**; both behaviour-changing units were blocked while
   green on every required check — one shipped a fix that worked on `check` and was inert
  on `run`/`build`, the other a regression turning a correct program into a crash. The two
  lenses also caught **each other's** errors twice: they reached opposite verdicts on one
  fixture header (the adversarial reviewer was right), and a round-1 reviewer's confident
  mechanism claim (`export newtype` "never" sets `newtypePub`) was false and drove a
  prescribed fix that was later measured to fail. A single reviewer returns one verdict with
  no signal that it might be wrong — the split is what supplies the signal.
- ⭐⭐ **Verify the CONSEQUENCE, not the mechanism.** The session's dominant failure, three
  costumes on one PR: a byte count proved a `gh api -X PATCH` write *happened*, not that the
  body *contained the corrections* (two rewrites landed, every retracted claim was still
  present); enumerating a field's **writers** answered the wrong question when the actual
  defect was who **clears** it; a regression fixture reached the changed code path but could
  not observe the consequence — green on the pre-fix commit, emitted IR byte-identical across
  the "fix". The countermeasure that worked every time: state the acceptance test as an
  observable on the **artifact**, never on the action — e.g. `grep -n '<retracted phrase>'
  <body>` must be empty, not "the PATCH call returned 200".
- ⚠️ **The orchestrator's own prescriptions need the same discipline as an agent's claims.**
  Three times this session a confidently-relayed mechanism was wrong while the conclusion
  happened to be right anyway. Each was caught only because the implementing agent
  **measured** the prescription instead of applying it as given. Brief agents to test what
  you hand them — say so explicitly in the brief, not just as a general expectation.
- ⚠️ **Two silent fleet hazards on this shared box, both cost real time:**
  - **The scratch root is shared.** One agent's `make preflight` log was overwritten by a
    sibling's and read as its own result — caught only because the log text happened to name
    the other agent's worktree id. Require gate logs at a path **private to the agent's own
    worktree**, with the exit code captured on the **next line, no pipe** (a piped exit code
    is the pipeline's, not the command's). Tell agents to grep any log they rely on for a
    foreign worktree id before trusting it.
  - **`refs/stash` is shared across every worktree** (`git rev-parse --git-common-dir` is the
    same `.git` for all of them). A bare `git stash pop` grabbed a *different* agent's entry.
    Ban bare `git stash`/`git stash pop` in briefs; use a throwaway WIP commit instead, or
    `git checkout <commit> -- <files>` to materialize a counterfactual arm without touching
    the shared stash stack.
- ⚠️ **Worktree reaping is attribution-blocked on a shared box.** `git worktree list` showed
  58 trees with a sibling orchestrator active concurrently. Only reap a tree you can actually
  attribute to your own session, and only when all four signals agree: no unmerged commits,
  clean `git status`, not locked, and no live process with its cwd inside it. Where any signal
  is missing or another orchestrator's activity is plausible, **report the tree rather than
  acting on it** — an unattributable reap risks deleting a sibling's in-flight work with no
  way to undo it.

## The gzip dogfood arc, 2026-08-05 — a pinned BOUNDARY, and defenses that mask

A capstone dogfood (`gzip/`, DEFLATE decompressor) built end to end by Sonnet subagents.
Five PRs merged, two enqueued, six issues filed. Three lessons generalise past the project.

- ⭐ **PIN THE UNIMPLEMENTED BOUNDARY IN A GATE, NOT IN PROSE.** A staged feature always
  has a "not yet implemented" edge. Writing it in a comment rots silently; asserting it in
  a gate makes the *implementation* flip the gate red and name the file to update. Used
  twice here: the Phase-2 boundary (`expect_fail … "not yet implemented"`) went red exactly
  when fixed-Huffman landed, and was replaced by real round-trips plus a fresh Phase-3 pin.
  Cost: one line. It converts "someone will remember to update the gate" into a mechanical
  instruction delivered at the right moment, to the right person.
- 🚨 **A DEFENSIVE LAYER THAT DEGRADES SILENTLY IS THE MASKING PATH FOR THE BUG IT GUARDS.**
  The fix for a shrink-loop hang (#1307) added a fuel cap — correct — that returned
  **silently** on exhaustion. So a future cycling arm would produce a *worse* counterexample
  after 10000 quiet evaluations and nobody would ever learn the cycle existed. Removing a
  hang is right; removing the *signal* with it is the loud→silent regression this repo ranks
  as a severity increase. **For any cap/limit/fallback you add, ask what an observer sees
  when it fires — and make it say so.** Then watch it fire (temporarily shrink the limit)
  rather than trusting that it would.
- ⚠️ **CHERRY-PICKING AN AGENT'S COMMIT BREAKS THE WRAP-UP WORKTREE CHECK.** Landing agents'
  work by `git cherry-pick` onto your own branch (rather than merging their branches) means
  their original SHAs are never ancestors of `main`, so `log origin/main..HEAD` reports
  "unmerged" **forever** and every such tree looks unreapable. The discriminating check is
  **content identity, not ancestry**: for each file the branch touched, compare
  `git -C <wt> show HEAD:<f>` against `git show origin/main:<f>` — all-identical means the
  work landed and the tree is provably redundant. That cleanly separated 5 reapable trees
  from 3 whose work was still in flight, where ancestry alone said "hold" for all 8.

⚠️ **Two of the three defects worth reporting this arc were found by MUTATION, not review.**
Four RFC tables shipped with no assertion at all — corrupting one cell left all 13 checks
green — and a byte-corruption helper was appending 16 literal characters, so its gate passed
for the wrong reason. Neither is visible in a green run or in a careful read. When a change
adds a *table* or a *byte-level helper*, perturb one cell and confirm something notices;
budget it as a review step, not an optional extra.

## #1319 unit 2, 2026-08-06/07 — SPLIT the adversarial review into two lenses; they catch disjoint sets

Three rounds on one PR (`typecheck.mdk`, +313 lines), run **during a GitHub Actions outage**, so
CI was not even a floor. The author reported ~50 local gates green, `selfcompile_emit` 40/40
byte-identical, `engines` 562 fixtures 0 regressions. It would have merged on a green rollup.

**Two reviewers, two briefs, and they found disjoint defect sets — neither found the other's:**

| lens | brief | what it found |
|---|---|---|
| **correctness** | attack the code: precedence ladder, key scoping, over-widening, perf, driver lockstep | a **confirmed accept→reject S1** on ordinary code (two libraries sharing a field name), and a **super-quadratic** (r3 = 6.47 vs a hard 3.0) |
| **claims** | attack the PROSE: PR body, commit message, code comments, fixture headers, ratchet reason strings | a **false guarantee shipped in three durable places** incl. a ratchet reason string, and a "derived, not assumed" claim whose grep **structurally could not match** the declaration it was asked about |

A single general reviewer spends its budget on the diff and skims the narrative. **Brief the
second one that the narrative IS the diff.** This arc's standing finding — *nine reviews, nine
findings, almost all in prose* — is the reason, and it kept holding.

**Both lenses must build a BASELINE binary from the merge-base.** Every before/after number in a
PR body is a claim. The correctness reviewer's S1 was found by re-deriving the author's own
before-column and getting a different answer.

### The counterfactual is the review step people skip, and it inverted twice

*"I added a generator so the gate can see this defect"* is not a gate until someone runs it
**against a bug-present binary**. Measured here: the first generator read **`ok`** (r2 = 2.38) on
the very defect it was added for — the ALLOC arm, which the file's own header calls the primary
deterministic verdict; it reddened only via TIME, by 3.6 %, on the signal this repo distrusts.
The fix was in the generator's own text (it already used a K-multiplier for the interface half
and explained why). After strengthening: ALLOC r2 = **5.41**, decisively red.

**Same for any "this fixture guards X" claim** — stub the thing back in and confirm red. A
fixture that passes with the feature disabled is testing nothing, and this tree keeps producing
them (the retired #66 row was a *permanently*-unfailable pin that no fix could ever have flipped).

### 🚨 A fix for "your enumeration is incomplete" can be to DELETE the enumeration

Round 1 flagged the PR's severity-direction section as under-enumerating. **Round 2 dropped the
section entirely** — and *neither* reviewer caught it, because both were hunting a **wrong** claim,
not an **absent** one. It surfaced only in the author's own round-3 report.

**Add "what did the last round REMOVE?" to a delta-review brief.** A diff of the prose, not just
of the code.

### Hedges die in the handoff — twice, the second time inside the fix for it

An agent's report to you labels its claims (*"inferred, not instrumented"*); **the PR ships them
flat**. I then restated the agent's labels to a reviewer as a property of the PR — the third time
in this arc that the claim reaching past its evidence was an *orchestrator brief*. Corrected the
author, and round 2 announced the fix as landed **inside the section named for that split** while
the diff touched the function **zero** times.

**Verify the artifact, never the report** — `git diff <prev> <new> -- <file> | grep -c <symbol>`
costs one command. The instinct to report upward and consider it delivered survives an explicit
correction, so check rather than re-ask. See `feedback_epistemic_labels_die_in_the_handoff`.

### Two adjudications worth reusing

- **"A variant still reproduces" is NOT grounds to keep a pin.** The test is whether the
  *variant's control* still discriminates the filed defect. Here the value-only spelling failed
  **with no re-exporter at all**, so it was a different defect (filed separately, pinned) rather
  than evidence the original was undrained. Treating them as one would have made the eventual
  drain name the wrong issue — which the one-fixture-per-issue rule exists to prevent.
- **Prefer REMOVING a half to repairing it out of scope.** Three of four blockers lived in one
  call chain whose correct predicate turned out to be a *different analysis* (type reachability,
  not constructor spelling). The author removed that half and stated plainly, in a box rather than
  a footnote, which tracker row is therefore **not** drained. A narrower PR with an honest gap
  beats a wider one with a quiet regression — but only if the gap is recorded at equal strength in
  every durable place (ratchet row, source comment, commit message, PR body). Grep for the stale
  footnote; that is the failure mode of an honest headline.

## The typecheck arc, 2026-08-07/08 — eight merges, and the biggest defect source was MY OWN PROSE

Eight PRs merged (#1389, #1393, #1395, #1390, #1410, #1381, #1411, #1415), two S0s closed, six
issues filed. **Fifteen review passes, fifteen real findings, zero PRs correct as first
submitted** — every one green on all twelve checks beforehand. The base rate has not decayed.
What follows is only what generalises.

### ⭐⭐ The orchestrator's PR body is the one artifact with no reviewer

**The plurality of blocking findings this session were in text I wrote, not in agent code.** Agent
diffs got two adversarial lenses each; the body I wrapped around them got none until a lens
happened to read it — and a PR body becomes the merge commit message.

- A **round-1 rationale surviving into a round-2 body** (#1393): it still asserted the exact
  framing the round-2 source retracts in a 🚨 block.
- A **stale count** (#1390): "exactly two deviations" after review moved it to three — in a PR
  where a claims lens had already *certified* "two" as true against the artifact.
- A **diffstat that was neither figure**: `+144/−10` — a net insertion count paired with a
  *summed* deletion count. ⚠️ **Round diffs do not compose additively** when a later round
  deletes text an earlier one added. State the true net or the true sum, never one field of each.
- A **fabricated line number** relayed into a brief, and a **reviewer's overcount** ("two source
  comments"; there was one) passed through verbatim, costing an auditor a cycle hunting it.

**Every one was a number or a `file:line` I had not run.** Countermeasures, all cheap:
brief the claims lens at **the body, not just the diff**; re-read the body after every fix round;
and **never quote a repo-wide count** (`docs-links` references, symbol claims, corpus totals) —
it is a property of the whole tree at run time, `main` moves under concurrent work, and the only
durable assertion such a run makes is **0 dead**.

### ⭐⭐ A faithfulness check can CERTIFY the property that is the defect

#1390 restored three spec clauses a 173-line hunk had silently deleted three weeks earlier. The
claims lens machine-diffed the restoration and **confirmed "verbatim, exactly two deviations."**
The rules lens then found that **the verbatim-ness was the defect**: the restored clause asserted
something true when written and falsified by a ruling that landed *while the clause was absent* —
so nobody reconciled it, and a faithful restore reintroduced the very "one question, two answers"
defect the issue existed to drain.

**A restore, revert, or cherry-pick is never a null change. Measure the licensing delta against
CURRENT `main`, never against the point of deletion** — "every sentence stood here until commit X"
is a claim about history, not about obligation. And **text that was absent while a ruling landed
is the highest-risk text in the tree**: it is precisely what no reconciliation pass looked at.

Neither lens found the other's defect. This is the sharpest argument yet for the split.

### ⭐⭐ Test every warning the author WROTE against the author's own diff

Twice this session a PR's own comment stated precisely the rule its change broke. #1393's new
comment read *"Over-offering is not additive: the entry it manufactures SHADOWS whatever the front
end actually bound"* — written to justify deleting one arm, while the same diff added a new
over-offering path that adversarial review confirmed as a regression. #1381's review found the same
shape one PR earlier.

An author who writes a warning has the right rule in hand and lacks only the reflex to turn it on
their own change. **Grep the diff for every normative sentence it adds and evaluate each as a claim
about that diff.** Put it in the review brief.

Its mechanism generalises: **a correspondence claim between two code paths must be checked at the
DATA level, not the control-flow level.** #1393's argument was that one function now mirrors
another "arm for arm." The arms did mirror; the *tables underneath* did not (one gated on
visibility, one did not), so a correctly-shaped question was asked of a wrongly-scoped set.

### ⚠️ A two-call state check FAKES a merge-queue bounce

My watcher reported `#1393 BOUNCED`. It had merged. The loop read PR `state` and `isInMergeQueue`
in **two separate calls**, and the merge completed between them — a bounce and a merge both drive
`isInMergeQueue` to `false` and differ *only* by `state`. On seeing `queued=false` after having
been queued, **re-read `state` and decide on the fresh value**; then confirm any terminal verdict
against the artifact (`git merge-base --is-ancestor <tip> origin/main`), never the watcher's word.

Note the direction: a watcher built to catch a *silent* failure produced a *false alarm* — the
cheaper direction, but a tripwire that cries wolf is one annoyance away from being widened.

### 🚨 "Resolves but isn't true" — citation currency is what nothing checks

Four findings across two rounds were citations that **resolved** and were **wrong**: right file /
wrong line, right quote / expired premise, right file / wrong content, right sentence / inside a
block marked `[REPLACED]`. All four passed a citation audit.

The mechanism is a **seam between two gates**: `check_doc_links.sh` strips a trailing `:NNN` before
validating (its own header says so) and `agent-doc-symbols` grades backticked symbols — so a
`path:line` citation is checked for path existence and **nothing else**. Neither gate is buggy; the
class is uncovered by construction. Evidence recorded on **#1197**.

⚠️ **A rebase alone invalidates line citations without touching a byte of the cited file** — so
"re-derived against the parent" can be true when written and false when merged. I did this to my
own agent's work. **Cite compiler internals by symbol name**, which the gates actually check.

### ⚠️ Two landing hazards, both nearly shipped

- **A closing keyword inside a sentence that means the opposite.** *"whoever **fixes #1216** must
  drain BOTH arms"* sat in a PR body **and** a commit message. GitHub pattern-matches
  `fix(es)?\s+#\d+` and scans commit messages landing on the default branch — it does not read
  English. #1216 was the live S0 the merge decision depended on staying open. **Add the grep to the
  review checklist**: `grep -inE '(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#(N…)'` over the
  body *and* the message. This repo's memory already flags the trap four times and it still shipped.
- **An agent amending a pushed commit that a reviewer has seen.** One agent amended with real
  content changes and force-pushed; the reviewed SHA survived only in the reflog, and the
  amendment carried **+113/−55 of unreviewed prose** that read as "the same reviewed change." A
  sibling agent facing the same choice picked a follow-up commit *"so the reviewer's approved SHA
  stays intact and the delta is reviewable"* — that is the right default. **Say so in the brief**,
  and pin the reviewed SHA (`git branch preserve/<pr>-reviewed-<sha>`) before allowing a rewrite.

### ⭐ Two adjudications worth reusing

- **A prescription that mispredicts once should be demoted, loudly, in the next brief.** The
  recorded plan was that a mangler fix would drain a record-layout S0. It did not — the S0's filed
  root cause was itself wrong (it blamed both emitters; the emitters were correct and typecheck's
  stamp was not). When the next agent was aimed at that S0, the brief said explicitly *"this route
  has already mispredicted once; choose your own fix site."* It found the real cause in one probe.
  **Correct the issue body when a root cause is disproved** — the next reader inherits it otherwise.
- **"Land with pins" is a legitimate answer to a severity-increase finding when the defect is
  PRE-EXISTING and the control proves it.** A unit's accept-widening routed new programs into a
  silent divergence — but a control showed the same graph already reached it on `main`. The unit
  widened *reachability*, not the defect. Landed with a must-fail pin plus the disclosure re-graded
  from S1-loud to S0-silent. The discriminator is the control, not the severity label.

## The shadow arc + wrap-up, 2026-08-08/09 — an UNDER-SPECIFIED RULE relocates its defect

PR #1419 (#1353/#1354 unit A) took **eight review rounds**, and three of them *introduced* a
new S0 while fixing the last. Six issues filed; three pinned in-arc, the other three closed out
here. What follows is only what generalises.

### ⭐⭐ An under-specified rule produces ONE DEFECT PER ROUND, at a DIFFERENT SITE

Rounds 3, 4 and 5 of #1419 each shipped a fresh S0. The cause was **not a weak implementer**.
The question *"which namespace is 'nameable in M' evaluated in"* had **no ruling**, so every
round guessed — and guessed somewhere else, because the previous guess had been patched at the
site the last review named.

**The tell is a defect that RELOCATES rather than recurs.** A recurring defect means the
implementer did not learn; a relocating one means there is nothing to learn *from* — the rule
being implemented does not exist yet. When you see round N's fix hold and round N+1 break the
same property one function over, **stop briefing fixes and go rule the spec.**

Adopting S1-NS mid-arc converted *"try harder"* into *"here is the clause you violate."* The
final fix then **deleted a predicate instead of adding a fourth** — after which the invariant
holds by construction rather than by three agreeing call sites. Prefer the shape that removes
a decision point; it is the only kind of fix that cannot relocate.

### ⭐⭐ When the same CLASS recurs, ask for the ENUMERATION, not the patch

Three consecutive rounds each fixed the lying comments they were **shown** — and each left a
sibling behind: one of two, then two of three, then three of four. Every round was a correct
fix to an incorrectly-scoped question.

One sweep — *"enumerate every comment claiming something about these symbols and verify each"* —
found **five more**, including a **fourth copy in `test/registry_keying_ratchet.sh`**, a file
nobody had opened in eight rounds of review. A reviewer citing instances hands the author a
list; the author fixes the list. **Make the enumeration the deliverable**, and name the symbol
(`selectIfaceRows`, `rpNames`) rather than the file — the claims travel.

Nothing mechanises this today: the two doc gates check that a cited **path** exists and that a
backticked **symbol** resolves, and neither reads `.mdk` or `.sh` comments at all, which is
where most such claims live. Filed as **#1432**. Until it exists, the sweep is the only
defence, and its scope is itself an unchecked claim — so state the scope you swept.

### ⭐⭐ I asserted a set was CLOSED twice, both times by enumerating the WRONG LEVEL

- *"The consumer set is closed at two sites."* I had counted consumers of the two **sets**. The
  decision surface was one level down, at the **row selectors** — three of them, one carrying a
  live S1.
- *"The closure invariant holds by construction."* I had counted selectors **and** sets. The
  property was about **inputs to dispatch**, and `rpNames` was a third input that bypassed the
  predicate entirely. That one was an S0.

Both times I enumerated **what the change TOUCHED** and called it a property of **what I was
CLAIMING**. Those are different sets and nothing warns you when they diverge. Before writing
"closed", "exhaustive", or "by construction": *name the property, then enumerate its inputs* —
starting from the consumer and working backwards, never from the diff forwards.

### ⚠️ Agent liveness needs TWO artifacts, and WHICH two changes

Three distinct false-stall shapes in one session, each of which would have been misread from a
single signal:

| shape | what looked dead | the artifact that proved otherwise |
|---|---|---|
| mid-build | git metadata stale for minutes | the **binary's** mtime |
| mid-probe | binary stale (nothing rebuilding) | the **emit/log file** growing |
| mid-read-then-build | BOTH stale ~10 min | a later binary appearing |

**Low load average is never a stall signal** — an agent reading files pins nothing. Check the
emit file **and** the build artifacts before concluding anything, and note that the pair that
discriminates changes with the phase: neither artifact alone is sufficient in all three shapes.

### 🚨 The PID-poll idiom the playbook mandates is BLOCKED, and the block message routes you toward a yield

The `until kill -0 $PID` form this playbook has been recommending is refused by the harness
classifier, and the refusal text points at the **Monitor** tool. An agent followed that route
and **died with its work uncommitted**, having ended its turn waiting on a notification that
never reached it.

⚠️ **State the mechanism, not a quotation.** This paragraph originally claimed Monitor's own
description says *"do not poll or sleep"* — **it does not; that phrasing was mine, in quotation
marks, and a review caught it.** What is true is the shape: the Bash refusal steers you to
Monitor, Monitor is built to notify rather than be polled, and an agent bounced between the two
lands on "wait for the notification" — which is the one thing that kills it. **A fabricated
quotation is worse than a paraphrase**: it survives review by looking checkable.

**The correct form is `run_in_background: true` on a SINGLE bounded command** — one command, no
`&`, no wrapper loop, and never end a turn waiting on a notification. Put that form in the
prompt itself; an agent handed the bare `until` loop will hit the block and then improvise.

### ⚠️ A multi-round PR body is a LEDGER, and REVERTS DO NOT SELF-DRAIN FROM IT

Rounds 2, 4 and 5 each caught the body's "helpers" section naming symbols that a **later revert
had deleted**. Additions get written into the body as they land; removals do not remove
themselves, so the body drifts in exactly one direction — toward claiming more than the diff
contains, which is the direction a reader cannot detect.

**After ANY revert, re-audit the body's symbol lists.** Better, and what finally worked here:
**derive them from the selfproc LEG A golden** rather than writing them by hand — the golden is
recut from the tree, so a reverted symbol disappears from it without anyone remembering to look.
This is the PR-body-has-no-reviewer lesson (previous section) with a mechanical fix attached.

## The typecheck-rearchitecture arc, 2026-08-10 — five merges, and every role defect was in a CITATION, a RELATION, or a POLL

#1491/#1494/#1495/#1498/#1501 merged; #1492/#1493 (S1), #1497 (S0), #1499 (S3), #1500 (S2) filed;
#1496 and #1502 left open. None of the four lessons below is about the compiler.

### ⭐⭐ A PRECISE citation is not a VERIFIED one — the precision is what buys the unearned trust

An agent cited "#1112 §1 row 7" as the authority for *"#1265 gates A-3.4."* That row says the
opposite, verbatim: **"DOES NOT GATE — belongs with B-2"** — and the same adjudication's
precondition list reads *"Explicitly NOT preconditions: … #1265 …"*. The section was real, the row
existed, the numbering was right; only the claim was invented. I relayed it to the repo owner as a
decision she needed to make **before opening it**, precisely BECAUSE `§1 row 7` reads like
something nobody writes unless they have read it.

**The check is to OPEN the citation, not to admire its specificity.** A vague citation gets checked
because it has to be. Retracted at #1112 `issuecomment-5237149420`, which needed four independent
lines of the record to undo one plausible sentence. Sibling of *"citation currency is what nothing
checks"* (2026-08-07/08) — that one is a citation that ROTTED; this one never held.

### ⭐⭐ An experiment about a RELATION between two things is not pinned by measuring ONE of them

The hypothesis was *"impl candidacy is prefix-scoped"*: whether a foreign same-spelled impl is a
candidate depends on its topological position **relative to the module where the goal is
elaborated**. Two agents independently built a fixture whose goal lived in `main`. `main` is always
topologically LAST, so no permutation of its imports can put the impl after the goal — both got a
**false null**, and both had correctly *proved their topological order*. Neither had stated **which
module elaborates the goal**, which is the other half of the relation. It cost three runs.

The settling run added a `midmod` holding the goal and permuted only two import lines in `main`,
moving the impl from before to after `midmod` while holding `midmod`'s import reachability constant
at none: the reject appeared and disappeared (#1482 `issuecomment-5237121185`, MEASURED at
`99780077`).

**When a hypothesis is "A relative to B", require the probe to REPORT BOTH A AND B** — not the
ordering it achieved. This is the discriminating-probe rule, but what failed to discriminate was
the fixture's SHAPE, not its assertion, so reading the assertion could not catch it.

### ⭐⭐ A completion poll must be unable to pass on a FAILED READ

An agent's merge-completion poll tested `mergedAt != "null"`. A transient empty API response
satisfied that test and it reported MERGED for a PR still sitting in the queue; it caught itself
only by re-reading state two ways. (RELAYED — the agent's own report, not re-run here.)

**Distinct from the stale-sentinel trap and from the two-call bounce above: those pass on the WRONG
data, this passes on the ABSENCE of data.** A completion predicate must be a POSITIVE match on the
value that means done — `mergedAt` parses as a timestamp, `state == "MERGED"`, the head SHA is an
ancestor of `origin/main` — never `!= <the sentinel you expect on failure>`, because every
*unforeseen* failure mode also `!=` it. Ask of any poll: *what does an empty response do to it?*
`scripts/pr.sh complete` already answers this (it proves the head SHA landed on `main`); prefer it
to a hand-rolled poll.

### ⭐⭐ Two agents can disagree because they ran DIFFERENT EXPERIMENTS, not because the answer is uncertain

One agent measured the order-sensitivity above; another could not reproduce it. The instinct is a
third opinion. What settled it was **running both constructions on ONE binary at ONE recorded
commit and publishing the datum neither had reported** — which module elaborates the goal. The
dissenter's null was then *explained* (its goal was in `main`) rather than outvoted, which is the
only outcome that also tells you what to build next.

Two details worth copying. A **third** agent reproduced the flip incidentally on the *same commit
as the dissenter*, which killed a tidy "the intervening merge (`fa9f7564`) changed it" story before
anyone spent a run on it. And the settling report states its commit, its build provenance and its
exit-code-reading method, so the next disagreement can be diffed against it instead of restarted.
**Tiebreak by making the two experiments identical, not by adding a voter.**

## Draining a pin, 2026-08-10/11 — a channel split is not a fixture verdict

### ⭐⭐ A drained fixture is not a drained class

PR #1520 (U1b) flipped issue #1438's `must_fail` pin green and its body proposed retiring
the issue. The pinned repro posed its goal through a **signature `=>` slot**, which
travels the exact channel U1b re-keyed. The minimal pair — same three modules, the
forwarder left **unsigned** so the goal is posed by a **bare method occurrence** instead
— was **identical on both arms**: `check` exit 0, `build` exit 0, **binary exit 139**.
Half the class was still alive and the proposal would have closed an open S0 with no
guard left in the tree.

**The check is cheap and belongs in any review of a fix that drains a pin: construct the
minimal pair that differs only in the mechanism the fix did not touch** — here, delete
one signature line and nothing else. Bookkeeping corollary from the same incident: name
the replacement fixture for **the unit that will drain the residual** (`1507-…`, after
#1507), not for the original issue — a fixture filed as `#1438` would sit unowned the
day #1507's fix lands, since #1507 is what actually closes it.

### ⭐⭐ A structural ruling does not license a fixture-level prediction

Same incident, my error. I derived a channel split from source — three bare obligation
producers, two closed by U1b, one owned by a sibling unit — and that half survived the
measurement unchanged. From it I *inferred* which unit issue #1438's own repro would
drain at, and wrote that inference into #1482's title and #1507's body **as a flat
statement**. One `check` run on the branch would have settled it before it shipped as
fact.

The verified structural half and the untested consequential half shipped in the same
sentence at the same confidence. **The sharpest part: this happened inside a correction
whose entire purpose was to stop an over-claim** — being in correction mode does not
immunise the correction itself from the same failure it exists to fix. Ask, every time a
derivation from source produces a claim about a SPECIFIC INSTANCE: has anyone actually
run that instance, or only the class it's alleged to belong to?

## The typecheck session, 2026-08-11 — ask whether the test COULD have failed, not whether it passes

### ⭐⭐ Every PR that entered adversarial review at 12/12 green came back with a real finding, and none was wrong code

Three PRs, four findings, zero wrong-code defects. The pattern across all four: a test that
looked like coverage was actually structurally unable to fail on the bug it claimed to guard.

- **#1526 round 1 — a gate that could not fail on the code it graded.**
  `origin_agreement_main`'s `single` probe arm **modelled** `test_cmd.mdk`'s id derivation
  instead of importing and calling it. Reverting the driver to its old buggy derivation left
  the gate fully green, because the gate was never reading the driver — it was reading its own
  copy of the driver's logic. The fix (export `singleRootId`, call it from the probe) was
  verified by the same swap-and-revert: revert the driver, gate goes red; restore, green. That
  swap-and-revert is what proves the probe is sensitive to the *driver*, not to its own model of
  it — a different property, and only the second one is a regression test.
- **#1527 — doctests that missed the field the ruling was about.** Six mutations run against
  29 doctests for `CE` construction; three passed clean (undetected): replacing **every
  method's raw `Ty`** — the entire subject of the Step-0 syntactic-vs-elaborated ruling this
  unit implements — with a bogus constant, garbling `superParams`/`superOrigin`, and deleting
  `classEnvFinish`'s row-order `reverseL`. All three were fixed and re-verified as positive
  controls (mutate → confirm red → restore → confirm 29/29 green) before merge.
- **#1526 round 2 — a vacuity tripwire disarmed by the pin meant to strengthen it.** The new
  `entry_residual` gate section shared the main loop's `fixtures` counter, so moving the whole
  `test/origin_fixtures/` corpus aside still exited 0 — the addition meant to catch a residual
  bug had silently defeated the check that catches an empty corpus. Fixed with a section-local
  guard, verified by moving the corpus aside and confirming exit 1 ("checked NOTHING").
- **#1526 round 2 — a live closing keyword in a commit message**, surviving after the PR body,
  the source fix, and the docs it touched all already said "does not close #1223." `gh` reads
  commit messages for closing keywords same as PR bodies (see the closing-keyword bullets
  above) — a sweep that stops at the visible prose misses the string GitHub actually parses.
  Fixed by squashing to one commit with no closing keyword anywhere.

**The actionable rule for a review brief:** don't ask the reviewer "does this test pass" — ask
them to **construct the wrong implementation and confirm the test notices**, and to **re-run
the tests that already passed as positive controls**, not just the new one. A green result is
otherwise indistinguishable from "the suite stopped running." And ask explicitly **which
fields no test observes** — an honest "unobserved, not asserted" recorded in the code (as
#1527's own doctest block did for one field) is fine; silence on it is not.

## Watching a long job, 2026-08-11/12 — two watcher patterns that report the WRONG thing

Neither is about the compiler. Both produced a confident wrong reading of *done*, and they
compound: the first supplies a premature "completed" notification, the second removes the
waiter that would have contradicted it.

### ⭐⭐ A background launch notifies you when the LAUNCHER exits, not when the JOB finishes

`nohup … &` — and `run_in_background` wrapped around any command that itself backgrounds its
real work — returns as soon as the **launcher** returns. Measured repeatedly this session: a
*"background command completed (exit 0)"* notification arrived **within seconds** while the
real work ran for another **~40 minutes**. An orchestrator that treats that notification as
the completion signal reads a half-finished sweep as final; an agent doing the same reported
a gate result from a build that had not yet promoted its binary (`test/build_native_medaka.sh`
writes `*.new.$$` and `mv`s into place, so the **binary's own appearance** is the completion
fact — not the launcher's exit code, which is about a process that is no longer doing the
work).

**`run_in_background: true` is correct only on a SINGLE command that itself runs to
completion** — no `&`, no `nohup`, no wrapper that spawns and returns. Then its exit *is* the
job's exit. This is the same rule the PID-poll bullet above reaches, from the other side.

### 🚨 `until ! pgrep -f <script>` NEVER EXITS — `pgrep -f` matches the WAITER's own command line

`-f` matches the full argv of every process, and the waiting shell's argv **contains the
pattern you are searching for**. The loop is therefore true forever with **no such job running
at all**. An agent lost three waiters to this in one session; the premature launcher
notifications above then looked like completed work, because nothing was left to disagree.
Derive it in two lines — neither job name exists anywhere on the box:

```sh
sh -c 'pgrep -f zzq_no_such_job;     echo "plain:     $?"'   # prints PIDs, exit 0 — it matched ITSELF
sh -c 'pgrep -f "[z]zq_no_such_job"; echo "bracketed: $?"'   # exit 1 — the regex cannot match its own literal
```

### ⭐⭐ The positive form: a predicate true ONLY on completion that CANNOT match the waiter

For "tell me when X finishes", write a condition on an **artifact**, not on a process:

- a **sentinel the job writes on exit** — `until [ -f /path/to/done ]; do sleep 5; done` — or
  the job's own output artifact, e.g. `until [ -x <worktree>/medaka ]; do sleep 5; done`
  (used successfully this session to wait out a cold bootstrap). Both are POSITIVE matches on
  the value that means done, which is exactly the rule the failed-read poll bullet above
  states; a process-absence test is the negative form and is what lets a self-match lie.
- if you genuinely need `pgrep`, **bracket the pattern** (above) or filter the waiter out.

**And when watching a MERGE QUEUE, watch `isInMergeQueue` + `mergeStateStatus` — NOT `state`.**
A **dequeued** PR stays `state: OPEN`, which is byte-identical to healthy waiting; measured
this session, a PR was bounced as `DIRTY`/`CONFLICTING` and a `state`-only watcher saw nothing
happen at all. Read all three together (`--json` does not expose `isInMergeQueue`; see the
merge-queue bullets in `AGENTS.md`):

```sh
gh api graphql -f query='{repository(owner:"MedakaLang",name:"medaka"){pullRequest(number:N){isInMergeQueue mergeStateStatus state}}}' \
  --jq '.data.repository.pullRequest'
```

⚠️ `mergeStateStatus` reads `UNKNOWN` on an already-merged PR, so it is a signal about a LIVE
PR only — don't build a completion test on it. For "did it land", `scripts/pr.sh complete`
(which proves the head SHA is on `main`) remains the answer.

---

## The deferred-verification sprint (Stage A, 2026-08-12/13) — what to keep, what to drop

A whole stage implemented on one branch with gate verification deliberately deferred to a
post-implementation adversarial round, then merged as PR #1601. It worked. The parts that
worked and the parts that cost are **separable**, and they got bundled at the time.

### ✅ KEEP: defer verification, but write the debt down

`DEBT.md` with a mandatory per-bite **`could move:`** field ("what acceptance behaviour could
plausibly have changed; *'nothing, and here is why'* is valid, silence is not") is what made the
repair round possible. Five reviewers got a real attack list instead of a diff to re-read. Cost:
essentially nothing. It found 2 S0 regressions, an architectural contradiction, and a
pre-existing S0.

### ❌ DROP: concurrent IMPLEMENTERS. **Parallelize readers, serialize writers.**

Four contaminated measurements in one run, **all** from agents holding uncommitted edits; zero
from late gates. The worst: a must-fail run reporting **5 phantom DRAINS** (zero on a quiescent
tree) — and the natural next action on a drain is to *close the issue*, so trusting it would have
put five wrongly-closed bugs in the tracker. Also ~4 bites of rework from a region collision and
one function built twice by two units briefed to build it.

Five adversarial reviewers ran concurrently with **zero** interference, because they do not edit.
Brief read-only agents *"do NOT rebuild the binary"* — a rebuild is the single action that breaks
quiescence for everyone. **No gate is measured while any agent holds uncommitted edits.** A drain
set is *stable*: run any drain claim **twice**; two runs disagreeing means the tree is moving.

⚠️ **State concurrency honestly in briefs.** I opened one with *"you are the ONLY agent live"*
and dispatched two more into that worktree minutes later. That agent checked instead of trusting
me, so its measurements survived. One that believed the sentence would have reported contaminated
baselines as clean.

### ⭐ THE HIGHEST-VALUE THING AN AGENT DID ALL RUN WAS REFUSE

Every one of these caught something no gate here can see, and none was asked for:
- an implementer **refused a bite** because the briefed site was unreachable (`publicDataDecl`
  has no `DAttrib` arm, so a `DAttrib` can never reach the function the bite patched) — three
  design passes had missed it, and the tree already said so in a fixture comment;
- an implementer **refused a brief instruction** ("every miss must fail loud") because that miss's
  loud form is a **false reject** — my brief had collapsed two opposite directions;
- two agents **STOPPED rather than adapting** onto a half-applied edit in a shared region;
- a reviewer **retracted its own finding** after noticing its probe grepped for the wrong keyword;
- a read-only agent **audited this orchestrator's ledger** and was right twice.

**Brief for refusal explicitly.** "Report disagreements rather than silently resolving them" and
"if your region changed under you, STOP — do not adapt" both paid for themselves repeatedly.

### 🎯 MAKE THE NEAREST-MISS TEST MANDATORY IN EVERY FIX BRIEF

> *State and TEST the nearest program your fix does NOT cover.*

The repair round exists because that question went unasked: a fix was verified against the
reproduction it was handed, and **the S0 survived one added type signature**. Once mandatory, it
found a live pre-existing S0 on the first try (#1599) and a retained false reject on the second.
A fix verified only against its own repro is verified against the **bug report**, not the defect.

### Two mechanical traps this run paid for

- **An `isolation: "worktree"` agent writes its report into a worktree nobody reads.** Copy the
  deliverable out the moment it returns, or it does not exist — the round's worst finding briefly
  survived only as a summary of a summary. Its `/var/tmp` probe corpora *do* survive, and were
  enough to reproduce the finding first-hand later.
- **Before calling a red "pre-existing", read the gate that produced it.** This tree's gates
  document which unit is licensed to flip them. One such red was reported as pre-existing by two
  agents, repeated by me in two commit messages and a PR body, and was in fact our own licensed
  deliverable — the header said so six lines above the assertion.

---

## Stage B (2026-08-13) — the orchestrator was the bottleneck, and it was MEASURABLE

Stage B landed as PR #1605 (`main` @ `1b5e740d`): three S0/S1s drained and closed with built-binary
evidence, one pre-existing defect filed (#1608), 12/12 required checks green. **The throughput lessons
below are worth more than the diff**, and every number here was derived from the `duration_ms` each
agent notification carries — not estimated.

### 🚨 THE HEADLINE: my serial verification was the bottleneck, at **0.73×**

| | agent-time | wall-clock | parallel efficiency |
|---|---|---|---|
| Phase 0 (six READ-ONLY agents, one batch) | 70.1 min | 15.9 min | **4.41×** |
| Implementation (serial writers) | 88.8 min | 121.8 min | **0.73× — BELOW 1.0** |

**33 of 122 implementation minutes ran with ZERO agents live** — all of it me verifying between bites.
Adding writers cannot fix that (they share `./medaka`; one build becomes another's baseline). **The fix
is to remove the dead time, not to add parallelism.** Baseline to beat next time: **1.48 landed
bites/hour**, implementers at **40–65% productive**.

**What actually moved it** (implementer productive share went 40% → ~70%):
1. **Commit on receipt → dispatch the next writer IMMEDIATELY → do ledger work while it runs.** Never
   finish → verify in silence → dispatch. I inverted this twice and Val caught the idle slot both times.
2. **Let implementers gate their own work.** They already run build/`check-self`/fixpoint. Re-running
   them is pure duplication; verify their *evidence* plus cheap checks needing no quiet tree
   (`git diff --numstat`, greps, `MEDAKA_STRICT=1`). **Run the fixpoint yourself once, at the exit.**
3. **Push and let CI absorb the heavy gates.** A draft PR gets `soundness` (compiler-source typecheck +
   fixpoint) on a hosted runner, free and parallel. ⚠️ It caught a `#1110` ratchet red that **no local
   gate can see** — on its first run.
4. **Overlap READ-ONLY agents pinned to a commit** (`git show <sha>:<path>`), which makes them immune to
   the live writer. Zero interference across ~10 such agents.

### ⭐ BRIEF QUALITY IS THE BINDING CONSTRAINT — not agent speed, not model tier

**Three bites were REFUSED, and every refusal caught a defect in MY scoping.** Two of those defects were
S0s that a faithful protocol-follower would have landed green. Also from my briefs: a self-contradictory
perf requirement (O(1) *and* an appending writer), a fix direction that was a **measured regression**
(32 false rejects), a citation I relayed twice that was scoped to the wrong constructor, an
`expected-red` prediction for a golden that **never moved** (which primed an implementer to hunt a
change that does not exist), a site count of "four" that was three, and **six wrong counts**.

⇒ **Spend orchestrator time on packets, not on re-verification.** And **use the strong model for
implementers**: the contract specified Sonnet; I used Opus throughout and the *refusals* are where the
value came from. Refusal requires disagreeing with the brief, which the bite protocol's site-list
framing actively discourages.

### 📊 The single cheapest instrument: TIME ACCOUNTING, scored against the ORCHESTRATOR

Make this a mandatory closing section in every brief:

> split (orientation · derivation · edits · build/gate · report) · biggest sink · **what did you have to
> DERIVE that I could have handed you?** · what of this brief was WASTED on you · build cycles + which
> were avoidable

⚠️ **Frame reading/thinking as PRODUCTIVE, never overhead** — say so explicitly, or agents will rush a
derivation to make a number look good. **Overhead is build churn and report-writing only.** And
**implementer derivation time is a readout of YOUR packet quality**, not their inefficiency.

Cost: **one retro accounting took 35 s and zero tool calls** (answered from transcript). It produced a
plan change, a new convention, and a brief-length cut. Findings it surfaced:
- *"Your brief was ~80% irrelevant"* → cut the amendment table; keep the **"already settled — do NOT
  re-derive" list**, which an implementer named as the thing that kept its bite short.
- *"Ledger prose was ~30% of my bite, more than the derivation that produced the verdict"* → **implementers
  write only their `DEBT.md` row; the orchestrator owns `DECISIONS.md`.** I was making them draft prose I
  then rewrote.
- *"The `engines:` four-arm ledger is 15 lines of 'untouched, and here is why' that one sentence covers"*
  → allow a one-line form when no compiled byte reaches an engine.
- **The biggest single waste of the run** was a mis-scoped sweep: an agent began a 1335-file corpus pass
  that would have taken **7 hours** (`compiler/**` files are whole-compiler compiles, ~3/min under load).
  **Put the cost model in the brief.**

### 🔁 PACKET-PREP: one bite ahead, never further

**Measured: design done phases ahead has a ~75% rework rate** — only **1 of 4** Phase 0 cuts survived
implementation unchanged, because implementation findings invalidate it. **Review has a structurally
ZERO rework rate** (it attacks landed work). ⇒ **Overlap review > overlap design**, and run a
~20-minute prep pass for the *next* bite only, during the current one.

A prep pass returned in ~6 min and **re-scoped the following bite before dispatch** by finding a source
block proving the planned scoping would reproduce a known bug class. Its highest-value instruction:
**"hunt the WHOLE-ANSWER fact"** — a committed comment (often carrying `MEASURED`/`#NNN`) that already
settles what the bite would otherwise investigate from scratch. One such find justifies the pass.

🚨 **When a prep pass asks a question only a BUILD can answer, run that build BEFORE dispatching.** I
failed this twice; **both became S0s.** The prep asked exactly the right question and I answered it by
reasoning. ⚠️ And **pin the prep to the commit the implementer will actually start from** — a packet
pinned pre-drain went stale and cost a wasted grep round.

### The rules that held all run (no amendment needed)

- **PARALLELIZE READERS, SERIALIZE WRITERS.** Zero contaminated measurements, zero region collisions —
  the Stage A failure mode did not recur.
- **A REFUSED BITE IS LANDED WORK.** One cost 33 min and produced no diff while preventing an S0 that
  would have shipped behind a green `check`. **Any metric scoring it zero optimises the run toward
  silent wrongness.**
- **Brief for refusal explicitly**, and say *"stopping with a written finding is worth more than a green
  gate."* Sixteen briefs were corrected this way.
- **State concurrency honestly**, including "four other agents are live."
- **Relay findings between agents MID-FLIGHT.** I sat on a reviewer's finding and the next implementer
  discovered it by running `git log` after the tree moved under it. Its words: *"that deserved a message."*

### Traps this run paid for

- 🚨 **The layered check is what works.** A reviewer audited my prose and found I had **invented a red
  that never existed** — a gate leg I described as permanently failing is a *pass* leg, green at BASE,
  copied forward without derivation. **That would have pre-authorised a reader to ignore a real red in
  the primary oracle.** Then a second agent **refuted that reviewer's most alarming finding** ("three
  artefacts lost" — it had resolved a path worktree-relative when the scratchpad is session-scoped). **I
  had already amplified the false claim to the user.** Audit the auditors.
- **Read-only reviewers' programs are UNRUN BY CONSTRUCTION.** **Three of six needed repair** before they
  could grade anything. That is the predictable cost of forbidding them to build — budget for it, or give
  a short smoke-test window.
- 🚨 **`gh pr edit` SILENTLY NO-OP'd** (Projects-classic deprecation), leaving a title saying "DRAFT" and
  a body saying **"Do not enqueue"** on a PR being readied for merge. **`scripts/pr.sh body --number N
  --file F` byte-verifies the readback**; the title needed `gh api -X PATCH`. **Read state back; never
  trust a write's exit code** — same for `--auto --merge`, where `isInMergeQueue` via GraphQL is the only
  signal.
- **Backticks in an inline `git commit -m` execute as shell** — blanked an identifier **twice** in one
  session. Commit from a **file**.
- **A HEARTBEAT is right while work is in flight and wrong after.** Every-20-min checks caught **two idle
  slots and one empty queue**; then five consecutive no-ops against a finished sprint. **Stop it when the
  queue is legitimately empty** rather than manufacturing work to satisfy it.
## The two-sprint AUDIT (2026-08-13) — the model holds; here is what the audit adds

The section above is the Stage B run's own retrospective (throughput, briefs, packet-prep).
This one records the *independent audit* of both sprints — headline claims, merge-queue runs,
tracker state, and spec conformance, each verified against the tree rather than the sprint's
prose. Verdict: **keep the sprint model.** No fabrications, no post-merge regressions attributed
to either sprint, no contradictions with standing spec rulings. The audit record: memory
`project_sprint_audit_verdict_20260813`, plus #1610 and the closes of #991/#1114/#1317.

### 🚨 The repair round is LOAD-BEARING, not a contingency — never cut it for schedule

Both sprints introduced S0/S1s mid-run. Every one was caught by the sprint's own adversarial
repair round **before merge**, and **zero were caught by gates** — Stage B's worst (a loud
compile-time refusal turned into an exit-0 build of a crashing binary; IR order-divergence 589
lines) was green on every check that ran. A sprint that lands without its repair round has not
gone faster; it has moved the catch to `main`.

### Template deltas for the next sprint, each earned by a measured miss

- **A `DEBT.md` row is owed for any behavior delta a differential DETECTS, not only ones the
  implementer recognizes.** Stage B landed one real acceptance regression (correct under DICT
  C3/C4, order-invariant — the intended direction) with **no row anywhere**; the repair round's
  base-vs-branch differential is what found it. Close the loop: any base-vs-branch delta outside
  the enumerated widening set gets a row *at detection time*, written by the round that found it.
- **A probe that decides a merge blocker must be durable.** FX-1's 589→0 order-invariance
  measurement — the evidence that closed the sprint's S1 — lives in prose plus session scratch;
  only the behavioral property survived into a gate. If a probe's verdict gates the merge, land
  the probe: fixture, gate, or committed script. A number nobody can re-run is a claim, not a
  record.
- **Desk closes are an EXIT CRITERION.** Phase 0 verified #991 and #1114 already-done; the closes
  were deferred to the repair round and never executed, so the tracker lagged the tree for the
  exact items the sprint had already derived. "Every verified desk close executed or handed to a
  named owner" joins §8, at the cost of minutes.
- **PR title severity must match the body's own table** (Stage B's said "three S0s"; its table
  correctly said one was an S1). The title is the one line every future reader quotes unchecked.
- **Sprint record directories must not collide.** `.claude/sprint/` (Stage A) and
  `.claude/sprint-b/` (Stage B) hold identically-named DECISIONS.md/DEBT.md, and the Stage B run
  doc's banner points at the wrong one for a Stage A reader. Name future runs
  `.claude/sprint-<stage>/` from the start and never reuse a bare `sprint/`.

### Residuals the audit routed, so nobody re-derives them

Fourth-engine gate blindness → **#1608** (filed by the sprint, covers it fully). Untriaged
nightly `perf_scaling DEEP` red (xref lint-stage time-superlinear, DEEP-only band) → **#1610**,
with #1006 owning the went-unnoticed half. Phase 3′'s tripwire (identity-in-routes falsifies the
copied super-slot route premise) → `.claude/sprint-b/repair/R3-c4i2.md` P4, already queued in
`.claude/sprint-b/next/`.

## Stage B / Phase 3′ (2026-08-14) — the sprint where every bite was re-cut by someone who refused it

PR #1616. Four bites landed, one dropped, one S0 drained. **The headline is not the diff: it is that
the design of record was wrong about FOUR of its six bites, and each error was caught by the agent
handed it rather than by any gate.**

| bite | what the design said | what was true |
|---|---|---|
| `a` | change `RKey`'s payload to a two-component carrier | **no type change at all** — all 15 reading sites need the word; none can consume an identity |
| `f` | add a per-slot declared/appended flag to `CSlot` | **no field** — a third mint site holds `List Int` and constructs no `CSlot`, so a flag serves 2 of 3 |
| `b1` | stamp identity at the four `inst` arms | **two lines, zero arm edits** — selection and the collision gate were already inside `keyForSite*` |
| `b2` | collapse a pair that is "provably one selection" | **dropped** — that pair is not one selection at this pin |

⇒ **Design-ahead's ~75% rework rate reproduced almost exactly.** The countermeasure that worked was
not better design; it was **briefing for refusal and then believing the refusal.**

### ⭐⭐ AN ENUMERATION CLAIM MUST STATE ITS DEPTH

Twice this sprint a *"verified by enumerating every X"* claim turned out to have stopped at the first
level instead of following to the leaves:

- *"every selector call site enumerated"* → stopped at `entailFallback`'s own body. The property I
  then asked an implementer to inscribe was **FALSE**, and it refused to write it — into the one bite
  whose whole purpose is leaving behind sentences the next refactor cannot violate.
- *"the 15 reading sites"* → three mentions, **zero enumerations**, in anything that ships with the PR.

**"I enumerated the call sites" and "I followed each to its leaves" are different claims.** Say which.

### ⭐⭐ A SOURCE-LEVEL ASYMMETRY IS NOT A DEFECT UNTIL BOTH SIDES ANSWER DIFFERENTLY ON A PROGRAM

I wrote *"audit the arms as a SET"* about a wildcard, twice shipped a set one arm short, then
**over-corrected** and asserted a third defect from a source asymmetry without measuring it. Measured:
it is **not** a defect — stripping a constraint yields a still-headless type, so both sides agree.
The two real ones disagree (one side says a concrete head, the other headless). Same
claim-past-its-evidence move, opposite direction.

### 📊 PARALLELIZE READERS *AGAINST A LIVE WRITER* — pinned readers cost nothing

Stage B measured implementation at **0.73×** parallel efficiency, a third of wall-clock with zero
agents live. This run reproduced that until it was corrected mid-sprint: **readers pinned to
committed SHAs (`git show <sha>:<path>`) are immune to a live writer**, and ran with zero
interference throughout. What filled the slots productively:

- adversarial review of a **landed** bite while the next one is being written;
- a **referee audit of the orchestrator's own prose** — which found nine wrong issue attributions and
  **zero in-place supersede markers**, in a ledger whose own text says an unmarked superseded ruling
  *"is how a ledger starts lying"*;
- **measurements on a separately-built base arm**, which a trunk writer cannot contaminate;
- building the repair round's instrument **before** it was needed.

### ⭐⭐ PUSH A DRAFT PR EARLY — it caught two reds the whole local suite missed

The sprint ran the fixpoint, the full snapshot suite, dict-semantics, engines, eval-modules, LLVM
typed IR and must-fail twice. **Neither CI red appeared in any of them:** a doc-symbol citation this
sprint's own deletion rotted (`soundness`, failing in 13s), and the sprint's own repro harness
tripping the *"gate that silently never runs"* check from **outside `test/`**. Both were ours; both
were invisible locally.

### Traps this run paid for

- **Blanket `git add <dir>` while an agent is writing into that dir** sweeps a half-finished file into
  an unrelated commit. Stage sprint records **by path** while any agent has the directory open.
- **A probe that fails IDENTICALLY on both arms carries no signal.** My first two-arm probe used
  exports the module does not have; "identical" was one glance away from being read as agreement.
- **My coarse greps produced three false alarms** (a count that was comments, diff lines that were
  comments, "surviving" occurrences that were trailing side-comments). Each time inspecting rather
  than trusting resolved it — the lesson is not "grep better", it is *never conclude from a count you
  have not eyeballed*.
- **`--bless`/`--new` are not symmetric.** `--new` is **suite-wide**, never overwrites, and reports
  *"0 compared, 201 skipped: NOTHING COMPARED (this is not a pass)"*. The **re-check afterwards** is
  what makes it a pass.
