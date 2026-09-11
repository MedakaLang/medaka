# Nominal scope-store extraction

Owner: #2586, under TYPECHECK-CONTRACTS §§5–6. Designed and independently
reviewed against running `433eaa9f7` (default provenance source `f35e93280`).
This is the first stateful service extraction permitted by the owner's revised
contract; it does not extract givens or activate solving.

## Boundary

Add `compiler/types/scopes.mdk`. An abstract ScopeStore owns frame allocation,
lookup, ancestry/visibility, and detached copying. GraphRun owns the store;
PerRun.currentScope remains inference-owned and resets per module. This moves an
invariant boundary without threading a context through infer.

Only the existing scope block, freshGraphRun, copyGraphRun, and scopeServiceProbe
touch scopeFrames/scopeCounter. Consumers read parent, module id, and owner.
Producers are module roots, props, tests, defaults, impl methods, and SCC members.
Visibility consumers are firstDictForEncl, firstPredForEncl, firstPredForEnclAt,
firstPredForEnclResidual, and anyGivenMatches. Memo snapshots copy scope storage
through copyGraphRun; resetGraphState starts a fresh namespace.

Keep gGiven and activeDictVars in typecheck: their payloads include GivenEntry,
PredicateSlot, and live Mono state. The future solver can import scopes and receive
an explicit store plus a separately owned given adapter without importing typecheck.

## Concrete API

The new module selectively imports only types.evidence's ScopeId/EvidenceBinderId
and types.repr's IfaceRef, besides the auto-prelude. It imports neither typecheck
nor solver_contract. Move these existing public data definitions unchanged:
DefaultBodyIdentity (full IfaceRef and method), ScopeOwner (including
DefaultBodyOwner), ScopeCursor, and ScopeFrame. Preserve their lack of Eq/Debug
derivings. Do not move or redefine identity types in evidence or repr.

```text
export data ScopeStore = ScopeStore {
  ssFrames: Ref (Array (Option ScopeFrame)), ssNext: Ref Int
}
freshScopeStore: Unit -> ScopeStore
copyScopeStore: ScopeStore -> ScopeStore
scopeFrame: ScopeStore -> ScopeId -> ScopeFrame
freshScope: ScopeStore -> Option ScopeId -> Int -> String -> ScopeOwner -> ScopeId
givenVisibleFrom: ScopeStore -> ScopeId -> ScopeId -> Bool
enclosingDefaultBody: ScopeStore -> ScopeId -> Option DefaultBodyIdentity
binderAt: ScopeId -> Int -> EvidenceBinderId
binderScope: EvidenceBinderId -> ScopeId
captureScopeCursor: ScopeCursor -> ScopeId
openScopeCursor: ScopeId -> ScopeCursor
closeScopeCursor: ScopeStore -> ScopeCursor -> ScopeCursor
scopeOwnerLabel: ScopeOwner -> String
scopeTraceContext: ScopeStore -> ScopeId -> (String, String)
scopeFrameStats: ScopeStore -> (Int, Int)
```

Export these functions; ScopeStore's constructor and fields remain abstract.
Do not invent binderOrdinal or an optional lookup solely for tests. Preserve
`panic "scope frame missing"` and current cursor panic strings. Initial capacity
is zero; growth stays `max 16 (2 * (i + 1))`, with the frame write before increment.
copyScopeStore creates fresh counter/storage Refs and arrayCopy; immutable frames
may be shared, mutable storage may not. Visibility remains ScopeId equality then
parent traversal. Default ancestry returns the first structural DefaultBodyOwner
with its full IfaceRef. Raw ScopeIds may repeat in independent stores: ids must
travel with their request's store.

## Integration and deletions

Replace GraphRun.scopeFrames/scopeCounter with scopeStore: ScopeStore.
freshGraphRun calls freshScopeStore; copyGraphRun calls copyScopeStore. Preserve
resetGraphState's EvId/EvCell handling and every memo save/restore/drain schedule.

Use selective imports for types/constructors plus `import types.scopes as Scopes`
for value calls. Add private allocation-free currentScopeStore. Migrate all
fresh/frame/visibility/binder/ancestry calls to qualified Scopes functions with an
explicit store where required. Keep captureScope/openScope/closeScope gateways
over PerRun.currentScope using cursor primitives. Do not move that cursor into
graph-lived storage.

Keep public typecheck scopeTraceContext/scopeFrameStats adapters for existing
observations. Keep renderEvidenceBinder in typecheck: dictParamName also synthesizes
AST parameters and owns ABI policy. BindingOwner and DefaultBodyOwner retain their
exact method stems. Labels remain observation only.

Delete the four moved data definitions, local scopeOrdinal, substantive frame
allocation/lookup/visibility/binder/owner-label/ancestry implementations, old
GraphRun fields and constructor/copy clauses, and scopeServiceProbe plus its
doctest. Keep defaultBodyRNoneServiceProbe and route its scope operations through
the service: it tests trace gates and renderer ABI. Keep DefaultBodyRNoneKind,
DefaultBodyRNoneTraceEntry, buffers, and resolver hooks in typecheck.

Amend TYPECHECK-DEFAULT-PROVENANCE.md in this slice: its original placement is now
superseded for identity/ancestry; the opt-in trace and hooks remain in typecheck.
The new GraphRun field replaces its two scope-storage fields; no trace payload is
added to replay state. Keep all matching, selection, routes, generalization, HM
levels, inference order, acceptance, and diagnostics unchanged.

## Tests and enrollment

Add compiler/types/scopes_test.mdk. Use projected local Eq/Debug views or booleans,
not whole-frame/owner equality requiring new production derivings.

1. Root/left/inner/right: id, parent, level, module, owner; inner sees left while
   sibling does not; same-spelled sibling binders differ within one store.
2. Copy after four frames. Allocate id4 independently in original and copy with
   distinct BindingOwner strings. Assert both ids are 4 and each store still has
   its own owner at id4. Shared counter yields id5; shared backing overwrites owner.
3. Fresh stores may each mint id0, but lookup returns each store's own module/owner.
4. A child inherits full default identity; unrelated module/sibling returns None;
   same iface/method spelling with distinct OriginModule remains distinct.
5. Cursor open/capture/close restores parent then closed; preserve panic behavior.

Keep production repeat/failure/cache frame counts and assumption/default traces
in typecheck_test. It currently needs no explicit DefaultBodyIdentity import;
any new annotation must import that type from scopes. Required mutations: shared
counter, shared array, owner-spelling visibility, name-only default ancestry.

Makefile's existing `./medaka test compiler/types` discovers the sibling in CI;
run it explicitly locally because preflight's path matching does not select a
child from that directory target. No Makefile or new gate is needed. Force-import
one scopes value in all_modules_entry. Add types.scopes to the two existing LEG-A
rosters (diff_compiler_selfproc.sh and capture_goldens.sh), with its module golden.
Create the scopes source snapshot via --new and named-bless typecheck. Entries
are excluded from this snapshot corpus; do not bless all_modules_entry. The test
file is excluded from compiler fingerprints and snapshots.

Run focused scopes/typecheck tests and derived preflight, including source
soundness, selfproc LEG A, snapshots, dictionary semantics, registry ratchet, and
compiler-source typecheck. Do not run the entire fixture-by-clang corpus locally.
Measure the existing playground/import-list N0–N3 cold/warm Cachegrind instructions
and allocated bytes against the immediately preceding source, with the same fixed
inputs and heap. Expect near-zero relocation cost; report against the 25% soft
budget. Preserve exact frame count/capacity lifecycle. Do not introduce rendered
keys, list maps, per-lookup allocation, or per-read frame copies.

Stop and report an import cycle, copy alias, frame lifecycle change, renderer
change, acceptance/diagnostic delta, or soft-budget breach. Completion covers
scope storage, immutable facts, ancestry/visibility, copy isolation, cursor
primitives, binder helpers, and nominal default identity only.
