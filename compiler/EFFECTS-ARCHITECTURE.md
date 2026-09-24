# Effects within the typechecker

**Status:** INCOMPLETE — implementation plan and delivered foundation. The delivery checklist below distinguishes the
destination from code that has actually migrated. This is one implementation
effort, not a sprint contract. Base: `c8d1ffe38`.

The effects subsystem owns effect rows and authority constraints. It participates
in the scopes, binding schedule, qualified schemes and publication protocol of
[TYPECHECK-CONTRACTS.md](TYPECHECK-CONTRACTS.md); it does not introduce a second
typechecker or make dictionary selection depend on effects.

## Semantic contract

Inference computes a value type and an immediate evaluation effect. Function
arrows carry latent effects; indexed containers carry deferred effects. A binding
also records whether looking it up forces a computation. Strict local variables
and function values cost nothing to look up. A lazy top-level value incurs its
initializer's effect at every potential force, even if a runtime implementation
memoizes it. A capability is a may-effect, not an execution count. This closes the
representation gap behind #3328 without changing evaluation order.

Three variable sorts remain distinct:

- Type variables describe runtime value shapes and retain the existing HM rules.
- Row variables describe sets of effects, including existing joins of row tails.
- Authority variables describe a parameter within a declared refinement domain.
  An authority variable is neither a type variable nor an entire row variable.

Checking a declared universally quantified signature uses rigid variables.
Instantiating it for a use creates fresh flexible variables. A body may use a
declared row variable but cannot choose its value, merge independently quantified
variables, or replace a declared authority by a broader one. A row variable
occurring only in a result is not an implicit wildcard. This resolves the
conflicting readings recorded on #830/#2111; the corresponding change needs
negative and honest-signature controls rather than just the old #797 fixture.
Inference-generated open rows remain flexible. Value restriction and inference
levels continue to govern all three sorts.

Row equality, directed sub-effecting, and invariant type indices are separate
operations. Call arguments and checked bodies use the directed judgment. An
effect index uses equality. Ordinary HM equality must not silently discard an
effect difference. The existing polarity discipline remains authoritative for
rows nested in data arguments.

## Authority algebra

Each effect label has a domain: Unit, Prefix, Set, or a named-axis Product.
Concrete domain operations have one implementation shared by inference, policy,
diagnostics and manifest rendering. A domain mismatch is not proof of coverage.

An authority term is a domain-checked concrete parameter, a scoped variable, or
a finite join. A symbolic join stays symbolic: `Net h1` and `Net h2` become one
Net atom carrying the join of those authorities. They must not be collapsed to
top merely because either operand is a variable. Concrete operands normalize
using the existing domain join. Join nodes are canonical, shared and deduplicated
by identities; constraint solving never enumerates all substitutions for a join.

A wanted has a goal identity, source origin, lexical scope, and an ordered
constraint such as `actual <= allowed`. Outcomes are solved, deferred with
explicit blocking variables/scopes, or insoluble. Solving an authority constraint
produces no runtime dictionary. The shared solver schedule owns draining and
finalization; the domain service owns the proof. Unknown is never synonymous with
solved. Unsatisfied constraints prevent successful publication.

Rigid authority variables stand for arbitrary caller choices. A literal does
not satisfy an unrelated rigid variable. A variable satisfies itself and top;
a join is covered only when every operand is covered. Flexible variables retain
lower and upper constraints until a binding boundary can solve or generalize
them. Generalized residual constraints travel with the qualified scheme and are
instantiated using the same substitution as its value type and rows. A local
rigid authority must not escape its scope in a result or residual constraint.

The abstraction of a value is domain-directed. Prefix-preserving concatenation
can preserve a Prefix authority; concatenation does not preserve a Set authority
(appending to an environment-variable name changes the member). Product axes are
handled independently. Unknown values conservatively require top. These are
abstractions of argument strings under the existing domains, not a new claim
that string prefixes prove filesystem canonicalization or runtime confinement.

## Declarations, calls and handles

The three effect-parameter forms ruled in #3385 remain: a named authority, a
literal domain parameter, or a bare label meaning top. The old quoted underscore
is retired for user and extern signatures together when named authorities work;
no unchecked compatibility hole is retained.

A named argument in a signature binds an authority independently of its runtime
value type. Within the body that authority is rigid. At a call, the determining
argument is substituted at its declared position. Partial applications retain
the instantiated relationships and already-supplied authorities. Generalized
aliases retain schemes; higher-order arguments retain their instantiated
monotypes, not first-class polymorphic schemes. This stays rank-1 HM and does not
promise a callback polymorphic at each invocation. It is not a callee-name lookup.
A two-path extern
such as rename incurs both source and destination authorities.

Every authority-index introduction needs a proof source: a qualified argument or
field, a retained constructor constraint, a generative existential, or an
explicitly trusted FFI operation. An abstract `Handle κ` can store only a raw
handle if controlled construction establishes its index; a runtime path field
is not required. An unrestricted constructor must not invent an arbitrary κ.
Constructor checking proves declared field constraints; matching recovers only
those declared relationships, never a qualifier from a phantom index alone.

Qualified values flow from `τ @qa` to `τ @qe` only when `qa ≤ qe`. Forgetting a
qualifier is safe; recovering precision from an unqualified value requires
expression-directed evidence. Arrows compose this relation with variance, and
mutable storage and authority-index slots remain invariant.

Effect labels must have resolved declaration identity `(origin, name)`, carried
through imports and reexports. Each identity owns exactly one domain schema.
Printed spelling is not an atom key: graph traversal order must not select a
schema for two different declarations with the same name.

The surface spelling for authority-qualified fields is to be settled alongside
the parser implementation and documented in EFFECTS-SEMANTICS, not encoded as a
magic string in the existing optional-string parameter carrier. Named-argument
syntax must lower to the same representation used by constructor fields and
callback signatures. Authority annotations erase before runtime layout; they do
not add hidden arguments or change dictionary arity.

Interface methods quantify authorities together with their type and row
variables. Supplied methods and default bodies obey the same signature contract.
Effects do not participate in instance ranking. Authority-qualified fields must
still be checked when a value passes through ordinary polymorphic code; erasure
belongs after checking, never inside a unifier as a catch-all.

## Module ownership and dependency direction

All typechecking services live in `compiler/types/`. The intended modules are
listed here as proposed paths; presence in this table is not a delivery claim.

| Module | Owns | Dependencies and boundary |
|---|---|---|
| `effect_domain.mdk` | Domain schemas, concrete parameters, joins, coverage and rendering | Small support utilities only; no AST, HM types or typechecker state |
| `effect_authority.mdk` | Domain-typed authority variables, symbolic joins and products | Concrete domains; scope identities but no HM orchestration |
| `effect_rows.mdk` | Atoms, row/tail representation, normalization, row views | Authority terms; explicit request services for stateful operations |
| `effect_solver.mdk` | Equality/subsumption modes, scoped authority constraints, residual solving | Rows and common scope/goal contracts; no import of `typecheck.mdk` |
| `effect_infer.mdk` | Source abstraction and authority propagation through expressions and patterns | AST plus explicit lexical facts; never look up a local by bare name in a global table |
| `effect_check.mdk` | Declared-signature and method-effect checks | Solver and explicit checking context; same entry for supplied/default bodies |
| `repr.mdk` | HM monotypes, schemes and type rendering | Imports effect representation; does not own a second effect algebra |
| `solver_contract.mdk` | Common wanted/outcome scheduling and qualified schemes | Domain-specific payloads do not require fake evidence destinations |
| `typecheck.mdk` | Integration into eager inference, SCC boundaries and graph publication | Calls services; retains small adapters while consumers migrate |

Extraction is by ownership, not by a requirement that every module be pure.
Stateful services receive narrow contexts: fresh identity allocation, inference
level, current rigidity/scope, absorption observations and diagnostic reporting.
They do not receive the entire PerRun record and never import the orchestrator
back into a leaf. Existing absorption checks remain until their replacement
observes both arrow-spine and off-spine cases; deleting a post-hoc check before
rigid checking covers that population would reopen laundering.

Request-owned variables and obligations are never published or reused through a
later request's cache. Freeze solved summaries or instantiate templates with
fresh identities. P -> failed/conflicting Q -> P must produce the same schemes,
constraints, diagnostics and effects as a cold P. Unknown manifest authority is
reported conservatively, never omitted.

## Implementation order and completion evidence

### Structural acceptance criteria

The invariant is preservation of authority through every introduction and
elimination form. A new callee-name exception, an AST-shape laundering blacklist,
or a repair pass reconstructing information already discarded is evidence that
the representation or judgment is missing something. Regression tests may name
individual attacks; the implementation rules must classify the whole population.
An ordinary variable occurrence instantiates the complete binding descriptor
once, including its forcing row. A type-only probe never charges evaluation.
The same distinction applies to selected standalone names and method routes:
selection picks a descriptor; it must not reconstruct one from a signature.

Semantic representations must retain their domain schema, variable sort, scope,
and identity. In particular, two open rows are not ordered merely because both
have a tail. Unknown constraints are pending or rejected, not silently accepted.
No binding may publish while a required proof is missing. If any known laundering
path remains, the delivery is incomplete, even if its individual changes pass.

### Data structures and complexity

Rows are finite label maps; their public renderings are sorted lists. Large atom
normalizations and coverage checks use keyed maps, not repeated list membership.
Small rows, a fixed Product schema, and capped concrete Sets may use small lists.
Symbolic terms and row joins are DAGs: visit identities once per traversal and
do not expand a shared diamond into a tree. Visited state is local to that
traversal because solving can mutate its cells afterward.

Use identity-keyed maps/sets for variable populations, constraint blockers,
dependency edges and active work. Wake only constraints blocked on a changed
variable; avoid rescanning all pending goals after each binding. Deterministic
rendering must not depend on hash iteration. Test duplicate-heavy rows, many
distinct labels, and deeply shared joins, not just large source-file counts.

### Execution order

This order allows intermediate commits on one branch. No intermediate commit
claims the full authority package or closes its pinned issues.

1. Extract the existing concrete algebra and row representation into owned modules,
   retaining behavior and public consumers. Add focused algebra/row tests before
   changing authority semantics. Remove the moved implementations from their old
   homes; a new unused module does not count as an extraction.
2. Give stateful row checking narrow services and explicit relation modes. Preserve
   existing directed-flow, index, polarity and join behavior under the new boundary.
3. Preserve lazy binding forcing effects in binding schemes and SCC inference,
   including recursion, aliases, imports, local shadows and manifest extraction.
   Keep runtime timing unchanged. Drain #3328 only after its rejection and honest
   effectful control execute through the production paths.
4. Establish declaration rigidity uniformly for type/row variables; resolve
   #830/#2111 and the remaining #825 family with spec-derived checks, including
   default methods and higher-order stored callbacks. Do not delete the preexisting
   soundness walks until their complete input populations are covered.
5. Add authority variables, scoped constraints, scheme substitution/generalization,
   and structured surface parameters. Named arguments, wrappers, partial application
   and all determining extern positions form one semantic change. Migrate underscore
   signatures and discharge #3382/#3383 only when their pins reject for the right reason.
6. Add authority-bearing data fields and patterns, handles, callback rows and method
   signatures on that representation. Check invariance and scope escape, including
   mutability, constructor abstraction and same-named binders in unrelated modules.
7. Migrate precision-dependent stdlib signatures and synchronize manifests, docs,
   formatting and editor grammar. Complete the declaration-kind/re-export gaps
   (#3327/#3304) where the new surface depends on them.

The completed package has no unchecked hole fill, no first-argument special case,
and no duplicated effect decision in policy/manifest consumers. All source bodies
participate. Tests include honest and dishonest wrappers, both rename paths,
same-label symbolic joins, Set versus Prefix concatenation, returned/stored
callbacks, opaque handles, unrelated code, import/declaration permutations, and
request/cache isolation. Newly accepted programs must execute under eval, native
and Wasm; front-end agreement alone does not validate erased representations.

Use sibling tests for the module contracts and existing effect/dictionary/engine
corpora for compiler behavior. Compiler source soundness, the reproducing fixpoint,
and per-stage scaling remain required. Record actual delivery below, including
anything still owed, rather than changing the destination to fit a partial result.

## Delivery

This is an **incomplete migration**, not a claim that the effects system meets
the no-laundering contract. The one-shot implementation establishes the following
foundation:

- `effect_domain.mdk` owns concrete domain operations and canonical atom joins.
  `Atom` temporarily lives there until domain-typed symbolic authorities exist;
  its final owner is `effect_rows.mdk` as described above.
- `effect_rows.mdk` owns row representation, DAG traversal, normalization and
  non-solving joins. Captured computations no longer unify their input rows.
  `effect_infer.mdk` owns scoped capture; source authority propagation is not yet
  migrated into it.
- Schemes carry a forcing row, quantified and instantiated with the value type
  under one substitution. Term occurrences charge it; neutral type/evidence
  probes do not. Lexical binding descriptors retain masked standalone schemes
  rather than reconstructing their types or consulting a name-keyed side table.
- Ordinary lazy bindings retain initializer effects, including function-valued
  initializers. Leading effect annotations constrain forcing. Supplied and
  default nullary methods check and publish their interface forcing contract.
  Default bodies use one signature instantiation for inference and checking.
- The shared-tail equality rule retains concrete lower bounds instead of merely
  recording their disappearance. This repairs a demonstrated closed-contract
  recursive forcing loss; it is not a least-fixed-point solver.
- Policy aggregation joins same-label authority parameters rather than keeping
  the first occurrence. It includes binding forcing effects. Its old structural
  traversal is still not an invocation-protocol summary.
- Interpreter capability tables now declare their actual `Value <IO>` index.
  Test/property runners propagate the effects of the values they evaluate rather
  than claiming an unrelated closed row. Runtime bodies and evaluation order are
  unchanged; these signature corrections were prerequisites exposed by retaining
  shared-tail lower bounds.
- Growing row-variable populations use integer-keyed maps. Shared join DAGs are
  visited once per collection, including shared labelled links whose identity
  survives solving. Empty link chains compress without copying labelled suffixes.
  Small atom populations retain an allocation-light fast path.

Still required before this package can be called complete or laundering-free:

1. Shared scoped universal signature checking and directed residual constraints
   (#830, #2111, #825), replacing flexible pre-unification plus post-hoc checks.
   The remaining row equality solver is not a general inclusion solver.
2. Least forcing solutions across recursive groups, including inference rows
   connected through function calls. Protecting only force cells and replaying
   their constraints after solving is insufficient: an ordinary arrow row can
   carry a recursive dependency back into the force equation.
3. Named authorities, qualified fields and constructor proof sources (#3385),
   together with retiring underscore and first-argument hole filling
   (#3382/#3383). Those existing laundering regressions remain release blockers.
4. Resolved effect-label identity and domain-schema agreement; current atoms
   still use strings, and the legacy mixed-domain join fallback remains. Prefix
   rendering also needs canonicalization (#3391): a raw common prefix can render
   as a pattern rejected in a written signature. This has a reproducing pin;
   no laundering was demonstrated by that rendering mismatch.
5. One invocation-protocol summary consumed by manifests and policy, with
   conservative unresolved authority reporting.
6. Full multi-module/engine coverage, final fixpoint and scaling evidence for the
   completed architecture. Passing foundation tests cannot discharge these.

The normative semantics specify the destination. Historical implementation
censuses are archived, not evidence that these obligations have been delivered.

### Foundation verification

Targeted preflight exposed dispatch regressions: a local
standalone had been mistaken for an imported alternative, obligations were
charged before binding selection, and collapsing import rows lost supplier
precedence. The fixes preserve lexical role and tagged export/import rows,
including through re-exports and module-chain memoization; ordinary scheme
overlays keep their existing precedence. Only the selected standalone contributes
its forcing row and obligations.

The new binding representation also exposed a Wasm emitter bug: its local
collector skipped constructor operands although emission traversed them. The
collector now descends through those expression children, with a cross-engine
fixture that fails assembly before the fix.

Fresh verification after these fixes:

- Native rebuild and cold-seed self-compilation: both reference agreement and the
  reproducing fixpoint are byte-identical.
- All 370 tests/doctests in `compiler/types` pass with `MEDAKA_STRICT=1`. The
  subsequently added nonzero-dispatch-index diagnostic-location regression also
  passes in the focused native binding suite (25/25, overlapping the full suite).
- All 83 JSON checks pass without changing their expected diagnostics.
- The final production source builds the complete playground compiler to Wasm:
  assembly, validation and stripping succeed.
- Both `return_pos_memoised` and `nested_pattern_locals` agree across interpreter,
  LLVM and Wasm, with the Wasm arm required. These are two targeted fixtures,
  not the full engine corpus.
- The architecture census and lint pass; lint retains pre-existing advisories.
- Targeted preflight completed with 46 passing gates and two failures: the
  catch-all census needed its three intentional new sites recorded, and a
  symbol-collision fixture's printing nullary method needed an honest `<IO>`
  forcing contract. After those test-only corrections, both gates pass on
  rerun (48 selected gates covered in aggregate). Preflight also passed the
  policy tests and both self-compilation checks. The complete engine corpus
  and the rest of CI were not run locally.

The selected-binding changes also passed all 100 shadow cases and all 114 CLI
module checks before the final diagnostic-location-only fix. Earlier foundation
checks passed both policy-summary tests, 63 native effect-domain CLI tests and
all 18 effect-polarity checks. A shared-labelled-link traversal mutation made its
operation-count test fail; restoring visited-node handling made it pass. That
checks the performance assertion's ability to detect the regression, not
whole-compiler scaling.

No issue is closed by these receipts, and this branch is not offered as a
release-ready effects system.

## Relationship to the broader rearchitecture

The solver's first vertical migration (#2549/#3188) is already available. This work
extends it to another constraint family. Shared signature checking and binding
scheme changes are included prerequisites, not independent blockers. Full
superclass-evidence replacement, general namespace migration, unrelated cache
replacement and the remaining typechecker file split are not prerequisites.

The owner requested modular effects explicitly. This document supplies the
boundary design required by #2586/TYPECHECK-CONTRACTS section 5; it does not
reschedule the rest of that issue or authorize unrelated mass extraction.

The bug class is representational: discarded forcing effects, flexible variables
standing in for universal declarations, and unverified parameter holes. Local
read-site guards cannot establish the desired contract. The ideal remedy is one
explicit representation per fact, shared judgments for its consumers, and
specification-derived tests that observe both verdicts and runtime effects.

## Architectural precedents

GHC represents nested checking as implication constraints with local skolems,
givens and wanteds. The applicable principle is a scoped proof boundary, not a
new independent solver schedule alongside Medaka's existing one.
[GHC constraint representation](https://ghc.gitlab.haskell.org/ghc/doc/libraries/ghc-9.15-inplace/GHC-Tc-Types-Constraint.html).

Rust distinguishes caller-chosen universal regions from inference variables and
checks that inferred relationships between universals were actually declared.
Authority variables need that distinction too; they are not ownership or lifetime
tracking and introduce no borrowing semantics.
[Rust universal regions](https://rustc-dev-guide.rust-lang.org/borrow-check/region-inference/lifetime-parameters.html).

Koka demonstrates row-polymorphic effect inference and its interaction with
generalization. Its duplicate-label rows serve handler semantics; Medaka instead
keeps one joined atom per label and has no handlers. Borrow the separation of
type/effect inference concerns, not an incompatible row algebra.
[Koka row-polymorphic effects](https://arxiv.org/pdf/1406.2061).
