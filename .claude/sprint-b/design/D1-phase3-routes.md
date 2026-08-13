# D1 — Phase 3′ (B-2.2, evidence references in routes): refreshed bite list

**Agent:** D1, design, Stage B sprint. **STRICTLY READ-ONLY.** Nothing was built; no gate,
probe or binary was run. **Every source line below is cited against the pinned commit
`604278bb`** (`sprint-b: B-2.1-b1 REFUSED and reverted; STOP-AND-LAND gate triggered`), read via
`git show 604278bb:<path>`. A writer is live in `compiler/types/typecheck.mdk`; the working tree
was never read.

**This file REFRESHES `.claude/sprint-b/phase0/P0-B-routes.md` §2/§3 and §7.3.** Where it and
P0-B disagree, this file gives the derivation and P0-B's claim is quoted so the disagreement is
visible. Nothing here is a measurement. Every claim is `DERIVED` (I read the code at `604278bb`)
or `RELAYED` (I read a ledger).

---

## 0. Answers first

1. **Two of P0-B's seven B-2.2 bites are now Phase 2′'s** (`B2.2-d`, `B2.2-d′`) — both are
   *selection/population* work that lands with a `String` payload. Five stay in 3′ (§1).
2. **`B-2.1-a2` simplifies nothing in 3′ directly** — it is a population substrate, and 3′ is a
   payload axis. What it buys 3′ is that the *identity* 3′ mints already exists on the substrate:
   `ImplRow`'s 2nd field is an `InstRef` (`typecheck.mdk:4058-4065 @604278bb`), so a
   row-returning selector hands the stamper identity with no second lookup (§2).
3. **The third leg does NOT change the stamping-site list** (still 6 `RKey` construction sites)
   **but it doubles the number of SELECTIONS per site, and that is 3′'s real crux** (§3).
   `argReqRoute` selects nothing — corrected (§3.1).
4. **Discharge kinds: 12, plus 4 sub-discharges and one precedence leak** — table at §4, with a
   handling column per kind. **Three kinds must NEVER acquire identity** (D1, D2, D7); two must be
   ruled before 3′ starts (D8, D9 — now Phase 2′'s).
5. **Supers boundary: STILL DESTROYED in every table, unchanged by `B-3-b`** — derivation at §6.1.
   **But it no longer needs a table**: appended slots have exactly ONE mint site
   (`superSlotOf:9209-9217 @604278bb`), so a `csDeclared` flag on `CSlot` is a 4-site change that
   makes INVARIANT (a-i) expressible with **no new Ref, no ratchet allowlist row, and no
   `funConstraintsRef` payload widening** (§6.2). This is materially cheaper than P0-B's `B2.2-f`.
6. **`expandSupersTable` fill bite:** `B-3-b`'s rewrite *does* change it — for the better and in
   one direction only: the two table-writing expansion paths collapsed into one pure function with
   one write op per pair, so the fill bite's site list shrinks. It does **not** touch the two
   *call-site* expansions (`inferDictAtFound:8919`, `shadowStandaloneDictSlots:12111`), which are
   where the surviving route fills read their slots (§6).

---

## 1. Which of P0-B's bites are Phase 2′'s and which remain Phase 3′'s

The axis (RUN-B-009): **2′ = population unification, payload stays a `String`. 3′ = payload
identity.** Test I applied to each bite: *can this bite be landed, complete and verifiable, with
`RKey`'s payload still a `String`?* Yes ⇒ 2′. No ⇒ 3′.

| P0-B bite | content | verdict | why |
|---|---|---|---|
| `B2.2-a` | `Route`'s payload becomes identity-bearing | **3′** | it *is* the payload change |
| `B2.2-b` | stamp identity at the four `inst` arms | **3′** | requires `a` |
| `B2.2-c` | precedence assertion on the non-`inst` kinds | **3′** | it is the guard on 3′'s own change; landing it in 2′ guards nothing yet |
| `B2.2-d` | D8/D9 — the two selector-free `RKey` stamps | 🔴 **MOVES TO 2′** | *"re-base onto the one selector"* is a **selection** change, complete with a `String` payload; and D8 reads `prog`, not `IE` — a residual candidacy reader, i.e. population. Deciding it under a simultaneous type change is strictly harder |
| `B2.2-d′` | thread the per-slot iface into the iface-blind fill paths | 🔴 **MOVES TO 2′** | same: it changes *which impl is selected*, not what the word says. Also its `resolveRecMono` half **is** D9's edit (P0-B says so), so splitting them across phases would edit one site twice |
| `B2.2-e` | emitter/eval-side paired key derivation | **3′** | must land with `b` (§5) |
| `B2.2-f` | preserve the declared/appended super-slot boundary | **3′** | it exists only because identity is stamped; §6 |

⚠️ **Neither `d` nor `d′` is in RUN-B-024's re-planned Phase 2′ list** (`a3`, `b2`, `c`, `d`, `e`,
plus the moved `B-2.4-a`/`b`). **I am not silently keeping them in 3′ to make my own phase tidy.**
They are 3′-**blocking** either way: `B-2.2-b` cannot stamp identity while two sites in its own
region mint `RKey` with no selector in the path, because the stamp there would be a *fabricated*
identity. Two acceptable resolutions, orchestrator's call:
- **(preferred)** add `d`/`d′` to Phase 2′ after `b2`, where they are cheap and where the payload
  is still a `String` so a wrong re-base shows up as a wrong *word* (diffable) rather than a wrong
  *identity* (which every downstream consumer is being taught to trust);
- or keep them at the head of 3′ **as its first two bites, before `a`** — never after `a`.

**Also relevant to 3′ and already ruled elsewhere, recorded so 3′'s owner does not re-derive it:**
`B-2.4-a`/`b` moved to the end of 2′ (RUN-B-013); `B-2.4-e`, `c`, `d` stay in Phase 5 with the
three superset-OR deletions — and those ORs are **deletable only after `B-2.2-a/b/e`**
(`llvm_emit.mdk:1512-1518`, `eval.mdk:1207`/`:1211`, `wasm_emit.mdk:4014-4048`, all verified
present at `604278bb`). Phase 3 → Phase 5 order must not be compressed.

---

## 2. What `B-2.1-a2` (`bodyImplEnvRef`) simplifies

`B-2.1-a2` landed `buildFlatImplEnv:4175` + `ieIndexRows:4182` + `PerRun.bodyImplEnvRef:6784`
(RELAYED from RUN-B-021; the three symbols verified present at `604278bb`). P0-B designed against
a tree where the Flat arm had no `IE`.

**What it changes for 3′ — one thing, and it is structural, not cosmetic:**

- **3′ needs no arm gate anywhere.** One ref on both arms means the identity mint in `B-2.2-a`
  reads one substrate. P0-B's `B2.2-a` would otherwise have owed a Flat peer for its mint
  (`buildKeyTable prog2` at `:14123` vs the cumulative `stampKeyTable` at `:28682` — the same
  Flat/Module asymmetry P0-B derived for the reader at `:20347`/`:20348`).
- **The identity is already on the substrate.** `data ImplRow = ImplRow Int InstRef IfaceRef (List
  Ty) (List Require) (List String)` (`:4058-4059 @604278bb`), accessor `ieRowInst:4064`. So
  "mint identity" is not "compute something new at the stamp"; it is "do not throw the row away".

**What it does NOT simplify, stated so nobody reads point 1 as more than it is:** `KeyBuckets`,
`ImplBuckets`, `stampKeyTable` and the 7 stampers are all still present at `604278bb`
(`stampImplTable`/`stampKeyTable` grep confirms the pair and its consumers). 3′ inherits whatever
Phase 2′ leaves; see §5's precondition.

---

## 3. The third leg, and what it does to 3′

### 3.1 Correction to P0-B, first: `argReqRoute` selects nothing (DERIVED)

`argReqRoute:19481-19495 @604278bb` is a `routeOfD` adapter — its whole body is a `routeOfD …`
call. `routeOfD:19190-19203` is *"a thin adapter over `entail` (EKNestedTop kind)"* (its own
header) whose body is `fst (entail implTable "" m encl (EKNestedTop keyTable iface policy depth
rest))`. **So every `requires` sub-goal's selection happens back in D4's arm**, not at
`argReqRoute`. This matches RUN-B-023 and contradicts P0-B's §3 site list. Consequence for 3′:
**D4 is the recursion hub — a change there is exercised by every nested `requires` in the tree,
which is why its `nearest miss:` must be a nesting-depth ≥2 program, not a flat one.**

### 3.2 The stamping-site list is UNCHANGED (DERIVED)

```
grep -n "RKey" <604278bb:typecheck.mdk> | (drop comment lines)
→ 15393  19114  19142  19161  19288  19538   (construct)
→ 19664  19831                              (destructure; 19664 also re-constructs)
```
Six construction sites, the same six P0-B's D-table names (its line numbers +101 in the 19xxx
region and +101 at `stampOpRouteVal`). **The third leg adds no site.**

⚠️ **P0-B's count does not reproduce.** It says *"exactly 7 hits, of which 5 construct and 2
destructure."* At `604278bb` and at BASE `2b9dc798` alike the filtered grep yields **8** hits —
**6 construct**, 2 destructure. Its own D-table names all six construct sites, so the prose
undercounted its own table. Nothing turns on it; recorded because *"never state a count without
the command"* is this run's standing rule and this is the second P0-B count to move (the first was
85 → 75, RUN-B-013).

### 3.3 What the third leg DOES change: two selections per site

This is the finding, and it is what makes "stamp identity at `inst`" insufficient as a bite
statement. **Each `inst` arm runs the selector TWICE** — once for the primary route word, once
inside its element/`requires` route helper — and the two do not always ask the same question:

| arm | primary word selector | element/`requires` selector | same selection? |
|---|---|---|---|
| **D3** `EKReturn:19110-19116` | `keyForSite keyTable name paramMonos` (method-keyed) | `implDictRoutesForFull … name … paramMonos` → `matchedEntry keyTable name paramMonos` (`:18793`) | ✅ **provably identical** — same method key, same goal vector |
| **D4** `EKNestedTop:19139-19144` | `keyForSiteByIface keyTable iface (m::rest)` | `argImplRequiresRoutes:19387-19398` → `selectReqImpl:19412-19415` → `selectImplEntryByIface keyTable iface goals`, `goals = m::rest` when `iface ≠ ""` | ✅ identical (this is RUN-B-023's *"the same selection, on the same iface and the same goal vector, computed twice"*) |
| **D5** `EKArg:19153-19163` | `keyForSite keyTable name goals` | `argImplDictRoutesForEncl … dictName … goals` → `matchedEntry keyTable dictName goals` (`:19468`), where `dictName = name` **or** `innerDefaultMethod name` | 🚨 **NOT necessarily** — a default-reduced method is a **different key** |
| **D6** `EKOp` → `stampOpRouteVal:15374-15393` | `keyForSite keyTable method [operandMono]` | `argImplDictRoutesFor … dictMethod …`, `dictMethod = method` **or** `innerDefaultMethod method` | 🚨 **NOT necessarily** — same reason |

**Three consequences for 3′, all load-bearing:**

1. **P0-B's §2.2 checkable property is WRONG as written.** It says *"the number of call sites of
   the identity-minting selector must equal the number of `inst` arms (D3–D6). Any additional
   caller is a precedence violation."* At `604278bb` there are already **two selector calls per
   arm**, so that property fails on a correct tree and would license "fixing" it by collapsing
   D5/D6's two different keys into one — a semantics change. **Restated property (§5, `B-2.2-c`):**
   > *Every selector call reachable from `entail` lies in an `inst` arm or in an element-route
   > helper called from one. No selector call may be reachable from `entailAssum*` or
   > `entailFallback`.* Grep-checkable, and it does not forbid the legitimate second call.
2. **`B-2.2-b` may collapse the double selection at D3 and D4 ONLY** (bite `b2`, §5). At D5/D6 the
   element route asks about a *different method*; collapsing there is the "unify for uniformity"
   refactor this section exists to forbid.
3. **The identity 3′ stamps is the PRIMARY selection's.** The element routes are evidence for
   *other* goals (the selected impl's own context) and carry their own identities recursively via
   D4. An implementer who stamps the element helper's row into the primary word has crossed two
   goals — and at D5/D6 that is silently a different impl.

---

## 4. 🚨 The discharge-kind enumeration (the anti-S0 section)

Derived from `entail`'s ladder (`:19054-19059 @604278bb` — three rungs: `entailAssum` →
`entailInst` → `entailFallback`, **no `super` rung**) plus every non-comment `RKey`/`RDict`/
`RDictFwd`/`RNone` producer reachable from it. Precedence is documented in-tree at `:19061-19068`
citing DICT §3.

| # | Discharge kind | Site `@604278bb` | Selected instance? | **3′ handling — mandatory** |
|---|---|---|---|---|
| **D1** | `assum`, tyvar-keyed | `entailAssumVar:19081-19086` → `entailAssumRoute:19088-19096` → `RDict`/`RDictFwd` | **NO** | **UNCHANGED. NEVER re-resolve through `inst`.** It already *is* `DictParam k`. Rebuilding here is #203's class: general evidence where the construction site's dict must be **forwarded** |
| **D2** | `assum`, predicate-keyed given (`registerPredGiven`) | `entailAssum:19069-19073` 2nd arm | **NO** | **UNCHANGED**, same reason, same constructors |
| **D3** | `inst`, return position | `entailInst … EKReturn:19110-19116`, `RKey` at `:19114` | **YES** | **STAMP.** Identity from the primary selector's row |
| **D4** | `inst`, nested/top constrained call (**the recursion hub**, §3.1) | `:19139-19144`, `RKey` at `:19142` | **YES** | **STAMP.** Also the only arm every nested `requires` reaches |
| **D5** | `inst`, argument position | `:19153-19163`, `RKey` at `:19161` | **YES** | **STAMP the primary only.** Element route keeps its own (possibly default-reduced) selection — §3.3 |
| **D6** | `inst`, operator site | `:19164-19165` → `stampOpRouteVal:15374-15393`, `RKey` at `:15393` | **YES**, or builtin → `RNone` | **STAMP the primary only.** Builtin arm stays `RNone`; same element-route caveat |
| **D3e–D6e** | the element/`requires` **sub**-discharges | `implDictRoutesForFull:18789`, `argImplDictRoutesForEncl:19467`, `argImplRequiresRoutes:19387`, `argImplReqRoutes:19477`, `argReqRoute:19481` → back to **D4** | **YES, per sub-goal** | **Each sub-goal gets its OWN identity, via D4.** Never the parent's. `argReqRoute` mints nothing (§3.1) |
| **D7** | `super` | **NO SITE** — no rung; flattened by `expandSupersTable:9131-9136` | **NO** | 🚨 **WITHHOLD identity from appended super slots** — §6. Ruling (a) (RUN-B-009) makes this an obligation, not a no-op |
| **D8** | undetermined-by-**count** (fallback) | `entailFallback:19169-19170` → `undeterminedRoute:19205-19208` → `routeUndeterminedTop:19277-19290`, `RKey` at `:19288` | **NO SELECTOR RAN** | **RULE FIRST (now Phase 2′'s, §1): re-base onto the selector, or demote to `RNone`.** Never carry the bare tag into an identity payload. Note `implHeadTagsForIface:19299` **dedups by head**, so `impl C (T Int)` + `impl C (T Bool)` present as ONE candidate and take the `[tag]` arm; and it reads `prog`, not `IE` |
| **D9** | recursive-call constraint route | `resolveRecMono:19536-19540`, `RKey` at `:19538` (`Some tag => RKey tag []`) | **NO SELECTOR RAN** | **RULE FIRST (Phase 2′'s).** Its sibling arm forwards a dict (`RDict (dictParamName encl slot)`), so this is the *concrete* arm of the recursive route. **If demoted to `RNone`, §6's boundary carrier for the recursive fill path is discharged for free** |
| **D10** | `RLocal` (definer shadow) | `ast.mdk:727 @604278bb`; producers `resolveRLocalSites:15072-15083` | n/a — not a dispatch discharge | **OUT.** SHADOW spec #616. Touch only with that spec cited |
| **D11** | `RScalar` | `ast.mdk:728` | n/a | **OUT** |
| **D12** | `entailFallback`'s `RNone` arms | `:19168`, `:19171`, `:19172` | **NO** | **UNCHANGED** — load-bearing do-nothings (the arms' own comments at `:19040-19052` say the op-site refs are `RNone`-seeded and the guard preserves that) |
| **D1-leak** | a **rigid in-scope** goal whose `activeDictVarOfEncl`/`opDictVarOf` lookup **misses**, so the ladder falls through to `inst` | `entail:19055-19059` (the `None =>` fall-through) | it *acquires* one it should not have | 🚨 **3′ MUST NOT WIDEN THIS, and cannot fix it.** Today the fall-through rebuilds general evidence at a site whose dict should be forwarded (#203/#1127 leg 2). 3′ makes the wrongness *nameable* (an identity naming an impl where a param should have been forwarded) without fixing it. **State it as `B-2.2-c`'s `nearest miss:`; do not attempt it here** — #1127 legs 1–2 are B-1's (RUN-B-009, P0-B §1.4) |

**The one-sentence version of this table, for a brief:** identity is minted from a **selected
row**; **D1/D2/D7 have no row and must keep their current constructors**; **D8/D9 have no row and
must be ruled before any stamping lands**; **D1-leak has the wrong row and 3′ may not make it
worse.** A bite that says "stamp at `inst`" without those four clauses is the S0.

---

## 5. Phase 3′ bite list (§4 format)

Every `sites:` is `file:line @604278bb`. Re-derive by symbol before editing —
`DICT-SEMANTICS.md:2499` records that drift in this file is **non-monotone**, so a recorded delta
is worth less than no delta.

### 🚨 Precondition on Phase 2′ that 3′ cannot supply for itself

> **Phase 2′'s `B-2.1-b2` must leave the unified selector returning the ROW
> (`Option ImplRow`), not a projected `String`.**

`keyForSite:17973-17974` and `keyForSiteByIface:18658-18659` both take
`selectImplEntryByIface`/`matchedEntry`'s `Option KeyEntry` and **throw the entry away to keep the
word.** If 2′ preserves that throw-away, 3′ must re-run the selector to recover identity — a
second resolution of one goal, at the site RUN-B-023 measured at **`check-self` 21.5 s → 25.1 s
(+17%)** for one extra scan. P0-B raised this as a recommendation; with the third leg it is a
**hard precondition on three entry points**, not one. **If 2′ lands with a `String`-returning
selector, `B-2.2-b1` is not statable as a bite and 3′ stops.**

---

### `B-2.2-d` / `B-2.2-d′` — **MOVED TO PHASE 2′.** See §1. Not cut here.

If the orchestrator keeps them in 3′, they are its **first two** bites, before `a`. P0-B's site
lists hold at `604278bb` with one correction: **`routesOfMonos:19319-19323` is NOT a super-slot
fill path.** Its only caller is `resolveMethodDicts:19506` (`grep -n "routesOfMonos "`, non-comment
→ `:19506` only), which routes **method-level** constraints; `expandSupersTable` expands
`funConstraintsRef` (**fn**-level), so no appended super slot ever reaches it. It *is* iface-blind
(passes `""` → `findImplEntry`'s first-match) and worth fixing, but as a **method-constraint**
defect, not a supers one. The genuine supers-bearing fills are `routesOfMonosTopV:19230` /
`topRouteV:19238` (**iface-aware ✅**, reached from `resolveDictApps:18990-18996`) and
`recRoutes:19522` → `recRoute:19531` → `resolveRecMono:19536` (**iface-blind ❌**, reached from
`realizeRecDictApps:19514-19520`). So P0-B's §7.3 three-row table is right that *two of three are
iface-blind* and wrong about *which two carry supers*: **one** iface-blind path carries super
slots, not two.

---

### `B-2.2-a` — `Route`'s evidence payload becomes identity-bearing

- **sites:** `compiler/frontend/ast.mdk:722-728` (`data Route`, unchanged at `604278bb`) · ONE new
  mint fn sited beside `InstRef` at `compiler/types/typecheck.mdk:3996` · the compile-error set the
  type change produces (that set **is** `B-2.4-e`'s site list, RUN-B-013).
- **transform:** change `RKey`'s **first field type** from `String` to a two-component carrier:
  (i) the **content-derived word** the engines match on, (ii) the `InstRef` within-compile
  discriminator. 🚨 **CHANGE the type; do NOT add a parallel `RInst` constructor** — a new AST
  constructor is swallowed by every `_ =>` wildcard arm (`AGENTS.md`'s standing trap), and a
  parallel constructor *is* the superset hedge B-2.4 exists to delete.
  🚨 **The WORD may not be derived from `InstRef`.** `InstRef`'s own header, `:3980-3995`, is
  explicit and was written for this bite: *"`seq` is a WHOLE-GRAPH running counter … If B-2 wants a
  NAME, derive it from `(module id, interface identity, head)` — content, not position."* **The
  content mint already exists in two mirrored copies:** `implKeyTc:17914-17915`
  (`"{iface}|{tyargs}|"`, typecheck side) and `implKeyOf` (`eval.mdk:481-483`, same bytes by
  construction per its header). Both key on the **BARE** iface name — and `ifaceIdentity`
  (`ast.mdk:121-124`, `"{module}::{name}"`) is *already* computed beside `implKeyOf` at
  `core_ir_lower.mdk:1301` and `eval.mdk:305` and then **dropped from the key**. **That drop is
  #1182's mechanism**, and closing it is one substitution in the mint.
- **could move:** nothing on its own — the bite is "type + mint + make the tree compile again
  carrying today's word". It is **not** compilable-and-inert by design: it forces every consumer
  to fail to compile, which is the loud form.
- **nearest miss:** an interface whose impls live in **two modules with the same module-local
  spelling** — the word must separate them or identity bought nothing (#1047's class). Second
  miss, cheaper to test and more likely: **two interfaces declaring the same method name**
  (#1182) — the word must carry `ifaceIdentity`, not the bare name.
- **engines:** LLVM · wasm · eval · `core_ir_lower` · `core_ir_sexp` all match `Route`. **Owes all
  five.** `core_ir_eval` is the fourth arm (RUN-B-007 AM-3) and shares eval's consumers while
  duplicating its producers (RUN-B-013) — check both.
- **sizing:** ✅ **statable.** "One type, one mint, then fix every compile error." The error set is
  enumerated by the compiler, which is exactly the property that makes it Sonnet-safe.

### `B-2.2-b1` — stamp identity at the four `inst` arms, from the selector's ROW

- **sites:** `:19110-19116` (D3) · `:19139-19144` (D4) · `:19153-19163` (D5) · `:19164-19165` →
  `stampOpRouteVal:15374-15393` (D6). **Four arms, one helper. Four sites, not five** — D6's arm
  is a one-line delegation.
- **transform:** each arm today reads `let routeKey = fromOption tag (keyForSite… )` — a **head-tag
  hedge over a selector result**. Replace with: one selector call → the row → mint identity from
  the row. `fromOption tag` disappears; `keyForSite`'s own header (`:17969-17972`) calls that
  *"#1113's end state"*.
- **could move:** **acceptance, no. Emitted evidence, YES, at every single-impl-per-head site in
  the tree** (`keyForSite`'s header). Also the `T-AMBIGUOUS-INSTANCE` channel:
  `pickMostSpecificEntry:18194-18196` still *returns* the first match after reporting
  (`DICT-SEMANTICS.md:2499`), so **a rejected program's routes must stay unchanged — assert it,
  do not assume it.**
- **nearest miss:** a goal whose selector returns `None` (headless/unmatched). Today `fromOption
  tag` silently substitutes the head tag; after this bite there is **no tag to fall back to**, so
  the `None` arm is a **new code path no existing fixture can exercise** — every existing fixture
  covered the substituted case. This is the tree's canonical returns-nothing → returns-something
  hazard; **the fixture must be built from the spec, not from the diff.**
- **engines:** all four arms consume the moved word. Owes the `noneHeadTag` general-fallback tier
  (`emitGeneralRKey:4593-4594` → `findByTag noneHeadTag`, `llvm_emit.mdk`; eval's
  `pickTagFallback:1053-1054`). `keyForSite`'s neighbouring header (`:17953-17959 @604278bb`)
  warns that behaviour surviving this IR change is *"EMPIRICAL, not structural"* and rests on that
  tier — **RELAYED, and it is what this bite's implementer must re-derive on a build.**
- **sizing:** ✅ statable **iff** the §5 precondition holds. If the selector still returns a
  `String`, ❌ — what is missing is a row-returning selector, and the bite goes back.

### `B-2.2-b2` — collapse the double selection at D3 and D4 **only**

- **sites:** D3's pair (`:19114` + `implDictRoutesForFull:18789-18795`) · D4's pair (`:19142` +
  `argImplRequiresRoutes:19387-19398` → `selectReqImpl:19412-19415`).
- **transform:** pass the already-selected **row** into the element-route helper instead of letting
  it re-select. Justified per arm, not by uniformity: at D3 both calls use the same method key and
  the same `paramMonos`; at D4 both use the same `iface` and `m::rest`. **Provably one selection
  each** (§3.3).
- 🚨 **EXPLICITLY EXCLUDES D5 and D6.** Their element routes select on `innerDefaultMethod name` /
  `innerDefaultMethod method` — a **different key** — so collapsing them changes which impl's
  context is discharged. A bite that "finishes the job" at D5/D6 is a semantics change.
- **could move:** nothing, if the two calls are genuinely the same selection — which is the claim
  under test. **Verification is a `check --json` code differential plus the flat-vs-onemodule
  value clause**, because a wrong collapse shows up as a wrong *value*, not a wrong verdict.
- **nearest miss:** a D5 site whose method **is** default-reduced (`innerDefaultMethod` ≠ `name`) —
  untouched by this bite by construction, and the fixture that proves it was not touched.
- **engines:** none new (same words, one fewer computation) — **assert byte-identical IR here**;
  unlike `b1`, this bite genuinely has a byte-identical bar.
- **sizing:** ✅ statable — two named pairs.
- **note:** this is the only bite in 3′ that RUN-B-023's +17% measurement argues *for*: it removes
  one of the two scans per site.

### `B-2.2-c` — the non-`inst` discharge kinds: assert, do not re-route

- **sites:** `entail:19054-19059` (the ladder) · `entailAssum:19069-19073` (D2) ·
  `entailAssumVar:19081-19086` (D1) · `entailAssumRoute:19088-19096` (all four arms) ·
  `entailFallback:19167-19172` (D12).
- **transform:** **no behavioural change.** Add the §4 table's mandatory-handling clauses and the
  **restated** selector-reachability property (§3.3 item 1) as a comment at the ladder, naming
  DICT §3, so the next refactor cannot "unify" these into the selector without deleting the
  sentence that forbids it. ⚠️ **Do not restate P0-B's site-count property — it is false on a
  correct tree** (§3.3).
- **could move:** nothing — pure comment + a review invariant. Valid "nothing", with the reason:
  no expression changes.
- **nearest miss:** **D1-leak** (§4) — a rigid in-scope goal at an `EKArg`/`EKOp` site whose
  `activeDictVarOfEncl`/`opDictVarOf` lookup misses and the ladder falls to `inst`. That
  fall-through is a real re-resolution **today**, this bite does not fix it, and #1127 legs 1–2
  are **B-1's**. State it; do not fix it.
- **engines:** none.
- **sizing:** ✅ statable. ⚠️ Comment-only edits carry two live traps: **#829's record-comment
  corruption** (check the record header shape first — the records here are fine, but
  `fmt --write` is mandatory and its damage passes `fmt --check`), and **fixture line-count
  neutrality** if any golden pins a line below the edit.

### `B-2.2-e` — the paired definition-side key derivation (lands WITH `b1`)

- **sites:** `compiler/ir/core_ir_lower.mdk:1346-1347` (`declRouteKey tag key unique = if unique
  then tag else key`) · `:1343` (`ifaceRouteKeysGo`) · `:1355-1356` (`ifaceDeclHeadUnique`) ·
  `:1301` (`ifaceImplHeadEntries`, which already computes `ifaceIdentity o ifaceName` **and**
  `implKeyOf ifaceName typeArgs None` — identity available, dropped from the key) · `:1392-1393` ·
  `compiler/eval/eval.mdk:1998-2004` (`implMethodEntry`, storing **both** `tag` and `key` into
  `VTypedImpl`) · `:305` (`declImplIfaceIdRow`, same identity-available-then-dropped shape) ·
  `:481-483` (`implKeyOf`) · `compiler/types/typecheck.mdk:17906` + `implKeyTc:17914-17915`.
  **All nine verified at `604278bb`.**
- **transform:** derive the impl's own identity word from the **same** content mint as `B-2.2-a`,
  so caller-stamped and definition-derived words are equal **by construction** rather than by two
  mirrored implementations agreeing.
- 🚨 **SEQUENCING, and it is not optional (DERIVED from `keyForSite`'s header, `:17961-17967`):**
  *"the typechecker stamps this word into the caller's dict cell and the emitter derives the impl's
  own from `declRouteKey`, so the two must agree word for word."* **`b1` and `e` land in ONE bite,
  or in two bites the sub-orchestrator commits back-to-back with no build published between them.**
  A skew is **silent on the direct-call path and live on the `RDict` path** — the tree says so at
  `:17966-17967`.
- **could move:** every emitted impl symbol name ⇒ **the seed and the IR-text golden**
  (`diff_compiler_llvm_typed_ir`). **Not acceptance.** ⚠️ **An implementer who reports
  "byte-identical" on `b1`/`e` has not exercised the change.** Per §5 of the sprint doc the
  fixpoint and a **twice-run** `refresh_seed.sh` are in-band here.
- **nearest miss:** a **headless** impl (`impl C a`, registered under `noneHeadTag` —
  `typecheck.mdk:17945-17952`, `core_ir_lower.mdk:1301`, `eval.mdk:2000`). If the new word
  collapses headless impls of **two** interfaces onto one spelling, the general-instance fallback
  tier picks by declaration order **and it is silent.** Carrying `ifaceIdentity` is what prevents
  it — which is the same substitution #1182 needs, tested at a different shape.
- **engines:** LLVM · wasm · eval · `core_ir_lower` (+ `core_ir_eval`'s own `VTypedImpl` producer
  at `:453-455`, RUN-B-013 — **P0-B's `B2.2-e` omitted it; that omission is the P0-9 shape**).
  **This bite is the seam with Phase 5.**
- **sizing:** ✅ statable — nine named sites, one derivation.

### `B-2.2-f` — mark appended super slots so identity can be WITHHELD

See §6 for the derivation; the bite is stated there (§6.3) because its shape depends on it.

---

## 6. The supers boundary and the `expandSupersTable` fill bite

### 6.1 Is the boundary still destroyed after `B-3-b`'s rewrite? **YES — in every table. DERIVED.**

Read `expandSupersTable:9131-9136 @604278bb` (post-`B-3-b`): its whole body is
`setFunConstraintTables (expandSupersCross allDecls <ids> <ifaces>)`. `expandSupersCross:9140-9145`
is pure and returns the **pair**; `expandSupersEntry:9147-9152` returns `(fn, map (s => s.csId)
pairs)` and `expandSupersIfaceEntry:9154-9158` returns `(fn, map (s => s.csIface) pairs)`.
`expandSupersPairs:9178-9179` = `expandSupersFix allDecls declared declared`, whose result is
`declared ++ appended` **deduped** (`dedupSlots:9253-9254` → `dedupBy`, which keeps the **first**
occurrence — `compiler/support/util.mdk:124-130` — so a declared slot always beats an appended
duplicate).

**Two derived facts that make the boundary genuinely unrecoverable downstream:**

1. **No stored table holds a declared-only slot list after the finalization point.**
   `expandSupersTable` is called at exactly two sites — `:14222` (Flat) and `:20732` (Module) —
   and **every table a consumer could ask is written from the post-expansion value**:
   `funConstraintsRef`/`funConstraintIfacesRef` via `setFunConstraintTables:9094-9096`;
   `crossModuleFunConstraintsRef` at `:20733`; `crossModuleFunConstraintsQualRef` at `:20735`
   (`attributeModuleArities mid prog perRun…funConstraintsRef.value`, on the line *after* the
   expansion). So `declaredConstraintSlots:8862` / `declaredConstraintIds:8826` — the only
   functions that *sound* like they answer this — return **expanded** slots on both their arms
   after `:20732`.
2. **`listLen declared` is NOT the boundary either**, so a caller cannot recompute it: `dedupSlots`
   can shorten the declared prefix, and `pairSlots:5607-5611` **truncates** to the shorter of the
   id/iface lists (its own documented policy). The count must be **recorded**, never recomputed —
   P0-B's instinct was right and its reason was incomplete.

**What `B-3-b` DID change, and it helps:** before it, the two table-writing expansion paths wrote
the two refs independently; now there is **one pure function** and **one write op per pair**, with
a documented fusion prohibition (`setFunConstraintTables:9082-9096`: *"a 'write both members
simultaneously' fusion is FORBIDDEN … expanding ids against an ALREADY-expanded iface list appends
every super slot a SECOND time and changes dict ARITY"*). So a third parallel member would inherit
that discipline **by type** rather than by statement order. **The fill bite's table-side site list
shrank; the defect did not change.**

**What `B-3-b` did NOT touch — and this is why a table-carried boundary is the wrong design:**
there are **two more expansion sites that never go through the table at all**, and they are where
the surviving route fills get their slots:
- `inferDictAtFound:8919` — `let expanded = expandSupersPairs driverState.value.superDeclsRef.value
  slots`, then `pushDictApp (routesRef, monos, map (s => s.csIface.irName) expanded, …)` at
  `:8925`. This is the payload `resolveDictApps:18990-18996` hands to
  `routesOfMonosTopV`/`topRouteV` — **the iface-aware super fill.**
- `shadowStandaloneDictSlots:12111` — the same `expandSupersPairs` call, returning
  `(monos, map (sl => sl.csIface.irName) expanded)`.
Both flatten the slot to a **spelling** deliberately (their own comments: *"the ROUTE half stays a
SPELLING … route words, not identities"*) — which is precisely the sentence `B-2.2` falsifies.

### 6.2 So: is P0-B's *"the tree destroys the boundary"* still true? **Yes for tables, NO for slots — and that is the cheaper fix.**

**Appended slots have exactly ONE mint site in the tree:** `superSlotOf:9209-9217`, whose body is a
single `CSlot { csIface = …, csId = … }` construction. Declared slots are minted at
`pairSlots:5611` and two registration sites (`:24452`, `:25477`). `grep -n "CSlot {"` → **4
construction sites, all in `typecheck.mdk`**, and `grep -rln CSlot --include=*.mdk` → **that file
only**. So:

> **Add `csDeclared : Bool` to `CSlot` (`:5594`). `superSlotOf` mints `False`; the three declared
> minters mint `True`. `dedupSlots` keeps the first occurrence, so a slot that is both declared and
> a super stays `True` — which is the correct answer (it has a declared slot to be identity-stamped
> at).**

That expresses INVARIANT (a-i) — *identity only on declared slots* — with:
- **no new `PerRun`/`CrossRun` Ref** ⇒ **no `test/registry_keying_ratchet.sh` allowlist row.**
  (Its check 1 gates new **CrossRun + DriverState fields** and check 2 gates `setRef
  crossRun.value.*`/`driverState.value.*` writers by target field — `test/registry_keying_ratchet.sh:32-47`.
  A cross-module boundary table would trip **both**.)
- **no widening of `funConstraintsRef`'s payload** ⇒ the ~20 non-comment `funConstraintsRef` sites
  (`grep -n funConstraintsRef`, comments dropped → 20, incl. `scopeArities:28386`,
  `aliasConstraintEntries:28418`, `attributeModuleArities:20735`, `promotedConstraints:14335`) are
  untouched. **This is the change P0-B's "record it at the mutation point" would have cost.**
- `data CSlot = CSlot { csIface : IfaceRef, csId : Int }` is a **single-line header**, so #829's
  record-comment corruption trigger (the two-line `data X =` / `| X {` shape) does **not** apply —
  a commented field addition here is measured-safe per `AGENTS.md`. **Check the shape again before
  editing; do not trust this sentence.**

**The one path the flag does not reach, and why it does not need to:** `recRoutes:19522` reads the
table's `List Int` (`realizeRecDictApps:19517`, `lookupAssocSL2 callee …funConstraintsRef`), so it
sees ids with no flag. Its stamp is **D9** (`resolveRecMono:19538`) — already slated to be
**re-based onto the selector or demoted to `RNone`** (§4, and now Phase 2′'s). **If D9 demotes to
`RNone`, the recursive fill path stamps no identity at all and the boundary requirement there is
discharged by construction.** If instead D9 is re-based, `recRoutes` needs the flag and the table
*does* need a third member — **so the D9 ruling determines `B-2.2-f`'s cost, and that dependency
is the reason `d` must land before `f`.**

### 6.3 `B-2.2-f` — the bite

- **sites:** `data CSlot:5594` · `pairSlots:5611` · `superSlotOf:9209-9217` (the `False` mint) ·
  `:24452` · `:25477` (the two other declared mints) · the two identity gates in `B-2.2-b1`'s
  arms that consult the flag · `inferDictAtFound:8925`'s `pushDictApp` payload and
  `shadowStandaloneDictSlots:12111-12114`'s returned pair **iff** either is to carry the flag
  onward (they map over `expanded` locally, so it is one `map` each).
- **transform:** mark appended-ness at birth; gate identity-stamping on it.
- **could move:** **nothing behavioural while the flag is read only by the stamping gate.** ⚠️ It
  must be minted at the slot's **birth**, not derived later — §6.1 item 2 is why.
- **nearest miss:** the **#1127** shape — sub goal `C (List Int)` with one impl, super goal
  `D (List Int)` with two (`D (List a)`, `D (List Int)`). Under ruling (a) that program **still
  mis-dispatches**: legs 1–2 are B-1's, and leg 2 is structural — `activeDictVars` is keyed by
  **tyvar id alone** and `expandSupersFix`/`superSlotOf` give the appended slot the **same id** as
  its sub slot (`superSlotsOf:9200-9204`: `zipL typarams (replicate … s.csId)`), so the **`assum`**
  rung cannot tell the two slots apart no matter what the route says. **The fixture belongs in
  `test/must_fail_fixtures/` asserting it STILL REPRODUCES — not a captured value golden, which
  would enshrine the wrong winner.** **#1127 is NOT drained by this sprint; a claim otherwise is
  wrong.**
- **engines:** none directly. It **constrains what `B-2.2-b1` may stamp**.
- **sizing:** ✅ statable — 5 mint/decl sites + 2 gates + at most 2 payload `map`s. ⚠️ Its cost
  becomes ❌ *"not yet statable"* if D9 is **re-based** rather than demoted, because then the
  boundary must also traverse `funConstraintsRef` (a third table member, a `setFunConstraintTables`
  signature change, and — for the cross-module twin — **two ratchet allowlist rows**). **Order: `d`
  (the D9 ruling) → `f` → `b1`.**

---

## 7. Sizing summary

| bite | statable as "apply this transform to these N named sites"? |
|---|---|
| `B-2.2-a` | ✅ 2 sites + a compiler-enumerated error set |
| `B-2.2-b1` | ✅ 4 sites — **conditional on §5's row-returning selector.** ❌ without it |
| `B-2.2-b2` | ✅ 2 named pairs |
| `B-2.2-c` | ✅ 5 sites, comment-only |
| `B-2.2-e` | ✅ 9 sites — **must land with `b1`** |
| `B-2.2-f` | ✅ ~7-9 sites **if D9 demotes**; ❌ (re-cut needed) if D9 re-bases |
| `B-2.2-d`, `d′` | **moved to Phase 2′** (§1) — not sized here |

**What is missing rather than cut:** nothing new, but two dependencies are hard and named — §5's
selector return type (Phase 2′ owes it) and §6.3's D9 ordering.

---

## 8. Refusals and disagreements (reported, not resolved)

1. **REFUSED to keep `B2.2-d`/`d′` in Phase 3′.** They are selection/population work, complete with
   a `String` payload, and RUN-B-024's Phase 2′ list does not contain them. Left in 3′ *after* `a`
   they would force a stamping decision under a simultaneous type change. **Orchestrator's call,
   with my recommendation and the cost of each option stated (§1).**
2. **REFUSED to restate P0-B's §2.2 selector-site-count property.** It is **false at `604278bb`** —
   there are two selector calls per `inst` arm — and stating it would license a D5/D6 collapse that
   changes which impl's context is discharged. Replacement property given (§3.3).
3. **CORRECTED P0-B §3's site list**, agreeing with RUN-B-023: `argReqRoute` performs **no
   selection**; it is a `routeOfD` → `entail EKNestedTop` adapter, so D4 is the recursion hub.
4. **CORRECTED P0-B §7.3's fill-path table:** `routesOfMonos` carries **method-level** constraints
   (only caller `resolveMethodDicts:19506`), which `expandSupersTable` never expands — so it is
   iface-blind but **not** a super-slot fill. **One** iface-blind path carries super slots
   (`recRoutes`/`recRoute`/`resolveRecMono`), not two.
5. **CORRECTED a count in P0-B §2:** *"exactly 7 `RKey` hits, 5 construct + 2 destructure"* does not
   reproduce at `604278bb` **or at BASE** — 8 hits, **6 construct**, 2 destructure. Its own D-table
   names all six, so the prose undercounted itself. Nothing turns on it; the site set is complete.
6. **DISAGREED with P0-B's `B2.2-f` shape** (record a declared **count** at the mutation point) and
   replaced it with a per-slot flag minted at birth. Reason: a count is unrecoverable from
   `listLen declared` (dedup + `pairSlots` truncation, §6.1 item 2) *and* a table-carried count
   costs a `funConstraintsRef` payload widening (~20 sites) plus two ratchet allowlist rows for the
   cross-module twin. The flag costs 4 mint sites in one file.
7. **P0-B's `B2.2-e` engine list omitted `core_ir_eval`'s own `VTypedImpl` producer** (RUN-B-013
   found the same omission in P0-C's `a`/`d`). Added. That omission is the P0-9 shape.
8. **NOTHING HERE IS MEASURED.** No binary was run, by instruction. In particular
   `keyForSite`'s neighbouring warning (`:17953-17959`) that behaviour surviving this IR change is
   *"EMPIRICAL, not structural"* and rests on the `noneHeadTag` fallback tier is the **tree's own**
   warning, RELAYED — and it is exactly what `B-2.2-b1`'s implementer must re-derive on a build.
9. **A premise in my brief I could not confirm and am not asserting:** the brief says `B-2.1-a2`'s
   unified substrate is what *"simplifies"* P0-B's design. It does — but only in the two specific
   ways at §2. It does **not** remove the Flat/Module asymmetry from `stampKeyTable:28682` /
   `keyTable:14123`, which Phase 2′ still owns. Reading `a2` as having already unified the
   *stamping* population would be the same error RUN-B-023 corrected on the reader side.
