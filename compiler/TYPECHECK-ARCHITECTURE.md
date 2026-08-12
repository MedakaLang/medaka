# Typechecker Architecture — the derived map

**Status:** CURRENT — derived first-hand from `compiler/types/typecheck.mdk` at `main`
`1691922a` (2026-07-29), then corrected against four adversarial reviews. **Numbers rot —
re-derive before trusting them**; §0 gives the commands and §9 records what this document
itself got wrong.

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
2. **State-ownership graph** — for all state cells, which functions read and which write,
   attributed by line span.
3. **Dominator analysis** — from a virtual root over all exported entry points. A function
   `F` *owns* everything reachable only through `F`. That dominated set is the closest
   thing this file has to a module boundary, and it is what §4's table is built from.

Cheap spot-checks that reproduce the headline numbers without any tooling:

```sh
wc -l compiler/types/typecheck.mdk                                  # 18668
grep -cE '^-- [─═━]' compiler/types/typecheck.mdk                   # 75  banner sections
grep -nE '^ +checkBodyImpl ' compiler/types/typecheck.mdk           # 2   the spine's call sites
awk '/^data PerRun/,/^  \}/' compiler/types/typecheck.mdk \
  | grep -cE '^ +[a-z][A-Za-z0-9_]* *:'                             # 63  PerRun fields
grep -cE '^[A-Za-z_][A-Za-z0-9_]* = (Ref|newRef)' compiler/types/typecheck.mdk   # 9  loose cells
grep -cE '^import ' compiler/types/typecheck.mdk                    # 11  inbound seams
```

⚠️ **Each of those five is shaped the way it is to dodge a specific false answer.**
`/^  \}/` stops at `PerRun`'s *indented* closing brace — `/^\}/` runs past it into
`freshPerRun`'s record literal and returns 64. `^ +checkBodyImpl ` requires the
indented-application shape — a plain `\bcheckBodyImpl\b` with a comment filter returns 5
(two declaration lines plus a trailing comment inside the `PerRun` record). And the loose-cell
count must key on the **`= Ref` right-hand side**, never on a `: Ref ` signature (§0 trap 4).

> ⚠️ **Four traps this derivation hit.** Each produced confident, wrong output first.
> - A regex matching `data|type|impl|…` without a trailing `\s+` silently reclassifies
>   every function *named* `implMatchesReceiverU`, `dataEnvOf`, `typeOfX` as a declaration
>   of that kind. It hid **55 functions** and turned "1 dead function" into a fabricated
>   "25 dead functions" finding.
> - The section banners use **box-drawing** characters (`── `), not ASCII. An ASCII-only
>   grep reports *"this file has no section structure"*, which is false.
> - **A banner's API list can be aspirational.** The `RefinementDomain interface` banner advertises
>   *"dtop/dsub/djoin/dmeet/drender"*. Four of the five are real (`dsub` and `drender` are
>   exported wrappers over `dsubN`/`drenderN`; `dtop` ships as `dtopFor`) — but there is
>   **no `dmeet`** at all (see `docs/design/EFFECTS-CONFORMANCE-ROADMAP.md`: *"No
>   `dmeet`/⊥"*). The first draft copied the banner verbatim and asserted a function that
>   does not exist.
> - **`name : Ref T` is usually a FUNCTION, not a cell.** Counting module-level state with
>   `^name : Ref ` returns 38; only **9** are cells. The other 29 are functions whose first
>   *parameter* is a `Ref` — `tyvarId : Ref Tyvar -> Int`, `ppGo : Ref (…) -> … -> String`,
>   the whole `coh*` matcher family. The first draft counted all 38, inflating the state
>   universe from 118 to 147 and every per-subsystem cell figure with it.
>
> Traps 1 and 4 are **the same bug**: a pattern matching a prefix without validating the
> rest of the shape. It was committed twice in one derivation, the second time *after*
> writing trap 1 down. Match the whole form, or count the thing you actually mean
> (`= Ref` for a cell, never `: Ref`).

⚠️ **The doc gates will not catch these for you.** `make agent-doc-symbols` passed a
backticked `dmeet` that resolves nowhere in the source. Treat it as a floor, not proof.

**No line numbers, by policy.** This map describes code that is about to be changed — every
line number in it would be stale after the first refactor, and a stale line number is worse
than none because it looks authoritative. Every source reference here is a **grep anchor**:
a symbol name, or a distinctive comment phrase verified unique at the time of writing. If an
anchor stops matching, the code moved *and* something about it changed — which is exactly
the signal you want. This follows the convention #991–#995 already state: *"grep the symbol
names, not the numbers."*

---

## 1. The shape of the file

| | |
|---|---|
| Lines | 18,668 |
| Logical declarations | 1,478 — **1,443 functions**, 33 `data`, 2 type aliases |
| Exported | 70 (50 functions reachable as entry points) |
| Banner sections | 75 (**not** a valid partition — §2) |
| State cells | **118** — `PerRun` 63, `CrossRun` 25, `DriverState` 18, `Toggles` 3, loose module-level **9** |
| Functions touching any state | **244 of 1,443** — the other 1,199 are pure |
| Cells written from ≥6 functions | **7 of 118** |
| Inbound imports | 11 modules (§7.7) |
| Modules importing this one | 31 |
| Functions with no caller, hence unreachable | 1 (`wReset`) |

**Growth**, from `git`: 10,483 lines (2026-06-29) → 13,717 (07-14) → 17,008 (07-21) →
18,668 (07-29). Roughly +8,200 lines in a month, +1,660 in the last week.

Two of these contradict the received wisdom and are load-bearing for §7: **1,199 of 1,443
functions are pure**, and **only 7 of 118 cells have diffuse ownership**. The state problem
this file is famous for has been substantially *fixed*.

---

## 2. Why the 75 banner sections are not the architecture

A banner marks **where a feature was inserted**, and every declaration after it inherits
that label until the next banner. They are commit archaeology.

| Banner | Actually spans | Actually contains |
|---|---|---|
| *"the INDEX row unifier (#1094)"* | 1,594 lines, 92 decls | `CrossRun`, `pushDictApp`, `routeLocalSym`, `callOblsWindow` — none of them the index row unifier |
| *"non-exhaustive-match warning accumulator"* | 185 lines, 5 decls | the core `PerRun` state record and `freshPerRun` |
| *"Multi-param-interface element grounding (Shape A / gap #44)"* | 1,562 lines, 135 decls | the whole impl-method body driver, incl. `inferImplMethod` |
| *"Tarjan strongly-connected components (O(V+E))"* | 534 lines, 51 decls | the letrec drivers — **but not Tarjan**, which is imported from `compiler/support/scc.mdk` |

Use them to find *when* something arrived, never *what a region does*.

⚠️ **Any line count or symbol list in §4 that came from a banner rather than from the
declaration inventory is suspect** — this document's first draft inherited two such errors
(§9). Two Layer 1 rows still carry banner-span sizes, marked where they appear.

---

## 3. The state model

State is four bundle records plus **9** loose module-level `Ref`s. Each bundle is a **record
of `Ref`s** held in one cell, so a reset re-mints the record rather than clearing fields —
this is the #158/#176 design, and it landed.

| Bundle | Cells | What is in it | Reset by |
|---|---|---|---|
| `PerRun` | 63 | HM counters + level; the 8 `pending*` route channels; 4 `Windowed` obligation channels; the 5 `numlit*` defaulting cells; shadow tables; per-module registries | `resetState` re-mints via `freshPerRun` |
| `CrossRun` | 25 | 15 `universe*` accumulators, 6 `crossModule*` constraint tables (each a bare/`Qual` **pair**), 3 `obUniv*`, and `coreSchemeObligationsRef` | survives `resetState` by design |
| `DriverState` | 18 | driver-mode flags, the match oracle + warnings, promotion harvest, `main` scheme, dict-eligibility sets | survives; re-minted per driver entry |
| `Toggles` | 3 | dynamic-scope suppression flags (`suppressRLocalRecord`, `suppressArgStamp`, `shadowHeadCtxRef`) — save/restore around routing decisions | re-minted with `PerRun` |
| *(loose)* | **9** | the four bundle cells themselves (`perRun`, `crossRun`, `driverState`, `toggles`) + `typeErrorsSticky`, `useFastIfaceMethodTy`, `currentLoc`, `currentDoOrigin`, `currentMethodMismatch` | varies |

**The seven cells with no single owning function** (≥6 distinct writers) are the residual
state-discipline debt: `perRun` (56 writers), `driverState` (14), `currentLoc` (8),
`typeErrorsSticky` (8), `crossRun` (7), `toggles` (6), `funConstraintsRef` (6).

⚠️ Two granularities are mixed in that list: `funConstraintsRef` is a `PerRun` *field*, so
its writers are already inside `perRun`'s 56. Read it as "these are the cells a change is
most likely to desynchronize," not as a partition.

Two structures deserve naming because subsystems below are defined in terms of them:

- **`Windowed`** (`wNew`/`wPush`/`wMark`/`wWindow`/`wReset`/`wSnapshot`/`wRestore`) — a push-only channel with
  mark/window bracketing, replacing the old snapshot-and-subtract idiom. Four channels use
  it: `obls`, `implObls`, `dictApps`, `absorptions`. This is *how obligations are scoped to
  a body at all*.
- **The `pending*` family** — 8 channels (`pendingSites`, `pendingBinopSites`,
  `pendingUnopSites`, `pendingArithSites`, `pendingArgStamps`, `pendingMethodDicts`,
  `pendingRecDictApps`, `pendingRLocalSites`) recording dispatch sites during inference for
  a post-inference pass to resolve (§4 Layer 4a, §5).

`typeErrorsSticky` is **deliberately** outside every bundle and must stay there — it is
sound *because* it survives resets (§8).

---

## 4. The subsystem map

Gateways are derived by dominance: *owns* = functions reachable only through this gateway;
*cells* = distinct state cells touched by that whole subtree. Layers are mine; everything
else is measured. Rows without a gateway are clusters that share helpers and so dominate
nothing — their sizes come from the declaration inventory, not from banner spans.

### Layer 0 — Foundations (pure type machinery)

| Subsystem | Gateway | Owns / lines / cells | Spec |
|---|---|---|---|
| Union-find + unification | `unify` → `unifyN` | 31 / 403 / 9 | — |
| Generalization, instantiation | `generalize`, `instantiate` | small | DICT §4 `gen` |
| Value restriction | `eagerRefs`, `allEVars` walkers | ~125 lines | EFFECTS §6 |
| AST type → `Mono` | `fromAstTypeE` | 15 / 224 / 3 | — |
| Alias cycle detection | `rejectCyclicAliases` | — | — |
| Rendering | `ppScheme` | 54 reachable | — |

### Layer 1 — Effects, rows, and the capability lattice

| Subsystem | Gateway | Owns / lines / cells | Spec |
|---|---|---|---|
| Refinement-domain lattice | `dtopFor`, `dsubN`, `djoin`/`djoinN`, `drenderN` | ~200 lines | EFFECTS §2.1 |
| Effect-label domain registry | `effectDomains` (`DriverState`) | ~49 lines | EFFECTS §2.2 |
| **Axis-product lattice** | `productNorm`, `sortAxes`, `insertAxis`, `isSubTop`, `lookupAxis` | ~100 lines | EFFECTS §2 |
| **Capability written-syntax decoder** | `atomOfWritten`, `decodeSetParam`, `decodeProductParam`, `decodeAxis` + hand-rolled splitters | ~150 lines | EFFECTS §2.3 |
| **`IO` widening union alias (Stage 3)** | `decodeSetParam` region | 149 lines / 15 decls ⚠️banner-span | EFFECTS §3.2 |
| **Known-literal-prefix analysis α (Stage 2b)** | `alpha`, `kpLcp` | 102 lines / 10 decls ⚠️banner-span | EFFECTS §2.4 |
| Effect rows, atoms, propagation | `unifyRowN` | 124-line core | EFFECTS §2.4, §3, §5 |
| Undetermined return-position eff vars | `checkUndeterminedRetEffVars` | 15 / 179 / 2 | EFFECTS §6 |
| Interface-method effect checks | `checkIfaceMethodEffs` | 13 / 166 / 2 | EFFECTS §6 |
| Effect-param / letrec declaration checks | `checkEffectParams`, `checkLetRecDecls` | ~60 lines | EFFECTS §6 |

Open here: #797, #817, #825, #1095, #1098, #1100, #1103 — the densest S0 cluster in the
file. EFFECTS §6.7 names `unifyRowN`'s closed/closed arm at its exact line; §6 names
`checkArgEffVarCoverage` and `methodEffRetOccs`. See §7.2 for what that does and does not
imply.

### Layer 2 — Inference core

| Subsystem | Gateway | Owns / lines / cells | Spec |
|---|---|---|---|
| Expression inference (25-arm walk) | `infer` | **298 / 4,302 / 57** | — |
| Application inference | `inferAppExpr` | 58 / 991 / 19 | — |
| Method occurrence typing | `inferMethodAt` | 18 / 300 / **18** | DICT §5 |
| Match inference | `inferMatch` | 17 / 182 / 4 | — |
| Binop/unop inference | `inferBinopE` | 13 / 195 / 7 | — |
| Let-group inference | `inferLetGroup`, `processLetGroup` | 30 / 337 / 6 | — |
| Pattern inference | `inferPat` | ~140 lines | — |
| **Numeric-literal defaulting** | `setNumlitFloats`; `recordNumlitLoc`, `markNumlitOpTaint`, `noteNumlitCtx`, `tagNumlitCtxIf`, `unifyAllNumlit` | ~220 lines / **5 cells** | **none** |

**Numeric-literal defaulting is semantic, not cosmetic.** `setNumlitFloats` writes each
`ENumLit`'s `Ref (Option Float)` after HM completes — it decides the runtime representation
of every integer literal. It runs at three sites, and **its ordering relative to
`checkCallObligations` differs between the Flat and Module paths** (grep
`setNumlitFloats-vs-checkCallObligations`). The taint machinery (`numlitUntainted`,
`numlitOpLocs`) has a documented O(n²) history.

### Layer 3 — Letrec scheduling

| Subsystem | Gateway | Owns / lines / cells | Spec |
|---|---|---|---|
| Dependency-ordered SCC processing | `processTopGroups` → `processSCCs` → `processSCC` | 86 / 918 / 26 | DICT §4 `gen-rec` (group sharing only) |
| Data registration | `registerAllData` | 18 / 175 / 6 | — |

⚠️ **Tarjan's algorithm is NOT in this file** — `tarjanSCCs` is imported from
`compiler/support/scc.mdk` (90 lines). The banner claiming otherwise is the §2 trap.

DICT §4 `gen-rec` fixes what a mutually-recursive group must *share* (one `λd̄.` prefix, no
fresh entailment at recursive occurrences). **The order in which groups are scheduled, and
what a later group may observe of an earlier one's generalization, is unspecified.**

### Layer 4 — Dispatch and dictionaries

| Subsystem | Gateway | Owns / lines / cells | Spec |
|---|---|---|---|
| **Entailment engine** | `entail` → `entailInst` | 49 / 620 / **5** | DICT §3 |
| Obligation checking | `checkCallObligationsU` → `checkOneCallObligation` | 43 / 524 / 8 | DICT §3, §4 |
| **Obligation channels** | `Windowed` ops over `obls`/`implObls`/`dictApps`/`absorptions` | 7 ops, 4 channels | DICT §4 |
| Impl method bodies | `inferImplBodies` → `inferOneImpl` → `inferImplMethods` → `inferImplMethod` | 22 / 495 / 11 | DICT §3 **W3**, §4 |
| Default method bodies | `inferDefaultBodiesIfEnabled` → … → `inferDefaultMethod` | 12 / 260 / 9 | DICT §3 **W3**, §4 |
| Dictionary insertion | `dictPass` → `dictPassDecl`, `implDictPassMethods` | 37 / 368 / 2 | DICT §4 |
| **Superclass-evidence expansion (WS-1b)** | `expandSupersTable` | ~100 lines owned | DICT §3 `super` |
| Arg-position AST prepass | `prePassDictArg`, `prePassDeclScoped`, `rewriteArgScoped` | 23 / 269 / **0** | SHADOW §1 (S1, S9), §3; DICT §5 |
| **D3a arg-position dispatch stamping** | `argDispatchIndices` | ~190 lines / 4 cells | DICT §5 |
| Per-run dispatch indices | `buildImplTable`, `buildKeyTable` | ~95 lines | — |
| Cross-run impl-key registry | `univConcreteBucket`, `univHeadless` | ~144 lines | DICT §6 C4, §8 I2 |
| Specificity selection | `selectImplEntryByIface`, `pickMostSpecificEntry`, `tySubsumesV`, `matchStep` | ~660 lines | DICT §3 `inst` |

`entail` at 620 lines touching only **5** cells is the best-encapsulated non-trivial
subsystem in the file — the #156 work succeeded. The impl/default fork is the **#992** shape:
two gateway chains, one judgment.

**Two distinct things are both called "arg position."** The *prepass* rewrites `EVar` →
`EMethodAt` in the AST (scope-aware, shadow-guarded). *D3a stamping* computes which
argument position discriminates dispatch for each interface method. They are unrelated
mechanisms sharing a name.

### Layer 4a — Route resolution (the collect-then-patch pass)

**No prior document describes this subsystem, and it is where dispatch is actually decided.**
Inference does not resolve dispatch; it *records sites* into the 8 `pending*` channels
(§3). After inference returns, an ordered sequence of stampers drains each channel, picks
the impl, and writes a `Route` back into the AST's `Ref Route` cells.

| Stamper | Drains | Spec |
|---|---|---|
| `resolveSites` | `pendingSites` (return-position method sites) | DICT §5 |
| `resolveOpSites` (binop / unop) | `pendingBinopSites`, `pendingUnopSites` | DICT §5 |
| `resolveArithSites` | `pendingArithSites` | DICT §5 |
| `resolveArgStamps` | `pendingArgStamps` | DICT §5 |
| `resolveRLocalSites` | `pendingRLocalSites` | DICT §5 |
| `realizeRecDictApps` | `pendingRecDictApps` | DICT §4 `gen-rec` |
| `resolveDictApps` | `dictApps` | DICT §4 |
| `resolveMethodDicts` | `pendingMethodDicts` | DICT §4 |

**The order is semantic and the two paths disagree** — see §5.

| Subsystem | Gateway | Size | Spec |
|---|---|---|---|
| **RLocal / local-binding dict pinning** | `recordRLocalSite`, `resolveRLocalSites`, `routeLocalSym`, `pinnedLocals`, `localBindRefs` | ~440 lines / 4 cells | DICT §4 `var` |

#1040, #1052 (S0) and #1043, #1082 (S1) all live in RLocal pinning.

### Layer 5 — Global checks

| Subsystem | Gateway | Owns / lines / cells | Spec |
|---|---|---|---|
| Coherence | `cohScan` → `cohScanInner` → `cohClassify` | 18 / 167 / **0** | DICT §6 C1–C4 |
| Final-check driver | `runFinalChecks` | 22 / 231 / **0** | — |
| Signature-constraint soundness | `checkSigConstraintCoverage` → `checkSigConstraintOne` | 25 / 218 / 3 | — |
| Signature-too-general | `checkSigTooGeneral` | ~98 lines | — |
| Cyclic superinterface detection | dedicated walk | ~190 lines | DICT §3 **W1** |
| Superinterface existence | dedicated walk | ~35 lines | DICT §3 |
| Impl completeness / phantom methods | two walks | ~169 lines | **none** |
| Interface type-parameter kinds | `checkGradedImplHeads` | ~195 lines | EFFECTS §6.1–§6.5 |
| **Field resolution + record registry** | `resolveFieldRecord`, `collectAbstractRecordTypes`; cells `recordByNameRef`, `fieldOwnersRef`, `abstractRecordTypesRef` | ~410 lines / 3 cells | **none** |

⚠️ DICT §6 is C1–C4 (unique most-specific instance, superclass consistency, resolution
determinism, one instance environment). **It does not require an impl to define every
method, nor reject a method absent from the interface** — those checks have no spec.

⚠️ `recordByNameRef`'s `omInsert` is **last-write-wins on a bare type name** (grep
`recordByNameRef : registry KEY`) — the same cross-module hazard as §7.3.

### Layer 6 — Shadowing (standalone fn ⇄ interface method)

| Subsystem | Gateway | Owns / lines / cells | Spec |
|---|---|---|---|
| Definer-side shadow application | `inferDefinerShadowApp` | 4 / 179 / 10 | SHADOW §1 (S1–S8) |
| Importer-side / S-1 machinery | `inferShadowApp`, `inferDefinerStandaloneVarApp` | ~730 lines | SHADOW §1 (S2 importer arm, S9) |

This is the one subsystem with a **per-clause enforcement table** already written
(SHADOW-SEMANTICS §3: clause → site → keying assumption). It is the model the other layers
lack. (SHADOW §6 is a *residuals bug list*, not governing semantics — do not cite it as one.)

### Layer 7 — Drivers, promotion, and cross-module

| Subsystem | Gateway | Owns / lines / cells | Spec |
|---|---|---|---|
| **The spine** | `checkBodyImpl` | **835 / 10,917 / 110** | — |
| **Promotion fixpoint** | `discoverAll` → `discoverPromoted` → `discoverNext`; `discoverPromotedModules` for the whole graph | ~175 lines + 2 banner regions | — |
| Inferred-constraint registration | `registerInferredConstraints`, `setDictEligible` | ~204 lines | DICT §4 `gen` |
| Per-module fold | `foldModules` | 10 / 201 / **0** | — |
| Multi-module check drivers | `checkModules`, `checkModuleFullImpl`, `checkProgramSeededSplit` + the `check*` tails | ~590 lines | — |
| Typed elaboration | `elaborateModules` → `elabHarvestWorker` → `elabWorker` → `elabModuleStamp`; `elaborateDict` | 53 / 892 / 30 | DICT §4, §8 |
| Cross-module universe marshalling | `loadDataUniverse`, `storeDataUniverse`, `appendUniverseAccums` — ⚠️ **derive the cell counts from the three bodies, never from this table**: it said `14`/`14`/`11`, and #1512 slices 1–3 plus #1557 A-3.5c retired cells out of the first two inside four days | 3 fns | DICT §6 C4, §8 I2 |
| Import seeding / aliasing / ctor overlay | `importFormSchemes`, `aliasSchemes`, `aliasConstraintEntries` | ~370 lines | DICT §8 I2 |

### Layer 8 — Diagnostics and error-path analysis

| Subsystem | Gateway | Size | Spec |
|---|---|---|---|
| Type-error accumulator | `pushTypeError` family; cells `typeErrors`, `typeErrorsSticky` | ~175 lines | — |
| Structured diagnostic | `tcCode`, `tcLoc`, `tcMsg`, `tcHelp`, `tcFix` | ~39 lines | `compiler/DIAGNOSTIC-CODES-DESIGN.md` |
| Exhaustiveness bridge | `checkMatchToLines`; cells `matchOracle`, `matchWarnings` → `compiler/frontend/exhaust.mdk` | ~185 lines | — |
| Unreachable-arm warning | `W-UNREACHABLE-ARM` walk | ~147 lines | — |
| **Num mis-framing provenance** | banner-scoped, error-path only | ~446 lines | `compiler/ERROR-QUALITY.md` |
| **Cascade suppression** | `poisonMismatchVars`; cell `poisonedVars` | 5 call sites (`:3489` `:5581` `:7715` `:7716` `:7762`), consumed at `:13926` | — |
| **Message construction surface** | 59 `*Msg`/`*Hint`/`*Explain`/`*Suggest` functions | ~525 lines | `compiler/ERROR-QUALITY.md` |

**Error-path-only machinery is roughly 1,050 lines / ~96 functions** — about 9% of the
file, not the ~3% the accumulator rows alone suggest. It has distinct invariants (fires
only on failure; must not perturb inference; needs cascade suppression) and is the
safest extraction candidate in the file (§7.4).

> ⚠️ Two corrections, issue 1147 — and the second is the reason to re-derive these
> numbers rather than trust them. (1) A **Swapped-argument detection** row
> (~145 lines, 14 functions) stood here until the whole hint was deleted; the totals
> above are the old 1,200/~110 minus that row. (2) The cascade-suppression row said
> *"~8 read sites"*; the deletion removed exactly ONE `poisonMismatchVars` call, and a
> recount then found **5**, not 7 — so that figure was already wrong before this change.
> Neither number had a derivation attached, which is why both drifted unnoticed. The
> row now carries the call sites themselves, so the next reader can check it in one grep.
> ⚠️ Also note the invariant sentence above ("fires only on failure; must not perturb
> inference") was FALSE of the deleted component — it ran on the success path of every
> two-argument application whose last argument was a literal. Measured at 3.2% and 1.2%
> of application nodes, with no observable effect; still, the invariant was aspirational,
> not enforced. Nothing enforces it for the remaining rows either.

---

## 5. Control flow: the spine is not linear

### 5.1 The driver stack above `checkBodyImpl`

**It is a bare sweep with a conditional fallback, not a fixpoint wrapped around a sweep.**

```
elaborateModules
  │
  ├─ BARE SWEEP (always)
  │    foldModules elabHarvestWorker → elabWorker → elabModuleStamp
  │      → checkModuleFullImpl → checkBodyImpl (Module …)   ← resetState at module START
  │
  └─ match promotionHarvestRef
       [] → the bare sweep IS final — one whole-program typecheck (the #194 win)
       _  → DISCARD it; resetCrossModuleState, then the 2-pass path:
              discoverPromotedModules              ← FIXPOINT, over a FLATTENED joint program
                → discoverPromotedJoint → checkProgramSeeded
                  → checkProgramSeededSplit → checkBodyImpl (Flat …)
              then a second real marking sweep with the promotion-augmented dict set
```

Three things this shape makes true that a linear reading does not:

- **The fixpoint is conditional.** It runs only when at least one function was *directly*
  promoted. On the common path it never runs at all.
- **It re-enters `checkBodyImpl` in `Flat` mode**, over a flattened joint program — not in
  the `Module` mode the sweep above it uses. The two modes are both live within one
  `elaborateModules` call.
- **The bare sweep's results are thrown away** when the harvest is non-empty, because call
  sites unmarked under `bareDict` are unsound to keep once a callee is promoted.

`foldModules` calls the worker **head-first**, so `elabHarvestWorker` reads a module's
promotion set before the recursion into `rest` resets it (grep `Timing: elabModuleStamp`).

### 5.2 `checkBodyImpl` itself

One function, 347 lines, **two call sites** — one `Flat`, one `Module` (§0's third
command locates both). It
dominates **835 functions / 10,917 lines — 58% of the file — and 110 of 118 state cells
(93%)**. It directly touches 46 cells.

It opens with `resetState ()` and is parameterised by
`data CheckMode = Flat (List Decl) | Module String (List Decl) (List Decl)`. The author's
own numbering (`#1`–`#6`, **three** `BREAK` points) marks the phases:

```
resetState → stampBindingIds → decl universes (#1) → superDecls (#6)
  → effect domains          ← [BREAK #3] Flat populates inline; Module relies on the driver
  → checkEffectParams / checkLetRecDecls → shadows (#4) → mode-specific ref setup
  → dataEnv → checkUndeterminedRetEffVars → checkGradedImplHeads → rejectCyclicAliases
  → globalS = ifaceMethodSchemes ++ externSchemes → env1
  → processTopGroups            ← [BREAK #1] inference plan; Flat is two-phase
  → cross-module dict snapshot (#3, Module only)
  → groundMultiParamObligations
  → obligation gate (#5)        ← [BREAK #2] incl. setNumlitFloats, ordered differently per mode
  → localSchemesOut / seedSchemesOut
```

(`stampBindingIds` is not local — the spine calls out to `compiler/frontend/resolve.mdk`.)

⚠️ **This sequence is ONE ITERATION, not the control flow.** On the eligible-name path the
promotion fixpoint re-enters it until the dict-passed set stabilizes: *"a mark+typecheck
pass discovers each eligible unsignatured fn's inferred constraints; we grow the
dict-passed set and re-run until it stabilizes"* (grep `re-run until it stabilizes`). Any
perf or ordering argument
built on "linear phase sequence" is wrong by a factor of the fixpoint depth.

**`Flat` vs `Module` bimodality is threaded through 20 `match mode` branches inside this
one function** — the #992 fork shape, one level up and unfiled.

### 5.3 The stamper sequence after it — where order is semantics

The two elaboration paths run **different stampers in different orders**:

| # | `elaborateDict` (Flat) | `elabModuleStamp` (Module) |
|---|---|---|
| 1 | `resolveSites` | `resolveSites` |
| 2 | `resolveOpSites` (binop) | `resolveOpSites` (binop) |
| 3 | `resolveOpSites` (unop) | `resolveOpSites` (unop) |
| 4 | `resolveArithSites` | `resolveArithSites` |
| 5 | `realizeRecDictApps` | **`resolveArgStamps`** |
| 6 | `resolveDictApps` | **`resolveRLocalSites`** ← absent on Flat |
| 7 | `resolveMethodDicts` | `realizeRecDictApps` |
| 8 | **`resolveArgStamps`** (last) | `resolveDictApps` |
| 9 | — | `resolveMethodDicts` |

**8 stampers vs 9.** `resolveRLocalSites` runs only on the Module path. `resolveArgStamps`
is last on Flat but fifth on Module. The source states the ordering is semantic — C5
requires `resolveRLocalSites` to run *after* `resolveSites` and `resolveArgStamps` so the
receiver-grounded route overrides what those stamped on the **same ref** (grep
`C5: LAST among the route-stampers` — whose own wording is stale: it is 6th of 9).

This is the sharpest instance of "order is semantics" in the file, and it is where
#1040/#1052/#1082 live.

---

## 6. Open issues, by subsystem

⚠️ **Derived by subsystem, not by label.** An earlier draft queried `ws:typecheck` only and
missed two open S0s sitting in subsystems mapped here. Follow the code, not the label.

| Subsystem | Open |
|---|---|
| Effects / rows | #797, #817 (S0), #825 (S0), #1095 (S0), #1098 (S0), #1100 (S0), #1103 (S0) |
| Cross-module registries | #1069 (S0), #1070 (S0 umbrella), #1092 (S0), **#1047 (S0, `ws:soundness`)**, #1090 |
| RLocal / local dict pins | #1040 (S0), #1052 (S0), #1043 (S1), #1082 (S1) |
| Specificity selection | **#1072 (S0, `ws:emitter`)** — most-specific-wins decided by module order |
| Obligations | #323, #563, #564, #792, #845, #991 |
| Coherence | #311, #614, #679 |
| Method rigidity / signatures | #819 (S1), #830 |
| Shadow / import overlay | #733, #756 |
| Superclass evidence | #741, #993 |
| Architecture (07-24 review) | #991, #992, #993, #994, #995 |
| Graded interfaces (planned arc) | #820, #821 |
| Hygiene | #176, #462, #480 |

---

## 7. What the map actually shows

**1. The state problem is largely solved; the *control-flow* problem is not.**
1,199 of 1,443 functions are pure and only 7 of 118 cells have diffuse ownership — #158/#176
worked. But one function dominates 58% of the file and **93%** of the state, is re-entered to a
fixpoint, and is followed by a 9-step ordered stamper pass that differs between the two
paths. `ARCH-REVIEW.md` diagnosed "a god module with concentrated mutable state" and the fix
addressed the state half. **No open issue names what is left.**

**2. The densest S0 cluster sits in the layer whose spec coverage is narrative, not tabular.**
Effects (Layer 1) carries 6 of the 11 open `ws:typecheck` S0s. EFFECTS-SEMANTICS *does* cover
this machinery — §6.7 names `unifyRowN`'s closed/closed arm at its line, §6 names
`checkArgEffVarCoverage` and `methodEffRetOccs`, §10 maps gaps to clauses. What it lacks is
SHADOW §3's **clause → site → keying-assumption table**. Every one of these S0s is a
keying/site question, which is exactly what such a table catches. Layer 1 is in fact the
best-*cited* layer in §4 — the deficit is structural form, not absence.

**3. The cross-module S0s are two different problems, and only one has a clause.**

- **#1092 is a genuine spec violation** — of DICT §8 **I2** ("method projection uses the
  resolved class") and §5, not I1. `methodIfaceParamsRef` keys method→interface by bare
  method name, so projection does not use the resolved class.
- **#1069 and most of #1070 are UNDER-specified.** DICT §8's own preamble scopes it to
  *bindings* and *dictionary discipline*; I1 is about the count/order/predicates of
  dictionary parameters. Kind registries and type/alias/record name tables are neither.
  **No clause in any spec grants type, alias or record names module-qualified identity** —
  and `compiler/backend/private_mangle.mdk` never qualifies them either. That is a missing
  rule, not an unenforced one.

  **Interface names are the partial exception.** I2 requires *"qualified instance
  identity"*, and an instance is identified by (class, head) — so a clause the engine must
  already satisfy is unattainable if class names collapse across modules. **#1047** (two
  unrelated `interface Speak`s merging) is therefore reachable from I2, unlike #1069.
  Interfaces sit between the two cases: specified indirectly, never specified directly.

  This matters for how the work is sized. Filed as "specified but unenforced" it looks like
  plumbing; filed correctly it is **a spec paragraph plus one whole-graph check that
  self-drains five S0/S1s** — which is what #1070 itself recommends.

**4. Four subsystems are already pure, and the safest extractions are the error-path clusters.**
`prePassDictArg`, `runFinalChecks`, `foldModules` **and coherence** (`cohScan`, 18
functions / 167 lines) touch **zero** state cells — coherence only looks stateful if you
miscount its `coh*` helper signatures as cells (§0 trap 4).

But purity is necessary, not sufficient: this file imports `mangledName` from
`compiler/backend/private_mangle.mdk`, so a "pure ⇒ extractable" argument must clear the
seam list (§7.7) as well as the state graph. The
~1,200 lines of error-path machinery (Layer 8) are a stronger candidate: they fire only on
failure, must not perturb inference, and have no inbound dependency from the inference core.

**5. `entail` is the proof the target shape works.** 620 lines, 49 functions, 5 state
cells, one gateway. The #156 consolidation produced the file's best-encapsulated subsystem.
Measure whatever is done next against it.

**6. Where a spec is owed.** Per the standing gate's question 2, "no formal semantics
exists" is a finding:

- **Cross-module identity of type / alias / record / interface names** (§7.3) — the
  highest-value missing rule; five S0/S1s hang off it.
- **Letrec scheduling order** — `gen-rec` fixes what a group shares, nothing fixes the order
  groups are scheduled in or what a later group may observe.
- **Numeric-literal defaulting** — decides runtime representation, ordered differently per
  path, wholly unspecified.
- **Impl completeness and phantom-method rejection** — enforced, never specified.
- **The `Flat`/`Module` bimodality** — `compiler/DRIVER-COLLAPSE-PLAN.md` is marked
  **IMPLEMENTED** and asserts the flat path is the degenerate 1-module case whose invariants
  are automatically satisfied. §5 measures 20 `match mode` branches, two `BREAK` points, and
  two divergent stamper orders. **A stated invariant with a measured counterexample.**

**7. The seams, inbound and outbound.** 11 modules are imported; 31 import this one. Four
edges constrain refactors and none was named before:

| Edge | Why it matters |
|---|---|
| → `backend/private_mangle.mdk` (`mangledName`) | typecheck depends on the **backend**; bears on §7.4 and on §7.3 (it is what does *not* qualify type names) |
| → `support/scc.mdk` (`tarjanSCCs`) | Tarjan is not in this file (§2) |
| → `frontend/marker.mdk` (`localBoundNames`) | marker produces `EMethodRef` — this file's **input contract** |
| ← `tools/lsp.mdk` (`currentLocalSchemes`, `currentSeedSchemes`) | the LSP reads `PerRun` state **after** a run completes, so `localSchemesOut`/`seedSchemesOut` are a **live external contract on reset timing** |

Also: `driver/diagnostics.mdk` consumes `checkProgramDiags`/`checkModulesDiags`/
`entryOwnSchemes`/`setCoherenceUserDecls`; `ir/` reaches this file only through
`elaborateModules`/`elaborateOne`, which is the whole typed-Core-IR boundary.

---

## 8. Settled — do not relitigate

- **The HM-core / dispatch file split was evaluated and REJECTED** (`ARCH-REVIEW.md` PASS 2:
  *"Do NOT attempt the HM-core/dispatch file split"*). Dispatch state is read at `infer`
  depth across the 25-arm walk. Re-proposing it needs new evidence, not a fresh opinion.
- **Order-sensitive scans must not be perturbed by a refactor.** Reverse-declaration-order
  scanning, first-match lookup and prepend-wins are *oracle-matching behaviour*. Golden drift
  from a map-ification means *"I changed semantics,"* never *"refresh the goldens."*

  ⚠️ **This is a change-control rule, NOT an endorsement.** Two order dependencies are
  **defects, not settled behaviour**: impl selection by declaration/module order contradicts
  DICT §3 (*"never of search order, declaration order, or resolution position"*) and C3, and
  is open as **#1072 (S0)**. Do not cite this bullet to defend it.
- **Effect rows are transparent in matching on purpose** (EFFECTS §8, the single-meaning
  law). Coherence, subsumption and dispatch matching strip `TEff` by design.
- **`typeErrorsSticky` stays outside every state bundle, permanently.** It is sound because
  it survives resets.
- **The `pending*` deferred-mutation cells are essential, not accidental.** A method site's
  route depends on which tyvar survives unification, knowable only post-inference. Bundle
  them; never try to eliminate them.
- **52 cells deliberately survive `resetState`.** It re-mints only `perRun` and `toggles`
  (118 − 63 − 3), so every `CrossRun`, `DriverState` and remaining loose cell persists.
  Clearing one "for hygiene" reproduces the Phase-134 dropped-dict bug. *(Prior docs say
  "~37" — that is `97 − 60` from issue #158's title, an artifact of the old inflated Ref
  count, not a measurement.)*
- **Hot helpers stay monomorphic and short-circuiting** — delegating to prelude `Foldable`
  methods measured +56% self-compile.

---

## 9. Corrections to prior documents

| Document | Claim | Status |
|---|---|---|
| `compiler/ARCH-REVIEW.md` | "6,916 lines; 48 top-level `Ref`s" | Historical (2026-06-14). Now 18,668 lines / 118 cells across 4 bundles + 9 loose. |
| `compiler/ARCH-REVIEW.md` | status banner: "still one ~13k-line file" | Stale — 18,668. |
| `compiler/ARCH-REVIEW.md` | "a 7k-line god-module with concentrated mutable state" | **Half fixed.** State is bundled; the concentration is now control-flow (§7.1). |
| `.claude/workstreams/TYPECHECK.md` | "13,717 lines / 97 `Ref`s at `db33eeab`" | Line count correct; `db33eeab` is dated **2026-07-14**, not 07-15, and the genuine cell count there is **95**, not 97 — the same `: Ref ` over-count (§0 trap 4). |
| This document, §2 | the 75 banners describe their regions | False — they are insertion markers, and §4 inherited two of their errors before review. |

**Corrections this document made to itself** (first draft → reviewed), recorded because the
same three failure modes are available to the next reader:

1. **The state-cell universe was 147; it is 118.** 29 "cells" were function signatures
   taking a `Ref` parameter (§0 trap 4). This propagated into every per-subsystem cell
   figure — 14 of 25 were wrong — and into two §7 conclusions. Both erred in the
   document's own favour: the spine holds **93%** of the state, not 83%, and coherence is
   **pure**, making it a fourth free extraction the draft had hidden from itself.
2. **DICT §8 I1 was cited for defects it does not govern.** Pattern-matched on the phrase
   *"never by its bare name"* instead of reading the clause's subject (dictionary
   parameters). Corrected in §7.3 — and the corrected finding is the more actionable one.
3. **Tarjan and `dmeet` were taken from banners.** Both wrong; both caught by re-derivation,
   not by the doc gates (§0).
4. **"~37 cells survive `resetState`" was copied, not measured** — it is `97 − 60` from
   issue #158's title. The real figure is 52. A status banner claiming everything was
   derived does not make it so.
5. **The issue table was scoped by label, not by subsystem.** Missed #1047 and #1072.
6. **Three of the §0 re-derivation commands returned the wrong numbers** — 64 for 63, 5 for
   2, and `grep -c '^import'` returning **44** because it matched functions named
   `importedBindings` and `importerShadowDomain`. A recipe that does not reproduce its own
   results is worse than none.
7. **The §5.1 driver stack was drawn as a fixpoint wrapped around the module sweep.** It is
   a bare sweep with a *conditional* fallback, the fallback re-enters `checkBodyImpl` in
   **`Flat`** mode, and on the common path it never runs. Corrected in §5.1.
8. **`§7.3` over-corrected once the I1 citation was withdrawn**, sweeping interface names in
   with types and aliases. I2's "qualified instance identity" does reach them (#1047).

The pattern across 1, 3, 6 and the import miscount: **every one was a shape-matching
shortcut that produced a plausible number, and not one was caught by a gate.** The prefix
bug alone appeared three times — `data|type|impl`, `: Ref`, `^import` — twice *after* being
written down as a trap. Only re-derivation caught any of them.

---

## References

- `docs/spec/DICT-SEMANTICS.md` — §3 entailment (W1, W3, `inst`), §4 elaboration (`gen`,
  `gen-rec`, `var`), §5 dispatch, §6 coherence C1–C4, §8 identity I1–I3
- `docs/spec/EFFECTS-SEMANTICS.md` — §2 rows and domains, §3 judgment, §5 no-laundering,
  §6 polymorphism and kinds (§6.1–§6.5, §6.7), §8 erasure, §10 conformance gaps
- `docs/spec/SHADOW-SEMANTICS.md` — §1 clauses S1–S9, §3 per-stage enforcement table
- `compiler/DRIVER-COLLAPSE-PLAN.md` — the Flat/Module collapse invariant (§7.6)
- `.claude/workstreams/TYPECHECK.md` — the standing gate, duplicate-family map
- `compiler/ARCH-REVIEW.md` — PASS 1/2 prior review
- `compiler/ERROR-QUALITY.md` — the rubric governing Layer 8's error-path machinery
