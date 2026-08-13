# P0-D — B-3 bite list (#991, #994) + the three adjudications (#1114, #1265, #1597)

**Agent:** P0-D, Phase 0, Stage B sprint. **Read-only.** This file is the only artifact written.
**Tree:** `/root/medaka/.claude/worktrees/giggly-tinkering-rainbow`, branch `arch/stage-b-sprint`,
`git rev-parse HEAD` → `2b9dc798fd7459e5cd0f3298bcb645a658a177fe` (== the briefed BASE),
`git status --short` → clean at the time every citation below was read.
**Binary:** `./medaka` was not used. Nothing here is measured on a running binary; every claim is a
reading of committed source, the tracker, or a committed ledger, and each says which.
**Posture:** where the brief's premise and the tree disagree, this file reports the disagreement and
stops the bite. Two of the four scope premises I was handed are wrong.

---

# 0. Headline — read this before cutting any B-3 work

| Node | Brief's premise | Verdict |
|---|---|---|
| **#991** | *"`implObls` still carries the pre-#838 tuple, three `Provenance` arms are dead, the numlit descope is unrecorded"* | 🚨 **ALL THREE CLAUSES ARE FALSE ON THIS TREE. #991 IS A DESK CLOSE, NOT A BITE LIST.** Landed in `fa9f7564` + `f37b2562`, both ancestors of BASE. |
| **#994** | *"fuse the slot-parallel lockstep table pairs … into single record-valued tables"* | ✅ **NOT landed — real work.** But it is **not three pairs**: pair 1 is now a **triple**, and pair 3 has **nothing to fuse** (its invariant is already a type fact). Full fusion is **not byte-identical** at six whole-table replacement sites. Bites below are cut to the byte-identical subset. |
| **#1114** | *"already LANDED … verify and close"* | ✅ **CLOSE, with two stale-citation repairs owed.** Policy half landed; #845/#792 both CLOSED with fixtures in tree. Closing comment drafted in §4. |
| **#1265** | ambiguous, adjudicate | ⛔ **OUT.** The pull-in rests on a **name coincidence**, derived and refuted in §5. Not the same defect as #1182 — both issues say so and name the discriminator. |
| **#1597** | presumption OUT | ⛔ **OUT**, presumption upheld. Pin exists and is well-formed. ⚠️ The brief's *"whose F-3 bite was refused"* is a **conflation** — see §6. |

**Consequence for the run's shape:** Phase 1 (B-3) is roughly **half the size the sprint doc
budgets**. B-3's stated purpose — *"the run's calibration unit … a mistake is mechanically visible"*
(`STAGE-B-SPRINT.md:143-144`) — survives, because #994's remaining bites are genuinely
byte-identical. But its second stated purpose — *"shrinks the obligation-storage surface that B-2
then edits"* (`:66`) — is **already delivered** and must not be re-claimed as this run's output.

---

# 1. #991 — REFUSED AS A BITE LIST. It is already in the tree.

`gh issue view 991 --json state` → **OPEN**. Its title is verbatim the brief's premise. Each of its
three clauses, checked against the source:

### Clause 1 — *"`implObls` still carries the pre-#838 tuple"* — FALSE

```
compiler/types/typecheck.mdk:6732
    implObls : Windowed UObligation,  -- #841: pendingImplObligations/N, ported onto Windowed; #991: onto UObligation
```

The issue body's own citation of the old shape (`Windowed (String, List String, Ty, Mono, Option
Loc)`) no longer resolves anywhere in the file. The `implOblToU` bridge the ask names for retirement
is **gone** — `grep -n 'implOblToU' compiler/types/typecheck.mdk` returns **three hits, all inside
comments recording its removal**, zero definitions and zero call sites:

- `:5257` — *"pre-#838 5-tuple, and the `implOblToU` bridge that converted it, are gone."*
- `:21764` — *"#991: the `implOblToU` bridge that used to project a surviving …"*
- `:20661` — a comment reading *"(projected via implOblToU)"*, describing history.

Both channels now store the same record (`obls : Windowed UObligation`, `:6754`). The
CHECK-time-vs-RECORD-time projection hazard the issue body did **not** anticipate was handled by an
explicit deferral arm — `data OblProjection = OpProjected | OpMethodOcc (List String) Ty Mono`
(`:5599`), read only through `uOblArgs` (`:5674-5677`), with the reasoning written out at
`:5578-5598` including the sentence *"🚨 THIS IS THE FACT #991'S BODY DID NOT HAVE."*

### Clause 2 — *"three `Provenance` arms are dead"* — FALSE, and verified past the comment

`:5558-5563` claims every arm is live. **A comment asserting a property is not the property**, so I
grepped the producers. All six arms have real stamp sites:

| arm | stamped at |
|---|---|
| `POperator` | `:10072` (`pushPendingObl … POperator`, `builtinClassPresent` guard) |
| `PNumLit` | `:10443`, `:23952`, `:23965` |
| `PMethodOcc` | `:10981` |
| `PCallSlot` | `:8914`, `:12085`, `:13938` |
| `PSchemeReinst` | `:10812` |
| `PMethodLevel` | `:11045` (recorder documented at `:11019`) |

Derivation: `grep -n 'POperator\|PNumLit\|PMethodOcc\|PCallSlot\|PSchemeReinst\|PMethodLevel'
compiler/types/typecheck.mdk` — 6 declaration lines (`:5566`–`:5576`) plus the sites above.
The issue's third ask (*"fix the stale `PMethodLevel` comment"*) is also done: `:5575-5576` now reads
`-- a method-level '=>' constraint slot  (#818, I3)`, with the *"not yet recorded"* text gone.

### Clause 3 — *"the numlit descope is unrecorded"* — FALSE

```
compiler/types/typecheck.mdk:6733
    numlitRefs : Ref (List (Mono, Ref (Option Float), Int, Ref Route)),  -- #991 ask 3, RULED: the numeric-literal channel STAYS BESPOKE — it is Float-DEFAULTING machinery (`setNumlitFloats`), not obligation checking, so it is deliberately NOT ported onto `UObligation` like `implObls` above was
```

That is the source-comment half of ask 2, in the exact place the issue asked for it (*"at the
`numlitRefs` field"*). The **tracker half** (*"and here"* — a closing comment on #991) is what is
still owed, which is why the issue is open.

### Provenance of the landing

`git log -L 6730,6735:compiler/types/typecheck.mdk`:

- **`fa9f7564`** — *"arch(#1446 P1+T2, with #991): the obligation channel's interface half becomes an
  identity"* — the diff flips `implObls : Windowed (String, List String, Ty, Mono, Option Loc)` →
  `Windowed UObligation`. #991 rode in on a **different** node's PR, which is exactly why the tracker
  never caught up.
- **`f37b2562`** — *"sprint(stage-a): ledger repair — correct a falsified claim, retire dead code"* —
  adds the `numlitRefs` descope comment.

### Ruling

> **#991 has no implementation bites. It is a desk item: one closing comment, plus the two stale
> citations #991's own landing created (bite `B-3-e` below). It must not appear in `DEBT.md` as
> implementation work, and Phase 1 must not claim it as output.**

⚠️ **The generalizable lesson, for the referee:** #991 landed **as a rider on #1446's PR**, so the
issue-to-commit link the tracker would need never existed. The sprint doc's own standing warning —
*"the tracker lags the tree in this arc, consistently and by several units"* (`STAGE-B-SPRINT.md:26`)
— applied to #991 and nobody applied it, because the issue TITLE reads like a live defect report and
was copied forward into the sprint doc (`:67`) and into my brief verbatim. **A title is an encoded
fact with no expiry.**

---

# 2. #994 — the real bite list, with two scope corrections

`gh issue view 994 --json state` → **OPEN**. Not landed: all six refs still exist as separate `Ref`s
(`:6747-6749`, `:6758-6759`, `:5955-5960`).

## 2.1 Correction A — pair 1 is a TRIPLE, not a pair

#994's body (2026-07-24) names `funConstraintsRef` + `funConstraintIfacesRef`. Since then **#1161
F-3a-ii added a third slot-parallel sibling**:

```
compiler/types/typecheck.mdk:6747-6749
    funConstraintsRef : Ref (List (String, List Int)),
    funConstraintArgsRef : Ref (List (String, List (List Mono))),
    funConstraintIfacesRef : Ref (List (String, List IfaceRef)),
```

Its slot-parallelism is asserted in-source at `:24277-24279` (*"so funConstraintArgsRef stays
slot-parallel to funConstraintsRef's ids"*). An implementer working from the issue body alone fuses
two of three and leaves the third dangling **beside** a fused record — strictly worse than today,
because the drift it re-enables is now invisible to a reader who sees a record and assumes it is
total.

## 2.2 Correction B — full fusion is NOT byte-identical. Six sites replace one member alone.

#994's premise is that the members are *"always prepended together"* and *"rewritten in lockstep"*.
**That is true only of the PREPEND sites.** There are whole-table **replacement** sites where one
member is `setRef`-replaced and its twins are deliberately left holding their previous value:

| site | writes | leaves untouched |
|---|---|---|
| `:28230` `dictPassModulesIfEnabled` | `funConstraintsRef` (`scopeArities …`) | `funConstraintIfacesRef`, `funConstraintArgsRef` |
| `:28231` same fn | `methodConstraintsRef` (`scopeMethodArities …`) | `methodConstraintPositionsRef` |
| `:28262` `dictPassModulesScoped` | `funConstraintsRef` | both twins |
| `:28264` same fn | `methodConstraintsRef` | `methodConstraintPositionsRef` |
| `:20562` module reseed | `methodConstraintsRef` (`++ crossModuleMethodConstraintsRef`) | `methodConstraintPositionsRef` |
| `:25317-25323` `registerInferredFor` | `funConstraintsRef` + `funConstraintIfacesRef` | **`funConstraintArgsRef`** |

The `methodConstraintPositionsRef` case is **behaviour, not sloppiness**, and this is the load-bearing
finding for the bite:

```
compiler/types/typecheck.mdk:8613-8622
alignedMethodConstraintIds name subst = match positionMatch name subst perRun.value.methodConstraintPositionsRef.value
  Some ids => Some ids
  None =>
    let entries = filterList (e => fst e == name) perRun.value.methodConstraintsRef.value
    …
        None => lookupAssocSL2 name perRun.value.methodConstraintsRef.value
```

and the field's own doc at `:5845`: *"Absent ⇒ fall back to alignedMethodConstraintIds."* A single
record-valued entry **cannot express "ids present, positions absent"** unless the positions field is
`Option`-typed — and if an implementer makes it non-optional and synthesizes a positions value at the
reseed sites, they will have **changed which arm `alignedMethodConstraintIds` takes**, silently, on
the cross-module method-dict path whose failure mode `:5858-5864` records as *"a dict is mis-bound
into a value parameter (`unknown op '+'` / garbage / run≠build)"*. Identically for
`funConstraintArgsRef`: absent ⇒ `fromOption []` at its sole reader `:8966`.

**Therefore Phase 0 rules the SHAPE, not just the sites:** B-3 takes #994's **own fallback wording** —
*"or, where the … pairing must stay two lookups deep, a paired-table type whose write op takes both
payloads"* — for **every** pair, and takes the single-record form for **none**. The invariant #994
exists to protect lives entirely at the *co-write* sites; a fused write op puts it in one place, which
is the stated goal, and is byte-identical by construction. Replacing the tables' representation is a
larger, non-byte-identical change and belongs behind a measurement, not in a calibration unit.

## 2.3 Correction C — pair 3 (crossModule bare/Qual) has nothing to fuse. DECLINED.

#994's third bullet asks to fuse `crossModuleFunConstraintsRef`/`…QualRef`,
`crossModuleFunConstraintIfacesRef`/`…QualRef`, `crossModuleMethodConstraintsRef`/`…QualRef`
(`:5955-5960`), on the ground that they are *"reset together only by whole-record re-mint."*

Three independent reasons this is not a fusion candidate, all read off the source:

1. **Different key TYPES.** Bare is `Ref (List (String, List Int))`; Qual is
   `Ref (List ((String, String), List Int))` (`:5955-5956`). They are not slot-parallel payloads of
   one key; they are two tables answering the same question under two different keys, read by
   different consumers (`lookupAssocSL2` on bare at `:8775`/`:8823`; `lookupQualArity`/
   `lookupQualIfaces` on Qual at `:8723-8724`, `:8780`).
2. **Different lifecycles.** At `:20621-20626` the bare refs are **replaced wholesale** from the
   per-module table while the Qual refs are **accumulated** (`attributeModuleArities mid prog … ++
   crossRun.value.crossModuleFunConstraintsQualRef.value`). A fused entry would have to hold one
   payload that is overwritten and one that grows.
3. **The invariant it cites is ALREADY a type fact.** The bare/Qual reset-together property is
   enforced by the `CrossRun` constructor, and the source says so at `:5870-5876`: *"the 22 per-run
   cross-module accumulators … are bundled into ONE typed record so their survive/clear lifecycle is
   a TYPE FACT, not prose … enforced by the constructor: a new accumulator cannot be added to the
   survive-set without appearing in freshCrossRun."* #158 PR2 already did the only thing #994's third
   bullet asks for.

Additionally, the source states the bare form is deliberately KEPT for a consumer the Qual form does
not serve (`:5768-5770`, `:5867-5869`: *"the per-module reseed … needs the bare form for the current
module's E6 cross-module call-site discovery"*). Collapsing them is a keying change, and #994's own
**Explicitly NOT in scope** paragraph forbids exactly that (*"the bare-String first-match keying of
`funConstraintsRef` itself … fusing a pair does not change its key discipline and should not try"*).

> **Ruling: pair 3 is DECLINED, with reason, and #994 closes without it.** The referee should treat a
> `DEBT.md` row claiming pair 3 as fused as a red flag, not a bonus.

---

## 2.4 THE BITES

All in `compiler/types/typecheck.mdk` unless stated. Line numbers are as of BASE `2b9dc798`;
**grep the symbol, not the number** — an earlier bite in the same unit will move them.

### B-3-a — one fused write op for the fn-constraint TRIPLE

**sites (3 writers, all prepend-shaped):**
- `:24268-24275` `registerMember` — writes all three (`funConstraintsRef`, `funConstraintArgsRef`,
  `funConstraintIfacesRef`).
- `:25317-25323` `registerInferredFor` — writes ids + ifaces, **not** args.
- `:14234-14235` + `:14245-14246` `promotedConstraints`/`promotedConstraintIfaces` snapshot/restore
  pair — writes ids + ifaces in lockstep, no args.

**transform:** add one helper beside `registerMember` —
`pushFunConstraint : String -> List Int -> List IfaceRef -> Option (List (List Mono)) -> Unit` — that
prepends onto all three refs, with `None` meaning *"no `funConstraintArgsRef` entry for this name"*.
Replace the three call sites' hand-written `setRef … :: …` triples/pairs with one call each.
`registerMember` passes `Some (keptConstraintArgs ifaceMonos argVecs)`; the other two pass `None`.
Do **not** touch the six replacement sites in §2.2.

**could move:** *Nothing — the prepend order and the per-ref payloads are unchanged; only the number
of statements that express them changes.* **Why that is checkable:** each ref's new value is
syntactically the same `(name, payload) :: old` cons it is today, and the helper performs the three
`setRef`s in the same textual order `registerMember` does now (`funConstraintsRef`,
`funConstraintArgsRef`, `funConstraintIfacesRef`) — order matters only per-ref, and each ref receives
exactly one write. The `Option` argument is what preserves the `registerInferredFor` asymmetry; a
non-optional args parameter would be the one way to move behaviour here, via `:8966`'s
`fromOption []`.

**nearest miss:** a **future fourth** parallel sibling, or a **replacement**-shaped writer. This bite
makes the three *prepends* atomic and does nothing for `:28230`/`:28262`/`:20562`, where
`funConstraintsRef` is replaced alone and its twins keep the previous module's rows. That is today's
behaviour and this bite preserves it; a program that depends on a *stale* `funConstraintIfacesRef`
entry surviving a `scopeArities` replacement behaves identically before and after. **Test it:** a
two-module fixture where module A registers a constrained fn and module B's dict-pass replaces
`funConstraintsRef` — assert the emitted dict arity is unchanged across the bite.

**engines:** none. `typecheck.mdk` only; no `Route` payload, no emitted-IR surface. LLVM / wasm / eval
all unmoved, no peers owed.

**#829 check (done, not delegated):** this bite adds **no record field**. If the implementer chooses
to introduce a small record for the payload triple, `data PerRun = PerRun {` (`:6712`) and
`data CrossRun = CrossRun {` (`:5880`) are both the **safe single-line** header form —
`grep -n '^data PerRun =$' -A1` returns nothing. ⚠️ `data DriverState =` / `  | DriverState {`
(`:5175-5176`) **is** the unsafe two-line form; this bite must not add a commented field there.

---

### B-3-b — `expandSupersTable`: one pass over the pair, ordering preserved

**sites:**
- `:9037-9041` `expandSupersTable` — the two parallel `map`s.
- `:9045` `expandSupersCross` — the same expansion over the cross-module snapshot pair, taking the
  two lists as arguments.

**transform:** replace the two `setRef`+`map` statements with a single computation that binds the
**pre-expansion** ifaces once and derives both new payloads from that binding, then writes both refs.

🚨 **THE TRAP, and the whole reason this is its own bite:** `:9039` calls
`expandSupersEntry allDecls perRun.value.funConstraintIfacesRef.value` — it reads the **OLD, un-expanded**
ifaces table — and only then does `:9040` overwrite that table with `expandSupersIfaceEntry`'s output.
A naive fusion into one traversal that expands ifaces first, or that reads the ifaces table after
writing it, feeds `expandSupersEntry` **already-expanded** ifaces and appends the super slots twice.
`:9026-9027` states the property that breaks: *"Appended AFTER the declared slots so existing slot
indices are unchanged; deduped by (iface, id) within an entry"* — the dedup is *within an entry*, so a
double expansion that produces distinct ids is **not** caught by it. The bite must `let` the old value
before either write.

**could move:** *Non-trivially — this is the one #994 bite where a correct-looking edit changes dict
ARITY.* If the read/write ordering inverts, every `=>`-constrained fn with a superclass gains
duplicate super slots; call sites over-apply dicts and define sites bind extra params. **Checkable
discriminator, no golden needed:** the `chain3b` transitive-supers fixture the function's own comment
names (`:9036`) plus any `Sub a requires Sup a` program — assert the emitted dict-param count per
constrained define is unchanged. This is the bite where `preflight`'s fixpoint is worth its cost.

**nearest miss:** `expandSupersCross` (`:9045`) — the cross-module snapshot arm. It takes the pair as
**arguments**, so fusing only `expandSupersTable` leaves a second copy of the same lockstep
requirement in a function whose name does not appear in #994's body. Landing one without the other is
the "one function built twice" shape. **Both sites are in this bite, deliberately.**

**engines:** none directly — but `expandSupersTable` decides emitted **dict arity**, which all three
engines consume, so a mistake here is a three-engine miscompile with no engine-specific edit. No peer
arms owed; the fixpoint is the guard.

⚠️ **Interplay, per #994's own body:** if B-1 (#993) landed, `expandSupersTable` would **disappear**
and this bite would be void. **B-1 is OUT of this sprint** (`STAGE-B-SPRINT.md:29`), so the bite
stands — but it must be marked in `DEBT.md` as *work B-1 will delete*, so the repair round does not
re-derive it as a permanent invariant.

---

### B-3-c — one fused write op for `methodConstraintsRef` + `methodConstraintPositionsRef`

**sites (exactly ONE co-write site):**
- `:23700-23705` `registerMethodConstraints` — the guarded prepend of both, under
  `if isEmptyL ids || hasAssocSL2 mname … then () else …`.

**transform:** one helper prepending both payloads under that single guard; the guard itself is
unchanged.

**explicit NON-sites, which the bite must name and must not touch:** `:20562`, `:20627`, `:20629`,
`:28231`, `:28264` all write `methodConstraintsRef` **alone**. Per §2.2 that asymmetry is behaviour:
positions-absent selects `alignedMethodConstraintIds`' fallback arm (`:8614-8622`, field doc `:5845`).

**could move:** *Nothing — one guard, one pair of prepends, both preserved verbatim.* Checkable
because the transform is a textual extraction of two adjacent `setRef`s that already sit inside one
`else` arm with no intervening reads; the guard is not duplicated, so the "registered twice" path
(`hasAssocSL2`) cannot change.

**nearest miss:** the five reseed sites above. A program where a method's positions entry is stale
relative to its ids entry — i.e. any multi-module program with a method-level `=>` constraint whose
interface is declared in an imported module (`:5849-5851` names core's
`foldMap : Monoid m =>` as the canonical case) — is **untouched** by this bite and still relies on
`positionMatch` missing and the fallback firing. **Test it:** `test/eval_modules_fixtures` /
`llvm_fixtures_modules` cell exercising a cross-module method-level constraint; assert the value is
unchanged. ⚠️ *That stale-positions-across-reseed shape looks like a latent defect in its own right.
I am NOT filing it — I have not reproduced it, and an unreproduced inference must not enter the
tracker. Recorded here as a question for the repair round.*

**engines:** none. Typecheck-side dict-arity registration; the arity it computes reaches all three
engines but no engine file is edited and no peer is owed.

---

### B-3-d — DECLINED: crossModule bare/Qual fusion

Not a bite. See §2.3: different key types (`:5955-5956`), different lifecycles (`:20621-20626`), and
the invariant is already enforced by `freshCrossRun` (`:5870-5876`). #994 closes without it; the
closing comment must say so, since a future reader comparing the issue body to the diff will
otherwise read three-minus-one as an unfinished job.

---

### B-3-e — the stale citations #991's own landing created (docs only)

This is the implementation half of #991's desk close. **Zero source risk, and it is owed**: #991
retired `implOblToU`, and two reviewed artifacts still cite it as live.

**sites:**
1. `docs/spec/DICT-SEMANTICS.md:2491` — the §11 **OD4** row's derivation reads
   *"the method-occurrence channel passes `True` (`map implOblToU perRun.value.implObls.items.value`)"*.
   That expression **no longer exists**; the live call is
   `checkCallObligations True False fullUniverse perRun.value.implObls.items.value`
   (`compiler/types/typecheck.mdk:20665`). The row's *claim* (the flag split is enforced by one
   parameter) is still true — only its evidence has rotted. ⚠️ Note `:20661`'s own comment still
   says *"(projected via implOblToU)"*; fix both or the next reader re-derives the stale form from the
   source and "confirms" the doc.
2. `compiler/TYPECHECK-TARGET-ARCHITECTURE.md:749` (family H) and `.claude/STAGE-B-SPRINT.md:67` —
   both write **"DICT-SEMANTICS §4.2 D1–D6"**. The spec forbids that spelling *in the section
   itself*: `docs/spec/DICT-SEMANTICS.md:790` — *"⚠️ **These rules are `OD1`–`OD6`, not `D1`–`D6`.
   §6.3 already owns `D1`–`D4`**"*. So the design doc's row H, the sprint doc, and my own brief all
   collide the deferral rules with the **defaulting** rules. Repair the design doc; the sprint doc is
   the run's own artifact and the orchestrator owns it.

**transform:** replace the dead expression with the live call site; change `D1–D6` → `OD1–OD6` in the
design doc row H.

**could move:** *Nothing — comment and Markdown only, no `.mdk` expression edited.* Checkable: the
diff touches zero lines inside any function body.
⚠️ **`make docs-links` and `make agent-doc-symbols` are the relevant gates** (every backticked symbol
must resolve) — and note that **`implOblToU` currently appears in prose as a symbol that no longer
exists**, so this bite may *fix* an agent-doc-symbols finding rather than risk one.

**nearest miss:** the other §11 rows. I checked OD1–OD6 only for `implOblToU`; I did **not** audit the
whole table's citations. `grep -rn 'implOblToU\|universeKeyBucketsRef\|keyForSite' docs/ compiler/*.md`
before declaring the sweep done — and note **B-2.1 deletes `KeyBuckets`/`keyForSite*`
by design** (`STAGE-B-SPRINT.md:68`), so that family is about to produce the same class of stale
citation. **Recommend the referee require a doc-citation sweep as part of B-2.1, not after it.**

**engines:** none.

---

### B-3-f — the desk close itself (orchestrator, not an implementer)

Post #991's closing comment (drafted below), then close #991. It is the tracker half of ask 2 —
*"#838 was closed with no closing comment, so the decision exists only in a session memory"* — and
leaving #991 open after B-3 recreates the exact defect #991 was filed about.

> **#991 — CLOSED: already landed, verified against `main` at `2b9dc798`.**
>
> All three residues this issue names are gone. Derivations, not assertions:
>
> 1. **Storage ported.** `implObls : Windowed UObligation`
>    (`compiler/types/typecheck.mdk:6732`), the same record as `obls` (`:6754`). The `implOblToU`
>    bridge is **deleted** — `grep -n implOblToU compiler/types/typecheck.mdk` returns only comments
>    recording its removal (`:5257`, `:21764`), zero definitions and zero call sites. Landed in
>    `fa9f7564` as a rider on #1446 P1+T2, which is why this issue never got linked.
> 2. **All six `Provenance` arms live**, checked at the producers rather than from the enum's comment:
>    `POperator` `:10072` · `PNumLit` `:10443`/`:23952`/`:23965` · `PMethodOcc` `:10981` ·
>    `PCallSlot` `:8914`/`:12085`/`:13938` · `PSchemeReinst` `:10812` · `PMethodLevel` `:11045`.
>    The stale `PMethodLevel` comment is fixed (`:5575-5576`).
> 3. **Numlit descope recorded in source**, at the field this issue named:
>    `:6733` — *"#991 ask 3, RULED: the numeric-literal channel STAYS BESPOKE — it is
>    Float-DEFAULTING machinery (`setNumlitFloats`), not obligation checking"* (`f37b2562`).
>
> ⚠️ **One fact this issue's body did not have, recorded because it changed the design.** The body
> predicted *"byte-identical target: … this changes only the record shape"* and proposed dropping the
> tuple onto `UObligation` outright. That would have moved a **check-time** projection to **record**
> time: `recordImplObligation` records a method occurrence against the method's DECLARED type, and
> `dispatchMonosOf` is only meaningful after `groundMultiParamObligations` has grounded the shared
> cells. The deferral is carried explicitly instead —
> `data OblProjection = OpProjected | OpMethodOcc (List String) Ty Mono` (`:5599`), read **only**
> through `uOblArgs` (`:5674`), with the reasoning at `:5578-5598`. `pred.args` is EMPTY on an
> `OpMethodOcc` obligation and reading it directly is silent (an empty vector is inert at the gate),
> which is why there is one accessor rather than a convention.
>
> The `#863` flag split the Hazards paragraph protects is intact: `deferNonGround`/`dedup` are still
> per-channel parameters of one checker (`:20665` passes `True False` for the impl channel).
> **#994 (table fusion) remains open and is unaffected by this close.**

---

# 3. Cross-cutting note for the B-2 units (unsolicited, cheap, and load-bearing)

While deriving §2.2 I read `:20363-20368`. The Module-arm reseed copies
`crossModuleFunConstraints{,Ifaces}Ref` into the per-run refs and then **prepends** the alias-rekeyed
Qual entries. This is the same *"the Module arm copies wholesale"* shape the sprint doc flags for
`universeKeyBucketsRef` → `shadowKeyTableRef` at `:20347-20348` (`STAGE-B-SPRINT.md:151-153`).
**These are two different table families and B-2.1's `IE` repoint touches only the second.** I flag it
only so that an implementer greping `20347` does not "tidy" the adjacent `20363` block in the same
region edit — that would put a keying change (#994's explicit non-goal, and D2's deferred re-key) into
a bite briefed as a reader repoint. **Region discipline: `:20347-20348` is in scope for B-2.1;
`:20363-20368` is not.**

---

# 4. ADJUDICATION 1 — #1114 (B-3-ext): **CLOSE.** Verified, with two repairs owed.

**Claim under test** (`compiler/TYPECHECK-TARGET-ARCHITECTURE.md:749`, family H): *"ONE written
deferral policy (B-3's scope — **LANDED as DICT-SEMANTICS §4.2 D1–D6 + its §11 rows**, #1114) …
**#845 and #792 DRAINED (#1114)**"*. `gh issue view 1114 --json state` → **OPEN**.

Per the brief's warning that *a partial identity reads as done from any single table*, I checked the
**set** of #1114's asks, not the design doc's summary of them.

### Ask 1 — *"ONE written deferral policy (a short spec/design note + the enforcement-table row)"* → ✅ DELIVERED

`docs/spec/DICT-SEMANTICS.md:782` — `### 4.2 Obligation deferral: which predicates defer, and where a
deferred one is discharged`. Six rules present and individually stated: **OD1** `:819`, **OD2** `:847`,
**OD3** `:854`, **OD4** `:858`, **OD5** `:876`, **OD6** `:884`, with two corollaries at `:893-926`.
The #863 hazard #1114 called load-bearing is honoured rather than flattened: **OD4** is titled *"the
impl-channel exemption from OD3 is load-bearing, and is not a mode fork"* (`:858`) and `:866-872`
records both rejected alternatives and why each is unsound.

§11 enforcement rows exist for all six: `:2488` (OD1), `:2489` (OD2), `:2490` (OD3), `:2491` (OD4),
`:2492` (OD5), `:2493` (OD6).

⚠️ **The naming in the design doc's claim is wrong** and the spec anticipated exactly this error:
`:790` — *"⚠️ These rules are `OD1`–`OD6`, not `D1`–`D6`. §6.3 already owns `D1`–`D4`"* (defaulting).
Repaired by bite **B-3-e**.

### Ask 2 — *"then make both channels conform"* → 🟡 PARTIAL, and every residual is separately tracked

Read off the §11 rows' own verdicts, verbatim:

| rule | §11 verdict | residual owner |
|---|---|---|
| OD1 `:2488` | 🟡 ENFORCED, after a refuted first attempt | — (`uOblIsDecidableNow` derived from the gate's decision structure) |
| OD2 `:2489` | ✅ ENFORCED | — |
| OD3 `:2490` | 🟡 PARTIAL — fires only at instance-count ≥ 2 | pre-existing, deliberate divergence, documented |
| OD4 `:2491` | ✅ ENFORCED, by ONE parameter | — (stale citation → B-3-e) |
| OD5 `:2492` | 🔴 **DIVERGENT** on the constrained-binding channel | **#1330** (OPEN, S0, verified) |
| OD6 `:2493` | 🟡 PARTIAL — four drained, three measured residuals | **#1330**, **#1326**, **#1337** |

**This is the discriminating question and it is why the close is safe:** does #1114 still own the
residuals, or have they been re-homed? They are re-homed, and each with a named issue and a measured
observable — #1330 (five prelude-only lines: `check` 0 → `build` 0 → segfault 139), #1326 (the
bare-name value family, *"Independent of #1114 (reproduces with its lookup ablated to `None`)"*),
#1337. Row `:2488` also records that OD1's first attempt was **refuted in review** on
`Debug (Int -> Int)` and corrected — i.e. the conformance work was adversarially reviewed, not
self-certified. **Nothing on that list is a #1114 deliverable that quietly went missing.**

### Ask 3 — the **Bar**: *"check/run/build agreement fixtures for both issues"* → ✅ DELIVERED

`ls test/must_fail_fixtures/` is the wrong place; the bar names the `run_check_agreement` family, and
`ls test/run_check_agreement_fixtures/` shows the cells, with two shapes each as the design doc
claims:

- `accept_792_parametric_impl_abstract_and_ground.{mdk,expected,out}`
- `accept_845_reexport_satisfiable.*`, `accept_845_unrelated_module_same_name.*`,
  `accept_845_xmod_all_spellings_satisfiable.*`

### The owned issues

- `gh issue view 845 --json state,closedAt` → **CLOSED**, `2026-08-05T22:16:18Z`.
- `gh issue view 792 --json state,closedAt` → **CLOSED**, `2026-08-05T22:15:48Z`.

Both closed **before** BASE. The design doc's *"#845/#792 both CLOSED"* is accurate.

### RULING

> ## ✅ #1114 is a DESK CLOSE. It is not implementation work and must not consume a Phase-1 bite.
>
> Policy written (§4.2 OD1–OD6 + six §11 rows), both owned issues CLOSED with fixtures in tree,
> and every conformance residual re-homed to a named, verified issue rather than left implicit.
> **Two repairs are owed and both are in bite B-3-e** (the `D1–D6`/`OD1–OD6` naming in design-doc row
> H; the dead `implOblToU` citation in §11's OD4 row). Neither blocks the close.

**I did not close it.** Draft closing comment, for the orchestrator to post:

> **#1114 — CLOSED: delivered. Verified against `main` at `2b9dc798`, ask by ask.**
>
> 1. **ONE written deferral policy.** `docs/spec/DICT-SEMANTICS.md` **§4.2** (`:782`) — six rules,
>    individually stated: OD1 `:819` · OD2 `:847` · OD3 `:854` · OD4 `:858` · OD5 `:876` ·
>    OD6 `:884`, plus corollaries (a)/(b) at `:893-926`. ⚠️ They are **`OD1`–`OD6`, not `D1`–`D6`** —
>    §6.3 already owns `D1`–`D4` for *defaulting*, and the spec warns about this collision at `:790`.
>    Several downstream citations (including `compiler/TYPECHECK-TARGET-ARCHITECTURE.md:749`) use the
>    wrong spelling; corrected separately.
> 2. **The enforcement-table rows.** `docs/spec/DICT-SEMANTICS.md:2488-2493`, one per rule.
> 3. **The #863 hazard is honoured, not flattened.** OD4 (`:858`) is titled *"the impl-channel
>    exemption from OD3 is load-bearing, and is not a mode fork"*, and `:866-872` records both
>    rejected alternatives (applying OD3 in place; widening `deferrableVarIds`) with why each is
>    unsound. §11's OD4 row confirms the split survives as **one parameter, not two checkers**.
> 4. **Both owned issues are CLOSED with their fixtures in tree.** #845 (2026-08-05) and #792
>    (2026-08-05), pinned in `test/run_check_agreement_fixtures/` —
>    `accept_792_parametric_impl_abstract_and_ground`, `accept_845_reexport_satisfiable`,
>    `accept_845_unrelated_module_same_name`, `accept_845_xmod_all_spellings_satisfiable`. Two shapes
>    each, as `TYPECHECK-TARGET-ARCHITECTURE.md` §4 family H records.
>
> **What this close does NOT claim — stated so no one reads it as full conformance.** §11 grades OD1
> 🟡, OD3 🟡, **OD5 🔴 DIVERGENT** and OD6 🟡. Every residual is separately owned and separately
> verified: **#1330** (OD5 on the constrained-binding channel — five prelude-only lines give
> `check` 0 → `build` 0 → segfault 139), **#1326** and **#1337** (the bare-name value family;
> #1326 reproduces with #1114's lookup ablated to `None`, so it is not a #1114 regression).
> OD3's sole-impl default is a deliberate, documented divergence. #1114 delivered the **policy** and
> its two owned defects; the remaining channel conformance lives on those issues.
>
> ⚠️ Also note OD1's row records that #1114's **first** enforcement attempt was **refuted in review**
> on `Debug (Int -> Int)` and corrected — the row is worth reading before touching
> `uOblIsDecidableNow`, because *"any arm added to `checkOneCallObligation` above its
> `allConcreteHeads` test must be mirrored in `uOblIsDecidableNow`, and no gate can catch the
> omission."*

---

# 5. ADJUDICATION 2 — #1265: **OUT.** The pull-in is a name coincidence.

`gh issue view 1265` → **OPEN**, `S0: silent wrongness, verified, ws:soundness, ws:typecheck`.

## 5.1 §9.3, quoted

The pull-in rests on `compiler/TYPECHECK-TARGET-ARCHITECTURE.md:1829`, the §9.6 disposition table:

> | `ifaceImplHeadsRef` / `ifaceIdsAtTag` / `defaultOwnedBy` / `narrowDefaults` / `CImplDefault`
> (`compiler/ir/core_ir_lower.mdk`, both emitters), `defaultCellName` cells
> (`compiler/eval/eval.mdk`) | the default-arm registry and its selector |
> **NOT `IE`, BY CONSTRAINT** (§9.3) — B-2 / #1265 |

§9.3 itself (`:1554`) is titled *"THE CONSTRAINT: `IE` is keyed by impl identity; the default-arm word
namespace is NOT `IE`'s"*, and its normative block is (`:1560-1565`):

> **`IE` holds impls. An interface's default-method arm is a property of the INTERFACE declaration —
> `CE`'s content (A-3a) — and the emit-side method/default *word* namespace belongs to B-2 (#1113),
> whose body already claims "the disjoint default-tag word namespace". No `IE` key component may be a
> method name.**

and immediately (`:1567-1569`):

> A future `IE` that folded the default-body/default-arm registry in and keyed it `(method, tag)`
> would rebuild #1265 in the new substrate: that pair is exactly the key whose two survivors #1265 is
> the first-match over.

## 5.2 The two readings, and which one §9.3's own text supports

- **Reading R1 (in):** the disposition column says *"— B-2 / #1265"*, therefore #1265 is B-2's to fix.
- **Reading R2 (out):** §9.3 is a **prohibition on `IE`**. Its disposition column answers *"is this
  table becoming part of `IE`?"* — answer *"no, and here is which stage's blast radius it sits in
  instead."* **#1265 is named as the ANTI-GOAL** — the thing §9.3 exists to avoid rebuilding — not as
  a work item.

**I rely on R2, and three things in §9.3 decide it:**

1. **Leg 3 is a declared NON-FLIP.** `:1615-1620`: *"`test/must_fail_fixtures/1265-two-ifaces-same-method-one-type-default-collapse` must stay RED
   across A-3.4 … It is the *observable* of this constraint: if A-3.4 changed the default-arm answer
   in any direction, the pin flips and the must-fail gate reds naming #1265."* A design that assigned
   #1265's fix to a stage would not make its pin an unflipped tripwire; it would schedule the flip.
2. **The whole section is about what `IE`'s key may contain**, enforced by a greppable ratchet
   (`:1580-1588`: check 4 fails if any of `defaultFnName`, `defaultCellName`, `ifaceIdsAtTag`,
   `defaultOwnedBy`, `narrowDefaults`, `CImplDefault`, `methodIfaceTableRef` appears inside `IE`'s
   block). That is a **prohibition on mentioning these symbols in the new substrate** — the opposite
   of a mandate to rewrite them.
3. **The table's other rows use the same column the same way.** `:1829`'s neighbours read
   *"**NOT `IE`** — #1112 §1 row 7: belongs with B-2"* and *"**DEFERRED → B-2, by DELETION**"*. The
   column names **which stage's blast radius owns the table**, and pairs it with the issue that lives
   there. It is a routing note.

## 5.3 The pull-in is a NAME COINCIDENCE — derived

The strongest case for R1 is that the sprint doc's **B-2.4** charter says *"disjoint default-tag
namespace"* (`STAGE-B-SPRINT.md:71`), which looks like #1265's first fix bullet (*"emit
`mdk_default_<ifaceId>_<method>_<tag>`"*). **It is not.** #1113's body defines the phrase
parenthetically — `gh issue view 1113 --json body`, blast list:

> LLVM emitter `implEntryRouteWords` superset-OR retirement + `noneHeadTag` catch-all re-key + the
> **disjoint default-tag word namespace** (*synthesized default-method arms exist for receiver tags
> with no impl — do not collapse them into the instance namespace*)

So B-2.4's namespace is the **route-word** set: *default arms vs impl arms* must not collide as
dispatch words. #1265's collision is in the **emitted symbol / eval cell name**: two *different
interfaces'* default bodies for the same method at the same tag collide on
`mdk_default_<method>_<tag>` (`defaultFnName`, `llvm_emit.mdk:1342`; `defaultFnNameW`,
`wasm_emit.mdk:4516`; eval's cell keyed the same way). **Different namespaces, different symbols,
different sites.** Two things sharing the word "default" and the word "namespace" is not a scope
overlap, and this is precisely the *"a precise citation is not a verified one"* failure — the phrase
matches, the referent does not.

## 5.4 #1265 vs #1182 — NOT the same defect. The "out" ruling is therefore stable.

The brief correctly flags that if these were one defect at two granularities, then #1182 being on the
drain list (`STAGE-B-SPRINT.md:75`) would destabilize an "out" on #1265. **They are not.** Both issue
bodies state the discriminator, and they agree with each other:

| | **#1265** | **#1182** |
|---|---|---|
| impls | **method-LESS** (`impl Speak Dog where`, empty) | **method-BEARING** (`m _ = 1`) |
| defective machinery | the Core IR **untagged-default registry** — `ifaceIdsAtTag` (`core_ir_lower.mdk:1233-1240`), `narrowDefaults`/`defaultOwnedBy` (`llvm_emit.mdk:1321-1327`), `narrowDefaultsW` (`wasm_emit.mdk:4502-4508`), `pickDefaultCand` (`eval.mdk:1045-1060`) | the **shared front end** — `matchingEntries` selects by method-name membership, `pickMostSpecificEntry` ranks across interfaces |
| trigger | one TAG carries two interfaces; name resolution unambiguous (each call site has only one interface in scope) | two interfaces in ONE file; `impl` block ORDER decides |
| correct answer | **not in dispute** — DICT §5/§5.1 M1 + §8 I4 settle it (`A-default|B-default`) | **in dispute** — #1182's own "Disposition" offers two viable semantics |
| fix sites | 3 **engine** sites, in lockstep | 1 **typecheck** selector |

And #1265's own *"Not a duplicate"* section states the closing fact: **"Fixing #1182's selector would
not touch `narrowDefaults`."** #1182's Control also confirms its own mechanism is cross-interface
min⊑ ranking (a strictly-more-specific impl declared *second* still wins), which is a selector
property, not a symbol-name property.

> They are two members of the same **family** (#1070, bare-name keys with no interface component) at
> two different **tables**. Draining #1182's selector leaves #1265's symbol collision untouched, so
> #1182 ∈ scope and #1265 ∉ scope is coherent.
> ⭐ Per the standing rule *a drained fixture is not a drained class*: if B-2 lands a #1182 fix, the
> `1265-*` pin **must still read REPRO**. If it flips, something touched the default-arm registry and
> that is a finding.

## 5.5 RULING

> ## ⛔ #1265 is OUT of the Stage B sprint.
>
> §9.3, on **reading R2**, does not assign it to B-2: it *prohibits* `IE` from acquiring a method-name
> key component and makes #1265's pin the **unflipped observable** of that prohibition (`:1615-1620`).
> The apparent assignment via B-2.4's *"disjoint default-tag namespace"* is a **name coincidence** —
> #1113 defines that phrase as *default arms vs impl arms in the route-word set*, whereas #1265 is a
> collision in the emitted **symbol name** `mdk_default_<method>_<tag>` (§5.3). It stays in the
> **method-namespace lane (#1354 M-2)**, deferred out of Stage A by RUN-024, exactly as
> `STAGE-B-SPRINT.md:86` has it.
>
> **Two obligations this ruling creates, both cheap, and B-2.4 owes them:**
> 1. **`test/must_fail_fixtures/1265-two-ifaces-same-method-one-type-default-collapse` is a DECLARED
>    NON-FLIP for this whole run.** It goes in `.claude/HANDOFF.md`'s expected-state set as
>    *"must read REPRO"*, **not** in the expected-red set. If it flips, B-2 changed the default-arm
>    answer and the bite that did so has escaped its brief. Per §9.3 leg 3, that is the designed
>    tripwire.
> 2. **B-2.4's `engines:` row must state which default-arm symbols it touched.** Its charter reaches
>    `llvm_emit.mdk`, `wasm_emit.mdk` and `eval.mdk` — the same three files that hold #1265's fix
>    sites. Naming `defaultFnName`/`defaultCellName`/`narrowDefaults` as **untouched** is how the
>    non-flip stays checkable rather than hoped-for.
>
> **Overturn criterion, stated so it can be exercised:** if a B-2.4 bite finds it *cannot* retire the
> superset word-set arm without also re-keying `defaultFnName`/`defaultCellName`, then #1265 comes in
> **as a consequence** — and that is a Phase-0-level escalation, not an implementer's call, because
> #1265's second fix half (*select by the interface identity the call site resolved to*) is M-2's axis.

---

# 6. ADJUDICATION 3 — #1597: **OUT.** Presumption upheld. Plus one correction to the brief.

`gh issue view 1597` → **OPEN**, *"ARCH: the field-owner candidate set is a raw topological prefix —
an unreachable record votes, rejecting legal programs"*, labels `S1: loud breakage`, `verified`,
`ws:typecheck`.

## 6.1 ⚠️ Correction: the brief conflates #1597 with #1586

My brief says #1597 *"was Stage A's Unit F, whose F-3 bite was **refused as unreachable dead code**
(RUN-031)"*. Reading the ledgers, that is two different things welded together:

- **#1597 is Stage A's F-1/F-2, FILED as an ARCH node and DEFERRED — never refused.**
  `.claude/sprint/DECISIONS.md:782` — *"## RUN-029 — ⚖️ OWNER RULINGS EXECUTED: **#1597 filed**"*,
  ruling *"**F-1/F-2 filed as #1597**"*.
- **F-3 is #1586's `DAttrib` arm.** RUN-031 (`:843`) refuses *that* bite: `declEnvDeclFieldOwners`'s
  one production caller always takes the `m.demPubDecls` arm, `publicDataDecl:25234-25239` has **no
  `DAttrib` arm** (`_ = False`), so *"A `DAttrib` can never reach the briefed function."* Its ruling
  line reads *"**Unit F ships F-0 (a pin) ONLY, and drains NEITHER #1586 NOR #1383**"* — #1597 is
  mentioned there only in passing, as *"#1597 was deferred"* (`:873`).
- **F-0 is #1597's PIN**, and it landed: RUN-032 (`:886`) — moved to
  `test/must_fail_fixtures/1597-unimported-record-votes-in-field-owners/` on measured evidence that
  `check_module_fixtures` **structurally cannot see the bug** (that harness diffs only the *entry*
  module's scheme dump; the rejection lives in `bmod.mdk`).

The correction does not change the presumption — **both** framings land on OUT — but it changes the
*reason*, and a wrong reason propagates. #1597 is not "a refused bite"; it is a **deliberately
deferred fix with a landed self-draining pin**.

## 6.2 Why OUT

1. **Wrong territory.** #1597 is `DataEnv`/record-field machinery. RUN-031 names the real sites:
   `registerData:12504-12523`, `resolve.mdk`'s `fieldOwnersOf`, and `publicDataDecl` itself
   (`.claude/sprint/DECISIONS.md:864-871`). Stage B owns **evidence identity** — instance selection,
   `Route`, dict routing. Field owners are keyed by *record/field*, not by instance; no B-2 bite in
   the sprint doc's §2 unit list reads or writes `fieldOwnersRef` (`typecheck.mdk:6718`).
2. **It was already adjudicated out once, by the owner, with the pin as the deliverable.** RUN-029/030/031.
   Re-scoping it in without new evidence relitigates a closed decision.
3. **The sprint doc rules it out with the presumption stated** (`STAGE-B-SPRINT.md:90-92`), and
   nothing I found contradicts that.
4. **A partial fix risks a severity INCREASE.** RUN-030 (`:820`) dropped F-4 because *"Landing F-4
   alone would trade a **loud S1 for a silent S0** — a severity INCREASE, and precisely the loud→quiet
   regression this repo's ladder forbids"*, the coupling being #1382/#1383 and the emitter-side
   #1216. #1597 is the **loud** member of that neighbourhood (S1: it *rejects legal programs*), so a
   fix that makes it quieter is worse than leaving it. **This is the single strongest reason to keep
   it out of a deferred-verification sprint**, where the golden that would catch a loud→quiet flip is
   not being run.

## 6.3 What would have to be true to bring it in

Stated so the ruling is falsifiable rather than merely asserted:

1. **A B-2 bite is found to edit the field-owner seed** — the topological prefix / `depClosure` /
   `publicDataDecls` visibility computation. Then #1597 enters **as a constraint on that bite**
   (its pin must not flip), not as a drain.
2. **#1216's emitter-side slot fix lands or is brought in scope**, unblocking the F-4 ordering
   constraint. Ruled *"not ours"* at RUN-029; nothing in Stage B changes that.
3. **The candidate-set prefix turns out to be shared substrate with B-2's evidence visibility** — i.e.
   one function computes both *"which records are visible here"* and *"which impls are visible here."*
   I have **not** checked this, and I am not claiming it either way; it is the one hypothesis that
   would make #1597 genuinely Stage-B-adjacent, and it is answerable with a single grep by whoever
   cuts B-2.1's bites.

## 6.4 The pin — confirmed present and well-formed

`ls test/must_fail_fixtures/1597-unimported-record-votes-in-field-owners/` →
`amod.mdk`, `bmod.mdk`, `main.mdk`, `claim.txt`. Three modules plus the claim file; not malformed.
Its own comments encode the two ways it can stop testing the bug — worth quoting, because both are
the "probe that cannot fail" shape:

- `bmod.mdk`: *"🚨 `readTag` MUST STAY UNSIGNATURED. With `readTag : Wye -> Int` the annotation pins
  the receiver … the program then checks at exit 0 whether or not the bug is present. MEASURED before
  #1597 was filed: the signatured form was the first attempt and it FAILED to reproduce."*
- `amod.mdk`: *"🚨 DO NOT RENAME `tag`. The collision with `bmod`'s `Wye.tag` IS the fixture."*
- `bmod.mdk`: *"🚨 DO NOT ADD A `main` HERE"* — a second downstream `T-AMBIGUOUS-INSTANCE` would enter
  `diag-code:`'s whole-ordered-list assertion and an unrelated change would drain the row.

Its control is `bmod.mdk` **as its own entry, byte-for-byte** — only graph membership varies
(RUN-032, `:895-899`). That is a proper positive control: it varies one thing.

> **⚠️ NOT MEASURED HERE, and deliberately.** I did **not** run
> `test/diff_compiler_must_fail.sh`. Four other read-only agents are live in this worktree and a
> `make medaka` was running in the background when I started — the exact non-quiescent condition
> under which Stage A's RUN-032 reading of *"5 DRAINED"* turned out to be a **PHANTOM** (RUN-033,
> `:912`: *"There were ZERO drains … entirely an artifact of measuring against Lane A's uncommitted,
> half-applied edits"*). **The `1597-*` REPRO reading is owed on a declared-quiescent tree, twice**,
> per `STAGE-B-SPRINT.md:285-290`. Last clean reading of record: RUN-033 at `433bcffe` —
> *"98 still reproduce, 0 DRAINED"*, with `1597-*` REPRO named explicitly.

## 6.5 RULING

> ## ⛔ #1597 is OUT of the Stage B sprint. Presumption upheld.
>
> `DataEnv`/record-field territory (`registerData`, `resolve.mdk`'s `fieldOwnersOf`,
> `publicDataDecl`), not evidence; already adjudicated out by the owner in Stage A with its pin as the
> deliverable; and its neighbourhood carries a documented **loud-S1 → silent-S0** hazard (RUN-030)
> that a deferred-golden sprint is the worst possible place to risk.
>
> **`test/must_fail_fixtures/1597-unimported-record-votes-in-field-owners/` is a DECLARED NON-FLIP for
> the whole run and must read REPRO.** If it ever reads DRAINED, someone changed the field-owner seed
> — **that is a finding, not a deliverable**, and the first question is which bite touched
> `publicDataDecls`/`depClosure`. ⚠️ Second question, before believing it: *was the tree quiescent?*
> A DRAINED reading taken while any agent held uncommitted edits is a phantom until re-run twice
> (RUN-033).

---

# 7. Summary of everything this file rules

| id | node | verdict |
|---|---|---|
| **B-3-a** | #994 | ✅ bite — fused write op for the fn-constraint **triple** (`:24268`, `:25317`, `:14234`/`:14245`). `Option` args payload preserves the asymmetry. |
| **B-3-b** | #994 | ✅ bite — `expandSupersTable` (`:9037`) **+ `expandSupersCross` (`:9045`)**. 🚨 read-old-ifaces-before-write ordering is load-bearing; inverting it doubles dict arity. |
| **B-3-c** | #994 | ✅ bite — fused write op at `registerMethodConstraints` (`:23700`). The five ids-only reseed sites are **explicit non-sites**; positions-absence is behaviour (`:5845`, `:8614`). |
| **B-3-d** | #994 | ⛔ **DECLINED** — crossModule bare/Qual: different key types, different lifecycles, invariant already a type fact via `freshCrossRun` (`:5870-5876`). |
| **B-3-e** | #991/#1114 | ✅ bite (docs) — dead `implOblToU` citation (`DICT-SEMANTICS.md:2491`, `typecheck.mdk:20661`); `D1–D6` → `OD1–OD6` (`TYPECHECK-TARGET-ARCHITECTURE.md:749`). |
| **B-3-f** | #991 | ✅ desk — post the drafted closing comment, close #991. **No implementation.** |
| **A-1** | #1114 | ✅ **CLOSE** (desk). Comment drafted §4. Two repairs ride in B-3-e. |
| **A-2** | #1265 | ⛔ **OUT.** Reading R2 of §9.3. Pin is a DECLARED NON-FLIP; B-2.4 owes the `engines:` statement. |
| **A-3** | #1597 | ⛔ **OUT.** Pin present, well-formed, DECLARED NON-FLIP. Brief's F-3 framing corrected. |

**Unresolved, escalated rather than settled:**
1. **B-3's budgeted size is roughly halved** (#991 + #1114 are both desk items). Whether Phase 1 is
   still worth running as a *separate* calibration phase, or should be folded into Phase 2's opening,
   is the orchestrator's call. My recommendation: **keep it separate** — B-3-b is the one bite in the
   sprint whose mistake is both mechanically visible *and* changes dict arity, which is exactly the
   calibration the phase is for.
2. **A doc-citation sweep is owed as part of B-2.1, not after it** (B-3-e's `nearest miss:`).
   B-2.1 deletes `KeyBuckets`/`keyForSite*` and will strand the same class of citation #991 stranded.
3. **The stale-positions-across-reseed shape** (§B-3-c `nearest miss:`) may be a live defect.
   **Not filed** — unreproduced. Handed to the repair round as a question.
