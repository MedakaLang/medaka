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
| **C3a** | Imports load interfaces in process (done) | The diagnostics arm serves each unchanged module before the entry from its recorded `ModuleInterface` (`types/module_interface.mdk`) within a session (the LSP and the playground; `check --json` and MCP drive without recording steps, so they neither serve nor record interfaces); two pass caches serve the raw-tree resolve and exhaust verdicts per module; the chain-length and MRU cliffs (#4167, #2797) are fixed. | Met: the warm leaf edit of the compiler's own graph re-checks 2 modules (the `lsp.e_leaf_edit` rows of `test/arch_goldens/stage_counts.golden`). The REPL clause is met at the sprint base (`repl_one_line.typecheck.drive` 1 in `test/arch_goldens/stage_counts.golden`), and so is `build`'s (`build_hello.typecheck.drive` 1 and `typecheck.module` 1 in the same golden). | sprint | C2, V3 |
| **C3b-1** | The tree arm serves in process (done) | A keyed tree drive serves each unchanged module before the entry from its recorded `ModuleTrees` (`types/module_interface.mdk`, policy in `types/serve_policy.mdk`): the marked pre-`dictPass` trees plus the rows the graph-end passes read, with `dictPass` re-run over the whole graph. Local binder names are a function of the graph (#4284). `medaka test`'s gate and doctest drives are keyed, so the doctest drive checks only the spliced module. One-shot verbs record and serve nothing. | Met: `test_docimp_eval.typecheck.module` falls 4 to 3 with `typecheck.drive` 2 (`test/arch_goldens/stage_counts.golden`); `test_doc_eval` met the criterion at the sprint base. The whole-tree census of cold against warm drives is identical. | sprint | C3a |
| **C3b-2** | The module store and the `medaka test` parent/child reuse (measured, not built; ruled out 2026-10-25) | Sprint 7b's identity spike built both on a scratch tree and measured them. The store saves at most 1.5 / 2.1 / 4.1% of the gate sample's CPU under the three key variants (1.4 / 2.4 / 11.0% of `make test`), gross of any decode cost. Decoding a stdlib module costs about what checking it does even at `prelude_elab`'s cursor rate (244 Ir/B; the prototype reader is 555), so it pays only for the compiler's own larger modules, and a cold `check --cache` of the self graph costs +54% CPU over a keyed check to write 130 MB. The handoff is exact over 110 native targets under seven identity rules but CPU-negative today (`interface_sexp_test` 28.0 to 35.0 CPU-s); its ceiling is 0.85% of `make test`. The child shares no module id with its parent at the base: the probe's per-run runtime dependency renames every stdlib module (`canonicalModId`, `driver/loader.mdk`). With stable ids the child floors would be `test_probe` 7 to 3, `test_doc_native` 2, `test_docimp_native` 3 to 2, `test_bytebuilder` 13 to 3, not 1. What 7b landed: a served module's key without the entry and roots (#4444 item 1). Sorting the graph key's rows was tried and dropped: a served module then prints overlapping impls in the first drive's order. | Not built (Val, 2026-10-25). `test_probe` and `test_doc_native` stay named exceptions in `stage_counts.golden`; #3902, #4279 and #2732 close on these numbers. Reopen if the module codec gets a cursor reader and a view that is not 57% of a file. | sprint | C3b-1 |

**Exit criterion.** Nothing proven in one process is re-proven in the next for an
unchanged input; the prelude is checked at build time only.

**Exit, stated 2026-10-25 at `fba49724e`, with named exceptions** (epic #4206; PRs #4391,
#4394, #4410, #4433, #4448, #4452): the prelude ships pre-checked and is not checked at
run time, and a module whose key matches is served in process by the diagnostics arm and
the tree arm. Nothing is served across a process. The `medaka test` native child checks
its own graph, so four rows of `stage_counts.golden` stay named exceptions
(`test_probe`, `test_doc_native`, `test_tonly_native`, `test_bytebuilder`); row C3b-2
records why the store and the handoff were measured and not built. Reopening them is
Phase 4's call, not a Phase 3 debt.

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
   `checkCoreMemoized`'s hit path is its loader; the key
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

**Amended 2026-10-26 (the Phase 4 cut; rulings P4-D1 to P4-D12, Val, recorded on #4206).**
The seven-row table this section carried was replaced by the one below, derived at
`e2f8b4840` from the file's measured call graph rather than from its section banners:
`types/typecheck.mdk` has 3,409 top-level declarations, its only large strongly-connected
component is the 64-declaration `infer` recursion (1,206 code lines), and a dependency-forced
layering of every declaration (a declaration's layer is at least the max of its callees'; the
tool and its inputs are under `/var/tmp/medaka-sprints/arch-p4/`) orders the rows below with
no cross-layer conflict, so no inversion mechanism is needed (P4-D2). Three findings of that
derivation corrected the old table: the `coh*` family is the instance-head *matcher* (algebra,
not a global check); the solver sits *below* inference, because local `let` generalization
calls improvement (GHC's order); patterns and the binding-group policy split out below the
recursion. The table below is the one sprint 0 ratified (see the second amendment block). A module
over 3,000 lines by the A8 measure states why in its header and joins `oversize.golden` under an
`Arch-Pin-Raise:` trailer (A8). Principles for every row: it names its precedent and whether
its order is forced or chosen; it holds one responsibility; it cites only the spec sections that
govern its contents; it owns its tests.

| Order | Module | Holds | Spec it implements | Precedent | Size (A8 file lines; code lines) | Position | Exports at boundary depth |
|---|---|---|---|---|---|---|---|
| 0 | `types/tc_types.mdk` (landed, Phase 2 T1) | the data declarations and state records, and the five record helpers and three accumulator data rows it already holds (`Accumulate`, `PassEvidence`, `PassMethod`), and the key format of the grant records (`grantTopKey`, `methodGrantKey`, `setGrantIds`) | — | types.ml; GHC.Tc.Types | 1,211; 3 | - | the 152 types; gains `PassEvidence`, `PassMethod`, `Accumulate` |
| 1 | `types/tc_mono.mdk` | operations over `Mono`/`Scheme`, pure except for minting effect-variable ids from the graph-run counter: head inspection, variable ids (including the live tail ids of effect variables), substitution, one-way matching and overlap, the builtin tycons, the `Scheme` projections (`schemeIds`, `schemeMono`, `schemeBodyOf`, `schemeAuthIds`) | HM-CORE §2 (owed, #2555); DICT §3 (specificity is matching) | btype.ml; GHC.Core.Unify, TyCo.Subst | 1,024; 822 (test-only 22) | forced below everything: 582 edges into it from the rows above, 0 edges out of it to any module but `tc_types` | 114 names; most-shared: `monoUnboundIds`, `tconBuiltin`, `tyvarId`, `headTyconMono`, `substMono`, `tyAppSpine`, `tyVarNames`, `schemeIds`, `authCellsIn` |
| 4a | `types/tc_diag_text.mdk` | **NEW (ratification pending (Val, 2026-10-27)).** the context-free message text: every message, help and fix builder, diagnostic key and text rewrite (`locKey`, `msgAtKey`, `writtenDiag`, `prependDiagOpt`) whose operands are values and whose closure is `tc_types`, `tc_mono`, `repr`, the AST and the effect leaves (`kindName`, `backticked`, `quotedNames`, `renderKindArrow`); no row takes a context record, an environment or a cell | ERROR-QUALITY.md; A5 | GHC.Tc.Errors.Ppr (unsourced here), without a Types counterpart: Medaka has text builders and no message data type; rustc keeps diagnostics as values apart from the `DiagCtxt` sink (report-rustc.md:58) | 1,453; 938 | forced below `tc_env`: 1 edge `tc_env` to the leaf (`kindName`, read by `ceRowParamKindNamesAt`, an R5 test-only probe), 0 back; chosen against `tc_state`: 0 edges either way | 147 names |
| 2 | `types/tc_state.mdk` | mints, copies and carries of the state records (including `emptyShadowDicts` and the span carries `sameSpan`, `mctxAt`, `dynAt`, `envAt` with their `IfSome` forms), the process interners cell, the `Windowed` channel ops, and the test-only trace-sink probes that only build or read a `TraceSink` or the graph-run evidence cells (`beginAssumptionTrace`, `beginNumericPredicateTrace`, `beginMethodReturnTrace`, `beginEvidenceObservation`, `evCellsSpanProbe` and their `finish` forms) | TYPECHECK-CONTRACTS §5; CELL-LIFETIMES.md | Ctype's level state; TcRnMonad env mints | 711; 550 (test-only 66) | forced above `tc_mono`: 3 edges state to mono, 0 back | 41 names; most-shared: `currentScopeStore`, `wWindow`, `dynAtIfSome`, `wMark`, `probeGraphCtx`, `initialModuleCtx`, `mctxAtIfSome`, `mctxAt`, `wRestore` |
| 3 | `types/tc_env.mdk` | construction of `ImplEnv`, `ClassEnv`, `MethodEnv` and lookup in every declaration envelope (`DataEnv`, `DeclEnvs`: accessors, visibility, the reach/import index and the import site it finds (`importLocFor`), the export and definer tables; their construction from declarations is `tc_decls`), the identity keys (including the built-in classes' spellings and references, `builtinClassName`, `builtinIfaceRef`), the imported-binding rows, and the term environment (`TcEnv` extension and lookup); which names an import makes visible is `tc_scope` | DICT §8 (identity-keyed tables); SHADOW §1.0 (the envelopes the scope ladders read) | env.ml; GHC.Tc.Utils.Env (InstEnv, ClassEnv) | 1,570; 1,293 (test-only 331) | forced above `tc_state`: 11 edges env to state, 0 back | 164 names; most-shared: `tyTabKey`, `namesToSet`, `methodSlotKey`, `sameIfaceDecl`, `ifaceTabKey`, `effTailNames`, `declTopFnNames`, `lookupRecordByName`, `lookupVar` |
| 4 | `types/tc_diag.mdk` | the emission API over `TcDiag` (`recordTypeError`, the `pushTypeError*` family, ambiguity replacement), the detection counter; the context-free message text and keys are `tc_diag_text`'s, and a message builder that needs solver or inference context lives beside its emission site (D3) | ERROR-QUALITY.md; DIAGNOSTIC-CODES-DESIGN.md; A5 | Location + per-module `report_error` (report-ocaml.md:51); GHC.Tc.Errors (the reporter, apart from its Ppr leaf) | 422; 225 | chosen: 0 edges with `tc_env`; acyclic anywhere from just above `tc_state` to just below `tc_scope` | 14 names; most-shared: `pushTypeErrorAt`, `pushTypeError`, `pushTypeErrorOnceAt`, `pushTypeErrorHelpFixAt`, `pushTypeErrorOncePerSite`, `erredDuring`, `recordTypeError`, `pushTypeErrorOnce`, `pushBoundaryAmbiguity` |
| 5 | `types/tc_scope.mdk` | **NEW.** name visibility across imports, read off the envelopes: the method-scope ladder (the own, imported and undecided rungs, admission, the dispatch-index and impl-existence reads scoped by it), the ctor and record scoped views (candidates, overrides, scoped entries), the interface rows an import makes visible (`importedIfaceRows`), and the alias-qualified supply (`import m as A` rows, keys, spellings, ambiguity message, dictionary names and constraint entries) | SHADOW §1.0, S1-NS, S2-DECL; language-design Module System, Import Details; SYNTAX Import aliasing | GHC.Rename.Env / GlobalRdrEnv (lookup apart from InstEnv); OCaml `Env.lookup_*` (resolving opens apart from the tables) | 814; 694 | forced above `tc_diag`: 2 edges scope to diag, 0 back | 27 names; most-shared: `methodAdmittedHere`, `methodEntryHere`, `argDispatchOf`, `methodIfaceHere`, `ieImplExistsForHead`, `methodDispatchIdx`, `aliasConstraintEntries`, `aliasDictNames`, `aliasMethodSpellings` |
| 6 | `types/tc_unify.mdk` | fresh variables and levels (including level lowering, `lowerToCurrent`, `lowerOwnedRoot`), unification over types, rows, joins, index rows and authority, the occurs check, the mismatch action (`typeMismatch`, `poisonMismatchVars`), generalization and instantiation | HM-CORE §3, §4 (owed, #2555); EFFECTS §2.4, §5, §6.6-6.8 | ctype.ml; GHC.Tc.Utils.Unify, TcMType, Instantiate | 2,171; 1,915 | chosen: 0 edges with `tc_scope`; acyclic anywhere from just above `tc_diag` to just below `tc_decls_variance` | 84 names; most-shared: `freshVar`, `unifyIn`, `captureScope`, `enterLevel`, `exitLevel`, `freshTvMap`, `instantiateMethodTracked`, `unify`, `atomsEscape` |
| 7 | `types/tc_decls_variance.mdk` | **NEW.** polarity and variance of declared types: occurrence polarity, polarity joins and the `DeclEnvs` polarity fixpoint | EFFECTS §6.4 (inferred variance, invariant indices), §6.8 (covariant joins), §5 (the covariant-position check); HM-CORE §3 (owed, #2555: unification parameterized on the declaration environment's variance) | typedecl_variance.ml (OCaml); GHC.Tc.TyCl variance and role inference | 325; 293 | chosen in substance: one edge (`polarityAtOr` -> `polarityAt`, a helper that could sink) puts it above `tc_unify` | 6 names; most-shared: `payloadAstTypes`, `variantPayload`, `seedParamPolarityFixpointScoped`, `declEnvPolarityChain`, `inferParamPolarities`, `recordParamPolarities` |
| 8 | `types/tc_decls_types.mdk` | **NEW.** the written-type layer of declaration analysis: AST types to `Mono` (`fromAstType`, `fromAstTypeE` and their application, alias-argument, effect-row and authority-qualifier cases `qualifyByTerms`, with the signature binder sets `SigVars` they read), the expansion of an applied alias, at conversion and at a written head (`aliasArgBindings`, `aliasScopeE`, `expandAliasHeadTy`, `substAliasArgs`), declared-kind consistency (`checkDeclaredKinds`, `checkHeadKinds`, `checkIfaceHeadKinds`, `checkSuperKinds`), effect domains (`registerEffectDomain`, `populateEffectDomainsGraph`, `checkDomainAxes`, `checkWrittenElementCap`), authority terms and binders (`authArgOf`, `checkDeclAuthorityUses`, `checkBinderDomain`, `checkPhantomAuthorityExport`, `reportUnboundAuthorityNamesIn`, `authorityBinderBound`) and written effect-parameter checks (`checkEffectParams`), with the message builders those checks use | DICT §1 (the type and predicate forms the conversion lowers); EFFECTS §2.1 (the domain family a label declares: `Unit`, `Prefix`, `Set`, `Product`), §4.1 (named authorities and scoped constraints), §6.1-§6.5 (kinds, declaration sites, partial annotations, kind consistency, requires chains), including §6.4 (alias expansion invents no qualifier); SYNTAX Declared parameter kinds | typetexp.ml (unsourced here; named only by the playbook row); GHC.Tc.Gen.HsType (4,948 lines, report-ghc.md:34) apart from GHC.Tc.TyCl | 1,641; 1,480 | forced above `tc_decls_variance`: 8 edges decls_types to decls_variance, 0 back | 31 names; most-shared: `fromAstType`, `rowArgNamesIn`, `fromAstTypeE`, `authArgBindersIn`, `atomsOfWritten`, `rowArgNames`, `sigVarsWithAuths`, `patternSlotNamesIn`, `sigConstraintsOf` |
| 9 | `types/tc_decls.mdk` | declaration analysis above the written-type layer: building `DataEnv` and `DeclEnvs` from declarations (`buildDeclEnvs`, `dataEnvAddDecl`, the owner tables), variant and record registration (`registerVariants`, `registerRecordInfoKeyed`, the existential cells), type aliases (`addAliasDecl`, cycle rejection by `rejectCyclicAliases`, the expansion normal form `tyAliasNormalForm`), the recording of declared kinds (`recordDeclKinds`, `recordDeclaredKinds`), the method scheme rows, and the signature layer over the conversion (`sigToScheme`, `sigVarsFor`, `instantiateSigTracked`, `astTypeFreshTbl`, `headAnnotTy`). The conversion itself and the kind, authority, effect-domain and effect-parameter checks are `tc_decls_types` | DICT §1; EFFECTS §4.1 (the signature binders), §6.1 (kinds), §6.2 (kind annotations bind parameters at declaration heads), §6.4 (kind consistency and indices of a declared head); DICT §8 I4 (the alias normal form keeps resolved identity); language-design Data Types | typedecl.ml; GHC.Tc.TyCl | 1,579; 1,338 (test-only 346) | forced above `tc_decls_types`: 29 edges decls to decls_types, 0 back | 39 names; most-shared: `methodDictArityOf`, `constraintIface`, `ifaceMethodSchemeRows`, `constraintIsMethodLevel`, `constraintVarNames`, `sigToScheme`, `sigToSchemeTvsIn` |
| 10 | `types/tc_foreign.mdk` | **NEW.** extern signatures checked against the FFI-ABI crossable set and the FFI-ABI rules on unlabelled, builtin-shadowing, catalog-narrow and nullary externs, with the signature-position helpers they use | FFI-ABI §1 (the crossable set) and its preamble rules (T-FFI-UNLABELLED, -BUILTIN-SHADOW, -CATALOG-NARROW, -NULLARY); EFFECTS §2.3 (the `FFI` parameter grammar at a declaration) | GHC.Tc.Gen.Foreign (foreign declaration checks) | 541; 481 | chosen: above `tc_decls_types` (the alias expansion `expandAliasHeadTy` it reads at a written head), 0 edges with `tc_decls` | 8 names; most-shared: `externDecls`, `ffiExternTypeRowsWith`, `ffiCheckExternsCatalogRow`, `ffiCheckExternsCrossable`, `ffiCheckExternsLabelled`, `ffiCheckExternsShadow`, `ffiStampMode`, `namedArgOrder` |
| 11 | `types/tc_solve_givens.mdk` | **NEW.** the given and assumption store of the solver: registering, scoping and answering from givens and assumptions, including the active-dictionary assumption writers (`registerEachActive*`, `registerActiveDictVars`) | DICT §3 (assumptions); TYPECHECK-CONTRACTS §3 (givens) | GHC InertSet givens; rustc ParamEnv | 695; 608 | chosen: 0 edges with `tc_foreign`; acyclic anywhere from just above `tc_decls` to just below `tc_solve_entail` | 39 names; most-shared: `lookupPredicateSlots`, `givenAnswers`, `predicateSlotKnownSupers`, `registerSlotPredGivens`, `superLookup`, `activeDictPredOf`, `activeDictVarOf`, `activeDictVarOfEncl`, `activeFunDictPredOf` |
| 12 | `types/tc_solve_entail.mdk` | **NEW.** entailment as routes: the judgment `P ⊢ π ⇝ e` at a site (`entail` and its assumption, instance, determined and rigid-lead arms `entailAssum`, `entailInst`, `entailDetermined`, `entailRigidLead`), the selection of the most specific matching impl row (`ieSelectRowByIface`, `ieSelectRowByMethod`, `pickMostSpecificEntry`, `goalCandidates`, `goalReach`) with the closed-goal ambiguous-overlap report (`goalsClosed`, `reportAmbiguousOverlap`), the route words a site stamps (`keyForSite`, `stampOpRouteVal`, `stampPredicateOpRouteVal`), the route walk over a selected row's `requires` and supers with its memo (the SCC of 22 decls and 523 lines: `routeOfD`, `argImplRequiresRoutesForRow`, `superRouteAt`, `routeWalkMemoized`) and the return-position route selection (`selectReturnRow`, `legacyReturnReqRoutesForRow`) | DICT §3 (the entailment judgment, specificity, determination, W2 the termination measure of the route walk), §5 (return-position dispatch through the dictionary), §6.1 (the per-goal unique minimum), §6.2 T3 (the closed goal), §8 I2 (qualified instance identity) | GHC.Tc.Solver.Dict (report-ghc.md:63; Interact was merged into Solve, :97); rustc traits/select (3,112 lines, report-rustc.md:32) beside fulfill.rs (:48) | 1,327; 1,172 | forced above `tc_solve_givens`: 12 edges solve_entail to solve_givens, 0 back | 34 names; most-shared: `goalCandidates`, `goalRows`, `reqWalkStart`, `ieSelectRowByIface`, `goalReach`, `reqWalkEnter`, `reqWalkMemo`, `noteNumericPredicateTrace`, `directSuperGoals` |
| 13 | `types/tc_solve.mdk` | one solving judgment over one goal store, above the entailment core: the exact-return and method-return solver (`solveExactReturn*`, the method-return predicate and its templates); improvement and determination by the unique instance; instance matching and selection for the judgments above entailment (the eleven rows `implMatchesU`, `bucketArgsMatch`, `implMatchesWithReqsU`, `bucketArgsMatchReqs`, `implHeadMatchesArgs`, `findMatchingImplReqsU`, `concreteReqMatchByIface`, `firstReqMatch`, `rigidHeadInstanceContext`, `answeredOnlyByBindingHead`, `residualSelectionStable`); the goal store, its dict-application reads (`dictAppsSince`) and the solving walks' discharge memo (`pushGoal`, `walkGoalDischarged`, `walkGoalFollowed`); the stamp queue (`enqueueStampCtx`, `stampCtxOf`); and the singular `resolve*Site` computations (one site each). Entailment and the route walk are `tc_solve_entail`; predicate-slot, dict-arity and constraint registration and the residual walk at binders are `tc_solve_check` | DICT §3, §4.2, §5; TYPECHECK-CONTRACTS §3 | GHC.Tc.Solver; rustc_trait_selection | 2,706; 1,960 (test-only 326) | forced above `tc_solve_entail`: 68 edges solve to solve_entail, 0 back | 101 names; most-shared: `uOblArgs`, `openScope`, `callUOblsWindow`, `isLocalAbsName`, `returnPosMethodNames`, `numConstrainedIds`, `routeLocalSym`, `routesOfMonosTopV`, `ifaceSelfAndSupers` |
| 14 | `types/tc_solve_check.mdk` | **NEW.** the solver boundary judgments and the write side of a binder's dictionary parameters: obligation checks at call and survivor sites, ambiguity registration and reports, numeric defaulting, the residual walk at binders (`residualPredsOf`, `residualBoundPreds`, `residualInferredPreds`, `unroutedResidual`: DICT §3 `inst` for a residual), the call-slot obligations of dispatch monos at generalization (`registerDispatchMonos`), the promotion of inferred constraints to the binding's scheme (`registerInferredConstraints`, `maybeInferConstraint`); and the registration of what the sites read back: predicate slots, dict arity and the constraint tables (`registerReqSlots`, `registerImplRequires`, `registerMember`, `registerConstraintRegs`, `registerInferredFor`, `inferredPredicateSlots`, `declaredPredicateSlots`, `setFunConstraintEntry`, the slot keys `cslotKey` and `cslotVecKey`, the test-only probe `inferredPredicateSlotsProbe`), with the lookups of an interface by constraint id they use (`ifaceForConstraintId`, `ifaceForInferredId`) | DICT §3 (the residual walk), §4 `gen`/`gen-sig` (the point of evidence abstraction; inferred-constraint promotion: the inferred P' becomes the scheme's context), §4.1 G1 (its local reading: one dictionary parameter per predicate, arity and order keyed by binder identity), §4.2 (discharge, OD2), §5 (the element dictionary of a return- or argument-position method), §6.2 (scheduling), §6.3 (defaulting), §8 I1 (evidence abstraction keyed by binding identity); HM-CORE §6 (owed, #2555) | GHC simplifyTop / Solver.Default; rustc fulfill (the boundary judgments); no module-level precedent for the registration half (unsourced here) | 1,861; 1,558 (test-only 47) | forced above `tc_solve`: 80 edges solve_check to solve, 0 back | 35 names; most-shared: `finalizeNumBoundary`, `dedupSlotVecs`, `callPredOf`, `checkCallObligationsU`, `checkSigVarGoals`, `oblPredOf`, `rejectUndeterminedVectors`, `predicateSlotView`, `boundTyvarIds` |
| 15 | `types/tc_shadow.mdk` | standalone-vs-method shadow resolution (S1-S9) outside the inference recursion, including the recorded-local site resolution `resolveRLocalSite` (SHADOW S2's inversion at route time), and the admitted-set occurrence checks (S2-DECL (d)) | SHADOW-SEMANTICS §1 S1-S9, §1.1; S2-DECL (d) | none (Medaka-specific) | 979; 819 | chosen in substance: one edge (`shadowStandaloneDictSlots` -> `dedupSlotVecs`, a helper that could sink) puts it above `tc_solve_check` | 50 names; most-shared: `isDefinerShadow`, `methodCellOf`, `pushAmbiguousShadowDecl`, `nameableIfaceMethodSet`, `recoveredShadowSym`, `groundShadowReceiver`, `shadowHeadEnv`, `callArgVecsV` |
| 16 | `types/tc_effects.mdk` | the effect checks inference runs at binding boundaries and impl bodies (escape, summary failures, rigidity, index-only variables), grant and authority recording (including the authority an argument carries into its application, `argumentAuthority`), and file-bound values (authority bounds at binding boundaries: recording, flow and settle checks); wires the `effect_*` leaves into inference | EFFECTS §2.3, §5, §6.2-6.9, §8 | none in GHC/OCaml | 1,414; 1,195 | chosen: 0 edges with `tc_shadow`; acyclic anywhere from just above `tc_solve_check` to just below `tc_occurrence` | 49 names; most-shared: `clausesOf`, `beginEffectSummaryScope`, `finishEffectSummaryScopeKeeping`, `evOrdinal`, `recordClauseFileBound`, `flushPendingEscapes`, `freshEffectSummary` |
| 17 | `types/tc_occurrence.mdk` | method and literal occurrence inference, operator dispatch-site recording (including `recordShadowStandaloneObls`), evidence-site minting, the mark pass over binding groups and the write-back of its marked clauses over the declarations (`rebuildGroupDecls`), the constrained-signature set, and the test-only evidence-cell and method-return probes (the `cellGoalInnerAliasing` family, `cellStoreMisses`, the `methodRow*Probe` and `methodReturn*Probe` rows) | DICT §4 (occurrence half), §5, §8 I7; SHADOW S2-DECL | GHC.Tc.Gen.Head, Gen.App | 2,899; 2,058 (test-only 515) | forced above `tc_effects`: 13 edges occurrence to effects, 0 back | 45 names; most-shared: `constrainedSigNames`, `argDispatchIndicesById`, `isGrantOnlyEv`, `markSourceless`, `recordIfaceObligation`, `instantiateStandaloneOccurrence`, `instantiateVarTrackedWithSubst`, `markNumlitOpTaint`, `mkMethodOccObl` |
| 18 | `types/tc_groups.mdk` | binding-group analysis and the generalization policy at a binding boundary: the free-variable walk that forms groups, the value restriction and the recursive-value restriction (`checkRecursiveValue`, `checkRecBindNonFunction`, the `eagerRefs` walk), group generalization, goals required below, signature constraints | HM-CORE §1 (gen-value), §4, §5 (owed, #2555); DICT §4.1 G2, §6.3 at binders | GHC.Rename.Bind dependency analysis + Tc.Solver.simplifyInfer; OCaml is_nonexpansive/generalize | 1,254; 1,069 | chosen in substance: one edge (`isDeclaredCtorHead` -> `ctorHeadShaped`, a helper that could sink) puts it above `tc_occurrence` | 36 names; most-shared: `exprLoc`, `checkRecursiveValue`, `allEVars`, `sigTvarIds`, `genBindingRestricted`, `residualsOf`, `isNonexpansive`, `checkRecBindNonFunction`, `requireGoalsBelow` |
| 19 | `types/tc_pat.mdk` | pattern inference: literal, constructor, tuple, list, record and existential-opening patterns, binder types | no HM-CORE section on pattern typing yet (owed, #2555); language-design Data Types; EFFECTS §4.1 | GHC.Tc.Gen.Pat | 397; 332 | chosen: 0 edges with `tc_groups`; acyclic anywhere from just above `tc_occurrence` to just below `tc_infer_records` | 14 names; most-shared: `unknownFieldMsg`, `recordBinderType`, `settlePatLits`, `takePatLits`, `inferPat`, `recordLocalBind`, `inferPats`, `recordAuthCells` |
| 20 | `types/tc_infer_records.mdk` | **NEW.** the helpers the record arms call: field-owner resolution, field-shape conflicts, record instantiation, the record error emitters and the field-name suggestion, and the stamped record head (`stampedRecordHead`); the nine record arms themselves (`inferRecordCreate`, `inferFieldAccess`, `inferValueField`, `inferRecordUpdate*`) and their field-assignment helpers (`unifyFieldAssignIdx`, `unifyFieldAssignsIdx`) are members of the `tc_infer` recursion | language-design Data Types, Sum Types (Variants with Named Fields), Product Types (record construction, access, update) | typecore.ml record cases (type_label_exp, disambiguate_label); GHC.Tc.Gen.Expr record cases | 725; 649 | chosen above `tc_pat`: its closure has no `tc_pat` (0 edges either way) | 15 names; most-shared: `recordFieldNames`, `assignedFieldNames`, `firstFieldName`, `instantiateRecordUpdate`, `resolveFieldRecord`, `stampedRecordHead`, `unknownRecordFresh`, `checkMissingFields`, `fieldAssignNamePair` |
| 21 | `types/tc_infer.mdk` | the expression inference recursion (variables, application, lambda, let and rec-let, match and arms, blocks, the shadow-application arms, the record arms, and the operator arms with their typing rules (`inferBinop`, `inferUnop`)), signature pre-unification, exhaustiveness and wide-literal checks at their sites; the record arms' helpers are `tc_infer_records` | DICT §4 (the elaboration judgment); HM-CORE §3-§5 (owed, #2555); SHADOW §1 (S2, S4-S7), §1.1; S2-DECL (d); EFFECTS §3 | typecore.ml; GHC.Tc.Gen.Expr, Match, Bind | 2,403; 2,593 (test-only 5) | forced above `tc_infer_records`: 21 edges infer to infer_records, 0 back | 17 names; most-shared: `closeScope`, `goalsMark`, `valueSpanLoc`, `sccProtectedSignatureIds`, `infer`, `appArgLoc`, `borrowedEffectCells`, `checkMatchChecks`, `checkWideLiterals` |
| 22 | `types/tc_elab.mdk` | dict-passing elaboration (`dictPass`), the grant rewrite (`grantWholeDomain`), operator-to-method rewriting; tree-to-tree passes over evidence | DICT §4 (translation), §7; EFFECTS §8 | GHC.HsToCore evidence binding; `dictPass` (STAGE2-DESIGN) | 1,327; 1,169 | chosen in substance: one edge (`constrainedSigPredicateSlots` -> `sigConstraints`, a helper that could sink) puts it above `tc_infer` | 7 names; most-shared: `setFunPredicateSlots`, `dictPassModulesIfEnabled`, `drivenEvidence`, `methodGrantOf`, `methodMarkCtx`, `selfDeclArities`, `grantWholeDomain` |
| 23 | `types/tc_global.mdk` | the whole-graph and declaration-level checks that need inference: the coherence scan, impl head, super-context and completeness checks, impl and default method bodies, survivor call obligations | DICT §6 C1-C4, §5.1 M1-M3, §3 (super context); #3995/#4010 | GHC.Tc.TyCl.Instance, Tc.Validity (OCaml has no classes) | 2,222; 1,906 | chosen in substance: one edge (`registerMethodBodyGrants` -> `methodGrantOf`, a helper that could sink) puts it above `tc_elab` | 17 names; most-shared: `nestedRequireGoals`, `calleeNumObls`, `checkCoherence`, `checkGradedImplHeads`, `checkImplCompletenessMap`, `checkPhantomMethods`, `checkSuperImpls`, `cohImplOfRow`, `cohIncomparableHelp` |
| 24 | `types/tc_module.mdk` | the per-module check in one order: declarations, top-level groups, impl and test bodies, final checks, the stamp drain and its walks (`stampEach`, `stampGraphDecls`, `stampGroupClauses`, `stampTailDecls`), the plural site resolution (`resolveSites`, `resolveRLocalSites`, `resolveArithSites`, `resolveOpSites`), binder-type materialization, and the registration of imported declarations (the import-overlay rows: `registerImportOverlay`, `overlay*`, `cached*`, `importOverlayDecls`, `oracleImportDecls*`, `reexported*Decl`, `useDefinerRows`) | TYPECHECK-CONTRACTS §3 (scoped scheduling); DICT §4.2, §7.1; HM-CORE §5 (owed, #2555) | typemod.ml's per-structure half; GHC.Tc.Module tcRnSrcDecls and tcRnImports (split from the driver by size) | 2,978; 2,428 (test-only 75) | forced above `tc_global`: 19 edges module to global, 0 back | 15 names; most-shared: `stampGraphDecls`, `captureTypeErrors`, `drainStampQueue`, `verdictFinding`, `checkBodyImpl`, `checkModuleFull`, `checkModuleFullDiags`, `checkRunResidue`, `directExternSigs` |
| 25 | `types/typecheck.mdk` (stays; P4-D4) | the entry module: the graph drive, the chain and core memos and interface continuation, serving, import seeding, publication, value-main judgment, configuration, the verb-facing API; the pre-inference alias rewrite, a driver step (`aliasSchemes`, `aliasSchemeEntry`, `coreAliasSchemes`, `renameAliasedMethods*`, `deAliasMethod*`, `resolveAliasMethodSpellings`); the `export import types.publish` facade | TYPECHECK-CONTRACTS §4, §5; DICT §7.1, §8; A2, A7; language-design Module System, Import Details (alias renames) | typemod.ml type_implementation; GHC.Tc.Module tcRnModule + GHC.Driver.Make upsweep | 2,293; 1,995 (test-only 3) | forced above `tc_module`: 19 edges typecheck to module, 0 back | 50 names; most-shared: `bindingGrantArity`, `chainArgs`, `chainFullKey`, `checkModules`, `checkModulesAllLines`, `checkModulesChainReportFor`, `checkModulesChainReportForGraph`, `checkModulesDiagsChain`, `checkModulesEntryFullReportK` |

**Amended 2026-10-25/26 (sprint 0, the partition; Val's rulings).** Sprint 0 placed every one of
`types/typecheck.mdk`'s 3,409 top-level declarations by one numbered rule (R1 486, R2 1, R3 1,240,
R4 1,494, R5 182, R6 6), checked that the loader accepts the whole partition as files that build and
check clean, and measured the sizes. The partition of record is each module's header together with
`compiler/types/ARCHITECTURE.md`; the table above is generated from the same source as the headers.
The table grew from the sixteen modules below `tc_types` (plus the entry) of the first version to the
twenty-five modules below it plus the entry, 27 rows with `tc_types` and `typecheck.mdk`.

- New row, ratification pending (Val): `tc_diag_text` (between `tc_mono` and `tc_state`: the context-free
  message text, keys and text rewrites; forced below `tc_env`, chosen against `tc_state`).
- New rows, each ratified by Val: `tc_scope` (between `tc_diag` and `tc_unify`: name visibility across
  imports, read off the envelopes, including the alias-qualified supply); `tc_foreign` (above
  `tc_decls`: extern signatures against the FFI-ABI rules); `tc_infer_records` (below `tc_infer`, above
  `tc_pat`; application and letrec are not cut); `tc_decls_variance` (below `tc_decls_types`);
  `tc_decls_types` (AST types to `Mono`, apart from declarations proper, as OCaml's typetexp and
  typedecl and GHC's Gen.HsType and TyCl are apart); and the solver cut into `tc_solve_givens`
  (the given store, below), `tc_solve_entail` (entailment as routes and instance selection),
  `tc_solve` (the goal store and the solving walks above entailment) and `tc_solve_check` (the
  checks at a boundary, above, with the write side of a binder's dictionary parameters).
- Ruling (Val, 2026-10-25/26): the registration of predicate slots, dict arity and the constraint
  tables, which the table above cut as a row of its own (`tc_solve_register`, 34 declarations), is
  merged into `tc_solve_check`. The two are the write side of a binder's dictionary parameters and
  the judgments at the binder's boundary (DICT section 4 `gen`/`gen-sig`, section 8 I1); the merged
  row holds 116 declarations in 1,861 A8 lines, under 3,000.
- Sizes are the A8 file measure: non-blank, non-comment lines of the generated file, including the
  import block, export markers, declarations and the probe sections that stay (P4-D8), with the
  fixtures that move to the sibling test taken out. Over 3,000: no row of the table; `tc_infer`
  measures 2,403 (the 64-declaration recursion plus its arm helpers), so no over-3,000 reason is owed.
  `tc_module` (2,978) and `tc_occurrence` (2,900) carry no adopted reason: a sprint that would take
  either over 3,000 stops for Val.
- The D8 exception (narrow, named): the 15 trace and probe sinks consumed by drive-level tests stay
  in their home modules in the test-only section and are imported directly by `typecheck_test.mdk`,
  with no facade; the exception ends with R35 (`docs/design/TEST-SIBLING-ACCESS-DESIGN.md`).
- `tc_mono`'s holds is reworded to "pure except for minting effect-variable ids from the
  graph-run counter"; lifting that mint is an idiom-slice option under the identity oracles.
- The alias-qualified-method family (45 declarations across `tc_env`, `tc_scope` and `typecheck`)
  has no row of its own: its declarations sit at the lowest legal layer, `tc_scope` holds 35 and
  `typecheck` keeps the pre-inference rewrite as a driver step; each header names the slice it holds,
  citing `docs/spec/language-design.md` Module System Import Details.
- The `util` flag marks 39 stdlib-shaped helpers whose placement is unchanged and which do not count
  as module API; an idiom slice replaces them with stdlib, and there is no `tc_util` module.
- Doctest placement: a doctest runs in its owning module. One that calls a name in a higher module
  moves to the sibling `*_test.mdk` of the highest module it calls; two doctests move this way
  (the `tc_env` block that calls `deKindRow0` moves to `tc_decls_test.mdk`).

*Position* says whether the graph forces the row's place (edges down, none up) or precedent
chose it where either order is acyclic. Test-only probes stay in the module whose state they
read, in a marked section exported to that module's sibling only; fixtures move to the
siblings (P4-D8). Every module gets a `<module>_test.mdk` in its sprint, with the
`typecheck_test.mdk` blocks whose subject moved plus API tests by the `write-tests` table; #3944's
exclusion of white-box tests of `unify`, `generalize`, `instantiate` and `entail` is reversed by
the split (P4-D7). A move is a source-order-preserving slice judged by identity oracles (IR
identity with a plant control, wide-corpus output identity, the LEG A multiset check, an
import-collision check, instruction counts within two percent); the idiom rewrite is a separate
slice (P4-D6, D9, D11). No `Arch-Growth-Override:` is admitted in the phase (P4-D5).

Sprints run serially under one orchestrator, extracting modules bottom-up in the Order column's
sequence, each sprint ending with its own review. Sprint 0 (the partition pre-sprint; nothing
lands) is done. The last two sprints are the exit (this document's §6 collapses to its criterion;
`types/ARCHITECTURE.md` re-derived with a spec column; `TYPECHECK-ARCHITECTURE.md` to
`archive/design/`; #4318) and the diagnostic code registry (`support/diag_codes.mdk`, one closed
type for every stage's codes pinned to `DIAGNOSTIC-CODES-DESIGN.md` by a two-way test; P4-D3b,
after the exit). Which modules each sprint extracts is set in the phase plan and its tracking
issues (milestone 42), not here; reviews run on opus where a decision is taken and sonnet where a
decided placement is executed (P4-D12).

**Exit criterion.** `types/typecheck.mdk` is the entry module and is under 3,000 code lines;
every module of the 26 `tc_*` names of the table (`tc_types`, `tc_mono`, `tc_state`, `tc_env`,
`tc_diag_text`, `tc_diag`, `tc_scope`, `tc_unify`, `tc_decls_variance`, `tc_decls_types`, `tc_decls`, `tc_foreign`,
`tc_solve_givens`, `tc_solve_entail`, `tc_solve`, `tc_solve_check`,
`tc_shadow`, `tc_effects`, `tc_occurrence`, `tc_groups`, `tc_pat`, `tc_infer_records`,
`tc_infer`, `tc_elab`, `tc_global`, `tc_module`) has a closure golden, a LEG A golden and a test
sibling; no `types.tc_*` row is in `oversize.golden` without a header reason; the largest
`types/` module is one whose header says why; `tc_diag_text`'s closure contains no inference module
(A5); IR identity against the phase base holds over the self graph.

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
| Phase 4 | #2586, ruling 8; milestone 42 | same sequencing; §6 names the twenty-five `tc_*` modules and the entry, their order and the per-module acceptance (amended 2026-10-26) |
| Phase 5 | #1398 R3 to R9, #4107 | unchanged |
| F1 to F3 (§7 amendment) | `docs/design/TEST-SIBLING-ACCESS-DESIGN.md`, style ruling R35 | added 2026-10-19 |
| none yet | M-IDENTITY, #2563 (identity-key every cross-module namespace) | No phase schedules it. Its remaining import-scope ladders are the `Sh` component of `types/` (`ARCHITECTURE.md` §3), which Phase 4's layer table places in `types/tc_shadow.mdk` (order 16); when retired they read the F1 producer. |
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
