# rustc architecture vs Medaka: a sourced comparison

**Status:** CLOSED RECORD. Point-in-time study of rustc at `701ce39ddc3b` (2026-10-14); its path citations are into that tree, not this one.

(Saved by the orchestrating session from the rustc study agent's hand-back, 2026-10-15. Measured against rust-lang/rust HEAD 701ce39ddc3b with a sparse checkout of compiler/, src/tools/tidy/src, src/doc/rustc-dev-guide/src and tests/crashes, at scratchpad/rustc-src/rust. DG = rustc-dev-guide.)

## Headline findings

1. rustc has the same shape as Medaka: it collects deferred work and drains it in an epilogue whose order matters. typeck_with_inspect (rustc_hir_typeck/src/lib.rs ~L214-265) runs about 12 ordered steps after the main walk and keeps 7 deferred_* queues, with inline justifications ("we check casts after fallback for backwards compatibility"). The structural differences: the queues live in a per-body struct (TypeckRootCtxt) created and dropped per typeck query, not module-level cells; obligations are one data type with one fixpoint engine, not 8 channels; results are written once by writeback.rs into a side table (TypeckResults) the query returns, nothing is patched into the tree.
2. File size is an enforced norm: tidy fails any file over 3,000 non-comment lines unless it carries `// ignore-tidy-filelength` (src/tools/tidy/src/style.rs:42, :692). 15 of 2,230 compiler files opt out; the largest hand-written file is 7,380 lines and is diagnostics code. Medaka's typecheck.mdk (about 34k non-comment lines) is roughly 11x the limit.
3. rustc's type system is about 3.3x Medaka's in lines, spread over about 340 files; Medaka's is one file holding 85% of compiler/types/.
4. "Compute once" is built in only from HIR onward; lexing, parsing, expansion and resolution are still whole-program. What makes std free is not red/green incrementality but .rmeta crate metadata, a much smaller mechanism and the right first target for Medaka.
5. rustc spent 2017-2026 retrofitting queries and is still changing course: in Feb 2026 rustc_query_system was dissolved into rustc_middle (PR #152636) because the abstraction layer was no longer worth its cost. A central hub plus a single registry file is accepted practice.

## §1 Facts per axis

### 1. Source tree and crate granularity

| metric | rustc compiler/ | Medaka compiler/ |
|---|---|---|
| units | 79 rustc_* crates | 10 dirs, 170 files |
| total lines | 883,785 (2,230 .rs) | 207,683 |
| median file | 144 | 227 |
| p90 / p99 | 1,042 / 3,251 | n/a |
| files > 3k | 33 (1.5%) | 13 (7.6%) |
| files > 5k | 7 | 7 |
| largest | 9,125 (generated), then 7,380 | 57,032 |
| comment lines | 15% | typecheck.mdk 40% |

Largest crates: rustc_middle 66.1k, rustc_trait_selection 50.9k, rustc_hir_typeck 49.9k, rustc_hir_analysis 40.8k, rustc_borrowck 36.7k, rustc_mir_transform 35.2k, rustc_parse 33.0k, rustc_codegen_llvm 31.1k, rustc_codegen_ssa 30.7k, rustc_resolve 29.7k (14 files), rustc_lint 26.1k.

Largest named files: rustc_resolve/src/late.rs 5,969; rustc_hir/src/hir.rs 5,315; rustc_hir_typeck/src/method/suggest.rs 5,043; rustc_borrowck/src/diagnostics/conflict_errors.rs 5,014; rustc_ast/src/ast.rs 4,533; rustc_parse/src/parser/expr.rs 4,328; rustc_hir_typeck/src/expr.rs 3,988; rustc_hir_analysis/src/hir_ty_lowering/mod.rs 3,951; traits/select/mod.rs 3,112; ty/context.rs 2,979. Of the 15 tidy opt-outs, 9 are diagnostics or suggestions code.

Typechecker family (hir_analysis + hir_typeck + infer + trait_selection + next_trait_solver + type_ir + middle/{ty,traits,infer}): 218,969 lines in 340 files, about 13% comments. Error reporting alone (trait_selection/src/error_reporting) is 24,343 lines; old selection engine 6,078; new solver 12,570 plus 2,598 glue. Medaka compiler/types/ non-test is 66,814 lines, typecheck.mdk 85% of it.

### 2. IR pipeline

Token stream, AST, expansion and resolution, HIR (desugared, immutable, HirId = (OwnerId, ItemLocalId)), THIR (fully typed, method calls and auto-derefs explicit; feeds pattern analysis and MIR building), MIR (typed CFG), ty::Ty interned in TyCtxt arenas.

Boundaries: side tables instead of annotations. Body typeck returns ty::TypeckResults (typeck_results.rs, 943 lines, 27 fields, each an ItemLocalMap keyed by the HIR node's local id). type_dependent_defs ("Resolved definitions for <T>::X associated paths and method calls, including those of overloaded operators") is the direct analogue of Medaka's dispatch route, which Medaka writes into a Ref Route cell inside the AST node. MIR has phases (MirPhase: Built, Analysis, Runtime); pass_manager.rs panics on backward transitions, runs validate.rs (1,717 lines) after every pass under -Zvalidate-mir and unconditionally on entering Runtime(Optimized). Crates act as walls: IR data types live in rustc_middle; 32 of 79 crates depend on it.

### 3. Typechecker architecture

Item level (rustc_hir_analysis: collect, coherence, wfcheck, hir_ty_lowering) and body level (rustc_hir_typeck) are separate crates; item facts are queries (type_of, predicates_of) so body inference never re-derives them. rustc_infer (13.5k): InferCtxt with ena unification tables, snapshots (probe, commit_if_ok, rollback_to), regions solved at the end, tainted_by_errors.

State scope: one TypeckRootCtxt per typeck root ("Data shared between a typeck root and its nested bodies"), owning the InferCtxt, the in-progress TypeckResults, the fulfillment_cx and 7 deferred queues (sized obligations, call resolutions, cast checks, transmute checks, offload checks, asm checks, repeat expr checks). Nothing outlives the query except the returned TypeckResults. Only TyCtxt (interners, arenas, query caches) is shared across bodies.

Pending obligations: one type, PredicateObligation, registered into a TraitEngine (register_predicate_obligation, try_evaluate_obligations, evaluate_obligations_error_on_ambiguity). Old impl: fulfill.rs 1,085 lines over obligation_forest 742; new: solve/fulfill.rs 414. Typeck calls select_obligations_where_possible opportunistically during the walk and again in the epilogue; progress comes from a generic fixpoint, not a hand-ordered drain per kind.

Ordered epilogue (lib.rs ~L214-265): check_repeat_exprs; opaque uses; type_inference_fallback; check_casts; select; closure_analyze; drain deferred_sized_obligations; select; opaque uses; drain_stalled_coroutine_obligations; report_ambiguity_errors (skipped if tainted); check_asms; resolve_type_vars_in_body (writeback). Order sensitivity documented inline. Writeback (1,097 lines): "all of the replacement happens at the end ... which creates a new TypeckResults which doesn't contain any inference variables."

Method resolution separates probe (probe.rs 2,760, returns a cacheable Pick with no inference variables) from confirm (confirm.rs 836, side-effecting), with suggestions in a third file (suggest.rs 5,043).

New trait solver: started late 2022, stabilized for coherence only in Rust 1.84 (Jan 2025), not stabilized globally as of the 2026 goals; written generically over an Interner (rustc_next_trait_solver + rustc_type_ir), which is why rust-analyzer can share it.

### 4. Diagnostics

Diagnostics are values: DiagCtxt is the session sink; 1,765 #[derive(Diagnostic)] structs vs 153 remaining struct_span_code_err! sites. rustc retreated from Fluent translation: zero .ftl files remain, messages are inline; DG says Fluent "causes some friction", "pending a redesign", "we are not mandating usage" (issue #132181). 518 Exxxx.md error-code docs. Cascade suppression is typed: ErrorGuaranteed is a zero-sized token only error emission can construct (922 uses); Ty::new_error(tcx, guar) (152 call sites) is a poison type; span_delayed_bug (203 sites) means "reachable only if an error was already emitted; ICE at the end otherwise". Recovery continues through lowering; typeck taints the InferCtxt and suppresses ambiguity errors once tainted.

### 5. Backend sharing

rustc_codegen_ssa (30.7k, 9.7k in mir/) lowers MIR once against trait interfaces (BuilderMethods etc.) implemented by LLVM and GCC. Cranelift does not implement BuilderMethods: it has its own MIR to CLIF lowering and implements only CodegenBackend. What all three share: layout and ABI computed once and queried (query layout_of, fn_abi_of_fn_ptr, fn_abi_of_instance; rustc_abi 6.3k, rustc_target), plus monomorphization collection. A backend can override queries via codegen_backend.provide(&mut providers).

### 6. Driver, queries, incrementality

All 329 queries are declared in one file, rustc_middle/src/queries.rs (2,904 lines); each is a memoized TyCtxt x Key -> Value. Providers are function-pointer fields on a generated Providers struct; 32 crates expose pub fn provide; rustc_interface assembles DEFAULT_QUERY_PROVIDERS. Cycles reported via handle_cycle_error.rs. Incremental: dep graph recorded by instrumenting query execution; try_mark_green; visiting reads out of order "can lead to ICEs"; on by default for debug builds since 1.24 (Feb 2018). Coverage partial: "as of November 2022, only the steps between HIR and LLVM-IR are query-fied". Cross-crate cache: rustc_metadata encodes a dependency's query results into .rmeta (signatures, predicates, MIR for generic and inline fns); ExternProviders decode it; std is never re-typechecked. Clippy and Miri hook through rustc_driver callbacks plus provider overrides. rust-analyzer did not reuse rustc's frontend (needs partial, changing source) and built its own salsa-based hir; it now reuses 8 rustc crates (abi, ast_ir, index, lexer, next_trait_solver, parse_format, pattern_analysis, type_ir). The cost was two frontends and years of drift; Chalk was dropped.

### 7. Encapsulation

Cargo forbids crate cycles. rustc avoids them two ways: data goes down into the hub (rustc_middle, rustc_type_ir); behavior is injected upward through providers (rustc_middle declares typeck, rustc_hir_typeck supplies it at startup; any crate calls tcx.typeck(def_id) without depending on rustc_hir_typeck). Late binding through a record of function pointers the driver builds; needs only first-class functions. pub(crate)/pub(super) used heavily. Costs and direction: MCP compiler-team#966 (Feb 2026, allow downstream crates to define queries) drew the concern of losing the single registry file; PR #152636 removed rustc_query_system; PR #160924 split cstore out of rustc_session so crates "compile in parallel" (hub splits are motivated by build parallelism, not design purity).

### 8. Testing

tests/ui 21,577 .rs with 13,784 .stderr goldens plus //~ ERROR annotations (deliberately redundant: "This redundancy helps avoid mistakes since the .stderr files are usually auto-generated"; --bless regenerates, a human reviews). tests/mir-opt 410 .rs with 1,342 goldens; codegen-llvm 862 (FileCheck); run-make 1,391; incremental 218; crashes 163 (inputs expected to ICE "so that accidental fixes are tracked", the same polarity as Medaka's must-fail). Bootstrap stage0 (downloaded beta) -> stage1 -> stage2; stage 3 same-result test is optional, so Medaka's mandatory fixpoint is stricter. Crater; perf.rust-lang.org instruction counts per PR (PR #152636 triaged for 0.3%). Continuous invariant checks: MIR validator at the Optimized transition, -Zvalidate-mir, -Zincremental-verify-ich, debug assertions, span_delayed_bug.

### 9. Documentation and governance

rustc-dev-guide: one book, 245 pages, about 40.8k lines, organized by reader task with an "Overview of the compiler" first; 31 files use <!-- date-check --> and a monthly CI report lists claims older than 6 months (imperfect: the overview still says "As of November 2022"). API docs generated per crate and linked, not duplicated. MCP process: significant internal refactorings filed in rust-lang/compiler-team with the major-change template (auto Zulip topic), a second from a non-author team member, 10-day FCP; concerns block; team leads decide on failure; experimental code may be written but "should not land" without approval. Large refactors were incremental over years: HIR 2015; MIR 2016 (stable in 1.12); queries 2017, incremental default 2018, front end still not querified; librustc -> librustc_middle PR #70536 (2020, parts 1-5); move into compiler/ PR #74862 (Aug 2020); astconv -> hir_ty_lowering (Mar 2024); new trait solver 2022-; diagnostic derives (#100717, 2022) then the Fluent retreat. Pattern: old and new side by side behind a flag (-Znext-solver), migrate call sites in many small PRs, delete the old path last. rustc's AGENTS.md is a policy restricting LLM use, assuming human authorship and review.

### 10. Regrets and pain points

rustc_middle as hub (32 crates wait on it; types "forced to be" there; no MCP to split it; build-bottleneck claim UNVERIFIED). Partial querification. Order sensitivity in incremental. Parallel front end challenges (lock contention, query-system invariants under concurrency). Old trait solver blocks unsoundness fixes; replacement four years in. Fluent friction. Large files exist but are fenced: 15 opt-outs, mostly diagnostics; late.rs 5,969 is the largest non-diagnostics file; acceptable size 3,000 non-comment lines by rule with an explicit per-file escape hatch; median 144.

## §2 What rustc does that Medaka does not (ranked)

1. Inference state is per body and dies with the body; output is a returned side table, not mutated tree cells (TypeckRootCtxt, writeback, type_dependent_defs is a route table keyed by node id).
2. One obligation type and one progress engine; ordering by kind confined to an epilogue of about 50 lines; most dispatch-like work is an obligation retried whenever new information arrives; probe (pure, cacheable Pick) separated from confirm.
3. File size enforced, each concern its own module, diagnostics split from analysis and reached through an extension context (TypeErrCtxt over InferCtxt) that passes state as an argument, so they never import the analysis.
4. A cross-invocation interface cache (.rmeta), not whole-program incrementality; std is never re-typechecked; needs no dependency graph.
5. Memoize by key as the default way to ask for a fact: the only way to get typeck(def) is tcx.typeck(def), which hits the cache.
6. Facts computed once upstream of all backends (layout_of, fn_abi_of_*, mono items), each owned by a named producer; IR has explicit phases with a validator at each transition.
7. One guide with an overview chapter, date-checks, and a lightweight change process; three kinds of docs kept apart (how it works now, proposals to change it, generated API reference).
8. Proof of an earlier error is a typed value (ErrorGuaranteed, span_delayed_bug).

## §3 What NOT to copy

The red/green on-disk dependency graph (2017-2018 to ship, still ICEs from order sensitivity; justified by minute-long crate builds; Medaka's problem is redundant work solved by memoization plus interfaces). 79 crates and a hub crate (much of the granularity is for rustc's own build parallelism; copy the provider inversion, not the crate count). Querifying everything (rustc never finished; querify per module or binding group). Rust-specific machinery (THIR, borrowck, MIR dataflow, both solvers, canonicalization, regions; no snapshots/rollback unless instance search backtracks). Codegen behind BuilderMethods traits (Cranelift did not adopt it; LLVM text and WasmGC differ more than LLVM and GCC; share facts and plans, not an instruction builder). Fluent. The social machinery of an MCP (assumes several independent reviewers; the owner's ruling plus a written destination contract is the analogue). rust-analyzer's separate frontend. Scale assumptions.

## §4 Recommendations

R1. Add a TypecheckResults side table and migrate the Ref Route cells into it one fact at a time: stable NodeId per route-carrying node (per-module counter like ItemLocalId); immutable Map NodeId Route returned per binding group; write both during migration; switch readers (eval, lowering) one at a time; delete the cell last; assert table and cell agree while both exist. Payoff: dispatch output becomes a cacheable value; the AST need not be re-typechecked to be re-routed.

R2. Scope all per-group inference state in one record created and dropped per binding group; keep only interners global. Classify the 60 loose Refs and the bundles by lifetime (GroupCtx, ModuleCtx, process); make checkBodyImpl take GroupCtx; move the 8 pending channels into it; turn the 9-step stamper into one named finishGroup with a justification per step; then collapse channels into one obligation datatype driven by a tryProgress loop during the walk and at the end, keeping only genuinely order-dependent steps (defaulting, ambiguity reporting) in the epilogue. Payoff: with state passed in, the HM-core vs dispatch split and the diagnostics extraction both become possible.

R3. A Providers record to break import cycles, with diagnostics as a downstream module over an explicit context: a low module defines a record of function fields (typecheckModule, routesOf, schemeOf, explainMismatch, ...); the driver fills it at startup; a module that needs a function it cannot import takes it from the record. Carve diagnostics into types/typecheck_diag.mdk taking GroupCtx plus the record (36 back-imports become record reads); remove the backend import the same way. Not copied: macro-generated query plumbing; a hand-written record of 20-40 fields suffices. Pair with an advisory per-file ceiling on non-comment lines with explicit opt-out markers, presented as a census threshold since the owner declined a gate.

R4. Memoize by key within a process (parse, resolve, typecheckModule, routesOf behind a per-process memo in the provider record, keyed by module path and source hash; every verb, REPL and LSP call through it), then a .rmeta-style module interface cache across processes (exported schemes, impl and dictionary shapes, importer-visible route entries, Core IR of small inlinable definitions; keyed by source hash plus compiler fingerprint; load the prelude from it; build child reads the parent's serialized Core IR). Store interfaces, not bodies. No dependency graph or red/green.

R5. Give Core IR phases (Lowered -> Annotated -> Planned), validate at every transition (unconditionally before emission, after every pass under a debug flag), compute backend facts once in named producers, delete twin pairs as both emitters read the stored fact, track the twin count in arch-census. Not copied: a shared BuilderMethods-style lowering.

Documentation: collapse the flat compiler/*.md files into a guide-shaped tree (one overview page covering pipeline, state lifetimes and fact storage; one page per phase with as-of dates and a periodic stale-claim report; an archive for landed sprint design docs); keep the do-not-relitigate register as the MCP-equivalent record.

## Sources

rust-lang/rust @ 701ce39ddc3b; rustc-dev-guide pages: overview, query, queries/incremental-compilation, type-inference, tests/ui, diagnostics/translation, diagnostics/diagnostic-structs, plus local copies (method-lookup, error-guaranteed, compiletest, bootstrapping, contributing-to-guide, sharing-crates-with-rust-analyzer); forge.rust-lang.org proposals-and-stabilization; compiler-team #966; PRs #152636, #160924, #70536 (via mirror), #74862; goals.rust-lang.org/2026/next-solver; Inside Rust 2024-12-04 trait-system-refactor-initiative; MIR blog 2016-04-19.
