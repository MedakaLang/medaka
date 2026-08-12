# P0-H — Can A-3.6's evidence plumbing be fixed inside A-3?

**VERDICT: NEEDS-B-2.** Not by judgement call — the epic's own scope table forbids, *by name*,
every one of the three doors into the fix, and the tree has already **measured** the outcome of
the only half-fix that stays inside A-3.

**Held against:** `5efc8525718203286915e9239e51047feffc69b6`, branch `arch/stage-a-sprint`,
worktree `/root/medaka/.claude/worktrees/wiggly-giggling-nygaard`. **Tree was CLEAN**
(`git status --porcelain` empty) at every measurement. Binary `./medaka` mtime 21:43, `MEDAKA_STRICT=1`
on every probe, no staleness warning ever emitted. A concurrent agent was editing `typecheck.mdk`;
all binary-dependent measurements below were taken in one window and the tree was clean throughout.

---

## 1. Reproduction — DERIVED, first-hand

| command | exit | output |
|---|---|---|
| `medaka check main.mdk` | **0** | `main : Unit` |
| `medaka run main.mdk` | 1 | `runtime error [E-PANIC]: putStrLn: not a String` |
| `medaka build main.mdk` | 0 | — |
| `./out_main` | **139** | `E-FATAL-SIGNAL: segmentation fault` |
| `medaka run control.mdk` | 0 | `wrap(int)` |

Matches the orchestrator's measurement exactly. That `main.mdk` was **exit 1 before A-3.6** is
**RELAYED** (orchestrator's single-variable revert + the fixture's own `exit: 1`); I did not
re-run the revert. It is consistent with everything below.

---

## 2. The mechanism — DERIVED from the typed Core IR dump and the emitted LLVM

### 2.1 Core IR (`core_ir_typed_modules_dump_main.mdk`, built to `/var/tmp/p0h/typeddump`)

**main.mdk (broken):**
```
CBind "nest__nest" (CClause ((PVar "x"))
  (CApp (CMethod "tagOf" (RKey "Wrap" ()) () ())
        (CApp (CVar "iface__Wrap" AGlobal) (CVar "x" AGlobal))))
main = (CApp (CDict "core__println" ((RKey "String" ())))
         (CApp (CVar "nest__nest" AGlobal) ...))
```
**control.mdk (correct):**
```
CBind "nest__nest" (CClause ((PVar "$dict_nest__nest_0") (PVar "x"))
  (CApp (CMethod "tagOf" (RKey "Wrap" ()) ((RDict "$dict_nest__nest_0")) ())
        ...))
main = ... (CApp (CDict "nest__nest" ((RKey "Int" ...))) ...)
```

Three evidence defects, all downstream of one fact:

1. **No `$dict_nest__nest_0` binder** — `nest` was generalized WITHOUT the residual `requires Tag a`.
2. **The route's nested-dict list is `()` instead of `((RDict …))`** — the selected instance's own
   `requires Tag a` sub-obligation produced no evidence.
3. **The call site is `CVar "nest__nest"`, not `CDict "nest__nest" ((RKey "Int"))`** — `main` never
   builds or passes the `Tag Int` dict.

🔑 **The route HEAD is `RKey "Wrap"` in BOTH.** Candidacy worked perfectly: typecheck found the
`wrapimpl` instance and committed to it. What did not follow is the *evidence payload*. This is
precisely C4's two conjuncts coming apart — see §4.

### 2.2 Emitted LLVM (`medaka build --keep-ir`) — the same fact, at the ABI

| | call site | definition |
|---|---|---|
| control | `call @mdk_nest__nest(i64 ptrtoint (ptr @mdk_dc_0), i64 %t0)` | `define i64 @mdk_nest__nest(i64 %arg0, i64 %arg1)` |
| **main** | `call @mdk_nest__nest(i64 %t0)` | `define i64 @mdk_nest__nest(i64 %arg0)` |

And inside `nest`, against an impl that is **arity-2 in both files** (`define i64
@mdk_impl_Wrap_tagOf(i64 %arg0, i64 %arg1)`, line 10356 in both):

- control: `call @mdk_impl_Wrap_tagOf(i64 %arg0, i64 %t2)` — dict, then value.
- **main:  `call @mdk_impl_Wrap_tagOf(i64 %t2)`** — an **arity-1 call to an arity-2 function**.
  The `Wrap` heap cell lands in the **dict slot**; the impl body loads a function pointer out of it,
  gets the constructor tag word `21474836480`, and jumps to it. **That is the segfault.**

Corroborating: control emits **two** dict constants (`@mdk_dc_0 = 193460240` for `Tag Int`,
`@mdk_dc_1` for `println`); main emits **one** (println's only). The `Tag Int` evidence value is
not merely misrouted — **it is never constructed at all.**

### 2.3 The discriminating probe — DERIVED, and it isolates the axis

Keep main.mdk's **rejecting import order**, change nothing but add `import wrapimpl` **to
`nest.mdk` itself**:

```
define i64 @mdk_nest__nest(i64 %arg0, i64 %arg1)   -- arity 2, dict param restored
./out  ->  wrap(int), exit 0
```

So the evidence path is **still sensitive to what the goal's own module can reach**, while
candidacy is now graph-global. The two axes are decided by two different tables. This is an
experiment, not a code reading — it is the load-bearing evidence for the whole verdict.

### 2.4 Why — the two-registry split, DERIVED by grep

The evidence path is:

```
residualPredsOf            typecheck.mdk:24544   reads perRun.value.residualUnivRef  (= IE, now GLOBAL)
  -> findMatchingImplReqsU typecheck.mdk:21453-21457
       -> concreteReqMatchByIface  :21471-21472  <-- IGNORES the `univ` argument entirely
            -> selectImplEntryByIface perRun.value.shadowKeyTableRef.value
```

`findMatchingImplReqsU` **takes** an `ImplUniverse` — the environment A-3.6 made global — but for
any non-empty argument vector it never consults it. Our goal is `Tag (Wrap a)`, concrete head
`Wrap`, so it takes the `concreteReqMatchByIface` leg, which reads a **different registry**:

```
typecheck.mdk:20105   Module _ _ _ => setRef perRun.value.shadowKeyTableRef
                                       crossRun.value.universeKeyBucketsRef.value
```

`univ` survives only on the headless fallback (`firstReqMatch (univHeadless univ iface)`), and
`wrapimpl` is concrete-headed, so it is not there. Result: `None` → `residualPredsOf` returns `[]`
→ **"no residual"** → no `requires Tag a`, no dict param, no route dict.

`universeKeyBucketsRef` is a **cumulative accumulator**, appended per module in loader topological
order (`typecheck.mdk:25314`, `bucketKeyEntries … crossRun.value.universeKeyBucketsRef.value`), and
`typecheck.mdk:17732-17741` says so directly, naming this exact chain:

> It does NOT hold for `universeKeyBucketsRef` … `checkBodyImpl`'s Module arm copies it into
> `shadowKeyTableRef`, which `concreteReqMatchByIface` reads → `selectImplEntryByIface` →
> `matchingEntriesByIface` → here.

That is `DICT-SEMANTICS.md` §11's I5 verdict — 🔴 **PARTIAL — cumulative, not global** — still
true, on the *evidence* registry, after A-3.6 flipped the *candidacy* one.

---

## 3. Why the fix cannot land in A-3 — three doors, all closed by the epic itself

**Door 1 — re-key / globalize `universeKeyBucketsRef` in place.** Forbidden verbatim,
`compiler/TYPECHECK-TARGET-ARCHITECTURE.md:1814`:

> \| `universeKeyBucketsRef` / `buildKeyTable` / `keyEntryOf` / `matchingEntries*` / `keyForSite*` /
> `headCollides*` / `implExistsForHead` (`KeyBuckets`) \| route-word registry, head half bare by
> design \| **DEFERRED → B-2, by DELETION. Must not appear in the diff** \|

and #1112's own comment (RELAYED via P0-H's doc sweep, quoted from the issue):

> The natural instinct when building a clean identity-keyed `IE` is to key everything in it by
> identity; **that instinct is wrong for exactly this one table.**

There is also an independent structural reason. That same table is read by `implExistsForHead` in
`inferShadowApp` (`typecheck.mdk:11162`, `:11449`) — the **shadow/name axis**, whose comment at
`:11297` reads *"impl universe is GLOBAL — shadowKeyTableRef spans local ∪ imported ∪ prelude"*.
Globalizing it in place would silently widen **shadow semantics** (a ratified spec, #616) — a
second, unbudgeted acceptance delta of exactly the kind I5's boundary clause forbids and exactly
what RUN-010's split ruling exists to prevent.

**Door 2 — point the evidence reader at `IE` instead.** That is, verbatim, B-2's job
(`TYPECHECK-TARGET-ARCHITECTURE.md:1815`, on the `ImplBuckets` reader `entail`/`routeOf` consumes):

> **DEFERRED → B-2.** §2 K's *"K's IE is the single environment both must read"* consolidation
> stays owed; **`IE` supplies the data, B-2 moves the reader** (its blast list already owns `Route`).

A-3.6 did the first half of that sentence. The second half is the fix, and it is named as B-2's.

**Door 3 — move only the checker's leg (`concreteReqMatchByIface` → `univConcreteBucket`), leaving
the router alone.** This is the tempting small fix, and **the tree has already measured that it
does not work.** `typecheck.mdk:21459-21461` records that the checker and the router share this
selector deliberately (*"the router's `selectReqImpl` / `argImplRequiresRoutes` select the SAME
entry the SAME way"*), so desynchronizing them yields an arity-2 function called with a **null**
element dict. `typecheck.mdk:24514-24526` measured exactly that outcome for #1560:

> the predicate now reaches the scheme and the dict prefix — but … `argReqRoute` resolves it to
> `RNone` — a literal null element dict, **and the binary still faults**. MEASURED …

A different segfault is not a fix. Moving **both** legs is Door 2.

---

## 4. What Stage A can honestly claim about C4/I2

**C4-by-construction does NOT hold, and A-3.6 does not deliver it.** C4 (`DICT-SEMANTICS.md:1312`)
is a **conjunction**:

> Two modules resolving the same predicate must consult the same instance set **and produce the
> same evidence** — otherwise C1/C2 hold only locally and coherence fails across module boundaries.

A-3.6 delivers conjunct 1 and **actively breaks conjunct 2**. §2.1 is a direct measurement of two
modules consulting the same instance set (`RKey "Wrap"` in both) and producing **different
evidence** (`((RDict …))` vs `()`). The clause even predicts the consequence: *"coherence fails
across module boundaries."*

**I2 is now violated in a way it was not before.** I2 (`:1881`): *"Import scoping affects
visibility of names, not the identity of the evidence a predicate resolves to."* §2.3's probe is a
direct counterexample: **adding one `import` line changed the emitted evidence** (arity 1 → arity 2)
and turned a segfault into a correct answer. Before A-3.6 that program was rejected, so import
order could not decide evidence — it decided only acceptance. **A-3.6 moved the order-dependence
from the acceptance channel into the evidence channel, where nothing observes it.**

So the honest Stage A claim is:

> A-3 delivers the **global instance environment** (C4's first conjunct, I5's subject:
> `match(IE, C τ̄)` ranges over the whole graph). It does **not** deliver C4's evidence conjunct or
> I2, because the evidence reader still consults the cumulative `KeyBuckets` registry, whose
> retirement is B-2's (`TYPECHECK-TARGET-ARCHITECTURE.md:1814-1815`). **C4/I2 by construction is
> NOT achieved by Stage A as cut.**

Claiming "C4/I2 by construction" on this tree would repeat the #1354 partial-identity mistake that
RUN-005's own reporting constraint was written to prevent — one conjunct of a two-conjunct clause,
reported as the clause.

---

## 5. Was declining the revert the right call?

**No — on the current evidence, REVERT (or Door 4 below) is the better call.** Directly:

- A-3.6 traded a **loud** defect for a **silent** one. Before: exit 1, a false reject, visible.
  After: **exit 0 from `check`, and a segfault from the built binary.** `AGENTS.md` is explicit
  that loud → silent is a **severity INCREASE**, "even when the old behaviour was also broken" —
  and that it *"will look like progress because the crash went away."* Here the reject went away
  and a real crash appeared.
- The thing bought is **half of one clause**, and §3 shows the other half cannot be bought in A-3.
- The pre-A-3.6 false reject (#1564) is real but is S1/S2 and **pinned**. The post-A-3.6 state is
  **S0 silent wrongness** reachable from a four-module program with no unsafe construct.
- `test/must_fail_fixtures/1564-…` currently asserts `exit: 1` and so should be **failing** now.
  Its `why-architecture` note anticipated draining "when candidacy becomes genuinely graph-global"
  — but candidacy alone is not the drain condition; **evidence is**. That fixture's drain criterion
  should be corrected regardless of the revert decision.

**Door 4, if the owner wants to keep the flip:** make the un-plumbed case **LOUD** rather than
silent. When candidacy admits an instance whose `requires` the evidence path cannot route, emit a
located reject instead of elaborating to nothing. The tree has a direct precedent for exactly this
move: `T-REQUIRES-DEPTH` (issue 1562) converted this same `residualPredsOf` `[]`-return from a
silent drop into a located reject, and its own comment states the principle — *"any finite fuel has
the same cliff; only making the cliff LOUD removes the silent wrongness"* (`typecheck.mdk:24528-24533`).
That is A-3-sized, keeps the candidacy flip, and restores the loud property without pre-empting
B-2. It does **not** make C4/I2 true, so §4's reporting constraint stands either way.

---

## 6. Epistemic ledger

| Claim | Label |
|---|---|
| Repro table §1 (5 commands, exits, outputs) | **DERIVED** first-hand, clean tree @ `5efc8525` |
| Core IR §2.1, LLVM §2.2, probe §2.3 | **DERIVED** first-hand |
| Call chain §2.4 (`:24544` → `:21453` → `:21471` → `:20105` → `:25314`) | **DERIVED** by grep + read |
| `main.mdk` was exit 1 before A-3.6 | **RELAYED** (orchestrator's revert; fixture `exit: 1`) |
| Quotes at `TYPECHECK-TARGET-ARCHITECTURE.md:1814`, `:1815` | **DERIVED** (read directly) |
| `DICT-SEMANTICS.md:1312` C4, `:1881` I2, §11 I5 PARTIAL | **DERIVED** by delegated sweep, each with file:line re-read |
| #1112 / #1113 scope quotes | **RELAYED** from the delegated `gh issue view` sweep |
| Door 3 desynchronization outcome | **DERIVED from the tree's own MEASURED note** (`:24514-24526`, #1560); not re-measured by me (would require an edit; I am read-only) |
| Whether Door 4 is acceptable to the owner | **OWED** — a recommendation, not a ruling |

### Defects found in this territory's prose (report separately)

1. **`DICT-SEMANTICS.md` contains no "§2 K" and no mention of "B-2" at all** (zero grep hits). The
   brief's *"DICT-SEMANTICS.md §2 K reportedly says…"* is **misattributed** — the sentence is at
   `compiler/TYPECHECK-TARGET-ARCHITECTURE.md:321`, and the B-2 deferral is a *separate* statement
   at `:1815`. The substance is right; the file is wrong.
2. **`TYPECHECK-TARGET-ARCHITECTURE.md:1536` cites `typecheck.mdk:2712-2713`** for
   `declEnvVisibleAt`; the real definition is `:2872-2873`.
3. **RUN-005's relayed citations `typecheck.mdk:2835` and `ieSnapAt :4080-4084` are both wrong**
   (`:2872-2873`, `:4290-4294`). RUN-007 asserts these were re-derived first-hand; that assertion
   does not hold for the line numbers.
4. **`DICT-SEMANTICS.md` §11 grades only I5.** The C4 (`:2502`) and I2 (`:2515`) rows carry **no**
   status marker. "§11 grades C4/I2 PARTIAL" would be wrong for both.
5. **RUN-042 and RUN-043 do not exist** — `.claude/sprint/DECISIONS.md` ends at RUN-041. The brief
   instructed me to read them.
6. **#1112's comments still describe A-3.6 as "literally the deletion of that predicate's body"**,
   superseded by RUN-010's SPLIT ruling and by the landed tree.
7. **§11's I5 row is stale against the tree** — it grades the retired
   `appendUniverseAccums`/`foldModules` accumulator, not today's `ieSnapAt`/`ieCandidacyVisibleAt`.
