# META
source_lines=1653
stages=DESUGAR,MARK
# SOURCE
import backend.wasm_demand.{validateWasmDemand}
-- Checks a lowered program must pass before an emitter writes any of it.  Each
-- check reads only the `CProgram` the emitter received and the extern catalog,
-- so every build entry reports a refusal from one place, and before either
-- emitter has produced text.
--
-- The record check: every record node carries each field's declared ordinal,
-- stamped by `core_ir_lower`, and an emitter stores and loads by it.  A node
-- with an unstamped (negative) ordinal, a record literal whose ordinals are not
-- its positions, or an update whose ordinals are not strictly ascending is
-- refused: the emitters keep no field-order table to fall back on.
--
-- The call check: every application carries the mode its head's defined arity
-- gives it (`core_ir_lower.definedArityOf`, the helper the lowering's stamp
-- reads).  A known head's defined arity is the pattern count of the clause it
-- names (a top-level or let-group binding, the entry an `RKey` route selects,
-- the binding an `RLocal` route or a `CDict` names, less the dictionaries the
-- occurrence supplies) or a constructor's field count; any other head is
-- dynamic.  An application with no arguments, or whose head is itself an
-- application, is refused too: a spine is one node.  So are impl entries of
-- one method and route word that take different value arities: they are the
-- clauses of one define.
--
-- The method-context check: an interface method takes one dictionary per slot of
-- its declared `=>` context (the program's method-context table, which lowering
-- reads off the signature; a method the table has no row for declares none).  A
-- `CMethod` occurrence of it supplies exactly that many method routes; an impl
-- entry for it opens with that many `$dict_<method>_<k>` parameters, k counting
-- from 0 (a supplied method follows them with all of its instance's `requires`
-- dictionaries or none, as the declaration facts count them; an inherited default
-- takes exactly one more, its receiver).  The emitters size a call by the routes
-- and an entry by its patterns, so the two must agree with the declaration, not
-- only with each other.
--
-- The dispatch-evidence check: a `CMethod` or `CDict` occurrence must denote
-- dictionaries its callee binds.  Every given dictionary a route names is bound
-- where the occurrence sits; a projection reads a given; a head instance key has
-- an impl entry; a `CDict` of a top-level function supplies exactly the leading
-- `$dict` parameters that function takes, none of them `RNone`; no route is a
-- scalar tag; a dictionary built at the site from an instance carries exactly as
-- many super and prerequisite dictionaries as the program's declaration facts
-- give; and an occurrence answered by a dictionary names its interface.  A head
-- instance is not held to its supers, which ride along only when the selected
-- entry needs a receiver, nor to its prerequisites, which dict-passing drops from
-- an entry whose body does not read them.  This reads routes and facts as
-- `core_ir_lower` published them on the emit path, so it runs there only: the
-- default sexp printer drops an `RKey`'s prerequisite and super routes, so a
-- program parsed back from a dump would be refused.
--
-- The binder-stamp check: every binder pattern in the program (a `PVar`, a `PAs`,
-- a record-pattern pun) has a row in the program's binder table
-- (`DeclFacts.factBinders`), so it says what it holds at run time.  A `let` of a
-- literal, a tuple, a list or a constructor is held to what its own right-hand
-- side is: a binder stamped as another scalar than the literal's, or as a scalar
-- where a cell is bound, is refused.  `RTValue` is the answer "no static fact" and
-- contradicts nothing; an integer literal may be stamped as any numeric type,
-- because it is written the same at each.  Every named function (a `CBind`) has
-- a row too, and the row gives the type its body returns.
--
-- The scalar-binop check: a non-empty `CBinPrim` scalar tag is a positive fact
-- from typecheck, so its operator must be one that can consume that tag. Arithmetic
-- accepts the primitive numeric heads; comparison accepts exactly the tags its
-- route stamper publishes. Other operators and unknown tags are refused before an
-- emitter can reinterpret the string.
--
-- The extern check: a runtime extern whose catalog row gives the backend no
-- lowering (`NotProvided`) is refused wherever the program references it
-- freely.  A reference is free when no local binder in scope and no top-level
-- binding or constructor of the program has the extern's name; those names
-- shadow the extern in both emitters' application ladders, so the emitter
-- would not lower the extern there.  The program checked is the one the
-- emitter received, after any reachability filter its entry ran.

import ir.extern_types.{ExternDeclFact(..), ExternUse(..)}
import ir.extern_uses.{collectExternUses}
import ir.extern_lower.{externRuntimeKey}
import ir.core_ir.{
  CExpr(..),
  CField(..),
  CArm(..),
  CGuard(..),
  CStmt(..),
  CBind(..),
  CClause(..),
  CImplEntry(..),
  CImplBody(..),
  ImplSym(..),
  MethodEvidence(..),
  CProgram(..),
  DeclFacts(..),
  MethodResultFact(..),
  CallMode(..),
  CallSite(..),
  noDeclFacts,
  givenNames,
  mapProgramBinders,
  BinderSite(..),
  litRuntimeType,
}
import types.runtime_types.{
  BinderRow(..),
  RuntimeType(..),
  binderOrdinal,
  runtimeTypeName,
}
import map as BM
import ir.core_ir_lower.{
  ArityEnv,
  CallScope,
  bindGroupScope,
  bindLetScope,
  bindPatScope,
  bindPatsScope,
  callModeFor,
  definedArityOf,
  entryArityRow,
  programArities,
  ifaceMethodArityKey,
  ifaceWordOfKey,
  leadingDictParams,
}
import ir.core_ir_sexp.{callModeSexp}
import frontend.ast.{
  Pat(..), Route(..), Decl(..), ExternDecl(..), Ty(..), Lit(..), BinderId(..),
  isFixedIntHead, isBoxed64Head
}
import types.target_profile.{TargetProfile, withheldLabels, profileName}
import backend.extern_requirements.{
  validateExternRequirements, requirementHostRows
}
import backend.global_plan.{validateGlobalInit}
import backend.emit_target.{Backend(..), backendName}
import backend.emit_plan.{EmitPlan, indexMethodResults, lookupMethodResult}
import backend.extern_catalog.{
  RuntimeExternDomain(..),
  Disposition(..),
  GapKind(..),
  catalogRow,
  gapKindName,
  rowLlvm,
  rowWasm,
  rowEval,
}
import support.ordmap.{
  OrdMap,
  omEmpty,
  omFromPairs,
  omInsert,
  omHasKey,
  omLookup,
  omKeys,
}
import types.private_mangle.{dictTag, hashName}
import support.util.{dedupBy, isNonEmptyL, joinWith, listLen, reverseL}

-- A free reference to a runtime extern the backend does not lower: the extern,
-- the backend, the row's gap kind and reason, and the top-level binding the
-- first reference sits in.
public export data ExternFinding =
  ExternFinding String Backend GapKind String String

-- Defects are fatal in every emission mode; target extern findings may instead
-- be recorded. The first failing validation family keeps its original order.
public export data CoreDefect = CoreDefect String

public export data EmissionValidation = EmissionValidation {
  defects : List CoreDefect,
  externFindings : List ExternFinding,
}

export
coreDefectMessage : CoreDefect -> String
coreDefectMessage (CoreDefect message) = message

export
validateForEmission : Backend ->
  RuntimeExternDomain ->
  EmitPlan ->
  CProgram ->
  EmissionValidation
validateForEmission backend domain plan cp =
  match emissionDefects backend domain plan cp
    [] =>
      let names = match domain
        PreludeFreeRuntime => []
        LoadedRuntimeExterns decls => map (d => d.edName) decls
      match missingCatalogRows names
        [] => EmissionValidation {
          defects = [],
          externFindings = validateExterns backend [] cp,
        }
        missing => EmissionValidation {
          defects = [CoreDefect (missingRowsMessage missing)],
          externFindings = [],
        }
    bad => EmissionValidation { defects = bad, externFindings = [] }

emissionDefects : Backend ->
  RuntimeExternDomain ->
  EmitPlan ->
  CProgram ->
  List CoreDefect
emissionDefects backend domain plan cp =
  if backendName plan.target /= backendName backend then
    [
      CoreDefect
        "internal error: emit plan was built for the \{backendName plan.target} backend but the \{backendName backend} emitter received it",
    ]
  else match implSymbolCollision cp
    Some message => [CoreDefect message]
    None => match dictTagCollision backend cp
      Some message => [CoreDefect message]
      None => firstShapeDefect [
        () => validateExternMetadata cp,
        () =>
          validateExternRequirements backend domain cp plan.externRequirements,
        () => validateRequirementProjection backend plan,
        () => validateGlobalInit cp plan.lazyGlobals plan.globalInit,
        () => validatePhysicalDemand backend plan cp,
        () => validateRecords cp,
        () => validateBinderStamps cp,
        () =>
          validateScalarOperators cp
            ++ validateCalls cp
            ++ validateImplSymbols cp
            ++ validateMethodContexts cp
            ++ validateDispatchEvidence cp
            ++ validateMethodResults plan cp,
        () => validateTails cp,
      ]

firstShapeDefect : List (Unit -> List String) -> List CoreDefect
firstShapeDefect [] = []
firstShapeDefect (check :: rest) = match check ()
  [] => firstShapeDefect rest
  bad => [CoreDefect ("internal error: " ++ joinWith "\n" bad)]

validateRequirementProjection : Backend -> EmitPlan -> List String
validateRequirementProjection WasmBackend plan =
  if map
      (imp => (imp.medakaName, (imp.jsName, (imp.params, imp.result))))
      plan.jsImports
    == requirementHostRows plan.externRequirements then
    []
  else
    ["extern-import-mismatch"]
validateRequirementProjection _ _ = []

validateExternMetadata : CProgram -> List String
validateExternMetadata (cp@(CProgram _ _ _ _ _ facts)) =
  flatMap
    (use => match omLookup use.useSymbol facts.factExterns
      None => ["unknown-extern-declaration: " ++ use.useSymbol]
      Some fact => match fact.callableShape
        None => ["missing-extern-abi: " ++ fact.symbol]
        Some _ => [])
    (collectExternUses cp)

export
findingExtern : ExternFinding -> String
findingExtern (ExternFinding name _ _ _ _) = name

export
findingBinding : ExternFinding -> String
findingBinding (ExternFinding _ _ _ _ binding) = binding

-- The gap kind and reason when `backend` does not lower runtime extern `name`,
-- or `None` for an extern it lowers and for a name that is not a runtime extern.
export
unprovidedOn : Backend -> String -> Option (GapKind, String)
unprovidedOn LlvmBackend name = match catalogRow name
  Some r => notProvidedOf (rowLlvm r)
  None => None
unprovidedOn WasmBackend name = match catalogRow name
  Some r => notProvidedOf (rowWasm r)
  None => None
unprovidedOn EvalBackend name = match catalogRow name
  Some r => notProvidedOf (rowEval r)
  None => None

notProvidedOf : Disposition f -> Option (GapKind, String)
notProvidedOf (NotProvided kind why) = Some (kind, why)
notProvidedOf _ = None

export
isUnprovidedOn : Backend -> String -> Bool
isUnprovidedOn backend name = isSome (unprovidedOn backend name)

-- Every free reference to a runtime extern `backend` does not lower, one
-- finding per distinct extern, in the order of first reference.  The target
-- check refuses every built-in a program reaches that is `NotProvided` on the
-- profile's column (`profileColumn`), so a finding for a program that check
-- admitted under that profile is a compiler bug.
-- `runtimeExterns` names the externs the entry declared from
-- `stdlib/runtime.mdk`; a name among them with no catalog row is an internal
-- error, raised before the program is read.
export
validateExterns : Backend -> List String -> CProgram -> List ExternFinding
validateExterns backend runtimeExterns prog =
  let _ = refuseMissingRows runtimeExterns
  match walkProgram backend prog
    Walk _ found _ _ _ _ _ _ => reverseL found

-- One line per record node whose ordinals the emitters cannot trust, in
-- program order; empty for a well-stamped program.
export
validateRecords : CProgram -> List String
validateRecords prog = match walkProgram LlvmBackend prog
  Walk _ _ bad _ _ _ _ _ => reverseL bad

export
renderRecordRefusal : List String -> String
renderRecordRefusal bad = joinWith "\n" bad

-- One line per application whose mode its head's defined arity contradicts, in
-- program order; empty for a well-stamped program.
export
validateCalls : CProgram -> List String
validateCalls (prog@(CProgram _ _ _ impls _ _)) =
  match walkProgram LlvmBackend prog
    Walk _ _ _ _ bad _ _ _ => reverseL bad ++ splitGroupFaults impls omEmpty []

-- One line per `CBinPrim` whose non-empty scalar tag is not licensed for its
-- operator, in program order. An empty tag makes no scalar claim.
export
validateScalarOperators : CProgram -> List String
validateScalarOperators prog = match walkProgram LlvmBackend prog
  Walk _ _ _ bad _ _ _ _ => reverseL bad

-- The entries of one method and route word are the clauses of one define, which
-- takes one parameter count, so an entry whose value arity differs from the
-- first entry of its group is refused.
splitGroupFaults : List CImplEntry -> OrdMap Int -> List String -> List String
splitGroupFaults [] _ acc = reverseL acc
splitGroupFaults ((ent@(CImplEntry method _ _ body)) :: rest) seen acc =
  let (key, n) = entryArityRow ent
  match omLookup key seen
    Some k =>
      if k == n then
        splitGroupFaults rest seen acc
      else
        splitGroupFaults
          rest
          seen
          ("call: impl entry takes \{intToString n} value parameters, the first entry of its group \{intToString k} [in impl \{method}@\{implBodyTag body}]"
            :: acc)
    None => splitGroupFaults rest (omInsert key n seen) acc

-- Signature facts are complete for every emitted method and preserve the plan's
-- qualified keys. Callback positions are strictly increasing value positions.
export
validateMethodResults : EmitPlan -> CProgram -> List String
validateMethodResults plan (prog@(CProgram _ _ _ impls _ facts)) =
  let index = indexMethodResults facts.factMethodResults
  let rowsBad = methodResultRows facts.factMethodResults omEmpty []
  let keys idx =
    flatMap
      (iface =>
        map
          (m => ifaceMethodArityKey iface m)
          (omKeys (optionOr omEmpty (omLookup iface idx))))
      (omKeys idx)
  let planBad =
    if keys index == keys plan.methodResults
      && all
        (methodResultMatches plan.methodResults)
        facts.factMethodResults then
      []
    else
      ["method result: emit plan index disagrees with declaration facts"]
  let refsBad = match walkProgram LlvmBackend prog
    Walk _ _ _ _ _ _ _ bad => reverseL bad
  rowsBad ++ planBad ++ refsBad ++ flatMap (entryMethodResult index) impls

methodResultMatches : OrdMap (OrdMap MethodResultFact) ->
  MethodResultFact ->
  Bool
methodResultMatches index row =
  lookupMethodResult index row.iface row.method == Some row

methodResultRows : List MethodResultFact ->
  OrdMap (OrdMap Unit) ->
  List String ->
  List String
methodResultRows [] _ bad = reverseL bad
methodResultRows (row :: rest) seen bad =
  let methods = optionOr omEmpty (omLookup row.iface seen)
  let why =
    if row.iface == "" || row.method == "" then
      "empty interface or method key"
    else if omHasKey row.method methods then
      "duplicate qualified key"
    else if row.valueArity < 0 then
      "negative value arity"
    else if not
      (callbackPositionsValid row.valueArity (-1) row.callbackPositions) then
      "invalid callback position"
    else
      ""
  methodResultRows rest (omInsert
    row.iface
    (omInsert row.method () methods)
    seen) (if why == "" then
    bad
  else
    "method result: \{why} [\{row.iface}#\{row.method}]" :: bad)

callbackPositionsValid : Int -> Int -> List Int -> Bool
callbackPositionsValid _ _ [] = True
callbackPositionsValid arity prev (n :: ns) =
  n > prev && n < arity && callbackPositionsValid arity n ns

entryMethodResult : OrdMap (OrdMap MethodResultFact) ->
  CImplEntry ->
  List String
entryMethodResult index (CImplEntry method _ declared (CImplTagged _ _ iface _ _ _ _)) =
  entryMethodResultFact index iface method declared
entryMethodResult index (CImplEntry method _ declared (CImplDefault iface _ _ _ _ _ _)) =
  entryMethodResultFact index iface method declared

entryMethodResultFact : OrdMap (OrdMap MethodResultFact) ->
  String ->
  String ->
  Int ->
  List String
entryMethodResultFact index iface method declared =
  match lookupMethodResult index iface method
    Some row =>
      if row.valueArity == declared then
        []
      else
        [
          "method result: fact value arity \{intToString row.valueArity} disagrees with Core impl entry declared value arity \{intToString declared} [\{iface}#\{method}]",
        ]
    None => ["method result: missing declaration fact [\{iface}#\{method}]"]

missingMethodResult : OrdMap (OrdMap MethodResultFact) ->
  String ->
  String ->
  List String
missingMethodResult index iface method =
  match lookupMethodResult index iface method
    Some _ => []
    None => ["method result: missing declaration fact [\{iface}#\{method}]"]

noteMethodResult : Ctx -> String -> String -> Walk -> Walk
noteMethodResult _ _ "" w = w
noteMethodResult (Ctx _ _ _ _ _ facts _) method iface (Walk seen found bad scalar calls ctxs evs results) =
  Walk
    seen
    found
    bad
    scalar
    calls
    ctxs
    evs
    (missingMethodResult facts.efMethods iface method ++ results)

-- One line per method occurrence or impl entry whose dictionaries disagree with
-- the method's declared context (see the header), in program order.
export
validateMethodContexts : CProgram -> List String
validateMethodContexts (prog@(CProgram _ _ _ impls mctx facts)) =
  match walkProgram LlvmBackend prog
    Walk _ _ _ _ _ bad _ _ =>
      reverseL bad
        ++ flatMap
          (entryContextFaults
            (omFromPairs mctx omEmpty)
            (omFromPairs facts.factRequires omEmpty))
          impls

entryContextFaults : OrdMap Int -> OrdMap Int -> CImplEntry -> List String
entryContextFaults table reqs (CImplEntry method _ _ (CImplTagged tag key iface _ _ pats _)) =
  let k = declaredMethodContext table iface method
  let r = optionOr 0 (omLookup key reqs)
  let n = leadingMethodDicts method 0 pats
  if n == k || n == k + r then
    []
  else
    [
      "method context: impl entry opens with \{intToString n} `$dict_\{method}_k` parameters, `\{iface}` declares \{intToString k} and its instance requires \{intToString r} [in impl \{method}@\{tag}]",
    ]
entryContextFaults table _ (CImplEntry method _ _ (CImplDefault iface tag _ _ _ pats _)) =
  let k = declaredMethodContext table iface method
  let n = leadingMethodDicts method 0 pats
  if n == k + 1 then
    []
  else
    [
      "method context: default entry opens with \{intToString n} `$dict_\{method}_k` parameters, `\{iface}` declares \{intToString k} and a receiver [in impl \{method}@\{tag}]",
    ]

-- The slot count of [method]'s declared context; no row declares none.
declaredMethodContext : OrdMap Int -> String -> String -> Int
declaredMethodContext table iface method =
  optionOr 0 (omLookup (ifaceMethodArityKey iface method) table)

-- How many of [pats], from the front, are `$dict_<method>_0`, `$dict_<method>_1`, ….
leadingMethodDicts : String -> Int -> List Pat -> Int
leadingMethodDicts method k ((PVar x _ _) :: rest) =
  if x == "$dict_\{method}_\{intToString k}" then
    leadingMethodDicts method (k + 1) rest
  else
    k
leadingMethodDicts _ k _ = k

-- The impl-symbol check: every impl entry carries the symbol words
-- `core_ir_lower.stampImplSymbols` wrote, and a supplied method's interface word
-- is the qualified word its canonical key opens with.  The emitters only prefix
-- and join the stamp, so an entry with none would define a symbol named after
-- nothing.
export
validateImplSymbols : CProgram -> List String
validateImplSymbols (CProgram _ _ _ impls _ _) = flatMap implSymbolFaults impls

implSymbolFaults : CImplEntry -> List String
implSymbolFaults (CImplEntry method _ _ (CImplTagged tag key iface (ImplSym sym _ _) _ _ _)) =
  (if sym == "" then
      ["impl symbol: entry has no stamped symbol [in impl \{method}@\{tag}]"]
    else
      [])
    ++ (if iface == ifaceWordOfKey key then
      []
    else
      [
        "impl symbol: interface word `\{iface}` is not the qualified word `\{ifaceWordOfKey key}` of its key [in impl \{method}@\{tag}]",
      ])
implSymbolFaults (CImplEntry method _ _ (CImplDefault _ tag _ (ImplSym sym ifaceTag keyTag) _ _ _)) =
  if sym == "" || ifaceTag == "" || keyTag == "" then
    [
      "impl symbol: default entry has no stamped symbol [in impl \{method}@\{tag}]",
    ]
  else
    []

-- Two DISTINCT impls cannot share one emitted symbol.  The stamp is injective by
-- construction (#1950), so this guard is an assertion on the scheme, not a check a
-- user program can trip by naming: anything it prints describes a defect in the
-- scheme.  It reads the stamped entries -- the symbols the backends are about to
-- mint -- and covers supplied-method symbols (`mdk_impl_*`) only; defaults are
-- named by interface word and key, and `$memo_` CAFs by the same stamped tag.
-- Rows are deduplicated by (method, symbol tag, key) first, so a multi-clause impl
-- and the joint list's duplicated prelude impls never fire it.
--
-- Run by both emitters before they write any text.  An entry carries no source
-- location, so the message names the canonical dispatch keys,
-- `<module>::<Interface>|<type arguments>|`.  It panics with its own unprefixed text
-- rather than joining the `internal error:` findings of the other checks, because
-- the message is user-actionable.
export
validateImplSymbolInjectivity : CProgram -> Unit
validateImplSymbolInjectivity cp = match implSymbolCollision cp
  Some message => panic message
  None => ()

-- The refusal text for the first collision, if any.
export
implSymbolCollision : CProgram -> Option String
implSymbolCollision (CProgram _ _ _ impls _ _) =
  checkImplSymbolsInjective
    (dedupBy implPreImageKey (flatMap taggedImplSymRow impls))
    omEmpty

-- (method, symbol tag, canonical key) of a supplied-method entry
taggedImplSymRow : CImplEntry -> List (String, String, String)
taggedImplSymRow (CImplEntry m _ _ (CImplTagged _ key _ (ImplSym tag _ _) _ _ _)) =
  [(m, tag, key)]
taggedImplSymRow _ = []

implPreImageKey : (String, String, String) -> String
implPreImageKey (m, tag, key) = "\{m}\n\{tag}\n\{key}"

-- one pass, O(n log n).  The three data lines are UNINDENTED on purpose: they are
-- CONTENT-derived (the symbol and the two dispatch keys), so a `stdout-line` pin can
-- match them with `grep -qxF` against a whitespace-stripped claim value without
-- false-draining on a rewording of the prose around them.
checkImplSymbolsInjective : List (String, String, String) ->
  OrdMap String ->
  Option String
checkImplSymbolsInjective [] _ = None
checkImplSymbolsInjective ((m, tag, key) :: rest) seen =
  let sym = "mdk_impl_\{tag}_\{m}"
  match omLookup sym seen
    None => checkImplSymbolsInjective rest (omInsert sym key seen)
    Some prev =>
      Some
        "emitted impl-symbol collision: two DISTINCT impls of method `\{m}` are emitted under one symbol.\ncollided symbol: \{sym}\nimpl 1 key: \{prev}\nimpl 2 key: \{key}\nTwo distinct impls cannot share one emitted symbol: the backend would define one body twice (the native link fails) or keep one and silently drop the other. The two keys above are the impls' canonical dispatch keys, spelled `<module>::<Interface>|<type arguments>|`. Since #1950 those keys are spelled into the symbol by `private_mangle.injectiveIdent`, which is INJECTIVE, so this is NOT a naming mistake you can rename your way out of -- it means the emitted-symbol scheme itself lost injectivity. Please report this message, with both keys above."

-- ── dict-witness TAG injectivity — #348 (native i64), #377 (wasm 30-bit) ──────
--
-- A DIFFERENT failure mode from `validateImplSymbolInjectivity` above, in a
-- different space, and no encoding choice can prevent it.  That check covers the
-- SYMBOL space, where the fix was to spell the key injectively (#1950).  This one
-- covers the DICT-WITNESS TAG space, where the map is `hashName` -- a HASH, a lossy
-- map from an unbounded domain to a fixed width, so the only available discharge is
-- to CHECK that the program's own pre-images do not happen to collide, and refuse
-- if they do.
--
-- Colliding pre-images are CONSTRUCTIBLE in the full i64: djb2 is the radix-33
-- polynomial `5381*33^n + Σ c_i*33^i` and the identifier alphabet spans 74 code
-- points, wider than the radix, so `Δ_{i+1} = +1, Δ_i = −33` at two adjacent
-- positions is an exact zero.  Every `(X, c)` / `(X+1, chr(ord c − 33))` adjacent
-- pair collides: `Az`/`BY`, `Azure`/`BYure`, `Mzone`/`NYone`.  Two impls of one
-- interface at head tycons `Mzone` and `NYone`, dispatched through a dict
-- parameter, otherwise build to a binary that answers `mzone|mzone` where `run`
-- answers `mzone|nyone`: both tags hash alike, so the shared dispatcher's first arm
-- wins every call.
--
-- The pre-image population is read off every impl entry, supplied (`CImplTagged`)
-- and inherited (`CImplDefault`) alike: each carries the canonical key
-- (`route_key.implRouteKeyWord`) of its instance, the one word its dispatcher arm
-- compares (`llvm_emit.emitDispatchArm`, `wasm_emit.dispatchKeyTestW`), and the
-- entry's method name is the grouping key of its dispatch chain.  A supplied impl and
-- an inherited default of one method share that chain, so their words collide as
-- surely as two supplied impls' do.  Both hashes are imported
-- from `types.private_mangle`, the SAME `hashName` the LLVM emitter stamps and the
-- SAME `dictTag` the wasm emitter stamps, because a guard with its own copy of the
-- hash certifies a property of the copy.
--
-- SCOPE:
--   * partitioned by METHOD NAME.  The emitted dispatcher only compares route words
--     WITHIN one method name's dispatch chain, so two impls of unrelated methods
--     whose words hash alike are never compared at runtime; refusing them would be a
--     false positive.  Do not pool route words program-wide.
--   * covers the DICT-WITNESS TAG space of both backends and nothing else.  Native
--     constructor and record cell headers are `llvm_emit.cellTag`'s composite
--     `(typeId, ordinal)`, not a hash.  The wasm symbol namespaces are not
--     observable in Core (#378).
--   * distinct pre-images belonging to DIFFERENT impls: the multi-clause and joint
--     prelude+module duplicates of one impl share its key.
--   * it observes the tag the backends mint; it does not change the tag scheme.
--
-- The backend selects the width.  `LlvmBackend` checks the full `hashName`;
-- `WasmBackend` checks it too (a full-width collision is also a masked collision)
-- and then the 30-bit `dictTag`.  A pair that collides ONLY in the masked width
-- therefore builds under native, where its codegen is correct, and is refused by
-- the wasm emitter.
export
validateDictTags : Backend -> CProgram -> Unit
validateDictTags backend cp = match dictTagCollision backend cp
  Some message => panic message
  None => ()

-- The refusal text for the first collision, if any: the full-width space first.
export
dictTagCollision : Backend -> CProgram -> Option String
dictTagCollision backend (CProgram _ _ _ impls _ _) =
  let rows = dedupBy dictRouteWordKey (map dictRouteWordRow impls)
  match checkDictTagsInjective nativeDictTagSpace hashName rows omEmpty
    Some message => Some message
    None => match backend
      LlvmBackend => None
      WasmBackend =>
        checkDictTagsInjective wasmDictTagSpace dictTag rows omEmpty
      EvalBackend => None

nativeDictTagSpace : String
nativeDictTagSpace =
  "native (LLVM) i64 dict-witness word `hashName` -- BOTH backends, since the wasm tag is this hash masked"

wasmDictTagSpace : String
wasmDictTagSpace =
  "wasm (WasmGC) 30-bit i31 dict tag `dictTag` (`hashName` masked to the low 30 bits) -- the full i64 tags are DISTINCT, so a native build of this program is correct; the wasm tag is this hash masked to a narrower width, which collides"

-- (method, route word) of an impl entry, supplied or inherited: the METHOD NAME that
-- word's dispatch chain is keyed by, and the word a dict witness for this impl
-- carries (its canonical key, which is also the impl's identity).
dictRouteWordRow : CImplEntry -> (String, String)
dictRouteWordRow (CImplEntry m _ _ (CImplTagged _ key _ _ _ _ _)) = (m, key)
dictRouteWordRow (CImplEntry m _ _ (CImplDefault _ _ key _ _ _ _)) = (m, key)

-- Rows are deduplicated by (method, word), first arrival wins, so two DIFFERENT
-- methods' identical word never dedup against each other.  The joint prelude+module
-- decl list duplicates each prelude impl and a multi-clause impl contributes one row
-- per clause; both collapse here, so a word never collides with itself.
dictRouteWordKey : (String, String) -> String
dictRouteWordKey (m, w) = "\{m}\n\{w}"

-- injectivity of route word -> emitted tag, one pass per space, O(n log n) through
-- the same weight-balanced tree the two guards above use.  `hash` is passed in so
-- the native and wasm passes are ONE predicate over two widths rather than two
-- copies that can disagree about what a collision is.  The map key is
-- METHOD-NAME-SCOPED (`"\{mname}\n\{intToString (hash w)}"`) so injectivity is
-- checked WITHIN one method name's population only — the same partition
-- `dictRouteWordKey` dedups by, and the same grouping key
-- `implsOf`/`dispFnName` use to decide what a real dispatch chain compares.
--
-- The four data lines are UNINDENTED on purpose, for the same reason
-- `checkImplSymbolsInjective`'s three are: they are CONTENT-derived, so a
-- `stdout-line` pin can match them with `grep -qxF` without false-draining on a
-- rewording of the prose around them.
checkDictTagsInjective : String ->
  (String -> Int) ->
  List (String, String) ->
  OrdMap String ->
  Option String
checkDictTagsInjective _ _ [] _ = None
checkDictTagsInjective space hash ((m, w) :: rest) seen =
  let t = intToString (hash w)
  let k = "\{m}\n\{t}"
  match omLookup k seen
    None => checkDictTagsInjective space hash rest (omInsert k w seen)
    Some w0 =>
      Some
        "emitted dict-witness tag collision: two DISTINCT impls of method `\{m}` hash to one dispatch tag.\ntag space: \{space}\ncollided tag: \{t}\nroute word 1: \{w0}\nroute word 2: \{w}\nA dict witness carries this tag, and method `\{m}`'s shared dispatcher selects an impl by comparing it against every OTHER impl of that SAME method name -- these two words ARE compared against each other at that dispatcher, so this collision is live: whichever arm the emitter happened to emit FIRST wins every call through a dictionary, silently, at exit 0. The two words above are the impls' route words: either a bare head tycon or a canonical dispatch key spelled `<module>::<Interface>|<type arguments>|`. This is NOT a naming collision you can rename your way out of by making the names more different -- `hashName` is djb2, a radix-33 polynomial over a 74-code-point alphabet, so it is genuinely non-injective (`hashName \"Az\" == hashName \"BY\"`). One of the two words above may name a type or interface from the prelude or stdlib that you do not own -- rename the OTHER one, one of your own types or interfaces involved in this collision. Please also report this message, with both words above."

implBodyTag : CImplBody -> String
implBodyTag (CImplTagged tag _ _ _ _ _ _) = tag
implBodyTag (CImplDefault _ tag _ _ _ _ _) = tag

export
renderCallRefusal : List String -> String
renderCallRefusal bad = joinWith "\n" bad

-- The names in `names` that have no extern catalog row.
export
missingCatalogRows : List String -> List String
missingCatalogRows names = filter (n => isNone (catalogRow n)) names

export
missingRowsMessage : List String -> String
missingRowsMessage missing =
  let names = joinWith ", " (map quoteName missing)
  "internal error: runtime extern \{names} has no row in the extern catalog (compiler/backend/extern_catalog.mdk)"

quoteName : String -> String
quoteName n = "'" ++ n ++ "'"

refuseMissingRows : List String -> Unit
refuseMissingRows names = match missingCatalogRows names
  [] => ()
  missing => panic (missingRowsMessage missing)

-- One line per finding: what the build refuses, and why the backend does not
-- lower the extern.
export
renderExternFinding : ExternFinding -> String
renderExternFinding (ExternFinding name backend kind why binding) =
  "\{backendName backend}: runtime extern '\{name}' is not available on the \{backendName backend} backend (\{gapKindName kind}: \{why}) [in \{binding}]"

-- The refusal under the target the build checked the program against
-- (`checkedTarget`), or the plain findings when there is none.
export
renderExternRefusal : List ExternFinding -> String
renderExternRefusal findings = renderExternRefusalUnder !checkedTarget findings

-- A refusal here is a compiler bug: `check` refuses a program that reaches a
-- built-in its target does not provide, so none arrives after an admitted
-- check, and every finding says so (`checkMissedNote`).  An extern behind a
-- label the profile does not reach (`withheldLabels`) also names that label.
export
renderExternRefusalUnder : Option CheckedTarget -> List ExternFinding -> String
renderExternRefusalUnder None findings =
  joinWith "\n" (map renderExternFinding findings)
renderExternRefusalUnder (Some t) findings =
  joinWith "\n" (map (renderFindingUnder t) findings)

renderFindingUnder : CheckedTarget -> ExternFinding -> String
renderFindingUnder (CheckedTarget profile labels) (f@(ExternFinding name backend _ _ _)) =
  let declared = optionOr [] (omLookup name labels)
  let withheldNote = match withheldLabels profile declared
    [] => ""
    withheld =>
      "; the target `\{profileName profile}` does not grant \{joinWith ", " withheld}, which `\{name}` performs"
  "\{renderExternFinding f}\{withheldNote}; \{checkMissedNote backend}"

-- Why a finding reached the lowering of a program that passed the target
-- check: blamed on the compiler, never on the program.
checkMissedNote : Backend -> String
checkMissedNote backend =
  "`check` should have refused this program before the \{backendName backend} backend saw it, so this is a bug in the compiler"

-- What `medaka build` checked the program against before lowering: the
-- selected profile, and each runtime extern's declared labels.
public export data CheckedTarget =
  CheckedTarget TargetProfile (OrdMap (List String))

export
checkedTargetOf : TargetProfile -> List Decl -> CheckedTarget
checkedTargetOf profile runtimeDecls =
  CheckedTarget profile (omFromPairs (externLabels runtimeDecls) omEmpty)

-- Set by the build's emitter seam (`entries/entry_support.runEmitWith`) once
-- the program has passed the target check; `None` for every other caller.
export
checkedTarget : Ref (Option CheckedTarget)
checkedTarget = Ref None

-- Each extern's result-row labels, read from its parsed declaration.
export
externLabels : List Decl -> List (String, List String)
externLabels [] = []
externLabels ((DExtern (ExternDecl { edName = n, edTy = ty, ... })) :: rest) =
  (n, resultLabels ty) :: externLabels rest
externLabels ((DAttrib _ d) :: rest) = externLabels (d :: rest)
externLabels (_ :: rest) = externLabels rest

resultLabels : Ty -> List String
resultLabels (TyFun _ r) = resultLabels r
resultLabels (TyConstrained _ t) = resultLabels t
resultLabels (TyEffect atoms _ _) = map (a => a.eatLabel) atoms
resultLabels _ = []

-- The panic of an emitter that meets an extern `validateExterns` refuses: the
-- validator runs first on every emission, so reaching one means the two
-- disagree about which references are free.
export
unrefusedExternMessage : Backend -> String -> String
unrefusedExternMessage backend name =
  "internal error: the \{backendName backend} emitter reached runtime extern '\{name}', which it does not lower, without a refusal from validateExterns (compiler/backend/core_validate.mdk)"

-- The top-level bindings and constructors of the program.
programNames : List CBind -> List (String, Int) -> OrdMap Unit -> OrdMap Unit
programNames [] [] acc = acc
programNames [] ((ctor, _) :: rest) acc =
  programNames [] rest (omInsert ctor () acc)
programNames ((CBind name _ _ _) :: rest) ctors acc =
  programNames rest ctors (omInsert name () acc)

-- A reference is the program's own when a top-level binding has its name, or
-- the `core__` name a bare prelude reference resolves to in both emitters
-- (`canonFn`, `canonFnName`).
isProgramName : OrdMap Unit -> String -> Bool
isProgramName top x = omHasKey x top || omHasKey ("core__" ++ x) top

-- The walk's state: the externs already found, the extern findings, the record
-- nodes with untrustworthy ordinals, the applications with a wrong mode, and the
-- method occurrences whose routes contradict their declared context, each newest
-- first.
data Walk =
  Walk (OrdMap Unit) (List ExternFinding) (List String) (List String) (List String) (List String) (List String) (List String)

noFindings : Walk
noFindings = Walk omEmpty [] [] [] [] [] [] []

-- The backend, the program's own names, its defined arities, its method-context
-- table, the leading `$dict` parameter count of each top-level binding, the
-- dictionary facts, and the top-level binding being read.
data Ctx =
  Ctx Backend (OrdMap Unit) ArityEnv (OrdMap Int) (OrdMap Int) EvFacts String

-- What a dictionary built at a site is held to (`DeclFacts`): each instance's
-- `requires` count and each interface's super count.
data EvFacts = EvFacts {
  efRequires : OrdMap Int,
  efSupers : OrdMap Int,
  efMethods : OrdMap (OrdMap MethodResultFact),
  efExterns : OrdMap ExternDeclFact,
}

walkProgram : Backend -> CProgram -> Walk
walkProgram backend (prog@(CProgram groups ctors _ impls mctx facts)) =
  let top = programNames groups ctors omEmpty
  let env = programArities prog
  let ctx =
    Ctx
      backend
      top
      env
      (omFromPairs mctx omEmpty)
      (dictParamCounts groups omEmpty)
      EvFacts {
        efRequires = omFromPairs facts.factRequires omEmpty,
        efSupers = omFromPairs facts.factSupers omEmpty,
        efMethods = indexMethodResults facts.factMethodResults,
        efExterns = facts.factExterns,
      }
      ""
  walkImpls ctx impls (walkBinds ctx groups noFindings)

walkBinds : Ctx -> List CBind -> Walk -> Walk
walkBinds _ [] w = w
walkBinds ctx ((CBind name clauses _ _) :: rest) w =
  walkBinds ctx rest (walkClauses (inBinding ctx name) omEmpty clauses w)

walkImpls : Ctx -> List CImplEntry -> Walk -> Walk
walkImpls _ [] w = w
walkImpls ctx ((CImplEntry method _ _ body) :: rest) w =
  walkImpls ctx rest (walkImplBody (inBinding ctx "impl \{method}") body w)

inBinding : Ctx -> String -> Ctx
inBinding (Ctx backend top env mctx dcounts facts _) binding =
  Ctx backend top env mctx dcounts facts binding

ctxBinding : Ctx -> String
ctxBinding (Ctx _ _ _ _ _ _ binding) = binding

walkImplBody : Ctx -> CImplBody -> Walk -> Walk
walkImplBody ctx (CImplTagged tag _ _ _ _ pats body) w =
  walkE
    (inBinding ctx "\{ctxBinding ctx}@\{tag}")
    (bindPatsScope pats omEmpty)
    body
    w
walkImplBody ctx (CImplDefault _ tag _ _ _ pats body) w =
  walkE
    (inBinding ctx "\{ctxBinding ctx}@\{tag}")
    (bindPatsScope pats omEmpty)
    body
    w

walkClauses : Ctx -> CallScope -> List CClause -> Walk -> Walk
walkClauses _ _ [] w = w
walkClauses ctx scope ((CClause pats body) :: rest) w =
  walkClauses ctx scope rest (walkE ctx (bindPatsScope pats scope) body w)

-- Every constructor is listed, with no catch-all arm, so a new expression form
-- must decide where its binders scope.
walkE : Ctx -> CallScope -> CExpr -> Walk -> Walk
walkE ctx scope (CVar x _) w = noteVar ctx scope x w
walkE _ _ (CLit _) w = w
walkE ctx scope (CApp f args site) w =
  walkList ctx scope args (walkE ctx scope f (noteCall ctx scope f args site w))
walkE ctx scope (CLam pats body) w = walkE ctx (bindPatsScope pats scope) body w
walkE ctx scope (CLet recF pat rhs body) w =
  let inner = bindLetScope pat rhs scope
  walkE ctx inner body (walkE ctx (if recF then inner else scope) rhs w)
walkE ctx scope (CLetGroup binds body) w =
  let inner = bindGroupScope binds scope
  walkE ctx inner body (walkLocalBinds ctx inner binds w)
walkE ctx scope (CMatch scrut arms) w =
  walkArms ctx scope arms (walkE ctx scope scrut w)
walkE ctx scope (CDecision scrut arms _) w =
  walkArms ctx scope arms (walkE ctx scope scrut w)
walkE ctx scope (CIf c t f) w = walkList ctx scope [c, t, f] w
walkE ctx scope (CBinPrim op l r tag _) w =
  walkList ctx scope [l, r] (noteScalarOperator ctx op tag w)
walkE ctx scope (CUnOp _ x) w = walkE ctx scope x w
walkE ctx scope (CTuple es) w = walkList ctx scope es w
walkE ctx scope (CList es) w = walkList ctx scope es w
walkE ctx scope (CRecord name fields) w =
  walkFields ctx scope fields (noteRecord ctx "CRecord" name True fields w)
walkE ctx scope (CFieldAccess x label name ord) w =
  walkE ctx scope x (noteAccess ctx label name ord w)
walkE ctx scope (CRecordUpdate name base fields) w =
  walkFields
    ctx
    scope
    fields
    (walkE ctx scope base (noteRecord ctx "CRecordUpdate" name False fields w))
walkE ctx scope (CVariantUpdate con base fields) w =
  walkFields
    ctx
    scope
    fields
    (walkE ctx scope base (noteRecord ctx "CVariantUpdate" con False fields w))
walkE ctx scope (CArray es) w = walkList ctx scope es w
walkE ctx scope (CRangeList lo hi _) w = walkList ctx scope [lo, hi] w
walkE ctx scope (CRangeArray lo hi _) w = walkList ctx scope [lo, hi] w
walkE ctx scope (CIndex a i) w = walkList ctx scope [a, i] w
walkE ctx scope (CSlice a lo hi _) w = walkList ctx scope [a, lo, hi] w
walkE ctx scope (CStringIndex a i) w = walkList ctx scope [a, i] w
walkE ctx scope (CStringSlice a lo hi _) w = walkList ctx scope [a, lo, hi] w
walkE ctx scope (CListIndex a i) w = walkList ctx scope [a, i] w
walkE ctx scope (CListSlice a lo hi _) w = walkList ctx scope [a, lo, hi] w
walkE ctx scope (CBlock stmts) w = walkStmts ctx scope stmts w
walkE ctx scope (node@(CMethod name (MethodEvidence iface _ _ _ meths))) w =
  noteEvidence
    ctx
    scope
    node
    (noteMethodResult
      ctx
      name
      iface
      (noteMethodContext ctx name iface (listLen meths) w))
walkE ctx scope (node@(CDict _ _)) w = noteEvidence ctx scope node w

noteScalarOperator : Ctx -> String -> String -> Walk -> Walk
noteScalarOperator _ _ "" w = w
noteScalarOperator (Ctx _ _ _ _ _ _ binding) op tag (Walk seen found records scalar calls ctxs evs results) =
  if scalarOperatorTagAllowed op tag then
    Walk seen found records scalar calls ctxs evs results
  else
    Walk
      seen
      found
      records
      ("scalar binop: operator `\{op}` cannot carry scalar tag `\{tag}` [in \{binding}]"
        :: scalar)
      calls
      ctxs
      evs
      results

scalarOperatorTagAllowed : String -> String -> Bool
scalarOperatorTagAllowed op tag =
  if scalarArithmeticOperator op then
    tag == "Int" || tag == "Float" || isFixedIntHead tag
  else if scalarComparisonOperator op then
    tag == "Int" || tag == "Char" || isBoxed64Head tag
  else
    False

scalarArithmeticOperator : String -> Bool
scalarArithmeticOperator "+" = True
scalarArithmeticOperator "-" = True
scalarArithmeticOperator "*" = True
scalarArithmeticOperator "/" = True
scalarArithmeticOperator "%" = True
scalarArithmeticOperator _ = False

scalarComparisonOperator : String -> Bool
scalarComparisonOperator "==" = True
scalarComparisonOperator "/=" = True
scalarComparisonOperator "<" = True
scalarComparisonOperator ">" = True
scalarComparisonOperator "<=" = True
scalarComparisonOperator ">=" = True
scalarComparisonOperator _ = False

-- One line per way a dispatch node's evidence fails to denote a dictionary its
-- callee binds (see the header).
export
validateDispatchEvidence : CProgram -> List String
validateDispatchEvidence prog = match walkProgram LlvmBackend prog
  Walk _ _ _ _ _ _ bad _ => reverseL bad

-- The leading `$dict` parameters of each top-level binding's first clause.
dictParamCounts : List CBind -> OrdMap Int -> OrdMap Int
dictParamCounts [] acc = acc
dictParamCounts ((CBind name ((CClause pats _) :: _) _ _) :: rest) acc =
  dictParamCounts rest (omInsert name (leadingDictParams pats) acc)
dictParamCounts (_ :: rest) acc = dictParamCounts rest acc

noteEvidence : Ctx -> CallScope -> CExpr -> Walk -> Walk
noteEvidence (Ctx _ _ env _ dcounts facts binding) scope node (Walk seen found bad scalar calls ctxs evs results) =
  let why = evidenceFaults env dcounts facts scope node
  Walk
    seen
    found
    bad
    scalar
    calls
    ctxs
    (reverseL
        (map
          (f => "dispatch evidence: \{headText node} \{f} [in \{binding}]")
          why)
      ++ evs)
    results

evidenceFaults : ArityEnv ->
  OrdMap Int ->
  EvFacts ->
  CallScope ->
  CExpr ->
  List String
evidenceFaults env _ facts scope (node@(CMethod name (MethodEvidence iface _ route prereqs meths))) =
  let routes = route :: prereqs ++ meths
  unboundFaults scope routes
    ++ flatMap routeShapeFaults routes
    ++ (match route
      RKey key _ _ => match definedArityOf env scope node
        Some _ => []
        None => ["names instance `\{key}` that has no entry for `\{name}`"]
      _ => [])
    ++ flatMap (builtDictFaults facts) (headParts route ++ prereqs ++ meths)
    ++ ifaceWordFaults iface route
    ++ methodNoRouteFault iface route
evidenceFaults _ dcounts facts scope (CDict f routes) =
  unboundFaults scope routes
    ++ flatMap routeShapeFaults routes
    ++ flatMap (builtDictFaults facts) routes
    ++ flatMap noRouteFault routes
    ++ (if omHasKey f scope then
      []
    else match omLookup f dcounts
      Some k =>
        if k == listLen routes then
          []
        else
          [
            "supplies \{intToString (listLen routes)} dictionaries, `\{f}` takes \{intToString k}",
          ]
      None => [])
evidenceFaults _ _ _ _ _ = []

-- The routes a dispatch answer is built from.  A head instance's own super routes
-- ride along only when its entry needs a receiver, so the head is not held to its
-- interface's super count; what it is built from is.
headParts : Route -> List Route
headParts (RKey _ reqs sups) = reqs ++ sups
headParts (RLocal _ ds) = ds
headParts (RProj r _) = [r]
headParts _ = []

-- A dictionary built at a site holds its interface's supers, then its instance's
-- `requires`, so it carries exactly as many of each as the declarations give.  An
-- instance or interface the program does not declare (a built-in dictionary of a
-- prelude-free program) stores none, as the emitters lay it out.
builtDictFaults : EvFacts -> Route -> List String
builtDictFaults facts (RKey key reqs sups) =
  let n = optionOr 0 (omLookup key facts.efRequires)
  let word = ifaceWordOfKey key
  let k = optionOr 0 (omLookup word facts.efSupers)
  (if listLen reqs == n then
      []
    else
      [
        "builds instance `\{key}` from \{intToString (listLen reqs)} prerequisite dictionaries, it requires \{intToString n}",
      ])
    ++ (if listLen sups == k then
      []
    else
      [
        "builds instance `\{key}` with \{intToString (listLen sups)} super dictionaries, `\{word}` has \{intToString k}",
      ])
    ++ flatMap (builtDictFaults facts) (reqs ++ sups)
builtDictFaults facts (RLocal _ ds) = flatMap (builtDictFaults facts) ds
builtDictFaults facts (RProj r _) = builtDictFaults facts r
builtDictFaults _ _ = []

-- An occurrence answered by a dictionary names the interface whose method it is.
ifaceWordFaults : String -> Route -> List String
ifaceWordFaults "" (RKey _ _ _) = ["dispatches with no interface word"]
ifaceWordFaults "" (RDict _) = ["dispatches with no interface word"]
ifaceWordFaults "" (RDictFwd _) = ["dispatches with no interface word"]
ifaceWordFaults "" (RProj _ _) = ["dispatches with no interface word"]
ifaceWordFaults _ _ = []

-- A method occurrence that names its interface is answered by an instance or a
-- given.  An interface-less `RNone` is a standalone, which dispatches by its own
-- name: an admitted-set occurrence check accepts carries its selecting
-- declaration's word, and one no declaration decides is a T-AMBIGUOUS-METHOD
-- reject.
methodNoRouteFault : String -> Route -> List String
methodNoRouteFault "" _ = []
methodNoRouteFault _ RNone = ["has no route"]
methodNoRouteFault _ _ = []

noRouteFault : Route -> List String
noRouteFault RNone = ["has a dictionary slot with no route"]
noRouteFault _ = []

unboundFaults : CallScope -> List Route -> List String
unboundFaults scope routes =
  flatMap
    (d =>
      if omHasKey d scope then
        []
      else
        ["reads dictionary `\{d}`, which is not bound here"])
    (flatMap givenNames routes)

routeShapeFaults : Route -> List String
routeShapeFaults (RScalar tag) = ["carries scalar route `\{tag}`"]
routeShapeFaults (RProj r _) =
  (if givenRooted r then
      []
    else
      ["projects from a route that is not a given dictionary"])
    ++ routeShapeFaults r
routeShapeFaults (RKey _ reqs sups) = flatMap routeShapeFaults (reqs ++ sups)
routeShapeFaults (RLocal _ ds) = flatMap routeShapeFaults ds
routeShapeFaults _ = []

-- Stricter than core_ir.isGivenRooted, which accepts any projection: a projection
-- is rooted only when the route it projects from is.
givenRooted : Route -> Bool
givenRooted (RDict _) = True
givenRooted (RDictFwd _) = True
givenRooted (RProj r _) = givenRooted r
givenRooted _ = False

-- A method occurrence supplies one route per slot of its declared context.
noteMethodContext : Ctx -> String -> String -> Int -> Walk -> Walk
noteMethodContext (Ctx _ _ _ mctx _ _ binding) name iface n (w@(Walk seen found bad scalar calls ctxs evs results)) =
  let k = declaredMethodContext mctx iface name
  if n == k then
    w
  else
    Walk
      seen
      found
      bad
      scalar
      calls
      ("method context: method \{name} supplies \{intToString n} method routes, `\{iface}` declares \{intToString k} [in \{binding}]"
        :: ctxs)
      evs
      results

-- A field access is stamped, or reads a `Ref` cell through `.value`, which is
-- never stamped: an emitter reading a stamped `.value` as a record field would
-- cast the cell to whichever record declares a field `value`.
noteAccess : Ctx -> String -> String -> Int -> Walk -> Walk
noteAccess ctx "value" name ord w =
  if ord == -1 then
    w
  else
    noteRecordBad
      ctx
      "CFieldAccess"
      "\{name}.value: a Ref read stamped with field ordinal \{intToString ord}"
      w
noteAccess ctx label name ord w =
  if ord >= 0 then
    w
  else
    noteRecordBad
      ctx
      "CFieldAccess"
      "\{name}.\{label}: unstamped field ordinal"
      w

-- `literal`: the ordinals must be the field positions (declared order).
noteRecord : Ctx -> String -> String -> Bool -> List CField -> Walk -> Walk
noteRecord ctx node name literal fields w =
  if ordinalsOk literal 0 (-1) fields then
    w
  else
    noteRecordBad
      ctx
      node
      "\{name}: field ordinals [\{joinWith ", " (map fieldOrdinalText fields)}] are not \{if literal then "the declared positions" else "strictly ascending"}"
      w

ordinalsOk : Bool -> Int -> Int -> List CField -> Bool
ordinalsOk _ _ _ [] = True
ordinalsOk literal pos prev ((CField _ o _) :: rest) =
  o >= 0
    && (if literal then o == pos else o > prev)
    && ordinalsOk literal (pos + 1) o rest

fieldOrdinalText : CField -> String
fieldOrdinalText (CField k o _) = "\{k}@\{intToString o}"

noteRecordBad : Ctx -> String -> String -> Walk -> Walk
noteRecordBad (Ctx _ _ _ _ _ _ binding) node why (Walk seen found bad scalar calls ctxs evs results) =
  Walk
    seen
    found
    ("record: \{node} \{why} [in \{binding}]" :: bad)
    scalar
    calls
    ctxs
    evs
    results

-- The mode the head's defined arity gives the arguments, or the shape fault.
noteCall : Ctx -> CallScope -> CExpr -> List CExpr -> CallSite -> Walk -> Walk
noteCall ctx _ _ [] _ w = noteCallBad ctx "application with no arguments" w
noteCall ctx _ (CApp _ _ _) _ _ w =
  noteCallBad ctx "application whose head is an application" w
noteCall (ctx@(Ctx _ _ env _ _ _ _)) scope hd args (CallSite mode _) w =
  let n = listLen args
  let arity = definedArityOf env scope hd
  if sameMode (callModeFor arity n) mode then
    w
  else match arity
    Some k =>
      noteCallBad
        ctx
        "\{headText hd} applied to \{intToString n} of \{intToString k}, stamped \{callModeSexp mode}"
        w
    None =>
      noteCallBad
        ctx
        "\{headText hd} has no static arity, stamped \{callModeSexp mode}"
        w

sameMode : CallMode -> CallMode -> Bool
sameMode CallExact CallExact = True
sameMode (CallPartial a) (CallPartial b) = a == b
sameMode (CallOver a) (CallOver b) = a == b
sameMode CallDynamic CallDynamic = True
sameMode _ _ = False

noteCallBad : Ctx -> String -> Walk -> Walk
noteCallBad (Ctx _ _ _ _ _ _ binding) why (Walk seen found bad scalar calls ctxs evs results) =
  Walk
    seen
    found
    bad
    scalar
    ("call: \{why} [in \{binding}]" :: calls)
    ctxs
    evs
    results

headText : CExpr -> String
headText (CVar x _) = x
headText (CMethod name _) = "method \{name}"
headText (CDict name _) = "\{name} (constrained)"
headText (CLam _ _) = "a lambda"
headText _ = "an expression"

noteVar : Ctx -> CallScope -> String -> Walk -> Walk
noteVar (Ctx backend top _ _ _ facts binding) scope x (w@(Walk seen found bad scalar calls ctxs evs results)) =
  if omHasKey x scope || omHasKey x seen then
    w
  else match (unprovidedOn
    backend
    (optionOr "" (externRuntimeKey facts.efExterns x)))
    None => w
    Some (kind, why) =>
      if isProgramName top x then
        w
      else
        Walk
          (omInsert x () seen)
          (ExternFinding
              (optionOr x (externRuntimeKey facts.efExterns x))
              backend
              kind
              why
              binding
            :: found)
          bad
          scalar
          calls
          ctxs
          evs
          results

walkList : Ctx -> CallScope -> List CExpr -> Walk -> Walk
walkList _ _ [] w = w
walkList ctx scope (e :: rest) w = walkList ctx scope rest (walkE ctx scope e w)

walkFields : Ctx -> CallScope -> List CField -> Walk -> Walk
walkFields _ _ [] w = w
walkFields ctx scope ((CField _ _ e) :: rest) w =
  walkFields ctx scope rest (walkE ctx scope e w)

walkLocalBinds : Ctx -> CallScope -> List CBind -> Walk -> Walk
walkLocalBinds _ _ [] w = w
walkLocalBinds ctx scope ((CBind _ clauses _ _) :: rest) w =
  walkLocalBinds ctx scope rest (walkClauses ctx scope clauses w)

-- An arm's pattern scopes over its guards and body; a `Pat <- e` guard's
-- pattern scopes over the guards after it and the body.
walkArms : Ctx -> CallScope -> List CArm -> Walk -> Walk
walkArms _ _ [] w = w
walkArms ctx scope ((CArm pat guards body) :: rest) w =
  walkArms
    ctx
    scope
    rest
    (walkGuarded ctx (bindPatScope pat scope) guards body w)

walkGuarded : Ctx -> CallScope -> List CGuard -> CExpr -> Walk -> Walk
walkGuarded ctx scope [] body w = walkE ctx scope body w
walkGuarded ctx scope ((CGBool c) :: rest) body w =
  walkGuarded ctx scope rest body (walkE ctx scope c w)
walkGuarded ctx scope ((CGBind pat e) :: rest) body w =
  walkGuarded ctx (bindPatScope pat scope) rest body (walkE ctx scope e w)

walkStmts : Ctx -> CallScope -> List CStmt -> Walk -> Walk
walkStmts _ _ [] w = w
walkStmts ctx scope ((CSExpr e) :: rest) w =
  walkStmts ctx scope rest (walkE ctx scope e w)
walkStmts ctx scope ((CSLet recF pat e) :: rest) w =
  let inner = bindLetScope pat e scope
  walkStmts ctx inner rest (walkE ctx (if recF then inner else scope) e w)
walkStmts ctx scope ((CSAssign _ e) :: rest) w =
  walkStmts ctx scope rest (walkE ctx scope e w)

-- ── the tail check ───────────────────────────────────────────────────────────
-- One line per application whose tail flag disagrees with its position, in
-- program order; empty for a program `core_ir_lower.markTailSites` flagged.
-- The walk states the position rules itself rather than calling the pass that
-- applies them, so the two can disagree.  Tail position starts at the body of a
-- clause with a parameter and of a lambda, and passes through the branches of
-- an `if`, the arms of a match, the body of a `let` or let-group and the last
-- statement of a block.
export
validateTails : CProgram -> List String
validateTails (CProgram groups _ _ impls _ _) =
  reverseL (tailImpls impls (tailBinds groups []))

export
renderTailRefusal : List String -> String
renderTailRefusal bad = joinWith "\n" bad

tailBinds : List CBind -> List String -> List String
tailBinds [] acc = acc
tailBinds ((CBind name clauses _ _) :: rest) acc =
  tailBinds rest (tailClauses name clauses acc)

tailClauses : String -> List CClause -> List String -> List String
tailClauses _ [] acc = acc
tailClauses b ((CClause pats body) :: rest) acc =
  tailClauses b rest (tailE b (isNonEmptyL pats) body acc)

tailImpls : List CImplEntry -> List String -> List String
tailImpls [] acc = acc
tailImpls ((CImplEntry method _ _ body) :: rest) acc =
  tailImpls rest (tailImplBody "impl \{method}" body acc)

tailImplBody : String -> CImplBody -> List String -> List String
tailImplBody b (CImplTagged tag _ _ _ _ pats body) acc =
  tailE "\{b}@\{tag}" (isNonEmptyL pats) body acc
tailImplBody b (CImplDefault _ tag _ _ _ pats body) acc =
  tailE "\{b}@\{tag}" (isNonEmptyL pats) body acc

-- `b` is the top-level binding being read; `tl` is whether `e` is in tail
-- position.  No catch-all arm.
tailE : String -> Bool -> CExpr -> List String -> List String
tailE b tl (CApp f args (CallSite mode flag)) acc =
  tailList b args (tailE b False f (tailCallNote b tl f mode flag acc))
tailE _ _ (CVar _ _) acc = acc
tailE _ _ (CLit _) acc = acc
tailE b _ (CLam _ body) acc = tailE b True body acc
tailE b tl (CLet _ _ rhs body) acc = tailE b tl body (tailE b False rhs acc)
tailE b tl (CLetGroup binds body) acc =
  tailE b tl body (tailLocalBinds b binds acc)
tailE b tl (CMatch scrut arms) acc =
  tailArms b tl arms (tailE b False scrut acc)
tailE b tl (CDecision scrut arms _) acc =
  tailArms b tl arms (tailE b False scrut acc)
tailE b tl (CIf c t f) acc = tailE b tl f (tailE b tl t (tailE b False c acc))
tailE b _ (CBinPrim _ l r _ _) acc = tailList b [l, r] acc
tailE b _ (CUnOp _ x) acc = tailE b False x acc
tailE b _ (CTuple es) acc = tailList b es acc
tailE b _ (CList es) acc = tailList b es acc
tailE b _ (CRecord _ fields) acc = tailFields b fields acc
tailE b _ (CFieldAccess x _ _ _) acc = tailE b False x acc
tailE b _ (CRecordUpdate _ base fields) acc =
  tailFields b fields (tailE b False base acc)
tailE b _ (CVariantUpdate _ base fields) acc =
  tailFields b fields (tailE b False base acc)
tailE b _ (CArray es) acc = tailList b es acc
tailE b _ (CRangeList lo hi _) acc = tailList b [lo, hi] acc
tailE b _ (CRangeArray lo hi _) acc = tailList b [lo, hi] acc
tailE b _ (CIndex a i) acc = tailList b [a, i] acc
tailE b _ (CSlice a lo hi _) acc = tailList b [a, lo, hi] acc
tailE b _ (CStringIndex a i) acc = tailList b [a, i] acc
tailE b _ (CStringSlice a lo hi _) acc = tailList b [a, lo, hi] acc
tailE b _ (CListIndex a i) acc = tailList b [a, i] acc
tailE b _ (CListSlice a lo hi _) acc = tailList b [a, lo, hi] acc
tailE b tl (CBlock stmts) acc = tailStmts b tl stmts acc
tailE _ _ (CMethod _ _) acc = acc
tailE _ _ (CDict _ _) acc = acc

tailCallNote : String ->
  Bool ->
  CExpr ->
  CallMode ->
  Bool ->
  List String ->
  List String
tailCallNote b tl hd mode flag acc =
  if flag && not tl then
    "tail: \{headText hd} is flagged as a tail call outside tail position [in \{b}]"
      :: acc
  else if flag && isPartialCall mode then
    "tail: \{headText hd} is flagged as a tail call but is a partial application \{callModeSexp mode} [in \{b}]"
      :: acc
  else if tl && not flag && not (isPartialCall mode) then
    "tail: \{headText hd} is in tail position, stamped \{callModeSexp mode}, but not flagged [in \{b}]"
      :: acc
  else
    acc

isPartialCall : CallMode -> Bool
isPartialCall (CallPartial _) = True
isPartialCall _ = False

tailList : String -> List CExpr -> List String -> List String
tailList _ [] acc = acc
tailList b (e :: rest) acc = tailList b rest (tailE b False e acc)

tailFields : String -> List CField -> List String -> List String
tailFields _ [] acc = acc
tailFields b ((CField _ _ e) :: rest) acc =
  tailFields b rest (tailE b False e acc)

tailLocalBinds : String -> List CBind -> List String -> List String
tailLocalBinds _ [] acc = acc
tailLocalBinds b ((CBind _ clauses _ _) :: rest) acc =
  tailLocalBinds b rest (tailClauses b clauses acc)

tailArms : String -> Bool -> List CArm -> List String -> List String
tailArms _ _ [] acc = acc
tailArms b tl ((CArm _ guards body) :: rest) acc =
  tailArms b tl rest (tailE b tl body (tailGuards b guards acc))

tailGuards : String -> List CGuard -> List String -> List String
tailGuards _ [] acc = acc
tailGuards b ((CGBool c) :: rest) acc = tailGuards b rest (tailE b False c acc)
tailGuards b ((CGBind _ e) :: rest) acc =
  tailGuards b rest (tailE b False e acc)

tailStmts : String -> Bool -> List CStmt -> List String -> List String
tailStmts _ _ [] acc = acc
tailStmts b tl [CSExpr e] acc = tailE b tl e acc
tailStmts b tl (st :: rest) acc = tailStmts b tl rest (tailStmt b st acc)

tailStmt : String -> CStmt -> List String -> List String
tailStmt b (CSExpr e) acc = tailE b False e acc
tailStmt b (CSLet _ _ e) acc = tailE b False e acc
tailStmt b (CSAssign _ e) acc = tailE b False e acc

-- ── binder stamps ─────────────────────────────────────────────────────────────
-- One line per binder with no row, per binder stamped against the literal,
-- tuple, list or constructor it is bound to, and per function whose row gives no
-- return type: a binding's patterns first, then its functions, in program order.
export
validateBinderStamps : CProgram -> List String
validateBinderStamps (CProgram groups ctorArs ctorTypes impls _ facts) =
  let rows =
    BM.fromList (map (r => (binderOrdinal r.brId, r)) facts.factBinders)
  let ctors = omFromPairs ctorTypes omEmpty
  let arities = omFromPairs ctorArs omEmpty
  flatMap (bindStampFaults rows ctors arities) groups
    ++ flatMap (entryStampFaults rows ctors arities) impls

bindStampFaults : BM.Map Int BinderRow ->
  OrdMap String ->
  OrdMap Int ->
  CBind ->
  List String
bindStampFaults rows ctors arities (b@(CBind name _ _ _)) =
  stampFaultsIn rows ctors arities name (CProgram [b] [] [] [] [] noDeclFacts)

entryStampFaults : BM.Map Int BinderRow ->
  OrdMap String ->
  OrdMap Int ->
  CImplEntry ->
  List String
entryStampFaults rows ctors arities (e@(CImplEntry method _ _ body)) =
  stampFaultsIn
    rows
    ctors
    arities
    "impl \{method}@\{implBodyTag body}"
    (CProgram [] [] [] [e] [] noDeclFacts)

stampFaultsIn : BM.Map Int BinderRow ->
  OrdMap String ->
  OrdMap Int ->
  String ->
  CProgram ->
  List String
stampFaultsIn rows ctors arities where_ prog =
  let found = Ref []
  let _ =
    mapProgramBinders
      (site x bid =>
        let _ = match site
          PatternBinder rhs => match stampFault rows ctors arities rhs x bid
            Some msg => found := "binder: \{msg} [in \{where_}]" :: !found
            None => ()
          FunctionBinder _ => match returnFault rows x bid
            Some msg => found := "function: \{msg} [in \{where_}]" :: !found
            None => ()
        bid)
      prog
  reverseL !found

-- A named function's row must say what its body returns.
returnFault : BM.Map Int BinderRow -> String -> BinderId -> Option String
returnFault rows x (BinderId _ n) =
  if n < 0 then
    Some "\{x} has no id, so no return type"
  else match BM.get n rows
    None => Some "\{x} has no stamped type"
    Some row => match row.brReturns
      None => Some "\{x} has no return type"
      Some _ => None

stampFault : BM.Map Int BinderRow ->
  OrdMap String ->
  OrdMap Int ->
  Option CExpr ->
  String ->
  BinderId ->
  Option String
stampFault rows ctors arities rhs x (BinderId _ n) =
  if n < 0 then
    Some "\{x} has no id, so no stamped type"
  else match BM.get n rows
    None => Some "\{x} has no stamped type"
    Some row => match rhs
      None => None
      Some e => match boundShape ctors arities e
        None => None
        Some shape =>
          if stampAllows shape row.brType then
            None
          else
            Some
              "\{x} is stamped \{runtimeTypeName row.brType} but is bound to \{shapeName shape}"

-- What a `let` right-hand side is, where that fixes what its binder holds.
data BoundShape = BoundLit RuntimeType | BoundInt | BoundCell

boundShape : OrdMap String -> OrdMap Int -> CExpr -> Option BoundShape
boundShape _ _ (CLit (LInt _)) = Some BoundInt
boundShape _ _ (CLit l) = Some (BoundLit (litRuntimeType l))
boundShape _ _ (CTuple _) = Some BoundCell
boundShape _ _ (CList _) = Some BoundCell
boundShape ctors arities (CVar c _) = ctorShape ctors arities c 0
boundShape ctors arities (CApp (CVar c _) args _) =
  ctorShape ctors arities c (listLen args)
boundShape _ _ _ = None

-- A constructor of a type other than `Bool` and `Unit`, applied to all its fields.
ctorShape : OrdMap String -> OrdMap Int -> String -> Int -> Option BoundShape
ctorShape ctors arities c n = match (omLookup c arities, omLookup c ctors)
  (Some k, Some ty) =>
    if k == n && ty /= "Bool" && ty /= "Unit" then Some BoundCell else None
  _ => None

stampAllows : BoundShape -> RuntimeType -> Bool
stampAllows _ RTValue = True
stampAllows (BoundLit t) stamped = t == stamped
stampAllows BoundInt stamped = isNumericRuntimeType stamped
stampAllows BoundCell stamped = stamped == RTCon

isNumericRuntimeType : RuntimeType -> Bool
isNumericRuntimeType RTInt = True
isNumericRuntimeType RTFloat = True
isNumericRuntimeType RTU64 = True
isNumericRuntimeType RTI64 = True
isNumericRuntimeType RTU32 = True
isNumericRuntimeType RTI32 = True
isNumericRuntimeType RTU16 = True
isNumericRuntimeType RTU8 = True
isNumericRuntimeType _ = False

shapeName : BoundShape -> String
shapeName (BoundLit t) = "a \{runtimeTypeName t} literal"
shapeName BoundInt = "an integer literal"
shapeName BoundCell = "a constructor cell"

export
renderBinderRefusal : List String -> String
renderBinderRefusal bad = joinWith "\n" bad

validatePhysicalDemand : Backend -> EmitPlan -> CProgram -> List String
validatePhysicalDemand WasmBackend plan cp = match plan.wasmPhysical
  None => ["missing-wasm-demand-plan"]
  Some physical =>
    validateWasmDemand
        { plan.wasmInputs |
          lazyGlobals = plan.lazyGlobals,
          globalInit = plan.globalInit,
          trmcVerdicts = plan.trmc,
          dispatchGroups = plan.dispGroups,
        }
        cp
        plan.externRequirements
        physical
      ++ (if physical.sourceDemand /= plan.wasmDemand
        || physical.sourceHostKeys /= plan.hostKeys
        || physical.jsImports /= plan.jsImports then
        ["wasm-source-demand-mismatch"]
      else
        [])
validatePhysicalDemand _ _ _ = []
# DESUGAR
(DUse false (UseGroup ("backend" "wasm_demand") ((mem "validateWasmDemand" false))))
(DUse false (UseGroup ("ir" "extern_types") ((mem "ExternDeclFact" true) (mem "ExternUse" true))))
(DUse false (UseGroup ("ir" "extern_uses") ((mem "collectExternUses" false))))
(DUse false (UseGroup ("ir" "extern_lower") ((mem "externRuntimeKey" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CField" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CBind" true) (mem "CClause" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "ImplSym" true) (mem "MethodEvidence" true) (mem "CProgram" true) (mem "DeclFacts" true) (mem "MethodResultFact" true) (mem "CallMode" true) (mem "CallSite" true) (mem "noDeclFacts" false) (mem "givenNames" false) (mem "mapProgramBinders" false) (mem "BinderSite" true) (mem "litRuntimeType" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" true) (mem "RuntimeType" true) (mem "binderOrdinal" false) (mem "runtimeTypeName" false))))
(DUse false (UseAlias ("map") "BM"))
(DUse false (UseGroup ("ir" "core_ir_lower") ((mem "ArityEnv" false) (mem "CallScope" false) (mem "bindGroupScope" false) (mem "bindLetScope" false) (mem "bindPatScope" false) (mem "bindPatsScope" false) (mem "callModeFor" false) (mem "definedArityOf" false) (mem "entryArityRow" false) (mem "programArities" false) (mem "ifaceMethodArityKey" false) (mem "ifaceWordOfKey" false) (mem "leadingDictParams" false))))
(DUse false (UseGroup ("ir" "core_ir_sexp") ((mem "callModeSexp" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Pat" true) (mem "Route" true) (mem "Decl" true) (mem "ExternDecl" true) (mem "Ty" true) (mem "Lit" true) (mem "BinderId" true) (mem "isFixedIntHead" false) (mem "isBoxed64Head" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false) (mem "withheldLabels" false) (mem "profileName" false))))
(DUse false (UseGroup ("backend" "extern_requirements") ((mem "validateExternRequirements" false) (mem "requirementHostRows" false))))
(DUse false (UseGroup ("backend" "global_plan") ((mem "validateGlobalInit" false))))
(DUse false (UseGroup ("backend" "emit_target") ((mem "Backend" true) (mem "backendName" false))))
(DUse false (UseGroup ("backend" "emit_plan") ((mem "EmitPlan" false) (mem "indexMethodResults" false) (mem "lookupMethodResult" false))))
(DUse false (UseGroup ("backend" "extern_catalog") ((mem "RuntimeExternDomain" true) (mem "Disposition" true) (mem "GapKind" true) (mem "catalogRow" false) (mem "gapKindName" false) (mem "rowLlvm" false) (mem "rowWasm" false) (mem "rowEval" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromPairs" false) (mem "omInsert" false) (mem "omHasKey" false) (mem "omLookup" false) (mem "omKeys" false))))
(DUse false (UseGroup ("types" "private_mangle") ((mem "dictTag" false) (mem "hashName" false))))
(DUse false (UseGroup ("support" "util") ((mem "dedupBy" false) (mem "isNonEmptyL" false) (mem "joinWith" false) (mem "listLen" false) (mem "reverseL" false))))
(DData Public "ExternFinding" () ((variant "ExternFinding" (ConPos (TyCon "String") (TyCon "Backend") (TyCon "GapKind") (TyCon "String") (TyCon "String")))) ())
(DData Public "CoreDefect" () ((variant "CoreDefect" (ConPos (TyCon "String")))) ())
(DData Public "EmissionValidation" () ((variant "EmissionValidation" (ConNamed (field "defects" (TyApp (TyCon "List") (TyCon "CoreDefect"))) (field "externFindings" (TyApp (TyCon "List") (TyCon "ExternFinding")))))) ())
(DTypeSig true "coreDefectMessage" (TyFun (TyCon "CoreDefect") (TyCon "String")))
(DFunDef false "coreDefectMessage" ((PCon "CoreDefect" (PVar "message"))) (EVar "message"))
(DTypeSig true "validateForEmission" (TyFun (TyCon "Backend") (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyCon "EmitPlan") (TyFun (TyCon "CProgram") (TyCon "EmissionValidation"))))))
(DFunDef false "validateForEmission" ((PVar "backend") (PVar "domain") (PVar "plan") (PVar "cp")) (EMatch (EApp (EApp (EApp (EApp (EVar "emissionDefects") (EVar "backend")) (EVar "domain")) (EVar "plan")) (EVar "cp")) (arm (PList) () (EBlock (DoLet false false (PVar "names") (EMatch (EVar "domain") (arm (PCon "PreludeFreeRuntime") () (EListLit)) (arm (PCon "LoadedRuntimeExterns" (PVar "decls")) () (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EFieldAccess (EVar "d") "edName"))) (EVar "decls"))))) (DoExpr (EMatch (EApp (EVar "missingCatalogRows") (EVar "names")) (arm (PList) () (ERecordCreate "EmissionValidation" ((fa "defects" (EListLit)) (fa "externFindings" (EApp (EApp (EApp (EVar "validateExterns") (EVar "backend")) (EListLit)) (EVar "cp")))))) (arm (PVar "missing") () (ERecordCreate "EmissionValidation" ((fa "defects" (EListLit (EApp (EVar "CoreDefect") (EApp (EVar "missingRowsMessage") (EVar "missing"))))) (fa "externFindings" (EListLit))))))))) (arm (PVar "bad") () (ERecordCreate "EmissionValidation" ((fa "defects" (EVar "bad")) (fa "externFindings" (EListLit)))))))
(DTypeSig false "emissionDefects" (TyFun (TyCon "Backend") (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyCon "EmitPlan") (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "CoreDefect")))))))
(DFunDef false "emissionDefects" ((PVar "backend") (PVar "domain") (PVar "plan") (PVar "cp")) (EIf (EBinOp "/=" (EApp (EVar "backendName") (EFieldAccess (EVar "plan") "target")) (EApp (EVar "backendName") (EVar "backend"))) (EListLit (EApp (EVar "CoreDefect") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: emit plan was built for the ")) (EApp (EVar "display") (EApp (EVar "backendName") (EFieldAccess (EVar "plan") "target")))) (ELit (LString " backend but the "))) (EApp (EVar "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString " emitter received it"))))) (EMatch (EApp (EVar "implSymbolCollision") (EVar "cp")) (arm (PCon "Some" (PVar "message")) () (EListLit (EApp (EVar "CoreDefect") (EVar "message")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "dictTagCollision") (EVar "backend")) (EVar "cp")) (arm (PCon "Some" (PVar "message")) () (EListLit (EApp (EVar "CoreDefect") (EVar "message")))) (arm (PCon "None") () (EApp (EVar "firstShapeDefect") (EListLit (ELam ((PLit LUnit)) (EApp (EVar "validateExternMetadata") (EVar "cp"))) (ELam ((PLit LUnit)) (EApp (EApp (EApp (EApp (EVar "validateExternRequirements") (EVar "backend")) (EVar "domain")) (EVar "cp")) (EFieldAccess (EVar "plan") "externRequirements"))) (ELam ((PLit LUnit)) (EApp (EApp (EVar "validateRequirementProjection") (EVar "backend")) (EVar "plan"))) (ELam ((PLit LUnit)) (EApp (EApp (EApp (EVar "validateGlobalInit") (EVar "cp")) (EFieldAccess (EVar "plan") "lazyGlobals")) (EFieldAccess (EVar "plan") "globalInit"))) (ELam ((PLit LUnit)) (EApp (EApp (EApp (EVar "validatePhysicalDemand") (EVar "backend")) (EVar "plan")) (EVar "cp"))) (ELam ((PLit LUnit)) (EApp (EVar "validateRecords") (EVar "cp"))) (ELam ((PLit LUnit)) (EApp (EVar "validateBinderStamps") (EVar "cp"))) (ELam ((PLit LUnit)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "validateScalarOperators") (EVar "cp")) (EApp (EVar "validateCalls") (EVar "cp"))) (EApp (EVar "validateImplSymbols") (EVar "cp"))) (EApp (EVar "validateMethodContexts") (EVar "cp"))) (EApp (EVar "validateDispatchEvidence") (EVar "cp"))) (EApp (EApp (EVar "validateMethodResults") (EVar "plan")) (EVar "cp")))) (ELam ((PLit LUnit)) (EApp (EVar "validateTails") (EVar "cp")))))))))))
(DTypeSig false "firstShapeDefect" (TyFun (TyApp (TyCon "List") (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "CoreDefect"))))
(DFunDef false "firstShapeDefect" ((PList)) (EListLit))
(DFunDef false "firstShapeDefect" ((PCons (PVar "check") (PVar "rest"))) (EMatch (EApp (EVar "check") (ELit LUnit)) (arm (PList) () (EApp (EVar "firstShapeDefect") (EVar "rest"))) (arm (PVar "bad") () (EListLit (EApp (EVar "CoreDefect") (EBinOp "++" (ELit (LString "internal error: ")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "bad"))))))))
(DTypeSig false "validateRequirementProjection" (TyFun (TyCon "Backend") (TyFun (TyCon "EmitPlan") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "validateRequirementProjection" ((PCon "WasmBackend") (PVar "plan")) (EIf (EBinOp "==" (EApp (EApp (EVar "map") (ELam ((PVar "imp")) (ETuple (EFieldAccess (EVar "imp") "medakaName") (ETuple (EFieldAccess (EVar "imp") "jsName") (ETuple (EFieldAccess (EVar "imp") "params") (EFieldAccess (EVar "imp") "result")))))) (EFieldAccess (EVar "plan") "jsImports")) (EApp (EVar "requirementHostRows") (EFieldAccess (EVar "plan") "externRequirements"))) (EListLit) (EListLit (ELit (LString "extern-import-mismatch")))))
(DFunDef false "validateRequirementProjection" (PWild PWild) (EListLit))
(DTypeSig false "validateExternMetadata" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateExternMetadata" ((PAs "cp" (PCon "CProgram" PWild PWild PWild PWild PWild (PVar "facts")))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "use")) (EMatch (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "use") "useSymbol")) (EFieldAccess (EVar "facts") "factExterns")) (arm (PCon "None") () (EListLit (EBinOp "++" (ELit (LString "unknown-extern-declaration: ")) (EFieldAccess (EVar "use") "useSymbol")))) (arm (PCon "Some" (PVar "fact")) () (EMatch (EFieldAccess (EVar "fact") "callableShape") (arm (PCon "None") () (EListLit (EBinOp "++" (ELit (LString "missing-extern-abi: ")) (EFieldAccess (EVar "fact") "symbol")))) (arm (PCon "Some" PWild) () (EListLit))))))) (EApp (EVar "collectExternUses") (EVar "cp"))))
(DTypeSig true "findingExtern" (TyFun (TyCon "ExternFinding") (TyCon "String")))
(DFunDef false "findingExtern" ((PCon "ExternFinding" (PVar "name") PWild PWild PWild PWild)) (EVar "name"))
(DTypeSig true "findingBinding" (TyFun (TyCon "ExternFinding") (TyCon "String")))
(DFunDef false "findingBinding" ((PCon "ExternFinding" PWild PWild PWild PWild (PVar "binding"))) (EVar "binding"))
(DTypeSig true "unprovidedOn" (TyFun (TyCon "Backend") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "GapKind") (TyCon "String"))))))
(DFunDef false "unprovidedOn" ((PCon "LlvmBackend") (PVar "name")) (EMatch (EApp (EVar "catalogRow") (EVar "name")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "notProvidedOf") (EApp (EVar "rowLlvm") (EVar "r")))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "unprovidedOn" ((PCon "WasmBackend") (PVar "name")) (EMatch (EApp (EVar "catalogRow") (EVar "name")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "notProvidedOf") (EApp (EVar "rowWasm") (EVar "r")))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "unprovidedOn" ((PCon "EvalBackend") (PVar "name")) (EMatch (EApp (EVar "catalogRow") (EVar "name")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "notProvidedOf") (EApp (EVar "rowEval") (EVar "r")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "notProvidedOf" (TyFun (TyApp (TyCon "Disposition") (TyVar "f")) (TyApp (TyCon "Option") (TyTuple (TyCon "GapKind") (TyCon "String")))))
(DFunDef false "notProvidedOf" ((PCon "NotProvided" (PVar "kind") (PVar "why"))) (EApp (EVar "Some") (ETuple (EVar "kind") (EVar "why"))))
(DFunDef false "notProvidedOf" (PWild) (EVar "None"))
(DTypeSig true "isUnprovidedOn" (TyFun (TyCon "Backend") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isUnprovidedOn" ((PVar "backend") (PVar "name")) (EApp (EVar "isSome") (EApp (EApp (EVar "unprovidedOn") (EVar "backend")) (EVar "name"))))
(DTypeSig true "validateExterns" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "ExternFinding"))))))
(DFunDef false "validateExterns" ((PVar "backend") (PVar "runtimeExterns") (PVar "prog")) (EBlock (DoLet false false PWild (EApp (EVar "refuseMissingRows") (EVar "runtimeExterns"))) (DoExpr (EMatch (EApp (EApp (EVar "walkProgram") (EVar "backend")) (EVar "prog")) (arm (PCon "Walk" PWild (PVar "found") PWild PWild PWild PWild PWild PWild) () (EApp (EVar "reverseL") (EVar "found")))))))
(DTypeSig true "validateRecords" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateRecords" ((PVar "prog")) (EMatch (EApp (EApp (EVar "walkProgram") (EVar "LlvmBackend")) (EVar "prog")) (arm (PCon "Walk" PWild PWild (PVar "bad") PWild PWild PWild PWild PWild) () (EApp (EVar "reverseL") (EVar "bad")))))
(DTypeSig true "renderRecordRefusal" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "renderRecordRefusal" ((PVar "bad")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "bad")))
(DTypeSig true "validateCalls" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateCalls" ((PAs "prog" (PCon "CProgram" PWild PWild PWild (PVar "impls") PWild PWild))) (EMatch (EApp (EApp (EVar "walkProgram") (EVar "LlvmBackend")) (EVar "prog")) (arm (PCon "Walk" PWild PWild PWild PWild (PVar "bad") PWild PWild PWild) () (EBinOp "++" (EApp (EVar "reverseL") (EVar "bad")) (EApp (EApp (EApp (EVar "splitGroupFaults") (EVar "impls")) (EVar "omEmpty")) (EListLit))))))
(DTypeSig true "validateScalarOperators" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateScalarOperators" ((PVar "prog")) (EMatch (EApp (EApp (EVar "walkProgram") (EVar "LlvmBackend")) (EVar "prog")) (arm (PCon "Walk" PWild PWild PWild (PVar "bad") PWild PWild PWild PWild) () (EApp (EVar "reverseL") (EVar "bad")))))
(DTypeSig false "splitGroupFaults" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "splitGroupFaults" ((PList) PWild (PVar "acc")) (EApp (EVar "reverseL") (EVar "acc")))
(DFunDef false "splitGroupFaults" ((PCons (PAs "ent" (PCon "CImplEntry" (PVar "method") PWild PWild (PVar "body"))) (PVar "rest")) (PVar "seen") (PVar "acc")) (EBlock (DoLet false false (PTuple (PVar "key") (PVar "n")) (EApp (EVar "entryArityRow") (EVar "ent"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "seen")) (arm (PCon "Some" (PVar "k")) () (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EApp (EApp (EVar "splitGroupFaults") (EVar "rest")) (EVar "seen")) (EVar "acc")) (EApp (EApp (EApp (EVar "splitGroupFaults") (EVar "rest")) (EVar "seen")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "call: impl entry takes ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " value parameters, the first entry of its group "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString " [in impl "))) (EApp (EVar "display") (EVar "method"))) (ELit (LString "@"))) (EApp (EVar "display") (EApp (EVar "implBodyTag") (EVar "body")))) (ELit (LString "]"))) (EVar "acc"))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "splitGroupFaults") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "n")) (EVar "seen"))) (EVar "acc")))))))
(DTypeSig true "validateMethodResults" (TyFun (TyCon "EmitPlan") (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "validateMethodResults" ((PVar "plan") (PAs "prog" (PCon "CProgram" PWild PWild PWild (PVar "impls") PWild (PVar "facts")))) (EBlock (DoLet false false (PVar "index") (EApp (EVar "indexMethodResults") (EFieldAccess (EVar "facts") "factMethodResults"))) (DoLet false false (PVar "rowsBad") (EApp (EApp (EApp (EVar "methodResultRows") (EFieldAccess (EVar "facts") "factMethodResults")) (EVar "omEmpty")) (EListLit))) (DoLet false true (PVar "keys") (ELam ((PVar "idx")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "iface")) (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EApp (EApp (EVar "ifaceMethodArityKey") (EVar "iface")) (EVar "m")))) (EApp (EVar "omKeys") (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EVar "iface")) (EVar "idx"))))))) (EApp (EVar "omKeys") (EVar "idx"))))) (DoLet false false (PVar "planBad") (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "keys") (EVar "index")) (EApp (EVar "keys") (EFieldAccess (EVar "plan") "methodResults"))) (EApp (EApp (EVar "all") (EApp (EVar "methodResultMatches") (EFieldAccess (EVar "plan") "methodResults"))) (EFieldAccess (EVar "facts") "factMethodResults"))) (EListLit) (EListLit (ELit (LString "method result: emit plan index disagrees with declaration facts"))))) (DoLet false false (PVar "refsBad") (EMatch (EApp (EApp (EVar "walkProgram") (EVar "LlvmBackend")) (EVar "prog")) (arm (PCon "Walk" PWild PWild PWild PWild PWild PWild PWild (PVar "bad")) () (EApp (EVar "reverseL") (EVar "bad"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "rowsBad") (EVar "planBad")) (EVar "refsBad")) (EApp (EApp (EVar "flatMap") (EApp (EVar "entryMethodResult") (EVar "index"))) (EVar "impls"))))))
(DTypeSig false "methodResultMatches" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact"))) (TyFun (TyCon "MethodResultFact") (TyCon "Bool"))))
(DFunDef false "methodResultMatches" ((PVar "index") (PVar "row")) (EBinOp "==" (EApp (EApp (EApp (EVar "lookupMethodResult") (EVar "index")) (EFieldAccess (EVar "row") "iface")) (EFieldAccess (EVar "row") "method")) (EApp (EVar "Some") (EVar "row"))))
(DTypeSig false "methodResultRows" (TyFun (TyApp (TyCon "List") (TyCon "MethodResultFact")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "methodResultRows" ((PList) PWild (PVar "bad")) (EApp (EVar "reverseL") (EVar "bad")))
(DFunDef false "methodResultRows" ((PCons (PVar "row") (PVar "rest")) (PVar "seen") (PVar "bad")) (EBlock (DoLet false false (PVar "methods") (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "row") "iface")) (EVar "seen")))) (DoLet false false (PVar "why") (EIf (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "row") "iface") (ELit (LString ""))) (EBinOp "==" (EFieldAccess (EVar "row") "method") (ELit (LString "")))) (ELit (LString "empty interface or method key")) (EIf (EApp (EApp (EVar "omHasKey") (EFieldAccess (EVar "row") "method")) (EVar "methods")) (ELit (LString "duplicate qualified key")) (EIf (EBinOp "<" (EFieldAccess (EVar "row") "valueArity") (ELit (LInt 0))) (ELit (LString "negative value arity")) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "callbackPositionsValid") (EFieldAccess (EVar "row") "valueArity")) (EUnOp "-" (ELit (LInt 1)))) (EFieldAccess (EVar "row") "callbackPositions"))) (ELit (LString "invalid callback position")) (ELit (LString ""))))))) (DoExpr (EApp (EApp (EApp (EVar "methodResultRows") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "row") "iface")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "row") "method")) (ELit LUnit)) (EVar "methods"))) (EVar "seen"))) (EIf (EBinOp "==" (EVar "why") (ELit (LString ""))) (EVar "bad") (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method result: ")) (EApp (EVar "display") (EVar "why"))) (ELit (LString " ["))) (EApp (EVar "display") (EFieldAccess (EVar "row") "iface"))) (ELit (LString "#"))) (EApp (EVar "display") (EFieldAccess (EVar "row") "method"))) (ELit (LString "]"))) (EVar "bad")))))))
(DTypeSig false "callbackPositionsValid" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool")))))
(DFunDef false "callbackPositionsValid" (PWild PWild (PList)) (EVar "True"))
(DFunDef false "callbackPositionsValid" ((PVar "arity") (PVar "prev") (PCons (PVar "n") (PVar "ns"))) (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "n") (EVar "prev")) (EBinOp "<" (EVar "n") (EVar "arity"))) (EApp (EApp (EApp (EVar "callbackPositionsValid") (EVar "arity")) (EVar "n")) (EVar "ns"))))
(DTypeSig false "entryMethodResult" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact"))) (TyFun (TyCon "CImplEntry") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "entryMethodResult" ((PVar "index") (PCon "CImplEntry" (PVar "method") PWild (PVar "declared") (PCon "CImplTagged" PWild PWild (PVar "iface") PWild PWild PWild PWild))) (EApp (EApp (EApp (EApp (EVar "entryMethodResultFact") (EVar "index")) (EVar "iface")) (EVar "method")) (EVar "declared")))
(DFunDef false "entryMethodResult" ((PVar "index") (PCon "CImplEntry" (PVar "method") PWild (PVar "declared") (PCon "CImplDefault" (PVar "iface") PWild PWild PWild PWild PWild PWild))) (EApp (EApp (EApp (EApp (EVar "entryMethodResultFact") (EVar "index")) (EVar "iface")) (EVar "method")) (EVar "declared")))
(DTypeSig false "entryMethodResultFact" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "entryMethodResultFact" ((PVar "index") (PVar "iface") (PVar "method") (PVar "declared")) (EMatch (EApp (EApp (EApp (EVar "lookupMethodResult") (EVar "index")) (EVar "iface")) (EVar "method")) (arm (PCon "Some" (PVar "row")) () (EIf (EBinOp "==" (EFieldAccess (EVar "row") "valueArity") (EVar "declared")) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method result: fact value arity ")) (EApp (EVar "display") (EApp (EVar "intToString") (EFieldAccess (EVar "row") "valueArity")))) (ELit (LString " disagrees with Core impl entry declared value arity "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "declared")))) (ELit (LString " ["))) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "#"))) (EApp (EVar "display") (EVar "method"))) (ELit (LString "]")))))) (arm (PCon "None") () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method result: missing declaration fact [")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "#"))) (EApp (EVar "display") (EVar "method"))) (ELit (LString "]")))))))
(DTypeSig false "missingMethodResult" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "missingMethodResult" ((PVar "index") (PVar "iface") (PVar "method")) (EMatch (EApp (EApp (EApp (EVar "lookupMethodResult") (EVar "index")) (EVar "iface")) (EVar "method")) (arm (PCon "Some" PWild) () (EListLit)) (arm (PCon "None") () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method result: missing declaration fact [")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "#"))) (EApp (EVar "display") (EVar "method"))) (ELit (LString "]")))))))
(DTypeSig false "noteMethodResult" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "noteMethodResult" (PWild PWild (PLit (LString "")) (PVar "w")) (EVar "w"))
(DFunDef false "noteMethodResult" ((PCon "Ctx" PWild PWild PWild PWild PWild (PVar "facts") PWild) (PVar "method") (PVar "iface") (PCon "Walk" (PVar "seen") (PVar "found") (PVar "bad") (PVar "scalar") (PVar "calls") (PVar "ctxs") (PVar "evs") (PVar "results"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "seen")) (EVar "found")) (EVar "bad")) (EVar "scalar")) (EVar "calls")) (EVar "ctxs")) (EVar "evs")) (EBinOp "++" (EApp (EApp (EApp (EVar "missingMethodResult") (EFieldAccess (EVar "facts") "efMethods")) (EVar "iface")) (EVar "method")) (EVar "results"))))
(DTypeSig true "validateMethodContexts" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateMethodContexts" ((PAs "prog" (PCon "CProgram" PWild PWild PWild (PVar "impls") (PVar "mctx") (PVar "facts")))) (EMatch (EApp (EApp (EVar "walkProgram") (EVar "LlvmBackend")) (EVar "prog")) (arm (PCon "Walk" PWild PWild PWild PWild PWild (PVar "bad") PWild PWild) () (EBinOp "++" (EApp (EVar "reverseL") (EVar "bad")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "entryContextFaults") (EApp (EApp (EVar "omFromPairs") (EVar "mctx")) (EVar "omEmpty"))) (EApp (EApp (EVar "omFromPairs") (EFieldAccess (EVar "facts") "factRequires")) (EVar "omEmpty")))) (EVar "impls"))))))
(DTypeSig false "entryContextFaults" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CImplEntry") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "entryContextFaults" ((PVar "table") (PVar "reqs") (PCon "CImplEntry" (PVar "method") PWild PWild (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") PWild PWild (PVar "pats") PWild))) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EApp (EVar "declaredMethodContext") (EVar "table")) (EVar "iface")) (EVar "method"))) (DoLet false false (PVar "r") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "reqs")))) (DoLet false false (PVar "n") (EApp (EApp (EApp (EVar "leadingMethodDicts") (EVar "method")) (ELit (LInt 0))) (EVar "pats"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "k")) (EBinOp "==" (EVar "n") (EBinOp "+" (EVar "k") (EVar "r")))) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method context: impl entry opens with ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " `$dict_"))) (EApp (EVar "display") (EVar "method"))) (ELit (LString "_k` parameters, `"))) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "` declares "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString " and its instance requires "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "r")))) (ELit (LString " [in impl "))) (EApp (EVar "display") (EVar "method"))) (ELit (LString "@"))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString "]"))))))))
(DFunDef false "entryContextFaults" ((PVar "table") PWild (PCon "CImplEntry" (PVar "method") PWild PWild (PCon "CImplDefault" (PVar "iface") (PVar "tag") PWild PWild PWild (PVar "pats") PWild))) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EApp (EVar "declaredMethodContext") (EVar "table")) (EVar "iface")) (EVar "method"))) (DoLet false false (PVar "n") (EApp (EApp (EApp (EVar "leadingMethodDicts") (EVar "method")) (ELit (LInt 0))) (EVar "pats"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method context: default entry opens with ")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " `$dict_"))) (EApp (EVar "display") (EVar "method"))) (ELit (LString "_k` parameters, `"))) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "` declares "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString " and a receiver [in impl "))) (EApp (EVar "display") (EVar "method"))) (ELit (LString "@"))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString "]"))))))))
(DTypeSig false "declaredMethodContext" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Int")))))
(DFunDef false "declaredMethodContext" ((PVar "table") (PVar "iface") (PVar "method")) (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "ifaceMethodArityKey") (EVar "iface")) (EVar "method"))) (EVar "table"))))
(DTypeSig false "leadingMethodDicts" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))
(DFunDef false "leadingMethodDicts" ((PVar "method") (PVar "k") (PCons (PCon "PVar" (PVar "x") PWild PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "x") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "$dict_")) (EApp (EVar "display") (EVar "method"))) (ELit (LString "_"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString "")))) (EApp (EApp (EApp (EVar "leadingMethodDicts") (EVar "method")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "rest")) (EVar "k")))
(DFunDef false "leadingMethodDicts" (PWild (PVar "k") PWild) (EVar "k"))
(DTypeSig true "validateImplSymbols" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateImplSymbols" ((PCon "CProgram" PWild PWild PWild (PVar "impls") PWild PWild)) (EApp (EApp (EVar "flatMap") (EVar "implSymbolFaults")) (EVar "impls")))
(DTypeSig false "implSymbolFaults" (TyFun (TyCon "CImplEntry") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "implSymbolFaults" ((PCon "CImplEntry" (PVar "method") PWild PWild (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PCon "ImplSym" (PVar "sym") PWild PWild) PWild PWild PWild))) (EBinOp "++" (EIf (EBinOp "==" (EVar "sym") (ELit (LString ""))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl symbol: entry has no stamped symbol [in impl ")) (EApp (EVar "display") (EVar "method"))) (ELit (LString "@"))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString "]")))) (EListLit)) (EIf (EBinOp "==" (EVar "iface") (EApp (EVar "ifaceWordOfKey") (EVar "key"))) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl symbol: interface word `")) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "` is not the qualified word `"))) (EApp (EVar "display") (EApp (EVar "ifaceWordOfKey") (EVar "key")))) (ELit (LString "` of its key [in impl "))) (EApp (EVar "display") (EVar "method"))) (ELit (LString "@"))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString "]")))))))
(DFunDef false "implSymbolFaults" ((PCon "CImplEntry" (PVar "method") PWild PWild (PCon "CImplDefault" PWild (PVar "tag") PWild (PCon "ImplSym" (PVar "sym") (PVar "ifaceTag") (PVar "keyTag")) PWild PWild PWild))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "sym") (ELit (LString ""))) (EBinOp "==" (EVar "ifaceTag") (ELit (LString "")))) (EBinOp "==" (EVar "keyTag") (ELit (LString "")))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl symbol: default entry has no stamped symbol [in impl ")) (EApp (EVar "display") (EVar "method"))) (ELit (LString "@"))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString "]")))) (EListLit)))
(DTypeSig true "validateImplSymbolInjectivity" (TyFun (TyCon "CProgram") (TyCon "Unit")))
(DFunDef false "validateImplSymbolInjectivity" ((PVar "cp")) (EMatch (EApp (EVar "implSymbolCollision") (EVar "cp")) (arm (PCon "Some" (PVar "message")) () (EApp (EVar "panic") (EVar "message"))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "implSymbolCollision" (TyFun (TyCon "CProgram") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "implSymbolCollision" ((PCon "CProgram" PWild PWild PWild (PVar "impls") PWild PWild)) (EApp (EApp (EVar "checkImplSymbolsInjective") (EApp (EApp (EVar "dedupBy") (EVar "implPreImageKey")) (EApp (EApp (EVar "flatMap") (EVar "taggedImplSymRow")) (EVar "impls")))) (EVar "omEmpty")))
(DTypeSig false "taggedImplSymRow" (TyFun (TyCon "CImplEntry") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))
(DFunDef false "taggedImplSymRow" ((PCon "CImplEntry" (PVar "m") PWild PWild (PCon "CImplTagged" PWild (PVar "key") PWild (PCon "ImplSym" (PVar "tag") PWild PWild) PWild PWild PWild))) (EListLit (ETuple (EVar "m") (EVar "tag") (EVar "key"))))
(DFunDef false "taggedImplSymRow" (PWild) (EListLit))
(DTypeSig false "implPreImageKey" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "implPreImageKey" ((PTuple (PVar "m") (PVar "tag") (PVar "key"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "key"))) (ELit (LString ""))))
(DTypeSig false "checkImplSymbolsInjective" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "checkImplSymbolsInjective" ((PList) PWild) (EVar "None"))
(DFunDef false "checkImplSymbolsInjective" ((PCons (PTuple (PVar "m") (PVar "tag") (PVar "key")) (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "sym") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "mdk_impl_")) (EApp (EVar "display") (EVar "tag"))) (ELit (LString "_"))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "sym")) (EVar "seen")) (arm (PCon "None") () (EApp (EApp (EVar "checkImplSymbolsInjective") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "sym")) (EVar "key")) (EVar "seen")))) (arm (PCon "Some" (PVar "prev")) () (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "emitted impl-symbol collision: two DISTINCT impls of method `")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "` are emitted under one symbol.\ncollided symbol: "))) (EApp (EVar "display") (EVar "sym"))) (ELit (LString "\nimpl 1 key: "))) (EApp (EVar "display") (EVar "prev"))) (ELit (LString "\nimpl 2 key: "))) (EApp (EVar "display") (EVar "key"))) (ELit (LString "\nTwo distinct impls cannot share one emitted symbol: the backend would define one body twice (the native link fails) or keep one and silently drop the other. The two keys above are the impls' canonical dispatch keys, spelled `<module>::<Interface>|<type arguments>|`. Since #1950 those keys are spelled into the symbol by `private_mangle.injectiveIdent`, which is INJECTIVE, so this is NOT a naming mistake you can rename your way out of -- it means the emitted-symbol scheme itself lost injectivity. Please report this message, with both keys above.")))))))))
(DTypeSig true "validateDictTags" (TyFun (TyCon "Backend") (TyFun (TyCon "CProgram") (TyCon "Unit"))))
(DFunDef false "validateDictTags" ((PVar "backend") (PVar "cp")) (EMatch (EApp (EApp (EVar "dictTagCollision") (EVar "backend")) (EVar "cp")) (arm (PCon "Some" (PVar "message")) () (EApp (EVar "panic") (EVar "message"))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "dictTagCollision" (TyFun (TyCon "Backend") (TyFun (TyCon "CProgram") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "dictTagCollision" ((PVar "backend") (PCon "CProgram" PWild PWild PWild (PVar "impls") PWild PWild)) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "dedupBy") (EVar "dictRouteWordKey")) (EApp (EApp (EVar "map") (EVar "dictRouteWordRow")) (EVar "impls")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "checkDictTagsInjective") (EVar "nativeDictTagSpace")) (EVar "hashName")) (EVar "rows")) (EVar "omEmpty")) (arm (PCon "Some" (PVar "message")) () (EApp (EVar "Some") (EVar "message"))) (arm (PCon "None") () (EMatch (EVar "backend") (arm (PCon "LlvmBackend") () (EVar "None")) (arm (PCon "WasmBackend") () (EApp (EApp (EApp (EApp (EVar "checkDictTagsInjective") (EVar "wasmDictTagSpace")) (EVar "dictTag")) (EVar "rows")) (EVar "omEmpty"))) (arm (PCon "EvalBackend") () (EVar "None"))))))))
(DTypeSig false "nativeDictTagSpace" (TyCon "String"))
(DFunDef false "nativeDictTagSpace" () (ELit (LString "native (LLVM) i64 dict-witness word `hashName` -- BOTH backends, since the wasm tag is this hash masked")))
(DTypeSig false "wasmDictTagSpace" (TyCon "String"))
(DFunDef false "wasmDictTagSpace" () (ELit (LString "wasm (WasmGC) 30-bit i31 dict tag `dictTag` (`hashName` masked to the low 30 bits) -- the full i64 tags are DISTINCT, so a native build of this program is correct; the wasm tag is this hash masked to a narrower width, which collides")))
(DTypeSig false "dictRouteWordRow" (TyFun (TyCon "CImplEntry") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "dictRouteWordRow" ((PCon "CImplEntry" (PVar "m") PWild PWild (PCon "CImplTagged" PWild (PVar "key") PWild PWild PWild PWild PWild))) (ETuple (EVar "m") (EVar "key")))
(DFunDef false "dictRouteWordRow" ((PCon "CImplEntry" (PVar "m") PWild PWild (PCon "CImplDefault" PWild PWild (PVar "key") PWild PWild PWild PWild))) (ETuple (EVar "m") (EVar "key")))
(DTypeSig false "dictRouteWordKey" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "dictRouteWordKey" ((PTuple (PVar "m") (PVar "w"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "w"))) (ELit (LString ""))))
(DTypeSig false "checkDictTagsInjective" (TyFun (TyCon "String") (TyFun (TyFun (TyCon "String") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "checkDictTagsInjective" (PWild PWild (PList) PWild) (EVar "None"))
(DFunDef false "checkDictTagsInjective" ((PVar "space") (PVar "hash") (PCons (PTuple (PVar "m") (PVar "w")) (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "intToString") (EApp (EVar "hash") (EVar "w")))) (DoLet false false (PVar "k") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "t"))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "seen")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "checkDictTagsInjective") (EVar "space")) (EVar "hash")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (EVar "w")) (EVar "seen")))) (arm (PCon "Some" (PVar "w0")) () (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "emitted dict-witness tag collision: two DISTINCT impls of method `")) (EApp (EVar "display") (EVar "m"))) (ELit (LString "` hash to one dispatch tag.\ntag space: "))) (EApp (EVar "display") (EVar "space"))) (ELit (LString "\ncollided tag: "))) (EApp (EVar "display") (EVar "t"))) (ELit (LString "\nroute word 1: "))) (EApp (EVar "display") (EVar "w0"))) (ELit (LString "\nroute word 2: "))) (EApp (EVar "display") (EVar "w"))) (ELit (LString "\nA dict witness carries this tag, and method `"))) (EApp (EVar "display") (EVar "m"))) (ELit (LString "`'s shared dispatcher selects an impl by comparing it against every OTHER impl of that SAME method name -- these two words ARE compared against each other at that dispatcher, so this collision is live: whichever arm the emitter happened to emit FIRST wins every call through a dictionary, silently, at exit 0. The two words above are the impls' route words: either a bare head tycon or a canonical dispatch key spelled `<module>::<Interface>|<type arguments>|`. This is NOT a naming collision you can rename your way out of by making the names more different -- `hashName` is djb2, a radix-33 polynomial over a 74-code-point alphabet, so it is genuinely non-injective (`hashName \"Az\" == hashName \"BY\"`). One of the two words above may name a type or interface from the prelude or stdlib that you do not own -- rename the OTHER one, one of your own types or interfaces involved in this collision. Please also report this message, with both words above.")))))))))
(DTypeSig false "implBodyTag" (TyFun (TyCon "CImplBody") (TyCon "String")))
(DFunDef false "implBodyTag" ((PCon "CImplTagged" (PVar "tag") PWild PWild PWild PWild PWild PWild)) (EVar "tag"))
(DFunDef false "implBodyTag" ((PCon "CImplDefault" PWild (PVar "tag") PWild PWild PWild PWild PWild)) (EVar "tag"))
(DTypeSig true "renderCallRefusal" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "renderCallRefusal" ((PVar "bad")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "bad")))
(DTypeSig true "missingCatalogRows" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "missingCatalogRows" ((PVar "names")) (EApp (EApp (EVar "filter") (ELam ((PVar "n")) (EApp (EVar "isNone") (EApp (EVar "catalogRow") (EVar "n"))))) (EVar "names")))
(DTypeSig true "missingRowsMessage" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "missingRowsMessage" ((PVar "missing")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "quoteName")) (EVar "missing")))) (DoExpr (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: runtime extern ")) (EApp (EVar "display") (EVar "names"))) (ELit (LString " has no row in the extern catalog (compiler/backend/extern_catalog.mdk)"))))))
(DTypeSig false "quoteName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoteName" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EVar "n")) (ELit (LString "'"))))
(DTypeSig false "refuseMissingRows" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))
(DFunDef false "refuseMissingRows" ((PVar "names")) (EMatch (EApp (EVar "missingCatalogRows") (EVar "names")) (arm (PList) () (ELit LUnit)) (arm (PVar "missing") () (EApp (EVar "panic") (EApp (EVar "missingRowsMessage") (EVar "missing"))))))
(DTypeSig true "renderExternFinding" (TyFun (TyCon "ExternFinding") (TyCon "String")))
(DFunDef false "renderExternFinding" ((PCon "ExternFinding" (PVar "name") (PVar "backend") (PVar "kind") (PVar "why") (PVar "binding"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString ": runtime extern '"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "' is not available on the "))) (EApp (EVar "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString " backend ("))) (EApp (EVar "display") (EApp (EVar "gapKindName") (EVar "kind")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "why"))) (ELit (LString ") [in "))) (EApp (EVar "display") (EVar "binding"))) (ELit (LString "]"))))
(DTypeSig true "renderExternRefusal" (TyFun (TyApp (TyCon "List") (TyCon "ExternFinding")) (TyCon "String")))
(DFunDef false "renderExternRefusal" ((PVar "findings")) (EApp (EApp (EVar "renderExternRefusalUnder") (EUnOp "!" (EVar "checkedTarget"))) (EVar "findings")))
(DTypeSig true "renderExternRefusalUnder" (TyFun (TyApp (TyCon "Option") (TyCon "CheckedTarget")) (TyFun (TyApp (TyCon "List") (TyCon "ExternFinding")) (TyCon "String"))))
(DFunDef false "renderExternRefusalUnder" ((PCon "None") (PVar "findings")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EVar "map") (EVar "renderExternFinding")) (EVar "findings"))))
(DFunDef false "renderExternRefusalUnder" ((PCon "Some" (PVar "t")) (PVar "findings")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EVar "map") (EApp (EVar "renderFindingUnder") (EVar "t"))) (EVar "findings"))))
(DTypeSig false "renderFindingUnder" (TyFun (TyCon "CheckedTarget") (TyFun (TyCon "ExternFinding") (TyCon "String"))))
(DFunDef false "renderFindingUnder" ((PCon "CheckedTarget" (PVar "profile") (PVar "labels")) (PAs "f" (PCon "ExternFinding" (PVar "name") (PVar "backend") PWild PWild PWild))) (EBlock (DoLet false false (PVar "declared") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "labels")))) (DoLet false false (PVar "withheldNote") (EMatch (EApp (EApp (EVar "withheldLabels") (EVar "profile")) (EVar "declared")) (arm (PList) () (ELit (LString ""))) (arm (PVar "withheld") () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "; the target `")) (EApp (EVar "display") (EApp (EVar "profileName") (EVar "profile")))) (ELit (LString "` does not grant "))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "withheld")))) (ELit (LString ", which `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` performs")))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "renderExternFinding") (EVar "f")))) (ELit (LString ""))) (EApp (EVar "display") (EVar "withheldNote"))) (ELit (LString "; "))) (EApp (EVar "display") (EApp (EVar "checkMissedNote") (EVar "backend")))) (ELit (LString ""))))))
(DTypeSig false "checkMissedNote" (TyFun (TyCon "Backend") (TyCon "String")))
(DFunDef false "checkMissedNote" ((PVar "backend")) (EBinOp "++" (EBinOp "++" (ELit (LString "`check` should have refused this program before the ")) (EApp (EVar "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString " backend saw it, so this is a bug in the compiler"))))
(DData Public "CheckedTarget" () ((variant "CheckedTarget" (ConPos (TyCon "TargetProfile") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig true "checkedTargetOf" (TyFun (TyCon "TargetProfile") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "CheckedTarget"))))
(DFunDef false "checkedTargetOf" ((PVar "profile") (PVar "runtimeDecls")) (EApp (EApp (EVar "CheckedTarget") (EVar "profile")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "externLabels") (EVar "runtimeDecls"))) (EVar "omEmpty"))))
(DTypeSig true "checkedTarget" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "CheckedTarget"))))
(DFunDef false "checkedTarget" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "externLabels" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "externLabels" ((PList)) (EListLit))
(DFunDef false "externLabels" ((PCons (PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n")) (rf "edTy" (PVar "ty"))) true)) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EVar "resultLabels") (EVar "ty"))) (EApp (EVar "externLabels") (EVar "rest"))))
(DFunDef false "externLabels" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "externLabels") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "externLabels" ((PCons PWild (PVar "rest"))) (EApp (EVar "externLabels") (EVar "rest")))
(DTypeSig false "resultLabels" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "resultLabels" ((PCon "TyFun" PWild (PVar "r"))) (EApp (EVar "resultLabels") (EVar "r")))
(DFunDef false "resultLabels" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "resultLabels") (EVar "t")))
(DFunDef false "resultLabels" ((PCon "TyEffect" (PVar "atoms") PWild PWild)) (EApp (EApp (EVar "map") (ELam ((PVar "a")) (EFieldAccess (EVar "a") "eatLabel"))) (EVar "atoms")))
(DFunDef false "resultLabels" (PWild) (EListLit))
(DTypeSig true "unrefusedExternMessage" (TyFun (TyCon "Backend") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "unrefusedExternMessage" ((PVar "backend") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: the ")) (EApp (EVar "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString " emitter reached runtime extern '"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "', which it does not lower, without a refusal from validateExterns (compiler/backend/core_validate.mdk)"))))
(DTypeSig false "programNames" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "programNames" ((PList) (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "programNames" ((PList) (PCons (PTuple (PVar "ctor") PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "programNames") (EListLit)) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "ctor")) (ELit LUnit)) (EVar "acc"))))
(DFunDef false "programNames" ((PCons (PCon "CBind" (PVar "name") PWild PWild PWild) (PVar "rest")) (PVar "ctors") (PVar "acc")) (EApp (EApp (EApp (EVar "programNames") (EVar "rest")) (EVar "ctors")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "acc"))))
(DTypeSig false "isProgramName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isProgramName" ((PVar "top") (PVar "x")) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "top")) (EApp (EApp (EVar "omHasKey") (EBinOp "++" (ELit (LString "core__")) (EVar "x"))) (EVar "top"))))
(DData Private "Walk" () ((variant "Walk" (ConPos (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "ExternFinding")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))) ())
(DTypeSig false "noFindings" (TyCon "Walk"))
(DFunDef false "noFindings" () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "omEmpty")) (EListLit)) (EListLit)) (EListLit)) (EListLit)) (EListLit)) (EListLit)) (EListLit)))
(DData Private "Ctx" () ((variant "Ctx" (ConPos (TyCon "Backend") (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "ArityEnv") (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyCon "EvFacts") (TyCon "String")))) ())
(DData Private "EvFacts" () ((variant "EvFacts" (ConNamed (field "efRequires" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "efSupers" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "efMethods" (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact")))) (field "efExterns" (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")))))) ())
(DTypeSig false "walkProgram" (TyFun (TyCon "Backend") (TyFun (TyCon "CProgram") (TyCon "Walk"))))
(DFunDef false "walkProgram" ((PVar "backend") (PAs "prog" (PCon "CProgram" (PVar "groups") (PVar "ctors") PWild (PVar "impls") (PVar "mctx") (PVar "facts")))) (EBlock (DoLet false false (PVar "top") (EApp (EApp (EApp (EVar "programNames") (EVar "groups")) (EVar "ctors")) (EVar "omEmpty"))) (DoLet false false (PVar "env") (EApp (EVar "programArities") (EVar "prog"))) (DoLet false false (PVar "ctx") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Ctx") (EVar "backend")) (EVar "top")) (EVar "env")) (EApp (EApp (EVar "omFromPairs") (EVar "mctx")) (EVar "omEmpty"))) (EApp (EApp (EVar "dictParamCounts") (EVar "groups")) (EVar "omEmpty"))) (ERecordCreate "EvFacts" ((fa "efRequires" (EApp (EApp (EVar "omFromPairs") (EFieldAccess (EVar "facts") "factRequires")) (EVar "omEmpty"))) (fa "efSupers" (EApp (EApp (EVar "omFromPairs") (EFieldAccess (EVar "facts") "factSupers")) (EVar "omEmpty"))) (fa "efMethods" (EApp (EVar "indexMethodResults") (EFieldAccess (EVar "facts") "factMethodResults"))) (fa "efExterns" (EFieldAccess (EVar "facts") "factExterns"))))) (ELit (LString "")))) (DoExpr (EApp (EApp (EApp (EVar "walkImpls") (EVar "ctx")) (EVar "impls")) (EApp (EApp (EApp (EVar "walkBinds") (EVar "ctx")) (EVar "groups")) (EVar "noFindings"))))))
(DTypeSig false "walkBinds" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyCon "Walk") (TyCon "Walk")))))
(DFunDef false "walkBinds" (PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkBinds" ((PVar "ctx") (PCons (PCon "CBind" (PVar "name") (PVar "clauses") PWild PWild) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EVar "walkBinds") (EVar "ctx")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkClauses") (EApp (EApp (EVar "inBinding") (EVar "ctx")) (EVar "name"))) (EVar "omEmpty")) (EVar "clauses")) (EVar "w"))))
(DTypeSig false "walkImpls" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "Walk") (TyCon "Walk")))))
(DFunDef false "walkImpls" (PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkImpls" ((PVar "ctx") (PCons (PCon "CImplEntry" (PVar "method") PWild PWild (PVar "body")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EVar "walkImpls") (EVar "ctx")) (EVar "rest")) (EApp (EApp (EApp (EVar "walkImplBody") (EApp (EApp (EVar "inBinding") (EVar "ctx")) (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EVar "display") (EVar "method"))) (ELit (LString ""))))) (EVar "body")) (EVar "w"))))
(DTypeSig false "inBinding" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyCon "Ctx"))))
(DFunDef false "inBinding" ((PCon "Ctx" (PVar "backend") (PVar "top") (PVar "env") (PVar "mctx") (PVar "dcounts") (PVar "facts") PWild) (PVar "binding")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Ctx") (EVar "backend")) (EVar "top")) (EVar "env")) (EVar "mctx")) (EVar "dcounts")) (EVar "facts")) (EVar "binding")))
(DTypeSig false "ctxBinding" (TyFun (TyCon "Ctx") (TyCon "String")))
(DFunDef false "ctxBinding" ((PCon "Ctx" PWild PWild PWild PWild PWild PWild (PVar "binding"))) (EVar "binding"))
(DTypeSig false "walkImplBody" (TyFun (TyCon "Ctx") (TyFun (TyCon "CImplBody") (TyFun (TyCon "Walk") (TyCon "Walk")))))
(DFunDef false "walkImplBody" ((PVar "ctx") (PCon "CImplTagged" (PVar "tag") PWild PWild PWild PWild (PVar "pats") (PVar "body")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EApp (EApp (EVar "inBinding") (EVar "ctx")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "ctxBinding") (EVar "ctx")))) (ELit (LString "@"))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString ""))))) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "omEmpty"))) (EVar "body")) (EVar "w")))
(DFunDef false "walkImplBody" ((PVar "ctx") (PCon "CImplDefault" PWild (PVar "tag") PWild PWild PWild (PVar "pats") (PVar "body")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EApp (EApp (EVar "inBinding") (EVar "ctx")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "ctxBinding") (EVar "ctx")))) (ELit (LString "@"))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString ""))))) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "omEmpty"))) (EVar "body")) (EVar "w")))
(DTypeSig false "walkClauses" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkClauses" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkClauses" ((PVar "ctx") (PVar "scope") (PCons (PCon "CClause" (PVar "pats") (PVar "body")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkClauses") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "scope"))) (EVar "body")) (EVar "w"))))
(DTypeSig false "walkE" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyCon "CExpr") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CVar" (PVar "x") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "noteVar") (EVar "ctx")) (EVar "scope")) (EVar "x")) (EVar "w")))
(DFunDef false "walkE" (PWild PWild (PCon "CLit" PWild) (PVar "w")) (EVar "w"))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CApp" (PVar "f") (PVar "args") (PVar "site")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "args")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "f")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteCall") (EVar "ctx")) (EVar "scope")) (EVar "f")) (EVar "args")) (EVar "site")) (EVar "w")))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CLam" (PVar "pats") (PVar "body")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "scope"))) (EVar "body")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CLet" (PVar "recF") (PVar "pat") (PVar "rhs") (PVar "body")) (PVar "w")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EApp (EVar "bindLetScope") (EVar "pat")) (EVar "rhs")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "inner")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EIf (EVar "recF") (EVar "inner") (EVar "scope"))) (EVar "rhs")) (EVar "w"))))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CLetGroup" (PVar "binds") (PVar "body")) (PVar "w")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindGroupScope") (EVar "binds")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "inner")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkLocalBinds") (EVar "ctx")) (EVar "inner")) (EVar "binds")) (EVar "w"))))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CMatch" (PVar "scrut") (PVar "arms")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "ctx")) (EVar "scope")) (EVar "arms")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "scrut")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "ctx")) (EVar "scope")) (EVar "arms")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "scrut")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "c") (EVar "t") (EVar "f"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "l") (EVar "r"))) (EApp (EApp (EApp (EApp (EVar "noteScalarOperator") (EVar "ctx")) (EVar "op")) (EVar "tag")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CUnOp" PWild (PVar "x")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "x")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CTuple" (PVar "es")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "es")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CList" (PVar "es")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "es")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRecord" (PVar "name") (PVar "fields")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "fields")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteRecord") (EVar "ctx")) (ELit (LString "CRecord"))) (EVar "name")) (EVar "True")) (EVar "fields")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CFieldAccess" (PVar "x") (PVar "label") (PVar "name") (PVar "ord")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "noteAccess") (EVar "ctx")) (EVar "label")) (EVar "name")) (EVar "ord")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "fields")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "base")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteRecord") (EVar "ctx")) (ELit (LString "CRecordUpdate"))) (EVar "name")) (EVar "False")) (EVar "fields")) (EVar "w")))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "fields")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "base")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteRecord") (EVar "ctx")) (ELit (LString "CVariantUpdate"))) (EVar "con")) (EVar "False")) (EVar "fields")) (EVar "w")))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CArray" (PVar "es")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "es")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CIndex" (PVar "a") (PVar "i")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "i"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CStringIndex" (PVar "a") (PVar "i")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "i"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CListIndex" (PVar "a") (PVar "i")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "i"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CBlock" (PVar "stmts")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "scope")) (EVar "stmts")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PAs "node" (PCon "CMethod" (PVar "name") (PCon "MethodEvidence" (PVar "iface") PWild PWild PWild (PVar "meths")))) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "noteEvidence") (EVar "ctx")) (EVar "scope")) (EVar "node")) (EApp (EApp (EApp (EApp (EVar "noteMethodResult") (EVar "ctx")) (EVar "name")) (EVar "iface")) (EApp (EApp (EApp (EApp (EApp (EVar "noteMethodContext") (EVar "ctx")) (EVar "name")) (EVar "iface")) (EApp (EVar "listLen") (EVar "meths"))) (EVar "w")))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PAs "node" (PCon "CDict" PWild PWild)) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "noteEvidence") (EVar "ctx")) (EVar "scope")) (EVar "node")) (EVar "w")))
(DTypeSig false "noteScalarOperator" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "noteScalarOperator" (PWild PWild (PLit (LString "")) (PVar "w")) (EVar "w"))
(DFunDef false "noteScalarOperator" ((PCon "Ctx" PWild PWild PWild PWild PWild PWild (PVar "binding")) (PVar "op") (PVar "tag") (PCon "Walk" (PVar "seen") (PVar "found") (PVar "records") (PVar "scalar") (PVar "calls") (PVar "ctxs") (PVar "evs") (PVar "results"))) (EIf (EApp (EApp (EVar "scalarOperatorTagAllowed") (EVar "op")) (EVar "tag")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "seen")) (EVar "found")) (EVar "records")) (EVar "scalar")) (EVar "calls")) (EVar "ctxs")) (EVar "evs")) (EVar "results")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "seen")) (EVar "found")) (EVar "records")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "scalar binop: operator `")) (EApp (EVar "display") (EVar "op"))) (ELit (LString "` cannot carry scalar tag `"))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString "` [in "))) (EApp (EVar "display") (EVar "binding"))) (ELit (LString "]"))) (EVar "scalar"))) (EVar "calls")) (EVar "ctxs")) (EVar "evs")) (EVar "results"))))
(DTypeSig false "scalarOperatorTagAllowed" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "scalarOperatorTagAllowed" ((PVar "op") (PVar "tag")) (EIf (EApp (EVar "scalarArithmeticOperator") (EVar "op")) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "tag") (ELit (LString "Int"))) (EBinOp "==" (EVar "tag") (ELit (LString "Float")))) (EApp (EVar "isFixedIntHead") (EVar "tag"))) (EIf (EApp (EVar "scalarComparisonOperator") (EVar "op")) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "tag") (ELit (LString "Int"))) (EBinOp "==" (EVar "tag") (ELit (LString "Char")))) (EApp (EVar "isBoxed64Head") (EVar "tag"))) (EVar "False"))))
(DTypeSig false "scalarArithmeticOperator" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "scalarArithmeticOperator" ((PLit (LString "+"))) (EVar "True"))
(DFunDef false "scalarArithmeticOperator" ((PLit (LString "-"))) (EVar "True"))
(DFunDef false "scalarArithmeticOperator" ((PLit (LString "*"))) (EVar "True"))
(DFunDef false "scalarArithmeticOperator" ((PLit (LString "/"))) (EVar "True"))
(DFunDef false "scalarArithmeticOperator" ((PLit (LString "%"))) (EVar "True"))
(DFunDef false "scalarArithmeticOperator" (PWild) (EVar "False"))
(DTypeSig false "scalarComparisonOperator" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "scalarComparisonOperator" ((PLit (LString "=="))) (EVar "True"))
(DFunDef false "scalarComparisonOperator" ((PLit (LString "/="))) (EVar "True"))
(DFunDef false "scalarComparisonOperator" ((PLit (LString "<"))) (EVar "True"))
(DFunDef false "scalarComparisonOperator" ((PLit (LString ">"))) (EVar "True"))
(DFunDef false "scalarComparisonOperator" ((PLit (LString "<="))) (EVar "True"))
(DFunDef false "scalarComparisonOperator" ((PLit (LString ">="))) (EVar "True"))
(DFunDef false "scalarComparisonOperator" (PWild) (EVar "False"))
(DTypeSig true "validateDispatchEvidence" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateDispatchEvidence" ((PVar "prog")) (EMatch (EApp (EApp (EVar "walkProgram") (EVar "LlvmBackend")) (EVar "prog")) (arm (PCon "Walk" PWild PWild PWild PWild PWild PWild (PVar "bad") PWild) () (EApp (EVar "reverseL") (EVar "bad")))))
(DTypeSig false "dictParamCounts" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "dictParamCounts" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "dictParamCounts" ((PCons (PCon "CBind" (PVar "name") (PCons (PCon "CClause" (PVar "pats") PWild) PWild) PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "dictParamCounts") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EApp (EVar "leadingDictParams") (EVar "pats"))) (EVar "acc"))))
(DFunDef false "dictParamCounts" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "dictParamCounts") (EVar "rest")) (EVar "acc")))
(DTypeSig false "noteEvidence" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyCon "CExpr") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "noteEvidence" ((PCon "Ctx" PWild PWild (PVar "env") PWild (PVar "dcounts") (PVar "facts") (PVar "binding")) (PVar "scope") (PVar "node") (PCon "Walk" (PVar "seen") (PVar "found") (PVar "bad") (PVar "scalar") (PVar "calls") (PVar "ctxs") (PVar "evs") (PVar "results"))) (EBlock (DoLet false false (PVar "why") (EApp (EApp (EApp (EApp (EApp (EVar "evidenceFaults") (EVar "env")) (EVar "dcounts")) (EVar "facts")) (EVar "scope")) (EVar "node"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "seen")) (EVar "found")) (EVar "bad")) (EVar "scalar")) (EVar "calls")) (EVar "ctxs")) (EBinOp "++" (EApp (EVar "reverseL") (EApp (EApp (EVar "map") (ELam ((PVar "f")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "dispatch evidence: ")) (EApp (EVar "display") (EApp (EVar "headText") (EVar "node")))) (ELit (LString " "))) (EApp (EVar "display") (EVar "f"))) (ELit (LString " [in "))) (EApp (EVar "display") (EVar "binding"))) (ELit (LString "]"))))) (EVar "why"))) (EVar "evs"))) (EVar "results")))))
(DTypeSig false "evidenceFaults" (TyFun (TyCon "ArityEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "EvFacts") (TyFun (TyCon "CallScope") (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "evidenceFaults" ((PVar "env") PWild (PVar "facts") (PVar "scope") (PAs "node" (PCon "CMethod" (PVar "name") (PCon "MethodEvidence" (PVar "iface") PWild (PVar "route") (PVar "prereqs") (PVar "meths"))))) (EBlock (DoLet false false (PVar "routes") (EBinOp "::" (EVar "route") (EBinOp "++" (EVar "prereqs") (EVar "meths")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "unboundFaults") (EVar "scope")) (EVar "routes")) (EApp (EApp (EVar "flatMap") (EVar "routeShapeFaults")) (EVar "routes"))) (EMatch (EVar "route") (arm (PCon "RKey" (PVar "key") PWild PWild) () (EMatch (EApp (EApp (EApp (EVar "definedArityOf") (EVar "env")) (EVar "scope")) (EVar "node")) (arm (PCon "Some" PWild) () (EListLit)) (arm (PCon "None") () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "names instance `")) (EApp (EVar "display") (EVar "key"))) (ELit (LString "` that has no entry for `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString "`"))))))) (arm PWild () (EListLit)))) (EApp (EApp (EVar "flatMap") (EApp (EVar "builtDictFaults") (EVar "facts"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "headParts") (EVar "route")) (EVar "prereqs")) (EVar "meths")))) (EApp (EApp (EVar "ifaceWordFaults") (EVar "iface")) (EVar "route"))) (EApp (EApp (EVar "methodNoRouteFault") (EVar "iface")) (EVar "route"))))))
(DFunDef false "evidenceFaults" (PWild (PVar "dcounts") (PVar "facts") (PVar "scope") (PCon "CDict" (PVar "f") (PVar "routes"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "unboundFaults") (EVar "scope")) (EVar "routes")) (EApp (EApp (EVar "flatMap") (EVar "routeShapeFaults")) (EVar "routes"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "builtDictFaults") (EVar "facts"))) (EVar "routes"))) (EApp (EApp (EVar "flatMap") (EVar "noRouteFault")) (EVar "routes"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "f")) (EVar "scope")) (EListLit) (EMatch (EApp (EApp (EVar "omLookup") (EVar "f")) (EVar "dcounts")) (arm (PCon "Some" (PVar "k")) () (EIf (EBinOp "==" (EVar "k") (EApp (EVar "listLen") (EVar "routes"))) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "supplies ")) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "routes"))))) (ELit (LString " dictionaries, `"))) (EApp (EVar "display") (EVar "f"))) (ELit (LString "` takes "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString "")))))) (arm (PCon "None") () (EListLit))))))
(DFunDef false "evidenceFaults" (PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "headParts" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route"))))
(DFunDef false "headParts" ((PCon "RKey" PWild (PVar "reqs") (PVar "sups"))) (EBinOp "++" (EVar "reqs") (EVar "sups")))
(DFunDef false "headParts" ((PCon "RLocal" PWild (PVar "ds"))) (EVar "ds"))
(DFunDef false "headParts" ((PCon "RProj" (PVar "r") PWild)) (EListLit (EVar "r")))
(DFunDef false "headParts" (PWild) (EListLit))
(DTypeSig false "builtDictFaults" (TyFun (TyCon "EvFacts") (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "builtDictFaults" ((PVar "facts") (PCon "RKey" (PVar "key") (PVar "reqs") (PVar "sups"))) (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EVar "facts") "efRequires")))) (DoLet false false (PVar "word") (EApp (EVar "ifaceWordOfKey") (EVar "key"))) (DoLet false false (PVar "k") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "word")) (EFieldAccess (EVar "facts") "efSupers")))) (DoExpr (EBinOp "++" (EBinOp "++" (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "reqs")) (EVar "n")) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "builds instance `")) (EApp (EVar "display") (EVar "key"))) (ELit (LString "` from "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "reqs"))))) (ELit (LString " prerequisite dictionaries, it requires "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))))) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "sups")) (EVar "k")) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "builds instance `")) (EApp (EVar "display") (EVar "key"))) (ELit (LString "` with "))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "sups"))))) (ELit (LString " super dictionaries, `"))) (EApp (EVar "display") (EVar "word"))) (ELit (LString "` has "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString "")))))) (EApp (EApp (EVar "flatMap") (EApp (EVar "builtDictFaults") (EVar "facts"))) (EBinOp "++" (EVar "reqs") (EVar "sups")))))))
(DFunDef false "builtDictFaults" ((PVar "facts") (PCon "RLocal" PWild (PVar "ds"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "builtDictFaults") (EVar "facts"))) (EVar "ds")))
(DFunDef false "builtDictFaults" ((PVar "facts") (PCon "RProj" (PVar "r") PWild)) (EApp (EApp (EVar "builtDictFaults") (EVar "facts")) (EVar "r")))
(DFunDef false "builtDictFaults" (PWild PWild) (EListLit))
(DTypeSig false "ifaceWordFaults" (TyFun (TyCon "String") (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ifaceWordFaults" ((PLit (LString "")) (PCon "RKey" PWild PWild PWild)) (EListLit (ELit (LString "dispatches with no interface word"))))
(DFunDef false "ifaceWordFaults" ((PLit (LString "")) (PCon "RDict" PWild)) (EListLit (ELit (LString "dispatches with no interface word"))))
(DFunDef false "ifaceWordFaults" ((PLit (LString "")) (PCon "RDictFwd" PWild)) (EListLit (ELit (LString "dispatches with no interface word"))))
(DFunDef false "ifaceWordFaults" ((PLit (LString "")) (PCon "RProj" PWild PWild)) (EListLit (ELit (LString "dispatches with no interface word"))))
(DFunDef false "ifaceWordFaults" (PWild PWild) (EListLit))
(DTypeSig false "methodNoRouteFault" (TyFun (TyCon "String") (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "methodNoRouteFault" ((PLit (LString "")) PWild) (EListLit))
(DFunDef false "methodNoRouteFault" (PWild (PCon "RNone")) (EListLit (ELit (LString "has no route"))))
(DFunDef false "methodNoRouteFault" (PWild PWild) (EListLit))
(DTypeSig false "noRouteFault" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "noRouteFault" ((PCon "RNone")) (EListLit (ELit (LString "has a dictionary slot with no route"))))
(DFunDef false "noRouteFault" (PWild) (EListLit))
(DTypeSig false "unboundFaults" (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "unboundFaults" ((PVar "scope") (PVar "routes")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "d")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "d")) (EVar "scope")) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "reads dictionary `")) (EApp (EVar "display") (EVar "d"))) (ELit (LString "`, which is not bound here"))))))) (EApp (EApp (EVar "flatMap") (EVar "givenNames")) (EVar "routes"))))
(DTypeSig false "routeShapeFaults" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "routeShapeFaults" ((PCon "RScalar" (PVar "tag"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "carries scalar route `")) (EApp (EVar "display") (EVar "tag"))) (ELit (LString "`")))))
(DFunDef false "routeShapeFaults" ((PCon "RProj" (PVar "r") PWild)) (EBinOp "++" (EIf (EApp (EVar "givenRooted") (EVar "r")) (EListLit) (EListLit (ELit (LString "projects from a route that is not a given dictionary")))) (EApp (EVar "routeShapeFaults") (EVar "r"))))
(DFunDef false "routeShapeFaults" ((PCon "RKey" PWild (PVar "reqs") (PVar "sups"))) (EApp (EApp (EVar "flatMap") (EVar "routeShapeFaults")) (EBinOp "++" (EVar "reqs") (EVar "sups"))))
(DFunDef false "routeShapeFaults" ((PCon "RLocal" PWild (PVar "ds"))) (EApp (EApp (EVar "flatMap") (EVar "routeShapeFaults")) (EVar "ds")))
(DFunDef false "routeShapeFaults" (PWild) (EListLit))
(DTypeSig false "givenRooted" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "givenRooted" ((PCon "RDict" PWild)) (EVar "True"))
(DFunDef false "givenRooted" ((PCon "RDictFwd" PWild)) (EVar "True"))
(DFunDef false "givenRooted" ((PCon "RProj" (PVar "r") PWild)) (EApp (EVar "givenRooted") (EVar "r")))
(DFunDef false "givenRooted" (PWild) (EVar "False"))
(DTypeSig false "noteMethodContext" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Walk") (TyCon "Walk")))))))
(DFunDef false "noteMethodContext" ((PCon "Ctx" PWild PWild PWild (PVar "mctx") PWild PWild (PVar "binding")) (PVar "name") (PVar "iface") (PVar "n") (PAs "w" (PCon "Walk" (PVar "seen") (PVar "found") (PVar "bad") (PVar "scalar") (PVar "calls") (PVar "ctxs") (PVar "evs") (PVar "results")))) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EApp (EVar "declaredMethodContext") (EVar "mctx")) (EVar "iface")) (EVar "name"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (EVar "k")) (EVar "w") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "seen")) (EVar "found")) (EVar "bad")) (EVar "scalar")) (EVar "calls")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method context: method ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " supplies "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " method routes, `"))) (EApp (EVar "display") (EVar "iface"))) (ELit (LString "` declares "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString " [in "))) (EApp (EVar "display") (EVar "binding"))) (ELit (LString "]"))) (EVar "ctxs"))) (EVar "evs")) (EVar "results"))))))
(DTypeSig false "noteAccess" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Walk") (TyCon "Walk")))))))
(DFunDef false "noteAccess" ((PVar "ctx") (PLit (LString "value")) (PVar "name") (PVar "ord") (PVar "w")) (EIf (EBinOp "==" (EVar "ord") (EUnOp "-" (ELit (LInt 1)))) (EVar "w") (EApp (EApp (EApp (EApp (EVar "noteRecordBad") (EVar "ctx")) (ELit (LString "CFieldAccess"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ".value: a Ref read stamped with field ordinal "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "ord")))) (ELit (LString "")))) (EVar "w"))))
(DFunDef false "noteAccess" ((PVar "ctx") (PVar "label") (PVar "name") (PVar "ord") (PVar "w")) (EIf (EBinOp ">=" (EVar "ord") (ELit (LInt 0))) (EVar "w") (EApp (EApp (EApp (EApp (EVar "noteRecordBad") (EVar "ctx")) (ELit (LString "CFieldAccess"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "."))) (EApp (EVar "display") (EVar "label"))) (ELit (LString ": unstamped field ordinal")))) (EVar "w"))))
(DTypeSig false "noteRecord" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))))
(DFunDef false "noteRecord" ((PVar "ctx") (PVar "node") (PVar "name") (PVar "literal") (PVar "fields") (PVar "w")) (EIf (EApp (EApp (EApp (EApp (EVar "ordinalsOk") (EVar "literal")) (ELit (LInt 0))) (EUnOp "-" (ELit (LInt 1)))) (EVar "fields")) (EVar "w") (EApp (EApp (EApp (EApp (EVar "noteRecordBad") (EVar "ctx")) (EVar "node")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ": field ordinals ["))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "fieldOrdinalText")) (EVar "fields"))))) (ELit (LString "] are not "))) (EApp (EVar "display") (EIf (EVar "literal") (ELit (LString "the declared positions")) (ELit (LString "strictly ascending"))))) (ELit (LString "")))) (EVar "w"))))
(DTypeSig false "ordinalsOk" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyCon "Bool"))))))
(DFunDef false "ordinalsOk" (PWild PWild PWild (PList)) (EVar "True"))
(DFunDef false "ordinalsOk" ((PVar "literal") (PVar "pos") (PVar "prev") (PCons (PCon "CField" PWild (PVar "o") PWild) (PVar "rest"))) (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "o") (ELit (LInt 0))) (EIf (EVar "literal") (EBinOp "==" (EVar "o") (EVar "pos")) (EBinOp ">" (EVar "o") (EVar "prev")))) (EApp (EApp (EApp (EApp (EVar "ordinalsOk") (EVar "literal")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "o")) (EVar "rest"))))
(DTypeSig false "fieldOrdinalText" (TyFun (TyCon "CField") (TyCon "String")))
(DFunDef false "fieldOrdinalText" ((PCon "CField" (PVar "k") (PVar "o") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "k"))) (ELit (LString "@"))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "o")))) (ELit (LString ""))))
(DTypeSig false "noteRecordBad" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "noteRecordBad" ((PCon "Ctx" PWild PWild PWild PWild PWild PWild (PVar "binding")) (PVar "node") (PVar "why") (PCon "Walk" (PVar "seen") (PVar "found") (PVar "bad") (PVar "scalar") (PVar "calls") (PVar "ctxs") (PVar "evs") (PVar "results"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "seen")) (EVar "found")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "record: ")) (EApp (EVar "display") (EVar "node"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "why"))) (ELit (LString " [in "))) (EApp (EVar "display") (EVar "binding"))) (ELit (LString "]"))) (EVar "bad"))) (EVar "scalar")) (EVar "calls")) (EVar "ctxs")) (EVar "evs")) (EVar "results")))
(DTypeSig false "noteCall" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyFun (TyCon "CallSite") (TyFun (TyCon "Walk") (TyCon "Walk"))))))))
(DFunDef false "noteCall" ((PVar "ctx") PWild PWild (PList) PWild (PVar "w")) (EApp (EApp (EApp (EVar "noteCallBad") (EVar "ctx")) (ELit (LString "application with no arguments"))) (EVar "w")))
(DFunDef false "noteCall" ((PVar "ctx") PWild (PCon "CApp" PWild PWild PWild) PWild PWild (PVar "w")) (EApp (EApp (EApp (EVar "noteCallBad") (EVar "ctx")) (ELit (LString "application whose head is an application"))) (EVar "w")))
(DFunDef false "noteCall" ((PAs "ctx" (PCon "Ctx" PWild PWild (PVar "env") PWild PWild PWild PWild)) (PVar "scope") (PVar "hd") (PVar "args") (PCon "CallSite" (PVar "mode") PWild) (PVar "w")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "listLen") (EVar "args"))) (DoLet false false (PVar "arity") (EApp (EApp (EApp (EVar "definedArityOf") (EVar "env")) (EVar "scope")) (EVar "hd"))) (DoExpr (EIf (EApp (EApp (EVar "sameMode") (EApp (EApp (EVar "callModeFor") (EVar "arity")) (EVar "n"))) (EVar "mode")) (EVar "w") (EMatch (EVar "arity") (arm (PCon "Some" (PVar "k")) () (EApp (EApp (EApp (EVar "noteCallBad") (EVar "ctx")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "headText") (EVar "hd")))) (ELit (LString " applied to "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " of "))) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString ", stamped "))) (EApp (EVar "display") (EApp (EVar "callModeSexp") (EVar "mode")))) (ELit (LString "")))) (EVar "w"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "noteCallBad") (EVar "ctx")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "headText") (EVar "hd")))) (ELit (LString " has no static arity, stamped "))) (EApp (EVar "display") (EApp (EVar "callModeSexp") (EVar "mode")))) (ELit (LString "")))) (EVar "w"))))))))
(DTypeSig false "sameMode" (TyFun (TyCon "CallMode") (TyFun (TyCon "CallMode") (TyCon "Bool"))))
(DFunDef false "sameMode" ((PCon "CallExact") (PCon "CallExact")) (EVar "True"))
(DFunDef false "sameMode" ((PCon "CallPartial" (PVar "a")) (PCon "CallPartial" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "sameMode" ((PCon "CallOver" (PVar "a")) (PCon "CallOver" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "sameMode" ((PCon "CallDynamic") (PCon "CallDynamic")) (EVar "True"))
(DFunDef false "sameMode" (PWild PWild) (EVar "False"))
(DTypeSig false "noteCallBad" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "Walk") (TyCon "Walk")))))
(DFunDef false "noteCallBad" ((PCon "Ctx" PWild PWild PWild PWild PWild PWild (PVar "binding")) (PVar "why") (PCon "Walk" (PVar "seen") (PVar "found") (PVar "bad") (PVar "scalar") (PVar "calls") (PVar "ctxs") (PVar "evs") (PVar "results"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "seen")) (EVar "found")) (EVar "bad")) (EVar "scalar")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "call: ")) (EApp (EVar "display") (EVar "why"))) (ELit (LString " [in "))) (EApp (EVar "display") (EVar "binding"))) (ELit (LString "]"))) (EVar "calls"))) (EVar "ctxs")) (EVar "evs")) (EVar "results")))
(DTypeSig false "headText" (TyFun (TyCon "CExpr") (TyCon "String")))
(DFunDef false "headText" ((PCon "CVar" (PVar "x") PWild)) (EVar "x"))
(DFunDef false "headText" ((PCon "CMethod" (PVar "name") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "method ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "headText" ((PCon "CDict" (PVar "name") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " (constrained)"))))
(DFunDef false "headText" ((PCon "CLam" PWild PWild)) (ELit (LString "a lambda")))
(DFunDef false "headText" (PWild) (ELit (LString "an expression")))
(DTypeSig false "noteVar" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyCon "String") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "noteVar" ((PCon "Ctx" (PVar "backend") (PVar "top") PWild PWild PWild (PVar "facts") (PVar "binding")) (PVar "scope") (PVar "x") (PAs "w" (PCon "Walk" (PVar "seen") (PVar "found") (PVar "bad") (PVar "scalar") (PVar "calls") (PVar "ctxs") (PVar "evs") (PVar "results")))) (EIf (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "scope")) (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "seen"))) (EVar "w") (EMatch (EApp (EApp (EVar "unprovidedOn") (EVar "backend")) (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EApp (EVar "externRuntimeKey") (EFieldAccess (EVar "facts") "efExterns")) (EVar "x")))) (arm (PCon "None") () (EVar "w")) (arm (PCon "Some" (PTuple (PVar "kind") (PVar "why"))) () (EIf (EApp (EApp (EVar "isProgramName") (EVar "top")) (EVar "x")) (EVar "w") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Walk") (EApp (EApp (EApp (EVar "omInsert") (EVar "x")) (ELit LUnit)) (EVar "seen"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "ExternFinding") (EApp (EApp (EVar "optionOr") (EVar "x")) (EApp (EApp (EVar "externRuntimeKey") (EFieldAccess (EVar "facts") "efExterns")) (EVar "x")))) (EVar "backend")) (EVar "kind")) (EVar "why")) (EVar "binding")) (EVar "found"))) (EVar "bad")) (EVar "scalar")) (EVar "calls")) (EVar "ctxs")) (EVar "evs")) (EVar "results")))))))
(DTypeSig false "walkList" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkList" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkList" ((PVar "ctx") (PVar "scope") (PCons (PVar "e") (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig false "walkFields" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkFields" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkFields" ((PVar "ctx") (PVar "scope") (PCons (PCon "CField" PWild PWild (PVar "e")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig false "walkLocalBinds" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkLocalBinds" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkLocalBinds" ((PVar "ctx") (PVar "scope") (PCons (PCon "CBind" PWild (PVar "clauses") PWild PWild) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkLocalBinds") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkClauses") (EVar "ctx")) (EVar "scope")) (EVar "clauses")) (EVar "w"))))
(DTypeSig false "walkArms" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkArms" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkArms" ((PVar "ctx") (PVar "scope") (PCons (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "ctx")) (EApp (EApp (EVar "bindPatScope") (EVar "pat")) (EVar "scope"))) (EVar "guards")) (EVar "body")) (EVar "w"))))
(DTypeSig false "walkGuarded" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyFun (TyCon "CExpr") (TyFun (TyCon "Walk") (TyCon "Walk")))))))
(DFunDef false "walkGuarded" ((PVar "ctx") (PVar "scope") (PList) (PVar "body") (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "body")) (EVar "w")))
(DFunDef false "walkGuarded" ((PVar "ctx") (PVar "scope") (PCons (PCon "CGBool" (PVar "c")) (PVar "rest")) (PVar "body") (PVar "w")) (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "c")) (EVar "w"))))
(DFunDef false "walkGuarded" ((PVar "ctx") (PVar "scope") (PCons (PCon "CGBind" (PVar "pat") (PVar "e")) (PVar "rest")) (PVar "body") (PVar "w")) (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "ctx")) (EApp (EApp (EVar "bindPatScope") (EVar "pat")) (EVar "scope"))) (EVar "rest")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig false "walkStmts" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkStmts" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkStmts" ((PVar "ctx") (PVar "scope") (PCons (PCon "CSExpr" (PVar "e")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DFunDef false "walkStmts" ((PVar "ctx") (PVar "scope") (PCons (PCon "CSLet" (PVar "recF") (PVar "pat") (PVar "e")) (PVar "rest")) (PVar "w")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EApp (EVar "bindLetScope") (EVar "pat")) (EVar "e")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "inner")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EIf (EVar "recF") (EVar "inner") (EVar "scope"))) (EVar "e")) (EVar "w"))))))
(DFunDef false "walkStmts" ((PVar "ctx") (PVar "scope") (PCons (PCon "CSAssign" PWild (PVar "e")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig true "validateTails" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateTails" ((PCon "CProgram" (PVar "groups") PWild PWild (PVar "impls") PWild PWild)) (EApp (EVar "reverseL") (EApp (EApp (EVar "tailImpls") (EVar "impls")) (EApp (EApp (EVar "tailBinds") (EVar "groups")) (EListLit)))))
(DTypeSig true "renderTailRefusal" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "renderTailRefusal" ((PVar "bad")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "bad")))
(DTypeSig false "tailBinds" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tailBinds" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailBinds" ((PCons (PCon "CBind" (PVar "name") (PVar "clauses") PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "tailBinds") (EVar "rest")) (EApp (EApp (EApp (EVar "tailClauses") (EVar "name")) (EVar "clauses")) (EVar "acc"))))
(DTypeSig false "tailClauses" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailClauses" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailClauses" ((PVar "b") (PCons (PCon "CClause" (PVar "pats") (PVar "body")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailClauses") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EApp (EVar "isNonEmptyL") (EVar "pats"))) (EVar "body")) (EVar "acc"))))
(DTypeSig false "tailImpls" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tailImpls" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailImpls" ((PCons (PCon "CImplEntry" (PVar "method") PWild PWild (PVar "body")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "tailImpls") (EVar "rest")) (EApp (EApp (EApp (EVar "tailImplBody") (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EVar "display") (EVar "method"))) (ELit (LString "")))) (EVar "body")) (EVar "acc"))))
(DTypeSig false "tailImplBody" (TyFun (TyCon "String") (TyFun (TyCon "CImplBody") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailImplBody" ((PVar "b") (PCon "CImplTagged" (PVar "tag") PWild PWild PWild PWild (PVar "pats") (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "b"))) (ELit (LString "@"))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString "")))) (EApp (EVar "isNonEmptyL") (EVar "pats"))) (EVar "body")) (EVar "acc")))
(DFunDef false "tailImplBody" ((PVar "b") (PCon "CImplDefault" PWild (PVar "tag") PWild PWild PWild (PVar "pats") (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "b"))) (ELit (LString "@"))) (EApp (EVar "display") (EVar "tag"))) (ELit (LString "")))) (EApp (EVar "isNonEmptyL") (EVar "pats"))) (EVar "body")) (EVar "acc")))
(DTypeSig false "tailE" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CApp" (PVar "f") (PVar "args") (PCon "CallSite" (PVar "mode") (PVar "flag"))) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EVar "args")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "f")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailCallNote") (EVar "b")) (EVar "tl")) (EVar "f")) (EVar "mode")) (EVar "flag")) (EVar "acc")))))
(DFunDef false "tailE" (PWild PWild (PCon "CVar" PWild PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailE" (PWild PWild (PCon "CLit" PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CLam" PWild (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "True")) (EVar "body")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CLet" PWild PWild (PVar "rhs") (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "rhs")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CLetGroup" (PVar "binds") (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "body")) (EApp (EApp (EApp (EVar "tailLocalBinds") (EVar "b")) (EVar "binds")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CMatch" (PVar "scrut") (PVar "arms")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailArms") (EVar "b")) (EVar "tl")) (EVar "arms")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "scrut")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailArms") (EVar "b")) (EVar "tl")) (EVar "arms")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "scrut")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "f")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "t")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "c")) (EVar "acc")))))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "l") (EVar "r"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CUnOp" PWild (PVar "x")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "x")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CTuple" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EVar "es")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CList" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EVar "es")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CRecord" PWild (PVar "fields")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailFields") (EVar "b")) (EVar "fields")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CFieldAccess" (PVar "x") PWild PWild PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "x")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CRecordUpdate" PWild (PVar "base") (PVar "fields")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailFields") (EVar "b")) (EVar "fields")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "base")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CVariantUpdate" PWild (PVar "base") (PVar "fields")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailFields") (EVar "b")) (EVar "fields")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "base")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CArray" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EVar "es")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "lo") (EVar "hi"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "lo") (EVar "hi"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CIndex" (PVar "a") (PVar "i")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "i"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CStringIndex" (PVar "a") (PVar "i")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "i"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CListIndex" (PVar "a") (PVar "i")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "i"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CBlock" (PVar "stmts")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailStmts") (EVar "b")) (EVar "tl")) (EVar "stmts")) (EVar "acc")))
(DFunDef false "tailE" (PWild PWild (PCon "CMethod" PWild PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailE" (PWild PWild (PCon "CDict" PWild PWild) (PVar "acc")) (EVar "acc"))
(DTypeSig false "tailCallNote" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "CExpr") (TyFun (TyCon "CallMode") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "tailCallNote" ((PVar "b") (PVar "tl") (PVar "hd") (PVar "mode") (PVar "flag") (PVar "acc")) (EIf (EBinOp "&&" (EVar "flag") (EApp (EVar "not") (EVar "tl"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "tail: ")) (EApp (EVar "display") (EApp (EVar "headText") (EVar "hd")))) (ELit (LString " is flagged as a tail call outside tail position [in "))) (EApp (EVar "display") (EVar "b"))) (ELit (LString "]"))) (EVar "acc")) (EIf (EBinOp "&&" (EVar "flag") (EApp (EVar "isPartialCall") (EVar "mode"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "tail: ")) (EApp (EVar "display") (EApp (EVar "headText") (EVar "hd")))) (ELit (LString " is flagged as a tail call but is a partial application "))) (EApp (EVar "display") (EApp (EVar "callModeSexp") (EVar "mode")))) (ELit (LString " [in "))) (EApp (EVar "display") (EVar "b"))) (ELit (LString "]"))) (EVar "acc")) (EIf (EBinOp "&&" (EBinOp "&&" (EVar "tl") (EApp (EVar "not") (EVar "flag"))) (EApp (EVar "not") (EApp (EVar "isPartialCall") (EVar "mode")))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "tail: ")) (EApp (EVar "display") (EApp (EVar "headText") (EVar "hd")))) (ELit (LString " is in tail position, stamped "))) (EApp (EVar "display") (EApp (EVar "callModeSexp") (EVar "mode")))) (ELit (LString ", but not flagged [in "))) (EApp (EVar "display") (EVar "b"))) (ELit (LString "]"))) (EVar "acc")) (EVar "acc")))))
(DTypeSig false "isPartialCall" (TyFun (TyCon "CallMode") (TyCon "Bool")))
(DFunDef false "isPartialCall" ((PCon "CallPartial" PWild)) (EVar "True"))
(DFunDef false "isPartialCall" (PWild) (EVar "False"))
(DTypeSig false "tailList" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailList" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailList" ((PVar "b") (PCons (PVar "e") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "tailFields" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailFields" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailFields" ((PVar "b") (PCons (PCon "CField" PWild PWild (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailFields") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "tailLocalBinds" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailLocalBinds" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailLocalBinds" ((PVar "b") (PCons (PCon "CBind" PWild (PVar "clauses") PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailLocalBinds") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EVar "tailClauses") (EVar "b")) (EVar "clauses")) (EVar "acc"))))
(DTypeSig false "tailArms" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "tailArms" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailArms" ((PVar "b") (PVar "tl") (PCons (PCon "CArm" PWild (PVar "guards") (PVar "body")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailArms") (EVar "b")) (EVar "tl")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "body")) (EApp (EApp (EApp (EVar "tailGuards") (EVar "b")) (EVar "guards")) (EVar "acc")))))
(DTypeSig false "tailGuards" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailGuards" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailGuards" ((PVar "b") (PCons (PCon "CGBool" (PVar "c")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailGuards") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "c")) (EVar "acc"))))
(DFunDef false "tailGuards" ((PVar "b") (PCons (PCon "CGBind" PWild (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailGuards") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "tailStmts" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "tailStmts" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailStmts" ((PVar "b") (PVar "tl") (PList (PCon "CSExpr" (PVar "e"))) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "e")) (EVar "acc")))
(DFunDef false "tailStmts" ((PVar "b") (PVar "tl") (PCons (PVar "st") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailStmts") (EVar "b")) (EVar "tl")) (EVar "rest")) (EApp (EApp (EApp (EVar "tailStmt") (EVar "b")) (EVar "st")) (EVar "acc"))))
(DTypeSig false "tailStmt" (TyFun (TyCon "String") (TyFun (TyCon "CStmt") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailStmt" ((PVar "b") (PCon "CSExpr" (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc")))
(DFunDef false "tailStmt" ((PVar "b") (PCon "CSLet" PWild PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc")))
(DFunDef false "tailStmt" ((PVar "b") (PCon "CSAssign" PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc")))
(DTypeSig true "validateBinderStamps" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateBinderStamps" ((PCon "CProgram" (PVar "groups") (PVar "ctorArs") (PVar "ctorTypes") (PVar "impls") PWild (PVar "facts"))) (EBlock (DoLet false false (PVar "rows") (EApp (EVar "BM.fromList") (EApp (EApp (EVar "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "binderOrdinal") (EFieldAccess (EVar "r") "brId")) (EVar "r")))) (EFieldAccess (EVar "facts") "factBinders")))) (DoLet false false (PVar "ctors") (EApp (EApp (EVar "omFromPairs") (EVar "ctorTypes")) (EVar "omEmpty"))) (DoLet false false (PVar "arities") (EApp (EApp (EVar "omFromPairs") (EVar "ctorArs")) (EVar "omEmpty"))) (DoExpr (EBinOp "++" (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "bindStampFaults") (EVar "rows")) (EVar "ctors")) (EVar "arities"))) (EVar "groups")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "entryStampFaults") (EVar "rows")) (EVar "ctors")) (EVar "arities"))) (EVar "impls"))))))
(DTypeSig false "bindStampFaults" (TyFun (TyApp (TyApp (TyCon "BM.Map") (TyCon "Int")) (TyCon "BinderRow")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CBind") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "bindStampFaults" ((PVar "rows") (PVar "ctors") (PVar "arities") (PAs "b" (PCon "CBind" (PVar "name") PWild PWild PWild))) (EApp (EApp (EApp (EApp (EApp (EVar "stampFaultsIn") (EVar "rows")) (EVar "ctors")) (EVar "arities")) (EVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CProgram") (EListLit (EVar "b"))) (EListLit)) (EListLit)) (EListLit)) (EListLit)) (EVar "noDeclFacts"))))
(DTypeSig false "entryStampFaults" (TyFun (TyApp (TyApp (TyCon "BM.Map") (TyCon "Int")) (TyCon "BinderRow")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CImplEntry") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "entryStampFaults" ((PVar "rows") (PVar "ctors") (PVar "arities") (PAs "e" (PCon "CImplEntry" (PVar "method") PWild PWild (PVar "body")))) (EApp (EApp (EApp (EApp (EApp (EVar "stampFaultsIn") (EVar "rows")) (EVar "ctors")) (EVar "arities")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EVar "display") (EVar "method"))) (ELit (LString "@"))) (EApp (EVar "display") (EApp (EVar "implBodyTag") (EVar "body")))) (ELit (LString "")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CProgram") (EListLit)) (EListLit)) (EListLit)) (EListLit (EVar "e"))) (EListLit)) (EVar "noDeclFacts"))))
(DTypeSig false "stampFaultsIn" (TyFun (TyApp (TyApp (TyCon "BM.Map") (TyCon "Int")) (TyCon "BinderRow")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "stampFaultsIn" ((PVar "rows") (PVar "ctors") (PVar "arities") (PVar "where_") (PVar "prog")) (EBlock (DoLet false false (PVar "found") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "mapProgramBinders") (ELam ((PVar "site") (PVar "x") (PVar "bid")) (EBlock (DoLet false false PWild (EMatch (EVar "site") (arm (PCon "PatternBinder" (PVar "rhs")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "stampFault") (EVar "rows")) (EVar "ctors")) (EVar "arities")) (EVar "rhs")) (EVar "x")) (EVar "bid")) (arm (PCon "Some" (PVar "msg")) () (EApp (EApp (EVar "setRef") (EVar "found")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "binder: ")) (EApp (EVar "display") (EVar "msg"))) (ELit (LString " [in "))) (EApp (EVar "display") (EVar "where_"))) (ELit (LString "]"))) (EUnOp "!" (EVar "found"))))) (arm (PCon "None") () (ELit LUnit)))) (arm (PCon "FunctionBinder" PWild) () (EMatch (EApp (EApp (EApp (EVar "returnFault") (EVar "rows")) (EVar "x")) (EVar "bid")) (arm (PCon "Some" (PVar "msg")) () (EApp (EApp (EVar "setRef") (EVar "found")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "function: ")) (EApp (EVar "display") (EVar "msg"))) (ELit (LString " [in "))) (EApp (EVar "display") (EVar "where_"))) (ELit (LString "]"))) (EUnOp "!" (EVar "found"))))) (arm (PCon "None") () (ELit LUnit)))))) (DoExpr (EVar "bid"))))) (EVar "prog"))) (DoExpr (EApp (EVar "reverseL") (EUnOp "!" (EVar "found"))))))
(DTypeSig false "returnFault" (TyFun (TyApp (TyApp (TyCon "BM.Map") (TyCon "Int")) (TyCon "BinderRow")) (TyFun (TyCon "String") (TyFun (TyCon "BinderId") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "returnFault" ((PVar "rows") (PVar "x") (PCon "BinderId" PWild (PVar "n"))) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString " has no id, so no return type")))) (EMatch (EApp (EApp (EVar "BM.get") (EVar "n")) (EVar "rows")) (arm (PCon "None") () (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString " has no stamped type"))))) (arm (PCon "Some" (PVar "row")) () (EMatch (EFieldAccess (EVar "row") "brReturns") (arm (PCon "None") () (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString " has no return type"))))) (arm (PCon "Some" PWild) () (EVar "None")))))))
(DTypeSig false "stampFault" (TyFun (TyApp (TyApp (TyCon "BM.Map") (TyCon "Int")) (TyCon "BinderRow")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "CExpr")) (TyFun (TyCon "String") (TyFun (TyCon "BinderId") (TyApp (TyCon "Option") (TyCon "String")))))))))
(DFunDef false "stampFault" ((PVar "rows") (PVar "ctors") (PVar "arities") (PVar "rhs") (PVar "x") (PCon "BinderId" PWild (PVar "n"))) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString " has no id, so no stamped type")))) (EMatch (EApp (EApp (EVar "BM.get") (EVar "n")) (EVar "rows")) (arm (PCon "None") () (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString " has no stamped type"))))) (arm (PCon "Some" (PVar "row")) () (EMatch (EVar "rhs") (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "e")) () (EMatch (EApp (EApp (EApp (EVar "boundShape") (EVar "ctors")) (EVar "arities")) (EVar "e")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "shape")) () (EIf (EApp (EApp (EVar "stampAllows") (EVar "shape")) (EFieldAccess (EVar "row") "brType")) (EVar "None") (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString " is stamped "))) (EApp (EVar "display") (EApp (EVar "runtimeTypeName") (EFieldAccess (EVar "row") "brType")))) (ELit (LString " but is bound to "))) (EApp (EVar "display") (EApp (EVar "shapeName") (EVar "shape")))) (ELit (LString "")))))))))))))
(DData Private "BoundShape" () ((variant "BoundLit" (ConPos (TyCon "RuntimeType"))) (variant "BoundInt" (ConPos)) (variant "BoundCell" (ConPos))) ())
(DTypeSig false "boundShape" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyCon "BoundShape"))))))
(DFunDef false "boundShape" (PWild PWild (PCon "CLit" (PCon "LInt" PWild))) (EApp (EVar "Some") (EVar "BoundInt")))
(DFunDef false "boundShape" (PWild PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "Some") (EApp (EVar "BoundLit") (EApp (EVar "litRuntimeType") (EVar "l")))))
(DFunDef false "boundShape" (PWild PWild (PCon "CTuple" PWild)) (EApp (EVar "Some") (EVar "BoundCell")))
(DFunDef false "boundShape" (PWild PWild (PCon "CList" PWild)) (EApp (EVar "Some") (EVar "BoundCell")))
(DFunDef false "boundShape" ((PVar "ctors") (PVar "arities") (PCon "CVar" (PVar "c") PWild)) (EApp (EApp (EApp (EApp (EVar "ctorShape") (EVar "ctors")) (EVar "arities")) (EVar "c")) (ELit (LInt 0))))
(DFunDef false "boundShape" ((PVar "ctors") (PVar "arities") (PCon "CApp" (PCon "CVar" (PVar "c") PWild) (PVar "args") PWild)) (EApp (EApp (EApp (EApp (EVar "ctorShape") (EVar "ctors")) (EVar "arities")) (EVar "c")) (EApp (EVar "listLen") (EVar "args"))))
(DFunDef false "boundShape" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "ctorShape" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "BoundShape")))))))
(DFunDef false "ctorShape" ((PVar "ctors") (PVar "arities") (PVar "c") (PVar "n")) (EMatch (ETuple (EApp (EApp (EVar "omLookup") (EVar "c")) (EVar "arities")) (EApp (EApp (EVar "omLookup") (EVar "c")) (EVar "ctors"))) (arm (PTuple (PCon "Some" (PVar "k")) (PCon "Some" (PVar "ty"))) () (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "k") (EVar "n")) (EBinOp "/=" (EVar "ty") (ELit (LString "Bool")))) (EBinOp "/=" (EVar "ty") (ELit (LString "Unit")))) (EApp (EVar "Some") (EVar "BoundCell")) (EVar "None"))) (arm PWild () (EVar "None"))))
(DTypeSig false "stampAllows" (TyFun (TyCon "BoundShape") (TyFun (TyCon "RuntimeType") (TyCon "Bool"))))
(DFunDef false "stampAllows" (PWild (PCon "RTValue")) (EVar "True"))
(DFunDef false "stampAllows" ((PCon "BoundLit" (PVar "t")) (PVar "stamped")) (EBinOp "==" (EVar "t") (EVar "stamped")))
(DFunDef false "stampAllows" ((PCon "BoundInt") (PVar "stamped")) (EApp (EVar "isNumericRuntimeType") (EVar "stamped")))
(DFunDef false "stampAllows" ((PCon "BoundCell") (PVar "stamped")) (EBinOp "==" (EVar "stamped") (EVar "RTCon")))
(DTypeSig false "isNumericRuntimeType" (TyFun (TyCon "RuntimeType") (TyCon "Bool")))
(DFunDef false "isNumericRuntimeType" ((PCon "RTInt")) (EVar "True"))
(DFunDef false "isNumericRuntimeType" ((PCon "RTFloat")) (EVar "True"))
(DFunDef false "isNumericRuntimeType" ((PCon "RTU64")) (EVar "True"))
(DFunDef false "isNumericRuntimeType" ((PCon "RTI64")) (EVar "True"))
(DFunDef false "isNumericRuntimeType" ((PCon "RTU32")) (EVar "True"))
(DFunDef false "isNumericRuntimeType" ((PCon "RTI32")) (EVar "True"))
(DFunDef false "isNumericRuntimeType" ((PCon "RTU16")) (EVar "True"))
(DFunDef false "isNumericRuntimeType" ((PCon "RTU8")) (EVar "True"))
(DFunDef false "isNumericRuntimeType" (PWild) (EVar "False"))
(DTypeSig false "shapeName" (TyFun (TyCon "BoundShape") (TyCon "String")))
(DFunDef false "shapeName" ((PCon "BoundLit" (PVar "t"))) (EBinOp "++" (EBinOp "++" (ELit (LString "a ")) (EApp (EVar "display") (EApp (EVar "runtimeTypeName") (EVar "t")))) (ELit (LString " literal"))))
(DFunDef false "shapeName" ((PCon "BoundInt")) (ELit (LString "an integer literal")))
(DFunDef false "shapeName" ((PCon "BoundCell")) (ELit (LString "a constructor cell")))
(DTypeSig true "renderBinderRefusal" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "renderBinderRefusal" ((PVar "bad")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "bad")))
(DTypeSig false "validatePhysicalDemand" (TyFun (TyCon "Backend") (TyFun (TyCon "EmitPlan") (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "validatePhysicalDemand" ((PCon "WasmBackend") (PVar "plan") (PVar "cp")) (EMatch (EFieldAccess (EVar "plan") "wasmPhysical") (arm (PCon "None") () (EListLit (ELit (LString "missing-wasm-demand-plan")))) (arm (PCon "Some" (PVar "physical")) () (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "validateWasmDemand") (ERecordUpdate (EFieldAccess (EVar "plan") "wasmInputs") ((fa "lazyGlobals" (EFieldAccess (EVar "plan") "lazyGlobals")) (fa "globalInit" (EFieldAccess (EVar "plan") "globalInit")) (fa "trmcVerdicts" (EFieldAccess (EVar "plan") "trmc")) (fa "dispatchGroups" (EFieldAccess (EVar "plan") "dispGroups"))))) (EVar "cp")) (EFieldAccess (EVar "plan") "externRequirements")) (EVar "physical")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "/=" (EFieldAccess (EVar "physical") "sourceDemand") (EFieldAccess (EVar "plan") "wasmDemand")) (EBinOp "/=" (EFieldAccess (EVar "physical") "sourceHostKeys") (EFieldAccess (EVar "plan") "hostKeys"))) (EBinOp "/=" (EFieldAccess (EVar "physical") "jsImports") (EFieldAccess (EVar "plan") "jsImports"))) (EListLit (ELit (LString "wasm-source-demand-mismatch"))) (EListLit))))))
(DFunDef false "validatePhysicalDemand" (PWild PWild PWild) (EListLit))
# MARK
(DUse false (UseGroup ("backend" "wasm_demand") ((mem "validateWasmDemand" false))))
(DUse false (UseGroup ("ir" "extern_types") ((mem "ExternDeclFact" true) (mem "ExternUse" true))))
(DUse false (UseGroup ("ir" "extern_uses") ((mem "collectExternUses" false))))
(DUse false (UseGroup ("ir" "extern_lower") ((mem "externRuntimeKey" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CExpr" true) (mem "CField" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CBind" true) (mem "CClause" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "ImplSym" true) (mem "MethodEvidence" true) (mem "CProgram" true) (mem "DeclFacts" true) (mem "MethodResultFact" true) (mem "CallMode" true) (mem "CallSite" true) (mem "noDeclFacts" false) (mem "givenNames" false) (mem "mapProgramBinders" false) (mem "BinderSite" true) (mem "litRuntimeType" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" true) (mem "RuntimeType" true) (mem "binderOrdinal" false) (mem "runtimeTypeName" false))))
(DUse false (UseAlias ("map") "BM"))
(DUse false (UseGroup ("ir" "core_ir_lower") ((mem "ArityEnv" false) (mem "CallScope" false) (mem "bindGroupScope" false) (mem "bindLetScope" false) (mem "bindPatScope" false) (mem "bindPatsScope" false) (mem "callModeFor" false) (mem "definedArityOf" false) (mem "entryArityRow" false) (mem "programArities" false) (mem "ifaceMethodArityKey" false) (mem "ifaceWordOfKey" false) (mem "leadingDictParams" false))))
(DUse false (UseGroup ("ir" "core_ir_sexp") ((mem "callModeSexp" false))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Pat" true) (mem "Route" true) (mem "Decl" true) (mem "ExternDecl" true) (mem "Ty" true) (mem "Lit" true) (mem "BinderId" true) (mem "isFixedIntHead" false) (mem "isBoxed64Head" false))))
(DUse false (UseGroup ("types" "target_profile") ((mem "TargetProfile" false) (mem "withheldLabels" false) (mem "profileName" false))))
(DUse false (UseGroup ("backend" "extern_requirements") ((mem "validateExternRequirements" false) (mem "requirementHostRows" false))))
(DUse false (UseGroup ("backend" "global_plan") ((mem "validateGlobalInit" false))))
(DUse false (UseGroup ("backend" "emit_target") ((mem "Backend" true) (mem "backendName" false))))
(DUse false (UseGroup ("backend" "emit_plan") ((mem "EmitPlan" false) (mem "indexMethodResults" false) (mem "lookupMethodResult" false))))
(DUse false (UseGroup ("backend" "extern_catalog") ((mem "RuntimeExternDomain" true) (mem "Disposition" true) (mem "GapKind" true) (mem "catalogRow" false) (mem "gapKindName" false) (mem "rowLlvm" false) (mem "rowWasm" false) (mem "rowEval" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromPairs" false) (mem "omInsert" false) (mem "omHasKey" false) (mem "omLookup" false) (mem "omKeys" false))))
(DUse false (UseGroup ("types" "private_mangle") ((mem "dictTag" false) (mem "hashName" false))))
(DUse false (UseGroup ("support" "util") ((mem "dedupBy" false) (mem "isNonEmptyL" false) (mem "joinWith" false) (mem "listLen" false) (mem "reverseL" false))))
(DData Public "ExternFinding" () ((variant "ExternFinding" (ConPos (TyCon "String") (TyCon "Backend") (TyCon "GapKind") (TyCon "String") (TyCon "String")))) ())
(DData Public "CoreDefect" () ((variant "CoreDefect" (ConPos (TyCon "String")))) ())
(DData Public "EmissionValidation" () ((variant "EmissionValidation" (ConNamed (field "defects" (TyApp (TyCon "List") (TyCon "CoreDefect"))) (field "externFindings" (TyApp (TyCon "List") (TyCon "ExternFinding")))))) ())
(DTypeSig true "coreDefectMessage" (TyFun (TyCon "CoreDefect") (TyCon "String")))
(DFunDef false "coreDefectMessage" ((PCon "CoreDefect" (PVar "message"))) (EVar "message"))
(DTypeSig true "validateForEmission" (TyFun (TyCon "Backend") (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyCon "EmitPlan") (TyFun (TyCon "CProgram") (TyCon "EmissionValidation"))))))
(DFunDef false "validateForEmission" ((PVar "backend") (PVar "domain") (PVar "plan") (PVar "cp")) (EMatch (EApp (EApp (EApp (EApp (EVar "emissionDefects") (EVar "backend")) (EVar "domain")) (EVar "plan")) (EVar "cp")) (arm (PList) () (EBlock (DoLet false false (PVar "names") (EMatch (EVar "domain") (arm (PCon "PreludeFreeRuntime") () (EListLit)) (arm (PCon "LoadedRuntimeExterns" (PVar "decls")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EFieldAccess (EVar "d") "edName"))) (EVar "decls"))))) (DoExpr (EMatch (EApp (EVar "missingCatalogRows") (EVar "names")) (arm (PList) () (ERecordCreate "EmissionValidation" ((fa "defects" (EListLit)) (fa "externFindings" (EApp (EApp (EApp (EVar "validateExterns") (EVar "backend")) (EListLit)) (EVar "cp")))))) (arm (PVar "missing") () (ERecordCreate "EmissionValidation" ((fa "defects" (EListLit (EApp (EVar "CoreDefect") (EApp (EVar "missingRowsMessage") (EVar "missing"))))) (fa "externFindings" (EListLit))))))))) (arm (PVar "bad") () (ERecordCreate "EmissionValidation" ((fa "defects" (EVar "bad")) (fa "externFindings" (EListLit)))))))
(DTypeSig false "emissionDefects" (TyFun (TyCon "Backend") (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyCon "EmitPlan") (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "CoreDefect")))))))
(DFunDef false "emissionDefects" ((PVar "backend") (PVar "domain") (PVar "plan") (PVar "cp")) (EIf (EBinOp "/=" (EApp (EVar "backendName") (EFieldAccess (EVar "plan") "target")) (EApp (EVar "backendName") (EVar "backend"))) (EListLit (EApp (EVar "CoreDefect") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: emit plan was built for the ")) (EApp (EMethodRef "display") (EApp (EVar "backendName") (EFieldAccess (EVar "plan") "target")))) (ELit (LString " backend but the "))) (EApp (EMethodRef "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString " emitter received it"))))) (EMatch (EApp (EVar "implSymbolCollision") (EVar "cp")) (arm (PCon "Some" (PVar "message")) () (EListLit (EApp (EVar "CoreDefect") (EVar "message")))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "dictTagCollision") (EVar "backend")) (EVar "cp")) (arm (PCon "Some" (PVar "message")) () (EListLit (EApp (EVar "CoreDefect") (EVar "message")))) (arm (PCon "None") () (EApp (EVar "firstShapeDefect") (EListLit (ELam ((PLit LUnit)) (EApp (EVar "validateExternMetadata") (EVar "cp"))) (ELam ((PLit LUnit)) (EApp (EApp (EApp (EApp (EVar "validateExternRequirements") (EVar "backend")) (EVar "domain")) (EVar "cp")) (EFieldAccess (EVar "plan") "externRequirements"))) (ELam ((PLit LUnit)) (EApp (EApp (EVar "validateRequirementProjection") (EVar "backend")) (EVar "plan"))) (ELam ((PLit LUnit)) (EApp (EApp (EApp (EVar "validateGlobalInit") (EVar "cp")) (EFieldAccess (EVar "plan") "lazyGlobals")) (EFieldAccess (EVar "plan") "globalInit"))) (ELam ((PLit LUnit)) (EApp (EApp (EApp (EVar "validatePhysicalDemand") (EVar "backend")) (EVar "plan")) (EVar "cp"))) (ELam ((PLit LUnit)) (EApp (EVar "validateRecords") (EVar "cp"))) (ELam ((PLit LUnit)) (EApp (EVar "validateBinderStamps") (EVar "cp"))) (ELam ((PLit LUnit)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EVar "validateScalarOperators") (EVar "cp")) (EApp (EVar "validateCalls") (EVar "cp"))) (EApp (EVar "validateImplSymbols") (EVar "cp"))) (EApp (EVar "validateMethodContexts") (EVar "cp"))) (EApp (EVar "validateDispatchEvidence") (EVar "cp"))) (EApp (EApp (EVar "validateMethodResults") (EVar "plan")) (EVar "cp")))) (ELam ((PLit LUnit)) (EApp (EVar "validateTails") (EVar "cp")))))))))))
(DTypeSig false "firstShapeDefect" (TyFun (TyApp (TyCon "List") (TyFun (TyCon "Unit") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "CoreDefect"))))
(DFunDef false "firstShapeDefect" ((PList)) (EListLit))
(DFunDef false "firstShapeDefect" ((PCons (PVar "check") (PVar "rest"))) (EMatch (EApp (EVar "check") (ELit LUnit)) (arm (PList) () (EApp (EVar "firstShapeDefect") (EVar "rest"))) (arm (PVar "bad") () (EListLit (EApp (EVar "CoreDefect") (EBinOp "++" (ELit (LString "internal error: ")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "bad"))))))))
(DTypeSig false "validateRequirementProjection" (TyFun (TyCon "Backend") (TyFun (TyCon "EmitPlan") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "validateRequirementProjection" ((PCon "WasmBackend") (PVar "plan")) (EIf (EBinOp "==" (EApp (EApp (EMethodRef "map") (ELam ((PVar "imp")) (ETuple (EFieldAccess (EVar "imp") "medakaName") (ETuple (EFieldAccess (EVar "imp") "jsName") (ETuple (EFieldAccess (EVar "imp") "params") (EFieldAccess (EVar "imp") "result")))))) (EFieldAccess (EVar "plan") "jsImports")) (EApp (EVar "requirementHostRows") (EFieldAccess (EVar "plan") "externRequirements"))) (EListLit) (EListLit (ELit (LString "extern-import-mismatch")))))
(DFunDef false "validateRequirementProjection" (PWild PWild) (EListLit))
(DTypeSig false "validateExternMetadata" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateExternMetadata" ((PAs "cp" (PCon "CProgram" PWild PWild PWild PWild PWild (PVar "facts")))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "use")) (EMatch (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "use") "useSymbol")) (EFieldAccess (EVar "facts") "factExterns")) (arm (PCon "None") () (EListLit (EBinOp "++" (ELit (LString "unknown-extern-declaration: ")) (EFieldAccess (EVar "use") "useSymbol")))) (arm (PCon "Some" (PVar "fact")) () (EMatch (EFieldAccess (EVar "fact") "callableShape") (arm (PCon "None") () (EListLit (EBinOp "++" (ELit (LString "missing-extern-abi: ")) (EFieldAccess (EVar "fact") "symbol")))) (arm (PCon "Some" PWild) () (EListLit))))))) (EApp (EVar "collectExternUses") (EVar "cp"))))
(DTypeSig true "findingExtern" (TyFun (TyCon "ExternFinding") (TyCon "String")))
(DFunDef false "findingExtern" ((PCon "ExternFinding" (PVar "name") PWild PWild PWild PWild)) (EVar "name"))
(DTypeSig true "findingBinding" (TyFun (TyCon "ExternFinding") (TyCon "String")))
(DFunDef false "findingBinding" ((PCon "ExternFinding" PWild PWild PWild PWild (PVar "binding"))) (EVar "binding"))
(DTypeSig true "unprovidedOn" (TyFun (TyCon "Backend") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "GapKind") (TyCon "String"))))))
(DFunDef false "unprovidedOn" ((PCon "LlvmBackend") (PVar "name")) (EMatch (EApp (EVar "catalogRow") (EVar "name")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "notProvidedOf") (EApp (EVar "rowLlvm") (EVar "r")))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "unprovidedOn" ((PCon "WasmBackend") (PVar "name")) (EMatch (EApp (EVar "catalogRow") (EVar "name")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "notProvidedOf") (EApp (EVar "rowWasm") (EVar "r")))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "unprovidedOn" ((PCon "EvalBackend") (PVar "name")) (EMatch (EApp (EVar "catalogRow") (EVar "name")) (arm (PCon "Some" (PVar "r")) () (EApp (EVar "notProvidedOf") (EApp (EVar "rowEval") (EVar "r")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "notProvidedOf" (TyFun (TyApp (TyCon "Disposition") (TyVar "f")) (TyApp (TyCon "Option") (TyTuple (TyCon "GapKind") (TyCon "String")))))
(DFunDef false "notProvidedOf" ((PCon "NotProvided" (PVar "kind") (PVar "why"))) (EApp (EVar "Some") (ETuple (EVar "kind") (EVar "why"))))
(DFunDef false "notProvidedOf" (PWild) (EVar "None"))
(DTypeSig true "isUnprovidedOn" (TyFun (TyCon "Backend") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isUnprovidedOn" ((PVar "backend") (PVar "name")) (EApp (EVar "isSome") (EApp (EApp (EVar "unprovidedOn") (EVar "backend")) (EVar "name"))))
(DTypeSig true "validateExterns" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "ExternFinding"))))))
(DFunDef false "validateExterns" ((PVar "backend") (PVar "runtimeExterns") (PVar "prog")) (EBlock (DoLet false false PWild (EApp (EVar "refuseMissingRows") (EVar "runtimeExterns"))) (DoExpr (EMatch (EApp (EApp (EVar "walkProgram") (EVar "backend")) (EVar "prog")) (arm (PCon "Walk" PWild (PVar "found") PWild PWild PWild PWild PWild PWild) () (EApp (EVar "reverseL") (EVar "found")))))))
(DTypeSig true "validateRecords" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateRecords" ((PVar "prog")) (EMatch (EApp (EApp (EVar "walkProgram") (EVar "LlvmBackend")) (EVar "prog")) (arm (PCon "Walk" PWild PWild (PVar "bad") PWild PWild PWild PWild PWild) () (EApp (EVar "reverseL") (EVar "bad")))))
(DTypeSig true "renderRecordRefusal" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "renderRecordRefusal" ((PVar "bad")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "bad")))
(DTypeSig true "validateCalls" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateCalls" ((PAs "prog" (PCon "CProgram" PWild PWild PWild (PVar "impls") PWild PWild))) (EMatch (EApp (EApp (EVar "walkProgram") (EVar "LlvmBackend")) (EVar "prog")) (arm (PCon "Walk" PWild PWild PWild PWild (PVar "bad") PWild PWild PWild) () (EBinOp "++" (EApp (EVar "reverseL") (EVar "bad")) (EApp (EApp (EApp (EVar "splitGroupFaults") (EVar "impls")) (EVar "omEmpty")) (EListLit))))))
(DTypeSig true "validateScalarOperators" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateScalarOperators" ((PVar "prog")) (EMatch (EApp (EApp (EVar "walkProgram") (EVar "LlvmBackend")) (EVar "prog")) (arm (PCon "Walk" PWild PWild PWild (PVar "bad") PWild PWild PWild PWild) () (EApp (EVar "reverseL") (EVar "bad")))))
(DTypeSig false "splitGroupFaults" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "splitGroupFaults" ((PList) PWild (PVar "acc")) (EApp (EVar "reverseL") (EVar "acc")))
(DFunDef false "splitGroupFaults" ((PCons (PAs "ent" (PCon "CImplEntry" (PVar "method") PWild PWild (PVar "body"))) (PVar "rest")) (PVar "seen") (PVar "acc")) (EBlock (DoLet false false (PTuple (PVar "key") (PVar "n")) (EApp (EVar "entryArityRow") (EVar "ent"))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "seen")) (arm (PCon "Some" (PVar "k")) () (EIf (EBinOp "==" (EVar "k") (EVar "n")) (EApp (EApp (EApp (EVar "splitGroupFaults") (EVar "rest")) (EVar "seen")) (EVar "acc")) (EApp (EApp (EApp (EVar "splitGroupFaults") (EVar "rest")) (EVar "seen")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "call: impl entry takes ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " value parameters, the first entry of its group "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString " [in impl "))) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EApp (EVar "implBodyTag") (EVar "body")))) (ELit (LString "]"))) (EVar "acc"))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "splitGroupFaults") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (EVar "n")) (EVar "seen"))) (EVar "acc")))))))
(DTypeSig true "validateMethodResults" (TyFun (TyCon "EmitPlan") (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "validateMethodResults" ((PVar "plan") (PAs "prog" (PCon "CProgram" PWild PWild PWild (PVar "impls") PWild (PVar "facts")))) (EBlock (DoLet false false (PVar "index") (EApp (EVar "indexMethodResults") (EFieldAccess (EVar "facts") "factMethodResults"))) (DoLet false false (PVar "rowsBad") (EApp (EApp (EApp (EVar "methodResultRows") (EFieldAccess (EVar "facts") "factMethodResults")) (EVar "omEmpty")) (EListLit))) (DoLet false true (PVar "keys") (ELam ((PVar "idx")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "iface")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EApp (EApp (EVar "ifaceMethodArityKey") (EVar "iface")) (EVar "m")))) (EApp (EVar "omKeys") (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EVar "iface")) (EVar "idx"))))))) (EApp (EVar "omKeys") (EVar "idx"))))) (DoLet false false (PVar "planBad") (EIf (EBinOp "&&" (EBinOp "==" (EApp (EVar "keys") (EMethodRef "index")) (EApp (EVar "keys") (EFieldAccess (EVar "plan") "methodResults"))) (EApp (EApp (EDictApp "all") (EApp (EVar "methodResultMatches") (EFieldAccess (EVar "plan") "methodResults"))) (EFieldAccess (EVar "facts") "factMethodResults"))) (EListLit) (EListLit (ELit (LString "method result: emit plan index disagrees with declaration facts"))))) (DoLet false false (PVar "refsBad") (EMatch (EApp (EApp (EVar "walkProgram") (EVar "LlvmBackend")) (EVar "prog")) (arm (PCon "Walk" PWild PWild PWild PWild PWild PWild PWild (PVar "bad")) () (EApp (EVar "reverseL") (EVar "bad"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EVar "rowsBad") (EVar "planBad")) (EVar "refsBad")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "entryMethodResult") (EMethodRef "index"))) (EVar "impls"))))))
(DTypeSig false "methodResultMatches" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact"))) (TyFun (TyCon "MethodResultFact") (TyCon "Bool"))))
(DFunDef false "methodResultMatches" ((PVar "index") (PVar "row")) (EBinOp "==" (EApp (EApp (EApp (EVar "lookupMethodResult") (EMethodRef "index")) (EFieldAccess (EVar "row") "iface")) (EFieldAccess (EVar "row") "method")) (EApp (EVar "Some") (EVar "row"))))
(DTypeSig false "methodResultRows" (TyFun (TyApp (TyCon "List") (TyCon "MethodResultFact")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "methodResultRows" ((PList) PWild (PVar "bad")) (EApp (EVar "reverseL") (EVar "bad")))
(DFunDef false "methodResultRows" ((PCons (PVar "row") (PVar "rest")) (PVar "seen") (PVar "bad")) (EBlock (DoLet false false (PVar "methods") (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "row") "iface")) (EVar "seen")))) (DoLet false false (PVar "why") (EIf (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "row") "iface") (ELit (LString ""))) (EBinOp "==" (EFieldAccess (EVar "row") "method") (ELit (LString "")))) (ELit (LString "empty interface or method key")) (EIf (EApp (EApp (EVar "omHasKey") (EFieldAccess (EVar "row") "method")) (EVar "methods")) (ELit (LString "duplicate qualified key")) (EIf (EBinOp "<" (EFieldAccess (EVar "row") "valueArity") (ELit (LInt 0))) (ELit (LString "negative value arity")) (EIf (EApp (EVar "not") (EApp (EApp (EApp (EVar "callbackPositionsValid") (EFieldAccess (EVar "row") "valueArity")) (EUnOp "-" (ELit (LInt 1)))) (EFieldAccess (EVar "row") "callbackPositions"))) (ELit (LString "invalid callback position")) (ELit (LString ""))))))) (DoExpr (EApp (EApp (EApp (EVar "methodResultRows") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "row") "iface")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "row") "method")) (ELit LUnit)) (EVar "methods"))) (EVar "seen"))) (EIf (EBinOp "==" (EVar "why") (ELit (LString ""))) (EVar "bad") (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method result: ")) (EApp (EMethodRef "display") (EVar "why"))) (ELit (LString " ["))) (EApp (EMethodRef "display") (EFieldAccess (EVar "row") "iface"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "row") "method"))) (ELit (LString "]"))) (EVar "bad")))))))
(DTypeSig false "callbackPositionsValid" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "Bool")))))
(DFunDef false "callbackPositionsValid" (PWild PWild (PList)) (EVar "True"))
(DFunDef false "callbackPositionsValid" ((PVar "arity") (PVar "prev") (PCons (PVar "n") (PVar "ns"))) (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "n") (EVar "prev")) (EBinOp "<" (EVar "n") (EVar "arity"))) (EApp (EApp (EApp (EVar "callbackPositionsValid") (EVar "arity")) (EVar "n")) (EVar "ns"))))
(DTypeSig false "entryMethodResult" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact"))) (TyFun (TyCon "CImplEntry") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "entryMethodResult" ((PVar "index") (PCon "CImplEntry" (PVar "method") PWild (PVar "declared") (PCon "CImplTagged" PWild PWild (PVar "iface") PWild PWild PWild PWild))) (EApp (EApp (EApp (EApp (EVar "entryMethodResultFact") (EMethodRef "index")) (EVar "iface")) (EVar "method")) (EVar "declared")))
(DFunDef false "entryMethodResult" ((PVar "index") (PCon "CImplEntry" (PVar "method") PWild (PVar "declared") (PCon "CImplDefault" (PVar "iface") PWild PWild PWild PWild PWild PWild))) (EApp (EApp (EApp (EApp (EVar "entryMethodResultFact") (EMethodRef "index")) (EVar "iface")) (EVar "method")) (EVar "declared")))
(DTypeSig false "entryMethodResultFact" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "entryMethodResultFact" ((PVar "index") (PVar "iface") (PVar "method") (PVar "declared")) (EMatch (EApp (EApp (EApp (EVar "lookupMethodResult") (EMethodRef "index")) (EVar "iface")) (EVar "method")) (arm (PCon "Some" (PVar "row")) () (EIf (EBinOp "==" (EFieldAccess (EVar "row") "valueArity") (EVar "declared")) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method result: fact value arity ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EFieldAccess (EVar "row") "valueArity")))) (ELit (LString " disagrees with Core impl entry declared value arity "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "declared")))) (ELit (LString " ["))) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString "]")))))) (arm (PCon "None") () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method result: missing declaration fact [")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString "]")))))))
(DTypeSig false "missingMethodResult" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "missingMethodResult" ((PVar "index") (PVar "iface") (PVar "method")) (EMatch (EApp (EApp (EApp (EVar "lookupMethodResult") (EMethodRef "index")) (EVar "iface")) (EVar "method")) (arm (PCon "Some" PWild) () (EListLit)) (arm (PCon "None") () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method result: missing declaration fact [")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "#"))) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString "]")))))))
(DTypeSig false "noteMethodResult" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "noteMethodResult" (PWild PWild (PLit (LString "")) (PVar "w")) (EVar "w"))
(DFunDef false "noteMethodResult" ((PCon "Ctx" PWild PWild PWild PWild PWild (PVar "facts") PWild) (PVar "method") (PVar "iface") (PCon "Walk" (PVar "seen") (PVar "found") (PVar "bad") (PVar "scalar") (PVar "calls") (PVar "ctxs") (PVar "evs") (PVar "results"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "seen")) (EVar "found")) (EVar "bad")) (EVar "scalar")) (EVar "calls")) (EVar "ctxs")) (EVar "evs")) (EBinOp "++" (EApp (EApp (EApp (EVar "missingMethodResult") (EFieldAccess (EVar "facts") "efMethods")) (EVar "iface")) (EVar "method")) (EVar "results"))))
(DTypeSig true "validateMethodContexts" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateMethodContexts" ((PAs "prog" (PCon "CProgram" PWild PWild PWild (PVar "impls") (PVar "mctx") (PVar "facts")))) (EMatch (EApp (EApp (EVar "walkProgram") (EVar "LlvmBackend")) (EVar "prog")) (arm (PCon "Walk" PWild PWild PWild PWild PWild (PVar "bad") PWild PWild) () (EBinOp "++" (EApp (EVar "reverseL") (EVar "bad")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "entryContextFaults") (EApp (EApp (EVar "omFromPairs") (EVar "mctx")) (EVar "omEmpty"))) (EApp (EApp (EVar "omFromPairs") (EFieldAccess (EVar "facts") "factRequires")) (EVar "omEmpty")))) (EVar "impls"))))))
(DTypeSig false "entryContextFaults" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CImplEntry") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "entryContextFaults" ((PVar "table") (PVar "reqs") (PCon "CImplEntry" (PVar "method") PWild PWild (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") PWild PWild (PVar "pats") PWild))) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EApp (EVar "declaredMethodContext") (EVar "table")) (EVar "iface")) (EVar "method"))) (DoLet false false (PVar "r") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "reqs")))) (DoLet false false (PVar "n") (EApp (EApp (EApp (EVar "leadingMethodDicts") (EVar "method")) (ELit (LInt 0))) (EVar "pats"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "n") (EVar "k")) (EBinOp "==" (EVar "n") (EBinOp "+" (EVar "k") (EVar "r")))) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method context: impl entry opens with ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " `$dict_"))) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString "_k` parameters, `"))) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "` declares "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString " and its instance requires "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "r")))) (ELit (LString " [in impl "))) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString "]"))))))))
(DFunDef false "entryContextFaults" ((PVar "table") PWild (PCon "CImplEntry" (PVar "method") PWild PWild (PCon "CImplDefault" (PVar "iface") (PVar "tag") PWild PWild PWild (PVar "pats") PWild))) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EApp (EVar "declaredMethodContext") (EVar "table")) (EVar "iface")) (EVar "method"))) (DoLet false false (PVar "n") (EApp (EApp (EApp (EVar "leadingMethodDicts") (EVar "method")) (ELit (LInt 0))) (EVar "pats"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method context: default entry opens with ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " `$dict_"))) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString "_k` parameters, `"))) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "` declares "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString " and a receiver [in impl "))) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString "]"))))))))
(DTypeSig false "declaredMethodContext" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Int")))))
(DFunDef false "declaredMethodContext" ((PVar "table") (PVar "iface") (PVar "method")) (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "ifaceMethodArityKey") (EVar "iface")) (EVar "method"))) (EVar "table"))))
(DTypeSig false "leadingMethodDicts" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))))
(DFunDef false "leadingMethodDicts" ((PVar "method") (PVar "k") (PCons (PCon "PVar" (PVar "x") PWild PWild) (PVar "rest"))) (EIf (EBinOp "==" (EVar "x") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "$dict_")) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString "_"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString "")))) (EApp (EApp (EApp (EVar "leadingMethodDicts") (EVar "method")) (EBinOp "+" (EVar "k") (ELit (LInt 1)))) (EVar "rest")) (EVar "k")))
(DFunDef false "leadingMethodDicts" (PWild (PVar "k") PWild) (EVar "k"))
(DTypeSig true "validateImplSymbols" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateImplSymbols" ((PCon "CProgram" PWild PWild PWild (PVar "impls") PWild PWild)) (EApp (EApp (EDictApp "flatMap") (EVar "implSymbolFaults")) (EVar "impls")))
(DTypeSig false "implSymbolFaults" (TyFun (TyCon "CImplEntry") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "implSymbolFaults" ((PCon "CImplEntry" (PVar "method") PWild PWild (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PCon "ImplSym" (PVar "sym") PWild PWild) PWild PWild PWild))) (EBinOp "++" (EIf (EBinOp "==" (EVar "sym") (ELit (LString ""))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl symbol: entry has no stamped symbol [in impl ")) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString "]")))) (EListLit)) (EIf (EBinOp "==" (EVar "iface") (EApp (EVar "ifaceWordOfKey") (EVar "key"))) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl symbol: interface word `")) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "` is not the qualified word `"))) (EApp (EMethodRef "display") (EApp (EVar "ifaceWordOfKey") (EVar "key")))) (ELit (LString "` of its key [in impl "))) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString "]")))))))
(DFunDef false "implSymbolFaults" ((PCon "CImplEntry" (PVar "method") PWild PWild (PCon "CImplDefault" PWild (PVar "tag") PWild (PCon "ImplSym" (PVar "sym") (PVar "ifaceTag") (PVar "keyTag")) PWild PWild PWild))) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "sym") (ELit (LString ""))) (EBinOp "==" (EVar "ifaceTag") (ELit (LString "")))) (EBinOp "==" (EVar "keyTag") (ELit (LString "")))) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl symbol: default entry has no stamped symbol [in impl ")) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString "]")))) (EListLit)))
(DTypeSig true "validateImplSymbolInjectivity" (TyFun (TyCon "CProgram") (TyCon "Unit")))
(DFunDef false "validateImplSymbolInjectivity" ((PVar "cp")) (EMatch (EApp (EVar "implSymbolCollision") (EVar "cp")) (arm (PCon "Some" (PVar "message")) () (EApp (EVar "panic") (EVar "message"))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "implSymbolCollision" (TyFun (TyCon "CProgram") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "implSymbolCollision" ((PCon "CProgram" PWild PWild PWild (PVar "impls") PWild PWild)) (EApp (EApp (EVar "checkImplSymbolsInjective") (EApp (EApp (EVar "dedupBy") (EVar "implPreImageKey")) (EApp (EApp (EDictApp "flatMap") (EVar "taggedImplSymRow")) (EVar "impls")))) (EVar "omEmpty")))
(DTypeSig false "taggedImplSymRow" (TyFun (TyCon "CImplEntry") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")))))
(DFunDef false "taggedImplSymRow" ((PCon "CImplEntry" (PVar "m") PWild PWild (PCon "CImplTagged" PWild (PVar "key") PWild (PCon "ImplSym" (PVar "tag") PWild PWild) PWild PWild PWild))) (EListLit (ETuple (EVar "m") (EVar "tag") (EVar "key"))))
(DFunDef false "taggedImplSymRow" (PWild) (EListLit))
(DTypeSig false "implPreImageKey" (TyFun (TyTuple (TyCon "String") (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "implPreImageKey" ((PTuple (PVar "m") (PVar "tag") (PVar "key"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString ""))))
(DTypeSig false "checkImplSymbolsInjective" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "checkImplSymbolsInjective" ((PList) PWild) (EVar "None"))
(DFunDef false "checkImplSymbolsInjective" ((PCons (PTuple (PVar "m") (PVar "tag") (PVar "key")) (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "sym") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "mdk_impl_")) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString "_"))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "sym")) (EVar "seen")) (arm (PCon "None") () (EApp (EApp (EVar "checkImplSymbolsInjective") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "sym")) (EVar "key")) (EVar "seen")))) (arm (PCon "Some" (PVar "prev")) () (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "emitted impl-symbol collision: two DISTINCT impls of method `")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "` are emitted under one symbol.\ncollided symbol: "))) (EApp (EMethodRef "display") (EVar "sym"))) (ELit (LString "\nimpl 1 key: "))) (EApp (EMethodRef "display") (EVar "prev"))) (ELit (LString "\nimpl 2 key: "))) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString "\nTwo distinct impls cannot share one emitted symbol: the backend would define one body twice (the native link fails) or keep one and silently drop the other. The two keys above are the impls' canonical dispatch keys, spelled `<module>::<Interface>|<type arguments>|`. Since #1950 those keys are spelled into the symbol by `private_mangle.injectiveIdent`, which is INJECTIVE, so this is NOT a naming mistake you can rename your way out of -- it means the emitted-symbol scheme itself lost injectivity. Please report this message, with both keys above.")))))))))
(DTypeSig true "validateDictTags" (TyFun (TyCon "Backend") (TyFun (TyCon "CProgram") (TyCon "Unit"))))
(DFunDef false "validateDictTags" ((PVar "backend") (PVar "cp")) (EMatch (EApp (EApp (EVar "dictTagCollision") (EVar "backend")) (EVar "cp")) (arm (PCon "Some" (PVar "message")) () (EApp (EVar "panic") (EVar "message"))) (arm (PCon "None") () (ELit LUnit))))
(DTypeSig true "dictTagCollision" (TyFun (TyCon "Backend") (TyFun (TyCon "CProgram") (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "dictTagCollision" ((PVar "backend") (PCon "CProgram" PWild PWild PWild (PVar "impls") PWild PWild)) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "dedupBy") (EVar "dictRouteWordKey")) (EApp (EApp (EMethodRef "map") (EVar "dictRouteWordRow")) (EVar "impls")))) (DoExpr (EMatch (EApp (EApp (EApp (EApp (EVar "checkDictTagsInjective") (EVar "nativeDictTagSpace")) (EVar "hashName")) (EVar "rows")) (EVar "omEmpty")) (arm (PCon "Some" (PVar "message")) () (EApp (EVar "Some") (EVar "message"))) (arm (PCon "None") () (EMatch (EVar "backend") (arm (PCon "LlvmBackend") () (EVar "None")) (arm (PCon "WasmBackend") () (EApp (EApp (EApp (EApp (EVar "checkDictTagsInjective") (EVar "wasmDictTagSpace")) (EVar "dictTag")) (EVar "rows")) (EVar "omEmpty"))) (arm (PCon "EvalBackend") () (EVar "None"))))))))
(DTypeSig false "nativeDictTagSpace" (TyCon "String"))
(DFunDef false "nativeDictTagSpace" () (ELit (LString "native (LLVM) i64 dict-witness word `hashName` -- BOTH backends, since the wasm tag is this hash masked")))
(DTypeSig false "wasmDictTagSpace" (TyCon "String"))
(DFunDef false "wasmDictTagSpace" () (ELit (LString "wasm (WasmGC) 30-bit i31 dict tag `dictTag` (`hashName` masked to the low 30 bits) -- the full i64 tags are DISTINCT, so a native build of this program is correct; the wasm tag is this hash masked to a narrower width, which collides")))
(DTypeSig false "dictRouteWordRow" (TyFun (TyCon "CImplEntry") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "dictRouteWordRow" ((PCon "CImplEntry" (PVar "m") PWild PWild (PCon "CImplTagged" PWild (PVar "key") PWild PWild PWild PWild PWild))) (ETuple (EVar "m") (EVar "key")))
(DFunDef false "dictRouteWordRow" ((PCon "CImplEntry" (PVar "m") PWild PWild (PCon "CImplDefault" PWild PWild (PVar "key") PWild PWild PWild PWild))) (ETuple (EVar "m") (EVar "key")))
(DTypeSig false "dictRouteWordKey" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "String")))
(DFunDef false "dictRouteWordKey" ((PTuple (PVar "m") (PVar "w"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "w"))) (ELit (LString ""))))
(DTypeSig false "checkDictTagsInjective" (TyFun (TyCon "String") (TyFun (TyFun (TyCon "String") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyApp (TyCon "Option") (TyCon "String")))))))
(DFunDef false "checkDictTagsInjective" (PWild PWild (PList) PWild) (EVar "None"))
(DFunDef false "checkDictTagsInjective" ((PVar "space") (PVar "hash") (PCons (PTuple (PVar "m") (PVar "w")) (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "t") (EApp (EVar "intToString") (EApp (EMethodRef "hash") (EVar "w")))) (DoLet false false (PVar "k") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "t"))) (ELit (LString "")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "seen")) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "checkDictTagsInjective") (EVar "space")) (EMethodRef "hash")) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (EVar "w")) (EVar "seen")))) (arm (PCon "Some" (PVar "w0")) () (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "emitted dict-witness tag collision: two DISTINCT impls of method `")) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "` hash to one dispatch tag.\ntag space: "))) (EApp (EMethodRef "display") (EVar "space"))) (ELit (LString "\ncollided tag: "))) (EApp (EMethodRef "display") (EVar "t"))) (ELit (LString "\nroute word 1: "))) (EApp (EMethodRef "display") (EVar "w0"))) (ELit (LString "\nroute word 2: "))) (EApp (EMethodRef "display") (EVar "w"))) (ELit (LString "\nA dict witness carries this tag, and method `"))) (EApp (EMethodRef "display") (EVar "m"))) (ELit (LString "`'s shared dispatcher selects an impl by comparing it against every OTHER impl of that SAME method name -- these two words ARE compared against each other at that dispatcher, so this collision is live: whichever arm the emitter happened to emit FIRST wins every call through a dictionary, silently, at exit 0. The two words above are the impls' route words: either a bare head tycon or a canonical dispatch key spelled `<module>::<Interface>|<type arguments>|`. This is NOT a naming collision you can rename your way out of by making the names more different -- `hashName` is djb2, a radix-33 polynomial over a 74-code-point alphabet, so it is genuinely non-injective (`hashName \"Az\" == hashName \"BY\"`). One of the two words above may name a type or interface from the prelude or stdlib that you do not own -- rename the OTHER one, one of your own types or interfaces involved in this collision. Please also report this message, with both words above.")))))))))
(DTypeSig false "implBodyTag" (TyFun (TyCon "CImplBody") (TyCon "String")))
(DFunDef false "implBodyTag" ((PCon "CImplTagged" (PVar "tag") PWild PWild PWild PWild PWild PWild)) (EVar "tag"))
(DFunDef false "implBodyTag" ((PCon "CImplDefault" PWild (PVar "tag") PWild PWild PWild PWild PWild)) (EVar "tag"))
(DTypeSig true "renderCallRefusal" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "renderCallRefusal" ((PVar "bad")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "bad")))
(DTypeSig true "missingCatalogRows" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "missingCatalogRows" ((PVar "names")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "n")) (EApp (EVar "isNone") (EApp (EVar "catalogRow") (EVar "n"))))) (EVar "names")))
(DTypeSig true "missingRowsMessage" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "missingRowsMessage" ((PVar "missing")) (EBlock (DoLet false false (PVar "names") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "quoteName")) (EVar "missing")))) (DoExpr (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: runtime extern ")) (EApp (EMethodRef "display") (EVar "names"))) (ELit (LString " has no row in the extern catalog (compiler/backend/extern_catalog.mdk)"))))))
(DTypeSig false "quoteName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoteName" ((PVar "n")) (EBinOp "++" (EBinOp "++" (ELit (LString "'")) (EVar "n")) (ELit (LString "'"))))
(DTypeSig false "refuseMissingRows" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Unit")))
(DFunDef false "refuseMissingRows" ((PVar "names")) (EMatch (EApp (EVar "missingCatalogRows") (EVar "names")) (arm (PList) () (ELit LUnit)) (arm (PVar "missing") () (EApp (EVar "panic") (EApp (EVar "missingRowsMessage") (EVar "missing"))))))
(DTypeSig true "renderExternFinding" (TyFun (TyCon "ExternFinding") (TyCon "String")))
(DFunDef false "renderExternFinding" ((PCon "ExternFinding" (PVar "name") (PVar "backend") (PVar "kind") (PVar "why") (PVar "binding"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString ": runtime extern '"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "' is not available on the "))) (EApp (EMethodRef "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString " backend ("))) (EApp (EMethodRef "display") (EApp (EVar "gapKindName") (EVar "kind")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "why"))) (ELit (LString ") [in "))) (EApp (EMethodRef "display") (EVar "binding"))) (ELit (LString "]"))))
(DTypeSig true "renderExternRefusal" (TyFun (TyApp (TyCon "List") (TyCon "ExternFinding")) (TyCon "String")))
(DFunDef false "renderExternRefusal" ((PVar "findings")) (EApp (EApp (EVar "renderExternRefusalUnder") (EUnOp "!" (EVar "checkedTarget"))) (EVar "findings")))
(DTypeSig true "renderExternRefusalUnder" (TyFun (TyApp (TyCon "Option") (TyCon "CheckedTarget")) (TyFun (TyApp (TyCon "List") (TyCon "ExternFinding")) (TyCon "String"))))
(DFunDef false "renderExternRefusalUnder" ((PCon "None") (PVar "findings")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EMethodRef "map") (EVar "renderExternFinding")) (EVar "findings"))))
(DFunDef false "renderExternRefusalUnder" ((PCon "Some" (PVar "t")) (PVar "findings")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "renderFindingUnder") (EVar "t"))) (EVar "findings"))))
(DTypeSig false "renderFindingUnder" (TyFun (TyCon "CheckedTarget") (TyFun (TyCon "ExternFinding") (TyCon "String"))))
(DFunDef false "renderFindingUnder" ((PCon "CheckedTarget" (PVar "profile") (PVar "labels")) (PAs "f" (PCon "ExternFinding" (PVar "name") (PVar "backend") PWild PWild PWild))) (EBlock (DoLet false false (PVar "declared") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "labels")))) (DoLet false false (PVar "withheldNote") (EMatch (EApp (EApp (EVar "withheldLabels") (EVar "profile")) (EVar "declared")) (arm (PList) () (ELit (LString ""))) (arm (PVar "withheld") () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "; the target `")) (EApp (EMethodRef "display") (EApp (EVar "profileName") (EVar "profile")))) (ELit (LString "` does not grant "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EVar "withheld")))) (ELit (LString ", which `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` performs")))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "renderExternFinding") (EVar "f")))) (ELit (LString ""))) (EApp (EMethodRef "display") (EVar "withheldNote"))) (ELit (LString "; "))) (EApp (EMethodRef "display") (EApp (EVar "checkMissedNote") (EVar "backend")))) (ELit (LString ""))))))
(DTypeSig false "checkMissedNote" (TyFun (TyCon "Backend") (TyCon "String")))
(DFunDef false "checkMissedNote" ((PVar "backend")) (EBinOp "++" (EBinOp "++" (ELit (LString "`check` should have refused this program before the ")) (EApp (EMethodRef "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString " backend saw it, so this is a bug in the compiler"))))
(DData Public "CheckedTarget" () ((variant "CheckedTarget" (ConPos (TyCon "TargetProfile") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))))) ())
(DTypeSig true "checkedTargetOf" (TyFun (TyCon "TargetProfile") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "CheckedTarget"))))
(DFunDef false "checkedTargetOf" ((PVar "profile") (PVar "runtimeDecls")) (EApp (EApp (EVar "CheckedTarget") (EVar "profile")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "externLabels") (EVar "runtimeDecls"))) (EVar "omEmpty"))))
(DTypeSig true "checkedTarget" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "CheckedTarget"))))
(DFunDef false "checkedTarget" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "externLabels" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "externLabels" ((PList)) (EListLit))
(DFunDef false "externLabels" ((PCons (PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n")) (rf "edTy" (PVar "ty"))) true)) (PVar "rest"))) (EBinOp "::" (ETuple (EVar "n") (EApp (EVar "resultLabels") (EVar "ty"))) (EApp (EVar "externLabels") (EVar "rest"))))
(DFunDef false "externLabels" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest"))) (EApp (EVar "externLabels") (EBinOp "::" (EVar "d") (EVar "rest"))))
(DFunDef false "externLabels" ((PCons PWild (PVar "rest"))) (EApp (EVar "externLabels") (EVar "rest")))
(DTypeSig false "resultLabels" (TyFun (TyCon "Ty") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "resultLabels" ((PCon "TyFun" PWild (PVar "r"))) (EApp (EVar "resultLabels") (EVar "r")))
(DFunDef false "resultLabels" ((PCon "TyConstrained" PWild (PVar "t"))) (EApp (EVar "resultLabels") (EVar "t")))
(DFunDef false "resultLabels" ((PCon "TyEffect" (PVar "atoms") PWild PWild)) (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (EFieldAccess (EVar "a") "eatLabel"))) (EVar "atoms")))
(DFunDef false "resultLabels" (PWild) (EListLit))
(DTypeSig true "unrefusedExternMessage" (TyFun (TyCon "Backend") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "unrefusedExternMessage" ((PVar "backend") (PVar "name")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: the ")) (EApp (EMethodRef "display") (EApp (EVar "backendName") (EVar "backend")))) (ELit (LString " emitter reached runtime extern '"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "', which it does not lower, without a refusal from validateExterns (compiler/backend/core_validate.mdk)"))))
(DTypeSig false "programNames" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "programNames" ((PList) (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "programNames" ((PList) (PCons (PTuple (PVar "ctor") PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "programNames") (EListLit)) (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "ctor")) (ELit LUnit)) (EVar "acc"))))
(DFunDef false "programNames" ((PCons (PCon "CBind" (PVar "name") PWild PWild PWild) (PVar "rest")) (PVar "ctors") (PVar "acc")) (EApp (EApp (EApp (EVar "programNames") (EVar "rest")) (EVar "ctors")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EVar "acc"))))
(DTypeSig false "isProgramName" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isProgramName" ((PVar "top") (PVar "x")) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "top")) (EApp (EApp (EVar "omHasKey") (EBinOp "++" (ELit (LString "core__")) (EVar "x"))) (EVar "top"))))
(DData Private "Walk" () ((variant "Walk" (ConPos (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "List") (TyCon "ExternFinding")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))) ())
(DTypeSig false "noFindings" (TyCon "Walk"))
(DFunDef false "noFindings" () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "omEmpty")) (EListLit)) (EListLit)) (EListLit)) (EListLit)) (EListLit)) (EListLit)) (EListLit)))
(DData Private "Ctx" () ((variant "Ctx" (ConPos (TyCon "Backend") (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyCon "ArityEnv") (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyCon "EvFacts") (TyCon "String")))) ())
(DData Private "EvFacts" () ((variant "EvFacts" (ConNamed (field "efRequires" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "efSupers" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "efMethods" (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact")))) (field "efExterns" (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")))))) ())
(DTypeSig false "walkProgram" (TyFun (TyCon "Backend") (TyFun (TyCon "CProgram") (TyCon "Walk"))))
(DFunDef false "walkProgram" ((PVar "backend") (PAs "prog" (PCon "CProgram" (PVar "groups") (PVar "ctors") PWild (PVar "impls") (PVar "mctx") (PVar "facts")))) (EBlock (DoLet false false (PVar "top") (EApp (EApp (EApp (EVar "programNames") (EVar "groups")) (EVar "ctors")) (EVar "omEmpty"))) (DoLet false false (PVar "env") (EApp (EVar "programArities") (EVar "prog"))) (DoLet false false (PVar "ctx") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Ctx") (EVar "backend")) (EVar "top")) (EVar "env")) (EApp (EApp (EVar "omFromPairs") (EVar "mctx")) (EVar "omEmpty"))) (EApp (EApp (EVar "dictParamCounts") (EVar "groups")) (EVar "omEmpty"))) (ERecordCreate "EvFacts" ((fa "efRequires" (EApp (EApp (EVar "omFromPairs") (EFieldAccess (EVar "facts") "factRequires")) (EVar "omEmpty"))) (fa "efSupers" (EApp (EApp (EVar "omFromPairs") (EFieldAccess (EVar "facts") "factSupers")) (EVar "omEmpty"))) (fa "efMethods" (EApp (EVar "indexMethodResults") (EFieldAccess (EVar "facts") "factMethodResults"))) (fa "efExterns" (EFieldAccess (EVar "facts") "factExterns"))))) (ELit (LString "")))) (DoExpr (EApp (EApp (EApp (EVar "walkImpls") (EVar "ctx")) (EVar "impls")) (EApp (EApp (EApp (EVar "walkBinds") (EVar "ctx")) (EVar "groups")) (EVar "noFindings"))))))
(DTypeSig false "walkBinds" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyCon "Walk") (TyCon "Walk")))))
(DFunDef false "walkBinds" (PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkBinds" ((PVar "ctx") (PCons (PCon "CBind" (PVar "name") (PVar "clauses") PWild PWild) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EVar "walkBinds") (EVar "ctx")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkClauses") (EApp (EApp (EVar "inBinding") (EVar "ctx")) (EVar "name"))) (EVar "omEmpty")) (EVar "clauses")) (EVar "w"))))
(DTypeSig false "walkImpls" (TyFun (TyCon "Ctx") (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "Walk") (TyCon "Walk")))))
(DFunDef false "walkImpls" (PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkImpls" ((PVar "ctx") (PCons (PCon "CImplEntry" (PVar "method") PWild PWild (PVar "body")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EVar "walkImpls") (EVar "ctx")) (EVar "rest")) (EApp (EApp (EApp (EVar "walkImplBody") (EApp (EApp (EVar "inBinding") (EVar "ctx")) (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString ""))))) (EVar "body")) (EVar "w"))))
(DTypeSig false "inBinding" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyCon "Ctx"))))
(DFunDef false "inBinding" ((PCon "Ctx" (PVar "backend") (PVar "top") (PVar "env") (PVar "mctx") (PVar "dcounts") (PVar "facts") PWild) (PVar "binding")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Ctx") (EVar "backend")) (EVar "top")) (EVar "env")) (EVar "mctx")) (EVar "dcounts")) (EVar "facts")) (EVar "binding")))
(DTypeSig false "ctxBinding" (TyFun (TyCon "Ctx") (TyCon "String")))
(DFunDef false "ctxBinding" ((PCon "Ctx" PWild PWild PWild PWild PWild PWild (PVar "binding"))) (EVar "binding"))
(DTypeSig false "walkImplBody" (TyFun (TyCon "Ctx") (TyFun (TyCon "CImplBody") (TyFun (TyCon "Walk") (TyCon "Walk")))))
(DFunDef false "walkImplBody" ((PVar "ctx") (PCon "CImplTagged" (PVar "tag") PWild PWild PWild PWild (PVar "pats") (PVar "body")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EApp (EApp (EVar "inBinding") (EVar "ctx")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "ctxBinding") (EVar "ctx")))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString ""))))) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "omEmpty"))) (EVar "body")) (EVar "w")))
(DFunDef false "walkImplBody" ((PVar "ctx") (PCon "CImplDefault" PWild (PVar "tag") PWild PWild PWild (PVar "pats") (PVar "body")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EApp (EApp (EVar "inBinding") (EVar "ctx")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "ctxBinding") (EVar "ctx")))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString ""))))) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "omEmpty"))) (EVar "body")) (EVar "w")))
(DTypeSig false "walkClauses" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkClauses" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkClauses" ((PVar "ctx") (PVar "scope") (PCons (PCon "CClause" (PVar "pats") (PVar "body")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkClauses") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "scope"))) (EVar "body")) (EVar "w"))))
(DTypeSig false "walkE" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyCon "CExpr") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CVar" (PVar "x") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "noteVar") (EVar "ctx")) (EVar "scope")) (EVar "x")) (EVar "w")))
(DFunDef false "walkE" (PWild PWild (PCon "CLit" PWild) (PVar "w")) (EVar "w"))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CApp" (PVar "f") (PVar "args") (PVar "site")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "args")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "f")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteCall") (EVar "ctx")) (EVar "scope")) (EVar "f")) (EVar "args")) (EVar "site")) (EVar "w")))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CLam" (PVar "pats") (PVar "body")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EApp (EApp (EVar "bindPatsScope") (EVar "pats")) (EVar "scope"))) (EVar "body")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CLet" (PVar "recF") (PVar "pat") (PVar "rhs") (PVar "body")) (PVar "w")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EApp (EVar "bindLetScope") (EVar "pat")) (EVar "rhs")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "inner")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EIf (EVar "recF") (EVar "inner") (EVar "scope"))) (EVar "rhs")) (EVar "w"))))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CLetGroup" (PVar "binds") (PVar "body")) (PVar "w")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindGroupScope") (EVar "binds")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "inner")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkLocalBinds") (EVar "ctx")) (EVar "inner")) (EVar "binds")) (EVar "w"))))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CMatch" (PVar "scrut") (PVar "arms")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "ctx")) (EVar "scope")) (EVar "arms")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "scrut")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "ctx")) (EVar "scope")) (EVar "arms")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "scrut")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "c") (EVar "t") (EVar "f"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "l") (EVar "r"))) (EApp (EApp (EApp (EApp (EVar "noteScalarOperator") (EVar "ctx")) (EVar "op")) (EVar "tag")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CUnOp" PWild (PVar "x")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "x")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CTuple" (PVar "es")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "es")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CList" (PVar "es")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "es")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRecord" (PVar "name") (PVar "fields")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "fields")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteRecord") (EVar "ctx")) (ELit (LString "CRecord"))) (EVar "name")) (EVar "True")) (EVar "fields")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CFieldAccess" (PVar "x") (PVar "label") (PVar "name") (PVar "ord")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "noteAccess") (EVar "ctx")) (EVar "label")) (EVar "name")) (EVar "ord")) (EVar "w"))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "fields")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "base")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteRecord") (EVar "ctx")) (ELit (LString "CRecordUpdate"))) (EVar "name")) (EVar "False")) (EVar "fields")) (EVar "w")))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "fields")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "base")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "noteRecord") (EVar "ctx")) (ELit (LString "CVariantUpdate"))) (EVar "con")) (EVar "False")) (EVar "fields")) (EVar "w")))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CArray" (PVar "es")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "es")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CIndex" (PVar "a") (PVar "i")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "i"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CStringIndex" (PVar "a") (PVar "i")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "i"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CListIndex" (PVar "a") (PVar "i")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "i"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PCon "CBlock" (PVar "stmts")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "scope")) (EVar "stmts")) (EVar "w")))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PAs "node" (PCon "CMethod" (PVar "name") (PCon "MethodEvidence" (PVar "iface") PWild PWild PWild (PVar "meths")))) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "noteEvidence") (EVar "ctx")) (EVar "scope")) (EVar "node")) (EApp (EApp (EApp (EApp (EVar "noteMethodResult") (EVar "ctx")) (EVar "name")) (EVar "iface")) (EApp (EApp (EApp (EApp (EApp (EVar "noteMethodContext") (EVar "ctx")) (EVar "name")) (EVar "iface")) (EApp (EVar "listLen") (EVar "meths"))) (EVar "w")))))
(DFunDef false "walkE" ((PVar "ctx") (PVar "scope") (PAs "node" (PCon "CDict" PWild PWild)) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "noteEvidence") (EVar "ctx")) (EVar "scope")) (EVar "node")) (EVar "w")))
(DTypeSig false "noteScalarOperator" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "noteScalarOperator" (PWild PWild (PLit (LString "")) (PVar "w")) (EVar "w"))
(DFunDef false "noteScalarOperator" ((PCon "Ctx" PWild PWild PWild PWild PWild PWild (PVar "binding")) (PVar "op") (PVar "tag") (PCon "Walk" (PVar "seen") (PVar "found") (PVar "records") (PVar "scalar") (PVar "calls") (PVar "ctxs") (PVar "evs") (PVar "results"))) (EIf (EApp (EApp (EVar "scalarOperatorTagAllowed") (EVar "op")) (EVar "tag")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "seen")) (EVar "found")) (EVar "records")) (EVar "scalar")) (EVar "calls")) (EVar "ctxs")) (EVar "evs")) (EVar "results")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "seen")) (EVar "found")) (EVar "records")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "scalar binop: operator `")) (EApp (EMethodRef "display") (EVar "op"))) (ELit (LString "` cannot carry scalar tag `"))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString "` [in "))) (EApp (EMethodRef "display") (EVar "binding"))) (ELit (LString "]"))) (EVar "scalar"))) (EVar "calls")) (EVar "ctxs")) (EVar "evs")) (EVar "results"))))
(DTypeSig false "scalarOperatorTagAllowed" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "scalarOperatorTagAllowed" ((PVar "op") (PVar "tag")) (EIf (EApp (EVar "scalarArithmeticOperator") (EVar "op")) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "tag") (ELit (LString "Int"))) (EBinOp "==" (EVar "tag") (ELit (LString "Float")))) (EApp (EVar "isFixedIntHead") (EVar "tag"))) (EIf (EApp (EVar "scalarComparisonOperator") (EVar "op")) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "tag") (ELit (LString "Int"))) (EBinOp "==" (EVar "tag") (ELit (LString "Char")))) (EApp (EVar "isBoxed64Head") (EVar "tag"))) (EVar "False"))))
(DTypeSig false "scalarArithmeticOperator" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "scalarArithmeticOperator" ((PLit (LString "+"))) (EVar "True"))
(DFunDef false "scalarArithmeticOperator" ((PLit (LString "-"))) (EVar "True"))
(DFunDef false "scalarArithmeticOperator" ((PLit (LString "*"))) (EVar "True"))
(DFunDef false "scalarArithmeticOperator" ((PLit (LString "/"))) (EVar "True"))
(DFunDef false "scalarArithmeticOperator" ((PLit (LString "%"))) (EVar "True"))
(DFunDef false "scalarArithmeticOperator" (PWild) (EVar "False"))
(DTypeSig false "scalarComparisonOperator" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "scalarComparisonOperator" ((PLit (LString "=="))) (EVar "True"))
(DFunDef false "scalarComparisonOperator" ((PLit (LString "/="))) (EVar "True"))
(DFunDef false "scalarComparisonOperator" ((PLit (LString "<"))) (EVar "True"))
(DFunDef false "scalarComparisonOperator" ((PLit (LString ">"))) (EVar "True"))
(DFunDef false "scalarComparisonOperator" ((PLit (LString "<="))) (EVar "True"))
(DFunDef false "scalarComparisonOperator" ((PLit (LString ">="))) (EVar "True"))
(DFunDef false "scalarComparisonOperator" (PWild) (EVar "False"))
(DTypeSig true "validateDispatchEvidence" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateDispatchEvidence" ((PVar "prog")) (EMatch (EApp (EApp (EVar "walkProgram") (EVar "LlvmBackend")) (EVar "prog")) (arm (PCon "Walk" PWild PWild PWild PWild PWild PWild (PVar "bad") PWild) () (EApp (EVar "reverseL") (EVar "bad")))))
(DTypeSig false "dictParamCounts" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int")))))
(DFunDef false "dictParamCounts" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "dictParamCounts" ((PCons (PCon "CBind" (PVar "name") (PCons (PCon "CClause" (PVar "pats") PWild) PWild) PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "dictParamCounts") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EApp (EVar "leadingDictParams") (EVar "pats"))) (EVar "acc"))))
(DFunDef false "dictParamCounts" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "dictParamCounts") (EVar "rest")) (EVar "acc")))
(DTypeSig false "noteEvidence" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyCon "CExpr") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "noteEvidence" ((PCon "Ctx" PWild PWild (PVar "env") PWild (PVar "dcounts") (PVar "facts") (PVar "binding")) (PVar "scope") (PVar "node") (PCon "Walk" (PVar "seen") (PVar "found") (PVar "bad") (PVar "scalar") (PVar "calls") (PVar "ctxs") (PVar "evs") (PVar "results"))) (EBlock (DoLet false false (PVar "why") (EApp (EApp (EApp (EApp (EApp (EVar "evidenceFaults") (EVar "env")) (EVar "dcounts")) (EVar "facts")) (EVar "scope")) (EVar "node"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "seen")) (EVar "found")) (EVar "bad")) (EVar "scalar")) (EVar "calls")) (EVar "ctxs")) (EBinOp "++" (EApp (EVar "reverseL") (EApp (EApp (EMethodRef "map") (ELam ((PVar "f")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "dispatch evidence: ")) (EApp (EMethodRef "display") (EApp (EVar "headText") (EVar "node")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString " [in "))) (EApp (EMethodRef "display") (EVar "binding"))) (ELit (LString "]"))))) (EVar "why"))) (EVar "evs"))) (EVar "results")))))
(DTypeSig false "evidenceFaults" (TyFun (TyCon "ArityEnv") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "EvFacts") (TyFun (TyCon "CallScope") (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "evidenceFaults" ((PVar "env") PWild (PVar "facts") (PVar "scope") (PAs "node" (PCon "CMethod" (PVar "name") (PCon "MethodEvidence" (PVar "iface") PWild (PVar "route") (PVar "prereqs") (PVar "meths"))))) (EBlock (DoLet false false (PVar "routes") (EBinOp "::" (EVar "route") (EBinOp "++" (EVar "prereqs") (EVar "meths")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "unboundFaults") (EVar "scope")) (EVar "routes")) (EApp (EApp (EDictApp "flatMap") (EVar "routeShapeFaults")) (EVar "routes"))) (EMatch (EVar "route") (arm (PCon "RKey" (PVar "key") PWild PWild) () (EMatch (EApp (EApp (EApp (EVar "definedArityOf") (EVar "env")) (EVar "scope")) (EVar "node")) (arm (PCon "Some" PWild) () (EListLit)) (arm (PCon "None") () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "names instance `")) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString "` that has no entry for `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "`"))))))) (arm PWild () (EListLit)))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "builtDictFaults") (EVar "facts"))) (EBinOp "++" (EBinOp "++" (EApp (EVar "headParts") (EVar "route")) (EVar "prereqs")) (EVar "meths")))) (EApp (EApp (EVar "ifaceWordFaults") (EVar "iface")) (EVar "route"))) (EApp (EApp (EVar "methodNoRouteFault") (EVar "iface")) (EVar "route"))))))
(DFunDef false "evidenceFaults" (PWild (PVar "dcounts") (PVar "facts") (PVar "scope") (PCon "CDict" (PVar "f") (PVar "routes"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "unboundFaults") (EVar "scope")) (EVar "routes")) (EApp (EApp (EDictApp "flatMap") (EVar "routeShapeFaults")) (EVar "routes"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "builtDictFaults") (EVar "facts"))) (EVar "routes"))) (EApp (EApp (EDictApp "flatMap") (EVar "noRouteFault")) (EVar "routes"))) (EIf (EApp (EApp (EVar "omHasKey") (EVar "f")) (EVar "scope")) (EListLit) (EMatch (EApp (EApp (EVar "omLookup") (EVar "f")) (EVar "dcounts")) (arm (PCon "Some" (PVar "k")) () (EIf (EBinOp "==" (EVar "k") (EApp (EVar "listLen") (EVar "routes"))) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "supplies ")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "routes"))))) (ELit (LString " dictionaries, `"))) (EApp (EMethodRef "display") (EVar "f"))) (ELit (LString "` takes "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString "")))))) (arm (PCon "None") () (EListLit))))))
(DFunDef false "evidenceFaults" (PWild PWild PWild PWild PWild) (EListLit))
(DTypeSig false "headParts" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "Route"))))
(DFunDef false "headParts" ((PCon "RKey" PWild (PVar "reqs") (PVar "sups"))) (EBinOp "++" (EVar "reqs") (EVar "sups")))
(DFunDef false "headParts" ((PCon "RLocal" PWild (PVar "ds"))) (EVar "ds"))
(DFunDef false "headParts" ((PCon "RProj" (PVar "r") PWild)) (EListLit (EVar "r")))
(DFunDef false "headParts" (PWild) (EListLit))
(DTypeSig false "builtDictFaults" (TyFun (TyCon "EvFacts") (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "builtDictFaults" ((PVar "facts") (PCon "RKey" (PVar "key") (PVar "reqs") (PVar "sups"))) (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "key")) (EFieldAccess (EVar "facts") "efRequires")))) (DoLet false false (PVar "word") (EApp (EVar "ifaceWordOfKey") (EVar "key"))) (DoLet false false (PVar "k") (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "word")) (EFieldAccess (EVar "facts") "efSupers")))) (DoExpr (EBinOp "++" (EBinOp "++" (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "reqs")) (EVar "n")) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "builds instance `")) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString "` from "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "reqs"))))) (ELit (LString " prerequisite dictionaries, it requires "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString ""))))) (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "sups")) (EVar "k")) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "builds instance `")) (EApp (EMethodRef "display") (EVar "key"))) (ELit (LString "` with "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "sups"))))) (ELit (LString " super dictionaries, `"))) (EApp (EMethodRef "display") (EVar "word"))) (ELit (LString "` has "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString "")))))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "builtDictFaults") (EVar "facts"))) (EBinOp "++" (EVar "reqs") (EVar "sups")))))))
(DFunDef false "builtDictFaults" ((PVar "facts") (PCon "RLocal" PWild (PVar "ds"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "builtDictFaults") (EVar "facts"))) (EVar "ds")))
(DFunDef false "builtDictFaults" ((PVar "facts") (PCon "RProj" (PVar "r") PWild)) (EApp (EApp (EVar "builtDictFaults") (EVar "facts")) (EVar "r")))
(DFunDef false "builtDictFaults" (PWild PWild) (EListLit))
(DTypeSig false "ifaceWordFaults" (TyFun (TyCon "String") (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "ifaceWordFaults" ((PLit (LString "")) (PCon "RKey" PWild PWild PWild)) (EListLit (ELit (LString "dispatches with no interface word"))))
(DFunDef false "ifaceWordFaults" ((PLit (LString "")) (PCon "RDict" PWild)) (EListLit (ELit (LString "dispatches with no interface word"))))
(DFunDef false "ifaceWordFaults" ((PLit (LString "")) (PCon "RDictFwd" PWild)) (EListLit (ELit (LString "dispatches with no interface word"))))
(DFunDef false "ifaceWordFaults" ((PLit (LString "")) (PCon "RProj" PWild PWild)) (EListLit (ELit (LString "dispatches with no interface word"))))
(DFunDef false "ifaceWordFaults" (PWild PWild) (EListLit))
(DTypeSig false "methodNoRouteFault" (TyFun (TyCon "String") (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "methodNoRouteFault" ((PLit (LString "")) PWild) (EListLit))
(DFunDef false "methodNoRouteFault" (PWild (PCon "RNone")) (EListLit (ELit (LString "has no route"))))
(DFunDef false "methodNoRouteFault" (PWild PWild) (EListLit))
(DTypeSig false "noRouteFault" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "noRouteFault" ((PCon "RNone")) (EListLit (ELit (LString "has a dictionary slot with no route"))))
(DFunDef false "noRouteFault" (PWild) (EListLit))
(DTypeSig false "unboundFaults" (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "Route")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "unboundFaults" ((PVar "scope") (PVar "routes")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "d")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "d")) (EVar "scope")) (EListLit) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "reads dictionary `")) (EApp (EMethodRef "display") (EVar "d"))) (ELit (LString "`, which is not bound here"))))))) (EApp (EApp (EDictApp "flatMap") (EVar "givenNames")) (EVar "routes"))))
(DTypeSig false "routeShapeFaults" (TyFun (TyCon "Route") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "routeShapeFaults" ((PCon "RScalar" (PVar "tag"))) (EListLit (EBinOp "++" (EBinOp "++" (ELit (LString "carries scalar route `")) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString "`")))))
(DFunDef false "routeShapeFaults" ((PCon "RProj" (PVar "r") PWild)) (EBinOp "++" (EIf (EApp (EVar "givenRooted") (EVar "r")) (EListLit) (EListLit (ELit (LString "projects from a route that is not a given dictionary")))) (EApp (EVar "routeShapeFaults") (EVar "r"))))
(DFunDef false "routeShapeFaults" ((PCon "RKey" PWild (PVar "reqs") (PVar "sups"))) (EApp (EApp (EDictApp "flatMap") (EVar "routeShapeFaults")) (EBinOp "++" (EVar "reqs") (EVar "sups"))))
(DFunDef false "routeShapeFaults" ((PCon "RLocal" PWild (PVar "ds"))) (EApp (EApp (EDictApp "flatMap") (EVar "routeShapeFaults")) (EVar "ds")))
(DFunDef false "routeShapeFaults" (PWild) (EListLit))
(DTypeSig false "givenRooted" (TyFun (TyCon "Route") (TyCon "Bool")))
(DFunDef false "givenRooted" ((PCon "RDict" PWild)) (EVar "True"))
(DFunDef false "givenRooted" ((PCon "RDictFwd" PWild)) (EVar "True"))
(DFunDef false "givenRooted" ((PCon "RProj" (PVar "r") PWild)) (EApp (EVar "givenRooted") (EVar "r")))
(DFunDef false "givenRooted" (PWild) (EVar "False"))
(DTypeSig false "noteMethodContext" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Walk") (TyCon "Walk")))))))
(DFunDef false "noteMethodContext" ((PCon "Ctx" PWild PWild PWild (PVar "mctx") PWild PWild (PVar "binding")) (PVar "name") (PVar "iface") (PVar "n") (PAs "w" (PCon "Walk" (PVar "seen") (PVar "found") (PVar "bad") (PVar "scalar") (PVar "calls") (PVar "ctxs") (PVar "evs") (PVar "results")))) (EBlock (DoLet false false (PVar "k") (EApp (EApp (EApp (EVar "declaredMethodContext") (EVar "mctx")) (EVar "iface")) (EVar "name"))) (DoExpr (EIf (EBinOp "==" (EVar "n") (EVar "k")) (EVar "w") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "seen")) (EVar "found")) (EVar "bad")) (EVar "scalar")) (EVar "calls")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "method context: method ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " supplies "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " method routes, `"))) (EApp (EMethodRef "display") (EVar "iface"))) (ELit (LString "` declares "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString " [in "))) (EApp (EMethodRef "display") (EVar "binding"))) (ELit (LString "]"))) (EVar "ctxs"))) (EVar "evs")) (EVar "results"))))))
(DTypeSig false "noteAccess" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Walk") (TyCon "Walk")))))))
(DFunDef false "noteAccess" ((PVar "ctx") (PLit (LString "value")) (PVar "name") (PVar "ord") (PVar "w")) (EIf (EBinOp "==" (EVar "ord") (EUnOp "-" (ELit (LInt 1)))) (EVar "w") (EApp (EApp (EApp (EApp (EVar "noteRecordBad") (EVar "ctx")) (ELit (LString "CFieldAccess"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ".value: a Ref read stamped with field ordinal "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "ord")))) (ELit (LString "")))) (EVar "w"))))
(DFunDef false "noteAccess" ((PVar "ctx") (PVar "label") (PVar "name") (PVar "ord") (PVar "w")) (EIf (EBinOp ">=" (EVar "ord") (ELit (LInt 0))) (EVar "w") (EApp (EApp (EApp (EApp (EVar "noteRecordBad") (EVar "ctx")) (ELit (LString "CFieldAccess"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString ": unstamped field ordinal")))) (EVar "w"))))
(DTypeSig false "noteRecord" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))))
(DFunDef false "noteRecord" ((PVar "ctx") (PVar "node") (PVar "name") (PVar "literal") (PVar "fields") (PVar "w")) (EIf (EApp (EApp (EApp (EApp (EVar "ordinalsOk") (EVar "literal")) (ELit (LInt 0))) (EUnOp "-" (ELit (LInt 1)))) (EVar "fields")) (EVar "w") (EApp (EApp (EApp (EApp (EVar "noteRecordBad") (EVar "ctx")) (EVar "node")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ": field ordinals ["))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "fieldOrdinalText")) (EVar "fields"))))) (ELit (LString "] are not "))) (EApp (EMethodRef "display") (EIf (EVar "literal") (ELit (LString "the declared positions")) (ELit (LString "strictly ascending"))))) (ELit (LString "")))) (EVar "w"))))
(DTypeSig false "ordinalsOk" (TyFun (TyCon "Bool") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyCon "Bool"))))))
(DFunDef false "ordinalsOk" (PWild PWild PWild (PList)) (EVar "True"))
(DFunDef false "ordinalsOk" ((PVar "literal") (PVar "pos") (PVar "prev") (PCons (PCon "CField" PWild (PVar "o") PWild) (PVar "rest"))) (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "o") (ELit (LInt 0))) (EIf (EVar "literal") (EBinOp "==" (EVar "o") (EVar "pos")) (EBinOp ">" (EVar "o") (EVar "prev")))) (EApp (EApp (EApp (EApp (EVar "ordinalsOk") (EVar "literal")) (EBinOp "+" (EVar "pos") (ELit (LInt 1)))) (EVar "o")) (EVar "rest"))))
(DTypeSig false "fieldOrdinalText" (TyFun (TyCon "CField") (TyCon "String")))
(DFunDef false "fieldOrdinalText" ((PCon "CField" (PVar "k") (PVar "o") PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "o")))) (ELit (LString ""))))
(DTypeSig false "noteRecordBad" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "noteRecordBad" ((PCon "Ctx" PWild PWild PWild PWild PWild PWild (PVar "binding")) (PVar "node") (PVar "why") (PCon "Walk" (PVar "seen") (PVar "found") (PVar "bad") (PVar "scalar") (PVar "calls") (PVar "ctxs") (PVar "evs") (PVar "results"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "seen")) (EVar "found")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "record: ")) (EApp (EMethodRef "display") (EVar "node"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "why"))) (ELit (LString " [in "))) (EApp (EMethodRef "display") (EVar "binding"))) (ELit (LString "]"))) (EVar "bad"))) (EVar "scalar")) (EVar "calls")) (EVar "ctxs")) (EVar "evs")) (EVar "results")))
(DTypeSig false "noteCall" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyFun (TyCon "CallSite") (TyFun (TyCon "Walk") (TyCon "Walk"))))))))
(DFunDef false "noteCall" ((PVar "ctx") PWild PWild (PList) PWild (PVar "w")) (EApp (EApp (EApp (EVar "noteCallBad") (EVar "ctx")) (ELit (LString "application with no arguments"))) (EVar "w")))
(DFunDef false "noteCall" ((PVar "ctx") PWild (PCon "CApp" PWild PWild PWild) PWild PWild (PVar "w")) (EApp (EApp (EApp (EVar "noteCallBad") (EVar "ctx")) (ELit (LString "application whose head is an application"))) (EVar "w")))
(DFunDef false "noteCall" ((PAs "ctx" (PCon "Ctx" PWild PWild (PVar "env") PWild PWild PWild PWild)) (PVar "scope") (PVar "hd") (PVar "args") (PCon "CallSite" (PVar "mode") PWild) (PVar "w")) (EBlock (DoLet false false (PVar "n") (EApp (EVar "listLen") (EVar "args"))) (DoLet false false (PVar "arity") (EApp (EApp (EApp (EVar "definedArityOf") (EVar "env")) (EVar "scope")) (EVar "hd"))) (DoExpr (EIf (EApp (EApp (EVar "sameMode") (EApp (EApp (EVar "callModeFor") (EVar "arity")) (EVar "n"))) (EVar "mode")) (EVar "w") (EMatch (EVar "arity") (arm (PCon "Some" (PVar "k")) () (EApp (EApp (EApp (EVar "noteCallBad") (EVar "ctx")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "headText") (EVar "hd")))) (ELit (LString " applied to "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "n")))) (ELit (LString " of "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "k")))) (ELit (LString ", stamped "))) (EApp (EMethodRef "display") (EApp (EVar "callModeSexp") (EVar "mode")))) (ELit (LString "")))) (EVar "w"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "noteCallBad") (EVar "ctx")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "headText") (EVar "hd")))) (ELit (LString " has no static arity, stamped "))) (EApp (EMethodRef "display") (EApp (EVar "callModeSexp") (EVar "mode")))) (ELit (LString "")))) (EVar "w"))))))))
(DTypeSig false "sameMode" (TyFun (TyCon "CallMode") (TyFun (TyCon "CallMode") (TyCon "Bool"))))
(DFunDef false "sameMode" ((PCon "CallExact") (PCon "CallExact")) (EVar "True"))
(DFunDef false "sameMode" ((PCon "CallPartial" (PVar "a")) (PCon "CallPartial" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "sameMode" ((PCon "CallOver" (PVar "a")) (PCon "CallOver" (PVar "b"))) (EBinOp "==" (EVar "a") (EVar "b")))
(DFunDef false "sameMode" ((PCon "CallDynamic") (PCon "CallDynamic")) (EVar "True"))
(DFunDef false "sameMode" (PWild PWild) (EVar "False"))
(DTypeSig false "noteCallBad" (TyFun (TyCon "Ctx") (TyFun (TyCon "String") (TyFun (TyCon "Walk") (TyCon "Walk")))))
(DFunDef false "noteCallBad" ((PCon "Ctx" PWild PWild PWild PWild PWild PWild (PVar "binding")) (PVar "why") (PCon "Walk" (PVar "seen") (PVar "found") (PVar "bad") (PVar "scalar") (PVar "calls") (PVar "ctxs") (PVar "evs") (PVar "results"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Walk") (EVar "seen")) (EVar "found")) (EVar "bad")) (EVar "scalar")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "call: ")) (EApp (EMethodRef "display") (EVar "why"))) (ELit (LString " [in "))) (EApp (EMethodRef "display") (EVar "binding"))) (ELit (LString "]"))) (EVar "calls"))) (EVar "ctxs")) (EVar "evs")) (EVar "results")))
(DTypeSig false "headText" (TyFun (TyCon "CExpr") (TyCon "String")))
(DFunDef false "headText" ((PCon "CVar" (PVar "x") PWild)) (EVar "x"))
(DFunDef false "headText" ((PCon "CMethod" (PVar "name") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "method ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString ""))))
(DFunDef false "headText" ((PCon "CDict" (PVar "name") PWild)) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " (constrained)"))))
(DFunDef false "headText" ((PCon "CLam" PWild PWild)) (ELit (LString "a lambda")))
(DFunDef false "headText" (PWild) (ELit (LString "an expression")))
(DTypeSig false "noteVar" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyCon "String") (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "noteVar" ((PCon "Ctx" (PVar "backend") (PVar "top") PWild PWild PWild (PVar "facts") (PVar "binding")) (PVar "scope") (PVar "x") (PAs "w" (PCon "Walk" (PVar "seen") (PVar "found") (PVar "bad") (PVar "scalar") (PVar "calls") (PVar "ctxs") (PVar "evs") (PVar "results")))) (EIf (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "scope")) (EApp (EApp (EVar "omHasKey") (EVar "x")) (EVar "seen"))) (EVar "w") (EMatch (EApp (EApp (EVar "unprovidedOn") (EVar "backend")) (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EApp (EVar "externRuntimeKey") (EFieldAccess (EVar "facts") "efExterns")) (EVar "x")))) (arm (PCon "None") () (EVar "w")) (arm (PCon "Some" (PTuple (PVar "kind") (PVar "why"))) () (EIf (EApp (EApp (EVar "isProgramName") (EVar "top")) (EVar "x")) (EVar "w") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Walk") (EApp (EApp (EApp (EVar "omInsert") (EVar "x")) (ELit LUnit)) (EVar "seen"))) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "ExternFinding") (EApp (EApp (EVar "optionOr") (EVar "x")) (EApp (EApp (EVar "externRuntimeKey") (EFieldAccess (EVar "facts") "efExterns")) (EVar "x")))) (EVar "backend")) (EVar "kind")) (EVar "why")) (EVar "binding")) (EVar "found"))) (EVar "bad")) (EVar "scalar")) (EVar "calls")) (EVar "ctxs")) (EVar "evs")) (EVar "results")))))))
(DTypeSig false "walkList" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkList" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkList" ((PVar "ctx") (PVar "scope") (PCons (PVar "e") (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkList") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig false "walkFields" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkFields" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkFields" ((PVar "ctx") (PVar "scope") (PCons (PCon "CField" PWild PWild (PVar "e")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkFields") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig false "walkLocalBinds" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkLocalBinds" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkLocalBinds" ((PVar "ctx") (PVar "scope") (PCons (PCon "CBind" PWild (PVar "clauses") PWild PWild) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkLocalBinds") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkClauses") (EVar "ctx")) (EVar "scope")) (EVar "clauses")) (EVar "w"))))
(DTypeSig false "walkArms" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkArms" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkArms" ((PVar "ctx") (PVar "scope") (PCons (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "ctx")) (EApp (EApp (EVar "bindPatScope") (EVar "pat")) (EVar "scope"))) (EVar "guards")) (EVar "body")) (EVar "w"))))
(DTypeSig false "walkGuarded" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyFun (TyCon "CExpr") (TyFun (TyCon "Walk") (TyCon "Walk")))))))
(DFunDef false "walkGuarded" ((PVar "ctx") (PVar "scope") (PList) (PVar "body") (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "body")) (EVar "w")))
(DFunDef false "walkGuarded" ((PVar "ctx") (PVar "scope") (PCons (PCon "CGBool" (PVar "c")) (PVar "rest")) (PVar "body") (PVar "w")) (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "c")) (EVar "w"))))
(DFunDef false "walkGuarded" ((PVar "ctx") (PVar "scope") (PCons (PCon "CGBind" (PVar "pat") (PVar "e")) (PVar "rest")) (PVar "body") (PVar "w")) (EApp (EApp (EApp (EApp (EApp (EVar "walkGuarded") (EVar "ctx")) (EApp (EApp (EVar "bindPatScope") (EVar "pat")) (EVar "scope"))) (EVar "rest")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig false "walkStmts" (TyFun (TyCon "Ctx") (TyFun (TyCon "CallScope") (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyFun (TyCon "Walk") (TyCon "Walk"))))))
(DFunDef false "walkStmts" (PWild PWild (PList) (PVar "w")) (EVar "w"))
(DFunDef false "walkStmts" ((PVar "ctx") (PVar "scope") (PCons (PCon "CSExpr" (PVar "e")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DFunDef false "walkStmts" ((PVar "ctx") (PVar "scope") (PCons (PCon "CSLet" (PVar "recF") (PVar "pat") (PVar "e")) (PVar "rest")) (PVar "w")) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EApp (EVar "bindLetScope") (EVar "pat")) (EVar "e")) (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "inner")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EIf (EVar "recF") (EVar "inner") (EVar "scope"))) (EVar "e")) (EVar "w"))))))
(DFunDef false "walkStmts" ((PVar "ctx") (PVar "scope") (PCons (PCon "CSAssign" PWild (PVar "e")) (PVar "rest")) (PVar "w")) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "ctx")) (EVar "scope")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "walkE") (EVar "ctx")) (EVar "scope")) (EVar "e")) (EVar "w"))))
(DTypeSig true "validateTails" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateTails" ((PCon "CProgram" (PVar "groups") PWild PWild (PVar "impls") PWild PWild)) (EApp (EVar "reverseL") (EApp (EApp (EVar "tailImpls") (EVar "impls")) (EApp (EApp (EVar "tailBinds") (EVar "groups")) (EListLit)))))
(DTypeSig true "renderTailRefusal" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "renderTailRefusal" ((PVar "bad")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "bad")))
(DTypeSig false "tailBinds" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tailBinds" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailBinds" ((PCons (PCon "CBind" (PVar "name") (PVar "clauses") PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "tailBinds") (EVar "rest")) (EApp (EApp (EApp (EVar "tailClauses") (EVar "name")) (EVar "clauses")) (EVar "acc"))))
(DTypeSig false "tailClauses" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailClauses" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailClauses" ((PVar "b") (PCons (PCon "CClause" (PVar "pats") (PVar "body")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailClauses") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EApp (EVar "isNonEmptyL") (EVar "pats"))) (EVar "body")) (EVar "acc"))))
(DTypeSig false "tailImpls" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tailImpls" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailImpls" ((PCons (PCon "CImplEntry" (PVar "method") PWild PWild (PVar "body")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "tailImpls") (EVar "rest")) (EApp (EApp (EApp (EVar "tailImplBody") (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString "")))) (EVar "body")) (EVar "acc"))))
(DTypeSig false "tailImplBody" (TyFun (TyCon "String") (TyFun (TyCon "CImplBody") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailImplBody" ((PVar "b") (PCon "CImplTagged" (PVar "tag") PWild PWild PWild PWild (PVar "pats") (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString "")))) (EApp (EVar "isNonEmptyL") (EVar "pats"))) (EVar "body")) (EVar "acc")))
(DFunDef false "tailImplBody" ((PVar "b") (PCon "CImplDefault" PWild (PVar "tag") PWild PWild PWild (PVar "pats") (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EVar "tag"))) (ELit (LString "")))) (EApp (EVar "isNonEmptyL") (EVar "pats"))) (EVar "body")) (EVar "acc")))
(DTypeSig false "tailE" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CApp" (PVar "f") (PVar "args") (PCon "CallSite" (PVar "mode") (PVar "flag"))) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EVar "args")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "f")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailCallNote") (EVar "b")) (EVar "tl")) (EVar "f")) (EVar "mode")) (EVar "flag")) (EVar "acc")))))
(DFunDef false "tailE" (PWild PWild (PCon "CVar" PWild PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailE" (PWild PWild (PCon "CLit" PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CLam" PWild (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "True")) (EVar "body")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CLet" PWild PWild (PVar "rhs") (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "body")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "rhs")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CLetGroup" (PVar "binds") (PVar "body")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "body")) (EApp (EApp (EApp (EVar "tailLocalBinds") (EVar "b")) (EVar "binds")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CMatch" (PVar "scrut") (PVar "arms")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailArms") (EVar "b")) (EVar "tl")) (EVar "arms")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "scrut")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailArms") (EVar "b")) (EVar "tl")) (EVar "arms")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "scrut")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "f")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "t")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "c")) (EVar "acc")))))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "l") (EVar "r"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CUnOp" PWild (PVar "x")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "x")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CTuple" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EVar "es")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CList" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EVar "es")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CRecord" PWild (PVar "fields")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailFields") (EVar "b")) (EVar "fields")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CFieldAccess" (PVar "x") PWild PWild PWild) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "x")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CRecordUpdate" PWild (PVar "base") (PVar "fields")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailFields") (EVar "b")) (EVar "fields")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "base")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CVariantUpdate" PWild (PVar "base") (PVar "fields")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailFields") (EVar "b")) (EVar "fields")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "base")) (EVar "acc"))))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CArray" (PVar "es")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EVar "es")) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "lo") (EVar "hi"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "lo") (EVar "hi"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CIndex" (PVar "a") (PVar "i")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "i"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CStringIndex" (PVar "a") (PVar "i")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "i"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CStringSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CListIndex" (PVar "a") (PVar "i")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "i"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") PWild (PCon "CListSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))) (EVar "acc")))
(DFunDef false "tailE" ((PVar "b") (PVar "tl") (PCon "CBlock" (PVar "stmts")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailStmts") (EVar "b")) (EVar "tl")) (EVar "stmts")) (EVar "acc")))
(DFunDef false "tailE" (PWild PWild (PCon "CMethod" PWild PWild) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailE" (PWild PWild (PCon "CDict" PWild PWild) (PVar "acc")) (EVar "acc"))
(DTypeSig false "tailCallNote" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "CExpr") (TyFun (TyCon "CallMode") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))))
(DFunDef false "tailCallNote" ((PVar "b") (PVar "tl") (PVar "hd") (PVar "mode") (PVar "flag") (PVar "acc")) (EIf (EBinOp "&&" (EVar "flag") (EApp (EVar "not") (EVar "tl"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "tail: ")) (EApp (EMethodRef "display") (EApp (EVar "headText") (EVar "hd")))) (ELit (LString " is flagged as a tail call outside tail position [in "))) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString "]"))) (EVar "acc")) (EIf (EBinOp "&&" (EVar "flag") (EApp (EVar "isPartialCall") (EVar "mode"))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "tail: ")) (EApp (EMethodRef "display") (EApp (EVar "headText") (EVar "hd")))) (ELit (LString " is flagged as a tail call but is a partial application "))) (EApp (EMethodRef "display") (EApp (EVar "callModeSexp") (EVar "mode")))) (ELit (LString " [in "))) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString "]"))) (EVar "acc")) (EIf (EBinOp "&&" (EBinOp "&&" (EVar "tl") (EApp (EVar "not") (EVar "flag"))) (EApp (EVar "not") (EApp (EVar "isPartialCall") (EVar "mode")))) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "tail: ")) (EApp (EMethodRef "display") (EApp (EVar "headText") (EVar "hd")))) (ELit (LString " is in tail position, stamped "))) (EApp (EMethodRef "display") (EApp (EVar "callModeSexp") (EVar "mode")))) (ELit (LString ", but not flagged [in "))) (EApp (EMethodRef "display") (EVar "b"))) (ELit (LString "]"))) (EVar "acc")) (EVar "acc")))))
(DTypeSig false "isPartialCall" (TyFun (TyCon "CallMode") (TyCon "Bool")))
(DFunDef false "isPartialCall" ((PCon "CallPartial" PWild)) (EVar "True"))
(DFunDef false "isPartialCall" (PWild) (EVar "False"))
(DTypeSig false "tailList" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailList" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailList" ((PVar "b") (PCons (PVar "e") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailList") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "tailFields" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailFields" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailFields" ((PVar "b") (PCons (PCon "CField" PWild PWild (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailFields") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "tailLocalBinds" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailLocalBinds" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailLocalBinds" ((PVar "b") (PCons (PCon "CBind" PWild (PVar "clauses") PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailLocalBinds") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EVar "tailClauses") (EVar "b")) (EVar "clauses")) (EVar "acc"))))
(DTypeSig false "tailArms" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "tailArms" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailArms" ((PVar "b") (PVar "tl") (PCons (PCon "CArm" PWild (PVar "guards") (PVar "body")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailArms") (EVar "b")) (EVar "tl")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "body")) (EApp (EApp (EApp (EVar "tailGuards") (EVar "b")) (EVar "guards")) (EVar "acc")))))
(DTypeSig false "tailGuards" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailGuards" (PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailGuards" ((PVar "b") (PCons (PCon "CGBool" (PVar "c")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailGuards") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "c")) (EVar "acc"))))
(DFunDef false "tailGuards" ((PVar "b") (PCons (PCon "CGBind" PWild (PVar "e")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EVar "tailGuards") (EVar "b")) (EVar "rest")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc"))))
(DTypeSig false "tailStmts" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "tailStmts" (PWild PWild (PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "tailStmts" ((PVar "b") (PVar "tl") (PList (PCon "CSExpr" (PVar "e"))) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "tl")) (EVar "e")) (EVar "acc")))
(DFunDef false "tailStmts" ((PVar "b") (PVar "tl") (PCons (PVar "st") (PVar "rest")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailStmts") (EVar "b")) (EVar "tl")) (EVar "rest")) (EApp (EApp (EApp (EVar "tailStmt") (EVar "b")) (EVar "st")) (EVar "acc"))))
(DTypeSig false "tailStmt" (TyFun (TyCon "String") (TyFun (TyCon "CStmt") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "tailStmt" ((PVar "b") (PCon "CSExpr" (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc")))
(DFunDef false "tailStmt" ((PVar "b") (PCon "CSLet" PWild PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc")))
(DFunDef false "tailStmt" ((PVar "b") (PCon "CSAssign" PWild (PVar "e")) (PVar "acc")) (EApp (EApp (EApp (EApp (EVar "tailE") (EVar "b")) (EVar "False")) (EVar "e")) (EVar "acc")))
(DTypeSig true "validateBinderStamps" (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "validateBinderStamps" ((PCon "CProgram" (PVar "groups") (PVar "ctorArs") (PVar "ctorTypes") (PVar "impls") PWild (PVar "facts"))) (EBlock (DoLet false false (PVar "rows") (EApp (EVar "BM.fromList") (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "binderOrdinal") (EFieldAccess (EVar "r") "brId")) (EVar "r")))) (EFieldAccess (EVar "facts") "factBinders")))) (DoLet false false (PVar "ctors") (EApp (EApp (EVar "omFromPairs") (EVar "ctorTypes")) (EVar "omEmpty"))) (DoLet false false (PVar "arities") (EApp (EApp (EVar "omFromPairs") (EVar "ctorArs")) (EVar "omEmpty"))) (DoExpr (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "bindStampFaults") (EVar "rows")) (EVar "ctors")) (EVar "arities"))) (EVar "groups")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "entryStampFaults") (EVar "rows")) (EVar "ctors")) (EVar "arities"))) (EVar "impls"))))))
(DTypeSig false "bindStampFaults" (TyFun (TyApp (TyApp (TyCon "BM.Map") (TyCon "Int")) (TyCon "BinderRow")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CBind") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "bindStampFaults" ((PVar "rows") (PVar "ctors") (PVar "arities") (PAs "b" (PCon "CBind" (PVar "name") PWild PWild PWild))) (EApp (EApp (EApp (EApp (EApp (EVar "stampFaultsIn") (EVar "rows")) (EVar "ctors")) (EVar "arities")) (EVar "name")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CProgram") (EListLit (EVar "b"))) (EListLit)) (EListLit)) (EListLit)) (EListLit)) (EVar "noDeclFacts"))))
(DTypeSig false "entryStampFaults" (TyFun (TyApp (TyApp (TyCon "BM.Map") (TyCon "Int")) (TyCon "BinderRow")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CImplEntry") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "entryStampFaults" ((PVar "rows") (PVar "ctors") (PVar "arities") (PAs "e" (PCon "CImplEntry" (PVar "method") PWild PWild (PVar "body")))) (EApp (EApp (EApp (EApp (EApp (EVar "stampFaultsIn") (EVar "rows")) (EVar "ctors")) (EVar "arities")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "impl ")) (EApp (EMethodRef "display") (EVar "method"))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EApp (EVar "implBodyTag") (EVar "body")))) (ELit (LString "")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CProgram") (EListLit)) (EListLit)) (EListLit)) (EListLit (EVar "e"))) (EListLit)) (EVar "noDeclFacts"))))
(DTypeSig false "stampFaultsIn" (TyFun (TyApp (TyApp (TyCon "BM.Map") (TyCon "Int")) (TyCon "BinderRow")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))))))
(DFunDef false "stampFaultsIn" ((PVar "rows") (PVar "ctors") (PVar "arities") (PVar "where_") (PVar "prog")) (EBlock (DoLet false false (PVar "found") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "mapProgramBinders") (ELam ((PVar "site") (PVar "x") (PVar "bid")) (EBlock (DoLet false false PWild (EMatch (EVar "site") (arm (PCon "PatternBinder" (PVar "rhs")) () (EMatch (EApp (EApp (EApp (EApp (EApp (EApp (EVar "stampFault") (EVar "rows")) (EVar "ctors")) (EVar "arities")) (EVar "rhs")) (EVar "x")) (EVar "bid")) (arm (PCon "Some" (PVar "msg")) () (EApp (EApp (EVar "setRef") (EVar "found")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "binder: ")) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString " [in "))) (EApp (EMethodRef "display") (EVar "where_"))) (ELit (LString "]"))) (EUnOp "!" (EVar "found"))))) (arm (PCon "None") () (ELit LUnit)))) (arm (PCon "FunctionBinder" PWild) () (EMatch (EApp (EApp (EApp (EVar "returnFault") (EVar "rows")) (EVar "x")) (EVar "bid")) (arm (PCon "Some" (PVar "msg")) () (EApp (EApp (EVar "setRef") (EVar "found")) (EBinOp "::" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "function: ")) (EApp (EMethodRef "display") (EVar "msg"))) (ELit (LString " [in "))) (EApp (EMethodRef "display") (EVar "where_"))) (ELit (LString "]"))) (EUnOp "!" (EVar "found"))))) (arm (PCon "None") () (ELit LUnit)))))) (DoExpr (EVar "bid"))))) (EVar "prog"))) (DoExpr (EApp (EVar "reverseL") (EUnOp "!" (EVar "found"))))))
(DTypeSig false "returnFault" (TyFun (TyApp (TyApp (TyCon "BM.Map") (TyCon "Int")) (TyCon "BinderRow")) (TyFun (TyCon "String") (TyFun (TyCon "BinderId") (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "returnFault" ((PVar "rows") (PVar "x") (PCon "BinderId" PWild (PVar "n"))) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString " has no id, so no return type")))) (EMatch (EApp (EApp (EVar "BM.get") (EVar "n")) (EVar "rows")) (arm (PCon "None") () (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString " has no stamped type"))))) (arm (PCon "Some" (PVar "row")) () (EMatch (EFieldAccess (EVar "row") "brReturns") (arm (PCon "None") () (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString " has no return type"))))) (arm (PCon "Some" PWild) () (EVar "None")))))))
(DTypeSig false "stampFault" (TyFun (TyApp (TyApp (TyCon "BM.Map") (TyCon "Int")) (TyCon "BinderRow")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "Option") (TyCon "CExpr")) (TyFun (TyCon "String") (TyFun (TyCon "BinderId") (TyApp (TyCon "Option") (TyCon "String")))))))))
(DFunDef false "stampFault" ((PVar "rows") (PVar "ctors") (PVar "arities") (PVar "rhs") (PVar "x") (PCon "BinderId" PWild (PVar "n"))) (EIf (EBinOp "<" (EVar "n") (ELit (LInt 0))) (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString " has no id, so no stamped type")))) (EMatch (EApp (EApp (EVar "BM.get") (EVar "n")) (EVar "rows")) (arm (PCon "None") () (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString " has no stamped type"))))) (arm (PCon "Some" (PVar "row")) () (EMatch (EVar "rhs") (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "e")) () (EMatch (EApp (EApp (EApp (EVar "boundShape") (EVar "ctors")) (EVar "arities")) (EVar "e")) (arm (PCon "None") () (EVar "None")) (arm (PCon "Some" (PVar "shape")) () (EIf (EApp (EApp (EVar "stampAllows") (EVar "shape")) (EFieldAccess (EVar "row") "brType")) (EVar "None") (EApp (EVar "Some") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString " is stamped "))) (EApp (EMethodRef "display") (EApp (EVar "runtimeTypeName") (EFieldAccess (EVar "row") "brType")))) (ELit (LString " but is bound to "))) (EApp (EMethodRef "display") (EApp (EVar "shapeName") (EVar "shape")))) (ELit (LString "")))))))))))))
(DData Private "BoundShape" () ((variant "BoundLit" (ConPos (TyCon "RuntimeType"))) (variant "BoundInt" (ConPos)) (variant "BoundCell" (ConPos))) ())
(DTypeSig false "boundShape" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CExpr") (TyApp (TyCon "Option") (TyCon "BoundShape"))))))
(DFunDef false "boundShape" (PWild PWild (PCon "CLit" (PCon "LInt" PWild))) (EApp (EVar "Some") (EVar "BoundInt")))
(DFunDef false "boundShape" (PWild PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "Some") (EApp (EVar "BoundLit") (EApp (EVar "litRuntimeType") (EVar "l")))))
(DFunDef false "boundShape" (PWild PWild (PCon "CTuple" PWild)) (EApp (EVar "Some") (EVar "BoundCell")))
(DFunDef false "boundShape" (PWild PWild (PCon "CList" PWild)) (EApp (EVar "Some") (EVar "BoundCell")))
(DFunDef false "boundShape" ((PVar "ctors") (PVar "arities") (PCon "CVar" (PVar "c") PWild)) (EApp (EApp (EApp (EApp (EVar "ctorShape") (EVar "ctors")) (EVar "arities")) (EVar "c")) (ELit (LInt 0))))
(DFunDef false "boundShape" ((PVar "ctors") (PVar "arities") (PCon "CApp" (PCon "CVar" (PVar "c") PWild) (PVar "args") PWild)) (EApp (EApp (EApp (EApp (EVar "ctorShape") (EVar "ctors")) (EVar "arities")) (EVar "c")) (EApp (EVar "listLen") (EVar "args"))))
(DFunDef false "boundShape" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "ctorShape" (TyFun (TyApp (TyCon "OrdMap") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "BoundShape")))))))
(DFunDef false "ctorShape" ((PVar "ctors") (PVar "arities") (PVar "c") (PVar "n")) (EMatch (ETuple (EApp (EApp (EVar "omLookup") (EVar "c")) (EVar "arities")) (EApp (EApp (EVar "omLookup") (EVar "c")) (EVar "ctors"))) (arm (PTuple (PCon "Some" (PVar "k")) (PCon "Some" (PVar "ty"))) () (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "k") (EVar "n")) (EBinOp "/=" (EVar "ty") (ELit (LString "Bool")))) (EBinOp "/=" (EVar "ty") (ELit (LString "Unit")))) (EApp (EVar "Some") (EVar "BoundCell")) (EVar "None"))) (arm PWild () (EVar "None"))))
(DTypeSig false "stampAllows" (TyFun (TyCon "BoundShape") (TyFun (TyCon "RuntimeType") (TyCon "Bool"))))
(DFunDef false "stampAllows" (PWild (PCon "RTValue")) (EVar "True"))
(DFunDef false "stampAllows" ((PCon "BoundLit" (PVar "t")) (PVar "stamped")) (EBinOp "==" (EVar "t") (EVar "stamped")))
(DFunDef false "stampAllows" ((PCon "BoundInt") (PVar "stamped")) (EApp (EVar "isNumericRuntimeType") (EVar "stamped")))
(DFunDef false "stampAllows" ((PCon "BoundCell") (PVar "stamped")) (EBinOp "==" (EVar "stamped") (EVar "RTCon")))
(DTypeSig false "isNumericRuntimeType" (TyFun (TyCon "RuntimeType") (TyCon "Bool")))
(DFunDef false "isNumericRuntimeType" ((PCon "RTInt")) (EVar "True"))
(DFunDef false "isNumericRuntimeType" ((PCon "RTFloat")) (EVar "True"))
(DFunDef false "isNumericRuntimeType" ((PCon "RTU64")) (EVar "True"))
(DFunDef false "isNumericRuntimeType" ((PCon "RTI64")) (EVar "True"))
(DFunDef false "isNumericRuntimeType" ((PCon "RTU32")) (EVar "True"))
(DFunDef false "isNumericRuntimeType" ((PCon "RTI32")) (EVar "True"))
(DFunDef false "isNumericRuntimeType" ((PCon "RTU16")) (EVar "True"))
(DFunDef false "isNumericRuntimeType" ((PCon "RTU8")) (EVar "True"))
(DFunDef false "isNumericRuntimeType" (PWild) (EVar "False"))
(DTypeSig false "shapeName" (TyFun (TyCon "BoundShape") (TyCon "String")))
(DFunDef false "shapeName" ((PCon "BoundLit" (PVar "t"))) (EBinOp "++" (EBinOp "++" (ELit (LString "a ")) (EApp (EMethodRef "display") (EApp (EVar "runtimeTypeName") (EVar "t")))) (ELit (LString " literal"))))
(DFunDef false "shapeName" ((PCon "BoundInt")) (ELit (LString "an integer literal")))
(DFunDef false "shapeName" ((PCon "BoundCell")) (ELit (LString "a constructor cell")))
(DTypeSig true "renderBinderRefusal" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))
(DFunDef false "renderBinderRefusal" ((PVar "bad")) (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EVar "bad")))
(DTypeSig false "validatePhysicalDemand" (TyFun (TyCon "Backend") (TyFun (TyCon "EmitPlan") (TyFun (TyCon "CProgram") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "validatePhysicalDemand" ((PCon "WasmBackend") (PVar "plan") (PVar "cp")) (EMatch (EFieldAccess (EVar "plan") "wasmPhysical") (arm (PCon "None") () (EListLit (ELit (LString "missing-wasm-demand-plan")))) (arm (PCon "Some" (PVar "physical")) () (EBinOp "++" (EApp (EApp (EApp (EApp (EVar "validateWasmDemand") (ERecordUpdate (EFieldAccess (EVar "plan") "wasmInputs") ((fa "lazyGlobals" (EFieldAccess (EVar "plan") "lazyGlobals")) (fa "globalInit" (EFieldAccess (EVar "plan") "globalInit")) (fa "trmcVerdicts" (EFieldAccess (EVar "plan") "trmc")) (fa "dispatchGroups" (EFieldAccess (EVar "plan") "dispGroups"))))) (EVar "cp")) (EFieldAccess (EVar "plan") "externRequirements")) (EVar "physical")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "/=" (EFieldAccess (EVar "physical") "sourceDemand") (EFieldAccess (EVar "plan") "wasmDemand")) (EBinOp "/=" (EFieldAccess (EVar "physical") "sourceHostKeys") (EFieldAccess (EVar "plan") "hostKeys"))) (EBinOp "/=" (EFieldAccess (EVar "physical") "jsImports") (EFieldAccess (EVar "plan") "jsImports"))) (EListLit (ELit (LString "wasm-source-demand-mismatch"))) (EListLit))))))
(DFunDef false "validatePhysicalDemand" (PWild PWild PWild) (EListLit))
