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

## 1. Where we are (measured 2026-10-18 at `c98fa3894`, the end of Phase 1)

Re-derive with `make arch-census` and the census scripts archived with the evaluation at
`archive/findings/architecture-evaluation-2026-10-15/census/` (run as
`python3 -I census/census.py <repo-root> <section>`; `census-medaka.md` beside them
records the method and the full tables).

| Measure | Value |
|---|---|
| Compiler source, non-test | 180 modules, 213,087 lines; median 234, p90 2,257 |
| `types/typecheck.mdk` | 57,406 lines (30,997 code, 22,662 comment); 27% of the compiler; 81% of `types/` |
| Its growth during Phase 1 | +400 code lines (30,597 to 30,997) under 16 `Arch-Growth-Override:` commits, every one a Phase 1 sprint; about 10,000 lines a month before Phase 0 |
| Modules over 3,000 code lines | 8 (`test/arch_goldens/oversize.golden`); 2 state a reason in their header (`frontend/resolve.mdk`, `tools/test_cmd.mdk`) |
| Module-level `= Ref` cells | 108 in 28 modules (`test/arch_goldens/cells.golden`, unchanged since Phase 0); typecheck 26 plus 159 fields in 4 bundles (`PerRun` 88, `GraphRun` 30, `DriverState` 27, `CrossRun` 14) |
| Import graph | 1,088 intra-compiler edges, 0 cycles, 3 layering violations (`layering.golden`) |
| llvm_emit / wasm_emit twins | 93 named pairs (`twins.golden`) |
| Identical bodies in 2+ modules | 0 (pinned empty by `dupbodies.golden`) |
| `lookupAssoc` call sites | 195 in 24 modules (87 in typecheck) |
| Prelude cost | re-parsed and re-typechecked per process, about 90% of a hello-world `check` (as of Oct 14; the stage counts are pinned by `stage_counts.golden`) |
| CPU per verb, Phase 0 end to Phase 1 end | `check`/`run`/`build` of a value `main` 0.16/0.16/0.71 s to 0.07/0.09/0.52 s; `test stdlib/list.mdk` 1.86 s to 1.41 s; `check` of the 72-module CLI graph unchanged within noise (17 to 20 s, either binary on either tree) |
| Design docs in `compiler/` | 21 files, 19,626 lines (the keep list) |

Open milestones this plan draws on (2026-10-18): M-PUBLISH (1 open), M-PIPELINE (1),
M-CACHE (5), M-BOUNDARIES (3), M-IDENTITY (11); run-once O2 (2), O3 (2), O4 (8), O5 (5).

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
| **G3** | Architecture goldens | 2026-10-15 (P0-D3, P0-D7, P0-D8): `test/arch_boundaries_test.mdk` pins layering, cells, hooks fields, three closures, twins and identical bodies under `test/arch_goldens/`. #4203, PR #4215. |
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
- Lowering and eval still read the installed evidence table rather than `CheckedProgram`
  (the emit path remaps it in place after mangling). A2's "consumers read the value" half is
  therefore unchecked: Phase 2 **S4** (#2705).
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

## 4. Phase 2: state by lifetime (A3)

This is component X: `PerRun`'s 88 fields and `resetState` (#2547's three units and #2548
landed 2026-09-03/04). It is the precondition of the file split (ruling 8). Whether it is
also the precondition of the interface artifact is what S1 decides (see the 2026-10-18
amendment below).

| Id | Action | Mechanism | Acceptance | Size | Needs |
|---|---|---|---|---|---|
| **S1** | Classify every cell | A table, committed in `types/ARCHITECTURE.md`, assigning each of the 26 loose cells and 159 bundle fields (`PerRun` 88, `GraphRun` 30, `DriverState` 27, `CrossRun` 14) a lifetime: process, graph, module, group, solver run. Fields whose lifetime no one can state are listed as such. The table also marks which cells a loaded `ModuleInterface` would have to fill, which is the input to the ordering decision below. | The table covers every cell (G3's count is the denominator). | slice | G3 |
| **T1** | The data leaf, pulled forward from Phase 4 | `types/tc_types.mdk`: the 150 `data` declarations and S1's state records move out of `typecheck.mdk` into a leaf with a closure golden that contains no inference module. No state is threaded; this is the one Phase 4 extraction that needs nothing from S2. | `typecheck.mdk` falls by the moved lines; `closure.types.tc_types.golden` pinned; fixpoint; LEG A additive-only. | slice | S1 |
| **S4** | Consumers read `CheckedProgram` | `core_ir_lower`, `eval` and the emit path read evidence, dispositions and runtime types from the `CheckedProgram` the drive returned, not from the installed tables; the in-place remap after mangling becomes a remap of the value. Closes A2's second half. | A2's check gains "no reader of an installed table outside `types/`" as a boundary pin; two-arm IR identity over the engines corpus. | sprint | S1, V2 (#2705) |
| **S2** | Per-group state becomes an argument | A `GroupCtx` record created when `processSCC` enters a group and dropped when it leaves, holding the pending channels and the per-group inference state; `checkBodyImpl` and `infer` take it as a parameter. Threading is done group-at-a-time, never all 25 arms at once; a shim reads the bundle while a region is unmigrated. | `PerRun` field count falls as fields move (G3 pins it); byte-identical goldens; fixpoint; the M2 instruction-count instrument stays within its soft budget. | arc | S1, V1 |
| **S3** | Per-module and per-graph state become records with owners | `ModuleCtx` minted by the module worker, `GraphCtx` by the graph driver; `resetState` is deleted because there is nothing ambient to reset; `Toggles` becomes an immutable `TcConfig` built once by the driver. | `grep -cE "^[a-z][A-Za-z0-9_']* *= *(Ref|newRef)" compiler/types/typecheck.mdk` is 0 outside interners; `resetState` does not exist; the memo layers no longer snapshot and reinstall mutable state. | sprint | S2 |

**Exit criterion.** Zero module-level cells in the typechecker outside interners; every
cell's lifetime is the record that holds it.

**Amended 2026-10-18 (Phase 1 wrap): the order of Phases 2 and 3.** S1 runs first, as one
slice. Then Phase 3's C1 and C2 run before S2, unless S1's table shows that a loaded
interface would have to fill cells beyond the published value's own tables; in that case
S2 and S3 run first and C1 waits. The reason: C1's dependency is V2 (its Needs column), not
Phase 2; Phase 3 is the stated perf lever, and Phase 1's measured CPU change on the 72-module
check was nil; S2 is the riskiest arc in the plan and should not gate the lever by default.
T1 runs beside either order. Phase 4 proper still waits on S2 (ruling 8).

---

## 5. Phase 3: the interface artifact (A7)

This is M-CACHE (#2732) plus run-once O3 and O5. It is also the single largest lever on
the box's CPU-seconds, the stated perf goal. Under the 2026-10-18 amendment it starts
after S1 rather than after Phase 2.

| Id | Action | Mechanism | Acceptance | Size | Needs |
|---|---|---|---|---|---|
| **C1** | `ModuleInterface` codec | Serialize a module's published export surface (schemes, interfaces, instances and their dispositions, the importer-visible evidence rows, declared effects) with a codec in the style of `ir/core_ir_sexp.mdk`, with a format version and the module's source fingerprint, the compiler fingerprint, the instance-environment key the contract requires (§5) and the IO join of the selected target profile (D7: the join's atom list, not the profile's name, so profiles with the same join share an entry). | Round-trip prop: decode (encode x) equals x for every stdlib module; a changed instance environment invalidates; an interface written under one join is never loaded under another, shown by a two-profile test over an unsigned binding whose type differs between them (the open-tail case in D7). | sprint | V2 |
| **C2** | The prelude ships pre-checked | At `make medaka`, the prelude's interface file is produced beside `stdlib/core.mdk`, keyed by the source fingerprint the binary bakes; the loader resolves it from `exeDir` as it resolves `stdlib/` and prefers it when the fingerprint matches (D6, ruled: shipped files, not baked). Every verb loads it instead of re-checking `core.mdk`; the same step then covers every stdlib module. Files are content-addressed per (module, IO join) (D7): `make medaka` produces the full join and the playground's (`wasmgc/browser-worker`), joins whose interfaces are byte-identical share one file, and any other join falls back to a full check. | G6's pins show zero prelude typecheck drives per process; hello-world `check` instruction count falls by the measured prelude share; interface-on versus interface-off differential over the engines corpus is identical; a mismatched fingerprint falls back to a full check and says so on stderr. | sprint | C1 |
| **C3** | Imports load interfaces | The loader consults the interface cache for every user import whose fingerprints match, falling back to a full check; the LSP, REPL and `medaka test` parent reuse it within a session; `build`'s parent hands the artifact to the child (D4, step two). | Multi-module `check` of `medaka_cli.mdk` re-typechecks only changed modules; the REPL's per-line drive count is 1; `build` parent plus child typecheck the graph once; the Phase 1 exception rows owned here (`test_probe`, `test_doc_native`, `test_doc_eval`, `test_docimp_eval`) fall to 1 because the doctest graph and the native child load the parent's interface instead of re-checking. | sprint | C2, V3 |

**Exit criterion.** Nothing proven in one process is re-proven in the next for an
unchanged input; the prelude is checked at build time only.

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
| **B1** | The Plan record (R5). **Landed 2026-10-14** (sprint #4107, PR #4110): `backend/emit_plan.mdk`'s `EmitPlan`, carrying its `target`; `lowerProgramEmit` takes no backend. R5's reachable-extern-requirements field is not on it yet; T4's `js/` lowering (#3672) waits for that field. | `lowerProgramEmit` has no backend parameter; `WasmEmitInput` carries the four facts it lacked. |
| **B2** | F7 capability manifest and the remaining ledger rows. | Each row's L7 hand-derived fixture; the validator arm observed red. |
| **B3** | Twin retirement | G3's twin count falls with every fact that lands; a PR that adds a twin says why. |
| **B4** | Validators on every test | `core_validate` runs before either emitter writes, in every engines fixture, not only in its own gate. |

---

## 8. Mapping to the existing plans

| Playbook | Existing owner | Relationship |
|---|---|---|
| Phase 0 | epic #4206, milestone `Architecture: Phase 0 (the guards)`: G1 #4200, G2a #4201, G2b #4202, G3 #4203, G4 #4204, G5 #4205, G6 #4189 | adds the guards no existing plan has |
| Phase 1 V1, V2, V3 | milestone `Architecture: Phase 1 (output is a value)`; #2549 phase 2, M-PUBLISH (#2544, #4053), M-PIPELINE (#2874), run-once #4151, #4152, #4154, #4160, #4157, #3901, #3902 | landed 2026-10-18; residuals S4 (#2705), #4279, #4282 |
| Phase 2 | component X (`PerRun`, `resetState`); #2547 and #2548 landed 2026-09-03/04; S4 is #2705; T1 is #2586's first leaf | same work; this document adds the cell-lifetime table and the exit grep |
| Phase 3 | M-CACHE #2732, run-once O3 (#4160, #3902) and O5 (#4169 to #4172, #3903) | same work; prelude-first ordering and D6 |
| Phase 4 | #2586, ruling 8 | same sequencing; this document names the layer axis and the per-module acceptance |
| Phase 5 | #1398 R3 to R9, #4107 | unchanged |
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
