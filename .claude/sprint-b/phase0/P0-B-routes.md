# P0-B — B-2.2 (evidence references in routes) + B-2.3 (frozen admissibility)

**Agent:** P0-B, Phase 0, Stage B sprint. **Read-only.** Trunk worktree
`/root/medaka/.claude/worktrees/giggly-tinkering-rainbow`, BASE `2b9dc798`, branch
`arch/stage-b-sprint`.
**Every citation below was opened in this tree.** Where a doc I consulted cited a line number
that has drifted, I say so and give the re-derived one.
⚠️ **No binary was available and none was built** (`make medaka` running in another agent's
window). **Nothing here is a measurement.** Every claim is source-derived, and each is marked
`DERIVED` (I read the code) or `RELAYED` (I read another artifact's claim). No `could move:` /
`nearest miss:` field below is a probe result; they are the *obligations* the implementer owes.

---

## 0. Ruling summary (the two things a later agent will look for first)

1. **`SupersPath`: ruling (a) — the PRESUMPTION HOLDS. B-2 ships a TWO-constructor evidence
   route. `SupersPath` is deferred to B-1 (#993) BY NAME.** Premise verified first-hand (§1).
   ⚠️ **(a) carries a non-obvious obligation that is NOT "do nothing": identity-stamping makes
   the flatten's own stated soundness premise false, so B-2.2 must *withhold* identity from
   appended super slots and therefore must preserve a boundary the tree currently DESTROYS.**
   See bite **B2.2-f**. And **#1127 is NOT drained by this sprint** — only its leg 3 (§1.4).
2. **B-2.3's carrier is UNRESOLVED and I am not cutting a bite for it.** The computation and the
   freeze *point* are bite-shaped (**B2.3-a**, **B2.3-b**); the *carrier* into the elaboration
   output is a cross-unit decision with a 22-call-site or an 85-site blast radius depending on
   which of three shapes is chosen (§4.3). §4 defines a bite as "apply this transformation to
   these N named sites"; the carrier cannot be stated that way until the shape is ruled, so per
   the brief I state what is missing instead of cutting a vague bite.

---

## 1. THE `SupersPath` RULING

### 1.1 The premise check — are supers in fact flattened into sibling slots today? **YES (DERIVED).**

`expandSupersTable` is at **`compiler/types/typecheck.mdk:9037-9042`** (⚠️ `#993`'s and
`compiler/TYPECHECK-ARCH-BUG-FIT.md:591`'s citation of `:5037` has drifted by ~4000 lines;
re-derive with `grep -n '^expandSupersTable' compiler/types/typecheck.mdk`). Its own header,
verbatim, `:9019-9028`:

> A `=>`-constrained fn whose body calls a SUPERCLASS method … needs an honest super-dict slot
> threaded through. Inference registers only the DECLARED constraints in
> `funConstraintsRef`/`funConstraintIfacesRef`; this pass **APPENDS, per entry, one extra slot
> for each (transitive) superinterface** … **Appended AFTER the declared slots so existing slot
> indices are unchanged**; deduped by (iface, id) within an entry. **Because the dict VALUE is
> just a type tag (VDict "Widget"), the super slot's route is identical to the sub slot's — no
> separate projection is needed; the slot just has to EXIST** so the call site applies a
> matching dict and the def binds a matching param.

The body confirms it: two `setRef`s that `map` an expansion over `funConstraintsRef` and
`funConstraintIfacesRef` (`:9039-9041`); `expandSupersEntry` returns `(fn, map (s => s.csId)
pairs)` (`:9054-9058`) — a flat id list, no structure. The cross-module twin is
`expandSupersCross` (`:9046-9051`).

**Corroborating derivation, independent of that header:** the entailment core has **no `super`
rung at all**. `entail` (`:18953-18958`) is a three-way ladder — `entailAssum` → `entailInst`
→ `entailFallback` — and `Route` (`compiler/frontend/ast.mdk:722-728`) has six constructors,
none of them a projection:

```
RNone | RKey String (List Route) | RDict String | RDictFwd String | RLocal String (List Route) | RScalar String
```

**So there is no path to reference, exactly as the sprint doc asserts.** A super-discharged goal
is not a discharge kind in this implementation: it is stamped with the *sub* slot's route.

### 1.2 The ruling

> **RULING (a). B-2.2 delivers a two-constructor evidence route: `InstId`-bearing (`RKey`) and
> `DictParam k` (`RDict`/`RDictFwd`). `SupersPath` is NOT built in this sprint. It is deferred to
> B-1 (#993), by name, together with the `entailSuper` projection rung that would give it
> something to denote.**
>
> **This is a STATED (a), not an unfinished (b).** A later agent reading `Route` and finding two
> evidence constructors where #1113's text says three is looking at the intended end state *of
> this sprint*, not at an abandoned migration.

I am **not** choosing (b). (b) would import B-1's representation change (`supers` component +
`entailSuper` rung + the `Value` rep in eval + dict-arity readers) into a branch whose goldens
are deferred, which is precisely the attribution failure the sprint doc quotes the design doc
naming at F-3 (`.claude/STAGE-B-SPRINT.md:48-52`).

### 1.3 ⚠️ What (a) COSTS — the obligation that makes (a) not-nothing

The flatten's justification (quoted above) is *"the dict VALUE is just a type tag … so the super
slot's route is identical to the sub slot's."* **B-2.2's entire purpose is to stop the route
being a type tag.** The moment `RKey`'s payload names a selected *instance* rather than a head
tag, "identical to the sub slot's route" stops meaning "a tag that happens to match" and starts
meaning **"the sub interface's instance, in the super interface's dict slot"** — a route that
names an impl of the wrong interface.

Therefore, under (a):

> **INVARIANT (a-i): identity is stamped ONLY on declared constraint slots. Appended super slots
> keep today's tag-shaped route, unchanged, until B-1 gives them a projection.**

**And that invariant is not currently expressible**, which is the concrete bite (a) buys:
`expandSupersEntry` overwrites the table with `declared ++ appended` and **records no boundary**
— the pre-expansion length is discarded (`:9054-9058`; the refs are wholesale `setRef`s at
`:9039-9041`). Any consumer that wants "is slot *k* declared or appended?" cannot ask.
See **B2.2-f**.

### 1.4 🚨 Scope statement a later agent must not misread: **#1127 is NOT drained here**

`compiler/TYPECHECK-ARCH-BUG-FIT.md:583-624` (RELAYED, with its line numbers re-derived by me)
labels #1127 **DRAINED-BY B-1 + B-2** and decomposes it into three legs: (1) the flatten's
premise false under overlap; (2) `assum` cannot tell the two slots apart, because
`expandSupersFix` gives the appended super slot **the same tyvar id** as its sub slot and
`activeDictVars` is keyed by tyvar id alone; (3) both engines re-derive the instance from a bare
head tag, differently. **Legs 1 and 2 are B-1's. Only leg 3 is B-2's.** Under ruling (a) this
sprint fixes leg 3 and leaves #1127 reproducing. A drain claim against #1127 from this run is
wrong.

---

## 2. B-2.2 — the discharge-kind enumeration (this section IS the anti-S0 part)

The brief is right that "stamp identity at `inst`" without enumerating discharge kinds is itself
the S0. Here is the complete set **as the tree actually implements it**, each with its site and
what B-2.2 does to it. The set was derived, not recalled: `entail`'s ladder
(`typecheck.mdk:18953-18958`) plus **every non-comment `RKey` construction site in the file** —
`grep -n RKey compiler/types/typecheck.mdk` filtered to non-comment lines yields exactly
**7** hits, of which 5 construct and 2 destructure:

| # | Discharge kind | Site(s) | Has a selected instance? | B-2.2 transform |
|---|---|---|---|---|
| D1 | **`assum`, tyvar-keyed** | `entailAssumVar:18980-18985` → `entailAssumRoute:18987-18995` → `RDict`/`RDictFwd` | **NO** | **UNCHANGED.** Already *is* `DictParam k`. Must **never** be re-resolved through `inst`. |
| D2 | **`assum`, predicate-keyed given** | `entailAssum:18968-18973` second arm (`activeDictPredOf`), the structured given `requires S (List a)` | **NO** | **UNCHANGED**, same reason. Same route constructors. |
| D3 | **`inst`, return position** | `entailInst … (EKReturn …):19009-19015`, `RKey routeKey []` at `:19013` | **YES** | Stamp identity **here** (bite B2.2-b). |
| D4 | **`inst`, nested/top constrained call** | `entailInst … (EKNestedTop …):19038-19043`, `RKey routeKey (…)` at `:19041` | **YES** | Stamp identity here. |
| D5 | **`inst`, argument position** | `entailInst … (EKArg …):19052-19062`, `RKey routeKey []` at `:19060` | **YES** | Stamp identity here. |
| D6 | **`inst`, operator site** | `entailInst … (EKOp …):19063-19064` → `stampOpRouteVal:15274-15292`, `RKey key reqs` at `:15292` | **YES** (or builtin → `RNone`) | Stamp identity here; builtin arm stays `RNone`. |
| D7 | **`super`** | **NO SITE.** No rung in `entail`; flattened by `expandSupersTable:9037` | **NO** | Ruling (a): withhold identity from appended slots — **B2.2-f**. |
| D8 | 🚨 **undetermined-by-count** | `routeUndeterminedTop:19176-19187`, `RKey tag (…)` at **`:19187`** | **NO SELECTOR RAN** | See §2.1 — must be ruled, not stamped. |
| D9 | 🚨 **recursive-call constraint route** | `resolveRecMono:19435-19439`, `RKey tag []` at **`:19437`** | **NO SELECTOR RAN** | See §2.1 — must be ruled, not stamped. |
| D10 | `RLocal` (definer shadow) | `ast.mdk:703-715` (SHADOW-SEMANTICS S1/S9) | n/a — not a dispatch discharge | **OUT.** SHADOW spec (#616). Touch only with that spec cited. |
| D11 | `RScalar` | `ast.mdk:716-721` | n/a — *"NOT a typeclass dispatch route"* | **OUT.** |
| D12 | `entailFallback` non-`RKey` arms | `:19066-19071` (`RNone` ×3) | **NO** | **UNCHANGED.** The `RNone` arms are load-bearing do-nothings (`:18940`, `:18949-18950`). |

### 2.1 🚨 D8 and D9 are the finding: **two `RKey` stamps that never consult `min⊑`**

Both mint a route from a **bare head tag** with no selector in the path. They are inside
B-2.2's own region and they are #1072's mechanism reproduced at the *stamp* side rather than the
emitter side:

- **D8 `routeUndeterminedTop` (`:19176-19187`)** — decides by **impl COUNT**:
  `match implHeadTagsForIface prog iface` → `[] => RNone` · `[tag] => RKey tag (…)` ·
  `_ => reportAmbiguousImpl iface`. Note *what* it counts: `implHeadTagsForIface` (`:19199`)
  projects heads through `headTyconTy` and **dedups**, so *two* impls sharing a head
  (`impl C (T Int)`, `impl C (T Bool)`) count as **one** and take the `[tag]` arm. It also reads
  **`prog`**, not `IE` — a per-driver decl list.
- **D9 `resolveRecMono` (`:19435-19439`)** — `Some tag => RKey tag []`. No `keyForSite`, no
  `matchedEntry`, no `pickMostSpecificEntry`. Its sibling arm forwards a dict slot (`RDict
  (dictParamName encl slot)`), so this is the *concrete* arm of the recursive-call route.

**Ruling I make here, because leaving it to an implementer is the S0:** a stamp with no selector
in its path **may not acquire an `InstId`**. Each of D8/D9 must be explicitly resolved as either
(i) re-based onto the one selector (it then becomes a genuine `inst` and gets identity), or
(ii) **demoted to `RNone`** with the loss stated. **Silently carrying the bare tag into an
identity-shaped payload manufactures a false identity** — an `InstId` that names an instance
nobody selected, which is strictly worse than today's honestly-coarse tag, because every
downstream consumer is being taught to trust the payload. This is bite **B2.2-d** and it is the
one I would not let a Sonnet implementer decide by proximity.

### 2.2 The precedence obligation, stated as a checkable property

DICT §3 pins `assum`/`super` above `inst` (`typecheck.mdk:18960-18967` records the precedence
in-tree). B-2.2's risk is the inverse of the usual one: a refactor that routes *everything*
through the new identity-stamping selector "for uniformity" would re-resolve D1/D2 through
`inst` and rebuild **general** evidence at a site whose dict must be **forwarded** — #203's
class. The property to assert in review:

> **The number of call sites of the identity-minting selector must equal the number of `inst`
> arms (D3–D6). Any additional caller is a precedence violation until proven otherwise.**

That is mechanically checkable by grep, and it is the review question I would put in the bite's
`could move:` line.

---

## 3. B-2.2 bite list

Notation: each bite gives `sites:` as `file:line` **as of BASE `2b9dc798`** (re-derive by
symbol, per `DICT-SEMANTICS.md:2499`'s non-monotone-drift warning), `transform:`, and the three
mandatory ledger fields the implementer owes. **`could move:`/`nearest miss:`/`engines:` here are
the OBLIGATION, pre-filled with my prediction — the implementer replaces them with what they
observed.**

### 🚨 Sequencing constraint that shapes the whole list (DERIVED, and it is not optional)

`keyForSite`'s own header, `typecheck.mdk:17860-17871`, verbatim:

> The key/tag split deliberately mirrors `core_ir_lower.declRouteKey` (bare head when that head
> is unique among the interface's declared impls, canonical full-type key otherwise): **the
> typechecker stamps this word into the caller's dict cell and the emitter derives the impl's own
> from `declRouteKey`, so the two must agree word for word.** … (Retiring `fromOption tag (…)`
> outright — **B-2/#1113's end state, where the route IS the selected instance's identity with no
> head-tag hedge at all — additionally renames every single-impl-per-head symbol in the tree,
> which moves the seed and every golden.**)

Two consequences, both load-bearing:

1. **The stamp side and `core_ir_lower.declRouteKey` (`compiler/ir/core_ir_lower.mdk:1346-1347`,
   `declRouteKey tag key unique = if unique then tag else key`) must move in the SAME bite or in
   two bites the sub-orchestrator lands back-to-back with no build published between them.**
   A skew is **silent on the direct-call path and live on the RDict path** — the tree says so at
   `:17865-17866`.
2. **B-2.2 renames symbols ⇒ it moves the seed and every golden.** That is in-band per
   `.claude/STAGE-B-SPRINT.md:300-311` (fixpoint + twice-run `refresh_seed.sh`). An
   implementer who reports "byte-identical" on B2.2-b has not exercised the change.

**And a dependency on B-2.1 that P0's B-2.1 owner must accept (flagging, not resolving):**
`EntailKind`'s four constructors each carry a `KeyBuckets` (`:18922-18951`) and D3/D5/D6 call
`keyForSite`, D4 calls `keyForSiteByIface` (`:18557-18558`) — so **B-2.1's "retire
`KeyBuckets`/`keyForSite*` by DELETION" cannot complete without editing exactly B-2.2's region.**
My recommendation, which is cheap if taken up front and expensive later:

> **B-2.1's IE-backed selector should return the selected ROW (`Option ImplRow`), not a projected
> `String` key.** `selectImplEntryByIface` already returns `Option KeyEntry` (`:18527`) and
> `keyForSite` throws the entry away to keep the word (`:17872-17887`). If B-2.1 preserves that
> throw-away, B-2.2 must re-run the selector to recover identity — two resolutions of one goal,
> which is the shape this whole arc exists to delete.

### B2.2-a — `Route`'s evidence payload becomes identity-bearing (one type, one mint site)

- **sites:** `compiler/frontend/ast.mdk:722-728` (the `Route` declaration) — plus ONE new
  mint function, sited beside `InstRef` at `compiler/types/typecheck.mdk:3996-4002`.
- **transform:** change `RKey`'s first field from `String` to a two-component identity carrier:
  (i) the **content-derived word** the engines match on, and (ii) the **`InstRef`** within-compile
  discriminator (`typecheck.mdk:3996`, `data InstRef = InstRef String Int Int` = declaring
  module id · ordinal · whole-graph seq).
  🚨 **CHANGE the payload type; do NOT add a parallel `RInst` constructor.** Two reasons, both
  from this tree: (1) `AGENTS.md`'s standing trap — a **new AST constructor is silently swallowed
  by every `_ =>` wildcard arm** in every pass that does not yet know it, and `Route` is matched
  in five files; changing the *type* makes every consumer fail to compile, which is the loud
  form. (2) A parallel constructor IS the superset hedge B-2.4 exists to delete.
  🚨 **The WORD may not be derived from `InstRef`.** `InstRef`'s own header,
  `typecheck.mdk:3980-3995`, verbatim: *"UNIQUE WITHIN ONE COMPILE — AND **NOT STABLE ACROSS
  COMPILES** … `seq` is a WHOLE-GRAPH running counter, so adding one `impl` to ANY earlier module
  renumbers every later impl … **If B-2 wants a NAME, derive it from `(module id, interface
  identity, head)` — content, not position — and use `InstRef` only as the within-compile
  discriminator it is.**"* A `seq`-derived symbol is a reproducible-build and incremental-rebuild
  hazard. **This constraint was written FOR this bite; honour it or overturn it in writing.**
- **could move:** nothing by itself (a type change with no stamping change is not
  compilable-and-inert — it will force every consumer edit, which is the point). The bite is
  "the type + the mint + make the tree compile again with today's word".
- **nearest miss:** an interface whose impls live in two modules with the **same module-local
  spelling** — the word must separate them or identity has bought nothing (#1047's class).
- **engines:** LLVM, wasm, eval, `core_ir_lower`, `core_ir_sexp` all match `Route`. This bite
  **owes all of them**; it is the bite whose compile errors *enumerate* B-2.4's site list, which
  is why it is worth landing before P0-C's arms rather than alongside them.

### B2.2-b — stamp identity at the four `inst` arms, from the selector's ENTRY

- **sites:** `typecheck.mdk:19009-19015` (D3) · `:19038-19043` (D4) · `:19052-19062` (D5) ·
  `:19063-19064` → `stampOpRouteVal:15274-15292` (D6). Four arms, one helper.
- **transform:** each arm today does `let routeKey = fromOption tag (keyForSite …)` — a
  **head-tag hedge over a selector result**. Replace with: consult the selector once, take the
  row, mint the identity from the row. `fromOption tag` disappears (that is exactly what
  `:17867` calls "#1113's end state").
- **could move:** **acceptance, no. Emitted evidence, YES, at every single-impl-per-head site in
  the tree** (`:17869`). Also the `T-AMBIGUOUS-INSTANCE` channel: `pickMostSpecificEntry` still
  *returns* the first match after reporting (`DICT-SEMANTICS.md:2475`), so a rejected program's
  routes must stay unchanged — assert that, do not assume it.
- **nearest miss:** a goal whose selector returns `None` (headless/unmatched). Today
  `fromOption tag` silently substitutes the head tag. After this bite there is no tag to fall
  back to — **the `None` arm is a new code path that no existing fixture can exercise, because
  every existing fixture covered the substituted case.** This is the tree's canonical
  "returns-nothing → returns-something" hazard; the fixture must be built from the spec.
- **engines:** all three consume the moved word. Owes the `noneHeadTag` general-fallback tier
  (`llvm_emit.mdk` `emitGeneralRKey`/`findByTag noneHeadTag`, and its eval peer `pickTagFallback`
  — named at `typecheck.mdk:17852-17858`, which warns in as many words that behaviour surviving
  this IR change *"is EMPIRICAL, not structural"* and rests on that tier).

### B2.2-c — the non-`inst` discharge kinds: assert, do not re-route

- **sites:** `typecheck.mdk:18968-18973` (D2 predicate given) · `:18980-18985` (D1) ·
  `:18987-18995` (`entailAssumRoute`, all four arms) · `:19066-19071` (`entailFallback`).
- **transform:** **no behavioural change.** Add the precedence assertion as a comment at
  `entail`'s ladder (`:18953`) naming DICT §3 and the site-count property of §2.2 above, so the
  next refactor cannot "unify" these into the selector without deleting the sentence that
  forbids it.
- **could move:** nothing — pure comment + a review invariant. (Valid form of "nothing", with
  the reason: no expression changes.)
- **nearest miss:** a *rigid in-scope* goal at a site whose `EntailKind` is `EKArg`/`EKOp`, where
  `activeDictVarOfEncl`/`opDictVarOf` miss and the ladder falls to `inst`. That fall-through is
  a real re-resolution today and this bite does **not** fix it; it only stops B-2.2 from adding
  more. State it as a `nearest miss:` rather than fixing it.
- **engines:** none.

### B2.2-d — 🚨 the two selector-free `RKey` stamps (D8, D9) — a RULING bite, not a mechanical one

- **sites:** `typecheck.mdk:19176-19187` (`routeUndeterminedTop`, `RKey` at `:19187`) ·
  `:19435-19439` (`resolveRecMono`, `RKey` at `:19437`).
- **transform:** for each, choose and record: (i) re-base onto the one selector, or (ii) demote
  to `RNone`. **Not** "carry the bare tag into the identity payload."
  Additional derived facts the chooser needs: D8's candidate count comes from
  `implHeadTagsForIface` (`:19196-19199`), which **dedups by head**, so `impl C (T Int)` +
  `impl C (T Bool)` present as a single candidate — the exact zero-overlap shape §4.1's clause
  calls out; and D8 reads `prog`, not `IE`, so it is also a residual candidacy reader that
  Stage A's globalization did not reach.
- **could move:** **acceptance can move in both directions.** Demoting D8 to `RNone` sends the
  site to the engines' runtime path (eval `filterByTag`, LLVM dispatch switch) — which under
  B-2.3 may then be *inadmissible* and must reject rather than guess. Re-basing D8 can turn
  today's silent `[tag]` accept into `T-AMBIGUOUS-INSTANCE`. **Either way this bite moves
  diagnostics, and value-goldens are structurally blind to a diagnostic-only change** — so its
  verification is a `check --json` code differential, not a value golden.
- **nearest miss:** a **recursive** `=>`-constrained function whose constraint grounds to a head
  with two impls (D9's shape). Today: bare `RKey tag []`, first-match-ish downstream. The
  fixture must be recursive, or it exercises D3–D6 instead and proves nothing about D9.
- **engines:** all three (route word moves at these sites), plus the diagnostic channel.

### B2.2-e — the paired emitter-side key derivation (lands WITH B2.2-b)

- **sites:** `compiler/ir/core_ir_lower.mdk:1346-1347` (`declRouteKey`) · `:1343`
  (`ifaceRouteKeysGo`/`ifaceDeclHeadUnique`) · `:1301` (`ifaceImplHeadEntries`, which mints
  `fromOption noneHeadTag (headTyconHead typeArgs)` + `implKeyOf …`) · `:1392` (the same pair
  again) · eval's peer `implMethodEntry` (`compiler/eval/eval.mdk:1998-2004`, which stores
  **both** `tag` and `key` into `VTypedImpl t key …`).
- **transform:** derive the impl's own identity word from the same content-derived mint as
  B2.2-a, so caller-stamped and definition-derived words remain equal **by construction**
  instead of by two mirrored implementations agreeing.
- **could move:** every emitted impl symbol name, hence the seed and the IR-text golden
  (`diff_compiler_llvm_typed_ir`). **Not** acceptance.
- **nearest miss:** a **headless** impl (`impl C a`) — registered under `noneHeadTag`
  (`typecheck.mdk:17930-17933`). If the new word collapses headless impls of two interfaces onto
  one spelling, the general-instance fallback tier picks by declaration order and it is silent.
- **engines:** LLVM + wasm + eval + `core_ir_lower`. **This bite is the seam with P0-C.** I name
  it; I do not design their side. The ORs P0-C retires are, derived:
  `implEntryRouteWords` (`compiler/backend/llvm_emit.mdk:1512-1518`, consumed by
  `emitDispatchArm:5336-5344` via `emitRouteWordMatch`); eval's `hasTag`/`matchesTag`
  (`compiler/eval/eval.mdk:1207`, `:1211` — both literally `t == tag || k == tag`, the
  superset-OR in eval); wasm's `headTagUniqueW`/`headTagForKeyW`
  (`compiler/backend/wasm_emit.mdk:4014-4048`). **Those three ORs are deletable only after
  B2.2-a/b/e; the sprint doc's Phase 3 → Phase 5 order is therefore correct and must not be
  compressed.**

### B2.2-f — preserve the declared/appended super-slot boundary (ruling (a)'s only obligation)

- **sites:** `typecheck.mdk:9037-9042` (`expandSupersTable`) · `:9046-9051`
  (`expandSupersCross`) · `:9054-9058` (`expandSupersEntry`) · `:9060-9064`
  (`expandSupersIfaceEntry`).
- **transform:** record, per entry, the **declared** slot count before appending (or tag appended
  slots), and gate identity-stamping on it so INVARIANT (a-i) is expressible. Purely additive:
  slot indices are already stable because supers are appended (`:9024-9025`), so no consumer's
  arithmetic changes.
- **could move:** nothing behavioural if the recorded count is unread by anything but the
  stamping gate. ⚠️ **It must be recorded at the mutation point**, not recomputed later — after
  the `setRef` the boundary is unrecoverable, which is the whole defect.
- **nearest miss:** the #1127 shape — sub goal `C (List Int)` with one impl, super goal
  `D (List Int)` with two (`D (List a)`, `D (List Int)`). Under (a) that program **still
  mis-dispatches** (legs 1+2 are B-1's, §1.4). The fixture belongs in
  `test/must_fail_fixtures/`, asserting it still reproduces — **not** a captured value golden,
  which would enshrine the wrong winner.
- **engines:** none directly; it constrains what B2.2-b may stamp.

---

## 4. B-2.3 — frozen admissibility

### 4.1 🚨 DICT §5's ACTUAL condition, quoted verbatim

`docs/spec/DICT-SEMANTICS.md:957-970`, read in this tree:

> **Arg-tag dispatch is an optimization, not a semantics.** Inspecting a runtime value's
> constructor to select an impl is sound **iff** the class parameter occurs in an argument
> position whose head constructor uniquely determines the **most-specific matching instance**
> (§3), *and* that argument is evaluated. Overlap narrows this side condition sharply: a head tag
> alone does not separate overlapping instances below one constructor — a `List` tag cannot
> distinguish the `List Int` instance from the `List a` instance — so for any class with such
> overlap, arg-tag selection at that constructor is *unsound*, not merely incomplete. It is a
> refinement of `(method)` valid under a side condition. It is **never** the meaning of dispatch
> and must never be the *only* mechanism, because result/phantom-position methods have no such
> argument. A semantics that decides dispatch in the evaluator is therefore wrong in general; §7
> makes the evaluator dictionary-directed and demotes arg-tag to an admissible optimization.

**Reporting the wording difference, as instructed.** The doc and my brief/#1113 do **not** say
the same words, and the difference is a quantification the doc leaves implicit:

| | wording |
|---|---|
| **Doc (§5:957-960)** | *"the class parameter occurs in an argument position whose head constructor uniquely determines the most-specific matching instance (§3), and that argument is evaluated"* |
| **Brief / #1113 body** | *"per (class, argument position), every reachable constructor uniquely determines the min-specificity winner for every goal reaching the site, AND the argument must be evaluated"* |

- **Substantively they agree**, and neither is the "no overlap below the head" paraphrase the
  brief warns about — the doc's own §11 row for §5 (`:2495`) records that #1113's text
  *corrected* that paraphrase, and gives the counterexample verbatim: *"`impl C (T Int)` /
  `impl C (T Bool)` don't overlap and the tag `T` determines nothing; multi-param interfaces
  likewise."*
- **"min-specificity" and "most-specific" are the same thing** — §3 defines selection as
  `I = min⊑(match(IE, C τ̄))`, *"the unique most-specific match"* (`:359`, `:324`).
- **The brief is STRICTLY STRONGER on two axes the doc leaves implicit**: it quantifies over
  *every reachable constructor* and over *every goal reaching the site*, where the doc quantifies
  over "an argument position whose head constructor". **The doc wins where they conflict; they
  do not conflict, so I adopt the stronger reading and say so** — a per-position verdict that
  held for one goal and not another would be exactly the order-dependence C4/I2 forbids.

### 4.2 "post-K" — where it actually is (DERIVED)

**K** is the whole-graph declaration-analysis phase (`compiler/TYPECHECK-TARGET-ARCHITECTURE.md`
§2 K, `:130`: *"K declaration analysis (whole-graph: CE, IE, DataEnv — new gateway)"*), landed as
A-3. In code, K **is** `buildDeclEnvs` (`typecheck.mdk:2769-2800`), whose `DeclEnvs` record
initialises `deData = buildDataEnv mods`, `deImpls = buildImplEnv mods` (the `IE`), and `CE` —
all **pure folds over the same per-module rows**, a property the record's own comment states and
flags as unguarded (`:2789-2800`).

It has exactly **two** call sites (`grep -n 'buildDeclEnvs' compiler/types/typecheck.mdk`, non-comment):

- `:27517` — the check path's preamble;
- **`:27996` — inside `elaborateModules`**, immediately followed by
  `setRef driverState.value.declEnvsRef declEnvs` (`:27997`).

**So "post-K" for the elaboration path is `typecheck.mdk:27996-27997`.** Two derived facts that
make this the right seam and not merely an available one:

1. **`elaborateModules` may run its whole sweep TWICE.** `match
   driverState.value.promotionHarvestRef.value` (`:28084`): the non-empty arm calls
   `resetCrossModuleState ()` and re-runs discovery + a second marking sweep (`:28090-28128`).
   A table computed at `:27996` is computed **once** and survives, because `declEnvsRef` is on
   `driverState`, which `resetCrossModuleState` does not touch — the comment at `:27992-27995`
   states exactly that for its three peers. A table computed anywhere inside the sweep would be
   built twice and could differ between the passes.
2. **The freeze belongs as a `DeclEnvs` FIELD, computed by a pure fold over `deImpls`** — same
   shape as `deData`/`deImpls`/`deCE`, so it inherits K's ordering and K's
   must-run-after-`stampGraphTyOrigins` precondition for free (`:3784-3786` region / the IE block
   header at `:3925-3966`).
   🚨 **Do NOT make it a new `CrossRun`/`DriverState` Ref.** `test/registry_keying_ratchet.sh`
   check 1 gates new `CrossRun`/`DriverState` **fields** and check 2 gates new `setRef …` writers
   (its header, `:32-47`), so a new Ref costs an allowlist row and a justification — and the
   ratchet is *right*: a mutable program-global table for a whole-graph-derived fact is the shape
   this arc is retiring.

### 4.3 🚨 The CARRIER is unresolved. I am not cutting a bite for it.

The spec says *"frozen into the elaboration output as data, consumed — never re-derived — by
every engine."* **The elaboration output is pure AST**:
`elaborateModules : List Decl -> List Decl -> List (String, List Decl) -> (List Decl, List (String, List Decl))` (`:27945`).
There is no data channel in it. Three candidate carriers, with their costs **derived, not
estimated**:

| # | Carrier | Cost (derived) | Verdict |
|---|---|---|---|
| C-1 | Widen `elaborateModules`' return tuple with the table | **22 call sites across 9 files** — `compiler/tools/test_cmd.mdk:427,505,518,586,602,739,750`; `compiler/driver/medaka_cli.mdk:745,1685,1926,1958`; `compiler/entries/entry_support.mdk:153,165`; `…/eval_autoprint_main.mdk:39,43`; `…/origin_agreement_main.mdk:334,348`; `…/playground_main.mdk:287,322`; `…/eval_typed_modules_main.mdk:51`; `…/wasm_emit_gaps_main.mdk:57`; `…/llvm_bootstrap_lex_main.mdk:54`. Derive: `grep -rn 'elaborateModules' --include=*.mdk compiler/` and drop comment lines | **Mechanical, loud, bite-shaped.** My recommendation for the **eval** arm. |
| C-2 | Widen `CProgram` (`compiler/ir/core_ir.mdk:241-242`, positional, 4 fields) with a 5th | **85 `CProgram` mentions across 14 files** (`grep -rn CProgram --include=*.mdk compiler/ \| grep -v ':--' \| wc -l` → 85), incl. `core_ir_sexp`, `core_ir_sexp_parse`, `core_ir_eval`, `snapshot.mdk`, both emitters, 4 entries. **A `core_ir_sexp` change moves the S-expr goldens** | Reaches LLVM+wasm+`ceval` cleanly but **not eval** (eval never sees a `CProgram`). Cost is real; P0-C's call. |
| C-3 | A synthetic `Decl` carrying the table | **REFUSED.** `AGENTS.md`'s standing trap: a new AST constructor is silently swallowed by every `_ =>` wildcard arm; and a table hidden in a decl list is re-derivable-looking, which is the failure mode the spec sentence exists to prevent | **Do not.** |

**What is missing before this becomes a bite:** whether the emit arm rides C-2 (data in
`CProgram`) or C-1 (threaded past lowering). That is a decision about `core_ir_lower`'s and both
emitters' signatures — **P0-C's territory**. My statement of the seam, which is all I will
assert:

> **SEAM:** the table is **produced** once at `typecheck.mdk:27996-27997` as a `DeclEnvs` field
> (bite B2.3-a/b). It is **handed to the engines** at exactly two boundaries: (i) the
> `elaborateModules` return, for `eval`; (ii) `lowerProgramEmit`
> (`compiler/ir/core_ir_lower.mdk:551-552`), for LLVM and wasm. **P0-C owns (ii)'s shape.**
> Whichever is chosen, the consumer contract is the same: **read, never recompute** — a
> consumer that can fall back to deriving it locally has reproduced the defect.

### 4.4 The operational definition of the condition (and where it is conservative)

"Every **reachable** constructor" is not computable from `IE` alone — `IE` holds impl heads, not
the set of constructors that can flow into an argument position, and DCE runs after. The sound,
`IE`-only reading, which I recommend stating in the bite so nobody silently weakens it:

> For class `C` and argument position *p*: *p* is **admissible** iff, for every pair of `IE` rows
> for `C`, the two rows' head constructors **at position p** either differ, or (being equal) one
> row is strictly `⊑`-more-specific than the other *and* the tag at *p* is sufficient to pick it.
> Two rows agreeing on the tag at *p* while differing below it — `impl C (T Int)` /
> `impl C (T Bool)` — make *p* **INADMISSIBLE**, overlap or no overlap.

This **over-approximates** the reachable-constructor set (it quantifies over all declared impls,
not the ones a program can reach), so it can mark an admissible position inadmissible. That
costs **performance, not correctness** — the inadmissible verdict routes dispatch through the
dictionary, which §5 says is the meaning of dispatch anyway. Say so in the bite; a later
"optimization" that narrows this quantifier is a soundness change wearing a perf hat.

**And the second conjunct is NOT free.** *"that argument is evaluated"* is not discharged by
Medaka's strictness, because dispatch can happen at a **partial application** before the
discriminating argument arrives: `applyOpt (VMulti vs) arg = collectPartials [] (filterByTag vs
arg) arg` (`compiler/eval/eval.mdk:940`) with `isDispatching (VTypedImpl _ _ pos seen _) =
containsInt seen pos` (`:974-976`) — `seen` counts arguments already applied and `pos` is the
declared dispatch positions. **`seen`/`pos` IS the second conjunct's implementation**, and the
frozen table must key on the same position notion or the two disagree.

### 4.5 B-2.3 bite list

### B2.3-a — the admissibility table: type + pure computation from `IE`

- **sites:** the `DeclEnvs` record (`typecheck.mdk:2778-2800`, add one field beside
  `deImpls = buildImplEnv mods` at `:2796`) + one new builder function sited beside
  `buildImplEnv`, folding over `deImpls`'s rows (`ImplRow`, `:4058-4059`;
  `ieRowTriple : ImplRow -> (IfaceRef, List Ty, List Require)` at `:4067-4068` gives head + context;
  `ieRowInst` at `:4064` gives identity).
- **transform:** compute, per `(interface identity, argument position)`, the verdict of §4.4.
  **Keyed on `IfaceRef` (interface IDENTITY), never on a bare interface-name `String`, and never
  on a method name** — the `IE` block header, `:3945-3951`, verbatim: *"`IE` is keyed by IMPL
  IDENTITY … **NO `IE` KEY COMPONENT MAY BE A METHOD NAME**: a `(method, tag)`-keyed default
  registry here would rebuild #1265 in the new substrate."* A `(method, …)` key here would put
  B-2.3 in the out-of-scope method-namespace lane (`.claude/STAGE-B-SPRINT.md:86-89`).
- **could move:** **nothing** — the field is computed and unread until B2.3-d. Valid "nothing",
  with the reason: no existing expression is edited. ⚠️ But it is a **new whole-graph fold**, so
  `perf_scaling` applies: the fold must be O(rows) per interface, not a `List`-as-a-map over all
  rows (`compiler/AGENTS.md`: thirteen quadratics, all that shape).
- **nearest miss:** a program with **zero** impls of a class (empty row set). The verdict for an
  absent class must be explicit; the eval reader's current analogue **fails open** —
  `lookupPositions _ _ [] = [0]` (`compiler/eval/eval.mdk:1934`) declares position 0
  dispatchable on a miss. A table that inherits that default has changed nothing.
- **engines:** none yet (produced, not consumed).

### B2.3-b — freeze it once, post-K

- **sites:** `typecheck.mdk:27996-27997` (the `buildDeclEnvs` call + `declEnvsRef` set inside
  `elaborateModules`); the peer at `:27517` for the check path.
- **transform:** none beyond B2.3-a — the field *is* frozen by being a `DeclEnvs` field computed
  at that one call. **This bite is the written derivation** (§4.2, incl. the double-sweep
  argument) plus the assertion that no other site computes it.
- **could move:** nothing. **nearest miss:** the **Flat fallback** path — A-3's honest scope
  keeps a per-run env for it (`TYPECHECK-TARGET-ARCHITECTURE.md:1214-1219`), and
  `buildImplUniverse`/`buildImplTable` still exist. If the Flat path reaches an engine without
  the frozen table, that engine either has no table (crash) or re-derives (defect). **Which
  drivers are Flat must be stated before B2.3-d lands.** I did not derive that set; it is owed.
- **engines:** none yet.

### B2.3-c — CARRIER: **NOT CUT.** See §4.3. Blocked on a P0-C-owned decision.

Stating the missing piece rather than cutting a vague bite, per §4 of the sprint doc.

### B2.3-d — the reader seam per engine (NAMED ONLY — P0-C owns the arms)

- **sites, eval:** `buildIfaceDispatch` (`compiler/eval/eval.mdk:1912-1913`) and
  `ifaceMethodEntry`/`dispatchPositionsOf` (`:1921-1923`, `:552-553`) — the table
  `List ((String, String), List Int)` that today supplies positions, **derived from interface
  DECLARATIONS, not from `IE`, and bare-name keyed on `(iface, method)`**; its reader
  `lookupPositions` (`:1933-1937`, fails open to `[0]`); the consumers `filterByTag` (`:958-961`),
  `filterByTagT` (`:963-965`), **`keepOrAll` (`:967-969`) — the silent-wrongness channel: when
  every tagged candidate is filtered out it returns the ORIGINAL set**, and `keepCand`/`matchesTag`
  (`:971-972`, `:1211`).
- **sites, LLVM:** `implEntryRouteWords:1512-1518` → `emitDispatchArm:5336-5344`.
- **sites, wasm:** `headTagUniqueW`/`headTagForKeyW:4014-4048`.
- **transform (P0-C's to design):** gate each arg-tag inspection on the frozen verdict; an
  **inadmissible** (class, position) must not be dispatched by tag.
- **could move / nearest miss / engines:** P0-C's to fill. One thing I will assert because it is
  a spec fact rather than a design choice: **§5's inadmissible case must not silently fall back
  to "first candidate"** — the doc calls tag selection there *"unsound, not merely incomplete"*
  (`:963-965`). `keepOrAll`'s original-set return is exactly that fallback.

### B2.3-e — ratchet obligation (only if a Ref is used after all)

If the carrier decision forces a `DriverState`/`CrossRun` Ref, `test/registry_keying_ratchet.sh`
checks 1 and 2 fire and the PR owes an allowlist row plus a justification (its header, `:39-47`:
*"never widen a pattern to make a check stop firing"*). **§4.2 recommends the `DeclEnvs` field
precisely to avoid this.**

---

## 5. Drain-target mapping (what my two units do and do NOT reach)

Titles read from the tracker (`gh issue list`), all **OPEN**:

| Issue | Mechanism | Reached by | Verdict |
|---|---|---|---|
| **#1072** S0 — *most-specific-wins decided by MODULE ORDER; the bare-head word is OR'd into every arm* | the three superset-ORs (`implEntryRouteWords`, eval `matchesTag`, wasm `headTagForKeyW`) | **B2.2-a/b/e enable; B-2.4 deletes** | Drains at B-2.4, not at B-2.2. A B-2.2-only drain claim is wrong. |
| **#1182** S0 — *two interfaces declaring the same method name; `impl` order decides which runs* | route word carries a head tag, no interface identity | **B2.2-a/b/e** (identity includes interface identity) | Plausible drain **at B-2.2**. Must be probed, not assumed — it borders the out-of-scope method-namespace lane. |
| **#1564** S1 / **#1599** S0 | candidacy/evidence split; RUN-045's *"order-dependence moved into the evidence channel"* | **B-2.1 + B2.2-b** | RUN-045's drain criterion is **evidence**, not candidacy (`DECISIONS.md:1315-1318`). Twice-run per §5 of the sprint doc. |
| **#1560** S0 — *mixed requires residual dropped* | `residualPredsOf` → `findMatchingImplReqsU` → `concreteReqMatchByIface:21715` reading `shadowKeyTableRef` | **B-2.1**, not mine | Do not claim it from B-2.2. |
| **#1113** | this whole unit | B-2.1…B-2.4 | Stays open per the sprint's closure policy. |
| **#1127** | supers flatten | legs 1+2 are **B-1** | **NOT drained.** §1.4. |

---

## 6. What I refused, and disagreements I am reporting rather than resolving

1. **Refused to cut B2.3-c (the carrier).** §4.3. The two viable shapes cost 22 and 85 sites and
   the choice is P0-C's; a bite naming neither would be the vague bite §4 forbids.
2. **Refused C-3** (a synthetic `Decl` carrier) on the new-AST-constructor trap.
3. **Refused to stamp identity at D8/D9** (`routeUndeterminedTop`, `resolveRecMono`). They mint
   `RKey` with **no selector in the path**; giving them an `InstId` fabricates an identity nobody
   selected. B2.2-d makes the choice explicit instead.
4. **Reported, not resolved — a cross-unit collision the sprint doc does not name.** B-2.1's
   "retire `KeyBuckets`/`keyForSite*` by DELETION" **necessarily edits B-2.2's region**:
   `EntailKind`'s four constructors each carry a `KeyBuckets` (`typecheck.mdk:18922-18951`) and
   all four `inst` arms call `keyForSite`/`keyForSiteByIface`. **B-2.1 and B-2.2 cannot be given
   to two implementers, even serially, without B-2.1 first fixing the selector's return type.**
   My recommendation (§3): **B-2.1's IE-backed selector returns the selected ROW, not a projected
   `String`.** This needs the B-2.1 owner's assent; I am not ruling on their unit.
5. **Reported, not resolved — the declaration-index defect touches my units.**
   `KeyEntry`'s 8th field is a per-module-restarting declaration index
   (`bucketKeyEntriesFrom:17751-17754`), consumed as an ordering by `mergeByDeclIdx:18052`.
   B-2.2's identity does **not** by itself specify the selector's tie-break, so an `IE`-backed
   replacement can inherit the defect. That adjudication is a separate Phase 0 deliverable
   (`.claude/STAGE-B-SPRINT.md:126-132`); I flag the dependency and stop.
6. **Reported: the Flat-path question is open** (B2.3-b `nearest miss:`). I did not derive which
   drivers still take the Flat fallback, so I cannot assert every engine receives the frozen
   table. Owed before B2.3-d lands.
7. **Wording difference reported, per instruction:** brief/#1113 vs `DICT-SEMANTICS.md:957-960`
   (§4.1). They agree substantively; the brief is strictly stronger on two quantifiers the doc
   leaves implicit. The doc wins on conflict; there is none; I adopt the stronger reading and
   record that I did.
8. **Not verified, and I say so rather than implying otherwise:** no binary existed for me, so
   **nothing here is measured.** In particular the claim at `typecheck.mdk:17852-17858` — that
   behaviour surviving the route-word move rests **empirically** on the `noneHeadTag` fallback
   tier — is the tree's own warning, relayed, and it is exactly what B2.2-b's implementer must
   re-derive on a build.

---

## 7. ADDENDUM — answering the orchestrator's three questions (P0-FABLE + P0-A convergence)

Added after reading `.claude/sprint-b/phase0/P0-FABLE-c4i2.md` (organ 2, organ 4) and
`.claude/sprint-b/phase0/P0-A-reader.md` (`B-2.1-b`'s third `nearest miss:`). **I re-derived every
citation I rely on below rather than relaying either file.** Where I correct them I say so.

### 7.1 Does `ImplBuckets` belong in MY bite list? — **NO. It is B-2.1's axis. But it BLOCKS B-2.2, and the gap is BIGGER than Fable states.**

**Fable's derivation is correct on every point I checked**, and two of its citations are the
sharpest facts in this whole Phase 0:

- `implEntryOf` (`typecheck.mdk:17611-17616`) — verbatim body: `match reqs` → **`[] => []`** →
  `_ => implEntryFromTys …`. **`ImplBuckets` omits every impl that has no `requires`.** ✅
- `ImplBuckets`' own header, `:17574-17585`, verbatim: *"The forward intra-bucket order is
  load-bearing for the **RESIDUAL first-match consumer** (`findImplEntry`, the iface-unknown `""`
  fallback) … (#203: the element/requires routers that USED to first-match this table … **now
  select the most-specific impl over `KeyBuckets`** via `matchedEntry`/`selectImplEntryByIface`;
  forward order still decides their tie-break when no unique min⊑ exists.)"* ✅ — i.e. **the
  stampers' min⊑ runs on the table B-2.1 deletes.** Fable is right that this is the gap.
- `stampImplTable = buildImplTable implDecls` at **`:28677`**, `implDecls` = *"core + every EARLIER
  module + this module"* (`:28666-28668`), order-observable comment at `:28065-28066`. ✅

**Three sharpenings, all derived, all of which make the gap wider than Fable's row 2 states:**

1. 🚨 **It is a PAIR of tables, not one — and the second one is a THIRD `KeyBuckets`
   population that nobody has named.** Beside `stampImplTable` at `:28677` sits
   **`stampKeyTable = buildKeyTable implDecls` at `:28682`** — built from the *same cumulative
   prefix*. So the min⊑ that `#203` moved onto `KeyBuckets` runs on **`stampKeyTable`**, which is
   **not** the population B-2.1 repoints. Derived populations of `KeyBuckets`, all three:
   - `crossRun.universeKeyBucketsRef` — cumulative accumulator (`:25755`);
   - `perRun.shadowKeyTableRef` — **Flat**: `buildKeyTable fullUniverse` (`:20347`); **Module**:
     a wholesale copy of the cumulative accumulator (`:20348`). *This* is what
     `concreteReqMatchByIface` (`:21715`) and the two SHADOW readers (`:11216`, `:11503`) read,
     and it is the only one line 68 of the sprint doc names;
   - **`stampKeyTable` (`:28682`) + its Flat peer `keyTable = buildKeyTable prog2` (`:14123`)** —
     what every route stamper reads. **Unnamed in the sprint doc, unnamed in Fable's row 2.**

   Consequence, stated as the thing to attack: **deleting `universeKeyBucketsRef` does not by
   itself move a single stamper's min⊑.** An implementer could execute line 68 to the letter,
   see the reader repointed, and leave the entire stamping side on a cumulative prefix.
2. **Count correction — it is SEVEN table-consuming stampers, not five.** Fable says "all five
   resolve\* stampers"; that number is inherited from the tree's own stale comment at `:28679`
   (*"was rebuilt from `implDecls` at each of the five resolve\* sites below"*). Derived:
   `grep -n 'stampImplTable\|stampKeyTable' compiler/types/typecheck.mdk` → the pair is consumed
   at **`:28683` `:28684` `:28685` `:28687` `:28688` `:28690` `:28691`** (`resolveSites`,
   `resolveOpSites True`, `resolveOpSites False`, `resolveArgStamps`, `resolveRLocalSites`,
   `resolveDictApps`, `resolveMethodDicts`). `resolveArithSites`/`realizeRecDictApps` take no
   tables. **A bite list that says "five" leaves two stampers on the old population** — and one
   of the two it would leave is `resolveRLocalSites`, which is SHADOW territory (#616) and needs
   that spec cited. This is `DERIVE, don't encode` failing inside a file that enforces it; I am
   not scoring a point, I am removing a number from a bite list.
3. **The order-sensitivity is Module-path-only, exactly mirroring the reader's asymmetry.**
   `buildImplTable` has **two** call sites (`grep -n buildImplTable`): `:14122` (Flat, over the
   whole `prog2`) and `:28677` (Module, cumulative prefix). Same shape as `:20347` vs `:20348`.
   So "the stamper reproduces the reader's Flat/Module split" is a derived statement, not an
   analogy — which also means the **Flat path is not where a repro will come from**, and a
   single-file fixture cannot exercise this gap at all.

**Ownership ruling I am asking you to make, with my recommendation.** `ImplBuckets`/`stampKeyTable`
are a **population** change (which instances a selector may see). B-2.2 is a **payload** change
(what the route says about the instance selected). Those are different axes and the arch doc
assigns the population one to the reader unit (`TYPECHECK-TARGET-ARCHITECTURE.md:1820`: *"`IE`
supplies the data, B-2 moves the reader"*). **So: NOT in my bite list — it belongs to B-2.1's.**
But it is a **hard prerequisite** for B2.2-b: identity minted at `inst` from a cumulative-prefix,
no-requires-omitting population is *order-sensitive identity*, i.e. RUN-045's defect with a more
authoritative-looking payload. **Stamping identity on top of that population is worse than not
stamping it**, because every consumer is then taught to trust the word.

**Can it be cut Sonnet-sized under §4's test? YES — as threading, with one semantic bite carved
out, and the cost is volume not judgement.** Derived cost:
`grep -n "^[a-zA-Z][a-zA-Z0-9']* :.*\(ImplBuckets\|KeyBuckets\)" compiler/types/typecheck.mdk | wc -l`
→ **49** top-level signatures thread one or both. Both are `export type`s
(`:17588-17589`) but **no other `.mdk` file uses them** — the only out-of-file hits are comments
in `llvm_emit.mdk:1481`, `:5313` and `registry.mdk:455`
(`grep -rn 'ImplBuckets\|KeyBuckets' --include=*.mdk compiler/ | grep -v typecheck.mdk`). So the
blast radius is **one file, ~49 signatures**. Cut it as:
- **(threading, mechanical, Sonnet-safe):** replace the two table params with one `IE`-derived
  accessor across the 49 signatures + the 7 stamper calls + the Flat peer (`:14122-14131`).
- **(semantic, NOT Sonnet-safe — hand it to the sub-orchestrator):** the iface-`""` **first-match**
  fallback in `findImplEntry` (`:18874-18883`, header at `:17578-17580`) must become min⊑ over
  `IE` **or** a located reject (Door-4 precedent). Fable's item 1 says the same; I agree and add
  the reason it must be separate: it is the only part of the change that can move a **verdict**.

### 7.2 The separability question — my claim, stated so you can attack it

> **CLAIM: NO. `B-2.1-b` cannot land alone AS A DRAIN, and the tree has already measured exactly
> that. Worse, landing it alone risks a severity INCREASE rather than a partial fix.**

**Leg 1 — the tree already ran this experiment and wrote down the answer.**
`typecheck.mdk:22205-22211`, verbatim, in the source (not in a ledger):

> 🚨 **REJECT, DO NOT ROUTE.** Handing this arm the `requires` from `univ` would be **"move only
> the checker's leg"** — `TYPECHECK-TARGET-ARCHITECTURE.md:1814-1815` defers both the re-key and
> the reader move to B-2 BY NAME, and **the tree has already MEASURED that desynchronizing the
> checker from the router yields an `argReqRoute` of `RNone` and a binary that still faults**
> (`residualPredsOf`'s header, #1560).

`.claude/sprint/DECISIONS.md:1297-1298` records the same as RUN-045's **door 3**, *"already
measured … `argReqRoute` → `RNone`, and the binary still faults."* **This is not an open question;
it is a closed door being reopened without its measurement.**

**Leg 2 — P0-A's `iff` condition does not merely lack evidence; it is DERIVABLY FALSE.** P0-A
writes *"it can land alone iff both legs compute min⊑ over populations that agree — which nothing
has established for these two."* I can state it stronger, which is the useful direction:

1. After `B-2.1-b` the checker's population is **graph-global `IE`**; the router's is the
   **cumulative prefix** `implDecls` (`:28677`, `:28682`). Not equal by construction.
2. The router's `ImplBuckets` **omits every no-requires impl** (`:17613-17615`). The two are not
   even the same *kind* of set, so no ordering fix could make them agree.
3. The router's min⊑ reads **`stampKeyTable`** (`:28682`) — a population `B-2.1-b` does not
   touch (§7.1 sharpening 1).

**⇒ the `iff` fails on three independent grounds. P0-A's reading is right and its hedge is too
weak: this is an established negative, not an unestablished positive.**

**Leg 3 — the direction of the failure, which is the part that decides your phase question.**
`B-2.1-b` alone makes the **checker** recover an impl's `requires` where the **router** still
does not. The checker's leg is what gives a definition its leading dict **parameters**
(`dict_pass`); the router's leg is what makes a call site pass dict **words**. `ast.mdk:706-712`,
verbatim, on exactly that skew:

> `dict_pass` gives such a definition leading dict PARAMETERS, so the call site must supply the
> matching dict WORDS or it silently **UNDER-APPLIES** (`check` green, `run` type-confused,
> `build` prints a raw PAP pointer — the S-1 miscompile).

So the risk is not "drains less than claimed"; it is **"creates new under-application sites"** —
a fix that makes a defect quieter/wider, which `AGENTS.md` ranks as a severity increase. That is
why I would not let this land alone even with the drain claim withdrawn.

**Recommendation (yours to rule; I am not ruling on phase structure).** Do **not** collapse Phase
2 into Phase 3 — that loses the STOP-AND-LAND gate *and* the attribution the deferred-golden
posture depends on. **Re-cut the boundary along the axis instead:**

| | new phase | content | bar |
|---|---|---|---|
| **Phase 2′** | **population unification** | ONE graph-global `IE`-derived population for **every** min⊑ consumer: the reader (`:21715`), the 7 stampers (`:28683`…`:28691`), the Flat peer (`:14122-14131`). Delete `ImplBuckets` + `KeyBuckets` + `keyForSite*`. **Route payload stays a `String` word.** | acceptance + emitted evidence move where a module prefix hid the winner — **this is the drain**, and both legs move together, satisfying `:22205-22211` |
| **Phase 3′** | **payload identity** (my B2.2-a/b/e) | the word becomes an identity; no population changes | symbol renames, seed + goldens move; **no** acceptance change |

Two properties this cut buys that collapsing does not: (i) the STOP-AND-LAND gate lands on a
coherent, landable, drain-complete PR; (ii) the repair round can attribute a moved golden to
*population* or to *representation* by which commit it appeared in — the F-3 attribution property
the sprint doc protects for B-1/B-2 and would otherwise lose inside B-2.

### 7.3 The `expandSupersTable` fill bite — **INSIDE B-2.2. It largely collapses into my B2.2-d, and Fable's MECHANISM is wrong in a way that changes the fix.**

**Verdict first: Fable's organ-4 gap is REAL, in-scope, not B-1, and one bite — I agree with all
four.** I take it, as **B2.2-d′** below. But I disagree with its mechanism, and the disagreement
makes the bite cheaper and better targeted.

**Fable says the fill "copies the sub slot's route" and the remedy is per-slot independent
entailment of every appended slot. DERIVED: nothing copies, and the per-slot iface is already
available.** `expandSupersIfaceEntry` (`:9060-9064`) maintains `funConstraintIfacesRef` **in
parallel** with the id list, so **each appended slot records its own super interface.** Whether
the fill is per-slot therefore depends entirely on which fill path runs, and there are **three**:

| fill path | site | per-slot iface? | what it stamps |
|---|---|---|---|
| `routesOfMonosTop` / `routesOfMonosTopV` / `topRouteV` | `:19166-19173`, `:19129-19137`, `:19148-19149` | ✅ **YES** — the iface list is threaded and reaches `routeOf … iface …` | already a per-slot entailment; **organ 4 does not apply here** |
| `routesOfMonos` | `:19218-19222`, one caller at `:19405` | ❌ **NO** — passes `routeOf implTable keyTable **""** ""` | iface unknown ⇒ the `findImplEntry` iface-`""` **first-match** fallback (`:17578-17580`) |
| `recRoutes` → `recRoute` → `resolveRecMono` | `:19421-19439` | ❌ **NO** — the signature has no iface parameter at all (`recRoutes : String -> Mono -> List Int -> List Route`) | `RKey tag []` from the bare head — **my D9** |

**So organ 4 is not "the fill copies"; it is "two of the three fill paths are iface-BLIND", and
the appended super slot is indistinguishable from its sub slot only on those two.** That matters
because Fable's remedy ("re-resolve each appended slot") would rewrite a path that is already
correct, while the two that are wrong are wrong for a *nameable* reason with a *smaller* fix.

**B2.2-d′ (folded into B2.2-d, not a new unit):**

- **sites:** `routesOfMonos:19218-19222` + its caller `:19405` · `recRoutes:19421-19423` ·
  `recRoute:19430-19433` · `resolveRecMono:19435-19439` (the D9 stamp).
- **transform:** thread the per-slot interface (already in `funConstraintIfacesRef`) into both
  iface-blind paths, so each slot — declared or appended-super — is entailed **at its own
  interface**. `resolveRecMono`'s `Some tag => RKey tag []` then goes through the one selector
  instead of minting a bare head tag, which is the same edit D9 already needs.
- **why this is C2, not an optimization:** `DICT-SEMANTICS.md:1281-1297` — `supers.D` must be the
  evidence of the **most-specific** `D`-instance at the construction goal. An iface-blind fill
  cannot express that, and B-2.2 is the change that makes the wrongness *nameable* (an identity
  that says "the sub's impl" where a `D`-dict is required).
- **could move:** the dict word at every `=>`-constrained call whose function has ≥1 appended
  super slot, and at every recursive constrained call. **Diagnostics can move too** (an
  iface-blind first-match becoming a min⊑ can surface `T-AMBIGUOUS-INSTANCE`).
- **nearest miss:** Fable's is right and I adopt it — a `Sub a requires Sup a` chain where sub and
  super have **different** most-specific impls at the goal. **Mine to add, because it is the one
  this bite does NOT fix:** #1127's **leg 2** — `activeDictVars` is keyed by **tyvar id alone**
  and `expandSupersFix` gives the appended slot the **same id** as its sub slot, so a goal
  discharged by the **`assum`** rung still cannot tell the two slots apart. Fill-path iface
  threading does not touch the `assum` rung. **⇒ #1127 remains undrained (consistent with §1.4),
  and any claim otherwise is wrong.**
- **engines:** all three (route words move). Owes P0-C the same seam as B2.2-e.
- **INVARIANT (a-i) remains the fallback, not the plan:** for any fill path whose per-slot iface
  is *not* threaded in this sprint, that path's slots **must not be identity-stamped** (§1.3).
  B2.2-f still buys the boundary that makes (a-i) expressible.

### 7.4 Disagreements, consolidated (per the brief: I would rather record these than a consensus)

| # | With | Claim | My verdict |
|---|---|---|---|
| 1 | P0-FABLE | "all **five** resolve\* stampers" | **Wrong count, 7.** Inherited from the tree's stale comment `:28679`. Derivation in §7.1-2. |
| 2 | P0-FABLE | the gap is `ImplBuckets` | **Understated.** It is `ImplBuckets` **and** `stampKeyTable` (`:28682`), a third `KeyBuckets` population the sprint doc's line 68 does not reach. §7.1-1. |
| 3 | P0-FABLE | organ 4: the fill "copies the sub slot's route"; remedy = re-resolve every appended slot | **Mechanism wrong; verdict right.** The per-slot iface exists (`:9060-9064`); **two of three** fill paths are iface-blind (`:19218-19222`, `:19421-19439`). Smaller, better-targeted fix. §7.3. |
| 4 | P0-A | "can land alone **iff** populations agree — which nothing has established" | **Too weak, same direction.** Derivably FALSE on three grounds. §7.2 leg 2. |
| 5 | sprint doc §1 line 68 | B-2.1's site list | **Incomplete** — agrees with Fable, and wider than Fable says (item 2). |
| 6 | — | anything measured | **Nothing in this addendum is measured.** No binary was available to me. Every claim is source-derived at BASE `2b9dc798`, and #1560's fault behaviour is the tree's own recorded measurement, relayed with its citation. |
