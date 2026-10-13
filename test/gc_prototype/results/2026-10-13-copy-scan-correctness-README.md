# Copy/scan Variant V correctness outcome

Variant V passed correctness checks after the source-only handoff at `c3f19e532`. Candidate `gc.c` SHA256 is `02246c8148d2086ae70aef645305298605b3249c40f2ee666a4b9fb1a217de11`; the header and workload remain byte-identical to baseline `85c364304684c44c544957c8ba2b180d15d736c5`. No candidate was installed in the repository, and no Variant V performance measurements were made.

The unchanged `run.py --correctness-only` suite exited 0: 203 positive fixture processes and 10 expected negative processes passed across all ten backends, prepared API, pool and adversarial capacity matrices, and the hand-written LLVM root contract. It made 24 successful builds. Five initial Clang sanitizer-runtime linker failures and the successful installed-GCC-runtime fallback commands are preserved verbatim. ASan and UBSan instrumentation remained active; LeakSanitizer was disabled. The wrapper overrides only isolated input paths and the adapter's input runtime; semantic assertions and fixture sources are unchanged. A delegating observer records nested LLVM subprocess commands, failures, outputs and binary hashes.

The separate bounded verifier exited 0: 22 sanitized positive processes (11 cases per arm) and seven exact named negative controls passed. All 12 paired stages / 24 raw stats snapshots matched in all 46 fields (45 numeric fields plus `stage`). Its nine initial sanitizer linker failures and nine successful fallback builds are retained. Independent review confirmed the source archive, counters, exact markers, and ASan/UBSan imports in the nine binaries. These targeted fixtures use `-O1`; the full suite mainly uses `-O2`, with its LLVM `-O0` control retained.

The manifest indexes every decoded archive member by size and SHA256. The archive contains complete commands, outputs and errors, execution and independent audit records, unchanged helper/fixture sources, all 17 members of the historical source archive, the exact baseline runtime used for production Boehm adapters, and the proposed timing plan. Rebuildable binaries are omitted; their 33 build hashes remain in execution records. Full-suite binaries were automatically removed with its temporary directory, so those 24 hashes are compile-time receipts rather than currently rehashable files; the verifier auditor separately rehashed its nine retained binaries. Historical source-only records are preserved verbatim and describe the earlier stage. `planning/UNIMPLEMENTED-UNEXECUTED-timing-plan.md` is planning evidence, not an executed or frozen timing harness.

## Reproduction

Verify the archive checksum against the adjacent manifest, extract it into a new directory, and use a repository whose prototype helper and fixture hashes match `full-suite/inputs`. The full-suite replay first checks those identities and prepares a new scratch directory. Omitting `--execute` performs preparation only:

```sh
python3 replay.py --repo /abs/medaka --output /tmp/variant-v-full-replay
```

To run the same unchanged full suite, use a different fresh output directory:

```sh
python3 replay.py --repo /abs/medaka --output /tmp/variant-v-full-execution --execute
```

The bounded verifier can independently rebuild from the retained sources:

```sh
python3 independent/restore/verification/run.py --source-root independent/restore/sources --packet independent/restore/plan/accepted-plan.md --output /tmp/variant-v-bounded-replay --execute
```

The full-suite wrapper pins the original source archive hash, baseline runtime from `git show`, Clang executable, static Boehm archive, and generated adapter hashes. Those external toolchain files are not bundled. Targeted sanitizer library hashes are post-run receipts, not a complete before/after dependency freeze. Both executions record selected environments; they are not fully hermetic host replays. Correctness does not establish performance or production integration. The LLVM contract is hand-written and does not test Medaka-generated roots. No historical evidence is superseded beyond the new correctness status.
