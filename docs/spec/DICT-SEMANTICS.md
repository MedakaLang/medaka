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

**Revision (2026-07-30): six rules that the implementation had been enforcing — or
failing to enforce — with no governing clause are now written down** (#1107, Stage S
of the typechecker target-architecture arc, epic #1122). They are **§4.1** (`gen` at a
local binder: uniform abstraction, the value-restriction gate, evaluation-timing
neutrality, predicate deferral), **§5.1** (impl completeness, extraneous methods, and
where a phantom-method rejection belongs), **§6.2** (group scheduling and when `inst`
may commit), **§6.3** (numeric-literal defaulting), **§7.1** (driver unimodality), and
**§8 I4/I5** (module-qualified identity in every namespace; graph-global instance
candidacy). Each carries a §11 row, and every one of those rows is UNIMPLEMENTED,
PARTIAL or DIVERGENT — these clauses describe the target, not the tree. Two of them
license behaviour changes that are stated in the clause itself rather than left to a
migration to discover: **I5** (three distinct consequences, only one of which is an
acceptance widening) and **§6.2 T4**.

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
requires is a unique winner: `match(IE, π)` must have a **unique ⊑-minimal
element**, the goal's *most-specific matching instance*, written
`min⊑(match(IE, π))`. (The matching set is finite, and in a finite preorder a
unique minimal element is a minimum — equivalently, one matching instance is
`⊑` every other matching instance.) If two `⊑`-incomparable instances match
and no matching instance lies `⊑`-below both, no minimum exists and the goal
is **ambiguous overlap** — rejected, not chosen from.

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
  goal's **unique most-specific matching instance** `I` — when the matching set
  has no `⊑`-minimum the program is rejected as ambiguous overlap (§6 C1) —
  and resolves to *`I`'s* evidence: it recursively discharges **`I`'s own
  context `φ(Q)`** at the goal's (specific) instantiation through this same
  judgment — so nested obligations themselves resolve most-specifically —
  captures that evidence `ē` in the method closures, fills `methods` from
  `I`'s impl, and fills each `supers.D` by resolving `D τ̄` through entailment
  — not through `super`, which would need the very dict being built. Its
  recursive premises are what force the representation to be a tree.

**Resolution determinism.** Entailment is intended to be a *function*: for a
given `(IE, CE, P, π)` at most one derivation exists up to evidence
equivalence (§6) — now **the unique most-specific derivation**, not the
unique derivation. Instance heads may overlap; `inst` stays deterministic not
by forbidding overlap but through its minimality premise: it applies only for
`min⊑(match(IE, π))`, which §6 C1 requires to exist uniquely wherever `inst`
fires. Two `⊑`-incomparable matches with no common `⊑`-lower match are
**ambiguous overlap** and the program is rejected — most-specific-wins is a
total tie-break, never "pick one". That reject is an `inst`-vs-`inst` rule and
scopes to `inst` alone.

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

**Well-formedness (for entailment to be a total function).** Beyond unique
most-specific matches (§6 C1), resolution is decidable only if (W1) the
**superclass relation is acyclic** — otherwise `super`-search loops — and (W2)
**instance resolution terminates** — each `inst` premise `πᵢ ∈ φ(Q)` (the
context of the *selected* instance) must be structurally smaller than the goal
(a Paterson/coverage-style condition), otherwise the recursive discharge of
`Q` diverges. Most-specific selection itself adds no termination risk:
`match(IE, π)` is a finite subset of a finite `IE`, membership is one
one-sided matching problem per instance, and `⊑` between two heads is one
more — so `min⊑` is computed by finitely many decidable comparisons, before
any recursion. W1 + W2 + C1 together make entailment the function the
elaboration of §4 assumes it to be.

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

- **G2 — The value-restriction gate.** A local binding **may abstract dictionaries
  only where it generalizes at all**, and it generalizes only where the value
  restriction licenses it: the bound expression must be a syntactic value. A
  non-value local is monomorphic, has no quantified variable for a predicate to range
  over, and therefore abstracts nothing. Dictionary abstraction is not a *second*
  gate stacked on generalization — it is a consequence of it. No local that fails the
  value restriction may acquire a `λd̄.` prefix.

- **G3 — Evaluation-timing neutrality (a theorem under G2, not an assumption).**
  Wrapping a bound expression `e` as `λd̄. e` moves `e`'s evaluation from binding time
  to each use. Under G2 that is unobservable, and the argument is worth writing down
  because it is what makes G2 the *right* gate rather than a convenient one: G2
  admits only syntactic values; a syntactic value's evaluation performs no effect,
  cannot diverge or panic, and allocates nothing whose identity a program can observe
  (mutable-cell constructors are excluded from the non-expansive set precisely so
  that generalizing them stays unsound). Re-evaluating one per use can therefore
  change *allocation cost* and nothing else. Anything that could raise, diverge, or
  perform on evaluation is expansive, is not generalized, and is never wrapped.

  ⚠️ **This is the part of the top-level case that does not carry over, and it is why
  G2 cannot be relaxed for ergonomics.** At a top-level binding the same wrapping is
  licensed by the same value restriction, but a top-level binding is evaluated at
  most once per program either way, so its neutrality argument never has to be made.
  At a local binder it does. A proposal to "generalize locals a little more eagerly
  than the value restriction allows" is not an ergonomic loosening of G2 — it is a
  proposal to move evaluation, and it owes this argument again.

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

  An implementation **MAY** warn at the declaration that a phantom method is usable
  only under an ambient assumption. **Acceptance is per use site.**

  ⚠️ **The parallel with §6.1 choice-point 2 goes only part of the way, and the part
  it does not go is the load-bearing one.** There, the declaration-time condition (a)
  *implies* the per-goal condition (c), so a declaration-time rejection is merely
  *early* — never wrong. Here it does not: *"this method mentions no class
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

- **C1 — Unique most-specific instance.** For any ground `C τ̄`, the matching
  set `match(IE, C τ̄)` (§3) has a **unique ⊑-minimal element** —
  equivalently (the set is finite), a `⊑`-minimum: one matching instance at
  least as specific as every other. Overlap — more than one matching head —
  is permitted *iff* this holds. Two `⊑`-incomparable matching instances with
  no matching instance `⊑`-below both make the goal **ambiguous overlap**,
  and the program is rejected; so are α-equal duplicate heads (mutually `⊑`,
  no *unique* minimal instance). This is the retained coherence guarantee:
  most-specific-wins is a total tie-break, not a licence to pick. (The old
  C1 — "at most one match" — is the special case where every matching set is
  a singleton, which is why the relaxation is conservative over previously
  legal programs.)
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
(Argument sketch under overlap: W1+W2+C1 make entailment total on the goals
elaboration poses, and a function of `(IE, CE, P, π)` — `assum` is keyed by
`P`, `super` by the already-unique sub-derivation, and `inst` by the unique
`⊑`-minimum, which no search order can vary (C3). C4 fixes one global `IE`,
so "the" minimum is the same at every site. Two derivations of the same
judgment thus produce `≡` evidence pointwise, and elaborated terms differ at
most in the derivation path, not the evidence — the same argument as the
non-overlapping theorem with "the unique match" replaced by "the unique
minimum".)

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
   - (b) *per-goal total order*: at every ground goal the matching set is
     totally ordered by `⊑`; implies (c);
   - (c) *per-goal unique minimum*: at every ground goal the matching set has
     a unique `⊑`-minimal element — what C1 states.
   (c) is exactly what `inst`-determinism requires — no more. The separating
   case: `C (Pair Int a)`, `C (Pair a Int)`, `C (Pair Int Int)` all declared.
   At the goal `C (Pair Int Int)` the first two are incomparable, but the
   third is `⊑` both — (c) accepts with an unambiguous winner; (a)/(b)
   reject. **Recommended: (c) as the semantics** (it is also GHC's condition),
   with the check performed at each `inst` application during elaboration —
   still fully static, never at run time. An implementation MAY additionally
   warn at declaration time on (a)-violations as an early diagnostic, but
   acceptance is per-goal. Note the task-level intuition "overlap is allowed
   iff totally ordered by specificity at each ground goal" is condition (b):
   sound, slightly stronger than needed, and the difference only shows on
   instance sets like the `Pair` triple above.

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

  Two consequences fall out. The first is a **flagged design choice**:
  * **At a binding whose type is inferred and about to be generalized, result position
    is NOT a determination channel.** `let n = 1` grounds; it does not generalize to
    `∀a. Num a ⇒ a`. This is a deliberate monomorphism-for-`Num` restriction — the
    same trade Haskell's monomorphism restriction and `default` declaration make.
    *Alternative:* generalize, and let each use choose. **Rejected here**, because it
    makes the representation of the literal `1`, and hence which `Num` impl runs, a
    property of the *use site* rather than of the literal — the very
    position-dependence this rule exists to remove.
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

  ⚠️ **This is a semantics change with three distinct consequences, and only the first
  is an acceptance widening. Naming all three is the point of this paragraph.**
  1. **New acceptances.** An impl declared in a module that no path reaches before the
     goal's module — a topologically later one, or a sibling — becomes usable. A
     program that did not compile now compiles. This is the orphan-instance-style
     widening, and it is carried by a fixture that could not pass before.
  2. **New rejections.** Enlarging `match(IE, π)` can destroy a `⊑`-minimum that a
     smaller candidate set had. Two `⊑`-incomparable instances, one of which was
     previously invisible at the goal, make the goal **ambiguous overlap** under C1 —
     so a program that compiles today can stop compiling. A candidate-set widening is
     *not* an acceptance widening.
  3. **Silent answer changes.** A newly-visible instance that is strictly more
     specific than the previous winner *wins*, by §3. The program still compiles, and
     prints something different. There is no diagnostic, because nothing is wrong: the
     new answer is the specified one and the old answer was the artifact. Any
     migration onto I5 must treat this as its primary hazard rather than as golden
     churn.

  The price I5 pays for coherence is that a program's meaning is a function of the
  **whole loaded graph**: adding an unrelated module to a build can change an existing
  module's dispatch. That is not a defect of I5 — it is what C4 buys coherence with,
  and the alternative (per-module candidate sets) is exactly the state in which "C1/C2
  hold only locally and coherence fails across module boundaries", which C4 forbids by
  name.

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

⚠️ **Where a row claims "no site exists", read the *derivation* in it, not the
verdict.** Two such claims made here were **wrong on the first pass** and are
corrected above (§5.1 **M2**; the record-field half of §8 **I4**). Both failed the
same way: the search used the *implementation's* vocabulary rather than the spec's —
the W2 lesson, applied — but was **scoped to `typecheck.mdk`**, and in both cases the
check lives elsewhere: at the **resolve stage** for M2, and under a name none of the
search terms covered for I4. A negative result scoped to one file is not a negative
result, and neither is one scoped to one stage. The single surviving "no site" claim
(§4.1 **G1**) is therefore stated with a tree-wide derivation over the *name-minting*
function rather than over the pass that was expected to call it.

| Clause | Stage / site | What it enforces | **Keying assumption** |
|---|---|---|---|
| §2 evidence representation (nested dict; `methods`+`supers`) | `compiler/eval/eval.mdk:130` `VDict String (List (Value e))`; `compiler/ir/core_ir.mdk:132` `CDict String (List Route)` | the runtime/IR shape of evidence — one dict per instance, closed over its required sub-evidence | ⚠️ REPRESENTATION-LEVEL: both are a flat `(key, positional-list)` pair, not a literal `{methods, supers}` record. Legal only as §2's "representation optimization" *if* supers/context are still resolved once at construction (`inst`, row below) and never re-derived — not independently re-verified past that point here |
| §3 `assum` | `entailAssum`/`entailAssumVar`/`entailAssumRoute`, `compiler/types/typecheck.mdk:11907-11934` | an in-scope `=>` dict is used directly, never rebuilt | keyed on the call site's **enclosing binding's** dict-variable name (`activeDictVarOfEncl`/`activeDictVarForEncl`, via `encl`), not on predicate identity — assumes at most one matching in-scope dict per predicate per enclosing binding |
| §3 `super` | `expandSupersTable`, `compiler/types/typecheck.mdk:5037` (WS-1b superclass-evidence flatten) | superclass access as a nested-record projection, computed once | table keyed by (interface, declared superinterface param-names) per transitive superinterface slot (own comment: "one slot for each (transitive) superinterface") |
| §3 specificity `⊑` / `min⊑` | `pickMostSpecificEntry:11441` → `findMostSpecificEntry`; `tySubsumesV:11490`; `matchStep:11782`; `selectImplEntryByIface:11584` (all `compiler/types/typecheck.mdk`) | the unique most-specific matching instance | ⚠️ `pickMostSpecificEntry`'s own comment (11438-11440): when no unique winner exists it falls back to **"the head of the list (the pre-existing first-match behaviour)"** rather than signalling ambiguity — see the C1 row below for why this path is believed unreachable, and why that reliance is itself a tracked gap (#614, #311) |
| §3 `inst` | `entailInst`, `compiler/types/typecheck.mdk:11941-11991`, via `keyForSite:11386`/`keyForSiteByIface:11608` → `matchedEntry:11416` → `pickMostSpecificEntry` | fresh dictionary construction at the `min⊑` instance, recursively discharging its own context | goal keyed by `ifaceParamMonos`'s **full param-mono vector** (the #609 fix, code comment 11971-11978) — shares ONE binding between the method route and its own `requires`-context routes so both arms pick the same impl (closes the C2 "same-impl" hazard) |
| §3 precedence (`assum`/`super` before `inst`) | `entail`, `compiler/types/typecheck.mdk:11892-11896` | in-scope evidence wins over instance construction | tries `entailAssum` first, falls to `entailInst` only on `None` |
| §3 **W1** (superclass acyclic) | `ifaceDfsCycle:11076-11101`, invoked at `:11062` pushing `T-CYCLIC-SUPERINTERFACE` (`compiler/types/typecheck.mdk`) | rejects a cyclic `requires` chain | DFS keyed on **bare interface name** (`String`), not module-qualified — not independently re-verified for a same-named-interface cross-module collision here |
| §3 **W2** (instance-context termination / Paterson coverage) | `routeOfD:12015` (`compiler/types/typecheck.mdk`), the depth-carrying core of `routeOf:12005-12007`, threaded through `argImplRequiresRoutesRecD:12114-12122` → `argImplReqRoutes:12197` → `argReqRoute:12201` → back to `routeOfD` — the #217 "WS-4b fuse" | ⚠️ **NOT the spec's W2.** W2 is a *static, declaration-time* condition (reject an instance whose context isn't structurally smaller than the goal). What exists is a **dynamic, resolution-time depth cutoff**: `argImplRequiresRoutesRecD:12116` — `if depth >= 32 then []` — so a non-shrinking context (`impl C (T a) requires C (T (T a))`, per the code's own comment at :12009-12014) *terminates* by silently returning no further requires-routes at depth 32, rather than being *rejected* at declaration. The program is accepted either way; only route resolution stops recursing | depth increments **once per impl level** inside `argImplRequiresRoutesRecD` (`depth + 1` at `:12120`), starting from `0` at `routeOf`'s call into `routeOfD` (`:12007`); the `32` bound is a magic number with no stated derivation — a legitimately-deep-but-terminating context presumably degrades identically to a genuinely non-terminating one at depth 33, and neither is diagnosed |
| §3 **W3** (method-scheme fidelity / rigidity) | `checkMethodRigidityCore:14732`, `checkImplMethodRigidity:14749`, `checkDefaultMethodRigidity:14766`, `checkImplEffVarRigidity:14927` (all `compiler/types/typecheck.mdk`) | an impl/default body may not pin a non-head quantified variable (type *or* effect) to a concrete shape | gated by `inRigidityBodyRef` — True only while an IMPL/DEFAULT method body is being inferred |
| §4 `var` | `instantiate:3630`; per-residual entailment via `entail:11892`; obligation discharge `checkCallObligationsU:13793`/`checkOneCallObligation:13814` | instantiation + per-predicate entailment at each use | — |
| §4 `gen` | `generalize:3505`; check-path registration `registerInferredConstraints:16140`/`setDictEligible:9418` | abstracts a dict param per deferred predicate | arity becomes part of the binding's elaborated type — see I1 below for the cross-module keying hazard this creates |
| §4 `gen-rec` | `processTopGroups:15568` → `processSCCs:15598` → `processSCC:15709` (`compiler/types/typecheck.mdk`) | one shared `λd̄.` prefix over a mutually-recursive group; recursive occurrences reuse it rather than re-entailing | — |
| §4 `gen-sig` (#619) | `checkSigConstraintCoverage:16344`/`checkSigConstraintOne:16350` (`compiler/types/typecheck.mdk`) | `Q_sig ⊩ P'ᵢ` — inferred body context must be entailed by the declared one, not merged | — |
| §4.1 **G1** (uniform dict abstraction at a local binder) | **UNIMPLEMENTED — confirmed absent TREE-WIDE, not just in `typecheck.mdk`.** `dictPassDecl:12377` has exactly four declaration arms — `DFunDef` (`:12378`), top-level `DLetGroup` (`:12388`), `DImpl` methods (`:12397`), `DInterface` default bodies (`:12403`) — then a catch-all `dictPassDecl _ _ d = d` (`:12407`); no arm descends into an expression. The stronger check is on the **name-minting** function: `dictParamName:12685` is the sole producer of a `$dict_<fn>_<slot>` binder, and tree-wide (`grep -rn dictParamName compiler/ --include='*.mdk'`) its only *pattern*-producing callers are `dictParamsGo:12671` and `dictParamsFrom:12680`, reachable only from those four arms — every other caller builds an `RDict` route or an `activeDictVars` entry, i.e. a **reference** to a param a declaration already bound. `llvm_emit.mdk`'s `dictParamNameE:6130` re-derives the same string for a method and creates nothing. And there is **no lambda-lifting pass** that could route a local through the `DFunDef` arm (`grep -rn 'lambdaLift\|hoistLocal\|liftLocal\|closureConv' compiler/` → 0 hits; `desugar.mdk` maps `ELetGroup` structurally at `:73`/`:120-121` and never hoists it) | — | so no `let`/`where` binding receives a `λd̄.` prefix at **any** stage — resolve, desugar, marker, typecheck, IR lowering, or either backend. Separately, even the implemented half has no per-binder key for G1 to extend: the arity a top-level binding gets is read by `dictArityOf:12662`, which is **bare-name** (see the I1 row). G1 additionally needs *local* binder identity — `(name, binding-id)` keying already exists for local scheme *obligations* (`registerLocalScheme:7866`, #837) and is the shape the arity table would need |
| §4.1 **G2** (value-restriction gate) | `genRestricted:3606` gated on `isNonexpansive:3534` (with `isCtorAppHead:3562` excluding `Ref`), at all five local generalization sites: `blockRecLet:5205`, `blockLet:5221`, `inferRecLet:7835`, `inferLetBody:7904`, `generalizeGroup:9331` (via `clausesAreValue:9344`) | a local generalizes only at a syntactic value | ENFORCED, and G3's neutrality argument rests on exactly this predicate: `isNonexpansive`'s only allocating arms are constructor/tuple/list/record forms over non-expansive parts, and the sole mutable-cell constructor is excluded by name (`:3566` `name != "Ref"`). ⚠️ that exclusion is a hard-coded single name — the comment at `:3528-3530` says any future uppercase mutable-cell extern must be added by hand, so the predicate G3 depends on is maintained by convention |
| §4.1 **G4** (predicate deferral; monomorphising is NOT an approximation) | 🔴 **DIVERGENT.** The five sites above conjoin the value test with `not (pinLocalIfDictForwarded:8947 …)` — the #866/#1021 all-or-nothing pin, which handles a dict-forwarding local by **declining to generalize** it, exactly the move G4 forbids | — | 🔴 **#1052 (OPEN, S0)** is that clause's counterexample and is already filed as one: monomorphising a `where` helper merges two *distinct rigid signature* variables and drops a dictionary slot, printing `2` where G4 says `3`, on both engines, exit 0. #1082 is the migration vehicle; the pin is documented as an interim at `registerLocalScheme`'s `#866 NARROWED THE PREMISE` comment (`:7850-7865`), which states the trade in the same terms |
| §5 method dispatch (arg/result/phantom position) | `inferMethodAt:4619`; `resolveSites:10057` (return-position); `argDispatchIndices:2746`/`prePassDictArg:9742` (arg-position) | dispatch type is fixed by `var`'s instantiation regardless of `ā_C`'s position in `τ_m` | — |
| §5 arg-tag dispatch = optimization, not semantics | (i) `narrowMethod`/`methodAtNarrow:1048-1069` narrows by a STATICALLY-computed `Route` key, not a runtime inspection. (ii) The genuine runtime-argument-inspection fallback is `applyOpt (VMulti vs) arg = collectPartials [] (filterByTag vs arg) arg:870` → `filterByTag:888-891` → `runtimeTypeTag:384-397` → `matchesTag:1088-1090` (all `compiler/eval/eval.mdk`) — reached whenever a VMulti (unnarrowed method candidates) is applied to a runtime argument | (i) is sound by construction (the key was already the `min⊑` winner at typecheck time — this is NOT arg-tag dispatch in §5's sense at all, despite the name). (ii) IS §5's arg-tag dispatch, and its side condition is **not verified**: `runtimeTypeTag` discriminates at **bare head-tycon granularity only** (`VList _ => Some "List"`, `:391`) — it cannot distinguish `List Int` from `List a`, nor (per the sharper counterexample below) `T Int` from `T Bool` | 🔴 **Already tracked, more precisely than this row first put it: #1113** (OPEN, part of this same target-architecture arc). #1113's own text corrects the "no overlap below the head" framing this row started from: *"`impl C (T Int)` / `impl C (T Bool)` don't overlap and the tag `T` determines nothing; multi-param interfaces likewise"* — so even NON-overlapping instances differing past the head are mis-discriminated by `runtimeTypeTag`'s granularity. #1113's own stated target fix ("computed once post-K from the global IE, frozen into the elaboration output... never re-derived") confirms today's `filterByTag` is exactly the ad-hoc mechanism it plans to retire |
| §5.1 **M1** (impl completeness) | `checkImplCompleteness:10862` (whole-program scan) **and** `checkImplCompletenessMap:10922` (the multi-module keyed twin), pushing `T-INCOMPLETE-IMPL` via `pushIncompleteImpl:10868`; required set from `requiredMethodNames:10908` (methods whose merged `IfaceMethod` carries no default) | every non-defaulted interface method has a body in the impl, so `methods(e).m` is total | ⚠️ two implementations of one judgment (the scan and the map), kept in step by hand — the map's comment (`:10920-10921`) states its keying assumption outright: *"Interface names are globally unique, so the map's last-write-wins carries the same required-method list the scan's first-match returned."* **§8 I4 makes that premise false**, and the failure is silent in the last-write-wins direction: two same-named interfaces in one graph, one required-method list. Error location is `firstImplMethodLoc:10892` — the first present method body, `None` for a wholly-empty impl |
| §5.1 **M2** (no extraneous methods) | ✅ **ENFORCED — at RESOLVE, not typecheck.** `checkImplDecl:1227` → `checkImplIface:1241` → `checkMethodMember:1252`, which rejects any `ImplMethod` whose name is absent from `ifaceMethodsOf iface env.ifaceMethods` with `MethodNotInInterface` (`resolve.mdk:119`), rendered at `ppResError:1912`, code `R-METHOD-NOT-IN-INTERFACE` (`resErrorCode:1955`). Runs on **both** env paths — `ifaceMethods` is populated at `resolve.mdk:1428` (single-file: prelude ++ user) and `:2472` (multi-module: ++ imported) — so it fires on `check`, `run` and `build`. Typecheck's own arm is **inert**: `inferImplMethod:14396`'s `None` arm (`:14398`) is `()`, so the extraneous body is never inferred; the guarantee comes entirely from resolve | an impl body under a name the interface does not declare is rejected before typecheck ever sees it | ⚠️ **keyed on the BARE interface name**, and `ifaceMethodsOf:1246` is a **first-match** assoc over `pIfaces ++ uIfaces ++ impIfaceMethods`. Two interfaces sharing a name in one graph resolve to the *first* list, which can both spuriously reject a legitimate method of the second and spuriously accept an extraneous name that happens to be in the first — §8 I4's hazard on this exact check (structural reading; not reproduced here, no binary). ⚠️ **Quality residual, not a soundness one:** the error is constructed with `None` for its location (`:1257`) and so prints `<unknown location>`, even though `checkImplMethod:1237` has `firstExprLoc body` in hand two lines away — an unfilled slot, `compiler/ERROR-QUALITY.md` dimension. **Scope note:** M2 is a rule about the *name* only; a body under a **correct** name with the wrong arity or type is W3's business (`inferImplMethod`'s unification), not M2's, and this row does not claim otherwise |
| §5.1 **M3** (phantom methods: reject the undetermined USE, not the declaration) | 🔴 **DIVERGENT.** `checkPhantomMethods:10995` → `phantomMethodMsgs:11001` → `phantomMethodMsg:11007`, pushing `T-PHANTOM-METHOD`, run from `runFinalChecks:11052` | rejects a method whose declared type mentions none of the interface's parameters | 🔴 keyed on the **`DInterface` declaration alone** — `phantomMethodMsgs` matches `DInterface` and nothing else, so the rule fires with **zero impls and zero uses in the program** and can never see whether a use is determined. This is #1134's over-rejection, stated structurally rather than behaviourally. ⚠️ a second, separable defect in the same site: the diagnostic is pushed with `pushTypeError:2932`, which attributes to `currentLoc.value` — the *live* location at the end of the run, not the declaration — so the caret lands wherever inference last was (on #1134's repro, the impl body). The location is not a deliberate attribution and should not be read as one |
| §6 **C1** (unique most-specific instance) | `cohFirstConflict:10769`/`cohConflictWith:10775`/`cohAnonConflict:10786`/`cohStrictlyMoreSpecific:10735`, invoked from `checkCoherence:10809` (`compiler/types/typecheck.mdk`) | rejects ambiguous overlap at declaration time | 🔴 **SPEC-VS-CODE DIVERGENCE (already tracked: #614, #311).** `cohConflictWith` scans **all declared pairs** and rejects on any `⊑`-incomparable pair — §6.1 choice-point 2's condition **(a) global comparability** — not the spec's stated recommendation **(c) per-goal unique minimum**. The spec's own `Pair` counterexample (`C (Pair Int a)`, `C (Pair a Int)`, `C (Pair Int Int)` — accepted under (c), rejected under (a)) is exactly what this implementation currently gets wrong |
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
| §7.1 **U1/U2** (driver unimodality) | 🔴 **DIVERGENT — a second mode is live.** `data CheckMode = Flat (List Decl) \| Module String (List Decl) (List Decl)` (`compiler/types/typecheck.mdk:12822`); `checkBodyImpl:12824` branches on it at **20 `Flat` arms** (derive: `grep -c '^    Flat ' compiler/types/typecheck.mdk`, against 21 `match mode` sites), and the two paths run different route-stamper sequences (`elaborateDict:9424` vs `elabModuleStamp:18570`) | — | the sole `Flat` constructor site is `checkProgramSeededSplit:12804`, whose live consumers are **not** remnants: `compiler/tools/repl.mdk` (`checkProgramSchemes`), `compiler/tools/check_policy.mdk:523,652,698`, `compiler/tools/doc.mdk:394`, `compiler/entries/playground_main.mdk`, `compiler/entries/core_ir_dict_pp_main.mdk:35` (`elaborateDict`), plus the flat re-entries inside `typecheck.mdk` itself — the promotion fallback (`:9434`, `:9463`, `:9556`) and the exhaustiveness-warning entry `checkMatchToLines:16722` (`:16725`). ⚠️ `compiler/DRIVER-COLLAPSE-PLAN.md`'s **status line says IMPLEMENTED**; this row is the measured counterexample §7.1 retires it with |
| §8 **I1** (evidence abstraction keyed by binding identity) | `dictArityOf:12662` (BARE-NAME, define-side only) vs. the cross-module qualified path `crossModuleFunConstraintsQualRef:2545`/`inferDictAtFound:4918` | dict-param count/order is part of the binding's identity, not its bare name | ⚠️ self-documented live hazard at lines 2415-2444: `dictArityOf`'s bare-name first-match "returns the WRONG module's arity" for two same-named fns of different `=>`-arity. The qualified table fixes the CALL-SITE (importer) leg; `dictArityOf` itself stays bare-name, safe only for the DEFINE-side prepend within the owning module — a residual sharp edge, not asserted as a currently-reproducing bug here |
| §8 **I2** (global instance environment after import resolution) | `importFormSchemes:17309`/`aliasSchemes:17290`/`aliasConstraintEntries:17324` (`compiler/types/typecheck.mdk`) | import scoping affects visibility, never evidence identity | — |
| §8 **I3** (evidence travels, not re-derived) | No INDEPENDENT site — but not because none was located; re-audited with I1's vocabulary (`inferDictAtFound`, `crossModuleFunConstraintsQualRef`) rather than I3's, and the same site applies: `inferDictAtFound:4918` (row I1 above) is exactly the mechanism that lets a cross-module CALLER supply the callee's dict args rather than the callee re-deriving anything | a cross-module call passes evidence as ordinary leading dict arguments (`var`, row above), sized by the callee's identity-keyed arity (I1) — there is nothing *for* the callee to re-resolve; it receives dicts as parameters like any other argument | this is a structural consequence of dict-PASSING itself (the callee is a function of its dict params, not a re-resolver), not a separately-checkable rule — same shape as C2's finding: the right conclusion is "enforced by the calling convention," not "unimplemented" |
| §8 **I4** (module-qualified identity in every namespace; use-site ambiguity) | 🔴 **PARTIAL — two of six namespaces.** ENFORCED for **values**: `checkVar:588` → `isAmbiguous:639`/`ambigMods:644` → `AmbiguousOccurrence`, code `R-AMBIGUOUS-OCCURRENCE` (`resErrorCode:1967`), set built by `ambiguousSet:2264`/`keepAmbiguous:2270`. ENFORCED for **data constructors** (#674): `checkPat:392` and `checkVar:602` → `isCtorAmbiguous:651` → `R-AMBIGUOUS-CTOR`. ENFORCED for **record-field selection**, in *typecheck* rather than resolve and exactly in qualification 2's shape: `resolveFieldByOwners:5392` → `resolveFieldAmbiguous:5403`, which pushes `T-AMBIGUOUS-FIELD` (`:5406`) **only when the receiver is still an unbound var** (`TVar _`) — a receiver whose type is known picks its owner and never consults the name. **UNIMPLEMENTED for types, aliases, interfaces, and record *names***: `checkType:338`'s `TyCon` arm is a bare existence test (`omHasKey n env.types \|\| omHasKey n env.imported`) with no ambiguity arm, and `checkConstraint:386` is `contains iface env.interfaces` — likewise existence-only (both `compiler/frontend/resolve.mdk`); a record name resolves through `recordByNameRef`, a last-write-wins map with no ambiguity diagnostic. Derivation for the negative half: the **only** four ambiguity codes in the tree are `R-AMBIGUOUS-OCCURRENCE`, `R-AMBIGUOUS-CTOR`, `T-AMBIGUOUS-FIELD`, `T-AMBIGUOUS-INSTANCE` (`grep -rn AMBIGUOUS compiler/ --include='*.mdk'`), and the last is instance selection, not naming. Interface *methods* are values, so they inherit the value rule; the interface *name* does not | a use site whose name yields no unique origin is rejected; the declarations are not | ⚠️ the implemented half is not identity-carrying either — it is a *diagnostic* over a name→module provenance map, not a resolution to an identity the AST carries. Type-name→origin resolution still happens **inside typecheck** (`fromAstTypeE:4047` reading `aliasTableRef`), and value binder ids are minted **inside** `checkBodyImpl` (`stampBindingIds`, declared at `compiler/frontend/resolve.mdk:3126` but *called* at `compiler/types/typecheck.mdk:12839`) and are per-run integers, not `(module, name)`. So no downstream table is identity-keyed today; the #1070 audit's bare-name tables are the consequence, and I4's *"a bare `String` key is not a key"* is the clause they fail. `keepAmbiguous:2273` additionally exempts `core` and any same-module top-level, which is I4's qualification 1 (scoping resolves before ambiguity applies) already realized for values |
| §8 **I5** (instance candidacy is graph-global) | 🔴 **PARTIAL — cumulative, not global.** `foldModules:17745` threads `accAll ++ prog` and `appendUniverseAccums:16925` grows the persistent impl universe (`growImplUniverse` over `implDeclsWithReqs:14030`) one module at a time, in the loader's dependency-first topological order (`compiler/driver/loader.mdk:570`) | the candidate set a goal is resolved against | so a module's candidate set is *every impl of every module earlier in the topological order*, plus its own — which is **strictly more** than its transitive imports (an unrelated sibling subtree fully visited earlier is included) and **strictly less** than the graph (nothing later is). The first half is order-dependence of exactly #1072's kind; the second is what I5 removes. ✅ the visibility half of I5 already holds: `implDeclWithReqs:14033` matches `DImpl { iface, tys, reqs, … }` and **never reads its `pub` field** (`compiler/frontend/ast.mdk:437-443`), so an impl's declared visibility governs no candidacy today — and `SHADOW-SEMANTICS.md` S2 already asserts the universe is *"GLOBAL — local ∪ imported ∪ prelude"* for its own routing rule |
| §9 soundness statements (type preservation, semantic adequacy, coherence, evaluator interchangeability, `gen-sig` authority) | composite of every row above | explicitly "targets for a later proof/audit" (§9's own header) — not independently implemented checks | — |

**Partial enforcement found (NOT "unimplemented"):** §3 W2 (instance-context
termination/Paterson coverage) has no *static, declaration-time* check, but a *dynamic,
resolution-time* depth cutoff does exist — `routeOfD`/`argImplRequiresRoutesRecD`, the
#217 "WS-4b fuse", bounded at depth 32. See the W2 row above for why that is not
equivalent to the spec's condition: a non-shrinking context terminates but is never
rejected, and there is no diagnostic at depth 33.

**Prominent divergence found:** §6 C1's implementation enforces condition (a)
(global pairwise comparability) where the spec commits to condition (c) (per-goal
unique minimum) — already tracked as #614 and #311; this table independently
re-confirms it against source at `c4ef6dbe`, with the exact reject site
(`cohConflictWith`) and the exact spec passage it contradicts (§6.1 choice-point 2).

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
#1052); **§6.2 T3/T4** (the route-stamper drain is keyed on the **module** boundary,
while the tyvar cells it depends on survive it); **§7.1 U1/U2** (`CheckMode` is live,
with 20 `Flat` arms and six external consumers, against
`compiler/DRIVER-COLLAPSE-PLAN.md`'s status line of IMPLEMENTED).

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
