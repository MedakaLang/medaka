# Effect-and-Capability Semantics for Medaka

**Status:** specification (theory-first, *idealized*). **Scope:** the typing,
inference, and meaning of Medaka's effect rows — including **parameterized
effects** (effect labels refined by a domain-drawn parameter) — and the
conditions under which the effect discipline is *sound*, the inference *principal*,
and the resulting row a trustworthy **capability manifest**.

## 0. Purpose and the non-derivation principle

Medaka annotates function types with **effect rows** (`<IO>`, `<Net "a.com/*">`,
`<Rand, Clock>`, `<IO | e>`). The intent is bigger than "track side effects": a
sound, fine-grained row is a **compiler-verified capability manifest** — the type
tells you (and the platform that runs the module) exactly what authority the code
exercises. The hard part is **parameterized effects**: a label like `Net` carries
a *parameter* (which hosts? which paths?) drawn from a refinement domain, and the
parameter must be tracked soundly through inference so that a module pinned to
`<Net "idp.example.com/*">` provably cannot reach `evil.com`.

This document fixes the semantics **from the theory of type-and-effect systems
and capability safety**, not from the current code. It is written to be a *target
the implementation is audited against* — deliberately *idealized*: where the
theory points past what is built (e.g. richer parameter domains, more precise
abstraction, interprocedural authority tracking), the spec follows the theory and
the gap becomes an audit finding, not a constraint on the spec. Where spec and
implementation disagree, that disagreement is a finding to triage; the spec is
**not** a description of present behavior.

Theory anchors:

- **The type-and-effect discipline** — Gifford & Lucassen (FX, 1986/88);
  Talpin & Jouvelot (*The Type and Effect Discipline*, 1994). A typing judgment
  carries a third component, the *effect*, inferred with **effect variables**.
- **Row-polymorphic effects** — Leijen (*Koka: Programming with Row-Polymorphic
  Effect Types*, 2014); Rémy / Wand (extensible rows). Medaka's
  `<l₁,…,lₙ | μ>` uses row polymorphism, but not Koka's duplicate-label algebra:
  Medaka joins same-label authorities and has no in-language handlers.
- **Effects as capabilities** — Brachthäuser, Schuster, Ostermann (*Effects as
  Capabilities*, 2020); the object-capability model (Miller). An effect is the
  *requirement of an authority*; the program cannot perform it without the
  ambient permission, and the **host is the handler** that grants or denies at the
  module boundary.
- **Abstract interpretation** — Cousot & Cousot (1977). A parameterized effect's
  parameter is an *abstraction* of a concrete authority value; the abstraction
  function α must be a **sound over-approximation** (a Galois connection), which is
  exactly what makes the no-exfiltration guarantee hold.

Deliberately **out of scope, permanently** (decided, not omitted): algebraic-effect
**handlers** / delimited continuations / `resume`; typed-error (`Throws E`) effects.
Medaka takes effect *tracking* and rejects effect *handling*: `Result` is the
canonical error representation and `panic` is the sole unrecoverable escape. See
§7 for why the handler's role is played by the host, not by in-language control flow.

Terminology bridge (Medaka surface → this document; no implementation terms):

| Medaka surface | This document |
|---|---|
| effect row `<IO>` / `<Net "h/*"> ` / `<IO ∣ e>` | effect row `φ` |
| effect label `Net`, `IO`, `Rand` | effect/operation label `L` |
| literal parameter `"a.com/*"` | refinement-domain element `p ∈ 𝔻_L` |
| named authority parameter `path` | scoped authority variable `κ : Authority 𝔻_L` (§4.1) |
| bare label `FileRead` | unconstrained authority `⊤_𝔻_L` |
| row tail `… ∣ e` | effect-row variable `μ` |
| `effect Net Prefix` | label declaration binding `L` to domain `𝔻_L` |
| kind annotation `(e : Effect)` on a declaration head | the kind `Effect` of §6.1 |
| pure (no annotation) | the empty closed row `⟨ ⟩` |
| the known-prefix analysis (`α`) | the abstraction function `α : Expr → 𝔻` |
| `check-policy` / capability manifest | manifest extraction `M(·)` (§7) |
| the Wasm host / platform | the **handler** — the capability grantor (§7) |

A note on **orthogonality to dictionaries.** Effects coexist with Medaka's
qualified-type (interface/`=>`) system specified in
[`DICT-SEMANTICS.md`](DICT-SEMANTICS.md). The two are *independent*: dictionaries
are evidence routed by label/method identity; effect parameters are **compile-time
terms that ride on the row**, related by authority constraints and never routed. This document
suppresses the predicate context `P` of the dictionary spec; a full judgment is
`P ∣ Γ ⊢ e ⇝ e' : τ ! φ`, and the effect rules below thread `φ` orthogonally to
the `P ⇝ e'` translation.

---

## 1. Source language (the effectful fragment)

We model what bears on effects. Types now carry effects on every arrow, and
schemes quantify **type, effect-row and authority variables**:

```
p   ::= ⊤_𝔻 | … domain-specific elements …      -- parameter from a domain 𝔻 (§2)
q   ::= p | κ | q ⊔ q | {axis = q, …}             -- domain-typed authority term (§4.1)
a   ::= L · q                                    -- atom: label L refined by authority q
φ   ::= ⟨ a₁ … aₙ ∣ μ? ⟩                         -- effect row: atom set + optional tail var μ
τ   ::= α | T τ̄ | τ₁ →^φ τ₂ | (τ̄)               -- monotypes; arrow carries a latent effect φ
                                                -- T τ̄ may include an effect-row argument (§6)
ρ   ::= τ                                        -- (qualifiers from DICT-SEMANTICS suppressed)
σ   ::= ∀ᾱ. ∀μ̄. ∀κ̄. C ⇒ (ρ ! φ_force)          -- binding scheme with residual authority constraints
```

Authority indices have kind `Authority 𝔻`; a qualified value type `τ @q` records
an upper bound on that value's domain-directed abstraction, not an exact runtime
singleton. These annotations erase. Strict bindings use `φ_force = ⟨ ⟩`.

- An **arrow** `τ₁ →^φ τ₂` reads "a function that, *when applied*, may perform
  `φ`." `φ` is the **latent** effect — it is discharged at application, not at
  closure construction (closing over an effectful body is pure; *calling* it is
  not). The empty closed row `⟨ ⟩` is a *pure* function.
- An **effect row** `φ = ⟨ ā ∣ μ ⟩` is a finite set of atoms `ā` with **at most
  one atom per label** (canonical form; same-label atoms are merged by the domain
  join `⊔`, §2), plus an optional **tail variable** `μ`.
  - `μ = ·` (absent) ⇒ **closed** row: exactly `ā`.
  - `μ = ρ` (present) ⇒ **open** row `⟨ ā ∣ ρ ⟩`: `ρ` can absorb further atoms.
- A **label environment** `LE` records, for each declared label `L`, its
  **domain** `𝔻_L` (§2). Every label is a host capability (§7). Built-in
  labels and `effect`-declarations populate `LE`.

A written row without a tail is closed. A named tail in a declaration is
universally quantified; a fresh inference tail is flexible. These roles must
remain distinct through checking and instantiation (§5.1).

---

## 2. Effect rows and the refinement-domain lattice

This is the first half of the parameterized-effect story: **what a parameter is**.

### 2.1 Domains

A **refinement domain** `𝔻` is a bounded join-semilattice with a partial meet:

```
𝔻 = (P, ⊑, ⊤, ⊔, ⊓)
    ⊑ : P × P → Bool          -- refinement order (decidable)
    ⊤ : P                      -- the unconstrained / maximal-authority element
    ⊔ : P × P → P              -- join: least over-approximation of two authorities
    ⊓ : P × P → P ∪ {⊥}        -- meet: greatest common authority, ⊥ if disjoint
```

subject to the laws: `⊑` is a partial order; `⊤` is the top (`p ⊑ ⊤` for all
`p`); `⊔` is the least upper bound and `⊓` the greatest lower bound w.r.t. `⊑`;
`⊔` is total (saturating to `⊤`), `⊓` may be `⊥`. **Higher in `⊑` means *more*
authority.** `⊤` = "any authority." A render `drender : P → String` produces the
manifest text (§7). This is exactly the abstract-domain interface of abstract
interpretation; a label's parameters live in *one* such domain, fixed by the
label's declaration.

The canonical domains (the spec defines the **family**; the implementation may
realize a prefix of it — see the audit):

| Domain | Elements | `⊑` | `⊔` | `⊓` |
|---|---|---|---|---|
| **`Unit`** | `()` only | trivial | `()` | `()` |
| **`Prefix`** | a delimiter-terminated string pattern, or `⊤` | structural prefix-containment (§2.3) | longest common prefix, saturating to `⊤` | the more specific, or `⊥` if neither contains the other |
| **`Set`** | a finite set of strings, or `⊤` | `⊆` | `∪` (saturating to `⊤` past a cardinality cap) | `∩` |
| **`Product`** | a tuple of sub-domains, e.g. `Net = Host(Prefix) × Method(Set)` | pointwise | pointwise | pointwise (⊥ if any component ⊥) |

`Unit` is the *atomic* label of v1 (an unparameterized effect is `L · ()`); it is
the degenerate one-point domain. Everything below is stated **domain-generically**:
the row machinery (§3–§5) is written against the `𝔻`-interface and is identical
for every domain. Adding `Set`/`Product` is a new domain instance plus a parser
clause for its literal syntax — **no change to unification, the escape check, or
the manifest extractor.** That domain-parametricity is the whole point.

### 2.2 Rows as domain-indexed maps

Canonically, a row's atom set is a finite **partial map** from labels to
parameters, `ā : L ⇀ P` with `ā(L) ∈ 𝔻_L`. Two syntactic atoms on the same label
are **never two members** — they collapse to one by `⊔` in `𝔻_L`. (Distinctness
holds *across* labels only; within a label the canonical form is the join,
otherwise the order in §2.4 is ill-defined.) A v1 atomic label `Foo` is exactly
`Foo · ()`.

### 2.3 The `Prefix` domain and the delimiter discipline

`Prefix` is the security-critical domain (hosts and paths). Its parameter is a
pattern; `⊤` = `None` (any). The refinement order:

```
p₁ ⊑ p₂   iff   p₂ = ⊤,
             or  p₂ is a pattern (ends in `*`) and p₁'s concrete part STARTS WITH p₂'s concrete part,
             or  p₂ is an exact element and p₁ = p₂
```

An element written without a trailing `*` is exact and admits only itself:
`"/etc/host"` does not admit `/etc/hostname`, `"/etc/host*"` does.

so `Net "a.com/api/v1" ⊑ Net "a.com/api/*" ⊑ Net "a.com/*" ⊑ Net ⊤`. **Raw-prefix
matching is unsound for authority** — `"a.com"` is a string-prefix of
`"a.com.evil.com"`, so a bare prefix would silently grant a sibling host.
The domain therefore requires every pattern to terminate at a **structural
delimiter**: a path/host boundary (`/`) or an explicit trailing `*`. `Net "a.com/*"`
matches `a.com/...` but **not** `a.com.evil.com/...`. A pattern lacking a delimiter
is rejected at declaration/annotation time. Full scheme/host/port/path structure is
the `Product` domain; `Prefix` is its sound, coarse one-axis approximation. Only
trailing-`*` wildcards are admitted — general globs/regex break decidability of
`⊑` and are rejected.

### 2.4 Sub-effecting (row order)

The order on rows, `φ₁ ≤ φ₂` ("`φ₁` performs no more than `φ₂`"), lifts the domain
orders pointwise and accounts for the tail:

```
⟨ ā₁ ⟩ ≤ ⟨ ā₂ ⟩   iff
    ∀ L·p₁ ∈ ā₁.  ∃ L·p₂ ∈ ā₂.  p₁ ⊑_{𝔻_L} p₂

G ⊨ φ₁ ≤ φ₂   iff   ∀ θ satisfying G. θ(φ₁) ≤ θ(φ₂)
```

The second rule extends the closed-row order to symbolic rows under declared
assumptions `G`. The mere presence of two tails is **not** a proof of containment:
`⟨e₁⟩ ≤ ⟨e₂⟩` does not hold for unrelated universal variables. In particular,
`⟨ ⟩ ≤ ⟨e⟩` and `⟨e⟩ ≤ ⟨e⟩` hold, but `⟨Stdout | e⟩ ≤ ⟨e⟩` does not.
Flexible inference variables generate ordered constraints; universal variables
are caller-chosen and cannot be solved by the body. Equality requires both
directions. Joins retain all their symbolic operands.

`≤` is the soundness order: a value of effect `φ₁` is usable where `φ₂` is
permitted iff `φ₁ ≤ φ₂`. The **direction matters for security**: `<Net "a.com/*">
≤ <Net ⊤>` (specific is usable where general is allowed) but `<Net ⊤> ≰ <Net
"a.com/*">` (a ⊤/any-host capability is *not* usable where only `a.com` is
permitted). This is precisely the gate that rejects exfiltration (§4, §5).

The **join** of two rows `φ₁ ⊔ φ₂` (used by inference, §3) is the label-wise
union with same-label params joined by `⊔_{𝔻_L}`; it is the least row `≥` both.

---

## 3. The effect judgment and effect inference

This is the second half: **how rows are inferred and checked.** The judgment

```
Γ ⊢ e : τ ! φ
```

reads "in environment `Γ`, `e` has type `τ` and its *evaluation* may perform
`φ`." `φ` is the **immediate** effect of running `e` to a value; latent effects of
functions sit on arrows (§1) and are released by `app`.

```
            x : ∀ᾱμ̄κ̄. (τ ! φ_force) ∈ Γ        S freshens all three sorts together
(var)   ─────────────────────────────────────────────
            Γ ⊢ x : S(τ) ! S(φ_force)

            Γ ⊢ e₁ : τ₂ →^φ₀ τ ! φ₁        Γ ⊢ e₂ : τ₂ ! φ₂
(app)   ──────────────────────────────────────────────────────
            Γ ⊢ e₁ e₂ : τ ! φ₁ ⊔ φ₂ ⊔ φ₀              -- evaluate fn, evaluate arg, THEN perform latent φ₀

            Γ, x:τ₁ ⊢ e : τ₂ ! φ₀
(lam)   ──────────────────────────────────────
            Γ ⊢ (λx. e) : τ₁ →^φ₀ τ₂ ! ⟨ ⟩           -- building a closure is pure; body effect is LATENT

            Γ ⊢ e₁ : τ₁ ! φ₁     Γ, x:gen(Γ, τ₁, ⟨ ⟩) ⊢ e₂ : τ₂ ! φ₂
(let)   ────────────────────────────────────────────────────────────
            Γ ⊢ (let x = e₁ in e₂) : τ₂ ! φ₁ ⊔ φ₂

            Γ ⊢ e : τ ! φ        φ ≤ φ'
(sub)   ─────────────────────────────────                -- subsumption: weaken to a larger row
            Γ ⊢ e : τ ! φ'
```

Primitive declarations and interface signatures supply the latent rows consumed
by these same rules:

```
            p has a trusted, authority-qualified primitive signature σ
(prim)      instantiate σ using (var), then check every supplied argument using (app)

            (op : … <e> … ) a class/interface method whose signature carries an effect var
(method)    — the effect var is instantiated like any μ̄ by (var); the method's
              latent row is fixed by the instantiated signature, independent of dispatch.
```

Reading:

- **`var`/`lam`** distinguish a value from a computation producing that value.
  Looking up a strict local or an already-constructed function is pure. A lazy
  top-level binding incurs its initializer's forcing row, even when its result
  is a function. A function's latent row lives on its arrow and is released by **`app`**,
  which **unions** the function-expression's, argument's, and latent effects. This
  is what makes effects flow through ordinary application without explicit
  threading.
- **`prim`** uses the same substitution and argument checking as a source
  function. Named determining arguments relate argument authorities to the
  latent row (§4.1); a fixed literal emits that authority regardless of arguments.
  An extern has no unchecked parameter-hole exception. Its declaration must
  faithfully describe the trusted runtime operation, including every determining
  position (for example both paths of a rename).
- **`let`/`gen`** generalizes; §6 gives the generalization rule for effect
  variables and its value-restriction side condition.
- **`sub`** is the only place the row *grows* without a cause — it is how an
  annotated bound is satisfied by a more specific inferred row, and how the two
  branches of an `if` are reconciled (each subsumed to their join).

**Principal effects.** Inference is intended to compute, for every `e`, the
*least* row under `≤` (equivalently: the join of exactly the atoms `e` can
actually perform, with the most specific parameters `α` can justify). `var`
contributes the binding's forcing row; `lam` contributes nothing; `app`/`let` join;
`prim` contributes its declared instantiated row; `sub`
is applied only where a bound forces it. Runtime memoization does not remove a
potential force from a static may-effect: no proof assumes some other caller
already evaluated the binding. Strict `let` charges its RHS immediately and
binds a pure lookup; a top-level thunk binds the RHS's full row for later lookup.
An annotation on the resulting value cannot erase this separate forcing row.
The least-row property is what makes the
inferred row a *tight* manifest rather than a conservative blanket.

---

## 4. Parameter creation: the abstraction α

The parameter associated with a determining argument is `α(e_k)`, where the
domain-directed abstraction reads both the expression and its checked type and is a
**sound abstraction** of the authority the argument denotes. Formally, with `γ`
the concretization (the set of runtime values a domain element admits), `α`/`γ`
form a Galois connection and the soundness obligation is

```
            ⟦e_k⟧  ∈  γ(α(e_k))                     -- α OVER-approximates: the real authority is admitted
```

i.e. the parameter the type system records is **never smaller** than the authority
the code actually exercises. Over-approximation toward `⊤` is always safe; the
only unsound move is to under-approximate (claim a *narrower* authority than the
code can reach). The ideal abstraction over string-producing forms (`Unknown ⇒ ⊤`
is the safe default):

| Core form | `α` |
|---|---|
| string literal `"s"` | the singleton authority `s` (e.g. `Prefix` pattern from `s`) |
| `e₁ ++ e₂` (concatenation) | in `Prefix`, a justified left prefix bounds the whole; in `Set`, non-literal concatenation gives `⊤` |
| string interpolation `"s\{e}…"` | the `++`-chain rule: the leading literal `s` is the known prefix; the first interpolated expression stops it |
| `let x = e₁ in …x…` | propagate `α(e₁)` to uses of `x` |
| `if c then e₁ else e₂` | `α(e₁) ⊔ α(e₂)` (join of branch authorities) |
| `match … { … ⇒ eᵢ }` | `⊔ᵢ α(eᵢ)` (join over arms) |
| a value whose checked type is `τ @q` | `q`, including variables, application results and field reads |
| application result, parameter, or field without an authority qualifier; anything else | `⊤` |

**The ⊤-fallback *is* the no-exfiltration guarantee.** A URL/path that is computed
(a function result, a runtime input, an un-analyzable expression) abstracts to
`⊤`, and `<L·⊤> ≰ <L·"pinned/*">` by §2.4 — so a module pinned to a specific host
**cannot** satisfy its bound with a runtime-chosen destination; it is *rejected at
type-check*. "No exfiltration to an attacker-chosen target" is literal-lifting
doing its job, not a separate check.

**Precision is a parameter of α, soundness is not.** The table above is the
*idealized* abstraction, including let/`if`/`match` propagation and the join over
branches. A weaker α (e.g. one that only recognizes a literal in argument
position and abstracts everything else to `⊤`) is **still sound** — it merely
*over-rejects* (a program the ideal would accept is refused because its authority
needlessly widened to `⊤`). Two precision levels are worth naming:

- **Intraprocedural** (the practical instance): authority is tracked within one
  function body; a value threaded through a *helper* collapses to `⊤` at the call
  boundary (`f ē ⇒ ⊤`). Sound, decidable, cheap.
- **Signature-indexed**: named authority relationships and qualified fields retain
  precision across calls (§4.1). This is rank-1 parametric indexing, not arbitrary
  dependent types, runtime singleton types, or interprocedural execution.

Because both are sound, the choice of α-precision is an engineering dial, **not** a
correctness question. The audit measures the implemented α against the idealized
table; every shortfall is a *completeness* (over-rejection) gap, never a soundness
hole.

---

### 4.1 Named authorities, fields and scoped constraints

The parameter forms are a literal, a named authority, or a bare label meaning
top. The quoted underscore is not a form: the parser rejects it in every
declaration, source or extern, naming the named-arrow replacement.

A named arrow argument `(path : String) -> <FileRead path> String` binds a fresh
authority `κ` scoped over the result type. Elaboration qualifies that argument
as `String @κ` and records `FileRead · κ` on the arrow. The relationship is to
the argument's position and resolved binder identity, not the spelling of the
definition's pattern or the name of the called function. Pattern names may differ
from signature binders. Partial applications retain the instantiated relationship.
Binders are lexical and signature-local: an atom or qualifier may name only a
binder written to its left in the same signature (`R-UNBOUND-AUTHORITY`), and a
named argument is well-formed only immediately left of an arrow
(`R-MISPLACED-AUTHORITY-BINDER`). Inside a body, `α` reads a name by its
binding: a match arm, a let pattern or a local definition that rebinds a name
shadows every outer let and every outer checked type of that name (an arm that
merely renames the scrutinee reads the scrutinee), and a let's right-hand side
is read in the scope it was bound in, never against a later rebinding. A binder must have type `String`
(`T-AUTHORITY-BINDER`) and serves labels of one domain (`T-AUTHORITY-DOMAIN`).
A qualifier is written with a spaced `@`: `String @p`. A joined qualifier
`String @(a | b)` is bounded by the join `a ⊔ b`: a value within either
authority, the type of a branch that returns one of two named arguments. Its
names must be binders of one domain (`T-AUTHORITY-DOMAIN`).

Each authority has exactly one domain. A binder used by two compatible Prefix
labels shares a variable; incompatible-domain uses are ill-formed, and so is a
qualifier naming a named argument that no atom or index slot of the signature
gives a domain (`(a : String) -> String @a`): nothing says which domain `a` is
an element of, so the qualifier would bound nothing. Product
domains retain their declared axis schema, `effect L Product (Host : Prefix,
Method : Set)`: the axes are declared in order and the first is the primary
axis an unqualified string argument or a bare written literal lifts into; a
written product may name only declared axes; a Product declared without axes
is ill-formed. Missing axes mean top. Domain mismatches are errors, never
proofs of containment.

At a call, instantiation freshens all quantified variables with one substitution.
Checking an argument against `τ @κ` checks its underlying type and generates
`α_𝔻(argument) ⊑ κ`, where `α` reads the argument's syntax first (a literal, a
`++` whose left operand is justified in a prefix-shaped domain, a same-body
`let`, a branch join) and otherwise the argument's checked type: the qualifier
of a `τ @q`, else the domain's top. A flexible `κ` accumulates lower bounds by
symbolic join, subject to its upper bounds; the scope that owns it takes the
least solution, variables bounded by each other collapsing to one representative
first. An upper bound that is a join with flexible members (`q₁ ⊔ κ`, the
bound a joined qualifier writes) has no single least solution, and no member
is chosen for it: such an obligation is decided once the join's members are
known, so a value in `String @(p | q)` is built against written or otherwise
determined indices. A solution for a variable older than a match arm or a
clause that opened an existential names the opened authority as its domain's
top, as an inferred row publishes it: the opened authority cannot leave the
arm through the solve. An obligation over a variable no binding owns — a value binding kept
monomorphic by the value restriction — is decided once over every use in the
module. An unresolved constraint remains an obligation; it is not successful
coverage. At a definition, universally bound `κ` is rigid: an unrelated literal
cannot establish `literal ⊑ κ`. An honest wrapper may forward the argument or
perform a domain-preserving operation on it. Publication quantifies an authority
variable only where the published type gives a caller a way to supply it, a
qualified argument slot; a variable occurring only in rows has no source and
publishes as the domain's top.

Symbolic joins flatten and deduplicate identities without replacing variables
by top. `q₁ ⊔ q₂ ⊑ q` requires both operands to be covered; `q ⊑ q` and
`q ⊑ q ⊔ q'` hold. Concrete operands use the domain algebra. Residual constraints
must travel with a generalized scheme, sharing its substitution; no residual
may refer to a rigid variable outside its scope.

Every authority-index introduction must have a proof source: a qualified
argument or field, a retained constructor constraint, a generative existential,
or an explicitly trusted FFI operation. An opaque `Handle κ` may store only a
raw handle when its controlled constructor establishes κ; an unrestricted
constructor cannot invent κ. A constructor with type
`∀κ. String @κ -> Handle κ` must check the stored value against that qualifier.
Matching a `Handle q` recovers `String @q` only for a field actually declared
with that qualifier. An ordinary `String` field remains unqualified.

The surface (ratified 2026-09-25) is a data parameter of kind `Authority L`,
`data Handle (p : Authority FileRead) = Handle (String @p)`: the label selects
a declared domain rather than creating a new runtime type, and the parameter may
appear in that declaration's fields as a qualifier (`String @p`), an atom's
parameter (`Unit -> <FileRead p> String`) or an index of another type
(`Other p`). A constructor is a proof source when some field of it carries the
parameter, because applying it checks each argument against the instantiated
field type by the directed judgment; such a constructor may be applied wherever
it is visible. A constructor none of whose fields carries the parameter is a
phantom index: applying it proves nothing, so it is a proof source only in its
declaring module, trusted as an extern's row is, and a `public export data`
with an `Authority` parameter must carry it in every constructor
(`T-AUTHORITY-PHANTOM-EXPORT`); `export data` is the raw-handle shape. Record
construction and update flow each supplied field into the declared field type
as an argument (`α(value) ⊑ q`), a field read yields the declared type
verbatim, and a record pattern binds the declared type whether punned or
explicit. Matching recovers exactly the declared field types under the
scrutinee's index substitution, flowing directed and never through undirected
unification; it never refines the index.

*Carrying* is decided by the field's type, not by mention. A field carries
the parameter `p` when every value of the field's type holds a value at `p`'s
authority: a qualifier (`String @p`), a tuple with a carrying component, or an
index `H … p …` of a head whose every constructor carries that parameter
(`Handle p`, by `Handle`'s own constructors; through a type parameter,
`Box (Handle p)` when `Box`'s constructor holds its parameter). `List (Handle p)`
mentions `p` and carries nothing, since `[]` inhabits it at every index; an
arrow `Unit -> <FileRead p> Unit` carries nothing, since an idle closure
inhabits it. A head whose constructors an importer cannot apply (`export data`,
a private head) is trusted, since only its declaring module builds a value of
it; a builtin container (`List`, `Array`) carries nothing. Recursion through
a head assumes the head carries: a finite value bottoms out in a carrying
constructor, or the type is empty. So `public export data Tok (p : Authority
FileRead) = Tok Int (List (Handle p))` is refused as a phantom export, and a
carrying head is applied anywhere and proves its index through the ordinary
argument route, in any order of inference. Three further consequences: a
field read outside a pattern of a field under an existential binder recovers
the domain's top for that binder, since a read cannot open it; an update of
such a record replaces every field that mentions the binder or none of them,
since one binder cannot name two values at different authorities; and an
unsigned binding whose authority variable occurs in no argument position of
its type publishes the top for it (`mkRaw = Raw` is `Int -> Raw *`), while a
written signature publishes as written.
(`mkRaw = Raw` is
`Int -> Raw *`), so a forwarder cannot republish a phantom constructor.

An `Authority`-kinded type-argument slot takes an authority term, kind-directed
as an `Effect` slot takes a row: a named argument's name (`open : (path :
String) -> <FileRead path> Handle path`), a bare lowercase name, which is a
universally quantified authority variable of the signature binding for
everything to its right exactly as a type variable does (`read : Handle p ->
<FileRead p> String`), a literal of the label's domain (`Handle "config/*"`,
what `open "config/x"` renders as), or `*`, the domain's top (`Handle *`, what
`open dyn` renders as; a row spells the top by omitting the parameter, an index
argument cannot be omitted). Index slots are invariant (§6.4): `Handle
"config/app"` is not a `Handle "config/*"`. A name is an authority binder only
where something binds it — a named argument of type `String`, an
`Authority`-kinded index slot, a head's `Authority` parameter, a constructor's
existential binder; an atom or a qualifier naming a type variable is
`T-AUTHORITY-KIND`, and an authority binder in a type position, or a type in
an `Authority` slot, the same code.

An `extern data` head (`extern data Socket (h : Authority Net)`) has no
constructors: its only proof sources are the runtime catalog's signatures
that return it, trusted as any catalog row is, so its index is exactly the
authority the producing extern was granted (`netTcpConnect : (host : String) ->
Int -> <Net host> Result String (Socket host)`), and every extern that consumes
one is charged at its index (`netSend : Socket h -> … <Net h> …`). A field of
such a type carries its parameter, since no importer can build a value of it.
A descriptor number read from one (`socketFd`) grants nothing: no extern that
reaches an endpoint accepts a number. A program adds no proof source: a
redeclared catalog extern must be an instance of the catalog's signature, so it
may fix `h` (`Socket "a.com/*"`) and is then charged at what it fixed, and a
foreign extern's types must cross the C boundary, which an extern type does not.

A constructor may bind an existential authority by a kinded group leading its
fields, `data AnyHandle = AnyHandle (p : Authority FileRead) (Handle p)`.
Packing takes the argument's own index. A match arm or a function clause whose
pattern names such a constructor opens a fresh RIGID authority scoped to that
arm or clause: values may be related by it inside (`sameAs h s` with `h :
Handle κ` and `s : String @κ`), an unrelated literal does not lie within it,
and a declared bound does not admit it. The opened authority may not occur in
the scope's value type nor reach anything older than the scope
(`T-AUTHORITY-ESCAPE`); a row the scope performs at it is checked against the
enclosing declaration as any row is, so only the label bare admits it, and an
inferred row publishes it as the domain's top — the safe over-approximation of
§4. A `let` or `do` pattern cannot open an existential
(`T-AUTHORITY-EXISTENTIAL-SCOPE`): it has no end at which the escape could be
checked. Only `Authority` existentials exist; a type or row existential is a
parse error.

Each effect label has resolved declaration identity `(origin, name)`, independent
of its printed spelling. Imports and reexports preserve that identity and its
unique domain schema. Two modules' same-spelled declarations cannot be merged
by traversal order, even if their schemas happen to agree.

The directed value relation accepts `τ @qa` at `τ @qe` iff `qa ⊑ qe` and the
underlying types are compatible. An unqualified expected type forgets authority;
an unqualified actual value cannot gain a narrower qualifier without
expression-directed evidence. Arrow types compose this relation with variance.
A value qualifier reaches a type metavariable only through a directed flow: an
argument into a flexible slot (which receives an allowance above the value's
authority, so several values can converge), a declared parameter, a match
scrutinee, or an application's result. Undirected unification equates value
types and erases a top-level qualifier, since it cannot tell which side is the
value: `p ++ "/x"` equates two Strings, and the result of an operator is a new
value whose authority is `α`'s business. Ordinary polymorphic identity preserves
a qualifier through its argument and result flows. Forgetting a qualifier to an
ordinary value type safely loses precision; inventing one from an unqualified
value requires the expression-directed proof above. Branches join authorities.
Composition `g >> h` takes `g`'s own domain, qualifier included, and pipes
`x |> f` are the application `f x`. Mutable storage and authority indices are
invariant: every write must satisfy the stored qualifier.

Medaka remains rank-1 HM. A generalized alias can instantiate its scheme afresh;
a higher-order argument retains one instantiated monotype and its relationships,
not a new polymorphic scheme at each invocation. None of these terms affects
dictionary selection, runtime argument count or constructor layout.

## 5. Sub-effecting, escape, and the no-laundering law

Soundness is enforced at exactly two seams, both instances of the order `≤` (§2.4).

**The binding-boundary escape check.** When a binding `f` carries a declared row
bound `φ_decl` (from its signature) and inference gives its body `φ_inf`, the
obligation is

```
            φ_inf ≤ φ_decl                          -- inferred effects fit the declaration
```

else **`EffectEscape`**: `f` is declared with `φ_decl` but also performs the
atoms `φ_inf \ φ_decl` (where `\` is the per-label residual: a label absent from
`φ_decl`, *or* present with a param `p_inf ⋢ p_decl`). The diagnostic names the
offending atom — "performs `<Net "evil.com">` where only `<Net "a.com/*">` is
allowed."

**The laundering / covariant-position check.** Storing an effectful value where a
lower-effect type is expected must be rejected, *even point-free* — `launder =
emit` (binding an `<IO>` function to a pure-typed name) cannot erase the row.
This is a directed type/effect judgment, respecting arrow variance and invariant
indices. Equality and directed flow are distinct relations; neither may erase an
unproved row difference. Instantiation freshens quantified variables only: a
closed row cannot become a fresh allowance merely because its function is aliased,
passed as an argument, or composed with another function.
An unshaped receiving type variable is different: it has no existing arrow row
to preserve. Giving that slot a value shape may introduce positive inference
allowances, constrained by every supplied value's unchanged row. Those allowances
take their least solution before publication; they cannot manufacture an
unconstrained result effect. Domains and invariant arguments still use equality.

**No-laundering law.** *Every elimination of an effectful value flows its row into
the ambient effect; no construct discards or downgrades a row except by `sub` to a
larger one.* This includes forcing bindings, applying aliases/partial applications,
recovering fields, and invoking stored callbacks. A consequence: the effect of a whole program is `≥` the join of every
primitive it can reach — there is no syntactic hiding place.

**Decidability.** The two checks reduce to deciding `≤`, which reduces to deciding
each `⊑_{𝔻_L}`. The spec's domains keep `⊑` decidable: `Unit` trivial; `Prefix`
trailing-`*`/delimiter-terminated (no general globs); `Set` finite `⊆`; `Product`
pointwise. Banning general globs/regex is a *decidability* requirement, not a taste.

---

### 5.1 Universal declarations and publication

A declared signature is checked under an implication scope: its universally
quantified type, row and authority variables are caller-chosen constants; its
declared constraints are assumptions. Inference may solve local metavariables,
but may not choose a declared variable's value, identify distinct universals, or
let a local universal escape. The implementation's type and effects must satisfy
the declared type by the directed judgment under those assumptions.

Thus `quiet : Unit -> <e> Unit; quiet _ = ()` is valid because `<> ≤ <e>`.
`bad : Unit -> <e> Unit; bad _ = putStr "x"` is invalid because
`<Stdout> ≰ <e>` for arbitrary `e`. A wrapper applying an argument of type
`Unit -> <e> Unit` may perform `e`, but not `Stdout ⊔ e` without declaring it.
Inferred variables in unsigned bindings remain flexible.

On success publish the declared scheme, fresh-instantiable at each use. An
outermost effect annotation, such as `value : <Audit> Unit`, bounds the binding's
forcing computation; an effect on an arrow instead bounds application. For an
ordinary binding with no written forcing annotation, infer its forcing row
independently of the annotated value type. An explicit `<>` promises pure forcing.
An interface method without a forcing annotation also promises pure forcing:
generic clients must not depend on inspecting the selected implementation. Method
occurrences use the interface's declared forcing contract, shared with its value
type under one instantiation. Both supplied bodies and defaults must satisfy it.

Do not silently specialize the signature to whichever row or type the body
happened to choose. For recursive
groups, provisional recursive instances and rigid body-checking instances are
distinct; group publication waits for all required checks and scope escapes.

The same judgment checks ordinary functions, supplied methods, default bodies,
returned closures, stored callbacks and indexed constructors. A spelling-based
exception or a post-hoc scan of only the outer arrows cannot substitute for it.

## 6. Polymorphism: effect variables, generalization, and effect-poly data

**Effect-variable generalization (the HM rule for effects).**
`gen(Γ, τ, φ)` quantifies the type *and* effect variables free in `(τ, φ)` but not
free in `Γ`:

```
gen(Γ, τ, φ_force) = ∀ᾱμ̄κ̄. C ⇒ (τ ! φ_force)
  -- quantify eligible type, row and authority variables of (τ, φ_force, C)
  -- that are not free in Γ; preserve C with the same binders
```

so a higher-order function gets an **effect-polymorphic** scheme. The canonical
example:

```
map : (a →^e b) → List a →^e List b              -- one effect var e on the callback AND the result
```

The callback's latent row `e` is *the same variable* as `map`'s own latent row:
applying `map` to a pure function instantiates `e := ⟨ ⟩` (the whole call is pure);
applying it to an `<IO>` function instantiates `e := <IO>` (the call performs
`<IO>`). This is effect parametricity — the engine of `do`-notation, `fold`,
`andThen`, and every stdlib combinator threading caller effects through.

**The value restriction.** Naïvely generalizing an effect variable that escapes
into a mutable/aliased position is unsound (the classic ML let-generalization
hazard, transposed to effects). The spec requires generalizing effect variables
only at **syntactic values** so a generalized `μ` cannot be captured at two incompatible
instantiations. This is the effect analogue of the type-system value restriction
and is what keeps `gen` + open-row unification sound together. Variance-sensitive
subsumption is not equivalent to the value restriction and does not replace it.
Binding generalization includes the free variables of its forcing row and value
type together; restricted variables in either are lowered to the enclosing level.

**Interface methods use the same universal-declaration rule (§5.1).** Substitute
the instance head first, then check the supplied or default body with every
remaining quantified type, row and authority variable rigid. Instance-head
parameters are not interchangeable with independent method variables. Checking
must respect every type position, including callbacks in tuples, fields and
indices, rather than inspecting only a method's outer arrow spine.

Return-only row variables are not wildcards. A method `quiet : a →^e Unit`
can be implemented purely for every `e`; it cannot choose `e := Stdout`.
Likewise a method may accept and ignore an effectful callback while remaining
pure. If it actually calls the callback, its immediate row must cover that
callback's row. Signature shape alone neither proves nor disproves that body
judgment. Dictionary selection never chooses or refines the caller's effect.

Earlier revisions imposed return-variable argument occurrence, argument-row
coverage, per-arrow intrinsic-atom checks, and post-unification absorption checks
as separate semantic restrictions. Their counterexamples are important
regressions, but the target is the single scoped checking judgment, not that
collection of implementation guards. For example:

- `(Unit →^e Unit) → Unit` admits an implementation that ignores its argument,
  but rejects one that invokes it.
- `(Unit →^{Stdout ⊔ e} Unit) →^e Unit` cannot invoke its callback without
  also declaring `Stdout`; ignoring it is sound.
- `a → b` cannot be implemented by returning a concrete function, tuple,
  or integer for caller-chosen `b`.
- Returning a closure delays its effect onto that closure's arrow; it does not
  remove the obligation. Fewer clause patterns do not weaken the judgment.

This supersedes the shape-only restrictions as *target semantics*. Existing
guards must not be removed from the implementation until the shared checker
covers their complete input populations; passing a partial migration does not
establish conformance.

The deferred-container rule remains unchanged: an independent callback row cannot
be identified with an instance-head row. A graded signature must express their
join in its result index. Supporting `Async` through that general signature is
the remedy, not a privileged exemption for one datatype or method family.

**Effect-polymorphic data.** An effect row can occupy an explicitly
`Effect`-kinded type-constructor argument:

```
data Async (e : Effect) a = Done a | Suspend (Unit →^e Async e a)
liftIO   : (Unit →^e a) → Async e a
runAsync : Async e a →^e a
```

Construction stores a computation; elimination runs it. These are different
effect events. The index describes the stored computation, not the effects
already performed while constructing its container.

### 6.1 Kinds

```
Kind    ::= Type | Effect | Authority Label | Kind → Kind | (Kind)
TyParam ::= name | (name : Kind)
```

Kind arrows associate right. `Effect` classifies rows; `Authority Label`
classifies a parameter in that label's declared domain, not a row. The label
must declare a domain: an atomic label, `IO` included, has no authorities, so
`Authority` over one is ill-formed. Compatible domain aliases give compatible
authority kinds.

### 6.2 Declaration sites

Kind annotations bind parameters on `data`, `newtype`, type-alias and
`interface` heads. Impl heads and `requires` clauses apply constructors;
their kinds follow from those constructors and the interface declaration.
Signature variables likewise obtain kinds from their uses.

### 6.3 Partial annotations

A declaration can annotate only the parameters that need it. Unannotated
parameters may infer `Type` and arrow structure containing only `Type`;
any occurrence of `Effect` or `Authority` in a declaration parameter's kind
must be explicit. Thus `data Wrap f a = W (f a)` can infer
`f : Type → Type`, but `data Later e a = Wait (Unit →^e a)` needs
`(e : Effect)`. Adding an unrelated method cannot change a declared kind.

### 6.4 Kind consistency and indices

Every use must agree with its resolved kind. A `Type` parameter cannot appear
as an effect tail; a row or authority cannot be substituted for an ordinary
value type. A declared but unused `Effect` parameter is legal: a phantom index
does not itself store or discharge a computation.

Effect and authority index slots are invariant. `F φ₁ a` and `F φ₂ a`
require equal indices, not merely `φ₁ ≤ φ₂`; a flexible index variable
takes the other side as its solution outright, as a substitution. An impl head
abstracts over an authority index — `impl I (Handle p)` covers every index,
since an instance is chosen by the type's head and the index is erased — so a
written term in an impl head's `Authority` slot is refused. This remains true when ordinary
type parameters have inferred variance. For example, covariantly widening the
index of `Sink e = Sink ((Unit →^e Unit) → Int)` would manufacture a pure
consumer of an effectful callback.

A phantom authority index can be meaningful for an abstract handle, but its
introduction must satisfy §4.1. An unused parameter on a transparent alias
provides no authority evidence; alias expansion does not invent a qualifier.

### 6.5 Requires chains

An interface's actual constructor argument must have the kind required by each
superinterface. A constructor of kind `Effect → Type → Type` cannot satisfy a
parameter of kind `Type → Type`. Imports preserve declared kinds, including
when an abstract export hides constructors.

### 6.6 Immediate and deferred composition

The plain and `Deferred*` interface families are peers. Plain composition runs
callbacks now and charges their rows on its arrows. Deferred composition stores
callbacks and records their rows in the result index. Its general contracts are:

```
deferMap  : (a →^e₂ b) → f e a → f (e ⊔ e₂) b
deferPure : ∀e. a → f e a
deferAp   : f e (a → b) → f e₂ a → f (e ⊔ e₂) b
deferThen : f e a → (a →^e₂ f e₃ b) → f (e ⊔ e₂ ⊔ e₃) b
```

The `DeferredMappable`, `DeferredApplicative`, `DeferredThenable`
hierarchy mirrors the plain hierarchy, with distinct `defer*` method names.
A `defer` block uses that family; `do` uses the plain family. Neither changes
instance selection according to a grade. A single shared grade is a restricted
instance of these contracts, not a license to identify independent caller rows.

`deferPure` introduces a fresh computation at any caller-chosen upper bound;
it performs and stores no effects. Choosing the empty grade is its least instance.
This is not a coercion from an existing `f ⟨⟩ a` to `f e a`: abstract indices
remain invariant. It permits a helper such as `deferWhen` to select between an
existing `f e Unit` and a freshly constructed `deferPure ()` at that same grade.
The implementation must satisfy this contract for every `e`, including empty.

In a qualified signature, the resolved interface declaration determines the
kind of each constrained constructor parameter. For example,
`DeferredApplicative m => Bool → m e Unit → m e Unit` quantifies `e` as an
effect row, not an ordinary type. These kinds are local to that signature;
an unrelated variable also spelled `m` inherits nothing.

Even an eager constructor arm must suspend its callback to implement the pure
deferred contract: `deferMap g (Done a)` constructs a suspended application,
not `Done (g a)`. An explicitly effectful eager API would need a different
arrow contract.

### 6.7 Deferred elimination

Every elimination that runs a stored computation charges its row at the point
of execution. Returning a stored thunk or inspecting a constructor does not run
it; applying it does. A result-index occurrence is not a charge on an arrow.
Thus `runAsync : Async e a →^e a` is honest, while an implementation that runs
the suspended arm under `Async e a → a` violates the universal body judgment.

The rule applies equally to ordinary functions, supplied methods and defaults.
It is a consequence of the shared checking judgment, not an interface-specific
shape exception.

### 6.8 Joins and recursive inference

A grade join is associative, commutative and idempotent, with empty-row identity.
Sequencing joins effects without equating its operands. Independent callback
variables remain independent. Checking a symbolic join must not choose an
arbitrary decomposition or identify universal members to make a constraint fit.

Produced alternatives also have a type join: this is distinct from joining the
effects incurred while producing them. With equal parameter types, alternatives
`a -> <p> b` and `a -> <q> c` produce
`a -> <p | q> join(b, c)`. Merely selecting either closure does not incur its
latent row. The same rule applies to `if`, match arms and multiple source clauses.
Declared covariant data parameters admit recursive value joins; contravariant,
invariant and unknown parameters require equality. Effect-kind indices remain
invariant. A checker that cannot establish a join must report a type error, not
erase an effect or assume unknown variance is covariant.

List and array literals join their element values before construction. Cons
joins its head value with the existing list's element type. Joining already
constructed mutable containers is different: `Array` and `Ref` remain invariant,
so a pure callback container cannot be widened to an effectful callback container
through branch selection. Any unknown alternative inferred to be a callback keeps
its own latent variable; another branch's closed row is not evidence that the
unknown callback is pure. Ordinary infinite-type rejection still applies.

Equality of invariant slots can solve their still-flexible inference variables.
For example, separate `Ref` constructor instances in one binding group may infer
one common callback allowance. This is not covariance of `Ref`: once either
element row is fixed, equality must preserve it. A singleton constructor
application with a pure callback must publish a pure element row, not an extra
open tail. If an inference allowance belongs to an enclosing binding, its bounds
and ownership transfer together and it is solved at that enclosing boundary.

Captured effects and an inference allowance are distinct: capture records what
a body performs; a shared clause or recursive inference variable can accumulate
lower bounds until its group is solved. The first pure clause cannot close that
variable before later clauses contribute. In particular a recursive equation
`φ = Audit ⊔ φ` retains `Audit`; equality unification must not discard the
concrete prefix. Recursive forcing and invocation summaries take the least
solution of their body equations before publication, independent of traversal
order. Intermediate arrows introduced by currying are pure; the final arrow
carries the body's summary. Constructing a closure does not invoke its body.

Recursive use assumes an allowance; it is not a new producer of effects. The
inferred published value must fit that allowance. A returned recursive value
contributes its assumed row to the actual result equation, where least solving
resolves the cycle. A caller's input row remains symbolic during this process.
If an inferred input allowance has lower bound `Audit`, its principal solution
may still contain other effects (`Audit | e`); exact effect-index equality does
not introduce such residual freedom. Unproved constraints must fail even when
their variables also occur in a recursive result.

Composition follows the same rule as ordinary application. If `f : a -> <p> b`
and `g : b -> <q> c`, then `f >> g` (equivalently `g << f`) has type
`a -> <p | q> c`. Constructing that closure does not perform `p` or `q`; invoking
it performs both. Pipe application performs the selected function's row now.
These constructs cannot introduce an unrelated result effect variable.

An inference allowance is not an effect variable supplied by a caller. It cannot
be performed, generalized, or published as an extra open tail. Compatibility is
a directed relation between rows, not an extra effect added to either row.
Ordinary callback variables remain in the least solution when their callbacks
are invoked; callbacks merely stored or returned contribute no invocation effect.

An inferred row occurring in a returned value is not thereby a declaration
universal. For example, applying `store : (Unit -> <e> Unit) -> Box e` to an
`Audit` callback constrains the returned index to include `Audit`. All arguments
at that occurrence constrain the same fresh instance; two callbacks with
different effects contribute their join, independent of argument order. A pure
lower bound alone does not fix an otherwise unconstrained row. Actual declaration
universals remain rigid throughout these judgments.

A signed binding has separate inferred and declared roles: its body summary
must fit the declared contract, while recursive uses and exported uses see that
contract. A pure implementation of a declared `<Audit>` operation therefore
still exposes `<Audit>`. Nested binding groups may retain a monomorphic
dependency on an enclosing group's summary, but that summary cannot escape its
own inference scope unsolved.

### 6.9 Dictionary orthogonality

Type, row and authority variables share a scheme's instantiation but have
different solving rules. Dictionary selection depends on interface/type
evidence, not effect parameters. Neither a selected implementation nor the
runtime dispatch route may refine the caller's declared effect contract.

Historical design alternatives and dated implementation observations are in
[the design history](archive/EFFECTS-DESIGN-HISTORY.md); they are not additional
semantic restrictions.

## 7. The capability semantics: effects as a verified manifest

This is the operational *point* of the discipline. Effects have **no runtime
behavior of their own** — they are erased before evaluation (§8). What they
produce is a **capability manifest**, and the *meaning* of an effect is fixed by
who reads that manifest.

**Every label is a host capability.** There is no internal/purity-tracking label
class — a label is a host-granted authority; the platform supplies the primitive
that performs it; **parameterizable** (carries a domain); **emitted to the
manifest**. Examples: `Net, FileRead, FileWrite, Env, Exec, Stdout, Stderr,
Stdin, Clock, Rand`, and every user `effect Foo`. (An earlier design carved out
an "internal" class — `Mut` for mutable state, `Panic` for divergence — with no
host meaning and no manifest entry. That class was removed 2026-07-14: mutation
is now untracked and `panic` is an ordinary control-flow primitive, not an
effect label. See [`MUT-SCOPING-DESIGN.md`](../design/MUT-SCOPING-DESIGN.md) for
the history.)

**`IO` as a widening alias.** `IO` is not a primitive label but the **join of the
security labels at `⊤`** (`Stdout ⊔ Stderr ⊔ … ⊔ Net⊤`). An inferred narrow row is
`≤ <IO>`, so any `<IO>` annotation still typechecks (it widens), while inference
yields tight narrow rows for the manifest. `FFI` ([#2071](https://github.com/MedakaLang/medaka/issues/2071))
is deliberately EXCLUDED from this join by design — `<IO>` does not subsume
`<FFI>` — because FFI crosses a trust boundary the IO alias is not meant to
paper over; see [`CAPABILITY-PLATFORM.md`](../design/CAPABILITY-PLATFORM.md) §8
and [`KNOWN-GAPS.md`](../KNOWN-GAPS.md) for why that boundary matters.

**Manifest extraction.** The capability manifest of a module is

```
M(module) = verified-row of the module's entry point(s)
```

— the verified forcing row of the entry binding, joined with the effects incurred
by the host's declared invocation protocol (calling a function or running an
effect-indexed entry computation), unfiltered,
with each label's verified parameter rendered (`drender`). For
`Net "idp.example.com/*"` the manifest records `idp.example.com/*` as the sole
permitted outbound authority. A `Net` authority names an endpoint the program
may dial or bind; a socket accepted through a bound endpoint is exercised at
that endpoint's authority, and waiting for a descriptor to become ready is a
timed wait (`Clock`), not an operation on an endpoint.

Unresolved symbolic authority at a host boundary is conservatively top in its
domain, or an explicit unresolved-manifest error. It must never be omitted or
rendered as empty authority. A forcing effect cannot disappear merely because
the entry's value type is `Unit` rather than an arrow.

**The host is the handler.** Medaka has no in-language effect handler. Instead the
**runtime platform** is the handler: it reads `M(module)` *before loading* the
module and **grants or denies** the actual capability at the module boundary — a
plugin whose manifest says `<Net "idp.example.com/*">` is given a network endpoint
restricted to that host and *nothing else*. `main` itself carries **no upper-bound
gate** inside the language (it may declare any row, or none): `main` is the **grant
root**, and the host — not the type system — decides which of its requested
authorities to honor. The policy check `inferred ≤ policy` (does this module stay
within an allowed capability set?) is *manifest verification*, performed by the
toolchain/host against `M`, not a typing rule.

**Capability soundness (no-exfiltration).** Combining §4 and §5: if a module
type-checks with manifest `M`, then for every label `L`, every authority
it can exercise at `L` is `⊑ M(L)`. In particular a parameterized bound confines
*which* hosts/paths/resources, not merely *whether* the label is used — and the
α ⊤-fallback guarantees runtime-chosen targets cannot escape the bound. This is the
theorem the whole apparatus exists to deliver.

---

## 8. Erasure and the single-meaning law

Effect rows and their parameters are **compile-time only**. After type-checking
(escape + laundering verified, manifest extracted), the row is **erased**; it
contributes nothing to the runtime representation, the evaluator, or the emitted
code. Therefore:

- **Single-meaning law.** *The value a program computes is independent of its
  effect annotations.* Adding, tightening, or removing a (still-well-typed)
  annotation cannot change the result — only whether the program is *accepted* and
  what manifest it carries. Any two backends (interpreter, native emitter) agree
  on every well-typed program, because effects are erased identically before either
  runs. (This is the effect analogue of the dictionary spec's single-evaluator law;
  here the content is *erasure*, not dispatch.)
- **Zero runtime cost.** Parameters never become runtime data; only the *verified*
  parameter reaches the static manifest. The security guarantee is paid for entirely
  at compile time.

A corollary worth stating because it is easy to violate: a primitive's effect must
be a faithful upper bound of what it *actually does* at runtime. Erasure means the
type system is the *only* place the authority is checked — so the externs' declared
rows are part of the trusted base. A mis-annotated extern
(claiming a narrower row than it performs) is a soundness bug the spec cannot catch;
the extern catalog is trusted, like any FFI boundary.

---

## 9. Soundness statements (targets for a later proof/audit)

- **Effect preservation (subject reduction).** If `Γ ⊢ e : τ ! φ` and `e ⟶ e'`,
  then `Γ ⊢ e' : τ ! φ'` with `φ' ≤ φ`. Reduction never *introduces* an effect the
  type did not already permit; the row is an upper bound preserved under evaluation.
- **Effect progress / containment.** A running program performs, at each step, only
  atoms within its whole-program row. No reachable primitive performs an
  unaccounted-for label.
- **α-soundness.** For every parameterized primitive application, the runtime
  authority of the determining argument is admitted by the recorded parameter:
  `⟦e_k⟧ ∈ γ(α(e_k))`. (Over-approximation; §4.)
- **Capability confinement.** If a module type-checks with manifest `M`, every
  authority it exercises at a label `L` is `⊑ M(L)` (§7). With a host that
  honors `M`, the module cannot act outside its declared capabilities.
- **Index fidelity (effect-indexed data).** For a constructor of kind
  `Effect → Type → Type`, the index is part of the type and is checked as such:
  `F φ₁ τ̄` and `F φ₂ τ̄` are interchangeable only when `φ₁ = φ₂`. **The index is
  invariant**, not sub-effected — no direction of `≤` (§2.4) is licensed at this
  slot. Without this the index carries no guarantee at all, and every statement
  below that mentions a registered effect is vacuous.

- **Deferred discharge.** Every elimination form of an effect-indexed type that
  *runs* a registered computation charges that computation's index on its own
  latent row (§6.7). Together with index fidelity this is what makes "registered
  now, produced later" a conservation law rather than a convention: an effect
  corked into an index is uncorked into a row, never dropped. The same universal
  body judgment applies to ordinary functions and interface methods.
- **Principality.** Inference computes the `≤`-least row for every term (§3); the
  manifest is therefore the *tightest* sound description, not a conservative blanket.
- **Coherence with erasure.** Under §8, the denotation is independent of the row;
  well-typedness and the manifest are the only observable consequences of the
  effect system.

---

## 10. How to read the conformance gaps against this spec

Not the audit (separate document), but the lens. Each anticipated shortfall maps to
a clause:

- **Parameter domain coverage** → §2.1: the spec defines the `Unit/Prefix/Set/
  Product` family; an implementation realizing only `Unit + Prefix` is *domain-
  incomplete*, inexpressive but not unsound. Suspect any `<L {…}>`/structured-param
  surface that fails to parse.
- **α precision** → §4: an abstraction weaker than the idealized table
  (missing let/`if`/`match` propagation, no interprocedural recovery) is sound but
  *over-rejects*. Suspect a pinned-bound program refused where the spec's α would
  accept (a `let`-bound or branch-joined literal authority collapsing to `⊤`).
- **Manifest realization** → §7: the verified row is the deliverable; if no
  toolchain path extracts/emits/verifies `M` on the canonical binary, the headline
  capability feature is unreachable even though the *typing* is sound. Suspect a
  policy/manifest command stranded on a non-canonical tool, or one checking labels
  but not parameters.
- **Effect-poly / data-effect threading** → §6: the `<e>` on combinators and the
  `Effect`-kinded data parameter must generalize and instantiate as HM-for-effects.
  Suspect a combinator that fixes a concrete label where the spec demands a variable.
- **Declared kinds** → §6.1–§6.5: a parameter's kind is *written* on the head, and
  only the `Type`-versus-arrow structure is still inferred (§6.3). An
  implementation that infers `Effect`-kindedness from a field's effect tail, or
  from slot co-occurrence in a method signature, is running the retired rule of
  §6.8 — suspect a declaration whose kind changes when an unrelated method is added
  or removed, and a parameter that is an effect index one level down being inferred
  `Type`.
- **Index fidelity and deferred discharge** → §6.7, §9: the `Effect`-kinded
  argument slot must be checked at unification like any other, and an eliminator
  that runs a registered computation must charge its index. Suspect a value of
  `F <IO> τ` accepted where `F ⟨ ⟩ τ` is demanded — the *value* slot being checked
  is not evidence that the index slot is, and an ordinary type accepted in the
  index slot (`F Int τ` read as `F ⟨ ⟩ τ`) is the same gap seen from the other
  side. Agreement between engines does not establish this property: both can
  execute the same incorrectly accepted program.
- **Erasure / backend agreement** → §8: any divergence in result (not just
  acceptance) between evaluators traceable to effects violates the single-meaning law.
- **`main` policy** → §7: a *language-internal* upper-bound gate on `main` would be a
  spec deviation in the *opposite* direction — `main` is the grant root; bounding is
  the host's job, not the type system's.

---

## 11. Implementation conformance

The [2026-07-30 enforcement census](archive/EFFECTS-ENFORCEMENT-2026-07-30.md)
is historical, not an up-to-date map of the checker. It described the previous
shape guards and string-hole model; it does not establish the universal
checking and named-authority contract above.

The active migration and its explicit completed/remaining work are recorded in
[Effects within the typechecker](../../compiler/EFFECTS-ARCHITECTURE.md).
The named-authority checkpoint there implements §4.1's named arrows, qualified
values, resolved label identity, the abstraction `α`, the scoped authority
solver and publication as far as a binding's own scope: a residual obligation
over a variable no scope owns is decided over the module, not carried in a
generalized scheme, so "residual constraints travel with a generalized scheme"
is not implemented. Qualified data fields, constructor proof sources,
carrying and authority-indexed existentials are implemented (the data-half
and close-out checkpoints there). No conformance claim may turn a pending proof into success or
describe the whole effects system as laundering-free while a known channel
remains. Issue status belongs in the issue tracker; the archived observations
explain counterexamples but are not a live backlog.

---

## References

- D. K. Gifford, J. M. Lucassen. *Integrating Functional and Imperative
  Programming.* LFP 1986. / J. M. Lucassen, D. K. Gifford. *Polymorphic Effect
  Systems.* POPL 1988. (Effects as a third judgment component; effect variables.)
- J.-P. Talpin, P. Jouvelot. *The Type and Effect Discipline.* Information and
  Computation, 1994. (Effect inference, generalization, the value restriction.)
- D. Leijen. *Koka: Programming with Row-Polymorphic Effect Types.* MSFP 2014.
  (Row-polymorphic effects; the `<labels ∣ μ>` row and its unification.)
- J. I. Brachthäuser, P. Schuster, K. Ostermann. *Effects as Capabilities.* OOPSLA
  2020. (Effects as the requirement of an ambient capability; the boundary as grantor.)
- M. S. Miller. *Robust Composition* (object-capability model). (Authority as
  unforgeable, confined at boundaries — the "host is the handler" stance.)
- P. Cousot, R. Cousot. *Abstract Interpretation.* POPL 1977. (The α/γ Galois
  connection; sound over-approximation — the discipline §4's parameter analysis obeys.)
- S. Katsumata. *Parametric Effect Monads and Semantics of Effect Systems.* POPL
  2014. (Graded monads — monads indexed by an ordered monoid of effects; §6's
  graded interfaces instantiate the monoid to the row join.)
- D. Orchard, T. Petricek, A. Mycroft. *The semantic marriage of monads and
  effects.* / Orchard et al., *Granule.* (Grading in practice: index algebras
  tracked through composition, kept out of the term semantics — the erasure
  stance §6's graded interfaces inherit.)
