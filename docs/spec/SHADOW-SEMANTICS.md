# Name Resolution Semantics (the lexical ladder)

**Status:** specification, ruled by Val 2026-11-04 (option A, the lexical ladder),
implemented by sprint `shadow-ladder-1` (#4890, shadow ladder sprint). Until that
sprint's `S-ladder` slice lands, the compiler still implements the older S1-S9 regime;
this document is the target and the compiler is audited against it. The earlier
2,469-line text (clauses S1-S9, the decision matrix, the per-stage table) is archived at
[`archive/design/SHADOW-SEMANTICS-S1-S9.md`](../../archive/design/SHADOW-SEMANTICS-S1-S9.md).

**Scope:** what one bare lowercase name `n` written in module `M` denotes, when several
declarations carry that spelling: a local binder, a top-level function, value or extern,
an interface method, an imported name, a prelude name. Constructor and type namespaces
are out of scope (they have their own scoped ladder and ambiguity error,
`R-AMBIGUOUS-CTOR`). `A.n` (dotted) is a qualified occurrence and is outside the ladder.

## 1. The ladder (clauses L1-L9)

- **L1 (one name, one declaration).** A bare lowercase name occurrence denotes exactly one
  declaration, chosen by the name and the scope it is written in. The receiver type, impls,
  constraints and the occurrence's syntactic position (applied, piped, sectioned, passed
  as a value) take no part in the choice.
- **L2 (the rungs).** Innermost first: (1) local binders (lambda and pattern variables,
  `let`, local `let rec`); (2) the module's own top-level declarations, including the
  methods of interfaces it declares; (3) explicit imports (`import m.{x}`, or
  `import m.{y as x}` binding `x`); (4) wildcard imports (`import m.*`: every exported
  value and every method of every exported interface); (5) the prelude. `import m.{I}`
  (an interface name) and `import m as A` bind no bare method name. Record fields are not
  bare bindings: `data W = W { size : Int }` defines no function `size`; `w.size` reads
  the field and the bare `size` is whatever the ladder says without the field. An own
  `extern`, an own top-level function and a local `let rec` each take their rung (an own
  `extern size` or `let rec size` beats an imported method `size`, measured in S-census
  F-Q1 on check, run and build).
- **L3 (ties).** The innermost rung that binds the name answers. Two distinct declarations
  at one rung 3-5 are a located ambiguity error at the occurrence; two at rung 2 are a
  duplicate-declaration error. In particular (F-R4) an interface method and a top-level
  function, value or extern of one name declared in one module is that duplicate error; it
  extends the existing rule for two interfaces declaring one method
  (`R-DUPLICATE-IFACE-METHOD`). One declaration reached by two paths (a re-export hub) is
  one binding, not two. A name never used is never ambiguous.
- **L4 (rung 3 against rung 2, F-R3).** An explicit import of a name the module also
  declares at top level is a located error at the import member. A wildcard import loses to
  the module's own declaration silently.
- **L5 (method or not).** A name bound to an interface method is a method occurrence and
  dispatches by type as dictionary passing always does. A name bound to anything else is an
  ordinary reference. Nothing after the ladder re-decides which. An unannotated recursive
  definer is covered: its own name inside its own group is rung 2, never the method.
- **L6 (generated names).** A name the desugarer generates (`slice`, `sliceInclusiveEnd`,
  `display` in interpolation, `andThen` and `pure` in `do`, `fromEntries` in map and set
  literals, `hash`, `derivedHashStep`, `derivedShowWrap`, `to_rep` in `deriving`) denotes
  the prelude declaration, whatever the module binds.
- **L7 (operators).** An operator denotes its prelude method; no bare binding changes it.
- **L8 (reaching a hidden method).** A method hidden by rungs 1-4 is reached through a
  module alias (`import core as C`, then `C.m`) or a member alias
  (`import core.{m as m2}`). There is no interface-qualified syntax, and no dict-var
  carve-out: a `=>` constraint on the receiver does not make the bare name mean the method.
- **L9 (engines agree; pin values).** `check`, `run` and `build` (and wasm) agree on every
  program. Agreement alone is not evidence: two engines can be wrong the same way for
  months, and a silent wrong value (S0 silent wrongness) exits 0 on every verb. Each
  fixture pins the expected value, derived from the clause, not captured from a binary.

## 2. Consequences of the ruling

- **F-R2.** The `=>` carve-out is gone. Inside a module that declares a function `n` beside
  an imported method `n`, a receiver typed by a constraint variable still calls the
  module's `n`. The method is reached by `C.n` or `import core.{n as n2}`.
- **F-R3.** `import m.{x}` plus a top-level `x` in the same module is the L4 error, located
  at the member `x`. `import m.*` plus the same top-level `x` is accepted and `x` is the
  module's own.
- **F-R4.** `interface I { size : a -> Int }` plus a top-level `size` in one module is the
  L3 duplicate error, located at the second declaration.
- **Warnings.** `W-PRELUDE-METHOD-SHADOW` stays and its statement stays true: an interface
  method declared in `M` beats the prelude standalone of the same name inside `M` (rung 2 over
  rung 5). `W-IMPORT-METHOD-SHADOW` and `T-AMBIGUOUS-SHADOW-DECL` are no longer emitted
  after `S-ladder`; the codes are deleted by shadow-ladder-2.
- **Own definitions keep their meaning.** A stdlib module that defines its own `length`
  beside the prelude's keeps meaning itself in its own module (rung 2 over rung 5); it
  never meets a live-impl receiver for the method inside that module.

## 3. Decision table (census classes)

Rows are the S-census classes (`census/census.tsv`, 225 rows at base `217afb473`: C1 41,
C2 1, C3 34, C4 55, C5 9, C6 48, C7 37, C8 0). Each moved program falls in exactly one.
Examples are `file:line` rows of that census.

| class | what moves | deciding clause | example |
|---|---|---|---|
| C1 | the importer arm picked the METHOD at a live-impl receiver; the ladder picks the import (silent where its type fits, else a located type error) | L2 rung 3 or 4 over rung 5, L1 | `parsec/lib/toml.mdk:42` (`orElse`; today `W-IMPORT-METHOD-SHADOW`) |
| C2 | the definer `=>` dict-var carve-out (or an unannotated recursive definer) dispatched the method; the ladder picks the module's own function | L2 rung 2, L5, L8 (F-R2) | `probes/p4/a.mdk:1` (#4714: today `E-PANIC intToString`, ladder `500`) |
| C3 | explicit import of a name the module also declares: new located error | L4 (F-R3) | `compiler/tools/lint_scope_test.mdk[inline-str]:120` (`expectEqual`) |
| C4 | interface method and function of one name in one module: new duplicate-declaration error | L3 (F-R4) | `compiler/types/effect_bindings_test.mdk[inline-str]:908` (`size`) |
| C5 | a desugar-generated name was captured by a user binding; it moves to the prelude | L6 | `probes/c5/display_derive.mdk:4` (today `T mine`, ladder `T 1`) |
| C6 | `import m.{I}` admission made a name a shadow; the ladder ignores the admission | L2 (an interface name binds no bare method) | `probes/p2/with_n.mdk:5` (today `2`, ladder `1`) |
| C7 | alias, re-export or multi-declaration cases decided the shadow | L3 (one declaration by two paths is one binding), L8 | `test/dict_fixtures/1386-alias-reproB-standalone-collision-rejected/control.mdk:8` |

A class C8 (a move no clause answers) means the clause list is incomplete; the census at
base found none. The one row that fits no instrumented site, `probes/p4/a.mdk`, is a
site gap, not a clause gap: L2 rung 2 and L5 answer `500`.

### Worked example: #4714 (P4, unannotated recursive definer)

```medaka
length n = if n == 0 then 0 else 1 + length (n - 1)
main = println (length 500)
```

The module declares `length` at rung 2 with no signature. Inside its own body the
occurrence `length (n - 1)` is rung 2 (L2), the function, so it is an ordinary reference
(L5); nothing re-decides it as the prelude method `length`. The program prints `500` on
check, run and build (L9). Today `run` panics (`E-PANIC intToString`) and the built binary
prints a heap address at exit 0. With a signature `length : Int -> Int` it already prints
`500`; the ladder removes the dependence on the signature.

## 4. Clause map from the S1-S9 regime

Existing citations of "SHADOW-SEMANTICS S2" and kin in `compiler/**`, `test/**` and
`docs/**` name the clauses of the archived text. They resolve as follows; sub-labels
(`S1-NS`, `S1-PRELUDE`, `S2-DECL`, ...) go with their parent clause. Row and cell numbers
(`row 26`, `cell d11`) index the archived matrix, which grades the old regime and is
replaced by the re-graded gate under `test/diff_compiler_shadow_semantics_test.mdk`.

- **S1 (shadow-hood) -> L2, L3, L4.** Which names were shadows. Now no notion of shadow:
  the rung table decides. `S1-SCOPE` and `S1-CHAIN` (nameable in `M`, re-export chains)
  become L2's import rungs reading the module's export surface; `S1-NS` (the per-method
  admission by `import m.{I}`) becomes L2's "an interface name binds no bare method"
  (class C6); `S1-PRELUDE` (a prelude standalone against a method, `W-PRELUDE-METHOD-SHADOW`)
  is rung 2 over rung 5, section 2.
- **S2 (applied) -> L1, L2, L5.** The inversion (a definer wins inside its module) is L2
  rung 2. The importer arm (a live impl picks the method) is deleted: L1 forbids the
  receiver taking part. `S2-DECL` (which declaration among several, import-order
  independence) is L3: one declaration per rung, ties are errors, order never decides.
  `S2-IMPORT-DIFFER` is class C1.
- **S3 (N-way) -> L3.** Several interfaces declaring one name: ambiguity at rungs 3-5,
  duplicate at rung 2.
- **S4 (value position) -> L1.** Position takes no part; an applied, piped, sectioned and
  value occurrence mean the same declaration.
- **S5 (ungrounded receiver) -> L1, L8.** The `=>` carve-out is removed (F-R2); the method
  is reached by `C.m` or a member alias.
- **S6 (module-independence) -> L2, L3.** The answer depends on the module's scope alone,
  not on the impls graph-wide.
- **S7 (path agreement) -> L9.** Kept in spirit, section 1: agreement between engines is
  not evidence; pin values.
- **S8 (arity and typaram arity) -> L1.** Arity and type-parameter count no longer gate a
  choice; they remain ordinary type errors where the chosen declaration does not fit.
- **S9 (constrained standalone) -> L5.** A constrained function is an ordinary reference
  when the ladder binds it; no dictionary channel decides method versus function.

## 5. Where the spec meets the other documents

- `docs/spec/SYNTAX.md` "Import aliasing (`as`)" and `docs/spec/language-design.md`
  "Module System" state the import forms against these clauses.
- The re-graded gate is `test/diff_compiler_shadow_semantics_test.mdk`; each row names its
  L-clause. The fixtures are `test/shadow_fixtures/`.
- `x19_prelude_module_alias_escapes_shadow.mdk` and
  `x20_prelude_member_rename_lands_on_shadow.mdk` pin L8.
- Diagnostic codes: `compiler/DIAGNOSTIC-CODES-DESIGN.md`.
