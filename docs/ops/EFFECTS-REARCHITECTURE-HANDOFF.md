# Effects rearchitecture session handoff

**Status:** INCOMPLETE — draft PR. The named-authority work (#3385's arrow
half, #3382, #3383, #3391) landed in the session of 2026-09-24/25 (see
"Named-authority session"); the data half of #3385 and the final CI run on
that head are still owed. CI was last green on head `fbe6d455b` (run
36064803849, every job). Handoff first recorded 2026-09-24.

## Resume here

Continue [PR #3393](https://github.com/MedakaLang/medaka/pull/3393), branch
`effects-architecture-one-shot`. The source checkpoint is the branch head; the
named-authority session below is its last commits. `main` is merged in as of
`9d7fd98ac`. Do not enqueue the PR until a fresh CI run on the head is read to
terminal; Val decides the merge.

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

**WasmGC emitter defect, predating this session, fixed:** compiling the
compiler to Wasm (the `wasm` CI job) failed validation in the lambda for
`declaredEffectsAt`. The record was incidental: any statically routed (`RKey`)
method call supplying fewer or more arguments than the method's value arity
(`map (map f) xs`, whose inner `map f` supplies one of two; `get (Box inc) 41`,
whose result is applied again) was emitted as a bare direct call, while every
other route already guarded saturation. `compiler/backend/wasm_emit.mdk` now
applies the saturation rule the LLVM emitter's `emitImplCallSat` applies: an
under-applied site builds the method's eta closure and applies through
`$__mdk_apply`; an over-applied site makes the saturated call and applies its
result to the rest. `test/engine_fixtures/method_rkey_under_over_applied.mdk`
pins both across the three engines; the playground build validates again.

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

## Named-authority session (2026-09-24/25)

What landed is itemised in [Effects architecture](../../compiler/EFFECTS-ARCHITECTURE.md)
§ "Named-authority checkpoint" and stated normatively in
[Effects semantics](../spec/EFFECTS-SEMANTICS.md) §1, §4.1 and §11; the codes
are in `compiler/DIAGNOSTIC-CODES-DESIGN.md`; the surface is in
`docs/spec/SYNTAX.md`. This section records the decisions, the traps and what
is owed, not the design.

**Ratified by Val before coding (AskUserQuestion, 2026-09-24):**

1. *Layer 1 only.* This increment covers named arrows, qualified argument values
   and label identity. Qualified data fields, constructor proof sources and
   authority-indexed existentials keep their proposed syntax in the semantics and
   are not implemented; nothing pretends otherwise.
2. *Lexical-only binders.* An atom or qualifier may name only a binder written to
   its left in the same signature. No implicit free names, no module-level
   authority names.
3. *Keep the literal grammar; a binder fills the Host axis.* Product atoms keep
   `Host="…" Method={…}`; `<Net host>` with a named binder qualifies the Host
   axis, other axes stay as written or top.
4. *Spaced ` @p` only.* `String @p` is the qualifier; a tight `@` is not lexed
   as one.

**Design decisions made while implementing, each a general rule:**

- *Undirected unification erases a top-level qualifier.* `unifyN` cannot tell
  which side is the value, so `TQual a q ~ b` equates `a ~ b`, and a metavariable
  meeting a `TQual` binds to the inner type. The first cut kept the qualifier on
  a variable and demanded `top ⊑ q` against a plain side; that rejected
  `p ++ "/x"` inside `appendOp` (the operands are equated) and would have let an
  unconstrained value (`v : a`) gain a qualifier through `v == p`. A qualifier now
  reaches a variable only through a directed flow: `argumentInto` (an allowance
  above the value's authority in a flexible slot), `bindFrom` (a declared
  parameter in `peelOntoParams`, a match scrutinee, a `let`/do pattern, an
  application's result). `appendOp` returns the operands' plain value type: an
  operator's result is a new value whose authority is `α`'s to decide, which is
  what keeps `n ++ "_X"` in a Set domain at top while `p ++ "/x"` in a Prefix
  domain keeps `p`.
- *Composition and pipes are not applications of an unknown value.* `composeOp`
  used to apply `g` to a fresh variable, which abstracted to top and solved `g`'s
  authority away; it now takes `g`'s own arrow (`calleeArrow`). `x |> f` routes
  through `applicationRow` with the argument's syntax, so a literal piped into a
  named extern is proved like `f x`.
- *A module-level residue is solved once.* A value binding the value restriction
  keeps monomorphic (`comp = load >> f`) leaves an authority variable no binding
  owns; its lower bounds arrive from later bindings. `checkAuthorities` transfers
  such wanteds to `SummarySolver.essRoot` when there is no enclosing scope, and
  `closeRootAuthorities` (called from `processTopGroups` after the last SCC) takes
  the least solution over every use and decides them. The first-scope-binds
  alternative was rejected as order-dependent and strictly less permissive than
  the least solution.
- *A local `effect Env` is another label.* With identity by declaring origin, a
  module that declares `effect Env Set` and redeclares `getEnv` writes a row over
  its own label, which the catalog-row cover check rightly refuses. The six
  `test/effect_param_fixtures` dropped their local declarations (the builtin
  labels already carry the domain). This is the type-shadowing rule applied to
  labels, not a defect.
- *`α` reads syntax before types.* Typecheck sees `EVar`/`EVarId` (`EVarAt` is
  minted by `annotateProgram` after typecheck); the `EVarAt` arm in
  `effect_infer.mdk` is harmless but never hit during inference.
- *A second application route was hiding in the standalone-shadow arms.* A
  user binding named like a prelude method (`sub` beside `Num.sub`) is applied
  through `unifySpineResult`, which took argument TYPES only, so every argument
  abstracted to top and a wrapper so named could not be called within a bound.
  Found by the engine fixture (`sub` was its wrapper's name); invisible to the
  matrix sibling, which runs without the prelude. The spine helper now takes the
  argument nodes and applies through `applicationRow`. The lesson generalizes:
  any arm that consumes a `List Mono` of applied arguments is a route that has
  lost the argument's syntax; `unifySpineProbe` is the one that remains, and it
  is a probe whose instance is discarded.
- *A cell read is a directed flow.* `!r` and `r.value` unified the cell's type
  with `Ref inner` undirectedly, which erased the stored qualifier; `refStored`
  reads it verbatim (the `Ref` invariance pair pins both directions).

**Traps paid for in this session:**

- Every `compiler/**.mdk` or `stdlib/**.mdk` edit after a build starts makes
  the binary stale; `MEDAKA_STRICT=1` then exits 1 with only a stderr warning,
  and a suite script that filters stdout reads as "no output". Two suite runs and
  one delegated verification were lost to this. Batch edits, then build.
- `stdlib/test_process.mdk` is outside `medaka_cli.mdk`'s closure, so the strict
  closure check cannot see an invalid written pattern there (`<Exec "mktemp">`
  needed a delimiter: `"mktemp*"`); `make snapshot-check` found it.
- `medaka test` on a `*_test.mdk` interprets the compiler from source, so a
  typechecker change can be exercised there before any rebuild; the scratch
  driver that printed each matrix row's diagnostics found the concat and
  composition defects in one run.
- New syntax in `stdlib/` must be cold-bootstrappable: the first CI run on
  the pushed head failed at "build medaka once" because the checked-in seed
  (`compiler/seed/emitter.ll.gz`, an older compiler) cannot parse
  `(path : String) ->` in `stdlib/test.mdk`, and every downstream job failed
  by dependency. `sh test/refresh_seed.sh` twice, then
  `sh test/bootstrap_from_seed.sh`, before pushing a syntax change the stdlib
  uses; AGENTS.md's `[T-EMITTER-BENCH]` says so for codegen changes and it
  holds for the parser too.
- The `compiler-soundness` job's must-fail step runs BEFORE the whole-source
  typecheck and the fixpoint, so a drained pin skips both in CI; they were run
  locally instead (`test/typecheck_compiler_source.sh`,
  `test/selfcompile_fixpoint.sh`, C3a and C3b yes). That source typecheck also
  carries the `OriginUnresolved` producer ratchet: the parser may not name the
  sentinel, so `effectDeclUnstamped` (`frontend/ast.mdk`) is the helper the
  effect declaration goes through.
- The catch-all census ledger is re-derived when a projection over `Expr`
  gains or loses a catch-all clause (`appArgExpr` gained one; `alpha`,
  `spineFirstArg` and `spineHeadIsApp` retired); the perf gate needs the
  `profile_main`/`profile_modules_main` oracles, which the effects oracle set
  does not build; a SYNTAX.md example must be in the formatter's canonical
  wrapping and an extern in it must name `FFI`.
- The `must_fail` gate's drain instruction is `git rm -r` of the pin directory;
  this session's tool policy refused that deletion ("security test removal"),
  so the three drained pins are still in the tree and the `soundness` job's
  must-fail step will report `3382`/`3383` DRAINED and `3391` CONTROL-BROKE
  until Val removes them. Nothing else is owed for those issues.

**Receipts on the final source state (build 11, oracles rebuilt after it):**

- `MEDAKA_STRICT=1 ./medaka check compiler/driver/medaka_cli.mdk`: 0 errors.
- Sibling suites: `effect_authority_test` 10/10, `effect_bindings_test` 75/75,
  `typecheck_test` 75/75, `effect_solver_test` 28/28, `effect_values_test` 5/5,
  `effect_domain_test` 7/7, `effect_rows_test` 9/9, `effect_infer_test` 2/2,
  `repr_test` 3/3, `solver_contract_test` 3/3, `check_policy_test` 2/2,
  `route_key` 38/38; domain fixture suites: param 6/6, product 8/8, builtin
  44/44.
- `MEDAKA_REQUIRE_WASM=1 ONLY=engine/named_authority diff_compiler_engines`:
  eval, native and wasm agree and match the absolute pin (three lines).
- The nine typecheck-error goldens were captured from `check_main`, read
  against §4.1 before blessing, and the `ok` control's argument was corrected
  once (`"config"` is not within `"config/*"` under the delimiter discipline;
  the wrapper narrows within the argument, so the caller must pass a path
  inside the bound).
- `run_gates.sh` over fmt, check*, snapshot*, selfproc, lextok, native_cli,
  eval*, must_fail, bootstrap_lex, fixture_corpus_coverage, source_bytes,
  lint*, effect_polarity, manifest*, engines: 26 pass; `diff_compiler_fmt`
  passes through `medaka gate run` (the bare runner leaves `MEDAKA_ROOT`
  unset, which silences the reimpl lint rows, as the test's own header says);
  `diff_compiler_check_wrapper_callers` passes after the ledger row for the
  matrix sibling; `diff_compiler_must_fail` reports 3382/3383 DRAINED and 3391
  CONTROL-BROKE, the drain this session could not delete.
- Snapshots re-blessed for the 33 moved compiler/stdlib sources plus the
  diff fixture, `--new` for `effect_authority.mdk`; LEG A re-captured (the
  removed lines are the deleted and re-typed helpers); lextok goldens for the
  migrated stdlib files; the native-cli check golden, boot_lex golden and
  combined golden of `effect_param_hole`; `docs/stdlib` regenerated.
- `docs-links`, `agent-doc-symbols` (one ledger row for the archived census's
  retired `Known`), comment-register census, shout-diff and the registry
  keying ratchet: green.
- CI on the final head `bbb98f13c` (run 36090508390): every job green except `compiler-soundness`, whose must-fail step reports the three drained pins and skips the whole-source typecheck and fixpoint behind them; both were run locally on that head and pass.

**Owed after this session:**

1. Delete `test/must_fail_fixtures/3382-*`, `3383-*`, `3391-*` (drained; the
   regressions live under `test/typecheck_error_fixtures/effect_*`) and close
   #3382, #3383, #3391 when the PR merges.
2. The data half of #3385 (delivery item 6 in the architecture).
3. A located `R-AMBIGUOUS-EFFECT` (an `EffAtomTy` carries no `Loc`).
4. A destructured qualified value (`Some x` from `Option (String @κ)`) and a
   lambda parameter without a directed flow lose the qualifier: conservative,
   documented in the architecture, not a launder.
5. The whole-diff adversarial review and the CI run on the final head.

## Delivered code and invariants to preserve

| File under compiler/types | Responsibility at the checkpoint |
|---|---|
| effect_domain.mdk | Concrete Unit/Prefix/Set/Product algebra; `canonParam`; the prefix join canonical form (`lcp*`) |
| effect_authority.mdk | Authority terms (`AConst`/`AVar`/`AJoin`), normalization, `authSub`, rendering |
| effect_rows.mdk | `EffLabel` identity, `Atom = label + authority`, row DAG operations, normalization, visited maps and shared labelled links |
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

1. An exact-head, whole-diff adversarial review, and the CI run on the final
   head read to terminal (CI was last green on `fbe6d455b`, run 36064803849).
2. Qualified data fields, constructor proof sources and existentials (#3385's
   data half). Named authorities on arrows, the underscore's retirement, label
   identity and the prefix-join canonical form are delivered.
3. Removal of the three drained must-fail pins (see "Owed after this session").
4. General qualified directed residual constraints in schemes, plus fully
   delayed unknown-shape produced-value joins.
5. Shared invocation-protocol summaries for policy/manifest consumers rather
   than re-deriving semantics by structural traversal.
6. Final performance, cross-engine, self-hosting and CI verification after all
   semantic changes. Earlier successful subsets do not discharge this.

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

## Authority design: the route that was implemented

This was the proposed route before the named-authority session; it was followed
in the order given, with the deviations recorded in "Named-authority session"
above. The module names are now real (`types/effect_authority.mdk`,
`types/effect_rows.mdk`'s `EffLabel`/`Atom`, `TQual`, the five-field `Forall`,
`EffParamTy`, `TyNamed`/`TyQual`). The "Ratify before coding" list was ratified
as recorded above. Qualified fields/constructors remain the proposed surface.

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
