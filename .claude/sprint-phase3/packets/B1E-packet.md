# Packet `B-2.2-b1` + `B-2.2-e` — the payload bite

**Branch:** `arch/stage-b-phase3-b22`. **Base:** `d5948e3a`.
**Worktree (absolute, always):** `/root/medaka/.claude/worktrees/expressive-prancing-minsky`
**This is the sprint's payload bite: it is where every deferred risk lands.**

---

## 0. Concurrency

**You are the ONLY writer live.** Tree quiescent, `git status` clean, binary built from exactly this
source. If the tree moves under you, **STOP and report** — do not adapt.

## 1. 🚨 `b1` IS TWO LINES. There are ZERO edits at the four `inst` arms

Every earlier ruling — including two of mine — describes `b1` as *"stamp identity at the four `inst`
arms"*. **That is wrong and the prep pass refuted it.** All four arms call `keyForSite` /
`keyForSiteByIface`, and **the row selection and the collision gate are already inside those two
functions**. The arms contain nothing but `fromOption tag (…)`.

```
compiler/types/typecheck.mdk:18440   Some (implKeyTc ir.irName tys)
  →                                  Some (implRouteKeyWord ir.irOrigin ir.irName tys None)
compiler/types/typecheck.mdk:19115   ditto
```

`ImplRow`'s third field is an `IfaceRef` carrying **both** `irName` and `irOrigin`, so **the origin is
already in hand at both sites.** Consequences, all of which you can rely on:

- **Do NOT "carry the collision gate."** An earlier ruling of mine (RUN-P3-006) says `b1` must; the
  gate is already inside `keyForSite*` and `b1` changes one expression *after* it. Lifting it out
  would create a second `IE` traversal and re-buy a measured +17% `check-self` cost.
- **Do NOT touch the no-row arm.** `fromOption tag` **is** the head-tag preservation RUN-P3-013
  required — already written. The non-collision arms stay `headKeyNameOr noneHeadTag …`; that bare
  tag is AD-1's absence state. **Do not "complete" them.**
- **D5/D6's element routes are untouched by construction** (they select on a possibly
  `innerDefaultMethod`-reduced name — a *different* key). `b2`'s prohibition is honoured with no
  explicit guard. **Say so in your `DEBT.md` row**: a future reader of a two-line diff cannot see
  that it was considered.

## 2. The commit split — by WORD CONTENT, not by side

`ir/core_ir_lower.mdk:61` **imports `implKeyOf` from `eval.eval`**, so the definition side is **one
function, not three**, and the seam has exactly two producers: `implKeyTc` (caller) and `implKeyOf`
(definition). A single atomic commit is **not** required. The safe split:

1. **Commit 1 — mirror deletion. Byte-identical, safe to build and publish.** Point both mints at
   `route_key.implRouteKeyWord` passing `OriginUnresolved`. Retire `route_key.mdk`'s
   `rule-duplicate-body` directive on `rkEffAtom` (`a` named `e` its owner — the comment there says
   so). Guaranteed byte-identical by `route_key`'s own compatibility doctests.
2. **Commit 2 — the origin, both sides at once. ATOMIC.** `ir.irOrigin` at `:18440`/`:19115`;
   `implOrigin` at `eval.mdk`'s two sites and `core_ir_lower.mdk`'s two. **A tree with only one half
   moved builds clean and type-checks clean** — the skew is invisible to every gate and live on the
   `RDict` path. `b1`'s two lines live here.

A single combined commit is also correct and costs only bisectability.

## 3. `e`: the site SET — and two sites you must NOT touch

Re-derive rather than trusting any list:
```sh
git grep -n 'implKeyOf\|implKeyTc\|declRouteKey' -- 'compiler/**/*.mdk'
```

**Edit (4):** `core_ir_lower.mdk:1301` (`ifaceImplHeadEntries` — `ifaceIdentity o ifaceName` is
computed into field 0 and dropped from the key at field 3) · `core_ir_lower.mdk:1399`
(`lowerImplMethod`) · `eval.mdk:305` (`declImplIfaceIdRow`, same shape) · `eval.mdk:2001`
(`implMethodEntry`) · plus the mint itself, `eval.mdk:481-483` (`implKeyOf`).

**No edit (consumers of the moved word):** `core_ir_lower.mdk:1343` (`ifaceRouteKeysGo`), `:1346`
(`declRouteKey` — `if unique then tag else key`; what changes is what `key` *is*), `:1361`
(`ifaceDeclHeadUnique`).

🚨 **DO NOT TOUCH `typecheck.mdk:18307` (`keyEntryOf`) or `:18962` (`keyEntryOfRow`).**
`KeyEntry`'s key field is written by those two and **read by nobody** — every destructuring in the
file binds other fields, and `bucketKeyEntriesFrom` only rebuilds it. Editing them adds
origin-threading with zero observable effect on the file whose snapshot and LEG A goldens are the
most expensive to move, and it manufactures the appearance that `implKeyTc` has four live callers
when it has **two**. If you change `implKeyTc`'s signature, pass `OriginUnresolved` there with a
one-line comment saying the field has no reader.
**M4 below is the fail-capable confirmation of that claim — run it before relying on it.**

**The only real plumbing:** `lowerImplMethod` and `implMethodEntry` have **no origin parameter**;
their callers (`lowerDeclImpl`, `declImplEntries`) do not bind `implOrigin`. Thread it.

**Guard against a grep-driven edit:** `wasm_emit.mdk:4090-4094` defines a *different function that
shares the name* `implKeyOf` (a local projection for `distinctImplKeys`). **Not a word mint. Do not
touch.** And `core_ir_eval.mdk:455` is a **consumer** — owed a *test*, not a patch, despite two
rulings flagging it in a way that reads as an owed edit.

**Phase 5's, not yours:** `llvm_emit`'s `implEntryRouteKey`/`implEntryRouteWords`/`headTagUnique`/
`distinctKeysAtHead`, wasm's independently-written family, `core_ir_lower.distinctKeysAtHeadL`.
They are your owed `engines:` peers and the reason acceptance survives a verdict skew —
`implEntryRouteWords` emits the **union** of `{routeKey, headTag}`.

## 4. ✅ The `ppTy` fold is SAFE — measured, so you need not re-derive it

`a` handed forward one large unverified assumption: pointing eval's callers at `rkTy` **widens**
eval's words, because typecheck's printer renders `TyEffect`/`TyConstrained` and eval's strips them.
**I measured it. The widening is unobservable, because the program that would observe it does not
typecheck:**

```
impl Sz Int  +  impl Sz (<Stdout> Int)   → check=1, run=1
  "Overlapping impls of Sz: Int and Int can match the same type."
impl Sz a    +  impl Sz (Eq a => a)      → check=1, run=1
  "Overlapping impls of Sz: a and b can match the same type."
```

**Coherence strips the effect/constraint too** — note the diagnostic says *"Int and Int"* — so two
impls differing only in an effect row or a constraint **cannot coexist**. ⇒ the fold cannot change
any accepted program's words on that axis. **`e` is safe here; record it as measured, not assumed.**

⚠️ **But a FOURTH divergence is live and `e` does NOT fix it.** `eval.headTycon` strips
`TyEffect`/`TyConstrained` to the inner head; `typecheck.headTyNode` does not. So the two sides
disagree on the **tag**, not the key. Measured, with a control:

```
impl Sz (<Stdout> Int)  alone  → check=0, run=0 [2], build=1
    E-PANIC: no impl of method 'sz' for type '__none__'
impl Sz Int             alone  → check=0, run=0 [2], build=0, exec [2], @mdk_impl_Int_sz
```

**`e` unifies the printers (word), not the head projections (tag), so this is out of scope and
unchanged by your bite.** Put it in `unchecked:` and do not attempt it. It is filed separately.

## 5. 🚨 `e` CHANGES A COLLISION VERDICT — and it makes our byte-identical claim false

`ifaceDeclHeadUnique` → `declKeysAtHead` dedups by **canonical key**, so an identity-bearing key
changes that count. Two same-spelled interfaces in different modules, each with an impl at head `T`:
today both keys are `"Speak|T|"` → dedup to one → `unique = True` → the definition side routes both
under the bare tag, **while the caller side already counts 2 rows and stamps `"Speak|T|"`. That is a
live skew today**, masked only by `implEntryRouteWords`' union arm. After your change the keys are
distinct, `unique = False`, and the skew closes.

⇒ **"byte-identical IR on programs with no head collision" is FALSE.** The defensible claim is
*"…and no two same-spelled interfaces in the module graph."* **Put the correct form in your
`DEBT.md` row.** A green `diff_compiler_llvm` must not be read as proof of the wider claim.

## 6. The fixtures you owe — built from the spec

Every existing fixture covers the *substituted* case, so **no existing fixture can fail.** Standing
rule: **`eval` is a known-wrong oracle on dispatch shapes** — hand-derive every expected value;
`CAPTURE=1` is inadmissible except where noted.

- **F1 — cross-module default inheritance.** A user impl of an interface from another module
  overriding **no** method (`fillImplDefaults` is same-module only), so `keyForSite` returns `None`
  and `fromOption tag` supplies the tag `emitDefaultRKey`'s `mdk_default_<method>_<TAG>` is keyed on.
  Pair it with a same-module twin. **Value assertion plus an IR assertion on that symbol with the
  concrete `<TAG>`** — an exit-code-graded control cannot see this, since the shape exits 0 today and
  would exit 0 with a wrong symbol right up until the link fails.
  ⚠️ **The IR half has NO HOME**: `diff_compiler_llvm_typed_ir.sh` reads a **single-file** corpus, and
  `diff_compiler_llvm_modules.sh` grades native stdout against an eval golden with no `.ll` golden
  anywhere. **Report which option you took**; the cheapest is an optional `entry.ll.golden` sibling
  in `diff_compiler_llvm_modules.sh` (a **new** `test/*.sh` trips the CI shard-coverage gate).
- **F2 — the no-default negative.** Same shape, interface default deleted: must stay exit 1 with its
  current diagnostic. It is the fail-capable half of F1.
- **F3 — the #1182 permutation pair, as a MUST-FAIL row.** `test/must_fail_fixtures/1182-*`. Not a
  value fixture: a value golden pins one order's answer and is structurally blind to the
  *wrong → differently wrong* transition your bite produces. **Capture inadmissible.**
- **F4 — the P4 tripwire. `b1` OWNS it.** ⚠️ **`b1` alone does NOT move P4's IR:** with one impl per
  interface the collision gate is False at both slots, so both still stamp the bare head tag and
  `@mdk_dc_0` appears twice, unchanged. **Pin that** (proving you did not widen), **and add a sibling
  with two impls of `Base`**, where the words must now differ — that sibling is where the change is
  observable and **blessing its IR diff is the review gate.** Keep the negative control (delete
  `impl Base T` → exit 1, missing-superinterface diagnostic).

## 7. Verify — this bite changes emitted IR, so these are load-bearing

```sh
make -C <worktree> medaka && make -C <worktree> check-self
sh test/typecheck_compiler_source.sh      # signature changes cross three modules
```

- 🚨 **`test/selfcompile_fixpoint.sh` — THE decisive gate.** `make preflight` forces it only on a
  `compiler/backend/*` diff; you touch `types/`, `eval/`, `ir/`, so **run it explicitly.** It can
  exceed the 10-minute foreground ceiling — **background it and poll**; `exit 143` at 600s is the
  ceiling, not a hang.
- **`test/diff_compiler_engines.sh`** — the only gate that can see an LLVM/eval divergence.
- **`diff_compiler_selfproc.sh`** needs its oracles built first (`check_all_main`,
  `eval_modules_main`, `eval_typed_modules_main`) or it exits 2 and reads as a skip.

🚨 **BLESS ZERO GOLDENS**, including the seed. Snapshot / `selfproc_legA` / `llvm_typed_ir` /
must-fail are expected-red for the sprint by design; they are re-cut **once**, at the close-out,
from the final binary, and the seed is re-minted there with `refresh_seed.sh` run **TWICE** (it is
not idempotent after a codegen change, and a stale seed can segfault the fixpoint on a perfectly
correct change).

⚠️ **An implementer who reports "byte-identical" has not exercised the change.** Expect moved words
at collision sites — and see §5 for the correct scope of the claim.

## 8. `DEBT.md` row — what it must carry

Standard six fields. Beyond the obvious, these must appear:
- **`b1` INHERITS #1182 rather than fixing it**, and makes it *quieter → different*:
  `ieCandidatesForMethod` is keyed `(method, head)` with **no interface component**, so at a
  `Beta`-typed site with an `Alpha` impl declared first the selected row is Alpha's. Today the
  head-tag hedge sometimes masks that; after `b1` the wrong instance's **identity** is stamped
  directly. F3 is the watching artifact.
- **`sanitizeId` is not injective and `e` widens the alphabet reaching it.** ⚠️ Module ids are
  loader-derived **paths**, and `.`, `/`, `-` **all** sanitize to `_` — so `a.b::I|T|`, `a/b::I|T|`
  and `a-b::I|T|` collide. (An earlier example of mine claiming `a_` + `_Alpha` collides was
  **wrong** — each offending char maps to a *single* `_`. Do not relay it.) Separately, the runtime
  word is `hashName key` (djb2), a **second, independent** collision channel.
- **`D1-leak`**: a rigid in-scope goal whose lookup misses falls through to `inst`. `b1` makes that
  wrongness *nameable* without fixing it; #1127 legs 1–2 are B-1's. State it; do not attempt it.
- **`engines:` all four arms**, naming LLVM's `implEntryRouteKey`/`implEntryRouteWords` and wasm's
  independent family as **owed peers**, and `core_ir_eval` as a consumer owed a test.
- **`could move:`** every emitted impl symbol and every `hashName`'d dict word at a collision site ⇒
  the seed, the IR-text golden, and the LEG A scheme goldens (all three edited modules are LEG A).
  **Not acceptance** — except through §5's verdict change. And: `pickMostSpecificEntry` still
  *returns* the first match after reporting, so **a rejected program's routes must stay unchanged —
  assert that, do not assume it.**

## 9. One measurement to run yourself, before relying on §3

**M4 — is `KeyEntry`'s key field really dead?** Replace the word at `:18307` and `:18962` with a
literal `"__DEAD__"`, then `make medaka && make check-self` and run
`sh test/diff_compiler_dict_semantics.sh`. **Green ⇒ dead, and §3's skip is correct.** Red ⇒ my
derivation is wrong and `e` grows two sites. The grep alone is not the evidence; this is.

## 10. Traps

- **`!=`, not `/=`.**
- `fmt --write` + `lint` on touched files **before** `make` — cheap checks first.
- **Exit codes do not survive a pipe.** Redirect, read `$?`, then read the file.
- **`main` must be a zero-arg value** in probes.
- **Never name a probe method after a prelude method** (`add`/`sub`/`mul`/…) — measured this
  session: a method named `sub` makes the built binary print a leaked pointer at exit 0.
- **Absolute paths everywhere.** Shell cwd resets between calls.
- **Line-count neutrality** if you edit a comment in a file with a golden pinning lines below it —
  `typecheck.mdk` is in the snapshot corpus. You also **own a comment fix**: `:18354-18360`'s
  *"rests on the emitter's general-instance fallback tier: `emitGeneralRKey` → `findByTag
  noneHeadTag`"* **names the wrong tier** (measured — that tier is unreachable from the `None` arm;
  the real one is `emitDefaultRKey`). Fix it in place rather than relaying it a third time.

## 11. Refuse, explicitly

**Report disagreements rather than resolving them silently.** In this sprint the prep passes have
already re-cut `a` (lost its type change entirely), `f` (lost its `CSlot` field) and `b1` (lost its
four-arm edit) — **every one by refusing the ruling it was handed.** If §1's two-line claim, §3's
site set, or §5's verdict analysis does not survive contact with the source, **STOP and report with
your derivation.** A refused bite is landed work.

## 12. Closing section, mandatory

**TIME ACCOUNTING**: split (orientation · derivation · edits · build/gate · report) · biggest sink ·
**what did you have to DERIVE that this packet could have handed you?** · what of this packet was
wasted · build cycles and which were avoidable. Reading and thinking are PRODUCTIVE; only build churn
and report-writing are overhead.
