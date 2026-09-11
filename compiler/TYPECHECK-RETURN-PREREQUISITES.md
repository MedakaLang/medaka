# Return-family migration prerequisites

Status: design review findings, **not an implementation packet**. Recorded after
the nominal scope slice `a4927caaf` and method-row preparation `ee61c0a35` on the
running rearchitecture branch. The owning completion contract remains
[TYPECHECK-CONTRACTS.md](TYPECHECK-CONTRACTS.md); the producer and consumer census
is in [TYPECHECK-SOLVER-MIGRATION.md](TYPECHECK-SOLVER-MIGRATION.md).

The full return family has not switched to the shared solver. The preparatory
rows do not yet constitute qualified-scheme production. Neither checking nor
return-route selection has been retired. An independent Sol review of the draft
found the prerequisites below; no activation is licensed by this document.

## Finalization and measurements

Re-derive #2646's quiescent numeric candidate/channel census on current source,
including core and module-prefix memo drains and same-process warm suffix edits.
The closed test/property fix does not finish graph defaulting. A prefix drain is
not whole-graph quiescence, and an externally constrainable variable cannot be
defaulted merely to store a prefix. Protect generalized variables, visible
dictionary channels, impl/method parameters, and instance-head channels under
DICT D1–D4; check every co-predicate after substitution.

Then re-take #2665's per-goal T4 census. The current tree result can carry final
drain failures outside the already-closed per-module verdict. A quiescent
Deferred outcome cannot be silently published as successful evidence. The
existing SC-3 owner decision or an accepted checked-artifact boundary must
resolve that condition before activation. Preserve warn-first policy meanwhile.

All three old memo reads and writes require bypass or replacement for migrated
request-owned evidence. PreludePreamble also carries request-local InstRef through
its impl environment. Measure the bypass before activation; the current scope
[performance results](TYPECHECK-SCOPE-PERFORMANCE.md) do not measure it. Frozen
summaries and lifecycle retention remain package-7 work.

Exact self-requiring and growing return-instance probes timed out on both the
starting revision and scope slice. No accepted fuel-truncation result was proved.
Declaration-only controls were accepted; a later use-site cycle/growth diagnostic
would not establish declaration-time DICT W2 conformance. Existing owners are
#1575 and #2120.

## Constraints to carry into the next concrete packet

* Primary return forwarding is role-dependent. Both a direct given and the
  preserved exact legacy-superclass assumption use the historical RDictFwd rung;
  method qualifiers and instance prerequisites use their own dictionary roles.
* Qualified instantiation needs an explicit supplied-primary destination plan
  to reuse an AST EvId while minting fresh tail destinations. The existing
  freshDestination service cannot express this by itself. Do not encode it as
  hidden first-call allocator state.
* Legacy instance proof edges, like semantic evidence, must be ordered EvIds in
  a DAG. A classified default has a destination and provenance but no fabricated
  Wanted. Publication ownership must include solved, insoluble, and classified
  default decisions so old cells cannot become a second authority.
* Collection marks and snapshots are not automatically solve points. Default
  givens are registered after body inference; impl requires givens arrive after
  method inference. Simplify only after the relevant unification, rigidity,
  defaulting, and direct-given registration. Retained parametric impl work must
  survive rollback before solving.
* A structural default-body owner must preserve historical binder rendering.
  A no-wanted legacy disposition must prove its qualifier tail empty or retain
  and solve that tail separately. The exact reachable-site census is still owed.
* Publish compatibility route refs only after transaction commit, or explicitly
  journal their prior values. A decision-table rollback alone cannot undo a
  mutation of numeric or method route refs.
* Generalized qualifier formals belong to the member's BindingOwner scope.
  Declaration method formals cannot substitute for them. Preserve #1082's
  exclusion of newly generalized local dictionary parameters.
* Select valid numeric evidence from resolved identity rows. Deleting the
  LegacyNumLiteralAnchor also requires preserving the measured malformed Flat
  DAttrib diagnostics; any retained adapter must be validation-only.
* RequestInstanceId is bounded by one ImplEnv generation. Flat rebuilds restart
  instance numbering, so facts and decisions cannot survive that reset.
* Structural map equality must be exact immutable identity; sameTyConHead's
  absent-origin compatibility is not an equivalence relation. Effect keys need
  terminating canonicalization of atoms, parameters, unbound tails, and joins.

Before implementation, the owning issue must receive the resulting concrete API,
deletion set, placement, and discriminating tests under contract §6. These findings
bound that design; they do not authorize a new language policy.
