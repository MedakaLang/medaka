# D2 — Phase 5 (B-2.4), the engine arms: refreshed bite cut

**Agent:** D2 (design, read-only). **Pinned read commit: `604278bb`** (`sprint-b: B-2.1-b1 REFUSED
and reverted; STOP-AND-LAND gate triggered`), which is also `HEAD` at the time of writing. **Every
line citation in this file is `@604278bb`** and was read off `git show 604278bb:<path>` copies in
`/var/tmp/…/scratchpad/d2/`, never off the working tree — a writer is live in
`compiler/types/typecheck.mdk`.

**What I did NOT do:** no build, no `make`, no gate, no `./medaka`, no `refresh_seed.sh`, no probe,
no edit outside this file. **Nothing here is a measurement.** Where a measurement is required I say
whose it is and what command produces it.

**Skill loaded:** `benchmark-emitter`. Its two rules are carried into §0's safety envelope and are
not restated per bite.

**Refreshes, does not repeat, `phase0/P0-C-engines.md`.** Read that file for the derivations of
*what the three engines do today* (§1), the #1068 ruling (§2), the wasm-absence derivations (§3),
the P0-B seam (§5) and the verification posture (§6). This file carries only what CHANGED, what was
WRONG, and the two bites P0-C did not cut.

---

## 0. The one structural fact that makes P0-C's site lists still usable

```sh
git diff --stat 2b9dc798 604278bb -- compiler/
# → compiler/TYPECHECK-TARGET-ARCHITECTURE.md | 2 +-
#   compiler/types/typecheck.mdk              | 230 ++++++++---
```

**Only `compiler/types/typecheck.mdk` changed between P0-C's base (`2b9dc798`) and `604278bb`.**
`llvm_emit.mdk`, `wasm_emit.mdk`, `eval.mdk`, `core_ir_eval.mdk`, `core_ir_lower.mdk`,
`core_ir.mdk` and `ast.mdk` are **byte-identical**. So every engine-file line number in P0-C is
still valid, and I **re-verified rather than re-derived** a sample of them (`llvm_emit.mdk:5336`
`emitDispatchArm`, `:5356` `emitRouteWordMatch`, `:1512` `implEntryRouteWords`, `:5491`
`implEntryTags`; `eval.mdk:1206-1212` `hasTag`/`matchesTag`, `:1998-2004` `implMethodEntry`;
`wasm_emit.mdk:4034` `implEntryRouteKeyW`, `:4456` `methodImplKey`) — all reproduce exactly.

⚠️ **One P0-C citation does NOT reproduce, and the file did not move**, so this is a mis-citation,
not rot: the *"UNTYPED path, like cevalProgram / evalModules"* comment is at
**`core_ir_eval.mdk:522`**, not `:598` (`:598` is inside `cInstallModGroups`). RUN-B-013 relayed
`:598` into a **mandatory `DEBT.md` condition**, so the wrong number is now load-bearing in the
contract. Derive: `grep -n 'UNTYPED path' compiler/ir/core_ir_eval.mdk` → one hit, `:522`.
**And the comment says more than RUN-B-013 took from it — see §3.**

**Safety envelope, carried by every bite below (from `benchmark-emitter`, not restated per bite):**
the self-compile fixpoint is in-band at this unit's boundary; **`test/refresh_seed.sh` is NOT
idempotent after a codegen change — run it TWICE** (pass 1 mints with the old-generation emitter
and still reports `C3a: NO`); **a stale seed can SEGFAULT the fixpoint on a perfectly correct
change**, so a fatal memory fault while `make medaka` and `check-self` are clean means **re-mint
before bug-hunting**; if anything here is *measured*, **two rebuilds, not one** — one rebuild gives
new behaviour compiled by the old emitter and crosses the arms; never baseline off another tree's
`medaka_emitter`. Bless **zero goldens**.

---

## 1. 🚨 RULING on item 1: `B-2.4-a` and `B-2.4-b` are **NOT admissible at Phase 2′. They fall back to Phase 5.**

RUN-B-013's overturn criterion is *"`a` is admissible at 2′ **iff** all 7 stampers +
`stampImplTable`/`stampKeyTable` + the Flat peer are whole-graph."* Re-evaluated against
`604278bb` and against RUN-B-024's re-planned 2′: **it fails, and it fails on a leg the criterion
does not enumerate.**

### 1.1 The variance the hedge exists for is produced by the COLLISION TEST, not by the selector

The superset-OR hedges *bare-head-vs-canonical-key* variance. That word is chosen in exactly one
place, and the branch is gated by a **different function** from the one b2 repoints:

```
typecheck.mdk:17973-17987  keyForSite table name goals = match matchedEntry table name goals
                             Some (KeyEntry _ hd _ key _ _ _ _) =>
                               if headCollides table name hd then Some key      -- canonical
                               else Some (headKeyNameOr noneHeadTag hd)         -- ⚠️ BARE HEAD
```

- `headCollides` (`:18532-18533`) → `countHead` (`:18606-18609`), whose body is
  `countHeadGo (bucketOfHead hd buckets) name (headTabOf hd)` — it reads `bucketOfHead` **directly**,
  **not** through `matchedEntry` / `matchingEntries` / `candidateBucket`. It is a *sibling* reader of
  the same `KeyBuckets`, not a caller of the selector.
- The iface-keyed twin is the same shape: `keyForSiteByIface` (`:18658-18666`) gated on
  `headCollidesByIface` (`:18669-18670`) → `countHeadByIface` (`:18675-18678`), also
  `bucketOfHead` direct.
- `buckets` at every one of those sites is the threaded `stampKeyTable = buildKeyTable implDecls`
  (`:28838`), and `implDecls` is documented in this very function's own header as *"core + every
  EARLIER module + this module"* (`:28822-28824`) — **a cumulative prefix.**

That prefix *is* #1072's mechanism, quoted in P0-C §1: *"`a` does not import `b`, so `a`'s
`KeyBuckets` hold one impl at head `Box` → no collision → typecheck stamps the bare head."* The
no-collision branch above is the line that stamps it.

### 1.2 The re-planned 2′ does not repoint that function — and says so explicitly

RUN-B-024's re-plan is `B-2.1-a3` (a head-across-interfaces index in `ieInsertRow`/`ieIndexRows`)
+ `B-2.1-b2` (repoint **three legs**: the checker `concreteReqMatchByIface`; the route-word/
`requires` router `keyForSiteByIface`+`selectReqImpl`; the method-keyed dict router `matchedEntry`
→ `matchingEntries`). RUN-B-023 RULING 2 then states, in its own words, that the non-`ByIface`
siblings **`matchedEntry`, `matchingEntries`, `countHead`, `headCollides`, `keyForSite` stay
LIVE**.

So after 2′ closes as re-planned:

| route-word site `@604278bb` | gate | gate's population after 2′ |
|---|---|---|
| `:19140` `keyForSiteByIface keyTable iface (m::rest)` (`entailInst` `EKNestedTop`) | `headCollidesByIface` | **whole-graph** (the `…ByIface` family dies with the repoint) |
| `:19112` `keyForSite keyTable name paramMonos` (`entailInst` `EKReturn`) | `headCollides`→`countHead` | ⚠️ **still the prefix `stampKeyTable`** |
| `:19155` `keyForSite keyTable name goals` (`entailInst` `EKArg`) | `headCollides`→`countHead` | ⚠️ **still the prefix** |
| `:15387` `keyForSite keyTable method [operandMono]` (operator site) | `headCollides`→`countHead` | ⚠️ **still the prefix** |

**Three of four route-word production sites keep a module-local collision verdict.** `a3` indexes
`ImplEnv`; it does **not** widen `buildKeyTable`'s input, so the criterion's own named condition —
*`stampKeyTable` whole-graph* — is not delivered either. Reading the criterion loosely as *"the
three legs are graph-global"* satisfies its letter and misses this entirely.

**⇒ RULING: the criterion FAILS. `B-2.4-a` stays in Phase 5, and `B-2.4-b` follows it** (RUN-B-013:
*"`b` follows `a`"*, because `memoSelector`'s contract is *"the string an `RKey` occurrence
carries"*). Per the criterion's own closing clause, deleting the OR in this mixed state *"converts
#1072's wrong-impl into a TRAP"* — and worse than the criterion anticipated: a **subset** of sites
would carry whole-graph words while the rest carry module-local ones, against **one** global
emitter verdict.

### 1.3 The asymmetry that makes this concrete (and the criterion's amendment)

The *lowering* side is **already whole-program**: `ifaceDeclHeadUnique` (`core_ir_lower.mdk:1355-1357`)
reads `ifaceImplHeadsRef`, installed once at `lowerImpls` (`:1228`) from `lowerProgramEmit
allDecls`, with its own comment naming that chokepoint *"the one … every emit path funnels through
with the WHOLE program's decls"* (`:1269-1274`). `declRouteKey tag key unique = if unique then tag
else key` (`:1346-1347`). So the emitter computes one whole-program verdict while typecheck
computes a per-module one — and the superset-OR is the patch over that difference. **The hedge is
deletable exactly when the typecheck side's collision verdict is also whole-program, at all four
sites.**

> **AMENDED overturn criterion (supersedes RUN-B-013's wording).** `B-2.4-a` may land at the end of
> 2′ **iff, in addition to** the 7 stampers (`typecheck.mdk:28839,28840,28841,28843,28844,28846,28847`)
> + `stampImplTable` (`:28833`) + `stampKeyTable` (`:28838`) + the Flat peer, **the COLLISION TEST
> is whole-graph at all four route-word sites** — i.e. `headCollides`/`countHead` (`:18532-18533`,
> `:18606-18609`) and `headCollidesByIface`/`countHeadByIface` (`:18669-18670`, `:18675-18678`) read
> the graph-global substrate, not a prefix `KeyBuckets`. **Mechanical check, no build:**
> ```sh
> grep -n 'if headCollides\|if headCollidesByIface' compiler/types/typecheck.mdk   # the 2 gates
> grep -n 'buildKeyTable\|stampKeyTable' compiler/types/typecheck.mdk              # their population
> ```
> If either gate still receives a table built from a cumulative `implDecls`, **`a` stays in Phase 5.**

**This is a genuine option, not just a veto:** a 2′ that *also* repoints the two collision gates
(a small additional bite — two functions, one population) would satisfy the amended criterion and
restore RUN-B-013's attribution argument. I am not cutting that bite; it is B-2.1's, and it would
need its own allocation grading for the same reason `a3` does. **Flagging it as the cheapest route
to recovering the 2′ placement, for the sub-orchestrator's call.**

---

## 2. Bite list, refreshed. Ids, sites `@604278bb`, four-arm `engines:`

**Standing rule, unchanged and now enforced by the ledger:** no `engines:` cell may be blank, and
*"none needed"* must cite **why** — an import that makes a helper shared, or a mechanism that
carries the identity already. **A bare "none needed" is the P0-9 failure written down.**

**The `core_ir_eval` PRODUCER set, named once and referenced by every bite below** (its
consumers are shared through `applyValue`/`methodAtNarrow`, which it imports; these five sites are
its own):

| site `@604278bb` | what it produces |
|---|---|
| `core_ir_eval.mdk:453-455` `cImplBodyValue` | builds **its own** `VTypedImpl tag key positions 0 (…)` from `CImplTagged` |
| `:431-434` `cImplEntryNames` + `:436-438` `qualifiedDefaultNameC` | allocates the default cell NAMES (peer of eval's `defaultNamesOf`, `eval.mdk:2080-2083`) |
| `:443-445` `cImplEntryValue` / `:447-451` `cImplEntryValues` | registers the default CELLS, bare + `<ifaceId>#<method>` (peer of eval's `defaultEntry`, `eval.mdk:2017-2029`) |
| `:587-588` `cModImplValues` | the multi-module peer of the above |
| `:401-411` `cevalProgram` | `installConsts cells (coalesceImpls (flatMap (cImplEntryValues env) implEntries))` |

---

### `B-2.4-a` — retire the recomputed route word in all four arms (**#1072**, **#1068**) — **PHASE 5** (§1)

**Transformation:** *the dispatch guard compares the evidence identity the producer stamped; no
engine recomputes a route word from `CImplEntry`s or from a head-uniqueness verdict.*

**sites — LLVM** (`compiler/backend/llvm_emit.mdk`): `:5336-5345` `emitDispatchArm` (guard becomes a
single equality) · `:5356-5373` `emitRouteWordMatch`/`emitRouteWordMatchOr` (OR-chain → one-word
form; its own comment `:5367-5370` records that a one-word set is byte-identical to the pre-#1036
single `icmp`) · `:1512-1518` `implEntryRouteWords`, `:1486-1499` `implEntryRouteKey`/`…KeyE` —
**left in place here, deleted in `d`** (second reader `implEntryTags:5491-5493` is re-based there).
**KEEP:** `:1354-1367` `implFnSymTag`/`headTagUnique` — SYMBOL namespace (P0-C §1).

**sites — wasm** (`compiler/backend/wasm_emit.mdk`): `:4034-4039` `implEntryRouteKeyW` (the recompute
#1068 names) · `:4456-4462` `methodImplKey` + `:4444-4447` `methodImpls` (the `(symTag, routeKey)`
pair's **second** component carries the stamped identity; the first is unchanged) · `:3714-3729`
`emitDispatchChain` (`:3726` hashes that identity). **READ ONLY, do not edit:** `:3808-3821`
`routeWitness` — it is the producer and already hashes what the `Route` carries. **KEEP:**
`:4003-4025` `implFnSymTagW`/`headTagUniqueW` (symbol namespace).

**sites — eval** (`compiler/eval/eval.mdk`): `:1206-1208` `hasTag` (`t == tag || k == tag` → single
identity comparison) · `:1210-1212` `matchesTag` (twin; ⚠️ its default arm is `matchesTag _ _ =
True`, not `False` — **touch the `VTypedImpl` arm only**; the default arm is `f`'s) · `:1998-2004`
`implMethodEntry`, where `VTypedImpl tag key positions 0 inner` is built (`key = implKeyOf
ifaceName typeArgs None`, a bare-name composition — P0-C §5's constraint applies).

**sites — `core_ir_eval`** 🆕: `:453-455` `cImplBodyValue`. **This arm builds its own `VTypedImpl`
and was MISSING from P0-C §4's bite `a`** (RUN-B-013 caught it). Its consumers are inherited via
the import list, so **no consumer edit — justified by the imports, not asserted.**

**engines:** LLVM ✅ `:5336-5373`, `:1486-1518` · wasm ✅ `:4034-4039`, `:4456-4462`, `:3726` · eval
✅ `:1206-1212`, `:1998-2004` · **`core_ir_eval` ✅ REQUIRED, `:453-455`.** All four **in this
bite**. The sub-orchestrator may commit them as four commits; it may **not** split them across
implementers, and it may **not** take an integration checkpoint between arms — a checkpoint taken
mid-bite measures a knowingly divergent tree.

⭐ **If `a` adds a field to `VTypedImpl`, `core_ir_eval.mdk:455` is a COMPILE ERROR** — the fourth
arm becomes loud rather than silent. That is the property to design for; see §4.

**could move:** most-specific-wins in cross-module programs, by design. #1072's repro flips
`general`→`specific`, **and its mirror control (same program, modules swapped) must keep printing
`specific`. Both arms are the acceptance test; a one-arm run proves nothing** (#1072's own body
says so). Also: any program where two modules each see a *different* single impl at one head — the
residual `llvm_emit.mdk:5331-5335` documents — changes answer. **That residual is what this bite
closes; say so, do not describe it as untouched.**
**nearest miss:** an `RNone` site still reaches arg-tag dispatch and is **not** covered — that is
`f`, plus #1046/#1075 at **F-1**, out of this sprint. Also not covered: two interfaces sharing a
method name at one tag — that is `k`, and `mdk_default_<method>_<tag>` still has one symbol for two
bodies until `k` lands.
**unchecked / owed in the same PR:** re-word `test/engine_divergence.txt:159` and `:160`, both of
which currently instruct the reader to *"PROMOTE when wasm accepts the route-word set"* — the
**retired** design. See §5.

---

### `B-2.4-b` — `core_ir_lower` memo selector follows the same identity — **PHASE 5** (follows `a`)

**Transformation:** *the per-instance-CAF selector is the stamped identity, not a recomputed
head-vs-key choice, so `isMemoKey` still matches the occurrence's route.*

**sites** (`compiler/ir/core_ir_lower.mdk`): `:849-857` `memoKeys`/`memoKeysGo` · `:862-867`
`memoSelector` · `:873-884` `headTagUniqueL`/`distinctKeysAtHeadL` (retire **only** the
route-selector use; delete if no other caller survives) · `:886-888` `isMemoKey` · `:951-952`
`memoBindName` · call sites `:972`, `:998`, `:1011`, `:1040-1042`.
**Peer name-derivations that must keep agreeing byte-for-byte:** `llvm_emit.mdk:5412-5413`
`memoGlobalName` (its comment `:5409` says *"must match core_ir_lower.memoBindName EXACTLY"*) +
its gate `:5395-5396`; `wasm_emit.mdk:3698-3701` `dispatchCallSeqW`, which **re-spells the name
inline** (`let memoName = "$memo_\{tag}_\{name}"`, `:3700`) rather than calling a shared helper —
so a spelling change silently un-hoists on wasm with no compile error. **That inline re-spelling is
the highest-risk line in this bite.**

**engines:** LLVM ✅ `:5412-5413` + `:5395-5396` · wasm ✅ `:3698-3701` (**inline re-spelling**, see
above) · eval **none needed** — memoises per `VTypedImpl` via `memoThunk` (`eval.mdk:1964-1968`,
gated at `:1955`), which is identity-carried already · **`core_ir_eval` none needed — RESOLVED
UNCONDITIONALLY, see §4.1.**

**could move:** whether a nullary/return-position impl's side effect runs **once or per
occurrence**. A selector that stops matching silently un-hoists the CAF (effect duplicated) or
mis-hoists it (effect shared across two *different* instances). **Both are exit-0 wrongness.**
**nearest miss:** an impl with `positions` or `pats` non-empty is not a CAF and is untouched
(`core_ir_lower.mdk:855`'s guard) — a fixture over such an impl **cannot fail** and must not be
offered as evidence.

---

### `B-2.4-c` — re-key the `noneHeadTag` catch-all — **PHASE 5 (3′)**

**Transformation:** *a general instance (`impl Iface a`) is selected by its own evidence identity
like every other instance — not by an unconditional trailing body, and not by filtering on
`noneHeadTag`.*

**sites — LLVM:** `:5424-5431` `isGeneralEntry`/`firstGeneralEntry` · `:5433-5455`
`emitDispatchChain` (the `Some gen => emitDispatchArmBody …` unconditional tail vs `None =>
unreachable`) · `:4593-4608` `emitGeneralRKey` (`findByTag noneHeadTag (implsOf e name)`).
**sites — wasm:** `:3647-3672` `emitMethodDispatchRef` (`concretes = filterList (p => fst p !=
noneHeadTag) impls`) · `:3674-3678` `firstGeneralImplW` · `:3680-3688` `emitGeneralArm` ·
`:4560-4564` `emitDefaultRKeyRef`'s `findByTagW name noneHeadTag` arm.
**sites — eval:** `:1053-1056` `pickTagFallback` (`filterList (hasTag noneHeadTag) vs`) ·
`:1011-1014` `pickByTag`.

**engines:** LLVM ✅ · wasm ✅ · eval ✅ · **`core_ir_eval` — none needed, CONDITIONALLY, with the
condition now MECHANICAL: see §4.2.** The three comments at `llvm_emit.mdk:4580-4592`,
`wasm_emit.mdk:4546-4559` and `eval.mdk:1016-1031` are **deliberate mirrors of each other** (each
says so) — a change to one that misses the others is the `evalModules`/`cevalModules` lockstep
failure in a new place.

**could move:** the precedence **general-instance vs interface-default** (DICT §5, #728-2). Today
the order is enforced *positionally* (general first, default second); after re-keying it is
enforced by **what `inst` selected**, which is the same answer only if the selection is min⊑. Any
program where the general and the default disagree is in scope — **hand-derive the winner from
DICT §3/§5, never from an engine.**
**nearest miss:** a general instance that **omits** the method. `fillImplDefaults` synthesises the
default body into it under `noneHeadTag` **same-module only**; cross-module leaves *no*
`noneHeadTag` entry (all three mirror comments state this). So the cross-module omitting-general
has **no instance-side identity to key on** — if P0-B's seam does not give the inheriting/omitting
impl an identity (P0-C §5 item 3), **this bite is not implementable for that shape and the
implementer must STOP and report**, not invent a synthetic identity.

---

### `B-2.4-d` — the disjoint default-tag WORD namespace (and the deletion) — **PHASE 5 (3′; the disjointness half may ride `a`)**

**Transformation:** *coverage and default-arm selection are computed in ONE namespace — instance
identity. The `mdk_default_<method>_<tag>` **symbol** stays a symbol and is never compared against a
dispatch word.*

**sites — LLVM:** `:5155-5175` `emitDispatchBody`'s two `defaultFor` arms — the
`covered`/`uncovered` computation is at **`:5170-5171`** (`let covered = implEntryTags e impls`,
`let uncovered = tagsMinus (ifaceTags e (methodIfaceOfInput e name)) covered`) · `:5491-5493`
`implEntryTags` · `:5497-5501` `tagsMinus` · `:5223-5239` `ifaceTags`/`ifaceTagsGo`/`declTagOrKey`
· `:5247-5271` `emitDefaultDispatchChain` · `:5457-5472` `emitDispatchChainDefaulted` · `:1335-1336`
`defaultFnName` — **READ ONLY, do not re-key (that is `k`).**
**sites — `core_ir_lower`:** `:1337-1347` `ifaceImplRouteKeys`/`declRouteKey` · `:1355-1364`
`ifaceDeclHeadUnique`/`declKeysAtHead` · `:1321-1328` `ifaceIdsAtTag`.
**sites — eval:** `:1058-1064` `pickDefaultCand` · `:1071-1079` `ownDefault`/`defaultCellOf` ·
`:1087-1089` `isDefaultCand` · producers `:2017-2029` `defaultEntry`/`qualifiedDefaultEntry`,
`:2080-2083` `defaultNamesOf`.
**sites — `core_ir_eval`** 🆕: `:431-438` `cImplEntryNames`/`qualifiedDefaultNameC` + `:443-451`
`cImplEntryValue`/`cImplEntryValues` + `:587-588` `cModImplValues` — **its own default-cell
registration, the peer of eval's `defaultEntry`/`defaultNamesOf`. P0-C §4's bite `d` did not name
these** (RUN-B-013's correction). Note `defaultCellName` itself is **imported** from `eval.mdk`
(`core_ir_eval.mdk:98`), so the NAME derivation is shared — only the REGISTRATION is duplicated.
**sites — wasm: NONE.** wasm has no interface-default dispatch arms; its `defaultForW`/
`narrowDefaultsW` (`:4513-4539`) are on the **RKey** path only.

**Deletion lands here:** `implEntryRouteWords` (`llvm_emit.mdk:1512-1518`), `implEntryRouteKey`/
`…KeyE` (`:1486-1499`), `emitRouteWordMatch`/`…Or` (`:5356-5373`), `emitConstFalse` (`:5375-5379`)
— **once both readers (arm + coverage) are off them.** Check reader counts *before* deleting; do
not delete on the strength of this list:
```sh
grep -n 'implEntryRouteWords\|implEntryRouteKey\|emitRouteWordMatch\|emitConstFalse' compiler/backend/llvm_emit.mdk
```

**engines:** LLVM ✅ `:5155-5175`, `:5223-5271`, `:5457-5472`, `:5491-5501` · **wasm — none needed:
#1020, out of scope.** `emitMethodDispatchRef` (`:3647-3672`) emits concrete arms + general tail +
`unreachable` and has **no peer of `emitDefaultDispatchChain`/`emitDispatchChainDefaulted`;
building one inside B-2.4 would be doing #1020 out of scope.** · eval ✅ `:1058-1089`, `:2017-2029`,
`:2080-2083` · **`core_ir_eval` ✅ REQUIRED, `:431-451`, `:587-588`.**

🚨 **The boundary that must not be crossed.** `defaultFnName tag method =
"mdk_default_\{method}_\{safeIdent tag}"` (`llvm_emit.mdk:1336`) has **no interface component**.
Re-keying it is **`B-2.4-k`**, a separate bite with a separate boundary test — **`d` makes the two
namespaces disjoint and stops there.** The four comments warning about this:
`llvm_emit.mdk:1257-1277`, `wasm_emit.mdk:4507-4512`, `eval.mdk:1043-1052`,
`core_ir_lower.mdk:1316-1320`.

**could move:** which tags get a `@mdk_default_<m>_<tag>` arm — hence emitted IR size and **arm
order**. `ifaceTags`' comment (`:5213-5222`) warns **head tags go FIRST and the order is
load-bearing** (`dedupS` keeps the LAST occurrence; entries-first reorders every dispatch chain in
the tree). Preserve the order or expect the whole IR golden family to move for no semantic reason.
**nearest miss:** a **method-less** impl (overrides nothing, cross-module) contributes **zero**
`CImplEntry`s — `lowerDeclImpl` projects one entry per method the impl DEFINES
(`core_ir_lower.mdk:1382`). It is visible today only through the decl table (`ifaceImplRouteKeys`).
If coverage moves to instance identity, that impl must still be enumerable, or **#948's
arm-less-dispatcher SIGSEGV returns. This is the shape most likely to break silently; require a
fixture over it.**

---

### `B-2.4-e` — `Route`/`CMethod` consumption alignment — **PHASE 5 (3′; has no content before the type changes)**

**Transformation:** *every consumer of a `Route`'s dispatch component reads the identity, and no
consumer re-derives one.* The sweep that catches readers the bites above do not name.

**sites — the enumeration, not a list to trust.** `Route` is
`RNone | RKey String (List Route) | RDict String | RDictFwd String | RLocal String (List Route) | RScalar String`
(`compiler/frontend/ast.mdk:722-728`); `CMethod String Route (List Route) (List Route)`
(`compiler/ir/core_ir.mdk:131`). **Derive the reader set:**
```sh
grep -n 'RKey' compiler/backend/llvm_emit.mdk compiler/backend/wasm_emit.mdk \
               compiler/eval/eval.mdk compiler/ir/core_ir_lower.mdk compiler/ir/core_ir_eval.mdk
```
and reconcile against the bites above; **anything left over is this bite's content.**
**Known-live readers `@604278bb`:** eval `routeTag` (`:1117-1129`) and `dictOfRoute` (`:1147-1163`)
and `methodAtNarrow` (`:1170-1191`) · LLVM `dictWordOfRoute` (`:5691-5704`) · wasm `routeWitness`
(`:3808-3840`) and `emitMethodRef` (`:3566-3644`).

**engines:** LLVM ✅ · wasm ✅ · eval ✅ · **`core_ir_eval` ✅** — it imports `routeTag`
(`core_ir_eval.mdk:79`) and consumes `CMethod`/`CDict` routes on the typed path (its SLICE 5 header,
`:23-26`).

**could move:** nothing, **if the sweep is faithful** — it is a re-pointing, not a semantic change.
**That claim is only honest with the grep executed; without it, `could move:` is "unknown".**
**nearest miss:** `RLocal`/`RScalar` carry no dispatch identity by construction
(`dictWordOfRoute _ _ (RLocal _ _) = "0"`, `llvm_emit.mdk:5704`; `dictOfRoute _ (RLocal _ _) =
VDict "" []`, `eval.mdk:1161`). Untouched, and they remain the **F-1** territory the sprint rules
out.

---

### `B-2.4-f` — consume frozen admissibility at the arg-tag sites (never re-derive) — **PHASE 5 (independent; gated only on the carrier)**

**Transformation:** *before emitting/performing an arg-tag dispatch, consult the frozen
per-(class, argument-position) admissibility verdict carried in the elaboration output; when the
verdict is inadmissible, fail loudly rather than dispatching on the runtime constructor tag.*

**sites — LLVM:** `:5521-5527` `emitMethodArgDispatch` (the `[]`/`[g]`/`_` fan-out — the **`[g]`
sole-group direct call at `:5526`** is #1046's mechanism) · `:5542-5546` `emitDefaultArgTag` ·
`:5548-5551` `emitArgTagDispatch` · `:5553-5582` `emitArgTagDispatchGo`/`emitArgDispatchChain` ·
`:5584-5599` `emitTagMatch`.
**sites — eval:** `:934-941` `applyOpt` (`:940` `collectPartials [] (filterByTag vs arg) arg`) ·
`:958-965` `filterByTag`/`filterByTagT` · `:967-969` `keepOrAll` · `:971-972` `keepCand` ·
`:1210-1212` `matchesTag`'s `matchesTag _ _ = True` arm · `:441-454` `runtimeTypeTag` · **`:1934`
`lookupPositions _ _ [] = [0]`.**
**sites — wasm: NONE** — `emitMethodRef … RNone` is a `gapLP` (`wasm_emit.mdk:3599-3602`), not a
dispatcher. **Nothing to move.**

**The condition, at DICT §5's actual strength** — repeated because an implementer will otherwise
paraphrase it: per (class, argument position), **every reachable constructor uniquely determines the
min-specificity winner for every goal reaching the site, and the argument must be evaluated.**
⚠️ **NOT "no overlap below the head"** — `impl C (T Int)` / `impl C (T Bool)` do not overlap and the
tag `T` determines nothing. **An implementer who implements the paraphrase has licensed an S0 with
zero overlap.**

🚨 **REQUIREMENT, not a footnote (RUN-B-013 condition 1). The two absence states must stay DISTINCT
IN THE CODE:**

| state | required behaviour |
|---|---|
| table **present**, **no row** for a (class, position) an engine reaches | **FAIL CLOSED** — not admissible. *(P0-C §4 additionally wanted this to STOP and report as a seam bug; either way it must never dispatch.)* |
| table **structurally absent** (the untyped drivers) | today's arg-tag behaviour, **marked UNVERIFIED** in `DEBT.md` |

**A single `Option`-with-default that serves both is FORBIDDEN.** The precedent is in the tree:
today's analogue **fails open** — `lookupPositions _ _ [] = [0]` (`eval.mdk:1934`) declares position
0 dispatchable **on a miss**, and `keepOrAll original [] = original` (`:967-968`) then returns the
**original** candidate set when every tagged candidate is filtered out. **A table that inherits
either default has changed nothing.** ⚠️ §3 below shows the ruled carrier (C-2) *makes this
requirement unsatisfiable as specified* — read it before implementing `f`.

**engines:** LLVM ✅ `:5521-5599` · **wasm — none needed: `RNone` is a `gapLP` (`:3599-3602`);
nothing to move** · eval ✅ `:934-972`, `:1210-1212`, `:1934` · **`core_ir_eval` ⚠️ NO TABLE ON
EITHER of its entry points as things stand — see §3.**

**Consumption is one-directional.** The verdict is **data in the elaboration output**. No engine may
call `IE`, walk `CImplEntry`s, or count heads to answer it — **a fallback re-derivation is exactly
the second opinion this whole stage retires.**

**could move:** arg-tag sites that today dispatch (possibly wrongly) may start refusing.
🚨 **That is a severity DECREASE only if the refusal is LOUD.** Ask the reviewer's question on this
bite specifically: *does this turn a path that returned NOTHING into one that returns SOMETHING?* If
so, **the new something is untested by construction.**
**nearest miss:** the sole-group shortcut at `:5526` fires **before** any chain is emitted, so a
method with impls at exactly one type is dispatched with **no runtime test at all**. If the frozen
verdict is consulted only inside `emitArgTagDispatch`, that shortcut **bypasses it** and #1046's
shape survives. **Consult the verdict at `emitMethodArgDispatch` (`:5522`), above the fan-out.**
#1046/#1075 still complete at **F-1**, so **this bite must not claim to drain them.**

---

### `B-2.4-k` — the default-arm KEY carries the interface (#1265 keying half) — **PHASE 5, independent of `a`/`b`**

**Transformation:** *the key under which an interface default is registered and looked up carries
the interface identity, so a tag that implements two same-method interfaces has a representable
answer per interface.* **Denotation stays OUT** (#1354 M-2). Boundary test (RUN-B-011): *can the key
express two distinct answers?* **No ⇒ representation ⇒ IN.**

**The boundary test, DERIVED first-hand rather than asserted.** `ifaceIdsAtTag`
(`core_ir_lower.mdk:1321-1328`) and its eval peer `ifaceIdsAtTagE` (`eval.mdk:311-318`) both return
a **`List String`** — a tag maps to *many* interface identities — and the consumer collapses:
```
eval.mdk:1071-1073  ownDefault env method tag = oneOnly (flatMap (id => defaultCellOf env method id) (ifaceIdsAtTagE tag))
eval.mdk:1081-1083  oneOnly [x] = Some x
                    oneOnly _   = None          -- ⚠️ two answers ⇒ NO answer
```
Its own comment (`:1066-1070`): *"None … when several do — in every one of those cases the caller
keeps the old answer rather than guessing."* **That is #1265's own sentence — "the narrowing has no
representable answer to narrow to" — in the source.** The key `(tag, method)` cannot express which
interface. **Representation ⇒ IN.**

**sites — the 6 symbols.** ⚠️ **RUN-B-011 records "6 symbols, 4 files". Derived, it is FIVE FILES:**
| # | site `@604278bb` | note |
|---|---|---|
| 1 | `llvm_emit.mdk:1335-1336` `defaultFnName tag method` | `mdk_default_<method>_<safeIdent tag>` — **no iface component** |
| 2 | `wasm_emit.mdk:4543-4544` `defaultFnNameW tag method` | `mdk_default_<gname method>_<gname tag>` — the same gap, second engine |
| 3 | `core_ir_lower.mdk:1321-1328` `ifaceIdsAtTag` | tag → **List** ifaceId (the plurality that has no representation) |
| 4 | `eval.mdk:311-318` `ifaceIdsAtTagE` | a **third** copy of #3, over `declImplIfaceIdsRef` |
| 5 | `eval.mdk:334-335` `defaultCellName ifaceId method` | **already iface-keyed (#1047) — this is the MODEL the other four copy** |
| 6 | `core_ir_eval.mdk:436-438` `qualifiedDefaultNameC` | 🆕 **the fifth file.** It *imports* `defaultCellName` (`:98`) so it shares the keying, but it has its **own registration** at `:431-434`/`:443-451` |

**Narrowing consumers that must move with them:** `narrowDefaults`/`defaultOwnedBy`
(`llvm_emit.mdk:1301-1309`) · `narrowDefaultsW`/`defaultOwnedByW`/`pickDefaultAtW`
(`wasm_emit.mdk:4527-4535`) · `ownDefault`/`defaultCellOf`/`oneOnly` (`eval.mdk:1071-1083`).

**engines:** LLVM ✅ `:1301-1336` · wasm ✅ `:4527-4544`, `:4560-4570` · eval ✅ `:311-318`,
`:334-335`, `:1071-1083` · **`core_ir_eval` ✅ REQUIRED, `:431-451` (its own registration).**
**The "4 files" figure is where the fifth arm goes missing — the same shape as AM-3.**

**could move:** which default body a tag implementing two same-method interfaces reaches — from
"neither (`oneOnly` → `None`, keep the old answer)" to "each interface's own". **`#1265`'s pin
(`test/must_fail_fixtures/1265-two-ifaces-same-method-one-type-default-collapse`) flipping is this
bite's deliverable**, and #1265 is **NOT closed by this run** (only its keying half moves).
**nearest miss:** two interfaces sharing a method name where the *tag* is also shared **and the
correct choice depends on the call site's expected type** — that is **denotation**, out of scope
(#1354 M-2). Key expresses two answers, wrong one chosen ⇒ selection ⇒ OUT. **A bite that starts
choosing between representable answers has left scope.**
**Do NOT confuse with #1182** — RUN-B-011: *"#1265 and #1182 are NOT the same defect."*

---

## 3. 🚨 ESCALATION: the ruled carrier (C-2) cannot satisfy RUN-B-013 condition 1 as specified

RUN-B-013 ruled C-2 = *"a 5th positional `CProgram` field"* for LLVM/wasm/`cevalProgram`, threaded
by widening `lowerProgramEmit` and `lowerProgram` **to take the table**. Two facts `@604278bb` make
that under-specified in a way that lands exactly on condition 1's fail-open hazard:

1. **`lowerProgramEmit` CALLS `lowerProgram`.**
   `lowerProgramEmit prog = hoistNullaryMemo (rewriteProgramRecPats (declaredRecordFieldOrders prog)
   (lowerProgram prog))` (`core_ir_lower.mdk:550-554`). So `CProgram` is **constructed at exactly ONE
   site** — `lowerProgram` (`:521-526`) — and C-2's *"compile error at every construction"* is one
   construction plus every destructure. That part is fine.
2. **`lowerProgram` is the UNTYPED shared path.** Its own sibling comment says so: the rec-pat
   rewrite *"lives in `lowerProgramEmit` … NOT in the shared `lowerProgram` that core_ir_main /
   core_ir_eval use"* (`:545-548`). Its 9 application sites are the untyped probe drivers
   (`core_ir_dump_main`, `core_ir_run_main`, `core_ir_main`, …). **They have no table.**

⇒ If the 5th field's type is *the table*, every untyped driver must construct **something** — and an
empty table is **indistinguishable from "table present, no rows"**. Then either (a) empty reads as
absent, and the **fail-closed** state RUN-B-013 condition 1 requires becomes unrepresentable for the
typed path, or (b) empty reads as no-rows and **fail-closed fires on every untyped driver**, breaking
`diff_compiler_core_ir*`. **Condition 1 collapses either way, in the carrier, before `f` is written.**

> **Recommendation (escalated, not decided — this is the carrier's owner's call, not mine):** the
> 5th field must be **two-valued at the TYPE level** — `Option <table>`, or a 2-constructor
> `CAdmis = CAdmisAbsent | CAdmisTable …`. `lowerProgram` constructs the ABSENT value; the typed
> emit path installs the table. Then "absent" and "no row" are different **constructors**, condition
> 1 is satisfied *structurally* rather than by discipline, and every engine's destructure is still a
> compile error until it binds the field.

**Second, sharper finding on the fourth arm's `f` cell.** RUN-B-013's ledger says *"`cevalProgram`
gets it via C-2, `cevalModules` does not."* The comment it cites (correctly located at
`core_ir_eval.mdk:522`, **not** `:598`) reads: *"UNTYPED path, like **cevalProgram** /
evalModules."* — i.e. **the tree calls `cevalProgram` untyped too.** Reconciled: `cevalProgram`
receives the *field* (it destructures `CProgram` positionally at `:401`) but whether the field is
POPULATED depends on which lowering built it, and the drivers that reach `cevalProgram` go through
bare `lowerProgram`. **So the fourth arm has NO POPULATED TABLE ON EITHER ENTRY POINT as things
stand**, and the `f` ledger cell must say that rather than distinguishing the two entry points on
carrier reachability. **Consequence for the assented carve-out: its `DEBT.md` row must name three
drivers, not two** — `eval_modules_main.mdk:37`, `profile_eval_main.mdk:92`, **plus every
`lowerProgram`-fed `cevalProgram` driver**. Derive the third set:
```sh
grep -rn 'lowerProgram ' --include=*.mdk compiler/entries/ | grep -v lowerProgramEmit
```
**I did not run that grep against `compiler/entries/` and am not asserting its result** — P0-C's
§8.1.2 table lists 9 `lowerProgram` application sites, which is the starting point.

**C-1's four bypass sites, named as RUN-B-013 requires** (the eval arm's bite must name them so an
implementer cannot thread the table past a `let _ =` and report done):
`compiler/driver/medaka_cli.mdk:745`, `compiler/driver/medaka_cli.mdk:1685`,
`compiler/entries/eval_autoprint_main.mdk:39`, `compiler/entries/playground_main.mdk:287`.
Re-derive rather than trust:
```sh
grep -rn 'elaborateModules' --include=*.mdk compiler/ | grep -vE ':[[:space:]]*--' \
  | grep -v '^compiler/types/typecheck.mdk'
```
⚠️ **These are P0-C's four, relayed with their commit (`2b9dc798`) — `medaka_cli.mdk` is not one of
the files I pinned and I did NOT re-verify these line numbers `@604278bb`.** `git diff --stat
2b9dc798 604278bb -- compiler/` shows only `typecheck.mdk` changed, so they should hold; **that is an
inference from the diffstat, not a read.** Re-run the grep.

---

## 4. P0-C's two CONDITIONAL `core_ir_eval` cells — both resolved, with mechanical discriminators

P0-C refused to pre-fill these *"without the diff"*, and that refusal was right. **Both conditions
turn out to be evaluable without the diff** — one structurally, one from a declaration that exists
before the bite starts. So I resolve them, and give the check that overturns each.

### 4.1 `b`'s cell: **none needed — UNCONDITIONALLY.** (P0-C's condition does not apply.)

P0-C's condition was *"if `b` changes `memoBindName`'s spelling, `cevalProgram`'s CBind lookup is a
reader."* Derived:

```sh
grep -n 'memoBindName\|\$memo_\|memoThunk\|isLazyGlobal\|memoGlobalName' compiler/ir/core_ir_eval.mdk
# → ZERO matches
```

**`core_ir_eval.mdk` contains no memo-name derivation of any kind.** The name flows through it as
**data**: `cBindCell (CBind name _) = (name, Ref VUnit)` (`:376-377`) allocates a cell under whatever
name the `CBind` carries, and `ceval env (CVar x _) = … lookupEnv env x` (`:104`) resolves the
reference by generic environment lookup. Producer and consumer of the *spelling* are both
`core_ir_lower`, which `b` edits. **⇒ none needed, and the reason is structural, not an assertion.**

⚠️ **But the row is not "unaffected".** `core_ir_eval` *observes* `b`'s semantic change (CAF hoisting
comes from the shared lowering), so **`diff_compiler_core_ir*` can move on this bite with no
`core_ir_eval` edit** — record that in `unchecked:` rather than reading "none needed" as "no gate can
move".
**Overturn check:** re-run the grep above. A non-zero result means the file grew a name derivation
and this cell is wrong.

### 4.2 `c`'s cell: **none needed IFF `CImplBody`'s declaration is unchanged** — a one-command check

`core_ir_eval.mdk:453-455` destructures `CImplTagged tag key iface positions pats body` and re-emits
`VTypedImpl tag key positions 0 (…)`. It **passes the tag through**; it does not derive one. So:

- if `c` changes only the **VALUE** of a general instance's `tag`/`key` (a `core_ir_lower` change),
  `core_ir_eval` needs **no edit** — it forwards the new value;
- if `c` changes the **SHAPE** of `CImplBody`/`CImplTagged` (`compiler/ir/core_ir.mdk:232-234`), the
  destructure at `:454` is a **compile error** and the cell is **REQUIRED** — loudly.

**Mechanical discriminator, runnable before the bite starts** (the declaration is B-2.2's/the
carrier's output, not `c`'s):
```sh
git diff <base> -- compiler/ir/core_ir.mdk | grep -n 'CImplTagged\|CImplBody\|CImplEntry'
# empty  ⇒ core_ir_eval cell = "none needed" (pass-through, justified above)
# non-empty ⇒ REQUIRED at core_ir_eval.mdk:453-455, and the compiler will name it for you
```
**⇒ Cell reads: "none needed — pass-through at `:453-455`; REQUIRED the moment `core_ir.mdk:232-234`
changes shape, which the compiler reports."** Same discriminator governs `a`'s cell in the other
direction: **`a` almost certainly DOES change that shape** (an identity field on `VTypedImpl`), which
is why `a`'s cell is an unconditional ✅ and why the fourth arm is **loud** for `a` and **quiet** for
`c`. That asymmetry is the thing to know, and it is exactly the P0-9 shape: `c` is the one that can
ship half-patched.

---

## 5. #1068 — subsumed, and its ENTRY CONDITION has changed since my brief

**The ruling stands unchanged** (P0-C §2, AMENDMENT 6): **#1068's filed fix direction is WRONG.** It
asks wasm to build the superset-OR arm `B-2.4-a` deletes — same site
(`wasm_emit.mdk:4034-4039` + caller `:4459`), opposite direction. **Subsumption, not ordering:**
#1068 **is** `a`'s wasm arm. An implementer who lands the filed direction first does strictly
negative work.

**Correction to my brief (item 6), derived rather than relayed:**

```sh
ls test/must_fail_fixtures/ | grep -E '^10(62|68|71|72)'
# → 1062-eval-sibling-call-in-default-head-collision
#   1071-eval-inherited-default-sibling-calls-typearg      ← NEW since P0-C
#   1072-overlap-xmod-bare-head-arm-order
#   (no 1068)
```

- **#1071 now HAS a pin** — P0-C's *"#1068 and #1071 have NO pin"* is out of date.
- **#1068 was REFUSED as not-pinnable, with a derivation, and the refusal already carries a
  measurement.** `test/MUST-FAIL-NOT-PINNABLE.txt:166` (`@604278bb`): the must-fail harness *"has NO
  WASM ENGINE"* — `run_verb` offers check/check-json/check-types/run/build/build-run/fmt-write/
  mcp-call, all interpreter or LLVM — so the diverging arm is unreachable from any verb, and
  **"MEASURED on this tree (2026-08-13, binary at `arch/stage-b-sprint`): eval and native are both
  CORRECT on the same programs"**, i.e. any pin this harness could write would assert
  already-correct behaviour.
- ⇒ **The entry condition is NOT "author a pin".** It is: build the wasm oracle
  (`sh test/wasm/build_wasm_oracle.sh`) and observe **both** ledger rows still RED via
  `test/diff_compiler_engines.sh` — `llvmM/typearg_inherited_default_dispatch`
  (`test/engine_divergence.txt:159`, shape A, jointly with #1020) and `llvmM/module_local_route_word`
  (`:160`, shape B, #1068 alone). **The partial-vs-empty stdout asymmetry is the discriminator
  between the shapes** and is why a crash-only assertion would miss half the issue. That ledger is
  self-draining in the strong direction (a passing ledgered row prints `PROMOTE` and **hard-fails**).
  **I did not run any of this.**
- **Owed in the same PR (both rows encode the RETIRED design):** `:160` ends *"PROMOTE when wasm
  accepts the route-word set"* and `:159` carries the same route-word-set framing. **Re-word them, or
  the next agent re-derives the superset from the ledger.** Also delete
  `MUST-FAIL-NOT-PINNABLE.txt:166` when #1068 closes — that line says so itself.

**Tripwire, from RUN-B-006, applies to every bite here:**
`test/wasm/fixtures_modules/iface_name_collision_default/` guards the **fixed** state of #1047 (5
modules, two unrelated `interface Speak x` with different defaults, method-less impls each
inheriting its own module's default; expected value **hand-derived from DICT §5 + §8 I4**, not
captured). **If a B-2.4 bite moves it, that is a regression in the class this stage is supposed to
make structurally impossible** — and it is a live differential with no golden, so it cannot be
blessed away.

---

## 6. Verification posture — three things this unit may NOT do

Unchanged from P0-C §6 and repeated because it is the failure mode nearest this bite list:

1. 🚨 **Engine agreement is NOT verification for any bite here.** `iface_name_collision_default`'s own
   header records #1047 as *"all three agreed and all three were wrong."* Same for #1047 generally.
2. 🚨 **eval is a KNOWN-WRONG ORACLE on precisely the shapes these bites move** (#1071, #1062 — and
   #1071 is a **duplicate of #1062** per RUN-B-012, so **do not count them as two drains**). So
   **eval's target behaviour in `a`/`c`/`d`/`f`/`k` is derived from `docs/spec/DICT-SEMANTICS.md`,
   never from what eval prints today.** A bite phrased as *"make eval agree with native"* is
   **refusable on sight** — none above is.
3. **Capture NO eval golden for a dispatch shape in this unit.** If the correct answer cannot be
   hand-derived with a DICT clause cited, pin the shape in `test/must_fail_fixtures/` instead.
   **#1072's evidence shape is the model: a repro PLUS its mirror control** (same program, the two
   impls' modules swapped). **A one-arm run reports "correct" and proves nothing; require the pair.**

---

## 7. Refusals, corrections, and what I did not derive

1. **REFUSED my brief's presumption that `a`/`b` are admissible at 2′.** §1 — the criterion fails on
   the collision test, a population neither the criterion nor `B-2.1-b2`'s three legs enumerate.
   **They stay in Phase 5.** I also amended the criterion so the next reader cannot satisfy its
   letter and miss this.
2. **ESCALATED, not decided: C-2 as ruled cannot satisfy RUN-B-013 condition 1.** §3. The 5th
   `CProgram` field must be two-valued at the type level. This reaches back into the carrier ruling,
   which is not mine to change.
3. **CORRECTED a P0-C citation that RUN-B-013 relayed into a mandatory `DEBT.md` condition:** the
   untyped-path comment is `core_ir_eval.mdk:522`, not `:598` — **and the file has not changed since
   P0-C read it**, so this is a mis-citation, not rot. Its content also **widens the carve-out to a
   third driver set** (§3).
4. **CORRECTED "6 symbols, 4 files" for `B-2.4-k`: it is FIVE files.** `core_ir_eval.mdk:431-451` is
   the omitted fifth — **the same omission shape as AMENDMENT 3**, in the bite cut *after* AM-3
   landed.
5. **CORRECTED my brief's #1068 entry condition** (§5): #1071 now has a pin; #1068's pin was refused
   with a derivation that already carries a 2026-08-13 measurement; the owed re-measurement is the
   **wasm** arm via `build_wasm_oracle.sh` + the two ledger rows, not a new fixture.
6. **RESOLVED both of P0-C's conditional cells** (§4) with checks that are runnable *before* the
   bite, rather than repeating its refusal. `b` = unconditionally none needed (structural, zero
   grep hits). `c` = none needed while `core_ir.mdk:232-234` keeps its shape, REQUIRED and
   **compiler-reported** the moment it does not.
7. **DID NOT derive, and say so:** the C-1 bypass line numbers `@604278bb` (§3 — relayed from P0-C at
   `2b9dc798` with the diffstat as the only evidence they hold); the `compiler/entries/`
   `lowerProgram` driver set (§3 — command given, not run); anything requiring a build, a gate, the
   wasm oracle, or `./medaka`. **Nothing in this file is a measurement.**
8. **Every count here ships the command that produced it.** Re-run them; do not cite this file's
   numbers. Three counts in this run have already been corrected (the tree's "five stampers" → 7;
   Fable's inherited 5; P0-B's 85 `CProgram` → 75) — and P0-C's own §7 says one of its counts was
   wrong on first draft and right only because it re-ran the command.
