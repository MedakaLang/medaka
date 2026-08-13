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

## RUN-B-009 — 🚨 THE PHASE STRUCTURE IS RE-CUT. Phase 2 is NOT separable from Phase 3.

**RUN-B-008's open question is CLOSED, and the answer was already measured in the tree.** P0-B found
the site: `typecheck.mdk:22205-22211` — *"REJECT, DO NOT ROUTE … move only the checker's leg …
**MEASURED** … `argReqRoute` of `RNone` and a binary that still faults."*

So P0-A's proposed `iff` (*"can land alone iff both legs compute min⊑ over populations that
agree"*) is **derivably false** — P0-B gives three grounds. And the failure direction is not merely
a fault: it is a **severity increase**. The define side gains dict params that **no call site
fills** — the **S-1 under-application** shape: *"`check` green, `run` type-confused, `build` prints
a raw PAP pointer."* A run whose purpose is draining S0s would have introduced one.

⚠️ **CORRECTED 2026-08-13 (P0-Q probe 5, verified by me at `compiler/frontend/ast.mdk:700-715`).**
This entry originally cited `ast.mdk:706-712` as the authority, inheriting the citation from
`P0-B-routes.md`. **That passage is scoped to `RLocal`, not `RDict`** — it documents the dict list a
*shadowing standalone* carries under SHADOW clause S9. The **failure class it describes is exactly
right** and is quoted above verbatim, but it is not a general authority for dict-arity skew on the
route path. **The under-application argument stands on its own mechanics; the citation was
over-scoped.** Recorded rather than silently edited, because I repeated it twice — this is the
*"a precise citation is not a verified one"* failure occurring inside the ledger whose whole
purpose is to prevent it.

### The ruling: **do NOT collapse Phase 2 and Phase 3 — re-cut the AXIS.**

P0-B proposed a better third option than the two I was weighing (land-alone vs merge), and I am
adopting it:

| new phase | content | why it is a coherent unit |
|---|---|---|
| **Phase 2′** | **population unification** — the checker leg AND the router/stamper leg move onto one substrate together; the route payload **stays a `String`** | This is where the **S0 drain** lives. Both legs move, so the desync above cannot arise |
| **Phase 3′** | **payload identity** — the route payload becomes identity-bearing | Separable *because* the population is already unified |

**Why this beats merging:** merging would produce one enormous unit whose goldens no bisect could
attribute — precisely the failure the design doc names at F-3 (*"bundling them makes CI unable to
say which half moved a golden"*). The re-cut **preserves the STOP-AND-LAND gate** and preserves
golden attribution, while making the fault above structurally impossible rather than
merely-avoided-by-ordering.

**The STOP-AND-LAND gate stays where it is**, after Phase 2′ — and it now has real content: Phase
2′ alone drains the S0s and is a coherent landable PR.

### The `ImplBuckets` population is WIDER than the Fable consult stated — two corrections

P0-B derived both, and both enlarge Phase 2′:

1. **There is a THIRD `KeyBuckets` population**: `stampKeyTable = buildKeyTable implDecls`
   (`:28682`), sitting beside `ImplBuckets` — and **it is where #203 put the stampers' min⊑.**
   Neither the sprint doc nor the Fable consult reaches it.
2. **There are SEVEN table-consuming stampers, not five.** ⚠️ **The Fable consult inherited the
   tree's own stale comment at `:28679`** to get five. This is the standing rule biting inside
   Phase 0 itself: **a count is an encoded fact with no derivation and no expiry.** Derive; never
   quote — including from this ledger.

Sizing, derived: **49 signatures, one file** — Sonnet-sized *as threading*, with the iface-`""`
first-match fallback **carved out as a separate semantic bite** (it is a semantics change, not
threading).

### `SupersPath`: presumption **(a) CONFIRMED**, premise verified verbatim — and (a) is NOT free

P0-B quoted `expandSupersTable:9037-9042`: *"APPENDS, per entry, one extra slot … Appended AFTER
the declared slots … **Because the dict VALUE is just a type tag, the super slot's route is
identical to the sub slot's.**"* Corroborated independently: `entail:18953` is a three-rung ladder
with **no `super` arm**. So there is genuinely no path to reference and (a) is right.

⚠️ **But (a) is not nothing:** identity-stamping **falsifies that header's own premise**, so B-2.2
must **withhold** identity from appended slots — and **the tree destroys the boundary needed to do
so.** Hence bite `B2.2-f` (preserve the declared/appended super-slot boundary). **#1127 is NOT
drained** — its legs 1–2 are B-1's.

⚠️ **The Fable consult's *mechanism* for this was wrong and P0-B corrected it:** nothing copies.
The per-slot iface **exists** (`:9060-9064`); the real defect is that **two of three** fill paths
are iface-blind (`routesOfMonos:19221` passes `""` → first-match; `recRoutes:19421` has no iface
param at all). **Smaller fix, same verdict** — folded into `B2.2-d′`. Recorded because the right
conclusion defended by wrong reasoning is a defect in its own right.

### DICT §5, verbatim at last (`docs/spec/DICT-SEMANTICS.md:957-960`)

> Inspecting a runtime value's constructor to select an impl is sound **iff** the class parameter
> occurs in an argument position whose head constructor uniquely determines the **most-specific
> matching instance** (§3), *and* that argument is evaluated.

P0-B reports honestly that the brief and #1113 add two quantifiers the doc leaves implicit
(*"every reachable constructor"*, *"every goal reaching the site"*), finds **no conflict**, and
adopts the stronger reading explicitly. **Ruling: the stronger reading is the sprint's bar.** The
weaker paraphrase this contract warned about (*"no overlap below the head"*) remains forbidden — it
licenses an S0 at zero overlap.

---

## RUN-B-010 — B-3 SHRINKS: **#991 is already implemented.** And its "byte-identical" bar is wrong.

### 🚨 #991 — **DESK CLOSE. All three clauses of its title are FALSE.**

P0-D verified each at the stamp sites rather than from the enum's own comment — the distinction
matters, because a comment is exactly what would have preserved the stale claim:

- *"`implObls` still carries the pre-#838 tuple"* → **false.** `implObls : Windowed UObligation`
  (`typecheck.mdk:6732`).
- *"three `Provenance` arms are dead"* → **false.** All **six** arms have real producers:
  `:10072`, `:10443`, `:10981`, `:8914`, `:10812`, `:11045`.
- *"the numlit descope is unrecorded"* → **false.** Recorded at `:6733`.
- `implOblToU` has **zero definitions and zero call sites**; three comments record its removal
  (`:5257`, `:21764`).

**Landed in `fa9f7564` as a rider on #1446's PR** — which is why no issue link closed it. This is
the third time this arc that **the tracker lagged the tree**, and it is a *good* outcome: closing
an issue as already-fixed is real progress. **No implementation; a desk close.**

### #994 — bites take its **own fallback**, not its headline. The contract's bar was wrong.

🚨 **Full fusion into single record-valued tables is NOT byte-identical** — six sites replace one
member alone. So the contract's framing of B-3 as *"byte-identical bar"* does not survive contact
with #994's headline. **Ruling: take #994's documented fallback — a fused paired *write op*** —
which *is* mechanically checkable, preserving B-3's actual purpose as the calibration unit.

- **B-3-a** — one fused write op for the fn-constraint **TRIPLE** (`:24268`, `:25317`,
  `:14234`/`:14245`). #994's body predates `funConstraintArgsRef` (#1161), so the issue describes a
  pair where the tree has a triple. `Option` args payload preserves `registerInferredFor`'s
  asymmetry.
- **B-3-b** — `expandSupersTable` (`:9037`) **+ `expandSupersCross` (`:9045`)**.
  🚨 **THE ONE B-3 BITE THAT CAN MISCOMPILE:** `:9039` reads the **old** ifaces table before
  `:9040` overwrites it. **Inverting that order double-expands super slots and changes dict
  arity.** So much for "mechanically visible" — this bite gets the same care as a B-2 bite, and its
  `could move:` must name dict arity explicitly.
- **B-3-c** — fused write op at `registerMethodConstraints` (`:23700`), the sole co-write site. The
  five ids-only reseed sites are **explicit non-sites**: positions-absence selects a fallback arm
  (`:5845`, `:8614-8622`), so a non-`Option` fused field **changes behaviour**.
- **B-3-d — DECLINED.** crossModule bare/Qual: different key types (`:5955-5956`), different
  lifecycles (`:20621-20626`), and the invariant is **already a type fact** via `freshCrossRun`
  (`:5870-5876`). Fusing would buy nothing and cost a type-level guarantee.
- **B-3-e** — docs: the dead `implOblToU` citation in DICT §11's OD4 row (`:2491`); and `D1–D6` →
  **`OD1–OD6`**, since the spec **forbids** the `D1–D6` spelling at `DICT-SEMANTICS.md:790` — a
  spelling **this sprint doc and the design doc both use.**

---

## RUN-B-011 — the three adjudications, settled

### #1114 — **CLOSE.** §4.2 OD1–OD6 (`:782`) + six §11 rows (`:2488-2493`); #845/#792 both CLOSED
2026-08-05, with four `run_check_agreement_fixtures/` cells. Conformance is 🟡/🔴 in places but
every residual is **re-homed to #1330/#1326/#1337**, so nothing is dropped by closing. Closing
comment **drafted, not posted** — as instructed. Closure happens after the adversarial review gate,
with the rest.

### #1265 — **SPLIT: keying IN, denotation OUT.** And the agent revised its own ruling.

P0-D **first ruled OUT**, then overturned itself on finding
`docs/spec/DICT-SEMANTICS.md` §9.9 `:2011-2012`: *"#1265's pin flips … Revert; **that is B-2's**"* —
i.e. the revert was forbidden in A-3.4 **precisely because** it is B-2's work. That is authority for
IN, and it is the opposite of what proximity would have suggested.

- **Keying → IN**, as new bite **`B-2.4-k`** (6 symbols, 4 files).
- **Denotation → OUT** (the method-namespace lane, #1354 M-2).
- **The boundary, stated in terms of what is keyed** — so an implementer cannot land on the wrong
  side of it by proximity: ***can the key express two distinct answers?*** **No** → representation
  → **IN**. **Yes, but the wrong one is chosen** → selection → **OUT**. That keeps #1182-in and
  #1265-denotation-out coherent, which was the instability I asked about.
- **#1265 and #1182 are NOT the same defect.** #1265's own line: *"the narrowing has no
  representable answer to narrow to."*
- ⚠️ **The Fable consult's ground for the split was FALSE, and the split is still right.** B-2.4's
  *"disjoint default-tag namespace"* means **route-words** (#1113's parenthetical), and
  `TYPECHECK-TARGET-ARCHITECTURE.md:1250-1252` **stripped that gloss** before this sprint doc copied
  it — which is how Fable misread it. Written as a mere clarification the split delivers nothing;
  written as keying it delivers the fourth discharge kind. **Right answer, wrong reasoning, caught
  by a second agent.**
- P0-A's `typecheck.mdk:3945-3951` quote (*"NO `IE` KEY COMPONENT MAY BE A METHOD NAME"*) was
  **verified verbatim** by P0-D. My relay of it is now corroborated rather than trusted.

**Ruling on the scope addition: `B-2.4-k` is ACCEPTED IN.** Reasons: §9.9 already assigns it to
B-2, so this records existing ownership rather than growing scope; it is 6 symbols across 4 files;
and it closes the **fourth discharge kind**, without which this run's headline C4/I2 claim would
need a written caveat. **#1265 is NOT closed by this run** — only its keying half moves, and its
pin flipping is a deliverable.

⚠️ P0-D escalated rather than absorbing this, and was right to: *"if declined, the run must scope
its C4/I2 claim to exclude default arms **in writing**; silence is the Stage A failure."*

### #1597 — **OUT.** Presumption upheld.

`DataEnv`/record territory, not evidence. Already adjudicated out in Stage A with its pin as the
deliverable. Decisive added reason: RUN-030 documents a **loud-S1 → silent-S0** hazard there, which
makes a **deferred-golden sprint the worst possible place** to touch it. Pin exists and is
well-formed (3 modules + `claim.txt`).

⚠️ **My brief was WRONG and P0-D corrected it:** #1597 is Stage A's **F-1/F-2** (filed and
deferred, RUN-029). The bite **refused as unreachable dead code** was **F-3**, which belonged to
**#1586's `DAttrib` arm** — a different node. I propagated that error from the sprint doc's §1;
noted here so it does not propagate further.

⭐ **P0-D declined to run the must-fail gate**, citing four live agents and a running build as
*"the exact non-quiescence that made Stage A's '5 DRAINED' a phantom (RUN-033)."* **That is the
quiescence protocol working without being asked** — the agent refused a measurement rather than
producing a contaminated one.

---

## RUN-B-012 — the pins: one authored and PROVEN fail-capable, two refused with reasons

P0-P closed the falsifiability hole, and refused two of the three rather than manufacturing pins
that would have passed for the wrong reason. **All three outcomes are correct.**

### #1071 — **PINNED and observed RED**, and ⭐ **proven fail-capable**

`test/must_fail_fixtures/1071-eval-inherited-default-sibling-calls-typearg/`. `run main.mdk` → exit
0, stdout `int/31`/`int/31` where `int/31`/`str/71` is correct. Row reads **REPRO** in
`sh test/diff_compiler_must_fail.sh` (100 fixtures, **0 DRAINED, 0 control-broke, 0 malformed**,
suite exit 0).

⭐ **It did the thing this repo keeps getting burned for skipping:** it **proved the pin can fail**
— temporarily asserted the *correct* `str/71`, confirmed the row flips to **DRAINED**, then
reverted. A pin authored but never witnessed failing is indistinguishable from a malformed one, and
**a malformed pin reports DRAINED, which reads as a benign verdict.** That has happened three times
here. This one is now known to be live in both directions.

Correct answer derived from **DICT semantics** (the dict is selected for the full applied type →
`str/71`), with native's independent output as **corroboration only** — the right ordering, given
eval is the known-wrong oracle on exactly this shape.

### 🚨 #1071 is a DUPLICATE of #1062 — adjudicated by me, on the evidence

P0-P flagged this and explicitly did **not** resolve it. Resolved here, having read both issue
bodies first-hand rather than relaying the flag:

| axis | #1062 | #1071 |
|---|---|---|
| engine | eval-only (native correct since #1058) | eval-only (native correct since #1058) |
| shape | sibling-method call **inside an interface default body** | sibling-method call **inside an interface default body** |
| collision | `Box Int` / `Box String` — head tycon shared, differ only in type args | `Box Int` / `Box String` — identical |
| symptom | inner call resolves to the first impl at that head, for every receiver | inherited default's sibling calls dispatch to the sibling's type |

**They are the same mechanism.** The only proposed distinction was #1071's sibling-call count
(`tagOf` + `sizeOf`, two, vs #1062's `speak`, one) — and **P0-P MEASURED the one-sibling-call
variant of #1071 reproducing identically**, so the call count is not the trigger. **#1071's own
stated discriminator is false.**

**Consequence for drain accounting, which is why this had to be settled now:** a single fix drains
**both**. Anyone counting #1062 and #1071 as two drained S0s is **inflating this run's output by
one**. Recorded in the fixture's own `why-note:`. ⚠️ **Neither is closed here** — closure is the
repair round's, after the adversarial gate; this ruling only prevents double-counting.

### #1068 — **NOT PINNABLE by this harness.** Ledgered, and the gap named honestly.

Wasm-only, and `run_verb` has **no wasm engine** (verbs: check / check-json / check-types / run /
build / build-run / fmt-write / mcp-call), while **eval and native are both correct** — so any pin
this harness could write **would assert correct behaviour**, i.e. a fixture that passes for the
wrong reason. Correctly refused.

Coverage that does exist: **two self-draining `test/engine_divergence.txt` rows** naming it, with
the shape-A (empty-stdout) / shape-B (partial-then-trap) asymmetry kept precise, and
`diff_compiler_engines.sh` **hard-fails on PROMOTE**.

⚠️ **NOT witnessed RED first-hand, and it says so plainly**: there is no `test/bin/` in this
worktree, so the wasm oracle is unbuilt, and it **declined to build one under quiescence** — the
right call. **Re-measuring both shapes is OWED to B-2.4** and is now that unit's entry condition,
not an optional extra. This is also where AMENDMENT 6 bites: those two ledger rows **encode the
retired design** (*"PROMOTE when wasm accepts the route-word set"*) and must be re-worded in the
same PR that deletes the arm.

### 🚨 #1075 — **NOT PINNABLE: the filed observable DOES NOT EXIST on this tree.**

Measured: the issue's **verbatim** repro gives `build` **exit 0** and a binary printing
`meow|meow` at **exit 0** — i.e. the **#1046** mechanism, **not** #1075's claimed exit-1
`[E-PANIC]`. Cause: **#1075's observable was measured on unmerged PR #1074.**

**This is a tracker defect, not a sprint finding:** #1075 carries the `verified` label while its
stated observable is unreproducible on `main`. Both candidate pins would have been **false drains**
— one flips when #1074 merely makes #1075 *reachable*, the other duplicates #1046's row. Refused,
and ledgered in `test/MUST-FAIL-NOT-PINNABLE.txt` with the reason. Independently matches commit
`17f3c185`, whose reasoning had lived **only in a commit message**; the ledger line now puts it
where the must-fail census can see it.

#1075 stays labelled **out of scope for Stage B** (F-1, with #1046).

### Two items routed OUT of the sprint's critical path, recorded so they are not lost

1. **An unfiled S1-shaped observation from P0-P**, preserved in `phase0/P0-P-pins.md`: *an impl that
   **defines** a method at a primitive head makes the **emitter itself** `E-PANIC` at build time
   (`arg-tag dispatch on impl type that owns no constructors`) on a program that `check`/`run`
   **accept**.* P0-P did **no dedup search** and said so, so it is deliberately **not filed** —
   filing an undeduped claim is the failure mode this ledger exists to prevent. **Owner: the repair
   round**, whose first job is to dedup it against the #1046/#1075/F-1 family and file or fold it.
2. **P0-P edited `test/MUST-FAIL-NOT-PINNABLE.txt`**, outside the `test/must_fail_fixtures/` path
   its brief named — the brief authorized it explicitly, and it **flagged the excursion so it is
   visible in the diff rather than discovered.** Noted as authorized.

---

## RUN-B-013 — the carrier: **BOTH. The 22-vs-85 choice was a false dilemma** — and my criterion was wrong

P0-C's ruling, accepted in full. Neither carrier reaches all four arms, so the question as P0-B
posed it (and as I relayed it) had no correct answer:

| carrier | arms it serves | why |
|---|---|---|
| **C-2** — 5th positional `CProgram` field | LLVM · wasm · `cevalProgram` | threaded by widening `lowerProgramEmit` (`core_ir_lower.mdk:551-552`) and `lowerProgram` (`:522-523`) — both take `List Decl` and *return* the `CProgram`, so the table must enter as a **parameter** |
| **C-1** — widen the `elaborateModules` return | `eval` only | `evalModules : List Decl -> …` (`eval.mdk:3072`) — **it never sees a `CProgram`** |
| C-3 — synthetic `Decl` | none | **refused**, agreeing with P0-B |

### 🚨 It corrected my criterion, and the correction is the useful part

I asked which carrier makes re-derivation *structurally impossible*. **That question has no answer:**
*"no carrier can make re-derivation impossible — only deleting the derivers does"*
(`implEntryRouteWords`, `headTagUniqueW`'s route use, `keyForSite*`). What a carrier actually
controls is **whether absence or bypass is LOUD.**

On that criterion C-2 wins decisively: `CProgram` is destructured **positionally**
(`core_ir_eval.mdk:401`), so a 5th field is a **compile error at every destructure**. And my
throwaway line *"a carrier an engine can bypass will eventually be bypassed"* turns out to be
**already true**: C-1 **is bypassed at 4 of its 22 sites** — `let _ = elaborateModules …` at
`medaka_cli.mdk:745`, `:1685`, `eval_autoprint_main.mdk:39`, `playground_main.mdk:287`. The eval
bite must name those four explicitly.

### ✅ ASSENT GRANTED to the untyped-eval carve-out — with four conditions

P0-C escalated rather than deciding, correctly: *"a knowing decision to leave an unsound path
unsound … it needs your assent and a `DEBT.md` row, not my say-so."*

**The fact my assent rests on, which P0-C did not state and I derived myself:** no user-facing verb
reaches the untyped path.
```
grep -rn 'cevalModules\|cevalProgram' compiler/ --include=*.mdk   # excluding core_ir_eval.mdk itself
→ compiler/entries/core_ir_modules_main.mdk:22,45
→ compiler/entries/profile_eval_main.mdk:42,102
grep -n 'core_ir_eval\|cevalM\|cevalP' compiler/driver/medaka_cli.mdk \
     compiler/tools/test_cmd.mdk compiler/driver/build_cmd.mdk   # → NO MATCHES
```
So `cevalModules`/`cevalProgram` are reachable **only from `compiler/entries/` probe mains**, and
the CLI does not reach `core_ir_eval` at all. The carve-out therefore leaves **no user-facing verb**
unsound — it leaves probe entries and the gates that consume them. **That is what makes it
acceptable; without it I would have refused.**

**Conditions, all mandatory:**

1. 🚨 **The two absence states must stay DISTINCT in the code.** They are different things and
   collapsing them is how the fail-open default returns:
   - *table present, **no row** for a (class, position)* → **FAILS CLOSED** (not admissible).
   - *table **structurally absent*** (the two untyped drivers) → today's arg-tag behaviour,
     marked UNVERIFIED.

   A single `Option`-with-default that serves both is **forbidden.** The precedent is concrete:
   today's analogue **fails open** — `lookupPositions _ _ [] = [0]` (`eval.mdk:1934`) declares
   position 0 dispatchable on a miss, and `keepOrAll` (`:967-969`) then returns the **original**
   candidate set when every tagged candidate is filtered out. A table inheriting that default
   **has changed nothing.**
2. A **`DEBT.md` row** naming both untyped drivers (`eval_modules_main.mdk:37`,
   `profile_eval_main.mdk:92`) in `unchecked:`.
3. **The run's C4/I2 claim is scoped IN WRITING** to exclude the untyped-eval probe paths.
   Per P0-D's escalation and Stage A's lesson: **silence is the failure**, not the caveat.
4. Fixing the untyped path stays **F-1/#1046's lane**, out of this sprint. A bite that "fixes" it
   has left scope.

### Bite moves under the 2′/3′ re-cut: **`a` and `b` move to Phase 2′; `e` stays in 3′**

**`B-2.4-a` (superset-OR retirement) belongs at the END of Phase 2′**, because #1072 is a
**population** defect, not a payload one: the superset-OR exists **only** to hedge module-local
stamping variance, so once the population is graph-global the hedge is deletable **with a `String`
payload still in place.** Also strictly better for attribution (population change vs symbol rename).

⭐ **And it ships a mechanical overturn criterion**, which is exactly what a plan ordering owes:

> `a` is admissible at 2′ **iff** all 7 stampers + `stampImplTable`/`stampKeyTable` + the Flat peer
> are whole-graph. **If any still reads a cumulative prefix, deleting the OR converts #1072's
> wrong-impl into a TRAP, and `a` stays in 3′.**

`b` follows `a` (`memoSelector` *is* "the string an `RKey` occurrence carries"). `e` stays in 3′ —
its site list **is** `B2.2-a`'s compile-error set, which does not exist until the type changes.
`c`/`d` stay in 3′; `d`'s disjointness half may ride `a`.

### The four-arm ledger: accepted, and it found the sites my ruling had only implied

My AMENDMENT 3 ruled `core_ir_eval` in; P0-C's derivation makes it precise and **corrects its own
earlier bites**: `core_ir_eval` **shares eval's dispatch CONSUMERS but DUPLICATES its PRODUCERS.**
From its import list it takes `applyValue`, `methodAtNarrow`, `routeTag`, `applyDicts`,
`coalesceImpls`, `installDispatchTables`, and imports **none** of
`hasTag`/`matchesTag`/`filterByTag`/`pickTagFallback` (reaching them transitively) — so consumer
edits cover both eval arms **structurally, justified by the import list rather than by assertion.**
But it builds its **own** `VTypedImpl` at `:453-455` and registers its **own** default cells at
`:435-451`. **Those producer sites were missing from bites `a` and `d`.** That omission **is the
P0-9 shape** — the precedent I invoked, found live in this run's own bite list before it shipped.

### ⚠️ A count in `P0-B-routes.md` did not survive re-derivation

| P0-B claim | P0-C's re-derivation | verdict |
|---|---|---|
| C-1 = 22 sites / 9 files | 22, in 9 files, listed line-by-line | ✅ **reproduces exactly** |
| C-2 = 85 `CProgram` mentions / 14 files | ran P0-B's command **verbatim** → **75**; stricter filter → 75; raw → 94; files 14 | ⚠️ **75, not 85** |

P0-C **refused to guess** why, and refused to chase it into the main checkout because a
worktree-isolated agent reading another tree is the documented session-costing risk — so *"derived
in a stale tree"* is **its hypothesis, explicitly not its finding.** (It is a live hypothesis: this
repo's main checkout is materially behind the worktrees.)

**Ruling:** nothing turns on it — the carrier ruling rests on **bypassability, which is
structural** — and the honest cost figure for C-2 was never a mention count but the **25
application sites** (16 `lowerProgramEmit` + 9 `lowerProgram`) plus the destructures the compiler
will name. **Standing instruction: re-derive any count in `P0-B-routes.md` before relying on it**;
its 22 reproduced perfectly, so this is doubt about one figure, not the file.

### Still open, deliberately unfilled

`b`'s and `c`'s `core_ir_eval` cells are **conditionally** "none needed" — one grep each, and
**P0-C refused to pre-fill a row whose condition it could not evaluate without the diff.** Correct:
a pre-filled `engines:` cell is exactly the blank-cheque this run's four-arm ledger exists to
prevent. The implementer runs those two greps.

---

## RUN-B-014 — B-3-b, verified first-hand: **#994's headline is in DIRECT TENSION with this function**

P0-D flagged `B-3-b` as *"the one B-3 bite that can miscompile."* I read the site myself rather than
briefing an implementer off a flag, and **the hazard is sharper than the flag says.**

`expandSupersTable` (`typecheck.mdk:9037-9041`), the whole body:

```
expandSupersTable allDecls =
  let _ = setRef perRun.value.funConstraintsRef      (map (expandSupersEntry allDecls perRun.value.funConstraintIfacesRef.value) perRun.value.funConstraintsRef.value)
  let _ = setRef perRun.value.funConstraintIfacesRef (map (expandSupersIfaceEntry allDecls) perRun.value.funConstraintIfacesRef.value)
  ()
```

**The first write READS the second table, before the second write overwrites it.** `:9039` passes
`funConstraintIfacesRef.value` — the **pre-expansion** ifaces list — into `expandSupersEntry`, which
at `:9055` does `expandSupersPairs allDecls (pairSlots ids ifaces)`. `:9040` then replaces that
table with its **expanded** form.

**So the sequence is load-bearing, and here is why it is a trap specifically for a FUSION bite:**
#994's headline asks for the two parallel tables to be **fused into one record-valued table and
written together** — and *writing them together is precisely the operation this function cannot
survive.* Feed `expandSupersEntry` an already-expanded ifaces list and `expandSupersPairs` expands a
second time ⇒ **double-expanded super slots ⇒ changed dict arity.**

**Why a dict-arity change is not a cosmetic defect here** — the function's own header, `:9032-9034`:
it mutates the table refs *"at ONE finalization point … so EVERY reader — define-side `dictArityOf`
and call-side `recRoutes`/`recRoute`/`inferDictAtFound` — sees identical expanded entries."* Break
the symmetry and the define side binds a different number of dict params than the call side applies:
the **S-1 under-application** shape (*"`check` green, `run` type-confused, `build` prints a raw PAP
pointer"*) — the same failure class RUN-B-009 rejected for Phase 2. The two highest-risk items in
this sprint are now the same shape.

⚠️ **Same citation correction as RUN-B-009:** this entry also originally cited `ast.mdk:706-712`,
which is scoped to **`RLocal`**. The *shape* is right and is quoted; the citation was over-scoped.
The argument here does not depend on it at all — it rests on `expandSupersTable`'s own header
(`:9032-9034`), which I read first-hand.

**Consequences for the brief, and they change the bite:**

1. **Fuse the STORAGE, not the WRITE SEQUENCE.** The fused write op must preserve "expand ids
   against the *old* ifaces, then expand ifaces" as an ordered interior. A single simultaneous
   record update is **forbidden** here, and the implementer must be told this in the bite text — it
   is the natural, obvious implementation of the issue as written.
2. `expandSupersCross` (`:9045-9049`) has the **same shape and is safe by construction** — it takes
   both tables as parameters and returns a tuple, so the caller's `idsTbl` is unaliased. It is
   `expandSupersTable`'s *ref-mutating* form that is fragile. **Both must move together** (P0-D)
   but only one carries the ordering hazard.
3. **`could move:` for this bite must name DICT ARITY explicitly**, not "table representation."
4. ⭐ **This retires the contract's framing of Phase 1 as a safe calibration unit.** §2 bills B-3 as
   work *"where a mistake is mechanically visible."* A double-expanded super slot is **not**
   mechanically visible in a diff — it is visible only as a dict-arity mismatch downstream.
   **The self-compile fixpoint is the gate that would catch it**, so — contrary to §5, which puts
   the fixpoint in-band only "from Phase 2 on" — **the fixpoint runs at the end of Phase 1 too.**
   Cheap (it is green at BASE, RUN-B-005) and it is the only thing standing between this bite and a
   silent miscompile.

---

## RUN-B-015 — the two desk closes: **DEFERRED to the repair round** (user ruling, 2026-08-13)

**#1114** (verified already-landed, closing comment drafted by P0-D) and **#991** (all three clauses
of its title verified false; landed in `fa9f7564` as an unlinked rider) are both **desk closes** —
no implementation owed by either.

The contract §1 explicitly authorized closing #1114 as *"a Phase 0 desk item"*, so this was
available. **Val ruled: leave both for the repair round.** Deferred.

**Rationale worth recording, since it makes the deferral the better call rather than merely the
cautious one:** closure is an outward-facing, visible action, and the repair round is already the
gate where **every** closure in this run happens (§1's issue-closure policy — the drain list stays
open through the sprint and closes only after adversarial review). Closing two issues early would
have made this run the only exception to its own policy, for no throughput gain: nothing in the
sprint is blocked on either issue's *state*, only on the *knowledge* that they need no
implementation — and that knowledge is now recorded here and in `phase0/P0-D-b3-adjudications.md`.

**What the repair round inherits, so nothing is re-derived:**
- **#1114** — close. Evidence: §4.2 OD1–OD6 (`DICT-SEMANTICS.md:782`) + six §11 rows
  (`:2488-2493`); #845/#792 both CLOSED 2026-08-05 with four `run_check_agreement_fixtures/` cells;
  every residual re-homed to #1330/#1326/#1337, so closing drops nothing. **Closing comment is
  drafted in `phase0/P0-D-b3-adjudications.md`** — use it, do not re-derive it.
- **#991** — close as already-implemented. Evidence, verified at the stamp sites rather than from
  the enum's comment: `implObls : Windowed UObligation` (`typecheck.mdk:6732`); all **six**
  `Provenance` arms have real producers (`:10072`, `:10443`, `:10981`, `:8914`, `:10812`, `:11045`);
  numlit descope recorded at `:6733`; `implOblToU` has zero definitions and zero call sites.
- ⚠️ **Neither close may be posted from a "CI green" or a passing gate** — both rest on
  source-derived facts, and a green suite is not corroboration of either claim.

---

## RUN-B-016 — B-3-a and B-3-c sites verified first-hand; the asymmetry is real

Completing the Phase 1 site review (RUN-B-014 covered B-3-b, the dangerous one). Read, not relayed:

**B-3-a — the asymmetry P0-D designed around is REAL, and confirms the `Option` args payload:**

| writer | `funConstraintsRef` | `funConstraintArgsRef` | `funConstraintIfacesRef` |
|---|---|---|---|
| `registerMember` (`:24268-24276`) | ✅ ids | ✅ `keptConstraintArgs …` | ✅ `keptIfaces` |
| `registerInferredFor` (`:25317-25320`) | ✅ ids | ❌ **none** | ✅ `map (ifaceForInferredId m) ids` |

So it is genuinely a **triple** at one site and a **pair** at the other. A fused record with a
**non-optional** args field would force `registerInferredFor` to **invent an args value** — which is
why P0-D specified `Option`. Verified rather than accepted: the design is right.

⭐ **And this names what the bite is actually FOR**, which the issue's own wording obscures.
`keptConstraintArgs`' header (`:24278-24280`, #1161/F-3a-ii) says it keeps `funConstraintArgsRef`
*"slot-parallel to `funConstraintsRef`'s ids."* **Slot-parallelism across these tables is today a
CONVENTION maintained by hand at every write site. The fusion's purpose is to make it a TYPE
FACT.** That belongs in the bite text: an implementer who thinks the goal is "fewer refs" will
happily fuse in a way that preserves the convention without making it structural, and land a diff
that reads correct and buys nothing.

**B-3-c — `registerMethodConstraints` (`:23697-23706`) is the genuinely mechanical bite.** Both
writes sit in the **same `else` branch** under one guard
(`if isEmptyL ids || hasAssocSL2 mname …`), key on the same `mname`, and **neither reads the other
table.** No ordering dependency, no aliasing — the clean fusion, and therefore *this* is the bite
that actually calibrates the protocol. Contrast B-3-b, which cannot be fused as written.

Its `Option` requirement has a different cause, and it is a **behavioural** one: P0-D reports the
five ids-only reseed sites are explicit **non-sites** because **positions-absence selects a fallback
arm** (`:5845`, `:8614-8622`). So here a non-`Option` fused field does not merely force invented
data — **it changes which arm runs.** Two bites, two different reasons for `Option`; an implementer
told only "use `Option`" will get one of them wrong.

**Phase 1 is now fully site-verified by me**: `a` (asymmetry ✅), `b` (ordering hazard, RUN-B-014 —
cannot fuse the writes), `c` (clean), `d` (declined), `e` (docs).

---

## RUN-B-017 — the owed probes, discharged. **One reverses a bite's risk direction.**

Three design agents worked before the binary existed and each owed probes rather than guessing —
correct behaviour that P0-Q has now settled. Full evidence: `phase0/P0-Q-probes.md`.

### 🚨 Probe 3 — `B-2.1-a` is **LOAD-BEARING**, and the risk runs the **OPPOSITE** way from P0-A's

P0-A's `B-2.1-a` `could move:` predicted that on Flat *"the reader's substrate changes table but not
content."* **Measured, and that is wrong in the dangerous direction:**

> **#1564 flattened to ONE no-import file `check`s CLEAN and prints `wrap(int)`; the four-module
> version REJECTS with `T-REQUIRES-UNROUTED`.**

**Flat is already whole-program, and therefore already CORRECT on the very shape this sprint exists
to fix.** So repointing the evidence reader onto an **empty** Flat `IE` is not a neutral substrate
swap — it is a **correct → broken regression**, and it lands on the busiest verbs. The Flat path is
reached by `medaka check <no-import file>`, **`lsp`**, **`repl`**, `doc`, `lint`-policy, `snapshot`,
single-file diagnostics, **and `llvm_emit_typed_main`/`wasm_emit_typed_main`** (via `elaborateDict`).

**Ruling: `B-2.1-a` is promoted from "enabling plumbing" to a HARD PRECONDITION of Phase 2′.** No
bite may repoint the evidence reader until Flat has a populated `ImplEnv`. An implementer who takes
P0-A's `could move:` at face value ships an `lsp`/`repl`/`check` regression that **no deferred golden
would catch**, because the goldens for those verbs are exactly the ones this run stops running.

⭐ This is the *"ask what the nearest program a fix does NOT cover"* discipline paying out: the
nearest program was **the single-file case**, and it was already right.

### Probe 2 — P0-A §4.3's hazard **does not exist**; the real one is its mirror image

`univReceiverTag (headTy::_) = headTyconTy headTy` — **the two projections cannot disagree**; one
calls the other. P0-A's owed derivation was aimed at a non-existent hazard.

**The real asymmetry is membership on EMPTY `tys`:** `keyEntryOf` emits **nothing**, while
`ieInsertRowAt` **inserts into `ieHeadless`**. That is a **widening** — the *opposite* hazard from
the false-`T-NO-IMPL` narrowing P0-A warned about. **Re-point the owed derivation accordingly.**

Behavioural sweep covered `Int`, `String`, 2- and 3-tuples, multi-arg `Pair Int Bool`, `List Int`.
**NOT covered, and stated as such: bare tyvar head, rigid head.** One divergence surfaced —
**alias-headed impls are accepted at declaration and unreachable from every goal** — but it is
impl-vs-*goal* and **symmetric across both tables**, so not a B-2.1 delta. Logged for the repair
round, not filed.

### Probe 1 — the definer-arm widening is **SAFE**. ✅ P0-A's load-bearing unprobeable claim holds.

A discriminating pair on identical modules/interface/method/impl: importer shadow → `IMPL`, definer
shadow → `STANDALONE`, **with the impl directly imported by the definer's own module** (i.e. the
maximal universe). Since widening can only flip `implExistsForHead` False→True, **an already-True
universe still yielding the standalone proves the arm is inert to widening.** Agrees on `run` and
native `build`. Source corroborates twice: `definerReceiverDispatches:11499` guards on
`isDefinerShadow` **first**, and `resolveRLocalSite:15014` carries the same short-circuit on the
**route** side — a site P0-A never cited.

**So `B-2.1-c` does not re-erase a user's function.** That was the one claim capable of making the
SHADOW re-basing an S0, and it is now positively established rather than assumed.

### 🚨 Probe 1's rider — **P0-A's `B-2.1-c` site list is INCOMPLETE, and the tree will not compile**

Verified by me:
```
grep -n 'implExistsForHead' compiler/types/typecheck.mdk   # code lines only
→ 11216 · 11503 · 14857/14858/14862 (def) · 14891-14895 (go) · 15014
```
`:15014` — `(not (isDefinerShadow name) && implExistsForHead keyTable name tag)` — is a **FOURTH
call site**, and `B-2.1-c` **changes that function's signature**, so omitting it is a **compile
error**, not a subtle miss. It is also the **route-side** gate, so it must read the **same
population** as `:11503` or the two legs disagree.

⭐ **Why P0-A missed it, and it is instructive rather than careless:** P0-A enumerated readers of the
**REF** (`shadowKeyTableRef`) and got exactly the right answer — **three**. `:15014` takes its table
as the threaded **`keyTable` parameter**, so it is not a ref reader. **But the bite changes the
FUNCTION's signature, and the function has four callers.** *The set you enumerate must be the set
your transformation acts on* — ref-readers and function-callers are different sets, and this bite
spans both. Exactly the *"a table lookup inherits the table's keying"* family of error.

### Probe 4 — the ratchet, derived: **23 rows**, gate PASS, nothing built

`universeKeyBucketsRef` **is** an allowlist row ⇒ **`B-2.1-d` shrinks it to 22.** `shadowKeyTableRef`
is `PerRun` and moves no ratchet number. **Derive at the bite, do not quote 23 from here.**

⭐ **And it re-verified P0-A's reader sets as still exactly `{11216, 11503, 21715}` and `{20348}`** —
so **no region has drifted** since Phase 0 opened. That is `B-2.1-d`'s own `nearest miss:` ("a fourth
reader introduced between Phase 0 and Phase 2 ⇒ STOP") discharged as of now, and it must be re-run
immediately before that bite.

### Probe 5 — RDict skew: coupling **REAL**; "silent" **understated**, "live" **over-read**

The chain's exhaustion arm is **`unreachable` — LLVM undefined behaviour, not `@mdk_oob`** — i.e.
**worse** than P0-B stated. But two masking tiers P0-B omits absorb exactly the tag↔key skew:
`implEntryRouteWords` (#1036 leg 2) already emits an arm per **union** word, and the general-entry
catch-all covers the headless case `typecheck.mdk:17865`'s own example lives in. **So the coupling is
real and must be honoured, but it is currently masked** — P0-B's bites `b`/`e` stay coupled, and the
`could move:` must say *"today masked by two tiers; unmasked the arm is UB."* Source-reading only,
and labelled as such.

### 🚨 A missing instrument: `diff_flat_vs_onemodule.sh` **does not exist**

`typecheck.mdk:14076` asserts it does. Verified by me — `find . -name 'diff_flat_vs_onemodule*'`
returns **nothing**. **It is precisely the instrument a `B-2.1-a` implementer would reach for**, and
given probe 3 that implementer is now working on the sprint's highest-risk precondition with a
phantom tool cited in the source.

**Invisible to both doc gates by construction:** `make agent-doc-symbols` does not scan `.mdk`, and
`make docs-links` checks docs, not source comments. **Owner: Phase 2′** — either build the
Flat-vs-one-module differential (it is the natural grader for `B-2.1-a`) or delete the false claim.
Do not leave it asserting a tool that is not there.

### Still owed (5 items, in `P0-Q-probes.md`) — carried into Phase 2′/3′, not dropped

Chiefly: **a real observed route-word skew** (needs a two-arm build; not constructible read-only),
the **tyvar/rigid-head** sweep arm, and whether **empty-`tys` is surface-reachable**. The first is a
genuine two-worktree cost and belongs in Phase 3′'s plan rather than being discovered by an
implementer.

---

## RUN-B-018 — ✅ **PHASE 0 GATE: MET.** Phase 1 opens.

The gate (§2) is *"every in-scope unit has a written bite list, or it is deferred out of the
sprint."* Discharged:

| unit | bites | status |
|---|---|---|
| **B-3** (#994; #991 desk-closed) | `a`, `b`, `c`, `e` (`d` **declined**) | ✅ all five **site-verified by me** (RUN-B-014, RUN-B-016) |
| **Phase 2′** population | `B-2.1-a`…`e` + `ImplBuckets`/`stampKeyTable`/7 stampers + `B-2.4-a`,`b` | ✅ cut; `B-2.1-a` now a hard precondition |
| **Phase 3′** identity | `B2.2-a`…`f` + `B-2.4-c`,`d`,`e` | ✅ cut |
| **Phase 4** admissibility | `B-2.3-a`,`b`,`d`,`e` + carrier **ruled** (C-2 ∧ C-1) | ✅ cut; `c` unblocked by the carrier ruling |
| **Phase 5** engines | `B-2.4-a`…`f` + **`k`**, over **four** arms | ✅ cut |

Also delivered: `SupersPath` **(a)** with its premise verified verbatim · the declaration-index
defect ruled **(b) fixed-by-deletion** · **#1114 CLOSE** / **#1265 SPLIT** / **#1597 OUT** ·
C4/I2 answered **before** implementing (⚠️ conjunct-2-only as written, gap named and closable
in-scope, **NOT `NEEDS-B-1`**) · one pin authored and **proven fail-capable**, two refused with
written reasons · six contract amendments.

**Cost:** 8 agents, all read-only but one narrow fixture writer. **Zero compiler-source writers, so
zero contaminated measurements and zero region collisions** — the Stage A failure mode did not
recur. Every agent that lacked evidence **said so** rather than guessing, and four of them corrected
either the contract, a peer, or me.

**Phase 1 dispatches now: ONE implementer, on B-3.**

---

## RUN-B-019 — ✅ **PHASE 1 (B-3) LANDED AND VERIFIED.** Four bites, plus a probe the fixpoint could not give.

### Gates, run by me on a freshly built binary

| gate | result |
|---|---|
| `make medaka` | ✅ built (stage A rebuilt the emitter from current source, stage B relinked) |
| `make check-self` | ✅ `PASS: medaka_cli.mdk closure is type-clean` |
| **`sh test/selfcompile_fixpoint.sh`** | ✅ **C3a YES · C3b YES** — byte-for-byte, fixpoint holds |
| `make agent-doc-symbols` | ✅ PASS — 996 live, 0 dead |
| `make docs-links` | ✅ PASS after a ratchet entry (below) |

### 🚨 The fixpoint does NOT discriminate the B-3-b hazard. I built a probe that does.

The implementer's own *"sharpest residual"* was: *"I could find no fixture that would discriminate a
1× from a 2× super expansion. If B-3-b is wrong, the fixpoint is the only local signal."*

**On inspection the fixpoint is NOT that signal, and believing it was would have been the error.**
C3a compares IR1 against a seed-bootstrapped reference **both built from current source**, and C3b
compares two current-source generations. **A UNIFORM super-slot doubling is self-consistent** — the
define side binds 2× dict params, every call site applies 2×, the compiler compiles itself, and both
arms of the comparison carry the doubling equally. **It would pass green.** *(This is the standing
lesson that a passing probe answering the wrong question is worse than no probe.)*

**So I built the discriminating probe — emitted-IR dict arity, read directly.**
`medaka build --keep-ir`, counting the dict words on a `requires`-constrained function:

| program | declared + supers | dicts predicted if CORRECT | if DOUBLED | **observed** | value |
|---|---|---|---|---|---|
| `Mid a requires Base a`, `useMid : Mid a => …` | Mid + Base | **2** | 3+ | **2** (`%arg0,%arg1` + value) | `3` ✅ |
| `Top ⇒ Mid ⇒ Base`, `useTop : Top a => …` | Top + Mid + Base | **3** | 5+ | **3** (`%arg0..%arg2` + value) | `7` ✅ |

**Both fail-capable and both discriminating**: the predicted counts differ between the correct and
doubled hypotheses, so the observation selects between them rather than merely being consistent with
one. The **second** program is the load-bearing one — it exercises the **transitive** fixpoint
(`Top` reaches `Base` through `Mid`, the `chain3b` case `expandSupersTable`'s own header names), which
is precisely where a re-expansion bug would bite and where the one-level case is uninformative. And
**call-site arity equals definition arity** in both (2=2, 3=3), so the S-1 under-application shape
this bite risked is positively excluded, not merely un-crashed.

**Ruling: B-3-b is verified by construction AND by observation.** By construction because I read the
diff — `expandSupersTable` now delegates to `expandSupersCross`, whose two `.value` reads are both
*arguments*, so the pre-expansion ifaces table is what both projections see, identical to the old
sequence. The implementer's solution is **stronger than my brief asked for**: I asked for an ordered
interior, it made the double-expansion **unrepresentable at the site** and collapsed the two forms
into one expansion implementation, so the required lockstep is now structural.

### Independent corroboration of B-3-a's one soundness claim

`registerInferredFor` now evaluates `ifaceForInferredId` **before** the `funConstraintsRef` write
(Medaka is strict, so the `map` completes before the op is called). Sound only if that closure reads
no fn-constraint table. I checked all seven functions the implementer named — `ifaceForInferredId`,
`ifaceForConstraintId`, `ifaceForConstraintIdGo`, `lookupSchemeIface`, `lookupIfaceById`,
`ifaceFromDictApps`, `ifaceAtMonoId` — **no `funConstraint*` read in any of them.**

⚠️ **Honest scope of my check:** I verified **the set the implementer named**, which *corroborates*
its claim. I did **not** independently derive that the callee set is complete, so an eighth callee
reached indirectly would escape both of us. Stated because "I checked it" and "I checked the set
someone handed me" are different claims.

### What the implementer got right that I want on the record

- **Reused the existing `CSlot`** (`:5537`, U1b/#1482) rather than inventing a slot type — its own
  header says it exists *"so that NO consumer … ever holds two parallel lists again"*, and this bite
  extends that to the **producers**. `registerMemberSlots` now emits `(iface, id)` in **one
  traversal**, so the second traversal (`keptConstraintIfaces`) is **deleted**. It explicitly did
  **not** zip two independently-computed lists — which would have preserved the convention *and*
  added a truncation-on-mismatch dict-arity risk. **That is the difference between the property
  becoming a type fact and a diff that reads correct and buys nothing** (RUN-B-016).
- **Found an independent third reason the `Option` is required**, not in my brief:
  `keptConstraintArgs`' second clause stops when its vector list runs out and its producer
  `constraintVarArgMonos` (`:24285`) drops constraints absent from the tvs map — so the args payload
  is legitimately a **PREFIX** of the slots. Folding it into `CSlot` would have had to truncate the
  id list (**a dict-arity change**) or invent a vector.
- **B-3-c used entry-ABSENCE rather than `Option`** — strictly safer, since absence cannot be
  collapsed by a later default, and it verified first-hand that `methodConstraintPositionsRef` has
  exactly one writer and one reader whose fallback arm absence selects.
- **The hazard reasoning is now IN THE TREE** — `setFunConstraintTables`' header states that a
  simultaneous fusion is FORBIDDEN and names the dict-arity mechanism. That is what stops a later
  agent reintroducing it; a `DEBT.md` row alone would not have.

### `docs-links`: a real red, ours, and correctly resolved by a ratchet entry

`.claude/sprint-b/phase0/P0-Q-probes.md:429` cites `test/diff_flat_vs_onemodule.sh` — the gate
**that does not exist** and whose absence that report was written to document. **Both the gate and
the report are correct**; this is the one case `check_doc_links.sh` cannot distinguish, since citing
a path to say *"this is missing"* is textually a citation.

Added one `REF` line to `test/DOC-LINK-EXCEPTIONS.txt` naming the owner (Phase 2′). **It self-drains
both ways** by the ledger's own design: building the gate trips **STALE REF**, removing the citation
trips **ORPHAN REF**. `make docs-links` → **exit 0, 0 dead.** Not silenced — ratcheted.

⚠️ **Process note against myself:** my first read of this gate ran `make … | tail` and printed
`exit: 0` — **`tail`'s** status, not `make`'s, while the output said `Error 1`. The
pipe-eats-exit-code trap, committed by me in the same session I warned an agent about it. The `make`
line in the output was the real signal. **Redirect to a file and read `$?`.**

### The four unclaimed co-write sites: **DEFERRED to Phase 2′**, not dropped

The implementer flagged rather than absorbed (correct) four `funConstraintsRef` co-write sites
outside its brief: `:20399-20404` (the Module arm restoring both tables from `crossRun`, then
prepending `aliasConstraintEntries` — **two** pairs), `:20657-20662` (the reverse snapshot into
`crossRun`), and `:28310`/`:28342` (`scopeArities` reseeds, **ids-only**).

**Ruling, and the two groups get different answers:**

- **`:20399-20404` and `:20657-20662` → owed to PHASE 2′, not to B-3.** They are whole-table
  co-write pairs and `setFunConstraintTables` is exactly their shape, so they are genuinely inside
  #994's stated subject ("fuse the slot-parallel lockstep table pairs"). **But Phase 2′ rewrites the
  POPULATION of these very tables** — `:20399` *is* the Module arm, squarely RUN-B-009's territory —
  so doing them now would be rework in a region Phase 2′ reopens. Deferred to avoid touching one
  region twice, which is the collision cost Stage A paid ~4 bites for.
- **`:28310`/`:28342` → OUT, permanently, and the reason must be stated rather than left implicit.**
  They write ids and **deliberately leave ifaces alone**, so a *pair* op cannot serve them without
  inventing data. **Consequence: "every ids entry has a parallel ifaces entry" is STILL FALSE
  program-wide**, and a reader assuming otherwise is no safer than before this unit. B-3 narrowed
  the property; it did not establish it.

### Deferred debt from Phase 1, per §5

**Two golden families moved and NEITHER was blessed** (zero goldens for the whole run):
`test/snapshots/compiler/typecheck.md`, and selfproc LEG A `types.typecheck.golden`.
⚠️ **The LEG A move is NOT additive-only this time** — `keptConstraintIfaces` is **deleted** and
`registerMemberSlots` is **re-typed**. So the standing "additive-only" check does not apply; the
re-cut must show *exactly* that one binding gone and that one signature changed, **and no other
existing binding re-typed.** Written here because the re-cut happens in a later round by someone
who did not watch this land.

Also still open from B-3-e's neighbourhood, reported by the implementer and **not swept**:
`typecheck.mdk:20697` still says *"(projected via `implOblToU`)"* — the same dead-symbol defect
B-3-e fixed in the spec, but **in source**, and **invisible to both doc gates by construction**
(`agent-doc-symbols` does not scan `.mdk`). And `.claude/STAGE-B-SPRINT.md:67` — the contract
itself — still writes `§4.2 D1–D6`, the spelling `DICT-SEMANTICS.md:790` forbids.

---

## RUN-B-020 — ✅ `B-2.1-a1` LANDED: the grader exists **before** the change it grades. Two of my errors corrected.

`test/diff_compiler_flat_vs_onemodule.sh` — new, 9 rows / 3 cases, **5.0 s**, no `test/bin` oracle,
no clang, no emitter. Fixtures generated into one `mktemp -d` **per process** (so it enrols no
shared corpus — the shared-corpus trap avoided by construction), honours `MEDAKA=` for two-arm
differentials, dash-clean, `perl`/`alarm` timeout shim.

**Verified independently by me, not accepted from the report:**

| check | result |
|---|---|
| `sh test/diff_compiler_flat_vs_onemodule.sh` | ✅ exit 0 — `checked 9 rows (0 drain notice(s))`, *"the FLAT arm holds its pinned answers; accepting arms agree on values"* |
| `sh test/diff_compiler_ci_shard_coverage.sh` | ✅ exit 0 — *"every gate is in exactly one CI shard (0 missing, 0 duplicated)"* |
| `make docs-links` | ✅ exit 0, **0** DEAD |
| `make check-self` | ✅ PASS |

### ⭐ The assert choice — its argument is sharper than either option I offered

I framed the choice as agree-on-acceptance (red on arrival) vs must-disagree (enshrines the bug).
**The implementer found the decisive objection to the first, which is neither of those:**

> **"It goes GREEN on the exact regression the gate exists to catch."** If B-2.1 repoints the
> reader onto an empty Flat `IE` and FLAT drops to the MODULE arm's rejection, **the arms agree and
> the gate passes.** *"An assertion satisfied by the failure it guards is not an instrument."*

**That is the whole discipline in one sentence**, and it is a better reason than "red on arrival."
Chosen instead: **pin the FLAT arm's own answers** (hand-derived from DICT §8 I5 / §3, *not*
captured), and grade the relation only through a clause **true on both sides of the #1564 fix** —
*"every arm that ACCEPTS must compute the same value."* That clause is the miscompile catcher, and
it is exactly the state #1564's own `claim.txt` records between A-3.6 and Door 4 (`check` exit 0,
built binary **exit 139**) — a state acceptance-agreement would have called green.

`must-disagree` was also rejected for a second reason I had not considered: **#1564 already has
that pin** in the must-fail suite, so duplicating it means two graders to re-derive on one fix.

Rows are `PIN` or `CHAR`; a `CHAR` row carries **both** the correct answer and today's answer —
today's passes with a note, the correct answer passes with a **DRAIN NOTICE** naming #1564, and a
**third** answer **FAILS**. So *"something else broke"* can never read as *"still broken"* or
*"fixed."* Both a **positive** control (`all_visible`) and a **negative** control
(`no_impl_anywhere`, both arms `T-NO-IMPL`) — without the negative one, an always-accept regression
would pass every other row.

⭐ **Fail-capability PROVEN, not asserted:** six independent single-expectation mutations of a
**copy**, each RED — including **FLAT pinned to REJECT, the actual regression direction** — plus
exit 2 on a missing binary and a simulated drain-notice pass.

### 🚨 MY ERROR 1 — instruction 4 contradicted my own naming ruling. Correctly refused.

I told the implementer to **delete** the `REF test/diff_flat_vs_onemodule.sh` row from
`test/DOC-LINK-EXCEPTIONS.txt`, on RUN-B-019's reasoning that it would self-drain. **It refused, and
measured why:** with the row removed, `make docs-links` exits **2** with `dead: 2` —
`.claude/sprint-b/DECISIONS.md` and `phase0/P0-Q-probes.md` **still cite the old path**, and neither
is the implementer's to rewrite.

**Both drain directions I predicted are VOID, and my own naming ruling is what voided them:**
**ORPHAN REF** cannot fire (the path is still cited); **STALE REF** cannot fire either, because I
ruled the successor gets a **different name**, so the old path stays legitimately dead. *My two
instructions were mutually inconsistent and I did not notice.*

It **rewrote the row's reason** instead — which the ledger's own ORPHAN-REF doctrine demands, since
*a reason that has become a lie is precisely what that check exists to prevent.* The reason now
records the true history, that Phase 2′ discharged its ownership, that neither predicted drain
applies, that deletion **fails** the gate, and the row's **real** drain condition (ORPHAN REF once
these sprint records are archived).

### 🚨 MY ERROR 2 — I repeated a stale number out of `AGENTS.md` instead of deriving it

My brief told the implementer *"`engines` is the cheapest heavy shard."* **False.** It derived the
truth from two consecutive green `merge_group` runs and put the gate in **`eval`** instead.
**I re-verified on `31655422530` rather than accept the correction:**

`engines` **373s (POLE)** · `types` 322 · `frontend` 289 · `tools` 202 · `sqlite` 185 · `backend`
165 · `eval` **149s (CHEAPEST)**.

I had copied `AGENTS.md`'s *"`gates (types)` was the pole and `engines` the cheapest heavy shard"* —
**a claim sitting two lines above that file's own warning "Numbers here rot — read them off a run
instead," followed by the exact command.** I quoted the number and skipped the command.

**Root cause fixed, not just noted:** `AGENTS.md` now states that its shard-cost ranking has been
wrong **three times**, records that the ranking **INVERTED** (explicitly *"to show the ranking
inverted, not for you to reuse"*), and puts the derivation command in the load-bearing position.

### Three further corrections the implementer derived

1. **The missing gate was NOT a phantom — it was deliberately DELETED.**
   `compiler/DRIVER-COLLAPSE-PLAN.md` Phase 5 (2026-06-13) lists `diff_flat_vs_onemodule.sh` among
   scaffolding it removed, **and its property was flat-vs-1-module BYTE-IDENTITY** — not what
   `B-2.1-a` needs. So RUN-B-017's framing ("asserts a tool that is not there") was right about the
   symptom and **incomplete about the cause**: the comment is a *survivor of a deletion*, not a
   fabrication. `typecheck.mdk`'s comment now says that, rather than merely swapping a filename.
2. ⭐ **The gate caught a bug in ITSELF, and it generalizes.** Its first draft merged `2>&1` on the
   value read; the moment its own `typecheck.mdk` comment edit made `./medaka` stale, **the stderr
   staleness warning became line 1 of stdout** and six accepting rows went red — **build freshness
   masquerading as a semantic finding**, which is #1421's exact shape. Streams are now split and the
   rule is in the header. **This is the stdout/stderr trap biting a gate author rather than a probe
   author**, and it is why that warning's channel is load-bearing.
3. ⭐ **A false corpus-consumer edge, which could have certified an uncovered corpus.** A path
   literal inside a live *message string* made `test/preflight.sh` credit the gate as a **consumer
   of `test/must_fail_fixtures`** — its `_refs` derivation strips comments but **not strings**. That
   false edge would be **inherited by `diff_compiler_fixture_corpus_coverage.sh`** and could be used
   to certify that corpus as covered when this gate does not read it. Literal removed; re-derived
   with `PREFLIGHT_DRY=1` to confirm the edge is gone. **Worth remembering as a shape:** a
   coverage-derivation tool that greps strings can be *fed* a fake edge by ordinary prose.

### What this bite deliberately does NOT cover (from its `nearest miss:`, and it is the honest gap)

**No value in the gate is a FLAT-arm observation.** The `value` column comes from `medaka run`,
which takes the **MODULE** arm even for a single no-import file (the `elaborateOne` 1-module
wrapper), so the FLAT arm is graded on **acceptance + diagnostics only**. A FLAT-arm *value* needs
`llvm_emit_typed_main`/`wasm_emit_typed_main`, which are compiled `test/bin` probes, excluded so
this gate reads no oracle.

**Consequence, stated so `B-2.1-a2` cannot hide behind a green gate:** a change that seats a
**NARROWER** Flat `ImplEnv` — **right acceptance, wrong selected impl** — passes all 9 rows. That
gap belongs to a Phase 3′/5 emitted-IR differential and is recorded in the gate's own header under
*"WHAT THIS GATE CANNOT SEE."* **`B-2.1-a2` must therefore be graded on emitted evidence too, not
on this gate alone.**

Second nearest miss, and it *is* covered: **FLAT declaration ORDER** — both orders of the flattened
#1564 are rows, so an order-sensitive FLAT arm would be caught.

### Deferred debt

`test/snapshots/compiler/typecheck.md` moves (+6 net) — the compiler's own source is in the snapshot
corpus and even a **comment** edit shifts every line below it. **Blessed by nobody**, per §5.
Fixpoint/`check-self` were not re-run by the implementer (correctly — no compiled byte changed);
**I ran `check-self` anyway: PASS.** I did **not** re-run the fixpoint, because a comment cannot
change emitted IR and it was green at `03ef6c47` two commits ago.

---

## RUN-B-021 — ✅ `B-2.1-a2` LANDED: Phase 2′'s hard precondition is discharged

**+70 insertions, 0 deletions** in `compiler/types/typecheck.mdk`. Purely additive, as briefed.

**Verified by me, independently:**

| check | result |
|---|---|
| `git diff --numstat` | **`70 0`** — additive, zero deletions |
| `git diff \| grep shadowKeyTableRef` | **empty** — the existing table and its three readers are genuinely untouched |
| `MEDAKA_STRICT=1 ./medaka --version` | ✅ exit 0 — binary provably built from the source on disk |
| `grep -rn 'ieAudit\|IEAUDIT' compiler/` | **empty** — all instrumentation removed |
| `make check-self` | ✅ PASS |
| `sh test/diff_compiler_flat_vs_onemodule.sh` | ✅ exit 0 — 9/9 as pinned, **0 drain notices** |
| **`sh test/selfcompile_fixpoint.sh`** | ✅ **C3a YES · C3b YES**, byte-for-byte |

⚠️ Note on one grep: `ieShadowCompare` **does** still appear three times — as **pre-existing comments**
citing A-3.4's historical idiom (`:4034`, `:4212`, `:4329`), not leftover instrumentation. Checking
`ieAudit`/`IEAUDIT` is what discriminates; a lazier grep would have produced a false alarm here.

### What landed

- **`buildFlatImplEnv : List Decl -> ImplEnv`** (`:4175`) + **`ieIndexRows`** (`:4182`) — the Flat peer
  of `buildImplEnv`, folding the decl list the Flat arm already holds (`fullUniverse`) through the
  **same** `implDeclFacts` / `implRowsOf` / `ieInsertRowKeys` / `ieInsertRowAt` / `ieBuildSnaps` the
  Module arm uses. One flat program = one scope ⇒ ordinal 0, mid `""`, `seq` still whole-program.
- **`PerRun.bodyImplEnvRef`** (`:6784`) + its `freshPerRun` initialiser (`:6880`).
- **A new SIBLING `let _ = match mode`** (`:20450-20460`) *beside*, not replacing, the
  `shadowKeyTableRef` gate: `Flat _ =>` the new builder; `Module _ _ _ =>` a **pointer copy** of
  `deImpls` (deliberately not re-deriving, citing `moduleImplUniv`'s own reason).

⭐ **An architectural win I did not specify and should have:** it is **ONE ref on BOTH arms**, so the
repoint in `B-2.1-b` gets **a single substrate rather than an arm gate.** That retires design law
L1's two-registry hazard — the thing P0-A explicitly ruled against as an END state (*"two answers to
'does an impl exist' in one compile"*) — instead of deferring it.

### ⭐ It avoided the quadratic BY CONSTRUCTION rather than fixing it

I warned that `ieInsertRow`'s `env.ieRows ++ [r]` is a known O(rows²) (`:4223`, *"OWED, RECORDED
RATHER THAN FIXED"*) but that **`ieRows` order is load-bearing** for RUN-B-007's declaration-index
ruling, so a cons+reverse "fix" could silently change a tie-break the phase rests on.

**It did neither — it made the quadratic unreachable on the new path.** `buildFlatImplEnv` computes
`rows` **once** as a forward list, then `ieIndexRows` folds **only the buckets** — sharing
`ieInsertRowKeys`, so Flat and Module keying **cannot diverge** — and sets `ieRows = rows` in one
assignment. `ieUnivSnaps` is re-derived via `ieBuildSnaps` (correct: `ieAddRows` does **not**
maintain the snapshot table). So: **no quadratic imported into the single-file path, `ieInsertRow`
untouched, ascending-`instRefSeq` order on the shared Module path untouched.** This is the right
shape — *don't fix the hazard, don't inherit it either.*

### ⭐ The equivalence check — this was the deliverable I most doubted, and it is sound

The problem: an additive population **nothing reads** is unobservable, and RUN-B-020 records that the
new grader **cannot** see a narrow env (*"right acceptance, wrong selected impl passes all 9 rows"*).
So "it builds and gates are green" proves nothing.

What it built: temporary Flat-arm instrumentation running **two order-sensitive, ELEMENT-WISE** checks
— **not counts** (I had warned that equal sizes can hide different contents):
1. **population** — `map render (flatMap keyEntryOf fullUniverse)` vs `map render ieRows`;
2. **index vs rows** — every registry key derived from the rows, bucket contents compared element-wise
   against the rows keying into it. **This is precisely the check for the narrow-env gap the flat
   gate is blind to.**

Evidence, in the order that makes it credible:
- **Positive control**: a sentinel-gated verdict panicked `IEAUDIT OK rows=118 keys=235
  ping=IeAuditPing|Int||pingv` — proving **the audit actually ran** rather than silently no-op'ing.
- **Fail-capability, both checks, observed RED**: index built from `tail rows` → `BUCKET MISMATCH …
  expected=Eq|Int||eq actual=`; `ieRows = tail rows` → `ROWS MISMATCH kt=118 ie=117`.
- **Corpus sweep**: `files=355 audit_findings=0`, **330 of them no-import ⇒ FLAT**.
- ⭐ **The sweep harness was ITSELF controlled**: the same detection path over the two mutation probes
  → `files=2 audit_findings=2`. **It verified that its detector detects** — the step that separates a
  real sweep from a green one that was never wired up.
- Instrumentation and both mutation hooks **removed**, rebuilt from stripped source, **all gates
  re-run on the clean binary** (which is the binary I then verified above).

### Refusals and deviations, all correct

- **No perf A/B measured** — and the brief did not require one: that clause was conditional on using
  `ieAddRows`, which it deliberately avoided. Derived instead: **118 rows → 235 index keys** per Flat
  compile, all linear, one `ieUnivSnaps` entry.
- **Two globs in its sweep script (`test/check_fixtures`, `test/types_fixtures`) do not exist** and
  contributed nothing — **recorded in the row rather than left to inflate the corpus claim.** That is
  the *"a sweep scope is itself an encoded fact"* discipline, applied unprompted to its own evidence.
- **Seed re-mint: judged unnecessary and FLAGGED rather than assumed.** I agree, and the reasoning is
  right: **C3a passed byte-for-byte against the seed-bootstrapped converged reference, which is
  exactly the comparison a stale seed fails.** `refresh_seed.sh` not run.

### Deferred debt

`test/snapshots/compiler/typecheck.md` and `test/selfproc_goldens/legA/types.typecheck.golden` —
the latter **additive-only** this time (new bindings, nothing deleted or re-typed), unlike Phase 1's.
**Blessed by nobody.**

---

*(Phase 2′ continues. Next: the reader repoint + the router/stamper population, which RUN-B-009 requires to move TOGETHER.)*
