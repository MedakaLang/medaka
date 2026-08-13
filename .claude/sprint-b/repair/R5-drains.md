# R5 — adversarial drain gate: #1564, #1599, #1072 (+ #1071/#1062, #1397/#1514)

Read-only, pinned at `61c4eebd`. **No build, no gate, no `./medaka` run.** Every verdict below
separates *"the pin flipped"* from *"the filed mechanism is addressed"*. Everything I could not
execute is marked **⚠️ UNVERIFIED** with the exact command.

---

## 0. The structural fact that shapes all three verdicts

`B-2.1-g` (`26423f93`) is **entirely a typecheck-side change**. Derived, not assumed:

```sh
git diff --stat 2b9dc798..61c4eebd -- compiler/
#   compiler/ir/core_ir_lower.mdk   12 +-      (comments only — verified by reading the diff)
#   compiler/types/registry.mdk      7 +-
#   compiler/types/typecheck.mdk  1819 ++++---
#   compiler/seed/emitter.ll.gz    (re-mint)
```

`compiler/backend/llvm_emit.mdk` is **untouched**. So `implEntryRouteWords` still returns the bare
head tag *and* the canonical key for every impl, and `emitRouteWordMatch` still ORs the bare head
into **every arm at that head**. #1072's filed mechanism — *"the bare-head word is OR'd into every
arm"* — is **still present in the compiler.** What `g` changed is the *producer*: `keyForSite` now
selects and counts over the graph-global `perRun.bodyImplEnvRef`, so a site at a colliding head
stamps the canonical key instead of the bare head, and the ambiguous word is (supposedly) never
stamped.

That is legitimate — issue #1072's own **"Fix direction"** offers exactly two remedies and this is
the first (*"the site must stamp something that identifies the impl it resolved to"*). But it means
**#1072 is closed only if NO remaining path can stamp a bare head at a head where two impls
collide.** That is the whole of my #1072 analysis below, and it is where I found a hole.

---

## #1564 — import-line order decides acceptance → **CLOSE** (one cheap re-run owed)

**Filed mechanism.** Instance candidacy + evidence were *cumulative over a topological prefix*, so a
conditional `impl Tag (Wrap a) requires Tag a` reached `nest.mdk`'s goal only if `wrapimpl` sorted
earlier — decided by two import lines in a third module. DICT §8 I5 requires graph-global candidacy.

**Fix mechanism.** `ieImplExistsForHead` + `keyForSite` + the three selection legs all read
`perRun.bodyImplEnvRef` (the graph-global `ImplEnv` seated on **both** driver arms by `B-2.1-a2`).
The population the checker asks is no longer a prefix. **This is the mechanism the issue filed**, and
it is the exact reader-move `TYPECHECK-TARGET-ARCHITECTURE.md:1815` and the fixture's own
`why-architecture:` block name as the true drain condition (*"drains when the residual reducer's
evidence lookup … reads the graph-global `IE` instead — i.e. when ARCH B-2 moves that reader"*).
Mechanism-match, and match against the **corrected** drain criterion, not the original wrong one.

**The false-drain risk was real and was closed.** This pin grades `check-json` **only**, and its own
claim.txt warns that between A-3.6 and Door 4 `check` was already exit 0 *while the built binary
segfaulted at 139* — "a clean drain for half a drain". `DEBT.md` records the four-arm answer on the
implementer's binary: `main.mdk` **and** `control.mdk` both `check` 0 / `build` 0 / **binary 0
printing `wrap(int)`**, no `T-ROUTE-WORD-AMBIGUOUS` in either stream, and the `.ll` shows
`@mdk_impl_Wrap_tagOf` arity-2 with **both** call sites passing two args — the arity-1-call-to-
arity-2-define shape that segfaulted is absent. **Not a check-only drain.**

**Sub-class accounting (asked for explicitly):**

| sub-class | status |
|---|---|
| **concrete head** (`Wrap Int` — the fixture) | **DRAINED**, four arms |
| **bare-tyvar head** (`impl Tag a requires Dbg a` in an unimported module) | **DRAINED** — `ieCandidatesForIface` unions `ieHeadRows None` graph-globally, so leg 1 reaches it before the `univHeadless` fallback. Base was a run≠build divergence (`run` E-PANIC, native correct); all three arms agree now. |
| **`tys = []`** | **UNTESTED, and not testable** — RUN-B-030 records it cannot be produced from surface syntax. Record it as an unclosable residual; do not let it block closure. |
| **goal whose head is not a tycon** (`goalHeadCon` = `None`) | **STILL FALLS TO THE PREFIX-READ FALLBACK** — `firstReqMatch (univHeadless univ iface)` and `findMatchingImplReqsU`'s `iface []` clause still read `univ`. **Not #1564's shape** (its goal is `Wrap a`, headed), but it is the residual that survives this fix and it belongs in a successor issue, not in #1564's closure. |

**Verdict: CLOSE**, with the residual sub-classes recorded in the closing comment.

**⚠️ UNVERIFIED, and it is the one thing I want re-run:** the four-arm measurement above was taken on
`B-2.1-g`'s binary. `EX-1`/`EX-2`/`EX-3` landed after it (13 deletions, a **seed re-mint ×2**, a
golden re-cut). `EX-4` re-certified `SA-4c`, which is a *variant*, not this fixture. Re-run on the
pinned binary:

```sh
cd test/must_fail_fixtures/1564-import-order-decides-conditional-impl-candidacy
MEDAKA_STRICT=1 /abs/medaka check main.mdk    > /tmp/c1.log 2>&1; echo "check main:    $?"
MEDAKA_STRICT=1 /abs/medaka check control.mdk > /tmp/c2.log 2>&1; echo "check control: $?"
/abs/medaka build main.mdk    -o /tmp/o1 > /tmp/b1.log 2>&1; echo "build main:    $?"; /tmp/o1; echo "  -> $?"
/abs/medaka build control.mdk -o /tmp/o2 > /tmp/b2.log 2>&1; echo "build control: $?"; /tmp/o2; echo "  -> $?"
# EXPECT: 0 0 0 / wrap(int) / 0 / wrap(int).  Redirect, never pipe — build's exit code dies in a pipe.
```

**Discriminating variant** (a shape the fix should not care about — same mechanism, one extra level
of `requires` recursion, so it tests whether the *whole chain* moved off the prefix or only the top
read). Put in `/tmp/d1564/`, entry `main.mdk` with `import deep` **last**:

```medaka
-- iface.mdk
public export data Wrap a = Wrap a
public export data Pair a b = Pair a b
export interface Tag t where
  tagOf : t -> String
export impl Tag Int where
  tagOf _ = "int"

-- wrapimpl.mdk        (level 1 conditional; not imported by nest)
import iface.{Tag, tagOf, Wrap}
export impl Tag (Wrap a) requires Tag a where
  tagOf (Wrap x) = "wrap(\{tagOf x})"

-- deep.mdk            (level 2 conditional, depends on level 1; not imported by nest)
import iface.{Tag, tagOf, Pair}
export impl Tag (Pair a b) requires Tag a, Tag b where
  tagOf (Pair x y) = "pair(\{tagOf x},\{tagOf y})"

-- nest.mdk            (imports NEITHER conditional impl)
import iface.{Tag, tagOf, Wrap, Pair}
export nest x = tagOf (Pair (Wrap x) x)

-- main.mdk            (the LOSING order: both impl modules imported AFTER nest)
import iface.{Tag, tagOf, Wrap, Pair}
import nest.{nest}
import wrapimpl
import deep

main = println (nest 5)
-- EXPECT check 0, build 0, binary prints  pair(wrap(int),int)
-- A T-REQUIRES-UNROUTED / T-NO-IMPL reject here, or a 139, means the depth-2 chain
-- still reads a prefix and #1564's mechanism survives one level down.
```

---

## #1599 — reachable conditional beats unreachable more-specific → **CLOSE**

**Filed mechanism.** Candidacy consults the graph-global `IE` while **evidence/selection** consults
the cumulative `universeKeyBucketsRef`/`shadowKeyTableRef`, so the *wrong impl* is routed (not a
missing one — which is why Stage A's `T-REQUIRES-UNROUTED` guard cannot fire: its lookup returns
`Some`). Fix owed to B-2: *"IE supplies the data, B-2 moves the reader."*

**Fix mechanism.** `B-2.1-b2` moved all three selection legs onto `bodyImplEnvRef`; `B-2.1-g` moved
the route word and the three existence reads onto the same ref. **That is literally the deferred
reader move the issue names.** Mechanism-match.

**The specific false-drain hazard here was raised, chased, and cleared — this is the important
part.** R2 (`bc043c43`, finding 2) observed that a `build-run` must-fail pin flips **DRAINED on a
build refusal exactly as it does on a real fix**, and that `B-2.1-f`'s safety derivation claiming
#1599 *"declares ONE impl at the head"* was **factually false** — `impl Show2 (Box …)` is declared in
**both** `gen.mdk` and `spec.mdk`. That is the "right conclusion, wrong reasoning" case in this
sprint. It was answered by measurement rather than argument (`DEBT.md`, g's orchestrator follow-ups):
`check` **0** (`main : Unit`), `check --json` **0** with `"diagnostics":[]` and **zero**
`T-ROUTE-WORD-AMBIGUOUS`, `build` **0** (file redirect, not a pipe), **built binary exit 0 printing
`5`** — and `5` is the value the fixture's own claim.txt names as correct against the pinned-wrong
`1003`. **Genuine drain, not a refusal.** R2's finding is moot because `g` retired `f`'s guard; the
finding was still right on the fact and I am recording that separately from the verdict.

**Verdict: CLOSE.**

🚨 **Closure has a mandatory companion action, from the fixture's own `drains-when:`** — replace the
pin with a **POSITIVE row asserting `stdout: 5`**. Deleting it outright leaves the S0 unguarded,
which `test/diff_compiler_dict_semantics.sh` records as a mistake made three times.

**⚠️ UNVERIFIED (same staleness caveat as #1564 — measured on g's binary, not `61c4eebd`):**

```sh
cd test/must_fail_fixtures/1599-reachable-conditional-beats-unreachable-specific
/abs/medaka build main.mdk    -o /tmp/s1 > /tmp/s1.log 2>&1; echo "build: $?"; /tmp/s1; echo " -> $?"   # EXPECT 5
/abs/medaka build control.mdk -o /tmp/s2 > /tmp/s2.log 2>&1; echo "build: $?"; /tmp/s2; echo " -> $?"   # EXPECT 5
```

**Discriminating variant** — the fix should not care *how far* the specific impl is from the goal's
module. Add `user.mdk` a second hop away and pose the goal from a module that imports **neither**
`gen` nor `spec`:

```medaka
-- deepuser.mdk   (imports iface + base ONLY — sees ZERO impls at head Box)
import iface.{T(..), Box(..), Show2, show2}
import base
export deepIt = show2 (Box T)

-- main2.mdk
import deepuser.{deepIt}
import base
import gen
import spec
main = println deepIt
-- EXPECT 5.  1003 means reachability still decides and #1599's mechanism survives
-- at a module that sees no impl at the head at all.
```

---

## #1072 — most-specific-wins decided by module order → 🚩 **NEEDS A PROBE (do NOT close yet)**

**Filed mechanism**, quoted from the issue: `implEntryRouteWords` returns *"the canonical key AND the
bare head tag"*, `emitRouteWordMatch` ORs one `icmp` per word, so `hashName "Box"` is OR'd into
**both** arms; typecheck stamps the bare head because a.mdk's prefix holds one impl at head `Box`;
the site matches arm 1 unconditionally and **the specific arm is dead code**.

**Fix mechanism.** The **emitter half is untouched** (§0). `g` addresses the *stamping* half:
`keyForSite` selects via `ieSelectRowByMethod` and retests collision via `ieHeadCollidesByMethod`,
both over the graph-global env, so a colliding head yields `implKeyTc ir.irName tys` — the canonical
key. `DEBT.md` records #1072's binary flipping `general` → `specific` at `B-2.1-b2` (it reaches
dispatch through the **iface**-keyed leg 2b, `keyForSiteByIface`). On the issue's own terms this is
remedy #1 of its stated fix direction, so for **the program the issue filed** it is a mechanism-match.

### But the class is not closed, and here is the hole — derived from source, not inferred

The checker's method-keyed collision count and the emitter's count apply **different predicates over
the same population**:

```
compiler/types/typecheck.mdk:19230   ieCountHeadByMethodGo (ImplRow _ _ _ tys _ ms) …
  | contains name ms && headTabEq (univReceiverTag tys) goal        <-- METHOD-NAME MEMBERSHIP
compiler/types/typecheck.mdk:18946   ieEntriesForMethod …            <-- same filter for CANDIDACY
compiler/types/typecheck.mdk:18937   ieEntriesForIface …             <-- filters on ir.irName ONLY
```

`compiler/ir/core_ir_lower.mdk`'s own comment states the emitter side is iface-keyed and says why
that matters: *"filters on the impl's iface, not on method-name membership — **so a specific impl
that inherits a method via a DEFAULT is still seen**."* And the same file, in the diff `g` landed:
*"The arithmetic still differs and that difference is pre-existing: this side counts DISTINCT
canonical keys, that side counts rows."*

Now combine with `compiler/frontend/desugar.mdk:834` `fillImplDefaults`, whose header is explicit:

> *"Universal across all interfaces; **same-module only** (sees just `DInterface` defaults co-located
> in this decl list — a user impl of a prelude interface **in another module keeps using the
> fallback**, as intended)."*

⇒ **In a MULTI-MODULE program where the interface and the impl live in different modules, an impl
that inherits a default does NOT get that method synthesized into its `methods` list**, so its
`ImplRow`'s `ms` does not contain the name. Therefore `ieCountHeadByMethod` counts **1**,
`ieHeadCollidesByMethod` is **False**, and `keyForSite` takes the `else` branch and stamps
**`headKeyNameOr noneHeadTag (univReceiverTag tys)` — the BARE HEAD**. The emitter, counting
iface-keyed over the whole program, sees **two** impls of `Speak` at head `Box`, keys the arms by
canonical key, and ORs the bare head `Box` into both. **Arm order decides. That is #1072's filed
mechanism, verbatim, surviving `g`.**

**A second, independent hole in the same function.** `keyForSite`'s `None` arm carries this safety
argument:

> *"the graph agreeing there is no impl means there is no second impl for that bare word to name"*

but its own preceding sentence names **two** ways to reach it: *"No impl anywhere in the graph
defines `[name]` at this goal's head **(or the goal has no head tycon at all**, `ieSelectRowByMethod`'s
`None => None` arm)"* — and `ieSelectRowByMethod` (typecheck.mdk:19003) does exactly
`match goalHeadCon goals … None => None`. **The justification covers only the first case.** In the
second, every caller answers with `fromOption tag (…)` and stamps a bare word that the graph may well
have two impls for. `AD-1` (`5ef29a60`) corroborates from the other side: the D8/D9 sites
(`routeUndeterminedTop`, `resolveRecMono`) *"still stamp bare tags with no selector"*, and D8 is
reachable **only** when `headTyconNameMono` is `None` — the same headless case. AD-1 also reproduced
a silent wrong answer in that region.

### 🔬 The discriminating program — a variant of #1072's own repro

One variable changed, and it is one the fix should not care about: **`b.mdk`'s more-specific impl
inherits `speak`'s default instead of overriding it.** Everything else — module topology, the site,
the receiver, the interface, `a` not importing `b` — is #1072's fixture unchanged.

```medaka
-- iface.mdk   (+ one required method so the specific impl is not method-less)
export interface Speak a where
  speak : a -> String
  speak _ = "DEFAULT"
  other : a -> Int

-- a.mdk       (site + ONLY the general impl; does NOT import b) — as in the fixture
export import iface.{Speak(..), speak, other}
public export data Box a = Box a
impl Speak (Box a) where
  speak _ = "general"
  other _ = 0
export useA : Speak a => a -> String
useA x = speak x
export callA : String
callA = useA (Box 1)

-- b.mdk       (strictly MORE SPECIFIC — and INHERITS `speak`)
import a.{Speak(..), speak, other, Box(..)}
impl Speak (Box Int) where
  other _ = 1

-- main.mdk
import a.{callA}
import b
main = println callA
```

* **CORRECT: `DEFAULT`** — `Speak (Box Int)` is strictly more specific than `Speak (Box a)`, and it
  inherits the interface default, so a `Box Int` receiver must reach the default body.
* **`general` ⇒ #1072's filed mechanism is ALIVE** in the method-keyed leg, and closing #1072 would
  file a live S0 as fixed.
* **Mandatory positive control (proves the probe can fail, and isolates the cross-module axis):** the
  same program **flattened into one file**. `fillImplDefaults` then sees the co-located
  `DInterface`, synthesizes `speak` into the `Box Int` impl, `ms` contains `speak`, the count is 2,
  the canonical key is stamped — so the single-file arm **must print `DEFAULT`**. If the single-file
  arm also prints `general`, the defect is broader than #1072 and this probe is not discriminating.
* **Mirror control** (as #1072's own claim.txt insists): swap which module holds which impl; must
  also print `DEFAULT`.

```sh
mkdir -p /tmp/d1072 && cd /tmp/d1072   # write the four files above
/abs/medaka run   main.mdk           > /tmp/d1072/run.log  2>&1; echo "run:   $?"; cat /tmp/d1072/run.log
/abs/medaka build main.mdk -o /tmp/d1072/out > /tmp/d1072/b.log 2>&1; echo "build: $?"
/tmp/d1072/out; echo " -> $?"        # EXPECT DEFAULT.  `general` = #1072 alive.
# and the IR, which is the authority on the mechanism rather than the value:
/abs/medaka build main.mdk -o /tmp/d1072/out --keep-ir > /dev/null 2>&1
grep -n 'icmp eq i64' /tmp/d1072/out.ll   # a bare `hashName "Box"` word OR'd into >1 arm = the bug
```

**Verdict: NEEDS A PROBE.** If the probe prints `DEFAULT` on all three arms → **CLOSE #1072** and
file the `None`-arm/headless-goal residual as a successor issue. If it prints `general` → **DO NOT
CLOSE**; the drain is real for the filed *program* but the filed *mechanism* survives, and the issue
should be re-scoped rather than closed.

**⚠️ Also UNVERIFIED and cheap:** #1072's binary was measured printing `specific` at `B-2.1-b2`, not
at `61c4eebd`. Re-run its own fixture (`build-run main.mdk` → `specific`, `control.mdk` → `specific`)
on the pinned binary before closing.

---

## #1071 vs #1062 — **DUPLICATE, high confidence, one probe owed**

Both are eval-only S0s: *a sibling-method call inside an interface **default body** is not re-narrowed
when the head tycon collides; the inner call resolves to the first impl at that head.* Both use `Box
Int` / `Box String` at shared head `Box`, both have `check` 0 and native correct.

**#1071's stated discriminator is refuted by #1062's own repro.** #1071 says: *"A default body with
only ONE sibling call did not reproduce for me … The defect appeared only with the **two**-sibling-call
body."* #1062's `loud x = "<" ++ speak x ++ ">"` has **exactly one** sibling call and reproduces
(`<boxint>` twice). So the sibling-call *count* is not an axis, and #1071 is a strictly more elaborate
instance of #1062 — not a distinct mechanism. #1071's other stated difference ("only `describe` is
inherited") is also present in #1062, where **neither** impl defines `loud`.

**Consequence for the run's output:** counting them separately inflates the drain surface — one fix
to eval's default-body sibling re-narrowing drains both pins. Neither is currently drained; both are
`REPRO`, correctly.

**Verdict: recommend #1071 be closed as a duplicate of #1062** — a tracker hygiene action, **not** a
drain, and **not** something I did. ⚠️ **UNVERIFIED — one confirming probe** (both pins already exist,
so this is two commands):

```sh
/abs/medaka run test/must_fail_fixtures/1062-eval-sibling-call-in-default-head-collision/main.mdk
/abs/medaka run test/must_fail_fixtures/1071-eval-inherited-default-sibling-calls-typearg/main.mdk
# Both must show the SAME signature: line 2 repeating line 1's impl.  If #1071 reproduces while a
# ONE-sibling-call variant of #1071's own program does NOT, the count IS an axis and they are not dups.
```
Keep **both fixtures** either way — deleting #1071's pin loses the differing-type-args + two-method
coverage. Only the *issue* is the duplicate.

---

## #1397 and #1514 — **DO NOT CLOSE. Both legitimately REPRO for their FILED reasons.**

Verified from the pins themselves rather than from the run's summary. Both grade the **original
silent-wrongness observable**, not the guard's refusal:

```
1397-xmod-samename-type-impl-symbol-collapse/claim.txt:  cmd: run main.mdk / exit: 0 / stdout: aamod|aamod
1514-xmod-same-spelled-iface-impl-selection/claim.txt:   cmd: run main.mdk / exit: 0 / stdout: 11,11,7
```

A `REPRO` on those rows **requires `run` to succeed and print the wrong value** — it cannot be
satisfied by a refusal. So their return to `REPRO` after `g` is exactly the un-refusal it is claimed
to be, and their filed defects are alive. `EX-4` (`89a9536b`) reports #1514's transition as the
proof: under `f`'s guard it read `DRAINED` (the build refused, so the bug became *unobservable*), and
the only route back to `REPRO` is a succeeding build. **That is a capability regression being
cleared, not a fix.** Confirmed: neither issue's mechanism was touched by anything in
`2b9dc798..61c4eebd`.

---

## What I refused

* I ran **no build, no gate, and no `./medaka`** — every measurement quoted above is attributed to
  the commit or `DEBT.md` entry that took it, and every claim I could not source is marked
  ⚠️ UNVERIFIED with its command. I did not launder a recorded measurement into a first-hand one.
* I closed **nothing** and ran no `gh issue close`.
* I did **not** re-derive the `must_fail` counts; the three-DRAINED/0-malformed result is taken as
  given by the brief and is not what I was asked to re-check.
* I state plainly that the four-arm evidence for **all three** drains was taken on `B-2.1-g`'s
  binary, **before** `EX-1`'s 13 deletions, `EX-2`'s double seed re-mint and `EX-3`'s golden re-cut.
  `EX-4` re-certified `SA-4c` (a variant) and the `must_fail` names on the final binary, but **not**
  the per-fixture stdout. Three of the commands above close that gap in about a minute.
