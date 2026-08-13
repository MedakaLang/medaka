# P-3′ — Phase 3′ packet: **VERDICT = DO NOT DISPATCH TONIGHT.** Close Phase 2′, re-cut Phase 3′ in a fresh run.

**Agent:** P-3′, packet prep, Stage B sprint. **STRICTLY READ-ONLY.** Nothing built, no gate,
no probe, no `./medaka`. Every source claim is cited `file:line @6ec0111a` and was read via
`git show 6ec0111a:<path>` into `/var/tmp/p3_*`; the working tree was never read (`EX-3` is live
in `compiler/types/typecheck.mdk` and the golden trees).
⚠️ **The brief's pin spelling `6ee0111a` is a typo.** `HEAD` and the real pin are **`6ec0111a`**
(`sprint-b EX-2: fixpoint GREEN on a twice-refreshed seed`). All lines below are against that.

---

## 1. 🛑 THE VERDICT: STOP. Four reasons, in descending durability.

**Reason 1 — the durable one, and it does not expire when `EX-3` finishes: Phase 3′'s
Phase-2′ precondition was never discharged.** D1 §1 moved `B-2.2-d` (D8/D9) and `B-2.2-d′` into
Phase 2′ and the ruling was **GRANTED** (`DECISIONS.md:1869`). **It was never taken.** Verified at
the pin, both sites still stamp a bare tag with no selector in the path:

- **D8** `routeUndeterminedTop:19836-19848` → `[tag] => RKey tag (argImplRequiresRoutes …)` at
  `:19847`; still decides by `implHeadTagsForIface prog iface` (`:19858-19861`, `dedup (flatMap …)`)
  — a **dedup'd COUNT over `prog`, not `IE`**.
- **D9** `resolveRecMono:20106-20108` → `Some tag => RKey tag []`.

`grep -n '^### `B-2' .claude/sprint-b/DEBT.md` returns rows for `a2 a3 a4 b1(REFUSED) b2 c(REFUSED)
f g d(EX-1)` — **no `d`/`d′` row exists.** By D1 §1's own blocker, `B-2.2-b1` cannot stamp identity
while two sites in its own region mint `RKey` with no selector: the stamp there is a **FABRICATED
identity**, which is the S0 D1 §4 was written to prevent. **Phase 3′'s first bite is therefore not
`a` and not `b1` — it is a ruling Phase 2′ owes and did not deliver.** That is a re-cut, not a
packet.

**Reason 2 — every Phase 3′ bite invalidates `EX-3`'s re-cut, including the comment-only one.**
`B-2.2-a` changes `RKey`'s field type (`ast.mdk:722-728 @6ec0111a`, `RKey String (List Route)`) ⇒
emitted IR moves ⇒ seed re-mint ×2 + in-band fixpoint again, discarding `EX-2`'s certified fixpoint.
`B-2.2-c` is comment-only **in `compiler/types/typecheck.mdk`**, which is in the snapshot corpus and
in the `selfproc_legA` corpus — so even it moves a golden `EX-3` is blessing right now. There is no
Phase 3′ bite that is safe against a live golden re-cut.

**Reason 3 — region collision.** §4's region discipline: *"an implementer whose region has already
changed under it STOPS."* Every 3′ bite's region is `typecheck.mdk` (D3–D6, the ladder, `CSlot`) or
`ast.mdk`+`typecheck.mdk`. `EX-3` is the live writer. Dispatching now manufactures the exact stop
the protocol is designed to make loud.

**Reason 4 — the queued plan does not say Phase 3′ next.** `HANDOFF.md`'s h-exit table:
`EX-1 → EX-2 → EX-3 → EX-4` (un-safe `HANDOFF.md` by **re-showing** `SA-4c`/#1514/#1397 on the
final binary). **`EX-4` is the next step, not Phase 3′.** Phase 2′'s exit criterion is a re-shown
drain on the *final* binary; a 3′ bite lands before that evidence exists.

> **Recommendation: let `EX-3` finish, run `EX-4`, close Phase 2′, and give Phase 3′ a fresh design
> run whose FIRST work item is the D8/D9 ruling.** No Phase 3′ bite is dispatchable tonight, and
> the reason is not merely scheduling.

---

## 2. The `Option ImplRow` question — **answered: the precondition is MET in substance, NOT in D1's literal form.**

**D1 §5 said:** *"Phase 2′'s `B-2.1-b2` must leave the unified selector returning the ROW
(`Option ImplRow`), not a projected `String`. If 2′ lands with a `String`-returning selector,
`B-2.2-b1` is not statable and 3′ stops."*

**At the pin, both halves are true at different layers — and the good half is the load-bearing one:**

| binding `@6ec0111a` | signature | verdict |
|---|---|---|
| `ieSelectRowByMethod:19002` | `ImplEnv -> String -> List Mono -> Option ImplRow` | ✅ **row-returning, exposed, takes `env` explicitly** |
| `ieSelectRowByIface:18994` | `ImplEnv -> String -> List Mono -> Option ImplRow` | ✅ same |
| `keyForSite:18383` | `String -> List Mono -> Option String` | ⚠️ **still projects to a `String`** |
| `keyForSiteByIface:19062` | `String -> List Mono -> Option String` | ⚠️ same |

**So `B-2.2-b1` IS statable, and cheaper than D1 priced it.** `keyForSite` is a 6-line pure
projection (`:18384-18409`: read `perRun.value.bodyImplEnvRef.value`, call `ieSelectRowByMethod`,
then either `implKeyTc ir.irName tys` or `headKeyNameOr noneHeadTag`). The stamping arms do not need
`keyForSite` re-signatured and do **not** need a second scan: they call `ieSelectRowByMethod` /
`ieSelectRowByIface` directly and project the word themselves. **RUN-B-023's +17% `check-self`
second-scan cost that D1 made the precondition's justification therefore does not apply** — the row
is one call away on the same substrate. `ImplRow`'s 2nd field is still the `InstRef`
(`data ImplRow:4067`, `ieRowInst:4073-4074`, `data InstRef:4005`), so identity is on the row as D1
§2 derived.
⚠️ **This is a REFRESH of D1 §5, not a confirmation of it.** An implementer handed D1 verbatim would
read `keyForSite : … -> Option String` and conclude 3′ stops. It does not stop *for that reason*.

---

## 3. D1's bite list, re-verified at the pin

**All D1 line numbers in the 19xxx region moved by ~+530 and `CSlot`/`superSlotOf` by ~+250.
Nothing was deleted, nothing added.** `RKey` grep, comments dropped: **6 construct
(`15721 19673 19701 19720 19847 20108`) + 2 destructure (`20234 20401`) = 8** — exactly D1 §3.2's
corrected figures, and its refusal #5 (P0-B's "7 hits / 5 construct") stands.

| D1 bite | status at `6ec0111a` | note |
|---|---|---|
| `B-2.2-a` payload → identity-bearing | **SURVIVES, unchanged.** `data Route` at `ast.mdk:722-728` is byte-identical to D1's reading | still the phase's opener *after* the D8/D9 ruling |
| `B-2.2-b1` stamp at the 4 `inst` arms | **SURVIVES and is CHEAPER** (§2) — but **BLOCKED** on the undischarged D8/D9 ruling | sites moved: D3 `19669-19675`, D4 `19698-19703`, D5 `19712-19722`, D6 `19723-19724` → `stampOpRouteVal:15702-15721` |
| `B-2.2-b2` collapse the double selection at D3/D4 only | **SURVIVES; its claim is now PROVABLE rather than argued** | `g` moved the element routes onto the SAME substrate: D3's element `implDictRoutesForFull:19352` calls `ieSelectRowByMethod …bodyImplEnvRef… name paramMonos` — **literally the same function on the same arguments** as the primary. D4's element `selectReqImpl:19981` calls `ieSelectRowByIface …bodyImplEnvRef… iface goals`. So `b2`'s byte-identical bar is genuine |
| `B-2.2-b2`'s **D5/D6 exclusion** | **STILL CORRECT — re-derived, not relayed** | `argImplDictRoutesForEncl:20038` selects on the `name` its caller passes, and D5 passes `dictName = name` **or** `innerDefaultMethod name` (`:19715-19718`); D6 the same via `dictMethod` (`:15716-15719`). Collapsing there is still a semantics change |
| `B-2.2-c` precedence assertions | **SURVIVES, comment-only** | ladder `entail:19613-19614`, `entailAssum:19628`, `entailAssumVar:19640-19645`, `entailAssumRoute:19647-19655`, `entailFallback:19726-19731`. Its restated reachability property is still the right one — the two-selector-calls-per-arm shape D1 refused P0-B over is still present |
| `B-2.2-e` definition-side key derivation | **NOT RE-VERIFIED.** ⚠️ `OWED:` its nine sites are in `core_ir_lower.mdk` / `eval.mdk` / `typecheck.mdk`; I read only `typecheck.mdk` + `ast.mdk` inside budget. `git show 6ec0111a:compiler/ir/core_ir_lower.mdk \| grep -n 'declRouteKey\|ifaceRouteKeysGo\|ifaceDeclHeadUnique\|ifaceImplHeadEntries'` and the `eval.mdk` peers | `implKeyTc` **is** present and is the mint `keyForSite:18391` uses |
| `B-2.2-f` `csDeclared` on `CSlot` | **SURVIVES; D1's measurement re-confirmed exactly** — §4 below | |
| `B-2.2-d` / `d′` | **NOT MOVED, NOT LANDED, NOT SUPERSEDED.** Now Phase 3′'s blocker (§1) | |

**Already done by `g`/`EX-1`, so 3′ must not re-derive:** the primary route word's population (both
`keyForSite*` read `bodyImplEnvRef`); all three existence reads; `resolveRLocalSite`'s selection leg;
the element routes at D3/D4/D5 (all now `ieSelectRow*` over `bodyImplEnvRef`); the whole prefix-table
read side (13 bindings deleted).
**Nothing in D1 is UNSTATABLE.** The only unstatable thing is Phase 3′'s *start*, because its first
bite is a ruling nobody has taken.

---

## 4. 🚨 The discharge-kind table — re-verified. **Zero drift. Every site exists; none moved category.**

| D1 # | kind | D1 line | **`@6ec0111a`** | handling verdict |
|---|---|---|---|---|
| **D1** | `assum`, tyvar-keyed | 19081-19096 | `entailAssumVar:19640-19645` → `entailAssumRoute:19647-19655` | **NEVER STAMP** — confirmed; four `RDict`/`RDictFwd` arms, no `RKey` |
| **D2** | `assum`, predicate given | 19069-19073 | `entailAssum:19628-19629` (2nd arm) | **NEVER STAMP** — confirmed |
| **D3** | `inst` return | 19110-19116 | `entailInst … EKReturn:19669-19675`, `RKey` at **`19673`** | **STAMP** |
| **D4** | `inst` nested/top (recursion hub) | 19139-19144 | `:19698-19703`, `RKey` at **`19701`** | **STAMP** |
| **D5** | `inst` argument | 19153-19163 | `:19712-19722`, `RKey` at **`19720`** | **STAMP primary only** |
| **D6** | `inst` operator | →`stampOpRouteVal:15374-15393` | `:19723-19724` → `stampOpRouteVal:15702-15721`, `RKey` at **`15721`** | **STAMP primary only** |
| **D7** | `super` | no site; flattened | `expandSupersTable:9382-9383` — **still no `super` rung** in `entail:19613-19614` | **NEVER STAMP** (withhold on appended slots) — confirmed; re-routing through `inst` is #203's class |
| **D8** | undetermined-by-COUNT | `:19288` | `routeUndeterminedTop:19836-19848`, `RKey` at **`19847`**; count via `implHeadTagsForIface:19858-19861` `dedup (flatMap …)`, over **`prog`** | **RULE FIRST — STILL UNRULED (§1)** |
| **D9** | recursive-call route | `:19538` | `resolveRecMono:20106-20108`, `RKey` at **`20108`** (`Some tag => RKey tag []`); sibling arm still `RDict (dictParamName encl slot)` | **RULE FIRST — STILL UNRULED (§1)** |
| **D12** | `entailFallback`'s `RNone` arms | 19168-19172 | `entailFallback:19726-19731` — three `RNone` arms + the `EKNestedTop` `undeterminedRoute` arm | **UNCHANGED** |
| **D1-leak** | rigid in-scope goal falling through to `inst` | 19055-19059 | `entail:19613-19614`'s `None =>` fall-through | **3′ MUST NOT WIDEN; cannot fix** — #1127 legs 1–2 are B-1's |

**D3e–D6e sub-discharges:** all present — `implDictRoutesForFull:19342/19352`,
`argImplRequiresRoutes:19946`, `selectReqImpl:19978`, `argImplDictRoutesFor:20000`,
`argImplDictRoutesForEncl:20034`, `argImplReqRoutes:20047`, `argReqRoute:20051-20057`.
**D1 §3.1's correction still holds:** `argReqRoute` selects nothing — it is a `routeOfD:19749`
adapter, and `routeOfD` calls `entail … EKNestedTop`, so **D4 remains the recursion hub** and a `b1`
implementer's `nearest miss:` must be nesting-depth ≥2.
**One genuine refresh to D1 §4/§3.3:** the element helpers now select over `bodyImplEnvRef` (not the
prefix table) while `keyTable` is *still threaded through them* for the nested-`requires`
re-bucketing (`implDictRoutesForFull:19342`'s own header says so). So a 3′ implementer must not read
a live `keyTable` parameter as "the element route still reads the old population" — it does not.

---

## 5. `csDeclared : Bool` on `CSlot` — **D1's measurement re-confirmed, both halves.**

- **Header shape:** `data CSlot = CSlot { csIface : IfaceRef, csId : Int }` — **`typecheck.mdk:5843`,
  SINGLE LINE.** ⇒ #829's two-line `data X =` / `| X {` corruption trigger does **not** apply. A
  commented field addition here is in the measured-safe class (`AGENTS.md`). ⚠️ Re-check the shape on
  the day; do not trust this line.
- **Mint count: FOUR construction sites, one file** — `grep -n 'CSlot {'` → **`5860`**
  (`pairSlots`, declared) · **`9463`** (`superSlotOf:9459-9460`, **the appended mint ⇒ `False`**) ·
  **`25049`** · **`26089`** (a `map (id => CSlot {…})` inside `setFunConstraintEntry`, declared).
  `grep -rln CSlot --include=*.mdk` scope: **`typecheck.mdk` only** — I re-ran it at the pin.
  ⇒ **`B-3-a`'s reuse of `CSlot` added no mint site and did not change the header.** D1 §6.2's
  "4 construction sites, all in `typecheck.mdk`" reproduces exactly (its line numbers `5611/9209/
  24452/25477` → `5860/9463/25049/26089`).
- **Unchanged:** no new `PerRun`/`CrossRun` Ref ⇒ no `test/registry_keying_ratchet.sh` allowlist
  row; no `funConstraintsRef` payload widening.
- ⚠️ **`B-2.2-f`'s cost is STILL undetermined**, and for D1's stated reason: §6.3's *"❌ not yet
  statable if D9 **re-bases** rather than demotes."* D9 is unruled (§1). **`f` is not sizable until
  the D8/D9 ruling lands.** Order stands: **D8/D9 ruling → `f` → `b1`+`e`.**

---

## 6. Anything not derivable read-only

- ⚠️ `OWED:` `B-2.2-e`'s nine sites outside `typecheck.mdk`/`ast.mdk` (§3 row) —
  `git show 6ec0111a:compiler/ir/core_ir_lower.mdk | grep -n 'declRouteKey\|ifaceRouteKeysGo\|ifaceDeclHeadUnique\|ifaceImplHeadEntries'`
  and `git show 6ec0111a:compiler/eval/eval.mdk | grep -n 'implMethodEntry\|declImplIfaceIdRow\|implKeyOf'`.
- ⚠️ `OWED:` whether `CSlot:26089`'s inferred-id mint is semantically "declared". D1 ruled all three
  non-`superSlotOf` mints `True`; I confirmed the *sites*, not the ruling.
- ⚠️ `OWED:` the `noneHeadTag` general-fallback tier `b1` rests on (`llvm_emit.mdk`, `eval.mdk`) —
  the tree's own warning calls it *"EMPIRICAL, not structural"*. **Requires a build. Not doable
  tonight and not doable read-only.**
- **REFUSED:** to write a dispatchable first bite. Per §1 the first work item is a ruling, not a
  transform, and stating a bite would present an undischarged precondition as satisfied. Per the
  brief's own bound: **Phase 3′ needs a design run, not a packet.**
- **No count in this file is quoted from another document.** Every one carries the command that
  produced it, run at the pin.
