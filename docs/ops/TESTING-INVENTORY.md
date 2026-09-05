# TESTING-INVENTORY.md — which gates can be native today, and what blocks the rest

**A dated survey snapshot, taken 2026-09-03 at `5397afc9c`.** One row per tracked shell script under `test/`, `test/wasm/`, and every `<project>/test/`. It was derived by a two-round agent survey (taxonomy, then per-gate expressibility against the native vehicle as measured on a fresh binary); no gate was run to produce it. It is the input to the testing-architecture epic (`docs/ops/TESTING-ARCHITECTURE.md` §5) and is expected to rot: the epic's registry slice moves the `dest`/`blockers` classification into `test/gates.toml` so `medaka gate verify` keeps it honest, after which this file is history.

## How to read a row

- **dest** — where the check goes: `N` a native gate module (Medaka code with the full extern set, run natively, may spawn `./medaka`/clang/node and diff), `T` a `test`/`prop` block in a `*_test.mdk` sibling under `medaka test`, `SHELL` stays a script for a stated reason, `OUT` a generator/tool that is not a check.
- **today** — `YES` = expressible with no new capability on the 2026-09-03 binary.
- **blockers** — capability codes; see the vocabulary in `TESTING-ARCHITECTURE.md` §5.1. `NATIVE-KIND-RUNNER` is the one foundational blocker: the registry declares `kind = "native"` but no gate uses it and `gate run` has no dispatch for it.
- **medianMs** — from `test/gate_cost_baseline.json` when a row exists; `—` otherwise.

## Counts

| destination | n |
|---|---:|
| native gate module (`N`) | 208 |
| stays shell (`SHELL`) | 43 |
| not a check (`OUT`) | 31 |
| undecided (`UNSURE`) | 4 |
| `*_test.mdk` sibling (`T`) | 2 |
| **total** | **288** |

| today? | n |
|---|---:|
| NO | 209 |
| n/a | 74 |
| UNSURE | 4 |
| YES | 1 |

| blocker | gates carrying it |
|---|---:|
| `NATIVE-KIND-RUNNER` | 211 |
| `EXTERNAL-TOOL` | 120 |
| `GOLDEN-ASSERT` | 101 |
| `ORACLE-PROBE` | 68 |
| `NOT-A-CHECK` | 32 |
| `TRUST-ANCHOR` | 25 |
| `SECTION-SPLIT` | 13 |
| `INVERTED-POLARITY` | 8 |
| `TEST-IO` | 1 |
| `NONE` | 1 |

## The table

| script | shape | subject | dest | today | blockers | medianMs | lines | note |
|---|---|---|---|---|---|---:|---:|---|
| `byteparser/test/check.sh` | CLI-CONTRACT | native | N | NO | NATIVE-KIND-RUNNER | 303 | 18 | WRAP: spawns ./medaka + diffs, module does the same |
| `gzip/test/deflate_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 81966 | 281 | WRAP: spawns ./medaka + diffs, module does the same [python3,gzip] |
| `gzip/test/inflate_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 6570 | 466 | WRAP: spawns ./medaka + diffs, module does the same [python3,gzip] |
| `mq/test/check.sh` | CLI-CONTRACT | native | N | NO | NATIVE-KIND-RUNNER | 138 | 18 | WRAP: spawns ./medaka + diffs, module does the same |
| `parsec/test/check.sh` | CLI-CONTRACT | native | N | NO | NATIVE-KIND-RUNNER | 1201 | 25 | WRAP: spawns ./medaka + diffs, module does the same |
| `pds/nightly/repo_vectors_eval_engine.sh` | DIFFERENTIAL | multiple (eval vs native) | N | NO | NATIVE-KIND-RUNNER | — | 92 | WRAP: spawns ./medaka + diffs, module does the same |
| `pds/nightly/signing_parity.sh` | DIFFERENTIAL | multiple (eval/native/wasm) | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | — | 96 | WRAP: spawns ./medaka + diffs, module does the same [node] |
| `pds/test/atsyntax_vectors.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER | 3352 | 88 | WRAP: spawns ./medaka + diffs, module does the same |
| `pds/test/car_vectors.sh` | DIFFERENTIAL | multiple (eval/native/wasm) | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 10759 | 108 | WRAP: spawns ./medaka + diffs, module does the same [node] |
| `pds/test/constant_time_parity.sh` | DIFFERENTIAL | multiple (eval/native/wasm) | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 228782 | 78 | WRAP: spawns ./medaka + diffs, module does the same [node] |
| `pds/test/constant_time_public_key.sh` | STRUCTURAL-IR | native | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL, SECTION-SPLIT | 3586 | 221 | WRAP: spawns ./medaka + diffs, module does the same [clang] |
| `pds/test/constant_time_reductions.sh` | STRUCTURAL-IR | native (some wasm required-checks) | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL, SECTION-SPLIT | 34263 | 989 | WRAP: spawns ./medaka + diffs, module does the same [clang,node] |
| `pds/test/constant_time_signing.sh` | STRUCTURAL-IR | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL, SECTION-SPLIT | 66762 | 641 | WRAP: spawns ./medaka + diffs, module does the same [clang,python3] |
| `pds/test/dagcbor_cid_vectors.sh` | DIFFERENTIAL | multiple (eval/native/wasm) | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 5707 | 68 | WRAP: spawns ./medaka + diffs, module does the same [node] |
| `pds/test/did_key_all_engines.sh` | DIFFERENTIAL | multiple (eval/native/wasm) | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 232991 | 120 | WRAP: spawns ./medaka + diffs, module does the same [node,python3] |
| `pds/test/ecdsa_vectors.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER | 74788 | 82 | WRAP: spawns ./medaka + diffs, module does the same |
| `pds/test/field_vectors.sh` | DIFFERENTIAL | multiple (eval/native) | N | NO | NATIVE-KIND-RUNNER | 49216 | 125 | WRAP: spawns ./medaka + diffs, module does the same |
| `pds/test/inlang_test_oracle.sh` | INLANG-WRAPPER | interpreter | N | NO | NATIVE-KIND-RUNNER | 418939 | 102 | WRAP: spawns ./medaka + diffs, module does the same |
| `pds/test/lexjson_vectors.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER | 3305 | 59 | WRAP: spawns ./medaka + diffs, module does the same |
| `pds/test/lib_boundary.sh` | RATCHET/LEDGER | none | N | NO | NATIVE-KIND-RUNNER | 288 | 154 | REWRITE: probe/static text becomes library calls |
| `pds/test/mst_vectors.sh` | DIFFERENTIAL | multiple (eval/native/wasm) | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 30928 | 114 | WRAP: spawns ./medaka + diffs, module does the same [node] |
| `pds/test/opaque_field_scalar.sh` | GOLDEN | none (typecheck-only) | N | NO | NATIVE-KIND-RUNNER | 3375 | 429 | WRAP: spawns ./medaka + diffs, module does the same |
| `pds/test/protocol_all_engines.sh` | DIFFERENTIAL | multiple (eval/native/wasm) | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 23834 | 123 | WRAP: spawns ./medaka + diffs, module does the same [node,python3] |
| `pds/test/read_routes_all_engines.sh` | DIFFERENTIAL | multiple (eval/native/wasm) | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 35748 | 157 | WRAP: spawns ./medaka + diffs, module does the same [node,python3] |
| `pds/test/repo_vectors.sh` | DIFFERENTIAL | multiple (native/wasm only, no eval) | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 18410 | 171 | WRAP: spawns ./medaka + diffs, module does the same [node] |
| `pds/test/rfc6979_vectors.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 2234 | 80 | WRAP: spawns ./medaka + diffs, module does the same [python3] |
| `pds/test/scalar_vectors.sh` | DIFFERENTIAL | multiple (eval/native) | N | NO | NATIVE-KIND-RUNNER | 63804 | 143 | WRAP: spawns ./medaka + diffs, module does the same |
| `pds/test/secp256k1_point_vectors.sh` | DIFFERENTIAL | multiple (eval/native) | N | NO | NATIVE-KIND-RUNNER | 200484 | 17 | WRAP: spawns ./medaka + diffs, module does the same |
| `pds/test/serve_e2e.sh` | PROJECT-SUITE | native | N | NO | NATIVE-KIND-RUNNER | 44227 | 233 | WRAP: spawns ./medaka + diffs, module does the same |
| `pds/test/sha256_vectors.sh` | DIFFERENTIAL | multiple (eval/native) | N | NO | NATIVE-KIND-RUNNER | 16052 | 115 | WRAP: spawns ./medaka + diffs, module does the same |
| `pds/test/store_persistence.sh` | PROJECT-SUITE | native | N | NO | NATIVE-KIND-RUNNER | 7958 | 102 | WRAP: spawns ./medaka + diffs, module does the same |
| `pds/test/trust_boundary_guards.sh` | OTHER | interpreter (eval only, deliberately) | N | NO | NATIVE-KIND-RUNNER | 3052 | 125 | WRAP: spawns ./medaka + diffs, module does the same |
| `sqlite/test/aggregate_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 4491 | 71 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3] |
| `sqlite/test/delete_negative_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 4891 | 113 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3] |
| `sqlite/test/delete_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 12495 | 163 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3] |
| `sqlite/test/distinct_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 4206 | 63 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3] |
| `sqlite/test/dml_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 12640 | 373 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3,python3] |
| `sqlite/test/groupby_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 4402 | 85 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3] |
| `sqlite/test/index_write_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL, SECTION-SPLIT | 15166 | 335 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3] |
| `sqlite/test/inlang_test_oracle.sh` | INLANG-WRAPPER | interpreter | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 25321 | 77 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3] |
| `sqlite/test/join_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 4203 | 73 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3] |
| `sqlite/test/left_join_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 4184 | 79 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3] |
| `sqlite/test/multipage_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 7604 | 106 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3,python3] |
| `sqlite/test/multipage_write_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 10007 | 167 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3,python3] |
| `sqlite/test/multitable_write_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 9905 | 157 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3,python3] |
| `sqlite/test/oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 7587 | 102 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3] |
| `sqlite/test/overflow_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL, SECTION-SPLIT | 6482 | 302 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3,python3] |
| `sqlite/test/projection_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 4293 | 71 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3] |
| `sqlite/test/rowid_roundtrip_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 10340 | 147 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3] |
| `sqlite/test/select_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 4380 | 80 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3] |
| `sqlite/test/sql_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL, SECTION-SPLIT | 10909 | 527 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3] |
| `sqlite/test/typed_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 2199 | 58 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3] |
| `sqlite/test/update_expr_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 5512 | 130 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3] |
| `sqlite/test/update_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 5458 | 193 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3] |
| `sqlite/test/writer_api_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 10084 | 307 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3] |
| `sqlite/test/writer_oracle.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 10139 | 132 | WRAP: spawns ./medaka + diffs, module does the same [sqlite3] |
| `test/build_cmd.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 13298 | 134 | WRAP: spawns ./medaka + diffs, module does the same [clang] |
| `test/build_construct_coverage.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 63926 | 187 | WRAP: spawns ./medaka + diffs, module does the same [clang] |
| `test/build_wasm_cmd.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, ORACLE-PROBE, EXTERNAL-TOOL | — | 106 | REWRITE: probe/static text becomes library calls [clang,node] |
| `test/check_agent_doc_symbols.sh` | DOC-ROT | none | N | NO | NATIVE-KIND-RUNNER | — | 588 | REWRITE: probe/static text becomes library calls |
| `test/check_doc_links.sh` | DOC-ROT | none | N | NO | NATIVE-KIND-RUNNER | — | 454 | REWRITE: probe/static text becomes library calls |
| `test/check_keyword_sync.sh` | RATCHET/LEDGER | none | N | NO | NATIVE-KIND-RUNNER | — | 117 | REWRITE: probe/static text becomes library calls |
| `test/check_removed_constructs.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER | — | 273 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/check_spec_clause_labels.sh` | DOC-ROT | none | N | NO | NATIVE-KIND-RUNNER | — | 372 | REWRITE: probe/static text becomes library calls |
| `test/check_syntax_examples.sh` | GOLDEN | native (check + run, interpreter path) | N | NO | NATIVE-KIND-RUNNER, SECTION-SPLIT | 23273 | 662 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/cross_project_deps.sh` | GOLDEN | native (check/run/build+exec) | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT | 1703 | 82 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/cross_project_twonames.sh` | GOLDEN | native (check/run/build+exec) | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT | 1330 | 78 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_async.sh` | GOLDEN | native (async I/O bound only in LLVM backend, per header) | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT | 7379 | 68 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_analyze_project.sh` | GOLDEN | native (compiled test/bin probe) | N | NO | NATIVE-KIND-RUNNER, ORACLE-PROBE, EXTERNAL-TOOL | 4697 | 154 | REWRITE: probe/static text becomes library calls [python3] |
| `test/diff_compiler_anf_identity.sh` | GOLDEN | native (compiled test/bin probe) | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE, EXTERNAL-TOOL, SECTION-SPLIT | 35 | 57 | REWRITE: probe/static text becomes library calls [node] |
| `test/diff_compiler_argtag_matrix.sh` | OTHER | multiple (check/run/build) | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL, INVERTED-POLARITY | 16063 | 187 | WRAP: spawns ./medaka + diffs, module does the same [clang] |
| `test/diff_compiler_build.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 20877 | 112 | WRAP: spawns ./medaka + diffs, module does the same [clang] |
| `test/diff_compiler_call_arity.sh` | STRUCTURAL-IR | native | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 184883 | 320 | WRAP: spawns ./medaka + diffs, module does the same [clang,python3] |
| `test/diff_compiler_capability_matrix.sh` | RATCHET/LEDGER | multiple (parses interpreter/LLVM/wasm dispatch SOURCE text; no execution of any) | N | NO | NATIVE-KIND-RUNNER | 1880 | 481 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_check.sh` | GOLDEN | native (compiled test/bin oracle) | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 8578 | 108 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_check_batch.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 3566 | 72 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_check_cli_modules.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, SECTION-SPLIT | 35548 | 2926 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_check_json.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 7472 | 240 | WRAP: spawns ./medaka + diffs, module does the same [clang] |
| `test/diff_compiler_check_match.sh` | GOLDEN | native (compiled test/bin oracle) | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 165 | 37 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_check_modules.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, ORACLE-PROBE | 1514 | 81 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_check_policy.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT | 2478 | 210 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_check_wrapper_callers.sh` | RATCHET/LEDGER | none | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 87 | 153 | REWRITE: probe/static text becomes library calls [python3] |
| `test/diff_compiler_cli_help_conformance.sh` | CLI-CONTRACT | native | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 12885 | 197 | WRAP: spawns ./medaka + diffs, module does the same [clang] |
| `test/diff_compiler_cli_reject_floor.sh` | CLI-CONTRACT | native | N | NO | NATIVE-KIND-RUNNER | 1014 | 487 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_codemod.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT | 629 | 101 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_core_ir.sh` | GOLDEN | native (compiled test/bin oracle, prelude-free) | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 181 | 44 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_core_ir_list.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 112 | 42 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_core_ir_modules.sh` | GOLDEN | native (also requires ./medaka present) | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 1125 | 100 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_core_ir_prelude.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 440 | 44 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_core_ir_roundtrip.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 195 | 48 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_core_ir_run.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 5128 | 39 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_core_ir_typed.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 1584 | 36 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_core_ir_typed_modules.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, ORACLE-PROBE, INVERTED-POLARITY | 14473 | 333 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_diagnostics.sh` | GOLDEN | none | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 3386 | 77 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_dict_semantics.sh` | GOLDEN | multiple | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL, SECTION-SPLIT | 306107 | 1643 | WRAP: spawns ./medaka + diffs, module does the same [clang,node,python3] |
| `test/diff_compiler_dispatch_shape.sh` | STRUCTURAL-IR | native | N | NO | NATIVE-KIND-RUNNER | 2652 | 208 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_doc.sh` | GOLDEN | none | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT | 1994 | 247 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_doc_stdlib_reference.sh` | GOLDEN | none | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT | 2627 | 79 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_draft_semantic.sh` | GOLDEN | none | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 1103 | 149 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_effect_hole.sh` | DIFFERENTIAL | none | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 695 | 175 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_effect_param.sh` | DIFFERENTIAL | none | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 272 | 93 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_effect_polarity.sh` | GOLDEN | none | N | NO | NATIVE-KIND-RUNNER | 1915 | 199 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_engines.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE, EXTERNAL-TOOL | 258308 | 772 | REWRITE: probe/static text becomes library calls [clang,node] |
| `test/diff_compiler_entry_exit_codes.sh` | CLI-CONTRACT | native | N | NO | NATIVE-KIND-RUNNER, ORACLE-PROBE, EXTERNAL-TOOL | 421 | 124 | REWRITE: probe/static text becomes library calls [node] |
| `test/diff_compiler_error_quality_baseline.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER | 9575 | 20 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_eval.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 180 | 61 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_eval_dict_batch.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 2314 | 32 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_eval_json.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT | 1350 | 89 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_eval_list.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 98 | 41 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_eval_list_batch.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 117 | 36 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_eval_modules.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 782 | 46 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_eval_prelude.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 395 | 42 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_eval_prelude_batch.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 121 | 35 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_eval_run.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 4994 | 40 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_eval_run_batch.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 776 | 41 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_eval_typed_batch.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 961 | 32 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_eval_typed_modules.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 2980 | 55 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_exhaust.sh` | GOLDEN | none | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 39 | 34 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_flat_vs_onemodule.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, ORACLE-PROBE, EXTERNAL-TOOL, INVERTED-POLARITY | 8630 | 683 | REWRITE: probe/static text becomes library calls [clang] |
| `test/diff_compiler_fmt.sh` | GOLDEN | none | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 494 | 51 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_fmt_roundtrip.sh` | DIFFERENTIAL | none | N | NO | NATIVE-KIND-RUNNER, ORACLE-PROBE, EXTERNAL-TOOL | 39568 | 240 | REWRITE: probe/static text becomes library calls [gzip] |
| `test/diff_compiler_fmt_write_safety.sh` | CLI-CONTRACT | none | N | NO | NATIVE-KIND-RUNNER | 822 | 203 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_guide_render.sh` | DOC-ROT | none | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 706 | 149 | REWRITE: probe/static text becomes library calls [node] |
| `test/diff_compiler_iface_order.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 9274 | 651 | WRAP: spawns ./medaka + diffs, module does the same [clang] |
| `test/diff_compiler_import_order.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 105360 | 732 | WRAP: spawns ./medaka + diffs, module does the same [clang,gh] |
| `test/diff_compiler_index.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT | 392 | 90 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_index_oob.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 6576 | 158 | WRAP: spawns ./medaka + diffs, module does the same [clang] |
| `test/diff_compiler_internal_extern.sh` | CLI-CONTRACT | multiple | N | NO | NATIVE-KIND-RUNNER | 4530 | 360 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_ir_size.sh` | STRUCTURAL-IR | native | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 8971 | 196 | WRAP: spawns ./medaka + diffs, module does the same [clang] |
| `test/diff_compiler_let_refute.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 3239 | 96 | WRAP: spawns ./medaka + diffs, module does the same [clang] |
| `test/diff_compiler_lex_files.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 189 | 72 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_lint.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 11748 | 56 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_lint_cache.sh` | DIFFERENTIAL | none | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT | 7223 | 451 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_lint_crossfile.sh` | GOLDEN | none | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT | 258 | 53 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_lint_fix.sh` | GOLDEN | none | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 147 | 42 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_lint_multi.sh` | GOLDEN | none | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT | 247 | 53 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_lint_multi_dir.sh` | GOLDEN | none | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT | 1156 | 117 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_llvm.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE, EXTERNAL-TOOL | 7798 | 128 | REWRITE: probe/static text becomes library calls [clang] |
| `test/diff_compiler_llvm_ffi.sh` | OTHER | native | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 18936 | 729 | WRAP: spawns ./medaka + diffs, module does the same [clang] |
| `test/diff_compiler_llvm_modules.sh` | GOLDEN | multiple | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE, EXTERNAL-TOOL | 13538 | 101 | REWRITE: probe/static text becomes library calls [clang] |
| `test/diff_compiler_llvm_symbol_collision.sh` | OTHER | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL, SECTION-SPLIT | 6611 | 505 | WRAP: spawns ./medaka + diffs, module does the same [clang] |
| `test/diff_compiler_llvm_typed.sh` | GOLDEN | multiple | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE, EXTERNAL-TOOL | 2253 | 190 | REWRITE: probe/static text becomes library calls [clang] |
| `test/diff_compiler_llvm_typed_ir.sh` | STRUCTURAL-IR | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE, EXTERNAL-TOOL | 984 | 242 | REWRITE: probe/static text becomes library calls [clang,node] |
| `test/diff_compiler_lsp.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 1183 | 292 | WRAP: spawns ./medaka + diffs, module does the same [python3] |
| `test/diff_compiler_lsp_b3.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 1035 | 269 | WRAP: spawns ./medaka + diffs, module does the same [python3] |
| `test/diff_compiler_lsp_b4.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 1995 | 355 | WRAP: spawns ./medaka + diffs, module does the same [python3] |
| `test/diff_compiler_mcp.sh` | GOLDEN | none | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT | 3480 | 231 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_must_fail.sh` | RATCHET/LEDGER | multiple | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL, INVERTED-POLARITY | — | 764 | WRAP: spawns ./medaka + diffs, module does the same [clang,node,python3] |
| `test/diff_compiler_new.sh` | GOLDEN | none | N | NO | NATIVE-KIND-RUNNER, ORACLE-PROBE | 9 | 51 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_origin_agreement.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE, EXTERNAL-TOOL | 2427 | 512 | REWRITE: probe/static text becomes library calls [clang] |
| `test/diff_compiler_os_entropy.sh` | OTHER | multiple | N | NO | NATIVE-KIND-RUNNER | 3413 | 143 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_parse_error_loc.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT | 1839 | 70 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_parse_errors.sh` | GOLDEN | none | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 335 | 66 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_parse_result.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 142 | 163 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_perf_stage_census.sh` | RATCHET/LEDGER | none | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 37 | 207 | REWRITE: probe/static text becomes library calls [python3] |
| `test/diff_compiler_prelude_obj.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 29397 | 145 | WRAP: spawns ./medaka + diffs, module does the same [clang] |
| `test/diff_compiler_prelude_shadow_census.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL, INVERTED-POLARITY | 67846 | 189 | WRAP: spawns ./medaka + diffs, module does the same [clang] |
| `test/diff_compiler_references_correctness.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 731 | 134 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_references_tool.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 812 | 203 | WRAP: spawns ./medaka + diffs, module does the same [python3] |
| `test/diff_compiler_rejection_parity.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, ORACLE-PROBE, EXTERNAL-TOOL | 4372 | 177 | REWRITE: probe/static text becomes library calls [clang,node] |
| `test/diff_compiler_repl.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 467 | 64 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_resolve.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 1370 | 41 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_resolve_batch.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 221 | 28 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_resolve_modules.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, ORACLE-PROBE | 1240 | 78 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_rt_obj.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 30299 | 239 | WRAP: spawns ./medaka + diffs, module does the same [clang] |
| `test/diff_compiler_run_check_agreement.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT | 108345 | 159 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_run_entry_subdir.sh` | CLI-CONTRACT | multiple | N | NO | NATIVE-KIND-RUNNER | 1685 | 119 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_run_stdout_flush.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER | 4843 | 161 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_shadow_semantics.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 95446 | 499 | WRAP: spawns ./medaka + diffs, module does the same [node] |
| `test/diff_compiler_slice_oob.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 6337 | 153 | WRAP: spawns ./medaka + diffs, module does the same [clang] |
| `test/diff_compiler_snapshot_bless.sh` | CLI-CONTRACT | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT | 927 | 160 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_snapshot_core_ir.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT | 133 | 119 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_snapshot_eval.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 2044 | 121 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_snapshot_eval_errors.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE, INVERTED-POLARITY | 910 | 142 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_snapshot_frontend.sh` | GOLDEN | multiple | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE, SECTION-SPLIT | 8794 | 227 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_snapshot_prelude.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT | 172 | 114 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_snapshot_types.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT | 234 | 129 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_snapshot_types_user.sh` | GOLDEN | interpreter | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT | 2077 | 120 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_snapshot_wasm_input.sh` | DIFFERENTIAL | native | N | NO | NATIVE-KIND-RUNNER | 231 | 92 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_source_bytes.sh` | RATCHET/LEDGER | none | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 2070 | 113 | REWRITE: probe/static text becomes library calls [python3,gzip] |
| `test/diff_compiler_stack_overflow.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 4843 | 126 | WRAP: spawns ./medaka + diffs, module does the same [clang] |
| `test/diff_compiler_stdlib_conventions.sh` | RATCHET/LEDGER | none | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 29 | 114 | REWRITE: probe/static text becomes library calls [python3] |
| `test/diff_compiler_test_native.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 10327 | 278 | WRAP: spawns ./medaka + diffs, module does the same [clang] |
| `test/diff_compiler_test_typecheck.sh` | CLI-CONTRACT | interpreter | N | NO | NATIVE-KIND-RUNNER | 1756 | 420 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/diff_compiler_tmc_parity.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, ORACLE-PROBE | 149125 | 125 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_typecheck_errors.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 10341 | 99 | REWRITE: probe/static text becomes library calls |
| `test/diff_compiler_wasm_shim_parity.sh` | RATCHET/LEDGER | none | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 146 | 137 | REWRITE: probe/static text becomes library calls [node] |
| `test/diff_native_cli.sh` | GOLDEN | multiple | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL, SECTION-SPLIT | 18657 | 514 | WRAP: spawns ./medaka + diffs, module does the same [clang,python3] |
| `test/diff_native_stack.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE, EXTERNAL-TOOL | 12975 | 124 | REWRITE: probe/static text becomes library calls [clang] |
| `test/diff_net.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, EXTERNAL-TOOL | 2883 | 90 | WRAP: spawns ./medaka + diffs, module does the same [node] |
| `test/dist_install_smoke.sh` | OTHER | native | N | NO | NATIVE-KIND-RUNNER | 7198 | 92 | WRAP: spawns ./medaka + diffs, module does the same |
| `effect_builtin_param_domain.sh` → `test/effect_builtin_param_domain_test.mdk` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 5175 | 249 | WRAP: migrated to native test [clang] |
| `effect_param_domain.sh` → `test/effect_param_domain_test.mdk` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER | 716 | 80 | WRAP: migrated to native test |
| `effect_product_domain.sh` → `test/effect_product_domain_test.mdk` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER | 1060 | 81 | WRAP: migrated to native test |
| `test/effect_set_domain.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER | 610 | 48 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/fuzz_diff.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, ORACLE-PROBE, EXTERNAL-TOOL | — | 273 | REWRITE: probe/static text becomes library calls [clang] |
| `test/gen_docs_index.sh` | DOC-ROT | none | N | NO | NATIVE-KIND-RUNNER | — | 190 | REWRITE: probe/static text becomes library calls |
| `test/lsp_harness.sh` | PROJECT-SUITE | native | N | NO | NATIVE-KIND-RUNNER | 4533 | 48 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/manifest_emit.sh` | CLI-CONTRACT | native | N | NO | NATIVE-KIND-RUNNER | 599 | 118 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/native_fixtures/run.sh` | GOLDEN | native | N | NO | NATIVE-KIND-RUNNER, INVERTED-POLARITY | — | 198 | WRAP: spawns ./medaka + diffs, module does the same |
| `test/registry_keying_ratchet.sh` | RATCHET/LEDGER | none | N | NO | NATIVE-KIND-RUNNER | — | 808 | REWRITE: probe/static text becomes library calls |
| `test/wasm/diff_gzip.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, ORACLE-PROBE, EXTERNAL-TOOL | — | 290 | REWRITE: probe/static text becomes library calls [clang,node,python3] |
| `test/wasm/diff_playground_input.sh` | DIFFERENTIAL | wasm | N | NO | NATIVE-KIND-RUNNER, ORACLE-PROBE, EXTERNAL-TOOL | — | 97 | REWRITE: probe/static text becomes library calls [node] |
| `test/wasm/diff_sqlite.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, ORACLE-PROBE, EXTERNAL-TOOL | — | 131 | REWRITE: probe/static text becomes library calls [clang,node] |
| `test/wasm/diff_wasm.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, ORACLE-PROBE, EXTERNAL-TOOL | — | 226 | REWRITE: probe/static text becomes library calls [clang,node] |
| `test/wasm/diff_wasm_ffi_wall.sh` | CLI-CONTRACT | wasm | N | NO | NATIVE-KIND-RUNNER, ORACLE-PROBE, EXTERNAL-TOOL | — | 102 | REWRITE: probe/static text becomes library calls [node] |
| `test/wasm/diff_wasm_modules.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, ORACLE-PROBE, EXTERNAL-TOOL | — | 223 | REWRITE: probe/static text becomes library calls [clang,node] |
| `test/wasm/diff_wasm_typed.sh` | DIFFERENTIAL | multiple | N | NO | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE, EXTERNAL-TOOL | — | 2867 | REWRITE: probe/static text becomes library calls [clang,node] |
| `test/arch_census.sh` | RATCHET/LEDGER | none | OUT | n/a | NOT-A-CHECK | — | 94 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/bench.sh` | PERF | native | OUT | n/a | NOT-A-CHECK | — | 247 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/bootstrap_from_seed.sh` | TRUST-ANCHOR | native | OUT | n/a | NOT-A-CHECK | — | 151 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/build_native_medaka.sh` | TRUST-ANCHOR | native | OUT | n/a | NOT-A-CHECK | — | 392 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/build_oracles.sh` | OTHER | native | OUT | n/a | NOT-A-CHECK | — | 544 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/capture_goldens.sh` | GOLDEN | multiple | OUT | n/a | NOT-A-CHECK | — | 991 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/check_self.sh` | OTHER | native | OUT | n/a | NOT-A-CHECK | — | 71 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/cli_conformance_census.sh` | CLI-CONTRACT | native | OUT | n/a | NOT-A-CHECK | — | 297 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/cli_conformance_lib.sh` | OTHER | native | OUT | n/a | NOT-A-CHECK | — | 252 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/comment_register_census.sh` | RATCHET/LEDGER | none | OUT | n/a | NOT-A-CHECK | — | 220 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/diag_census.sh` | RATCHET/LEDGER | native | OUT | n/a | NOT-A-CHECK | — | 148 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/doctest_shape_census.sh` | RATCHET/LEDGER | none | OUT | n/a | NOT-A-CHECK | — | 197 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/error_quality_fixtures/capture.sh` | GOLDEN | multiple (check/run/build) | OUT | n/a | NOT-A-CHECK | — | 107 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/first_hour_census.sh` | RATCHET/LEDGER | native (interpreter, via check --json) | OUT | n/a | NOT-A-CHECK | — | 258 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/fixtures/pr_mock_gh.sh` | OTHER | none | OUT | n/a | NOT-A-CHECK | — | 91 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/fmt_clean_census.sh` | RATCHET/LEDGER | native | OUT | n/a | NOT-A-CHECK | — | 86 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/gate_cost_collect.sh` | OTHER | none | OUT | n/a | NOT-A-CHECK | — | 391 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/gate_cost_ingest.sh` | RATCHET/LEDGER | none | OUT | n/a | NOT-A-CHECK | — | 414 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/lib_scratch.sh` | OTHER | none | OUT | n/a | NOT-A-CHECK | — | 43 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/lib_stale_warning.sh` | OTHER | none | OUT | n/a | NOT-A-CHECK | — | 130 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/o2_survivor_census.sh` | STRUCTURAL-IR | native (clang -O2 over emitted LLVM IR) | OUT | n/a | NOT-A-CHECK | — | 141 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/perf_baseline.sh` | PERF | native | OUT | n/a | NOT-A-CHECK | — | 303 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/perf_shapes.sh` | OTHER | none | OUT | n/a | NOT-A-CHECK | — | 140 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/preflight.sh` | OTHER | none directly | OUT | n/a | NOT-A-CHECK | — | 1900 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/profile_compiler.sh` | PERF | multiple (interpreter+native per-stage drivers) | OUT | n/a | NOT-A-CHECK | — | 120 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/refresh_seed.sh` | TRUST-ANCHOR | native | OUT | n/a | NOT-A-CHECK | — | 58 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/run_gates.sh` | OTHER | multiple | OUT | n/a | NOT-A-CHECK | — | 594 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/slop_census.sh` | RATCHET/LEDGER | native (optional, SLOP_CENSUS_FULL=1) | OUT | n/a | NOT-A-CHECK | — | 149 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/wasm/assemble_check_main.sh` | STRUCTURAL-IR | wasm | OUT | n/a | NOT-A-CHECK | — | 87 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/wasm/build_wasm_oracle.sh` | OTHER | wasm+native | OUT | n/a | NOT-A-CHECK | — | 68 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `test/wasm/w1.sh` | OTHER | wasm | OUT | n/a | NOT-A-CHECK | — | 49 | ledgered in CI-COVERAGE-TOOLS.txt: generator/harness/report, no verdict |
| `pds/test/signing_corpus.sh` | OTHER | none | SHELL | n/a | EXTERNAL-TOOL | 1453 | 6 | subject is a shell/python/browser harness or live gh state; wrap gains nothing |
| `playground/e2e/run.sh` | PROJECT-SUITE | wasm | SHELL | n/a | EXTERNAL-TOOL | — | 99 | subject is a shell/python/browser harness or live gh state; wrap gains nothing |
| `test/bootstrap_eval.sh` | TRUST-ANCHOR | native | SHELL | n/a | TRUST-ANCHOR | 178 | 44 | circular: checks the machinery a native gate would run inside |
| `test/bootstrap_lex.sh` | TRUST-ANCHOR | native | SHELL | n/a | TRUST-ANCHOR | 316 | 63 | circular: checks the machinery a native gate would run inside |
| `test/bootstrap_resolve.sh` | TRUST-ANCHOR | native | SHELL | n/a | TRUST-ANCHOR | 1366 | 55 | circular: checks the machinery a native gate would run inside |
| `test/bootstrap_typecheck.sh` | TRUST-ANCHOR | native | SHELL | n/a | TRUST-ANCHOR | 102 | 41 | circular: checks the machinery a native gate would run inside |
| `test/check_build_oracles_for_consistency.sh` | OTHER | none | SHELL | n/a | TRUST-ANCHOR | 1884 | 105 | circular: checks the machinery a native gate would run inside |
| `test/check_fingerprint_parity.sh` | TRUST-ANCHOR | native | SHELL | n/a | TRUST-ANCHOR | — | 110 | circular: checks the machinery a native gate would run inside |
| `test/check_mutation_transaction.sh` | OTHER | none | SHELL | n/a | EXTERNAL-TOOL | — | 230 | subject is a shell/python/browser harness or live gh state; wrap gains nothing |
| `test/check_no_banned_oracle_cmd.sh` | RATCHET/LEDGER | none | SHELL | n/a | EXTERNAL-TOOL | — | 133 | subject is a shell/python/browser harness or live gh state; wrap gains nothing |
| `test/check_recursive_shell_interpreter.sh` | RATCHET/LEDGER | none | SHELL | n/a | EXTERNAL-TOOL | — | 76 | subject is a shell/python/browser harness or live gh state; wrap gains nothing |
| `test/diff_compiler_check_ir_floor.sh` | PERF | native | SHELL | n/a | EXTERNAL-TOOL | 12907 | 190 | valgrind/cachegrind/wall-clock instrumentation plus statistics; wrap gains nothing |
| `test/diff_compiler_ci_gen_drift.sh` | OTHER | native | SHELL | n/a | TRUST-ANCHOR | — | 85 | circular: checks the machinery a native gate would run inside |
| `test/diff_compiler_ci_guard_failsafe.sh` | OTHER | none | SHELL | n/a | TRUST-ANCHOR, EXTERNAL-TOOL | 116 | 253 | subject IS a verbatim chunk of ci.yml shell; nothing to migrate |
| `test/diff_compiler_ci_shard_coverage.sh` | RATCHET/LEDGER | native | SHELL | n/a | TRUST-ANCHOR | 2403 | 418 | circular: checks the machinery a native gate would run inside |
| `test/diff_compiler_closure_alloc.sh` | PERF | native | SHELL | n/a | EXTERNAL-TOOL | 3983 | 246 | valgrind/cachegrind/wall-clock instrumentation plus statistics; wrap gains nothing |
| `test/diff_compiler_emitted_code_floor.sh` | PERF | native | SHELL | n/a | EXTERNAL-TOOL | 13022 | 178 | valgrind/cachegrind/wall-clock instrumentation plus statistics; wrap gains nothing |
| `test/diff_compiler_eval_scaling.sh` | PERF | multiple | SHELL | n/a | EXTERNAL-TOOL | 9159 | 381 | valgrind/cachegrind/wall-clock instrumentation plus statistics; wrap gains nothing |
| `test/diff_compiler_fixture_corpus_coverage.sh` | RATCHET/LEDGER | none | SHELL | n/a | TRUST-ANCHOR | 16770 | 322 | circular: checks the machinery a native gate would run inside |
| `test/diff_compiler_gate_balance.sh` | RATCHET/LEDGER | none | SHELL | n/a | TRUST-ANCHOR | — | 735 | circular: checks the machinery a native gate would run inside |
| `test/diff_compiler_gate_budget.sh` | RATCHET/LEDGER | none | SHELL | n/a | TRUST-ANCHOR | — | 271 | circular: checks the machinery a native gate would run inside |
| `test/diff_compiler_gate_cost.sh` | OTHER | none | SHELL | n/a | TRUST-ANCHOR | — | 400 | circular: checks the machinery a native gate would run inside |
| `test/diff_compiler_gate_registry.sh` | RATCHET/LEDGER | none | SHELL | n/a | TRUST-ANCHOR | 1182 | 128 | circular: checks the machinery a native gate would run inside |
| `test/diff_compiler_ir_scaling.sh` | PERF | interpreter | SHELL | n/a | EXTERNAL-TOOL | 302992 | 1177 | valgrind/cachegrind/wall-clock instrumentation plus statistics; wrap gains nothing |
| `test/diff_compiler_perf_scaling.sh` | PERF | multiple | SHELL | n/a | EXTERNAL-TOOL | 340370 | 4996 | valgrind/cachegrind/wall-clock instrumentation plus statistics; wrap gains nothing |
| `test/diff_compiler_preflight_base.sh` | OTHER | none | SHELL | n/a | TRUST-ANCHOR | 179 | 157 | circular: checks the machinery a native gate would run inside |
| `test/diff_compiler_project_enrolment.sh` | RATCHET/LEDGER | none | SHELL | n/a | TRUST-ANCHOR | 10322 | 368 | circular: checks the machinery a native gate would run inside |
| `test/diff_compiler_prose_classifier.sh` | DIFFERENTIAL | native | SHELL | n/a | TRUST-ANCHOR, EXTERNAL-TOOL | 587 | 145 | subject IS a verbatim chunk of ci.yml shell; nothing to migrate |
| `test/diff_compiler_reach_fail_open.sh` | OTHER | none | SHELL | n/a | TRUST-ANCHOR, EXTERNAL-TOOL | 2207 | 336 | subject IS a verbatim chunk of ci.yml shell; nothing to migrate |
| `test/diff_compiler_references_scaling.sh` | PERF | native | SHELL | n/a | EXTERNAL-TOOL | 1288 | 235 | valgrind/cachegrind/wall-clock instrumentation plus statistics; wrap gains nothing |
| `test/diff_compiler_selfproc.sh` | TRUST-ANCHOR | multiple | SHELL | n/a | TRUST-ANCHOR | 16303 | 204 | circular: checks the machinery a native gate would run inside |
| `test/diff_compiler_stage_ir_scaling.sh` | PERF | multiple | SHELL | n/a | EXTERNAL-TOOL | 647833 | 1528 | valgrind/cachegrind/wall-clock instrumentation plus statistics; wrap gains nothing |
| `test/diff_compiler_tier_drift.sh` | RATCHET/LEDGER | none | SHELL | n/a | TRUST-ANCHOR | 40540 | 352 | circular: checks the machinery a native gate would run inside |
| `test/must_fail_census.sh` | RATCHET/LEDGER | none | SHELL | n/a | EXTERNAL-TOOL | — | 458 | subject is a shell/python/browser harness or live gh state; wrap gains nothing |
| `test/pr_helper_test.sh` | OTHER | none | SHELL | n/a | EXTERNAL-TOOL | 10651 | 297 | subject is a shell/python/browser harness or live gh state; wrap gains nothing |
| `test/selfcompile_build_fixpoint.sh` | TRUST-ANCHOR | native | SHELL | n/a | TRUST-ANCHOR | 57702 | 130 | circular: checks the machinery a native gate would run inside |
| `test/selfcompile_emit.sh` | TRUST-ANCHOR | multiple | SHELL | n/a | TRUST-ANCHOR | 16855 | 147 | circular: checks the machinery a native gate would run inside |
| `test/selfcompile_fixpoint.sh` | TRUST-ANCHOR | native | SHELL | n/a | TRUST-ANCHOR | — | 199 | circular: checks the machinery a native gate would run inside |
| `test/selfcompile_lex.sh` | TRUST-ANCHOR | multiple | SHELL | n/a | TRUST-ANCHOR | 17413 | 179 | circular: checks the machinery a native gate would run inside |
| `test/typecheck_compiler_source.sh` | TRUST-ANCHOR | native | SHELL | n/a | TRUST-ANCHOR | — | 1346 | circular: checks the machinery a native gate would run inside |
| `test/wasm/diff_visitor_analyze_latency.sh` | PERF | wasm | SHELL | n/a | EXTERNAL-TOOL | — | 64 | valgrind/cachegrind/wall-clock instrumentation plus statistics; wrap gains nothing |
| `test/wasm/diff_visitor_cost_bytes.sh` | PERF | none | SHELL | n/a | EXTERNAL-TOOL | — | 77 | valgrind/cachegrind/wall-clock instrumentation plus statistics; wrap gains nothing |
| `test/wasm/diff_wasm_emitted_size.sh` | PERF | wasm | SHELL | n/a | EXTERNAL-TOOL | — | 233 | valgrind/cachegrind/wall-clock instrumentation plus statistics; wrap gains nothing |
| `pds/test/encodings_vectors.sh` | GOLDEN | interpreter (eval only) | T | NO | TEST-IO | 994 | 84 | pure in-language assertions over a library function |
| `pds/test/secp256k1_public_key.sh` | OTHER | native | T | YES | NONE | 2324 | 33 | pure in-language assertions over a library function |
| `pds/test/vector_provenance.sh` | RATCHET/LEDGER | none | UNSURE | UNSURE | NATIVE-KIND-RUNNER, EXTERNAL-TOOL | 1869 | 834 | UNSURE: also a shared helper (--files-for) called by ~8 sibling gates; migrating it moves a de-facto library, not just a check |
| `test/diff_compiler_ported.sh` | INLANG-WRAPPER | interpreter | UNSURE | UNSURE | NATIVE-KIND-RUNNER, EXTERNAL-TOOL, INVERTED-POLARITY | 2785 | 231 | UNSURE: the tests are already (T); the shell is a known-bug ledger + anti-vacuity floor that derived discovery may retire outright rather than migrate |
| `test/diff_compiler_test.sh` | GOLDEN | interpreter | UNSURE | UNSURE | NATIVE-KIND-RUNNER, GOLDEN-ASSERT, ORACLE-PROBE | 59668 | 326 | UNSURE: goldens are OCaml-era captures for a compiler that no longer exists; what the gate still proves must be settled before a destination is picked |
| `test/tmc_census.sh` | STRUCTURAL-IR | multiple | UNSURE | UNSURE | NOT-A-CHECK | — | 209 | UNSURE: ledgered as a tool but exits nonzero on EMIT-FAIL/PINFAIL, i.e. a real gate wrapped by diff_compiler_tmc_parity; denominator membership unresolved |
