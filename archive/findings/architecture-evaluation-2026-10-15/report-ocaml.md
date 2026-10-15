# The OCaml compiler as an architectural reference for Medaka

**Status:** CLOSED RECORD. Point-in-time study of the OCaml compiler at trunk `ccd44ad7e24c` (2026-10-14); its path citations are into that tree, not this one.

(Saved by the orchestrating session from the OCaml study agent's hand-back, 2026-10-15. Measured on ocaml/ocaml trunk ccd44ad7e24c (5.7.0+dev0-2026-10-06) at scratchpad/ocaml-src/ocaml; scripts in scratchpad/scripts/. Historical sizes from the GitHub contents API at release tags; PR sizes from gh api.)

Correction to the brief: Medaka is not wholly without an interface mechanism. It has per-declaration export and abstract type export (export data without public); typecheck.mdk has 104 export lines. What it lacks is a separate, separately checked interface file and a compiled interface artifact.

## §1 Facts per axis

### 1. Source tree and module granularity

| dir | impl files | .mli | impl lines | .mli lines | impl with .mli | >3k | >5k | median impl |
|---|---|---|---|---|---|---|---|---|
| parsing | 18 | 18 | 14,737 | 3,617 | 17 | 1 | 0 | 537 |
| typing | 54 | 57 | 57,134 | 8,414 | 54 | 4 | 2 | 513 |
| lambda | 14 | 15 | 16,535 | 1,358 | 14 | 1 | 0 | 1,036 |
| middle_end | 77 | 80 | 25,382 | 5,841 | 77 | 0 | 0 | 174 |
| asmcomp | 81 | 56 | 24,632 | 3,821 | 46 (*) | 0 | 0 | 189 |
| bytecomp | 12 | 13 | 4,621 | 752 | 12 | 0 | 0 | 175 |
| driver | 14 | 14 | 4,580 | 780 | 14 | 0 | 0 | 128 |
| utils | 26 | 26 | 8,469 | 3,663 | 25 | 0 | 0 | 202 |
| file_formats | 3 | 6 | 730 | 388 | 3 | 0 | 0 | 119 |
| toplevel | 14 | 11 | 3,777 | 772 | 8 | 0 | 0 | 201 |
| total | 313 | | 160,597 | | 270 (86%) | 6 | 2 | 227 |

(*) The 35 unpaired asmcomp files are 7 per-arch implementations x 5 arches, each implementing a shared .mli at asmcomp/ root (asmcomp/proc.mli), linked into place by the Makefile. Effectively every module has an interface. typing/ holds 57 modules.

Files over 2,000 lines: typecore.ml 8,913; ctype.ml 6,815; parser.mly 4,438; lambda/matching.ml 4,434; env.ml 3,987; typemod.ml 3,901; cmm_helpers.ml 2,864; typedecl.ml 2,660; parmatch.ml 2,398; typeclass.ml 2,293; out_type.ml 2,143; main_args.ml 2,070. Others: includemod.ml 1,456; includecore.ml 1,116; printtyp.ml 174 (down from 2,720 in 5.2 after the 2024 split); cmmgen.ml 1,576; translcore.ml 1,356; bytegen.ml 1,152.

Scale comparison: all of typing/*.ml is 57,134 lines and 2,054,149 bytes. Medaka's typecheck.mdk alone is 57,032 lines and 2,850,564 bytes: 8.3x typecore.ml by bytes and 1.39x the entire OCaml typing/ directory, which covers modules, functors, GADTs, polymorphic variants, classes and objects, first-class modules and signature inclusion. typecore.ml is 11.7% comment-only lines; Medaka's file about 40%.

### 2. IR pipeline

Native: Parsetree -> Typedtree -> Lambda -> Closure (closure.ml 1,539) or Flambda (62 files, 21,101) -> Clambda -> Cmm (typed by machtype) -> Mach -> Linear -> assembly. Bytecode branches at Lambda (bytegen -> instruct -> emitcode). Each IR is a distinct type in a distinct module with its own printer (Pprintast, Printtyped, Printlambda, Printclambda, Printcmm, Printmach, Printlinear, Printinstr); about 50 -d* dump flags; -stop-after and -save-ir-after via Compiler_pass. asmgen.ml threads each function through about 15 passes with ++, each its own module with a dump hook and Profile.record timer.

Typedtree carries inference results on immutable nodes: expression = { exp_desc; exp_loc; exp_extra; exp_type : Types.type_expr; exp_env : Env.t; ... }; disambiguation results are constructor payloads (Texp_construct carries constructor_description; Texp_record carries label_description and representation). typedtree.mli has exactly 2 mutable fields (ctyp_desc, ctyp_type, "mutable because of Typeclass.declare_method"). The bridge from types to representation is one small module, typing/typeopt.ml (297 lines): exp_type plus exp_env -> Lambda's value_kind (Pgenval | Pfloatval | Pboxedintval | Pintval), array_kind, immediate_or_pointer; Translcore writes the facts into Lambda so later stages never re-derive them. Medaka's per-backend re-derivation of arity, runtime types and field slots is exactly what Typeopt, value_kind and machtype exist to prevent.

### 3. Typechecker architecture

typing/HACKING.adoc (83 lines) documents the layering: Types and Typedtree are the data; Btype and Ctype handle levels, unification and backtracking; Typetexp, Typecore, Typemod, Typedecl, Typeclass do inference, one per language layer; Includecore/Includemod/Includeclass do signature inclusion; Out_type, Printtyp, Errortrace_report print; Env and Persistent_env hold environments.

Mutable type variables sit behind an abstraction: Types.type_expr is abstract (get_desc, get_level); writes go through Transient_expr.set_desc on a private record (#10337, 4.14, +1,441/-1,308 in 45 files). Unification is transactional: Types.snapshot/backtrack log every mutation ("Costs nothing"); snapshot called 16 times in ctype.ml, 4 in typecore.ml. Levels are scoped: #11536 (5.1) replaced begin_def/end_def with with_local_level wrappers; generalization walks a per-level pool. Expected type is pushed down (type_expect; type_expected is a private record carrying a type_forcing_context for errors); constructor and label disambiguation is resolved at the node during inference from the expected type; order-dependent results raise a Not_principal warning under -principal instead of deferring.

typecore.ml is still one giant recursive walk: 250 top-level bindings; the core let rec type_exp ... and ... group runs from line 4567 to 8081 (about 3,500 lines, 34 functions); type_expect_ alone about 1,400 lines.

Deferred work cannot change typing results: Typecore.delayed_checks is the only collect-then-run channel; its items are warnings; force_delayed_checks runs between Btype.snapshot and Btype.backtrack. Medaka's semantic-order 8-channel stamper has no OCaml analogue (no typeclasses).

Global state (approximate): about 27 top-level s_ref/s_table cells registered in Local_store (typing + utils); about 60 plain top-level refs in typing/, 18 of them ref (fun ...) forward hooks; per file ctype.ml 14, env.ml 11, typecore.ml 2. utils/local_store.mli (Tarides, 2020) exists "to register all (well, hopefully) the global state" so Merlin can fresh/with_store/reset it; "Merlin is their only user". Medaka's typecheck.mdk alone has 60 loose cells plus 109 in bundles.

Errors: each module owns a closed error variant (typecore.ml:107-222) and raises Error.In_context (loc, env, err); 110 raise or log sites; report_error sits at the bottom (8342-8890), installed via Location.register_error_of_exn.

### 4. Diagnostics

Location.report = { kind; main : msg; sub : msg list; footnote }, msg = Format_doc.t loc; report_kind covers error, warning, warning-as-error, alert, alert-as-error; Misc.Error_style Contextual | Short. Rendering inverted by registration: 38 register_error_of_exn sites; renderers can live downstream of the checker (Includemod_errorprinter, 1,118 lines, depends on Includemod; Typemod calls Includemod_errorprinter.register () at typemod.ml:26). Unification failures are data first (Errortrace, 258 lines) rendered by Errortrace_report (785). The 2024 Printtyp split #13336 (5.3, +3,385/-3,014 in 35 files) produced Printtyp (174), Out_type (2,143) and the errortrace modules. Errors accumulate only since 2026: #14241 "Add Merlin's Typing recovery" plus follow-ups (+5,954/-1,072 in 206 files, merged 2026-05-20, 5.6.0); before that the compiler stopped at the first type error; typing_recovery.ml (105 lines) with log_or_raise, catch_errors and a "ref of ref" scoped error context; HACKING.adoc: "There are no clear rules: the current recovery points are inherited from Merlin and were chosen through trial and error".

### 5. Backend sharing

Shared asmcomp/*.ml totals 14,955 lines; per-arch dirs: amd64 2,356, arm64 2,511, power 2,350, riscv 1,548, s390x 1,618 (one arch is 10-15% of the native backend). An arch supplies arch, proc, selection, CSE, reload, scheduling, stackframe, emit.mlp; the contract is the shared .mli (proc.mli about 40 vals); Selection inherits Selectgen.selector_generic (riscv/selection.ml is 93 lines); shared passes Spill, Split, Liveness, Coloring/Linscan, Linearize, Emitaux, Reloadgen, Schedgen, Stackframegen. RISC-V #9441 (4.11) was +1,812/-6 in 16 files; AArch64 experimental in 4.02 (2014); CI runs make check_all_arches. Bytecode and native share everything down to Lambda (matching, Translcore, Simplif, Tmc); bytegen.ml 1,152. Flambda (#132, 4.03) sits between Lambda and Clambda; both middle ends produce Clambda; #2288 made switching one call; Flambda 2 lives in Jane Street's fork (oxcaml), not upstream; Flambda 1 still gets fixes (abandonment UNVERIFIED). Two emission styles coexist (cvt_emit .mlp templates vs X86_ast/X86_dsl).

### 6. Driver and separate compilation

driver/compile_common.mli exposes parse_intf/typecheck_intf/emit_signature and parse_impl/typecheck_impl/implementation; it admits "it is unsafe to try to compile several distinct compilation units by calling [with_info] several times". .cmi is the checker's own signature marshalled ({ cmi_name; cmi_sign : Types.signature_item list; cmi_crcs; cmi_flags }, Compression.output_value), consistency by CRC (consistbl.ml); Persistent_env loads lazily; Env components lazy (Lazy_backtrack, Subst.Lazy; #10559 made substitution lazy). The stdlib is never re-typechecked: Compmisc.initial_env opens Stdlib from its .cmi and forces only touched components. .cmt/.cmti store the full Typedtree, initial env, load path, source digest, uid table, shapes and occurrences for tools; .cmx carries cross-module optimisation info. Merlin vendors a patched typer per OCaml version (src/ocaml/typing/ plus cmi_cache, cmt_cache, msupport), typechecks the buffer incrementally with checkpoints at top-level items (Bour, Refis, Scherer, ICFP 2018); ocaml-lsp depends on merlin-lib; dependencies come from .cmi and project-wide queries from .cmt via ocaml-index, so nothing is re-typechecked per hover.

### 7. Encapsulation

.mli files are the architecture: 86% of impl files (effectively 100%); abstract types (type_expr, Env.t, snapshot) and private records enforce invariants; typing/TODO.md still asks for "an abstraction boundary between the type algebra and the type checker (at first between Ctype and Typecore)". No import cycles; forward references instead: HACKING.adoc: "Since OCaml does not permit circular dependencies between files, the implementation uses forward declarations, implemented with references to functions that are filled later on" (Typecore.type_module/type_str_item/type_open filled by Typemod at typemod.ml:3379; Typetexp.transl_modtype; Env.add_delayed_check_forward filled by Typecore; Ctype.package_subtype = ref (fun _ -> assert false)); 18 such hooks in typing/. The layer order is written down in the root Makefile's *_SOURCES link order. typing/ uses Lambda only for its data vocabulary (Typeopt, Typedecl, Value_rec_check use Lambda.array_kind and immediate_or_pointer), OCaml's version of Medaka's typecheck importing backend.private_mangle. CONTRIBUTING.md: 80 columns, ASCII (tools/check-typo), "no strongly enforced guidelines specific to the compiler ... local consistency", cleanups in separate commits, library changes update .mli doc comments, issue numbers in comments for non-obvious fixes.

### 8. Testing

testsuite/tests/ has 240 area directories and 1,694 files with an ocamltest (* TEST *) header; 978 .reference and 262 .compilers.reference goldens; 393 files use inline [%%expect{|...|}] blocks (golden beside each phrase); make promote rewrites goldens, docs ask to check with git diff; 46 typing-* directories including typing-recovery. Bootstrap fixpoint: boot/ocamlc (3.7 MB bytecode) and boot/ocamllex are checked in (the analogue of compiler/seed/); make coreboot promotes, rebuilds, runs compare, which strips debug info and cmpbyt-compares and prints "Fixpoint reached, bootstrap succeeded." or "Fixpoint not reached, try one more bootstrapping cycle." (Makefile:736-750); BOOTSTRAP.adoc: bootstrap only on runtime or file-format changes, commit the result separately; tools/ci/inria/bootstrap exercises it in CI.

### 9. Documentation and governance

In-tree compiler-internal docs: 11 files, 657 lines (HACKING.adoc for parsing, typing, utils; typing/TODO.md; parsing/CONFLICTS.md; parsing/VIPs.md; a NOTES.md per arch). Root: HACKING.adoc 695, BOOTSTRAP.adoc 158, CONTRIBUTING.md 478, AI.md 58, Changes 17,834 lines (one entry per PR naming author and reviewers). Medaka has 66 files and 40,015 lines flat in compiler/. Governance: PRs; ecosystem-impacting changes to ocaml/RFCs; an OCaml Language Committee shepherds contested decisions; AI.md requires disclosing AI use and that contributors "have either written, or read and reviewed yourself, every part". Large refactors landed as sequences of medium, green, reviewed PRs: Transient_expr #10337/#10474; level wrappers #11536/#12012; Printtyp split #13336; type_pat de-CPS #11027; unify_pat_types split #12025; label disambiguation #9178/#9182/#9196; pattern-match compiler #9321/#9322/#9359/#9361/#9417/#9447; type_let split #14394; recovery #14241 plus three. typing/TODO.md is the committed backlog of agreed cleanups.

### 10. Regrets and pain points

typing/TODO.md: "There is a consensus that the current implementation of the OCaml typechecker is overly complex and fragile. A big rewriting from scratch might be possible or desirable at some point, or not, but incremental cleanup steps are certainly accessible". Smells listed first: "global mutable state" and "poor data representation"; TODO items include making the level generator part of Env.t, collecting "all global state of the type checker in a single place, possibly a single reference to a persistent data structure", warning settings in Env.t, a more abstract or persistent union-find, "use records instead of 14-tuples" in Typeclass.

typecore.ml growth at release tags: 3.12.1 2,428; 4.00 3,214; 4.02 3,980; 4.06 5,165; 4.10 5,260; 4.14 5,934; 5.2 6,932; 5.4 7,556; trunk 8,913 (3.7x in 15 years; ctype.ml 3,494 -> 6,815). Medaka's file grew 8.3x in 4 months. No primary source calls typecore's size the problem; the TODO blames global state and data representation. utils/clflags.mli exports 133 global refs, the cause of Compile_common's single-unit limit, of Local_store existing, and of recovery's "ref of ref". Recovery points have "no clear rules". Unification debugging has dedicated tools (gprinttyp.ml graphviz, rawprinttyp.ml).

## §2 What OCaml does that Medaka does not (ranked)

1. The output tree holds decisions as immutable fields and post-passes cannot change typing (Typedtree 2 mutable fields; disambiguation as constructor payloads; order-dependent choices warn instead of deferring; the only post pass runs inside snapshot/backtrack). The transferable part: the elaborated output is a new value built after solving, and later passes cannot change typing outcomes.
2. Global state is inventoried and can be snapshotted (Local_store; Btype.snapshot/backtrack). Medaka has neither a registry of its 169+ cells nor a mutation log, which blocks safe speculation and safe in-process reuse (LSP, the multi-check value main).
3. A compiled-interface artifact (.cmi = the checker's own signature type plus CRCs, loaded lazily; stdlib costs one unmarshal).
4. One small bridge computes representation facts once behind a narrow backend contract (Typeopt 297 lines -> value_kind -> machtype; proc.mli about 40 vals; an arch is 10-15% of the backend; RISC-V +1,812 lines).
5. Many modules each with an interface in a written-down layer order (median 227; 2 of 313 over 5k; cycles broken by 18 documented forward hooks).
6. Error data separated from rendering by registration (closed error variants; Location.register_error_of_exn; downstream Includemod_errorprinter). Exactly the inversion that blocked Medaka's withdrawn diagnostics extraction.
7. Few, short, located docs plus one committed TODO (657 lines of internal docs; rationale in .mli comments and Changes entries vs Medaka's 40,015 lines across 66 flat files).
8. A dump flag at every IR boundary (about 50 -d* flags plus -stop-after; Medaka approximates this with 67 entries/ probes).
9. Inline expect tests (393 files keep the golden beside the input, promoted with a reviewed diff).

## §3 What NOT to copy

Don't treat the 3,500-line recursive type_exp group as a target (a stable core team holds it in memory; agents need smaller units). Don't use forward-ref hooks for inference (they turn a static dependency into an init-order invariant failing with assert false; TODO.md names global state smell #1; use them only for one-way, register-once rendering and tool hooks). Don't copy Clflags-style global configuration (133 refs; regretted in Compile_common). Don't copy Marshal-based .cmi naively (Medaka has no generic Marshal; it has the hand-written Core IR s-expression codec; .cmi needs magic-number and CRC discipline; a Medaka cache must be keyed by the existing staleness fingerprint or it serves stale types silently). Don't copy Merlin's forked typer (organizational; Medaka's single shared library is better; take Merlin's checkpointing). Don't copy .mlp templates or a second middle end. Don't copy the RFC repo, language committee or CLA; one rule transfers from AI.md: whoever submits must have read every part, which for agents means checking a slice report's claims against the commit. Don't legislate file-size ceilings: OCaml has no size gate; files stayed small because each new concern became a new module with an .mli.

## §4 Recommendations

1. Make the elaborated output a new value and make the stamper unable to change typing: the 9-step stamper produces an immutable RouteTable (node id -> route) instead of writing Ref Route cells; Core lowering and the evaluator read the table; delete the AST Ref fields; run every post-inference pass under a cell snapshot and treat any change to a type-variable binding as a bug. Precedent: Typedtree's 2 mutable fields; Texp_construct carrying its constructor_description; force_delayed_checks between snapshot and backtrack.
2. Register every typechecker cell in one registry tagged by lifetime (makes "touches 93% of the state" measurable per function), add snapshot/restore over the registry (enables in-process reuse for LSP hover and the multi-check value main), then a mutation log for speculative unification. Precedent: utils/local_store.mli, Types.snapshot/backtrack, TODO.md's "collect all global state in a single place".
3. Ship a typed-interface cache, prelude first: serialize the post-typecheck export environment of core.mdk with a core_ir_sexp-style codec keyed by source fingerprint plus a format version, load lazily; extend to stdlib then user modules; hand build's child the parent's front-end result; gate with a cache-on vs cache-off differential. Precedent: .cmi plus CRCs, lazy Persistent_env, Compmisc.initial_env, the magic-number rules.
4. Invert diagnostics through registration, then extract modules in OCaml's layer order: typecheck errors become a closed data type built at the raise site with context; rendering moves to a downstream typecheck_errorprinter registered once through a single Ref hook (the printer depends on the checker, not the reverse); then extract in order: data, core algebra (unify, levels, generalize), per-layer inference, coherence, printing; each new module states its contract in a top-of-file export block. Precedent: Location.register_error_of_exn, Includemod_errorprinter.register (), #13336, typing/HACKING.adoc layering.
5. Replace the backend twins with one representation bridge and an explicit backend contract: finish moving arity, runtime kind, field slot and tail position into Core IR computed once by a typeopt-style module; write the backend contract as an exported record or interface analogous to proc.mli; CI check that both emitters compile against it. Precedent: Typeopt feeding value_kind; shared asmcomp/*.mli implemented per arch; make check_all_arches; RISC-V at +1,812 lines.

Process note: OCaml's big refactors landed as 2-10 PRs of 1-6k changed lines each, every one green and reviewed, tracked in one committed typing/TODO.md rather than per-PR design docs. One TODO.md plus one HACKING page per Medaka directory would match that and could replace most of the 66 flat design docs.

Sources: the clone (paths inline); gh api repos/ocaml/ocaml/pulls/{9441,10337,11536,13336,14241}; GitHub raw contents at tags 3.12.1 through 5.4.0; merlin and ocaml-lsp contents via gh api; OCamlPro Flambda2 snippets (2024-01-25); Merlin experience report (ICFP 2018); discuss.ocaml.org thread on upstreaming Jane Street's fork.
