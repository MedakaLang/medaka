# Native GC handoff

Prepared at the user's request as the session approached its usage limit. Finish
the current evidence and CI work; do not infer permission to start another timing
batch from this handoff. The overall performance goal remains unachieved.

## Start here

- Working branch: `experiment/gc-feasibility`; draft [PR #4061](https://github.com/MedakaLang/medaka/pull/4061).
- Main revision integrated: `cad1303e1f9a8b1608fba79d36fbc6b5d307759c`.
- Last source integration commit: `701a3cc43`; measured/CI head before this
  handoff's evidence-only additions: `e2ef41974f99360c226a72f08861e070a635d110`.
- Collector baseline remains `85c364304684c44c544957c8ba2b180d15d736c5`.
  The current [gc.c](gc.c) and [gc.h](gc.h) have not received the rejected
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
The pushed repair still requires fresh hosted CI; do not report the old run as
fully green.

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

Also rejected or not selected: descriptor caching, promotion inlining, larger
mature headroom, root-pair registration, whole-payload initialization, larger
nursery defaults, and the supplementary allocation-pressure policy. Preserve
their negative results. The proposed 375-process confirmation batch has never
run. No new default has been selected.

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
