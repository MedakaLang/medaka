# P0-F — RE-DERIVING THE AD-2 CARRIER RULING AGAINST HEAD

**Packet:** P0-F. **Role:** read-only static analyst. **No build, no gate, no `./medaka`
invocation was made.** No file under `compiler/`, `stdlib/`, `runtime/`, `test/` was edited.

**Pin:** `BASE = aaa437167b633d6070adccd055c8c2a19e9bb8c6`
```sh
$ git rev-parse HEAD
aaa437167b633d6070adccd055c8c2a19e9bb8c6
$ git status --porcelain
?? .claude/sprint-phase45/
```
Worktree: `/root/medaka/.claude/worktrees/peppy-brewing-kitten`. Every grep below was run
scoped to that worktree.

**Documents read before starting:** `.claude/sprint-phase3/AD2-carrier-ruling.md` (pinned
`68f84bf1`) and `.claude/sprint-phase45/phase0/P0-A-phase4-design.md` (pinned `aaa43716`).
Every number relayed from either was re-derived here from scratch.

---

## HEADLINE — the four findings, before the derivations

1. **All three re-opened premises CONFIRM.** I get 29 constructions / 11 destructures
   independently; there is no `typecheck ↔ core_ir` import edge in either direction; arg-tag
   admissibility is 100% in `compiler/eval/eval.mdk` with **zero** code sites in
   `compiler/types/`.
2. 🔴 **§B — P0-A's "there is no channel at all" is TOO STRONG, and the correction matters.**
   A channel exists and is load-bearing today: typecheck stamps mutable `Ref`s embedded in
   the AST node `EMethodAt String (Ref Route) (Ref (List Route)) (Ref (List Route))`
   (`frontend/ast.mdk:919`), and lowering reads them at `core_ir_lower.mdk:150-151`. It
   crosses *inside* `List Decl`. What does **not** exist is a channel for a **whole-program**
   value — which is a different, and weaker, claim than "no channel".
3. 🚨 **§C — AD-2's carrier does NOT survive, and the reason is not the corrected counts.**
   **`compiler/eval/eval.mdk` contains ZERO occurrences of `CProgram` and imports nothing
   from `ir.`.** One of the two lockstep consumption sites therefore lives in a module that
   **cannot name the proposed carrier**. Separately, `lowerImpls` — which contains the other
   consumption site — is called *inside* the `CProgram` constructor application at
   `core_ir_lower.mdk:533`, so the table is an **input to building `CProgram`**, not a field
   readable from it. AD-2 put the carrier on the wrong side of its own consumption.
   **The two-valued RULING survives; the `CProgram` CARRIER does not.**
4. 🟢 **§D — the key is in better shape than any prior document says. BOTH halves of the
   intended key are already in hand as local variables at BOTH consumption sites, one line
   above the bare-name lookup.** `core_ir_lower.mdk:1408` and `eval.mdk:1975` both bind the
   declaring interface's `TyConOrigin` as `o` and use it for `implRouteKeyWord o ifaceName …`
   — then the very next line throws it away for `lookupPositions ifaceName mname disp`.
   The identity substrate (`ifaceIdentity`, `ifaceIdMatches`, `ifaceWordOf`) already exists
   and already sits in modules imported by producer and both consumers.

---

## A. THE THREE PREMISES, RE-DERIVED

### A.1 Premise 1 — `CProgram` construction sites: **29. I AGREE WITH P0-A, AGAINST AD-2's 13.**

Derivation, from scratch. First the per-file distribution of non-comment `CProgram` lines:

```sh
$ grep -rn '\bCProgram\b' --include=*.mdk compiler/ stdlib/ \
    | grep -vE '^[^:]+:[0-9]+: *--' | awk -F: '{print $1}' | sort | uniq -c
      7 compiler/backend/llvm_emit.mdk
      7 compiler/backend/wasm_emit.mdk
      2 compiler/entries/llvm_emit_modules_main.mdk
      2 compiler/entries/llvm_emit_typed_main.mdk
      2 compiler/entries/profile_main.mdk
     55 compiler/entries/wasm_emit_typed_main.mdk
      5 compiler/ir/core_ir_eval.mdk
     11 compiler/ir/core_ir_lower.mdk
      2 compiler/ir/core_ir.mdk
      4 compiler/ir/core_ir_sexp.mdk
      4 compiler/ir/core_ir_sexp_parse.mdk
      5 compiler/ir/draft_semantic_program.mdk
      3 compiler/tools/snapshot.mdk
```
**109 lines total.** ⚠️ `stdlib/` contributes **zero** — `CProgram` is compiler-private.

Classifying by position (application in expression position = CONSTRUCTION):

| file | construction lines | n |
|---|---|---|
| `compiler/ir/core_ir_lower.mdk` | 529, 643, 1003, 1011 | 4 |
| `compiler/ir/core_ir_sexp_parse.mdk` | 381 (the **deserializer**) | 1 |
| `compiler/entries/llvm_emit_typed_main.mdk` | 77 | 1 |
| `compiler/entries/wasm_emit_typed_main.mdk` | 222, 234, 291, 294, 396, 409, 423, 435, 450, 463, 476, 479, 491, 519, 531, 538, 558, 568, 663, 682, 725, 831, 842 | **23** |
| **TOTAL** | | **29** |

**VERDICT: AD-2's 13 is REFUTED at HEAD; P0-A's 29 is CONFIRMED by an independent count,
line-for-line.** The delta is entirely `compiler/entries/wasm_emit_typed_main.mdk` (23 of 29).

⚠️ **Two derivations agreeing is worth something only if they were independent — and there is
one place mine was not fully so:** I derived my line list first and then compared to P0-A's,
rather than the reverse. The lists are identical member-for-member. I did **not** re-derive
AD-2's 13 at `68f84bf1` (that would need a checkout I am not doing), so I can say the count
at HEAD is 29 but **cannot** say whether AD-2 was wrong at its own pin or merely stale.

🚨 **The shelf-life warning is real and I am strengthening it.** `wasm_emit_typed_main.mdk`
has **55** `CProgram` lines and holds **23 of the 29 constructions plus 1 of the 11
destructures** — i.e. **24 of 40 sites, 60%, in a single file created by PR #1623 hours before
this sprint, with a live concurrent writer from the #1403 / X-W emitter arc.** Any design
whose site count in that file is nonzero is buying a merge conflict. **§C's re-ruled carrier
touches it ZERO times.** That is not a tiebreaker; it is the largest single sizing difference
between the two carriers.

### A.1.1 DESTRUCTURE sites: **11 — I agree with BOTH prior documents on the count**

```
compiler/entries/llvm_emit_modules_main.mdk:86    CProgram groups _ _ impls => …
compiler/ir/core_ir_eval.mdk:401                  cevalProgram (CProgram groups ctorArs ctorToType implEntries) =
compiler/ir/core_ir_sexp.mdk:225                  cprogramToSexp (CProgram binds ctorArities ctorToType impls) = node
compiler/ir/draft_semantic_program.mdk:313        cprogramSummary (CProgram binds ctorArities ctorTypes impls) = node
compiler/entries/wasm_emit_typed_main.mdk:567     implSelfCensusProgram (CProgram groups ctorArs ctorTypes impls) =
compiler/ir/core_ir_lower.mdk:642                 rewriteProgramRecPats fo (CProgram groups ctorArs ctorTypes implEntries) =
compiler/ir/core_ir_lower.mdk:1001                hoistNullaryMemo (CProgram groups ctorArs ctorTypes implEntries) =
compiler/backend/wasm_emit.mdk:1055               emitProgramWith emit input (CProgram groups ctorArs ctorTypes impls) =
compiler/backend/wasm_emit.mdk:1113               emitProgramGaps input (CProgram groups ctorArs ctorTypes impls) =
compiler/backend/llvm_emit.mdk:10761              emitProgramMode gapMode input (CProgram groups ctorArs ctorTypes implEntries) =
compiler/backend/llvm_emit.mdk:11131              emitProgramGaps input (CProgram groups ctorArs ctorTypes implEntries) =
```
⚠️ **AD-2's line for the `wasm_emit_typed_main` destructure (`:219`) is stale; at HEAD it is
`:567`.** P0-A already caught this. Total AD-2 cost claim *"the same 24 sites"* → **40 at
HEAD** (11 + 29). Confirmed.

⚠️ Two files mention `CProgram` in **type position only** and are neither constructions nor
destructures — they would still need no edit under an arity change, but a naive
`grep -c CProgram` counts them: `compiler/entries/profile_main.mdk` (`:35` import, `:361`
signature) and `compiler/tools/snapshot.mdk` (`:167` import, `:615`, `:621` signatures).

### A.2 Premise 2 — the seam: **CONFIRMED. No import edge, in either direction.**

```sh
$ grep -nE '^import [a-z]' compiler/ir/core_ir_lower.mdk
13:import frontend.ast.{
42:import types.route_key.{implRouteKeyWord}
43:import ir.core_ir.{
58:import eval.eval.{
67:import list.{replicate}
68:import support.ordmap.{OrdMap, omEmpty, omInsert, omHasKey}
69:import backend.private_mangle.{sanitizeId}
70:import support.util.{

$ grep -nE '^import [a-z]' compiler/types/typecheck.mdk
14:import frontend.ast.{
76:import types.registry.{
90:import frontend.desugar.{mapProg}
91:import frontend.marker.{localBoundNames}
92:import frontend.resolve.{
106:import frontend.exhaust.{
116:import support.char.{isUpper}
117:import backend.private_mangle.{mangledName}
118:import support.scc.{tarjanSCCs}
119:import support.ordmap.{
130:import list.{replicate}
131:import support.util.{
163:import types.registry.{
202:import types.route_key.{implRouteKeyWord}
```
⇒ **`core_ir_lower.mdk` has NO `types.typecheck` edge. `typecheck.mdk` has NO `ir.core_ir`
and NO `ir.core_ir_lower` edge.** CONFIRMED, both directions.

And the elaboration boundary returns `Decl`-shaped values only:
```sh
$ grep -nE '^export elaborate[A-Za-z]* :' compiler/types/typecheck.mdk
14538:export elaborateOne     : List Decl -> List Decl -> (String, List Decl) -> List Decl
14566:export elaborateDict    : List Decl -> List String -> List String -> List Decl -> List Decl
28990:export elaborateModules : List Decl -> List Decl -> List (String, List Decl) -> (List Decl, List (String, List Decl))
```
`grep -nE '^elaborate[A-Za-z]* :|^export elaborate[A-Za-z]* :'` returns **exactly these
three** — there is no fourth, non-exported elaboration entry point. CONFIRMED.

🔴 **But see §B: "returns `List Decl`" is not the same as "carries no typecheck output". It
does. That is the whole `EMethodAt` mechanism.**

### A.3 Premise 3 — admissibility lives in `eval.mdk`: **CONFIRMED, and stronger than stated.**

```sh
$ grep -rn 'lookupPositions\|dispatchPositionsOf\|keepOrAll\|buildIfaceDispatch\|ifaceDispatchRef' \
    --include=*.mdk compiler/types/
compiler/types/registry.mdk:161:--   | `ifaceDispatchRef`  | Ident × Ident  | eval.mdk      |
compiler/types/registry.mdk:487:-- An identity TUPLE (`ImplUniverse`'s concrete bucket, `ifaceDispatchRef`,
compiler/types/registry.mdk:1171:--     (`ImplUniverse`'s buckets, `ifaceDispatchRef` and `methodReqCountRef` are
compiler/types/typecheck.mdk:28999:-- default RNone → eval arg-tag-dispatched a Map through the no-matching-tag `keepOrAll`
```
**All four hits are COMMENTS. Zero code sites in `compiler/types/`.** CONFIRMED — Phase 4 is a
**RELOCATION**, not a re-key.

The producer, grep-proven at HEAD:
```
compiler/eval/eval.mdk:270:ifaceDispatchRef : Ref (List ((String, String), List Int))
compiler/eval/eval.mdk:271:ifaceDispatchRef = Ref []
compiler/eval/eval.mdk:280:export installDispatchTables : List Decl -> List ((String, String), List Int)
compiler/eval/eval.mdk:1882:buildIfaceDispatch : List Decl -> List ((String, String), List Int)
compiler/eval/eval.mdk:1883:buildIfaceDispatch prog = flatMap ifaceDispatchEntries prog
compiler/eval/eval.mdk:1903:export lookupPositions : String -> String -> List ((String, String), List Int) -> List Int
```

🟢 **NEW — not in AD-2 or P0-A: `installDispatchTables` has FOUR call sites, not two, and
the fourth is the lockstep twin.**
```sh
$ grep -rn 'installDispatchTables' --include=*.mdk compiler/ | grep -vE ': *--'
compiler/ir/core_ir_eval.mdk:85:  installDispatchTables,          (import)
compiler/ir/core_ir_eval.mdk:534:  let disp = installDispatchTables allDecls
compiler/ir/core_ir_lower.mdk:62:  installDispatchTables,          (import)
compiler/ir/core_ir_lower.mdk:1233:  lowerImplsWith (installDispatchTables prog) prog
compiler/eval/eval.mdk:280:export installDispatchTables : List Decl -> …   (definition)
compiler/eval/eval.mdk:3059:  let disp = installDispatchTables allDecls
compiler/eval/eval.mdk:3177:  let disp = installDispatchTables allDecls
```
Enclosing functions, derived:
```sh
$ grep -nE '^export [a-zA-Z]+ :|^[a-zA-Z][a-zA-Z0-9]* :' compiler/eval/eval.mdk | awk -F: '$1>3000 && $1<3200'
3053:export evalModulesWith        : …          ← contains :3059
3171:export evalModulesRootEnvWith : …          ← contains :3177
$ grep -nE '^export [a-zA-Z]+ :' compiler/ir/core_ir_eval.mdk | awk -F: '$1>480 && $1<560'
528:export cevalModules : List Decl -> List (String, List Decl) -> <e> List (String, Value e)   ← contains :534
```
⇒ **The four seeding sites are `evalModulesWith` · `evalModulesRootEnvWith` · `cevalModules` ·
`lowerImpls`.** `evalModulesWith` and `cevalModules` are **precisely `AGENTS.md`'s named
lockstep pair**. P0-A's §A.1.2 lists only `eval.mdk:282` (which is *inside* the definition) and
`core_ir_lower.mdk:1233` — it undercounts the seeding sites by two and does not name the
lockstep twin `core_ir_eval.mdk:534`. **Any relocation owes all four.**

The two fail-open defaults, re-derived at HEAD (AD-2's `:1934`/`:967-969` are stale; P0-A's
`:1904`/`:937-939` are right):
```
compiler/eval/eval.mdk:1904:lookupPositions _ _ [] = [0]
compiler/eval/eval.mdk:937:keepOrAll : List (Value e) -> List (Value e) -> List (Value e)
compiler/eval/eval.mdk:938:keepOrAll original [] = original
compiler/eval/eval.mdk:939:keepOrAll _ kept = kept
```
CONFIRMED live at HEAD.

---

## B. 🎯 THE SEAM CHANNEL — CONFIRMED TO EXIST, contra P0-A; but not the shape AD-2 assumed

### B.1 The refutation of *"there is no channel at all"*

P0-A §B.5 / bite 4 states: *"there is no channel today for a non-`Decl` value to cross that
seam."* **That is true only for a WHOLE-PROGRAM value. A per-occurrence channel exists, is
load-bearing, and is exactly how typecheck already tells lowering which impl it picked.**

The carrier is a mutable cell embedded in an AST node:
```
compiler/frontend/ast.mdk:919:  | EMethodAt String (Ref Route) (Ref (List Route)) (Ref (List Route))
compiler/frontend/ast.mdk:722:public export data Route =
compiler/frontend/ast.mdk:723:  | RNone
compiler/frontend/ast.mdk:724:  | RKey String (List Route)
compiler/frontend/ast.mdk:725:  | RDict String
compiler/frontend/ast.mdk:726:  | RDictFwd String
compiler/frontend/ast.mdk:727:  | RLocal String (List Route)
compiler/frontend/ast.mdk:728:  | RScalar String
```

**PRODUCER — typecheck writes into those cells:**
```
compiler/types/typecheck.mdk:6608:resolveArgStamp : ImplBuckets -> KeyBuckets -> String -> Ref Route -> Ref (List Route) -> Mono -> Mono -> String -> Unit
compiler/types/typecheck.mdk:6613:    _ => setRef tagRef route
compiler/types/typecheck.mdk:6614:  setRef implRef routes
compiler/types/typecheck.mdk:12365:stampRoutes : List (Ref Route) -> Unit
compiler/types/typecheck.mdk:12368:  let _ = setRef r (RLocal (routeLocalSym r.value) [])
```
(`grep -c 'EMethodAt' compiler/types/typecheck.mdk` → **82**.)

**CONSUMERS — both lockstep engines read them:**
```
compiler/ir/core_ir_lower.mdk:150:lower (EMethodAt name routeRef implRef methodRef) =
compiler/ir/core_ir_lower.mdk:151:  CMethod name routeRef.value implRef.value methodRef.value
compiler/eval/eval.mdk:1256:eval env (EMethodAt name routeRef implRef methodRef) =
```

⇒ **The seam is crossed today, in one hop, by a typecheck-computed value, with no import edge
between `typecheck.mdk` and either consumer — because the type (`Route`) lives in
`frontend/ast.mdk`, which all three import.** That is the architectural pattern the tree
already uses, and it is the pattern AD-2's `CProgram` field is *not*.

**What P0-A got right and what it got wrong:**
- ✅ RIGHT: elaboration's three entry points return `List Decl` only. Grep-proven above.
- ✅ RIGHT: there is no import edge, in either direction. Grep-proven above.
- 🔴 **OVER-STATED: "no channel at all". The `List Decl` it returns is not inert — it is a
  graph of mutable cells the typechecker has already written into.** A conclusion built on
  "the return type is `List Decl`, therefore nothing typecheck-computed crosses" is a claim
  reaching past its evidence: the return TYPE is `List Decl`; the return VALUE carries stamped
  `Route`s. The correct statement is **"no channel for a WHOLE-PROGRAM value"** — which is
  what §B.3 has to solve, and it is a narrower problem than P0-A frames.

### B.2 Tracing the actual data path from COMPUTE to CONSUME

```
compiler/eval/eval.mdk:1972:implMethodEntry : EvalEnv (Value e) -> List ((String, String), List Int) -> TyConOrigin -> String -> List Ty -> ImplMethod -> (String, (Int, Value e))
compiler/eval/eval.mdk:1973:implMethodEntry env disp o ifaceName typeArgs (ImplMethod mname pats body) =
compiler/eval/eval.mdk:1974:  let tag = fromOption noneHeadTag (headTyconHead typeArgs)
compiler/eval/eval.mdk:1975:  let key = implRouteKeyWord o ifaceName typeArgs None
compiler/eval/eval.mdk:1976:  let positions = lookupPositions ifaceName mname disp
compiler/eval/eval.mdk:1977:  let inner = implMethodValue env positions pats body
compiler/eval/eval.mdk:1978:  (mname, (tyvarsInArgs typeArgs, VTypedImpl tag key positions 0 inner))
```
```
compiler/ir/core_ir_lower.mdk:1405:lowerImplMethod : List ((String, String), List Int) -> TyConOrigin -> String -> List Ty -> ImplMethod -> CImplEntry
compiler/ir/core_ir_lower.mdk:1406:lowerImplMethod disp o ifaceName typeArgs (ImplMethod mname pats body) =
compiler/ir/core_ir_lower.mdk:1407:  let tag = fromOption noneHeadTag (headTyconHead typeArgs)
compiler/ir/core_ir_lower.mdk:1408:  let key = implRouteKeyWord o ifaceName typeArgs None
compiler/ir/core_ir_lower.mdk:1409:  let positions = lookupPositions ifaceName mname disp
compiler/ir/core_ir_lower.mdk:1413:    (CImplTagged tag key ifaceName positions pats (lower body))
```

🚨 **Note what these two sites are: they are NOT call sites. They are IMPL-INSTALLATION sites**
— once per (impl, method) *declaration*, not once per method application. `positions` is baked
into `VTypedImpl` / `CImplTagged` and consulted later by `filterByTag`/`keepOrAll`. This
confirms P0-A §A.1.2 (the position half is already frozen-as-data) and it is decisive for §C:
**the consumer is a fold over `List Decl`, inside a function that receives neither a
`CProgram` nor anything from typecheck.**

`disp` is threaded from exactly four seeding sites (§A.3), and **all four call
`installDispatchTables allDecls`** — i.e. all four derive the table from `List Decl` at the
point of use. That derivation is the thing Phase 4 replaces.

### B.3 ENUMERATED OPTIONS FOR A WHOLE-PROGRAM CHANNEL

Four, not three — the tree already contains an instance of each pattern.

| # | option | mechanism | signatures changed | files touched | verdict |
|---|---|---|---|---|---|
| **1** | **5th `CProgram` field** (AD-2's ruling) | positional field | `lowerProgram`, `lowerProgramEmit`, `rewriteProgramRecPats`, `hoistNullaryMemo`, `parseCProgram`, `cprogramToSexp`, + arity at **40** sites | **13**, incl. **24 sites in `wasm_emit_typed_main.mdk`** | 🚨 **CANNOT REACH `eval.mdk` AT ALL** — §C.1 |
| **2** | **Widen the elaboration return types** | `List Decl` → `(List Decl, CAdmis)` at `:14538`, `:14566`, `:28990` | 3 exported signatures + every caller | unsized — **REFUSAL 2** | still does not reach `implMethodEntry`, which no driver calls directly |
| **3** | **A shared-module `Ref` — the `ifaceDispatchRef` idiom** | `Ref CAdmis` in `types/route_key.mdk`, written post-K by typecheck, read at the 4 seed sites | **0 signature changes**; 1 decl + 1 setter + 4 seed-site edits + 1 added import | **5** | 🟢 **the tree's own existing pattern for this exact value** — §C.2 |
| **4** | **Per-occurrence AST stamping** — the `EMethodAt`/`Route` idiom | extend the route cells | `ast.mdk` + 82 typecheck sites + 2 consumers | many | wrong granularity: admissibility is per (iface, method), not per occurrence |

#### B.3.1 Option 3 in detail — the module graph permits it, and names the one added import

`types/route_key.mdk` is the unique module already imported by the producer **and both
lockstep-family consumers**, with no upward edges of its own:
```sh
$ grep -n 'import types.route_key' compiler/types/typecheck.mdk compiler/ir/core_ir_lower.mdk compiler/eval/eval.mdk
compiler/types/typecheck.mdk:202:import types.route_key.{implRouteKeyWord}
compiler/ir/core_ir_lower.mdk:42:import types.route_key.{implRouteKeyWord}
compiler/eval/eval.mdk:48:import types.route_key.{implRouteKeyWord}

$ grep -nE '^import [a-z]' compiler/types/route_key.mdk
125:import frontend.ast.{
132:import support.util.{joinWith, escStr}
```
⇒ **acyclic by construction.** The one module that would need a new import is the lockstep
twin:
```sh
$ grep -nE '^import [a-z]' compiler/ir/core_ir_eval.mdk
28:import frontend.ast.{Lit(..), Pat(..), Addr(..), Route(..), Decl, Loc(..)}
29:import ir.core_ir.{
44:import ir.core_ir_lower.{lowerGroups, lowerImplsWith}
45:import support.util.{isEmptyL, dedup}
46:import eval.eval.{
```
— no `types.route_key` edge. **Adding one is acyclic** (route_key imports only
`frontend.ast` + `support.util`, neither of which reaches `ir.`). Cost: **one import line.**

🔴 **This corrects P0-A §B.5, which frames the module-graph question as `ir/core_ir.mdk` vs
`types/typecheck.mdk` and never mentions `eval.mdk` — the module its own §A.0 headline says
owns the entire computation.** `eval.mdk:48` already imports `route_key`; P0-A's option (b) is
therefore *better* than P0-A knew, and its option (a) (`CAdmis` in `ir/core_ir.mdk`) is
*worse* than P0-A knew, because `eval.mdk` imports nothing from `ir.` at all (§C.1).

The existing instance of the idiom, at the exact granularity Phase 4 needs:
```
compiler/eval/eval.mdk:270:ifaceDispatchRef : Ref (List ((String, String), List Int))
compiler/eval/eval.mdk:271:ifaceDispatchRef = Ref []
```
**Option 3 IS `ifaceDispatchRef` — moved to a shared module, re-keyed, re-typed two-valued,
and written by typecheck instead of by lowering.** It introduces no new mechanism.

⚠️ **The honest cost of option 3, stated rather than left to be found:** a global `Ref` is
process-global and order-dependent, and `eval.mdk:271` initialises to `Ref []` — a **fail-open**
initial value under today's `lookupPositions _ _ [] = [0]`. `Ref CAdmisAbsent` is the
fail-closed-capable initialiser, and **that is sound only because `CAdmisAbsent` is a distinct
constructor**: with an `Option`-shaped or bare-list field, the initialiser and "computed table
with zero rows" are the same value again. **Option 3 does not weaken RUN-B-013 condition 1 —
it is the option that needs it MOST.** A second cost: a stale `Ref` from a previous program in
the same process reads as authoritative. `installDispatchTables` has the same exposure today
and manages it by re-seeding at every driver entry; option 3 inherits that obligation at all
four seed sites.

#### B.3.2 Option 2's cost is NOT sized here — see REFUSAL 2

I verified the three signatures and that all three return `Decl`-shaped values (§A.2). I did
**not** enumerate their caller set, so I will not hand anyone a cost for option 2.

### B.4 🚨 WHAT THE CHANNEL OWES THE LOCKSTEP TWIN

`AGENTS.md`'s named pair is `evalModules` (`eval/eval.mdk`) / `cevalModules`
(`ir/core_ir_eval.mdk`). Both seed the table today, and there is a **third** eval-side seeder
neither AD-2 nor P0-A names:
```
compiler/eval/eval.mdk:3059:      let disp = installDispatchTables allDecls   (in evalModulesWith,        :3053)
compiler/eval/eval.mdk:3177:      let disp = installDispatchTables allDecls   (in evalModulesRootEnvWith, :3171)
compiler/ir/core_ir_eval.mdk:534:  let disp = installDispatchTables allDecls   (in cevalModules,          :528)
compiler/ir/core_ir_lower.mdk:1233:  lowerImplsWith (installDispatchTables prog) prog  (in lowerImpls,     :1230)
```
**Any channel that changes where `disp` comes from owes all four.** A change landing on
`evalModulesWith` alone reproduces the P0-9 failure verbatim: mirrored code, one arm patched,
the other silently stale for months.

🚨 **Under option 1 (`CProgram`) this obligation is UNSATISFIABLE on two of the four** —
`eval.mdk` has no `CProgram` and no `ir.` import (§C.1). That is not a cost; it is a
disqualification.

---

## C. RE-RULING THE CARRIER

**Verdict, up front:**
- ✅ **The TWO-VALUED ruling SURVIVES, and on a STRONGER argument than AD-2 gives** (§C.3).
- ✅ **`Option` stays REJECTED** — AD-2 §4.1's argument is untouched by the corrected premises,
  and §C.3 makes it load-bearing on the recommended carrier rather than merely prudent.
- 🚨 **`CProgram` as the CARRIER does NOT survive. It is disqualified twice over, and neither
  disqualification is about site counts.**
- 🟢 **The alternative, named: a `Ref CAdmis` in `compiler/types/route_key.mdk`** (§B.3 option
  3), i.e. the `ifaceDispatchRef` idiom the tree already runs, re-homed and re-typed.

### C.1 DISQUALIFIER 1 — `eval.mdk` cannot name `CProgram`

```sh
$ grep -c 'CProgram' compiler/eval/eval.mdk
0
$ grep -n 'import ir\.' compiler/eval/eval.mdk
(no output)
```
**`compiler/eval/eval.mdk` contains ZERO occurrences of `CProgram` and imports NOTHING from
`ir.`.** (Its full import head is `frontend.ast` · `types.route_key` · `support.util` ·
`driver.diagnostics` · `bits64` — §B.3.1.)

One of the two consumption sites the sprint exists to fix is `eval.mdk:1976`, inside
`implMethodEntry` (`:1972`), reached from `evalModulesWith:3053` and
`evalModulesRootEnvWith:3171`. **None of those functions has, or can have, a `CProgram`.**
`ir.core_ir` imports `frontend.ast`; `eval.eval` is imported *by* `ir.core_ir_lower` and
`ir.core_ir_eval` — so making `eval.mdk` import `ir.core_ir` to name `CAdmis` is not merely
a layering violation, it is **a cycle** (`ir.core_ir_lower → eval.eval → ir.core_ir`; and
`ir.core_ir_eval:44` imports `ir.core_ir_lower` too).

⇒ A 5th `CProgram` field can deliver a frozen table to **`lowerImpls` and to nothing else**.
Two of the four seed sites (§B.4) and one of the two lockstep consumers are structurally out
of reach. **That is the P0-9 shape designed in from the start.**

⚠️ This also retires P0-A §B.5's **option (a)** ("define `CAdmis` in `ir/core_ir.mdk` beside
`CProgram`"): it is not "crosses a layer, pulls Core IR into the typechecker's graph" — it is
**unreachable from the module that owns the computation**.

### C.2 DISQUALIFIER 2 — the table is an INPUT to building `CProgram`, not a field of it

```
compiler/ir/core_ir_lower.mdk:526:export lowerProgram : List Decl -> CProgram
compiler/ir/core_ir_lower.mdk:527:lowerProgram prog =
compiler/ir/core_ir_lower.mdk:528:  let _ = setRef ctorFieldOrdersRef (buildCtorFieldOrders prog)
compiler/ir/core_ir_lower.mdk:529:  CProgram
compiler/ir/core_ir_lower.mdk:530:    (lowerGroups prog)
compiler/ir/core_ir_lower.mdk:531:    (ctorArities prog)
compiler/ir/core_ir_lower.mdk:532:    (buildCtorToType prog)
compiler/ir/core_ir_lower.mdk:533:    (lowerImpls prog)
```
```
compiler/ir/core_ir_lower.mdk:1230:lowerImpls : List Decl -> List CImplEntry
compiler/ir/core_ir_lower.mdk:1231:lowerImpls prog =
compiler/ir/core_ir_lower.mdk:1232:  let _ = installIfaceImplHeads (ifaceImplHeadTable prog)
compiler/ir/core_ir_lower.mdk:1233:  lowerImplsWith (installDispatchTables prog) prog
```
`lowerImpls` — which contains the seed *and*, via `lowerImplMethod:1409`, the consumption — is
**the fourth argument of the `CProgram` constructor application at `:529-533`**. The
admissibility table is consumed while `CProgram` is being built. A field on `CProgram` is
therefore **downstream of its own consumer**: readable by `cevalProgram`, the two emitters and
the serializer, and *not* readable by the code whose fail-open default the sprint is trying to
retire.

⇒ AD-2's C-2 (a 5th positional `CProgram` field) chose a carrier that is **structurally
downstream of the decision it is meant to freeze.** RUN-B-013's C-2 should be **overturned**,
not merely re-typed. AD-2 §3 explicitly declined to reopen C-2 (*"C-2 stands, unamended; this
ruling is only about that field's TYPE"*) — that was the correct scope for AD-2's charter, and
it is the reason the error survived: **the escalation asked about the TYPE, so nobody re-asked
about the FIELD.**

### C.3 DOES THE FAIL-CLOSED REQUIREMENT STILL HOLD? **YES — and it gets SHARPER, not weaker**

RUN-B-013 condition 1 requires *table present but no row* to be distinguishable from *table
structurally absent*. AD-2 grounded this in a hypothetical (`[]` as a 5th field's only
"nothing" value). **At HEAD there is a live, non-hypothetical instance, and it is the exact
line the condition cites:**
```
compiler/eval/eval.mdk:1903:export lookupPositions : String -> String -> List ((String, String), List Int) -> List Int
compiler/eval/eval.mdk:1904:lookupPositions _ _ [] = [0]
```
**Today's fail-open arm's discriminant IS `[]` — the empty table.** That arm exists *because*
the type cannot tell "no table was installed" from "a table with no rows", so it guesses, and
it guesses OPEN. The two-valued type is not a stylistic preference over `Option`; **it is
precisely the thing that makes `:1904` splittable into two arms with opposite verdicts:**

| carrier value | verdict |
|---|---|
| `CAdmisAbsent` | today's arg-tag behaviour — preserve `[0]`, marked UNVERIFIED |
| `CAdmisTable []` | **table computed, genuinely no rows ⇒ FAIL CLOSED** |
| `CAdmisTable rows`, key misses | **FAIL CLOSED** |

Under a bare `List row` — 5th field *or* `Ref` — arms 1 and 2 are the same value and `:1904`
cannot be split at all. **The requirement holds identically for the re-ruled carrier.**

🚨 **And it binds HARDER on a `Ref` than on a `CProgram` field**, which is the one way the
corrected picture makes the ruling more important rather than less:
```
compiler/eval/eval.mdk:270:ifaceDispatchRef : Ref (List ((String, String), List Int))
compiler/eval/eval.mdk:271:ifaceDispatchRef = Ref []
```
A `Ref` **must have an initialiser**, and with a bare list type that initialiser is `[]` — the
fail-open value, installed by construction at process start, indistinguishable from a computed
empty table for the whole run. `Ref CAdmisAbsent` is the only spelling in which "never
written" is a distinct observable. **A `Ref (Option table)` initialised `Ref None` would
technically work — and is exactly what AD-2 §4.1 rejects, because `fromOption [] admisRef.value`
is one idiomatic token (99 uses of `fromOption` in `compiler/`) that re-installs the fail-open
default in a diff nobody stops on.** AD-2's `Option`-rejection argument therefore **transfers
to the new carrier verbatim and is strictly more load-bearing there.**

### C.4 🚨 THE FAIL-OPEN DEFAULTS — and the incoherence the brief asks about. IT IS REAL.

Two defaults, and **they are not the same kind of thing**:

| | site | operates on | reached by a fail-closed carrier? |
|---|---|---|---|
| **(i)** | `lookupPositions _ _ [] = [0]` (`eval.mdk:1904`) | **the TABLE** | ✅ **YES** — this arm IS the carrier's `CAdmisAbsent`/`CAdmisTable []` split (§C.3) |
| **(ii)** | `keepOrAll original [] = original` (`eval.mdk:938`) | **the CANDIDATE VALUE LIST** | ❌ **NO — structurally out of reach** |

Proof for (ii) — the whole decision chain, and no `disp` anywhere in it:
```
compiler/eval/eval.mdk:910:applyOpt (VMulti vs) arg = collectPartials [] (filterByTag vs arg) arg
compiler/eval/eval.mdk:928:filterByTag : List (Value e) -> Value e -> List (Value e)
compiler/eval/eval.mdk:929:filterByTag vs arg
compiler/eval/eval.mdk:930:  | not (anyList isDispatching vs) = vs
compiler/eval/eval.mdk:931:  | otherwise = filterByTagT vs (runtimeTypeTag arg)
compiler/eval/eval.mdk:934:filterByTagT vs None = vs
compiler/eval/eval.mdk:935:filterByTagT vs (Some tag) = keepOrAll vs (filter (keepCand tag) vs)
compiler/eval/eval.mdk:938:keepOrAll original [] = original
compiler/eval/eval.mdk:942:keepCand tag v = not (isDispatching v) || matchesTag tag v
compiler/eval/eval.mdk:945:isDispatching (VTypedImpl _ _ pos seen _) = containsInt seen pos
```
`positions` reaches this chain **only** as the `pos` already baked into each `VTypedImpl` by
`implMethodEntry:1978`. So:

- **A fail-CLOSED table narrows `positions`** ⇒ fewer candidates are `isDispatching` ⇒
  `keepCand` returns `True` for more of them ⇒ **the filter keeps MORE**. A "not admissible"
  verdict is laundered into "this candidate is not tag-filtered", i.e. **into keeping it.**
- **If the table says slot 0 IS dispatchable and no candidate's tag matches**, the filter
  yields `[]` and `keepOrAll` returns **the ORIGINAL, unfiltered set** — first-impl-wins,
  exit 0, no diagnostic. **A fail-closed carrier cannot see or change this.**

⇒ **ANSWER TO THE BRIEF'S WARNING: the incoherence is real and it is NOT fixable by the
carrier.** Freezing an authoritative table upstream of `keepOrAll` is precisely RUN-B-013's
*"a table inheriting that default has changed nothing"* — except worse, because the table now
*reads* as authoritative. **`keepOrAll` (and `filterByTag:930`, and `filterByTagT:934`) must be
retired in the SAME unit that makes the table authoritative, or the unit must not claim to
have closed the fail-open behaviour.** Either is defensible; silently doing the first half is
not.

⚠️ **Scope note, DERIVED (REFUSAL 4 discharged):** `grep -rn 'filterByTag' --include=*.mdk
compiler/` returns hits in `eval.mdk` only, plus one **comment** at
`backend/llvm_emit.mdk:5509`. `core_ir_eval.mdk` has **zero** hits for
`filterByTag`/`keepOrAll`/`isDispatching`/`keepCand` — **because it reaches them through a
SHARED implementation**, and the file says so in its own words:
```
compiler/eval/eval.mdk:878:-- a call site; `applyValue` lets core_ir_eval.mdk reuse this runtime's value
compiler/eval/eval.mdk:880:export applyValue : Value e -> Value e -> <e> Value e
compiler/eval/eval.mdk:881:applyValue f x = apply f x
compiler/eval/eval.mdk:895:  let r = applyDispatch f x
compiler/eval/eval.mdk:900:applyDispatch f x = match applyOpt f x
compiler/eval/eval.mdk:910:applyOpt (VMulti vs) arg = collectPartials [] (filterByTag vs arg) arg
```
with `core_ir_eval.mdk:53` importing `applyValue`. ⇒ **`keepOrAll` is a SINGLE implementation
shared by `evalModules` and `cevalModules`** — so this one fail-open has **no
lockstep-duplication hazard**; one fix covers both interpreters. It does **not** cover the
native and wasm engines, whose analogue lives in the emitters (REFUSAL 5).

### C.5 IS `CProgram` STILL THE RIGHT CARRIER? **NO. The named alternative:**

> **`admisRef : Ref CAdmis` in `compiler/types/route_key.mdk`**, with
> `CAdmis = CAdmisAbsent | CAdmisTable <rows>` declared there, initialised `Ref CAdmisAbsent`,
> written by typecheck post-K, read at the four seed sites (§B.4).

Why this and not `CProgram`, in the order the facts fall out:

| criterion | 5th `CProgram` field | `Ref CAdmis` in `route_key` |
|---|---|---|
| reaches `eval.mdk:1976` | ❌ **impossible** (§C.1) | ✅ `eval.mdk:48` already imports `route_key` |
| reaches `core_ir_lower.mdk:1409` | ⚠️ only *after* the field exists — but the consumer runs *while building* it (§C.2) | ✅ `core_ir_lower.mdk:42` already imports it |
| reaches the lockstep twin `cevalModules` | ❌ `core_ir_eval` gets a `CProgram` at `:401`, but `:534` seeds from `List Decl` | ✅ one added import (§B.3.1) |
| producer can name the type | ❌ `typecheck.mdk` has no `ir.core_ir` edge | ✅ `typecheck.mdk:202` already imports `route_key` |
| sites touched in `wasm_emit_typed_main.mdk` (live concurrent writer, #1403/X-W) | **24** | **0** |
| total sites | **40** + serializer + parser | ~**6** |
| serialization question (AD-2 §5(2), P0-A §C) | forced — render/omit/gate | **does not arise** |
| snapshot goldens moved by the carrier itself | `core_ir`, `core_ir_lower`, `core_ir_eval`, `core_ir_sexp`, `core_ir_sexp_parse`, `llvm_emit`, `wasm_emit`, `draft_semantic_program`, `snapshot` | `route_key` + the touched modules |
| fail-closed representable | ✅ (two-valued) | ✅ (two-valued) — and **required**, §C.3 |
| new mechanism introduced | a 5th positional field | **none** — it is `ifaceDispatchRef` re-homed |

⚠️ **What the `Ref` carrier costs, stated rather than left to be found:**
1. **Process-global mutable state.** Order-dependent; a stale value from a prior program in the
   same process reads as authoritative. `installDispatchTables` carries this exposure today and
   manages it by re-seeding at every driver entry — the new carrier inherits that obligation at
   all four sites, and a driver that forgets is silently on stale data. This is a genuine
   regression risk relative to a value threaded in a signature, and it is the strongest
   argument that survives *for* AD-2's positional-field instinct.
2. **No arity check.** `CProgram`'s decisive safety property — *"the constructor is
   arity-checked, so every missed site is a build failure"* (P0-A bite 1) — **does not
   transfer.** A seed site that forgets to write the ref compiles clean. **Mitigation must be
   named, not assumed:** AD-2 §4.2's tripwire (`grep -rn 'CAdmisAbsent' --include=*.mdk
   compiler/` enumerates every arm as a SET) is the substitute, plus the fixture pair whose
   control makes it fail-capable.
3. **It does not, by itself, close §C.4's `keepOrAll`.** Nothing does.
4. ⚠️ **`route_key.mdk` holds ZERO `Ref`s today — it is a PURE module** (REFUSAL 3, discharged).
   The *reachability* argument for it is proven; the *home* question is a live sub-decision:
   give `route_key` its first `Ref`, or add a small new module importable by all four. The
   reachability constraint (§C.1) binds any home; the choice of home does not follow from it.

**I am not overturning C-2 unilaterally — this is a P0 analysis, not an adjudication.** What I
am asserting is that **C-2 rests on a premise that is false at HEAD** (that `CProgram` is
reachable from both consumption sites), that AD-2 explicitly declined to re-examine it, and
that the owner should re-rule it with §C.1 and §C.2 in hand.

---

## D. 🚨 THE KEY — which half is identity-bearing, at the exact point the table is built

### D.0 First, a correction to the brief's framing: **there are TWO tables, not one**

The brief says the frozen table *"must be keyed by INTERFACE IDENTITY, not `(method, head)`"*.
At HEAD, `(method, head)` describes the **impl-selection** machinery, not the admissibility
table. The two are separate and are keyed differently:

| table | key at HEAD | built at | read at |
|---|---|---|---|
| **POSITION / admissibility** (`ifaceDispatchRef`) | `(String, String)` = **bare iface name × bare method name. NO head component at all.** | `ifaceMethodEntry`, `eval.mdk:1891-1893` | `lookupPositions`, `eval.mdk:1903-1907` |
| **impl selection** (`KeyEntry`/`ImplBuckets`) | `HeadKey` (identity-bearing) + `ir.irName` (bare) | `keyEntryOfRow`, `typecheck.mdk:19100` | `ieEntriesForIface`, `typecheck.mdk:19121-19122` |

```
compiler/eval/eval.mdk:1891:ifaceMethodEntry : String -> List String -> IfaceMethod -> ((String, String), List Int)
compiler/eval/eval.mdk:1892:ifaceMethodEntry ifaceName typeParams (IfaceMethod mname mty _) =
compiler/eval/eval.mdk:1893:  ((ifaceName, mname), dispatchPositionsOf mty (receiverParam typeParams))
```
⇒ **The admissibility table has no `head` in its key.** Anyone reading "not `(method, head)`"
as a description of the table Phase 4 freezes will look for a head component that does not
exist. Phase 4's re-key is **`(bare iface, bare method)` → `(iface IDENTITY, method)`** — one
component to fix, and it is the interface one.

### D.1 THE ANSWER: at the build point, **NEITHER half is identity-bearing — and BOTH are one field away**

**PRODUCER (`ifaceDispatchEntries`, `eval.mdk:1885-1893`):**
```
compiler/eval/eval.mdk:1885:ifaceDispatchEntries : Decl -> List ((String, String), List Int)
compiler/eval/eval.mdk:1887:ifaceDispatchEntries (DAttrib _ d) = ifaceDispatchEntries d
compiler/eval/eval.mdk:1888:ifaceDispatchEntries (DInterface { name = ifaceName, typarams = typeParams, methods, ... }) = map (ifaceMethodEntry ifaceName typeParams) methods
compiler/eval/eval.mdk:1889:ifaceDispatchEntries _ = []
```
🟢 **`DInterface` HAS an `ifaceOrigin` field — this destructure simply does not project it.**
```
compiler/frontend/ast.mdk:1217:      ifaceOrigin : TyConOrigin,
```
And the same file already destructures it that way, **twelve lines below**, for the defaults:
```
compiler/eval/eval.mdk:1969:declImplEntries env _ (DInterface { name = ifaceName, ifaceOrigin = o, typarams = typeParams, methods, ... }) = flatMap (defaultEntry env (ifaceIdentity o ifaceName) typeParams) methods
compiler/ir/core_ir_lower.mdk:1402:lowerDeclImpl _ (DInterface { name = ifaceName, ifaceOrigin = o, typarams = typeParams, methods, ... }) = flatMap (lowerDefault (ifaceIdentity o ifaceName) typeParams) methods
```

**CONSUMER (`implMethodEntry` / `lowerImplMethod`) — the identity is ALREADY A LOCAL VARIABLE,
bound one line above the bare-name lookup, at BOTH lockstep sites:**
```
compiler/eval/eval.mdk:1975:  let key = implRouteKeyWord o ifaceName typeArgs None     ← `o` IS the interface's identity
compiler/eval/eval.mdk:1976:  let positions = lookupPositions ifaceName mname disp     ← and it is DISCARDED here
```
```
compiler/ir/core_ir_lower.mdk:1408:  let key = implRouteKeyWord o ifaceName typeArgs None
compiler/ir/core_ir_lower.mdk:1409:  let positions = lookupPositions ifaceName mname disp
```
That `o` is `DImpl.implOrigin` (`eval.mdk:1965`, `core_ir_lower.mdk:1397`), and the AST states
what it means:
```
compiler/frontend/ast.mdk:1222:  -- ⚠️ `implOrigin` is an OCCURRENCE carrier, not a decl-layer one: an `impl` is
compiler/frontend/ast.mdk:1223:  -- not a declaration of the interface it names, it is a USE of one — which is
compiler/frontend/ast.mdk:1225:  -- has no `DImpl` arm and must not grow one.  It is the identity of `iface`,
compiler/frontend/ast.mdk:1240:      implOrigin : TyConOrigin,
```
**⇒ `implOrigin` IS the interface identity.** So at both consumption sites, the correct key is
computable with **zero new plumbing** — it is the same `o` the adjacent line already uses.

### D.2 REPORTING THE BRIEF'S TWO FACTS — one confirmed, one *not applicable to this table*

**Fact 1 — `IfaceRef { irName, irOrigin }` at `typecheck.mdk:5794`. ✅ CONFIRMED verbatim:**
```
compiler/types/typecheck.mdk:5794:public export data IfaceRef = IfaceRef {
compiler/types/typecheck.mdk:5795:    irName : String,  -- the SPELLING; still needed for diagnostics and for the spelling-keyed KeyBuckets question
compiler/types/typecheck.mdk:5796:    irOrigin : TyConOrigin,  -- the I4 identity of the declaration this occurrence denotes
```
⚠️ **But `IfaceRef` is on `ImplRow`, i.e. on the IMPL-SELECTION table, not on the position
table.** It is the right substrate *if and only if* Phase 4 rebuilds admissibility from `IE`'s
`ieRows`. If Phase 4 instead re-keys the position table in place, the identity source is
`DInterface.ifaceOrigin` / `DImpl.implOrigin` (§D.1) and `IfaceRef` is not involved.

**Fact 2 — `headTyconTy` already returns an identity-bearing `HeadKey`. ✅ CONFIRMED:**
```
compiler/types/typecheck.mdk:19452:headTyconTy : Ty -> Option HeadKey
compiler/types/typecheck.mdk:19453:headTyconTy t = match headTyNode t
compiler/types/typecheck.mdk:19454:  TyCon { tyConName = n, tyConOrigin = o } => Some (headKeyOfCon o n)
compiler/types/typecheck.mdk:19455:  TyTuple ts => Some (headKeyOfCon OriginBuiltin (tupleHeadTagTc (listLen ts)))
compiler/types/typecheck.mdk:19456:  _ => None
```
`headKeyOfCon o n` carries the origin `o`. **BUT — per §D.0 — the admissibility table has no
head component, so this fact does not narrow Phase 4's key work; it narrows the *impl
selection* work, which is 4b's.**

⇒ **ANSWER TO THE BRIEF'S QUESTION, precisely:** at the point the admissibility table is
built, **neither half of its two-part key is identity-bearing** — both are bare `String`s
(`eval.mdk:1891`). The *method* half is legitimately a bare name (a method name is scoped by
its interface, so once the interface half carries identity the pair is scoped). **Exactly one
component needs fixing: the interface half.** The `HeadKey` half the brief expects to find
half-done belongs to a different table.

### D.3 THE KEY SPELLING — the tree already provides it, with the fail-open arm handled

Do **not** key on raw `ifaceIdentity`:
```
compiler/frontend/ast.mdk:121:export ifaceIdentity : TyConOrigin -> String -> String
compiler/frontend/ast.mdk:122:ifaceIdentity (OriginModule m) name = "\{m}::\{name}"
compiler/frontend/ast.mdk:123:ifaceIdentity OriginUnresolved _ = ""
compiler/frontend/ast.mdk:124:ifaceIdentity OriginBuiltin _ = ""
```
```
compiler/frontend/ast.mdk:113:-- 🚨 `""` IS ABSENCE OF AN IDENTITY, NOT AN IDENTITY.  Resolve is explicit that
compiler/frontend/ast.mdk:114:-- no predicate may treat two `OriginUnresolved` origins as matching each other
compiler/frontend/ast.mdk:137:export ifaceIdMatches : String -> String -> Bool
compiler/frontend/ast.mdk:138:ifaceIdMatches a b = a != "" && a == b
```
On the FLAT / loader-less drivers every interface carries `OriginUnresolved`, so raw
`ifaceIdentity` is `""` for all of them and `ifaceIdMatches` refuses `"" == ""` — **every
lookup would MISS, and under a fail-CLOSED table that means "nothing is admissible" for
`medaka check <single file>`, lsp, repl, doc.** That is a catastrophic regression, and the
tree already names the line where it would live:
```
compiler/types/route_key.mdk:138:-- 🚨 THE FALLBACK IS THE WHOLE POINT OF THIS FUNCTION — DO NOT DELETE IT AS
compiler/types/route_key.mdk:143:-- strings and absence never matches even itself). The flat drivers
compiler/types/route_key.mdk:145:-- would spell `"|T|"` for EVERY interface under `medaka check <single file>`,
compiler/types/route_key.mdk:146:-- lsp, repl, doc, lint and snapshot — collapsing onto one word the instances
compiler/types/route_key.mdk:151:-- ⚠️ THE PROPERTY THE FALLBACK RESTS ON, stated because this is precisely
compiler/types/route_key.mdk:152:-- where a silent collapse would live: the bare-name arm is safe only because
compiler/types/route_key.mdk:153:-- two same-spelled interfaces cannot both have absent origins AND be in scope
compiler/types/route_key.mdk:154:-- together — the flat path is ONE module and therefore one namespace, and
compiler/types/route_key.mdk:158:export ifaceWordOf : TyConOrigin -> String -> String
compiler/types/route_key.mdk:159:ifaceWordOf o name = match ifaceIdentity o name
compiler/types/route_key.mdk:160:  "" => name
compiler/types/route_key.mdk:161:  ident => ident
```
🟢 **`ifaceWordOf o name` is the key spelling Phase 4 wants**, and it is already the one
`implRouteKeyWord` uses on the very lines that sit beside both consumption sites:
```
compiler/types/route_key.mdk:179:export implRouteKeyWord : TyConOrigin -> String -> List Ty -> Option String -> String
compiler/types/route_key.mdk:180:implRouteKeyWord o iface tys nm = "\{ifaceWordOf o iface}|\{joinWith " " (map rkTyAtom tys)}|\{fromOption "" nm}"
```
⇒ **The re-keyed table's key is `(ifaceWordOf o ifaceName, mname)`**, computed from the same
`o` already bound at `eval.mdk:1975` / `core_ir_lower.mdk:1408`, in a module both already
import. **Zero plumbing, one existing helper, and the flat-path fallback is already
adjudicated with its safety premise written down.**

⚠️ **The premise `route_key.mdk:151-157` names is the one Phase 4 must not break:** the
bare-name fallback is safe *only because* the flat path is one module. It is a documented
precondition, not a guarantee — and a fail-CLOSED table raises the stakes on it, because under
the fallback two same-spelled flat interfaces would share a bucket and now share an
*authoritative* verdict.

### D.4 🎯 IS PHASE 4 BLOCKED ON 4b? **IT DEPENDS ENTIRELY ON WHICH SOURCE PHASE 4 READS —
and the two answers are opposite. This is the ordering question.**

| Phase 4 builds the table from… | identity available? | blocked on 4b? |
|---|---|---|
| **(α) `List Decl` — `DInterface.ifaceOrigin`**, i.e. re-key the position table in place | ✅ **YES, today.** `ifaceOrigin` on the producer (`ast.mdk:1217`), `implOrigin` on the consumer (`ast.mdk:1240`), `ifaceWordOf` as the spelling | ❌ **NOT BLOCKED.** Phase 4 can ship an identity-keyed table with no query-side change at all |
| **(β) `IE`'s `ieRows` post-K**, i.e. the sprint's stated charter | ⚠️ identity is on the ROW (`IfaceRef.irOrigin`, `typecheck.mdk:5796`) but **every selector that reads `IE` takes a bare `String`** | 🚨 **BLOCKED — and this is the freeze hazard the brief warns about** |

The (β) blocker, grep-proven — the readers' signatures:
```
compiler/types/typecheck.mdk:19119:ieEntriesForIface    : List ImplRow -> String -> List Mono -> List KeyEntry
compiler/types/typecheck.mdk:19154:ieCandidatesForIface : ImplEnv -> HeadKey -> String -> List Mono -> List KeyEntry
compiler/types/typecheck.mdk:19179:ieSelectRowByIface   : ImplEnv -> String -> List Mono -> Option ImplRow
compiler/types/typecheck.mdk:19340:ieCountHeadByIface   : ImplEnv -> String -> Option HeadKey -> Int
compiler/types/typecheck.mdk:19249:keyForSiteByIface    : String -> List Mono -> Option String
```
and the filter itself is a bare-spelling equality:
```
compiler/types/typecheck.mdk:19121: ieEntriesForIface ((r@(ImplRow _ _ ir tys _ _))::rest) iface goals
compiler/types/typecheck.mdk:19122:   | ir.irName == iface && ieRowHeadMatches tys goals = keyEntryOfRow r
```
**I independently confirm P0-A §B.1: `ir.irName == iface` is a bare SPELLING comparison.** Two
same-spelled interfaces in different modules are one bucket to it (#1619's shape).

⇒ 🚨 **If Phase 4 takes route (β) and freezes what the CURRENT selector answers, it freezes
`ir.irName == iface` — the order-dependence — behind an artifact that then reads as
authoritative. That is exactly the failure the brief names, and route (β) makes it certain,
not merely possible.** Under (β), **Phase 4 is HARD-ORDERED AFTER 4b.**

⇒ 🟢 **Route (α) is not blocked, and it is also the route the re-ruled carrier (§C.5) wants** —
a `Ref CAdmis` in `route_key`, populated from `List Decl` at the four seed sites, keyed
`ifaceWordOf`. It is a smaller unit, it discharges the sprint's actual stated goal (retire the
bare-name key + the fail-open `lookupPositions` arm), and it leaves `IE`-sourced admissibility
to a later unit once 4b has supplied identity to the selectors.

**⚠️ The honest cost of (α), because it is the reason the charter says "post-K from `IE`":** a
`List Decl` fold sees *declared* interfaces, not the *entailment-resolved* impl universe. If
the sprint needs admissibility to reflect what the selector chose (not what was declared),
(α) does not deliver it and (β) is the only route — in which case **the ordering is hard and
4b must land first.** **This is a scoping decision for the owner, and it is the single
highest-leverage open question in this packet.** I state both branches rather than picking,
because picking requires knowing which property Phase 4 is chartered to freeze, and the
sprint doc's wording ("computed once, post-K, from the global `IE`") and its stated purpose
(retire the bare-name key and the fail-open default) point at **different routes**.

---

## REFUSALS

**REFUSAL 1 — I did not re-derive AD-2's counts at ITS OWN pin `68f84bf1`.** I derived 29
constructions / 11 destructures at `aaa43716` and can state that AD-2's 13 is wrong *at HEAD*.
I cannot state whether it was wrong when written. Doing so needs a checkout of another commit,
which is outside a read-only static analysis of this worktree. **This matters for attribution
only, not for planning** — the number to plan against is HEAD's, and per §A.1 it has a shelf
life of days.

**REFUSAL 2 — I did not size option 2 (widening the elaboration return types).** I verified the
three signatures at `typecheck.mdk:14538`, `:14566`, `:28990` and that all three return
`Decl`-shaped values. I did **not** enumerate their caller set across `compiler/entries/`,
`compiler/driver/` and `compiler/tools/`, so I will not hand anyone a file or signature count
for it. If the owner wants option 2 costed, that enumeration is the first command.

**REFUSAL 3 — DISCHARGED, with a finding that qualifies §C.5.** I ran it:
```sh
$ grep -n 'Ref ' compiler/types/route_key.mdk
(no output)
```
**`types/route_key.mdk` holds ZERO `Ref`s. It is a PURE module** — word-building functions with
doctests, no mutable state at all. Adding a process-global `Ref` to it changes the module's
character and puts mutable state in the one module whose value is that both engines compute the
same *pure* word from the same inputs (`:166-169`: *"the two strings agree BY CONSTRUCTION"*).
`compiler/frontend/ast.mdk` is no better: its 23 `Ref` hits are all `Ref Route` **fields inside
data declarations**, not module-level state. **Module-level mutable state in this neighbourhood
lives in `eval.mdk` today** (`ifaceDispatchRef = Ref []`, `:271`).
⇒ §C.5's recommendation stands on reachability, but **the home is a live sub-decision**: give
`route_key` its first `Ref`, or add a small new module importable by all four. **I am not
ruling that; it belongs to whoever rules C-2.** What I have proven is the *reachability*
constraint (§C.1/§B.3.1), which any home must satisfy.

**REFUSAL 4 — DISCHARGED. The Core-IR interpreter DOES share `keepOrAll`, and the file says so.**
```
compiler/eval/eval.mdk:878:-- a call site; `applyValue` lets core_ir_eval.mdk reuse this runtime's value
compiler/eval/eval.mdk:879:-- application unambiguously.
compiler/eval/eval.mdk:880:export applyValue : Value e -> Value e -> <e> Value e
compiler/eval/eval.mdk:881:applyValue f x = apply f x
compiler/eval/eval.mdk:887:export apply : Value e -> Value e -> <e> Value e
compiler/eval/eval.mdk:895:  let r = applyDispatch f x
compiler/eval/eval.mdk:899:applyDispatch : Value e -> Value e -> <e> Value e
compiler/eval/eval.mdk:900:applyDispatch f x = match applyOpt f x
compiler/eval/eval.mdk:910:applyOpt (VMulti vs) arg = collectPartials [] (filterByTag vs arg) arg
```
and `core_ir_eval.mdk:53` imports `applyValue`. ⇒ **`applyValue → apply → applyDispatch →
applyOpt → filterByTag → keepOrAll` is a SINGLE implementation shared by both interpreters.**
§C.4's finding holds for both, and — good news for once — **this particular fail-open has no
lockstep-duplication hazard: one fix covers `evalModules` and `cevalModules` together.** It
still does not cover the two compiled engines (REFUSAL 5).

**REFUSAL 5 — I did not derive the native/wasm analogues of the `keepOrAll` decision.**
`backend/llvm_emit.mdk:5509` is a **comment** mentioning `filterByTag → runtimeTypeTag`, which
implies an emitter-side analogue exists. §C.4's incoherence finding is therefore proven for
the eval engine and **unproven for the two compiled engines**. A Phase 4 that closes the
fail-open behaviour owes all three engines, and I have sized only one.

**REFUSAL 6 — I am not adjudicating C-2.** §C.1 and §C.2 establish that C-2's carrier is
unreachable from one consumption site and downstream of the other. Whether that overturns C-2
or reshapes it is the owner's ruling, not mine. I have named the alternative and costed both;
I have not decided.

**REFUSAL 7 — I did not verify the FLAT-arm behaviour of `ifaceWordOf` empirically.** §D.3
rests on `route_key.mdk:138-161`'s own doc-comment and on `ast.mdk:121-138`. Both are prose
in the tree, not a measurement. The claim that *"every interface under `medaka check <single
file>` carries `OriginUnresolved`"* is the tree's assertion, and I am relaying it as such.
Confirming it needs a binary.

---

## SUMMARY

**Does AD-2's two-valued ruling survive?** **The TYPE ruling: YES, and on stronger ground.**
Today's live fail-open arm `lookupPositions _ _ [] = [0]` (`eval.mdk:1904`) discriminates on
`[]` — the exact value a two-valued carrier splits into `CAdmisAbsent` vs `CAdmisTable []`.
`Option` stays rejected, and AD-2 §4.1's argument transfers verbatim and binds harder on the
recommended `Ref` carrier, which *must* have an initialiser. **The CARRIER ruling: NO.**
`compiler/eval/eval.mdk` has zero `CProgram` occurrences and no `ir.` import, so a 5th
`CProgram` field cannot reach one of the two lockstep consumption sites at all; and
`lowerImpls` — which contains the other — is an *argument* to the `CProgram` constructor
(`core_ir_lower.mdk:533`), so the field is downstream of its own consumer. Recommended
alternative: **`Ref CAdmis` in `compiler/types/route_key.mdk`**, the module all three of
`typecheck.mdk:202`, `core_ir_lower.mdk:42` and `eval.mdk:48` already import — ~6 sites
instead of 40, **zero** in the concurrently-written `wasm_emit_typed_main.mdk`, and no
serialization question at all.

**Is there a seam channel?** **Yes — P0-A's "no channel at all" is over-stated.** Typecheck
already crosses the seam by stamping mutable `Ref`s inside `EMethodAt` (`ast.mdk:919`;
written `typecheck.mdk:6613-6614`, read `core_ir_lower.mdk:150` and `eval.mdk:1256`). What is
missing is a channel for a *whole-program* value — a narrower gap, with four enumerated
options (§B.3), of which the recommended one costs **zero signature changes**.

**Is Phase 4 ordered before or after 4b?** **It depends on which source Phase 4 reads, and the
sprint doc's two statements of intent point at different routes.** From `List Decl` /
`DInterface.ifaceOrigin` (route α): **NOT blocked** — identity is available today at producer
and both consumers, and `ifaceWordOf` is the ready-made key spelling. From `IE`'s `ieRows`
post-K (route β, the charter's literal wording): **HARD-ORDERED AFTER 4b**, because every `IE`
reader takes a bare `String` and `ieEntriesForIface` filters on `ir.irName == iface`
(`typecheck.mdk:19121-19122`) — freezing that selector's answers freezes the order-dependence
behind an authoritative table, which is exactly the failure the sprint is trying to prevent.

**Two things the brief did not ask about that I would not let ship silently:**
1. **The admissibility table has NO head component** (`eval.mdk:1891-1893`) — the brief's
   `(method, head)` framing describes the impl-selection table, and `headTyconTy`'s
   already-identity-bearing `HeadKey` therefore does **not** narrow Phase 4's key work (§D.0).
   Exactly one component is bare: the interface half.
2. **`keepOrAll original [] = original` (`eval.mdk:938`) is structurally unreachable from any
   carrier** — it filters candidate VALUES, not the table. A fail-closed table upstream of it
   is RUN-B-013's own *"has changed nothing"* warning, arriving with the table now *reading* as
   authoritative. It must be retired in the same unit, or the unit must not claim to have
   closed the fail-open behaviour (§C.4).
