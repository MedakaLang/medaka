# Emitter target architecture - per-bug fit ledger

**Status:** CURRENT - S0/S1 fit at `f4fbcd0a` (2026-08-07).
Fit is against [`EMITTER-TARGET-ARCHITECTURE.md`](EMITTER-TARGET-ARCHITECTURE.md),
derived from the GitHub S0/S1 population and current source. This ledger
separates direct backend defects from upstream defects whose consequence is a
bad executable. A stage is credited only when its mechanism reaches the cause,
not because the issue mentions `build`, LLVM, Wasm, a segfault, or a wrong
binary.

**Evidence provenance.** This planning pass re-derived the issue population and
read each issue body, any repository pin, and named source paths; it did not
rerun every executable reproduction. Unless a row explicitly says otherwise,
"mechanism" below means the verified issue artifact plus source-consistency
review at `f4fbcd0a`, not a fresh independent execution by this document's
author. Predictions are target-architecture claims and remain unproved until a
stage's acceptance fixture flips.

**Tracker maintenance.** #1072 was accidentally closed by docs-only PR #1389
while its must-fail pin and source mechanism remained live; it was reopened on
2026-08-07. Draft PR #1081 fixes the filed arrangement but is blocked: review
reproduced an unrelated-module S0 when its whole-graph widening meets bare
interface/type keys. #1020's missing
`S1: loud breakage` and `verified` labels were restored from its reproduced
trap on the same date. #1075 is retained below as a branch residual: its coded
panic was verified on unmerged PR #1074. An attributed pinning-agent report
observes current `main` falling back to #1046's `meow|meow`; this planning pass
did not independently rerun that arm. #1075 is not silently dropped from the
open-issue population or reported as a branch behavior already on `main`.

## 1. Inclusion and verdicts

The source set is re-derived, never counted from prose:

```sh
gh issue list --label "S0: silent wrongness" --state open --limit 300
gh issue list --label "S1: loud breakage" --state open --limit 300
```

Every current row was classified even when its owner is outside the emitter
arc. The verdict vocabulary is:

| Verdict | Meaning |
|---|---|
| `DRAINED-BY` | the named stage removes the established cause and states a falsifiable prediction |
| `CONTRACT-DEPENDENCY` | upstream work fixes the cause; this architecture must consume the result and can prevent backend reinvention |
| `PHYSICAL-RESIDUAL` | shared facts may improve localization, but one physical backend still owes a lowering fix |
| `EVAL-RESIDUAL` | product AST evaluator, not LLVM/Wasm emission |
| `BRANCH-RESIDUAL` | verified on an unmerged prerequisite branch, not established on current `main` |
| `OUT-OF-ARC` | frontend, type soundness, diagnostics, or harness issue not owned here |
| `NOT-ESTABLISHED` | symptom is real but no mechanism-to-stage claim is yet justified |

## 2. Summary

| Family | Direct high-severity members | Primary target owner |
|---|---|---|
| Record/field order in emitted layout | #1306 | X-I |
| Record identity stamped wrongly upstream | #1216 current residual; #1281/#1382 closed controls | fresh #1216 trace; typechecker identity/record work; X-I contract |
| Constructor import/export visibility and mangling | #1359; #1305 upstream-decision dependency; #1300 closed control; #1396 eval residual | upstream export contract, then X-I; eval peer separate |
| Impl/method symbol identity | #1397 | upstream identity + X-I/X-L; eval/Core-eval peers |
| Complete default-method identity/disposition | #1265, #1020 | A-3/#1112 producer, then X-E; Wasm residual |
| Evidence/route realization | #1072, #1127, #1046, #1068; #1075 branch residual | identity-safe defect fixes where available; #993/#1113/#1082 then X-E for structural retirement |
| Calling convention/PAP/closures | #1034, #1101, #826; #1043 split | #1318/#1137 then X-C; #1101 residual X-C/X-N pending receipt |
| Wasm tail realization | #1349 | X-G/X-W |

The rest of the live S0/S1 set is accounted for in sections 4-7 so a reader
cannot confuse "not an emitter bug" with "not reviewed".

**Self-draining coverage is derived across all harnesses, not from
`must_fail` alone.** #1020 and #1068 are pinned by `engine_divergence.txt`;
#1127 by the dict-semantics ledger; #1349 by `test/wasm/diff_gzip.sh` and its
`MUST-FAIL-NOT-PINNABLE` row. At this derivation point #1396 and #1397 have no
repository self-draining artifact, and #1075 explicitly owes one if its
prerequisite branch lands. Those are test debts on the issue, not evidence for
or against the architecture verdict.

**#1075's debt update, 2026-09-01 (sprint `argtag-decidability`, #2445
closeout).** The prerequisite this row names (#1046's arg-tag arm-set fix)
landed at `33385a53`, so on this row's own wording the `build-run` pin is now
owed. It remains UNPAID, and not silently: #1075's exact spelling (a
method-less impl at a PRIMITIVE head — `impl Speak Int where`) is not
`test/argtag_matrix_fixtures/`'s enrolled `A4_mixed_primitive__B2_one_default`
cell, which places the method-less impl at the *user* head (`Cat`) with `Int`
defining — the mirror, not the match (measured identical on all three verbs,
see `S-4-narrow-where-decidable.md`'s report and #1075's own issue-comment
amendment). Two independent blockers keep the pin from being paid this
slice: (1) the local-pin narrowing that would let #1075's own repro reach
`build` at all is not landed (S-4 took the sprint's pre-licensed
no-narrowing discharge — see `docs/KNOWN-GAPS.md`'s "Known over-reject"
entry), so a `must_fail_fixtures/` row graded on ordinary `check`/`run`/`build`
now MALFORMEDs at `check` (`T-LOCAL-CONSTRAINED-MONO`, exit 1) rather than
reaching the emitter panic the issue records — the same MALFORMED-verb problem
`1046-methodless-impl-argtag-dispatch/claim.txt` already documents for its own
row; and (2) reaching it at all needs the same test-only unpin hatch the
census uses, and `test/argtag_matrix_fixtures/` is a shared corpus
([T-SHARED-CORPUS]) — extending it with an eleventh cell is a corpus decision
this closeout slice is not licensed to make unilaterally. Left for the
end-of-sprint review round to accept or decline adding
`A4_mixed_primitive__B2_one_default_at_primitive_head` (S-4's Notes item 3
names the same candidate).

## 3. Direct and split backend families

### 3.1 Record creation order - #1306

**Verdict: DRAINED-BY X-I.** `core_ir_lower` preserves record-literal source
order in `CRecord`; LLVM `emitRecordCreate` and Wasm `emitRecordRef` fill slots
positionally. The language assigns by field identity, not written order.

**Prediction.** With owner `Ident`, owner-qualified `FieldId`, and canonical
ordinals carried and validated, every
permutation of one literal's assignments produces the same logical layout and
value. A positive control changing the labels changes the value. Both physical
plans consume canonical declaration order.

### 3.2 Cross-module record collisions - #1216; closed #1281/#1382

**Verdict: #1281/#1382 DRAINED upstream by PR #1395 and retained as X-I contract
controls; #1216 is NOT-ESTABLISHED pending a fresh post-#1395 trace.** The closed
pair originally looked like bare-name tables in `llvm_emit`, but typed Core
proved the wrong owner was stamped earlier through `resolveFieldRecord ->
lookupRecordByMangledHead -> resolveFieldByOwners -> resolveFieldAmbiguous ->
pairRecordByName`. PR #1395 narrows that ambiguity by the receiver's declaration
identity and closes the field-order/type-divergence/memory-safety pair. Its own
verification says #1216 still reproduces through a residual bare-key path, so
the closed pair's mechanism must not be copied onto #1216 without a new trace.

**Prediction.** For every residual, typed Core must first name the hand-derived
owner `Ident`. X-I then deletes bare-name record authorities from both physical
plans. An unrelated same-spelled record cannot change the target record's V/AP
projection. If typed Core still carries the wrong owner, X-I has nothing correct
to transcribe and gets no credit.

### 3.3 Constructor visibility and the mangler - #1305, #1359; closed #1300; #1396 eval

**Verdict: #1300 DRAINED by PR #1393 and retained as an X-I binding-set control;
#1359 remains DRAINED-BY X-I; #1305 is a CONTRACT-DEPENDENCY; #1396 now has only
an EVAL-RESIDUAL.** `private_mangle.mdk` still independently reconstructs
constructor exports/imports, but current source includes #1393's corrected
member and visibility rules:

- `ctorMemberEntry` now preserves a constructor named directly with `Ctor(..)`
  (#1300's closed regression control);
- `ctorExportEntries` deliberately has no newtype arm, exposing the deeper
  resolve/typecheck disagreement in #1305 as a loud build refusal;
- constructor exports have no re-export-chain peer of value exports (#1359);
- a private constructor can still outrank a public imported constructor in eval
  (#1396), while #1393's `VisPublic` gate repaired the native half.

#1305 cannot be assigned directly to X-I until the language/front end decides
whether a newtype constructor is exportable: resolve publishes it, typecheck
resolves the occurrence from a bare-name universe to a different imported
constructor, eval follows typecheck, and the mangler now refuses to manufacture
the newtype binding. No import-driven mangler can agree with both upstream
answers; the consumer rule is clear only after that producer fork has one
authoritative answer.

**Prediction.** The resolver publishes an identity-stamped constructor binding
set for each module; mangling renders exactly that set and cannot add or remove
a binding. A binding-set equality gate covers direct members, `Type(..)`,
constructor-name `Ctor(..)`, wildcard imports, newtypes, private constructors,
and multi-hop re-exports. Eval and Core eval consume the same visibility result
or remain separately wrong; X-I does not claim their fix by association.

### 3.3a Same-named type impl symbols - #1397

**Verdict: CONTRACT-DEPENDENCY on upstream qualified type/instance identity,
then DRAINED-BY X-I/X-L for the emitted-symbol half; observed EVAL-RESIDUAL for
product eval plus a Core-eval peer obligation.** Two unrelated modules' distinct
`Thing` types and `impl
Label Thing` declarations collapse to one `@mdk_impl_Thing_label`. The issue
report filed against `c5fda728` directly reports product eval/native
wrong output and shows one emitted LLVM definition; it additionally reports
three-engine agreement, but does not include the Wasm command/output.

**Prediction.** V carries distinct type `Ident`s and solver-owned `InstId`s; AP
linkage assigns distinct `LinkId`s; LLVM/Wasm collision validators cover
impl/method symbols.
Permuting module order cannot change either result. `evalModules` is an observed
residual; `cevalModules` is its source-consistent peer obligation and must be
tested rather than reported as already observed. Both must consume the same
qualified identity in lockstep; fixing only emitted linkage does not drain the
evaluator path(s).

### 3.4 Defaults share method spelling but not identity - #1265

**Verdict: DRAINED-BY A-3/#1112 plus X-E.** Core retains two distinct interface IDs,
but LLVM `defaultFnName`, Wasm `defaultFnNameW`, and eval's default cell key the
entity by method spelling and receiver tag. Two interfaces with one method name
on one type collapse to one body. Every engine agrees on the wrong answer, and
import order chooses which one.

**Prediction.** Elaboration carries one complete disposition per (`InstId`,
`MethodId`) (`Supplied` or `InheritedDefault`). Defaults have distinct
identity/linkage even at the same receiver tag. The hand-derived
`A-default|B-default` fixture is invariant under import order, and its boundary
control with distinct receiver types remains correct.

### 3.5 Missing Wasm default arms - #1020

**Verdict: CONTRACT-DEPENDENCY on A-3/#1112 with PHYSICAL-RESIDUAL in Wasm.** A
cross-module method-less impl may lower to zero `CImplEntry`; desugar, eval,
LLVM, and Wasm each answer method-table completion differently. Wasm's
`emitMethodDispatchRef` also lacks the native default-chain peer and reaches
`unreachable`.

**Prediction.** A-3 makes the complete disposition visible before the backend
fork. Wasm then lowers supplied/inherited dispositions rather than synthesizing
them. If the complete disposition reaches Wasm and the fixture still traps,
that remaining defect is strictly X-W physical realization.

### 3.6 Cross-module route word and most-specific winner - #1072

**Verdict: CONTRACT-DEPENDENCY on qualified identity for a targeted defect fix;
DRAINED-BY #1113 then X-E for structural retirement.** The call site's module sees a
topological-prefix instance set and stamps a bare head; LLVM
`implEntryRouteWords` ORs that word into every arm at the head. Reordering
modules changes the answer. Merely stamping the prefix's canonical instance was
built and disproved: it encodes the wrong prefix decision in every engine.

Draft PR #1081 widens selection to the whole graph and fixes that arrangement,
but review reproduced an unrelated module's same-named interface/type capturing
the route because the widened tables remain bare-keyed. The prefix had been
accidentally supplying scope to an unscoped key. Therefore #1081 cannot land as
written, but neither must the live defect wait for all of X-E: once candidate
identity is qualified, an identity-safe targeted fix may precede #1113.

**Prediction.** Whole-graph K plus evidence references distinguish `InstId`,
`EvidenceParam`, and `SupersPath`; the route-word hedge and
`KeyBuckets` collision counters retire rather than being identity-re-keyed.
Both module arrangements select the specific instance. X-E cannot start before
#1113's prerequisite identity/whole-graph work.

### 3.7 Superclass projection - #1127

**Verdict: DRAINED-BY #993 + #1113, then verified by X-E.** A superclass dict
must be projected from the supplied evidence, not re-resolved through a coarse
runtime word. Current `activeDictVars`/route-word machinery can select a general
instance instead.

**Prediction.** Typed Core contains `EvidenceSuper` rooted in the caller's
evidence. No backend selector can replace it with a fresh `inst` choice. The
selected evidence identity is asserted structurally as well as by output.

### 3.8 Method-less impl through a local lambda - #1046

**Verdict: CONTRACT-DEPENDENCY on #1082 and #1113; PHYSICAL-RESIDUAL only if it
survives.** LLVM `emitMethodArgDispatch` has a sole-group direct-call shortcut,
and method-less impls are absent from entry-derived groups. The site reaches
arg-tag dispatch because the local binder did not abstract evidence.

**Prediction.** After local evidence abstraction, the site carries explicit
evidence and cannot reach the sole-group shortcut. If a direct arg-tag site
without local evidence remains and still misroutes, X-E owns that residual. Do
not describe #1075's coded-panic state as a fix: it is a verified
`BRANCH-RESIDUAL` of unmerged PR #1074. #1075 remains tracked and owes its stated
`build-run` pin if that prerequisite lands.

### 3.9 Wasm route recomputation - #1068

**Verdict: DRAINED-BY #1113 plus X-E, with a Wasm PHYSICAL-RESIDUAL.** Wasm
`implEntryRouteKeyW`/`headTagUniqueW` recomputes route uniqueness from entries
using a different population from typecheck's stamp.

**Prediction.** Wasm consumes the evidence reference and frozen admissibility
from typed Core. No function reconstructs a semantic route key from
`CImplEntry`. If WAT still fails after consuming the right evidence, X-W owns
only the instruction-level residual.

### 3.10 Method/source arity and PAP timing - #1034

**Verdict: DRAINED-BY #1318 -> #1137 -> X-C.** `methodArgTys` walks the entire
declared arrow spine, while eval uses clause pattern count. A method returning a
function is therefore mistaken for a higher-source-arity method and its strict
prefix is deferred in a PAP.

**Prediction.** One hand-derived `CallShape` distinguishes source strict-prefix
arity from result-function shape and dictionary prefix. Calling the source
arity executes the prefix exactly once and returns a closure. Every engine
consumes the same shape; the fixture replaces the divergence signal that
centralization removes.

### 3.11 Top-level CAF returned closure - #1101

**Verdict: CONTRACT-DEPENDENCY on X-C; residual owner NOT-ESTABLISHED between AP
production and X-N lowering.** Native emits a call to a
one-parameter plain function with two arguments when a CAF's returned closure
is applied in another top-level function. Definition arity is correct, so the
extra argument arises in native call/application lowering; the exact source
arm remains less certain than #1034.

**Prediction.** ANF splits the producer call from closure application and the
LLVM physical validator rejects any prototype mismatch, including a direct
named call checked against that callee's plan prototype rather than relying on
LLVM opaque-pointer verification. The fixture's physical
plan contains one direct call followed by one closure call. If it already does
and the binary is wrong, X-N owns the residual rather than X-C. If AP itself
contains the oversized direct call, X-C owns it. X-C therefore cannot claim this
issue merely because it centralizes call classification, and X-N cannot claim it
before the structural receipt identifies the first divergence.

### 3.12 Wrapper plus method returning closure - #826

**Verdict: CONTRACT-DEPENDENCY on #1137/X-C with LLVM PHYSICAL-RESIDUAL; exact
root NOT-ESTABLISHED.** The native segfault is a pure emit-path symptom, but
existing eta/capture/layout diagnoses are hypotheses.

**Prediction.** The shared plan asserts call shape and logical capture order.
The LLVM validator asserts closure layout and prototypes. Whichever first
differs from the hand-derived fixture identifies the owner; the architecture
does not claim the fix in advance.

### 3.13 Block-let method helper - #1043

**Verdict: CONTRACT-DEPENDENCY on #1082 for the typecheck/evidence half;
PHYSICAL-RESIDUAL for the current unlocated emitter panic.** Uniform local
evidence should prevent the accepted site from reaching constructor-less
arg-tag emission. Runtime diagnostics still need their own location work.

### 3.14 Wasm non-self method tail calls - #1349

**Verdict: DRAINED-BY X-G/X-W.** `emitAppTail` emits a tail call for exact
saturated self-method routes but returns normally for another statically-known
`CMethod`; deep do-notation recursion over that path exhausts Wasm while native
succeeds.

**Prediction.** The shared plan marks the call as semantic tail and exact. The
Wasm physical plan contains `return_call`/`return_call_ref`; a deep fixture and
WAT shape assertion both fail before the fix and pass after it. The existing
`test/wasm/diff_gzip.sh` `known_divergence` case is already the self-draining
behavior pin, as recorded in `test/MUST-FAIL-NOT-PINNABLE.txt`.

## 4. Upstream identity and obligation families

These issues can produce a wrong/crashing binary, but the cause is already
present before physical emission. They are contract tests for V, not direct
drain claims.

| Issues | Cause / owner | Emitter-architecture obligation |
|---|---|---|
| #1276, #1386 | alias-qualified method provenance/obligation pass placement | V must reject unresolved evidence; X-E consumes only checked evidence |
| #1383, #1376, #1377 | bare-keyed record/constructor pairing in typecheck | X-I accepts only resolved owner IDs; cannot repair a wrong stamped ID |
| #1353, #1351, #1070 | cross-module universe visibility/bare registries | typechecker Stage A/A-3; X-I/X-E must not recreate spelling tables |
| #1330 | obligation dedup skips the check | invalid program must never reach V; validator rejects missing evidence |
| #1326, #1369 | constrained value identity/re-export channel | carried value `Ident` and `CallShape`, no bare-name arity lookup |
| #1302 | private interface contaminates candidacy | upstream whole-graph/visibility contract |
| #1288 | interface/constructor re-export collapse | resolver export contract; X-I renders it |
| #1182, #1180, #1154, #1174, #1183 | instance candidate/commit timing | typechecker K/S/E; X-E transcribes only final evidence |
| #1161, #1177, #1169 | dictionary slot is a tyvar rather than predicate | #1318 before #1137/X-C |
| #1052, #1040, #1133, #1082 | local/recursive evidence abstraction | #1082/typechecker schedule; X-C/X-E consume resulting call shape/evidence |
| #1150 | value restriction misclassifies alias-qualified call | typechecker identity/value restriction; V cannot certify an unsound program |
| #1396 | visibility set differs across typecheck/eval/mangler | X-I owns mangler consumption; eval/Core-eval peers remain explicit |

## 5. Eval-only realization families

| Issues | Verdict |
|---|---|
| #1292 | EVAL-RESIDUAL: `ctorToTypeRef` chooses the wrong type under constructor-name collision |
| #1343 | EVAL-RESIDUAL: private constrained helper collides in eval frame; native is correct |
| #1071, #1062 | EVAL-RESIDUAL after shared evidence/default contracts; native is correct on the filed shapes |
| #1125 | EVAL-RESIDUAL plus typechecker B-1/B-2 evidence dependency |

Moving product `run` to V/AP evaluation could retire some duplicate evaluator
machinery, but this architecture does not assume that decision. Until then,
`evalModules` and `cevalModules` remain lockstep consumers.

## 6. Type/effect soundness outside the backend arc

| Issues | Verdict |
|---|---|
| #1121, #1103, #1100, #1098, #1095 | OUT-OF-ARC: row variance/coverage/unification; invalid programs must not reach V |
| #817, #825, #819 | OUT-OF-ARC: graded-interface/effect/impl rigidity work |

The backend contract still has a negative obligation: no "best effort" emission
of a program whose evidence or effects failed validation.

## 7. Frontend, diagnostics, and harness issues

| Issues | Verdict |
|---|---|
| #1217 | OUT-OF-ARC: record-rest pattern lowered to wildcard before backend; native rejection is a consequence |
| #1373 | OUT-OF-ARC: named-field variant re-export resolution |
| #733 | OUT-OF-ARC/identity residual: derive the still-live wildcard row before assigning it |
| #1362 | OUT-OF-ARC: JSON/MCP check path omits internal-extern restriction |
| #1394 | OUT-OF-ARC: must-fail harness mistakes malformed build for a drained issue |
| #1191 | OUT-OF-ARC: flat/prelude typecheck collision |

## 8. Architectural debt with lower current severity

These issues do not become S0/S1 merely because the architecture adopts them,
but they close prevention gaps:

| Issues | Target owner |
|---|---|
| #353 | X-T: semantic runtime types, retirement of recovery twins |
| #357 | X-N/X-W: explicit per-emission state and install-hook retirement |
| #358 | X-L: semantic extern catalog and target dispositions |
| #347, #348 | X-L/X-N: native symbol/tag injectivity |
| #377, #378 | X-L/X-W: Wasm symbol/tag injectivity |
| #748 | X-L/X-N validator: duplicate emitted define cannot silently run |
| #380 | X-W: declared capability rejection quality |
| #375, #376 | X-W host manifest/flush contract |

## 9. Closed incidents that constrain the design

| Incident | Architectural lesson / required control |
|---|---|
| #59 | a one-backend semantics fix is half a fix |
| #553/#561 | shared analysis can make both backends uniformly wrong; use unrelated/global controls |
| #674/#712 | spelling and built-in constructor assumptions are not identity |
| #948/#1024/#1036/#1037 | entry population is not a complete instance method table |
| #719 | nullary impl-method bodies require one shared memoization/timing decision |
| #368/#373 | constants and widths copied across physical representations are wrong |
| #346 | undefined conversion behavior can become pointer/address disclosure |
| #672/#762 | emitter, optimizer, and runtime constant folding are separate semantic paths |
| #759 | fixing literal values does not fix literal patterns; audit consumer sets |
| #374 | neighboring Wasm control arms can emit invalid modules independently |
| refutable-guard fallthrough incident | node-carried target beats ambient mutable emission state |

## 10. Stage acceptance matrix

| Stage | Must flip / establish | Must not claim |
|---|---|---|
| X-0 | one validated additive contract, product/probe input parity | behavior fix |
| X-A | V/ANF/AP equivalence and malformed-plan rejection | engine agreement proves semantics |
| X-I | #1306 and mangler set; identity controls for collision families | upstream wrong-record stamp is repaired downstream |
| X-T | deletion of each named recovery heuristic after migration | all Float bugs are fixed |
| X-C | structural call-shape receipts for #1034/#1101/#826 family | central arity alone fixes physical closure bugs |
| X-E | evidence/default identity from A-3 and no engine selection | prefix-scoped selection encoded more strongly is correct |
| X-G | explicit force/tail/control plan; #1349 Wasm realization | one physical TMC implementation fits both targets |
| X-L | injective validated domains before sanitization changes | hash collision is impossible without a check/construction |
| X-N.H/X-W.H | explicit current inputs/state and same-process isolation before AP | resetting away caller-installed inputs; behavior fix hidden as hygiene |
| X-N.C/X-W.C | no ambient semantic prerequisites; validated AP physical plans | local output buffers/counters must be purely functional |
| X-X | legacy authorities deleted and ratchets observed red | a second silent fallback is harmless |

The burden of proof is intentionally asymmetric: a `DRAINED-BY` row needs a
mechanism and a prediction. If implementation contradicts either, the row moves
to `NOT-ESTABLISHED`; the issue is not forced into the plan.
