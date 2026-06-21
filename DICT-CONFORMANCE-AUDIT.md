# Dictionary-Passing Conformance Audit

**Status:** audit (findings). **Target spec:** [`DICT-SEMANTICS.md`](DICT-SEMANTICS.md)
(theory-first, written without consulting the implementation). **Audited tree:**
`HEAD = 14a3b58` (`20a5c45` argstamp-unify confirmed ancestor). **Canonical
implementation under audit:** the native self-hosted compiler (`selfhost/*.mdk`,
compiled to the `./medaka` binary). The OCaml compiler (`lib/*.ml`) is the
**frozen differential oracle** being retired; its divergences are recorded but are
out of scope for the conformance verdict except where it usefully contrasts.

## 0. Method

Six independent read-audits, one per spec dimension (§2 representation, §3
entailment, §4 elaboration, §5 dispatch, §6/§8 coherence+identity, §7
single-evaluator law), each reading both implementations and the dispatch-gap
docs, every claim cited `file:line`. Three of the soundness-relevant claims were
then **re-verified empirically by the auditor** on a freshly built canonical
binary (`make medaka`, cold from seed) running both `medaka run` (interpreter)
and `medaka build` (native LLVM emit). Two agents independently built and ran the
binary as well; one inter-agent conflict (a claimed native deep-nesting SIGSEGV)
was resolved against the empirical result.

## 1. Executive verdict

**The canonical binary is substantially conformant.** Every historically painful
defect class the spec was written to explain is **closed and empirically
verified** on native codegen:

- evidence is a genuine **nested tree** (`VDict(key, [reqs])`), not a flat key (§2);
- **return-position dispatch** goes through the static dict (`pure 1 : Option Int`
  → `Some 1` vs `: List Int` → `[1]`, same argument — §5);
- the **single-evaluator law** holds in substance — one route-stamped Core IR,
  both evaluators consume it, parity probe 26/26 identical (§7);
- nested element-dicts **#21/#5** (two- and three-level), mutual-recursion **#44**,
  and dispatch gaps **#54/#55/#50** all round-trip `run == build`.

The real divergences are narrower and cluster as follows:

| # | Divergence | Spec | Severity | Bites canonical? |
|---|---|---|---|---|
| **D1** | Interface `requires` (superclass) is **semantically inert** — no existence gate, no `supers` evidence | §3 `super`, §6 C2 | **Soundness** | **Yes** (confirmed) |
| **D2** | Dict-param arity keyed by **bare name**, not module-qualified identity — ✅ CLOSED (fn `e488cd9`, method `880e0fe`; full re-key deferred) | §8 I1 | **Soundness** | Yes (latent) |
| **D3** | **No global instance environment** — `IE` assembled per-module | §6 C4 / §8 I2 | Coherence | Yes (latent) |
| **D4** | Overlap escape-hatches resolve to **arg-tag at runtime**, no uniqueness enforcement | §6 C1, §5 | Coherence | Yes (narrow) |
| **D5** | **Superclass acyclicity (W1)** unenforced | §3 W1 | Robustness | Esoteric |
| **D6** | **Instance-resolution termination (W2)** unenforced | §3 W2 | Robustness | Esoteric |
| **D7** | No distinct `supers` field; instance-context **Q param-threaded**, not closure-captured | §2 | Fidelity | No (equivalent) |
| **D8** | **Phantom-position** methods silently undispatched | §5 | Fidelity | No (inexpressible) |
| **D9** | Vestigial flag-fork at `typecheck.mdk:4567` (representation-only) | §7 | Cosmetic | No (invisible) |
| **D10** | Stale comments/docs contradict the binary | — | Doc | No |

Only **D1** is an active soundness hole reachable by ordinary code. **D2–D4** are
latent (no current trigger in stdlib or tests) but structural. **D5–D6** need
adversarial input. **D7–D10** are fidelity/cleanup, not bugs.

## 2. Conformance matrix (per spec clause)

| Clause | Verdict | Evidence (canonical unless noted) |
|---|---|---|
| §2 evidence is a tree | **CONFORMS** | `VDict String (List Value)` `eval.mdk:97`; route `RKey String (List Route)` `ast.mdk:55`; builder recurses `eval.mdk:850` |
| §2 distinct `supers` field | **PARTIAL (D7)** | superclass + instance-context share one `reqs` list; no `supers` field anywhere |
| §3 `assum` (receive, not rebuild) | **CONFORMS** | `enclDictVarOf`/`activeDictVarOfEncl` `typecheck.mdk:4594-4607` → `RDict $dict_<encl>_<slot>` |
| §3 `super` (project, not re-resolve) | **DIVERGES (D1)** | no super-projection route; `supers` field never reaches solving |
| §3 `inst` (build + recurse Q) | **CONFORMS** | `implRequiresRoutesRec` `typecheck.mdk:5199` → nested `RKey`; #21/#5 verified |
| §3 determinism / overlap reject | **CONFORMS\*** | `checkCoherence` 6 sites `typecheck.mdk:4915`; \*modulo deliberate escape-hatches (D4) |
| §3 W1 acyclic supers | **DIVERGES (D5)** | no cycle check; `checkSuper` only verifies name exists `resolve.mdk:473-498` |
| §3 W2 termination | **DIVERGES (D6)** | comment-asserted only `typecheck.mdk:5198` |
| §4 `var` (apply evidence) | **CONFORMS** | `inferDictAtFound`→`routeOfMono` `typecheck.mdk:5228-5353` |
| §4 `gen` (abstract evidence) | **CONFORMS** | signature-order slots `registerMemberSlots`; one list drives both sides |
| §4 `gen-rec` (reuse group dicts) | **CONFORMS** | `RecDictApp`→`realizeRecDictApps` `typecheck.mdk:5311-5353`; #44 closed |
| §5 arg-position dispatch | **CONFORMS** | static route + `applyDicts` threading `eval.mdk:835` |
| §5 return-position dispatch | **CONFORMS** | `returnPosMethodNames`→`RDictFwd`/`RKey` from result mono; verified |
| §5 phantom-position | **DIVERGES (D8)** | no determining arg/result; silently undispatched |
| §6 C1 unique instances | **PARTIAL (D4)** | rejects equal/incomparable; permits most-specific/named/default → arg-tag at runtime |
| §6 C2 superclass consistency | **DIVERGES (D1)** via super; else structural per-module |
| §6 C3 resolution determinism | **CONFORMS** | single per-module resolution |
| §6 C4 single global IE | **DIVERGES (D3)** | per-module assembly `typecheck.mdk:7717-7780` |
| §7 single-evaluator law | **CONFORMS in substance** | one route-stamped Core IR; parity 26/26; residual D9 |
| §8 I1 identity-keyed arity | **CONFORMS in substance (D2 closed)** | module-qualified mirrors (fn `e488cd9` / method `880e0fe`) consulted per scope; bare `funConstraintsRef` `typecheck.mdk` kept (load-bearing), full retirement deferred |
| §8 I2 global IE after import | **DIVERGES (D3)** | same root as C4 |
| §8 I3 evidence travels | **CONFORMS** | use-site discharge `typecheck.mdk:2408-2429` |

## 3. Divergence ledger

### D1 — Interface `requires` (superclass) is semantically inert — **SOUNDNESS, canonical**

**Spec:** §3 `super` makes superclass access a *projection* `supers(e).D`; §6 C2
requires the superclass impl to exist and its evidence to equal the canonical
`D`-dict. §5 requires return-position dispatch to come from the static dict.

**Finding (canonical / selfhost):** the interface `supers` field is parsed
(`parser.mdk:2060-2088`), plumbed through annotate/desugar/marker/exhaust
unchanged, and checked only for *name existence* (`resolve.mdk:473-498`
`checkSuper`). **It never reaches typecheck's constraint solving, dispatch, or any
obligation check.** There is no super-projection arm in the `Route` type
(`RNone | RKey | RDict | RDictFwd | RLocal`, `ast.mdk:53-58`) and no
`expand_supers`/`check_superinterface_obligations` analog (exhaustive grep empty).

**Empirical confirmation (auditor, both binaries):**

```
impl Mon Bag    -- where  interface Mon a requires Sem a ;  NO impl Sem Bag exists
```
- native `./medaka check` → **rc 0 (accepts)**; `run` → `accepted-no-Sem-Bag`.
- OCaml oracle `check` → **rejects**: `impl Mon Bag requires a superinterface impl 'impl Sem Bag', which is missing`.

Same divergence for `impl Ord Color` without `impl Eq Color`.

**Two coupled gaps:**
1. **No impl-declaration existence gate.** Native ships `impl Mon Bag` without
   `impl Sem Bag`. OCaml gates this (`check_superinterface_obligations`,
   `lib/typecheck.ml:4857-4875` → `MissingSuperImpl`); selfhost never ported it.
2. **No `supers` evidence path.** Superclass methods reach an impl by **arg-tag on
   their own arguments**, not by projecting a `supers` dict. For an *argument*-position
   superclass method with the impl present this happens to work; where a
   wrong-but-same-tag impl exists it **silently mis-dispatches** (a `sameRank :
   Ord a => a -> a -> Bool` body calling `eq` returns a value even with no `Eq`
   impl). A **return/phantom-position** superclass method has no argument to tag
   and cannot dispatch at all.

**Partial mitigation observed:** native's *call-site* obligation check
(`checkCallObligations`, `typecheck.mdk:6021-6024`) does fire when a superclass
method is used at a type with **no** matching-tag impl (auditor probe: a `sappend`
with no impl anywhere → `check` rc 1). So the hole is specifically (a) the
declaration-site gate, and (b) the silent mis-dispatch when *some* same-tag impl
exists. This is the §10 "superclass entailment → re-resolution at the use site"
defect in its most degenerate form: **no resolution at all, arg-tag substituting.**

**Root cause:** evidence has no `supers` field (D7) and the elaboration never
builds or threads superclass evidence; the existence gate was never ported from
OCaml during the self-host.

---

### D2 — Dict-param arity keyed by bare name, not binding identity — **SOUNDNESS (latent), both impls** — ✅ CLOSED (fn `e488cd9`, method twin `880e0fe`)

> **RESOLUTION (2026-06-21):** the observable collision is closed for BOTH
> function-level (`e488cd9`) and method-level (`880e0fe`) dict arity, via additive
> module-qualified mirror tables (`crossModuleFunConstraintsQualRef` /
> `crossModuleMethodConstraintsQualRef`) consulted per dict-pass scope. The
> method-level case was a genuine *unmitigated* soundness bug (silent: `check`
> passes, `run`/`build` diverge into crash/garbage). The bare tables are KEPT
> (load-bearing — see below); full retirement is deferred (`selfhost/WS2-REKEY-DIAGNOSIS.md`).
> EMPIRICAL CORRECTION: the bare arity table is **not** redundant at the call site —
> neutering the inference seed (`typecheck.mdk:8136`) under-applies cross-module calls;
> it is the sole source of constraint-slot ids (the `Scheme` carries no constraint list).


**Spec:** §8 I1 — dictionary-parameter arity is part of the binding's
*module-qualified identity*, never its bare name; conflating them "forces phantom
dictionary parameters onto an unconstrained binding, whose use sites then under-
or over-apply — a coherence and a type-preservation break."

**Finding:** arity is stored keyed by **bare `String`**:
- selfhost: `funConstraintsRef : Ref (List (String, List Int))` `typecheck.mdk:1117`;
  registered by `registerMember m` keyed by `m`; `scopeArities` keys by `fst e`
  `typecheck.mdk:8036-8051`; `dictParamName encl slot` bare `typecheck.mdk:5336`.
- OCaml: `collect_arities : program -> (ident, int) Hashtbl.t`, `ident = string`,
  `Hashtbl.replace tbl f …` `lib/dict_pass.ml:33-45`; `dict_param_name` bakes the
  bare name `lib/ast.ml:395-396`.

**Phase-134 was contained, not closed.** The cross-module collision was addressed
by (1) an unconstrained member registering **no** arity entry
(`registerMember _ [] = ()`), so an unconstrained sibling can't shadow a
constrained one, and (2) **per-scope decl-filtering** of which decls feed the
arity table (`dictPassModulesScoped` scopes to `core2 ++ prog ++ importerDecls`,
`typecheck.mdk:8070-8075`; OCaml `collect_arities (p @ importer_decls)`
`lib/eval.ml:2246-2253`). The **key is still bare-name**; `mangleUnits`
de-collides only *private* names (`typecheck.mdk:8044`), not public ones.

**Residual collision class (latent):** two **public, genuinely-constrained**
same-named bindings with **different dict-arity**, both visible in one scope
(e.g. module C imports A's `mk : Tag a => …` (1 dict) and B's
`mk : Foo a => Bar a => …` (2 dicts)). `scopeArities`/`collect_arities` over C
sees both `EDictApp`s for `mk`; last write wins → one call site under-/over-applies
→ un-run partial closure (clean exit, no output) or arity mismatch. No stdlib or
fixture triggers it today (the mitigation targets the constrained-vs-unconstrained
case, not constrained-vs-constrained).

---

### D3 — No global instance environment — **COHERENCE (latent), both impls**

**Spec:** §6 C4 / §8 I2 — `IE`/`CE` are *global* after import resolution; two
modules resolving the same predicate must consult the same instance set.

**Finding:** each module is type-checked against a **fresh per-module instance
set** = (seeded prelude ∪ this module's imports' public impls ∪ own impls).
selfhost: `checkModulesGo` seeds `baseSeed ++ importSeed prog depEnv`
(`typecheck.mdk:7717-7780`); `importSeed` admits only explicitly-imported schemes;
`checkCoherence prog` runs on **this module's** decls only (`typecheck.mdk:7351`).
OCaml: `env.impls := te.te_impls @ !(env.impls)` per imported module
(`lib/typecheck.ml:5319`); coherence over that merged-but-still-per-module set.

**Consequence:** two modules each defining `impl C T` with no import edge between
them both type-check and **embed different evidence for `C T`**; a third module
importing both would only then hit a (local) coherence check. The orphan-instance
check (`check_orphans`, `lib/typecheck.ml:4237-4268`) and the no-stdlib-import
discipline narrow the blast radius, but **there is no global `IE` and no global
coherence check** — exactly the cross-module coherence failure C4 names.

---

### D4 — Overlap escape-hatches resolve to arg-tag at runtime — **COHERENCE (narrow), both impls**

**Spec:** §6 C1 — for any ground `C τ̄`, at most one instance head matches; the
implementation must enforce or reject.

**Finding:** overlap **is** detected and rejected for equal/incomparable anonymous
impls (`OverlappingImpls`/`MultipleDefaultImpls`, `typecheck.mdk:4915-4917`;
`lib/typecheck.ml:4164-4193`). Overlap is **deliberately permitted** for
most-specific-wins (`cohStrictlyMoreSpecific`), named (`@Name`) impls, and
exactly-one-`default`. This is a defensible design choice (most-specific-wins is a
feature, not a bug). **The conformance gap is downstream:** runtime impl lookup
does **not** enforce uniqueness — `select_impl_by_head`/`findImplEntry`
(`lib/eval.ml:604-622`; `typecheck.mdk:5035-5040`) fall back to first-arg-tag-match
on a non-unique match. For a most-specific-wins pair dispatched in **return or
phantom position** (no determining argument, §5 side condition unmet), the
static checker blesses the overlap but the evaluator has no sound way to pick —
arg-tag is wrong there. The comment `lib/typecheck.ml:4494`
("`select_impl_by_head` enforces uniqueness") is **inaccurate** — it degrades to
arg-tag.

---

### D5 — Superclass acyclicity (W1) unenforced — **ROBUSTNESS, both impls**

No cycle/acyclicity check on the interface `requires` graph anywhere
(`checkSuper` verifies only that the named interface exists; `register_interface`
records `iface_supers` with no guard). `interface A requires B` /
`interface B requires A` is unchecked. OCaml's `expand_supers` is one-level with a
`seen` dedup so it won't itself loop; in selfhost supers are inert so a cycle
can't *execute* today — but **the moment superclass evidence is wired in (D1's
fix), a cyclic `requires` becomes a compile-time hang.** W1 must land *before*
super-wiring.

### D6 — Instance-resolution termination (W2) unenforced — **ROBUSTNESS, both impls**

No structural-decrease / Paterson-coverage check on instance contexts. Termination
of `implRequiresRoutesRec` / `impl_requires_routes_rec` is **comment-asserted**
("Terminates because each step structurally shrinks", `typecheck.mdk:5198`,
`lib/typecheck.ml:4385`). A non-shrinking instance
(`impl Eq (Wrap a) requires Eq (Wrap a)`) would diverge at resolution. No stdlib
trigger; adversarial only.

### D7 — No distinct `supers` field; Q param-threaded not closure-captured — **FIDELITY, both impls**

**Spec:** §2 — evidence is `{methods, supers}`; instance-context `Q` is captured
*in the method closures*. **Implementation:** superclass evidence (when it were to
exist) and instance-context `Q` share **one undifferentiated `reqs` list** inside
`VDict(key, [reqs])`, and `Q` is **threaded as leading `$dict_<m>_<slot>`
parameters** at dispatch (`applyDicts`) rather than captured in a closure.
**Observationally equivalent** at every tested depth (the closure ends up closed
over the same evidence), and it round-trips #21/#5. Not a bug; a representation
that differs from the spec letter. Folding D1's fix into a real two-field
`{methods, supers}` record would close both D7's structural gap and give `super` a
projection route (the spec-true form of D1).

### D8 — Phantom-position methods silently undispatched — **FIDELITY (latent), canonical**

A method whose class param is **absent from its type** (e.g.
`interface Named a where typeName : String`) has no argument and no result type to
fix the instance. Native `check` accepts the declaration; `run` produces garbage
(`putStrLn: not a String`) — dispatch silently does not occur. **No such method
exists in stdlib or selfhost** (every interface mentions its param in a method
signature), and the near-case `fromEntries` was fixed to classify by the receiver
typaram. Latent front-end gap; recommend rejecting at `check` or documenting as
unsupported.

### D9 — Vestigial flag-fork at `typecheck.mdk:4567` — **COSMETIC, canonical**

`argStampEnabled : Ref False` has exactly one behavioral read (`typecheck.mdk:4567`)
and one dead guard (`:8165`, branches identical). At the live read — a
standalone-shadow receiver-has-impl site — eval stamps `RNone` (→ arg-tag on the
receiver) while emit stamps `RKey<receiverHead>` (→ direct call); **both select the
same impl** (the receiver head determines the instance, §5-sound). A
representation-only difference with **no observable divergence**
(`argstamp_parity_probe.sh` 26/26 identical under both flag settings). The
*dispatch-decision* fork the `ARGSTAMP-UNIFY-PLAN` targeted is genuinely retired
(`evalDictLayerActive` has zero live readers); this residual is near-vestigial.

### D10 — Stale comments/docs contradict the binary — **DOC, both trees**

Verified-false against the audited binary; will mislead the next auditor:
- `selfhost/DISPATCH-GAPS-SCOPE.md:411-476` + `selfhost/EMITTER-GAPS.md:74` —
  claim #21 `Box (List (List Int))` SIGSEGVs. **Refuted**: native build+exec → `True`.
- `selfhost/ARGSTAMP-UNIFY-PLAN.md:95` — "emit path of `monoid_mutual_recursive`
  still fails". **Refuted**: `diff_selfhost_build` 29/0 includes it.
- `selfhost/types/typecheck.mdk:1290-1298, 4674-4683` (and ~`1295, 4550, 7954`) —
  "`argStampEnabled` OFF on the eval path → arg-tag". **Stale**: gates removed,
  arg-dispatch is unconditional on both paths.
- `lib/typecheck.ml:4494` — "`select_impl_by_head` enforces uniqueness". **False**:
  degrades to arg-tag (D4).

## 4. Empirical verification log (canonical binary, `HEAD = 14a3b58`)

| Probe | Result | Confirms |
|---|---|---|
| `impl Mon Bag` w/o `impl Sem Bag`, native `check`/`run` | rc 0 / `accepted-no-Sem-Bag` | **D1** (inert) |
| same file, OCaml oracle `check` | rejects, `MissingSuperImpl` | **D1** (divergence direction) |
| `sappend` (no impl) under `Mon a =>`, native `check` | rc 1 (caught) | D1 mitigation (call-site obligation) |
| `MkBox [[1,2],[3,4]] == MkBox …`, native `run` | `True` | #21 closed |
| same, native `build` + exec | `True` | #21 closed on **emitter** (refutes D10 stale SIGSEGV) |
| `20a5c45` ancestor of `HEAD` | true | argstamp-unify landed (§7) |

Plus, from the agent runs (independently reproduced): `pure 1 : Option Int`→`Some 1`
vs `: List Int`→`[1]` (§5 return-position); three-level `List (List (List Int))`
default →`[[[0]]]` (#5); `diff_selfhost_eval_dict` 26/0, `diff_selfhost_build`
29/0, `diff_selfhost_llvm` 181/0, `argstamp_parity_probe` 26/26 (§7);
#54/#55/#50/#21 all `run == build`.

## 5. Out of scope (frozen OCaml oracle)

These are genuine spec divergences in `lib/*.ml` but the oracle is frozen and being
retired, so they do not affect the canonical verdict:

- **§7:** OCaml `apply` makes arg-tag the *primary* dispatch mechanism on every
  `VMulti` application (`lib/eval.ml:710-772`), not a guarded residual — a real
  single-evaluator-law violation, but only between the oracle and the canonical
  binary, which the diff gates already police.
- **§3 `super`:** OCaml's `expand_supers` *flattens* a superclass into a sibling
  dict slot resolved by `assum` — sound, but re-resolution into a parallel slot,
  not the spec's projection. (It is, however, the porting source for D1's
  minimal fix: it carries the existence gate selfhost lacks.)

The forward plan to close D1–D6 is in
[`DICT-CONFORMANCE-ROADMAP.md`](DICT-CONFORMANCE-ROADMAP.md).
