# Hindley–Milner Core Semantics (unqualified fragment)

**Status:** DRAFT — §1 is normative and enforced (2026-09-02); §2–§6 are owed by
[#2555](https://github.com/MedakaLang/medaka/issues/2555) and are listed here only as the
boundary this document commits to. Written in the register of `DICT-SEMANTICS.md` and
`EFFECTS-SEMANTICS.md`: theory-first, an audit target, and a disagreement with the
implementation is a finding to triage, not a constraint on the rule.

## 0. Purpose, and the boundary

`DICT-SEMANTICS.md` §4 writes its elaboration judgment `P ∣ Γ ⊢ e ⇝ e' : τ` on top of
"ordinary Hindley–Milner rules" it never states, and `EFFECTS-SEMANTICS.md` §6 extends a
generalization it likewise assumes. The 2026-09-02 typechecker survey (its report is linked
from `compiler/TYPECHECK-TARGET-ARCHITECTURE.md` § SURVEY AMENDMENT, SA-11) found that
unification, the occurs check, generalization levels and instantiation appear in no spec at
all, and that the two HM mechanics that *are* specified — the value restriction and `Num`
defaulting — are specified only because a defect forced each. This document is the missing
core.

**Boundary, decided before writing.** This document covers the *unqualified* core only:
monotypes, unification, the occurs check, generalization by level, instantiation, the
value restriction, and let-polymorphism scheduling over binding groups. It does **not**
carry a predicate context — `Forall` in the implementation is `∀ᾱ μ̄. τ` with **no** `P`;
predicates live in a separate obligation channel governed by `DICT-SEMANTICS.md` §4, and
`instantiate` here instantiates *no* context. Effect rows on arrows are part of the
monotype grammar (§2) but their subsumption, escape and laundering rules stay in
`EFFECTS-SEMANTICS.md` §5–§6. Two deliberate holes in row unification (the closed~closed
arm and the same-tail arm) are stated in §3 as **proof obligations discharged elsewhere**,
never as unification rules, because that is what the implementation's own comments say and
the survey confirmed.

## 1. The value restriction at every binding (normative)

**Rule (gen-value).** A binding generalizes — quantifies the type and effect variables of
its inferred type that are not free in the environment — **iff its bound expression is a
syntactic value**, where *syntactic value* is exactly the set `DICT-SEMANTICS.md` §4.1 G2
defines: a literal, a variable, a lambda, or a construction (tuple, list literal, record
construction, or an application of a declared data constructor) every part of which is a
syntactic value, modulo location and ascription wrappers, with a mutable-cell constructor
admitted at no position. A clause with parameters is a value (it is a lambda). Everything
else is *expansive* and stays monomorphic: its free variables are lowered to the enclosing
level and no later use may instantiate them differently.

Three clauses make the rule total, each the site of a measured defect:

1. **The decision is per binding, and membership in a binding group grants no exemption.**
   Binding groups (SCCs of the dependency graph, `DICT-SEMANTICS.md` §6.2 T1) schedule
   inference; they do not license generalization. A zero-argument expansive member of a
   mutually-recursive group — `cell = Ref (helper 0)` beside `helper n = … cell …` — is
   expansive, and its siblings with parameters are values on their own account. The
   implementation's former rule "a multi-member group is always a function group" was
   [#2554](https://github.com/MedakaLang/medaka/issues/2554): `check` printed
   `cell : Ref (Option a)` and the native binary read a boxed string as an integer.

2. **A type signature grants no exemption.** Whether an expression is a value is a fact
   about its syntax, never about its type: a signed binding `f : a -> a` whose RHS is an
   application is expansive even though its unified type is an arrow, because the
   application runs before the arrow is returned and may allocate. `weird : a -> a;
   weird = mk ()` shared one cell across every instantiation and segfaulted the native
   binary — [#2556](https://github.com/MedakaLang/medaka/issues/2556). A point-free
   definition is made a value by eta-expansion: `maximum xs = fold step None xs`.

3. **Partial application is expansive.** `fold step None` is an application, not a value,
   even when its head is a function of greater arity that would not run its body. This
   document does *not* adopt an arity-directed relaxation: it would make value-hood a fact
   about the callee's definition rather than the bound expression's syntax, which is the
   #1093 shape §4.1 G2 forbids. If such a relaxation is ever wanted it is a change to G2's
   set, taken there, with a fixture that discriminates it.

4. **A declared polymorphic signature over an expansive body is a definition-site
   error, never a silent narrowing.** If a binding's signature quantifies a type
   variable (with or without a context) and its bound expression is expansive, the
   binding cannot generalize to what it declares; the implementation rejects it there
   (`T-SIG-OVER-EXPANSIVE`), naming the remedy: give the binding a parameter, or write
   the monomorphic type. It must not accept the signature and then narrow the binding
   to its first use (#830's shape), nor export the declared scheme over a monomorphic
   body — the latter is what made `sumOf : (Foldable t, Num a) => t a -> a; sumOf = fold
   (+) 0` pass `check` and crash `build` on an unbound dictionary witness. This retires
   the "point-free constrained CAF" (Phase 89): under dictionary elaboration such a
   binding would become a function of its evidence, re-evaluated per use and never
   memoized, which is exactly the evaluation move `DICT-SEMANTICS.md` §4.1 G3 says is
   neutral only for G2's value set. Ruled 2026-09-02: spec as written; write
   `sumOf xs = fold (+) 0 xs`.

   A bare variable is a value even after the dictionary pre-pass has rewritten it into
   a marked node, so `callMin : Ord a => a -> a -> a; callMin = min` generalizes under
   every verb; the predicate must see through the marking or the same program is a
   value under `check` and expansive under `build`.

**Where it is enforced.** `sccSchemes` (`grep -n 'sccSchemes :' compiler/types/typecheck.mdk`)
gates each member on `memberClauseIsValue` → `isNonexpansive` and nothing else; local
`let`/`where` bindings go through `genRestricted` with the same predicate (G2). Pinned by
`test/typecheck_error_fixtures/value_restriction.mdk`, `value_restriction_scc.mdk` and
`value_restriction_sig_pointfree.mdk`, `value_restriction_sig_expansive.mdk` (clause 4) and
`value_restriction_sig_variable_ok.mdk` (the positive control: a bare variable under a
constrained signature generalizes), gate `test/diff_compiler_typecheck_errors.sh`; the
eta-expanded `test/build_diff_fixtures/{pointfree_caf,sum_twocstr}.mdk` and
`test/ported/test_eval_ported.mdk` (`myMax`) are the retired shape's former fixtures.

**Relation to G3.** `DICT-SEMANTICS.md` §4.1 G3's evaluation-timing argument is contingent
on the value set being exactly G2's set. This rule is what makes that contingency hold at
the top level: with the two exemptions gone, no binding generalizes whose evaluation could
be observed.

## 2. Monotypes and schemes — owed (#2555)

`TVar` over union-find cells, `TCon` carrying declaration identity, `TRigid`, `TApp`, `TFun`
with an effect row, `TEff` index slots; tuples as saturated `__tupleN__` spines; `Scheme`
without context. To be written from the survey's `W2-C` §1.

## 3. Unification — owed (#2555)

Structural, symmetric, equality-only; the occurs check fused with level lowering; the
`TApp`/`TApp` arm parameterized on the declaration environment `Δ` (variance); the two
row-unification relations (arrow rows, subsumption-permissive; index rows, invariant) with
the closed~closed and same-tail arms stated as obligations discharged by
`EFFECTS-SEMANTICS.md` §5/§6's declaration-time checks. From `W2-C` §2.1–2.3, §2.6, §3.4.

## 4. Generalization and instantiation — owed (#2555)

Levels; `gen` quantifying variables deeper than the current level; `inst` as fresh
substitution, **plus** the Medaka-specific re-opening of closed rows at covariant positions,
stated as its own rule. From `W2-C` §2.4–2.5.

## 5. Binding groups — owed (#2555)

Tarjan SCCs over the reference graph; the per-group order infer → exit level → default →
ambiguity → generalize, which is `DICT-SEMANTICS.md` §6.3 D1 realized. From `W2-C` §2.8.

## 6. Defaulting — owed (#2555)

`DICT-SEMANTICS.md` §6.3 D1–D4 own the rule; this document will state only the placement
relative to §4 and §5.
