# Explicit-root collector experiment

This is an on-demand C/LLVM test and synthetic benchmark, not a Medaka compiler
backend, runtime option, or CI gate. Production keeps Boehm. The design decision
and compiler profiling evidence live in [GC feasibility](../../docs/design/GC-FEASIBILITY.md).

Run from any directory, with Python 3, clang, and Boehm development headers
installed (`pkg-config bdw-gc`, or Homebrew `bdw-gc`):

```console
python3 /absolute/path/to/medaka/test/gc_prototype/run.py --correctness-only
python3 /absolute/path/to/medaka/test/gc_prototype/run.py --count 5000000 --nursery-bytes 262144
python3 /absolute/path/to/medaka/test/gc_prototype/run.py --count 5000000 --nursery-bytes 1048576 --profiles ephemeral mutation
```

`CC` selects clang. All generated adapters, mutation variants, and binaries use
temporary directories and are removed on exit. The driver clears inherited
`GC_*` settings, sets Boehm's free-space divisor to 1, and uses its default initial
heap size. It reports the actual divisor and the inline source SHA-256. This
initial heap policy differs from a compiler run with a fixed 2 GiB heap; these
results cannot be used to predict compiler speedups.

The driver prefers `libgc.a` and its pkg-config private dependencies to match the
production compiler's static Boehm linkage. If the archive is unavailable it
reports a dynamic-link fallback explicitly. Provenance includes the platform,
compiler version, Git base, source hashes, link flags, and static archive hash.
Output consists of JSON lines, including correctness and LLVM fixture statuses.

For a separate profile of real compiler `check`, use a new empty output directory:

```console
python3 /absolute/path/to/medaka/test/gc_prototype/profile_boehm.py --root /absolute/path/to/medaka --binary /absolute/path/to/medaka/medaka --workload compiler/driver/medaka_cli.mdk --output /new/empty/directory --heap-size 134217728
python3 /absolute/path/to/medaka/test/gc_prototype/profile_boehm.py --root /absolute/path/to/medaka --binary /absolute/path/to/medaka/medaka --workload compiler/driver/medaka_cli.mdk --output /another/new/empty/directory --heap-size 134217728 --mode gc-stats
```

The compiler profiler defaults to three timing repeats, or one run in `gc-stats`
mode. It rejects stdout/stderr disagreement, workload failure, timeout, and missing
or incomplete GC statistics. This profiles compiler checking, not native fixture
execution. Parent-owned baseline data is in `results/`.

Correctness runs first, including ASan + UBSan. On Linux with missing clang
sanitizer libraries the driver links the installed GCC ASan/UBSan runtimes with
clang instrumentation. LeakSanitizer is disabled because sandbox ptrace prevents
it from running; exact old-generation reclamation has explicit assertions.
UBSan errors fail the command. A sanitizer or fixture failure stops timing.

The single-thread custom collector uses:

- Tagged 64-bit words: zero is null, odd words are immediates, and aligned nonzero
  words are exact payload pointers. There are no interior pointers or immortal/
  static objects: every nonzero even pointer must refer to an object with this
  collector's header. Production raw pointers and static function values would
  require an explicit additional representation/descriptor contract.
- An eight-byte-aligned bump nursery. A collection promotes every reachable
  nursery object into the nonmoving old generation, updates root slots and
  pointer fields, and handles aliases/cycles through forwarding headers. Used
  nursery bytes are poisoned after collection to make stale-root mutation checks
  deterministic. This extra diagnostic write is included in timing.
- Shared descriptors with a bitmap covering the first 64 words. Zero means
  pointer-free; such payloads can exceed 64 words. Scanning ignores all other
  payload bits. The descriptor is supplied at allocation, not inferred.
- One eight-byte header containing a shared descriptor index and collector bits.
  During evacuation, the young header instead holds the forwarding address.
  A 24-byte payload occupies 32 bytes in either generation. Descriptors are
  interned by word count and scan bitmap; table capacity is reported separately.
- Mature size-class pools for objects up to 2 KiB including their header. Dead
  slots carry free-list links; sweep reuses partially live pools and releases
  completely empty pools. Larger mature objects have individual allocations
  with separately counted list metadata. An object larger than the nursery
  starts in mature storage, using a pool when its size allows.
- Separate remembered-object and tracing work vectors. Every old-to-young write
  goes through `store`; only pointer slots may hold pointers. Vector capacity
  and descriptor tables remain allocated until heap destruction and are included
  in reported storage.
- Major mark/sweep before allocation when old requested bytes cross an adaptive
  threshold: initially four nursery capacities, then twice the live old bytes
  plus four nursery capacities. A major starts with nursery promotion and scans
  every reserved mature pool slot. The mature generation is nonmoving.

`gc.h` is the explicit-root API. Register a mutable word slot with `root_push`
before an operation that can allocate/collect. Reload that slot after the
operation. `root_pop` must follow stack order, and a tail call must unregister
the caller's frame before transferring control. A pointer held only in a C local
or SSA register is insufficient for the custom collector. The Boehm arm compiles
the shadow-root operations away and relies on its production conservative C
stack/register contract. `GC_reachable_here` keeps final workload roots visible
through the final Boehm collection.

Both Boehm comparators use the same workload source. `boehm` uses `GC_malloc` for
pointer-bearing objects and `GC_malloc_atomic` for pointer-free ones.
`boehm_inline` uses the small-object allocator extracted at build time from
`runtime/medaka_rt.c`, with its version guard, granule rounding, disabled
`GC_ASSERT`, and traced uncollectable free-list heads preserved. Versions outside
libgc 8.2 fall back to `GC_malloc`; `inline_available` reports that. Atomic objects
continue through `GC_malloc_atomic`. The extractor deliberately fails if its
source boundaries change, so drift needs a conscious update.

Correctness fixtures check root updates, aliasing, sharing, cycles, remembered
old-to-young writes, repeated collections with a 240-byte nursery, large objects,
pointer-looking atomic data, and root dropping followed by major reclamation.
The independent [adversarial graph model](adversarial.c) mutates a shared cyclic
graph across 5,000 allocations, compares every reachable edge against an integer
model, verifies exact liveness/accounting, and exercises descriptor slot 63 across
the nursery/direct-old boundary. The runner executes it with ASan/UBSan at 35
capacities from 32 bytes through 256 KiB, including the 520-byte object boundary.
The independent [pool review fixture](pool_review.c) additionally exercises
descriptor-table growth, mixed object sizes, partial-pool reuse with different
descriptors, complete pool release, large allocations, aliasing, cycles, and
heap destruction/reinitialization.
Temporary broken builds suppress root-slot updates or the remembered-set barrier;
the corresponding fixtures must fail at their assertions. They do not dereference
the stale references and no broken variant is installed or committed.

The hand-written [LLVM contract fixture](llvm_contract/contract.ll) additionally
checks relocated root reloads, an earlier argument across a later allocating
helper, and 10,000 `musttail` transfers with balanced roots. It passes at `-O0`,
`-O2`, and `-O2` with ASan/UBSan. Omitting either reload must produce its specified
failure. It demonstrates an implementable contract in optimized LLVM; it does
not test the Medaka emitter or prove that generated programs satisfy that contract.
It can also run directly:

```console
python3 /absolute/path/to/medaka/test/gc_prototype/llvm_contract/validate_llvm.py --gc-source /absolute/path/to/medaka/test/gc_prototype/gc.c
```

The separate [generated-code harness](generated_contract/validate.py) compiles
three Medaka source fixtures through the typed LLVM probe, validates their
emitted straight-line IR against trusted record/function contracts, and inserts
explicit root slots and reloads. It links a small startup/printing shim and this
collector. It does not change the production emitter or support general LLVM.

Build only the required probe from the repository root, then choose a new or
empty evidence directory:

```console
sh test/build_oracles.sh --build-one llvm_emit_typed_main
python3 /absolute/path/to/medaka/test/gc_prototype/generated_contract/validate.py --output /new/empty/directory
```

The harness checks 18 successful builds, two exact wrong-answer mutations, and
19 source/IR rejection cases. Positive cases cover two collection schedules at
`-O0` and `-O2`, ASan/UBSan, and the ordinary Boehm adapter over the same transformed
IR. Root slots remain registered for the whole function, so these are correctness
checks only. Unsupported control flow, recursion, mutation, globals, raw-pointer
lifetimes, and runtime helpers are rejected. Semantic contracts are independent
oracle inputs for these known fixtures; neither `LTInt` nor arbitrary `i64` is
treated as pointer provenance. Emitted/transformed LLVM and full provenance are
written to the chosen output directory; an existing nonempty directory is refused.
The committed [validation record](results/2026-10-12-generated-contract.json)
contains the exact hashes, commands, schedules, expected and observed outputs.

The six timing profiles all allocate 24-byte payloads. Ephemeral lists drop their
root every 256 nodes. The list and balanced tree retain every node. Mutation keeps
an old anchor whose child is replaced every 64 nodes, exercising the barrier.
Atomic allocates pointer-free three-word payloads. Mixed retains every 64th node
in a growing spine while dropping each batch of temporary nodes. Its retained
spine checksum and exact post-collection object count are checked. This is a
synthetic lifetime distribution, not a captured compiler allocation trace.
The mutation profile has one
extra anchor allocation. Every arm must produce the same allocation count,
logical payload byte count, and arithmetic checksum for each profile. Payloads
are read to calculate the checksum and the checksum is observed through a
volatile sink, so the compiler cannot remove the workload allocations.

Each backend/profile runs in three fresh processes, sequentially. The driver
reports all three timings and the statistics from the fastest sample. Time covers
workload construction, checksum traversal, and a final full collection with the
profile's final roots still live. It excludes heap initialization, output, and
destruction. That final collection makes custom old live bytes exact at the
measurement boundary and charges promotion of the last nursery survivors.

Interpret the memory fields with their different meanings:

| Field | Meaning |
| --- | --- |
| `payload_bytes`, `allocations` | Equal logical workload requests, excluding survivor copies. |
| `allocation_header_bytes` | Cumulative custom header bytes on original allocations: eight per allocation on this 64-bit ABI. Promotion headers are accounted separately in copied/old bytes. |
| `nursery_header_bytes`, `old_header_bytes` | Requested metadata sizes for each generation, also exposed through the header-size API for correctness checks. |
| `nursery_allocations`, `nursery_payload_bytes`, `direct_old_allocations`, `direct_old_payload_bytes` | Original allocation counts and payload bytes split by birth generation. |
| `copied_bytes`, `copied_payload_bytes` | Cumulative promoted old object bytes including full old headers, and payload bytes alone. The latter divided by `nursery_payload_bytes` is the measured nursery survival fraction. These timing profiles all start in the nursery; direct-to-old large objects are excluded from both numerator and denominator. |
| `old_total_allocated_bytes` | Cumulative logical mature object bytes, including promotions and direct mature allocations; excludes pool rounding and system allocator overhead. |
| `old_live_bytes`, `exact_live_bytes` | Exact requested live object bytes including headers as of the final major, before the workload drops its final roots; the nursery is then empty. |
| `peak_old_bytes` | Maximum requested old object bytes at any point, including dead objects pending sweep. |
| `exact_live_payload_bytes` | Reachable payload bytes after the final major, excluding object headers. |
| `old_slot_bytes`, `pool_padding_bytes` | Occupied mature pool slots and their internal size-class padding. Logical objects and slots must not be added to reserved pool bytes again. |
| `pool_reserved_bytes`, `peak_pool_reserved_bytes` | Current and peak requested pool allocations, including pool metadata, empty slots, and size-class padding. Empty pools are returned during major collection. |
| `large_reserved_bytes`, `large_metadata_bytes` | Dedicated large-object allocations and their included list metadata. |
| `descriptor_bytes`, `work_queue_bytes`, `remembered_queue_bytes` | Reserved capacities of shared descriptor/hash tables and tracing vectors, retained until heap destruction. |
| `accounted_bytes`, `peak_accounted_bytes` | Current and peak nursery capacity + reserved pools/large objects + descriptor/vector capacities + collector static state + registered root records. Peak also includes overlapping old/new tables during growth. Excludes malloc internals, root word slots already present in the workload, and non-root C stack. |
| `peak_root_bytes` | Largest registered root-record stack in bytes; included in `peak_accounted_bytes`. |
| `boehm_heap_bytes`, `boehm_free_bytes`, `boehm_heap_minus_free_bytes` | Boehm's managed heap/free/occupied accounting at the end. Occupied bytes are conservative, include free-list retention and block granularity, and are not exact reachable payload bytes or a peak. |
| `boehm_total_allocated_bytes` | Boehm's allocation accounting, including internal rounding and adapter refills. Free-list allocations may be accounted when refilled rather than per logical request. |
| `inline_root_bytes` | Requested bytes for the inline adapter's traced uncollectable free-list head table; already part of Boehm heap accounting. |
| `process_peak_rss_bytes` | OS process high-water resident bytes (Linux and macOS units normalized). Includes code, stack, allocator arenas, collector metadata, and any fork/exec launcher floor; it is not exact object liveness. |

The roughly 19 MB RSS floor in these small-process measurements comes from the
subprocess launcher's high-water accounting; it does not establish that each
collector needs 19 MB. Retained-graph RSS measurements rise well above that floor.

These synthetic graphs have precise descriptors and deliberately explicit roots.
The custom collector has no concurrent allocation, finalizers, weak references,
pinning, FFI roots, thread roots, write-barrier integration into generated Medaka,
exception unwinding, or runtime object-layout coverage. Survival profiles can
change the result substantially. Neither a local gain nor a local loss establishes
a compiler-level performance result.

Historical matched static-Boehm evidence from the first experiment is recorded in
JSONL files containing source hashes, platform/compiler/link provenance,
correctness status, all three samples, and the fastest sample's counters:

- [Full nursery header, 256 KiB, all profiles](results/2026-10-12-beforecompact-5m-256k.jsonl)
- [Compact nursery header, 256 KiB, all profiles](results/2026-10-12-compact-5m-256k.jsonl)
- [Full nursery header, 1 MiB, ephemeral and mutation](results/2026-10-12-beforecompact-5m-1m.jsonl)
- [Compact nursery header, 1 MiB, ephemeral and mutation](results/2026-10-12-compact-5m-1m.jsonl)
- [Final correctness, including the adversarial graph model](results/2026-10-12-final-correctness.jsonl)

The [first-experiment patch](results/2026-10-12-beforecompact-to-compact.patch)
can be reversed to reconstruct the exact baseline `gc.c`, `gc.h`, `workload.c`,
and `run.py`. Its reverse application was checked against every recorded baseline
source hash. For inspection, reconstruct in a scratch directory:

```console
mkdir -p /tmp/medaka-gc-first
git archive 33f900bca3bf577e8c49745080ec16147a0b017b test/gc_prototype | tar -x -C /tmp/medaka-gc-first
cp -R /tmp/medaka-gc-first/test/gc_prototype /tmp/medaka-gc-baseline
patch -R -p3 -d /tmp/medaka-gc-baseline -i /absolute/path/to/medaka/test/gc_prototype/results/2026-10-12-beforecompact-to-compact.patch
```

To rerun a reconstructed version, put that directory at `test/gc_prototype/`
inside a scratch checkout containing the repository's `runtime/` and Git metadata,
then run the recorded settings. The collector and workload at commit
`33f900bca3bf577e8c49745080ec16147a0b017b` match the first compact evidence.
That driver's independent graph test was added after
measurement; it changes correctness coverage only. The exact
[measurement runner](results/2026-10-12-compact-measurement-run.py) is preserved,
and its hash matches the compact evidence's `run.py` hash. Restore it as `run.py`
in the scratch experiment directory to recreate that driver revision.

The pooled-heap comparison uses the same workload source in both custom versions,
including the mixed profile:

- [Previous collector, 256 KiB](results/2026-10-12-pool-baseline-5m-256k.jsonl)
- [Pooled collector, 256 KiB](results/2026-10-12-pool-compact-5m-256k.jsonl)
- [Previous collector, 262,136 bytes](results/2026-10-12-pool-baseline-5m-offset.jsonl)
- [Pooled collector, 262,136 bytes](results/2026-10-12-pool-compact-5m-offset.jsonl)

To reconstruct that previous collector, extract `test/gc_prototype/` and
`runtime/medaka_rt.c` from commit `33f900bca3bf577e8c49745080ec16147a0b017b` into
a scratch checkout. Replace its `workload.c` with the current file and add
`"mixed"` to its runner's `PROFILES` tuple. No other baseline source changes are
needed; the evidence records all resulting hashes. Run both collectors at both
capacities with `--count 5000000`. The eight-byte offset matters: 32-byte cells
fit exactly 8,192 times in 256 KiB, aligning with periodic temporary-root drops.
Read copied-payload fractions alongside timings rather than interpreting that
alignment as a general workload property.

The [allocation-path profile](results/2026-10-12-pool-profile.json) records
500-million-allocation CPU samples for the previous and pooled collectors.
It also records the independent audit of source hashes, complete sample rows,
checksums, and correctness markers in all four timing artifacts. These CPU
shares identify hot paths; they are not absolute function-time measurements.
