# Emitter Target Architecture - one semantic plan, two physical lowerings

**Status:** REVISED 2026-09-03. The design laws (section 1) are in force; the
V/ANF/AP migration plan is SUPERSEDED by the REVISION block below (R1-R10),
which grows Core IR into the contract one fact at a time.
Designed from `docs/spec/EMITTER-SEMANTICS.md`,
`docs/spec/WASM-SEMANTICS.md`, `docs/spec/DICT-SEMANTICS.md`,
`docs/spec/EFFECTS-SEMANTICS.md`, and `docs/spec/SHADOW-SEMANTICS.md`, informed
by the current map in [`EMITTER-ARCHITECTURE.md`](EMITTER-ARCHITECTURE.md).
The issue-level fit is
[`EMITTER-ARCH-BUG-FIT.md`](EMITTER-ARCH-BUG-FIT.md).
Cross-backend tracking: #1398.

**Normative provenance.** `EMITTER-SEMANTICS` and `DICT-SEMANTICS` are
theory-first target specifications; `WASM-SEMANTICS` is the physical/host
supplement to the shared emitter laws; `SHADOW-SEMANTICS` is enforced by its
decision-matrix gate. `EFFECTS-SEMANTICS` is explicitly idealized: its complete
manifest law is the target contract, not a claim that every parameter domain is
already implemented. V cannot be minted from a row whose required extraction or
soundness checks are still pending.

**Scope.** This design covers the contract from elaboration to executable
native/Wasm output, including shared lowering, physical planning, emit state,
linkage, runtime capabilities, and validation. It does not take ownership of
type inference, instance selection, or namespace resolution. It states the
facts those stages must publish and coordinates with
[`TYPECHECK-TARGET-ARCHITECTURE.md`](TYPECHECK-TARGET-ARCHITECTURE.md) rather
than implementing a second version in the backend.

**What this is not.** It is not a big-bang rewrite, a shared physical IR, a
promise that sharing code proves semantics, or an instruction to wait for the
typechecker arc. Development, review, and non-conflicting design/test work can
proceed in parallel; compiler-source landing is serialized through the repo's
one-PR golden lane. Semantic consumers wait only for their specific upstream
facts, not for the entire typechecker epic.

## REVISION (2026-09-03) - laws kept, migration plan replaced

**Adopted (Val, 2026-09-03, on the review's recommendation).** The eight design laws in section 1 stand. The
migration plan that was meant to reach them (sections 2, 4-8, and 12: an opaque
`ValidSemanticProgram`, a canonical ANF, a validated ANF plan, two physical
plans, two pure renderers, all gated on typechecker producers) is replaced by
the plan in R3-R9 below. Sections marked SUPERSEDED are retained as the record
of what was proposed and why; they are not the plan. Section 3's producer
table is amended in place by R8. This revision was prepared by the 2026-09-03
review of the epic against the source tree at `7132909b7`, the live tracker,
and the revised typechecker plan (`TYPECHECK-TARGET-ARCHITECTURE.md` SURVEY
AMENDMENT and RULED blocks, rulings 1-8).

### R1. Why the plan changed

Every claim below was re-derived on 2026-09-03; the commands are the evidence.

- **The hygiene band is finished; the architecture band never started.** Both
  emitters and the lowering stage hold zero module-level `Ref` cells
  (`grep -c "^[a-zA-Z_][A-Za-z0-9_']* *: *Ref " compiler/backend/llvm_emit.mdk
  compiler/backend/wasm_emit.mdk compiler/ir/core_ir_lower.mdk` reads `0 0 0`),
  and `test/wasm/diff_wasm_typed.sh` pins the Wasm set at empty. Roughly twenty
  merged PRs did that (X-N.H, X-W.H1-H2b, `emit-inputs`,
  `emit-state-injectivity`, `lowering-stage-hygiene`). Nothing else exists:
  `grep -rn "ValidSemanticProgram\|CallableId\|CallShape\|LinkId" compiler/`
  finds only comments saying "deliberately not this" and the draft's own
  pending-fact markers.
- **The producers X-0V waited on are gone or unscheduled.** #1113 closed with
  its emitter-facing leg (B-2.4) cut back to X-E by owner ruling. #1137's named
  class was drained by an emitter sprint (`call-arity-conformance`, PR #2061)
  and its owner recommends routing the residual to this arc. #1318 was folded
  into #2547 unit 3. #1112 (A-3 dispositions), #993 (B-1), #1082 (F-1), and
  #353 have no step in the revised typechecker order. See R8.
- **Two typechecker rulings contradict the old stage design.** Ruling 4 keeps
  `RNone` runtime narrowing as a pinned optimization, which section 4.3's
  `MethodDisposition` and section 4.6 item 7 cannot represent; ruling 3 defers
  whether the emitter process runs resolve at all, while X-I assumed
  `private_mangle` renders resolver decisions. Neither doc knew about the
  other's change.
- **The seam the typechecker plan declares invariant is Core IR, not V.** The
  largest typechecker move (#2549, evidence as bindings) leaves the emitters
  alone because they read `Route` as data on `CMethod`/`CDict`
  (`TYPECHECK-TARGET-ARCHITECTURE.md`, SA-4 step 7). That seam is stable across
  all eight typechecker steps and is the one this arc builds on.
- **Bugs drained without the stages.** Of the roughly seventy open S0/S1 rows
  `EMITTER-ARCH-BUG-FIT.md` classified on 2026-08-07, at least forty-five have
  closed, almost all through targeted sprints (`call-arity-conformance`,
  `predicate-slots`, `ctor-identity`, `unmask-arg-tag-dispatch`), one through
  the ledger's own carve-out (#1072). Fifty of the seventy-two S0/S1 issues open
  today postdate the ledger. The stage predictions were bypassed, not tested.
- **Reconstruction below Core kept growing while the epic waited.**
  `methodArityOf` became a five-function family on each backend between
  2026-08-21 and 2026-08-27; `backend/wasm_reach.mdk` added a second
  whole-program reachability pass on one backend; `lowerProgramEmit` grew an
  `EmitTarget` parameter that threads a physical fact (tag width) up into the
  shared seam, against L4. Eighty-nine named LLVM/Wasm twin functions exist,
  forty of them in dispatch, evidence rewriting, arity, and impl indexing.
- **Cost.** Three new representations (V, ANF, AP) plus an ANF interpreter, a
  second S-expression form, an equivalence chain, and a plan-and-renderer split
  of 26,000 lines of emitter, in a self-hosted compiler where every new module
  perturbs the seed and the fixpoint, with no open issue drained by any of it
  before the last stage.

### R2. What is kept

- Laws L1-L8 (section 1), unchanged.
- Separate physical backends (L4, section 6.1, section 9): the boundary is
  semantic versus physical, and no shared physical representation is proposed.
- Per-emission state (`Emit`, `WasmEmit`, `EmitInput`, `WasmEmitInput`) and the
  ratchets that pin it. This is done; do not reopen it.
- The collision validators landed under X-L.H (`symbolInjectivityGuard`,
  `implSymbolCollisionGuard`, `dictWitnessTagGuard`).
- The verification doctrine (section 13), with 13.3's malformed-plan tests
  re-pointed at the Core validator in R6.
- `draft_semantic_program.mdk`'s `pendingFacts` list as the inventory of what
  Core still lacks (R4 is that list, re-ordered by open-bug pressure). The
  module itself is subject to R9's consumer-or-delete rule.

### R3. Replacement component model

```text
  R/E   resolved typed elaboration (upstream; publishes the route-stamped AST)
    |
    v
  Core  CProgram: the contract. Typed and fact-carrying, grown one fact at a
        time (R4), checked by coreValidate (R6) before any emitter runs.
    |
    v
  Plan  one immutable shared-analysis record built once by lowerProgramEmit
        (R5): reachability, lazy globals, TRMC groups, linkage, extern
        requirements, target choice.
    |                         |
    v                         v
  llvm_emit                 wasm_emit
  consumes Core + Plan;     consumes Core + Plan;
  physical only             physical only
```

There is no V, no ANF, no AP, and no plan-and-renderer split. Each fact the old
V carried becomes a field on an existing Core node, with a producer in
lowering, a validator arm, and a deletion of the per-backend reconstruction in
the same PR. That is the pattern `RScalar` on `CBinPrim`, `CDecision`,
`labelFallthrough`, and the `Route` payloads already follow; this revision makes
it the whole plan.

### R4. The fact ledger

One row per fact. A row lands as one compiler-source PR (or a short series)
that adds the carrier, the producer, the validator arm, and the hand-derived
fixture, and deletes the named consumers. Both backends switch in the same PR
([T-EVAL-LOCKSTEP] for the interpreters; #59 for the backends). Order is by
open-bug pressure, not by layer.

| # | Fact | Carrier | Producer | Deletes | Drains / owns | Prerequisite |
|---|---|---|---|---|---|---|
| F1 | Record field ordinals, and update evaluation order | ordinal on `CRecord`, `CFieldAccess`, `CRecordUpdate`, `CVariantUpdate` fields; update overrides canonicalized at lower time (bind in written order, store by ordinal) | `core_ir_lower` from `declaredRecordFieldOrders` (already an emit input) | LLVM `Emit.recByName`/`recByLabel`/`recFields`, Wasm record-name and label indexes in `WasmEmitInput` | #1518 (update order diverges across engines); the residual of the #1306 family | none |
| F2 | Call mode | `CApp` stamped exact / partial / over with the residual arity (a new `CCall`/`CPap` pair is acceptable if the stamp reads worse) | `core_ir_lower` from the one arity table both backends already share plus the impl clause's own pattern count (the #1034 rule) | the ten `methodArityOf*` functions, `emitApp`/`emitOverApp` classification, Wasm `$mdk_apply` arity branches | #2078; the #1034/#1101/#826 family stays drained by construction | none now; consumes the typechecker's per-binding arity when M2 (#2549) publishes it (E-5) |
| F3 | Interface and type identity on dispatch nodes | the existing `ifaceIdentity` string (`module::Iface`) on `CImplDefault`, extended to `CMethod`, `CDict`, `CImplEntry`, `CImplTagged`; the head type carries its owner module the same way | `core_ir_lower` from declaration identity (`Ident` is already in the AST) | bare-spelling keys in `defaultFnName`/`defaultFnNameW`, `implFnSym`, `distinctKeysAtHead`, `headTagUniqueW` | emitted-symbol half of #1397; #1619; #2055; #1973; the symbol-keying half of #1265 | none for the string form; SC-1 (#2563) upgrades it to the typed key |
| F4 | Semantic tail sites | tail flag on `CApp`/`CMethod` in tail position, computed once | `core_ir_lower` (the position is syntactic) | per-backend tail rediscovery in `emitAppTail` and its Wasm peer | #1349, #2577 | none |
| F5 | Runtime types on binders, parameters, and returns | `RTInt`/`RTFloat`/`RTValue` (never `LTy`, never `(ref eq)`) on `CLam` params, `CLet` binders, `CBind` clauses | the #353 plan, unchanged: stamp what typecheck knew at lower time | `inferSigs`, `typeOf`, `paramUseTy`, `staticIsFloat`, `bodyFloatRet`, Wasm `cexprIsFloat`/`refMainKind` | #2545 and the N8 family (EMITTER-SEMANTICS section 9) | none; #353 is adopted as written |
| F6 | Explicit evidence and complete method dispositions | evidence terms on `CMethod`/`CDict` replacing `Route` recipes; a complete `(instance, method)` disposition table | typechecker M2 (#2549) for evidence; B-1 (#993) for default-body evidence | route-word hedges, `emitDefaultRKey`, Wasm `implEntryRouteKeyW` recomputation, default synthesis | #1068, #1020, the route half of #1265, #1046 | BLOCKED on M2 and #993. `RNone` stays until #993 lands (ruling 4). X-E (#1403) is the consumer issue and does nothing before M2 |
| F7 | Capability manifest | a Core-level manifest field extracted before row erasure | effects checker | the reachable-extern approximation of the manifest | #2426's class (missing host import must be a named rejection) | the effects manifest producer (EFFECTS sections 7-8) |

Every row owes the L7 fixture: centralizing a fact makes all engines agree, so a
wrong centralized fact is a unanimity no differential can see. The fixture is
derived from the spec before the PR is cut, never captured from an engine.

### R5. The shared plan record

`lowerProgramEmit` builds one immutable record beside `CProgram` and both
emitters take it as an argument. It holds what is already computed today in
scattered places, moved rather than reinvented:

| Field | Today |
|---|---|
| reachability roots and edges | `ir/dce.mdk` (pre-lower) and `backend/wasm_reach.mdk` (post-lower, Wasm only) |
| lazy/eager global classification | `emit_support.eagerReachMap` / `lazyGlobalNames`, computed per backend |
| TRMC eligibility and groups | `backend/trmc_analysis.mdk`, computed per backend |
| linkage map and injectivity | `private_mangle` and the three X-L.H guards, run inside lowering |
| reachable extern requirements | per-backend extern ladders |
| target | the `EmitTarget` parameter of `lowerProgramEmit`, which moves here so lowering itself is target-neutral again (L4) |

The two emit-input records converge into this one over time; the four facts
`WasmEmitInput` lacks relative to `EmitInput` (`returnsSelf`, `selfFnParams`,
`methodConstraintIfaces`, `mainIsUnit`) are the first to move. This unit has no
upstream dependency and is landable now. `wasmReachFilter`'s post-lower pruning
becomes the shared reachability pass once F3 gives it identity-keyed dispatch
edges; until then it stays a Wasm-only field, named as such.

### R6. The Core validator

`coreValidate : EmitTarget -> CProgram -> Plan -> List CoreDefect`, run by every
build entry between lowering and emission. It rejects, before any text is
produced: a record operation without an ordinal once F1 has landed, an
application without a call mode once F2 has landed, a dispatch node without
identity once F3 has landed, a binder without a runtime type once F5 has
landed, a reachable extern without a requirement row, a duplicate or
non-injective link symbol (#748), and a direct call whose argument count
disagrees with the callee's definition arity (#1101's class). An internal
defect is a compiler bug and fails hard; it is not subject to ruling 2's
warn-first policy, which governs user-program type errors reaching
`runEmitWith` (#2089). Section 13.3's malformed-plan tests mutate a lowered
`CProgram` and assert the validator fires.

### R7. Stage dispositions

| Stage | Issue | Disposition |
|---|---|---|
| X-0 | #1399 | X-0V retired. X-0D (`ir/draft_semantic_program.mdk`) has one consumer, its own probe; it either gains a product consumer within one sprint or is deleted with its probe and gate (R9). |
| X-A | #1400 | Retired. No ANF, no AP. `ir/anf_identity.mdk` and its probe follow the same consumer-or-delete rule. Generated-callable identity, if ever needed, is a Core fact, not a new IR. |
| X-I | #1401 | Re-scoped to F1 and F3. `private_mangle` keeps its binding-set responsibility until ruling 3 decides whether the emitter process runs resolve. |
| X-T | #353 | Adopted unchanged as F5. |
| X-C | #1402 | Re-scoped to F2. |
| X-E | #1403 | Kept as the consumer of F6, blocked on #2549 and #993. Its charter also absorbs the reconciliation of `RNone` (ruling 4) with L1: `RNone` is a validated, pinned optimization datum until #993, and a fresh site that reaches it is a bug. |
| X-G | #1404 | Re-scoped to F4 plus the globals and TRMC fields of R5. |
| X-L | #1405 | X-L.H landed (injectivity guards). Abstract `LinkId` retired; the linkage field of R5 and the validator arms in R6 are what remains. |
| X-N | #1406 | X-N.H complete. X-N.C (validated LLVM plan plus pure renderer) retired; the prototype check and duplicate-define refusal it promised move into R6. |
| X-W | #1407 | X-W.H complete. X-W.C retired. Residual scope: the scalar-mode decision (section 8.1, unchanged), host-ABI requirement derivation from R5's extern field, and product-input parity with `playground_main` (R9). |
| X-X | #1408 | Kept, with the deletion set reduced to what R4 rows delete plus the two consumer-or-delete modules; the ratchet requirement is unchanged. |

### R8. Reconciliation with the revised typechecker plan

Section 3's producer table, re-derived 2026-09-03 against the live tracker and
`TYPECHECK-TARGET-ARCHITECTURE.md`'s amended DAG:

| Section 3 row | Named producer | Live state | Where it sits now |
|---|---|---|---|
| Qualified `Ident` everywhere | #1110-#1112, #1115 | #1110, #1115 closed; #1112 open | cross-module half is SC-1 (#2563), step 8 of the typechecker order |
| Whole-graph declaration/instance environments | #1112 (K/A-3) | open | no step; SA-2/SA-3 measured the route table as topological-prefix scoped, widening at #2548 with an acceptance delta |
| Structured superclass evidence | #993 (B-1) | open | no step; ruling 4 defers it |
| Evidence references, frozen admissibility | #1113 (B-2) | closed | B-2.4 cut to X-E.C by the 2026-08-14 ruling; B-2 delivered conjunct 2 only |
| One slot per predicate | #1318 (G-10) | open | folded into #2547 unit 3 |
| Dict abstraction at local binders | #1082 (F-1) | open | no step; #1986 is its 0.1.0-sized half |
| Source arity and call convention | #1137 after #1318 | open | class drained by PR #2061 (emitter arc); falls out of M2 (#2549) as E-5 |
| Complete method disposition | #1112/A-3 with #993 | open | no step |
| Semantic runtime types | #353 | open | not in the typechecker plan; owned here as F5 |
| Capability manifest | effects sections 7-8 | - | unchanged |

Three facts this arc must carry that the old sections did not know:

1. **The emitter binary does not run resolve.** `medaka build` shells out to
   `medaka_emitter`, whose pipeline is `driveModules -> runEmitWith ->
   mangleUnits -> elaborateModules`; resolve's resolution pass is DCE'd out of
   that binary (`compiler/frontend/resolve.mdk`, SA-1). Whether that changes is
   ruling 3, deferred until after M2. Until then every identity fact in R4 is
   produced by lowering from the elaborated AST, which is what both build
   processes have.
2. **`RNone` is a ruled-in optimization** (ruling 4), realized as
   `narrowUnrouted` in `eval.mdk` and `emitDefaultRKey` in `llvm_emit.mdk`. L1
   still holds for every other missing fact; F6 records the one sanctioned
   exception and its expiry (#993).
3. **Route answers and build-path acceptance move under the typechecker plan**
   (#2546 acceptance delta, #2548 route-table widening, #2549 node-arity change
   on `EMethodAt`). No comparison carrier in this arc may certify a fact against
   that moving baseline; R4 rows are graded by hand-derived fixtures and the
   engines gate, dated per typechecker step.

The reciprocal pointer this doc owed is now in place:
`TYPECHECK-TARGET-ARCHITECTURE.md` section 8's emitter-coordination bullet
links back here.

### R9. Order of work

1. **Now, no dependency:** `playground_main.runEmit` passes the validated FFI
   extern table exactly as `wasm_emit_modules_main.emitTail` does (the browser
   compiler passes `[]` today, so a user FFI extern dies as an unbound variable
   instead of the named WasmGC rejection). Re-derive `EMITTER-ARCHITECTURE.md`
   and `EMITTER-ARCH-BUG-FIT.md` (done in the same PR as this revision).
2. **Consumer-or-delete, one sprint:** `ir/draft_semantic_program.mdk`,
   `ir/anf_identity.mdk`, `ir/anf_identity_sexp.mdk`, their two probe entries,
   and gates `diff_compiler_draft_semantic.sh` / `diff_compiler_anf_identity.sh`.
   Default outcome is deletion; a product consumer is the only thing that keeps
   them.
3. **R5 plan record** (no dependency; can run beside F1).
4. **F1, F3, F2, F4, F5** in that order, one row per PR series, each with its
   R6 validator arm and L7 fixture.
5. **F6** when #2549 lands; **F7** when the manifest producer exists.

Compiler-source landing stays serialized through the one-PR golden lane and
interleaves with the typechecker's steps; high-severity fixes keep priority
(section 12's "High-severity work during migration" still applies).

### R10. Supersession map

| Section | Status after this revision |
|---|---|
| 1 Design laws | in force |
| 2 Component model | SUPERSEDED by R3 |
| 3 Upstream contract | amended by R8 (table states); the "consumes, does not own" principle stands |
| 4 V | SUPERSEDED by R4 (facts) and R6 (validation) |
| 5 A canonical ANF | SUPERSEDED; no ANF |
| 6 AP | SUPERSEDED by R5; 6.1's shared-versus-physical table stands |
| 7 N, 8 W | SUPERSEDED as stages; the ownership lists remain the description of what is physical; 8.1 stands |
| 9 Runtime and host | in force |
| 10 Traceability | historical; `EMITTER-ARCH-BUG-FIT.md` section 0 is the current map |
| 11 Decisions | in force, with "current Core's sufficiency" now answered: insufficient as-is, grown rather than replaced |
| 12 Migration DAG | SUPERSEDED by R7 and R9; its high-severity clause stands |
| 13 Verification | in force, 13.3 re-pointed at R6 |
| 14 Risks | in force; the "two permanent authorities" risk is what R9 step 2 discharges |
| 15 Tracker | in force |

## 1. Design laws

### L1 - Semantic closure before the backend fork

The validated semantic program is sufficient to execute a check-accepted program
without consulting typed declarations, source spellings, or ambient install
tables. If a backend needs a fact established upstream, the fact travels in the
input. A missing fact is a validation error, never a default to Int, first
candidate, empty route, guessed arity, or label search.

This is the backend form of the typechecker target's "one judgment, one
implementation" law. It removes the substrate behind N8 type recovery,
record-layout guesses, arity forks, and route-key recomputation.

### L2 - Resolve and elaboration decide; consumers transcribe

The settled namespace-tagged `Ident` (`Ns`, origin, spelling) is the identity
substrate. Module-scope declarations use it directly. Owner-local declarations
use an owner-qualified compound (`MethodId`/`FieldId`) built from `Ident`s and a
validated slot; the owner is never encoded into spelling. A selected impl
carries the upstream solver's opaque `InstId`. Local/evidence binders use
separate scope-local IDs. Elaboration selects or forwards evidence; A-3 (#1112)
records the complete per-instance method disposition. No downstream component
re-selects an instance, reconstructs visibility, or decides ownership from
spelling.

This restates EMITTER-SEMANTICS DL1. Rendering an identity into an LLVM/WAT
symbol is backend work; creating the identity is not.

### L3 - Evaluation and call shape are explicit

Strict left-to-right evaluation, exactly-once evaluation, trap order, guard
scope, semantic tail position, dictionary-prefix order, source arity, and
eta-expansion are represented once in shared IR. `CallShape` is authoritative;
ANF derives and becomes the sole executable carrier of exact/under/over
application. Whole-program analyses may index ANF decisions but never classify
them again. The physical backend chooses instructions and layouts, not meaning
or timing.

### L4 - Shared semantic plan, separate physical plans

Every decision independent of tagged words, WasmGC types, SSA, or structured
control is computed once. Every decision that names those mechanisms belongs to
one physical backend. The boundary is semantic versus physical, not
`llvm_emit.mdk` versus `wasm_emit.mdk`.

### L5 - Plans are validated values

End-state emitters accept only opaque validated artifacts. During migration a
deliberately non-opaque `DraftSemanticProgram` may carry legacy answers and
comparison receipts; it is never called validated and never becomes a new
authority. Validation happens before text is produced and checks identity,
ownership, types, arities, evidence, layouts, control, linkage, capabilities,
and backend invariants. Invalid internal state fails loudly as a compiler
diagnostic; a physical toolchain must not be the first component to discover a
malformed plan.

### L6 - Emission is an explicit per-program computation

Semantic facts and planning caches live in immutable per-program records.
Physical lowering and serialization may use local mutation for builders,
register allocation, labels, and buffers, but no semantic result depends on a
module-level `Ref`, a prior emission, or which entry installed a table.

Equivalent input produces byte-identical normalized plans and output. The
native self-compile fixpoint remains the strongest determinism proof.

### L7 - The spec, not engine agreement, is the oracle

Every centralized decision has a hand-derived conformance fixture. Cross-engine
parity remains necessary, but all engines agreeing is not sufficient (#1265).
Validators have negative tests, new constructors have exhaustive consumer
audits, and program-global state has unrelated-code and same-process controls.

### L8 - Shared planning replaces work

The new layers replace backend scans and tables as consumers migrate. They do
not permanently sit in front of unchanged emitters. Each index is built once
from immutable authoritative data, uses a real map/set where appropriate, and
is measured for allocation and emit-stage time before a performance claim.

## 2. Component model

> **SUPERSEDED 2026-09-03** by R3. Retained as the record of the proposal.

```text
  R/E  resolved typed elaboration (upstream contract)
    |
    v
  V    Validated Semantic Program
    |
    v
  A    canonical ANF Core
    |
    v
  AP   Validated ANF Plan (ANF bodies + shared analyses/manifests)
    |                         |
    v                         v
  N    LLVM Physical Plan     W    Wasm Physical Plan
    |                         |
    v                         v
  LN   pure LLVM renderer     LW   pure WAT renderer
    |                         |
  C/Boehm runtime             WAT runtime + host ABI
```

`DraftSemanticProgram` exists only during migration before V. The names are
contracts, not mandatory file boundaries. During migration they may be records
in existing modules. End-state constructors for validated artifacts are private
to their validator modules.

## 3. R/E - upstream elaboration contract

> **AMENDED 2026-09-03**: the table below records the producers as named on
> 2026-08-07; their live state and current owner are in R8. The principle
> (this arc consumes, it does not own) stands.

The backend arc consumes, but does not own, these facts:

| Fact | Upstream owner | Existing migration owner |
|---|---|---|
| Qualified `Ident` values in every global namespace and no unresolved flat-path origin | resolve/typechecker Stage A/E-1 | #1110-#1112, #1115, and namespace follow-ups |
| Owner-qualified `MethodId`/`FieldId` and stable member/constructor ordinals | resolved declaration graph / typechecker `DataEnv` | Stage A owner/member pairs, adopted by X-I.P without spelling lookup |
| Whole-graph declaration/instance environments | typechecker K/A-3 | #1112 |
| Structured superclass/instance evidence | typechecker B-1 | #993 |
| Evidence references and frozen arg-tag admissibility | typechecker B-2 | #1113 |
| One dictionary slot per full predicate | typechecker G-10 | #1318 |
| Dict abstraction at local binders | typechecker F-1 | #1082 |
| Source arity and dictionary-prefix call convention | elaboration output | #1137 after #1318 |
| Complete per-instance method disposition | declaration analysis/elaboration | #1112/A-3 (G-7 adoption), coordinated with #993 |
| Semantic runtime type facts | typecheck/lowering | #353, refined by X-0 |
| Effects checked and authoritative `CapabilityManifest` extracted before row erasure | typechecker/effects | EFFECTS sections 7-8; current manifest/check-policy path |

`CapabilityManifest` is not `ReachableExternRequirements`. The manifest is the verified
entry-point effect row, including user labels and parameter domains. Physical
planning may derive host imports from reachable externs but may not narrow or
recompute the manifest.

The contract is parallel-friendly. X-0 first publishes additive draft carrier
shapes. Independent producer adapters can populate and compare draft fields as
each producer becomes authoritative; physical consumers do not cut over before
V/AP validation. No temporary emitter is allowed to invent missing identity or
evidence; an adapter may copy a legacy producer's answer only to compare
behavior while the producer is being replaced.

## 4. V - Validated Semantic Program

> **SUPERSEDED 2026-09-03** by R4 (the facts become Core fields) and R6 (the
> validator). The fact inventory in 4.1-4.5 remains the reference for what
> each R4 row must carry; the opaque record and its minting rule are gone.

Validated Semantic Program (V) is the last representation whose fields describe
language meaning rather than an execution target.

### 4.1 Program-level shape

The conceptual program contains identity-keyed definitions:

```text
VProgram
  modules          : ordered modules with module origins
  bindings         : Map Ident VBinding + ordered List Ident
  dataTypes        : Map Ident VDataDef + ordered List Ident
  records          : Map Ident VRecordDef + ordered List Ident
  interfaces       : Map Ident VInterface + ordered List Ident
  instances        : Map InstId VInstance + ordered List InstId
  externs          : Map Ident VExtern + ordered List Ident
  entry            : Ident
  capabilityManifest : CapabilityManifest
```

Named global IDs use the already-settled `Ident` type, whose `Ns` distinguishes
six namespaces and whose origin constructors enforce non-empty module identity.
Selected instances use the solver-owned `InstId`; this plan does not encode a
second string key for them. Local binders and evidence parameters use scoped IDs
because they are not global declarations. An encoded qualified spelling must
never be written back by `fmt`. Ordered identity vectors preserve
source/dependency order independently of map-key order and are validated against
the maps.

Legal owner-local spelling reuse requires compound IDs:

```text
MethodId = { iface : Ident, member : Ident, slot : Int }
FieldId  = { owner : Ident, member : Ident, ordinal : Int }
```

The nested `member` carries `NsMethod` or `NsField` and the declaration origin;
the compound owner is what makes two same-spelled members in one module
distinct. V validates the namespace, origin, owner membership, and slot. These
types wrap the established identity substrate rather than replacing it with a
second encoded-string identity.

V identifies source callables without pre-declaring ANF-generated code:

```text
SourceCallableId =
  TopLevel Ident
  | ImplMethod InstId MethodId
  | InterfaceDefault MethodId
```

V validates source owner existence and uniqueness. X-A then becomes the sole
producer and validator of generated callable identity:

```text
CallableId =
  Source SourceCallableId
  | Nested CallableId StableNodeId
  | Adapter CallableId StableNodeId CallShape
```

`StableNodeId` is derived by X-A from a project-relative source span plus a
structural node/role path, never a rendered name or traversal counter. This
covers lifted lambdas, wrappers, eta adapters, and PAP entry code without
pretending they are module-scope `NsValue` declarations. AP validates generated
owner existence and uniqueness; DCE and linkage key all callable bodies on
`CallableId`.

### 4.2 Runtime types, not LLVM types

V carries a closed backend-neutral runtime type/kind:

```text
RuntimeType =
  RTInt | RTFloat | RTChar | RTBool | RTUnit | RTString
  | RTData Ident | RTRecord Ident | RTTuple Int | RTList
  | RTArray | RTRef | RTClosure ClosureRuntimeShape | RTEvidence Ident
  | RTParam TypeParamId | RTValue
```

`ClosureRuntimeShape` is the runtime projection of `CallShape`: ordered evidence
and value parameter representations plus result representation. It excludes
`sourceArity` and `etaTarget`, which govern source application/adapter planning
but do not distinguish runtime closure representation.

The exact final ADT is a staging decision, but two constraints are fixed:

- it distinguishes every operation a backend must lower without guessing;
- it contains neither LLVM `LTy` states such as unboxed-register Float nor
  Wasm types such as `(ref eq)`;
- polymorphic values use `RTParam`/`RTValue`, never a guessed concrete scalar.

`RuntimeType` records semantic operation facts, not an exact physical layout.
Backends may map `RTParam`/`RTValue` to native's uniform word or Wasm's general
reference slot. `RTEvidence`'s `Ident` must be `NsIface`; V rejects any other
namespace.

### 4.3 Calls and evidence

Each callable has one `CallShape`:

```text
CallShape
  evidenceParams : ordered List EvidenceParam
  valueParams    : ordered List RuntimeType
  sourceArity    : Int
  callableArity  : Int
  etaTarget      : Option Int
  resultType     : RuntimeType
```

For an ordinary declaration,
`callableArity = length evidenceParams + length valueParams`, and
`sourceArity = length valueParams`. Generated adapters and partial applications
carry their own explicit shape rather than adjusting an inherited arity.
The final representation must express #1318's one-slot-per-predicate rule. It
must not freeze today's per-type-variable shattering. Escape eligibility is a
validated shared analysis fact, not a guess from observing direct calls.

Evidence is ordinary explicit structure:

```text
Evidence =
  EvidenceInstance InstId (List Evidence)
  | EvidenceParam EvidenceParamId
  | EvidenceSuper Evidence SuperSlot
```

A method operation carries a `MethodId`, the evidence value, and a stable method
slot. Validation checks each evidence argument against the destination
predicate/interface/type key, not just argument count. There is no
backend-visible request to "find an impl named X". Arg-tag dispatch may survive
only as frozen, validated optimization data whose admissibility was decided
against the whole instance environment.

A-3's complete method table is represented without a backend synthesis case:

```text
MethodDisposition =
  Supplied { instance : InstId, method : MethodId, body : SourceCallableId }
  | InheritedDefault {
      instance : InstId,
      iface : Ident,
      method : MethodId,
      defaultBody : SourceCallableId,
      receiver : EvidenceParamId,
      localEvidence : ordered List EvidenceParam
    }
```

Every method slot of every accepted instance has exactly one disposition. A
method-less interface contributes zero slots. If an impl omits a required method
that has no default, #993/A-3 must reject it upstream rather than minting an
`Absent` row. X-E consumes this table and never fills one.

### 4.4 Data and records

Constructor and field operations carry identities and logical ordinals:

- constructor creation/match: owner/type `Ident`, ctor `Ident`, logical ordinal;
- field creation/update/access: owning record/ctor `Ident` plus `FieldId`;
- record literal fields are canonicalized by `FieldId`, never source order;
- private/import/re-export visibility has already been resolved.

V carries the authoritative declaration-derived member and constructor
ordinals and validates identity, ownership, and complete non-overlapping
owner-local ordinal tables. AP copies and indexes those ordinals without
renumbering; mutating or normalizing one is a validation failure. Native byte
offsets and Wasm struct field types are physical.

### 4.5 Traps, locations, and globals

Partial operations carry a stable `TrapCode` and source span. Locations use
project-relative identity so D1 determinism is preserved. A top-level nullary
read is represented as `Force Ident`; backends do not reinterpret it as an
ordinary zero-initialized global load. The validated `CapabilityManifest` is a
separate V field and is never reconstructed from reachable extern calls.

### 4.6 V validation

Validation rejects:

1. unresolved, forged, or out-of-scope identities;
2. duplicate declaration IDs;
3. field ownership/ordinal disagreement;
4. missing semantic runtime types;
5. call/definition/dictionary-prefix arity disagreement;
6. evidence that does not satisfy the referenced interface/method;
7. a missing or ambiguous instance-method disposition;
8. malformed match/fallthrough targets;
9. partial operations without trap code/span;
10. effects erased before complete capability-manifest extraction;
11. map/order-vector disagreement or an identity in the wrong `Ns`;
12. evidence whose interface/type key does not match its call slot.

## 5. A - canonical ANF Core

> **SUPERSEDED 2026-09-03**: there is no ANF. The properties this section
> wanted (evaluation order explicit, call mode decided once, captures and
> tail sites computed once) are R4 rows F1, F2, and F4 on existing Core nodes.

ANF makes evaluation order and call categories structural without introducing a
machine CFG.

```text
AExpr =
  Let LocalId AOp AExpr
  | If Atom AExpr AExpr
  | Switch Atom (List ACase) AExpr
  | Return Atom
  | Trap TrapCode Span

AOp =
  Prim TypedPrim (List Atom)
  | DirectCall CallableId (List EvidenceAtom) (List Atom)
  | ClosureCall Atom CallShape (List Atom)
  | MakeClosure CallableId CallShape (List LocalId)
  | MakePap Atom CallShape (List Atom)
  | MakeEvidence InstId (List EvidenceAtom)
  | ProjectMethod EvidenceAtom MethodId
  | MakeCtor Ident (List Atom)
  | FieldGet Atom FieldId
  | FieldSetCopy Atom (List (FieldId, Atom))
  | ForceGlobal Ident
  | ExternCall Ident (List Atom)
```

The concrete type may preserve structured `match` nodes where doing so makes
Wasm lowering simpler, but it must retain these properties:

- all operation operands are atoms;
- left-to-right strict order is explicit;
- each non-atomic expression is evaluated once;
- direct, closure, constructor, method/evidence, and extern calls are distinct;
- exact/under/over application is decided once from `CallShape` while producing
  ANF, with adapters/PAPs explicit in the nodes above;
- semantic tail positions and fallthrough targets are explicit;
- every value has a `RuntimeType`.

ANF initially performs no CSE, code motion, inlining, or representation choice.
An ANF interpreter and stable S-expression form are required. The equivalence
chain is elaborated AST evaluation -> current Core evaluation -> ANF evaluation,
but expected results for known-wrong families come from the specs, not eval.

The call encoding is structural, not a hint to a later classifier:

- `DirectCall` and `ClosureCall` are exact calls and validation requires their
  arguments to match the carried/calculated callable shape exactly;
- under-application is only `MakePap`, whose explicit residual `CallShape`
  accounts for every supplied argument;
- over-application is an exact call followed by one or more explicit exact
  `ClosureCall` nodes; there is no over-application node for a backend to split;
- `MakeClosure`'s `LocalId` list is the canonical identity-keyed capture set and
  order produced during ANF conversion. AP validates and indexes that list; it
  does not recompute free variables or reorder captures.

Physical lowering therefore contains no argument-count or free-variable
classification branch.

## 6. AP - validated ANF Plan

> **SUPERSEDED 2026-09-03** by R5, the shared plan record built by
> `lowerProgramEmit`. Section 6.1's shared-versus-physical table stands.

The Validated ANF Plan is one immutable value containing ANF bodies plus
separately validated whole-program analyses, manifests, and indexes. It is not
a low-level instruction IR and does not duplicate semantic decisions already
encoded by ANF.

| Component | Shared content |
|---|---|
| Reachability | identity-keyed DCE roots and edges, including every evidence/default/adapter/closure/global/extern edge |
| Calls | call graph indexing the call decisions already encoded in ANF |
| Closures | indexes and validates ANF's canonical capture IDs/order, callable shape, and explicit PAP plans; no second free-variable analysis |
| Globals | lazy by default; eager only with a proof of purity, non-observation, and dependency-safe order; cycle/black-hole policy |
| Evidence | logical evidence schemas; the complete method dispositions produced by A-3 (#1112); frozen admissibility |
| Data layout | owners, canonical field/ctor ordinals, runtime types |
| Matching | semantic decision trees, guard/fallthrough structure |
| Tail work | semantic tail sites, TRMC eligible functions/groups and constructor slots |
| Linkage | collision-free abstract `LinkId`s and ownership (prelude/program) |
| Externs | reachable semantic extern requirements, signatures, domains; separate from V's complete `CapabilityManifest` |
| Diagnostics | trap codes and stable source spans |

DCE is conservative by construction: an edge kind not understood by the
reachability builder is a validation error, not an omission. Retention laws
cover evidence constructors, explicit/default method bodies, generated
adapters/PAPs, closure targets, global initializers/force functions, extern
requirements, and conservative fallback retention for dynamic method dispatch.
Order vectors are filtered, never regenerated from map traversal.

### 6.1 What remains physical

| Shared fact | LLVM physical decision | Wasm physical decision |
|---|---|---|
| field ordinal | cell word offset/GEP | struct field/type/cast |
| runtime type | tagged word/box/unboxed local | i31/box/ref type/local |
| call shape | LLVM prototype/direct or indirect call | function/ref type and call form |
| capture order | native closure cell | `$clos`/environment struct |
| global policy | native state/force functions | Wasm globals/state/force functions |
| match tree | blocks/branches/phis | structured blocks/`br_table` |
| tail site/TRMC group | `musttail`/native destination cells | `return_call`/mutable destination structs |
| `LinkId` | legal LLVM symbol | legal WAT identifier |
| extern requirement | C symbol/runtime declaration | WAT helper or host import |

SSA construction, phi placement, LLVM prototypes, Wasm block signatures,
casts, allocation sizes, and instruction text never enter AP.

## 7. N - LLVM Physical Plan

> **SUPERSEDED 2026-09-03 as a stage** (R7, X-N). The ownership list below
> remains the description of what is physical on the native side; the
> validator items move to R6. No plan-and-renderer split is planned.

The LLVM plan owns:

- native tagged-word and boxed-cell layouts;
- Float unboxing as a local optimization;
- concrete closure, evidence, thunk, and global state cells;
- LLVM prototypes and direct/indirect call compatibility;
- CFG/SSA/phi construction;
- `musttail` legality and native TRMC realization;
- Boehm atomic/non-atomic allocation class;
- C-runtime bindings and declarations;
- physical tags, sentinels, and symbol spellings;
- prelude/program-half linkage.

Its validator checks every call prototype, tail-call side condition, allocation
size, pointer/int conversion, block terminator, tag/symbol collision domain,
guarded partial instruction, and global force use. A reachable raw
`unreachable` must cite a validated upstream invariant.

The renderer has the end-state signature conceptually equivalent to:

```text
renderLLVM : ValidLLVMPlan -> String
```

It may allocate local registers/labels and append text. It does not inspect
source declarations or infer semantic facts.

## 8. W - Wasm Physical Plan

> **SUPERSEDED 2026-09-03 as a stage** (R7, X-W). The ownership list stands
> as the physical description; 8.1's scalar-mode decision rule stands.

The Wasm plan owns:

- `(ref eq)` slots, i31 versus `$boxint`, and any validated scalar fast path;
- the typed struct/array graph and explicit sum discriminants;
- closure code-ref, arity, PAP, and universal apply representation;
- structured control, typed locals, `return_call`/`return_call_ref`;
- ref casts and mutable fields needed by Wasm TRMC;
- helper/runtime inclusion and host-import groups;
- coded-trap-before-`unreachable` realization;
- WAT identifier and i32 tag collision domains.

Its validator checks function/ref signatures, cast justification, 63-bit Int
normalization at every producer, mutable TMC fields, import availability,
coded traps, and absence of raw engine traps for accepted programs.

### 8.1 Scalar mode decision

The target does not preserve or delete scalar mode by fiat. X-W measures its
benefit on representative pure programs: emitted size, assembly time,
instantiation time, runtime, and implementation surface. The decision rule is:

- retain scalar representations only as local physical choices inside the one
  AP -> Wasm-plan lowerer; they may select locals, arithmetic instructions, and
  boxing boundaries but may not own a second expression/control/call scanner;
- retire the current scalar lowering path if it cannot be expressed under that
  constraint, or if the measured value does not justify its remaining surface.

Either outcome preserves the WasmGC physical contract for general programs.

## 9. Runtime and host contracts

Native continues to use Boehm and `runtime/medaka_rt.c`; custom GC work remains
out of scope. The architecture narrows and validates the runtime ABI but does
not replace it.

Wasm host imports are generated or validated from one host-ABI requirement set
derived from reachable externs. Every host implementation set must provide the
same required key set, with a real implementation or named rejection. This is
distinct from V's complete `CapabilityManifest`, which remains the authoritative
entry-point effect contract. Shared pure shim behavior should come from one
source/module where packaging permits; byte-copy parity markers remain a
transitional guard, not the target architecture.

The extern catalog has one semantic row per primitive:

```text
ExternSpec
  id, signature, effects/capabilities, domain, target dispositions
```

Each physical backend then supplies a lowering or an explicit rejection.
Backend-specific runtime code remains separate.

## 10. Traceability by defect family

The detailed ledger is in `EMITTER-ARCH-BUG-FIT.md`. The architecture-level
claim is deliberately narrower than "this plan fixes every backend symptom".

| Family | Structural cause | Target prevention | Owner |
|---|---|---|---|
| Record/ctor identity and layout | names/order survive where IDs/ordinals are needed | V `Ident`s + AP canonical logical layout + validation | upstream identity plus X-I consumers |
| Mangler visibility/re-exports | backend reconstructs resolver binding set | consume resolver-produced bindings; `LinkId` render only | X-I |
| Scalar/type recovery | type erased before operations are fully typed | `RuntimeType`/typed primops | #353 / X-T |
| Arity/PAP/strict-prefix | engines infer source arity differently | one `CallShape`, ANF application mode | #1318 -> #1137 / X-C |
| Evidence/super/default dispatch | routes/method tables are recipes or incomplete | explicit evidence + A-3's complete method disposition | #993/#1113/#1082/#1112 / X-E |
| Global initialization | compiled backends approximate lazy semantics | `Force`; lazy by default; one shared proof for safe eager cases | X-G |
| Match/fallthrough drift | backend-local control state | explicit ANF control and target | X-G |
| TCO/TRMC drift | semantic tail site rediscovered physically | shared tail/TRMC plan, separate realization | X-G, including #1349 |
| Symbol/tag collision | sanitize/hash-and-hope | abstract IDs plus physical validators | X-L |
| Ambient state/install hooks | hidden emitter prerequisites | immutable artifacts and local state | X-0/X-N/X-W |
| Extern/host drift | parallel name ladders and shim inventories | semantic catalog, complete capability manifest, reachable host requirements | X-L/X-W |

## 11. Decisions preserved and reopened

### Preserved

- one elaborated semantics refined by eval, Core, native, and Wasm;
- effects erase after soundness checks and capability extraction;
- lazy top-level nullary semantics and three-state cycle detection;
- one abstract value contract with two physical encodings;
- native tagged words, Boehm, and the C runtime;
- WasmGC typed references and host-managed GC;
- shared TRMC verdict with backend-specific mechanics;
- deterministic native self-hosting and `prelude.o` independence;
- loud rejection instead of a guessed backend answer.

### Reopened

- current Core's sufficiency as the backend contract;
- `Route` recipes as "explicit dictionaries";
- install hooks as a permanent semantic interface;
- backend-local closure conversion and call classification;
- `private_mangle` reconstructing import/export semantics;
- Wasm scalar mode's cost/value;
- copied host-shim blocks versus generated/shared host ABI;
- LLVM `LTy` extraction as the answer to N8 (it is physical, not the missing
  semantic carrier).

## 12. Migration DAG

> **SUPERSEDED 2026-09-03** by R7 (stage dispositions) and R9 (order of
> work). The "High-severity work during migration" clause at the end of this
> section stands.

Stage handles and owners are stable. Existing issues are adopted rather than
duplicated:

| Stage | Owner |
|---|---|
| X-0 | #1399 |
| X-A | #1400 |
| X-I | #1401 |
| X-T | #353 (adopted) |
| X-C | #1402 |
| X-E | #1403 |
| X-G | #1404 |
| X-L | #1405 |
| X-N | #1406 |
| X-W | #1407 |
| X-X | #1408 |

```text
Parallel pre-fan-in work (develop concurrently; land compiler PRs one at a time):
  X-0D    draft schema/provenance/comparison receipts
  X-N.H   LLVM explicit-input and per-emission-state hygiene
  X-W.H   Wasm explicit-input/reset hygiene and product-input parity
  X-L.H   semantic extern-catalog groundwork and current-domain validators
  upstream producer development and independent S0/S1 fixes

X-0D
  |\
  | + typechecker A/E-1 ------------> X-I.P identity/visibility adoption
  | + #353 -------------------------> X-T.P runtime-type production
  | + #1318 -> #1137 --------------> X-C.P call-shape production
  | + A-3/#1112 + #993/#1113/#1082 -> X-E.P evidence/disposition production
  |
  + all required authoritative producer checkpoints -> X-0V
                                                       -> X-A canonical ANF
                                                       -> X-G analyses
  {X-G, X-L.H} -> X-L.P LinkIds/reachability -> AP validation

AP -> shared .C semantic-consumer cutovers
{AP, X-N.H} -> X-N.C LLVM physical plan/renderer
{AP, X-W.H} -> X-W.C Wasm physical plan/renderer + playground consumer
               (X-N.C and X-W.C are peers, not dependencies of one another)

{all .C cutovers, X-L.C, X-N.C, X-W.C} -> X-X legacy deletion
```

`.P` checkpoints adopt an authoritative producer into the draft and compare it
against legacy behavior. `.C` checkpoints switch physical consumers only after
AP validation. `.H` checkpoints improve today's physical state/input seam
without claiming semantic authority or consuming AP. They may be milestones
inside one stage issue; the suffixes make the no-cutover-before-validation rule
reviewable.

**Landing versus development.** The lanes above permit parallel worktrees,
prototypes, tests, and review. They do not permit simultaneous compiler-source
landing: compiler-source snapshots and selfproc goldens are re-cut, never
text-merged, so only one such PR is in flight. Architecture PRs interleave with
typechecker PRs in that lane; high-severity fixes take priority.

### X-0 (#1399) - sole elaboration-to-engine contract

X-0D publishes additive `DraftSemanticProgram` records beside current
`CProgram`/install tables and compares every fact. Draft constructors remain
visible and carry provenance per field. X-0D has no producer dependency and may
land before the typechecker arc completes. X-0V lands only after required
upstream producers are authoritative; it validates and mints opaque
`ValidSemanticProgram`. No semantic behavior changes and no bug closure claim.
The typed Core dump is the primary structural receipt.

### X-A (#1400) - canonical ANF and AP substrate

Add stable serialization, validation, and an interpreter. Start with
behavior-preserving normalization, then build shared analyses over ANF. AP is
opaque only after all analysis validators pass. No physical emitter switches
until equivalence and malformed-plan controls are green. X-A alone mints
generated `CallableId`s from stable source-node/role paths; V contains only
`SourceCallableId`s. X-A's design, fixtures, `StableNodeId`, serializer, and
validator harness may be developed before X-0V; the authoritative V -> ANF
lowerer and canonical/AP claims may not land before X-0V.

### X-I (#1401) - identity, visibility, and logical layout consumers

After each upstream namespace and owner-local identity is available, X-I.P
populates `DraftSemanticProgram` with records, fields, constructors, methods,
imports/re-exports, and authoritative ordinals. X-0V/X-A carry those facts into
V/A/AP; only then does X-I.C migrate identity/visibility consumers. Method
dispositions belong only to X-E. `private_mangle` becomes a renderer of resolver
decisions. Live direct consumer family: #1359, #1306, and #1397's emitted-symbol
half; closed #1300 remains a binding-set regression control. #1305 first
requires an upstream decision: resolve publishes the newtype constructor,
typecheck resolves the occurrence from a bare-name universe to another module's
constructor, eval follows typecheck, and the post-#1393 mangler refuses to
manufacture the newtype binding. X-I transcribes the authoritative binding set
only after that fork is settled. Adjacent upstream-stamping families are
contract tests, not stolen drain claims.

### X-T (#353, adopted) - semantic runtime types

Adopt #353. X-T.P stamps backend-neutral runtime facts into the draft and
compares them against each named recovery family; it never puts LLVM `LTy` in
V. After AP validation, X-T.C migrates physical consumers one family at a time
and deletes LLVM `inferSigs`/`typeOf` and Wasm `cexprIsFloat` fallbacks only when
those consumers read AP.

### X-C (#1402) - calling convention and application

After #1318 and #1137, X-C.P populates and compares one authoritative call shape
in the draft. X-A later uses validated V to produce exact/PAP/over-application
ANF, explicit eta/PAP nodes, and canonical identity-keyed closure captures.
After AP validation, X-C.C migrates definitions, closures, methods, and both
physical plans. X-C establishes the structural receipts for #1034, #1101, and
#826; the stage whose plan first diverges owns each repair. #1101's CAF +
distinct-caller boundary is a mandatory physical-call realization test, and
centralization alone is not a proof that it is X-C rather than X-N.

### X-E (#1403) - evidence and method disposition

After #993/#1113/#1082 and A-3's complete #1112 default-disposition carrier,
X-E.P populates explicit evidence and complete dispositions in the draft and
validates slot keys. After AP validation, X-E.C migrates all engines atomically
and retires route-word superset hedges, backend selection, incomplete
method-entry inference, and default synthesis. Direct/partial family: #1072
(reopened after an accidental docs-only closure), #1127, #1046, #1068, #1020,
#1265. #1072 may receive an earlier identity-safe targeted fix; X-E still owns
route-word/key-bucket retirement. For #1020, X-E owns complete-disposition
production and consumption; a trap after a correct disposition reaches the Wasm
physical plan remains X-W.

### X-G (#1404) - globals, matching, tail work

Represent `Force`, match/fallthrough targets, tail sites, and TRMC groups in AP.
Globals remain lazy unless AP carries the safe-eager proof in section 6. Retain
backend-specific mechanics. Use #1349 as a Wasm realization test for the known
non-self method tail-call class. It is already self-draining through
`test/wasm/diff_gzip.sh`'s `known_divergence` case, as recorded in
`test/MUST-FAIL-NOT-PINNABLE.txt`.

### X-L (#1405) - linkage, tags, and extern requirements

Adopt #347, #348, #377, #378, and #358. X-L.H can establish the semantic
`ExternCatalog` and validate collision domains already observable in current
output. After canonical callable identity/reachability exists, X-L.P builds
`ReachableExternRequirements` and injective abstract `LinkId`s before AP is
validated. X-L.C maps those completed facts to target symbols/tags/imports and
runs target-specific collision validators before changing sanitization. Include
impl/method symbols and the #1397 same-named-type control in the collision-domain
set. A sanitization fix without a collision check can convert loud invalid
output into silent aliasing.

### X-N (#1406) - native physical state and renderer

Adopt #357. X-N.H moves today's declaration-derived prerequisites into explicit
input records and today's remaining physical state into one per-emission
context; it can land before V/AP if it preserves installed inputs and
byte-identical LLVM. Resetting at `emitProgram` after callers install inputs is
not a valid implementation. X-N.C later lowers AP into the validated LLVM plan
and pure renderer. Preserve the self-compile fixpoint and prelude/program-half
shape throughout. The post-AP physical validator checks every direct named call
against the callee plan's prototype; it does not rely on LLVM opaque-pointer
verification (#1101).

### X-W (#1407) - Wasm physical state, scalar decision, and host ABI

Mirror X-N at the physical-contract level, not line-for-line. X-W.H can
consolidate today's reset/input lifecycle and assert product input-set parity
before AP, while preserving current behavior. The shipping playground's former
missing `installCtorFloatFields` was observed as P1 (record-field Float unary
negation) and P2 (constructor-pattern Float unary negation) illegal-cast traps
from parse-valid WAT. The focused repair installs the existing
`ctorFieldTypeNames allDecls` producer immediately after declared return types;
it does not close ambient input parity or X-W.H. X-W.C later validates reachable host requirements without weakening the complete
capability manifest, decides scalar mode by the criterion in section 8.1,
migrates both `wasm_emit_modules_main` and `playground_main`, and adds a
behavior-level self-host assurance arm to tracker #384's linkage-only coverage.

### X-X (#1408) - delete legacy authorities and add ratchets

Remove `install*` semantic hooks, route re-selection, backend type inference,
bare-name layout tables, emitter-only semantic Core variants, and fallback
authorities. Add structural checks preventing their reintroduction. This stage
lands last; until then, every migrated decision has one declared authority and
comparison assertions against the legacy path.

### High-severity work during migration

This S3 architecture arc never blocks an independently established S0/S1 fix.
Fix a live defect before V/AP when its cause is reachable without inventing a
second semantic authority; advance the narrow producer prerequisite when it is
not. An interim fix must not add backend synthesis, spelling-keyed tables,
ambient semantic state, route re-selection, or a quieter wrong answer. Repairing
one defect instance also does not by itself satisfy the structural stage exit.

#1072 is the discriminator. Draft PR #1081 correctly widens selection beyond a
topological prefix for the filed arrangement, but adversarial review reproduced
a new unrelated-module S0 because the widened universe is still keyed by bare
interface/type spellings. It cannot land in that state. Qualified identity is a
minimum prerequisite; a targeted identity-safe fix may precede #1113/X-E, while
final evidence references and route-word/key-bucket retirement remain X-E work.

## 13. Verification doctrine

### 13.1 Contract fixtures

Every centralized field needs a hand-derived fixture that asserts the field,
not just output. Required shapes include:

- source fields written out of declaration order;
- same-module records reusing one field spelling and interfaces reusing one
  method spelling, with different owner-local slots;
- same-spelled unrelated modules with different record layouts/types;
- constructor visibility through direct import, wildcard, and re-export;
- method returning a function with a strict prefix;
- two instances of one interface in one module, proving distinct impl-body
  `CallableId`/`LinkId` values under declaration-order permutation;
- exact, under-, and over-application across CAF and wrapper boundaries;
- full n-ary predicates and predicate-order permutations;
- superclass projection, inherited defaults, method-less impls, and overlap;
- a lazy global reached through structure, calls, dispatch, and genuine cycle;
- guard/refutable fallthrough and nested matches;
- monomorphic and polymorphic Int/Float operations;
- symbol/tag collision controls and target capability rejection.

### 13.2 Isolation/permutation control

The architecture's central regression is a P -> P+U -> P same-process test.
`U` reuses P's spellings for every namespace but is unrelated. Module/import/
declaration order is permuted. P's V/AP projection and observation must stay
identical. A positive control explicitly refers to U and must change the IDs and
result, proving the test can observe selection.

### 13.3 Malformed-plan tests

Tests mutate a valid internal plan to introduce a wrong field ordinal, missing
runtime type, arity mismatch, wrong-interface evidence ID, duplicate symbol/tag,
incomplete capability manifest, missing reachable host requirement, or uncoded
trap. Validation must fail before either serializer runs.

### 13.4 Stage gates

Every compiler-source increment runs the source typecheck and native fixpoint.
LLVM behavior changes run typed-IR, engine, dispatch-shape, prelude-object, and
relevant native gates. Wasm changes assemble, validate, execute, and run typed/
module/product gates. Shared TMC and capability populations retain parity plus
positive coverage. New gates must be observed red and fail on zero work.

### 13.5 Performance

Planning indexes are built once. Measure allocation and per-stage lower/emit
time with the benchmark-emitter two-rebuild discipline and rooted controls.
Byte-identical output proves semantics did not move; it does not prove the new
plan reduced cost.

## 14. Risks

| Risk | Required mitigation |
|---|---|
| Shared wrong decision makes every engine agree | hand-derived contract fixtures and plan assertions |
| New IR constructor swallowed by wildcard | exhaustive arms or explicit audited internal-error waiver; constructor-set gate |
| Plan adds cost before replacing scans | consumer-by-consumer deletion and allocation/time measurement |
| Typechecker and emitter arcs duplicate carriers | X-0 schema coordination; upstream issue dependency, no backend selection |
| Physical abstraction leaks into AP | field ownership table in every stage issue; reject LLVM/Wasm types in V/A/AP |
| Loud path becomes silent during fallback removal | preserve severity; could-not-pass-before fixtures for new values |
| Native fixpoint moves unexpectedly | two-rebuild/seed discipline and C3 receipts |
| Wasm host set drifts | derive host/import keys from `ReachableExternRequirements`, keep `CapabilityManifest` unchanged, no encoded count; preserve `diff_compiler_wasm_shim_parity.sh` until superseded by generated construction |
| Migration leaves two permanent authorities | X-X exit criterion and structural ratchets |

## 15. Tracker relationship

The revised typechecker plan is `TYPECHECK-TARGET-ARCHITECTURE.md` (SURVEY
AMENDMENT and RULED blocks); its section 8 emitter-coordination bullet links
back to R8 of this document.

The cross-backend epic #1398 is the architecture router. Existing #362 remains the
native conformance/performance router and #384 remains the Wasm physical/host
router. They are not replaced. Architecture stages adopt their relevant open
issues and link back; backend-specific residuals that do not challenge the
shared contract stay in those trackers.
