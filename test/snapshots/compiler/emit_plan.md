# META
source_lines=256
stages=DESUGAR,MARK
# SOURCE
-- The per-emission plan: facts about the lowered program that both backends read
-- and neither recomputes.  Built once, right after lowering, from the program an
-- emitter is about to receive.

import frontend.ast.{Pat}
import ir.core_ir.{
  CProgram(..),
  CBind(..),
  CClause(..),
  CExpr,
  CImplEntry(..),
  CImplBody(..),
}
import backend.core_validate.{Backend(..), backendName}
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
-- `eagerReach` maps each binding to the value globals it eagerly reaches; the
-- value-global init order is sorted by it.
-- `trmc` says which functions are tail-recursive modulo constructor (TRMC-DESIGN.md).
-- `dispGroups` are the dispatch-graph TMC groups (WASMGC-TRMC-DESIGN.md §11): a
-- group's members are emitted as one destination-passing loop rooted at its root.
public export data EmitPlan = EmitPlan {
  target : Backend,
  wasmOnlyReach : Option ReachUnits,
  lazyGlobals : List String,
  eagerReach : OrdMap (List String),
  trmc : TrmcVerdicts,
  dispGroups : List DispGroup,
}

public export data ReachUnits = ReachUnits { total : Int, kept : Int }

-- The self-recursive TRMC verdict.  `eligibleFns` holds every top-level function, and
-- `eligibleImpls` every impl group (one `(method, key)` pair, its clauses in program
-- order), whose clauses `trmcEligible` accepts with a uniform count of leading
-- dictionary parameters.
--
-- The verdict is the same on both backends, and each realizes every eligible
-- function as a destination-passing loop.  What differs is only the cell a
-- constructor leaf links.  LLVM allocates every leaf through its constructor
-- tag.  Wasm picks the struct per function: the built-in list cell when the
-- leaves are `::` (`ctorTailIsCons`), the user constructor's struct otherwise.
-- A dispatch-group member is emitted by its group, not by this verdict.
--
-- A constructor is a name in the program's constructor table.  Wasm's own table
-- also answers for reserved and synthetic names the program may not declare
-- (`Some`, `Ok`, `Err`, `Cons`, `Tup<n>`).  None of them can head a leaf whose
-- last field is the self-call: `Some (f x)` returned by `f` would need
-- `Option T = T`, and the list and tuple cells lower to `::` and tuple nodes, not
-- applications.  So, for a typechecked program, the one table gives both backends
-- the verdict they computed.  Untyped input (the `wasm_emit_main` probe) can head
-- such a leaf, and there the plan's verdict is the narrower one.
public export data TrmcVerdicts = TrmcVerdicts {
  eligibleFns : OrdMap Unit,
  eligibleImpls : OrdMap Unit,
}

export
buildEmitPlan : Backend -> CProgram -> EmitPlan
buildEmitPlan target prog = planOver target None prog

-- The wasm modules entries' builder: reach first, then every plan field over the
-- reached program, which is also the program the emitter must receive.
export
buildEmitPlanReached : CProgram -> (EmitPlan, CProgram)
buildEmitPlanReached prog =
  let reached = wasmReachFilter prog
  let units = ReachUnits {
    total = programUnitCount prog,
    kept = programUnitCount reached,
  }
  (planOver WasmBackend (Some units) reached, reached)

programUnitCount : CProgram -> Int
programUnitCount (CProgram groups _ _ impls _ _) =
  listLen groups + listLen impls

planOver : Backend -> Option ReachUnits -> CProgram -> EmitPlan
planOver target reach (CProgram groups ctorArs _ impls _ _) =
  -- first entry wins on a repeated constructor name, as in both emitters' tables
  let ctors = omFromPairs (reverseL ctorArs) omEmpty
  let fns = filterList isTopFn groups
  EmitPlan {
    target = target,
    wasmOnlyReach = reach,
    lazyGlobals = lazyGlobalNames groups,
    eagerReach = eagerReachMap groups,
    trmc = TrmcVerdicts {
      eligibleFns =
        omFromNames
          (map bindName (filterList (b => selfTrmcBind ctors b) fns))
          omEmpty,
      eligibleImpls = trmcImplKeys ctors impls,
    },
    dispGroups = planDispatchGroups ctors fns groups impls,
  }

-- does the TRMC verdict hold for top-level function [name]?
export
isTrmcFn : TrmcVerdicts -> String -> Bool
isTrmcFn v name = omHasKey name v.eligibleFns

-- does the TRMC verdict hold for the impl group of [method] at instance [key]?
export
isTrmcImpl : TrmcVerdicts -> String -> String -> Bool
isTrmcImpl v method key = omHasKey (implGroupKey method key) v.eligibleImpls

-- Asserts that a plan was built for the calling emitter's own backend.
export
checkPlanBackend : Backend -> EmitPlan -> Unit
checkPlanBackend expected plan =
  if backendName plan.target == backendName expected then
    ()
  else
    panic
      "internal error: emit plan was built for the \{backendName plan.target} backend but the \{backendName expected} emitter received it"

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
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Pat" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" false) (mem "CImplEntry" true) (mem "CImplBody" true))))
(DUse false (UseGroup ("backend" "core_validate") ((mem "Backend" true) (mem "backendName" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omKeys" false) (mem "omFromNames" false) (mem "omFromPairs" false))))
(DUse false (UseGroup ("support" "util") ((mem "lenKey" false) (mem "reverseL" false) (mem "filterList" false) (mem "listLen" false))))
(DUse false (UseGroup ("backend" "wasm_reach") ((mem "wasmReachFilter" false))))
(DUse false (UseGroup ("backend" "emit_support") ((mem "eagerReachMap" false) (mem "lazyGlobalNames" false))))
(DUse false (UseGroup ("backend" "trmc_analysis") ((mem "SelfRef" true) (mem "DispGroup" false) (mem "trmcEligible" false) (mem "detectDispatchGroups" false) (mem "dictUniformClauses" false) (mem "methodSelf" false) (mem "clauseArityOf" false) (mem "bindName" false))))
(DData Public "EmitPlan" () ((variant "EmitPlan" (ConNamed (field "target" (TyCon "Backend")) (field "wasmOnlyReach" (TyApp (TyCon "Option") (TyCon "ReachUnits"))) (field "lazyGlobals" (TyApp (TyCon "List") (TyCon "String"))) (field "eagerReach" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "trmc" (TyCon "TrmcVerdicts")) (field "dispGroups" (TyApp (TyCon "List") (TyCon "DispGroup")))))) ())
(DData Public "ReachUnits" () ((variant "ReachUnits" (ConNamed (field "total" (TyCon "Int")) (field "kept" (TyCon "Int"))))) ())
(DData Public "TrmcVerdicts" () ((variant "TrmcVerdicts" (ConNamed (field "eligibleFns" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "eligibleImpls" (TyApp (TyCon "OrdMap") (TyCon "Unit")))))) ())
(DTypeSig true "buildEmitPlan" (TyFun (TyCon "Backend") (TyFun (TyCon "CProgram") (TyCon "EmitPlan"))))
(DFunDef false "buildEmitPlan" ((PVar "target") (PVar "prog")) (EApp (EApp (EApp (EVar "planOver") (EVar "target")) (EVar "None")) (EVar "prog")))
(DTypeSig true "buildEmitPlanReached" (TyFun (TyCon "CProgram") (TyTuple (TyCon "EmitPlan") (TyCon "CProgram"))))
(DFunDef false "buildEmitPlanReached" ((PVar "prog")) (EBlock (DoLet false false (PVar "reached") (EApp (EVar "wasmReachFilter") (EVar "prog"))) (DoLet false false (PVar "units") (ERecordCreate "ReachUnits" ((fa "total" (EApp (EVar "programUnitCount") (EVar "prog"))) (fa "kept" (EApp (EVar "programUnitCount") (EVar "reached")))))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "planOver") (EVar "WasmBackend")) (EApp (EVar "Some") (EVar "units"))) (EVar "reached")) (EVar "reached")))))
(DTypeSig false "programUnitCount" (TyFun (TyCon "CProgram") (TyCon "Int")))
(DFunDef false "programUnitCount" ((PCon "CProgram" (PVar "groups") PWild PWild (PVar "impls") PWild PWild)) (EBinOp "+" (EApp (EVar "listLen") (EVar "groups")) (EApp (EVar "listLen") (EVar "impls"))))
(DTypeSig false "planOver" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "Option") (TyCon "ReachUnits")) (TyFun (TyCon "CProgram") (TyCon "EmitPlan")))))
(DFunDef false "planOver" ((PVar "target") (PVar "reach") (PCon "CProgram" (PVar "groups") (PVar "ctorArs") PWild (PVar "impls") PWild PWild)) (EBlock (DoLet false false (PVar "ctors") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "ctorArs"))) (EVar "omEmpty"))) (DoLet false false (PVar "fns") (EApp (EApp (EVar "filterList") (EVar "isTopFn")) (EVar "groups"))) (DoExpr (ERecordCreate "EmitPlan" ((fa "target" (EVar "target")) (fa "wasmOnlyReach" (EVar "reach")) (fa "lazyGlobals" (EApp (EVar "lazyGlobalNames") (EVar "groups"))) (fa "eagerReach" (EApp (EVar "eagerReachMap") (EVar "groups"))) (fa "trmc" (ERecordCreate "TrmcVerdicts" ((fa "eligibleFns" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "bindName")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "selfTrmcBind") (EVar "ctors")) (EVar "b")))) (EVar "fns")))) (EVar "omEmpty"))) (fa "eligibleImpls" (EApp (EApp (EVar "trmcImplKeys") (EVar "ctors")) (EVar "impls")))))) (fa "dispGroups" (EApp (EApp (EApp (EApp (EVar "planDispatchGroups") (EVar "ctors")) (EVar "fns")) (EVar "groups")) (EVar "impls"))))))))
(DTypeSig true "isTrmcFn" (TyFun (TyCon "TrmcVerdicts") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isTrmcFn" ((PVar "v") (PVar "name")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "v") "eligibleFns")))
(DTypeSig true "isTrmcImpl" (TyFun (TyCon "TrmcVerdicts") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "isTrmcImpl" ((PVar "v") (PVar "method") (PVar "key")) (EApp (EApp (EVar "omHasKey") (EApp (EApp (EVar "implGroupKey") (EVar "method")) (EVar "key"))) (EFieldAccess (EVar "v") "eligibleImpls")))
(DTypeSig true "checkPlanBackend" (TyFun (TyCon "Backend") (TyFun (TyCon "EmitPlan") (TyCon "Unit"))))
(DFunDef false "checkPlanBackend" ((PVar "expected") (PVar "plan")) (EIf (EBinOp "==" (EApp (EVar "backendName") (EFieldAccess (EVar "plan") "target")) (EApp (EVar "backendName") (EVar "expected"))) (ELit LUnit) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: emit plan was built for the ")) (EApp (EVar "display") (EApp (EVar "backendName") (EFieldAccess (EVar "plan") "target")))) (ELit (LString " backend but the "))) (EApp (EVar "display") (EApp (EVar "backendName") (EVar "expected")))) (ELit (LString " emitter received it"))))))
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
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Pat" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" false) (mem "CImplEntry" true) (mem "CImplBody" true))))
(DUse false (UseGroup ("backend" "core_validate") ((mem "Backend" true) (mem "backendName" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omKeys" false) (mem "omFromNames" false) (mem "omFromPairs" false))))
(DUse false (UseGroup ("support" "util") ((mem "lenKey" false) (mem "reverseL" false) (mem "filterList" false) (mem "listLen" false))))
(DUse false (UseGroup ("backend" "wasm_reach") ((mem "wasmReachFilter" false))))
(DUse false (UseGroup ("backend" "emit_support") ((mem "eagerReachMap" false) (mem "lazyGlobalNames" false))))
(DUse false (UseGroup ("backend" "trmc_analysis") ((mem "SelfRef" true) (mem "DispGroup" false) (mem "trmcEligible" false) (mem "detectDispatchGroups" false) (mem "dictUniformClauses" false) (mem "methodSelf" false) (mem "clauseArityOf" false) (mem "bindName" false))))
(DData Public "EmitPlan" () ((variant "EmitPlan" (ConNamed (field "target" (TyCon "Backend")) (field "wasmOnlyReach" (TyApp (TyCon "Option") (TyCon "ReachUnits"))) (field "lazyGlobals" (TyApp (TyCon "List") (TyCon "String"))) (field "eagerReach" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "trmc" (TyCon "TrmcVerdicts")) (field "dispGroups" (TyApp (TyCon "List") (TyCon "DispGroup")))))) ())
(DData Public "ReachUnits" () ((variant "ReachUnits" (ConNamed (field "total" (TyCon "Int")) (field "kept" (TyCon "Int"))))) ())
(DData Public "TrmcVerdicts" () ((variant "TrmcVerdicts" (ConNamed (field "eligibleFns" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "eligibleImpls" (TyApp (TyCon "OrdMap") (TyCon "Unit")))))) ())
(DTypeSig true "buildEmitPlan" (TyFun (TyCon "Backend") (TyFun (TyCon "CProgram") (TyCon "EmitPlan"))))
(DFunDef false "buildEmitPlan" ((PVar "target") (PVar "prog")) (EApp (EApp (EApp (EVar "planOver") (EVar "target")) (EVar "None")) (EVar "prog")))
(DTypeSig true "buildEmitPlanReached" (TyFun (TyCon "CProgram") (TyTuple (TyCon "EmitPlan") (TyCon "CProgram"))))
(DFunDef false "buildEmitPlanReached" ((PVar "prog")) (EBlock (DoLet false false (PVar "reached") (EApp (EVar "wasmReachFilter") (EVar "prog"))) (DoLet false false (PVar "units") (ERecordCreate "ReachUnits" ((fa "total" (EApp (EVar "programUnitCount") (EVar "prog"))) (fa "kept" (EApp (EVar "programUnitCount") (EVar "reached")))))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "planOver") (EVar "WasmBackend")) (EApp (EVar "Some") (EVar "units"))) (EVar "reached")) (EVar "reached")))))
(DTypeSig false "programUnitCount" (TyFun (TyCon "CProgram") (TyCon "Int")))
(DFunDef false "programUnitCount" ((PCon "CProgram" (PVar "groups") PWild PWild (PVar "impls") PWild PWild)) (EBinOp "+" (EApp (EVar "listLen") (EVar "groups")) (EApp (EVar "listLen") (EVar "impls"))))
(DTypeSig false "planOver" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "Option") (TyCon "ReachUnits")) (TyFun (TyCon "CProgram") (TyCon "EmitPlan")))))
(DFunDef false "planOver" ((PVar "target") (PVar "reach") (PCon "CProgram" (PVar "groups") (PVar "ctorArs") PWild (PVar "impls") PWild PWild)) (EBlock (DoLet false false (PVar "ctors") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "ctorArs"))) (EVar "omEmpty"))) (DoLet false false (PVar "fns") (EApp (EApp (EVar "filterList") (EVar "isTopFn")) (EVar "groups"))) (DoExpr (ERecordCreate "EmitPlan" ((fa "target" (EVar "target")) (fa "wasmOnlyReach" (EVar "reach")) (fa "lazyGlobals" (EApp (EVar "lazyGlobalNames") (EVar "groups"))) (fa "eagerReach" (EApp (EVar "eagerReachMap") (EVar "groups"))) (fa "trmc" (ERecordCreate "TrmcVerdicts" ((fa "eligibleFns" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "bindName")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "selfTrmcBind") (EVar "ctors")) (EVar "b")))) (EVar "fns")))) (EVar "omEmpty"))) (fa "eligibleImpls" (EApp (EApp (EVar "trmcImplKeys") (EVar "ctors")) (EVar "impls")))))) (fa "dispGroups" (EApp (EApp (EApp (EApp (EVar "planDispatchGroups") (EVar "ctors")) (EVar "fns")) (EVar "groups")) (EVar "impls"))))))))
(DTypeSig true "isTrmcFn" (TyFun (TyCon "TrmcVerdicts") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isTrmcFn" ((PVar "v") (PVar "name")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "v") "eligibleFns")))
(DTypeSig true "isTrmcImpl" (TyFun (TyCon "TrmcVerdicts") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "Bool")))))
(DFunDef false "isTrmcImpl" ((PVar "v") (PVar "method") (PVar "key")) (EApp (EApp (EVar "omHasKey") (EApp (EApp (EVar "implGroupKey") (EVar "method")) (EVar "key"))) (EFieldAccess (EVar "v") "eligibleImpls")))
(DTypeSig true "checkPlanBackend" (TyFun (TyCon "Backend") (TyFun (TyCon "EmitPlan") (TyCon "Unit"))))
(DFunDef false "checkPlanBackend" ((PVar "expected") (PVar "plan")) (EIf (EBinOp "==" (EApp (EVar "backendName") (EFieldAccess (EVar "plan") "target")) (EApp (EVar "backendName") (EVar "expected"))) (ELit LUnit) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "internal error: emit plan was built for the ")) (EApp (EMethodRef "display") (EApp (EVar "backendName") (EFieldAccess (EVar "plan") "target")))) (ELit (LString " backend but the "))) (EApp (EMethodRef "display") (EApp (EVar "backendName") (EVar "expected")))) (ELit (LString " emitter received it"))))))
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
