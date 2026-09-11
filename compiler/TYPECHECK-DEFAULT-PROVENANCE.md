# Default-body identity and retained-route census

Owner: #2549 phase 2, coordinated with #993. This is a bounded prerequisite to the
return-family migration under TYPECHECK-CONTRACTS §§2, 4, 6. It changes ownership
representation and adds an opt-in observation; it does not activate solving,
classify retained initialization as valid semantic evidence, or complete #993.

## Measured current behavior

Generic defaults are structurally `DInterface -> IfaceMethod -> MethodDefault` at
inference. Their scopes currently retain only `BindingOwner methodName`. Argument
and return method stampers can return RNone and deliberately leave the marker's
RNone initialization untouched. They also preserve RLocal seeds, so “no new route”
alone cannot identify the default exception. Default method-level givens register
after body inference and before draining; direct qualifiers and superclass aliases
are separate outcomes within the same default body.

The true inherited return-default program below accepts and prints 41 under check,
interpretation and compiled native execution on both `2b6e08c8d` and method-row
`cd42e56f4`. A top-level constrained `copy` helper is not this probe.

```medaka
export default interface Supply a where
  seed : a
  copy : a
  copy = seed
```

A second module imports Supply/copy, supplies only seed=41 in `impl Supply Int`,
and evaluates `answer : Int; answer = copy`. Native typed-Core and Wasm module
probes also print 41 on `cd42e56f4`; Wasm emission, parsing, validation and Node
execution all succeed. The same-module specialized-copy control passes checking,
interpretation, typed-Core and native execution. Proper native probes replaced an
initial inconclusive attempt to interpret the compiler entry source itself.

A no-prelude mixed default with Rich/Other method qualifiers and a Base superclass
accepts and observes two direct givens plus one legacy superclass given. It also
calls a same-interface peer on its abstract receiver. That peer's retained RNone
must be observed separately from successful qualifier dispatch.

## Concrete API and placement

Keep these types/services in `compiler/types/typecheck.mdk`:

```text
DefaultBodyIdentity { dbiIface: IfaceRef, dbiMethod: String }
ScopeOwner += DefaultBodyOwner DefaultBodyIdentity
DefaultBodyRNoneKind = DBRKArg | DBRKReturn
DefaultBodyRNoneTraceEntry {
  dbrOwner: DefaultBodyIdentity, dbrCallee: String,
  dbrKind: DefaultBodyRNoneKind, dbrOrigin: Option Loc, dbrScope: ScopeId
}
beginDefaultBodyRNoneTrace : Unit -> Unit
finishDefaultBodyRNoneTrace : Unit -> List DefaultBodyRNoneTraceEntry
```

The identity and trace data are immutable public exports for compiler sibling
tests. ScopeId is request-local and compared only within a request. Deliberately
omit EvId: PendingEntry's fresh route-goal id is not the AST EMethodAt destination.
This observer must not suggest otherwise or mint another evidence identity.

`inferOneIfaceDefaults` captures its declaration's full IfaceRef, including origin.
Thread IfaceRef through `inferDefaultMethods` and `inferDefaultMethod`, replacing
their String-only interface argument. Each actual MethodDefault constructs its
own DefaultBodyIdentity from that IfaceRef and method name, then opens its body
scope with DefaultBodyOwner. Project irName only into existing display/default
subject helpers. Never recover identity by matching the method's spelling.

`renderEvidenceBinder` handles DefaultBodyOwner by applying the existing
dictParamName to dbiMethod and ordinal. The resulting ABI names are unchanged.
`scopeOwnerLabel` gains an explicit default label for observation; the label is
never an identity or visibility key. Explicit and synthesized ImplMethod bodies
retain BindingOwner.

Private `enclosingDefaultBody` follows parent ScopeIds. Private
`noteDefaultBodyRNone` returns immediately when tracing is disabled, before any
ancestry lookup or trace allocation. Record only if the computed entail route is
RNone, the existing route cell was itself RNone before calling entail, and the captured
scope has a DefaultBodyOwner ancestor. Capture the prior tag before entail. Both `resolveSite` and `resolveArgStamp`
call this helper in their existing RNone branch; thread the PendingEntry location
explicitly through their adapters. Preserve all current writes and order.

Begin clears/enables a dedicated trace buffer outside replayed inference state;
finish disables, returns entries in occurrence order, and clears it. This is an
append-only opt-in trace, never a lookup table or solver input. A cache hit may
perform no new fallback and therefore produce no entries; it is not evidence loss.

## Deletions and strict limits

Delete only the generic-default path's BindingOwner construction and String-only
interface argument in the two default inference helpers. Add no new field to
PendingEntry, Obligation, EvCell, GraphRun, MethodSchemeRow, or qualified schemes.
There is no route/checker/backend deletion or new semantic evidence publication.

Keep argument and return observations distinct. Ord's inner compare is an
argument site; it cannot justify a return-family compatibility exception. Only
DBRKReturn sites enter the eventual return migration's exception census. Eval
narrowing, LLVM/Wasm default restamping and #993's other work remain unchanged.

## Tests and verification

Extend the existing compiler sibling test and existing module-fixture vehicles:

1. Mixed default: one same-interface abstract argument peer is DBRKArg retained
   RNone; successful Rich/Other qualifier calls are excluded. Assert direct binder
   ordinals 0 and 1 plus superclass alias ordinal 0, all owned by the actual default.
2. Genuine Supply.copy MethodDefault observes DBRKReturn for seed, with the
   Supply/copy owner and a parser location where supplied. Preserve its inherited
   cross-module execution at 41; no top-level-helper substitute.
3. Explicit impl and same-module synthesized-copy controls have ordinary impl
   ownership and produce no generic-default trace. Same-spelled methods in another
   interface cannot borrow the first interface's owner. Include two identical
   interface/method spellings with different module origins, and a local helper
   inheriting its default body's scope (plus ancestry behavior for child scopes).
4. RLocal and concrete RKey controls produce no retained-RNone trace; preserve
   historical dictionary rendering and qualifier order.
5. Existing foldMap list/string/Bag, prelude_default_parametric_requires, inherited
   argument defaults, source soundness, snapshots, and focused module engines.
   Use correctly built native probes; setup failures do not become semantic verdicts.
6. Mutation checks remove the scope-origin discriminator, admit RLocal, conflate
   Arg/Return, or alter default binder rendering; the appropriate assertion must
   fail. Preserve source freshness and restore isolated mutation trees.

Stop if a required accepted control fails on the baseline, if generic-default
provenance cannot be captured directly, or if this requires changing any route or
verdict. Record the existing defect separately; do not broaden this slice to fix it.
