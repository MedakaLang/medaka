# Direct-old retained-tree diagnostic evidence

The completed UTC 2026-10-13 diagnostic contains 144 timed rows: 5,000,000 retained
tree nodes, four capacities, six arms and six balanced cyclic rounds. All rows,
paired storage contracts and before/after provenance checks passed. The separate
correctness run passed 159 checks. The independent read-only audit recomputed all
summaries and confirmed balance, source/binary stability and raw-file identity.

The retained sources and scripts are exact measured/validated bytes. In particular,
the approved PROTOCOL.md still says SOURCE ONLY. That is its historical status at
review/freeze, not the final execution status. It was intentionally NOT rewritten
after measurement. audit.json records completed execution; this README supplies
the external annotation.

Files:

- 2026-10-13-direct-old-results.jsonl: original raw bytes, unchanged.
- 2026-10-13-direct-old-audit.json: original runner audit, commands, per-run stdout,
  six-sample summaries, paired ranges, source/header/toolchain/binary hashes.
- 2026-10-13-direct-old-independent-audit.json: independent verification of 144 rows.
- 2026-10-13-direct-old-reproduction.tar.gz: validated/original/shared sources,
  reconstruction patch, fixtures, correctness/timing scripts and evidence,
  production 85c allocator extraction, four measured binaries, static libgc archive,
  all transitive header snapshots and available licensing texts.
- 2026-10-13-direct-old-export.json: hashes for durable files and every uncompressed
  archive member, original paths, sizes and external compiler reference.

The compiler executable is NOT redistributed: its exact path/version/hash are
recorded in the audit and export manifest. Header snapshots and static libgc are
evidence of the measured build inputs; rebuilding with another toolchain produces
new binaries and requires a new provenance record. The included measured binaries
are Linux x86_64 executables, not portable application releases.
ELF host libc and loader dependencies are not archived or hash-pinned; the bundle
is reproducibility evidence rather than a hermetic replay environment.

For replay, unpack the bundle in a new empty directory. Its replay/ subtree retains
the original /tmp directory layout. Restore medaka-tree-direct-old-85 under /tmp
if absent; retain its original verification JSON and adapter snapshots. Copy the
archived timing runner and approved protocol into another NEW empty directory
(not the original measured directory), then run that copied runner with --execute
only when CPU is reserved. The frozen scripts use the original repository path
/root/.codex/worktrees/f396/medaka as cwd; retain that checkout/path or visibly adapt
copies and record their new hashes. Never silently rewrite the archived originals.
The audit also provides direct compile and per-process commands for rebuilding
from the same C sources in other paths. A different path/toolchain need not produce
the same executable hash.

Measurement is existing elapsed_seconds: construction, checksum traversal and final
GC, excluding heap/layout setup. No extra collection phases were added. RSS is
process high-water, not exact live bytes. Boehm ignores nursery capacity and its
heap-minus-free metric is conservative. Fixed 128 requests an initial heap, not a
memory cap. Both Boehm adapters retain version/size guards and traced uncollectable
freelist heads, static linking, GC_THREADS/pthread and divisor 1.

This is a birth-route diagnostic with changed mature placement/allocation order,
checked out-of-line old birth and full zeroing. It does not isolate physical copy
cost, select a policy or establish held-out performance. No compiler/runtime
production edit is part of this evidence.
