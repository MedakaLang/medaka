# Visitor battery

Sixty-odd programs of the kind a newcomer types in their first hour, used for the
HN-readiness review on 2026-10-02. Each `NN_name.mdk` is standalone; `tools/` holds the
drivers (`run_battery.sh` for run/native/wasm-in-node, `browser_battery.mjs` for the live
playground in system Chrome, `show_results.py` to read a results dir).

Exit column key: `0` ran, `1` program error or diagnostic, `124` killed by timeout, `B1` build
refused, `C1` playground compiler refused, `P` wat did not parse. Browser column: `ok` printed
the compiled-and-ran line, `diag` a located diagnostic, `TRAP` "compiler trap", `HANG` >45 s.

| program | run | native | wasm (node) | live browser |
|---|---|---|---|---|
| 01_hello | 0 (0.14s) | 0 (0.85s) | 0 (0.98s) | ok (2.0s) |
| 02_main_paren_mistake | 1 (0.12s) | B1 (0.20s) | C1 (0.55s) | diag (0.6s) |
| 03_fizzbuzz | 0 (0.17s) | 0 (0.77s) | 0 (1.03s) | ok (0.9s) |
| 04_fib_naive_30 | 0 (21.44s) | 0 (0.80s) | 0 (1.03s) | ok (0.9s) |
| 05_factorial_overflow | 1 (0.15s) | 1 (0.81s) | 1 (1.13s) | other (0.9s) |
| 06_quicksort | 0 (0.13s) | 0 (0.87s) | 0 (1.08s) | ok (0.9s) |
| 07_wordfreq | 0 (0.28s) | 0 (1.16s) | 0 (1.82s) | ok (1.7s) |
| 08_expr_eval | 0 (0.13s) | 0 (0.76s) | 0 (1.07s) | ok (0.9s) |
| 09_records | 0 (0.13s) | 0 (0.80s) | 0 (1.42s) | ok (1.1s) |
| 10_interface | 0 (0.12s) | 0 (0.78s) | 0 (1.00s) | ok (0.9s) |
| 11_strings | 1 (0.16s) | B1 (0.25s) | C1 (0.61s) | diag (0.6s) |
| 12_floats | 0 (0.13s) | 0 (0.75s) | 0 (1.02s) | ok (0.9s) |
| 13_int_div_zero | 1 (0.15s) | 1 (0.73s) | 1 (1.05s) | other (0.9s) |
| 14_deep_recursion | 1 (0.31s) | 0 (0.84s) | 1 (1.04s) | other (0.8s) |
| 15_tail_loop_1M | 1 (0.31s) | 0 (0.84s) | 0 (1.09s) | ok (0.8s) |
| 16_option_result | 0 (0.18s) | 0 (0.88s) | C1 (2.77s) | TRAP (2.4s) |
| 17_json | 0 (0.29s) | 0 (1.52s) | C1 (4.65s) | HANG (45.4s) |
| 18_hof_pipeline | 0 (0.17s) | 0 (0.91s) | 0 (1.44s) | ok (1.4s) |
| 19_type_error | 1 (0.14s) | B1 (0.20s) | C1 (0.58s) | diag (0.6s) |
| 20_typo_unbound | 1 (0.07s) | B1 (0.09s) | C1 (0.34s) | diag (0.6s) |
| 21_haskell_isms | 1 (0.06s) | B1 (0.06s) | C1 (0.11s) | diag (0.6s) |
| 22_haskell_case_of | 1 (0.06s) | B1 (0.07s) | C1 (0.12s) | diag (0.6s) |
| 23_ocaml_isms | 1 (0.07s) | B1 (0.08s) | C1 (0.12s) | diag (0.6s) |
| 24_print_structures | 0 (0.13s) | 0 (0.73s) | 0 (1.00s) | ok (0.9s) |
| 25_sieve_10k | 0 (15.87s) | 0 (0.87s) | 0 (1.14s) | ok (0.8s) |
| 26_nqueens_8 | 1 (0.07s) | B1 (0.07s) | C1 (0.12s) | diag (0.6s) |
| 27_collatz_100k | 124 (40.01s) | 0 (0.90s) | 0 (1.21s) | ok (0.9s) |
| 28_tuples | 0 (0.14s) | 0 (0.83s) | 0 (1.06s) | ok (0.9s) |
| 29_unicode | 1 (0.18s) | B1 (0.27s) | C1 (0.61s) | diag (0.6s) |
| 30_effect_violation | 1 (0.14s) | B1 (0.21s) | C1 (0.56s) | diag (0.6s) |
| 31_custom_effect | 0 (0.14s) | 0 (0.90s) | 0 (1.14s) | ok (0.9s) |
| 32_arrays_vectors | 0 (0.31s) | 0 (1.17s) | C1 (4.62s) | TRAP (3.5s) |
| 33_map_set | 0 (0.37s) | 0 (1.44s) | 0 (2.01s) | ok (1.9s) |
| 34_stdin | 0 (0.15s) | 0 (0.85s) | C1 (0.83s) | TRAP (0.6s) |
| 35_int_bounds | 1 (0.14s) | 1 (0.79s) | 1 (1.12s) | other (0.8s) |
| 36_string_to_int | 0 (0.16s) | 0 (0.88s) | C1 (2.89s) | TRAP (2.4s) |
| 37_indentation_error | 1 (0.07s) | B1 (0.06s) | C1 (0.30s) | diag (0.6s) |
| 38_no_main | 1 (0.15s) | B1 (0.23s) | C1 (0.57s) | diag (0.6s) |
| 39_shadow_prelude | 0 (0.14s) | 0 (0.86s) | 0 (1.10s) | ok (0.9s) |
| 40_display_tree | 0 (0.16s) | 0 (0.86s) | 0 (1.14s) | ok (0.9s) |
| 41_curried_lambda | 0 (0.16s) | 0 (0.89s) | 0 (1.11s) | ok (0.9s) |
| 42_for_loop_attempt | 1 (0.07s) | B1 (0.07s) | C1 (0.12s) | diag (0.6s) |
| 43_large_output | 0 (0.60s) | 0 (0.87s) | 0 (1.39s) | ok (27.2s) |
| 44_panic | 1 (0.16s) | 1 (0.87s) | 1 (1.25s) | other (0.9s) |
| 45_chars | 1 (0.23s) | B1 (0.30s) | C1 (0.75s) | diag (0.6s) |
| 46_list_index | 1 (0.13s) | 1 (0.80s) | 1 (1.09s) | other (0.9s) |
| 47_negative_literals | 0 (0.13s) | 0 (0.78s) | 0 (1.06s) | ok (0.9s) |
| 48_mutual_rec_data | 0 (0.13s) | 0 (0.87s) | 0 (1.21s) | ok (1.1s) |
| 49_async | 1 (0.40s) | B1 (0.64s) | C1 (0.27s) | diag (0.6s) |
| 50_where_helper_shadow | 0 (0.14s) | 0 (0.74s) | 0 (1.05s) | ok (0.9s) |
| 51_infinite_loop | 1 (0.29s) | 124 (40.71s) | 124 (41.00s) | other (10.8s) |
| 52_match_guard_exhaust | 1 (0.15s) | 1 (0.84s) | 1 (1.26s) | other (0.9s) |
| 53_forEach_println | 1 (0.24s) | B1 (0.29s) | C1 (0.86s) | diag (0.6s) |
| 54_length_of_string | 1 (0.22s) | B1 (0.21s) | C1 (0.56s) | diag (0.6s) |
| 55_pow_operator | 1 (0.07s) | B1 (0.07s) | C1 (0.11s) | diag (0.6s) |
| 56_not_equal_operator | 1 (0.08s) | B1 (0.07s) | C1 (0.11s) | diag (0.6s) |
| 57_map_insert_typo | 1 (0.12s) | B1 (0.12s) | C1 (0.86s) | diag (0.6s) |
| 58_ocaml_match_with | 1 (0.07s) | B1 (0.06s) | C1 (0.12s) | diag (0.6s) |
| 59_while_attempt | 1 (0.07s) | B1 (0.07s) | C1 (0.30s) | diag (0.6s) |
| 60_string_concat_int | 1 (0.12s) | B1 (0.22s) | C1 (0.58s) | diag (0.6s) |
| 61_if_no_else_value | 1 (0.14s) | B1 (0.24s) | C1 (0.65s) | diag (0.6s) |
| 62_fib_memo_map | 0 (0.36s) | 0 (1.09s) | 0 (1.80s) | ok (1.1s) |
| 63_show_negative_in_ctor | 0 (0.15s) | 0 (1.00s) | 0 (1.32s) | ok (0.9s) |
