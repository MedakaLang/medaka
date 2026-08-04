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

## 🚦 Standing gate: five questions before fixing ANY typechecker bug

This is keyed to the **`ws:typecheck` label, not to a skill**, and it fires first because it
gates everything else in this file. `harden-typechecker` is narrower than it looks — a fix that
threads through resolve/eval/desugar routes to `add-language-feature` instead (`AGENTS.md`), and
a gate parked in a skill would silently miss that fix. Keying it to the label instead of a skill
closes that gap.

**Before fixing ANY typechecker bug, answer these five questions IN WRITING on the issue or PR:**

1. Does this bug represent an **architectural issue** or simply an **implementation gap**?
2. Is there a **formal semantics** outlining the way this should behave? If yes, why aren't we
   following it? If no, why not?
3. Can this bug be fixed by making a **larger, more principled fix** to the surrounding
   typechecker machinery?
4. Are there **adjacent bugs** that we can find or have already filed near this one? If yes, is
   there a **single fix that resolves the entire class**?
5. What is the **most ideal principled way** to resolve this bug so that the typechecker becomes
   more robust and properly architected?

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

**Application notes:**

- **Write the answers into the issue/PR body.** Unwritten answers become a ritual that gets
  nodded through; written ones are reviewable at adversarial review, which is already mandatory
  for S0 fixes.
- **The implementing agent must not self-grade.** It will rationalise toward the small fix it
  already wants to make. The adversarial reviewer checks the answers, not the author.
- **Concrete discriminator for questions 1 and 3:** does the fix change the KEY or the
  REPRESENTATION, or does it merely add a guard at ONE READ SITE? The second masquerading as the
  first is this file's signature failure mode.
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
| Operator seams ×4 | LANDED #146 → collapsed to `recordIfaceObligation`/`ifaceRegistered` (the 12 clones `record{Num,Eq,Ord,Semigroup}Obligation` + `*IfaceRegistered` guards + `*Entry` predicates are retired). LANDED #147 → `methodIfaceParamsRef` is now an `OrdMap` keyed by method name + a cached `registeredIfacesRef` iface-name set; `ifaceRegistered` is `omHasKey` (the old ifaceEntryMatches full-scan predicate is retired) |
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
