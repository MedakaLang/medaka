# B-2.2: one route-word mint on both sides of the seam — drains #1514 (S0), reproduces #347 (S2)

> **Title contract (`CLOSE-OUT.md` §8.7 / exit criterion 7).** The only severity claims in the title
> are **#1514 = S0** and **#347 = S2**, and both are the tracker's own labels, re-read at close-out
> (`gh issue view 1514/347 --json state,labels` → `CLOSED · S0: silent wrongness, verified` /
> `OPEN · S2: misleading, needs-repro, ws:emitter`). The drain table below carries the same two
> severities and no others. **The title claims one S0 drained and one previously-unreproduced S2
> reproduced. It does not claim a class is fixed.**
> ⚠️ **#347's `needs-repro` label is deliberately NOT removed by this PR.** The repro is supplied as a
> comment (`gh issue view 347` → the `2026-08-14T01:59:32Z` comment); relabelling is the issue owner's
> call, so the title says "reproduces", not "de-repro'd".

Stage B / Phase 3′. Four bites landed, one (`b2`) dropped. Full ledger:
`.claude/sprint-phase3/{DECISIONS,DEBT,FINDINGS,FILINGS,CLOSE-OUT}.md`.

---

## 1. What landed

| bite / round | SHA | what |
|---|---|---|
| `a` | `cd1f2c8d` | `compiler/types/route_key.mdk` (NEW) — the shared route-word mint: `ifaceWordOf`, `implRouteKeyWord`, `routeWordFor`, plus one prec-2 `Ty` printer. **Zero call sites at landing.** |
| `f` | `d5948e3a` | the declared-prefix sidecar on the constraint-ids table (`compiler/types/typecheck.mdk`); plumbing only — nothing reads it yet. Collapsed two structural-duplicate function pairs. |
| `b1`+`e` | `ec1cda37` | **the payload.** Caller side (`keyForSite`/`keyForSiteByIface`) and definition side (`eval.implKeyOf`, `ir/core_ir_lower`) now mint the impl route word from **one** function carrying interface identity. `eval.mdk`'s private `ppTyK`/`ppTyAtomK`/`ppEffAtomK` printer family DELETED (the P0-9 mirror). 5 new `test/dict_fixtures/` directories; **13 new `b1-*` rows** in `diff_compiler_dict_semantics.sh` (`git show ec1cda37 -- test/diff_compiler_dict_semantics.sh \| grep -c '^+[^+]'` → 14, of which one is an unrelated `s9-*` entailment row). |
| `c` | `655991f2` | comment-only (mechanically confirmed: the non-`--` lines of the diff are empty). Three stale comments corrected + the selector-reachability invariant inscribed above `entail`. |
| repair round | `5329b1e4` | **test + ratchet only — no `compiler/` or `stdlib/` change** (`DEBT.md` REPAIR ROUND, `could move:`). #1514's program promoted into `test/dict_fixtures/` as a **value** row, plus a distinct-spelling control and the constrained-wrapper segfault pin; `route_key.mdk`'s two ratchet allowlist entries given the line-grained companion checks `typecheck.mdk`'s already had. `diff_compiler_dict_semantics.sh` **176 → 184** assertions (`DEBT.md` REPAIR ROUND, `transform:`). |
| goldens | `b4beeb11` | the ONE golden re-cut, from the final post-`c` binary — see §5. |
| CI repairs | `be635769` | two reds CI caught that no local run did — see §4. |
| tracker | `ced9e7f7` | #1514 closed and its must-fail pin deleted, in that order — see §2 and §7. |
| `b2` | — | **DROPPED** (RUN-P3-032). Now filed as **#1622**. |

**`data Route` is UNCHANGED and `RKey`'s first field is still `String`** — verified at HEAD
(`git show HEAD:compiler/frontend/ast.mdk | grep -n 'data Route' -A3` → `RKey String (List Route)`).
`.claude/HANDOFF.md` carries the corrected framing at HEAD (commit `1ff27689`); the earlier
"this unit changes `RKey`'s payload type" wording is stale since RUN-P3-019 and must not be quoted.

---

## 2. Drain table — tracker state re-read at close-out

| claim | status | evidence |
|---|---|---|
| **#1514 (S0, `verified`) — two unrelated modules each declaring a same-spelled `interface Same` + own impl; `run` answered both call sites with one module's impl, import-order dependent, exit 0, no diagnostic** | **DRAINED — issue now `CLOSED`** (`ced9e7f7`) | The pin produced `11 / 110 / 7`, its own **hand-derived** answer (`DEBT.md` `b1`+`e`, `could move:` (1)). **Causal, not a shape move**: pre-bite `declKeysAtHead` deduped both impls onto one key ⇒ `ifaceDeclHeadUnique` True ⇒ definition side registered under the bare tag while `keyForSiteByIface` stamped the canonical key; caller word ∉ emitter's union ⇒ fallback tier ⇒ first-impl-wins. Post-bite the keys are distinct ⇒ direct hit (RUN-P3-042). The close comment carries this derivation **and** the not-a-class caveat. |
| **#347 (S2, `needs-repro`) — `mangledName` not injective across `sanitizeId`** | **REPRODUCED**, first time; issue stays **OPEN**, comment filed | `DEBT.md` D-1 — see §3.1. Comment on #347 dated `2026-08-14T01:59:32Z`. |
| the same-spelled-interface **class** | **NOT drained** | `DEBT.md` D-2 — see §3.2. |
| #1182 | **NOT fixed, NOT touched; its pin still reproduces** (`run` → 1, control → 2). Still **OPEN**, `S0 verified`. A **coverage-gap comment** was filed (`2026-08-14T02:08:34Z`): its pin is single-file, the defect reaches through a cross-module wrapper. | `DEBT.md` `b1`+`e`, `nearest miss:`. See §8.1. |
| #1062 / #1071 / #1072 (#1113's own drain list) | **not claimed here** | #1071/#1072 verified `CLOSED`, drained by *Stage A/B*, not by this sprint; **#1062 is still `OPEN` and is EVAL-ONLY** — this sprint's route-word half does not touch it (RUN-P3-037, `CLOSE-OUT.md` §5 item 4). |
| #994 | **ANTI-CLOSE — this sprint WIDENED it** (eight lockstep `setRef`s at one site, two of them `f`'s). Still `OPEN`. | Comment on #994 dated `2026-08-14T02:08:48Z`. 🚨 **No reviewer should close #994 on this PR.** |
| #1113 | body updated; **NOT closed**, and this PR does not close it. Still `OPEN`. | RUN-P3-037. |

### The scope statement — verbatim from `RUN-P3-044`, the sprint's settled drain boundary

> The fix distinguishes impl route **words**; it does **not** change impl **selection** — so it
> covers exactly those programs where the candidate scan already yields ONE row (the two impls sit at
> **distinct head types**), and covers **none** where two impls share a head type **and** a method
> name, because there the wrong row is chosen **upstream of any word**.

Derived by a five-step mutation ladder, one variable per step, on both pre-built arms (RUN-P3-044).
**M1→M2 is the boundary:** a per-module wrapper is not it (M1 has one and still drains); interface
*spelling* is not it (M3 reproduces the wrongness with differently-spelled interfaces). **Shared head
type + shared method name is.**

✅ **COVERS:** cross-module same-spelled-interface programs where each module's impl is at **its own
head type** — #1514's shape.
❌ **DOES NOT COVER:** any program where two impls share **both** a method name and a head type.
Measured `(1,1)`/`(2,2)` on base **and** branch, on `run` **and** the built binary, `check` clean at
exit 0 throughout. Import order still decides.

⚠️ **The most discriminating fact in that derivation** (RUN-P3-044): for the uncovered shape, base's
**`build` is also wrong**. #1514's `build` was **correct** and only `run` was wrong — which is why
#1514 read as an eval-only defect. A scope claim resting on `run` alone would have mis-drawn this
boundary.

---

## 3. Behaviour changes the differential DETECTED

Base `68f84bf1` vs branch `ec1cda37`, 15 programs × 4 channels × 2 arms, graded on stdout and
diagnostics (never exit codes). Control clean, 6 vacuous rows named. **Neither D-1 nor D-2 was
recognized by any bite's implementer**; both have `DEBT.md` rows written at detection time. **D-3 was
found later, by the repair round**, and has the same treatment.

### 3.1 D-1 — a program that BUILT and ran now FAILS TO LINK. **Direction: silent wrongness → loud breakage (S0 → S1).**

Modules `a.b` and `a_b`, each with its own `interface C`/method `m` at head `Int`:

```
base   → build 0, exec 0, prints (1, 1)     ← the pre-existing WRONG answer; (1, 2) is correct
branch → build 1: clang failed linking
         invalid redefinition of function 'mdk_impl_a_b__C_Int__m'
```

`.` and `_` both sanitize to `_`, so `a.b::C|Int|` and `a_b::C|Int|` collapse onto one symbol.
`B-2.2-e`'s word carries `module::Iface` through a **non-injective** `sanitizeId`
(`compiler/backend/private_mangle.mdk`) — the collision class **pre-exists at module granularity**;
this sprint newly exposes it at **interface** granularity and makes it load-bearing.

**By this repo's severity ladder that direction is an improvement** — the program was answering
`(1, 1)` and now refuses to build instead of lying. **But it is a NEW build failure on a program that
previously built, and that belongs in this body rather than in a user's terminal.** LLVM only (the
failure is at the clang link step); `run` is unchanged on both arms; wasm unprobed by this
2-engine harness. **Not checked: whether any real project has module ids colliding under
`sanitizeId`.** The corpus program is synthetic.

This is **#347**, previously `needs-repro`, now reproduced and filed as a comment. Ship only the
**path** example (`a.b` / `a/b` / `a-b`) — the circulated `a_` + `_Alpha` example was **refuted**
(RUN-P3-030) and must not be quoted.

### 3.2 D-2 — the same-spelled-interface CLASS is not drained, though #1514 is

`p02`/`p03` — two same-spelled interfaces in different modules, each with an impl at the **same**
head, reached through per-module wrapper functions. Correct is `(1, 2)` (DICT §8 I4: a class is
`(module, name)`). **Both arms print `(1, 1)` in one import order and `(2, 2)` in the other —
unchanged by this sprint, still order-dependent.** `p04`/`p05` (method-name sharing across modules)
likewise unchanged.

**A drained fixture is not a drained class.** The differential demonstrated the gap empirically
rather than leaving it as a caution, and the repair round **deliberately did not** add a fixture for
this shape (`DEBT.md` REPAIR ROUND, `nearest miss:`) — a conformance row would assert the wrong
answer.

⚠️ **What `p02`'s residual IS remains unestablished.** It is order-dependent selection **upstream of
the word**, it is **not** #1265 (its branch IR contains zero `mdk_default` symbols) and **not** #1047
(closed). Whether it is literally #1182's defect or a sibling is a **symptom match, not a proof**
(RUN-P3-044 G-3, which corrects an earlier entry in this sprint's own ledger). **The sprint files
nothing new for it.**

### 3.3 D-3 — headless cross-module impls: one collapsed symbol becomes two qualified ones

Found by the **repair round**, not by any bite (`DEBT.md` D-3). Two modules each declaring a
same-spelled `interface C` with a **headless** impl (`impl C a`):

```
base:    @mdk_impl___none___cm          ← ONE symbol; the second module's body is silently DROPPED
branch:  @mdk_impl_ma__C_a__cm          ← TWO distinct symbols…
         @mdk_impl_mb__C_a__cm          ← …the second emitted and NEVER called
```

**Values unchanged on both arms** (`(1, 1)`, where `(1, 2)` is correct) — so this is **not** an
acceptance or severity change. Direction: **neutral-to-better** (base silently discarded a
definition; the branch keeps both and makes the mis-selection nameable in the IR without fixing it).
LLVM symbol set only; eval unchanged; wasm unprobed.

✅ **Its sibling control is what makes the amended claim survive:** differently-spelled headless
interfaces across modules produced **byte-identical IR**, symbols still unqualified — qualification
is gated on the collision verdict. The **unamended** claim *"byte-identical on programs with no head
collision"* would have been **falsified** by this row (see §8, item 2).

---

## 4. Two CI-only reds — caught by pushing a draft PR early, invisible to every local gate

`be635769`. **Recorded as evidence for the practice, not as an embarrassment.**

| red | what it was | why no local run saw it |
|---|---|---|
| `soundness` / *"Docs must not cite fabricated symbols"* | `.claude/skills/harden-typechecker/SKILL.md` cited `lookupQualIfaces`, which bite `e` **deleted** (fused into `lookupQualPayload`). **Genuine doc rot caused by this sprint**, on a doc the gate correctly guards. Repointed; `make agent-doc-symbols` → **997 live / 0 dead**. | The doc-symbol gate is not in any `diff_compiler_*` family and is not selected by `preflight` from a `compiler/types/*.mdk` diff. Nothing the sprint ran reads `.claude/skills/`. |
| `gates (tools)` / `diff_compiler_ci_shard_coverage` | the sprint's own repro harness at `.claude/sprint-phase3/repro/run.sh` matched the gate-name pattern and no CI shard — the *"a gate that silently never runs"* check firing on something that **is not a gate**. Added to `test/CI-COVERAGE-EXCEPTIONS.txt` **with a reason**: it grades nothing, several arms are **expected** to fail (F-2's build `E-PANIC`s on purpose), and running it in CI would red the suite on findings that are correctly still open. | The harness did not exist until mid-sprint, and the coverage gate is a whole-tree scan — its input is the tree, not the diff, so no diff-derived local selection reaches it. |

**Both were invisible to every local gate this sprint ran.** The draft PR is what surfaced them.

---

## 5. Close-out results — fixpoint, seed, goldens, drains (all on the FINAL binary)

Source: RUN-P3-047 and commit `b4beeb11`.

| item | result |
|---|---|
| **fixpoint** | `C3a PASS: IR1 (native) == seed-bootstrapped converged reference, byte-for-byte` · `C3b PASS: IR1 == IR2 byte-for-byte`. Run on the **post-`c` binary**, closing the gap where the earlier `ec1cda37` measurement predated the terminal bite. **This names WHICH C3a and covers only that one.** ⚠️ `ec1cda37`'s commit message gives the **unqualified** claim — do not quote it. |
| **seed** | **No re-mint owed — derived, not assumed.** The seed *is* the native emitter's emission of the build driver's graph, so `C3a` green is the same proposition as *"`refresh_seed` would rewrite identical bytes"*; and `git diff --name-only 68f84bf1..HEAD -- compiler/backend` is empty, so there is no codegen change to converge. |
| **goldens** | Re-cut **ONCE**, from the final binary. Snapshot: **3 re-blessed by name** (`typecheck`, `core_ir_lower`, `eval` — all three differ in SOURCE, DESUGAR and MARK) + `route_key.md` **CREATED** with `--new`, verified surgical against a before-copy (*"Only in test/snapshots/compiler: route_key.md"*), then **re-checked for real: 202 fixtures, all 202 compared and matching.** ⚠️ `--new` itself reports *"0 compared, 201 skipped: NOTHING COMPARED (this is not a pass)"* — the gate is honest about that mode; the re-check is what makes it a pass. |
| **LEG A** | Non-additive **by design**, and the diff matched the adversarial review's advance prediction (RUN-P3-036) **exactly**: **4 deletions** (`attributeModuleArities`, `attributeModuleArrIfaces`, `lookupQualArity`, `lookupQualIfaces`) · **4 additions** (`attributeModuleEntries`, `clampPrefix`, `declaredConstraintFor`, `lookupQualPayload`) · **5 modified** (`aliasConstraintEntries`, `aliasEntriesFor`, `memberAliasEntry`, `moduleAliasEntry`, `promotedConstraints`), **each a strict generalization** — old type an instance of the new at `a := List X` (e.g. `aliasEntriesFor`'s `List ((String,String), List a)` → `List ((String,String), a)`). **Both negative requirements hold:** `declaredConstraintSlots` and `qualConstraintFor` show **zero** diff lines and are both still present; there is **no sixth** modified row. `eval.eval.golden` moves 1 add / 7 del (deleted `implKeyOf` + its `ppTyK` family, plus `implMethodEntry`'s signature). |
| **drains ×2** | Two runs on a quiescent tree, **identical**: `97 fixtures: 96 still reproduce, 1 DRAINED (#1514), 0 control-broke, 0 malformed`. Agreement was the requirement — a disagreement would have meant the tree was still moving. **After the pin deletion the suite is green: 96 fixtures, 96 reproduce, 0 drained** (`ced9e7f7`; `git ls-tree -d --name-only HEAD test/must_fail_fixtures/ \| wc -l` → 96). |

---

## 6. What reviewers should look at

**The golden re-cuts are the review gate, not the green.** The §5 results are the *author's* reading;
the reviewer's job is to re-derive them.

- 🚨 **`test/selfproc_goldens/legA/types.typecheck.golden` is NOT additive-only, deliberately.**
  `AGENTS.md` forbids modified rows by default, so **the reviewer's question is not "were rows
  deleted"** but:
  > **Is each modified row a strict generalization — the old type an instance of the new at
  > `a := List X` — and did nothing else move?**
  - **The 4 deletions are accounted for:** `f` collapsed two structural-duplicate pairs into one
    polymorphic function each.
  - **Two bindings are REQUIRED to be UNCHANGED:** `declaredConstraintSlots` and `qualConstraintFor`.
    R-1 held their byte-identity on an *identity* (`qualConstraintKey ≡ hasImportDefiner`), not a
    contingency — if either row moved, that identity broke. Measured: zero diff lines, both present.
  - **A sixth modified row is a regression.** Do not bless it; derive what moved.
  - **Two modules move, not three.** `compiler/ir/core_ir_lower.mdk` is **not** in the LEG A corpus
    (`test/capture_goldens.sh:191`; `AGENTS.md` excludes `ir.core_ir_lower` explicitly). The
    `b1`+`e` `DEBT.md` row's *"all three edited modules are LEG A"* is **wrong** (erratum, RUN-P3-046)
    — expecting a third golden and not getting one is not a missing re-cut.
- **`test/snapshots/compiler/route_key.md` is a CREATE, not a re-bless** — a corpus **ADD** (the gate
  globs `compiler/types/*.mdk`). Measured at `a`'s landing as **201 of 201** compared and matching,
  zero goldens moved; the post-create re-check is **202 of 202** (§5).
- **`diff_compiler_llvm_typed_ir` is GREEN and its green is not evidence.** 54/54 byte-identical at
  `ec1cda37` — but the corpus is 54 **single-file, prelude-free** fixtures ⇒ absent origin ⇒
  bare-name fallback, which is exactly why it cannot see this bite. The multi-module evidence is the
  new `dict_semantics` rows. A **red** here would mean the flat-driver fallback broke.
- **The eight new `dict_fixtures/` directories** are read by exactly one gate
  (`test/diff_compiler_dict_semantics.sh`; derived word-bounded). ⚠️ That gate's **section 4**
  (impl-block permutation) globs `*.mdk` **directly in `FIXDIR`, no recursion** — the new
  *directories* are excluded from it. Confirm sections 1 and 3 actually open and **print** them.
- **The repair round's fixtures blessed ZERO goldens.** Every pinned value was hand-derived from the
  impl bodies before any binary was run; no `CAPTURE=1` anywhere. Every new row was proven
  **fail-capable by perturbation and reverted byte-exactly** (`DEBT.md` REPAIR ROUND, `unchecked:` (d)
  and (e)) — a fixture that has only ever passed has not been shown to pin anything.
  ⚠️ Its `unchecked:` (a) is load-bearing: **the pre-bite cells in those fixtures are RELAYED, not
  re-measured by the fixture author.** The post-fix side was verified first-hand.
- **`b1`'s two lines** at `keyForSite`/`keyForSiteByIface` are the whole caller-side payload. **ZERO
  edits at the four `inst` arms** and D5/D6's element routes untouched by construction — stated
  because a reader of a two-line diff cannot see that it was considered.

---

## 7. Tracker work executed by this PR

| action | targets |
|---|---|
| **desk closes** (ARCH, each with tree-derived evidence) | **#1512, #1557, #1558, #1559** — all verified `CLOSED`. ⚠️ #1558's close comment carries the **re-scope**: it landed as a **SPLIT**, not the deletion its body specifies. |
| **S0 drain close** | **#1514** — `CLOSED`, pin deleted. 🚨 **Order was load-bearing and was followed**: the program was promoted into `test/dict_fixtures/` as a value row and `diff_compiler_dict_semantics` went green **BEFORE** the pin was deleted. The sprint's other new fixtures pin the *wire format*, not the *selection*, so deleting first would have left **zero** regression coverage for the behaviour actually fixed. |
| **new issues filed** | **#1617** (S0 — function-typed impl head falls into the `noneHeadTag` bucket) · **#1618** (S1 — effect-carrying impl head checks clean, runs correctly, cannot be built) · **#1619** (S0 — cross-module interface DEFAULT silently hijacked by a same-spelled interface at the same head) · **#1620** (S0 — two interfaces sharing a method name in ONE file). |
| **numberless follow-ups given numbers** | **#1621** (the inert `keyTable`/`KeyBuckets` residue) · **#1622** (the `b2` drop, and D1's ✅ on the D4 pair being wrong at this pin). Both were previously recorded **only** in this sprint's ledger; without numbers, Phase 5 re-plans off stale design docs (RUN-P3-046). |
| **evidence comments** | **#1450** (an additional cell — the colliding partner can be the auto-prelude) · **#347** (the missing repro, §3.1) · **#1182** (a measured coverage gap in its pin). |
| **anti-close** | **#994** — 🚨 do **not** close it on this PR or on #1605's *"Implements B-3 (#994)"*. The `CrossRun` half is not done and **this sprint widened it by two**. |

🚨 **The four new issues ship with pin RECOMMENDATIONS, not pins.** `FILINGS.md` §§2–5 each specify a
`must_fail_fixtures/` shape, and **none of them landed in this PR** — `git diff --name-status
68f84bf1..HEAD -- test/must_fail_fixtures` shows **deletions only** (#1514's pin). Two of them became
pinnable only at RUN-P3-048, which converted a non-byte-stable leaked-pointer channel into a
deterministic `Bool` projection (`run → True`, `binary → False ×3, stable`). **Owed, not done.**

---

## 8. CLAIMS THIS SPRINT CANNOT MAKE

Listed so they cannot be quoted by accident out of a heading, a commit message, or an agent report.

1. **"This fixes #1182."** It does not — it **inherits** it. #1182's selection runs on
   `contains name ms` — method-name membership plus head match, **no interface component** — and the
   word is minted *downstream of the already-selected row*; in #1182's own single-file repro **the
   word does not even move**. Adjudicated three times independently, all against the earlier framing,
   and corrected in **nine** places. ⚠️ `b1` makes #1182 **quieter → differently wrong**: where the
   head-tag hedge used to mask the mis-selection, the wrongly-selected instance's identity is now
   stamped directly. **Its pin stays and still reproduces.**
2. **"Byte-identical IR on programs with no head collision."** FALSE. The defensible form adds
   *"…and no two same-spelled interfaces in the module graph"* — `ifaceDeclHeadUnique` →
   `declKeysAtHead` dedups by canonical key, so the collision **verdict** changes (RUN-P3-026).
   **D-3 (§3.3) is the row that would have falsified the unamended claim**, and its differently-spelled
   control is what shows the amendment is the right one.
3. **Anything from the Phase 0 gate table (RUN-P3-018). All six rows are stale** — superseded by
   RUN-P3-019/-023/-025/-027/-032/-033. It is a `#` heading reading "GO", which is exactly why it is
   the most quotable stale thing in the ledger.
4. **#1113's own drain list.** *"Drains #1072/#1071/#1062"* is two-thirds spent, **and neither third
   was spent by this sprint** — #1071/#1072 were drained by Stage A/B. **#1062 is still OPEN and is
   eval-only. Do not cite #1062.**
5. **"The route selectors now all read one graph-global population."** FALSE at this pin —
   `ImplBuckets`/`implTable` rides the same parameter positions and **does** decide, by a different
   rule over a different population (`FINDINGS.md` F-5, now folded into **#1622**).
6. **`f`'s fixpoint waiver, and "typed IR byte-unchanged" as a whole-diff statement.** The gates
   behind it are 54 single-file prelude-free fixtures — ~1 of 6 changed regions. The narrow claim
   must be scoped to the corpus that produced it.
7. **The retracted `sanitizeId` example** (`a_` + `_Alpha`). Refuted — `safeChar` maps each offending
   char to a *single* `_`. Ship the path example only.
8. **"The sprint's fixpoint is green" without naming the stage.** The covered claim is exactly
   *"C3a: IR1 (native) == seed-bootstrapped converged reference, byte-for-byte"* plus C3b, on the
   **post-`c`** binary (§5). `ec1cda37`'s commit message gives an unqualified version; it is not the
   claim.
9. **Any count without its command.** Wrong in this sprint alone: `DEBT.md`'s *"374 lines"* for
   `route_key.mdk` (`git show HEAD:compiler/types/route_key.mdk | wc -l` → **436** at HEAD, and a
   mid-sprint recount said 396 — **three values, two of them "corrections"**); *"`fromOption` 99
   uses"* (99 *lines*, 78 occurrences); *"86 / 91"* `KeyBuckets`/`keyTable` residue (**99 lines across
   2 binders**, now #1621's title); *"nine probe drivers"* (**7**); *"`CProgram` constructed at
   exactly ONE site"* (**13**).
10. **"CI green" as corroboration for a specific gate's numbers.** `pull_request` runs are narrowed;
    a shard can go green in seconds having run nothing. Cite the `merge_group` run or per-shard step
    conclusions. §4 is the counterexample in the other direction — **local green is not CI green
    either.**
11. **"All 15 reading sites need the word."** 🚧 **This number has no enumeration in any artifact that
    ships with this PR** (`grep -rn '15 read' .claude/sprint-phase3/` → three hits: an assertion, a
    flag that it is unverifiable, and a repetition). **It is not in this body**, and the refusal of
    the design of record rests instead on the two derivations that *are* independently checkable —
    see §9.
12. **"The `headTyconTy` wildcard has three live divergences."** It has **two**. The source asymmetry
    is three-armed (`TyFun`, `TyEffect`, `TyConstrained`) but the `TyConstrained` arm was **measured
    with two live controls and shows no divergence** — stripping a constraint leaves a *headless*
    type, so both sides agree (RUN-P3-045). Filed as #1617 and #1618; **no third row.**
13. **"The four new issues are pinned."** They are not — §7, last paragraph.
14. **"#347 is de-repro'd" / "the class of symbol collisions is understood."** #347 keeps its
    `needs-repro` label (this PR does not relabel), and D-1's `nearest miss:` names a **second,
    independent** collision channel — `hashName` (djb2) — which `sanitizeId` reasoning does not cover
    and which nothing here probed.
15. **`FINDINGS.md` has no F-9.** A numbering gap created by appending F-10 out of band. Nobody should
    hunt for a lost finding. **F-4 does not file as a bug** — it is derived, never measured, and may
    be unobservable through normal channels; RUN-P3-049 rules it an ARCH filing about the consequence.
    **F-7 is not a filing at all.**

---

## 9. Why the design of record was refused — resting only on checkable derivations

`.claude/sprint-b/design/D1-phase3-routes.md` §`B-2.2-a` says to change `RKey`'s field to a
two-component carrier. Refused in Phase 0 (RUN-P3-019). Two independently checkable reasons, both
re-verified at HEAD for this body:

1. **Siting the mint beside `InstRef` in `typecheck.mdk` would have made a THIRD mirrored copy** —
   the exact P0-9 shape `B-2.2-e` exists to delete. `eval.mdk` and `core_ir_lower.mdk` cannot reach
   `types/typecheck.mdk`: `git show HEAD:compiler/eval/eval.mdk | grep '^import'` and the same for
   `core_ir_lower.mdk` show **no `types.typecheck` edge** (both now import `types.route_key`).
2. **The tree already ruled it at the site that owns the word** — `ieCountHeadByIface`: *"the question
   is inherently SPELLING-scoped… answering it with identities is wrong at ANY supply level."*

---

## 10. Expected gate state — do not diagnose these as a break

The mid-run reds `.claude/HANDOFF.md` licensed are **discharged at this commit**. Current expectation:

| gate | expectation on this PR |
|---|---|
| `diff_compiler_must_fail` | **GREEN.** `96 fixtures, 96 still reproduce, 0 DRAINED, 0 control-broke, 0 malformed` — the #1514 drain is closed and its pin deleted (§5, §7). |
| `diff_compiler_snapshot_frontend` | **re-cut and re-checked: 202 / 202 compared and matching** (§5). |
| `diff_compiler_selfproc` (LEG A) | re-cut, non-additive by design; review against the 4+4+5 expectation in §6. **CI `backend` shard only** — it phantom-skips (exit 2 → `FAIL*`) without `test/bin/check_all_main`, so a local `FAIL*` here is a missing oracle, not a break. |
| `diff_compiler_llvm_typed_ir` | **green, and must stay green.** Do not capture it. |
| `diff_compiler_dict_semantics` | green, **176 → 184** assertions. |
| `test/typecheck_compiler_source.sh` | 3 ratchet allowlist entries from `b1`+`e`; **two of them discharge a red inherited from `a`** (the ratchets are `git grep`s over tracked files, so `route_key.mdk` tripped them from the moment it landed, unnoticed). The repair round then **narrowed** them: `route_key.mdk`'s entries gained the **line-grained companion checks** `typecheck.mdk`'s already had — the producer ratchets compare exact filename sets, so line-graining must be a companion, not a replacement. |
| `soundness` / doc-symbol + shard-coverage | **green as of `be635769`** — see §4. |
| `rule-duplicate-body` on `rkEffAtom` | the `lint-disable-next-line` directive is **KEPT**. `a`'s row instructing its retirement is **refused, measured**: `e` deletes eval's copy but typecheck's `ppEffAtomTy` and doc's `ppEffAtomDoc` survive, so removing it exits 1 naming two files. (`DEBT.md` is append-only ⇒ this is an erratum, not an edit.) |

---

## 11. Owed after this PR — nothing here is claimed as done

- **Pins for #1617 / #1618 / #1619 / #1620.** Shapes specified in `FILINGS.md` §§2–5; none landed (§7).
- **#1068 / the wasm arm.** #1113's blast list says #1068's fix and this work must be done
  **together**, and #1068 appears **zero** times in `DEBT.md` (`grep -c '1068' .claude/sprint-phase3/DEBT.md`
  → 0). Carried here instead. Standing risk: wasm's method-less-impl default-dispatch coverage rests
  on a **separately maintained parallel family** (`headTagUniqueW`, `distinctKeysAtHeadW`, …) with
  zero hits for the shared table — an `evalModules`/`cevalModules`-class lockstep hazard.
- **Owed peers, unedited by `b1`+`e`:** `llvm_emit.implEntryRouteKey` / `implEntryRouteWords` /
  `headTagUnique` / `distinctKeysAtHead`, wasm's family, `core_ir_lower.distinctKeysAtHeadL`, and a
  **test** (not a patch) for `core_ir_eval.mdk:455`.
- **The D-2 boundary question** — *why* #1514's shape drains and `p02`'s does not — is unanswered
  (`DEBT.md` D-2, `unchecked:`). A fixture for `p02` would need a KNOWN-BAD ledger row, not a
  conformance row.
- **wasm is unprobed for D-1, D-3 and all three repair-round fixtures.** The differential is
  2-engine; `diff_compiler_dict_semantics` drives check/run/build only (its own *"NOT YET COVERED"*
  §7 bullet).
- **Not run by any bite:** perf/scaling, the wasm gates, `diff_compiler_selfproc` locally.
