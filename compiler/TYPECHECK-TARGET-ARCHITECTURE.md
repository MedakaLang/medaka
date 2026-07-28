# Typechecker Target Architecture — the ground-up design

**Status:** PROPOSAL — the idealized architecture for the full type-system pipeline
(resolve identity → declaration analysis → inference → entailment → elaboration →
global checks), designed from the semantics in `docs/spec/DICT-SEMANTICS.md`,
`docs/spec/EFFECTS-SEMANTICS.md`, and `docs/spec/SHADOW-SEMANTICS.md`, informed by
the derived map in [`TYPECHECK-ARCHITECTURE.md`](TYPECHECK-ARCHITECTURE.md). It
answers *"what would this system look like designed from scratch, knowing what we
now know?"* and maps every element to the current implementation and to a staged
migration in which `main` stays green at every step.

**What this is not.** Not a description of current behavior (that is the map), not
a license for a big-bang rewrite (§7 is explicit that every increment is a
mergeable PR), and not a re-derivation of the specs — where the target disagrees
with today's code, the spec is the authority; where the spec is silent, §6 files
the owed spec paragraph as its own task.

**Reading order.** §1 states the design laws. §2 gives the component model. §3
maps it to the current code. §4 is the traceability matrix — the reason to believe
this architecture *eliminates classes* rather than instances. §5 lists the
decisions this proposal reopens (with justification) and the ones it deliberately
does not. §6 is the migration DAG. §7 is verification doctrine. §8 is risks.

---

## 1. Design laws

Every recurring defect class in this subsystem's history violates one of five
laws. The target architecture is the smallest structure in which all five are
enforced by construction rather than by discipline.

**L1 — One judgment, one implementation.** Each spec judgment (entailment,
elaboration, the effect judgment, the shadow resolution function, exhaustiveness)
has exactly one implementation, parameterized where call sites differ, never
forked. A "second copy for the other path" is the repo's #1 recurring bug shape
(P0-9, the imported-module bug, #873, #992's table of divergences, the 8-vs-9
stamper orders). Where two realizations are irreducible (interpreter vs emitter),
they consume one *decision* computed upstream and a differential gate diffs them.

**L2 — Identity is resolved, never re-derived from spelling.** After the resolve
phase, no component keys anything by a bare `String` name. Types, aliases,
interfaces, methods, records, constructors, and bindings all carry
module-qualified identity assigned once, at resolve (the Haskell/Rust model,
decided 2026-07-25). A flat table keyed by bare name, populated across module
boundaries, is last-write-wins with silent loss — 10 confirmed instances
repo-wide (#1070), and for five of them per-table re-keying is *impossible*
because the collapse already happened upstream in the `Mono` representation.
The law therefore lands at the substrate: `TCon`/interface/method references
carry identity, so a bare-name table becomes unwritable, not just inadvisable.

**L3 — Order is either specified or irrelevant.** Wherever the spec makes a
result order-free (instance selection: *"never of search order, declaration
order, or resolution position"*, DICT §3; C4's single instance environment),
the implementation must be structurally order-free — computed once from a
whole-graph environment, not re-derived from a per-module view (#1072's
mechanism). Wherever order is genuinely semantic (route-stamper sequencing,
C5; numeric-literal defaulting relative to obligation checking), it is written
in exactly one place — one table, one driver — so "the two paths disagree on
order" (§5.3 of the map) cannot be expressed. Residually order-sensitive scans
that exist to match oracle behavior stay order-preserving until the clause
governing them says otherwise (see §5, reopened decision R2).

**L4 — Evidence is structured, and uniform at every binder.** Evidence is the
tree of DICT §2: superclass dicts in a distinguished `supers` component
(projection, never re-resolution — the missing `entailSuper` rung), instance
context captured at construction. Every binder that generalizes over a
constraint — top-level fn, impl method, default method, **and local
`let`/`where` binding** — abstracts dictionary parameters by the same `gen`
rule (DICT §4). The current exception for locals (`dict_pass` touches only
top-level defs and impl methods) is the structural cause of the whole
C family (#866/#1040/#1043/#1045/#1052) and of the interim pin that is itself
unsound (#1052); #1082 is this law's migration vehicle.

**L5 — The spec is executable.** Every normative clause has (a) a row in a
per-spec enforcement table (clause → site → keying assumption — the form
SHADOW §3 already has and the S0-densest layer lacks), and (b) at least one
conformance fixture whose expected value was derived from the clause by hand,
never captured from an engine — because eval is a known-wrong oracle in at
least five open S0s, and all three engines agreeing proves nothing (#1047,
#1094). A rule with no site is an unimplemented clause; a site with no clause
is an owed spec paragraph; both are findings, and the table makes them
enumerable instead of discoverable-by-incident.

---

## 2. The component model

Seven components. Boundaries are drawn by *contract*, not necessarily by file —
§5 (R3) explains which are separate modules and which are regions of
`typecheck.mdk` with a single gateway, respecting the evaluated-and-rejected
HM-core/dispatch file split.

```
  R  resolve identity      (frontend/resolve.mdk — extended)
  K  declaration analysis  (whole-graph: CE, IE, DataEnv — new gateway)
  I  inference             (the 25-arm infer walk — kept intact)
  S  solving               (ONE entailment engine + ONE resolution pass)
  E  elaboration           (gen/gen-rec/gen-sig at every binder; routes+dicts stamped)
  G  global checks         (coherence, escape/launder, kinds, exhaustiveness bridge)
  D  diagnostics           (error-path machinery — extracted)
```

### R — Identity (in `resolve.mdk`, upstream of typecheck)

Resolve assigns every declaration a qualified identity `(originModule, name)` and
resolves every occurrence to it, for **all** namespaces: values (already done via
binder ids), types, aliases, interfaces, interface methods, records/fields,
constructors. Two modules may declare the same name; the collision surfaces at a
*use site* as an ambiguity diagnostic (`Ambiguous occurrence`), never at the
declaration, never silently (decided: Haskell/Rust model). The AST carries the
resolution — `DInterface`/`DImpl`/`TyCon` reference identities, not spellings.

Consequences downstream:

- The typechecker's `Mono` representation distinguishes two modules' `Cfg` — the
  five #1070 tables whose re-keying was *impossible* ("both modules' `Cfg` are
  the same `Mono`") become keyable, and then become unnecessary as tables get
  replaced by K's environments.
- The shadow machinery's four keying assumptions (SHADOW §3 rows for S1
  detection) collapse: shadow-hood is an intersection of *identities*, so the
  mangled/bare asymmetry that defeated name-intersection detection cannot recur.
- `private_mangle` stays emit-only and stops being load-bearing for semantics:
  it renders identities into symbols; it no longer *creates* the only
  disambiguation that exists (#1070's root cause note).

### K — Declaration analysis (whole-graph, before any body inference)

One pass over the topologically-loaded module graph builds three environments,
keyed by qualified identity, **assembled once and never per-module**:

- **`CE`** (class environment): interfaces with declared parameter kinds
  (EFFECTS §6.1–§6.5), method schemes, superclass predicates; W1 acyclicity;
  the method-effect-var well-formedness rules (Option A + argument-occurrence
  coverage, EFFECTS §6) checked here, at the declaration, where they are
  decidable without dispatch.
- **`IE`** (instance environment): every impl with its full head, context, and
  method table; W2 termination; impl completeness and phantom-method rejection
  (currently enforced with no spec — the owed paragraph is task S-2 in §6);
  declaration-time overlap diagnostics (advisory (a)-warnings; acceptance stays
  per-goal C1(c)).
- **`DataEnv`**: datatypes, constructor schemes, records and field ownership,
  aliases with cycle rejection.

**Why whole-graph is load-bearing, not a style choice.** C4 (single instance
environment) and I2 (global `IE` after import resolution) are *spec clauses*.
The current architecture approximates them by marshalling 14-cell universe
snapshots per module (`loadDataUniverse`/`storeDataUniverse`/
`appendUniverseAccums`) — and the approximation is exactly where #1072 lives:
a site's module sees only its own slice of `IE`, concludes there is no
collision at a head, and stamps a bare-head key that the linker then ORs into
every arm. When `IE` is one global environment consulted at solving time,
*"the site's module didn't see the other impl"* becomes inexpressible.
Import scoping remains a **visibility** filter applied at name resolution (R),
never an identity or instance-set filter (I2's exact wording).

### I — Inference (kept structurally intact)

The 25-arm `infer` walk, application/method/match/pattern/binop inference, HM
with levels and value restriction, effect-row inference per EFFECTS §3. This
component is deliberately conservative: the map shows the HM core is good, the
file-split around it was evaluated and rejected, and the `pending*` deferred-site
channels are HM-forced (a route depends on which tyvar survives unification).
Three changes only:

- **Sites and obligations get one record shape each.** Dispatch sites of every
  flavor (return-position method, binop/unop, arith, arg-stamp, rec-dict,
  method-dict, RLocal) are recorded as one `Site` record with a kind field, into
  channels that remain per-kind but share storage discipline (`Windowed`), and
  obligations complete the #991 unification (one `UObligation` with live
  provenance arms; `implOblToU` retired).
- **Numeric-literal defaulting becomes a solving step** (see S), not an
  interleaved family of five cells whose ordering differs per driver path.
  Inference *records* literal sites and taints; it does not decide representations.
- **Effect-row unification consults one polarity/invariance discipline.**
  `unifyRowN` and the re-open machinery already implement §5's
  polarity-carrying subtyping encoding correctly for arrows; the defects are
  positions that don't consult it: the `Effect`-kinded index slot must unify
  invariantly (#1094 — the closed~closed no-op arm is correct *for arrows* and
  wrong for indices), the same-tail arm must still check the atom prefix
  (#1103), and `rowArgOf`'s catch-all must be a kind error, not `pureRow`
  (`Box Int Int` silently read as `Box ⟨⟩ Int`). Structurally: the row unifier
  takes a position mode (arrow-covariant | index-invariant), and mode is set by
  the caller from the *kind* of the position — one function, one table of
  positions, no per-arm ad hoc leniency. Invariance propagates through types
  that transitively contain a write channel (`Ref`/`MutArray`/`HashMap` and any
  wrapper reaching them, #1098) as compiler-internal variance computation — no
  user-facing annotations (decided 2026-07-27).

### S — Solving: one entailment engine, one resolution pass

**Entailment** is DICT §3 verbatim, in one engine (today's `entail` is already
the file's best subsystem — 620 lines, 5 cells; this component *finishes* it):

- `assum` → `super` → `inst` with the assum/super-over-inst precedence;
- **`entailSuper` becomes a real rung**: superclass evidence is a projection
  into the evidence tree's `supers` component (§993's target), replacing the
  flatten-into-sibling-slots pass (`expandSupersTable`) and the four duplicate
  super-closure walks with **one** closure combinator parameterized by payload;
- `inst` selects `min⊑(match(IE, π))` — the unique most-specific instance —
  and **every** resolution position reaches dispatch through this one selector
  (the uniform-resolution corollary). No first-match, no declaration order, no
  bare-head keys anywhere downstream: the *selected instance's identity* is
  what gets stamped into routes and emitted into dispatch tables, so an engine
  cannot re-derive (and mis-derive) the choice from a coarser key (#1072,
  family B: #1071/#1062/#1046/#1075/#1034).

**Resolution (the stamper pass)** drains the recorded sites **in one order,
written once**. Today two drivers run 8 vs 9 stampers in different orders and
the source's own ordering comment is stale (map §5.3); C5-style constraints
("RLocal must override what resolveSites/resolveArgStamps stamped on the same
ref") become *the order table's* content, asserted in one place. With a single
driver (E below) there is exactly one instance of this pass.

**Defaulting** (numeric literals) runs here, at a specified point relative to
obligation checking — identical on every path because there is only one path —
with the spec paragraph (currently: none) written as part of the migration
(#563/#564 get their protection rule from that paragraph, not from cell
placement).

### E — Elaboration: one driver, one mode, evidence at every binder

The single most consequential structural change, and the one the map shows is
missing with no issue filed (§7.1, §7.6):

**One driver.** The multi-module driver is the only driver; a single file is a
1-module graph. This is DRIVER-COLLAPSE-PLAN's own stated invariant ("the
degenerate 1-module case automatically satisfies the flat path's invariants") —
marked IMPLEMENTED while §5 of the map measures 20 `match mode` branches, two
divergent stamper sequences, and a `Flat`-mode re-entry inside the promotion
fallback. The target deletes `CheckMode` entirely: `checkBodyImpl`'s spine runs
per module over K's global environments; the LSP/diagnostics output contracts
(`localSchemesOut`/`seedSchemesOut`, the §7.7 seam) are preserved explicitly.

**SCC-scheduled generalization dissolves the promotion fixpoint.** Today,
dict-eligibility for unsignatured constrained functions is discovered by a
mark-then-typecheck fixpoint that re-runs until the dict-passed set stabilizes —
and when the harvest is non-empty the whole bare sweep's results are *discarded*
and redone in `Flat` mode over a flattened joint program (map §5.1). Designed
from scratch: process bindings in dependency order (Tarjan SCCs over the
whole-graph call graph, cross-module topo order from the loader), generalize
each SCC once (`gen-rec`: one shared `λd̄.` prefix per group), and elaborate each
use site *after* its callee's scheme is final (`var`). A caller then never needs
re-marking, because the callee's constraint set is known before any caller is
elaborated. The fixpoint, the discard-and-redo, and the harvest machinery
dissolve into ordinary scheduling. What this requires and what it buys is
spelled out in §5 (R1) — it is the largest reopening in this proposal, and the
letrec scheduling order it fixes is currently **unspecified** (owed paragraph,
task S-2).

**Evidence at every binder (L4).** `gen`/`gen-rec`/`gen-sig` apply uniformly to
top-level bindings, impl methods, default methods (one `MethodBodyKind`-merged
driver per #992, keeping the load-bearing two-unify as a kind parameter), and
**local bindings** (#1082): a `let`/`where` binding that generalizes over a
constraint abstracts its own dict params, routed per use site. The interim
all-or-nothing pin (PR #1021) and its unsoundness (#1052) retire with it.

**Output contract.** Elaboration produces the typed, dict-explicit, route-stamped
AST that *both* engines and the Core-IR lowering consume — one elaboration
(decided 2026-07-15: the owner would sooner retire the tree-walker than keep two).
Dispatch decisions live entirely in routes/evidence (single-evaluator law, §7);
arg-tag inspection survives only as an optimization applied identically by every
engine under §5's side condition, which under overlap means: never below a head
where overlapping instances exist.

### G — Global checks

Coherence (C1 per-goal unique minimum — migrating the enforced condition from
(a) global comparability to the spec's (c), #311/#614), superclass-consistency
auditing (C2 as an invariant check), signature authority (`gen-sig`: reject, not
narrow — #830's silent narrowing becomes a def-site diagnostic), W3 rigidity
with the #817 carve-out retiring on the graded arc (#823), the escape and
laundering checks converged into one post-unify traversal (#995, with the
rigid-skolem idealization explicitly blocked on #817/#820), the eliminator
obligation for graded methods (#1095: a result-index occurrence is a promise
about force time, never a charge at call time), and the exhaustiveness bridge.
All run over K's environments; none holds private registries.

### D — Diagnostics

The ~1,200 lines / ~110 functions of error-path-only machinery (message
construction, mis-framing provenance, swapped-argument detection, cascade
suppression) extract to a sibling module with a narrow interface (push a
structured `TcDiag`, read the accumulators). Fires only on failure, must not
perturb inference, has no inbound dependency from the inference core — the map's
safest extraction (§7.4). The accumulating-errors discipline and
`typeErrorsSticky`'s position outside every reset bundle are unchanged
(settled).

### Cross-cutting substrate

- **Registry discipline (the #1070 "owed gate").** One registry abstraction for
  cross-module tables: keyed by qualified identity, and either write-once-
  with-conflict-diagnostic or explicitly commutative (multimap/set). A
  `CrossRun` field whose key type is a bare `String` fails a structural check —
  the ratchet that prevents "registry #16 next month", which lint cannot see
  (it is a dataflow property, per #1070's own analysis).
- **Fused lockstep tables (#994).** Slot-parallel pairs
  (`funConstraints`+`Ifaces`, `methodConstraints`+`Positions`, the bare/Qual
  mirror pairs — the latter dissolve entirely under L2) become single
  record-valued tables; the lockstep invariant lives in one writer.
- **State model.** The four-bundle + `Windowed` discipline is kept (it worked —
  1,199 of 1,443 functions are pure; only 7 cells have diffuse ownership). The
  reset lifecycle simplifies with the driver: `CrossRun`'s marshalling triplet
  disappears into K; `DriverState`'s mode flags disappear with `CheckMode`.

---

## 3. Mapping: current → target

Keyed to the map's §4 layers. "Kept" means structurally unchanged.

| Map layer / mechanism | Target component | Disposition |
|---|---|---|
| L0 unify/generalize/value restriction/`fromAstTypeE` | I | Kept. `fromAstTypeE` reads K's `DataEnv`+alias table (identity-keyed) instead of `universeAliasTable` |
| L1 refinement domains, α, row machinery | I (+ G checks) | Kept; row unifier gains position-mode parameter (arrow vs index) + variance propagation (#1094/#1098/#1103) |
| L2 `infer` and satellites, 57 cells | I | Kept intact — the settled no-split verdict stands |
| L2 numlit defaulting (5 cells, path-divergent ordering) | S | Re-homed as a solving step with a written ordering rule |
| L3 `processTopGroups`/SCC processing | E scheduler | Generalizes to the whole-graph SCC schedule; letrec order becomes specified |
| L4 `entail` | S | Kept as the core; gains `entailSuper` rung |
| L4 obligation channels + checkers | I record / S check | #991 storage completion; one record, live provenance |
| L4 impl/default body drivers | E (`MethodBodyKind`) | #992 merge; two-unify kept as kind parameter |
| L4 `expandSupersTable` + 4 super-closure walks | S | Retired → tree evidence + one closure combinator (#993) |
| L4 specificity selection (`pickMostSpecificEntry` etc.) | S | The one `min⊑` selector; all positions route through it |
| L4a the 8 `pending*` channels + 9 stampers | I (record) / S (drain) | Channels kept (essential); ONE drain order, one instance |
| L4a RLocal pinning (#1040/#1052/#1043/#1082) | E | Locals dict-abstracted (L4); pin machinery retired |
| L5 coherence | G | Kept pure; condition (a)→(c) |
| L5 field/record registry (`recordByNameRef` LWW) | K | Identity-keyed `DataEnv`; LWW impossible |
| L5 kind checks (`checkGradedImplHeads`) | K + G | Declared kinds (EFFECTS §6.1–§6.5, #822) checked at declaration |
| L6 shadow machinery (both kinds) | R (detect) + S (route) | Detection by identity intersection; routing stays per SHADOW S1–S9, single decision point |
| L7 `checkBodyImpl` spine, `CheckMode`, promotion fixpoint | E | One driver, one mode; fixpoint → SCC schedule |
| L7 universe marshalling (`load`/`store`/`appendUniverse*`) | K | Retired — environments are global, never marshalled |
| L7 import seeding/aliasing/ctor overlay | R + K | Visibility filtering at R; identity makes overlay collision-free (#733/#756) |
| L8 error-path machinery | D | Extracted |
| `marker.mdk` `EVar`→`EMethodRef` | R (adjunct) | Kept as pre-pass; rewrite keys by identity; dict-app marking for unsignatured fns moves into E's schedule |
| `private_mangle.mdk` | backend | Emit-only rendering of identities; no longer semantics-bearing |

---

## 4. What becomes unrepresentable — the traceability matrix

The claim "eliminates bugs through architecture" is checkable: each row names a
bug family, its structural cause in the current architecture, the design element
that removes the *cause* (not the instance), and the open issues it drains.
(Issues marked ◇ are drained only together with the noted stage of §6.)

| Family | Structural cause (today) | Design element (target) | Open issues drained |
|---|---|---|---|
| A. Bare-name cross-module collision | Identity never acquired at resolve; tables faithfully reflect a pre-collapsed namespace | L2/R: qualified identity substrate; K: identity-keyed environments; registry ratchet | #1047, #1069, #1070 (5 of 7 confirmed + method tables), #1092, #1090 (comment), #733, #756, #845◇ |
| B. Dispatch key under-discriminates | Selection re-derived downstream from keys coarser than instance identity (bare head tycon; per-module `IE` slice) | S: one `min⊑` selector; selected-instance identity stamped and emitted; K: global `IE` | #1072, #1071, #1062, #1046, #1075, #1034 |
| C. Locals not dict-abstracted | `gen` applied at only two binder kinds; interim pin merges rigid vars | L4/E: uniform `gen` at every binder (#1082) | #1040, #1043, #1045, #1052, #866-interim |
| D. Impl/default & Flat/Module forks | Two implementations of one judgment kept in sync by hand | L1/E: `MethodBodyKind` merge; one driver, one stamper order | #992, #873-class, #462◇, map §7.6 (unfiled → task E-2) |
| E. Supers flattened & re-resolved | No `entailSuper`; evidence is a flat slot list; 4 duplicate closure walks | L4/S: tree evidence, projection rung, one closure combinator | #993, #679, #741, #323 |
| F. Effects rules with unreached arms | Row unifier's leniency is per-arm, position-blind; no invariance notion; coverage counts promises as charges | I/G: position-moded row unification + variance propagation; eliminator obligation | #1094-class (spec'd), #1095, #1098, #1100, #1103, #797◇ |
| G. Laundering via method schemes | W3 checked with flexible vars in places; carve-out for Async | G: W3 rigid everywhere; graded arc retires the carve-out | #817, #825, #819 (adjacent), #830 (gen-sig authority) |
| H. Obligation storage drift | 2 storage shapes, dead provenance arms, bespoke numlit channel | I/S: #991 completion; defaulting as specified solving step | #991, #563, #564, #792◇ |
| I. Order-dependent results the spec forbids | Per-module env slices; promotion discard-and-redo; two stamper orders | L3/K/E: whole-graph env, SCC schedule, one order table | #1072 (also B), letrec order (owed spec) |
| J. Coherence condition mismatch | Enforced (a) global comparability vs spec'd (c) per-goal minimum | G: per-goal unique-minimum check at `inst` | #311, #614 |
| K. Registry recurrence risk | Nothing prevents the next bare-name table | Registry ratchet (structural check on `CrossRun` key types) | #1070's "owed gate" |

Hygiene items (#176 ref-growth probe, #480 duplicate loc-helpers) ride along
with the stages that touch their code and are listed in §6 rather than here.

**What the matrix does NOT claim.** Nothing here fixes an engine bug by
architecture alone (E-panic #1043's emitter half; the wasm/native realizations),
and nothing here substitutes for the graded-interfaces arc (#820–#824), which
this design *assumes* as the resolution of family G's carve-out and therefore
treats as a peer arc, not a subtask.

---

## 5. Decisions reopened, and decisions deliberately kept

Per the working agreement: default is to keep settled semantics; where the
ground-up ideal disagrees, the reopening is stated with its cost. Three
reopenings, none of them language-visible semantics.

**R1 — The per-module sweep + promotion fixpoint → whole-graph SCC-scheduled
inference.** *What it challenges:* DRIVER-COLLAPSE-PLAN (status IMPLEMENTED) and
the shape of `elaborateModules`. The plan's invariant — flat ≡ 1-module — is a
stated invariant with a measured counterexample (20 mode branches, divergent
stamper orders, `Flat` re-entry in the fallback), so this is less "reopening a
decision" than "finishing one whose completion was misrecorded." *What is
genuinely new:* scheduling inference by whole-graph SCC order instead of
per-module sweeps + a fixpoint. *Why:* it makes the promotion fixpoint,
harvest-discard, and re-marking structurally unnecessary; it turns letrec
scheduling from unspecified emergent behavior into a written rule; it removes
the only consumer of `Flat` mode. *Costs to manage:* the per-module `resetState`
lifecycle changes (module-scoped state becomes SCC-scoped or graph-scoped —
the 52-survivor discipline must be re-derived, not assumed); the LSP's
post-run scheme-read seam must be preserved by contract; diagnostics must still
attribute errors to modules for per-module output ordering. This is the
highest-risk element and is staged accordingly (§6, stage E, with a
behavior-frozen refactor before any scheduling change).

**R2 — Order-preserving scans where the spec mandates order-freedom.** The
settled change-control rule ("golden drift from a map-ification means I changed
semantics") stays the default. But the map itself flags the carve-out: impl
selection by declaration/module order **contradicts DICT §3/C3 and is open as
#1072 (S0)** — there, matching the oracle *is* the bug. The reopening is
narrow: goldens that pin order-dependent *instance selection* get re-derived
from the spec (hand-computed winners) as part of family B's fix, with each
moved golden justified clause-by-clause in the PR. Everything else (coherence
conflict report order, first-Loc selection, display order) stays
order-preserving.

**R3 — Two extractions from `typecheck.mdk`, without relitigating the
file-split rejection.** The rejected split was HM-core vs dispatch — state read
at `infer` depth across the 25-arm walk; that verdict stands and this proposal
does not thread records through `infer`. The two extractions here sit *outside*
that coupling, on the map's own dominance evidence: **D** (error-path machinery
— fires only on failure, no inbound dependency from inference) and **K**
(declaration analysis — runs before any body inference; its outputs are
read-only during I/S/E). Both clear the §7.7 seam list: D exports the push/read
interface; K owns what `loader`-adjacent marshalling owns today. If K-as-a-file
proves to fight the build (import cycles, `SMap` layering — the trap that
blocked the Tarjan extraction), K lands as a gateway-owned region of
`typecheck.mdk` instead; the *contract* (whole-graph, identity-keyed, built
once) is the architecture, the file boundary is not.

**Kept, explicitly (do not re-derive):**

- **HM-core/dispatch file split: rejected.** (ARCH-REVIEW PASS 2; map §8.)
- **`pending*` deferred-site channels: essential.** Bundled, never eliminated.
- **`typeErrorsSticky` outside every bundle.** Sound *because* it survives resets.
- **Effect rows transparent in matching** (single-meaning law; EFFECTS §8).
- **Most-specific-wins as specified** — head-only `⊑`, per-goal unique minimum,
  commit-at-elaboration-site (choice-points §6.1 all stand).
- **Module-qualified identity with use-site ambiguity** (not reject-at-decl).
- **One elaboration across engines** (single-evaluator law; the two-mode
  emitArgStampPasses class stays dead).
- **Declared kinds replace inference; `Effect` kind; `Deferred*` naming; `defer`
  keyword** (graded arc decisions, 2026-07-26).
- **No user-facing variance annotations** — internal propagation only (#1098).
- **Graded interfaces arc as designed** (#822 → graded-lite → #823 → #824; #821
  deferred). This design treats `Effect`-kinded slots as invariant positions
  (per the 2026-07-27 investigation) and otherwise takes the arc as given.
- **No catchable panics; IO not a monad; lazy top-level nullary; hot helpers
  monomorphic and short-circuiting** (+56% self-compile measured; L5's
  conformance machinery must not delegate hot scans to Foldable).
- **The interpreter stays** — as a refinement consuming the one elaboration.
  Retiring it is an owner-only decision this proposal does not need.

---

## 6. The migration DAG

Six stages. Every task is a mergeable PR series with `main` green throughout;
collision surfaces are named so the fleet can schedule; ⊕ marks tasks that are
*already filed* and are adopted (re-scoped where noted) rather than duplicated.
Verification bars per task follow §7's doctrine; compiler-source tasks all
carry the standing bar (snapshot + selfproc-legA blessing, fixpoint C3a/C3b,
`typecheck_compiler_source`, serialization on `typecheck.mdk`).

**Stage S — Spec & conformance substrate (no compiler changes; unblocks everything)**

- **S-1. Conformance suite scaffolding.** A clause-indexed fixture corpus for
  DICT/EFFECTS/SHADOW: each fixture names its clause, states its expected value
  *and how it was derived* (by hand from the rule), and is wired either as a
  passing gate or a `must_fail` pin when the engine is known-wrong. Starts from
  the existing shadow matrix gate (the model) and the `run_check_agreement`
  family. This is the safety net for every later stage.
- **S-2. Owed spec paragraphs.** (a) Cross-module identity of types / aliases /
  records / interfaces / methods (DICT §8 I-series extension — the decided
  Haskell/Rust model, including the use-site ambiguity rule); (b) letrec/SCC
  scheduling order and what a later group may observe; (c) numeric-literal
  defaulting (placement relative to obligation checking, taint rules);
  (d) impl completeness / phantom-method rejection; (e) driver unimodality
  (retiring DRIVER-COLLAPSE's stale IMPLEMENTED claim). Each lands with its
  enforcement-table row (L5).
- **S-3. Enforcement tables for DICT and EFFECTS** (clause → site → keying
  assumption), SHADOW-§3-style, added to the specs and gated by the doc gates.
  The map's §4 spec column is the seed.

**Stage A — Identity substrate (family A) — the widest-blast, highest-value stage**

- **A-1. Resolve-acquired qualified identity** for types/aliases/interfaces/
  methods/records/ctors; AST carries origin; use-site ambiguity diagnostics
  (R-series codes). *Collision surface: `resolve.mdk`, `ast.mdk` (new fields —
  named-field records per the 2026-07-27 insurance note), every golden family;
  the single biggest golden move of the arc.*
- **A-2. Identity-keyed environments + registry ratchet.** Re-key the surviving
  `universe*`/method/record/kind tables; land the write-once-or-diagnose
  registry abstraction; structural check that `CrossRun` keys are identity
  types. *Drains #1047/#1069/#1092/#1090; #1070 umbrella closes when its audit
  rows are all either drained or reclassified.*
- **A-3. Whole-graph declaration analysis (K).** Build CE/IE/DataEnv once;
  retire the 14-cell universe marshalling; impl completeness + kind checks move
  to declaration time. *Depends on A-1/A-2. Collision: `typecheck.mdk` broadly;
  serialize against every other typecheck PR.*

**Stage B — One selection discipline (family B + E) — depends on A-3 for global `IE`**

- **B-1 ⊕ (#993). Evidence tree + `entailSuper`** — as filed: distinguished
  `supers`, one closure combinator, `expandSupersTable` + census twins retired.
  Blast: `Value` rep in eval, `Route`, both emitters, dict-arity readers —
  design-first, staged, adversarial bar (its own text already says so).
- **B-2. The single `min⊑` selector at every position + identity-stamped
  dispatch.** Route stamps and emitted dispatch tables carry the *selected
  instance identity*; the bare-head OR (#1058's superset arm) retires. Includes
  the R2 golden re-derivation. *Drains #1072 and family B; the engines gate
  grows the same-name/overlap cross-module fixtures it demonstrably lacks.*
- **B-3 ⊕ (#991, #994).** Obligation storage completion and lockstep-pair
  fusion — mechanical, byte-identical bars, can land early and in parallel with
  Stage A (they don't depend on identity).

**Stage C — One method-body judgment**

- **C-1 ⊕ (#992). `MethodBodyKind` merge** — as filed, two-unify retained as a
  kind parameter, module-placement probes both ways.
- **C-2 ⊕ (#830 + gen-sig authority).** Signature more general than body ⇒
  def-site reject (never silent narrowing); the vector-valued entailment side
  condition per DICT §9.

**Stage D — Effects soundness (family F) — independent of A/B; interleaves with the graded arc**

- **D-1. Position-moded row unification**: index-invariant arm (#1094-class as
  spec'd in EFFECTS §6.7), same-tail prefix check (#1103), `rowArgOf` catch-all
  kind error. One function + a position table.
- **D-2. Variance propagation** for write-channel-carrying types (#1098) —
  compiler-internal, transitive, with the `List` control staying accepted.
- **D-3. Coverage/charge separation** (#1095): result-index occurrences never
  discharge argument coverage; the eliminator obligation for graded methods per
  EFFECTS §6.7. Coordinates with #822/#823 (the graded arc owns the signatures).
- **D-4 ⊕ (#995). Effect-walk convergence** — shape-only now; rigid-skolem
  idealization stays blocked on #817/#820 exactly as filed.
- **D-5 ⊕ (#797)** return-position `<e>` collapse on the top-level path — rides
  D-1's unifier work.

**Stage E — One driver (family D/I) — after A-3; the riskiest stage, split for safety**

- **E-1. Behavior-frozen unification.** Collapse the 20 `match mode` branches
  and the two stamper sequences to one, *preserving today's Module-path
  semantics* (byte-identical bar; the Flat path's divergences each get a
  fixture first, then die). `CheckMode` deleted; one stamper order table.
- **E-2. SCC-scheduled generalization.** Replace the promotion fixpoint +
  harvest-discard with dependency-ordered gen per S-2(b)'s now-written rule.
  Explicit sub-bars: reset-lifecycle re-derivation, LSP seam contract test,
  per-module diagnostic attribution unchanged. *This is R1; it does not start
  until E-1 is green and soaked.*
- **E-3. Defaulting placement** per S-2(c) (#563/#564 close against the rule).

**Stage F — Locals + extraction + residuals**

- **F-1 ⊕ (#1082). Dict-abstracted locals** — the deferred (C) remedy, now on
  the uniform-`gen` substrate; retires the interim pin and #1052 with it.
  Calling-convention change across typecheck/dict_pass/core_ir_lower/both
  backends: benchmark-emitter discipline applies.
- **F-2. Extract D (error-path machinery)** — pure extraction, byte-identical.
- **F-3 ⊕ (#311/#614). Coherence (a)→(c).**
- **F-4. Hygiene ride-alongs**: #480 (loc-helper dedupe, in F-2's diff), #176
  (ref-growth probe, after A-3 changes the ref population), #462 (stamp-order
  comment truth, dies with E-1's order table).

**Dependency spine:** S ⟶ A-1 ⟶ A-2 ⟶ A-3 ⟶ {B-2, E-1} ; B-1 ∥ C ∥ D
(independent of A after S) ; E-1 ⟶ E-2 ; A-3 ∥ B-3 ; F-1 after C-1 and E-1;
F-2/F-3 anytime after S. The graded arc (#822→#823→#824) runs as a peer,
touching D-3 only.

**Sizing honesty.** A is weeks of fleet work (every golden family moves once);
B-1 and E-2 are the two design-first items; B-3/C-2/D-1/D-5/F-2/F-3 are
single-PR sized. Nothing in this plan is a side quest — #993's own warning
generalizes to the whole arc.

---

## 7. Verification doctrine

- **Conformance-first.** Stage S's clause-indexed fixtures are the *oracle of
  record* for every behavioral change; captured goldens remain the oracle for
  *unchanged* behavior only. Where the two disagree, the clause wins and the
  golden moves with a per-clause justification (R2's narrow carve-out).
- **The known-wrong-oracle rule.** No `CAPTURE=1` against a shape in a family
  this document names until that family's stage lands; pin with `must_fail`
  instead (the tracker self-drains). Matching-arity/silent-only guards go in
  the pin comments (the #1070 lesson: the obvious repro is often the loud one).
- **Byte-identical where claimed.** B-3, C-1 (module-placement probes), E-1,
  F-2 carry byte-identical bars; A and B-2 explicitly do not (identity and
  selection *are* semantics) and say so per golden family.
- **The standing five questions** (`.claude/workstreams/TYPECHECK.md`) apply to
  every S0 fixed in passing; adversarial review is mandatory for every
  behavior-touching increment in B-1, B-2, E-2, F-1 (this seam produced
  confirmed S0s in three separate reviews during the #839/#840 arc).
- **Loud-over-quiet.** Any task that converts a crash/reject into an accept
  must present the spec clause licensing the accept plus a fixture that could
  not pass before — the "new something is untested by construction" rule.

---

## 8. Risks, and what this proposal does not do

- **R1's blast radius** is the honest maximum: reset lifecycle, LSP seam,
  diagnostic ordering, and the fixpoint's oracle-matching behavior all move in
  E-2. Mitigation is structural (E-1 first, behavior-frozen; E-2 gated on the
  S-2(b) spec paragraph; both with the full adversarial bar).
- **Perf.** Whole-graph environments and identity keys must not regress the
  self-compile: identity keys stay interned/monomorphic (no dict-passed
  comparisons in hot lookups — the +56% lesson), and the perf-scaling gate's
  alloc arm is blind to constant factors (#115), so stage A carries an
  interleaved wall-clock A/B on the self-compile as its own bar.
- **Fleet dynamics.** Stages A and E serialize the whole `ws:typecheck` lane on
  `typecheck.mdk`; B-3/C/D provide parallel lanes so the fleet is never idle
  behind the big stages.
- **Not in scope:** engine-realization bugs (emitter E-PANIC halves, wasm
  parity), the graded arc's own design forks (#823's eager-arm decision), the
  `do`/`defer` routing implementation (#824), and any change to surface
  syntax. The `medaka check` CLI surface is unchanged throughout.

---

## References

- [`TYPECHECK-ARCHITECTURE.md`](TYPECHECK-ARCHITECTURE.md) — the derived map this design targets
- `docs/spec/DICT-SEMANTICS.md`, `docs/spec/EFFECTS-SEMANTICS.md`,
  `docs/spec/SHADOW-SEMANTICS.md` — the governing semantics
- `compiler/ARCH-REVIEW.md` (PASS 2), `compiler/DRIVER-COLLAPSE-PLAN.md` — prior
  structural verdicts this design keeps or completes
- `.claude/workstreams/TYPECHECK.md` — the standing five-question gate
- Issues: #991–#995 (adopted), #1070/#1084 (family audits), #1082 (locals),
  #820–#824 (graded arc, peer)
