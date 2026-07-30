# Typechecker target architecture — per-bug fit ledger

**Status:** CURRENT — one row per open `verified` `ws:typecheck` S0/S1 bug, adjudicated
against [`TYPECHECK-TARGET-ARCHITECTURE.md`](TYPECHECK-TARGET-ARCHITECTURE.md) (the design)
and epic #1122 (the stage table). Derived first-hand from `compiler/**/*.mdk` at
`13b9fafe` (2026-07-30). Extends §4's traceability matrix from *families* to
*individual bugs*, and states a falsifiable prediction for every DRAINED-BY verdict so
each row is **gradeable the day its stage merges**. The design document is the
authority; nothing here amends it — the proposed changes in the GAP sections are
proposals for the orchestrator.

> **The burden of proof here is inverted.** "The plan covers this" is the claim that
> needs a mechanism plus a prediction; "this is a gap" is the cheap answer. A row with
> no stateable mechanism is `NOT ESTABLISHED`, not "probably fine" — retiring a live
> bug into a stage that does not actually reach it is the expensive failure this
> ledger exists to prevent.

---

## Summary

| Bug | Verdict | Stage / owner |
|---|---|---|
| #817 Async method-effect-var ≡ container row | **GAP (ownership)** — explicitly deferred to peer arc #820–#824, whose own coverage rules are open S0s | peer arc; see G-3 |
| #819 impl body pins an impl-HEAD type var | **GAP** — matrix lists it "(adjacent)"; no design element removes it | none; see G-1 |
| #825 deferred callback under a pure stored arrow | **GAP (ownership)** — same as #817 | peer arc; see G-3 |
| #1040 `where`-local method helper at two types | DRAINED-BY **F-1** (#1082) | F |
| #1043 block-`let` local method helper | DRAINED-BY **F-1** (typecheck half) · ENGINE-REALIZATION (emitter half) — with a scoping caveat, G-2 | F |
| #1052 local-dict pin merges two rigid sig vars | DRAINED-BY **F-1** (#1082) | F |
| #1069 `dataParamKindsRef` bare-type-name collision | DRAINED-BY **A-1 → A-2** (#1110/#1111) | A |
| #1070 umbrella: 7 of 15 `universe*` tables collide | DRAINED-BY **A-1 → A-2 → A-3** | A |
| #1092 `methodIfaceParamsRef` bare-method-name collision | DRAINED-BY **A-1 → A-2**, with a key-precision refinement (G-4) | A |
| #1095 result-index occurrence discharges coverage | **GAP (ownership)** — D-3 defers to #823, #823's record defers to soundness-not-an-issue | D-3 / #823; see G-3 |
| #1098 `Ref`/`MutArray`/`HashMap` widening launder | DRAINED-BY **D-2** (#1119) | D |
| #1100 abstract-head row arg never collected | DRAINED-BY **D-3** (unconditional half) | D |
| #1103 `unifyRowN` same-tail prefix discard | DRAINED-BY **D-1** (#1118) | D |
| #1121 contravariant Type parameter widens | DRAINED-BY **D-2** (#1119) | D |
| #1125 eval loses a `requires` dict under overlap | DRAINED-BY **B-1 + B-2** (both required) — and it re-prices B-1's owed #323 scope decision | B |
| #1127 superclass-projected dict picks the general instance | DRAINED-BY **B-1 + B-2** (hypothesis CONFIRMED) — **plus GAP G-5** (`activeDictVars` keying is in neither task's blast list) | B + G-5 |
| #1128 `impl C a` beside a concrete parametric-head impl | **GAP** — B-2 covers half; nothing makes the candidate set complete. **NOT** engine-realization (hypothesis disproved) | B-2 + new law; see G-6 |

**Exclusion re-audit** (§4's engine-realization list): #1034 ✅ holds · #826 ✅ holds ·
#1101 ✅ holds · #1043-emitter-half ✅ holds · **#1020 ⚠️ partially misclassified** —
see G-7. All five, plus #1101, additionally share an uncovered **L1** class defect (G-8).

---

## What the gaps have in common — read this before the rows

Seven gaps. **Every one of them is a completeness gap, not a keying gap**, and the
design has no law that covers completeness.

The five laws in §1 are all properties of *how a decision is made and carried*:
L1 one implementation · L2 identity not spelling · L3 order specified-or-irrelevant ·
L4 evidence structured and uniform · L5 the spec is executable. Together they make the
*decision* unambiguous. **None of them says anything about whether the decision's
INPUTS, or the engines' INPUTS, are complete.** And that is exactly where the residue
sits:

- **#1128** — the fully-general `impl Tag a` produces **no registry entry at all**
  (`keyEntryOf` → `headTyconTy (TyVar _)` → `None` → `[]`). A perfect `min⊑` selector
  over an incomplete candidate set still returns the wrong instance.
- **#1020** — a cross-module impl that overrides only defaults produces **no lowered
  entry at all** (`lowerDeclImpl` emits one entry per method *defined*;
  `fillImplDefaults` is same-module only). Each engine then re-synthesizes the missing
  arm privately, and wasm forgot to.
- **#1127** — the super slot exists but carries **no distinguishing key**
  (`activeDictVars : Ref (List (Int, String))` — tyvar id only, no interface
  component), so the body's `D a` goal cannot name its own dict.
- **#1034 / #826 / #1101** — the elaboration output carries routes and dicts but **not
  arity**, so three consumers derive it three ways and two of them disagree.

Contrast the *keying* problems (#1069/#1070/#1092/#1072): those are exactly what
Stage A is built for, and the plan handles them cleanly. The plan is a plan about keys.

There is a second, smaller shape worth naming because the design document itself fell
into it: **three bugs (#819, #1095, and #817/#825) are placed in a family by TOPIC and
then the family's design element does not reach them.** #819 sits in family G whose
element is "W3 rigid everywhere" — but W3 exempts impl-head variables *by construction*,
so the element is structurally incapable of draining it. That is the same
pattern-match-onto-a-plausible-stage failure this ledger's own instructions warn
against, committed once inside the matrix.

### Proposed plan change (the one that subsumes four gaps)

Add a sixth law and give it a stage:

> **L6 — Elaboration output is total.** Every instance in `IE` carries its **complete**
> method table (interface defaults resolved whole-graph, not per-module and not
> per-engine); every candidate set consulted by `min⊑` contains **every declared
> instance**, including heads with no head tycon; and every fact an engine needs —
> route, evidence reference, admissibility predicate, **and arity / calling
> convention** — is present in the elaboration output rather than re-derived by the
> engine from a partial view. An engine that must *supply* something the elaboration
> omitted has forked the judgment exactly as surely as one that *recomputes* something
> the elaboration provided (L1's dual).

L6 is the dual of L1 and it is the missing half: L1 forbids re-deriving what was
decided; L6 forbids *not deciding* something an engine then has to invent. Concretely
it makes A-3 (K) own instance method-table completion, makes B-2 own candidate-set
completeness, and gives #1034/#826/#1101's class an owner for the first time.

---

## Family A — identity / bare-name registries

### #1069 — `dataParamKindsRef` bare-type-name collision · **DRAINED-BY A-1 → A-2**

**Mechanism (verified).** `dataParamKindsRef : Ref (List (String, List Kind))`
(`compiler/types/typecheck.mdk:3113`) and its carrier
`universeDataParamKinds : Ref (List (String, List Kind))` (`:2536`) are keyed by the bare
type name; readers are `lookupAssoc n perRun.value.dataParamKindsRef.value` first-match
(`:1240`, `:4135`, `:4289`, `:7977`). The source states the hazard itself at `:17048`:

> `⚠️ dataParamKindsRef is keyed by BARE NAME across the whole import graph, so two
> same-named types in different modules already share a key`

#1070 records that this table is one of the **five** whose per-table re-keying is
*impossible* — the read sites hold only a bare head-tycon `String` recovered from `Mono`,
because `TCon` itself is bare, so there is no module identity available at the lookup.

**Why the plan removes the cause.** L2 lands the fix at the substrate, not at the table:
A-1 (#1110) gives `TyCon`/`TCon` references a resolve-assigned `(originModule, name)`
identity, so the two modules' `Box` are no longer the same `Mono`; A-2 (#1111) then
re-keys the surviving `universe*` tables by that identity and lands the write-once-or-
diagnose registry ratchet, under which a bare-`String` key fails the structural check.
The collapse #1070 describes ("both modules' `Cfg` are the same `Mono`") is precisely
what A-1 undoes.

**Falsifiable prediction.** When **A-1 + A-2** land, #1069's three-file repro
(`apub.mdk` `data Box e a`, `zopapub.mdk` `data Box p q` + `zf`, entry importing only
`zopapub.{zf}`) must change from `check` printing `v : Box Unit Int` (row erased, exit 0)
to `v : Box <Stdout> Int` — byte-identical to the control with `zopapub.mdk` deleted.
A-1 alone is **not** sufficient and must not close this: identity has to reach the
*table key*, which is A-2.

⚠️ Guard when pinning: the repro is silent **only at matching arity** — every hot reader
guards on `listLen kinds == listLen args` (`:1424`, `:4289`), so a same-name/different-
arity clash abstains loudly and a naive pin is immune to the defect it means to catch.

---

### #1092 — `methodIfaceParamsRef` bare-method-name collision · **DRAINED-BY A-1 → A-2** (with G-4)

**Mechanism (verified).** `methodIfaceParamsRef : Ref (OrdMap (String, List String, Ty,
List (String, List Kind)))` (`:3124`) is keyed by the bare **method** name;
`registerMethodIfaceParamsMethods` (`:15335`) does
`omInsert mname (iface, typarams, mty, scope)` — last-write-wins across the whole loaded
program. The source's own comment at `:15332` concedes it:

> This entry is method-NAME-keyed last-write-wins, an exposure it already had … The
> underlying bare-name interface identity is #1047's territory

`ifaceParamMonos` (`:10115`) and the entailment it feeds read that table by bare method
name, so the interface an obligation is *checked against* is decoupled from the interface
the occurrence *resolved to* — which is why #1092's 24-cell matrix shows the verdict
tracking import order and nothing else.

**Why the plan removes the cause.** R (resolve identity) resolves interface-method
occurrences to a qualified identity (§2 R lists "interfaces, interface methods"
explicitly), and `marker.mdk` already rewrites method `EVar`→`EMethodRef` so there is an
existing seam to carry it. A-2 then keys the method table by that identity, and the
reader consults the identity the *occurrence* carries rather than a name.

**Falsifiable prediction.** When **A-2** lands, #1092's flagship cell
(`same_implA_ba_namedb`: `import ifaceb.{IB, mth}` + `import ifacea.{IA}`, `Blob`
implementing only `IA`) must change from `check` exit 0 / `run` printing `1` to
`check` exit 1 with `No impl of IB for Blob`; and the false-reject mirror
(`same_implA_ab_nameda`) must change from exit 1 to exit 0. **All 24 cells must become
insensitive to the `order` axis** — that, not any single cell, is the gradeable
assertion, because `order` is the axis #1092 proved is the only one that moves the
outcome.

**Refinement owed — see G-4.** `(module, name)` is not a sufficient key here.

---

### #1070 — umbrella, 7 of 15 `universe*` tables · **DRAINED-BY A-1 → A-2 → A-3**

**Mechanism (verified).** The structural root #1070 names is real:
`private_mangle.mdk` renames only functions and constructors, so type / alias /
interface names are never module-qualified on either path, and `publicDataDecls` then
carries public `DData`/`DTypeAlias`/`DInterface` across module boundaries into bare-name
tables. Five of the seven confirmed rows are re-keyable only after identity reaches
`TCon`.

**Why the plan removes the cause.** This is the family the arc was built around — §4
family A maps it to "L2/R qualified identity substrate; K identity-keyed environments;
registry ratchet". A-2's issue (#1111) already states it "**updates #1070's body**":
its priority-1 remedy (reject duplicate public names at the declaration) is
**superseded** by the decided use-site-ambiguity model, per §5's "Kept, explicitly" list.
A-3 (#1112) then replaces the tables themselves with K's environments, and §2's registry
ratchet — covering `CrossRun` fields, `PerRun`/`DriverState`/loose refs, **and the
engine-side frame tables** — is what closes the "owed gate" (row K of the matrix).

**Falsifiable prediction.** When **A-2** lands, each of the seven confirmed rows must have
either (a) a passing fixture derived from the repro in #1070's body, or (b) an explicit
reclassification in this ledger. Specifically: the `universeAliasTable` repro
(`amod.type T = Int` / `zmod.type T = Float` + `zf`; entry imports only `zmod.{zf}`) must
change from `check → v : Float`, `run → 42.0` to `v : Int` / `42`. The umbrella closes
only when **all** rows are drained or reclassified — not when the first one is.

⚠️ Two rows to hold to a higher bar: `universeRecordByName` and `universeDataEnv` were
audit-verified but **not** independently re-run by #1070's author, and `universeRecordByName`
is claimed to produce a check-vs-build divergence that no gate has ever observed. Those
two need first-hand reproduction before A-2 can claim them.

---

## Family B — dispatch key under-discriminates

### #1127 — superclass-projected dict selects the general instance · **DRAINED-BY B-1 + B-2** · **plus GAP G-5**

**The hypothesis handed to me was that this is a direct B-1 hit. It is — and the
mechanism is sharper than "supers are flattened".**

**Mechanism (verified, three legs).**

1. **The flatten's stated premise is false under overlap.** `expandSupersTable`
   (`compiler/types/typecheck.mdk:5037`) appends one dict slot per transitive
   superinterface, and its own header (`:5027-5029`) justifies not projecting:

   > Because the dict VALUE is just a type tag (VDict "Widget"), the super slot's route
   > is identical to the sub slot's — no separate projection is needed; the slot just
   > has to EXIST so the call site applies a matching dict and the def binds a matching
   > param.

   That holds only when the sub-goal and the super-goal resolve to instances with the
   same tag. In #1127 the sub goal is `C (List Int)` (one impl) and the super goal is
   `D (List Int)` (**two** impls, `D (List a)` and `D (List Int)`, sharing head `List`).
   Identical routes are then wrong by construction.

2. **The `assum` rung cannot tell the two slots apart.**
   `activeDictVars : Ref (List (Int, String))` (`:3139`) is keyed by **tyvar id alone**;
   `activeDictVarOf` (`:10243`) is `lookupAssocI (tyvarId cell) …` first-match and
   `firstDictForEncl` (`:10268`) adds only a `$dict_<encl>_` name-prefix filter. Because
   `expandSupersFix` gives the appended super slot **the same tyvar id** as its sub slot
   (`:5025-5026`: "`Sub a`/`Sup a` share `a`, so the super id == the sub id"), the body's
   `dm x` goal on `a` resolves to whichever slot is found first — with no interface
   component anywhere in the key.

3. **Both engines then re-derive the instance from a bare head tag, differently.**
   `emitDispatchArm` (`llvm_emit.mdk:5304`) matches `headTag` against
   `implEntryRouteWords` in declaration order; eval scores candidates by
   `tyvarsInArgs typeArgs` (`eval.mdk:1881`) and so happens to prefer `D (List Int)`.
   That is L1's "consume, never re-derive" violated on both sides — which is why one
   engine is right and one is wrong on a program whose front end is shared.

**Why the plan removes the cause.** B-1 (#993) replaces the flatten with a distinguished
`supers` component and a real `entailSuper` **projection** rung, so leg 1 and leg 2 both
disappear: there is no appended sibling slot to mis-address. B-2 (#1113) makes routes
carry evidence references (`InstId` | `DictParam k` | `SupersPath`) stamped wherever
`inst` runs, and retires `implEntryRouteWords`' superset-OR arm, so leg 3 disappears:
engines project and apply, never select.

**Falsifiable prediction.** When **B-1 and B-2 have both landed**, #1127's repro must
print `77` from the built binary (today: `20`), matching `medaka run`, and the
one-token control (`useD : D a =>` instead of `C a =>`) must stay `77`/`77`. The fixture
`test/dict_fixtures/s6-1-4-*` goes red the day it is fixed, naming this issue.
**B-1 alone must NOT close this** — if #1127 is claimed drained after B-1 without B-2,
re-run the repro before believing it: leg 3 is independently sufficient to keep it wrong.

**GAP G-5 rides on this row — see below.**

---

### #1125 — eval loses a `requires`-bearing winner's dict under overlap · **DRAINED-BY B-1 + B-2**

**Mechanism (derived from the issue's own matrix + grep, not assumed).** #1125's
three-cell matrix is the discriminator: eval fails **only** when an overlapping sibling
exists *and* the `min⊑` winner carries a `requires`. Drop either and eval is correct.
Exactly one mechanism in the pipeline toggles on "does an overlapping sibling exist",
and it changes the **route payload**: `keyForSite` (`:11386`)

```
keyForSite table name goals = match matchedEntry table name goals
  Some (KeyEntry _ tag _ key _ _ _) => if headCollides table name tag then Some key else None
```

with the registry's own header (`:11331-11337`) stating the design:

> The route normally keeps the bare head tycon … it is UPGRADED to the full canonical
> key ONLY when two impls share that head tycon for the method

So the route for `Speak (Box (List a)) requires Tag a` is a **bare tag `Box`** when the
general sibling is absent and a **canonical key `Speak|(Box (List a))|`** when it is
present. The route representation is bimodal, gated on head collision, and the eval arm
loses the recursively-discharged `Tag Int` dict in exactly one of the two modes.

**Why the plan removes the cause.** B-2 deletes the bimodality outright: *every* goal
that reaches `inst` stamps an evidence reference (`InstId`), unconditionally — there is
no "keep the bare tag when there is no collision" branch left to be the second mode.
B-1 supplies the other half: instance context captured at construction in the evidence
tree, so the winner's `requires` travels with the evidence rather than being re-attached
per engine.

**Falsifiable prediction.** When **B-1 + B-2** land, #1125's repro must print
`specific:INT` under `medaka run` (today: `runtime error [E-PANIC]: putStrLn: not a
String`), matching the native arm, and all three matrix rows must read
`eval == native`. **If it still panics after both stages**, the residual is
engine-realization in eval's `dictOfRoute`/`narrowMethod` and must be re-filed as such
rather than kept on this row.

**Input the plan does not yet have.** §6 B-1 leaves a scope decision owed — *"whether the
tree extends to recursive instance-context capture at nesting depth ≥2 (what #323 needs)
or stays supers-scoped as filed"* — and §4 marks #323 `◇B-1-scope` on the strength of
#323 being an "exotic corner, no realistic shipping surface". **#1125 re-prices that
decision.** Its repro is single-level nesting with 2-way overlap: `impl C (Box a)` plus
`impl C (Box (List a)) requires D a` is idiomatic. If B-1's design doc decides
"supers-scoped as filed" on the grounds that instance-context capture only matters at
depth ≥2, it will be deciding against evidence that arrived after the plan was written.
⚠️ #1125's own body is explicit that its identity with #323 is a **hypothesis, not a
verified claim** — so the input is "an idiomatic shape needs recursive context capture",
not "#1125 and #323 are one bug".

---

### #1128 — fully-general `impl C a` beside a concrete parametric-head impl · **GAP (G-6)**

**The hypothesis handed to me was that this may be engine-realization. It is not.
Disproved below.**

**Mechanism (verified — and it is upstream of the mangled symbol).** #1128 reads the
mangled symbol off the emitted IR (`@mdk_impl_Box_tag` called at all three sites, the
general impl emitted as `@mdk_impl___none___tag` and never called) and concludes the
decision is at elaboration. That is right, but the cause is one step earlier still:

- `keyEntryOf` (`:11362`) emits a `KeyEntry` **only** when `headTyconTy headTy` is
  `Some`; `headTyconTy` (`:11632`) has arms for `TyCon` / `TyApp` / `TyTuple` and falls
  to `headTyconTy _ = None` for a `TyVar`. `implEntryFromTys` (`:11318`) and
  `implHeadTagForIface` (`:12071`) gate identically.
- Therefore **`impl Tag a` produces no entry in `KeyBuckets`, no entry in `ImplBuckets`,
  and no head tag in `implHeadTagsForIface` — it is invisible to every selector the
  typechecker has.** `matchingEntries` (`:11427`) then scans only the bucket at
  `goalHeadCon goals` = `Box`, and `keyForSite` returns `None`, so the caller keeps the
  fallback `tag`: `let routeKey = fromOption tag (keyForSite keyTable name paramMonos)`
  (`:11950`, `:11981`). The route is `RKey "Box"` — the *receiver's* head tycon, which
  happens to name the concrete impl's symbol.
- Downstream, `headTycon (TyApp a _) = headTycon a` (`eval.mdk:488`) drops the type
  arguments, so `Box Int` and `Box String` are the same tag. That is the *rendering*
  step #1128 observed, but it is faithfully rendering a route the typechecker chose.

**Why this is not engine-realization.** An engine-realization defect is one no stage can
drain because the information is unrecoverable (as with #1034's `methodArgTys`
over-count, where `a -> (Unit -> Unit)` and `a -> Unit -> Unit` are the same `Ty`). Here
the information is present and discarded: the goal is `Tag (Box String)`, the instance
`Tag a` is declared in the same file, and `min⊑` over `{Tag a}` is a one-line
computation. Nothing is lost; a candidate is simply never collected.

**Why B-2 covers only half.** B-2 (#1113) fixes the route-representation half: routes
carry `InstId` rather than a head tag, so once the right instance is selected it cannot
be re-derived away. But B-2's own text presupposes the selector sees the instance — *"every
goal that reaches `inst` goes through the one `min⊑` selector"*. **Nothing in §2 K, §2 S,
or §6 A-3/B-2 states that the candidate set must contain instances whose head has no head
tycon.** §2 K describes IE's *content* ("every impl with its full head, context, and
method table") but not its *indexing*, and §8's perf risk pushes hard toward keeping
head-tycon bucketing (the hot maps are `Map String`, the +56% lesson). If A-3
re-implements IE as "the same buckets, identity-keyed" — the natural reading — **#1128
survives Stage A and Stage B untouched**, because `impl Tag a` still has no bucket.

**Proposed plan change.** Make candidate-set completeness a stated law of K's IE, in
A-3's issue (#1112) and B-2's (#1113):

> IE's candidate collection for a goal `C τ̄` is `bucket(headTycon τ₀) ∪ general`, where
> `general` holds every instance whose head-0 is a bare type variable. A goal's candidate
> set is never a proper subset of the matching instances. Any bucketing is an index over
> a total set, never a filter on it — the same discipline C4 already requires of import
> scoping ("visibility filter, never a candidacy filter").

This is small, it is measurable (one extra list union per goal, over a bucket that is
empty in every program in the tree today), and it is a precondition for B-2's frozen
arg-tag admissibility to mean anything: "every constructor reachable at that position
must map to exactly one `min⊑` winner" is computed against the same candidate set, so an
incomplete set yields a *confidently wrong* admissibility verdict frozen into the
elaboration output and consumed by every engine — strictly worse than today.

**Falsifiable prediction (conditional on the change above being adopted).** With A-3's IE
carrying a general bucket **and** B-2's `InstId` routes, #1128's repro must print
`99` / `10` / `10` on both engines (today: `99` / `99` / `99`), and the one-token control
(`impl Tag (Box a)`) must stay `99` / `10` / `10`. **Without the change, the prediction is
that the repro is unaffected by the entire arc** — that is the gradeable claim, and it is
the reason this row is filed as GAP rather than DRAINED-BY.

---

## Family C — locals not dict-abstracted

### #1040 — `where`-local helper at two types · **DRAINED-BY F-1** (#1082)

**Mechanism (verified).** `dict_pass` prepends `$dict_…` parameters to top-level defs and
impl methods only; the source states it at `:8893`:

> A local binding is NOT dict-abstracted — dict_pass prepends `$dict_…` params to
> top-level defs and impl methods only, never to a `where`/`let` member

`methodConstrainedIds` (`:8852`) exists to *decline* the generalization instead, and is
consumed at one site inside `generalizeGroup` (`:8791`, `:9308`). With the binding
generalized, each use site instantiates a fresh variable, the method route falls to
`RNone`, and the emitter degrades to arg-tag — first impl group wins for both sites.

**Why the plan removes the cause.** L4 makes evidence uniform at *every* binder:
§2 E states `gen`/`gen-rec`/`gen-sig` apply to "top-level bindings, impl methods, default
methods …, **and local bindings** (#1082)", and §4 family C names the structural cause
exactly ("`gen` applied at only two binder kinds"). Under F-1 the helper `d` gets its own
dict parameter and is routed per use site, so there is no fresh-variable-with-no-route
state to degrade from.

**Falsifiable prediction.** When **F-1** lands, `top = d (1 : Int) ++ d True where d v =
debug v` must print `1True` from the built binary (today: `11`, exit 0) and from
`medaka run` (today: `E-PANIC: intToString: not an Int`). All three engines must agree.

**Sequencing note, not a gap.** F-1 sits at the end of the spine (after C-1, E-2, and
S-2(f)). #1040, #1043 and #1052 stay live for the whole arc; the `must_fail` pins owed on
all three are what keep them visible.

---

### #1043 — block-`let` local helper cannot be built · **DRAINED-BY F-1** (typecheck half) · **ENGINE-REALIZATION** (emitter half) · caveat G-2

**Mechanism (verified).** Same root as #1040, different entry point. `methodConstrainedIds`
is reached only via `processLetGroup` ← `inferLetGroup`; the sibling local-binding paths
`blockLet` (`:5209`), `blockRecLet` (`:5189`), `inferRecLet` (`:7819`) and `inferLetBody`
(`:7901`) never consult it. The emitter then panics in `emitArgDispatchChain`
(`llvm_emit.mdk:5532`) with the message at `:5553`:
`"arg-tag dispatch on impl type that owns no constructors (primitive receiver carries no
cell tag)"` — which #1043 proves misdirects (a constructor-bearing ADT panics identically).

**Why the plan removes the typecheck cause.** Same as #1040: under F-1 the block-`let`
binder is dict-abstracted, the route resolves, and arg-tag is never reached.

**Emitter half stays excluded, correctly.** The unlocated, uncoded, wrong-cause `E-PANIC`
is an emitter diagnostic defect; §4's exclusion of "#1043's emitter half" holds, and the
absence of `medaka build --json` keeps it structurally unreachable to a `Diag` consumer.
That half needs an engine fix regardless of this arc.

**Caveat — see G-2.** F-1's deliverable must be stated over the *set* of local-binding
inference paths, or #1040 drains and #1043 does not.

---

### #1052 — the local-dict pin is itself unsound · **DRAINED-BY F-1** (#1082)

**Mechanism (verified from the issue's IR dump).** The pin declines generalization,
monomorphising the `where`-local `d`, which merges the two **declared, rigid** signature
variables `a` and `b` of `useTwo : (Sized a, Sized b) => a -> b -> Int` and drops a dict
slot: the typed Core IR shows one `$dict_…useTwo_0` parameter for a two-constraint
signature. Both `d x` and `d y` route through the survivor.

**Why the plan removes the cause.** §2 E is explicit: *"The interim all-or-nothing pin
(PR #1021) and its unsoundness (#1052) retire with it."* Under uniform `gen`, `d` is not
monomorphised at all — it is generalized *and* dict-abstracted, `d : Sized v => v -> Int`,
with the two use sites forwarding `$dict_useTwo_0` and `$dict_useTwo_1` respectively.
The merge cannot happen because nothing declines the generalization. S-2(f)'s
value-restriction gate is satisfied here (`d v = sizeOf v` is a syntactic function, so
the restriction already licenses generalization) and its timing-neutrality clause is
satisfied for the same reason.

**Falsifiable prediction.** When **F-1** lands, #1052's repro must print `3` on both
engines (today: `2` on both, `check` green), matching its inlined control; and the typed
Core IR dump (`compiler/entries/core_ir_typed_modules_dump_main.mdk`) must show **two**
`$dict_` parameters on `useTwo`. The IR-dump assertion is the load-bearing half — a fix
that makes the printed value `3` without restoring the second dict slot has moved the bug,
not removed it.

⚠️ #1052's own body warns that *"a fix that merely makes `check` agree with emit is not
sufficient — both already agree here, and both are wrong"*. Applies to F-1's verification
bar too.

---

## Family F — effect rows, polarity, coverage

### #1103 — `unifyRowN` same-tail prefix discard · **DRAINED-BY D-1** (#1118)

**Mechanism (verified).** `unifyRowN` (`:916`), same-tail arm at `:931`:
`| effvarId v1 == effvarId v2 = recordAbsorptions (atomsDiff l1 l2 ++ atomsDiff l2 l1) v1`
— the prefix mismatch is recorded for the #839 event trail and otherwise discarded. The
arm's own comment calls the leniency *"ACCIDENTAL, NOT load-bearing"* and points at the
declaration-time covering rule; #1103 proves that rule does not reach a plain top-level
function, because `checkArgEffVarCoverage` (`:1170`) is wired only from
`checkIfaceMethodEffs` (`:1138`), reached only from `checkUndeterminedRetEffVarsDecl`'s
`DInterface` arm (`:1132`).

**Why the plan removes the cause.** §2 I names it at the spec's precision: *"the same-tail
arm must still check the atom prefix (#1103)"*, and §6 D-1 owns it by number. The fix is
a prefix-equality check on the arm, not an unconditional error — which is exactly what the
source comment's warning ("a benign self-unify `e ~ e` also lands here") requires, and
D-1's phrasing preserves it.

**Falsifiable prediction.** When **D-1** lands, `launderArrow : (Unit -> <Stdout | e> Unit)
-> (Unit -> <e> Unit); launderArrow f = f` must be rejected at its declaration or at
`quiet = launderArrow shout` (today: `check` exit 0, both engines print `SMUGGLED`), while
control 1 (identical rows, `honestArrow`) must keep its existing rejection at
`10:20` and the benign self-unify `e ~ e` must remain silent — a D-1 that reddens the
compiler's own sources on `e ~ e` has overshot.

---

### #1098 — mutable containers widen an effect-row-carrying parameter · **DRAINED-BY D-2** (#1119)

**Mechanism (verified).** Two contributing routes, per #1098's own correction: the
`<>`-supplied case reaches `unifyRowN (EffRow _ None) (EffRow _ None) = ()` (`:988`)
because `reopenRowN True (EffRow (l::ls) None)` (`:3663`) re-opens only rows carrying at
least one label; the non-empty case reaches the *correct* guarded subset check. Neither
site accounts for mutation, and `Ref`'s type parameter carries no invariance requirement.

**Why the plan removes the cause.** §2 I is explicit that write channels are **not** the
rule: *"Write channels (`Ref`/`MutArray`/`HashMap`, #1098) are the co∧contra special case
of this rule, not the rule"*. D-2 computes a per-parameter polarity from field occurrences
and propagates it transitively; `Ref a`'s parameter occurs in both the read and the write
signature, so it is mixed ⇒ invariant ⇒ no covariant row leniency at that argument. The
three stdlib types built on `Ref` (`MutArray`, `HashSet`, `HashMap` — grep-confirmed in
#1098's body) inherit it through the transitive propagation rather than through a
hand-maintained table, which is what makes this a class fix.

**Falsifiable prediction.** When **D-2** lands, `alias : Ref (Unit -> <Stdout> Unit); alias
= box` (where `box : Ref (Unit -> <> Unit)`) must be rejected (today: exit 0, both engines
print `REF-EFFECT-PERFORMED`), and the same must hold for the `MutArray` and `HashMap`
repros **without a per-type entry being added for either** — if closing them needs three
more table rows, D-2 implemented the special case and not the rule. The `List` control and
the bare-function control must both stay **accepted**.

---

### #1121 — contravariant Type parameter of an ordinary datatype · **DRAINED-BY D-2** (#1119)

**Mechanism.** `data Taker a = MkTaker (a -> Int)` puts `a` in domain position, so `Taker`
is contravariant in `a`; `wide : Taker (Unit -> <IO> Unit); wide = pureTaker` is the unsafe
widening direction (EFFECTS §9). No mutation is involved anywhere, and no
`Effect`-kinded index — so neither #1094's closed fix nor #1098's write-channel framing
reaches it.

**Why the plan removes the cause.** #1121 is the case §2 I names *by this exact example* as
the general rule the write-channel proxy misses, and §6 D-2 says D-2 "**owns #1121**". The
mechanism is the same computation as #1098's: `a` occurs contravariantly in `MkTaker`'s
field ⇒ contravariant ⇒ invariant row treatment at that argument.

**Falsifiable prediction.** When **D-2** lands, `wide = pureTaker` must be rejected (today:
exit 0, both engines print `LAUNDERED`), while the covariant control (`f : Unit -> <IO>
Unit; f = pureFn`) and the `List` control must both stay **accepted**. #1121's own owed-pin
note is right that the accepted controls must be pinned alongside, or the fix overshoots
into rejecting sound re-opens.

**Consistency check on the plan:** #1098 and #1121 must land in **one** change. They are
the same computation at two positions; fixing them separately re-creates the
special-case-first mistake that produced #1121 in the first place.

---

### #1100 — abstract-head row-kinded argument never collected · **DRAINED-BY D-3** (unconditional half)

**Mechanism (verified, line-for-line).** The two halves of one rule disagree about what a
row-kinded occurrence is:

- return side — `methodEffRetOccs scope` (`:1248`) ends
  `++ map (n => (n, [])) (rowArgNamesIn scope t)` (`:1255`), and `rowArgNamesIn` (`:4276`)
  has **both** a `TyCon`-head arm (`:4278`) and a `TyVar`-head arm
  (`(TyVar h, args) => rowArgNamesVarApp scope h args …`, `:4280`);
- argument side — `methodEffArgOccs` (`:1205`) takes **no scope parameter at all**, and
  `argPerformableOccs`' `TyApp` arm (`:1232-1234`) resolves a row slot only via
  `krowSlotOccs` under a `TyCon` head; a `TyVar` head falls to the structural catch-all
  and contributes `[]`.

`checkArgEffVars _ _ _ _ _ [] = ()` (`:1176`) then returns immediately on the empty
variable list, so no obligation is ever raised for `gtake : f e a -> a`.

**Why the plan removes the cause.** §6 D-3 owns exactly this: *"abstract-head row-kinded
arguments are `collected` at all (#1100)"*. The fix is symmetry — thread the graded scope
into `methodEffArgOccs`/`argPerformableOccs` and give the latter a `TyVar`-head arm
matching `rowArgNamesVarApp`. Note this half is **unconditional**: unlike #1095 it does not
depend on the #823 fork, because `gtake`'s return type is a bare variable with no index to
discharge anything.

**Falsifiable prediction.** When **D-3** lands, `g1_abstract_head_notake.mdk` must be
rejected at the `gtake` declaration with `T-EFFECT-ARG-UNCOVERED` (today: exit 0 on
`check`/`run`/`build`, prints `BOOM 7`), matching its concrete-head control `g2` and its
one-token control `g5`. The charged-arrow control `g3` must keep its existing rejection.

⚠️ **Sequencing, stated by #1100 itself and worth holding the plan to:** `gpure`, `gap` and
`gtake` are green today *because of this defect*; closing it moves them into #1095's
population. So D-3 must land #1100's half and #1095's half **together**, or the graded
fixtures redden in between. §6 D-3 groups them, which is right — but the epic's stage table
lists D-3 as "#1095 + #1100, coordinated with #822/#823", and #1095's half is `◇`-gated
while #1100's is not. That asymmetry is the risk.

---

### #1095 — result-index occurrence discharges argument coverage · **GAP (G-3, ownership)**

**Mechanism (verified).** `methodEffRetOccs` (`:1254-1255`) folds `rowArgNamesIn scope t`
into the *return* occurrence list, and `checkArgEffVars` (`:1177`) treats a non-empty
`retOccs` as discharging the argument-only requirement. A result **index** occurrence
(`f e b`) is a promise about force time, not a charge at call time — so an impl arm that
applies the callback eagerly performs `<e>` with nothing charging it.

**Why this is a GAP rather than DRAINED-BY D-3.** The design assigns it away twice, and
the other side assigns it back:

- §4 family F marks it `#1095 ◇graded-arc` — *"if #823 resolves to the uncharged-signature
  option, the launder stays representable and only the arc closes it"*.
- §6 D-3 repeats it — *"if #823 resolves the eager-arm fork to the uncharged signature, the
  launder remains representable and the arc — not this stage — closes it"*.
- And #1095's own body quotes the graded arc's decision record as saying of the
  defer-vs-eager fork: *"Both options close #817/#825 equally — this was never a soundness
  question, only a cost one."* **#1095 exists to disprove that sentence.**

So D-3 defers to #823 on the grounds that #823 will decide it, and #823's recorded premise
is that there is nothing to decide. **There is no stage in either arc that is
unconditionally committed to closing #1095**, and the `◇` marker makes that look like
coverage rather than the ownership hole it is.

**Proposed plan change.** Make #1095's *unconditional* half explicit and give it to D-3
regardless of the fork:

> D-3 must land the coverage/charge separation — a result-**index** occurrence never
> discharges the argument-only requirement — **independently of #823's eager-vs-defer
> resolution**. What #823 decides is whether the eager arm remains *writable*; what D-3
> decides is whether writing it is *diagnosed*. These are different questions and only the
> second is this arc's.

Concretely: today the honest signature (control 2, `gmap : (a -> <e> b) -> f e a -> <e> f e b`)
is expressible and enforced at every call site, so there is a correct target for the
diagnostic to point at. The fix does not require the fork to be resolved.

**Falsifiable prediction (once ownership is fixed).** `f3_graded_eager_pure_caller.mdk`
must be rejected — either at the `impl GMap Box` eager arm or at the `gmap` declaration —
where today `check`/`run`/`build` all exit 0 and `pureInt : Int` prints `BOOM`. Control
`f2` (deferred arm) must stay accepted; control `f5` (no index occurrence) must keep its
existing rejection.

---

## Family G — laundering via method schemes

### #819 — impl body pins an impl-HEAD type variable · **GAP (G-1)**

**Mechanism (from the issue, source-consistent).** An impl registers for head `P c d` and
therefore matches every instantiation, but its body only typechecks at `c := String`; a
`P Int Int` receiver dispatches to it anyway. `check` green, `run` panics.

**Why the plan does not remove it.** §4's family G row lists the drained issues as
*"#830 (gen-sig authority), #819 (adjacent); #817 ◇graded-arc, #825 ◇graded-arc"* and names
the design element as *"G: W3 rigid everywhere; #803 bound keeps pre-unify placement"*.

**W3 cannot reach #819, by construction.** W3 is *method-scheme* rigidity —
`checkImplMethodRigidity` / `checkDefaultMethodRigidity` / `checkImplEffVarRigidity`
(`:14749`, `:14766`, `:14927`), all gated by `inRigidityBodyRef`. Impl-**head** variables
are the instance's own quantifiers (the substitution φ) and are **deliberately exempt**;
the source says so at `:14926`: *"(The TYPE-var half has no such carve-out: a method type
var may never alias an impl-head type var.)"* — i.e. the rule that exists is about method
vars aliasing head vars, not about head vars being pinned by a body. #819's own text
states the same: *"impl-HEAD vars are the instance's own quantifiers and are exempt there
by design."*

Making W3 "rigid everywhere" therefore does nothing for #819. The parenthetical
"(adjacent)" is doing all the work in that matrix cell, and "adjacent" is not a drain.
**No stage in §6 owns an instance-head fidelity check.** C-2 (#830) is signature authority
for *declared function signatures*; G's other listed items are W3, the #803 bound, and the
graded carve-out. Nothing else.

**Proposed plan change.** Add the instance-side analogue of W3 to Stage G / C-2's scope,
and write its spec paragraph into S-2 alongside (d) (impl completeness / phantom-method
rejection), which is the same "instance well-formedness at the declaration" bucket:

> **W3-inst (instance-head fidelity).** Every impl-head type variable must survive the
> checking of every method body of that impl as an unconstrained variable. If a body pins
> one to a concrete shape, reject at the impl declaration and name the narrowing the head
> would need (`impl Sizer (P String d)`) — the same C3-style post-unify survivor check W3
> already runs, keyed on the head vars instead of the method's own quantifiers.

The machinery exists (`checkMethodRigidityCore`'s survivor comparison), the diagnostic
shape exists (`T-IMPL-TOO-SPECIFIC`), and the check is decidable at the declaration where
`IE` is in hand — so this is an extension of an existing stage, not a new one. It belongs
with C-2 because both are "the declaration is authority over the body, reject rather than
narrow".

**Falsifiable prediction (once owned).** #819's repro must be rejected at
`impl Sizer (P c d)` naming `c` (today: `check` green, `run` panics with
`'++' requires Semigroup` in the reviewer's variant). Until a stage owns it, the honest
prediction is **that no stage of this arc changes #819's behaviour at all.**

---

### #817 — Async's `Mappable`/`Thenable` identify the method effect var with the container row · **GAP (G-3, ownership)**
### #825 — deferred effectful callback under a pure stored arrow closes the method effect var · **GAP (G-3, ownership)**

**Mechanism (verified in source).** Both are *deliberately admitted* residuals of the W3
check. `checkImplEffVarRigidity` (`:14927`) carries two comment blocks stating it:

- `:14916-14926` — *"⚠️ #817 carve-out: a method effect var unifying with an INSTANCE-HEAD
  row parameter (`impl Mappable (Async e)` …) is deliberately ADMITTED — the impl-head
  types' row tails are NOT in the dup set. It is a real residual laundering channel …
  Resolution is design-scoped (#817)."*
- `:14934-14944` — *"⚠️ DEFERRED-PERFORMANCE residual (round-2 break 4; tracked, NOT
  enforced) … Rejecting it here is CORRECT but outlaws the compiler's own Parser monad …
  the channel is admitted for now and owned by #825 (pinned)."*

**Why this is a GAP.** The design is *honest* about not owning them — §4 family G marks
both `◇graded-arc` and adds *"the arc is a peer, not a subtask — these drain there, not
here"*, and §8 lists the arc's own design forks as out of scope. That is a defensible
scoping decision and I am **not** proposing to reopen it. The gap is narrower and real:

**the architecture's assumption that the graded arc closes these is not currently
underwritten, because the graded surface's own coverage rules are open S0s.** #1095 and
#1100 each show the graded signature shape the arc will ship (`f e a`, `(a -> <e> b) ->
f e a -> f e b`) is accepted with **no** declaration-time obligation on the impl — #1100's
own §"Bearing on #820/#823" puts it plainly: *"the 'eliminate only through `grun`'
discipline the graded design rests on is, for abstract heads, entirely on the honour
system."* So the migration path #817/#825 are waiting on can be completed and still leave
the laundering channel open, one shape over.

**Proposed plan change (small, and it is a coordination note, not a re-scoping).** §8's
"Graded-arc coordination" bullet names two coordination points (A-3 ↔ #822 kind
machinery; D-3 ↔ #823 coverage rules). Add a third, and make it a **precondition** rather
than a rebase note:

> **#817/#825 may be closed by the graded arc only after D-3's coverage/charge separation
> is in force.** Migrating `Async`/`Parser` to a graded row index is not sufficient on its
> own: #1095 and #1100 demonstrate that the graded surface accepts an eager arm and an
> uncharged abstract-head method with no diagnostic, so a migration performed before D-3
> relocates the laundering channel rather than closing it (`#1044`-shape: relocating a
> collision is not a fix).

**Falsifiable prediction.** No stage of *this* arc changes #817's or #825's behaviour —
both repros must still launder after every stage S–F lands. That is the gradeable claim,
and it is why both rows read GAP rather than DRAINED-BY: the arc's own output for these two
is "unchanged, by design", and the risk is that a reader of the matrix's `◇graded-arc`
marker reads it as coverage.

---

## The remaining gaps, stated once

### G-2 — F-1's local-binder scope must be a SET, not the phrase "local bindings"

§2 E and §6 F-1 both say `gen` applies to "local bindings (#1082)". But #1040 and #1043
are the **same defect at different entry points**, and #1043 exists precisely because the
existing pin is consumed at one of five local-binding inference paths:
`processLetGroup` (via `inferLetGroup`) reads it; `blockLet` (`:5209`), `blockRecLet`
(`:5189`), `inferRecLet` (`:7819`) and `inferLetBody` (`:7901`) do not.

That is L1's own "a second copy for the other path" shape, and the plan's own §2 E already
learned this lesson once for a different set — the red team forced the correction that
E-4's *"schedule's marked-node set must enumerate impl bodies, default bodies, prop and
test bodies"*, because *"a schedule that walks only `DFunDef` groups silently regresses
them"*. The identical enumeration is owed here.

**Proposed plan change.** F-1's issue (#1082) should carry an explicit enumeration
sub-bar: *"the uniform-`gen` binder set is `{top-level, impl method, default method,
prop/test body, let-group member, block-`let`, block-rec-`let`, inline rec-`let`,
`let`-body pattern binder}`, enumerated from the inference entry points rather than
sampled; each gets a fixture."* Without it, #1040 (a `where` group, on the covered path)
drains and #1043 (a block-`let`, on an uncovered path) does not — and #1043's build failure
would then be read as the emitter half, which is excluded.

### G-4 — A-2's key for method tables must be METHOD identity, not `(module, name)`

#1070's priority-2 remedy — adopted verbatim into A-2's scope — is *"`(module, name)`
keying for `universeMethodIfaceParamsRef`, `universeIfaceRequiredRef`,
`universeMethodDispatchIdxRef`"*. That is not sufficient. Two interfaces declared in the
**same** module that each declare a method `mth` still collide under a `(module, "mth")`
key, and `registerMethodIfaceParamsMethods` (`:15335`) inserts by `mname` per interface, so
the same last-write-wins applies within a module.

The correct key is the method's own identity, which necessarily includes its owning
interface: `(originModule, ifaceName, methodName)`. L2 already says identity is assigned
to "interfaces, interface methods" as separate namespaces, so the substrate supports it;
the risk is purely that A-2 implements #1070's literal wording. AGENTS.md's own registry
lesson states the same shape: *"prove the key is scoped (`<iface>@<slot>`, never a
program-global bare name)"*.

**Proposed plan change.** A-2 (#1111) should state the key shape per table rather than
inheriting `(module, name)` from #1070's body — the same way it already states that
#1070's priority-1 remedy is superseded.

### G-5 — L2 is worded over `String` keys; two confirmed defects key by something else

L2 reads: *"After the resolve phase, no component keys anything by a bare `String` name."*
The registry ratchet in §2's cross-cutting substrate makes it mechanical: *"A bare-`String`
key fails the check."*

Two of the defects in this ledger key by something that is **not a `String`** and would
pass that check unchanged:

- **`activeDictVars : Ref (List (Int, String))`** (`:3139`) — the `assum` rung's evidence
  environment, keyed by a bare **tyvar id**, with no interface component. This is
  #1127's leg 2, and it is in **neither** #993's blast list ("`Value` rep, `Route`, both
  emitters, dict-arity readers") **nor** #1113's ("`keyForSite*`, `KeyBuckets`,
  `implEntryRouteWords`, `noneHeadTag`, wasm, eval dispatch, `Route`/`core_ir_lower`, the
  IR golden"). DICT §11's `assum` row already flags the property — *"keyed on the call
  site's enclosing binding's dict-variable name …, not on predicate identity"* — so the
  spec table saw it and the migration plan did not pick it up.
- **`(module, name)` for method tables** — a tuple, not a bare `String`, and still
  under-determining (G-4).

**Proposed plan change.** Restate L2's operative clause as a property of the key rather
than of its type, and widen the ratchet accordingly:

> **L2 (operative form).** Every table key is the resolved identity of the thing being
> keyed — for evidence environments, the **predicate** (interface identity + goal), not a
> tyvar id; for declaration tables, the declaration's `(originModule, …)` identity, not its
> spelling. The ratchet rejects any key that is not derived from an identity, whatever its
> representation type.

And add `activeDictVars` (and its readers `activeDictVarOf`, `activeDictVarForEncl`,
`firstDictForEncl`) to **B-1's** blast list, since B-1 is what makes the super-slot
degenerate case disappear.

### G-6 — candidate-set completeness (the #1128 change), stated above

See #1128's row. This is the single highest-value proposed change in this document,
because B-2's frozen arg-tag admissibility is computed against the same candidate set: an
incomplete set turns a today-latent bug into a *frozen, consumed-by-every-engine* wrong
answer.

### G-7 — #1020 is partially misclassified as engine-realization

§4 and §8 list **#1020** among the defects "architecture cannot drain", with the capture
ban holding "until the ENGINE fix lands". The wasm symptom is indeed an engine defect —
`emitMethodDispatchRef` has no default-synthesis arms and falls through to `unreachable`.
But #1020's own diagnosis names a cause that is **not** in the wasm backend:

- `lowerDeclImpl` (`compiler/ir/core_ir_lower.mdk:1267`) projects a `DImpl` to
  `map (lowerImplMethod …) methods` — **one entry per method the impl DEFINES**, so an
  impl that overrides only defaults lowers to **zero** `CImplEntry` and is invisible to
  every emitter table derived from the lowered entries;
- `fillImplDefaults` (`compiler/frontend/desugar.mdk:851`) would have filled them, but its
  own header (`:845-847`) says it is **same-module only**: *"sees just DInterface defaults
  co-located in this decl list — a user impl of a prelude interface in another module keeps
  using the fallback, as intended."*

So "what is this instance's method table?" is answered in four places — desugar
(same-module), `eval.mdk`'s untagged `defaultEntry` fallback (`:1888`), LLVM's
`emitDefaultDispatchChain`/`emitDispatchChainDefaulted`, and wasm's (absent) peer. That is
a textbook **L1** violation, and the design already brushes against it: B-2's blast list
calls out *"the disjoint default-tag word namespace (synthesized default-method arms exist
for receiver tags with no impl — do not collapse them into the instance namespace)"*.

**Proposed plan change.** Reclassify #1020 as **split**: the wasm dispatch arm stays
engine-realization; the *cause* — cross-module default-method table completion — becomes
part of **A-3 (K)**, whose IE is already specified to carry "every impl with its full head,
context, **and method table**". Make that phrase load-bearing: the method table is
**complete** (defaults resolved whole-graph), computed once, and consumed. Then the wasm
fix becomes "read the table" rather than "grow a fourth private copy of the rule".

Leaving it wholly on the exclusion list is the invisible-work hazard: the list says nothing
can help it, so nobody revisits the part that a stage genuinely would.

### G-8 — arity / calling convention has no owner (the #1034 / #826 / #1101 class)

The exclusions for **#1034**, **#826** and **#1101** all **hold** at the instance level,
and I am not proposing to move any of them:

- **#1034** — `methodArgTys` (`core_ir_lower.mdk:1382-1386`) walks the whole arrow spine
  (`methodArgTys (TyFun a b) = a :: methodArgTys b`), so a method whose result type is
  itself a function is over-counted. §4's justification is exactly right: `a -> (Unit ->
  Unit)` and `a -> Unit -> Unit` are the same `Ty`, so **the over-count is not recoverable
  from the type**, and no identity or selection work touches it. ✅ holds.
- **#826** — same root distortion, different failure mode (define-vs-call-site arity
  disagreement → LLVM prototype mismatch → SIGSEGV). ✅ holds.
- **#1101** — a direct 2-argument call against a 1-parameter `define`, silently legal under
  LLVM's opaque-pointer model. Pure emit. ✅ holds.
- **#1043's emitter half** — an unlocated, uncoded, wrong-cause `E-PANIC`. ✅ holds.

**But the class has no owner.** Method arity is derived independently by at least three
consumers: `eval.mdk` builds `VClosure env pats body` (`:1837`) from the **impl clause's
pattern count**; `core_ir_lower` derives `methodArityOf` from the **declared interface
signature** (`:1410-1411`); and #826 is literally a third disagreement between a define
and its call sites. Under **L1** — *"consume, never re-derive … extends to every derived
artifact of a decision"* — that is three implementations of one judgment. §2 E's output
contract lists what elaboration produces: *"the typed, dict-explicit, route-stamped AST"*
and *"evidence references and frozen admissibility data"*. **Arity and calling convention
are not in it.**

**Proposed plan change.** Extend E's output contract (and hence L6, above) to carry
per-binding and per-method **arity and calling convention** — number of leading dict
params, source arity, eta-expansion target — as elaboration output consumed by both
engines. That does not fix #1034 (the over-count still has to be corrected once, in the
lowering, which is why the exclusion holds); it stops the *next* one, and it is the only
change that would make #826's "make the two arity oracles agree" a structural property
rather than a patch that #1034 already proved insufficient.

---

## Not established

**None.** Every row above reached a verdict. The two rows I came closest to leaving open
were #1125 (settled by the `headCollides` bimodality derivation — see its row for the
falsification that would move it back to engine-realization) and #1127 (settled by
grep-proving all three legs). Both carry an explicit "if this is still broken after the
stage, re-file as engine-realization" clause, which is the honest form of the residual
uncertainty rather than a hedge in the verdict column.

---

## References

- [`TYPECHECK-TARGET-ARCHITECTURE.md`](TYPECHECK-TARGET-ARCHITECTURE.md) — the design (authority)
- [`TYPECHECK-ARCHITECTURE.md`](TYPECHECK-ARCHITECTURE.md) — the derived map
- [`../docs/spec/DICT-SEMANTICS.md`](../docs/spec/DICT-SEMANTICS.md) §11, [`../docs/spec/EFFECTS-SEMANTICS.md`](../docs/spec/EFFECTS-SEMANTICS.md) §11 — per-clause enforcement tables (clause → site → keying assumption)
- Epic **#1122** — stage table and dependency spine
- `.claude/workstreams/TYPECHECK.md` — the standing five-question gate
