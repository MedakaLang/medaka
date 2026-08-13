# Stage B / Phase 3′ — findings worklist (exit-phase filing)

Defects and residuals surfaced **in passing** during this sprint. **None is in scope for
`B-2.2`.** Each row says what was reproduced, by whom, and what the exit phase owes it.

> **Filing discipline, binding:** this sprint does not file an agent's claim unreproduced.
> A row reaches the tracker only after the **orchestrator** has re-run it first-hand with an
> independently authored control. Rows below are marked accordingly.
> Repro sources are committed under `repro/` so they survive the session — `/var/tmp` does not.
>
> ⏳ **OWED, next quiescent window:** `repro/run.sh` has been **written but not yet run** — a writer
> is live, so measuring now would grade a possibly half-built binary. An unrun harness is the
> *"read-only reviewers' programs are unrun by construction"* trap (three of six needed repair in
> Stage B), so it gets smoke-tested before anything cites it.

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

**Status:** ⚠️ **NOT yet reproduced by the orchestrator.** Reported by a Phase 0 agent with its
probe under `/var/tmp/p3/p07/`. **Do not file until re-run first-hand** (and copy the repro into
`repro/` when doing so).

Two interfaces in **one file** declaring the same method name at different return types
(`Alpha.ping : a -> String`, `Beta.ping : a -> Int`), both implemented on one type:
`check` **exit 0** · `run` **exit 1** E-PANIC (`intToString: not an Int` — eval narrowed to Beta) ·
`build` **exit 0**, emitting *correct* distinct symbols (`@mdk_impl_Alpha_T__ping`,
`@mdk_impl_Beta_T__ping`) with the call site reaching Alpha's · **built binary exit 0 printing a raw
word** where a string belongs. Control with `Beta` deleted: clean on every arm.

**Dedup note:** adjacent to but not obviously **#1265**, which is scoped to *defaults*
(`mdk_default_<method>_<tag>` has no interface component). Here both impls are concrete **and the
symbols are distinct**, so the wrongness is downstream of naming. Needs its own triage.

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
`|` and space; #1182's fix **adds `:`**. So `a::Alpha|T|` → `a__Alpha_T_`, and a module `a_` with
interface `_Alpha` sanitizes to the **same symbol**. The collision class pre-exists, but `e` widens
the alphabet reaching it — a returns-nothing → returns-something transition on a namespace nothing
is watching.

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
