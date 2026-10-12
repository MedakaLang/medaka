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

**Current direction:** keep the pooled representation as an experimental
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
