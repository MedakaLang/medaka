# P0-E — Phase 3: the namespace follow-ons (#1354, #1319) + #991 / #1111 / #1112 status

**Agent:** P0-E (architecture, read-only). **Trunk:** `/root/medaka/.claude/worktrees/wiggly-giggling-nygaard`,
branch `arch/stage-a-sprint`, BASE `7aae8b83`. **Date:** 2026-08-12.

**Nothing in this file was written to a tracked source file. No build was run.** Every probe below was
run with the trunk's already-built `./medaka` under `MEDAKA_STRICT=1`; every symbol named was grepped
in this worktree before it was written down.

**Epistemic labels used throughout:** **DERIVED** (I ran the command / read the `file:line` in this
worktree) · **RELAYED** (taken from an issue, PR or in-tree ledger, not re-derived) · **INFERRED**
(reasoned from DERIVED facts, not run) · **OWED** (not established in either direction).

---

## 0. Headline — five findings that change the sprint's Phase-3 plan

1. 🚨 **#1351's blocker is GONE and nobody has recorded it.** The two adopted scoping passes on #1354
   (2026-08-07, 2026-08-09) both state that M-1 (#1351) **cannot be graded** because *"#1351's correct
   answer is NOT derivable from today's spec"*, and that a SHADOW-S1 spec successor was *"being filed"*.
   **That successor was never filed — and it did not need to be: the ruling landed in the spec itself.**
   `docs/spec/SHADOW-SEMANTICS.md:971-1052` carries **🔒 S2-DECL — RULED 2026-08-09 (#1351)**, five
   sub-clauses (a)–(e), which specify the receiver argument, the pairing rule, the admitted set, the
   cardinality choice *including a located reject*, and order-invariance as a gateable rule. **DERIVED**
   (`grep -n 'S2-DECL' docs/spec/SHADOW-SEMANTICS.md`; read in full at `:968-1052`).
   ⇒ **M-1 is fully specified and implementable this sprint.**
2. 🚨 **M-1's "Step 0, blocking" is also discharged by the same document.** The 2026-08-09 pass made M-1
   conditional on first naming *"the emit-path decision site E1b could not move."* The spec's own
   conformance matrix names it: `SHADOW-SEMANTICS.md:1746` records, **MEASURED 2026-08-09**, that the
   build arm *"reads **no** dispatch-index table at all: the receiver is argument 0, positionally"*, via
   `definerShadowArgHead` → `importerShadowOnEmitPath` → `inferDefinerShadowApp`. All three symbols
   **DERIVED** present (`typecheck.mdk:10942`, `:10965`, `:10976`). ⇒ M-1 is a **two-arm** unit, and the
   S7 trap (moving `run` alone) is a known, named hazard rather than a discovery waiting to happen.
3. **#1319 unit 4 is NOT drained, and it is NOT Phase 3's.** `importedCtorTypeDecls` still exists and is
   still called (`typecheck.mdk:26234` def; live callers at `:19782` and `:26732`) — **DERIVED**.
   #1512's body owns it (*"absorbs #1319 unit 4"*), #1512 is **OPEN**, and the sprint's own scope table
   puts #1512 in **Phase 1**. ⇒ Phase 3 must not schedule unit 4; it should *inherit* it.
4. **What A-3.2b actually drained from #1319 is a different row.** `universeFieldOwners` is **deleted
   from `CrossRun`** (`typecheck.mdk:5538` records the retirement) — **DERIVED** — but the ratchet states,
   verbatim, that this is **"NEUTRAL, NOT A DRAIN"**: *"#1216 (S0) and #1383 (S1) reproduce unchanged, and
   the type-REACHABILITY predicate that would fix them is still owed to a later unit"*
   (`test/registry_keying_ratchet.sh:201`). **RELAYED**, quoted from the file. ⇒ #1319's remaining Phase-3
   surface after Phase 1 is **#1383 + #1216 (the field-owner reachability predicate)** — one unit, not four.
5. 🚨 **A symbol pair cited in three ledgers does not exist in the tree.**
   `methodIfaceTableRef` / `methodIfaceIndexRef`, cited as `compiler/backend/emit_support.mdk:449-464` in
   **#1112's body**, in `compiler/TYPECHECK-TARGET-ARCHITECTURE.md:1806`, and in #1354's 2026-08-09
   scoping pass §Q5 — **DERIVED absent**: `grep -rn 'methodIfaceTableRef\|methodIfaceIndexRef' compiler/`
   returns **only `.md` files**, and `grep -n 'methodIface' compiler/backend/emit_support.mdk` returns
   **zero** hits (the file is 552 lines). The real substrate is `EmitInputData.methodIfaces` /
   `.methodIfaceIndex` (`compiler/backend/llvm_emit.mdk:727`, built at `:748`, read by
   `methodIfaceOfInput` `:481` and `methodArityOfInput` `:486`) and its wasm peer
   (`compiler/backend/wasm_emit.mdk:460-471`). This is the #1574 class in a doc the symbol gate does not
   scan. **The claim it supports — that the method namespace's bare-name surface extends into both
   backends — is TRUE; only the citation is wrong.**

---

## 1. #1354 — the method namespace

### 1.1 Both S0s REPRODUCE first-hand (not relayed)

Run on the trunk binary, `MEDAKA_STRICT=1`, no staleness warning on stderr:

```
#1351  check main.mdk          exit 0   "main : Unit"   (zero diagnostics)
       run   main.mdk          exit 0   7
       run   control.mdk       exit 0   99
       run   order-swapped.mdk exit 1   Type mismatch: Int vs String @ 10:20

#1276  check main.mdk          exit 0   "main : Unit"   (silent)
       run   main.mdk          exit 0   2
       run   control.mdk       exit 0   1
```

Fixtures: `test/must_fail_fixtures/1351-methoddispatchidx-import-order-collision/` and
`.../1276-alias-method-provenance-erased/`. **DERIVED** (script at
`/var/tmp/medaka-scratch/.../scratchpad/repro.sh`). Import-line order alone decides #1351's verdict, as
the issue title says.

### 1.2 The adopted unit split — CONFIRMED, with one member already drained

The split is **already adopted on the issue** (2026-08-09 comment, *"Adopted (2026-08-09 roadmap-structure
review, amendment A-5)"*): **M-1 = #1351**, **M-2 = #1276 + #1265 (+ #1386 coupling)**. **RELAYED.**
I re-derived the two facts it rests on and **confirm both** (§1.3, §1.4).

**Unit A (#1353) has LANDED** (PR #1419) — #1353 is **CLOSED** (**DERIVED**, `gh issue view 1353`), and
the tree carries its artefacts: `nameableIfaceShadows` (`typecheck.mdk:25062`) wrapping both shadow-set
reads (`:19613`, `:19617`), plus `graphIfaceMethodsRef` in the ratchet's `driver_allowed` labelled
*"#1354 unit A (#1353/#1380)"* (`test/registry_keying_ratchet.sh:233` region). ⇒ **#1354's owned set is
now two, not three.** Its body still says "owns #1276, #1351, #1353".

**Partial-identity check, done as the SET rather than one table** (per the standing finding): of #1354's
five rows, `universeMethodIdentsRef` and `universeMethodCollidedRef` are identity-keyed (✅),
`universeIfaceMethodsRef` is still bare **but its read is now visibility-scoped** (unit A — the fix was a
predicate at the read, not a re-key; the row is still in `cross_allowed`),
`universeMethodIfaceParamsRef` is still bare + overlaid (#1276), `universeMethodDispatchIdxRef` is still
bare + first-match (#1351). **DERIVED** — all five present at `typecheck.mdk:5526-5534`, plus
`methodDispatchIdxRef` (`:4836`) and `argDispatchIdxRef` (`:4828`) which the `universe*` grep cannot see.
**The namespace is still partially keyed; reading only `universeMethodIdentsRef` still says "done".**

### 1.3 M-1 (#1351) — now spec-driven. **6 bites.**

**The target value is DERIVED FROM SPEC, not captured.** `main.mdk` imports `fmodI.{mth}`,
`amodI.{af}`, `zmodI.{IZ, zf}` (**DERIVED**, read the file). Under S2-DECL (c) the admitted set is
`{IZ}` — `IA` is not nameable. Exactly one ⇒ (d) first arm ⇒ `IZ` decides: its receiver argument is
argument **1** (`mth : Int -> b -> Int`), which is the `5`, an `Int`, and no `impl IZ Int` exists ⇒ the
standalone denotes ⇒ **99, at every ordering**. The spec states this same conclusion at `:1041-1047` and
flags it **"PREDICTED UNDER THIS CLAUSE, not measured — no binary implements it yet."**

The graded instrument exists: `test/diff_compiler_import_order.sh`,
`test/import_order_fixtures/1351-methoddispatchidx-import-order-collision/`, ledger row
`test/IMPORT-ORDER-LEDGER.txt:120` with two distinct signatures pinned. **DERIVED.**

| id | description | named sites (all grep-verified in this worktree) | transformation | deps |
|---|---|---|---|---|
| **M1-a** | Build the per-module **admitted-declaration** set (S2-DECL (c)) | `nameableIfaceShadows` `typecheck.mdk:25062`; `graphIfaceMethods` `:25748`; `selectIfaceRows` `:25821`; `graphIfaceMethodsRef` (DriverState) | Add one function returning, for a method name `N` and module decls `prog`, the **list of admitted declarations** (`IfaceRef` + `typarams` + `mty`) rather than unit A's boolean. Unit A's predicate is the same S1-NS (a) test collapsed to a Bool; this exposes the candidates. No table changes. | — |
| **M1-b** | Retire `methodDispatchIdx`'s bare first-match read; take the receiver argument from the **admitted declaration** (S2-DECL (a)+(b)) | `methodDispatchIdx` `:8210`; `recordRLocalSite` `:8184` (its sole caller); `universeMethodDispatchIdxRef` `:5534`; `methodDispatchIdxRef` `:4836`; write site `:19639`; `argDispatchOfMethod` `:5800`; `firstDispatchIdx` `:5816` | Replace `lookupAssoc name driverState…methodDispatchIdxRef` with `firstDispatchIdx` applied to the M1-a entry's own `(typarams, mty)`. Delete the two dispatch-index accumulators' **index payload**. ⚠️ `argDispatchIdxRef`'s **name set** (`argNames`, `:13746` / `:27055`) is a different use and **stays**. | M1-a |
| **M1-c** | Make the impl query ask about **that declaration's** interface (S2-DECL (b)+(c)) | `resolveRLocalSite` `:14624`; `implExistsForHead` `:14490`; `implExistsForHeadGo` `:14524` | Thread the admitted declaration's `IfaceRef` into the existence query, so it asks *"an impl of `I` at head `T`"* rather than *"an impl of anything declaring a method named `N`"*. ⚠️ **Must-not-absorb re-check owed at implementation time, explicitly:** these touch `KeyBuckets`. The restated criterion (adopted 2026-08-06 on #1354) is *does the row supply `dispHeadTab` or the head-key equality?* — `implExistsForHead` is an **existence scan**, not `countHead`/`headCollides`/`keyForSite`. **RELAYED** from the 2026-08-09 pass; re-derive before editing. | M1-b |
| **M1-d** | The **emit arm** — peel the receiver argument, not argument 0 | `definerShadowArgHead` `:10942`; `importerShadowOnEmitPath` `:10965`; `inferDefinerShadowApp` `:10976`; `suppressRLocalRecord` `:2644` | Replace the positional first-argument peel with the M1-a receiver argument. **This bite is what makes the unit an S7-safe change**: landing M1-b/c without it converts an agreed-wrong answer into `run` ≠ `build` (measured by the 2026-08-09 pass's E1, **RELAYED**; the spec records the same at `:1746`). | M1-b |
| **M1-e** | The (d) cardinality decision, including the **located reject** for ≥2 disagreeing admitted declarations | the M1-a call site in `recordRLocalSite`; a new diagnostic code in `compiler/DIAGNOSTIC-CODES-DESIGN.md`; rubric `compiler/ERROR-QUALITY.md` | Implement all four (d) arms. **This is the one acceptance NARROWING in the unit** and the spec names it as a cost (`:1038-1040`). Not delegable to a cheap model. | M1-a..d |
| **M1-f** | Ledger + pin bookkeeping | `test/IMPORT-ORDER-LEDGER.txt:120`; `test/must_fail_fixtures/1351-…/claim.txt`; `test/shadow_fixtures/i17_importer_two_ifaces_neither_nameable/` | **DE-LEDGER** row 120 (the ledger's own header forbids re-cutting it); leave the must-fail fixture in place and let it flip red. Confirm `i17` stays green. | M1-a..e |

**Flat-arm behavior (all six bites) — 🚨 I inferred this wrong first, and the tree says the opposite.
Do not repeat my error.** `graphIfaceMethodsRef` (`typecheck.mdk:4824`) is written only at the two
**Module**-mode driver entries, so on the Flat/single-file path the index is empty. My first inference
was that M1-a's admitted set is therefore empty and S2-DECL (d)'s **None** arm applies. **That is
wrong.** Unit A's predicate **fails OPEN on an absent index, deliberately**: `nameableIfaceShadows`
`:25067` reads `| omSize driverState…graphIfaceMethodsRef.value == 0 = names` — the unfiltered list —
and its header (`:25043-25053`) states why in capitals: *"Dropping shadow-hood from an occurrence that
IS one makes it dispatch unconditionally … the S4/#410 class, up to `no impl of method … for type …` on
a valid program and a SIGSEGV variant."* **DERIVED, read in full.**

⇒ **M1-a MUST fail open the same way**, degrading to today's graph-global answer (every declaration
admitted) rather than to "none admitted". Under S2-DECL (d) that puts the Flat arm on the **≥2** arms,
not the **None** arm — so **M1-e's located reject could fire on single-file programs that compile
today** unless the (d) decision is itself gated on the index being present. **This is the single
highest-risk interaction in M-1 and it must be stated in the diff, not discovered:** the sibling failure
(a Module-only field read reached on a Flat path, turning live rejections into silent accepts) is
recorded verbatim at `test/registry_keying_ratchet.sh:201` for A-3.5c, and it is a **severity increase**
in whichever direction it goes.

**Must-fail pins expected to flip RED:**
- `test/must_fail_fixtures/1351-methoddispatchidx-import-order-collision` — **certain** (M1-b/d move
  `stdout: 7` to `99`). Expected red at M1-d, possibly at M1-b.
- `test/must_fail_fixtures/1182-two-ifaces-same-method-name-order-decides` — **possible, and it must
  NOT flip**: #1182 is ruled OUT of this unit (hazard (a) family, stays with #1112/#1113). A red here
  means M1-c reached `keyForSite`'s family. **Treat a #1182 flip as a STOP, not a bonus drain.**
- `test/must_fail_fixtures/1072-overlap-xmod-bare-head-arm-order` — **must NOT flip** (same tripwire;
  it is the #1277-reintroduction check).
- `test/must_fail_fixtures/1265-two-ifaces-same-method-one-type-default-collapse` — **should not flip**
  (occurrence granularity, M-2's). If it does, the change reached further than scoped.

**`could move:` for M-1 as a whole.** (i) Any program with **two admitted, disagreeing** declarations of
one method name **stops compiling** — the spec's own named cost, and it is invisible to every value
golden. (ii) The emit arm's receiver peel changes which argument is projected for *every* importer-shadow
occurrence, including ones with no collision at all — the "feature + UNRELATED code still behaves"
fixture (#1354's prediction P5) is mandatory, not optional. (iii) `implExistsForHead` gaining an
interface parameter changes an existence answer for method names shared across interfaces even where no
shadow exists. (iv) Nothing in M1-f can move behavior.

### 1.4 M-2 (#1276 + #1265 + #1386) — **RECOMMEND DEFERRING OUT OF THE SPRINT**, with one probe first

**The root cause is re-derived in this worktree, and it is a driver asymmetry, not a table.**
- `renameAliasedMethods` (`typecheck.mdk:25519`) has exactly one caller, in `elaborateModules`
  (`:27014`). **DERIVED.**
- `elaborateModules` sets `implInferEnabled := True` (`:13743`). **DERIVED.**
- The impl-channel obligation check runs **only** under `not implInferEnabled`
  (`:19946-19951`, `checkCallObligationsU True False obUniv [] perRun…implObls.items.value`). **DERIVED.**

⇒ The path that de-aliases never checks; the path that checks never de-aliases. **An impossible fix site
is the root cause** — matching the standing durable finding, and matching the ruling that the fix site is
RESOLVE-side/structural rather than a guard inside typecheck. No read-site guard can repair it, which is
why the `UseAlias`-arm-in-`usePathWitnesses` remedy was refuted.

**Why this is not a bite list.** The adopted scope is *"carry the alias's module id (and, for #1265, the
resolved interface identity) on the method occurrence"* — an **occurrence carrier**. `EMethodRef` /
`EMethodAt` are bare (**RELAYED** from the 2026-08-09 pass; I did not re-grep `frontend/ast.mdk`), and a
new carrier threads through desugar/resolve/marker/typecheck/printer/sexp/fmt/lower/mangle. That is
`add-language-feature` scale, it moves the snapshot corpus and the LEG A goldens broadly, and it is the
opposite of "a transformation over N named sites". Under §2's gate it should be **deferred**.

**⚠️ One narrower shape exists and I am flagging it as a QUESTION, not proposing it.** `renameAliasedMethods`
does two things, and only the second erases anything: `renameAliasedMethodsIn` (`:25963`) calls
`deAliasMethodImports` (`:25977`), whose `UseAlias` arm **adds a synthetic `DUse (UseGroup quals mems)`**
naming the aliased module's methods (`:25985-25987`) — *and then* `renameMethodVar` rewrites the
occurrence. **DERIVED by reading `:25963-25989`.** The synthetic `DUse` is exactly the witness
`usePathBindsName` (`:15879`) / `usePathWitnesses` (`:15869`) require. So *materializing the import
without renaming the occurrence*, on the check drivers, might give `scopedMethodEntry` (`:15745`) a
module-granularity witness on the diagnostic-producing path.

**This is INFERRED and it may well be wrong** — the refuted `UseAlias` remedy is a cautionary precedent
in exactly this territory, and this would only reach **module** granularity, which the 2026-08-09 pass
established is **insufficient for both #1276 and #1265** (two occurrences in one module must differ).
**Owed before anyone plans on it:** a throwaway instrumented compiler running `deAliasMethodImports`
alone on a check driver, graded on `test/must_fail_fixtures/1276-…/main.mdk` (`run` → reject) **and** on
its `control.mdk` (must stay `1`), **and** on `check` exit for #1386's no-impl-anywhere shape.
⚠️ Grade it on the **executed built binary**, never on `run` — this arc has one measured instance of a
supply change that moved `run` and left `build` where it was.

**If M-2 is deferred, say so on #1354** so the next reader does not find M-1 landed and read the
namespace as done. That is the partial-identity failure one level up.

---

## 2. #1319 — the constructor namespace. **How much A-3.2b drained: less than the brief implies.**

| unit (from the adopted 2026-08-05 breakdown) | state | derivation |
|---|---|---|
| **0** import-clause permutation differential | **LANDED** | `test/diff_compiler_import_order.sh`, `test/IMPORT-ORDER-LEDGER.txt`, 12 fixture dirs under `test/import_order_fixtures/` — **DERIVED**, listed |
| **1** `universeDataEnv` ctor entries | **LANDED** (PR #1352) | `universeCtorIdentsRef`/`universeCtorCollidedRef` present in `cross_allowed`; `graphCtorExportsRef` in `driver_allowed` — **DERIVED** |
| **2** `universeRecordByName` non-short-form | **LANDED** (PR #1372) | `universeRecordIdentsRef`/`universeRecordCollidedRef` in `cross_allowed` — **DERIVED**. #1253 **CLOSED** |
| **3** #1376/#1377 | **LANDED** (PR #1381) | both **CLOSED** — **DERIVED** |
| **4** retire `importedCtorTypeDecls` + shrink the ratchet | **NOT STARTED — and owned by #1512, Phase 1** | `importedCtorTypeDecls` def at `typecheck.mdk:26234`, live callers `:19782`, `:26732`; helpers `memberOverlayDecl` `:26251`, `findOverlayDecl` `:26283`, `overlayScanRows` `:26320`, `overlayScan` `:26329`, `overlayScanOne` `:26342`, `overlayNote` `:26364`, `declCtorNamed` `:26378`, `declOwnedBy` `:26394` — **all DERIVED present** |
| the `universeFieldOwners` row | **CrossRun cell deleted; the DEFECT is untouched** | `typecheck.mdk:5538` records the retirement; `perRun.fieldOwnersRef` **survives** at `:6351`, written by `addFieldOwners` at `:12504-12505`, read at `:8992` and `:9348` — **DERIVED**. `test/registry_keying_ratchet.sh:201`: *"NEUTRAL, NOT A DRAIN … #1216 (S0) and #1383 (S1) reproduce unchanged"* — **RELAYED, quoted** |

### Adopted split for #1319's Phase-3 residue — **one unit, 3 bites**

Everything above unit 4 has landed; unit 4 belongs to Phase 1. What is left for Phase 3 is the
**field-owner reachability predicate**, tracked as **#1383** (S1) and **#1216** (S0), both **OPEN**
(**DERIVED**). Note the 2026-08-09 **retraction** on #1319: #1383 and the `universeFieldOwners` row
*"share a CODE REGION, not a mechanism"* and are tracked separately — **RELAYED**; I did not re-derive it,
and it is the one place a sub-orchestrator should not take my word.

| id | description | named sites | transformation | deps |
|---|---|---|---|---|
| **C-a** | Reproduce #1383 (both faces) and #1216 on the trunk binary, with the mechanism control (rename the colliding field) | `test/must_fail_fixtures/1383-variant-ctor-name-collides-xmod-record-type/`, `.../1216-xmod-record-field-name-collision/` | **Probe only, no edit.** Gate on this before any keying change: the ratchet's *"reproduce unchanged"* claim is RELAYED and post-dates A-3.2b's slice 3 by hours. | — |
| **C-b** | **Q-IDENT** — identity selection when the receiver type is concrete (#1383) | `resolveFieldByOwners` / `pairRecordByName` / `fieldOwnerNames` `:6497` region; `fieldOwnersRef` `:6351`; readers `:8992`, `:9348` | Select the `RecordInfo` by receiver **identity** on the concrete-receiver arm instead of falling to `headL owners`. The 2026-08-09 design comment reports this prototyped at ~30 lines, needing **no closure and no new table**, draining both faces of #1383 and both arms of #1216 — **RELAYED, not re-derived; treat as a hypothesis with a named prototype, not a plan.** | C-a |
| **C-c** | The `TVar`-receiver ambiguity arm — the reachability closure | same read sites; `deFieldOwnerIdents` `:3325` (**DERIVED: still has NO reader**) | Scope the candidate owner set to types the module can reach. ⚠️ The ratchet states `deFieldOwnerIdents` cannot answer this — it is **ordinal-free** and it unwraps `DAttrib` where `publicDataDecls` does not, so reading it *"would have given an attributed record a field-owner vote it does not have today … an acceptance NARROWING"* (`:201`, **RELAYED, quoted**). **This bite is the one most likely to need to be an open architectural question rather than a bite.** | C-b |

**Flat-arm behavior.** `fieldOwnersRef` is `PerRun`, seeded on the Module path by
`declEnvSeedDataUniverse` and written by `registerAllData` on both paths (**DERIVED** from `:12504`,
`:24878` region). C-b operates on the receiver, not the seed, so it should be arm-neutral; **C-c is not**
— any predicate built on `declEnvVisibleAt`/ordinals is empty on the Flat arm, which is the exact shape
that turns a rejection into a silent accept. **Owed, per bite.**

**Must-fail pins expected to flip RED:** `1383-variant-ctor-name-collides-xmod-record-type` (C-b),
`1216-xmod-record-field-name-collision` (C-b — it is `ws:emitter`, so grade it on the **built binary**),
and `1586-attribute-drops-field-owner-registration` **must NOT flip** (C-c's `DAttrib` hazard is exactly
its shape — a flip there means C-c widened acceptance through the attribute arm).
**`could move:`** C-b changes which `RecordInfo` a *concrete* receiver selects, program-wide, including
programs with no collision — and the #1382/#1383 pairing warning is explicit that a careless fix to one
produces the other. Grade any C-b patch against #1382's repros as a **positive regression case**.

---

## 3. #991 — three sub-claims, three separate answers. **Two DRAINED, one LIVE.**

Derived from source in this worktree; I did **not** read #991's own 2026-08-11 status comment until after
deriving, and my three answers agree with it independently.

| ask | verdict | derivation |
|---|---|---|
| **1. `implObls` still carries the pre-#838 tuple; retire `implOblToU`** | ✅ **DRAINED** | `implObls : Windowed UObligation` — `typecheck.mdk:6365`. `grep -n implOblToU` returns **only** `:21030`, a comment reading *"the `implOblToU` bridge that used to project a surviving …"*. **DERIVED.** |
| **2. Three `Provenance` arms are dead (+ the stale `PMethodLevel` comment)** | ✅ **DRAINED** | `typecheck.mdk:5203-5208` now reads *"#991: every arm below is now LIVE"*. Producers **DERIVED** live: `POperator` `:9705`, `PNumLit` `:10076`, `PMethodOcc` `:10614`, `PMethodLevel` `:10675`. The `PMethodLevel` comment now reads *"a method-level `=>` constraint slot (#818, I3)"* (`:5220-5221`). |
| **3. The numlit descope is unrecorded** | ❌ **STILL LIVE** | `numlitRefs : Ref (List (Mono, Ref (Option Float), Int, Ref Route))` — `typecheck.mdk:6366`, **no comment**. `grep -n numlit compiler/types/typecheck.mdk \| grep -i 'descope\|bespoke\|deliberate'` → **empty**. **DERIVED.** |

**⇒ #991 is LIVE but is now a one-line documentation residual (S3), not a storage port.** It landed with
#1446 via PR #1480 (**RELAYED** from #991's own comment; corroborated in-tree by `typecheck.mdk:20827`,
*"T2 HAS MOVED — #1446, landed with #991"*). Its **title and body are stale** and will mislead any agent
who reads them without grepping.

**Bite (1, trivial):**

| id | description | named sites | transformation |
|---|---|---|---|
| **O-a** | Record the numlit stays-bespoke decision | `typecheck.mdk:6366` (`numlitRefs`); optionally `setNumlitFloats` | Add a comment at the field stating that the numeric-literal channel stays bespoke, and why (Float-defaulting machinery, not obligation checking), citing #991. |

⚠️ **`PerRun`'s header shape must be checked before adding this comment.** #829 is REOPENED and its
trigger is the two-line `data X =` / `| X {` header. `PerRun` is documented as the **safe collapsed**
form and `DriverState` as the unsafe one — **I did not re-derive that**; run
`grep -n '^data PerRun =$' -A1 compiler/types/typecheck.mdk` before editing, and diff the decl by eye
after `fmt --write`. If it is the unsafe form, put the prose on `setNumlitFloats` instead.
**`could move:` nothing — comment only. Flat arm: unaffected. Pins: none.**

---

## 4. #1111 / #1112 — the shell verdict: **NEITHER is a clean shell.**

### #1111 (A-2) — carries residual work, one bullet of which is **discharged but unrecorded**

- Its body's *"**Also in scope:** update #1070's body"* is **DONE** — **DERIVED**: #1070's body now carries
  `1. ~~Reject duplicate…~~ — **SUPERSEDED, see note below; do not implement this.**` and the full
  2026-07-25 supersede note. No child issue owns that bullet; it was simply done. **Nothing to schedule.**
- Its closure gate is **RULED** (2026-08-09, on-issue): *"All three follow-on units — #1319, #1337, #1354
  — gate this issue's closure. So does #1317."* **RELAYED, quoted.**
- 🚨 **A bookkeeping defect in that ruling: #1317 is OPEN and is a DISSOLVED historical pointer.** Its title
  reads *"ARCH A-2 (DISSOLVED 2026-08-09) … Historical pointer only"* — **DERIVED**. #1111 therefore cannot
  close while an issue that owns no work is open. **This is unowned work: someone must either close #1317
  or amend #1111's ruling to drop it.** It is not in any child's scope.

**⇒ #1111 verdict: shell + one live bookkeeping item (#1317's disposition). It carries no implementable
work of its own.** Given the sprint's issue-closure policy, do not close it either — but the #1317 item
should be recorded on `DECISIONS.md` so it is not rediscovered.

### #1112 (A-3) — carries **two** residual bullets no child owns

1. **A-3.4 has no issue at all.** It exists only in #1112's decomposition table. **RELAYED** from the
   sprint doc §1, which says so verbatim; corroborated by the tracker sweep (#1557 = A-3.5, #1558 = A-3.6,
   #1559 = A-3.7; there is no A-3.4 issue) — **DERIVED**. Work has landed against it anyway (commits
   `5a4c87b7` *"arch(1112) A-3.4 PR2 — ie reader flip"*, `0bcc5e21`), i.e. **#1112 is holding an
   unticketed child's residue in its own body.**
2. **The per-namespace A-3 precondition analysis is OWED and unowned.** #1111's 2026-08-09 ruling
   escalated *"what is A-3's actual precondition"* and answered it only partially; the follow-on
   correction states the per-namespace question *"is a real piece of work and should be done deliberately,
   by whoever picks up A-3, before A-3 starts."* **RELAYED, quoted.** No child issue carries it.
3. Its body **cites the fabricated symbol pair** from §0.5 (`#1112` body, the "derive by SHAPE, not prefix"
   parenthetical). That parenthetical's *instruction* is correct and load-bearing; its *citation* is not.

**⇒ #1112 verdict: NOT a clean shell.** It holds (a) an unticketed child A-3.4, (b) an owed
architectural analysis, (c) a stale citation. **An epic that quietly holds unowned work is exactly the
shape §1 warns about, and #1112 is an instance.**

---

## 5. Bite count and scheduling recommendation

**N bites = 10** implementable (M1-a … M1-f = 6, C-a … C-c = 3, O-a = 1), plus **1 deferral
recommendation** (M-2) and **1 probe that must precede it**.

Recommended Phase-3 order, and why:

1. **O-a** (#991) — one comment, no behavior, no dependency. Land it first so #991 can be re-titled after
   the sprint. Do **not** close it.
2. **M1-a … M1-f** (#1351) — spec-driven, graded by a live permutation differential, and the largest
   soundness win available in Phase 3. Strictly serial internally; M1-d is non-optional.
3. **C-a** (probe) → **C-b** (#1383/#1216). **C-c is a candidate for deferral** — its predicate is the
   `TVar` arm the ratchet says needs a reachability closure that is *"still owed to a later unit."*
4. **M-2 (#1276/#1265/#1386): deferred**, with the `deAliasMethodImports` probe (§1.4) run inside the
   sprint if there is slack, because a negative result is as valuable as a positive one and it costs one
   throwaway build.

**Nothing here closes an issue and nothing deletes a must-fail fixture.** The expected-red set to write
into `.claude/HANDOFF.md` before Phase 3 starts:
`1351-methoddispatchidx-import-order-collision`, `1383-variant-ctor-name-collides-xmod-record-type`,
`1216-xmod-record-field-name-collision`. The must-**not**-flip tripwires:
`1072-…`, `1182-…`, `1265-…`, `1586-…`.

---

## 6. What I could NOT establish

- **I did not build any counterfactual compiler.** Every "this bite drains X" is a prediction from the
  spec text plus source reading, not a measurement. The two S0 **repros** are measured (§1.1); the
  **fixes** are not.
- **I did not re-derive the 2026-08-09 retraction** separating #1383 from the `universeFieldOwners` row,
  nor the Q-IDENT prototype's reported results. Both are load-bearing for §2's C-b and both are RELAYED.
- **I did not re-grep `frontend/ast.mdk`** for `EMethodRef` / `EMethodAt` bareness — RELAYED from #1354's
  scoping pass, and it is the premise of M-2's deferral.
- **I did not measure the Flat-arm behavior of any bite.** M-1's Flat-arm row is now read off
  `nameableIfaceShadows`'s own source (`:25043-25070`, DERIVED) after my first inference from the ratchet
  proved **wrong in the dangerous direction** — I had it failing closed; it fails open. §2's Flat-arm row
  is still INFERRED from `test/registry_keying_ratchet.sh` — **ungated prose that has shipped fabricated
  symbols (#1574)** — which I quoted rather than re-derived in three places. Assume the same error is
  latent there and derive it from source before implementing C-c.
- **I did not run a single gate**, per the read-only contract. No claim here rests on a gate's colour.
- **I did not establish that `deAliasMethodImports` alone would move #1276** — §1.4's shape is INFERRED
  from reading `:25963-25989` and is explicitly presented as a probe to run, not a plan to adopt.
- **I did not check `compiler/ir/core_ir_eval.mdk`** for a parallel copy of any dispatch-index or
  field-owner table. The `evalModules`/`cevalModules` lockstep trap applies to M1-b and C-b. **The
  2026-08-07 pass named this as "the implementer's first check" and it is still owed.**
