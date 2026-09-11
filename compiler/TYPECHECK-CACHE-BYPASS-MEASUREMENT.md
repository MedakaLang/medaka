# Cost of bypassing all three typechecker memos

Owners: #2549 finalized-result caching, #2719 performance, #2902 request
contamination; prerequisite to #2646 defaulting and the return-family migration.
This is an isolated experiment, not a production patch or budget waiver.

Base: `433eaa9f78763ea64fdbde57a477359a0816cb90`, typecheck source SHA-256
`d330cbd60f11a927c00053b36a0c70fc239e0792da17ee6890803908efbea0c9`.
Guarded mutator: `/tmp/rearch-all3-memo-bypass.py`; receipts, diff, normalized
protocol responses, and restoration hashes: `/tmp/rearch-cache-bypass-measure`.

## Controlled change

Bypass PreludePreamble through preludePreambleOf, CoreCheckMemo through its None
key path, and ChainMemo through a fresh full fold without snapshot construction
or reads/writes. Remove unused ChainStep construction. Preserve core, keyed
intermediate, and final drains exactly, with no solver/defaulting change.
PreludePreamble is included because its implementation rows carry InstRefs.

Use the existing M2 same-process LSP instrument and identical heaps. Cold is
N1−N0, first warm N2−N1, second warm N3−N2.

| Workload | Phase | Baseline instructions | Bypass | Change |
|---|---|---:|---:|---:|
| playground | cold | 305,155,294 | 305,216,700 | +0.0201% |
| playground | first warm | 24,824,825 | 296,842,903 | +1095.8% |
| playground | second warm | 24,825,818 | 296,792,383 | +1095.5% |
| import-list | cold | 538,326,563 | 538,226,157 | −0.0187% |
| import-list | first warm | 38,164,804 | 395,988,745 | +937.7% |
| import-list | second warm | 38,180,543 | 395,920,623 | +936.9% |

| Workload | Phase | Baseline allocated bytes | Bypass | Change |
|---|---|---:|---:|---:|
| playground | cold | 48,585,792 | 48,570,480 | −0.0315% |
| playground | first warm | 4,566,496 | 47,142,240 | +932.7% |
| playground | second warm | 4,570,656 | 47,109,760 | +930.8% |
| import-list | cold | 93,144,592 | 93,106,720 | −0.0407% |
| import-list | first warm | 6,884,272 | 62,901,568 | +813.9% |
| import-list | second warm | 6,887,664 | 62,881,760 | +812.9% |

Warm cost exceeds the 25% soft budget by a wide margin. This measures the aggregate
cost of losing all three caches, not the safety or cost of one independently.
It measures instructions and allocation, not retained heap.

## Validation and disposition

Normalized diagnostics and hover match byte-for-byte on both fixed workloads;
strict freshness and all N0–N3 exits pass. check_self passes, registry tests pass
32/32, and solver-contract tests pass 3/3.

The typecheck sibling reports 14/15 on the bypass arm. The failing test requires
empty traces on three prefix-cache hits. Bypass re-infers those prefixes and emits
traces, so those three assertions fail. The same test's frame count/capacity and
error assertions remain true. This is an expected cache-observation mismatch, not
evidence of a changed semantic result; preserve the failure receipt.

The experiment was restored byte-exact, rebuilt and checked strictly; its tree is
clean. No bypass source was committed to the running branch. Safe finalized or
freshly instantiated summaries are needed before enabling the semantic migration
within the current budget. Shared mutable snapshots are not an acceptable shortcut:
#2902 reproduces false type errors on the pristine baseline and current source.
The scope-store extraction can proceed independently.
