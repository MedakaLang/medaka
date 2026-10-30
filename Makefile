# Medaka — convenience targets.
#
# The native, self-hosted `medaka`.  Day-to-day: a 2-stage rebuild from current
# source (no seed).
# Fresh clone: cold-bootstrapped once from the gzipped IR seed.
#
# Quick start:   make medaka && ./medaka run yourfile.mdk

# ⚠️ /tmp is a RAM-BACKED tmpfs (50% of RAM by default = 16 GB on this box).
# Build scratch there competes with the compiler for MEMORY, and a leak shows up as
# "the box is mysteriously slow", not "disk full". mktemp -d honours TMPDIR, so one
# variable moves the whole write-storm onto disk. Override with MEDAKA_SCRATCH.
MEDAKA_SCRATCH ?= /var/tmp/medaka-scratch
export TMPDIR := $(shell mkdir -p $(MEDAKA_SCRATCH) 2>/dev/null && echo $(MEDAKA_SCRATCH) || echo /tmp)

.PHONY: engines-doc medaka emitter seed bootstrap seed-health check-self test gates snapshot-check preflight ci clean help docs-links docs-index gen-ci agent-doc-symbols pr-helper-test fmt-clean-census cli-conformance-census diag-census first-hour-census comment-census arch-census slop-census dup-census dist o2-survivor-census alloc-census retain-census doc-census bytes-census

## medaka  — build the native `medaka` CLI.
##           WARM (./medaka_emitter present): 2-stage rebuild from current source,
##           no seed.  COLD (fresh clone): bootstrap from the gzipped seed first.
medaka:
	sh test/build_native_medaka.sh

## dist    — package a relocatable install tree (medaka, medaka_emitter,
##           stdlib/, runtime/medaka_rt.c) into dist/medaka-<version>-<os>-
##           <arch>.tar.gz. Depends on `medaka` (builds first if needed).
##           MEDAKA_DIST_VERSION overrides the embedded version string.
dist: medaka
	sh scripts/make_dist.sh

## emitter — build just the native emitter binary from the gzipped seed (medaka_emitter)
emitter:
	sh test/bootstrap_from_seed.sh

## bootstrap — STRICT seed-currency gate (CHECKPOINT USE): verify the gzipped seed
##             == current native re-emission, byte-identical (C3a). Run this before
##             cutting a release or a seed re-mint — NOT on every emitter change.
##             The everyday requirement is only that the seed still WORKS (which
##             `make medaka` proves on its cold path); byte-currency is a drift
##             detector. See the SEED POLICY note in test/bootstrap_from_seed.sh:
##             conflating the two drove 41 re-mints = 86 MB = 40% of git history.
bootstrap:
	SEED_STRICT=1 sh test/bootstrap_from_seed.sh

## seed-health — the EVERYDAY check (what CI runs): the seed must still BUILD a
##             working emitter from current source. C3a drift only WARNS.
seed-health:
	sh test/bootstrap_from_seed.sh

## seed    — RE-MINT the gzipped IR seed via the native emitter
seed:
	sh test/refresh_seed.sh

## check-self — FAST "is the compiler source type-clean" gate over the
##           ALREADY-BUILT ./medaka alone (does NOT rebuild it — run `make
##           medaka` first). No oracle build, no differential compare: just
##           `./medaka check` over the medaka_cli.mdk closure, gated on ITS
##           OWN exit code. Sub-minute (~20s). This is
##           test/typecheck_compiler_source.sh's first PASS
##           ("medaka_cli.mdk closure is type-clean") factored out to skip
##           that gate's oracle-staleness coupling — reach for this during a
##           tight edit-verify loop on compiler-source/typechecker work
##           (issue #833); typecheck_compiler_source.sh remains the fuller
##           gate (it additionally covers compiler/entries/*.mdk, issue #472).
check-self:
	sh test/check_self.sh

## preflight — THE AGENT LOOP. Build + run only what your DIFF touches.
##             Derives the gate set from `git diff --name-only`, derives the ORACLE
##             set from those gates, and builds only those (an agent touching
##             parser.mdk builds the multicall plus the singles its gates read, not every entry). Skips the expensive gates —
##             the 3-engine differential (346 fixtures × clang) and the fixpoint
##             (unless you touched the backend, where it IS the decisive gate).
##             ⚠️ A FILTER, NOT AN AUTHORITY. It runs a SUBSET and prints what it
##             skipped. CI on the PR is the authority. Do not merge on a green
##             preflight.  Usage: make preflight [BASE=<ref>]   (default: origin/main)
preflight:
	sh test/preflight.sh $(BASE)

## Concurrency budget for `make test`: INLANG_JOBS steps run at once, each
## handing MEDAKA_TEST_JOBS (INLANG_NESTED) to the suites it spawns.  From 4 cores up
## the outer count is one above cores/2 (4 vCPU CI: 3 x 2; 12 cores: 7 x 2), because
## most steps are single-threaded for long stretches (a front-end pass, then clang)
## and cores/2 x 2 leaves a 4-core runner about a third idle.  Below 4 cores it is
## cores/2, floored at 1.  An INLANG_JOBS given on the command line or in the
## environment is the outer count exactly, and the nested count divides the cores by it.
## Override any of the three.  GNU make 3.81 (macOS) has no --output-sync, so it
## falls back to one step at a time with every core nested.
## Steps share no scratch: each `medaka test --native` builds in its own mktemp
## directory, so the only ordering kept is a -O2 rerun after its base step.
INLANG_CORES ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
INLANG_SERIAL := $(filter 3.%,$(MAKE_VERSION))
INLANG_JOBS_ORIGIN := $(origin INLANG_JOBS)
INLANG_BASE_JOBS := $(if $(INLANG_SERIAL),1,$(shell j=$$(( $(INLANG_CORES) / 2 )); [ $$j -ge 1 ] || j=1; echo $$j))
INLANG_JOBS ?= $(if $(INLANG_SERIAL),1,$(shell j=$(INLANG_BASE_JOBS); [ $(INLANG_CORES) -lt 4 ] || j=$$(( j + 1 )); echo $$j))
INLANG_NESTED ?= $(shell n=$$(( $(INLANG_CORES) / $(if $(filter undefined,$(INLANG_JOBS_ORIGIN)),$(INLANG_BASE_JOBS),$(INLANG_JOBS)) )); [ $$n -ge 1 ] || n=1; echo $$n)
INLANG_SYNC := $(if $(INLANG_SERIAL),,--output-sync=target)
INLANG_MAKEFILE := $(lastword $(MAKEFILE_LIST))
## The step list is READ from the `inlang-*` targets between the markers below,
## so the targets are the one declaration (preflight reads the same span).
INLANG_STEPS := $(shell awk '/^. inlang-steps: begin/{f=1;next} /^. inlang-steps: end/{exit} f&&/^inlang-[^ :]*:/{sub(/:.*/,""); print}' $(INLANG_MAKEFILE))


## test    — the IN-LANGUAGE suite: doctests, property tests, and `test "…"` decls,
##           run by `medaka test` itself (dogfooding). Needs NO oracle binaries.
##           This is what `medaka test` means; the differential gate suite is
##           `make gates`.
## ⚠️ A compiler module with NO CALL SITES is in no entry's import closure, so
##    `make medaka`, `make check-self` and `test/typecheck_compiler_source.sh`
##    ALL miss it — verified 2026-08-03 by injecting `regSize (Registry m) =
##    "not an int"` into `compiler/types/registry.mdk`: `./medaka check
##    compiler/driver/medaka_cli.mdk` exited 0 and `make check-self` printed
##    PASS.  `medaka test <file>` typechecks the file before running its
##    doctests, so listing such a module HERE is what puts both its types and
##    its doctests inside a required check (`inlang` runs `make test`).  Add a
##    step below (an `inlang-*` target) for every call-site-free compiler module.
## GC_INITIAL_HEAP_SIZE (1 GiB): every step is front-end bound and allocation-heavy, so a
## pre-sized heap skips most collections, cutting the suite's CPU-seconds.  Each process
## peaks near 1.5 GB RSS, so 6 concurrent on a 16 GB runner is fine; 2 GiB buys little
## more.  The byte count, not a `1G` suffix, because older libgc ignores the suffix.
test: medaka
	GC_INITIAL_HEAP_SIZE=$(if $(GC_INITIAL_HEAP_SIZE),$(GC_INITIAL_HEAP_SIZE),1073741824) MEDAKA_TEST_JOBS=$(if $(MEDAKA_TEST_JOBS),$(MEDAKA_TEST_JOBS),$(INLANG_NESTED)) $(MAKE) -f $(INLANG_MAKEFILE) --no-print-directory -j$(INLANG_JOBS) $(INLANG_SYNC) inlang-steps

.PHONY: inlang-steps $(INLANG_STEPS)
inlang-steps: $(INLANG_STEPS)

# inlang-steps: begin (test/preflight.sh derives its file set from the lines between these markers)
inlang-ported:
	sh test/diff_compiler_ported.sh

## The floor gate for the whole `stdlib/` suite (#3214).  Every
## `stdlib/*.mdk` is reached through this one roster rather than a line of
## its own here: each row carries the executed-assertion floor that module
## commits and the engine it is spawned under, and a closure check fails
## when a stdlib module has neither a row nor a reasoned exemption — which
## is what a list of per-module lines cannot do, since a module absent from
## such a list is indistinguishable from one that needs no line.  The
## [W-MODULE-BLIND] reason each of those lines carried is stated once, in
## the roster module's own header.
## `--native` is for THIS module, not for the modules it grades: it lists
## `stdlib/` and spawns one `medaka test` per row, and both reach host
## primitives the interpreter does not bind.  Each graded module's own
## engine is the `Engine` column inside the roster.
inlang-stdlib-suite-test:
	./medaka test --native test/stdlib_suite_test.mdk

## The one DIRECTORY target, and the only thing anywhere that reaches
## `checkTestMdkRoster` (compiler/driver/medaka_cli.mdk): the roster check runs
## inside `runTestManyTargets`, which only a multi-target/directory invocation
## takes, so with file targets alone its "git-tracked but never walked" arm was
## dead code. Directory discovery walks all tracked `compiler/types/*_test.mdk`
## siblings: `registry_test.mdk`, `scopes_test.mdk`,
## `solver_contract_test.mdk`, and `typecheck_test.mdk`. The roster therefore
## has something real to account for. It subsumes the four file
## lines that stood here, each for its own [W-MODULE-BLIND] reason:
##   registry.mdk / registry_test.mdk — the module is outside every entry's
##     import closure, so nothing else walks it;
##   evidence.mdk / solver_contract.mdk / solver_contract_test.mdk — the
##     scoped-solver foundation remains outside every production entry's
##     import closure until its first vertical consumer lands;
##   route_key.mdk (ARCH B-2.2-a) — the shared route-word mint is call-site-free
##     BY DESIGN, so this is the only thing that typechecks it at all;
##   typecheck.mdk (A-3.2, #1112) — reached by check-self and
##     typecheck_compiler_source.sh, but neither RUNS doctests, and `DataEnv`'s
##     deFieldOwnerIdents identity-collision case lives in one.
inlang-types:
	./medaka test compiler/types

inlang-extern-core-test:
	./medaka test compiler/types/runtime_abi_test.mdk compiler/types/extern_source_test.mdk compiler/ir/extern_lower_test.mdk

## Support property siblings have no production entry and require explicit discovery.
inlang-support-ordmap-test:
	./medaka test compiler/support/ordmap_test.mdk

inlang-support-scc-test:
	./medaka test compiler/support/scc_test.mdk

inlang-support-util-test:
	./medaka test compiler/support/util_test.mdk

inlang-support-sexp-value-test:
	./medaka test compiler/support/sexp_value_test.mdk
	./medaka test compiler/support/source_index_test.mdk
	./medaka test compiler/tools/lsp_positions_test.mdk
	./medaka test compiler/tools/lsp_diagnostics_test.mdk
	./medaka test compiler/tools/source_snapshot_test.mdk
	./medaka test compiler/tools/snapshot_syntax_test.mdk
	./medaka test compiler/tools/syntax_cache_test.mdk
	./medaka test compiler/tools/source_edits_test.mdk
	./medaka test compiler/tools/syntax_queries_test.mdk

inlang-support-symbol-origin-test:
	./medaka test compiler/support/symbol_origin_test.mdk

inlang-support-diag-codes-test:
	./medaka test compiler/support/diag_codes_test.mdk

inlang-support-diag-codes-doc-test:
	./medaka test compiler/support/diag_codes_doc_test.mdk

inlang-ir-dce-test:
	./medaka test compiler/ir/dce_test.mdk

## The Core s-expression printer and parser round-trip a call's mode and tail
## flag, record ordinals, float literals and the binder-type section; no entry
## imports this sibling.
inlang-ir-core-ir-sexp-test:
	./medaka test compiler/ir/core_ir_sexp_test.mdk

## `noInlineFnNames` carries `@noinline` from the declarations to the LLVM
## emitter; no entry imports this sibling.
inlang-ir-core-ir-lower-test:
	./medaka test compiler/ir/core_ir_lower_test.mdk

inlang-eval-eval-test:
	./medaka test compiler/eval/eval_test.mdk

## The shared free-variable walker in trmc_analysis.mdk drives TRMC safety and
## LLVM closure capture. Its sibling is outside the test roster
## for compiler/types and otherwise has no runner.
inlang-backend-trmc-analysis-test:
	./medaka test compiler/backend/trmc_analysis_test.mdk

## #3306: private_mangle.mdk's ctor-export table (incl. the #1359 re-export
## definer) is private; its sibling drives the exported mangleUnits.
inlang-types-private-mangle-test:
	./medaka test compiler/types/private_mangle_test.mdk

## support/hooks.mdk has no importer until the first hooks consumer lands, so
## no entry's closure reaches it.
inlang-support-hooks-check:
	./medaka check compiler/support/hooks.mdk

## Both emitters and core_validate import the extern catalog, but no entry
## imports its sibling, which checks every row against runtime.mdk, the wasm
## emitter's output and the interpreter.  The registry gate
## diff_compiler_capability_matrix runs extern_catalog_gate_test.mdk.
inlang-backend-extern-catalog-test:
	./medaka test compiler/backend/extern_catalog_test.mdk

## The per-extern engine matrix and its drift guard (an effectful extern the
## oracle binds that `run` does not); no entry imports the module or its sibling.
inlang-tools-engine-table-test:
	./medaka test --native compiler/tools/engine_table_test.mdk

## No entry imports a `_test.mdk` sibling, so the extern check's own tests
## run only from here.
inlang-backend-core-validate-test:
	./medaka test compiler/backend/core_validate_test.mdk

## Each emitter refuses an unstamped binder. Native-only: the refusal is a panic,
## graded in a child `medaka test` run, and no entry imports the file.
inlang-backend-emit-binder-refusal-test:
	./medaka test --native compiler/backend/emit_binder_refusal_test.mdk

## The emission plan's lazy/eager global classification, and the structural check
## that neither emitter recomputes it. Native: the check reads the emitter sources.
inlang-backend-emit-plan-test:
	./medaka test --native compiler/backend/emit_plan_test.mdk compiler/backend/extern_requirements_test.mdk compiler/backend/wasm_demand_test.mdk
	./medaka test compiler/backend/global_plan_test.mdk

## The built-in wall's derived pin: every profile x every NotProvided catalog
## row is refused with the row's reason. Native: each pair spawns `medaka`.
inlang-tools-target-check-test:
	./medaka test --native compiler/tools/target_check_test.mdk

## Coded-trap helpers of wasm_emit.mdk: one `$trapmsg_K` per distinct fixed text,
## graded against the spec's stderr lines.
inlang-backend-wasm-emit-trapmsg-test:
	./medaka test compiler/backend/wasm_emit_trapmsg_test.mdk

## Source-named wasm params of wasm_emit.mdk: a single all-PVar clause binds no
## `__wparg` copy; multi-clause and wildcard params stay positional.
inlang-backend-wasm-emit-paramname-test:
	./medaka test compiler/backend/wasm_emit_paramname_test.mdk

## Or-pattern arms of wasm_emit.mdk: both tree engines emit a shared arm body
## once, against a control walker whose ten separate arms emit it ten times.
inlang-backend-wasm-emit-orarm-test:
	./medaka test compiler/backend/wasm_emit_orarm_test.mdk

## Or-pattern arms of llvm_emit.mdk: a shared arm body is emitted once in its
## join block, against a control walker whose ten separate arms emit it ten times.
inlang-backend-llvm-emit-orarm-test:
	./medaka test compiler/backend/llvm_emit_orarm_test.mdk

## Byte literals of wasm_emit.mdk: a byte literal emits as the WAT of the same
## `U8` integer word, in expressions, patterns and `impl` clauses.
inlang-backend-wasm-emit-bytelit-test:
	./medaka test compiler/backend/wasm_emit_bytelit_test.mdk

## Byte literals of llvm_emit.mdk: a byte literal emits as the IR of the same
## `U8` integer word.
inlang-backend-llvm-emit-bytelit-test:
	./medaka test compiler/backend/llvm_emit_bytelit_test.mdk

## The Wasm physical-identity registry (backend/wasm_symbols.mdk): each defect
## beside a valid same-name control, plus whole programs through the emitter.
inlang-backend-wasm-symbols-test:
	./medaka test compiler/backend/wasm_symbols_test.mdk

## The Wasm runtime helper blocks (backend/wasm_preamble.mdk): each block's text
## defines and calls what its manifest row states, and the registry seeded from
## the rows refuses each defect beside a valid control.
inlang-backend-wasm-preamble-test:
	./medaka test compiler/backend/wasm_preamble_test.mdk

## The LLVM physical-symbol registry (backend/llvm_symbols.mdk): each defect
## beside a valid same-name control, plus whole programs through the emitter.
inlang-backend-llvm-symbols-test:
	./medaka test compiler/backend/llvm_symbols_test.mdk

## The LLVM runtime preamble (backend/llvm_preamble.mdk): each row renders as
## the declaration its parts describe, and the registry checks calls against it.
inlang-backend-llvm-preamble-test:
	./medaka test compiler/backend/llvm_preamble_test.mdk

## String-literal segments of wasm_emit.mdk: one `(data $strseg_N)` per distinct
## payload, shared by every site that spells the same bytes.
inlang-backend-wasm-emit-strseg-test:
	./medaka test compiler/backend/wasm_emit_strseg_test.mdk

## The edge loader text of wasm_loader.mdk; no entry imports the sibling.
inlang-backend-wasm-loader-test:
	./medaka test compiler/backend/wasm_loader_test.mdk

## #3908: match-arm self tail calls must lower to musttail. The sibling is
## native-only (the claim is about emitted code) and has no other runner.
inlang-backend-llvm-emit-tail-call-test:
	./medaka test --native compiler/backend/llvm_emit_tail_call_test.mdk

inlang-backend-llvm-emit-tail-call-test-o2: | inlang-backend-llvm-emit-tail-call-test
	MEDAKA_TEST_CLANG_OPT=-O2 ./medaka test --native compiler/backend/llvm_emit_tail_call_test.mdk

## Char comparisons inline as tagged-word compares (RScalar "Char", #2356 family).
## Native-only: the claim is about the emitted icmp.
inlang-backend-llvm-emit-char-cmp-test:
	./medaka test --native compiler/backend/llvm_emit_char_cmp_test.mdk

## Solved Int arithmetic returned through polymorphic calls must take the checked
## inline emitter path; the sibling is native-only and has no other runner.
inlang-backend-llvm-emit-arith-test:
	./medaka test --native compiler/backend/llvm_emit_arith_test.mdk

## S-reach-derive (#2179): same reason. `gate reach`'s fail-open rules live in
## pure functions with doctests (reachIsFailOpen/reachProjects), and NOTHING
## else runs this file's doctests — no gate script invokes `medaka test` on
## compiler/tools/*, so without this step the fail-open coverage would be
## fixtures that never execute. It also picks up the isProsePath/underDir
## doctests already in the file, which were equally unrun.
inlang-tools-gate-cmd:
	./medaka test compiler/tools/gate_cmd.mdk

## S-the-one-file-wall (#3234): same reason, for gate_cmd.mdk's `*_test.mdk`
## sibling. It drives the native-grading clause's import-following rules
## (`gradeViolations`) over fixture module sources, and a `*_test.mdk` under
## compiler/ is outside every entry's import closure ([W-MODULE-BLIND]), so
## without this step nothing walks it at all.
inlang-tools-gate-cmd-test:
	./medaka test compiler/tools/gate_cmd_test.mdk

## `medaka interface`'s sibling: outside every entry's import closure
## ([W-MODULE-BLIND]), and no gate script runs `medaka test` on compiler/tools/*.
inlang-tools-interface-cmd-test:
	./medaka test compiler/tools/interface_cmd_test.mdk

inlang-tools-doc-test:
	./medaka test compiler/tools/doc_test.mdk

inlang-tools-check-policy-test:
	./medaka test compiler/tools/check_policy_test.mdk

inlang-tools-doctest-test:
	./medaka test compiler/tools/doctest_test.mdk

inlang-tools-repl-test:
	./medaka test compiler/tools/repl_test.mdk

inlang-tools-native-probe-printer-test:
	./medaka test compiler/tools/native_probe_printer_test.mdk

inlang-tools-native-probe-tco-test:
	./medaka test compiler/tools/native_probe_tco_test.mdk

inlang-tools-native-probe-tco-test-o2: | inlang-tools-native-probe-tco-test
	MEDAKA_TEST_CLANG_OPT=-O2 ./medaka test compiler/tools/native_probe_tco_test.mdk

inlang-driver-build-cmd-test:
	./medaka test compiler/driver/build_cmd_test.mdk

inlang-tools-test-cmd-test:
	./medaka test compiler/tools/test_cmd_test.mdk

inlang-tools-target-parse-test:
	./medaka test compiler/tools/target_parse_test.mdk

inlang-tools-probe-transcript-test:
	./medaka test compiler/tools/probe_transcript_test.mdk

inlang-tools-native-props-acceptance-test:
	./medaka test compiler/tools/native_props_acceptance_test.mdk

inlang-tools-native-props-policy-test:
	./medaka test compiler/tools/native_props_policy_test.mdk

inlang-tools-native-props-test:
	./medaka test compiler/tools/native_props_test.mdk

inlang-tools-eval-props-test:
	./medaka test compiler/tools/eval_props_test.mdk

inlang-tools-prop-plan-test:
	./medaka test compiler/tools/prop_plan_test.mdk

inlang-tools-test-pins-test:
	./medaka test compiler/tools/test_pins_test.mdk

inlang-tools-test-pins-io-test:
	./medaka test compiler/tools/test_pins_io_test.mdk

inlang-tools-test-pins-report-test:
	./medaka test compiler/tools/test_pins_report_test.mdk

inlang-tools-test-pins-report-io-test:
	./medaka test compiler/tools/test_pins_report_io_test.mdk

inlang-tools-snapshot-test:
	./medaka test compiler/tools/snapshot_test.mdk

## S-gate-registry (#2735): same reason, for gate_cmd.mdk's sibling. No
## gate script invokes `medaka test` on compiler/tools/gate_registry.mdk
## either, so without this step its tierPartOf/modePartOf/globMatch/
## parseSelector doctests and its `prop` block (selector parsing, glob
## matching) would be fixtures that never execute.
inlang-tools-gate-registry:
	./medaka test compiler/tools/gate_registry.mdk

## S-sweep-is-one-runner (#2593): same reason, for the native gates' shared
## support module. `medaka test --native <gate>.mdk` runs only the named
## module's own doctests, so chompNewlines/stripUnitAutoPrint/batchSection —
## the pure text surgery every migrated sweep grades its goldens through —
## would otherwise be documented and never executed.
inlang-compiler-cli-test-support:
	./medaka test test/compiler_cli_test_support.mdk

## FIX-lint-mechanism-correctness (Fix C): compiler/tools/lint_baseline.mdk
## is outside every entry's import closure ([W-MODULE-BLIND]), so its
## fail-closed parse/validation paths (missing file, malformed TOML, a
## duplicate row, a negative count, a missing count field, findings with
## no row) are otherwise never run. Its sibling carries the six cases.
inlang-tools-lint-baseline-test:
	./medaka test compiler/tools/lint_baseline_test.mdk

## #2701 leg 3: compiler/tools/lint_test.mdk is outside every entry's
## import closure ([W-MODULE-BLIND]), so its renderer-parity property
## (text/JSON/MCP cross-file findings agree) never runs otherwise.
## `--native`: every property here parses real fixture files, an extern
## `medaka test`'s interpreter policy does not bind.
inlang-tools-lint-test:
	./medaka test --native compiler/tools/lint_test.mdk

## The `medaka lint` behaviors only the built binary shows: what the working
## directory and the flag combinations do. compiler/tools/lint_cli_test.mdk is
## outside every entry's import closure ([W-MODULE-BLIND]).
inlang-tools-lint-cli-test:
	./medaka test compiler/tools/lint_cli_test.mdk

## S-two-way-draws-are-random (#2344): compiler/tools/prop_runner_test.mdk
## is outside every entry's import closure ([W-MODULE-BLIND]), so without
## this step its `rngNextLocal` distribution regression (both Bool values
## appear across a run of draws, not a fixed alternation) would be a
## fixture that never executes.
inlang-tools-prop-runner-test:
	./medaka test compiler/tools/prop_runner_test.mdk

## The regex conformance table beside stdlib/regex.mdk, whose expected
## spans, captures, replacements and split pieces come from the published
## Go regexp and RE2 test tables rather than from this engine. It is not
## enrolled as a gate, so this step is the only thing that runs it.
## (stdlib/regex.mdk's own doctests and props are a roster row in
## test/stdlib_suite_test.mdk above, not a line of their own.)
inlang-regex-conformance-test:
	./medaka test test/regex_conformance_test.mdk

## Guard exhaustiveness over test/exhaust_fixtures, called in-process
## (replaces the exhaust_main probe row). A `*_test.mdk` sibling is outside
## every entry's import closure ([W-MODULE-BLIND]); `--native` for `readFile`.
inlang-frontend-exhaust-test:
	./medaka test --native compiler/frontend/exhaust_test.mdk

## analyzeToLines over the resolve/exhaust/check_match fixtures, called
## in-process (replaces the diagnostics_main probe row). A `*_test.mdk`
## sibling is outside every entry's closure ([W-MODULE-BLIND]); `--native`
## for `readFile`.
inlang-driver-diagnostics-test:
	./medaka test --native compiler/driver/diagnostics_test.mdk

## The profile each verb typechecks under follows the project holding its
## entry. A `*_test.mdk` sibling is outside every entry's closure
## ([W-MODULE-BLIND]); `--native` for `readFile`/`writeFile`.
inlang-driver-profile-select-test:
	./medaka test --native compiler/driver/profile_select_test.mdk

## compiler/frontend/resolve.mdk carries its own `test "…"` block
## (the did-you-mean pool memo's once-per-Env discipline, #2800): the
## module's TYPES are checked on every build via the live pipeline's
## import closure, but nothing else runs `medaka test` on it, so
## without this step the memo assertions would never execute.
inlang-frontend-resolve:
	./medaka test compiler/frontend/resolve.mdk

## S-a-missing-companion-is-a-red-gate (#1685): compiler/frontend/
## resolve_test.mdk is a `*_test.mdk` sibling, outside every entry's
## import closure ([W-MODULE-BLIND]), so without this step its
## structural `ModuleExports`/`reExp*From` companion census would never
## run. `--native`: parsing resolve.mdk's own live source needs
## `readFile`, an extern `medaka test`'s interpreter engine does
## not bind.
inlang-frontend-resolve-test:
	./medaka test --native compiler/frontend/resolve_test.mdk

inlang-frontend-lexer-test:
	./medaka test compiler/frontend/lexer_test.mdk
	./medaka test compiler/frontend/lex_literal_test.mdk
	./medaka test compiler/frontend/lex_layout_test.mdk
	./medaka test compiler/frontend/lex_perf_test.mdk

## compiler/frontend/parser_test.mdk is a `*_test.mdk` sibling, outside every
## entry's import closure ([W-MODULE-BLIND]): the unrendered-failure text and
## the furthest-failure choice would otherwise never run.
inlang-frontend-parser-test:
	./medaka test compiler/frontend/parser_test.mdk
	./medaka test compiler/frontend/parse_hints_test.mdk
	./medaka test compiler/frontend/parse_engine_test.mdk
	./medaka test compiler/frontend/parse_diagnostic_test.mdk
	./medaka test compiler/frontend/parse_recovery_test.mdk
	./medaka test compiler/frontend/syntax_source_test.mdk

## compiler/frontend/ast_codec.mdk is imported only by types.prelude_elab; this
## step runs its own sibling test by name.
inlang-frontend-ast-codec-test:
	./medaka test compiler/frontend/ast_codec_test.mdk

## compiler/types/prelude_elab.mdk is imported by types.typecheck and
## driver.build_cmd; this step runs its own sibling test by name.
inlang-types-prelude-elab-test:
	./medaka test compiler/types/prelude_elab_test.mdk

## compiler/types/prelude_decls.mdk is imported by tools.interface_cmd and
## driver.build_cmd; this step runs its own sibling test by name.
inlang-types-prelude-decls-test:
	./medaka test compiler/types/prelude_decls_test.mdk

## S-the-libraries-nobody-runs (#2984-adjacent): `gzip/`'s whole
## in-language suite (lib + main) has no floor gate of any kind, and a
## directory target already grades every assertion in it with one exit
## code, so this is that, rather than a per-module roster row.
inlang-gzip:
	./medaka test gzip

## S-the-makefile-is-not-a-roster (#3081): a small fixed roster over the
## modules whose assertion counts no floor protects. Four are reached by
## nothing — `compiler/tools/gate_cost.mdk`, `compiler/support/util.mdk`
## and `compiler/support/manifest.mdk` are outside every entry's import
## closure ([W-MODULE-BLIND]), and `test/probe_runner.mdk` carries its own
## doctests that no other gate runs. Six are `gzip/lib/*.mdk`, which the
## `medaka test gzip` step above DOES run, but only as one exit code for
## the whole directory; `--json` is refused on a directory target, so no
## per-module count is committed anywhere else. `--native` is for THIS
## module, not the ones it grades: it spawns a `medaka test` subprocess
## per row via `runCommand`, an extern the interpreter does not bind.
inlang-compiler-module-roster-test:
	./medaka test --native test/compiler_module_roster_test.mdk
# inlang-steps: end

## gates   — the FULL differential gate suite (all 82 test/diff_compiler_*.sh, in
##           parallel). Needs `make medaka` AND pre-built oracles:
##             sh test/build_oracles.sh                    # the multicall (51 names) + 2 singles
##             sh test/build_oracles.sh --for '<pattern>'  # only what a gate reads
##           A gate whose oracle is missing now FAILS (not a silent skip), and the
##           runner hard-fails if 0 gates passed — so a fresh clone can no longer
##           report "0 failed" having tested nothing.
##           Slow on a small machine; CI shards it across 6 hosted runners.
gates: medaka
	sh test/run_gates.sh

## snapshot-check — the snapshot suite, CHECK only (never blesses). ~30s, no oracles.
##           This is what the pre-commit hook runs, and the two facts are related:
##           the compiler's own sources are IN the snapshot corpus, so any edit to
##           compiler/**.mdk — including a pure `medaka fmt` reflow — moves that file's
##           `# SOURCE` section and turns the gate red until it is re-cut.
##           Re-cut what you changed, by name:
##             sh test/snapshot_bless.sh --bless compiler/frontend/lexer.mdk
##           There is no whole-suite bless, and a diagnostic-bearing section will refuse
##           to bless at all (see compiler/tools/snapshot.mdk's header for the 3 locks).
##           MEDAKA_ROOT must be ABSOLUTE here: `medaka snapshot` strips the root
##           prefix out of every payload by plain string substitution, so a relative
##           root of `.` also rewrites every literal `.` in the payload (a fixture
##           printing `[0..9]` snapshots as `[0<ROOT><ROOT>9]`). test/run_gates.sh and
##           .githooks/pre-commit each pass an absolute root for the same reason.
snapshot-check: medaka
	MEDAKA_ROOT="$(CURDIR)" ./medaka test --native test/diff_compiler_snapshot_frontend_test.mdk

## ci      — everything CI runs, locally. Slow. Prefer `make preflight`.
ci: medaka
	FORCE=1 sh test/build_oracles.sh
	sh test/run_gates.sh
	$(MAKE) test

## docs-links — doc-link rot gate. Pure text analysis (no build, no toolchain,
##           safe to run anywhere): checks every relative markdown link and
##           every bare `compiler/`/`stdlib/`/`test/`/`runtime/`/`playground/`
##           source citation across the repo's markdown against the CURRENT
##           tree. Ratcheted by test/DOC-LINK-EXCEPTIONS.txt — see that file
##           and test/check_doc_links.sh's header for the FILE/REF format.
docs-links:
	sh test/check_doc_links.sh

## pr-helper-test — run scripts/pr.sh's own test suite (mocked `gh`; no repo
##           touched). POSIX sh, Linux + macOS. Would need no build.
pr-helper-test:
	sh test/pr_helper_test.sh

## engines-doc — regenerate docs/stdlib/ENGINES.md from the engine tables
##           (compiler/tools/engine_table.mdk). GENERATED; the test in
##           engine_table_test.mdk fails when the committed page drifts.
engines-doc: medaka
	ENGINES_BLESS=1 ./medaka test --native compiler/tools/engine_table_test.mdk

## docs-index — regenerate docs/README.md (THE doc index) from every doc's H1
##           + `**Status:**` banner. GENERATED file — never hand-edit it; run
##           this after moving/adding/renaming a doc. Idempotent (same input
##           -> byte-identical output), pure text analysis, no build.
docs-index:
	sh test/gen_docs_index.sh

## gen-ci — regenerate the GENERATED region of .github/workflows/ci.yml (the
##           `gates` job's eight-row matrix) from test/gates.toml. GENERATED
##           block — never hand-edit between its markers; run this after
##           changing a gate's `shard`, a `[[shard]]` row, or a row's
##           test/gate_shards/*.txt prose. Idempotent (same input ->
##           byte-identical output). The drift check is the NON-MUTATING
##           `medaka gate ci --check`, not this target followed by `git diff`:
##           regenerating first heals an uncommitted hand-edit inside the
##           region before any diff can see it. Needs ./medaka (the registry
##           reader is in-binary).
##           LC_ALL=C is pinned for the same reason docs-index pins it: a
##           generator whose output depends on the runner's locale is not
##           reproducible, and "generated" then means nothing. This one has no
##           `sort` today; the pin keeps that true if it ever grows one.
gen-ci: medaka
	LC_ALL=C ./medaka gate ci

## agent-doc-symbols — agent-facing doc SYMBOL-claim rot gate. Pure text
##           analysis (no build, no toolchain, safe to run anywhere): checks
##           every backticked, symbol-shaped token in AGENTS.md,
##           .claude/skills/*/SKILL.md, .claude/workstreams/*.md,
##           .claude/ORCHESTRATING.md (BROAD tier — every inline claim) and
##           docs/spec/*.md, docs/stdlib/*.md and test/*.sh (SCOPED tier —
##           only a claim whose line also cites a compiler/stdlib/runtime
##           path; see the script header for why)
##           against compiler/*.mdk, stdlib/*.mdk, and runtime/*.c. Ratcheted
##           by test/AGENT-DOC-SYMBOL-EXCEPTIONS.txt — see that file and
##           test/check_agent_doc_symbols.sh's header for the SYM/FILE format.
##           ⚠️ compiler/*.md is NOT yet in this corpus — see #1192.
agent-doc-symbols:
	sh test/check_agent_doc_symbols.sh

## fmt-clean-census — report which tracked .mdk files outside test/ fail
##           `medaka fmt --check` (#1794). Derived, not hand-maintained — see
##           test/fmt_clean_census.sh's header. Needs a built ./medaka. Always
##           exits 0: this is a report, not a gate (on-demand only, not wired
##           into CI — see the script header for why).
fmt-clean-census: medaka
	sh test/fmt_clean_census.sh

## cli-conformance-census — re-derive docs/ops/CLI-CONFORMANCE.md's machine-checkable
##           columns (unknown-flag disposition, exit codes, stream discipline,
##           --json channel, help/parse-arm agreement) by EXECUTING every verb.
##           Derived, not hand-maintained. Needs a built ./medaka. Always exits 0:
##           a census, not a gate — see test/cli_conformance_census.sh's header.
cli-conformance-census: medaka
	sh test/cli_conformance_census.sh

## diag-census — re-derive the error-quality conformance table over
##           test/error_quality_fixtures/ (human-channel prefix, caret,
##           real location, --json code/kind/range, diagnostic count, plus
##           documented-vs-observed diagnostic-code coverage). Derived, not
##           hand-maintained — see test/diag_census.sh's header. Needs a
##           built ./medaka. Always exits 0: a census, not a gate — the
##           enforcing check is test/diff_compiler_error_quality_baseline.sh.
diag-census: medaka
	sh test/diag_census.sh

## first-hour-census — mutation census over the docs guide corpus, ranked by
##           first-hour reachability (extract every checkable guide example,
##           apply a small set of beginner-mistake mutations, tabulate which
##           diagnostic code — or, for P-PARSE, which message text — fires
##           how often). Derived, not hand-maintained — see
##           test/first_hour_census.sh's header. Needs a built ./medaka.
##           Always exits 0: a census, not a gate.
first-hour-census: medaka
	sh test/first_hour_census.sh
## comment-census — report the seven comment-register classes (#2281) by
##           line over compiler/*.mdk + stdlib/*.mdk: history narration,
##           reviewer-addressed ruling vocabulary, tombstones, emoji shouts,
##           draft narration, dead deictic citations, and falsified-by-
##           refactor candidates. Derived, not hand-maintained — see
##           test/comment_register_census.sh's header. Pure text/regex, no
##           built ./medaka needed. Always exits 0: a census, not a gate.
comment-census:
	sh test/comment_register_census.sh

## bytes-census — report the per-file `Array Int` type-position count
##           tree-wide (epic #3134). Derived, not hand-maintained — see
##           test/bytes_census.sh's header. Pure text/regex, no built
##           ./medaka needed. Always exits 0 unless the file corpus comes
##           back empty: a census, not a gate.
bytes-census:
	sh test/bytes_census.sh

## arch-census — report the largest-files table + per-directory file/line
##           totals over compiler/*.mdk + stdlib/*.mdk (#2289). Derived, not
##           hand-maintained — see test/arch_census.sh's header. SOFT
##           detector only: no threshold, no verdict. Pure text/wc, no built
##           ./medaka needed. Always exits 0: a census, not a gate.
arch-census:
	sh test/arch_census.sh

## doc-census — report per-doc disposition over the doc corpus (#2300):
##           last-edit date, syntax-example-corpus enrolment, DOC-LINK-
##           EXCEPTIONS.txt FILE-tier enrolment, docs/README.md reachability,
##           and a `**Status:**` banner check. Derived, not hand-maintained —
##           see test/doc_census.sh's header. Pure git/text, no built
##           ./medaka needed. Always exits 0: a census, not a gate.
doc-census:
	sh test/doc_census.sh

## o2-survivor-census — report-only census over test/o2_survivor_fixtures/
##           (#2357, LLVM arm): for each single-construct probe, emit
##           pre-`-O2` LLVM IR (`medaka build --keep-ir`), run `clang -O2
##           -S -emit-llvm`, and bucket what survives in the probe's own
##           function (opaque runtime calls, live allocations, redundant
##           loads, non-collapsed tag arithmetic). Needs a built ./medaka
##           and clang. Always exits 0: a census, not a gate — see
##           test/o2_survivor_census.sh's header.
o2-survivor-census: medaka
	sh test/o2_survivor_census.sh

## alloc-census — report-only allocation census of `medaka check` on the
##           compiler (#4027, #2357, #503): builds the CLI non-LTO with
##           --keep-ir, classifies every mdk_alloc site by pointer fate,
##           counts them in an instrumented run, and reports class x kind x
##           function plus string/list append callers. ~4 min. Needs a built
##           ./medaka, clang, python3, bdw-gc. Always exits 0: a census, not
##           a gate — see test/alloc_census.sh's header.
alloc-census: medaka
	sh test/alloc_census.sh

## retain-census — report-only retention census of `medaka check` on the
##           compiler (#4090): what the collector keeps re-marking, as live
##           bytes by allocating function and module at several points of the
##           run, plus "who holds it" with RETAIN_REF_SITES/RETAIN_REF_APP.
##           ~6 min. Needs a built ./medaka, clang, python3, bdw-gc. Always
##           exits 0: a census, not a gate — see test/retain_census.sh's header.
retain-census: medaka
	sh test/retain_census.sh

## dup-census — report what rule-duplicate-body's zero is hiding (#2861):
##           suppression directives per file, the findings they hide (derived
##           by stripping them in a SCRATCH copy and re-running the same
##           binary — the working tree is never written), and how many of the
##           directives state a constraint. Needs a built ./medaka. Always
##           exits 0: a census, not a gate — see
##           test/dup_suppression_census.sh's header.
dup-census: medaka
	sh test/dup_suppression_census.sh

## slop-census — the ONE composing entry point over the slop-burndown
##           crusade's (#2276) member censuses (#2304). Registry is data IN
##           test/slop_census.sh — a row whose script does not exist reports
##           MISSING, never 0. Default invocation does NOT build or invoke
##           ./medaka (build-needing rows are SKIPPED with a reason); pass
##           SLOP_CENSUS_FULL=1 to also run those (needs `make medaka` first).
##           Always exits 0: a census, not a gate.
slop-census:
	sh test/slop_census.sh

## clean   — remove native build artifacts (keeps the checked-in seed)
clean:
	rm -f medaka medaka_emitter

help:
	@grep -E '^## ' Makefile | sed 's/^## //'
