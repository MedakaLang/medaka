# P0-C — B-2.4, the three engines (#1113 part, #1068)

**Agent:** P0-C (Phase 0, read-only). **Trunk:** `/root/medaka/.claude/worktrees/giggly-tinkering-rainbow`,
branch `arch/stage-b-sprint`, `git rev-parse HEAD` = `2b9dc798fd7459e5cd0f3298bcb645a658a177fe`
(pinned; matches the briefed BASE).

**What I did NOT do:** no build, no `make`, no gate, no `refresh_seed.sh`, no edit outside this
file. `./medaka` and `./medaka_emitter` were present (`ls -la`: 4141112 / 2063608 bytes, both
02:45–02:46) and I ran **neither** — every claim below is read off source, and every line number
is from a Read/grep executed in this worktree at this HEAD. Line numbers rot: the grep that
produced each site list is quoted so you can re-derive rather than trust.

**Skill loaded:** `benchmark-emitter` (contract §5 requires it before emitter work). Its two
rules are carried into every bite's safety envelope below, verbatim in substance:
**two rebuilds, not one** (behaviour comes from source, speed comes from the emitter that
compiled it — one rebuild crosses the arms), and **`test/refresh_seed.sh` is not idempotent
after a codegen change: run it TWICE; a stale seed can SEGFAULT the fixpoint on a perfectly
correct change.**

---

## 0. Executive summary

| | |
|---|---|
| Bites cut | **6** (`B-2.4-a` … `B-2.4-f`), all statable as "apply this transformation to these N named sites" |
| Bites with a genuine 3-engine peer set | **3** (a, c, e) |
| Bites where wasm has **no site to move** | **2** (d, f) — derived, see §3; this corrects the brief's "wasm is the peer arm" premise for those two |
| #1068 ruling | **Its filed fix direction is now WRONG.** Subsumed by `B-2.4-a`'s wasm arm, same edit site, opposite direction. §2 |
| Seam owed by P0-B | Four items, §5 |
| Refusals / premise corrections | **5**, §7 |

---

## 1. What the three engines actually do today (the derivation the bites rest on)

The producer/consumer split is the whole defect, and it is symmetric across engines.

**Producer (typecheck-stamped, per site's module):** the dict word is hashed from the `Route`.
- LLVM: `dictWordOfRoute e env (RKey key reqs) = … emitDictCell e (hashName key) reqWords`
  (`compiler/backend/llvm_emit.mdk`, `sed -n '/^dictWordOfRoute/,/^$/p'`).
- wasm: `routeWitness _ _ _ (RKey tag []) = ["i32.const " ++ intToString (dictTag tag), "ref.i31"]`
  (`compiler/backend/wasm_emit.mdk:3809-3810`).
- eval: `routeTag _ (RKey key _) = key` (`compiler/eval/eval.mdk:1119`);
  `dictOfRoute env (RKey key reqs) = VDict key …` (`:1148`).

**Consumer (emitter/interpreter-recomputed, program-global or entry-derived):**
- LLVM: `emitDispatchArm` guards on `emitRouteWordMatch e headTag (implEntryRouteWords e ent)`
  (`llvm_emit.mdk:5338`), where `implEntryRouteWords` (`:1512-1518`) is the **two-element
  superset** `[implEntryRouteKeyE …, t]` — the canonical key OR the bare head.
- wasm: `emitDispatchChain` compares `["i32.const " ++ intToString (dictTag key), "i32.eq", "if"]`
  (`wasm_emit.mdk:3726`) against a key from `implEntryRouteKeyW entries method t k`
  (`:4459`, defined `:4034-4039`) — **one recomputed word, no superset**.
- eval: `hasTag tag (VTypedImpl t k _ _ _) = t == tag || k == tag` (`eval.mdk:1206-1208`), and
  its twin `matchesTag` (`:1210-1212`) — **eval already has the superset-OR**, in one line.

So the three engines hold three different answers to one question: LLVM ORs the set (superset),
wasm recomputes a single verdict (#1068), eval ORs the two fields (superset). **The sprint's
`implEntryRouteWords` superset-OR retirement is therefore a three-engine edit whose eval arm is
two lines and whose wasm arm is a bug fix.**

That the LLVM superset is *itself* an S0 is not my inference — it is #1072's own body, read with
`gh issue view 1072 --json body`: *"`a` does not import `b`, so `a`'s `KeyBuckets` hold one impl
at head `Box` → no collision → typecheck stamps the bare head. #1058 ORs that bare head into
**every** arm at the head. The site matches **arm 1 unconditionally**, and the more specific arm
is dead code for that site."* — with the two `or i1` guards printed out of `--keep-ir`, and a
mirror control (modules swapped) that flips the answer. #1058 built the superset in LLVM; #1072
is the S0 that construction produced.

**The four-way lockstep set (not two).** `compiler/ir/core_ir_lower.mdk:862-867`
(`memoSelector`) is a *fourth* consumer of the same word — its own comment says it computes
*"the string an RKey occurrence of (method, head-tag) carries"* and `isMemoKey` (`:886-888`)
compares it against the route's tag. Any bite that changes what an RKey carries and forgets this
one silently un-hoists (or mis-hoists) every per-instance CAF. Derive:
`grep -n 'isMemoKey\|memoKeys\|memoSelector' compiler/ir/core_ir_lower.mdk`.

**Keep the SYMBOL namespace out of this.** `implFnSymTag`/`headTagUnique`
(`llvm_emit.mdk:1356-1367`), `implFnSymTagW`/`headTagUniqueW` (`wasm_emit.mdk:4003-4025`) and
`headTagUniqueL` (`core_ir_lower.mdk:873-884`) also key on head-vs-key, but they name **LLVM/wasm
symbols**, not dispatch words. Retiring those is neither required nor safe here (it renames every
`@mdk_impl_*` in the tree and moves the IR-text golden for no semantic reason). **Every bite below
touches the WORD namespace only; the SYMBOL namespace is explicitly out of scope for B-2.4.**
This distinction is the single most likely way an implementer over-deletes.

---

## 2. #1068 — the ruling

**Read first-hand:** `gh issue view 1068 --json number,title,state,labels,body` (plain
`gh issue view 1068` fails on this box with the Projects-classic GraphQL deprecation — use
`--json`). Labels: `S1: loud breakage`, `verified`, `ws:wasm`, `ws:emitter`. Its fix-direction
section reads: *"Apply the same remedy PR #1058 applied to LLVM: have
`implEntryRouteKeyW`/`headTagUniqueW` accept **every** word `keyForSiteByIface` can produce
(canonical key *and* bare head) rather than recomputing a single verdict."*

**Ruling: #1068's filed fix direction is now WRONG.** In those words. It asks wasm to build the
superset-OR arm that `B-2.4-a` deletes from LLVM — i.e. to construct, in a second engine, the
exact mechanism #1072 documents as a live S0 with the IR printed. The coordination note this
brief cites is confirmed verbatim at `compiler/TYPECHECK-TARGET-ARCHITECTURE.md:1251-1255`:
*"`wasm_emit`'s peer arm (#1068's leg — **coordination note: #1068's filed fix direction would
build in wasm the superset arm this task deletes; do them together, not sequentially**)"*.
`compiler/EMITTER-ARCH-BUG-FIT.md:234-244` (§3.9) already grades it the same way —
*"DRAINED-BY #1113 plus X-E, with a Wasm PHYSICAL-RESIDUAL … Wasm consumes the evidence
reference and frozen admissibility from typed Core. No function reconstructs a semantic route
key from `CImplEntry`."*

**Subsumption, not ordering.** #1068 is not sequenced before or after the retirement: it **is**
the wasm arm of `B-2.4-a`. Same edit site (`wasm_emit.mdk:4034-4039` + its one caller `:4459`),
opposite direction — delete the recompute and read the stamp, instead of widening the recompute
into a superset. There is no intermediate state in which wasm is "fixed as filed" and then
un-fixed; an implementer who lands the filed direction first does strictly negative work and
must be told so before starting.

**Two consequences the implementer owes, both derived:**

1. **#1068 has no must-fail pin** (`ls test/must_fail_fixtures/ | grep -E '^10(68|72|71|62)'`
   returns exactly `1062-eval-sibling-call-in-default-head-collision` and
   `1072-overlap-xmod-bare-head-arm-order` — no 1068, no 1071). It is pinned only in
   `test/engine_divergence.txt:159-160`. Authoring that fixture is a Phase 0 deliverable
   (sprint doc §1) and is **not** mine; I flag it as unpinned so the drain claim is not made
   against nothing.
2. 🚨 **Those two ledger rows encode the wrong fix direction and must be re-worded in the same
   PR.** `test/engine_divergence.txt:160` ends *"PROMOTE when wasm accepts the route-word set"*
   and `:159` ends *"PROMOTE this row only when BOTH are fixed"* with the same route-word-set
   framing. Leaving them is how a future agent re-derives the retired design from the ledger.
   This is a `DEBT.md` row in its own right (see `B-2.4-a`'s `unchecked:`).

---

## 3. Where the three engines CANNOT move together — stated plainly

Two of the six bites have **no wasm peer at all**, and this contradicts the natural reading of
"wasm is the peer arm". Both are derived, not assumed:

**(i) wasm has NO arg-tag dispatch path.**
`grep -n 'arg-tag\|argTag\|ArgTag\|argDispatch' compiler/backend/wasm_emit.mdk` returns **three**
hits, none of them an implementation: `:3560` a comment (*"RNone → arg-tag fallback (gap this
slice…)"*), `:3601-3602` the arm itself —
`emitMethodRef prog env d name RNone … = gapLP prog ("wasm W5: RNone arg-tag dispatch for '" ++ name ++ "' is out of slice")`
— and `:4601` an unrelated comment. So `B-2.4-f` (frozen-admissibility consumption at the arg-tag
site) has an LLVM reader and an eval reader and **nothing to edit in wasm**. The bite must say so;
an `engines:` row reading "wasm peer owed" for (f) would send an implementer hunting a site that
does not exist.

**(ii) wasm has NO interface-default dispatch arms.** `emitMethodDispatchRef`
(`wasm_emit.mdk:3647-3667`) emits concrete arms + the general tail + `unreachable`, and there is
no peer of LLVM's `emitDefaultDispatchChain`/`emitDispatchChainDefaulted`
(`llvm_emit.mdk:5247-5271`, `:5457-5472`). wasm's only default path is the **RKey** arm
`emitDefaultRKeyRef` (`:4560-4570`). That absence is **#1020**, which the sprint doc lists under
*"engine-realization exclusions … the capture ban holds until the engine fix lands"* — so
`B-2.4-d` (the disjoint default-tag word namespace) has an LLVM arm and an eval arm and **no wasm
arm**, and `B-2.4-d` must not grow one. Building wasm default arms inside B-2.4 would be doing
#1020 out of scope.

Everything else (a, c, e) genuinely moves in all three engines and is cut that way.

---

## 4. The bite list

Standing fields, per the contract §4: each bite's implementer owes
`sites: / transform: / could move: / nearest miss: / engines: / unchecked:` in `DEBT.md`.
`could move:` and `nearest miss:` may not be blank; "nothing, and here is why" is valid.

**Safety envelope — carried in EVERY bite below, not stated once:**
- Self-compile fixpoint (`sh test/selfcompile_fixpoint.sh`) is **in-band at this unit's
  boundary** and at every unit boundary from Phase 2 on. It is the only in-run signal that
  codegen still converges.
- `test/refresh_seed.sh` is **NOT idempotent after a codegen change — run it TWICE.** Pass 1
  mints with the old-generation emitter and still reports `C3a: NO`; pass 2 converges.
- **A stale seed can SEGFAULT the fixpoint on a perfectly correct change.** The crash lives in
  the intermediate bootstrap generation (new source compiled by the stale seed's codegen). If
  the fixpoint dies with a fatal memory fault while `make medaka` and `check-self` are clean,
  **re-mint before bug-hunting** — the symptom points at your diff and the cause is the seed.
- If anything here is *measured* rather than validated: **two rebuilds, not one.** One rebuild
  gives new behaviour compiled by the old emitter and crosses the arms. Never use another tree's
  `medaka_emitter` as a baseline.
- Bless **zero goldens** (sprint §5). `diff_compiler_llvm_typed_ir` is expected-red for the
  duration; write it into `.claude/HANDOFF.md` before starting.

---

### `B-2.4-a` — retire the recomputed route word in all three engines (**#1072**, **#1068**)

**One transformation:** *the dispatch guard compares the evidence identity the producer stamped;
no engine recomputes a route word from `CImplEntry`s or from a head-uniqueness verdict.*

**Sites — LLVM** (`compiler/backend/llvm_emit.mdk`):
- `:5336-5345` `emitDispatchArm` — guard becomes a single equality against the entry's stamped
  identity word.
- `:5356-5370` `emitRouteWordMatch` / `emitRouteWordMatchOr` — the OR-chain; reduced to the
  one-word form (its own comment at `:5347-5350` already documents that a one-word set is
  byte-identical to the pre-#1036 single `icmp`, which is the shape to land on).
- `:1512-1518` `implEntryRouteWords` — **left in place by this bite** (its second reader,
  `implEntryTags:5491-5493`, is re-based in `B-2.4-d`); deleted in `d`.
- `:1486-1492` `implEntryRouteKey`, `:1494-1499` `implEntryRouteKeyE` — same: reader count drops
  to one here, deletion lands in `d`.

**Sites — wasm** (`compiler/backend/wasm_emit.mdk`):
- `:4034-4039` `implEntryRouteKeyW` — the recompute #1068 names.
- `:4456-4462` `methodImplKey` (`:4459` is the call) and `:4444-4447` `methodImpls` — the
  `(symTag, routeKey)` pair type must carry the **stamped identity** in its second component;
  the first (symbol) component is unchanged (§1's namespace rule).
- `:3714-3729` `emitDispatchChain` — `:3726`'s `dictTag key` now hashes that identity.
- `:3808-3821` `routeWitness` — **read only, do not edit**: it is the producer and already hashes
  what the Route carries. It is listed so the implementer can confirm producer/consumer agreement
  from one screen.
- `:4014-4025` `headTagUniqueW` — **keep** (symbol namespace, `implFnSymTagW:4003-4008`).

**Sites — eval** (`compiler/eval/eval.mdk`):
- `:1206-1208` `hasTag` — `t == tag || k == tag` becomes the single identity comparison.
- `:1210-1212` `matchesTag` — the twin. ⚠️ Its default arm is `matchesTag _ _ = True` (not
  `False`); changing that arm changes the arg-tag path, which belongs to `B-2.4-f`. Touch the
  `VTypedImpl` arm only.
- `:1998-2004` `implMethodEntry` — where `VTypedImpl tag key positions 0 inner` is built; the
  identity must be stamped here or reachable from here.

**Fixed edges:** none inbound except B-2.2 (routes carry identity) — this bite is unimplementable
before it. Outbound: `B-2.4-d` deletes the functions this bite orphans.

**engines:** LLVM **+** wasm **+** eval, all three **in this bite**. The sub-orchestrator may
commit them as three commits; it may **not** split them across implementers, and it may **not**
take an integration checkpoint between arms — a checkpoint taken mid-bite measures a knowingly
divergent tree and its verdict means nothing. This is the bite the `engines:` field exists for.

**could move: (what the implementer must expect to have changed)** — most-specific-wins in
cross-module programs, by design: #1072's repro flips from `general` to `specific`, and its
**mirror control** (same program, modules swapped) must keep printing `specific`. Both arms of
that pair are the acceptance test; a one-arm run proves nothing (#1072's own body says so).
Also: any program where two modules each see a *different* single impl at one head — the
residual `llvm_emit.mdk:5331-5335` documents as pre-existing — changes answer. That residual
is what this bite closes; say so rather than describing it as untouched.

**nearest miss:** a site whose route is `RNone` (no evidence at all) still reaches arg-tag
dispatch and is **not** covered — that is `B-2.4-f` plus, for local-lambda sites, #1046/#1075
at **F-1**, explicitly out of this sprint. Also **not** covered: two interfaces sharing a method
name at one tag (#1265, out) — the identity fixes the *word*, and `mdk_default_<method>_<tag>`
still has one symbol for two bodies.

**unchecked (owed by the implementer, listed so it is not forgotten):** re-word
`test/engine_divergence.txt:159` and `:160`, both of which currently instruct the reader to
*"PROMOTE when wasm accepts the route-word set"* — the retired design.

---

### `B-2.4-b` — `core_ir_lower` memo selector follows the same identity

**Transformation:** *the per-instance-CAF selector is the stamped identity, not a recomputed
head-vs-key choice — so `isMemoKey` still matches the occurrence's route.*

**Sites** (`compiler/ir/core_ir_lower.mdk`): `:849-857` `memoKeys`/`memoKeysGo`, `:862-867`
`memoSelector`, `:873-884` `headTagUniqueL`/`distinctKeysAtHeadL` (retire **only** the
route-selector use; if it has no other caller after this, delete), `:886-888` `isMemoKey`,
`:951-952` `memoBindName`, `:972`, `:1011`, `:1040-1042` (its call sites).
**Peer readers that must keep agreeing byte-for-byte:** `llvm_emit.mdk:5412-5413`
`memoGlobalName` (whose comment says *"must match core_ir_lower.memoBindName EXACTLY"*) and its
gate at `:5395-5396`; `wasm_emit.mdk:3698-3699` `dispatchCallSeqW` / `isLazyGlobalW`.

**engines:** the *table* is `core_ir_lower` (shared by all three); LLVM and wasm each hold a
name-derivation peer that must not drift; eval memoises per `VTypedImpl` (`memoThunk`), which is
identity-carried already and needs no edit — **but say that in `DEBT.md` rather than omitting
eval**, or the row reads as an unnamed peer.

**could move:** whether a nullary/return-position impl's side effect runs once or per
occurrence. A selector that stops matching silently un-hoists the CAF (effect duplicated) or
mis-hoists it (effect shared across two *different* instances). Both are exit-0 wrongness.
**nearest miss:** an impl with `positions` or `pats` non-empty is not a CAF and is untouched
(`:855`'s guard) — a fixture over such an impl cannot fail and must not be offered as evidence.

---

### `B-2.4-c` — re-key the `noneHeadTag` catch-all

**Transformation:** *a general instance (`impl Iface a`) is selected by its own evidence
identity, like every other instance — not by an unconditional trailing body, and not by
filtering on `noneHeadTag`.*

**Sites — LLVM:** `:5415-5431` (`isGeneralEntry`, `firstGeneralEntry`), `:5433-5439`
`emitDispatchChain` (the `Some gen => emitDispatchArmBody …` unconditional tail vs
`None => unreachable`), `:4594-4608` `emitGeneralRKey` (`findByTag noneHeadTag (implsOf e name)`).
**Sites — wasm:** `:3654-3667` (`concretes = filterList (p => fst p != noneHeadTag) impls`, then
`emitGeneralArm` at block level), `:3674-3678` `firstGeneralImplW`, `:3680-3688` `emitGeneralArm`,
`:4560-4564` `emitDefaultRKeyRef`'s `findByTagW name noneHeadTag` arm.
**Sites — eval:** `:1053-1056` `pickTagFallback` (`filterList (hasTag noneHeadTag) vs`),
`:1011-1014` `pickByTag`.

**engines:** LLVM + wasm + eval, same bite. The three comments at `llvm_emit.mdk:4580-4592`,
`wasm_emit.mdk:4546-4559` and `eval.mdk:1016-1031` are *deliberate mirrors of each other* (each
says so) — a change to one that misses the others is the `evalModules`/`cevalModules` lockstep
failure in a new place.

**could move:** the precedence general-instance-vs-interface-default (DICT §5, #728-2). Today
the order is enforced *positionally* (general consulted first, default second). After re-keying
it must be enforced by **what `inst` selected**, which is the same answer only if the selection
is min⊑. Any program where the general and the default disagree is in scope; expect movement and
hand-derive the winner from DICT §3/§5, not from an engine.
**nearest miss:** a general instance that **omits** the method. Today desugar's
`fillImplDefaults` synthesises the default body into it under `noneHeadTag` **same-module only**,
and cross-module leaves *no* `noneHeadTag` entry (all three comments state this). So the
cross-module omitting-general has **no instance-side identity to key on** — if P0-B's seam does
not give the inheriting/omitting impl an identity (§5 item 3), **this bite is not implementable
for that shape and the implementer must STOP and report**, not invent a synthetic identity.

---

### `B-2.4-d` — the disjoint default-tag word namespace (and the deletion)

**Transformation:** *coverage and default-arm selection are computed in ONE namespace — instance
identity. The `mdk_default_<method>_<tag>` **symbol** stays a symbol and is never compared
against a dispatch word.*

**Sites — LLVM:** `:5162-5175` `emitDispatchBody`'s two `defaultFor` arms (the
`covered`/`uncovered`/`tagsMinus` computation at `:5170-5171`), `:5491-5493` `implEntryTags`,
`:5497-5501` `tagsMinus`, `:5223-5239` `ifaceTags`/`ifaceTagsGo`/`declTagOrKey`, `:5247-5271`
`emitDefaultDispatchChain` (`:5251`'s `icmp eq i64 headTag, hashName tag`), `:4879`
(`defaultReachesOtherTags`-style reader of `tagsMinus`/`implEntryTags`), `:1335-1336`
`defaultFnName` — **read-only, do not re-key** (see below).
**Sites — `core_ir_lower`:** `:1337-1347` `ifaceImplRouteKeys`/`declRouteKey`, `:1355-1364`
`ifaceDeclHeadUnique`/`declKeysAtHead`, `:1321-1328` `ifaceIdsAtTag`.
**Sites — eval:** `:1058-1064` `pickDefaultCand`, `:1071-1079` `ownDefault`/`defaultCellOf`,
`:1087-1089` `isDefaultCand`.
**Sites — wasm:** **NONE.** §3(ii): wasm has no default dispatch arms (#1020, out of scope). Its
`defaultForW`/`narrowDefaultsW` (`:4513-4539`) are on the **RKey** path only and are not part of
the dispatch-word namespace. State this in `engines:` as *"no wasm peer — #1020, out of scope"*,
not as an owed peer.
**Deletion lands here:** `implEntryRouteWords` (`llvm_emit.mdk:1501-1518`),
`implEntryRouteKey`/`implEntryRouteKeyE` (`:1486-1499`), `emitRouteWordMatch`/`…Or`
(`:5356-5370`) and `emitConstFalse` (`:5372-5379`) once both readers (arm + coverage) are off
them. Check reader counts with
`grep -n 'implEntryRouteWords\|implEntryRouteKey\|emitRouteWordMatch\|emitConstFalse' compiler/backend/llvm_emit.mdk`
**before** deleting — do not delete on the strength of this list.

🚨 **The boundary that must not be crossed.** `defaultFnName tag method =
"mdk_default_\{method}_\{safeIdent tag}"` (`llvm_emit.mdk:1336`) has **no interface component**,
which is why two interfaces sharing a method name at one tag collapse. That is **#1265**, and the
sprint doc rules it **OUT** (*"the method-namespace lane (#1354 M-2)"*, with Phase 0 adjudicating
explicitly). `compiler/TYPECHECK-TARGET-ARCHITECTURE.md:1556-1562` assigns B-2 the *word*
namespace and forbids method names in `IE` keys — it does **not** assign B-2 the default-body
*symbol*. So: make the two namespaces **disjoint** (a default arm's key and an impl arm's key are
never compared, and coverage is not a string subtraction across both), and **do not** re-key
`defaultFnName`. An implementer who "finishes the job" by threading interface identity into that
symbol has done #1265 out of scope; the four comments that warn about it are
`llvm_emit.mdk:1257-1277`, `wasm_emit.mdk:4507-4512`, `eval.mdk:1043-1052`,
`core_ir_lower.mdk:1316-1320`.

**could move:** which tags get a `@mdk_default_<m>_<tag>` arm, hence emitted IR size and arm
order. `ifaceTags`' comment at `:5213-5222` warns that **head tags go FIRST and the order is
load-bearing** (`dedupS` keeps the LAST occurrence; entries-first would reorder every dispatch
chain in the tree). Preserve the order or expect the whole IR golden family to move for no
semantic reason.
**nearest miss:** a *method-less* impl (overrides nothing, cross-module) contributes **zero**
`CImplEntry`s — `lowerDeclImpl` projects one entry per method the impl DEFINES
(`core_ir_lower.mdk:1382`). It is visible today only through the decl table
(`ifaceImplRouteKeys`). If coverage moves to instance identity, that impl must still be
enumerable, or #948's arm-less-dispatcher SIGSEGV returns. **This is the shape most likely to
break silently; require a fixture over it.**

---

### `B-2.4-e` — `Route`/`CMethod` consumption alignment

**Transformation:** *every consumer of a `Route`'s dispatch component reads the identity, and no
consumer re-derives one.* This is the sweep that catches readers the four bites above do not
name.

**Sites — the enumeration, not a list to trust.** `Route` is
`RNone | RKey String (List Route) | RDict String | RDictFwd String | RLocal String (List Route) | RScalar String`
(`compiler/frontend/ast.mdk:723-728`); `CMethod String Route (List Route) (List Route)`
(`compiler/ir/core_ir.mdk:131`). Derive the reader set with
`grep -n 'RKey' compiler/backend/llvm_emit.mdk compiler/backend/wasm_emit.mdk compiler/eval/eval.mdk compiler/ir/core_ir_lower.mdk compiler/ir/core_ir_eval.mdk`
and reconcile against the bites above; anything left over is this bite's content.
**Known-live readers:** eval `routeTag` (`:1117-1129`) and `dictOfRoute` (`:1147-1163`);
LLVM `dictWordOfRoute` / `dictWordsOf` (`:5674-`); wasm `routeWitness` (`:3808-3840`).

🚨 **`compiler/ir/core_ir_eval.mdk` is a FOURTH engine-shaped consumer and it is not in this
unit's brief.** AGENTS.md's standing trap: `evalModules` (`eval/eval.mdk`) and `cevalModules`
(`ir/core_ir_eval.mdk`) are **parallel module drivers — fix module-frame semantics in
LOCKSTEP**, and the P0-9 cross-module ctor-collision fix shipped patching only `eval.mdk`,
leaving the other broken for months. **I am flagging, not resolving:** if `core_ir_eval` reads
route tags, it is a fifth arm and either belongs in this unit or must be explicitly deferred by
name. **Do not let an implementer decide this by proximity.** (Derivation owed before Phase 5:
the grep above, over `core_ir_eval.mdk`.)

**could move:** nothing, if the sweep is faithful — it is a re-pointing, not a semantic change.
That claim is only honest with the grep executed; without it, `could move:` is "unknown".
**nearest miss:** `RLocal` and `RScalar` carry no dispatch identity by construction
(`dictWordOfRoute _ _ (RLocal _ _) = "0"`, eval's `dictOfRoute _ (RLocal _ _) = VDict "" []`).
They are untouched and remain the F-1 territory the sprint rules out.

---

### `B-2.4-f` — consume frozen admissibility at the arg-tag sites (never re-derive)

**Transformation:** *before emitting/performing an arg-tag dispatch, consult the frozen
per-(class, argument-position) admissibility verdict carried in the elaboration output; when the
verdict is inadmissible, fail loudly rather than dispatching on the runtime constructor tag.*

**Sites — LLVM:** `:5521-5527` `emitMethodArgDispatch` (the `[]`/`[g]`/`_` fan-out — note the
`[g]` **sole-group direct call**, which is #1046's mechanism), `:5548-5551`
`emitArgTagDispatch`, `:5553-5580` `emitArgTagDispatchGo`/`emitArgDispatchChain`, `:5584-5599`
`emitTagMatch`, `:5542-5546` `emitDefaultArgTag`.
**Sites — eval:** `:940` `applyOpt` (`collectPartials [] (filterByTag vs arg) arg`), `:958-965`
`filterByTag`/`filterByTagT`, `:971-972` `keepCand`, `:1210-1212` `matchesTag`'s
`matchesTag _ _ = True` arm, `:441-454` `runtimeTypeTag`.
**Sites — wasm:** **NONE** — §3(i), `wasm_emit.mdk:3599-3602` is a `gapLP`, not a dispatcher.
`engines:` reads *"no wasm peer — RNone is a gap; nothing to move"*.

**The condition, stated at DICT §5's actual strength** (the sprint doc §Phase 4 insists on this
and I am repeating it because an implementer will otherwise paraphrase): per (class, argument
position), **every reachable constructor uniquely determines the min-specificity winner for every
goal reaching the site, and the argument must be evaluated.** ⚠️ **NOT "no overlap below the
head"** — `impl C (T Int)` / `impl C (T Bool)` do not overlap and the tag `T` determines nothing.
An implementer who implements the paraphrase has licensed an S0 with zero overlap.

**Consumption is one-directional.** The verdict is **data in the elaboration output** (P0-B's
B-2.3). No engine may call `IE`, walk `CImplEntry`s, or count heads to answer it. If the frozen
table has no row for a (class, position) an engine reaches, that is a **P0-B seam bug — STOP and
report**; do not fall back to re-deriving, because a fallback re-derivation is exactly the second
opinion this whole stage retires.

**could move:** arg-tag sites that today dispatch (possibly wrongly) may start refusing.
🚨 **That direction is a severity *decrease* only if the refusal is loud.** A silent
wrong-answer→right-answer change is fine; a loud-crash→silent-wrong-answer change is a severity
INCREASE (#1072's own history: it replaced `unreachable` UB with a wrong answer at exit 0). Ask
the reviewer's question on this bite specifically: *does this turn a path that returned NOTHING
into one that returns SOMETHING?* If so the new something is untested by construction.
**nearest miss:** the sole-group shortcut at `:5526` fires **before** any chain is emitted, so a
method with impls at exactly one type is dispatched with no runtime test at all. If the frozen
verdict is consulted only inside `emitArgTagDispatch`, that shortcut **bypasses it** and #1046's
shape survives. Consult the verdict at `emitMethodArgDispatch`, above the fan-out. (#1046/#1075
still complete at **F-1** — the sprint rules them out — so this bite must not claim to drain
them.)

---

## 5. The seam I need from P0-B (stated; I am not designing their side)

1. **A per-instance evidence identity reachable from a `CImplEntry` by a TOTAL function, and
   present on the `Route` the producer stamps** — the same field on both sides, so
   producer/consumer cannot hold two derivations. Today `CImplTagged String String String (List Int) (List Pat) CExpr`
   carries `(headTag, canonicalKey, iface, positions, pats, body)`
   (`compiler/ir/core_ir.mdk:233`) and the identity is *computed* from the first two; I need it
   **carried**, not computed. Whether that is a new field, a new constructor, or a table is
   P0-B's call.
2. **A frozen admissibility accessor** over `(classIdentity, argumentPosition)` that (a) is
   pure data in the elaboration output, (b) answers for **every** (class, position) any engine
   can reach — including the no-entries case that reaches `emitDefaultArgTag` — and (c) is
   **total**: a missing row must be distinguishable from "admissible", or `B-2.4-f` silently
   re-licenses today's behaviour. See `B-2.4-f`.
3. **An identity for an impl that produces ZERO `CImplEntry`s** (the method-less/inheriting
   cross-module impl, `core_ir_lower.mdk:1382`; and the cross-module omitting general instance,
   `eval.mdk:1023-1026`). `B-2.4-c` and `B-2.4-d` are not implementable for those shapes without
   it. If P0-B's answer is "those have no identity", **say so explicitly** and both bites get
   re-cut around a decl-table enumeration instead — silence here ships #948's SIGSEGV back.
4. **A ruling on whether `noneHeadTag` survives as a value.** If general instances get real
   identities, `noneHeadTag` becomes a symbol-namespace artifact only. Its readers are
   enumerable: `grep -n noneHeadTag compiler/backend/llvm_emit.mdk compiler/backend/wasm_emit.mdk compiler/eval/eval.mdk compiler/ir/core_ir_lower.mdk`
   (`grep -c` at this HEAD: `core_ir_lower` 4, `eval` 7, `wasm_emit` 8, `llvm_emit` 8 = **27**,
   comments included — I ran it; re-run it, do not trust the number. ⚠️ My first pass wrote
   "12" here from memory of an earlier grep's *filtered* output; the count is 27. That is this
   file's own instance of the rule it states.)

**Constraint I hand back to P0-B, from the design doc rather than from taste:** the identity must
not be a bare-name composition. `TYPECHECK-TARGET-ARCHITECTURE.md:1556-1562` — *"No `IE` key
component may be a method name"* — and #1047's whole class is bare-name-composed keys colliding
across modules. Today's `canonicalKey` (`implKeyOf ifaceName typeArgs None`) is built from the
**bare** `ifaceName` (`core_ir_lower.mdk:1393`), which is exactly the shape the sprint doc says
under-discriminates pre-Stage-A.

**`SupersPath` (sprint §1):** none of my six bites references a supers path — every arm compares
a single identity, so **presumption (a) (two-constructor route, `SupersPath` deferred to B-1 by
name) is what these bites are cut against.** If Phase 0 instead chooses (b), `B-2.4-a` and
`B-2.4-c` must be **re-cut**: comparing a *path*-shaped identity is not the same edit as
comparing a scalar one, and I would be handing an implementer a bite that no longer describes the
work.

---

## 6. Verification posture for this unit (what I am NOT proposing)

- 🚨 **I do not propose engine agreement as verification for any bite above.** Eval-vs-native
  agreement **proves nothing on a dispatch shape** — several known S0s have every engine equally
  wrong (#1047 is the tree's own example), which is exactly why `diff_compiler_engines` cannot
  see them.
- 🚨 **eval is a known-wrong oracle on precisely the shapes this unit moves.** #1071 (*"eval
  prints int/31 where str/71 is correct (native is correct)"*) and #1062 (*"EVAL-ONLY since
  #1058: eval does not re-narrow a sibling-method call inside an interface default body when the
  head tycon collides"*) — titles read off `gh issue view … --json`. So **eval's target
  behaviour in `B-2.4-a`/`-c`/`-d`/`-f` is derived from `docs/spec/DICT-SEMANTICS.md`, never
  from what eval prints today, and no bite may be phrased as "make eval agree with native".**
  A bite worded that way is refusable on sight.
- **Capture no eval golden for a dispatch shape** in this unit (sprint §5). If the correct answer
  cannot be hand-derived with a DICT clause cited, pin the shape in `test/must_fail_fixtures/`
  instead of capturing.
- **#1072's evidence shape is the model for every acceptance test here:** a repro **plus its
  mirror control** (the same program with the two impls' modules swapped). A one-arm run reports
  "correct" and proves nothing; the pair is the evidence. Require the pair.
- **Pins:** #1072 → `test/must_fail_fixtures/1072-overlap-xmod-bare-head-arm-order`,
  #1062 → `…/1062-eval-sibling-call-in-default-head-collision` (both present, `ls` above).
  **#1068 and #1071 have NO pin** — the sprint doc owes them and my drain claims are
  unfalsifiable until they exist and are observed RED.

---

## 7. Refusals and premise corrections

1. **#1068's filed fix direction is WRONG** (§2), in those words. Do not implement it, before or
   after; it is subsumed by `B-2.4-a`'s wasm arm at the same site in the opposite direction.
2. **"wasm is the peer arm" is false for two of the six bites.** wasm has **no** arg-tag
   dispatcher (`gapLP`, `wasm_emit.mdk:3599-3602`) and **no** interface-default dispatch arms
   (#1020, out of scope). `B-2.4-d` and `B-2.4-f` have no wasm site, and their `engines:` rows
   must say *"no wasm peer, and why"* — not *"peer owed"*. §3.
3. **`test/engine_divergence.txt:159-160` encode the retired design** (*"PROMOTE when wasm
   accepts the route-word set"*). They must be re-worded in the same PR or the next agent
   re-derives the superset from the ledger. §2.
4. **`compiler/ir/core_ir_eval.mdk` may be a fifth arm and is not in my brief.** I flag it rather
   than absorb it — the `evalModules`/`cevalModules` lockstep trap is exactly this shape and has
   already cost this tree months. It needs an explicit in-or-out ruling before Phase 5. §`B-2.4-e`.
5. **I will not cut the #1265 half of the default namespace.** `defaultFnName` carries no
   interface component and re-keying it is #1265 — sprint-ruled OUT, and the design doc assigns
   B-2 the *word* namespace only. `B-2.4-d` makes the namespaces disjoint and stops there.
   §`B-2.4-d`.

**Not a refusal, but stated so it is not mistaken for a finding I verified:** every line number
here was read at `2b9dc798`, and I ran no gate, no build and no probe. Nothing in this file is a
measurement. The counts I do state (six bites; three-of-six with real peer sets; 27 `noneHeadTag`
occurrences; 3 `arg-tag` grep hits in `wasm_emit.mdk`) each ship the command that produced them —
**re-run them; do not cite this file's numbers.** One of them was wrong on the first draft and
caught by re-running, which is the only reason it is right now.
