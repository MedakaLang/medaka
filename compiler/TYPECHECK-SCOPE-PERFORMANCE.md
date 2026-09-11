# Nominal scope validation: LSP measurements

Measured cumulative running branch `a4927caaf5ea4e4185ff404f96871b59b3346c78` against starting revision `2b6e08c8d9da9fd02ed06bc748b2fd313e174726`. These are workload observations, not an attribution of every difference to one helper.

| Workload | Metric | Before | After | Change |
|---|---|---:|---:|---:|
| playground | cold instructions | 356,961,559 | 305,249,022 | -14.49% |
| playground | first warm instructions | 24,936,667 | 24,952,500 | +0.06% |
| playground | second warm instructions | 24,945,515 | 24,945,821 | +0.001% |
| import-list | cold instructions | 593,052,249 | 538,578,855 | -9.19% |
| import-list | first warm instructions | 38,318,523 | 38,330,580 | +0.03% |
| import-list | second warm instructions | 38,273,108 | 38,316,900 | +0.11% |
| playground | cold allocated bytes | 59,258,992 | 48,594,048 | -18.00% |
| playground | first warm allocated bytes | 4,570,096 | 4,578,784 | +0.19% |
| playground | second warm allocated bytes | 4,582,448 | 4,587,056 | +0.10% |
| import-list | cold allocated bytes | 104,422,192 | 93,160,864 | -10.78% |
| import-list | first warm allocated bytes | 6,895,456 | 6,904,432 | +0.13% |
| import-list | second warm allocated bytes | 6,886,320 | 6,907,888 | +0.31% |

Use the same N=0..3 request streams on both binaries. N0 initializes/shuts down; N1 adds didOpen; N2/N3 add successive one-integer didChange edits. Subtract N0 from N1 for cold work and adjacent measurements for warm work. The playground source defines `add : Int -> Int -> Int` and prints `add 2 3`; import-list additionally imports `list.range` and defines `ys : List Int = range 1 3`. Both use fixed file URIs under `/tmp/rearch-scope-perf`.

Instruction instrument: Valgrind Cachegrind 3.24.0 with cache/branch simulation disabled. Allocation instrument: an external LD_PRELOAD destructor prints `GC_get_total_bytes()` and process id at exit, with no compiler instrumentation or source changes. Pin `GC_INITIAL_HEAP_SIZE=1073741824`, set the appropriate `MEDAKA_ROOT`, and require `MEDAKA_STRICT=1`. Every run exited successfully and published the expected empty diagnostics for its selected URI; allocation records were unique and matched the parent process. Two allocation repetitions were byte-identical. Frame counts and allocation totals do not measure retained/live heap; matched lifecycle live-heap instrumentation remains package-7 debt.

Receipts and reusable runners in this workspace:

- `/tmp/rearch-scope-perf/run_lsp_cachegrind.py` and baseline `measure.log`.
- `/tmp/rearch-scope-allocation/gc_counter.c`, `libgc_counter.so`, `run_allocation.py`, baseline `measure.log`.
- `/tmp/rearch-nominal-perf.py`, candidate `/tmp/rearch-nominal-perf/instructions.log` and `allocation.log`; individual request responses and tool output in their subdirectories.

This scope slice leaves cache policy unchanged and is within the existing approximately 25% soft instruction budget on these workloads. It says nothing about the later return vertical's proposed all-three memo bypass, whose cost must be measured separately before activation.
