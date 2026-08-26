# Workstream: TYPECHECK

**Owns:** the consolidation arc for `compiler/types/typecheck.mdk` — dict-elaboration dedupe, the
entailment engine, driver/entry-point unification, state discipline, and the file's scaling
liabilities.
**Touches:** `compiler/types/typecheck.mdk` (almost exclusively), `compiler/driver/diagnostics.mdk`,
`test/diff_compiler_perf_scaling.sh`.

```sh
gh issue list --label "ws:typecheck" --state open   # the backlog. #160 is the tracking issue + DAG.
```

**Load the `harden-typechecker` skill before you start.** It carries the API surface (the
`pushTypeError` family, level bracketing, the value restriction, the two-entry-point table, the
coherence prelude-exclusion rule). This file carries only what the consolidation arc adds on top.

---

## 🚦 Standing gate: six questions before fixing ANY typechecker bug

This is keyed to the **`ws:typecheck` label, not to a skill**, and it fires first because it
gates everything else in this file. `harden-typechecker` is narrower than it looks — a fix that
threads through resolve/eval/desugar routes to `add-language-feature` instead (`AGENTS.md`), and
a gate parked in a skill would silently miss that fix. Keying it to the label instead of a skill
closes that gap.

**Before fixing ANY typechecker bug, answer these six questions IN WRITING on the issue or PR:**

1. Does this bug represent an **architectural issue** or simply an **implementation gap**?
2. Is there a **formal semantics** outlining the way this should behave? If yes, why aren't we
   following it? If no, why not?
3. Can this bug be fixed by making a **larger, more principled fix** to the surrounding
   typechecker machinery?
4. Are there **adjacent bugs** that we can find or have already filed near this one? If yes, is
   there a **single fix that resolves the entire class**?
5. What is the **most ideal principled way** to resolve this bug so that the typechecker becomes
   more robust and properly architected?
6. **If the fix WIDENS acceptance** (turns a reject into an accept — drains a false-REJECT
   diagnostic), what was the reject keeping programs AWAY from downstream, and have you taken
   newly-accepted programs all the way to the **built binary, executed** — not `check`, not `run`?

**Why this exists.** `compiler/types/typecheck.mdk` is the most fragile, highest-consequence file
in the tree, and its bug history is dominated by fixes that *relocated* a defect rather than
removing it:

- **#1044 was created by #1007.** #1007 fixed a real def-site omission by re-keying impl-method
  heads through `nsTy` instead of `nsMethod` — the right handle, but `nsTy` has the same
  one-slot-per-name property `nsMethod` had, so an imported *type* sharing the interface's name
  now steals the slot (#1044). #1070's audit calls this out by name: *"relocating the lookup is
  not a fix."*
- **#674's fix covered only ONE import spelling, and widening it moved the boundary rather
  than removing it.** The original patch matched the member's spelling against the `(..)`
  import flag instead of fixing the underlying bare-name keying, so `import amod.{A1(..)}`
  resolved correctly while `import amod.{A1, Dup}` got the wrong type (#1070). #1111 A-2.6
  widened the rule to any member that *names a constructor* (`memberOverlayDecl`) and scoped
  the pool lookup by declaration identity (`declOwnedBy`), which genuinely drained #1256 and
  #1259 — **and the same shape immediately reappeared one hop out**, through a re-export
  (`export import armod.{Cfg}`), where the decl's origin names the *declaring* module and the
  import path names the *re-exporter*, so the identity test misses (#1283). Widening a
  spelling-matched rule is still not the same as keying the table correctly.
  ⚠️ A-2.6 also shows the cost of getting the *layering* wrong while the keying is right: its
  first cut registered the import overlay **after** the module's own `prog0`, so an imported
  decl's constructors out-ranked locally-declared ones and `import json.{Json, JNull}` plus a
  local `data Tok = JString String` was rejected. Ask of any per-module overlay not only
  *"is the key scoped?"* but *"what does it out-rank, and should it?"*.
- **The P0-9 cross-module constructor fix patched `compiler/eval/eval.mdk` and left its parallel
  driver `compiler/ir/core_ir_eval.mdk` broken for months** — documented in `AGENTS.md`'s
  `evalModules`/`cevalModules` trap.
- **#1381 (issue #1319 unit 3) drained a false REJECT and created #1382 (S0) + #1383 (S1).** The
  front end became identity-correct for a record-namespace collision (`Type mismatch: Cfg vs Cfg`
  no longer fires on legal programs) — every gate green: 29-gate preflight, `selfproc` 16 ok,
  `engines` 528/0, `must_fail` 69/69, LEG A additive-only, CI 12/12. The back end still resolves
  field layout by **bare name**, and `inferFieldAccess` (`compiler/types/typecheck.mdk:6440`)
  `setRef`s the receiver's *unmangled* head name onto the AST node the emitter reads. Before the
  fix, the selected `RecordInfo` **was** `lookupRecordByName r` — key and stamp agreed by
  construction. After it, they can name different records: `check` 0, `medaka run` correct,
  **built binary silently wrong** (plus a segfault variant and a destructive-write variant).
  `diff_compiler_engines` would have redded instantly — eval and native resolve fields by name at
  *run time*, so they're structurally immune to the layout bug and would have disagreed. It
  didn't catch this because the new fixtures gave the colliding records single fields, so both
  layouts picked index 0 and the wrong pick was unobservable: **the gate existed, the input
  didn't.** Loud → silent is a severity increase even though the old behavior (a spurious reject)
  was also wrong — see `AGENTS.md`'s "fix that makes a defect QUIETER" section, of which this is
  a typecheck-specific instance.

**Application notes:**

- **Write the answers into the issue/PR body.** Unwritten answers become a ritual that gets
  nodded through; written ones are reviewable at adversarial review, which is already mandatory
  for S0 fixes.
- **The implementing agent must not self-grade.** It will rationalise toward the small fix it
  already wants to make. The adversarial reviewer checks the answers, not the author.
- **Concrete discriminator for questions 1 and 3:** does the fix change the KEY or the
  REPRESENTATION, or does it merely add a guard at ONE READ SITE? The second masquerading as the
  first is this file's signature failure mode.
- **Concrete discriminator for question 6 — does typecheck now DECIDE by a richer key than the
  one it STAMPS into the AST?** If the fix makes typecheck's *decision* sharper (e.g. resolve a
  collision by full module-qualified identity) but the value it writes into a `Ref`/annotation
  for a later stage to read is still the old, coarser key (e.g. the bare unmangled name), the
  stamp is stale by construction and front end/back end now disagree on cases the old, coarser
  decision made unreachable. Grep every `Ref`/annotation write the changed function makes and
  check its key matches the one just used to decide. ⚠️ **A write has TWO spellings** — `r := v`
  and `setRef r v` — so grepping only `setRef` MISSES most of them (typecheck.mdk is now
  overwhelmingly `:=`; the `setRef` residue is the multi-line calls of #1744). Grep both, or grep
  the target field name.
- **Question 6's verification checklist, concretely:**
  - Take newly-accepted programs to `medaka build` and **execute the binary**. `medaka run` and
    `medaka build` typecheck with the same binary and share the whole front end (`AGENTS.md`), so
    they are not two independent observations of anything at or before typecheck — only the
    built binary exercises the back end's read of the stamp.
  - Treat the new SOMETHING as **untested by construction**: every pre-existing fixture covered
    the reject (empty/absent) case, so no existing fixture can fail on a wrong new accept. Build
    the test from the spec, not from the diff or from coverage.
  - Check whether your new fixtures can even **express** the failure. A collision fixture with
    single-field records can't show a field-order bug — both layouts pick index 0. Prefer
    fixtures with ≥2 differently-ordered fields per colliding shape.
  - `eval`/`run` agreeing with native is **not** corroboration for a back-end-only defect: a
    tree-walker can be structurally immune to a bug that only a compiled representation exposes
    (here, both resolve fields by name at run time) — a known-wrong oracle in the *reassuring*
    direction, not just the usual wrong-in-the-alarming direction.
  - Permute what the mechanism actually reads, not what's convenient — #1381's order-dependence
    was on module-name **sort** order, not import-clause order, so a permutation differential
    over import clauses would have found nothing.
- **Question 2 has a real answer path.** Medaka has formal specs for several subsystems —
  `docs/spec/DICT-SEMANTICS.md`, `docs/spec/EFFECTS-SEMANTICS.md`, `docs/spec/SHADOW-SEMANTICS.md`,
  `docs/spec/LAYOUT-SEMANTICS.md`. "No formal semantics exists" is therefore a **finding**, not an
  excuse: the fix should come with one. PR #1093 (open) is the worked example — it specified
  declared type-parameter kinds before any implementation began.
- **Question 4 is the highest-yield.** Worked example: bare-`String`-keyed cross-module
  registries are ONE class — two filed separately (#1069, #1092), the rest recorded as audit rows
  in #1070 (still owed, per its own "Owed" section) — so the fix is not N patches. (An earlier
  draft of this bullet claimed all seven were filed separately — an encoded count nobody had
  derived against the tracker. Corrected in review; a fitting place for it, since an unverified
  count is exactly what this gate exists to catch.)
- **Accepted cost:** this slows S0 fixes, and there are roughly a dozen open. The owner judged it
  net-positive against a track record of fixes spawning adjacent bugs.

---

## Why this workstream exists

The HM core (levels + path-compressed union-find + value restriction) is excellent — do not
"improve" it. The problem is the layers around it: at the 2026-06-14 `compiler/ARCH-REVIEW.md`
deep-dive the file was 6,916 lines / 49 module-level `Ref`s; at `db33eeab` (2026-07-15) it is
13,717 lines / 97 `Ref`s. The growth is **parallel near-copies** — two orchestration bodies, five
final-check tails, four fold-over-modules loops, six impl-resolution paths, four operator-obligation
seams, binop/unop twins — each pair kept in agreement by nothing but manual mirror discipline.
That is the repo's #1 recurring bug shape (P0-9, the 2026-06-14 imported-module bug, #59).

The target shape is **already specified**: `docs/spec/DICT-SEMANTICS.md` (§3: entailment is ONE
function; §7: the single-evaluator law) and `compiler/ARCH-REVIEW.md` (consolidate + unify; the
HM-core/dispatch **file split was evaluated and rejected** — dispatch state is read at `infer`
depth across a 25-arm walk; do not relitigate it). This workstream is convergence to those two
documents, in gate-verified steps.

## The duplicate-family map (grep anchors, not line numbers)

| Family | Members |
|---|---|
| Orchestration bodies | `checkProgramSeededSplit` ∥ `checkModuleFullImpl` (#80) |
| Final-check tails ×5 | `checkToLines` / `checkToLinesWithRuntime` / `checkErrorsWithRuntime` / `checkProgramDiags` / `checkModuleFullDiags` (#152) |
| Module fold loops ×4 | ✅ LANDED (#151): unified into one `foldModules` (worker + isLast-aware collector) — the four drivers are now thin worker/collector pairs (`cmCheckWorker`/`cmDiagsWorker`/`cmEntryWorker`+`cmEntryCollect`/`elabWorker`); the three `check*` preambles share `checkModulesPreamble` |
| Impl resolution ×6 | `resolveSite`, `resolveOpSite` (the #145-unified binop/unop resolver), `routeOf` (already unifies what were three separate routeOfMono/routeOfMonoTop/routeOfMonoEncl arms), `findImplEntry`, arg-position mirrors (#156) |
| Structural matchers ×4 | `cohOverlap`'s unifier, `cohSubsumes`, `tySubsumesV`, `matchTyMono` (#156 stage 1) |
| Operator seams ×4 | LANDED #146 → collapsed to `recordIfaceObligation`/ifaceRegistered (the 12 clones `record{Num,Eq,Ord,Semigroup}Obligation` + `*IfaceRegistered` guards + `*Entry` predicates are retired). LANDED #147 → `methodIfaceParamsRef` is now an `OrdMap` keyed by method name + a cached registeredIfacesRef iface-name set; ifaceRegistered is `omHasKey` (the old ifaceEntryMatches full-scan predicate is retired). LANDED #1539 → the seam's gate is `builtinClassPresent`, a projection of the prelude-seeded `BuiltinClasses` record (DICT §8 I7 qual. 4), so no user-writable table decides whether an operator's obligation is synthesized; ifaceRegistered had no callers left and was deleted, leaving registeredIfacesRef write-only. LANDED #1569 → registeredIfacesRef / universeRegisteredIfacesRef and the ifaceRegistered tombstone ledger are removed entirely; the accumulator pair `insertMethodIfaceParams`/`insertIfaceMethodsAcc` fed collapses to a single map |
| Binop/unop twins ×4 pairs | ✅ LANDED (#145): collapsed into one `isBinop`-flagged set — `resolveOpSites`/`resolveOpSite`/`opDictVarOf`/`stampOpRouteVal` (a later extraction pulled the pure Route-returning core out of the original stampOpRoute into stampOpRouteVal) |

---

## ⚠️ THE TRAPS — read before your first PR here

### 1. The bar is BYTE-IDENTICAL, and two gates are non-negotiable
Every consolidation PR must show byte-identical goldens for the gates its diff touches, **plus**
`test/selfcompile_fixpoint.sh` (C3a/C3b YES) **plus** `test/typecheck_compiler_source.sh`. The last
one is not optional and not redundant: **the build does not gate on type errors** — an ill-typed
compiler builds green through all 80+ gates. It is also the *only* thing that catches a stale
caller after a signature change. The ONE deliberate exception to byte-identical was #157
(the emitArgStampPasses retirement — now landed), which moved the compiler self-snapshot
goldens (comment-only) and was blessed by named path.

### 2. ORDER IS SEMANTICS — the map-ification trap
The `List` scans you are replacing are not incidental: reverse-declaration-order scanning,
first-match lookup, and prepend-wins are **oracle-matching behavior**. They decide which coherence
conflict is reported first, which impl a collision site keys, and which cross-module arity wins.
An `OrdMap` rewrite that changes any of that will show up as golden drift in
`diff_compiler_typecheck_errors` / `diff_compiler_check*` — treat that drift as "I changed
semantics," never as "goldens need a refresh." Buckets must preserve the order the scan had.

### 3. The compiler's own source is in the snapshot corpus
Any edit to `typecheck.mdk` moves its own golden. **Bless it, by name, in the same commit** — or
`main` goes red and the next agent is forced to rubber-stamp your regression.

### 4. Mirror discipline is LIVE until the unification issues land
Until #151/#152/#80 merge, a change to one copy of a duplicated family is **silently absent** from
the others — and the miss is path-specific (LSP-only, emit-only), the hardest kind to notice.
Before pushing, grep every member of the family you touched (table above) and patch all of them.

### 5. Coherence must NEVER see seeded impls
`checkCoherence` runs over **user decls only** (`coherenceUserDecls`) — a user impl deliberately
overrides a seeded prelude impl. Feed the unified final-checks helper (#152) the seeded set and it
false-positives on the stdlib itself, breaking dozens of gates at once. Pass the decls explicitly;
no defaulting to the whole program.

### 6. Keep hot helpers monomorphic and short-circuiting
Do NOT "clean up" a hot scan by delegating to a prelude Foldable method — measured **+56%
self-compile** (`compiler/AGENTS.md`). The consolidated helpers in #145/#146 must stay
monomorphic `||`/`&&` loops or keyed lookups.

### 7. resetState survivors are load-bearing — clearing is not a cleanup
~37 Refs deliberately survive `resetState` (cross-module accumulators, per-module reseed tables,
driver mode flags). Clearing one "for hygiene" reproduces the Phase-134 dropped-dict mode. The
cross-module six get exactly ONE lifecycle owner via #143; everything else waits for #158's
two-record split (a per-run record vs a cross-run record — #158 mints the actual names; they do
not exist yet, so don't grep for them), where survive-vs-clear becomes type structure.
`typeErrorsSticky` stays OUTSIDE any bundle, permanently — it is sound *because* it lives outside
resets (ARCH-REVIEW hazard #1).

### 8. Effect rows are transparent in matching ON PURPOSE
Coherence, subsumption, and dispatch matching all ignore/strip `TEff` rows. That is the
single-meaning law (`docs/spec/EFFECTS-SEMANTICS.md` §8 — effects erase; they never participate in
dispatch), not an oversight. Do not "fix" it while unifying the matchers in #156.

### 9. Measurement discipline for the perf items
The scans this workstream removes are **pure traversals — they allocate nothing**, so the
allocation grade is physically blind to them; only per-stage TIME can see them (the #115 lesson).
Pin `GC_INITIAL_HEAP_SIZE`, take min-of-K, grade per stage — and remember `whenL False (…)` is NOT
a stub in a strict language; to stub a call, delete it. Full doctrine: `.claude/workstreams/PERF.md`
and the `perf-hunt` skill.

### 10. One compiler-source PR in flight; stage commits by path
Goldens are re-cut from source, never text-merged — two typecheck branches always fight over the
same golden files. And never `git add -A` (see `.claude/workstreams/HARNESS.md`).

### 11. "Will this key change fail SILENTLY?" has NO general answer — it depends on GATE vs PAYLOAD
Two arguments in this arc were built on *predicted silence*, and the prediction was backwards.

- A **GATE** table is consulted for **permission**. Its value is often `Unit`; a missed lookup means
  *the check vanishes* — genuinely silent. universeRegisteredIfacesRef / ifaceRegistered was one
  (#1539 deleted that reader; #1569 removed the write-only table itself. The gate it fed is now
  `builtinClassPresent`, and the same GATE-shaped hazard transfers to it verbatim — a presence bit
  that answers False switches every operator's obligation OFF and moves no golden).
- A **PAYLOAD** table is consulted for **content**. A missed lookup means *"no impl exists"* — which
  is a **reject**, i.e. deafening. `oblIfaceKey` / `ImplUniverse` is one.

Measured (2026-08-09, the P1 experiment on #1112): identity-keying `IE` while `Predicate` stayed bare
did **not** silently switch obligations off — it made them **universally unsatisfiable**. The prototype
compiler rejects its own prelude (`No impl of Eq for Int`), `make check-self` FAILS, and goldens moved
61/61 in a behaviour-driven corpus. `oblIfaceKey`'s own in-source ledger predicts the opposite polarity
and **owes a correction**; it reasoned from a gate-shaped sibling while describing a payload-shaped
table.

⚠️ The two can nest: `checkUndeterminedObligation`'s RULE 3 is guarded on `implCountForIfaceU >= 2`
with `| otherwise = ()`, so a missed count reads 0 and `T-AMBIGUOUS-INSTANCE` stops emitting — a
genuine gate-shaped sub-case **inside** the payload table, which is presumably how they got conflated.

**Before asserting a key change will be caught (or missed), classify the table.** And note the effect
can **partition by origin supply**: origin-carrying impls are written `TkIdent`, read `TkBare`, and
vanish, while flat-file user impls carry `OriginUnresolved`, stay `TkBare` on both sides, and are
unaffected — so a probe drawn only from the flat corpus reports "no effect."

### 12. Derive a table family by SHAPE, not by a NAMING CONVENTION
#1070's family is defined by a shape — *a flat table keyed by a bare `String`, populated across module
boundaries, last-write-wins, silent on loss*. Every issue in the arc enumerated it with a **prefix**
grep on `universe*`. Those are not the same set, and multiple "the set is complete" claims rest on the
prefix.

Re-derived 2026-08-09: **~20 shape-members sat outside both prefix greps**, in `types/`
(`DriverState`), `backend/`, `ir/` and `eval/` — including `argDispatchIdxRef` and the former
shared method-interface table/index Refs in `backend/emit_support.mdk`. X-N.H and X-W.H1 later
moved those method facts into backend input values, but the derivation lesson remains: a
`types/`-anchored enumeration structurally cannot reach backend members.

The leverage is that `OrdMap a = Map String a` (`compiler/support/ordmap.mdk`), so *bare-`String`-keyed*
is a **type** fact and therefore greppable. 🚨 **And the obvious shape grep is itself a trap:** anchoring
on `^ident :` silently drops every `export`-prefixed declaration — measured **65 rows anchored vs 75
prefixed**, and the missed rows included both former exported method-interface Refs. The derivation
that fixes a scope error can re-commit it one level down. Full command + graded table: the
2026-08-09 audit comment on #1070.

### 13. A FALSE REJECT can be LOAD-BEARING — draining one exposes what it was hiding
Three instances in one day (2026-08-09), which is why this is a trap and not a footnote:

- **#1424** — landing the re-export arm without the provenance filter propagated a poisoned row one hop
  and turned a legal 4-module program into a three-verb reject. The two halves were coupled *through
  the table*, not through the function they share; each is measured-unsafe alone, in opposite
  directions.
- **PR #1455 round 1** — draining #1383's false reject let collider-bearing programs reach a
  **pre-existing** layout bug: clean `check`, wrong built binary, and in one variant a **SIGSEGV**.
  Loud → silent, the severity increase the ladder warns about.
- **PR #1455's extension** — fixing that properly *narrowed the language* (`T-FIELD-VARIANT-CONFLICT`),
  and in doing so revealed that the arm-(a) spelling, both single-file spellings and the whole
  record-**update** path had been silently wrong at exit 0 all along.

**Ask of any accept-widening fix: what was this reject keeping programs AWAY from?** The answer is
often a defect nobody has met, because nothing could reach it. See the standing gate's Q6, and note
Q6 has an **inverse** for narrowing fixes: the hazard becomes false rejects on legal programs.

### 14. `MEDAKA_STRICT=1` makes a two-binary differential IMPOSSIBLE from one tree
The baseline binary hard-exits 1 on the staleness check, so every cell reads "fail" and the
differential looks catastrophic. An agent lost a cycle to this reading 15/15 cells as failures.

**Remedy:** extract a pristine tree with `git archive` and point `MEDAKA_ROOT` at it. Also confirm
`MEDAKA_ROOT` / `MEDAKA_EMITTER` are not exported in your shell — either one silently crosses the arms
(a binary resolves its emitter and stdlib from `exeDir`, which is what makes the comparison sound in
the first place; [D-TWO-ARM] in the `debug-pipeline` skill).

### 15. 🚨 A local `diff_compiler_engines` run is a TWO-engine population unless you set `MEDAKA_REQUIRE_WASM=1`
The wasm arm **silently degrades off** when its toolchain is unavailable — the gate still prints a
total and still exits 0. So a local *"exit 0, 541 clean, 0 regressions"* is a **T1-only** number that
reads exactly like three-engine coverage. CI grades three and reported 540 + **1 regression on the same
commit** — a different population, not a contradiction.

**This cost real certification error twice in one PR (#1455):**

1. An author reported engines green from a local run and pushed; CI redded on the cell they had just
   added.
2. Worse, and this is the one to remember: round 2 carved out an exemption — *"where all constructors
   place the field at the same offset the stamp is immaterial"* — and pinned a fixture (`pB`) as a
   working program the rule **must not break**. **On WasmGC that program already trapped**
   (`illegal cast`) at the merge base. The exemption is true of LLVM and **false of WasmGC**, because a
   record there is a `struct` type **per constructor**: the stamp names a TYPE and the access is a
   **cast**, so identical offsets are no protection at all. A two-engine measurement had certified a
   carve-out that blessed programs which trap on one of the two shipping backends.

**Rules:**
- **Always `MEDAKA_REQUIRE_WASM=1` before reporting an engines number**, and say in the PR body which
  invocation produced it. An unlabelled engines figure should be assumed two-engine.
- **A "must not move" row proven on two engines is not proven.** Before carving an exemption out of a
  correctness rule, check the carve-out against **all three** engines — the exemption is exactly where
  a backend-specific representation difference hides.
- **LLVM and WasmGC do not share a record representation.** Reasoning about field *offsets* is
  LLVM-shaped; WasmGC dispatches by struct type and cast. Any rule phrased in terms of offsets needs a
  wasm answer stated separately. This generalises past this arc — see `AGENTS.md`'s note that wasm was
  never wrong on the fallthrough class *because it already had the design LLVM lacked*.

---

## Sequencing

The DAG lives in **#160** (tracking). Shape: Phase 0 defects + the perf-scaling shapes (#143/#144/
#153) → Phase 1 mechanical dedupe + map-ification (#145–#150) → Phase 2 driver unification
(#151 → #152 → #80, then #154/#155) → Phase 3 entailment engine #156, then single-mode elaboration
#157 → Phase 4 state + diagnostics records (#158, #159). Phase boundaries are dependency edges,
not suggestions: #158 designed before #157 lands would be designed around a flag that is about to
vanish (ARCH-REVIEW made exactly this sequencing mistake once).

## Reading list

- `docs/spec/DICT-SEMANTICS.md` — the target semantics for #156/#157. §10 maps defect classes to clauses.
- `compiler/ARCH-REVIEW.md` — PASS 2 is the prior deep-dive; its file-split rejection and
  DispatchState design still govern #158.
- `compiler/TYPECHECK-AUDIT.md` — the 2026-06-09 oracle-diff audit; its executive-summary root
  pattern ("semantics keyed by incidental identity") is what #156 finally retires.
- `docs/spec/SHADOW-SEMANTICS.md` + `docs/spec/EFFECTS-SEMANTICS.md` — the other two behavior
  contracts this file implements; their gates are part of the byte-identical bar.
- `compiler/AGENTS.md` — the perf ground rules; `.claude/workstreams/PERF.md` — the measurement traps.
