# Native GC handoff

Prepared at the user's request as the session approached its usage limit. Finish
the current evidence and CI work; do not infer permission to start another timing
batch from this handoff. The overall performance goal remains unachieved.

## Start here

- Working branch: `experiment/gc-feasibility`; draft [PR #4061](https://github.com/MedakaLang/medaka/pull/4061).
- Main revision integrated: `cad1303e1f9a8b1608fba79d36fbc6b5d307759c`.
- Last source integration commit: `701a3cc43`; validated/CI head before this
  handoff's evidence-only additions: `e2ef41974f99360c226a72f08861e070a635d110`.
- Collector baseline remains `85c364304684c44c544957c8ba2b180d15d736c5`.
  The current [gc.c](gc.c) and [gc.h](gc.h) have not received the scratch
  pressure, direct-old, intrusive-list, or deferred-copy experiments.
- Production uses Boehm. The experimental collector is C. No full PDS, gzip,
  or compiler execution on the moving collector has been established.
- Tracking: [#503](https://github.com/MedakaLang/medaka/issues/503),
  [feasibility/results](../../docs/design/GC-FEASIBILITY.md),
  [native integration architecture](../../compiler/EMITTER-TARGET-ARCHITECTURE.md).

Read the repository and compiler AGENTS instructions before implementation.
Serialize local builds, correctness runs, and benchmarks on this shared box.
Use fresh probes from the exact source tree; do not borrow emitters. Keep all
four Boehm comparisons (historical/caller-inline, default/fixed initial heap),
final collection, and both aligned/offset nursery controls in comparisons.

## What is validated

The merged compiler includes the F5 carrier/LLVM consumer sprint, the native
producer inventory, intrinsic Boolean return repair, and the restricted
ByteBlock helper experiment. The merge was regenerated from fresh compilers,
including two forced rebuilds, two seed refreshes, fresh probes, semantic checks
before golden capture, and reproducing C3a/C3b fixpoints.

The [combined validation record](results/2026-10-12-combined-cad-byteblock-validation.json)
records 100 commands and their actual exits. It includes the focused compiler
siblings, 122 string tests and array tests/properties, compiler-source and census
gates, 62 typed LLVM runtime/IR fixtures, nine typed Wasm fixtures plus four
incoming string fixtures, three Boolean-return routes, and 18 selfproc checks.
The [fresh ByteBlock matrix](results/2026-10-12-combined-cad-byteblock-result.json)
passed 86 checks with the final source-provenance/timeout guards.

ByteBlock kernels execute real runtime helper bodies with custom atomic objects,
explicit helper roots, and relocation reloads. They are a closed, checked
execution domain: a copied source cannot remain live in the caller. The general
report deliberately remains `incomplete` and `moving-safe=false`. This does not
establish general mixed-heap safety, caller roots, or application support.

The earlier isolated ByteBlock evidence remains separate from the combined
rerun. ASan/UBSan instrumentation remained active, with leak detection and the
alternate signal stack disabled for documented host/runtime constraints.
Valgrind's raw run reported 156 startup Boehm conservative-stack conditions;
the narrowly suppressed run had zero remaining errors. Do not call that an
unsuppressed-clean run.

Historical separate milestones include packed-gzip byte-oracle measurements,
29 exact PDS varint LEB128 boundary cases under Boehm, the full 236-fixture LLVM
suite, and the 50-assertion signing gate with Valgrind controls. They were not
all repeated on the latest merged head. The combined record states its limits.

Hosted CI completed at e2ef41974: 19/20 CI jobs passed and macOS passed. The only
failure was `diff_compiler_cli_reject_floor`: the new standalone typed-emitter
probe was missing from the existing non-CLI flag exemption ledger. Commit
`9504da667` adds that row and its reason. Strict formatting/lint and all seven
native checks, including exemption necessity and no-CLI-reachability checks,
passed with the compiler binary unchanged. The [repair record](results/2026-10-13-cli-probe-registration.json)
preserves exact commands, outputs, source/binary hashes, and the pre-fix base.
Fresh hosted CI then passed at exact head
`bdcc13c75fc7bb788feee1eae640cd6d3ded1c53`:
[CI run 38342914637](https://github.com/MedakaLang/medaka/actions/runs/38342914637)
completed successfully with all 20 jobs passing, including Wasm and the repaired
gate; [macOS run 38342914768](https://github.com/MedakaLang/medaka/actions/runs/38342914768)
also completed successfully. This handoff expansion is a subsequent docs-only
change; those results validate the named head, not a later commit.

## Performance conclusions

The custom nursery benefits short-lived synthetic workloads. The retained-tree
path remains the primary weakness against the strongest matched Boehm adapter.
Do not compare to the slower historical Boehm arm and call the goal achieved.

The independently audited 144-run direct-old diagnostic is informative:

| Nursery/pacing setting | Baseline ms | Direct-old ms | Fastest Boehm ms |
| --- | ---: | ---: | ---: |
| 256 KiB | 301.73 | 248.30 | 248.05 |
| 256 KiB minus 8 bytes | 289.68 | 243.65 | 241.40 |
| 16 MiB | 312.25 | 209.36 | 258.90 |
| 16 MiB minus 8 bytes | 324.23 | 210.52 | 251.90 |

Direct-old RSS was about 154.8 MiB versus Boehm's 167.4 MiB. This changes birth
placement/order, removes evacuation, and can change automatic collection
scheduling. It is not an isolated copying-cost measurement or a selected
pretenuring policy. See the [reproduction notes](results/2026-10-13-direct-old-README.md).

The OCaml-inspired intrusive promotion list passed independent sanitizer and
mutation checks, the full existing collector suite, and a 576-row screen with
exact accounting. It did **not** advance: small-tree paired median time ratios
were 1.052750 and 0.984207, with 0/6 and 1/6 qualifying gains. Both primary cells
needed a median below 0.95 and at least five qualifying pairs. No secondary
cell met the repeatable-regression rule. Ten RSS cells were floor-limited.
All final queues remained 512 bytes; current/peak accounting increased by eight
bytes. The isolated 17-object minor-only queue saving was real but did not
translate into this screen's final storage or required throughput gain.
The [raw screen](results/2026-10-13-intrusive-screen-results.jsonl),
[measurement audit](results/2026-10-13-intrusive-screen-audit.json), and
[independent audit](results/2026-10-13-intrusive-screen-independent-audit.json)
are retained with a reproduction archive and export manifest.

## What we tried and learned

These are historical experiments with different measurement cohorts, not rows
of one comparable benchmark. The linked sections contain exact sources, commands,
raw samples, controls and limitations. "Retained" means part of the experimental
baseline, never a production collector switch. Revisit a rejected approach only
with a concrete new hypothesis; do not rerun the same variant under a new name.

| Work | Disposition and lesson | Durable detail |
| --- | --- | --- |
| Initial explicit-root copying nursery and mature heap | Established evacuation, barriers and root-update correctness; object/storage overhead made the first representation uncompetitive. | [First prototype](../../docs/design/GC-FEASIBILITY.md#first-prototype-results-2026-10-12) |
| Eight-byte headers and size-class mature pools | Retained. Retained-graph RSS fell from about 482 to 163 decimal MB; compact storage alone did not fix allocation throughput. | [Compact pooled heap](../../docs/design/GC-FEASIBILITY.md#compact-pooled-heap-2026-10-12) |
| Closed generated-LLVM rooting transformer | Validated a restricted root/reload contract with negative controls. It is not a general emitter or application root planner. | [Generated-code experiment](../../docs/design/GC-FEASIBILITY.md#generated-code-rooting-experiment) |
| Prepared layouts and caller-visible allocation/stores | Retained. Eliminating hot wrapper/descriptor work helped short-lived workloads. Give Boehm caller-inline allocation too; the historical wrapper is a weaker comparator. | [Prepared allocation](../../docs/design/GC-FEASIBILITY.md#prepared-layouts-and-caller-allocation-2026-10-12) |
| Avoid zeroing immediately before promotion memcpy; update storage peaks on reservation changes | Retained together. Same-run list/tree medians improved 13–14%/7–8%; direct-old births and padding still get zeroed. | [Promotion work](../../docs/design/GC-FEASIBILITY.md#promotion-work-and-retained-graphs-2026-10-12) |
| Inline queue append/capacity test with cold growth | Retained. Lists improved 3–6%; roughly 1% tree changes were inconclusive. This is different from replacing the queue with an intrusive list. | [Queue allocation](../../docs/design/GC-FEASIBILITY.md#tracing-queue-allocation-experiment-2026-10-12) |
| Inline common marking path | Retained. Final major time improved 20–23%, while whole-tree medians moved only 2–4%. Construction remained the main deficit. | [Phase attribution](../../docs/design/GC-FEASIBILITY.md#retained-tree-phase-attribution-and-marking-2026-10-12) |
| Cache mature size class/extent in descriptors | Rejected, 448 rows. Assembly removed the intended work, but tree medians worsened and metadata grew 256 bytes. Fewer instructions did not imply faster execution. | [Descriptor cache](../../docs/design/GC-FEASIBILITY.md#rejected-descriptor-cache-2026-10-12) |
| Full/split promotion inlining | Rejected, 560 rows. Small mixed changes did not establish a useful gain. | [Promotion inlining](../../docs/design/GC-FEASIBILITY.md#rejected-promotion-inlining-2026-10-12) |
| Larger mature threshold (live coefficient 2→4) | Rejected after the bounded transition screen. Delaying major collection retained dead memory and did not justify wider measurement. | [Major threshold](../../docs/design/GC-FEASIBILITY.md#rejected-larger-major-collection-threshold-2026-10-12) |
| Bounded empty-pool cache | Deferred idea, never implemented or measured. Pool allocation/release counts alone did not establish a dominant CPU cost. | No runtime result exists. |
| Nursery/reserve sweep | No default selected, 576 rows. Large nurseries reduced transition promotion but increased RSS and hurt other work. An omitted predeclared reducer criterion is explicitly disclosed; the memory rejection still stood. | [Nursery sweep](../../docs/design/GC-FEASIBILITY.md#nursery-and-major-reserve-sweep-2026-10-12) |
| Total-mutator allocation-pressure budget | Rejected, 576 rows. Large-nursery transition improved, but small-nursery benefit did not qualify and aligned large-nursery trees regressed 8.5%. Stable-graph churn also worsened. | [Pressure screen](../../docs/design/GC-FEASIBILITY.md#allocation-pressure-screen-2026-10-12) |
| Whole-payload initialization helper | Not selected, 700 rows. Some tree benefit, mixed controls including a list regression. This still used zeroed allocation; it did not test compiler-proven zeroing elimination. | [Initialization candidate](../../docs/design/GC-FEASIBILITY.md#whole-payload-initialization-candidate-2026-10-12) |
| Pair adjacent root registration/removal | Rejected, 288 rows. Four calls became two, but only the offset tree improved; aligned results were flat and Boehm remained ahead. | [Root-pair screen](../../docs/design/GC-FEASIBILITY.md#root-pair-registration-screen-2026-10-12) |
| Direct-old retained-tree birth | Diagnostic only, 144 rows. Closed or reversed the Boehm gap, with less RSS; changes placement, copying and sometimes pacing together. | [Direct-old diagnostic](../../docs/design/GC-FEASIBILITY.md#retained-tree-direct-old-birth-diagnostic-2026-10-13) |
| Intrusive minor work list inspired by OCaml | Rejected, 576 rows. Correct and precisely accounted, but neither primary tree cell qualified. Minor-only queue savings did not remove the final major queue. | [Intrusive screen](../../docs/design/GC-FEASIBILITY.md#intrusive-minor-work-queue-screen-2026-10-13) |
| PDS/gzip application baselines | Real byte/count oracles and Boehm measurements established; these do not run full applications on the custom heap. | [Application baselines](../../docs/design/GC-FEASIBILITY.md#measured-application-baselines-2026-10-12) |
| Packed gzip inflater output | Implemented and measured under Boehm: large seed workload 1.935→1.649 s and 1,286.8→348.0 decimal MB RSS; small inputs mixed. Preserve overlapping backreferences and public arbitrary-Int copyBack behavior. | [Packed gzip](../../docs/design/GC-FEASIBILITY.md#packed-gzip-inflater-output-2026-10-12) |
| Compiler-produced native inventory | Implemented, incomplete, and output-neutral. It observes physical contracts; it does not create a valid root map. Report-disabled compiler overhead has not been separately benchmarked. | [Native inventory](../../docs/design/GC-FEASIBILITY.md#compiler-produced-native-inventory-2026-10-12) |
| Real ByteBlock helper relocation seam | Implemented for closed kernels, 86 combined runtime checks. Establishes helper rooting/extent/relocation behavior while leaving caller roots and full applications unsupported. | [Combined evidence](results/2026-10-12-combined-cad-byteblock-validation.json) |

The proposed 375-process confirmation batch has never run. Its preparation and
drift-rejection checks passed, but a preparation result is not timing evidence.
The copy/scan-fusion source below is a new prepared candidate, not a tried or
validated runtime optimization.

## Lessons that should survive the session

- **Boehm's advantage has a mechanism.** On retain/drop/churn at the small
  nursery, 98.565% of churn payload was promoted while temporarily rooted.
  Nonmoving Boehm avoids evacuation and often allocates from a caller-inline
  thread-local free list. Overlapping profile shares are not additive costs.
- **Alignment changes survival and scheduling.** A 256 KiB nursery fits 8,192
  32-byte cells, aligning with the 256-node ephemeral drop interval. An eight-byte offset
  changes copied fractions and can change construction-time major counts. Keep
  both settings; do not choose the favorable one after looking at results.
- **Time and memory need several measurements.** Logical live bytes, reserved
  pool/descriptor/queue/root storage, transient resize peaks and process RSS are
  different quantities. Boehm heap-minus-free is not exact live storage. Small
  child-process RSS can be dominated by the Python launcher's changing high-water
  floor; retain the floor observations and mark those comparisons inconclusive.
  Compare total RSS without subtracting that floor; inconclusive is not memory
  approval. Copy counters record logical promoted volume: `copied_bytes`
  includes headers; `copied_payload_bytes` excludes them. Neither counts all
  physical reads and writes.
- **Attribute only what was measured.** Tree construction includes allocation,
  rooting, promotion and automatic collections. A direct-old change is not a
  pure copying-cost test. Separately computed phase medians need not sum to total
  medians. The pressure screen's transition validation was inside whole elapsed
  but not fully inside phase timers; zero reported phase time did not mean zero
  work. The original packet and explicit erratum are preserved. Pool-call counts
  and additional major collections alone do not establish a CPU hotspot.
- **Freeze comparisons before running.** Record sources, transitive headers,
  compiler/library/binary identities, schedules, environment and thresholds.
  Preserve attempts and failures. A median of paired ratios is not the ratio of
  medians. Pressure and intrusive screens used different frozen reduction rules;
  retain each packet's own criteria. The four Boehm arms use static libgc and
  free-space divisor 1; 128 MiB is an initial heap size, not a cap. Keep final
  collection, checksums, assertions, poisoning, initialization
  obligations and memory charges; do not win by dropping a required cost.
- **Compiler freshness has two generations.** Behavior and the emitter that
  compiled the binary are separate. Use the benchmark-emitter skill, forced
  rebuilds and fixpoints; do not copy another worktree's emitter. Never resolve
  generated merge conflicts by hand or bless output before semantic validation.
- **Semantic facts do not identify roots.** F5, `RTValue`, LLVM `i64` and the
  emitter's integer lowering type do not constitute physical scan maps. Earlier
  arguments, projected values, joins, foreign-helper inputs and TRMC interior
  pointers need explicit native ownership/root/reload contracts.
- **Use OCaml mechanisms with their contracts.** The review pins OCaml commit
  `907eec0b75c5bcf0fe6da5f4b9f11c5c22995a16`. Useful ideas are cheap compiled
  allocation, precise safepoints, initialization windows, temporary promotion
  layouts and mature pools. Its nursery configuration is explicit; its major
  allocation debt counts promotion/direct-major allocation, not all dead young
  allocation. Our rejected total-mutator budget was a separate hypothesis.
  The source links and distinctions are in the [OCaml review](../../docs/design/GC-FEASIBILITY.md#lessons-from-ocamls-compilerruntime-contract-2026-10-12).
- **C was an integration choice.** Rust could safely manage collector metadata;
  it would still require explicit foreign-object and generated-code contracts.
  No C-versus-Rust speed experiment was performed. Do not relitigate that choice
  based on a claim that Rust would provide no safety benefit.
- **State tool limitations precisely.** This host lacks the Clang ASan runtime
  archives used by the default link; tested harnesses record the system-runtime
  fallback. LSan/alternate-stack exceptions and scoped Valgrind suppressions are
  documented per run. A named, pre-dereference mutant failure is evidence;
  arbitrary sanitizer crashes, timeouts or wrong exits are not.

## Prepared next experiment: source only

The next idea, taken from pinned OCaml minor promotion, fuses copying traced
fields with resolving their pointers. Current promotion copies the payload and
then rewrites its traced fields. The prepared variant V uses the original
vector queue, independently of the rejected intrusive-list change.

Candidate C SHA256:
`02246c8148d2086ae70aef645305298605b3249c40f2ee666a4b9fb1a217de11`.
Header/workload are exact baseline85. Independent source review passed.
**No candidate, verifier, or mutant native binary has been built or run. No
timing or runtime-correctness claim is available.**

The [source-only bundle notes](results/2026-10-13-copy-scan-source-README.md)
provide the exact baseline, candidate, patch, packet, prepared verification
files, review receipts, member hashes, and restoration/next commands. The first
resumed step is independent correctness, followed by the unchanged complete
collector suite and exact counter/storage checks. Only after these pass should
a separate timing packet be reviewed and run.

Critical invariant: a forwarded mature object may be privately incomplete
during the uninterrupted minor drain. Save field0 before forwarding; queue
source headers for minor work and mature headers for major work; consult the
destination descriptor; preserve mask-zero full copies, raw tails beyond bit63,
remembered-owner scanning, direct-old zeroing, and padding. No mutator, callback,
major marker, or generic payload reader may observe incomplete fields. Mutation
checks must fail before unsafe dereferences, not merely crash under sanitizers.

## Compiler integration after that

R5a names rooted immutable construction as the next bounded integration seam:
physical operand handles protect earlier arguments and conditional results,
reload after allocation, and initialize direct-old children with barriers while
retaining the generic zeroed allocator. Function frames need balanced cleanup
and a collection-free return handoff.

The proposed target is the real recursive PDS varint digit-list computation,
with TRMC explicitly disabled for that experiment and recursion bounded by the
integer domain. It needs a trusted import/direct-call closure; do not silently
discard unsupported retained impl bodies. Complete encoding still needs
Builder/Ref roots and mutation barriers; gzip has broader helper/ownership
requirements. Compare any timings with equally configured and strongest normal
Boehm routes. Do not expand F5 into a second GC type-inference authority.

## Before merge and session cleanup

The user explicitly deferred evidence packaging cleanup until merge preparation.
At head e2ef41974, raw results/audits accounted for 168,234 of 187,238 added lines.
Preserve byte-exact data and checksums, then move bulk evidence into compressed
artifacts with readable summaries/reproduction instructions. Do not just delete
failed experiments, minify away reviewability, or rewrite historical provenance.

Keep the PR draft until its intended scope and all required checks are ready.
Read CI for the exact latest head; older green runs are historical. Hosted CI
may still be running when a handoff is read. Query PR4061 and its check runs.

The clean isolated ByteBlock worktree `/tmp/medaka-gc-byteblock` at `710836421`
is retained for reproduction; its change is cherry-picked as `df812453b`.
Other sessions own hundreds of worktrees and the shared stash stack: do not
remove them. Local experiment scratch is retained for this handoff, with
critical new evidence/source archived in the repository. Do not kill global
compiler pools or delete `/tmp` broadly. Verify each owner before cleanup.
