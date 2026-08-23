# Typechecker target architecture — per-bug fit ledger

**Status:** CURRENT — one row per open `verified` `ws:typecheck` S0/S1 bug, plus an
explicitly-marked out-of-family section for rows adjudicated on request, against
[`TYPECHECK-TARGET-ARCHITECTURE.md`](TYPECHECK-TARGET-ARCHITECTURE.md) (the design)
and epic #1122 (the stage table). Derived first-hand from `compiler/**/*.mdk` at
`13b9fafe` (2026-07-30); the issue-1150, #1139 and #1140 rows added 2026-07-31 and
derived at `ec51c28e`; the #1161 and #1162 rows added 2026-07-31 and derived at
`5c3ded21`, with every behavioural claim in them re-run on a binary cold-built from that
commit rather than taken from the issues. Extends §4's traceability matrix from *families* to
*individual bugs*, and states a falsifiable prediction for every DRAINED-BY verdict so
each row is **gradeable the day its stage merges**. The design document is the authority.
Two of this ledger's proposals were adjudicated and are now **adopted into it** (§2 K
match-preserving indices; §2 E arity in the output contract, plus a §2 K correction to a
false W2 claim); every other proposal below is a proposal for the orchestrator, not a
change of record.

**Revision, 2026-07-30 — the synthesis was rewritten after adversarial review.** The
first version classified all gaps as one shape and proposed a sixth design law (L6). The
review falsified both, and I verified each counter-claim against source. **Every per-bug
verdict, mechanism and falsifiable prediction survived unchanged**; only the synthesis,
the #1128 row's diagnosis, and the G-7/G-8 remedies moved. The corrected classification
is three shapes plus one genuine absence; the withdrawn L6 and *why* it failed are kept
below rather than deleted, because the two ways it broke are the more useful record.

**Addendum, 2026-07-31 — three owed rows.** Issue 1150 (OPEN, `verified`, S0
memory-safety, filed after the derivation above) joins family A; **#1139** (CLOSED) and
**#1140** (OPEN, S2, `ws:language`) are adjudicated in a new *out-of-family* section
because they are outside the scope line above and a reader finding nothing here cannot
tell "out of scope" from "nobody looked". **One new gap, G-9.** Nothing else moved: no
existing verdict, mechanism or prediction was touched.

**Second addendum, 2026-07-31 — #1161 and #1162**, both OPEN, `verified`, S0,
`ws:typecheck`, filed after the derivation above and both reproduced first-hand here on a
binary cold-built in this worktree at `5c3ded21`. #1161 joins family B; #1162 opens a
**family J** section (§4's coherence row, previously unpopulated here). **Two new gaps,
G-10 and G-11**, both **Shape 1b** — admitting them is what forced Shape 1 to split into
1a (a complete copy exists: adopt it) and 1b (none exists: build one, contract first),
since the old heading's *"two implementations"* wording was false for three of four
members. Three consequences reach outside their own rows and are stated there rather than
left to a reader: **G-10 must be adjudicated before or with G-8's §2 E arity amendment
(#1137)** — not because #1137 freezes the shattering (a conformant one cannot; DICT §4
`gen-sig` gives one dict param per predicate) but because **#1137's mandated conformance
fixture cannot honestly go green until G-10 lands**; **F-3c (#1155) must not land before
#1161's leg is repaired**, because the arm F-3c makes loud is already reached by that
leg's deformed goals; and **F-3c must key its diagnostic to `pickMostSpecificEntry`'s
`None` arm, not to that function's docstring**, which mis-describes equal heads as a
no-unique-minimum case and would flip them. Nothing else moved.

**Third addendum, 2026-08-05 — the post-#1162 population, adjudicated at TRACKER level.**
Every `verified` S0/S1 filed after the second addendum is mapped in a new section at the
end of this document ("Third addendum" before References), derived at `c0c67f15`. Its
evidence bar is **weaker than the prior addenda and says so per row**: verdicts come from
issue bodies, tracker state, and source greps at that commit — not from repros re-run on a
cold-built binary — and the adjudication of record is the set of 2026-08-05 comments posted
on the issues themselves. Ownership changes: **G-10 now has an issue (#1318)**, G-9's
consumer clause is recorded on #1150 (still live — verified by grep at `c0c67f15`), G-11's
declaration-time half is adopted onto A-3's blast list (#1112 comment), G-1 (#1136) and
G-8 (#1137) have proposed owners, and the G-7 #1020 split is adopted onto #1112. Two new
stage-filling issues: **#1317** (dispatch-key identity re-key) and **#1319**
(constructor-namespace identity). No existing family row, verdict, mechanism or
prediction was touched.

> **The burden of proof here is inverted.** "The plan covers this" is the claim that
> needs a mechanism plus a prediction; "this is a gap" is the cheap answer. A row with
> no stateable mechanism is `NOT ESTABLISHED`, not "probably fine" — retiring a live
> bug into a stage that does not actually reach it is the expensive failure this
> ledger exists to prevent.

---

## Summary

| Bug | Verdict | Stage / owner |
|---|---|---|
| #817 Async method-effect-var ≡ container row | **GAP (ownership)** — explicitly deferred to peer arc #820–#824, whose own coverage rules are open S0s | peer arc; see G-3 |
| #819 impl body pins an impl-HEAD type var | **GAP** — matrix lists it "(adjacent)"; no design element removes it | none; see G-1 |
| #825 deferred callback under a pure stored arrow | **GAP (ownership)** — same as #817 | peer arc; see G-3 |
| #1040 `where`-local method helper at two types | DRAINED-BY **F-1** (#1082) | F |
| #1043 block-`let` local method helper | DRAINED-BY **F-1** (typecheck half) · ENGINE-REALIZATION (emitter half) — with a scoping caveat, G-2 | F |
| #1052 local-dict pin merges two rigid sig vars | DRAINED-BY **F-1** (#1082) | F |
| #1069 `dataParamKindsRef` bare-type-name collision | DRAINED-BY **A-1 → A-2** (#1110/#1111) | A |
| #1070 umbrella: 7 of 15 `universe*` tables collide | DRAINED-BY **A-1 → A-2 → A-3** | A |
| #1092 `methodIfaceParamsRef` bare-method-name collision | DRAINED-BY **A-1 → A-2**, with a key-precision refinement (G-4) | A |
| #1095 result-index occurrence discharges coverage | **GAP (ownership)** — D-3 defers to #823, #823's record defers to soundness-not-an-issue | D-3 / #823; see G-3 |
| #1098 `Ref`/`MutArray`/`HashMap` widening launder | DRAINED-BY **D-2** (#1119) | D |
| #1100 abstract-head row arg never collected | DRAINED-BY **D-3** (unconditional half) | D |
| #1103 `unifyRowN` same-tail prefix discard | DRAINED-BY **D-1** (#1118) | D |
| #1121 contravariant Type parameter widens | DRAINED-BY **D-2** (#1119) | D |
| #1125 eval loses a `requires` dict under overlap | DRAINED-BY **B-1 + B-2** (both required) — and it re-prices B-1's owed #323 scope decision | B |
| #1127 superclass-projected dict picks the general instance | DRAINED-BY **B-1 + B-2** (hypothesis CONFIRMED) — **plus GAP G-5** (`activeDictVars` keying is in neither task's blast list) | B + G-5 |
| #1128 `impl C a` beside a concrete parametric-head impl | **CLOSED by F-3b** (2026-08-01) — the classification below held: it was an L1 fork, not engine-realization. ⚠️ F-3b closed the *completeness* half by registering tyvar heads under `noneHeadTag` and unioning that bucket into both route-path selectors; it did **not** merge the two registries, so **G-6 stays OPEN** as the consolidation A-3 owes. It also did not retire `keyForSite`'s head-tag hedge — that is still B-2 | A-3 + B-2; see G-6 |
| #1150 alias-qualified head defeats the value restriction | DRAINED-BY **A-1** (#1110) — A-2 (#1111) contributes the ratchet, not the fact — **with an owed consumer clause, GAP G-9** | A |
| #1161 the `=>` leg shatters a multi-param predicate into per-tyvar slots | **GAP (L1 fork, Shape 1b; also an L5 non-conformance)** — no stage *repairs* "dict slot becomes a predicate"; three producers, none complete. §2 E's mandated arity fixture would **detect** it, which is why #1137 is blocked by this and not the reverse. **NOT** a member of G-8 (argued in the row) | none; see G-10 |
| #1162 `checkCoherence` sees USER decls only; the key table is prelude ++ user | DRAINED-BY **F-3c** (#1155) for the symptom — belongs on its declared flip list, proved by a strictly-more-specific discriminator printing `42` — **plus GAP G-11** for the declaration-time input set, which A-3 must relocate onto K's `IE` and no task names. Its **equal-head** second symptom is drained by nothing (see the row) | F-3c + G-11 |
| #1139 value restriction folded over the LAST ctor argument only | **CLOSED, and NOT DRAINED-BY any stage** — fixed independently at `825f9b14`; no law and no stage reaches a fold-completeness defect. Recorded so the arc is not credited with it | none; see O-1 |
| #1140 one-line `where` silently drops an interface method | **OUT OF ARC (pipeline stage)** — decided in the lexer/parser, upstream of resolve; verified by `fmt` round-trip. Also outside this ledger's stated scope (S2, `ws:language`/`ws:diagnostics`) | none; see O-2 |

**Exclusion re-audit** (§4's engine-realization list): #1034 ✅ holds · #826 ✅ holds ·
#1101 ✅ holds · #1043-emitter-half ✅ holds · **#1020 ⚠️ partially misclassified** —
see G-7. Separately, #1034/#826/#1101 share an **L1** class defect (arity, G-8) that had
no owner; §2 E's amendment now gives it one.

---

## How the gaps classify — read this before the rows

*(Derive the member set — `grep -n 'G-[0-9]' compiler/TYPECHECK-ARCH-BUG-FIT.md` — rather
than trusting a count in this prose; note G-1 and G-3 are stated inline under Shape 3 and
have no `###` heading of their own, so a heading-only grep under-counts. This heading read
"the eight gaps" until 2026-07-31, when G-9 was added with issue 1150's row — and then
G-10/G-11 the same day with #1161's and #1162's. **The count in this prose has been wrong
twice; the grep has never been.** Note also that the two-digit numbers make a naive
`grep -c 'G-1'` match `G-10`/`G-11` as well as `G-1` — word-bound it.)*

> **⚠️ This section was rewritten after adversarial review (2026-07-30). The first
> version claimed eight gaps were "seven gaps, every one a completeness gap" and
> proposed a sixth law, **L6 — elaboration output is total**, to cover them. The review
> broke L6 and falsified the synthesis; the per-bug verdicts, mechanisms and predictions
> below survived unchanged. What follows is the corrected classification. The L6 proposal
> is **withdrawn** — see "Why L6 was wrong" at the end of this section, which is kept
> because the two ways it failed are the interesting part.

**G-1 … G-8, in three distinct shapes.** They do *not* share one shape, and saying they
did was the first version's central error. (**G-9** was added on 2026-07-31 with issue
1150's row; it belongs to Shape 2 and *widens* it — see the note there. **G-10** and
**G-11** were added the same day with #1161's and #1162's rows; both are Shape 1, and
splitting Shape 1 in two is what admitting them forced — see immediately below.)

### Shape 1 — L1 forks: one judgment, several implementations, at least one incomplete (G-6, G-7, G-10, G-11)

This is **not** a missing law. It is L1's core prohibition — *"Each spec judgment has
exactly one implementation, parameterized where call sites differ, never forked"* —
violated by construction.

⚠️ **The shape splits in two, and the split is not taxonomy — it routes the REMEDY.**
This heading read *"one judgment, **two** implementations, one of them incomplete"* until
2026-07-31, when G-10 (three producers) and G-11 (four collections) were admitted under
it. That wording is now false for three of the four members, and the ledger's own prose
said so without drawing the conclusion:

- **Shape 1a — a complete reference implementation exists in the tree (G-6).** One copy
  already answers the judgment correctly; the incomplete one is on the path that decides
  emitted code. **Remedy: adopt the working copy** — for G-6, `univHeadless`'s union, 1200
  lines from `KeyBuckets` in the same file. Cheap, low-risk, and the correctness argument
  is already written.
- **Shape 1b — NO complete implementation exists anywhere (G-7, G-10, G-11).** Every copy
  is lossy in its own way, so there is nothing to adopt. **Remedy: build one, and decide
  its contract first** — which is why all three carry a design question rather than a
  patch (G-7: per-`(instance, method)` disposition vs a filled table; G-10: what a dict
  slot *is*, with an arity move behind it; G-11: what the instance universe is for
  coherence, with a language-design question behind it).

Reading a 1b gap as 1a is the expensive error: it makes the fix look like a small
adoption when it is a contract decision, which is exactly how G-10 came to be described
in the source as *"deliberately NOT done here"* and then never scheduled.

- **G-6 / #1128 (Shape 1a).** "Which instances match this goal?" has **two**
  implementations in `compiler/types/typecheck.mdk`. The obligation-checking path is
  **complete**: it unions the headless bucket into every lookup — ⚠️ **the line numbers in
  this bullet are pre-`5c3ded21` and are the ones most likely to be followed; re-derive
  them by grep, and see the drift table in #1162's row for why an offset will not do it** —

  ```
  13617: implMatchesU univ iface (a0::rest) = bucketArgsMatch (univConcreteBucket univ iface (headTyconMono a0)) (a0::rest)
  13618:   || bucketArgsMatch (univHeadless univ iface) (a0::rest)
  ```

  with `implMatchesReceiverU` (`:13628-13629`) and `findMatchingImplReqsU`
  (`:13666-13669`) doing the same, and the source stating the reason outright at
  `:13661-13662`: *"Headless impls carry no head tycon and so are absent from
  KeyBuckets — the headless bucket fallback (still over the ImplUniverse) covers
  them."* The **route-stamping** path was not: `keyEntryOf` emitted no entry when
  `headTyconTy` is `None`, so `matchingEntries` never saw a fully-general `impl C a`.
  ⚠️ `matchingEntries`' own completeness argument was **circular** — its bucket was
  exhaustive *because* tyvar-headed entries were dropped at construction — so it must
  not be read as evidence that the two paths agree.

  ✅ **F-3b (2026-08-01) closed the COMPLETENESS half, and only that half.**
  `keyEntryOf` now registers a tyvar head under `noneHeadTag`, `candidateBucket`
  unions that bucket into `matchingEntries` and `matchingEntriesByIface` (a stable
  merge on a declaration index, not a `++`), and `keyForSite`/`keyForSiteByIface`
  return the winner's own head tag instead of `None` so the selection survives to the
  route. The two source excerpts above are stale in one word: the headless entries are
  no longer *absent* from `KeyBuckets`, and the `findMatchingImplReqsU` comment quoted
  here has been corrected in place.
  **G-6 IS STILL OPEN.** The gap it names is the FORK — two registries answering one
  judgment — and there are still two: `ImplUniverse` (obligation checking) and
  `KeyBuckets` (route stamping), now both complete and still independently
  maintained. A-3's job is to make K's `IE` the one environment both read. A second
  implementation that happens to agree is exactly the state this gap describes.
- **G-7 / #1020 (Shape 1b).** "What is this instance's method table?" is answered in four places:
  `fillImplDefaults` (same-module only, `desugar.mdk:851`), `eval.mdk`'s untagged
  `defaultEntry` (`:1888`), LLVM's `emitDefaultDispatchChain`, and wasm's absent peer.
  `lowerDeclImpl` (`core_ir_lower.mdk:1267`) emits one entry per method *defined*, so a
  cross-module default-only impl lowers to zero entries and each engine must invent the
  arm privately. Same shape, no complete reference implementation.
- **G-10 / #1161 (Shape 1b).** "What predicate does this binding's `=>` context state?" is answered
  by **three** producers in `compiler/types/typecheck.mdk`, each with its own loss rule
  and **none** complete: `constraintTyVars` (`:16040-16042`) keeps one entry per *type
  variable* and drops every non-tyvar argument; `constraintArgMono` (`:16460-16463`)
  drops the *whole predicate* if any argument is not a plain tyvar, which is what
  `declaredSchemeOblsFor` (`:16434-16445`) inherits; and `recordSigConstraintObls`
  (`:7584-7593`) — the only genuinely n-ary producer — applies the same all-or-nothing
  drop and is reachable from exactly one caller (`:7559`, the shadow-standalone path).
  The n-ary *representation* exists (`Predicate { iface, args : List Mono }`); every
  producer that feeds the dispatch decision refuses to fill it.
- **G-11 / #1162 (Shape 1b).** "What is the instance universe?" is answered by **four** collections
  with two different scopes: `buildKeyTable implDecls` (`:9586`, `:18794`) and the
  `ImplUniverse`/`ImplBuckets` pair are built over prelude ++ user, while
  `cohCollectImpls` (`:11381-11383`, via `checkCoherence`'s `userDecls` parameter,
  `:10984-10985`) and `cohCollectModuleImpls` (`:11396-11399`) are built over user decls
  only. Note this is a scope disagreement one level *below* G-6's: G-6's two collections
  agree on the universe and disagree on the index; these disagree on the universe itself.

### Shape 2 — keying gaps L2 does not reach, because it constrains the key's TYPE, not its PROVENANCE (G-4, G-5)

L2 reads *"no component keys anything by a bare `String` name"*, and the registry
ratchet is mechanical on that: *"A bare-`String` key fails the check."* Both gaps here
key by something that is not a bare `String` and would pass unchanged:

- **G-4 / #1092** — `(module, name)`, a tuple, still under-determining (two interfaces
  in one module declaring the same method name).
- **G-5 / #1127** — `activeDictVars : Ref (List (Int, String))` (`:3139`), a bare
  **tyvar id**, with no interface component at all.

The defect is that L2 is a constraint on the key's *representation* where it needs to be
a constraint on its *provenance* — every key must be derived from the resolved identity
of the thing being keyed, whatever type that identity is encoded in.

**G-9 (added 2026-07-31 with issue 1150) widens this shape one step further: the
defect there keys NOTHING.** `ctorHeadIsUpper` reads character 0 of a name and decides
whether the head is a data constructor — a spelling re-derivation with no table
anywhere. L2's *headline* ("identity is resolved, never re-derived from spelling") is
exactly on point; its *operative* clause and the ratchet built from it are about keys,
so they do not reach it. See G-9.

### Shape 3 — plan-scope / ownership holes, no law implicated (G-1, G-2, G-3)

Nothing in §1 is violated; a stage simply does not exist, or two stages point at each
other. **#819** (no stage owns instance-head fidelity; family G's "W3 rigid everywhere"
cannot reach it because W3 exempts head vars by construction), **#1043** (F-1's scope
says "local bindings" where the defect is four uncovered inference paths), **#1095 /
#817 / #825** (D-3 defers to #823; #823's record says there is nothing to decide).

Worth naming because the design document itself fell into it once: these three are
placed in a family by **topic**, and then the family's design element does not reach
them. That is the pattern-match-onto-a-plausible-stage failure, committed inside the
matrix.

### The one genuine absence from the output contract (G-8)

**Exactly one** item is a fact the elaboration never carries and therefore has no owner
anywhere: **per-method arity and calling convention** (#1034 / #826 / #1101's class).
`eval.mdk`'s `implMethodValue` (`:1837`) builds a closure from the impl clause's `pats`;
`methodArityOf` (`backend/emit_support.mdk:485`) reads a table `methodIfaceTable`
(`core_ir_lower.mdk:1399`) builds from `methodArgTys` (`:1382-1386`), which walks the
whole arrow spine. §2 E's output contract listed routes, dicts, evidence and
admissibility — not arity.

### Why L6 was wrong (kept, because the failure modes are the finding)

**It was unnecessary.** The claim it rested on — *"none of L1–L5 says anything about
whether the decision's INPUTS are complete"* — is false twice over. L1's own text
(`TYPECHECK-TARGET-ARCHITECTURE.md`, L1) already names **"admissibility predicates"**
among the derived artifacts that must be consumed and never re-derived; and, decisively,
#1128 *is* a fork of one judgment into two implementations, which is L1's core
prohibition verbatim. A new law was proposed for a case an existing law already forbids.

**It was unachievable as stated, and one clause was actively dangerous.**

- *Route/evidence totality cannot hold.* W2 is a **depth-32 fuse**
  (`argImplRequiresRoutesRecD`: `if depth >= 32 then []`), not a static condition, so
  elaboration's route data is deliberately partial at depth ≥32. Making W2 static would
  *reject* programs `main` accepts — a language-visible acceptance **narrowing**, where
  §5 R2 enumerates exactly two exceptions and both are widenings carried by a
  could-not-pass-before fixture.
- *The "complete method table per instance" clause conflicts with two settled rules.*
  §2 S requires **a disjoint word class for synthesized default-method arms, "which
  exist for receiver tags with no impl at all and must not be collapsed into the
  instance namespace"** — an instance-keyed complete table cannot express "no impl at
  all". And DICT §3's **W3** rule checks a default body **at the class head `C ā_C`,
  with `ā_C` held rigid** (*"it is the class-provided impl, at the head `C ā_C` itself
  with `ā_C` also held rigid"*), not at any instance head; filling defaults into
  instances checks it at `C T̄` instead — a different judgment. Not speculative:
  `fillImplDefaults`' own header
  (`desugar.mdk:840-870`) records what doing it at *same-module* scale cost — an `Ord`
  *"unbound dict witness"* and a `Foldable` **SIGSEGV** — both since fixed, both
  re-openable by a whole-graph version.

**The two amendments that replace it, now ADOPTED into the design (§2 K and §2 E):**

1. **Match-preserving indices (§2 K).** IE's candidate set for `C τ̄` is every matching
   instance; an index may narrow a lookup only when it *provably cannot drop a match*.
   Head-tycon bucketing is match-preserving only for instances that have a head tycon,
   so tyvar-headed (`__none__`) instances are unioned into every bucket lookup — exactly
   as `univHeadless` already does. This is the L1 fork closed at the substrate, and it
   does **not** touch method tables or W2.
2. **Arity in the output contract (§2 E),** with a *mandatory* hand-derived conformance
   fixture — see the sequencing warning under G-8.

### ⚠️ Sequencing hazard on amendment 1 (loud-over-quiet) — flagged by the review

`pickMostSpecificEntry` (`:11441-11444`) resolves a non-unique winner by **silently
keeping the head of the list** — declaration order, no diagnostic (`None => Some e`; its
own comment: *"if no such unique entry exists … keep the head of the list"*). DICT §11's
`⊑`/`min⊑` row already flags this and ties it to #614/#311.

Completing the candidate set routes strictly **more** goals into that path. Each change
is individually correct, and the combination is a severity increase: a program that
today reaches no candidate and fails loudly could land on a silent first-match instead.
**A-3/B-2's completeness change must land with, or after, F-3 (#311/#614)'s per-goal
unique-minimum diagnostic**, never before it. This is the "a fix that makes a defect
QUIETER is a severity INCREASE" rule applied to the plan's own ordering.

---

## Family A — identity / bare-name registries

### #1069 — `dataParamKindsRef` bare-type-name collision · **DRAINED-BY A-1 → A-2**

**Mechanism (verified).** `dataParamKindsRef : Ref (List (String, List Kind))`
(`compiler/types/typecheck.mdk:3113`) and its carrier
`universeDataParamKinds : Ref (List (String, List Kind))` (`:2536`) are keyed by the bare
type name; readers are `lookupAssoc n perRun.value.dataParamKindsRef.value` first-match
(`:1240`, `:4135`, `:4289`, `:7977`). The source states the hazard itself at `:17048`:

> `⚠️ dataParamKindsRef is keyed by BARE NAME across the whole import graph, so two
> same-named types in different modules already share a key`

#1070 records that this table is one of the **five** whose per-table re-keying is
*impossible* — the read sites hold only a bare head-tycon `String` recovered from `Mono`,
because `TCon` itself is bare, so there is no module identity available at the lookup.

**Why the plan removes the cause.** L2 lands the fix at the substrate, not at the table:
A-1 (#1110) gives `TyCon`/`TCon` references a resolve-assigned `(originModule, name)`
identity, so the two modules' `Box` are no longer the same `Mono`; A-2 (#1111) then
re-keys the surviving `universe*` tables by that identity and lands the write-once-or-
diagnose registry ratchet, under which a bare-`String` key fails the structural check.
The collapse #1070 describes ("both modules' `Cfg` are the same `Mono`") is precisely
what A-1 undoes.

**Falsifiable prediction.** When **A-1 + A-2** land, #1069's three-file repro
(`apub.mdk` `data Box e a`, `zopapub.mdk` `data Box p q` + `zf`, entry importing only
`zopapub.{zf}`) must change from `check` printing `v : Box Unit Int` (row erased, exit 0)
to `v : Box <Stdout> Int` — byte-identical to the control with `zopapub.mdk` deleted.
A-1 alone is **not** sufficient and must not close this: identity has to reach the
*table key*, which is A-2.

✅ **CONFIRMED, 2026-08-03, by A-2.3** (`universeAliasTable` + `universeDataParamKinds`
re-keyed to `TabKey`). The repro's `check main.mdk` went from `v : Box Unit Int` to
`v : Box <Stdout> Int`, byte-identical to its control, and
`test/diff_compiler_must_fail.sh` drained the row and named the issue. The prediction's
"A-1 alone is not sufficient" half also held: A-1 shipped with every hot reader binding
the acquired origin `o` in the same pattern as the head NAME and using it only to mint
the head, never to key the lookup.

🚨 **THE GUARD PARAGRAPH THAT USED TO SIT HERE WAS FALSE, and it is corrected rather
than deleted because it would have disarmed the pin.** It said the repro is silent *"only
at matching arity"*, because *"every hot reader guards on `listLen kinds == listLen
args`, so a same-name/different-arity clash abstains loudly"*. Measured with a 2×5 matrix
(shadower arity 0/1/2/3 plus a control × the use-site row spelled WRAPPED
`Box (<Stdout> Unit) Int` or BARE `Bx <Stdout> Int`): **arity moved the outcome in
neither direction.** On the guard-PASSING path the winning entry's kinds are all-`KType`,
so `foldAppKinds` erases the row exactly as `appFallback` does. What actually selected
silent-vs-loud was the row's SPELLING at the use site — the wrapped form unwraps to a
real type and keeps inferring silently (#1069), the bare form raises
`T-ROW-KIND-MISMATCH` (#1090, the same table with the opposite symptom). The identical
claim in `compiler/types/typecheck.mdk`'s `registerOpaqueParamKinds` doc-comment was
corrected by the same PR; #1069's issue body carries it too and is left alone.

---

### #1092 — `methodIfaceParamsRef` bare-method-name collision · **DRAINED-BY A-1 → A-2** (with G-4)

**Mechanism (verified).** `methodIfaceParamsRef : Ref (OrdMap (String, List String, Ty,
List (String, List Kind)))` (`:3124`) is keyed by the bare **method** name;
`registerMethodIfaceParamsMethods` (`:15335`) does
`omInsert mname (iface, typarams, mty, scope)` — last-write-wins across the whole loaded
program. The source's own comment at `:15332` concedes it:

> This entry is method-NAME-keyed last-write-wins, an exposure it already had … The
> underlying bare-name interface identity is #1047's territory

`ifaceParamMonos` (`:10115`) and the entailment it feeds read that table by bare method
name, so the interface an obligation is *checked against* is decoupled from the interface
the occurrence *resolved to* — which is why #1092's 24-cell matrix shows the verdict
tracking import order and nothing else.

**Why the plan removes the cause.** R (resolve identity) resolves interface-method
occurrences to a qualified identity (§2 R lists "interfaces, interface methods"
explicitly), and `marker.mdk` already rewrites method `EVar`→`EMethodRef` so there is an
existing seam to carry it. A-2 then keys the method table by that identity, and the
reader consults the identity the *occurrence* carries rather than a name.

**Falsifiable prediction.** When **A-2** lands, #1092's flagship cell
(`same_implA_ba_namedb`: `import ifaceb.{IB, mth}` + `import ifacea.{IA}`, `Blob`
implementing only `IA`) must change from `check` exit 0 / `run` printing `1` to
`check` exit 1 with `No impl of IB for Blob`; and the false-reject mirror
(`same_implA_ab_nameda`) must change from exit 1 to exit 0. **All 24 cells must become
insensitive to the `order` axis** — that, not any single cell, is the gradeable
assertion, because `order` is the axis #1092 proved is the only one that moves the
outcome.

**Refinement owed — see G-4.** `(module, name)` is not a sufficient key here.

---

### #1070 — umbrella, 7 of 15 `universe*` tables · **DRAINED-BY A-1 → A-2 → A-3**

**Mechanism (verified).** The structural root #1070 names is real:
`private_mangle.mdk` renames only functions and constructors, so type / alias /
interface names are never module-qualified on either path, and `publicDataDecls` then
carries public `DData`/`DTypeAlias`/`DInterface` across module boundaries into bare-name
tables. Five of the seven confirmed rows are re-keyable only after identity reaches
`TCon`.

**Why the plan removes the cause.** This is the family the arc was built around — §4
family A maps it to "L2/R qualified identity substrate; K identity-keyed environments;
registry ratchet". A-2's issue (#1111) already states it "**updates #1070's body**":
its priority-1 remedy (reject duplicate public names at the declaration) is
**superseded** by the decided use-site-ambiguity model, per §5's "Kept, explicitly" list.
A-3 (#1112) then replaces the tables themselves with K's environments, and §2's registry
ratchet — covering `CrossRun` fields, `PerRun`/`DriverState`/loose refs, **and the
engine-side frame tables** — is what closes the "owed gate" (row K of the matrix).

**Falsifiable prediction.** When **A-2** lands, each of the seven confirmed rows must have
either (a) a passing fixture derived from the repro in #1070's body, or (b) an explicit
reclassification in this ledger. Specifically: the `universeAliasTable` repro
(`amod.type T = Int` / `zmod.type T = Float` + `zf`; entry imports only `zmod.{zf}`) must
change from `check → v : Float`, `run → 42.0` to `v : Int` / `42`. The umbrella closes
only when **all** rows are drained or reclassified — not when the first one is.

✅ **THE `universeAliasTable` ROW IS CONFIRMED AND DRAINED, 2026-08-03, by A-2.3.** That
repro now reads `v : Int` and prints `42` on all three engines (interpreter, native and
WasmGC, each run first-hand — the row was previously wrong on all three, which is why
`diff_compiler_engines` never saw it). Its fixture was deleted and **#1070 was left
OPEN**, exactly as this paragraph's last sentence requires: the remaining rows are
tracked as #1256 (`universeRecordByName`), #1257 (`ifaceSlotKey`), #1258
(`universeIfaceRequiredRef`) and #1259 (`universeDataEnv`), each with its own
`test/must_fail_fixtures/` pin, draining on units A-2.4 / A-2.6. The umbrella's own row
in `test/MUST-FAIL-NOT-PINNABLE.txt` records why it now carries no fixture of its own.

✅ **THE `ifaceSlotKey` (#1257) AND `universeIfaceRequiredRef` (#1258) ROWS ARE
CONFIRMED AND DRAINED, 2026-08-03, by A-2.4** (`universeIfaceParamKinds` re-keyed to
`RegKey` = interface identity × slot ordinal; `universeIfaceRequiredRef` re-keyed to a
`Registry` over interface identity). Both repros go from `exit 1` to `exit 0` and print
`1`: #1257's `impl Same P` is no longer judged against a same-named GRADED interface's
slot kinds, and #1258's `impl Same ET` is no longer judged against a same-named
interface's required-method list. Verified on `check`, on `run`, and on `build` + the
native binary — noting that `run` and `build` share the front end, so on the ACCEPTANCE
question those are ONE observation, while the printed `1` is a genuine per-engine
observation on each. Both fixtures were deleted and **#1070 remains OPEN**; the
remaining rows are #1256 (`universeRecordByName`) and #1259 (`universeDataEnv`),
draining on unit A-2.6.

🚨 **AND A-2.4 FALSIFIED PART OF ITS OWN BRIEF, which is recorded here because a
future reader would otherwise re-derive it.** #1257's fixture notes (and the A-2.4
brief) attributed the REVERSED-import-order symptom —
`Method 'pmth' is not part of interface 'Same'` — to `universeIfaceRequiredRef`. It does
not come from there. It is `R-METHOD-NOT-IN-INTERFACE`, raised by `checkMethodMember`
in **`compiler/frontend/resolve.mdk`** off `Env.ifaceMethods`, a *resolve-layer* assoc
list keyed by bare interface name and scanned first-match by `ifaceMethodsOf`. It is
unchanged by either table A-2.4 re-keyed (re-run first-hand on the A-2.4 binary), it is
on no A-2 unit's list, and it is now tracked as **#1269** with its own
`test/must_fail_fixtures/1269-ifacemethods-bare-name-collision/` pin. The
interface-name collision therefore has a THIRD table, in a file this arc does not
touch.

⚠️ Two rows to hold to a higher bar: `universeRecordByName` and `universeDataEnv` were
audit-verified but **not** independently re-run by #1070's author, and `universeRecordByName`
is claimed to produce a check-vs-build divergence that no gate has ever observed. Those
two need first-hand reproduction before A-2 can claim them.

---

### issue 1150 — alias-qualified head defeats the value restriction · **DRAINED-BY A-1** (#1110), with an owed consumer clause (G-9)

**This row is family A on L2's *headline*, not on its operative clause.** It is the only
row in this ledger where identity is re-derived from spelling with **no table involved
at all**, which is why it needs G-9 rather than G-4/G-5.

**Mechanism (verified first-hand on a binary built from this branch).** Three facts
compose, and the source now states the composition itself at
`compiler/types/typecheck.mdk:3511-3562`:

1. A module alias **must** be uppercase — `aliasNameFor (TUpper x) = emit x`
   (`compiler/frontend/parser.mdk:2513`) with the `TIdent` arm a hard `failP`
   (`:2514`). The safe spelling is ungrammatical.
2. An alias-qualified value desugars to a **flat** `EVar` carrying the dotted name —
   `EVar a => if contains a aliases then EVar (qualifiedLocal a f) else e`
   (`compiler/frontend/desugar.mdk:1014`), `qualifiedLocal alias n = "\{alias}.\{n}"`
   (`compiler/frontend/ast.mdk:425`).
3. The value restriction's head arms are a first-character test —
   `isCtorAppSpine (EVar name) = name /= "Ref" && ctorHeadIsUpper name` (`:3618`, and
   `EVarId` identically at `:3619`), over `ctorHeadIsUpper` (`:3624-3627`), which reads
   `arrayGetUnsafe 0 cs`.

So `ctorHeadIsUpper "H.new"` reads `'H'` and returns `True`: **every alias-qualified
application in the language is classified as a constructor application.** With
`stdlib/hash_map.mdk:55-56` (`export new : Unit -> HashMap k v` /
`new _ = HashMap (Ref (arrayMake initialCapacity [])) (Ref 0)`), `let m = H.new ()`
generalizes a mutable hash table: `check` exit 0 with zero diagnostics, `run`
`E-NOT-A-FUNCTION`, built binary **SIGSEGV** (exit 139). The one-token discriminator —
`H.new ()` spelled `new ()` with `H.set`/`H.get` unchanged — is correctly rejected with
`Type mismatch: Int -> Int vs Int`. Pinned at
`test/must_fail_fixtures/1150-alias-qualified-head-value-restriction/`.

**Why the plan removes the cause.** The information the predicate is guessing at already
exists one stage earlier and is thrown away. `resolve.mdk` maintains a **constructor
namespace distinct from the value namespace** — `ctorNames` (`:1294-1299`) folded into
`ctorsM` (`:1420`, `:2442`), with cross-module constructor ambiguity already a first-class
diagnostic (`isCtorAmbiguous:653`, `AmbiguousConstructor`, `ppResError:1914`). What
reaches `isCtorAppSpine` is a bare `EVar name`, or an `EVarId name id` whose `id` is a
**binding** id stamped by `stampExpr` (`resolve.mdk:2940-2943`) for obligation keying —
not a namespace tag. A-1 (#1110) is precisely "resolve-acquired qualified identity …
AST carries origin"; once the occurrence carries what it resolved to, the two head arms
read that instead of `ctorHeadIsUpper name`, and **both** known holes close by
construction:

- the alias case, because `H.new` resolved to a *value exported by `hash_map`*; and
- the collision case that defeated the obvious patch, because an unrelated module's
  `data Tagged a = Ref a` is a constructor **this occurrence did not resolve to**.

**A-2's contribution is negative, and worth stating as such.** The registry ratchet does
not supply the fact; it is what makes the known-bad remedy structurally unwritable.
`isSome (lookupCtor env name)` (`lookupCtor:4398-4399`, reading `TcEnv`'s bare-name ctor
`OrdMap`) was tried on `wip/1150-lookupctor-attempt` (commit `8d0fb475`, never merged)
and produces a **strictly worse S0** — `data Tagged a = Ref a` anywhere in the graph
makes `Ref []` generalize into a polymorphic mutable cell, reachable by a victim module
that never has the colliding constructor in scope. That is the same bare-name/graph-wide
class the must-fail corpus already pins several times over — derive the set with
`ls test/must_fail_fixtures/ | grep -i 'bare-name\|collision'` — and it would have been
the first where the consequence is memory unsafety rather than a bad diagnostic.
**Membership is not resolution**, and the ratchet is the mechanism that says so.

**GAP G-9 — the owed consumer clause.** A-1's stated collision surface (§6 A-1:
*"parser, `resolve.mdk`, `ast.mdk`, printer/fmt, sexp, every golden family"*) does not
name `typecheck.mdk`'s value restriction as a **consumer** of resolved identity, and L2's
operative clause — *"no component keys anything by a bare `String` name"* — plus the
ratchet derived from it are both about **keys**. `ctorHeadIsUpper` keys nothing. So A-1
can land the identity substrate whole and this defect survive untouched. This is the
#1128/G-6 shape (substrate lands, the incomplete consumer is not named, the bug is
unaffected), which is why the verdict is **conditional**.

**Falsifiable prediction.** When **A-1** lands *with the G-9 clause*,
`test/must_fail_fixtures/1150-alias-qualified-head-value-restriction/main.mdk` must go
from `check` exit 0 printing exactly

```
putI : HashMap String Int -> Unit
getF : HashMap String (Int -> Int) -> Option (Int -> Int)
main : Unit
```

to `check` exit 1 with `Type mismatch: Int -> Int vs Int` at `match getF m` — the same
diagnostic that fixture's `discriminator.mdk` produces **today** — while its
`control.mdk` stays exit 0. Two further conditions, and the row is not drained without
them: the `wip/1150-lookupctor-attempt` counter-repro (`data Tagged a = Ref a` +
`r = Ref []` + a victim module that imports neither) must **also** be rejected — that is
what distinguishes a resolved-identity fix from the bare-name lookup that re-introduces
it one dimension over; and `docs/spec/DICT-SEMANTICS.md` §4.1 **G2** must be rewritten
rather than flipped green, since G3 may not be cited as discharged while any hole in the
predicate stands. **A-2 is NOT required for the repro to flip; A-1 alone with the clause
is sufficient.** **Without the clause, the prediction is that the repro is unaffected by
the entire arc.**

⚠️ **Narrow-repair hazard, stated by the source and worth holding the plan to**
(`typecheck.mdk:3528-3540`). Closing this by rejecting a dotted name in the head test
satisfies every sentence of the mechanism above and leaves the predicate spelling-based.
The grammar still admits the other hazard — `externNameFor (TUpper x) = emit x`
(`compiler/frontend/parser.mdk:2312`) accepts an uppercase extern **name**, where
`identNameFor` (`:251-253`, same file) accepts only `TIdent` for an ordinary
identifier — so an uppercase
mutable-cell extern becomes the sole remaining way to defeat the test the moment the
alias route is closed narrowly. A narrow repair therefore **drains this row without
satisfying the prediction's second condition**, and must not be read as A-1 having
landed.

---

## Family B — dispatch key under-discriminates

### #1127 — superclass-projected dict selects the general instance · **DRAINED-BY B-1 + B-2** · **plus GAP G-5**

**The hypothesis handed to me was that this is a direct B-1 hit. It is — and the
mechanism is sharper than "supers are flattened".**

**Mechanism (verified, three legs).**

1. **The flatten's stated premise is false under overlap.** `expandSupersTable`
   (`compiler/types/typecheck.mdk:5037`) appends one dict slot per transitive
   superinterface, and its own header (`:5027-5029`) justifies not projecting:

   > Because the dict VALUE is just a type tag (VDict "Widget"), the super slot's route
   > is identical to the sub slot's — no separate projection is needed; the slot just
   > has to EXIST so the call site applies a matching dict and the def binds a matching
   > param.

   That holds only when the sub-goal and the super-goal resolve to instances with the
   same tag. In #1127 the sub goal is `C (List Int)` (one impl) and the super goal is
   `D (List Int)` (**two** impls, `D (List a)` and `D (List Int)`, sharing head `List`).
   Identical routes are then wrong by construction.

2. **The `assum` rung cannot tell the two slots apart.**
   `activeDictVars : Ref (List (Int, String))` (`:3139`) is keyed by **tyvar id alone**;
   `activeDictVarOf` (`:10243`) is `lookupAssocI (tyvarId cell) …` first-match and
   `firstDictForEncl` (`:10268`) adds only a `$dict_<encl>_` name-prefix filter. Because
   `expandSupersFix` gives the appended super slot **the same tyvar id** as its sub slot
   (`:5025-5026`: "`Sub a`/`Sup a` share `a`, so the super id == the sub id"), the body's
   `dm x` goal on `a` resolves to whichever slot is found first — with no interface
   component anywhere in the key.

3. **Both engines then re-derive the instance from a bare head tag, differently.**
   `emitDispatchArm` (`llvm_emit.mdk:5304`) matches `headTag` against
   `implEntryRouteWords` in declaration order; eval scores candidates by
   `tyvarsInArgs typeArgs` (`eval.mdk:1881`) and so happens to prefer `D (List Int)`.
   That is L1's "consume, never re-derive" violated on both sides — which is why one
   engine is right and one is wrong on a program whose front end is shared.

**Why the plan removes the cause.** B-1 (#993) replaces the flatten with a distinguished
`supers` component and a real `entailSuper` **projection** rung, so leg 1 and leg 2 both
disappear: there is no appended sibling slot to mis-address. B-2 (#1113) makes routes
carry evidence references (`InstId` | `DictParam k` | `SupersPath`) stamped wherever
`inst` runs, and retires `implEntryRouteWords`' superset-OR arm, so leg 3 disappears:
engines project and apply, never select.

**Falsifiable prediction.** When **B-1 and B-2 have both landed**, #1127's repro must
print `77` from the built binary (today: `20`), matching `medaka run`, and the
one-token control (`useD : D a =>` instead of `C a =>`) must stay `77`/`77`. The fixture
`test/dict_fixtures/s6-1-4-*` goes red the day it is fixed, naming this issue.
**B-1 alone must NOT close this** — if #1127 is claimed drained after B-1 without B-2,
re-run the repro before believing it: leg 3 is independently sufficient to keep it wrong.

**GAP G-5 rides on this row — see below.**

---

### #1125 — eval loses a `requires`-bearing winner's dict under overlap · **DRAINED-BY B-1 + B-2**

**Mechanism (derived from the issue's own matrix + grep, not assumed).** #1125's
three-cell matrix is the discriminator: eval fails **only** when an overlapping sibling
exists *and* the `min⊑` winner carries a `requires`. Drop either and eval is correct.
Exactly one mechanism in the pipeline toggles on "does an overlapping sibling exist",
and it changes the **route payload**: `keyForSite` (`:11386`)

```
keyForSite table name goals = match matchedEntry table name goals
  Some (KeyEntry _ tag _ key _ _ _) => if headCollides table name tag then Some key else None
```

with the registry's own header (`:11331-11337`) stating the design:

> The route normally keeps the bare head tycon … it is UPGRADED to the full canonical
> key ONLY when two impls share that head tycon for the method

So the route for `Speak (Box (List a)) requires Tag a` is a **bare tag `Box`** when the
general sibling is absent and a **canonical key `Speak|(Box (List a))|`** when it is
present. The route representation is bimodal, gated on head collision, and the eval arm
loses the recursively-discharged `Tag Int` dict in exactly one of the two modes.

**Why the plan removes the cause.** B-2 deletes the bimodality outright: *every* goal
that reaches `inst` stamps an evidence reference (`InstId`), unconditionally — there is
no "keep the bare tag when there is no collision" branch left to be the second mode.
B-1 supplies the other half: instance context captured at construction in the evidence
tree, so the winner's `requires` travels with the evidence rather than being re-attached
per engine.

**Falsifiable prediction.** When **B-1 + B-2** land, #1125's repro must print
`specific:INT` under `medaka run` (today: `runtime error [E-PANIC]: putStrLn: not a
String`), matching the native arm, and all three matrix rows must read
`eval == native`. **If it still panics after both stages**, the residual is
engine-realization in eval's `dictOfRoute`/`narrowMethod` and must be re-filed as such
rather than kept on this row.

**Input the plan does not yet have.** §6 B-1 leaves a scope decision owed — *"whether the
tree extends to recursive instance-context capture at nesting depth ≥2 (what #323 needs)
or stays supers-scoped as filed"* — and §4 marks #323 `◇B-1-scope` on the strength of
#323 being an "exotic corner, no realistic shipping surface". **#1125 re-prices that
decision.** Its repro is single-level nesting with 2-way overlap: `impl C (Box a)` plus
`impl C (Box (List a)) requires D a` is idiomatic. If B-1's design doc decides
"supers-scoped as filed" on the grounds that instance-context capture only matters at
depth ≥2, it will be deciding against evidence that arrived after the plan was written.
⚠️ #1125's own body is explicit that its identity with #323 is a **hypothesis, not a
verified claim** — so the input is "an idiomatic shape needs recursive context capture",
not "#1125 and #323 are one bug".

---

### #1128 — fully-general `impl C a` beside a concrete parametric-head impl · **CLOSED by F-3b** (G-6 still open)

✅ **Fixed 2026-08-01 (F-3b).** Everything below is the diagnosis, and it held: the
defect was candidate collection on the route path, not engine realization. What the
fix actually needed, beyond the text of this row, was a **third** part — the route.
Registering the tyvar head and unioning its bucket makes the general impl
*selectable* and leaves it *unroutable*, because `keyForSite` upgraded the route key
only on a head-tag collision and a headless winner sits alone in its bucket; it
answered `None` and `entailInst`'s `fromOption tag (…)` fell back to the goal's head
tycon. Two independent agents built registration+union and both probes were inert.
**G-6 remains OPEN**: the two registries are still two, and consolidating them onto
K's `IE` is A-3's.

**The hypothesis handed to me was that this may be engine-realization. It is not.
Disproved below.**

**Mechanism (verified — and it is upstream of the mangled symbol).** #1128 reads the
mangled symbol off the emitted IR (`@mdk_impl_Box_tag` called at all three sites, the
general impl emitted as `@mdk_impl___none___tag` and never called) and concludes the
decision is at elaboration. That is right, but the cause is one step earlier still:

- `keyEntryOf` (`:11362`) emits a `KeyEntry` **only** when `headTyconTy headTy` is
  `Some`; `headTyconTy` (`:11632`) has arms for `TyCon` / `TyApp` / `TyTuple` and falls
  to `headTyconTy _ = None` for a `TyVar`. `implEntryFromTys` (`:11318`) and
  `implHeadTagForIface` (`:12071`) gate identically.
- Therefore `impl Tag a` produces no entry in `KeyBuckets`, none in `ImplBuckets`, and
  no head tag in `implHeadTagsForIface`. `matchingEntries` (`:11427`) then scans only
  the bucket at `goalHeadCon goals` = `Box`, `keyForSite` returns `None`, and the caller
  keeps the fallback `tag`: `let routeKey = fromOption tag (keyForSite keyTable name
  paramMonos)` (`:11950`, `:11981`). The route is `RKey "Box"` — the *receiver's* head
  tycon, which happens to name the concrete impl's symbol.
- ⚠️ **Correction (adversarial review, 2026-07-30): this row previously said the general
  impl is "invisible to EVERY selector the typechecker has". That is false, and the
  correction changes the diagnosis.** The **obligation-checking** path sees it perfectly
  well, by unioning a headless bucket into every lookup:

  ```
  13617: implMatchesU univ iface (a0::rest) = bucketArgsMatch (univConcreteBucket univ iface (headTyconMono a0)) (a0::rest)
  13618:   || bucketArgsMatch (univHeadless univ iface) (a0::rest)
  ```

  — likewise `implMatchesReceiverU` (`:13628-13629`) and `findMatchingImplReqsU`
  (`:13666-13669`), with `univHeadless` at `:13707`. The source even states the gap it
  is compensating for, at `:13661-13662`: *"Headless impls carry no head tycon and so
  are absent from KeyBuckets — the headless bucket fallback (still over the
  ImplUniverse) covers them."*

  So this is **not a missing law — it is an L1 fork**: one judgment ("which instances
  match this goal?"), two implementations in one file, one complete (`ImplUniverse`) and
  one not (`KeyBuckets`), with the incomplete one on the path that decides emitted code.
  ⚠️ Note `matchingEntries`' own completeness argument (`:11421-11423`) is **circular** —
  the bucket is exhaustive *because* `keyEntryOf` dropped tyvar-headed entries at
  construction — so it is not evidence that the two paths agree.
- Downstream, `headTycon (TyApp a _) = headTycon a` (`eval.mdk:488`) drops the type
  arguments, so `Box Int` and `Box String` are the same tag. That is the *rendering*
  step #1128 observed, but it is faithfully rendering a route the typechecker chose.

**Why this is not engine-realization.** An engine-realization defect is one no stage can
drain because the information is unrecoverable (as with #1034's `methodArgTys`
over-count, where `a -> (Unit -> Unit)` and `a -> Unit -> Unit` are the same `Ty`). Here
the information is present and discarded: the goal is `Tag (Box String)`, the instance
`Tag a` is declared in the same file, and `min⊑` over `{Tag a}` is a one-line
computation. Nothing is lost; a candidate is simply never collected.

**Why B-2 covers only half.** B-2 (#1113) fixes the route-representation half: routes
carry `InstId` rather than a head tag, so once the right instance is selected it cannot
be re-derived away. But B-2's own text presupposes the selector sees the instance — *"every
goal that reaches `inst` goes through the one `min⊑` selector"*. **Nothing in §2 K, §2 S,
or §6 A-3/B-2 states that the candidate set must contain instances whose head has no head
tycon.** §2 K describes IE's *content* ("every impl with its full head, context, and
method table") but not its *indexing*, and §8's perf risk pushes hard toward keeping
head-tycon bucketing (the hot maps are `Map String`, the +56% lesson). If A-3
re-implements IE as "the same buckets, identity-keyed" — the natural reading — **#1128
survives Stage A and Stage B untouched**, because `impl Tag a` still has no bucket.

**Plan change — ADOPTED into §2 K (2026-07-30).** Stated as *match-preservation* rather
than as a new law, since L1 already forbids the fork:

> IE's candidate set for a goal `C τ̄` is every instance of `C` that matches `τ̄`. An
> index over IE is admissible only if it is **match-preserving**: every instance it
> excludes from a lookup provably cannot match that goal. Head-tycon bucketing is
> match-preserving only for instances that *have* a head tycon, so tyvar-headed
> (`__none__`) instances must be unioned into every bucket lookup — exactly as
> `univHeadless` already does on the obligation-checking path.

This is small and measurable (one list union per goal, over a bucket that is empty in
every program in the tree today), it needs no new machinery (the reference
implementation is `implMatchesU`), and it is a precondition for B-2's frozen arg-tag
admissibility to mean anything: *"every constructor reachable at that position must map
to exactly one `min⊑` winner"* is computed against the same candidate set, so an
incomplete set yields a *confidently wrong* admissibility verdict frozen into the
elaboration output and consumed by every engine — strictly worse than today.

⚠️ **Sequencing (loud-over-quiet).** Completing the candidate set routes strictly more
goals into `pickMostSpecificEntry` (`:11441-11444`), which resolves a non-unique winner
by **silently keeping the head of the list**. This change must land **with, or after**,
F-3 (#311/#614)'s per-goal unique-minimum diagnostic — never before it. Also recorded in
§2 K.

**Falsifiable prediction (conditional on the change above being adopted).** With A-3's IE
carrying a general bucket **and** B-2's `InstId` routes, #1128's repro must print
`99` / `10` / `10` on both engines (today: `99` / `99` / `99`), and the one-token control
(`impl Tag (Box a)`) must stay `99` / `10` / `10`. **Without the change, the prediction is
that the repro is unaffected by the entire arc** — that is the gradeable claim, and it is
the reason this row is filed as GAP rather than DRAINED-BY.

---

### #1161 — the `=>` leg shatters a multi-param predicate into per-tyvar slots · **GAP (G-10)**

**The framing handed to me was that the goal vector "does not exist to be threaded". That
is right, and the reason is one step earlier than the comment it cites: the vector is not
lost at the call site, it is destroyed at SIGNATURE REGISTRATION, before any call exists.**

**Mechanism (verified line-for-line, and reproduced on a binary cold-built in this
worktree at `5c3ded21`).** Four legs.

1. **The predicate's non-tyvar arguments are dropped when the signature is read.**
   `sigConstraints` → `constraintTyVars (Constraint iface tys) = map (n => (iface, n))
   (tyVarArgNames tys)` (`:16040-16042`), over `tyVarArgNames ((TyVar n)::rest) = n ::
   tyVarArgNames rest` / `tyVarArgNames (_::rest) = tyVarArgNames rest` (`:16044-16047`).
   Its own header says so at `:16034-16035`: *"each constraint argument that is a single
   type variable; multi-param/structured args skipped"*. So `Ix a Char` registers the
   single pair `("Ix", "a")` and `Char` is gone before `registerMember` (`:16085-16091`)
   writes `funConstraintsRef : Ref (List (String, List Int))` (`:3209`).
2. **The route is therefore selected on a singleton.** `inferDictAtFound` (`:5067`) reads
   those ids, maps them through the call's subst (`constraintMonosOf`, `:5093`), and
   pushes `(routesRef, monos, ifaces)`; `resolveDictApps` (`:12013-12014`) hands them to
   `routesOfMonosTop` (`:12214-12221`), which is `Mono -> Route` **per slot** — it calls
   `routeOf` (`:12180-12182`) → `routeOfD` (`:12190-12197`) → `entail … (EKNestedTop
   keyTable iface policy depth)` → `entailInst`'s `EKNestedTop` arm (`:12136-12145`),
   whose goal is literally `[m]`. That arm's own comment (`:12137-12140`) states the
   design and names the owner: *"a nested/top `requires` goal arrives as a single subject
   mono, so the goal vector is the singleton … Threading the full predicate vector down
   this leg needs the n-ary obligation representation and is #607's scope, not this
   fix's."*
3. **A singleton goal is over-matched, and the tie is broken by declaration order.**
   `keyForSiteByIface` (`:11783`) → `selectImplEntryByIface` (`:11759-11761`) →
   `matchingEntriesByIfaceGo` (`:11772-11776`) → `entryHeadMatches` (`:11943-11948`),
   whose `| otherwise` arm matches **arg 0 alone** when the goal length differs from the
   impl's head length. `Ix Int Bool` and `Ix Int Char` therefore both match the goal
   `[Int]`; `entryCovers` compares the **full** `itys` vectors
   (`:11640-11642` — `tyHeadEqV candTys otherTys || tyStrictlyMoreSpecificV candTys
   otherTys`; the `#609` note above it at `:11634-11639` records that arg-0-only
   comparison is exactly what made these two ⊑-equal) and finds them incomparable;
   `pickMostSpecificEntry` (`:11616-11620`) falls to `None => Some e`
   — the head of the list. This is #1154's terminal mechanism, reached from a second
   producer.
4. **The obligation check cannot catch it either, because a 1-ary predicate is checked
   receiver-only.** `recordCallObligations` (`:5121-5134`) records `Predicate { iface,
   args = [mono] }`; `implMatchesArgsU univ iface [a] = implMatchesReceiverU univ iface a`
   (`:14069-14071`), and `bucketRecvMatch` (`:13845-13851`) matches only the impl head
   vector's **first** element. So the obligation `Ix Int` is discharged by `impl Ix Int
   Char` — which is symptom 2 exactly: a constraint nothing satisfies is accepted.

⚠️ **One claim in the source is FALSE and the row must not inherit it.**
`recordCallObligations`' comment (`:5131-5132`) says *"The joint obligation for such a
predicate is supplied by the declared-context path (`declaredSchemeOblsFor`); this path
stays as-is."* It is not. `declaredOblOne` (`:16440-16445`) routes through
`constraintArgMonos` → `constraintArgMono` (`:16460-16463`), which returns `None` for a
non-tyvar argument, and `declaredSchemeOblsFor`'s own header (`:16429-16433`) states the
consequence: *"A predicate is kept only if EVERY argument is a plain tyvar … a partial
vector would be a different predicate."* So `Ix a Char` contributes **nothing** to the
scheme obligations either — which is why `check --types` prints `useIx : a -> Int` with
the context erased (verified first-hand). The comment is true only for a predicate all of
whose arguments are variables, and that is precisely the case that does not need it.

**Why no stage of the plan removes the cause.** The negative was searched in the
*implementation's* vocabulary and across stages, not only for the issue's phrase:

- **`#607` appears zero times** in `TYPECHECK-TARGET-ARCHITECTURE.md` and in this ledger.
- **§2 I** completes the obligation channel's *storage* (*"obligations complete the #991
  unification (one `UObligation` with live provenance arms; `implOblToU` retired)"*). The
  storage is already n-ary; the producers are not. Storage unification does not restore a
  discarded argument.
- **§2's cross-cutting substrate** is the only place the plan touches this table at all:
  *"Fused lockstep tables (#994). Slot-parallel pairs (`funConstraints`+`Ifaces`, …)
  become single record-valued tables."* That is B-3, and it preserves the slot
  **cardinality** exactly — it fuses `(name, List Int)` with `(name, List String)` into
  one record-valued table with the same one-entry-per-tyvar shape. B-3 edits the defect's
  home and leaves the defect.
- **§2 S** and **§2 K** both quantify over a goal `C τ̄` — *"every goal that reaches
  `inst` goes through the one `min⊑` selector"*, *"IE's candidate set for a goal `C τ̄` is
  every instance of `C` that matches `τ̄`"*. They legislate what happens **to** `τ̄`. No
  clause anywhere says who **builds** `τ̄`, or that any producer currently fails to.
- **§2 E's arity clause** (the G-8 amendment) carries *"leading dict-param count and
  order (DICT §8 I1)"* as data. ⚠️ **It does decide what one slot means — by reference,
  and this row said otherwise until adversarial review corrected it.** §8 **I1** makes the
  dict params' *"count, order, **and predicates**"* part of the binding's elaborated type
  (`docs/spec/DICT-SEMANTICS.md:1319-1321`), citing §4 `gen`; and §4 **`gen-sig`**
  (`:463-465`) writes the abstraction as `λ d̄_sig. e'` where
  `d̄_sig = (d₁:π₁)…(dₖ:πₖ), {π₁..πₖ} = Q_sig` — **one dict param per predicate**, with
  §4 `gen`'s prose saying the same (*"abstracts a dictionary parameter for each
  predicate"*, `:476-477`). So a **conformant** §2 E gives `Ix a i =>` one parameter, not
  two. What §2 E lacks is not the rule but a **repair**: it mandates that the count be
  carried and conformance-tested, not that any producer be changed.

So the plan has no owner for the *repair* the source calls *"the dict-slot=predicate
change (#607 punch-list item 3)"*. It is not quite true that nothing in the plan reaches
this class — §2 E's **mandatory hand-derived arity conformance fixture** is a named stage
carrying an artifact that would **detect** it (see the sequencing note below). Detect is
not repair, and no stage repairs it, which is why the verdict is GAP; but the earlier
phrasing "no stage owns it at all" overstated the case and is corrected here.

**Is #1161 a member of G-8? No — and the test is the one this ledger uses everywhere
else: apply the remedy in full and see whether the repro moves.** Implement G-8 to
completion — one arity and calling convention, computed once, carried in the elaboration
output, consumed by eval and both backends. `useIx : Ix a Char => a -> Int` still
registers one slot, `routesOfMonosTop` still hands `entailInst` the goal `[Int]`, and
variant A still prints `111`. **G-8 fully landed changes nothing here**, which is this
ledger's criterion for "not drained by". The two defects differ in kind: G-8's is
*multiplicity* (three derivations of one arity — `implMethodValue`'s pattern count,
`methodArityOf`'s arrow spine, define-vs-call), remedied by centralizing; G-10's is
*loss* (three producers of one predicate, all lossy), remedied by not discarding.
Centralizing a lossy value is not a repair.

⚠️ **That "changes nothing" holds for THIS repro, and it holds by a coincidence that must
be stated or the verdict looks broader than it is.** #1161's repro is
`useIx : Ix a Char => a -> Int` — a predicate with **exactly one type variable** — so the
spec's count (one param per predicate) and the implementation's count (one per variable)
**coincide at 1**, and a conformance-faithful G-8 has nothing to disagree with. Add one
variable (`Ix a i =>`, this row's own example below) and they diverge: spec 1,
implementation 2. **At that shape a conformance-faithful G-8 does touch the defect** — its
fixture reds. The GAP verdict is unaffected (a red fixture is a detector, not a fix, and
the repro is what this row grades) but the boundary is narrower than "G-8 is orthogonal".

🚨 **The coupling to #1137, corrected — the direction of the hazard is the opposite of
what this row first claimed, and the guard is sharper for it.** The earlier text said
#1137 *"freezes the shattered count into the output contract"*. **A conformant #1137
cannot**, per the spec chain above: §2 E cites §8 I1, I1 cites §4 `gen`, and `gen-sig`
gives one parameter per predicate — so a #1137 that publishes 2 for `Ix a i =>` is
publishing a value its own governing clause forbids. **#1137 is therefore blocked BY G-10,
not a freezer OF it**, and §2 E's mandatory hand-derived fixture is what makes that
visible rather than silent.

The real hazard arrives by a different route, and it is an implementer-behaviour hazard
rather than a plan defect: **an implementer sees the mandated fixture red and "derives"
the expected value from `dictArityOf` (2) instead of from §4 `gen-sig` (1).** *That*
freezes the shattering — and it is exactly the failure this repo's capture-ban rule
exists to prevent (*"a captured golden records what the engine did"*), reached through a
fixture rather than a golden. So the guard #1137 must carry:

> #1137's arity conformance fixture **must** include a ≥2-variable predicate
> (`Ix a i =>`), and its expected value **must** be hand-derived from
> `docs/spec/DICT-SEMANTICS.md` §4 `gen-sig` (`d̄_sig = (d₁:π₁)…(dₖ:πₖ)`), never read off
> the implementation. **It will red until G-10 lands. Do not weaken it to match.**

The conclusion is unchanged: **G-10 must be adjudicated before or with #1137**, because
#1137 cannot honestly go green before it.

**Which law.** **L1**, on this ledger's Shape 1: three producers of one judgment, none
complete, and the incomplete ones on the path that decides emitted code — with the extra
sharpness that the n-ary representation they should be filling *already exists* beside
them. **L4** is implicated too, and not merely in spirit: L4 makes evidence *structured*,
and DICT §2's evidence unit is the **predicate** — one dictionary discharges `Ix a Char`,
not one dictionary per variable it mentions. A per-tyvar dict slot is a representation in
which the evidence for a multi-parameter predicate cannot be named at all, which is why
the route has nothing to select on. This is **not** L4's binder-uniformity clause (family
C's); it is L4's first clause, at the evidence unit rather than at the binder. **L3** is
the law the *symptom* violates (declaration order decides a result the spec makes
order-free), but L3 is downstream: order-dependence is what an under-determined goal looks
like when it reaches a first-match tie-break.

**And L5, which this row missed on its first pass — the shattering already violates a
NORMATIVE clause, and the enforcement table cannot see it.** §4 `gen-sig`'s abstraction
half is normative (`d̄_sig = (d₁:π₁)…(dₖ:πₖ)`, `docs/spec/DICT-SEMANTICS.md:463-465`), so
the per-tyvar producer is not merely un-owned by the migration — it is
**non-conformant to a clause that already exists**. §11's `§4 gen-sig` row
(`docs/spec/DICT-SEMANTICS.md:1620`) names only the **coverage** half
(`checkSigConstraintCoverage` / `checkSigConstraintOne`, i.e. the `Q_sig ⊩ P'ᵢ` side
condition) and carries no 🔴 in its last column, where sibling rows do for exactly this
kind of divergence. The `=>`-leg's **arity producer has no site at all**: grep
`docs/spec/DICT-SEMANTICS.md` for `constraintTyVars`, `registerMember`,
`funConstraints`, `registerConstraintRegs`, `registerMemberSlots` or `tyVarArgNames` and
every one returns zero (verified at `5c3ded21`), while the §4 `gen` row's named sites
(`setDictEligible`, `registerInferredConstraints`) are the **unsignatured** path
(`typecheck.mdk:9553` calls its input the *"INFERRED (unsignatured) constraint"*). By L5's
own rule — *"A rule with no site is an unimplemented clause"* — half of `gen-sig` is
unimplemented and the table records it as satisfied. That is a §11 row this arc owes,
**not** edited here: the spec change is a separate PR and this ledger is not its author.

**Falsifiable prediction — ⚠️ NULL, and labelled as such.** **No stage of this arc as
written changes #1161's behaviour**: variants A and B must still print `111` and `222`
after every stage S–F lands, and `check --types` must still print `useIx : a -> Int`.

⚠️ **Read the direction before grading it.** This is a *null* prediction — the kind a
stage that does nothing satisfies, including a **broken** stage — and it is
**one-directional**: an observed change **refutes** the GAP verdict, but no amount of
"still `111`" ever confirms that a stage worked. It is the honest form for a GAP row (the
claim *is* "nothing reaches this") and it is strictly weaker evidence than the positive
predictions elsewhere in this ledger, e.g. #1162's, which names a specific new diagnostic
at a specific stage. Do not treat the two as equally gradeable.

🚨 **GRADED 2026-07-31 — HALF REFUTED, by a stage the arc did not have when this was
written.** F-3a-ii — the arity-neutral intermediate this row *offered as an option*, since
scheduled ahead of F-3b — **landed**, and variant A now prints **`222`** on `run` and on
the shipped native binary, with A and B agreeing. The first half of the prediction is dead.
The second half held until 2026-08-23: `check` printed `useIx : a -> Int` with the context
erased, and the unsatisfiable `Ix a Bool =>` was accepted at exit 0 — leg 4, below.
**CLOSED** by the slice `S-obligation-nary-payload`, which widened the obligation payload
itself (`VecObl.voArgs` carries the predicate's whole argument vector, and
`declaredOblMixed` records a predicate whose arguments are bare bound tyvars and ground
types). `check` now prints `useIx : Ix a Bool => a -> Int` and rejects with
`No impl of Ix for Int Bool`; the regression guard is
`test/dict_fixtures/s3-sig-constraint-unsatisfiable-rejects.mdk`, and its accept-direction
twin is `test/dict_fixtures/s3-nary-sig-constraint-goal-vector.mdk`.

⚠️ **CLOSED IS SINGLE-FILE ONLY — do not read it as the whole obligation-channel gap.** The
end-of-sprint review round (2026-08-23) found the fix does not cross a module boundary: an
imported constrained function with the same unsatisfiable-goal shape still silently accepts
(no cross-module qual twin for the argument-vector table — `declaredConstraintArgs`' own
header has recorded this residual since before this sprint). Filed as **#1868**. Separately,
two predicates over the *same* interface at one tyvar id still collapse to one dict slot in
this same `=>` channel (`(Ix a Char, Ix a Bool) => …` gives `444` where `333` is correct) —
filed as **#1866**, and it is why #1137's arity rule needs the caveat recorded on that issue.

⚠️ **SCOPE THE REFUTATION PRECISELY — the unqualified reading is WRONG.** "Order no longer
decides on this leg" holds only when the multi-argument predicate is the **first predicate
declared over its type variable**. Measured A/B, cold builds either side, varying only
`compiler/types/typecheck.mdk`:

| `=>` context | main | F-3a-ii | correct |
|---|---|---|---|
| `(Ix a Char, Dbg a)` | 116 | **227** ✅ | 227 |
| `(Dbg a, Ix a Char)` | 116 | 116 ❌ | 227 |
| `(Dbg c, Ix a Char)` — distinct tyvars | 116 | **227** ✅ | 227 |

The residue is a **different defect on the other side of the same slot**, filed as **#1177**
(S0, verified): `funConstraintsRef` is per-tyvar, so two predicates over one `a` register
two slots with the **same id**, and `enclDictVarOf`'s `indexOfId` returns the **first**
match — every use in the body reads slot 0. F-3a-ii's route is computed correctly and lands
in the right slot; the body consumes the wrong one. Not a regression (main is 116 either
way), and **no gate can see it**: `diff_compiler_dict_semantics.sh` §4 permutes `impl`
blocks, and nothing in the tree permutes predicate order in a signature.
⚠️ Read what that licenses. Because the prediction is one-directional, the refutation says
the GAP verdict was wrong about **reachability** for legs 2–3 — *not* that the mechanism
analysis was wrong. Legs 1–3 are described correctly; what the row could not know is that
the goal vector is recoverable **from the signature at registration**, without unshattering
the dict slots at all.

Two corollaries make the diagnosis sharper, and both must hold or it is wrong. ⚠️ **Neither
is currently executable** — F-3a is unmerged (probe only) and B-2 (#1113) has not started —
so they are gradeable *when those stages land*, not today:

- **F-3a (the `requires`-leg vector threading) must leave both variants unchanged.** Its
  probe adds a `List Mono` to `EKNestedTop` and delegates from the scalar entry points
  with `[]`; `routesOfMonosTop`'s leg reaches `entailInst` through `routeOfD`, which is
  the delegating wrapper — so the goal on this leg stays `[m]` by construction. If a
  build of F-3a alone makes variant A print `222`, this row's leg-2 trace is wrong.
- **B-2 must leave them unchanged too.** B-2 stamps an `InstId` wherever `inst` runs; here
  `inst` runs and selects the wrong instance from a complete candidate set and an
  incomplete goal. B-2 would stamp the wrong instance's identity faithfully.

**The one positive, executable prediction this row does carry** is #1137's, above: its
arity conformance fixture at `Ix a i =>`, expected value hand-derived from §4 `gen-sig`,
**must red** on today's binary and go green exactly when G-10 lands. That one can fail in
both directions and is checkable the day the fixture is written.

**⚠️ Sequencing consequence for F-3, and it inverts the stage's declared order.** F-3c
(#1155) makes `pickMostSpecificEntry`'s no-unique-minimum arm a hard diagnostic, on the
stated precondition that the candidate-set deformations feeding it are repaired first
(F-3a, F-3b). Leg 3 above **is** that arm, reached from this leg, **and neither F-3a nor
F-3b repairs this producer** — F-3a threads the vector on the `requires` route, F-3b
unions the headless bucket (#1128), and the `=>` route's vector is destroyed upstream of
both. So on the order as written, F-3c turns `useIx : Ix a Char => a -> Int` — a program
that is unambiguous under DICT §3 once the predicate is whole — into a hard reject. That
trips #1155's own acceptance criterion 3 (*"no fixture outside the declared flip list
newly rejects"*), which its issue declares a STOP condition. **Sizing: this is not a
subset of F-3a.** F-3a's probe is ~31/20 lines inside one entail arm and its recursion;
repairing this leg means changing what a dict slot *is* — `constraintTyVars` /
`registerMember` / `funConstraintsRef`'s payload, `constraintMonosOf`,
`routesOfMonosTop`'s per-slot scalarity, `dictArityOf`, and `dictPass`'s prepend — with an
arity move, a seed re-mint, and both engines' calling convention in the blast radius.

**An arity-neutral intermediate exists and should be priced before the full change is
scheduled** — offered as an option for the owner, not a recommendation this row makes.
Keep one dict slot per **tyvar** (arity unchanged, no seed re-mint, no engine change) and
additionally record, per slot, the **whole predicate's argument vector** with its concrete
arguments resolved, so the route selects on `[Int, Char]` while the dict-passing
convention is untouched. It is redundant where a predicate has two variable arguments (two
slots, one predicate, two identical goals) and it does **not** move toward L4's evidence
unit — so it is a second transitional step, not the target — but it closes legs 2–3 and
unblocks F-3c without touching emitted arity.

⚠️ **Two claims in this paragraph were MEASURED WRONG and are corrected here (2026-07-31),
by a scoping pass that built the change rather than reading it.**

- It said **"closes legs 2–4."** It closes **2–3**. Leg 4 — an unsatisfiable partially-concrete
  constraint being accepted — was tested directly: `recordCallObligations` was made n-ary at
  exactly the site that now carries the vector, built, and run, and the program is **still
  accepted at exit 0**. Leg 4's home is `declaredSchemeOblsFor` → `declaredOblOne` →
  `constraintArgMonos`, on a channel whose payload is `List (String, List Int)` — **ids only,
  with no room for a concrete argument.** Widening it is a separate obligation-payload change,
  not a rider on this one.
- It said the machinery **"already exists: `constraintArgMonos`."** That function is **not
  usable here**: it returns `None` for any non-tyvar argument, which is exactly the `Char` in
  `Ix a Char` that the whole fix is about. The correct resolver is **`fromAstType tvMap`**.
  This is the more expensive of the two errors — it names a real symbol that resolves, so it
  reads as verified, and it points an implementer at a function that silently drops the datum.

`headSubstWithParams` (`:11850-11856`) does already match a goal vector against an impl head
vector, and is reached without a new call site — that part of the claim holds.

✅ **LANDED 2026-07-31 as F-3a-ii**, exactly as this paragraph describes it, and every
claim above survived contact with the implementation. `funConstraintArgsRef` is a table
**slot-parallel** to `funConstraintsRef` (its payload untouched, so `dictArityOf` /
`dictPass` / `scopeArities` / the cross-module arity snapshot are literally unmodified);
`routesOfMonosTopV` / `topRouteV` / `vectorGoal` route on it, gated on vector length > 1 so
the 1-ary path is byte-identical **by construction**; `constraintVarArgMonos` resolves the
arguments with `fromAstType tvMap`; `substArgVec` substitutes with `substMono`. Arity
neutrality is now pinned STRUCTURALLY by two emitted-IR rows in
`test/diff_compiler_dict_semantics.sh` (`useIx` at arity 2 and arity 3) — no behavioural
assertion can see an arity move, which is why the value rows alone were not enough.
⚠️ **Two residuals were left SCALAR and are named at `declaredConstraintArgs`**, not
covered by anything: the cross-module qual table (there is no `(definer, name)`-keyed
vector table, and a stored vector's tyvar arguments carry per-module ids that would need
`attributeModuleArities`-style re-attribution — a mis-attributed vector is a
wrong-but-**concrete** goal, strictly worse than a missing one), and
`resolveRLocalSites`/`SKRLocal`, which is entangled with the first through
`shadowStandaloneDictSlots` → `declaredConstraintSlots`.

⚠️ Two further constraints, both **silent** if missed, established by the same pass: the
substitution must be **`substMono`**, not top-level only (a top-level substitution leaves an
interior signature tyvar unmapped, `matchTyMonos` fails, the candidate set goes **empty**, and
the route degrades to bare-tag first-match — the original bug at a different shape); and
**F-3c does not catch that class**, because `pickMostSpecificEntry []` returns `None` rather
than the ambiguity arm.

---

## Family C — locals not dict-abstracted

### #1040 — `where`-local helper at two types · **DRAINED-BY F-1** (#1082)

**Mechanism (verified).** `dict_pass` prepends `$dict_…` parameters to top-level defs and
impl methods only; the source states it at `:8893`:

> A local binding is NOT dict-abstracted — dict_pass prepends `$dict_…` params to
> top-level defs and impl methods only, never to a `where`/`let` member

`methodConstrainedIds` (`:8852`) exists to *decline* the generalization instead, and is
consumed at one site inside `generalizeGroup` (`:8791`, `:9308`). With the binding
generalized, each use site instantiates a fresh variable, the method route falls to
`RNone`, and the emitter degrades to arg-tag — first impl group wins for both sites.

**Why the plan removes the cause.** L4 makes evidence uniform at *every* binder:
§2 E states `gen`/`gen-rec`/`gen-sig` apply to "top-level bindings, impl methods, default
methods …, **and local bindings** (#1082)", and §4 family C names the structural cause
exactly ("`gen` applied at only two binder kinds"). Under F-1 the helper `d` gets its own
dict parameter and is routed per use site, so there is no fresh-variable-with-no-route
state to degrade from.

**Falsifiable prediction.** When **F-1** lands, `top = d (1 : Int) ++ d True where d v =
debug v` must print `1True` from the built binary (today: `11`, exit 0) and from
`medaka run` (today: `E-PANIC: intToString: not an Int`). All three engines must agree.

**Sequencing note, not a gap.** F-1 sits at the end of the spine (after C-1, E-2, and
S-2(f)). #1040, #1043 and #1052 stay live for the whole arc; the `must_fail` pins owed on
all three are what keep them visible.

---

### #1043 — block-`let` local helper cannot be built · **DRAINED-BY F-1** (typecheck half) · **ENGINE-REALIZATION** (emitter half) · caveat G-2

**Mechanism (verified).** Same root as #1040, different entry point. `methodConstrainedIds`
is reached only via `processLetGroup` ← `inferLetGroup`; the sibling local-binding paths
`blockLet` (`:5209`), `blockRecLet` (`:5189`), `inferRecLet` (`:7819`) and `inferLetBody`
(`:7901`) never consult it. The emitter then panics in `emitArgDispatchChain`
(`llvm_emit.mdk:5532`) with the message at `:5553`:
`"arg-tag dispatch on impl type that owns no constructors (primitive receiver carries no
cell tag)"` — which #1043 proves misdirects (a constructor-bearing ADT panics identically).

**Why the plan removes the typecheck cause.** Same as #1040: under F-1 the block-`let`
binder is dict-abstracted, the route resolves, and arg-tag is never reached.

**Emitter half stays excluded, correctly.** The unlocated, uncoded, wrong-cause `E-PANIC`
is an emitter diagnostic defect; §4's exclusion of "#1043's emitter half" holds, and the
absence of `medaka build --json` keeps it structurally unreachable to a `Diag` consumer.
That half needs an engine fix regardless of this arc.

**Caveat — see G-2.** F-1's deliverable must be stated over the *set* of local-binding
inference paths, or #1040 drains and #1043 does not.

---

### #1052 — the local-dict pin is itself unsound · **DRAINED-BY F-1** (#1082)

**Mechanism (verified from the issue's IR dump).** The pin declines generalization,
monomorphising the `where`-local `d`, which merges the two **declared, rigid** signature
variables `a` and `b` of `useTwo : (Sized a, Sized b) => a -> b -> Int` and drops a dict
slot: the typed Core IR shows one `$dict_…useTwo_0` parameter for a two-constraint
signature. Both `d x` and `d y` route through the survivor.

**Why the plan removes the cause.** §2 E is explicit: *"The interim all-or-nothing pin
(PR #1021) and its unsoundness (#1052) retire with it."* Under uniform `gen`, `d` is not
monomorphised at all — it is generalized *and* dict-abstracted, `d : Sized v => v -> Int`,
with the two use sites forwarding `$dict_useTwo_0` and `$dict_useTwo_1` respectively.
The merge cannot happen because nothing declines the generalization. S-2(f)'s
value-restriction gate is satisfied here (`d v = sizeOf v` is a syntactic function, so
the restriction already licenses generalization) and its timing-neutrality clause is
satisfied for the same reason.

**Falsifiable prediction.** When **F-1** lands, #1052's repro must print `3` on both
engines (today: `2` on both, `check` green), matching its inlined control; and the typed
Core IR dump (`compiler/entries/core_ir_typed_modules_dump_main.mdk`) must show **two**
`$dict_` parameters on `useTwo`. The IR-dump assertion is the load-bearing half — a fix
that makes the printed value `3` without restoring the second dict slot has moved the bug,
not removed it.

⚠️ #1052's own body warns that *"a fix that merely makes `check` agree with emit is not
sufficient — both already agree here, and both are wrong"*. Applies to F-1's verification
bar too.

---

## Family F — effect rows, polarity, coverage

### #1103 — `unifyRowN` same-tail prefix discard · **DRAINED-BY D-1** (#1118)

**Mechanism (verified).** `unifyRowN` (`:916`), same-tail arm at `:931`:
`| effvarId v1 == effvarId v2 = recordAbsorptions (atomsDiff l1 l2 ++ atomsDiff l2 l1) v1`
— the prefix mismatch is recorded for the #839 event trail and otherwise discarded. The
arm's own comment calls the leniency *"ACCIDENTAL, NOT load-bearing"* and points at the
declaration-time covering rule; #1103 proves that rule does not reach a plain top-level
function, because `checkArgEffVarCoverage` (`:1170`) is wired only from
`checkIfaceMethodEffs` (`:1138`), reached only from `checkUndeterminedRetEffVarsDecl`'s
`DInterface` arm (`:1132`).

**Why the plan removes the cause.** §2 I names it at the spec's precision: *"the same-tail
arm must still check the atom prefix (#1103)"*, and §6 D-1 owns it by number. The fix is
a prefix-equality check on the arm, not an unconditional error — which is exactly what the
source comment's warning ("a benign self-unify `e ~ e` also lands here") requires, and
D-1's phrasing preserves it.

**Falsifiable prediction.** When **D-1** lands, `launderArrow : (Unit -> <Stdout | e> Unit)
-> (Unit -> <e> Unit); launderArrow f = f` must be rejected at its declaration or at
`quiet = launderArrow shout` (today: `check` exit 0, both engines print `SMUGGLED`), while
control 1 (identical rows, `honestArrow`) must keep its existing rejection at
`10:20` and the benign self-unify `e ~ e` must remain silent — a D-1 that reddens the
compiler's own sources on `e ~ e` has overshot.

---

### #1098 — mutable containers widen an effect-row-carrying parameter · **DRAINED-BY D-2** (#1119)

**Mechanism (verified).** Two contributing routes, per #1098's own correction: the
`<>`-supplied case reaches `unifyRowN (EffRow _ None) (EffRow _ None) = ()` (`:988`)
because `reopenRowN True (EffRow (l::ls) None)` (`:3663`) re-opens only rows carrying at
least one label; the non-empty case reaches the *correct* guarded subset check. Neither
site accounts for mutation, and `Ref`'s type parameter carries no invariance requirement.

**Why the plan removes the cause.** §2 I is explicit that write channels are **not** the
rule: *"Write channels (`Ref`/`MutArray`/`HashMap`, #1098) are the co∧contra special case
of this rule, not the rule"*. D-2 computes a per-parameter polarity from field occurrences
and propagates it transitively; `Ref a`'s parameter occurs in both the read and the write
signature, so it is mixed ⇒ invariant ⇒ no covariant row leniency at that argument. The
three stdlib types built on `Ref` (`MutArray`, `HashSet`, `HashMap` — grep-confirmed in
#1098's body) inherit it through the transitive propagation rather than through a
hand-maintained table, which is what makes this a class fix.

**Falsifiable prediction.** When **D-2** lands, `alias : Ref (Unit -> <Stdout> Unit); alias
= box` (where `box : Ref (Unit -> <> Unit)`) must be rejected (today: exit 0, both engines
print `REF-EFFECT-PERFORMED`), and the same must hold for the `MutArray` and `HashMap`
repros **without a per-type entry being added for either** — if closing them needs three
more table rows, D-2 implemented the special case and not the rule. The `List` control and
the bare-function control must both stay **accepted**.

---

### #1121 — contravariant Type parameter of an ordinary datatype · **DRAINED-BY D-2** (#1119)

**Mechanism.** `data Taker a = MkTaker (a -> Int)` puts `a` in domain position, so `Taker`
is contravariant in `a`; `wide : Taker (Unit -> <IO> Unit); wide = pureTaker` is the unsafe
widening direction (EFFECTS §9). No mutation is involved anywhere, and no
`Effect`-kinded index — so neither #1094's closed fix nor #1098's write-channel framing
reaches it.

**Why the plan removes the cause.** #1121 is the case §2 I names *by this exact example* as
the general rule the write-channel proxy misses, and §6 D-2 says D-2 "**owns #1121**". The
mechanism is the same computation as #1098's: `a` occurs contravariantly in `MkTaker`'s
field ⇒ contravariant ⇒ invariant row treatment at that argument.

**Falsifiable prediction.** When **D-2** lands, `wide = pureTaker` must be rejected (today:
exit 0, both engines print `LAUNDERED`), while the covariant control (`f : Unit -> <IO>
Unit; f = pureFn`) and the `List` control must both stay **accepted**. #1121's own owed-pin
note is right that the accepted controls must be pinned alongside, or the fix overshoots
into rejecting sound re-opens.

**Consistency check on the plan:** #1098 and #1121 must land in **one** change. They are
the same computation at two positions; fixing them separately re-creates the
special-case-first mistake that produced #1121 in the first place.

---

### #1100 — abstract-head row-kinded argument never collected · **DRAINED-BY D-3** (unconditional half)

**Mechanism (verified, line-for-line).** The two halves of one rule disagree about what a
row-kinded occurrence is:

- return side — `methodEffRetOccs scope` (`:1248`) ends
  `++ map (n => (n, [])) (rowArgNamesIn scope t)` (`:1255`), and `rowArgNamesIn` (`:4276`)
  has **both** a `TyCon`-head arm (`:4278`) and a `TyVar`-head arm
  (`(TyVar h, args) => rowArgNamesVarApp scope h args …`, `:4280`);
- argument side — `methodEffArgOccs` (`:1205`) takes **no scope parameter at all**, and
  `argPerformableOccs`' `TyApp` arm (`:1232-1234`) resolves a row slot only via
  `krowSlotOccs` under a `TyCon` head; a `TyVar` head falls to the structural catch-all
  and contributes `[]`.

`checkArgEffVars _ _ _ _ _ [] = ()` (`:1176`) then returns immediately on the empty
variable list, so no obligation is ever raised for `gtake : f e a -> a`.

**Why the plan removes the cause.** §6 D-3 owns exactly this: *"abstract-head row-kinded
arguments are `collected` at all (#1100)"*. The fix is symmetry — thread the graded scope
into `methodEffArgOccs`/`argPerformableOccs` and give the latter a `TyVar`-head arm
matching `rowArgNamesVarApp`. Note this half is **unconditional**: unlike #1095 it does not
depend on the #823 fork, because `gtake`'s return type is a bare variable with no index to
discharge anything.

**Falsifiable prediction.** When **D-3** lands, `g1_abstract_head_notake.mdk` must be
rejected at the `gtake` declaration with `T-EFFECT-ARG-UNCOVERED` (today: exit 0 on
`check`/`run`/`build`, prints `BOOM 7`), matching its concrete-head control `g2` and its
one-token control `g5`. The charged-arrow control `g3` must keep its existing rejection.

⚠️ **Sequencing, stated by #1100 itself and worth holding the plan to:** `gpure`, `gap` and
`gtake` are green today *because of this defect*; closing it moves them into #1095's
population. So D-3 must land #1100's half and #1095's half **together**, or the graded
fixtures redden in between. §6 D-3 groups them, which is right — but the epic's stage table
lists D-3 as "#1095 + #1100, coordinated with #822/#823", and #1095's half is `◇`-gated
while #1100's is not. That asymmetry is the risk.

---

### #1095 — result-index occurrence discharges argument coverage · **GAP (G-3, ownership)**

**Mechanism (verified).** `methodEffRetOccs` (`:1254-1255`) folds `rowArgNamesIn scope t`
into the *return* occurrence list, and `checkArgEffVars` (`:1177`) treats a non-empty
`retOccs` as discharging the argument-only requirement. A result **index** occurrence
(`f e b`) is a promise about force time, not a charge at call time — so an impl arm that
applies the callback eagerly performs `<e>` with nothing charging it.

**Why this is a GAP rather than DRAINED-BY D-3.** The design assigns it away twice, and
the other side assigns it back:

- §4 family F marks it `#1095 ◇graded-arc` — *"if #823 resolves to the uncharged-signature
  option, the launder stays representable and only the arc closes it"*.
- §6 D-3 repeats it — *"if #823 resolves the eager-arm fork to the uncharged signature, the
  launder remains representable and the arc — not this stage — closes it"*.
- And #1095's own body quotes the graded arc's decision record as saying of the
  defer-vs-eager fork: *"Both options close #817/#825 equally — this was never a soundness
  question, only a cost one."* **#1095 exists to disprove that sentence.**

So D-3 defers to #823 on the grounds that #823 will decide it, and #823's recorded premise
is that there is nothing to decide. **There is no stage in either arc that is
unconditionally committed to closing #1095**, and the `◇` marker makes that look like
coverage rather than the ownership hole it is.

**Proposed plan change.** Make #1095's *unconditional* half explicit and give it to D-3
regardless of the fork:

> D-3 must land the coverage/charge separation — a result-**index** occurrence never
> discharges the argument-only requirement — **independently of #823's eager-vs-defer
> resolution**. What #823 decides is whether the eager arm remains *writable*; what D-3
> decides is whether writing it is *diagnosed*. These are different questions and only the
> second is this arc's.

Concretely: today the honest signature (control 2, `gmap : (a -> <e> b) -> f e a -> <e> f e b`)
is expressible and enforced at every call site, so there is a correct target for the
diagnostic to point at. The fix does not require the fork to be resolved.

**Falsifiable prediction (once ownership is fixed).** `f3_graded_eager_pure_caller.mdk`
must be rejected — either at the `impl GMap Box` eager arm or at the `gmap` declaration —
where today `check`/`run`/`build` all exit 0 and `pureInt : Int` prints `BOOM`. Control
`f2` (deferred arm) must stay accepted; control `f5` (no index occurrence) must keep its
existing rejection.

---

## Family G — laundering via method schemes

### #819 — impl body pins an impl-HEAD type variable · **GAP (G-1)**

**Mechanism (from the issue, source-consistent).** An impl registers for head `P c d` and
therefore matches every instantiation, but its body only typechecks at `c := String`; a
`P Int Int` receiver dispatches to it anyway. `check` green, `run` panics.

**Why the plan does not remove it.** §4's family G row lists the drained issues as
*"#830 (gen-sig authority), #819 (adjacent); #817 ◇graded-arc, #825 ◇graded-arc"* and names
the design element as *"G: W3 rigid everywhere; #803 bound keeps pre-unify placement"*.

**W3 cannot reach #819, by construction.** W3 is *method-scheme* rigidity —
`checkImplMethodRigidity` / `checkDefaultMethodRigidity` / `checkImplEffVarRigidity`
(`:14749`, `:14766`, `:14927`), all gated by `inRigidityBodyRef`. Impl-**head** variables
are the instance's own quantifiers (the substitution φ) and are **deliberately exempt**;
the source says so at `:14926`: *"(The TYPE-var half has no such carve-out: a method type
var may never alias an impl-head type var.)"* — i.e. the rule that exists is about method
vars aliasing head vars, not about head vars being pinned by a body. #819's own text
states the same: *"impl-HEAD vars are the instance's own quantifiers and are exempt there
by design."*

Making W3 "rigid everywhere" therefore does nothing for #819. The parenthetical
"(adjacent)" is doing all the work in that matrix cell, and "adjacent" is not a drain.
**No stage in §6 owns an instance-head fidelity check.** C-2 (#830) is signature authority
for *declared function signatures*; G's other listed items are W3, the #803 bound, and the
graded carve-out. Nothing else.

**Proposed plan change.** Add the instance-side analogue of W3 to Stage G / C-2's scope,
and write its spec paragraph into S-2 alongside (d) (impl completeness / phantom-method
rejection), which is the same "instance well-formedness at the declaration" bucket:

> **W3-inst (instance-head fidelity).** Every impl-head type variable must survive the
> checking of every method body of that impl as an unconstrained variable. If a body pins
> one to a concrete shape, reject at the impl declaration and name the narrowing the head
> would need (`impl Sizer (P String d)`) — the same C3-style post-unify survivor check W3
> already runs, keyed on the head vars instead of the method's own quantifiers.

The machinery exists (`checkMethodRigidityCore`'s survivor comparison), the diagnostic
shape exists (`T-IMPL-TOO-SPECIFIC`), and the check is decidable at the declaration where
`IE` is in hand — so this is an extension of an existing stage, not a new one. It belongs
with C-2 because both are "the declaration is authority over the body, reject rather than
narrow".

**Falsifiable prediction (once owned).** #819's repro must be rejected at
`impl Sizer (P c d)` naming `c` (today: `check` green, `run` panics with
`'++' requires Semigroup` in the reviewer's variant). Until a stage owns it, the honest
prediction is **that no stage of this arc changes #819's behaviour at all.**

---

### #817 — Async's `Mappable`/`Thenable` identify the method effect var with the container row · **GAP (G-3, ownership)**
### #825 — deferred effectful callback under a pure stored arrow closes the method effect var · **GAP (G-3, ownership)**

**Mechanism (verified in source).** Both are *deliberately admitted* residuals of the W3
check. `checkImplEffVarRigidity` (`:14927`) carries two comment blocks stating it:

- `:14916-14926` — *"⚠️ #817 carve-out: a method effect var unifying with an INSTANCE-HEAD
  row parameter (`impl Mappable (Async e)` …) is deliberately ADMITTED — the impl-head
  types' row tails are NOT in the dup set. It is a real residual laundering channel …
  Resolution is design-scoped (#817)."*
- `:14934-14944` — *"⚠️ DEFERRED-PERFORMANCE residual (round-2 break 4; tracked, NOT
  enforced) … Rejecting it here is CORRECT but outlaws the compiler's own Parser monad …
  the channel is admitted for now and owned by #825 (pinned)."*

**Why this is a GAP.** The design is *honest* about not owning them — §4 family G marks
both `◇graded-arc` and adds *"the arc is a peer, not a subtask — these drain there, not
here"*, and §8 lists the arc's own design forks as out of scope. That is a defensible
scoping decision and I am **not** proposing to reopen it. The gap is narrower and real:

**the architecture's assumption that the graded arc closes these is not currently
underwritten, because the graded surface's own coverage rules are open S0s.** #1095 and
#1100 each show the graded signature shape the arc will ship (`f e a`, `(a -> <e> b) ->
f e a -> f e b`) is accepted with **no** declaration-time obligation on the impl — #1100's
own §"Bearing on #820/#823" puts it plainly: *"the 'eliminate only through `grun`'
discipline the graded design rests on is, for abstract heads, entirely on the honour
system."* So the migration path #817/#825 are waiting on can be completed and still leave
the laundering channel open, one shape over.

**Proposed plan change (small, and it is a coordination note, not a re-scoping).** §8's
"Graded-arc coordination" bullet names two coordination points (A-3 ↔ #822 kind
machinery; D-3 ↔ #823 coverage rules). Add a third, and make it a **precondition** rather
than a rebase note:

> **#817/#825 may be closed by the graded arc only after D-3's coverage/charge separation
> is in force.** Migrating `Async`/`Parser` to a graded row index is not sufficient on its
> own: #1095 and #1100 demonstrate that the graded surface accepts an eager arm and an
> uncharged abstract-head method with no diagnostic, so a migration performed before D-3
> relocates the laundering channel rather than closing it (`#1044`-shape: relocating a
> collision is not a fix).

**Falsifiable prediction.** No stage of *this* arc changes #817's or #825's behaviour —
both repros must still launder after every stage S–F lands. That is the gradeable claim,
and it is why both rows read GAP rather than DRAINED-BY: the arc's own output for these two
is "unchanged, by design", and the risk is that a reader of the matrix's `◇graded-arc`
marker reads it as coverage.

---

## Family J — coherence condition and scope

*(§4's family J. Its two named issues, #311 and #614, are the *condition* half — (a)
global comparability where the spec commits to (c) per-goal minimum. #1162 is the *scope*
half, and it is what makes the condition question secondary: a declaration-time check
that cannot see half the instance universe is unsound under either condition.)*

### #1162 — `checkCoherence` sees USER decls only; the key table is prelude ++ user · **DRAINED-BY F-3c** (#1155) · **plus GAP G-11**

**The framing handed to me was that this is a scope disagreement, not a keying bug. That
is right. What the issue does not yet say — and it changes the fix's price — is that the
exemption which creates the scope is justified by a behaviour that does not exist.**

**Mechanism (verified, and reproduced first-hand on a binary cold-built in this worktree
at `5c3ded21`).**

- The coherence input is a **parameter**, and every caller passes user decls.
  `checkCoherence userDecls` (`:10984-10985`) scans `cohCollectImpls userDecls`
  (`:11381-11383`); `runFinalChecks` (`:11227-11232`) takes `cohDecls` separately from
  `cycDecls`, with the warning at `:11224-11226`: *"⚠️ trap #5: coherence must see USER
  decls only, so this helper has NO access to `prog` — the caller decides [cohDecls]
  explicitly (never a `prog` fallback)."* The module driver passes this module's own
  `prog` (`:18097`); the single-file drivers pass `driverState.value.coherenceUserDecls`
  (`:11430`, `:16892`). The cross-module pass is a second, equally narrow collection:
  `cohCollectModuleImpls` (`:11396-11399`), whose header states the exclusion and its
  reason at `:11389-11390`.
- The selector's table is **not** narrow: `buildKeyTable implDecls` (`:18794`, and
  `buildKeyTable prog2` at `:9586`) is built over the accumulated universe, prelude
  included. The goal `Index (List Int) Int Int` therefore matches the prelude's
  `impl Index (List a) Int a` (`stdlib/core.mdk:1087`) **and** the user's
  `impl Index (List Int) k Int` at full vector length (three each, so `entryHeadMatches`
  takes its length-equal arm, not the arg-0 fallback), and the two are not
  `entryCovers`-comparable, so `pickMostSpecificEntry` (`:11616-11620`) keeps the head of
  the list. Verified: `check --json` → `{"diagnostics":[]}`, `run` → `1`, native build and
  execute → `1`; the user impl never runs. The identical user-vs-user shape is rejected
  with `Overlapping impls of Idx: List Int a b and List c Int c can match the same type`
  (verified, exit 1).

  ⚠️ **A source trace alone cannot establish that last step, and this row originally
  rested on one.** The reading above is indistinguishable, from the trace, from a
  competing explanation that would kill the verdict: that the user's impl is simply
  **absent** from the bucket the selector scans, so the prelude wins by default and
  `pickMostSpecificEntry`'s fall-through never fires at all. Under that reading the defect
  would be a registration bug, not a coherence-scope bug, and F-3c would not touch it.

  **A one-token discriminator settles it, and it is the load-bearing evidence for this
  row** (run first-hand on the binary built here). Replace the user impl with the
  *strictly more specific* `impl Index (List Int) Int Int where index _ _ = 42`, leaving
  everything else byte-identical:

  ```
  check  → main : Unit        (exit 0)
  run    → 42
  build + execute → 42
  ```

  A user impl of a **prelude** interface is therefore registered in the same buckets as
  the prelude's and **is** selected when it wins `min⊑` — `42`, not `1`. So in the
  ⊑-incomparable case both entries are demonstrably co-present in one candidate list, the
  registration explanation is refuted, and the only remaining mechanism is
  `pickMostSpecificEntry`'s `None => Some e` arm firing on two co-present incomparable
  entries. That is precisely the arm F-3c makes loud, which is what makes the DRAINED-BY
  verdict below a mechanism rather than a hope.

🚨 **The exemption's stated justification is false, and this is a new finding rather than
a restatement of the issue.** `cohCollectModuleImpls`' header (`:11389-11390`) excludes
prelude impls because *"a user `impl Eq Int` legitimately overrides the prelude one, so
prelude impls must NOT be in the set"*. Using that comment's **own example**, on the
binary built here:

- `impl Eq Int where eq _ _ = False` + `main = println (eq (1 : Int) (1 : Int))` →
  `check` exit 0, `run` → `True`, native build and execute → `True`.
- `impl Display Int where display _ = "USER"` + `main = println (display (5 : Int))` →
  `check` exit 0, `run` → `5`.
- `impl Index (List a) Int a` — head **exactly equal** to the prelude's — `check` exit 0.

The override does not happen on either engine. **The exemption protects a behaviour the
language does not implement**, and every equal-head user impl of a prelude interface is
accepted and silently dead — the same S0 shape #1162 reports, reached without needing any
overlap at all. That matters for the fix's price: widening coherence's input does **not**
narrow acceptance of any *working* program, so §5 R2's "only widenings are licensed" bar
is not the obstacle it looks like. It does still change acceptance for programs that
compile today with a dead impl, which is why the disposition below is the design's own
`(a)`-warning rather than a new error.

**Why the plan removes the cause — and which half of the plan actually does it.**

§2 K commits the environment: `IE` is *"every impl with its full head, context, and
method table"*, *"assembled once and never per-module"* over the topologically-loaded
module graph, and it hosts *"declaration-time overlap diagnostics (advisory
(a)-warnings; acceptance stays per-goal C1(c))"*. §2 G then commits the consumer, in one
sentence that is the answer to the crux question: *"All of this runs over K's
environments; none of it holds private registries."* Coherence is named in that
paragraph's first clause. So the design **does** commit coherence to consuming the same
environment as the selector — the crux is answered in the affirmative, and the "K unifies
only the selector's view" reading is refuted by that sentence.

But §2 K simultaneously **demotes** the declaration-time check to advisory, and moves
acceptance to the per-goal C1(c) rule. So the stage that turns this program from silent to
loud is **F-3c (#1155)**, not A-3: F-3c makes `pickMostSpecificEntry`'s no-unique-minimum
arm a hard diagnostic, and the arm is *already reached* by this goal today, from a
candidate set that *already* contains both impls. **A-3 contributes nothing to the symptom
and everything to the declaration-time half** — which is exactly why the gap below is
scoped to the input set and not to the verdict.

**#1162's flip-list claim is CONFIRMED.** Its goal matches both entries at full vector
length and they are ⊑-incomparable, so F-3c's arm fires and the program becomes a hard
reject with `T-AMBIGUOUS-INSTANCE`. That is the correct outcome under DICT §6 C1(c), and
it must be on #1155's **declared flip list** — under criterion 3, an unlisted new
rejection is a STOP condition, and this one is reachable from a five-line file against the
prelude with no imports.

**Is this G-6's second symptom? No — commit: it is a distinct L1 fork, one level below
G-6's.** G-6's two implementations (`ImplUniverse`, complete via `univHeadless` at
`:13921-13922`, and `KeyBuckets`, which drops tyvar-headed entries at `keyEntryOf`'s
`headTyconTy` gate — `:11537-11546`, gate at `:11540`, over `headTyconTy _ = None` at
`:11811`; ⚠️ G-6's own row still cites the pre-`5c3ded21` lines `:11362`/`:11632` for these
two — **re-derive them by grep; do not apply an offset**, for the reason in the boxed note
below) are built over the
**same universe** and disagree about the **index**; G-6's remedy is match-preservation,
and applying it in full leaves #1162 exactly as it is, because `cohCollectImpls` is not an
index over IE at all — it is a fourth collection with a narrower **universe**. The two
gaps are also of opposite shape within Shape 1: G-6 has a working reference implementation
twelve hundred lines from the incomplete one, and G-11 has none — no collection anywhere
in the tree answers "the whole instance universe, for coherence". A bug filed as new that
turned out to be an existing gap's second symptom would be a good finding; this one is not
that, and saying so is the point of checking.

> ### ⚠️ This ledger's `typecheck.mdk` line citations have drifted. RE-DERIVE BY GREP — do not apply an offset.
>
> Rows derived before 2026-07-31 cite `compiler/types/typecheck.mdk` at `13b9fafe`/
> `ec51c28e`. Measured against `5c3ded21`, the drift is **not uniform**, and an earlier
> draft of this note quoted a single `~175` figure — which is itself the encoded-fact trap
> this document keeps warning about, committed inside the warning:
>
> | cited | actual at `5c3ded21` | delta |
> |---|---|---|
> | `keyEntryOf:11362` | `:11537` | +175 |
> | `headTyconTy:11632` | `:11811` | +179 |
> | `implMatchesU:13617` | `:13829` | +212 |
> | `implMatchesReceiverU:13628` | `:13841` | +213 |
> | `findMatchingImplReqsU:13666` | `:13879` | +213 |
> | `univHeadless:13707` | `:13921` | +214 |
>
> A reader applying `+175` to the 13.6k region lands **~37 lines short — exactly where
> G-6's "complete reference implementation" citations live**, which is the one place this
> ledger most needs a reader to arrive.
>
> **Bounding any future sweep: the drift is confined to `compiler/types/typecheck.mdk`.**
> Spot-checked at `5c3ded21`, seven citations in four other files are **exact**:
> `eval.mdk:488` (`headTycon (TyApp a _)`), `eval.mdk:1837` (`implMethodValue`),
> `eval.mdk:1888` (`defaultEntry`), `desugar.mdk:851` (`fillImplDefaults`),
> `core_ir_lower.mdk:1267` (`lowerDeclImpl`), `core_ir_lower.mdk:1382-1386`
> (`methodArgTys`), `emit_support.mdk:485` (`methodArityOf` — the signature line, not the
> equation; correct as cited).
>
> ⚠️ **One symbol is now cited at two different lines in this one document** — G-6's
> sequencing note has `pickMostSpecificEntry` at `:11441-11444` (stale) and the #1161 and
> #1162 rows have it at `:11616-11620` (current). Both refer to the same `None => Some e`
> arm. The current line is `:11616-11620`; the stale one is left in place rather than
> silently rewritten, because a row's citations belong to the derivation that produced it
> and a blanket renumber would erase which rows were re-verified and which were not.

**Applying the `.claude/ORCHESTRATING.md` test — "a proposed new LAW may be covering for
an existing one being violated unnoticed" — before proposing anything.** No new law is
needed and none is proposed. **L1** already forbids this verbatim (*"Each spec judgment
has exactly one implementation … never forked"*), and **L3** already forbids the symptom
(the winner is decided by candidate-list order at a position DICT §3 makes order-free).
The reason the laws did not prevent it is the same reason recorded for G-9 and G-5: the
ratchet built from a law is narrower than the law. L1's enforcement in this arc is the
per-stage **blast list**, and no stage's blast list names `cohCollectImpls` /
`cohCollectModuleImpls` / `coherenceUserDecls`. A law with no enumerated consumer is a law
with no site.

**Falsifiable prediction — POSITIVE and two-directional** (unlike #1161's, which is null;
this one names a specific new diagnostic at a specific stage and can fail either way).
When **F-3c** lands, #1162's repro (`impl Index (List Int) k Int` +
`let a : Int = index [1, 2, 3] 0`) must change from `check` exit 0 / `run` `1` / native
`1` to `check` exit 1 with a located `T-AMBIGUOUS-INSTANCE` naming both
`Index (List a) Int a` and `Index (List Int) k Int` — and **three controls must NOT move**:
the user-vs-user control keeps its existing `T-CONFLICTING-IMPL` rejection at the
declaration (not silently relocated to the goal site); the strictly-more-specific
discriminator (`impl Index (List Int) Int Int`) keeps printing `42` on `run` and native;
and the equal-head shape (`impl Eq Int`) keeps `check` exit 0. ⚠️ **Not executable today** —
F-3c (#1155) is unmerged.

⚠️ **CONTROL 1 HAS SINCE MOVED, and by F-3d rather than F-3c — re-read it before
using it.** F-3d (#614/#311, 2026-08-01) demotes DICT §6.1 condition **(a)** to a
`W-INCOMPARABLE-IMPLS` warning, so a ⊑-incomparable **user-vs-user** pair no longer
carries a declaration-time `T-CONFLICTING-IMPL`; at a closed goal it is rejected by
the goal-site `T-AMBIGUOUS-INSTANCE` alone, and at a non-closed goal it now COMPILES
(#1183). The control as written — *"keeps its existing `T-CONFLICTING-IMPL` rejection
at the declaration (not silently relocated to the goal site)"* — was a correct
statement about F-3c and is a false one about the tree today; the relocation it
guards against is exactly what F-3d did, deliberately.

Control 3 — *"the equal-head shape (`impl Eq Int`) keeps `check` exit 0"* — is
**unchanged**, and it is worth being exact about *why*, because the obvious gloss is
false in a direction that would hide a live S0. F-3d keeps a **mutually-⊑
(α-equal)** pair a hard `T-CONFLICTING-IMPL` — but only where `checkCoherence` can
see the pair, and its input is **user decls only**. Control 3's pair is
**prelude-vs-user**, so coherence never compares it: `impl Eq Int` beside the
prelude's still checks clean, exit 0, verified on the F-3d branch against
`test/lint_fixtures/derivable_needs_datadecl.mdk` (`{"diagnostics":[]}`). That is
**#1162's equal-head second symptom**, which this document elsewhere records as
drained by nothing, and F-3d neither fixes nor worsens it. So: the hard arm's
coverage is **user-vs-user only**; do not read "α-equal heads still hard-reject" as
covering the prelude case.

**A-3 alone must NOT close this**: if it is claimed drained after A-3, re-run the repro —
K's declaration-time diagnostic is advisory by its own text, so an advisory warning plus
exit 0 is not a drain. **Without the G-11 clause below, the prediction for the
declaration-time half is null and unaffected by the entire arc**: A-3 can build a
whole-graph `IE` and `checkCoherence` keep reading its `userDecls` parameter, because
nothing names it as a consumer to move.

🚨 **Trap for the F-3c implementer — keying the new diagnostic to `pickMostSpecificEntry`'s
DOCSTRING instead of to its `None` arm breaks the flip list.** The docstring
(`:11613-11615`) says the fall-through covers *"≤1 match, **equal heads**, or incomparable
overlap"*. For equal heads that is **outcome-equivalent but mechanism-wrong**: `entryCovers`
is `tyHeadEqV candTys otherTys || tyStrictlyMoreSpecificV …` (`:11640-11642`), and
`tyHeadEqV` is mutual subsumption (`:11674-11675`), so two equal-head entries each cover
the other, `entryCoversAllOthers` succeeds, and `findMostSpecificEntry` returns **`Some`** —
the `None` arm never fires. The comment eleven lines further down says so directly
(`:11628-11630`: *"Equal-head entries are covered trivially"*), contradicting the docstring
above it. An implementer who rejects on "no unique most-specific" as the docstring defines
it will hard-reject **every** duplicate-instance and every user-overrides-prelude program —
an unlisted flip, and by #1155's criterion 3 a STOP condition. **Key the diagnostic to the
`None` arm, not to the prose.**

⚠️ **Guard when pinning.** The `let a : Int = …` annotation is load-bearing — without it
the expression is `Display`-ambiguous and the fixture fails for an unrelated reason, which
would make the pin immune to the defect it means to catch. And pin the **equal-head**
shape separately from the ⊑-incomparable one: they have different dispositions under the
plan (warning vs hard reject), so one fixture cannot grade both.

### The equal-head prelude-vs-user shape — **NOT DRAINED-BY any stage; recorded here, no gap number**

The three probes above (`impl Eq Int`, `impl Display Int`, `impl Index (List a) Int a`)
are a **second symptom** of the same scope defect, and this ledger's own rule — that a
reader finding nothing cannot tell "out of scope" from "nobody looked" — requires it be
classified rather than left implied by #1162's row.

**No stage reaches it, and the mechanism is stateable.** F-3c cannot: equal heads are
⊑-**comparable** (`tyHeadEqV`), so `findMostSpecificEntry` returns `Some` and the arm F-3c
makes loud never fires (the trap above is the same fact from the other side). A-3 + G-11
relocate the declaration-time check onto `IE`, at which point the pair becomes *visible* —
but §2 K's disposition there is an **advisory (a)-warning**, and this row's own prediction
two paragraphs up declares that an advisory warning plus exit 0 **is not a drain**. So the
honest verdict is: after every stage S–F lands, this shape still compiles at exit 0 with
the user's impl dead, at best with a new warning.

**It gets no gap number, deliberately.** G-11 already names the missing consumer relocation
that would surface it; a second number for the same structural hole would double-count.
What is genuinely unresolved is not an architecture gap but a **language-design question** —
whether a user impl at a head equal to a prelude impl's should be a hard reject, a warning,
or an actual override — and per this ledger's standing rule that is named, not picked. It
is recorded on #1162 as a second symptom with that question attached.

---

## Rows outside the families — adjudicated on request (2026-07-31)

Neither of these is an open `verified` `ws:typecheck` S0/S1 bug, so neither is in this
ledger's stated scope. Both were adjudicated anyway because a reader looking for them
here and finding nothing cannot tell "out of scope" from "nobody looked" — which is the
invisible-work hazard G-7's last paragraph names. Their verdicts are recorded with the
same burden of proof as every other row.

### O-1 — #1139, value restriction folded over the LAST ctor argument only · **CLOSED, and NOT DRAINED-BY any stage**

**State.** CLOSED. Fixed on `main` at `825f9b14` (merge `f3da5bb0`, PR #1149), one commit
before this ledger's derivation point.

**Mechanism of the defect (as filed).** The constructor-application arm walked the left
spine to the head and discarded every argument on the way, so for `C a₁ … aₙ` only `aₙ`
was tested for non-expansiveness; `let b = BR (Ref []) True` therefore generalized a
mutable cell. The repair is a fold over the whole spine on the single walk —
`isCtorAppSpine (EApp f x) = isCtorAppSpine f && isNonexpansive x`
(`compiler/types/typecheck.mdk:3617`), with the sibling arms (`ETuple`, `EListLit`,
`ERecordCreate`, `:3576-3589`) already using `allList isNonexpansive`.

**Would the arc have drained it? No — and this is the interesting half.** The hypothesis
handed to me was that it would not, and I could not falsify it:

- **L1 is not implicated.** There is exactly one implementation of the judgment; the
  defect is *inside* it. No fork, so nothing for L1's "consume, never re-derive" to bite
  on.
- **L2 is not implicated by *this* defect.** The spelling re-derivation in the same
  function is issue 1150's — a different arm. #1139's hole was in the argument fold,
  which involves no name at all.
- **L3, L4 are not implicated.** No order, no evidence tree, no binder set: the defect
  fired identically at every generalization site, because they all call one predicate
  (the site list is enumerated in DICT §11's G2 row, with its own re-derivation grep —
  don't copy it here, it has moved twice).
- **No stage of §6 owns it.** The only value-restriction item in the plan is **S-2(f)**,
  and S-2(f) writes the spec paragraph *gating dict abstraction on* the predicate —
  *"dict abstraction only where the value restriction already licenses generalization"*
  (`TYPECHECK-TARGET-ARCHITECTURE.md:428-430`). It **consumes** the predicate; nothing in
  it repairs one.
- **L5 is the only law with any purchase, and it is not a mechanism.** DICT §4.1 **G2**
  does define the value set normatively, so an L5 conformance fixture hand-derived from
  G2 could in principle have caught this. But L5 is a discipline that has to be *aimed*
  at a shape; "somebody writing conformance fixtures might have picked a non-final `Ref`"
  is not a stateable mechanism by which a named stage reaches the bug, and this ledger's
  own rule says so. **NOT ESTABLISHED** is the verdict for any DRAINED-BY claim here.

**Residual prediction (the row's remaining use).** The arc must not be credited with
#1139, and **DICT §4.1 G2 must not be flipped green on the strength of its closure** —
G2 stays 🔴 HOLED for issue 1150, whose hole is strictly wider (#1139 needed a
hand-written `data` type with a `Ref` field; 1150 needs one stdlib import).
[`../docs/spec/DICT-SEMANTICS.md`](../docs/spec/DICT-SEMANTICS.md) §11's G2 row already
records exactly this — reason changed on 2026-07-31 from #1139 to issue 1150, verdict
unchanged.

### O-2 — #1140, a one-line `where` silently drops an interface method · **OUT OF ARC (pipeline stage)**

**Scope.** OPEN, `verified`, but **S2** and labelled `ws:language` / `ws:diagnostics`,
not `ws:typecheck` — out of this ledger's scope on both axes. Pinned at
`test/must_fail_fixtures/1140-oneline-where-method-silently-dropped/`.

**Mechanism (verified first-hand, not inferred from the issue).** `medaka fmt --write`
is a parse→print round trip, so it renders what the parser actually built. On
`interface Foo a where m : a -> String` it emits (verbatim, stray whitespace included):

```
interface Foo a where
  

m : a -> String
```

— an interface with an **empty body**, and the method re-emitted as a **separate
top-level declaration**. The indented control round-trips unchanged. So the method is
lost at **parse**, in the layout handling of a `where` block opened and closed on one
line; the interface never has a method for any later stage to lose. The eventual
diagnostic #1140 complains about is emitted at **resolve**, not typecheck —
`checkMethodMember` (`compiler/frontend/resolve.mdk:1254-1259`) returns
`[MethodNotInInterface mname iface None]`, and that literal `None` is the
`<unknown location>` / `range: null` the issue reports (`resErrorLoc:204`,
`resErrorCode:1935` → `R-METHOD-NOT-IN-INTERFACE`).

**Why no stage of this arc reaches it.** Stages S–G operate at resolve and later; the
defect is decided before resolve runs. The one place the arc touches the parser is A-1's
collision surface (§6 A-1: *"parser, `resolve.mdk`, `ast.mdk`, printer/fmt, sexp"*), and
that is about carrying an origin field on nodes the parser **already builds** — it does
not change **which** nodes it builds. And the design's own §6 A-3 note already records
that this check is upstream of typecheck: *"§5.1 **M2** (an impl may not define a method
the interface does not declare) is enforced **at resolve**, not typecheck —
`checkMethodMember` → `MethodNotInInterface` / `R-METHOD-NOT-IN-INTERFACE`"*
(`TYPECHECK-TARGET-ARCHITECTURE.md`, §6). **NOT ESTABLISHED** for any DRAINED-BY claim: I
can state no mechanism by which a named stage of this arc reaches a parser layout defect,
and per this ledger's header that is the honest verdict rather than "probably fine".

**Falsifiable prediction.** **No stage of this arc changes #1140's behaviour at all.**
Its must-fail row (`check-json main.mdk` → `T-UNBOUND 2:7-2:8 Unbound variable: m`) must
still reproduce after every stage S–F lands. It drains from the lexer/parser side, per
the issue's own fork: either the one-line form is rejected at the interface with a
located diagnostic, or it is accepted and the method registers.

---

## The remaining gaps, stated once

### G-2 — F-1's local-binder scope must be a SET, not the phrase "local bindings"

§2 E and §6 F-1 both say `gen` applies to "local bindings (#1082)". But #1040 and #1043
are the **same defect at different entry points**, and #1043 exists precisely because the
existing pin is consumed at one of five local-binding inference paths:
`processLetGroup` (via `inferLetGroup`) reads it; `blockLet` (`:5209`), `blockRecLet`
(`:5189`), `inferRecLet` (`:7819`) and `inferLetBody` (`:7901`) do not.

That is L1's own "a second copy for the other path" shape, and the plan's own §2 E already
learned this lesson once for a different set — the red team forced the correction that
E-4's *"schedule's marked-node set must enumerate impl bodies, default bodies, prop and
test bodies"*, because *"a schedule that walks only `DFunDef` groups silently regresses
them"*. The identical enumeration is owed here.

**Proposed plan change.** F-1's issue (#1082) should carry an explicit enumeration
sub-bar: *"the uniform-`gen` binder set is `{top-level, impl method, default method,
prop/test body, let-group member, block-`let`, block-rec-`let`, inline rec-`let`,
`let`-body pattern binder}`, enumerated from the inference entry points rather than
sampled; each gets a fixture."* Without it, #1040 (a `where` group, on the covered path)
drains and #1043 (a block-`let`, on an uncovered path) does not — and #1043's build failure
would then be read as the emitter half, which is excluded.

### G-4 — A-2's key for method tables must be METHOD identity, not `(module, name)`

#1070's priority-2 remedy — adopted verbatim into A-2's scope — is *"`(module, name)`
keying for `universeMethodIfaceParamsRef`, `universeIfaceRequiredRef`,
`universeMethodDispatchIdxRef`"*. That is not sufficient. Two interfaces declared in the
**same** module that each declare a method `mth` still collide under a `(module, "mth")`
key, and `registerMethodIfaceParamsMethods` (`:15335`) inserts by `mname` per interface, so
the same last-write-wins applies within a module.

The correct key is the method's own identity, which necessarily includes its owning
interface: `(originModule, ifaceName, methodName)`. L2 already says identity is assigned
to "interfaces, interface methods" as separate namespaces, so the substrate supports it;
the risk is purely that A-2 implements #1070's literal wording. AGENTS.md's own registry
lesson states the same shape: *"prove the key is scoped (`<iface>@<slot>`, never a
program-global bare name)"*.

**Proposed plan change.** A-2 (#1111) should state the key shape per table rather than
inheriting `(module, name)` from #1070's body — the same way it already states that
#1070's priority-1 remedy is superseded.

### G-5 — L2 is worded over `String` keys; two confirmed defects key by something else

L2 reads: *"After the resolve phase, no component keys anything by a bare `String` name."*
The registry ratchet in §2's cross-cutting substrate makes it mechanical: *"A bare-`String`
key fails the check."*

Two of the defects in this ledger key by something that is **not a `String`** and would
pass that check unchanged:

- **`activeDictVars : Ref (List (Int, String))`** (`:3139`) — the `assum` rung's evidence
  environment, keyed by a bare **tyvar id**, with no interface component. This is
  #1127's leg 2, and it is in **neither** #993's blast list ("`Value` rep, `Route`, both
  emitters, dict-arity readers") **nor** #1113's ("`keyForSite*`, `KeyBuckets`,
  `implEntryRouteWords`, `noneHeadTag`, wasm, eval dispatch, `Route`/`core_ir_lower`, the
  IR golden"). DICT §11's `assum` row already flags the property — *"keyed on the call
  site's enclosing binding's dict-variable name …, not on predicate identity"* — so the
  spec table saw it and the migration plan did not pick it up.
- **`(module, name)` for method tables** — a tuple, not a bare `String`, and still
  under-determining (G-4).

**Proposed plan change.** Restate L2's operative clause as a property of the key rather
than of its type, and widen the ratchet accordingly:

> **L2 (operative form).** Every table key is the resolved identity of the thing being
> keyed — for evidence environments, the **predicate** (interface identity + goal), not a
> tyvar id; for declaration tables, the declaration's `(originModule, …)` identity, not its
> spelling. The ratchet rejects any key that is not derived from an identity, whatever its
> representation type.

And add `activeDictVars` (and its readers `activeDictVarOf`, `activeDictVarForEncl`,
`firstDictForEncl`) to **B-1's** blast list, since B-1 is what makes the super-slot
degenerate case disappear.

### G-6 — the candidate-collection L1 fork (the #1128 change) — **ADOPTED into §2 K**

See #1128's row for the mechanism and the `univHeadless` reference implementation. This
is the highest-value change in this document, because B-2's frozen arg-tag admissibility
is computed against the same candidate set: an incomplete set turns a today-latent bug
into a *frozen, consumed-by-every-engine* wrong answer.

Landed in §2 K as **match-preservation**, not as a new law — L1 already forbids the
fork — together with the `pickMostSpecificEntry` sequencing constraint (land with or
after F-3).

### G-7 — #1020 is partially misclassified as engine-realization

§4 and §8 list **#1020** among the defects "architecture cannot drain", with the capture
ban holding "until the ENGINE fix lands". The wasm symptom is indeed an engine defect —
`emitMethodDispatchRef` has no default-synthesis arms and falls through to `unreachable`.
But #1020's own diagnosis names a cause that is **not** in the wasm backend:

- `lowerDeclImpl` (`compiler/ir/core_ir_lower.mdk:1267`) projects a `DImpl` to
  `map (lowerImplMethod …) methods` — **one entry per method the impl DEFINES**, so an
  impl that overrides only defaults lowers to **zero** `CImplEntry` and is invisible to
  every emitter table derived from the lowered entries;
- `fillImplDefaults` (`compiler/frontend/desugar.mdk:851`) would have filled them, but its
  own header (`:845-847`) says it is **same-module only**: *"sees just DInterface defaults
  co-located in this decl list — a user impl of a prelude interface in another module keeps
  using the fallback, as intended."*

So "what is this instance's method table?" is answered in four places — desugar
(same-module), `eval.mdk`'s untagged `defaultEntry` fallback (`:1888`), LLVM's
`emitDefaultDispatchChain`/`emitDispatchChainDefaulted`, and wasm's (absent) peer. That is
a textbook **L1** violation, and the design already brushes against it: B-2's blast list
calls out *"the disjoint default-tag word namespace (synthesized default-method arms exist
for receiver tags with no impl — do not collapse them into the instance namespace)"*.

**Proposed plan change.** Reclassify #1020 as **split**: the wasm dispatch arm stays
engine-realization; the *cause* — one judgment with four implementations — is an L1 item
that **A-3 (K)** should own.

⚠️ **The remedy is a per-method DISPOSITION, not a filled-in method table.** The first
version of this ledger proposed making IE's method table *complete* (defaults resolved
whole-graph). **Adversarial review broke that, and it was right:**

- §2 S requires **a disjoint word class for synthesized default arms, "which exist for
  receiver tags with no impl at all and must not be collapsed into the instance
  namespace"**. An instance-keyed *complete* table cannot express "no impl at all" — it
  erases the very distinction §2 S preserves, and DICT §5's arg-tag reasoning needs it.
- DICT §3's **W3 (method-scheme fidelity)** rule checks a default body **at the class
  head `C ā_C`, with `ā_C` held rigid** — *"or by the class's **default**, which is
  checked by this same rule (it is the class-provided impl, at the head `C ā_C` itself
  with `ā_C` also held rigid)"*. Filling defaults into instances checks the body at
  `C T̄` instead: a different judgment, not a completion.
- This is measured, not hypothetical. `fillImplDefaults`' own header
  (`compiler/frontend/desugar.mdk:840-870`) records what specializing defaults per-impl
  cost at **same-module** scale: an `Ord` *"unbound dict witness"* and a `Foldable`
  **SIGSEGV** (*"the tagged copy wasn't eta-expanded so a saturated call dropped the
  container and returned an unapplied PAP"*). Both are fixed; a whole-graph version
  re-opens the same surface at larger scale.

The non-conflicting shape: elaboration records, per `(instance, method)`, its
**disposition** — *supplied by this instance* | *inherited from the class default* —
as data in a namespace disjoint from instance identity. "The instance omits the method"
stays representable (it *is* a disposition), the default body remains one body checked
once at the class head, and each engine **reads** the disposition instead of inventing
an arm. That closes the fork without touching where any body is checked.

**Not adopted into the design** — unlike the §2 K and §2 E amendments, this one needs
owner adjudication, since it touches the default-arm namespace §2 S already legislates.

Leaving #1020 wholly on the exclusion list remains the invisible-work hazard: the list
says nothing can help it, so nobody revisits the part that a stage genuinely would.

### G-8 — arity / calling convention has no owner (the #1034 / #826 / #1101 class)

The exclusions for **#1034**, **#826** and **#1101** all **hold** at the instance level,
and I am not proposing to move any of them:

- **#1034** — `methodArgTys` (`core_ir_lower.mdk:1382-1386`) walks the whole arrow spine
  (`methodArgTys (TyFun a b) = a :: methodArgTys b`), so a method whose result type is
  itself a function is over-counted. §4's justification is exactly right: `a -> (Unit ->
  Unit)` and `a -> Unit -> Unit` are the same `Ty`, so **the over-count is not recoverable
  from the type**, and no identity or selection work touches it. ✅ holds.
- **#826** — same root distortion, different failure mode (define-vs-call-site arity
  disagreement → LLVM prototype mismatch → SIGSEGV). ✅ holds.
- **#1101** — a direct 2-argument call against a 1-parameter `define`, silently legal under
  LLVM's opaque-pointer model. Pure emit. ✅ holds.
- **#1043's emitter half** — an unlocated, uncoded, wrong-cause `E-PANIC`. ✅ holds.

**But the class has no owner, and this is the ONE genuine absence from the output
contract.** Method arity is derived independently by at least three consumers:
`eval.mdk`'s `implMethodValue` builds `VClosure env pats body` (`:1837`) from the **impl
clause's pattern count**; `methodArityOf` (`compiler/backend/emit_support.mdk:485`) reads
a table `methodIfaceTable` (`compiler/ir/core_ir_lower.mdk:1399`) builds from
`methodArgTys` (`:1382-1386`), i.e. from the **declared signature's whole arrow spine**;
and #826 is a third disagreement, define vs call site. Under **L1** — *"consume, never
re-derive … extends to every derived artifact of a decision"* — that is three
implementations of one judgment. §2 E's output contract listed *"the typed,
dict-explicit, route-stamped AST"* and *"evidence references and frozen admissibility
data"*. **Arity and calling convention were not in it.**

**Plan change — ADOPTED into §2 E (2026-07-30).** The output carries, per binding and
per method, its arity and calling convention (leading dict-param count and order per
DICT §8 I1, source arity, eta-expansion target) as data; no engine derives arity from a
clause pattern count or from a declared signature. That does **not** fix #1034 — the
over-count still needs one correction in the lowering, and `a -> (Unit -> Unit)` /
`a -> Unit -> Unit` remain the same `Ty`, which is why the exclusion holds — but it
removes the substrate that keeps regrowing the class, and it makes #826's "make the two
arity oracles agree" a structural property rather than the patch #1034 already proved
insufficient.

🚨 **The amendment ships with a MANDATORY hand-derived conformance fixture, and the
reason is a severity trap, not hygiene.** #1034 was findable **only because the engines
disagreed** — eval right, native wrong, a divergence `diff_compiler_engines` could show.
Centralizing arity makes both engines consume the *same* arity, so a wrong centralized
arity becomes a **unanimity no differential can structurally see** — #1047's failure
mode exactly. Removing the only signal that found this class, without replacing it with
an oracle derived by hand from the clause, converts a visible divergence into silent
wrongness: a severity increase disguised as a consolidation. The fixture is the
replacement signal.

### G-9 — L2's operative clause is about KEYS; the value restriction's head test keys nothing

Added 2026-07-31 with issue 1150's row. It is Shape 2 (a provenance gap L2 does not
reach) taken one step further than G-4/G-5: those key by something that is not a bare
`String`; this **keys nothing at all**.

```
compiler/types/typecheck.mdk:3618   isCtorAppSpine (EVar name) = name /= "Ref" && ctorHeadIsUpper name
compiler/types/typecheck.mdk:3624   ctorHeadIsUpper name =
compiler/types/typecheck.mdk:3626     let cs = stringToChars name
compiler/types/typecheck.mdk:3627     arrayLength cs > 0 && isUpper (arrayGetUnsafe 0 cs)
```

`ctorHeadIsUpper` reads character 0 of a name to decide whether an application head is a
data constructor. There is no table, so:

- L2's **operative** clause — *"After the resolve phase, no component keys anything by a
  bare `String` name"* — is silent on it;
- the registry ratchet built from that clause (*"A bare-`String` key fails the check"*)
  passes it unchanged, as does G-5's proposed provenance restatement, which is still
  quantified over *table keys*;
- L2's **headline** — *"Identity is resolved, never re-derived from spelling"* — names
  the defect exactly.

That gap between the headline and the operative clause is the whole finding, and it is
the same failure mode G-5 records: the law is enforceable only over the shape someone
happened to write the ratchet for.

**Proposed plan change (two parts, both small).**

1. **Widen L2's operative form past keying.** G-5 already proposes *"every table key is
   the resolved identity of the thing being keyed"*; extend the quantifier:

   > **L2 (operative form).** No component after resolve answers a question about a
   > name's *identity or namespace* — which module it came from, whether it is a
   > constructor, which interface owns it — from the name's **spelling**, whether that
   > answer is used as a table key, a predicate, or a branch condition. Keys are one
   > instance; this predicate is another.

   The ratchet then has something mechanical to check for beyond key types: a
   `String`-inspecting predicate on a resolved occurrence.

2. **Name the consumer in A-1's deliverable.** A-1's collision surface (§6 A-1) lists
   producers of identity and the golden families that move; it does not enumerate the
   **consumers** that must be switched over. The value restriction's head arms
   (`isCtorAppSpine`, `:3618-3619`) are one, and they are not reachable from any table
   audit. Without an explicit consumer clause, A-1 lands whole and issue 1150 is
   untouched — the #1128/G-6 shape.

⚠️ **The consumer switch is not local, and that is what makes the cheap patch
attractive** (`typecheck.mdk:3556-3561`): `isNonexpansive:3567`, `isCtorAppSpine:3614`,
`clausesAreValue:9396`, `memberClauseIsValue:16063` and `sccSchemes:16054` all take no
`TcEnv` today. Whatever A-1 carries identity *in* has to reach the expression node, not
an environment — which is an argument for A-1's "AST carries origin" shape and against
answering the question from any environment at all.

### G-10 — no stage owns "a dict slot becomes a predicate" (the #1161 class)

Added 2026-07-31 with #1161's row. **Shape 1b**: an L1 fork with **no** complete
reference implementation, so the remedy is to build one and decide its contract, not to
adopt a working copy. Three producers answer *"what predicate does this
binding's `=>` context state?"*, each lossy in its own way —
`constraintTyVars`/`tyVarArgNames` (`:16040-16047`) keeps one entry per type **variable**
and silently drops a concrete argument; `constraintArgMono` (`:16460-16463`) drops the
**whole** predicate if any argument is not a plain tyvar, which `declaredSchemeOblsFor`
(`:16434-16445`) inherits; `recordSigConstraintObls` (`:7584-7593`) is genuinely n-ary but
applies the same all-or-nothing drop and is reachable from one caller only (`:7559`).

**The plan has no task that REPAIRS it.** `#607` — which `recordCallObligations`' own
comment names as the owner (*"the dict-slot=predicate change (#607 punch-list item 3),
which moves emitted arity and is deliberately NOT done here"*) — appears **zero times** in
`TYPECHECK-TARGET-ARCHITECTURE.md` and zero times in this ledger. §2 I unifies the
obligation channel's *storage* (already n-ary); §2's `#994` bullet fuses
`funConstraints`+`Ifaces` while preserving the one-slot-per-tyvar cardinality; §2 S and
§2 K quantify over a goal `C τ̄` without ever saying who builds `τ̄`. **§2 E's arity clause
is the one exception and it is a detector, not a repair** — it mandates a hand-derived
arity conformance fixture, which at a ≥2-variable predicate reds until this gap closes.

**It is also already non-conformant to a landed clause**, which makes it an **L5** item and
not only a migration hole: §4 `gen-sig` normatively writes
`d̄_sig = (d₁:π₁)…(dₖ:πₖ), {π₁..πₖ} = Q_sig` (`docs/spec/DICT-SEMANTICS.md:463-465`) — one
dict param per **predicate** — while the implementation abstracts one per **variable**.
§11's `§4 gen-sig` row (`:1620`) names only the coverage half and carries no 🔴; the
arity producer has no site there at all. That §11 row is owed, and is **not** edited from
this ledger.

**Two proposed plan changes, and the first is the urgent one.**

1. **Order G-10 before or with G-8's §2 E amendment (#1137) — because #1137 is BLOCKED BY
   G-10, not a freezer of it.** ⚠️ This entry previously said the amendment *"would publish
   the shattered granularity as a calling convention"*. **A conformant #1137 cannot**: §2 E
   cites DICT §8 I1, which makes the params' *"count, order, and predicates"* part of the
   elaborated type (`:1319-1321`) and cites §4 `gen`; and `gen-sig` gives one param per
   predicate. Publishing 2 for `Ix a i =>` would contradict the clause #1137 is
   implementing, and §2 E's mandatory hand-derived fixture is what makes that visible.

   The real hazard is an implementer one: **seeing the mandated fixture red and "deriving"
   the expected value from `dictArityOf` (2) rather than from §4 `gen-sig` (1)** — the
   capture-ban failure reached through a fixture instead of a golden. So the guard #1137
   must carry:

   > #1137's arity conformance fixture **must** include a ≥2-variable predicate
   > (`Ix a i =>`), and its expected value **must** be hand-derived from
   > `docs/spec/DICT-SEMANTICS.md` §4 `gen-sig`, never read off the implementation.
   > **It will red until G-10 lands. Do not weaken it to match.**

   G-8's own severity warning still applies, one level up — it is stated there about a
   wrong arity **value** and holds equally for a wrong arity **unit** — but the ordering
   conclusion now rests on #1137 being unable to go green honestly, not on it freezing
   anything.
2. **Name the producers, as a SET, in whichever task takes it.** This is G-2's lesson
   applied one subsystem over: a deliverable phrased as *"thread the predicate vector"*
   will reach `recordCallObligations` (the site with the comment) and miss
   `constraintTyVars`, which is where the argument is actually discarded — and a fix at
   the call site cannot recover an argument the signature reader already threw away.

⚠️ **Cross-gap note.** G-10 and G-6 are the two halves of one sentence in §2 K/§2 S: G-6 is
*"the candidate set for a goal `C τ̄` must be complete"*, G-10 is *"`τ̄` must be the
predicate"*. Landing either alone leaves the selector answering a well-posed question about
the wrong input, or the wrong question about the right input. Both feed
`pickMostSpecificEntry`'s silent first-match arm, so **both** carry the same
land-with-or-after-F-3 constraint — and G-10 additionally carries the inverse constraint
that F-3c must not land before **it** (see #1161's row).

### G-11 — coherence's input set is a fourth collection of the instance universe, and no task names it

Added 2026-07-31 with #1162's row. **Shape 1b** — like G-7 and G-10, no complete copy
exists to adopt. "What is the instance universe?" is collected four ways: `buildKeyTable implDecls` (`:9586`, `:18794`) and the
`ImplUniverse`/`ImplBuckets` pair over prelude ++ user; `cohCollectImpls` (`:11381-11383`)
and `cohCollectModuleImpls` (`:11396-11399`) over user decls only. The narrow pair is
where coherence reads, and the wide pair is where the selector reads, so the check and the
decision disagree about what exists.

**The design's commitment is present and the migration's is not.** §2 G says *"All of this
runs over K's environments; none of it holds private registries"*, with coherence named in
the same paragraph's first clause, and §2 K hosts the declaration-time overlap diagnostic
on `IE`. But §6 A-3's scope is *"Build CE/IE/DataEnv once; the **Module path** reads K"* —
it enumerates producers and the marshalling shim, and names no consumer to relocate. So
A-3 can land a whole-graph `IE` and `checkCoherence` keep reading its `userDecls`
parameter unchanged. That is the #1128/G-6 shape and the G-9 shape: **the substrate lands,
the incomplete consumer is not named, the defect survives.**

**Proposed plan change.** A-3 (#1112) should carry an explicit consumer clause naming
`checkCoherence`'s `userDecls` parameter, `runFinalChecks`' `cohDecls` argument
(`:11227`), `driverState.value.coherenceUserDecls` (`:11430`) and `globalCoherenceConflict`
(`:11418-11420`) as reads that move onto `IE` — the same form G-9 asks of A-1.

⚠️ **The exemption those four implement is justified by a behaviour that does not exist,
and A-3 should not preserve it unexamined.** `cohCollectModuleImpls`' header excludes the
prelude because *"a user `impl Eq Int` legitimately overrides the prelude one"*; on the
current binary that override does not happen (#1162's row records the three probes,
including the comment's own `Eq Int` example, all accepted at exit 0 with the prelude impl
still winning on both engines). So relocating coherence onto `IE` does **not** break a
working feature; what it changes is that a today-silent dead impl becomes visible. §2 K's
own disposition — an advisory `(a)`-warning at the declaration, with acceptance decided
per-goal by C1(c) — is the shape that fits: the equal-head case warns, and the
⊑-incomparable case is rejected at the goal by F-3c. Whether the equal-head case should
instead be a hard reject, or the override implemented for real, is a language decision
this ledger does not take — it is recorded, with that question attached, in #1162's row
under *"The equal-head prelude-vs-user shape"*, which also states why that second symptom
gets **no gap number of its own**: G-11 already names the missing consumer relocation, and
a second number for one structural hole would double-count it.

---

## Not established

**None of the family rows.** Every row in families A–G and J reached a verdict.
**Two of the out-of-family rows deliberately do not**: **O-1 (#1139)** and
**O-2 (#1140)** are `NOT ESTABLISHED` for any DRAINED-BY claim — in both cases I can
state a mechanism for why no stage reaches the bug, which is a stronger result than a
missing verdict, but neither is retired into a stage. The two rows I came closest to leaving open
were #1125 (settled by the `headCollides` bimodality derivation — see its row for the
falsification that would move it back to engine-realization) and #1127 (settled by
grep-proving all three legs). Both carry an explicit "if this is still broken after the
stage, re-file as engine-realization" clause, which is the honest form of the residual
uncertainty rather than a hedge in the verdict column.

### ⚠️ Not every "falsifiable prediction" in this ledger is equally strong — added 2026-07-31

A verdict's prediction and its *gradeability* are separate properties, and presenting
them uniformly overstates the GAP rows. Three distinctions, applied to the two rows added
in the second addendum and worth applying to the rest when they are next revisited:

- **NULL vs POSITIVE.** A GAP row's prediction is typically *"no stage changes this"* —
  satisfied by a stage that does nothing, **including a broken one**, and
  **one-directional**: an observed change refutes the GAP, but no amount of "unchanged"
  ever confirms a stage worked. #1161's, #819's, #817/#825's and O-1/O-2's are all null in
  this sense. **#1162's is positive** — a specific new diagnostic at a specific stage, with
  three named controls that must not move — and is the strongest prediction in the set.
- **EXECUTABLE vs PENDING.** A prediction keyed to an unmerged stage cannot be run today.
  #1161's two corollaries (F-3a, B-2) and #1162's main prediction (F-3c) are all pending.
  The one executable prediction added in the second addendum is #1137's arity conformance
  fixture, which must **red on the current binary** — checkable the day it is written.
- **DETECTOR vs REPAIR.** A stage whose artifact would *reveal* a defect (§2 E's mandated
  arity fixture, for G-10) is not a stage that drains it. Saying so explicitly is what
  keeps a GAP verdict honest when a stage does in fact touch the area.

---

## Third addendum — 2026-08-05: tracker-level re-adjudication of the post-#1162 population

**Provenance and evidence bar, stated first because it differs from the rest of this
ledger.** Derived at `main` = `c0c67f15` (2026-08-05), as part of a three-track
architecture audit (PR-conformance sweep · S0/S1 mapping · forward-plan review). Verdicts
below come from issue bodies, stage states, merged-PR contents, and source greps at that
commit. **Behavioural claims were NOT re-run on a cold-built binary** (unlike the first
and second addenda), except the single grep-checkable one noted at #1150. Rows marked
*inference* are hypotheses for a scoping pass with a binary, not findings — the
distinction this repo's methodology comments keep having to restate. The adjudication of
record is the set of 2026-08-05 comments posted on each issue; this section is the
ledger's index of them.

| Bug | Verdict | Stage / owner | Evidence bar |
|---|---|---|---|
| #1169 multi-param `requires` reads the wrong dict slot | candidate member of **G-10 (#1318)** — slot mis-assignment upstream of both engine symptoms | #1318 | inference, on-issue |
| #1174 (Int, Char) call vs bare-tyvar-head impl rejects a legal program | **unmapped** — plausibly the #1161 shattered-goal class (bare-TyVar head matches anything at `entryHeadMatches`' arg-0 fallback); adjudication owed | none yet; candidate #1318-class | inference, HERE only — no on-issue comment |
| #1177 predicate ORDER in a `=>` context decides dispatch | member of **G-10 (#1318)** — slot-per-tyvar cardinality is the mechanism | #1318 | inference, on-issue |
| #1180 undetermined constraint silently picks the concrete impl | **CANDIDATE member only** of #1318 — the named fix site (`implHeadTagForIface`) may make it S-lane selector work instead | #1318 (candidate) | adjudication owed, on-issue |
| #1182 two interfaces, one method name — `impl` block order decides | plausibly **A-3** (#1112): candidate collection keyed by interface identity in K's `IE` (`matchingEntries` keys by method name today) | A-3 (proposed) | inference, on-issue |
| #1183 ⊑-incomparable overlap at a non-closed goal commits with a warning | **deferred by owner decision** (F-3d record) — needs the T4 quiescence pass, i.e. **E-4** territory; the accepted cost is on the epic | E-4 (revisit condition) | adjudicated (owner decision) |
| #1191 prelude-standalone collision on the zero-import path | plausibly **E-1** (#1115) — the Flat arm's prelude concatenation; belongs in E-1's divergence enumeration | E-1 (proposed) | inference, on-issue |
| #1217 record pattern `...` lowered to a bare wildcard | **OUT OF ARC** — desugar/exhaust pattern lowering; no stage here touches it; routes via the frontend pipeline | none (out of arc) | adjudicated, on-issue |
| #1265 `CImplDefault` method-name half | **A-2 tail** — identity into the default's *symbol*; adjudicated in the A-2 handoff | A-2 (#1111) | adjudicated (handoff) |
| #1276 alias-qualified method provenance erased before the method-scope table | **A-2 method-scope residual** — witness must survive `renameAliasedMethods`; PR #1296 proved it distinct from the drained #1272/#1275 | A-2 (#1111) | adjudicated (PR #1296) |
| #1279 absent origin bridges two identities | downstream of **#1280** — closes when supply closes | A-2 (#1111) / #1280 | adjudicated (on-issue + handoff) |
| #1283 overlay misses a re-exported member | member of **#1319** (constructor-namespace identity) | #1319 | adjudicated, on-issue |
| #1284 overlaid sibling out-ranks a by-name import | member of **#1319** | #1319 | adjudicated, on-issue |
| #1302 dependency's PRIVATE interface decides an importing module's obligation | A-2.5-witness fix **gated on an owed spec ruling** (S-2 mould — private-interface visibility); ruling before fix | A-2 (#1111), spec first | adjudicated, on-issue |

**Also in the audited population but already family rows above:** #1150 (family A — the
G-9 consumer clause is still live: `isCtorAppSpine` classifies via `ctorHeadIsUpper` at
`c0c67f15`, verified by grep; the A-1/A-2 substrate landed and the consumer never moved —
recorded on #1150 with the owed conformance fixture), #1161 (family B — its residual is
now owned by #1318), #1162 (family J — G-11's declaration-time half adopted onto A-3's
blast list via the #1112 comment).

**Gap-ownership delta since the second addendum:**

- **G-10 → #1318 filed.** Members #1161 (residual) and #1177; candidates #1169, #1180,
  and (from this table) #1174. ⚠️ **Two rationales for the #1137 coupling are now on
  record and the ORDERING is the same under both**: the epic's 2026-07-31 form ("the full
  fix moves the leading dict-param count §2 E freezes") and this ledger's revised form
  above (a *conformant* §2 E cannot freeze the shattering — DICT §4 `gen-sig` gives one
  dict param per predicate — but **#1137's mandated arity conformance fixture cannot
  honestly go green until G-10 lands**). #1318's body carries the epic's form; the
  refinement is recorded there by comment. Either way: G-10 before or with #1137.
- **G-9 → recorded on #1150** (see above). **G-11 → A-3 blast list** (#1112 comment).
- **G-1 (#1136) → proposed Stage C sibling of C-2 (#830).** **G-8 (#1137) → proposed
  E-lane.** Both are proposals for the lane scoping passes, posted on-issue; both issues
  had zero movement since being filed as ownerless on 2026-07-30.
- **G-7's #1020 split → adopted onto A-3's scope** (#1112 comment) — proposed on the epic
  2026-07-30, half-adopted until now.

**Family notes.** Family A's residue has changed character: after A-2's thirteen PRs the
open members are no longer bare-name *tables* but witness/overlay *edge cases* (#1276
alias, #1283 re-export, #1284 ranking, #1302 private) — each landed widening moved the
boundary one hop out, which is why **#1319** exists (key the constructor namespace by
declaration identity end-to-end; retire the overlay) and why **#1317** exists (the
dispatch-key demand half, previously prose-only). Family B has **split**: key granularity
(B-1/B-2, owned) vs predicate loss at the producers (G-10/#1318) — a fourth root cause
that postdates #1084's "3 root causes + 1 arc" framing; #1084 is flagged for
re-derivation. **Exclusion re-audit:** the §4 list holds; **#1292** (`ctorToTypeRef`
runtime-tag collision, filed by A-2.7) is a new engine-realization candidate with a
◇B-2 marker — B-2 removes the *path* to the tag fallback, the tag substrate itself is
engine work.

**What this addendum does not do.** It does not rewrite the family sections in this
ledger's full row format (mechanism + falsifiable prediction, derived on a cold build)
for the fourteen bugs above — that bar is owed at each owning unit's scoping pass, and
pretending this table meets it would be the exact overstatement the Not-established
section warns about. The NULL-vs-POSITIVE / EXECUTABLE-vs-PENDING / DETECTOR-vs-REPAIR
distinctions of 2026-07-31 apply to every prediction referenced here.

---

## References

- [`TYPECHECK-TARGET-ARCHITECTURE.md`](TYPECHECK-TARGET-ARCHITECTURE.md) — the design (authority)
- [`TYPECHECK-ARCHITECTURE.md`](TYPECHECK-ARCHITECTURE.md) — the derived map
- [`../docs/spec/DICT-SEMANTICS.md`](../docs/spec/DICT-SEMANTICS.md) §11, [`../docs/spec/EFFECTS-SEMANTICS.md`](../docs/spec/EFFECTS-SEMANTICS.md) §11 — per-clause enforcement tables (clause → site → keying assumption)
- Epic **#1122** — stage table and dependency spine
- `.claude/workstreams/TYPECHECK.md` — the standing gate
