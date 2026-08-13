# P0-FABLE — Does the §1 cut deliver C4/I2 BY CONSTRUCTION, as the conjunction?

**Consult:** Fable, Phase 0, read-only. Branch `arch/stage-b-sprint`, BASE `2b9dc798`.
Every citation below was read first-hand in this worktree at that BASE; line numbers are from
`grep -n`/`sed -n` runs in this session, not inherited from any doc.

---

## VERDICT: ⚠️ CONJUNCT-2-ONLY **as the cut is WRITTEN** — gap at the ROUTE STAMPER's second
## cumulative table (`ImplBuckets`). Closable inside this sprint's scope. **NOT 🔴 NEEDS-B-1.**

One sentence: the sprint doc repeats A-3's structural failure one organ downstream — B-2.1
names the deletion of `KeyBuckets` (the evidence *reader's* registry) but not the retirement of
**`ImplBuckets`**, the *route stamper's* registry, which is built per module from the **same
cumulative topological-prefix universe** and carries a **first-match** fallback. Identity stamped
at `inst` (B-2.2) from an order-sensitive table is an order-sensitive identity: conjunct 1 gets
fixed in one registry while conjunct 2 is minted from a second cumulative one — the exact shape
RUN-045 measured for A-3 (`.claude/sprint/DECISIONS.md:1269-1290`: *"the evidence reader consults
a second, still cumulative registry"*).

The gap is **already sanctioned as B-2 work** by the architecture doc
(`compiler/TYPECHECK-TARGET-ARCHITECTURE.md:1820`: `buildImplTable`/`implEntryOf`/`findImplEntry`
— *"per-run bucket table keyed by bare iface+tag, consumed by `entail`/`routeOf`"* — *"DEFERRED →
B-2 … `IE` supplies the data, B-2 moves the reader"*). So this is a **scope-statement defect in
the sprint doc**, not new scope. But an implementer executing `STAGE-B-SPRINT.md` §1 literally
(B-2.1 row, line 68: repoint `concreteReqMatchByIface`/`findMatchingImplReqsU`, delete
`universeKeyBucketsRef`/`KeyBuckets`/`keyForSite*` — nothing else) satisfies every named bite and
ships the gap. A-3 was believed to deliver C4/I2 and delivered half because the two conjuncts
live in different organs; here they live in different **tables**, and the cut names one.

---

## The organ table

For each organ a goal's resolution passes through: what pins it to the **global instance set**
(conjunct 1), and what pins it to a **canonical evidence term** (conjunct 2). A gap = "nothing,
or a cumulative/order-sensitive structure" in either column.

| # | Organ | Sites (read this session) | Pinned to global set by | Pinned to canonical evidence by | Verdict |
|---|---|---|---|---|---|
| 0 | Candidacy | A-3's global `IE`; unrouted case rejects `T-REQUIRES-UNROUTED` (RUN-045/047) | A-3 (delivered) | n/a (candidacy is conjunct 1) | ✅ inherited |
| 1 | Evidence reader | `concreteReqMatchByIface` ← `findMatchingImplReqsU` (`typecheck.mdk:21696-21698` per sprint doc §Phase 2; RUN-045 mechanism) reading `shadowKeyTableRef` ← `universeKeyBucketsRef` (cumulative) | **B-2.1** repoints onto `IE` | `min⊑` at the repointed reader; ⚠️ the tie-break inherits the **declaration-index defect** (`typecheck.mdk:17743`, indices duplicate across modules, violating `mergeByDeclIdx`'s precondition) — already a named Phase 0 desk item | ✅ once B-2.1 lands **and** the tie-break ruling is written |
| 2 | **Route stamper** | `elabModuleStamp` builds `stampImplTable = buildImplTable implDecls` (`typecheck.mdk:28677`) where `implDecls` = *"core + every EARLIER module + this module"* (`:28667-28668`; also `:25575`) — the comment at `:28065-28067` says it in words: *"impl-body universe (`accAll ++ prog`, **order-observable** through buildImplTable/buildKeyTable/resolveSites)"*. Consumed by `routeOf`/`routeOfD` (`:19078-19095`) and all the resolve\* stampers (`resolveSites`/`resolveArgStamps`/`resolveDictApps`/`resolveRLocalSites`, `:28682-28690`). `findImplEntry` is **first-match** on the iface-`""` fallback (`:17578-17580`, `:18874-18883`, `:19253`), and `implEntryOf` **omits no-requires impls** (`:17613-17616`) — a matching set that is not `IE`'s | **NOTHING in the sprint doc.** §1 B-2.1 (line 68) deletes only the `KeyBuckets` family; `ImplBuckets` is unnamed in §1 and in Phases 2-3 | **NOTHING.** Worse: the #203 repair put the stampers' `min⊑` (`matchedEntry`/`selectImplEntryByIface`) **on KeyBuckets** (`:17580-17584`) — the table B-2.1 DELETES — with *"forward order still decides their tie-break when no unique min⊑ exists"*. Delete KeyBuckets without re-basing these onto `IE` and the stampers either break or fall back to the first-match, requires-only, cumulative `ImplBuckets` | 🔴 **THE GAP** |
| 3 | Route payload | B-2.2: `Route` carries `InstId \| DictParam k`; identity stamped where `inst` runs; min-specificity only at `inst` (sprint doc line 69, Phase 3 lines 169-175) | correct **iff** organ 2's input is `IE` | the two-constructor route is **sufficient for all three discharge kinds** under today's flattened supers (see below) | ✅ conditional on organ 2 |
| 4 | **Super-slot fill** | `expandSupersTable` (`typecheck.mdk:9020-9043`) appends one sibling dict slot per transitive super; its own comment: *"Because the dict **VALUE is just a type tag** (`VDict "Widget"`), **the super slot's route is identical to the sub slot's** — no separate projection is needed"* (`:9027-9030`) | the fill goes through the ordinary entailment → inherits organs 0-2 | 🚨 **the copied-route invariant is valid ONLY while dict words are bare type tags — B-2 is the change that falsifies its own premise.** Once words carry construction-site identity (B-2.2) and engines key on identity instead of (iface, tag) (B-2.4), a super slot carrying the SUB instance's identity is the wrong dict — a **C2 violation minted by the run itself** (DICT `:1278-1297`: `supers.D` must be the most-specific `D`-instance at the construction goal). The fix is per-slot independent entailment of the super goal at the construction site — which C2 says **is** the canonical answer (*"`supers.D` **is** built by that same resolution"*, `:1283-1284`) | ⚠️ conditional gap — one bite, in-scope, **not B-1** |
| 5 | Admissibility | B-2.3: per-(class, position), computed once post-K from global `IE`, frozen as data, at §5's actual condition (DICT `:957-971`; sprint line 70 + Phase 4's ⚠️ on the wrong paraphrase) | post-K from `IE` — by construction | frozen data, consumed never re-derived — by construction | ✅ **but scoped**: #1046/#1075 local-lambda sites keep arg-tag until F-1 (sprint lines 82-84; arch `:743`) — the C4/I2 claim must name that residual |
| 6 | **Default-arm registry** | `ifaceIdsAtTag`/`defaultOwnedBy`/`narrowDefaults`/`CImplDefault` (`core_ir_lower.mdk`, both emitters), `defaultCellName` (`eval.mdk`) — arch `:1829` and §9.3 (`:1554-1568`): keyed `(method, tag)`, first-match over two survivors = #1265 | arch §9.3: **"NOT `IE`, BY CONSTRAINT … B-2 / #1265"** | B-2.4's row DOES claim *"disjoint default-tag word namespace"* (sprint line 71; arch `:1250-1252`) — which is the keying fix — **while §1 simultaneously lists #1265 as OUT** (lines 86-89, "method-namespace lane") | ⚠️ internal contradiction in the cut — Phase 0 must adjudicate (below) |
| 7 | Engines | B-2.4: `implEntryRouteWords` superset-OR retirement, `noneHeadTag` re-key, wasm peer (#1068 lands with it), `eval.mdk` mirrored dispatch, `Route`/`core_ir_lower` | consume frozen admissibility + identity words as **data** | word-set retirement removes the engine-side re-derivation | ✅ — ⚠️ the engine-side `implKeyOf` bare-iface family (arch `:1821`, `eval.mdk:481-483`, `CImplEntry.key`, wasm `distinctImplKeys`) rides "with `Route`" per that row; the bite list should name it so it is not a re-derived judgment call |

**Untyped eval** (no typecheck; arg-tag "first impl wins", AGENTS.md) is outside the elaborated
fragment §7's single-evaluator law quantifies over; it cannot carry the claim and never could.
Note it in the closure text; it is not a gap in this cut.

---

## The B-1 ruling — the one I was asked to make explicitly

**C4/I2-as-a-conjunction is ACHIEVABLE WITHOUT B-1. The sprint's scope ruling (B-1 OUT,
presumption (a): two-constructor route, `SupersPath` deferred by name) is RIGHT — conditional on
organ 4 being owned as a named bite.**

Derivation, not assertion:

1. Under today's flattening, a `super`-discharged goal at a **use** site is a sibling dict slot
   (`expandSupersTable`, `:9020-9036`) — i.e. it arrives as an assumption and routes
   **`DictParam k`**. No projection path exists to reference, so `SupersPath` has nothing to
   name until B-1 builds the tree. The two-constructor route is not a compromise; it is the
   faithful route type for the current representation.
2. The **construction-site fill** of that sibling slot is an ordinary entailment goal
   (`inst`/`assum` at the construction goal's instantiation). DICT C2 (`:1281-1297`) says the
   canonical `supers.D` **is** the result of exactly that resolution — *"filled by entailment at
   construction, not pre-baked against the (possibly general) instance head"*. So flat slots
   filled by per-slot independent entailment are `≡` to the projection B-1 would build. Nothing
   about canonicality waits on the tree.
3. What B-1 actually buys is representation (one closure combinator, `expandSupersTable` + census
   twins retired, first-class dict values that can be projected) and #323's depth-≥2 question —
   which B-1's own filing leaves undecided (arch `:1237-1243`). Neither is a premise of the
   conjunction.
4. The **only** way supers break the conjunction inside this sprint is organ 4's copied-route
   fill surviving into the identity-word world — and that is a flat-representation bite
   (re-resolve each appended slot), not a tree.

So: if organ 4 ships, verdict path stays ⚠️→✅ without B-1. If organ 4 is left implicit, the run
manufactures a C2 violation and **no B-1 deferral language will explain it later** — but the
remedy is still the bite, not B-1.

## Discharge-kind coverage (asked for explicitly)

- **`inst`** — `InstId`, minted where `inst` runs, min⊑ only there. Covered by B-2.2 **iff**
  minted from `IE` (organ 2), not from `ImplBuckets`' first-match/requires-only view.
- **`assum`** — `DictParam k`. The machinery exists today (`RDict` via `activeDictVars`,
  `:28670-28672`; RUN-045's control arm stamped `RDict "$dict_…"`). Phase 3's text (sprint
  `:171-175`) names the hazard correctly: re-resolving an in-scope **rigid** goal through `inst`
  rebuilds general evidence (#203's class; DICT §3 precedence, `:417-430`). ⚠️ B-2 **inherits**
  precedence rather than constructing it: identity stamping faithfully records whatever rule the
  engine chose, so a stamper that consults an impl table where a dict param is in scope stamps a
  *precise wrong answer*. The repair round's permutation differential must include a
  rigid-goal-with-dict-in-scope shape, not only ground goals.
- **`super`** — `DictParam k` (flattened sibling slot), canonical per C2 **iff** organ 4's fill
  is per-slot entailment. Not silently assumed `inst` by the sprint text — Phase 3 names it —
  but the *fill site* is named nowhere, and that is where it actually lives.
- **Default-method arms** — a fourth de-facto kind the brief's three-way split doesn't name: the
  dict's `methods` slot filled from the class default. Its selector is organ 6; see the
  adjudication below.

## Cheapest additions that close the gaps — all inside this sprint's scope

1. **(THE gap) Extend B-2.1's deletion/re-base list, verbatim in `.claude/sprint-b/DECISIONS.md`:**
   `buildImplTable`/`ImplBuckets`/`implEntryOf`/`findImplEntry`/`findImplEntryGo` retire with
   `KeyBuckets`; `routeOfD` + the five resolve\* stampers and `matchedEntry`/
   `selectImplEntryByIface` read **`IE`** with min⊑; the iface-`""` first-match fallback becomes
   either min⊑ over `IE` or a located reject (Door-4 precedent), never first-match. Zero new
   scope — this is arch `:1820`'s own assignment, restated where implementers will read it. The
   forced function already exists: deleting `KeyBuckets` breaks `routeOf`'s signature
   (`:19078`), so the re-base is adjacent work either way; the risk being closed is an
   implementer "fixing" that breakage by leaning on the table that remains.
2. **(organ 4) One named bite in B-2.2:** the super-slot fill in `expandSupersTable`'s consumers
   stops copying the sub slot's route; each appended slot's evidence is resolved independently
   at the construction goal (C2 cited as the license). Its `nearest miss:` row: a
   `Sub a requires Sup a` chain where sub and super have **different** most-specific impls at
   the goal.
3. **(organ 6) Phase 0 adjudication of #1265, split rather than in/out:** the default-arm
   registry's **keying** (disjoint per-interface default-tag namespace) is IN — B-2.4's row
   already claims it, and leaving it `(method, tag)`-first-match leaves an order-sensitive
   evidence organ standing, i.e. a third gap by this consult's own criterion. The
   method-**namespace** lane (#1354 M-2: #1276/#1386/#1351) stays OUT. The sprint doc currently
   asserts both halves without splitting them; that is the contradiction to resolve in writing.
4. **(claim hygiene, free) Scope the closure text:** C4/I2-by-construction is claimed for
   **evidence-carrying sites**; #1046/#1075's local-lambda sites (F-1) and untyped eval are
   named exclusions. A-3's lesson was an unscoped claim; the fix costs one sentence.
5. **(organ 1 tie-break) Already a Phase 0 desk item** (declaration-index defect) — noting here
   only that it is conjunct-2-relevant: a duplicated index across modules is an order artifact
   inside the tie-break, so "the tie-break is specified away" (e.g. duplicate keys are
   `T-AMBIGUOUS-INSTANCE` per F-3c) is the answer that keeps the conjunction.

## Disagreements reported, per the brief

- **Sprint §1's B-2.1 site list is incomplete against `TYPECHECK-TARGET-ARCHITECTURE.md:1820`,
  and the omission reproduces RUN-045's failure shape one organ downstream.** Not a wrong cut —
  a cut whose written form permits the same half-delivery it exists to prevent.
- **Sprint §1 both claims and excludes the default-arm fix** (B-2.4 row line 71 vs the #1265
  exclusion lines 86-89). The doc flags the ambiguity; I am ruling it needs the split in item 3,
  not a bare in/out.
- **The B-1 exclusion is correct** — I looked for the failure mode that would overturn it
  (super-discharged evidence non-canonical while flattened) and found it is organ 4's fill-site
  bite, reachable in the flat representation. No disagreement with the scope ruling itself.

**Repair-round echo (per sprint §8):** ask this question again at the end with a hand-derived
permutation differential that includes (a) a two-module import-order swap over an overlapping
pair, (b) a rigid goal with the dict in scope (#203 shape), (c) a `requires`-chain with distinct
sub/super winners, (d) a default-arm two-survivor shape — one per organ that moved. Engine
agreement is not evidence on any of them (#1047; eval is a known-wrong oracle on exactly these).
