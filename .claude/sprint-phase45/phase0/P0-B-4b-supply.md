# P0-B — Sizing Phase 4b (the selector re-key). SUPPLY analysis.

**Analyst:** packet P0-B, read-only. **Worktree:** `/root/medaka/.claude/worktrees/peppy-brewing-kitten`
**Base commit (pinned):** `aaa437167b633d6070adccd055c8c2a19e9bb8c6`
**Method:** pure static analysis. No build, no gate, no sub-agent. Every `file:line` below was
read at that commit with `awk NR==<line>` / `Read`; anything I could not verify is DELETED or
listed under `## REFUSALS`.

---

## 0. Headline (read this first)

🚨 **The ruling's "one line given an interface" sizing rests on a supply that is UNSOUND FOR THE
BUG 4b is supposed to drain.**

An interface IS obtainable at every `keyForSite` call site — but the only available supply is
`ifaceOfMethodName` / `ifaceParamMonos`, both of which read
`perRun.value.methodIfaceParamsRef`, a map **keyed by bare method NAME**, whose own header says
it hands callers **"the WRONG INTERFACE, silently, in either direction (S0)"** on a bare-name
collision between two unrelated interfaces (`compiler/types/typecheck.mdk:2327-2331`).

#1182 *is* the bare-name method-collision bug. So repointing `keyForSite` to `*ByIface` using
that supply routes the selection through **a second bare-name-keyed table with the same
order-dependence**. The verdict per site is therefore not `IN HAND` and not a clean `DERIVABLE`
— it is **DERIVABLE-BUT-CIRCULAR** for the two sites that matter. Details and the full proof in
§C.

Secondary finding: **`ieEntriesForIface` matches on `ir.irName == iface`, a bare `String`
interface NAME — not the `module::Iface` identity `route_key.mdk` mints.** (`typecheck.mdk:19121-19122`,
signature `:19119`.) So even a perfect supply of `module::Iface` cannot be fed to the peer family
as it stands; the peer family's parameter type is `String` and its comparison is a name. That is
an additional, unbudgeted sub-bite.

Both findings are elaborated below with quoted code.

---

## A. The method-keyed family — definitions and every call site

### A.0 Tree-wide grep (scoped to this worktree)

```
grep -rn 'ieEntriesForMethod\|ieCandidatesForMethod\|ieSelectRowByMethod\|ieCountHeadByMethod\|ieImplExistsForHeadGo\|keyForSite' --include=*.mdk compiler/ stdlib/
```

**VERIFIED — the sprint doc's claim "every hit outside `typecheck.mdk` is a comment" is TRUE.**
All 14 out-of-file hits are `--` comment lines. Proof (each line printed at its exact number):

```
compiler/ir/core_ir_lower.mdk:865:  -- emitter's implFnSymTag/keyForSite choice (C7), so the CAF and the occurrence agree.
compiler/ir/core_ir_lower.mdk:1265: -- dict word.  typecheck's `keyForSiteByIface`/`ieHeadCollidesByIface` are INTERFACE-
compiler/ir/core_ir_lower.mdk:1337: -- union through `dedupS`).  Mirrors typecheck's `keyForSiteByIface`: the bare head
compiler/ir/core_ir_lower.mdk:1340: -- canonical full-type key — the same word `keyForSiteByIface` stamps into the
compiler/ir/core_ir_lower.mdk:1394: -- word (the definition side of the identity-bearing key `keyForSite` stamps at the
compiler/eval/eval.mdk:1963:        -- stamps at the call site (`keyForSite`).  Matched arm-for-arm by
compiler/types/route_key.mdk:7:    -- `ieCandidatesForMethod`'s candidate key — method-name membership plus a head
compiler/types/route_key.mdk:89:   -- `keyForSite`/`keyForSiteByIface`.
compiler/types/route_key.mdk:93:   -- `keyForSite`/`keyForSiteByIface` (`types/typecheck.mdk`), unified — the
compiler/types/route_key.mdk:360:  -- (NOT #1182 — see the header). Applied by `B-2.2-b1` at `keyForSite`.
compiler/backend/llvm_emit.mdk:1352: -- The typechecker stamps the SAME canonical key into the RKey route (keyForSite),
compiler/backend/llvm_emit.mdk:1469: -- and derived the bare head "Box" — while typecheck's `keyForSiteByIface` counts
compiler/backend/llvm_emit.mdk:1502: -- `keyForSiteByIface` picks the bare head tag when the SITE'S MODULE sees no collision
compiler/backend/llvm_emit.mdk:5312: -- `keyForSiteByIface` upgrades a bare head tag to the canonical key only when the
```

⚠️ **Two corrections to the doc's own citation of that derivation.**
- The doc cites the comment set as *"(`core_ir_lower.mdk:1265-1266`, `route_key.mdk:192`)"*. It is
  **four files, 14 lines**, not two files/two sites — `eval.mdk` and `llvm_emit.mdk` also carry
  back-references. Under-citing here does not change the conclusion but it understates the
  comment-level coupling that a re-key will make stale (see §D, `unchecked:`).
- **`route_key.mdk:192` does not mention any of the five named symbols.** Verified:
  `compiler/types/route_key.mdk:192: -- types/typecheck.mdk` (`ieHeadCollidesByMethod`/`…ByIface`, whose sense is`.
  It is a comment about a *different* symbol. The doc's cited line is off; the claim it supports
  survives via lines 7/89/93/360.

### A.1 `ieEntriesForMethod`

**Definition:** `compiler/types/typecheck.mdk:19129`
```
ieEntriesForMethod : List ImplRow -> String -> List Mono -> List KeyEntry
ieEntriesForMethod [] _ _ = []
ieEntriesForMethod ((r@(ImplRow _ _ _ tys _ ms))::rest) name goals
  | contains name ms && ieRowHeadMatches tys goals = keyEntryOfRow r
    ++ ieEntriesForMethod rest name goals
  | otherwise = ieEntriesForMethod rest name goals
```
**Header comment verbatim** (`:19126-19128`):
```
-- The METHOD-keyed candidate scan — the successor of `matchingEntriesGo` (deleted by
-- B-2.1-d).  Same
-- method-name membership test, same head match, same order.
```
**Call sites:** exactly two, both self-recursive-plus-one — `typecheck.mdk:19163` and
`typecheck.mdk:19164`, both inside `ieCandidatesForMethod`. (Recursive occurrences at
`:19133`, `:19134` are the definition's own tail calls.) One further mention at `:18755` is a
comment: `--  🚦 ONE INTERFACE.  \`ieEntriesForMethod\` filters by METHOD NAME, not by interface, so`.

### A.2 `ieCandidatesForMethod`

**Definition:** `compiler/types/typecheck.mdk:19160`
```
ieCandidatesForMethod : ImplEnv -> HeadKey -> String -> List Mono -> List KeyEntry
ieCandidatesForMethod env hk name goals =
  mergeByDeclIdx
    (ieEntriesForMethod (ieHeadRows (Some hk) env) name goals)
    (ieEntriesForMethod (ieHeadRows None env) name goals)
```
**No header comment of its own** — it sits directly under `ieCandidatesForIface`, sharing that
function's long header block (`:19136-19153`).
**Call sites:** exactly **one** — `typecheck.mdk:19189`, inside `ieSelectRowByMethod`.
Comment mentions at `:18569` (`keyForSite`'s "THIS IS NOT #1182" note), `:18629`, `:19056`,
`route_key.mdk:7`.

### A.3 `ieSelectRowByMethod`

**Definition:** `compiler/types/typecheck.mdk:19187`
```
ieSelectRowByMethod : ImplEnv -> String -> List Mono -> Option ImplRow
ieSelectRowByMethod env name goals = match goalHeadCon goals
  Some hk => ieRowOfEntry env (pickMostSpecificEntry goals (ieCandidatesForMethod env hk name goals))
  None => None
```
**Header comment verbatim** (`:19184-19186`):
```
-- 🚨 ENTRY POINT 2 of 3 — the METHOD-keyed row selector, read by leg 3's two
-- element-dict route sites AND (since ARCH B-2.1-g) by the route WORD itself, through
-- `keyForSite`.  It replaced `matchedEntry`, which B-2.1-d deleted.
```
**Call sites — THREE, all in `typecheck.mdk`:**
| # | line | enclosing function |
|---|---|---|
| M1 | `:18559` | `keyForSite` |
| M2 | `:19550` | `implDictRoutesForFull` |
| M3 | `:20284` | `argImplDictRoutesForEncl` |

M2 (`:19550`, verbatim):
```
implDictRoutesForFull implTable keyTable encl name tag resultMono paramMonos = match ieRowHeadTriple (ieSelectRowByMethod perRun.value.bodyImplEnvRef.value name paramMonos)
```
M3 (`:20284`, verbatim):
```
argImplDictRoutesForEncl implTable keyTable encl name _tag mono goals = match ieRowHeadTriple (ieSelectRowByMethod perRun.value.bodyImplEnvRef.value name goals)
```
These are "leg 3's two element-dict route sites" the header names.

### A.4 `ieCountHeadByMethod`

**Definition:** `compiler/types/typecheck.mdk:19412`
```
ieCountHeadByMethod : ImplEnv -> String -> Option HeadKey -> Int
ieCountHeadByMethod env name hd =
  ieCountHeadByMethodGo (ieHeadRows hd env) name (headTabOf hd)

ieCountHeadByMethodGo : List ImplRow -> String -> Option TabKey -> Int
ieCountHeadByMethodGo [] _ _ = 0
ieCountHeadByMethodGo ((ImplRow _ _ _ tys _ ms)::rest) name goal
  | contains name ms && headTabEq (univReceiverTag tys) goal =
    1 + ieCountHeadByMethodGo rest name goal
  | otherwise = ieCountHeadByMethodGo rest name goal
```
(`ieCountHeadByMethodGo` def at `:19417`; guard read verbatim at `:19420`.)
Its header block is the shared one on `ieCountHeadByIface` (`:19268-…`), which states verbatim
`-- FULL DERIVATION FOR BOTH COUNTING SCANS (this one and \`ieCountHeadByMethod\`)`.

**Call sites:** exactly **one** — `typecheck.mdk:19425`:
```
ieHeadCollidesByMethod env name hd = ieCountHeadByMethod env name hd > 1
```
`ieHeadCollidesByMethod` in turn has exactly one call site: `typecheck.mdk:18561`, inside
`keyForSite`.

### A.5 `ieImplExistsForHeadGo`

**Definition:** `compiler/types/typecheck.mdk:15441`
```
ieImplExistsForHeadGo : List ImplRow -> String -> TabKey -> Bool
ieImplExistsForHeadGo [] _ _ = False
ieImplExistsForHeadGo ((ImplRow _ _ _ tys _ ms)::rest) name goal
  | headTabIs (univReceiverTag tys) goal && contains name ms = True
  | otherwise = ieImplExistsForHeadGo rest name goal
```
(guard line `:15444` read directly — note the conjunct ORDER is head-first here and
method-first in `ieCountHeadByMethodGo`; extensionally the same, worth not "tidying".)
**Call sites:** exactly **one** — `typecheck.mdk:15428`, inside `ieImplExistsForHead`:
```
  ieImplExistsForHeadGo (ieHeadRows (Some hk) env) name (dispHeadTab hk)
```
Its reachable wrapper `ieImplExistsForHead` (`:15425`) has **three** call sites, all
`typecheck.mdk`, all off `perRun.value.bodyImplEnvRef.value`:
`:11660` (`inferApp` shadow-head arm), `:11957`, `:15549`.
Comment mentions at `:2448`, `:4168`, `:6918`, `:6927`, `:11795`, `:11954`, `:15328`,
`:15356`, `:15487`, `:15543`, `:21264`, `:22470`.

⚠️ **`ieImplExistsForHeadGo` is an EXISTENCE test, not a selector.** It answers "does any impl
define this method at this head" and never picks a row. Re-keying it by interface is a
*different* semantic change from re-keying a selector — see §C.5 and §E.

### A.6 `keyForSite`

**Definition:** `compiler/types/typecheck.mdk:18556`
```
keyForSite : String -> List Mono -> Option String
keyForSite name goals =
  let env = perRun.value.bodyImplEnvRef.value
  match ieSelectRowByMethod env name goals
    Some (ImplRow _ _ ir tys _ _) =>
      if ieHeadCollidesByMethod env name (univReceiverTag tys) then
        …
        Some (implRouteKeyWord ir.irOrigin ir.irName tys None)
      else
        …
        Some (headKeyNameOr noneHeadTag (univReceiverTag tys))
    None => None
```
Its header is ~70 lines (`:18485-18555`). The two load-bearing extracts, verbatim:
- `:18569-18571`: `-- ⚠️ THIS IS NOT #1182: that bug is \`ieCandidatesForMethod\`'s` /
  `-- interface-free candidate key, UPSTREAM of this word, and on its own` /
  `-- one-file repro this substitution is a NO-OP (absent origin ⇒ bare name).`
- `:18536-18537`: `--  1. \`keyForSite\` is reached ONLY from the five \`resolve*\` stamp passes, and those run` /
  `--     in \`elabModuleStamp\`, i.e. inside \`elaborateModules\`.`

**Call sites — THREE, all in `typecheck.mdk`:**
| # | line | enclosing function / arm |
|---|---|---|
| K1 | `:15821` | (see §C, inside the `implFnSymTag`/monos leg — `let key = fromOption tag (keyForSite method [operandMono])`) |
| K2 | `:19911` | `entailInst … (EKReturn keyTable fullMono _)` |
| K3 | `:19954` | `entailInst … (EKArg keyTable fullMono)` |

Comment mentions (not calls): `:4167`, `:6597`, `:15277`, `:15487`, `:15492`, `:15545`,
`:18258`, `:18307`, `:18376`, `:18426`, `:18503`, `:18536`, `:19046`, `:19056`, `:19061`,
`:19071`, `:19222`, `:19227`, `:19231`, `:19259`, `:19287`, `:19290`, `:19313`, `:19323`,
`:19379`, `:19774`, `:19781`, `:19795`, `:19804`, `:19920`, `:22490`, `:22496`, `:22500`,
`:22508`, plus the 14 out-of-file lines in §A.0.

---

## B. The `*ByIface` peer family

### B.1 `ieEntriesForIface`
**Definition:** `compiler/types/typecheck.mdk:19119`
```
ieEntriesForIface : List ImplRow -> String -> List Mono -> List KeyEntry
ieEntriesForIface [] _ _ = []
ieEntriesForIface ((r@(ImplRow _ _ ir tys _ _))::rest) iface goals
  | ir.irName == iface && ieRowHeadMatches tys goals = keyEntryOfRow r
    ++ ieEntriesForIface rest iface goals
  | otherwise = ieEntriesForIface rest iface goals
```
**Header verbatim** (`:19112-19118`):
```
-- The iface-keyed candidate scan: every row of [rows] whose interface is [iface]
-- and whose head pattern matches [goals], as `KeyEntry`s, ORDER PRESERVED.  The
-- peer of the deleted `matchingEntriesByIfaceGo`, one substrate over — same
-- `ifn == iface` filter (NOT method-name membership, so a specific impl inheriting
-- a method via a DEFAULT is still seen) and the same `entryHeadMatches`.
-- `keyEntryOfRow r` is a ONE-element list on this arm (the guard proved `tys`
-- non-empty), so the `++` is a single cons.
```
**Call sites:** two — `:19157`, `:19158`, both inside `ieCandidatesForIface`. Comment
mentions at `:18762`, `:20047`.

### B.2 `ieCandidatesForIface`
**Definition:** `:19154`
```
ieCandidatesForIface : ImplEnv -> HeadKey -> String -> List Mono -> List KeyEntry
ieCandidatesForIface env hk iface goals =
  mergeByDeclIdx
    (ieEntriesForIface (ieHeadRows (Some hk) env) iface goals)
    (ieEntriesForIface (ieHeadRows None env) iface goals)
```
**Call sites:** one — `:19181`, inside `ieSelectRowByIface`. Comment mentions `:18629`, `:22638`.

### B.3 `ieSelectRowByIface`
**Definition:** `:19179`
```
ieSelectRowByIface : ImplEnv -> String -> List Mono -> Option ImplRow
ieSelectRowByIface env iface goals = match goalHeadCon goals
  Some hk => ieRowOfEntry env (pickMostSpecificEntry goals (ieCandidatesForIface env hk iface goals))
  None => None
```
**Header verbatim** (`:19166-19178`) — `ENTRY POINT 1 of 3`, ending:
```
-- A goal with no head tycon keys no bucket and selects nothing — the `None => None` arm
-- below, which is what `matchingEntries`' `None => []` arm did before B-2.1-d.
```
**Call sites — three, all `typecheck.mdk`:** `:19252` (`keyForSiteByIface`),
`:20227` (`ieRowHeadTriple (ieSelectRowByIface … iface goals)` — the `selectReqImpl` leg),
`:22674` (`concreteReqMatchByIface iface args = match ieSelectRowByIface … iface args`).

### B.4 `ieCountHeadByIface`
**Definition:** `:19340`
```
ieCountHeadByIface : ImplEnv -> String -> Option HeadKey -> Int
ieCountHeadByIface env iface hd =
  ieCountHeadByIfaceGo (ieHeadRows hd env) iface (headTabOf hd)

ieCountHeadByIfaceGo : List ImplRow -> String -> Option TabKey -> Int
ieCountHeadByIfaceGo [] _ _ = 0
ieCountHeadByIfaceGo ((ImplRow _ _ ir tys _ _)::rest) iface goal
  | ir.irName == iface && headTabEq (univReceiverTag tys) goal =
    1 + ieCountHeadByIfaceGo rest iface goal
  | otherwise = ieCountHeadByIfaceGo rest iface goal
```
**Call sites:** one — `:19266`, `ieHeadCollidesByIface env iface hd = ieCountHeadByIface env iface hd > 1`.
`ieHeadCollidesByIface` in turn: one call site, `:19254`, inside `keyForSiteByIface`.

### B.5 `keyForSiteByIface`
**Definition:** `:19249` (body quoted in §C.2).
**Call sites:** exactly **one** — `:19939`, `entailInst`'s `EKNestedTop` arm:
```
entailInst implTable _ m encl tag (EKNestedTop keyTable iface _ depth rest) =
  let routeKey = fromOption tag (keyForSiteByIface iface (m::rest))
```
**Note the shape of the supply here**: `iface` arrives as a *field of the `EntailKind`
constructor*, `EKNestedTop keyTable iface _ depth rest`. It is not derived at the site — it was
carried in. That is the existence proof that this style of supply is possible, and §C measures
how far the other two arms are from it.

### B.6 🎯 STRUCTURAL-IDENTITY CLAIM — CONFIRMED, with two amendments

The doc claims `ieSelectRowByIface` and `ieSelectRowByMethod` are *"structurally identical —
same `goalHeadCon` match, same `pickMostSpecificEntry`, same `ieRowOfEntry` — differing only in
which candidate function they call, which differ only in `iface`-match vs `contains name ms`."*

**CONFIRMED.** Diffing the two bodies quoted above, character by character, the only difference
is `ieCandidatesForIface`↔`ieCandidatesForMethod` and the parameter's name (`iface`↔`name`).
Both parameters are `String`; both selectors have the identical type
`ImplEnv -> String -> List Mono -> Option ImplRow`. Descending one level:
`ieCandidatesForIface`/`…ForMethod` are identical modulo `ieEntriesForIface`↔`ieEntriesForMethod`.
Descending again: those differ in exactly the guard's first conjunct,
`ir.irName == iface` vs `contains name ms`, plus the destructuring pattern needed to reach the
field (`ImplRow _ _ ir tys _ _` vs `ImplRow _ _ _ tys _ ms`). Nothing else.

**AMENDMENT 1 — the substitution is TYPE-COMPATIBLE, so the compiler cannot catch a bad supply.**
Both selectors are `String -> …`. Passing a method name where an interface name is expected is
**silently well-typed**. There is no type-level guard on this re-key; the whole correctness
burden falls on the caller supplying the right `String`. This raises the review bar for 4b
considerably and is not mentioned in the ruling.

**AMENDMENT 2 — 🚨 THE PEER FAMILY IS ITSELF BARE-NAME-KEYED, NOT IDENTITY-KEYED.**
`ieEntriesForIface`'s filter is `ir.irName == iface` (`:19122`) and `ieCountHeadByIfaceGo`'s is
`ir.irName == iface` (`:19348`) — the interface **NAME** off the row's `IfaceRef`, *not*
`ir.irOrigin`, and *not* the `module::Iface` word `implRouteKeyWord ir.irOrigin ir.irName …`
mints two lines away at `:18578`/`:19257`. The `IfaceRef` carries the origin beside the name —
`keyForSite`'s own comment says so at `:18563-18564`: *"`ir.irOrigin` is in hand here —
`ImplRow`'s `IfaceRef` field carries the origin beside the name"* — and the peer family
throws it away.

⇒ **Repointing `keyForSite` to `*ByIface` does NOT make selection identity-keyed.** It moves the
candidate key from *method name* to *interface name*. Two same-spelled interfaces in two
modules (the #1047/#1265 family, which `keyForSite:18566-18568` names explicitly) remain
collapsed in the candidate set. This is a real narrowing of #1182's specific shape (two
DIFFERENT-named interfaces sharing a method name) but it is **not** the C4/I2 constraint the
sprint's §3 states for Phase 4: *"key the frozen table by INTERFACE IDENTITY (`module::Iface`),
not by `(method, head)`."* 4b as ruled satisfies neither half of that spelling.

---

## C. 🎯 THE SUPPLY VERDICT

### C.0 The site inventory being graded

Reducing the method-keyed family to its *reachable* decision sites (§A), everything funnels
through three `entail` arms plus one operator stamper:

| id | site | expression at the line | reached from |
|---|---|---|---|
| **K1** | `:15821` | `let key = fromOption tag (keyForSite method [operandMono])` | `stampOpRouteVal` ← `entailInst` EKOp `:19969` |
| **K2** | `:19911` | `let routeKey = fromOption tag (keyForSite name paramMonos)` | `entailInst` EKReturn |
| **K3** | `:19954` | `let routeKey = fromOption tag (keyForSite name goals)` | `entailInst` EKArg |
| **C1** | `:18561` | `if ieHeadCollidesByMethod env name (univReceiverTag tys)` | inside `keyForSite` |
| **M2** | `:19550` | `ieSelectRowByMethod perRun.value.bodyImplEnvRef.value name paramMonos` | `implDictRoutesForFull` ← EKReturn `:19914` |
| **M3** | `:20284` | `ieSelectRowByMethod perRun.value.bodyImplEnvRef.value name goals` | `argImplDictRoutesForEncl` ← EKArg `:19967` (`dictName`) and ← `argImplDictRoutesFor` `:20248` ← `stampOpRouteVal` `:15831` (`dictMethod`) |
| **X1** | `:11660` | `ieImplExistsForHead perRun.value.bodyImplEnvRef.value mname head` | `inferApp` shadow-head arm |
| **X2** | `:11957` | `ieImplExistsForHead perRun.value.bodyImplEnvRef.value name head` | shadow scheme leg |
| **X3** | `:15549` | `(not (isDefinerShadow name) && ieImplExistsForHead perRun.value.bodyImplEnvRef.value name tag)` | shadow/standalone leg |

### C.1 What supplies exist at all — the candidates, enumerated

**(a) A carried-in `iface` field on the `EntailKind`.** This is how the *already*-iface-keyed
site works: `EKNestedTop KeyBuckets String Undetermined Int (List Mono)` (`:19794`) has a
`String` iface field, destructured at `:19938` and used at `:19939`. **`EKReturn KeyBuckets Mono Bool`
(`:19783`) and `EKArg KeyBuckets Mono` (`:19803`) have no such field.** `EKOp Bool KeyBuckets Bool`
(`:19809`) has none either.

**(b) `ifaceOfMethodName : String -> Option String` (`:24507`).**
```
ifaceOfMethodName name = map
  ((iface, _, _, _) => iface.irName)
  (omLookup name perRun.value.methodIfaceParamsRef.value)
```
🚨 **This is a `perRun` lookup keyed on the BARE METHOD NAME, and it is already on the ladder.**
`entailAssum` calls it at `:19869` (`None => match ifaceOfMethodName name`), one rung above every
site in C.0. So it costs **zero plumbing** at K2/K3/M2 — it is literally an expression already
evaluated for the same `name` in the same call.

**(c) `ifaceParamMonos` (`:15313`)** — same table, already called on the very lines above K2 and
K3 (`:19910`, `:19953`).

**(d) There is no fourth candidate.** `EMethodAt` — the node that records a route site — is
`EMethodAt String (Ref Route) (Ref (List Route)) (Ref (List Route))`
(`compiler/frontend/ast.mdk:919`): a bare method-name `String` and three route cells. `EMethodRef
String` (`ast.mdk:875`) likewise. `marker.mdk:90` mints it as `| omHasKey x methods = EMethodRef x`
— name in, name out. `PendingEntry name tagRef …` (`:9033`, `:6556`) carries a bare name.
`inferMethodAt : TcEnv -> String -> …` (`:8843`) takes a bare name. **No interface identity is
carried on the route-stamping path at any point.**

### C.2 🚨 THE SUPPLY IS CIRCULAR — supply (b) is the SAME bare-name-keyed table that IS #1182

`methodIfaceParamsRef`'s own header, verbatim, `compiler/types/typecheck.mdk:2322-2333`:

```
-- #147: keyed by method NAME (was a program-sized assoc List scanned linearly on
-- hot per-node paths).  omInsert is last-write-wins and the register site inserts
-- in the SAME order the old List prepended, so on a method-name collision the
-- latest-registered entry wins — identical to the old `lookupAssoc` first-match.
--
-- 🚨 #1111 A-2.5 (#1092): "identical to the old first-match" is TRUE and was never the
-- point.  BOTH forms pick by REGISTRATION ORDER, and neither picks by what the
-- occurrence resolved to — so on a bare-name collision between two unrelated
-- interfaces this table hands `recordImplObligation` / `ifaceParamMonos` the WRONG
-- INTERFACE, silently, in either direction (S0).  The table stays name-keyed here (it
-- is per-module state and a module's scope binds a bare method name to at most one
-- declaration — resolve rejects the ambiguous case outright).
```

⚠️ **The parenthetical justification is FALSE for #1182's shape, and #1182's own pin proves it.**
The pin is ONE FILE with two interfaces, `test/must_fail_fixtures/1182-two-ifaces-same-method-name-order-decides/main.mdk:12-22`:
```
interface A1 a where
  m : a -> Int

interface A2 a where
  m : a -> Int

impl A1 (Q Int y z) where
  m _ = 1

impl A2 (Q x Bool z) where
  m _ = 2
```
`claim.txt:17-18` records `medaka check --json main.mdk -> {"diagnostics":[]}, exit 0 (silent)`.
So resolve does **not** reject this; the module's scope binds `m` to **two** declarations, and
`methodIfaceParamsRef["m"]` holds exactly one of them — chosen by **interface declaration order**.

⇒ **Repointing `keyForSite name goals` → `keyForSiteByIface (ifaceOfMethodName name) goals`
does not remove the order dependence. It MOVES it, from the order of the two `impl` blocks to
the order of the two `interface` blocks.** The candidate set becomes one interface's impls only,
so `main.mdk` and `control.mdk` converge and **the pin drains** (`claim.txt:61-62`: *"converge on
2 … -> DRAINED"*). But permuting the two `interface` blocks — a permutation the pin does not
perform — reintroduces a wrong value at exit 0 with no diagnostic.

🚨 **This is the "a fix that makes a defect QUIETER is a severity INCREASE" shape, dressed as a
drain.** The must-fail fixture would go green and instruct the next agent to close #1182, while
the S0 class survives under a different permutation that no gate in the tree performs.
**4b MUST ship an interface-permutation control** (a file permuting `interface A1` / `interface A2`
and nothing else) or it is a self-draining pin certifying its own blind spot.

### C.3 🚨 THE IDENTITY-KEYED COMPANION CANNOT FIX IT EITHER — `Ident` has no interface component

The obvious remedy — "use the identity-keyed table, not the name-keyed one" — is **closed on
this tree**, and the proof is two definitions:

`compiler/frontend/ast.mdk:310`:
```
public export data Ident = Ident Ns IdentOrigin String deriving (Eq, Ord, Debug)
```
`typecheck.mdk:16834` / `:16937` mint a method's identity as `mkIdent NsMethod origin mname`,
where `origin` is the **interface's `ifaceOrigin`**, i.e. its **MODULE**. So for two interfaces
declared in the SAME module sharing a method name, `A1.m` and `A2.m` produce **the identical
`Ident`** — `Ident NsMethod <this module> "m"`. Nothing in `Ident` names the interface.

The consequence is mechanical and it disables the whole overlay, `:16844-16851`:
```
addMethodIdentCand mname ident payload (cands, collided) =
  let prior = dropMethodIdentCand ident (fromOption [] (omLookup mname cands))
  let next = prior ++ [(ident, payload)]
  (
    omInsert mname next cands,
    if listLen next >= 2 && not (contains mname collided) then mname::collided else collided,
  )
```
`dropMethodIdentCand ident` (`:16853`, guard `| i == ident`) **removes A1's entry** when A2 is
inserted, because the idents are equal. So `next` has length **1**, `listLen next >= 2` is
False, and `"m"` is **never added to the collided list**. `applyMethodScopeOverrides`
(`:16869`) *"Iterates the collided list — not the table"* (`:16861-16862`), so it iterates past
`"m"` entirely and the floor's last-write-wins answer stands unchallenged.

⇒ **On #1182's shape, the tree's identity machinery is not merely unused — it is structurally
incapable of representing the distinction, and it silently reports "no collision".**

### C.4 Per-site verdicts

| id | interface IN HAND? | derivable? | **VERDICT** |
|---|---|---|---|
| **K1** `:15821` | No | `ifaceOfMethodName method`, 0 signatures | **DERIVABLE (0 signatures) — but CIRCULAR (C.2), and see C.5** |
| **K2** `:19911` | No | `ifaceOfMethodName name`; already evaluated for the same `name` at `:19869` | **DERIVABLE (0 signatures) — CIRCULAR (C.2)** |
| **K3** `:19954` | No | same as K2 | **DERIVABLE (0 signatures) — CIRCULAR (C.2)** |
| **C1** `:18561` | follows `keyForSite`'s parameter | — | **IN HAND once `keyForSite` takes one** (it is inside the function being re-keyed; `ieHeadCollidesByIface`/`ieCountHeadByIface` already exist, `:19265`/`:19340`) |
| **M2** `:19550` | No | `ifaceOfMethodName name`, 0 signatures | **DERIVABLE (0 signatures) — but see C.5: re-keying it is a SEMANTIC CHANGE the source forbids** |
| **M3** `:20284` | No | `ifaceOfMethodName dictName`; note `dictName`/`dictMethod` may be `innerDefaultMethod name` | **DERIVABLE (0 signatures) — but see C.5: re-keying it is a SEMANTIC CHANGE the source forbids** |
| **X1** `:11660` | No | — | **NOT A RE-KEY TARGET** (existence, not selection — C.6) |
| **X2** `:11957` | No | — | **NOT A RE-KEY TARGET** (C.6) |
| **X3** `:15549` | No | — | **NOT A RE-KEY TARGET** (C.6) |

**No site is `IMPOSSIBLE HERE` for the WEAK (bare interface-NAME) supply.** For the STRONG
supply — a genuine `module::Iface` interface identity, which is what C4/I2 demands of Phase 4 —
the verdict flips:

| id | STRONG supply (`module::Iface`) verdict |
|---|---|
| K1, K2, K3, M2, M3 | **IMPOSSIBLE HERE without a cross-file change.** The identity does not exist anywhere on the path (C.1(d)), and `Ident` cannot express it at all (C.3). Constructing it requires (i) widening `Ident` or minting an interface-qualified method identity — `compiler/frontend/ast.mdk`; (ii) carrying it on `EMethodRef`/`EMethodAt` — `ast.mdk` + `compiler/frontend/marker.mdk`; (iii) threading it through `PendingEntry`, `EKReturn`/`EKArg`/`EKOp`, `entailInst`, `keyForSite`, `implDictRoutesForFull`, `argImplDictRoutesForEncl` — `typecheck.mdk`; and (iv) re-keying `ieEntriesForIface`/`ieCountHeadByIfaceGo` off `ir.irName` onto the identity — `typecheck.mdk`. **≥ 3 files, ≥ 8 signatures, plus a new AST constructor field.** |

🚨 **This directly refutes the ruling's "inside one file" scoping — for the strong fix.** The
ruling is correct that the *engines* are untouched; it is **wrong** that the work is confined to
`typecheck.mdk`, because the supply it treats as a free variable does not exist and cannot be
made to exist inside that file. The one-file sizing is only true of the **weak** fix, and the
weak fix does not satisfy C4/I2's own stated constraint (sprint doc §3: *"keyed by INTERFACE
IDENTITY (`module::Iface`)"*).

⚠️ Note the shape this reproduces: it is the memory-indexed **"an impossible fix site is the
root cause"** pattern. The reason `keyForSite` is method-keyed is not an oversight to be
substituted away — it is that **no interface identity is manufactured anywhere upstream of it.**

### C.5 🚨 A SECOND, INDEPENDENT REFUTATION: re-keying M2/M3 COLLAPSES a distinction the source explicitly forbids collapsing

`typecheck.mdk:19838-19845`, verbatim, inscribed on the ladder for exactly this reason:
```
-- 🚨 IT IS A REACHABILITY PROPERTY, NOT A COUNT — AND THE COUNT FORM IS FALSE ON A
-- CORRECT TREE.  There are legitimately TWO selector calls per `inst` arm: one for the
-- primary route word, one inside the element-route helper.  At `EKArg` and `EKOp` those
-- two deliberately ask about DIFFERENT methods — the element helper is keyed on the
-- `innerDefaultMethod`-reduced name when the head's impl does not itself define the
-- method (`ieDefinesReqMethodAt`).  Any *"one selector call per arm"* rule would license
-- collapsing them, which changes WHICH IMPL'S CONTEXT IS DISCHARGED (§6 C2).  Do not
-- restate this property in the count form.
```
And `innerDefaultMethod`'s own header, `:15838-15841`:
```
-- The inner same-interface method an interface DEFAULT reduces to, supplying the
-- element `requires` dicts.  Ord's `lt`/`gt`/`lte`/`gte`/`min`/`max` defaults all
-- reduce to `compare`; any other relational/equality method has its own impl so the
-- `ieDefinesReqMethodAt` guard keeps it on `method`, never reaching here.
```
Body, `:15842-15847`:
```
innerDefaultMethod m =
  if contains m ["lt", "gt", "lte", "gte", "min", "max"] then
    "compare"
  else
    m
```

**The reduction is SAME-INTERFACE by construction** (`lt` → `compare`, both `Ord`). Therefore
`ifaceOfMethodName name` and `ifaceOfMethodName (innerDefaultMethod name)` return the same
interface. **Re-keying K3 and M3 by interface makes the two selector calls in the EKArg arm ask
the identical question** — precisely the collapse the inscribed property says *"changes WHICH
IMPL'S CONTEXT IS DISCHARGED (§6 C2)"*. Same for K1 / M3-via-`stampOpRouteVal`.

The behavioural difference is concrete, not theoretical. `ieEntriesForIface`'s own header
(`:19115-19116`) states the widening verbatim:
```
-- `ifn == iface` filter (NOT method-name membership, so a specific impl inheriting
-- a method via a DEFAULT is still seen)
```
So an `impl Ord (Box a) requires Ord a` that defines `compare` and INHERITS `lt` is **invisible**
to `keyForSite "lt"` today and **visible** to an iface-keyed selector after the re-key. That
changes the stamped route word for every Ord-default operator/arg site over a default-inheriting
impl ⇒ **it changes emitted IR**, ⇒ the fixpoint and the goldens move. `keyForSite`'s own header
already names the version of this that *"moves the seed and every golden"* (`:18496-18499`).

⇒ **M2/M3 are not part of a "one line" substitution and must not ride in the same bite as
K1/K2/K3.** Grouping them is the sizing error. Note also that this widening applies to K1/K2/K3
themselves — the primary route word — so **even the weak fix is not byte-neutral on emitted IR**,
contrary to the impression *"on its own one-file repro this substitution is a NO-OP"*
(`keyForSite`'s header, `:18571`) leaves. That sentence is about the `implRouteKeyWord` origin
substitution of B-2.2-b1, **not** about the selector re-key; do not read it as a no-op claim for 4b.

### C.6 Why X1–X3 are not re-key targets

`ieImplExistsForHead` (`:15425`) answers *"does any impl define METHOD `name` at head `hk`"*.
Its three callers (`:11660`, `:11957`, `:15549`) are shadow/definer guards choosing between a
method occurrence and a user's same-named standalone function — a **method-name** question by
construction. There is no interface in the question, so "supply an interface" is not a
well-posed ask here. `ieImplExistsForHeadGo` is listed in the ruling's family; **it should be
struck from 4b's target list.**

---

## D. Sizing 4b

**4b is NOT one bite and it is not "one line".** It is **five units**, of which one is a decision
that must precede any code, one is a fixture that must land BEFORE the fix to be fail-capable,
and one (D-5) is optional-but-required-for-conformance.

Everything below is scoped to `compiler/types/typecheck.mdk` except D-5, which is not.

### D-0 — 🚦 OWNER DECISION, no code: WEAK or STRONG supply?

Not sizable as a bite; it is the question §C forces. **WEAK** = candidate set scoped by interface
NAME, supplied by `ifaceOfMethodName` (`:24507`) — one file, but §C.2's displaced order
dependence and §B.6 Amendment 2's failure to meet C4/I2's `module::Iface` spelling. **STRONG** =
candidate set scoped by interface IDENTITY — ≥3 files, a new AST field, ≥8 signatures (§C.4).
**The ruling assumed WEAK without naming the choice.** Phase 4's C4/I2 constraint says STRONG.
These are different sprints. **Land nothing until this is ruled.**

### D-1 — the permutation control, BEFORE any fix

- **what:** add a third file to `test/must_fail_fixtures/1182-two-ifaces-same-method-name-order-decides/`
  permuting the two `interface` blocks (and nothing else), plus the `claim.txt` rows that grade
  it. Today the fixture permutes only `impl` blocks (`main.mdk` vs `control.mdk`,
  `claim.txt:47-49`).
- **why first:** §C.2 — the WEAK fix drains the existing pin while displacing the S0 onto the
  interface-declaration order. Without this file the pin certifies its own blind spot and
  instructs the next agent to close #1182 (`claim.txt:61-71`).
- `could move:` `test/diff_compiler_must_fail.sh` (the fixture directory is its corpus).
  ⚠️ The shared-corpus trap applies — enumerate the consumers of
  `test/must_fail_fixtures/` before adding, do not trust a count.
- `nearest miss:` the added file reproduces *today* for the same reason `main.mdk` does, so it
  looks like a duplicate row. It is not: it is the row that will still reproduce after the WEAK
  fix. Its value is entirely post-fix.
- `engines:` `run` only, matching the existing rows' `why-verb` (`claim.txt:32-37`).
- `unchecked:` whether the harness supports a second control per fixture, or whether this needs
  a sibling fixture directory. **Not derivable without reading `diff_compiler_must_fail.sh`,
  which is outside this packet's scope — see REFUSALS R2.**

### D-2 — re-key the ROUTE WORD: `keyForSite` (covers K1, K2, K3, C1)

- **what:** give `keyForSite` an interface and repoint its two internals —
  `ieSelectRowByMethod` → `ieSelectRowByIface` (`:18559`) and `ieHeadCollidesByMethod` →
  `ieHeadCollidesByIface` (`:18561`). Both peers exist (`:19179`, `:19265`). Supply per D-0.
- **sites, grep-proven:** the definition `:18556-18593`; the three callers `:15821`, `:19911`,
  `:19954` (unchanged if the interface is derived inside `keyForSite`; changed if it becomes a
  parameter).
- **this is 2 lines inside one function** — the ruling's sizing is correct **for this unit
  alone**, and this unit alone is what the ruling appears to have measured.
- `could move:` **emitted IR.** §C.5 — `ieEntriesForIface` sees default-inheriting impls that
  `ieEntriesForMethod` does not (`:19115-19116`), so the winner, hence the stamped word, changes
  wherever a method is inherited via an interface default. ⇒ the self-compile fixpoint, the
  seed, `test/snapshots/`, `test/selfproc_goldens/legA/types.typecheck.golden`.
- `nearest miss:` a program where two interfaces share a method name AND the winning impl is
  the one `methodIfaceParamsRef` did *not* register — i.e. the interface-permutation of #1182.
  D-1 is exactly this fixture.
- `engines:` `keyForSite` is **elaborate-only** (`:18531`), so `medaka check` cannot observe it
  (`:18536-18546`). Grade on `run` **and** `build`+exec, never on `check`.
- `unchecked:` whether `ifaceOfMethodName` returns `None` at any live site (a non-method name
  routed through here). `:24504-24506` says a non-method name is *absent* from the table →
  `None`. **The `None` behaviour must be specified before this lands** — falling back to the
  method-keyed selector re-opens the bug on exactly those sites; failing closed narrows
  acceptance. This is undecided in the ruling.

### D-3 — the element-dict helpers: M2 / M3. **SEPARATE BITE, and possibly OUT of 4b**

- **what:** `implDictRoutesForFull` `:19550` and `argImplDictRoutesForEncl` `:20284`.
- **why separate:** §C.5. Re-keying these makes the two selector calls per `inst` arm ask the
  identical question, which `:19838-19845` says *"changes WHICH IMPL'S CONTEXT IS DISCHARGED
  (§6 C2)"* and instructs future work not to license. **A bite that does D-2 and D-3 together
  cannot attribute a fixpoint move to either.**
- `could move:` emitted IR, more broadly than D-2 (element dicts are the `requires` chain).
- `nearest miss:` an `impl Ord (Box a) requires Ord a` defining `compare` and inheriting `lt`,
  used at an operator site. Named verbatim in the tree at `:15856-15860` as an existing repro
  shape.
- `engines:` `run` + `build`+exec; `check` blind for the same reason as D-2.
- `unchecked:` **whether this should happen at all.** My reading is that #1182 is a defect of
  the primary route WORD's candidate set, and D-3 is a distinct semantic change with its own
  risk profile that no open issue currently asks for. **Recommend D-3 is deferred and filed,
  not bundled.**

### D-4 — strike `ieImplExistsForHeadGo` from the target list

- **what:** documentation/scope only. §C.6 — it is an existence test whose question has no
  interface in it. Its three callers (`:11660`, `:11957`, `:15549`) are shadow guards.
- `could move:` nothing. `nearest miss:` n/a. `engines:` n/a.
- `unchecked:` none.

### D-5 — (STRONG supply only) the identity plumbing. **NOT one file.**

- **what:** §C.4's strong-supply row — an interface-qualified method identity minted in
  `compiler/frontend/ast.mdk`, carried on `EMethodRef`/`EMethodAt` (`ast.mdk:875`, `:919`) and
  minted by `compiler/frontend/marker.mdk:90`, threaded through `PendingEntry`, `EntailKind`
  (`:19783`, `:19794`, `:19803`, `:19809`), `entailInst`, `keyForSite`, and the two element
  helpers; then `ieEntriesForIface` `:19122` and `ieCountHeadByIfaceGo` `:19348` re-keyed off
  `ir.irName` onto `ir.irOrigin`+`ir.irName`.
- **≥ 3 files, ≥ 8 signatures, one new AST constructor field.**
- `could move:` everything D-2 moves, plus the parse/desugar/resolve snapshot corpus (a new AST
  field), plus every LEG A golden.
- `nearest miss:` any program with two interfaces in one module sharing a method name — §C.3
  proves today's `Ident` cannot tell them apart, so the *first* thing this bite must prove is
  that its new identity CAN.
- `engines:` full — this is an AST change; the new-AST-constructor wildcard trap applies
  (`AGENTS.md`: audit the `_ =>` arms as a SET).
- `unchecked:` **everything.** This is a design run, not a bite. Sizing it further from static
  reading alone would be inventing a number — see REFUSALS R3.

### Landing order

`D-0` (ruling) → `D-1` (fail-capable control) → `D-2` (the actual re-key) → `D-4` (scope
correction, free) → then either `D-5` (if STRONG) or file `D-3` and stop.

**Bite count: 3 landable code/fixture bites (D-1, D-2, D-4) under the WEAK ruling; 4 under
STRONG, where the fourth is a design run of its own.** Not one.

---

## E. What 4b does NOT drain — mechanism-by-mechanism

The ruling names #1617, #1619, #1620, #1608 and #1182 around 4b. Reading each issue body and
comparing its stated mechanism against §A/§B/§C:

| issue | doc's position | **my verdict** | mechanism |
|---|---|---|---|
| **#1182** | drained by 4b | **YES — pin drains; CLASS DOES NOT** | See below |
| **#1617** | explicitly NOT drained | **NO — AGREE with the doc** | See below |
| **#1619** | in the conjunct-1 drain list | 🚨 **NO — I DISAGREE WITH THE DOC** | See below |
| **#1620** | in the conjunct-1 drain list | ⚠️ **UNVERIFIABLE — the doc's assignment is unsupported** | See below |
| **#1608** | genuine engine defect, not 4b's | **NO — AGREE with the doc** | See below |

### #1182 — YES for the pin, NO for the class

`ieCandidatesForMethod` (`:19160`) unions candidates by `contains name ms` (`:19132`), so `A1`'s
and `A2`'s impls of `m` land in one set and `pickMostSpecificEntry` ranks across interfaces —
exactly the issue's stated mechanism (*"`matchingEntries` selects candidates by method-name
membership … not by interface"*). Scoping the set to one interface removes the cross-interface
ranking, so `main.mdk` and `control.mdk` converge and the pin drains per `claim.txt:61-62`.

🚨 **But the class does not drain, and §C.2 is the proof:** the interface that scopes the set is
itself chosen by `methodIfaceParamsRef`'s bare-name last-write-wins, i.e. by **interface
declaration order**. The issue's own framing — *"Which interface the occurrence of `m` belongs
to is a **name-resolution** question. It cannot depend on the order of `impl` blocks"* — applies
verbatim to the replacement: it cannot depend on the order of `interface` blocks either. #1182's
disposition option 1 is *"Scope the candidate set by interface … identity resolved, never
re-derived from spelling"*; **the WEAK fix re-derives it from spelling plus registration order,
so it does not implement option 1.** ⇒ 4b-as-ruled **closes the ticket without fixing the
defect it names.**

### #1617 — NO (agreeing with the doc, for the doc's reason)

Its repro has **ONE interface**, `Sz`, with two impls (`impl Sz (Int -> Int)` / `impl Sz (Bool ->
Bool)`). Scoping the candidate set by interface scopes it to `Sz` — **the same set**. The stated
mechanism is `headTyconTy`'s `_ => None` wildcard putting both `TyFun` heads into `noneHeadTag`,
which is upstream of every function in §A and §B: it corrupts the *bucket*, not the *filter*.
`goalHeadCon`'s `None => None` arm (`:19182`/`:19190`) is identical in both selectors. **Nothing
in the re-key touches it.**

### #1619 — 🚨 NO. The doc is WRONG to put this in 4b's drain list.

Two independent reasons, both mechanical:

1. **The two colliding interfaces are BOTH SPELLED `Tag`.** `ieEntriesForIface`'s filter is
   `ir.irName == iface` (`:19122`) and `ieCountHeadByIfaceGo`'s is `ir.irName == iface`
   (`:19348`) — a bare **NAME** compare (§B.6 Amendment 2). `di.Tag` and `other.Tag` both match
   `iface == "Tag"`, so **the candidate set is not narrowed at all.** The WEAK re-key is a
   literal no-op on this repro.
2. **The issue does not name any function in §A as the mechanism.** Its own words: *"The
   untagged interface-default **registry** is keyed by bare head tag with no interface
   component, so two same-spelled interfaces' defaults at one head collapse last-write-wins."*
   That is a **default registry**, not `ieCandidatesForMethod`. And the issue's own dedup
   section says verbatim **"Not #1182"**, giving the discriminator: *"This is same-spelled
   interfaces and is **not** order-dependent."* The conjunct-1 family is the order-dependent
   one.

⇒ **Remove #1619 from 4b's drain list.** It would only be drained by the STRONG fix (D-5), and
even then only if the *default* registry is re-keyed too — which is a third site nobody has
enumerated.

### #1620 — ⚠️ UNVERIFIABLE FROM THE TREE. The doc's assignment is not supported by the issue.

The issue's repro is #1182's shape (one file, `Alpha.ping`/`Beta.ping`) so an interface-scoped
candidate set plausibly changes it. **But the issue explicitly records that the mechanism is not
established**, under its own heading `## ⚠️ What is NOT derived`:

> *"The **mis-selecting site is unknown**. The measurement establishes that it is downstream of
> naming and is not order-dependent … but I have not identified where the wrong row is chosen.
> Recording that as owed rather than papering over it."*

**A drain claim requires a mechanism, and the issue states there isn't one yet.** Two facts from
this packet argue against a clean drain:
- The issue's discriminator from #1182 is *"This reproduces **unconditionally**; no permutation
  is needed"*, whereas §A/§C's family produces order-dependence. Different signature.
- Its symptom is a **three-way divergence** (`check` 0 / `run` E-PANICs / built binary exits 0
  printing a raw word) with **correct, distinct emitted symbols**. `keyForSite` is
  **ELABORATE-ONLY** (`:18531`) and stamps a route *word*; the issue says naming is already
  correct. So at most the re-key changes *which* correct symbol is called — it cannot by itself
  explain or repair a `run`-vs-`build` divergence whose symbols were never wrong.

⇒ Verdict **PARTIAL AT BEST, UNVERIFIED**. Determining it needs a build-and-probe run, which this
packet is forbidden from doing (REFUSALS R4). **Do not carry "#1620 is drained by 4b" forward as
a fact.**

### #1608 — NO (agreeing with the doc)

The defect is in `compiler/ir/core_ir_eval.mdk`'s `cevalModules`/`cevalProgram`, selecting by
import order. Nothing in §A or §B is in that file (§A.0 proves the family's only non-comment
occurrences are in `typecheck.mdk`). The issue further records that *"The only gate that runs
`cevalModules` is the UNTYPED path … **no `Route` is ever stamped**"* — so `keyForSite`'s output
is not even consumed on the path where the bug lives. **Structurally out of reach of 4b.**

---

## REFUSALS

**R1 — Which of `A1`/`A2` `methodIfaceParamsRef` actually holds for #1182 (hence whether the WEAK
fix converges on `1` or on `2`).** Derivable in principle from the registration walk, but it
depends on the decl traversal order in `insertMethodIfaceParams` *and* on whether `run` on a
no-import file takes the Flat or the Module path (which selects `applyMethodScopeOverrides` or
not, `:2336-2338`). Settling it requires running the binary. **The direction does not affect any
conclusion in this packet** — §C.2 only needs "decided by interface declaration order", which is
established from `omInsert` last-write-wins (`:2322-2325`) plus `dropMethodIdentCand`'s ident
collapse (§C.3). I decline to state the direction.

**R2 — Whether `test/diff_compiler_must_fail.sh` supports a second control per fixture (D-1).**
Not read; outside this packet's stated scope. Sizing D-1 as "one file" versus "a sibling fixture
directory" would be a guess.

**R3 — A bite-level size for D-5 (the STRONG supply).** I can enumerate the files and the
signature count floor (§C.4) but not decompose it into landable bites without a design run over
`marker.mdk` and `resolve.mdk`, which this packet did not do. **I decline to give a number
beyond the floor.**

**R4 — Whether 4b drains #1620.** §E. Requires a two-arm build-and-probe. Forbidden here.

**R5 — Any claim about how much IR moves.** §C.5 establishes that IR *does* move (the
default-inheriting-impl widening). **How much** is not statically derivable and I decline to
estimate it; the self-compile fixpoint is the authority (`keyForSite`'s own header says so at
`:18528-18529`: *"It does change which word is stamped … the fixpoint is the authority on that"*).

**R6 — The sprint doc's own relayed citation `route_key.mdk:192`.** §A.0 — the line exists but
names a different symbol. I have reported the discrepancy rather than repairing the doc.

---

## Addendum — R1 partially discharged, from source only (NOT measured)

`insertMethodIfaceParams` (`compiler/types/typecheck.mdk:16763`) is a plain left-to-right decl
walk:
```
insertMethodIfaceParams ((DInterface { name, typarams, methods, ifaceOrigin, ... })::rest) acc = insertMethodIfaceParams rest (insertIfaceMethodsAcc IfaceRef { irName = name, irOrigin = ifaceOrigin } typarams (declGradedScope typarams methods) methods acc)
```
Combined with `omInsert` being last-write-wins on a method-name collision (`:2322-2325`), the
**LAST-declared** interface's entry survives. In #1182's `main.mdk` that is `A2`, so
`ifaceOfMethodName "m"` should answer `"A2"` and the WEAK fix should make **both** `main.mdk` and
`control.mdk` print `2` — which is precisely the `claim.txt:61-62` **DRAINED** branch.

⚠️ **Derived from source, not measured**, and it still routes through the Flat/Module-path
question R1 raises (`applyMethodScopeOverrides`, `:16869`). §C.3 shows the Module path cannot
override here anyway — `"m"` never enters the collided list — so both paths should agree. I am
recording this as the expected direction, **not** as a verified one; the conclusions in §C.2 and
§E do not depend on it.
