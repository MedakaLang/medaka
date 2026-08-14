# Stage B / Phase 3′ — EXIT-PHASE FILINGS (drafted, NOT filed)

**Author:** R-11. **Status:** drafting only — **zero `gh` writes were made**, no issue was created,
commented on, or relabelled. Every body below is ready to paste; the close-out executes them.

**Base pin:** `68f84bf1` (RUN-P3-001). **Source:** `FINDINGS.md` F-1…F-10, `DECISIONS.md`,
`CLOSE-OUT.md`, `DEBT.md`, `PR-BODY.md`, `repro/`.

## Filing discipline applied (binding, not restated for decoration)

A row reaches the tracker only if the **orchestrator** reproduced it first-hand with an
independently authored control. **No row's status was upgraded to make it fileable.** Where
`FINDINGS.md`'s own `Action:` line conflicts with that rule, the rule wins and the conflict is
named (see F-4).

| row | status in FINDINGS | disposition here |
|---|---|---|
| F-1 | ✅ orchestrator-reproduced, IR-derived routing | **COMMENT (cell) on #1450** — §1 |
| F-2 | ✅ orchestrator-reproduced + own control | **NEW ISSUE, S0** — §2 |
| F-3 | ✅ orchestrator-reproduced, re-authored + own control | **NEW ISSUE, S0** — §3 |
| F-8 | ✅ orchestrator-reproduced + effect-row control | **NEW ISSUE, S1** — §4 |
| F-10 | ✅ orchestrator-reproduced, both arms, control fires | **NEW ISSUE, S0** — §5 |
| F-6 | DERIVED + RUN-P3-030 measurement | **COMMENT on #347** (`needs-repro`) — §6 |
| F-4 | DERIVED, **not measured** | **BLOCKED** — §9 |
| F-5 | DERIVED, no discriminating program; probe did **not** discriminate | **BLOCKED** — §9 |
| F-7 | DERIVED, in scope, assigned to bite `c` | **NOT A FILING** — §9 |
| F-9 | **does not exist** | numbering gap — §9 |

Plus four items that are not `FINDINGS` rows: §7 (`keyTable`/`KeyBuckets`), §8 (`b2` drop),
§10 (#1068), §11 (#1182 fixture recommendation).

---

# §1 — F-1 → COMMENT (cell) on **#1450**, not a new issue

**Routing is IR-DERIVED, not symptom-matched** (RUN-P3-038 / OWED-2,
`DECISIONS.md:1483-1497`). R-4 flagged that the original *"same mechanism as #1450"* rested on a
symptom (leaked pointer at exit 0) where #1450's own filing read the **arity off the IR** — and
that if the arity were correct, a cell would bury a second defect inside that issue. It was then
measured.

### Comment body (paste as-is)

> **A THIRD collision partner for this table: the AUTO-PRELUDE. One file, no imports.**
>
> This issue's repro needs three files and an import-order swap. The same mechanism fires with
> **one file and zero imports**, because the colliding partner can be `stdlib/core.mdk`'s prelude
> interface `Num` — which is in scope in every program by construction.
>
> **Repro** (`repro/f1_prelude_name/sub.mdk`, committed in the Phase 3′ sprint record):
>
> ```medaka
> interface Zub a where
>   sub : a -> Int
> data T = T
> impl Zub T where
>   sub _ = 2
> both : Zub a => a -> Int
> both x = sub x
> main = println (both T)
> ```
>
> `sub` is a method of the prelude interface `Num` (`stdlib/core.mdk:699`) at **arity 2**; this
> interface declares it at **arity 1**.
>
> **Control** (`zub.mdk`) is byte-identical except the method is named `zub`, which collides with
> nothing in the prelude.
>
> | file | check | run | build | executed binary |
> |---|---|---|---|---|
> | `zub` (control) | 0 | 0, `2` | 0 | 0, **`2`** |
> | `sub` | 0 | 0, `2` | 0 | 0, **`69934889740256`** |
>
> **MEASURED** 2026-08-14 on a cold `make medaka` at `68f84bf1`, `MEDAKA_STRICT=1`, every arm
> redirected to a file with `$?` read directly (never through a pipe).
>
> **The IR, read the way this issue read it** (RUN-P3-038):
>
> ```
> zub (control): define i64 @mdk_impl_T_zub(i64 %arg0)              <- ONE param, correct
> sub          : define i64 @mdk_impl_T_sub(i64 %arg0, i64 %arg1)   <- TWO
>                (cf. define i64 @mdk_impl_Int_sub(i64, i64) — Num.sub's arity)
> ```
>
> The user interface declares `sub : a -> Int`, arity 1. The emitter defined its impl with
> **`Num.sub`'s arity 2**, and the call site passes two args to match. That is this issue's
> `methodIfaceTableRef` mechanism verbatim — bare-name key, `Num`'s entry wins, `methodArityOf`
> returns 2, the define is emitted with 2 params and the extra one is uninitialised.
>
> **What this adds to the fix's scope:** the exposed surface is not "two user modules that happen
> to share a method name". **Every user interface method named for a `Num` method — `add`, `sub`,
> `mul`, `div`, `negate`, `abs`, `signum`, `fromInt` — is exposed with no import at all**, and the
> same holds for every other prelude interface's method names. A fix that scopes the table by
> module must treat the prelude as a module, not as an ambient exception.
>
> ⚠️ **Live hazard for probe authors, worth recording here:** a dispatch fixture whose method is
> named after a prelude method measures *this*, not dispatch identity. It cost one Phase 3′ agent
> four probe rounds.

### Pin recommendation

#1450's `Owed` section already requires a `must_fail_fixtures/` pin that **asserts on the built
binary**, since `check` and `run` are green. The leaked value is **not byte-stable** (this issue
records *"a different value on every execution"*), so a stdout golden cannot be used directly.

**Recommendation — make the defect deterministic instead of declaring it unpinnable:** change the
entry to `main = println (both T == 2)`. On a correct compiler that prints `True`; under the
defect the second (garbage) argument makes the comparison fail and it prints `False` —
byte-stable, gradeable with the `build-run` verb, self-draining the moment the arity is fixed.
🚧 **UNVERIFIED — one measurement owed** (that the `== 2` form does not change the emitted call
shape and still reproduces). If it does not reproduce, fall back to `MUST-FAIL-NOT-PINNABLE.txt`
with reason *"observable value is a nondeterministic leaked pointer"* and pin the arity from the
IR in a `test/llvm_fixtures/` golden instead.

---

# §2 — F-2 → **NEW ISSUE**

### Title

```
S0: a FUNCTION-TYPED impl head falls into headTyconTy's `_ => None` wildcard — two impls at
different arrow heads collapse into one noneHeadTag bucket, run is wrong in BOTH orders at
exit 0 and build E-PANICs
```

### Body

> **`headTyconTy`'s `_ => None` arm is documented everywhere as *"a type VARIABLE head has no head
> tycon"*. It really means **anything that is not a `TyCon` and not a `TyTuple`** — `TyFun`
> included.** Two impls of one interface at two *different* function-typed heads are therefore
> indistinguishable to dispatch: `run` answers the same impl for both call sites, in **both**
> declaration orders, at exit 0 with `check` clean; `build` exits 1 with a compiler E-PANIC rather
> than a diagnostic.
>
> Found in passing during the Stage B / Phase 3′ sprint. **Not caused by it** — no sprint bite
> touches this projection.
>
> ## Repro — 3 files; `ab`/`ba` differ ONLY in impl-block order, `ctl` is the control
>
> ```medaka
> -- ab.mdk
> interface Sz a where
>   sz : a -> Int
> impl Sz (Int -> Int) where
>   sz _ = 5
> impl Sz (Bool -> Bool) where
>   sz _ = 9
> f : Int -> Int
> f x = x + 1
> g : Bool -> Bool
> g b = b
> main = println (sz f, sz g)
> ```
>
> `ba.mdk` is byte-identical except the two `impl` blocks are swapped.
> `ctl.mdk` is `ab.mdk` with two `data` types (`W`, `V`) substituted for the two function types, so
> the heads are real tycons — **independently authored, not adapted from the reporting agent's
> probe**.
>
> ## Measured — cold `make medaka` at `68f84bf1`, `MEDAKA_STRICT=1`, no piped exit codes
>
> | file | check | run | build | executed binary |
> |---|---|---|---|---|
> | `ab` | 0 | **0, `(5, 5)`** | **1** | NOBIN |
> | `ba` (order swapped) | 0 | **0, `(9, 9)`** | **1** | NOBIN |
> | `ctl` (two `data` heads) | 0 | 0, `(5, 9)` | 0 | 0, `(5, 9)` |
>
> ```
> error: emitter failed compiling ab.mdk
> runtime error [E-PANIC]: arg-tag dispatch on impl type that owns no constructors
>                          (primitive receiver carries no cell tag)
> ```
>
> ## Correct answer, hand-derived from the source BEFORE running
>
> `f : Int -> Int` and `g : Bool -> Bool` are distinct, fully **ground** types. Each call site's
> goal is closed, exactly one impl matches each, and no ambiguity or specificity question arises.
> **Correct is `(5, 9)`** — which the control produces on every arm, and which **neither**
> permutation of the defective program produces. This is not a case where one of two answers is
> defensible: both `(5, 5)` and `(9, 9)` are wrong.
>
> ## What the control establishes
>
> `ctl.mdk` differs from `ab.mdk` in exactly one thing — the two impl heads are `data` types rather
> than function types — and is correct on all four channels. So the trigger is the **function-typed
> head**, not "two impls of one interface", not the tuple-returning `main`, not the interface shape.
>
> ## Mechanism, DERIVED
>
> `compiler/types/typecheck.mdk:19452-19456`:
>
> ```medaka
> headTyconTy : Ty -> Option HeadKey
> headTyconTy t = match headTyNode t
>   TyCon { tyConName = n, tyConOrigin = o } => Some (headKeyOfCon o n)
>   TyTuple ts => Some (headKeyOfCon OriginBuiltin (tupleHeadTagTc (listLen ts)))
>   _ => None
> ```
>
> `headTyNode` (`:19433-19435`) peels `TyApp` spines only, so a `TyFun` head arrives intact at the
> wildcard and answers `None`. Consumers turn that into `noneHeadTag`
> (`fromOption noneHeadTag (headTyconHead …)`, e.g. `compiler/ir/core_ir_lower.mdk:1306`, `:1407`;
> `compiler/eval/eval.mdk:309`, `:1974`), so **both** impls register under one bucket and selection
> degrades to a first-match scan over it — which is why the answer tracks declaration order.
> `headTyconNameTy` (`:19479-19483`) is the bare-name residual of the same projection and carries
> the **same three arms**, so it has the same hole.
>
> ## Two severities in one program, filed together because one arm fixes both
>
> - **S0** — `run` returns a wrong value at exit 0 with `check` clean, in both orders.
> - **S1** — `build` exits 1 with an internal E-PANIC instead of a diagnostic; and eval/native
>   **diverge** (eval answers, native cannot compile).
>
> ## Not a duplicate
>
> - **Not #1180** (OPEN, S0). Closest neighbour: same E-PANIC string, same `headTyconTy`-answers-
>   `None` family. **The trigger and the fix direction are opposite.** #1180's head is a bare
>   `TyVar` (`impl Sz a`) — the case the wildcard *is documented for* — its goal is **undetermined**
>   at quiescence, and its correct verdict is the **rejection** its own positive control already
>   produces; its fix site is `implHeadTagForIface`'s consumer (`:12268-12270`) and is an
>   accept→reject narrowing. Here **every head is a concrete, ground type**, every goal is closed,
>   the program is **legal and must be ACCEPTED** with `(5, 9)`, and the fix site is
>   `headTyconTy`'s arm set itself. Applying #1180's fix leaves this program wrong; applying this
>   one leaves #1180 wrong.
> - **Not #1128** (CLOSED) — a fully-general `impl C a` alongside a concrete impl at a parametric
>   head. Bare-TyVar again, and no function type participates.
> - **Not #1182 / #1265 / #1450** — none involves a function-typed head; all three turn on a shared
>   *name* (method, interface, or symbol). Here the two impls share no name at all.
> - **Not #1113/#1122's route-word work.** The word is downstream; the *tag* is already collapsed
>   before any word is minted.
> - Title searches run (all zero relevant hits, 2026-08-14):
>   `gh search issues --repo MedakaLang/medaka --state open 'noneHeadTag' / 'headTyconTy' /
>   'impl on a function type'`, plus a scan of all ~370 open issue titles for
>   `function|arrow|__none__|headless|head tag|impl head`.
>
> ## Relationship to the sibling row
>
> The **effect-carrying impl head** hits the *same wildcard* by a different route and produces a
> different symptom (build-time E-PANIC with `run` correct). It is filed separately because the two
> need **different fixes**: this one needs the arm to give `TyFun` a tag; that one needs two head
> *projections* to agree. **The argument both make together is to audit that arm as a SET** —
> `AGENTS.md`'s new-constructor-swallowed-by-a-wildcard trap, one substrate over.
>
> ⚠️ **A third candidate arm was measured NOT to be a defect.** `eval.headTycon` also strips
> `TyConstrained` while `headTyconTy` does not (`compiler/eval/eval.mdk:513-519`). Measured on both
> arms with two live controls (RUN-P3-045): a constrained impl head is clean on every channel,
> because stripping a constraint from `Eq a => a` yields `a`, which is **still headless** — both
> sides answer headless and **agree**. The divergence needs the stripped result to be concrete on
> one side and headless on the other, which only the effect arm produces. **The live set is two,
> not three.**

### Pin recommendation — `test/must_fail_fixtures/`, 3 cases + control

`ALL_EXACT` does **not** apply (the channels disagree by construction). Pin:

1. `run` on `ab.mdk`, graded exit 0 + stdout `(5, 5)` — the S0.
2. `run` on `ba.mdk`, graded exit 0 + stdout `(9, 9)` — the permutation twin. **Both arms are
   required**: a single-arm pin would read as "one answer is wrong", where the assertable defect is
   that *no* order produces the correct one.
3. `build` on `ab.mdk`, graded exit 1 — the S1. (`build` is the only verb that grades the emitter's
   own exit; `test/diff_compiler_must_fail.sh:193-198`.)
4. `ctl.mdk` as the fixture's **control**, exit 0 — the harness fails the row if a control breaks
   (`:541`), which is what keeps the pin from passing vacuously.

All four are deterministic. The row self-drains: fixing the arm makes 1–3 produce `(5, 9)`/exit 0
and the gate goes red naming this issue.

---

# §3 — F-3 → **NEW ISSUE**

### Title

```
S0: two interfaces in ONE file declaring the same method at different return types — the built
binary prints a raw word where a String belongs at exit 0, while run E-PANICs and check is clean
(the emitted symbols are CORRECT and distinct: the wrongness is downstream of naming)
```

### Body

> **A three-way divergence in one program.** `check` accepts. `run` fails **loud** with an
> E-PANIC. The **built binary exits 0 printing a raw machine word where a `String` belongs.** The
> build arm is the S0; the run arm is merely S1.
>
> Re-authored first-hand by the Phase 3′ orchestrator (not copied from the reporting agent's
> probe), with an independently written control. Found in passing; **not caused by the sprint**.
>
> ## Repro — one file
>
> ```medaka
> interface Alpha a where
>   ping : a -> String
>
> interface Beta a where
>   ping : a -> Int
>
> data T = T
>
> impl Alpha T where
>   ping _ = "alpha"
>
> impl Beta T where
>   ping _ = 7
>
> main = println (ping T)
> ```
>
> **Control** — the same file with the second interface and its impl deleted, nothing else changed.
>
> ## Measured — cold `make medaka` at `68f84bf1`
>
> | file | check | run | build | executed binary |
> |---|---|---|---|---|
> | `collide` | 0 | **1**, `runtime error [E-PANIC]: intToString: not an Int` | 0 | **0, `47457582201144`** |
> | `control` | 0 | 0, `alpha` | 0 | 0, `alpha` |
>
> Emitted symbols:
>
> ```
> collide: @mdk_impl_Alpha_T__ping   @mdk_impl_Beta_T__ping    <- TWO, DISTINCT, both correct
> control: @mdk_impl_T_ping
> ```
>
> ## Correct answer, hand-derived
>
> `DICT-SEMANTICS` §8 I4 makes a class `(module, name)`, so `Alpha` and `Beta` are two unrelated
> classes that merely share a method spelling. `main = println (ping T)` is therefore **ambiguous
> at the occurrence** — two in-scope interfaces declare `ping`, at incompatible return types, both
> implemented at `T`. The correct verdict is a **resolve/typecheck rejection naming the ambiguity**,
> not a value. What must *not* happen is any of the three things measured: silent acceptance, a
> runtime panic from the wrong interface's projection, and a binary that prints an unprintable word.
>
> ⚠️ Whichever of "reject" or "pick `Alpha` by scope" the language ultimately adopts, **the binary's
> answer is wrong under both** — it is not a `String` at all.
>
> ## What the control establishes
>
> Deleting the second interface and its impl — the only change — makes every channel correct. So
> the trigger is the second interface, not the method's return type, the `data` declaration, or
> `println`.
>
> ## Why this is not #1265 or #1182 — the SYMBOLS are what settle it
>
> - **Not #1265.** That issue is scoped to **defaults**: two same-named defaults collapse because
>   `mdk_default_<method>_<tag>` (`compiler/backend/llvm_emit.mdk:1342`) has **no interface
>   component**, so two bodies have one symbol to live under. Here **both impls have explicit
>   bodies**, the emitter mints **two distinct, correctly-qualified symbols**
>   (`@mdk_impl_Alpha_T__ping`, `@mdk_impl_Beta_T__ping`), and no `mdk_default` symbol
>   participates. #1265's fix (put the interface identity in the default's symbol) leaves this
>   unchanged, because this program's symbols already carry it. **The wrongness is downstream of
>   naming.**
> - **Not #1182.** That issue's defect is **order-dependent** — its own table shows swapping the two
>   `impl` blocks flips the answer between `1` and `2`, and its assertable property is the
>   reordering differential. **This reproduces unconditionally**, with no permutation needed, and
>   its three channels *disagree with each other* (which #1182's do not: #1182 is
>   check-clean/run-and-build-agreeing). #1182's candidate-set fix in `matchingEntries` /
>   `pickMostSpecificEntry` cannot explain a binary that prints a raw word while `run` panics.
> - **Not #1450.** That is a bare-name **arity** table; the symbols there are correct but the
>   *arity* is wrong. Here the arity is not in question and both symbols are correct.
> - **Not #1047** (CLOSED) — same interface *name*, different implementing types.
>
> ⚠️ **Stated as a discrimination, not an identity.** What is established is that this program's
> emitted symbols are correct and distinct, which is incompatible with #1265's mechanism, and that
> it is not order-dependent, which is incompatible with #1182's assertable property. The **exact**
> site downstream of naming that mis-selects has **not** been derived — see `Owed` below.
>
> ## Owed
>
> The fix site. The measurement narrows it to *after* symbol minting: read the IR call site with
> `medaka build --keep-ir` and identify which of the two correct symbols the `println` call
> reaches, and where the `String`/`Int` slot decision is made. That is a ~10-minute derivation
> with `core_ir_typed_modules_dump_main`, not a design question.

### Pin recommendation — `must_fail_fixtures/` for the `run` arm; the binary arm is likely NOT pinnable

- **Pinnable now:** `run` on `collide.mdk`, graded **exit 1** + the E-PANIC line, with
  `control.mdk` as the control (exit 0, `alpha`). Deterministic, self-draining.
- **The S0 channel is the one that resists pinning.** `47457582201144` is a raw word in a `String`
  slot — the same class as #1450's *"different value on every execution"*. 🚧 **One measurement
  owed: execute the built binary 3× and compare.** If stable, add a `build-run` case graded on that
  exact stdout. If not, add a row to `test/MUST-FAIL-NOT-PINNABLE.txt` with reason
  *"the S0 channel's observable is a nondeterministic raw word; only the run arm is byte-stable"*
  and cross-reference the run pin. **Do not pin a nondeterministic value** — it turns a real defect
  into a flaky gate and the next agent blind-retries it.

---

# §4 — F-8 → **NEW ISSUE**

### Title

```
S1: an EFFECT-carrying impl head makes build E-PANIC on a program that checks clean and runs
correctly — eval's headTycon strips TyEffect to the inner head while typecheck's headTyconTy
answers None, so the emitter looks up a __none__ bucket nothing registered under
```

### Body

> **A program that type-checks clean and runs correctly cannot be built.** It is one effect row
> apart from a program that builds and runs fine. The two sides disagree on the **head tag** — not
> on the key.
>
> Found while discharging bite `B-2.2-e`'s largest unverified assumption (which came back **safe**;
> this is an adjacent defect, not that assumption failing). **Explicitly out of `e`'s scope:** `e`
> unifies the type *printers* (the key), not the head *projections* (the tag). Not caused by the
> sprint.
>
> ## Repro
>
> ```medaka
> interface Sz a where
>   sz : a -> Int
>
> impl Sz (<Stdout> Int) where
>   sz _ = 2
>
> main = println (sz 0)
> ```
>
> **Control** — byte-identical except the impl head is plain `Int` rather than `<Stdout> Int`.
> One effect row is the only difference.
>
> ## Measured — cold `make medaka` at `68f84bf1`
>
> | file | check | run | build | executed binary | symbol |
> |---|---|---|---|---|---|
> | `impl Sz (<Stdout> Int)` | 0 | 0, `2` | **1** | NOBIN | — |
> | `impl Sz Int` (control) | 0 | 0, `2` | 0 | 0, `2` | `@mdk_impl_Int_sz` |
>
> ```
> error: emitter failed compiling …
> runtime error [E-PANIC]: no impl of method 'sz' for type '__none__'
> ```
>
> ## Correct answer, hand-derived
>
> The program has exactly one interface, one impl, one call site, and a closed goal. `sz 0` selects
> the only impl and must yield **`2`** — which `run` already produces and the control produces on
> every channel. There is no ambiguity, no overlap, and nothing for the compiler to reject.
> **Correct is: `build` exits 0 and the binary prints `2`.** If the language instead decides an
> effect row is not admissible in an impl head, the correct answer is a **diagnostic at `check`** —
> not a green `check`, a correct `run`, and an internal panic from the emitter.
>
> ## What the control establishes
>
> Deleting the effect row — the only change — makes `build` succeed and the binary print `2`. So
> the trigger is the effect row in the impl head and nothing else. The control also proves the
> probe is live rather than measuring an unrelated breakage.
>
> ## Mechanism, DERIVED — two head projections that disagree
>
> `compiler/eval/eval.mdk:513-519` **strips the effect** to the inner head:
>
> ```medaka
> headTycon : Ty -> Option String
> headTycon (TyCon { tyConName = n }) = Some n
> headTycon (TyApp a _) = headTycon a
> headTycon (TyConstrained _ t) = headTycon t
> headTycon (TyEffect _ _ t) = headTycon t      <- strips: answers Some "Int"
> headTycon (TyTuple ts) = Some (tupleHeadTag (listLen ts))
> headTycon _ = None
> ```
>
> `compiler/types/typecheck.mdk:19452-19456` does **not** — it matches only `TyCon`/`TyTuple`, so a
> `TyEffect` head reaches `_ => None` and lands in the `noneHeadTag` bucket. The definition side
> registers under one tag and the emitter looks up the other, finds nothing, and panics.
>
> The tree's own comment at `compiler/eval/eval.mdk:496-502` already records the asymmetry —
> *"`headTycon` (below) strips `TyEffect` AND `TyConstrained` to the inner head while typecheck's
> `headTyconTy` does not … so the two sides can still disagree on the TAG"* — and explicitly warns
> *"Do not read that list as complete."* This issue is that warning firing.
>
> ## Not a duplicate
>
> - **Distinct from the `TyFun` row filed alongside this one**, and they need **different fixes**.
>   Both reach `headTyconTy`'s `_ => None`, but: that one is two impls at two *arrow* heads
>   collapsing into one bucket (wrong VALUE at exit 0, order-dependent, `build` panics); this is a
>   **single** impl whose two sides project **different** tags (`run` CORRECT, `build` panics). Fix
>   there = give `TyFun` a tag in that arm. Fix here = make the two head projections agree on
>   `TyEffect`. Neither fix addresses the other. **Filed separately; the shared argument is to audit
>   that arm as a SET.**
> - ⚠️ **A third candidate arm is NOT a defect and must not be filed** (RUN-P3-045, MEASURED on both
>   arms with the effect arm as a live positive control and the plain arm as a clean negative
>   control): `TyConstrained` is stripped by `headTycon` and not by `headTyconTy`, but stripping a
>   constraint from `Eq a => a` yields `a`, which is **still headless** — both sides answer headless
>   and **agree**, and a single headless impl is a direct hit. The rule that generalizes: *an
>   asymmetry in the source is not a defect until the two sides are shown to answer differently on a
>   program.*
> - **Not #1180** — that is a bare-`TyVar` head with an *undetermined* goal, whose correct verdict is
>   rejection. This goal is closed and the correct verdict is a value.
> - **Not #1103 / #1100 / #1098 / #1095** (the effect-laundering S0 family) — those are soundness
>   holes where a pure-typed value performs an effect at `check`-green. This is a build-time crash on
>   a program whose typing is not in dispute.
> - Title/full-text searches run: `noneHeadTag`, `headTyconTy`, plus a scan of all open titles for
>   `effect.*impl head|impl head.*effect`. No match.
>
> ## Note on the two-impl case, for whoever fixes this
>
> Two impls differing **only** in an effect row are **rejected by coherence** (*"Overlapping impls
> of Sz: Int and Int can match the same type"*, exit 1 on `check` AND `run` — and note the
> diagnostic strips the row too), so this is reachable only for a **lone** effect-headed impl.
> Recorded so the fixer does not go looking for a two-impl witness that cannot exist.

### Pin recommendation — `must_fail_fixtures/`, `build` verb + control

Not `ALL_EXACT` (`check`/`run` are green, `build` is not). Pin the `build` verb on
`effect_head.mdk`, graded **exit 1**, with `control.mdk` as the control at exit 0. Both channels
are deterministic. Self-draining: when the projections agree, `build` exits 0 and the gate reds
naming this issue. Optionally add a `run` case graded exit 0 + `2` to pin the eval/native
divergence explicitly — that arm is what makes the row read as a divergence rather than as "this
program is unsupported".

---

# §5 — F-10 → **NEW ISSUE**

### Title

```
S0: a cross-module interface DEFAULT is silently hijacked by a same-spelled interface at the same
head — a method-less impl inheriting `di::Tag`'s default answers `other::Tag`'s explicit impl body,
check/run/build/binary all agree, NOT order-dependent
```

### Body

> A module's `interface` **default body** is never reached when a **different module** declares a
> same-spelled interface with an explicit impl at the same head. All four channels agree on the
> wrong answer at exit 0, with no diagnostic.
>
> **PRE-EXISTING**: measured identically on both the Phase 3′ base arm (`68f84bf1`) and the branch.
> The sprint exposed it; it did not cause it.
>
> ## Repro — four files
>
> `di.mdk` — the interface **with a default body**:
> ```medaka
> export interface Tag x where
>   tag : x -> Int
>   tag _ = 7
> ```
>
> `dimpl.mdk` — a **method-less** impl that inherits it:
> ```medaka
> import di.{Tag(..), tag}
>
> public export data Box = Box
>
> impl Tag Box where
>
> export dtag : Box -> Int
> dtag b = tag b
> ```
>
> `other.mdk` — a **different module's own same-spelled** interface, with an explicit impl:
> ```medaka
> import dimpl.{Box(..)}
>
> export interface Tag x where
>   tag : x -> Int
>
> impl Tag Box where
>   tag _ = 100
>
> export otag : Box -> Int
> otag b = tag b
> ```
>
> `main.mdk`:
> ```medaka
> import dimpl.{Box(..), dtag}
> import other.{otag}
>
> main = println (dtag Box, otag Box)
> ```
>
> ## Correct answer, hand-derived from the spec — NOT captured from an engine
>
> `docs/spec/DICT-SEMANTICS.md` §8 **I4**: a class is `(module, name)`, so `di::Tag` and
> `other::Tag` are two unrelated classes that merely share a spelling. §5: an interface default
> fills a slot **only when the SELECTED instance omits the method**. `dtag` calls `tag` in a module
> where the selected instance is `di::Tag Box`, which omits the method, so `di::Tag`'s default
> body applies → **7**. `otag` calls `tag` where the selected instance is `other::Tag Box`, whose
> explicit body gives **100**.
>
> **Correct: `(7, 100)`.**
>
> ## Measured — both pre-built arms
>
> | program | base | branch | correct |
> |---|---|---|---|
> | `a2` (collision present) | **`(100, 100)`** | **`(100, 100)`** | `(7, 100)` |
> | `a2ctl` (colliding module deleted) | `7` | `7` | `7` — **control FIRES** |
> | `a3` (both impls method-less) | **`(200, 200)`** | **`(200, 200)`** | `(7, 200)` |
>
> `check`, `run`, `build` and the executed binary **all agree** on the wrong value at exit 0, with
> zero diagnostics.
>
> ## What the control establishes
>
> `a2ctl` deletes `other.mdk` and nothing else: the answer becomes `7`, the default body's value.
> So `di::Tag`'s default is reachable and correct in isolation, and the presence of an unrelated
> module's same-spelled interface is what suppresses it. The control fires, so a wrong `a2` is a
> real answer rather than a dead probe.
>
> ## Mechanism, DERIVED
>
> The untagged interface-default registry is keyed by **bare head tag with no interface
> component**, so two same-spelled interfaces' entries at one head collapse **last-write-wins** —
> the `installConsts`/`findCell` hazard `AGENTS.md` documents for module frames, reappearing in the
> default tier. Relevant sites: `ifaceIdsAtTag` (`compiler/ir/core_ir_lower.mdk:1326-1333`) returns
> the identity of **every** impl at a tag; `narrowDefaults` / `defaultOwnedBy`
> (`compiler/backend/llvm_emit.mdk:1301-1304`) filters against that set; `ownDefault` /
> `ifaceIdsAtTagE` (`compiler/eval/eval.mdk:315-322`, `:1041-1043`) is the eval peer.
>
> ⚠️ **Labelled DERIVED, not measured.** The measurement establishes the wrong answer and its
> trigger; the exact registry write that loses is **not** read off the IR here. **Owed:**
> `medaka build --keep-ir` plus `core_ir_typed_modules_dump_main` on `a2`, to show which entry the
> `dtag` call site reaches. Do not treat the mechanism paragraph as settled.
>
> ## Not a duplicate — this is a THIRD distinct sub-shape
>
> - **Not #1182.** That is *differently*-spelled interfaces sharing a **method name**, in a
>   **single file**, and it is **order-dependent** (its own table flips between `1` and `2` when the
>   two `impl` blocks are swapped). This is *same*-spelled interfaces across **modules** and is
>   **not order-dependent**: swapping the imports changes nothing, because the colliding module is
>   topologically later in both orders. #1182's assertable property (a reordering differential) does
>   not exist here.
> - **Not #1265.** That is two interfaces' **defaults** colliding on `mdk_default_<method>_<tag>` —
>   both impls method-less, both sides a default, and its own boundary control shows it is fixed by
>   putting the interface identity in the *default's* symbol. Here **the hijacking side is an
>   explicit impl body**, not a default: the losing side is a default and the winning side is not,
>   so a default-symbol re-key does not describe it. Also #1265's repro uses **differently**-named
>   interfaces (`Speak`/`Greet`) and is order-dependent (`A-default|A-default` ↔
>   `B-default|B-default`); this uses the **same** name and is not.
> - **Not `p02`/D-2** (the sprint's own unfiled residual). That is **order-dependent** and involves
>   **two explicit impls**. Here the hijacked side is a **default**.
> - **Not #1514** (drained by this sprint) — two modules each with their **own** impl at their
>   **own** head; no default participates, and its shape now answers correctly.
> - **Not #1047** (CLOSED) — same interface name, *different* implementing types.
>
> ⚠️ **Dedup confidence is lower on the `a3` arm than on `a2`.** With **both** impls method-less
> (`a3`, measured `(200, 200)`, correct `(7, 200)`), both sides *are* defaults, which is much closer
> to #1265 — the only difference being that the two interfaces share a **spelling**, the half #1264
> was supposed to have fixed via the `Conflicting impl <Iface>` guard. **Recommendation: file the
> `a2` shape as this issue and record `a3` in the body as a second observable, explicitly flagged as
> *possibly #1265's mechanism with a same-spelled pair*, rather than asserting it is distinct.** If
> triage decides `a3` is #1265, that costs a comment; asserting it is new and being wrong buries a
> second defect.
>
> ## It sharpens an existing debt row
>
> `DEBT.md` row `c` says deleting `fromOption tag` *"breaks every cross-module method-less impl
> inheriting an interface default."* True — and the complement is now measured: **keeping it
> silently breaks them anyway the moment a same-spelled interface shares the head.**

### Pin recommendation — `must_fail_fixtures/`, `ALL_EXACT`

Every channel agrees, and the value is deterministic. Pin the four-file `a2` program with the
`build-run` verb graded on stdout `(100, 100)` at exit 0, plus a `run` case graded identically, plus
`a2ctl` as the fixture's control (`7`, exit 0). This is the cleanest pin in this batch: it
self-drains to `(7, 100)` the moment the default tier is keyed by `(ifaceIdentity, method, tag)`.
Sources are committed at `.claude/sprint-phase3/repro/f10_default_hijack/`.

---

# §6 — F-6 → COMMENT on **#347**, supplying the missing derivation

**#347 is OPEN and labelled `needs-repro`** (`S2: misleading`, `ws:emitter`). Its own text says
*"Nobody has built two modules whose paths differ only in a separator char."* This sprint derived
exactly that (RUN-P3-030; `CLOSE-OUT.md:264-271`; `PR-BODY.md:88-91`). **It gets a comment, not a
new issue.**

### Comment body (paste as-is)

> **Supplying the derivation this issue is waiting for, plus a second, independent collision
> channel it does not cover — and a retraction of a wrong example that was circulating.**
>
> Found during the Stage B / Phase 3′ sprint, where bite `B-2.2-e` **widens the alphabet reaching
> this boundary**: today's word alphabet at the mangling seam is `|` and space; the identity
> substitution (#1113) **adds `:`**.
>
> ## The mechanism, at current line numbers
>
> `compiler/backend/private_mangle.mdk:679-694`:
>
> ```medaka
> mangledName mid name = "\{sanitizeId mid}__\{name}"
> sanitizeId s = sanitizeGo s 0 (stringLength s) ""
>   …  let c2 = if safeChar c then c else "_"
> safeChar c = c >= "a" && c <= "z" …
> ```
>
> `safeChar` maps each offending char to a **single** `_`, one-for-one and not injectively.
>
> ## The example to use — module ids are loader-derived PATHS
>
> ```
> a.b::I|T|   ─┐
> a/b::I|T|   ─┼─►  a_b__I_T_
> a-b::I|T|   ─┘
> ```
>
> `.`, `/` and `-` all sanitize to `_`, so three distinct module paths produce one symbol prefix.
> This is exactly the separator-collapse hole this issue posits, now with a concrete word.
>
> ## ⚠️ Retraction — an example that was circulating does NOT reproduce
>
> A claim that `a::Alpha|T|` collides with a module `a_` plus an interface `_Alpha` is **WRONG**
> and must not be used. Because `safeChar` maps each offending char to a *single* `_`, `a::Alpha|T|`
> gives `a____Alpha_T_` — **four** underscores. Recording the refutation here so it is not filed a
> third time.
>
> ## A SECOND, independent collision channel this issue does not mention
>
> The runtime dispatch word is `hashName key` (djb2), which no `sanitizeId` reasoning covers at all.
> A fix that makes `sanitizeId` injective leaves that channel open. (Cf. #377, which records the
> wasm side's 30-bit-truncated djb2 tag space with no emit-time collision check.)
>
> ## Status
>
> **DERIVED, not yet executed as a program.** The collapse is read off the source, not off two
> built modules — so this comment discharges *"nobody has worked out what collides"*, and does not
> yet discharge *"nobody has observed whether it manifests as a loud duplicate-symbol link error or
> a silently mis-routed rename-map entry"*, which remains this issue's open question and is the
> reason the `needs-repro` label should stay until the fixture below lands.

### Pin / fixture recommendation

`.claude/sprint-phase3/DEBT.md`'s `b1`+`e` `nearest miss:` already states the owed fixture and
**no fixture was landed** (`CLOSE-OUT.md:530`, owner: repair round): *two modules whose sanitized
`<mid>::<iface>` spellings collide, asserting DISTINCT emitted symbols.* That is a
`test/llvm_fixtures_modules/` IR-shape fixture, **not** a `must_fail` row — the assertion is
"two defines, two names", which is a positive property, and `must_fail` grades verdicts and stdout.
If the collision turns out to manifest as a wrong *answer* rather than a duplicate symbol, add a
`must_fail` row then. **Do not `CAPTURE=1` a golden here** without hand-deriving the two expected
symbols first: capturing under the collision enshrines it.

---

# §7 — FOLLOW-UP WITH NO ISSUE NUMBER (1/2): the deferred `keyTable`/`KeyBuckets` deletion

`CLOSE-OUT.md:524` marks this **FILE**, owner unassigned-until-now, *"no issue number anywhere in
the ledger"*. `DECISIONS.md:1839-1842`: **without numbers, Phase 5 re-plans off stale design docs.**

### Title

```
ARCH: delete the inert `keyTable`/`KeyBuckets` residue from typecheck's entail ladder — 99 lines
across TWO binders (`keyTable` + `stampKeyTable`), deferred out of Phase 3′ as a region-collision
generator, not as an open question
```

### Body

> **Deferred from Stage B / Phase 3′ (`B-2.2`) by RUN-P3-007, on a derived ruling rather than a
> default one.** The residue is **inert** — it decides nothing — but its positions run straight
> through the region four of six Phase 3′ bites edit, so sweeping it concurrently would have been a
> region-collision generator. It is behaviour-free, confined to `compiler/types/typecheck.mdk`, and
> would remove two `O(decls)` table builds per elaborate.
>
> ## 🚨 The census — and the number Phase 5 must NOT size this off
>
> **DERIVED at pin `68f84bf1` (RUN-P3-007). The design doc's `86`/`91` are RELAYED and both are
> miscut.**
>
> | thing | count |
> |---|---|
> | `KeyBuckets` | 86 lines *including comments*; **34 code lines** |
> | `keyTable` | 91 — but this is a `\bkeyTable\b` count |
> | **`stampKeyTable`** (the SECOND binder) | **+8 code lines**, `elabModuleStamp:29508-29517` |
> | **true residue** | **99 lines across 2 binders** |
>
> ⚠️ **A census that says "91" misses the second binder — the multi-module path, which is the half
> that matters.** `stampKeyTable` is the multi-module elaboration's name for the same table; a
> `\bkeyTable\b` grep cannot see it. **Derive, do not copy this table:**
> `grep -n 'KeyBuckets ->' compiler/types/typecheck.mdk` and
> `grep -nw 'keyTable\|stampKeyTable' compiler/types/typecheck.mdk`.
>
> `shadowKeyTableRef` / `universeKeyBucketsRef` have **zero non-comment occurrences** — those
> deletions are already real.
>
> ## Proof it is inert — derived by inverting the search
>
> Grep the **reader primitive**, not the table. The only `OrdMap` read is `bucketOf` (`:18066`),
> with exactly three call sites (`:18083`, `:18242`, `:19583`), and **not one is applied to a
> threaded `keyTable`**. Every one of the 99 positions is a binder or an argument position; the four
> `EntailKind` constructors carry the field purely to ferry it into `entailInst`, which rebinds it
> and passes it on. **`routeUndeterminedTop`'s `KeyBuckets` parameter is likewise DEAD.**
>
> ## ⚠️ Read the in-tree comment, not around it
>
> The comment at `implDictRoutesForFull` claimed the threading was live for the nested-`requires`
> re-bucketing. **It was stale** — following that recursion
> (`argImplReqRoutes → argReqRoute → routeOfD → entail EKNestedTop → entailInst →
> argImplRequiresRoutes → selectReqImpl`) ends at a function that **does not take `keyTable` at
> all** (`:20031`), and its own sibling comment (`:20025-20027`) already recorded the truth.
> Phase 3′'s bite `c` corrected it in place, replacing it with *"dead parameter awaiting the
> sweep"*. ⚠️ **If bite `c` did not land, that stale comment is still in the tree and will be the
> first thing an implementer reads** — check before starting.
>
> ## ⚠️ What this issue is NOT
>
> **`ImplBuckets` is a different table and it DOES decide.** Do not sweep it with this one.
> `selectReqImpl`'s `iface == ""` arm (`:20033`) selects over `ImplBuckets` via `findImplEntry`
> (`:19582`) — a first-match, head-tag-bucketed **declaration-order** scan over a population that
> **omits no-requires impls** (`buildImplTable:18071`). That is a live second deciding population;
> see the companion follow-up (§8 / the `b2` drop) and `FINDINGS.md` F-5.
>
> ## Owed before starting
>
> `medaka check`/`run`/`build` are all expected byte-identical. The deletion's own bar is a
> **no-emitted-byte-change** claim, so it needs the LLVM golden round plus the self-compile
> fixpoint — not a value differential.

**Suggested labels:** `S3: friction & debt`, `ws:typecheck`. Reference `#1113`, `#1122`.

### Pin recommendation

**None. `MUST-FAIL-NOT-PINNABLE.txt` is also wrong here** — this is not a defect, it is dead code.
There is nothing to assert still-reproduces. The self-draining artifact is the grep in the body:
when the sweep lands, `grep -n 'KeyBuckets ->' compiler/types/typecheck.mdk` returns nothing.

---

# §8 — FOLLOW-UP WITH NO ISSUE NUMBER (2/2): the `b2` drop

`CLOSE-OUT.md:525` marks this **FILE**: *"no issue number. Without it Phase 5 re-plans `b2` off
D1's stale ✅."* **It carries a finding that exists only in this ledger.**

### Title

```
ARCH: `B-2.2-b2` (collapse the double selection at D3/D4) is DROPPED — D1's ✅ "provably one
selection each" is WRONG at this pin: `selectReqImpl`'s `iface == ""` arm selects over a DIFFERENT
population by DECLARATION ORDER, so a correct b2 needs an `iface != ""` guard D1 never mentions
```

### Body

> **Dropped from Stage B / Phase 3′ by RUN-P3-032, on evidence rather than schedule pressure.**
> Filed so Phase 5 does not re-plan the bite off a design-doc ✅ that is false at this pin.
>
> ## 🚨 The finding: a design document's ✅ on the D4 pair is wrong
>
> `.claude/sprint-b/design/D1-phase3-routes.md` carries three markers for this bite:
>
> - `:138` — the per-arm table row: *"| **D4** `EKNestedTop:19139-19144` | `keyForSiteByIface
>   keyTable iface (m::rest)` | `argImplRequiresRoutes:19387-19398` → `selectReqImpl:19412-19415` →
>   `selectImplEntryByIface keyTable iface goals`, `goals = m::rest` **when `iface ≠ ""`** | ✅
>   identical |"*
> - `:290-297` — the bite spec: *"at D4 both use the same `iface` and `m::rest`. **Provably one
>   selection each** (§3.3)."*
> - `:492` — the sizing summary: *"| `B-2.2-b2` | ✅ 2 named pairs |"*
>
> **The D4 row names its own escape hatch — *"when `iface ≠ ""`"* — and then never guards it.**
>
> **The element leg's `selectReqImpl` has a live `iface == ""` arm** that selects over a
> **different population** with a **different goal vector**:
>
> ```
> selectReqImpl implTable iface tag m goals                                          :20031
>   | iface == "" = map (…) (findImplEntry implTable iface tag m)                    :20033
>   | otherwise   = ieRowHeadTriple (ieSelectRowByIface …bodyImplEnvRef… iface goals) :20034
> ```
>
> - **Population:** `ImplBuckets` via `findImplEntry` (`:19582`) — a first-match, head-tag-bucketed
>   linear scan by **declaration order**, not `min⊑`/`pickMostSpecificEntry`; and
>   `buildImplTable:18071` **omits no-requires impls** (the tree's own comment, `:20015`).
> - **Goal vector:** `[m]`, not `m::rest`.
> - **Reachable:** `routesOfMonosTop*` / `routesOfMonos` call `routeOf implTable keyTable "" "" …`
>   with `iface = ""` (`:19848`, `:19882`, `:19934`), threading that `""` down to this arm. The
>   Phase 3′ prep pass statically derived **four callers** reaching it.
>
> **Collapsing there is the D5/D6 semantics change one leg over, arriving as a wrong VALUE at exit
> 0.** So D1's sizing — *"two named pairs, provably identical"* — is false: it is **one clean pair
> plus a conditional one**, and a correct `b2` needs an `iface != ""` guard the design never
> mentions.
>
> ## Two further reasons the bite as specified no longer exists
>
> 2. **It is no longer "pass the row down."** `keyForSite`/`keyForSiteByIface` now *are* the
>    selector call — they select, collision-test and mint internally, returning `Option String` and
>    discarding the row (RUN-P3-006: `keyForSite` is **10 non-comment lines and runs a SECOND `IE`
>    query**, not the "6-line pure projection" the plan called it). `b2` would have to split both,
>    then add a pre-selected-row parameter to `implDictRoutesForFull` and `argImplRequiresRoutes`.
> 3. **The win is smaller than billed and its premise is gone.** Each arm costs **three** IE
>    traversal groups (select-for-word · collision count · select-for-elements), so `b2` removes
>    **1 of 3, not 1 of 2** — and RUN-P3-025 established that `b1` adds no scan, so RUN-B-023's
>    +17% `check-self` cost is not being re-bought. Its byte-identical bar would cost a fixpoint
>    plus an LLVM-golden round to establish.
>
> ## ⚠️ The population finding is DERIVED and has NO discriminating program
>
> Phase 3′ built a candidate probe (a nested `requires` chain, depth ≥ 2, two impls where
> declaration order and min-specificity **disagree**, plus a swapped-order twin). It answered `2`
> — the min-specificity winner — on **both** orders and every channel. **That is not evidence the
> arm is fine: the probe did not reach the `iface == ""` arm and therefore did not discriminate**
> (RUN-P3-039 / OWED-3). The discriminating program is still owed and must be routed through one of
> the four `routeOf … "" ""` callers.
>
> ## Binding on downstream prose, regardless of outcome
>
> Any sentence of the form *"the route selectors now all read one graph-global population"* is
> **FALSE at this pin** and may not appear in a debt row, a commit message, a PR body, or the #1113
> close-out.

**Suggested labels:** `S3: friction & debt` (the drop) — **not** an S0/S1 label, because the
population finding is derived and unwitnessed. `ws:typecheck`. Reference `#1113`, `#1122`.

### Pin recommendation

**`test/MUST-FAIL-NOT-PINNABLE.txt`**, with the reason stated exactly: *"the second deciding
population (`selectReqImpl`'s `iface == ""` arm over `ImplBuckets`) is DERIVED from the source and
reachable from four callers, but no program has been built that reaches it and observes the
declaration-order answer. A pin requires a witness; the probe that was built did not discriminate
(RUN-P3-039)."* Upgrade to a `must_fail_fixtures/` row — the #1154-shape reordering differential:
swap two impl blocks with no other change and assert the answer moves — the moment a witness exists.

---

# §9 — ROWS THAT DO **NOT** GET A BODY, and what each is owed

### F-4 — `expandSupersIfaceEntry` is not idempotent — **BLOCKED ON REPRODUCTION**

**Status in `FINDINGS.md`: DERIVED by a Phase 0 architecture agent, NOT measured** — and possibly
unmeasurable through normal channels, since `pairSlots`' truncate-to-shorter policy masks it (slots
stay correct; it is invisible in IR).

🚨 **`FINDINGS.md:143` says *"Action: file with the derivation, labelled as derived-not-measured."*
That conflicts with this sprint's binding filing discipline, and the discipline wins.** The row was
not reproduced by the orchestrator, and no control exists. **Do not upgrade it to file it.**

**Owed, and it is small:** a program that expands the same iface entry twice and observes the ifaces
entry growing by one per subsequent module — i.e. a ≥3-module graph where a `Subq`/`Sup` pair is
re-expanded, with the ifaces-table length read out (a probe entry point, since IR cannot see it).
If it genuinely cannot be observed through any channel, that is itself the finding, and the honest
artifact is a `MUST-FAIL-NOT-PINNABLE.txt` row plus an ARCH issue framed as *"a boundary marker
stored on the ifaces table is unsound by construction"* — which is the consequence that actually
matters (it is why `B-2.2-f`'s declared-prefix count rides the **ids** table, and that decision has
already shipped).

⚠️ **Do not file it as a bug body.** Filing an unreproduced derivation as a defect is the exact move
this sprint caught in others.

### F-5 — the `ImplBuckets` second deciding population — **BLOCKED, and now folded into §8**

DERIVED; no discriminating program; the probe that was run **did not discriminate** (RUN-P3-039).
It does not file on its own. Its content is carried, correctly labelled, inside the `b2`-drop
follow-up (§8), which is where Phase 5 will look for it. **If a witness is later built, split it out
as its own S0 and remove it from §8's body** — a derived finding riding inside a scope-decision
issue is fine; a *measured* S0 riding there would be buried.

### F-7 — two stale in-tree comments — **NOT A FILING**

In scope for this sprint, assigned to bite `B-2.2-c`, which corrects them in place (`DEBT.md:305-340`).
🚨 **`CLOSE-OUT.md:529` records that `c` has NOT landed.** If it lands, nothing is owed. **If it does
not, this becomes a filing** — an `S2: misleading` issue, because one of the two comments (the
`keyForSite` *"EMPIRICAL, not structural"* warning naming the wrong tier) has already been relayed
through two design documents unverified, and the other (`implDictRoutesForFull`'s `[keyTable]`
justification) **shaped a sprint question**. The close-out must check `c`'s landing before deciding.

### F-9 — **does not exist**

Zero occurrences anywhere in `.claude/sprint-phase3/`, including `git log -p --all -S "F-9"`. The
row set is F-1…F-8, F-10; `FINDINGS.md` is not in numeric order (F-8 was appended next to its F-2
relative). **Nothing is missing** — the number was skipped when F-10 was added out of band. Recorded
here so a future reader does not go looking for a lost finding.

---

# §10 — #1068: the wasm arm this sprint's `engines:` clause shipped without citing

**Not a new issue.** #1068 is OPEN, `verified`, `S1: loud breakage`, `ws:wasm` + `ws:emitter`.

**The debt, DERIVED:** #1113's blast list says #1068's fix *"would build in wasm the superset arm
this task deletes; **do them together**."* RUN-P3-003 independently re-derived wasm's separate
uniqueness family — `headTagUniqueW`, `distinctKeysAtHeadW`, `headTagForKeyW`, `methodImplKey`,
`findByTagW`, with **zero hits** for `ifaceImplRouteKeys`/`ifaceDeclHeadUnique` — **without citing
#1068**. The `b1`+`e` `engines:` clause is now written and committed (`ec1cda37`) naming the owed
peers and **not** citing it. `grep -c '1068' .claude/sprint-phase3/DEBT.md` → **0**.

**The cheap window has closed** (the implementer's bite is committed). **Owner: ORCH, at the
close-out.**

### Discharge — do BOTH, they are cheap and they land in different readers' paths

1. **Append an erratum row to `DEBT.md`** (the file is append-only) against `b1`+`e`'s `engines:`
   clause, citing #1068 and stating the standing arc risk verbatim:
   > *If wasm truly has no consumer of the shared table, wasm's method-less-impl default-dispatch
   > coverage rests entirely on a separately-maintained parallel family (`headTagUniqueW`,
   > `distinctKeysAtHeadW`, `headTagForKeyW`, `methodImplKey`, `findByTagW`) — an
   > `evalModules`/`cevalModules`-class lockstep hazard — and #1113's blast list says the two must be
   > done **together**.*
2. **Carry it explicitly in the PR body and in the #1113 close-out**, since the PR body is what a
   reviewer reads and `DEBT.md` is what Phase 5 reads.

### Draft comment for #1068 itself (optional but recommended)

> Stage B / Phase 3′ (`B-2.2`) independently re-derived the wasm uniqueness family this issue is
> about — `headTagUniqueW`, `distinctKeysAtHeadW`, `headTagForKeyW`, `methodImplKey`, `findByTagW`,
> with **zero** hits for the LLVM-side `ifaceImplRouteKeys`/`ifaceDeclHeadUnique` (RUN-P3-003) —
> and then **shipped its `engines:` clause without citing this issue**. Recording that here so the
> "do them together" constraint from #1113's blast list is not lost: the LLVM-side superset arm has
> now moved, and the wasm peer has not. **No wasm gate was run by any Phase 3′ bite**
> (`DEBT.md` `b1`+`e` `unchecked:` (8)), so this issue's status is unchanged by that work — it is
> neither drained nor re-verified against it.

**Pin:** none new. Both shapes are already enrolled in `test/engine_divergence.txt` with measured
verdicts, which is the correct self-draining artifact for an engine divergence.

---

# §11 — Fixture recommendation on **#1182**: the pin is single-file, the defect reaches through a cross-module wrapper

**Not a new issue** (`DECISIONS.md:1783-1785`, RUN-P3-044): *"The sprint files NOTHING new here. The
only gap is coverage of the existing pin."*

**#1182's pin is `test/must_fail_fixtures/1182-*` — a permutation pair, both interfaces in ONE
module, single file.** Because it is single-file, `ifaceIdentity` answers `""` and `ifaceWordOf`
falls back to the bare name, so the word does not even move (`DEBT.md:226-233`). This sprint
measured the same defect **reaching through per-module wrapper functions across modules**.

### Comment body (paste as-is)

> **This pin's reach is single-file; the defect also reaches through a cross-module wrapper, and
> that half is unpinned.**
>
> Measured on both arms of the Stage B / Phase 3′ branch (base `68f84bf1` and branch), `run` **and**
> the built binary, `check` clean at exit 0 throughout:
>
> Two same-spelled interfaces in **different** modules, each with an impl at the **same** head,
> reached through **per-module wrapper functions**. Correct is `(1, 2)` (`DICT-SEMANTICS` §8 I4: a
> class is `(module, name)`). **Both arms print `(1, 1)` in one import order and `(2, 2)` in the
> other.** Import order still decides, unchanged by that sprint. The method-name-sharing-across-
> modules variant is likewise unchanged.
>
> A five-step mutation ladder (one variable per step, both pre-built arms, MEASURED — RUN-P3-044)
> locates the boundary precisely:
>
> | step | variable | base `run` / binary | branch `run` / binary |
> |---|---|---|---|
> | M0 (positive control) | — | `(11,11)` / `(11,110)` | `(11,110)` / `(11,110)` |
> | M1 | + per-module wrapper fn | `(11,11)` / `(11,110)` | `(11,110)` / `(11,110)` |
> | **M2** | head → a shared 3rd module (**one type**) | `(11,11)` / **`(11,11)`** | **`(11,11)` / `(11,11)`** |
> | M3 | M2 + interfaces spelled **differently** | `(11,11)` / `(11,11)` | unchanged |
> | M4 | M3 + method names differ | `(11,110)` / `(11,110)` | positive control holds |
>
> **M1→M2 is the boundary.** The wrapper is **not** it (M1 has one and is fine). Interface spelling
> is **not** it (M3 reproduces with *differently* spelled interfaces). **Shared head type + shared
> method name IS.**
>
> **Also measured, and it is the sharpest fact:** on that shape the **`build` arm is wrong too**,
> not just `run`. A scope claim resting on `run` alone mis-draws this boundary.
>
> ⚠️ **Stated as a coverage gap, NOT as an identity.** Whether this cross-module shape is literally
> this issue's defect or a sibling of it is **not established** — it is a symptom match (same
> order-dependence, same engine agreement, same order-dependent-selection-upstream-of-the-word
> shape), and this sprint corrected nine prior misattributions to this issue, so the bar for a tenth
> is a mechanism derivation, not a resemblance.
>
> **Recommendation:** extend this issue's fixture pair with a **cross-module wrapper arm** —
> a 3-module graph (two interface+impl modules, one shared head-type module), each dispatching
> through its own wrapper, graded on **both `run` and the built binary**, with the import-order twin
> as the differential. That is the assertable property here as it is for the single-file pair: the
> *order-dependence*, not either value.

### Pin recommendation

Extend the existing `test/must_fail_fixtures/1182-*` pair rather than adding a new fixture family —
the `why-control` block there already explains how to read a convergence. ⚠️ **Read the
shared-corpus trap before touching that directory**: enumerate every consumer of
`must_fail_fixtures/` and run them, and word-bound the grep.

⚠️ **One deliberate non-recommendation, recorded so it is not re-litigated** (`DEBT.md:520-529`):
the repair round considered adding this cross-module-wrapper fixture and **declined**, because it
would need a KNOWN-BAD ledger row rather than a conformance row, and the boundary question ("why
does #1514's shape drain and this one not") is still unanswered. **If the close-out adds it, add it
as a `must_fail` row on #1182 — never as a `dict_fixtures/` conformance row**, which would assert
the wrong polarity.

---

# Summary for the close-out

| # | action | target | severity | pin |
|---|---|---|---|---|
| §1 | comment (cell) | **#1450** | — | extend #1450's owed pin; `== 2` trick, 1 measurement owed |
| §2 | **new issue** | — | **S0** (+S1 arm) | `must_fail`, 3 cases + control |
| §3 | **new issue** | — | **S0** | `must_fail` run arm; binary arm likely NOT-PINNABLE |
| §4 | **new issue** | — | **S1** | `must_fail` build arm + control |
| §5 | **new issue** | — | **S0** | `must_fail`, `ALL_EXACT`, `build-run` + control |
| §6 | comment | **#347** (`needs-repro`) | — | `llvm_fixtures_modules` IR-shape fixture (owed) |
| §7 | **new issue** | — | S3 / ARCH | none (dead code) |
| §8 | **new issue** | — | S3 / ARCH | `MUST-FAIL-NOT-PINNABLE.txt` until a witness exists |
| §10 | `DEBT.md` erratum + PR body + optional comment | **#1068** | — | already in `engine_divergence.txt` |
| §11 | comment (fixture rec) | **#1182** | — | extend the existing pair, cross-module arm |
