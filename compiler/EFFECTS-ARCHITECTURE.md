# Effects within the typechecker

**Status:** delivered through delivery item 6 (the data-half checkpoint);
item 7 (stdlib migration of precision-dependent signatures to handles) and the
review leftovers listed in the handoff remain. The delivery checklist below
distinguishes the destination from code that has actually migrated. This is
one implementation effort, not a sprint contract. Base: `c8d1ffe38`.

PR #3393 merged on 2026-09-25 (`f81ff1d9d`). For what it delivered and what
remains, read the
[session handoff](../docs/ops/EFFECTS-REARCHITECTURE-HANDOFF.md) first. It records
the decisions, the verification receipts, the adversarial review's findings and
the open work. This document describes the intended
architecture; neither it nor the earlier passing subsets imply merge readiness.

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
| `effect_bindings.mdk` | Source-arity shape and separate body/forcing summaries | Type and row representation; explicit fresh-variable services |
| `effect_values.mdk` | N-ary structural joins of produced alternatives | Type and row representation; explicit equality, variance and allocation services |
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
   Delivered: the named-authority checkpoint below.
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

### Binding-boundary redesign

The solver integration distinguishes three facts: the source body's inferred
summary, a written contract, and the scheme published to callers. They are not
three names for one mutable row. `effect_bindings.mdk` owns the source-arity
shape: constructing intermediate closures is pure; the final source application
runs the body. A nullary source binding instead assigns the body summary to
forcing. Returned functions keep their own invocation rows. A binding has two
value shapes with shared source domains/body row: the published envelope `P`
and the recursive-use assumption `R`. Recursive inference receives only `R`;
the producer join constructs `P` independently. Publication checks `P <= R`,
not unconditional equality. A recursive return contributes `R` as an actual
producer lower bound when the source performs that dataflow.

Every recursive group opens one effect-solving scope and allocates all body
summaries before inference. Each clause contributes a lower bound to its member's
summary. Unsigned recursive occurrences see the recursive-use shape; signed occurrences see
fresh instances of the written contract, not another member's body-checking
universals. A recursive contract's value scheme and predicate templates are
allocated together and retained in one lexical descriptor. Primary and selected
standalone roles each retain their own descriptor. Type, forcing, row-indexed
predicate arguments and dictionary obligations use the same occurrence's
substitution; final body-variable IDs cannot identify a fresh recursive call.
Declared calls use the ordinary dictionary-routing pipeline, while inferred
monomorphic recursion retains deferred routing. Definition and call templates
share the ordinary-signature slot constructor and superclass expansion.
Definition checking rejects declared type variables that become concrete or
collapse together; otherwise the published dictionary ABI could differ from the
recursive contract. Qualified signature elaboration derives constructor kinds
from resolved interface predicates at the current module's visibility ordinal.
That local kind scope separates row indices from ordinary type quantifiers in
both the body-checking instance and the recursive scheme. It is not a global
table keyed by variable spelling.
Checking a body against a contract records directed
obligations, including nested callback rows, rather than identifying contract
tails with inference variables. Solving precedes generalization. Instantiation
substitutes quantified variables only; it must never reopen a solved closed row.

Instantiation explicitly registers its existential effect choices with the
current solver scope. Encountering an unknown row during effect capture does not
confer that ownership. The solver distinguishes declaration universals from
flexible roots reachable in the value being published. Universals are never
solved. Reachable inference roots are retained when unconstrained, but may be
solved by accumulated lower bounds; returning an invariant `Box e` does not
make its inferred `e` a universal. A local instantiated choice that is not
reachable from the published value may take the least row. Environment roots
remain outside the child's solving ownership. Ordinary row equality retains most-general HM
unification, oriented so only flexible cells can be bound, including when the
other side is a declaration universal. Equality involving a body summary enters
the scoped solver as two obligations. Universal roles are installed before
inference, not reconstructed afterward. Instantiation ownership follows
normalized representatives, so a flexible equality cannot orphan a local choice.
When an inner constraint depends on an outer summary, its flexible endpoints
are lowered to the parent level before transfer. This keeps the retained proof
and every local use on the same cells until the outer boundary solves them.

Mutually reachable bare-variable inclusions prove equality and are collapsed
before solving. An unconstrained retained equality class remains open. Filtered
cycles and body summaries remain least-fixed-point equations; they do not receive
invented polymorphic tails. Worklist propagation sends only newly discovered
atoms and symbolic leaves across an edge, rather than rescanning each growing
solution. More general directed residual schemes remain unfinished: the current
solver does not publish general qualified inequalities. This is a completeness
limitation, not permission to accept an unproved constraint.

Scope closing has two phases. First solve owned summaries and non-published
local choices, retaining published flexible leaves as symbolic payload. Then
normalize and discard proved relations before solving summary-free residual
constraints. Relations containing an outer summary transfer to its owner. A
borrowed subset records source-domain roots and domains reached through positive
published function projections. Non-exact borrowed targets retain one fresh
residual per graph node; these residuals are seeded before worklist propagation,
so dependent upper bounds receive the same freedom. Exact index targets do not
receive a residual. Borrowed roles are re-derived through retained cell references
after equality-class collapse, rather than left on stale pre-union IDs.

Positive receiving slots have a separate least-allowance role. When directed
flow first shapes an upper type variable, it reuses the structural value-envelope
operation: domains and invariant arguments remain equal, while positive arrows
receive flexible allowances constrained by the actual rows. The original value's
rows are not reopened. Registered allowances take their least solution even in
invariant published results; rigid and borrowed input roles take precedence.
They are not body summaries, and compatibility never becomes a producer equation.
An allowance lowered into an enclosing monotype transfers its ownership and the
connected constraint component before local solving. A row-to-constraint index
and visited maps perform that transfer without repeated whole-list scans. Even
an unconstrained pure allowance transfers, so dropping a reflexive proof cannot
lose the obligation to close it at its owner.

Module publication retains the canonical callable scheme and the optional
standalone scheme in one export descriptor. Visibility is checked per role.
Import precedence selects that complete descriptor once; ordinary lookup and
standalone dispatch project from the same winner. A same-named method cannot
donate its public visibility to a private standalone.

`effect_values.mdk` owns the structural join of produced alternatives. Functions
keep equal domains, join latent rows, and recursively join their results. Data
arguments join only where resolved declaration metadata proves covariance;
effect indices and invariant, contravariant, or unknown slots use equality.
Branches, match arms, list/array initializer elements, cons, and clause results
use this operation. Fresh array elements are joined before allocation; existing
arrays remain invariant. Application spines are traversed once and arguments
joined column-wise, not by repeatedly folding an ever-growing intermediate row.
Unknown alternatives receive fresh shapes, with an occurs check before shaping.

The published envelope allocates owned summaries at positive returned arrows,
including for a single producer. It never promotes an ordinary inference row to
a summary. Source domains are checked separately, so this envelope walk starts
after the syntactic arity and does not count source-body effects twice. Unknown
type shapes still use HM equality: general delayed structural joins and their
principal schemes remain outside this implemented subset.

Arrow rendering now preserves row tails using the same naming context as forcing
rows and type arguments. A printed closed row must not conceal an open allowance;
the old labels-only arrow rendering obscured this distinction during review.

### Stabilization checkpoint

The continuation session reproduced every red gate of the first full CI run and
found four defects, each with a general cause: a declared signature variable
must never be defaulted (the former "shared by every generalizable member" bound
assumed monomorphic recursion), an expansive sibling that fixes a declared
universal is the universality guard's third violation form, the Prefix domain's
empty prefix is canonically top so join and coverage agree, and a relation over
a leaf a scope does not own transfers to its owner before local solving. An
ambiguous import now yields a poisoned recovery scheme instead of an
import-order winner, and poison propagates through variable binding. The
remaining differences were rendering changes whose goldens were re-derived.
The [session handoff](../docs/ops/EFFECTS-REARCHITECTURE-HANDOFF.md) records
each with its evidence.

### Solver checkpoint verification

Before produced-value joining was added, a fresh compiler passed both binding
and solver sibling suites under eval and native (47 and 17 assertions), the four
effect-domain suites under native (63 assertions), and the native shadow suite
(4 assertions). The check driver accepted the CLI closure and all 71 entry
closures; the elaborate driver accepted the CLI closure. Self-compilation C3a
and C3b were byte-identical. These are receipts for that solver checkpoint, not
for the subsequent value-join changes or the complete no-laundering architecture.

### Produced-value and scoped-allowance checkpoint verification

The subsequent redesign passes the native binding, solver, value-join and
representation suites (69, 26, 5 and 3 tests). With freshly rebuilt compiler and
project-diagnostics binaries, the check driver accepts the CLI closure and all
71 entry closures; the elaborate driver accepts the CLI closure. C3a agrees
with the converged seed reference and C3b reproduces byte-identical IR.

Nine selected fixtures agree across eval, native and Wasm: generic value choice,
private standalone visibility, shadowed method forcing and six nullary-memo
fixtures. The first two also pass independent value pins. Native CLI passes
169 cases, cross-project dependencies pass nine tests, and all seven changed or
new compiler snapshots pass. Disabling allowance ownership transfer makes its
outward-pure regression fail; restoring the transfer makes it pass.

Stock `bindings` and `nesting` performance probes pass without threshold changes.
Allocation grows approximately 2.04x and 2.08–2.15x per input doubling,
respectively. Binding typecheck time grows 1.26–1.46x; nesting remains below the
gate's timing floor. These are targeted checks, not full engine, performance or
preflight passes. Full CI and final exact-head review remain outstanding, as do
the semantic migration items below.

These are implementation invariants under active migration. The foundation
receipts below predate the solver redesign.

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
  Supplied methods and default bodies install scoped rigid contract variables
  before body inference. The solver validates their directed obligations at
  scope exit; legacy post-inference checks remain during migration.
- Binding-owned body and forcing equations are solved to a least fixed point,
  including recursive dependencies and filtered higher-order call constraints.
  Positive returned-value envelopes own separate summary equations; arbitrary
  existing inference rows are never retroactively claimed as summaries.
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

1. Complete directed residual schemes and retirement of legacy signature
   post-checks (#830, #2111, #825). Scoped universal checking is integrated, but
   the remaining row equality solver is not a general inclusion solver.
2. Complete structural constraint solving when produced alternatives initially
   have only unknown type shapes. The dual published/recursive envelopes solve
   explicit returned-arrow equations, but HM equality can still identify
   unknown alternatives before their eventual arrow shapes are available.
3. Qualified data fields, constructor proof sources and authority-indexed
   existentials (#3385's data half). Named authorities on arrows, the retirement
   of the underscore and of first-argument hole filling, resolved effect-label
   identity and prefix-join canonicalization are delivered (the named-authority
   checkpoint); #3382, #3383 and #3391 are regressions under
   `test/typecheck_error_fixtures/effect_*` and their must-fail pins drain.
4. A located `R-AMBIGUOUS-EFFECT`: an effect atom carries no source location, so
   the ambiguity of two imported same-spelled labels reports unlocated.
5. One invocation-protocol summary consumed by manifests and policy, with
   conservative unresolved authority reporting.
6. Full multi-module/engine coverage, final fixpoint and scaling evidence for the
   completed architecture. Passing foundation tests cannot discharge these.

The normative semantics specify the destination. Historical implementation
censuses are archived, not evidence that these obligations have been delivered.

### Named-authority checkpoint

What landed, in the order the decision record prescribed:

1. **Identity.** An effect label is `EffLabel name origin` (`types/effect_rows.mdk`),
   keyed `mod::Name` for a module-declared label and bare for a builtin. The
   resolver stamps every `EffAtomTy` and `DEffect` with its declaring origin,
   exports carry `(name, origin)` provenance, and writing a label that two
   imports declare is `R-AMBIGUOUS-EFFECT` (unlocated: an atom has no `Loc`).
   Two modules' same-spelled labels stay distinct atoms in a joined row. Domain
   schemas are registered by label, and core's labels reach every importer
   through the prelude origin layer.
2. **Authority terms.** `types/effect_authority.mdk` owns
   `Authority = AConst Param | AVar (Ref Authvar) | AJoin`, normalization (a
   join flattens, folds its concrete members through the domain join and drops
   nothing symbolic), `authSub` and rendering. An `Atom` is a resolved label plus
   an authority term; rows insert by joining same-label authorities and
   `atomsDiff` keeps symbolic pairs it cannot prove.
3. **Representation.** `Mono` gains `TQual Mono Authority`; `Scheme` quantifies
   type, row and authority variables; every visitor (substitution, free
   variables, levels, occurs, generalization, rendering) carries the new sort and
   one substitution serves an occurrence's type, rows and authorities.
4. **Surface.** `EffParamTy` is structured (`EPTop`/`EPLit`/`EPName`/`EPSet`/
   `EPProduct`); the parser accepts `(name : String) ->` (`TyNamed`) and
   `T @name` (`TyQual`) and rejects the quoted underscore with a located message;
   printer, formatter, LSP, lint, codemod, sexp and doc carry the forms; the
   resolver checks lexical binder scope (`R-UNBOUND-AUTHORITY`,
   `R-MISPLACED-AUTHORITY-BINDER`).
5. **Checking.** A signature's named binder elaborates to a rigid `κ` inside the
   body (`ScopedMember.smDeclaredAuths`, `perRun.rigidAuthvarsRef`); the domain
   is `String @κ` (`T-AUTHORITY-BINDER`, `T-AUTHORITY-DOMAIN` on ill-formed
   binders). `argumentInto` is the one proof route: an argument flowing into a
   qualified domain wants `α(argument) ⊑ q` (`types/effect_infer.mdk`), through
   direct calls, aliases, partial application, higher-order apply, composition
   (`calleeArrow`), pipes and the standalone-shadow selections (a user binding
   named like a prelude method, whose spine `unifySpineResult` now applies
   through `applicationRow`) alike. `fillHolesInRow`, `spineFirstArg` and the
   alpha-based hole filling are deleted. Undirected unification erases a
   top-level qualifier; `bindFrom` carries it verbatim into a declared parameter
   (a clause's, a method body's or a lambda's against a known arrow), a match
   scrutinee, a let pattern, an application's result and a binding's produced
   result; `refStored` reads a cell's stored type verbatim; a flexible
   receiving slot takes an allowance above the value's authority. `α` reads a
   name by its binding (`AlphaBinder`): a let carries its right-hand side, a
   parameter or pattern the environment types is read through its checked
   type, a binder inside the argument itself is opaque (a bare rename of the
   scrutinee reads it), and a let's right-hand side is read in the scope it
   was bound in. The scoped solver (`effect_solver.mdk`)
   records wanteds, solves each scope's owned flexible variables to their least
   solution (SCC-collapsed), transfers what an enclosing scope owns, and
   `closeRootAuthorities` decides the module-level residue of value bindings the
   value restriction keeps monomorphic. A declared universal is rigid wherever
   it was minted, a method contract's included, so no obligation over one is
   handed outward. An ill-typed binder binds no authority (`binderIsString`),
   so its diagnostic does not cascade into the body.
6. **Publication.** `generalizeBinding` quantifies authority variables that have a
   qualified-argument source and publishes the rest as the domain's top. The
   policy checker (`tools/check_policy.mdk`) reads authorities through `authSub`
   and prints a symbolic atom as the label bare in a manifest.
7. **Migration.** `stdlib/runtime.mdk` and the wrappers in `fs`, `io`, `net`,
   `net_async`, `test` and `test_process` declare named arrows wherever the body
   forwards or prefix-extends the argument; `rename` carries both paths. The
   effect-parameter fixture corpora declare named externs.
8. **Prefix join and exact elements.** Two prefixes join to their longest
   common prefix spelled `lcp*`, written syntax a signature accepts (#3391); an
   element without a trailing `*` is exact and admits only itself.
9. **Catalog redeclaration.** A user `extern` redeclaring a catalog name is
   checked against the catalog's row with one authority variable per argument
   position, so a binder covers the catalog's only when it names the same
   argument (`ffiCheckCatalogRowOne`).

Delivered after this checkpoint: the data-half checkpoint below. A
destructured qualified value (`Some x` from `Option (String @κ)`) loses its
qualifier, conservatively; a lambda parameter gains a qualifier only from a
directed flow.

Coverage: `types/effect_authority_test.mdk` (the anti-laundering matrix with
its honest controls: literal versus dynamic, honest and dishonest wrapper,
binder renaming, both `rename` positions, alias, partial, apply, compose,
branch join, let, Set versus Prefix concatenation, binder errors, the algebra);
`test/typecheck_error_fixtures/effect_named_authority_*`,
`effect_rename_destination_*` and `effect_prefix_join_render` (the #3382,
#3383 and #3391 regressions, the `Ref` invariance pair and the dynamic-path
launder, each negative beside a control); `test/engine_fixtures/named_authority`
with an absolute pin under eval, native and wasm.

### Data-half checkpoint

What landed (delivery item 6; surface ratified 2026-09-25, recorded in
[the handoff](../docs/ops/EFFECTS-REARCHITECTURE-HANDOFF.md) § "Data-half
session"):

1. **Kind.** `KindAnn` gains `KindAuthority label origin` and the typechecker's
   `Kind` gains `KAuth EffLabel`; the parser reads `(p : Authority L)` on every
   head through the one `tyParamsP`, resolve stamps the label's declaring
   identity as it stamps an atom's (`stampDeclKinds`) and checks it as a written
   label, and `checkDeclaredKinds` refuses the parameter as a row tail, as a
   type, and on an interface head (`T-AUTHORITY-KIND`).
2. **Representation.** `Mono` gains `TAuth Authority`, the third-sort twin of
   `TEff` for an `Authority`-kinded argument slot; every visitor (substitution,
   free/unbound variables, levels, occurs, coherence, rendering) carries it, and
   `unifyN`/`unifyIntoN` keep it invariant (both directions of `wantAuthority`).
   The surface node is `TyAuth EffParamTy (Option Loc)` for a written term
   (`*`, a literal, a set); a bare name stays a `TyVar` and is an authority
   by the slot's declared kind.
3. **Elaboration.** `kindArgMono` fills a `KAuth` slot through `authArgOf`;
   `sigVarsFor` binds a name only where something binds it
   (`authorityBinderBound`: a `String` named argument or an index slot,
   `authArgBindersIn` being `rowArgNamesIn`'s twin) and reports a name nothing
   binds (`reportUnboundAuthorityNames`); a signature's type variables exclude
   the index names (`sigTyVarNames`), so `read : Handle p -> <FileRead p> a`
   quantifies `p` as an authority. Resolve's scope for an atom or qualifier is
   any name WRITTEN to its left (`tyVarsWritten`) plus the head's `Authority`
   parameters and the constructor's existential binders; the kind is the
   typechecker's question.
4. **Constructors and records.** `registerVariants` mints one authority cell
   per `Authority` parameter (`mintParamReprs`, named after it), threads it
   through the field elaboration (`paramEtbl`) and quantifies it in every
   constructor scheme, so a qualified field is `String @κ` in the scheme's
   domain and construction proves it through the ordinary application route
   (`argumentInto`) — no constructor-specific path. `RecordInfo` carries the
   authority ids; record creation and update flow each field through
   `argumentIntoOrd` (value-first wording), a field read is verbatim, and an
   explicit record sub-pattern binds through `bindFrom`, so the punned and
   explicit forms agree. `checkPhantomAuthorityExport` refuses a public
   constructor that carries the parameter in no field
   (`T-AUTHORITY-PHANTOM-EXPORT`). Polarity: an `Authority` parameter is `PInv`
   by kind. `deriving` requires instances only of the `Type`-kinded parameters.
5. **Existentials.** A constructor's leading `(p : Authority L)` groups are
   `dataCtorBinders`/`newtypeCtorBinders` (positional with the constructors,
   as `dataParamKinds` is with the parameters); their cells are quantified in
   the scheme and their ids recorded in `perRun.ctorExistentialsRef`, keyed by
   id so a same-named constructor elsewhere cannot answer. A pattern
   instantiates them RIGID (`instantiateCtorPattern`,
   `instantiateRecordOpening`) and parks them at the pattern site
   (`takePatLits`/`settlePatLits`, the literal-pattern bracket); a match arm or
   a function clause takes them (`openExistentialScope`: the body one level
   deeper, the cells raised to it) and closes them (`closeExistentialScope`:
   a cell in the value or lowered below the level is `T-AUTHORITY-ESCAPE`);
   every other pattern site refuses them (`T-AUTHORITY-EXISTENTIAL-SCOPE`).
   No solver scope is opened for an arm: the enclosing scope decides the
   obligations (rigid, so a literal never satisfies one) and publication
   defaults a sourceless opened cell to the domain's top, which is the row
   widening §4 licenses. The alternative of an arm-owned solver scope was
   rejected as order-dependent across arms.
6. **Erasure.** No backend reads a kind, a binder or an index; the engine
   fixture `test/engine_fixtures/authority_handle` runs a handle, a record and
   an existential under eval, native and wasm against an absolute pin.
7. **Surface tools.** Printer, formatter, doc, LSP hover (through `ppScheme`),
   lint, sexp and route keys carry the kind, the index term (`authTermSurface`)
   and the constructor binders (`ctorBindersSource`); `ppDomain` renders a
   qualified domain as `(p : T)` only at the binder's first occurrence, after an
   index it is `T @p`.

Coverage: `types/effect_authority_test.mdk` (seven data-half groups beside
the arrow half's); `test/typecheck_error_fixtures/effect_data_field_{ok,launder}`,
`effect_existential_{ok,launder}`, `effect_phantom_export`;
`test/check_module_fixtures/authority_handle_import` (the kind and the
abstract handle across a module boundary); `test/parse_fixtures/declared_kinds`
(the formatter round trip of every new spelling); the engine fixture above.

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
