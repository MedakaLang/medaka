# Stage B / Phase 3′ — findings worklist (exit-phase filing)

Defects and residuals surfaced **in passing** during this sprint. **None is in scope for
`B-2.2`.** Each row says what was reproduced, by whom, and what the exit phase owes it.

> **Filing discipline, binding:** this sprint does not file an agent's claim unreproduced.
> A row reaches the tracker only after the **orchestrator** has re-run it first-hand with an
> independently authored control. Rows below are marked accordingly.
> Repro sources are committed under `repro/` so they survive the session — `/var/tmp` does not.
>
> ✅ **DISCHARGED (RUN-P3-022).** `repro/run.sh` was smoke-tested and **was broken on first run** —
> a `set -e` killed it at F-2's first intentionally-failing `build`, silently reporting a subset as
> the whole result. That is the *"reviewers' programs are unrun by construction"* trap (three of six
> needed repair in Stage B) inside a harness written to preserve findings. Fixed, re-run: **both
> findings reproduce, matching the recorded expectations exactly.**

---

## F-1 — prelude-method-name collision: `run` correct, built binary prints a leaked pointer

**Status:** ✅ REPRODUCED by the orchestrator, with an independently written control.
**Action:** add as a **cell on #1450**, not a new issue.

`repro/f1_prelude_name/{zub,sub}.mdk` differ by one identifier. `sub` is a method of the prelude
interface `Num` (`stdlib/core.mdk:699`, arity 2); the user interface declares it at arity 1.

```
zub: check=0 run=0 [2] build=0 exec=0 [2]
sub: check=0 run=0 [2] build=0 exec=0 [69934889740256]
```

**Why a cell and not a new issue:** #1450 is *"two modules sharing an interface METHOD NAME make the
emitter define an impl with the OTHER interface's arity — check 0, run correct, built binary prints a
leaked pointer."* Same symptom, same mechanism. **What is new:** the colliding partner can be the
**auto-prelude**, so the repro needs **one file and no imports** (#1450's needs three files and an
import-order swap), and every user interface method named for a `Num` method — `add`, `sub`, `mul`,
`div`, `negate`, `abs`, `signum`, `fromInt` — is exposed with no import at all.

⚠️ **Also a live hazard for this sprint's own probes:** a `B-2.2` fixture that names a method after a
prelude method measures *this*, not dispatch identity. Cost one Phase 0 agent four probe rounds.

---

## F-2 — a function-typed impl head falls into the `noneHeadTag` bucket

**Status:** ✅ REPRODUCED by the orchestrator, with an independently written control.
**Action:** file as a new issue (**S0 + S1 in one**) after a dedup check. No open issue matched a
title search on `function|arrow|__none__|general instance|headless`.

`repro/f2_fnhead/{ab,ba,ctl}.mdk`. `ab`/`ba` differ **only** in impl-block order; `ctl` is the
control, substituting two `data` types for the two function types.

```
ab:  check=0 run=0 [(5, 5)] build=1 exec=NOBIN
ba:  check=0 run=0 [(9, 9)] build=1 exec=NOBIN
ctl: check=0 run=0 [(5, 9)] build=0 exec=0 [(5, 9)]
error: emitter failed compiling ab.mdk
runtime error [E-PANIC]: arg-tag dispatch on impl type that owns no constructors
                         (primitive receiver carries no cell tag)
```

Correct answer is `(5, 9)`, derived from the source before running. **`run` is wrong in BOTH
permutations at exit 0 with `check` clean — S0.** **`build` exits 1 with a compiler E-PANIC rather
than a diagnostic — S1, plus an eval/native divergence.** The control builds and prints correctly, so
the trigger is the function-typed head, not two-impls-per-interface.

**Root cause, DERIVED:** `headTyconTy`'s `_ => None` wildcard (`compiler/types/typecheck.mdk`,
~`:19310-19314`). `noneHeadTag` is documented everywhere as *"a type VARIABLE head has no head
tycon"*, but the arm really means **anything that is not a `TyCon` and not a `TyTuple`** — `TyFun`
included. This is `AGENTS.md`'s new-constructor-swallowed-by-a-wildcard trap one substrate over:
**audit the arms as a SET.**

---

## F-3 — same-file method-name collision across two interfaces: build arm silently wrong

**Status:** ✅ **REPRODUCED by the orchestrator**, re-authored independently (not copied from the
reporting agent's probe) with my own control. Sources: `repro/f3_method_collide/`.
**Action:** FILE NEW — the dedup discriminator is now measured, see below.

```
collide: check=0 run=1 build=0 exec=0 [47457582201144]
         run: runtime error [E-PANIC]: intToString: not an Int
         symbols: @mdk_impl_Alpha_T__ping  @mdk_impl_Beta_T__ping   ← two, DISTINCT
control: check=0 run=0 build=0 exec=0 [alpha]
         symbols: @mdk_impl_T_ping
```

**A THREE-WAY divergence in one program:** `check` accepts, `run` fails **loud** (E-PANIC), and the
**built binary exits 0 printing a raw word** where a `String` belongs. The build arm is the S0; the
run arm is merely S1.

🚨 **The measured symbols are what settle the dedup.** They are **correct and distinct**, so the
wrongness is **downstream of naming** — which separates this from **#1265** (scoped to *defaults*,
where `mdk_default_<method>_<tag>` has no interface component) and from **#1182** (order-dependent;
this reproduces **unconditionally**, with no permutation needed). The control isolates the trigger to
the second interface.

**The program:** two interfaces in one file declaring the same method name at different return types
(`Alpha.ping : a -> String`, `Beta.ping : a -> Int`), both implemented on one concrete type. The
control deletes the second interface and its impl, and nothing else.

---

## F-8 — an EFFECT-carrying impl head: `check` 0, `run` 0 correct, `build` E-PANICs

**Status:** ✅ REPRODUCED by the orchestrator, with a control differing only in the effect row.
**Action:** file as a new issue (**S1: loud breakage**, plus an eval/native divergence) after a dedup
check. Sources: `repro/f8_effect_head/`.

```
impl Sz (<Stdout> Int)   → check=0  run=0 [2]  build=1
    error: emitter failed compiling …
    runtime error [E-PANIC]: no impl of method 'sz' for type '__none__'
impl Sz Int              → check=0  run=0 [2]  build=0  exec=0 [2]   @mdk_impl_Int_sz
```

**A program that type-checks clean and runs correctly cannot be built.** One effect row apart from a
program that builds and runs fine.

**Root cause, DERIVED:** the two sides disagree on the **head tag**, not on the key.
`typecheck.headTyconTy` answers `None` for a `TyEffect` head (it matches only `TyCon`/`TyTuple`, so
the head lands in the `noneHeadTag` bucket), while `eval`/`core_ir_lower`'s `headTycon` **strips the
effect** to the inner head `Int`. The emitter then looks up `__none__` and finds nothing.

⚠️ **Related to but distinct from F-2.** F-2 is the same `_ => None` wildcard reached via a *function*
type; this is the *effect* arm, and its symptom is a build-time E-PANIC rather than an order-dependent
wrong answer. Same wildcard, two shapes — which is the argument for auditing that arm as a **SET**
rather than patching either instance.

**Not this sprint's to fix**, and explicitly out of `B-2.2-e`'s scope: `e` unifies the type
*printers* (the key), not the head *projections* (the tag). Recorded because it was found while
discharging `e`'s largest unverified assumption — which itself came back **safe** (two impls
differing only in an effect row are rejected by coherence, so the printer fold cannot change any
accepted program's words).

---

## F-4 — `expandSupersIfaceEntry` is not idempotent

**Status:** DERIVED (by a Phase 0 architecture agent), **not measured** — and it may be
unmeasurable through normal channels, which is precisely why it is worth a pin.
**Action:** file with the derivation, labelled as derived-not-measured.

`expandSupersEntry` (ids) is idempotent — it pairs against real ids. `expandSupersIfaceEntry` is
**not**: it fabricates synthetic ids (`idsForIfaceSlots`, `0,1,2,…`), so re-expanding `[Subq, Sup]`
yields a frontier `Subq@0 → Sup@0` that `cslotKey` treats as distinct from the existing `Sup@1` —
**the ifaces entry grows by one per subsequent module.** `pairSlots`' truncate-to-shorter policy
masks it, so slots stay correct and it is invisible in IR.

**Why it matters beyond tidiness:** it is the reason `B-2.2-f`'s declared-prefix count must ride the
**ids** table. A boundary marker stored on the ifaces table is **unsound by construction**.

---

## F-5 — the `ImplBuckets` second deciding population

**Status:** DERIVED, **no discriminating program built**. **Assigned to the repair round (Phase 3),
not to filing.** File only if it reproduces.

`selectReqImpl`'s `iface == ""` arm decides over `ImplBuckets` via `findImplEntry` — a **first-match,
head-tag-bucketed linear scan** (declaration order, not `min⊑`), over a population that **omits
no-requires impls**. Reachable: `routesOfMonosTop*`/`routesOfMonos` pass `iface = ""`.

**The experiment the repair round owes:** swap two impl blocks with no other change and see whether
the answer moves (the #1154 shape).

**Binding on this sprint's prose regardless of the outcome:** any sentence of the form *"the route
selectors now all read one graph-global population"* is **FALSE** at this pin and may not appear in a
`DEBT.md` row, a commit message, the PR body, or the #1113 close-out.

---

## F-6 — `sanitizeId` is not injective, and `B-2.2-e` widens the alphabet reaching it

**Status:** DERIVED. **Owed a fixture by `B-2.2-e` itself** — this one is in scope, as `e`'s
`nearest miss:`.

`sanitizeId` (`compiler/backend/private_mangle.mdk`, ~`:682-698`) maps every char outside
`[A-Za-z0-9_]` to `_`, **one-for-one and not injectively**. Today's word alphabet at that boundary is
`|` and space; the identity substitution (#1113) **adds `:`**. ⚠️ An earlier example here claimed
`a::Alpha|T|` collides with a module `a_` + interface `_Alpha`; that is **WRONG** — `safeChar` maps
each offending char to a *single* `_`, giving `a____Alpha_T_`, four underscores. The **real** hazard:
module ids are loader-derived **paths**, and `.`, `/`, `-` all sanitize to `_`, so `a.b::I|T|`,
`a/b::I|T|` and `a-b::I|T|` **all** collapse to `a_b__I_T_`. Separately the runtime word is
`hashName key` (djb2) — a second, independent collision channel.

The collision class pre-exists, but `e` widens the alphabet reaching it — a returns-nothing →
returns-something transition on a namespace nothing is watching.

⚠️ **Filing note:** file the *path* example (`a.b` / `a/b` / `a-b`), never the retracted `a_` +
`_Alpha` one. This row becomes an issue body, and the retracted example would ship a repro that does
not reproduce.

---

## F-7 — two in-tree comments are STALE and mislead in opposite directions

**Status:** DERIVED. **In scope — assigned to bite `c`** (the comment-only bite).

1. `implDictRoutesForFull` (~`:19397`) claims the `keyTable` threading is live for the nested
   `requires` re-bucketing. It is not: the recursion ends at `selectReqImpl`, which **does not take
   `keyTable` at all**. Its own sibling comment (~`:20025`) already records the truth. Sprint §4's Q1
   cited this comment as the residue's justification — so the stale comment shaped a sprint question.
2. `keyForSite`'s *"EMPIRICAL, not structural"* warning (~`:18354-18360`) names
   `emitGeneralRKey → findByTag noneHeadTag` as the tier the behaviour rests on. **That tier is
   unreachable from the arm in question**; the real tier is `emitDefaultRKey`. Relayed through two
   design documents unverified. **Correct it in place rather than relaying it a third time.**

---

## F-10 — a cross-module interface DEFAULT is silently hijacked by a same-spelled interface

**Status:** ✅ **REPRODUCED by the orchestrator** on both pre-built arms, with the control firing.
Found by the repair round (R-9). Sources: `repro/f10_default_hijack/`.
**Action:** FILE NEW (**S0: silent wrongness**). Pinnable in `must_fail_fixtures/` — `check`, `run`,
`build` and the binary all agree, so it grades `ALL_EXACT`.

```
a2    (collision present)       : base (100, 100)   branch (100, 100)   <- correct is (7, 100)
a2ctl (colliding module deleted): base 7            branch 7            <- control FIRES
a3    (both impls method-less)  : base (200, 200)   branch (200, 200)   <- correct is (7, 200)
```

**The shape:** module `di` declares `interface Tag` **with a default body** (`tag _ = 7`); module
`dimpl` has a **method-less** `impl Tag Box` that inherits it; module `other` declares its **own
same-spelled** `interface Tag` with an explicit `impl Tag Box where tag _ = 100`. Expected by
DICT §8 I4 (a class is `(module, name)`) plus §5 (a default applies only when the *selected* instance
omits the method): `(7, 100)`. Measured `(100, 100)` — **`di`'s default is never reached.**

**Mechanism, DERIVED:** the untagged interface-default registry is keyed by **bare head tag with no
interface component**, so two same-spelled interfaces' defaults at one head collapse
**last-write-wins** — the `installConsts`/`findCell` hazard `AGENTS.md` documents for module frames,
reappearing in the default tier.

**Identical on both arms => PRE-EXISTING. The sprint exposed it, did not cause it.**

🚨 **Dedup, and this is a THIRD distinct sub-shape — do not merge it:**
- **not #1182** — that is *differently*-spelled interfaces sharing a **method name**, single-file, and
  **order-dependent**. This is *same*-spelled interfaces and is **not** order-dependent (swapping the
  imports changes nothing; the colliding module is topologically later in both orders).
- **not `p02`/D-2** — that residual **is** order-dependent and involves two explicit impls. Here the
  hijacked side is a **default**.
- **not #1265** — that is two same-named *defaults* colliding on `mdk_default_<method>_<TAG>`. Here
  one side is an **explicit impl body** that wins over another interface's default.

⚠️ **It also sharpens `DEBT.md` row `c`.** That row says deleting `fromOption tag` *"breaks every
cross-module method-less impl inheriting an interface default."* True — and the complement is now
measured: **keeping it silently breaks them anyway the moment a same-spelled interface shares the
head.**
