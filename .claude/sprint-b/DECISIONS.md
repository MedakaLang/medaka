# Stage B sprint — DECISIONS.md

**Append-only.** Architecture companions and the run orchestrator write; **everyone reads this
before asking**. Every entry carries **its derivation**, not just its conclusion — an entry
stating a fact without a derivation gets bounced by the referee.

Contract: `.claude/STAGE-B-SPRINT.md`. Debt ledger: `.claude/sprint-b/DEBT.md`.
Phase 0 raw deliverables: `.claude/sprint-b/phase0/*.md` (one file per agent, merged here).

**Branch:** `arch/stage-b-sprint` · **Trunk worktree:**
`/root/medaka/.claude/worktrees/giggly-tinkering-rainbow` · **BASE:** `2b9dc798`

---

## RUN-B-000 — run opened, tree state derived 2026-08-13

**Derivation, command by command:**

- `git rev-parse HEAD` → `2b9dc798fd7459e5cd0f3298bcb645a658a177fe`. **Pinned as `BASE`.**
  Every worktree shares one `.git`, so `origin/main` moves with no signal — all diffs and
  checkouts in this run reference `$BASE`, never a moving ref.
- `git status --porcelain` → empty. Clean start.
- Branch `arch/stage-b-sprint` created off `BASE`.
- **Trunk binary cold-bootstrapped** (`make -C <trunk> medaka`, exit 0). This worktree had **no**
  `./medaka` and no `./medaka_emitter` at open — per `AGENTS.md` a worktree-isolated tree
  cold-bootstraps from `compiler/seed/emitter.ll.gz` rather than borrowing a sibling's emitter.
  Artifacts: `medaka` (4141112 B), `medaka_emitter` (2063608 B).
- **Freshness verified, not assumed:** `MEDAKA_STRICT=1 ./medaka --version` → `medaka
  0.1.0-preview`, **exit 0**. Strict mode promotes a stale-source fingerprint to a hard `exit 1`,
  so exit 0 is affirmative evidence the binary matches `compiler/*.mdk` on disk.
- **Baseline self-typecheck:** `make -C <trunk> check-self` →
  `PASS: medaka_cli.mdk closure is type-clean`. This is the in-band signal §5 requires after
  ~every 3 bites; it is **green at BASE**, so any later failure is attributable to this run.

**Stage A's known-red set is EMPTY.** `.claude/HANDOFF.md` records the Stage A goldens re-cut once
from the final binary in terminal commit `46c551c0`: `diff_compiler_selfproc` 16 ok / 0 failing,
`diff_compiler_snapshot_frontend` 201/201, `must_fail` 98 REPRO / 1 DRAINED. So this run starts
from a genuinely clean signal and **does not inherit a red to hide behind.**

⚠️ **One pre-existing red is NOT ours and must not be attributed to this run:**
`check_cli_modules`' `1112-A34/later-invisible` leg, which fails by **ACCEPTING**. No diff that
only adds a reject can have caused it.

---

## RUN-B-001 — sole occupancy confirmed (§7)

§7 widens sole occupancy beyond Stage A's single file: B-2 also owns
`compiler/backend/llvm_emit.mdk`, `compiler/backend/wasm_emit.mdk`,
`compiler/ir/core_ir_lower.mdk` and `compiler/eval/eval.mdk` alongside
`compiler/types/typecheck.mdk`.

**Derivation:** `git worktree list` shows one other repo worktree,
`.claude/worktrees/agent-a03a28eda256bd47d` @ `7aae8b83` (behind BASE). `ListAgents` reports no
live agent in it — only two Remote Control peer sessions, one offline and one idle, neither
holding this tree. mtimes on that worktree's copies of the sole-occupancy set:
`typecheck.mdk` 2026-08-12T22:55, `llvm_emit.mdk` and `eval.mdk` 2026-08-12T22:41, against a
current clock of 2026-08-13T00:44 — **idle ~2h, no writes in flight.**

⚠️ **Honest limitation, recorded rather than glossed:** this session is worktree-isolated, so
`git -C <sibling> status` is **refused** by the isolation classifier. Occupancy is therefore
established from `ListAgents` + mtimes, **not** from a porcelain status. That is weaker evidence.
It is sufficient because the sibling is behind BASE and idle, but if a sibling agent wakes and
edits the occupancy set, this ruling lapses and must be re-derived.

---

## RUN-B-002 — Stage A's split verdict, and what this run does differently

Read from `.claude/ORCHESTRATING.md` §"The deferred-verification sprint (Stage A, 2026-08-12/13)"
(line 2247) — quoted, not paraphrased from the sprint doc's summary of it:

- ✅ **KEEP** deferred verification *with* a mandatory per-bite `could move:` field. Cost
  "essentially nothing"; it "found 2 S0 regressions, an architectural contradiction, and a
  pre-existing S0."
- ❌ **DROP** concurrent implementers. "**Four contaminated measurements in one run, all from
  agents holding uncommitted edits; zero from late gates.**" Worst case: a must-fail run
  reporting **5 phantom DRAINS** where a quiescent tree had zero — and since the next action on a
  drain is to *close the issue*, trusting it would have put five wrongly-closed bugs in the
  tracker. Plus ~4 bites of rework from a region collision and one function built twice.
- Five concurrent adversarial **reviewers** interfered with **zero**, because they do not edit.

**Ruling for this run: PARALLELIZE READERS, SERIALIZE WRITERS.** Throughput comes from read-only
fan-out and batched builds, not concurrent writers. **One implementer live at a time.**

**Applied at Phase 0:** six agents dispatched concurrently — five strictly read-only (P0-A/B/C/D,
P0-FABLE), each writing exactly one disjoint file under `phase0/`; one narrow writer (P0-P)
confined to `test/must_fail_fixtures/`, which no other agent touches. Zero compiler-source
writers live. Every brief states the true concurrency, because Stage A's orchestrator opened a
brief with *"you are the ONLY agent live"* and dispatched two more minutes later; that agent
checked instead of trusting it, and only for that reason did its measurements survive.

**Every brief carries the refusal clause.** The highest-value agent behaviour in Stage A was
refusal — a bite refused for an unreachable site, a brief instruction refused because its "loud"
form was a false reject, two agents stopping rather than adapting, a reviewer retracting its own
finding, a read-only agent auditing the orchestrator's ledger and being right twice. None was
asked for. So it is asked for now, explicitly, in every brief.

---

## RUN-B-003 — the drain list is OPEN by policy; baseline states derived

`gh issue view` on each, 2026-08-13. **All confirmed OPEN**, with labels:

| Issue | Sev | Labels | In this run |
|---|---|---|---|
| #1113 | — | ws:soundness, ws:typecheck, ws:emitter | **B-2, the spine** |
| #991 | S3 | ws:typecheck | B-3 |
| #994 | S3 | ws:typecheck | B-3 |
| #1114 | — | ws:typecheck | Phase 0 desk item: verify-and-close |
| #1317 | S0 | ws:soundness, arc:plan-gap | retires at B-2.1 **by deletion** |
| #1564 | S1 | verified, ws:typecheck | drain |
| #1599 | S0 | verified, ws:typecheck | drain |
| #1560 | S0 | verified, ws:soundness | drain |
| #1072 | S0 | verified, ws:emitter | drain |
| #1071 | S0 | verified, ws:emitter | drain — **was unpinned** |
| #1062 | S0 | verified, ws:soundness | drain (eval-only) |
| #1182 | S0 | verified, ws:soundness | drain |
| #1068 | S1 | verified, ws:wasm, ws:emitter | drain — **was unpinned**, lands with B-2.4 |
| #993 | S3 | ws:typecheck | **OUT** — B-1 |
| #1046 | S0 | verified, ws:emitter | **OUT** — F-1 (local lambda) |
| #1075 | S1 | verified | **OUT** — F-1 residual, **was unpinned** |
| #1265 | S0 | verified, ws:soundness, ws:typecheck | Phase 0 adjudicates |
| #1597 | S1 | verified, ws:typecheck | Phase 0 adjudicates; presumption OUT |

**Policy (contract §1): the run implements S0/S1-draining work. It does NOT close it.** Pins
flipping red as fixes land is a **deliverable** and is the repair round's attack list. Closure
requires the adversarial review gate every soundness fix here gets, which happens after.

⚠️ **A drain reading is only valid on a quiescent tree, and every drain claim is run TWICE.**
Two runs disagreeing means the tree is moving. See the phantom-DRAIN history in RUN-B-002.

---

## RUN-B-004 — the three unpinned drains: falsifiability hole, being closed now

**#1071, #1068 and #1075 have no must-fail pin.** A drain claim against an unpinned issue is
**unfalsifiable**, and three of this run's own drain targets were in that state. Dispatched to
P0-P with the bar: **witnessed RED first-hand on the current binary, before any fix exists**, and
the row confirmed to read **REPRO** — because a **malformed pin reports DRAINED or phantom-skip**,
which is indistinguishable from a fixed bug and reads as a *benign* verdict. That has happened
three times in this repo.

#1075 is pinned but labelled **out-of-scope for Stage B** (F-1, local lambda), so a later agent
does not read its still-RED pin as a Stage B failure.

---

## RUN-B-005 — the decisive gate is GREEN at BASE (baseline, not a formality)

`sh test/selfcompile_fixpoint.sh` at BASE, **exit 0**:

```
C3a PASS: IR1 (native) == seed-bootstrapped converged reference, byte-for-byte
C3b PASS: IR1 == IR2 byte-for-byte — FIXPOINT (the compiled compiler reproduces its own output)
C3a (IR1==seed-ref): YES   C3b (IR1==IR2 fixpoint): YES
```

**Why this was worth spending before any implementation:** the fixpoint is **in-band from Phase 2
on** and cannot be deferred, because B-2 changes emitted IR. Without a baseline, a red fixpoint
later is ambiguous between *this run broke codegen* and *it was already red* — and the standing
trap is that a **stale seed can SEGFAULT the fixpoint on a perfectly correct change.** It is green
at BASE on the committed seed, so from here **any fixpoint failure is attributable to this run**
and the seed is not a confound at the outset.

⚠️ **Self-check on my own action, recorded because it is the exact shape this run exists to
prevent.** I started this gate while P0-P was using `./medaka` to witness must-fail pins — i.e. I
ran a heavy build-shaped job during another agent's measurement window, which is the contamination
pattern §5 forbids. **Verified rather than assumed that it was harmless:** `selfcompile_fixpoint.sh`
compiles every stage into its `$WORK` temp dir (`"$CC" ... -o "$2"` at `:112`, all targets under
`$WORK`) and writes **neither** `./medaka` **nor** `./medaka_emitter`. Confirmed from the
consequence, not the source: trunk mtimes were **unchanged** across the whole run
(`medaka` 02:46:09, `medaka_emitter` 02:45:18 — identical before and after). So P0-P's evidence
stands. **The general rule is unchanged and I should not have needed the check: do not overlap a
build-shaped job with a measurement window.**

---

## RUN-B-006 — §5's wasm-corpus precondition: DISCHARGED, and it yields a Phase 5 tripwire

Contract §5 requires confirming, before trusting a green wasm arm, that the wasm corpus still
exercises **cross-module same-name collisions** — the class it was once entirely blind to.
*"Derive per corpus; never quote a count."* Derived, not counted:

- **#1418** — `gh issue view 1418` → **CLOSED**, titled *"S3: `test/wasm/fixtures_modules` has ZERO
  cross-module same-name collision fixtures — the identity arc's semantics reach wasm with no
  coverage of the class."* So the gap was real and was closed by adding coverage.
- All three sibling corpora are present and are **genuinely distinct** (the shared-corpus trap
  warns that a naive grep conflates them): `test/wasm/fixtures`, `test/wasm/fixtures_typed`,
  `test/wasm/fixtures_modules`. The modules corpus holds the multi-module collision dirs
  `iface_name_collision_default`, `mm_color`, `mm_sum`, `record_xmod_field_order`,
  `record_xmod_field_order_permuted`, `record_xmod_field_type_collision`,
  `record_xmod_field_type_swap`.
- **Checked for substance, not just presence** (a fixture can exist and exercise nothing).
  `iface_name_collision_default/` is a real 5-module program: `ifa.mdk` and `ifb.mdk` each declare
  `interface Speak x` with a **different** default body and have **no import relationship of any
  kind**; `ifai.mdk`/`ifbi.mdk` each implement it with a **method-less** impl, so each type must
  inherit its *own* module's default.

**Two properties of that fixture make it directly load-bearing for Phase 5 (B-2.4):**

1. **Its expected value is hand-derived from the spec, not captured from an engine** — its own
   header cites DICT-SEMANTICS §5 (a default applies only when the selected instance omits the
   method) and §8 I4 (a class is `(module, name)`), concluding correct = `A-default|B-default`.
   That is precisely the discipline §5 demands of us, already applied.
2. It records that #1047 was invisible to `diff_compiler_engines` because **all three engines
   resolved the same registry the same wrong way** — *"all three agreed and all three were wrong."*
   This is the standing warning made concrete: **engine agreement is not evidence on a dispatch
   shape**, and B-2.4 is a dispatch change in three engines.

**Ruling:** the wasm arm's coverage of this class is real, so a green wasm arm is meaningful — and
`iface_name_collision_default` is registered as a **tripwire for B-2.4**: it guards the *fixed*
state of #1047, so if a B-2.4 bite moves it, that is a regression in the class this stage is
supposed to be making structurally impossible. It is a **live differential against the native
oracle with no golden**, so it cannot be silently blessed away.

---

## RUN-B-007 — Phase 0 returns: **the contract itself was wrong in three places.** Amendments.

P0-A, P0-C and the Fable consult have landed. All three **refused part of their brief**, which is
what they were briefed to do, and between them they corrected the sprint doc's §1 scope table in
three independent places. **The contract is amended below.** Primary sources — read these, not this
summary: `phase0/P0-A-reader.md`, `phase0/P0-C-engines.md`, `phase0/P0-FABLE-c4i2.md`.

### AMENDMENT 1 — §1's B-2.1 row overreaches. `keyForSite*` is NOT B-2.1's to delete.

**P0-A refused it, derived.** `grep -n 'keyForSite' compiler/types/typecheck.mdk` → `15286`,
`17872-17873`, `18557-18558`, `19011`, `19039`, `19054`. **Every one takes its table as the
threaded `keyTable` parameter — none reads `shadowKeyTableRef` or `universeKeyBucketsRef`.**
`keyForSite*` is the ROUTE-WORD source and retires with the route change (B-2.2) and the engine
word-set retirement (B-2.4). The tree says so twice: `TYPECHECK-TARGET-ARCHITECTURE.md`'s
`KeyBuckets` row (*"DEFERRED → B-2, by DELETION"* — B-2, not B-2.1) and `typecheck.mdk:21557-21561`
(*"T1's counters retire WITH #1113 (B-2) … alongside the emitter word-set retirement"*).

**Ruling: ACCEPTED.** B-2.1's deletion budget is exactly `universeKeyBucketsRef` +
`shadowKeyTableRef`. `KeyBuckets`/`buildKeyTable`/`keyEntryOf`/`matchingEntries*`/`candidateBucket`/
`mergeByDeclIdx`/`keyForSite*`/`headCollides*` **all survive B-2.1** and retire at B-2.2/B-2.4.
An implementer who deletes them in Phase 2 has broken the route path.

### AMENDMENT 2 — §1's *"wasm peer arm"* is FALSE for two of the six B-2.4 bites.

**P0-C refused it, derived:** wasm has **no arg-tag dispatcher** and **no interface-default arms**.
So bite `d` (disjoint default-tag namespace) and bite `f` (consume frozen admissibility at the
arg-tag sites) have **no wasm arm at all** — `d` because of #1020 (out of scope), `f` because
`RNone` is a `gapLP` there.

**Ruling: ACCEPTED.** This matters more than a scope trim: a blanket *"wasm peer arm"* instruction
would have sent an implementer hunting a wasm site that does not exist, and the honest outcome of
that hunt is either a fabricated arm or a silent "done". The `engines:` triple is now **per bite**,
not per unit — `a/c/e` are three-armed, `b` is name-peers only, `d/f` are LLVM+eval only.

### AMENDMENT 3 — 🚨 §1's engine list OMITS AN ENGINE. `core_ir_eval.mdk` is IN.

**P0-C flagged this as outside its brief and refused to absorb it, asking for an explicit ruling.
That was correct and it is the most valuable thing in its report.** §1's B-2.4 row names LLVM,
wasm, `eval.mdk`, and `Route`/`core_ir_lower` — and omits `compiler/ir/core_ir_eval.mdk`.

**Derived first-hand, because the rule of thumb alone is not evidence:**
`grep -n 'hasTag\|implMethodEntry\|CImplEntry\|CImplDefault\|dispatch' compiler/ir/core_ir_eval.mdk`
shows it is a **genuine dispatch arm**, not a bystander:
- `:23-24` — *"SLICE 5: typeclass dispatch — impls/interface-defaults are lowered (Ty-free) and
  installed into the driver's env as **arg-tag-dispatched `VMulti`s**"*
- `:444` — `cImplEntryValue env (CImplEntry name score body)`: **it reads the specificity `score`**
- `:448` — `cImplEntryValues env (CImplEntry name score (CImplDefault ifaceId pats body))`:
  it consumes the **interface-default registry with its iface identity**
- `:420-422` — it folds same-named candidates into one `VMulti`, *"the arg-tag-dispatched value"*

So **every axis B-2.4 moves — identity, specificity score, default-arm keying, arg-tag
admissibility — reaches this file.** It also has live gates: `diff_compiler_core_ir.sh`,
`diff_compiler_core_ir_modules.sh`.

**Ruling: `core_ir_eval.mdk` is a REQUIRED arm of B-2.4.** `AGENTS.md` states the rule —
*"`evalModules` and `cevalModules` are PARALLEL module drivers — fix module-frame semantics in
LOCKSTEP"* — and states the precedent: the **P0-9 cross-module ctor-collision fix shipped patching
only `eval.mdk`, leaving `core_ir_eval.mdk` broken for months.** The shared-corpus trap is the
mechanism: `test/eval_modules_fixtures/*/` feeds **both** `diff_compiler_eval_modules.sh` **and**
`diff_compiler_core_ir_modules.sh`, and *"P0-9 shipped 'green' having run only the first."*

⚠️ **Consequence for the deferred-verification posture: this arm is the one most likely to ship
silently broken**, because its gates are deferred to the repair round *and* its corpus is shared
with an arm that will look green. Every B-2.4 `engines:` field must therefore read as a
**four-arm** ledger (LLVM · wasm · eval · core_ir_eval), with "none needed" spelled out and
justified rather than left blank.

### AMENDMENT 4 — the C4/I2 verdict: **⚠️ CONJUNCT-2-ONLY as written**, gap at `ImplBuckets`

The Fable consult's verdict on the sprint's headline claim. The gap is a **second cumulative
table the sprint doc never names**: `ImplBuckets`, built per module from the same cumulative prefix
(*"core + every EARLIER module + this module"*, `typecheck.mdk:28667`; order-observable `:28065`),
with a first-match iface-`""` fallback (`:17578-17580`), omitting no-`requires` impls
(`:17613-16`), consumed by `routeOf` and **all five `resolve*` stampers**. Identity stamped at
`inst` from *that* table is **order-sensitive identity — RUN-045's exact shape recurring one organ
downstream.** Worse: the stampers' existing min⊑ (`matchedEntry`/`selectImplEntryByIface`) runs on
`KeyBuckets`, the table B-2.1 deletes.

**Ruling: IN, as a scope STATEMENT rather than new scope** — the arch doc `:1820` already assigns
`ImplBuckets` to B-2, so naming it is recording what the arc already owns. **Written down
explicitly**, because §1's silence on it is exactly the unstated-(a)-reads-as-unfinished-(b) hazard
the doc warns about for `SupersPath`.

### AMENDMENT 5 — **B-1 stays OUT. The scope ruling is CORRECT** — conditional on one bite.

The question Stage A got wrong late, asked early and answered: **NOT `NEEDS-B-1`.** The
conjunction is achievable without B-1, **conditional on one named bite**:
`expandSupersTable`'s premise that *"the super slot's route is identical to the sub slot's"*
(`:9027-9030`) holds **only while dict words are bare tags**, and **B-2 falsifies that premise** —
so the supers fill must become **per-slot entailment at the construction site**. That is
flat-representation work, not B-1's evidence tree.

**Ruling: `SupersPath` presumption (a) HOLDS** (two-constructor route, `SupersPath` deferred to
B-1 by name) **plus the `expandSupersTable` fill bite, which is now IN scope and must be
explicitly owned.** P0-B has been asked whether it sits in B-2.2 or wants its own unit.
⚠️ P0-C's bites are cut against presumption (a); **choosing (b) would force bites `a` and `c` to be
re-cut.**

### AMENDMENT 6 — #1068's filed fix direction is **WRONG**, and it is subsumed, not ordered

**P0-C, in those words.** #1068 asks wasm to **build the superset-OR arm that bite `B-2.4-a`
deletes** — the same construction PR #1058 put in LLVM and that #1072 documents as a live S0.
Same site (`wasm_emit.mdk:4034-4039` + caller `:4459`), **opposite direction**. This vindicates the
contract's coordination note that sequential is the wrong answer.

Two riders, both owed in the same PR: #1068 has **no must-fail pin** (only
`test/engine_divergence.txt:159-160`) — P0-P is authoring one — and **those two ledger rows
themselves encode the retired design** (*"PROMOTE when wasm accepts the route-word set"*), so they
must be re-worded rather than left to teach the deleted architecture to the next agent.

---

## RUN-B-008 — 🚨 OPEN STRUCTURAL QUESTION: is Phase 2 separable from Phase 3?

**Two independent derivations converged on one seam, which is why this is a phase-structure
question and not a footnote.**

- **P0-A**, calling it *"the sharpest risk in the whole unit"*: B-2.1-b moves the **checker's** leg
  while `argReqRoute`/`selectReqImpl` (`:19311`, `:19380`) still select the winner on the
  **router** side over `KeyBuckets`. **#1560 measured that desync as `RNone` + "the binary still
  faults"** (`:22205-22211`). So if the two legs disagree about the winner, **B-2.1-b reproduces
  #1560** — the run would introduce the S0 it is trying to drain.
- **Fable**, from the other direction: the stampers' min⊑ runs on `KeyBuckets`, the table B-2.1
  deletes.

P0-A's own reading: B-2.1-b can land alone **iff** both legs compute min⊑ over populations that
agree — *"which is exactly what the whole-prefix measurement at `:20287-20302` established for
candidacy and what **nothing** has established for these two."*

**Status: UNRESOLVED, referred to P0-B** (which owns the router/stamper side) with the question
stated as an attackable claim. **This is the STOP-AND-LAND gate's real content** — the gate was
written as "is the tree stable"; its actual first question is now *"can Phase 2 land without Phase
3 at all?"* If the answer is no, Phases 2 and 3 merge into one unit and the gate moves after them.

⚠️ **Not decided by an implementer, and not absorbed silently by enlarging a bite.** Recorded here
open, per the contract's own instruction that an unstated ruling reads to a later agent as an
unfinished one.

---

*(Rulings from P0-B, P0-D and P0-P are appended below as they land.)*
