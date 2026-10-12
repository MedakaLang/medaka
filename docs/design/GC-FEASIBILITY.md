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
Independent source and artifact reviews check the growth order, reconstruction
patch, identities, sample order, and timing summaries. The
[experiment README](../../test/gc_prototype/README.md) links the evidence.
