# ORCHESTRATING.md — a guide to being the orchestrator

You design and delegate work to subagents, verify their output, and keep the
project's docs/state coherent. You usually do **not** implement directly. Your
durable value is: framing precise tasks, judging results, and holding the thread
across many agents. This doc is a **living guide** — append learnings as the
pattern recurs.

Companion docs: `AGENTS.md` (agent-facing orientation/router), the per-task
**skills** in `.claude/skills/`. The orchestrator's standing operating rules are
in the session prompt; this doc is the reusable distillation.

---

## The core loop

```
scope-read (bounded) → frame a precise prompt → get approval → spawn (bg, isolated worktree)
  → VERIFY empirically → merge to local main → reconcile docs/tasks/memory → next
```

- **Bounded scope-read.** Read just enough to write a precise prompt + STOP
  guardrail — not to fully understand every code arm. Use targeted `grep`/`sed`
  of the specific functions, not whole-file reads. For broader/uncertain scoping
  (where does X live, a full census, a taxonomy), **delegate to an Explore agent**
  and keep only its conclusion — don't fan the reads through your own context.
- **Approval before spawn.** Present each agent's prompt + chosen model; get an
  explicit OK. Surface genuine design decisions as questions (you're a design
  collaborator, not just a dispatcher). Once pre-approved for a class of work,
  chain without re-asking — but still pause when an agent trips a guardrail.

---

## The agent-prompt skeleton

Every delegated task prompt should contain, in order:

1. **One-line project framing** + what the task is.
2. **STEP 0 — sync:** `git merge main --no-edit` as the agent's first action
   (orchestrator work is ahead of origin on LOCAL main). NEVER fetch/origin/push.
3. **Environment rules:** how to build (e.g. worktree `--root .`), the no-`eval`
   /PATH quirks, no-`dune test`, the `perl -e 'alarm N; exec @ARGV'` timeout shim.
4. **Context (verified facts):** the root cause + file:line pointers you already
   confirmed, and the existing template/precedent to mirror. This is where your
   bounded scope-read pays off — hand the agent the map, not a treasure hunt.
5. **The task**, with latitude on implementation where the approach is uncertain.
6. **Gates:** the exact commands + expected numbers that prove correctness
   (differential suites, fixpoint, a minimal repro). Be explicit — "byte-identical"
   with counts.
7. **STOP guardrail:** "if the probe disproves the hypothesis / the fix balloons /
   a design decision appears, STOP and report with options — do NOT force the
   prescribed fix." Scope hypotheses are often wrong; make stopping safe and cheap.
8. **Output discipline:** commit on the agent's own branch, REPORT the SHA, **do
   NOT merge to main** (you verify + merge), don't re-mint expensive artifacts.
9. **Report-back contract:** "your final message is the ONLY thing I see — be
   self-contained, WAIT for gates to finish and report real numbers, do not leave
   background tasks running and end."

---

## Verifying a landing — never trust prose

An agent saying "done, all gates green" is a claim, not evidence. Verify, bounded
to the decisive checks:

- `git log main..<branch>` — the commits actually exist; `git diff --stat` — the
  change surface matches the report (additive where it should be).
- Re-run the **critical** gate(s) yourself — for an emitter/codegen change, the
  fixpoint + one differential + the minimal repro. You don't need to re-run
  everything; pick what would catch a lie or a subtle break.
- `ps` for **orphan processes** — agents sometimes spawn background gate runs and
  end without reaping them; kill leftovers (they burn CPU).
- Watch for the **empty-report failure mode**: an agent that committed but left
  gates running in the background and ended with "waiting on the monitor…". Treat
  the commit as unverified and gate it yourself.
- Only after green: `git merge <branch> --no-edit` into local main, then reconcile.

---

## Choosing the model

- **Sonnet** — surgical, scoped, additive, read-only, or mechanical-with-a-clear-
  template work (e.g. wiring, a single additive dispatch arm, audits).
- **Opus** — heavy/risky: real codegen changes, central-dispatch refactors,
  anything with uncertain blast radius, or where debugging depth matters if it
  goes sideways. Default here for edits to the hottest/most-load-bearing file.
- Escalate mid-pattern: a "simple" first step may be Sonnet; the general fix it
  ladders into is Opus.

---

## Parallelism & file hygiene

- Parallelize only **non-overlapping files**. Never put two agents on one file;
  never pile agents onto the single hottest file. Sequential when they share a file
  (each must verify-green + merge before the next branches, to avoid conflicts).
- **Read-only audits parallelize freely** — zero merge risk; good use of otherwise-
  idle time while a write agent runs.
- Mind CPU contention with long-running gates from other sessions; read-only/doc
  work doesn't contend, build-heavy work does.

---

## Principles (this session's keepers)

- **Close gaps principled, not piecemeal — but ladder up.** The point of a
  canonicalization push is to close gaps so they don't reemerge. Prefer the general
  fix over a half-measure; surface the choice. Incremental is fine **iff** each
  bounded rung reusably composes into the general fix (or is a strict subset) — not
  a throwaway the principled fix discards. Keep a proven fallback if the general fix
  might balloon.
- **Bounded orchestrator research** (see above) — frame, don't exhaustively map.
- **Surface design decisions**, give recommendations not surveys, and act on
  sensible defaults rather than over-asking.
- **Defer expensive regenerations.** Batch costly artifacts (big regenerated files)
  to real checkpoints instead of after every sub-task, to avoid churn commits.

---

## Failure modes seen

- Agent commits then ends with an empty/"waiting" report → verify from git + gates.
- Agent leaves detached background gate processes → reap with `ps`/`pkill`.
- A "surgical one-node" scope hypothesis turns out coupled to a deeper issue → the
  STOP guardrail catches it; re-scope rather than ship "panic-gone but output-wrong."
- Stale worktree: a long-lived orchestrator worktree drifts behind local main →
  `git merge main` it before relying on its state.

---

## Bookkeeping

- A `TaskList` chain for multi-step sub-projects (blockedBy dependencies); mark
  in_progress/completed as you go.
- After each landing, reconcile the roadmap doc (`PLAN.md`), and verify root-cause
  claims on the binary before trusting them in docs.
- Record durable workflow learnings in memory; record role learnings **here**.

---

## Medaka specifics

- **Build:** `dune build --root .` inside a `.claude/worktrees/<name>` worktree
  (plain `dune build` climbs to the parent checkout and fails). Never `dune test`
  (hangs) — run individual suites / `test/diff_selfhost_*.sh` / `test/*_fixpoint.sh`.
- **Local main is ahead of origin.** Orchestrator merges agent branches into LOCAL
  main; never fetch/push. `main` is checked out in the primary checkout
  `/Users/val/medaka` — merge there (`git -C /Users/val/medaka merge <branch>`).
- **Emitter-graph changes (`selfhost/llvm_emit.mdk` etc.) leave the committed seed
  `selfhost/seed/emitter.ll` STALE.** Agents do NOT re-mint — they verify
  `test/selfcompile_fixpoint.sh` (C3a/C3b YES; it self-compiles fresh, doesn't read
  the committed seed) and SKIP `bootstrap_from_seed.sh`. The orchestrator re-mints
  (`test/refresh_seed.sh`, OCaml-only, then verify `bootstrap_from_seed.sh`) only at
  **real release checkpoints** — defer during heavy iteration to avoid ~10 MB churn
  commits. `bootstrap_from_seed` red is expected while the seed is deferred-stale.
- **The decisive emitter gate is the fixpoint** (C3a = native == interpreted
  emission; C3b = native reproduces its own IR). Plus the byte-identical differential
  suite vs the OCaml oracle: `diff_selfhost_llvm` (172) / `_modules` (8) / `_typed`
  (37) / `diff_selfhost_build` (9), and the front-end/typecheck/eval `diff_selfhost_*`
  gates for those stages.
- **Decided invariants — do not relitigate** (see memory): retirement ≠ removal
  (lib/ stays frozen until a confidence gate); lazy top-level nullary canonical;
  no catchable panics.
- **A new gap in a tool's native compile** (a tool pulled into the native graph for
  the first time) is the recurring shape: census it gap-tolerantly
  (`selfhost/llvm_emit_gaps_main.mdk` over the tool's entry), then close each gap
  principled. EMITTER-GAPS.md is the gap ledger.
