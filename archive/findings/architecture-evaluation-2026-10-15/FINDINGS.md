# Medaka compiler architecture: evaluation against OCaml, GHC and rustc

**Status:** CLOSED RECORD. The 2026-10-15 architecture evaluation that `compiler/ARCHITECTURE.md` and `compiler/ARCHITECTURE-PLAYBOOK.md` rest on; point-in-time, kept for provenance. Companion files in this directory: `report-ocaml.md`, `report-ghc.md`, `report-rustc.md` (the three reference-compiler studies, measured on fresh clones 2026-10-14), `census-medaka.md` (the structural census of this tree at `48e36f797`) and `census/` (the re-runnable census scripts, `python3 -I census/<script>.py <repo-root> [section]`, the reference implementation for playbook action G3).

Written 2026-10-15 at main 48e36f797. Inputs: the four reports in this directory (report-ocaml.md, report-ghc.md, report-rustc.md, census-medaka.md), the in-tree architecture docs (ARCH-REVIEW, TYPECHECK-ARCHITECTURE, TYPECHECK-TARGET-ARCHITECTURE, TYPECHECK-CONTRACTS, EMITTER-ARCHITECTURE, EMITTER-TARGET-ARCHITECTURE), epics #1122, #2549, #2586, #1398, #4141, and the milestone board.

## 1. Verdict

Val's instinct is right, but the disorganization is at one grain only. In the small, the compiler is better organized than its reputation: median declaration 6 lines, zero import cycles, 7 layering violations in 994 edges, selective imports everywhere, a sound directory taxonomy, comments that are real design rationale rather than noise. What is not up to standard is the module grain: one file holds 27.5% of the compiler and 85% of its directory, the two emitters are structural twins, the same helper is defined in up to ten modules, and the process-level architecture has no artifact that lets one invocation reuse another's work.

Every mature compiler has one oversized file and regrets its global state (OCaml typecore.ml 8.9k and a TODO.md saying the typechecker is "overly complex and fragile"; GHC's DynFlags; rustc's rustc_middle hub). Medaka differs in degree and in velocity.

| | Medaka | OCaml | GHC | rustc |
|---|---|---|---|---|
| Largest file (lines) | 57,032 | 8,913 | 8,053 | 7,380 (hand-written) |
| Largest file as share of compiler | 27.5% | 5.5% | 1.35% | 0.8% |
| Typechecker: files / lines | 22 / 66,814 (one file = 85%) | 57 / 57,134 | 76 / 125,542 | ~340 / 218,969 |
| Files over 3k lines | 13 of 170 (7.6%) | 6 of 313 | 29 of 871 (3.3%) | 33 of 2,230 (1.5%) |
| Median file | 230 | 227 | 311 | 144 |
| Module-level mutable cells in the typechecker | 26 loose + 147 bundle fields | ~27 registered + ~60 refs across typing/ | ~30, scoped per module/implication/solver run | 0 global; one TypeckRootCtxt per body |
| Typecheck output | Ref cells patched into the shared AST | new Typedtree with types as fields | new HsExpr GhcTc + evidence bindings | TypeckResults side table keyed by HirId |
| Compiled interface artifact | none | .cmi (+ .cmt, .cmx) | .hi (ModIface) | .rmeta |
| Max file size rule | none (soft census) | none (.mli per module) | none | 3,000 non-comment lines, explicit opt-out |
| Internal design docs | 66 files, 40k lines, flat in compiler/ | 11 files, 657 lines + TODO.md | 2,019 source Notes + wiki | one organized guide, 40k lines, date-checked |

Growth is the alarming number. typecheck.mdk went 10.9k (Jul 1) to 19.9k (Aug 1) to 39.0k (Sep 1) to 53.0k (Oct 1) to 57.0k (Oct 14); OCaml's typecore.ml took fifteen years to grow 3.7x. The 21 sibling modules extracted from it since August total about 9.8k lines; it grew about 10k lines per month over the same period. The rearchitecture is losing a race it was not designed to run.

## 2. What the three compilers do that Medaka does not, ranked by what it would fix

1. Typecheck output is a value, not cells in the input tree. All three produce a new value (Typedtree fields; GhcTc tree plus EvBinds; TypeckResults). Medaka writes 9 Ref cells in 8 AST constructors from a post-inference stamper. This one representation choice is why the 9-step stamper order is semantic, why run and build typecheck twice, why the memo layers hold live cells and cannot be cached, why the LSP re-typechecks per hover, and why eval and lowering read a half-stamped tree. M2 (#2549, EMethodAt carries an EvId) is already aimed here. It is the most important item in the plan.
2. State scoped by lifetime. GHC: per module (TcGblEnv), per implication (tcl_lie swapped by captureConstraints), per solver run (TcSEnv). rustc: TypeckRootCtxt dies with the body. OCaml: Local_store registry plus snapshot/backtrack. Medaka: checkBodyImpl touches 93% of 118+ cells reachable from everywhere. This is #2547 unit 1 and the X component; it is also the precondition that makes any file split possible.
3. A compiled interface artifact. None of the three relies on whole-program incrementality to avoid re-typechecking the standard library; all three have a serialized post-typecheck summary (.cmi, .hi, .rmeta) loaded lazily and keyed by a fingerprint. Medaka re-typechecks the prelude in every process (about 90% of a hello-world check) and the build child redoes the parent's front end. M-CACHE (#2732) is this; prelude-first, possibly baked into the binary at build time, is the cheapest version.
4. Diagnostics as a leaf data type with rendering downstream. GHC: Tc.Errors.Types and Tc.Errors.Ppr import only Tc.Types. OCaml: closed error variants per module, renderers registered via Location.register_error_of_exn and allowed to live downstream (Includemod_errorprinter). rustc: error_reporting behind an explicit TypeErrCtxt. Medaka's withdrawn extraction (#1120) failed because its diagnostics code computes while rendering; all three say the fix is to build an error value at the raise site and render it elsewhere.
5. A sanctioned dependency-inversion mechanism. The loader forbids cycles, which is right and matches Cargo and OCaml. But OCaml breaks its genuine inversions with 18 documented forward hooks, rustc with a Providers record of function pointers, GHC with .hs-boot and a types/logic split. Medaka has none: zero module-level function-Ref hooks in the compiler and no provider record. That is why extractions keep hitting back-imports and why typecheck, both ir modules and eval import backend.private_mangle (4 of the 7 layering violations are that one node).
6. Representation facts computed once, upstream of every backend. OCaml Typeopt (297 lines) feeds Lambda's value_kind; GHC StgToCmm; rustc layout_of and fn_abi_of are shared even by Cranelift, which shares no builder code. Medaka's fact ledger (F1 to F6 landed in October, both emitters shrank about 600 lines) is the same idea reached independently; the plan record (R5, sprint #4107) finishes it. Do not attempt a shared emitter; share facts.
7. Compute-once as structure, not discipline. In rustc the only way to get typeck(def) is tcx.typeck(def), which hits the cache. Medaka's O1 fixes are pinned by no gate (#4189) and will regress. The structural answer is one memoized entry per fact plus the interface artifact (item 3).
8. Splitting by layer, not by algorithm. All three split the typechecker as data / type algebra / inference per language layer / solving / inclusion or coherence / errors / printing. Medaka's rejected split was HM-core vs dispatch, which cuts through the infer recursion. The GHC and OCaml axis is the one that works with a strict no-cycle loader.
9. A file-size norm with an explicit escape hatch. rustc's tidy fails a file over 3,000 non-comment lines unless it carries ignore-tidy-filelength; 15 of 2,230 files opt out, most of them diagnostics. OCaml and GHC have no rule but their equilibrium is the same because each new concern becomes a new module with an interface. Medaka's soft census has not changed the growth curve.
10. Three kinds of documentation kept apart. OCaml: how it works (HACKING.adoc, 83 lines for typing/), what is agreed to change (one TODO.md), what changed (Changes). rustc: the guide, MCP issues closed when done, generated API docs. GHC: Notes beside the code. Medaka mixes all three in 66 flat files, 36 of which say IMPLEMENTED in their status line: they are landed design records living next to the current maps.

## 3. What not to copy

GHC's 16k-line rewriting solver and System FC (Medaka has HM, interfaces and rows; copy the shape, not the machinery). rustc's red/green dependency graph (two years to ship, still order-sensitive ICEs; Medaka's problem is redundant work, which memoization plus interfaces solve). 79 crates (much of that is rustc's own build parallelism). Trees That Grow in full. .hs-boot files (a second source of truth agents will let drift; the no-cycle loader is a feature). OCaml's forward hooks for inference (TODO.md names global state as smell one; use hooks only for register-once rendering and tooling). Clflags-style global config. Merlin's forked typer and rust-analyzer's separate frontend (Medaka's one library shared by CLI and LSP is better; take Merlin's checkpointing). Any committee process; the do-not-relitigate register is the single-owner analogue. The tempo: GHC and rustc refactors took two to six years with dozens of contributors; Medaka has a byte-for-byte fixpoint, a three-engine differential and plentiful agent labour, so it can take larger behaviour-preserving steps, as long as each is gated.

## 4. Where Medaka is ahead

The byte-for-byte self-compile fixpoint is stricter than anything GHC runs and than rustc's optional stage-3 check (OCaml's cmpbyt bootstrap is the closest). The 346-fixture three-engine differential has no equivalent. must-fail pins are rustc's tests/crashes. Zero import cycles and zero wildcard imports across 170 modules. Small functions: nothing in llvm_emit, resolve or eval exceeds 200 lines. Comment density matches GHC's (40% vs 48%) and the comments sampled are rationale, not archaeology, though the issue-number density in typecheck.mdk (25 per 1k lines, 2.4x the rest of the compiler) shows the sprint process writing history into source.

## 5. Remedy

The rearchitecture plan (#1122, TYPECHECK-CONTRACTS.md) is the right plan. It already borrows GHC's generation / solving / evidence / reporting separation and its component model matches what the three compilers converge on. The gap is not the destination; it is that nothing stops the file from growing while the plan executes, and the plan has no cheap guards in front of it.

Three layers, cheapest first.

### 5a. Guards, independent of the rearch, each about one sprint slice

- A per-file line ratchet on typecheck.mdk alone, the shape the project already accepts for lint findings and comment register ([H-LINT-BASELINE]): the count may only fall. New typechecker code lands in new types/ modules or displaces old code. This is rustc's tidy rule applied to one file with the opt-out being the PR body. The declined hard ratchet (#2289) was a tree-wide size gate; this is a growth gate on the one file the whole plan is about.
- A hooks module in support/ (a record of function-typed Refs, filled by the driver at startup), explicitly limited to rendering, tooling and backend-fact inversions, with a gate that counts its fields. This is OCaml's 18 forward hooks and rustc's Providers. It unblocks the diagnostics extraction and lets private_mangle's two helpers move below types/ so the 4 layering violations close.
- Dependency-closure goldens (GHC CountDepsAst/CountDepsParser) for frontend/ast, types/repr, ir/core_ir and the future tc_types and tc_diag modules: the sorted transitive import closure is committed and may only shrink. A layering check pins the 7 violating edges as a count that may only fall.
- Docs: move the 36 IMPLEMENTED compiler/*.md files to an archive directory, keep one ARCHITECTURE.md per compiler subdirectory (OCaml's HACKING.adoc shape, under 100 lines each), one TODO.md per directory as the committed cleanup backlog, and treat design docs as closed issues. Rationale that explains why code is the way it is moves next to the code; the source already does this well.
- Helper dedup as a cheap Haiku sprint: 214 names defined in 2+ modules, 36 with identical bodies, letBindName in 10 modules. HELPER-CENSUS.md's plan stalled in September.

### 5b. The structural moves, in leverage order

1. Routes as a side table (M2, #2549, in flight). Give each dispatch site a stable id at resolve time, return Map SiteId Route from check, fill the Ref cells from the table during transition, then delete the cells. This removes the semantic stamper order from the tree, lets run/build typecheck once, and makes the result cacheable.
2. State by lifetime (#2547 unit 1). Classify every cell as per group, per module, per solver run or per process; per-group state becomes a record created on entry and dropped on exit. Delete each cell as it is scoped (GHC's DynFlags campaign plateaued because the god-record stayed available as a fallback).
3. Interface cache, prelude first (M-CACHE, #2732). Serialize the post-typecheck export surface with the existing s-expression codec, keyed by the existing source fingerprint plus a format version; load lazily; then reuse it across the build child, REPL lines and LSP hovers. This is also the largest single lever on Val's stated perf goal (CPU-seconds on the box).
4. Split by layer once 1 and 2 make it possible: tc_types (the 150 data types and the state records), tc_diag (error values plus renderer), the type algebra (unify, levels, generalize, instantiate), per-layer inference, solving, coherence and global checks, drivers. Each new module is a leaf whose closure golden is committed with it.
5. Finish the backend fact ledger and the plan record; track the twin count (95 today) in arch-census and expect it to fall as each fact lands.

### 5c. Process

Every mature compiler lands architecture as sequences of 2 to 10 behaviour-preserving PRs, each green, with the old and new paths side by side behind a flag and the old path deleted last. Medaka's sprint machinery already does this per sprint. What it lacks is the rule that a sprint touching the typechecker must leave the file no larger than it found it, which is the only mechanism in any of the three compilers that keeps a hot file from becoming the compiler.

## 6. Sources

report-ocaml.md, report-ghc.md, report-rustc.md, census-medaka.md in this directory; the clones under ocaml-src/, ghc-src/, rustc-src/; the census scripts (census.py, docs.py, ent.py, growth.py). Repo: archive/design/ARCH-REVIEW.md, archive/design/TYPECHECK-ARCHITECTURE.md, compiler/TYPECHECK-TARGET-ARCHITECTURE.md, compiler/TYPECHECK-CONTRACTS.md, compiler/EMITTER-ARCHITECTURE.md, compiler/EMITTER-TARGET-ARCHITECTURE.md, .claude/skills/architecture/SKILL.md; issues #1122, #2549, #2586, #2547, #2732, #1398, #4141, #4189, #2289.
