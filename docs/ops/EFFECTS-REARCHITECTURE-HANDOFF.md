# Effects rearchitecture session handoff

**Status:** The arrow half (PR #3393, `f81ff1d9d`) and the data half (PR
#3445, `ea782db98`) of #3385 are on `main`. The close-out session (branch
`effects-closeout`, § "Close-out session") answers the data half's owed list,
fixes #3304 and pins #3327; delivery item 7 and the two remaining checklist
items have proposals awaiting ratification there. Handoff first recorded
2026-09-24.

## Resume here

The effects rearchitecture is on `main`. Start the next piece of work from
`main` on a topic branch. Read this handoff's § "Close-out session" first: its
last list is the open work, as proposals awaiting ratification, and nothing in
it is to be implemented before Val rules on it. Then the architecture, the
semantics and the typechecker contracts; the reading order below still applies.

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

**The adversarial review (2026-09-25, at `35654f79f`) and what it changed.**
Fourteen findings; five S0/S1, every one reproduced with this session's binary
before it was fixed. Each fix is a general rule, and each has a regression
under `test/typecheck_error_fixtures/effect_*` beside its honest control:

- *S0: `α` resolved names by spelling.* A match arm, a let pattern or a local
  definition that rebound the named argument's name read the outer binder's
  qualifier, and a let chain read a later rebinding. Now a local binder
  enters the α scope (`AlphaBinder`, innermost first): a let with its
  right-hand side (`ALet`), a parameter or pattern the environment types
  (`AParam`, read through the checked type), or a binder inside the argument
  itself whose value nothing can see (`AOpaque`, the top; an arm that merely
  renames the scrutinee reads it). A let's right-hand side is read in the
  scope it was bound in (`letInScope`). The first cut kept a flat name list
  and deleted entries on rebinding, which lost the older let a still-older
  let referred to; the second cut marked a parameter as opaque, which hid the
  parameter's own qualifier. `patBoundNames` lives in `frontend/ast.mdk`.
- *S0: a method contract's binder was solved at the root.* Its variables are
  minted before the body's scope opens, so the level test called them outer
  and the module residue solved them. A declared universal is rigid wherever
  it was minted (`localRigidAuth` asks only the rigid set).
- *S0: the catalog-row cover check was blind to positions.* Both rows are now
  lifted with one authority variable per argument position (`positionCells`,
  `positionalSigVars`; the catalog map carries each row's binder order), so a
  redeclaration covers the catalog only when its binders name the same
  arguments; a bare label still covers, a binder never covers a bare one.
- *S1: method bodies, lambda-form definitions and qualified results.* A
  method's parameters bind from the contract verbatim (`unifyParamsExpected`
  through `bindFrom`; the generic default check used to pass no expected
  domains at all), a lambda meeting a known arrow binds its parameters before
  its body is inferred (`inferExpected`'s `ELam` arm, through `normalize`,
  since the expected type arrives behind a link), and a clause's produced
  value flows into the binding's result slot (`publishProducedResults` through
  `bindFrom`): the same directed-flow rule as arguments and calls.
- *Pre-existing S0 at the merge base:* a written Prefix element containing a
  `/` anywhere was a prefix, so `"/etc/host"` admitted `/etc/hostname`. An
  element without a trailing `*` is exact (`isPrefixPattern`; §2.3 amended).
  The one fixture that pinned the old algebra, `ffi_libname_wildcard_accept`
  ("a wildcard library name is the same set as the bare name"), now pins the
  one direction the order admits: the exact name lies within the pattern.
- *Ratification 4:* the tight `String@p` lexed as a qualifier; `@` adjacent to
  any identifier character is now `TAsAt`, and the parser refuses a tight
  qualifier naming the spaced spelling.
- *§11 overclaimed:* residual constraints do not travel with a generalized
  scheme; the module-level residue is decided over the module instead. The
  sentence now says so.

Still open from the review, none a launder: error locations that land on an
honest body or a last arm rather than the call (S2); the "declared row admits
only X" wording when X is a solved bound rather than the written one (S2); a
symbolic join renders as `(src | dst)`, which no signature can spell (S2); the
manifest and the policy checker key labels by bare name, so two modules'
same-spelled labels produce duplicate TOML keys (S2, needs a format decision);
one defect can report twice (S2); `literalAuthority` hard-codes the Product
axis `Host` and no declared axis schema exists (S3, the data half); a PLAUSIBLE
`unifyIntoN` arm that binds a value's variable to a qualified type in positive
position without evidence (every attempt was caught at a later application).

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
  typecheck and the fixpoint, so a drained pin skips both in CI; while the pins
  were in the tree they were run locally instead (`test/typecheck_compiler_source.sh`,
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
- The `must_fail` gate's drain instruction is the removal of the pin
  directory; this session's tool policy refused that at first ("security test
  removal"), and Val authorized it. The three drained pins are removed and the
  gate reads 25 still reproduce, 0 drained.

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
  matrix sibling; `diff_compiler_must_fail` reported 3382/3383 DRAINED and 3391
  CONTROL-BROKE until the pins were removed, and is green after.
- Snapshots re-blessed for the 33 moved compiler/stdlib sources plus the
  diff fixture, `--new` for `effect_authority.mdk`; LEG A re-captured (the
  removed lines are the deleted and re-typed helpers); lextok goldens for the
  migrated stdlib files; the native-cli check golden, boot_lex golden and
  combined golden of `effect_param_hole`; `docs/stdlib` regenerated.
- `docs-links`, `agent-doc-symbols` (one ledger row for the archived census's
  retired `Known`), comment-register census, shout-diff and the registry
  keying ratchet: green.
- CI on `bbb98f13c` (run 36090508390) was green except the must-fail step's drained pins; with the pins removed, the full dispatched run on `35654f79f` (run 36105896609, `workflow_dispatch`, unnarrowed) was green on every job, `compiler-soundness` included. The review fixes landed as `d5bcbca70`; its dispatched run (36121365015) was green on every job but the perf gate, whose two-sided `modules:typecheck` TIME row fired its own under-2.00 promotion branch (r2=1.97), so that row is drained from `KNOWN_SLOW_TIME` (the Ir row in `stage_ir_scaling` stays the arm of record for #1879); the full dispatched run on the drained head `0fc8d0bfe` (36123654759) was green on every job. The PR had meanwhile become CONFLICTING with `main` (N1's fixed-width integers rewired match inference in the same functions), which is why GitHub had stopped creating `pull_request` runs; `main` is merged in as `403e1fdee` with the typechecker merged by hand (produced-value join, `bindFrom` and `captureEffects` kept; N1's literal-pattern bookkeeping and deferred match checks threaded through) and every derived golden re-derived from the merged compiler, LEG A additive-only against the branch tip (GitHub stopped creating `pull_request` runs for this branch's pushes after 353b4e21a, so the branch's runs are dispatched by hand). Locally on `d5bcbca70`: strict closure clean, whole-source typecheck PASS, C3a/C3b yes, matrix 14/14, every sibling and domain suite green, `named_authority` on all three engines, perf 0 regressed, 29 gates green plus the census after its re-derivation.

**Owed after this session** (the named-authority session's list, as the
data-half session left it):

1. #3382, #3383, #3391 closed with the merge. The data half (item 2) and the
   leftovers (items 3 and 5) landed in the data-half session, and its
   whole-diff review's findings are answered there; what remains is listed
   under "Owed after the data-half session".
2. A destructured qualified value (`Some x` from `Option (String @κ)`) and a
   lambda parameter without a directed flow lose the qualifier: conservative,
   documented in the architecture, not a launder.
3. Delivery item 7: migrating precision-dependent stdlib signatures to
   handles, and the declaration-kind/re-export gaps (#3327/#3304) the new
   surface depends on.

## Data-half session (2026-09-25)

What landed is itemised in [Effects architecture](../../compiler/EFFECTS-ARCHITECTURE.md)
§ "Data-half checkpoint" and stated normatively in
[Effects semantics](../spec/EFFECTS-SEMANTICS.md) §4.1; the codes are in
`compiler/DIAGNOSTIC-CODES-DESIGN.md`; the surface is in `docs/spec/SYNTAX.md`.
This section records the decisions, the traps and what is owed.

**Ratified by Val before coding (AskUserQuestion, 2026-09-25), each the
recommended option of a short proposal:**

1. *Syntax.* `data Handle (p : Authority FileRead) = Handle (String @p)`, the
   spec's §6.1 kind. An `Authority`-kinded index slot is kind-directed like an
   `Effect` slot: a named argument's name, an implicitly quantified lowercase
   name binding to its right as a type variable does (`read : Handle p ->
   <FileRead p> String`), or a domain literal. `@` stays name-only.
2. *Top in an index slot is `*`.*
3. *Construction.* A constructor whose fields carry the binder is a proof
   source anywhere it is visible; one that carries it in no field is trusted
   only at home, so `public export data` requires every constructor to carry it.
4. *Existential* = a kinded binder leading a constructor's fields, built last.
5. *Patterns* recover the declared field types under the index, directed, and
   never refine the index.
6. *Manifest keys qualify only on collision* (the leftover's format).

**Design decisions made while implementing, each a general rule:**

- *A name is a binder only where something binds it.* The arrow half minted an
  authority from any atom that named a binder, because the resolver had
  refused every unbound name. With index slots admitting a bare name to the
  left, the resolver's rule became "written to the left" and the kind moved
  to the typechecker: `sigVarsFor` binds a name only as a `String` named
  argument or an index-slot occupant (`authorityBinderBound`), and a name
  nothing binds is `T-AUTHORITY-KIND`, never a silent top.
- *An existential's scope is a match arm or a function clause, not a `let`.*
  Both have an end; the check at the end reads the ordinary level
  discipline (the scope runs one level deeper, the opened cells are raised to
  it, anything older that received them lowers them) plus the scope's own
  value type. The first cut minted the opened cells at the outer level and
  every arm reported a false escape. The clause form was added after lint's
  own `rule-destructure-in-param` steered a fixture toward it. No solver scope
  is opened for the arm: the enclosing scope decides the obligations (rigid,
  so a literal never satisfies one) and publication defaults a sourceless
  opened cell to top, which is §4's widening. An arm-owned solver scope was
  rejected as order-dependent across arms.
- *Record construction is an argument flow.* `unifyFieldAssignIdx` ran no `α`,
  so a literal into a qualified field hit `top ⊑ q`. It now goes through
  `argumentIntoOrd`, the same route as a call, with the value-first wording
  the record path always had; an explicit record sub-pattern binds through
  `bindFrom` so the punned and explicit forms agree.
- *`RecordInfo` carries authorities.* The record table was kind-blind (a
  `KRow` parameter was a plain type variable there); it now mints the same
  reprs as `registerVariants` and instantiates them together
  (`RecordSubst`).
- *`deriving` requires instances only of `Type`-kinded parameters.* The
  deriver asked `Eq e` of an `Effect` parameter; the kind list now reaches
  `paramRequires` and the doc generator's mirror of it.

**The review leftovers, in the order the prompt listed them:**

- *A located `R-AMBIGUOUS-EFFECT`.* `EffAtomTy` carries `eatLoc`, the atom's
  span from the parser; resolve locates the ambiguous-, unknown-label and
  unbound-authority diagnostics of an atom there. A qualifier's `TyQual`
  still has no span (an `Option Loc` on it fans out to some thirty-five
  sites), so `String @p` with an unbound `p` at declaration level stays
  unlocated: owed.
- *Locations on a body or a last arm.* The cause is that `infer`'s `ELoc` arm
  sets `currentLoc` and never restores it, so a check that runs after a body
  reads the body's last leaf. The general fix (restore after each `ELoc`)
  moves pinned locations across the JSON and LSP corpora and was not taken in
  this pass; instead an effect failure derived from a row check is located by
  effect provenance: `performEffect` records, per binding and label, the
  first site that performed the label (`effectSitesRef`), and
  `reportEffectSummaryFailures` reports there (`esfLabel` on the solver's
  failure). A value-flow obligation already carried the argument's span. The
  `ELoc` restore remains owed.
- *"declared row admits only X" for a solved bound.* The solver's failure now
  carries the upper term as recorded (`esfWrittenUpper`); a variable since
  solved gets its own wording ("not a written bound but what this binding's
  other uses … determined together"), and a written bound says "declared
  bound", since an index is not a row.
- *`(src | dst)`.* A joined atom renders as one atom per operand
  (`renderAtomWith`), the spelling the parser folds back; the `@(a | b)`
  qualifier form is unchanged and still unspellable (rare: a value whose
  authority is a join of two binders).
- *One defect twice.* Three mechanisms, each general: identical
  `lower ⊑ upper` failures from one scope report once (`distinctFailures`),
  an identical (code, span, message) is recorded once (`pushTypeErrorAt`,
  which also folds a default body's generic check and its per-instance copy),
  and the retained post-hoc escape walk skips a member the solver already
  reported (`rowFailureReportedRef`).
- *`literalAuthority`'s `Host`.* A Product label declares its axis schema,
  `effect L Product (Host : Prefix, Method : Set)`, carried on `DEffect` and
  registered as the label's top (`PProduct` of the axes at their tops, in
  declaration order; `subTopOf`/`isSubTop`/`canonParam` treat it as the top);
  the literal lifts into the first axis (`productPrimaryLift`), a written
  product is checked against the declared axes, and no axis name is spelled in
  the compiler. The six product fixtures declare their schema; a custom-axis
  fixture, a no-axes negative and an unknown-axis negative pin the rule.
- *Manifest keys.* Val's format: qualify only on collision. `manifestKey`
  writes a label bare unless two origins spell it in one row, then each as a
  quoted `"mod.Name"` key; `atomPermitted` accepts either spelling.

**The whole-diff adversarial review (2026-09-25), reproduced and answered:**

- *S0: an existential record field read published `RecEx -> Handle a`.*
  `instantiateRecordShared` freshened the existential flexible. A read cannot
  open the binder; it recovers the domain's top (`sharedAuthority`).
- *S0: the phantom check is syntactic.* `Tok Int (List (Handle p))` and
  `Cb Int (Unit -> <FileRead p> Unit)` pass `T-AUTHORITY-PHANTOM-EXPORT`, and an
  importer built `Tok 1 []` and `Cb 1 (u => ())` at `"config/*"`. The first
  answer was a dynamic rule — a construction's index as a claim bounded by its
  arguments' evidence, decided at the scope's close — and the second review
  round showed it order-dependent (`Tok 1 (hsOf t)` published `Tok *` where
  `hsOf t |> Tok 1` published `Tok p`; a claim in a `let` was decided before
  its evidence; grounding accepted `[] : List (Handle "cfg/*")`). The rule that
  stands is static: the export check decides *carrying* by the field's type
  (architecture item 8, semantics §4.1), so `Tok` is refused at its
  declaration and the claim machinery is gone. The S2 forwarder (`export
  mkRaw = Raw` republished `Int -> Raw p`) is closed by publication counting
  only argument-position occurrences as sources (`qualifierAuthIds`), so the
  forwarder is `Int -> Raw *`; a written signature's binders are never
  defaulted.
- *S0: a constructor binder spelled like the head's parameter defeated the
  check.* Resolve reports it as `R-DUP-BINDER` (`duplicateCtorBinders`).
- *S0: `fmt` corrupted an existential record constructor* (binders printed
  before the name). `recordVariantDoc` takes the binders.
- *S1: `impl Eq (D p)` failed `T-AUTHORITY-KIND`;* the head elaborated its
  variables as types. `implHeadMonos` is the one seam (inference and
  coherence). *An alias `type H (q : Authority L) = Handle q` was unusable;*
  its parameter recorded two obligations against itself and is now a link.
  *A field naming a later head was rejected;* kinds are recorded for every
  head before any field elaborates.
- *S2, each reproduced first:* an index binder at a Set label beside a Prefix
  one was silently one variable (`reportBinderDomains`, whatever binds it;
  two Prefix labels stay one shape, as for a named argument); a failure
  located at the first site performing the label rather than the offending
  one (`effectSiteOf` picks the first site outside the bound); a Product
  label accepted a repeated axis name; a bare literal into a Set first axis
  was checked as a prefix pattern (one lift, `productPrimaryLift`); a
  signature's unlocated kind error landed on the previous declaration
  (`sigToSchemeTvsIn` sets the location). Not reproduced, so not acted on: a
  `doc` rendering of a qualified arrow domain (it parenthesises), and an index
  name reused as a named argument (the named argument binds, the slot refers
  to it — coherent, kept).
- *Found while fixing:* the LSP hover fallback's `generalize` ran the
  sourceless default over locals whose cells are shared with published
  schemes, so the domain-only source rule rewrote every signature binder to
  the top after the fact. `generalize` now quantifies without defaulting
  (`quantifyFree`); the matrix row "a wrapper publishes its argument's
  authority" is the regression. Second: recording every head's kinds ahead
  of the declarations was first written with a per-head table scan, and the
  kinds table grows with every imported module, so the `modules` perf unit's
  typecheck time climbed (r2 2.72 on this box); `recordParamKinds` is a
  constant-time prepend again (r2 2.34 quiet). The unit's TIME row is
  re-ledgered in `test/diff_compiler_perf_scaling.sh` (`KNOWN_SLOW_TIME`): the
  drain that removed it on PR #3393 was the false promotion the row's own
  note predicts, and the plain climbing clause trips on the unfixed
  #154/#150 quadratic's own band (CI read r2 2.53 on the data-half head
  before any of this).

**The second review round (2026-09-25, on `04b66839b`), reproduced and answered:**

- *S0:* an imported existential record's field read published `SealedR ->
  Handle a` (the existential id table was per module; it lives with the id
  counter now); the claim rule was grounded by positions that prove nothing
  (replaced, above).
- *S1:* the claim decision was order-dependent and scope-dependent
  (replaced); a written signature with a result-only index was republished at
  `*` (declared binders are never defaulted); a return-position method at an
  authority-indexed impl head panicked (`monoSameGiven` is index-blind, as
  coherence is); a two-parameter interface over an indexed head hung in an
  improvement loop (a flexible index substitutes, `unifyIndex`); an impl at a
  literal index never dispatched (refused: an impl head takes a name).
- *S2/S3:* a binder-domain report once per module (once per signature now);
  `fmt` moved a comment out of an existential record constructor
  (`printNamedFieldData` renders the binders); a top qualifier printed as
  `String @` (bare type); a partial update of an existential record (refused
  unless every field under the binder is replaced); the duplicate-binder
  report was unlocated (at the constructor's fields); a record-pattern
  existential escape named `'?'` (the binder's cells are collected from the
  fields). The claim fixpoint's superlinearity went with the claims.

**Owed after the data-half session** (every item below is answered in §
"Close-out session"; kept as the record of what was owed):

- A span on `TyQual`, the `ELoc` restore, the `@(a | b)` qualifier form
  (above).
- Delivery item 7 (stdlib migration to handles).
- An unlocated `effect` declaration (`DEffect` carries no `Loc`): the axis
  and kind-label diagnostics report at the file's first span.
- An index mismatch between two written indices still reads as a row failure
  ("reaches X where its declared bound admits only Y"); a dedicated wording
  for index equality is wording work.
- `check_policy`'s bare Product token lifts through the same first-axis
  rule; a manifest row naming two same-spelled labels from two origins is
  keyed qualified (above) but the policy's `Method=true` decode of a written
  product atom was reported by the review and not reproduced.
- `test/check_module_fixtures` is a frozen corpus (hand-derived oracles), so
  the cross-module claim rows live in the matrix sibling through
  `checkModulesDiagsChain` rather than there.

**Traps paid for in this session:**

- `medaka check` on a probe that declares externs refuses them without `<FFI>`
  (`T-FFI-UNLABELLED`), while the matrix sibling's `checkOneDiags` does not:
  a probe replayed from a matrix row must use a prelude wrapper, not an
  extern. Likewise the sibling runs without the prelude, so a row that needs
  `:=`/`setRef` belongs in `test/typecheck_error_fixtures`, and a plain
  `String` field that leaks reports `T-EFFECT-LEAK`, which the sibling's
  `rejects` (`T-AUTHORITY` only) does not count — use `expectFalse (accepts …)`.
- The worktree guard refuses compound shells and `sed -n "$(…)p"`; every
  multi-step check went into a scratchpad script.
- `checkDeclaredKinds`'s exhaustiveness warnings are printed only for the
  entry file of a `check`; scanning each edited module with its own `medaka
  check` found seven `Ty` walkers still missing a `TyAuth` arm that the
  whole-closure check had not surfaced.
- The engine gate's eval and wasm arms are ORACLES: a fixture using new syntax
  reads as "eval printed nothing" and "wasm emitter: unexpected `(`" until
  `build_oracles.sh --for 'diff_compiler_engines*'` has run on the new source.

## Close-out session (2026-09-25/26)

Branch `effects-closeout` from `ea782db98` (the merge of PR #3445). What
landed is itemised in [Effects architecture](../../compiler/EFFECTS-ARCHITECTURE.md)
§ "Close-out checkpoint"; the normative changes are in
[Effects semantics](../spec/EFFECTS-SEMANTICS.md) §4.1 and §6.1 and in
`docs/spec/SYNTAX.md`; the codes are in `compiler/DIAGNOSTIC-CODES-DESIGN.md`.

**The owed list, each answered by a general rule:**

- *A span on `TyQual`.* `TyQual Ty (List String) (Option Loc)`: the qualifier
  carries its span from the `@`, and every diagnostic about a name it writes
  (resolve's `R-UNBOUND-AUTHORITY`, the typechecker's `T-AUTHORITY-KIND` and
  `T-AUTHORITY-DOMAIN`) is located there. `authorityNamesWritten` returns each
  name with the span of the atom or qualifier that wrote it.
- *The `ELoc` restore.* `infer`'s and `inferExpected`'s `ELoc` arms set the
  node's own span again on the way out, so a check that runs after a
  subexpression reads that subexpression's span, not its last leaf.
  The forecast that this would move pinned locations across the JSON and LSP
  corpora did not hold: one golden moved,
  `test/check_json_fixtures/projects/imported_help_fix`. Its diagnostic had
  pointed at the digit `3`, the last leaf of `(Box { width = 2, height = 3
  }).widht`, and its fix-it range, computed from that span, covered `}).wi`,
  so applying the fix would have corrupted the source. It now spans the
  receiver. No LSP golden moved. The locations of five typecheck-error
  fixtures moved too (their goldens pin messages, not spans); the notable
  one is a `match` whose arm disagrees with the declared result, which now
  reports at the `match` (the whole node) where it reported the LAST arm's
  leaf, right only when the offending arm was the last.
- *`@(a | b)`.* Spellable. The qualifier's names are a list and elaborate to
  their join (`qualifyByAll`); the renderer already printed the join this way,
  so the round trip now closes. A joined field carries neither name alone
  (`tyCarries`), and a join across domains is `T-AUTHORITY-DOMAIN`.
- *An unlocated `effect` declaration.* `DEffect` carries the label's span;
  `checkDomainAxes` reports there. The same class of defect, a declaration-level
  name with no span, also covered the label in `(p : Authority L)`:
  `KindAuthority` carries its span, and resolve's unknown-label report uses it.
- *Index mismatch wording.* An authority index equality is recorded as two
  exact halves (`wantAuthorityWith True`, `AuthWanted.awExact`, carried to
  `esfExact`); a failure reads `T-AUTHORITY-INDEX-MISMATCH`, "Authority index
  mismatch: X vs Y …", once for both halves. It was two row-bound reports.
- *The two unreproduced S3s.* The policy's `Method=true` decode reproduced: a
  `--allow` entry was decoded by a schema-blind parser, so `Method=true` and
  `Method=GET` were prefix strings on a Set axis, and a bare
  `Net=idp.example.com/*` on a Product label never lifted into its first axis
  (an admissible plugin was refused). Fixed by one rule for both consumers: the
  shape check is a pure function (`effectParamProblems`), the typechecker reports
  its problems at the atom, and `check-policy` keeps each entry written and
  decodes it against the domain of the label it is compared with
  (`decodeWrittenParam`), refusing a malformed entry with the problem rather
  than reading it as the whole domain. The unused round-trip renderer
  (`manifestToAllowStr`) spelled a top axis `=true`; it now omits it. Naming an
  existential cell after the field that carries it did NOT reproduce: every
  site renders the binder's name (`AnyH h`, `AnyR { hd = zz, n }`,
  `AnyR { hd = h2, ... }` in a match arm, an escape, a record pattern, a
  mismatch inside the arm; all say `p`/`q`, never `h`, `hd`, `zz`, `h2`).
  Retired.

**Found while closing, each reproduced first and fixed as a rule:**

- A qualifier naming a named argument that no atom or index names was
  silently dropped: `idQ : (a : String) -> String @a` published `String` and a
  caller's `readFile (idQ a)` reached the whole domain. An authority has
  exactly one domain, so zero is `T-AUTHORITY-DOMAIN` at the qualifier.
- `Authority L` over an atomic label (`Beep`, `IO`) was accepted as a slot
  every index trivially fills; it is `T-AUTHORITY-KIND` at the label.
- An opened existential was described as "an authority the caller chooses";
  `openedAuthvarsRef` records the cells a pattern opened and the failure says
  what they are.
- #3304 had a second half: the label's NAME crossed a member-list hop once
  `nsEffects` carried it, but its declaring identity did not
  (`typeOriginExports` carried `effect:` origin rows for wildcard hops only),
  so `<Logging>` from the facade and `<Logging>` from `doLog` were two labels
  (`T-EFFECT-LEAK`). `reexportedEffectOrigins` applies the same binding rule.

**The whole-diff review (on `1c431448e`), reproduced first and answered:**

- *S1: `fmt --write` wrote unparseable source* for a qualified application
  head (`(Result String @a) E` printed bare). The bare form is now only for
  the type a row wraps (`printRowResult`).
- *S1/S2: a joined field could not be built with inferred indices*
  (`Two "cfg/x"` at `@(p | q)` failed, "the caller chooses"). An upper bound
  that is a join with flexible members raises every one of them unless its
  fixed members cover the lower bound (`raisedBy`); semantics §4.1 states it.
- *S0, older than this branch: an empty bare literal on a Product label meant
  the whole domain*, in source (`<Web "">`) and in a policy (`Web=`). The
  literal is checked as the first axis's value before the lift canonicalises
  it.
- *S0-class, older: the field fix-it's range was the SUGGESTION's length*, so
  `(b.heigh)` lost its `)`. It is now the written name's length. The field
  name has no span of its own, so a receiver separated from its `.` by
  whitespace (`b .widht`) still mislocates the fix: owed, with the reason.
- *S2: a qualifier naming a non-String argument* (`@(a | n)`, `@n` with `n :
  Int`) was dropped silently; it is `T-AUTHORITY-BINDER` at the qualifier.
- *S3:* quoted set members in a policy never matched; they are unquoted.
  `@(p | p)` now carries `p`. SYNTAX.md said "one label's domain" where the
  rule is one domain shape.
- *Not acted on, recorded as owed (older than this branch, S2):* an alias
  `type F = (a : String) -> String @a` erases the named authority silently; a
  named argument inside a higher-order domain (`((a : String) -> String @a)
  -> Int`) is reported as unbound (`namedArgTypes` walks the top spine only);
  a stacked `String @b @a` and a qualified non-String `Int @a` are accepted
  without a report. The `match` location above is a precision loss owed to
  checking arms against the expected result type.
- *A design question for Val, found while pinning the join rule:* the Prefix
  join is the longest common prefix saturating to ⊤ (semantics §2.2), so a
  WRITTEN bound of two literals of one label, `<FileRead "cfg/*", FileRead
  "tmp/*">`, is the whole domain: the signature publishes `<FileRead>` and a
  body reading `/etc/x` is accepted with no report (on `main` too). The same
  holds for `Two "cfg/*" "tmp/*"` over a `String @(p | q)` field. The manifest
  stays honest (it reports the top), but the written signature is widened
  silently. Candidate rules: report a written join that saturates, or give
  the Prefix domain finite unions; neither is taken here.

**Delivery item 7's prerequisites:**

- #3327 does not reproduce on `ea782db98`: `recordDeclKinds` (the data half)
  records every head's kinds before any field elaborates. Pinned in the matrix:
  both declaration orders accept, and a genuinely mis-kinded use is reported at
  its own declaration in either order.
- #3304 fixed as above; pinned by `test/import_form_fixtures/reexport_effect_label`
  (resolve: a member list naming the label, a wildcard, and a member list NOT
  naming it, which is refused) and a matrix row through
  `checkModulesDiagsChain` (typecheck: the identity arrives).

**Owed after the close-out session (proposals awaiting Val's ratification):**

*Delivery item 7, proposal (stdlib review first).* A survey of `stdlib/`
found one family that loses an authority through an opaque value: the `Net`
socket handles. Files, commands and environment variables are always passed
as strings, so they need no handle. The openers are already precise
(`connect : (host : String) -> Int -> <Net host> …`,
`listen : (addr : String) -> Int -> <Net addr> …`), but `Connection` and
`Listener` are `public export data … = … Int`, and every consumer is typed
with the bare `<Net>`. Proposed signature changes:

| Now | Proposed |
|---|---|
| `public export data Connection = Connection Int` | `export data Connection (h : Authority Net)` (abstract; see the open question) |
| `public export data Listener = Listener Int` | `export data Listener (a : Authority Net)` |
| `connect : (host : String) -> Int -> <Net host> Result String Connection` | `… Result String (Connection host)` |
| `listen : (addr : String) -> Int -> <Net addr> Result String Listener` | `… Result String (Listener addr)` |
| `send`/`recv`/`sendAll`/`recvAll`/`sendString`/`recvString`/`sendLine`/`recvLine`/`shutdown`/`close`/`setTimeout : Connection -> … <Net> …` | `Connection h -> … <Net h> …` |
| `listenPort`/`closeListener : Listener -> <Net> …` | `Listener a -> <Net a> …` |
| `accept : Listener -> <Net> Result String Connection` | `Listener a -> <Net a> Result String (Connection a)` (the accepted socket speaks under the listener's grant) |
| `serveLoop`, `withConnection`, `withListener` | index threaded through; the `with*` forms name their host argument |
| `net_async`: `connect`, `connectWithin : String -> Int -> Async <Net \| e> …` | `(host : String) -> Int -> Async <Net host \| e> (Result String (Connection host))`; every consumer `Connection h -> Async <Net h \| e> …` |
| `io.getEnvOr : String -> String -> <IO> String` | `(name : String) -> String -> <Env name> String` (a named argument, not a handle) |

The open question, which decides whether this needs a language addition: an
honest `send : Connection h -> … <Net h> …` must call a fd-level extern that
performs `<Net h>`, but the runtime externs take a raw `Int` and perform the
bare `<Net>`, and a `newtype` is boxed, so it cannot stand in for the `Int`
at the extern boundary. Three routes:

1. *(recommended)* An authority-indexed opaque FFI type, `NetFd (h : Authority
   Net)`, represented as the C `Int`, whose only proof sources are the opening
   externs (`netTcpConnect : (host : String) -> Int -> <Net host> Result String
   (NetFd host)`) and whose consumers are indexed (`netSend : NetFd h -> … <Net
   h> …`). This is §4.1's "explicitly trusted FFI operation". It needs a way to
   declare an opaque extern type with a kinded parameter, which is new surface.
2. The handle carries its host as evidence, `Connection (String @h) Int`, and
   every fd-level extern gains a host argument the C side ignores. No new
   surface, but it changes the C signatures, and the evidence is the host
   string, not the socket.
3. Defer: keep the consumers bare and index only the handle types, so a
   signature can at least say which host a handle came from.

`fs.mkdirAll`/`walkDir`/`replaceDurably` and `test_process.boundedVerb` could
name their arguments too, but `mkdirAll "a/b"` writes the prefix `a`, which is
outside `<FileWrite "a/b">`, so those stay bare unless the body proves it.

*Checklist item 2, scope proposal.* (a) Residual constraints in schemes: a
generalized binding carries its unsolved inequalities between its own
quantified authority variables (`C ⇒ τ`), instantiated with the scheme's one
substitution at each use and re-emitted as obligations in the user's scope;
anything mentioning a non-quantified variable is decided where it is today.
IN: inferred residuals (unsigned bindings), rendering them in hover/doc.
DEFER: a written surface for residuals in signatures (a signature would stay
less expressive than inference until it lands, which is itself a design
question). (b) Delayed joins: when branch alternatives have unknown shapes,
record a join constraint the solver resolves once the shapes are known,
instead of HM equality. IN: arrows and covariant data slots, the cases the
envelope already handles for known shapes. This is a completeness fix (it
rejects fewer honest programs); no known laundering depends on it.

*Checklist item 3, scope proposal.* One invocation summary in `types/`,
consumed by `check-policy` and `manifest`, replacing `monoEffects`' structural
walk. Given a scheme and the host's protocol (force the entry; call it with
N arguments; any function value it returns may be invoked), it returns the
forcing row joined with the latent rows the host can reach (positive
positions only, by declared variance), plus the atoms whose authority is
still symbolic, reported explicitly (manifest `= true` with an "unresolved"
note, policy "not proven"). IN: the two built-in protocols the verbs use
today. DEFER: a user-declared protocol syntax. Today's walk descends into
every data argument whatever its variance, so it counts a row in a callback
slot the host would supply, which over-rejects; the change narrows that
without admitting anything the host can run.

**Traps paid for in this session:**

- `medaka test` on a native gate file reads `$MEDAKA_ROOT` for the lint
  probe's stdlib index; run bare, eight `rule-stdlib-reimpl` rows read as
  failures. `medaka gate run` (and `run_gates.sh`) set it.
- A pristine `main` tree for pin discrimination needs `compiler/`, `stdlib/`,
  `runtime/`, the `main` binary AND its emitter beside it (`medaka test`
  builds natively); both binaries are in the build cache
  (`$MEDAKA_SCRATCH/medaka-build-cache`). A test program string the old parser
  cannot read panics the whole run, so drop that group to see the rest.
- `diff_compiler_fmt`'s typecheck-error rows grade `check_main`'s sorted
  output, so an intended wording change moves `*.tc.golden` files, which no
  capture script regenerates; regenerate from the oracle and read the diff.

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

## What remains after the merge

Updated by the close-out session: item 1 below is delivered (PR #3445), item 4
is answered by the close-out checkpoint, and items 2 and 3 have scope
proposals awaiting ratification in § "Close-out session". The original list:

1. Qualified data fields, constructor proof sources and existentials (#3385's
   data half). Named authorities on arrows, the underscore's retirement, label
   identity and the prefix-join canonical form are delivered.
2. General qualified directed residual constraints in schemes, plus fully
   delayed unknown-shape produced-value joins.
3. Shared invocation-protocol summaries for policy/manifest consumers rather
   than re-deriving semantics by structural traversal.
4. The review's S2/S3 leftovers and the manifest's bare-name label keys, listed
   under "Owed after this session".

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

Data-half head `783d966bf` (PR #3445, 2026-09-25, the carrying rework after the
second review round): the `pull_request` run 36207649443 completed green on
every job, as did run 36200182399 on the first-round head `04b66839b` — the eight gate shards each ran
their planned gates (the shard step and the timing upload both succeeded),
`compiler-soundness` ran the must-fail suite, the whole-source typecheck and
the emitter fixpoint, `soundness`, `wasm`, `inlang`, `seed-health`,
`ci-gen-drift`, `gate-balance`, `gate-budget` and `gate-cost` all succeeded.
Locally on the same head: strict closure clean, whole-source typecheck PASS,
C3a/C3b yes, matrix 28/28, 52 gates green (perf, Ir-scaling and llvm
included). A PR run is narrowed by the change→gate map; the merge queue runs the
whole suite.

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
