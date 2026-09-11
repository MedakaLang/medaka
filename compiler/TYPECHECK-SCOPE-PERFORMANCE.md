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

## Method-row preparation follow-up

The independent Sol reviewer repeated the same instruments on method-row revision
`cd42e56f4` (running-branch equivalent `ee61c0a35`) against its scope predecessor
`a4927caaf`. These results isolate that preparation step more narrowly than the
cumulative table above. Both allocation repetitions were byte-identical; all
selected request diagnostics were empty and no stale-source warnings occurred.

| Workload | Request | Instructions before | After | Allocation before | After |
|---|---|---:|---:|---:|---:|
| playground | cold | 305,249,022 | 305,233,973 | 48,594,048 | 48,577,648 |
| playground | first warm | 24,952,500 | 24,818,526 | 4,578,784 | 4,566,496 |
| playground | second warm | 24,945,821 | 24,826,707 | 4,587,056 | 4,570,656 |
| import-list | cold | 538,578,855 | 538,290,319 | 93,160,864 | 93,135,952 |
| import-list | first warm | 38,330,580 | 38,146,599 | 6,904,432 | 6,871,904 |
| import-list | second warm | 38,316,900 | 38,200,952 | 6,907,888 | 6,903,744 |

Every measured delta is negative: instructions range from -0.005% to -0.537%,
allocation from -0.027% to -0.471%. Raw candidate receipts are in
`/tmp/rearch-method-rows-review-instructions` and
`/tmp/rearch-method-rows-review-allocation`; predecessor receipts are the scope
measurements above. These remain allocation and instruction measurements, not
retained-live-heap measurements. The later scope classification fix and future
cache changes are outside this exact comparison.
