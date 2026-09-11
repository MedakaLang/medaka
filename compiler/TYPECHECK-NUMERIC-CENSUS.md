# Graph-end numeric defaulting: bounded census

Owner: #2646, coordinated with #2549 cache ownership and #2665's later T4 census.
This records a prerequisite experiment, not a defaulting implementation or a
complete per-goal T4 census. No warning policy changes are authorized by it.

The temporary audit used source `ee61c0a35`; ordinary controls used the clean,
strictly fresh `cd42e56f4` compiler. The audit captured live literal cells, scope,
module, location, predicate identity/arguments and visible givens, then observed
the same cells after prefix and final drains. Display spellings were not used to
establish cell identity. Its patch and native receipts are retained in the session
artifact directory `/tmp/rearch-num-census`.

## Positive candidate and last determination

```medaka
shared = identity (x => x + 1)
main = println "ok"
```

The literal remains Unbound at whole-graph finalization, outside the generalized
deferrable-ID set, with two known-Num obligation observations on the exact captured
cell and no visible given. Ordinary check reports `shared : a -> a`; interpretation
and native execution print `ok`, all exit zero.

Changing only main to `println (shared 2.5)` grounds that same cell to Float;
ordinary check reports `shared : Float -> Float`, and both execution engines print
`3.5`. A real selective-import two-module form also checks and prints `3.5`.

Source inspection establishes the boundary: ordinary application is expansive,
isValue is False, and genRestricted False retains a monomorphic scheme with no
quantified IDs. Argument occurrence protects the live cell at the group boundary;
it is still available for later inference. Under DICT D1/D3 and T2, an unused
survivor defaults only when the complete graph has had its last chance to constrain
it. A prefix drain is not that point. An impl-candidacy Num observation is numeric
taint, not an independently existing dictionary that can determine the variable.

## Cache order observation

The prefix exports the same expansive shared binding. Two sequences use separate
cache keys and alter only the suffix. Every request reports zero diagnostics.

| Sequence | Final literal states |
|---|---|
| unused, Float use, unused | Unbound, Float, Float |
| Float use, unused, Float use | Float, Float, Float |

Cold unused ends Unbound; unused after Float ends Float. This is an observed
retained-prefix mutation under the existing shallow snapshots, before adding any
new defaulting. The prefix observation captured on the initial inference remains
Unbound in replayed audit rows; it must not be mistaken for a newly performed
prefix solve on a cache hit. Final rows re-observe the live cell.

The destination contract forbids sharing mutable inference cells between requests.
The adopted migration plan requires bypassing or replacing all three affected
memos: CoreCheckMemo, ChainMemo and PreludePreamble (whose implementation rows carry
InstRef). The separate measurement in TYPECHECK-CACHE-BYPASS-MEASUREMENT.md
preserves the drain schedule but exceeds the warm budget by a wide margin.
No production bypass is enabled.

The independent uninstrumented native repro is now #2902: Float then explicitly
Int-using suffixes produce a false type mismatch; reverse order falsely rejects
Float. Ordinary cold processes accept both. The matrix is byte-identical on
pristine `2b6e08c8d` and `f35e93280`, so this defect predates the current slices.
Both arms' command/output/hash receipts are in `/tmp/rearch-cache-poison-repro/logs`.

## Controls and limits

In accept_impl_body_numlit_stays_poly, mk and lift retain unbound numeric cells
outside the generalized set. Each has a visible full known-Num given on the same
live root: mk's explicit instance `requires Num b`, and lift's declared method
predicate. These are specified determination channels and must remain polymorphic.
Their absence from another obligation ledger would not make them default candidates.

The bounded matrix also observes closed test/property literals as Int, caller-
selected Float, generalized inc/total literals as unbound and deferrable, a user
Num Vec case as Generic Vec, and the D2 co-predicate control's expected diagnostic.
The selected where fixture ends Int; the selected parse-block fixture contains no
integer literal. No unknown-argument Num witness occurred in this matrix. None of
these observations is an exhaustive claim about all goals or compiler inputs.

Before a production graph-end defaulting slice, define the ownership/provenance
API for independently existing channels, preserve generalized/outer-owned cells,
substitute without dropping any co-predicate (D2), and restamp literal routes after
grounding. Distinguish full finalization from every prefix drain. After defaulting,
re-take the per-goal T4 census; SC-3 remains an owner decision.

## Reproduction receipts

The session artifacts include findings.md, instrument.patch, the exact
num_census_probe_test.mdk, matrix-final.log, focused-final.log,
witness-summary-final.log, ordinary normal-check/run/build/built logs, source
hashes, and strict check/lint results. Earlier partial summaries are superseded by
the final files. The disposable tree is restored and rebuilt separately; no
instrumentation belongs on the running branch.
