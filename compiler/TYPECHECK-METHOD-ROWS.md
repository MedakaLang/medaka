## Method declaration rows: preparation for the return-family migration

Owner: #2549 phase 2 / #1122, after nominal assumption ownership. This is a behavior-preserving declaration-data change; the complete return-family switch still owes one outcome for checking and evidence and its full deletion ledger. This slice does not call `instantiateQualified`, emit new wanteds or add a solver judgment.

Today a second declaration walk obtains method identities, then a positional zip pairs them with freshly built schemes. A single row from the existing scheme-building walk can own those associations and expose the old views. Numeric literal inference also stores its scheme and declaration metadata in separate refs; one explicitly legacy anchor will hold their existing pair atomically, preserving the measured attributed-declaration error path.

### API and placement

Private declarations in `compiler/types/typecheck.mdk`:

```text
MethodSchemeRow {
  msrIface : IfaceRef,
  msrName : String,
  msrScheme : Scheme,
  msrMethodSlots : List MethodPredicateSlot
}
LegacyNumLiteralAnchor {
  lnlaScheme : Scheme,
  lnlaParams : Option (IfaceRef, List String, Ty, List (String, List Kind))
}
methodSchemeRows : List (String, List Kind) -> IfaceRef -> List String
                   -> List IfaceMethod -> List MethodSchemeRow
ifaceMethodRows : List Decl -> List MethodSchemeRow
legacyMethodSchemes : List MethodSchemeRow -> List (String, Scheme)
installMethodPredicateSlots : String -> List MethodPredicateSlot -> Unit
seedNumLitFromIntAnchor : List MethodSchemeRow -> List Decl -> Unit
pickSchemesByDecl : List String -> List (String, Scheme)
                    -> List MethodSchemeRow -> List (String, Scheme)
admittedSchemeFor : String -> List MethodSchemeRow -> Option Scheme
lookupSchemeById : IfaceRef -> String -> List MethodSchemeRow -> Option Scheme
```

For each method, call `sigToSchemeTvsIn scope mty` exactly once at the old construction point. Build method predicate slots from that call's type-variable map and scheme ids. `installMethodPredicateSlots` installs those precomputed slots through the existing first-write/empty/dedup guards. Keep the slots in the row and project name/scheme pairs from it. Do not recompute slots during projection or move their registration later.

No new interface-vector or unused declaration-metadata fields are retained in this preparation. The later return producer must add its full vector at this same construction point, with explicit handling of phantom/row-kinded parameters; it cannot rematch a declaration or perform a second fresh-variable build. No formal evidence-binder scope is invented here.

### Wiring and compatibility

At `checkBodyImpl`, bind `currentMethodRows = ifaceMethodRows prog` where the current method schemes are built. Project `globalS` from those rows at the same point. Preserve the Flat arm's existing second method-scheme construction used for `methodNames`: it has an observable fresh-id allocation schedule and registration side effects. Removing that build is outside this slice.

The Module arm builds `visibleMethodRows = ifaceMethodRows implDecls` at the existing `ifaceSchemes` construction point. Keep these rows local and pass them directly to `pickSchemesByDecl` and the Num seeder. Delete `ifaceMethodSchemesByIdRef` with no replacement `PerRun` field: its only reader is the immediate setup call, so graph-lived full rows would retain unused declaration/type metadata in every `StampCtx`. `admittedSchemeFor` and `lookupSchemeById` project `msrScheme` using their existing `sameTyConHead` comparison. The Num seeder separately preserves `sameIfaceDecl`. These are two distinct comparison policies; do not merge them. No fallback or resolution rule changes.

Replace `numLitFromIntSchemeRef` and `numLitFromIntParamsRef` with `numLitFromIntAnchorRef : Ref (Option LegacyNumLiteralAnchor)`. The single seeder selects `(builtinIfaceRef BNum, "fromInt")` from the rows using `sameIfaceDecl`, and obtains optional params through the unchanged legacy declaration walk. Store an anchor only if the scheme is present. Literal inference reads its scheme; the obligation recorder reads its optional params and preserves the existing absent-params branch. Preserve all literal suppression/defaulting rules. This consolidates state ownership; it does not yet unify numeric scheme and parameter declaration identity.

The row walk mirrors the old scheme walk arm-for-arm, including its `DInterface`-only behavior and declaration/method order. An attributed-only interface produces no scheme row and cannot activate literal method inference. Preserve that boundary, the params walk's `DAttrib` unwrapping, and the separate unwrapping behavior of `registerMethodIfaceParamsAll`.

The cross-pair is reproduced on strict-fresh running head `5f90e7a75522238f8dd3c959a33368900e09f99c` (also reproduced at base `2b6e08c8d`) through the public prelude-free `compiler/entries/typecheck_main.mdk` Flat entry. With attributed `Num a / fromInt : Int -> a`, direct `Num a b / fromInt : String -> a`, and `main = 1`, attribute-first prints both `String vs Int` and `Int literal vs Int` errors; direct-first prints only `String vs Int`. Repeats are identical. Exact-head receipts are `/tmp/rearch-method-row-probes/5f90e7a_*.log`. The probe exits 0 while printing `TYPE ERROR:` lines; normal CLI checking rejects the mixed input at resolve and does not expose this order difference. Preserve this existing error-path behavior in the legacy anchor instead of silently changing diagnostics during preparation. Replacing its params walk remains part of the return-family migration.

These rows contain live scheme/type cells and remain local to setup. Only the selected legacy Num anchor outlives setup because literal bodies read it. Its scheme remains subject to the existing mutable memo limitations; it is not a frozen summary or published evidence. Preserve cross-module method-slot append/snapshot order. Measure the allocation effect on the same LSP cold/warm workloads.

### Deletions

- `ifaceMethodSchemeIds`, `declIfaceMethodIds`, `ifaceMethodIdRow`, `zipIfaceMethodSchemeIds` and all positional-zip calls.
- The superseded builders `ifaceMethodSchemes`, `declIfaceMethods` and `methodSchemes`: both existing construction invocations use `ifaceMethodRows` and its projection. Preserving the Flat second invocation does not license retaining a second implementation of the builder.
- The old `ifaceMethodSchemesByIdRef` field and constructor/copy entries, with no replacement graph-lived row field.
- Both numeric scheme/params refs and their separate seed entry points: `seedNumLitFromIntScheme`, `seedNumLitFromIntParams`. Replace the old pair-table scheme picker with a row picker using the same strict comparison. Retain `numLitFromIntParamsOf`, `numLitFromIntParamsDecl`, and `pickIfaceMethodParams` as the explicit legacy params walk.
- `registerMethodConstraints`, replaced by `installMethodPredicateSlots`: only the row builder computes slots; the installer receives them at the same old registration point.

Retain `methodSchemesPure` for default bodies, the Flat second build, `registerMethodIfaceParamsAll`/`methodIfaceParamsRef`, `ifaceParamMonos`, and every occurrence recorder, checker, selector and stamper. Their eventual return-family replacements remain owned by the parent design.

### Verification

Extend the subject's `compiler/types/typecheck_test.mdk`, already included by `make test`'s `compiler/types` directory target. A narrow exported test observer returns immutable identity/alias observations from private rows while saving/restoring compiler state; it does not export mutable rows or graph state. Its concrete API is specified below before implementation.

- A method with independent constraints, using the `foldMap : Monoid m => (a -> m) -> t a -> m` shape, must have predicate-slot positions and live cells aligned with its own HM scheme. Assert identity/cell correspondence, not just equal pretty-printed types. Computing slots from a second `sigToSchemeTvsIn` call must fail this test.
- Two interfaces with the same method spelling retain their own identity/scheme/slot associations in both declaration orders. Include a differing method count so a dropped row cannot pass a count-only or zip-truncation check.
- Build the same quantified method twice: the second scheme has distinct fresh ids and advances the type-variable counter, while the first-write method-slot registry still points to the first build. This directly pins the deliberately retained Flat schedule. Also assert a nullary/non-function method row (the `Monoid.empty`/constant-method shape) survives even with no method slots.
- A builtin `Num.fromInt` row and a user interface's `fromInt` row in both orders must select the builtin scheme and preserve the old metadata selection. Spelling-only selection must fail. Attributed/direct malformed cases separately pin the intentional legacy cross-pair.
- Assert an attributed-only interface contributes zero rows while `registerMethodIfaceParamsAll` retains its existing unwrapping behavior. Include malformed direct/attributed duplicates in the diagnostic control; do not assume their old cross-pairing is unreachable. No new rejection is licensed.

Retain end-to-end `method_constraint_foldmap_{list,string}`, numeric default/polymorphic/Float fixtures, SHADOW X9/X10, and Flat/Module agreement. Use the existing dictionary, shadow and snapshot gates; run source soundness and self-hosting checks for the compiler change. Compare LSP cold/warm instruction counts against the predecessor slice using the same fixed request streams and the existing approximately 25% soft instruction-count budget. Report before/after allocation on those same streams; no new numeric allocation ceiling is introduced. Existing instruments do not provide matched retained-live-heap measurements, so keep that package-7 instrumentation debt explicit and do not substitute peak RSS or frame counts. No new gate script is required.

Stop on any acceptance, diagnostics, route/evidence, generalization, instance-selection or fresh-variable-allocation-order change; any second scheme build supplying a row's slots; or any use of the new row as a second solver authority. Keep a deliberately preserved construction explicit rather than deleting it on intuition.

### Immutable sibling-test observer

Export these observations from the subject module, using the normal public record syntax:

```text
NumAnchorTestObservation {
  natoCase : String,
  natoHasScheme : Bool,
  natoHasParams : Bool,
  natoSchemeBody : String,
  natoParamType : String
}
MethodRowTestObservation {
  mrtoSchemeIds : List Int,
  mrtoSlotBoundIds : List (List Int),
  mrtoSlotPositions : List (List Int),
  mrtoSlotIdsAtPositions : List (List Int),
  mrtoSlotArgumentIds : List (List Int),
  mrtoCounterBefore : Int,
  mrtoCounterAfterFirst : Int,
  mrtoCounterAfterSecond : Int,
  mrtoFirstSchemeIds : List Int,
  mrtoSecondSchemeIds : List Int,
  mrtoFirstRowSlotIds : List (List Int),
  mrtoSecondRowSlotIds : List (List Int),
  mrtoRegistryAfterSecondSlotIds : List (List Int),
  mrtoSameNameForward : List (String, String, Int, Int),
  mrtoSameNameReverse : List (String, String, Int, Int),
  mrtoConstantRowCount : Int,
  mrtoConstantSchemeIdCount : Int,
  mrtoConstantBodyIsFunction : Bool,
  mrtoConstantSlotCount : Int,
  mrtoAttributedRowCount : Int,
  mrtoAttributedParamIface : String,
  mrtoAttributedParamTyparams : List String,
  mrtoNumAnchors : List NumAnchorTestObservation
}
observeMethodSchemeRowsForTest : Unit -> MethodRowTestObservation
```

The observer constructs fixed private test declarations. Save the exact `CrossRun`, `GraphRun`, and `PerRun` objects; install fresh state, including `freshCrossRun initialEnv`; copy observations to immutable values; restore all three objects. No `Mono`, `Ref`, row, or compiler-state object escapes. Each independent numeric case starts with all three states fresh. This matters because numeric selection reads `builtinClassesRef` from `CrossRun`.

For the constrained-method test, recursively collect argument-variable ids from `PSArgsKnown`. Assert the slot bound ids, the scheme ids selected at the slot positions, and the slot argument ids agree and refer to that row's scheme. The second construction must advance the counter and produce distinct scheme ids; its slots must follow its own scheme while the first-write registry remains associated with the first construction.

The same-name tuple is `(originTag, methodName, schemeIdCount, slotCount)`. Give the same-spelled methods themselves different shapes: `A.same : Int -> Int` and `B.same : D a => a -> a`, plus differing method counts. Assert complete identity-associated rows in both orders, so swapping same-named rows cannot pass merely because another method differs. Use `token : Int` for the constant row and assert one row, zero quantified ids, a non-function body and zero slots.

Numeric cases are `attrOnly`, `directOnly`, `attrThenDirect`, `directThenAttr`, `builtinThenUser`, and `userThenBuiltin`. The attributed/direct cases seed builtin identity through `builtinClassesOf` on the actual Flat declaration list, as production does. The builtin/user permutation cases seed from the designated builtin declaration alone before selecting from the combined rows: otherwise the test changes which declaration production regards as builtin instead of testing selection. Copy scheme bodies using `ppMono` on the `Forall` body and parameter types using `ppTy`; absent values have empty strings and explicit presence booleans. Pin the measured mixed-declaration diagnostics with the existing public Flat entry as well as these internal observations.

### Construction-schedule source guard

Extend the existing source assertions in `test/typecheck_compiler_source.sh`; do not add a new gate script. Require exactly two production occurrences of `ifaceMethodRows prog` (initial setup and the preserved Flat second build), and exactly one `ifaceMethodRows implDecls` (Module setup). Update the existing required `registerMethodConstraints` assertion to `installMethodPredicateSlots` and reject the deleted builder/zip/ref names above. A unit test that manually constructs rows twice cannot detect removal of the actual second production call, so this narrow source guard complements the identity tests. It protects the explicit construction schedule, not a general runtime equivalence claim.
