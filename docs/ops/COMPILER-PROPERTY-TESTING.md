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
| Custom generators | Argument-free nominal types can use an in-scope `Arbitrary` instance | Built-in types use structural draws. Applied types without a selected custom instance use structural draws; an unsupported selected instance reports a capability error. Check imported type identity and eligibility. |
| Custom shrinking | Eligible `Arbitrary.shrink` instances run in both engines; structural shrinking covers containers and ADTs | Keep the input domain valid under shrinking and preserve the original failing law. |
| Large structures and boundary values | Default primitive draws are small | Add deterministic sizes, extreme integers, Unicode and delimiter-bearing names explicitly. |
| Reproducible draws | `--seed` controls property draws and is forwarded to directory/multi-target child runs | Record the seed, case budget, source revision and selected engine. |
| Native algorithm laws | Property bodies compile in the selected engine | Run the same independent law under `--engines eval,native`. |
| Process, diagnostic, trap and compiler-output contracts | Native tests can spawn tools; engine gates already exist | Grade exits and outputs as well as the mathematical law. |
| Coverage of generated cases | No classification or coverage threshold API | Count required categories explicitly in a test corpus; do not infer coverage from a high draw count. |

The initial audit found that directory/multi-target invocations dropped
`--seed` at the child-process boundary ([#3854](https://github.com/MedakaLang/medaka/issues/3854)).
Its regression compares direct-file and directory reports at two seeds without
pinning an RNG draw, shrink result or case count. A test-infrastructure gap
blocks this campaign until its capability is built; do not preserve a workaround
in the algorithm suites.

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

## Semantics specifications as executable laws

Use the normative clauses, rather than a current implementation's conformance
table, to decide the expected result. A table can be stale; a failing law can
expose a defect in any engine, including the interpreter.

| Specification | Executable property families | Vehicle |
| --- | --- | --- |
| [EFFECTS-SEMANTICS](../spec/EFFECTS-SEMANTICS.md) §2.1–2.4, §6.8 | Finite authority models; antichain normal forms independent of input order; row join associativity/commutativity/idempotence/empty identity; independent callback tails and invariant indices. The initial siblings implement finite Prefix/Set/Product domains, atomic rows and shared tails. | Internal model props, then generated accepted/rejected programs. |
| [DICT-SEMANTICS](../spec/DICT-SEMANTICS.md) §6 C-laws, §8 I1–I4 | Same declaration reached along two import paths retains one identity; distinct same-spelled declarations stay distinct; admissible instance permutations preserve evidence; dictionaries retain binding identity across modules. Registry identity laws are a substrate check, not a whole-pipeline proof. | Registry models plus generated module graphs and engine differentials. |
| [SHADOW-SEMANTICS](../spec/SHADOW-SEMANTICS.md) §1 S1–S9 | Alpha-rename an unrelated binder; insert an unrelated declaration; vary import order where visibility remains unique; binding resolution must preserve the selected identity. | Generated binding graphs and scoped source transformations. |
| [LAYOUT-SEMANTICS](../spec/LAYOUT-SEMANTICS.md) §3–8, §12 | Insert transparent comments; vary permitted indentation and bracket nesting; compare emitted layout tokens against an independent transition model; generated token streams must remain parseable. | Lexer/parser model props and grammar-aware sources. |
| [HM-CORE-SEMANTICS](../spec/HM-CORE-SEMANTICS.md) §1 | Non-expansive forms generalize, expansive forms obey the value restriction; changing a binder name cannot change the restriction. Sections marked owed are not a finished specification to invent tests from. | Generated programs with explicit type/diagnostic expectations. |
| [EMITTER-SEMANTICS](../spec/EMITTER-SEMANTICS.md) R1–R5, V/N/T/M/D laws | Preserve specified values, outcomes and trap codes; constructor/symbol identity remains injective; numeric boundaries match the law; repeated emission is deterministic. | Native/eval/Wasm differential programs with independently calculated expectations. |
| [WASM-SEMANTICS](../spec/WASM-SEMANTICS.md) WP/WH laws | Physical representations refine the shared emitter contract; dependency ordering and host boundaries preserve values, outcomes and required capabilities. | Existing Wasm harness and generated bounded programs. |

For each dispatched law record the exact clause, input domain, independent
oracle, generation coverage and mutation control. Shared-state generators
construct valid aliasing topologies from descriptions; random recursive `Ref`
values are not a substitute for those topologies.

The `Makefile` test target reaches the support siblings explicitly. New
`compiler/types/*_test.mdk` siblings are reached by its existing directory
target. An exit code alone is insufficient evidence: read the named property
and executed test counts. A `--filter` run may legitimately exclude one phase.

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

The compiler's [ledger](../../compiler/medaka-test-pins.toml) retains the native
assertion-grading regression for [#3857](https://github.com/MedakaLang/medaka/issues/3857).
Its test still asserts the correct grading behavior; the pin records the
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
