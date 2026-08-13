# P-c packet — pre-derived facts for bite `B-2.1-c` (re-base the SHADOW readers)

**All line numbers derived at pinned commit `85ceec1f` via `git show 85ceec1f:<path>`.**
`compiler/types/typecheck.mdk` @ `85ceec1f` = **29171 lines**; `docs/spec/SHADOW-SEMANTICS.md`
@ `85ceec1f` = **2152 lines**. A live writer is editing typecheck.mdk — re-derive with
`grep -n` against your own tree before editing, but the *relative* structure below is stable.

---

## 1. The site set — VERIFIED, and the brief's count is OFF BY ONE

Code (non-comment) occurrences of `implExistsForHead`:

| Line | What | Table it reads |
|---|---|---|
| **11548** | `inferShadowApp` (def `11535-11536`) — the importer-shadow **APP** path | `perRun.value.shadowKeyTableRef.value` (global ref) |
| **11835** | `definerReceiverDispatches` (def `11831-11836`) | `perRun.value.shadowKeyTableRef.value` (global ref) |
| **15352** | `resolveRLocalSite` (def `15329-15330`, sig at `15329`) — the **ROUTE-side** gate | threaded **`keyTable` parameter** (NOT a ref) |
| **15195-15200** | `implExistsForHead` — signature `15195`, body `15196-15200` | — (the definition; `KeyBuckets -> String -> HeadKey -> Bool`) |
| **15229-15233** | `implExistsForHeadGo` — the `Go` helper (sig `15229`) | — |
| *(15239-15241)* | `headTabIs` — the actual key comparison, reached only from `Go`/the counting scans | — |

🚨 **There are THREE call sites, not four.** The brief's "**Four** call sites, not three" is
arithmetically wrong: it counts *the definition* as a call site. Do not burn a grep round
doubting yourself. The brief's substantive point is intact and is the one that matters —
**`15352` takes its table as a threaded parameter, so a `shadowKeyTableRef` ref-grep misses it,
and the bite changes the function's SIGNATURE, so omitting it is a compile error.**

⚠️ **Where the brief's "three" came from, and the site it silently drags in.** There are
exactly **three** code readers of `perRun.value.shadowKeyTableRef.value`:
`11548`, `11835`, and **`22072`** — `concreteReqMatchByIface`, which reads the same ref through
`selectImplEntryByIface`, **not** through `implExistsForHead`. So "three ref readers" and "the
callers of `implExistsForHead`" are **two different populations that overlap in two members**, and
the brief conflates them. **`22072` is a third read of the very ref this bite is retiring as the
shadow substrate and the brief never mentions it.** Decide explicitly and say so in your row:
either it is out of scope (it is the *require-matching / evidence* leg — arguably B-2.1-b's spec,
not #616) or the ref is left half-live. Do not leave the reader to notice.

### The stale defence comment: there are **TWO**, and the brief's grep finds only ONE

- **`11683`** — inside `inferDefinerShadowApp`'s P0-19 d8 note:
  `-- is GLOBAL — shadowKeyTableRef spans local ∪ imported ∪ prelude) DISPATCHES → type`
- **`15306`** — **the brief's grep string misses this one**, because the phrase is
  **line-wrapped after the second `∪`**:
  ```
  15305: -- (The separate `implExistsForHead perRun.value.shadowKeyTableRef.value` reads in inferShadowApp
  15306: -- are NOT this table and NOT a drift: that universe is GLOBAL by design — local ∪ imported ∪
  15307: -- prelude, see the P0-19 d8 note — and answers the inference-time binding question, not which
  15308: -- impl a route stamps.)
  ```
  **Use `grep -n 'local ∪ imported' compiler/types/typecheck.mdk` — it returns both (11683, 15306).**
  The brief's `local ∪ imported ∪ prelude` returns only 11683. Both must be **rewritten, not
  deleted**; `15306`'s is the more dangerous of the two because it also asserts a *structural
  invariant this bite breaks* (item 2 below).

---

## 2. 🚨 THE "WHOLE ANSWER" FACT — `15296-15309`, the drift-hazard block above `resolveRLocalSites`

This is the find. It is committed source, it carries `#415 item 2`, and it argues against the
exact transformation this bite performs. Verbatim (typecheck.mdk `85ceec1f`, `15296-15309`):

```
-- "Does an impl exist" and "which impl entails" must agree on ONE
-- KeyBuckets table — a drift between them would be a real dispatch bug.  #415 item 2: that
-- agreement is STRUCTURAL, not a standing obligation.  Both reads consume this function's single
-- [keyTable] param: `implExistsForHead keyTable` directly, and `keyForSite` via
-- routesOfMonosTop keyTable → routeOf → entail (EKNestedTop keyTable) → entailInst.  There is no
-- second table in scope to drift TO; each resolver group threads one `buildKeyTable` result to
-- all five stampers (elaborateDict:7323, elabModuleStamp:14711).  Re-introducing the hazard would
-- take adding a parameter or reaching for a global — so keep both reads on [keyTable].
```

**Read the last clause against the bite.** Re-basing `15352`'s existence read onto
`perRun.value.bodyImplEnvRef` **is "reaching for a global"**, while its sibling read at that same
site — `routesOfMonosTop prog implTable keyTable monos ifaces`, on the very next line of both
arms — **stays on `keyTable`**. That is the drift this block declares structurally impossible,
re-introduced by construction:

> existence answers **True** off the graph-global substrate ⇒ the site does **not** stamp
> `RLocal` ⇒ the call is expected to dispatch ⇒ but the **selection** leg
> (`keyForSite` / `entail`, still on the topological-prefix `keyTable`) has no row for that
> impl to select.

**So the fact settling this bite's verdict is: what does the route become when existence says
"an impl exists" and selection cannot find it?** That is one derivation the implementer must do
and it is *not* discoverable from the brief. Two honest resolutions, both cheap to state:
either (i) `15352` is deferred to B-2.1-b so existence and selection move together (the bite then
touches only `11548`/`11835`, both of which are inference-time and have **no** sibling selection
read — `15305-15308` says so explicitly), or (ii) both reads at `15352` move, which makes this
bite reach into the **evidence** path the brief insists it must not. **Say which, and rewrite
`15296-15309` to match — leaving it standing while its "no second table to drift TO" premise is
false is the exact hazard the brief's own "rewrite, don't delete" instruction is about.**

### Secondary "whole answer": **F1 is already CLOSED for the new substrate, by an executable doctest**

The brief leaves F1 as an open question for the implementer (*"`implExistsForHead` is a membership
test — if your implementation compares or renders keys, say so"*). **It does compare and render
keys** — `headTabIs` (`15240`) is `dispHeadTab hk == goal`, and `bucketOfHead` files/finds by
`headBucketRender`. **But the source already settles that this is F1-immune**, at
`4785-4790` (item 6d of the `ieByHead` probe block), with a fail-capable doctest one line below it:

```
--    6d. IMMUNE TO THE ARM-KEYING ASYMMETRY (RUN-B-025 F1).  Seq 4's interface mints
--        ONE `oblIfaceKeys` leg where 0/1/2 mint two, and it is in the bucket all the
--        same — because this key has no interface component.  An index that grew one
--        (or that keyed the head through anything origin-bearing) drops seq 4 here.
-- > map (r => instRefSeq (ieRowInst r)) (ieHeadRows (Some ieProbeBlobHead) ieHeadProbeEnv)
-- [0, 1, 2, 4]
```

and the mechanism at `4687-4694`: *"`ieByHead` cannot inherit that, because its key has no
interface component AT ALL: it is `headBucketKey (univReceiverTag tys)`, and `dispHeadTab hk =
TkBare NsType (headKeyName hk)` — bare spelling, origin-blind (#1317 T1)."*
**⇒ Do not investigate F1. Cite 6d and move on.** Your accessor is
**`ieHeadRows : Option HeadKey -> ImplEnv -> List ImplRow` (`4379`)**, which is
`mregLookupK (headBucketKey hd) env.ieByHead` — i.e. the substrate already exposes the *same*
head partition `bucketOfHead` gives you, so the shape of your read barely changes.

### Third: `15202-15228` — the #1111 MEASURED block that constrains your retest

Do not re-derive this either. Verbatim excerpt (`15205-15216`):

```
-- 🚨 THE RETEST IS SPELLING-KEYED, THROUGH `dispHeadTab`, AND IT MUST BE — it
-- has to be the SAME projection the BUCKETING applies, never a stronger one.
...
-- that was measured, not argued (#1111): the impl side (`headTyconTy`, off a
-- `Ty.TyCon`) came back `TkIdent … IdentBuiltin` for every primitive head on
-- both driver arms, while the goal side (`headTyconMono`) came back mixed
```

⇒ **A structural `HeadKey` compare re-opens a closed S0** (`debug (stringLength "xy")` printing
the standalone's answer at exit 0). Corpus: `test/shadow_fixtures/i11_importer_extern_receiver`.
Whatever you rebuild the retest on, keep it at exactly the bucket's projection strength.
Corroborating measurement at `18804-18823` (`MEASURED, #1317`): moving *only* the two counting
scans' retest to identity form turned `(1, 2)` into `(1, 1)` — #1277's S0, back.

### Fourth: substrate readiness at this pin — **`b2` has NOT landed at `85ceec1f`**

Both of these say so, and **both become false the moment your bite lands, so both are yours to
update**:
- `4152-4153`: *"This function removes that emptiness FIRST, additively: nothing reads
  `bodyImplEnvRef` yet."*
- `20697-20699`: *"ADDITIVE AND BEHAVIOUR-NEUTRAL BY CONSTRUCTION: nothing reads
  `bodyImplEnvRef` yet, which is the whole point of landing it as its own bite."*

The seating itself is done on **both** arms (`20703-20705`):
`Flat _ => buildFlatImplEnv fullUniverse` · `Module _ _ _ => driverState.value.declEnvsRef.value.deImpls`.
`4148-4151` records the RUN-B-017 probe-3 hazard this closed: **Flat's `IE` used to be
`emptyImplEnv`**, so a repoint before B-2.1-a2 would have been a correct→broken regression on
`check`/`lsp`/`repl`/`doc`/`lint`/`snapshot`. It is no longer empty. **The old table's seating
you are displacing is `20692-20694`** (`Flat => buildKeyTable fullUniverse`;
`Module => crossRun.value.universeKeyBucketsRef.value` — the cumulative **topological-prefix**
accumulator, which is the actual narrowness the bite is fixing).

### Fifth: the widening's blast radius is **IMPORTER shadows only** — all three sites

Not stated in the brief, and it shrinks the work:
- `11548` is in `inferShadowApp`, the importer-shadow app path (`11418` is its only caller).
- `11835` is guarded one line above at `11832`: `| isDefinerShadow name = definerReceiverIsDictVar name xt`.
- `15352` is `(not (isDefinerShadow name) && implExistsForHead keyTable name tag)`.
- `isDefinerShadow` (`11798-11800`) = `ifaceMethodName name && contains name
  perRun.value.definerShadowNamesRef.value` — definer-specific, as the brief's settled item claims.

⇒ **The definer arm is unreachable from every one of the three reads.** Your definer
`nearest miss:` is therefore a *non-regression control by construction*, not an investigation.

---

## 3. Contradictions / staleness in the draft brief

1. **"Four call sites, not three" — off by one** (§1). Three calls + the definition. The
   *mechanism* the brief warns about (the threaded-parameter site, signature change) is real and
   correct; only the count is wrong.
2. **"P0-A's design enumerated readers of the REF and got three — correctly"** conflates two
   populations. The three **ref** readers are `11548`, `11835`, **`22072`**; `22072` is
   `concreteReqMatchByIface`, **not** an `implExistsForHead` caller, and the brief never mentions
   it. The three **callers** are `11548`, `11835`, `15352`. **Neither set has four members.**
3. **The brief's grep for the stale defence comment finds only one of two** — `15306` is
   line-wrapped (§1). And `15306`'s comment is the load-bearing one.
4. **The brief's licensing case and the source's `#415 item 2` invariant are in direct
   tension at `15352`** (§2). The brief asserts the widening is *"a CONFORMANCE FIX, not an
   incidental widening"* — true of `11548`/`11835`, which have no sibling selection read — but at
   `15352` it also silently splits existence from selection. **This is the item to REFUSE-AND-REPORT
   on if you cannot resolve it cheaply.**
5. **The brief leaves F1 open when the tree closes it** (§2, item 6d). Minor, but it is an
   investigation the implementer would otherwise start.
6. **The brief's `SHADOW-SEMANTICS.md:241-245` citation is right but off by one at the front** —
   the retired-phrase sentence begins at **`242`** (`241` ends *"the other about **instances**. ⚠️ Beware
   in particular that"*). Quote `241-245` and you get the lead-in; quote `242-245` and you get the
   clause. Immaterial, recorded for precision.

---

## 4. Licensing clauses — pre-quoted, all four cited line numbers **VERIFIED CORRECT** at `85ceec1f`

**`docs/spec/SHADOW-SEMANTICS.md:183-186`** ✅ (bullet begins exactly at 183):
```
- **Live impl** / **no-impl** (of a receiver): the receiver's head tycon does,
  or does not, have an `impl` of the shadowed interface — tested against S2's
  **graph-global** impl universe (§1.0), never filtered by what `M` can name.
  Used throughout §2's matrix ("live-impl recv" / "no-impl recv") and §3.
```

**`:226`** ✅ (the glossary table row, one line):
```
| **graph-global** | ranges over **every** module of the loaded graph, whether or not any import path reaches it — `DICT-SEMANTICS.md` §8 **I5** | S2's **impl universe** only |
```

**`:36-37`** ✅ (the 2026-08-06 branch ruling, inside the blockquote):
```
> - **The branch.** **S1's interface operand is scoped to what the module can
>   NAME; S2's impl universe stays graph-global.** The argument, the cost, and
>   the **⟲ overturn condition** are in the **S1-SCOPE** note under S1.
```

**`:228-245`** ✅ — the separately-scoped-operands paragraph pair. The two load-bearing halves:
```
228: ⚠️ **S1's two operands are NOT the same set, and that is deliberate.** The
229: standalone operand is the *narrower* one — it is pinned by S1's own kind
...
237: **"Nameable" and "graph-global" are NOT the same set** either, and *that*
238: difference is the whole content of S1 versus S2: a module `M` with no import path
239: to module `P` cannot name `P`'s interfaces (so they create no shadow in `M`) but
240: `P`'s **instances** are still candidates for every goal arising in `M` (I5). One
241: is about **names**, the other about **instances**. ⚠️ Beware in particular that
242: "local ∪ imported ∪ prelude" is **not** a synonym for graph-global — it is
243: strictly narrower than I5's instance universe, an older wording of S2 used it as
244: one anyway, and that collision (the same three-item enumeration carrying opposite
245: force thirty lines apart) is what made S1 unreadable.
```

Bonus, for the `nearest miss:` (b) argument — **`:249-261`, the S1 clause itself**:
```
- **S1 (shadow-hood).** ... `N` is a shadow **in `M`** iff `N` ∈ funDef-names(standalones
  **defined in `M` or imported into `M`**) ∩ iface-method-names(interfaces
  **nameable in `M`**). ... but an interface that `M` cannot name creates **no shadow in `M`**,
  ... **The impl universe is not narrowed by this clause** — see S2 and §1.0.
```

---

## 5. The two `nearest miss:` programs, written out

### (b) — the S1/S2 separation. **DO NOT WRITE THIS ONE; IT ALREADY EXISTS.**

`test/shadow_fixtures/i13_importer_not_nameable_liveimpl/` (5 modules) is exactly this cell, with
its expected behaviour written in its own header: *"`size` is not a shadow in this module … applying
it to a `Box` is a located REJECT (`Type mismatch: Int vs Box`) on all three verbs … Under the
graph-global reading the same source is ACCEPTED at exit 0 and prints `300`."*
Siblings on the same axis: `i12_importer_iface_not_nameable`, `i17`, `i18`, `i21`,
`d24_definer_return_pos_not_nameable`.

**And the structural reason it cannot regress — cite this instead of designing a program.**
Shadow-hood is computed at `20680-20686`, *before* any `implExistsForHead` read, from a
**different substrate**: `crossRun.value.universeIfaceMethodsRef.value` filtered through
**`nameableIfaceShadows`** (`26412-26414`). The impl table (`20692-20694` today,
`bodyImplEnvRef` after this bite) is **not an input to shadow-hood at all**. So a widened *impl*
universe cannot widen *shadow-hood*: S1's operand and S2's operand are separately computed, not
merely separately documented. `4868` records this as the design (*"FILTER AT THE READ
(`nameableIfaceShadows` narrowing the graph-global set…)"*).
⇒ **State it as one line + the i13 citation, and note the gate that grades it is
`test/diff_compiler_shadow_semantics.sh` (single-armed only, #1431).**

### (a) — definer shadow, receiver's impl in a **NON-PREFIX** module

The closest committed fixture is `test/shadow_fixtures/d8_definer_imported_impl/` (2 modules) —
but it is the **PREFIX** case (`main.mdk` imports `prov`, so `prov` precedes `main` in the
cumulative accumulator, and the read finds the impl today). **d8 is your positive control, not
your discriminator.** Reuse its shape:

`main.mdk`
```
import prov.{Sizeable, Box(..)}

size : Int -> Int
size n = n + 1

main =
  println (size (Box 3))
  println (size 3)
```
`prov.mdk`
```
export interface Sizeable a where
  size : a -> Int

public export data Box = Box Int

export impl Sizeable Box where
  size (Box n) = n
```
**d8 prints `3` then `4` and `check` accepts** — the definer standalone wins even with a live
imported impl, which is S2's inversion. Your non-prefix variant must produce the **same** answer.

**The non-prefix program.** `main` is the entry, so *every* module `main` reaches is in `main`'s
own prefix — the shadow question must therefore be asked in a **non-entry** module, with the impl
in a **sibling** branch of the graph. Five files:

`ifc.mdk`
```
-- interface + receiver type, nameable from both siblings
export interface Sizeable a where
  size : a -> Int

public export data Box = Box Int
```
`m.mdk` — **the module holding the definer shadow**
```
-- DEFINER shadow: `size` is this module's own top-level fn.  The receiver's impl
-- lives in `q`, which this module does not import and which is NOT in this
-- module's topological prefix.  Expected: the STANDALONE wins (S2's inversion),
-- so `size (Box 3)` is a located REJECT `Int vs Box` -- unchanged by this bite,
-- because all three implExistsForHead reads short-circuit on isDefinerShadow.
import ifc.{Sizeable, Box(..)}

size : Int -> Int
size n = n + 1

export mv : Int
mv = size (Box 3)
```
`q.mdk` — **the non-prefix impl provider**
```
import ifc.{Sizeable, Box(..)}

export impl Sizeable Box where
  size (Box n) = n * 100

export qf : Int -> Int
qf n = n
```
`main.mdk`
```
import m.{mv}
import q.{qf}

main = println (mv + qf 0)
```

**What it should do today, from the spec — not from an engine.** S2's definer arm routes to the
standalone **unconditionally** (SHADOW-SEMANTICS §1.0 / the `resolveRLocalSite` header at
`15332-15345`), so `mv = size (Box 3)` applies `Int -> Int` to a `Box`: a **located reject,
`Type mismatch: Int vs Box`, exit 1**, on `check`/`run`/`build`, whether or not `q`'s impl is
in `m`'s prefix. **After the bite it must still reject, for the same reason.** If it *starts*
accepting and printing `300`, the widening reached the definer arm and the bite is an S0 — that
is the one outcome that must stop the bite.

⭐ **The free discriminator hiding in this program — use it, it is fail-capable and costs one
edit.** Change `m.mdk`'s `size` from a definer shadow to an **importer** one (move
`size : Int -> Int` into a sixth module `prov.mdk` and have `m` do `import prov.{size}`,
i13-style). Now `implExistsForHead` *is* reached, `m`'s cumulative prefix does **not** contain
`q`'s impl, and the two arms genuinely differ:
- **today (topological-prefix table):** no impl found → `RLocal` → standalone → reject `Int vs Box`;
- **after the bite (graph-global):** impl found → dispatch → accepts, prints `300`.

⚠️ **Both halves depend on `q` being ordered after `m`, which is loader topo-order over two
independent siblings — verify it rather than assume it.** The cheap control: swap the two
`import` lines in `main.mdk`. If today's answer *changes* under the swap, you have proved the
current behaviour is topological-prefix-dependent (which is the defect); if it does not, `q` was
in `m`'s prefix all along and the program is not yet discriminating — deepen it (put `q` behind
its own importer so it sorts later) before drawing any conclusion. **After the bite, the swap
must make no difference at all** — that invariance *is* the conformance claim, and it is a
stronger assertion than either arm's value.

---

## 6. Refused / not done

- Did not audit the wider shadow subsystem, the `Route`/engine consumers, or `DEBT.md`/`DECISIONS.md`.
- Did not design the bite: item 2's two resolutions are stated as a choice for the implementer,
  not decided.
- Ran **no** build, gate, or `./medaka` (per instruction) — so every "should do" above is derived
  from the spec and committed comments, never from an engine's output.
- Did not re-derive the settled items (definer-arm closure, F1 dormancy, the same-keys measured
  regression); §2 items 3/5 only *cite* the committed measurements that back them.
