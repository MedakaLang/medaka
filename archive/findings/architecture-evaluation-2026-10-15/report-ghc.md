# GHC architecture vs Medaka: a sourced comparison

**Status:** CLOSED RECORD. Point-in-time study of GHC at `8ddbc6f9b378` (2026-10-14); its path citations are into that tree, not this one.

(Saved by the orchestrating session from the GHC study agent's hand-back, 2026-10-15. GHC numbers measured against github.com/ghc/ghc commit 8ddbc6f9b378 with a blobless sparse clone of compiler/; see ghc-wc2.txt, ghc-tests.txt, paper/mod.txt in this directory.)

## §1 Facts, per axis

### 1. Source tree organization and module granularity

compiler/GHC/ has one hierarchy per component. Measured subtree sizes (.hs files / lines):

| Subtree | Files | Lines | Role |
|---|---:|---:|---|
| GHC/Tc/ | 76 | 125,542 | typechecker (+13 .hs-boot) |
| GHC/Core/ | 82 | 95,388 | Core IR, optimiser, Lint |
| GHC/CmmToAsm/ | 82 | 46,688 | native code generators |
| GHC/Types/ | 68 | 33,116 | shared vocabulary |
| GHC/Driver/ | 73 | 27,410 | session, pipeline, flags |
| GHC/HsToCore/ | 35 | 25,147 | desugarer |
| GHC/Iface/ | 25 | 20,497 | interface files, recompilation |
| GHC/Cmm/ | 40 | 19,828 | Cmm IR and passes |
| GHC/Rename/ | 13 | 19,492 | renamer |
| GHC/StgToCmm/ | 23 | 14,492 | shared codegen |
| GHC/Hs/ | 18 | 13,839 | GHC half of the AST |
| GHC/Parser/ | 15 | 13,817 | plus Parser.y 4,818, Lexer.x 3,725 |
| GHC/StgToJS/ + GHC/JS/ | 41 | 16,668 | JavaScript backend |
| GHC/Unit/ | 38 | 12,385 | packages, module graph |
| GHC/Stg/ | 22 | 7,920 | STG IR |
| Language/Haskell/Syntax/ | 19 | 8,047 | pass-agnostic AST (TTG) |

The hierarchy came from ticket #13009, GHC 8.10 to 9.0 (Henry, Ericson, Young, *Modularizing GHC*, 2022). Motivation quoted: "we couldn't even state a rule such as 'modules of the Domain Layer mustn't import modules of the UI or Application Layers' because we couldn't identify which layer a module belonged to."

Typechecker granularity: 76 modules (Gen 16, Solver 10, Types 10, Utils 8, Errors 6, Deriv 5, TyCl 5, Instance 4, Zonk 4, top level 8). Largest Tc files: Tc/Errors/Ppr.hs 8,053; Tc/Errors/Types.hs 7,296; Tc/TyCl.hs 6,017; Tc/Utils/Unify.hs 5,241; Tc/Gen/HsType.hs 4,948; Tc/Solver/Equality.hs 3,338; Tc/Module.hs 3,334; Tc/Gen/Splice.hs 3,154; Tc/Errors.hs 3,044; Tc/Gen/App.hs 2,515; Tc/Utils/TcMType.hs 2,460; Tc/Solver/Monad.hs 2,342; Tc/Gen/Expr.hs 1,808. Subtotals: Gen 24,160, Utils 17,351, Errors 16,817, Solver 16,407. The two largest typechecker files are diagnostic data and rendering, not inference logic.

Whole compiler: 871 source files, 594,344 lines, 62 .hs-boot. Files over 1k: 191; over 2k: 76; over 3k: 29; over 5k: 6; over 10k: 0. Median 311; p90 1,808. Largest file is 1.35% of the compiler; largest Tc file is 6.4% of the typechecker.

Medaka, same measurement: 170 files, 207,683 lines. Over 1k: 36; over 3k: 13; over 5k: 7; over 10k: 3. Median 227. typecheck.mdk is 27.5% of the compiler and 85% of compiler/types/. Medaka's median file is smaller than GHC's; the problem is the tail.

Comment density: GHC Tc/ about 47.6% comment lines; Medaka typecheck.mdk about 40%. Not materially different.

### 2. IR pipeline

| IR | Typed? | Boundary checker |
|---|---|---|
| HsSyn GhcPs | no | parser |
| HsSyn GhcRn | no | renamer |
| HsSyn GhcTc | yes | zonk produces the final tree |
| Core (System FC) | yes, explicit coercions | Core Lint (GHC/Core/Lint.hs, 3,996 lines) |
| STG | runtime reps | Stg Lint (606 lines) |
| Cmm | machine types | Cmm Lint (332 lines) |

Trees That Grow: one AST indexed by pass; extension fields and constructors (XXExprGhcTc: WrapExpr HsWrapper, ExpandedThingTc, ConLikeTc, HsTick, HsBinTick). The pass-agnostic AST imports nothing from the compiler; a golden (testsuite/tests/count-deps/CountDepsAst.stdout) pins its closure at 19 modules.

The typechecker never mutates its input tree; it returns a new HsExpr GhcTc. Elaboration: HsWrapper (a small composable language around an expression) and evidence bindings. At a call site instCall returns mkWpEvApps evs; each ev is a fresh evidence variable emitted as a Wanted (Instantiate.hs:357-380; emitWanted TcMType.hs:256). The solver later produces ev = dictionary-expression bindings into an EvBindsVar (one IORef per implication, Evidence.hs:734). The AST refers to evidence by name; the solver's answer lives in a separate binding map. Only meta type variables get filled in, and zonk resolves those.

Medaka contrast: in frontend/ast.mdk, 8 Expr constructors carry 9 mutable cells (5 Ref Route in EBinOp, EUnOp, ENumLit, EWideLit; 4 Ref String in EFieldAccess, ESlice, EIndex, ERecordUpdate). One AST type with no pass index serves parse, resolve, typecheck, eval and lowering.

### 3. Typechecker architecture

TcM = TcRn = IOEnv (Env TcGblEnv TcLclEnv). TcGblEnv has 62 fields, 23 mutable (mostly TH, usage tracking, counters). TcLclEnv has 3 mutable cells: tcl_usage, tcl_lie (WantedConstraints), tcl_errs. TcSEnv has tcs_count, tcs_inerts, tcs_worklist, EvBindsVar. Each meta variable owns one IORef. So about 30 named cells plus one per meta variable. The difference from Medaka's 118 cells is scope and shape: per module (TcGblEnv), per scope swapped by the monad (tcl_lie via captureConstraints), per solver invocation (TcSEnv via runTcS). No cell lives for the whole run and is read by inference to steer control flow, apart from coarse error checks.

Generation (GHC.Tc.Gen.*, 16 modules; Unify does eager unification with deferral) never resolves class constraints; it emits WantedConstraints (simple plus implication tree, Constraint.hs 2,802 lines). Levels gate unification and generalisation. Solving (GHC.Tc.Solver.*, 10 modules, 16,407 lines) is a worklist and inert-set engine with separate modules for Equality, Dict, Irred, FunDeps, Rewrite, Default.

Top-level sequencing (Tc/Module.hs): tcRnSrcDecls collects lie; simplifyTop = solveWanteds then tryDefaulting; tryDefaulting applies four ordered strategies each followed by re-solving (Default.hs:147-157); reportUnsolved turns residuals into diagnostics (or deferred runtime errors); zonkTopDecls is the single writeback pass. GHC does have an ordered post-inference phase. It differs from Medaka's 8 pending channels and 9-step stamper in three ways: one data structure; the general solver re-runs to fixpoint after each policy step (Note [Top-level Defaulting Plan]); output is evidence bindings, not writes into the AST.

### 4. Diagnostics

Structured messages (GhcMessage/PsMessage/TcRnMessage) from MR !4798 (Di Napoli), shipping around 9.2/9.4 (first release UNVERIFIED). Converting TcRnUnknownMessage sites took years (#20117 to #20119). Error codes GHC-NNNNN via diagnosticCode (#21684), GHC 9.6, indexed at errors.haskell.org; codes assigned in one module through a type family, never reused.

Current: GHC/Types/Error/Codes.hs (1,489 lines) assigns about 696 codes; TcRnMessage has about 300 constructors; data in Tc/Errors/Types.hs, rendering in Tc/Errors/Ppr.hs. Structural point: Ppr.hs imports only GHC.Tc.Errors.*, GHC.Tc.Types.*, GHC.Tc.Utils.TcType. Diagnostics are a leaf; inference constructs values, a separate module prints them.

Errors as control: most type errors stay in WantedConstraints as insoluble and are reported after solving. Coarse gating only (failIfErrsM, ifErrsM, checkNoErrs, askNoErrs: 74 uses in 19 files), at phase boundaries.

### 5. Backend sharing

Shared middle: Core, STG, Cmm. Done once: GHC.StgToCmm (closure layout, info tables, calling conventions, heap/stack checks, primops); GHC.Cmm.* passes. Per backend: instruction selection and register allocation (NCG), textual LLVM (CmmToLlvm 3,948 + Llvm 2,076), C printing.

Backend is an abstract type with properties (GHC/Driver/Backend.hs, 943 lines): "Conditioning client code on the identity or name of a back end is Not Done." Per-component configuration records (CmmConfig, StgToCmmConfig, NCGConfig) built from DynFlags in GHC/Driver/Config/* (29 modules); #17957.

Wasm backend (Nov 2022, GHC 9.6): another NCG target consuming Cmm, CmmToAsm/Wasm* 5 files, 2,952 lines; shared changes were build system, RTS POSIX avoidance, driver logic, and a CFG-to-structured-control-flow algorithm (Ramsey, ICFP 2022). JS backend (MR !9133, Nov 2022) branches at STG not Cmm (StgToJS 13,313 + JS 3,355). Lesson: the shared IR level is chosen per backend family.

### 6. Driver and incrementality

HscEnv now 10 fields. ModSummary, ModIface (.hi). Recompilation avoidance (GHC/Iface/Recomp.hs, 2,055 lines) compares per-declaration hashes, export hash, flag hash, and a usage list of which fingerprints of which imports were consumed. Importers never re-typecheck dependencies; they load ModIface and lazily rebuild TyThings (GHC.IfaceToCore). base ships .hi files, so the Prelude is never re-typechecked. -fwrite-if-simplified-core (GHC 9.6) stores Core in .hi to restart after simplification. Modes: --make (in-process graph, home package table) vs one-shot. HLS/ghcide uses the GHC API under its own incremental graph (details UNVERIFIED). *Modularizing GHC* §1 names the batch-vs-IDE tension directly.

### 7. Encapsulation

Export lists everywhere; abstract types common. .hs-boot files break cycles: 62 in compiler/, 13 in Tc/. Types/logic split: GHC.Tc.Types.* (10 modules) and Tc.Errors.Types hold data; logic modules import those, not each other. Dependency-closure goldens: CountDepsParser.stdout (311 modules today; 275 of 593 in May 2022) and CountDepsAst (19) fail when the closure grows. Notes: 2,172 Note headers (2,019 distinct), 5,426 "See Note [" references in compiler/.

### 8. Testing

testsuite/tests/: 22,498 files, 113 areas, 586 all.T manifests; about 11,852 .hs sources, 4,578 .stderr goldens, 2,692 .stdout goldens; should_compile 4,878 / should_fail 4,416 / should_run 3,120 paths; typecheck/should_fail alone 1,513 files. Every test compiles with -dcore-lint -dstg-lint -dcmm-lint (hadrian RunTest.hs:54). Perf tests: 63 collect_compiler_stats('bytes allocated', N) calls with percent tolerances; baselines in git notes (UNVERIFIED). Bootstrap: stage1 from installed stage0, stage2 from stage1; CI does not routinely check stage2 == stage3 byte-identical (UNVERIFIED); determinism via deterministic uniques (#12935), -fobject-determinism in 9.12, LLVM determinism incomplete (#25274). Medaka's byte-for-byte fixpoint is stronger than anything GHC runs.

### 9. Documentation and governance

ghc-proposals covers language and major user-visible behaviour; "changes to the GHC API, the plugin API, or compiler internals" go through MR review. Internals are decided by maintainers in review, not a committee. Large refactors landed as sequences of behaviour-preserving MRs: module hierarchy (#13009), component configs (#17957, a dependency-ordered checkbox roadmap), structured diagnostics (!4798 then module-by-module), solver split (!10076, #23070, pure refactor; later "Add the SolverStage monad" merged Canonical and Interact into Solve), TTG (multi-year). Correction: GHC.Core.SimpleOpt is a Core optimiser, not a solver rewrite.

### 10. Regrets and pain points

DynFlags god-record: 145 fields in 2022, about 169 now; mentions went 1,696 (8.6) to 802 (9.2) to 841 now; the campaign halved then plateaued. unsafeGlobalDynFlags (2012 "ugly kludge") caused bugs for years. HscEnv caches leak into the domain layer. Parser depends on 311 modules; "many new features have been force-fitted into the existing code without proper redesign." CI friction blocks custodial work. Notes "are better at explaining awkward or confusing things than laying forth how code ought to be." No GHC rule on file size found (UNVERIFIED); modularity work targets coupling, not length; observed equilibrium median about 300, about 3% of files over 3k, nothing over about 8k.

## §2 What GHC does that Medaka does not (ranked)

1. Evidence by name, answers in a side table (vs collect-then-patch Ref Route). Under GHC's shape the order of solving cannot affect the tree, only the binding map.
2. One constraint data structure with scoped accumulation (vs 8 pending channels whose interactions are encoded in step order).
3. State lifetimes enforced by the monad (vs 118 run-wide cells reachable from everywhere; hence checkBodyImpl touching 93% of state).
4. Diagnostics as a leaf data type (vs an extraction needing 36 of 61 back-imports because the diagnostics code computes while rendering).
5. A types/logic module split as the cycle breaker (hs-boot is secondary).
6. Interface files and fingerprint recompilation (vs the prelude re-typechecked per process).
7. Lint at every IR boundary on every test (vs a validator arm still being grown).
8. Backends ask properties of a shared lower IR (vs 89 twin functions; the fact ledger plus plan is the same idea).
9. Dependency-closure goldens (vs a soft arch-census).
10. Notes in the code (vs about 66 flat design docs that drift).

## §3 What NOT to copy

The size of the solver (GADTs, families, coercions); System FC and coercion evidence (Medaka needs a Core validator, not FC); three IRs below the AST (one validated Core plus plan is right for two backends and a strict language); .hs-boot files (keep the no-cycles loader, fix cycles with the types/logic split); Trees That Grow in full (Medaka needs typecheck output as a separate value, not a pass-indexed AST); dual one-shot/--make modes, plugins, Backpack; the proposals committee; GHC's refactoring tempo (2 to 6 years per refactor; Medaka has plentiful agent labour, one reviewer and a strong whole-compiler oracle, so can afford larger, faster mechanical moves); Notes as prescriptions (agents need prescriptions; keep a few target docs, move rationale into Notes).

## §4 Recommendations

R1. Make typechecker output a value, not cells in the AST: stable SiteId per dispatch site at resolve time; checker emits "site needs evidence for C" as data; solving produces Map SiteId Route returned from check; consumers look up by SiteId. Migrate one constructor at a time (EBinOp first), filling the cell from the table during transition. Precedent: instCall/emitWanted, EvBindsVar, zonkTopDecls.

R2. Collapse the 8 pending channels into one Wanted type and a types/solve.mdk that inference does not import; encode the 9-step order as an explicit policy with general re-solving after each step. Precedent: WantedConstraints, Solver split from Gen, simplifyTopWanteds, !10076 landing as a pure refactor.

R3. Split typecheck.mdk along types / logic / rendering first, not HM core / dispatch: (a) tc_types.mdk with the 150 data types and state-bundle record types; (b) tc_diag.mdk with data TcMessage and a renderer importing only (a) and repr.mdk; (c) logic modules import (a) and construct (b). Remove the import of backend.private_mangle by moving isReservedCtor and mangledName lower. Precedent: GHC.Tc.Types.*, Tc.Errors.Types, Tc.Errors.Ppr, TcRnUnknownMessage catch-all migration.

R4. Scope state by lifetime: classify each PerRun cell (per group, per module, per solver run, per process); replace bundles with values created on scope entry; Toggles become an immutable TcConfig. Delete each cell as soon as scoped (DynFlags counter-lesson). Precedent: TcGblEnv, captureConstraints, runTcS, GHC.Driver.Config.*.

R5. Interface cache (serialise each module's typechecked export surface with a fingerprint; prelude first, possibly baked into the binary; reuse across build child, REPL, LSP; invalidate on used-import fingerprints), dependency-closure goldens per layer root (ast, tc_types, tc_diag, core), and move rationale into Notes. Precedent: ModIface/.hi, Iface.Recomp, CountDeps*, 2,019 Notes.

Sources: GHC tree at commit 8ddbc6f9b378; Henry, Ericson, Young, Modularizing GHC (2022); GHC issues #13009, #17957, #20117-#20119, #21684, #23070, #12935, #25274; MRs !4798, !9133, !10076; Tweag wasm post (2022-11-22); Well-Typed interface-files-with-core (2023-02); ghc-proposals README; Haskell Discourse JS backend announcement.
