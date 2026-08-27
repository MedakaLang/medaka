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
  `<l₁,…,lₙ | μ>` is exactly a Koka-style effect row with an optional polymorphic
  tail `μ`.
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
| parameter `"a.com/*"`, `_` | refinement-domain element `p ∈ 𝔻_L` |
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
are evidence routed by label/method identity; effect parameters are **inert data
that rides on the row**, joined at unification and never routed. This document
suppresses the predicate context `P` of the dictionary spec; a full judgment is
`P ∣ Γ ⊢ e ⇝ e' : τ ! φ`, and the effect rules below thread `φ` orthogonally to
the `P ⇝ e'` translation.

---

## 1. Source language (the effectful fragment)

We model what bears on effects. Types now carry effects on every arrow, and
schemes quantify **type and effect variables**:

```
p   ::= ⊤_𝔻 | … domain-specific elements …      -- parameter from a domain 𝔻 (§2)
a   ::= L · p                                    -- atom: label L refined by param p
φ   ::= ⟨ a₁ … aₙ ∣ μ? ⟩                         -- effect row: atom set + optional tail var μ
τ   ::= α | T τ̄ | τ₁ →^φ τ₂ | (τ̄)               -- monotypes; arrow carries a latent effect φ
                                                -- T τ̄ may include an effect-row argument (§6)
ρ   ::= τ                                        -- (qualifiers from DICT-SEMANTICS suppressed)
σ   ::= ∀ᾱ. ∀μ̄. ρ                               -- scheme: quantifies TYPE and EFFECT vars
```

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

Closed rows are what a *user annotation* denotes; **inference synthesizes open
rows** so the subsumption discipline (§5) survives equality unification.

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
p₁ ⊑ p₂   iff   p₂ = ⊤,  or  p₂ is a pattern and p₁'s concrete part STARTS WITH p₂'s concrete part
```

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
⟨ ā₁ ∣ μ₁ ⟩ ≤ ⟨ ā₂ ∣ μ₂ ⟩   iff
    (∀ L·p₁ ∈ ā₁.  ∃ L·p₂ ∈ ā₂.  p₁ ⊑_{𝔻_L} p₂)     -- every atom is covered, more specific ⊑ more general
  ∧ (μ₁ present ⇒ μ₂ present)                         -- a closed row ≤ an open row; not conversely
```

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
            x : ∀ᾱμ̄. τ ∈ Γ        S = [τ̄/ᾱ, φ̄/μ̄]  (instantiation; §6 reopening)
(var)   ─────────────────────────────────────────────
            Γ ⊢ x : S(τ) ! ⟨ ⟩                       -- a variable use performs nothing

            Γ ⊢ e₁ : τ₂ →^φ₀ τ ! φ₁        Γ ⊢ e₂ : τ₂ ! φ₂
(app)   ──────────────────────────────────────────────────────
            Γ ⊢ e₁ e₂ : τ ! φ₁ ⊔ φ₂ ⊔ φ₀              -- evaluate fn, evaluate arg, THEN perform latent φ₀

            Γ, x:τ₁ ⊢ e : τ₂ ! φ₀
(lam)   ──────────────────────────────────────
            Γ ⊢ (λx. e) : τ₁ →^φ₀ τ₂ ! ⟨ ⟩           -- building a closure is pure; body effect is LATENT

            Γ ⊢ e₁ : τ₁ ! φ₁     Γ, x:gen(Γ, τ₁, φ₁) ⊢ e₂ : τ₂ ! φ₂
(let)   ────────────────────────────────────────────────────────────
            Γ ⊢ (let x = e₁ in e₂) : τ₂ ! φ₁ ⊔ φ₂

            Γ ⊢ e : τ ! φ        φ ≤ φ'
(sub)   ─────────────────────────────────                -- subsumption: weaken to a larger row
            Γ ⊢ e : τ ! φ'
```

with two rules that *introduce* concrete effects:

```
            (prim p : τ̄ →^⟨ L·● ∣ ρ ⟩ τ) ∈ LE      Γ ⊢ ēᵢ : τ̄ᵢ ! φ̄ᵢ
            π = α_{𝔻_L}(e_k)                         -- the determining argument's abstraction (§4)
(prim)  ───────────────────────────────────────────────────────────────
            Γ ⊢ p ē : τ ! (⊔ᵢ φ̄ᵢ) ⊔ ⟨ L·π ⟩

            (op : … <e> … ) a class/interface method whose signature carries an effect var
(method)    — the effect var is instantiated like any μ̄ by (var); the method's
              latent row is whatever the dispatched impl performs, bounded by the signature.
```

Reading:

- **`var`/`lam`** are the classic effect-discipline shape: *mentioning* a function
  is pure; the latent row lives on its arrow and is released only by **`app`**,
  which **unions** the function-expression's, argument's, and latent effects. This
  is what makes effects flow through ordinary application without explicit
  threading.
- **`prim`** is the **only rule that mints a parameterized atom.** A parameterized
  primitive's signature has a *hole* `L·●` at a parameter position; the atom's
  parameter is computed by abstracting the **determining argument** `e_k` (the URL,
  the path) via `α` (§4). A non-parameterized primitive is the special case
  `𝔻_L = Unit`, `π = ()`. (A primitive with a *fixed* annotation `L·c` instead of a
  hole emits exactly `L·c` regardless of arguments — the hole is what invokes α.)
- **`let`/`gen`** generalizes; §6 gives the generalization rule for effect
  variables and its value-restriction side condition.
- **`sub`** is the only place the row *grows* without a cause — it is how an
  annotated bound is satisfied by a more specific inferred row, and how the two
  branches of an `if` are reconciled (each subsumed to their join).

**Principal effects.** Inference is intended to compute, for every `e`, the
*least* row under `≤` (equivalently: the join of exactly the atoms `e` can
actually perform, with the most specific parameters `α` can justify). `var`/`lam`
contribute nothing; `app`/`let` join; `prim` adds the single determined atom; `sub`
is applied only where a bound forces it. The least-row property is what makes the
inferred row a *tight* manifest rather than a conservative blanket.

---

## 4. Parameter creation: the abstraction α

The parameter on a `prim`-introduced atom is `α(e_k)`, where `α : Expr → 𝔻` is a
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
| `e₁ ++ e₂` (concatenation) | if `α(e₁)` is a known prefix `p`, then `p` (a fixed left prefix bounds the whole, regardless of `e₂`); else `⊤` |
| string interpolation `"s\{e}…"` | the `++`-chain rule: the leading literal `s` is the known prefix; the first interpolated expression stops it |
| `let x = e₁ in …x…` | propagate `α(e₁)` to uses of `x` |
| `if c then e₁ else e₂` | `α(e₁) ⊔ α(e₂)` (join of branch authorities) |
| `match … { … ⇒ eᵢ }` | `⊔ᵢ α(eᵢ)` (join over arms) |
| application result `f ē`, a free/parameter variable, field access, anything else | `⊤` |

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
- **Interprocedural / value-singleton** (the ideal ceiling): authority recovered
  across calls by propagating singleton/refinement information on values. Strictly
  more precise; needs value-level singleton typing — a real escalation. The spec
  *permits* it; no soundness rests on it.

Because both are sound, the choice of α-precision is an engineering dial, **not** a
correctness question. The audit measures the implemented α against the idealized
table; every shortfall is a *completeness* (over-rejection) gap, never a soundness
hole.

---

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
Mechanically this is **unification of an inferred *open* row against a declared
*closed* row**: the open side may carry no atom the closed side lacks. The
covariant-position **re-open** discipline — an instantiated closed-with-atoms row
reopens to `⟨ ā ∣ ρ ⟩` only at *value-producing* positions — is what lets equality
unification still enforce the *subset* (≤) direction rather than collapsing it to
equality. (This is the standard subtyping-via-row-polymorphism encoding.)

**No-laundering law.** *Every elimination of an effectful value flows its row into
the ambient effect; no construct discards or downgrades a row except by `sub` to a
larger one.* A consequence: the effect of a whole program is `≥` the join of every
primitive it can reach — there is no syntactic hiding place.

**Decidability.** The two checks reduce to deciding `≤`, which reduces to deciding
each `⊑_{𝔻_L}`. The spec's domains keep `⊑` decidable: `Unit` trivial; `Prefix`
trailing-`*`/delimiter-terminated (no general globs); `Set` finite `⊆`; `Product`
pointwise. Banning general globs/regex is a *decidability* requirement, not a taste.

---

## 6. Polymorphism: effect variables, generalization, and effect-poly data

**Effect-variable generalization (the HM rule for effects).**
`gen(Γ, τ, φ)` quantifies the type *and* effect variables free in `(τ, φ)` but not
free in `Γ`:

```
gen(Γ, τ, φ) = ∀(ᾱ = ftv(τ,φ)\ftv(Γ)). ∀(μ̄ = fev(τ,φ)\fev(Γ)). τ
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
only at **syntactic values** (or, equivalently, only re-opening rows at covariant
positions per §5) so a generalized `μ` cannot be captured at two incompatible
instantiations. This is the effect analogue of the type-system value restriction
and is what keeps `gen` + open-row unification sound together.

**Well-formedness of interface-method effect variables (the no-laundering side
condition).** A quantified effect variable that occurs in an interface method's
**return-position** row must **also** occur in an **argument** position of that
method's signature — either as a callback's latent arrow effect (`(a →^e b)`) or as
an `Effect`-kinded type-constructor argument (`Async e a`, §"effect-polymorphic data"
below). An effect variable that appears **only** in the return row, determined by no
argument, is **ill-formed** (an ambiguous / under-determined quantified variable, the
effect analogue of a class method whose return type mentions a type variable pinned
by nothing). It is rejected at the interface declaration.

The reason is soundness, not taste. If `speak : a →^e String` quantifies `e` with
nothing to pin it, a caller instantiates `e := ⟨ ⟩` at the use site and obtains a
value the effect system certifies **pure** — yet the *dispatched* impl of `speak`
may perform `<Stdout>`, selected by the dictionary at the call site, invisibly to
the caller's effect. The effect would be **laundered** away (§5's no-laundering law
violated with no error). Argument-carried polymorphism (`map`, `andThen`, `fold`,
`traverse`) at least *gives the caller a handle on* `e`: it appears in an argument
(a callback's effect row, or an `Effect`-kinded constructor parameter), so the instantiated
`e` is visible in the call's type rather than materialising out of nowhere. This
well-formedness condition is what makes the *generalization* of a method effect
variable meaningful in the presence of dictionary dispatch — and it is decided
**without** consulting the dictionary (it is a purely syntactic property of the
*declared* signature), so it preserves the dictionary/effect orthogonality restated
below: the alternative of lower-bounding a return-only effect var by the *dispatched*
impl's latent effect was rejected because it would make the effect depend on
dispatch, violating that orthogonality.

**The dual condition: argument-occurrence coverage (ENFORCED).** Option A constrains
where a *return*-row variable must also appear; its dual constrains what an
*argument*-position occurrence may carry. An effect variable's argument occurrences
(a callback's row, an `Effect`-kinded argument) are rows an impl can **perform** by using
that argument — so the method's own rows must account for them, at declaration:

- **argument-only** — `use : a → (Unit →^e Unit) → Int`, where `e` appears in *no*
  non-argument row: an impl applying the callback performs `e` with no row charging
  it (a pure-typed wrapper silently prints; verified). Ill-formed.
- **uncovered atoms** — `act1 : a → (Unit →^{Stdout ⊔ e} Unit) →^e Unit`: the
  callback's concrete `Stdout` pours into a row declared bare `⟨e⟩`, which a caller
  instantiates to `⟨ ⟩` (verified launder). Ill-formed unless **every** non-argument
  occurrence of `e` covers (IO-expanded) the union of `e`'s argument-side atoms —
  `⟨Stdout ⊔ e⟩` at both callback and return is fine, as is an `⟨IO ⊔ e⟩` return.

Like Option A this is decided from the declared signature alone (dispatch never
consulted). It must live at the declaration: once unification runs, the same-tail
row arm (`⟨e⟩ ∼ ⟨Stdout ⊔ e⟩`) succeeds without recording the atom anywhere, so no
post-hoc inspection can recover the loss.

**Scope of Option A, and the impl-body bound that completes it (#803, ENFORCED).**
Option A's side condition is a *necessary* well-formedness rule about the shape of the
**declared signature**; on its own it does **not** bound the **impl body's** latent
effect. A method whose signature *does* carry `e` in an argument can still *attempt* to
launder — and in **two** shapes, not one: an impl may **ignore** the effect argument and
perform its own *intrinsic* effect, **or** it may legitimately **use** the effect
argument (apply the callback, run the `Effect`-kinded data value) *and additionally* perform
an intrinsic effect alongside it. For example `speak : a → (Unit →^e Unit) →^e String`
is well-formed under Option A, yet an impl `speak d k = k (); putStr "…"; "woof"`
performs `<Stdout>` while a caller instantiates `e := ⟨ ⟩` — laundering that *applying*
the callback does not excuse.

This is now **rejected** by a companion rule that bounds the impl **body's own latent
effect** — on **every arrow of the method's declared type, down to its final return** —
by what its arguments and signature justify. Writing `φ_i^{decl}` and `φ_i^{body}` for the
declared and inferred effect on the *i*-th arrow of a method of declared arity *n*:

```
    ∀ i ≤ n.   atoms(φ_i^{body})  ⊆  atoms(φ_i^{decl})  ∪  atoms(argContributable)
```

where **argContributable** is the union of the effect rows an impl may perform by *using*
its arguments — each function-typed argument's arrow latent row, each `Effect`-kinded data
argument's effect row — and `atoms(·)` / the containment are IO-expanded exactly as the
binding-boundary escape check of §5. Any atom of `φ_i^{body}` outside that bound is an
intrinsic effect the caller cannot see, and is **rejected** (`T-EFFECT-LAUNDER`).

**Why every arrow, not just the last.** An impl may write **fewer patterns** than the
method's arity and return a lambda for the rest (`speak d k = u => …`), an ordinary
curried idiom; its intrinsic effect then lands on a **returned-lambda arrow beyond the
impl's pattern count** but still *within* the method's declared arrows. Bounding only the
final arrow — or only the impl's own pattern count — misses exactly that effect (the
smoking gun: `speak d k u = …` and `speak d k = u => …` must be judged identically).

**Why it is exact.** The bound is checked **before** the body's rows are unified into the
declared type, and there every parameter is still a fresh variable — so `argContributable`
is entirely effect *variables* carrying no atoms, and an effect the body performs *through
an argument* (applying a callback, running an effectful data value) appears on its arrow as
that same variable, never a concrete atom. Consequently the per-arrow residual reduces to
*concrete atoms of `φ_i^{body}` minus `φ_i^{decl}`*: a variable is visible to the caller and
cannot lie, so only a concrete atom can launder. This makes the rule sound *and* precise —
not the blanket *"no effect var may carry a concrete effect"* ban that would break
`map`/`traverse`:

- an impl that **threads** the effect (`map`, `traverse`, or any impl — curried or not —
  that *applies* its callback / *runs* its effectful data argument) contributes only that
  argument's **variable** to each `φ_i^{body}` — no atom — so it is **accepted**;
- an impl whose callback carries a **concrete** effect (`Unit →^{Stdout} Unit`) which the
  method's return honestly declares is **arg-contributed and declared**, so it too is
  **accepted** — the reason `argContributable` cannot be dropped from the rule as stated;
- an impl that **honestly declares** its own effect (`<Stdout | e>`) has that atom in the
  matching `φ_i^{decl}`, so it is **accepted**;
- only an **intrinsic** effect — a concrete atom on some arrow justified by neither the
  arguments nor the declared effect at that arrow — **escapes** and is **rejected**,
  whether the impl ignores its effect argument, uses it, or is written point-free/curried.

So an argument-carried effect variable is bounded by the effect that actually *flows from
the method's arguments*: the caller sees `e` in the call's type, and — with this rule —
the instantiation **cannot lie**, because the dispatched impl can perform on that row only
what its arguments justify or its signature declares. Together, Option A (signature shape)
and this impl-body bound close the laundering hole for effect-variable interface methods.
(Was tracked as #803.) They do **not** yet close the *type-variable* channel — an impl can
still smuggle a row inside the instantiation of a quantified **type** variable, off the
arrow spine the bound walks. That channel is closed by method-scheme rigidity, next.

**Method-scheme rigidity (the instantiation channel; #814).** The two rules above
constrain the *signature's shape* and the *declared arrows*. The remaining laundering
channel is the **instantiation of the method's quantified variables themselves**: with the
body checked against the method type via ordinary (flexible) unification, an impl of
`mk : a → b` can pin `b := Unit →^⟨Stdout⟩ String` — or a tuple or data type containing
such an arrow — while every caller instantiates `b` freshly and may pin it to the *pure*
arrow: a certified-pure value performs IO, and no arrow of the declared spine ever carried
an atom for the #803 bound to see. The same flexibility is a **type**-soundness hole with
no effects involved at all (`mk d = 42` pinned `b := Int`; a caller instantiates
`b := String` and evaluation crashes), which is why the fix is not effect-specific.

The rule (the effect reading of `DICT-SEMANTICS.md` §3 **W3**, which owns the formal
statement): an impl or default method body is checked against the method's declared type
with every quantified variable not bound by the interface head — **type variables and
effect variables alike** — held **rigid**. For a type variable, rigid means what it means
in any skolem check: it may not be instantiated to a constructed type, identified with
another method variable, or identified with an instance-head variable. For an effect
variable `μ`, rigid means the row it stands for may acquire **no concrete atom beyond
what the declared row at each of `μ`'s occurrences already carries** (IO-expanded,
exactly as §5's escape check), and two distinct declared effect variables may not be
identified — an atom that reaches `μ` from nowhere in the signature is precisely an
intrinsic effect the caller can erase by instantiating `μ := ⟨ ⟩`.

Consequences, and the division of labour with the #803 bound:

- pinning `b` is rejected *outright* — effectful, pure, nested in tuples or data-type
  arguments, it makes no difference, so the tuple/data-nesting variants need no
  variance-aware descent: there is nothing to descend into once `b` cannot be pinned;
- an intrinsic atom poured into an argument-pinned `e` at a position **off the arrow
  spine** (e.g. a method returning `(Unit →^e Unit, Int)`, the atom inside the tuple) is
  caught by the effect-variable half — the one laundering shape the per-arrow #803 walk
  is structurally blind to;
- the #803 per-arrow bound remains the *diagnostic* seam for spine positions (it names
  the offending arrow pre-unification); in the idealized semantics it is subsumed by
  rigidity — a rigid `μ` on a declared arrow cannot absorb an intrinsic atom.

**Known residual (#817).** One identification is *deliberately admitted*: a method
effect variable unifying with an **instance-head effect parameter** (`impl Mappable
(Async e)`, whose `Suspend` arm stores the callback and thereby forces the method's
`e'` ≈ the head's `e`). It is a real laundering channel — the callback's effect is
charged at *build* time but performed at *force* time, so a pure-typed thunk obtained
through the container performs the deferred effect (verified; tracked as #817) — but
the sound result row `e ⊔ e'` is inexpressible while the instance head fixes the
container's row, so rejecting the identification would outlaw effect-polymorphic
data's shipped functor/monad instances outright. The resolution is design-scoped and
owned by #817 — and now specified: **graded interfaces** (below, and #820) make the
container's index absorb the callback row by signature shape, after which this
exception retires. The type-variable half has **no** such exception (a method type
variable may never alias an instance-head type variable).

Two deliberate design notes. **First**, rigidity is an over-approximation in one corner:
an atom entering a rigid `μ` at a *purely contravariant* occurrence (the impl returns a
function that merely *demands* a more-effectful callback than the caller need supply)
cannot actually be performed, yet is rejected. That is the §4 stance transposed —
over-rejection is a completeness gap, never a soundness hole — and the corner is
unreachable anyway for honestly-shaped signatures. **Second**, the alternative that was
considered and **rejected**: keeping the flexible instantiation and adding a
variance-aware structural walk of the (declared, inferred) type pair that hunts effect
atoms in covariant positions of the pinned types. It would have needed per-datatype
variance machinery the type system does not track, and — decisively — it *presumes the
pinning survives*, which the `b := Int` crash shows is unsound independently of effects.
Rigidity closes both axes with no new machinery, and is the standard obligation of the
dictionary translation besides (an instance method must inhabit the method's scheme at
the instance head — Wadler–Blott; `DICT-SEMANTICS.md` §3 W3).

**Effect-polymorphic data (effects as type-constructor arguments).** A row may
occupy a **type-constructor argument** position, so a data type can be parameterized
*by an effect*:

```
data Async (e : Effect) a = Done a | Suspend (Unit →^e Async e a)
runAsync : Async e a →^e a
```

Here `e` has kind **`Effect`** (distinct from the `Type` kind of `a`), **declared**
on the head per §6.1. (This paragraph said "row-kinded (kind `Row`), *inferred*
from its use in an effect position" until the declared-kinds decision; both the
name and the inference are superseded — see §6.1 and §6.8.) The effect stored in a
`Suspend` thunk *is* `e`; `runAsync` performs exactly the row the value carries —
an obligation §6.7 names and shows to be **unenforced** on the implementation
today. This is how
Medaka expresses an *effectful computation as a first-class value* **without** an
`<Async>` effect label: async-ness rides in the *type* (`Async e a`), exactly as
error-ness rides in `Result e a` — composition is ordinary `do`/monad structure,
not a tracked row label and not a handler. (Decided invariant.)

**Two families, differing in WHEN — the intuition first.** Everything below turns
on one distinction that is easy to miss because *both* families are effectful. The
prelude's plain interfaces already carry effect variables:

```
map     : (a →^e b) → f a →^e f b
andThen : m a → (a →^e m b) →^e m b
```

The effect variable sits on the **method's own arrow**, so the effects are
**produced at the call site, immediately**. That is exactly right for a strict
container (`List`, `Option`, `Result`): `map` really does run the callback now.

The graded family instead records the effect in the **container's index**. Compare
the same shape, deliberately spelled with a *different* method name — the two
families must not share one (§6.9 Q1), so showing them under one name here would
misrepresent the design:

```
gandThen : f e a → (a →^e f e b) → f e b        -- graded-LITE (one shared grade)
```

This is the **graded-lite** degenerate — one variable doing duty as both the
callback's row and the index — chosen here because it makes the *where does the
effect live* contrast legible in one line. The normative family below uses
independent grades joined in result position (`f (e ⊔ e₂) b`); the intuition is the
same and the algebra is #821's.

so effects are **registered now and produced later**. In the project owner's own
words, which convey it better than the formal statement does:

> The deferred one is just constructing a datatype that represents a set of
> effects that will *eventually* be produced but for now are just registered as
> part of the datatype that is being produced.

The picture that goes with it is **corking and uncorking**, and it is literally
realized by `stdlib/async.mdk`'s two boundary functions:

```
liftIO   : (Unit →^e a) → Async e a       -- cork:   arrow effect  ⟶  index
runAsync : Async e a →^e a                -- uncork: index         ⟶  arrow effect
```

Corking moves an effect off the arrow and into the type; uncorking moves it back.
The index is the label on the bottle. `map`/`andThen` on a corked value merge
bottles and union labels — which is *why* the grade monoid is the row join `⊔`
(§2.4): associative, commutative, **idempotent**, unit `⟨ ⟩`. Registering the same
effect twice registers it once, and the order of registration is not observable.

So the two families differ in **WHEN effects happen, not whether**. Neither
subsumes the other (§6.6), and this is the actual root cause of #817 and #825: an
`Async`/parser-shaped impl needs to *register an effect for later*, but the
interface it implements says *produce it now*, so the impl identified the method's
effect variable with the container row and laundered.

**Graded (`Deferred*`) interfaces (effect-indexed constructors; the sound
composition surface for effect-polymorphic data).** Effect-polymorphic data exposes
a gap the plain interface system cannot close. An ordinary functor signature at
`f := Async e`
reads `map : (a →^{e'} b) → Async e a →^{e'} Async e b` — the result carries the
**same** index `e` as the input, yet any implementation of the `Suspend` arm must
store the callback inside the container, so the stored thunk's row is really
`e ⊔ e'`. The impl can only typecheck by privately identifying `e' ≈ e`, which the
caller never sees: `e'` is charged at the *build* site (the `map` application) while
the stored effect fires at the *force* site (`runAsync`), charged only `e`. The
result is the deferred-effect launder tracked as the W3 carve-out (#817) — and it is
not an implementation accident: with `f` fixed to `Async e`, the sound result type
is **inexpressible**. The two candidate patches both fail on principle: propagating
the impl's identification to call sites is dispatch-dependent effect refinement
(violating the orthogonality below, the same reason #784's Option B was rejected),
and widening `runAsync` to a blanket row destroys the precision that makes the
index worth having.

The principled closure is **grading** (Katsumata's parametric effect monads): an
interface over an **effect-indexed constructor** `f : Effect → Type → Type`, whose
method signatures compose indices by the row join, in **result position**. The
family is named `Deferred*` and **mirrors the plain hierarchy exactly, `requires`
chain included** — because the two families are peers (§6.6), not a general and a
special case:

```
interface DeferredMappable (f : Effect → Type → Type) where
  gmap     : (a →^{e₂} b) → f e a → f (e ⊔ e₂) b

interface DeferredApplicative (f : Effect → Type → Type)
  requires DeferredMappable f where
  gpure    : a → f ⟨ ⟩ a
  gap      : f e (a → b) → f e₂ a → f (e ⊔ e₂) b

interface DeferredThenable (f : Effect → Type → Type)
  requires DeferredApplicative f where
  gandThen : f e a → (a →^{e₂} f e₃ b) → f (e ⊔ e₂ ⊔ e₃) b
```

with, **not** as a method,

```
grun     : f e a →^{e} a                    -- per-type eliminator (runAsync)
```

— see §6.7 for why the eliminator cannot be a member of the family and what
obligation replaces it.

⚠️ **The METHOD names above are not decided, and are not even all attested.**
`gandThen`/`gmap`/`grun` are spelled in `test/engine_fixtures/graded_iface_async.mdk`;
`gpure` in `test/typecheck_error_fixtures/graded_closed_row_grade_ok.mdk:22`;
**`gap` is attested nowhere as a graded method name** — it exists only in this
document. (Careful with that one: `compiler/backend/wasm_emit.mdk:9320` defines an
unrelated `gap : String → a`, the W3 scope-wall panic helper. A symbol gate would
therefore *resolve* `gap` and silently vouch for a name no graded fixture uses.)
The
*interface* names `Deferred*` are decided, the `g`-prefix on the methods is
not, and `DeferredMappable.gmap` is at minimum an inconsistent pairing. Open
question, §6.9 (Q1). What *is* settled is that the method names must stay
**distinct from the plain family's**: sharing `map`/`andThen` was investigated and
rejected during the #824 design work — the unqualified `andThen` that `do` desugars
to would have to pick one interface, and picking the graded one breaks the
prelude's own containers. (Reported there as probe-established; not re-verified
here.)

A **grade** is an ordinary effect row used as a type index; grade composition is
the row join `⊔` of §2.4 — associative, commutative, idempotent, with unit `⟨ ⟩` —
so the graded monad laws are the plain monad laws with indices multiplied out (unit
grade `⟨ ⟩`, join associativity). Three consequences, each independently valuable:

- **Soundness with no exception.** The `Suspend` arm's stored thunk types at
  `e ⊔ e₂`, and the declared result index *says so* — the impl inhabits the graded
  scheme at full generality, so W3 (§6 above, DICT-SEMANTICS §3) holds for graded
  impls with **no carve-out**; the #817 exemption retires when the stdlib migrates.
- **Construction is genuinely pure.** The plain signature charges the callback row
  at the build site — an over-approximation in the *other* direction (the effect
  is paid where nothing runs). Graded signatures charge nothing until `grun`, the
  sole discharge point: the accounting finally matches the operational story of a
  deferred computation.
- **Erasure and dispatch are untouched.** A grade is a row: it erases (§8), it
  rides no dictionary, and graded elaboration is the ordinary dictionary
  translation — one instance per constructor *family* (`impl DeferredMappable
  Async`), with no overlap-on-grade dimension. The orthogonality invariant below
  survives verbatim.

**Well-formedness and decidability.** Joins may appear only in result/index
positions of graded method signatures; unification never *decomposes* a join —
instantiation is checked by grade **subsumption** (`e ≤ e₁ ⊔ e₂` per §2.4's order),
the direction the escape check already decides. This is the same discipline that
keeps the parameter domains decidable (§2.3): expressiveness bounded exactly where
decidability demands it. A **degenerate form is the right first destination**
("graded-lite"): all grades in a signature collapsed to one shared variable
(`gandThen : f e a → (a →^e f e b) → f e b`), realizing the join by unification.
Its *semantics* is sound — when the grade is genuinely a row and genuinely shared
across the signature, it rejects the #817 and #825 deferred-effect laundering at
the correct site, the same discipline the full family gives.

**Status correction (this paragraph replaces one that is now out of date).** An
earlier revision said graded-lite "is not admissible today" because interface
parameter kinds did not exist. That was true when written and is **no longer**:
#822 shipped an interface-parameter kind, and the graded-lite signature declares
on the current binary (`interface DThenable f where gandThen : f e a -> (a -> <e>
f e b) -> f e b` → `check` exit 0; probed 2026-07-26). What #822 shipped is a kind
that is **inferred**, which is the very rule §6.8 retires — declaration replaces
it, and the surface above is written against the declared form.

**The eager-arm fork is still open (#823) — but it is no longer speculative, and
what is at stake is not what this document previously said (see #1095).** A prior
revision recorded that no probe was possible; one is now, and it fires. On a binary
built from `main` (2026-07-26) a graded-lite `DeferredThenable`-shaped interface
whose impl **applies** its callback rather than storing it launders the callback's
row, with `check` green:

```
data Later e a = Now a | Wait (Unit -> <e> Later e a)

interface DThenable f where
  gandThen : f e a -> (a -> <e> f e b) -> f e b

impl DThenable Later where
  gandThen (Now a) k = k a                                -- EAGER: performs <e>
  gandThen (Wait t) k = Wait (u => gandThen (t u) k)

step : Int -> <IO> Later <IO> Int
step n =
  let _ = println "BOOM — this ran at BUILD time"
  Now (n + 1)

build : Unit -> Later <IO> Int                            -- NO row on the arrow
build u = gandThen (Now 1) step

main =
  let _ = println "before"
  let v = build ()
  println "after"
```

`check` exit 0; `run` prints `before` / `BOOM — this ran at BUILD time` / `after`,
exit 0.

⚠️ **`build` must actually be applied, and the result must be reached from `main`.**
An earlier revision of this section printed this program with the last four lines
missing — no `main`, and `build` never applied — while asserting the same output.
That version does not run at all (`E-NO-MAIN`), and merely adding a bare `main`
still prints nothing, because a top-level nullary binding is lazy and the
application is never forced. The defect is precisely the one this document exists
to warn about: **a probe that looks like it passed.** It is recorded rather than
quietly corrected.

The mechanism is structural, not a
missing check: a graded signature deliberately carries **no row on the method's
own arrows** — that is the whole point of moving the effect into the index — so an
impl that performs rather than defers has nothing to charge it. The per-arrow
bound of #803 cannot see it either, because applying the callback contributes only
the *variable* `e`, never a concrete atom (the bound's own precision argument,
above, says exactly this). §6.7 states the obligation this exposes.

`stdlib/async.mdk`'s `map`/`pure` still apply the callback
**eagerly**, inline in the constructor arm (`map f (Done a) = Done (f a)`,
`stdlib/async.mdk`). Two candidate resolutions were named neutrally here while
the fork stood; the verdict follows them:

- **defer the arm** (`gmap g (Done a) = Suspend (u => Done (g a))`), keeping
  construction pure per the discharge-at-`grun` story above, at the cost of an
  operational-semantics change to Async's eager fast path; or
- **keep the arm eager** and charge the callback's row on the method's own
  arrow instead of only its result index, which changes the signature
  discipline described above rather than the impl.

**RESOLVED (owner: Val, 2026-08-17; recorded on #823): DEFER the arm.** Graded
impls suspend the constructor fast path (`deferMap g (Done a)` builds
`Suspend (u => Done (g a))` rather than applying `g` inline); construction
stays genuinely pure and the callback's row fires at force time, per the
discharge story above. Accepted costs: a map/bind on an already-`Done` value
allocates a `Suspend` and pays one extra force round, and the eager reduction
is not preserved in the graded family. The eager-and-charge option was declined
because the charge lands on the method's *declared* arrow — every impl and call
site pays it — which rejects the pure-context builder that is this discipline's
central use case. An explicitly-charged eager sibling method remains addable
later as a separate decision. #823 migrates Async against this verdict.

⚠️ **Read the fork correctly — and this document had it a notch wrong.** An earlier
revision of this paragraph said the probe makes the choice load-bearing because
"option 2 is what makes an eager impl expressible without laundering", implying
option 1 is merely the safe one and option 2 the enabling one. Per #1095, **both
options above are sound as stated**: deferring is silent at construction, and an
explicit `→^{e}` on the method arrow *is* correctly enforced at the call site. What
is false is that the choice is **free**. The unsound shape is neither of them — it
is the *uncharged* signature this section's own examples give (`gmap : (a →^{e} b)
→ f e a → f e b`, no row on the method's arrows), which is what the probe above
exercises and what #823 was on course to ship while the fork stood unmade (it
is now made — the resolution above). §6.7, finding 2, gives the mechanism.

The full family with independent grades remains the ideal; graded-lite is a
narrower first surface realized *within* it once the kind exists, not a
free-standing shortcut. Design driver and phased plan: #820 (interface heads /
kinds first — #822 — then the graded-lite surface; stdlib/Async migration #823;
`do`-notation routing #824; the independent-grade algebra of #821 — a
multi-tail `EffRow` join, today unrepresentable — sequenced last, behind the
same surface).

**Orthogonality to dictionaries (restated).** When an interface method's signature
carries an effect variable (`andThen : m a → (a →^e m b) →^e m b`), the effect var
generalizes and instantiates exactly as above and is **independent** of the
dictionary that resolves `m`'s instance. Parameters ride as inert data on the row;
the dict machinery keys on labels/methods and never inspects a parameter. A change
to effect parameters touches unification and the escape check **only** — never
dispatch. Graded interfaces preserve this: a grade rides the *type index*, joined
by signature shape at elaboration — never routed, never inspected by dispatch.

---

### 6.1 The kind grammar, and the `Effect` kind

A type-parameter kind is written on the **declaration head**:

```
Kind   ::=  Type  |  Effect  |  Kind → Kind  |  ( Kind )
TyParam ::= name  |  ( name : Kind )
```

The arrow **associates to the right**, as everywhere else: `Effect → Type → Type`
is `Effect → (Type → Type)`, the kind of a constructor that takes an effect row
first and a value type second. Parenthesisation is the only way to write a
left-nested kind (`(Type → Type) → Type`).

`Effect` is the kind of an effect row `φ` (§1). A parameter of kind `Effect` may be
instantiated only by a row — a closed one (`⟨ ⟩`, `⟨Stdout⟩`), an open one, or an
effect variable — and may occur only where §1's grammar admits a `φ`: an arrow's
latent row, or an `Effect`-kinded argument position of some type constructor. A
parameter of kind `Type` may not.

**Why this is a grammar addition and not a keyword.** A `data` head's *effect*
parameter needs only the atomic kind `Effect`; if that were the whole feature, a
marker word would do. An **interface** parameter is a type *constructor* — the
whole point of `DeferredThenable` is to abstract over `f`, not over `f e a` — so
its kind is an arrow, `Effect → Type → Type`, and arrows compose. That forces a
grammar for kinds rather than a fixed vocabulary of them.

**Arrow kinds on `data` heads are in scope too, because Medaka already has them.**
This was probed, not assumed: on a binary built from `main` (2026-07-26) both

```
data Wrap f a = W (f a)                     -- f : Type → Type
data Fix f = In (f (Fix f))                 -- f : Type → Type, recursively
```

typecheck (`check` exit 0) and the first also runs. So a `data` parameter can
already be higher-kinded by inference, and the grammar must be able to *write*
what inference already accepts. (§6.3 nevertheless keeps that particular kind
inferred.)

### 6.2 Where a kind annotation is legal

A kind annotation binds a **parameter**, so it is legal exactly where a
declaration binds type parameters:

| Form | Annotation |
|---|---|
| `data T (p : κ) … = …` | yes |
| `newtype T (p : κ) … = …` | yes |
| `type T (p : κ) … = …` (alias) | yes |
| `interface I (p : κ) … where …` | yes |
| `impl I …` | **no** |

**`impl` heads carry no annotation.** An impl head *names types*; it does not bind
parameters (`DImpl { iface, tys : List Ty, … }` in `compiler/frontend/ast.mdk` —
the head is a list of **types**, where every other head is a list of parameters).
Type variables do occur in an impl head — `impl Mappable (Async e)` — but they are
*implicitly* bound and their kinds are already fixed from two sides at once: by the
interface's declared parameter kind, and by the head constructor's own declared
kinds. Admitting an annotation there would create a third source of truth for a
kind that has no freedom left, and there is nothing it could express that the two
declarations do not already say. The same reasoning covers `requires` clauses.

A signature (`f : …`) also binds type variables implicitly and likewise takes no
kind annotation; the kinds of the variables in a signature are determined by the
constructors they are applied to.

### 6.3 Partial annotation, and the surgical rule

**Partial annotation is legal, and is the common case.** `data Async (e : Effect)
a` annotates `e` and leaves `a` bare. Requiring all-or-nothing per head would force
`(a : Type)` noise onto the one declaration in a file that happens to need an
effect index.

**Declaration replaces inference of `Effect`-kindedness ONLY.** This is the
surgical rule, and it is the whole scope of the change:

```
                          κ contains NO occurrence of Effect, anywhere in it
(kind-default)  ─────────────────────────────────────────────────────────────
                an UNANNOTATED parameter may be inferred at κ
```

The side condition has to be stated over the *whole* kind, not over its result:
`{Type, arrow kinds}` would admit `Effect → Type`, which is precisely what the rule
forbids, and "excluded from the codomain" is wrong for the same reason — in
`Effect → Type → Type` the `Effect` sits in the **domain**.

An unannotated parameter still gets its `Type`-versus-arrow structure from how it
is used — `interface Mappable f` still infers `f : Type → Type` from `f a`, and
`data Wrap f a = W (f a)` still infers `f : Type → Type` (§6.1). What an
unannotated parameter can **never** be is `Effect`, or any kind with an `Effect`
inside it: that kind is reachable only by writing it. So the defaulting rule is not
"unannotated means `Type`" — it is "unannotated means *whatever arity inference
determines, drawn from the `Effect`-free kinds*."

**A parameter's RESOLVED kind** is its declared kind where one is written, and its
inferred kind otherwise. Every rule below is stated over the resolved kind, which
is what makes partial annotation (a `data Async (e : Effect) a` whose `a` is bare)
well-defined rather than leaving `a` with no κ to check against.

**Corollary: the migration is compulsory, not opportunistic.** `data Async e a =
Done a | Suspend (Unit →^e Async e a)` — today's spelling, no annotation — becomes
**ill-kinded** under this rule: the `Suspend` field demands `Effect` at `e`, and an
unannotated parameter cannot be `Effect`. That is a deliberate consequence of
*replace* rather than *augment* (nothing keeps a spooky fallback alive), and it is
why the migration list below is a hard prerequisite rather than a cleanup. It also
makes the change **loud**: every existing `Effect`-kinded declaration fails with a
kind error rather than silently re-kinding. (Loud, but not necessarily *at the
head* — §6.4's rule detects the contradiction at the **field** whose effect tail
demands `Effect`, which is where the evidence is. Whether the diagnostic should
also point back at the unannotated head is a presentation choice for the
implementation.)

**The alternative, considered and rejected: annotate everything.** Full annotation
— every parameter of every `data`/`newtype`/`type`/`interface` head carries its
kind, and nothing is inferred — is the more uniform language and would have made
§6.4's consistency rule a plain equality check with no inference to reconcile
against. It was rejected on migration cost. Derived, not estimated:

```sh
# every parameterised declaration head in the shipped tree
grep -rEc '^(public )?(export )?(data|newtype|type|interface) [A-Za-z_][A-Za-z0-9_]* [a-z]' \
  stdlib/*.mdk compiler/*/*.mdk sqlite/lib/*.mdk | awk -F: '{s+=$2} END {print s}'
```

**47** heads at the time of writing — every prelude interface in `stdlib/core.mdk`
(`Mappable f`, `Applicative f`, `Thenable m`, `Foldable t`, `Traversable t`, `Eq
a`, `Ord a`, …) among them. Against that, the surgical rule's migration is the set
of declarations that are `Effect`-kinded **today** — same file scope, so the two
numbers compare:

```sh
awk '
function flush() { if (inbody && hit) print decl; inbody=0; hit=0 }
/^(public )?(export )?(data|newtype) [A-Za-z_][A-Za-z0-9_]* [a-z]/ {
  flush(); decl=FILENAME":"FNR; inbody=1; hit=0; if ($0 ~ /<[a-z][a-z0-9]*>/) hit=1; next }
/^[^ \t]/ { flush() }
{ if (inbody && $0 ~ /<[a-z][a-z0-9]*>/) hit=1 }
END { flush() }' stdlib/*.mdk compiler/*/*.mdk sqlite/lib/*.mdk
```

**Two**, at the time of writing: `stdlib/async.mdk:26` (`export data Async e a`)
and `compiler/eval/eval.mdk:90` (`public export data Value e`). For the fixtures,
the glob must be built with `find` — **there are no `.mdk` files directly under
`test/`**, so a `test/*.mdk` argument makes `awk` exit fatal having matched
nothing:

```sh
find test -name '*.mdk' -print0 | xargs -0 awk '<the same program>'
```

which yields **13**.

⚠️ **That is a floor, not the fixture total.** The census program matches
`data|newtype` only, so it is structurally blind to `interface` and `type` heads —
and the graded fixtures (`test/typecheck_error_fixtures/graded_*.mdk`,
`test/engine_fixtures/graded_iface_async.mdk`, and the `check_module_fixtures`
graded/row families) declare `Effect`-kinded *interfaces*. No single grep decides
that for you, because today's interface rule is the slot-and-tail **co-occurrence**
rule of §6.8, not a textual pattern — enumerate those families by hand. No shipped
**interface** is `Effect`-kinded yet, so the `stdlib/` interface half of the
migration is greenfield; the *fixture* half is not.

⚠️ The decision record for this feature said **one** (`stdlib/async.mdk` alone,
"the migration is ONE LINE"). That count was wrong: `Value e` is `Effect`-kinded
too, via `VPrim (Value e →^e Value e)` and `VThunk (Unit →^e Value e)`. Two is
still small enough that the rationale stands — but this is now the *third* count in
this arc asserted and found wrong (the third being a `test/*.mdk` recipe on this
very page that matched nothing while printing a correct number), so **run the
command, do not trust the number**, including every one on this page.

Both writings are recorded here so the project owner can overrule the choice with
the costs in front of them.

### 6.4 Kind consistency: the two directions, which are NOT symmetric

Declaring a kind creates an obligation between the head and the body. It runs in
two directions and they behave differently.

**(a) Declared kind CONTRADICTED by usage — an error.** If a parameter is declared
`Type` but occurs where §1's grammar demands a row, or declared `Effect` but occurs
where a monotype is demanded, the declaration is ill-kinded:

```
                Δ = the head's RESOLVED kinds (§6.3: declared where written,
                    inferred otherwise)
                Δ ⊢ τ : κ   for every field/method type τ of the declaration
(kind-decl)  ────────────────────────────────────────────────────────────────
                the declaration is well-kinded
```

so `data Async (e : Type) a = Mk (Unit →^e a)` fails: the field's arrow puts `e` in
latent-row position, which demands `Effect`, and the head says `Type`. Symmetrically
`data Box (e : Effect) a = Mk e` fails: `Mk`'s field position demands a monotype.

The diagnostic is **`T-EFFECT-KIND-MISMATCH`**. That name also **renames the
shipped `T-ROW-KIND-MISMATCH`**, which today reports the *use*-site half of the
same rule ("a row was written here, but this type-argument position isn't
row-kinded"); the rename follows the kind's name, since every other effect
diagnostic already says *effect* (`T-EFFECT-LEAK`, `T-EFFECT-UNDETERMINED`,
`T-EFFECT-ARG-UNCOVERED`, `T-EFFECT-LAUNDER`). Whether the *declaration*-site
contradiction above should share that one code or take its own is a taxonomy
question this spec does not settle — see §6.9 (Q2).

**(b) Declared `Effect`, never used in effect-tail position — a *phantom* index.**
`data Box (e : Effect) a = Mk a`. This is the direction the two are not symmetric
in, and it needs splitting into two questions that were previously run together.

*What today's inference does, stated precisely.* Under the retired rule this was
not "rejected" — the parameter was simply **never `Effect`-kinded**, since
`inferParamKinds` reads kindedness off a field's effect tail and there is no such
field. Writing a row in that slot then drew the *use*-site error. Probed
(2026-07-26): `data Box e a = Mk a` with `useBox : Box <Stdout> Int → Int` →
`T-ROW-KIND-MISMATCH` at the row; the control `data Box e a = Mk (Unit →^e a)` →
`check` exit 0. So the phantom shape was unreachable rather than diagnosed.

*As a declaration, in isolation: **legal**.* A phantom `Effect` parameter cannot
launder, and the argument closes against this document's own laws rather than by
appeal to intuition:

- §5's **no-laundering law** governs *elimination of an effectful value*. A phantom
  index means **no field's type mentions `e`**, so no row can be *stored* under it;
  with nothing stored, no elimination can fail to charge what was stored. There is
  no effectful value to eliminate on account of `e`.
- §8's **erasure** gives `e` no runtime meaning, so §8's single-meaning law is
  untouched: the value a program computes cannot depend on a parameter that indexes
  nothing.
- §9's **capability confinement** bounds the authority exercised at each label by
  the manifest. A phantom index adds no atom to any inferred row (nothing performs
  through it), so it cannot *lower* a bound; at worst a downstream signature
  demands a row that is never produced, which is **over**-approximation — §4's
  stance exactly: over-rejection is a completeness gap, never a soundness hole.

*A consequence worth naming: a shipped fixture's verdict changes.*
`test/typecheck_error_fixtures/graded_ctor_phantom_arg.mdk` pins today's rejection
of exactly this shape (`data Box e a = Mk a` used as `Box e Unit` in a method
signature), and its own comment explains that the pair with
`graded_ctor_row_arg_ok.mdk` "differs by ONE constructor field" — the field being
what *infers* the kind. Once the kind is written, the field stops being the
discriminator and that pair no longer proves what it was built to prove. Whether
the phantom half should then be accepted, or rejected for a different reason, has
to be re-decided when the feature lands; this spec's answer for the *declaration*
is "legal", which is not by itself an answer for that fixture's method signature.

*As a **graded instance head**: NOT established — see §6.9 (Q3).* The three
arguments above are about a declaration standing alone; none of them licenses
`impl DeferredThenable Box` for a phantom-indexed `Box`. Reason to doubt: a graded
method's arrows carry no row by design (§6.7), so the family's soundness rests on
impls *storing* the callback rather than performing it — and a phantom-indexed
container has nowhere to store one. Its only possible `gandThen` must apply the
callback, which is precisely the shape probed to launder in §6 above. This spec
therefore settles the declaration and explicitly leaves the instance-head question
open, rather than deciding it by extension.

### 6.5 `requires`-chain kind agreement

A superinterface constraint applies the subinterface's parameters to the
superinterface, so it is an ordinary kind application and must check as one:

```
                interface I p … requires J p
                κ  = p's RESOLVED kind in I   (§6.3)
                κ' = the RESOLVED kind of J's corresponding parameter
(kind-req)  ──────────────────────────────────────────────────────────
                well-kinded iff κ = κ'
```

pointwise over every argument of every `requires` head, and over the whole chain
transitively. A mismatch is an error **at the declaration of `I`** — not at an
impl, not at a use site — since it is decidable from the two declarations alone.

Kind equality here is syntactic on the grammar of §6.1: there is no subkinding and
no coercion between `Type` and `Effect`.

The `Deferred*` family is therefore uniformly `Effect → Type → Type` along its
chain:

```
interface DeferredApplicative (f : Effect → Type → Type)
  requires DeferredMappable f where …
```

and, for the same rule, `interface DeferredApplicative (f : Effect → Type → Type)
requires Mappable f` is **ill-kinded**: `Mappable`'s parameter is `Type → Type`.
That is not an accident of naming — it is §6.6's "neither family subsumes the
other", showing up as a kind error.

### 6.6 Two families, and why neither subsumes the other

§6's opening states the semantic difference (effects *now*, on the method arrow,
versus effects *registered now and produced later*, in the index). The structural
consequence is that the plain and `Deferred*` hierarchies are **peers**: neither
can be derived from the other, and the `requires` rule of §6.5 forbids chaining
them.

A fully general signature would unify them —

```
andThen : m e a → (a →^{e₂} m e' b) →^{e₂} m (e ⊔ e') b
```

— since a strict container is the case `e = e' = ⟨ ⟩`. Getting there needs one of
two things, both far larger than this arc:

- **a phantom index on every ordinary container**, so `List` becomes `List ⟨ ⟩ a`
  and every existing signature, impl, and error message grows a slot that means
  nothing for it; or
- **kind polymorphism**, so a `Type → Type` constructor can fill an
  `Effect → Type → Type` slot (`∀κ. (κ → Type → Type) → …`), which is a change to
  the kind grammar of §6.1 and to unification, not a change to the stdlib.

Two families is therefore the *semantically honest* factoring, not an encoding
accident: the families really do differ in when the effect is produced, and the
type system says so.

⚠️ **Declared kinds also dissolved a constraint that shaped the earlier design.**
Under the retired inference rule an interface is `Effect`-kinded only if some
method uses the *same variable* both at the index slot and in an effect tail, so
the family's factoring was partly forced by what inference could see rather than by
what reads well. With kinds written, factoring is a free choice — which is why
`Deferred*` can mirror the plain hierarchy exactly, `requires` chain and all.

Be precise about **which** methods that constraint actually bit, because a coarser
version of this claim was wrong and is corrected here. The first two cases are
**probed** (2026-07-26); the third is **derived**, and says so — it cannot be
probed, for a reason that is itself worth recording:

- `gpure : a → f e a` alone — **not** `Effect`-kinded. *Observed:* nothing puts `e`
  in an effect tail, so a plain two-parameter instance head is accepted, `check`
  exit 0 (§6.8's non-locality pair turns on exactly this).
- **graded-lite** `gmap : (a →^{e} b) → f e a → f e b` alone — **`Effect`-kinded
  after all.** The callback's row and the index are the *same* variable, so the
  co-occurrence rule fires. *Observed:* a sole-method interface already treats `f`
  as `Effect → Type → Type`, and a plain head draws `T-IMPL-KIND-MISMATCH`. An
  earlier revision said `gmap` could not stand alone; that is **false** in this
  form.
- the **join** form `gmap : (a →^{e₂} b) → f e a → f (e ⊔ e₂) b` — index and
  callback row are *distinct* names, so the co-occurrence rule does not fire.
  **DERIVED, not observed: the join spelling does not parse today.** Both
  `f (e | e2) b` and `f <e | e2> b` are hard parse errors (*"unexpected `(`;
  expected a dedent"* / *"unexpected `<`; …"*), which is #821's content — a
  type-level row join is unrepresentable while `EffRow` carries one optional tail.
  The result is read off `anySlotIsRow` (`compiler/types/typecheck.mdk:8299-8302`),
  which fires only when a **bare name** at slot *i* also appears in that same
  signature's tail set. The nearest *expressible* analogue —
  `gmap : (a →^{e₂} b) → f e a → f e b`, distinct names, no join — is **observed**
  to fail with `T-EFFECT-ARG-UNCOVERED` rather than `T-IMPL-KIND-MISMATCH`, i.e.
  the interface is never kinded graded at all. That is the form the earlier claim
  was true of, and the form §6's signature block uses.

So the constraint is real but narrower than stated: it bites the **join** family,
and `gpure`-shaped methods in either family.

### 6.7 The elimination-form obligation

The graded family moves the effect off the method's arrows and into the index. That
buys "construction is genuinely pure" — and it means **the entire discharge of the
effect happens at the eliminator**. So the eliminator carries an obligation, and it
is stated here because it does not appear to be written down anywhere else:

> **Deferred-elimination obligation.** For an effect-indexed constructor
> `F : Effect → Type → Type`, every elimination form that *runs* a computation
> registered in `F`'s index must **charge that index on its own latent row**: its
> type must have the shape `F e τ̄ → … →^{φ} …` with `e ≤ φ` (§2.4). An
> elimination form that inspects without running (a pattern match that returns the
> stored thunk, a `isDone`-style predicate) is exempt — it discharges nothing.

`runAsync : Async e a →^e a` satisfies it at `φ = e`. An `F`-eliminator that drops
the `→^e` has re-created #817 in a new place.

**It cannot be an interface method, and that is why `grun` sits outside the
`Deferred*` block above.** The eliminator is not uniform across the family:
`Async`'s is `f e a →^e a`, a parser-shaped container's is
`f e a → String →^e Option a`, a resource-scoped one's takes a handle. A method
must have *one* declared type for the whole family, and these differ in arity and
in argument types. What generalizes is the **invariant on `φ`**, not a signature —
so the obligation is a checkable property of each declared eliminator, not
something an interface can impose.

**The obligation itself is still unenforced for interface methods; the index it
protects is no longer unchecked.** Probed on a binary built from `main`
(2026-07-26), then independently reproduced and filed. These are conformance
findings against §9, not claims about the spec.

⚠️ **Status, 2026-07-30: Finding 1 is CLOSED; Finding 2 is OPEN.** The two findings
below were both live when this section was written and their statuses have since
diverged. **#1094 closed 2026-07-27** (PR #1102): `unifyN (TEff r1) (TEff r2) =
unifyIndexRow r1 r2` (`compiler/types/typecheck.mdk:3396`) now routes an
`Effect`-kinded index slot through `unifyIndexRow:1040` / `unifyIndexRowN:1043` /
`indexRowEqCheck:1056`, which enforces exactly the invariant-equality rule §9
specifies. **#1095 remains OPEN.** Finding 1's text is kept below because it is the
record of what was wrong and why the fix had to land at unification rather than
downstream — but every present-tense claim in it that the slot is unchecked is
**historical**, and the corrections at its end say which. The division of labour the
two findings' closing note describes is unchanged: fixing either always left the
other standing, and one of them is still standing.

**Finding 1 (CLOSED — #1094, fixed 2026-07-27) — the `Effect`-kinded argument slot
was not checked at unification.** On the shipped `Async`, as of 2026-07-26:

```
import async.{Async, liftIO, runAsync}
noisy : Async <IO> Int
noisy = liftIO (u => let _ = println "LAUNDERED" in 1)
pureNow : Async <> Int
pureNow = noisy                    -- accepted
sneaky : Int                       -- NO row at all
sneaky = runAsync pureNow
main = println sneaky
```

`check` exit 0; `run` prints `LAUNDERED`. The control discriminates cleanly:
swapping the *value* slot instead (`Async <IO> String` where `Async <IO> Int` is
demanded) is rejected with `Type mismatch: String vs Int`, so the hole is specific
to the `Effect`-kinded slot. #1094's own repro is smaller still — **no import, no
interface and no impl** (`data Box e a = MkBox (Unit →^e a)`, a `Box <Stdout> Int`
rebound as `Box ⟨ ⟩ Int`, then unboxed into a binding typed plain `Int` that
prints) — and both engines are equally wrong, with no divergence to expose it. So
it is neither #1028's cross-module kind loss nor #804's cross-module spurious
*rejection* (both closed, both cross-module), and not #817 or #825, both of which
are dispatch-side.

The mechanism, per #1094, is worth stating here because it says exactly *which*
part of this section the implementation is missing. An `Effect`-kinded argument
elaborates through `kindArgMono … KRow` to `TEff (rowArgOf …)`. For the shape at
issue — a **written closed row** (`<Stdout>`, `⟨ ⟩`) in the index slot — `rowArgOf`
yields a closed `EffRow atoms None`; `unifyN (TEff r₁) (TEff r₂)` then routes to
the arrow-row unifier, whose closed-versus-closed arm — `unifyRowN (EffRow _ None)
(EffRow _ None) = ()`, `compiler/types/typecheck.mdk:981` — is a **documented
silent no-op**. Its comment justifies the leniency for *arrows*, where direction is
recovered later by `launderEscapeFromLog`, and signs off with *"a genuine mismatch
elsewhere surfaces as a caller-level type mismatch"*. That justification does not
transfer: **an index is invariant and has no later consumer.**

(`rowArgOf` is not closed-only in general — `compiler/types/typecheck.mdk:4131-4146`:
its `TyVar` arm yields an **open** `EffRow [] (Some cell)` when the name resolves
through the shared `etbl`, and its catch-all yields `pureRow`. The closed reading
above is scoped to the written-closed-row case the probe exercises.)

Per #1094, giving either side an **open tail** reaches the guarded arms, which run
`effectLeakCheck` and reject the identical program — the sharpest available
evidence that the rule this section states is *implementable*, and merely unreached,
in this position. Note the open-tail arms are not one uniform path: a bare `<e>`
target can silently absorb, with the rejection landing downstream rather than at the
index, so "open tail rejects" should be read as *the machinery exists and fires*,
not as a drop-in specification of where the diagnostic belongs. A corollary #1094
also records: because `rowArgOf`'s catch-all returns the pure row, an ordinary
**type** written in the index slot (`Box Int Int`) is silently read as
`Box ⟨ ⟩ Int`.

**Resolution (2026-07-27, PR #1102).** The fix landed exactly where the paragraph
above predicted it had to: `unifyN`'s `(TEff, TEff)` case no longer reaches the
arrow-row unifier at all. It dispatches to `unifyIndexRow`, whose closed-vs-closed
and same-tail-open arms are **equality-only**, falling through to ordinary
`unifyRowN` only when the two tails are provably distinct metavariables (a genuine
instantiation, not an interchange). The probe above is rejected on a current binary.
The sentence this paragraph used to end with — *"until #1094 is addressed the index
is decorative: the graded story's soundness is currently resting on a check that does
not run"* — was true when written and is **no longer true**; it is quoted rather than
deleted because it is the clearest statement of what the missing check cost.

⚠️ Two of Finding 1's sub-observations were **not** part of #1094's headline and
should be re-probed rather than assumed closed with it: that `rowArgOf`'s catch-all
returns `pureRow`, so an ordinary **type** written in the index slot (`Box Int Int`)
reads as `Box ⟨ ⟩ Int`; and that a bare `<e>` open-tail target can absorb silently,
landing the rejection downstream of the index. Both are recorded in this section's
own text above, and the target architecture carries the first as a task
(*"`rowArgOf`'s catch-all must be a kind error, not `pureRow`"*).

**Finding 2 — the eager-arm fork is a soundness question, not a preference (see
#1095).** The refinement matters and this document previously got it a notch wrong.
Both options named in §6 above — *defer the arm*, or *keep it eager and charge the
callback's row on the method's own arrow* — are in fact **sound as stated**:
deferring is silent at construction, and an explicit `→^{e}` on the method arrow
**is** correctly enforced at the call site. What is false is that the choice is
**free**. The unsound thing is not a third *signature* — it is the **combination**
that results from leaving the fork unmade: §6's uncharged signature,

```
gmap : (a →^{e} b) → f e a → f e b            -- no row on the method's own arrows
```

— which is exactly the signature option 1 also uses — **paired with an eager
impl**.

⚠️ **The two options are NOT symmetric, and that asymmetry is the whole content of
the fork.** Option 1 avoids the pairing **by convention**: nothing enforces it, as
the mechanism below shows — the B2 program printed in §6 is option 1's exact
signature with an eager impl, `check` exit 0, and it prints. Option 2 forecloses
the pairing **in the type system**: the row on the method's own arrow makes an
eager impl a `T-EFFECT-LEAK` at any pure caller. So option 2 closes the hole for
**every** impl, including ones written elsewhere by people who never read this
document; option 1 closes it only for impls that choose to defer. (An earlier
revision of this paragraph said option 1 "makes that pairing impossible by changing
the impl" — false, and contradicted by the four lines immediately below it.)

Ship the uncharged signature and then write an eager impl anyway, which is what
#823 is on course to do if the fork is left unmade, and the result is **silently
accepted** and unsound. Per #1095 the
mechanism is `methodEffRetOccs` (`compiler/types/typecheck.mdk:1157-1164`), which
counts a row-kinded **result-index** occurrence as discharging
`checkArgEffVarCoverage` — but an index is a promise about *force* time, not a
charge at *call* time, so the coverage rule of §6 ("argument-occurrence coverage")
is satisfied by something that does not in fact charge anything. That is the
precise seam at which the deferred family departs from the plain one, and it is why
the eliminator obligation above cannot be left implicit.

Note the division of labour between the two findings: #1094 is about the index not
being *checked*, #1095 about an index being *miscounted as a charge*. Fixing either
leaves the other standing.

### 6.8 What declaration retires

Declaring the kind replaces two *different* inference rules for one concept, and
the fact that there were two, disagreeing, is most of the reason to retire them.

- **On `data`/`newtype` heads** (`inferParamKinds`): a parameter is `Effect`-kinded
  **iff its name appears in a field's effect-tail position**.
- **On `interface` heads** (`declGradedScope` → `ifaceParamKindsOf` →
  `anySlotIsRow`): a parameter's slot *i* is `Effect`-kinded **iff some single
  method** puts a bare name at slot *i* and uses *that same name* in effect-tail
  position in *that same signature*.

Two properties motivate retiring them, both probe-established rather than argued:

**1. The interface rule makes a kind a NON-LOCAL property of the method set.**
Adding or removing an unrelated method silently re-kinds the interface. The
resulting error names **the kinds** — prominently and well — but not **the method
that moved**, which is the fact the writer needs and the only one the diagnostic
cannot recover. Verified with a two-file pair differing by exactly one line
(2026-07-26):

```
data Pair x y = MkPair y
interface DApplicative f where
  gpure : a -> f e a
impl DApplicative Pair where
  gpure a = MkPair a                 -- check exit 0
```

Adding one sibling method — `gandThen : f e a -> (a -> <e> f e b) -> f e b` — to
that interface, changing nothing else, makes the *impl* fail:

```
Instance head has the wrong kind for interface 'DApplicative': the interface's
type parameter is graded — kind `Row -> Type -> Type` — but `Pair` has kind
`Type -> Type -> Type` …
```

The first program is not merely accepted, it is accepted **at a different kind**:
`f : Type → Type → Type` in one, `Effect → Type → Type` in the other, decided by a
method the writer of `Pair` never saw.

**2. The `data` rule is not transitive**, so a parameter that *is* an effect index
one level down is inferred `Type`. `compiler/eval/eval.mdk:88` documents this in
shipped source and works around it by threading `Value e` whole rather than
parameterising over the row. Verified:

```
data Later e a = Now a | Wait (Unit -> <e> Later e a)
data Holder e = H (Later e Int)      -- `e` is inferred Type, not Effect
useIt : Holder <IO> -> Int           -- T-ROW-KIND-MISMATCH at the row
```

A declared `data Holder (e : Effect) = H (Later e Int)` states the intent directly
and needs no transitive analysis.

**3. The two rules are different from each other** for the same concept — slot
co-occurrence within one method signature versus a name in any field's tail — so
the same idea has two definitions and a writer must know which declaration form
they are in to predict the kind. Declaring collapses all three problems: the kind is
written where it is bound, is local to the declaration, is transitive by
construction, and is the same notion on every head.

⚠️ **One thing declaration does NOT retire**, recorded so it is not re-derived: a
head-declared kind does not remove an importer's dependence on the cross-module
parameter-kind table, because `export data` (abstract export) does not publish its
constructors and the importer therefore still reads the kind from a table rather
than from the fields. Declared kinds kill the *variant-inference* dependency and
the non-local rule; the table's own hazards are a separate matter (#1069).

### 6.9 Open questions this spec deliberately does not settle

Listed rather than smoothed over, because a guessed answer here has cost this
document three public retractions already (PRs #999/#1001).

- **Q1 — the `Deferred*` METHOD names. RESOLVED (Val, 2026-08-17; recorded on
  #824): descriptive `defer*` words** — `deferMap` / `deferThen` / `deferPure`,
  with the discharge method spelled `force`. This respects the binding
  constraint (distinct from the plain family's names, since sharing them would
  make the unqualified `andThen` that `do` desugars to pick one interface and
  break the prelude's containers, #824) and matches the decided `Deferred*`
  interface names rather than the fixtures' `g*` prefix. The `g*` spellings
  this entry previously catalogued (`gandThen`/`gmap`/`grun` in
  `test/engine_fixtures/graded_iface_async.mdk`, `gpure` in
  `test/typecheck_error_fixtures/graded_closed_row_grade_ok.mdk:22`, the
  fixture-internal `gth`, and `gap` — this document's own invention) are
  historical until #823/#824 land the surface; do not add new ones. The
  criticism that motivated the choice stands recorded: `DeferredMappable.gmap`
  paired a descriptive interface name with a cryptic, not-even-self-consistent
  prefix.
- **Q2 — one diagnostic code or two.** §6.4's declaration-site contradiction and
  the shipped use-site check are the same rule at two seams. Whether
  `T-EFFECT-KIND-MISMATCH` covers both, or the declaration site takes its own code,
  is a taxonomy decision for `compiler/DIAGNOSTIC-CODES-DESIGN.md` and is not made
  here. (The *rename* of `T-ROW-KIND-MISMATCH` → `T-EFFECT-KIND-MISMATCH` **is**
  decided.)
- **Q3 — a phantom-`Effect`-indexed type as a GRADED INSTANCE HEAD.** §6.4 settles
  the declaration (legal) and explicitly does not settle this. The reason to doubt
  is stated there; it needs deciding alongside #823's eager-arm fork, which is the
  same question seen from the impl side.
- **Q4 — is the §6.7 obligation a rule, or a consequence? PARTIALLY RESOLVED: a
  consequence for ordinary eliminators, still a rule for interface methods.** This
  was recorded as undeterminable; it is now determinable in one half, because the
  discriminator turns out not to depend on #1094 at all — it only needs the index
  made *concrete*. Probed:

  ```
  data Later e a = Now a | Wait (Unit -> <e> Later e a)
  forceIO : Later <IO> a -> a                    -- declared pure, index concrete
  forceIO (Now a) = a
  forceIO (Wait t) = forceIO (t ())
  ```

  → **rejected**, `T-EFFECT-LEAK`: *"Function 'forceIO' declared with <> but also
  performs <IO>"*. So the ordinary §5 binding-boundary escape check **already
  discharges the obligation** for a declared eliminator; no separate rule is needed
  for that case. The earlier probe that appeared to show otherwise
  (`forceBad : Later e a → a`, accepted) is explained rather than contradicted: with
  a *variable* index the same escape check pins `e := ⟨ ⟩`, which is honest, and the
  launder then arrives entirely through the call site — i.e. through #1094 and
  nothing else. **So finding 2 of §6.7's earlier framing was #1094 wearing a
  different hat**, and the "rule vs consequence" question for ordinary eliminators
  resolves to *consequence*, parked on #1094 for confirmation once the index is
  checked.

  What is **not** resolved, and is the reason this entry stays open: the argument
  above covers *declared* eliminators only. It does **not** extend to interface
  method signatures, where #1095 shows a result-index occurrence being miscounted as
  a charge (§6.7, finding 2) — there the escape check is not reached, so for methods
  the obligation remains a genuine rule with nothing enforcing it. Falsifier for the
  resolved half, should anyone find one: an eliminator that *runs* a registered
  computation, carries a concrete non-empty index, and is nevertheless accepted. None
  was found.
- **Q5 — `type` aliases with an `Effect` parameter.** §6.2 admits the annotation on
  an alias head by symmetry with the other binding forms. Whether an alias may
  *abstract over* a row in a way its expansion does not (partial application,
  an alias whose right-hand side drops the parameter) was not investigated and no
  behaviour is asserted. One cheap fact that bounds the question: **today an alias
  parameter can never be `Effect`-kinded at all.** Probed —

  ```
  data Later e a = Now a | Wait (Unit -> <e> Later e a)
  type LaterInt e = Later e Int
  useIt : LaterInt <IO> -> Int          -- T-ROW-KIND-MISMATCH at the row
  ```

  — because the retired inference rule reads kindedness off a *variant field's*
  effect tail and an alias has no variants (the same non-transitivity as §6.8's
  point 2). So there is no existing behaviour to preserve or contradict here: the
  alias case is entirely greenfield, which makes Q5 cheap to settle and means
  nothing depends on settling it now.
- **Q6 — the `do`-routing keyword's spelling** (#824). **RESOLVED (Val,
  2026-08-17; recorded on #824): `defer`.** A separate keyword mirroring `do`
  was already decided; the word is now too. The objection this entry recorded —
  `defer` reads as "run at scope exit" to anyone arriving from Go or Zig — was
  weighed and accepted, not dropped: Medaka has no scope-exit construct for it
  to collide with, and `defer` is family-coherent across the whole surface
  (`Deferred*` interfaces, `defer*` methods, `defer` blocks), which is the
  argument that won.

---

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

— the inferred, escape-checked row of `main` (or each exported entry), unfiltered,
with each label's verified parameter rendered (`drender`). For
`Net "idp.example.com/*"` the manifest records `idp.example.com/*` as the sole
permitted outbound authority.

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

  **Correction — the rule as PR #1093 first stated it was unsound, and
  self-contradicting.** That revision said the two were interchangeable "only
  where the row order `≤` permits, exactly as any other type argument": covariant
  widening, gated by `≤`. Four lines later its own ⚠️ said the arrow-unifier's
  leniency "does not transfer to an invariant index" — the operative sentence and
  the caveat sentence could not both be true, and this is the document's second
  correction in this area (§6.7 finding 2 already corrected the eager-arm
  asymmetry; see also PRs #999/#1001). It is recorded rather than quietly
  rewritten, per that same convention.

  The `≤` rule is not just internally inconsistent — it is disproven. A
  **contravariant** `Effect`-indexed type is expressible and its kind is inferred
  correctly:
  ```
  data Sink e = MkSink ((Unit -> <e> Unit) -> Int)
  ```
  Widening `pureSink : Sink <>` to `Sink <Stdout>` is exactly the `<> ≤ <Stdout>`
  step the old rule licensed, and it makes a binding typed `Int` — carrying no
  effect row at all — print at runtime, on both engines. **Why not covariance:** at
  the time this rule was established, a parameter's polarity in `F` (co-, contra-,
  or non-variant) was not knowable without a variance analysis, and Medaka had
  none; the widening direction that is safe for a covariant occurrence is exactly
  the direction that is unsafe for a contravariant one, so no uniform direction of
  weakening could be sound. **Update (D-2, #1119, this sprint):** Medaka now
  computes a per-parameter polarity for ordinary first-order `data` declarations
  (`dataParamPolarityRef`), enforced at non-covariant type-constructor ARGUMENTS
  via `T-EFFECT-PARAM-VARIANCE` — closing the analogous #1098/#1121 launder family
  for write channels (`Ref`/`Array`) and contravariant function arguments, and (F1,
  this sprint) closing the transitive-fixpoint gap so a forward-declared type
  constructor converges to the correct polarity regardless of declaration order.
  That does not reopen THIS index slot to a polarity-gated `≤`, though:
  `unifyIndexRow` treats an `Effect`-kinded type-constructor argument as invariant
  unconditionally, by KIND rather than by a computed polarity — which stays the
  correct and simpler rule for indices, since equality is what the argument above
  establishes is needed even where the polarity happens to be knowable. The
  per-parameter analysis does not yet cover higher-kinded type-constructor heads or
  type aliases (open follow-ups #2107, #2108). **Why invariance costs almost
  nothing:** with *inferred* indices,
  open-row unification already computes the join before invariance is ever asked
  to compare two closed rows — an `if` across two branches with different tails
  yields one joined row (`Async <Stdin, Stdout | a>`), not two concrete rows for
  invariance to reject. Invariance only bites when a program writes two different
  **concrete** rows into the same slot, which is exactly the case that should be
  flagged rather than silently widened. (Established by probe.)

  The removed clause — "exactly as any other type argument" — was also
  independently wrong, and is not replaced with a repaired version of the same
  appeal: ordinary type arguments are precisely where this covariant-widening bug
  lives today (see #1098 — `Ref (Unit -> <> Unit)` widens to `Ref (Unit ->
  <Stdout> Unit)`, and a write through the alias makes a no-row read print). Index
  invariance does not rest on how sibling type-argument positions behave; it
  stands on the variance argument above alone.

  ✅ **ENFORCED since 2026-07-27 (#1094 closed, PR #1102).** This bullet read
  *"Probed and currently FALSE on the implementation"* until 2026-07-30, and by then
  the statement was two days stale: `unifyN (TEff r1) (TEff r2) = unifyIndexRow r1 r2`
  (`compiler/types/typecheck.mdk:3396`) routes an `Effect`-kinded index slot to
  `unifyIndexRow:1040` / `unifyIndexRowN:1043` / `indexRowEqCheck:1056`, which is
  equality-only on the closed-vs-closed (`:1044`) and same-tail-open (`:1046-1048`)
  forms and falls through to ordinary `unifyRowN` (`:1049`) only when the tails are
  distinct metavariables. The arrow-row unifier's closed-vs-closed silent no-op still
  exists and is still correct **for arrows** — the fix was to stop routing indices
  through it, not to change it. The *rule* stated above was never wrong; only this
  note about the implementation was. (Also unaffected by the correction above: the
  implementation was never enforcing `≤` at this slot either.)
- **Deferred discharge.** Every elimination form of an effect-indexed type that
  *runs* a registered computation charges that computation's index on its own
  latent row (§6.7). Together with index fidelity this is what makes "registered
  now, produced later" a conservation law rather than a convention: an effect
  corked into an index is uncorked into a row, never dropped. For an ordinary
  declared eliminator the §5 escape check already delivers this (§6.9 Q4). For an
  **interface method** it does not: a result-index occurrence is currently
  miscounted as a charge — see #1095 — so the graded family's methods are the one
  place this statement has no enforcement behind it.
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
  side. Of the two issues once open against this clause, **#1094 (index unchecked) is
  CLOSED** (2026-07-27, PR #1102 — see the §9 bullet) and **#1095 (a result-index
  occurrence miscounted as a charge in a method signature) is OPEN**. Note neither
  showed up as an engine divergence — both engines were equally wrong — so
  `diff_compiler_engines` could not see this class, and cannot see the half that
  remains.
- **Erasure / backend agreement** → §8: any divergence in result (not just
  acceptance) between evaluators traceable to effects violates the single-meaning law.
- **`main` policy** → §7: a *language-internal* upper-bound gate on `main` would be a
  spec deviation in the *opposite* direction — `main` is the grant root; bounding is
  the host's job, not the type system's.

---

## 11. Per-clause enforcement table (clause → site → keying assumption)

Seeded from [`compiler/TYPECHECK-ARCHITECTURE.md`](../../compiler/TYPECHECK-ARCHITECTURE.md)
§4 Layer 1 (the densest open-S0 layer per that map's finding #2) and re-verified
directly against source at `c4ef6dbe` (this document's `$BASE`; line numbers drift —
re-derive with `grep -n '^<symbol>' <file>` rather than trusting them). Follows
[`SHADOW-SEMANTICS.md`](SHADOW-SEMANTICS.md) §3's form. A clause with no located
site is marked **UNIMPLEMENTED**, not skipped, per §0's non-derivation principle.

✅ **The staleness this table found in the document's own narrative is now fixed
(2026-07-30, #1107).** When these rows were built, §6.7 Finding 1 and the §9 "index
fidelity" bullet both asserted the `Effect`-kinded argument slot was *"currently FALSE
on the implementation"* / *"nothing enforces it today"*, citing #1094 — which had
closed on 2026-07-27. Rather than leave the contradiction standing behind a notice,
both passages have been corrected in place, with the superseded sentences quoted so
the record survives; §10's "index fidelity and deferred discharge" bullet was corrected
with them. The lesson is the durable part: **a `$BASE`-verified enforcement table can
be newer than the prose above it**, so a clause's narrative and its row must be
re-read together, and the row is the one with a derivation.

| Clause | Stage / site | What it enforces | **Keying assumption** |
|---|---|---|---|
| §2.1 domain family (`Unit`/`Prefix`/`Set`/`Product`) | `data Param = PUnit \| PPrefix … \| PSet … \| PProduct …`; `dsubN:270`, `djoinN:331`, `drenderN:412` (all `compiler/types/typecheck.mdk`) all pattern-match on all four constructors | the `⊑`/`⊔`/render laws, domain-generically | ENFORCED for all four domains — better than this document's own §10 hedge ("an implementation realizing only `Unit + Prefix`" is explicitly allowed for as a lesser case; the current tree already has all four wired into the lattice ops) |
| §2.2 canonical row form (one atom per label, same-label atoms joined) | `effrowNorm:784` (`compiler/types/typecheck.mdk`) | atoms on the same label collapse to one by `⊔_{𝔻_L}` | — |
| §2.3 `Prefix` delimiter discipline | `prefixPatternOk:728`/`strHasSlash:733` (`compiler/types/typecheck.mdk`), message at `:1094` | rejects a Prefix pattern with no trailing `*` and no `/` | requires the pattern string to end in `*` **or** contain `/`; no structural (path-segment-aware) check beyond that |
| §2.4 sub-effecting order `≤` | `dsubN:270-289` (`compiler/types/typecheck.mdk`) | the per-label refinement order lifted pointwise, plus the tail rule (closed ≤ open) | domain mismatch between two atoms of the *same* label is asserted "never happens (one domain per label)" (`:289`) — not independently re-verified here |
| §2.4 join `⊔` | `djoin:328`/`djoinN:331-351` (`compiler/types/typecheck.mdk`) | least-upper-bound row used by inference (branch joins, `let`) | — |
| §3 `var`/`app`/`lam` | `inferVar:6025`; `inferAppExpr:6435`; `inferLam:7785` (all `compiler/types/typecheck.mdk`) | variable use performs nothing; application unions fn/arg/latent effects; closure construction is pure, body effect stays latent | — |
| §3 `let` | `inferLetGroup:8179` (`compiler/types/typecheck.mdk`) | joins the bound expression's and body's effects | — |
| §3 `sub` (subsumption / branch join) | `inferIf:7912` (`compiler/types/typecheck.mdk`), which reconciles branch rows via the same `djoinN` (row above) | weakens an inferred row to a larger bound; how `if` branches reconcile | — |
| §3 `prim` (mints a parameterized atom) | `holeFillParam:836`/`fillHoleAtom:822` (`compiler/types/typecheck.mdk`) | computes the atom's parameter from the determining argument via `α`, falling back to the domain's `⊤` | domain-directed: Prefix-domain labels get `PPrefix (Some s)`, Set-domain get a singleton `PSet (Some [s])`, Product-domain get `Host=literal, Method=⊤` (comment: "α has no method info — a sound over-approximation") |
| §3 `method` (dispatch's latent row = whatever the impl performs) | no dedicated site — cross-references `DICT-SEMANTICS.md` §5's method-dispatch rows (same `var`-time instantiation determines both the dict route and the effect var) | — | — |
| §4 abstraction `α` | `alpha:664-688` (`compiler/types/typecheck.mdk`) | the ideal `α` table: literal → `Known`, `++`/interp → propagate, `let`/`if`/`match` → propagate/join, everything else → `Unknown` | matches the spec's own table row-for-row (string literal, `let`-propagation, `if`-join, `match`-join, catch-all) |
| §4 `⊤`-fallback (no-exfiltration) | `holeFillParam:843` `Unknown => dtopFor label` (`compiler/types/typecheck.mdk`) | an un-analyzable expression's authority abstracts to the domain's `⊤`, never a narrower bound | — |
| §5 binding-boundary escape check (`φ_inf ≤ φ_decl`) | `checkEffectEscape:15990`, `T-EFFECT-LEAK` at `:15995` (`compiler/types/typecheck.mdk`) | rejects a body performing an atom (or a narrower param) outside its declared row | keyed by binding name into `sigTyMapRef` — a **bare-name** table; not independently re-verified for cross-module collision here |
| §5 laundering / covariant-position re-open | `reopenRow:3659`/`reopenRowN:3662` (`compiler/types/typecheck.mdk`) | an instantiated closed-with-atoms row reopens only at value-producing positions, so equality unification still enforces `≤` rather than collapsing to `=` | fires only at `True`-flagged (covariant) call sites — the flag itself is not re-audited here |
| §6 effect-variable generalization (the HM rule for effects) | `generalize:3505` (`compiler/types/typecheck.mdk`), which quantifies free type *and* effect vars together | `gen(Γ, τ, φ)` — effect-polymorphic schemes for higher-order functions | shares one function with the dictionary-side `gen` (DICT §4) — the two axes are not separately keyed |
| §6 value restriction | `eagerRefs:8683`/`allEVars:15422` (`compiler/types/typecheck.mdk`) | generalize an effect variable only at syntactic values | — |
| §6 Option A (return-position effect var must also occur in argument position) | `checkIfaceMethodEffs:1138`, `checkArgEffVars:1175-1177` (`compiler/types/typecheck.mdk`) | rejects an interface method whose quantified return-row effect var has no argument-side occurrence to pin it | decided from the **declared signature alone** — dispatch never consulted (documented orthogonality) |
| §6 dual condition: argument-occurrence coverage (ENFORCED) | `checkArgEffVarCoverage:1165-1173` (`compiler/types/typecheck.mdk`) | rejects "argument-only" and "uncovered atoms" shapes — an argument-side effect var whose atoms are not covered by a non-argument occurrence | must fire **at declaration**: comment notes post-unify inspection cannot recover the loss (same-tail row unification discards it silently) |
| §6 impl-body per-arrow bound (#803, ENFORCED) | `launderEscapeFromLog:14624-14700ish` (`compiler/types/typecheck.mdk`), sourced from the post-unify absorption-event trail (#839 2b) | bounds the impl body's own latent effect on **every** declared arrow (not just the last) by `atoms(φ_i^{decl}) ∪ argContributable` | per-arrow residual = `atomsEscape(actual, expandIo(declared))`; OPEN vs CLOSED actual arrows are recovered through two disjoint routes (trail query vs. direct read) — see the function's own long comment for why |
| §6 method-scheme rigidity, effect axis (#814) | `checkImplEffVarRigidity:14927` (`compiler/types/typecheck.mdk`) — the effect reading of `DICT-SEMANTICS.md` §3 **W3** | a quantified effect var may acquire no concrete atom beyond what its declared occurrences already carry; two declared effect vars may not be identified | same `inRigidityBodyRef` gate as the type-axis check (DICT §3 W3 row) |
| §6 known residual (#817): method effvar ≈ instance-head row param | documented at `compiler/types/typecheck.mdk:14916-14924`, immediately preceding `checkImplEffVarRigidity:14927` | the ONE identification deliberately admitted through the W3/rigidity check above | scoped to instance-head effect params only (`impl Mappable (Async e)`-shaped); tracked as design-open (#817), retires once the stdlib migrates to graded interfaces |
| §6 graded interfaces elaborate as an ordinary dict (no overlap-on-grade) | `fromAstTypeVarApp:4167-4171` (`compiler/types/typecheck.mdk`), whose own header comment (`:4140-4145`) SELF-CITES this exact clause: *"The head itself still elaborates as an ordinary tyvar: the grade rides the type INDEX, never the dictionary (EFFECTS-SEMANTICS §6 'Erasure and dispatch are untouched')"*. The `DImpl` elaboration path itself is the same as any interface (`compiler/frontend/ast.mdk:437`) | a graded interface-typaram spine (`f e b`) elaborates its head as a bare tyvar; the row slot is folded separately via `foldRowSlotArgs`, never routed through dict machinery | keyed by whether a name was seeded into `etbl` but withheld from `tvs` (`isRowSlotArg:4175-4177`) — "seeded into etbl AND withheld from tvs" IS the classification, per the same comment, so there is no separate name-keyed global to collide |
| §6.7 deferred-elimination obligation — DECLARED eliminators (ENFORCED) | `checkEffectEscape:15990` (row above), per §6.9 Q4's resolution | a declared eliminator (`forceIO : Later <IO> a -> a`) that under-declares its latent row is caught by the ordinary binding-boundary escape check | no separate mechanism needed — probed and confirmed by the spec's own §6.9 Q4 |
| §6.7 deferred-elimination obligation — INTERFACE methods (UNENFORCED — #1095, OPEN) | `methodEffRetOccs:1248-1254` (`compiler/types/typecheck.mdk`), feeding `checkArgEffVarCoverage` (row above) | *should* charge a graded method's result-index occurrence as a use, not as coverage | 🔴 miscounts a result-index occurrence as **discharging** `checkArgEffVarCoverage` — an index is a promise about *force* time, not a charge at *call* time, so an eager graded impl launders with `check` green. Confirmed still open (`gh issue view 1095` → OPEN) |
| §6 orthogonality to dictionaries (restated) | same site as the row above: `fromAstTypeVarApp:4140-4145` self-cites this clause by name (*"the grade rides the type INDEX, never the dictionary"*); additionally, no effect-row read was found inside `entail`/`entailInst`/`keyForSite*` (DICT §11 table) | a change to effect parameters touches unification and the escape check only, never dispatch | the code comment's own citation of this exact spec clause is stronger evidence than a negative grep alone — but it is still one author's stated INTENT at one call site, not an exhaustive proof that no OTHER site reads an effect row for dispatch |
| §6.1 kind grammar (`Kind ::= Type \| Effect \| Kind → Kind`, `(name : κ)` syntax) | **UNIMPLEMENTED, re-confirmed at THREE independent layers (re-audited with lexer/AST vocabulary, not just parser vocabulary, per the W2 lesson).** Lexer: `TEffect` (`compiler/frontend/lexer.mdk:89`, keyword `"effect"` at `:455`) is the `effect Foo` DECLARATION token, not a kind keyword — no `TKind`/kind-colon token exists. Parser: `parseData:2924-2928`/`parseInterface:2607-2611` parse params as bare `many lowerNameP`. AST: `DData DataVis String (List String) …` (`compiler/frontend/ast.mdk:421`), `DInterface { typarams : List String, … }` (`:433`), `DTypeAlias`/`DNewtype` (`:445`,`:447`) all carry typarams as `List String` — there is no FIELD anywhere in the AST that could hold a kind even if parsed; `Attr = AttrDeprecated String \| AttrInline \| AttrMustUse` (`:406`) rules out an attribute-based side channel too. `data Kind = KType \| KRow` (`compiler/types/typecheck.mdk:1633`), no arrow kinds | N/A | the spec's §6.3 "Status correction" already says this precisely: #822 shipped only an *inferred* graded-lite kind, and declaration is what §6.8 says should retire that — it has not yet. Grepped `typecheck.mdk` for "declared kind"/"kind annotation": zero hits, consistent with the structural absence above |
| §6.2 where a kind annotation is legal | **UNIMPLEMENTED** — moot; no annotation syntax exists to be legal or illegal anywhere yet | N/A | `DImpl { iface, tys : List Ty, … }` (`compiler/frontend/ast.mdk:437`) is consistent with "impl heads carry no annotation" only by *absence of any annotation grammar at all*, not by a dedicated rejection rule |
| §6.3 kind-default / surgical rule (resolved kind = declared-or-inferred) | **UNIMPLEMENTED** as specified. Current mechanism is INFERENCE-ONLY: `inferParamKinds:8292` (`data`/`newtype` heads); `declGradedScope:8383`→`ifaceParamKindsOf:8399`→`anySlotIsRow:8416` (`interface` heads) | N/A — there is no *declared* half to combine with the inferred half | this is precisely the "two different inference rules for one concept" §6.8 says declaration retires — both are still live |
| §6.4(a) `kind-decl` (declared kind contradicted by usage) | **UNIMPLEMENTED** as specified. Current analog is usage-site-only: `T-ROW-KIND-MISMATCH` at `compiler/types/typecheck.mdk:4085`,`4252`,`14072`; `T-IMPL-KIND-MISMATCH` at `:1405`,`:1429` | catches a usage inconsistent with the currently-INFERRED kind | no declaration exists yet to be contradicted — this is the *use*-site half of what §6.4 specifies, not the declaration-site half. The planned rename to `T-EFFECT-KIND-MISMATCH` (§6.4) has also not happened — both codes are still the pre-rename names |
| §6.4(b) phantom `Effect`-indexed parameter, legal as a declaration | **UNIMPLEMENTED** — moot; no declared-`Effect`-kind parameter can exist yet. `test/typecheck_error_fixtures/graded_ctor_phantom_arg.mdk` (confirmed present) still pins the OLD rejection under the inferred mechanism | N/A | the spec's own §6.4(b) says this fixture's verdict needs re-deciding once declaration lands — it has not been re-decided, and the fixture still asserts the pre-declaration behavior |
| §6.5 `kind-req` (requires-chain kind agreement) | **UNIMPLEMENTED** as the declared-kind rule. Partial analog for impl-vs-interface only: `checkGradedImplHeads:1335`→`checkGradedImplTys:1368`→`checkGradedImplHead:1395` (`compiler/types/typecheck.mdk`) | impl head's kind vs. the interface slot's (inferred) kind | ⚠️ self-documented bare-name hazard at lines 1347-1367: the slot kinds were once keyed by `<iface>@<slot>` (bare interface NAME, not module identity) in a per-run table whose comment named the exact collision class (#1044, #1047) and called the severity "bounded... never silent wrongness in a program's types" — a claim not independently re-verified here. ⚠️ That hazard is CLOSED twice over: #1111 A-2.4 re-keyed the table to a module-qualified identity, and #1112 A-3.5c (#1557) retired it entirely in favour of stage K's `CE` (`ceRowParamKinds`, read at the reading module's ordinal through `ceSlotKindsAt`) |
| §6.7 Finding 1 — `Effect`-kinded argument slot at unification | **NOW ENFORCED** (see the ⚠️ notice above the table). `unifyN (TEff r1) (TEff r2) = unifyIndexRow r1 r2` (`compiler/types/typecheck.mdk:3396`) → `unifyIndexRow:1040`/`unifyIndexRowN:1043`/`indexRowEqCheck:1056` | invariant-equality check on an `Effect`-kinded index slot — `F φ₁ τ̄`/`F φ₂ τ̄` interchangeable only when `φ₁ = φ₂` | equality-only on both closed-vs-closed and same-tail-open forms (`unifyIndexRowN:1044-1049`); routes to ordinary `unifyRowN` only when the two tails are provably different metavariables (genuine instantiation, not interchange) — this is exactly §9's "no direction of `≤` licensed at this slot" |
| §6.7 Finding 2 / §9 deferred discharge — INTERFACE methods | same as the #1095 row above (`methodEffRetOccs:1248`) | — | duplicated here because §9 states it as a soundness-target bullet ("deferred discharge") distinct from §6.7's own framing — both point at the same one open mechanism |
| §7 every label is a host capability | `effectDomains : Ref (List (String, Param))` field, `compiler/types/typecheck.mdk:2076`; populated via `LE`-building at label/`effect`-declaration processing | every declared label carries a domain and is emitted to the manifest | — |
| §7 `IO` as a widening alias | `expandIoInBound:522-534` (`compiler/types/typecheck.mdk`) | `IO` is treated as the join of the security labels at `⊤` for subsumption purposes | called from the escape check (`checkEffectEscape` row above) and from the impl-body bound (`launderEscapeFromLog` row above) — not an independent mechanism |
| §7 manifest extraction `M(module)` + host-grant policy check | `runCheckPolicy:516` (`compiler/tools/check_policy.mdk`), fed by `parsePolicy:125` | the toolchain-level `inferred ≤ policy` verification, performed against the extracted manifest | manifest verification is a **separate tool** (`medaka check-policy`) from ordinary `check`/`build` — a program can typecheck without ever having its manifest verified unless this tool is invoked |
| §8 single-meaning law / erasure | negative-result site: `compiler/eval/eval.mdk:90` `data Value e = …` carries no effect-row constructor/field anywhere in its variants | the value a program computes cannot depend on its effect annotations | erasure verified by *absence* — no runtime representation of a row was found in `Value`'s variants |
| §8 mis-annotated-extern trust boundary | `stdlib/runtime.mdk`'s extern catalog (declared rows, not independently checked against runtime behavior) | the type system is the only place authority is checked, so extern-declared rows are part of the trusted base | the spec says this explicitly: "a soundness bug the spec cannot catch" — recorded here as a known, accepted gap, not a finding |
| §9 soundness statements (effect preservation, progress/containment, α-soundness, capability confinement, principality, coherence-with-erasure) | composite of every row above | explicitly "targets for a later proof/audit" (§9's own header) | — |
| §9 index fidelity | see the §6.7 Finding 1 row above (NOW ENFORCED) | `F φ₁ τ̄`/`F φ₂ τ̄` interchangeable only when `φ₁ = φ₂`, invariant, no `≤` licensed | the spec's own contravariant `Sink` counterexample (why no direction of weakening is sound) is exactly why `unifyIndexRowN` is equality-only rather than directional |
| §9 deferred discharge | ENFORCED for declared eliminators (§6.9 Q4 row above), UNENFORCED for interface methods (#1095 row above) | an effect corked into an index is uncorked into a row, never dropped | split verdict — the two halves have different enforcement status, which is why they are tabulated separately above rather than as one soundness bullet |

**UNIMPLEMENTED found (7):** §6.1 kind grammar; §6.2 where annotation is legal;
§6.3 kind-default/surgical rule; §6.4(a) kind-decl (declared-vs-usage contradiction);
§6.4(b) phantom-index-as-declaration; §6.5 kind-req (requires-chain kind
agreement, as a declared-kind rule) — all six are one coherent gap: the "declared
kinds" design of §6.1-§6.5 has no parser support yet, only the *old*, narrower,
inference-only mechanism §6.8 says it should retire. Plus, separately: §6.7
deferred-elimination obligation for interface methods (#1095, tracked, OPEN).

**Prominent finding — spec narrative was stale, not the rule (RESOLVED 2026-07-30):**
§6.7 Finding 1 / §9 "index fidelity" / §10 described the `Effect`-kinded argument slot
as currently unenforced, citing #1094. #1094 closed 2026-07-27 and the fix
(`unifyIndexRow` et al.) is live. The *normative rule* was correct throughout; only
this document's prose about *today's implementation state* was wrong, and #1107
corrected all three passages. **#1095 is untouched by that correction and is still
OPEN** — the deferred-elimination obligation for interface methods remains the one
place §9's "deferred discharge" statement has no enforcement behind it.

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
