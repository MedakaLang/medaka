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
fills** — `ast.mdk:706-712`'s S-1 under-application. A run whose purpose is draining S0s would
have introduced one.

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
**`ast.mdk:706-712`'s S-1 under-application** — the same failure class RUN-B-009 rejected for
Phase 2. The two highest-risk items in this sprint are now the same shape.

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

*(P0-Q's probes are appended below when they land.)*
