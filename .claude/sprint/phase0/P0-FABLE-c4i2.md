# P0 Fable consult — does the cut still deliver C4/I2 by construction?

**Verdict: YES-BUT.** The claim survives this cut *as the epic states it* — Module-path-scoped,
riding entirely on A-3b — but it survives only under a precise reading, and one unit (A-3.6)
carries the whole thing. Two qualifications must travel with any "delivered" report.

---

## 1. What C4 and I2 are (quoted, DERIVED)

`docs/spec/DICT-SEMANTICS.md:1312-1315`:

> **C4 — Single instance environment.** `IE`/`CE` are *global* after import
> resolution (§8). Two modules resolving the same predicate must consult the
> same instance set and produce the same evidence — otherwise C1/C2 hold only
> locally and coherence fails across module boundaries.

`docs/spec/DICT-SEMANTICS.md:1881-1885`:

> **I2 — Global instance environment after import resolution.** Per C4, `IE`
> and `CE` are assembled across the whole import graph before entailment runs.
> Instance lookup in `inst` uses qualified instance identity; method projection
> uses the resolved class. Import scoping affects *visibility* of names, not the
> *identity* of the evidence a predicate resolves to.

And the arch doc's operationalization (`TYPECHECK-TARGET-ARCHITECTURE.md:280-283`, DERIVED):
import scoping is "a **visibility** filter applied at name resolution (R), never a candidacy
filter on instances."

## 2. What "by construction" means here (DERIVED from arch doc + ratchet)

Not "no test fails." The property is that the violating state becomes **inexpressible** in the
final tree (`TYPECHECK-TARGET-ARCHITECTURE.md:278-279`: when IE is one global environment,
*"the site's module didn't see the other impl" becomes inexpressible*). Concretely, three
structural facts of the final tree:

1. **One written copy** of "what impls exist" on the Module path — the `obUniv*` accumulators
   are *deleted from CrossRun*, not left unread (ratchet `deImpls` row: "two written copies of
   one table is exactly the divergence design law L1 removes"). **Landed** — A-3.4 PR2. DERIVED:
   the ratchet's `cross_allowed` no longer lists `obUnivConcreteRef`/`obUnivHeadlessRef`/
   `obUnivIfaceTagsRef`, and `ieUniverseAt` is the single read accessor.
2. **No per-module candidacy filter**: the ordinal projection dies. Today it is alive —
   `typecheck.mdk:2834-2835`: `declEnvVisibleAt cur entryOrd = entryOrd <= cur`, applied to IE
   by `ieSnapAt` (`typecheck.mdk:4080-4084`). So **C4/I2 is NOT yet true after A-3.4**: IE is
   globally *stored* but *prefix-projected at read*. A-3.6 is, verbatim (`typecheck.mdk:2832-2833`):
   "the deletion of this predicate's body (it becomes `True`) and nothing else." The publicity
   conjunct is deliberately separable and migrates to R per §3 L7 (`typecheck.mdk:2888-2896`) —
   that migration is exactly I2's "visibility of names" clause, so it is part of the claim, not
   a leak in it.
3. **Coherence consults the same environment** (A-3.7) — otherwise C1 is checked against a
   different instance set than `inst` resolves from, which is the "second answer" shape L1 bans.

The Flat promotion-fallback keeps the marshalling shim until E-4 — but the epic's own honest-scope
paragraph says so ("the **Module path** reads K"), so the claim was Module-path-scoped from the
start. RELAYED from #1112 body; consistent with the ratchet's "THE FLAT ARM DOES NOT READ THIS
FIELD" note.

## 3. Do the two acceptance deltas compromise it?

**Delta 1 — A-3.5c cycle-walk re-key (identity edges, private cycle roots): NO.** DERIVED: the
re-keyed walk (`checkInterfaceCycles` over `ceRowsVisibleAt`) is a decl-time *diagnostic* pass.
It touches no entailment, candidacy, or evidence path; its widenings are duplicate reports and
new W1 rejections of genuinely cyclic private interfaces. C4/I2 quantify over predicate
*resolution*; this delta cannot reach them.

**Delta 2 — the bare compatibility leg in `oblIfaceKeys`: NO, but this is the crux and the
required honesty line.** DERIVED from `typecheck.mdk:4086-4170` (the §9.7 assertions block) and
the ratchet's `deImpls` row: `ieInsertRow` mints TWO keys, and doctest 1b *asserts* that two
same-spelled interfaces in unrelated modules share the bare bucket (`listLen ... == 2`).

The reason this does not defeat C4/I2: the bare leg is still **one global, site-uniform**
environment. Every site consulting the bare key consults the *same* over-broad bucket — so C4's
sentence ("two modules resolving the same predicate must consult the same instance set and
produce the same evidence") holds; the wrongness is *uniform*. What the leg violates is
**identity** — which predicate a bare-keyed goal denotes — and that is **I4/P1's clause**
(`DICT-SEMANTICS.md:1893+`: identity is module-qualified in every namespace), a *different* spec
clause, pinned (#1438 → `must_fail_fixtures/1514-xmod-same-spelled-iface-impl-selection`,
DERIVED: claim.txt cites 1438) and assigned to #1482/#1507, not A-3. Scope collision ≠ table
collision: the identity leg IS a scope (doctest 1: each identity key resolves to exactly one
row); the bare leg is a deliberate, asserted, separately-owned residue.

**The BUT:** the claim that survives is "C4/I2 by construction on the Module path, modulo the
inherited #1438 identity collapse on the bare leg (I4's defect, #1482/#1507's drain)." A report
that says "IE is identity-keyed" unqualified, or "A-3 delivers coherent global dispatch," would
be over-claiming — a bare-keyed goal can still resolve through the collapsed bucket to an impl
of the *other* same-spelled interface, silently. The head half staying bare (#1317 T1) is fine:
it is an *index bucket*, admissible under the match-preservation rule
(`TYPECHECK-TARGET-ARCHITECTURE.md:289-297`) so long as the matcher discriminates — over-broad
buckets never drop a match, and re-keying it re-introduces closed S0 #1277. RELAYED (ruling) +
DERIVED (the rule's text).

## 4. Load-bearing unit and falsifier

**A-3.6.** Everything else is storage, relocation, or diagnostics; the spec property — candidacy
is graph-global, scoping filters only names — becomes true at exactly one edit: deleting
`declEnvVisibleAt`'s body as read through `ieSnapAt`.

**Cheapest falsifiers, in cost order:**
1. Structural, free: after A-3.6 "lands," `grep -n 'entryOrd <= cur'
   compiler/types/typecheck.mdk` still matching (or any reader open-coding an ordinal test —
   the ratchet warns A-3.6 must count THREE production readers of the predicate).
2. Behavioral, one must-fail run, no oracle build:
   `test/must_fail_fixtures/1072-overlap-xmod-bare-head-arm-order` — the pin's own note says
   graph-global candidacy flips `main.mdk`'s stdout to `specific` (control staying `specific`).
   **If that row does not flip red after A-3.6, the claim is false** — the "site's module didn't
   see the other impl" state is still expressible. DERIVED from `DICT-SEMANTICS.md` §8 I5
   class (3) and the fixture's cited note.

## 5. Risks specific to THIS cut (deferred verification)

"By construction" is a structural property, so deferring gates does not defeat it — but it
defers the *evidence*, and §8 I5's own text (DERIVED, lines ~1975-1990) says classes (1), (2)
and (4) of the candidacy flip are **unpinned in either direction**, and class (3) is a silent
answer change — precisely the failure the sprint doc admits its gate suite is blind to.
Two recommendations:

- **Make the 1072-pin flip an in-run checkpoint observation at the end of A-3.6**, not a
  testing-round item. It is one `sh` run of an existing fixture, blesses nothing, and is the
  single cheapest discriminator between "flip landed" and "a residual filter survived."
- **R2's could-not-pass-before fixture must be authored inside A-3.6's bite list** (the epic:
  "A-3's PR carries the could-not-pass-before fixture"), even if it is only *run* in the
  testing round. A-3.6 without it repeats the exact claim-without-subject defect the 2026-08-07
  spec repair documents.

**What would restore the claim if A-3.6 slips out of the cut:** nothing short of A-3.6. A-3.4 +
A-3.5 alone produce a tree with the *machinery* (global storage, single accessor) and not the
*guarantee* (candidacy still prefix-filtered) — reporting A-3 done on that tree is the
partial-identity mistake the epic's honesty clause names (#1354, one stage up). OWED until
A-3.6 lands: the property itself.
