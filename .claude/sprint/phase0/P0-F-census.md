# P0-F — Stage A arc-wide residue census

**Agent:** P0-F (Phase 0, read-only census + cross-check).
**Tree:** `/root/medaka/.claude/worktrees/wiggly-giggling-nygaard`, branch `arch/stage-a-sprint`,
`HEAD = 7aae8b83e8b2f7aeef1132b7af0c8b4db784f3f1` (pinned; `git rev-parse HEAD`).
**Working tree at derivation time:** clean except ` M .claude/HANDOFF.md` and untracked `.claude/sprint/`.
**Date:** 2026-08-12.

Every claim below is labelled **DERIVED** (I ran the command shown, in this worktree, and read
the output), **RELAYED** (someone else's claim, attributed, not re-derived), or **OWED**.

---

## 1. The live `cross_allowed` set — **24 members** · DERIVED

`sh test/registry_keying_ratchet.sh` **PASSES** on this tree and prints:

```
ok: 24 CrossRun field(s), 22 DriverState field(s), 8 DeclEnvs field(s), 5 DeclEnvModule field(s), no new bundle field
ok: 24 crossRun.value.* write target(s), 22 driverState.value.* write target(s), no rogue writer
PASS: #1111 registry keying ratchet (...)
```

The ratchet asserts `cross_allowed` (its prose allowlist) **equals** the live `CrossRun` field
set, so a green run means the two agree; I derived the live set independently rather than
reading the prose block:

```sh
sed -n '/^data CrossRun = CrossRun {$/,/^  }$/p' compiler/types/typecheck.mdk \
  | grep -vE '^[[:space:]]*--' | sed -E 's/[[:space:]]--[[:space:]].*$//' \
  | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*:.*/\1/' \
  | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' | LC_ALL=C sort
```

**The 24 members**, alphabetically:

| # | field | note (DERIVED from presence/absence only) |
|---|---|---|
| 1 | `builtinClassesRef` | closed enum key; #1446 P1 |
| 2 | `coreSchemeObligationsRef` | #673 |
| 3 | `crossModuleFunConstraintIfacesQualRef` | qualified mirror |
| 4 | `crossModuleFunConstraintIfacesRef` | bare |
| 5 | `crossModuleFunConstraintsQualRef` | qualified mirror |
| 6 | `crossModuleFunConstraintsRef` | bare |
| 7 | `crossModuleMethodConstraintsQualRef` | qualified mirror |
| 8 | `crossModuleMethodConstraintsRef` | bare |
| 9 | `crossModuleSchemeOblsQualRef` | #1114 |
| 10 | `universeCtorCollidedRef` | A-2.11 |
| 11 | `universeCtorIdentsRef` | **#1593's elaborated trio** |
| 12 | `universeDataEnv` | **#1593's elaborated trio** |
| 13 | `universeFunNamesRef` | |
| 14 | `universeIfaceMethodsRef` | excluded from CE; #1354's territory |
| 15 | `universeIfaceRequiredRef` | **A-3.5a's target** |
| 16 | `universeKeyBucketsRef` | A-2.2b |
| 17 | `universeMethodCollidedRef` | A-2.5 |
| 18 | `universeMethodDispatchIdxRef` | excluded from CE; **#1351 lives here** |
| 19 | `universeMethodIdentsRef` | A-2.5 |
| 20 | `universeMethodIfaceParamsRef` | A-2.5 overlay floor |
| 21 | `universeRecordByName` | **#1593** + the sole surviving load/store cell |
| 22 | `universeRecordCollidedRef` | A-2.12 |
| 23 | `universeRecordIdentsRef` | A-2.12/13; deleter is #1288 |
| 24 | `universeRegisteredIfacesRef` | deliberately bare; revisit with the obligation channel |

### 1a. The shrink history — DERIVED, and it exposes a wrong number in a ledger

I re-derived the count at each landing commit (`git show <c>^:…` vs `git show <c>:…`, same
extraction as above; script at
`/var/tmp/medaka-scratch/.../scratchpad/histcount.sh`):

| commit | PR | unit | before → after |
|---|---|---|---|
| `4acb893c` | #1553 | A-3.2b overlay pool (`universeDataDecls`) | **32 → 31** |
| `7e6d9b8e` | #1567 | A-3.4 PR2 IE reader flip (3× `obUniv*Ref`) | **31 → 28** |
| `60bf1afa` | #1588 | A-3.2b residual 1 (`universeAliasTable`) | **28 → 27** |
| `4dd1c304` | #1592 | A-3.5c (`universeIfaceParamKinds`) | **27 → 26** |
| `095d16b9` | #1590 | A-3.2b slices 2+3 (`universeDataParamKinds`, `universeFieldOwners`) | **26 → 24** |
| `7aae8b83` | #1596 | (docs only) | **24 → 24** |

🚩 **FINDING (ledger wrong by one).** `compiler/TYPECHECK-TARGET-ARCHITECTURE.md:1803` states
A-3.5c took *"`cross_allowed` 28 → 27"*. **Measured: 27 → 26.** The row was written before #1588
(merged 06:27Z) landed ahead of #1592 (07:12Z), and was never re-derived. Low harm today —
nobody should be reading a count — but it is the exact #1574 shape in a *gated* doc, and it
will read as a discrepancy to anyone who checks. **Fix by deleting the number, not bumping it.**

🟢 **CROSS-CHECK, independent and agreeing.** #1593's body (filed 2026-08-12 at the close of the
A-3.2b/A-3.5c session) states `cross_allowed = 24` on `main` @ `dc3e8bd5` and tells the reader to
derive it. My derivation agrees. (Mine DERIVED; theirs RELAYED here.)

### 1b. The other three bundle counts — DERIVED

- `DriverState` = **22**
- `DeclEnvs` = **8**: `deAllDecls, deData, deIfaces, deImpls, deKindsBefore, deModules, deOrdIndex, deOwnersBefore`
- `DeclEnvModule` = **5**: `demDecls, demId, demKindEntries, demOrd, demPubDecls`

The ratchet's stated progress signal — *"this row GROWING while `cross_allowed` SHRINKS"* — is
therefore currently **DeclEnvs 3 → 8** against **cross_allowed 32 → 24** over five landings.

---

## 2. Per-unit landed / owed — the whole A-3 arc

Method: `git log --oneline -60`; `gh pr list --state merged --limit 40`; then **confirmed against
the source**, because a PR title is a claim. Issue states via one `gh api graphql` call.

| Unit | Status | PR / commit | Derivation (what I read in the tree) |
|---|---|---|---|
| **A-3.1** — stage-K envelope | ✅ **LANDED** | (pre-BASE) | `DeclEnvs` exists with `deModules`/`deOrdIndex`/`deAllDecls`; `buildDeclEnvs` at `typecheck.mdk:2753`; `declEnvsRef` on `DriverState` (in `driver_allowed`) |
| **A-3.2a** — DataEnv slice | ✅ **LANDED** | (pre-BASE) | `deData : DataEnv` at `:2726`; `deTypes`/`deCtorIdents`/`deRecordIdents`/`deFieldOwnerIdents`/`deAliases` all present (`:3325` and siblings) |
| **A-3.2b** — overlay pool | ✅ **LANDED** | #1553 / `4acb893c` | `universeDataDecls` has **0 non-comment occurrences** in `compiler/`; `importedCtorTypeDecls` (`:26234`) reads `deModules` via `declEnvRowVisible` |
| **A-3.2b residual slice 1** — alias table | ✅ **LANDED** | #1588 / `60bf1afa` | `aliasUniverseAt` (`:3547`) + `aliasVisibleTo` (`:3557`); `loadDataUniverse:24894-24896` seeds `aliasTableRef` from `deData.deAliases`; no `universeAliasTable` field |
| **A-3.2b residual slices 2+3** — kinds + field owners | ✅ **LANDED** | #1590 / `095d16b9` | `deKindsBefore`/`deOwnersBefore` in `DeclEnvs`; `declEnvSeedChain:3054`; `declEnvSeedDataUniverse:3113` called once at `:19780`; `universeFieldOwners` **0 non-comment hits** |
| **A-3.2b remainder** (elaborated trio) | ➡️ **RE-SCOPED OUT of #1512 into #1593** (OPEN) | — | `universeRecordByName`/`universeDataEnv`/`universeCtorIdentsRef` still in `CrossRun` (items 11/12/21 above); #1593 body owns them explicitly |
| **A-3.3** — CE construction | ✅ **LANDED** | #1527 | `deIfaces` in `DeclEnvs`; `ceRows`/`ceByKey`; ratchet check 5 prints `ok: CE block is 193 line(s)` |
| **A-3.4 PR1** — IE construction | ✅ **LANDED** | (pre-BASE) | `deImpls` in `DeclEnvs`; `ieInsertRow`, `ieUnivSnaps`, `InstRef` all present |
| **A-3.4 PR2** — IE reader flip | ✅ **LANDED** | #1567 / `7e6d9b8e` | `ieUniverseAt` bound once at `:19584` inside `checkBodyImpl` (`:19455`); three `obUniv*Ref` gone from `CrossRun` (1 non-comment hit each, all in `.md` docs); ratchet check 4 prints `ok: IE block is 122 line(s)` |
| **A-3.5a** — impl completeness over CE | ⛔ **OWED** | — | `universeIfaceRequiredRef` still in `CrossRun` (item 15). Arch doc `:1801` defers `implCompletenessMsgsOf*` to A-3.5 |
| **A-3.5b** — super-impl scan over IE | ⛔ **OWED** | — | `superImplMsgsOf`/`implMatchesSuper` deferred to A-3.5 at arch doc `:1802`; no CE/IE read at either |
| **A-3.5c** — CE-only decl-time checks | ✅ **LANDED** | #1592 / `4dd1c304` | `checkPhantomMethods:16490` → `ceRowsOwnedBy`; `checkInterfaceCycles:16597` → `ceRowsVisibleAt`; `checkGradedImplTys:1873` → `ceSlotKindsAt`; `ifaceParamKindsRef`/`registerIfaceParamKinds`/`insertIfaceParamKinds` **0 non-comment hits in code** |
| **A-3.6** — candidacy flip (#1558) | ⛔ **OWED** | — | `declEnvVisibleAt` body present at `:2834-2835`; §4 below is the reader count it must honour |
| **A-3.7** — coherence over IE (#1559) | ⛔ **OWED** | — | `coherenceUserDecls` still in `driver_allowed`; `ieInst`/`InstRef`/`ieMethods` are payload-only (`InstRef` 15 non-comment hits, none in a judgment) |
| **#1593** — elaborated trio | ⛔ **OWED**, OPEN | — | see above |

**#1557 is OPEN with only its `c` sub-unit landed.** The sprint's §1 table lists `#1557 (A-3.5)`
as one node; the tree says it is **1 of 3 done**. Sub-orchestrators should treat A-3.5 as
**two remaining bites (a, b)**, not one unit.

**Issue states** (`gh api graphql`, one call, 2026-08-12): #1111 OPEN, #1112 OPEN, #1512 OPEN,
#1557 OPEN, #1558 OPEN, #1559 OPEN, #1593 OPEN, #1354 OPEN, #1319 OPEN, **#991 OPEN** (sprint §1's
"confirm still live" → **CONFIRMED LIVE**), #1288 OPEN, #1574 OPEN, #1276/#1351/#1216/#1383/#1586
all OPEN.

---

## 3. The load/store ladder — **AGREE. No divergence.** DERIVED

Read verbatim at `compiler/types/typecheck.mdk:24891-24903`:

```
loadDataUniverse : Int -> Unit
loadDataUniverse cur =
  let _ = setRef perRun.value.recordByNameRef crossRun.value.universeRecordByName.value
  setRef
    perRun.value.aliasTableRef
    (aliasUniverseAt cur driverState.value.declEnvsRef.value.deData.deAliases)

storeDataUniverse : Unit -> Unit
storeDataUniverse _ =
  setRef crossRun.value.universeRecordByName perRun.value.recordByNameRef.value
```

**Verdict on the ratchet's own silent-divergence test** (*"agree in SET and in ORDER"*, applied to
the **CROSS-RUN half** only, per the invariant note at `:24865-24890`):

- **CROSS-RUN half, load:** `{ universeRecordByName → recordByNameRef }` — **1 cell**.
- **CROSS-RUN half, store:** `{ recordByNameRef → universeRecordByName }` — **1 cell**.
- **SET: identical. ORDER: trivially identical (one element).** ✅ **NO DIVERGENCE.**
- **STAGE-K half, load-only:** `aliasTableRef ← aliasUniverseAt cur … deData.deAliases`. It has
  **no store counterpart by construction** and must not acquire one (design law L1; the copy
  would silently carry `rejectCyclicAliases`' per-module deletions).
- Both bodies have **exactly one tail expression and no dangling `let _ =`** — the second half of
  the invariant note's after-rebase check. ✅

⚠️ **One imprecision in the invariant comment, worth a one-line fix (not a bug).**
`:24874-24878` says *"Three tables are now on this side"* and lists `aliasTableRef`,
`dataParamKindsRef`, `fieldOwnersRef` under the STAGE-K half **of this pair**. Only
`aliasTableRef` is in `loadDataUniverse`'s body. The other two are seeded by
`declEnvSeedDataUniverse` at a **different call site** (`:19780`, inside `checkBodyImpl`'s Module
arm) — the comment says so two lines later, but a reader scanning the "three tables" sentence
will look for three lines in a two-line function and not find them.

**Also confirmed DERIVED:** the doubling hazard the comment describes is real and still live —
`appendDataUniverse:24944` calls `loadDataUniverse`, which **no longer resets**
`fieldOwnersRef`/`dataParamKindsRef`, then `registerAllData … pubDecls` re-registers. Inert only
because nothing reads the multimap in between. **Any unit adding a `fieldOwnersRef` read after
`:24945` re-arms the `mangledHeadCandidates` singleton-gate failure.** A-3.6/A-3.7 implementers
should treat this as a standing hazard row.

---

## 4. Production readers of `declEnvVisibleAt` / `declEnvVisibleTo` — DERIVED

```sh
grep -n 'declEnvVisibleAt\|declEnvVisibleTo' compiler/types/typecheck.mdk | grep -vE ':[[:space:]]*--'
```

Both predicates live **only** in `compiler/types/typecheck.mdk` (the only other tree hits are
prose in `compiler/TYPECHECK-TARGET-ARCHITECTURE.md` and `test/registry_keying_ratchet.sh`).

### 4a. `declEnvVisibleAt` — definition `:2834-2835`

**5 direct call sites**, one of which is the `declEnvVisibleTo` wrapper:

| site | caller | leads to |
|---|---|---|
| `:2874` | `declEnvsUpToGo` → `declEnvsUpTo:2868` → `declEnvsVisible:2879` (exported) | 💀 **NO CALLER** — still dead |
| `:2910` | `declEnvVisibleTo` (the wrapper) | see 4b |
| `:4083` | `ieSnapAt` → `ieUniverseAt:4072` | **PRODUCTION**: `:19584` in `checkBodyImpl:19455` (the `moduleImplUniv` bind) |
| `:4461` | `ceLookupAt` | **PRODUCTION**: `ceSlotKindsAt:4496` → `checkGradedImplTys:1873`; and `ifaceDfsCycleOneSuper:16688` (`:16695`) |
| `:4482` | `ceRowsVisibleAt` | **PRODUCTION**: `checkInterfaceCycles:16597` (`:16608`) |

### 4b. `declEnvVisibleTo` — definition `:2909-2910`

**3 direct call sites**:

| site | caller | leads to |
|---|---|---|
| `:2928`, `:2929` | `declEnvRowVisible:2926` | **PRODUCTION** ×2: `declEnvSeedChain:3060` (field-owner seed) and `overlayScanRows:26322` (`:26323`) ← `findOverlayDecl:26284` ← `importedCtorTypeDecls:26234` |
| `:3000`, `:3001` | `declEnvRowKindEntries:2998` | **PRODUCTION**: `declEnvSeedChain:3059` (kind seed) |
| `:3558` | `aliasVisibleTo:3557` → `aliasUniverseAt:3547` | **PRODUCTION**: `loadDataUniverse:24896` (+ one doctest at `:3615`) |

### 4c. The count A-3.6 must honour

**8 distinct production read paths reach `declEnvVisibleAt`**, through **7 distinct
intermediaries**:

1. `ieSnapAt` / `ieUniverseAt` → `checkBodyImpl` Module arm (`:19584`) — *A-3.4 PR2*
2. `ceLookupAt` → `ceSlotKindsAt` → `checkGradedImplTys` (`:1876`) — *A-3.5c*
3. `ceLookupAt` → `ifaceDfsCycleOneSuper` (`:16695`) — *A-3.5c*
4. `ceRowsVisibleAt` → `checkInterfaceCycles` (`:16608`) — *A-3.5c*
5. `declEnvVisibleTo` → `declEnvRowVisible` → `overlayScanRows` → `importedCtorTypeDecls` — *A-3.2b*
6. `declEnvVisibleTo` → `declEnvRowVisible` → `declEnvSeedChain` (owners) — *A-3.2b slice 3*
7. `declEnvVisibleTo` → `declEnvRowKindEntries` → `declEnvSeedChain` (kinds) — *A-3.2b slice 2*
8. `declEnvVisibleTo` → `aliasVisibleTo` → `aliasUniverseAt` → `loadDataUniverse` — *A-3.2b residual 1*

Plus **1 dead path** (`declEnvsVisible`, exported, zero callers — the source's own comment at
`:2687-2693` says so and asks whichever unit first calls it to update the line) and **9 doctest-only
readers** (`ceRowMethodNamesAt`/`ceRowMethodTysAt`/`ceRowTyparamsAt`/`ceRowSuperHeadsAt`/
`ceRowSuperParamsAt`/`ceRowSuperOriginAt`/`ceRowIfaceNameAt`/`ceRowParamKindNamesAt` at
`:4601-4660`, and `aliasUniverseAt`'s doctest at `:3615`) — **verified doctest-only**: every
occurrence of those eight names outside their own definition is inside a `-- >` doctest line.

⚠️ **Three of those readers post-date the ratchet's own list.** The ratchet's `declEnvsRef` row
names A-3.2b, A-3.4 PR2, A-3.2b-slice-1 and A-3.5c. Reader **1** (A-3.5c's `ceLookupAt` via
`ifaceDfsCycleOneSuper`) is a **second** CE path the row's A-3.5c sentence does not separately
name, and readers **6/7** (the `declEnvSeedChain` pair) came in after that sentence was drafted.
A-3.6 must count **8**, not 5.

⚠️ **A-3.6 must NOT delete these three conditions**, each derived at its site:
- `aliasVisibleTo`'s **own-row exclusion** `adOrd != cur` — structural, not transitional.
- `aliasVisibleTo`'s **attributed-alias drop** `not adAttrib`.
- The **publicity conjunct** of `declEnvVisibleTo` — it migrates to R, it does not vanish.

🟢 **Deliberate redundancy with P0-C.** If P0-C reports a different number, the discriminator is:
did they count *call sites of the predicate* (5 + 3), *intermediaries* (7), or *leaf production
readers* (8)? Mine is leaf production read paths, enumerated above by `file:line`.

---

## 5. Must-fail pin inventory for Stage A's territory

`ls test/must_fail_fixtures/` — **97 directories** (DERIVED, `ls | wc -l`).

### 5a. Expected to flip RED during this sprint — *deliverable, not a break*

Per sprint §1's closure policy, and by which in-scope node owns the issue:

| fixture dir | issue | owner node | why it flips |
|---|---|---|---|
| `1276-alias-method-provenance-erased` | #1276 S0 | **#1354** (in scope) | §1 names it explicitly |
| `1351-methoddispatchidx-import-order-collision` | #1351 S0 | **#1354** (in scope) | §1 names it explicitly; `universeMethodDispatchIdxRef` is `cross_allowed` #18 |
| `1530-xmod-method-name-collision-reexport-merge` | #1530 | method-namespace (#1354 territory) | **CANDIDATE** — same table family; not named by §1. Verify before assuming |
| `1450-xmod-iface-method-name-arity-collision-segfault` | #1450 | method-namespace | **CANDIDATE**, same caveat |

### 5b. Declared NON-flip — must stay RED, and a flip is a REAL failure

| fixture dir | derivation |
|---|---|
| `1265-two-ifaces-same-method-one-type-default-collapse` | `TYPECHECK-TARGET-ARCHITECTURE.md:1598-1601`: *"must stay RED across A-3.4, declared up front per §7's pin→stage map … if A-3.4 changed the default-arm answer in any direction, the pin flips and the must-fail gate reds naming #1265"* |
| `1302-private-iface-witnesses-under-wildcard` | F3, deliberately unfixed by A-2.5b/A-2.11/#1354-A (`driver_allowed` rows say so verbatim) |
| `1586-attribute-drops-field-owner-registration` | `declenvs_allowed`'s `deOwnersBefore` row: *"#1586 is inherited here, not drained"* |
| `1228-attribute-drops-data-registration` | sibling of #1586; `demKindEntries` row: *"NO `DAttrib` arm, deliberately: `registerData` has none either (#1586, S0)"* |
| `1216-xmod-record-field-name-collision` | `deOwnersBefore` row: *"#1216 (S0) and #1383 (S1) reproduce unchanged"* |
| `1383-variant-ctor-name-collides-xmod-record-type` | same |

### 5c. Adjacent, in Stage A's blast radius — watch, do not pre-classify

`1288-reexport-iface-merge-incomplete-impl` (#1288 is the *named deleter* of three `cross_allowed`
identity-companion rows), `1514-xmod-same-spelled-iface-impl-selection` (the #1438 candidacy class
A-3.6 widens), `1564-import-order-decides-conditional-impl-candidacy` (IE candidacy — A-3.6/3.7),
`1292-xmod-ctor-name-argtag-wrong-impl` (#1319 coordinates it), `1396-priv-ctor-outranks-public-import-eval`
(#1284 class → #1319), `1373-reexport-named-field-variant-unknown-field`,
`1359-reexport-ctor-mangle-miss`, `1397-xmod-samename-type-impl-symbol-collapse`.

**Out of scope by §1's ruling:** `1326-…` / `1427-…` / `1472-…` belong to **#1337**, and
`1425-list-get-map-bare-seed-poison` to **#1425** — both ruled off-spine. A red there is **not**
this sprint's.

---

## 6. 🚨 Work in the A-3 arc that **no in-scope node owns**

### 6a. The field-owner list re-key — **UNOWNED**. The highest-value finding here.

The ratchet's `declEnvsRef` row states (verbatim): *"`deFieldOwnerIdents` therefore still has NO
reader; what it uniquely states (two SAME-NAMED owners kept apart by identity) is owed to **the
unit that re-keys the owner list**."* And: *"the type-REACHABILITY predicate that would fix
[#1216/#1383] is still owed to **a later unit**."*

**DERIVED: that unit does not exist.**

- `deFieldOwnerIdents` has **no production reader**. All 13 occurrences
  (`grep -n deFieldOwnerIdents compiler/types/typecheck.mdk`) are: 4 prose comments
  (`:3227,3235,3305,3319,3378`), the field decl `:3325`, the `emptyDataEnv` init `:3334`, two
  construction lines `:3448/:3453`, and 5 doctest lines `:3707-3718`. **Zero judgment reads it.**
- No open ARCH issue names it. Full sweep of open ARCH nodes
  (`gh issue list --state open --limit 300 --jq 'select(.title|test("ARCH"))'` → 30 rows) and of
  every open issue whose title mentions owner/reachability/field/slot
  (`--jq 'select(.title|test("owner|reachab|slot|field";"i"))'` → 22 rows): **not one claims it.**
  #1319's scope (read in full) covers constructor identity and `universeRecordByName`'s
  non-short-form entries — **not** the field-owner multimap. #1288 owns interface re-export merge
  plus the *constructor* consolidation — not this. #1593 owns the elaborated trio — not this.
- The tree even has a precedent for naming such gaps explicitly: **#1136** and **#1137** are open
  issues titled *"…has no stage owner"*. The field-owner family has no such issue.

**The orphaned set:** #1216 (S0, run≠build, silent wrong value at exit 0), #1383 (S1, legal
program rejected), #1586 (S0, silent wrong owner, all engines agree), #1468 (S0, sibling-slot
read), #1456 (S3, superlinear), and `deFieldOwnerIdents` itself — a table built, doctested and
allowlisted with **zero readers**, in the very record the sprint's units keep extending.

**Recommendation to the run orchestrator:** this is not implementable inside a Phase-0 bite, but
it is exactly the *"work that fell between nodes ships silently incomplete"* shape §8's exit
criterion cannot see. **File it as an ARCH node before the sprint's exit** (in the #1136/#1137
mould), so it is owed to *something*. Do not let it exit as prose inside a gate script's comment.

### 6b. `declEnvsVisible` — exported, zero callers, since A-3.1 — **UNOWNED**

`:2879-2880`. Its own comment (`:2687-2693`) asks *"whichever unit first calls `declEnvsVisible`
should update this line"* — but no unit is assigned to. Three units have since added their own
visibility paths (§4) and **none** used it. Either A-3.6 absorbs it or it should be deleted;
today it is a live export that `rule-dead-code` does not flag.

### 6c. A-3.5 is 1-of-3, and the sprint doc counts it as 1 node

See §2. **A-3.5a and A-3.5b are owed work with no bite list**, hiding behind a single `#1557` row
in §1's scope table. Phase 0's gate (*"every in-scope unit has a written bite list"*) is not met
by a decomposition of "#1557" that treats it as one unit.

---

## 7. #1574 contribution — every symbol the ratchet's `declEnvsRef` and `deImpls` rows name

I extracted **101** symbols from those two rows (plus their immediate neighbours) into
`syms.txt` and grepped each with word boundaries against `compiler/`
(script: `/var/tmp/medaka-scratch/.../scratchpad/symcheck.sh`), reporting both total hits and
non-comment hits.

### 7a. Symbols that **do not exist anywhere in the tree** (0 hits)

| symbol | verdict |
|---|---|
| `declEnvSeedRows` | **FABRICATED — CONFIRMED.** 0 hits. The row already self-flags this (*"BOTH were fabrications by the time it shipped"*), and I independently confirm it. The other half of that self-flag, the own-row test **`m.demOrd == cur`**, is likewise absent: `declEnvSeedChain:3054-3060` contains **no ordinal comparison at all** — the exclusion is structural (the `omInsert` precedes the fold). ✅ the row's own retraction is accurate. |
| `ieTriplesUpTo` | 0 hits — **correct**, the row names it as *deleted by A-3.4 PR2*. Not a fabrication; a correctly-past-tense citation. |

### 7b. 🚩 **NEW FINDING — a THIRD dead symbol, presented in the PRESENT tense**

**`ieShadowCompare`.** The `declEnvsRef` row says, in its A-3.2a HISTORY sentence:

> *"`deImpls` has none either outside the **temporary `ieShadowCompare` instrument**"*

**DERIVED: `ieShadowCompare` does not exist in the tree.** 6 total hits in `compiler/`,
**0 non-comment** — and all six describe it in the past tense as *deleted*:

```
typecheck.mdk:19527:  -- #1112 A-3.4 PR2: `ieShadowCompare mid prog0` stood here, and the hard `panic`
typecheck.mdk:19578:  -- real module id at a real ordinal.  The instrument is deleted with `ieShadowCompare`;
```

It was retired by A-3.4 PR2 (#1567) and the stale marker cleanup in `1cb5c8e6`. The ratchet row's
sentence is labelled HISTORY, which mitigates it — but it is a **#1574-class citation of a
non-existent symbol in the file five implementers are about to read**, and it says *"has"*, not
*"had"*. **Remedy: `ieShadowCompare` → past tense, or drop the clause.**

### 7c. Symbols that exist **only in comments** — all correct retirement citations

`universeDataDecls` (0 non-comment), `universeFieldOwners` (0), `registerIfaceParamKinds` (0),
`insertIfaceParamKinds` (0). Each is cited by the ratchet as *retired/deleted*; the tree agrees.
`obUnivConcreteRef`/`obUnivHeadlessRef`/`obUnivIfaceTagsRef`, `universeIfaceParamKinds`,
`universeDataParamKinds`, `ifaceParamKindsRef`, `registerOpaqueParamKinds` each show 1–6
"non-comment" hits — I read **every one**: all are in `compiler/*.md` prose or a `--`-side comment
the strip missed. **No live code references any of them.** ✅

### 7d. Everything else resolves

The remaining **~90** symbols all have live non-comment occurrences. Notable spot-checks:
`declEnvSeedChain` (4), `declEnvSeedDataUniverse` (3), `deKindsBefore`/`deOwnersBefore` (4 each),
`aliasVisibleTo` (3), `ieUniverseAt` (3), `ceSlotKindsAt` (5), `ceRowsOwnedBy` (4),
`ceRowsVisibleAt` (4), `moduleImplUniv` (2), `residualUnivRef` (3), `mangledHeadCandidates` (3).

**Score for #1574:** 3 stale symbol citations in the two rows audited — 1 self-flagged fabrication
(`declEnvSeedRows`, plus its fabricated test `m.demOrd == cur`), 1 correct past-tense deletion
(`ieTriplesUpTo`), **1 newly found present-tense citation of a deleted symbol (`ieShadowCompare`)**.
Do not re-file #1574; add these to it.

---

## 8. Standing hazards for the fleet (all DERIVED above)

1. **Do not read a count.** The ratchet, the arch doc and three PR titles each carry a
   `cross_allowed` number; one of them (`TYPECHECK-TARGET-ARCHITECTURE.md:1803`) is **wrong by
   one**. `sh test/registry_keying_ratchet.sh` prints the live figure in ~1s.
2. **`fieldOwnersRef` is DOUBLE-listed** after `appendDataUniverse:24945` until the next
   `resetState`. Adding a read there turns `mangledHeadCandidates`' singleton gate into the
   give-up arm. Inert today, silent tomorrow.
3. **A-3.6 counts 8 production read paths**, not the 4 the ratchet's prose enumerates.
4. **`test/*.sh` is outside `check_agent_doc_symbols.sh`'s scan** (#1574). Any symbol a sprint
   agent writes into `registry_keying_ratchet.sh` is ungated. Grep it before committing.
