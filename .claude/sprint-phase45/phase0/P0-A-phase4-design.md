# P0-A — Phase 4 (`B-2.3`, frozen admissibility) DESIGN RUN

**Packet:** P0-A. **Role:** read-only static analyst. **No build, no gate, no `./medaka`
invocation was made.** Every claim below is derived by `grep`/`sed`/`awk` over the worktree
`/root/medaka/.claude/worktrees/peppy-brewing-kitten`.

**Pin:** `BASE = aaa437167b633d6070adccd055c8c2a19e9bb8c6` (`git rev-parse HEAD`, this worktree).
⚠️ The sprint doc `.claude/STAGE-B-PHASE45-SPRINT.md` pins itself at `0913762f` and AD-2 pins
itself at `68f84bf1`. **Neither is HEAD.** Every citation relayed out of those documents below
was re-derived at `aaa43716` and the re-derivation is shown. Where a relayed number moved, it is
flagged 🔴.

---

## A. THE CURRENT STATE, DERIVED

### A.0 headline — the single most important correction to the sprint's framing

🔴 **Arg-tag admissibility is NOT computed in `compiler/types/typecheck.mdk` today. Not
anywhere in it.** It is computed in `compiler/eval/eval.mdk`, from `List Decl`, and consumed in
`eval.mdk` *and* `compiler/ir/core_ir_lower.mdk` — the known lockstep pair. `typecheck.mdk`
contains **exactly one** hit for the admissibility machinery, and it is a **comment**:

```sh
grep -rn 'lookupPositions\|dispatchPositionsOf\|keepOrAll\|buildIfaceDispatch' \
  --include=*.mdk compiler/types/
# compiler/types/typecheck.mdk:28999:-- default RNone → eval arg-tag-dispatched a Map through the no-matching-tag `keepOrAll`
```
i.e. **zero code sites in `compiler/types/`.**

Consequence for Phase 4's charter — *"computed once, post-K, from the global `IE`"* — this is not
a re-keying of an existing typecheck table. **It is a RELOCATION** of a computation that today
lives one layer down (AST → Core IR / eval values) up into the typechecker, plus a re-keying.
That is a materially bigger unit than "re-key the table", and the bite list in §E is sized for
the relocation, not for a re-key.

### A.1 Where admissibility is computed TODAY — every site, by symbol

Two distinct things are conflated under "arg-tag admissibility" and Phase 4 must say which it
freezes. Both are enumerated.

#### A.1.1 The POSITION table — *which argument slots are dispatch-bearing*

| # | symbol | file:line | what it does |
|---|---|---|---|
| 1 | `dispatchPositionsOf` | `compiler/eval/eval.mdk:522-523` | `filterMentions 0 (argsOfTy mty) params` — the per-method arg-slot computation |
| 2 | `receiverParam` | `compiler/eval/eval.mdk:1899-1901` | the dispatch typaram = FIRST interface param only |
| 3 | `ifaceMethodEntry` | `compiler/eval/eval.mdk:1891-1893` | mints one row `((ifaceName, mname), positions)` |
| 4 | `ifaceDispatchEntries` | `compiler/eval/eval.mdk:1885-1889` | per-`Decl` projection (with the `DAttrib` unwrap, #1037) |
| 5 | `buildIfaceDispatch` | `compiler/eval/eval.mdk:1882-1883` | `flatMap ifaceDispatchEntries prog` — the whole table |
| 6 | `ifaceDispatchRef` | `compiler/eval/eval.mdk:270-271` | `Ref (List ((String, String), List Int))`, the installed copy |
| 7 | `lookupPositions` | `compiler/eval/eval.mdk:1903-1907` | the READER — **fails OPEN** (see A.1.3) |
| 8 | `installDispatchTables` | called at `compiler/ir/core_ir_lower.mdk:1233` | the Core-IR-side installer (`lowerImpls`) |

Proof of the type (this is the whole bare-name-key finding, §D):

```
compiler/eval/eval.mdk:270:ifaceDispatchRef : Ref (List ((String, String), List Int))
compiler/eval/eval.mdk:1882:buildIfaceDispatch : List Decl -> List ((String, String), List Int)
compiler/eval/eval.mdk:1903:export lookupPositions : String -> String -> List ((String, String), List Int) -> List Int
```

**The key is `(String, String)` = bare interface NAME × bare method NAME. It has no origin, no
module id, no `Ident`.**

#### A.1.2 Is it re-derived per call site? **NO — and that is a trap for the sprint's framing**

It is derived **once per lowering/eval run**, not per call site:

```
compiler/eval/eval.mdk:282:  let disp = buildIfaceDispatch allDecls
compiler/eval/eval.mdk:284:  let _ = setRef ifaceDispatchRef disp
compiler/ir/core_ir_lower.mdk:1233:  lowerImplsWith (installDispatchTables prog) prog
```

and threaded down as a `disp` parameter to exactly two consumers:

```
compiler/eval/eval.mdk:1976:  let positions = lookupPositions ifaceName mname disp
compiler/ir/core_ir_lower.mdk:1409:  let positions = lookupPositions ifaceName mname disp
```

⇒ **the POSITION half is already "computed once and frozen into the output as data"** — into
`VTypedImpl tag key positions 0 inner` (`eval.mdk:1978`) and into
`CImplTagged tag key ifaceName positions pats (lower body)` (`core_ir_lower.mdk:1413`). Phase 4
is *not* introducing freezing to a per-site re-derivation here. What it is introducing is (a) a
correct KEY and (b) a correct SOURCE (`IE`, post-K, instead of `List Decl` at lower time).

🚨 **Honest consequence: if the sprint's justification for Phase 4 is "stop re-deriving per call
site", that justification is FALSE for the position table.** The real justification is the key
and the fail-open default, both below.

#### A.1.3 The DECISION half — where admissibility is actually *applied*, and where it fails open

This is the part that is genuinely decided at runtime, per application, and it is **three
fail-open defaults deep**:

| # | symbol | file:line | verdict |
|---|---|---|---|
| 1 | `lookupPositions _ _ [] = [0]` | `compiler/eval/eval.mdk:1904` | 🚨 **FAILS OPEN** — an empty table declares slot 0 dispatchable |
| 2 | `filterByTag` | `compiler/eval/eval.mdk:928-931` | `not (anyList isDispatching vs) = vs` — no dispatching candidate ⇒ keep all |
| 3 | `filterByTagT vs None = vs` | `compiler/eval/eval.mdk:934` | no runtime tag ⇒ keep all |
| 4 | `keepOrAll original [] = original` | `compiler/eval/eval.mdk:937-939` | 🚨 **FAILS OPEN** — every tagged candidate filtered out ⇒ return the ORIGINAL set |
| 5 | `keepCand` | `compiler/eval/eval.mdk:941-942` | `not (isDispatching v) \|\| matchesTag tag v` |
| 6 | `isDispatching` | `compiler/eval/eval.mdk:944-946` | `containsInt seen pos` |

⚠️ 🔴 **AD-2 §2 cites these as `eval.mdk:1934` and `eval.mdk:967-969`. At HEAD they are
`eval.mdk:1904` and `eval.mdk:937-939` — a −30 drift, exactly the magnitude the sprint doc's Q1
table records for `eval.mdk` symbols.** The symbols survive; the line numbers in RUN-B-013 and
in AD-2 are stale. Do not quote them.

Re-derivation:
```sh
grep -n 'lookupPositions _ _ \[\] = \[0\]\|keepOrAll original \[\] = original' compiler/eval/eval.mdk
# 1904:lookupPositions _ _ [] = [0]
# 938:keepOrAll original [] = original
```

**This is the precedent RUN-B-013 condition 1 is built on, and it is still live at HEAD.** A
frozen table that inherits either default has changed nothing.

### A.2 `CProgram` today — fields and EVERY construction site

**Declaration** (`compiler/ir/core_ir.mdk:241-242`):
```
public export data CProgram =
  | CProgram (List CBind) (List (String, Int)) (List (String, String)) (List CImplEntry)
```
Four fields: binds · ctor arities · ctor→type · impl entries. ⚠️ Note the **two-line
`data X =` / `| X …` header form** — AD-2 §4.4's `fmt --write` hazard (#829) applies verbatim.
Confirm before editing: `grep -n '^data CProgram =$' -A1 compiler/ir/core_ir.mdk` — here it is
`public export data`, same unsafe two-line shape.

#### A.2.1 DESTRUCTURE sites — **11**, agreeing with AD-2

```sh
grep -rnE '\(CProgram [a-z]|CProgram [a-z_]+ [a-z_]+ [a-z_]+ [a-z_]+ *=>' --include=*.mdk compiler/
```
```
compiler/entries/llvm_emit_modules_main.mdk:86   preludeSymsOf
compiler/ir/core_ir_eval.mdk:401                 cevalProgram
compiler/ir/core_ir_sexp.mdk:225                 cprogramToSexp
compiler/ir/draft_semantic_program.mdk:313       cprogramSummary
compiler/entries/wasm_emit_typed_main.mdk:567    implSelfCensusProgram
compiler/ir/core_ir_lower.mdk:642                rewriteProgramRecPats
compiler/ir/core_ir_lower.mdk:1001               hoistNullaryMemo
compiler/backend/wasm_emit.mdk:1055              emitProgramWith
compiler/backend/wasm_emit.mdk:1113              emitProgramGaps
compiler/backend/llvm_emit.mdk:10761             emitProgramMode
compiler/backend/llvm_emit.mdk:11131             emitProgramGaps
```
**11 — unchanged from AD-2's list, same members.** Each becomes a compile error on a 5th field.

#### A.2.2 CONSTRUCTION sites — 🔴 **29 at HEAD, not 13**

AD-2 says 13. **I get 29.** The delta is entirely `compiler/entries/wasm_emit_typed_main.mdk`,
which AD-2 counted at 8 and which is now at **23** — this file is the one PR #1623 created/grew
(the sprint doc §2b names it as a live concurrent writer from the emitter arc).

| file | lines | n |
|---|---|---|
| `compiler/ir/core_ir_lower.mdk` | 529 (`lowerProgram`), 643 (`rewriteProgramRecPats`), 1003 + 1011 (`hoistNullaryMemo`) | 4 |
| `compiler/ir/core_ir_sexp_parse.mdk` | 381 (`parseCProgram` — the **deserializer**) | 1 |
| `compiler/entries/llvm_emit_typed_main.mdk` | 77 | 1 |
| `compiler/entries/wasm_emit_typed_main.mdk` | 222, 234, 291, 294, 396, 409, 423, 435, 450, 463, 476, 479, 491, 519, 531, 538, 558, 568, 663, 682, 725, 831, 842 | 23 |
| **total** | | **29** |

Re-derive (two commands, because continuation-line constructions put `CProgram` alone on a line):
```sh
grep -rnE '^ +CProgram *$' --include=*.mdk compiler/          # 7 continuation-line constructions
grep -rn '\bCProgram\b' --include=*.mdk compiler/ | grep -vE '^[^:]+:[0-9]+: *--'   # then classify
```

🚨 **This is the single largest sizing correction in this document.** AD-2's *"either spelling
costs the same 24 sites"* is now **40 sites** (11 destructures + 29 constructions), and **23 of
the 29 are in one probe-driver file with an active concurrent writer from another arc (#1403 /
X-W).** See §F REFUSAL 1 — this is a real merge-conflict exposure that the Phase 4 bite list
must sequence around, and the count has a shelf life measured in days.

#### A.2.3 The typed/untyped split, re-verified

`lowerProgramEmit` is a **wrapper**, not a peer (`compiler/ir/core_ir_lower.mdk:555-559`):
```
555: export lowerProgramEmit : List Decl -> CProgram
556: lowerProgramEmit prog =
557:   hoistNullaryMemo (rewriteProgramRecPats
558:     (declaredRecordFieldOrders prog)
559:     (lowerProgram prog))
```
AD-2 §1.3 cited `:551-555`; at HEAD it is `:555-559`. 🔴 **+4 drift; the claim survives
verbatim.** A table parameter added to `lowerProgram` must be added to `lowerProgramEmit` and
forwarded: one hop, no branch — confirmed at HEAD.

### A.3 What is "post-K"? — named by symbol, with the completion point

**K = Stage K, the whole-graph declaration environments** (`compiler/TYPECHECK-TARGET-ARCHITECTURE.md`
§2 K). `IE` is its impl registry. Named at `compiler/types/typecheck.mdk:3948`:
> `-- WHAT THIS IS.  Stage K's `IE`: one registry answering "what impls exist",`

**`IE` is complete at two build sites, one per driver arm:**

| arm | builder | file:line | completion point |
|---|---|---|---|
| Module | `buildImplEnv` | `compiler/types/typecheck.mdk:4140-4143` | `ImplEnv { env \| ieUnivSnaps = ieBuildSnaps env.ieRows }` — the fold over ALL modules has finished |
| Flat | `buildFlatImplEnv` | `compiler/types/typecheck.mdk:4201-4205` | one flat program, all rows ordinal 0 |

**The graph-global `IE` is INSTALLED — and is therefore first readable-as-complete — at exactly
one place**, `checkBodyImpl` (definition at `compiler/types/typecheck.mdk:21069`):

```
21281:  let _ = match mode
21282:    Flat _ => setRef perRun.value.bodyImplEnvRef (buildFlatImplEnv fullUniverse)
21283:    Module _ _ _ => setRef perRun.value.bodyImplEnvRef driverState.value.declEnvsRef.value.deImpls
```

and on the Module arm `deImpls` was itself built at `compiler/types/typecheck.mdk:2812`
(`deImpls = buildImplEnv mods`).

⇒ **"post-K" = after `typecheck.mdk:21281-21283`.** That is the earliest point at which a
whole-graph admissibility table can be computed from `IE` on **both** driver arms with one
substrate. ⚠️ It is *inside* `checkBodyImpl`, i.e. **per body**, not once per program — see
§F REFUSAL 2.

---

## B. 🚨 THE DOMINATING CONSTRAINT — interface identity, and what the tree actually gives you

### B.1 The `*ByIface` family EXISTS. **It is interface-NAME-keyed, NOT interface-IDENTITY-keyed.**

All five symbols the brief names exist at HEAD. Exact signatures, grep-proven:

```
compiler/types/typecheck.mdk:19119:ieEntriesForIface : List ImplRow -> String -> List Mono -> List KeyEntry
compiler/types/typecheck.mdk:19154:ieCandidatesForIface : ImplEnv -> HeadKey -> String -> List Mono -> List KeyEntry
compiler/types/typecheck.mdk:19179:ieSelectRowByIface : ImplEnv -> String -> List Mono -> Option ImplRow
compiler/types/typecheck.mdk:19340:ieCountHeadByIface : ImplEnv -> String -> Option HeadKey -> Int
compiler/types/typecheck.mdk:19249:keyForSiteByIface : String -> List Mono -> Option String
```

🚨 **Every one of them takes the interface as a bare `String`.** And the filter is a bare-name
string equality:

```
19121: ieEntriesForIface ((r@(ImplRow _ _ ir tys _ _))::rest) iface goals
19122:   | ir.irName == iface && ieRowHeadMatches tys goals = keyEntryOfRow r
```

⇒ 🔴 **The sprint doc §2b derivation 2 — *"the interface-keyed peer ALREADY EXISTS, and the tree
already states it is immune"* — is TRUE ONLY FOR CONJUNCT-1's METHOD-NAME HALF.** It is
**false** for interface *identity*. `ieEntriesForIface` scopes by the interface's SPELLING. Two
same-spelled interfaces in two different modules are **still one bucket** to it.

Concretely, against the sprint's own drain list:

| issue | shape | does `*ByIface` fix it? |
|---|---|---|
| #1182 / #1620 | two **differently-named** interfaces share a METHOD name | ✅ yes — `ir.irName == iface` separates them |
| #1619 | a **same-spelled** interface in another module hijacks a default | ❌ **NO** — `irName` is equal on both; they stay in one candidate set |

**Phase 4's constraint is `module::Iface`, not `Iface`. The `*ByIface` family as it stands does
not satisfy it.** Anyone reading the ADOPTED RULING's derivation 2 as "the identity-keyed peer
already exists" will freeze the order-dependence for the #1619 shape behind an authoritative
table — the exact failure the constraint exists to prevent.

### B.2 …but the identity IS already on the row. No plumbing needed on the PRODUCER side.

`ImplRow` carries an `IfaceRef`, and `IfaceRef` carries the origin beside the name:

```
compiler/types/typecheck.mdk:4073:data ImplRow =
compiler/types/typecheck.mdk:4074:  | ImplRow Int InstRef IfaceRef (List Ty) (List Require) (List String)
compiler/types/typecheck.mdk:5795:    irName : String,  -- the SPELLING; still needed for diagnostics and for the spelling-keyed KeyBuckets question
compiler/types/typecheck.mdk:5796:    irOrigin : TyConOrigin,  -- the I4 identity of the declaration this occurrence denotes
```

**And the identity comparator already exists**, used by the coherence checker:
```
compiler/types/typecheck.mdk:16343:cohSameIface a b = sameTyConHead a.irName a.irOrigin b.irName b.irOrigin
```

`keyForSite` says so in its own comment, verbatim (`compiler/types/typecheck.mdk:18563-18565`):
> *"`ir.irOrigin` is in hand here — `ImplRow`'s `IfaceRef` field carries the origin beside the
> name, so no selection work is added and the collision gate above is untouched"*

⇒ **Answer to the brief's question:** at the point the frozen table would be BUILT (a fold over
`IE`'s `ieRows`), **interface identity is already available as a value** — `(ieRowTriple r).0`
gives you the `IfaceRef`, with `irName` **and** `irOrigin`. Nothing needs plumbing there.

### B.3 The SUPPLY problem is at the CONSUMER, and it is real

Every reader hands the selector a bare `String`. The three call sites of `ieSelectRowByIface`:

```
compiler/types/typecheck.mdk:19252:  match ieSelectRowByIface env iface goals            -- in keyForSiteByIface
compiler/types/typecheck.mdk:20227:  | otherwise = ieRowHeadTriple (ieSelectRowByIface perRun.value.bodyImplEnvRef.value iface goals)
compiler/types/typecheck.mdk:22674:concreteReqMatchByIface iface args = match ieSelectRowByIface perRun.value.bodyImplEnvRef.value iface args
```

and `keyForSiteByIface`'s own caller passes a `String` too:
```
compiler/types/typecheck.mdk:19939:  let routeKey = fromOption tag (keyForSiteByIface iface (m::rest))
```

⇒ **This is the sprint doc's residual 1 (*"the risk is SUPPLY, not shape"*) — CONFIRMED, and it
is worse than the doc frames it.** The doc frames supply as a question about *whether an
interface is in hand at each site*. The measured answer is: **an interface NAME is in hand at
every site; an interface IDENTITY is in hand at none of them.** The substitution is not "one
line given an interface" — it is a signature change `String → IfaceRef` propagated back through
the readers to wherever the `String` was first projected off an `IfaceRef` (`.irName`, of which
`grep -c 'irName' compiler/types/typecheck.mdk` reports **89** lines — comments included, so
that is an upper bound, not a site count; derive the code-only set the way
`headTyconNameTy`'s own doc-comment at `compiler/types/typecheck.mdk:19464-19466` derives its
residuals, with both comment filters).

⚠️ There is a **fail-open hazard in the identity itself** that Phase 4 must handle explicitly,
and the tree already documents it (`compiler/types/typecheck.mdk:18575-18577`):
> *"On the loader-less drivers (`check <single file>`, lsp, repl, doc) the origin is absent and
> `ifaceWordOf` falls back to the bare name — the pre-bite word exactly. That fallback is
> load-bearing"*

and `compiler/types/typecheck.mdk:5814`: `ifaceRefBare n = IfaceRef { irName = n, irOrigin = OriginUnresolved }`.

⇒ **On FLAT, `irOrigin` is `OriginUnresolved` for user declarations** (see also
`compiler/types/registry.mdk:170-173`, which records exactly this for the `RegKey` conversion).
An identity-keyed table that treats `OriginUnresolved == OriginUnresolved` as "same interface"
re-collapses every FLAT interface into one bucket. **`cohSameIface` / `sameTyConHead` is the
comparator to reuse precisely because it already has to answer this** — verify its
`OriginUnresolved` arm before building on it (see §F REFUSAL 3: I did not verify that arm).

### B.4 The other half of the key: `headTyconTy`'s `_ => None` arm set (sprint Q7)

The sprint doc's Q7 is a **Phase 4 PRECONDITION, not an independent unit**, and the derivation is
one line: the frozen table's head component comes from `headTyconTy`, via
`keyEntryOfRow`/`KeyEntry`:

```
compiler/types/typecheck.mdk:19100:    KeyEntry ms (headTyconTy headTy) headTy (implKeyTc ir.irName tys) ir.irName tys reqs (instRefSeq inst)
```

**The arm set, enumerated — it is THREE arms and I derived them**
(`compiler/types/typecheck.mdk:19452-19456`):
```
19452: headTyconTy : Ty -> Option HeadKey
19453: headTyconTy t = match headTyNode t
19454:   TyCon { tyConName = n, tyConOrigin = o } => Some (headKeyOfCon o n)
19455:   TyTuple ts => Some (headKeyOfCon OriginBuiltin (tupleHeadTagTc (listLen ts)))
19456:   _ => None
```
with `headTyNode` (`:19433-19435`) peeling only `TyApp`. ⇒ **`TyFun` (#1617), `TyEffect`
(#1618) and `TyConstrained` (unfiled) all land in `_ => None`. CONFIRMED, grep-proven, at
HEAD.** Q7's answer is therefore: **precondition, not independent unit** — a table frozen off
this projection cannot discriminate three type shapes, and freezing makes that permanent behind
an authoritative artifact. See §E bite 0.

🟢 **Good news, and it materially narrows Phase 4's key work:** `headTyconTy` already returns an
**identity-bearing** `HeadKey` (`headKeyOfCon o n` — origin `o` read straight off
`TyCon.tyConOrigin`). ⇒ **the HEAD half of the frozen table's key is already `module::Tycon`;
only the INTERFACE half is bare.** Phase 4's identity work is one component, not two.

### B.5 The MODULE-GRAPH constraint on where the table can live (nobody has stated this)

Derived from the import lines, not assumed:

```
compiler/ir/core_ir.mdk:52:       import frontend.ast.{Lit, Pat, Addr, Route}     -- and NOTHING else
compiler/ir/core_ir_lower.mdk:42: import types.route_key.{implRouteKeyWord}
compiler/types/typecheck.mdk:202: import types.route_key.{implRouteKeyWord}
compiler/types/route_key.mdk:125: import frontend.ast.{...}
compiler/types/route_key.mdk:132: import support.util.{joinWith, escStr}
```
and `grep -n '^import' compiler/ir/core_ir_lower.mdk` shows **no `types.typecheck` edge**, while
`grep -n '^import' compiler/types/typecheck.mdk` shows **no `ir.core_ir` edge**.

⇒ **The producer (`typecheck.mdk`) cannot today name the carrier's type (`ir/core_ir.mdk`), and
the consumer (`core_ir_lower.mdk`) cannot today read the producer's `perRun` ref.** Two ways
out, both acyclic:

| option | edge to add | cost |
|---|---|---|
| **(a)** define `CAdmis` in `ir/core_ir.mdk` beside `CProgram` | `types.typecheck → ir.core_ir` | pulls the whole Core IR into the typechecker's graph; crosses a layer |
| **(b) RECOMMENDED** — define `CAdmis` + its key spelling in **`types/route_key.mdk`** | `ir.core_ir → types.route_key` | route_key imports only `frontend.ast` + `support.util`, so no cycle; **both sides already import it** |

Option (b) also puts the type next to `implRouteKeyWord`, which is where the definition-side and
checker-side route words are already kept byte-equal — the same "one spelling, two engines"
discipline the frozen key needs.

⚠️ **Neither option answers how the table's VALUE travels.** `typecheck` produces it post-K in
`perRun`; `lowerProgram`/`lowerProgramEmit` consume it. The tree's existing mechanism for
carrying a typecheck decision into lowering is **stamping into the AST** (`EMethodAt` + `Route`),
not passing a table. AD-2 §1.3's *"a table parameter added to `lowerProgram` must also be added
to `lowerProgramEmit` and forwarded: one hop, no branch"* is correct about the **signature** and
silent about the **29 construction sites** (§A.2.2) and about which driver supplies the value.
See §E bite 4 and §F REFUSAL 2.

---

## C. Q2 RULED — render, omit, or the third arm the question does not offer

### C.1 The facts, derived

**1. `cprogramToSexp` emits exactly FOUR sub-lists** (`compiler/ir/core_ir_sexp.mdk:224-232`):
```
224: export cprogramToSexp : CProgram -> String
225: cprogramToSexp (CProgram binds ctorArities ctorToType impls) = node
226:   "CProgram"
227:   [
228:     slist (map cbindSexp binds),
229:     slist (map ctorArityPairSexp ctorArities),
230:     slist (map ctorTypePairSexp ctorToType),
231:     slist (map cimplEntrySexp impls),
232:   ]
```
✅ AD-2 §5(2) and the sprint doc are both CORRECT here.

**2. `parseCProgram` matches an EXACT-ARITY `SList` and panics otherwise**
(`compiler/ir/core_ir_sexp_parse.mdk:379-382`):
```
379: export parseCProgram : String -> CProgram
380: parseCProgram s = match parseAll s
381:   SList ((SAtom "CProgram")::[SList binds, SList ctorArities, SList ctorTypes, SList impls]) => CProgram (map toCBind binds) …
382:   other => panic ("core_ir_sexp_parse: bad CProgram: " ++ sexprToStr other)
```
✅ CORRECT. A 5-sub-list render against an unchanged parser is a **hard panic**, not a silent drop.

**3. `core_ir_roundtrip_main.mdk` does lower → serialize → re-parse → evaluate**
(`compiler/entries/core_ir_roundtrip_main.mdk:28-31`):
```
28:    let prog = lowerProgram (annotateProgram (desugar (parse src)))
29:    let sexp = cprogramToSexp prog
30:    let prog2 = parseCProgram sexp
31:    putStrLn (cevalMain prog2)
```
✅ CORRECT.

### C.2 🔴 …but the hazard both documents infer from fact 3 does NOT reproduce. Here is why.

The sprint doc (§4 Q2) and AD-2 §5(2) both say: *"a non-round-tripped field silently becomes
`CAdmisAbsent` after a round trip — a silent-wrongness shape, not a golden move."*

**That inference needs a round-trip driver whose field was NON-absent to begin with. There is
none.**

- `parseCProgram` has **exactly ONE consumer in the whole tree**:
  ```sh
  grep -rn 'parseCProgram' --include=*.mdk compiler/
  # compiler/ir/core_ir_sexp_parse.mdk:379,380        (the definition)
  # compiler/entries/core_ir_roundtrip_main.mdk:6,18,30  (comment, import, the ONE call)
  ```
- and that consumer's lowering is `lowerProgram (annotateProgram (desugar (parse src)))`
  (`:28`) — **the untyped, `IE`-free path.** It never runs `elaborateModules`, never reaches
  `checkBodyImpl`, never seats `bodyImplEnvRef`. Its admissibility field is `CAdmisAbsent`
  **before** serialization and `CAdmisAbsent` after.

⇒ **`CAdmisAbsent → CAdmisAbsent` is not silent wrongness; it is a fixed point.** The round-trip
gate `test/diff_compiler_core_ir_roundtrip.sh` cannot observe the field at all without first
making its driver typed — a change nobody has proposed.

🚨 **A claim reaching past its evidence, inherited identically by two documents.** The
*mechanism* (arity-exact parser + a round-trip driver) is real; the *consequence* (silent
wrongness) needs a fact neither document checked. It materially changes Q2's cost balance.

### C.3 What ACTUALLY moves under each arm — grep-proven

The S-expression **text** reaches a committed golden through exactly one route: `medaka
snapshot`'s `CORE_IR` section (`compiler/tools/snapshot.mdk:746`), rendered by
```
compiler/tools/snapshot.mdk:567: coreIrOf : List Decl -> String
compiler/tools/snapshot.mdk:568: coreIrOf d = cprogramToSexp (lowerProgram (annotateProgram d))
```
— again the **untyped** path.

```sh
grep -rl 'CORE_IR' test/snapshots/ | sed 's|.*/snapshots/||;s|/[^/]*$||' | sort | uniq -c
#  1 compiler        (test/snapshots/compiler/snapshot.md — the SOURCE of snapshot.mdk, not a CORE_IR section)
# 24 eval_fixtures
```

| arm | goldens that move | gate |
|---|---|---|
| **RENDER (unconditional)** | the `CORE_IR` section of **24** `test/snapshots/eval_fixtures/*.md` | `test/diff_compiler_snapshot_core_ir.sh` (`run_family eval_fixtures core_ir`, `:100`) |
| **OMIT** | none of the above | — |
| **EITHER ARM, unavoidably** | `test/snapshots/compiler/{core_ir,core_ir_sexp,core_ir_sexp_parse,core_ir_lower,core_ir_eval,snapshot,draft_semantic_program,llvm_emit,wasm_emit}.md` — the compiler's own sources are in the snapshot corpus, so **any** `CProgram` arity change moves them | `test/diff_compiler_snapshot_frontend.sh` (compiler family) |
| **EITHER ARM** | `test/selfproc_goldens/legA/types.typecheck.golden` (bite 3) and `eval.eval.golden` (bite 5) | `test/diff_compiler_selfproc.sh` — **CI `backend` shard only** |

⚠️ Correction to a plausible-sounding error: `test/selfproc_goldens/legA/ir.sexp.golden` is
`compiler/ir/sexp.mdk` (the **AST** S-expr), **not** `core_ir_sexp.mdk`. `ls compiler/ir/` shows
both files. `core_ir_lower` is explicitly NOT in the LEG A corpus per `AGENTS.md`.

⇒ **The whole Q2 cost delta is 24 files in ONE gate.** OMIT's "goldens hold still" advantage is
smaller than the sprint doc implies (both arms move the compiler-source snapshots and both LEG A
goldens anyway), and OMIT's "silent wrongness" disadvantage is, per C.2, **not real at HEAD**.

### C.4 🟢 The third arm the question does not offer — already an idiom in this exact file

```
compiler/ir/core_ir_sexp.mdk:47: faithfulRoutesRef : Ref Bool
compiler/ir/core_ir_sexp.mdk:48: faithfulRoutesRef = Ref False
compiler/ir/core_ir_sexp.mdk:52: export setFaithfulRoutes : Bool -> Unit
compiler/ir/core_ir_sexp.mdk:53: setFaithfulRoutes b = setRef faithfulRoutesRef b
compiler/ir/core_ir_sexp.mdk:68: -- gated behind faithfulRoutesRef so ONLY the debug probe pays the widening.
```
`compiler/frontend/resolve.mdk:4343` calls it *"the established probe-flag idiom"*. Its only
caller is the designated dispatch probe:
```
compiler/entries/core_ir_typed_modules_dump_main.mdk:42:  let _ = setFaithfulRoutes True
compiler/entries/core_ir_typed_modules_dump_main.mdk:43:  putStr (cprogramToSexp (lowerProgramEmit allDecls))
```
with its own justification (`:39-41`): *"the golden path never calls this, so the committed
core_ir_sexp/snapshot corpus stays byte-identical."*

### C.5 RECOMMENDATION (yours to rule; here is the derivation)

**RENDER, behind the existing `faithfulRoutesRef` gate, defaulting OFF** — i.e. arm 3.

| | RENDER (unconditional) | OMIT | **arm 3: gated render** |
|---|---|---|---|
| 24 `eval_fixtures` snapshots move | yes | no | **no** (flag off on the golden path) |
| compiler-source snapshots + 2 LEG A goldens move | yes | yes | yes — unavoidable |
| `parseCProgram` must change | **yes, or it PANICS** | no | **no** (flag off ⇒ 4 sub-lists ⇒ parser untouched) |
| `core_ir_typed_modules_dump_main` can show admissibility | yes | **no** | **yes** — the flag is already `True` there, `:42` |
| new precedent introduced | — | — | **none; it is this file's own idiom** |

Decisive: OMIT costs the sprint the **one probe `AGENTS.md` designates for "which impl did it
actually pick"**, on the exact sprint where that is the question. Unconditional RENDER costs a
24-file re-cut **and** a parser change on a path that provably gains nothing from it (C.2). Arm
3 pays neither.

⚠️ **What arm 3 does NOT give you, stated rather than left to be found:** a gated render is
exercised by **no gate**, so its correctness is unpinned — the same criticism that already
applies to `faithfulRoutesRef`. If you want it graded, the honest add-on is one fixture in a
*new* golden family driven by `core_ir_typed_modules_dump_main`, not a widening of the 24. I did
**not** derive whether such a family exists — §F REFUSAL 4.

---

## D. Q3 — proving the key is SCOPED

### D.1 The unscoped key is not hypothetical — it is the table Phase 4 replaces

```
compiler/eval/eval.mdk:270:ifaceDispatchRef : Ref (List ((String, String), List Int))
```
**Key = (bare interface name, bare method name). Program-global. No module id, no origin, no
`Ident`.** Two modules that never import each other, each declaring an interface spelled `Shape`
with a method `area`, mint two rows with the **same key**; `lookupPositions` (`:1905-1907`)
returns the **first** and stops. This is `AGENTS.md`'s thirteen-times shape, live, today.

`compiler/types/registry.mdk` already sizes the conversion and already says it is owed:
```
compiler/types/registry.mdk:161: --   | `ifaceDispatchRef`               | Ident × Ident            | eval.mdk      |
compiler/types/registry.mdk:175: -- are stated as A-2.0 sized them; the unit that converts each owes the same
```
⇒ **Phase 4's key work is a conversion the registry ledger already owes, not a new invention.**
Reuse `RegKey`/`regKeyN` rather than minting a spelling — and heed `registry.mdk:163-166`: a
parameter **SLOT is an ordinal, not a declaration**, so it belongs in `RegKey`'s second component
(`regKeyTabAt`), never faked as an `Ident`. The Phase 4 key is therefore
**`RegKey <iface-Ident> <slot>` × `HeadKey`** — literally `<iface-identity>@<slot>`, with the
head half already identity-bearing (§B.4).

### D.2 The required fixture — table PRESENT, assertion about code that does NOT use it

**Home: `test/eval_typed_modules_fixtures/`.** Justification, derived:

- It is **typed** and **multi-module**. Phase 4's table exists only post-K, which only the typed
  path reaches (§A.3); cross-module key collision is unobservable in a single file.
- ⚠️ **Consumer enumeration, word-bounded on both sides** (the shared-corpus trap):
  ```sh
  grep -rlE '(^|[^A-Za-z0-9_])eval_typed_modules_fixtures([^A-Za-z0-9_]|$)' test/ --include=*.sh
  # test/diff_compiler_eval_typed_modules.sh
  ```
  **EXACTLY ONE consumer.** The word-bounding is load-bearing: an unbounded `modules_fixtures`
  grep also matches the real sibling corpora `eval_modules_fixtures` (**4** consumers —
  `diff_compiler_eval_modules.sh`, `diff_compiler_core_ir_modules.sh`,
  `diff_compiler_check_cli_modules.sh`, `capture_goldens.sh`) and `llvm_fixtures_modules`.
- 🚨 **The corpus is FROZEN with NO regeneration script**, by the gate's own words
  (`test/diff_compiler_eval_typed_modules.sh:38-44`):
  > *"`sh test/capture_goldens.sh` is a NO-OP for this corpus … There is no regeneration script …
  > hand-derive the expected pp_value and write $golden yourself"*

  **For this fixture that is a feature.** `AGENTS.md`'s capture warning (*"a captured golden
  records what the engine did, not what is correct"*) is structurally enforced: you cannot
  capture, so you must derive.

**The fixture is a PAIR, not a directory.** One program is not fail-capable — "it printed 3" is
compatible with any keying. The control is what makes it a proof.

| dir | modules | `main` asserts on |
|---|---|---|
| `admis_scope_control/` | `shape.mdk` (`public export interface Shape` + method `area`, `impl Shape Circle`) · `plain.mdk` (a plain fn — no interface, no impl) · `main.mdk` importing both | `plain.step 7` — **a binding whose type mentions no interface at all** — and the `Shape` dispatch, and a prelude `map (+ 1) [1,2,3]` |
| `admis_scope_collide/` | the SAME three files **plus** `shape2.mdk`, a second **same-spelled** `interface Shape` with the same method name `area` and `impl Shape Square`, imported by `main.mdk` and referenced by neither `plain.mdk` nor the asserted expressions | the SAME three lines |

**The property:** the `plain.step 7` line, the `shape.mdk` dispatch line and the prelude line in
`admis_scope_collide/main.eval.golden` must be **byte-identical** to `admis_scope_control`'s.
A program-global bare-name key lets `shape2.mdk`'s row shadow `shape.mdk`'s at key
`("Shape","area")` and the dispatch line moves — **at exit 0, no diagnostic.** That is the S0
shape, made observable, and the control is what lets the fixture fail.

⚠️ **`admis_scope_collide` must first be a program that CHECKS.** Two same-spelled exported
interfaces reachable in one importer may already be a resolve-level reject at HEAD. If so the
fixture is unbuildable as written and the discriminator must instead put the two `Shape`
declarations in **sibling** modules — `main` importing one, a third module importing the other.
**I did not verify which; §F REFUSAL 5.** This is precisely the brief-for-refusal case: the
implementer must reduce it to a program that checks before writing any golden.

### D.3 What "prove" means here, operationally

`"It is keyed per-X"` is an assertion. The proof is **three** things, none sufficient alone:

1. **The type.** The frozen table's key carries an `Ident`/`RegKey` in the interface position.
   One line: `grep -n 'CAdmisTable' compiler/ir/core_ir.mdk` must show no bare `String` there.
2. **The comparator.** Every lookup goes through the identity comparator, never `==` on a name.
   `cohSameIface` (`compiler/types/typecheck.mdk:16343`) / `sameTyConHead` is the existing one.
   Tripwire, per AD-2 §4.2: `grep -rn 'CAdmisAbsent' --include=*.mdk compiler/` enumerates every
   arm as a **SET**.
3. **The fixture pair above**, whose control makes it fail-capable.

---

## E. THE BITE LIST

**Standing conditions for every bite below.** Phase 4 changes emitted IR ⇒ per the sprint
contract, goldens are blessed **zero times mid-run** and re-cut **once** at close-out. So from
bite 1 onward the following are **RED and expected to stay red until close-out**, and that must
be written into `DEBT.md` before bite 1 lands, not discovered at bite 4:

- `test/diff_compiler_snapshot_frontend.sh` (compiler family) — every `CProgram`-arity source moves
- `test/diff_compiler_selfproc.sh` — LEG A `types.typecheck.golden`, `eval.eval.golden`
- (only under Q2 = unconditional RENDER) `test/diff_compiler_snapshot_core_ir.sh` — 24 files

⚠️ `diff_compiler_selfproc` **phantom-skips** in a fresh worktree and `AGENTS.md` tells you to
dismiss phantom skips. **Do not, here** — it is the only local signal for the LEG A golden, and
it reds the CI `backend` shard. Build its three oracles per `AGENTS.md` before bite 3.

---

### Bite 0 — CLOSE THE `_ => None` ARM SET (Q7). **Precondition, not a sibling.**

> Apply "add the missing head-projection arms, as a SET" to these **4** named sites.

| # | site | today |
|---|---|---|
| 1 | `headTyconTy` | `compiler/types/typecheck.mdk:19452-19456` — 3 arms: `TyCon`, `TyTuple`, `_ => None` |
| 2 | `headTyconNameTy` | `compiler/types/typecheck.mdk:19479-…` — its own comment (`:19477`) says *"these three arms … must classify the same head nodes as the three above"* |
| 3 | `headTyconHead` | `compiler/eval/eval.mdk:1980-1982` — `headTyconHead (t::_) = headTycon t`; exported and imported by `compiler/ir/core_ir_lower.mdk:65` (verified) |
| 4 | `headTycon` | `compiler/eval/eval.mdk:513-519` |

⚠️ **Site 4 is NOT symmetric with site 1, and the asymmetry is the whole of #1618.** Derived:
```
513: headTycon : Ty -> Option String
514: headTycon (TyCon { tyConName = n }) = Some n
515: headTycon (TyApp a _) = headTycon a
516: headTycon (TyConstrained _ t) = headTycon t
517: headTycon (TyEffect _ _ t) = headTycon t
518: headTycon (TyTuple ts) = Some (tupleHeadTag (listLen ts))
519: headTycon _ = None
```
**eval's `headTycon` already STRIPS `TyConstrained` and `TyEffect`** (`:516-517`); typecheck's
`headTyconTy` (`:19452-19456`) has neither arm. That is exactly the divergence #1618 reports.
**Both still swallow `TyFun`** (#1617) through their `_` arms. ⇒ bite 0 adds **2 arms** to the
typecheck side and **1 arm** to the eval side — not the same edit at both, and a "mirror the
arms" instruction would be wrong.

**Why first:** the frozen table's head component is minted by `headTyconTy` at
`compiler/types/typecheck.mdk:19100`. Freezing a projection that answers `None` for `TyFun`
(#1617), `TyEffect` (#1618) and `TyConstrained` (unfiled) makes an under-discriminating table
**authoritative**.

- `could move:` LEG A `types.typecheck.golden`, `eval.eval.golden`; `test/snapshots/compiler/`
  for both files. Possibly `test/must_fail_fixtures/1617-*`/`1618-*` **flip green and RED the
  must-fail gate** — that is the tracker self-draining and is a GOOD failure.
- `nearest miss:` a head shape that is neither `TyCon`, `TyTuple`, `TyFun`, `TyEffect` nor
  `TyConstrained` — I did **not** enumerate `Ty`'s full constructor set, so this bite's
  "as a SET" claim is exactly the one Phase 3′'s retrospective says was shipped one arm short.
  **The implementer owes `grep -n '^data Ty' -A20 compiler/frontend/ast.mdk` before starting.**
- `engines:` typecheck + eval + (through the import) core_ir_lower. **Not** LLVM/wasm.
- `unchecked:` whether closing the arms *drains* #1617/#1618 or merely moves their shape.

---

### Bite 1 — INTRODUCE `CAdmis` AND THE 5th `CProgram` FIELD, ALL-ABSENT. Behaviour-neutral.

> Apply "add a 5th positional field, valued `CAdmisAbsent` at every construction and ignored at
> every destructure" to these **41** named sites (1 declaration + 11 destructures + 29
> constructions).

- **1 declaration:** `compiler/ir/core_ir.mdk:241-242`. ⚠️ two-line `data X =` header ⇒ AD-2
  §4.4's #829 `fmt --write` hazard. **Add the field bare; put the prose on the `CAdmis`
  declaration in `types/route_key.mdk` (per §B.5 option b), not inside the record.**
- **1 new type + its home:** `CAdmis = CAdmisAbsent | CAdmisTable <rows>` in
  `compiler/types/route_key.mdk`; add `import types.route_key` to `compiler/ir/core_ir.mdk`
  (acyclic — §B.5).
- **11 destructures** — the SET, from §A.2.1: `llvm_emit_modules_main.mdk:86` ·
  `core_ir_eval.mdk:401` · `core_ir_sexp.mdk:225` · `draft_semantic_program.mdk:313` ·
  `wasm_emit_typed_main.mdk:567` · `core_ir_lower.mdk:642` · `core_ir_lower.mdk:1001` ·
  `wasm_emit.mdk:1055` · `wasm_emit.mdk:1113` · `llvm_emit.mdk:10761` · `llvm_emit.mdk:11131`.
  ⚠️ AD-2 §5(3) is right that this is a **decision per site**, not a mechanical `_`. The two
  rewrite passes (`rewriteProgramRecPats`, `hoistNullaryMemo`) must **forward** the field, not
  drop it — dropping is how it silently becomes `CAdmisAbsent` mid-pipeline.
- **29 constructions** — the SET, from §A.2.2. 23 of them are in
  `compiler/entries/wasm_emit_typed_main.mdk`, a file with an active concurrent writer from
  #1403/X-W (§F REFUSAL 1).

**This bite is a compile-error-driven sweep: the constructor is arity-checked, so every missed
site is a build failure, not a silent miss.** That property is what makes it safe at 41 sites.

- `could move:` `test/snapshots/compiler/{core_ir,core_ir_lower,core_ir_eval,core_ir_sexp,core_ir_sexp_parse,llvm_emit,wasm_emit,draft_semantic_program,snapshot}.md`; `route_key.md`. **No behaviour golden should move** — if an `.eval.golden` moves, the bite is wrong.
- `nearest miss:` a program reaching `CProgram` through a path added between now and landing.
- `engines:` all three (every emitter destructures `CProgram`), but **behaviour-neutrally**.
- `unchecked:` the fixpoint / seed. A `CProgram` arity change is a compiler-source change and
  the emitter compiles itself — run `selfcompile_fixpoint.sh` backgrounded after this bite.

---

### Bite 2 — SERIALIZATION, per the §C ruling.

> Under the recommended arm 3: apply "render the 5th sub-list only when `faithfulRoutesRef.value`"
> to **1** site — `cprogramToSexp` (`compiler/ir/core_ir_sexp.mdk:224-232`) — and **0** sites in
> `parseCProgram`.

Under unconditional RENDER instead: 1 site in `cprogramToSexp` **plus** `parseCProgram`
(`core_ir_sexp_parse.mdk:379-382`) **plus** a 24-file golden re-cut.

- `could move:` arm 3 → nothing beyond bite 1's source snapshots. RENDER → +24
  `test/snapshots/eval_fixtures/*.md`.
- `nearest miss:` any future consumer of `cprogramToSexp` that does not set the flag and then
  believes the absence it reads. **Owed: a comment on `cprogramToSexp` saying the field is
  flag-gated** — the `faithfulRoutesRef` precedent already carries one at `:68`.
- `engines:` none (serialization only).
- `unchecked:` that the gated render is exercised by any gate. **It is not** (§C.5).

---

### Bite 3 — COMPUTE THE TABLE, POST-K, FROM `IE`, KEYED BY IDENTITY.

> Apply "fold `IE`'s rows into a `CAdmisTable` keyed by `RegKey <iface-Ident> <slot>` × `HeadKey`"
> at **1** new function, seeded at **1** existing site.

| # | site | change |
|---|---|---|
| 1 | new `buildAdmisTable : ImplEnv -> CAdmis` in `compiler/types/typecheck.mdk` | reads `ieRows`; iface identity from each row's `IfaceRef` (`irName` + `irOrigin`, `:5795-5796`); head from `headTyconTy` (`:19452`, post-bite-0); slot from the interface's own method signature — the computation `dispatchPositionsOf` (`compiler/eval/eval.mdk:522-523`) does today |
| 2 | `checkBodyImpl`, `compiler/types/typecheck.mdk:21281-21283` | after the `bodyImplEnvRef` seed, compute once and store in a new `perRun` field |
| 3 | the comparator | reuse `cohSameIface` (`:16343`) / `sameTyConHead`. **Do NOT write `a.irName == b.irName`.** |
| 4 | the fail-closed arm | a *miss* in a `CAdmisTable` means **NOT admissible**. `CAdmisAbsent` alone means "today's arg-tag behaviour". RUN-B-013 condition 1. |

⚠️ **The `OriginUnresolved` hazard (§B.3) is decided HERE and nowhere else.** On FLAT, user
interfaces carry `OriginUnresolved` (`compiler/types/typecheck.mdk:5814`,
`compiler/types/registry.mdk:170-173`). Treating `OriginUnresolved == OriginUnresolved` as "same
interface" re-collapses every FLAT interface into one bucket — reintroducing the bug in the fix.

- `could move:` LEG A `types.typecheck.golden` (**additive-only** — no existing binding's
  inferred type may change; if one did, the fix changed types);
  `test/snapshots/compiler/typecheck.md`.
- `nearest miss:` **a program that never reaches `checkBodyImpl`.** That is every loader-less
  verb (`check <single file>` on the Flat arm still reaches it; `lsp`/`repl`/`doc` — I did not
  verify). The table is *computed*, not yet *consumed*, so a miss here is inert until bite 5.
- `engines:` typecheck only. Behaviour-neutral by construction (nothing reads the table yet).
- `unchecked:` recomputation cost. `checkBodyImpl` runs **per module** on the Module arm, not
  once per program (§F REFUSAL 2, derived from `typecheck.mdk:3046`)
  — a naive fold over `ieRows` at each call is a new O(modules × rows). `check` is GC-bound;
  `compiler/AGENTS.md` names exactly this shape. **Memoize on `ieRows`' identity or hoist.**

---

### Bite 4 — CARRY THE TABLE FROM TYPECHECK TO LOWERING.

> Apply "add a `CAdmis` parameter and forward it" to these **4** named sites, then set the field
> at the **1** lowering construction that has a value to set.

| # | site |
|---|---|
| 1 | `lowerProgram` — `compiler/ir/core_ir_lower.mdk:526-533` (signature + the `CProgram` at `:529`) |
| 2 | `lowerProgramEmit` — `compiler/ir/core_ir_lower.mdk:555-559` (forward, one hop, no branch) |
| 3 | the 7 probe drivers + `compiler/tools/snapshot.mdk:568` — AD-2 §1.1's site set, **re-derived** at HEAD before the bite: `grep -rn 'lowerProgram\b' --include=*.mdk compiler/ \| grep -v lowerProgramEmit` |
| 4 | the typed drivers that HAVE a table (`elaborateOne`/`elaborateDict` callers) — supply it; every other caller supplies `CAdmisAbsent` |

🚨 **This is the bite most likely to be wrong, and it is wrong in the design, not the code.**
There is **no import edge** from `core_ir_lower` to `typecheck` (§B.5), and the tree's existing
mechanism for carrying a typecheck decision into lowering is **AST stamping**, not a table
parameter. AD-2 asserts "one hop, no branch" about the *signature* and is silent about the
*supply*. **Brief the implementer to refuse this bite if the supply path does not exist**, and
route it back to design rather than inventing a global ref.

**The supply gap, made concrete — the elaboration boundary returns DECLS ONLY:**
```
compiler/types/typecheck.mdk:14538:export elaborateOne     : List Decl -> List Decl -> (String, List Decl) -> List Decl
compiler/types/typecheck.mdk:14566:export elaborateDict    : List Decl -> List String -> List String -> List Decl -> List Decl
compiler/types/typecheck.mdk:28990:export elaborateModules : List Decl -> List Decl -> List (String, List Decl) -> (List Decl, List (String, List Decl))
```
and the typed drivers thread exactly that into lowering, e.g.
`compiler/entries/llvm_emit_typed_main.mdk:99` — `lowerProgramEmit (elaborateDict …)`,
`compiler/entries/wasm_emit_typed_main.mdk:111`, `compiler/entries/core_ir_typed_main.mdk:34`.
⇒ **there is no channel today for a non-`Decl` value to cross that seam.** Bite 4 must either
widen all three return types (touching every typed driver) or add an exported reader in
`route_key`/`registry` — a decision, not a mechanical edit.

- `could move:` `test/snapshots/compiler/{core_ir_lower,snapshot}.md` + every touched entry driver.
- `nearest miss:` `medaka snapshot` — a **user-facing verb** on the untyped path
  (`compiler/tools/snapshot.mdk:568`). AD-2 §1.2 is explicit that RUN-B-013's *"no user-facing
  verb reaches the untyped path"* is **FALSE of `lowerProgram`**. Do not repeat it in `DEBT.md`.
- `engines:` all three consume the lowered `CProgram`; none reads the field yet.
- `unchecked:` whether any driver silently supplies `CAdmisAbsent` where a table exists — which
  is exactly the fail-open regression this whole carrier design exists to prevent.

---

### Bite 5 — CONSUME IT, AND RETIRE THE TWO FAIL-OPEN DEFAULTS.

> Apply "read the frozen table instead of `lookupPositions`, and fail CLOSED on a miss" to these
> **6** named sites.

| # | site | today |
|---|---|---|
| 1 | `compiler/eval/eval.mdk:1976` | `let positions = lookupPositions ifaceName mname disp` (in `implMethodEntry`) |
| 2 | `compiler/ir/core_ir_lower.mdk:1409` | the same line in `lowerImplMethod` — **the lockstep twin** |
| 3 | `compiler/eval/eval.mdk:1904` | `lookupPositions _ _ [] = [0]` — 🚨 fails OPEN |
| 4 | `compiler/eval/eval.mdk:937-939` | `keepOrAll original [] = original` — 🚨 fails OPEN |
| 5 | `compiler/eval/eval.mdk:928-931` | `filterByTag … not (anyList isDispatching vs) = vs` |
| 6 | `compiler/eval/eval.mdk:934` | `filterByTagT vs None = vs` |

🚨 **Sites 1 and 2 are `AGENTS.md`'s named lockstep pair** (`evalModules`/`cevalModules` family:
*"a fix to one is silently absent from the other"*). They must move in **one** bite.

🚨 **Sites 3-6 are where behaviour actually changes, and this is the bite that can turn a
LOUD-or-lucky path into a QUIET wrong answer or vice versa.** Under `CAdmisTable`, a miss must
fail CLOSED; under `CAdmisAbsent`, today's behaviour must be preserved **exactly**. Getting that
backwards on the `CAdmisAbsent` arm regresses every untyped driver.

- `could move:` **behaviour goldens, for the first time.** `test/eval_fixtures/*.eval.golden`,
  `test/eval_dict_fixtures/`, `test/eval_modules_fixtures/` (**4 gates**, §D.2),
  `test/eval_typed_modules_fixtures/`, plus LLVM/wasm IR goldens if positions reach the emitters
  through `CImplTagged`. **Any golden that moves here needs its correct value hand-derived, not
  captured** — several of these corpora sit on known-wrong eval oracles (`AGENTS.md`: five open
  S0s).
- `nearest miss:` a method whose dispatch position is **result** or **phantom** (DICT §5) — no
  argument reveals the instance, so no admissibility verdict helps. Those must already route
  through the dictionary; this bite must not make them worse.
- `engines:` eval **and** native (through `core_ir_lower` → `CImplTagged`) **and** wasm.
  🚨 **Cross-engine agreement CANNOT grade this** — all three read the same lowered positions.
  The instrument is `test/diff_compiler_import_order.sh` (a permutation differential), and per
  the sprint doc's Q4 it **has no wasm arm** (`grep -ni wasm test/diff_compiler_import_order.sh`
  — the doc reports one hit, a comment; **re-run it, do not quote it**).
- `unchecked:` perf. `filterByTag` is on the eval hot path.

---

### Bite 6 — THE SCOPING FIXTURE PAIR (§D.2).

> Apply "add a control/collide fixture pair with hand-derived goldens" to **1** corpus directory
> with **1** consumer gate: `test/eval_typed_modules_fixtures/` →
> `test/diff_compiler_eval_typed_modules.sh`.

Lands **after** bite 5 (before it, the assertion is vacuous — the table is not consumed).

- `could move:` nothing existing; it is additive. ⚠️ But **adding a directory to a shared
  corpus enrolls you in its gates** — here, exactly one, re-verified word-bounded at the moment
  of the bite.
- `nearest miss:` a collision between an interface in the **prelude** and a user interface. The
  fixture pair covers user↔user. `AGENTS.md`'s *"ask does it touch the prelude"* applies.
- `engines:` eval (typed multi-module driver) only. **The same shape is ungraded on native and
  wasm** — say so in `DEBT.md` rather than implying the fixture covers three engines.
- `unchecked:` that `admis_scope_collide` is a program that checks at all (§F REFUSAL 5).

---

### Landing order and what is red when

```
0 (arms)  →  1 (field, all-absent)  →  2 (serialize)  →  3 (compute)  →  4 (carry)  →  5 (consume)  →  6 (fixture)
            └─────────── source snapshots + LEG A RED from here to close-out ──────────┘
                                                                    └─ behaviour goldens RED from here ─┘
```

Bites 0-4 are **behaviour-neutral**; only bite 5 changes an answer. That is deliberate: it puts
the entire attribution burden on one bite, which is what makes a mid-run red readable.

---

## F. REFUSALS

**REFUSAL 1 — `CProgram`'s construction-site count has a shelf life of days, and I will not
hand you a number to plan against.** I derived **29** at `aaa43716`; AD-2 derived **13** at
`68f84bf1`. **23 of the 29 are in `compiler/entries/wasm_emit_typed_main.mdk`**, created by PR
#1623 ("Tracks #1407", the X-W arc) hours before the sprint doc was written, and the sprint doc
itself (§2b) names that file as having a **live concurrent writer from another arc**. Bite 1
touches all 29. **Re-derive immediately before cutting bite 1, and expect a merge conflict in
that one file.** Do not cite 29 in a PR body without re-running the two commands in §A.2.2.

**REFUSAL 2 — I cannot size bite 3's cost, because "post-K" lands inside a function that runs
PER MODULE, not once.** `checkBodyImpl` (`compiler/types/typecheck.mdk:21069`) is where `IE` is
seated (`:21281-21283`), and the file says so in its own prose:
`compiler/types/typecheck.mdk:3046` — *"`loadDataUniverse` at the top of **every module's**
`checkBodyImpl` Module arm"*; `:1798` — *"its one call site is in `checkBodyImpl`, shared by
Flat and Module"*. Phase 4's charter says *"computed ONCE, post-K"*. **Those two facts are in
tension and I could not resolve it statically** — resolving it needs `checkBodyImpl`'s call
graph and a measurement, and I am forbidden both. Since it is at least per-module, a naive fold is a new O(modules × rows) on the **GC-bound**
`check` stage, which is the exact shape `compiler/AGENTS.md` says thirteen quadratics took.
**This is a blocking design question, not a note.**

**REFUSAL 3 — I did not verify `sameTyConHead`'s `OriginUnresolved` arm.** §B.3 and bite 3 both
rest on reusing it as the identity comparator. Whether it treats two `OriginUnresolved`
interfaces as the same or as distinct decides whether the FLAT path collapses. **Derive it
before bite 3:** `grep -n '^sameTyConHead' -A15 compiler/types/typecheck.mdk`.

**REFUSAL 4 — I did not derive whether a golden family driven by
`core_ir_typed_modules_dump_main` exists.** §C.5's arm-3 recommendation carries the honest cost
that a gated render is exercised by no gate. If you want it graded, that gap must be sized
first; I have not sized it.

**REFUSAL 5 — I did not verify that the `admis_scope_collide` fixture is a legal program.** Two
same-spelled exported interfaces reachable in one importer may be a resolve-level reject at
HEAD. Verifying needs a binary. The implementer must reduce it to a checking program before
writing a golden, and is licensed to change the module topology (§D.2) to get one.

**REFUSAL 6 — bite 0's "as a SET" claim is not yet a set.** I proved `headTyconTy` has three
arms and that `TyFun`/`TyEffect`/`TyConstrained` fall through `_ => None`. I did **not**
enumerate `Ty`'s full constructor list, so I cannot say those three are all that fall through.
Phase 3′'s own retrospective records *"I wrote 'audit the arms as a SET' and then shipped a set
one arm short."* **`grep -n '^data Ty' -A25 compiler/frontend/ast.mdk` before bite 0.**

**REFUSAL 7 — I am not ruling Q2. I am recommending arm 3 and showing the derivation.** The
call is the owner's, and it turns on one thing I flagged rather than resolved: whether the
sprint accepts an ungraded debug-only render (§C.5's last paragraph).

---

### Corrections this document makes to the record

| claim | source | status at `aaa43716` |
|---|---|---|
| *"`CProgram` is constructed at 13 sites"* | AD-2 §3.1 | 🔴 **29.** The delta is `wasm_emit_typed_main.mdk` (8 → 23) |
| *"either spelling costs the same 24 sites"* | AD-2 §3.1 | 🔴 **40** (11 destructures + 29 constructions) |
| *"a non-round-tripped field silently becomes `CAdmisAbsent` after a round trip"* | AD-2 §5(2), sprint §4 Q2 | 🔴 **Does not reproduce.** `parseCProgram` has ONE consumer and it is on the untyped path — `CAdmisAbsent → CAdmisAbsent` |
| *"the interface-keyed peer ALREADY EXISTS … the tree already states it is immune"* | sprint §2b derivation 2 | 🔴 **True for method-name collisions (#1182/#1620), FALSE for interface IDENTITY (#1619).** `ieEntriesForIface` filters `ir.irName == iface` — a bare SPELLING (`typecheck.mdk:19121-19122`) |
| *"the substitution is one line given an interface; obtaining one may not be"* | sprint §2b residual 1 | ⚠️ **Understated.** An interface NAME is in hand at every site; an interface IDENTITY at none. It is a `String → IfaceRef` signature change, not a substitution |
| `eval.mdk:1934` = `lookupPositions _ _ [] = [0]` | AD-2 §2, RUN-B-013 | 🔴 **`:1904`** at HEAD (−30 drift) |
| `eval.mdk:967-969` = `keepOrAll` | AD-2 §2, RUN-B-013 | 🔴 **`:937-939`** at HEAD |
| `lowerProgramEmit` at `core_ir_lower.mdk:551-555` | AD-2 §1.3 | 🔴 **`:555-559`** (+4). Claim survives verbatim |
| Q7 (`_ => None` arm set) is *"derive whether it is a precondition or an independent unit"* | sprint §4 Q7 | ✅ **PRECONDITION** — grep-proven at `typecheck.mdk:19452-19456`; the frozen key's head comes from that projection (`:19100`) |
| — | — | 🟢 **New, not in any prior document:** the head half of the key is ALREADY identity-bearing (`headKeyOfCon o n`, `:19454`). Only the interface half is bare |
| — | — | 🟢 **New:** `typecheck.mdk` has no `ir.core_ir` edge and `core_ir_lower.mdk` no `types.typecheck` edge; `types/route_key.mdk` is the shared acyclic home (§B.5) |
| — | — | 🟢 **New:** arg-tag admissibility is not in `compiler/types/` at all today; Phase 4 is a RELOCATION, not a re-key (§A.0) |

