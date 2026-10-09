# Compiler property testing

The compiler needs direct algorithm laws alongside its fixture and engine gates.
The approach is inspired by [Property Testing with Agent Swarms](https://recursion.wtf/posts/agents-and-property-tests/): specify independent models, generate interacting histories, calibrate the tests with deliberate mutations, and retain a fixed regression alongside each repair. Batch coherent coverage and infrastructure fixes in one PR; use separate issues and pins for larger unrelated defects.

## What the built-in runner can establish

`prop` declarations generate parameters, execute a Boolean law in each selected
engine, and shrink the first failure. The native engine compiles a probe once
per file. Both engines use the same generation and shrinking plan, and reports
name the engine that produced each result. A concrete exhaustive corpus can
establish a useful finite-domain guarantee alongside a property; a second
hand-written random runner is not a substitute for native property execution.
Backend output also requires the existing eval/native/Wasm differential infrastructure.

| Need | Current support | Campaign practice |
| --- | --- | --- |
| Lists, tuples, primitive operation descriptions | Structural generation | Generate scripts, then construct the structure inside the law. |
| Constrained graphs, balanced trees, shared mutable cells | Describe with primitive scripts or an eligible custom generator | Preserve validity by construction; compare against a simpler independent model. |
| Custom generators | Nominal carriers, including applied and generic carriers, can use an in-scope `Arbitrary` instance | Built-in types use structural draws. Resolve custom instances at the complete carrier type through ordinary typechecking, including `requires` obligations. Check imported type identity and reject only laws that depend on an unusable instance. |
| Custom shrinking | Eligible `Arbitrary.shrink` instances run in both engines; structural shrinking covers containers and ADTs | Keep the input domain valid under shrinking and preserve the original failing law. |
| Large structures and boundary values | Default primitive draws are small | Add deterministic sizes, extreme integers, Unicode and delimiter-bearing names explicitly. |
| Reproducible draws | `--seed` controls property draws and is forwarded to directory/multi-target child runs | Record the seed, case budget, source revision and selected engine. |
| Native algorithm laws | Property bodies compile in the selected engine | Run the same independent law under `--engines eval,native`. |
| Process, diagnostic, trap and compiler-output contracts | Native tests can spawn tools; engine gates already exist | Grade exits and outputs as well as the mathematical law. |
| Coverage of generated cases | No classification or coverage threshold API | Count required categories explicitly in a test corpus; do not infer coverage from a high draw count. |

The initial audit found that directory/multi-target invocations dropped
`--seed` at the child-process boundary ([#3854](https://github.com/MedakaLang/medaka/issues/3854)).
Its regression compares direct-file and directory reports at two seeds without
pinning an RNG draw or shrink result. It also checks the requested replay
metadata. A test-infrastructure gap
blocks this campaign until its capability is built; do not preserve a workaround
in the algorithm suites.

A type recursive through `List` or `Array` (`data Rose = Rose Int (List Rose)`)
generates lists whose length bound falls by one per level of constructor
depth, from 7 at depth 0 to 0 at depth 7, in both engines. A generated value is
therefore finite, and a Rose holds at most 1957 nodes. Lists that do not sit on
a cycle through a list keep the flat bound of 7. The decay applies to every
list-cyclic type, terminating or not, so a list-cyclic type draws different
values than it did before #3937 was fixed; types that are not list-cyclic,
which are the carriers the draw-order pins cover, draw exactly as before.

Custom evaluator helpers carry concrete type signatures and use the compiler's
ordinary dictionary elaboration. The runner does not reconstruct method-table
ordinals or dictionaries. Helper validation runs over the requested carriers
together; an unsatisfied prerequisite produces a capability result for its
dependent laws while independent laws still execute. Both engines preserve
abstract module boundaries when displaying counterexamples.

Evaluator properties and ordinary tests execute in the original module cells,
so global references remain identical to the references captured by functions.
Each property gets its requested seed and budget while mutations remain visible
to later cases and laws. Custom shrinkers also run inside structural containers,
tuples and nominal constructor fields. Constructor privacy is checked relative
to the owning module: abstract exports and newtypes can generate structurally
there, while importers need an eligible custom generator.

Generated probe bindings and import aliases carry a per-probe nonce drawn from
OS entropy, with occupied source namespaces excluded before rendering. Generated
core calls and runtime primitive calls use canonical module aliases, so a valid
user declaration named `map`, `debug` or `randomState` keeps its own meaning
without capturing runner machinery. The evaluator likewise selects runtime RNG
bindings from a preserved primitive frame, separately from method dispatch cells.
Native scratch projects declare a nonce-qualified dependency on the installed
stdlib runtime catalog, so a target's sibling `runtime.mdk` retains its own
meaning while probe primitives resolve to the runtime. An existing dependency
with the generated name produces a build error rather than being replaced.
User bodies, labels and field names
are preserved rather than rewritten after rendering.

Reports retain the exact requested integer seed, including negative and wide
seeds. Normalizing a structural generator's internal state does not normalize
its replay metadata.
Human failure and known-red property rows print the seed and requested case
budget so the reported witness can be replayed with the same CLI options.

Passing laws in both engines do not establish that they received the same
inputs. Runner regressions must also compare seeded draw witnesses and final
shrunk counterexamples, with expected values derived independently. Include
negative and wide seeds and nested structural values. A shrinker that exhausts
its fuel must report that its counterexample may not be minimal in either
engine.

Evaluator properties run in one supervised process per target, sharing their
original module cells within that process. A panic in a body, generator or
shrinker produces runtime-error rows with the requested replay metadata, and
the other selected engine still runs. An aborted evaluator batch reports all
of its selected laws as runtime errors; it does not claim a partial pass. The
parent accepts only a complete transcript matching its requested law names,
engines, seeds and case budgets.
The worker uses the compiler associated with the caller's concrete prelude
path, including when the testing library is called by a standalone entry.

## Initial algorithm coverage

The first added siblings keep test-only models out of compiler source
fingerprints. Their slow list/reference algorithms are intentionally suitable
only for bounded tests; production code must still follow
[the compiler performance rules](../../compiler/AGENTS.md).

| Subject | Test destination | Independent contract |
| --- | --- | --- |
| String-keyed ordered maps | [ordmap_test.mdk](../../compiler/support/ordmap_test.mdk) | Every operation prefix agrees with a list model; overwrite/delete locality; persistent old versions; cached sizes/order/balance; pair construction bias; value mapping; set membership. |
| Dead-code elimination | [dce_test.mdk](../../compiler/ir/dce_test.mdk) | Reachable plain functions match an independent graph closure; roots and non-emitting declarations follow the DCE contract; exhaustive three-node graphs and disconnected cycles. |
| SCC decomposition | [scc_test.mdk](../../compiler/support/scc_test.mdk) | Components are exactly mutual-reachability classes; every vertex occurs once; dependency order; permutation/duplicate-edge invariance; independent calls reset scratch state. |
| Shared utility algorithms | [util_test.mdk](../../compiler/support/util_test.mdk) | Stable first-representative dedup; composite-key injectivity; edit distance versus minimum edit scripts and metric laws; text roundtrip; memo-prefix model; decimal boundaries. |
| Identity registries and lexical scopes | Existing `compiler/types` siblings | Scripted independent models and identity/visibility laws; retain specific unit regressions. |
| Atomic effect rows and shared row DAGs | [effect_rows_property_test.mdk](../../compiler/types/effect_rows_property_test.mdk) | Finite-map normalization; grade-join algebra; independent unsolved tails; effects survive later solving after a warm normalization. |
| Concrete authority domains | [effect_domain_property_test.mdk](../../compiler/types/effect_domain_property_test.mdk) | Prefix/Set/Product inclusion and least upper bounds against finite models; antichain admission preservation; constant-authority order; empty Set boundaries. |
| The value restriction (HM-CORE §1, DICT §4.1 G2) | [hm_value_restriction_property_test.mdk](../../compiler/types/hm_value_restriction_property_test.mdk) | Generated bindings generalize iff a transcribed value grammar says so, at top level, at a local `let`, in a binding group and under a signature; partial application; `T-SIG-OVER-EXPANSIVE`; binder-rename invariance. |
| Invariance of verdicts and schemes (SHADOW S1-S9, DICT T1/U1/U2/C4, history independence) | [check_invariance_property_test.mdk](../../compiler/types/check_invariance_property_test.mdk) | Shadow-clause verdict model under renaming, unrelated insertion and import/provider reordering; declaration permutation; flat route versus one-module route; two-module split; a check of `P` after any `Q` equals `P` first. |
| Damas-Milner core (HM-CORE §2-5, #2555) | [hm_core_property_test.mdk](../../compiler/types/hm_core_property_test.mdk) | Principality by re-annotation; instantiation and non-instances; occurs check; operand-order symmetry against a Robinson unification model; lambda- versus let-bound polymorphism; group monomorphism and polymorphic recursion under signatures. |
| Dictionary resolution (DICT §3, §6 C1/C3, §6.3, §8 I5/I6.1) | [dict_property_test.mdk](../../compiler/types/dict_property_test.mdk) | Most-specific selection against a matching and specificity model, invariant under instance permutation; improvement and determination against a unification model; the defaulting settle sequence and its channels; graph-global candidacy; head-variable spelling. |
| Dictionary declarations (DICT §3 W1/W3, §4 `gen-sig`, §5.1, §8 I1-I4/I6.2/I7) | [dict_declaration_property_test.mdk](../../compiler/types/dict_declaration_property_test.mdk) | Superclass cycles against a reachability model; impl bodies against a binder-keyed rigid-variable model; impl completeness and extraneous members; signature contexts as contracts; identity along two import paths and of same-spelled declarations; the literal's class. |

The utility deduplication model exposed a native code-generation defect:
a lifted patterned lambda inherited its enclosing function's tail-recursion
destination and emitted a branch to an undefined label. A definition scope now
saves, clears and restores that context. The fixed
[engine fixture](../../test/engine_fixtures/trmc_patterned_lambda_scope.mdk)
has an independently chosen `True` value pin and agrees across eval, native and
Wasm.

## Semantics specifications as executable laws

Use the normative clauses, rather than a current implementation's conformance
table, to decide the expected result. A table can be stale; a failing law can
expose a defect in any engine, including the interpreter.

| Specification | Executable property families | Vehicle |
| --- | --- | --- |
| [EFFECTS-SEMANTICS](../spec/EFFECTS-SEMANTICS.md) §2.1–2.4, §6.8 | Finite authority models; antichain normal forms independent of input order; row join associativity/commutativity/idempotence/empty identity; independent callback tails and invariant indices. The initial siblings implement finite Prefix/Set/Product domains, atomic rows and shared tails. | Internal model props, then generated accepted/rejected programs. |
| [DICT-SEMANTICS](../spec/DICT-SEMANTICS.md) §3, §4, §5.1, §6, §6.3, §8 | Same declaration reached along two import paths retains one identity; distinct same-spelled declarations stay distinct; instance permutations preserve verdicts and schemes; selection, improvement, determination and defaulting follow the clause models. Which dictionary a goal selects is evidence identity, which verdicts and schemes do not show. | Generated programs and module graphs with clause models (see § "Typechecker law inventory"). |
| [SHADOW-SEMANTICS](../spec/SHADOW-SEMANTICS.md) §1 S1–S9 | Alpha-rename an unrelated binder; insert an unrelated declaration; vary import order where visibility remains unique; binding resolution must preserve the selected identity. | Generated binding graphs and scoped source transformations. |
| [LAYOUT-SEMANTICS](../spec/LAYOUT-SEMANTICS.md) §3–8, §12 | Insert transparent comments; vary permitted indentation and bracket nesting; compare emitted layout tokens against an independent transition model; generated token streams must remain parseable. | Lexer/parser model props and grammar-aware sources. |
| [HM-CORE-SEMANTICS](../spec/HM-CORE-SEMANTICS.md) §1–5 | Non-expansive forms generalize, expansive forms obey the value restriction; changing a binder name cannot change the restriction. The owed §2–5 are covered by textbook Damas-Milner laws written law-first under #2555, not by invented prose. | Generated programs with explicit type/diagnostic expectations. |
| [EMITTER-SEMANTICS](../spec/EMITTER-SEMANTICS.md) R1–R5, V/N/T/M/D laws | Preserve specified values, outcomes and trap codes; constructor/symbol identity remains injective; numeric boundaries match the law; repeated emission is deterministic. | Native/eval/Wasm differential programs with independently calculated expectations. |
| [WASM-SEMANTICS](../spec/WASM-SEMANTICS.md) WP/WH laws | Physical representations refine the shared emitter contract; dependency ordering and host boundaries preserve values, outcomes and required capabilities. | Existing Wasm harness and generated bounded programs. |

For each dispatched law record the exact clause, input domain, independent
oracle, generation coverage and mutation control. Shared-state generators
construct valid aliasing topologies from descriptions; random recursive `Ref`
values are not a substitute for those topologies.

### Typechecker law inventory

Typechecker laws check generated programs through the exported checker entry
points only, using the shared harness
[law_harness_test.mdk](../../compiler/types/law_harness_test.mdk): a law-owned
mini prelude, shape descriptions with source and type renderers, flat and
module-route verdict wrappers, a use-at-two-types generalization observer and an
`alphaEquiv` canonical-renaming model. A rendered scheme does not show whether a
binding generalized, so generalization is observed by use at two incompatible
types. Each row's disposition is a prop, a pin against an issue, or not
black-box-observable. Two rows record what the spec leaves open instead: an
interpretation the laws adopt pending a ruling, and a question no law
asserts. A cell marked "issue and pin pending" is red at the base and has no
issue yet; it is not asserted until it has a pin.

| Clause | Disposition | Oracle |
| --- | --- | --- |
| HM-CORE §1 gen-value, top level | pin #3949 (eval and native) on prop `a top-level binding generalizes iff its expression is a syntactic value` (flat and module routes); passing prop `a literal-free top-level binding generalizes iff its expression is a syntactic value` | G2 value grammar transcribed as `isSyntacticValue`; the shape's type from the harness typing model |
| HM-CORE §1 clause 1, binding groups | pin #3949 (eval and native) on prop `membership in a binding group grants no generalization exemption`; passing prop `a literal-free binding group member gets no generalization exemption` | Same grammar, applied to a member of a two-member group |
| HM-CORE §1 clause 2, signatures | pin #3949 (eval and native) on prop `a type signature grants no generalization exemption`; passing prop `a type signature grants a literal-free binding no generalization exemption` | Same grammar under the shape's principal signature |
| HM-CORE §1 clause 3, partial application | prop `a partial application is expansive and its eta-expansion is a value` | Clause 3 text; a clause with a parameter is a lambda |
| HM-CORE §1 clause 4, `T-SIG-OVER-EXPANSIVE` | pin #3949 (eval and native) on prop `a polymorphic signature over an expansive body is T-SIG-OVER-EXPANSIVE`; passing prop `a polymorphic signature over an expansive literal-free body is T-SIG-OVER-EXPANSIVE`; test `a variable under a constrained signature is a value` | Clause 4 text: a definition-site error, never a narrowing to the first use |
| HM-CORE §1, decision by syntax | prop `renaming binders preserves the value restriction's verdict` | Alpha-equivalent programs have the same verdict and codes |
| DICT §4.1 G2, local binder | pin #3949 (eval and native) on prop `a local let generalizes iff its expression is a syntactic value`; passing prop `a literal-free local let generalizes iff its expression is a syntactic value` | G2 value grammar, at a block `let` |
| HM-CORE §1 clause 3 versus G2, partial constructor application (`Pair s`) | interpretation, awaiting Val's ruling: the laws count it a value, reading G2's "an application of a data constructor … all parts values"; clause 3's "partial application is expansive … even when its head is a function of greater arity" reads the other way, and the spec does not say which governs a constructor | n/a |
| HM-CORE §1, a bare unapplied `Ref` | open spec question, not generated: whether the bare mutable-cell constructor is a value is undecided, so the shapes only apply `Ref` | n/a |

The HM-CORE §1 and G2 rows live in
[hm_value_restriction_property_test.mdk](../../compiler/types/hm_value_restriction_property_test.mdk).
A pin matches a law by name only, so a pinned law cannot report a second
regression in its clause. Each law pinned to #3949 therefore has a live twin
over the same shapes with every integer literal replaced by a string literal
(`literalFree`), which #3949 cannot reach and which keeps values and
non-values alike.

| Clause | Disposition | Oracle |
| --- | --- | --- |
| SHADOW S1, S2 (shadow-hood; definer inversion) | prop `a shadow program's verdict follows the clauses and survives the transformations` | S2 text: a definer shadow applied to a receiver denotes the standalone, so only a receiver in the standalone's domain is accepted; importer shadow dispatches at a live-impl head |
| SHADOW S3 (N-way) | same prop, `UApplyLive`/`UApplyTag` | S3 text: a receiver at a live-impl head is a located reject |
| SHADOW S4 (value position) | same prop, `UValueDomain`/`UValueLive` | S4 text: a value-position shadow is the standalone, for definer and importer |
| SHADOW S5 (ungrounded receiver) and carve-out | same prop, `UWrapDomain`/`UWrapLive`/`UCarveOut` | S5 text: the wrapper monomorphises to the standalone's domain unless the receiver is a written `=>` variable |
| SHADOW S6 (module independence), importer half | same prop, `Importer` topology with `Swapped` order, and `DefinerImported` | S6 text: where the interface or impl live and the order of imports cannot change an outcome where visibility stays unique |
| SHADOW S6 (module independence), interface location | same prop, `ImporterUnnamed` topology | S6 text (narrowed 2026-08-07) and S1-NS (a): an importer that imports the interface's module admitting neither the interface nor the method is not a shadow, so every use is the imported standalone |
| SHADOW S8 (arity) | same prop, `A1`/`A2` | S8 text: parameter count of the method changes no rule |
| SHADOW S9 (constrained standalone) | same prop, `UConstrDomain`/`UConstrLive` | S9 text: an ordinary constrained call; a type lacking the standalone's own constraint is rejected, not dispatched |
| SHADOW S1-S9 under binder renaming and unrelated insertion | same prop, `XRename`/`XInsertFront`/`XInsertBack` | Alpha-equivalent or extended programs have the same codes and alpha-equivalent schemes (harness `alphaEquiv`) |
| SHADOW S7 (path agreement) | not black-box-observable: it compares `run`, `check` and `build`, and these laws observe only the checker entry points; graded by `test/diff_compiler_shadow_semantics_test.mdk` | n/a |
| DICT T1 (declaration order) | prop `permuting the top-level declarations preserves verdict and schemes` | Block model (only the bad block rejects) plus same-names, alpha-equivalent-schemes comparison |
| DICT U1/U2 (flat versus module route) | prop `the flat route and the one-module route agree` | Equal diagnostic lists; block model verdict |
| DICT C4 (module split) | prop `splitting a dependency-closed program across two modules preserves the verdict` | Block model verdict on a program with and without the split |
| History independence (F13) | prop `checking P after any Q equals checking P first` | The answer for `P` before and after an unrelated `Q` agrees with itself and with the model; not a claim about F12 |

The invariance rows live in
[check_invariance_property_test.mdk](../../compiler/types/check_invariance_property_test.mdk).
Its self-test hand-builds a changed scheme, a changed verdict and a lost
binding and requires the comparison to reject each; its censuses assert both
verdicts and every transformation over the enumerated domains.

| Clause | Disposition | Oracle |
| --- | --- | --- |
| HM-CORE §2/§4 principality (#2555) | prop `re-annotating a binding with its inferred scheme is accepted and re-infers it` | Damas-Milner principal type: the inferred scheme equals the harness typing model's type up to renaming (`alphaEquiv`), and annotating with it re-infers it |
| HM-CORE §2/§4 with an integer literal (#2555) | prop `a binding containing an integer literal is principal and generalizes`; pin #3949 (eval and native) | Same rules; a literal is a syntactic value (HM-CORE §1) |
| HM-CORE §3 symmetry (#2555) | prop `swapping the operands of an equation-forcing construct keeps its verdict` | Robinson unification model over generated types: each operand order's verdict is whether a unifier exists |
| HM-CORE §3 occurs check (#2555) | prop `an equation between a type and a proper part of itself is rejected` | `α = C[α]` with non-empty `C`, or self-application, has no unifier in the model; a `let` alias of a lambda-bound variable quantifies nothing |
| HM-CORE §4 instantiation (#2555) | prop `a generalized binding is usable at two distinct instances and at no non-instance` | Instances are substitutions of the scheme's variables; a repeated variable sent to two types is no instance |
| HM-CORE §4 lambda versus let (#2555) | prop `a lambda-bound variable is monomorphic and its let-bound twin is polymorphic` | A lambda parameter is a monotype; the let twin is a scheme |
| HM-CORE §5 group monomorphism (#2555) | prop `a binding group is monomorphic inside the group and generalized after it` | `letrec`: members are monotypes inside the group, generalized at its exit |
| HM-CORE §5 polymorphic recursion (#2555) | prop `a signature admits polymorphic recursion` | Unsigned recursion at `C[α]` is an occurs failure in the model; a signed member is instantiated afresh (Mycroft) |
| HM-CORE §5 signatures and dependency (#2555) | pin #3955 (eval and native) on prop `every member of a group with a signed member generalizes at its principal type` | Haskell 2010 §4.5.2: a reference to a signed member adds no dependency, so the unsigned member keeps its principal type. HM-CORE §5 has not decided this boundary |

The HM-core rows live in
[hm_core_property_test.mdk](../../compiler/types/hm_core_property_test.mdk).
They assert none of #2555's recorded deviations: no predicate context, rows or
authority appear in the fragment. Its self-tests hand-build a wrong case for
each law family and require the comparison or the checker to reject it; its
censuses count each verdict class over enumerated type, wrap and shape domains.

| Clause | Disposition | Oracle |
| --- | --- | --- |
| DICT §3 specificity, `min⊑` and `inst`; §6 C1 | prop `instance selection follows the most-specific model and survives permuting the instances` | Matching and specificity model: an empty matching set is the missing-instance rejection `T-NO-IMPL` with no ambiguity code; one `⊑`-minimal head is accepted; two or more are `T-AMBIGUOUS-INSTANCE` |
| DICT §6 C3, §3 resolution determinism | same prop, permuted instance declarations | The same sorted codes and alpha-equivalent schemes before and after the permutation |
| DICT §6 C1, α-equal duplicate heads | prop `a twice-declared head that is minimal at the goal is rejected and not as missing`. The other half, a duplicate that no goal reaches as a minimum, is red at the base: the checker rejects the declaration pair as `T-CONFLICTING-IMPL` whatever the goal; issue and pin pending | §3: α-equal heads are `⊑`-equivalent and never tie-break, so a goal at which the duplicate is minimal has two minimal instances; §6.1 choice point 2 (c) decides acceptance per goal |
| DICT §3 `assum` | prop `a signature's context is a contract the body is checked against and every caller discharges` | A declared `Sz a` discharges `sz x` at a rigid `a` no instance matches; that the evidence is received rather than rebuilt is evidence identity |
| DICT §3 `super` | same prop | A declared `Tg a` entails `sz x` through `Tg requires Sz` |
| DICT §3 precedence (`assum` before `inst`) | not black-box-observable: where both rules apply the verdict is the same and only the evidence differs | n/a |
| DICT §3 improvement by the one matching instance | prop `a repeated head variable improves its goal jointly and a second unifying head blocks the commit` | Robinson unification of the goal with each head, apart; a repeated head variable binds its positions jointly; uniqueness counts unifying heads |
| DICT §3 determination by the one unifying instance, and its Reject paragraph | prop `an open goal is determined by its one unifying instance and rejected otherwise` | One unifying head commits; none is `T-NO-IMPL`; two or more without a stable minimum are `T-AMBIGUOUS-INSTANCE` (ruling 2026-10-08) |
| DICT §3 determination, the peeled-qualifier exception | not black-box-observable here: a peeled qualifier is an effect-qualified head (`<Stdout> Int`), an effect-row form outside this campaign; EFFECTS-SEMANTICS successor sprint | n/a |
| DICT §3 signature variables in every matcher | not black-box-observable: the spec gives two readings, W3-inst's (a goal whose arguments are all type variables is never reduced by an instance) and the matcher paragraph's (a blanket instance binds its variable to a signature variable); question for Val: is `f : a -> Int; f y = q y` with only `impl Q a` accepted? | n/a |
| DICT §3 W1 | prop `a superclass cycle is rejected and an acyclic superclass relation is accepted` | Reachability over generated `requires` edges; a cycle is `T-CYCLIC-SUPERINTERFACE` |
| DICT §3 W2 | not black-box-observable: the clause states a decidability precondition and fixes no verdict or site for an instance that violates it | n/a |
| DICT §3 W3 (type axis, and the effect axis of a method row) and W3-inst pinning | prop `an impl body inhabits its method's scheme with the method and head variables rigid` | Rigid variables keyed by binder, so a head `b` and a method `b` differ; a fresh body type fits; performing `KV` on the caller's row does not |
| DICT §3 W3-inst undeclared prerequisites | not black-box-observable: the same two readings as the signature-variable row, and the same question for Val | n/a |
| DICT §3 W3 graded interfaces (#1094, #1095, both closed) | not black-box-observable here: effect-kinded unification, EFFECTS-SEMANTICS successor sprint | n/a |
| DICT §4 `gen-sig` | prop `a signature's context is a contract the body is checked against and every caller discharges` | The scheme's context is exactly the declared one; an unentailed body predicate is `T-MISSING-CONSTRAINT`; a declared, unused predicate is still the caller's |
| DICT §5.1 M1, M2 | prop `an impl is accepted iff it is complete and has no extraneous method` | Every method without a default has a body (`T-INCOMPLETE-IMPL`); no body under another name (`R-METHOD-NOT-IN-INTERFACE`, from `frontend.resolve.resolveProgram`) |
| DICT §5.1 M3 | prop `a phantom method is legal at its declaration and only an undetermined use is rejected`; pin #1134 (eval and native) | A use under a given is discharged by `assum`; a bare use is undetermined |
| DICT §6.3 D1, D2 | prop `a defaulted literal's other predicates are still checked, after determination` | Determination over every open goal with joint consistency, then `?a := Int`, then every predicate checked as written |
| DICT §6.3 D3, D4 | prop `a literal is defaulted exactly when no surviving channel can determine it` | An argument, a connected variable and a declared dictionary are channels; an inferred result and a local `let` are not; the enclosing binder's variable is its own |
| DICT §8 I1, I2, I3, I4; I6.2 (a) | prop `a declaration keeps one identity along two import paths and same-spelled declarations stay distinct` | Re-exported and direct imports of one type, interface or binding agree; two modules' `T`, `Sh` or `f` stay distinct; a tuple type written in two modules is one type |
| DICT §8 I5 | prop `instance candidacy ranges over every module of the graph` | The C1 model over the impls of an imported module and of one the entry never imports, before or after it |
| DICT §8 I6.1 | prop `an instance-head variable is a variable under every spelling` | The C1 model, which knows no spellings, under respelled head variables including the reserved `__none__` |
| DICT §8 I6.2 (b) | not black-box-observable: whether source text can forge the reserved builtin origin is decided where the parser builds heads, and generated programs only reach the checker through that parser | n/a |
| DICT §8 I6.3 | not black-box-observable: an empty module id is an internal origin no source program or module graph can name | n/a |
| DICT §8 I7 (literals) | pin #3956 (eval and native) on prop `a numeric literal demands the prelude's Num whatever binding is spelled fromInt` | The literal's class is the prelude's `Num`, whose only instance is at `Int` |
| DICT §8 I7 (operators), qualification 2 | prop `an operator demands the prelude's class and no program class of that spelling` | `==`, `<`, `++` and `+` demand the prelude's `Eq`, `Ord`, `Semigroup` and `Num`, each with its one instance at `Int`; a program class of the same spelling, with any instances, changes nothing |
| DICT §8 I7 qualification 4 | prop `with no prelude class an operator imposes no class constraint`. The cell with a program class of the operator's spelling and no prelude class is red at the base: that program class gates the operator (`interface Eq a where userOp : a -> Int` then `probe = 1 == 1` is `T-NO-IMPL` on both routes); issue and pin pending | Qualification 4: absent the prelude's class the predicate is not synthesized, and the gate is never "some interface of that name exists" |

The dictionary rows live in
[dict_property_test.mdk](../../compiler/types/dict_property_test.mdk) and
[dict_declaration_property_test.mdk](../../compiler/types/dict_declaration_property_test.mdk),
split so that each file's evaluator run stays well inside the 600-second
foreground ceiling. Their self-tests hand-build a wrong case for each model
and check one fixed program per family; their censuses count every verdict
class over enumerated description domains. Only a prelude declaration is a
built-in class, so the operator laws declare `Eq`, `Ord` and `Semigroup` in
the prelude position through the harness's `flatDiagnosticsWith`, in their
own text rather than the shared law prelude.
DICT §4.1 G2, §6 C4, T1 and U1/U2 are disposed of in the tables above.

The `Makefile` test target reaches the support siblings explicitly. New
`compiler/types/*_test.mdk` siblings are reached by its existing directory
target. An exit code alone is insufficient evidence: read the named property
and executed test counts. A `--filter` run may legitimately exclude one phase.
Other compiler siblings need an explicit `Makefile` test invocation. A stdlib
test module needs both a `suites` row and its matching `floorExpectation` test
in `test/stdlib_suite_test.mdk`; the required CI `inlang` job runs `make test`.

Run a file directly, with a recorded seed and case count:

```sh
./medaka check /absolute/path/compiler/support/ordmap_test.mdk
./medaka test --engines eval,native --cases 500 --seed 20261005 /absolute/path/compiler/support/ordmap_test.mdk
```

`medaka test --engines eval,native` runs each property and `test` block under
both requested engines.
Verify a new suite's ability to fail by temporarily breaking its subject,
observing a named failure, restoring the source, and checking freshness again.
Never commit the mutation or capture its result as a correct golden.

## Retaining known-red laws

Keep a broken law's assertion and independent oracle intact. The project-local
`medaka-test-pins.toml` ledger records its file, declaration kind, name, engine
and underlying issue. A property pin also fixes the seed and case budget that
witness the defect. A unit-test pin records the exact assertion detail.

The runner executes pinned tests and reports known-red outcomes separately.
A pin holds only for the declared failure kind: a law returning False cannot
be replaced by a generation error, compiler error, trap or malformed probe.
An unexpected pass, changed assertion failure or stale declaration name makes
the run fail. Filters select declarations; they do not turn missing ledger
names into a silent skip.

A ledger has a schema version and one row per engine. For example, a law whose
False result reproduces issue 123 would have a row like this (use the actual
issue number and existing project-relative source path):

```toml
version = 1

[[pin]]
file = "<existing project-relative source path>"
kind = "prop"
name = "join preserves authority"
engine = "native"
issue = 123
seed = 20261005
cases = 400
failure = "false"
```

For a `test` declaration, use `kind = "test"`, `failure = "assertion"`, and
replace `seed` and `cases` with `detail_lines`, an array containing the exact
assertion message lines. Unknown fields and duplicate selectors are
errors. A second engine needs its own row because its observed failure may be
different. An absent ledger means there are no pins; an unreadable or malformed
ledger fails the run.

A native unit test that exposes a known compiler abort can instead declare
`failure = "error"` with the exact error message in `detail_lines`. That explicit
error pin preserves the raw error and names its issue. Assertion pins and
False-law pins still reject every runtime error; a changed error or unexpected
pass drains an error pin loudly.

The compiler's [ledger](../../compiler/medaka-test-pins.toml) retains two native
assertion-grading regressions for [#3857](https://github.com/MedakaLang/medaka/issues/3857).
Both tests still assert the correct grading behavior; their pins record the
constructor-identity abort that currently prevents native execution.

Fixing a defect means removing its pin and passing the same law. Small,
clear compiler fixes may accompany their regressions; larger or uncertain
compiler defects get an issue and a pin. Defects in the property infrastructure
must be fixed during the campaign rather than deferred behind a workaround.

## Remaining inventory

This inventory identifies candidates; a row is not a claim of completed
property coverage. Re-derive source and CI reach before dispatching each slice.
Existing fixed tests remain useful, but do not substitute for generated laws.

| Family | Structures and algorithms | Next independent laws / input description |
| --- | --- | --- |
| Support | `path`, `manifest`, remaining `util` numeric/string helpers | Path component laws under the documented domain; manifest parser roundtrips; tagged-Int and wide-literal boundaries. |
| Type foundations | `registry`, `scopes`, `repr`, `route_key`, `evidence`, `superclass`, `solver_contract` | Registry/multiregistry/set/spelling populations against ordered list models; scope ancestry/visibility/copy; identity mint injectivity; substitution and alpha-renaming. |
| Inference and effects | Union-find in `typecheck`; `effect_rows`, `effect_domain`, `effect_authority`, `effect_solver`, `effect_infer`, `effect_bindings`, `effect_invocation`, `effect_values` | Construct shared-cell graphs from scripts; normalization idempotence; join algebra; inclusion versus a finite set model; substitution/renaming/permutation invariants; failed unification must not corrupt unrelated cells. |
| Frontend | `lexer`, `parser`, `desugar`, `exhaust`, `resolve`, `marker`, `parse_cache`, `desugar_cache` | Grammar-aware source/ASTs; location-normalized parse/print roundtrip; desugar evaluation equivalence; finite-constructor brute-force exhaustiveness; binding-preserving import permutations; cache-hit/miss equivalence. |
| IR and evaluation | `core_ir_lower`, `core_ir_sexp`, `core_ir_sexp_parse`, `core_ir_eval`, `dce`, `anf_identity`, `draft_semantic_program`, `eval` | Well-typed bounded expressions; serializer roundtrip; DCE closure against independent reachability; DCE/lowering semantic preservation; decision trees versus sequential pattern arms; interpreter driver agreement. |
| Backends | `private_mangle`, `trmc_analysis`, LLVM/Wasm emitter indexes and dispatch tables, `wasm_reach`, `wasm_file_grants` | Binding-preserving/injective mangling; independent free-variable sets; TRMC safety controls; indexed lookup versus original ordered tables; reachability closure; conservative capability propagation; differential emitted programs. |
| Driver and tools | `loader`, `diagnostics`, `build_cmd`, `printer`, `fmt`, `lint`, `lsp`, `refindex`, `gate_registry`, `gate_pack`, `gate_cost`, `snapshot`, `doctest`, `check_policy`, `prop_runner`, `test_cmd` | Dependency graphs; format idempotence/parse preservation; token encode/decode offsets; reference-index ancestry; gate packing conservation/determinism; normalization laws; random-runner replay and failure-report contracts. |

## Turning failures into fixes

1. State the correct result from semantics or an independent model before
   running the subject. Engine agreement alone cannot establish correctness.
2. Record the source revision, generator domain, seed, case count, minimized
   input, exact failing output and a nearby passing control.
3. Reproduce independently with a fresh binary and deduplicate against the
   tracker. A generator or harness defect gets its own report.
4. Add a named, fixed regression in the owning sibling or existing engine
   corpus. Retain the broader property that discovered it.
5. Keep each defect's tests and fix in a distinct commit. Batch coherent
   commits into one PR when runner capacity is limited. Run derived preflight,
   with full-suite work left to CI when the support-directory blast radius applies.

To locate existing declarations without relying on a frozen count:

```sh
rg -n '^prop ' compiler
rg -n '^test ' compiler
rg -n 'medaka test' Makefile
```
