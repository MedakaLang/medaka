# P0-G — Unit F: the field-owner list re-key

**Agent:** P0-G (Phase 0, read-only architecture pass for RUN-023's "Unit F").
**Tree:** `/root/medaka/.claude/worktrees/wiggly-giggling-nygaard`, branch `arch/stage-a-sprint`,
`HEAD = 176feb50` at derivation time. **Working tree NOT clean** — ` M compiler/types/typecheck.mdk`
(a concurrent implementer). See §0.
**Date:** 2026-08-12.

Every claim is labelled **DERIVED** (I ran the command / read the `file:line` / executed the probe),
**RELAYED** (someone else's, attributed, not re-derived), or **OWED**.

---

## 0. Probe hygiene — read this before trusting any exit code below

**DERIVED, and it bit me mid-session.** My first probes ran `./medaka` **relative**, which the
harness resolves against `/root/medaka` — the *main checkout's* binary, not the trunk's. All
results below were **re-run with the absolute trunk path**
`/root/medaka/.claude/worktrees/wiggly-giggling-nygaard/medaka`.

**`MEDAKA_STRICT=1` began failing partway through the session** with
`exit 1: … built from compiler source that differs from …/compiler — it may be stale`. That is
**not** a defect: `git status --short` shows ` M compiler/types/typecheck.mdk`, i.e. a concurrent
implementer edited the source under the binary. Probes after that point were run **without**
`MEDAKA_STRICT`, and the staleness warning is present on their stderr.

⇒ **Every result below is against the binary built from `176feb50`'s source**, which is the state
Unit F must be designed against. It is not against the in-flight edit. Any bite that lands must
re-derive on a freshly built binary.

---

## 1. Reproductions — first-hand, with positive controls

### 1a. #1383 (S1, legal program rejected) — **REPRODUCES** · DERIVED

`/var/tmp/pf/r1383/` — `ahold.mdk` declares `public export data Holder = | Plain { hx : Int }` and
`mkH = Plain { hx = 100 }`; `plainlib.mdk` declares an unrelated `public export data Plain =
Plain { px : Int }`; `main.mdk` imports both and does `putStrLn (intToString mkH.hx)`.

```
$ …/medaka check /var/tmp/pf/r1383/main.mdk        → exit 1
/var/tmp/pf/r1383/main.mdk:5:29: Type mismatch: Holder vs Plain
/var/tmp/pf/r1383/main.mdk:5:29: Field 'hx' does not belong to record 'Plain'
```

**Positive control** (`/var/tmp/pf/r1383c/`, byte-identical except `plainlib`'s type/ctor renamed
`Otherr`): **exit 0**, `main : Unit`. ✅ Discriminating — the only variable is the spelling
collision.

Hand-derived correct answer: **100**. `mkH : Holder`; `Holder`'s sole variant is the named-field
ctor `Plain { hx }`; `plainlib.Plain` is a different declaration and irrelevant here.

### 1b. #1216 (S0, run ≠ build, silent wrong value at exit 0) — **REPRODUCES** · DERIVED

`/var/tmp/pf/r1216/`, the issue's Repro A verbatim.

| arm | result |
|---|---|
| `medaka run main.mdk` | `ob` / `BBB`, exit 0 — **correct** |
| `medaka build … -o p && ./p` | **`oa`** / `BBB`, exit 0 — **WRONG**, no diagnostic |

**Positive control** (`/var/tmp/pf/r1216c/single.mdk`, both records in ONE file): `run` → `ob`,
built binary → `ob`. ✅ Cross-module only.

### 1c. 🚨 #1216's locus is **NOT** the field-owner list — DERIVED, three probes

This is the single most consequential finding in this pass, and it contradicts RUN-016/RUN-023's
premise that Unit F drains #1216.

1. **Typecheck resolves #1216's access CORRECTLY.** `/var/tmp/pf/d1/` is Repro A with `Rec`'s
   fields re-typed `Int` (so a wrong owner would be a type error) and the access bound as
   `probe : String`. `check` → **exit 0**, `probe : String` — i.e. `resolveFieldRecord` picked
   `Other`. The **same build** still prints `oa`. So the loss is strictly downstream of
   `resolveFieldRecord`.
2. **The emitter uses the OTHER record's index, not a neighbouring slot.** `/var/tmp/pf/d2/`
   moves the colliding `beta` to index **2** of a 3-field `Rec`; the built binary prints the
   **empty string** — slot 2 of a 2-slot `Other`. The index tracks `Rec`, exactly.
3. **It is not "the stamp is always empty".** `/var/tmp/pf/d3/` puts `Rec` FIRST in a single
   file; the built binary is still **correct** (`ob`). And `/var/tmp/pf/m2/` puts both records in
   ONE module while forcing the **Module** driver path (an unrelated `import helper.{unrelated}`)
   — also **correct**. So the stamp works on Flat and on Module; it fails only when the two
   records are declared in **different modules**.

**Mechanism, DERIVED from the source these probes bracket:** `inferFieldAccess`
(`typecheck.mdk:8947-8955`) stamps the resolved **registry key** onto the node
(`setRef r rname`); `lower (EFieldAccess e f r) = CFieldAccess (lower e) f r.value`
(`ir/core_ir_lower.mdk:127`); the emitter converts it with `fieldIdxByName`
(`backend/llvm_emit.mdk:10023-10030`), which on a **miss** in `recFieldsOfName` silently falls
through to `findFieldIdx` — the **label-only, first-record-in-table-order** search. The two key
spaces disagree on the emit path: `registry_keying_ratchet.sh:549-551` states it in the tree —
*"on the emit path its keys are the MANGLED ctor names"* — while `e.recByName`
(`llvm_emit.mdk:1099-1101, 1117`) is seeded from `input.recordFieldOrders` /
`core_ir_lower.declaredRecordFieldOrders`, i.e. the **declaration** names.

⇒ **#1216 is a stamp/emitter key-space mismatch, `ws:emitter` (its own label), and NO reachability
predicate touches it.** The field-owner multimap is *reached* on this path (via
`mangledHeadCandidates:9344-9348`, which reads `fieldOwnersRef` raw) but it supplies the right
answer; what is dropped is the answer's key space.
⚠️ **OWED, not derived:** I did not observe the stamped string itself. The chain above is a
best-supported inference from four probes plus two source sites, not a direct reading. The
decisive instrument is `compiler/entries/core_ir_typed_modules_dump_main.mdk` (see `AGENTS.md`);
I did not build it, per this brief's no-build constraint. **Whoever takes #1216 should run it
first and should not take my chain on faith.**

### 1d. 🚩 A LIVE, UNFILED FALSE REJECT — the real Unit F bug, MEASURED · DERIVED

The brief describes the over-wide candidate set abstractly. Here it is, executing, today:

`/var/tmp/pf/v2/`
```medaka
-- amod.mdk
public export data Zed = Zed { beta : String, gamma : String }
export za : Int
za = 1
-- bmod.mdk          ← imports NOTHING
public export data Bee = Bee { beta : String }
export f r = r.beta
-- main.mdk
import amod.{Zed(..), za}
import bmod.{Bee(..), f}
main = println (f (Bee { beta = "B" }))
```
```
$ …/medaka check /var/tmp/pf/v2/main.mdk           → exit 1
/var/tmp/pf/v2/bmod.mdk:2:13: Ambiguous field access: '.beta' is declared by Bee, Zed; …
```

**`bmod.mdk` does not import `amod`.** `Zed` votes only because `amod` is topologically earlier.

**Two positive controls, both DERIVED clean:**
- `…/medaka check /var/tmp/pf/v2/bmod.mdk` (bmod alone) → **exit 0**, `f : Bee -> String`.
- `/var/tmp/pf/v3/` — identical graph, `Zed`'s field renamed `gg` → **exit 0**.

**And the fix must not over-suppress:** `/var/tmp/pf/v1/` (main itself imports the module
declaring the rival record) correctly **rejects** with `'.beta' is declared by Other, Rec`. Any
predicate must keep v1 red and turn v2 green. That pair is the discriminator.

**This is not filed anywhere.** It is the same class as #1216/#1383 but a *distinct* observable
(false reject on a module that imports nothing). Recommend filing it before the sprint exits, per
the #1136/#1137 idiom RUN-016 already invokes.

---

## 2. The reachability predicate

### 2.1 Definition

For a reader module `m` at ordinal `cur`, a record declaration `d` in module `k` at ordinal `o` is
a **field-owner candidate for `m`** iff

```
  (V1)  o == cur                                              -- m's own row: every record, private included
  (V2)  o <  cur  ∧  publicDataDecl d  ∧  k ∈ depClosure(m)   -- an earlier row: public AND reachable
```

where `depClosure(m)` is the least set containing `usePathModuleId path` for every `DUse _ path _`
in `m.demDecls`, closed under the same operation over those modules' own `DUse` decls, plus the
implicit prelude (ordinal 0, keyed `""`/`"core"` — `buildDeclEnvs:2757-2765` registers both
spellings).

V1 and V2's first two conjuncts are **exactly today's `declEnvVisibleTo cur o pub`**
(`typecheck.mdk:2909-2911`). The whole delta is the third conjunct.

### 2.2 Why that definition and not a stricter one

**Not name-visibility (`import k.{R(..)}`).** A module can *hold* a value of type `R` without ever
naming `R` — it comes back from a dependency's function. On such a binder the owners path is the
only resolution route (arm (a) of `resolveFieldRecord:9042-9051` needs a known head tycon). Drop
`R` and you get either `[]` → `pushUnknownField` → **exit 1 on a legal program** (a *new* false
reject, `resolveFieldByOwners:9358-9362`), or a singleton where two candidates were right → a
**silent accept**. Both are severity increases. So the granularity must be **module** reachability,
not **name** visibility.

**Not "public at every hop".** Requiring each intermediate module to re-export `R` is I2's
*visibility* rule for NAMES (`DICT-SEMANTICS.md:1881`, RELAYED via RUN-005). Type reachability is
transitive through values regardless of re-export. Applying the name rule here drops legitimately
held types — same two failure modes as above.

### 2.3 Why not a looser one

Today's rule is V1 ∨ (V2 minus the closure conjunct) — the **ordinal prefix** — and §1d is its
measured false reject. Looser still (whole graph, the naive A-3.6 reading) is what
`typecheck.mdk:2902-2908` measured and forbids.

### 2.4 Fail direction — **this is the part that is easy to get backwards**

`declEnvSeedChain`'s own note (`typecheck.mdk:3095-3099`) states, DERIVED verbatim: the OWNERS half
fails **CLOSED and loud** — a missing seed is `[]` → `pushUnknownField` → exit 1 — while the KINDS
half fails **silent**. Therefore:

> 🚨 **A `depClosure` lookup that MISSES must fall back to TODAY'S PREFIX, never to `[]` and never
> to "no candidates".** A miss means "I could not compute reachability", and the safe answer to
> that is the status quo (over-wide, loud), not under-wide (which converts a rejection into a
> silent accept, or a legal program into `T-UNKNOWN-FIELD`).

This single rule is what makes the Flat arm safe for free — see §4.

### 2.5 It is not a new invention — the tree already does this one table over

`typecheck.mdk:25356-25363` ("IMPORT-SCOPED per-module seeding") states the identical hazard for
value schemes — *"omInsert is last-write-wins, so a later-loaded dependency's same-named binding …
silently overwrites an earlier one"* — and its fix: *"each module's seed is built from ONLY the
names its own `DUse` decls import."* `importedSchemeOblEntries:25489` and
`addImportedIfaceMethods:25164` are live instances (`usePathModuleId path` is the accessor).
**The field-owner seed is the odd one out**: it is the only per-module seed still built from a
topological prefix rather than from the module's own imports.

---

## 3. Is `deFieldOwnerIdents` fit for purpose? — **NO. Unit F should not read it.** · DERIVED

The brief flags it as widely expected to be Unit F's first reader. It is not fit, for three
reasons, and the third is the one nobody has written down.

1. **Ordinal-free.** `DataTypeDecl` (`typecheck.mdk:3305-3311`) has no `adOrd`/`adPub` peer — its
   sibling `AliasDecl` (`:3325-3333`) does, precisely because *it* got a reader. Confirms the
   ratchet's stated reason.
2. **It unwraps `DAttrib` where `publicDataDecls` does not** (`:3369-3379`; `publicDataDecl` at
   `:25190-25195` has no `DAttrib` arm). Reading it naively gives an attributed record a vote it
   does not have today — an acceptance **NARROWING** that would arrive as a side effect of a
   different change, with no fixture and no ruling. Confirms the ratchet.
3. **NEW, and decisive: it is FLAT.** It is one whole-graph `OrdMap (List (Ident, String))` with
   no per-reader projection. The entire content of Unit F's fix *is* the per-reader projection.
   Adding `(ord, pub, attrib)` to its rows would not be enough — the reader would still have to
   *filter the whole table at every read*, which is the exact shape CI already caught on this
   exact function (`typecheck.mdk:3054`'s measured note: `perf_scaling`'s `modules` shape,
   typecheck TIME 0.299/0.675/1.872s at N=100/200/400, ALLOC arm clean at 2.24/2.42). The
   shipped design is a **chain**, and a flat table cannot be one.

**And Unit F does not need it.** Its two typecheck-side defects are answered elsewhere:
- the reachability false reject (§1d) and #1586 → the **seed chain** (bites F-2, F-3);
- #1383 → `recordCandIsReceiverDecl` (`typecheck.mdk:9325`) + `universeRecordIdentsRef`
  (`:5573`), both already live and already proven on #1382. Worked through on §1a's shape:
  `registerRecordInfoKeyed o cname="Plain" typeName="Holder"` (`:12495-12505`) mints
  `Holder@ahold` as the row's `recordResultMono` head, while `plainlib.Plain`'s is `Plain@plainlib`;
  the receiver's head is `Holder@ahold`. `recordCandIsReceiverDecl` separates them exactly, and its
  `HeadKey` equality is already fail-safe by construction (`:9315-9323`: an unstamped receiver
  matches ZERO candidates, not "the first one").

⇒ **Recommendation to the owner (a decision, not a bite):** `deFieldOwnerIdents` is a built,
doctested, ratchet-allowlisted table that no unit needs. Either give it rows carrying
`(ord, pub, attrib)` when a reader genuinely appears, or **retire it** — the exact
`declEnvsVisible` shape RUN-016 §6b found and P0-C's bite C-0 drained. **Do not let Unit F read
it just because it is unread.**

---

## 4. Flat-arm answer, once, for the whole unit

`buildDeclEnvs` runs only at the two Module-mode driver entries, so `declEnvsRef` is
`emptyDeclEnvs` on every flat path (RELAYED from the ratchet's `declEnvsRef` row; corroborated by
`emptyDeclEnvs:2739-2750` and by RUN-013). On Flat, `fieldOwnersRef` is populated **solely** by
`registerAllData … prog0` over the single program's own decls — one module, so every owner is
own-row and V1 already admits it.

**The architectural consequence, and it constrains every bite:**

> 🚨 **Do the filtering on the PRODUCER side (`buildDeclEnvs` / `declEnvSeedChain`), never on the
> READER side (`resolveFieldByOwners` / `fieldOwnerNames`).** A reader-side filter would need graph
> data that Flat does not have; combined with §2.4 it would have to fall back on every flat read,
> which is at best a no-op with a cost and at worst — if the fallback were written the other way —
> exactly the "three live rejections became silent accepts" severity increase the ratchet's own
> Flat-arm note records for A-3.5c.

Every bite below is producer-side except F-4, which touches no graph state at all.

---

## 5. Bites

Each is *"apply this transformation to these N named sites."* Every site was grepped in this
worktree. Line numbers are from `176feb50` **and will have moved** — anchor on the symbol name.

---

### F-0 — pin the §1d false reject, RED, before anything moves

- **sites (new):** `test/check_module_fixtures/unimported_record_no_field_vote/`
  (`entry.mdk`, `m.mdk`, `b.mdk`, `oracle.tcmod`) — modelled byte-for-byte on the existing
  `test/check_module_fixtures/attributed_record_no_field_vote/` (DERIVED: `ls` shows
  `entry`, `entry.mdk`, `m.mdk`, `oracle.tcmod`).
- **consumers, DERIVED** (`grep -rln check_module_fixtures test/`): `test/diff_compiler_check_modules.sh`,
  `test/diff_compiler_check_cli_modules.sh`, `test/registry_keying_ratchet.sh` (names fixtures in
  prose), `test/snapshots/compiler/typecheck.md`. ⚠️ **This is a shared corpus** — adding a
  directory enrols you in the first two gates. Run both, or record them as owed.
- **transform:** encode `/var/tmp/pf/v2/` (§1d) plus its two controls. The golden captures
  **today's exit 1**, so the fixture is RED-by-construction and F-2 flips it.
- **deps:** none. Lands first.
- **Flat arm:** N/A (fixture only).
- **flips:** nothing yet. It is the probe F-2 must succeed against, authored **before** the fix so
  it cannot be shaped to fit it.
- **could move:** nothing — it is a new fixture. ⚠️ But it **adds a golden the sprint may not
  bless** (§5). It must be listed in `.claude/HANDOFF.md`'s expected-red table on the day it lands.

---

### F-1 — carry the import closure on `DeclEnvs`

- **sites:** `data DeclEnvs` (`typecheck.mdk:2726-2735`) — add
  `deDepClosure : OrdMap (OrdMap Unit)` (module id → the set of module ids it transitively
  imports); `emptyDeclEnvs` (`:2739-2750`) — `deDepClosure = omEmpty`; `buildDeclEnvs`
  (`:2757-2790`) — one new initialiser; a new pure `declEnvDepClosure : List DeclEnvModule ->
  OrdMap (OrdMap Unit)` beside `declEnvOrdIndex` (`:2822`); `test/registry_keying_ratchet.sh`'s
  `declenvs_allowed` block (DeclEnvs 8 → 9 — DERIVED: P0-F §1b enumerates today's 8, and
  `sh test/registry_keying_ratchet.sh` prints the live count).
- **transform:** fold `mods` in ordinal order; for row `m`, `closure(m) = ⋃_{d ∈ directDeps(m)}
  (closure(d) ∪ {d})`, where `directDeps(m) = map usePathModuleId [path | DUse _ path _ ← m.demDecls]`.
  Dependency-first order guarantees every `d` is already computed.
  🚨 **PERF CONSTRAINT, not style:** build it by *inserting into a dep's already-built map*, never
  by re-walking the graph per module. `typecheck.mdk:3054`'s note is the record of what happens
  otherwise. A module with one dep must cost O(its own imports), sharing the dep's map.
- **deps:** none (independent of F-0).
- **Flat arm:** `emptyDeclEnvs` ⇒ `omEmpty` ⇒ every lookup misses ⇒ §2.4's fallback ⇒ today's
  behaviour. **Nothing on the Flat path can observe this bite.**
- **flips:** none — the field is unread until F-2.
- **could move:** **nothing on any judgment** (zero readers), but two real risks: (a) `buildDeclEnvs`
  runs in the driver preamble on every Module compile, so a mis-shaped fold is a whole-compile
  perf regression, graded only by `diff_compiler_perf_scaling`'s `modules` shape, which §5 defers;
  (b) `DeclEnvs` gains a field ⇒ the ratchet's `declenvs_allowed` assertion fails until edited in
  the **same** bite. ⚠️ Also: adding a field to a record whose header is the two-line
  `data X =` / `| X {` form is #829's trigger. `data DeclEnvs = DeclEnvs {` at `:2726` is the
  **safe collapsed** form and it already carries interior comments — keep at least one, per the
  🚨 note at `:2706-2717`.

---

### F-2 — filter the field-owner seed by reachability  ⭐ **the unit's core**

- **sites:** `declEnvSeedChain` (`typecheck.mdk:3054-3064`) — the owner half only (`oacc` /
  `declEnvDeclFieldOwners`, `:3066`); `buildDeclEnvs`'s `let seeds = …` call (`:2765`);
  `deOwnersBefore`'s ratchet row (`registry_keying_ratchet.sh:236`), whose prose asserts the
  retirement is NEUTRAL and that #1216/#1383 "reproduce unchanged" — **that sentence stops being
  true and must be re-cut in this bite** (RUN-010 consequence 1's rule, applied here).
- **transform:** the owner accumulator stops being a single prefix chain and becomes a per-module
  map computed over `deDepClosure`: `owners(m) = ⋃_{k ∈ depClosure(m)} publicOwners(k)`, where
  `publicOwners(k)` is exactly today's `declEnvDeclFieldOwners (declEnvRowVisible (k.demOrd + 1) k)`
  — **unchanged projection**, so the publicity conjunct still routes through `declEnvVisibleTo` and
  nothing open-codes `<=` or a `pub` test (the prohibition `typecheck.mdk` states in four places).
  🚨 **On a `deDepClosure` miss, return today's prefix accumulator** (§2.4). Keep the prefix chain
  alive as that fallback; do not delete it.
  🚨 **The kind half (`kacc`/`km`) is NOT touched.** It fails silent (`:3095-3099`) and is #1069's
  territory. Two accumulators, one function — edit one.
- **deps:** F-1 (needs `deDepClosure`); F-0 (the fixture must exist and be RED first).
- **Flat arm:** miss ⇒ prefix ⇒ today. No flat-path change.
- **flips:** **`test/must_fail_fixtures/1383-variant-ctor-name-collides-xmod-record-type`** — *may*
  flip as a side effect if the rival owner becomes unreachable, but **do not rely on it**: in
  §1a's shape `main` imports *both* modules, so both stay reachable and the pin does **not** flip
  from F-2. #1383 is F-4's. Nothing else flips here.
- **could move:** 🚨 **the largest `could move:` in this sprint.** Every program with an
  unannotated field-selection binder in a module that does not import a same-field-named record's
  module changes answer. Direction is **widening** (fewer candidates ⇒ fewer `T-AMBIGUOUS-FIELD`),
  which is the direction §5 R2 can carry (`typecheck.mdk:2902-2908`), witnessed by F-0's fixture.
  But two second-order moves are **not** widenings and are what the testing round must hunt:
  (i) **ambiguous → singleton** turns a rejection into an *accept that picks an owner* — if the
  dropped candidate was the real one, that is loud→silent, a severity INCREASE; §2.2's argument
  says it cannot happen (an unreachable type cannot be held), and that argument is the thing to
  attack;
  (ii) **singleton → `[]`** ⇒ `T-UNKNOWN-FIELD`, a *new* false reject, if `depClosure` is
  under-computed (a `DUse` form `usePathModuleId` does not cover — `UseAlias`, dotted `UseName`,
  `export import` re-export chains). **Enumerate the `UsePath` arms as a SET**
  (`ast.mdk:990-994`: `UseName`, `UseGroup`, `UseWild`, `UseAlias`) — a missing arm is invisible
  behind any `_ =>`.
  **Witnessing fixtures:** F-0's new cell (green after); `/var/tmp/pf/v1/` shape must stay RED —
  add it as the negative control in the same directory; `check_module_fixtures/private_record_no_field_vote`
  (exists, DERIVED) is a live discriminator for the population side.

---

### F-3 — give the field-owner seed a `DAttrib` arm (drains #1586, S0)

- **sites:** `declEnvDeclFieldOwners` (`typecheck.mdk:3066-3070`) — add a `DAttrib` unwrap-and-recurse
  arm ahead of the `_::rest` catch-all; `registerData`'s catch-all (`registerData env _ = env`,
  DERIVED present via `:3369`'s comment and #1586's body) — the Flat/own-row half;
  `frontend/resolve.mdk`'s `fieldOwnersOf` (#1586's second, resolve-stage site — RELAYED from the
  issue, **not** re-derived by me);
  `test/check_module_fixtures/attributed_record_no_field_vote/oracle.tcmod`.
- **transform:** unwrap `DAttrib` at each site so an attributed record registers its fields.
- **deps:** independent of F-1/F-2 (different arm of the same function — **but the same named
  region as F-2, so serialize the two**, per §4 region discipline).
- **Flat arm:** `registerData`'s arm is the Flat half and is where #1586's single-file repro lives
  (its body's repro is single-file). **This bite MUST touch `registerData`, or it fixes only the
  Module path** — that asymmetry is the trap.
- **flips:** **`test/must_fail_fixtures/1586-attribute-drops-field-owner-registration`** →
  expected RED (a deliverable, per §1's closure policy).
- **could move:** an acceptance **NARROWING** — attributed records start voting, so a program that
  compiles today may become `T-AMBIGUOUS-FIELD`. ⚠️ **This is licensed and pre-declared**, and the
  licence is in the tree, DERIVED verbatim from
  `check_module_fixtures/attributed_record_no_field_vote/entry.mdk`: *"When #1586 lands, this
  fixture is expected to MOVE (`B` starts voting and the program is rightly ambiguous) — that is a
  deliberate behaviour change owned by that issue, not a regression in this one."*
  🚨 It is therefore **NOT** an instance of the unlicensed narrowing RUN-008 forbids: that one is
  licensed only by §5 R2's widening-exception, this one by an S0. **But it moves a value golden**
  (`oracle.tcmod`), and §5 blesses zero goldens ⇒ `diff_compiler_check_modules` /
  `check_cli_modules` go RED for the rest of the run. **Must be in `.claude/HANDOFF.md` before the
  bite lands.**

---

### F-4 — make `pairRecordByName` identity-aware (drains #1383's typecheck half)

- **sites:** `pairRecordByName` (`typecheck.mdk:9373-9374`), reached from `resolveFieldByOwners`'s
  singleton arm (`:9361`) and from `resolveFieldAmbiguous`'s concrete-receiver arm (`:9370`).
  Reuses, unchanged: `recordCandIsReceiverDecl` (`:9325`), `headTyconMono`,
  `universeRecordIdentsRef` (`:5573`), `recordResultMono` (`:9337`).
- **transform:** `pairRecordByName` takes the receiver's `Option HeadKey`. Enumerate
  `omLookup r universeRecordIdentsRef` rows; `filterList (recordCandIsReceiverDecl rk)`; on
  **exactly one** survivor, return it; **on 0 or ≥2, fall through to today's
  `lookupRecordByName r`, unchanged.** Absence makes no claim — the same rule `sameTyConHead` and
  `recordCandIsReceiverDecl`'s own `HeadKey` equality already implement (`:9315-9323`).
- **deps:** none. Independent of F-1/F-2/F-3; a different named region (~9358 vs ~3060).
- **Flat arm:** **fully live on Flat**, and safe there: single-file, `universeRecordIdentsRef` has
  at most one row per key, the filter is a no-op, `lookupRecordByName` answers as today.
- **flips:** **`test/must_fail_fixtures/1383-variant-ctor-name-collides-xmod-record-type`** →
  expected RED. **This is the pin Unit F actually drains.**
- **could move:** by construction only where today's bare `lookupRecordByName` returned a record
  whose head ≠ the receiver's — i.e. only wrong answers. Strictly `None → Some correct`, the same
  monotonicity `lookupRecordByMangledHead`'s note argues for #1382 (`:9276-9284`).
  🚨 **BUT #1383's own body names the trap, and it is real:** *"a fix that changes which
  `RecordInfo` is selected without also making the stamped name distinguishing will convert this S1
  into [#1382's] S0."* F-4 changes the selected `RecordInfo` while `inferFieldAccess` still stamps
  the **bare key** `r`. On the emit path that key is ambiguous — **which is exactly §1c's
  mechanism.** ⇒ **F-4 must be graded against #1216's repros, not only against #1383's**, and if
  #1216's stamp defect is not fixed first, F-4 can convert a loud S1 into a silent S0. That is a
  **loud → silent transition**, the one this repo's ladder counts as a severity increase.
  **Mitigation, and it is an ordering constraint, not a note: F-4 must not land before the stamp
  key-space is either fixed or proven not to reach this shape.** OWED — I did not prove which.

---

### F-5 — **NOT A BITE. #1216 leaves Unit F.**

Per §1c, #1216's defect is `fieldIdxByName`'s silent fall-through to `findFieldIdx` on a key-space
miss (`backend/llvm_emit.mdk:10023-10030`). It is `ws:emitter`, it is not statable as a
transformation over Unit F's sites, and its instrument (`core_ir_typed_modules_dump_main.mdk`) has
not been run. **Escalate to the owner: #1216 should be re-assigned out of Unit F**, and F-4's
ordering constraint above depends on that assignment. Filing it as an emitter node is cheap; the
alternative is Unit F reporting an S0 drained that it did not touch.

---

## 6. The pin-classification contradiction — RESOLVED

**The census (§5b) and RUN-023 do not actually disagree; the census flattened a unit-scoped claim
into a global one.** DERIVED by reading the source of the classification —
`test/registry_keying_ratchet.sh:236`, the `deOwnersBefore` row, verbatim:

> *"the retirement is **NEUTRAL**, same population … and same keys, **so** #1216 (S0) and #1383
> (S1) reproduce unchanged and the type-REACHABILITY predicate that would fix them is owed to a
> later unit"*

That is a **neutrality claim about A-3.2b slice 3** — *"my change did not move these"* — with the
drain explicitly deferred **to a later unit**. It is not a declaration that a flip is a failure.
The census's §5b table dropped the "so" and the "owed to a later unit", turning a scoped statement
into a permanent tripwire.

**Ruling I recommend the owner record:**

| pin | for every unit EXCEPT Unit F | for Unit F |
|---|---|---|
| `1216-xmod-record-field-name-collision` | **NON-FLIP** — a flip is a real failure | **NON-FLIP** (per §1c/F-5: Unit F does not touch it) |
| `1383-variant-ctor-name-collides-xmod-record-type` | **NON-FLIP** | **FLIP EXPECTED** — F-4 drains it; red is a deliverable |
| `1586-attribute-drops-field-owner-registration` | **NON-FLIP** | **FLIP EXPECTED** — F-3 drains it |

**Why getting this wrong is expensive in both directions:** classified non-flip, F-3/F-4's success
reads as a break and gets reverted; classified flip-expected globally, a genuine regression in
someone else's lane reads as designed. The classification is **unit-relative**, and the testing
round must be handed it that way. ⚠️ Note #1216 is non-flip **for a different reason** than the
others — not "nobody is fixing it" but "the unit chartered to fix it does not reach it."

---

## 7. Landing order (against RUN-019)

RUN-019's order: ledger-repair → Lane A (A-3.5a, CE) ∥ Lane B (A-3.5b, IE) → A-3.6 → A-3.7.

**Unit F lands AFTER the ledger-repair commit, CONCURRENTLY with Lanes A and B, and BEFORE A-3.6.**

- **After ledger-repair, forced.** P0-A's D1/D2 sit at `declEnvVisibleAt:2834` and
  `declEnvSeedChain:3054` (RUN-019 step 0's own warning). F-2's site *is* `declEnvSeedChain`. Same
  named region ⇒ §4 region discipline ⇒ serialize.
- **Concurrent with Lanes A/B, safe.** Lane A is CE-side (`universeIfaceRequiredRef`,
  `implCompletenessMsgsOf*`); Lane B is IE-side (`ieRowsVisibleAt`). Unit F is
  `DeclEnvs`/`declEnvSeedChain` (~2726–3070) and `resolveFieldByOwners` (~9358–9375). Disjoint.
  ⚠️ **RUN-019's own caveat applies verbatim** — this is a *claim* of disjointness the
  sub-orchestrator must confirm against actual bite sites before dispatching.
- **Before A-3.6, recommended.** Under RUN-010's split, A-3.6 no longer touches the field-owner
  readers — but it owes a re-cut of ~8 comments including `:2891` and `:2987`, which sit **inside
  Unit F's region** and describe the very predicate F-2 changes. Landing Unit F first means A-3.6's
  re-cut describes the end state once, instead of describing a state that moves under it.
- **Internal order:** F-0 → (F-1 → F-2) ∥ F-4; F-3 after F-2 (same function). **F-4 gated on the
  #1216 assignment (§F-5).**

---

## 8. Feasibility verdict

**SPLIT. Three bites are sprint-safe; the core two are not.**

| bite | verdict |
|---|---|
| **F-0** (pin the false reject) | ✅ **sprint-safe.** Fixture only. |
| **F-4** (`pairRecordByName` identity) | ✅ **sprint-safe** — small, one region, monotone, reuses proven machinery — **conditional** on the #1216 assignment (F-5). Drains the S1. |
| **F-3** (`DAttrib` arm) | ⚠️ **sprint-safe with a caveat.** Small and pre-licensed, but it moves a value golden the sprint may not bless. Land it only if `.claude/HANDOFF.md` is updated in the same commit. Drains the S0 that Unit F *can* drain. |
| **F-1 + F-2** (the reachability predicate) | ❌ **NOT sprint-safe. Recommend carving out into its own gated round.** |

**Why F-1/F-2 must not land under a deferred-verification posture** — three independent reasons,
each of which alone is sufficient:

1. **The characteristic failure is invisible to the entire deferred gate set.** A widened or
   narrowed field-owner candidate set is a *diagnostic-only* change on programs whose values do not
   move. Value goldens cannot see it; absence probes cannot see an undercount. §8 of the sprint doc
   says this in the abstract; Unit F is the instance.
2. **The one gate that CAN see F-2's real risk is `diff_compiler_perf_scaling`, and §5 defers it.**
   This is not speculative: `typecheck.mdk:3054` records that the *first cut of this exact function*
   was O(universe)-per-module and was caught only by that gate's `modules` shape, with the ALLOC
   arm reading clean. F-2 replaces a prefix chain — whose sharing is the entire reason it is fast —
   with a DAG closure. **The sprint would be re-running a measurement it already knows this
   function fails.**
3. **The fix's safety argument is not gate-checkable at all.** §2.2's claim ("a module cannot hold
   a value of an unreachable type") is what stands between F-2 and a loud→silent transition. That
   is an argument about the language, not about a fixture, and it needs adversarial review — the
   gate every soundness fix in this repo gets, which §1 explicitly places *after* this run.

**What the sprint should do instead:** land F-0, F-3, F-4 — which drain #1383 (S1) and #1586 (S0),
i.e. two of the orphan's five, using only machinery already proven in this tree — and hand F-1/F-2
out as a **new ARCH node** with F-0's fixture already RED in the tree, §2's predicate already
derived, and §1d's measured repro attached. That node then costs its implementer a decomposition
they do not have to re-derive, and it gets the gated round its failure mode requires.

⚠️ **This is a partial answer to RUN-023, and saying so plainly matters more than looking
complete.** The owner scoped Unit F in to *drain #1216 and #1383*. On the evidence here, the
sprint can drain **#1383 and #1586**; **#1216 is not Unit F's** (§1c/F-5); **#1468** is a
missing per-constructor totality check on `.field` selection (its own body's fix shape (1)), not a
field-owner-list defect; **#1456** is the `fieldOwnerNames` `sortUniqS`-per-access cost
(`typecheck.mdk:8992`) — a real, in-region S3 that F-2 would naturally absorb and that no other
bite touches. So the orphan cluster splits three ways, and only one third of it is the re-key.

---

## 9. Ledger of what I did NOT establish (OWED)

- The stamped record-name string on the emit path (§1c). Inferred from four probes and two source
  sites; **not observed**. `core_ir_typed_modules_dump_main.mdk` settles it.
- `frontend/resolve.mdk`'s `fieldOwnersOf` (#1586's second site). **RELAYED from the issue only** —
  I did not open that file.
- Whether `usePathModuleId` covers every `UsePath` arm for F-1's closure. Named as a `could move:`;
  not derived.
- Whether F-2's DAG-closure fold preserves the chain's asymptotics on real graphs. **Argued in
  §5/F-1, measured nowhere.** This is reason 2 of the feasibility verdict.
- I did not run any gate, did not build, and blessed nothing.
