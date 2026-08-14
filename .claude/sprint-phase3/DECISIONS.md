# Stage B / Phase 3′ (`B-2.2`) — DECISIONS

Append-only. The orchestrator is the single writer. Every entry carries its **derivation**, not
just its conclusion. Contract: `.claude/STAGE-B-PHASE3-SPRINT.md`; inherited protocol:
`.claude/STAGE-B-SPRINT.md` §3–§7.

**Branch:** `arch/stage-b-phase3-b22`. **BASE pin:** `68f84bf1` (`main`, 2026-08-14).

---

## RUN-P3-001 — sprint opened; branch and pin

- `BASE=68f84bf1458681b2599e73f039a592a32de3183a`, branch `arch/stage-b-phase3-b22` cut from it.
- Records live here (`.claude/sprint-phase3/`), never in `.claude/sprint-b/` (frozen, cited by the
  Stage B PR) — audit template delta 5.
- Trunk worktree: `/root/medaka/.claude/worktrees/expressive-prancing-minsky`. Binary cold-built
  from `compiler/seed/emitter.ll.gz` (no emitter borrowed — the borrow path re-runs stages A and B
  anyway and can cost an isolated agent its session). Smoke: `MEDAKA_STRICT=1 ./medaka run` on a
  `println` probe → `12345`, exit 0.

## RUN-P3-002 — sole-occupancy check (§9 delta), DERIVED

`git worktree list` shows two live sibling sprints. Neither touches this unit's owned set
(`compiler/types/typecheck.mdk`, `compiler/frontend/ast.mdk`, `compiler/ir/core_ir_lower.mdk`,
`compiler/eval/eval.mdk`):

- `sprint/1398-h2b6-wtrmc` and `sprint/1398-h2b7-lambda-v2` (opencode emitter sprint #1398):
  `git diff --stat main...<branch>` → `compiler/backend/wasm_emit.mdk` ·
  `compiler/entries/wasm_emit_typed_main.mdk` · `test/wasm/diff_wasm_typed.sh` **only**.

⚠️ **Coordination item, not a collision.** `B-2.2-a` changes `RKey`'s field type, and the
compiler-enumerated error set that follows **reaches `wasm_emit.mdk` and `llvm_emit.mdk` as
consumers** — files §9 explicitly says this unit does NOT own (they are Phase 5's). The resolution
is: touch them **only** as far as the type change forces (make the tree compile carrying today's
word); no word-set or superset-OR work there. A mechanical conflict with #1398's `wasm_emit.mdk`
diff is possible at merge; it is a rebase cost, not a semantic one.

## RUN-P3-003 — Q2 answered (P0-2, read-only, DERIVED at `68f84bf1`)

**All nine `B-2.2-e` sites survive unchanged in SHAPE**; only line numbers moved (~+400–520 in
`typecheck.mdk`, less elsewhere). `core_ir_eval.mdk:453-455`'s `VTypedImpl` producer — the arm D1
flagged as historically omitted (the P0-9 shape) — **is present** and mirrors `eval.mdk`'s
`implMethodEntry`; it carries `(tag, key)` through `CImplTagged` and **never re-derives the key**.

**The identity-drop mechanism is confirmed, and D1's wording undersells it.** At
`core_ir_lower.mdk:1301` (`ifaceImplHeadEntries`) and `eval.mdk:305` (`declImplIfaceIdRow`),
`ifaceIdentity o ifaceName` **is** computed — and *retained one tuple slot over*, for a documented
sibling purpose (#1047 default-body qualification / `ifaceIdsAtTag`). It is the **key mint** that
never sees it: `implKeyOf`/`implKeyTc` take a bare `String` iface and the word begins with the bare
name by construction. So identity is not "lost" — it is **present and unthreaded**, which is
the **#1047/#1265** route-word residual's mechanism (citable ticket: **#1113**) and makes `e`'s
substitution local rather than a plumbing job.
⚠️ **CORRECTED (RUN-P3-036).** This sentence originally said *"#1182's mechanism"* and is the
**earliest instance** of a nine-place propagation. #1182's mechanism is stated in its own issue body:
*"`matchingEntries` selects candidates by method-name membership, not by interface."* That selection
never consults the route word.

### 🚨 FINDING — D1's nine-site list is INCOMPLETE, and the two extra sites are in files §9 says we do NOT own

1. **`compiler/backend/llvm_emit.mdk:1486-1492` — `implEntryRouteKey`**: a **second, module-scoped**
   route-key decision, deliberately not the same population as `declRouteKey`. Its own comment
   (`:1480-1485`) says the emitter *cannot* recompute typecheck's global verdict because that
   verdict is a property of **the site's module** — the same impl may legitimately be stamped `"Box"`
   by one module and `"Speak|(Box Int)|"` by another. Its sibling `implEntryRouteWords:1512-1518`
   **unions** the key with the bare tag `t` so that `RDict` acceptance cannot bet on one word —
   which is the direct mechanism behind the tree's *"silent on the direct-call path, live on the
   `RDict` path"* warning. A third local decision follows at `:5225`/`:5239`
   (`ifaceTags`→`declTagOrKey`).
2. **`compiler/backend/wasm_emit.mdk:4092-4094`** — a *locally-named* `implKeyOf` (name collision
   with eval's; a different function) that extracts the already-stamped key, plus an independently
   written uniqueness family (`headTagUniqueW`, `distinctKeysAtHeadW`, `headTagForKeyW`,
   `methodImplKey`, `findByTagW`). **`ifaceImplRouteKeys`/`ifaceDeclHeadUnique` have ZERO hits in
   `wasm_emit.mdk`** — wasm does not consume the shared decl-level table LLVM uses.

**Orchestrator ruling (RULED, not deferred):** `B-2.2-e`'s bite stays scoped to the nine sites, i.e.
to the **mint**. The two extra sites are **consumers of the minted word, not producers of it**, and
`implEntryRouteWords`' superset-OR is explicitly **Phase 5's deletion** (D1 §1: those ORs are
deletable only *after* `B-2.2-a/b/e`). Touching them here would be doing Phase 5 inside Phase 3′.
**But they are now named**, which changes two things this sprint owns:

- `e`'s `engines:` row must state that LLVM's `implEntryRouteKey`/`implEntryRouteWords` and wasm's
  independent family are **owed peers**, not silent.
- The repair round's engine leg must check the mint against **both** consumers, since a word that
  changes shape can be accepted by the union arm while the direct arm diverges — precisely the
  channel that hides a skew.

⚠️ Relayed onward as a standing arc risk (not this sprint's to fix): if wasm truly has no consumer
of the shared table, wasm's method-less-impl default-dispatch coverage rests entirely on a
separately-maintained parallel family — a lockstep hazard of the `evalModules`/`cevalModules` kind.

## RUN-P3-004 — the refresh: **GO on shape** (P0-1, DERIVED at `68f84bf1`)

**The RKey site set is 6 construct + 2 destructure, at byte-identical line numbers to the relay**
(`15726 · 19720 · 19748 · 19773 · 19900 · 20161` construct; `20287 · 20454` destructure). Zero
drift. **No stop-the-sprint condition.** Also confirmed first-hand, not relayed:

- **Categories unchanged:** 4 selecting arms (D3/D4/D5/D6, each with `keyForSite*` in the path) and
  2 selector-free (D8 `implHeadTagsForIface … prog`, D9 `headTyconNameMono`). **AD-1's premise
  stands unfalsified.**
- **`data Route` unchanged** — 6 constructors, `RKey`'s first field still `String`
  (`ast.mdk:722-728`).
- **`ieSelectRowByIface` / `ieSelectRowByMethod` both `ImplEnv -> String -> List Mono -> Option
  ImplRow`** (`:19041`, `:19049`). D1 §5's precondition — the one it said 3′ *stops* without — **is
  met.** Identity is reachable with no new plumbing: `ImplRow`'s 2nd field is `InstRef`, accessor
  `ieRowInst:4073`. `keyForSite` currently destructures it and throws it away.
- **`data CSlot` is single-line** (`:5843`), so `B-2.2-f`'s commented field is in #829's
  measured-safe class. Sprint §3 item 5's *"re-check on the day"* is discharged.
- ⚠️ `:20287` **destructures and re-constructs on one line** — one line, two edits for `a`.

## RUN-P3-005 — 🚨 RULING: `B-2.2-a`'s blast radius vs §9's ownership list

> 🚨 **PARTIALLY SUPERSEDED by RUN-P3-019.** Parts 2 and 3 are **moot** — there is no payload type
> change, so no carrier and no S-expr work; and part 1's lending of the six non-owned files is **not
> exercised by `a`**. The blast-radius *derivation* (25 sites / 9 files) stands and was independently
> re-verified cell-by-cell by the referee.

**The finding (DERIVED).** `Route` is consumed **positionally, tree-wide**. Word-bounded
`grep -rn '\bRKey\b' compiler/ --include=*.mdk` (comments dropped) — an unbounded pattern also
matches `CRKey` and inflates every number below:

```
8 typecheck.mdk (owned) · 7 wasm_emit.mdk · 4 llvm_emit.mdk · 3 core_ir_sexp.mdk
3 core_ir_lower.mdk · 3 eval.mdk · 2 entries/wasm_emit_typed_main.mdk
1 core_ir_sexp_parse.mdk · 1 ast.mdk · 1 trmc_analysis.mdk
```

**25 non-typecheck sites in 9 files.** §9 gives this unit four files and says the two emitters are
Phase 5's. **As written, §9 is not satisfiable by bite `a`.** This is an architecture divergence, so
it is ruled here rather than worked around silently.

**RULED — three parts:**

1. **§9 lends bite `a` the six non-owned files for MECHANICALLY-FORCED edits only**: make the tree
   compile carrying **today's word**. No word-set change, no superset-OR touch, no re-keying. §9's
   purpose — keep Phase 5's *semantic* engine work out of Phase 3′ — survives intact; only its
   letter is amended, and the amendment is recorded so a later reader does not mistake the edits for
   Phase 5 work started early.
2. **The payload is a CARRIER TYPE on field 1, not a third positional field.** This is D1 §5's own
   wording (*"change `RKey`'s first field type … to a two-component carrier"*) and it is materially
   cheaper: a third positional field breaks **every destructure** (`RKey tag reqs` → arity 3),
   whereas a carrier leaves destructure arity alone and breaks only where the bound word is *used*
   as a `String` — a one-accessor mechanical fix per site. AD-1's constraint is satisfied either
   way (a field becoming optional, **not** a new `Route` constructor), so `SupersPath`/presumption
   (a) stays undisturbed.
3. **The S-expr channel is `a`'s owned decision, and the default is RENDER.** `core_ir_sexp.mdk:57`
   renders `RKey` (`node "RKey" [escStr k, slist …]`) and `core_ir_sexp_parse.mdk:239` parses back
   **only the no-reqs form** — so the round-trip is already incomplete and will be more so at the
   new payload. Rendering identity moves the `core_ir` S-expr goldens (fine — goldens are re-cut
   once at the close-out anyway); **NOT rendering it blinds `core_ir_typed_modules_dump_main`, the
   probe `AGENTS.md` calls the highest-value instrument for any dispatch/dict-routing question — and
   that probe is the repair round's primary instrument for this very change.** A change whose only
   observation channel cannot see it is the shape this arc keeps paying for. `a` renders identity,
   and states in `unchecked:` what the round-trip parser does or does not accept.

## RUN-P3-006 — CORRECTION to sprint §3 item 2: `keyForSite` is not a pure projection

> 🚨 **SUPERSEDED IN ITS CONSEQUENCE by RUN-P3-025.** The observation is correct — `keyForSite` runs
> a second `IE` query — but the instruction it produced (*"`b1` must carry the collision gate"*) is
> **wrong**: the gate is already inside `keyForSite*`, and `b1` changes one expression *after* it.
> **Deliberately left in place**, because the warning was sound and only its premise was not.

Sprint §3 (*"already settled — do NOT re-derive"*) calls `keyForSite` a **6-line pure projection**.
DERIVED at the pin, it is **10 non-comment lines and runs a SECOND `IE` query**: after selecting the
row it calls `ieHeadCollidesByMethod env name (univReceiverTag tys)` (`:18435`) and stamps
`implKeyTc ir.irName tys` on collision (`:18440`) versus `headKeyNameOr noneHeadTag …` otherwise
(`:18449`). `keyForSiteByIface` is the same shape via `ieHeadCollidesByIface` (`:19115`).

**Consequence for `b1`, which must go in its `transform:` row:** the cheap shape is *select once,
project `ieRowInst` for identity **and carry the collision gate on that row***. If `b1` calls
`ieSelectRowByMethod` for identity while leaving the `keyForSite` call in place, that is **three**
`IE` traversals per arm (select-for-word · collision-count · select-for-identity) — re-buying
RUN-B-023's +17% `check-self` cost that §3 item 2 was written to retire. **`b1` carries the
collision gate; it is not a projection.** The conclusion of §3 item 2 (3′ does not stop) is
unaffected; its *shape* is corrected.

## RUN-P3-007 — Q1 answered: the residue is INERT, and `B-2.2` does NOT retire it

**Census, DERIVED (the doc's `86`/`91` are RELAYED and both are miscut):** `KeyBuckets` = 86 *lines
including comments*; the **code** count is 34. `keyTable` = 91 — but that is a `\bkeyTable\b` count
and **MISSES the second binder**: the multi-module path (`elabModuleStamp:29508-29517`) names its
table **`stampKeyTable`**, 8 more code lines. **True residue = 99 lines across 2 binders.** Anyone
sizing this deletion off "91" misses the multi-module half — the half that matters. (Third instance
this arc of a relayed count whose *derivation scope* was itself an unstated encoded fact.)
`shadowKeyTableRef`/`universeKeyBucketsRef` have **zero non-comment occurrences** — `EX-1`'s
deletions are real.

**Do any of them DECIDE? NONE.** Derived by inverting the search — grep the **reader primitive**,
not the table. The only `OrdMap` read is `bucketOf` (`:18066`), with exactly three call sites
(`:18083`, `:18242`, `:19583`), and **not one is applied to a threaded `keyTable`**. Every one of
the 99 lines is a binder or an argument position; the four `EntailKind` constructors carry the field
purely to ferry it into `entailInst`, which rebinds and passes it on.

⚠️ **The in-tree comment at `implDictRoutesForFull:19397` — which sprint §4 Q1 cites as the
residue's justification — is STALE.** It claims the threading is live for the nested-`requires`
re-bucketing; following that recursion (`argImplReqRoutes` → `argReqRoute` → `routeOfD` → `entail
EKNestedTop` → `entailInst` → `argImplRequiresRoutes` → `selectReqImpl`) ends at a function that
**does not take `keyTable` at all** (`:20031`). Its own sibling at `:20025-20027` already records the
truth (*"the `KeyBuckets` parameter is REMOVED rather than ignored — it had exactly one reader, this
arm"*). That was the last reader. **`routeUndeterminedTop`'s `KeyBuckets` parameter is likewise
DEAD** — AD-1's *"never stamps"* and *"never decides"* are two independent facts and both hold.

**RULED — the deletion is OUT of Phase 3′, and this is not the default answer, it is a derived one.**
It is behaviour-free, confined to `typecheck.mdk`, and would even remove two `O(decls)` table builds
per elaborate. It is nonetheless **out**, because its 99 positions run straight through the `entail`
ladder, the four `EntailKind` constructors and `entailInst`'s arms — **the exact region four of six
bites edit.** A 99-position sweep interleaved with `b1`/`b2`/`c` is a region-collision generator, and
region collisions are what the serialize-writers rule exists to prevent. Filed as a named follow-up
carrying P0-1's derivation **and the `stampKeyTable` correction**, so Phase 5 does not size it off
the wrong count.

**Correction to `B-2.2-c`'s scope (cheap, and it is the right owner):** `c` is the comment-only
bite. It now also **corrects `:19397`'s stale comment**, since `c`'s whole job is leaving behind
sentences the next refactor cannot silently violate — and this one currently misleads in the
opposite direction.

## RUN-P3-008 — 🚨 FINDING: there IS a second surviving deciding population — `ImplBuckets`, not `KeyBuckets`

Both halves of Q1's dichotomy are true of *different things*. `KeyBuckets`/`keyTable` is 100% inert;
**`ImplBuckets`/`implTable` rides the same parameter positions and DOES decide**:

```
selectReqImpl implTable iface tag m goals                                    :20031
  | iface == "" = map (…) (findImplEntry implTable iface tag m)              :20033  ← decides over ImplBuckets
  | otherwise   = ieRowHeadTriple (ieSelectRowByIface …bodyImplEnvRef… iface goals)  :20034
```

`findImplEntry` (`:19582`) is a **first-match, head-tag-bucketed linear scan** — declaration order,
not `min⊑`/`pickMostSpecificEntry`. It is a **different population** (`buildImplTable:18071` omits
no-requires impls per the tree's own comment at `:20015`) selected by a **different rule**. And it is
**reachable**: `routesOfMonosTop*`/`routesOfMonos` call `routeOf implTable keyTable "" "" …` with
`iface = ""` (`:19848`, `:19882`, `:19934`), which threads that `""` down to this arm. `findImplEntry`
is also the sole surviving `bucketOf` reader outside the two builders.

**Not filed as a bug** — P0-1 built no discriminating program, the `iface == ""` arm is documented as
deliberate at `:20017`, and this repo does not file unreproduced claims. **Assigned to the repair
round** (Phase 3): build the discriminating program — swap two impl blocks with no other change and
see whether the answer moves (the #1154 shape) — and file only if it reproduces.

**Binding on this sprint's prose, effective now:** any sentence of the form *"the route selectors now
all read one graph-global population"* is **FALSE at `68f84bf1`**. It may not appear in a `DEBT.md`
row, a commit message, the PR body, or the #1113 close-out. This is exactly the claim-reaching-past-
its-evidence shape the audit flagged, caught before it was written rather than after.

## RUN-P3-009 — the `D2 §3` carrier escalation is RULED. Full text: `AD2-carrier-ruling.md`

**Ruling in one line:** RUN-B-013's C-2 (a **5th positional `CProgram` field**) **stands** — the
escalation and the ruling were about orthogonal axes, and the brief's "positional vs two-valued"
framing was a **false dilemma** the companion refused. What is ruled is the field's **type**: it is
**two-valued**, spelled **`CAdmis = CAdmisAbsent | CAdmisTable <rows>`**, **not** `Option`.

Why `Option` loses, and it is the only asymmetry between the spellings (both cost the same 24
sites, both make `absent ≡ []` a type error, neither trips the wildcard trap): RUN-B-013's
condition 1 forbids *"a single `Option`-with-default"* **by name**, and `fromOption` is
auto-prelude with **99 uses in `compiler/`** — so the forbidden collapse is `fromOption [] admis`,
one idiomatic token, invisible in review. `CAdmisAbsent` has **no prelude eliminator** and is a
**token that exists nowhere else in the tree**, so the anti-collapse tripwire is one grep.

**The escalation's premise was corrected, not just confirmed** (this matters, because Phase 4 will
inherit the argument): `lowerProgram` is the **shared** path, not the *untyped* one — **2 of its 7
probe-driver callers are typed**, and a **user-facing verb (`medaka snapshot`) reaches it**. So D2's
argument (*"the untyped drivers have no table"*) invites the rebuttal *"thread the table on them
too"*. The load-bearing reason is different and durable: **the `lowerProgram`/`lowerProgramEmit`
split does not partition callers by whether a table exists**, so no call site can be inferred to
mean "absent" and absence must live in the value.

**Three counts in `D2-phase5-engines.md` §3 are refuted** (fourth, fifth and sixth mis-stated counts
recorded in this arc): "nine probe drivers" → **7 drivers**; "`CProgram` is constructed at exactly
ONE site" → **13**; and RUN-B-013's *"no user-facing verb reaches the untyped path"* is true of
`cevalModules`/`cevalProgram` but **false of `lowerProgram`**, so it does not transfer to the
carrier and Phase 4's `DEBT.md` row may not repeat it.

### ⚠️ Cross-link that binds THIS sprint, not Phase 4

AD-2 §5.2 derives, for the carrier, the same serialization dilemma RUN-P3-005 part 3 ruled for
`RKey` — and it adds the fact that makes the ruling sharper:
**`core_ir_roundtrip_main.mdk:28-30` lowers → serializes → RE-PARSES → evaluates.** So a field that
is *rendered but not round-tripped* **silently becomes ABSENT after a round trip**. Applied to bite
`a`: rendering identity into the S-expr is not sufficient — **`core_ir_sexp_parse.mdk` must
round-trip it, or the roundtrip probe silently observes an identity-free program and reports
success.** That is a returns-nothing→returns-something hazard inside the very channel the repair
round uses to observe this change. **Added to `a`'s packet as a required, not optional, sub-item.**

## RUN-P3-010 — Q4 answered, and it RE-OPENS `B-2.2-f`'s sizing on a NEW axis

Sites re-derived (⚠️ the packet's `25049`/`26089` are **stale**; grep by symbol):
`data CSlot:5843` (**single-line — safe for a commented field**, #829 does not trigger) ·
`pairSlots:5860` · `superSlotOf:9463` · `registerMemberSlots:25102` · `registerInferredFor:26142`.
Four mints, one file (`grep -rln CSlot --include=*.mdk` → `typecheck.mdk` only).

| mint | verdict |
|---|---|
| `superSlotOf:9463` | `False` — the sprint's premise holds |
| `registerInferredFor:26142` | **`True`**, DERIVED — the fn's own inferred `=>` context (`inferredConstraintIds` keeps only ids in `schemeIds sch`), minted during generalization, i.e. **strictly upstream of `expandSupersTable`**, whose only two live call sites are `:14487` and `:21363` |
| `registerMemberSlots:25102` | **`True`** — declared signature context, upstream of expansion |
| `pairSlots:5860` | 🚨 **NOT `True` as ruled** |

**The `pairSlots` defect.** `csDeclared` is in **neither table payload**
(`setFunConstraintEntry:25043-25046` writes ids and ifaces only), and the sole rebuild path is
`expandSupersEntry:9398` / `expandSupersIfaceEntry:9405`, both `expandSupersPairs allDecls
(pairSlots ids ifaces)`. On the **Module** path `checkBodyImpl` seeds `perRun` from the cross-module
refs at `:21105-21106`, expands at `:21363`, and snapshots the **post-expansion** value back at
`:21364` — so module *N* is seeded from a snapshot taken **after** module *N−1*'s expansion, and
`:21363` feeds already-appended slots back through `pairSlots`. Today this is **invisible**
(`expandSupersPairs` dedups by `cslotKey = spelling ++ id`, so re-expansion is content-idempotent
and dict arity is unchanged). **Under `f` it silently re-marks appended slots `True` — the flag goes
vacuous exactly where the bug lives.** And id value can never discriminate: `superSlotsOf:9453`
gives the appended slot the **same integer** as its sub slot.

**This is independent of the D9 dependency** D1 §6.3 made `f`'s ❌ conditional on. AD-1 discharged
D9; this axis was never considered. **Escalated to a dedicated architecture agent (P0-6) before any
ruling**, because the obvious remedy — have `pairSlots`' callers pass `False` — is *not* the
conservative choice it appears to be: if a rebuilt entry's **declared prefix** also loses its `True`,
then on the Module path (where every cross-module entry is rebuilt) identity is withheld
**everywhere**, and `B-2.2` delivers nothing cross-module — which is precisely where C4/I2, the
arc's headline claim, lives. A "safe under-stamp" that is vacuous there is not safe, it is empty.
**Answering that by reasoning is the exact move that became an S0 twice in Stage B; it gets a build.**

## RUN-P3-011 — Q5: the P4 tripwire is `b1`'s, and R3's P4 program was NOT VALID

**Owner ruled: `B-2.2-b1` owns the P4 tripwire.** The falsifying event is a **stamp**, not a mark —
with `f` landed and `b1` not, every route word is still a bare tag and P4 stays green for the reason
it is green today. `f` owns the **availability of the discriminator** (including RUN-P3-010's
defect): if `f` ships with `pairSlots` minting `True`, `b1`'s gate reads a flag that is `True` for
appended slots on the Module path and the gate is **vacuous exactly where the bug lives**.

**The tripwire, in one testable sentence:** for a call to a `Deriv a =>`-constrained function at a
concrete receiver, the dict word applied at the **appended `Base` super slot** is byte-identical to
the word at the **declared `Deriv` slot**, and that is correct *only* because the word is a bare tag
carrying no interface and no impl-row identity. **MEASURED at IR level, not inferred:**
`call i64 @mdk_use__both(i64 …@mdk_dc_0…, i64 …@mdk_dc_0…, i64 42949672961)` — the **same**
`@mdk_dc_0` passed to both dict params, and `@mdk_dc_0 = internal constant [1 x i64] [i64 177657]`,
one bare word. The tree states the premise itself at `typecheck.mdk:9365-9369`: *"Because the dict
VALUE is just a type tag (VDict "Widget"), the super slot's route is identical to the sub slot's."*
That sentence is what Phase 3′ falsifies.

⚠️ **REFINEMENT to R3's F-4, MEASURED: the tripwire has ≥3 copy sites and R3 names the wrong one for
the common case.** `resolveRecMono:20159` is the **recursive-call** arm; a non-recursive cross-module
call never reaches it. The common case copies at **`inferDictAtFound:9170-9176`** (appended slot
shares the sub's `csId`, so `constraintMonosOf` yields the same mono twice and both slots resolve
against it); `shadowStandaloneDictSlots:12374` is a third instance of the same shape. **A bite scoped
to `resolveRecMono` alone leaves the common case uncovered.**

### 🚨 R3's P4 program is unrunnable, and once made to parse it tests something else entirely

1. `public export interface` is a **hard parse error** (*"`public` only applies to `data`
   declarations"*, exit 1) — R3 ran nothing, so this was never going to surface there.
2. After fixing (1), its method name **`sub` collides with the prelude's `Num.sub`**
   (`stdlib/core.mdk:699`) and the program exhibits a **native miscompile** instead of testing
   organ 4: `run` prints `201`, the built binary prints `7001350344291201`, exit 0 both.

**⇒ Any prior "P4 green" reading taken from that program is unsound in both directions.** A valid P4
was reconstructed (`interface Base` / `interface Deriv a requires Base a`, distinct bodies `1`/`2`,
`both x = dtag x * 100 + btag x`, split across four modules) and **MEASURED GREEN at this pin**:
`check`/`run`/`build`/native all `201`, in **both** import orders. Recorded per R3's own instruction
as *"green because dict words are still bare tags"* — **proven** by the `@mdk_dc_0`-twice IR
reading — and never as *"organ 4 is fine"*. Controls, all measured: **PC1** delete `impl Base T` →
exit 1 with the missing-superinterface diagnostic (the obligation is live); **PC2**
`define i64 @mdk_use__both(i64, i64, i64)` — three params for a one-argument function, so the
appended slot really is threaded; **PC3** distinct bodies make a copied route *observable* (`202`
vs `201`), so this is not an absence probe.

### The watching artifact — TWO assertions, because a value golden cannot see this bug

- **(A) value fixture** (`test/dict_fixtures/`, graded by the dict-semantics gate): expected **`201`
  hand-derived from the semantics**, never captured. ⚠️ `must_fail_fixtures/` is the **wrong home** —
  that corpus asserts a bug *still reproduces*, and there is no bug here today; a row there would be
  a false claim that reds as "drained" with nothing having changed.
- **(B) MECHANISM assertion — the one that actually watches the tripwire.** A value golden is blind
  to identity *inside* the word: a wrong-identity word that still selects the right row prints `201`
  anyway. Assert on the IR (`--keep-ir`, redirected — the exit code does not survive a pipe). Today:
  `@mdk_dc_0` twice. **The moment `b1` lands, the expected IR is itself the deliverable `b1` must
  move deliberately, and blessing that diff is the review gate.**
- **(C)** keep PC1 live as a negative: if a `b1` regression makes the super slot *vanish* rather than
  mis-resolve, (A) and (B) both still pass.

**What a still-green P4 after `b1` would NOT mean** (recorded now, so it cannot be over-read later):
not that the appended slot carries `Base`'s identity (one impl per interface ⇒ a wrongly-stamped
identity can still land on the right row via the fallback tier — **only (B) discriminates**); not
that the other two copy sites are covered; not that transitive chains are covered (P4 is depth 1,
`expandSupersFix:9433` is a fixpoint and `Top requires Mid requires Base` forges two slots); not that
`f`'s flag is non-vacuous (RUN-P3-010 — and P4's `both` lives in a module whose entry **is** re-minted,
so P4 is also the program where that defect first bites); not that #1127 is drained.

## RUN-P3-012 — a live S0 cell found in passing, REPRODUCED first-hand by the orchestrator

Not an agent's claim relayed: independently re-authored and run on the sprint binary, one identifier
apart, `MEDAKA_STRICT=1`, exit codes from redirects.

```medaka
interface Zub a where
  zub : a -> Int          -- and the variant with `zub` renamed to `sub` throughout
data T = T
impl Zub T where
  zub _ = 2
both : Zub a => a -> Int
both x = zub x
main = println (both T)
```

```
zub: check=0 run=0 [2] build=0 exec=0 [2]
sub: check=0 run=0 [2] build=0 exec=0 [69934889740256]
```

**`run` prints 2; the BUILT BINARY prints a leaked pointer, exit 0, no diagnostic.** `sub` is a
method of the prelude interface `Num` (`stdlib/core.mdk:699`, arity 2) and the user interface
declares it at arity 1.

**Routing — an ADDITIONAL CELL on #1450, not a new issue.** #1450 is *"two modules sharing an
interface METHOD NAME make the emitter define an impl with the OTHER interface's arity — check 0,
run correct, built binary prints a leaked pointer"*. Same symptom, same mechanism; what is new is
that **the colliding partner can be the auto-prelude itself**, so the repro needs **one file and no
imports at all** (#1450's needs three files and an import-order swap), and every user interface
method named for a `Num`/prelude-interface method — `add`, `sub`, `mul`, `div`, `negate`, `abs`,
`signum`, `fromInt` — is exposed with no import. Filed to #1450 as a comment at the exit phase.
**Out of scope for this sprint's implementation** — recorded because a `B-2.2` probe that names a
method after a prelude method will silently measure this instead of what it meant to.

## RUN-P3-013 — 🚨 Q3 answered, and it AMENDS `B-2.2-b1`'s stated mechanism

This is the question the sprint doc called `b1`'s real risk, and it was right to. **The design's
premise is false, and the tree's own comment is what misled it.**

### The tree's warning names the WRONG TIER (DERIVED + MEASURED)

`typecheck.mdk:18354-18360` warns that behaviour surviving this IR change is *"EMPIRICAL, not
structural … it rests on the emitter's general-instance fallback tier: `emitGeneralRKey` →
`findByTag noneHeadTag`"*. That has now been relayed through two design documents. **Derived on a
build for the first time: the `None` arm cannot reach `emitGeneralRKey` by construction.** A
headless general that provides the method is *always* a candidate for `ieSelectRowByMethod`, so
whenever a general exists `keyForSite` returns `Some`; the `None` arm fires only when there is **no**
general — exactly the condition under which `emitGeneralRKey` misses. Measured: a headless impl
emits a **direct** `call @mdk_impl___none___sz`, i.e. the ordinary direct-hit path, because the
general is itself registered under `__none__`. **The named tier is the tier that used to be needed,
before F-3b moved the word.**

### What actually catches the `None` arm — and it is keyed on the thing `b1` was going to delete

The live `None`-arm population is **one shape**: a **cross-module method-less impl inheriting an
interface default**. `ieEntriesForMethod` requires `contains name ms`, and `fillImplDefaults` is
**same-module only** by its own comment (`desugar.mdk:838-841`) — so a cross-module method-less impl
carries an empty method list and can never be a candidate. That population is **large**: any user
impl of a prelude interface is this shape.

Measured discriminator — the one shape where the two arms emit *different symbols*:

```
e1_same  (same-module)  → call i64 @mdk_impl_Box_sz(i64 %t3)          -- Some "Box"
e2_cross (cross-module) → call i64 @mdk_default_sz_Box(i64 %arg0)     -- None
```

`@mdk_default_sz_Box` is reachable only via `implFor` miss → `emitGeneralRKey` **miss** →
`emitDefaultRKey`, whose symbol is `mdk_default_<method>_<TAG>`. **That `<TAG>` is supplied by
`fromOption tag`.** Controls, measured: delete the interface default and the program is rejected
loudly at exit 1 on all three verbs (so the population really is bounded to the default-inheriting
shape); distinct method names make the collision case order-invariant (so the flip below is caused
by the shared name).

### ⇒ THE AMENDMENT, and it is the sprint's most important Phase 0 result

> **`fromOption tag` is not "a head-tag hedge over a selector result". At the sites where it fires
> it is the ONLY source of the head tag the default-dispatch symbol is keyed on, and the selector
> was never going to speak there.**

`b1`'s transform as written — *"`fromOption tag` disappears"* — would break **every cross-module
default-inheritance call site**. `b1` is still statable, but its mechanism is amended to:

- mint identity **from the row** where a row exists (unchanged), **and**
- on the **no-row** arm, **preserve the concrete head tag as the word** and carry the identity as
  **absent**. The tag is available at the arm: `entailInst` is reached *only* when
  `headTyconNameMono m` is `Some tag` (`typecheck.mdk:19663`).

**Convergence worth naming:** the absent-identity state AD-1 required for D8/D9 is the *same* state
`b1`'s no-row arm needs. Three sites, one mechanism — an independent second route to AD-1's
`Option`-valued field, and confirmation that `a`'s payload shape is right.

**`b1` also inherits #1182 rather than fixing it.** The row it mints identity from is chosen by
`ieCandidatesForMethod`, keyed `(method name, head)` with **no interface component**; two interfaces
sharing a method name give incomparable rows and `pickMostSpecificEntry` returns the head of the
`mergeByDeclIdx` list. Measured at this pin, in a *sharpened* form: with the call site explicitly
typed at `Beta`, impl-block order alone flips the answer `11` ↔ `22`, check 0, build 0, and the
emitted dispatcher **loads the runtime dict tag and never compares it**
(`%t1 = load i64, ptr %t0` … `call @mdk_impl_Alpha_a__ping`). Today the head-tag hedge sometimes
masks this; after `b1` the wrong instance's identity is stamped directly — **a quieter→different
transition on an already-open S0.** `b1`'s `nearest miss:` must say so.

### The fixture `b1` owes — built from the spec, because no existing fixture can fail

Every existing fixture covers the *substituted* case. Three assertions:
1. the cross-module default-inheritance pair (same-module vs cross-module, same value `42`) **plus
   an IR assertion** on `@mdk_default_sz_Box` — an exit-code-graded control cannot see this, since
   the shape exits 0 today and would exit 0 with a wrong symbol too, right up until the link fails;
2. the no-default negative, which must keep its good diagnostic at exit 1 and must not degrade if
   `b1` makes the `None` arm loud;
3. the #1182 permutation pair as a **must-fail** row, so a change from wrong to *differently* wrong
   is visible — a value-golden gate is structurally blind to that.

**Ordered, not keyed, on all three engines** (`findByTag` first-match over `implsOf` in program
order; `firstGeneralImplW` a literal first-match; eval's `pickTagFallback` → `oneOrMultiV` which
**punts to the untyped arg-tag path** on multiple candidates). ⚠️ LLVM takes the first and eval
punts — **the two engine families resolve a multi-candidate `__none__` bucket by different rules.**
That is a divergence surface, recorded for the repair round's engine leg.

**Correction owed in the tree:** `typecheck.mdk:18354-18360` must be fixed in place by whichever
bite lands there, not relayed a third time.

## RUN-P3-014 — 🚨 SECOND live S0/S1 found in passing, REPRODUCED first-hand with my own control

Root cause is one wildcard arm — `headTyconTy`'s `_ => None` (`typecheck.mdk:19310-19314`) — so a
**function-typed impl head** (`impl Sz (Int -> Int)`) is filed into the *same* `noneHeadTag` bucket
as a fully-general `impl Sz a`. This is `AGENTS.md`'s new-constructor-swallowed-by-a-wildcard trap
one substrate over: `noneHeadTag` is documented as *"a type VARIABLE head has no head tycon"*, but
the arm really means **anything that is not a `TyCon` and not a `TyTuple`**.

Independently re-authored and run on the sprint binary (`ab`/`ba` differ only in impl-block order;
`ctl` is my own control substituting two `data` types for the two function types):

```
ab:  check=0 run=0 [(5, 5)] build=1 exec=NOBIN
ba:  check=0 run=0 [(9, 9)] build=1 exec=NOBIN
ctl: check=0 run=0 [(5, 9)] build=0 exec=0 [(5, 9)]
error: emitter failed compiling ab.mdk
runtime error [E-PANIC]: arg-tag dispatch on impl type that owns no constructors
                         (primitive receiver carries no cell tag)
```

Correct answer is `(5, 9)`, derived from the source before running. **`run` is wrong in BOTH
permutations, exit 0, check clean — S0.** **`build` exits 1 with a compiler E-PANIC rather than a
diagnostic — S1, plus an eval/native divergence.** The control builds and prints correctly, so the
trigger is the function-typed head, not two-impls-per-interface.

**Not this sprint's to fix.** Filed at the exit phase after an independent dedup check; recorded
here because it constrains this sprint's probes — any `B-2.2` fixture using a function-typed impl
head is measuring this defect, not dispatch identity.

## RUN-P3-015 — `B-2.2-f` RE-SIZED: a declared-prefix COUNT sidecar. Options (1) and (2) both REJECTED

> 🚨 **PARTIALLY SUPERSEDED by RUN-P3-023.** The **count-sidecar half stands**. The **`csDeclared`
> field half is REFUTED** — no field, no `data CSlot` change, and `f` touches neither fill site.
> Also corrected there: **2** ratchet rows, not 4; `:29056`/`:29088` are **WRITERS**, not
> "count-only readers"; the write list is **FIVE** sites, not three. And corrected by the `f` review:
> *"a mismatch clamps loudly"* is **false** — nothing clamps it, the implementer writes the `min`.

The architecture agent (P0-6) verified RUN-P3-010's chain and ruled. The ruling stands, with **its
one unmeasured premise now MEASURED by the orchestrator** (RUN-P3-016 below).

**The decisive question was:** at each fill site, is the slot list computed from a *local declared*
list, or does it arrive *already appended* out of a table? Both non-recursive fill sites
(`inferDictAtFound:9152`, `shadowStandaloneDictSlots:12362`) take their input from **the same
accessor**, `declaredConstraintSlots:9111`, which resolves through `qualConstraintFor` or the bare
`funConstraintsRef` — **every source is a table.** So the answer is purely a question of *when the
table was last expanded relative to the fill*:

| path | table state at the fill | boundary intact? |
|---|---|---|
| **Flat** (`elaborateDict:14487`) | `expandSupersTable` runs *after* `checkProgramSeeded` | **YES** |
| **Module**, callee in **this** module | registered during this module's inference; `:21363` has not run | **YES** |
| **Module**, callee in an **EARLIER** module | seeded `:21105-21108` from a `crossRun` snapshot taken *after* module N−1's `:21363` | 🚨 **NO — destroyed** |

⇒ **Option (2) — mint the flag at the fill sites, no table change — is correct on Flat and on
same-module calls and WRONG on exactly the cross-module case `B-2.2` exists for.** It would mint
`True` on every appended super slot that crossed a module boundary. **REJECTED.**

⇒ **Option (1) — `pairSlots`' callers pass `False` — REJECTED, and it is worse than "conservative".**
`expandSupersTable:9382` → `setFunConstraintTables:9345` rewrites `perRun.funConstraintsRef`
*itself*, and `:21364`/`:21366` immediately snapshot that value into the `crossRun` bare **and qual**
mirrors. So every entry in the snapshot — **declared prefix included** — would be `False`, and module
N ≥ 2 is seeded entirely from it: **identity withheld on 100% of cross-module constrained calls.**
That is "works single-file, vacuous multi-module" — an empty feature wearing a safety label, and
structurally the same shape as the live S1 one layer up (#1457).

### RULED — option (3), in a form materially cheaper than D1 priced it

**A per-entry scalar: the DECLARED PREFIX LENGTH `k`, carried alongside the IDS table**, mirrored
into `crossRun` bare + qual. **Not** a payload widening of `funConstraintsRef`; **not** a per-slot
parallel list. ~~`csDeclared` is then minted at the fill sites as `index < k`.~~
**⚠️ REFUTED (RUN-P3-023): there is NO `csDeclared` field and `f` touches neither fill site.**

**Why a count is sound here** (and D1 §6.1 item 2's objection does not apply): `expandSupersPairs =
expandSupersFix allDecls declared declared` starts `acc = declared` and only ever **appends**, and
`dedupSlots` keeps the **first** occurrence — its own comment: *"declared slots stay leading"*. So
the declared slots occupy `[0,k)` **permanently**, across arbitrarily many re-expansions. D1's
objection was that `k` is unrecoverable *by recomputation*; it is being **recorded**, which is
exactly what D1 §6.1 item 2 says the correct move is.

**Cost RE-DERIVED, not relayed** (D1's "~20 sites / two allowlist rows" priced the payload-widening
variant and is wrong for this shape in both directions):
`grep -c 'perRun.value.funConstraintsRef.value'` → **13 reads, of which a sidecar changes ZERO.**
Writes owed: the whole-table replacements only — `21105/21107` (seed), `21364/21366` (snapshot),
`25045` (entry append); `29056/29088` is a **count-only reader** and can be omitted.
**`test/registry_keying_ratchet.sh` owes FOUR rows, not two** — 2 CrossRun fields in check 1 **plus**
2 `setRef crossRun.value.*` writer rows in check 2 (`:187-190` shows the existing four tables).

**Pre-empting the obvious review objection:** a sidecar looks like the "two parallel lists" shape
`CSlot`'s own header was written to abolish. It is not — `k` is a **per-entry scalar**, not a
per-slot list, so there is no zip and no truncation policy; a mismatch degrades to an out-of-range
count, which clamps loudly rather than silently dropping a tail.

**`b1` remains statable unchanged.** ~~Its gate reads `csDeclared`, now correct on Flat, same-module
and cross-module alike.~~ **⚠️ REFUTED twice: there is no `csDeclared` (RUN-P3-023), and `b1`'s
payload is two lines with no gate of its own (RUN-P3-025).** The conclusion — `b1` stays statable —
held through both re-cuts. **The sprint proceeds as cut, with `f` re-sized.**

### ⚠️ Correction B — `expandSupersIfaceEntry` is NOT idempotent, and it constrains the design

RUN-P3-010's *"content-idempotent"* premise is **half false**. The ids entry (`expandSupersEntry`)
*is* idempotent — it pairs against real ids. `expandSupersIfaceEntry` is **not**: it fabricates
synthetic ids (`idsForIfaceSlots:9412-9422`, `0,1,2,…`), so re-expanding `[Subq, Sup]` yields a
frontier `Subq@0 → Sup@0` that `cslotKey` treats as distinct from the existing `Sup@1` — **the
ifaces entry grows by one per subsequent module.** `pairSlots`' truncate-to-shorter policy
(`:5857-5858`) masks it, so slots stay correct and it is unobservable in IR.

**Consequence, and it is why the sidecar rides the ids table:** any boundary marker stored on the
**ifaces** table is unsound by construction. DERIVED, not measured (truncation hides it). **Owed its
own pin, separately from this bite** — added to the exit-phase filing list.

### One zero-cost variant considered and rejected on principle, not cost

Recovering declaredness at the fill site from the callee's scheme context
(`importedSchemeOblsRef` / `crossModuleSchemeOblsQualRef`) fails because `typecheck.mdk:12343-12347`
records that the two stores live in **different id spaces** — *"mapping the latter's ids through the
former's substitution silently finds nothing."* The only remaining join key is the interface
**SPELLING**, which is precisely what B-2 exists to stop keying dispatch on, and which is ambiguous
in exactly the two-same-spelled-interfaces shape. Recorded so nobody re-proposes it as free.

## RUN-P3-016 — 🚨 I MEASURED the one premise the ruling rested on source-reading for

P0-6 stated its limit honestly: the *pre-expansion-at-fill-time* fact is not observable in IR
(re-expansion of the ids entry is idempotent, so arity and route words are identical either way), it
rested on reading the `:21105`/`:21363`/`:21364` ordering, and it explicitly said **"don't take my
source read as a measurement"** and named the one-line instrumented build that would settle it.

**That is the exact situation Stage B's retrospective says became an S0 twice — a prep pass asking a
question only a build can answer, and an orchestrator answering it by reasoning. So I ran the
build.** `let _ = if name == "processq" then panic (…listLen slots… listLen (expandSupersPairs …))`
at `inferDictAtFound:9152`, `make medaka`, both arms, then reverted (⚠️ a first attempt routed the
value through `pushTypeError` and produced **nothing on either arm** — the diagnostic never
surfaced. A silent probe proves nothing; `panic` is unfilterable, which is why it was the right
instrument):

```
== /var/tmp/p3/p06/two/main.mdk (2 modules)  exit=1
runtime error [E-PANIC]: PROBE-P3 callee=processq slotsIn=2 expandedOut=2
== /var/tmp/p3/p06/iso/a.mdk  (single file)  exit=1
runtime error [E-PANIC]: PROBE-P3 callee=processq slotsIn=1 expandedOut=2
```

**Same function name, same body, single variable = one file vs two modules.** Cross-module, the
slots arrive at the fill site **already expanded** (`slotsIn=2`: declared `Subq` + appended `Sup`);
single-file they arrive **declared-only** (`slotsIn=1`) and expansion happens locally.

**The probe was fail-capable and it discriminated** — it returned *different* numbers on the two
arms, which is the whole point; a probe that printed `2` on both would have proven nothing.

⇒ **RUN-P3-015's rejection of option (2) is now MEASURED, not derived**, and the sidecar is ruled on
evidence. `typecheck.mdk` was restored to pristine (`git diff` clean) and the binary rebuilt from
unmodified source before any implementation work.

## RUN-P3-017 — sequencing: #1457 bounds `f`'s population TODAY and will widen it

Re-derived first-hand by P0-6 while building its probe: a module-level fn whose **body** calls a
**superclass** method is **FALSE-REJECTED on the multi-module path** (*"Could not deduce 'Sup a'
from the signature of 'processq'"*), while byte-identical code is accepted single-file and by
`test/build_diff_fixtures/super_method.mdk`. That is **#1457** (OPEN, `verified`, `S1: loud
breakage`) — not new, not filed again.

**Its bearing on this sprint:** today the population of cross-module appended super slots is
restricted to callees that declare a super-implied constraint but **never call the super method**
(P0-6's probe had to be reshaped into exactly that to get past it). **`f` is still required** — the
slot exists and is passed; measured, `@mdk_b__processq` takes **two** dict params against
`@mdk_onlysup`'s one, and both arguments are the **byte-identical** `@mdk_dc_0`, so the appended
slot is indistinguishable from the declared one at the call site by any means other than a boundary
marker. But **`f`'s blast radius grows the moment #1457 is fixed, and a fixture written before that
fix will not exercise the shape that matters after it.** Goes in `b1`'s brief verbatim.

---

# RUN-P3-018 — PHASE 0 GATE: **GO.** Bite order holds; two bites are amended and one is re-sized

> # 🚨 THIS TABLE IS THE PHASE 0 SNAPSHOT AND **EVERY ROW HAS SINCE MOVED. DO NOT QUOTE IT.**
>
> | row | superseded by | what actually happened |
> |---|---|---|
> | `a` | **RUN-P3-019** | **no type change at all** — no carrier, sexp files untouched, no compiler-enumerated error set |
> | `f` | **RUN-P3-023** | **no `csDeclared` field**; **2** ratchet rows, not 4; `f` touches **neither** fill site |
> | `b1` | **RUN-P3-025** | **two lines, ZERO edits at the four arms**; the collision gate is already carried |
> | `e` | **RUN-P3-027** | `e` must **skip two** of the nine sites (`KeyEntry`'s key field has no reader) |
> | `b2` | **RUN-P3-032** | **DROPPED** — D1's ✅ on the D4 pair is *wrong at this pin* |
> | `c` | **RUN-P3-033** | a **third** stale comment found; scope is three corrections, not two |
>
> Kept unedited below because it is the honest record of what Phase 0 concluded — and because the
> gap between this table and the six entries above is the sprint's most useful artifact: it is the
> measured rework rate, not an embarrassment. **But it is the most consultable thing in this file
> (a `#`-level heading reading "GO"), so a reader who stops here leaves with six wrong facts.**

Phase 0 ran six read-only agents plus one orchestrator-run instrumented build. **No stop condition
fired.** The refresh found zero drift in the site set, and D1 §5's precondition — the one it said 3′
stops without — is met. **Order stands: `a` → `f` → `b1`+`e` → `b2` → `c`.**

| bite | state after Phase 0 | statable? |
|---|---|---|
| `a` | **WIDENED.** Carrier type on `RKey`'s field 1 (not a 3rd positional field); §9 lends it 6 non-owned files for mechanically-forced arity/accessor edits; **must render identity into the S-expr AND round-trip it** (`core_ir_roundtrip_main` re-parses, so rendered-but-not-round-tripped silently reads as ABSENT) | ✅ 2 sites + a compiler-enumerated error set + the sexp pair |
| `f` | 🚨 **RE-SIZED** — a per-entry declared-prefix count `k` sidecar on the ids table, mirrored to `crossRun` bare + qual; `csDeclared` minted at the fill sites as `index < k`. **+4 ratchet allowlist rows.** No longer "~7-9 sites, one file" | ✅ but it is now **the risk bite** |
| `b1` | **AMENDED twice** — carries the collision gate (not a projection); **preserves the concrete head tag on the no-row arm** (deleting `fromOption tag` outright breaks every cross-module default-inheritance site). Owns the P4 tripwire; inherits #1182 | ✅ 4 arms, one helper |
| `e` | unchanged, 9 sites, **lands with `b1`**; `engines:` now owes LLVM's `implEntryRouteKey`/`implEntryRouteWords` and wasm's independent family as named peers | ✅ |
| `b2` | unchanged, 2 named pairs. **First to be dropped if the sprint needs to shed scope** — it is an optimization (the only bite RUN-B-023's +17% argues *for*), not a soundness bite | ✅ |
| `c` | unchanged **plus two comment corrections it now owns**: `:19397`'s stale nested-`requires` justification (RUN-P3-007) and `:18354-18360`'s wrong-tier warning (RUN-P3-013) | ✅ 5 sites + 2 |

**`a` and `f` are independent of each other** (`f` touches no `Route` payload; `a` stamps nothing);
both must precede `b1`. The stated order is kept because serializing writers is the rule regardless.

**Deferred out, each with its reason:** the `keyTable`/`KeyBuckets` deletion (RUN-P3-007 — inert, but
its 99 positions run through the region four bites edit). **Filed at the exit phase:** the
`expandSupersIfaceEntry` non-idempotence pin (RUN-P3-015 Correction B); the prelude-method-name cell
on #1450 (RUN-P3-012); the function-typed-impl-head S0/S1 (RUN-P3-014); the `ImplBuckets` second
deciding population, **only if the repair round reproduces it** (RUN-P3-008).

**Phase 0 cost:** 6 read-only agents, ~48 min wall clock, plus 2 orchestrator builds for the
instrumented measurement. **It amended two bites, re-sized a third, refuted six counts across three
design documents, corrected two in-tree comments, and surfaced two live defects.** The design-ahead
rework rate the audit measured at 75% held: of the six bites, **three were changed by Phase 0** —
and one of those changes (`b1`'s `fromOption tag`) would otherwise have shipped as a break in every
cross-module default-inheritance program.

---

## RUN-P3-019 — 🚨 `B-2.2-a` REFUSED AS DESIGNED and RE-CUT: there is **no type change**

The architecture companion (P0-7) was asked to choose among four carrier shapes for `RKey`'s
payload. **It refused all four and named the missing option: there is no carrier.** I audited the
refusal before accepting it — including verifying its load-bearing claim first-hand — and **it is
better evidenced than the design of record.** ACCEPTED.

### The ruling

**`data Route` is UNCHANGED. `RKey`'s first field stays `String`.** `B-2.2-a` becomes **one new
module, one mint, zero call sites** — `compiler/types/route_key.mdk`, exporting `ifaceWordOf` /
`implRouteKeyWord` / `routeWordFor` (+ private `rkTy`/`rkTyAtom`/`rkTyFunArg`), which **both** the
caller side (`keyForSite*`) and the definition side (`declRouteKey`/`implKeyOf`) will call. The
words then agree **by construction** instead of by two hand-mirrored implementations happening to
match.

### Why — three independent derivations, any one sufficient

1. **No consumer can use an identity.** The consumer table enumerates all 15 reading sites: every
   one needs the **word**, and the only namespaces `Route` reaches outside `types/` are `String`
   symbol names (`@mdk_impl_<tag>__<method>`) and `hashName`'d i64 dict words. An `InstRef` arriving
   there must be rendered to a `String` before it can act — **at which point it is the word.**
2. **The mirror of the constraint I found is what kills D1's mint siting.** I established
   `ast.mdk` ↛ `InstRef`; the decisive half is the other direction — `eval.mdk` and
   `core_ir_lower.mdk` **also cannot reach `typecheck.mdk`** (verified: the only cross-stage import
   edges are `core_ir_lower → eval.eval`, `llvm_emit`/`wasm_emit → ir.core_ir_lower`, `wasm_emit →
   backend.trmc_analysis`). So D1's *"site the mint beside `InstRef` in `typecheck.mdk`"* would make
   it a **THIRD** mirrored copy alongside `implKeyTc` and `implKeyOf` — **the exact P0-9 shape
   `B-2.2-e` exists to delete**, while looking like it satisfied `e`'s stated property.
3. **The tree already ruled this, at the site that owns the word**, in a header block cited by
   neither D1 nor my brief: *"what moved onto identity is the FIELD, not the comparison"*
   (`keyForSite`) and *"Route words are bare names by construction and three engines re-derive that
   same uniqueness test from a bare `String` tag … the question is inherently SPELLING-scoped and
   **answering it with identities is wrong at ANY supply level**"* (`ieCountHeadByIface`).
   Component (ii) is that same move, one field over.

**MEASURED**, and it settles the load-bearing question (*does anything need to distinguish two routes
carrying the same word?*): at a genuine same-head/same-method collision the head test already fires
and the word already separates the instances **all the way into the emitted symbol namespace** —
`@mdk_impl_Alpha_T__ping` and `@mdk_impl_Beta_T__ping`, with the call site correctly reaching Alpha's.
A control with the second interface deleted is clean, so the divergence is caused by the collision.
⇒ **D1's component (ii) is dead weight in a node 25 sites touch.**

### AD-1 is satisfied, not contradicted

AD-1 required the absent state to **exist** and explicitly delegated its *representation* to `a`
(*"or carries an explicit `unselected` value; the choice is `a`'s"*), stating the required outcome as
*"the word stays `RKey <tag>` byte-for-byte."* **Under this ruling absence IS the bare head tag** —
byte-for-byte what AD-1 demanded, at all three sites (D8, D9, and `b1`'s no-row arm). Nothing can
distinguish an absent-identity `RKey "List"` from a deliberately-bare-because-unique one, **and
nothing needs to**; every consumer treats them identically, which is what makes them safe.
The honest loss: a future auditor cannot grep for "sites carrying an absent identity." If that
auditability is ever wanted it belongs in a typecheck-internal side table, **never on `Route`**,
which crosses five golden-producing engines where a within-compile serial is un-goldenable.

### What this supersedes

**RUN-P3-005 parts 2 and 3 are SUPERSEDED** (marked, not deleted — an unmarked superseded ruling is
how a ledger starts lying):
- part 2 (carrier type on field 1) — moot; there is no payload change.
- part 3 (render identity into the S-expr, and round-trip it) — **moot, and the hazard evaporates.**
  `core_ir_sexp.mdk` and `core_ir_sexp_parse.mdk` are **unchanged**; the word simply carries
  different content, and `core_ir_roundtrip_main` stays faithful for it. ⚠️ Note the direction I had
  wrong: `toRoute`'s pattern is one-element-only, so an **over-wide render would PANIC, not read as
  absent** — the silent case needs an *under-wide* render, which this shape makes impossible.
- **RUN-P3-005 part 1 also largely evaporates:** with no type change there is no compile-error set,
  so §9's lending of the six non-owned files is **not exercised by `a`**. 15 of the 25 census sites
  are untouched by the whole of Phase 3′. The merge-conflict risk against the #1398 wasm sprint
  (RUN-P3-002) goes with it.
- **The dump probe gets strictly BETTER**, not worse: after the mint, `escStr k` reads
  `mymod::Alpha|T|` at a collision site — a content-derived, **compile-stable** instance name in a
  golden. That is the checkable form of *"same evidence"*, and it is a form an `InstRef` could never
  take.

### 🚨 The catch that would have caused a regression, verified by me first-hand

**`ifaceIdentity` returns `""` on the flat path, and the tree states `""` IS ABSENCE, NOT AN
IDENTITY** (`ast.mdk:113-124`; `ifaceIdMatches` is the only legal comparison, and absence never
matches even itself). The loader-less drivers deliberately stamp no origin, so a word built from a
**raw** `ifaceIdentity` would spell `"|T|"` for **every** interface on `medaka check <single file>`,
lsp, repl, doc, lint and snapshot — **collapsing two instances the present bare-name word keeps
apart.** Hence `ifaceWordOf`'s bare-name fallback. This is the single most likely way to get `e`
wrong and it is stated nowhere in D1.

⚠️ **The property the implementer must ASSERT rather than assume:** the fallback is safe only
because two same-spelled interfaces cannot both have absent origins *and* be in scope together — on
the flat path there is one module and therefore one namespace. Cross-module, origins are stamped.
**Write that down at the fallback; it is exactly where a silent collapse would live.**

### Sizing, and the safety property this LOSES — stated, not glossed

D1 sized `a` as *"2 sites + a compiler-enumerated error set"* and its virtue was that **the compiler
enumerates the site list for you**, which is what made it safe for a weaker model. **That property is
gone.** `a` is now fully inert (no call sites), and all of its risk moves into `b1`/`e`, whose nine
sites are named by a **human** and must be checked as a **SET** — including
`core_ir_eval.mdk:453-455`'s `VTypedImpl` producer, the P0-9 shape in the flesh.
**`e`'s packet gets the derivation command, not the list of nine:**
`grep -rn 'implKeyOf\|implKeyTc\|declRouteKey' compiler/ --include=*.mdk`.

### Two further items this ruling hands forward

- **`e` also collapses the `ppTy` mirror** (`ppTyAtom`/`ppTyFunArg`/`ppTy` in `typecheck.mdk` vs
  `ppTyAtomK`/`ppTyFunArgK`/`ppTyK` in `eval.mdk`). `implKeyOf`'s header calls their agreement *"by
  construction"* — **it is not**; they are two functions matching on the reachable subset, and they
  **already differ off it** (typecheck renders `TyEffect`/`TyRow` as `<…>` and `TyConstrained` as
  `cs => t`; eval strips all three). ⚠️ **The fold is behaviour-visible if any impl type arg can
  carry an effect or a constraint — a discriminating probe is owed BEFORE collapsing, not after.**
- **`nearest miss:` for `e`, which D1 does not state.** `sanitizeId` (`private_mangle.mdk:682-698`)
  maps every char outside `[A-Za-z0-9_]` to `_`, **one-for-one and not injectively**. Today's word
  alphabet at that boundary is `|` and space; the identity substitution (#1113) **adds `:`**. ⚠️ The
  example that followed here was refuted — see RUN-P3-030. So `a::Alpha|T|` →
  `a__Alpha_T_`, and a module `a_` with interface `_Alpha` sanitizes to the **same symbol**. The
  class pre-exists, but this bite **widens the alphabet reaching it** — a returns-nothing →
  returns-something transition on a namespace nothing watches. Owed fixture: two modules whose
  sanitized `<mid>::<iface>` spellings collide, asserting distinct emitted symbols.

## RUN-P3-020 — a THIRD live defect found in passing (P0-7's byproduct) — TRIAGE OWED, not filed

Two interfaces in **one file** declaring the same method name at different return types
(`Alpha.ping : a -> String`, `Beta.ping : a -> Int`), both implemented on one type:
`check` **exit 0** · `run` **exit 1** E-PANIC (`intToString: not an Int` — eval narrowed to Beta) ·
`build` **exit 0** with *correct* distinct symbols and the call site reaching Alpha's ·
**built binary exit 0 printing a raw word** where a string belongs. A control with `Beta` deleted is
clean on every arm.

So the emitted **symbols are right** and the wrongness is downstream of naming — which makes it
**adjacent to but not obviously #1265** (that one is scoped to *defaults*, where
`mdk_default_<method>_<tag>` has no interface component; here both impls are concrete). **Not filed
— I have not reproduced this one myself yet**, and this sprint does not file an agent's claim
unreproduced. Added to the exit-phase triage list with its repro path.

---

# RUN-P3-021 — `B-2.2-a` LANDED (`cd1f2c8d`), inert as designed

`compiler/types/route_key.mdk` — 3 exports, 6 private helpers, 38 doctests, **zero call sites**.
Verified on a freshly built binary: `make medaka` 0 · `check-self` PASS · doctests **38/38** ·
`fmt --check` 0 · whole-project `lint` 0 · the pre-commit **cross-file** scan 0 ·
`diff_compiler_snapshot_frontend` **201 of 201 existing snapshots compared and matching, zero
goldens MOVED**.

The `ifaceWordOf` fallback is **fail-capable, measured**: replacing its body with a raw
`ifaceIdentity o name` reds **8 of the 38** doctests. That is the difference between a test that
passes and a test that *could have failed* — the property RUN-P3-019 predicted would bite, now
guarded by something that demonstrably fires.

### Three decisions the implementer correctly handed back rather than taking

1. **`rule-duplicate-body` red on `rkEffAtom` — silenced HERE, with `e` named as the owner of its
   removal.** The finding is **true, not spurious**: it is a transitional 4th copy, and `B-2.2-e`
   deletes the mirrors. Landing `a` together with `e` (the alternative) would have merged
   `a`+`e`+`b1` into one landing and cost the clean, inert, separately-bisectable commit. The three
   existing copies each carry the same directive; this one additionally names its own expiry.
   ⚠️ **Placement is load-bearing and the diagnostic's line number misleads.** The directive must sit
   immediately above **the specific duplicated equation**. Above the signature, or above the *first*
   equation, it does **not** suppress — measured across three placements with the hook's own command.
   The finding is reported at the declaration's first line, which is a **decl-level anchor, not the
   line the directive is matched against**, so putting the directive where the diagnostic points is
   the natural move and it fails. Written down at the site.
2. **The `Makefile` `test:` line STAYS, and it is the bite's only real verification.** A
   call-site-free module is invisible to `make check-self` *and* `typecheck_compiler_source.sh`
   (measured 2026-08-03 for `types/registry.mdk`, whose header records it). Without that line the
   module ships **unverified with every gate green** — this arc's signature failure. The implementer
   found the standing instruction in the `Makefile`'s own comment; the packet had not carried it.
3. **The snapshot is DEFERRED to the close-out, not created now.** The new file auto-enrolled in the
   snapshot corpus via `compiler/types/*.mdk` (a shared-corpus ADD, not a golden move), so the
   pre-commit hook correctly refused the commit. Committed with `PRECOMMIT_SNAPSHOT_DEFER=1` — the
   documented shape (#1179) for a source commit whose golden lands later in the same PR — keeping
   fmt/lint/lextok live, **never `--no-verify`.** ⚠️ The close-out owes a **CREATE (`--new`)**, not a
   re-bless; the gate's own message warns against `--new` because it writes a golden from current
   output, so this needs a deliberate decision. Recorded in `.claude/HANDOFF.md`.

### One packet error, corrected by the implementer

My packet said `eval`'s printer "strips all three" of `TyEffect`/`TyRow`/`TyConstrained`. It strips
**two** — `eval.mdk:506` renders `TyRow` and agrees with typecheck. The instruction was unaffected
(`rkTy` follows typecheck's `ppTy`, the more complete mirror), and the corrected divergence is now in
`e`'s owed `unchecked:` item. **The error was mine, relayed from P0-7's phrasing without checking it.**

### The verification debt `e` inherits, stated now so it is not discovered later

`rkTy` follows **typecheck's** printer, so pointing **eval's** callers at it would *widen* eval's
words: two impls differing only in an effect row or a constraint currently collapse onto one
`implKeyOf` word there and would stop doing so. **That is very likely the right direction and it is a
BEHAVIOUR CHANGE.** `e` owes a discriminating probe on the eval arm **before** collapsing the
callers, not after.

## RUN-P3-022 — the committed repro harness was BROKEN on first run, and that is why it was smoke-tested

`.claude/sprint-phase3/repro/run.sh` had `set -e`, so it **died at F-2's first intentionally-failing
`build`** and printed only the rows above it — silently reporting a subset as if it were the whole.
This is Stage B's *"read-only reviewers' programs are UNRUN BY CONSTRUCTION — three of six needed
repair"* trap, in a harness written to preserve findings. Fixed (no `set -e`, with the reason stated
in the file so nobody re-adds it) and re-run: **both findings reproduce, matching the recorded
expectations exactly.** It is now a record rather than a claim — which is the audit's own template
delta about probes whose verdict gates a decision.

## RUN-P3-023 — `B-2.2-f` RE-CUT AGAIN: **no `csDeclared` field.** Three corrections to RUN-P3-015

The `f` prep pass refuted the field half of RUN-P3-015 and I accepted it. **`f` = table plumbing
plus one read accessor. Zero `CSlot` mint edits, no `data CSlot` change.**

**The decisive fact — and it is one I had in hand and failed to use.** Three sites mint the route
word `b1` must withhold identity from. Two hold `List CSlot`; **the third holds `List Int` and
constructs no `CSlot` at all** — `realizeRecDictApps:20140` → `recRoutes:20145` →
`resolveRecMono:20161`. RUN-P3-011 *names* that site as one of the ≥3 copy sites, and I still scoped
the question to *"the two fill sites"* when I briefed it. **A `csDeclared` field serves 2 of 3 and
leaves the recursive arm stamping identity on appended slots — the same "vacuous exactly where it
must not be" failure that got options (1) and (2) rejected, wearing a different hat.** A per-entry
count keyed by callee name serves all three, including the one with no slot record.
Second, independent reason: a field must be minted by all four `CSlot` mints — including
`pairSlots`, which **is** RUN-P3-010's defect. The field re-opens the hole the count was ruled in to
close.

**Scope ruling: `f` touches NEITHER fill site.** Plumbing + accessor + doctests only; the indexed
read is `b1`'s, since `b1` is what stamps. This keeps `f` inert and provable by unmoved goldens — the
same property that made `a` reviewable. The alternative (bind `k` at the fill sites, use it nowhere)
is dead code that `fmt`/lint carry and review cannot judge.

### Three corrections to RUN-P3-015, all DERIVED by the prep pass

1. **The ratchet owes TWO rows, not four.** Check 2's allowlist is *computed from* check 1's
   (`test/registry_keying_ratchet.sh:362`, `sed 's/^/crossRun.value./'`), so adding a field row
   **automatically admits its writer**. My "four rows" was an assumption dressed as a derivation.
2. **`:29056`/`:29088` are WRITERS, not "count-only readers"** — whole-table replacements built from
   `scopeArities`, which has no prefix to give. They correctly owe no `k`, because **no fill site
   runs after dict-pass** — and that is precisely why the prefix cannot be a mandatory column and the
   absent state must be first-class.
3. 🚨 **The write list is FIVE sites, not three. The omitted one decides whether `f` is real.**
   `:14600-14612` — `promotedConstraints … funConstraintsRef` → `expandSupersCross` →
   `setCrossFunConstraintTables` — is a whole-table write of the crossRun bare pair **and it is what
   module 1 is seeded from**. Without a companion write, **every promoted cross-module callee reaches
   every fill site with no recorded prefix and `f` ships vacuous** — the exact failure mode that
   disqualified option (1). Note the expansion happens *after* the filter, so the recorded value must
   be the **pre-expansion** count.

### Fail-closed representation: `CDeclaredPrefix = CDPUnknown | CDPLen Int`

**Not `0`, not `Option Int`.** `k = 0` is a genuinely reachable *recorded* state (`registerMember`
guards on `ifaceMonos` being non-empty, **not** on `slots`), and `fromOption 0` is one idiomatic
invisible token — the collapse RUN-B-013 condition 1 forbids by name, with `fromOption` at 99 uses in
`compiler/`. `CDPUnknown` has no prelude eliminator and is a token found nowhere else in the tree, so
*"is any site collapsing absence into a length?"* is one grep. **Same reasoning as AD-2's carrier
ruling, arrived at independently, one bite over** — which is some evidence the reasoning generalizes.

## RUN-P3-024 — I MEASURED the prep's two arithmetic traps. One is WITNESSED; one is not

The prep named two ways `index < k` could mark an **appended** slot as declared, and flagged both as
needing a build. Per the standing rule — *a prep question only a build can answer gets the build
before dispatch* — I instrumented both sites in one build, then reverted.

**Trap 1 — `dedupSlots` shrinks the declared prefix: 🔴 WITNESSED.**

```
twice : (Shw a, Shw a) => a -> Int          -- one tyvar, duplicated constraint
runtime error [E-PANIC]: PROBE-F-M1 twice 2->1
```

Two declared slots collapse to one. **Recording `k = listLen slots` would mark the first APPENDED
slot as declared — silently, in the unsafe direction.** ⇒ `k = listLen (dedupSlots slots)` is
**mandatory with a witness**, not defensive, and the program above is a ready-made fixture.
⚠️ It fired **nowhere** in a full `make medaka` (the entire compiler + stdlib through the
typechecker): the shape is absent from the compiler's own corpus and reachable only from user source.
**A test that only compiles the compiler cannot catch a regression here** — worth stating, because
"the self-build is clean" is exactly the evidence someone would offer.

**Trap 2 — `pairSlots` truncation: UNWITNESSED.** Did not fire on a full compiler build or on the
two-module probe. Keep the `min k (listLen slots)` clamp (one token, free) and record it as
defensive. ⚠️ RUN-P3-015 claimed a mismatch *"clamps loudly"* — **it does not; nothing clamps it
today.** That was a third unverified claim in the same entry.

**The probe was fail-capable and demonstrated it** — silent across the whole compiler, firing on a
purpose-built control. A probe that never fires anywhere proves nothing, and this one was one
positive control away from being exactly that.
⚠️ Cost note for the next orchestrator: my first probe build failed on `/=`. **Medaka's inequality is
`!=`** — I copied the prep's Haskell-ism without checking, and it cost a build cycle.

## RUN-P3-025 — 🚨 `B-2.2-b1` IS TWO LINES. It has ZERO edits at the four `inst` arms

**DERIVED by the `b1`+`e` prep pass, and it inverts the bite's stated size.** Every ruling in this
sprint — D1's, RUN-P3-006's, RUN-P3-013's — describes `b1` as *"stamp identity at the four `inst`
arms"*. **The four arms need no edit at all.** All four call `keyForSite` / `keyForSiteByIface`, and
**the row selection and the collision gate are already inside those two functions**
(`:18430-18455`, `:19110-19121`). The arms contain nothing but `fromOption tag (…)`.

`b1`'s entire behavioural payload:

```
typecheck.mdk:18440   Some (implKeyTc ir.irName tys)
  →                   Some (implRouteKeyWord ir.irOrigin ir.irName tys None)
typecheck.mdk:19115   ditto
```

`ImplRow`'s third field is an `IfaceRef` carrying **both** `irName` and `irOrigin`, so **the origin is
already in hand at both sites.** Consequences:

- **RUN-P3-006's warning is correct about a design nobody now needs to build.** I ruled that *"`b1`
  must carry the collision gate, not merely project"* — the gate is already carried; `b1` changes one
  expression *after* it. There is no second `IE` traversal and RUN-B-023's +17% risk does not arise.
  ⚠️ Left in the ledger deliberately: the warning was sound, its premise was not.
- **RUN-P3-013's amendment is already implemented in the tree.** I ruled that `b1` must *"preserve
  the concrete head tag on the no-row arm"*. `fromOption tag` **is** that preservation, already
  written. The amendment was right and the edit it implied does not exist.
- **D5/D6's element routes are untouched by construction** — `b1` edits neither, so `b2`'s
  prohibition is honoured with no explicit guard. State it anyway: a future reader of a two-line diff
  cannot see that it was considered.

## RUN-P3-026 — the definition side is ONE function, and the safe commit split is by WORD, not by SIDE

**`ir/core_ir_lower.mdk:61` imports `implKeyOf` from `eval.eval`.** So `core_ir_lower`'s two mint
sites are *the same function* as eval's, not a third copy — **`e` is roughly half the size D1
implies**, and the seam is one string family with exactly two producers (`implKeyTc` caller-side,
`implKeyOf` definition-side).

**⇒ A single atomic commit is NOT required.** The atomicity is not `b1`-vs-`e`; it is *the two
origin-supplying edits*. Split by word **content**:

1. **Commit 1 — mirror deletion, provably byte-identical.** Point both mints at
   `route_key.implRouteKeyWord` passing `OriginUnresolved`; retire `rkEffAtom`'s lint directive
   (RUN-P3-021 named `e` its owner). Byte-identical by `route_key`'s own compatibility doctests.
   **Safe to build and publish.**
2. **Commit 2 — the origin, both sides at once. ATOMIC.** A tree with only one half moved builds
   clean, type-checks clean, and the skew is **invisible to every gate and live on the `RDict`
   path**. `b1`'s two lines live here.

### 🚨 `e` CHANGES A COLLISION VERDICT — and it means our byte-identical claim is FALSE as stated

`ifaceDeclHeadUnique` → `declKeysAtHead` dedups by **canonical key**, so making the key
identity-bearing changes that count. Two same-spelled interfaces in different modules, each with an
impl at head `T`: today both keys are `"Speak|T|"` → dedup to one → `unique = True` → the definition
side routes both under the bare tag, **while the caller side (`ieCountHeadByIface`, which counts
ROWS) already sees 2 and stamps `"Speak|T|"`. That is a live skew today**, masked only by
`implEntryRouteWords`' union arm. After the change the keys are distinct, `unique = False`, and the
skew closes.

⇒ **"byte-identical IR on programs with no head collision" is FALSE.** The defensible claim is
*"…no head collision **and no two same-spelled interfaces in the module graph**."* This goes in the
PR body; a green `diff_compiler_llvm` must not be read as proof of the wider claim.

## RUN-P3-027 — `KeyEntry`'s key field has NO READER; `e` must NOT touch two of D1's sites

`KeyEntry`'s 4th field is written by `keyEntryOf:18307` and `keyEntryOfRow:18962` (the latter in
**neither** D1's nine nor `b1`'s four) and **read by nobody**: every destructuring in the file binds
other fields, and `bucketKeyEntriesFrom` only rebuilds it. Independently DERIVED at field level, and
consistent with RUN-P3-007's finding that the `keyTable` family is inert.

⇒ **`e` skips both.** Editing them adds two origin-threadings with zero observable effect, enlarges
the diff on the file whose snapshot and LEG A goldens are the most expensive to move, and
manufactures the appearance that `implKeyTc` has four live callers when it has **two**.
**M4 (below) is the fail-capable confirmation — the grep alone is not.**

**The only real plumbing in `e`:** `lowerImplMethod` and `implMethodEntry` have **no origin
parameter**; their callers (`lowerDeclImpl`, `declImplEntries`) do not bind `implOrigin`. That is what
an implementer hits first.

**A grep-driven edit to guard against:** `wasm_emit.mdk:4090-4094` defines a *different function that
happens to share the name* `implKeyOf` (a local projection for `distinctImplKeys`). **Not a word
mint. Do not touch.** And `core_ir_eval.mdk:455` is a **consumer** — it is owed a *test*, not a patch,
which is worth stating because two rulings flag it as "the P0-9 shape omitted by P0-B" in a way that
reads as an owed edit.

## RUN-P3-028 — the `ppTy` fold IS constructible, and there is a FOURTH divergence

`impl I (<Stdout> Int)` and `impl I (Eq a => a)` are **grammatically legal impl heads** — impl type
arguments are parsed by the full type parser through a parenthesised atom. **The fold is not vacuous
at the parser.** The discriminating program:

```medaka
interface Sz a where
  sz : a -> Int
impl Sz Int where
  sz _ = 1
impl Sz (<Stdout> Int) where
  sz _ = 2
main = println (sz 0)
```

Today, DERIVED by reading the printers: **eval collides both impls onto one `(tag, key)` pair**
(`ppTyK` strips `TyEffect`; `headTycon` strips it too), so `findByTag`'s first-match scan makes
**declaration order decide** — while the typechecker stamps `"Sz|<Stdout> Int|"`, a word **no
definition-side entry carries**. Pointing eval's mint at `rkTy` de-collides the definition side.

⚠️ **A FOURTH divergence, not previously recorded:** `eval.headTycon` strips `TyEffect`/
`TyConstrained` to the inner head while `typecheck.headTyNode` does not — so even after the printers
are unified **the two sides still disagree on the TAG.** That is RUN-P3-014's `_ => None` wildcard one
substrate over. **`e` does not fix it; it goes in `unchecked:`.**

Whether either program survives resolve/coherence/typecheck is **not derivable** — it is M1/M2 below.
Both outcomes are complete answers, and a rejection makes the fold vacuous and `e` safe on this axis.

## RUN-P3-029 — the headline fixture has NOWHERE TO LIVE

`diff_compiler_llvm_typed_ir.sh` reads a **single-file** corpus; `diff_compiler_llvm_modules.sh`
grades **native stdout** against an eval golden, with no `.ll` golden anywhere. **No existing corpus
gives an IR golden for a multi-module program** — and the cross-module default-inheritance fixture
`b1` owes is exactly that. An owed design decision, not a fixture drop.
⚠️ A **new** `test/*.sh` trips the CI shard-coverage gate unless a shard pattern in `ci.yml` matches
it. Cheapest option: extend `diff_compiler_llvm_modules.sh` with an optional `entry.ll.golden`
sibling, adding no new gate file.

## RUN-P3-030 — my `sanitizeId` example was WRONG, and the prep refused it

I wrote (RUN-P3-019) that `a::Alpha|T|` → `a__Alpha_T_` collides with module `a_` + interface
`_Alpha`. **It does not:** `safeChar` maps each offending character to a **single** `_`, so `a_` +
`_Alpha` gives `a_::_Alpha|T|` → `a____Alpha_T_` — four underscores, no collision. The prep refused
to relay it and derived the real hazard instead:

**Module ids are loader-derived PATHS, and `.`, `/`, `-` all sanitize to `_`** — so
`a.b::Alpha|T|`, `a/b::Alpha|T|` and `a-b::Alpha|T|` **all** sanitize to `a_b__Alpha_T_`. A
pre-existing shape at *module* granularity that `e` newly exposes at *interface* granularity. And
the runtime word is `hashName key` (djb2), a **second, independent collision channel** that
`sanitizeId` reasoning does not cover at all.

**That is the third time this session a fabricated-but-plausible example of mine was caught by the
agent I handed it to.** The pattern is consistent: the *hazard* was real each time and the *instance*
I invented to illustrate it was not.

## RUN-P3-031 — the `ppTy` fold is MEASURED SAFE; and a FOURTH divergence is confirmed as a live S1

Ran in the quiescent window after `f` landed, before dispatching `b1`+`e` — the standing rule that a
prep question needing a build gets the build **first**.

**The fold (`e`'s largest unverified assumption): SAFE.** The worry was that pointing eval's mint at
`rkTy` widens eval's words, since typecheck's printer renders `TyEffect`/`TyConstrained` and eval's
strips them. **The widening is unobservable, because the program that would observe it does not
typecheck:**

```
impl Sz Int  +  impl Sz (<Stdout> Int)  → check=1 run=1
    "Overlapping impls of Sz: Int and Int can match the same type."
impl Sz a    +  impl Sz (Eq a => a)     → check=1 run=1
    "Overlapping impls of Sz: a and b can match the same type."
```

**Coherence strips the effect/constraint too** — the diagnostic says *"Int and Int"* — so two impls
differing only in an effect row or a constraint **cannot coexist**. ⇒ the fold cannot change any
accepted program's words. **`e` is safe on this axis, measured rather than assumed.**

### 🚨 F-8 — a NEW S1, found by asking the sharper follow-up

A *single* effect-carrying impl has no overlap to be rejected for. Measured, with a control differing
only in the effect row:

```
impl Sz (<Stdout> Int)  → check=0  run=0 [2]  build=1
    E-PANIC: no impl of method 'sz' for type '__none__'
impl Sz Int             → check=0  run=0 [2]  build=0  exec=0 [2]   @mdk_impl_Int_sz
```

**A program that checks clean and runs correctly cannot be built.** Mechanism: `headTyconTy` answers
`None` for a `TyEffect` head → `noneHeadTag` on the typecheck side, while eval/`core_ir_lower`'s
`headTycon` **strips the effect** to `Int`. The emitter then looks up `__none__` and finds nothing.
This is the **fourth divergence** the `b1`+`e` prep predicted — `eval.headTycon` vs
`typecheck.headTyNode` — now with a failing program and a control.
**`e` unifies the printers (word), not the head projections (tag), so this is unchanged by the
sprint.** Recorded in `FINDINGS.md`; filed at the exit phase.

## RUN-P3-032 — **`B-2.2-b2` is DROPPED.** Three independent reasons, and one of them is a finding

The prep pass recommended dropping and I accept it. RUN-P3-018 already flagged `b2` as first to shed;
this is that call, taken on evidence rather than on schedule pressure.

1. 🚨 **Its D4 pair is NOT "provably the same selection" — D1's ✅ is wrong at this pin.** The element
   leg's `selectReqImpl` has a live `iface == ""` arm that selects over a **different population**
   (`ImplBuckets`, first-match by **declaration order**, no-requires impls omitted) with a
   **different goal vector** (`[m]`, not `m::rest`) — and that arm is reachable from `EKNestedTop`
   through four `routeOf … "" ""` callers. **Collapsing there is the D5/D6 semantics change one leg
   over, arriving as a wrong VALUE at exit 0.** A correct `b2` would need an `iface != ""` guard D1
   never mentions, so the "two named pairs, provably identical" sizing is simply false: it is one
   clean pair plus a conditional one.
2. **The bite is no longer "pass the row down."** `keyForSite`/`keyForSiteByIface` now *are* the
   selector call — they select, collision-test and mint internally, returning `Option String` and
   discarding the row. `b2` would have to split both, then add a pre-selected-row parameter to
   `implDictRoutesForFull` and `argImplRequiresRoutes` — **the exact two functions `b1` is editing in
   this worktree right now.** A region collision, for an optimization.
3. **The win is smaller than billed and its premise is gone.** Each arm costs **three** IE traversal
   groups (select-for-word · collision count · select-for-elements), so `b2` removes **1 of 3, not
   1 of 2** — and RUN-P3-025 already established that `b1` adds no scan, so RUN-B-023's +17% is not
   being re-bought. Its byte-identical bar would cost a fixpoint plus an LLVM-golden round to
   establish.

**Filed as a follow-up carrying the D4 `iface == ""` finding**, so Phase 5 does not re-plan it off
D1's stale ✅.

### ⚠️ This gives RUN-P3-008 its first reachability path

The `ImplBuckets` second-deciding-population finding was DERIVED but had **no witness**. The prep
statically derived **four callers** that reach `selectReqImpl`'s `iface == ""` arm. That is not yet a
reproduction — but it converts "reachable in principle" into a named path the repair round can probe,
and it upgrades the priority of that experiment. **Still not filed; the discriminating program is
still owed.**

## RUN-P3-033 — **`B-2.2-c` LANDS**, and it grew a THIRD stale comment

`c` is the only bite that leaves the tree's measured-wrong comments corrected, and all of them were
relayed forward through design documents unverified — one of them twice. The prep found a **third**,
which nobody had flagged:

3. **`entailInst`'s header says `EKNestedTop → bare head tag`.** False since #203 — the arm stamps
   the canonical key of the min⊑ winner, bare only when the collision gate is False — and **its own
   body comment says so eleven lines later**, as does the `EntailKind` ladder comment. *Two of three
   descriptions of this arm are right and the one an implementer reads first is wrong.*

Two traps checked and **discharged with derivations rather than assertions**:

- **The fixture-line-count trap does NOT bite**, and the reason is worth pinning: the snapshot embeds
  the source verbatim but its **graded sections carry no source locations**, so a line-shifting
  comment edit diffs exactly the edited lines plus `source_lines=` — no cascade. No golden pins a
  line *inside* `typecheck.mdk`, and the two in-tree `typecheck.mdk:NNNN` citations from other
  modules sit **above** every edit site. ⇒ **Do not compress a correction to preserve line count.**
  The wrong-tier correction says strictly more than the error did, and the sentence that protects
  `fromOption tag` is precisely the one whose absence nearly shipped a break — **it must not be
  traded away for neutrality.**
- **#829 is not triggered.** The file's only three two-line-header *record* decls are >12 000 lines
  from every edit site; `KeyEntry`/`EntailKind` are two-line-header but **positional, not record**, a
  shape #829's measurement does not cover and the prep did not test. ⇒ one rule: **put no new comment
  inside `data EntailKind`'s body** — the ladder block goes above `entail`, a *function*, sidestepping
  the untested case entirely.

## RUN-P3-034 — the repair round's BASE ARM is built and verified, ahead of need

Both prior sprints improvised the base-vs-branch differential at the end. It is now warm:
**`/var/tmp/p3/base-arm`**, a worktree at the sprint base `68f84bf1`, cold-built (exit 0).

Verified as a **sound** arm rather than merely present — a two-worktree differential is only valid
because a `medaka` binary resolves its emitter and stdlib from **`exeDir`**, the directory the binary
sits in, not from cwd or the compiled file's project root:

```
exe-adjacent layout: medaka · medaka_emitter · stdlib · runtime   — all four present
                     (⚠️ `runtime/` matters only at the FIRST build; check and run
                      succeed without it, so its absence bites late)
crossing guard:      MEDAKA_ROOT and MEDAKA_EMITTER both unset
identity:            68f84bf1…  ·  run/build/exec all exit 0 → 12345
route_key.mdk:       ABSENT — the arm genuinely predates the sprint
```

That last line is the one that makes the arm trustworthy: a "base" arm that carried this sprint's own
new module would compare the branch against itself and report a reassuring nothing.

## RUN-P3-035 — parallel verification, corrected mid-sprint on Val's push

Four readers were dispatched against a live writer, all pinned to committed SHAs (`git show
<sha>:<path>`) so the writer cannot contaminate them — the Stage B pattern that ran ~10 such agents
with zero interference. **I had been serializing verification behind implementation, which is the
0.73× parallel-efficiency failure Stage B's retrospective measured and named.**

- **R-1** — adversarial review of `f` at its landing commit. Primary attack: *is the write set
  complete?* A sixth unmirrored site means entries reach the reader with no prefix and the next bite
  silently withholds identity there.
- **R-2** — **referee audit of the orchestrator's own ledger.** ~700 lines of my prose is the
  least-reviewed artifact in the sprint and it feeds the PR body and the #1113 close-out. Blocking
  first item: adjudicate the #1182-vs-#1047 framing (below).
- **R-3** — build the repair round's differential instrument **now**, graded on stdout rather than
  exit codes, written outside the repo and **labelled never-run** in its own header.
- **R-4** — tracker-vs-tree reconciliation, so the exit criterion *"every verified desk close
  executed or handed to a named owner"* has a worklist.

### ⚠️ A claim of mine now under adjudication: **"this fixes #1182"**

The `b1`+`e` implementer's in-tree prose disputes a framing I have repeated throughout this ledger
and in two packets. Its argument: **#1182 is two interfaces sharing a METHOD name**, selected by a
`(method, head)`-keyed candidate set with **no interface component** — so qualifying the *word*
does not change which row is selected. What the substitution actually fixes is the **#1047 family**:
two same-**spelled** interfaces in different modules collapsing onto one route word.

That reasoning looks right to me, and if it is, **the PR body would have claimed a fix we did not
make.** I am not taking my own word for it: R-2 adjudicates it from the source side and R-4 from the
tracker side, independently. **Two derivations agreeing is worth more than either alone** — and if
they disagree, that disagreement is itself the finding.

**The reachability property `c` inscribes was VERIFIED, not asserted** — every selector call site was
enumerated, and one legitimate selector call **outside** the ladder (`concreteReqMatchByIface`, the
obligation channel) is named in the comment so a future grep-based check does not read it as a
violation.

---

# RUN-P3-036 — the parallel review round: `f` HOLDS, my ledger did NOT

Four readers ran against the live `b1`+`e` writer, all pinned to committed SHAs. **Zero
interference** — the Stage B pattern, reproduced. Their findings, and what I did about each.

## R-1 — adversarial review of `f`: **VERDICT: `f` HOLDS**

No defect makes the sidecar wrong, vacuous or non-inert. Six claims were attacked and held, each
with a derivation I did not have: write-set completeness (including non-`setRef` routes — **there is
no missing companion**), the two-valued read discipline (**zero consumers of the prefix**, so nothing
can collapse it), the `declaredConstraintSlots` refactor's byte-identity (via
`qualConstraintKey ≡ hasImportDefiner`, an *identity* not a contingency), the four generalizations'
behavioural neutrality, the two-row ratchet claim, and — the one it most expected to break —
**`dedupSlots` key identity across the write/expand seam**: `dedupBy` is stable first-occurrence, so
dedup of a concatenation preserves the first operand's dedup as a **literal prefix**. It holds on a
real property, not a coincidence.

**Three findings I acted on:**

1. 🚨 **The dict-pass sites leave a STALE prefix, not an absent one — and "absence here is correct"
   is the premise `f` shipped with.** `resetState ()` fires at exactly two sites, **neither** between
   the last `checkBodyImpl` and `dictPassModules*`, so the declared table still holds the *previous
   module's* entries. A reader there gets a **present, wrong** prefix — the one state `CDPUnknown`
   exists to make impossible. **Fail-closed is not achieved by not writing; it requires writing
   `[]`.** No impact today (no readers) or for `b1` (its fill sites run during inference), but the
   next bite to touch the define side inherits a silent wrong answer. **Relayed to the live
   implementer as a one-token fix.**
2. 🚨 **My commit message for `f` over-claims, and the waiver it licensed is invalid.** *"typed IR
   byte-unchanged"* rests on gates whose corpus is **54 single-file, prelude-free fixtures** — so the
   qual arm, both module seed/snapshot pairs and the joint-discovery snapshot are **never reached**.
   It covers ~1 of 6 changed regions. **Corollary: `f`'s `DEBT.md` waived the fixpoint on those
   grounds. That waiver does not survive.** The fixpoint is **not optional** for this sprint.
3. **`CDeclaredPrefix`'s doc comment is false on a live path** — it defines the prefix by *"its own
   `=>` context"*, but `setFunConstraintEntry`'s second caller mints from **inferred** ids with no
   `=>` anywhere, recorded as `CDPLen`. Behaviour right, definition wrong, **and wrong in the
   direction that invites an unsafe "fix"** (lowering the inferred path would withhold identity from
   real slots). Relayed with a reword.

Also: `lookupAssoc` calls **`opBump`**, so the read side moves the perf gate's op-count metric by
~one table scan per constrained call site — for a value nobody reads. Not quadratic; owed a perf run.

**And the close-out expectation it derived**, which the `f` commit note got half-right: the LEG A
re-cut is **4 deletions + 4 additions + 5 MODIFIED rows**. The commit warned about deletions; **the
five modifications are what `AGENTS.md` forbids by default.** Reviewer's check is not *"were rows
deleted"* but *"is each modified row a strict generalization, old type an instance of new at
`a := List X`, and nothing else moved"* — with `declaredConstraintSlots` and `qualConstraintFor`
required to be **unchanged**. A sixth modified row is a regression.

## R-2 — referee audit of my own ledger: **TWO BLOCKING FINDINGS**

1. **The `#1182` attribution is wrong in NINE places, and my A-packet is the origin** — the `a`
   implementer copied my sentence verbatim into the tree. Adjudicated twice, independently, both
   against me. #1182's selection runs on `contains name ms` (method-name membership + head match,
   **no interface component**) and the word is minted *downstream of the already-selected row*; in
   #1182's own single-file repro **the word does not even move**. The substitution serves the
   same-**spelled**-interface family — **#1047 (CLOSED)** and its open successor **#1265** — and the
   citable ticket is **#1113**. **Corrected in all nine.** Worse than a wrong ticket: the sprint
   contained **both framings simultaneously**, in two of my own packets, with no cross-reference —
   whichever got quoted into the PR body would have won by accident.
2. **ZERO in-place supersede markers existed** — and RUN-P3-019's own parenthetical reads
   *"(marked, not deleted — an unmarked superseded ruling is how a ledger starts lying)"* while
   marking nothing. **The sentence stating the rule broke the rule.** Worst instance: RUN-P3-018's
   gate table, a `#`-heading reading "GO", with **all six rows stale**. **Fixed:** a supersession
   table at the gate, in-place markers on RUN-P3-005/006/015, and the two live-sounding `csDeclared`
   claims struck where a grep lands.

Plus two contradictions, both fixed: `DEBT.md` said `rule-duplicate-body` was *"deliberately left
un-silenced"* when the directive is committed at `route_key.mdk:230` (the row predated my ruling and
was never updated); and `FINDINGS.md` still advertised the repro harness as **owed** after
RUN-P3-022 had discharged it — *"discharged debt looking owed"* invites a future agent to re-spend a
quiescent window. Also flagged: `fromOption` "99 **uses**" is 99 *lines*, 78 occurrences (the design
argument survives either); and `DEBT.md`'s "374 lines" is 396.

⚠️ **One claim R-2 could not verify and neither can I from the artifacts: the "15 reading sites"** —
the entire justification for refusing the design of record. The table lives in an agent report that
**does not ship with the PR**. **Owed: paste it into RUN-P3-019 or give the reproducing command.**

## R-3 — the repair round's differential, built ahead of need

`/var/tmp/p3/r3/` — 15 programs, 52 files, **never run** (stated in its own header and reprinted on
every invocation). Not in the repo yet; I smoke-test it in the next quiet window before it is cited.

Shapes worth naming: a **control** (p01) whose failure prints *"THE HARNESS IS SUSPECT — do not
adjudicate any other row"*; a **bystander** (p15) where the colliding graph is present but the entry
prints from an unrelated module — `AGENTS.md`'s *"feature works, unrelated code breaks"* shape, and
a DIFFERS there outranks every other row; and both nearest-miss controls (F-2's function head, F-8's
effect head) expected to be **equally broken on both arms**, since `e` unifies printers, not head
projections.

Refusals rather than warnings (exit 2, before any measurement) for: `MEDAKA_ROOT`/`MEDAKA_EMITTER`
set (they cross both arms silently), both arms resolving to one directory, and a missing
`runtime/medaka_rt.c` — the last with its "bites only on the first `build`" note. A
**`both arms failed check`** counter exists because a corpus of unparseable programs would otherwise
report a clean all-SAME. And an **`EXITONLY`** verdict annotated *"loud → quiet is a severity
increase, not progress."*

## RUN-P3-037 — tracker reconciliation (R-4): four desk closes, one anti-close, five omissions

### The #1182 adjudication is CLOSED — three independent derivations, all against me

R-4 derived it tracker-side, R-2 source-side, the implementer in-tree. All three agree, and R-4 adds
the fact that reframes the replacement: **#1047 is CLOSED**, so "the #1047 family" means its live
members — **#1265**, **#1514**, and the bare-compat leg of `oblIfaceKeys`. Citable ticket: **#1113**.
All nine instances corrected.

### Desk closes: **#1512 · #1557 · #1558 · #1559** — four Stage A units implemented and left open

Each derived, not relayed: `universeIfaceRequiredRef` survives only as **11 comment tombstones, zero
code sites**; `ieCandidacyVisibleAt _ _ = True`; `checkCoherence` now takes `ImplEnv` and `CohImpl`
carries an `IfaceRef`; #1512's three owed fixtures all exist at HEAD. Precedent for closing ARCH
units on landing rather than holding them: #1446 and #991.

⚠️ **#1558 must carry its re-scope into the close comment.** It landed as an owner-ruled **split, not
the deletion its body specifies** — `test/registry_keying_ratchet.sh` says so in its own words:
*"A-3.6 (#1558) HAS LANDED AND IT WAS NOT A DELETION."* Close it silently and the next reader takes
the title as evidence the name axis flipped too. It did not.

### 🚨 ANTI-CLOSE: **#994 must NOT be closed — and this sprint WIDENED it**

`#994`'s third bullet is that CrossRun's mirror pairs should reset *"only by whole-record re-mint."*
At HEAD there are **eight lockstep `setRef`s at one site** — and **two of them are `f`'s**. PR
#1605's *"Implements B-3 (#994)"* is true of the PerRun pairs and **false of the CrossRun snapshot**.
Closing #994 on that PR body would bury a live drift surface **that a `b1` bug would land squarely
on**. This is the partial-identity-reads-as-done shape, and my own bite is now part of it.

### #1113's body is STALE in a way that would corrupt the close-out

Updated 2026-08-09 — before Stage A merged. Two consequences:
- Its *"depends on Stage A"* dependency is **discharged** (Stage A merged 08-12).
- Its *"Drains #1072/#1071/#1062"* line is **already two-thirds spent**: #1072 and #1071 are
  **CLOSED**, drained by *Stage B*, not by B-2 (#1071 as a duplicate of #1062). **B-2's remaining
  drain claim is #1062 alone — and #1062 is EVAL-ONLY**, which nothing in B-2.2's route-word half
  touches. **The close-out must not cite #1062 as drained by this sprint.**

Also: #1122's serialized lane still reads as though B-2 were gated behind U2/U4, which have not
landed and are being overtaken.

### FINDINGS → tracker, dedup done properly (title AND body, open AND closed)

| row | routing | why |
|---|---|---|
| **F-6** | 🎯 **ALREADY COVERED — cell on #347** | #347 is OPEN, `needs-repro`, and says *"nobody has built two modules whose paths differ only in a separator char."* **F-6 supplies exactly that missing derivation.** A duplicate avoided outright |
| **F-1** | cell on **#1450**, ⚠️ **conditional** | no issue covers a user interface method colliding with a prelude interface **method** (the neighbours are all prelude *standalones*). But see OWED-2 |
| **F-2 / F-8** | **file separately** | same root arm, **different fixes**: F-2 needs `TyFun` to get a tag; F-8 needs two projections to agree. Merging them would give one pin two fixes |
| **F-3** | **do not file** until reproduced | checked against #1265 (defaults only), #1530 (re-export), #1182 (order-dependence) — no match, but it is unreproduced |
| **F-4** | file, labelled derived-not-measured | one search hit, closed, different subject |
| **F-5** | repair round first; may be a **cell on #1154** | `pickMostSpecificEntry`'s first-declared arm is the same shape |

🚨 **OWED-2 gates F-1's routing, and the failure mode is specific:** F-1's *"same mechanism as
#1450"* is **symptom-matched, not IR-derived** — #1450's own filing read the arity off the IR. If the
param count is correct with a wrong value, it is a **different mechanism** and the cell would **bury
a second defect inside #1450**. Derive before filing: `build --keep-ir`, then
`grep 'define .*_sub('`.

### Five tracker facts my ledger never recorded (a grep of all three artifacts found three hits total)

1. **#1068** — #1113's blast list says its fix *"would build in wasm the superset arm this task
   deletes; **do them together**."* RUN-P3-003 independently re-derived wasm's separate family
   **without citing #1068**. `e`'s `engines:` clause owes the issue number, or the wasm arm ships an
   un-owned divergence.
2. **#1608** — filed *by the previous sprint*, S1, **un-pinnable**: `core_ir_eval` selects a
   cross-module impl by **import order**. It is `eval.mdk`'s lockstep peer, a file this sprint edits.
   **Any `b1`/`e` fixture asserting on `run` in a cross-module shape may be measuring #1608.**
   Relayed to the implementer.
3. **#1127** — its repro carries an `assum`-vs-`super` control that is **exactly the P4 axis** the
   new dict fixtures pin. Adopt it rather than authoring fresh. Relayed.
4. **#1180** — a known-wrong `noneHeadTag` bucket sitting **under `b1`'s preserved fallback arm**.
   Belongs in `DEBT.md`.
5. 🚨 **A THIRD `headTyconTy` asymmetry:** `eval.mdk:~546` also strips **`TyConstrained`**. F-2 and
   F-8 are **two of three**. I wrote *"audit the arms as a SET"* and then shipped a set one arm
   short — the lesson failing inside the sentence that states it, for the second time this sprint.

## RUN-P3-038 — two OWED measurements run on the BASE ARM, while a writer held the trunk

Both are language-level questions about defects present at base, so the base-arm binary answers them
and the live `b1`+`e` writer cannot contaminate them. This is the parallel-verification pattern
applied to *measurements*, not just reading.

### OWED-2 — **F-1's routing is CONFIRMED: a cell on #1450, and it is now IR-derived**

R-4 flagged that F-1's *"same mechanism as #1450"* rested on a **symptom** (leaked pointer at exit 0)
where #1450's own filing read the **arity off the IR** — and that if the arity were correct, a cell
would bury a second defect inside that issue. Measured:

```
zub (control): define i64 @mdk_impl_T_zub(i64 %arg0)              ← ONE param, correct
sub          : define i64 @mdk_impl_T_sub(i64 %arg0, i64 %arg1)   ← TWO
               (cf. define i64 @mdk_impl_Int_sub(i64, i64) — Num.sub's arity)
```

The user interface declares `sub : a -> Int`, **arity 1**. The emitter defined its impl with
**`Num.sub`'s arity 2**, and the call site passes two args to match. **That is #1450's mechanism
verbatim, read the way #1450 read it.** F-1 files as a cell, no longer symptom-matched.

### OWED-3 — **F-5 did NOT reproduce, and the probe did NOT discriminate. Both halves matter.**

A nested `requires` chain (depth ≥ 2) with two impls of one interface at the same head where
declaration order and min-specificity **disagree** (`Base (Wrap a)` = 1 vs `Base (Wrap Int)` = 2),
and a swapped-order twin:

```
ab: check=0 run=0 [2] build=0 exec=0 [2]
ba: check=0 run=0 [2] build=0 exec=0 [2]
```

Correct by min-specificity is **2**, and both orders answer 2 on every channel. Min-specificity won;
order did not decide.

🚨 **This is NOT evidence that F-5 is absent, and recording it as such would be the exact error this
sprint keeps catching in others.** F-5 is about `selectReqImpl`'s **`iface == ""`** arm, which the
prep derived is reached from `routesOfMonos*` via `routeOf … "" ""` — the method-dict / untyped
fallback leg. **My program goes through `entail EKNestedTop` with `iface != ""`, i.e. very likely the
OTHER arm.** I did not instrument it, so I cannot claim it reached the target.

⇒ **A probe must discriminate, not merely answer.** Mine answered. **F-5 stays open and stays
assigned to the repair round**, now with a *negative* result on the `iface != ""` path (useful: it
bounds the claim) and an explicit note that **the `iface == ""` path is still unprobed** and needs a
program that reaches `routesOfMonos`, or an instrumented build to confirm the arm was entered.

## RUN-P3-039 — the close-out checklist, and three corrections it makes to this ledger

`CLOSE-OUT.md` (590 lines, 5 sections) now exists so Phase 2 and the exit phase are **executable
rather than reconstructed from ~1500 lines of narrative** — which is what the referee's
"six owed follow-ups with no owner" finding actually demanded.

**Owed sweep: 6 named → 4 still owed, 2 DISCHARGED.** The instruction to *verify each is still owed*
was the highest-value line in the brief: it caught two items that would otherwise have been
advertised as debt (RUN-P3-029's homeless fixture — solved by the `b1`+`e` writer without an IR
golden or a new `test/*.sh`; and F-3, since reproduced first-hand). **Six further unowned items were
found by sweeping and assigned. Nothing is left unassigned.**

### 🚨 Correction 1 — the differential harness HAS been run, and its CONTROL IS RED

`/var/tmp/p3/r3/run1.log` shows **11 DIFFER rows**, and **p01 — the control that must be identical —
differs on `build`.** The two texts differ **only in the arm name inside the output path**: a
`normalize()` gap, not a compiler delta. **And the harness's own "normalization leaks: 0" counter
missed it** — the tripwire built for exactly this failed to fire.

⇒ **No row in that run is adjudicable.** This is precisely why the control exists, and precisely why
"all-SAME is also what a harness that ran nothing prints" was written into R-6's brief. R-6 is
mid-repair on it. **Note also that my own report a few beats ago described the harness as "never
run" — it had been run ~an hour earlier; the ledger was stale by one agent-lifetime.**

### Correction 2 — `--new` takes NO path argument, and has historically lied

It is **suite-wide** (`:138`), and under `--new` the summary has historically read *"all snapshots
match"* **having compared nothing**. `route_key.mdk` needs a snapshot CREATE at the close-out, so
this is directly on the path. Three guards are written into the checklist's step 5b.

### Correction 3 — `ir.core_ir_lower` is NOT in the LEG A corpus

The landed `DEBT.md` row for `b1`+`e` says *"all three edited modules are LEG A."* **It is two.**
Erratum owed on that row; the close-out's expected LEG A diff (**4 deletions + 4 additions + 5
MODIFIED**, with `declaredConstraintSlots` and `qualConstraintFor` required **unchanged** and a sixth
modified row a regression) is unaffected.

### One window that has now CLOSED

**#1068** — the arc says its fix must be done **together** with the wasm arm, and `e`'s `engines:`
clause is now committed **without citing it**. The cheap moment is gone; it is assigned to the
orchestrator as a follow-up rather than pretended to be in scope.

## RUN-P3-040 — a process hazard I created, recorded so it is not repeated

**Blanket `git add .claude/sprint-phase3` while an agent is writing into that directory sweeps in a
half-finished file.** `CLOSE-OUT.md` was captured mid-write by the F-3 commit (`b2daac7d`) and
finalized only in `c2d89c44`. No damage — the full 590 lines are committed and the working tree
matches — but **`b2daac7d` contains a partial file its message does not describe**, which is the
"title must match the body" discipline failing one level down.

**Remedy, effective now: stage sprint-record files BY PATH while any agent has that directory open**,
never by directory. The same rule already applies to `DEBT.md`, which has had two concurrent writers
and which the `b1`+`e` implementer flagged for exactly this reason.

---

# RUN-P3-041 — `B-2.2-c` LANDED (`655991f2`); PHASE 1 COMPLETE. And `c` refused my property.

All bites are in: `a` (`cd1f2c8d`) · `f` (`d5948e3a`) · `b1`+`e` (`ec1cda37`) · `c` (`655991f2`).
`b2` dropped (RUN-P3-032).

## 🚨 The property I specified for `c` was FALSE, and the implementer refused to inscribe it

I gave `c` this absolute: *"No selector call may be reachable from `entailAssum*` or
`entailFallback`."* **The second half is false at this pin.** `entailFallback` →
`undeterminedRoute` → `routeUndeterminedTop` → `argImplRequiresRoutes` → `selectReqImpl` **is** a
selector call reachable from `entailFallback`.

**Inscribing it would have written a property the tree violates on its first read** — into the one
bite whose entire purpose is leaving behind sentences the next refactor cannot silently violate.

**RULED: the implementer's amendment stands, and is better than what I asked for.** It states the
`assum` trio as an absolute (the whole chain enumerated: every arm is a `perRun` registry lookup)
and names the fallback path as a **derived non-violation** — that rung answers its own goal by
**COUNTING** (`implHeadTagsForIface`; exactly one, else `T-AMBIGUOUS-INSTANCE`), never by selection,
and only then routes the chosen impl's nested `requires` as a fresh sub-goal descending the ladder
again. The forbidden shape — the fallback rung answering the ladder's own goal *by selection* — is
stated explicitly, and `KeepNone` cannot reach even this path.

⚠️ **My packet claimed the property was "verified at the pin by enumerating every selector call
site."** That enumeration stopped at `entailFallback`'s **own body** rather than following to the
leaves. **This is the SECOND "verified by enumeration" claim in this sprint that stopped short of the
leaves** (the first: the "15 reading sites" table). ⇒ **An enumeration claim must state its DEPTH.**
"I enumerated the call sites" and "I followed each to its leaves" are different claims and this
sprint has now conflated them twice.

# RUN-P3-042 — adversarial review of `b1`+`e`: **THE BITE HOLDS**, on a stronger argument than mine

**The by-construction claim is DERIVED TRUE, structurally.** `implRowsOf` is the **only** `ImplRow`
construction site, and its `IfaceRef` comes only from `implDeclFact`, which is literally
`IfaceRef { irName = iface, irOrigin = implOrigin }` off the `DImpl` — while the definition side
destructures `implOrigin` off **that same `DImpl`**. ⇒ **the caller's `ir.irOrigin` IS the definition
side's `implOrigin`: same field, same decl, one hop.** My brief framed these as two independent
sources; they are not, and the reviewer notes that handing it that one line would have collapsed 45%
of its time into a confirmation.

**And it survives the pathological case:** #1288's re-export merge makes `implOrigin` *wrong* — but
**identically wrong on both sides**, so agreement is unaffected. Nine attacks held in total,
including one the reviewer **retracted** after chasing it (a tuple-rendering divergence that
dissolved when `joinComma = joinWith ", "` turned out to be the same function).

## 🚨 F-1 (S2, CLOSE-OUT BLOCKING) — the acceptance fix loses its only test at close-out

**The only landed test of this bite's *acceptance* fix is the must-fail fixture — and the `DEBT` row
instructs the close-out to close #1514 and remove it.**

The five new `dict_fixtures/` rows pin the **wire format** (a module prefix appears in a symbol), not
the **behaviour**: the colliding-heads fixture separates its two impls by **type argument**
(`Box Int` vs `Box String`), which **the pre-bite word already separated**. The `base::` prefix is
decoration in that program — nothing in it would behave differently if the prefix were absent.

⇒ **Delete the must-fail pin without promoting its program and the tree has ZERO regression coverage
for "two same-spelled interfaces select correctly" — the thing this bite actually fixed.**

**Close-out requirement (blocking): promote #1514's program into `test/dict_fixtures/` as a value row
BEFORE deleting the must-fail pin.** The gate already takes multi-module directory fixtures.

## Adjudication: **"no seed re-mint owed" is SOUND** — and the derivation is worth keeping

Not the confusion I was guarding against. From the harness: **the seed IS the native emitter's
emission of the build driver's own graph — i.e. exactly `IR1`.** C3a asserts `IR1 == REF` where `REF`
descends from the committed seed. So *"C3a green"* and *"`refresh_seed.sh` would rewrite the seed
with identical bytes"* are **the same proposition on this harness.** Riders: `git show --stat
ec1cda37` touches **no `compiler/backend/*` file**, so there is no codegen change to converge; and the
residual C3a cannot see is a word that moves only in a program the compiler's own graph lacks.
⚠️ **My commit message gave the unqualified claim.** The repo rule is to say **which** C3a; the DEBT
row does (`IR1 byte-identical to the seed-bootstrapped reference`), the commit message does not — and
the commit message is what a bisecting reader greps.

## #1514's drain is REAL and CAUSAL, and its nearest miss is named

Pre-bite the two sides **actively disagreed**: `declKeysAtHead` deduped both impls onto one key ⇒
`ifaceDeclHeadUnique` True ⇒ definition side registered under the **bare tag**, while
`keyForSiteByIface` counted **rows**, saw 2, and stamped the canonical key. Caller word ∉ the
emitter's union ⇒ fallback tier ⇒ first-impl-wins. Post-bite the keys are distinct ⇒ `unique` False ⇒
the caller's word is a direct hit. **A causal fix, not a shape move.**

**Nearest program still wrong** — from the tree, not invented: the same two modules with
**method-less impls inheriting an interface default**. `mdk_default_<method>_<TAG>` has **no
interface component**, so two same-named defaults share one symbol; `core_ir_lower.mdk:1296-1300`
says so verbatim and calls it **#1265, still open**. eval escapes via `defaultCellName ifaceId
method`; the native emitter has no such escape.

## Two more findings

- **F-2 (S3):** two of the three `typecheck_compiler_source.sh` allowlist entries are **FILE-grained**
  on a file that is **no longer inert** — `b1` moved `route_key.mdk` into the import closure **in the
  same commit that added an entry justified by its inertness**. `typecheck.mdk`'s equivalent entry is
  line-grained by a companion check; this one has none. Narrow it or add the companion.
- **F-3 (S3, watch):** loader-derived module ids now reach an **emitted LLVM symbol**
  (`@mdk_impl_base__Base__Box_Int___btag`). **#1223 is OPEN and MEASURED still reproducing** — an
  import-bearing file's loader id is first-root as an entry and last-root as a dependency. Scoped
  honestly: within one `medaka build` there is one loader run, so this is **not** a live miscompile;
  what it is, is IR goldens whose expected symbol embeds a path-derived id, and a new coupling
  between an open loader defect and object-file names.

## RUN-P3-043 — OWED-1 DISCHARGED: no tree-wide prelude symbol move

The adversarial review closed eight of nine attacks on paper and named **one link it could not**:
`declKeysAtHead`'s dedup exists because *"a re-imported prelude impl appears in the joint decl list
twice under ONE key"* — and after `e` that premise requires both copies to carry **identical
`implOrigin`**. If any path re-stamped a shared decl per module, the copies would diverge, the count
would become 2, `ifaceDeclHeadUnique` would flip **False for a prelude interface**, and symbols would
move **tree-wide**. C3a would catch that only if the compiler's own graph happened to hit it.

**Measured on the two pre-built arms** (no rebuild; a writer holds the trunk). Two modules both
importing `map`, so prelude impls reach the joint decl list from two places:

```
base   → build 0, exec 0 [25], 253 distinct @mdk_impl_ symbols
branch → build 0, exec 0 [25], 253 distinct @mdk_impl_ symbols
symbol-set diff: IDENTICAL
```

**⇒ The dedup premise holds. No prelude symbol moved.**

### The positive control, and why this is not a vacuous null

A null result proves nothing unless the probe *could* have been non-null. **It could**, and the
control is already measured: `p11_sanitize_collide` on **this same branch binary** emits
`@mdk_impl_a_b__C_Int__m` — a module-qualified symbol. So the branch arm demonstrably qualifies
symbols when the collision gate fires. Here it does not fire, because prelude impls are unique per
head and take `routeWordFor`'s bare-tag arm.

⚠️ **Honest scope:** this is a **consequence-side** check (did symbols move?), not an instrumented
check of the mechanism (do the two copies carry the same origin?). That is the preferred direction in
this tree — verify the consequence, not the mechanism — but it means the finding is *"no observable
divergence on a program that exercises the shared-prelude path"*, not *"the origins are provably
identical at the source level."*
⚠️ Also recorded because it cost a round: my first probe used `map.empty`/`map.insert`, which that
module does not export. **Both arms failed identically**, which is exactly the vacuous-both-arms-fail
shape the differential harness had to grow a counter for — a probe failing the same way on both arms
carries no signal and must not be read as agreement.
