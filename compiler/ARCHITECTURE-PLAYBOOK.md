# From here to there: the architecture playbook

**Status:** ADOPTED 2026-10-15 as the plan of record; Val ratified
[`ARCHITECTURE.md`](ARCHITECTURE.md) and ruled the decisions in §9. Tracking epic #4206. This is the sequencing plan
that takes the compiler from its measured state (§1) to the laws in that file. It does
not replace the typechecker epic (#1122), the emitter epic (#1398) or the run-once epic
(#4141); it orders work across them and adds the one phase none of them has, the guards
that stop the tree from drifting while the plan runs. Each phase ends with an exit
criterion that is a command, not a sentence.

**How to read an action.** Every action has an id, what it changes, the mechanism, an
acceptance check that can go red, a size, its dependencies and its owner issue. A size
is one of: *slice* (one sprint slice, one PR), *sprint* (one review's worth of slices, usually 3 to 5), *arc* (several
sprints under an existing epic).

**How this document is maintained.** When an action lands, its row gains a dated landing
line and its prose is cut to that line. When a phase's exit criterion is met, the phase
collapses to its criterion and date. Numbers in §1 rot; re-derive them with the listed
commands before citing them.

---

## 1. Where we are (measured 2026-10-21 at `17e977db4`, the end of Phase 2)

Re-derive with `make arch-census` and the census scripts archived with the evaluation at
`archive/findings/architecture-evaluation-2026-10-15/census/` (run as
`python3 -I census/census.py <repo-root> <section>`; `census-medaka.md` beside them
records the method and the full tables).

| Measure | Value |
|---|---|
| Compiler source, non-test | 183 modules, 217,929 lines; median 230, p90 2,249 |
| `types/typecheck.mdk` | 58,083 lines (33,730 code, 20,710 comment); 27% of the compiler; 60% of `types/` (`tc_types.mdk` holds 1,184 code lines of it since T1) |
| Its growth during Phase 2 | +2,733 code lines (30,997 to 33,730) under 33 `Arch-Growth-Override:` commits across ten sprints, each naming `types/tc_driver.mdk` or a Phase 4 leaf as the destination. T1 took −799; stage 6 (the threading) +2,848, of which 2,603 are parameters and `fmt` re-wraps and 95 net logic. About 10,000 lines a month before Phase 0; +400 during Phase 1 |
| Modules over 3,000 code lines | 8 (`test/arch_goldens/oversize.golden`, unchanged); 2 state a reason in their header (`frontend/resolve.mdk`, `tools/test_cmd.mdk`) |
| Module-level `= Ref` cells | 84 in 26 modules (`test/arch_goldens/cells.golden`; Phase 1 ended at 108 in 28); `types.typecheck` 4 (`interners` and the three memo refs) plus 196 fields in 13 records (`ModuleCells` 91, `GraphRun` 30, `GraphCtx` 19, `CrossRun` 14, `DynCtx` 10, `TraceSink` 8, `DriveInputs` 6, `TcConfig` 5, `ModuleCtx` 3, `Lineage` 3, `SiteCtx` 3, `Interners` 2, `GroupCtx` 2), every one a row of `types/CELL-LIFETIMES.md` |
| Import graph | 0 cycles, 3 layering violations (`layering.golden`, unchanged) |
| llvm_emit / wasm_emit twins | 93 named pairs (`twins.golden`, unchanged) |
| Identical bodies in 2+ modules | 0 (pinned empty by `dupbodies.golden`) |
| `lookupAssoc` call sites | 225 in compiler modules, 134 in typecheck (Phase 1 end: 223 and 105; the records' mint, copy and restore paths added the 29) |
| Prelude cost | callgrind of `check hello.mdk` at `17e977db4`: 392M Ir in all; the typecheck drive 285M (73%), of which the prelude's core pass (`checkCoreMemoized`) is 247M (63% of the process); load and parse about 89M (23%). `typecheck.module` is 2 on every verb's hello probe (`stage_counts.golden`) |
| CPU per verb, Phase 1 end to Phase 2 end | unchanged within noise: hello `check`/`run`/`build` 0.07/0.07/0.42 s to 0.06/0.08/0.48 s; a value `main` 0.07/0.07/0.45 s to 0.07/0.07/0.48 s; `test stdlib/list.mdk` 1.32 s to 1.19 s; `check` of the CLI graph 17.3 s to 17.9 s on the same source tree (each binary on each tree, median of 3, user+sys) |
| Design docs in `compiler/` | 21 files, 19,672 lines (the keep list) |

Open milestones this plan draws on (2026-10-21): M-PUBLISH (1 open), M-PIPELINE (1),
M-CACHE (4), M-BOUNDARIES (3), M-IDENTITY (11); run-once O2 (2), O3 (2), O4 (8), O5 (5).
The Phase 1 and Phase 2 milestones are still open with 3 and 5 issues each (§3, §4).

---

## 2. Phase 0: guards (no behaviour change) — met 2026-10-15

**Exit criterion, met 2026-10-15** (epic #4206, PRs #4215, #4221, #4222, #4226):
`types/typecheck.mdk` is no larger than at the phase's start (30,597 code lines against a
floor of 30,609); the G3 boundaries test is green and enrolled; `compiler/*.md` holds
only current maps, destinations, this playbook and `AGENTS.md`, exactly the keep list.
The guards now run in CI: `test/arch_ratchet.sh`, `test/arch_boundaries_test.mdk` and
`test/stage_counts_test.mdk`, with their goldens under `test/arch_goldens/`.

| Id | Action | Landed |
|---|---|---|
| **G1** | Growth ratchet on `types/typecheck.mdk` | 2026-10-15 (P0-D1, P0-D2): `test/arch_ratchet.sh`, delta against the PR base with no committed baseline; the override is a commit trailer, not a PR-body line. #4200, PR #4215. |
| **G2a** | Close the `private_mangle` layering violations | 2026-10-15 (P0-D6): the whole module moved to `types/`; layering violations 7 to 3. #4201, PR #4215. |
| **G2b** | The hooks record | 2026-10-15 (P0-D3, P0-D4): `compiler/support/hooks.mdk` carries the contract and `hookUnset`, no record yet; the import rule and the field-count pin are in `test/arch_boundaries_test.mdk`. #4202, PR #4215. |
| **G3** | Architecture goldens | 2026-10-15 (P0-D3, P0-D7, P0-D8): `test/arch_boundaries_test.mdk` pins layering, cells, hooks fields, three closures, twins, identical bodies and declaration-visibility counts (`visibility.golden`) under `test/arch_goldens/`. #4203, PR #4215. |
| **G4** | Documentation in three piles | 2026-10-15 (P0-D5): landed design docs in `archive/design/`, open proposals in `docs/design/`, nine `ARCHITECTURE.md` maps, `compiler/README.md` as the entry page with the old body in `archive/design/COMPILER-PORT-LOG.md`. #4204, PR #4226. |
| **G5** | Helper dedup | 2026-10-15 (P0-D8, P0-D9): `dupbodies.golden` is empty; `typecheck.mdk` 30,609 to 30,597 code lines; exempt residue `ir/core_ir_eval.nthArm` and `backend/emit_support.nthArm`. #4205, PR #4222; residue #4229. |
| **G6** | Pin compute-once | 2026-10-15: `test/stage_counts_test.mdk` pins per-verb stage counts (7 CLI probes, 4 LSP transcripts) from a write-only instrument, `support/stage_count.mdk`; counts above 1 are pinned at today's value with their owning issue (#4148, #4151, #4160). #4189, PR #4221; gaps #4228. |
| **G7** | The A8 oversize list | 2026-10-18 (Phase 1 wrap): `oversize.golden` lists every module over 3,000 code lines (the ratchet's rule). It is a membership pin, not a line ratchet: a listed module may grow, and only a module newly crossing the line needs an `Arch-Pin-Raise:` trailer naming the reason its header states. The six listed modules whose headers state no reason owe one from the next sprint that touches each. |

---

## 3. Phase 1: the typechecker's output is a value (A2) — met 2026-10-18

**Exit criterion, met 2026-10-18 at `c98fa3894`** (epic #4206; eight sprints #4235 to
#4241 and #4278, PRs #4242, #4246, #4258, #4260, #4265, #4277, #4286, #4296): no `Ref`
field in `frontend/ast.mdk` (`ast_cells.golden` pins 0); a published scheme holds no live
cell, and P then Q then P renders as cold P (`compiler/types/publish_test.mdk`); one
`typecheck.drive` per verb per graph (`stage_counts.golden`), with the seven exception rows
below. The cut rulings P1-D1 to P1-D22 and the exit outputs are on #4206.

| Id | Action | Landed |
|---|---|---|
| **V1** | Evidence side table | 2026-10-17 (P1-D1, D2, D5 to D7, D16): every site-bearing node carries an `EvId` minted idempotently by the mark pass; answers live in graph-owned site cells published into the one `EvTable`, read through `types/route_key.mdk`; parity by two-arm IR identity per constructor. Sprints 3 and 4, PRs #4258, #4260; #700 closed. |
| **V2** | Finalized publication | 2026-10-17/18 (P1-D4, D8 to D10): `types/publish.mdk` holds `TcReport`, `CheckedProgram`, `PubScheme`, `PartialAnalysis`, the deep zonk, freeze-by-copy at graph end and the live-cell validator; `types/evidence_coverage.mdk` validates the evidence against the trees. Sprints 5 and 6, PRs #4265, #4277; #4053 closed. |
| **V3** | One pipeline | 2026-10-16 to 18 (D4 step one, D5a and D5b, P1-D3, D12 to D15, D19 to D22): `driver/diagnostics.mdk`'s `frontEnd` is the one pipeline function behind `check`, `run`, `build`'s child, `check-policy`, `manifest`, the LSP and MCP; the value-`main` print and the `Async` driver application are judged in the drive; `build --json` reports through `--diag-json`; `medaka test`, the REPL and hover drive each graph once. Sprints 1, 2, 7, 8, PRs #4242, #4246, #4286, #4296. |

**Listed exceptions at the exit** (`typecheck.drive` above 1), each with an owner:

| Row | Value | What it is | Owner |
|---|---|---|---|
| `test_probe`, `test_doc_native` | 2 | the parent's drive plus the native child's own: a value crossing a process boundary | Phase 3 C3 (#2732, #3902) |
| `test_doc_eval`, `test_docimp_eval` | 2 | the doctest-injected program is a second graph (P1-D15) | Phase 3 C3 (#4279) |
| `test_propsdoc_eval`, `test_arb_eval` | 4, 5 | the single-file test parent's gate and pair drives are two prelude universes, plus the doctest graph and the props worker's process | #4282 (precursor #4297), then C3 |
| `lsp.c_didchange` | 4 | four requests, not a duplicate | none needed |

**What Phase 1 did not do**, and where each residual now lives:
- Lowering and eval now read `ProgramFacts` values rather than an installed evidence table
  (the emit path remaps the value after mangling); the reader half of Phase 2 **S4** (#2705)
  landed in sprint arch-p2-2.
- Stampers still write destination cells inside the drive; "the stamper order is a policy
  over a value" is M-SOLVER's evidence-bindings step (#2705, P1-D18).
- Process-global cells (`selectedProfile`, `mainSchemeRef`) remain: Phase 2 S1 and S3.
- `typecheck.mdk` grew by 400 code lines under override, all solver-side halves of V1, V2
  and D5: Phase 2 **T1** and Phase 4.
- Every drive Phase 1 removed had been a silent judge of something (sprint 1 F1, sprint 7
  F1, sprint 8 F1: a mismatched `Async` driver built at exit 0). Each was caught by the
  end-of-sprint review, none by a per-slice check or the corpora. The sprint-plan skill now
  requires a deleted check to name a program only it rejects.

---

## 4. Phase 2: state by lifetime (A3) — met 2026-10-20

**Exit criterion, met 2026-10-20 at `d111d97fc`** (epic #4206; ten sprints #4303, #4304,
#4321, #4325, #4326, #4338, #4341, #4346, #4353 and the optional #4356; PRs #4309, #4311,
#4322, #4327, #4334, #4339, #4342, #4347, #4354, #4360):
`grep -cE "^[a-z][A-Za-z0-9_']* *= *(Ref|newRef)" compiler/types/typecheck.mdk` is 4, every
one an interner or a memo (`interners`, the evidence lineage and the builtin extern catalog;
`coreCheckMemoRef`, `preludePreambleMemoRef`, `moduleChainMemoRef`); `resetState` and
`resetCrossModuleState` do not exist; `cells.golden` pins `types.typecheck` at 4 (26 at the
phase's start); `test/arch_boundaries_test.mdk` pins that the row set of
`types/CELL-LIFETIMES.md` equals the cell census; `compiler/types/publish_test.mdk` is green.
Every remaining cell lives in a record whose constructor is its reset point, and the record
is a parameter or a field of the drive's result, never a module-level cell. The cut rulings
P2-D1 to P2-D18 and the stage-6 questions are on #4206; the plan, facts, contracts and
reports are under `/var/tmp/medaka-sprints/arch-p2*/` on the build box.

| Id | Action | Landed |
|---|---|---|
| **S1** | Classify every cell | 2026-10-19 (P2-D1, D2): `types/CELL-LIFETIMES.md`, one row per cell and bundle field with its lifetime, owner, writers, reset, target and whether a loaded interface would have to fill it; the row set is pinned against the census. Sprint 1, PR #4309. |
| **T1** | The data leaf | 2026-10-19 (P2-D3 to D5): 152 declarations moved body-identical into `types/tc_types.mdk` (−799 code lines); `closure.types.tc_types.golden`. Sprint 1, PR #4309. |
| **S4** | Consumers read `CheckedProgram` | 2026-10-19 (P2-D6 to D10, D16): lowering, the three evaluator drivers and the backends read a `ProgramFacts` value built from the drive's result; the installers, their readers and three cells deleted; `mangleUnitsEv` remaps the value. Sprint 2, PR #4311; #2705's reader half. Residual: one run-owned facts cell, `program_facts.currentFacts` (#4317). |
| **S2** | Per-run and per-group state are arguments | 2026-10-19 (P2-D11, D12): the "current …" cells became fields of `DynCtx` and `SiteCtx`, carried by `TcEnv` (sprint 3, PR #4322); `GroupCtx` is minted by `processSCC` and `ModuleCtx` by the module worker (sprint 4, PR #4327). |
| **S3** | Module and graph records with owners | 2026-10-20 (P2-D13): `GraphCtx` minted by `graphPreamble`, `TcConfig` built once per drive, memo hits return values, `DriverState` and `resetState` deleted (sprint 5, PR #4334). Stage 6 then threaded the shims: a drive's configuration is `DriveInputs` and its answers a frozen `DriveOutputs` (6a, PR #4339; #4337 closed); a drive starts from its inputs and the interners alone (6b, PR #4342; #4330, #4335, #4336 closed); `perRun` and `graphCtx` deleted by threading `ModuleCtx` through 787 functions and `GraphCtx` through about 380, both as tool-generated sweeps reviewed by regeneration (6c, 6d, PRs #4347, #4354). |
| **6e** (optional) | Lexical diagnostic locations | 2026-10-21: `currentLoc` replaced by `ModuleCtx.mcLoc`, a scoped value; 188 diagnostics moved, each classified by rule and approved; #1449 and #3846 closed, #1752 open on its second half. PR #4360. |

**What the phase measured.** N_fill was 19 strict rows and 6 caveat rows
(`CELL-LIFETIMES.md` § "Interface fills"), so the gate of the 2026-10-18 amendment read
"S2 and S3 first" and Val took it (2026-10-19); the amendment is spent. Cost: the four
cachegrind rows within +0.3% per slice and the big check −1% over stage 6; retention flat
except #4355 (MCP `type_at` loop peak RSS +17%, Boehm heap growth with a lower live heap;
accepted and tracked). CPU per verb unchanged (§1). The real cost is growth: +2,733 code
lines in `typecheck.mdk`, all parameters, re-wraps and records, loaned against
`types/tc_driver.mdk`.

**What Phase 2 did not do**, and where each residual lives:
- Lowering and eval take the facts through one run-owned cell, not a parameter (P2-D16):
  #4317, `types.program_facts 1` in `cells.golden`.
- `ElabResult` is still a positional 7-tuple at about 40 sites: #4318, with the Phase 4
  driver leaf.
- The evidence lineage and the extern catalog are process-wide on purpose (`interners`,
  6b Q1), so local dictionary binder names depend on drive history (#4284); a cross-process
  artifact must normalise or fix that before it carries evidence rows.
- The in-process memos are the one approved form of cross-drive state, and only the diags
  arm uses the core memo: the tree arm (`run`, `build`'s child, `medaka test`'s phases)
  needs core's marked declarations back, which a memo may not hold (`graphPreamble`'s
  comment), so `typecheck.module` is 2 on every verb's hello probe. Phase 3 inherits both
  facts (§5).
- Style debt the diff-scoped review cannot see (#4350); a nested-group effect-escape bug
  found beside the work (#4331); the Phase 2 milestone is still open on these five.
- Every refusal in the phase (sprint 4, 6d and 6e, two each) was a measured set smaller
  than the affected set, or a packet fact that contact contradicted; none was a wrong
  change. The end-of-sprint review found what per-slice checks missed each time it fired:
  6b's chain-memo retention regression (392 to 932 MB over 30 rounds), 6d's #4355, 6e's
  six location shapes no corpus contained.

---

## 5. Phase 3: the interface artifact (A7)

This is M-CACHE (#2732) plus run-once O3 and O5. It is also the single largest lever on
the box's CPU-seconds, the stated perf goal. Under the 2026-10-18 amendment it starts
after S1 rather than after Phase 2.

| Id | Action | Mechanism | Acceptance | Size | Needs |
|---|---|---|---|---|---|
| **C1** | `ModuleInterface` codec | Serialize a module's published export surface (schemes, interfaces, instances and their dispositions, the importer-visible evidence rows, declared effects) with a codec in the style of `ir/core_ir_sexp.mdk`, with a format version and the module's source fingerprint, the compiler fingerprint, the instance-environment key the contract requires (§5) and the IO join of the selected target profile (D7: the join's atom list, not the profile's name, so profiles with the same join share an entry). The surface is the F1 producer's output. F3 later adds the full view a test sibling reads (private items included, as rustc's `.rmeta` carries them; ruled 2026-10-18) under a format-version bump. | Round-trip prop: decode (encode x) equals x for every stdlib module; a changed instance environment invalidates; an interface written under one join is never loaded under another, shown by a two-profile test over an unsigned binding whose type differs between them (the open-tail case in D7). | sprint | V2, F1 |
| **C2** | The prelude ships pre-checked | At `make medaka`, the prelude's interface file is produced beside `stdlib/core.mdk`, keyed by the source fingerprint the binary bakes; the loader resolves it from `exeDir` as it resolves `stdlib/` and prefers it when the fingerprint matches (D6, ruled: shipped files, not baked). Every verb loads it instead of re-checking `core.mdk`; the same step then covers every stdlib module. Files are content-addressed per (module, IO join) (D7): `make medaka` produces the full join and the playground's (`wasmgc/browser-worker`), joins whose interfaces are byte-identical share one file, and any other join falls back to a full check. | G6's pins show zero prelude typecheck drives per process; hello-world `check` instruction count falls by the measured prelude share; interface-on versus interface-off differential over the engines corpus is identical; a mismatched fingerprint falls back to a full check and says so on stderr. | sprint | C1 |
| **C3** | Imports load interfaces | The loader consults the interface cache for every user import whose fingerprints match, falling back to a full check; the LSP, REPL and `medaka test` parent reuse it within a session; `build`'s parent hands the artifact to the child (D4, step two). | Multi-module `check` of `medaka_cli.mdk` re-typechecks only changed modules; the REPL's per-line drive count is 1; `build` parent plus child typecheck the graph once; the Phase 1 exception rows owned here (`test_probe`, `test_doc_native`, `test_doc_eval`, `test_docimp_eval`) fall to 1 because the doctest graph and the native child load the parent's interface instead of re-checking. | sprint | C2, V3 |

**Exit criterion.** Nothing proven in one process is re-proven in the next for an
unchanged input; the prelude is checked at build time only.

**Amended 2026-10-21 (Phase 2 wrap): what Phase 2 changed about this phase.** The three
rows above stand as the actions; the points below are their refinements, derived from the
cell table, the memo code and the stage-6 measurements, and they are the inputs to the cut.
The `Needs` column is met: V2 and V3 landed in Phase 1, F1 in #4314, and #2724 (the
module-count superlinearity #2732 waited on) is closed.

1. **C1's content is the fill table.** A loaded interface restores, beside the published
   value (`cpSchemes`, `cpCore`, `cpDispositions`), the 19 strict and 6 caveat rows of
   `types/CELL-LIFETIMES.md` § "Interface fills". Rows of kind *accumulated module by
   module* (the `CrossRun` universes, predicate slots and declared prefixes,
   `GraphRun.ctorExistentialsRef`) are interface content, one contribution per module.
   Rows of kind *computed once from the whole graph's declarations* (`effectDomains`,
   `declEnvsRef`, `markSetsRef`, `argDispatchIdxByIdRef`, `mangledShadowMapRef`,
   `abstractRecordTypesRef`, `builtinClassesRef`, `dictEligible*`) are recomputed by the
   loader over the loaded graph's declaration view, so the interface carries that view
   (heads, signatures, effect-domain declarations) in a `Decl`-free form. The admissibility
   rule is the one `PreludePreamble` already states in `types/tc_types.mdk`: every field a
   pure function of the module's declarations; no `Decl`, no `Ref`, no live `Scheme`
   (`PubScheme` is the admitted form); no read of process state. `cpEvidence` and
   `cpBinders` are not C1 content: no fill row reads them, and they belong to the tree-arm
   artifact (point 2), where #4284 is a prerequisite.
2. **C2 is the core memo served from a file, and it splits by output arm.**
   `CoreCheckMemo` plus `PreludePreamble` is the shipped prelude's content and
   `checkCoreMemoized`'s hit path (`restoreGraphCtx`, `copyCrossRun`) is its loader; the key
   family is the memos' (`ccmKey`), widened per D7 to the join's atom list (the in-process
   memo keys on the profile name, which the file key must not). **C2a** serves the diags arm
   (`check`, the LSP, MCP, the playground, `medaka test`'s gate): acceptance as written, and
   `check_hello.typecheck.module` 2 to 1. At `17e977db4` the prelude's core pass is 63% of a
   hello-world `check`'s instructions (§1), 85% with its parse. **C2b** serves the tree arm
   (`run`, `build`'s child, `medaka test`'s phases), which needs the prelude's elaborated,
   dict-passed trees: that artifact carries them (`ir/core_ir_sexp.mdk` and its parser are
   the codec precedent; #4172's prelude object is the native link's half), and
   `run_hello`/`build_hello` `typecheck.module` go 2 to 1. C2a lands first; C2b is its own
   sprint.
3. **C3's preconditions.** The in-session reuse C3 promises cannot be shown on the
   compiler's own graph until #4167 (the chain memo records nothing past 64 modules) and
   #2797 (the 24-entry MRU caches) are closed; both join C3's `Needs`. The per-module
   accumulator copies (#4165, #4166) are the cost of the *accumulated* rows C3 restores and
   are measured in its cost rows.
4. **Zero growth.** Phase 3 adds no net code lines to `types/typecheck.mdk`: the value and
   its one process cache are a new leaf (`types/interface.mdk`), the codec another
   (`types/interface_sexp.mdk`) over a new `support/sexp.mdk` (a `types → ir` import of
   `ir/sexp.mdk` would be a layering violation, and that module has writers only; corrected
   2026-10-22 at the Phase 3 cut, ruling P3-D19), the loader side lives in `driver/`, and the
   typechecker's one change is the core memo's hit and miss paths going through the frozen
   value. An `Arch-Growth-Override:` in a Phase 3 sprint is a review finding unless it names
   that one path. Phase 2's loaned +2,733 lines are Phase 4's to move.
5. **Parity.** Interface-on versus interface-off is a two-arm differential over the wide
   corpus (every program under `test/` and the inline test programs; stage 6e's survey
   measured five rejected corpora and the wide census then moved 102 more rows), plus the
   stage-6 multi-drive probe set (a loaded interface is a drive, so 6b's rows must not
   move) and the retention and peak-RSS rows (6b's chain-memo regression, #4355). The
   tooling is Phase 2's: `arch-p2/facts/stage6/cost/` and `arch-p1/tools/ir_identity.sh`
   under `/var/tmp/medaka-sprints/`. A mismatched fingerprint falls back to a full check and
   says so; a slice that deletes a prelude drive names a program only that drive judged.
6. **Order against Phase 4.** Ruling 8's precondition (S2) is met, so Phase 4 is unblocked
   too. Phase 3 runs first: it is the perf lever, and its typechecker footprint is one hit
   path, after which Phase 4's leaves move the loaned lines. A Phase 4 leaf that touches no
   driver region may interleave between Phase 3 sprints, the way F1 did between Phase 2's.
7. The Phase 1 exception rows C3 owns are unchanged (§3), and
   `compiler/types/drive_independence_test.mdk` (6b) stays green across C3's session reuse.

---

## 6. Phase 4: the typechecker in modules (A8)

This is #2586. It starts when Phase 2's S2 has moved the state the earlier split trial
tripped on, and it proceeds along the layer axis, one leaf at a time. Each extraction
owes: a dependency-closure golden (G3) for the new module, snapshot `--new`, a LEG A
golden per new module with the selfproc gate's list grown, source-soundness coverage and
the fixpoint.

| Order | Module | Contents | Closure must not contain |
|---|---|---|---|
| 1 | `types/tc_types.mdk` | the 150 `data` declarations and the state records of S1 to S3 | any inference module |
| 2 | `types/tc_diag.mdk` | the closed diagnostic type and its renderer (A5); error values are constructed at the detection sites and rendered here | any inference module |
| 3 | `types/tc_algebra.mdk` | unify, occurs, levels, generalize, instantiate, zonk | solving, drivers |
| 4 | `types/tc_infer_*.mdk` | expression, pattern, match, application, let-group inference, one module per language layer | drivers |
| 5 | `types/tc_solve.mdk` | entailment, obligations, the policy-ordered epilogue (defaulting, ambiguity) | drivers |
| 6 | `types/tc_global.mdk` | coherence, signature checks, cyclic superinterfaces, impl completeness | drivers |
| 7 | `types/tc_driver.mdk` | graph and module drivers, promotion schedule, publication | nothing above it |

A boundary that still needs a back-import after S2 becomes a hooks-record field only if
A6 admits it (rendering, tooling, backend facts); otherwise it stays a gateway-owned
region inside its current module and the owed state move is filed.

**Exit criterion.** `types/typecheck.mdk` no longer exists or is under 3,000 code lines;
every `types/` module has a closure golden; the largest `types/` module is the one whose
header says why.

---

## 7. Phase 5: the backends (A4), in parallel with everything

This is #1398's REVISION block and runs beside Phases 0 to 4; it needs nothing from them.

| Id | Action | Acceptance |
|---|---|---|
| **B1** | The Plan record (R5). **Landed 2026-10-14** (sprint #4107, PR #4110): `backend/emit_plan.mdk`'s `EmitPlan`, carrying its `target`; `lowerProgramEmitWith` takes no backend. R5's reachable-extern-requirements field is not on it yet; T4's `js/` lowering (#3672) waits for that field. | `lowerProgramEmitWith` has no backend parameter; `WasmEmitInput` carries the four facts it lacked. |
| **B2** | F7 capability manifest (P5.5): a checked request publishes a complete, immutable entry/protocol contract before erasure; policy, manifest and emission consume that value. Remaining ledger rows stay open. | F7's existing publication, policy, target and emission route fixtures; the validator arm observed red. |
| **B3** | Twin retirement | Global initialization order is owned by `backend/global_plan.mdk` and carried by `EmitPlan.globalInit`; emitters consume its source-prioritized SCC-ready order. G3's twin count falls with every fact that lands; a PR that adds a twin says why. |
| **B4** | Validators on every test | `core_validate` runs before either emitter writes, in every engines fixture, not only in its own gate. |

**Amendment 2026-10-19: the visibility producer.** A4 applied to the export surface
(`docs/design/TEST-SIBLING-ACCESS-DESIGN.md`). Like Phase 5 it runs beside the typechecker
phases, but it is ordered against them: each slice runs serially between Phase 2 sprints, and
F1 lands before C1 so the codec encodes one producer. F2 and F3 do not gate Phase 3; if C1
exists when F3 lands, F3 adds the full view to the interface under a format-version bump.

| Id | Action | Acceptance |
|---|---|---|
| **F1** (landed in #4314) | A `frontend/` module, seeded from `resolve.mdk`'s `ExpNs` block, answers "may this importer see this name" from declarations plus a loader-supplied sibling flag; resolve and `private_mangle`'s import map read it. | Two-arm IR identity and the LEG A goldens unchanged; `resolve.mdk` shrinks. |
| **F2** | The five `public*` projections in `types/typecheck.mdk` read the producer; the M-IDENTITY ladders are untouched. | No direct `pub`-flag projection remains outside the producer (a grep pin that may only fall); `types/typecheck.mdk` shrinks. |
| **F3** | Test siblings see their subject's private names (the design's slice 3). | The design's slice 3 evidence. |

---

## 8. Mapping to the existing plans

| Playbook | Existing owner | Relationship |
|---|---|---|
| Phase 0 | epic #4206, milestone `Architecture: Phase 0 (the guards)`: G1 #4200, G2a #4201, G2b #4202, G3 #4203, G4 #4204, G5 #4205, G6 #4189 | adds the guards no existing plan has |
| Phase 1 V1, V2, V3 | milestone `Architecture: Phase 1 (output is a value)`; #2549 phase 2, M-PUBLISH (#2544, #4053), M-PIPELINE (#2874), run-once #4151, #4152, #4154, #4160, #4157, #3901, #3902 | landed 2026-10-18; residuals S4 (#2705), #4279, #4282 |
| Phase 2 | milestone `Architecture: Phase 2 (state by lifetime)`; component X (`PerRun`, `resetState`); #2547 and #2548 landed 2026-09-03/04; S4 is #2705; T1 is #2586's first leaf | landed 2026-10-20; residuals #4317, #4318, #4350, #4355 and the found bug #4331 |
| Phase 3 | M-CACHE #2732, run-once O3 (#3902) and O5 (#4169 to #4172, #3903); C3 also needs O4's #4167 and M-CACHE's #2797 (§5 amendment, point 3); #4284 before the tree-arm artifact | same work; prelude-first ordering, D6, D7, and the 2026-10-21 refinements in §5 |
| Phase 4 | #2586, ruling 8 | same sequencing; this document names the layer axis and the per-module acceptance |
| Phase 5 | #1398 R3 to R9, #4107 | unchanged |
| F1 to F3 (§7 amendment) | `docs/design/TEST-SIBLING-ACCESS-DESIGN.md`, style ruling R35 | added 2026-10-19 |
| none yet | M-IDENTITY, #2563 (identity-key every cross-module namespace) | No phase schedules it. Its remaining import-scope ladders are the `Sh` component of `types/` (`ARCHITECTURE.md` §3), which Phase 4's layer table does not yet place; when retired they read the F1 producer. |
| run-once O2, O4 | #4141 | they land as consequences of V3 (O2) and S2 (O4), and G6 pins them |
| Targets epic #3661 | `docs/design/TARGETS-DESIGN.md`, milestones T2 to T5 | Since #4032 the selected profile's IO join is an input to inference, so it is part of every cache key (D7). #4053 (a second drive changes rendering) is V2's P-then-Q-then-P test; #4154 (the target gate re-elaborates) lands with V3, and G6 pins `check --target`; #4051 (every verb selects a profile) lands now, not after V3, and V3 deletes its per-verb plumbing; the IO-join cells in `DriverState` and `selectedProfile` are configuration for S1 and S3's `TcConfig`; T4 #3671 adds no lines to `types/typecheck.mdk` (G1); #3672 follows B1's extern-requirements field |

---

## 9. Decisions, ruled by Val on 2026-10-15

D1 to D6 were ruled in one session and D7 later the same day (recorded on #4206). They are standing decisions; a
later sprint executes them and does not re-ask.

| Id | Decision | Needed by | Ruling |
|---|---|---|---|
| **D1** | A may-only-fall code-line ratchet on `types/typecheck.mdk` alone, with a commit-trailer override. #2289 declined a tree-wide size gate because "a size ratchet teaches avoidance, not architecture"; this is a growth stop on one file, with an explicit reviewed opt-out, which is the rustc form. | G1 | **Adopted.** The soft census had not moved the curve in two months. #2289's tree-wide refusal stands; this is one file. |
| **D2** | The hooks record's admissibility rule: rendering, tooling and backend-fact lookups only, never read from inference. | G2b | **Accepted** as written in A6. |
| **D3** | Archive location (`compiler/archive/` beside `archive/PLAN-ARCHIVE.md` at the root) and the per-directory `ARCHITECTURE.md` shape (under 100 lines, no line numbers). | G4 | **Accepted, amended by P0-D5 (Val ruling 2026-10-15, Phase 0 planning):** the archive is the root `archive/design/` tier, not `compiler/archive/`; it is the existing home for this class of doc and `test/gen_docs_index.sh` indexes it. Open proposals go to `docs/design/`. The per-directory maps replace `ARCH-REVIEW.md`; `TYPECHECK-ARCHITECTURE.md` stays until Phase 4 re-derives it per module. |
| **D4** | Who owns `build`'s front end (#4160): the child runs resolve, or the parent hands the artifact across. | V3, C3 | **Accepted** in two steps: until C1 exists, the emitter child runs the whole pipeline including resolve and the parent stops doing front-end work; once C1 exists, the parent hands the artifact across. This also closes #2874's residual. |
| **D5** | How a value `main` is checked (#4151) without a modified prelude defeating the memo. | V3 | **Accepted:** the auto-print obligation becomes an ordinary wanted on `main`'s type, solved in the same drive against the unmodified prelude. The implementing slice first confirms, by reading `autoPrintPinCore` and `COMPOSITE-MAIN-AUTOPRINT-DESIGN.md`, that the obligation is one predicate. |
| **D6** | How the prelude's interface is delivered. | C2 | **Accepted: shipped interface files, OCaml's form.** `make medaka` produces one interface file per stdlib module beside the sources (`core.mdk` first), keyed by the source fingerprint the binary already bakes; the loader prefers the interface when the fingerprint matches, resolving it from `exeDir` as it already resolves `stdlib/`. Not baked into the binary: OCaml (`stdlib/*.cmi`), GHC (`base`'s `.hi` in the package db) and rustc (`std`'s `.rmeta` in the sysroot) all ship installed interface files beside the compiler and load them lazily, and one loader then serves the prelude, the stdlib and (C3) user modules. The playground fetches the interface the way it fetches `dist/*.mdk`. |
| **D7** | How a shipped or cached interface handles the target profile. Since #4032 the selected profile's IO join is read inside inference (`rowInto`'s open-tail arm and `intersectDeclAtoms` in `types/typecheck.mdk`), so it can change a published type without an error: with `withIo : (Unit -> <IO \| e> String) -> <IO \| e> String`, the unsigned `viaStdin = withIo (_ => readLine ())` is `<IO> String` with no profile and on `wasmgc/node`, and `<IO, Stdin> String` on `wasmgc/edge` (census at `f99cd3e91`). An interface reused under a narrower join would hide an ungranted label inside `IO`, which the target check never gates. The alternative was to stop `IO` absorbing narrow labels at open tails on every profile, so one interface would serve all profiles. | C1, C2 | **Accepted: a published type may depend on the profile, and the IO join is part of every interface key.** Key on the join's atom list, not the profile's name (no profile, `llvm/native-posix` and `eval/run` share the full join). Store interfaces content-addressed per (module, join): the stdlib's 1,977 published bindings all carry written signatures, so their listings were byte-identical with no profile and under each of the six profiles, and collapse to one file each. No typechecker change; #4032's placement stands. |

---

## 10. How the playbook runs

- Each action group is cut as a sprint through `sprint-plan`, with this document's
  acceptance column as the contract's exit bar. Phase 0 guards are independent slices;
  G4 and G5 go to a cheap model.
- Every sprint that touches `compiler/` records `make arch-census` at cut and at wrap-up;
  the diff is the sprint's architectural footprint and goes in the sprint report. A phase's
  wrap also records CPU-seconds per verb against the previous phase's end (the perf goal is
  box throughput, not wall time).
- An `Arch-Growth-Override:` reason names the sibling module the lines will leave to (a
  Phase 4 leaf, or T1), so the override is a loan with a stated lender, not a toll. Phase 1
  took 16 such loans for 400 lines; none named a destination.
- A slice that deletes a check, a drive or a re-check names a program that only the deleted
  check rejects, with base and head exit codes, or states that none could be built. "No
  fixture changed" is not evidence that nothing judged (the `sprint-plan` skill, step 3).
- A finding that a law is wrong amends `ARCHITECTURE.md` by a PR Val ratifies, never by a
  sprint report. A finding that the plan is wrong amends this file with a dated block, the
  way `EMITTER-TARGET-ARCHITECTURE.md`'s REVISION block did.
- When Phase 0 is complete, this document's §1 is re-derived and the growth row is
  retired; when Phase 4 is complete, `TYPECHECK-ARCHITECTURE.md` is re-derived per module
  and `types/ARCHITECTURE.md` replaces it.
