# B-2.2: one route-word mint on both sides of the seam — drains #1514 (S0), reproduces #347 (S2)

> **Title contract (`CLOSE-OUT.md` §8.7 / exit criterion 7).** The only severity claims in the title
> are **#1514 = S0** and **#347 = S2**, and both are the tracker's own labels, read at draft time
> (`gh issue view 1514/347 --json labels` → `S0: silent wrongness, verified` / `S2: misleading,
> needs-repro`). The drain table below carries the same two severities and no others. **The title
> claims one S0 drained and one previously-unreproduced S2 reproduced. It does not claim a class is
> fixed.**

Stage B / Phase 3′. Four bites landed, one (`b2`) dropped. Full ledger:
`.claude/sprint-phase3/{DECISIONS,DEBT,FINDINGS,CLOSE-OUT}.md`.

---

## 1. What landed

| bite | SHA | what |
|---|---|---|
| `a` | `cd1f2c8d` | `compiler/types/route_key.mdk` (NEW) — the shared route-word mint: `ifaceWordOf`, `implRouteKeyWord`, `routeWordFor`, plus one prec-2 `Ty` printer. **Zero call sites at landing.** |
| `f` | `d5948e3a` | the declared-prefix sidecar on the constraint-ids table (`compiler/types/typecheck.mdk`); plumbing only — nothing reads it yet. Collapsed two structural-duplicate function pairs. |
| `b1`+`e` | `ec1cda37` | **the payload.** Caller side (`keyForSite`/`keyForSiteByIface`) and definition side (`eval.implKeyOf`, `ir/core_ir_lower`) now mint the impl route word from **one** function carrying interface identity. `eval.mdk`'s private `ppTyK`/`ppTyAtomK`/`ppEffAtomK` printer family DELETED (the P0-9 mirror). 5 new `test/dict_fixtures/` directories; 13 new rows in `diff_compiler_dict_semantics.sh`. |
| `c` | `655991f2` | comment-only (mechanically confirmed: the non-`--` lines of the diff are empty). Three stale comments corrected + the selector-reachability invariant inscribed above `entail`. |
| `b2` | — | **DROPPED** (RUN-P3-032). |

**`data Route` is UNCHANGED and `RKey`'s first field is still `String`** — verified at HEAD
(`git show HEAD:compiler/frontend/ast.mdk | grep -n 'data Route'` → `RKey String (List Route)`).
⚠️ `.claude/HANDOFF.md:10` still says this unit changes `RKey`'s payload type. That is **stale since
RUN-P3-019** and must not be quoted.

---

## 2. Drain table

| claim | status | evidence |
|---|---|---|
| **#1514 (S0, `verified`) — two unrelated modules each declaring a same-spelled `interface Same` + own impl; `run` answered both call sites with one module's impl, import-order dependent, exit 0, no diagnostic** | **DRAINED** | `test/must_fail_fixtures/1514-xmod-same-spelled-iface-impl-selection` now produces `11 / 110 / 7`, the fixture's own **hand-derived** answer (`DEBT.md` `b1`+`e`, `could move:` (1)). **Causal, not a shape move**: pre-bite `declKeysAtHead` deduped both impls onto one key ⇒ `ifaceDeclHeadUnique` True ⇒ definition side registered under the bare tag while `keyForSiteByIface` stamped the canonical key; caller word ∉ emitter's union ⇒ fallback tier ⇒ first-impl-wins. Post-bite the keys are distinct ⇒ direct hit (RUN-P3-042). |
| **#347 (S2, `needs-repro`) — `mangledName` not injective across `sanitizeId`** | **REPRODUCED**, first time | `DEBT.md` D-1 — see §3. |
| the same-spelled-interface **class** | **NOT drained** | `DEBT.md` D-2 — see §3. |
| #1182 | **NOT fixed, NOT touched; its pin still reproduces** (`run` → 1, control → 2) | `DEBT.md` `b1`+`e`, `nearest miss:`. See §6. |
| #1062 / #1071 / #1072 (#1113's own drain list) | **not claimed here** | #1071/#1072 CLOSED, drained by *Stage A/B*; **#1062 is EVAL-ONLY** and this sprint's route-word half does not touch it (RUN-P3-037, `CLOSE-OUT.md` §5 item 4). |

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

---

## 3. Behaviour changes the differential DETECTED

Base `68f84bf1` vs branch `ec1cda37`, 15 programs × 4 channels × 2 arms, graded on stdout and
diagnostics (never exit codes). Control clean, 6 vacuous rows named. Neither delta was recognized by
any bite's implementer; both have `DEBT.md` rows written at detection time.

### D-1 — a program that BUILT and ran now FAILS TO LINK. **Direction: silent wrongness → loud breakage (S0 → S1).**

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

This is **#347**, previously `needs-repro`, now reproduced. File the **path** example
(`a.b` / `a/b` / `a-b`) — the circulated `a_` + `_Alpha` example was **refuted** and must not ship.

### D-2 — the same-spelled-interface CLASS is not drained, though #1514 is

`p02`/`p03` — two same-spelled interfaces in different modules, each with an impl at the **same**
head, reached through per-module wrapper functions. Correct is `(1, 2)` (DICT §8 I4: a class is
`(module, name)`). **Both arms print `(1, 1)` in one import order and `(2, 2)` in the other —
unchanged by this sprint, still order-dependent.** `p04`/`p05` (method-name sharing across modules)
likewise unchanged.

**A drained fixture is not a drained class.** The differential demonstrated the gap empirically
rather than leaving it as a caution.

---

## 4. An unclaimed repair: a deterministic native SEGFAULT

Nothing in the commit messages claims this. Add a `Same a => a -> Int` **constrained wrapper** to the
#1514 shape and **base builds at exit 0 and segfaults 3/3** (`exit 139`, `E-FATAL-SIGNAL`) while its
`run` answers `(11,11)`; **branch answers `(11,110)` on both arms.** IR: base hands the *same* dict
constant to both generic calls and the dispatcher tests a tag no arm matches, reaching `unreachable`;
branch emits two constants and two matching arms. (RUN-P3-044.)

🚧 **UNPINNED AS OF THIS DRAFT — therefore stated as a measurement, not claimed as a repair.**
`test/dict_fixtures/b1-xmod-same-spelled-iface-constrained-wrapper/` exists **untracked in the working
tree** (a writer is adding it now); it is not in any commit in `68f84bf1..HEAD`. **If it does not land
in this PR, delete this section** — an unpinned claim is not claimable.

---

## 5. What reviewers should look at

**The golden re-cuts are the review gate, not the green.**

- 🚨 **`test/selfproc_goldens/legA/types.typecheck.golden` will NOT be additive-only. Expected:
  4 deletions + 4 additions + 5 MODIFIED rows** (R-1's derivation, RUN-P3-036). `AGENTS.md` forbids
  modified rows by default, so **the reviewer's question is not "were rows deleted"** but:
  > **Is each modified row a strict generalization — the old type an instance of the new at
  > `a := List X` — and did nothing else move?**
  - **The 4 deletions are accounted for:** `f` collapsed two structural-duplicate pairs into one
    polymorphic function each — `attributeModuleArities` + `attributeModuleArrIfaces` →
    `attributeModuleEntries`, and `lookupQualArity` + `lookupQualIfaces` → `lookupQualPayload`.
  - **Two bindings are REQUIRED to be UNCHANGED:** `declaredConstraintSlots` and `qualConstraintFor`.
    R-1 held their byte-identity on an *identity* (`qualConstraintKey ≡ hasImportDefiner`), not a
    contingency — if either row moved, that identity broke.
  - **A sixth modified row is a regression.** Do not bless it; derive what moved.
  - **Two modules move, not three.** `compiler/ir/core_ir_lower.mdk` is **not** in the LEG A corpus
    (`test/capture_goldens.sh:191`; `AGENTS.md` excludes `ir.core_ir_lower` explicitly). The
    `b1`+`e` `DEBT.md` row's *"all three edited modules are LEG A"* is **wrong** — expecting a third
    golden and not getting one is not a missing re-cut.
- **`test/snapshots/compiler/route_key.md` is a CREATE (`--new`), not a re-bless** — a corpus **ADD**
  (the gate globs `compiler/types/*.mdk`), measured at `a`'s landing as 201 of 201 existing snapshots
  compared and matching, zero goldens moved. `--new` is **suite-wide and takes no path argument**;
  confirm exactly one `FAIL no snapshot` row before running it, and re-run without the flag
  afterwards (under `--new` every existing fixture is skipped).
- **`diff_compiler_llvm_typed_ir` is GREEN and its green is not evidence.** 54/54 byte-identical at
  `ec1cda37` — but the corpus is 54 **single-file, prelude-free** fixtures ⇒ absent origin ⇒
  bare-name fallback, which is exactly why it cannot see this bite. The multi-module evidence is the
  new `dict_semantics` IR assertions. A **red** here would mean the flat-driver fallback broke.
- **The five new `dict_fixtures/` directories** are read by exactly one gate
  (`test/diff_compiler_dict_semantics.sh`; derived word-bounded). ⚠️ That gate's **section 4**
  (impl-block permutation) globs `*.mdk` **directly in `FIXDIR`, no recursion** — the new
  *directories* are excluded from it. Confirm sections 1 and 3 actually open and **print** them.
- **`b1`'s two lines** at `keyForSite`/`keyForSiteByIface` are the whole caller-side payload. **ZERO
  edits at the four `inst` arms** and D5/D6's element routes untouched by construction — stated
  because a reader of a two-line diff cannot see that it was considered.

---

## 6. CLAIMS THIS SPRINT CANNOT MAKE

Listed so they cannot be quoted by accident out of a heading, a commit message, or an agent report.

1. **"This fixes #1182."** It does not. #1182's selection runs on `contains name ms` — method-name
   membership plus head match, **no interface component** — and the word is minted *downstream of the
   already-selected row*; in #1182's own single-file repro **the word does not even move**.
   Adjudicated three times independently, all against the earlier framing, and corrected in **nine**
   places. ⚠️ `b1` makes #1182 **quieter → differently wrong**: where the head-tag hedge used to mask
   the mis-selection, the wrongly-selected instance's identity is now stamped directly. Its pin stays.
2. **"Byte-identical IR on programs with no head collision."** FALSE. The defensible form adds
   *"…and no two same-spelled interfaces in the module graph"* — `ifaceDeclHeadUnique` →
   `declKeysAtHead` dedups by canonical key, so the collision **verdict** changes (RUN-P3-026).
3. **Anything from the Phase 0 gate table (RUN-P3-018). All six rows are stale** — superseded by
   RUN-P3-019/-023/-025/-027/-032/-033. It is a `#` heading reading "GO", which is exactly why it is
   the most quotable stale thing in the ledger.
4. **#1113's own drain list.** *"Drains #1072/#1071/#1062"* is two-thirds spent. **Do not cite #1062.**
5. **"The route selectors now all read one graph-global population."** FALSE at this pin —
   `ImplBuckets`/`implTable` rides the same parameter positions and **does** decide, by a different
   rule over a different population (`FINDINGS.md` F-5).
6. **`f`'s fixpoint waiver, and "typed IR byte-unchanged" as a whole-diff statement.** The gates
   behind it are 54 single-file prelude-free fixtures — ~1 of 6 changed regions. The narrow claim
   must be scoped to the corpus that produced it.
7. **The retracted `sanitizeId` example** (`a_` + `_Alpha`). Refuted — `safeChar` maps each offending
   char to a *single* `_`. Ship the path example only.
8. **`HANDOFF.md:10`'s "this unit changes `RKey`'s payload type."** Stale.
9. **Any count without its command.** Wrong in this sprint alone: `DEBT.md`'s *"374 lines"* for
   `route_key.mdk` (`git show HEAD:compiler/types/route_key.mdk | wc -l` → **436**, and a mid-sprint
   recount said 396); *"`fromOption` 99 uses"* (99 *lines*, 78 occurrences); *"86 / 91"*
   `KeyBuckets`/`keyTable` residue (**99 lines across 2 binders**); *"nine probe drivers"* (**7**);
   *"`CProgram` constructed at exactly ONE site"* (**13**).
10. **"CI green" as corroboration for a specific gate's numbers.** `pull_request` runs are narrowed;
    a shard can go green in seconds having run nothing. Cite the `merge_group` run or per-shard step
    conclusions.
11. **"All 15 reading sites need the word."** 🚧 **This number has no enumeration in any artifact that
    ships with this PR** (`grep -rn '15 read' .claude/sprint-phase3/` → three hits: an assertion, a
    flag that it is unverifiable, and a repetition). **It is not in this body**, and the refusal of
    the design of record rests instead on the two derivations that *are* independently checkable —
    see §7.
12. **"The `headTyconTy` wildcard has three live divergences."** It has **two**. The source asymmetry
    is three-armed (`TyFun`, `TyEffect`, `TyConstrained`) but the `TyConstrained` arm was **measured
    with two live controls and shows no divergence** — stripping a constraint leaves a *headless*
    type, so both sides agree (RUN-P3-045). F-2 and F-8 file; no third row.

---

## 7. Why the design of record was refused — resting only on checkable derivations

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

## 8. Known-red / expected gates — do not diagnose these as a break

`.claude/HANDOFF.md` licenses the mid-run reds; this PR discharges them at the close-out.

| gate | expectation on this PR |
|---|---|
| `diff_compiler_must_fail` | **RED naming #1514 is the drain deliverable.** The close-out closes #1514 and deletes the fixture. 🚨 **Blocking precondition (RUN-P3-042): promote #1514's program into `test/dict_fixtures/` as a value row BEFORE deleting the pin** — the five landed fixtures pin the *wire format*, not the *behaviour*, so deleting the pin without promotion leaves the tree with **zero** regression coverage for the thing this bite fixed. |
| `diff_compiler_snapshot_frontend` | re-cut for `typecheck.mdk`, `eval.mdk`, `core_ir_lower.mdk`; **CREATE** for `route_key.mdk`. |
| `diff_compiler_selfproc` (LEG A) | re-cut, reviewed against the 4+4+5 expectation in §5. **CI `backend` shard only** — green locally, and it phantom-skips (exit 2 → `FAIL*`) without `test/bin/check_all_main`. |
| `diff_compiler_llvm_typed_ir` | **green, and must stay green.** Do not capture it. |
| `test/typecheck_compiler_source.sh` | 3 new ratchet allowlist entries. ⚠️ **Two of them discharge a red inherited from `a`** — the ratchets are `git grep`s over tracked files, so `route_key.mdk` tripped them from the moment it landed, unnoticed. |
| `rule-duplicate-body` on `rkEffAtom` | the `lint-disable-next-line` directive is **KEPT**. `a`'s row instructing its retirement is **refused, measured**: `e` deletes eval's copy but typecheck's `ppEffAtomTy` and doc's `ppEffAtomDoc` survive, so removing it exits 1 naming two files. (`DEBT.md` is append-only ⇒ this is an erratum, not an edit.) |

---

## 9. 🚧 TODO — owed before merge, not yet true at this draft

The working tree at draft time is **not quiescent** (`compiler/types/route_key.mdk` modified; three
untracked `test/dict_fixtures/` directories). Every line below is a close-out step that has **not run
on the post-`c` binary**:

- [ ] **Fixpoint, with the stage named.** The `C3a YES / C3b YES` result in `DEBT.md` `b1`+`e` was
      measured at **`ec1cda37`, i.e. before `c` landed**, and the C3a it names is *"IR1 byte-identical
      to the seed-bootstrapped reference"* — **which is the only C3a this claim covers.** Re-run
      `selfcompile_fixpoint.sh` on the post-`c` binary and a twice-refreshed seed and restate it here
      with the stage named. ⚠️ `ec1cda37`'s commit message gave the **unqualified** claim; the DEBT
      row does not. Do not quote the commit message.
- [ ] **Seed:** `test/refresh_seed.sh` **twice**. Expected a no-op — `git show --stat ec1cda37`
      touches no `compiler/backend/*` file — so a non-empty `git diff -- compiler/seed/` is the
      **surprise**, and needs explaining before the fixpoint.
- [ ] Goldens re-cut **once** from the final binary (§5).
- [ ] The segfault pin (§4) landed, or §4 deleted.
- [ ] #1514's program promoted to `dict_fixtures` before its pin is deleted (§8).
- [ ] Filing pass: F-2, F-8 (each naming the `TyConstrained` arm as the third member of the wildcard's
      set, so the fix audits the SET), F-3 (new), F-1 (cell on #1450), F-6/D-1 (cell on **#347**),
      F-4 (labelled derived-not-measured); plus the two unfiled follow-ups — the deferred
      `keyTable`/`KeyBuckets` deletion and the `b2` drop, **neither of which has an issue number
      anywhere in the ledger.**
- [ ] Desk closes: #1512, #1557, #1558 (**close comment must carry the re-scope — it landed as a
      SPLIT, not the deletion its body specifies**), #1559, #1514. 🚨 **#994 is an ANTI-CLOSE — this
      sprint WIDENED it** (eight lockstep `setRef`s at one site, two of them `f`'s). #1113: update the
      body, do **not** close.
- [ ] **#1068 / the wasm arm.** #1113's blast list says #1068's fix and this work must be done
      **together**; `grep -c '1068' .claude/sprint-phase3/DEBT.md` → **0**. Carry it here or append a
      `DEBT.md` erratum. Standing risk: wasm's method-less-impl default-dispatch coverage rests on a
      **separately maintained parallel family** (`headTagUniqueW`, `distinctKeysAtHeadW`, …) with zero
      hits for the shared table — an `evalModules`/`cevalModules`-class lockstep hazard.
- [ ] Owed peers, unedited by `b1`+`e`: `llvm_emit.implEntryRouteKey` / `implEntryRouteWords` /
      `headTagUnique` / `distinctKeysAtHead`, wasm's family, `core_ir_lower.distinctKeysAtHeadL`,
      and a **test** (not a patch) for `core_ir_eval.mdk:455`.
- [ ] **Not run by any bite:** perf/scaling, the wasm gates, `diff_compiler_selfproc`.
