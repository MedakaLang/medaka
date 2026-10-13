# Generated LLVM moving-root contract

This on-demand correctness experiment compiles three actual Medaka source
fixtures through the existing typed LLVM entry, validates their emitted LLVM
against independently authored semantic contracts, and adds mutable root slots
and operand reloads. It does not change the production emitter or runtime.

```sh
sh test/build_oracles.sh --build-one llvm_emit_typed_main
python3 test/gc_prototype/generated_contract/validate.py \
  --output /tmp/medaka-generated-gc-check
```

Build the probe with the command above before validation. The probe does not
implement the CLI's source-staleness check; the runner records its binary hash
but does not prove freshness merely by setting `MEDAKA_STRICT=1`. Validation
requires successful typed emission without diagnostics, clang, and Boehm
development files. It retains
the original and transformed LLVM plus `provenance.json` in the output
directory. Provenance includes source, emitter, collector, header, transformer,
runner, shim, independent rejection checks, runtime catalog and trusted-contract
hashes, Git HEAD, platform,
build commands, collection schedules, exit statuses and exact output. The
output directory must be empty, preserving previous evidence. Temporary
binaries are removed after validation.

The source-level answers follow directly from the record fields: `arguments`
returns the earlier argument's `21`, `field` returns the projected child's
`137`, and `nested` returns the nested right field's `89`. Each fixture runs
at `-O0` and `-O2` with two collection schedules, at `-O2` under ASan/UBSan,
and against ordinary Boehm using the same transformed LLVM and `gc.c` compiled
with `USE_BOEHM`. The small C adapter provides only collector/root
entry points, argument setup, scalar printing and startup; the workload is
emitted Medaka code. This baseline does not use the production inline allocator
or worker-thread configuration, and the experiment reports no timings.

The collector moves only young objects. Collection immediately before every
allocation would promote a child before construction of its owner, hiding
the boxed-field relocation case. Bit `n` in each schedule selects collection
before allocation number `n`: arguments uses `[2]` and `[1,2]`, field uses
`[3]` and `[2,3]`, and nested uses `[3,5]` and `[3,4,5]`. The adapter checks
that every selected collection ran. Positive collection/promotion counts, balanced roots, no
direct-to-old allocation, and zero old live storage after final collection
are checked by the adapter.

Two deliberate defects must produce exact silent wrong answers with a normal
exit and collector diagnostics: stale call arguments produce `43` instead of
`21`; dropping the boxed-field root produces `99` instead of `137`. Unrelated
crashes do not satisfy these controls. Unsupported source fixtures and malformed
LLVM controls exercise rejection, including raw-pointer lifetime, field bounds,
raw header loads, raw arguments, interrupted constructors, recursion after a
completed constructor, indirect/atomic calls, invalid call/return types,
post-construction mutation and uncontracted unreachable functions. Independent
rejection witnesses live in `rejection_checks.py`.

The trusted contracts in `validate.py` specify every record tag, field type,
function parameter type and result type for this source corpus. The transformer
accepts only inputs matching those contracts. It is not a verifier for arbitrary
LLVM or arbitrary typed Medaka programs. `i64` and `LTInt` alone are never used
to classify roots. Constructor headers and the final raw integer used for
printing remain unrooted. Constructor fields have tagged-value descriptors,
excluding the raw header at slot zero.

The accepted grammar is straight-line immutable record construction/projection,
tagged integer values, and direct calls in an acyclic call graph. Constructors
must initialize every field exactly once in schema order, with no intervening
call. Arrays, mutation, globals, atomic allocation, closures, callbacks, FFI,
branches, phi nodes, tail transfers, raw workers and all unlisted instructions
or runtime calls are rejected. Tagged record values may survive a call through
their mutable root slots; raw LLVM heap pointers may not survive any direct
call. Each operand use reloads its tagged value, including earlier arguments
and constructor stores following allocation.

Roots remain registered until their function returns, deliberately retaining
dead values. This establishes a generated-code correctness seam, not root
liveness, representative survival rates, compiler coverage or performance.
Extending to control flow and accurate liveness should introduce emitter-owned
GC-aware values/root metadata rather than expand this closed transformer into
another LLVM parser or backend. This experiment is explicitly invoked and is
not enrolled as a CI gate.
