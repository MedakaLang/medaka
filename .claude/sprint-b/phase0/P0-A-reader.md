# P0-A — B-2.1, the evidence reader (#1113 part; #1317's T1 half)

**Agent:** P0-A (Phase 0, read-only). **Tree:** `arch/stage-b-sprint` @ `2b9dc798`
(`git rev-parse HEAD` in `/root/medaka/.claude/worktrees/giggly-tinkering-rainbow`, branch
confirmed `arch/stage-b-sprint`). Every line number below was read on that commit.
**Binary:** not used. `./medaka` was not invoked and no claim here depends on it; every
finding is derived from source + the committed specs/ledgers. Two claims are explicitly
marked as owing a first-hand probe.

---

## 0. Headline — two refusals and a fix, up front

1. 🚨 **REFUSED AS STATED: "retire `universeKeyBucketsRef` / `KeyBuckets` / `keyForSite*` BY
   DELETION" is not one unit and cannot be B-2.1's.** Those three have three different
   owners. Derived, code lines only:

   ```sh
   grep -n 'keyForSite' compiler/types/typecheck.mdk | grep -v '^\([0-9]*\):[[:space:]]*--'
   ```
   → `15286`, `17872-17873` (def), `18557-18558` (def), `19011`, `19039`, `19054`.
   **Every one takes its table as the `keyTable` *parameter*, threaded from a
   `buildKeyTable` result — none reads `shadowKeyTableRef` or `universeKeyBucketsRef`.**
   `keyForSite*` is the ROUTE-WORD source; it retires with the `Route` change (B-2.2) and the
   engine word-set retirement (B-2.4). The tree says so itself, twice:
   - `compiler/TYPECHECK-TARGET-ARCHITECTURE.md` (the "what impls exist" table, the
     `KeyBuckets` row): *"`universeKeyBucketsRef` / `buildKeyTable` / `keyEntryOf` /
     `matchingEntries*` / `keyForSite*` / `headCollides*` / `implExistsForHead`
     (`KeyBuckets`) … **DEFERRED → B-2, by DELETION.** Must not appear in the diff"* — B-2,
     not B-2.1.
   - `typecheck.mdk:21557-21561`: *"**T1's counters retire WITH #1113 (B-2)** … B-2's blast
     list already names `keyForSite*` and the `KeyBuckets` slices **alongside the emitter
     word-set retirement**, and at that point they are DELETED … rather than re-keyed."*
     The coupling is to the emitter, i.e. B-2.4.

   What B-2.1 *can* delete is narrower and exact — see §1 and the deletion budget in §5.

2. 🚨 **REFUSED AS STATED: B-2.1 cannot repoint `concreteReqMatchByIface` at `IE` on both
   arms, because `IE` is EMPTY on the Flat path.** `typecheck.mdk:1854` — *"`declEnvsRef` is
   EMPTY on Flat"* (also `:17191`), and the `IE` block header itself, `:3965-3966`: *"The
   Flat path is untouched and still builds its own `buildImplUniverse` over its whole
   program — that shim retires at **E-4**, not here."* E-4 is out of this sprint's scope
   (§1 of the contract: *"Everything in Stages C, D, E, F"*). The resolution is **not** to
   leave two arms reading two registries (design law L1) — it is bite **B-2.1-a** below,
   which seats the Flat program as a one-module `ImplEnv` so the reader has ONE substrate on
   both arms. That is an architectural addition and is flagged as a decision point, not
   decided by an implementer.

3. ✅ **The declaration-index defect FIXES ITSELF, by deletion, in exactly this unit** — and
   the IE-backed replacement does **not** inherit it. Full ruling with clause citations in
   §3. This is the item the brief called highest-value and the answer is a clean (b), with
   one named residue that must not move.

---

## 1. The reader sets, derived (not sampled)

```sh
grep -n 'shadowKeyTableRef'    compiler/types/typecheck.mdk | grep -v '^\([0-9]*\):[[:space:]]*--'
grep -n 'universeKeyBucketsRef' compiler/types/typecheck.mdk | grep -v '^\([0-9]*\):[[:space:]]*--'
grep -rn 'shadowKeyTableRef\|universeKeyBucketsRef\|KeyBuckets\|keyForSite' compiler/ --include=*.mdk \
  | grep -v 'types/typecheck.mdk'
```

**`shadowKeyTableRef` — 2 writers, 3 readers, complete:**

| line | role | path | classification |
|---|---|---|---|
| `6726` | field decl (`Ref (OrdMap (List KeyEntry))`) | — | — |
| `6821` | init `Ref omEmpty` | — | — |
| `20347` | **write**, `buildKeyTable fullUniverse` | Flat | whole-program ⇒ already graph-global |
| `20348` | **write**, `crossRun.value.universeKeyBucketsRef.value` | Module | **cumulative topological prefix** |
| `11216` | **read** `implExistsForHead … mname head`, in `inferShadowApp` | both | 🟡 **SHADOW** (#616) |
| `11503` | **read** `implExistsForHead … name head`, in `definerReceiverDispatches` | both | 🟡 **SHADOW** (#616) |
| `21715` | **read** `selectImplEntryByIface … iface args`, in `concreteReqMatchByIface` | both | 🔵 **EVIDENCE** (DICT §3 `inst`) |

**`universeKeyBucketsRef` — 1 writer, 1 reader, complete:**

| line | role |
|---|---|
| `5883` | `CrossRun` field decl |
| `6005` | init |
| `25755` | **write** (`appendUniverseAccums`): `bucketKeyEntries (flatMap keyEntryOf prog) <itself>` — the cumulative fold |
| `20348` | **read** — the ONLY one, and it is the copy into `shadowKeyTableRef` |

**Consequence, and it is the whole shape of the unit:** `universeKeyBucketsRef` is reachable
by *nothing* except the three `shadowKeyTableRef` readers above. So its deletion is gated on
**all three** moving — the evidence one *and* both shadow ones. A B-2.1 that moves only the
evidence reader (which is the S0 drain) leaves `universeKeyBucketsRef` alive, serving the two
shadow readers alone. That is a legitimate, landable intermediate state and I recommend
cutting the unit so it is reachable (see §5, and the STOP-AND-LAND gate).

**Nothing outside `typecheck.mdk` touches either ref.** The cross-file hits are all
*comments* in `core_ir_lower.mdk` (`:861`, `:1260`, `:1332`, `:1335`), `llvm_emit.mdk`
(`:1352`, `:1469`, `:1481`, `:1502`, `:5312-5313`) and `registry.mdk` (`:455`, `:681`) —
they describe `keyForSite`'s route word, which B-2.1 does not move. Verify with the third
grep above; separate code from commentary.

---

## 2. 🚨 The SHADOW-semantics ruling (brief item 2)

### 2.1 What the two shadow readers ask

`implExistsForHead : KeyBuckets -> String -> HeadKey -> Bool` (`:14857-14862`) — *"does some
impl in [keyTable] define method [name] at head tycon [tag]?"* It is a **method-name
membership + head-tag existence** question, not a selection: it never calls
`pickMostSpecificEntry`. Both call sites use it as the S2 *live-impl / no-impl* predicate:
- `inferShadowApp:11203`, reader `:11216` — the IMPORTER-shadow per-receiver rule (Fork 1).
- `definerReceiverDispatches:11498`, reader `:11503` — the definer arm's `otherwise` leg.

### 2.2 Ruling: **they MOVE — re-based onto `IE`, deliberately, and it is a CONFORMANCE FIX**

Licensing clauses, quoted:

- `docs/spec/SHADOW-SEMANTICS.md:183-186` (§0, *Live impl / no-impl*): *"the receiver's head
  tycon does, or does not, have an `impl` of the shadowed interface — tested against S2's
  **graph-global** impl universe (§1.0), never filtered by what `M` can name."*
- `:226` (§1.0 scope table): *"**graph-global** | ranges over **every** module of the loaded
  graph, whether or not any import path reaches it — `DICT-SEMANTICS.md` §8 **I5** | S2's
  **impl universe** only."*
- `:36-37` (the 2026-08-06 ruling): *"S1's interface operand is scoped to what the module can
  NAME; **S2's impl universe stays graph-global**."*

**And the tree is currently in divergence from that, derivably.** `typecheck.mdk:14967-14970`
defends the two reads like this: *"that universe is GLOBAL by design — **local ∪ imported ∪
prelude**, see the P0-19 d8 note."* But `SHADOW-SEMANTICS.md:241-245` retires exactly that
phrase, by name: *"Beware in particular that "local ∪ imported ∪ prelude" is **not** a
synonym for graph-global — it is strictly narrower than I5's instance universe, **an older
wording of S2 used it as one anyway**."* And the actual table on the Module path is narrower
still: `universeKeyBucketsRef` is the **topological prefix** (grown per module at `:25755`,
copied at `:20348`) — not local ∪ imported ∪ prelude, and not graph-global.

So: repointing `:11216` and `:11503` onto `IE` is **S2 conformance**, licensed by
SHADOW §0 + §1.0 + the 2026-08-06 ruling, not an incidental widening. It is nonetheless an
**acceptance change in a second spec**, and therefore gets its own bite, its own `DEBT.md`
row, and its own `nearest miss:` — it must not ride inside the evidence bite. This is
precisely the door RUN-045 closed to Stage A (*"It also feeds `implExistsForHead`/shadow
semantics (#616), so touching it is an unbudgeted widening"*): budgeted here, with the clause.

**Direction of the delta, stated so a reviewer can attack it.** Widening the universe makes
`implExistsForHead` answer `True` for more receivers ⇒ **more occurrences DISPATCH and fewer
call the standalone**. For a definer shadow (`:11500-11503`) that is the arm S2's inversion
exists to restrain, so the widening moves the compiler *toward* the pre-inversion behaviour
on receivers whose impl lives in a non-prefix module — and the inversion's own rationale
(`:11474-11488`: a top-level name written in a module is THAT MODULE'S NAME) is about
*whether the universe is consulted at all*, not its extent. It is consulted here only on the
`otherwise` (non-definer-shadow) leg, so the definer-shadow inversion is untouched. ⚠️ **That
last sentence is a source reading and is the one claim in this document I could not probe
(no binary). It must be verified first-hand before B-2.1-c lands**, because if the widening
reached the definer arm it would be a silent re-erasure of the user's function — the exact S0
S2 was written to fix.

**⚠️ The gate that grades this cannot be run two-armed.** `test/diff_compiler_shadow_semantics.sh`
hardcodes `$ROOT/medaka` — it is the notable non-overridable gate, filed as **#1431**. Derive
the overridable set with a script file (not inline; the harness mangles `${…}` in quoted
inline args):

```sh
grep -rln 'MEDAKA="${MEDAKA:-' test/*.sh
```

So a base-vs-branch shadow differential needs a second worktree, and that cost belongs in
B-2.1-c's plan rather than being discovered by the implementer.

### 2.3 The alternative I rule against, and why

Keep the shadow readers on a prefix-scoped `KeyBuckets` and move only the evidence reader.
It is cheaper and it is *available* (it is exactly the intermediate state §1 describes). I
rule against it as an END state, because it leaves two answers to "does an impl exist" in one
compile — the L1 hazard `:20240-20243` retired the `obUniv*` accumulators to avoid — and it
strands `universeKeyBucketsRef` (and with it the whole cumulative `bucketKeyEntries` fold and
its index defect, §3) alive with a single vestigial consumer. As a *staging* state inside the
sprint it is fine and is how the bites are ordered.

---

## 3. 🚨 The declaration-index defect — where the property goes (brief item 3)

### 3.1 The defect, quoted

`bucketKeyEntriesFrom` (`:17743-17750`): *"the per-module declaration-index numbering is
UNCHANGED. This function still starts at 0 on every call and `appendUniverseAccums` still
re-enters it once per module with a non-empty accumulator, so indices still **DUPLICATE
across modules** within one bucket of `universeKeyBucketsRef` and each module's slice is
still prepended (descending). That is the property `candidateBucket`'s doc-comment records
as violating `mergeByDeclIdx`'s ascending precondition; re-keying the buckets does not touch
it, and repairing it is not this unit's change."*

`candidateBucket` (`:17975-17984`) names the reach: *"It does NOT hold for
`universeKeyBucketsRef`, and that table reaches this merge on EVERY MULTI-MODULE COMPILE …
`checkBodyImpl`'s Module arm copies it into `shadowKeyTableRef`, which
`concreteReqMatchByIface` reads → `selectImplEntryByIface` → `matchingEntriesByIface` → here.
So `mergeByDeclIdx`'s ascending-operands precondition is VIOLATED on that consumer and its
output order there is deterministic but arbitrary."*

### 3.2 RULING: **(b) FIXED — and fixed by DELETION of the defective consumer, not by repair.**

Three legs, each derived:

**Leg 1 — the defect's only live consumer is the thing B-2.1 deletes.** `bucketKeyEntries`
has exactly two callers: `buildKeyTable:17733` and `appendUniverseAccums:25755`. The
precondition holds for the first — `buildKeyTable` passes `omEmpty` and applies
`omMapValues reverseL` per bucket, so both merge operands are in forward declaration order
(`:17967-17973`, which says exactly this). It fails only for the second. Delete the `:25755`
writer with `universeKeyBucketsRef` and **`buildKeyTable` becomes the sole caller ⇒ the
ascending precondition holds tree-wide, with `bucketKeyEntriesFrom` byte-unchanged.** The
defect is retired at the point where it was live, by removing the violating consumer. That
is why the A-2.2b deferral (*"repairing it is not this unit's change"*) was correct rather
than lazy: the repair *is* this unit's deletion.

**Leg 2 — the IE-backed replacement does not inherit it, because its index is globally
unique and ascending.** The replacement's candidate lists are the two `IE` buckets:
`ieConcrete` keyed `regKeyNTab [ifaceTab, headTab]` and `ieHeadless` keyed
`regKeyOfTab ifaceTab` (`ieInsertRowAt:4243-4249`). Both are written with **`mregAppendK`**,
which appends (`compiler/types/registry.mdk:703-708`: `vs ++ [v]`), and the write order is
`buildImplEnv`'s single fold over modules in ordinal order (`:4119-4128`). Each row carries
`InstRef mid ord seq` where `seq` is a **whole-graph running counter**
(`implRowsOf:4185-4189`; `:4117-4118` — *"The sequence number runs across the WHOLE build
(not per module)"*). Therefore `instRefSeq` is (i) duplicate-free across the entire graph and
(ii) ascending within each bucket. **Keying the merge on `instRefSeq` satisfies
`mergeByDeclIdx`'s precondition by construction**, and the resulting order is graph-global
forward declaration order restricted to the two buckets — which is what the route path's
`buildKeyTable` already gets, now available on the multi-module path for the first time.

⚠️ `InstRef`'s own header (`:3980-3995`) warns it is *"UNIQUE WITHIN ONE COMPILE — AND **NOT
STABLE ACROSS COMPILES**"* and that B-2 should not derive a **NAME** from `seq`. That warning
is about emitted symbols (B-2.2/B-2.4's business). Using `seq` as a **within-compile ordering
key** is precisely the *"within-compile discriminator it is"* that same paragraph endorses.
Do not let a reviewer collapse the two uses.

**Leg 3 — the *semantic* dependence on that order is specified away, and its residue must
not move.** `docs/spec/DICT-SEMANTICS.md:293-295`: *"the `inst` rule below therefore needs a
**tie-break**, and the tie-break must be a property of the instances and the goal alone —
**never of search order, declaration order, or resolution position**."* So list order is
*not* licensed as a tie-break at all. Where it can still decide an answer is the documented
residue: `pickMostSpecificEntry`'s no-unique-minimum arm is a hard `T-AMBIGUOUS-INSTANCE`
reject **only at a CLOSED goal** (#1155 / F-3c), because §6.2 **T4** defers a non-closed
goal rather than deciding it; at a non-closed goal the arm still silently returns the head of
the list (DICT §11, the `§3 specificity` row; `candidateBucket:17991-17998`; tracked #1183).

**Therefore B-2.1's obligation on the residue is: do not widen it and do not narrow it.**
Concretely — the head-of-list answer at a non-closed, no-unique-minimum, multi-module goal
**changes** under this bite, from "deterministic but arbitrary" (descending per-module slices)
to "graph-global declaration order". That is a strict improvement in the direction the
permutation differential can see (`diff_compiler_dict_semantics.sh` §4 — `:17960-17965`
records that the gate is *structurally blind* to bucket-order tie-breaks and *can* see
declaration order), but it **is an observable delta and belongs in `could move:` verbatim**.
It is emphatically **not** licence to implement T4 — DICT §11 carries a normative *"T4 MUST
NOT be implemented before I5"* constraint, and closing that residue is T4's work.

**Not (c).** The tie-break is *forbidden*, not *specified*, so there is no clause that makes
the order irrelevant; the residue survives as a known non-conformance with an owner.
**Not (a).** Inheriting would require reproducing a restarting per-module counter, which the
IE substrate does not have and would have to be invented.

---

## 4. The `IE` reader surface — what exists, and what a repointed reader still needs (brief item 4)

### 4.1 What `IE` offers today

| thing | site | shape |
|---|---|---|
| `ImplRow` | `:4058-4059` | `ImplRow Int InstRef IfaceRef (List Ty) (List Require) (List String)` — ordinal · identity · iface identity · full head types · context · method names. **Positional, not a record** — `:4015-4038` records the measured LLVM `CFieldAccess` panic that forces this. Do not "improve" it. |
| accessors | `:4061-4068` | `ieRowOrd`, `ieRowInst`, `ieRowTriple` (→ `(IfaceRef, List Ty, List Require)`) |
| `InstRef` | `:3996-4002` | `InstRef String Int Int` (mid · ord · seq) + `instRefMid`, `instRefSeq` |
| `ImplEnv` | `:4075-4105` | `ieRows : List ImplRow` (whole graph, build order) · `ieConcrete`/`ieHeadless : MultiRegistry ImplRow` · `ieIfaceTags` · `ieUnivSnaps : List (Int, ImplUniverse)` |
| read accessors | `:4288-4289`, `:4345-4347` | `ieUniverseAt : Int -> ImplEnv -> ImplUniverse` (candidacy, via `ieSnapAt`) · `ieRowsVisibleAt : Int -> ImplEnv -> List ImplRow` (decl-time existence) — both through `ieCandidacyVisibleAt`, which is `True` ⇒ graph-global |
| population | `buildImplEnv:4119` ← `buildDeclEnvs:2769` | once per driver, in the driver **preamble** (`:3426`), i.e. **before** any module body is checked ⇒ available to the inference-time reads at `:11216`/`:11503` |
| the one production read | `moduleImplUniv:20303-20307` | `Module` arm only; `Flat` arm is `emptyImplUniverse` |

### 4.2 What the repointed reader needs that `IE` does not expose

1. **A `List ImplRow` candidate read for a (iface, goal-head) pair.** `ieUniverseAt` is the
   wrong accessor: it returns an `ImplUniverse`, whose buckets hold bare
   `(List Ty, List Require)` pairs (`insertUnivImplAt:21382-21397`) — **identity is
   projected away**, so it can never serve B-2.2's `InstId`, and it has no min⊑ selector.
   `ieRowsVisibleAt` returns rows but is `O(rows)` per call with a 🚨 PERF banner
   (`:4340-4344`) forbidding a per-goal caller. **What is missing is a bucketed row read** —
   the `ImplRow` peer of `candidateBucket`: `mregLookupK (regKeyNTab [ifk, hd]) ieConcrete`
   merged with `mregLookupK (regKeyOfTab ifk) ieHeadless`. Both registries already exist and
   are already keyed through the same `oblIfaceKeys`/`dispHeadTab` calls as `KeyBuckets`
   (`:4070-4074`); only the accessor is absent. Cost profile matches the existing hot path
   (two `omLookup`s + a merge), and the `[]`-headless fast path of `candidateBucket:18034-18037`
   should be preserved verbatim for the reason given at `:17948-17954` (`xs ++ []` copies;
   every module of `compiler/`, `stdlib/`, `sqlite/` has an empty headless bucket).
2. **`ieMethods` gets its first reader** (needed only by the SHADOW bite, B-2.1-c, for
   `implExistsForHead`'s method-name membership). `:3964-3966` — *"WHAT IS STILL NOT READ:
   `ieInst`/`InstRef` and `ieMethods`."* (`InstRef` gained a reader at A-3.7 via
   `cohImplOfRow`; `ieMethods` has none.) `:4162-4169` records the field as an *owed*
   per-compile allocation whose named consumer may never arrive — B-2.1-c is that consumer,
   which retires the "drop the field" option.
3. **A Flat-arm `ImplEnv`** — the blocker in §0 item 2. `IE` is empty on Flat.
4. **Nothing else.** Specifically: `reqs` (§3's context) is `ImplRow` field 5, and the head
   types are field 4, so the winner's OWN `requires` — the thing
   `concreteReqMatchByIface:21714-21718` returns and the thing RUN-045 measured as missing —
   is fully present.

### 4.3 The one substrate agreement the implementer must derive, not assume

`keyEntryOf:17805` projects the head with `headTyconTy headTy`; `ieInsertRowAt:4244` projects
with `univReceiverTag tys`. `:2474-2484` asserts the `headTyconTy` (impl) / `headTyconMono`
(goal) pairing holds for **both** tables and warns *"Those two do NOT agree on ORIGIN — only
on the head's SPELLING, which is all either table keys on."* A repointed reader inherits
`IE`'s bucketing, so it inherits whatever `univReceiverTag` does with a head
`headTyconTy` treated differently. **Derive the agreement on a fixture before landing**
(`grep -n 'univReceiverTag' -A8 compiler/types/typecheck.mdk` and compare with
`headTyconTy`); do not take this document's word for it. A disagreement here is a silent
"stops finding impls", i.e. a false `T-NO-IMPL` or a re-armed #1128.

### 4.4 RUN-045's own ledger, for the record

`.claude/sprint/DECISIONS.md` RUN-045: *"`residualPredsOf` → `findMatchingImplReqsU` →
`concreteReqMatchByIface`, which **ignores its `univ` argument** and reads `shadowKeyTableRef`
← `universeKeyBucketsRef`, a **cumulative** accumulator. A-3.6 globalized `IE`; the evidence
reader consults a **second, still cumulative registry**."* And the standing constraint it
leaves: *"Stage A delivers the global instance ENVIRONMENT and is LOUD where evidence cannot
follow. Any claim of C4/I2-by-construction is false."* B-2.1 is the unit that earns the
second conjunct; it should not claim it until the repair round's permutation differential
says so (contract §8).

---

## 5. The bite list

Ordering is a chain: each bite's sites are disjoint, but **b/c/d are only reachable after
a**. `engines:` is per §4 of the contract.

### `B-2.1-a` — seat a one-module `ImplEnv` on the Flat arm (the enabling bite)

**⚑ FLAGGED AS A DECISION POINT, not an implementer's choice.** This adds a construction
`IE` does not have today and is the substitute for E-4, which is out of scope.

- **sites:** `typecheck.mdk:20303-20307` (`moduleImplUniv`'s arm gate — the pattern to
  mirror); a new `Flat` arm binding beside it; one new field on `PerRun` near
  `:6726` (`shadowKeyTableRef`'s neighbourhood) *or* a new arm of the existing
  `:20346-20348` `match mode`.
- **transform:** replace the `:20346-20348` `match mode` that populates
  `shadowKeyTableRef` with one that populates a single `ImplEnv`-valued ref:
  `Flat` → `ieAddRows (implRowsOf "" 0 0 (implDeclFacts fullUniverse)) emptyImplEnv` with
  `ieUnivSnaps` re-derived (`ieBuildSnaps`, per `ieAddRows`'s 🚨 at `:4191-4213` — it does
  **not** maintain the snapshot table); `Module` → `driverState.value.declEnvsRef.value.deImpls`.
  Both arms then feed ONE reader.
- **could move:** nothing on the Module arm (same value it already holds). On Flat, the
  reader's substrate changes table but not content — `implDeclFacts` and `keyEntryOf` walk
  the same `DImpl`s in the same order (`:4150-4160` asserts the lockstep with
  `implDeclsWithReqs`; `keyEntryOf` is the third walk and its agreement is §4.3's owed
  derivation). **Perf can move on Flat:** `ieInsertRow` is `env.ieRows ++ [r]` per row =
  O(rows²) over the build, self-documented as OWED and unmeasured (`:4223-4230`). Flat now
  pays it once per compile over prelude+user impls (low hundreds). **Take the one-line fix
  named there** (cons + `reverseL` once) inside this bite rather than importing a known
  quadratic into the single-file path; `compiler/AGENTS.md` forbids exactly this shape.
- **nearest miss:** a driver that reaches `checkBodyImpl` **without** `buildDeclEnvs` — the
  `wasm_emit_typed_main.mdk` shape at `:4029-4038`. Under this bite that path takes the Flat
  arm and builds its own env, so it is covered; what it does **not** cover is a *Module*-mode
  driver that stamps a module id `buildDeclEnvs` never indexed (`:17231-17232` says no live
  path does, and `declEnvsOrdOf`'s `-1` is *"vacuous here"* per `:20263-20266`). Such a
  driver would silently read the whole graph. Test: a probe entry that calls the Module arm
  with an unindexed mid.
- **engines:** none moved. No route word changes; no LLVM/wasm/eval edit. `IE` construction
  is typecheck-internal.

### `B-2.1-b` — repoint the EVIDENCE reader onto `IE` (**the S0 drain**)

- **sites:** `typecheck.mdk:21714-21718` (`concreteReqMatchByIface`); a new `ImplRow`-shaped
  candidate accessor beside `:4288` (the `IE` accessor block); a new `keyEntryOfRow` adapter.
  `findMatchingImplReqsU:21696-21700` is **unchanged** (it already threads the right `univ`
  for its headless fallback).
- **transform:** `concreteReqMatchByIface` selects over `IE` instead of
  `perRun.value.shadowKeyTableRef.value`. **Keep ONE min⊑ selector**: add
  `keyEntryOfRow : ImplRow -> KeyEntry` — `KeyEntry (methods) (univReceiverTag tys)
  (head tys) (implKeyTc irName tys) irName tys reqs (instRefSeq inst)` — and feed the
  **existing** `pickMostSpecificEntry` / `selectImplEntryByIface` unchanged. Precedent in
  tree: A-3.7's `IE`→`CohImpl` adapter (`cohImplOfRow`, `:15396`) did exactly this for
  coherence. Do **not** write a second selector: DICT §11 (`§6 uniform resolution`) requires
  all resolution paths to perform min⊑, and a second copy is the drift `:14959-14966`
  forbids. Merge the two bucket lists with `mergeByDeclIdx` on the adapter's `instRefSeq`
  index (§3, leg 2), preserving `candidateBucket`'s empty-headless fast path.
- **could move:** 🔴 **A LOT, and this is the point of the unit.** (i) On the multi-module
  path a goal whose impl is declared in a topologically LATER module now recovers that
  impl's `requires` ⇒ a `λd̄.` slot and a route dict appear where there were none ⇒ **emitted
  IR changes** and `T-REQUIRES-UNROUTED` stops firing for that class (see `B-2.1-d`).
  (ii) The tie-break at a non-closed, no-unique-minimum multi-module goal changes from
  arbitrary to graph-global declaration order (§3 leg 3). (iii) The headless fallback
  (`firstReqMatch (univHeadless univ …)`) is now reached under different circumstances,
  because the concrete leg answers `Some` in cases it previously answered `None`
  (`:21689-21693` — the fallback *"is now reached only when the KeyBuckets union has no
  match at all"*; that sentence must be re-derived after this bite). (iv) Any pre-existing
  divergence between `keyEntryOf`'s and `implDeclFacts`' decl walks becomes an acceptance
  delta (§4.3).
- **nearest miss:** the shape whose impl carries **no** `requires`. It never needed a dict,
  so nothing observable moves — but it is the shape SA-4/RUN-055 already used to prove the
  Door-4 predicate was over-firing, and it is the control that shows this bite fixed the
  right thing rather than everything. Second miss: a goal reaching the **headless** leg,
  which this bite does not repoint at all (`firstReqMatch` still reads `univ`); a headless
  impl in a later module is therefore **still** unroutable after B-2.1-b. State that
  explicitly — it is the most likely place a "drained" claim over-reaches. Third:
  `argReqRoute` / `selectReqImpl` (`:19311`, `:19380`) select the winner on the ROUTER side
  over `KeyBuckets`; #1560 measured that desynchronizing the checker from the router yields
  `RNone` and *"the binary still faults"* (`:22205-22211`). **So B-2.1-b changes the CHECKER's
  leg and the router's leg still reads `KeyBuckets`.** If the two now disagree about the
  winner, this bite reproduces #1560. ⚠️ **This is the sharpest risk in the whole unit and it
  is not a `could move:` footnote — it is a gating question for the sub-orchestrator: does
  B-2.1-b have to land together with the router leg (i.e. with B-2.2), or can it land alone?**
  My reading: it can land alone **iff** both legs still compute min⊑ over populations that
  agree — which is exactly what the whole-prefix measurement at `:20287-20302` established
  for candidacy and what nothing has established for these two. **Recommend: the integration
  checkpoint after B-2.1-b runs #1560's and #1564's own fixtures on all four arms
  (`check`/`run`/`build`/built-binary), not just `check`.**
- **engines:** no engine edit; **all three consume changed evidence** (a dict that was never
  built now exists). `diff_compiler_engines` is deferred to the repair round, so this bite
  owes the repair round an eval/native/wasm triple on #1564's fixture. ⚠️ eval is a
  known-wrong oracle on dispatch shapes — do not capture a golden here (contract §5).

### `B-2.1-c` — re-base the two SHADOW readers onto `IE` (§2; **its own bite, its own spec**)

- **sites:** `typecheck.mdk:11216`, `:11503`; `implExistsForHead:14857-14862` + its scan
  `implExistsForHeadGo`; the stale defence comment at `:14967-14970` (which cites the phrase
  SHADOW §1.0 retires — it must be rewritten, not deleted, or the next reader re-derives the
  old claim).
- **transform:** `implExistsForHead` takes `IE` (or the §4.2-item-1 accessor) instead of
  `KeyBuckets`, answering method-membership from `ieMethods` and head existence from
  `ieConcrete`'s `[iface, head]` bucket. Note it is keyed by **method name**, not iface — so
  it must scan `ieMethods` across the iface-relevant rows; `ieIfaceTags` alone cannot answer
  it.
- **could move:** SHADOW acceptance. More receivers dispatch; fewer call the standalone.
  Scoped to the Module path (Flat's `buildKeyTable fullUniverse` was already whole-program).
  This bite is a **conformance FIX** under SHADOW §0/§1.0, and it is also the bite that could
  silently re-erase a user's function if the widening reaches the definer arm (§2.2's owed
  probe).
- **nearest miss:** a definer shadow whose receiver's impl lives in a non-prefix module —
  the program S2's inversion exists to protect (`:11479-11482`'s `eq : List Int -> ...`
  shape, but with the impl in a later module). Under the current tree it calls the
  standalone; after this bite the question is whether `isDefinerShadow` short-circuits
  before the widened universe is consulted. **Test that program specifically.** Second miss:
  an `import`-less module — S1 says an interface `M` cannot name creates no shadow in `M`, so
  the widened *impl* universe must not widen *shadow-hood*; the two operands are separately
  scoped (`SHADOW-SEMANTICS.md:228-245`) and this bite must touch only S2's.
- **engines:** none directly; a changed dispatch/standalone decision changes the `Route`
  (`RKey` vs `RLocal`) at those sites, which all three engines consume. Owes the wasm and
  eval arms an observation in the repair round.

### `B-2.1-d` — delete `universeKeyBucketsRef` + `shadowKeyTableRef` (the deletion budget)

Reachable only after **b and c**.

- **sites:** `typecheck.mdk:5883` (field), `:6005` (init), `:25755` (writer, inside
  `appendUniverseAccums`), `:6726` (field), `:6821` (init), `:20346-20348` (the arm gate,
  already rewritten by `B-2.1-a`); `:27623`'s accumulator comment; the
  `test/registry_keying_ratchet.sh` `cross_allowed` allowlist row (a deletion shrinks it —
  **derive the number with `sh test/registry_keying_ratchet.sh`, never quote one**;
  `TYPECHECK-TARGET-ARCHITECTURE.md`'s own count was measured wrong in both directions,
  RUN-007/RUN-013).
- **transform:** pure deletion. **`KeyBuckets`, `buildKeyTable`, `keyEntryOf`,
  `matchingEntries*`, `candidateBucket`, `mergeByDeclIdx`, `bucketKeyEntries*`,
  `keyForSite*`, `headCollides*`, `countHead*` all SURVIVE** — they serve the route path via
  the threaded `keyTable` parameter (§0 item 1) and retire at B-2.2/B-2.4.
- **could move:** nothing at the language level (deleting an unread ref). What it *does*
  change is §3's precondition: `buildKeyTable` becomes `bucketKeyEntries`' sole caller, so
  `mergeByDeclIdx`'s ascending precondition holds tree-wide. **`bucketKeyEntriesFrom`'s
  ⚠️ comment at `:17743-17750` and `candidateBucket`'s at `:17975-17998` and
  `mergeByDeclIdx`'s at `:18041-18051` all become STALE and must be rewritten in this bite** —
  each currently documents a live defect that this deletion retires, and leaving them is how
  a later agent "rediscovers" a fixed bug.
- **nearest miss:** a fourth reader of either ref introduced between Phase 0 and Phase 2.
  Re-run the two greps in §1 immediately before this bite; if the sets are not
  {11216, 11503, 21715} and {20348}, **STOP and report** — the region changed under the unit.
- **engines:** none.

### `B-2.1-e` — the Door-4 reject: verify unreachable for #1564's class, **do not delete**

- **sites (assertion set, derived — `grep -rn 'UNROUTED' compiler/ test/ docs/`):**
  code `typecheck.mdk:22236-22241` (`unroutedGroundReqs`), `:24936-24941`
  (`unroutedResidual`), `:24974-24975` (`requiresUnroutedMsg`), `implMatchesWithReqsU:22253`;
  assertions `test/diff_compiler_check_cli_modules.sh:1964-1966` (D4b), `:2268` (SA-4b),
  `:2303` (SA-4c); `test/must_fail_fixtures/1564-import-order-decides-conditional-impl-candidacy/claim.txt`
  (its `diag-code:` line is `T-REQUIRES-UNROUTED 2:16-2:21`);
  `test/import_order_fixtures/evidence-unroutable-invariant/case.txt`;
  `test/import_order_fixtures/conditional-impl-evidence-routed-invariant/case.txt`;
  `test/r2_widening_fixtures/1558-a36-candidacy-graph-global/claim.txt`;
  `compiler/DIAGNOSTIC-CODES-DESIGN.md:189` (whose own row says *"this code **drains** when
  that lands"*).
- **transform:** **do NOT delete the guard.** Verify it no longer fires for the #1564 class
  (which is the drain), update the fixtures that assert the reject, and mark the
  `DIAGNOSTIC-CODES-DESIGN.md` row drained-for-that-cause. Keep the guard: its own row names
  a **still-open** neighbouring class (*"it does not cover the no-impl-anywhere partially-ground
  shape, which is still silent — issue 1578"*), and deleting a loud reject that still has a
  live class is precisely the loud→silent severity increase `AGENTS.md` and the contract
  forbid. If it turns out to be provably unreachable, that is a separate, argued deletion.
- **could move:** programs that were `check` exit 1 become exit 0 — an **accept-widening**,
  which owns its assertion sites (all of the above). ⚠️ The corresponding must-fail pin
  flipping RED is a *deliverable* (contract §1), not a break, and the flip must be observed
  **twice on a quiescent tree** (5 phantom DRAINs in Stage A).
- **nearest miss:** the shape the guard is *right* about — a goal whose matching impl is
  genuinely unroutable for a reason B-2.1 does not fix, i.e. the **headless** leg
  (`B-2.1-b`'s second miss). If that still exists, the reject is still needed and a
  "drained" claim on #1564 must say which sub-class drained.
- **engines:** none. Diagnostic-only ⇒ ⚠️ **value goldens are structurally blind to it**
  (memory: value-golden gates cannot see a diagnostic-only change). Grade with
  `check --json` and the `code` field, and remember `check --json`'s own multi-module
  silent-accept hole (#1362, OPEN S0) — corroborate with human `check`.

---

## 6. Scope boundary (brief item 5) — clean

**No bite above drains #1046 or #1075.** Both reach dispatch through a **local lambda**, so
arg-tag survives at their sites until locals carry evidence (contract §1, routed to **F-1**).
Every site B-2.1 touches is a *top-level* obligation/residual/shadow site reached from
`checkBodyImpl`'s arms — `residualPredsOf`/`checkOneCallObligation`/`inferShadowApp`/
`definerReceiverDispatches`. Nothing here changes what a local binding carries, and B-2.3
(frozen admissibility) is the unit that touches arg-tag at all. **If an implementer finds a
bite of theirs draining #1046 or #1075, that is the signal they have left scope.**

Adjacent nodes I deliberately did **not** touch: `SupersPath` (contract §1's ruling — not
mine), #1265's default-arm registry (constrained OUT of `IE` by §9.3, quoted at `:3945-3951`
— *"NO `IE` KEY COMPONENT MAY BE A METHOD NAME"*; B-2.1 adds no method-keyed `IE` component,
so it does not prejudge that adjudication), #1597, #1114.

---

## 7. What I did not verify, and why

- **No binary.** `./medaka` was not available/used (a `make medaka` was running in the trunk
  per my brief; I was instructed not to depend on it and not to build). Consequences: §2.2's
  definer-arm short-circuit claim, §4.3's `univReceiverTag`/`headTyconTy` agreement, and
  every `nearest miss:` are **stated as tests to run**, not as results. None of the
  structural claims (reader sets, spec clauses, ownership) depends on a binary.
- **`ieMethods`' exact adequacy for `implExistsForHead`** — the method-name axis. `ieMethods`
  holds `map implMethodNameTc methods`, the same projection `keyEntryOf:17805` uses for
  `KeyEntry`'s first field, so it should be identical; I did not diff `implMethodNameTc`'s
  two call sites for a wrapper.
- **`registry_keying_ratchet.sh`'s current `cross_allowed` value** — deliberately not quoted.
  Derive it.
- **Bite sizing.** `B-2.1-b` is the largest and I have not proven it is Sonnet-sized under
  §4's test; the adapter + accessor make it *statable* as a transformation over named sites,
  but its `nearest miss:` #1560 coupling question may force it to merge with B-2.2. That is
  a sub-orchestrator call, flagged, not resolved.
