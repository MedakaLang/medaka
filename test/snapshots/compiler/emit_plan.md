# META
source_lines=568
stages=DESUGAR,MARK
# SOURCE
import backend.package_identity.{
  PackageIdentity, IdentityPlan, IdentityDefect, emptyPackage,
  planProgramIdentity
}
import backend.impl_groups.{ImplClauseGroup, groupImplEntries}
import ir.constructor_facts.{ConstructorFacts, planConstructors}
import support.symbol_encoding.{encodePair}
import backend.wasm_demand.{
  JsImport(..), WasmDemand(..), WasmDemandInputs(..), WasmDemandPlan,
  planWasmDemand
}
import backend.wasm_names.{uniqueBinders}
-- The per-emission plan: facts about the lowered program that both backends read
-- and neither recomputes.  Built once, right after lowering, from the program an
-- emitter is about to receive.

import backend.extern_requirements.{ExternRequirements, planExterns}
import backend.global_plan.{GlobalInitPlan, planGlobals}
import backend.emit_target.{Backend(..)}
import frontend.ast.{Lit(..), Pat(..)}
import ir.extern_types.{ExternDeclFact}
import ir.core_ir.{
  CProgram(..),
  EntryFact(..),
  MethodResultFact(..),
  CArm(..),
  CBind(..),
  CClause(..),
  CExpr(..),
  CField(..),
  CGuard(..),
  CHead(..),
  CImplEntry(..),
  CImplBody(..),
  CStmt(..),
  CTBranch(..),
  CTree(..),
  ifaceMethodArityKey,
}
import backend.extern_catalog.{
  RuntimeExternDomain,
  WasmUse(..),
}

import support.ordmap.{
  OrdMap,
  omEmpty,
  omInsert,
  omLookup,
  omHasKey,
  omFromNames,
  omFromPairs,
  omMapValues,
}
import support.util.{lenKey, reverseL, filterList, listLen}
import backend.wasm_reach.{wasmReachFilter}
import backend.emit_support.{eagerReachMap, lazyGlobalNames}
import backend.trmc_analysis.{
  TrmcVerdicts(..),
  SelfRef(..),
  DispGroup,
  trmcEligible,
  detectDispatchGroups,
  dictUniformClauses,
  methodSelf,
  clauseArityOf,
  bindName,
}

-- `wasmOnlyReach` is `Some` only on a plan from `buildEmitPlanReached`: the unit
-- counts (top-level binds plus impl entries) before and after the dispatch-rooted
-- reach filter, whose result the plan's other fields were computed over.  Reach is
-- wasm-only because native whole mode emits every function but `@mdk_program_main`
-- as `define internal`, so clang's GlobalDCE already drops the same functions and
-- the pass would buy no measurable CPU time.  The prelude-object halves must be
-- identity: the prelude half has to define every prelude symbol a program half may
-- link against, which no reach from a single program can know.
--
-- `target` is the backend the plan was built for; the emitter asserts it is its own.
-- `lazyGlobals` are the value globals emitted as forced-on-first-use cells.
-- `eagerReach` maps each binding to the value globals it eagerly reaches.
-- `globalInit` gives the complete value order and its eager subsequence; the
-- gateway checks both against Core before either target consumes them.
-- `trmc` says which functions are tail-recursive modulo constructor (TRMC-DESIGN.md).
-- `dispGroups` are the dispatch-graph TMC groups (WASMGC-TRMC-DESIGN.md §11): a
-- group's members are emitted as one destination-passing loop rooted at its root.
-- `wasmDemand` is what the program demands of a WasmGC module, and `hostKeys` the
-- `env` host imports its externs' wasm lowerings call (`wasmHostKeys`), sorted
-- and distinct; the wasm emitter declares exactly these imports.  `jsImports` are
-- the user externs with a `js` binding that the program reaches, one each, in
-- Medaka-name order; the wasm emitter imports exactly these from the jsffi module.  All
-- three are empty on an LLVM plan.
import types.capability_manifest.{ManifestRequest, CapabilityManifest}

public export data EmitPlan = EmitPlan {
  manifestIndex : List ManifestRequest,
  target : Backend,
  externRequirements : ExternRequirements,
  entryOutcome : Option EntryFact,
  methodResults : OrdMap (OrdMap MethodResultFact),
  constructorFacts : ConstructorFacts,
  identity : Result (List IdentityDefect) IdentityPlan,
  wasmOnlyReach : Option ReachUnits,
  lazyGlobals : List String,
  eagerReach : OrdMap (List String),
  globalInit : GlobalInitPlan,
  implGroups : List ImplClauseGroup,
  trmc : TrmcVerdicts,
  dispGroups : List DispGroup,
  wasmDemand : WasmDemand,
  wasmInputs : WasmDemandInputs,
  wasmPhysical : Option WasmDemandPlan,
  hostKeys : List String,
  jsImports : List JsImport,
  methodTables : MethodTables,
}

public export data ReachUnits = ReachUnits { total : Int, kept : Int }

-- A dictionary is a method table: `[hdr | super_0 .. | slot_0 .. | req_0 ..]`.
-- `slots` gives each interface's slots in declaration order; slot i of a
-- dictionary of that interface is the word after its supers, at field
-- `supers + i`.  `instances` gives, per instance key, the impl groups that fill
-- each slot of its interface, in slot order.  A valid program has exactly one
-- group per slot (`core_validate.validateMethodTables`).
public export data MethodTables = MethodTables {
  slots : OrdMap (List MethodSlot),
  instances : OrdMap InstanceTable,
}

-- One slot: the method, the dictionaries its own `=>` context takes, and its
-- declared value arity.  A slot holds a closure of `1 + contextDicts +
-- valueArity` arguments, called as `code(clos, dict, mw.., args..)`.
public export data MethodSlot = MethodSlot {
  method : String,
  contextDicts : Int,
  valueArity : Int,
} deriving (Eq, Debug)

-- An instance's table: its interface word and, per slot of that interface, the
-- groups that fill it.
public export data InstanceTable = InstanceTable {
  iface : String,
  fills : List (List SlotCallee),
}

-- A group that fills a slot: its position in `EmitPlan.implGroups`, whether it
-- is an inherited default's per-instance body, and the value arity its entries
-- declare.
public export data SlotCallee = SlotCallee {
  group : Int,
  inherited : Bool,
  declaredArity : Int,
} deriving (Eq, Debug)

-- the slots of interface [iface], in declaration order
export
interfaceSlots : MethodTables -> String -> List MethodSlot
interfaceSlots tables iface = optionOr [] (omLookup iface tables.slots)

-- Slot order is the order of the declaration facts; the first declaration of a
-- method wins, as in `indexMethodResults`.
planMethodTables : CProgram -> List ImplClauseGroup -> MethodTables
planMethodTables (CProgram _ _ _ impls mctx facts) groups =
  let contexts = omFromPairs mctx omEmpty
  let slots = fold (addSlot contexts) omEmpty facts.factMethodResults
  let entries = indexImplEntries impls 0 omEmpty
  let byKey = fillsByKey entries groups 0 omEmpty
  MethodTables {
    slots = slots,
    instances = omMapValues (instanceTable slots) byKey,
  }

instanceTable : OrdMap (List MethodSlot) ->
  (String, OrdMap (List SlotCallee)) ->
  InstanceTable
instanceTable slots (iface, byMethod) = InstanceTable {
  iface = iface,
  fills =
    map
      (s => optionOr [] (omLookup (s : MethodSlot).method byMethod))
      (optionOr [] (omLookup iface slots)),
}

addSlot : OrdMap Int ->
  OrdMap (List MethodSlot) ->
  MethodResultFact ->
  OrdMap (List MethodSlot)
addSlot contexts acc row =
  let have = optionOr [] (omLookup row.iface acc)
  if any (s => (s : MethodSlot).method == row.method) have then
    acc
  else
    omInsert
      row.iface
      (have
        ++ [
          MethodSlot {
            method = row.method,
            contextDicts =
              optionOr
                0
                (omLookup (ifaceMethodArityKey row.iface row.method) contexts),
            valueArity = row.valueArity,
          },
        ])
      acc

-- per instance key: its interface word and the callees of each method
fillsByKey : OrdMap CImplEntry ->
  List ImplClauseGroup ->
  Int ->
  OrdMap (String, OrdMap (List SlotCallee)) ->
  OrdMap (String, OrdMap (List SlotCallee))
fillsByKey _ [] _ acc = acc
fillsByKey entries (g :: rest) i acc = match firstEntryOf entries g
  Some (CImplEntry method _ declared body) =>
    let (iface, inherited) = match body
      CImplTagged _ _ word _ _ _ _ => (word, False)
      CImplDefault word _ _ _ _ _ _ => (word, True)
    let key = (g : ImplClauseGroup).key
    let byMethod = match omLookup key acc
      Some (_, m) => m
      None => omEmpty
    let callee = SlotCallee {
      group = i,
      inherited = inherited,
      declaredArity = declared,
    }
    fillsByKey
      entries
      rest
      (i + 1)
      (omInsert
        key
        (
          iface,
          omInsert
            method
            (optionOr [] (omLookup method byMethod) ++ [callee])
            byMethod,
        )
        acc)
  None => fillsByKey entries rest (i + 1) acc

firstEntryOf : OrdMap CImplEntry -> ImplClauseGroup -> Option CImplEntry
firstEntryOf entries g = match (g : ImplClauseGroup).indices
  i :: _ => omLookup (intToString i) entries
  [] => None

export
buildEmitPlan : Backend -> RuntimeExternDomain -> CProgram -> EmitPlan
buildEmitPlan target domain prog =
  buildEmitPlanWithIdentity target domain emptyPackage prog

export
buildEmitPlanWithIdentity : Backend ->
  RuntimeExternDomain ->
  PackageIdentity ->
  CProgram ->
  EmitPlan
buildEmitPlanWithIdentity target domain package prog =
  planOver target domain None omEmpty (planProgramIdentity package prog) prog

-- The wasm modules entries' builder: reach first, then every plan field over the
-- reached program, which is also the program the emitter must receive. The
-- complete runtime domain is retained separately from the reached selection.
export
buildEmitPlanReached : RuntimeExternDomain ->
  OrdMap (List Int) ->
  CProgram ->
  (EmitPlan, CProgram)
buildEmitPlanReached domain ctorFields prog =
  buildEmitPlanReachedWithIdentity domain ctorFields emptyPackage prog

export
buildEmitPlanReachedWithIdentity : RuntimeExternDomain ->
  OrdMap (List Int) ->
  PackageIdentity ->
  CProgram ->
  (EmitPlan, CProgram)
buildEmitPlanReachedWithIdentity domain ctorFields package prog =
  let identity = planProgramIdentity package prog
  let reached = wasmReachFilter prog
  let units = ReachUnits {
    total = programUnitCount prog,
    kept = programUnitCount reached,
  }
  let prepared = uniqueBinders reached
  (
    planOver WasmBackend domain (Some units) ctorFields identity prepared,
    prepared,
  )

export
prepareWasmPlan : RuntimeExternDomain ->
  OrdMap (List Int) ->
  CProgram ->
  (EmitPlan, CProgram)
prepareWasmPlan domain ctorFields prog =
  prepareWasmPlanWithIdentity domain ctorFields emptyPackage prog

export
prepareWasmPlanWithIdentity : RuntimeExternDomain ->
  OrdMap (List Int) ->
  PackageIdentity ->
  CProgram ->
  (EmitPlan, CProgram)
prepareWasmPlanWithIdentity domain ctorFields package prog =
  let identity = planProgramIdentity package prog
  let prepared = uniqueBinders prog
  (planOver WasmBackend domain None ctorFields identity prepared, prepared)

programUnitCount : CProgram -> Int
programUnitCount (CProgram groups _ _ impls _ _) =
  listLen groups + listLen impls

planOver : Backend ->
  RuntimeExternDomain ->
  Option ReachUnits ->
  OrdMap (List Int) ->
  Result (List IdentityDefect) IdentityPlan ->
  CProgram ->
  EmitPlan
planOver target domain reach ctorFields identity prog =
  let (CProgram groups _ _ impls _ facts) = prog
  let constructors = planConstructors prog
  let ctors = constructors.arities
  let fns = filterList isTopFn groups
  let requirements = planExterns target domain prog
  let lazy = lazyGlobalNames ctors groups
  let eager = eagerReachMap groups
  let globalInit = planGlobals prog lazy eager
  let implGroups = groupImplEntries impls
  let trmc = TrmcVerdicts {
    eligibleFns =
      omFromNames
        (map bindName (filterList (b => selfTrmcBind ctors b) fns))
        omEmpty,
    eligibleImpls = trmcImplKeys ctors impls implGroups,
  }
  let dispatch = planDispatchGroups ctors fns groups impls
  let inputs = WasmDemandInputs {
    ctorFloatFields = ctorFields,
    lazyGlobals = lazy,
    globalInit = globalInit,
    trmcVerdicts = trmc,
    dispatchGroups = dispatch,
  }
  let physical = match target
    WasmBackend => Some (planWasmDemand constructors inputs prog requirements)
    _ => None
  EmitPlan {
    manifestIndex =
      map (m => (m : CapabilityManifest).request) facts.factManifests,
    target = target,
    externRequirements = requirements,
    entryOutcome = facts.factEntryOutcome,
    methodResults = indexMethodResults facts.factMethodResults,
    constructorFacts = constructors,
    identity = identity,
    wasmOnlyReach = reach,
    lazyGlobals = lazy,
    eagerReach = eager,
    globalInit = globalInit,
    implGroups = implGroups,
    trmc = trmc,
    dispGroups = dispatch,
    wasmDemand = match physical
      Some p => p.sourceDemand
      None => noDemand,
    wasmInputs = inputs,
    wasmPhysical = physical,
    hostKeys = match physical
      Some p => p.sourceHostKeys
      None => [],
    jsImports = match physical
      Some p => p.jsImports
      None => [],
    methodTables = planMethodTables prog implGroups,
  }

export
planEntryMainIsUnit : EmitPlan -> Bool
planEntryMainIsUnit plan = match plan.entryOutcome
  Some outcome => outcome.entryMainIsUnit
  None => False

export
planEntryMainIsFloat : EmitPlan -> Bool
planEntryMainIsFloat plan = match plan.entryOutcome
  Some outcome => outcome.entryMainIsFloat
  None => False

-- The two-level index preserves qualified interface identity without joining
-- names. First declaration wins, matching declaration-table lookup order.
export
indexMethodResults : List MethodResultFact -> OrdMap (OrdMap MethodResultFact)
indexMethodResults rows = fold insertMethodResult omEmpty (reverseL rows)

insertMethodResult : OrdMap (OrdMap MethodResultFact) ->
  MethodResultFact ->
  OrdMap (OrdMap MethodResultFact)
insertMethodResult acc row =
  let methods = optionOr omEmpty (omLookup row.iface acc)
  omInsert row.iface (omInsert row.method row methods) acc

export
lookupMethodResult : OrdMap (OrdMap MethodResultFact) ->
  String ->
  String ->
  Option MethodResultFact
lookupMethodResult index iface method = do
  methods <- omLookup iface index
  omLookup method methods

-- a function binding: it takes parameters, and it is not `main`
isTopFn : CBind -> Bool
isTopFn (CBind "main" _ _ _) = False
isTopFn (CBind _ ((CClause (_ :: _) _) :: _) _ _) = True
isTopFn _ = False

isCtorIn : OrdMap Int -> String -> Bool
isCtorIn ctors name = omHasKey name ctors

ctorArityIn : OrdMap Int -> String -> Int
ctorArityIn ctors name = optionOr 0 (omLookup name ctors)

clausePair : CClause -> (List Pat, CExpr)
clausePair (CClause pats body) = (pats, body)

-- the TRMC verdict on clauses that recurse through [self]
clausesTrmc : OrdMap Int -> SelfRef -> List CClause -> Bool
clausesTrmc ctors self clauses =
  let arity = clauseArityOf clauses
  arity > 0
    && dictUniformClauses clauses
    && trmcEligible
      (isCtorIn ctors)
      (ctorArityIn ctors)
      self
      arity
      (map clausePair clauses)

selfTrmcBind : OrdMap Int -> CBind -> Bool
selfTrmcBind ctors (CBind name clauses _ _) =
  clausesTrmc ctors (SelfByVar name) clauses

implGroupKey : String -> String -> String
implGroupKey method key = lenKey method ++ key

-- the eligible impl groups, keyed by `implGroupKey`
trmcImplKeys : OrdMap Int ->
  List CImplEntry ->
  List ImplClauseGroup ->
  OrdMap Unit
trmcImplKeys ctors impls groups =
  let indexed = indexImplEntries impls 0 omEmpty
  omFromNames
    (map
      (g => implGroupKey (g : ImplClauseGroup).method (g : ImplClauseGroup).key)
      (filterList
        (g =>
          let clauses =
            flatMap
              (i => match omLookup (intToString i) indexed
                Some (CImplEntry _ _ _ body) => [snd (implKeyClause body)]
                None => [])
              (g : ImplClauseGroup).indices
          clausesTrmc
            ctors
            (methodSelf
              (g : ImplClauseGroup).method
              (g : ImplClauseGroup).key
              (firstPats clauses))
            clauses)
        groups))
    omEmpty

indexImplEntries : List CImplEntry ->
  Int ->
  OrdMap CImplEntry ->
  OrdMap CImplEntry
indexImplEntries [] _ acc = acc
indexImplEntries (entry :: rest) i acc =
  indexImplEntries rest (i + 1) (omInsert (intToString i) entry acc)

implKeyClause : CImplBody -> (String, CClause)
implKeyClause (CImplTagged _ key _ _ _ pats body) = (key, CClause pats body)
implKeyClause (CImplDefault _ _ key _ _ pats body) = (key, CClause pats body)

firstPats : List CClause -> List Pat
firstPats ((CClause pats _) :: _) = pats
firstPats [] = []

-- The dispatch-graph TMC groups.  A name is a function when it names a function
-- binding; a bare prelude reference resolves to its `core__` binding; an unknown
-- name's arity is -1, so no call to it saturates.  The singleton check is the
-- self-recursive TRMC verdict, so a function that verdict claims never joins a group.
planDispatchGroups : OrdMap Int ->
  List CBind ->
  List CBind ->
  List CImplEntry ->
  List DispGroup
planDispatchGroups ctors fns groups impls =
  let arities =
    omFromPairs (reverseL (map (b => (bindName b, bindArity b)) fns)) omEmpty
  detectDispatchGroups
    (n => canonFnIn arities n)
    (n => omHasKey n arities)
    (n => match omLookup n arities
      Some a => a
      None => 0 - 1)
    (nm _ cs => clausesTrmc ctors (SelfByVar nm) cs)
    fns
    groups
    impls

bindArity : CBind -> Int
bindArity (CBind _ clauses _ _) = clauseArityOf clauses

canonFnIn : OrdMap Int -> String -> String
canonFnIn fns name =
  if omHasKey name fns then
    name
  else if omHasKey (encodePair "core" name) fns then
    encodePair "core" name
  else
    name

-- ── the wasm demand walk ────────────────────────────────────────────────────

noDemand : WasmDemand
noDemand = WasmDemand {
  uses = [],
  refBox = False,
  divGuard = False,
  tupleArities = [],
}

-- the walk's state: the demand so far, newest first, and the host keys and `js`
-- imports seen
data DemandAcc = DemandAcc {
  seenUses : List WasmUse,
  seenKeys : OrdMap Unit,
  seenJs : OrdMap JsImport,
  seenRefBox : Bool,
  seenDivGuard : Bool,
  seenArities : List Int,
}

-- What a bare name denotes where the walk meets it, resolved in the order the
-- wasm emitter resolves it (`emitAppRef`, `emitTailCallW`, `emitVarRefPlain`).
-- A binder in scope is a local, whatever else shares its name.  Otherwise a
-- value reference is a top-level binding of that name, or the `core__`
-- function a bare prelude name stands for, before it is an extern; an applied
-- name is an extern before it is a top-level function, unless only its
-- `core__` function exists.  `topFns` and `topVals` partition the top-level
-- bindings other than `main` as the emitter's own indexes do.  An extern is a
-- user extern with a `js` binding (`jsBinds`: name -> (JS name, heads)) before
-- it is a catalog extern, as in the emitter.
data DemandScope = DemandScope {
  locals : OrdMap Unit,
  topFns : OrdMap Unit,
  topVals : OrdMap Unit,
  jsBinds : OrdMap (String, (List String, String)),
  externFacts : OrdMap ExternDeclFact,
}
# DESUGAR
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("backend" "package_identity") ((mem "PackageIdentity" false) (mem "IdentityPlan" false) (mem "IdentityDefect" false) (mem "emptyPackage" false) (mem "planProgramIdentity" false))))
(DUse false (UseGroup ("backend" "impl_groups") ((mem "ImplClauseGroup" false) (mem "groupImplEntries" false))))
(DUse false (UseGroup ("ir" "constructor_facts") ((mem "ConstructorFacts" false) (mem "planConstructors" false))))
(DUse false (UseGroup ("support" "symbol_encoding") ((mem "encodePair" false))))
(DUse false (UseGroup ("backend" "wasm_demand") ((mem "JsImport" true) (mem "WasmDemand" true) (mem "WasmDemandInputs" true) (mem "WasmDemandPlan" false) (mem "planWasmDemand" false))))
(DUse false (UseGroup ("backend" "wasm_names") ((mem "uniqueBinders" false))))
(DUse false (UseGroup ("backend" "extern_requirements") ((mem "ExternRequirements" false) (mem "planExterns" false))))
(DUse false (UseGroup ("backend" "global_plan") ((mem "GlobalInitPlan" false) (mem "planGlobals" false))))
(DUse false (UseGroup ("backend" "emit_target") ((mem "Backend" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Pat" true))))
(DUse false (UseGroup ("ir" "extern_types") ((mem "ExternDeclFact" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "EntryFact" true) (mem "MethodResultFact" true) (mem "CArm" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CField" true) (mem "CGuard" true) (mem "CHead" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CStmt" true) (mem "CTBranch" true) (mem "CTree" true) (mem "ifaceMethodArityKey" false))))
(DUse false (UseGroup ("backend" "extern_catalog") ((mem "RuntimeExternDomain" false) (mem "WasmUse" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omFromNames" false) (mem "omFromPairs" false) (mem "omMapValues" false))))
(DUse false (UseGroup ("support" "util") ((mem "lenKey" false) (mem "reverseL" false) (mem "filterList" false) (mem "listLen" false))))
(DUse false (UseGroup ("backend" "wasm_reach") ((mem "wasmReachFilter" false))))
(DUse false (UseGroup ("backend" "emit_support") ((mem "eagerReachMap" false) (mem "lazyGlobalNames" false))))
(DUse false (UseGroup ("backend" "trmc_analysis") ((mem "TrmcVerdicts" true) (mem "SelfRef" true) (mem "DispGroup" false) (mem "trmcEligible" false) (mem "detectDispatchGroups" false) (mem "dictUniformClauses" false) (mem "methodSelf" false) (mem "clauseArityOf" false) (mem "bindName" false))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "ManifestRequest" false) (mem "CapabilityManifest" false))))
(DData Public "EmitPlan" () ((variant "EmitPlan" (ConNamed (field "manifestIndex" (TyApp (TyCon "List") (TyCon "ManifestRequest"))) (field "target" (TyCon "Backend")) (field "externRequirements" (TyCon "ExternRequirements")) (field "entryOutcome" (TyApp (TyCon "Option") (TyCon "EntryFact"))) (field "methodResults" (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact")))) (field "constructorFacts" (TyCon "ConstructorFacts")) (field "identity" (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyCon "IdentityDefect"))) (TyCon "IdentityPlan"))) (field "wasmOnlyReach" (TyApp (TyCon "Option") (TyCon "ReachUnits"))) (field "lazyGlobals" (TyApp (TyCon "List") (TyCon "String"))) (field "eagerReach" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "globalInit" (TyCon "GlobalInitPlan")) (field "implGroups" (TyApp (TyCon "List") (TyCon "ImplClauseGroup"))) (field "trmc" (TyCon "TrmcVerdicts")) (field "dispGroups" (TyApp (TyCon "List") (TyCon "DispGroup"))) (field "wasmDemand" (TyCon "WasmDemand")) (field "wasmInputs" (TyCon "WasmDemandInputs")) (field "wasmPhysical" (TyApp (TyCon "Option") (TyCon "WasmDemandPlan"))) (field "hostKeys" (TyApp (TyCon "List") (TyCon "String"))) (field "jsImports" (TyApp (TyCon "List") (TyCon "JsImport"))) (field "methodTables" (TyCon "MethodTables"))))) ())
(DData Public "ReachUnits" () ((variant "ReachUnits" (ConNamed (field "total" (TyCon "Int")) (field "kept" (TyCon "Int"))))) ())
(DData Public "MethodTables" () ((variant "MethodTables" (ConNamed (field "slots" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "MethodSlot")))) (field "instances" (TyApp (TyCon "OrdMap") (TyCon "InstanceTable")))))) ())
(DData Public "MethodSlot" () ((variant "MethodSlot" (ConNamed (field "method" (TyCon "String")) (field "contextDicts" (TyCon "Int")) (field "valueArity" (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "MethodSlot")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "MethodSlot" ((rf "method" (PVar "__a0")) (rf "contextDicts" (PVar "__a1")) (rf "valueArity" (PVar "__a2"))) false) (PRec "MethodSlot" ((rf "method" (PVar "__b0")) (rf "contextDicts" (PVar "__b1")) (rf "valueArity" (PVar "__b2"))) false)) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "$core.eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "$core.eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "$core.eq") (EVar "__a2")) (EVar "__b2"))))))))
(DImpl true "Debug" ((TyCon "MethodSlot")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "MethodSlot" ((rf "method" (PVar "__a0")) (rf "contextDicts" (PVar "__a1")) (rf "valueArity" (PVar "__a2"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "MethodSlot {")) (ELit (LString " method = "))) (EApp (EVar "$core.debug") (EVar "__a0"))) (ELit (LString ", contextDicts = "))) (EApp (EVar "$core.debug") (EVar "__a1"))) (ELit (LString ", valueArity = "))) (EApp (EVar "$core.debug") (EVar "__a2"))) (ELit (LString " }"))))))))
(DData Public "InstanceTable" () ((variant "InstanceTable" (ConNamed (field "iface" (TyCon "String")) (field "fills" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "SlotCallee"))))))) ())
(DData Public "SlotCallee" () ((variant "SlotCallee" (ConNamed (field "group" (TyCon "Int")) (field "inherited" (TyCon "Bool")) (field "declaredArity" (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "SlotCallee")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "SlotCallee" ((rf "group" (PVar "__a0")) (rf "inherited" (PVar "__a1")) (rf "declaredArity" (PVar "__a2"))) false) (PRec "SlotCallee" ((rf "group" (PVar "__b0")) (rf "inherited" (PVar "__b1")) (rf "declaredArity" (PVar "__b2"))) false)) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "$core.eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "$core.eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "$core.eq") (EVar "__a2")) (EVar "__b2"))))))))
(DImpl true "Debug" ((TyCon "SlotCallee")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "SlotCallee" ((rf "group" (PVar "__a0")) (rf "inherited" (PVar "__a1")) (rf "declaredArity" (PVar "__a2"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "SlotCallee {")) (ELit (LString " group = "))) (EApp (EVar "$core.debug") (EVar "__a0"))) (ELit (LString ", inherited = "))) (EApp (EVar "$core.debug") (EVar "__a1"))) (ELit (LString ", declaredArity = "))) (EApp (EVar "$core.debug") (EVar "__a2"))) (ELit (LString " }"))))))))
(DTypeSig true "interfaceSlots" (TyFun (TyCon "MethodTables") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodSlot")))))
(DFunDef false "interfaceSlots" ((PVar "tables") (PVar "iface")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "iface")) (EFieldAccess (EVar "tables") "slots"))))
(DTypeSig false "planMethodTables" (TyFun (TyCon "CProgram") (TyFun (TyApp (TyCon "List") (TyCon "ImplClauseGroup")) (TyCon "MethodTables"))))
(DFunDef false "planMethodTables" ((PCon "CProgram" PWild PWild PWild (PVar "impls") (PVar "mctx") (PVar "facts")) (PVar "groups")) (EBlock (DoLet false false (PVar "contexts") (EApp (EApp (EVar "omFromPairs") (EVar "mctx")) (EVar "omEmpty"))) (DoLet false false (PVar "slots") (EApp (EApp (EApp (EVar "fold") (EApp (EVar "addSlot") (EVar "contexts"))) (EVar "omEmpty")) (EFieldAccess (EVar "facts") "factMethodResults"))) (DoLet false false (PVar "entries") (EApp (EApp (EApp (EVar "indexImplEntries") (EVar "impls")) (ELit (LInt 0))) (EVar "omEmpty"))) (DoLet false false (PVar "byKey") (EApp (EApp (EApp (EApp (EVar "fillsByKey") (EVar "entries")) (EVar "groups")) (ELit (LInt 0))) (EVar "omEmpty"))) (DoExpr (ERecordCreate "MethodTables" ((fa "slots" (EVar "slots")) (fa "instances" (EApp (EApp (EVar "omMapValues") (EApp (EVar "instanceTable") (EVar "slots"))) (EVar "byKey"))))))))
(DTypeSig false "instanceTable" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "MethodSlot"))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "SlotCallee")))) (TyCon "InstanceTable"))))
(DFunDef false "instanceTable" ((PVar "slots") (PTuple (PVar "iface") (PVar "byMethod"))) (ERecordCreate "InstanceTable" ((fa "iface" (EVar "iface")) (fa "fills" (EApp (EApp (EVar "map") (ELam ((PVar "s")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EFieldAccess (EAnnot (EVar "s") (TyCon "MethodSlot")) "method")) (EVar "byMethod"))))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "iface")) (EVar "slots"))))))))
(DTypeSig false "addSlot" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "MethodSlot"))) (TyFun (TyCon "MethodResultFact") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "MethodSlot")))))))
(DFunDef false "addSlot" ((PVar "contexts") (PVar "acc") (PVar "row")) (EBlock (DoLet false false (PVar "have") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "row") "iface")) (EVar "acc")))) (DoExpr (EIf (EApp (EApp (EVar "any") (ELam ((PVar "s")) (EBinOp "==" (EFieldAccess (EAnnot (EVar "s") (TyCon "MethodSlot")) "method") (EFieldAccess (EVar "row") "method")))) (EVar "have")) (EVar "acc") (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "row") "iface")) (EBinOp "++" (EVar "have") (EListLit (ERecordCreate "MethodSlot" ((fa "method" (EFieldAccess (EVar "row") "method")) (fa "contextDicts" (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "ifaceMethodArityKey") (EFieldAccess (EVar "row") "iface")) (EFieldAccess (EVar "row") "method"))) (EVar "contexts")))) (fa "valueArity" (EFieldAccess (EVar "row") "valueArity"))))))) (EVar "acc"))))))
(DTypeSig false "fillsByKey" (TyFun (TyApp (TyCon "OrdMap") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyCon "ImplClauseGroup")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "SlotCallee"))))) (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "SlotCallee"))))))))))
(DFunDef false "fillsByKey" (PWild (PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "fillsByKey" ((PVar "entries") (PCons (PVar "g") (PVar "rest")) (PVar "i") (PVar "acc")) (EMatch (EApp (EApp (EVar "firstEntryOf") (EVar "entries")) (EVar "g")) (arm (PCon "Some" (PCon "CImplEntry" (PVar "method") PWild (PVar "declared") (PVar "body"))) () (EBlock (DoLet false false (PTuple (PVar "iface") (PVar "inherited")) (EMatch (EVar "body") (arm (PCon "CImplTagged" PWild PWild (PVar "word") PWild PWild PWild PWild) () (ETuple (EVar "word") (EVar "False"))) (arm (PCon "CImplDefault" (PVar "word") PWild PWild PWild PWild PWild PWild) () (ETuple (EVar "word") (EVar "True"))))) (DoLet false false (PVar "key") (EFieldAccess (EAnnot (EVar "g") (TyCon "ImplClauseGroup")) "key")) (DoLet false false (PVar "byMethod") (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "acc")) (arm (PCon "Some" (PTuple PWild (PVar "m"))) () (EVar "m")) (arm (PCon "None") () (EVar "omEmpty")))) (DoLet false false (PVar "callee") (ERecordCreate "SlotCallee" ((fa "group" (EVar "i")) (fa "inherited" (EVar "inherited")) (fa "declaredArity" (EVar "declared"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "fillsByKey") (EVar "entries")) (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (ETuple (EVar "iface") (EApp (EApp (EApp (EVar "omInsert") (EVar "method")) (EBinOp "++" (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "method")) (EVar "byMethod"))) (EListLit (EVar "callee")))) (EVar "byMethod")))) (EVar "acc")))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "fillsByKey") (EVar "entries")) (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")))))
(DTypeSig false "firstEntryOf" (TyFun (TyApp (TyCon "OrdMap") (TyCon "CImplEntry")) (TyFun (TyCon "ImplClauseGroup") (TyApp (TyCon "Option") (TyCon "CImplEntry")))))
(DFunDef false "firstEntryOf" ((PVar "entries") (PVar "g")) (EMatch (EFieldAccess (EAnnot (EVar "g") (TyCon "ImplClauseGroup")) "indices") (arm (PCons (PVar "i") PWild) () (EApp (EApp (EVar "omLookup") (EApp (EVar "intToString") (EVar "i"))) (EVar "entries"))) (arm (PList) () (EVar "None"))))
(DTypeSig true "buildEmitPlan" (TyFun (TyCon "Backend") (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyCon "CProgram") (TyCon "EmitPlan")))))
(DFunDef false "buildEmitPlan" ((PVar "target") (PVar "domain") (PVar "prog")) (EApp (EApp (EApp (EApp (EVar "buildEmitPlanWithIdentity") (EVar "target")) (EVar "domain")) (EVar "emptyPackage")) (EVar "prog")))
(DTypeSig true "buildEmitPlanWithIdentity" (TyFun (TyCon "Backend") (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyCon "PackageIdentity") (TyFun (TyCon "CProgram") (TyCon "EmitPlan"))))))
(DFunDef false "buildEmitPlanWithIdentity" ((PVar "target") (PVar "domain") (PVar "package") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "planOver") (EVar "target")) (EVar "domain")) (EVar "None")) (EVar "omEmpty")) (EApp (EApp (EVar "planProgramIdentity") (EVar "package")) (EVar "prog"))) (EVar "prog")))
(DTypeSig true "buildEmitPlanReached" (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "CProgram") (TyTuple (TyCon "EmitPlan") (TyCon "CProgram"))))))
(DFunDef false "buildEmitPlanReached" ((PVar "domain") (PVar "ctorFields") (PVar "prog")) (EApp (EApp (EApp (EApp (EVar "buildEmitPlanReachedWithIdentity") (EVar "domain")) (EVar "ctorFields")) (EVar "emptyPackage")) (EVar "prog")))
(DTypeSig true "buildEmitPlanReachedWithIdentity" (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "PackageIdentity") (TyFun (TyCon "CProgram") (TyTuple (TyCon "EmitPlan") (TyCon "CProgram")))))))
(DFunDef false "buildEmitPlanReachedWithIdentity" ((PVar "domain") (PVar "ctorFields") (PVar "package") (PVar "prog")) (EBlock (DoLet false false (PVar "identity") (EApp (EApp (EVar "planProgramIdentity") (EVar "package")) (EVar "prog"))) (DoLet false false (PVar "reached") (EApp (EVar "wasmReachFilter") (EVar "prog"))) (DoLet false false (PVar "units") (ERecordCreate "ReachUnits" ((fa "total" (EApp (EVar "programUnitCount") (EVar "prog"))) (fa "kept" (EApp (EVar "programUnitCount") (EVar "reached")))))) (DoLet false false (PVar "prepared") (EApp (EVar "uniqueBinders") (EVar "reached"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EVar "planOver") (EVar "WasmBackend")) (EVar "domain")) (EApp (EVar "Some") (EVar "units"))) (EVar "ctorFields")) (EVar "identity")) (EVar "prepared")) (EVar "prepared")))))
(DTypeSig true "prepareWasmPlan" (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "CProgram") (TyTuple (TyCon "EmitPlan") (TyCon "CProgram"))))))
(DFunDef false "prepareWasmPlan" ((PVar "domain") (PVar "ctorFields") (PVar "prog")) (EApp (EApp (EApp (EApp (EVar "prepareWasmPlanWithIdentity") (EVar "domain")) (EVar "ctorFields")) (EVar "emptyPackage")) (EVar "prog")))
(DTypeSig true "prepareWasmPlanWithIdentity" (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "PackageIdentity") (TyFun (TyCon "CProgram") (TyTuple (TyCon "EmitPlan") (TyCon "CProgram")))))))
(DFunDef false "prepareWasmPlanWithIdentity" ((PVar "domain") (PVar "ctorFields") (PVar "package") (PVar "prog")) (EBlock (DoLet false false (PVar "identity") (EApp (EApp (EVar "planProgramIdentity") (EVar "package")) (EVar "prog"))) (DoLet false false (PVar "prepared") (EApp (EVar "uniqueBinders") (EVar "prog"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EVar "planOver") (EVar "WasmBackend")) (EVar "domain")) (EVar "None")) (EVar "ctorFields")) (EVar "identity")) (EVar "prepared")) (EVar "prepared")))))
(DTypeSig false "programUnitCount" (TyFun (TyCon "CProgram") (TyCon "Int")))
(DFunDef false "programUnitCount" ((PCon "CProgram" (PVar "groups") PWild PWild (PVar "impls") PWild PWild)) (EBinOp "+" (EApp (EVar "listLen") (EVar "groups")) (EApp (EVar "listLen") (EVar "impls"))))
(DTypeSig false "planOver" (TyFun (TyCon "Backend") (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyApp (TyCon "Option") (TyCon "ReachUnits")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyCon "IdentityDefect"))) (TyCon "IdentityPlan")) (TyFun (TyCon "CProgram") (TyCon "EmitPlan"))))))))
(DFunDef false "planOver" ((PVar "target") (PVar "domain") (PVar "reach") (PVar "ctorFields") (PVar "identity") (PVar "prog")) (EBlock (DoLet false false (PCon "CProgram" (PVar "groups") PWild PWild (PVar "impls") PWild (PVar "facts")) (EVar "prog")) (DoLet false false (PVar "constructors") (EApp (EVar "planConstructors") (EVar "prog"))) (DoLet false false (PVar "ctors") (EFieldAccess (EVar "constructors") "arities")) (DoLet false false (PVar "fns") (EApp (EApp (EVar "filterList") (EVar "isTopFn")) (EVar "groups"))) (DoLet false false (PVar "requirements") (EApp (EApp (EApp (EVar "planExterns") (EVar "target")) (EVar "domain")) (EVar "prog"))) (DoLet false false (PVar "lazy") (EApp (EApp (EVar "lazyGlobalNames") (EVar "ctors")) (EVar "groups"))) (DoLet false false (PVar "eager") (EApp (EVar "eagerReachMap") (EVar "groups"))) (DoLet false false (PVar "globalInit") (EApp (EApp (EApp (EVar "planGlobals") (EVar "prog")) (EVar "lazy")) (EVar "eager"))) (DoLet false false (PVar "implGroups") (EApp (EVar "groupImplEntries") (EVar "impls"))) (DoLet false false (PVar "trmc") (ERecordCreate "TrmcVerdicts" ((fa "eligibleFns" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "bindName")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "selfTrmcBind") (EVar "ctors")) (EVar "b")))) (EVar "fns")))) (EVar "omEmpty"))) (fa "eligibleImpls" (EApp (EApp (EApp (EVar "trmcImplKeys") (EVar "ctors")) (EVar "impls")) (EVar "implGroups")))))) (DoLet false false (PVar "dispatch") (EApp (EApp (EApp (EApp (EVar "planDispatchGroups") (EVar "ctors")) (EVar "fns")) (EVar "groups")) (EVar "impls"))) (DoLet false false (PVar "inputs") (ERecordCreate "WasmDemandInputs" ((fa "ctorFloatFields" (EVar "ctorFields")) (fa "lazyGlobals" (EVar "lazy")) (fa "globalInit" (EVar "globalInit")) (fa "trmcVerdicts" (EVar "trmc")) (fa "dispatchGroups" (EVar "dispatch"))))) (DoLet false false (PVar "physical") (EMatch (EVar "target") (arm (PCon "WasmBackend") () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "planWasmDemand") (EVar "constructors")) (EVar "inputs")) (EVar "prog")) (EVar "requirements")))) (arm PWild () (EVar "None")))) (DoExpr (ERecordCreate "EmitPlan" ((fa "manifestIndex" (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EFieldAccess (EAnnot (EVar "m") (TyCon "CapabilityManifest")) "request"))) (EFieldAccess (EVar "facts") "factManifests"))) (fa "target" (EVar "target")) (fa "externRequirements" (EVar "requirements")) (fa "entryOutcome" (EFieldAccess (EVar "facts") "factEntryOutcome")) (fa "methodResults" (EApp (EVar "indexMethodResults") (EFieldAccess (EVar "facts") "factMethodResults"))) (fa "constructorFacts" (EVar "constructors")) (fa "identity" (EVar "identity")) (fa "wasmOnlyReach" (EVar "reach")) (fa "lazyGlobals" (EVar "lazy")) (fa "eagerReach" (EVar "eager")) (fa "globalInit" (EVar "globalInit")) (fa "implGroups" (EVar "implGroups")) (fa "trmc" (EVar "trmc")) (fa "dispGroups" (EVar "dispatch")) (fa "wasmDemand" (EMatch (EVar "physical") (arm (PCon "Some" (PVar "p")) () (EFieldAccess (EVar "p") "sourceDemand")) (arm (PCon "None") () (EVar "noDemand")))) (fa "wasmInputs" (EVar "inputs")) (fa "wasmPhysical" (EVar "physical")) (fa "hostKeys" (EMatch (EVar "physical") (arm (PCon "Some" (PVar "p")) () (EFieldAccess (EVar "p") "sourceHostKeys")) (arm (PCon "None") () (EListLit)))) (fa "jsImports" (EMatch (EVar "physical") (arm (PCon "Some" (PVar "p")) () (EFieldAccess (EVar "p") "jsImports")) (arm (PCon "None") () (EListLit)))) (fa "methodTables" (EApp (EApp (EVar "planMethodTables") (EVar "prog")) (EVar "implGroups"))))))))
(DTypeSig true "planEntryMainIsUnit" (TyFun (TyCon "EmitPlan") (TyCon "Bool")))
(DFunDef false "planEntryMainIsUnit" ((PVar "plan")) (EMatch (EFieldAccess (EVar "plan") "entryOutcome") (arm (PCon "Some" (PVar "outcome")) () (EFieldAccess (EVar "outcome") "entryMainIsUnit")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "planEntryMainIsFloat" (TyFun (TyCon "EmitPlan") (TyCon "Bool")))
(DFunDef false "planEntryMainIsFloat" ((PVar "plan")) (EMatch (EFieldAccess (EVar "plan") "entryOutcome") (arm (PCon "Some" (PVar "outcome")) () (EFieldAccess (EVar "outcome") "entryMainIsFloat")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "indexMethodResults" (TyFun (TyApp (TyCon "List") (TyCon "MethodResultFact")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact")))))
(DFunDef false "indexMethodResults" ((PVar "rows")) (EApp (EApp (EApp (EVar "fold") (EVar "insertMethodResult")) (EVar "omEmpty")) (EApp (EVar "reverseL") (EVar "rows"))))
(DTypeSig false "insertMethodResult" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact"))) (TyFun (TyCon "MethodResultFact") (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact"))))))
(DFunDef false "insertMethodResult" ((PVar "acc") (PVar "row")) (EBlock (DoLet false false (PVar "methods") (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "row") "iface")) (EVar "acc")))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "row") "iface")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "row") "method")) (EVar "row")) (EVar "methods"))) (EVar "acc")))))
(DTypeSig true "lookupMethodResult" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "MethodResultFact"))))))
(DFunDef false "lookupMethodResult" ((PVar "index") (PVar "iface") (PVar "method")) (EApp (EApp (EVar "$core.andThen") (EApp (EApp (EVar "omLookup") (EVar "iface")) (EVar "index"))) (ELam ((PVar "methods")) (EApp (EApp (EVar "omLookup") (EVar "method")) (EVar "methods")))))
(DTypeSig false "isTopFn" (TyFun (TyCon "CBind") (TyCon "Bool")))
(DFunDef false "isTopFn" ((PCon "CBind" (PLit (LString "main")) PWild PWild PWild)) (EVar "False"))
(DFunDef false "isTopFn" ((PCon "CBind" PWild (PCons (PCon "CClause" (PCons PWild PWild) PWild) PWild) PWild PWild)) (EVar "True"))
(DFunDef false "isTopFn" (PWild) (EVar "False"))
(DTypeSig false "isCtorIn" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isCtorIn" ((PVar "ctors") (PVar "name")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "ctors")))
(DTypeSig false "ctorArityIn" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "ctorArityIn" ((PVar "ctors") (PVar "name")) (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "ctors"))))
(DTypeSig false "clausePair" (TyFun (TyCon "CClause") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "CExpr"))))
(DFunDef false "clausePair" ((PCon "CClause" (PVar "pats") (PVar "body"))) (ETuple (EVar "pats") (EVar "body")))
(DTypeSig false "clausesTrmc" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "SelfRef") (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyCon "Bool")))))
(DFunDef false "clausesTrmc" ((PVar "ctors") (PVar "self") (PVar "clauses")) (EBlock (DoLet false false (PVar "arity") (EApp (EVar "clauseArityOf") (EVar "clauses"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "arity") (ELit (LInt 0))) (EApp (EVar "dictUniformClauses") (EVar "clauses"))) (EApp (EApp (EApp (EApp (EApp (EVar "trmcEligible") (EApp (EVar "isCtorIn") (EVar "ctors"))) (EApp (EVar "ctorArityIn") (EVar "ctors"))) (EVar "self")) (EVar "arity")) (EApp (EApp (EVar "map") (EVar "clausePair")) (EVar "clauses")))))))
(DTypeSig false "selfTrmcBind" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CBind") (TyCon "Bool"))))
(DFunDef false "selfTrmcBind" ((PVar "ctors") (PCon "CBind" (PVar "name") (PVar "clauses") PWild PWild)) (EApp (EApp (EApp (EVar "clausesTrmc") (EVar "ctors")) (EApp (EVar "SelfByVar") (EVar "name"))) (EVar "clauses")))
(DTypeSig false "implGroupKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "implGroupKey" ((PVar "method") (PVar "key")) (EBinOp "++" (EApp (EVar "lenKey") (EVar "method")) (EVar "key")))
(DTypeSig false "trmcImplKeys" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyCon "ImplClauseGroup")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "trmcImplKeys" ((PVar "ctors") (PVar "impls") (PVar "groups")) (EBlock (DoLet false false (PVar "indexed") (EApp (EApp (EApp (EVar "indexImplEntries") (EVar "impls")) (ELit (LInt 0))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (ELam ((PVar "g")) (EApp (EApp (EVar "implGroupKey") (EFieldAccess (EAnnot (EVar "g") (TyCon "ImplClauseGroup")) "method")) (EFieldAccess (EAnnot (EVar "g") (TyCon "ImplClauseGroup")) "key")))) (EApp (EApp (EVar "filterList") (ELam ((PVar "g")) (EBlock (DoLet false false (PVar "clauses") (EApp (EApp (EVar "flatMap") (ELam ((PVar "i")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "intToString") (EVar "i"))) (EVar "indexed")) (arm (PCon "Some" (PCon "CImplEntry" PWild PWild PWild (PVar "body"))) () (EListLit (EApp (EVar "snd") (EApp (EVar "implKeyClause") (EVar "body"))))) (arm (PCon "None") () (EListLit))))) (EFieldAccess (EAnnot (EVar "g") (TyCon "ImplClauseGroup")) "indices"))) (DoExpr (EApp (EApp (EApp (EVar "clausesTrmc") (EVar "ctors")) (EApp (EApp (EApp (EVar "methodSelf") (EFieldAccess (EAnnot (EVar "g") (TyCon "ImplClauseGroup")) "method")) (EFieldAccess (EAnnot (EVar "g") (TyCon "ImplClauseGroup")) "key")) (EApp (EVar "firstPats") (EVar "clauses")))) (EVar "clauses")))))) (EVar "groups")))) (EVar "omEmpty")))))
(DTypeSig false "indexImplEntries" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "CImplEntry")) (TyApp (TyCon "OrdMap") (TyCon "CImplEntry"))))))
(DFunDef false "indexImplEntries" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "indexImplEntries" ((PCons (PVar "entry") (PVar "rest")) (PVar "i") (PVar "acc")) (EApp (EApp (EApp (EVar "indexImplEntries") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "intToString") (EVar "i"))) (EVar "entry")) (EVar "acc"))))
(DTypeSig false "implKeyClause" (TyFun (TyCon "CImplBody") (TyTuple (TyCon "String") (TyCon "CClause"))))
(DFunDef false "implKeyClause" ((PCon "CImplTagged" PWild (PVar "key") PWild PWild PWild (PVar "pats") (PVar "body"))) (ETuple (EVar "key") (EApp (EApp (EVar "CClause") (EVar "pats")) (EVar "body"))))
(DFunDef false "implKeyClause" ((PCon "CImplDefault" PWild PWild (PVar "key") PWild PWild (PVar "pats") (PVar "body"))) (ETuple (EVar "key") (EApp (EApp (EVar "CClause") (EVar "pats")) (EVar "body"))))
(DTypeSig false "firstPats" (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "firstPats" ((PCons (PCon "CClause" (PVar "pats") PWild) PWild)) (EVar "pats"))
(DFunDef false "firstPats" ((PList)) (EListLit))
(DTypeSig false "planDispatchGroups" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyCon "List") (TyCon "DispGroup")))))))
(DFunDef false "planDispatchGroups" ((PVar "ctors") (PVar "fns") (PVar "groups") (PVar "impls")) (EBlock (DoLet false false (PVar "arities") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EVar "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "bindName") (EVar "b")) (EApp (EVar "bindArity") (EVar "b"))))) (EVar "fns")))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "detectDispatchGroups") (ELam ((PVar "n")) (EApp (EApp (EVar "canonFnIn") (EVar "arities")) (EVar "n")))) (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "arities")))) (ELam ((PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "arities")) (arm (PCon "Some" (PVar "a")) () (EVar "a")) (arm (PCon "None") () (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))))) (ELam ((PVar "nm") PWild (PVar "cs")) (EApp (EApp (EApp (EVar "clausesTrmc") (EVar "ctors")) (EApp (EVar "SelfByVar") (EVar "nm"))) (EVar "cs")))) (EVar "fns")) (EVar "groups")) (EVar "impls")))))
(DTypeSig false "bindArity" (TyFun (TyCon "CBind") (TyCon "Int")))
(DFunDef false "bindArity" ((PCon "CBind" PWild (PVar "clauses") PWild PWild)) (EApp (EVar "clauseArityOf") (EVar "clauses")))
(DTypeSig false "canonFnIn" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "canonFnIn" ((PVar "fns") (PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "fns")) (EVar "name") (EIf (EApp (EApp (EVar "omHasKey") (EApp (EApp (EVar "encodePair") (ELit (LString "core"))) (EVar "name"))) (EVar "fns")) (EApp (EApp (EVar "encodePair") (ELit (LString "core"))) (EVar "name")) (EVar "name"))))
(DTypeSig false "noDemand" (TyCon "WasmDemand"))
(DFunDef false "noDemand" () (ERecordCreate "WasmDemand" ((fa "uses" (EListLit)) (fa "refBox" (EVar "False")) (fa "divGuard" (EVar "False")) (fa "tupleArities" (EListLit)))))
(DData Private "DemandAcc" () ((variant "DemandAcc" (ConNamed (field "seenUses" (TyApp (TyCon "List") (TyCon "WasmUse"))) (field "seenKeys" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "seenJs" (TyApp (TyCon "OrdMap") (TyCon "JsImport"))) (field "seenRefBox" (TyCon "Bool")) (field "seenDivGuard" (TyCon "Bool")) (field "seenArities" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DData Private "DemandScope" () ((variant "DemandScope" (ConNamed (field "locals" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "topFns" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "topVals" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "jsBinds" (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))) (field "externFacts" (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")))))) ())
# MARK
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("backend" "package_identity") ((mem "PackageIdentity" false) (mem "IdentityPlan" false) (mem "IdentityDefect" false) (mem "emptyPackage" false) (mem "planProgramIdentity" false))))
(DUse false (UseGroup ("backend" "impl_groups") ((mem "ImplClauseGroup" false) (mem "groupImplEntries" false))))
(DUse false (UseGroup ("ir" "constructor_facts") ((mem "ConstructorFacts" false) (mem "planConstructors" false))))
(DUse false (UseGroup ("support" "symbol_encoding") ((mem "encodePair" false))))
(DUse false (UseGroup ("backend" "wasm_demand") ((mem "JsImport" true) (mem "WasmDemand" true) (mem "WasmDemandInputs" true) (mem "WasmDemandPlan" false) (mem "planWasmDemand" false))))
(DUse false (UseGroup ("backend" "wasm_names") ((mem "uniqueBinders" false))))
(DUse false (UseGroup ("backend" "extern_requirements") ((mem "ExternRequirements" false) (mem "planExterns" false))))
(DUse false (UseGroup ("backend" "global_plan") ((mem "GlobalInitPlan" false) (mem "planGlobals" false))))
(DUse false (UseGroup ("backend" "emit_target") ((mem "Backend" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Pat" true))))
(DUse false (UseGroup ("ir" "extern_types") ((mem "ExternDeclFact" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "EntryFact" true) (mem "MethodResultFact" true) (mem "CArm" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CField" true) (mem "CGuard" true) (mem "CHead" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CStmt" true) (mem "CTBranch" true) (mem "CTree" true) (mem "ifaceMethodArityKey" false))))
(DUse false (UseGroup ("backend" "extern_catalog") ((mem "RuntimeExternDomain" false) (mem "WasmUse" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omFromNames" false) (mem "omFromPairs" false) (mem "omMapValues" false))))
(DUse false (UseGroup ("support" "util") ((mem "lenKey" false) (mem "reverseL" false) (mem "filterList" false) (mem "listLen" false))))
(DUse false (UseGroup ("backend" "wasm_reach") ((mem "wasmReachFilter" false))))
(DUse false (UseGroup ("backend" "emit_support") ((mem "eagerReachMap" false) (mem "lazyGlobalNames" false))))
(DUse false (UseGroup ("backend" "trmc_analysis") ((mem "TrmcVerdicts" true) (mem "SelfRef" true) (mem "DispGroup" false) (mem "trmcEligible" false) (mem "detectDispatchGroups" false) (mem "dictUniformClauses" false) (mem "methodSelf" false) (mem "clauseArityOf" false) (mem "bindName" false))))
(DUse false (UseGroup ("types" "capability_manifest") ((mem "ManifestRequest" false) (mem "CapabilityManifest" false))))
(DData Public "EmitPlan" () ((variant "EmitPlan" (ConNamed (field "manifestIndex" (TyApp (TyCon "List") (TyCon "ManifestRequest"))) (field "target" (TyCon "Backend")) (field "externRequirements" (TyCon "ExternRequirements")) (field "entryOutcome" (TyApp (TyCon "Option") (TyCon "EntryFact"))) (field "methodResults" (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact")))) (field "constructorFacts" (TyCon "ConstructorFacts")) (field "identity" (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyCon "IdentityDefect"))) (TyCon "IdentityPlan"))) (field "wasmOnlyReach" (TyApp (TyCon "Option") (TyCon "ReachUnits"))) (field "lazyGlobals" (TyApp (TyCon "List") (TyCon "String"))) (field "eagerReach" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "globalInit" (TyCon "GlobalInitPlan")) (field "implGroups" (TyApp (TyCon "List") (TyCon "ImplClauseGroup"))) (field "trmc" (TyCon "TrmcVerdicts")) (field "dispGroups" (TyApp (TyCon "List") (TyCon "DispGroup"))) (field "wasmDemand" (TyCon "WasmDemand")) (field "wasmInputs" (TyCon "WasmDemandInputs")) (field "wasmPhysical" (TyApp (TyCon "Option") (TyCon "WasmDemandPlan"))) (field "hostKeys" (TyApp (TyCon "List") (TyCon "String"))) (field "jsImports" (TyApp (TyCon "List") (TyCon "JsImport"))) (field "methodTables" (TyCon "MethodTables"))))) ())
(DData Public "ReachUnits" () ((variant "ReachUnits" (ConNamed (field "total" (TyCon "Int")) (field "kept" (TyCon "Int"))))) ())
(DData Public "MethodTables" () ((variant "MethodTables" (ConNamed (field "slots" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "MethodSlot")))) (field "instances" (TyApp (TyCon "OrdMap") (TyCon "InstanceTable")))))) ())
(DData Public "MethodSlot" () ((variant "MethodSlot" (ConNamed (field "method" (TyCon "String")) (field "contextDicts" (TyCon "Int")) (field "valueArity" (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "MethodSlot")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "MethodSlot" ((rf "method" (PVar "__a0")) (rf "contextDicts" (PVar "__a1")) (rf "valueArity" (PVar "__a2"))) false) (PRec "MethodSlot" ((rf "method" (PVar "__b0")) (rf "contextDicts" (PVar "__b1")) (rf "valueArity" (PVar "__b2"))) false)) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "$core.eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "$core.eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "$core.eq") (EVar "__a2")) (EVar "__b2"))))))))
(DImpl true "Debug" ((TyCon "MethodSlot")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "MethodSlot" ((rf "method" (PVar "__a0")) (rf "contextDicts" (PVar "__a1")) (rf "valueArity" (PVar "__a2"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "MethodSlot {")) (ELit (LString " method = "))) (EApp (EVar "$core.debug") (EVar "__a0"))) (ELit (LString ", contextDicts = "))) (EApp (EVar "$core.debug") (EVar "__a1"))) (ELit (LString ", valueArity = "))) (EApp (EVar "$core.debug") (EVar "__a2"))) (ELit (LString " }"))))))))
(DData Public "InstanceTable" () ((variant "InstanceTable" (ConNamed (field "iface" (TyCon "String")) (field "fills" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "SlotCallee"))))))) ())
(DData Public "SlotCallee" () ((variant "SlotCallee" (ConNamed (field "group" (TyCon "Int")) (field "inherited" (TyCon "Bool")) (field "declaredArity" (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "SlotCallee")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "SlotCallee" ((rf "group" (PVar "__a0")) (rf "inherited" (PVar "__a1")) (rf "declaredArity" (PVar "__a2"))) false) (PRec "SlotCallee" ((rf "group" (PVar "__b0")) (rf "inherited" (PVar "__b1")) (rf "declaredArity" (PVar "__b2"))) false)) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "$core.eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "$core.eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "$core.eq") (EVar "__a2")) (EVar "__b2"))))))))
(DImpl true "Debug" ((TyCon "SlotCallee")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "SlotCallee" ((rf "group" (PVar "__a0")) (rf "inherited" (PVar "__a1")) (rf "declaredArity" (PVar "__a2"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "SlotCallee {")) (ELit (LString " group = "))) (EApp (EVar "$core.debug") (EVar "__a0"))) (ELit (LString ", inherited = "))) (EApp (EVar "$core.debug") (EVar "__a1"))) (ELit (LString ", declaredArity = "))) (EApp (EVar "$core.debug") (EVar "__a2"))) (ELit (LString " }"))))))))
(DTypeSig true "interfaceSlots" (TyFun (TyCon "MethodTables") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "MethodSlot")))))
(DFunDef false "interfaceSlots" ((PVar "tables") (PVar "iface")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "iface")) (EFieldAccess (EVar "tables") "slots"))))
(DTypeSig false "planMethodTables" (TyFun (TyCon "CProgram") (TyFun (TyApp (TyCon "List") (TyCon "ImplClauseGroup")) (TyCon "MethodTables"))))
(DFunDef false "planMethodTables" ((PCon "CProgram" PWild PWild PWild (PVar "impls") (PVar "mctx") (PVar "facts")) (PVar "groups")) (EBlock (DoLet false false (PVar "contexts") (EApp (EApp (EVar "omFromPairs") (EVar "mctx")) (EVar "omEmpty"))) (DoLet false false (PVar "slots") (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "addSlot") (EVar "contexts"))) (EVar "omEmpty")) (EFieldAccess (EVar "facts") "factMethodResults"))) (DoLet false false (PVar "entries") (EApp (EApp (EApp (EVar "indexImplEntries") (EVar "impls")) (ELit (LInt 0))) (EVar "omEmpty"))) (DoLet false false (PVar "byKey") (EApp (EApp (EApp (EApp (EVar "fillsByKey") (EVar "entries")) (EVar "groups")) (ELit (LInt 0))) (EVar "omEmpty"))) (DoExpr (ERecordCreate "MethodTables" ((fa "slots" (EVar "slots")) (fa "instances" (EApp (EApp (EVar "omMapValues") (EApp (EVar "instanceTable") (EVar "slots"))) (EVar "byKey"))))))))
(DTypeSig false "instanceTable" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "MethodSlot"))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "SlotCallee")))) (TyCon "InstanceTable"))))
(DFunDef false "instanceTable" ((PVar "slots") (PTuple (PVar "iface") (PVar "byMethod"))) (ERecordCreate "InstanceTable" ((fa "iface" (EVar "iface")) (fa "fills" (EApp (EApp (EMethodRef "map") (ELam ((PVar "s")) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EFieldAccess (EAnnot (EVar "s") (TyCon "MethodSlot")) "method")) (EVar "byMethod"))))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "iface")) (EVar "slots"))))))))
(DTypeSig false "addSlot" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "MethodSlot"))) (TyFun (TyCon "MethodResultFact") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "MethodSlot")))))))
(DFunDef false "addSlot" ((PVar "contexts") (PVar "acc") (PVar "row")) (EBlock (DoLet false false (PVar "have") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "row") "iface")) (EVar "acc")))) (DoExpr (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "s")) (EBinOp "==" (EFieldAccess (EAnnot (EVar "s") (TyCon "MethodSlot")) "method") (EFieldAccess (EVar "row") "method")))) (EVar "have")) (EVar "acc") (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "row") "iface")) (EBinOp "++" (EVar "have") (EListLit (ERecordCreate "MethodSlot" ((fa "method" (EFieldAccess (EVar "row") "method")) (fa "contextDicts" (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EApp (EApp (EVar "ifaceMethodArityKey") (EFieldAccess (EVar "row") "iface")) (EFieldAccess (EVar "row") "method"))) (EVar "contexts")))) (fa "valueArity" (EFieldAccess (EVar "row") "valueArity"))))))) (EVar "acc"))))))
(DTypeSig false "fillsByKey" (TyFun (TyApp (TyCon "OrdMap") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyCon "ImplClauseGroup")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "SlotCallee"))))) (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "SlotCallee"))))))))))
(DFunDef false "fillsByKey" (PWild (PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "fillsByKey" ((PVar "entries") (PCons (PVar "g") (PVar "rest")) (PVar "i") (PVar "acc")) (EMatch (EApp (EApp (EVar "firstEntryOf") (EVar "entries")) (EVar "g")) (arm (PCon "Some" (PCon "CImplEntry" (PVar "method") PWild (PVar "declared") (PVar "body"))) () (EBlock (DoLet false false (PTuple (PVar "iface") (PVar "inherited")) (EMatch (EVar "body") (arm (PCon "CImplTagged" PWild PWild (PVar "word") PWild PWild PWild PWild) () (ETuple (EVar "word") (EVar "False"))) (arm (PCon "CImplDefault" (PVar "word") PWild PWild PWild PWild PWild PWild) () (ETuple (EVar "word") (EVar "True"))))) (DoLet false false (PVar "key") (EFieldAccess (EAnnot (EVar "g") (TyCon "ImplClauseGroup")) "key")) (DoLet false false (PVar "byMethod") (EMatch (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "acc")) (arm (PCon "Some" (PTuple PWild (PVar "m"))) () (EVar "m")) (arm (PCon "None") () (EVar "omEmpty")))) (DoLet false false (PVar "callee") (ERecordCreate "SlotCallee" ((fa "group" (EVar "i")) (fa "inherited" (EVar "inherited")) (fa "declaredArity" (EVar "declared"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "fillsByKey") (EVar "entries")) (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "omInsert") (EVar "key")) (ETuple (EVar "iface") (EApp (EApp (EApp (EVar "omInsert") (EVar "method")) (EBinOp "++" (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "method")) (EVar "byMethod"))) (EListLit (EVar "callee")))) (EVar "byMethod")))) (EVar "acc")))))) (arm (PCon "None") () (EApp (EApp (EApp (EApp (EVar "fillsByKey") (EVar "entries")) (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "acc")))))
(DTypeSig false "firstEntryOf" (TyFun (TyApp (TyCon "OrdMap") (TyCon "CImplEntry")) (TyFun (TyCon "ImplClauseGroup") (TyApp (TyCon "Option") (TyCon "CImplEntry")))))
(DFunDef false "firstEntryOf" ((PVar "entries") (PVar "g")) (EMatch (EFieldAccess (EAnnot (EVar "g") (TyCon "ImplClauseGroup")) "indices") (arm (PCons (PVar "i") PWild) () (EApp (EApp (EVar "omLookup") (EApp (EVar "intToString") (EVar "i"))) (EVar "entries"))) (arm (PList) () (EVar "None"))))
(DTypeSig true "buildEmitPlan" (TyFun (TyCon "Backend") (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyCon "CProgram") (TyCon "EmitPlan")))))
(DFunDef false "buildEmitPlan" ((PVar "target") (PVar "domain") (PVar "prog")) (EApp (EApp (EApp (EApp (EVar "buildEmitPlanWithIdentity") (EVar "target")) (EVar "domain")) (EVar "emptyPackage")) (EVar "prog")))
(DTypeSig true "buildEmitPlanWithIdentity" (TyFun (TyCon "Backend") (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyCon "PackageIdentity") (TyFun (TyCon "CProgram") (TyCon "EmitPlan"))))))
(DFunDef false "buildEmitPlanWithIdentity" ((PVar "target") (PVar "domain") (PVar "package") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "planOver") (EVar "target")) (EVar "domain")) (EVar "None")) (EVar "omEmpty")) (EApp (EApp (EVar "planProgramIdentity") (EVar "package")) (EVar "prog"))) (EVar "prog")))
(DTypeSig true "buildEmitPlanReached" (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "CProgram") (TyTuple (TyCon "EmitPlan") (TyCon "CProgram"))))))
(DFunDef false "buildEmitPlanReached" ((PVar "domain") (PVar "ctorFields") (PVar "prog")) (EApp (EApp (EApp (EApp (EVar "buildEmitPlanReachedWithIdentity") (EVar "domain")) (EVar "ctorFields")) (EVar "emptyPackage")) (EVar "prog")))
(DTypeSig true "buildEmitPlanReachedWithIdentity" (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "PackageIdentity") (TyFun (TyCon "CProgram") (TyTuple (TyCon "EmitPlan") (TyCon "CProgram")))))))
(DFunDef false "buildEmitPlanReachedWithIdentity" ((PVar "domain") (PVar "ctorFields") (PVar "package") (PVar "prog")) (EBlock (DoLet false false (PVar "identity") (EApp (EApp (EVar "planProgramIdentity") (EVar "package")) (EVar "prog"))) (DoLet false false (PVar "reached") (EApp (EVar "wasmReachFilter") (EVar "prog"))) (DoLet false false (PVar "units") (ERecordCreate "ReachUnits" ((fa "total" (EApp (EVar "programUnitCount") (EVar "prog"))) (fa "kept" (EApp (EVar "programUnitCount") (EVar "reached")))))) (DoLet false false (PVar "prepared") (EApp (EVar "uniqueBinders") (EVar "reached"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EVar "planOver") (EVar "WasmBackend")) (EVar "domain")) (EApp (EVar "Some") (EVar "units"))) (EVar "ctorFields")) (EVar "identity")) (EVar "prepared")) (EVar "prepared")))))
(DTypeSig true "prepareWasmPlan" (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "CProgram") (TyTuple (TyCon "EmitPlan") (TyCon "CProgram"))))))
(DFunDef false "prepareWasmPlan" ((PVar "domain") (PVar "ctorFields") (PVar "prog")) (EApp (EApp (EApp (EApp (EVar "prepareWasmPlanWithIdentity") (EVar "domain")) (EVar "ctorFields")) (EVar "emptyPackage")) (EVar "prog")))
(DTypeSig true "prepareWasmPlanWithIdentity" (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "PackageIdentity") (TyFun (TyCon "CProgram") (TyTuple (TyCon "EmitPlan") (TyCon "CProgram")))))))
(DFunDef false "prepareWasmPlanWithIdentity" ((PVar "domain") (PVar "ctorFields") (PVar "package") (PVar "prog")) (EBlock (DoLet false false (PVar "identity") (EApp (EApp (EVar "planProgramIdentity") (EVar "package")) (EVar "prog"))) (DoLet false false (PVar "prepared") (EApp (EVar "uniqueBinders") (EVar "prog"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EVar "planOver") (EVar "WasmBackend")) (EVar "domain")) (EVar "None")) (EVar "ctorFields")) (EVar "identity")) (EVar "prepared")) (EVar "prepared")))))
(DTypeSig false "programUnitCount" (TyFun (TyCon "CProgram") (TyCon "Int")))
(DFunDef false "programUnitCount" ((PCon "CProgram" (PVar "groups") PWild PWild (PVar "impls") PWild PWild)) (EBinOp "+" (EApp (EVar "listLen") (EVar "groups")) (EApp (EVar "listLen") (EVar "impls"))))
(DTypeSig false "planOver" (TyFun (TyCon "Backend") (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyApp (TyCon "Option") (TyCon "ReachUnits")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyCon "IdentityDefect"))) (TyCon "IdentityPlan")) (TyFun (TyCon "CProgram") (TyCon "EmitPlan"))))))))
(DFunDef false "planOver" ((PVar "target") (PVar "domain") (PVar "reach") (PVar "ctorFields") (PVar "identity") (PVar "prog")) (EBlock (DoLet false false (PCon "CProgram" (PVar "groups") PWild PWild (PVar "impls") PWild (PVar "facts")) (EVar "prog")) (DoLet false false (PVar "constructors") (EApp (EVar "planConstructors") (EVar "prog"))) (DoLet false false (PVar "ctors") (EFieldAccess (EVar "constructors") "arities")) (DoLet false false (PVar "fns") (EApp (EApp (EVar "filterList") (EVar "isTopFn")) (EVar "groups"))) (DoLet false false (PVar "requirements") (EApp (EApp (EApp (EVar "planExterns") (EVar "target")) (EVar "domain")) (EVar "prog"))) (DoLet false false (PVar "lazy") (EApp (EApp (EVar "lazyGlobalNames") (EVar "ctors")) (EVar "groups"))) (DoLet false false (PVar "eager") (EApp (EVar "eagerReachMap") (EVar "groups"))) (DoLet false false (PVar "globalInit") (EApp (EApp (EApp (EVar "planGlobals") (EVar "prog")) (EVar "lazy")) (EVar "eager"))) (DoLet false false (PVar "implGroups") (EApp (EVar "groupImplEntries") (EVar "impls"))) (DoLet false false (PVar "trmc") (ERecordCreate "TrmcVerdicts" ((fa "eligibleFns" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "bindName")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "selfTrmcBind") (EVar "ctors")) (EVar "b")))) (EVar "fns")))) (EVar "omEmpty"))) (fa "eligibleImpls" (EApp (EApp (EApp (EVar "trmcImplKeys") (EVar "ctors")) (EVar "impls")) (EVar "implGroups")))))) (DoLet false false (PVar "dispatch") (EApp (EApp (EApp (EApp (EVar "planDispatchGroups") (EVar "ctors")) (EVar "fns")) (EVar "groups")) (EVar "impls"))) (DoLet false false (PVar "inputs") (ERecordCreate "WasmDemandInputs" ((fa "ctorFloatFields" (EVar "ctorFields")) (fa "lazyGlobals" (EVar "lazy")) (fa "globalInit" (EVar "globalInit")) (fa "trmcVerdicts" (EVar "trmc")) (fa "dispatchGroups" (EVar "dispatch"))))) (DoLet false false (PVar "physical") (EMatch (EVar "target") (arm (PCon "WasmBackend") () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "planWasmDemand") (EVar "constructors")) (EVar "inputs")) (EVar "prog")) (EVar "requirements")))) (arm PWild () (EVar "None")))) (DoExpr (ERecordCreate "EmitPlan" ((fa "manifestIndex" (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EFieldAccess (EAnnot (EVar "m") (TyCon "CapabilityManifest")) "request"))) (EFieldAccess (EVar "facts") "factManifests"))) (fa "target" (EVar "target")) (fa "externRequirements" (EVar "requirements")) (fa "entryOutcome" (EFieldAccess (EVar "facts") "factEntryOutcome")) (fa "methodResults" (EApp (EVar "indexMethodResults") (EFieldAccess (EVar "facts") "factMethodResults"))) (fa "constructorFacts" (EVar "constructors")) (fa "identity" (EVar "identity")) (fa "wasmOnlyReach" (EVar "reach")) (fa "lazyGlobals" (EVar "lazy")) (fa "eagerReach" (EVar "eager")) (fa "globalInit" (EVar "globalInit")) (fa "implGroups" (EVar "implGroups")) (fa "trmc" (EVar "trmc")) (fa "dispGroups" (EVar "dispatch")) (fa "wasmDemand" (EMatch (EVar "physical") (arm (PCon "Some" (PVar "p")) () (EFieldAccess (EVar "p") "sourceDemand")) (arm (PCon "None") () (EVar "noDemand")))) (fa "wasmInputs" (EVar "inputs")) (fa "wasmPhysical" (EVar "physical")) (fa "hostKeys" (EMatch (EVar "physical") (arm (PCon "Some" (PVar "p")) () (EFieldAccess (EVar "p") "sourceHostKeys")) (arm (PCon "None") () (EListLit)))) (fa "jsImports" (EMatch (EVar "physical") (arm (PCon "Some" (PVar "p")) () (EFieldAccess (EVar "p") "jsImports")) (arm (PCon "None") () (EListLit)))) (fa "methodTables" (EApp (EApp (EVar "planMethodTables") (EVar "prog")) (EVar "implGroups"))))))))
(DTypeSig true "planEntryMainIsUnit" (TyFun (TyCon "EmitPlan") (TyCon "Bool")))
(DFunDef false "planEntryMainIsUnit" ((PVar "plan")) (EMatch (EFieldAccess (EVar "plan") "entryOutcome") (arm (PCon "Some" (PVar "outcome")) () (EFieldAccess (EVar "outcome") "entryMainIsUnit")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "planEntryMainIsFloat" (TyFun (TyCon "EmitPlan") (TyCon "Bool")))
(DFunDef false "planEntryMainIsFloat" ((PVar "plan")) (EMatch (EFieldAccess (EVar "plan") "entryOutcome") (arm (PCon "Some" (PVar "outcome")) () (EFieldAccess (EVar "outcome") "entryMainIsFloat")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "indexMethodResults" (TyFun (TyApp (TyCon "List") (TyCon "MethodResultFact")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact")))))
(DFunDef false "indexMethodResults" ((PVar "rows")) (EApp (EApp (EApp (EMethodRef "fold") (EVar "insertMethodResult")) (EVar "omEmpty")) (EApp (EVar "reverseL") (EVar "rows"))))
(DTypeSig false "insertMethodResult" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact"))) (TyFun (TyCon "MethodResultFact") (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact"))))))
(DFunDef false "insertMethodResult" ((PVar "acc") (PVar "row")) (EBlock (DoLet false false (PVar "methods") (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "row") "iface")) (EVar "acc")))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "row") "iface")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "row") "method")) (EVar "row")) (EVar "methods"))) (EVar "acc")))))
(DTypeSig true "lookupMethodResult" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "MethodResultFact"))))))
(DFunDef false "lookupMethodResult" ((PVar "index") (PVar "iface") (PVar "method")) (EApp (EApp (EVar "$core.andThen") (EApp (EApp (EVar "omLookup") (EVar "iface")) (EMethodRef "index"))) (ELam ((PVar "methods")) (EApp (EApp (EVar "omLookup") (EVar "method")) (EVar "methods")))))
(DTypeSig false "isTopFn" (TyFun (TyCon "CBind") (TyCon "Bool")))
(DFunDef false "isTopFn" ((PCon "CBind" (PLit (LString "main")) PWild PWild PWild)) (EVar "False"))
(DFunDef false "isTopFn" ((PCon "CBind" PWild (PCons (PCon "CClause" (PCons PWild PWild) PWild) PWild) PWild PWild)) (EVar "True"))
(DFunDef false "isTopFn" (PWild) (EVar "False"))
(DTypeSig false "isCtorIn" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isCtorIn" ((PVar "ctors") (PVar "name")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "ctors")))
(DTypeSig false "ctorArityIn" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "ctorArityIn" ((PVar "ctors") (PVar "name")) (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "ctors"))))
(DTypeSig false "clausePair" (TyFun (TyCon "CClause") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "CExpr"))))
(DFunDef false "clausePair" ((PCon "CClause" (PVar "pats") (PVar "body"))) (ETuple (EVar "pats") (EVar "body")))
(DTypeSig false "clausesTrmc" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "SelfRef") (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyCon "Bool")))))
(DFunDef false "clausesTrmc" ((PVar "ctors") (PVar "self") (PVar "clauses")) (EBlock (DoLet false false (PVar "arity") (EApp (EVar "clauseArityOf") (EVar "clauses"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "arity") (ELit (LInt 0))) (EApp (EVar "dictUniformClauses") (EVar "clauses"))) (EApp (EApp (EApp (EApp (EApp (EVar "trmcEligible") (EApp (EVar "isCtorIn") (EVar "ctors"))) (EApp (EVar "ctorArityIn") (EVar "ctors"))) (EVar "self")) (EVar "arity")) (EApp (EApp (EMethodRef "map") (EVar "clausePair")) (EVar "clauses")))))))
(DTypeSig false "selfTrmcBind" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CBind") (TyCon "Bool"))))
(DFunDef false "selfTrmcBind" ((PVar "ctors") (PCon "CBind" (PVar "name") (PVar "clauses") PWild PWild)) (EApp (EApp (EApp (EVar "clausesTrmc") (EVar "ctors")) (EApp (EVar "SelfByVar") (EVar "name"))) (EVar "clauses")))
(DTypeSig false "implGroupKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "implGroupKey" ((PVar "method") (PVar "key")) (EBinOp "++" (EApp (EVar "lenKey") (EVar "method")) (EVar "key")))
(DTypeSig false "trmcImplKeys" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "List") (TyCon "ImplClauseGroup")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "trmcImplKeys" ((PVar "ctors") (PVar "impls") (PVar "groups")) (EBlock (DoLet false false (PVar "indexed") (EApp (EApp (EApp (EVar "indexImplEntries") (EVar "impls")) (ELit (LInt 0))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (ELam ((PVar "g")) (EApp (EApp (EVar "implGroupKey") (EFieldAccess (EAnnot (EVar "g") (TyCon "ImplClauseGroup")) "method")) (EFieldAccess (EAnnot (EVar "g") (TyCon "ImplClauseGroup")) "key")))) (EApp (EApp (EVar "filterList") (ELam ((PVar "g")) (EBlock (DoLet false false (PVar "clauses") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "i")) (EMatch (EApp (EApp (EVar "omLookup") (EApp (EVar "intToString") (EVar "i"))) (EVar "indexed")) (arm (PCon "Some" (PCon "CImplEntry" PWild PWild PWild (PVar "body"))) () (EListLit (EApp (EVar "snd") (EApp (EVar "implKeyClause") (EVar "body"))))) (arm (PCon "None") () (EListLit))))) (EFieldAccess (EAnnot (EVar "g") (TyCon "ImplClauseGroup")) "indices"))) (DoExpr (EApp (EApp (EApp (EVar "clausesTrmc") (EVar "ctors")) (EApp (EApp (EApp (EVar "methodSelf") (EFieldAccess (EAnnot (EVar "g") (TyCon "ImplClauseGroup")) "method")) (EFieldAccess (EAnnot (EVar "g") (TyCon "ImplClauseGroup")) "key")) (EApp (EVar "firstPats") (EVar "clauses")))) (EVar "clauses")))))) (EVar "groups")))) (EVar "omEmpty")))))
(DTypeSig false "indexImplEntries" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "OrdMap") (TyCon "CImplEntry")) (TyApp (TyCon "OrdMap") (TyCon "CImplEntry"))))))
(DFunDef false "indexImplEntries" ((PList) PWild (PVar "acc")) (EVar "acc"))
(DFunDef false "indexImplEntries" ((PCons (PVar "entry") (PVar "rest")) (PVar "i") (PVar "acc")) (EApp (EApp (EApp (EVar "indexImplEntries") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "intToString") (EVar "i"))) (EVar "entry")) (EVar "acc"))))
(DTypeSig false "implKeyClause" (TyFun (TyCon "CImplBody") (TyTuple (TyCon "String") (TyCon "CClause"))))
(DFunDef false "implKeyClause" ((PCon "CImplTagged" PWild (PVar "key") PWild PWild PWild (PVar "pats") (PVar "body"))) (ETuple (EVar "key") (EApp (EApp (EVar "CClause") (EVar "pats")) (EVar "body"))))
(DFunDef false "implKeyClause" ((PCon "CImplDefault" PWild PWild (PVar "key") PWild PWild (PVar "pats") (PVar "body"))) (ETuple (EVar "key") (EApp (EApp (EVar "CClause") (EVar "pats")) (EVar "body"))))
(DTypeSig false "firstPats" (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyApp (TyCon "List") (TyCon "Pat"))))
(DFunDef false "firstPats" ((PCons (PCon "CClause" (PVar "pats") PWild) PWild)) (EVar "pats"))
(DFunDef false "firstPats" ((PList)) (EListLit))
(DTypeSig false "planDispatchGroups" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyCon "List") (TyCon "DispGroup")))))))
(DFunDef false "planDispatchGroups" ((PVar "ctors") (PVar "fns") (PVar "groups") (PVar "impls")) (EBlock (DoLet false false (PVar "arities") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (ETuple (EApp (EVar "bindName") (EVar "b")) (EApp (EVar "bindArity") (EVar "b"))))) (EVar "fns")))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "detectDispatchGroups") (ELam ((PVar "n")) (EApp (EApp (EVar "canonFnIn") (EVar "arities")) (EVar "n")))) (ELam ((PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "arities")))) (ELam ((PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "arities")) (arm (PCon "Some" (PVar "a")) () (EVar "a")) (arm (PCon "None") () (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))))) (ELam ((PVar "nm") PWild (PVar "cs")) (EApp (EApp (EApp (EVar "clausesTrmc") (EVar "ctors")) (EApp (EVar "SelfByVar") (EVar "nm"))) (EVar "cs")))) (EVar "fns")) (EVar "groups")) (EVar "impls")))))
(DTypeSig false "bindArity" (TyFun (TyCon "CBind") (TyCon "Int")))
(DFunDef false "bindArity" ((PCon "CBind" PWild (PVar "clauses") PWild PWild)) (EApp (EVar "clauseArityOf") (EVar "clauses")))
(DTypeSig false "canonFnIn" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "canonFnIn" ((PVar "fns") (PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "fns")) (EVar "name") (EIf (EApp (EApp (EVar "omHasKey") (EApp (EApp (EVar "encodePair") (ELit (LString "core"))) (EVar "name"))) (EVar "fns")) (EApp (EApp (EVar "encodePair") (ELit (LString "core"))) (EVar "name")) (EVar "name"))))
(DTypeSig false "noDemand" (TyCon "WasmDemand"))
(DFunDef false "noDemand" () (ERecordCreate "WasmDemand" ((fa "uses" (EListLit)) (fa "refBox" (EVar "False")) (fa "divGuard" (EVar "False")) (fa "tupleArities" (EListLit)))))
(DData Private "DemandAcc" () ((variant "DemandAcc" (ConNamed (field "seenUses" (TyApp (TyCon "List") (TyCon "WasmUse"))) (field "seenKeys" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "seenJs" (TyApp (TyCon "OrdMap") (TyCon "JsImport"))) (field "seenRefBox" (TyCon "Bool")) (field "seenDivGuard" (TyCon "Bool")) (field "seenArities" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DData Private "DemandScope" () ((variant "DemandScope" (ConNamed (field "locals" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "topFns" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "topVals" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "jsBinds" (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))) (field "externFacts" (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")))))) ())
