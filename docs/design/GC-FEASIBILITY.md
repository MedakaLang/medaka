# Native GC feasibility experiment

**Status:** EXPERIMENTAL — isolated collector and LLVM contract tests; no
production integration.

This experiment evaluates a copying nursery for native Medaka. It does not
replace the production collector or change the language's memory semantics.
The starting revision is `6aae2ea97e49656995a23eadaed333f676ee61ca`, which
includes the Boehm inline allocation path from PR #4048.

The user authorized reopening the investigation on 2026-10-12. The production
decision in [RUNTIME-DESIGN.md](../../compiler/RUNTIME-DESIGN.md), section 9,
continues to apply while experiments produce evidence. Issue #503 owns the
Boehm measurements; this experiment additionally explores collector mechanics.

## Questions the experiment can answer

1. How much time does the current compiler spend allocating and collecting,
   after the recent allocation reductions and inline allocator change?
2. On controlled object-lifetime workloads, can a bump nursery plus promotion
   outperform the current small-object Boehm allocation path after paying for
   explicit roots, metadata, copying, mutation barriers, and old-generation GC?
3. What compiler and runtime contracts would a production integration need?

A synthetic speedup is not a compiler speedup. Cumulative allocated bytes are
not peak RSS. Boehm's aggregate reclaimed fraction is not the survival rate of
objects in a nursery. The experiment keeps these measurements distinct.

## Prototype boundary

The standalone C prototype lives under `test/gc_prototype/`. It is an on-demand
experiment, not a production runtime or CI acceptance gate. Its explicit-root
mutator uses tagged values and precise object descriptors. Nursery survivors
move to a nonmoving old generation; old objects are eventually reclaimed by
mark/sweep. The remembered set covers old-to-young pointer stores.

This demonstrates an explicit-root mutator contract; it does not discover roots
in existing emitted LLVM or C stack/register state. Pointer-free numeric
payloads and raw buffers must not be rewritten based on pointer-looking bits.

This deliberately includes the costs that an allocation-only microbenchmark
would omit. Collector metadata and nursery capacity must be reported; system
allocator bookkeeping is not observable from the prototype's byte counters.
Benchmark results must identify ordinary versus inline Boehm allocation.

## Integration audit

The allocation entry point is narrow, but the present root contract is not.
Replacing `mdk_alloc` alone with an evacuating allocator would invalidate live
references in emitted code and C helpers.

| Surface | Current behavior | Required contract |
|---|---|---|
| LLVM values | Heap references travel as ordinary `i64` SSA values. | Register live tagged root slots and reload relocated values, or lower explicit GC pointer SSA through LLVM statepoints. |
| Expression temporaries | Earlier arguments can remain live while later arguments allocate. | Track intermediate operands as well as lexical bindings. |
| Type information | Some field loads and indirect results are classified as `LTInt` even when they carry boxed values. | Root classification cannot assume this lowering type means pointer-free. |
| Object headers | Constructors, arrays, closures, boxed numbers, and scratch buffers have different layouts; headers do not provide a universal scan map. | Supply allocation size and trace descriptors or equivalent side metadata. |
| C helpers | Lists, arrays, strings, and partial applications keep local pointers across allocating calls. | Root mutable base slots and reload them; derive interior pointers again after movement. |
| Tail recursion modulo constructors | The emitter retains an interior destination pointer across allocation. | Preserve a rooted base plus offset, or use storage that cannot move. |
| Mutation | Ref writes, array writes/blits/fills, and construction across callbacks may install pointers into old objects. | Cover every old-to-young store, including generated stores and C helper stores. |
| Global and TLS state | UTF-8 cursors, scoped file grants, and the stdout stash rely on conservative discovery. | Register roots or pin objects; maintain the signal-readable stdout pointer consistently. |
| FFI | Strings are borrowed as interior pointers; array buffers are copied out and copied back. | Stable addresses throughout the foreign call, through pinning or a no-move protocol. |
| Threads | The program runs on a Boehm-registered worker thread. | Explicit mutator registration and stop/safepoint protocol. The prototype has one mutator. |
| Optimizer | LLVM allocator attributes permit allocation deletion and store forwarding. | Revalidate allocation attributes and rooting effects under movement, including tail calls. |

Audit sources: `compiler/backend/llvm_emit.mdk` (`emitArgs`, `emitFieldAccess`,
array construction, TRMC), `compiler/backend/llvm_preamble.mdk`,
`runtime/medaka_rt.c`, and [FFI-ABI.md](../../compiler/FFI-ABI.md).

A Boehm-old/custom-young hybrid is not automatically safe: each collector must
see references into its heap from the other heap. Conservative pinning is an
alternative research path, but it needs interior-pointer containment lookup and
reclaimable storage around pinned objects. Conservative candidates must never
be rewritten as if they were known pointers.

## Decision criteria

### Implementation language and representation

The collector will be implemented in C, with allocation fast paths and root
handling generated by the Medaka compiler. This choice was accepted on
2026-10-12. It follows the existing native build, cache, bootstrap, and release
paths, which compile or distribute `runtime/medaka_rt.c`. It is an integration
decision; no C-versus-Rust performance comparison has been made.

Rust could safely own descriptor tables, tracing queues, and much of the heap
bookkeeping. A Rust static library could expose the same collector ABI. Its
safety benefits are real, but it would add a toolchain and library build/cache/
packaging integration while leaving generated-code rooting, relocation, and
barrier correctness as explicit compiler/runtime obligations. C therefore
requires continued sanitizer testing and independent reachability models.

Object representation and emitter conventions may change to support collection.
The first integration priorities do not require surface-language changes:

- Track tagged GC values separately from arithmetic lowering types: `LTInt`
  currently also describes some boxed field loads. Preserve earlier arguments
  across later allocating expressions with initialized root slots and reloads.
- Supply layout descriptors shared by the native emitter and C runtime for
  constructors, closures, arrays, and atomic payloads. Closure code addresses
  must not be traced as captured values.
- Preserve a rooted base plus an offset for TRMC interior destinations, and
  reload array-builder bases after allocating callbacks. Cover generated and C-helper
  mutation with barriers, including initialization of objects born in old space.
- Give foreign buffers stable lifetimes through explicit copies, pinning, or a
  no-move protocol. Additional FFI retention/lifetime annotations would be a
  language change; ordinary copies can preserve current behavior.

The active [binder-runtime-type sprint #4047](https://github.com/MedakaLang/medaka/issues/4047)
owns F5 of the [emitter target architecture](../../compiler/EMITTER-TARGET-ARCHITECTURE.md).
GC integration must consume its validated Core facts, including lowering-minted
binders, rather than introduce another scalar inference table. The adopted
architecture grows Core and its validator; the older V/ANF/AP pipeline in that
document is superseded. Shared runtime types remain backend-neutral. Native
GC layouts, raw-versus-tagged storage, safepoints, and root liveness are physical
decisions derived from those facts, not synonymous with them. F5 alone supplies
neither complete object scan maps nor every live expression temporary.

After the relevant F5 carrier and consumers land, the next emitter experiment
should use an explicit opt-in path for immutable records, direct calls, and
conditionals, with native descriptors and root slots. Conditional results and
outer values surviving allocation extend the existing straight-line fixtures.
Unsupported globals, TRMC, mutation, callbacks, and FFI must still be rejected.
The closed LLVM transformer should not grow into a second general backend.
Standalone collector measurements can proceed while the sprint owns compiler
source changes. The shared plan/linkage work belongs to the Targets arc
(#3661), outside both this experiment and the F5 sprint.

### Evidence required for production integration

Keep the existing allocator as the production baseline. A full integration is
worth proposing only after a repeatable improvement on relevant workloads at a
comparable memory budget, with small-program overhead and pause behavior also
reported. A 20% end-to-end improvement is a proposed project threshold, not a
measured result or a universal requirement.

The older section-9 plateau condition is not satisfied: allocation reductions
remain open in #4028, #4029, and #4040. Those are competing uses of implementation
effort, and they can change both the baseline and the object-lifetime mix.

If the standalone collector is promising, the next integration step should be
a fail-closed subset of generated native programs with explicit root handling
and descriptors. Unsupported mutation, callbacks, FFI, or interior-pointer
forms must be rejected by that experimental path until their contracts exist.
Compiling the compiler itself belongs after this boundary is proven.

### Confirmation target

The active goal is to outperform the strongest matched Boehm baseline, first on
the standalone lifetime workloads and then on real generated PDS/gzip programs.
A retained-tree loss must remain visible rather than disappearing in an aggregate
average. Any faster-but-larger result must identify its memory tradeoff.
The retain/drop/churn case below is an additional required check; it is not part
of the fifteen-point confirmation driver.

After a candidate wins the development matrix, freeze it for a separate serial
confirmation batch: list/tree at 500,000, two million, and eight million objects;
the other five lifetime workloads at two million; and tree/mixed at approximately
64 KiB and 1 MiB nurseries as well as the usual approximately 256 KiB. Five cyclic
rounds compare custom GC with both Boehm allocation adapters under default and
128 MiB initial-heap policies: 375 fresh processes across fifteen points. Choose
the fastest Boehm median independently at each point and retain every arm's
results. These are proposed confirmation runs, not completed measurements.

A useful practical margin is at least 5% per point, with retained-case uncertainty
supporting a ratio below one and no more than 10% additional RSS against the
fastest comparator where RSS exceeds the launcher floor. These are experimental
acceptance targets, not claimed results or substitutes for application evidence.
Report workload time and process wall time separately, since the former excludes
heap initialization and descriptor preparation. A Boehm initial heap is not a
memory cap or the same control as a custom nursery. Atomic-allocation comparisons
must label zeroing differences and include a comparator with the same contract.

Nursery selection is a separate experiment on unchanged commit `85c364304`.
Training compares 256 KiB, 1 MiB, 4 MiB, and 16 MiB, each aligned and minus eight
bytes, across tree, transition, ephemeral, and mutation workloads. Both Boehm
adapters run under both initial-heap policies. Twelve cyclic rounds balance the
eight custom settings and four Boehm arms: 576 processes. Choose one nursery
family across workloads, using its worse alignment and worst custom/Boehm ratio;
prefer the smaller family for scores within 3%. Reject repeatable regressions
over 5% against the existing setting and memory growth over the stated 10% limit
where RSS is above the launcher floor. Preserve every configuration's results.
The unchanged collector couples nursery size to the major threshold, so this
does not isolate minor-collection policy alone.

A selected default needs held-out counts and lifetime windows before a general
claim. Forced smaller nurseries remain visible as sensitivity results; selecting
a different nursery for each workload cannot establish a useful global default.
Neither this protocol nor the confirmation driver is evidence of a win.

Real-application confirmation must use the improved packed gzip implementation
in both arms. PDS needs exact content oracles beyond the existing CAR-size and
MST-entry-count checks, plus forced-relocation and omitted-root/reload/barrier
controls. Compiler-produced physical contracts precede moving execution; a
handwritten fixture contract alone cannot establish application rooting costs.

## First prototype results (2026-10-12)

The tested collector implements evacuation, forwarding, explicit roots, a
remembered set, and old-generation mark/sweep. A second version reduced young
headers from 56 to 24 bytes, while retaining 56-byte old headers. A 24-byte
payload therefore occupies 48 bytes when young and 80 bytes after promotion,
before system allocator overhead. The nursery is poisoned after evacuation to
expose stale references; that debugging cost is included in the timings.

The matched comparison uses five million allocations, a 256 KiB nursery, three
fresh sequential processes per backend/profile, and the minimum elapsed time.
Boehm is statically linked, uses divisor 1 and its default initial heap policy,
and includes the production inline allocator with matching thread configuration.
The workload construction, checksum traversal, and final full collection are
timed; process/heap initialization and destruction are excluded.

| Profile | Initial custom (ms) | Compact custom (ms) | Tuned Boehm in compact run (ms) |
|---|---:|---:|---:|
| Ephemeral lists | 51.56 | 48.72 | 53.78 |
| Replaced old-to-young child | 52.33 | 48.10 | 53.19 |
| Entire list retained | 356.40 | 349.92 | 195.21 |
| Entire tree retained | 568.41 | 530.69 | 283.49 |
| Pointer-free cells | 45.72 | 47.50 | 49.72 |

The compact version is about 9–10% faster than tuned Boehm on these short-lived
pointer-bearing profiles. Retained lists and trees are 1.79× and 1.87× slower.
Their process peak RSS is about 482 MB versus 175 MB for tuned Boehm. These are
decimal MB and process high-water values, not exact live payload sizes. The
custom collector's exact requested peak for those graphs is 400.26 MB, including
the nursery; system malloc bookkeeping accounts for additional RSS.

At 1 MiB nursery capacity, the compact ephemeral and mutation profiles take
49.46 ms and 46.99 ms versus tuned Boehm's 55.03 ms and 51.90 ms. Their copied
payload fractions fall from 2.39%/1.75% at 256 KiB to 0.61%/0.44%, but requested
peak storage rises from 1.36/1.34 MB to 3.47/2.81 MB. Larger nurseries do not
establish a free performance gain. The retained profiles promote every object.

All samples, source/archive hashes, compile/link flags and baseline reconstruction
instructions are in [the experiment README](../../test/gc_prototype/README.md)
and its `results/` directory. These small synthetic timings are descriptive on
a shared machine; the data do not establish a statistically robust compiler
speedup or a production-ready memory budget.

Correctness validation includes ASan/UBSan, sharing and cycles, old-to-young
mutation, large direct-to-old objects, pointer-looking atomic payloads, root
dropping, and exact reclamation. Broken root-update and barrier variants fail.
The hand-written LLVM fixture passes at `-O0`, `-O2`, and under sanitizers;
missing root reloads fail, and 10,000 tail transfers keep root frames balanced.
An independent review additionally checked graph reachability against an integer
model at 26 nursery capacities, including descriptor slot 63 and object-size
boundaries. This is Linux validation; the macOS paths have not been exercised.

**Decision after the first prototype:** preserve the working experiment, but do not wire this
collector into the production emitter. The short-lived-object benefit is too
small to justify the present retained-object cost and integration bill. The next
useful experiment is to reduce mature-object metadata/allocation overhead and
establish representative object lifetimes before attempting compiler-wide root
relocation. The results do not rule out a better custom collector.

## Compact pooled heap (2026-10-12)

The next version replaces both headers with one eight-byte descriptor-index/flag
word. A three-word payload occupies 32 bytes in either generation. Mature objects
through 2 KiB use size-class pools; sweep reuses free slots and returns empty
pools. Larger objects retain dedicated allocations. Shared descriptor tables,
work/remembered vectors, pool slack, and collector globals are included in the
new reserved-storage accounting. Logical live bytes remain a separate measure.

The comparison reruns the previous collector from commit `33f900bca3bf577e8c49745080ec16147a0b017b`
with the new workload source, at five million allocations and three fresh
processes per profile/backend. The additional mixed profile retains every 64th
node while dropping batches of temporary nodes. It models a lifetime mixture;
it is not a compiler trace.

With 32-byte cells, a 256 KiB nursery fits exactly 8,192 objects, aligning with
the ephemeral profile's 256-node drop interval. Its copied payload fraction is
only 0.00128%. Reducing capacity by eight bytes makes that fraction 1.71162%.
Both capacities were measured; the offset case below avoids that exact alignment.
The previous 48-byte nursery cells have the same capacity in objects at both
settings and copy 2.38892% of ephemeral payloads.

| Profile, 262,136-byte nursery | Previous custom (ms) | Pooled custom (ms) | Tuned Boehm, pooled run (ms) |
|---|---:|---:|---:|
| Ephemeral lists | 47.25 | 59.67 | 51.97 |
| Entire list retained | 347.19 | 209.11 | 183.93 |
| Entire tree retained | 525.07 | 364.95 | 266.98 |
| Replaced old-to-young child | 46.42 | 56.06 | 52.08 |
| Pointer-free cells | 42.22 | 58.53 | 45.68 |
| Mixed temporary nodes and retained spine | 49.78 | 56.53 | 78.89 |

Retained-graph process peak RSS falls from about 482 MB to 163 MB, versus about
175 MB for tuned Boehm. The pooled graph has 160 MB of logical live objects,
160.47 MB of reserved pool storage, and a 160.74 MB accounted peak including the
nursery and side metadata. These are decimal MB. The change resolves the large
memory penalty and substantially reduces retained-graph time, but retained
lists/trees remain about 14%/37% slower than tuned Boehm in the offset run.
Mixed is about 28% faster; short-lived and pointer-free cases regress. Compact
storage alone has not established a generally faster allocation path.

Correctness now includes the integer graph model at 35 nursery capacities and
an independently authored pool fixture at 21 capacities. The latter checks
descriptor growth, partial-pool reuse with changed descriptors, empty-pool
release, remembered-vector growth, sharing/cycles, large-object boundaries,
atomic data, and heap reinitialization. Sanitizers, root/barrier mutation
controls, and the optimized LLVM contract still pass. The recorded source
hashes and complete samples are linked from the experiment README.

**Direction after the pooled-heap experiment:** keep the pooled representation as an experimental
foundation and investigate allocation-path overhead alongside the generated-root
contract. Descriptor/vector capacity stays reserved until destruction; major
sweep visits reserved pool slots; the mature heap remains nonmoving. This is
still a single-mutator experiment, with no production collector switch.

A separate 199 Hz DWARF profile at 500 million allocations captured 1,379/1,217
samples for pooled ephemeral/atomic and 1,045/897 for the previous collector,
with no lost samples. The pooled allocation function accounts for about
59%/53% of sampled CPU cycles. Inlined descriptor-key hashing is a subset of
that share, about 7%/5% overall. This points to allocation-path work beyond
hashing alone; sample percentages do not establish absolute function costs.
The [profile summary](../../test/gc_prototype/results/2026-10-12-pool-profile.json)
records commands, counts, and the independent measurement-artifact audit.

## Generated-code rooting experiment

The on-demand `test/gc_prototype/generated_contract/` experiment now uses
`compiler/entries/llvm_emit_typed_main.mdk` with the runtime extern catalog and
no core prelude. This entry runs elaboration, Core lowering, and the real LLVM
emitter. Three straight-line source fixtures exercise an earlier argument
across a later allocating argument, a boxed field load across allocation,
and nested record construction. Expected answers are 21, 137, and 89, derived
from the source semantics.

A closed LLVM transformation validates the complete input before returning
rooted IR. Its trusted inputs include independently authored record layouts
and function argument/result types for these fixtures. It verifies constructor
tags, sizes, field types/offsets, and call/return types against those contracts.
This is a test of known fixtures, not a type or pointer classifier for arbitrary
emitted LLVM. It accepts immutable records, projections, tagged scalar constants,
local bindings, and direct calls between accepted functions. It rejects control
flow, recursion, globals, indirect calls, mutation, atomic objects, callbacks,
FFI, and allocating runtime helpers. A minimal startup/printing adapter replaces
the production runtime. Constructors must initialize without intervening calls,
all objects must fit the nursery, and raw heap pointers may not survive calls.

Approved tagged semantic values receive initialized root slots and are reloaded
at every use, including constructor fields and final call arguments. Neither all
`i64` values nor the emitter's `LTInt` classification is used as a root set.
Slots stay registered until function return: this overstates lifetimes and
cannot support performance claims. Collection schedules target the relevant
allocations and require actual promotion and balanced roots.

All 18 successful builds pass: each fixture at `-O0` and `-O2` under two collection
schedules, with sanitizers, and against the ordinary Boehm adapter. The Boehm
arm uses the same transformed IR, not the production C runtime. Omitting the
earlier-argument reload returns 43 instead of 21; omitting the boxed-field root
returns 99 instead of 137. Both controls require those exact wrong answers with
normal exit and valid collector counters. Nineteen source/IR rejection checks
include independently authored adversarial cases. The
[provenance record](../../test/gc_prototype/results/2026-10-12-generated-contract.json)
pins source, transformer, semantic contracts, emitter, runtime catalog, shim,
compiler commands, outputs, and emitted/transformed IR hashes.

This transformation stops at the small straight-line grammar. Loops, phi values,
last-use clearing, tail calls, and runtime integration require emitter-owned GC
metadata and an explicit experimental mode. The hand-written LLVM fixtures test
tail-transfer mechanics separately; no production backend has changed.

## Prepared layouts and caller allocation (2026-10-12)

The next experiment prepares stable layout handles once and exposes nursery
allocation and known-layout stores to the caller. The fast path retains the
old-generation collection threshold, complete initialization, accounting, and
barriers. The allocation slow path still moves objects; field values must be
reloaded from roots afterward. Assertions and nursery poisoning remain enabled.

The comparison now includes a stronger Boehm arm with allocation and checked
stores actually inlined into the caller. The historical production adapter
still crosses out-of-line wrappers. Independent assembly inspection confirmed
both new hit paths are embedded in the workload; Boehm still calls
`GC_end_stubborn_change`. Six custom API variants separate preparation,
known-layout stores, and allocation/store inlining. Preparation alone is not a
reliable win: for offset ephemeral lists, dynamic allocation takes 62.46 ms,
prepared allocation with generic stores 69.82 ms, prepared out-of-line
allocation/stores 135.63 ms, and both caller-inline 24.10 ms. These variants also
differ in descriptor validation and argument passing; this is not an isolated
measurement of descriptor hashing.

Five million allocations per workload were measured in ten fresh processes per
variant, with cyclic ordering covering each execution position once. All samples
and counters are retained. The table reports minima at the 262,136-byte nursery,
and selects the fastest of all four Boehm variants independently per workload.
Every variant prepares the workload layouts before timing, including the dynamic
baseline; preparation cost and metadata are reported separately.

| Workload | Dynamic custom (ms) | Caller-inline custom (ms) | Fastest Boehm (ms) | Custom versus Boehm |
|---|---:|---:|---:|---:|
| Ephemeral lists | 62.46 | 24.10 | 34.27 | 30% faster |
| Entire list retained | 220.56 | 182.15 | 167.20 | 9% slower |
| Entire tree retained | 382.39 | 331.00 | 243.18 | 36% slower |
| Replaced old-to-young child | 62.39 | 22.77 | 32.06 | 29% faster |
| Pointer-free cells | 62.96 | 16.38 | 26.89 | 39% faster |
| Mixed temporary nodes and retained spine | 60.54 | 20.19 | 62.10 | 67% faster |
| Varied sizes and lifetimes | 144.30 | 109.19 | 584.22 | 81% faster |

The fastest Boehm variant is caller-inline for the first six workloads and the
historical production adapter for varied sizes. The latter avoids the prepared
API's full atomic zeroing guarantee; both variants produce the same required
workload results. The varied-size profile cycles through eight layouts from two
to 127 words, including atomic objects and pointer slot 63. Its retention period
of 61 visits every shape, while temporary roots drop every 64 allocations.

At the aligned 262,144-byte capacity, caller-inline custom ephemeral/mutation/
atomic/mixed/varied-size workloads beat the fastest Boehm variant by about
38%/32%/38%/68%/83%. Retained lists/trees remain 24%/45% slower. These separate
shared-machine runs have different noise; capacity effects cannot explain every
timing difference. Ephemeral copied payload remains 0.00128% at the aligned
capacity and 1.71162% at the offset, so the short-lived benefit survives the
previously identified alignment problem.

Retained list/tree RSS remains about 163 MB versus 175–178 MB for the fastest
Boehm arm. Custom accounted peak is 160.739 MB plus a separately reported
352-byte workload layout manifest. Varied sizes use about 32 MB RSS versus
75 MB; their custom accounted peak is 30.52 MB and final logical live heap is
17.21 MB. Small-profile RSS remains obscured by the roughly 20 MB launcher floor.

Validation includes the existing pool and graph models, 46 sanitized prepared-API
runs, six named root/zero/barrier mutation failures, and the hand-written LLVM
contract. The generated-source harness again passes 18 successful builds, two
exact wrong-answer controls, and 19 rejections. Valgrind 3.24.0 checks both prepared
API modes at 32, 240, and 262,136 bytes: six runs, zero errors, and no leaked heap
blocks. Evidence and exact commands are linked from the experiment README.

**Direction:** caller-visible allocation and initialization now produce a
substantial synthetic benefit without surrendering compact mature storage.
Retained graphs still need work, and no compiler speedup has been established.
Integration should consume the active F5 runtime-type work and the added native
GC requirements in R5a of the emitter target architecture; these results do not
justify replacing production Boehm yet.

## Promotion work and retained graphs (2026-10-12)

DWARF CPU sampling of 30 fresh five-million-object runs per retained workload
identified mature allocation as a useful next target: `new_old` accounted for
17.5% of flat samples on custom lists and 9.1% on trees. Tree root registration
and removal together accounted for 3.7%. These are sampled CPU shares, including
kernel work, not wall-clock attribution. The profile retains benchmark and
marker-thread names within benchmark process IDs, excluding Python before
`exec`; no secondary-thread samples were observed.

Promotion now copies the complete logical payload into its mature slot without
first clearing the same bytes. Pool padding remains cleared, direct-old births
remain fully zeroed, and dedicated large allocations retain `calloc`. Allocation
from a pool updates the logical old-generation peak directly; full storage-peak
accounting still runs when reserved storage changes. Roots, barriers, tracing,
assertions, counters, and nursery poisoning are unchanged.

Six position-balanced rounds compare the previous caller-inline collector,
each change separately, both together, and the caller-inline and historical
production-adapter Boehm arms. The table uses **medians**, unlike the preceding
minimum-of-ten table. Each cell shows offset/aligned nursery capacities
(262,136/262,144 bytes); each process allocates five million objects.

| Workload | Previous custom (ms) | Combined custom (ms) | Fastest of two Boehm arms (ms) |
|---|---:|---:|---:|
| Ephemeral lists | 24.91 / 29.32 | 24.88 / 30.88 | 37.10 / 39.43 |
| Entire list retained | 212.50 / 238.76 | 182.43 / 208.60 | 213.33 / 204.63 |
| Entire tree retained | 362.05 / 389.92 | 332.18 / 363.45 | 299.19 / 295.15 |
| Replaced old-to-young child | 26.32 / 23.95 | 25.43 / 23.70 | 45.70 / 38.37 |
| Pointer-free cells | 18.17 / 18.35 | 18.64 / 17.57 | 30.85 / 29.65 |
| Mixed temporary nodes and retained spine | 25.28 / 21.26 | 22.96 / 20.72 | 71.06 / 68.34 |
| Varied sizes and lifetimes | 134.00 / 137.71 | 113.81 / 115.74 | 762.03 / 749.45 |

Lists improve 13–14%, trees 7–8%, and varied sizes 15–16% against the same-run
custom baseline. Lists beat Boehm at the offset capacity and remain about 2%
slower when aligned; trees remain 11–23% slower. The individual changes do not
have additive timing effects, and the combination is not fastest in every
cell. Small changes in short-lived cases are inconsistent, including a 5%
aligned ephemeral regression; shared-machine variation prevents a general
speedup claim for those cases. Caller-inline Boehm wins its comparison except
for aligned varied sizes, where the historical adapter wins.

All 252 custom variant comparisons across both capacities have identical
deterministic counters, including copied payload, collections, logical live
storage, and peak accounted storage. The full correctness/sanitizer matrix and
six independent Valgrind runs pass. Reproduction patches, complete samples,
profile provenance, and validation records are linked from the
[experiment README](../../test/gc_prototype/README.md).

This is a bounded improvement to the standalone collector. Real Medaka workloads
and the production compiler still require emitter integration before any custom
GC performance comparison is possible.

### Application workloads for native integration

The existing PDS and gzip projects provide application-level candidates beyond
compiler checking. These are identified targets, not custom-GC measurements:

| Candidate | Existing entry and workload | Independent correctness check |
|---|---|---|
| PDS CAR encoding | `pds/test/performance_resource_main.mdk`, `car 1000` and `car 2000` | Output `CAR 1000 40059` / `CAR 2000 80059`: a 59-byte framed header plus 40 bytes per section |
| PDS persistent MST insertion | Same entry, `mst-insert 1000` / `mst-insert 2000` | Reported entry count equals the requested count; `allocBytes` is a measurement, not a fixed answer |
| gzip compression | `gzip/deflate_demo.mdk`, repeated-text and deterministic incompressible corpora from its oracle tests | System `gunzip` reconstructs every input byte |
| gzip decompression | `gzip/inflate_demo.mdk`, committed `compiler/seed/emitter.ll.gz` | Byte-for-byte agreement with system `gunzip` |

A focused Medaka entry around the existing CAR algorithm, starting with 16
blocks, is an application integration target. The full resource
driver also imports signing and handler machinery; a smaller entry can run the
actual CAR library without unrelated startup. Even that target needs rooted
control flow and recursion, ADT/list layouts, closures and dictionaries, packed
`ByteBlock` storage, and allocation contracts for runtime helpers. Its byte
builder keeps a backing block in a mutable `Ref`, requiring barriers and valid
buffer bases across growth. gzip adds mutable numeric arrays, bit cursors, and
vector growth. These requirements should extend the native R5a implementation
plan while consuming F5's settled semantic facts.

Inspection of the application dependencies identifies a smaller first execution
target: `pds/lib/multiformats.mdk:uvarintEncode`, the real PDS framing algorithm.
Its independent unsigned-LEB128 answers include `0 → 00`, `127 → 7f`,
`128 → 8001`, `300 → ac02`, and `16384 → 808001`. It already reaches recursive
lists, byte builders, mutable backing-block references, packed bytes, and buffer
growth. A focused CAR entry still has 27 statically imported modules, versus 15
for this varint entry; these counts do not describe emitted reachable functions.

At the inspected emitter sprint commit
`2a3ef1283254993aa9f816ab267c7996f62736f1`, the runtime-type domain, binder identities,
`DeclFacts.factBinders` snapshot, and binder-stamp validator exist. The LLVM
consumer has not yet switched to those facts. The first compiler integration
slice should consume that carrier and export native allocation layouts, operand
storage classes, and collection-call contracts from their producing operations,
with Boehm still collecting. This removes the closed transformer's handwritten
application layout authority before enabling movement. Missing facts or helper
contracts must reject the experimental path.

Moving execution then needs temporary roots and reloads, balanced tail transfers,
the backing-Ref barrier, and a ByteBlock-copy contract that roots its source
across allocation. Experimental TRMC must either use rooted base-plus-offset
destinations or be disabled in that mode. Constants and globals need explicit
ownership contracts. After the varint/builder path passes forced relocation and
mutation controls, expand to CAR and then the broader gzip runtime surface.

### Measured application baselines (2026-10-12)

The real PDS and gzip native executables now have a reproducible production-Boehm
baseline. Independent checks pass for CAR sizes, MST entry counts, compression
round trips through system gzip, and decompression of the committed compiler seed.
MST's check covers entry count, not a full independent tree-content model. The
CAR and MST probes will need content-level oracles before comparing execution
under a moving collector; unchanged lengths alone cannot establish correct data.
The driver records 120 fresh-process measurements and 24 separate GC diagnostic runs,
with source, compiler, binary, and input hashes. Each case has five timing samples
per heap policy, alternating cohort order. Builds and output verification are
outside timing; startup and file I/O are included.

| Application workload | Default initial heap, median (ms) | 128 MiB initial heap, median (ms) |
|---|---:|---:|
| CAR, 1,000 blocks | 16.29 | 14.18 |
| CAR, 2,000 blocks | 28.35 | 23.27 |
| MST insertion, 1,000 entries | 149.71 | 97.47 |
| MST insertion, 2,000 entries | 353.28 | 294.88 |
| Deflate, 101,700 repeated-text bytes | 7.44 | 5.68 |
| Deflate, 200,000 deterministic incompressible bytes | 31.99 | 27.05 |
| Inflate, 200,000 incompressible bytes from system gzip | 25.25 | 23.38 |
| Inflate compiler seed, 26,301,788 output bytes | 2,115.74 | 2,156.46 |

The default application link starts without the compiler's pre-expansion policy;
both cohorts use free-space divisor 1. The 128 MiB setting fixes the initial size,
not the maximum heap. It reduces MST collection frequency at a memory cost:
the 2,000-entry diagnostic runs log 236 versus five collections, while the timed
128 MiB runs have about 149 MB median peak RSS. The insertion-only allocation
counter reports about 187.7 MB at 1,000 entries and 608.6 MB at 2,000; it is not
the whole-process allocation total.

Seed decompression has roughly 1.29 GB median peak RSS under either policy. The
separate diagnostic runs log 3.654/3.683 GB allocated at collection boundaries,
25/18 collections, and 120/113 ms of collection duration. These counters omit the
final allocation tail and do not measure exact liveness; diagnostic collection
durations must not be treated as a wall-time decomposition of the separate timed
runs. The larger initial heap gives no useful improvement in this sample. The
allocation and representation costs warrant investigation before attributing
that memory footprint to collector policy.

Short cases include process-startup overhead, and their RSS is often obscured by
the roughly 24 MB inherited launcher high-water floor. Full samples, minima,
medians, ranges, independent audits, and reusable commands are in the
[experiment README](../../test/gc_prototype/README.md). None of these applications
has yet run under the custom collector.

Source inspection gives a concrete representation hypothesis for the gzip
footprint. `gzip/lib/inflate.mdk` retains all output in a `Vector Int`, using it
as the back-reference window. At this output size its doubling capacity reaches
33,554,432 word slots (about 268 MB). Finishing makes a roughly 210 MB exact-size
word array and a packed 26 MB byte block; the CLI converts the result back to a
word array for `writeFileBytes`. Those copies and historical vector backing
arrays explain substantial allocation. They do not establish which allocations
are simultaneously live or conservatively retained. A packed output/window and
packed file-I/O path are separate application/runtime optimization candidates;
their benefit must be measured independently of changing collectors.

### Tracing-queue allocation experiment (2026-10-12)

A fresh profile of the promotion-optimized collector attributes 8.1% of retained
tree CPU samples and 9.6% of list samples to `queue_push`. Assembly shows that the
old shared function saves six registers and reserves stack space even when no
growth occurs. The queue now inlines its capacity check and append, with the
unchanged growth sequence in a separate out-of-line function. It preserves
traversal order, allocation sizes, overlap accounting during growth, assertions,
and all counters.

Eight cyclic rounds compare the previous collector, the queue variant, and both
Boehm alternatives at five million allocations. Each arm occupies each position
twice. Medians below show offset/aligned nursery capacities:

| Workload | Previous custom (ms) | Queue variant (ms) | Fastest of two Boehm arms (ms) |
|---|---:|---:|---:|
| Entire list retained | 175.77 / 200.33 | 170.12 / 187.89 | 179.34 / 193.52 |
| Entire tree retained | 322.94 / 358.39 | 319.75 / 354.22 | 305.86 / 269.97 |
| Varied sizes and lifetimes | 120.10 / 128.05 | 119.67 / 118.67 | 750.59 / 736.24 |

Lists improve 3–6% against the same-run baseline and beat the measured Boehm
alternatives by 3–5%. Trees improve only about 1%, which is inconclusive on this
shared machine, and remain 5–31% slower than Boehm. The different Boehm tree
times across runs underline the need to retain both capacities and all samples.
Other effects are mixed: offset ephemeral and aligned mutation regress about
1% and 2%; a 7% aligned varied-size gain does not repeat at the offset capacity.
This is a small list improvement, not a general solution to the retained-tree gap.

All 112 paired custom measurements have exactly matching deterministic counters
and memory accounting. The full correctness/sanitizer and mutation matrix passes,
including remembered and tracing queue growth beyond their initial 64 slots.

### Retained-tree phase attribution and marking (2026-10-12)

Three additional clock reads divide the tree workload into construction (including
root setup and collections triggered during allocation), checksum traversal, and
the final major collection plus root cleanup. There is no per-allocation timing.
Eight balanced rounds compare commit `06e4bc273`, forced-inline marking, and both
Boehm adapters at five million nodes and two nursery capacities: 128 samples.

| Median milliseconds, nursery capacity | 262,136 bytes | 262,144 bytes |
|---|---:|---:|
| Custom tree total, before → after | 323.96 → 317.50 | 340.13 → 326.84 |
| Custom final major plus cleanup, before → after | 38.98 → 29.91 | 37.24 → 29.78 |
| Custom construction, after | 206.07 | 213.90 |
| Boehm caller-inline construction | 136.97 | 113.23 |
| Custom checksum traversal, after | 73.59 | 74.85 |
| Boehm caller-inline checksum traversal | 104.16 | 100.04 |
| Fastest Boehm tree total (caller-inline in both columns) | 292.69 | 260.51 |
| Custom list total, before → after | 180.14 → 166.54 | 179.56 → 174.46 |
| Fastest Boehm list total | 200.83 | 196.37 |

Each row is a separately computed median; phase medians need not sum to the
median total. Marking now inlines its common path while retaining the existing
queue growth slow path, assertions, traversal order, and counters. Assembly
confirms the two calls to `mark` disappear. Final collection improves 20–23%,
while total tree medians improve only 2–4% with overlapping ranges. Lists improve
3–8% in this sample. All 32 paired custom counter comparisons match exactly.

Trees remain 8–25% slower than the fastest measured Boehm arm. Their remaining
cost is concentrated in construction, which includes promotion and intervening
collections; these measurements do not separate those costs from root handling
or allocation. Final collection and subsequent traversal are already faster in
this workload. This directs the next investigation toward the allocation and
promotion paths rather than treating the entire gap as final marking time.

The [raw samples](../../test/gc_prototype/results/2026-10-12-mark-inline-results.jsonl),
[reconstruction and timing audit](../../test/gc_prototype/results/2026-10-12-mark-inline-audit.json),
and [correctness record](../../test/gc_prototype/results/2026-10-12-mark-inline-correctness.json)
retain phase boundaries, provenance, and the corrected fastest-Boehm reduction.

### Rejected descriptor cache (2026-10-12)

Caching object bytes and mature size class in each descriptor removes the class
selection chain from promotion, but does not improve the measured workload.
Eight cyclic rounds compare commit `85c364304`, the cache, and both Boehm adapters
across seven profiles and two nursery capacities at five million allocations:
448 samples. Tree medians regress from 286.65 to 292.13 ms at 262,136 bytes and
from 301.25 to 305.03 ms at 262,144 bytes. Most other profile medians also regress
slightly. The cache is excluded from the collector.

All 112 paired custom rows retain identical deterministic counters except the
four descriptor/current/peak accounting fields, each correctly increasing by
256 bytes. Assembly confirms the intended class-selection work disappears;
removing instructions is insufficient evidence of an improvement. The
[samples](../../test/gc_prototype/results/2026-10-12-descriptor-cache-results.jsonl)
and [audit](../../test/gc_prototype/results/2026-10-12-descriptor-cache-audit.json)
preserve the rejected patch and reconstruction evidence.

Separate baseline event instrumentation finds six construction-time major
collections with the 262,136-byte nursery and seven with 262,144 bytes, plus the
final collection in both cases. The extra collection traces a large retained
graph; this makes collection policy a candidate for investigation. Diagnostic
durations and sampled profiles are not uninstrumented benchmark results. Any
policy change must also measure a retain-then-drop workload, since postponing
collection can retain dead memory longer.

### Rejected promotion inlining (2026-10-12)

The uncached baseline next competes against full promotion inlining and a split
with inline null/mature/forwarded checks plus an out-of-line evacuation helper.
Assembly confirms the intended changes. Across 560 samples (seven profiles, two
capacities, five arms, eight cyclic rounds), full inlining improves tree medians
by only 0.7–0.8%, while the split regresses them by about 1%. Other results are
mixed, including a size-profile gain at one capacity and loss at the other.
Neither variant is selected. All deterministic custom counters match exactly;
both variants pass 89 sanitizer cases and fourteen phase smoke comparisons.

The [raw samples](../../test/gc_prototype/results/2026-10-12-promote-inline-results.jsonl)
and [audit](../../test/gc_prototype/results/2026-10-12-promote-inline-audit.json)
retain both patches, assembly findings, correctness records, complete timing
ranges, and the independently selected fastest Boehm arm for each point.

### Rejected larger major-collection threshold (2026-10-12)

A candidate raises the post-collection threshold from `2*live + 4*nursery` to
`4*live + 4*nursery` when at most one eighth of the pre-sweep population is
reclaimed. It recomputes this choice after each major and returns to factor two
after substantial reclamation. Four reset checks (including sanitizers), three
deliberately broken policies, and 120 compiled arithmetic boundary cases pass.

The lifetime-transition workload retains one million list nodes, drops them,
then creates eight million more in windows of 65,536 nodes, keeping a separate
15,625-node anchor. Exact contents and final custom liveness are checked. Three
cyclic rounds across four arms and two nursery capacities give 24 samples;
three rounds do not fully balance four execution positions.

| Median, 262,136 / 262,144-byte nursery | Existing custom | Larger threshold | Fastest Boehm |
|---|---:|---:|---:|
| Whole workload, ms | 201.04 / 174.34 | 219.44 / 206.28 | 91.59 / 92.26 |
| Process peak RSS, decimal MB | 42.35 / 34.23 | 113.33 / 91.32 | 38.95 / 38.92 |

The larger threshold performs fewer collections but takes 9–18% longer than the
existing collector and uses 2.4–2.9 times the fastest Boehm arm's peak RSS. It is
rejected without widening the timing matrix. This workload also exposes a
remaining deficit in the existing collector: almost every temporary node is
promoted, and thousands of empty mature pools are released and allocated again.
Those counters motivate profiling; they do not identify the dominant CPU cost.
Whole-workload time includes validation omitted from individual phase timers,
so summing phase medians is not an equivalent metric. RSS snapshots are
cumulative process high-water marks, not independent phase peaks.

The [samples](../../test/gc_prototype/results/2026-10-12-headroom-rejected-results.jsonl)
and [audit](../../test/gc_prototype/results/2026-10-12-headroom-rejected-audit.json)
retain the policy, transition fixture, controls, and reconstruction inputs.

### Why the transition favors caller-inline Boehm (2026-10-12)

Fifty DWARF profiles per arm compare the existing custom collector and both
Boehm adapters on the offset transition case. All 150 recordings have zero lost
samples. Only the main workload thread appears in the samples; there is no
sampled parallel-marking contribution explaining the advantage.

About 54% of custom workload samples include minor collection and 45% include
promotion. These are overlapping call-stack groups, not additive costs. During
churn, 98.565% of allocated payload is promoted before its temporary root is
dropped. Each 65,536-node window occupies 2 MiB, versus a roughly 256 KiB nursery.
The nonmoving Boehm collector avoids those evacuation copies, and assembly
confirms its caller-inline path pops a TLS size-class free list directly, calling
refill only on a miss. Caller-inline Boehm takes 91.59 ms versus custom's
201.04 ms in the ordinary offset measurements; historical out-of-line Boehm takes
220.29 ms. The advantage belongs to the stronger caller-inline comparator.

Pool creation and free-list initialization appear in the custom profile, but
their inlined attribution overlaps `new_old`; event counts alone do not justify
making pool caching the first fix. The next configuration control changes nursery
size while retaining the same collector source. Since nursery size also sets the
major threshold's `4*nursery` reserve, that control measures a coupled policy
change. Copy volume, delayed reclamation, and memory must accompany its timing.

The [profile audit](../../test/gc_prototype/results/2026-10-12-transition-profile.json)
preserves commands, reductions, source attribution, and the distinction between
instrumented profiles and ordinary timings.

### Nursery and major-reserve sweep (2026-10-12)

The frozen sweep completed 576 fresh-process measurements: four workloads,
eight custom settings, four Boehm arms, and twelve position-balanced rounds.
All 384 custom rows pass conservation checks. Changing nursery capacity also
changes the major threshold's `4*nursery` reserve, so these measure coupled
policies. The table uses each family's worse alignment and the fastest Boehm
median for each workload; ratios below one favor custom GC.

| Nursery family | Retained tree | Lifetime transition | Ephemeral | Mutation | Memory eligible |
|---|---:|---:|---:|---:|---|
| 256 KiB | 1.161 | 1.870 | 0.684 | 0.704 | Yes |
| 1 MiB | 1.159 | 1.499 | 0.694 | 0.709 | No |
| 4 MiB | 1.152 | 1.029 | 0.706 | 0.740 | No |
| 16 MiB | 1.283 | 0.837 | 0.828 | 0.893 | No |

At 16 MiB, churn promotion falls to about 6.59% and transition time falls to
about 93 ms versus Boehm's 111.63 ms. However, custom peak RSS is about 49.5 MiB
versus 37.14 MiB, exceeding the predeclared 10% memory allowance. Final collection
also grows from roughly 0.4 ms to 12 ms. Retained trees remain slower, and
short-lived workloads lose some of their advantage. No new global default
qualifies for held-out confirmation; that batch was not run.

The prepared sweep protocol and reducer omitted the separately stated 5%
repeatable-regression gate against the existing setting. That criterion was not
evaluated as a repeatability gate; all alternative families already failed the
memory criterion. Short-lived RSS remains indeterminate at the launcher floor:
"memory eligible" means no observed above-floor rejection, not a demonstrated
memory margin on every workload.

The [samples](../../test/gc_prototype/results/2026-10-12-nursery-sweep-results.jsonl)
and [audit](../../test/gc_prototype/results/2026-10-12-nursery-sweep-audit.json)
preserve all alignments, ranges, phase counters, frozen selection rules, source
inputs, and the limitations of reused historical build provenance. These results
motivate separating major collection pressure from survivor volume: a larger
nursery can reduce promotion while delaying reclamation of dead mature objects.

### Allocation-pressure screen (2026-10-12)

A scratch candidate supplements the mature-size trigger with mutator allocation
debt, charged at existing slow paths. Its budget is twice post-collection live
bytes plus four nursery capacities. This tests eventual mature reclamation when
continued young allocation produces few survivors; it does not implement OCaml's
major-allocation debt rule or incremental collection.

All 576 measurements completed: four workloads, four nursery capacities
(256 KiB and 16 MiB, each also tested eight bytes smaller), and six
position-balanced rounds across two custom and four Boehm arms. Independent
recomputation confirmed provenance, accounting, reductions, and three rejection
cells under the frozen rules. The candidate is not selected or installed.

At 16 MiB, transition medians improve from 82.07–82.72 ms to 70.08–70.47 ms, with five of six
paired samples improving more than 5% at both capacities. Three pressure-triggered
majors reduce post-churn pool reservation from 33.75 MB to 3.68–4.73 MB. Final
collection falls from 10.99–11.83 ms to 1.06–1.44 ms, and peak RSS falls from
49.55–49.61 MiB to 36.38–37.42 MiB. Candidate time is 0.748–0.766 of the fastest
Boehm median, with RSS ratios 0.979–1.007.

Keeping the mature graph live at those capacities exposes the cost: an extra
major scan raises churn time by 15.5–19.3%. Whole-run candidate/baseline ratios are 1.034 and 1.087; only
three of six paired ratios exceed 1.05 at either capacity. This does not meet the
frozen repeatable-regression rejection, but it is inconclusive, not proof of no
regression. At 256 KiB, stable-graph churn slows about 60–61%; whole-run medians
rise 4.69–5.95%, again without meeting the frozen five-of-six repeatability rule.

Both small-nursery transition points fail the qualifying-benefit requirement:
median ratios are 0.977 and 0.970, without a qualifying reservation or final-pause
reduction. The aligned 16 MiB retained tree rejects on a repeatable regression:
454.07 ms becomes 492.60 ms, a ratio of 1.0849 with five of six paired ratios
above 1.05. Both custom arms have the same 11 minor and two major collections,
five million promotions, and 160 MB copied; this result does not establish extra
collection work as the cause. No memory rejection occurs. No held-out
confirmation batch was run.

Whole elapsed includes exact-content validation. The frozen packet incorrectly
said transition validation was contained in the named phase timers: several
checks occur between timers. Zero validation/cleanup fields mean unreported
time, not absent work. The audit preserves that packet with an explicit erratum
and the elapsed-minus-phase residuals. The decision metric remains whole elapsed;
phase timings do not partition it.

The [raw samples](../../test/gc_prototype/results/2026-10-12-allocation-pressure-screen-results.jsonl)
and [audit](../../test/gc_prototype/results/2026-10-12-allocation-pressure-screen-audit.json)
preserve the frozen criteria, source reconstruction, phase ranges, correctness
checks, and independent audit.

### Whole-payload initialization candidate (2026-10-12)

A scratch helper initializes a complete payload after zeroed allocation and root
reloads, validating the trusted prepared layout once and remembering an old
target once when needed. It preserves zeroed allocation, ordinary mutation, and
the collection schedule. Both prepared Boehm and custom arms receive the same
helper; historical Boehm remains a fifth comparator.

Seven profiles, two capacities, and ten position-balanced rounds produce 700
samples. Custom tree medians improve 3.7% and 5.3%, mainly in construction, but
remain 2.2% and 12.7% behind the fastest Boehm median. The aligned list median
regresses 4.3%, and unchanged profiles also show substantial timing variation.
Exploratory paired bootstrap intervals include parity for the offset tree gain;
the aligned result favors the candidate. This is a promising constructor API,
not a selected collector change or a general performance win.

All deterministic custom counters match. Five selftests, 105 smoke runs, and
22 independent graded cases pass, including ASan/UBSan, direct-old slot 63,
overlapping initialization, preserved zeroing, remembered-entry deduplication,
and safe failures for omitted barriers and stale pre-allocation inputs. The
[samples](../../test/gc_prototype/results/2026-10-12-whole-init-results.jsonl) and
[audit](../../test/gc_prototype/results/2026-10-12-whole-init-audit.json) preserve
the uninstalled helper, independent fixture, measured sources, and uncertainty.

### Root-pair registration screen (2026-10-12)

A scratch tree constructor batches each pair of adjacent root pushes and pops,
retaining the same two root records, relocation semantics, and peak accounting.
Assembly confirms four root calls become two per node. Five selftests, 105 smoke
runs, and seven graded fixture cases pass; invalid LIFO operations and an omitted
relocation mutant fail their intended checks.

The balanced screen contains 288 samples across four workloads, two capacities,
and six arms, including both Boehm adapters with default and 128 MiB initial heaps.
All 48 paired custom counter groups match exactly. Tree medians change from
285.928 to 269.367 ms at 262,136 bytes, but from 298.883 to 299.928 ms at 262,144
bytes. The candidate remains 13.5% and 14.4% behind the strongest Boehm medians.
Its tree RSS remains about 155 MiB versus roughly 167–168 MiB for those Boehm
arms, with no meaningful change from the existing custom collector.
It fails the predeclared requirement to improve both tree alignments and is not
installed. Per-round variation remains visible in the audit.

The [raw samples](../../test/gc_prototype/results/2026-10-12-root-pair-results.jsonl)
and [audit](../../test/gc_prototype/results/2026-10-12-root-pair-audit.json) preserve
the candidate, controls, and frozen provenance. A summary-key error occurred
after all measurements and final input checks completed; a separate corrected
offline reducer processed the unchanged rows. No timing rerun was performed.

### PDS varint integration workload (2026-10-12)

`pds/test/gc_varint_main.mdk` calls the real `uvarintEncode` implementation.
The opt-in `applications.py --correctness-only --varint-only` path checks 29
exact encodings against a Python unsigned-LEB128 oracle using `divmod(128)`.
Cases span every seven-bit length boundary through `intMaxBound`; nine-byte
outputs exercise builder capacities 1, 2, 4, 8, and 16. Four repetition cases
consume every emitted byte into an order-sensitive checksum. Negative input and
zero/negative repetition counts must fail with the intended diagnostics.

The [correctness artifact](../../test/gc_prototype/results/2026-10-12-varint-correctness.json)
records all 33 positive executions, three negative executions, eleven malformed
output controls, CLI mode guards, and default-driver compatibility checks. This
is a production-Boehm executable with an independent content oracle, ready for
later compiler-contract integration; it does not yet execute with custom GC.
The existing larger application baseline mode retains its inputs and behavior.

### Compiler-produced native inventory (2026-10-12)

The experiment now consumes the emitter sprint's validated F5 binder facts.
`compiler/backend/native_gc_contract.mdk` records native allocation layouts,
physical operand classes, stores, derived addresses, and call contracts at their
actual LLVM producers. The whole-module probe can write a deterministic report
with `MEDAKA_NATIVE_GC_CONTRACT=/absolute/path/report.sexpr`. Split emission and
simultaneous stats output are rejected. Ordinary emission avoids constructing
report events, but the added state and branch overhead has not been benchmarked.

Every report declares `boehm incomplete moving-safe=false`. Raw numeric fields,
lengths, code addresses, and packed bytes are distinguished from tagged words;
unknown helper/re-entry behavior remains explicit. This inventory does not
provide root liveness, relocation reloads, static-object ownership, or complete
runtime-helper coverage, and does not enable custom-GC application execution.

Thirteen native tests include actual-emitter report/default LLVM equality and
unrelated-program isolation. The real PDS varint program produces identical LLVM
with reporting enabled or disabled; 29 exact encodings and four repeated byte
checksums pass independent oracles. All 35 calls to the six ByteBlock helpers
match the report. Self-compilation converges, and 62 typed LLVM fixtures plus
78 module fixtures pass. The [reconstruction evidence](../../test/gc_prototype/results/2026-10-12-native-contract.json)
preserves sources, report, commands, independent oracle, hashes, and the limits
of the saved validation logs.

### Lessons from OCaml's compiler/runtime contract (2026-10-12)

This source review pins OCaml 5.4.0 at commit
`907eec0b75c5bcf0fe6da5f4b9f11c5c22995a16`; it makes no claim about the latest
release or comparative performance. OCaml 5 rewrote the runtime for parallel
domains, so OCaml 4's established sequential-GC reputation is not evidence for
the performance of every OCaml 5 mechanism. Medaka's single-mutator experiment
does not need the parallel coordination described in the
[OCaml 5.4 GC manual](https://ocaml.org/manual/5.4/parallelism.html#s:parallel-gc).

The useful lessons cross the compiler/runtime boundary:

- The [AMD64 emitter](https://github.com/ocaml/ocaml/blob/907eec0b75c5bcf0fe6da5f4b9f11c5c22995a16/asmcomp/amd64/emit.mlp)
  generates a downward bump using a dedicated register, a limit comparison, and
  a cold collection branch. Header and field initialization follow separately.
  The limit also participates in runtime interrupt handling. Our C fast path
  still performs epoch/header checks, zeroing, statistics, and an old-limit test;
  removing any of these requires a replacement contract, not disabled diagnostics.
- [Liveness analysis](https://github.com/ocaml/ocaml/blob/907eec0b75c5bcf0fe6da5f4b9f11c5c22995a16/asmcomp/liveness.ml)
  and [stack scanning](https://github.com/ocaml/ocaml/blob/907eec0b75c5bcf0fe6da5f4b9f11c5c22995a16/runtime/fiber.c)
  connect live tagged values at safepoints to relocatable register/stack slots.
  Raw interior addresses cannot substitute for traced base pointers. Medaka needs
  validated physical root provenance and intermediate-operand liveness in addition
  to the binder-type carrier; a frame per scope is only a first implementation.
- OCaml's [initialization contract](https://ocaml.org/manual/5.4/intfc.html)
  permits uninitialized low-level allocation fields only until the next allocation.
  Its [barriers](https://github.com/ocaml/ocaml/blob/907eec0b75c5bcf0fe6da5f4b9f11c5c22995a16/runtime/memory.c)
  distinguish young initialization, major initialization, and general mutation.
  Major initialization still remembers young children. General mutation also
  preserves major marking, beyond the old-to-young invariant our prototype needs.
- [Minor promotion](https://github.com/ocaml/ocaml/blob/907eec0b75c5bcf0fe6da5f4b9f11c5c22995a16/runtime/minor_gc.c)
  temporarily uses evacuated-object fields for an intrusive pending-work list,
  preserving the first original field in the destination and recovering the
  remaining fields from the source. This avoids a separate queue
  append for each ordinary promoted object, but adds a temporary-layout invariant.
- [Mature pools](https://github.com/ocaml/ocaml/blob/907eec0b75c5bcf0fe6da5f4b9f11c5c22995a16/runtime/shared_heap.c)
  use size-class lookup and support sweeping on demand. [Major collection](https://github.com/ocaml/ocaml/blob/907eec0b75c5bcf0fe6da5f4b9f11c5c22995a16/runtime/major_gc.c)
  includes pacing and prefetch mechanisms. These address different throughput and
  latency costs; they are hypotheses for measurement, not features to copy wholesale.

The pinned runtime also clarifies what allocation pressure means. Its
[major pacing](https://github.com/ocaml/ocaml/blob/907eec0b75c5bcf0fe6da5f4b9f11c5c22995a16/runtime/major_gc.c)
charges promotions and direct major allocations, together with work already
performed; it does not charge every nursery allocation that dies young. Nursery
size is explicitly configured, rather than automatically inferred from survival.
[GC controls](https://github.com/ocaml/ocaml/blob/907eec0b75c5bcf0fe6da5f4b9f11c5c22995a16/runtime/gc_ctrl.c)
also expose ramp-up/ramp-down hints for applications that know they are growing
and then dropping mature graphs. Those hints do not establish automatic phase
detection.

The historical supplementary pressure budget counted all requested mutator bytes,
including dead nursery objects, at existing collection boundaries. This is a
Medaka-specific anti-starvation hypothesis: after a mature graph loses its roots,
continued young allocation should eventually prompt mature reclamation even if
nothing new survives. It was rejected in the allocation-pressure screen above,
and is not installed. It is not a reproduction of OCaml's debt rule. That
experiment kept the existing mature-size threshold and stop-the-world tracing;
concurrent or incremental slices need additional barrier contracts.

Caching object bytes and mature size class in the interned descriptor was tested
and rejected above: removing that repeated work did not improve measured
performance. Whole-payload initialization showed a narrower tree improvement,
but has not earned installation across the workload set.

Compiler integration should then test explicit allocation/initialization windows
and compact live-root frames. Keep the generic zeroed allocation API, reload
inputs after collecting slow paths, initialize every traced field before another
safepoint, and retain barriers on direct-old objects. Boehm must receive the same
initialization affordances in comparisons. These changes belong in the planned
native physical contracts, after the F5 carrier consumer is available.

Intrusive promotion work is now a tested scratch experiment: cycles, aliases,
one-word objects, atomic payloads, complete field restoration, and draining before
mutator resumption need independent checks. Measure threshold-major work and
bounded heap-headroom policies before adding incremental collection. Always
charge the final drain; a larger nursery cannot avoid eventual copying of a fully
retained tree. Incremental major GC would require an additional major-marking
barrier contract. Intrusive correctness checks establish no timing result;
incremental collection remains a proposal.

### Packed gzip inflater output (2026-10-12)

The inflater now accumulates decoded output in the existing packed byte builder.
Backreferences read newly emitted bytes when their ranges overlap, and refresh
the backing view when an append grows the buffer. Stored blocks append into the
same buffer so later compressed blocks can reference them. Finalization copies
only the initialized prefix. The exported `copyBack` retains its existing
arbitrary-`Int` vector behavior; the decoder uses a private packed helper.

Five fresh processes per variant, case, and initial-heap policy yield 80 timed
executions, followed by 16 separate GC diagnostic executions. Before and after
use the same compiler, emitter, runtime, `-O2`, static Boehm, inputs, and independent
system-gzip byte oracle. Variant and cohort orders alternate. Only the inflater
module differs between application source snapshots.

| Compiler-seed inflate, 26,301,788 decoded bytes | Default initial heap | 128 MiB initial heap |
|---|---:|---:|
| Median elapsed time, before → after | 1.935 → 1.649 s | 1.907 → 1.651 s |
| Median peak RSS, before → after (decimal MB) | 1,286.8 → 348.0 | 1,285.6 → 358.5 |
| Time reduction | 14.8% | 13.4% |
| RSS reduction | 73.0% | 72.1% |

This is a representation improvement under production Boehm, not a custom-GC
application result. The CLI still converts packed output to a word array for
file writing. Smaller cases have mixed timing changes, including regressions;
their RSS is largely hidden by a 55.9 MB inherited launcher floor. The seed's
RSS is well above that floor in both arms. Observed RSS reductions cannot be
equated with exact simultaneously live object bytes.

All 96 measured/diagnostic outputs match the independent bytes. Native tests
cover growth, overlap, high bytes, invalid distances without mutation, arbitrary
public `copyBack` values, and stored-to-fixed-block references. The latter fixture
also decodes independently with zlib. The
[complete artifact](../../test/gc_prototype/results/2026-10-12-gzip-packed-before-after.json)
contains samples, ranges, source snapshots, frozen measurement helpers, commands,
and full GC logs. An initial incomplete batch was discarded after an overly
strict stderr check rejected Boehm's nonfatal large-allocation warning; the full
matrix was rerun with an exact warning allowlist and all stderr retained.
Independent source and artifact reviews check the growth order, reconstruction
patch, identities, sample order, and timing summaries. The
[experiment README](../../test/gc_prototype/README.md) links the evidence.

### Retained-tree direct-old birth diagnostic (2026-10-13)

This diagnostic sends only retained-tree nodes directly to the mature allocator.
Both custom arms compile the same validated source; `TREE_DIRECT_OLD` is the
only candidate define. Generic allocation, zeroing, root registration/reloads,
store barriers and final collection remain present. The new birth call is
checked and out of line. Placement and allocation order also change, so this
does not isolate physical copying cost or establish a production policy.

Each fresh process constructs 5,000,000 nodes. Six balanced cyclic rounds compare
four capacities: 262144, 262136, 16777216 and 16777208 bytes. The two Boehm
allocators each use default and requested 128 MiB initial heaps, static libgc
8.2.8 and divisor 1. Boehm ignores the nursery-capacity labels. All 144 timed
rows pass allocation/checksum/storage contracts; compiler, static archive,
transitive headers, sources and four binaries retain their before/after hashes.
The existing elapsed interval includes construction, checksum traversal and
final GC, excluding heap/layout setup. It supplies no separate phase timings.

| Capacity | Custom nursery (ms) | Direct old (ms) | Historical Boehm default / 128 MiB (ms) | Caller Boehm default / 128 MiB (ms) | Paired direct/nursery median (range) |
|---|---:|---:|---:|---:|---:|
| 256 KiB | 301.7 | 248.3 | 379.5 / 344.4 | 254.8 / 248.0 | 0.824 (0.801–0.883) |
| 256 KiB − 8 B | 289.7 | 243.7 | 342.6 / 337.9 | 247.7 / 241.4 | 0.842 (0.718–0.976) |
| 16 MiB | 312.2 | 209.4 | 331.9 / 329.7 | 258.9 / 277.9 | 0.675 (0.615–0.696) |
| 16 MiB − 8 B | 324.2 | 210.5 | 334.5 / 318.1 | 252.3 / 251.9 | 0.664 (0.555–0.692) |

Times are six-process medians; ratios are medians of the six within-round ratios.
Direct-old/fastest-observed-Boehm paired medians are 1.001, 1.008, 0.817 and
0.825 respectively; their ranges are 0.899–1.083, 0.961–1.046, 0.763–0.833 and
0.733–0.904. This is a tree-only diagnostic with no selection or held-out claim.
A negative checked-birth result could not rule out specialized old allocation
or chunk retention; a positive result still includes the placement/order effects.

| Capacity | Median RSS nursery → direct old (MiB) | Historical Boehm default / 128 MiB RSS (MiB) | Caller Boehm default / 128 MiB RSS (MiB) | Minor / major counts nursery → direct old |
|---|---:|---:|---:|---:|
| 256 KiB | 155.0 → 154.8 | 167.3 / 167.4 | 167.3 / 167.4 | 618 / 8 → 8 / 8 |
| 256 KiB − 8 B | 155.0 → 154.8 | 167.4 / 167.4 | 167.4 / 167.4 | 617 / 7 → 8 / 8 |
| 16 MiB | 170.8 → 154.8 | 167.4 / 167.4 | 167.4 / 167.4 | 11 / 2 → 2 / 2 |
| 16 MiB − 8 B | 170.8 → 154.8 | 167.4 / 167.4 | 167.4 / 167.4 | 11 / 2 → 2 / 2 |

The mature limit is still initially `4*N`, then `2*live + 4*N`; changing nursery
capacity therefore changes major pacing even with no nursery births. Each major
includes a minor prepass, so the two collection counts are not disjoint. The
candidate avoids all 5,000,000 promotions: logical copied bytes change from
160,000,000 to zero, including 120,000,000 payload bytes. Both arms end with
160,000,000 logical mature bytes, 9,766 pools reserving 160,474,912 bytes, a
512-byte work queue and the same descriptor/layout/root storage. Exact accounted
bytes still include the identical reserved nursery. Direct-old peak accounting
is 736 bytes higher, reflecting the same pool reservation coexisting with
768 active root bytes during construction instead of 32 during the final minor.
The approximately 16 MiB RSS difference at the large capacities is consistent
with leaving that nursery reservation untouched; it is not a reduction in
reported reserved bytes. RSS is process high-water, and Boehm heap-minus-free
is not exact live-object accounting.

The accepted correctness run covers 159 checks, including ASan/UBSan,
pre-dereference barrier/root-reload negative controls, invalid prepared layouts,
all six non-tree counter controls, and equal same-heap postdrop schedules.
Independent source, packet and 144-row artifact reviews passed. The
[raw rows](../../test/gc_prototype/results/2026-10-13-direct-old-results.jsonl),
[measurement audit](../../test/gc_prototype/results/2026-10-13-direct-old-audit.json),
[independent audit](../../test/gc_prototype/results/2026-10-13-direct-old-independent-audit.json)
and [reproduction bundle](../../test/gc_prototype/results/2026-10-13-direct-old-reproduction.tar.gz)
preserve the evidence; the
[export manifest](../../test/gc_prototype/results/2026-10-13-direct-old-export.json)
records every archived file hash. The frozen protocol's historical `SOURCE ONLY`
label remains unchanged and is annotated externally in the
[reproduction notes](../../test/gc_prototype/results/2026-10-13-direct-old-README.md).

### Intrusive minor work queue screen (2026-10-13)

This isolated candidate copies each promoted payload completely, then borrows
nursery field zero as a pending-work link. It removes each entry before scanning
its children. Forwarding stays in the header; atomic objects still enter the
queue. Allocation, zeroing, scanning, major pacing and workload phases remain
unchanged. The mature marking queue remains an array.

The frozen screen runs all seven existing profiles at 5,000,000 inputs and both
256 KiB capacities, plus tree at both 16 MiB capacities: 576 fresh-process rows,
six balanced rounds and six arms. Boehm retains historical/caller allocators,
default/128 MiB initial heaps, static libgc 8.2.8 and divisor 1. Advancement
requires both small-tree cells to have median paired ratio below .95 and at
least five of six ratios below .95. Other cells reject repeatable slowdowns
above 1.05. All six arms remain visible in the evidence.

| Tree capacity | Baseline / intrusive median (ms) | Fastest observed Boehm median (ms) | Paired intrusive/baseline median | Samples below .95 |
|---|---:|---:|---:|---:|
| 256 KiB | 293.7 / 306.6 | 241.7, caller 128 MiB | 1.053 | 0/6 |
| 256 KiB − 8 B | 282.8 / 278.3 | 244.7, caller default | 0.984 | 1/6 |
| 16 MiB | 299.7 / 303.3 | 249.4, caller 128 MiB | 1.019 | 2/6 |
| 16 MiB − 8 B | 303.1 / 296.5 | 239.2, caller 128 MiB | 0.962 | 2/6 |

Both primary cells fail the gain rule. No secondary cell meets the repeatable
slowdown rule, and no qualifying RSS cell exceeds the 10% growth threshold.
Ten of sixteen cells are RSS-inconclusive because baseline median RSS is below
twice the independently recorded launcher floor; total RSS is never adjusted
by subtracting that floor. Every cell ends with the same 512-byte major queue.
Current and peak accounted storage are exactly 8 bytes higher, the static head:
32 untimed ledgers verify 134,704 component sums, including transient allocation
overlap. Removing minor queue traffic provides no final reserved-storage saving
in this matrix.

The unchanged full correctness runner and 18 independent positives plus five
named safe mutants pass with address/UB checks active; LSan is disabled under
ptrace. Independent source, reducer and raw-artifact audits pass. The screen
does not advance, and no collector installation or held-out confirmation follows.
[Raw rows](../../test/gc_prototype/results/2026-10-13-intrusive-screen-results.jsonl),
[measurement audit](../../test/gc_prototype/results/2026-10-13-intrusive-screen-audit.json),
[independent audit](../../test/gc_prototype/results/2026-10-13-intrusive-screen-independent-audit.json)
and the [reconstruction bundle](../../test/gc_prototype/results/2026-10-13-intrusive-screen-reproduction.tar.gz)
retain the exact evidence. The [export manifest](../../test/gc_prototype/results/2026-10-13-intrusive-screen-export.json)
hashes every member and annotates the frozen protocol's historical source-only
label externally. The bundle preserves sources and receipts, not a full host
replay environment.

### Copy/scan fusion correctness (2026-10-13)

Variant V retains the baseline85 vector queue and completes traced promotion
payloads while resolving pointers from the nursery source. It saves field zero
before forwarding, queues source headers, and uses the destination descriptor
while draining. Atomic objects still receive complete copies; direct-old
zeroing, remembered-owner scanning and major marking are unchanged. Forwarded
destinations may be privately incomplete only during the uninterrupted minor
drain. No mutator or major marker may observe them before completion.

After restoring the previously archived source bundle, the independent verifier
passed 22 positive runs and seven named negative controls under ASan/UBSan.
Eleven cases produce 12 paired stages: all 46 snapshot fields (45 numeric and
the stage name) match baseline exactly. An independent raw-evidence audit
verified diagnostics, identities, accounting and sanitizer instrumentation.
The unchanged full collector correctness suite also passed on the isolated
candidate, including ten backends, prepared allocation, pooled storage,
adversarial graphs and LLVM contracts. Missing bundled Clang sanitizer libraries
required the recorded system ASan/UBSan fallback; LSan was disabled. Host library
hashes are receipts, not a hermetic execution environment.

The candidate SHA256 remains
`02246c8148d2086ae70aef645305298605b3249c40f2ee666a4b9fb1a217de11`.
It is not installed or timed. These results establish correctness within the
tested contracts, not a speedup or full application support. The
[execution bundle](../../test/gc_prototype/results/2026-10-13-copy-scan-correctness-README.md)
preserves original link failures, successful commands, fixtures, source/binary
identities and independent audit. Its next-screen proposal still needs a
reviewed, frozen implementation and fresh paired baseline/Boehm measurements.
