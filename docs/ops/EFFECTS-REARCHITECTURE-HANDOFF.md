# Effects rearchitecture session handoff

**Status:** INCOMPLETE — draft PR; CI stabilized locally, authority work not started.
Handoff first recorded 2026-09-24; continuation session the same day.

## Resume here

Continue [PR #3393](https://github.com/MedakaLang/medaka/pull/3393), branch
`effects-architecture-one-shot`. The source checkpoint is the branch head; the
continuation session below is its last commit. `main` is merged in as of
`9d7fd98ac`. Do not enqueue the PR until a fresh CI run on the stabilized head
is read to terminal and the named-authority work below has been decided.

Read, in order:

1. This handoff: the continuation section, then the decision record.
2. [Effects architecture](../../compiler/EFFECTS-ARCHITECTURE.md): destination,
   delivered checkpoints, invariants, architectural precedents and references.
3. [Effects semantics](../spec/EFFECTS-SEMANTICS.md): normative behavior.
4. [Typechecker contracts](../../compiler/TYPECHECK-CONTRACTS.md) and
   [shadow semantics](../spec/SHADOW-SEMANTICS.md): shared ownership/publication.
5. Repository and compiler agent instructions and the typechecker workstream.

The user wants one coherent implementation, **not a sprint**, and has said
explicitly that the typechecker's strength must be a resilient architecture: no
narrow exceptions, no one-off fixes. A run of carve-outs for edge cases is a
signal that the representation or the judgment is wrong. Keep most implementation
in the main agent; delegate research, adversarial review or simple maintenance.
Semantics corrections and prerequisite fixes are authorized. The final system
must not admit effect laundering.

## Continuation session: what the red CI was, and what it became

Run 36033795210 had red on every gate shard, inlang, wasm and the must-fail
step. Every failure was reproduced locally and classified. None was a reason to
abandon the scoped architecture; four were defects, each with a general cause,
and the rest were intentional rendering changes whose goldens had not been
re-derived. What follows is the record, so the next session does not re-derive
it.

**Defects fixed (general rules, no carve-outs):**

- *Signed mutual recursion published `Int -> Int` against a `Num a =>` signature,
  silently.* The engine fixtures `numlit_recursive_*` and the CI value pins
  caught it. The cause was on `main`: `sccProtectedSignatureIds` (commit
  8d83c4414) protected a declared signature variable from Num defaulting only
  when every SCC member shared it, a bound written for monomorphic recursion.
  With signed members instantiating their contract afresh at every recursive
  occurrence, no member shares the variable, so nothing was protected and the
  too-general guard (which runs before defaulting) never saw the grounding.
  Rule now: a declared signature variable is a caller-chosen universal and is
  never defaulted, whatever the group's shape. `sharedGeneralizableSigIds` is
  deleted. The previously rejected "erased sibling" shape
  (`ping n = … consume (signed (n - 1))`) now accepts with correct runtime
  evidence; `test/engine_fixtures/numlit_recursive_erased.mdk` pins it across
  the three engines.
- *The gap the old bound was papering over:* a zero-argument expansive sibling
  (`ping = signed 1`) shares the signed member's declared variable; the group can
  neither generalize it for the sibling nor default it for the signed member,
  and it used to surface as a far-away type mismatch, or not at all. This is
  the third form of the universality guard (`checkSigsFixedByExpansive`,
  beside grounded and collapsed), reported at the signature.
- *pds `rename` rejection:* the Prefix domain's empty prefix `""` joined to top
  (`"" ⊔ "" = ⊤`) but did not cover top under `dsub`, so the solver's covered-atom
  skip and the row flattener disagreed. `canonParam` (formerly `normHole`) makes
  the hole and the empty prefix one canonical top; producers build atoms through
  it. `effect_domain_test.mdk` pins the lattice law.
- *sqlite `runGrouped` rejection:* a relation whose lower leaf was an allowance
  owned by the *parent* scope was validated as final inside a child `let` scope.
  `closeSummaryScope` now transfers every relation over a leaf this scope does
  not own (`outerRelationLeaves`, whether the leaf is one of its own escaped
  allowances or a variable the enclosing scope handed in), with its connected
  component, before solving anything locally. `effect_solver_test.mdk` pins both
  the allowance and the signature-root case; `effect_bindings_test.mdk` pins the
  do-bound shape through inference.
- *`check --json` cascade after an ambiguous import:* the branch's import
  selection picked the first supplier of a bare name (main picked the last),
  both by import order, so a name the resolver had already rejected as ambiguous
  was typed against one definition and cascaded. Import rows now carry the id of
  the import that binds the name (the resolver's own key, `importNamesIn`), a
  name two suppliers bind gets a recovery scheme, and the fresh variable it
  instantiates to is poisoned. Poison now propagates through variable binding
  (`propagatePoison`), which is what makes an applied occurrence's result
  variable quiet too. The resolver counts interface methods as value exports,
  and typecheck's own alias pass (`deAliasMethodImports`, run/build path only)
  synthesizes admissions the resolver never saw: every method of an
  alias-imported module, and a member-aliased method with its alias dropped.
  The pass records them per module in `graphAdmittedMethodsRef`
  (`synthesizedAdmissions`), and the import seed never counts an admission as
  a supplier. Shadow cell I22 (`{size as sz}` beside `fmod.{size}`) is what
  caught the first cut, which keyed on the alias import's location and missed
  the member-alias rewrite.
- *Diagnostic quality:* the new inclusion judgment had replaced several
  site-specific laundering messages with one generic sentence. It now has one
  message that names what escaped (concrete labels, or the caller's whole row)
  and the two honest repairs (`effectInclusionMsg`). The legacy graded-index
  check still fires beside it on one fixture; retiring legacy checks stays on
  the list below.
- *LSP hover doubled the forcing row* (`main : <IO> <IO> Unit`): the scheme
  renderer now prints a binding's forcing row itself, so the hover-side
  workaround that re-read the written leading effect is deleted.

**WasmGC emitter defect, predating this session:** compiling the compiler to
Wasm (the `wasm` CI job, `playground/build_playground_wasm.sh`) fails
validation in the lambda for `declaredEffectsAt` (`typecheck.mdk`): a record
literal whose field is `map (map f) xs`, the outer callback a partial
application of `map`, is mis-sequenced by `compiler/backend/wasm_emit.mdk`
(`struct.new` receives an `i32` where a boxed field belongs). The first full CI
run failed the same way. It is a backend bug to fix in the emitter as a general
rule, not by rewriting the source around it.

**Intentional changes whose goldens were re-derived (each diff read):**
function arrows render their open row tails (`(a -> <b> c)`), nullary bindings
render a solved forcing row (`main : <IO> Unit`, no longer `<IO | a>` or
`<a> Widget …`), written leading effects print as written. That moved the
boot-typecheck goldens, LEG A and the LEG D probe golden, the typecheck-error
corpus, the check-module `oracle.tcmod` files, the LSP completion dump, the
error-quality corpus (line order only), the stdlib doc pages and the catch-all
ledger (`sourceBindingArity`, a justified catch-all). Two check-module fixtures
had dishonest signatures (`runIt : … -> Async b c -> c` running the argument's
row) and now declare `-> <b> c`; the spec example `applyTo` in SYNTAX.md had the
same shape and is corrected.

**#825 drained.** The deferred-callback pin now rejects with the inclusion
diagnostic and its eager control passes. The pin is re-pointed at
`test/typecheck_error_fixtures/effect_deferred_callback_launder.mdk` and
`effect_deferred_callback_eager_ok.mdk`; close #825 when the PR merges.

**Verification on the stabilized head** (fresh binary, fresh oracles, this
worktree): strict CLI closure check; every `compiler/**/*_test.mdk` sibling
suite (19 files, `typecheck_test` 75/75, `effect_bindings_test` 75/75); the
thirteen previously red gates (`diff_compiler_check_json`,
`diff_compiler_error_quality_baseline`, `diff_compiler_check`,
`diff_compiler_fmt`, `check_syntax_examples`, `diff_compiler_catch_all_census`,
`diff_compiler_doc_stdlib_reference`, `bootstrap_typecheck`,
`diff_compiler_check_cli_modules`, `diff_compiler_lsp`, `lsp_harness`,
`diff_compiler_selfproc`, `diff_compiler_must_fail`) and `diff_compiler_engines`
(660 fixtures, 0 regressions, 0 pin failures); `make snapshot-check`;
`make docs-links`; `make agent-doc-symbols`; `sqlite/lib/select.mdk` and
`pds/shell/blockfile.mdk` check clean. Not run locally: the full sqlite and pds
gate families, the self-compile fixpoint, and preflight's full expansion. CI is
the authority for those.

## Delivered code and invariants to preserve

| File under compiler/types | Responsibility at the checkpoint |
|---|---|
| effect_domain.mdk | Concrete Unit/Prefix/Set/Product algebra; Atom still lives here temporarily |
| effect_rows.mdk | Row DAG operations, normalization, visited maps and shared labelled links |
| effect_infer.mdk | Scoped, non-solving effect capture |
| effect_bindings.mdk | Source arity and body/forcing summaries; distinct produced and recursive rows |
| effect_values.mdk | Structural positive envelopes for branch/clause/literal/receiving joins |
| effect_solver.mdk | Protected producers, directed scoped constraints, SCCs and integer-keyed worklists |
| repr.mdk | Type/scheme representation and truthful open-row rendering |
| typecheck.mdk | Binding schedule, environment, signature/kind and selected-occurrence integration |

Produced summaries and recursive assumptions are separate: publish the produced
row, constrain it below the recursive assumption. Capturing a computation must
not solve it. After SCC collapse, variable roles have precedence rigid, borrowed,
owned allowance, ordinary existential. Before solving a child, transfer escaping
allowances **and their connected constraint component** to the parent. Removing
a reflexive/pure constraint must not accidentally discard allowance ownership.
The ownership-transfer mutation test failed as intended (expected empty, got
row id 21), then passed after restoring the code.

Positive joins keep function domains equal while joining results and latent
effects. Only proved-covariant data positions join; unknown, mutable and invariant
positions stay equal. Perform occurs checks before shaping variables. Fully
delayed joins for unknown value shapes remain unfinished.

Recursive contracts now use a paired `ValueScheme` carrying `Scheme` and optional
`CDeclared`. Primary and selected standalone bindings each retain their own
pair; `ScopedMember.smRecursive` keeps the `EnvBinding`. Recursive schemes and
predicate templates originate in one `sigToSchemeTvs` allocation in
`preunifySigsEx`; `declaredPredicateSlots` is shared with final definition setup.
Final definitions still own their separately registered IDs.

Every selected term occurrence must use **one retained instantiation** for type,
forcing row, row-indexed predicates, obligations and dictionaries. This includes
plain variables, `EDictAt`, selected `EMethodAt`, importer/definer shadows, applied
and value positions. `SelectedValueOccurrence` carries the instantiation and
shadow dictionaries. Deferred candidate probing must not charge forcing or emit
obligations before selection.

The universal-signature guard rejects grounding a declared type variable or
collapsing independent declared variables. It is needed to prevent recursive
dictionary ABI specialization; do not disable it or special-case away effect
rows. Qualified signature kinds come from resolved interface identity and module
visibility ordinal, not a global name-to-kind table. Recursive and body schemes
must classify variables consistently. Diagnostic locations were explicitly fixed.

The carrier was motivated by `monoid_mutual_recursive.mdk`: checking succeeded
but evaluation panicked on Semigroup dictionaries and native execution failed a
match. Its unchanged expected result is `abc|xy`. The persisted all-engine
fixture `effects_recursive_contracts.mdk` covers mutual Monoid recursion,
polymorphic Display recursion, swapped multiparameter predicates and selected
standalone shadows. Its value pin is five lines: `abc|xy`, `1`, `2x`, `y3`, `1`.
The new CI numeric failures show this coverage is not sufficient by itself.

Semantics correction already made: `deferPure` introduces a fresh polymorphic
grade, conceptually `forall e. a -> f e a`; it does **not** coerce an existing
`f <> a` into `f e a`. `deferWhen`/`deferUnless` preserve the grade instead of
claiming purity. Keep inference, signatures, docs and snapshots consistent.

## Remaining merge blockers

These are tracked by the draft PR and its architecture delivery checklist; this
list is not a claim that an independent full-head review found nothing else.

1. A fresh CI run on the stabilized head read to terminal, and an exact-head,
   whole-diff adversarial review.
2. Named authorities, qualified fields and constructor proof sources (#3385).
3. Retire unchecked quoted underscore and first-argument hole filling: known
   laundering #3382/#3383 still exists. Keep legacy soundness checks until their
   replacements cover every route.
4. Resolved effect-label identity and consistent domain schemas; string labels
   and mixed-domain fallback remain.
5. General qualified directed residual constraints in schemes, plus fully
   delayed unknown-shape produced-value joins.
6. Shared invocation-protocol summaries for policy/manifest consumers rather
   than re-deriving semantics by structural traversal.
7. Prefix rendering/canonicalization #3391 (S2; no demonstrated laundering).
8. Final performance, cross-engine, self-hosting and CI verification after all
   semantic changes. Earlier successful subsets do not discharge this.

Open issue pins are already durable under `test/must_fail_fixtures/`:
`3382-user-signature-effect-hole-unchecked`,
`3383-rename-destination-uncharged`, and `3391-prefix-join-render`.
The branch also changed `819-impl-head-tyvar-pinned`; recheck its current contract.
The #825 drain above is new evidence. #830/#2111 remain relevant semantic history.
#3328 remains open although this branch implements forcing preservation; verify
its exact production-path acceptance before closing it. The handoff-time
`must_fail_census.sh --all` reported no pinned-but-closed issues, but did report
stale unrelated exemptions and unpinned candidates (including #3328). Its exit 0
is not a clean-census claim. Do not sweep unrelated tracker debt into this PR.
Broader superclass evidence, general cache/namespace migration and unrelated
typechecker file splitting are not prerequisites to finish effects.

## Architectural decision record for the next session

The decisions below explain the design, rather than just naming current files.
Revisit a decision when a counterexample disproves its invariant; do not accumulate
local exceptions around it. The new CI numeric cases are evidence to investigate,
not yet evidence that the entire scoped architecture should be discarded.

- **One inference schedule, several constraint families.** Effects participate in
  existing binding SCCs, lexical scopes, wanted/outcome scheduling and publication.
  They are not a second typechecker or a whole-program repair pass. Shared scheme,
  signature and occurrence carriers are legitimate prerequisites because they
  own the information effects must retain. Instance ranking stays effect-blind.
- **Separate facts that have different owners.** A source body's produced effects,
  its written allowance, and its recursive-use assumption cannot share one mutable
  cell. Equality would let consumption rewrite what a producer did, or let a body
  choose its caller's universal. The produced/recursive split and directed proof
  boundary replace that accidental coupling. Recursive least solutions remain
  desirable, but only for variables the current inference scope actually owns.
- **Ownership is semantic, not reachability.** An open tail is not proof of
  permission; seeing a variable does not entitle capture to solve it. A local
  allowance that escapes must take its connected obligations with it before
  child solving. Generalization and publication are proof boundaries: unresolved
  required constraints cannot vanish just because a variable leaves a local scope.
- **Equality, directed flow and positive joins are different judgments.** Forcing
  all three through HM equality loses effects or overconstrains legitimate code.
  Conversely, treating every nested type position as covariant launders mutable
  or authority-indexed state. A single structural producer-envelope service owns
  branch/match/clause/container joins; shape-unknown cases need delayed constraints,
  not a list of expression-specific exceptions. An inference variable in an as-yet
  unknown constructor slot is not the same thing as widening an existing container.
- **An occurrence is an indivisible instantiation event.** Reconstructing a
  selected standalone type or instantiating predicates separately loses binding
  identity and can change dictionary ABI. Keep type, immediate forcing, latent
  rows, predicates and eventually authorities together. A probe is not evaluation;
  only selection followed by a real occurrence charges effects/obligations.
- **Source arity and forcing are not inferred arrow count.** Intermediate source
  applications construct closures; the last source application runs the body.
  Returned functions have their own rows. A nullary lazy binding charges on force,
  including through aliases/imports, regardless of runtime memoization. This is a
  may-effect analysis, not an execution-count or evaluation-order change.
- **Nominal identity before authority precision.** Interface-derived kinds and
  effect labels require resolved identity/provenance, not spelling. Authority
  relationships must survive in types and schemes through abstraction. Re-reading
  the call AST or the first argument after information has been erased cannot
  prove higher-order, partial or stored-value safety.
- **No proof, no precision.** Concrete domain operations, symbolic terms and
  constraint solving have distinct owners. Unknown source values conservatively
  require top; an unresolved symbolic relationship stays pending or errors.
  Prefix abstraction is not filesystem canonicalization or a runtime sandbox.
  Qualifiers erase only after checking, with no new dictionary/runtime arguments.
- **Narrow module interfaces, explicit state.** Leaf modules may be stateful but
  receive only allocation, levels/scopes, relation/variance callbacks and diagnostic
  services they need. Do not pass the entire typechecker state or import the
  orchestrator back into a leaf. The proposed atom extraction prevents a concrete
  domain/authority/row representation cycle. Exact new file names are not sacred;
  preserve the dependency direction in the architecture module table.
- **Request isolation is part of soundness.** Never cache live request-owned
  variables or obligations for a later request. Freeze summaries or instantiate
  templates afresh. Test cold P against P after failed/conflicting Q, module import
  permutations and cache hits, comparing diagnostics, effects and evidence.
- **Performance follows graph structure.** Use stable-ID maps/sets for variable
  populations, blockers, SCC edges and worklists; wake constraints by changed
  dependencies rather than rescanning all pending goals. Rows/joins are shared
  DAGs; traverse each identity once per operation, with traversal-local visited
  state because cells mutate. Keep deterministic sorted rendering separate from
  hash iteration. Small fixed products/capped sets can use lists. Stress shared
  diamonds, duplicate-heavy and many-label rows, not just source-file size.

The researched precedents and primary-source links are retained in
[Architectural precedents](../../compiler/EFFECTS-ARCHITECTURE.md#architectural-precedents):
GHC's implication scopes motivate local proof boundaries; Rust's universal versus
inference region distinction motivates not solving caller-chosen authorities;
Koka motivates separating row inference and generalization. Do not copy GHC's
whole scheduler, Rust borrowing semantics, or Koka duplicate-label handler rows:
Medaka has one joined atom per label and no effect handlers.

Explicitly ruled-out shortcuts: reopening a solved closed row on instantiation;
treating any two open rows as compatible; suppressing universal errors for row
types; using implementation pattern names as authority identity; first-argument
or callee-name hole filling; raw-field qualifiers without construction evidence;
making mutable indices covariant; trusting cross-engine agreement without value
pins; deleting legacy off-spine soundness checks before equivalent coverage.

## Next authority design: researched, NOT implemented

The architecture/spec own the contract; the following is a proposed concrete
implementation route, not a description of current symbols or final decisions.

**Prerequisite: nominal effect identity.** Introduce an effect reference keyed
by defining origin and name, stamp declarations/occurrences, preserve exported
definer provenance, reject ambiguous imports, and key domain schemas by that
reference. Rows must not merge two imported same-spelled effect labels. Do this
before symbolic authorities; otherwise their domain identities are unsound.

Suggested new modules in `compiler/types/`:

- Authority terms/normalization: concrete parameter, variable, symbolic join.
  Variables carry stable ID, level, domain identity, rigid/flexible/link/bounds
  state. Use ID maps for roots, deduplication and substitutions.
- Effect atoms: resolved label plus authority term. Move Atom out of the concrete
  domain module to avoid a dependency cycle; rows consume atoms structurally.
- Authority constraint solver: explicit directed actual-below-allowed wanteds,
  symbolic lower joins for flexible variables, rigid variables never chosen by
  bodies. Deferred constraints must be transported or rejected, not forgotten.

Keep concrete domains free of inference variables. Extend the type representation
with a qualified-value wrapper and schemes with authority quantifiers/residuals.
Every type visitor (substitution, free variables, generalization, levels, occurs,
unification, rendering) and atom visitor needs the new sort. Every occurrence
must share a single type/row/authority substitution, extending the carrier above.

Replace string-encoded source atom parameters with structured bare, literal,
name, set and product forms. Add a named-arrow AST form for
`(path : String) -> <FileRead path> String`, plus explicit `String @p` qualifiers.
Thread all AST walkers, resolution/stamping, desugaring, printer/formatter and
LSP displays. This is language-feature work, so use the corresponding skill.

One proof route should handle all calls:

- The signature binder introduces rigid authority kappa over its result; the
  body argument has that qualifier regardless of implementation pattern spelling.
- Use sites freshen it with the occurrence's shared substitution. Directed
  qualified flow emits actual authority below expected authority.
- Literals supply domain abstraction; raw unknown values supply top; qualified
  values forward their proof. An unqualified value cannot gain a narrow qualifier
  merely by unification.
- Application charges the selected arrow's symbolic row. Remove `fillHolesInRow`,
  `spineFirstArg` and alpha-based hole filling; no callee-name/first-argument rule.
- `rename` carries both source and destination authorities and joins them. Aliases,
  partial applications, returned functions, higher-order application and composition
  retain relationships through types, not re-inspection of expression syntax.
- Publication discharges or transports residual constraints. Manifest output for
  unresolved authority is conservative top or an explicit error, never omission.
- Qualified fields/constructors require proof on introduction; pattern matching
  recovers only declared evidence. Mutable storage and invariant indices cannot
  widen. Authority terms erase before runtime layouts; no runtime check is implied.

Ratify before coding: whether the first authority increment includes indexed
data/fields/existentials or explicitly leaves their syntax proposed; lexical-only
authority binders (recommended, no implicit free names); product-axis grammar
and rejection of incompatible domain reuse; spaced `String @p` versus tight `@`
lexing; explicit trust in qualified FFI declarations, with no underscore exemption.
These are unresolved implementation choices, not permission to weaken the spec.

Order after CI stabilization: identity/structured atoms; authority and atom
carriers plus complete substitution traversal; named-arrow elaboration and
qualified flow/rigid checking/residual publication; runtime catalog migration
and deletion of holes; data/field proof sources and variance; complete gates.

Required anti-laundering matrix includes direct literal versus raw dynamic input;
honest versus dishonest named wrapper body; implementation binder renaming;
both rename positions; higher-order apply/compose; aliases/partials/returned
functions; occurrence freshness and shared substitution within one occurrence;
qualified constructor introduction/match recovery versus raw fields; Array/Ref
invariance; imported same-spelled effect identities; incompatible domains and
missing product axes; underscore rejection for user and extern declarations.
Every negative needs an honest control. #3382 and #3383 must become ordinary
regressions asserting rejection, not disappear by changing their expected output.

## Verification receipts and their limits

Before the recursive carrier additions: 69 binding, 26 solver, 5 value and 3 repr
native tests passed (103 total); CHECK CLI plus 71 entries and ELABORATE CLI;
C3a seed reference and C3b byte-identical fixpoint; nine selected engine fixtures;
169 native CLI cases, nine cross-project cases and seven compiler snapshots.
Bindings allocation scaled 2.04x/2.04x, nesting 2.08x/2.15x; bindings time
1.26x/1.46x, nesting below timing floor. No threshold relaxation. These are older
checkpoint receipts, not final-system performance certification.

After recursive contracts and qualified kinds: fresh compiler, full source
CHECK/ELABORATE and C3a/C3b passed; 72 native binding tests; the recursive-contract
fixture passed eval/native/Wasm and its absolute pin; 29 dictionary snapshots,
169 native CLI cases, nine cross-project cases, 61 type snapshot differentials
plus four named snapshots passed. Independent read-only review of this bounded
carrier/kind change found no blocking issue. This was **not** a whole-PR proof.

After the last code edits (comment cleanup, equivalent lint refactor, diagnostic
locations): fresh build/check-self and **73/73 native binding tests** passed.
The earlier full-source/fixpoint/all-engine checks were not all rerun after those
last edits. Commit `552b7b7ce` then changed docs and four LEG A goldens only:
fresh `check_all_main` agreed on 15/15 LEG A modules. This did not run full
selfprocessing legs B/C/D; CI now reports `tc_probe` failing.

Preflight's dry-run expanded to the full suite due to compiler/support scope;
the full local suite was deliberately not run. The must-fail census was not
clean. The red CI section is later evidence than these receipts.

Reproduction starting commands, in the branch worktree (read each gate's skill
and controls first; these are not an instruction to run the full suite locally):

```sh
make medaka
MEDAKA_STRICT=1 ./medaka check compiler/driver/medaka_cli.mdk
./medaka test --native compiler/types/effect_bindings_test.mdk
./medaka test --native compiler/types/effect_solver_test.mdk
./medaka test --native compiler/types/effect_values_test.mdk
./medaka test --native compiler/types/repr_test.mdk
FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one diagnostics_project_main
sh test/typecheck_compiler_source.sh
sh test/selfcompile_fixpoint.sh
FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one eval_autoprint_main
FORCE=1 JOBS=1 sh test/build_oracles.sh --build-one wasm_emit_modules_main
MEDAKA_REQUIRE_WASM=1 ONLY=engine/effects_recursive_contracts INNER_JOBS=1 JOBS=1 sh test/diff_compiler_engines.sh
./medaka snapshot --check test/eval_dict_fixtures --out test/snapshots/eval_dict_fixtures --stages eval
```

Use one `--build-one` per invocation: multiple flags silently selected only one.
Never edit compiler source during a build, borrow another worktree's emitter,
or trust a stale stage probe because the CLI is fresh. A stale eval probe once
reported a spurious `putStrLn`/String failure; rebuilding the probe fixed that
attempt with no source change. Generic build “can't parse” fallback messages can
hide a type error: inspect the full diagnostic. Snapshot blessing must use the
repository blessing helper and named reviewed changes, not mass acceptance.

## Checkpoint and workspace ownership

History: `6991fa7d1` forcing foundation; `e7050278f` foundation docs;
`407ed9563` scoped solver/produced values/recursive contracts;
`552b7b7ce` doc-symbol and LEG A maintenance. All implementation is committed and
pushed. No essential source or design exists only in a stash, child worktree or
temporary probe. Some exploratory reviewer probes were not persisted; do not
count them as continuously maintained regression coverage.

All session agents completed. No owned command/build remains awaiting a result.
The shared repository has unrelated worktrees and five unrelated stashes; leave
them alone. Process inspection in the sandbox is namespace-local, not evidence
that the whole shared host is idle. Temporary logs/probes are optional evidence,
not prerequisites; source tests, this handoff, the PR and CI links are durable.
Do not resume by replaying the entire earlier session: start with the red CI and
the explicit delivery gaps above.
