# Copy/scan-fusion Variant V: source-only handoff

Status: UNBUILT / UNEXECUTED. The collector candidate, C fixture and seven
mutation controls have not been compiled or run. Verification --execute has
never run. Source review passed; no correctness execution PASS, performance
claim, policy selection or production integration follows. Preparation metadata
and Python syntax checks were performed; plan.json says execution_performed=false.

The main collector remains 85c364304684c44c544957c8ba2b180d15d736c5. Variant V
retains its minor vector capacity/growth but queues nursery source Header pointers.
Traced promotions save field0 and complete later words directly from the nursery;
destination descriptors govern scanning. Atomic objects keep full copying and
queueing; remembered scanning, direct-old zeroing/padding and major marking stay
unchanged. All deterministic counters/storage and old-limit schedules are expected
to match 85 exactly. This expectation has not been tested. Intrusive queue work
was not advanced; fusion is compared against the original vector queue only.

The new temporary invariant keeps incomplete forwarded old destinations private
until all minor work completes before nursery poison, major collection or mutator
resumption. It assumes the existing single-mutator/no-reentry collector. It does
not authorize uninitialized public allocation, callbacks or concurrent marking.

The reproduction archive contains exact baseline/candidate gc.c, identical gc.h
and workload.c, the source patch/manifest, accepted diagnostic plan, prepared
independent fixture/runner/control metadata and independent source-review receipt.
The external manifest binds every member's SHA256/size and original path.
No host executable, library archive, object file or measurement artifact is needed.
Source-review PASS is separate from execution, and nursery-range checks are not
general authentication of arbitrary pointers.

## Restore without old /tmp files

Choose a fresh empty extraction directory; these commands are for the next session,
not commands already run. Replace the extraction path if it already exists.

```sh
mkdir /tmp/medaka-copy-scan-handoff-next
tar -xzf test/gc_prototype/results/2026-10-13-copy-scan-source-reproduction.tar.gz -C /tmp/medaka-copy-scan-handoff-next
```

The runner supports relocation via explicit --source-root and --packet; restoring
the recorded original absolute paths is unnecessary. Verify archive/member hashes
against 2026-10-13-copy-scan-source-manifest.json before using the sources.
The preparation helper is provenance, not a required restore step: it uses the
original repository path and pinned git commit. The archived C sources are complete.

After explicit resume and CPU scheduling, the first command prints a source-only
plan without compiling or invoking the C fixture:

```sh
python3 /tmp/medaka-copy-scan-handoff-next/verification/run.py --source-root /tmp/medaka-copy-scan-handoff-next/sources --packet /tmp/medaka-copy-scan-handoff-next/plan/accepted-plan.md
```

Only after the next session authorizes and reserves the CPU slot:

```sh
python3 /tmp/medaka-copy-scan-handoff-next/verification/run.py --source-root /tmp/medaka-copy-scan-handoff-next/sources --packet /tmp/medaka-copy-scan-handoff-next/plan/accepted-plan.md --execute --output /tmp/medaka-copy-scan-verification-next
```

The output directory must be empty/nonexistent. Requirements are Python 3.10+,
a 64-bit C11 Clang toolchain and ASan/UBSan runtimes (no Boehm dependency for
this prepared verifier). Capture compiler version/hash and execution provenance
then; this source-only handoff contains no measured toolchain or binary claim.

Prepared scope: nine builds; 22 positive runs (11 cases × 2 arms); seven named
negative controls. It compares every deterministic printed snapshot plus old_limit,
checks raw field0/bit63/tails/atomic data/cycles/aliases/remembered chains/direct-old
zeroing/lifecycle, and journals commands/results including failures. A valid mutant
grade requires status86 and its exact FIXTURE_FAIL marker; crashes, sanitizer
reports and timeouts do not count. See verification/plan.json for markers/flags.

If those checks pass, the accepted plan still requires the existing full collector
correctness matrix, independent review and a separate timing handoff. Neither a
performance runner nor performance results are supplied here. Do not replace main
gc.c, edit compiler/ByteBlock sources or choose a policy merely to resume validation.
