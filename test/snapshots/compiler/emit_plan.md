# META
source_lines=383
stages=DESUGAR,MARK
# SOURCE
import backend.wasm_demand.{
  JsImport(..), WasmDemand(..), WasmDemandInputs(..), WasmDemandPlan,
  planWasmDemand, ctorFloatFieldIndex
}
import backend.wasm_names.{uniqueBinders}
-- The per-emission plan: facts about the lowered program that both backends read
-- and neither recomputes.  Built once, right after lowering, from the program an
-- emitter is about to receive.

import backend.extern_requirements.{
  ExternRequirements, planExterns, requirementHostRows
}
import backend.global_plan.{GlobalInitPlan, planGlobals}
import backend.emit_target.{Backend(..)}
import frontend.ast.{Lit(..), Pat(..), hostRows}
import ir.extern_types.{ExternDeclFact}
import ir.extern_lower.{externRuntimeKey, externHeadRows}
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
}
import backend.extern_catalog.{
  RuntimeExternDomain,
  WasmUse(..),
  fileBoundHostKeys,
  wasmHostKeys,
  wasmTupleArities,
  wasmUses,
}

import support.ordmap.{
  OrdMap,
  omEmpty,
  omInsert,
  omLookup,
  omHasKey,
  omKeys,
  omFromNames,
  omFromPairs,
}
import support.util.{lenKey, reverseL, filterList, listLen}
import backend.wasm_reach.{wasmReachFilter}
import backend.emit_support.{eagerReachMap, lazyGlobalNames}
import backend.trmc_analysis.{
  TrmcVerdicts(..),
  SelfRef(..),
  flattenApp,
  DispGroup,
  trmcEligible,
  detectDispatchGroups,
  dictUniformClauses,
  methodSelf,
  clauseArityOf,
  bindName,
  patVarsList,
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
-- Medaka-name order; the wasm emitter imports exactly these from `jsffi`.  All
-- three are empty on an LLVM plan.
public export data EmitPlan = EmitPlan {
  target : Backend,
  externRequirements : ExternRequirements,
  entryOutcome : Option EntryFact,
  methodResults : OrdMap (OrdMap MethodResultFact),
  wasmOnlyReach : Option ReachUnits,
  lazyGlobals : List String,
  eagerReach : OrdMap (List String),
  globalInit : GlobalInitPlan,
  trmc : TrmcVerdicts,
  dispGroups : List DispGroup,
  wasmDemand : WasmDemand,
  wasmInputs : WasmDemandInputs,
  wasmPhysical : Option WasmDemandPlan,
  hostKeys : List String,
  jsImports : List JsImport,
}

public export data ReachUnits = ReachUnits { total : Int, kept : Int }

export
buildEmitPlan : Backend -> RuntimeExternDomain -> CProgram -> EmitPlan
buildEmitPlan target domain prog = planOver target domain None omEmpty prog

-- The wasm modules entries' builder: reach first, then every plan field over the
-- reached program, which is also the program the emitter must receive. The
-- complete runtime domain is retained separately from the reached selection.
export
buildEmitPlanReached : RuntimeExternDomain ->
  OrdMap (List Int) ->
  CProgram ->
  (EmitPlan, CProgram)
buildEmitPlanReached domain ctorFields prog =
  let reached = wasmReachFilter prog
  let units = ReachUnits {
    total = programUnitCount prog,
    kept = programUnitCount reached,
  }
  let prepared = uniqueBinders reached
  (planOver WasmBackend domain (Some units) ctorFields prepared, prepared)

export
prepareWasmPlan : RuntimeExternDomain ->
  OrdMap (List Int) ->
  CProgram ->
  (EmitPlan, CProgram)
prepareWasmPlan domain ctorFields prog =
  let prepared = uniqueBinders prog
  (planOver WasmBackend domain None ctorFields prepared, prepared)

programUnitCount : CProgram -> Int
programUnitCount (CProgram groups _ _ impls _ _) =
  listLen groups + listLen impls

planOver : Backend ->
  RuntimeExternDomain ->
  Option ReachUnits ->
  OrdMap (List Int) ->
  CProgram ->
  EmitPlan
planOver target domain reach ctorFields prog =
  let (CProgram groups ctorArs _ impls _ facts) = prog
  -- first entry wins on a repeated constructor name, as in both emitters' tables
  let ctors = omFromPairs (reverseL ctorArs) omEmpty
  let fns = filterList isTopFn groups
  let requirements = planExterns target domain prog
  let lazy = lazyGlobalNames groups
  let eager = eagerReachMap groups
  let globalInit = planGlobals prog lazy eager
  let trmc = TrmcVerdicts {
    eligibleFns =
      omFromNames
        (map bindName (filterList (b => selfTrmcBind ctors b) fns))
        omEmpty,
    eligibleImpls = trmcImplKeys ctors impls,
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
    WasmBackend => Some (planWasmDemand inputs prog requirements)
    _ => None
  EmitPlan {
    target = target,
    externRequirements = requirements,
    entryOutcome = facts.factEntryOutcome,
    methodResults = indexMethodResults facts.factMethodResults,
    wasmOnlyReach = reach,
    lazyGlobals = lazy,
    eagerReach = eager,
    globalInit = globalInit,
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
lookupMethodResult index iface method = match omLookup iface index
  Some methods => omLookup method methods
  None => None

-- a function binding: it takes parameters, and it is not `main`
isTopFn : CBind -> Bool
isTopFn (CBind "main" _ _ _) = False
isTopFn (CBind _ ((CClause (_ :: _) _) :: _) _ _) = True
isTopFn _ = False

isCtorIn : OrdMap Int -> String -> Bool
isCtorIn ctors name = omHasKey name ctors

ctorArityIn : OrdMap Int -> String -> Int
ctorArityIn ctors name = match omLookup name ctors
  Some n => n
  None => 0

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
trmcImplKeys : OrdMap Int -> List CImplEntry -> OrdMap Unit
trmcImplKeys ctors impls =
  let grouped = groupImplClauses impls omEmpty
  omFromNames
    (filterList
      (k => match omLookup k grouped
        Some (method, key, revClauses) =>
          let clauses = reverseL revClauses
          clausesTrmc ctors (methodSelf method key (firstPats clauses)) clauses
        None => False)
      (omKeys grouped))
    omEmpty

-- each `(method, key)` group's clauses, newest first
groupImplClauses : List CImplEntry ->
  OrdMap (String, String, List CClause) ->
  OrdMap (String, String, List CClause)
groupImplClauses [] acc = acc
groupImplClauses ((CImplEntry method _ _ body) :: rest) acc =
  let (key, clause) = implKeyClause body
  let k = implGroupKey method key
  let prev = match omLookup k acc
    Some (_, _, cs) => cs
    None => []
  groupImplClauses rest (omInsert k (method, key, clause :: prev) acc)

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
  else if omHasKey ("core__" ++ name) fns then
    "core__" ++ name
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
(DUse false (UseGroup ("backend" "wasm_demand") ((mem "JsImport" true) (mem "WasmDemand" true) (mem "WasmDemandInputs" true) (mem "WasmDemandPlan" false) (mem "planWasmDemand" false) (mem "ctorFloatFieldIndex" false))))
(DUse false (UseGroup ("backend" "wasm_names") ((mem "uniqueBinders" false))))
(DUse false (UseGroup ("backend" "extern_requirements") ((mem "ExternRequirements" false) (mem "planExterns" false) (mem "requirementHostRows" false))))
(DUse false (UseGroup ("backend" "global_plan") ((mem "GlobalInitPlan" false) (mem "planGlobals" false))))
(DUse false (UseGroup ("backend" "emit_target") ((mem "Backend" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Pat" true) (mem "hostRows" false))))
(DUse false (UseGroup ("ir" "extern_types") ((mem "ExternDeclFact" false))))
(DUse false (UseGroup ("ir" "extern_lower") ((mem "externRuntimeKey" false) (mem "externHeadRows" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "EntryFact" true) (mem "MethodResultFact" true) (mem "CArm" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CField" true) (mem "CGuard" true) (mem "CHead" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CStmt" true) (mem "CTBranch" true) (mem "CTree" true))))
(DUse false (UseGroup ("backend" "extern_catalog") ((mem "RuntimeExternDomain" false) (mem "WasmUse" true) (mem "fileBoundHostKeys" false) (mem "wasmHostKeys" false) (mem "wasmTupleArities" false) (mem "wasmUses" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omKeys" false) (mem "omFromNames" false) (mem "omFromPairs" false))))
(DUse false (UseGroup ("support" "util") ((mem "lenKey" false) (mem "reverseL" false) (mem "filterList" false) (mem "listLen" false))))
(DUse false (UseGroup ("backend" "wasm_reach") ((mem "wasmReachFilter" false))))
(DUse false (UseGroup ("backend" "emit_support") ((mem "eagerReachMap" false) (mem "lazyGlobalNames" false))))
(DUse false (UseGroup ("backend" "trmc_analysis") ((mem "TrmcVerdicts" true) (mem "SelfRef" true) (mem "flattenApp" false) (mem "DispGroup" false) (mem "trmcEligible" false) (mem "detectDispatchGroups" false) (mem "dictUniformClauses" false) (mem "methodSelf" false) (mem "clauseArityOf" false) (mem "bindName" false) (mem "patVarsList" false))))
(DData Public "EmitPlan" () ((variant "EmitPlan" (ConNamed (field "target" (TyCon "Backend")) (field "externRequirements" (TyCon "ExternRequirements")) (field "entryOutcome" (TyApp (TyCon "Option") (TyCon "EntryFact"))) (field "methodResults" (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact")))) (field "wasmOnlyReach" (TyApp (TyCon "Option") (TyCon "ReachUnits"))) (field "lazyGlobals" (TyApp (TyCon "List") (TyCon "String"))) (field "eagerReach" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "globalInit" (TyCon "GlobalInitPlan")) (field "trmc" (TyCon "TrmcVerdicts")) (field "dispGroups" (TyApp (TyCon "List") (TyCon "DispGroup"))) (field "wasmDemand" (TyCon "WasmDemand")) (field "wasmInputs" (TyCon "WasmDemandInputs")) (field "wasmPhysical" (TyApp (TyCon "Option") (TyCon "WasmDemandPlan"))) (field "hostKeys" (TyApp (TyCon "List") (TyCon "String"))) (field "jsImports" (TyApp (TyCon "List") (TyCon "JsImport")))))) ())
(DData Public "ReachUnits" () ((variant "ReachUnits" (ConNamed (field "total" (TyCon "Int")) (field "kept" (TyCon "Int"))))) ())
(DTypeSig true "buildEmitPlan" (TyFun (TyCon "Backend") (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyCon "CProgram") (TyCon "EmitPlan")))))
(DFunDef false "buildEmitPlan" ((PVar "target") (PVar "domain") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "planOver") (EVar "target")) (EVar "domain")) (EVar "None")) (EVar "omEmpty")) (EVar "prog")))
(DTypeSig true "buildEmitPlanReached" (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "CProgram") (TyTuple (TyCon "EmitPlan") (TyCon "CProgram"))))))
(DFunDef false "buildEmitPlanReached" ((PVar "domain") (PVar "ctorFields") (PVar "prog")) (EBlock (DoLet false false (PVar "reached") (EApp (EVar "wasmReachFilter") (EVar "prog"))) (DoLet false false (PVar "units") (ERecordCreate "ReachUnits" ((fa "total" (EApp (EVar "programUnitCount") (EVar "prog"))) (fa "kept" (EApp (EVar "programUnitCount") (EVar "reached")))))) (DoLet false false (PVar "prepared") (EApp (EVar "uniqueBinders") (EVar "reached"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "planOver") (EVar "WasmBackend")) (EVar "domain")) (EApp (EVar "Some") (EVar "units"))) (EVar "ctorFields")) (EVar "prepared")) (EVar "prepared")))))
(DTypeSig true "prepareWasmPlan" (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "CProgram") (TyTuple (TyCon "EmitPlan") (TyCon "CProgram"))))))
(DFunDef false "prepareWasmPlan" ((PVar "domain") (PVar "ctorFields") (PVar "prog")) (EBlock (DoLet false false (PVar "prepared") (EApp (EVar "uniqueBinders") (EVar "prog"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "planOver") (EVar "WasmBackend")) (EVar "domain")) (EVar "None")) (EVar "ctorFields")) (EVar "prepared")) (EVar "prepared")))))
(DTypeSig false "programUnitCount" (TyFun (TyCon "CProgram") (TyCon "Int")))
(DFunDef false "programUnitCount" ((PCon "CProgram" (PVar "groups") PWild PWild (PVar "impls") PWild PWild)) (EBinOp "+" (EApp (EVar "listLen") (EVar "groups")) (EApp (EVar "listLen") (EVar "impls"))))
(DTypeSig false "planOver" (TyFun (TyCon "Backend") (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyApp (TyCon "Option") (TyCon "ReachUnits")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "CProgram") (TyCon "EmitPlan")))))))
(DFunDef false "planOver" ((PVar "target") (PVar "domain") (PVar "reach") (PVar "ctorFields") (PVar "prog")) (EBlock (DoLet false false (PCon "CProgram" (PVar "groups") (PVar "ctorArs") PWild (PVar "impls") PWild (PVar "facts")) (EVar "prog")) (DoLet false false (PVar "ctors") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "ctorArs"))) (EVar "omEmpty"))) (DoLet false false (PVar "fns") (EApp (EApp (EVar "filterList") (EVar "isTopFn")) (EVar "groups"))) (DoLet false false (PVar "requirements") (EApp (EApp (EApp (EVar "planExterns") (EVar "target")) (EVar "domain")) (EVar "prog"))) (DoLet false false (PVar "lazy") (EApp (EVar "lazyGlobalNames") (EVar "groups"))) (DoLet false false (PVar "eager") (EApp (EVar "eagerReachMap") (EVar "groups"))) (DoLet false false (PVar "globalInit") (EApp (EApp (EApp (EVar "planGlobals") (EVar "prog")) (EVar "lazy")) (EVar "eager"))) (DoLet false false (PVar "trmc") (ERecordCreate "TrmcVerdicts" ((fa "eligibleFns" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "bindName")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "selfTrmcBind") (EVar "ctors")) (EVar "b")))) (EVar "fns")))) (EVar "omEmpty"))) (fa "eligibleImpls" (EApp (EApp (EVar "trmcImplKeys") (EVar "ctors")) (EVar "impls")))))) (DoLet false false (PVar "dispatch") (EApp (EApp (EApp (EApp (EVar "planDispatchGroups") (EVar "ctors")) (EVar "fns")) (EVar "groups")) (EVar "impls"))) (DoLet false false (PVar "inputs") (ERecordCreate "WasmDemandInputs" ((fa "ctorFloatFields" (EVar "ctorFields")) (fa "lazyGlobals" (EVar "lazy")) (fa "globalInit" (EVar "globalInit")) (fa "trmcVerdicts" (EVar "trmc")) (fa "dispatchGroups" (EVar "dispatch"))))) (DoLet false false (PVar "physical") (EMatch (EVar "target") (arm (PCon "WasmBackend") () (EApp (EVar "Some") (EApp (EApp (EApp (EVar "planWasmDemand") (EVar "inputs")) (EVar "prog")) (EVar "requirements")))) (arm PWild () (EVar "None")))) (DoExpr (ERecordCreate "EmitPlan" ((fa "target" (EVar "target")) (fa "externRequirements" (EVar "requirements")) (fa "entryOutcome" (EFieldAccess (EVar "facts") "factEntryOutcome")) (fa "methodResults" (EApp (EVar "indexMethodResults") (EFieldAccess (EVar "facts") "factMethodResults"))) (fa "wasmOnlyReach" (EVar "reach")) (fa "lazyGlobals" (EVar "lazy")) (fa "eagerReach" (EVar "eager")) (fa "globalInit" (EVar "globalInit")) (fa "trmc" (EVar "trmc")) (fa "dispGroups" (EVar "dispatch")) (fa "wasmDemand" (EMatch (EVar "physical") (arm (PCon "Some" (PVar "p")) () (EFieldAccess (EVar "p") "sourceDemand")) (arm (PCon "None") () (EVar "noDemand")))) (fa "wasmInputs" (EVar "inputs")) (fa "wasmPhysical" (EVar "physical")) (fa "hostKeys" (EMatch (EVar "physical") (arm (PCon "Some" (PVar "p")) () (EFieldAccess (EVar "p") "sourceHostKeys")) (arm (PCon "None") () (EListLit)))) (fa "jsImports" (EMatch (EVar "physical") (arm (PCon "Some" (PVar "p")) () (EFieldAccess (EVar "p") "jsImports")) (arm (PCon "None") () (EListLit)))))))))
(DTypeSig true "planEntryMainIsUnit" (TyFun (TyCon "EmitPlan") (TyCon "Bool")))
(DFunDef false "planEntryMainIsUnit" ((PVar "plan")) (EMatch (EFieldAccess (EVar "plan") "entryOutcome") (arm (PCon "Some" (PVar "outcome")) () (EFieldAccess (EVar "outcome") "entryMainIsUnit")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "planEntryMainIsFloat" (TyFun (TyCon "EmitPlan") (TyCon "Bool")))
(DFunDef false "planEntryMainIsFloat" ((PVar "plan")) (EMatch (EFieldAccess (EVar "plan") "entryOutcome") (arm (PCon "Some" (PVar "outcome")) () (EFieldAccess (EVar "outcome") "entryMainIsFloat")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "indexMethodResults" (TyFun (TyApp (TyCon "List") (TyCon "MethodResultFact")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact")))))
(DFunDef false "indexMethodResults" ((PVar "rows")) (EApp (EApp (EApp (EVar "fold") (EVar "insertMethodResult")) (EVar "omEmpty")) (EApp (EVar "reverseL") (EVar "rows"))))
(DTypeSig false "insertMethodResult" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact"))) (TyFun (TyCon "MethodResultFact") (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact"))))))
(DFunDef false "insertMethodResult" ((PVar "acc") (PVar "row")) (EBlock (DoLet false false (PVar "methods") (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "row") "iface")) (EVar "acc")))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "row") "iface")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "row") "method")) (EVar "row")) (EVar "methods"))) (EVar "acc")))))
(DTypeSig true "lookupMethodResult" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "MethodResultFact"))))))
(DFunDef false "lookupMethodResult" ((PVar "index") (PVar "iface") (PVar "method")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "iface")) (EVar "index")) (arm (PCon "Some" (PVar "methods")) () (EApp (EApp (EVar "omLookup") (EVar "method")) (EVar "methods"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "isTopFn" (TyFun (TyCon "CBind") (TyCon "Bool")))
(DFunDef false "isTopFn" ((PCon "CBind" (PLit (LString "main")) PWild PWild PWild)) (EVar "False"))
(DFunDef false "isTopFn" ((PCon "CBind" PWild (PCons (PCon "CClause" (PCons PWild PWild) PWild) PWild) PWild PWild)) (EVar "True"))
(DFunDef false "isTopFn" (PWild) (EVar "False"))
(DTypeSig false "isCtorIn" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isCtorIn" ((PVar "ctors") (PVar "name")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "ctors")))
(DTypeSig false "ctorArityIn" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "ctorArityIn" ((PVar "ctors") (PVar "name")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "ctors")) (arm (PCon "Some" (PVar "n")) () (EVar "n")) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig false "clausePair" (TyFun (TyCon "CClause") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "CExpr"))))
(DFunDef false "clausePair" ((PCon "CClause" (PVar "pats") (PVar "body"))) (ETuple (EVar "pats") (EVar "body")))
(DTypeSig false "clausesTrmc" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "SelfRef") (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyCon "Bool")))))
(DFunDef false "clausesTrmc" ((PVar "ctors") (PVar "self") (PVar "clauses")) (EBlock (DoLet false false (PVar "arity") (EApp (EVar "clauseArityOf") (EVar "clauses"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "arity") (ELit (LInt 0))) (EApp (EVar "dictUniformClauses") (EVar "clauses"))) (EApp (EApp (EApp (EApp (EApp (EVar "trmcEligible") (EApp (EVar "isCtorIn") (EVar "ctors"))) (EApp (EVar "ctorArityIn") (EVar "ctors"))) (EVar "self")) (EVar "arity")) (EApp (EApp (EVar "map") (EVar "clausePair")) (EVar "clauses")))))))
(DTypeSig false "selfTrmcBind" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CBind") (TyCon "Bool"))))
(DFunDef false "selfTrmcBind" ((PVar "ctors") (PCon "CBind" (PVar "name") (PVar "clauses") PWild PWild)) (EApp (EApp (EApp (EVar "clausesTrmc") (EVar "ctors")) (EApp (EVar "SelfByVar") (EVar "name"))) (EVar "clauses")))
(DTypeSig false "implGroupKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "implGroupKey" ((PVar "method") (PVar "key")) (EBinOp "++" (EApp (EVar "lenKey") (EVar "method")) (EVar "key")))
(DTypeSig false "trmcImplKeys" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "trmcImplKeys" ((PVar "ctors") (PVar "impls")) (EBlock (DoLet false false (PVar "grouped") (EApp (EApp (EVar "groupImplClauses") (EVar "impls")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterList") (ELam ((PVar "k")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "grouped")) (arm (PCon "Some" (PTuple (PVar "method") (PVar "key") (PVar "revClauses"))) () (EBlock (DoLet false false (PVar "clauses") (EApp (EVar "reverseL") (EVar "revClauses"))) (DoExpr (EApp (EApp (EApp (EVar "clausesTrmc") (EVar "ctors")) (EApp (EApp (EApp (EVar "methodSelf") (EVar "method")) (EVar "key")) (EApp (EVar "firstPats") (EVar "clauses")))) (EVar "clauses"))))) (arm (PCon "None") () (EVar "False"))))) (EApp (EVar "omKeys") (EVar "grouped")))) (EVar "omEmpty")))))
(DTypeSig false "groupImplClauses" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "CClause")))) (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "CClause")))))))
(DFunDef false "groupImplClauses" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "groupImplClauses" ((PCons (PCon "CImplEntry" (PVar "method") PWild PWild (PVar "body")) (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PTuple (PVar "key") (PVar "clause")) (EApp (EVar "implKeyClause") (EVar "body"))) (DoLet false false (PVar "k") (EApp (EApp (EVar "implGroupKey") (EVar "method")) (EVar "key"))) (DoLet false false (PVar "prev") (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "acc")) (arm (PCon "Some" (PTuple PWild PWild (PVar "cs"))) () (EVar "cs")) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EVar "groupImplClauses") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (ETuple (EVar "method") (EVar "key") (EBinOp "::" (EVar "clause") (EVar "prev")))) (EVar "acc"))))))
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
(DFunDef false "canonFnIn" ((PVar "fns") (PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "fns")) (EVar "name") (EIf (EApp (EApp (EVar "omHasKey") (EBinOp "++" (ELit (LString "core__")) (EVar "name"))) (EVar "fns")) (EBinOp "++" (ELit (LString "core__")) (EVar "name")) (EVar "name"))))
(DTypeSig false "noDemand" (TyCon "WasmDemand"))
(DFunDef false "noDemand" () (ERecordCreate "WasmDemand" ((fa "uses" (EListLit)) (fa "refBox" (EVar "False")) (fa "divGuard" (EVar "False")) (fa "tupleArities" (EListLit)))))
(DData Private "DemandAcc" () ((variant "DemandAcc" (ConNamed (field "seenUses" (TyApp (TyCon "List") (TyCon "WasmUse"))) (field "seenKeys" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "seenJs" (TyApp (TyCon "OrdMap") (TyCon "JsImport"))) (field "seenRefBox" (TyCon "Bool")) (field "seenDivGuard" (TyCon "Bool")) (field "seenArities" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DData Private "DemandScope" () ((variant "DemandScope" (ConNamed (field "locals" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "topFns" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "topVals" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "jsBinds" (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))) (field "externFacts" (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")))))) ())
# MARK
(DUse false (UseGroup ("backend" "wasm_demand") ((mem "JsImport" true) (mem "WasmDemand" true) (mem "WasmDemandInputs" true) (mem "WasmDemandPlan" false) (mem "planWasmDemand" false) (mem "ctorFloatFieldIndex" false))))
(DUse false (UseGroup ("backend" "wasm_names") ((mem "uniqueBinders" false))))
(DUse false (UseGroup ("backend" "extern_requirements") ((mem "ExternRequirements" false) (mem "planExterns" false) (mem "requirementHostRows" false))))
(DUse false (UseGroup ("backend" "global_plan") ((mem "GlobalInitPlan" false) (mem "planGlobals" false))))
(DUse false (UseGroup ("backend" "emit_target") ((mem "Backend" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Pat" true) (mem "hostRows" false))))
(DUse false (UseGroup ("ir" "extern_types") ((mem "ExternDeclFact" false))))
(DUse false (UseGroup ("ir" "extern_lower") ((mem "externRuntimeKey" false) (mem "externHeadRows" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "EntryFact" true) (mem "MethodResultFact" true) (mem "CArm" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CField" true) (mem "CGuard" true) (mem "CHead" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CStmt" true) (mem "CTBranch" true) (mem "CTree" true))))
(DUse false (UseGroup ("backend" "extern_catalog") ((mem "RuntimeExternDomain" false) (mem "WasmUse" true) (mem "fileBoundHostKeys" false) (mem "wasmHostKeys" false) (mem "wasmTupleArities" false) (mem "wasmUses" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omKeys" false) (mem "omFromNames" false) (mem "omFromPairs" false))))
(DUse false (UseGroup ("support" "util") ((mem "lenKey" false) (mem "reverseL" false) (mem "filterList" false) (mem "listLen" false))))
(DUse false (UseGroup ("backend" "wasm_reach") ((mem "wasmReachFilter" false))))
(DUse false (UseGroup ("backend" "emit_support") ((mem "eagerReachMap" false) (mem "lazyGlobalNames" false))))
(DUse false (UseGroup ("backend" "trmc_analysis") ((mem "TrmcVerdicts" true) (mem "SelfRef" true) (mem "flattenApp" false) (mem "DispGroup" false) (mem "trmcEligible" false) (mem "detectDispatchGroups" false) (mem "dictUniformClauses" false) (mem "methodSelf" false) (mem "clauseArityOf" false) (mem "bindName" false) (mem "patVarsList" false))))
(DData Public "EmitPlan" () ((variant "EmitPlan" (ConNamed (field "target" (TyCon "Backend")) (field "externRequirements" (TyCon "ExternRequirements")) (field "entryOutcome" (TyApp (TyCon "Option") (TyCon "EntryFact"))) (field "methodResults" (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact")))) (field "wasmOnlyReach" (TyApp (TyCon "Option") (TyCon "ReachUnits"))) (field "lazyGlobals" (TyApp (TyCon "List") (TyCon "String"))) (field "eagerReach" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "globalInit" (TyCon "GlobalInitPlan")) (field "trmc" (TyCon "TrmcVerdicts")) (field "dispGroups" (TyApp (TyCon "List") (TyCon "DispGroup"))) (field "wasmDemand" (TyCon "WasmDemand")) (field "wasmInputs" (TyCon "WasmDemandInputs")) (field "wasmPhysical" (TyApp (TyCon "Option") (TyCon "WasmDemandPlan"))) (field "hostKeys" (TyApp (TyCon "List") (TyCon "String"))) (field "jsImports" (TyApp (TyCon "List") (TyCon "JsImport")))))) ())
(DData Public "ReachUnits" () ((variant "ReachUnits" (ConNamed (field "total" (TyCon "Int")) (field "kept" (TyCon "Int"))))) ())
(DTypeSig true "buildEmitPlan" (TyFun (TyCon "Backend") (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyCon "CProgram") (TyCon "EmitPlan")))))
(DFunDef false "buildEmitPlan" ((PVar "target") (PVar "domain") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "planOver") (EVar "target")) (EVar "domain")) (EVar "None")) (EVar "omEmpty")) (EVar "prog")))
(DTypeSig true "buildEmitPlanReached" (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "CProgram") (TyTuple (TyCon "EmitPlan") (TyCon "CProgram"))))))
(DFunDef false "buildEmitPlanReached" ((PVar "domain") (PVar "ctorFields") (PVar "prog")) (EBlock (DoLet false false (PVar "reached") (EApp (EVar "wasmReachFilter") (EVar "prog"))) (DoLet false false (PVar "units") (ERecordCreate "ReachUnits" ((fa "total" (EApp (EVar "programUnitCount") (EVar "prog"))) (fa "kept" (EApp (EVar "programUnitCount") (EVar "reached")))))) (DoLet false false (PVar "prepared") (EApp (EVar "uniqueBinders") (EVar "reached"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "planOver") (EVar "WasmBackend")) (EVar "domain")) (EApp (EVar "Some") (EVar "units"))) (EVar "ctorFields")) (EVar "prepared")) (EVar "prepared")))))
(DTypeSig true "prepareWasmPlan" (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "CProgram") (TyTuple (TyCon "EmitPlan") (TyCon "CProgram"))))))
(DFunDef false "prepareWasmPlan" ((PVar "domain") (PVar "ctorFields") (PVar "prog")) (EBlock (DoLet false false (PVar "prepared") (EApp (EVar "uniqueBinders") (EVar "prog"))) (DoExpr (ETuple (EApp (EApp (EApp (EApp (EApp (EVar "planOver") (EVar "WasmBackend")) (EVar "domain")) (EVar "None")) (EVar "ctorFields")) (EVar "prepared")) (EVar "prepared")))))
(DTypeSig false "programUnitCount" (TyFun (TyCon "CProgram") (TyCon "Int")))
(DFunDef false "programUnitCount" ((PCon "CProgram" (PVar "groups") PWild PWild (PVar "impls") PWild PWild)) (EBinOp "+" (EApp (EVar "listLen") (EVar "groups")) (EApp (EVar "listLen") (EVar "impls"))))
(DTypeSig false "planOver" (TyFun (TyCon "Backend") (TyFun (TyCon "RuntimeExternDomain") (TyFun (TyApp (TyCon "Option") (TyCon "ReachUnits")) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "CProgram") (TyCon "EmitPlan")))))))
(DFunDef false "planOver" ((PVar "target") (PVar "domain") (PVar "reach") (PVar "ctorFields") (PVar "prog")) (EBlock (DoLet false false (PCon "CProgram" (PVar "groups") (PVar "ctorArs") PWild (PVar "impls") PWild (PVar "facts")) (EVar "prog")) (DoLet false false (PVar "ctors") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "ctorArs"))) (EVar "omEmpty"))) (DoLet false false (PVar "fns") (EApp (EApp (EVar "filterList") (EVar "isTopFn")) (EVar "groups"))) (DoLet false false (PVar "requirements") (EApp (EApp (EApp (EVar "planExterns") (EVar "target")) (EVar "domain")) (EVar "prog"))) (DoLet false false (PVar "lazy") (EApp (EVar "lazyGlobalNames") (EVar "groups"))) (DoLet false false (PVar "eager") (EApp (EVar "eagerReachMap") (EVar "groups"))) (DoLet false false (PVar "globalInit") (EApp (EApp (EApp (EVar "planGlobals") (EVar "prog")) (EVar "lazy")) (EVar "eager"))) (DoLet false false (PVar "trmc") (ERecordCreate "TrmcVerdicts" ((fa "eligibleFns" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "bindName")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "selfTrmcBind") (EVar "ctors")) (EVar "b")))) (EVar "fns")))) (EVar "omEmpty"))) (fa "eligibleImpls" (EApp (EApp (EVar "trmcImplKeys") (EVar "ctors")) (EVar "impls")))))) (DoLet false false (PVar "dispatch") (EApp (EApp (EApp (EApp (EVar "planDispatchGroups") (EVar "ctors")) (EVar "fns")) (EVar "groups")) (EVar "impls"))) (DoLet false false (PVar "inputs") (ERecordCreate "WasmDemandInputs" ((fa "ctorFloatFields" (EVar "ctorFields")) (fa "lazyGlobals" (EVar "lazy")) (fa "globalInit" (EVar "globalInit")) (fa "trmcVerdicts" (EVar "trmc")) (fa "dispatchGroups" (EVar "dispatch"))))) (DoLet false false (PVar "physical") (EMatch (EVar "target") (arm (PCon "WasmBackend") () (EApp (EVar "Some") (EApp (EApp (EApp (EVar "planWasmDemand") (EVar "inputs")) (EVar "prog")) (EVar "requirements")))) (arm PWild () (EVar "None")))) (DoExpr (ERecordCreate "EmitPlan" ((fa "target" (EVar "target")) (fa "externRequirements" (EVar "requirements")) (fa "entryOutcome" (EFieldAccess (EVar "facts") "factEntryOutcome")) (fa "methodResults" (EApp (EVar "indexMethodResults") (EFieldAccess (EVar "facts") "factMethodResults"))) (fa "wasmOnlyReach" (EVar "reach")) (fa "lazyGlobals" (EVar "lazy")) (fa "eagerReach" (EVar "eager")) (fa "globalInit" (EVar "globalInit")) (fa "trmc" (EVar "trmc")) (fa "dispGroups" (EVar "dispatch")) (fa "wasmDemand" (EMatch (EVar "physical") (arm (PCon "Some" (PVar "p")) () (EFieldAccess (EVar "p") "sourceDemand")) (arm (PCon "None") () (EVar "noDemand")))) (fa "wasmInputs" (EVar "inputs")) (fa "wasmPhysical" (EVar "physical")) (fa "hostKeys" (EMatch (EVar "physical") (arm (PCon "Some" (PVar "p")) () (EFieldAccess (EVar "p") "sourceHostKeys")) (arm (PCon "None") () (EListLit)))) (fa "jsImports" (EMatch (EVar "physical") (arm (PCon "Some" (PVar "p")) () (EFieldAccess (EVar "p") "jsImports")) (arm (PCon "None") () (EListLit)))))))))
(DTypeSig true "planEntryMainIsUnit" (TyFun (TyCon "EmitPlan") (TyCon "Bool")))
(DFunDef false "planEntryMainIsUnit" ((PVar "plan")) (EMatch (EFieldAccess (EVar "plan") "entryOutcome") (arm (PCon "Some" (PVar "outcome")) () (EFieldAccess (EVar "outcome") "entryMainIsUnit")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "planEntryMainIsFloat" (TyFun (TyCon "EmitPlan") (TyCon "Bool")))
(DFunDef false "planEntryMainIsFloat" ((PVar "plan")) (EMatch (EFieldAccess (EVar "plan") "entryOutcome") (arm (PCon "Some" (PVar "outcome")) () (EFieldAccess (EVar "outcome") "entryMainIsFloat")) (arm (PCon "None") () (EVar "False"))))
(DTypeSig true "indexMethodResults" (TyFun (TyApp (TyCon "List") (TyCon "MethodResultFact")) (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact")))))
(DFunDef false "indexMethodResults" ((PVar "rows")) (EApp (EApp (EApp (EMethodRef "fold") (EVar "insertMethodResult")) (EVar "omEmpty")) (EApp (EVar "reverseL") (EVar "rows"))))
(DTypeSig false "insertMethodResult" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact"))) (TyFun (TyCon "MethodResultFact") (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact"))))))
(DFunDef false "insertMethodResult" ((PVar "acc") (PVar "row")) (EBlock (DoLet false false (PVar "methods") (EApp (EApp (EVar "optionOr") (EVar "omEmpty")) (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "row") "iface")) (EVar "acc")))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "row") "iface")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "row") "method")) (EVar "row")) (EVar "methods"))) (EVar "acc")))))
(DTypeSig true "lookupMethodResult" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "OrdMap") (TyCon "MethodResultFact"))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "MethodResultFact"))))))
(DFunDef false "lookupMethodResult" ((PVar "index") (PVar "iface") (PVar "method")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "iface")) (EMethodRef "index")) (arm (PCon "Some" (PVar "methods")) () (EApp (EApp (EVar "omLookup") (EVar "method")) (EVar "methods"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "isTopFn" (TyFun (TyCon "CBind") (TyCon "Bool")))
(DFunDef false "isTopFn" ((PCon "CBind" (PLit (LString "main")) PWild PWild PWild)) (EVar "False"))
(DFunDef false "isTopFn" ((PCon "CBind" PWild (PCons (PCon "CClause" (PCons PWild PWild) PWild) PWild) PWild PWild)) (EVar "True"))
(DFunDef false "isTopFn" (PWild) (EVar "False"))
(DTypeSig false "isCtorIn" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isCtorIn" ((PVar "ctors") (PVar "name")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "ctors")))
(DTypeSig false "ctorArityIn" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyCon "Int"))))
(DFunDef false "ctorArityIn" ((PVar "ctors") (PVar "name")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EVar "ctors")) (arm (PCon "Some" (PVar "n")) () (EVar "n")) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig false "clausePair" (TyFun (TyCon "CClause") (TyTuple (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "CExpr"))))
(DFunDef false "clausePair" ((PCon "CClause" (PVar "pats") (PVar "body"))) (ETuple (EVar "pats") (EVar "body")))
(DTypeSig false "clausesTrmc" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "SelfRef") (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyCon "Bool")))))
(DFunDef false "clausesTrmc" ((PVar "ctors") (PVar "self") (PVar "clauses")) (EBlock (DoLet false false (PVar "arity") (EApp (EVar "clauseArityOf") (EVar "clauses"))) (DoExpr (EBinOp "&&" (EBinOp "&&" (EBinOp ">" (EVar "arity") (ELit (LInt 0))) (EApp (EVar "dictUniformClauses") (EVar "clauses"))) (EApp (EApp (EApp (EApp (EApp (EVar "trmcEligible") (EApp (EVar "isCtorIn") (EVar "ctors"))) (EApp (EVar "ctorArityIn") (EVar "ctors"))) (EVar "self")) (EVar "arity")) (EApp (EApp (EMethodRef "map") (EVar "clausePair")) (EVar "clauses")))))))
(DTypeSig false "selfTrmcBind" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "CBind") (TyCon "Bool"))))
(DFunDef false "selfTrmcBind" ((PVar "ctors") (PCon "CBind" (PVar "name") (PVar "clauses") PWild PWild)) (EApp (EApp (EApp (EVar "clausesTrmc") (EVar "ctors")) (EApp (EVar "SelfByVar") (EVar "name"))) (EVar "clauses")))
(DTypeSig false "implGroupKey" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "implGroupKey" ((PVar "method") (PVar "key")) (EBinOp "++" (EApp (EVar "lenKey") (EVar "method")) (EVar "key")))
(DTypeSig false "trmcImplKeys" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "trmcImplKeys" ((PVar "ctors") (PVar "impls")) (EBlock (DoLet false false (PVar "grouped") (EApp (EApp (EVar "groupImplClauses") (EVar "impls")) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "filterList") (ELam ((PVar "k")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "grouped")) (arm (PCon "Some" (PTuple (PVar "method") (PVar "key") (PVar "revClauses"))) () (EBlock (DoLet false false (PVar "clauses") (EApp (EVar "reverseL") (EVar "revClauses"))) (DoExpr (EApp (EApp (EApp (EVar "clausesTrmc") (EVar "ctors")) (EApp (EApp (EApp (EVar "methodSelf") (EVar "method")) (EVar "key")) (EApp (EVar "firstPats") (EVar "clauses")))) (EVar "clauses"))))) (arm (PCon "None") () (EVar "False"))))) (EApp (EVar "omKeys") (EVar "grouped")))) (EVar "omEmpty")))))
(DTypeSig false "groupImplClauses" (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "CClause")))) (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "CClause")))))))
(DFunDef false "groupImplClauses" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "groupImplClauses" ((PCons (PCon "CImplEntry" (PVar "method") PWild PWild (PVar "body")) (PVar "rest")) (PVar "acc")) (EBlock (DoLet false false (PTuple (PVar "key") (PVar "clause")) (EApp (EVar "implKeyClause") (EVar "body"))) (DoLet false false (PVar "k") (EApp (EApp (EVar "implGroupKey") (EVar "method")) (EVar "key"))) (DoLet false false (PVar "prev") (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EVar "acc")) (arm (PCon "Some" (PTuple PWild PWild (PVar "cs"))) () (EVar "cs")) (arm (PCon "None") () (EListLit)))) (DoExpr (EApp (EApp (EVar "groupImplClauses") (EVar "rest")) (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (ETuple (EVar "method") (EVar "key") (EBinOp "::" (EVar "clause") (EVar "prev")))) (EVar "acc"))))))
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
(DFunDef false "canonFnIn" ((PVar "fns") (PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "fns")) (EVar "name") (EIf (EApp (EApp (EVar "omHasKey") (EBinOp "++" (ELit (LString "core__")) (EVar "name"))) (EVar "fns")) (EBinOp "++" (ELit (LString "core__")) (EVar "name")) (EVar "name"))))
(DTypeSig false "noDemand" (TyCon "WasmDemand"))
(DFunDef false "noDemand" () (ERecordCreate "WasmDemand" ((fa "uses" (EListLit)) (fa "refBox" (EVar "False")) (fa "divGuard" (EVar "False")) (fa "tupleArities" (EListLit)))))
(DData Private "DemandAcc" () ((variant "DemandAcc" (ConNamed (field "seenUses" (TyApp (TyCon "List") (TyCon "WasmUse"))) (field "seenKeys" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "seenJs" (TyApp (TyCon "OrdMap") (TyCon "JsImport"))) (field "seenRefBox" (TyCon "Bool")) (field "seenDivGuard" (TyCon "Bool")) (field "seenArities" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DData Private "DemandScope" () ((variant "DemandScope" (ConNamed (field "locals" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "topFns" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "topVals" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "jsBinds" (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))) (field "externFacts" (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")))))) ())
