# R1 — adversarial review of the landed Stage B work

**Read-only. Nothing was built, run, or blessed.** Every source citation below is against the
pinned commit **`604278bb`** unless the line explicitly says `2b9dc798` (BASE) or `03ef6c47`
(the commit Phase 1 landed as). Sources were read from `git show 604278bb:<path>` copies in
`/var/tmp/r1_*`, never from the working tree (a writer is live in `compiler/types/typecheck.mdk`).

Scope: `03ef6c47` (B-3-a/b/c/e), `523f960e` (B-2.1-a1), `5d499dfb` (B-2.1-a2), and the
`DEBT.md` / `DECISIONS.md` ledgers at `604278bb`.

---

## Findings, most severe first

### F1 — S2 today, **S0-shaped for `B-2.1-b`**: the Flat and Module `ImplEnv`s are keyed DIFFERENTLY, and nothing landed compares their keys

`a2` seats both arms on one ref (`bodyImplEnvRef`, `:20459-20460`) and its `could move:` argues
neutrality. That is right *today*. But the two populations it unifies are **not indexed under the
same keys**, and the ledger's `nearest miss:` names only the *widening* direction.

**Derivation.**
- `buildFlatImplEnv` (`:4175-4179`) indexes through `ieIndexRows` (`:4182-4185`) →
  `ieInsertRowKeys (oblIfaceKeys ir) r env`.
- `oblIfaceKeys` (`:21488-21491`) branches on `ir.irOrigin`:
  `OriginUnresolved => [TkBare NsIface ir.irName]` — **one** key;
  `_ => [oblIfaceKey ir, TkBare NsIface ir.irName]` — **two**, including the identity key.
- `implDeclFact` (`:4232-4239`) sets `irOrigin = implOrigin`, straight off the `DImpl`.
- On the FLAT arm, `implOrigin` is whatever `stampFlatTyOrigins coreProg0 userProg0`
  (`:20223`, in `checkProgramSeededSplit`) left. Its scope is `flatTyOriginScope`
  (`604278bb:compiler/frontend/resolve.mdk:4267-4277`) = **builtins + the prelude's types and
  interfaces only**. `checkProgramSeededSplit`'s own header (`:20198-20206`) states the omission
  is deliberate: *"it deliberately contains NO entry for the user program's own declarations."*
  `fillIfaceOccOrigin` (`resolve.mdk:4092-4096`) fills only a still-unresolved origin.

**Consequence.** A single no-import file that declares its own `interface I` and an `impl I T`
gets `irOrigin = OriginUnresolved` for that impl, so the Flat `ImplEnv` files it under the **bare
key only**. The same declaration reached through the graph drivers (`stampGraphTyOrigins`) carries
a real `OriginModule` and files under **two** keys. Same ref, two keying regimes, selected by
driver arm — with prelude interfaces (`Eq`, `Ord`, …) resolved on *both* arms, so the divergence
is confined to **user-declared interfaces**, which is where `#1564`-shaped bugs live.

**This is the direction the instruments cannot see.**
- `a1`'s own gate header says *"a `B-2.1` change that seats a NARROWER Flat `ImplEnv` — right
  acceptance, wrong selected impl — would pass all 9 rows."* This is a candidate mechanism for
  exactly that.
- `a2`'s equivalence audit could not have caught it either — see **F2**.
- `a2`'s `nearest miss:` names `tys = []` (a *widening* in `IE`'s favour) and an unindexed module
  id. The **narrowing** is unnamed.

**UNVERIFIED (behavioural).** Flat may be *self-consistent*: if the goal side also mints bare-only
for an unresolved occurrence (which `oblIfaceKeys`' own comment says is the design —
*"an identity-less occurrence mints the bare key from `tabKeyOf` already"*), lookups match and
nothing breaks. I could not establish that, and it is a precondition `B-2.1-b` currently inherits
unstated.

**Probe that would settle it** (owed to `B-2.1-b`, not to `a2`): one no-import file declaring its
own interface + two impls of it, versus the same program split into two modules; on the repointed
binary, compare the selected impl via
`compiler/entries/core_ir_typed_modules_dump_main.mdk` (the `$dict` routes), not via exit codes.
Add it as a row to `diff_compiler_flat_vs_onemodule.sh` **before** the repoint, since the gate's
existing 9 rows use only prelude interfaces or accept/reject.

**Recommendation.** Make "Flat and Module agree on `oblIfaceKeys` for a user-declared interface"
an explicit precondition of `B-2.1-b`, with a stated verdict. Either arm may be the correct one;
the defect would be *repointing a reader onto a substrate whose keying depends on the driver*.

---

### F2 — S2: `DECISIONS.md:1366` reaches past its evidence

> *"**index vs rows** — every registry key derived from the rows, bucket contents compared
> element-wise against the rows keying into it. **This is precisely the check for the narrow-env
> gap the flat gate is blind to.**"*

It is not. As described, check 2 compares the Flat `ImplEnv`'s **index against its own rows** —
IE-internal self-consistency. A Flat env that is narrower *than the Module env* is perfectly
self-consistent, so check 2 is structurally incapable of detecting it. The narrow-env gap is a
**cross-arm** property; both audit checks are single-arm.

Check 1 is also bounded in a way the ledger does not state: it compares
`map render (flatMap keyEntryOf fullUniverse)` against `map render ieRows`, and `KeyEntry`
(`:17826`) carries **no `TyConOrigin`** — so no projection through `keyEntryOf` can observe the
F1 divergence. The comparison could only have covered the population, not the keying.

The audit is genuinely good work (positive control, two-sided fail-capability, a controlled sweep
harness, an honestly-reported dead glob). The defect is one sentence claiming a reach it does not
have — and it is the sentence a later agent will cite to skip building the cross-arm probe.

**Fix:** amend 1366 to *"this is the check that the Flat index agrees with the Flat rows; the
cross-arm narrow-env gap is still owed."*

---

### F3 — S3, but a lying comment in compiler source: *"LINEAR BY DESIGN … imports no quadratic into the single-file path"* is false

`typecheck.mdk:4110-4130` (the `buildFlatImplEnv` header), echoed by `DEBT.md`
(*"`buildFlatImplEnv` is linear BY DESIGN"*, *"imports no quadratic into the single-file path"*)
and `DECISIONS.md:1352` (*"no quadratic imported into the single-file path"*) and 1384
(*"118 rows → 235 index keys per Flat compile, **all linear**"*).

**Derivation.** `ieIndexRows` → `ieInsertRowKeys` (`:4295-4298`) → `ieInsertRowAt` (`:4300-4306`)
→ **`mregAppendK`**, which is `vs ++ [v]`
(`604278bb:compiler/types/registry.mdk:703-708`), self-documented there as *"at the same
**O(bucket)** cost per add."* And `ieBuildSnaps` (`:4191-4204`) → `insertUnivImpl` →
`insertUnivImplAt` (`:21493`) reaches the **same** `mregAppendK`. So `buildFlatImplEnv` is
`O(rows + Σ_b b²)`, incurred **twice** (index buckets and universe snapshots), not linear.

What the bite actually avoided is narrower and worth saying precisely: **`ieInsertRow`'s
`env.ieRows ++ [r]`, the global `O(rows²)`** (`:4291-4293`). That avoidance is real and correct.
The per-bucket appends were not avoided — they were imported into a path that previously had
`emptyImplEnv` and did none of this work at all.

**Practical size:** concrete buckets are keyed `(iface, head)`, so most hold one row; the
headless bucket is per-interface. So the true cost is probably near-linear at today's ~118 rows.
That is a *bound*, not the *claim on the page* — and the declined perf A/B (`DECISIONS.md:1383`)
was substituted with the word "linear" rather than a measurement.

**Why it matters beyond accuracy.** This runs unconditionally on **every Flat compile** —
`medaka check` on a single file, **`lsp` diagnostics per keystroke**, `repl`, `doc`, `lint`'s
policy pass, `snapshot`, and the two emit entries (the list is `buildFlatImplEnv`'s own header,
`:4134-4137`) — to populate a table **nothing reads**. That is also the honest answer to the
Priority-2 question for `a2`: *code that has nothing to do with this change gets slower, and
nothing else.*

**Probe:** allocation-graded A/B of `./medaka check <no-import file>` on the `523f960e` binary vs
the `5d499dfb` binary (alloc, not wall-clock — `check` is GC-bound). Also worth a bucket-depth
histogram over the prelude to confirm the `Σ b²` term is as small as I expect.

---

### F4 — S3: B-3-a's callee closure was **incomplete by five**; its conclusion is **CONFIRMED**, and there is **no eighth path**

This closes the gap the orchestrator flagged. Full transitive closure of `ifaceForInferredId`
(`:25503-25512`), derived here:

| callee | site | ref reads |
|---|---|---|
| `ifaceForConstraintId` | `:25560` | `perRun.implObls.items.value` (`:25562`) |
| `ifaceForConstraintIdGo` | `:25564` | — |
| `lookupSchemeIface` | `:25515` | *(arg)* `schemeObligationsRef.value` read at `:25508` |
| `lookupIfaceById` | `:25528` | — |
| `ifaceFromDictApps` | `:25535` | *(arg)* `dictApps.items.value` read at `:25510` |
| `ifaceAtMonoId` | `:25541` | — |
| **`normalize`** | `:6997` | tyvar cells only |
| **`normalizeLink`** | `:7007` | tyvar cells — **and WRITES them** |
| **`tyvarId`** | `:7018` | tyvar cell |
| **`containsI`** | `:6964` | — |
| **`ifaceRefBare` / `ifaceRefNone`** | `:5558` / `:5567` | — |

**Verdict: the row's soundness claim holds.** The closure reads exactly `implObls`,
`schemeObligationsRef` and `dictApps.items` — **no `funConstraintsRef`, no
`funConstraintIfacesRef`, no `funConstraintArgsRef`, no `activeDictVars`, no `promotedRef`** — and
the only ref between the old and new evaluation points is the `funConstraintsRef` `setRef` itself,
which is none of those. Moving `ifaceForInferredId` before the write cannot change its answer.
**No eighth path exists.**

**Two corrections to the row, both non-fatal.**
1. It names **six** callees; the closure has **eleven**. The five unnamed are the bottom block.
2. `normalizeLink` **writes** (`setRef cell (Link r)`), so *"reads neither fn-constraint table"*
   understates the closure — it contains a mutating callee. The mutation is documented as
   representation-only path compression (`:6985-6988`, *"leaves the ROOT IDENTITY untouched — this
   is a representation change only, so no program's inferred type moves"*), so the conclusion
   survives. But a row whose whole argument is "the callee set is inert" should say which callee
   is not.

---

### F5 — S3: B-3-a's `could move:` omits a **second** evaluation-order move, then asserts *"nothing else can move"*

`registerMember` (`:24418-24420`) now reads:

```
let slots = registerMemberSlots m 0 ifaceMonos
setFunConstraintEntry m slots (Some (keptConstraintArgs ifaceMonos argVecs))
```

Medaka is strict, so **`keptConstraintArgs ifaceMonos argVecs` evaluates before all three
writes**. Pre-edit (`03ef6c47`'s parent) it sat inside the **args** `setRef`'s argument, i.e.
*after* the `funConstraintsRef` write. That is a second evaluation-order move, of the same kind
the row makes its headline — and claim **(3)** *"Nothing else can move: no ref changed type, no
payload changed shape…"* is therefore over-broad.

**It is sound.** `keptConstraintArgs` (`:24429-24435`) calls only `normalize`; it reads no
fn-constraint ref, and the sole intervening action was the `funConstraintsRef` write. So the
finding is against the *enumeration*, not the transform.

Byte-equivalence of the rest of the bite I did verify at source: `registerMemberSlots`' rewrite
(`:24443-24456`) walks the same list, same length, same order, same `normalize`-is-a-`TVar`
filter, and `CSlot { csIface = iface }` takes the iface from the same pair the deleted
`keptConstraintIfaces` took it from. Identical values.

---

### F6 — S1-shaped, **PRE-EXISTING**, **UNVERIFIED**: `expandSupersEntry` WIPES an ids entry that has no matching ifaces entry

B-3-a's `nearest miss:` correctly establishes the precondition — *"the ids-only pair in particular
means 'every ids entry has a parallel ifaces entry' is **still false** program-wide"* (`:28310` /
`:28342`, `scopeArities`) — and then concludes only that *"a reader that assumed otherwise is no
safer than yesterday."* **One such reader's miss-behaviour is not benign.**

**Derivation.** `expandSupersEntry` (`:9147-9151`):
```
let ifaces = fromOption [] (lookupAssocS fn ifacesTbl)
let pairs  = expandSupersPairs allDecls (pairSlots ids ifaces)
(fn, map (s => s.csId) pairs)
```
and `pairSlots _ [] = []` (`:5609`), truncating to the shorter list. So an ids entry whose fn has
**no** (or a **shorter**) ifaces entry comes back with **fewer or zero ids** — a drop of dict
slots, i.e. the define/call-side under-application shape B-3-b exists to protect.

**Two candidate reach paths, neither confirmed:**
1. *Ordering* — `scopeArities` writes at `:28386` / `:28419`, in the **final** dict-pass, after
   the last `expandSupersTable` (`:14222`, `:20732`). This pair looks protected by order.
2. *Bare-name duplicates* — the refs are prepend-accumulated and, per `registerMember`'s own
   comment (`:24410`), *"keyed by BARE NAME and accumulate"*, while `lookupAssocS` returns the
   **first** match. Two constrained functions sharing a bare name with different slot counts
   would pair the older ids entry against the newer ifaces list, truncating it.

**UNVERIFIED.** I cannot run anything. Path 2 may be unreachable if `perRun` is reset per module.
**B-3-b did not change this expression**, so it is not a regression of this sprint — it is a
pre-existing hazard sitting directly under the bite that reasons about it.

**Probe:** two modules each defining a constrained `f` at different constraint arity, one with a
`requires` superclass, reached cross-module; dump `core_ir_typed_modules_dump_main` and compare
define-side dict params against call-side dict applications. Grade the **IR**, not the exit code.

---

## Priority 2 — "what happens to code that has nothing to do with this?"

- **B-3-a / B-3-b / B-3-c.** Clean. No new AST constructor (so no wildcard-arm blindness), no new
  keyed global table. A program with no constrained function and no interface never reaches any of
  the three ops: `registerMember _ [] _ = ()` (`:24417`), `registerInferredFor _ [] = ()`
  (`:25469`), `registerMethodConstraints`' `isEmptyL ids` guard (`:23812`), and
  `expandSupersTable` maps over an empty table. The only reachable-for-everyone change is F5's
  evaluation order, which is inert.
- **B-2.1-a1.** No compiled byte (comment only, `+8/-2` verified). Cannot affect unrelated code.
- **B-2.1-a2.** It **does** add a program-global structure, and I checked the collision shape the
  tree's most expensive failure mode takes: `bodyImplEnvRef` is a **whole-env value on `PerRun`**,
  not a table keyed by a scopeless name, so the bare-name-key hazard does not apply — there is no
  key to collide. `PerRun` derives nothing, is constructed only in `freshPerRun` (`:6877`), and is
  never printed or compared, so the added field is not indirectly observable. **The real answer to
  the question is F3: unrelated code gets slower on every Flat compile, and nothing else** — as
  long as F1's keying asymmetry stays unread.

---

## Priority 3 — `nearest miss:` verification

| claim | verdict |
|---|---|
| `a2`: the one known population disagreement is `tys = []` | **TRUE and correctly directed.** `keyEntryOf`'s `[] => []` (`:17908`) drops it; `implDeclFact` (`:4232`) keeps it and `univReceiverTag [] = None` (`:21736`) files it in `ieHeadless`. A widening in `IE`'s favour. |
| `a2`: *"the ONE place the two populations are known to disagree"* | **UNDERSTATED — see F1.** True of the *population*; false of the *keying*. |
| `a1`: *"no value here is a FLAT-arm observation"* | **TRUE, and if anything understated.** `medaka run` reaches `elaborateOne`'s 1-module wrapper (`:14183`), the Module arm; `medaka check` on a no-import file reaches `checkProgramSeededSplit` → `Flat` (`:20190`, `:20233`). The FLAT column is acceptance + diagnostic `code` only. |
| `B-3-b`: the only other `expandSupers*` writers are the two `expandSupersPairs` callers holding a `List CSlot` and writing no table | **TRUE** as stated — but see **F6**, which is a *reader*, not a writer, and is the sharper miss. |
| `B-3-c`: `methodConstraintPositionsRef` has exactly one writer and one reader; absence selects a fallback arm | **TRUE.** Writer is `setMethodConstraintEntry` (`:23829`); reader is `alignedMethodConstraintIds`, whose `positionMatch`-miss arm is BASE `:28614`. |
| `B-3-e`: `implOblToU` has zero definitions and zero call sites | **TRUE.** |

---

## Priority 4 — ledger audit

**Confirmed against the tree (each independently re-derived, not read off the ledger):**

- **`a2` "no reader" — CONFIRMED.** `git grep -n bodyImplEnvRef 604278bb -- compiler` → exactly
  **6** hits: `:6784` (field), `:6880` (initialiser), `:20459` + `:20460` (both `setRef`), and
  `:4143` + `:20453` (comments). Every code site is a write. No read site anywhere in the tree.
- **`a2` `+70 / 0` — CONFIRMED** (`git diff --numstat 523f960e..5d499dfb`). **`a1` `+8 / -2` —
  CONFIRMED.**
- **B-3-b's byte-equivalence argument — CONFIRMED at source.** `expandSupersCross` (`:9140-9144`)
  takes both **unexpanded** tables and maps each independently, so it computes exactly the two
  values the old ordered pair of `setRef`s produced. The transposition genuinely discharges the
  ordering constraint by type.
- **⚠️ Phase 1's LEG A move is NOT additive-only — the orchestrator's characterisation is
  CORRECT, and here is the re-cut bar.** `604278bb:test/selfproc_goldens/legA/types.typecheck.golden`
  line **1040** holds `keptConstraintIfaces : List (IfaceRef, Mono) -> List IfaceRef`
  (to be **deleted**) and line **1427** holds
  `registerMemberSlots : String -> Int -> List Mono -> List Int`
  (to be **re-typed** to `String -> Int -> List (IfaceRef, Mono) -> List CSlot`).
  The correct re-cut diff is **exactly**: 1 deletion, 1 re-type, and 6 additions
  (`setFunConstraintEntry`, `setFunConstraintTables`, `setCrossFunConstraintTables`,
  `setMethodConstraintEntry`, `buildFlatImplEnv`, `ieIndexRows`). **Anything else in that diff is a
  finding.** Note `expandSupersTable`'s scheme is unchanged (`List Decl -> Unit`) — it must not move.
- **RUN-B-022's "7 stampers, tree says five" — independently CONFIRMED.**
  `grep -c 'stampImplTable stampKeyTable'` on `2b9dc798:compiler/types/typecheck.mdk` = **7**
  (BASE `:28683-28691`), and the comment at BASE `:28678-28681` says *"five"* **twice**. The
  citations `:28677` / `:28682` are exact.
- **`ci.yml` wiring is real and shard-coverage-safe.** `diff_compiler_flat_vs_onemodule` matches no
  pre-existing shard glob and was explicitly appended to the `eval` shard pattern, so
  `diff_compiler_ci_shard_coverage.sh` is satisfied.
- **The new gate is dash-clean.** Over `604278bb:test/diff_compiler_flat_vs_onemodule.sh` (361
  lines): no `printf '\x`, no bare `timeout`, no `local`, no `sed -i`, no bashisms.

**Ledger defects found:**

- **S3 — line numbers are per-row against that row's OWN landing commit, and the ledger says so
  nowhere.** B-3-a's read-set citations (`:25486`, `:25431`, `:25433`) and
  `constraintVarArgMonos (:24285)` are **exact against `03ef6c47`**, and resolve to *unrelated but
  plausible* lines at both other commits — at BASE, `:24285` is `keptConstraintArgs`' last clause
  (off by −53) and `:25486` is a bare comment (off by −80); at `604278bb` they are off by +70/+76.
  A reader who checks a citation against `HEAD` or `BASE` gets a confident wrong answer rather than
  a miss. **One sentence per row naming the commit fixes it permanently.**
- **S3 — the `a2` equivalence audit is unreproducible, and its *reach* is unrecorded.** The
  instrument is correctly gone (`ieAudit`/`IEAUDIT` grep clean at `604278bb`, as
  `DECISIONS.md:1317` records). But the ledger records the *projection* only as
  `map render (flatMap keyEntryOf fullUniverse)` vs `map render ieRows` — and since `KeyEntry`
  (`:17826`) carries no `TyConOrigin`, that projection **provably** could not have covered F1.
  The 355-file / 0-finding claim is honest about corpus and silent about reach; F2 is the sentence
  where that silence becomes an overclaim.
- **S3 — F4 and F5 above** are ledger-completeness defects on the same row (`B-3-a`): a closure
  named at 6 of 11, and a *"nothing else can move"* that omits one thing that moved.

---

## Retracted

**I opened, then withdrew, a finding that B-3-a miscited four line numbers.** My first check ran
them against `604278bb` and then `2b9dc798`; both resolved to unrelated lines, which looked like
fabrication. Checking `03ef6c47` — the commit that row actually landed as — showed **all four
exact**. The residual is the unstated numbering base (S3, above), not error. Recording this
because the wrong version of the finding would have impugned a row that is, on this point, right.

---

## What I could NOT do

No build, no gate, no `./medaka`, no bless — by instruction, and because the writer is live. Every
behavioural claim above is a source derivation with an explicit probe attached. **F1 and F6 are the
two that need a probe before anyone acts on them**; F2–F5 are settled from source alone.
