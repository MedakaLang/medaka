# Dictionary-Passing Semantics for Medaka Interfaces

**Status:** specification (theory-first). **Scope:** the elaboration of
constrained, interface-using source programs into an explicit
dictionary-passing core, and the conditions under which that elaboration is
sound and coherent — including overlapping instances resolved by
most-specific-wins specialization (§3, §6).

## 0. Purpose and the non-derivation principle

Medaka's interface machinery — `interface`/`impl`, `=>` constraints,
`requires` — has been a recurring source of defects. The defects cluster:
return-position dispatch, nested/structured dictionaries, superclass
(`requires`) entailment, cross-module identity, selection among overlapping
instances, and an eval-vs-emit split in *where* a dispatch decision is made.
These are symptoms of an implementation
that grew incrementally without one authoritative answer to two questions:

1. **What is a dictionary** (its shape), and
2. **How is evidence built and threaded** (its discipline).

This document fixes those answers **from the theory of qualified types**, not
from the current code. It is deliberately written without consulting
`resolve`, `method_marker`, `typecheck`, `dict_pass`, or either evaluator. The
intent is a target the implementation can be *audited against*. Where this
spec and the implementation disagree, that disagreement is a finding to
triage — the spec is not a description of present behavior.

Theory anchor: the **theory of qualified types** (Jones) and the
**dictionary-passing translation** for type classes (Wadler & Blott 1989; Hall,
Hammond, Peyton Jones, Wadler, "Type Classes in Haskell"). Dictionary passing
is exactly *evidence translation*: a constraint is discharged by constructing
an evidence value, and a class method is a projection out of that evidence.
"Theory, not code" is consistent with "anchored on prior work" — the theory is
external to Medaka's implementation.

Terminology bridge (Medaka surface → theory; no implementation terms):

| Medaka surface | This document |
|---|---|
| `interface C a` with methods | class `C` of arity-1 (the spec generalizes to n params) |
| `impl C T` | instance `C T` |
| `requires` on an interface | superclass predicate |
| `requires` on an impl / `=>` in a signature | instance context / qualifier predicate |
| dictionary (informal) | evidence value for a predicate |

**Revision (2026-07-31): C1's quantifier is corrected — it is the closed goals `inst`
decides, not the ground goals** (owed before **F-3d** of #311/#614; recorded on issue
1155). §6 C1 said *"for any ground `C τ̄`"* while §6.1.3 says `inst` also fires at
**rigid**-variable goals and commits there, and §3's determinism paragraph already
cited C1 as covering them (*"wherever `inst` fires"*). C1, and with it §6.1.2's (b)
and (c), now quantify over every goal that **reaches** `inst` — closed, not discharged
by `assum`/`super`, **and not abstracted by `gen` into the binding's context** (that
third exit is what keeps the clause off deferred predicates). The class is the ground
goals plus the rigid-variable ones. The argument that the old wording genuinely left
the rigid class uncovered rests on §6.1.2's *"acceptance is per-goal"* — **not** on any
claim that the old wording was unsatisfiable or undecidable, both of which were offered
in an earlier draft and are wrong; §6 C1's ⚠️ states the strongest opposing reading and
defeats it there.

**The change is a two-way move on acceptance, and both directions are real.** Rigid
goals enter C1's scope (a narrowing that changes no program's status under this
document — §3 `inst` was already inapplicable without a `⊑`-minimum, rigid or ground —
and moves only what an implementation is obliged to check and diagnose). Predicates
discharged by `assum`/`super` leave it, and that is a genuine **acceptance widening**
in (c)'s direction: a program whose only occurrence of an ambiguous predicate is
discharged from a context, with no caller, was rejected before and is accepted now.
Correct under per-goal semantics, unobservable in any program that constructs the
evidence — but a widening, and §6 C1 carries the counterexample rather than the word
"inert".

Two side repairs travel with it. C1 now says **at most one** `⊑`-minimal element, so an
**empty** matching set is `inst` inapplicability rather than a C1 violation — it was
literally a violation before, under either quantifier. Every clause that read
**totality** out of C1 is corrected to stop; **§6 C1's ⚠️ carries the list, and this
banner deliberately does not repeat it** — an earlier draft kept a second copy here,
which went stale the moment the list grew, exactly as the count inside that ⚠️ had.
One list, one place. And §6.1.2 now records
that the (a) → (b) → (c) ladder **breaks at α-equal heads** — at (b) ⇒ (c) under the
preorder reading of (b) the document now fixes, at (a) ⇒ (b) under the antisymmetric
one, and either way **(a) ⇏ (c)** — so C1's rigid half may not be derived from (a).
See §6 C1's ⚠️ and §11's C1 row.

**Revision (2026-08-07): two CLAIM repairs in §8 I5 and its §11 row — no rule changes.**
Both were claims reaching past their evidence, in the clause that carries this document's
one licensed acceptance widening, so they are corrected in place with the superseded text
quoted rather than deleted. (1) I5's consequence class **(1)** asserted, in the present
tense, that the widening *"is carried by a fixture that could not pass before"*. **No such
fixture exists**: `test/dict_fixtures/` holds `s8-*` units for I1, I2 and I3 only, and the
design assigns the fixture to A-3 (#1112, OPEN). ⚠️ The repaired clause says *"gated by a
CONFORMANCE fixture"* and not "gated", because class (3) **is** pinned — **inversely** —
by `test/must_fail_fixtures/1072-overlap-xmod-bare-head-arm-order/`; the clause now names
it and says the red it will go is the drain. (2) I5's
§11 row closed by quoting a `SHADOW-SEMANTICS.md` **S2** gloss that S2 itself retracted on
2026-08-06 (#1375) — that row is the DICT half of the **reciprocal citation** #1375 added,
so a stale quotation there is load-bearing, not decorative. Repaired to S2's current
wording; the row's 🔴 PARTIAL verdict is deliberately unchanged. **(2) is #1380's item 3;
(1) is not filed anywhere** — it was found while verifying item 3, which is the argument
for enumerating this clause's claims by class rather than repairing the one that was
reported. #1380's other two items are **not** repaired here: they are
`SHADOW-SEMANTICS.md`'s, and that document is not this one's to edit.

**Revision (2026-08-01): §8 gains I6 — the three heads I4 does not cover.** I4 says
every *declaration* has a module-qualified identity; it says nothing about the heads
this implementation builds with **no declaration behind them**. **I6** pins the three,
each of which fails a mechanical reading of I4 in a different direction: a head
fabricated from a **type-parameter name** (a rigid variable, which must carry *no*
identity — I6.1), a **builtin** head such as a tuple constructor (one program-global
identity, *not* the writing module's — I6.2), and the **empty module id** (neither an
identity nor a wildcard; the absent case must be unrepresentable — I6.3). I6.2 splits
into two conjuncts — *one type* and *unforgeable* — and the second is the
soundness-bearing one. I6.1 and I6.3 also carry a **joint corollary neither states
alone**: a rigid variable cannot remain in the type-constructor node. Each conjunct
carries its own §11 row. Most of I6 holds in the tree today **only because the
name-collapse I4 rejects is still in place**, which is why those rows say "carried"
rather than "enforced": the stage that implements I4 (A-1, see #1110) has to keep them
on purpose.

**Revision (2026-07-30): six rules that the implementation had been enforcing — or
failing to enforce — with no governing clause are now written down** (#1107, Stage S
of the typechecker target-architecture arc, epic #1122). They are **§4.1** (`gen` at a
local binder: uniform abstraction, the value-restriction gate, evaluation-timing
neutrality, predicate deferral), **§5.1** (impl completeness, extraneous methods, and
where a phantom-method rejection belongs), **§6.2** (group scheduling and when `inst`
may commit), **§6.3** (numeric-literal defaulting), **§7.1** (driver unimodality), and
**§8 I4/I5** (module-qualified identity in every namespace; graph-global instance
candidacy). Each carries a §11 row, and not one of those rows reads ENFORCED-as-stated
— they are UNIMPLEMENTED, PARTIAL, DIVERGENT or HOLED. **These clauses describe the
target, not the tree.** Two of them license behaviour changes stated in the clause
itself rather than left to a migration to discover — **I5** (whose consequences are
*derived*, not enumerated, and only one of which is an acceptance widening) and
**§6.2 T4** (which carries a normative "not before I5" constraint). And one, **§4.1
G3**, is explicitly a valid argument about a value set the implementation does **not**
have (#1150), so it may not be cited as discharged: it is F-1's (#1082) gate, and the
gate is not open.

**Revision (2026-07-16): overlapping instances are specified.** Overlap with
specialization — `impl Foo Int` alongside `impl Foo a`, the more specific
instance winning — is an **intended Medaka feature** (owner decision); the
implementation deliberately accepts such pairs. The original spec forbade all
overlap (the old C1), which left the tie-break *unspecified* — and "overlap
makes `inst` nondeterministic" was not a hypothetical: with no written
tie-break, the implementation's several resolution paths diverged on which
overlapping instance wins (#203, an S0 across all four execution paths). This
revision defines the specificity order (§3), makes `inst` select by it, and
relaxes C1 (§6) to "unique most-specific match", so that entailment remains a
**total, coherent function** and every resolution position — top-level,
argument, return, nested `requires`, superclass projection — is obligated to
the *same* winner. Points where a defensible alternative design exists are
collected in §6.1 rather than silently chosen.

⚠️ **Two phrases in the paragraph above are SUPERSEDED by the 2026-07-31 revision
and are kept only as the historical record of what that revision said.** C1's
condition is now *"at most one `⊑`-minimal element"*, not *"unique
most-specific match"* — the difference is existence, and it matters. And C1 does
**not** make entailment a *total* function and never did: it bounds the winner
from above and asserts no existence, so a goal with an empty matching set leaves
entailment undefined (the missing-instance rejection). Read §6 C1 and §3's
well-formedness paragraph for the operative statements; this paragraph is
history, and is deliberately not rewritten, because a superseded revision note
that has been quietly edited stops being a record of anything.

---

## 1. Source language (the qualified fragment)

We model only what bears on dictionaries. Types and predicates:

```
τ  ::= a | T τ̄ | τ → τ              -- monotypes (a: type var; T: type ctor)
π  ::= C τ̄                          -- predicate: class C applied to type args
ρ  ::= P ⇒ τ                        -- qualified type
σ  ::= ∀ā. ρ                        -- type scheme
P  ::= {π₁, …, πₙ}                  -- predicate set (the constraint context)
```

A **class environment** `CE` records, for each class `C`:
- its parameter(s) `ā_C`,
- its **superclass predicates** `super(C) = {D₁ ā_C, …}` (Medaka `requires` on
  the interface), and
- its **method signatures** `m_i : ∀ā_C. C ā_C ⇒ τ_i` — every method's type
  mentions `C ā_C` as a constraint; `ā_C` may appear in argument position,
  result position, or not at all (see §5).

An **instance environment** `IE` records, for each declared `impl`, an
**instance declaration**

```
instance Q ⇒ C T̄        -- Q = the impl's own context (Medaka requires/=>)
```

where `T̄` are the instance head types and `Q` is the (possibly empty) set of
predicates the instance depends on. The instance also carries the method
implementations `{m_i ↦ e_i}` for `C`. Distinct instances of the same class
**may have overlapping heads** (two heads that unify); §3's specificity order
and §6 C1 govern when that is legal and which instance a goal resolves to.

We write `⌜·⌝` for the core (target) language: source minus predicates, plus
explicit evidence abstraction and application (§7).

---

## 2. Evidence representation — what the theory dictates

This section answers question (1). The representation is **derived from the
entailment rules** of §3, not chosen for convenience: the shape of evidence is
whatever lets superclass and instance-context evidence be **resolved once at
construction** — reached thereafter by a projection or a captured closure — and
never re-resolved at the use site.

**Definition (dictionary).** Evidence for a predicate `C T̄` is a record

```
DictC⟨T̄⟩ = {
    methods:  m₁ ↦ v₁, …, mₖ ↦ vₖ    -- impl of each method at T̄, each closed over
                                       -- the instance-context evidence (§3 `inst`)
    supers:   D ↦ DictD⟨σ̄⟩            -- one per superclass D ā_C ∈ super(C),
                                       -- with σ̄ = [T̄/ā_C](D's args)
}
```

That is, a dictionary is **structured and nested**: it *contains* sub-evidence
for every predicate it transitively depends on — its superclasses appear as
`supers` sub-dicts, and its instance-context evidence is captured inside the
method closures — rather than naming them for later lookup. (Superclass head args
are written `[T̄/ā_C](D's args)`; for the common case `D ā_C` this is just `D T̄`.)

**Why nested, from the rules (not from code).** Entailment has two
non-assumption rules: superclass projection (§3, `super`) and instance use
(§3, `inst`). For `super` to be a total, side-effect-free *projection*
— `P ⊢ D T̄ ⇝ supers(e).D` — the `D`-evidence must already be *present inside*
the `C`-evidence. If instead a dictionary were a flat key (e.g. only an
instance identity) and superclass evidence were recovered by re-running
resolution at the use site, then:

- the use site re-derives `D T̄` independently of how the `C T̄` evidence was
  built, so the two can disagree when resolution is path-sensitive — a direct
  **coherence** break (§6); and
- nested constraints whose evidence is itself constraint-dependent (an
  instance context `Q` mentioning class parameters) cannot be reconstructed at
  all from a flat key: that evidence is captured in the method closures at
  construction time, and a flat impl-key discards it. This is the structural
  cause of the "nested element-dict" class of failures.

**Verdict:** evidence is a tree of dictionaries. Superclass predicates are
**`supers` fields**, resolved once at construction and thereafter only
projected; instance-context evidence is **captured in the method closures** at
construction, never re-resolved. A flat, impl-key representation is *unsound for
the general case* and admissible only as a representation **optimization** under
the side conditions of §8 (a dictionary with no superclasses whose methods
capture no context evidence is isomorphic to its instance identity, so it may be
represented by that identity — but the general shape is the tree).

**Uniformity of nested resolution.** Every piece of sub-evidence in the tree —
each `supers.D` field, and each instance-context dict captured in a method
closure — is built by the **same entailment judgment** (§3) as a top-level
goal, at the types of the *construction site's* goal instantiation. Under
overlapping instances this is load-bearing: a nested obligation (the
`requires` context of a general instance, discharged at a now-concrete type)
must select the most-specific instance at that type exactly as a top-level
goal there would. Sub-evidence is therefore **never pre-baked at the instance
declaration** against the general head — a polymorphic instance's context and
supers are resolved per construction goal — and never resolved by a different
lookup (first-match, declaration order, "the instance syntactically at hand")
than top-level goals use. A construction path with its own weaker lookup
agrees with top-level resolution on non-overlapping instance sets and
diverges precisely under overlap; that is the defect class of #203 (§10).

Method values `v_i` are closed over their needed evidence — both the instance
context `Q` (captured at construction, §3 `inst`) and any constraints internal
to the method body — so projecting `methods.m_i` yields a directly-applicable
value. (Exception: a method whose *own* signature adds a constraint over a fresh
variable not fixed by the instance keeps that dictionary abstract; projection
then yields a value still awaiting that dict at the call site.)

---

## 3. Entailment: constructing evidence

The judgment

```
P ⊢ π ⇝ e
```

reads: under the in-scope predicate assumptions `P` (each available as an
evidence variable), predicate `π` is entailed, **witnessed by evidence `e`**.
`P` is the constraint context of the enclosing scope; its members are bound to
evidence variables `d_π`.

### Specificity

Instance heads may overlap; the `inst` rule below therefore needs a
**tie-break**, and the tie-break must be a property of the instances and the
goal alone — never of search order, declaration order, or resolution position.

**Definition (specificity, `⊑`).** For instances `I_A = (Q_A ⇒ C Ā)` and
`I_B = (Q_B ⇒ C B̄)` of the same class (head variables taken disjoint),

```
I_A ⊑ I_B    iff    ∃σ.  σ(C B̄) = C Ā
```

— `I_A` is *at least as specific as* `I_B` iff `I_A`'s head is a substitution
instance of `I_B`'s head. The relation compares **heads only**; the contexts
`Q_A`, `Q_B` play no role (§6.1, choice-point 1). Write `I_A ⊏ I_B`
(*strictly more specific*) for `I_A ⊑ I_B ∧ ¬(I_B ⊑ I_A)`.

`⊑` is a **preorder on instances** — reflexive (`σ = id`) and transitive
(compose the substitutions) — and descends to a **partial order** on heads
up to renaming: mutual substitution instances are equal up to a variable
bijection (antisymmetry modulo α). Two instances with α-equal heads are
`⊑`-equivalent yet distinct, which C1 (§6) rejects as ambiguous — duplicate
heads never tie-break.

For a goal `π = C τ̄`, define the **matching set**

```
match(IE, π) = { I ∈ IE  |  ∃φ.  φ(head(I)) = π }
```

Overlap — `|match(IE, π)| > 1` at some goal — is **permitted**. What §6 C1
requires is that there be no *rival* winner: `match(IE, π)` must have **at most
one** `⊑`-minimal element. Where one exists it is the goal's *most-specific
matching instance*, written `min⊑(match(IE, π))`. (The matching set is finite,
and in a finite preorder a unique minimal element is a minimum — equivalently,
one matching instance is `⊑` every other matching instance.) If two
`⊑`-incomparable instances match and no matching instance lies `⊑`-below both,
no minimum exists and the goal is **ambiguous overlap** — rejected, not chosen
from. ⚠️ The other way to have no minimum is for `match(IE, π)` to be **empty**;
that is *not* ambiguous overlap and not a C1 violation but `inst` inapplicability
— the missing-instance rejection. C1 bounds the winner from above and asserts no
existence (§6 C1).

*Example (the #203 shape).* Let `IE` contain `DL_a = (Default a ⇒ Default
(List a))` and `DL_Int = (Default (List Int))`. Then `DL_Int ⊏ DL_a` (via
`σ = [Int/a]`). The ground goal `Default (List Int)` is matched by both;
`min⊑` is `DL_Int`, so **its** evidence witnesses the goal — at *every*
resolution position: as a top-level goal, and equally as the nested context
obligation that arises when `DL_a` is selected for the goal
`Default (List (List Int))` (matched only by `DL_a`) and its context
`Default a` is discharged at `a := List Int`. A path that hands that nested
obligation to `DL_a`'s evidence has changed the program's meaning.

### The rules

```
            (d_π : π) ∈ P
(assum)  ───────────────────
            P ⊢ π ⇝ d_π


            P ⊢ C T̄ ⇝ e        (D ā_C) ∈ super(C)
(super)  ──────────────────────────────────────────
            P ⊢ D T̄ ⇝ supers(e).D


            I = (instance Q ⇒ C T̄) ∈ IE
            I = min⊑(match(IE, C τ̄))      -- the unique most-specific match;
                                          -- none/no-unique ⇒ rule inapplicable
            φ a most-general matcher with  C τ̄ = φ(C T̄)
            for each πᵢ ∈ φ(Q):   P ⊢ πᵢ ⇝ eᵢ        -- ē = (e₁ … eₚ)
(inst)   ──────────────────────────────────────────────────────
            P ⊢ C τ̄ ⇝ DictC⟨τ̄⟩{
                  methods = φ(impl_C) closed over ē;
                  supers  = { D ↦ e_D | D ā_C ∈ super(C),
                                        P ⊢ [τ̄/ā_C](D ā_C) ⇝ e_D } }
```

Notes.

- **`assum`** is dictionary-variable use: a constraint already in scope is
  witnessed by its bound variable. This is the rule that makes a constrained
  function *receive* rather than *rebuild* its evidence.
- **`super`** is pure projection into the nested record — never a re-resolution.
  It is the formal meaning of `requires` on an interface.
- **`inst`** is the only rule that *builds* a fresh dictionary. It selects the
  goal's **unique most-specific matching instance** `I` and resolves to *`I`'s*
  evidence: it recursively discharges **`I`'s own
  context `φ(Q)`** at the goal's (specific) instantiation through this same
  judgment — so nested obligations themselves resolve most-specifically —
  captures that evidence `ē` in the method closures, fills `methods` from
  `I`'s impl, and fills each `supers.D` by resolving `D τ̄` through entailment
  — not through `super`, which would need the very dict being built. Its
  recursive premises are what force the representation to be a tree.
- **When `inst` does NOT apply**, the formal premise above says only that the
  rule is **inapplicable** (`none/no-unique ⇒ rule inapplicable`), and *which*
  rejection follows depends on **why**. Two `⊑`-incomparable matches with none
  `⊑`-below both is **ambiguous overlap** (§6 C1). An **empty** matching set is
  the **missing-instance** rejection and is *not* a C1 violation (§6 C1's ⚠️) —
  and it need not be a rejection at all, since §3's precedence may already have
  discharged the goal by `assum`. ⚠️ This note read *"when the matching set has
  no `⊑`-minimum the program is rejected as ambiguous overlap"*, which collapsed
  the two and contradicted §6 C1 from inside the same section.

**Resolution determinism.** Entailment is intended to be a *function*: for a
given `(IE, CE, P, π)` at most one derivation exists up to evidence
equivalence (§6) — now **the unique most-specific derivation**, not the
unique derivation. Instance heads may overlap; `inst` stays deterministic not
by forbidding overlap but through its minimality premise: it applies only for
`min⊑(match(IE, π))`, which §6 C1 keeps free of a **rival** wherever `inst`
fires. Two `⊑`-incomparable matches with no common `⊑`-lower match are
**ambiguous overlap** and the program is rejected — most-specific-wins is a
total tie-break, never "pick one". That reject is an `inst`-vs-`inst` rule and
scopes to `inst` alone.

⚠️ **Note precisely what C1 supplies here, because this sentence used to
over-state it.** C1 gives *at most one* `⊑`-minimal element — never that one
**exists**. So `inst`'s minimality premise is either met by exactly one instance
or not met at all, and an **empty** matching set fails it just as an ambiguous
one does, for a different reason and with a different verdict (§6 C1). Existence
is `inst`'s applicability, not C1's guarantee. This sentence read *"which §6 C1
**requires to exist uniquely** wherever `inst` fires"* until the at-most-one
repair; its quantifier was already right, which is why it is cited in §6 C1 — and
is exactly why the rest of it went unexamined for a round.

When both `assum`/`super` and `inst` could apply, **`assum`/`super` takes
precedence**: a predicate already in scope is used, and `inst` fires only when
no assumption matches (GHC's rule). This is what makes this section's "nested
obligations themselves resolve most-specifically" realisable, and with it
§2's "never pre-baked at the instance declaration": inside the body of a
parametric instance the `requires` context is *in scope as an assumption*, so
the body forwards the dict built at the **construction site's** goal rather
than re-resolving its own rigid goal through `inst` to the general instance.
The two are therefore not in tension — they resolve at different types, and
`assum` is the one holding the construction goal's evidence. Note the
precedence is only reachable when an assumption actually **matches** the goal:
matching is structural, on rigid variables, never unification (§6.1.3) — given
`S a`, the goal `S (List a)` is *not* an assumption in scope, `assum` stays
silent, and `inst` correctly commits to the general instance.

In particular, the choice among overlapping instances is made **here, once,
during elaboration** — never re-made per resolution position, per engine, or at
run time (§6 "uniform resolution", §7).

**Well-formedness (for entailment to be a single-valued function).** Beyond
at-most-one most-specific match (§6 C1), resolution is decidable only if (W1) the
**superclass relation is acyclic** — otherwise `super`-search loops — and (W2)
**instance resolution terminates** — each `inst` premise `πᵢ ∈ φ(Q)` (the
context of the *selected* instance) must be structurally smaller than the goal
(a Paterson/coverage-style condition), otherwise the recursive discharge of
`Q` diverges. Most-specific selection itself adds no termination risk:
`match(IE, π)` is a finite subset of a finite `IE`, membership is one
one-sided matching problem per instance, and `⊑` between two heads is one
more — so `min⊑` is computed by finitely many decidable comparisons, before
any recursion. W1 + W2 + C1 together make entailment the **function** the
elaboration of §4 assumes it to be — **single-valued**, and that is the whole of
what they deliver. ⚠️ **They do not deliver TOTALITY, and this heading over-claimed
it in both of its previous forms.** C1 bounds the winner from above ("at most one
`⊑`-minimal element") and asserts no existence, so it cannot carry totality and
never could. Nor is entailment *"defined exactly where a matching instance
exists"* — a briefly-written repair that is false in **both** directions, by this
document's own cases: a non-empty matching set can still fail, when the selected
instance's own context `Q` is underivable (§8 I5's class-4 shape); and an
**empty** one can still succeed, when `assum` discharges the goal from `P`
(§5.1 M3's first bullet, where `match(IE, Mk a)` is empty at rigid `a` and the
program is nonetheless accepted). Where entailment is defined is `inst`'s
applicability *and* §3's precedence, not C1's business.

**W3 (method-scheme fidelity).** `inst` fills `methods` from `I`'s impl, and
`var` at every use site instantiates the **method's declared scheme** — so the
dictionary's method values must actually *inhabit* those schemes, at the
instance head, **at full generality**. For an instance
`I = (instance Q ⇒ C T̄)` and a class method

```
            m : ∀ā_C. C ā_C ⇒ ∀b̄ μ̄. Q_m ⇒ τ_m
```

(`b̄` the method-level type variables not bound by the class head, `μ̄` its
effect variables), the body supplied by `I` — or by the class's **default**,
which is checked by this same rule (it is the class-provided impl, at the head
`C ā_C` itself with `ā_C` also held rigid) — must satisfy

```
            (Q, Q_m) | Γ ⊢ impl_I.m ⇝ e_m : [T̄/ā_C] τ_m     with b̄, μ̄ RIGID
```

**rigid** meaning skolem constants: the body may not instantiate a `b ∈ b̄` to
a constructed type, may not identify two of them, and may not identify one with
a variable of `T̄`; a `μ ∈ μ̄` may not acquire a concrete effect atom nor be
identified with another. (One admitted exception on the effect side — a `μ`
identified with a **row parameter of `T̄` itself** — is a known, tracked
residual; see `EFFECTS-SEMANTICS.md` §6 "Known residual (#817)".) `b̄ μ̄` belong to the **caller** — `var` re-instantiates
them freshly at every use site — so a body that pins one inhabits a strictly
more specific type than the scheme every call site is entitled to. Checking the
body with *flexible* `b̄ μ̄` (unification metavariables) is unsound on both
axes, silently:

- **type axis** — `mk : a → b` with a body returning `42` fixes `b := Int`;
  a caller instantiates `b := String` and evaluation crashes (likewise a body
  forcing `b = c` between two method variables, or `b` = an instance variable
  of `T̄`);
- **effect axis** — the same body position can fix `b` to an *effect-bearing*
  type (`Unit →^⟨Stdout⟩ String`, alone or nested in a tuple or data argument);
  the caller pins `b` to the pure arrow and obtains a certified-pure value that
  performs IO — the laundering vein of
  [`EFFECTS-SEMANTICS.md`](EFFECTS-SEMANTICS.md) §6 (#814).

**W3 and graded interfaces.** One family of impls cannot satisfy W3 under a
*plain* interface signature: an effect-row-indexed container (`Async e a`) whose
functor/monad impls must store the method's callback in the container — the sound
result index is `e ⊔ e'`, inexpressible with the head fixed at `Async e`, so the
body can only typecheck by identifying a caller-owned effect variable with the
instance-head row parameter (the tracked #817 exemption). The resolution is
**graded interfaces** — the `Deferred*` family, interfaces over effect-indexed
constructors `f : Effect → Type → Type` whose signatures compose indices by the row
join in result position (`gmap : (a →^{e₂} b) → f e a → f (e ⊔ e₂) b`); see
[`EFFECTS-SEMANTICS.md`](EFFECTS-SEMANTICS.md) §6 "Graded (`Deferred*`)
interfaces" for the semantics, §6.1–§6.5 for the declared kind, and #820 for the
plan. Dictionary-wise nothing changes: a graded
interface elaborates to an ordinary dictionary, one instance per constructor
*family* (`impl DeferredMappable Async` — no overlap-on-grade dimension), grades erase
with the rows they are, and — the point — the graded impl inhabits its scheme at
full generality, so W3 holds for it with **no exemption**.

⚠️ **"No exemption" is a property of the design, not a description of the current
implementation.** Two verified S0s stand between the two: the `Effect`-kinded index
slot is not checked at unification at all (#1094), and a result-index occurrence is
miscounted as discharging the argument-coverage rule, so a graded impl that applies
its callback eagerly launders (#1095). Until those are addressed, migrating an impl
off the #817 carve-out and onto a graded signature moves it from a *tracked*
exemption to an *unchecked* one — filed, but with nothing in the type system
stopping it. See [`EFFECTS-SEMANTICS.md`](EFFECTS-SEMANTICS.md)
§6.7 for both mechanisms and §6.9 for what the graded design still leaves open.

W3 needs **no variance analysis**: rigidity decides scheme membership
uniformly. In particular a body like `mk d = k ⇒ k ()` (fixing `b` to a
callback-taking arrow — a shape a variance-aware effect check would be tempted
to admit, since the atom sits contravariantly) is rejected on the *type* axis
alone: `∀b` with `b` pinned to any shape is a lie to every caller, effectful or
not. This is the instance-side counterpart of `gen-sig`'s "a signature is a
contract the body must satisfy, not a floor it can raise" (§4): the method
signature is a contract the impl must meet **at every instantiation the caller
may choose**, not just one the impl finds convenient.

---

## 4. Elaboration: typing-with-translation

The judgment

```
P | Γ ⊢ e ⇝ e' : τ
```

elaborates source term `e` to core term `e'`. `Γ` binds variables to schemes;
`P` is the ambient constraint context (with evidence variables). The rules of
interest are those that *introduce* or *consume* dictionaries; ordinary
Hindley–Milner rules carry the translation through unchanged.

```
            x : ∀ā. Q ⇒ τ  ∈ Γ        S = [τ̄/ā]  (instantiation)
            for each πᵢ ∈ S(Q):   P ⊢ πᵢ ⇝ eᵢ
(var)    ────────────────────────────────────────────────
            P | Γ ⊢ x ⇝ x e₁ … eₙ : S(τ)


            P' = the predicates deferred to this binding (its principal context)
            (P, P') | Γ ⊢ e ⇝ e' : τ
(gen)    ───────────────────────────────────────────────────────────────
            P | Γ ⊢ (let x = e) ⇝ (let x = Λā. λ(d₁:π₁)…(dₘ:πₘ). e') : …
                where {π₁..πₘ} = P',  ā = generalizable vars


            P' = predicates deferred to the (mutually) recursive group
            d̄ = (d₁:π₁)…(dₘ:πₘ) fresh for P'
            (P, P') | Γ, x : ∀ā. P' ⇒ τ ⊢ e ⇝ e' : τ
            -- every recursive occurrence of x in e' is elaborated by (var) to
            -- (x d₁ … dₘ): the SAME dict params, NOT a fresh entailment
(gen-rec)──────────────────────────────────────────────────────────────────
            P | Γ ⊢ (let rec x = e) ⇝ (let rec x = Λā. λ d̄. e')


            x :: ∀ā. Q_sig ⇒ τ   (ascribed signature)
            P'ᵢ = the predicates the body infers on ā
            Q_sig ⊩ P'ᵢ          (entailment under `requires`-closure, §3)
            (P, Q_sig) | Γ ⊢ e ⇝ e' : τ
(gen-sig)───────────────────────────────────────────────────────────────────
            P | Γ ⊢ (let x : Q_sig ⇒ τ = e) ⇝ (let x = Λā. λ d̄_sig. e')
                where d̄_sig = (d₁:π₁)…(dₖ:πₖ),  {π₁..πₖ} = Q_sig
```

Reading.

- **`var`** is the **point of evidence application**. A use of a constrained
  binding instantiates its scheme, and *each residual predicate is discharged
  by entailment (§3)* and applied as an extra leading argument. The evidence is
  determined entirely by the instantiation `S` and the ambient `P` at the use
  site — statically, before evaluation.
- **`gen`** is the **point of evidence abstraction**. When a binding is
  generalized over a constraint set `P'`, the elaborated term abstracts a
  dictionary parameter for each predicate. Inside the body those parameters
  populate `P` and are consumed by `assum`. This is the dual of `var`: producers
  abstract, consumers apply, and the two must agree on **order and arity** of
  the dictionary parameters (§8 makes this a per-binding, identity-keyed fact —
  the source of the cross-module collision when arity is keyed by bare name).

- **`gen-rec`** is `gen` for a (mutually) recursive group, and it is the rule the
  recurring mutual-recursion dictionary bugs (#44) turn on. The recursive
  occurrences of `x` inside its own body must be applied to the **same** dict
  params `x` abstracts — `var` resolves them to the in-scope `d₁…dₘ`, **not** a
  fresh entailment. Re-resolving instead rebuilds a divergent or duplicated
  dictionary at each recursive step (non-termination, or evidence that disagrees
  with the caller's). A mutually-recursive group shares **one** `λ d̄.` prefix
  over the whole group.

- **`gen-sig`** is `gen` for a binding carrying an **ascribed signature** (#619).
  The distinction from `gen` is which set becomes the binding's principal context.
  `gen` reads it off the body (`P'` = the inferred deferred predicates); `gen-sig`
  takes it **from the signature**: `Q_sig` — not the inferred `P'ᵢ` — is the
  principal context, so the abstracted dictionaries `d̄_sig`, the displayed scheme,
  and every caller's discharged predicates (`var`) all come from `Q_sig`. A
  signature is a **contract the body must satisfy, not a floor it can raise** (the
  standard qualified-types reading — Jones; Hall–Peyton-Jones–Wadler). The body's
  inferred `P'ᵢ` is therefore **checked, not merged**: the side condition
  `Q_sig ⊩ P'ᵢ` demands every inferred predicate be entailed by the ascribed
  context, closed under `requires` (§3). If it fails — the body genuinely needs a
  predicate `Q_sig` does not license — the program is **rejected**
  (`T-MISSING-CONSTRAINT`), never silently widened to `Q_sig ∪ P'ᵢ`. Two
  consequences fall out, and both are the point of the rule:
    - a declared predicate the body never dispatches on is **still abstracted** —
      it is part of the contract (`sz2 : Sz a ⇒ a → Int` whose body ignores `Sz`
      still has `Sz a` in its scheme and every caller discharges it);
    - a predicate the body infers that `Q_sig` **already entails via a superclass**
      is **dropped, not displayed** (`when : Thenable m ⇒ …` whose body's `pure`
      infers `Applicative m` has scheme context exactly `Thenable m`, since
      `Thenable requires Applicative`). Merging it in — the pre-#619 behaviour —
      was sound but produced a redundant `(Applicative m, Thenable m) ⇒` display
      and propagated a superclass-redundant predicate to every caller.
  When `Q_sig` is empty the rule degenerates to the ordinary monomorphic-signature
  case, and `gen-sig` still fires (a signed binding with no `⇒` has principal
  context `∅`, so a body that infers **any** predicate on `ā` is rejected — the
  usual `Could not deduce … add '… ⇒'` error).

The arity and order of `(d₁:π₁)…(dₘ:πₘ)` are part of the binding's elaborated
type and **travel with the binding's identity**, not its surface name.

### 4.1 `gen` at a local binder

`gen`, `gen-rec` and `gen-sig` are stated over `let`, and are therefore rules about
**every** binder that generalizes: a top-level binding, an `impl` method, a class
default, **and a `let`/`where` binding inside a body**. Nothing above distinguishes
them. This subsection says so normatively, because the distinction has repeatedly
been *read into* the rules by implementations, and reading it in is the structural
cause of an entire defect family (#866 / #1040 / #1043 / #1045 / #1052; the remedy is
tracked as #1082, gated on this clause).

- **G1 — Uniform abstraction.** A local binding generalized over a predicate set `P'`
  abstracts one dictionary parameter per predicate, exactly as `gen` states, and each
  of its use sites applies them by `var`. `gen-rec` likewise governs a *recursive*
  local: its recursive occurrences reuse the group's `d̄`, never a fresh entailment.
  A local binding's dictionary arity and order are part of **its** elaborated type
  and are keyed by **that binder's identity** — the local reading of §8 I1. Two
  `where` helpers spelled `g` in two different bodies have independent dictionary
  arities; a table keyed by the bare name `g` conflates them, with exactly the
  under-/over-application I1 describes.

- **G2 — The value-restriction gate, with the value set defined HERE.** A local
  binding **may abstract dictionaries only where it generalizes at all**, and it
  generalizes only where the value restriction licenses it: the bound expression must
  be a **syntactic value**. A non-value local is monomorphic, has no quantified
  variable for a predicate to range over, and therefore abstracts nothing. Dictionary
  abstraction is not a *second* gate stacked on generalization — it is a consequence
  of it. No local that fails the value restriction may acquire a `λd̄.` prefix.

  **Definition (syntactic value).** `v` is a syntactic value iff it is a literal, a
  variable, a lambda, or a **construction whose every component is a syntactic
  value** — a tuple, a list literal, a record construction, or an application of a
  data constructor, in each case with **all** parts syntactic values — modulo
  location/origin wrappers and type ascriptions, which are transparent. A constructor
  that allocates a **mutable cell** is not admitted at any position. Everything else
  is *expansive*.

  🚨 **This definition is given in full, rather than by naming the implementation's
  predicate, and that is deliberate.** An earlier revision of this clause defined the
  set as *"whatever `isNonexpansive` accepts"*. That is the #1093 shape — a rule
  stated in terms of an existing relation silently inherits that relation's bugs —
  and it has now inherited **two**, one after the other:

  - **#1139 (CLOSED, fixed 2026-07-31).** The constructor-application arm tested only
    the **final** argument of the spine, so a mutable cell in any non-final position
    was admitted. The arm now walks the whole spine (`isCtorAppSpine`,
    `compiler/types/typecheck.mdk` — `grep -n 'isCtorAppSpine :' compiler/types/typecheck.mdk`),
    testing every argument met on the way to the head, so **"all parts" is now the
    words that arm has**.
  - **#1150 (OPEN, S0, verified, memory-safety) — this is the hole that is live, and it
    is strictly wider.** The *head* test is a first-character heuristic, not a
    constructor lookup: `isCtorAppSpine (EVar name) = name != "Ref" && ctorHeadIsUpper
    name`. A module alias is **required** to be uppercase (`aliasNameFor`,
    `compiler/frontend/parser.mdk`) and an alias-qualified value desugars to a flat
    `EVar` carrying the dotted name (`rewriteAliasQual`, `compiler/frontend/desugar.mdk`,
    via `qualifiedLocal`, `compiler/frontend/ast.mdk`), so `ctorHeadIsUpper "H.new"`
    reads `'H'` and returns `True`: **every alias-qualified application in the language
    is classified as a constructor application**. Classification is not the whole test
    — `isCtorAppSpine (EApp f x) = isCtorAppSpine f && isNonexpansive x` still rejects
    the spine when any argument is expansive, so `H.f (g 1)` is classified but **not**
    generalized. That does not save the repro, whose argument is a value:
    `let m = H.new ()` over `stdlib/hash_map.mdk` is a polymorphic mutable table —
    `check` exit 0, `run` `E-NOT-A-FUNCTION`, built binary **SEGFAULT** (exit 139).
    #1139 needed a hand-written `data` type with a `Ref` field; this needs one stdlib
    import, and the only safe **alias** spelling (a lowercase one) is a parse error —
    a selective import (`import hash_map.{new}` + `let m = new ()`) is the sole safe
    form, its head `EVar "new"` failing `ctorHeadIsUpper` and staying expansive.

  So the implementation's predicate is **still not this clause's set**, for a different
  reason than when this paragraph was first written. The three sibling arms (`ETuple`,
  `EListLit`, `ERecordCreate`) fold with `allList isNonexpansive` and always did; what
  the constructor arm now lacks is not the fold but a trustworthy notion of *what a
  constructor is*.

- **G3 — Evaluation-timing neutrality, and exactly what it is contingent on.**
  Wrapping a bound expression `e` as `λd̄. e` moves `e`'s evaluation from binding time
  to each use. **For the value set G2 defines, that is unobservable**, and the
  argument is what makes G2 the *right* gate rather than a convenient one: every such
  value's evaluation performs no effect, cannot diverge or panic, and allocates
  nothing whose identity a program can observe — mutable-cell constructors are
  excluded from the value set at every position **precisely so that generalizing them
  stays sound**, which is the same exclusion this argument needs. Re-evaluating such
  a value per use can therefore change *allocation cost* and nothing else. Anything
  that could raise, diverge, or perform on evaluation is expansive, is not
  generalized, and is never wrapped.

  🚨 **This is a valid argument about G2's set, NOT a discharged theorem about the
  tree, and the difference is load-bearing because this clause is F-1's (#1082)
  gate.** The implementation's value predicate is **not** G2's set: by the 🚨 above it
  classifies *every alias-qualified application* as a constructor application, so
  `let m = H.new ()` over `stdlib/hash_map.mdk` is generalized into a polymorphic
  mutable table today (#1150 — `check` clean, `run` `E-NOT-A-FUNCTION`, native
  SEGFAULT). Wrapping *that* binding in `λd̄.` would additionally re-allocate the cell
  per use, so neutrality does not hold for it either. **An implementation may not cite
  G3 while its value predicate is holed:** either the predicate is repaired to G2's
  set first, or the dict-abstraction of locals is restricted to a set that is
  independently shown to satisfy G2. Landing F-1 on the current predicate would take
  a live unsoundness and give it a second, calling-convention-shaped channel.

  ⚠️ **Why the argument has to be made at a local binder at all** — the top-level case
  looks like it never needed it, and the reason is *not* established. A top-level
  binding is gated by the same value predicate (`memberClauseIsValue`,
  `compiler/types/typecheck.mdk:16023`, calling the same `isNonexpansive`), and once
  it is dict-abstracted its body is likewise re-entered per use, so "evaluated at most
  once per program" is a claim about **CAF memoization of a nullary top-level
  binding** — which this document has **not verified** and does not assert. Treat the
  top-level/local asymmetry as unestablished. What does not depend on it: a proposal
  to "generalize locals a little more eagerly than the value restriction allows" is
  not an ergonomic loosening of G2, it is a proposal to move evaluation, and it owes
  this argument again from scratch.

- **G4 — Predicate deferral across nested binders.** Let a local binding `b` sit
  inside an enclosing binder `E`. Partition the predicates `b`'s body infers by the
  variables they mention:
  - every variable is generalizable at `b` ⇒ the predicate is **`b`'s own**: `gen`
    abstracts it on `b`, and each use site of `b` discharges it by §3 in `E`'s scope;
  - some variable is free in `E`'s environment (it belongs to `E`, or to a binder
    outside `E`) ⇒ the predicate is **deferred outward**, unchanged, to the nearest
    enclosing binder that generalizes that variable; `b` abstracts nothing for it;
  - some variable is **rigid** (bound by `E`'s ascribed signature) ⇒ the predicate is
    discharged **in place** by `assum` against `E`'s own dictionary parameter (§3
    precedence), and abstracted nowhere.

  A predicate mixing the first two kinds is **`b`'s own** — abstracted on `b` — and
  its discharge at each use site is an ordinary §3 goal in `E`'s scope. That goal may
  succeed by `assum` (when it matches structurally: §3's matching is on rigid
  variables, never unification), succeed by `inst`, or **fail**, in which case the
  **use site** is rejected.

  🚨 **It is never discharged by monomorphising `b`, and that prohibition is
  normative.** The tempting shortcut for a local an implementation cannot yet
  dict-abstract is to decline generalization and let unification sort it out. That is
  unsound the moment two use sites instantiate the predicate's variable at two
  *distinct* types: monomorphising `b` unifies them, and when those are `E`'s own
  rigid signature variables it merges two variables the signature declared distinct —
  silently collapsing `E`'s dictionary parameters so one use runs on the other's
  evidence. #1052 is exactly that program (`useTwo : (Sized a, Sized b) => …` sharing
  one `where` helper: printed `2` where this clause says `3`, on both engines, exit
  0, no diagnostic). Under G4 the helper abstracts `Sized c` and the two uses
  discharge by `assum` against `E`'s two distinct dictionary parameters, which is the
  specified answer. **An implementation that cannot yet abstract locals must REJECT
  the multi-type use with a located diagnostic; declining to generalize is not an
  admissible approximation of this clause, it is a different and unsound rule.**

### 4.2 Obligation deferral: which predicates defer, and where a deferred one is discharged

§4's rules say *what* evidence a term needs. They do not say *when* an implementation
is allowed to postpone constructing it. An implementation records predicates on several
internal channels, and each of those channels had, until this clause, its own deferral
disposition — set by whichever defect was being fixed at the time. This subsection is
the one policy those channels must conform to.

⚠️ **These rules are `OD1`–`OD6`, not `D1`–`D6`. §6.3 already owns `D1`–`D4`** (defaulting
placement, substitution, taint, level discipline) and its own prose cites *"D1's
ordering"* bare. Two rule sets under one label in one document is a citation that
silently resolves to the wrong rule, so this set carries the `OD` (obligation-deferral)
prefix. Cite `OD`n and `§6.3 D`n; never a bare `D`n in this document.

**OD1–OD5 are consequences of §4 and §3.** **OD6 is not derived: it is stated here as
primitive.** An earlier draft justified it from "the single-front-end fact in §7" — but
§7 is the single-*evaluator* law and §7.1 is driver unimodality, and **neither says that
`check`, `run` and `build` must accept the same programs**. That was a new axiom
presented as a corollary, borrowing authority it did not have. The honest status is that
OD6 is an independent commitment of this specification, which the implementation's shared
front end makes *achievable* but does not by itself make *true*.

**Vocabulary.** A predicate `π` is **ground at a point** iff every argument of `π` has
a concrete head type constructor there. **Discharge** of `π` is the §3 entailment
decision — `assum`, `inst`, or reject. A **deferral** postpones discharge past the
point at which `π` was recorded.

⚠️ **"Ground" is not the same as "decidable now", and the difference is load-bearing at
OD1.** An entailment goal can be *decidable* on an argument that is not ground by the
definition above — a function type has no head *type constructor*, yet no instance can
ever match it, so the goal is refutable immediately. An implementation that reads OD1 as
"keep the ground ones" rather than "keep the ones a verdict can be reached on" drops
exactly that population. This is not hypothetical: it is how the first implementation of
OD1 (#1114) failed review, on `Debug (Int -> Int)`.

---

**OD1 — a predicate whose verdict is DECIDABLE where it is recorded is discharged
there.** If entailment can reach a verdict on `π` — accept or reject — at the end of the
inference of the binding, method body, or module that recorded it, that inference MUST
discharge it. No window, rollback, deduplication, or channel filter may discard it.

`π` is decidable at a point iff every argument's head is **stable** there, i.e. no later
substitution can change it. Two populations qualify, and an implementation owes both:

- **ground** — every argument has a concrete head type constructor. Grounding is
  monotone, so the verdict cannot move.
- **structurally refutable** — an argument whose head is a *type former no instance can
  ever match*, the function arrow being the case that exists today. `Debug (Int -> Int)`
  is not "ground" under the vocabulary above (an arrow has no head type *constructor*)
  and is nonetheless decided, by `inst` having no candidate at all.

> *Rationale.* A decidable verdict does not change later, so postponing it is never
> necessary — and postponing it is the only mechanism by which two consumers of one
> front end can disagree (OD6).
>
> 🚨 **A narrowed decidability test is invisible to every test suite**, which is why the
> two populations are enumerated here rather than left to the implementation. A predicate
> a filter drops is one no channel reports; the result is *silence*, and silence is what
> a golden already records for every program the compiler accepts. Narrowing this test
> keeps every suite green. Whatever predicate implements OD1 must therefore be derived
> from the entailment engine's own decision structure — every arm that can reach a
> verdict before the groundness test — and not sampled from the cases someone had in
> mind.

**OD2 — a non-ground predicate defers to the binding that quantifies its variables.**
If `π` is not ground, it defers outward to the nearest enclosing binder that
generalizes its free variables (§4 `(gen)`, §4.1). Its discharge point is then **each
use site** of that binding: `(var)` instantiates `π` at the use's types and discharges
it there. Deferred predicates are part of the binding's **scheme**, so this holds
across a module boundary exactly as it does within one — see OD6(a).

**OD3 — a non-ground predicate with no quantifying binder is ambiguous.** If no
enclosing binding generalizes `π`'s free variables, `π` has no discharge point at all
and MUST be rejected as ambiguous, save where OD4 applies.

**OD4 — the impl-channel exemption from OD3 is load-bearing, and is not a mode fork.**
Predicates arising from **interface-method occurrences** are recorded on a separate
channel from those arising from **instantiating a constrained binding**. On the
method-occurrence channel a non-ground predicate defers *unconditionally*: OD3 is NOT
applied to it in place. OD3 still governs that population, but out of band — the
genuinely unanchored variable is re-recorded onto the constrained-binding channel,
where OD3 runs.

> **Do not flatten this into one disposition.** Applying OD3 to the method-occurrence
> channel directly rejects benign non-ground occurrences — a bare receiver variable
> recorded outside any generalized-group window is in neither the deferrable set nor
> the out-of-band pass — which is an `Ambiguous instance` on essentially every program.
> The apparent alternative, widening the *deferrable-variable* set so OD2 absorbs them,
> is unsound: that set is shared with OD2 on the constrained-binding channel, and the
> genuinely ambiguous variable must stay out of it or OD3 would never fire at all.
> The split encodes two different facts about two different populations; it is not two
> modes of one judgment. [#863]

**OD5 — deduplication suppresses a REPORT, never a CHECK.** Two recorded predicates may
share a diagnostic-deduplication key and have **different verdicts**: a key is derived
from argument *head* constructors, while a matched conditional instance's `requires` is
checked *below* the head (§3), so `Debug (Color, Int)` and `Debug (Int, Int)` share the
key `Debug/__tuple2__` and disagree. A channel that skips the *check* on a key
collision therefore drops the failing sibling's rejection entirely. Deduplication is
admissible **only at emission**. [#863]

**OD6 — every consumer of the front end discharges the same set.** `check`, `run` and
`build` share one front end (§7.1) and MUST accept exactly the same programs. Stated
so it can be checked rather than asserted: *for every predicate `π` that any channel
records, `π` is ground at the same point under every consumer; hence by OD1 every
consumer discharges it, and by OD2/OD3 every consumer defers or rejects it identically.*
A construct that causes a channel to **record** `π` on one consumer's path and not
another's, or to **discard** it on one and not another, is a violation of this clause —
not a tuning knob, and not an acceptable approximation.

Two corollaries of OD6 are worth stating separately, because both were violated by
construction and neither is visible to a golden:

- **(a) Declared and inferred contexts defer identically, including across modules.**
  §4 draws no distinction **in how the context defers** — only in *where it comes from*,
  and that distinction is §4 `(gen-sig)`'s whole subject (#619): for a signed binding the
  scheme's context is the *declared* one `Q_sig`, for an unsigned binding it is the
  *inferred principal* context `P'` (`(gen)`).
  ⚠️ The two halves of that sentence must stay apart. **Sourcing is `(gen-sig)`'s
  declared-only ruling and is NOT relaxed by anything here**; a reading of this bullet
  that erases the sourcing distinction is one step from re-proposing the
  `Q_sig ∪ P'ᵢ` union `(gen-sig)` rejects. What OD6(a) says is only that *once* the
  context is determined, whichever rule determined it, the **scheme** carries it and
  `(var)` at each use site discharges it — identically, and identically across a module
  boundary. An implementation that sources a cross-module callee's predicates
  from a table populated only by **ascribed signatures** silently drops the unsigned
  binding's context at every importing call site — `check` greens, and whichever
  consumer *does* thread the evidence rejects or crashes. The store a consumer reads for
  a cross-module predicate must be the one that holds the binding's **scheme context**,
  under the same source-exact `(defining module, exported name)` key §8 requires of
  every cross-module table — never a bare name, and never a store whose population
  depends on which consumer is running.

- **(b) A window that exists to suppress OD3 must filter by DECIDABILITY, not discard
  wholesale — and not by groundness either.** An implementation that infers a body only
  to surface non-obligation errors, and rolls the obligation channel back afterwards to
  avoid OD3 false positives on that body's abstract variables, discards the body's
  **decidable** predicates along with its undecidable ones — a direct OD1 violation, and
  one that presents as `check` accepting what `build` rejects. The rollback must retain
  what OD1 requires and drop only what OD2/OD3 would have deferred.
  ⚠️ This corollary first shipped saying *"filter by groundness"*, and an implementation
  that did exactly that still violated OD1 on the structurally-refutable population —
  the arrow case OD1 now enumerates. **Restating OD1's test in a corollary is how the
  two drift**; this bullet therefore names the property and defers to OD1 for its
  content rather than paraphrasing it.

---

## 5. Method dispatch, including return position

A class method `m : ∀ā_C. C ā_C ⇒ τ_m` is, at the core level, a **projection**:

```
            P ⊢ C T̄ ⇝ e
(method) ──────────────────────────────
            ⌜m at C T̄⌝  =  methods(e).m
```

The dispatch type is `C`'s parameter `ā_C := T̄`. Crucially, **`T̄` is fixed by
the instantiation of `C` at the use site (§4 `var`), regardless of where `ā_C`
appears in `τ_m`.** Three cases:

- **Argument position** (`ā_C` occurs in an argument of `τ_m`, e.g. `eq : a → a
  → Bool`): the dispatch type is recoverable from a runtime argument's head, so
  arg-tag dispatch is a *sound refinement* (see below).
- **Result position** (`ā_C` occurs only in the result, e.g. `pure : a → F a`
  with class on `F`, or a `fromInt : a` with class on the result `a`): there is
  **no argument** whose runtime tag reveals the instance. Dispatch is possible
  *only* because `e` was determined statically by `var`/entailment. This is the
  formal reason return-position dispatch must go through the dictionary and
  cannot be an evaluator-time argument inspection.
- **Phantom position** (`ā_C` absent from `τ_m`): same — only the static
  dictionary determines it.

**Arg-tag dispatch is an optimization, not a semantics.** Inspecting a runtime
value's constructor to select an impl is sound **iff** the class parameter
occurs in an argument position whose head constructor uniquely determines the
**most-specific matching instance** (§3), *and* that argument is evaluated.
Overlap narrows this side condition sharply: a head tag alone does not
separate overlapping instances below one constructor — a `List` tag cannot
distinguish the `List Int` instance from the `List a` instance — so for any
class with such overlap, arg-tag selection at that constructor is *unsound*,
not merely incomplete. It is a refinement of `(method)` valid under a side
condition. It is **never** the meaning of
dispatch and must never be the *only* mechanism, because result/phantom-position
methods have no such argument. A semantics that decides dispatch in the
evaluator is therefore wrong in general; §7 makes the evaluator dictionary-
directed and demotes arg-tag to an admissible optimization.

### 5.1 What a dictionary must contain, and where an undispatchable method is rejected

§3 `inst` fills `methods` from `I`'s impl and `(method)` projects out of it. Three
well-formedness rules follow. None was written down before; each is stated here, at
the clause whose meaning it protects.

- **M1 — Impl completeness.** For `I = (instance Q ⇒ C T̄)`, `I` must supply a body
  for every method of `C` for which `CE` records no default. `inst` builds
  `methods = φ(impl_C)`; a missing method leaves `methods(e).m` undefined, so
  `(method)` has nothing to project and the program has no meaning. The rejection
  belongs at the **impl declaration**: it is a property of `I` and `CE` alone,
  decidable with no use site in hand, and there is no goal to attribute it to.

- **M2 — No extraneous methods.** `I` may not supply a body under a name that is not
  a method of `C`. Such a body inhabits no method scheme, so §3 **W3** has nothing to
  check it against and `(method)` can never project it: it is code the type system
  has not looked at and the program cannot reach. Rejecting it is the only reading
  under which W3's *"the dictionary's method values must actually inhabit those
  schemes"* quantifies over the whole dictionary rather than over an implementation's
  choice of which entries to notice.

  **Why M2 must be its own clause and cannot be left to M1.** When the extraneous name
  is a near-miss for a method with **no** default, M1 already rejects the impl, so M2
  adds only a better message. When it is a near-miss for a method that **does** have a
  default, M1 is silent by construction — the default fills the slot, and without M2
  the misspelled body would be unreachable, never typechecked, and the program would
  run the default while its author believed it ran the override. That case is the
  whole reason the clause exists, and it is the one M1 structurally cannot see.

  ✅ **ENFORCED, at resolve rather than typecheck** — `checkMethodMember`
  (`compiler/frontend/resolve.mdk:1252`) → `MethodNotInInterface`,
  code `R-METHOD-NOT-IN-INTERFACE`; so M2 is a description of current behaviour, not a
  narrowing. See the §11 row for the one thing that *is* owed (the diagnostic's
  location) and for the keying assumption it rests on.

- **M3 — A phantom method is legal at the declaration; an undetermined *use* is not.**
  A method `m : ∀ā_C. C ā_C ⇒ τ_m` whose `τ_m` mentions no `a ∈ ā_C` (§5's *phantom
  position*) is a well-formed declaration. §5 already says what such a method means —
  *"only the static dictionary determines it"* — and §3/§4 already say when that
  dictionary exists, so no new rule is needed for the accept case. What is needed is
  the placement of the **reject**, and it is not new either: it is `var` failing to
  discharge `C ?ā` with `?ā` unconstrained, which is the rejection any undetermined
  predicate already gets. Concretely, with `interface Mk a where mk : Int -> a;
  phantom : Int`:
  - `phantom` used inside `f : Mk a => …` is **accepted**. `Mk a` is in scope over the
    signature's rigid `a`, `assum` discharges it (§3 precedence — no `inst`, no
    search, nothing undetermined), and `(method)` projects `methods(e).phantom`. At a
    call `f (Red 1)`, §4 `var` instantiates `a := Red` against the matching impl.
  - `println (phantom : Int)`, with no `Mk` in scope, is **rejected**. The annotation
    fixes `τ_m`, which §5 says is irrelevant here, and nothing fixes `ā_C`.

  ⚠️ **The rejection has TWO mechanisms, and citing only the first is incomplete.**
  Where every visible instance of `C` has a rigid head (the shape above — `impl Mk
  Red` and nothing more general), `match(IE, C ?ā)` is **empty**: matching is one-sided
  from head to goal (§3), and no substitution on a ground head produces a
  metavariable, so `inst` is inapplicable and the rejection is `var` failing to
  discharge, as stated. Where a **fully-general** `impl C a` is also visible, that is
  no longer true: `match(IE, C ?ā)` is non-empty with a unique `⊑`-minimum, so `inst`
  would fire and pick it — and the program would be *accepted* with `?ā` still
  undetermined, which is meaningless rather than wrong-but-defined. In that case the
  rejection comes from **§6.2 T4**: a goal still not closed at quiescence is
  ambiguous, and is rejected there. The verdict is the same either way; the mechanism
  is not, and an implementation that only implements the first will accept the second
  shape.

  An implementation **MAY** warn at the declaration that a phantom method is usable
  only under an ambient assumption. **Acceptance is per use site.**

  ⚠️ **The parallel with §6.1 choice-point 2 goes only part of the way, and the part
  it does not go is the load-bearing one.** There, the declaration-time condition (a)
  *implies* the per-goal condition (c) — **with one exception, recorded at §6.1.2's
  own ⚠️: α-equal heads satisfy (a) and (b) while failing (c), so the implication is
  (a) ⇒ (c) *only for instance sets carrying no duplicate heads*. Read that exception
  as narrowing what follows, not as licensing it** — outside it, a declaration-time
  rejection is merely *early*, never wrong. Here it does not hold at all: *"this method
  mentions no class
  parameter"* and *"this use's class parameter is undetermined"* are **logically
  independent**. A phantom method has determined uses (the first bullet above), and a
  non-phantom method has undetermined ones. So a declaration-time *rejection* is not
  a conservative approximation of M3; it is a strictly broader and different rule,
  and every program in the difference is one this document resolves. That difference
  is tracked as **#1134** and pinned as
  `test/dict_fixtures/s5-phantom-determined-use-rejected.mdk`; its ambiguous sibling
  `…-ambiguous-use-rejected.mdk` is conformant on the verdict and stays conformant
  under M3, with the caveat in its header now settled rather than open.

  ✅ **Which of #1134's two directions this clause takes, so nobody has to re-derive
  it.** Both fixtures' headers enumerate two opposite resolutions and note that only
  one reaches them automatically. M3 takes the first: **§5 keeps licensing phantom
  dispatch, so the checker narrows to reject only the undetermined use.** Therefore
  `s5-phantom-determined-use-rejected.mdk` goes **red** the day that lands — which is
  the drain working — and is re-pinned to ACCEPT with value `7`. The second direction
  (forbid phantom methods in §5), under which nothing goes red and both rows need
  relabelling by hand, is **not taken**, and that contingency in the fixtures' headers
  can be struck rather than carried forward.

---

## 6. Coherence

**Definition (coherence).** Elaboration is *coherent* if the meaning of a
source program is independent of the elaboration derivation: whenever
`P | Γ ⊢ e ⇝ e₁ : τ` and `P | Γ ⊢ e ⇝ e₂ : τ`, then `e₁ ≡ e₂` (observationally
equivalent in the core). Equivalently, every predicate has a *unique* evidence
value up to `≡`.

Coherence is the property the recurring bugs violate. It is guaranteed by the
following conditions; the implementation must enforce them or reject the
program.

- **C1 — At most one most-specific instance.** For every goal `C τ̄` **that reaches
  `inst`** — every predicate the elaboration poses that (i) §3's precedence leaves
  undischarged by `assum`/`super`, (ii) §4 `gen`/`gen-rec`/`gen-sig` does **not**
  abstract into the enclosing binding's context as a dict parameter, and (iii) is
  **closed at the point `inst` is applied to it** (§6.2 T3) — the matching set
  `match(IE, C τ̄)` (§3) has **at most one** `⊑`-minimal element — equivalently (the
  set is finite), and whenever it is non-empty, a `⊑`-minimum: one matching instance
  at least as specific as every other. **An EMPTY matching set is not a C1
  violation.** It is `inst` inapplicability (§3) — the missing-instance rejection,
  a different verdict reached for a different reason. C1 governs *which* of several
  instances answers a goal, never *whether* one exists; read otherwise, every
  program with a missing instance "violates C1", which is not what any part of this
  document means (see §5.1's phantom-method rejection, which turns on `match(IE, C
  ?ā)` being empty and attributes the verdict to `var`/T4, not here). Overlap — more
  than one matching head — is permitted *iff* this holds. Two `⊑`-incomparable
  matching instances with no matching instance `⊑`-below both make the goal
  **ambiguous overlap**, and the program is rejected; so are α-equal duplicate heads
  (mutually `⊑`, hence **two** `⊑`-minimal elements, not one). This is the retained
  coherence guarantee: most-specific-wins is a total tie-break, not a licence to
  pick. (The **original** C1 — *at most one matching instance*, a different condition
  from this one's *at most one `⊑`-minimal* instance — is the special case where
  every matching set is a singleton, which is why the relaxation is conservative over
  previously legal programs.)

  ⚠️ **Read "at most one" strictly throughout, and do not restore "unique" from the
  older wording.** This clause bounds the winner from **above only**. It says nothing
  about a winner *existing* — that is `inst`'s applicability, a separate question with
  a separate verdict — so C1 alone no longer delivers **totality** of entailment. Every
  clause that leaned on it for totality is corrected to say so: §3's **well-formedness**
  paragraph, §3's **`min⊑` restatement**, §3's **resolution-determinism** sentence,
  §3's **`inst` note**, and the **coherence theorem** below. ⚠️ **That list is named
  rather than counted on purpose** — an earlier draft of this ⚠️ said *"the three
  places"* and was wrong the moment a fourth was found, which is what a count in a
  document like this always does. Re-derive it rather than trust it: sweep for `C1` by
  name, then again for the unnamed restatements (`unique`, `total`, `at most one`,
  `minim*`), which is where the misses were.
  The clause title was *"Unique most-specific instance"* until this revision; that
  word was doing existence-work and at-most-one-work at once, which is exactly the
  conflation this repair removes.

  ⚠️ **The quantifier is the goals `inst` DECIDES, not the ground goals.** C1 read
  *"for any ground `C τ̄`"* until this revision. The strongest reading of that wording
  is not idle and very nearly closes the gap on its own, so it is worth stating before
  it is set aside: quantify over **every** ground predicate, and read the condition as
  *no ambiguous overlap* among the instances matching it. That is satisfiable, and it
  is **decidable** despite the infinite quantifier — for each `⊑`-incomparable pair
  whose heads unify with mgu `θ`, ask whether some declared head is α-equal to `θ`'s
  common instance, which is precisely §6.1.2's `Pair`-triple test. It also subsumes the
  rigid goals: a rigid variable behaves as a fresh constant under one-sided matching,
  so a rigid goal's matching set coincides with that of a ground predicate, and
  quantifying over *all* ground predicates catches it.

  **What defeats that reading is §6.1.2's own commitment — *"acceptance is
  per-goal."*** Quantified over every ground predicate, the condition rejects a program
  declaring `C (Pair Int a)` and `C (Pair a Int)` and nothing else, *even if no goal in
  the program ever reaches `C (Pair Int Int)`*. Condition (c) — the semantics this
  document adopts — accepts exactly that program. So C1 is not a condition on the
  instance environment in the abstract; it is a condition at the goals a program
  **poses**, and it must name that class correctly. The goals a program poses are not
  all ground: §3's precedence paragraph is explicit that given `S a` in scope the goal
  `S (List a)` is *not* an assumption, so `assum` stays silent and `inst` commits;
  §6.1.3 is explicit that the commitment is **final**. A rigid goal is put to `min⊑`
  and answered by it, so it is a goal at which the tie-break must be total. That class
  — the goals `inst` decides that are not ground — is what the old wording left outside
  the condition, and it is the whole of what this revision adds. §3's determinism
  paragraph already cites C1 with the corrected quantifier — **"wherever `inst`
  fires"** — so this is C1 stating what the rest of the document already attributes to
  it.

  ⚠️ **That sentence is also a cautionary case, and it is worth naming because this
  revision nearly repeated it.** It read *"which §6 C1 **requires to exist uniquely**
  wherever `inst` fires"*, and an earlier draft of this paragraph quoted it in full,
  approvingly, as evidence for the quantifier. Its second half attributes **existence**
  to C1 and restores the very word the ⚠️ above says not to restore — so one sentence
  was at once the best support for the requantification and a casualty of the
  at-most-one repair. It is corrected in §3. **When a sentence is cited as support, the
  half not being quoted is exactly the half to check.**

  **The class is the CLOSED goals** — §6.2 **T3**: `inst` may fire only on a goal
  every variable of which is either quantified by the scheme just produced or already
  ground — that neither §3's precedence discharges nor §4's `gen` abstracts. That is
  the ground goals **plus** the rigid-variable ones.

  ⚠️ **Exit (ii) is not decoration, and a gloss that omits it over-includes by a whole
  class.** A residual predicate over a **generalizable** variable is deferred by `gen`
  and becomes a dict parameter (§4's `P'`; §6.1.3's *second* sentence says so outright) —
  it is never posed to `inst`, and C1 has nothing to say about it. Without exit (ii)
  a reader gets the opposite: an *inferred* binding whose residual predicate is
  `C (T a Int Int)`, against `⊑`-incomparable `C (T a b Int)` and `C (T a Int b)`, would
  be rejected **at its definition with no goal having reached `inst`** — the same fault
  this clause rejects the commitment-site reading for, one exit over. (Exit (iii)'s
  *"at the point `inst` is applied to it"* is load-bearing for the same case and is why
  it is spelled that way: T3 indexes closedness to the scheme just produced, but the
  question C1 asks is about the goal `inst` is handed, so the two must be read at the
  same instant.) ⚠️ Do not read **T6**'s spelling of the closed class — *"every goal of
  every generalized binding, and every ground goal"* — as C1's quantifier. T6 is
  characterizing **closedness**, which is a strictly larger class: it includes the
  goals `gen` abstracts, and exit (ii) removes those.

  Closedness is *part of the quantifier*, not a gloss on it, and the alternative
  reading — "every goal at which an implementation in fact commits" — is rejected
  here, for two reasons.

  It would **forbid a legal program.** Under §6.2 **T4** a *non-closed* goal — say
  `D (T ?z Int Int)` with `?z` determined by a later group — is **deferred, not
  decided**, and is resolved exactly once at quiescence. At the moment it is posed it
  is undischarged by `assum`/`super` and its matching set may well have no minimum;
  a C1 quantified over commitment sites would reject it, while T4 and T6 say it is
  well-formed and that deferral is the whole point. And it would make C1's extent
  **implementation-relative**: *"does program P satisfy C1?"* would have no answer
  without knowing where some particular — possibly buggy — implementation happened to
  commit. Every other condition in this section is a property of programs, and the
  coherence theorem below reads C1 as one. An implementation that commits at a
  non-closed goal (§11's T3/T4 row records one) is violating **T3**; C1 is not the
  clause that catches it, and stretching C1 to cover it would cost C1 its status as a
  property of the program.

  "Reaches" is deliberate in the other direction as well: the class is *not* delimited
  by `inst` **succeeding**. `inst`'s own minimality premise makes the rule inapplicable
  where no minimum exists, so a condition quantified over the goals at which `inst`
  succeeds would be vacuous — it would assert a minimum exists exactly where one was
  already found. For the **`assum`** leg, whether a goal reaches `inst` is settled
  before any matching set is compared: `assum` is a lookup in `P`. The **`super`** leg
  is not settled that cheaply — its premise `P ⊢ C T̄ ⇝ e` is an arbitrary entailment
  that may itself need `inst` — so "decided in advance" is a claim about `assum` only,
  and is stated as one. No soundness consequence follows: C2 is what requires the two
  answers to agree.

  Making C1's *scope* a function of the ambient `P` — precedence is — is not §6.1.1's
  rejected alternative, which makes the *winner* a function of `P`. Selection at a goal
  that reaches `inst` remains a function of `(IE, π)` and nothing else, exactly as C3
  requires. **C2 needs one clause more than C3 does**, and the site must be named
  carefully. C2's obligation is *not* discharged at the instance **head**: §3 `inst`
  fills `supers.D` by entailment **at the construction goal's instantiation**, and
  §6.1.4 calls pre-resolving supers against the general head at declaration *"the
  tempting-but-wrong implementation"* — so no `D T̄` goal at the declared head is ever
  posed to `inst`, and C1 owes it nothing. Where C2 genuinely gains is §6.1.4's
  **rigid construction goal**: when a general `C`-instance is constructed at a goal
  whose variables are rigid, its `supers.D` is resolved at *that* goal, and §6.1.4
  asserts the result agrees with what top-level resolution at the same goal would
  produce. That agreement needs at most one winner **at a rigid goal** — which the old
  quantifier did not supply and this one does. So the `P`-dependence reaches C2 too,
  and it is a gain rather than a loss: under the old wording that goal had **no** C1
  backing at all.

  ⚠️ **The requantification is a TWO-WAY move, and BOTH directions are live.** The new
  class is not a superset of the old one, so no reader may lean on "strictly wider" —
  and the half that leaves is **not** inert, which an earlier draft of this paragraph
  wrongly claimed.

  **What leaves is an acceptance WIDENING, deliberate and in (c)'s direction.** Take
  `impl D (Pair Int a)` and `impl D (Pair a Int)` — `⊑`-incomparable, no third
  instance below both — together with

  ```
  f : D (Pair Int Int) => Pair Int Int -> Int
  f p = dv p
  ```

  and **no caller**. `f`'s body poses the *ground* goal `D (Pair Int Int)`, which
  `assum` discharges from `f`'s own context, so it never reaches `inst`. Under the old
  ground quantifier that predicate was in C1's scope, had two `⊑`-minimal elements, and
  the program was **rejected**; under this one it is **accepted**. That is the correct
  verdict under per-goal semantics — no evidence for the predicate is ever constructed
  in this program, so no coherence question arises — but it *is* a widening, and the
  honest statement of it is: **unobservable in any program that actually constructs the
  evidence** (a caller re-poses the predicate where `inst` decides it, and C1 binds
  there), not "inert".

  **What arrives — the rigid goals — is the narrowing half**, and it changes no
  program's status under **this document**: §3 `inst` was already inapplicable at any
  goal, ground or rigid, whose matching set has no `⊑`-minimum, so a program posing one
  was already unelaborable. What changes there is the **obligation** on an
  implementation, which is audited clause by clause (§11): ambiguous overlap at a rigid
  goal owes a diagnostic, the check may not be gated on groundness, and such a goal may
  not be answered from a fallback. §11's C1 row records why the present
  declaration-time site does not discharge this half, and what currently stands in
  for it.

  That the change is not merely editorial is best seen in **two clauses elsewhere in
  this section that cited a C1 which did not reach them**:
  **§6.1.4**'s parenthetical asserts that at a *rigid-variable* construction goal the
  super-dict agrees with what top-level resolution at that same goal would produce,
  which needs at most one winner **at that rigid goal**; and **C2**'s pinning of *which*
  `D`-dict fills `supers.D` inherits that same goal (see the C2 paragraph above — the
  site is the construction goal, not the declared head). ⚠️ Note the claim is exactly
  *"cited a C1 that did not reach them"* and not *"true only under the corrected
  quantifier"* — an earlier draft said the latter, which does presupposition-failure
  work rather than truth-value work, since §3 `inst`'s minimality premise already
  forecloses the bad case under either quantifier. The weaker claim is the true one and
  is sufficient. ⚠️ The **coherence theorem**'s sketch is *not* a third witness, though an
  earlier draft of this paragraph offered it as one: its *"total on the goals
  elaboration poses"* is repaired below for the at-most-one reading, not for the
  quantifier, and citing a sentence this same revision had to fix would have been
  circular.

- **C2 — Superclass consistency (an invariant, largely implied by C1+C3+C4).**
  For every instance `Q ⇒ C T̄` and every `D ā_C ∈ super(C)`, the evidence in
  `supers.D` must be `≡` to resolving `D T̄` independently via §3 — the nested
  superclass dict equals the canonical `D`-dict. Since `supers.D` *is* built by
  that same resolution under one global `IE`, C2 follows from deterministic
  resolution (C3) over unique most-specific matches (C1, C4); it is the invariant to check,
  not an independent obligation. The **transitive (diamond) form** is the part
  worth stating outright: if `C` reaches a base class `B` along two superclass
  paths (via `D` and via `E`), both must yield `≡` `B`-evidence — again
  guaranteed by C1+C3, but the first thing a flat or path-sensitive
  representation breaks. Under overlap, C2 additionally pins **which**
  `D`-dict: `supers.D` must be the evidence of the *most-specific*
  `D`-instance at the construction goal's instantiation — which is exactly
  what §3 builds, since `supers` is filled by entailment at construction, not
  pre-baked against the (possibly general) instance head at its declaration.
  A super-projection that reaches a general `D`-dict while an independent
  top-level goal `D τ̄` resolves to a specific one is a C2 violation even
  though both are `D`-evidence; no genuine most-specific/C2 conflict remains
  once supers are resolved per construction goal (§6.1, point 4).
- **C3 — Resolution determinism.** Entailment (§3) returns the same evidence
  regardless of search order; with C1 holding, `inst` is deterministic — the
  `⊑`-minimum is unique, so most-specific selection cannot reintroduce order
  sensitivity. Where more than one rule could fire, determinism does **not**
  rest on the rules agreeing: §3's **precedence** (`assum`/`super` before
  `inst`) makes the choice, so entailment is a function of the goal *and the
  scope* `P`, never of search order. `assum` and `super` both discharge a goal
  with evidence resolved at the **construction site's** instantiation; C2 is
  what pins that evidence to be the most-specific one *there*. Neither is
  required to equal what an independent `inst` would build at a **rigid**
  use-site goal — and where they differ, the in-scope evidence wins (§3). That
  is exactly what makes §2's uniformity of nested resolution realisable, and it
  is not an incoherence: coherence quantifies over derivations of the **same**
  judgment, and a rigid use-site goal and the construction goal its evidence was
  built at are different judgments (§6.1.3).
- **C4 — Single instance environment.** `IE`/`CE` are *global* after import
  resolution (§8). Two modules resolving the same predicate must consult the
  same instance set and produce the same evidence — otherwise C1/C2 hold only
  locally and coherence fails across module boundaries.

**Uniform resolution (corollary of C1+C3+C4 and the single judgment).** There
is exactly one entailment judgment (§3), and *every* resolution position
consults it: a top-level goal, a `var`-site residual predicate (§4), a method
dispatch whether the class parameter sits in argument, result, or phantom
position (§5), a nested instance-context (`requires`) obligation (§3 `inst`),
and a superclass projection target (C2). All of them therefore resolve a
given goal to the same — most-specific — evidence. This corollary is worth
stating because it is what #203 violated: an implementation with several
resolution code paths must make **all** of them perform `min⊑` selection; a
path that agrees with the others on non-overlapping instance sets but falls
back to first-match (or declaration order, or crashes) under overlap is
exactly the defect class of §10.

**Coherence theorem (target).** If C1–C4 hold, elaboration is coherent.
(Argument sketch under overlap: W1+W2+C1 make entailment a **single-valued
partial** function of `(IE, CE, P, π)` on the goals elaboration poses — `assum` is keyed
by `P`, `super` by the already-unique sub-derivation, and `inst` by the
`⊑`-minimum, which is unique where it exists and which no search order can vary
(C3). C4 fixes one global `IE`, so "the" minimum is the same at every site. Two
derivations of the same judgment thus produce `≡` evidence pointwise, and
elaborated terms differ at most in the derivation path, not the evidence — the
same argument as the non-overlapping theorem with "the unique match" replaced by
"the unique minimum".)

⚠️ **Coherence is what this theorem claims; TOTALITY is not, and the earlier
wording ("make entailment total on the goals elaboration poses") over-claimed.**
C1 bounds the winner from above only, so a goal with an **empty** matching set
leaves entailment undefined — the missing-instance rejection, which is a *failed
elaboration*, not an incoherent one. Coherence quantifies over derivations of the
same judgment; a judgment with **zero** derivations satisfies it vacuously. So
the theorem is unaffected by the at-most-one reading, and only its sketch's
choice of word was wrong.

### 6.1 Design choice-points in the overlap regime (owner-visible)

Most-specific-wins has principled variants. This spec commits to the choices
below; each is **flagged** because a defensible alternative exists and moving
to it later is a semantics change, not a bug fix.

1. **Specificity compares heads only, not contexts.** `⊑` (§3) ignores the
   instance contexts `Q` — this matches the motivating intuition
   (`impl Foo Int ⊏ impl Foo a`) and GHC's `OVERLAPPING` regime.
   *Alternative:* treat a more-constrained instance as more specific
   (`Eq a ⇒ C (List a)` beating `C (List a)`). **Rejected here:** the winner
   would then depend on what is *provable* at the goal site, making selection
   a function of the ambient `P` rather than of `(IE, π)` — the same ground
   goal could resolve differently under different contexts, which forfeits C3
   and reintroduces path-sensitivity, the exact disease this revision cures.
   Consequence to accept knowingly: two instances with α-equal heads and
   different contexts are *ambiguous*, never ranked. **Recommended: head-only
   (as specified).**

2. **Per-goal unique minimum, not total order, not global comparability.**
   Three candidate coherence conditions, strongest first:
   - (a) *global comparability*: any two instances of a class whose heads
     unify must be `⊑`-comparable — checkable once at declaration time,
     earliest errors; implies (b);
   - (b) *per-goal total order*: at every goal that reaches `inst` the matching
     set is totally ordered by `⊑` — **pairwise `⊑`-comparability**, i.e. a
     total *preorder*, since §3 makes `⊑` a preorder on instances and only a
     partial order on heads *up to renaming*; implies (c) ⚠️ **except at
     α-equal heads — see the hole recorded below**;
   - (c) *per-goal unique minimum*: at every goal that reaches `inst` the
     matching set has **at most one** `⊑`-minimal element — a unique minimum
     whenever it is non-empty — which is what C1 states.
   (c) is exactly what `inst`-determinism requires — no more. The separating
   case: `C (Pair Int a)`, `C (Pair a Int)`, `C (Pair Int Int)` all declared.
   At the goal `C (Pair Int Int)` the first two are incomparable, but the
   third is `⊑` both — (c) accepts with an unambiguous winner; (a)/(b)
   reject. **Recommended: (c) as the semantics** (it is also GHC's condition),
   with the check performed at each `inst` application during elaboration —
   still fully static, never at run time. An implementation MAY additionally
   warn at declaration time on (a)-violations as an early diagnostic, but
   acceptance is per-goal. Note the task-level intuition "overlap is allowed
   iff totally ordered by specificity at each ground goal" is condition (b)
   **under C1's old quantifier**: stronger than needed at the goals it does
   cover — the difference showing on instance sets like the `Pair` triple
   above — and silent at every rigid goal, which is the half §6 C1's ⚠️
   repairs.

   "Goal that reaches `inst`" is C1's quantifier and carries C1's meaning: the
   **closed** goals — the ground ones **and** the rigid-variable ones. Both (b)
   and (c) are per-*goal* conditions, so both inherit it; (a) is quantified over
   declared instance **pairs**, not over goals, so its own statement is unchanged.

   ⚠️ **But the ladder has a hole exactly where C1 has its explicit carve-out, and
   no migration may lean on the chain across it.** Two **α-equal** heads are
   mutually `⊑`. They therefore satisfy (a) (they are `⊑`-comparable) *and* (b) (a
   two-element set, pairwise comparable, is totally preordered) — while C1 rejects
   them outright, because mutual `⊑` gives **two** `⊑`-minimal elements, not one.
   **So the broken link is (b) ⇒ (c), not (a) ⇒ (b)**, and the composite that fails
   is the one a migration would actually want: **(a) ⇏ (c)**, hence **(a) does not
   subsume C1.**

   That placement depends on reading (b)'s "totally ordered" as *pairwise
   comparable*, which is why the bullet now says so outright. It is the only reading
   available: §3 makes `⊑` a **preorder** on instances — antisymmetric on heads only
   *up to renaming*, and α-equal heads are exactly the case where the quotient
   matters — so an antisymmetric reading of (b) would not be a condition on the
   matching set of *instances* at all. Under the antisymmetric reading (b) fails
   too, and the hole moves to (a) ⇒ (b); **the ladder is broken somewhere either
   way, and (a) ⇏ (c) is the invariant conclusion.**

   An implementation MAY close the hole by demanding *strict* specificity in one
   direction rather than mere comparability, and §11's C1 row records that this one
   does — but that is the implementation being stronger than (a), not (a) being
   strong enough. **Do not derive C1's rigid half from (a) at the level of this
   document.** §5.1's *"(a) implies (c), so a declaration-time rejection is merely
   early"* carries this exception explicitly.

   What *was* true, and was a fact about the tree rather than a theorem about (a):
   the strengthened declaration-time check rejected every `⊑`-incomparable
   overlapping pair before any goal was posed. **As of 2026-08-01 the tree has taken
   this bullet's licence:** that pair is now a declaration-time **warning**
   (`W-INCOMPARABLE-IMPLS`) and acceptance is per-goal, decided by `min⊑` — so C1's
   rigid half is live. The *extra* strength survives the change and must: a
   **mutually-`⊑`** pair is still a hard error, since it satisfies (a) while failing
   C1, which is the hole this ⚠️ records. §11's C1 row carries the probes.

3. **Non-ground goals: selection commits at the elaboration site
   (specialization is not retroactive).** `inst` fires on the goal *as it
   stands where it is resolved*. A goal over **generalizable** variables is
   deferred by §4 `gen` (abstracted as a dict parameter) — standard, and it
   preserves the caller's ability to supply most-specific evidence. But a
   goal over a **rigid** (signature-bound) variable — e.g. `Default (List a)`
   inside `f : ∀a. Default a ⇒ …` — matches only the general instance and is
   discharged there, once, when `f` is elaborated. If `f` is later used at
   `a := Int`, `f`'s body still runs the general instance's evidence (closed
   over the caller's `Default Int` dict); it is **not** retroactively
   re-resolved to `Default (List Int)`. So a ground predicate can receive
   different evidence at two *different* judgments — one where it was ground
   at resolution time, one arising by instantiating an already-elaborated
   polymorphic binding. This does **not** violate §6 coherence (which
   quantifies over derivations of the *same* judgment) and is the standard
   price of specialization under separate elaboration — GHC behaves
   identically — but it is real and observable, and this spec states it
   loudly rather than letting it be discovered.
   *Alternatives:* (i) reject `inst` at any non-ground goal that a strictly
   more specific instance *unifies* with (a substitution-stability
   requirement) — restores "one evidence per ground predicate, globally" but
   rejects most of the generic code that motivates the general instance at
   all, since such code is precisely "use `C (List a)` at unknown `a`";
   (ii) monomorphize/re-elaborate per instantiation — whole-program
   compilation, incompatible with §8's separate, identity-keyed elaboration.
   **Recommended: commit-at-elaboration-site (as specified). FLAG:** this is
   the one place most-specific-wins is weaker than it may look from the
   surface; the owner should confirm this trade explicitly.

4. **Superclasses and diamonds under overlap — no conflict, one obligation.**
   Could most-specific selection fight C2? Only if sub-evidence were resolved
   at a different goal than top-level evidence. The rule that prevents it:
   supers and instance contexts are discharged **at the construction goal's
   instantiation** (§3 `inst`, §2 "uniformity"), so a general `C`-instance
   constructed at a ground goal carries the *specific* `D`-super-dict for
   that ground type, and both arms of a superclass diamond resolve `B` through
   the same judgment at the same types, yielding `≡` evidence (C1+C3). The
   tempting-but-wrong implementation is pre-resolving a polymorphic
   instance's supers once, against its general head, at declaration — that
   turns every ground construction into a C2 violation under overlap. (At a
   *rigid-variable* construction goal the super-dict is the general one, by
   point 3 — consistently with what top-level resolution at that same goal
   would produce, so uniformity is preserved there too.)

### 6.2 Scheduling, and when `inst` may commit

§3 requires selection to be a function of `(IE, CE, P, π)` and of nothing else —
*"never of search order, declaration order, or resolution position"*. An
implementation that elaborates a program in pieces therefore owes a statement of
**when** each piece's goals are decided: a commitment taken before a goal's type is
final is a commitment taken at a different `π` than the one the program means, and
"which piece I was in when I committed" is precisely a resolution position. This
subsection is that schedule. It fixes the semantics; how many passes realize it is
an implementation matter.

- **T1 — Binding groups.** Bindings are partitioned into **groups**. A group is a
  strongly-connected component of the reference graph over the bindings of **one
  module**: a mutually-recursive set is one group (`gen-rec` gives it one shared
  `λd̄.` prefix over the whole group); a non-recursive binding is a group of one.
  Groups are elaborated in a topological order of that graph, dependencies first, and
  modules in the loader's own dependency-first order — so the whole graph's group
  order is the concatenation. That order exists, and no group can reference a later
  group: within a module, a reference from an earlier group to a later one would put
  both in the same SCC; across modules, an import cycle is rejected by the loader, so
  **no group ever spans two modules**.

  ⚠️ **The node set is every binding whose body is inferred, not just the ones that
  look like a dependency graph's nodes.** `impl` method bodies, class default bodies,
  and any other body the elaborator visits are bindings under T1, and a schedule that
  enumerates only top-level function definitions has silently left them unscheduled —
  which reads as "they work" for exactly as long as something else happens to infer
  them at a point where the schedule's guarantees happen to hold.

- **T2 — What a later group may observe of an earlier one.** A later group observes
  an earlier group's **scheme**: its quantifiers, its principal context (`P'` for
  `gen`, `Q_sig` for `gen-sig`), and the arity and order of its dictionary parameters
  (§8 I1). It observes **nothing else** — not which instance any goal inside the
  earlier group resolved to, not any evidence value, not any route. This is what
  makes `var` at a use site a *fresh* application of §3 (§8 I3) rather than a lookup
  of somebody else's answer, and it is why two use sites of one binding may legally
  receive different evidence.

  One consequence must be stated rather than left to be discovered: for a
  **non-generalized** (value-restricted) binding the "scheme" a later group observes
  is a monotype containing **live metavariables**, physically shared with the
  observer. A later group can therefore *ground* an earlier group's type. That is not
  a leak — it is the ordinary meaning of a monomorphic binding — but it is exactly
  the channel T3 and T4 exist to regulate.

- **T3 — Generalization is final per group; `inst` is not.** `gen`/`gen-rec`/`gen-sig`
  fire when a group finishes, and the scheme they produce is final. `inst` is
  different. It may fire on a goal only when that goal is **closed**: every variable
  in `π` is either quantified by the scheme just produced (so no later unification
  can reach it) or already ground. The goals of a **non-generalized** binding are not
  closed at their group's end, by T2's last paragraph — so committing them there
  would make instance selection a function of where a group boundary happened to
  fall, which §3 forbids in as many words.

- **T4 — Quiescence.** Route resolution, `inst` commitment for goals not closed at
  their group's end, and numeric-literal defaulting for the same (§6.3) run as
  **whole-graph post-passes at quiescence** — after every group of every module of
  the graph has been inferred, in one pass, in one written order. At quiescence every
  metavariable that anything in the program can determine has been determined, so the
  goal `inst` sees is the goal the program means. A goal still not closed at
  quiescence is genuinely undetermined: nothing in the program fixes it, and it is
  **rejected as ambiguous** — never committed to a default instance, and never left
  to an engine to pick.

  Note what quiescence is *not* waiting for. `IE` and `CE` are assembled once, before
  any body is elaborated, and do not grow during elaboration (C4, §8 I2/I5) — so the
  only thing that changes between a group's end and quiescence is **the goal**. If
  `IE` could still grow, deferring would be a second, independent order-dependence
  rather than a cure for the first; it is I5 that makes T4 a purely beneficial delay.

  🚨 **Normative migration constraint: T4 MUST NOT be implemented before I5.** This is
  not advice about ordering work, it is a condition on T4's soundness. While candidacy
  is still assembled incrementally — the topological-prefix behaviour §11's I5 row
  records — deferring some goals to quiescence puts **two different candidate sets in
  one program**: a closed goal commits at its group's end against the prefix visible
  *then*, while a deferred goal resolves against the whole accumulation. Two goals in
  the same program would then be answered from different instance environments, which
  is a C4 violation outright and a C3 violation in effect — and, unlike the
  order-dependence T4 exists to cure, this one would be **created by the deferral
  itself**. An implementation that lands T4 first has made the problem worse in the
  name of fixing it.

- **T5 — The alternative is REJECTED, explicitly.** The alternative schedule is
  *freeze at the module boundary*: when a module closes, reject any of its goals
  still carrying a free metavariable as ambiguous, so that commitment is only ever
  taken on a closed goal. It is **sound** — it never commits at a non-final type —
  and it is nearer to what implementations naturally do, since a module's inference
  state is normally torn down when the module closes. It is rejected for two reasons,
  neither of which is convenience:
  1. **It narrows the language.** A binding whose type only a later module determines
     is well-formed under T4 and rejected under T5, with a diagnostic the author
     cannot act on where it is reported (*"ambiguous"* — but it is not; a later
     module determines it). Every other acceptance change in this document's vicinity
     is a widening carried by a program that could not previously be written. A
     narrowing has no such witness, and this one has no compensating soundness gain
     over T4.
  2. **It makes module partitioning semantically significant.** Moving two bindings
     between files, changing nothing else, would change whether the program is
     accepted. §3's order-freedom requirement is exactly the refusal to let that class
     of fact matter, and C4's single global `IE` is the same refusal one level up.

- **T6 — What T4 costs, stated rather than discovered.** Under T4 the elaboration of a
  module is a function of the **whole loaded graph**, not of the module and its
  imports. For the bindings T4 covers — the non-closed ones — that forecloses
  elaborating a module once and reusing the result across different entry graphs.
  This is the same price §6.1.3's alternative (ii) is rejected for, and it is bounded
  in the same way: it applies to non-closed goals **only**. Every *closed* goal —
  which is every goal of every generalized binding, and every ground goal — still
  commits where it stands, at its own elaboration site, per §6.1.3, unaffected.

  ⚠️ **T4 is not retroactive re-elaboration, and that distinction is the whole of why
  it is compatible with §6.1.3.** §6.1.3 refuses to *re-resolve* a goal already
  discharged at a rigid or generalizable variable, when a later instantiation would
  make a more specific instance match. T4 re-resolves nothing: a non-closed goal is
  discharged **exactly once**, at the one type the program gives it, later than a
  naive schedule would have. Reading T4 as licence to revisit a settled commitment
  reinstates alternative (ii) and is not what it says.

### 6.3 Defaulting for numeric literals

An integer literal elaborates as a `Num`-constrained value, so a program with no
other constraint on a literal's type poses a goal `Num ?a` with `?a` undetermined.
Rejecting every such program is unusable, so the language **defaults** the variable.
Defaulting is a *solving* step, not an inference step, and it owes three statements:
where it sits, which variables it may touch, and what it is not allowed to do.

- **D1 — Placement.** Defaulting is the **last determination step** at the boundary it
  runs at, and therefore runs:
  * **after** the boundary's bodies are inferred — nothing later can constrain the
    variable *through the body*;
  * **before** generalization at that boundary — a defaulted variable must not be
    quantified, or the choice becomes per-use rather than per-literal;
  * **before** any check that rejects on an undetermined variable: the ambiguity
    rejection of §6.2 T4, and the obligation checks of §4 `var`.

  The third is normative, not tidiness. Run in the other order, a program whose only
  problem is an undefaulted literal is reported as an *interface ambiguity* — a
  diagnostic about a rule the program did not break, pointing at machinery the author
  never used.

  ⚠️ **"The boundary it runs at" is plural, and reconciling that with §6.2 T4 is part
  of the rule, not a loose end.** A candidate variable the boundary **closes** — one
  it is about to quantify, or one nothing outside it can reach — is defaulted **at
  that boundary**, before it generalizes. A candidate variable that survives its
  boundary as a live metavariable (§6.2 T2's non-generalized case) has not had its
  last chance yet: something later may still ground it, and defaulting early would
  pre-empt a determination the program actually makes. It is therefore defaulted **at
  quiescence** (T4), under this same D1 ordering relative to the checks that run
  there. Read either half alone and D1 and T4 look like two different placements. They
  are one rule — *default at the last point that can still determine the variable* —
  applied at the two points where "last" can fall.

- **D2 — Defaulting never discharges.** Defaulting **substitutes**: it makes `?a`
  ground, and does nothing else. Every predicate on that variable — including `Num`
  itself — is afterwards checked exactly as it would have been had the program
  written the type out. A defaulted variable carrying a predicate the default does
  not satisfy yields a **rejected** program, never a silently accepted one. An
  implementation that treats a defaulted variable's obligations as already discharged
  has turned a convenience into a soundness hole.

- **D3 — Which variables (the taint rule).** A variable is a defaulting **candidate**
  iff
  1. some predicate on it is `Num`, **and**
  2. **no channel that outlives the boundary can determine it.**

  Clause 2 is the substantive half, and it must be stated **by channel**, not by
  syntactic position, because the available channels differ by binder kind. The
  channels are: an **argument** the caller supplies; the binding's own **result**,
  when the binding's type is a *declared* scheme somebody else instantiates; and a
  **dictionary** — an abstracted `d̄` (§4 `gen`), the method dictionary of an
  `impl`-method body, or the matcher `φ` of the instance head that body is checked at
  (§3 `inst`) — each of which lets a caller or a construction goal choose the
  variable.

  🚨 **Clause 2's dictionary channel is evaluated as the channels stand BEFORE
  generalization, and that is a resolution of a circularity, not a refinement.** At a
  binding whose type is *inferred*, whether it abstracts a `d̄` at all is an **output**
  of `gen` — which D1 orders *after* the test that would consult it. Read naively,
  clause 2 asks a question whose answer does not exist yet. The rule is therefore:
  **only a `d̄` that exists independently of this boundary's generalization decision is
  a channel** — a `gen-sig` binding's declared `d̄_sig`, an `impl`-method body's method
  dictionary, the matcher `φ` of the instance head it is checked at. A dictionary
  parameter that generalization *would* mint for this very binding is **not** a
  channel, because the whole point of defaulting is to decide, first, whether there is
  anything left to generalize over.

  Two consequences fall out. The first is the direct application of that resolution,
  and it is a **flagged design choice only in which direction the circularity is cut**:
  * **At a binding whose type is inferred and about to be generalized, result position
    is NOT a determination channel.** `let n = 1` grounds; it does not generalize to
    `∀a. Num a ⇒ a`. This is a deliberate monomorphism-for-`Num` restriction — the
    same trade Haskell's monomorphism restriction and `default` declaration make.
    *Alternative:* generalize, and let each use choose. **Rejected here**, because it
    makes the representation of the literal `1`, and hence which `Num` impl runs, a
    property of the *use site* rather than of the literal — the very
    position-dependence this rule exists to remove.
    ⚠️ **Cross-reference §4.1 G4, which reads as a contradiction of this bullet and is
    not one.** G4 says a local binding's own predicates are abstracted on it and
    discharged per use site — which for `let n = 1` would mean a `Num` dictionary
    parameter and a per-use choice, exactly what this bullet forbids. They reconcile
    **only through D1's ordering**: defaulting runs *before* generalization, so by the
    time G4's partition is computed there is no `Num` predicate left on that variable
    to abstract. Without D1's ordering the two clauses genuinely conflict, and the
    conflict becomes reachable the moment locals are dict-abstracted at all (§11 G1 —
    #1082). **Anyone landing #1082 must land it under D1's ordering**, not alongside it.
  * **At an `impl`-method body, result position IS a determination channel**, because
    both the method's declared scheme and the instance head are instantiated by
    somebody else. `empty : a` at `impl Monoid (Acc b)` has its `b` chosen by the goal
    `Monoid (Acc Float)`; grounding it inside the impl would monomorphise a variable
    the construction site had already fixed.

  ⚠️ These two are not in tension, and the difference is **not** "result position
  behaves differently in two places". In the first case the variable belongs to a
  type this binder is about to **quantify**; in the second it belongs to a scheme
  somebody else **instantiates**. It is one rule — *no surviving channel* — read
  against two different sets of channels.

  🚧 **Open, and deliberately not settled here.** Whether the *instance head's*
  matcher is a channel for a **body-local** literal whose variable appears nowhere in
  the method's own type is not settled by the paragraph above. This document says it
  is (the `Acc b` case). **#563** records the implementation grounding such a variable
  to `Int` and panicking at `Acc Float`, and #563 closes against this clause. The
  residual question is the opposite direction: whether treating the head as a channel
  can **under**-default and leave a genuinely undetermined variable live at
  quiescence. No such shape has been constructed. One should be looked for before
  this bullet is promoted from *specified* to *settled*.

- **D4 — Scope, and the level discipline.** Defaulting, and the ambiguity check that
  follows it, are scoped to the variables the boundary **owns**. A variable belonging
  to an inner binder that has already generalized and been checked must not be
  defaulted or reported here — its obligation merely leaks into this boundary's
  window. A variable belonging to an **enclosing** binder must not be defaulted here
  either, since that binder still has channels open. Expressing "belongs to this
  boundary" requires the boundary to have a **level** — the ordinary Hindley–Milner
  binding level, entered before its bodies and exited before defaulting — because
  "this boundary's obligations" and "this boundary's variables" are different sets
  and only the level distinguishes them. A boundary with no level discipline can
  state the first half of D4 and not the second, and therefore cannot host the
  ambiguity check at all. **#564** records that prerequisite for the `impl`-method
  body boundary, and #564 closes against this clause.

---

## 7. Core operational semantics and the single-evaluator law

The core language is the source minus predicates, plus: dictionary records
(§2), evidence abstraction `λ(d:π). e'` and application `e' e`, field
projection `methods(e).m` / `supers(e).D`. Dictionaries are
**ordinary values**; there is nothing class-specific in the core's evaluation
rules.

```
(proj)   methods(DictC{…, m ↦ v, …}).m  ⟶  v
(papp)   (λ(d:π). e') V                  ⟶  e'[d ↦ V]
```

**The single-evaluator law.** *All dispatch is resolved during elaboration
(§3–§5). The core evaluator makes no dispatch decision; it only constructs,
projects, and applies dictionary values.* Consequently:

- Any concrete evaluator (a tree-walker, a native code emitter) is a *refinement
  of one core semantics*. Two evaluators may differ in representation and speed
  but must agree, value-for-value, on every elaborated core program.
- A dispatch decision taken at evaluation time (e.g. selecting an impl by
  inspecting a runtime tag *instead of* projecting a statically-built
  dictionary) is admissible **only** as an optimization that provably refines
  `(method)` under §5's side condition, and must be applied **identically** by
  every evaluator. A fork in which one evaluator threads dictionaries and
  another decides by argument tag is, by this law, two different semantics — a
  spec violation, even if they happen to agree on tested programs.

Most-specific selection is part of elaboration, hence inside this law:
`min⊑` (§3) is computed once, statically, and its result is frozen into the
elaborated core. No evaluator, backend, or optimization level may re-derive,
re-order, or approximate it — an overlapping-instance program on which the
engines disagree (as in #203, where the tree-walker, the Core-IR interpreter,
and native at different opt levels each did something different) is by this
law a spec violation of exactly the same kind as an eval-vs-emit dispatch
fork, regardless of which engine happens to print the intended value.

This law is the formal statement of the unification the implementation has been
moving toward: elaboration is the *only* place dispatch is decided, and the
evaluators are interchangeable refinements.

### 7.1 Driver unimodality: a single file is a 1-module graph

The single-evaluator law fixes that dispatch is decided **in elaboration** and
nowhere else. It is silent on how many *elaborations* there are, and that silence has
been read as licence for two — a whole-program "flat" path for a single file, and a
per-module path for a graph. It is not.

- **U1 — The unit of elaboration is a module graph.** A single source file is the
  module graph with exactly one node, its import set being empty. The prelude is a
  node like any other (`SHADOW-SEMANTICS.md` S1: *"the PRELUDE IS A MODULE"*, whose
  own bodies are therefore not in the user's shadow scope). There is no smaller unit
  of elaboration and no second mode.

- **U2 — No clause may be conditioned on the number of modules.** Every rule in this
  document holds of a 1-node graph by holding of graphs; none of them may be
  restated, relaxed, or re-ordered for the degenerate case. Any observable difference
  between elaborating a program as a single file and elaborating it as the 1-node
  graph containing it is a **defect**, not a configuration — by §7 the two *are* two
  elaborations, and two elaborations that can disagree about a dispatch decision are
  two semantics, which is the same violation as an eval-vs-emit fork.

  The two rules that make the degenerate case non-trivial, and that a flat path
  therefore has to re-derive rather than inherit, are worth naming: **§6.2 T1**'s
  group order is over one unit either way, but **C4/§8 I5**'s instance environment and
  **SHADOW S1**'s per-module shadow scoping both quantify over *modules*, and a path
  that flattens the prelude into the user's program has erased the boundary both of
  them are stated against.

**The place someone will push back, and what U2 actually says about it.** The doctest
runner splits on whether the file under test has imports (`runChosen`,
`compiler/tools/test_cmd.mdk:213-216`, on `hasUseDecls`), and the split is deliberate
and documented. It is **not** a second elaboration mode — `runSingle`'s own comment
says so (*"route the degenerate no-import file through the SAME multi-module path …
the 1-module wrappers"*, `:225-227`), and both arms reach `elaborateModules`. So U2 is
not violated by the split *as a driver choice*. What the split carries is a residual
**flatten**: the prelude is concatenated into the user's declaration list rather than
being a node of the graph, which is why the no-import arm must first compute
`livePrelude` = *"the shadow-dropped core"* (`dropShadowedExp`, `:237-240`) and why it
needs a `programIsCore` guard (`:255`) to avoid double-declaring everything when the
file under test *is* the prelude. Under **U1** the prelude is a node like any other,
so a genuine 2-node graph needs neither the pre-drop nor the guard — SHADOW S1's
per-module scoping already answers the question they exist to work around. **Those two
are defects of the flatten, not legitimate 1-module behaviour**, and U2 is what makes
that judgement rather than leaving it to taste.

⚠️ **This enumeration was incomplete — there was a THIRD residual, not a defect of the
flatten but of the *name* the single-target arm gave its own node — PARTIALLY fixed
by #1521 (ARCH E-5), which owns #1223 but does not close it.** `runSingle` used to
stamp a single-target test file's declarations under a synthetic module id,
`"__user__"`, hardcoded at four sites in `compiler/tools/test_cmd.mdk`, while
`loadProgram` stamped the *same file* under its loader-derived id — so one
declaration carried two identities across a single `medaka test <dir>` process
(#1223, S2). This was not the flatten's residual: `runSingle` was already on the
Module path (a genuine `elaborateModules … [(rootId, prog)]` call, a 1-node graph
satisfying U1), and the defect was entirely in *what string named that one node*,
orthogonal to whether the prelude is flattened into it. #1521 retired the literal —
`runSingle`/`runPropsSingle`/`runTestDeclsSingle`/`propsReportSingle` now compute
`canonicalPathId` (`compiler/driver/loader.mdk`), the SAME last-containing-root,
round-trip-guarded convention `canonicalModId` uses to canonicalize a sibling's
import of this file — **not** plain `moduleIdOfPath` (first-root), which a first
pass at this fix used and which still diverged from the loader whenever the target
sat below its own `medaka.toml` (caught in adversarial review, #1526). This holds
REGARDLESS of whether the single-target file and the sibling that depends on it
share a directory: `canonicalPathId`'s last-containing-root convention depends only
on the SET OF ROOTS each file's own `entrySearchRoots` walk reaches (both walk up
to the SAME `medaka.toml`), not on the two files living in one directory —
`test/origin_fixtures/nested` is the cross-directory witness (`main_nested.mdk` at
the fixture root, `src/leaf.mdk` a directory below it, and the two AGREE). So the
single-target arm's node now carries the same identity a sibling's graph load would
assign it.

⚠️ **That closes #1223's ORIGINAL repro, not the general property, and #1223 stays
OPEN.** `compiler/driver/loader.mdk:662-669` documents a SEPARATE, pre-existing
residual, untouched by this fix: an ENTRY module's own id is `moduleIdOfPath`
(first-containing-root — `loadProgramFilesE` never routes it through
`canonicalModId`), while the SAME module reached as a DEPENDENCY of a DIFFERENT
target's graph is `canonicalModId` (last-containing-root). For an IMPORT-BEARING
file — which goes through `runMulti`, never through the single-file drivers E-5
changed — that asymmetry still stamps one declaration with two ids. **MEASURED**
in #1526's adversarial review, directly: `test/origin_entry_residual_fixture/src/a.mdk`
(which imports a sibling, so it is multi-regime), driven through the probe as its
OWN entry in one process, reads `mod:a`; driven again, in a SEPARATE process, as
`src/b.mdk`'s dependency, the SAME declaration reads `mod:src.a`. **DERIVED, not
separately measured:** `medaka test <dir>` would exhibit the identical divergence
within ONE process, since `medaka_cli.mdk`'s `testFilesGo` loops over every
expanded target file and calls `loadProgram` (or the single-file path) fresh per
file, in the same process, with no state shared between iterations — so the two
probe invocations above are a faithful stand-in for two iterations of that loop.
This is pinned as a dedicated section of `test/diff_compiler_origin_agreement.sh`
(`entry_residual`), not in `test/must_fail_fixtures/` — see that suite's
`test/MUST-FAIL-NOT-PINNABLE.txt` entry for #1223 for why no `medaka` CLI verb can
express it.

⚠️ **U1/U2 are clauses, not a description of the current state, and that difference
has already misled.** `compiler/DRIVER-COLLAPSE-PLAN.md` records U1 as its own
governing invariant (*"the degenerate 1-module case automatically satisfies the flat
path's invariants"*) and carries the status **IMPLEMENTED**. It is not implemented: a
second mode is live, and its consumers are live production paths rather than
remnants (see the §11 row). U1 is what that plan was trying to state; its status line
is **superseded by this clause** and must not be read as evidence that U1 holds.

---

## 8. Identity, arity, and cross-module elaboration

Dictionary discipline is a property of **bindings**, and bindings have
module-qualified identity.

- **I1 — Evidence abstraction is keyed by binding identity.** The dictionary
  parameters a generalized binding abstracts (§4 `gen`) — their count, order,
  and predicates — are part of *that binding's* elaborated type, identified by
  its module-qualified name, never by its bare name. Two distinct bindings that
  share a surface name (different modules) have independent dictionary arities.
  Conflating them (keying arity by bare name) forces phantom dictionary
  parameters onto an unconstrained binding, whose use sites then under- or
  over-apply — a coherence and a type-preservation break at once.

- **I2 — Global instance environment after import resolution.** Per C4, `IE`
  and `CE` are assembled across the whole import graph before entailment runs.
  Instance lookup in `inst` uses qualified instance identity; method projection
  uses the resolved class. Import scoping affects *visibility* of names, not the
  *identity* of the evidence a predicate resolves to.

- **I3 — Evidence travels, it is not re-derived.** When a constrained binding
  crosses a module boundary, its callers discharge its residual predicates from
  *their* ambient `P` (§4 `var`); the binding itself does not re-resolve them.
  This keeps a single derivation per predicate-occurrence and preserves C2/C3
  across modules.

- **I4 — Identity is module-qualified in every namespace, and a collision surfaces at
  the USE site.** I1 states this for value bindings; it is a property of every
  declaration, and the rest of this document depends on the general form. Every
  declaration — **top-level** value binding, type constructor, type alias, data
  constructor, record and each of its fields, interface, and interface method — has an
  identity `(originModule, name)`, assigned once where it is declared. (A **local**
  binder needs an identity too, and `(originModule, name)` is not one for it: two
  `where` helpers spelled `g` in one module are distinct. Local binder identity is
  §4.1 G1's, and I4 does not attempt to give it.) Every occurrence is
  resolved to one such identity **before** entailment or elaboration runs, and all
  downstream keying is on the identity: dictionary arity and order (I1), instance
  lookup (I2), method schemes, record-field ownership, interface parameter kinds, and
  every cross-module table. A key that is a bare `String` name is, by this clause,
  not a key.

  Two modules **may** declare the same name. That is legal at both declarations, and
  it is never the declarations that are rejected — this is the Haskell/Rust model, and
  the reject-at-declaration alternative is not adopted. What is rejected is a **use
  site** at which the scoping rules yield no unique identity.

  Three qualifications, each of which changes the rule rather than decorating it:
  1. **Ambiguity is the *failure of the scoping rules* to produce a unique identity —
     not the mere existence of two.** Where scoping already selects (a same-module
     declaration over an import; the shadowing order of
     [`SHADOW-SEMANTICS.md`](SHADOW-SEMANTICS.md) S1–S9), there is no ambiguity and no
     diagnostic. Stated without this qualification, the rule would make every
     prelude-shadowing program ambiguous and would contradict SHADOW outright.
  2. **It applies only to occurrences resolved BY NAME.** A record-field selection
     `r.f` is resolved by the *type* of `r`, not by the spelling `f`, so two records
     in scope sharing a field name are not an ambiguous use — where the field's owner
     is determined, so is the field's identity. Record *construction* and record
     *patterns* name the record, and are ambiguous exactly when that name is.
  3. **Aliases stay transparent.** A `type` alias has an identity, used to resolve the
     occurrence; the type that occurrence *denotes* is the expansion, carrying the
     expansion's identities. Two distinct alias identities with the same expansion
     denote the same type. I4 is about resolution, not about type equality, and does
     not turn an alias into a nominal type.

  🚧 **Open: effect labels.** Whether two same-named `effect` declarations in
  different modules are one capability or two is **not settled by this clause**, and
  is deliberately left open rather than decided in passing: the answer is a
  capability-semantics question (`EFFECTS-SEMANTICS.md` §7 — a label is a name in the
  host's grant vocabulary, and a manifest names labels) and not a dictionary one.
  Until it is settled, an implementation must not infer from I4 that effect labels are
  module-qualified.

- **I5 — Instance candidacy is graph-global; import scoping filters NAMES, never
  instances.** This is C4's own sentence, made operational. For a goal `C τ̄` arising
  anywhere in a module graph, `match(IE, C τ̄)` (§3) ranges over **every** instance
  declared in **every** module of the loaded graph. Not only the modules the goal's
  own module imports; not only the modules that precede it in a load, topological, or
  any other order; and not only the instances whose declarations are marked public —
  an instance's visibility annotation, if the surface language has one, governs
  nothing here. `IE` and `CE` are assembled once, before any body is elaborated (I2).
  Import scoping decides which **names** a module may write. It never decides which
  instances exist.

  ⚠️ **This is a semantics change, and only the first of its consequences is an
  acceptance widening.** The classes below are *derived*, not enumerated: a new
  candidate can change the outcome at three points — whether a `⊑`-minimum exists
  (C1), which instance it is (`inst`'s selection), and whether the selected instance's
  own context `Q` is dischargeable (`inst`'s recursive premise) — and each point
  yields one class, plus the trivial case of a goal that previously matched nothing.
  **Do not treat this list as closed; derive against those four points instead.**
  1. **New acceptances.** An impl declared in a module that no path reaches before the
     goal's module — a topologically later one, or a sibling — becomes usable. A
     program that did not compile now compiles. This is the orphan-instance-style
     widening. ⚠️ **It is OWED a could-not-pass-before fixture and does not have one.**
     This sentence read *"it is carried by a fixture that could not pass before"*, in
     the present tense, from the clause's own authoring commit (`ab1e6e9d`, ARCH S-2)
     until 2026-08-07 — while that same commit's message said the fixture is *A-3's*
     and covers class (1) alone, and the design that ordered the clause
     ([`TYPECHECK-TARGET-ARCHITECTURE.md`](../../compiler/TYPECHECK-TARGET-ARCHITECTURE.md)
     §5 **R2**) says *"A-3's PR carries the could-not-pass-before fixture"* — a
     **present-tense verb whose SUBJECT does not exist**. A-3 is
     [#1112](https://github.com/MedakaLang/medaka/issues/1112) and is OPEN. ⚠️ That
     distinction is worth stating rather than smoothing, because it is the axis this
     repair turns on and an earlier draft of this very paragraph got it backwards by
     calling R2's sentence "future tense": R2 is **not wrong** — it describes a PR yet
     to be written — and the defect was importing it into a *specification* as a claim
     about a fixture in the tree. Tense is not reference.

     Derived, not assumed: the conformance corpus at `test/dict_fixtures/` holds `s8-*`
     units for I1, I2 and I3 only — no I4, I5 or I6 unit exists — so **no class of I5
     is gated by a CONFORMANCE fixture today.** ⚠️ **That is not the same as ungated,
     and the difference is exactly class (3).** Class (3) *is* pinned, **inversely**,
     by `test/must_fail_fixtures/1072-overlap-xmod-bare-head-arm-order/`, which asserts
     that the class-(3)-wrong answer **still reproduces**: a general `impl Speak (Box
     a)` in the site's own module and a strictly more specific `impl Speak (Box Int)`
     in a module the site does not import, where the native binary prints `general` at
     exit 0 while `medaka run` prints the correct `specific`. Implementing graph-global
     candidacy flips that row's stdout to `specific` and turns the pin **red — and the
     red is the DRAIN, not a break** (the row's own note: *"When main.mdk's stdout flips
     to `specific` with control.mdk still `specific`, close #1072 and delete this
     fixture."*). Its mirror `control.mdk` must stay `specific` throughout; a red on
     *both* is a general regression, not a drain. Classes **(1), (2) and (4) are
     unpinned in either direction.** Do not cite this clause as evidence the widening
     is covered, and do not read the four classes here as uniformly unpinned either.
  2. **New rejections via C1.** Enlarging `match(IE, π)` can destroy a `⊑`-minimum
     that a smaller candidate set had. Two `⊑`-incomparable instances, one of which
     was previously invisible at the goal, make the goal **ambiguous overlap** under
     C1 — so a program that compiles today can stop compiling. A candidate-set
     widening is *not* an acceptance widening.
  3. **Silent answer changes.** A newly-visible instance that is strictly more
     specific than the previous winner *wins*, by §3. The program still compiles, and
     prints something different. There is no diagnostic, because nothing is wrong: the
     new answer is the specified one and the old answer was the artifact. Any
     migration onto I5 must treat this as its primary hazard rather than as golden
     churn.
  4. **New rejections via an UNSATISFIABLE CONTEXT — with C1 fully satisfied.** The
     newly-visible instance is strictly more specific, so it wins uncontested; but its
     own `Q` cannot be discharged at the goal, and `inst` has no backtracking to the
     runner-up. Given `impl Show2 (List a)` and `impl Show2 (List (Option a)) requires
     Sized a`, the goal `Show2 (List (Option Blob))` with no `Sized Blob` in scope
     compiles and prints `generic` while only the general instance is visible, and is
     **rejected** — `No impl of Sized for Blob` — once both are. This is class (2)'s
     outcome by class (3)'s mechanism, and it is neither: the two instances here are
     perfectly `⊑`-comparable and C1 holds throughout, so the mechanism stated in (2)
     does not apply. It falls out of §6.1 choice-point 1 (`⊑` compares heads only;
     contexts play no role in selection) combined with `inst`'s commitment to the
     `⊑`-minimum. ⚠️ **This class has the worst migration diagnostic of the four**: an
     error naming an interface the author never wrote, arising from a module they
     never imported, at a call site they did not change. A migration that plans only
     for goldens and ambiguity will meet this one unprepared.

  The price I5 pays for coherence is that a program's meaning is a function of the
  **whole loaded graph**: adding an unrelated module to a build can change an existing
  module's dispatch. That is not a defect of I5 — it is what C4 buys coherence with,
  and the alternative (per-module candidate sets) is exactly the state in which "C1/C2
  hold only locally and coherence fails across module boundaries", which C4 forbids by
  name.

  🚨 **I5 does NOT extend that price to NAMES, and in particular it does not decide
  shadow-hood.** This paragraph has been read as licence for *any* graph-global
  name-set predicate, which it is not: I5's subject is `match(IE, C τ̄)`, and its
  closing sentence (*"Import scoping decides which names a module may write. It
  never decides which instances exist."*) is a **boundary clause** bounding I5's own
  claim to instances — not a rule about how a predicate over names is scoped. The
  coherence argument above does not transfer, either: two modules resolving the same
  *name* differently is **scoping**, not incoherence, and C4 says nothing about it.
  ⚠️ **The concrete instance this ambiguity produced, now ruled
  (2026-08-06):** `SHADOW-SEMANTICS.md` **S1** decides whether a bare name is a
  *shadow* by intersecting two **name** sets, and its operands are scoped — the
  interface operand to what the occurrence's module can **name**, the standalone
  operand to what is defined in or imported into it (that document's §1.0 and its
  **S1-SCOPE** note) — **while S2's impl universe stays graph-global under this
  clause**. Narrowing a name set does not narrow `IE`, and the two are compatible
  rather than in tension. Ruling:
  [#1375](https://github.com/MedakaLang/medaka/issues/1375). Anyone implementing
  I5 must keep the two apart; anyone implementing S1 must not cite I5 as licence
  to make its operands graph-global.

- **I6 — Heads that no declaration produced, and the empty origin.** I4 assigns an
  identity `(originModule, name)` to every *declaration*. Three heads this
  implementation constructs have **no declaration behind them**, and I4 as written is
  silent on all three. The silence is not harmless: it is precisely where the
  mechanical reading of I4 — *"stamp every type-constructor head with the module being
  elaborated"* — yields a wrong answer, and the three fail in three different
  directions. I6 pins them so that an implementation of I4 does not have to guess.

  1. **I6.1 — A head fabricated from a TYPE-PARAMETER name denotes a rigid type
     variable and carries NO I4 identity.** Where a signature elaborator meets a
     type-parameter spelling it cannot bind, this implementation reifies it as a
     nullary type constructor. Normatively that head denotes a **rigid type
     variable**, which is not a declaration: it MUST NOT be assigned an
     `(originModule, name)`; it MUST NOT compare equal to the identity of any
     declaration, including one whose surface spelling it happens to share; and it
     MUST NOT be usable as a key in any table I4 requires to be identity-keyed.
     Whether two such heads are the *same* variable is a question about **binders**,
     not about modules — same binder ⇒ same variable, different binders ⇒ different —
     and that is §4.1 **G1**'s local-binder identity, which I4 already declines to
     give. ⚠️ **The failure this rules out is of a different kind from the one I4
     rules out.** I4's *"a bare `String` name is not a key"* is about keying a
     declaration by a name that two modules may share. Here there is **no declaration
     to be right about**: a bare-spelling key promotes a type variable into a type
     constructor. Two reachable collisions follow — with an unrelated variable of the
     same spelling in another scope entirely, and with a **reserved internal tag**.
     ⚠️ **Collision with a user-declared type is a third case and it is NOT claimed
     here**: a type variable and a type constructor occupy disjoint surface
     spellings, so the two populations cannot meet *by source spelling* — the same
     input-side argument I6.2 (b) rests on. The clause is not weakened by that: the
     first two collisions are enough, and an implementation that cannot tell a
     fabricated head from a declared one has not implemented I4 however carefully it
     qualifies the declared ones.

  2. **I6.2 — A BUILTIN head has exactly ONE identity, shared by every module.**
     **Two conjuncts, checked in different places.** An implementation can satisfy
     one and not the other, so no verdict on I6.2 is meaningful unless it says
     *which*:
     - **(a) One type.** The tuple type constructors are part of the language, not
       declarations of any module: `(Int, Int)` written in two modules is **one
       type**, and `impl Bimappable (,)` in the prelude applies to every module's
       tuples. A builtin head's origin is a **reserved origin, distinct from every
       module identity**, and in particular it is *not* the module in which the
       occurrence is written.
     - **(b) Unforgeable.** No source file may produce a head carrying that reserved
       origin, other than through the surface syntax the language assigns to the
       builtin. **(b) is the soundness-bearing conjunct**: (a) only says that two
       writings of the builtin agree; (b) is what stops anything *else* joining
       them. A reserved origin that user text can name is not reserved.

     The representation of the reserved origin is A-1's to choose; the property is
     not.

     🚨 **(a) is the conjunct a mechanical I4 implementation breaks first, and it
     breaks it silently.** Stamping every type-constructor head with the module under
     elaboration makes two modules' `(Int, Int)` two distinct types, un-does the
     prelude's tuple instances for every module but the prelude, and produces
     no diagnostic that names tuples. Today (a) holds — for the very reason
     I4 fails, namely that the head is a bare program-global string with no origin at
     all. **It is therefore carried, not enforced**, and A-1 must preserve it
     deliberately rather than expect to inherit it.

     ⚠️ **A round-trip guard is a MITIGATION of (b)'s failure mode, never evidence
     for (b).** The internal spelling has *two meanings depending on which side of
     the pipeline it is on*: as a type-constructor payload it names the builtin;
     written back into source it re-parses as a type **variable**. The tree records
     the consequence itself — emitting the raw name would produce text that
     *"re-parses as a type VARIABLE and corrupts the impl head"*
     (`compiler/tools/printer.mdk:337`). One spelling, two meanings, and A-1 is
     about to make that spelling load-bearing. Evidence for (b) has to come from
     the **input** side (what a source file can construct), not from the output
     side (what the printer declines to emit).

  3. **I6.3 — The empty module id is NOT an identity, and must not become one.**
     Every declaration's origin is a **non-empty** module id. There is no "belongs to
     no module" case to encode: the prelude is a module (`SHADOW-SEMANTICS.md` S1,
     *"the PRELUDE IS A MODULE"*), and **a single file is the 1-node graph containing
     it** (§7.1 **U1**), so it has an origin like every other node. Where a
     population's origin is genuinely undecided today — the extern catalogue is
     parsed and threaded alongside the prelude rather than resolved as a named node —
     that is a gap for I4's implementation to close by **giving** it an origin, not a
     licence to leave the component empty. Consequently an identity whose module
     component is empty is **not well-formed**, and neither available reading of an
     empty component is licensed:
     - as an **identity**, `""` makes every declaration that carries it collide with
       every other one — the exact last-write-wins loss I4 exists to forbid, now
       concentrated on the builtin/prelude/single-file population;
     - as a **wildcard** that compares equal to anything, it makes two distinct
       declarations indistinguishable at a coherence or dispatch decision, which is a
       C1/C2 break rather than a naming one.

     Where an implementation writes `""` today it means *"origin not recorded"* — a
     **sentinel, not a value** — and the two are not interchangeable. An
     implementation of I4 must make the absent case **unrepresentable**: a **total,
     non-optional origin that every producer supplies**, which U1 says always
     exists.

     ⚠️ **An `Option`-shaped origin does NOT satisfy this, and must not be read into
     it.** It makes the absent case *representable, as `None`* — typed and explicit,
     which is a weaker and different property than absent — and it reinstates the
     prohibited behaviour verbatim: a cross-module predicate over `Some a` and
     `None` still has to decide, per call site, which of the two readings above
     applies. `None` meaning "origin not recorded" is `""` with a nicer type. If a
     producer cannot supply an origin, that is a **defect in the producer** — U1
     says every declaration sits in a module — not a licence to widen the type.

  **Corollary (I6.1 ∧ I6.3) — a rigid type variable must not be carried by the
  type-CONSTRUCTOR node at all.** Neither clause states this on its own; together
  they force it, and since it is a constraint on the *representation* rather than a
  matter of taste, it is stated here rather than left for an implementer to collide
  with. I6.1 says a fabricated head carries **no** identity. I6.3 says an identity's
  origin may not be absent, and that the absent case must be unrepresentable. If a
  rigid variable is still carried by the same node that carries a declared type
  constructor, then it *is* a head whose origin is absent — exactly the state I6.3
  forbids representing. The only resolution satisfying both is that a rigid variable
  is **a distinct constructor**, so that "carries no identity" is a structural fact
  about the node rather than an empty field on it. ⚠️ **This is the one place where
  two I6 clauses jointly pin the representation harder than either does alone**, and
  it lands on the first question A-1 has to answer. An implementation that keeps
  rigid variables in the type-constructor node can satisfy I6.1 or I6.3 but not
  both, and the conflict will surface as a per-call-site decision about an empty
  origin — which is the defect I6.3 exists to forbid.

- **I7 — An OPERATOR's class, and a numeric literal's class, are fixed by the language
  definition. They are not resolved by name, and no user declaration can capture
  them.** I4 gives an identity to every declaration and rules on occurrences; I6 rules
  on heads with no declaration behind them. A third population is governed by neither:
  the predicates this implementation **synthesizes** at an operator or a literal. `1 +
  1` demands `Num`, `x == y` demands `Eq`, `x < y` demands `Ord`, `xs ++ ys` demands
  `Semigroup` — and at none of those sites did the programmer write a class name.
  There is **no occurrence to resolve**, so I4's machinery does not reach them, and
  the mechanical reading (*"look the spelling up in whatever interface table is in
  scope"*) is the wrong answer rather than an under-specified one.

  **The rule.** For each operator and for the numeric literal, the class its
  synthesized predicate names is a **fixed constant of the language**, denoting the
  **prelude's** declaration of that class and carrying that declaration's I4 identity
  `(originModule = the prelude module, name)`. It is the same class in every module of
  every graph. An implementation MUST NOT determine it by looking up the class
  spelling in a table that any non-prelude declaration can write to, and MUST NOT
  determine it by resolving the operator to a method name and reading that method's
  class.

  The bindings are part of the language definition, not of any user's scope:

  | Surface | Synthesized predicate | Prelude method the elaboration uses |
  |---|---|---|
  | `+` `-` `*` `/` `%`, unary `-` | `Num τ` | `add` / `sub` / `mul` / `div` / `negate` |
  | `==` `!=` | `Eq τ` | `eq` |
  | `<` `>` `<=` `>=` | `Ord τ` | `compare` and its derived methods |
  | `++` | `Semigroup τ` | `append` |
  | integer literal `n` | `Num τ` | `fromInt` |

  Four qualifications, each of which changes the rule rather than decorating it:

  1. **This is an instance of I4's qualification 2, not an exception to I4.** That
     qualification already says the ambiguity rule *"applies only to occurrences
     resolved BY NAME"*, and gives `r.f` as the case where the spelling is not the
     resolution key. An operator is the stronger form of the same fact: the spelling
     is not merely not the key, **it is not present**. I7 therefore does not weaken
     I4's *"two modules may declare the same name"* — it says what the synthesized
     predicate denotes when neither module's name was written down.

  2. **A user MAY declare an interface spelled `Num`, `Eq`, `Ord` or `Semigroup`, and
     it is never rejected for that.** I4 states that the reject-at-declaration
     alternative is not adopted, and I7 does not reintroduce it by the back door. Such
     a declaration is an ordinary interface with its own I4 identity; users may
     `impl` it and call its methods by name. What it does **not** do is capture an
     operator: `1 + 1` in that same module still demands the *prelude's* `Num`. A
     program that wants the user's class must name it — by calling its methods, or by
     writing it in a signature — which is an occurrence resolved by name and therefore
     governed by I4 in the ordinary way.

  3. **The identity must be DERIVED from the prelude's own declarations, never
     invented.** The prelude is a module (§7.1 U1; `SHADOW-SEMANTICS.md` S1), its
     `interface` declarations carry I4 identities like any other, and those
     declarations are in hand wherever the operator predicates are synthesized. The
     implementation MUST read the identity off them. It MUST NOT fabricate an ambient
     module id for the prelude — that is the I6.3 failure in a different namespace,
     and it is unnecessary here because a real declaration exists to read.

  4. **Absent the prelude, there are no built-in classes and the operators impose no
     class constraint.** A driver elaborating without the prelude (a bare-HM
     configuration) has no `Num`/`Eq`/`Ord`/`Semigroup` declaration to denote, so the
     synthesized predicates are not merely undischarged — they are **not
     synthesized**. The gate an implementation tests before synthesizing MUST be *"is
     the PRELUDE's class present"*, answered from the prelude's declarations. It MUST
     NOT be *"is some interface named `Num` registered"*, which a user declaration can
     satisfy: that gate makes a user's class both the trigger for the obligation and,
     under a name-keyed lookup, its referent — the capture this clause forbids,
     reached through the gate instead of through the payload.

  ⚠️ **The failure this rules out is REACHABLE TODAY, and it is silent.** The
  numeric-literal path is the one place this implementation already anchors a built-in
  class by name — it elaborates a literal to a `fromInt` occurrence and resolves
  `fromInt` in the **user's term scope** — so any binding spelled `fromInt` re-anchors
  every numeric literal in the module. Measured on `adb789ca`: a file whose only
  addition is a top-level `fromInt : Int -> Float` typechecks at exit 0 and then
  `println (1 + 1)` prints **`2.0`** under the interpreter and **`2`** from the
  compiled binary — two engines, two answers, no diagnostic, on a program the
  implementation accepts. The binding need not be an interface method (a plain
  function does it), need not collide with any interface *name*, and need not be
  top-level (a `let` binder does it). This is why qualification 1 is stated as
  "not present" rather than "not the key": an implementation that anchors an
  operator's class by resolving *any* name — the class's or its method's — has
  already lost, and the literal path is the proof.

  ⚠️ **Do not read I7 as licence to skip the dictionary.** I7 fixes *which class* an
  operator demands; §5 still fixes how the demand is discharged. An operator whose
  predicate is satisfied by a user instance must dispatch through that instance's
  dictionary exactly as a method call does. An implementation that records the
  predicate, accepts the program, and then evaluates the operator by a primitive that
  only understands built-in representations satisfies I7's identity requirement while
  violating §5 and §9's type preservation — accepting a program it cannot run. That
  is a distinct defect from the one I7 rules out, and closing I7 does not close it.

---

## 9. Soundness statements (targets for a later proof/audit)

- **Type preservation.** If `P | Γ ⊢ e ⇝ e' : τ`, then in the core,
  `⌜Γ⌝, (d:π for π∈P) ⊢ e' : ⌜τ⌝`. Elaboration maps a well-typed qualified
  program to a well-typed core program with dictionaries explicit.
- **Semantic adequacy.** `e'` computes the value the source program denotes
  under its intended class semantics; method calls reduce to the impl selected
  by the statically-determined, most-specific instance (§3).
- **Coherence.** Under C1–C4, the elaboration is unique up to `≡` (§6), so
  "the value the source denotes" is well-defined.
- **Evaluator interchangeability.** Under the single-evaluator law (§7), any two
  refining evaluators agree on every elaborated program.
- **Signature authority (§4 `gen-sig`, #619).** For a binding with an ascribed
  signature, its principal context is the declared `Q_sig`, and elaboration abstracts
  exactly `Q_sig`. The body's inferred context `P'ᵢ` is admitted **iff** `Q_sig ⊩ P'ᵢ`
  (`requires`-closed entailment, §3); otherwise the program is rejected. Equivalently:
  a well-typed signed binding never has a scheme context that differs from — is neither
  a superset nor a subset of — the predicates it wrote, so no caller discharges a
  predicate the author did not declare, and none is silently dropped that the body
  genuinely needs. The entailment side condition is **vector-valued** on multi-parameter
  predicates: `Q_sig = {Ix a b, Ix c d}` does **not** entail an inferred joint `Ix a d`
  (each argument appears in `Q_sig`, but the predicate does not), so that binding is
  rejected rather than widened — the per-argument reading would be unsound.

---

## 10. How to read the recurring defects against this spec

> ### ⚙️ This spec now EXECUTES: `test/diff_compiler_dict_semantics.sh` (#616)
>
> Until 2026-07-30 nothing mechanically checked the implementation against this
> document — the conformance reviewer was the sole enforcement mechanism, which is
> how it accumulated four independent divergences in a single day
> (#607/#609/#610/#614) with every gate green. The corpus is
> `test/dict_fixtures/`, **one fixture per clause**, each carrying its
> **hand-derived spec answer in its own header comment** before any observed
> value. The gate drives `check`/`run`/`build` per fixture and asserts the
> **verdict**, the **printed value** (§7 is a claim about values, so exit codes
> alone cannot see it), the **diagnostic code** for rejections, the **displayed
> scheme** (#607/#610 both printed the right value with the constraint silently
> dropped), and pinned patterns over the **emitted LLVM IR** (dict-param arity and
> which impl a site actually resolved to — a dead dict slot is invisible from
> behaviour).
>
> ⚠️ **It pins CURRENT BEHAVIOUR, not this spec.** Divergences are pinned with the
> issue number annotated, so the gate doubles as the conformance ledger and goes
> **red the day a fix lands** — which is the signal to re-pin the row. Its header
> carries the live ledger and an explicit **NOT YET COVERED** punch-list; read
> both before concluding a clause is enforced. Whichever clause you are editing
> here, check whether it has a row there, and add one if it does not.
>
> **Building it found two S0s that no existing gate could see**, both `verified`
> and both pinned as ledger rows: **#1127** (§6.1.4/C2 — a dictionary reached by
> *superclass projection* selects the general instance on the native build:
> `check` 0, `run` correct, binary wrong) and **#1128** (§3/§10 — a fully-general
> `impl C a` beside a concrete impl at a parametric head: every call resolves to
> the concrete impl, *both engines*, exit 0). Each ships with a one-token
> discriminating control in the same corpus. The other ledger rows are #323, #614
> /#311, and phantom-position rejection.
>
> ⚠️ **The phantom row's own framing has since been corrected, and the correction is
> worth keeping.** An earlier revision of this notice read *"which is **not** a bug to
> file but the spec paragraph owed as #1107 (d)"* — a false dichotomy. It is **both**:
> #1107 (d) owed the spec paragraph (now **§5.1 M3**), and the over-rejection M3
> identifies is a behavioural defect filed separately as **#1134**. The pair of
> fixtures pins them apart: `s5-phantom-ambiguous-use-rejected` is conformant on the
> verdict, `s5-phantom-determined-use-rejected` is not, and only the second can drain
> — on #1134, never on #1107, which changes no behaviour.
>
> ⚠️ **§11 below and this gate answer different questions — do not substitute one
> for the other.** §11 maps each clause to its **source site** and keying
> assumption (what the code *is*); the gate observes **behaviour** on programs the
> compiler's own source never exercises (what the code *does*). §11 is what
> located #614/#311 and #1113 by reading; #1127 and #1128 were invisible to
> reading and only fell out of running. A clause wants both rows.

**Audit completed 2026-06-21 — see [`archive/DICT-CONFORMANCE-AUDIT.md`](../../archive/DICT-CONFORMANCE-AUDIT.md) (archived); all D1–D10 divergences closed.** (That audit predates the
overlap extension of §3/§6; D1–D10 concerned the non-overlapping regime. The
overlap regime's conformance target is the 2026-07-16 revision, driver #203.)
The lens below remains useful for diagnosing future regressions.

Each known trouble area maps to a
specific clause; that mapping is the audit's starting point.

- **Return-position dispatch** → §5: dispatch must come from the static
  dictionary; an evaluator that can only inspect arguments cannot do
  result/phantom position. Suspect any path where dispatch is argument-directed.
- **Nested / element dictionaries** → §2 + §3 `inst`: evidence is a tree —
  superclass sub-dicts in `supers`, instance-context evidence captured in method
  closures; a flat impl-key discards the captured context and cannot reconstruct
  it. Suspect flattening.
- **Mutually-recursive constrained bindings** → §4 `gen-rec`: recursive uses must
  reuse the group's dict params, not re-resolve. Suspect a recursive call site
  that re-enters entailment instead of passing `d₁…dₘ`.
- **Superclass (`requires`) entailment** → §3 `super` + C2: superclass access is
  projection of a field that must equal the canonical dict. Suspect re-resolution
  at the use site.
- **Cross-module same-name collision** → §8 I1, and its general form **I4**:
  dictionary arity keyed by bare name instead of binding identity. Suspect any
  bare-name arity table — and, per I4, any bare-name table at all: an interface's
  required-method list, a method scheme, a record's field owners, an interface
  parameter's kind. The failure is last-write-wins and therefore silent.
- **An impl that is only usable from some modules** → §8 **I5** + C4: candidacy
  narrowed to what a module happened to have loaded. Suspect any instance universe
  that is *accumulated* in load order rather than assembled once.
- **A local helper that dispatches to the wrong impl** → §4.1 **G4**: a `let`/`where`
  binding that forwards a dictionary but abstracts none. Suspect any generalization
  site that answers "this local forwards a dict" by declining to generalize.
- **Eval-vs-emit dispatch fork** → §7 single-evaluator law: dispatch decided in
  an evaluator rather than in elaboration. Suspect any evaluator-time impl
  selection that is not a uniformly-applied, side-condition-guarded refinement
  of `(method)`.
- **Most-specific divergence (overlapping instances, #203)** → §3 `inst` +
  §6 C1 + uniform resolution: with overlap now *specified*, the defect class
  is no longer "overlap exists" — it is **a resolution path that fails to
  select the `⊑`-minimal matching instance** the spec mandates: a nested
  `requires` obligation discharged to the general instance, a super-projection
  built against the declaration head instead of the construction goal, or an
  engine that crashes/diverges where another selects correctly. Suspect any
  resolution code path that stops at the *first* matching instance, iterates
  `IE` in declaration order, keys instances by class-plus-head-constructor
  alone (which cannot separate `List Int` from `List a`), or resolves
  nested/super obligations through a different lookup than top-level goals.
- **Impl fixes a caller-owned method variable (#814 vein)** → §3 W3: an impl or
  default body checked with *flexible* method-scheme variables can pin a type
  variable the caller instantiates freshly at every `var` — a type-soundness
  crash when pinned to a mismatched concrete type, silent effect laundering when
  pinned to an effect-bearing type. Suspect any impl/default body-checking path
  that unifies the body against the method type with fresh metavariables and
  never verifies the scheme's non-head quantifiers survived as distinct,
  unconstrained variables.

---

## 11. Per-clause enforcement table (clause → site → keying assumption)

Seeded from [`compiler/TYPECHECK-ARCHITECTURE.md`](../../compiler/TYPECHECK-ARCHITECTURE.md)
§4 (every subsystem row there already cites its governing clause) and re-verified
directly against source at `c4ef6dbe` (this document's `$BASE`; line numbers drift —
re-derive with `grep -n '^<symbol>' <file>` rather than trusting them). Follows
[`SHADOW-SEMANTICS.md`](SHADOW-SEMANTICS.md) §3's form. A clause with no located
site is marked **UNIMPLEMENTED** rather than skipped — per this document's own §0
non-derivation principle, that is a finding, not a formatting gap.

The rows for **§4.1, §5.1, §6.2, §6.3, §7.1 and §8 I4/I5** were added with those
clauses (#1107) and verified against source at `128da26c`. Every one of them is
UNIMPLEMENTED, PARTIAL, or DIVERGENT — which is expected and is the point: those
clauses were written *because* behaviour existed with no governing rule, so the rows
record where the behaviour and the rule now differ rather than pretending the clauses
were already in force.

The **§8 I7** rows were added with clause I7 (2026-08-10) and verified against source
at `adb789ca`. Unlike every batch above them, their verdicts are **first-hand
behavioural measurements on a binary built from that commit**, not source reading:
each 🔴 cell names the program, the three verbs, and the exit codes it was derived
from. Where a row says a divergence is *unreachable today*, it also names **what makes
it unreachable and when that expires** — in every case the prelude flatten that §7.1
**U1** removes — because "unreachable" without that is a verdict with a hidden premise,
which is what §0's non-derivation principle forbids recording.

Three of those I7 rows were **re-derived at `5c3d3dd8`** when the gate half landed
(#1480 moved the payload, #1539 the gate): **I7 qual. 4** is now ✅, **I7 (operators)**
stays 🟡 for the flattened-arm identity alone, and **I7 (literals)** stays 🔴 because
only its *guard* moved — its `fromInt` anchoring, which is the actual divergence, did
not. ⚠️ The 🟡 and the 🔴 are the point: a conformance table that upgraded all three
because one fix landed would be claiming conformance the code does not have.

The **§8 I6** rows were added with clause I6 (2026-08-01) and verified against source
at `fa07eaa7`. Several are marked 🟡 rather than ✅ on purpose: the property *is* true
of the tree today, but it is true **because of the very name-collapse I4 rejects**, so
an implementation of I4 that does not preserve it deliberately will break it silently.
A row that reads "holds" without recording *what makes it hold* would retire exactly
the question I6 exists to ask.

⚠️ **I6's rows are ONE PER CONJUNCT, and that is a deliberate departure from the
one-row-per-clause shape above.** The first cut of these rows gave I6.2 a single
🟡 HOLDS verdict, having checked only its conjunct (a) — a paraphrase naming one
half, evidence for one half, one verdict apparently covering both. **(b) was the
soundness-bearing half and was the unchecked one.** A multi-conjunct clause in a
single cell hides exactly that: the cell is ~3 000 characters and renders as one
unwrapped line in a diff, so the gap between "what the clause asserts" and "what the
evidence reaches" is invisible to review. Where a clause below has more than one
independently-checkable assertion, give each its own row and its own verdict —
including the case where the honest verdict is UNVERIFIED.

⚠️ **Where a row claims "no site exists", read the *derivation* in it, not the
verdict.** **Three** such claims made here were **wrong on the first pass** and are
corrected above (§5.1 **M2**; the record-field half of §8 **I4**; §8 **I6.1**). All
three failed the same way: the search used the *implementation's* vocabulary rather
than the spec's — the W2 lesson, applied — but was **scoped to `typecheck.mdk`**, and
in every case the check lives elsewhere: at the **resolve stage** for M2, under a name
none of the search terms covered for I4, and — for **I6.1** — at the resolve stage
again, where `checkType:341-345` tests a `TyCon` and `checkType:346` is a separate
`TyVar` arm, so the `Ty` AST separates the two populations that the claim said
*"there is no predicate anywhere"* to separate. ⚠️ **I6.1 was added by the same change
that added this paragraph** (2026-08-01), which is the point rather than an
embarrassment: a paragraph cataloguing a failure mode has to catch its own newest
instance, or it is an example of the thing it warns about. A negative result scoped to
one file is not a negative result, and neither is one scoped to one stage.
⚠️ **Wrong SCOPE and wrong PATTERN are two species with one symptom, and only the
first is described above.** A regex that cannot match the shape it is looking for
returns empty exactly like a search in the wrong place: a `TyCon` applied as an
ARGUMENT is written `(TyCon name None)`, with the paren *before* the constructor, so a
pattern anchored on `TyCon` followed by an open paren matches none of them — and an
empty grep is a claim, not a proof, in either species. The single surviving "no site" claim
(§4.1 **G1**) is therefore stated with a tree-wide derivation over the *name-minting*
function rather than over the pass that was expected to call it.

| Clause | Stage / site | What it enforces | **Keying assumption** |
|---|---|---|---|
| §2 evidence representation (nested dict; `methods`+`supers`) | `compiler/eval/eval.mdk:130` `VDict String (List (Value e))`; `compiler/ir/core_ir.mdk:132` `CDict String (List Route)` | the runtime/IR shape of evidence — one dict per instance, closed over its required sub-evidence | ⚠️ REPRESENTATION-LEVEL: both are a flat `(key, positional-list)` pair, not a literal `{methods, supers}` record. Legal only as §2's "representation optimization" *if* supers/context are still resolved once at construction (`inst`, row below) and never re-derived — not independently re-verified past that point here |
| §3 `assum` | `entailAssum`/`entailAssumVar`/`entailAssumRoute`, `compiler/types/typecheck.mdk:11907-11934` | an in-scope `=>` dict is used directly, never rebuilt | keyed on the call site's **enclosing binding's** dict-variable name (`activeDictVarOfEncl`/`activeDictVarForEncl`, via `encl`), not on predicate identity — assumes at most one matching in-scope dict per predicate per enclosing binding |
| §3 `super` | `expandSupersTable`, `compiler/types/typecheck.mdk:5037` (WS-1b superclass-evidence flatten) | superclass access as a nested-record projection, computed once | table keyed by (interface, declared superinterface param-names) per transitive superinterface slot (own comment: "one slot for each (transitive) superinterface") |
| §3 specificity `⊑` / `min⊑` | `pickMostSpecificEntry` → `findMostSpecificEntry`; `tySubsumesV`; `matchStep`; `selectImplEntryByIface` (all `compiler/types/typecheck.mdk` — **symbol names only**, for the non-monotone-drift reason the C1 row below gives at length) | the unique most-specific matching instance | ✅ **The no-unique-minimum arm is a HARD REJECT since #1155 / F-3c (2026-08-01)** — `reportAmbiguousOverlap` pushes a located `T-AMBIGUOUS-INSTANCE` naming the goal and every competing impl head. This cell read *"it falls back to the head of the list (the pre-existing first-match behaviour) rather than signalling ambiguity"*, which is now true only of the residue below. ⚠️ **The residue is real and deliberate: the reject is gated on the goal being CLOSED** (`goalsClosed` — ground, or every free variable quantified by an enclosing scheme, i.e. §6.2 T3's class), because T4 defers a goal still carrying an unbound metavariable rather than deciding it. At a NON-closed goal the arm still silently returns the head of the list. Closing that is T4's work, not the selector's — and it is currently **unreachable**, see the C1 row and `test/MUST-FAIL-NOT-PINNABLE.txt` (#1155). ⚠️ The arm still RETURNS the first match after reporting: the program is rejected by the sticky-error channel, so no route moves and the rejected program's emitted IR is unchanged |
| §3 `inst` | `entailInst`, `compiler/types/typecheck.mdk:11941-11991`, via `keyForSite:11386`/`keyForSiteByIface:11608` → `matchedEntry:11416` → `pickMostSpecificEntry` | fresh dictionary construction at the `min⊑` instance, recursively discharging its own context | goal keyed by `ifaceParamMonos`'s **full param-mono vector** (the #609 fix, code comment 11971-11978) — shares ONE binding between the method route and its own `requires`-context routes so both arms pick the same impl (closes the C2 "same-impl" hazard) |
| §3 precedence (`assum`/`super` before `inst`) | `entail`, `compiler/types/typecheck.mdk:11892-11896` | in-scope evidence wins over instance construction | tries `entailAssum` first, falls to `entailInst` only on `None` |
| §3 **W1** (superclass acyclic) | `ifaceDfsCycle:11076-11101`, invoked at `:11062` pushing `T-CYCLIC-SUPERINTERFACE` (`compiler/types/typecheck.mdk`) | rejects a cyclic `requires` chain | DFS keyed on **bare interface name** (`String`), not module-qualified — not independently re-verified for a same-named-interface cross-module collision here |
| §3 **W2** (instance-context termination / Paterson coverage) | `routeOfD:12863` (`compiler/types/typecheck.mdk`), the depth-carrying core of `routeOf:12852`, threaded through `argImplRequiresRoutes:13054` → `argImplReqRoutes:13144` → `argReqRoute` → back to `routeOfD` — the #217 "WS-4b fuse" | ⚠️ **NOT the spec's W2.** W2 is a *static, declaration-time* condition (reject an instance whose context isn't structurally smaller than the goal). What exists is a **dynamic, resolution-time depth cutoff**: `argImplRequiresRoutes:13056` — `if depth >= 32 then []` — so a non-shrinking context (`impl C (T a) requires C (T (T a))`) *terminates* by silently returning no further requires-routes at depth 32, rather than being *rejected* at declaration. The program is accepted either way; only route resolution stops recursing | depth increments **once per impl level** inside `argImplRequiresRoutes` (`depth + 1` at `:13062`), starting from `0` at `routeOf`'s call into `routeOfD`; the `32` bound is a magic number with no stated derivation — a legitimately-deep-but-terminating context presumably degrades identically to a genuinely non-terminating one at depth 33, and neither is diagnosed |
| §3 **W3** (method-scheme fidelity / rigidity) | `checkMethodRigidityCore:14732`, `checkImplMethodRigidity:14749`, `checkDefaultMethodRigidity:14766`, `checkImplEffVarRigidity:14927` (all `compiler/types/typecheck.mdk`) | an impl/default body may not pin a non-head quantified variable (type *or* effect) to a concrete shape | gated by `inRigidityBodyRef` — True only while an IMPL/DEFAULT method body is being inferred |
| §4 `var` | `instantiate:3630`; per-residual entailment via `entail:11892`; obligation discharge `checkCallObligationsU:13793`/`checkOneCallObligation:13814` | instantiation + per-predicate entailment at each use | — |
| §4 `gen` | `generalize:3505`; check-path registration `registerInferredConstraints:16140`/`setDictEligible:9418` | abstracts a dict param per deferred predicate | arity becomes part of the binding's elaborated type — see I1 below for the cross-module keying hazard this creates |
| §4 `gen-rec` | `processTopGroups:15568` → `processSCCs:15598` → `processSCC:15709` (`compiler/types/typecheck.mdk`) | one shared `λd̄.` prefix over a mutually-recursive group; recursive occurrences reuse it rather than re-entailing | — |
| §4 `gen-sig` (#619) | `checkSigConstraintCoverage:16344`/`checkSigConstraintOne:16350` (`compiler/types/typecheck.mdk`) | `Q_sig ⊩ P'ᵢ` — inferred body context must be entailed by the declared one, not merged | — |
| §4.1 **G1** (uniform dict abstraction at a local binder) | **UNIMPLEMENTED — confirmed absent TREE-WIDE, not just in `typecheck.mdk`.** `dictPassDecl:12377` has exactly four declaration arms — `DFunDef` (`:12378`), top-level `DLetGroup` (`:12388`), `DImpl` methods (`:12397`), `DInterface` default bodies (`:12403`) — then a catch-all `dictPassDecl _ _ d = d` (`:12407`); no arm descends into an expression. The stronger check is on the **name-minting** function: `dictParamName:12685` is the sole producer of a `$dict_<fn>_<slot>` binder, and tree-wide (`grep -rn dictParamName compiler/ --include='*.mdk'`) its only *pattern*-producing callers are `dictParamsGo:12671` and `dictParamsFrom:12680`, reachable only from those four arms — every other caller builds an `RDict` route or an `activeDictVars` entry, i.e. a **reference** to a param a declaration already bound. `llvm_emit.mdk`'s `dictParamNameE:6130` re-derives the same string for a method and creates nothing. And there is **no lambda-lifting pass** that could route a local through the `DFunDef` arm (`grep -rn 'lambdaLift\|hoistLocal\|liftLocal\|closureConv' compiler/` → 0 hits; `desugar.mdk` maps `ELetGroup` structurally at `:73`/`:120-121` and never hoists it) | — | so no `let`/`where` binding receives a `λd̄.` prefix at **any** stage — resolve, desugar, marker, typecheck, IR lowering, or either backend. Separately, even the implemented half has no per-binder key for G1 to extend: the arity a top-level binding gets is read by `dictArityOf:12662`, which is **bare-name** (see the I1 row). G1 additionally needs *local* binder identity — `(name, binding-id)` keying already exists for local scheme *obligations* (`registerLocalScheme:7866`, #837) and is the shape the arity table would need. ⚠️ **G1's absence is uniform across BOTH local spellings** — the `dictParamName` derivation above covers `let` and `where` alike — so an observed `let`-vs-`where` behavioural difference (e.g. #1052's two spellings printing `3` and `2`) is **not** explained by this row. It is explained by the G4 row below: the five sites do not share one pin predicate |
| §4.1 **G2** (value-restriction gate) | 🔴 **HOLED — the gate exists and its predicate is not G2's set.** `genRestricted:3658` is gated on `isNonexpansive:3567` at all five local generalization sites (`blockRecLet:5241`, `blockLet:5261`, `inferRecLet:7871`, `inferLetBody:7953`, `generalizeGroup:9360` via `clausesAreValue:9396`) **and at the top-level site** (`sccSchemes:16054` via `memberClauseIsValue:16063`) — line numbers as of the issue-480 dedupe **and its prose follow-up**, which shifted everything below `isNonexpansive`'s header comment by +35; re-derive with `grep -n 'genRestricted\|isNonexpansive' compiler/types/typecheck.mdk` | a binding generalizes only at a syntactic value | 🔴 **#1150 (OPEN, S0, verified, memory-safety): the constructor-application arm's HEAD test is a first-character heuristic, not a constructor lookup.** `isCtorAppSpine (EVar name) = name != "Ref" && ctorHeadIsUpper name` — and `ctorHeadIsUpper` inspects character 0 only. A module alias MUST be uppercase (`aliasNameFor`, `compiler/frontend/parser.mdk` — lowercase is a hard parse error) and an alias-qualified value desugars to a FLAT `EVar` carrying the dotted name (`rewriteAliasQual`, `compiler/frontend/desugar.mdk`, via `qualifiedLocal`, `compiler/frontend/ast.mdk`), so `ctorHeadIsUpper "H.new"` reads `'H'` and returns True: **every alias-qualified application in the language is classified as a constructor application**. Classification is not the whole test — `isCtorAppSpine (EApp f x) = isCtorAppSpine f && isNonexpansive x` still rejects a spine with an expansive argument, so `H.f (g 1)` is classified but NOT generalized — but the repro's argument is a value: `import hash_map as H` + `let m = H.new ()` yields a polymorphic mutable table: `check` exit 0 with zero diagnostics, `run` `E-NOT-A-FUNCTION`, built binary **SEGFAULT** (exit 139). The safe **alias** spelling (a lowercase one) is forbidden by the language; the selective-import control (`import hash_map.{new}` + `let m = new ()`, head `EVar "new"`) is correctly rejected, so the alias IS the discriminator. ⚠️ **This row's reason changed on 2026-07-31; its verdict did not.** It previously cited **#1139** (the arm folded over the spine's FINAL argument only). #1139 is CLOSED and fixed — `isCtorAppSpine` now tests every argument on its single walk to the head — but that repair does not touch `ctorHeadIsUpper`, and #1150 is strictly wider: #1139 needed a hand-written `data` type with a `Ref` field, #1150 needs one stdlib import. ⚠️ **The hazard TODAY is not the "future uppercase mutable-cell extern" the source comment used to warn about** — that audit (`grep '^extern [A-Z]' stdlib/runtime.mdk`) is clean, one hit, `Ref`, and the predicate is defeated by the alias route anyway. ⚠️ **But that retirement is CONDITIONAL, not permanent, because the GRAMMAR still admits the hazard**: `externNameFor (TUpper x) = emit x` (`compiler/frontend/parser.mdk`) accepts an uppercase extern NAME where `identNameFor` (same file) accepts only `TIdent` for an ordinary identifier. So the instant issue 1150 is repaired NARROWLY — by rejecting a dotted name rather than by asking the environment — an uppercase mutable-cell extern becomes the SOLE remaining way to defeat the head test, and the "defeated anyway" clause above expires with the repair while the warning does not. Asking the environment is not a local change, which is what makes the narrow patch attractive: `isNonexpansive`, `isCtorAppSpine`, `clausesAreValue`, `memberClauseIsValue` and `sccSchemes` all take no `TcEnv`. G3 may not be cited as discharged while this stands |
| §4.1 **G4** (predicate deferral; monomorphising is NOT an approximation) | 🔴 **DIVERGENT.** The five sites above conjoin the value test with `not (pinLocalIfDictForwarded:8947 …)` — the #866/#1021 all-or-nothing pin, which handles a dict-forwarding local by **declining to generalize** it, exactly the move G4 forbids | — | 🚨 **The five sites do NOT share one pin predicate, and this is where a `let`-vs-`where` divergence comes from.** The four `let`-shaped sites call `pinLocalIfDictForwarded:8947`, whose pin set is `dictForwardedPairs callN0 dictN0` (`:8928`) — the dict-app and call-obligation windows, and nothing else. The `where`/let-group site is different: `processLetGroup:8770` computes `pinned = methodConstrainedIds () ++ map fst dictPairs` (`:8791`) and hands it to `generalizeGroup:9310`, which pins on `anyIn free constrained` (`:9318`). So the `where` path pins on a **strictly larger** set — it consults the METHOD-constrained channel that the `let` path never reads. One judgment, two predicates, is an L1 fork, and it is the structural difference that would make #1052's `let` spelling generalize (unpinned ⇒ correct `3`) where its `where` spelling pins (⇒ the collapse to `2`). Stated as the mechanism the source supports; not probed here (no binary). 🔴 **#1052 (OPEN, S0)** is the clause's counterexample and is already filed as one: monomorphising a `where` helper merges two *distinct rigid signature* variables and drops a dictionary slot, printing `2` where G4 says `3`, on both engines, exit 0. #1082 is the migration vehicle; the pin is documented as an interim at `registerLocalScheme`'s `#866 NARROWED THE PREMISE` comment (`:7850-7865`), which states the trade in the same terms |
| §4.2 **OD1** (a decidable predicate is discharged where it is recorded) | 🟡 **ENFORCED, AFTER A REFUTED FIRST ATTEMPT — read the history, it is the whole content of this row.** Two sites must agree: (a) the gate, `checkOneCallObligation`, whose arms reach a verdict on a function-typed vector (`anyListM monoIsFunction`) BEFORE its `allConcreteHeads` arm; (b) the rollback filter `uOblIsDecidableNow` (#1114), which decides what the parametric-impl-body window in `inferUserImplBodies` re-pushes. Re-derive with `grep -n 'allConcreteHeads\|monoIsFunction\|uOblIsDecidableNow' compiler/types/typecheck.mdk` | a predicate entailment can decide now is decided now, by no channel's leave | 🚨 **This row read `✅ ENFORCED` when #1114 first landed and that was WRONG, on a claim that (a) and (b) "share `allConcreteHeads` verbatim".** They did share it, and sharing it was the defect: `headTyconNameMono` enumerates `TCon`/`TRigid` only, so a **fully concrete `Debug (Int -> Int)`** is non-concrete to `allConcreteHeads` while the gate decides and rejects it one arm earlier. The window dropped it, OD4's exemption meant no ambiguity fired, and the predicate vanished with no verdict from any channel — #792's exact three-verdict signature, reached by changing one argument's type. Corrected by deriving the filter from the gate's decision structure and enumerating `Mono`'s heads (`TVar`/`TCon`/`TRigid`/`TFun`/`TEff` after `TApp`-peeling) to show the set is now closed. ⚠️ **The keying assumption is therefore a maintenance obligation, not a property:** any arm added to `checkOneCallObligation` above its `allConcreteHeads` test must be mirrored in `uOblIsDecidableNow`, and **no gate can catch the omission** — a dropped predicate produces silence, which every golden already records for an accepted program |
| §4.2 **OD2** (a non-ground predicate defers to the binding that quantifies its variables) | ✅ **ENFORCED** on the constrained-binding channel: `checkUndeterminedObligation` RULE 2 defers when every free var of the predicate is in `deferrableVarIds`, which `registerSchemeObligations` fills from the POST-generalization `schemeIds` at each group close. The use-site half is `instantiateVarTrackedId`, which re-instantiates the binding's stored predicates through the call's substitution | a forwarded predicate is re-checked at each concrete use rather than at the definition | ⚠️ **The store consulted at the use site is chosen by whether the binding is same-module or cross-module, and the two are different tables.** Same-module: `schemeObligationsRef`, keyed `(name, binding-id)` (#837). Cross-module: `declaredCrossModuleObls`'s three lookups — `qualConstraintFor` (module-qualified), `qualSchemeOblsFor` (#1114 — read key is a BARE LOCAL NAME; what makes it safe is that its table is IMPORT-SCOPED, rebuilt per module from that module's own `DUse` decls, so a name is reachable only from a module whose own import names the module defining it. Calling this "module-qualified" — as this row first did — loses exactly the distinction #1326 turns on), `coreSchemeObligationsRef` (bare NAME, prelude-only). D2 holds identically across a module boundary only for as long as those stay in step; the third is bare-name and survives only because prelude names are deliberately excluded from `currentImportDefinersRef`, so nothing else can key it |
| §4.2 **OD3** (a non-ground predicate with no quantifying binder is ambiguous) | 🟡 **PARTIAL — the rule fires only at instance-count ≥ 2.** `checkUndeterminedObligation`: `Num` is skipped outright (RULE 4a, literal defaulting), a forwarded enclosing dict is skipped (`activeDictVarOf`), a poisoned var is skipped, ONE impl of the interface takes a sole-impl default with no diagnostic, and only TWO-or-more reaches `AmbiguousImpl` | a predicate with no discharge point is rejected rather than silently resolved | ⚠️ the sole-impl default is a deliberate divergence from D3 as written (the source comment calls it out against the oracle's silent first-wins). It is answer-preserving **today** because one impl is the only candidate — but it is a rule keyed on the CURRENT instance count, so adding a second impl anywhere in the graph turns a silently-accepted program into an ambiguity rejection. Not a keying assumption about a table; a keying assumption about the program |
| §4.2 **OD4** (the impl-channel exemption; do not flatten) | ✅ **ENFORCED, and by ONE parameter rather than two checkers** — the payoff of #838 I4. `checkCallObligations`/`checkCallObligationsU` take `deferNonGround`; the method-occurrence channel passes `True` (`map implOblToU perRun.value.implObls.items.value`), the constrained-binding channel `False`. Both call sites sit in `checkBodyImpl`, one per driver arm | D3 is not applied in place to method occurrences; it reaches them out of band, via `registerAmbiguousConstraints` → `PCallSlot` → the other channel | 🚨 **The exemption is keyed on the CHANNEL, and the two candidate alternatives are both wrong in recorded ways.** Applying D3 to the method channel directly rejects a bare receiver var recorded outside any generalized-group window — in neither `deferrableVarIds` nor the RETPOS pass — producing `Ambiguous instance for Traversable` on `main = 0`. Widening `deferrableVarIds` instead is unsound: it is shared with D2 on the other channel, so the genuinely ambiguous RETPOS var would defer too and D3 would never fire. A later unification of the channels must reproduce this split as a fact about populations, not delete it as a mode fork [#863] |
| §4.2 **OD5** (dedup suppresses a REPORT, never a CHECK) | 🔴 **DIVERGENT on the constrained-binding channel — #1330 (OPEN, S0, verified).** `checkCallObligationsU` takes `dedup`; the method-occurrence channel passes `False` and checks every recorded predicate (correct, #863), but the constrained-binding channel passes `True` at BOTH driver arms and the skip is of `checkOneCallObligation` itself: `if dedup && contains key seen then …` recurses without checking. So the rule holds on one channel and is violated on the other | two predicates with one key and two verdicts both reach a verdict | 🚨 **The key is derived from argument HEAD constructors; the rule it hides is checked BELOW the head.** `oblDedupKey` renders `(iface, arity, present positions, each position's head)`, then a matched conditional instance's `requires` is walked by `checkNestedReqs` — so `Display (Color, Int)` and `Display (Int, Int)` share `Display/__tuple2__` and disagree, and LIFO order decides which survives. Measured on this build: `data Color = Red` plus `main = let _ = println (Red, 3)` / `println (1, 2)` — **five lines, no imports** — gives `check` **exit 0**, `build` **exit 0**, and the built binary **exit 139, segfault**; the offending line ALONE rejects correctly, and swapping the two lines rejects. This row read `✅ ENFORCED` when #1114 landed, on the strength of the impl channel's flag; that was a claim about one channel presented as a claim about the rule [#1330, #863] |
| §4.2 **OD6** (every consumer discharges the same set) | 🟡 **PARTIAL — four violations drained, three measured residuals.** Drained by #1114: the parametric-impl-body window discarding decidable predicates (#792) in BOTH its ground (`debug Bar`) and structurally-refutable (`debug bumper`, `bumper : Int -> Int`) forms; and the cross-module store holding only DECLARED contexts (#845) both DIRECTLY and through an `export import` re-export hop. All four are pinned in `test/run_check_agreement_fixtures/`, which asserts check == run == build by exit code AND forbids rejection-by-panic | `check`, `run` and `build` accept exactly the same programs | 🔴 **THREE RESIDUALS, each measured on a built binary, none inferred.** (1) **#1330** — the OD5 row above; five prelude-only lines, `check` 0 → `build` 0 → segfault. (2) **#1326** — two modules exporting the same bare name, one constrained and one not, both imported into one scope: `No impl of Display for NoDisp` at the UNCONSTRAINED binding's call site. Independent of #1114 (reproduces with its lookup ablated to `None`, and with both bindings SIGNATURED), so it is the #739/#1070 bare-name family. (3) the `run`-only face of (2): `run` printing *"type error … Run `medaka check` for details"* for a program `check` reports nothing about — a divergence that names the very command which will not reproduce it |
| §5 method dispatch (arg/result/phantom position) | `inferMethodAt:4619`; `resolveSites:10057` (return-position); `argDispatchIndices:2746`/`prePassDictArg:9742` (arg-position) | dispatch type is fixed by `var`'s instantiation regardless of `ā_C`'s position in `τ_m` | — |
| §5 arg-tag dispatch = optimization, not semantics | (i) `narrowMethod`/`methodAtNarrow:1048-1069` narrows by a STATICALLY-computed `Route` key, not a runtime inspection. (ii) The genuine runtime-argument-inspection fallback is `applyOpt (VMulti vs) arg = collectPartials [] (filterByTag vs arg) arg:870` → `filterByTag:888-891` → `runtimeTypeTag:384-397` → `matchesTag:1088-1090` (all `compiler/eval/eval.mdk`) — reached whenever a VMulti (unnarrowed method candidates) is applied to a runtime argument | (i) is sound by construction (the key was already the `min⊑` winner at typecheck time — this is NOT arg-tag dispatch in §5's sense at all, despite the name). (ii) IS §5's arg-tag dispatch, and its side condition is **not verified**: `runtimeTypeTag` discriminates at **bare head-tycon granularity only** (`VList _ => Some "List"`, `:391`) — it cannot distinguish `List Int` from `List a`, nor (per the sharper counterexample below) `T Int` from `T Bool` | 🔴 **Already tracked, more precisely than this row first put it: #1113** (OPEN, part of this same target-architecture arc). #1113's own text corrects the "no overlap below the head" framing this row started from: *"`impl C (T Int)` / `impl C (T Bool)` don't overlap and the tag `T` determines nothing; multi-param interfaces likewise"* — so even NON-overlapping instances differing past the head are mis-discriminated by `runtimeTypeTag`'s granularity. #1113's own stated target fix ("computed once post-K from the global IE, frozen into the elaboration output... never re-derived") confirms today's `filterByTag` is exactly the ad-hoc mechanism it plans to retire |
| §5.1 **M1** (impl completeness) | `checkImplCompleteness:10862` (whole-program scan) **and** `checkImplCompletenessMap:10922` (the multi-module keyed twin), pushing `T-INCOMPLETE-IMPL` via `pushIncompleteImpl:10868`; required set from `requiredMethodNames:10908` (methods whose merged `IfaceMethod` carries no default) | every non-defaulted interface method has a body in the impl, so `methods(e).m` is total | ⚠️ two implementations of one judgment (the scan and the map), kept in step by hand — the map's comment (`:10920-10921`) states its keying assumption outright: *"Interface names are globally unique, so the map's last-write-wins carries the same required-method list the scan's first-match returned."* **§8 I4 makes that premise false**, and the failure is silent in the last-write-wins direction: two same-named interfaces in one graph, one required-method list. Error location is `firstImplMethodLoc:10892` — the first present method body, `None` for a wholly-empty impl |
| §5.1 **M2** (no extraneous methods) | ✅ **ENFORCED — at RESOLVE, not typecheck.** `checkImplDecl:1227` → `checkImplIface:1241` → `checkMethodMember:1252`, which rejects any `ImplMethod` whose name is absent from `ifaceMethodsOf iface env.ifaceMethods` with `MethodNotInInterface` (`resolve.mdk:119`), rendered at `ppResError:1912`, code `R-METHOD-NOT-IN-INTERFACE` (`resErrorCode:1955`). Runs on **both** env paths — `ifaceMethods` is populated at `resolve.mdk:1428` (single-file: prelude ++ user) and `:2472` (multi-module: ++ imported) — so it fires on `check`, `run` and `build`. Typecheck's own arm is **inert**: `inferImplMethod:14396`'s `None` arm (`:14398`) is `()`, so the extraneous body is never inferred; the guarantee comes entirely from resolve | an impl body under a name the interface does not declare is rejected before typecheck ever sees it | ⚠️ **keyed on the BARE interface name**, and `ifaceMethodsOf:1246` is a **first-match** assoc over `pIfaces ++ uIfaces ++ impIfaceMethods`. Two interfaces sharing a name in one graph resolve to the *first* list, which can both spuriously reject a legitimate method of the second and spuriously accept an extraneous name that happens to be in the first — §8 I4's hazard on this exact check (structural reading; not reproduced here, no binary). ⚠️ **Quality residual, not a soundness one:** the error is constructed with `None` for its location (`:1257`) and so prints `<unknown location>`, even though `checkImplMethod:1237` has `firstExprLoc body` in hand two lines away — an unfilled slot, `compiler/ERROR-QUALITY.md` dimension. **Scope note:** M2 is a rule about the *name* only; a body under a **correct** name with the wrong arity or type is W3's business (`inferImplMethod`'s unification), not M2's, and this row does not claim otherwise |
| §5.1 **M3** (phantom methods: reject the undetermined USE, not the declaration) | 🔴 **DIVERGENT.** `checkPhantomMethods:10995` → `phantomMethodMsgs:11001` → `phantomMethodMsg:11007`, pushing `T-PHANTOM-METHOD`, run from `runFinalChecks:11052` | rejects a method whose declared type mentions none of the interface's parameters | 🔴 keyed on the **`DInterface` declaration alone** — `phantomMethodMsgs` matches `DInterface` and nothing else, so the rule fires with **zero impls and zero uses in the program** and can never see whether a use is determined. This is #1134's over-rejection, stated structurally rather than behaviourally. ⚠️ a second, separable defect in the same site: the diagnostic is pushed with `pushTypeError:2932`, which attributes to `currentLoc.value` — the *live* location at the end of the run, not the declaration — so the caret lands wherever inference last was (on #1134's repro, the impl body). The location is not a deliberate attribution and should not be read as one |
| §6 **C1** (at most one most-specific instance) | `cohScan`/`cohScanInner`/`cohClassify`/`cohStrictlyMoreSpecific`/`cohMutuallySubsumes`, invoked from `checkCoherence` (`compiler/types/typecheck.mdk`) — **symbol names only, deliberately.** This row's line numbers were captured at `c4ef6dbe` and had drifted by the time it was next read, which is the failure this table's preamble warns about. ⚠️ **A number was not merely stale, it was UNRECOVERABLE by re-measurement: drift here is NON-MONOTONE.** Two agents re-derived this row's drift honestly, in different trees, and got answers an order of magnitude apart — a large deletion upstream in `typecheck.mdk` pulls every citation below it back *toward* its captured value, so "how stale is this citation" has no single answer and a recorded delta is worth less than no delta at all. Re-derive each symbol with `grep -n '^<symbol>' compiler/types/typecheck.mdk`, as this table's preamble already instructs | rejects ambiguous overlap at declaration time | ✅ **THE §6.1 (a)-VS-(c) DIVERGENCE (#614, #311) IS CLOSED as of F-3d, 2026-08-01 — but by DEMOTION, not deletion, and the difference is load-bearing for anyone re-deriving this cell.** Until then `cohConflictWith` scanned **all declared pairs** and rejected on any `⊑`-incomparable pair — §6.1 choice-point 2's condition **(a) global comparability** — where the spec commits to **(c) per-goal unique minimum**, so the spec's own `Pair` counterexample (`C (Pair Int a)`, `C (Pair a Int)`, `C (Pair Int Int)` — accepted under (c)) was rejected. `cohClassify` now **splits** that arm: a `⊑`-**incomparable** pair is a `W-INCOMPARABLE-IMPLS` **warning** (exactly the *"MAY additionally warn at declaration time on (a)-violations … but acceptance is per-goal"* §6.1.2 licenses), and acceptance passes to the goal-site `min⊑` reject. The `Pair` triple now compiles and prints `3` (`test/dict_fixtures/s6-1c-per-goal-unique-min-accepted.mdk`). ⚠️ **A MUTUALLY-`⊑` (α-equal) pair is still a hard `T-CONFLICTING-IMPL`, and that is not a residual over-rejection to be tidied away later** — it is this cell's own last ⚠️ made operational. α-equal heads **satisfy (a)**, so they were never (a)'s to demote; they violate **C1** outright (two `⊑`-minimal elements), and the goal-site reject **cannot** see them, because `entryCovers` is `tyHeadEqV \|\| tyStrictlyMoreSpecificV` so two equal heads cover each other and `findMostSpecificEntry` returns `Some`. Demoting that class with the rest would have accepted a program the spec rejects, ordered by declaration, with nothing left to report it. The one genuine residual is that this site is still **goal-blind**, so it warns/rejects on a declared pair even where no goal poses it. ⚠️ **The widening has its own price, accepted knowingly under #311's owner decision and tracked at #1183, and it is a conformance LOSS against §6.2 sitting beside a conformance GAIN against §6.1 — do not read the two as one verdict.** At a **non-closed** goal F-3c's goal-site *arm* is correctly silent: T4 defers such a goal rather than deciding it, so a reject there would be caused by our own early commitment. But T4's verdict on the *program* is not "accept" — it says the goal is decided at quiescence and, if still not closed there, **"rejected as ambiguous — never committed to a default instance, and never left to an engine to pick"**. This implementation has no quiescence pass, so it commits at the group's end instead: `test/dict_fixtures/s6-2-t4-open-goal-deferred.mdk` compiles, and its value is decided by `impl`-block order at exit 0 (`1`; `2` with the blocks swapped). Before F-3d condition (a) rejected that program for an unrelated reason, so the T3/T4 divergence this table already records was not user-visible; it now is, under the (a) warning rather than in silence. Closing it is T4's own work, which T4 forbids landing before I5. 🔴 **The cited site is GOAL-BLIND, so it does not EXERCISE this clause as reworded — it SUBSTITUTES for it, and only by being stronger than it** (stronger than the spec-level (a) too — see the last ⚠️ in this cell). `checkCoherence` folds over declared impls and never sees a goal, rigid or ground, so C1's rigid half (the ⚠️ in §6 C1) is covered here by accident of that strength, not by anything that would survive (a)'s relaxation. **The rigid half is live, and both halves of that were probed on a worktree build at `c88859c0`, not inferred.** (i) `min⊑` really does run and decide at a rigid goal: against `impl D (P a b)` + `impl D (P a Int)`, the binding `g : P x Int -> Int` / `g p = dv p` emits `call @mdk_impl_D__P_a_Int___dv` as the whole of `g`'s body (`medaka build --keep-ir`) — the strictly-more-specific of the two instances matching the rigid goal `D (P x Int)`, with both impls emitted in the module, so the choice is the typechecker's and not DCE's; `run` and the built binary both print `2`. (ii) (a) is what keeps that goal out of the ambiguous case: add a third impl and make the pair incomparable — `impl D (T a b Int)` / `impl D (T a Int b)` / `impl D (T Int Int Int)` — and the program is rejected at the *second declaration*, *"Overlapping impls of D: T a Int b and T c d Int can match the same type. Make them disjoint, or wrap one type in a newtype"*, even though its **only** `D` goal is the rigid `D (T x Int Int)` inside `g : T x Int Int -> Int`. Relax (a) to (c) (**F-3d** of #311) and the per-goal site inheriting the clause is the §3 `min⊑` row's `pickMostSpecificEntry` — ✅ **whose no-unique-minimum arm is a hard `T-AMBIGUOUS-INSTANCE` since #1155 / F-3c (2026-08-01), so that site is now ready to inherit it.** This cell said the arm "returns the head of the candidate list"; it still does *return* that entry, but it also rejects. F-3c supplies the rigid half of C1's requantification that this cell records as covered only "by accident of [(a)'s] strength": `test/dict_fixtures/s6-c1-rigid-goal-no-minimum.mdk` is a program (a) structurally cannot see — one user impl, incomparable with a PRELUDE impl, and coherence's input is user decls only — which now rejects at the goal, and its `-no-call-discriminator` sibling poses NO ground goal at all. ⚠️ **What F-3d must supply is the other half: the reject is gated on the goal being CLOSED (§6.2 T3), and today that gate changes no VERDICT** — every program reaching it is rejected by (a) anyway, at the declaration. It is nonetheless **reachable and pinned**, by `test/dict_fixtures/s6-2-t3-closed-goal-reported.mdk` + `…-t4-open-goal-deferred.mdk` (one token apart; the open half asserts the ambiguity code is ABSENT, since verdict/exit/stdout are identical across the pair). ⚠️ F-3c first shipped the claim that the gate was *unreachable*, arguing from this very cell that (a) keeps a ⊑-incomparable pair with a shared bare-variable argument away from the selector. That inference is **false**: a declaration-time rejection is not an early exit — errors accumulate — so both impls are registered and the goal reaches `min⊑` regardless. Relaxing (a) is what makes the open half a legal program rather than what makes it constructible. ⚠️ **That §3 row's forward reference to "why this path is believed unreachable" resolves here, and the answer is that it is NOT unreachable — the belief holds only for the goals whose candidate set really is `match(IE, π)`.** (a) compares only pairs whose heads unify, so it never sees two **disjoint** impls that a *deformed* candidate set delivers to the selector together; issue **#1154** (OPEN, S0) is that path, reproduced first-hand here rather than relayed — `111` with its two `Ix` impls in one order, `222` with them swapped, `check --json` reporting `"diagnostics":[]` and exit 0 both ways. (Its context predicate `Ix a Char` is *written* at the rigid impl-head variable `a`; whether the selector is reached at `a` or at its ground instantiation was **not** established here, and this row does not claim it — the deformation, not the rigidity, is what defeats (a) in that case.) ⚠️ **The site is also STRONGER than the (a) §6.1.2 states, which matters to anyone deriving one from the other.** (a) asks only for `⊑`-**comparability**, which two α-equal heads satisfy; `cohAnonConflict` instead falls through only on `cohStrictlyMoreSpecific xs ys` or `cohStrictlyMoreSpecific ys xs`, so mutually-subsuming heads reach its `otherwise` arm and are rejected — closing, in the implementation, the ladder hole §6.1.2's ⚠️ records (at **(b) ⇒ (c)** under the preorder reading of (b), at (a) ⇒ (b) under the antisymmetric one; **(a) ⇏ (c)** either way). Read the direction carefully: the tree is stronger than the clause here, so this is a place where auditing the implementation against (a) would *understate* what it enforces |
| §6 **C2** (superclass consistency) | No SINGLE dedicated check — but TWO independent by-construction mechanisms were located, not merely the spec's own disclaimer. (a) `argImplDictRoutesForEncl:12187-12192`/`entailInst`'s EKReturn+EKArg arms (`:11974-11978`, the #609 fix); (b) `expandSupersTable:5037-5041` (WS-1b) | (a) selects the SAME impl for the dispatch route and its own `requires`-context routes — comment at `:12175-12177` names the failure mode explicitly as "evidence for instance A attached to methods of instance B (§2 "evidence is a tree"; §6 C2 coherence)". (b) sidesteps the question for `=>`-constrained-fn super slots by construction: the dict *value* is a bare type tag identical across the whole `requires` chain, so "the super slot's route is identical to the sub slot's route — no separate projection is needed" (comment at `:5028-5029`) | (a) is keyed by the SAME goal-vector selection as `inst` (row above); (b) is keyed by (fn, transitive-superinterface) slot pairs, deduped by `(iface, id)`. Neither is a dedicated "check that C2 holds" — both are designs that make a C2 *violation* structurally unreachable, which is a stronger form of the spec's own claim ("the invariant to check, not an independent obligation") than a blank "no site" first suggested |
| §6 **C3** (resolution determinism) | same dispatch path as `inst`/precedence rows above | entailment returns the same evidence regardless of search order | ⚠️ **#1072 (OPEN S0)**: "most-specific-wins is decided by MODULE ORDER — the bare-head word is OR'd into every arm, so a site whose module sees only the general impl calls it instead of the specific one" — a live counterexample to order-independence |
| §6 **C4** (single instance environment) | `loadDataUniverse:16973`/`storeDataUniverse:16983`/`appendUniverseAccums:16925`; `univConcreteBucket:13702`/`univHeadless:13707` (`compiler/types/typecheck.mdk`) | `IE`/`CE` global after import resolution | see I2 below for the identity-keying discipline this depends on |
| §6 uniform resolution corollary | no single dedicated site — structural consequence of every resolution position sharing `entail:11892` | all resolution positions agree on the same-goal evidence | audit-level claim, not an independently-checkable function |
| §6.2 **T1** (groups = SCCs of the reference graph, topological order) | `processTopGroups:15568` → `tarjanSCCs` over `depGraphMap` → `processSCCs:15598` → `processSCC:15709` (`compiler/types/typecheck.mdk`); `isLetrecGroup:15789` distinguishes a multi-member group from a singleton | dependency-first group order; one shared `λd̄.` per mutually-recursive group | ⚠️ the graph's node set is **top-level value bindings only** — `depsOf:15579` builds edges from `allEVars` over `clausesOf`, so `impl` bodies, `default` bodies, prop and test bodies are **not nodes**. They are inferred after every SCC has generalized (`processTopGroups` at `:13009`; `inferImplBodiesIfEnabledIn` at `:13020`/`:13035`), which satisfies T1 for them only because nothing schedules them at all |
| §6.2 **T2** (a later group observes only the earlier group's scheme) | structural: `processSCCs:15600` threads the environment forward as `snd er ++ …` over `fst er`, and the only thing added is `extendVars env (dropSchemesNamed …) schemes` (`:15782`) | no evidence, route, or instance choice crosses a group boundary — only schemes | keyed by binder name into the environment. The second half of T2 (a non-generalized binding's monotype carries **live** metavariables into later groups) is structural too: `genRestricted:3606`'s non-value arm returns `monoScheme t` after `lowerToCurrent:3582`, i.e. the same cells |
| §6.2 **T3/T4** (`inst` commits only on a closed goal; non-closed goals resolve at graph quiescence) | 🔴 **DIVERGENT — the drain is per-MODULE, not per-graph.** `elabModuleStamp:18570` runs `checkModuleFullImpl` and then all nine stampers (`resolveSites`/`resolveOpSites`×2/`resolveArithSites`/`resolveArgStamps`/`resolveRLocalSites`/`realizeRecDictApps`/`resolveDictApps`/`resolveMethodDicts`, `:18581-18589`) for that module before the next one; the flat twin is `elaborateDict:9424` | — | the module boundary is what today's drain is keyed on, and its own comment (`:18558-18561`) states the assumption: *"the tyvar cells are still bound (the next module's `resetState` hasn't run yet)"*. `resetState:3265` mints a fresh `PerRun`, which drops the pending-site lists — but **not** the tyvar cells, which live in the `Mono` values an exported scheme shares. So a later module can still ground a metavariable whose routes were already stamped. T4 exists to remove that window; it is **not** a formalization of current behaviour, and the target-architecture note that quiescence "matches today's whole-module-then-stamp behavior, extended" should be read as *extends*, not *describes* |
| §6.2 **T5** (freeze-at-module-close REJECTED) | N/A — a rejected alternative | — | recorded so a later implementation does not adopt it as an optimization: it is sound but narrowing, and it makes module partitioning semantically significant |
| §6.3 **D1** (defaulting placement) | four boundaries, each running the defaulting primitive *before* `registerAmbiguousConstraints:9199` and before generalization: `blockRecLet:5202-5203`, `blockLet:5218-5219`, `inferRecLet:7832-7833`, `inferLetSimple:7897-7898`, and the group boundary `processSCC:15754-15756` (`defaultGroupNum` then `defaultEachMember` then `registerAmbiguousConstraints`); plus two method-body boundaries with no paired ambiguity check — `inferDefaultMethod:13489` and `inferImplMethod:14546`, both `defaultBodyLocalNum` | defaulting is the last determination step at its boundary | ENFORCED as an ordering at each site; there is no single place the order is written, so D1 holds seven times by construction rather than once by statement |
| §6.3 **D2** (defaulting substitutes, never discharges) | `groundNumVars:9273` grounds by `unify m (TCon "Int")` (`:9277`) — an ordinary unification, so the now-ground predicate is checked by whatever would have checked it | a defaulted variable's obligations are still obligations | ENFORCED by mechanism (substitution, not removal). Note the *choice* this encodes: the target is always `Int`, with no `default`-declaration analogue and no fall-through to a second type |
| §6.3 **D3** (the taint rule) | candidate set from `numConstrainedIds:9103`/`numObligIds:9106` (`iface == "Num"` only); the surviving-channel filter is **two different predicates**: `monoArgUnboundIds:9096` (outermost arrow **domains** only) at `defaultAmbiguousNum:9111` and `defaultGroupNum:9129`, versus `monoUnboundIds` over the **whole** member type at `defaultBodyLocalNum:9164` | which `Num`-constrained variables may ground | 🔴 **PARTIAL / tracked.** Neither predicate is D3's channel rule: `monoArgUnboundIds` under-approximates it (a return-position variable, and *every* variable of a nullary method type, get zero protection — the function returns `[]` on any non-`TFun`), and `defaultBodyLocalNum`'s whole-type test approximates it from the other side. The **instance-head** channel D3's open bullet asks about is in neither. Tracked as **#563** (return/nullary blind spot, `verified`) and **#564** (the missing ambiguity pairing); both close against §6.3 |
| §6.3 **D4** (level discipline) | `registerAmbiguousConstraints:9199` computes `groupLevel = perRun.value.currentLevel.value + 1` (`:9205`) and `registerDispatchMonos:9250` filters on `snd p <= groupLevel` against `monoUnboundVarLevels:9263` | "belongs to this boundary" vs. an inner binder's leaked obligation | ⚠️ the level is derived from the **ambient** `currentLevel`, valid only because every precedent site runs `enterLevel`/`exitLevel` around its bodies and calls this post-`exitLevel`. The impl-method-body boundary has **no `enterLevel`/`exitLevel` at all**, which is why it hosts `defaultBodyLocalNum` and *not* `registerAmbiguousConstraints` — #564's recorded prerequisite, stated here as the keying assumption it is |
| §7 single-evaluator law | `evalMethodAt:1223`/`dictOfRoute:1025`/`applyDicts:1013` (`compiler/eval/eval.mdk`); `emitMethod:4226` (`compiler/backend/llvm_emit.mdk`); `emitMethodRef:3548` (`compiler/backend/wasm_emit.mdk`); cross-engine agreement enforced by the GATE `test/diff_compiler_engines.sh`, not a shared source site | three independent emit/eval implementations of the same `Route` dispatch stay in agreement | agreement is kept by convention + the differential gate, not by one shared function body |
| §7.1 **U1/U2** (driver unimodality) | 🔴 **DIVERGENT — a second mode is live.** `data CheckMode = Flat (List Decl) \| Module String (List Decl) (List Decl)` (`compiler/types/typecheck.mdk:12822`); `checkBodyImpl:12824` branches on it at **20 `Flat` arms** (derive: `grep -c '^    Flat ' compiler/types/typecheck.mdk`, against 21 `match mode` sites), and the two paths run different route-stamper sequences (`elaborateDict:9424` vs `elabModuleStamp:18570`) | — | the sole `Flat` constructor site is `checkProgramSeededSplit:12804`. **Do not read a consumer count out of this row — derive it:** `grep -rln 'elaborateDict\|checkProgramSchemes' compiler/entries/ compiler/tools/`, then `grep -n` each hit to separate real call sites from comments (at `128da26c` the file grep yields **12**, of which **10** call and 2 mention it only in prose). An earlier revision of this row listed five files and said "six external consumers" — wrong, and wrong in the way this table's own preamble warns about; the missing ones are load-bearing: **`tools/lsp.mdk:694`**, **`tools/snapshot.mdk:624`** (so a *gate* runs on the flat path), and **both typed emit entries**, `entries/llvm_emit_typed_main.mdk:66` and `entries/wasm_emit_typed_main.mdk:61` — which is where U2 bites hardest, because those paths produce **IR**. Add `entries/profile_main.mdk:247` and the flat re-entries inside `typecheck.mdk` itself: the promotion fallback (`:9434`, `:9463`, `:9556`) and `checkMatchToLines:16722` (`:16725`). ⚠️ `compiler/DRIVER-COLLAPSE-PLAN.md`'s **status line says IMPLEMENTED**; this row is the measured counterexample §7.1 retires it with |
| §8 **I1** (evidence abstraction keyed by binding identity) | `dictArityOf:12662` (BARE-NAME, define-side only) vs. the cross-module qualified path `crossModuleFunConstraintsQualRef:2545`/`inferDictAtFound:4918` | dict-param count/order is part of the binding's identity, not its bare name | ⚠️ self-documented live hazard at lines 2415-2444: `dictArityOf`'s bare-name first-match "returns the WRONG module's arity" for two same-named fns of different `=>`-arity. The qualified table fixes the CALL-SITE (importer) leg; `dictArityOf` itself stays bare-name, safe only for the DEFINE-side prepend within the owning module — a residual sharp edge, not asserted as a currently-reproducing bug here |
| §8 **I2** (global instance environment after import resolution) | `importFormSchemes:17309`/`aliasSchemes:17290`/`aliasConstraintEntries:17324` (`compiler/types/typecheck.mdk`) | import scoping affects visibility, never evidence identity | — |
| §8 **I3** (evidence travels, not re-derived) | No INDEPENDENT site — but not because none was located; re-audited with I1's vocabulary (`inferDictAtFound`, `crossModuleFunConstraintsQualRef`) rather than I3's, and the same site applies: `inferDictAtFound:4918` (row I1 above) is exactly the mechanism that lets a cross-module CALLER supply the callee's dict args rather than the callee re-deriving anything | a cross-module call passes evidence as ordinary leading dict arguments (`var`, row above), sized by the callee's identity-keyed arity (I1) — there is nothing *for* the callee to re-resolve; it receives dicts as parameters like any other argument | this is a structural consequence of dict-PASSING itself (the callee is a function of its dict params, not a re-resolver), not a separately-checkable rule — same shape as C2's finding: the right conclusion is "enforced by the calling convention," not "unimplemented" |
| §8 **I4** (module-qualified identity in every namespace; use-site ambiguity) | 🔴 **PARTIAL.** ⚠️ **The headline count was WRONG, and had been since before this cell was last touched — re-derive it, do not trust a number written here (including this one).** This cell used to read "two of six namespaces"; re-derived 2026-08-03 it is **five of six** (values, data constructors, types, aliases, interfaces are enforced; only record names are not) — see the derivation below, and re-run it rather than trust either count. ⚠️ **Line numbers in this cell were RE-DERIVED at `fa07eaa7` (2026-08-01); the previous set was stale by 2–296 lines in `compiler/frontend/resolve.mdk`/`compiler/types/typecheck.mdk` and by 959 on one `compiler/types/typecheck.mdk` citation — re-derive with `grep -n '^<symbol>' <file>` rather than trusting these, exactly as this table's preamble and the C1 row instruct.** ENFORCED for **values**: `checkVar:590` → `isAmbiguous:641`/`ambigMods:646` → `AmbiguousOccurrence` (pushed `:600-601`), code `R-AMBIGUOUS-OCCURRENCE` (`resErrorCode:1924`, arm `:1947`), set built by `ambiguousSet:2244`/`keepAmbiguous:2250`. ENFORCED for **data constructors** (#674): `checkPat:393` (push `:398`) and `checkVar:604` → `isCtorAmbiguous:653` → `R-AMBIGUOUS-CTOR`. ENFORCED for **record-field selection**, in *typecheck* rather than resolve and exactly in qualification 2's shape: `resolveFieldByOwners:5688` → `resolveFieldAmbiguous:5699`, which pushes `T-AMBIGUOUS-FIELD` (`:5702`) **only when the receiver is still an unbound var** (`TVar _`) — a receiver whose type is known picks its owner and never consults the name. 🚨 **THIS CELL USED TO SAY "UNIMPLEMENTED for types, aliases, interfaces, and record *names*" — FALSE for three of those four, and not merely stale prose: the derivation it offered for that claim was itself wrong.** `grep -rn AMBIGUOUS compiler/ --include='*.mdk'` finds **six** ambiguity codes, not four: the four above plus `R-AMBIGUOUS-TYPE` and `R-AMBIGUOUS-INTERFACE` (`resErrorCode:2119-2120`), landed by Stage A-1's unit E/F — *before* this cell was last edited, so this was never a drift introduced downstream of it. Both are wired in, not dead code: `checkType`'s `TyCon` arm (`:366`, not `:340`) calls `ambiguousTypeErrors` (`:430-432` → `isTypeAmbiguous`/`typeAmbigMods:749-757`) once a name passes the existence test, and `checkConstraint` (`:461-462`, not `:388`) calls `ambiguousIfaceErrors` (`:456-459` → `isIfaceAmbiguous`/`ifaceAmbigMods:775-782`) the same way. So: ENFORCED for **types**, which subsumes **aliases** — a `type` alias is a `DTypeAlias` occupying the identical `env.types` namespace and reached by the identical `TyCon` occurrence check, not a separate mechanism. **Verified live, not inferred from source:** two modules `export type T = Int` and `export type T = String`, imported together and used in a signature `f : T -> T`, report `Ambiguous type: 'T' is brought into scope by both \`amod\` and \`zmod\`. A type name can be neither qualified nor aliased, so import it from only one — drop 'T' from the other's import list` at exit 1, in **both** import orders (swapping which import line comes first only swaps the module names in the message). ENFORCED for **interfaces** too: `test/resolve_module_fixtures/ambiguous_type_iface/` already pins `AmbiguousInterface` alongside `AmbiguousType`, predating this cell's stale claim. **STILL UNIMPLEMENTED for record *names***: a record name resolves through `recordByNameRef`, a last-write-wins map with no ambiguity diagnostic, and no seventh ambiguity code exists for it — the closest sibling gap (a record-literal-head *constructor* colliding across modules, not the record type name) is tracked and pinned live at `#1253` (`test/must_fail_fixtures/1253-record-head-ctor-ambiguity-import-order/`). `T-AMBIGUOUS-INSTANCE` remains instance selection, not naming. Interface *methods* are values, so they inherit the value rule; the interface *name* now has its own rule too | a use site whose name yields no unique origin is rejected; the declarations are not | ⚠️ the implemented half is not identity-carrying either — it is a *diagnostic* over a name→module provenance map, not a resolution to an identity the AST carries. Type-name→origin resolution still happens **inside typecheck** (`fromAstTypeE:4266` reading `aliasTableRef`), and value binder ids are minted **inside** `checkBodyImpl` (`stampBindingIds`, declared in `compiler/frontend/resolve.mdk`, *called* from `compiler/types/typecheck.mdk` — re-derive both with `grep -n 'stampBindingIds' compiler/frontend/resolve.mdk compiler/types/typecheck.mdk`) and are per-run integers, not `(module, name)`: the declaration is `let top = numberFrom 1 (dedup (topBinderNames decls))`, sequential integers over ONE decl list with no module component, and the call takes the current pass's `prog`, so two modules number independently from 1. ⚠️ **This clause carried two LINE NUMBERS until 2026-08-05 and both had rotted (`resolve.mdk:3106`, `typecheck.mdk:13798`), which is why they are gone rather than refreshed.** The rot was not cosmetic: this row is the one place in the spec that records the value-identity fact correctly, and `TYPECHECK-TARGET-ARCHITECTURE.md` §2 R asserted the OPPOSITE (values "already done via binder ids") for the whole arc — **a correct fact with unresolvable citations does not propagate**, which is the same failure as a citation pointing at the wrong clause, one step further along. The refresh itself makes the point: the numbers proposed to replace them (`resolve.mdk:3402`, `typecheck.mdk:15447`) were derived on `main` and the second was ALREADY WRONG in the branch applying it (`:15563` there, a branch that had only added lines above it). Cite by symbol; let `grep -n` supply the line. [#1337] So no downstream table is identity-keyed today; the #1070 audit's bare-name tables are the consequence, and I4's *"a bare `String` key is not a key"* is the clause they fail. **⚠️ THAT SENTENCE ONCE READ "So no downstream table is identity-keyed today" AND IS NOW FALSE FOR TWO TABLES.** #1111 Stage A-2 unit A-2.3 (2026-08-03) re-keyed `universeAliasTable` and `universeDataParamKinds` (with their `perRun` halves `aliasTableRef` / `dataParamKindsRef`) to a module-qualified `TabKey` (`compiler/types/registry.mdk`), draining #1069, #1090 and #1070's alias row. **The re-keying is MODULE-PATH-ONLY for the flat table's USER half — NOT "no identity can be built there," which is false.** On the flat/single-file driver path the table holds BOTH populations at once: `checkProgramSeededSplit` stamps the PRELUDE's own decls `OriginModule "core"` (`stampDeclOrigins "core" coreProgTy`, `compiler/types/typecheck.mdk:14219`), so those rows register through `registerAllData` → `recordParamKinds` as identity-bearing `TkIdent` rows — the same re-keying this row is about. Every FLAT USER declaration, by contrast, still carries `OriginUnresolved` (`stampFlatTyOrigins`), so `mkIdent` returns `None` for those alone, and they key as `TkBare` until #1115 (E-1) gives that half module ids too — a `medaka check` on a no-import file, the LSP, `doc`, `repl` and the playground are all on that path. What makes a table holding both populations safe is per-population STAMPING AGREEMENT, checked rather than assumed: `flatTyOriginScope` (`compiler/frontend/resolve.mdk:4111-4117`) derives its scope from exactly `dataRecordNames coreDecls ++ interfaceNamesOf coreDecls` — precisely the decl set `stampDeclOrigin` stamps (`dataRecordNames` reaches `DData`/`DNewtype`/`DTypeAlias`; `interfaceNamesOf` reaches `DInterface`) — so a `TkIdent` occurrence never meets a `TkBare` declaration of the same name or vice versa. The remaining `#1070` audit tables (`universeRecordByName`, `universeIfaceRequiredRef`, `universeDataEnv`, the method-name registries) are still bare-name and still fail I4's *"a bare `String` key is not a key"* clause; units A-2.4/A-2.5/A-2.6 own them. ⚠️ **The interface slot-kind table was in that list until 2026-08-04 and is no longer bare-name** -- unit A-2.4 re-keyed its slot-key mint to `regKeyTabAt (ifaceTabKey o iface) i` and #1257 is CLOSED. ⚠️ **That table, its mint and its `universe*` half are RETIRED OUTRIGHT as of #1112 A-3.5c (#1557)**: the slot kinds are stage K's `CE` (`ceRowParamKinds`, read through `ceSlotKindsAt`), so the symbols named here no longer exist -- do not re-cite them. Re-derive this list; do not extend it. ⚠️ The `_ => TCon n` citation earlier in this cell is ALSO stale, and by an EARLIER change than this one — A-1 (#1110) made that arm `tconFrom o n`, so the `Mono` head has carried identity since then even though nothing compared it; the comparison step is scheduled as A-2.10 (#1208). **✅ A-2.10 LANDED IT (2026-08-04) — the sentence before this one is now HISTORY, not a plan.** Six comparisons — `unifyN`, `cohGoR`, `cohStep`, `cohEqR`, `matchStep`, `monoSameGiven` — read the field, all through one seam, `sameTyConHead` (`compiler/frontend/ast.mdk`), whose doc-comment owns the rule and its derivation. #1208 and #1209 are DRAINED (their `test/must_fail_fixtures/` rows deleted; the assertions moved to `test/diff_compiler_check_cli_modules.sh`'s `A-2.10/*` legs). ⚠️ The rule is **not** strict origin equality and cannot be, while identity SUPPLY is incomplete: an ABSENT origin makes no claim, so two heads conflict only when both carry an identity and the identities differ. Copying `tabKeyEq`'s absence-never-matches shape here rejects the compiler's own prelude (measured — an extern-sourced `Int` has no identity and must still meet the builtin one). The residual is a supply gap, not a keying choice, and it closes this rule automatically: at total supply `identOriginOf` never answers `None` and the predicate IS strict equality. ⚠️ 🚨 **AND IT TURNED ONE S0 INTO AN S1 RATHER THAN FIXING IT**: #1256's valid program is now REJECTED (`Type mismatch: Cfg vs Cfg`), because `recordByNameRef` is bare-name keyed and hands back a well-formed identity belonging to ANOTHER module. That is the general shape — a bare-name-keyed table that STORES a head is an identity-SUPPLY defect, and this rule converts each one from silent wrongness to a loud false reject. DERIVE the member set from the rule -- a member is a table keyed by a BARE NAME **and** storing a type head, or a scheme containing one -- rather than reading a list here (including this one): #1256 (`recordByNameRef`) and #1259 (`universeDataEnv`, constructor schemes). ⚠️ **This cell listed #1257 (the interface slot-kind table, then keyed by an identity x slot composite) as a third member until 2026-08-04, and that was wrong twice over**: it stores KINDS, not heads, so no wrong head can flow out of it (which is what #1111's own comment already said); and it had been re-keyed by unit A-2.4 and CLOSED (2026-08-04 02:23:34Z) an hour before A-2.10 opened -- the mint was `regKeyTabAt (ifaceTabKey o iface) i`, identity-keyed (and the whole table is gone since A-3.5c). Three other artifacts agreed with each other and this one disagreed, which is exactly the direction a canonical spec must not be wrong in. Re-derive the citations rather than trusting them. 🔴 **The type half is stronger than "a missing diagnostic", and this row understated it at first.** `fromAstTypeE:4266`'s `TyCon` arm bottoms out at `_ => TCon n` (`:4278`) — a **bare-name** `Mono`. Two modules that each `public export data Thing` therefore do not merely go undiagnosed at the use site: their types are *the same `Mono`* and are silently **identified**, so a function declared over one module's `Thing` accepts the other's constructor, typechecks green, and dies at run time on a pattern match that cannot see the foreign constructor. ⚠️ **THAT COLLAPSE IS FIXED as of #1111 A-2.10 (2026-08-04) and this sentence describes the PRE-A-2.10 tree** — it is #1208's repro verbatim, and #1208 is drained: the two `Thing`s carry different `OriginModule` ids, `unifyN` reads them, and the program is rejected at `check` with a diagnostic naming both modules. What is NOT fixed is the paragraph's premise — `fromAstTypeE`'s arm has minted `tconFrom o n` since A-1 — so re-derive the citation before reusing it. The record-NAME half of this row stays UNIMPLEMENTED, and A-2.10 made it louder rather than closing it (see the I4 note above on #1256). That is a type-identity collapse — the `Mono`-level half of #1070 that its own audit records as *"impossible to re-key per table, because the collapse already happened upstream"*, and #1047's family. I4 is what makes it unwritable; a use-site ambiguity diagnostic alone would not. Two exemptions realize I4's qualification 1 (scoping resolves before ambiguity applies) for values, and they live in **two different functions** — this cell previously attributed both to one: `foldProvenance:2220` skips `core` outright (`mid == "core"`, `:2224`, so a prelude name never contributes a provenance at all), while `keepAmbiguous:2250` drops any name that has a same-module top-level definition (`not (contains n sameMod)`, `:2253`) |
| §8 **I5** (instance candidacy is graph-global) | 🔴 **PARTIAL — cumulative, not global.** `foldModules` threads `accAll ++ prog` and `appendUniverseAccums` grows the persistent impl universe (`growImplUniverse` over `implDeclsWithReqs`) one module at a time, in the loader's dependency-first topological order (`compiler/driver/loader.mdk`, the DFS topological sort — `grep -n 'DFS topological sort' compiler/driver/loader.mdk`) | the candidate set a goal is resolved against | so a module's candidate set is *every impl of every module earlier in the topological order*, plus its own — which is **strictly more** than its transitive imports (an unrelated sibling subtree fully visited earlier is included) and **strictly less** than the graph (nothing later is). The first half is order-dependence of exactly #1072's kind; the second is what I5 removes. ✅ the visibility half of I5 already holds: `implDeclWithReqs` matches `DImpl { iface, tys, reqs, … }` and **never reads its `pub` field**, which `DImpl` does declare (`compiler/frontend/ast.mdk`, `grep -n 'DImpl {' compiler/frontend/ast.mdk` then read the record — `pub : Bool` is its first field), so an impl's declared visibility governs no candidacy today. ⚠️ **ALL SIX of this cell's line numbers had rotted, and all six are gone rather than refreshed** (2026-08-07). Cite by symbol; let `grep -n` supply the line, exactly as this table's preamble says. Measured at `bfee53b4`: `foldModules:17745` → actual `:22245` (off 4,500); `appendUniverseAccums:16925` → `:20953` (off 4,028); `implDeclsWithReqs:14030` → `:17867` (off 3,837); `implDeclWithReqs:14033` → `:17870` (off 3,837) — all four in `compiler/types/typecheck.mdk`; `ast.mdk:437-443` → `compiler/frontend/ast.mdk:1234` (off ~797). The sixth is **not** a drifted offset and must not be "refreshed" like one: `compiler/driver/loader.mdk:570` is a live line about **sibling-spelling rewrites**, not about ordering at all — the DFS topological sort it was cited for is ~156 lines later. A wrong-target citation and a stale-offset citation look identical from the doc and are repaired differently, which is why the numbers go rather than move. 🚨 **The first repair of this cell stripped ONE of the six and left five, and that is the lesson worth more than the numbers.** The retained `implDeclsWithReqs:14030` sits **three lines and one character** from the removed `implDeclWithReqs:14033`; a reader who saw one number deleted *with a derivation* could only infer the neighbours had been checked. **A citation sweep's unit is the CELL, never the sentence** — repairing the citation you were looking at manufactures exactly the false confidence the sweep exists to remove. 🔁 **RECIPROCAL CITATION — repaired 2026-08-07 (#1380 item 3).** `SHADOW-SEMANTICS.md` **S2**'s importer-shadow arm asks whether an impl exists *"…exists **anywhere in the loaded module graph** (the impl universe is **graph-global** — instances are coherent across modules, and import scoping never decides which instances exist: `DICT-SEMANTICS.md` §8 **I5**)"*, and cites this clause by name; this cell cites S2 back. The pair is what keeps SHADOW S1's **name**-scoping from being read as licence to narrow `IE` — see I5's own 🚨 boundary paragraph in §8. ⚠️ **This cell quoted S2's OLD gloss — *"GLOBAL — local ∪ imported ∪ prelude"* — until the repair. S2 retracted that phrase on 2026-08-06 (#1375) in its own words (*"Do not restore it: say **graph-global** here and **nameable in `M`** at S1 (§1.0)."*) because the three-item enumeration is strictly SMALLER than the loaded graph and was the same phrase S1 uses for a set that genuinely is those three. Do not restore it here either.** Note S2's assertion is about the routing rule it governs and is not evidence for this row's verdict: the verdict above stays 🔴 PARTIAL — cumulative, not global |
| §8 **I6.1** (a head fabricated from a type-parameter name is a rigid VARIABLE, not a declaration) | 🔴 **OWED — #1110. DIVERGENT where behaviour exists.** Two elaborators reify an unbindable type-parameter spelling as a nullary head. ⚠️ **CITATIONS RE-DERIVED 2026-08-02 after ARCH A-1 PR "A" (#1110) — the previous cell said `fromOption (TCon n) …` / `fromOption (TCon tp) …`, which no longer exists in the source.** Current: `fromAstTypeE`'s `TyVar` arm, `fromOption (TRigid n) (lookupAssoc n tvs)` (`compiler/types/typecheck.mdk:4372`), and `paramMonoOf`, `fromOption (TRigid tp) (lookupAssoc tp subst)` (`:10387`). 🔴 **The verdict is UNCHANGED and the row is still OWED**: the result is no longer byte-indistinguishable from a `data`-declared head — that half is fixed, and the I6 corollary row below records it — but I6.1 says a rigid *is a variable*, and `headTyconMono:13815` and `monoHeadCon:3191` still answer `Some n` for one, so a rigid is still usable as a dispatch key where I4 requires identity-keying. Both arms are explicit and carry a `⚠️ ANSWER-PRESERVING, NOT CORRECT` comment naming this clause, so the residue is greppable rather than inferred | — (nothing at the `Mono` level) | ⚠️ **DERIVATION CORRECTED — read this, not the verdict.** An earlier revision of this row said *"there is no predicate anywhere that separates the two populations"*. **That is false in one grep**, and this table's own preamble is what makes the error expensive: `checkType:341-345` (`compiler/frontend/resolve.mdk`) tests a `TyCon` for existence — `omHasKey n env.types \|\| omHasKey n env.imported \|\| isTupleCtorTyName n` — while `checkType:346` is a different arm entirely, `checkType _ _ (TyVar _) = []`. **The `Ty` AST separates the populations and resolve already acts on the difference.** The true, narrower claim is the one A-1 acts on: the distinction **exists in resolve and is destroyed at `fromAstTypeE`**, which mapped a `TyVar` onto the same node a `TyCon` maps onto — after which no predicate over the resulting `Mono` could recover it, and no resolve→typecheck channel carries resolve's knowledge forward (#1110 §2 derives the absence of that channel). ⚠️ **THE FIRST HALF OF THAT IS NOW OBSOLETE — corrected 2026-08-02, ARCH A-1 PR "A".** The producer is `:4372`, not `:4279`, and it mints `TRigid`, so **`TRigid` IS the recovering predicate** and the two populations are structurally distinguishable at the `Mono` level. **What remains OWED is the KEYING, not the REPRESENTATION**: `headTyconMono:13815`/`monoHeadCon:3191` still answer `Some n` for a rigid, so a rigid is still usable where I4 requires an identity-keyed head. The resolve→typecheck channel is likewise still absent. ⚠️ **The in-tree proof that the collapse is live, not hypothetical**: `candidateBucket:11986`'s `tag == noneHeadTag` guard exists because `paramMonoOf` can put a `"__none__"`-named head at `goals[0]` (`TCon "__none__"` pre-#1110; `TRigid "__none__"` since — `:10387` — which is precisely the point: the node kind changed, the KEY did not) from a user-written interface parameter, so `goalHeadCon` answers `Some "__none__"` — a **reserved internal tag** (`noneHeadTag`, `compiler/support/util.mdk:494`) reached from an ordinary type-variable spelling. Its own comment (`:11976-11985`) records that `data __none__ = N` is a parse error while `impl Q __none__` type-checks at exit 0 |
| §8 **I6 corollary** (I6.1 ∧ I6.3 ⇒ a rigid variable must not be the type-CONSTRUCTOR node) | ✅ **SATISFIED (2026-08-02, ARCH A-1 PR "A", #1110).** The corollary's own stated resolution — *"a rigid variable is **a distinct constructor**"* (§8, above this table) — is now the representation: `Mono` is `\| TCon String TyConOrigin \| TRigid String \| …` (`compiler/types/typecheck.mdk:124,156` — `TCon` gained the identity field in #1110 unit D and `TRigid` deliberately did not, which is the corollary spelled in the types), with exactly two rigid producers, both `lookupAssoc` FALLBACKS: `fromAstTypeE:4372` and `paramMonoOf:10387`. "Carries no identity" is a structural fact about the node, as the corollary requires | that "carries no identity" is a structural fact about the node, not an empty field on it | ⚠️ **This row being ✅ does NOT drain I6.1 — read that row, which stays OWED.** The corollary constrains the *representation*; I6.1 constrains what may be used as a key, and the split was landed deliberately **answer-preserving**, so `headTyconMono:13815`/`monoHeadCon:3191` still hand a rigid out as a dispatch key. The gain the corollary buys is that the violation is now **greppable** (`grep -nw TRigid`) rather than invisible inside `TCon`, and that a module-identity field can now be added to `TCon` at all — which was the blocking reason this row existed, and which #1110 unit D then did. Derived from I6.1 ∧ I6.3, **neither of which states it alone**; kept as a row so the next implementer sees it was met at design time rather than at the first `cohIsCrossModule`-shaped site |
| §8 **I6.2 (a)** — ONE type: the builtin head is the same in every module | 🟡 **HOLDS — and since #1110 unit D it is CARRIED BY A NAMED SITE rather than by the collapse. Still 🟡: the site is named, not fully gated.** Re-derived 2026-08-03 against the post-unit-D source. `Mono`'s `TCon` now carries a `TyConOrigin` (`compiler/types/typecheck.mdk:124`), so the conjunct can no longer rest on there being no field to get wrong. It rests instead on the tuple head having its OWN mint: `tconTupleHead:230-231` stamps `OriginBuiltin`, the same inhabitant and the same authority as the parser's `tyConBuiltin (tupleCtorTyName n)` (`compiler/frontend/parser.mdk:2132`), so a tuple head never picks up a writing module's id. `tupleMono:13945-13946` and `reqTyToMono`'s `TyTuple` arm (`:15428-15429`) are its only callers, and `tupleSpine:13963` still recognises a tuple by comparing the NAME string, so no answer moved. `test/typecheck_compiler_source.sh` pins that the four mints are the ONLY `TCon` constructions in the file, and separately checks that every `tconBuiltin "X"` names a member of resolve's `primitiveTypes`. 🚨 **THE MECHANISM IS NOT "one list read by both layers" — that reading is FALSE and this cell asserted it before 2026-08-03.** The `Ty` layer does not answer *from* `primitiveTypes`: `tyOriginScope:3227-3236` is a **last-wins fold whose builtin layer has the LOWEST precedence**, under prelude, imports and the module's own declarations — so membership alone would not stop a higher layer from overriding a name `tconBuiltin` still calls builtin. What actually holds the conjunct is a *different* fact about the same list: `primitiveTypes` is **also the duplicate-type seed** — `duplicateErrors:1734-1743`'s `typeSeed = primitiveTypes ++ …`, unconditional (`programIsCore` gates only the prelude term) — so **no module can declare a TYPE of one of these names**, not even `stdlib/core.mdk`, and the higher layers are therefore EMPTY at those keys. Measured 2026-08-03: `data List a = …`, `data Int = Foo` and `data Ref a = …` each give `Duplicate type: <N>`. ⚠️ **The narrowing to "a TYPE" is load-bearing and needs a second leg**: `primitiveTypes` seeds only `typeSeed`, not `ifaceSeed`, so `interface Int a where …` is **accepted** (measured, exit 0, no diagnostic). It cannot reach the same key because interfaces are keyed `iface:<Name>` (`ifaceKey:3956` / `ownIfaceOrigin:3962-3963`) while the builtin layer holds the BARE name — the two namespaces are disjoint by construction, witnessed in-tree by `test/references_fixtures/iface_ty_collide/` (unit E/F). That is exactly what `tyOriginScope`'s own comment means by *"the prelude beats builtins only vacuously (they are disjoint today)"*. 🚨 **SO THE CONJUNCT IS CONDITIONAL ON DUPLICATE-TYPE REJECTION, and no gate would notice it lapsing.** `tyOriginScope`'s comment already contemplates *"a future prelude `data List`"*; on that day an occurrence of `List` carries `OriginModule "core"` while `tconBuiltin "List"` still hands out `OriginBuiltin`, and the ratchet stays **green**, because it checks MEMBERSHIP, not AGREEMENT. Whoever relaxes that rejection owes this row and the two source sites it names. ⚠️ **What is NOT gated: WHICH mint a given caller picks.** The ratchet sees a construction outside the four, and a builtin claim for a non-primitive name; it does not see `tupleMono` being rewired to `tconFrom`. Resolve already treats the builtin as *not a declaration* — `checkType:342-346` accepts it via `isTupleCtorTyName` (`compiler/frontend/resolve.mdk:1263`) rather than by membership in `env.types` | that `(Int, Int)` written in two modules is one type, and the prelude's tuple instances apply everywhere | 🚨 **the keying assumption USED TO BE the ABSENCE of a key**, which is precisely what I4 removes. *A mechanical A-1 that stamps every `TCon` with the module under elaboration satisfies I4 and breaks this conjunct, with no diagnostic that names tuples* — that was this cell's standing warning, and #1110 unit D is the PR it was written for. It was avoided in two ways, both deliberate: the builtin heads got their own mints (`tconBuiltin` / `tconTupleHead`) so "the module under elaboration" is never even in scope for one, and `typecheck.mdk` still holds no ambient module id to stamp from (`grep -nE 'currentModule\|curModId\|moduleIdRef\|currentMid'` is empty). Still 🟡 rather than ✅: a wrong mint CHOICE at a caller remains ungated, so the property is now carried by a named, reviewed site instead of by an absence — a real improvement, not a proof |
| §8 **I6.2 (b)** — UNFORGEABLE: no source file may produce a head carrying the reserved origin | ✅ **VERIFIED at the SURFACE level, over EVERY frontend producer — not just the parser.** `compiler/frontend/parser.mdk` has exactly **two** `TyCon`-constructing sites: `parseTyAtom:2026`'s `TUpper c` arm (`:2030-2034`), and `tupleCtorTyOfArity:2102` (`:2105`) — the `(,)`/`(,,)`/… sugar, which produces exactly `tupleCtorTyName:2109`. A `TIdent` becomes `TyVar` instead (`:2035`). `__tupleN__` begins with `_`, and `identStartLower:1637` is `isLower (at src p) \|\| at src p == '_'` (`compiler/frontend/lexer.mdk:1638`), so the spelling can never arrive as `TUpper`. The tree states the invariant itself: *"A `TyCon` can only start at a `TUpper` token (`parseTyAtom`)"* (`compiler/frontend/parser.mdk:3648`). 🚨 **The parser is NOT the sole producer, and a claim that it is does not survive a grep — this cell said only "the parser" at first and that scoping was the same defect the preamble above catalogues.** `compiler/frontend/desugar.mdk` builds three more: `derivedImpl:183` (`tys = [TyCon tyName None]`, `:187`), `appliedHead:515`, and `pinType:979`. **All three take an already-parsed UPPER name**, which is what actually closes the route: the `deriving` path's `name` is `parseData:2924`'s `name <- upperNameP` (`:2927`), and the map/set-literal path's is `upperBrace:831`'s `x` reaching `classifyBrace:899` — and `upperNameFor:1988` accepts `TUpper` and **fails on everything else** (`:1990`). So every frontend `TyCon` producer derives its name from a `TUpper` token or from the `(,)` sugar, which is a stronger statement than a sole-producer claim would have been. (Remaining sites construct no new name: `substTyVars:15003` rebuilds `TCon n` from the `n` it matched, `typecheck.mdk:13282` uses an internal `RScalar` route tag, and `compiler/entries/fuzz_gen_main.mdk:437-443` is a fuzz generator, not a source path.) ⚠️ **NOT ESTABLISHED at the `Mono` level — see the keying column** | that the reserved origin cannot be named by user text | ⚠️ **The tempting differential is an INVERSION — do not read it as a refutation.** `impl Q (,)` applied to `Int` rejects, while `impl Q __tuple2__` applied to `Int` accepts and prints. That is **not** forgery of the builtin: `__tuple2__` parsed as a type **variable**, so `headTyconTy _ = None` (`compiler/types/typecheck.mdk:12463`) filed the impl in the headless bucket — the author wrote a general `impl Q a` with an odd-looking variable name, and the accept is correct. The observation is evidence *for* (b), by a mechanism a `Mono`-level reading cannot see. 🔴 **The `Mono` level is now VERIFIED REACHABLE — MEASURED 2026-08-02, no longer "suspect"**: the row below correctly recorded that the *signature-position* rigid is closed and that *"every other path on which `fromAstTypeE`'s `TyVar` fallback or `paramMonoOf` actually fires"* was untested. It is the **constructor-field** position, and it forges the builtin:<br>`interface Q a where qq : a -> Int` + `impl Q (,)` + `data Bad = Bad __tuple2__` + `use (Bad v) = qq v` **checks clean, exit 0**, on a pre-split binary. Control: rename the rigid to `zzz` and it rejects, `No impl of Q for zzz` — so the *only* thing making it accept is the reserved spelling. A second, independent route: `data Bad = Bad __tuple2__` + `g : Bad -> (,)` + `g (Bad v) = v` also checks clean, i.e. the fabricated head **unifies with** the builtin head, not merely dispatches to it. `__tuple2__` is a legal type-variable spelling because `identStartLower` (`compiler/frontend/lexer.mdk:1638`) admits a leading `_`. Same shape as the already-documented `__none__` forgery (`candidateBucket:11976-11985`). **OWED — #1243** (filed 2026-08-02 as the dedicated issue for this `Mono`-level forgery; #1110 is the multi-PR stage and owns I6.1, not this cell — pinned by `test/must_fail_fixtures/1243-rigid-forges-builtin-tuple-head/`, which self-drains when it is fixed). **S3, not S0: the forging type is UNINHABITABLE** — the declaring type's field is an unbound rigid and a rigid unifies only with itself, so `mk = Bad (1, 2)` is rejected `Type mismatch: (,) vs (a, b)` (measured) and the wrongness is type-level only. ⚠️ A **bound** type parameter does NOT forge (`data Box __tuple2__ = Box __tuple2__` / `unbox : Box Int -> (,)` errors `Type mismatch: (,) vs Int`, measured) — the parameter is substituted before any head comparison, so **only an UNBOUND rigid reaches this**, i.e. the sole route in is #1240's shape. It is also the sharpest reason the I6 corollary row is not optional. ⚠️ **ARCH A-1 PR "A" PRESERVED this forgery deliberately** — the split is answer-preserving by ruling (carrier now, semantics later), so the six sites that used to compare the two populations with one `TCon` name-equality now carry **explicit** cross-population arms rather than falling to a wildcard: `unifyN:3590`, `matchStep:12753`, `cohGoR`, `cohStep`, `cohEqR`, `monoSameGiven`, plus `tupleSpine:13859`. Each names this clause in its own comment. Without them the two repros above become `No impl of Q for (,)` and `Type mismatch: (,) vs (,)` — a silent-to-loud ANSWER CHANGE, which is exactly what the ruling excluded from this step. So the forgery is now **explicit and greppable** (`grep -nw TRigid`) instead of emergent, but it is NOT drained. ✅ **ONE construction route is PROBED AND CLOSED — the SIGNATURE-POSITION rigid.** Given `interface Q a` + `impl Q (,)`, the binding `g : __tuple2__ -> Int` / `g v = q v` — a rigid whose spelling *is* the reserved tuple tag — is **rejected**, `Could not deduce 'Q __tuple2__' from the signature of 'g'`, and the control with the rigid renamed `zzz` rejects **byte-identically** (`Could not deduce 'Q zzz' …`). So the fabricated head does not unify with the builtin head at the point that matters, even though the message shows the rigid genuinely carrying the tag spelling. ⚠️ **The tree explains WHY, which is what makes this durable rather than anecdotal**: *"A rigid signature variable is NOT reified to a `TCon` here"* (`compiler/types/typecheck.mdk:12176-12177`) — a signature's free variable is bound by the scheme and stays an unbound `TVar`, so `fromAstTypeE`'s rigid fallback (`:4372`; it was `:4279` and built a `TCon` pre-#1110) never fires for it. 🚨 **SCOPE OF THE PROBE, stated because a passing probe of ONE route is not a proof of a negative** — and this table's own preamble enumerates the instances where a scoped search produced a confidently wrong "no site exists" verdict (§5.1 **M2**, the record-field half of §8 **I4**, and §8 **I6.1**), so the hazard is not hypothetical here. What was tested: the **signature-position** rigid, on a built binary, **relayed** — this PR built nothing and did not re-run it. What was **not** tested: every other path on which `fromAstTypeE`'s `TyVar` fallback or `paramMonoOf` actually fires, i.e. an *unbound* parameter rather than a scheme-quantified one — which is precisely the `__none__` shape above, and it remains documented-reachable. The verdict stays OWED |
| §8 **I6.3** (`""` is not a module identity) | 🟡 **PARTIAL — the sentinel exists and is READ AS ONE.** `cohImplsOf:10716` is defined as `cohImplsOfMid "" d` (`:10717`) — the per-module coherence sweep records no origin — and the empty string is then read back by `cohIsCrossModule:11079` (`mid1 != "" && mid2 != "" && mid1 != mid2`, `:11080`) and `cohSoftInScope:11058` (whose first arm is `cohSoftInScope "" "" = True`, `:11059`). **OWED — #1110** for the elimination | which coherence sweep OWNS a ⊑-incomparable pair, and whether the message names both modules | ⚠️ **A MIGRATION hazard, not a live defect** — the severity rests on the reachability row below, not on this one. Today `""` reads as *"origin not recorded"*, and its only consumers are message wording (`cohHardMsg:11074`, `cohWhereSuffix:11094`) and sweep ownership (`cohClassify:11037`'s drop arm `:11042`, a de-duplication) — **no acceptance decision**. A-1 makes real origins available at both sweeps; the clause forbids promoting the sentinel to an identity at that moment rather than eliminating it. The origins the clause says exist are already in the tree for the prelude (`coreExports:2494`'s `modId = "core"`, `compiler/frontend/resolve.mdk:2496`) |
| §8 **I6.3 (reachability)** — no comparison mixes `""` with a real id today | ✅ **CHECKED, not assumed** — `cohScan` has exactly **two** call sites: `checkCoherence:11142` over `cohCollectImpls:11548` (every mid `""`) and `globalCoherenceConflict:11588` over `cohCollectModuleImpls:11564` (mids from the loader). Each collector is uniform, so a `("" , real)` pair never forms | the severity of the row above: a mixed pair would drop a soft finding, never accept anything wrong | 🔴 **the "every mid real" half is INHERITED FROM THE PRODUCER, NOT ENFORCED AT THE COLLECTOR — name the owner or this row rots the moment A-1 changes the producers.** `cohCollectModuleImpls:11564` pattern-matches `(mid, prog)` and passes `mid` through **without any non-emptiness test**; the guarantee lives entirely in `moduleIdOfPath:117` (`compiler/driver/loader.mdk`), which is `slashToDot (stripSuffixStr ".mdk" (relUnderRoots roots path))` (`:119`) and would yield `""` for a path of exactly `<root>/.mdk`. Nothing asserts it: where that degenerate name is excluded at all it is excluded **incidentally**, by a dot-entry filter written for a different purpose — `dropDotEntries:1427`, applied in `enumerateDir` (`compiler/tools/refindex.mdk:1412`), one frame below `enumerateMdkFiles:1403` — and on a different code path. **So the invariant has no owner.** Reachability of the degenerate path through the loader's own enumeration was **not** established here (structural reading; no binary run) — UNVERIFIED, and deliberately not claimed either way |
| §8 **I7 (operators)** — the class an OPERATOR demands is the prelude's, fixed | `inferBinop:8916-8934` (`compiler/types/typecheck.mdk`) dispatches `+ - * / %` → `numArithOp`, `== !=` → `eqCompareOp`, `< > <= >=` → `ordCompareOp`, `++` → `appendOp`, each calling `recordIfaceObligation:8977` with a **`BuiltinClass` constructor** (`BNum`/`BEq`/`BOrd`/`BSemigroup`, `:9047`) — no string reaches the seam. Payload from `builtinIfaceRef:9084`, gate from `builtinClassPresent:9076`, both projections of `builtinClassesRef`, populated only by `seedBuiltinClasses:9165` from a **prelude** declaration list | 🟡 **HOLDS, AND NOW FOR I7's OWN REASON — with one honest residual.** #1480 gave the payload a closed four-constructor enum (no fifth built-in class is *nameable*) and #1539 pointed the gate at the same table, so neither half can be reached by a user declaration through a spelling. The residual is the *identity*, not the referent: on the prelude-**flattened** internal passes the prelude's own `DInterface` is unstamped, so `builtinIfaceRef` carries `OriginUnresolved` rather than `(originModule = core, Num)`. That is symmetric — the impl side keys `TkBare` on exactly those arms — so nothing mis-selects, but it is not yet qualification 3's "carrying that declaration's I4 identity" on every arm. §7.1 **U1** deletes that arm | 🟡 `IfaceRef { irName, irOrigin }` (was a bare `String` before #1480), real on the stamped arms, `OriginUnresolved` on the flattened ones. The 12-cell `Duplicate interface: <N>` measurement (`adb789ca`, `Num`/`Eq`/`Ord`/`Semigroup`/`Display`/`Mappable`, flat + module + imported + *un*imported, every verb, exit 1) **re-confirmed at `5c3d3dd8` for the four built-in classes on `check`/`run`/`build` plus the built binary** — and it is no longer what makes this row hold, only what makes the U1 unmasking a non-event here. ⚠️ That protection remains an ARTIFACT OF THE PRELUDE FLATTEN, not a rule (`resolve.mdk:4245-4258` depends on it in writing) |
| §8 **I7 (literals)** — the class a numeric LITERAL demands is the prelude's, fixed | `inferNumLit:9317` (`compiler/types/typecheck.mdk`) guards on `builtinClassPresent BNum` (**#1539**; it was `ifaceRegistered "Num"`) and then still resolves the literal through **`lookupVar env "fromInt"`** — a bare-name lookup in the **user's term scope** | 🔴 **STILL DIVERGENT — the GATE was fixed, the ANCHOR was not, and the anchor is the divergence.** #1539 converted only the guard on the line above; I7's central prohibition, violated, silently, remains. Any binding spelled `fromInt` re-anchors every numeric literal in the module. **MEASURED at `adb789ca`:** adding only `fromInt : Int -> Float` / `fromInt _ = 10.5` to a file makes `check` exit 0 (`0 errors`) while `println (1 + 1)` prints **`2.0`** under `run` and **`2`** from the built binary — an eval/native divergence at exit 0 on an accepted program. A plain top-level function suffices (no interface, no name collision); a `let` binder suffices. The loud cousin (a `fromInt` whose return type has no `Num` impl → a cascade of prelude-internal errors mislocated to the user's line 1) is filed as **#259** at S2; the silent, engine-divergent shape above is **not** covered by that issue | 🔴 keyed on the **term-namespace spelling `fromInt`** in the user's scope — the exact "resolve the operator to a method name and read that method's class" anchoring I7 forbids |
| §8 **I7 qual. 4** — the synthesis gate must be "the PRELUDE's class is present", not "some class of that name is registered" | All **three** gate sites — `recordIfaceObligation:8977` (the operator seam), `inferNumLit:9317`, `checkOneCallObligation:20293`'s no-prelude `Num` skip — ask `builtinClassPresent:9076`, a projection of the four `bc*Present` fields of `BuiltinClasses:9034`, written only by `builtinClassesGo:9103` walking a **prelude** declaration list under `seedBuiltinClasses:9165` | ✅ **CONFORMANT (#1539).** The gate is answered from the prelude's own declarations and from nothing else: the population is four `Bool`s in a closed record, there is no key to collide on and no table a user declaration writes to. A user `interface Num` cannot satisfy it even once §7.1 **U1** makes such a declaration legal, which is the reachability this row previously deferred to. ⚠️ **Behaviour-preservation was MEASURED, not asserted:** `builtinClassesGo` mirrors the old table's sole writer decl-for-decl (`≥1 method`), and a disagreement tripwire compiled into the checker reported **zero** disagreements at all three sites across the gate corpus | ✅ four `Bool` fields of a closed record — not a keyed table, so nothing to key correctly. ⚠️ The `Unit`-valued `registeredIfacesRef` is **not** re-keyed and is **not** the gate any more: #1539 deleted `ifaceRegistered`, its only reader, leaving that table WRITE-ONLY pending its own retirement atom (**#1569**). The #1111 A-2.4 / A-2.2b ledger for it survives as a tombstone at `typecheck.mdk:9183` — I7 did not retract that reasoning, it relocated the question off the table entirely |
| §8 **I7** ⚠️2 (identity fixed ⇏ dictionary discharged) — an operator satisfied by a user instance must dispatch through it | `evalArith:1852` (`compiler/eval/eval.mdk`), the arithmetic fallthrough: `panic ("unknown op '" ++ op ++ "'")` | 🔴 **DIVERGENT, and it is the distinct §5 defect the clause's second trap names.** The `Num` obligation for `+ - * / %` is recorded and correctly discharged against a user `impl Num T`, and then no dictionary is projected. **MEASURED at `adb789ca`:** a complete `impl Num Money` with `Money 3 + Money 4` gives `check` exit 0, `run` exit 1 `E-PANIC: unknown op '+'`, `build` exit **0**, and the built binary **segfaults**, `E-FATAL-SIGNAL`, exit **139** — on both the flat and the module arm. ⚠️ **The three other operator classes do NOT share this**: `==` (`Eq`), `<` (`Ord`) and `++` (`Semigroup`) each dispatch to the user's impl correctly and print the right answer on both engines, measured on the same binary. The gap is arithmetic-only | — (a §5 dispatch gap, not a keying one; recorded here because I7's identity ruling is what makes it visible as a *separate* defect rather than a consequence) |
| §9 soundness statements (type preservation, semantic adequacy, coherence, evaluator interchangeability, `gen-sig` authority) | composite of every row above | explicitly "targets for a later proof/audit" (§9's own header) — not independently implemented checks | — |

**Partial enforcement found (NOT "unimplemented"):** §3 W2 (instance-context
termination/Paterson coverage) has no *static, declaration-time* check, but a *dynamic,
resolution-time* depth cutoff does exist — `routeOfD`/`argImplRequiresRoutesRecD`, the
#217 "WS-4b fuse", bounded at depth 32. See the W2 row above for why that is not
equivalent to the spec's condition: a non-shrinking context terminates but is never
rejected, and there is no diagnostic at depth 33.

**Prominent divergence found — and CLOSED, 2026-08-01 (F-3d, #614/#311). Kept here
because the reasoning that resolved it is what a future reader needs, not the
verdict.** §6 C1's implementation enforced condition (a) (global pairwise
comparability) where the spec commits to condition (c) (per-goal unique minimum);
this table independently re-confirmed it against source at `c4ef6dbe`, with the exact
reject site and the exact spec passage it contradicted (§6.1 choice-point 2).
⚠️ **The divergence was in the SAFE direction, and that was the trap** — but
**not** for the reason it is tempting to give. The safe reason is *not* "(a) is
stronger than (c)": §6.1.2's own ⚠️ shows the ladder from (a) to (c) breaks at α-equal
heads, so **(a) ⇏ (c)** and (a) alone would leave a duplicate-head pair accepted where
C1 rejects it. Safety came from the **site being stronger than (a)** — the arm fell
through only on *strict* specificity in one direction, so mutually-subsuming heads
were rejected too (the C1 row establishes this). On that true premise the site
over-rejected rather than mis-answering, including over the rigid-variable goals C1's
quantifier now names explicitly, and was therefore *standing in for* a per-goal check
that did not exist. **That extra strength is exactly what F-3d had to preserve, and
it is why the repair is a CLASSIFICATION rather than a deletion**: `cohClassify`
demotes only the `⊑`-incomparable class (a genuine (a)-violation) to a warning and
keeps the mutually-`⊑` class a hard error, because nothing downstream rejects the
latter. A reader who audits the site against the *clause* (a) and demotes the whole
arm re-opens the hole §6.1.2's ⚠️ describes — the direction matters, and it points the
way that understates what the tree enforces. The C1 row above carries the probes and
the residuals; the sequencing consequence stands as written — (a)'s relaxation and a
per-goal ambiguity reject are one change, not two, which is why 1155 (F-3c) landed
first.

**UNIMPLEMENTED found by the #1107 rows (1), with no site anywhere in the tree:**
**§4.1 G1** — a `let`/`where` binding never receives dictionary parameters. This one
survived the harder test: not just "`dictPassDecl` has four declaration arms", but
"`dictParamName` is the sole minter of a `$dict_` binder and its only
pattern-producing callers are reachable from those four arms", plus "no
lambda-lifting pass exists to route a local through them". See the row.

🚨 **A second row was first written UNIMPLEMENTED and is WRONG — the correction is
kept because the failure mode is this table's own recurring one.** §5.1 **M2** was
recorded as having no site, on the strength of a vocabulary search (`T-UNKNOWN-*`,
"not a method", "does not declare") **scoped to `typecheck.mdk`**. The check exists,
one file over and one *stage* earlier: `checkMethodMember` in
`compiler/frontend/resolve.mdk`, raising `MethodNotInInterface` /
`R-METHOD-NOT-IN-INTERFACE` — a **resolve** error with no `T-` code at all, which no
search of typecheck's vocabulary could ever have found. The observation that led to
the wrong verdict was itself correct (`inferImplMethod`'s `None` arm really is inert);
the *inference* from it — "therefore nothing rejects this" — did not survive a probe.
**The W2 lesson is not only "search the implementation's vocabulary" but "search
every STAGE the judgment could live in":** a guarantee this table attributes to
typecheck may be discharged at resolve, and a negative result scoped to one file is
not a negative result. Two of the four "no site" claims attempted here failed that
way (M2, and the field half of I4); both are corrected above.

**Further divergences found by the #1107 rows (4):** **§5.1 M3** (`checkPhantomMethods`
keys on the `DInterface` declaration alone and can never see a use site — #1134,
whose resolution is decided in M3's favour: the checker narrows, so the pinned
`test/dict_fixtures/s5-phantom-determined-use-rejected.mdk` goes **red** on the fix
and re-pins to ACCEPT `7`; the "relabel by hand" contingency in both phantom
fixtures' headers does **not** apply and can be struck);
**§4.1 G4** (the local-dict pin monomorphises where the clause requires a reject —
#1052 — and, separately, the five local sites do not share one pin predicate, which is
where a `let`-vs-`where` divergence comes from); **§6.2 T3/T4** (the route-stamper
drain is keyed on the **module** boundary, while the tyvar cells it depends on survive
it); **§7.1 U1/U2** (`CheckMode` is live, with 20 `Flat` arms and a consumer set to be
derived by the command in that row, against `compiler/DRIVER-COLLAPSE-PLAN.md`'s
status line of IMPLEMENTED).

🔴 **One row is HOLED rather than divergent, and it is the most serious finding in this
table: §4.1 G2** (`isNonexpansive`'s constructor arm decides *what a constructor is*
from the head name's **first character**, so every alias-qualified application —
`import hash_map as H`, `let m = H.new ()` — is generalized as if it were a
constructor application — **#1150**, OPEN, S0, memory-safety: `check` exit 0, native
SEGFAULT). It matters beyond its own
severity because it is the premise **§4.1 G3** rests on, and G3 is **F-1's (#1082)
gate**: landing dict-abstracted locals on the current value predicate would give a
live unsoundness a second, calling-convention-shaped channel. ⚠️ **The row's cited
reason has already moved once without its verdict moving**: it first cited **#1139**
(final-spine-argument only), which is now CLOSED and fixed — and the fix does not
touch the head test, so the row stayed 🔴. A drained citation is not a drained hole.
⚠️ **This row asserted
the opposite** in its first revision — *"`isNonexpansive`'s only allocating arms are
… over non-expansive parts"* — a claim contradicted by the very lines it cited, and
the fourth first-pass error in this table. The three others were "no site" verdicts
under-searched; this one was a **positive** claim read off a line whose sibling arms
made it look obvious. Neither kind is caught by a doc gate.

---

## References

- P. Wadler, S. Blott. *How to make ad-hoc polymorphism less ad hoc.* POPL 1989.
  (The dictionary-passing translation.)
- M. P. Jones. *Qualified Types: Theory and Practice.* (Evidence/entailment,
  the `P ⊢ π` discipline and the coherence problem.)
- C. Hall, K. Hammond, S. Peyton Jones, P. Wadler. *Type Classes in Haskell.*
  (Class/instance environments, superclasses, the translation in practice.)
- S. Peyton Jones, M. Jones, E. Meijer. *Type classes: an exploration of the
  design space.* Haskell Workshop 1997. (Overlapping instances and the
  specificity ordering among the surveyed design choices — prior art for §3's
  `⊑` and §6.1.)
