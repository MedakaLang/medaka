# Stage B sprint — run doc

**Status:** planning artifact for a single long-running orchestration session.
**Premise:** implement Stage B's selection discipline on one branch, in one worktree, with
golden/differential verification deferred to a repair round that runs *after* implementation —
**but with the self-compile fixpoint and the seed re-mint kept IN the run, because this stage
changes emitted IR and those two cannot be deferred safely.**
**This document is the contract.** Every agent in the fleet reads it before acting.

> ⚠️ **This run trades verification latency for implementation throughput. That trade is only
> safe because the debt is WRITTEN DOWN.** An agent that skips a `DEBT.md` row has not saved
> time — it has converted a deferred check into a check nobody will ever know to make.

> 🚨 **Stage A ran this experiment and it came back with a split verdict. Read
> `.claude/ORCHESTRATING.md`'s closing section — "The deferred-verification sprint (Stage A)" —
> before Phase 0.** Its one-line summary: **KEEP the deferred verification with a written
> `could move:` ledger. DROP the concurrent implementers.** §3 and §5 below are rewritten
> around that, and the rewrite is the single largest difference from the Stage A doc.

---

## 1. Scope

Derived 2026-08-13 against the tracker, the epic's 2026-08-09 spine amendment, the design doc,
**and the Stage A sprint's own ledgers** — which are ahead of the tracker on several nodes.
Re-derive before starting; the tracker lags the tree in this arc, consistently and by several
units.

### The scope ruling: **B-3 + B-2. B-1 is OUT.**

Stage B is three units — B-1 (#993 evidence tree + `entailSuper`), B-2 (#1113 identity-stamped
evidence), B-3 (#991/#994 obligation storage). The sprint takes **B-3 and B-2, not B-1.**

**Why B-2 must be the spine of this run.** Stage A ended with a measured verdict, not a guess:
`DECISIONS.md` RUN-045 — *"🔴 NEEDS-B-2. C4/I2 does NOT survive."* A-3 globalized `IE`, but the
**evidence reader still consults a cumulative registry**, so import order stopped deciding
acceptance and started deciding *emitted evidence*, "where nothing observes it." Stage A closed
that by rejecting loudly (`T-REQUIRES-UNROUTED`), which was correct and is not a fix. **B-2 is
the fix**, and the arc's headline claim is blocked on it.

**Why B-1 is out, stated so it can be overturned.** Three independent reasons:
1. **Its scope is undecided by design.** The doc (§6 B-1) says its own design doc must rule
   whether the evidence tree extends to recursive instance-context capture at nesting depth ≥2
   (what #323 needs) or stays supers-scoped as filed. **An unresolved scope question is a design
   run, not a sprint** — this template requires pre-cut, mechanical bites.
2. **It is dependency-independent.** Epic #1122, 2026-08-09, on what the amendment did *not*
   change: *"B-1 ∥ C ∥ D (no new 2026-08-09 evidence touches them)."* Nothing in B-2 waits on it.
3. **It would make the repair round unable to attribute.** B-1 rewrites evidence
   *representation* (`Value` rep in eval, `Route`, both emitters, dict-arity readers); B-2
   rewrites evidence *identity* over the same organs. Landing both on one branch with deferred
   goldens reproduces exactly the failure the design doc names at F-3: *"bundling them makes CI
   unable to say which half moved a golden."*

⚠️ **The one place B-1 reaches into B-2, which Phase 0 must rule on:** B-2's route triple is
`InstId | DictParam k | SupersPath`, and **`SupersPath` is B-1's projection.** Today supers are
flattened into sibling dict slots, so there is no path to reference. Phase 0 decides between
(a) B-2 ships a two-constructor route and identity-stamps the existing flattened supers slots,
`SupersPath` deferred to B-1 by name; or (b) B-1's projection is absorbed as a B-2 precursor
unit. **(a) is the presumption.** Whichever is chosen, it is written down as a scope statement,
not left implicit — an unstated (a) reads to a later agent as an unfinished (b).

### In scope

| Phase unit | Nodes | Notes |
|---|---|---|
| B-3 prelude | #991, #994 | Byte-identical bar, single-PR sized, independent. Shrinks the obligation-storage surface B-2 then edits |
| B-3-ext closure | #1114 | **Already LANDED** (design doc line 749: DICT §4.2 D1–D6 + §11 rows; #845/#792 both CLOSED). The issue is open. Verify and close — a Phase 0 desk item, not implementation |
| B-2.1 evidence reader | #1113 (part) | Repoint `concreteReqMatchByIface`/`findMatchingImplReqsU` off `shadowKeyTableRef` onto `IE`; **retire `universeKeyBucketsRef`/`KeyBuckets`/`keyForSite*` by DELETION** (T1, #1317). The S0 drain |
| B-2.2 routes | #1113 (part) | Evidence references in `Route`; identity stamped where `inst` runs; min-specificity only at `inst` |
| B-2.3 admissibility | #1113 (part) | Per-(class, position) arg-tag admissibility computed **once post-K from global IE, frozen into the elaboration output as data** |
| B-2.4 engines | #1113 (part), **#1068** | LLVM `implEntryRouteWords` superset-OR retirement + `noneHeadTag` catch-all re-key + disjoint default-tag namespace; wasm peer arm; `eval.mdk` mirrored dispatch; `Route`/`core_ir_lower` |
| Historical close | #1317 | Retires here by deletion. Close it when B-2.1 lands |

**Drain list (the run implements these; it does not close them — see below):** #1564, #1599,
#1560, #1072, #1071, #1062, #1068, #1182.
⚠️ **#1071, #1068 and #1075 have no must-fail pin.** Filing owes a fixture; three of this run's
own drain targets are unguarded. **Pinning them is a Phase 0 deliverable** — a drain claim
against an unpinned issue is unfalsifiable, and the pin must be observed RED before the fix.

### Out of scope (ruled 2026-08-13)

- **B-1 (#993)** and its riders **#679**, **#741**, **#323** — see the ruling above.
- **#1046 / #1075** — the design doc routes both to **F-1**: their sites reach dispatch through
  a local lambda, so arg-tag survives there until locals carry evidence. A B-2 that "drains"
  them has done something out of scope.
- **#1265 / #1276 / #1386 / #1351** — the **method-namespace** lane (#1354 M-2), deferred out of
  Stage A by RUN-024. Different axis. ⚠️ #1265 is genuinely ambiguous — the doc files the
  default-arm registry as *"NOT `IE`, BY CONSTRAINT (§9.3) — B-2 / #1265"* — so **Phase 0
  adjudicates it explicitly** rather than letting an implementer decide by proximity.
- **#1597** (field-owner candidate set is a raw topological prefix) — Stage A's Unit F, whose
  F-3 bite was **refused as unreachable dead code** (RUN-031). It is `DataEnv`/record territory,
  not evidence. **Phase 0 adjudicates in-or-out; the presumption is out.**
- **#1034, #826, #1101, #1020** — engine-realization exclusions. The capture ban holds until the
  *engine* fix lands; architecture cannot drain them and a run that claims otherwise is wrong.
- **#1137, #1318** — no stage owner; proposals pending adjudication.
- Everything in Stages C, D, E, F.

### Issue-closure policy

**The run implements S0/S1-draining work. It does not close it.** The drain list stays open
through the sprint. Must-fail pins flipping red as fixes land is a *deliverable*, not a break,
and it is the repair round's attack list. Closure requires the adversarial review gate every
soundness fix in this repo gets, which happens after.

⚠️ **A drain reading is only valid on a quiescent tree.** Stage A's must-fail run reported **5
phantom DRAINS** where a quiescent tree had zero, taken while agents held uncommitted edits. The
next action on a drain is *close the issue*, so a phantom would have put five wrongly-closed
bugs in the tracker. **Run any drain claim twice; two runs disagreeing means the tree is moving.**

---

## 2. Phases

Each phase gate is a hard stop. No phase starts before its predecessor's deliverable exists.

### Phase 0 — design fan-out (parallel, read-only)

The critical path. ~4 Opus arch agents plus one Fable consult, all read-only, so zero merge risk.
This is the only genuinely parallel *work* in the sprint.

Deliverables, all into `.claude/sprint-b/DECISIONS.md`:

- **Bite-level decomposition for B-2.1 … B-2.4 and for B-3** (§4 defines a bite).
- **The `SupersPath` ruling** (§1). Presumption (a).
- **The three adjudications:** #1265 in-or-out · #1597 in-or-out · #1114 verify-and-close.
- **The declaration-index defect.** `bucketKeyEntriesFrom`'s own comment
  (`compiler/types/typecheck.mdk`, grep `per-module declaration-index numbering is UNCHANGED`)
  records that indices **duplicate across modules** within one bucket, violating
  `mergeByDeclIdx`'s ascending precondition — explicitly *"not this unit's change"* at A-2.2b.
  B-2.1 deletes that table. **Rule where the property goes**: does the `IE`-backed replacement
  inherit the defect, fix it, or is the tie-break specified away? Silence here ships a
  reintroduction.
- **The three unpinned drains** (#1071, #1068, #1075): fixtures authored, observed RED.
- **Fable's single question:** does this cut deliver **C4/I2 by construction** — the conjunction,
  *"consult the same instance set AND produce the same evidence"* — or does it deliver conjunct 2
  and leave a third gap the way A-3 left this one? This is the one broad, formal-semantics-scale
  question in the run and the only thing Fable is spent on. **It is the same question that came
  back NEEDS-B-2 last time; ask it before implementing, not after.**

**Gate:** every in-scope unit has a written bite list, or it is deferred out of the sprint.

### Phase 1 — B-3 (#991, #994)

Byte-identical bar. The run's calibration unit: it exercises the whole protocol on work where a
mistake is mechanically visible, before the fleet touches selection semantics.

### Phase 2 — B-2.1, the evidence reader

Repoint the reader at `IE`; delete `KeyBuckets` and its family. **This is where the Stage A
residue drains.** Verified entry points, current tree:
`concreteReqMatchByIface` ← `findMatchingImplReqsU` (`typecheck.mdk:21696-21698`) reading
`shadowKeyTableRef`, which the Module arm copies wholesale from `universeKeyBucketsRef`
(`:20347-20348`).

⚠️ **`implExistsForHead ... shadowKeyTableRef` has readers on the shadow-dispatch path —
`inferShadowApp` (`:11203`, reader at `:11216`) and `definerReceiverDispatches` (`:11498`, reader
at `:11503`) — that are SHADOW-semantics (#616), not evidence.** RUN-045 named this as the
reason door 1 was closed to Stage A: touching the table reaches a second spec. **Those readers
move or are re-based deliberately, with the SHADOW spec cited — never incidentally.**

### 🛑 STOP-AND-LAND GATE (after Phase 2)

**A real decision point, not a formality.** Phase 2 alone drains several S0/S1s and is a
coherent, landable PR. Before Phase 3 the run answers, in writing: *is the tree stable, is the
fixpoint green, and is the remaining bite list still believed?* If any answer is no, **land
Phases 1–2 and re-plan.** Stage A's equivalent moment was RUN-044/045, where continuing past a
half-landed widening produced a compile-time rejection that became a segfault.

### Phase 3 — B-2.2, evidence references in routes

`Route` carries `InstId | DictParam k` (+ `SupersPath` per the Phase 0 ruling). Identity stamped
wherever `inst` runs. **Precision matters and the loose form is itself an S0:** an
`assum`-discharged goal or a `super`-discharged goal has NO selected instance; re-resolving an
in-scope rigid goal through `inst` rebuilds general evidence where the construction site's dict
must be forwarded (#203's class, DICT §3 precedence).

### Phase 4 — B-2.3, frozen admissibility

Computed once post-K from global `IE`, frozen into the elaboration output **as data**, consumed —
never re-derived — by every engine. **At DICT §5's actual condition:** per (class, argument
position), every reachable constructor uniquely determines the min-specificity winner for every
goal reaching the site, and the argument must be evaluated. ⚠️ **Not "no overlap below the
head"** — that paraphrase licenses an S0 with zero overlap (`impl C (T Int)` / `impl C (T Bool)`
do not overlap and the tag `T` determines nothing).

### Phase 5 — B-2.4, the three engines

LLVM + wasm + `eval` word-set retirement, `Route`/`core_ir_lower`. **#1068 lands HERE, with it** —
the design doc's coordination note is explicit that #1068's filed fix direction would *build in
wasm the superset arm this task deletes*. Sequential is the wrong answer.

### Between every unit — the integration checkpoint

Backgrounded `sh test/preflight.sh` plus `sh test/selfcompile_fixpoint.sh`. Bounds bisect blast
radius to one unit. Run detached and poll — preflight forces the fixpoint on backend-adjacent
diffs and can exceed the 10-minute foreground ceiling; a kill at 600s with exit 143 is the
ceiling, not a hang.

---

## 3. Agent architecture

> ### 🚨 THE CHANGE FROM STAGE A: **PARALLELIZE READERS, SERIALIZE WRITERS.**
> Stage A ran 3–5 concurrent implementers and paid for it: **four contaminated measurements, all
> from agents holding uncommitted edits, zero from late gates**; ~4 bites of rework from a region
> collision; one function built twice by two units. Its five concurrent adversarial *reviewers*
> interfered with nothing, because they do not edit. **Throughput in this run comes from
> read-only fan-out and batched builds, not from concurrent writers.** This is slower on paper
> and it is the ruling.

| Role | Model | Count | Charter |
|---|---|---|---|
| Run orchestrator | Opus | 1 | Owns the trunk worktree, the phase gates, the checkpoints, and the **quiescence protocol** (§5) |
| Unit sub-orchestrator | Opus | 1 live at a time | Owns one unit. Cuts bites, dispatches the implementer, commits, batch-builds |
| Architecture companion | Opus | 1 per live sub-orchestrator | Answers what would otherwise pull the sub-orchestrator off coordination. Writes every ruling to `DECISIONS.md` |
| **Implementer** | Sonnet | **1 live at a time** | Executes one bite. See §4 |
| Read-only analyst / reviewer | Sonnet or Opus | 2–4 concurrent | Probes, differentials, ledger audits, corpus derivation. **Briefed: do NOT rebuild the binary** — a rebuild is the one action that breaks quiescence for everyone |
| Referee | Sonnet | 1 | See §6 |
| Fable consult | Fable | 1, Phase 0 only | The C4/I2 question. Nothing else |

⚠️ **State concurrency honestly in briefs.** Stage A's orchestrator opened one brief with *"you
are the ONLY agent live"* and dispatched two more into that worktree minutes later. That agent
checked instead of trusting it, so its measurements survived. One that believed the sentence
would have reported contaminated baselines as clean.

---

## 4. The bite protocol

**A bite is a transformation over named sites.** If it cannot be stated as *"apply this
transformation to these N named sites"*, it is not a bite: it goes back to the architecture
companion to be cut further, or the sub-orchestrator does it. This test is the whole reason
Sonnet can be trusted inside a 27k-line `typecheck.mdk`.

An implementer's deliverable is **the edit plus a `DEBT.md` row**:

```
### <bite id> — <unit> — <one-line description>
sites:      <the files:lines actually touched>
transform:  <what was applied>
could move: <what acceptance behavior could plausibly have changed, incl. "nothing — pure rename">
nearest miss: <the nearest program this does NOT cover, and what it does today>
engines:    <LLVM / wasm / eval — which arms this bite moved, and which peers it owes>
unchecked:  <what I did not verify, and why>
```

**`could move:` and `nearest miss:` may not be left blank.** "Nothing, and here is why" is valid;
silence is not.

- **`could move:`** is what the repair round reads. It cost nothing in Stage A and produced the
  attack list that found 2 S0 regressions, an architectural contradiction, and a pre-existing S0.
- **`nearest miss:`** is new and mandatory. *State and TEST the nearest program your fix does NOT
  cover.* Stage A's repair round exists because that went unasked and **an S0 survived one added
  type signature**. Once mandatory it found a live S0 on the first try (#1599). A fix verified
  only against its own repro is verified against the **bug report**, not the defect.
- **`engines:`** is new and specific to this stage. B-2 moves dispatch in three engines. A bite
  that lands the LLVM arm without naming its wasm and eval peers has created a divergence that
  `diff_compiler_engines` — deferred to the repair round — will not see until then.

### Region discipline

All implementers work **in the trunk worktree**, on disjoint named regions. No per-implementer
worktrees, no merging, no divergent history — a conflict cannot arise. Worst case is an edit
failing to match, which is loud and retriable.

🚨 **An implementer whose region has already changed under it STOPS and reports. It does not
adapt.** Two Stage A agents did exactly this and were right both times.

🚨 **Brief for refusal, explicitly.** The highest-value agent behaviour in the Stage A run was
**refusal**: a bite refused because the briefed site was unreachable; a brief instruction refused
because its "loud" form was a false reject; two agents stopping rather than adapting; a reviewer
retracting its own finding; a read-only agent auditing the orchestrator's ledger and being right
twice. None was asked for. **"Report disagreements rather than silently resolving them" goes in
every brief.**

**The sub-orchestrator is the single writer of history.** Implementers edit; the sub-orchestrator
commits, one commit per bite. `DECISIONS.md` and `DEBT.md` are likewise single-writer.

---

## 5. Verification posture

### The quiescence protocol (new; non-negotiable)

**No gate, probe, or drain claim is measured while any agent holds uncommitted edits.** The
orchestrator declares quiescence explicitly before any measurement window and does not dispatch a
writer into it. Read-only agents are told, in words, not to rebuild. Any drain claim is run
**twice**.

### Runs in-band, every unit

```sh
make -C <trunk worktree absolute path> medaka && make -C <trunk worktree absolute path> check-self
```

after roughly every 3 landed bites. Not for correctness — because **every downstream implementer
inherits this base**, and a tree that does not self-typecheck makes all later work unverifiable
and unbisectable.

### 🚨 What CANNOT be deferred this stage — and this is the material difference from Stage A

**B-2 changes the compiler's own emitted IR.** That pulls two gates in-band:

- **`test/selfcompile_fixpoint.sh` at every unit boundary from Phase 2 on.** It is the decisive
  gate for any compiler-source change and the only in-run signal that codegen still converges.
- **Seed re-mint discipline: `test/refresh_seed.sh` is NOT idempotent after a codegen change —
  run it TWICE.** A **stale seed can SEGFAULT the fixpoint on a perfectly correct change**, and
  an agent who does not know that will spend the session debugging a phantom. Load the
  **`benchmark-emitter`** skill before touching the emitter, including its two-rebuild rule:
  a binary's behavior comes from its source but its *speed* comes from the emitter that compiled
  it, so a single rebuild crosses the arms.

### Deferred to the repair round

Goldens, snapshots, selfproc LEG A schemes, the differential gates, engines, must-fail (except
the twice-run drain claims above), the capability matrix, doc gates.

🚨 **Bless zero goldens for the entire run.** Mid-run blessing enshrines intermediate states and
produces N conflicting re-cuts of one file. Goldens are re-cut **once**, from the final binary —
never merged, never hand-resolved.

⚠️ **This stage's bar is NOT byte-identical, by design — selection is semantics.** Every moved
golden gets a **hand-computed** winner with its DICT clause cited, per family. And the standing
known-wrong-oracle rule bites hardest here: **eval is a known-wrong oracle on exactly the shapes
this stage moves** (#1071, #1062 are eval-only S0s in the drain list). Capturing an eval golden
for a dispatch shape enshrines the bug. Work out the right answer from the spec first.

⚠️ **The wasm corpus was blind to this class and #1418 closed by fixing that — confirm the
fixtures are still there and still exercise cross-module same-name collisions before trusting a
green wasm arm.** Derive per corpus; never quote a count.

---

## 6. Communications

**Chatter is a structural problem, not a discipline problem.** Agents re-ask because there is no
write-once shared artifact to consult.

- `.claude/sprint-b/DECISIONS.md` — append-only. Architecture companions write; everyone reads
  **before** asking. Every entry carries its derivation, not just its conclusion.
- `.claude/sprint-b/DEBT.md` — append-only, one row per bite (§4).
- Direct messaging is for what the ledgers cannot carry: a decision that invalidates in-flight
  work, or a blocked unit.

⚠️ **An `isolation: "worktree"` agent writes its report into a worktree nobody reads. Copy the
deliverable out the moment it returns, or it does not exist** — Stage A's worst finding briefly
survived only as a summary of a summary.

### Referee charter

One Sonnet agent, with real authority:

1. **Keeps the ledgers honest.** An entry stating a fact without a derivation gets bounced. This
   tree has a long history of ledger prose that was ungated and wrong — including, in the Stage A
   run, a dead symbol, a fabricated test, and wrong counts in three PR bodies.
2. **Cuts cross-talk.**
3. **Enforces the bite protocol.** No bite lands without `could move:`, `nearest miss:` and
   `engines:`.
4. **Enforces quiescence.** May veto a measurement window.
5. **Forces escalation.** May stop a sub-orchestrator and rule a question architectural.

---

## 7. Operational traps

- **The pre-commit hook fights every commit.** Compiler source moves snapshots. Standing
  instruction: `PRECOMMIT_SNAPSHOT_DEFER=1 git commit …` — **not** `--no-verify`, which also
  drops fmt, lint and lextok.
- **Write the expected-red set into `.claude/HANDOFF.md` before starting.** Snapshot, selfproc
  LEG A, must-fail and the IR-text golden (`diff_compiler_llvm_typed_ir`) are red for the
  duration *by design*. Otherwise an agent diagnoses the run's own deferred debt as a break.
- 🚨 **Before calling a red "pre-existing", READ the gate that produced it.** This tree's gates
  document which unit is licensed to flip them. In Stage A one such red was reported as
  pre-existing by two agents, repeated by the orchestrator in two commit messages and a PR body,
  and was in fact the run's own licensed deliverable — the gate header said so six lines above
  the assertion.
- **`fmt --write` is mandatory and #829's record-comment corruption is live.** No interior record
  comments on a record whose header is still the two-line `data X =` / `| X {` form. Check the
  shape first.
- **CI gives zero signal for days.** The per-unit checkpoint is the only signal. Do not let
  agents poll a queue that has nothing in it.
- **Sole occupancy is wider this stage.** Stage A needed `compiler/types/typecheck.mdk`. B-2 also
  owns `compiler/backend/llvm_emit.mdk`, `compiler/backend/wasm_emit.mdk`,
  `compiler/ir/core_ir_lower.mdk` and `compiler/eval/eval.mdk`. Confirm no scheduled agent is
  pointed at any of them before Phase 0.
- **Absolute paths everywhere.** The shell cwd resets between calls; a relative path edits the
  main checkout, which the trunk build never sees.
- **Pin `BASE=$(git rev-parse HEAD)` at the start.** Every worktree shares one `.git`, so
  `origin/main` moves under you with no signal.

---

## 8. Exit criteria

The sprint is done when every in-scope node's bites are landed, the tree builds, self-typechecks,
**and the self-compile fixpoint is green on a twice-refreshed seed.** It is **not** done in any
other sense — that is the design.

Handoff to the repair round is: the branch, `DEBT.md`, `DECISIONS.md`, and the set of must-fail
pins that flipped red.

**Budget the repair round up front.** Stage A's was discovered, not planned, and it found 2 S0
regressions introduced by the run itself. It is a phase, not a contingency. Its first job is to
work `DEBT.md`'s `could move:` and `nearest miss:` columns, because the gate suite is structurally
blind to this run's characteristic failures: **value goldens cannot see a diagnostic-only change,
absence probes cannot see an undercount, and eval agreement proves nothing on a dispatch shape.**

**And it asks the Phase 0 question again, at the end:** does C4/I2 hold **as a conjunction** —
same instance set *and* same evidence — on a hand-derived permutation differential? Stage A
answered that question late and the answer was no. Answering it early and again at the end is the
whole point of this run.
