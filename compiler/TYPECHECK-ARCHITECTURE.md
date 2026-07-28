# Typechecker Architecture — the derived map

**Status:** CURRENT — derived first-hand from `compiler/types/typecheck.mdk` at `main`
`1691922a` (2026-07-29). Every count in this document was computed from the source, not
copied from a prior doc. **Numbers rot: re-derive before trusting them** (§0 gives the
commands).

**What this is.** A responsibility map: the subsystems inside the typechecker, what each
owns, which state it touches, and which spec clause governs it. It exists because every
prior artifact about this file is *defect-indexed* — `compiler/ARCH-REVIEW.md` is a
critique, `.claude/workstreams/TYPECHECK.md` is a duplicate-family map, #991–#995 are five
seam deep-dives. None of them answers *"what are the parts?"*, which is the question you
need answered before you can argue about a target architecture.

**What this is not.** Not a tutorial (the HM core is standard and good — do not "improve"
it), not a backlog (that is GitHub Issues), and not a plan. §8 records decisions already
made so a future reader does not relitigate them.

---

## 0. How this was derived, and how to re-derive it

Three mechanical passes over the source, then verification by reading:

1. **Declaration inventory** — every column-0 declaration, its line span, its clauses.
2. **State-ownership graph** — for all 147 state cells, which functions read and which
   write, attributed by line span.
3. **Dominator analysis** — from a virtual root over all exported entry points. A function
   `F` *owns* everything reachable only through `F`. That dominated set is the closest
   thing this file has to a module boundary, and it is what §4's table is built from.

Cheap spot-checks that reproduce the headline numbers without any tooling:

```sh
wc -l compiler/types/typecheck.mdk                                  # size
grep -cE '^-- [─═━]' compiler/types/typecheck.mdk                   # banner sections
grep -nE '^checkBodyImpl' compiler/types/typecheck.mdk              # the spine
grep -n '\bcheckBodyImpl\b' compiler/types/typecheck.mdk | grep -v '^[0-9]*: *--'   # its 2 call sites
awk '/^data PerRun/,/^\}/' compiler/types/typecheck.mdk | grep -cE '^ +[a-z].*:'    # PerRun fields
```

> ⚠️ **Two traps this derivation hit.** Both produced confident, wrong output first.
> - A regex matching `data|type|impl|…` without a trailing `\s+` silently reclassifies
>   every function *named* `implMatchesReceiverU`, `dataEnvOf`, `typeOfX` as a declaration
>   of that kind. It hid **55 functions** and turned "1 dead function" into a fabricated
>   "25 dead functions" finding.
> - The section banners use **box-drawing** characters (`── `), not ASCII. An ASCII-only
>   grep reports *"this file has no section structure"*, which is false.

---

## 1. The shape of the file

| | |
|---|---|
| Lines | 18,668 |
| Logical declarations | 1,478 — **1,443 functions**, 33 `data`, 2 type aliases |
| Exported | 70 (50 functions reachable as entry points) |
| Banner sections | 75 (**not** a valid partition — §2) |
| State cells | **147** — `PerRun` 63, `CrossRun` 25, `DriverState` 18, `Toggles` 3, loose module-level 38 |
| Functions touching any state | **316 of 1,443** — the other 1,127 are pure |
| Cells written from ≥6 functions | **6 of 147** |
| Functions unreachable from an entry point | 0 |
| Functions with no caller | 1 (`wReset`) |

**Growth**, from `git`: 10,483 lines (2026-06-29) → 13,717 (07-15) → 17,008 (07-22) →
18,668 (07-29). Roughly +8,200 lines in a month, +1,660 in the last week.

Two of these numbers contradict the received wisdom and are load-bearing for §7:
**1,127 of 1,443 functions are pure**, and **only 6 of 147 cells have diffuse ownership**.
The state problem this file is famous for has been substantially *fixed*.

---

## 2. Why the 75 banner sections are not the architecture

A banner marks **where a feature was inserted**, and every declaration after it inherits
that label until the next banner. They are commit archaeology. Three examples, all derived:

| Banner | Actually spans | Actually contains |
|---|---|---|
| *"the INDEX row unifier (#1094)"* | 1,594 lines, 92 decls | `CrossRun`, `pushDictApp`, `routeLocalSym`, `callOblsWindow` — none of them the index row unifier |
| *"non-exhaustive-match warning accumulator"* | 185 lines, 5 decls | the core `PerRun` state record and `freshPerRun` |
| *"Multi-param-interface element grounding (Shape A / gap #44)"* | 1,562 lines, 135 decls | the whole impl-method body driver, incl. `inferImplMethod` |

Use them to find *when* something arrived, never *what a region does*.

---

## 3. The state model

State is four bundle records plus 38 loose module-level `Ref`s. Each bundle is a **record
of `Ref`s** held in one cell, so a reset re-mints the record rather than clearing fields —
this is the #158/#176 design, and it landed.

| Bundle | Cells | Lifetime | Reset by |
|---|---|---|---|
| `PerRun` | 63 | one module / one check run | `resetState` re-mints via `freshPerRun` |
| `CrossRun` | 25 | whole multi-module run — the `universe*` accumulators | survives `resetState` by design |
| `DriverState` | 18 | driver-mode flags, oracles, harvests | survives; re-minted per driver entry |
| `Toggles` | 3 | dynamic context (suppression flags) | re-minted with `PerRun` |
| *(loose)* | 38 | mixed — incl. the four bundle cells themselves | varies |

**The six cells with no single owning function** (≥6 distinct writers) are the residual
state-discipline debt: `perRun` (56 writers), `driverState` (14), `currentLoc` (8),
`typeErrorsSticky` (8), `crossRun` (7), `funConstraintsRef` (6).

`typeErrorsSticky` is **deliberately** outside every bundle and must stay there — it is
sound *because* it survives resets (see §8).

---

## 4. The subsystem map

Gateways are derived by dominance: *owns* = functions reachable only through this gateway;
*cells* = distinct state cells touched by that whole subtree. Layers are mine; everything
else is measured.

### Layer 0 — Foundations (pure type machinery)

| Subsystem | Gateway | Owns / lines / cells | Spec |
|---|---|---|---|
| Union-find + unification | `unify` → `unifyN` | 31 / 403 / 15 | — |
| Generalization, instantiation, value restriction | `generalize`, `instantiate` | small | — |
| AST type → `Mono` | `fromAstTypeE` | 15 / 224 / 3 | — |
| Alias cycle detection | `rejectCyclicAliases` | — | — |
| Rendering (`ppMono`/`ppScheme`) | `ppScheme` | 54 reachable | — |

The HM core (levels, path-compressed union-find, the value restriction) is the healthiest
part of the file. `ARCH-REVIEW.md` said so in June and it is still true.

### Layer 1 — Effects and rows

| Subsystem | Gateway | Owns / lines / cells | Spec |
|---|---|---|---|
| Refinement domains (capability-effects v2) | `dsub`, `djoin`, `dmeet`, `drender` | ~200 lines | EFFECTS §2 |
| Effect-label domain registry | `effectDomains` (in `DriverState`) | ~50 lines | EFFECTS §2 |
| Effect rows, atoms, propagation | `unifyRowN` | 124-line core | EFFECTS §3, §5 |
| Undetermined return-position effect vars | `checkUndeterminedRetEffVars` | 15 / 179 / 2 | EFFECTS §6 |
| Interface-method effect checks | `checkIfaceMethodEffs` | 13 / 166 / 2 | EFFECTS §6 |

Open here: #797, #817, #825, #1095, #1098, #1100, #1103. **This is the densest open-S0
cluster in the file**, and §7 argues it is not a coincidence.

### Layer 2 — Inference core

| Subsystem | Gateway | Owns / lines / cells | Spec |
|---|---|---|---|
| Expression inference (the 25-arm walk) | `infer` | **298 / 4,302 / 63** | — |
| Application inference | `inferAppExpr` | 58 / 991 / 21 | — |
| Method occurrence typing | `inferMethodAt` | 18 / 300 / **18** | DICT §5 |
| Match inference | `inferMatch` | 17 / 182 / 4 | — |
| Binop/unop inference | `inferBinopE` | 13 / 195 / 8 | — |
| Let-group inference | `inferLetGroup`, `processLetGroup` | 30 / 337 / 6 | — |
| Pattern inference | `inferPat` | ~140 lines | — |

### Layer 3 — Letrec scheduling

| Subsystem | Gateway | Owns / lines / cells | Spec |
|---|---|---|---|
| Dependency-ordered SCC processing | `processTopGroups` → `processSCCs` → `processSCC` | 86 / 918 / 27 | **none** |
| Tarjan SCC | (within the above) | — | — |

**No formal semantics governs generalization order or SCC merging.** That is a finding,
not a gap in this document.

### Layer 4 — Dispatch and dictionaries

| Subsystem | Gateway | Owns / lines / cells | Spec |
|---|---|---|---|
| **Entailment engine** | `entail` → `entailInst` | 49 / 620 / **6** | DICT §3 |
| Obligation checking | `checkCallObligationsU` → `checkOneCallObligation` | 43 / 524 / 10 | DICT §3, §4 |
| Impl method bodies | `inferImplBodies` → `inferOneImpl` → `inferImplMethods` → `inferImplMethod` | 22 / 495 / 12 | DICT §4 |
| Default method bodies | `inferDefaultBodiesIfEnabled` → `inferDefaultBodies` → `inferOneIfaceDefaults` → `inferDefaultMethods` → `inferDefaultMethod` | 12 / 260 / 10 | DICT §4 |
| Dictionary insertion | `dictPass` → `dictPassDecl`, `implDictPassMethods` | 37 / 368 / 4 | DICT §4 |
| Arg-position prepass | `prePassDictArg`, `prePassDeclScoped`, `rewriteArgScoped` | 23 / 269 / **0** | **none** |
| Canonical impl-key registry | `univConcreteBucket`, `univHeadless` | ~144 lines | DICT §8 |
| Specificity selection | (#609 head vectors, #203 interface-keyed) | ~660 lines | DICT §3 `inst` |

`entail` at 620 lines touching only **6** cells is the best-encapsulated non-trivial
subsystem in the file — the #156 work succeeded. The **impl/default fork is the #992
shape**: two gateway chains, same judgment.

The arg-position prepass touches **zero** state cells. It is pure, and therefore movable.

### Layer 5 — Global checks

| Subsystem | Gateway | Owns / lines / cells | Spec |
|---|---|---|---|
| Coherence | `cohFirstConflict` → `cohConflictWith` | 18 / 167 / 8 | DICT §6 |
| Final-check driver | `runFinalChecks` | 22 / 231 / **0** | — |
| Signature-constraint soundness | `checkSigConstraintCoverage` → `checkSigConstraintOne` | 25 / 218 / 4 | — |
| Signature-too-general | `checkSigTooGeneral` | ~98 lines | — |
| Impl completeness, phantom methods, cyclic/absent superinterfaces | four separate walks | ~390 lines | DICT §6 |
| Interface type-parameter kinds (#822) | `checkGradedImplHeads` | ~195 lines | partial (#1093) |
| Data/record registration | `registerAllData` | 18 / 175 / 8 | — |

Open here: #311, #614, #679 (coherence vs DICT §6.1), #830, #819.

### Layer 6 — Shadowing (standalone fn ⇄ interface method)

| Subsystem | Gateway | Owns / lines / cells | Spec |
|---|---|---|---|
| Definer-side shadow application | `inferDefinerShadowApp` | 4 / 179 / 10 | SHADOW §1 (S1–S8) |
| Importer-side / S-1 machinery | `inferShadowApp`, `inferDefinerStandaloneVarApp` | ~730 lines | SHADOW §1, §6 |

This is the one subsystem with a **per-clause enforcement table** already written
(SHADOW-SEMANTICS §3, clause → site → keying assumption). It is the model the other
layers lack.

### Layer 7 — Drivers and cross-module

| Subsystem | Gateway | Owns / lines / cells | Spec |
|---|---|---|---|
| **The spine** | `checkBodyImpl` | **835 / 10,917 / 122** | — |
| Per-module fold | `foldModules` | 10 / 201 / **0** | — |
| Multi-module check drivers | `checkModules`, `checkModuleFullImpl` + 5 `check*` tails | ~590 lines | — |
| Typed elaboration | `elaborateModules`, `elaborateDict`, `elabModuleStamp` | 53 / 892 / 30 | DICT §4, §8 |
| Cross-module universe marshalling | `loadDataUniverse`, `storeDataUniverse`, `appendUniverseAccums` | 14 cells each | **DICT §8 I1** |
| Import seeding / aliasing / ctor overlay | `importFormSchemes`, `aliasSchemes`, `aliasConstraintEntries` | ~370 lines | DICT §8 I2 |

### Layer 8 — Diagnostics

| Subsystem | Gateway | Owns / lines / cells | Spec |
|---|---|---|---|
| Type-error accumulator | `pushTypeError` family, `typeErrorsSticky` | ~175 lines | — |
| Structured diagnostic (`TcDiag`) | `tcCode`, `tcLoc`, `tcMsg`, `tcHelp`, `tcFix` | ~39 lines | `compiler/DIAGNOSTIC-CODES-DESIGN.md` |
| Exhaustiveness bridge | `matchOracle`, `matchWarnings` → `compiler/frontend/exhaust.mdk` | ~185 lines | — |
| Unreachable-arm warning | `W-UNREACHABLE-ARM` walk | ~147 lines | — |

---

## 5. The spine: `checkBodyImpl`

One function, 347 lines, **two call sites** (the `Flat` path at 12805, the `Module` path at
16768). It dominates **835 functions / 10,917 lines — 58% of the file — and 122 of the 147
state cells (83%)**. It directly touches 46 cells itself.

It is a linear phase sequence, opening with `resetState ()`, parameterised by
`data CheckMode = Flat (List Decl) | Module String (List Decl) (List Decl)`. The author's
own numbering (`#1`–`#6`, plus two `BREAK` points) marks the phases:

(`stampBindingIds` is not local — the spine calls out to
`compiler/frontend/resolve.mdk` for it.)

```
resetState → stampBindingIds → decl universes (#1) → superDecls (#6)
  → checkEffectParams / checkLetRecDecls → shadows (#4) → mode-specific ref setup
  → dataEnv → checkUndeterminedRetEffVars → checkGradedImplHeads → rejectCyclicAliases
  → globalS = ifaceMethodSchemes ++ externSchemes → env1
  → processTopGroups            ← [BREAK #1] the inference plan; Flat is two-phase
  → cross-module dict snapshot (#3, Module only)
  → groundMultiParamObligations
  → obligation gate (#5)        ← [BREAK #2] Flat and Module diverge again
  → localSchemesOut / seedSchemesOut
```

**`Flat` vs `Module` bimodality is threaded through 20 `match mode` branches inside this
one function.** That is the #992 fork shape (two drivers for one judgment), one level up
and unfiled — the driver equivalent of the impl/default split.

---

## 6. Open issues, by subsystem

| Subsystem | Open |
|---|---|
| Effects / rows | #797, #817 (S0), #825 (S0), #1095 (S0), #1098 (S0), #1100 (S0), #1103 (S0) |
| Cross-module registries | #1069 (S0), #1070 (S0 umbrella), #1092 (S0), #1090 |
| Local dict pins | #1040 (S0), #1052 (S0), #1043 (S1), #1082 (S1) |
| Obligations | #323, #563, #564, #792, #845, #991 |
| Coherence | #311, #614, #679 |
| Method rigidity / signatures | #819 (S1), #830 |
| Shadow / import overlay | #733, #756 |
| Superclass evidence | #741, #993 |
| Architecture (from the 07-24 review) | #991, #992, #993, #994, #995 |
| Graded interfaces (planned arc) | #820, #821 |
| Hygiene | #176, #462, #480 |

---

## 7. What the map actually shows

**1. The state problem is largely solved; the *control-flow* problem is not.**
1,127 of 1,443 functions are pure and only 6 of 147 cells have diffuse ownership — #158/#176
worked. But one function dominates 58% of the file and 83% of the state. `ARCH-REVIEW.md`
diagnosed "a god module with concentrated mutable state" and the fix addressed the state
half. The remaining concentration is `checkBodyImpl`, and no open issue names it.

**2. The largest open-S0 cluster sits in the layer with the weakest spec coverage.**
Effects (Layer 1) carries 6 of the ~11 open S0s. EFFECTS-SEMANTICS is the longest spec in
the tree, but the row-unifier and coverage-check machinery those S0s live in
(`unifyRowN`, `checkArgEffVarCoverage`) is not covered clause-by-clause the way
SHADOW-SEMANTICS §3 covers its sites.

**3. The cross-module S0s violate a clause the spec already states by name.**
DICT-SEMANTICS §8 **I1** says evidence abstraction is keyed by module-qualified binding
identity, "never by its bare name," and names bare-name keying as "a coherence and a
type-preservation break at once." #1069, #1070, and #1092 are that break, in tables that
still key by bare name. This is not an under-specified area — it is a specified area with
an unenforced clause.

**4. Two subsystems are pure and therefore extractable today.** The arg-position prepass
(`prePassDictArg`/`prePassDeclScoped`/`rewriteArgScoped`, 269 lines) and `runFinalChecks`
(231 lines) touch **zero** state cells. `foldModules` touches zero. These are the cheapest
real decompositions available and none of them is blocked on anything.

**5. `entail` is the proof the target shape works.** 620 lines, 49 functions, 6 state
cells, one gateway. The #156 entailment consolidation produced the file's best-encapsulated
subsystem. Whatever is done next should be measured against it.

**6. Three subsystems have no governing semantics at all**: letrec/SCC scheduling and
generalization order, the `Flat`/`Module` driver bimodality, and the arg-position prepass.
Per the standing gate's question 2, "no formal semantics exists" is a finding — these are
where a spec is owed.

---

## 8. Settled — do not relitigate

- **The HM-core / dispatch file split was evaluated and REJECTED** (`ARCH-REVIEW.md` PASS 2).
  Dispatch state is read at `infer` depth across the 25-arm walk. Re-proposing a split needs
  new evidence, not a fresh opinion.
- **Order is semantics.** Reverse-declaration-order scanning, first-match lookup and
  prepend-wins decide which coherence conflict reports first and which impl a collision site
  keys. Golden drift from a map-ification is *"I changed semantics"*, never *"refresh the goldens."*
- **Effect rows are transparent in matching on purpose** (EFFECTS-SEMANTICS §8, the
  single-meaning law). Coherence, subsumption and dispatch matching strip `TEff` by design.
- **`typeErrorsSticky` stays outside every state bundle, permanently.** It is sound because
  it survives resets.
- **The `pending*` deferred-mutation cells are essential, not accidental.** A method site's
  route depends on which tyvar survives unification, knowable only post-inference. Bundle
  them; never try to eliminate them.
- **~37 cells deliberately survive `resetState`.** Clearing one "for hygiene" reproduces the
  Phase-134 dropped-dict bug.
- **Hot helpers stay monomorphic and short-circuiting** — delegating to prelude `Foldable`
  methods measured +56% self-compile.

---

## 9. Corrections to prior documents

| Document | Claim | Status |
|---|---|---|
| `compiler/ARCH-REVIEW.md` | "6,916 lines, 48 Refs" | Historical (2026-06-14). Now 18,668 lines / 147 cells across 4 bundles. |
| `compiler/ARCH-REVIEW.md` | "still one ~13k-line file" (status banner) | Stale — 18,668. |
| `.claude/workstreams/TYPECHECK.md` | "13,717 lines / 97 Refs at `db33eeab`" | Correct as of 2026-07-15; superseded. |
| Both | "concentrated mutable state" is the primary issue | **Substantially fixed.** The primary issue is now single-gateway control-flow concentration in `checkBodyImpl`. |
| §2 above | the 75 banner sections describe their regions | False — they are insertion markers. |

---

## References

- `docs/spec/DICT-SEMANTICS.md` — §3 entailment, §4 elaboration, §5 dispatch, §6 coherence, §8 identity
- `docs/spec/EFFECTS-SEMANTICS.md` — §2 rows, §3 judgment, §5 no-laundering, §6 polymorphism, §8 erasure
- `docs/spec/SHADOW-SEMANTICS.md` — §1 clauses S1–S8, §3 per-stage enforcement table
- `.claude/workstreams/TYPECHECK.md` — the standing five-question gate, duplicate-family map, traps
- `compiler/ARCH-REVIEW.md` — PASS 1/2 prior review
- `compiler/DIAGNOSTIC-CODES-DESIGN.md` — the `TcDiag` contract
