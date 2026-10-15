# META
source_lines=494
stages=DESUGAR,MARK
# SOURCE
-- The per-emission plan: facts about the lowered program that both backends read
-- and neither recomputes.  Built once, right after lowering, from the program an
-- emitter is about to receive.

import frontend.ast.{Lit(..), Pat(..)}
import ir.core_ir.{
  CProgram(..),
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
  WasmUse(..),
  fileBoundHostKeys,
  wasmHostKeys,
  wasmTupleArities,
  wasmUses,
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
  flattenApp,
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
-- `wasmDemand` is what the program demands of a WasmGC module, and `hostKeys` the
-- `env` host imports its externs' wasm lowerings call (`wasmHostKeys`), sorted
-- and distinct; the wasm emitter declares exactly these imports.  Both are empty
-- on an LLVM plan.
public export data EmitPlan = EmitPlan {
  target : Backend,
  wasmOnlyReach : Option ReachUnits,
  lazyGlobals : List String,
  eagerReach : OrdMap (List String),
  trmc : TrmcVerdicts,
  dispGroups : List DispGroup,
  wasmDemand : WasmDemand,
  hostKeys : List String,
}

public export data ReachUnits = ReachUnits { total : Int, kept : Int }

-- One walk of every binding and impl body (`wasmDemandOf`).  `uses` holds, once
-- each, the catalog demands (`wasmUses`) of every runtime extern the program
-- names and the demands its literals, collection forms and `++`/`::` make.
-- `refBox` is a `Ref` cell, `divGuard` a `/` or `%`, and `tupleArities` the
-- distinct tuple arities, first seen first.  The walk keys on names alone: it
-- does not track binders, so a local that shares an extern's name demands what
-- the extern does.
public export data WasmDemand = WasmDemand {
  uses : List WasmUse,
  refBox : Bool,
  divGuard : Bool,
  tupleArities : List Int,
}

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
  let (demand, keys) = match target
    WasmBackend => wasmDemandOf groups impls
    LlvmBackend => (noDemand, [])
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
    wasmDemand = demand,
    hostKeys = keys,
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

-- ── the wasm demand walk ────────────────────────────────────────────────────

noDemand : WasmDemand
noDemand = WasmDemand {
  uses = [],
  refBox = False,
  divGuard = False,
  tupleArities = [],
}

-- the walk's state: the demand so far, newest first, and the host keys seen
data DemandAcc = DemandAcc {
  seenUses : List WasmUse,
  seenKeys : OrdMap Unit,
  seenRefBox : Bool,
  seenDivGuard : Bool,
  seenArities : List Int,
}

wasmDemandOf : List CBind -> List CImplEntry -> (WasmDemand, List String)
wasmDemandOf groups impls =
  let start = DemandAcc {
    seenUses = [],
    seenKeys = omEmpty,
    seenRefBox = False,
    seenDivGuard = False,
    seenArities = [],
  }
  let acc = walkEach dImpl (walkEach dBind start groups) impls
  (
    WasmDemand {
      uses = reverseL acc.seenUses,
      refBox = acc.seenRefBox,
      divGuard = acc.seenDivGuard,
      tupleArities = reverseL acc.seenArities,
    },
    omKeys acc.seenKeys,
  )

walkEach : (DemandAcc -> a -> DemandAcc) -> DemandAcc -> List a -> DemandAcc
walkEach _ acc [] = acc
walkEach f acc (x :: xs) = walkEach f (f acc x) xs

-- `seenUses` holds at most one entry per `WasmUse` constructor, so the scan is
-- bounded.
noteUse : DemandAcc -> WasmUse -> DemandAcc
noteUse acc u =
  if any (== u) acc.seenUses then
    acc
  else
    { acc | seenUses = u :: acc.seenUses }

noteKey : DemandAcc -> String -> DemandAcc
noteKey acc k =
  if omHasKey k acc.seenKeys then
    acc
  else
    { acc | seenKeys = omInsert k () acc.seenKeys }

noteArity : DemandAcc -> Int -> DemandAcc
noteArity acc n =
  if any (== n) acc.seenArities then
    acc
  else
    { acc | seenArities = n :: acc.seenArities }

noteRefBox : DemandAcc -> DemandAcc
noteRefBox acc = if acc.seenRefBox then acc else { acc | seenRefBox = True }

-- an occurrence of a name: every demand and host key the catalog lists for it
noteName : DemandAcc -> String -> DemandAcc
noteName acc "Ref" = noteRefBox acc
noteName acc "$withFileReadBound" = noteFileBound acc
noteName acc "$withFileWriteBound" = noteFileBound acc
noteName acc name =
  walkEach
    noteArity
    (walkEach
      noteKey
      (walkEach noteUse acc (wasmUses name))
      (wasmHostKeys name))
    (wasmTupleArities name)

-- a declared file bound pushes its grant, a cons list of $str elements
noteFileBound : DemandAcc -> DemandAcc
noteFileBound acc =
  walkEach noteKey (noteUse (noteUse acc UseStr) UseList) fileBoundHostKeys

noteTag : DemandAcc -> String -> DemandAcc
noteTag acc "U64" = noteUse acc UseU64
noteTag acc "I64" = noteUse acc UseI64
noteTag acc _ = acc

-- `++` is runtime-dispatched ($mdk_append): the $str leaf concat and the cons list.
noteBinop : DemandAcc -> String -> DemandAcc
noteBinop acc "++" = noteUse (noteUse (noteUse acc UseStrLeaf) UseStr) UseList
noteBinop acc "::" = noteUse acc UseList
noteBinop acc "/" = { acc | seenDivGuard = True }
noteBinop acc "%" = { acc | seenDivGuard = True }
noteBinop acc _ = acc

dBind : DemandAcc -> CBind -> DemandAcc
dBind acc (CBind _ clauses _ _) = walkEach dClause acc clauses

-- a clause's parameter patterns, then its body
dClause : DemandAcc -> CClause -> DemandAcc
dClause acc (CClause pats body) = dExpr (walkEach dPat acc pats) body

dImpl : DemandAcc -> CImplEntry -> DemandAcc
dImpl acc (CImplEntry _ _ _ (CImplTagged _ _ _ _ _ pats b)) =
  dExpr (walkEach dPat acc pats) b
dImpl acc (CImplEntry _ _ _ (CImplDefault _ _ _ _ _ pats b)) =
  dExpr (walkEach dPat acc pats) b

dExpr : DemandAcc -> CExpr -> DemandAcc
dExpr acc (CList es) = walkEach dExpr (noteUse acc UseList) es
dExpr acc (CRangeList lo hi _) = dExpr (dExpr (noteUse acc UseList) lo) hi
dExpr acc (CTuple es) = walkEach dExpr (noteArity acc (listLen es)) es
dExpr acc (CArray es) = walkEach dExpr (noteUse acc UseArray) es
dExpr acc (CRangeArray lo hi _) = dExpr (dExpr (noteUse acc UseArray) lo) hi
dExpr acc (CIndex a i) = dExpr (dExpr (noteUse acc UseArray) a) i
dExpr acc (CSlice a lo hi _) =
  dExpr (dExpr (dExpr (noteUse acc UseArray) a) lo) hi
dExpr acc (CRecord _ fields) = walkEach dField acc fields
dExpr acc (CFieldAccess ex _ _ _) = dExpr acc ex
dExpr acc (CRecordUpdate _ base fields) =
  walkEach dField (dExpr acc base) fields
dExpr acc (CVariantUpdate _ base fields) =
  walkEach dField (dExpr acc base) fields
dExpr acc (app@(CApp _ _ _)) =
  let (hd, args) = flattenApp app []
  walkEach dExpr (dAppHead acc hd) args
dExpr acc (CVar x _) = noteName acc x
dExpr acc (CLit (LFloat _)) = noteUse acc UseFloat
dExpr acc (CLit (LU64 _ _)) = noteUse acc UseU64
dExpr acc (CLit (LI64 _ _)) = noteUse acc UseI64
dExpr acc (CLit (LString _)) = noteUse acc UseStr
dExpr acc (CLit (LChar _)) = noteUse acc UseStr
dExpr acc (CLam _ b) = dExpr acc b
dExpr acc (CBinPrim op l r tag _) =
  dExpr (dExpr (noteBinop (noteTag acc tag) op) l) r
dExpr acc (CUnOp _ x) = dExpr acc x
dExpr acc (CIf c t f) = dExpr (dExpr (dExpr acc c) t) f
dExpr acc (CLet _ pat a b) = dExpr (dExpr (dPat acc pat) a) b
dExpr acc (CBlock stmts) = walkEach dStmt acc stmts
dExpr acc (CDecision scrut arms tree) =
  dTree (walkEach dArm (dExpr acc scrut) arms) tree
dExpr acc (CMatch scrut arms) = walkEach dArm (dExpr acc scrut) arms
dExpr acc (CLetGroup binds b) = dExpr (walkEach dBind acc binds) b
dExpr acc _ = acc

dAppHead : DemandAcc -> CExpr -> DemandAcc
dAppHead acc (CVar "setRef" _) = noteRefBox acc
dAppHead acc (CVar f _) = noteName acc f
dAppHead acc h = dExpr acc h

dField : DemandAcc -> CField -> DemandAcc
dField acc (CField _ _ e) = dExpr acc e

dArm : DemandAcc -> CArm -> DemandAcc
dArm acc (CArm pat guards body) =
  dExpr (walkEach dGuard (dPat acc pat) guards) body

dGuard : DemandAcc -> CGuard -> DemandAcc
dGuard acc (CGBool g) = dExpr acc g
dGuard acc (CGBind p e) = dExpr (dPat acc p) e

dStmt : DemandAcc -> CStmt -> DemandAcc
dStmt acc (CSExpr e) = dExpr acc e
dStmt acc (CSLet _ pat e) = dExpr (dPat acc pat) e
dStmt acc (CSAssign _ e) = dExpr acc e

-- a pattern's collection heads: a cons or list pattern is a list, a tuple
-- pattern its arity
dPat : DemandAcc -> Pat -> DemandAcc
dPat acc (PCons h t) = dPat (dPat (noteUse acc UseList) h) t
dPat acc (PList ps) = walkEach dPat (noteUse acc UseList) ps
dPat acc (PTuple ps) = walkEach dPat (noteArity acc (listLen ps)) ps
dPat acc (PCon _ args) = walkEach dPat acc args
dPat acc (PAs _ _ _ p) = dPat acc p
dPat acc _ = acc

-- a decision tree's switch heads, the lowered shape of list and tuple patterns
dTree : DemandAcc -> CTree -> DemandAcc
dTree acc (CTGuard _ fail) = dTree acc fail
dTree acc (CTDrop sub) = dTree acc sub
dTree acc (CTSwitch branches dft) = dTree (walkEach dBranch acc branches) dft
dTree acc _ = acc

dBranch : DemandAcc -> CTBranch -> DemandAcc
dBranch acc (CTBranch h sub) = dTree (dSwitchHead acc h) sub

dSwitchHead : DemandAcc -> CHead -> DemandAcc
dSwitchHead acc HCons = noteUse acc UseList
dSwitchHead acc HNil = noteUse acc UseList
dSwitchHead acc (HTuple n) = noteArity acc n
dSwitchHead acc _ = acc
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Pat" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CArm" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CField" true) (mem "CGuard" true) (mem "CHead" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CStmt" true) (mem "CTBranch" true) (mem "CTree" true))))
(DUse false (UseGroup ("backend" "extern_catalog") ((mem "WasmUse" true) (mem "fileBoundHostKeys" false) (mem "wasmHostKeys" false) (mem "wasmTupleArities" false) (mem "wasmUses" false))))
(DUse false (UseGroup ("backend" "core_validate") ((mem "Backend" true) (mem "backendName" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omKeys" false) (mem "omFromNames" false) (mem "omFromPairs" false))))
(DUse false (UseGroup ("support" "util") ((mem "lenKey" false) (mem "reverseL" false) (mem "filterList" false) (mem "listLen" false))))
(DUse false (UseGroup ("backend" "wasm_reach") ((mem "wasmReachFilter" false))))
(DUse false (UseGroup ("backend" "emit_support") ((mem "eagerReachMap" false) (mem "lazyGlobalNames" false))))
(DUse false (UseGroup ("backend" "trmc_analysis") ((mem "SelfRef" true) (mem "flattenApp" false) (mem "DispGroup" false) (mem "trmcEligible" false) (mem "detectDispatchGroups" false) (mem "dictUniformClauses" false) (mem "methodSelf" false) (mem "clauseArityOf" false) (mem "bindName" false))))
(DData Public "EmitPlan" () ((variant "EmitPlan" (ConNamed (field "target" (TyCon "Backend")) (field "wasmOnlyReach" (TyApp (TyCon "Option") (TyCon "ReachUnits"))) (field "lazyGlobals" (TyApp (TyCon "List") (TyCon "String"))) (field "eagerReach" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "trmc" (TyCon "TrmcVerdicts")) (field "dispGroups" (TyApp (TyCon "List") (TyCon "DispGroup"))) (field "wasmDemand" (TyCon "WasmDemand")) (field "hostKeys" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DData Public "ReachUnits" () ((variant "ReachUnits" (ConNamed (field "total" (TyCon "Int")) (field "kept" (TyCon "Int"))))) ())
(DData Public "WasmDemand" () ((variant "WasmDemand" (ConNamed (field "uses" (TyApp (TyCon "List") (TyCon "WasmUse"))) (field "refBox" (TyCon "Bool")) (field "divGuard" (TyCon "Bool")) (field "tupleArities" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DData Public "TrmcVerdicts" () ((variant "TrmcVerdicts" (ConNamed (field "eligibleFns" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "eligibleImpls" (TyApp (TyCon "OrdMap") (TyCon "Unit")))))) ())
(DTypeSig true "buildEmitPlan" (TyFun (TyCon "Backend") (TyFun (TyCon "CProgram") (TyCon "EmitPlan"))))
(DFunDef false "buildEmitPlan" ((PVar "target") (PVar "prog")) (EApp (EApp (EApp (EVar "planOver") (EVar "target")) (EVar "None")) (EVar "prog")))
(DTypeSig true "buildEmitPlanReached" (TyFun (TyCon "CProgram") (TyTuple (TyCon "EmitPlan") (TyCon "CProgram"))))
(DFunDef false "buildEmitPlanReached" ((PVar "prog")) (EBlock (DoLet false false (PVar "reached") (EApp (EVar "wasmReachFilter") (EVar "prog"))) (DoLet false false (PVar "units") (ERecordCreate "ReachUnits" ((fa "total" (EApp (EVar "programUnitCount") (EVar "prog"))) (fa "kept" (EApp (EVar "programUnitCount") (EVar "reached")))))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "planOver") (EVar "WasmBackend")) (EApp (EVar "Some") (EVar "units"))) (EVar "reached")) (EVar "reached")))))
(DTypeSig false "programUnitCount" (TyFun (TyCon "CProgram") (TyCon "Int")))
(DFunDef false "programUnitCount" ((PCon "CProgram" (PVar "groups") PWild PWild (PVar "impls") PWild PWild)) (EBinOp "+" (EApp (EVar "listLen") (EVar "groups")) (EApp (EVar "listLen") (EVar "impls"))))
(DTypeSig false "planOver" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "Option") (TyCon "ReachUnits")) (TyFun (TyCon "CProgram") (TyCon "EmitPlan")))))
(DFunDef false "planOver" ((PVar "target") (PVar "reach") (PCon "CProgram" (PVar "groups") (PVar "ctorArs") PWild (PVar "impls") PWild PWild)) (EBlock (DoLet false false (PVar "ctors") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "ctorArs"))) (EVar "omEmpty"))) (DoLet false false (PVar "fns") (EApp (EApp (EVar "filterList") (EVar "isTopFn")) (EVar "groups"))) (DoLet false false (PTuple (PVar "demand") (PVar "keys")) (EMatch (EVar "target") (arm (PCon "WasmBackend") () (EApp (EApp (EVar "wasmDemandOf") (EVar "groups")) (EVar "impls"))) (arm (PCon "LlvmBackend") () (ETuple (EVar "noDemand") (EListLit))))) (DoExpr (ERecordCreate "EmitPlan" ((fa "target" (EVar "target")) (fa "wasmOnlyReach" (EVar "reach")) (fa "lazyGlobals" (EApp (EVar "lazyGlobalNames") (EVar "groups"))) (fa "eagerReach" (EApp (EVar "eagerReachMap") (EVar "groups"))) (fa "trmc" (ERecordCreate "TrmcVerdicts" ((fa "eligibleFns" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "bindName")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "selfTrmcBind") (EVar "ctors")) (EVar "b")))) (EVar "fns")))) (EVar "omEmpty"))) (fa "eligibleImpls" (EApp (EApp (EVar "trmcImplKeys") (EVar "ctors")) (EVar "impls")))))) (fa "dispGroups" (EApp (EApp (EApp (EApp (EVar "planDispatchGroups") (EVar "ctors")) (EVar "fns")) (EVar "groups")) (EVar "impls"))) (fa "wasmDemand" (EVar "demand")) (fa "hostKeys" (EVar "keys")))))))
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
(DTypeSig false "noDemand" (TyCon "WasmDemand"))
(DFunDef false "noDemand" () (ERecordCreate "WasmDemand" ((fa "uses" (EListLit)) (fa "refBox" (EVar "False")) (fa "divGuard" (EVar "False")) (fa "tupleArities" (EListLit)))))
(DData Private "DemandAcc" () ((variant "DemandAcc" (ConNamed (field "seenUses" (TyApp (TyCon "List") (TyCon "WasmUse"))) (field "seenKeys" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "seenRefBox" (TyCon "Bool")) (field "seenDivGuard" (TyCon "Bool")) (field "seenArities" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DTypeSig false "wasmDemandOf" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyTuple (TyCon "WasmDemand") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "wasmDemandOf" ((PVar "groups") (PVar "impls")) (EBlock (DoLet false false (PVar "start") (ERecordCreate "DemandAcc" ((fa "seenUses" (EListLit)) (fa "seenKeys" (EVar "omEmpty")) (fa "seenRefBox" (EVar "False")) (fa "seenDivGuard" (EVar "False")) (fa "seenArities" (EListLit))))) (DoLet false false (PVar "acc") (EApp (EApp (EApp (EVar "walkEach") (EVar "dImpl")) (EApp (EApp (EApp (EVar "walkEach") (EVar "dBind")) (EVar "start")) (EVar "groups"))) (EVar "impls"))) (DoExpr (ETuple (ERecordCreate "WasmDemand" ((fa "uses" (EApp (EVar "reverseL") (EFieldAccess (EVar "acc") "seenUses"))) (fa "refBox" (EFieldAccess (EVar "acc") "seenRefBox")) (fa "divGuard" (EFieldAccess (EVar "acc") "seenDivGuard")) (fa "tupleArities" (EApp (EVar "reverseL") (EFieldAccess (EVar "acc") "seenArities"))))) (EApp (EVar "omKeys") (EFieldAccess (EVar "acc") "seenKeys"))))))
(DTypeSig false "walkEach" (TyFun (TyFun (TyCon "DemandAcc") (TyFun (TyVar "a") (TyCon "DemandAcc"))) (TyFun (TyCon "DemandAcc") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "DemandAcc")))))
(DFunDef false "walkEach" (PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "walkEach" ((PVar "f") (PVar "acc") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "f")) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "x"))) (EVar "xs")))
(DTypeSig false "noteUse" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "WasmUse") (TyCon "DemandAcc"))))
(DFunDef false "noteUse" ((PVar "acc") (PVar "u")) (EIf (EApp (EApp (EVar "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "u")))) (EFieldAccess (EVar "acc") "seenUses")) (EVar "acc") (ERecordUpdate (EVar "acc") ((fa "seenUses" (EBinOp "::" (EVar "u") (EFieldAccess (EVar "acc") "seenUses")))))))
(DTypeSig false "noteKey" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "String") (TyCon "DemandAcc"))))
(DFunDef false "noteKey" ((PVar "acc") (PVar "k")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "k")) (EFieldAccess (EVar "acc") "seenKeys")) (EVar "acc") (ERecordUpdate (EVar "acc") ((fa "seenKeys" (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (ELit LUnit)) (EFieldAccess (EVar "acc") "seenKeys")))))))
(DTypeSig false "noteArity" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "Int") (TyCon "DemandAcc"))))
(DFunDef false "noteArity" ((PVar "acc") (PVar "n")) (EIf (EApp (EApp (EVar "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "n")))) (EFieldAccess (EVar "acc") "seenArities")) (EVar "acc") (ERecordUpdate (EVar "acc") ((fa "seenArities" (EBinOp "::" (EVar "n") (EFieldAccess (EVar "acc") "seenArities")))))))
(DTypeSig false "noteRefBox" (TyFun (TyCon "DemandAcc") (TyCon "DemandAcc")))
(DFunDef false "noteRefBox" ((PVar "acc")) (EIf (EFieldAccess (EVar "acc") "seenRefBox") (EVar "acc") (ERecordUpdate (EVar "acc") ((fa "seenRefBox" (EVar "True"))))))
(DTypeSig false "noteName" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "String") (TyCon "DemandAcc"))))
(DFunDef false "noteName" ((PVar "acc") (PLit (LString "Ref"))) (EApp (EVar "noteRefBox") (EVar "acc")))
(DFunDef false "noteName" ((PVar "acc") (PLit (LString "$withFileReadBound"))) (EApp (EVar "noteFileBound") (EVar "acc")))
(DFunDef false "noteName" ((PVar "acc") (PLit (LString "$withFileWriteBound"))) (EApp (EVar "noteFileBound") (EVar "acc")))
(DFunDef false "noteName" ((PVar "acc") (PVar "name")) (EApp (EApp (EApp (EVar "walkEach") (EVar "noteArity")) (EApp (EApp (EApp (EVar "walkEach") (EVar "noteKey")) (EApp (EApp (EApp (EVar "walkEach") (EVar "noteUse")) (EVar "acc")) (EApp (EVar "wasmUses") (EVar "name")))) (EApp (EVar "wasmHostKeys") (EVar "name")))) (EApp (EVar "wasmTupleArities") (EVar "name"))))
(DTypeSig false "noteFileBound" (TyFun (TyCon "DemandAcc") (TyCon "DemandAcc")))
(DFunDef false "noteFileBound" ((PVar "acc")) (EApp (EApp (EApp (EVar "walkEach") (EVar "noteKey")) (EApp (EApp (EVar "noteUse") (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseStr"))) (EVar "UseList"))) (EVar "fileBoundHostKeys")))
(DTypeSig false "noteTag" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "String") (TyCon "DemandAcc"))))
(DFunDef false "noteTag" ((PVar "acc") (PLit (LString "U64"))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseU64")))
(DFunDef false "noteTag" ((PVar "acc") (PLit (LString "I64"))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseI64")))
(DFunDef false "noteTag" ((PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "noteBinop" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "String") (TyCon "DemandAcc"))))
(DFunDef false "noteBinop" ((PVar "acc") (PLit (LString "++"))) (EApp (EApp (EVar "noteUse") (EApp (EApp (EVar "noteUse") (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseStrLeaf"))) (EVar "UseStr"))) (EVar "UseList")))
(DFunDef false "noteBinop" ((PVar "acc") (PLit (LString "::"))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseList")))
(DFunDef false "noteBinop" ((PVar "acc") (PLit (LString "/"))) (ERecordUpdate (EVar "acc") ((fa "seenDivGuard" (EVar "True")))))
(DFunDef false "noteBinop" ((PVar "acc") (PLit (LString "%"))) (ERecordUpdate (EVar "acc") ((fa "seenDivGuard" (EVar "True")))))
(DFunDef false "noteBinop" ((PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "dBind" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CBind") (TyCon "DemandAcc"))))
(DFunDef false "dBind" ((PVar "acc") (PCon "CBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EApp (EVar "walkEach") (EVar "dClause")) (EVar "acc")) (EVar "clauses")))
(DTypeSig false "dClause" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CClause") (TyCon "DemandAcc"))))
(DFunDef false "dClause" ((PVar "acc") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "dExpr") (EApp (EApp (EApp (EVar "walkEach") (EVar "dPat")) (EVar "acc")) (EVar "pats"))) (EVar "body")))
(DTypeSig false "dImpl" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CImplEntry") (TyCon "DemandAcc"))))
(DFunDef false "dImpl" ((PVar "acc") (PCon "CImplEntry" PWild PWild PWild (PCon "CImplTagged" PWild PWild PWild PWild PWild (PVar "pats") (PVar "b")))) (EApp (EApp (EVar "dExpr") (EApp (EApp (EApp (EVar "walkEach") (EVar "dPat")) (EVar "acc")) (EVar "pats"))) (EVar "b")))
(DFunDef false "dImpl" ((PVar "acc") (PCon "CImplEntry" PWild PWild PWild (PCon "CImplDefault" PWild PWild PWild PWild PWild (PVar "pats") (PVar "b")))) (EApp (EApp (EVar "dExpr") (EApp (EApp (EApp (EVar "walkEach") (EVar "dPat")) (EVar "acc")) (EVar "pats"))) (EVar "b")))
(DTypeSig false "dExpr" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CExpr") (TyCon "DemandAcc"))))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CList" (PVar "es"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dExpr")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseList"))) (EVar "es")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseList"))) (EVar "lo"))) (EVar "hi")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CTuple" (PVar "es"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dExpr")) (EApp (EApp (EVar "noteArity") (EVar "acc")) (EApp (EVar "listLen") (EVar "es")))) (EVar "es")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CArray" (PVar "es"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dExpr")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseArray"))) (EVar "es")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseArray"))) (EVar "lo"))) (EVar "hi")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseArray"))) (EVar "a"))) (EVar "i")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseArray"))) (EVar "a"))) (EVar "lo"))) (EVar "hi")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CRecord" PWild (PVar "fields"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dField")) (EVar "acc")) (EVar "fields")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CFieldAccess" (PVar "ex") PWild PWild PWild)) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "ex")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CRecordUpdate" PWild (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dField")) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "base"))) (EVar "fields")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CVariantUpdate" PWild (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dField")) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "base"))) (EVar "fields")))
(DFunDef false "dExpr" ((PVar "acc") (PAs "app" (PCon "CApp" PWild PWild PWild))) (EBlock (DoLet false false (PTuple (PVar "hd") (PVar "args")) (EApp (EApp (EVar "flattenApp") (EVar "app")) (EListLit))) (DoExpr (EApp (EApp (EApp (EVar "walkEach") (EVar "dExpr")) (EApp (EApp (EVar "dAppHead") (EVar "acc")) (EVar "hd"))) (EVar "args")))))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CVar" (PVar "x") PWild)) (EApp (EApp (EVar "noteName") (EVar "acc")) (EVar "x")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CLit" (PCon "LFloat" PWild))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseFloat")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CLit" (PCon "LU64" PWild PWild))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseU64")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CLit" (PCon "LI64" PWild PWild))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseI64")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CLit" (PCon "LString" PWild))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseStr")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CLit" (PCon "LChar" PWild))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseStr")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CLam" PWild (PVar "b"))) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "b")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") PWild)) (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "noteBinop") (EApp (EApp (EVar "noteTag") (EVar "acc")) (EVar "tag"))) (EVar "op"))) (EVar "l"))) (EVar "r")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CUnOp" PWild (PVar "x"))) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "x")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "c"))) (EVar "t"))) (EVar "f")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CLet" PWild (PVar "pat") (PVar "a") (PVar "b"))) (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dPat") (EVar "acc")) (EVar "pat"))) (EVar "a"))) (EVar "b")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dStmt")) (EVar "acc")) (EVar "stmts")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EVar "dTree") (EApp (EApp (EApp (EVar "walkEach") (EVar "dArm")) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "scrut"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dArm")) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "scrut"))) (EVar "arms")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CLetGroup" (PVar "binds") (PVar "b"))) (EApp (EApp (EVar "dExpr") (EApp (EApp (EApp (EVar "walkEach") (EVar "dBind")) (EVar "acc")) (EVar "binds"))) (EVar "b")))
(DFunDef false "dExpr" ((PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "dAppHead" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CExpr") (TyCon "DemandAcc"))))
(DFunDef false "dAppHead" ((PVar "acc") (PCon "CVar" (PLit (LString "setRef")) PWild)) (EApp (EVar "noteRefBox") (EVar "acc")))
(DFunDef false "dAppHead" ((PVar "acc") (PCon "CVar" (PVar "f") PWild)) (EApp (EApp (EVar "noteName") (EVar "acc")) (EVar "f")))
(DFunDef false "dAppHead" ((PVar "acc") (PVar "h")) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "h")))
(DTypeSig false "dField" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CField") (TyCon "DemandAcc"))))
(DFunDef false "dField" ((PVar "acc") (PCon "CField" PWild PWild (PVar "e"))) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "e")))
(DTypeSig false "dArm" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CArm") (TyCon "DemandAcc"))))
(DFunDef false "dArm" ((PVar "acc") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EVar "dExpr") (EApp (EApp (EApp (EVar "walkEach") (EVar "dGuard")) (EApp (EApp (EVar "dPat") (EVar "acc")) (EVar "pat"))) (EVar "guards"))) (EVar "body")))
(DTypeSig false "dGuard" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CGuard") (TyCon "DemandAcc"))))
(DFunDef false "dGuard" ((PVar "acc") (PCon "CGBool" (PVar "g"))) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "g")))
(DFunDef false "dGuard" ((PVar "acc") (PCon "CGBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dPat") (EVar "acc")) (EVar "p"))) (EVar "e")))
(DTypeSig false "dStmt" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CStmt") (TyCon "DemandAcc"))))
(DFunDef false "dStmt" ((PVar "acc") (PCon "CSExpr" (PVar "e"))) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "e")))
(DFunDef false "dStmt" ((PVar "acc") (PCon "CSLet" PWild (PVar "pat") (PVar "e"))) (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dPat") (EVar "acc")) (EVar "pat"))) (EVar "e")))
(DFunDef false "dStmt" ((PVar "acc") (PCon "CSAssign" PWild (PVar "e"))) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "e")))
(DTypeSig false "dPat" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "Pat") (TyCon "DemandAcc"))))
(DFunDef false "dPat" ((PVar "acc") (PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "dPat") (EApp (EApp (EVar "dPat") (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseList"))) (EVar "h"))) (EVar "t")))
(DFunDef false "dPat" ((PVar "acc") (PCon "PList" (PVar "ps"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dPat")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseList"))) (EVar "ps")))
(DFunDef false "dPat" ((PVar "acc") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dPat")) (EApp (EApp (EVar "noteArity") (EVar "acc")) (EApp (EVar "listLen") (EVar "ps")))) (EVar "ps")))
(DFunDef false "dPat" ((PVar "acc") (PCon "PCon" PWild (PVar "args"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dPat")) (EVar "acc")) (EVar "args")))
(DFunDef false "dPat" ((PVar "acc") (PCon "PAs" PWild PWild PWild (PVar "p"))) (EApp (EApp (EVar "dPat") (EVar "acc")) (EVar "p")))
(DFunDef false "dPat" ((PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "dTree" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CTree") (TyCon "DemandAcc"))))
(DFunDef false "dTree" ((PVar "acc") (PCon "CTGuard" PWild (PVar "fail"))) (EApp (EApp (EVar "dTree") (EVar "acc")) (EVar "fail")))
(DFunDef false "dTree" ((PVar "acc") (PCon "CTDrop" (PVar "sub"))) (EApp (EApp (EVar "dTree") (EVar "acc")) (EVar "sub")))
(DFunDef false "dTree" ((PVar "acc") (PCon "CTSwitch" (PVar "branches") (PVar "dft"))) (EApp (EApp (EVar "dTree") (EApp (EApp (EApp (EVar "walkEach") (EVar "dBranch")) (EVar "acc")) (EVar "branches"))) (EVar "dft")))
(DFunDef false "dTree" ((PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "dBranch" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CTBranch") (TyCon "DemandAcc"))))
(DFunDef false "dBranch" ((PVar "acc") (PCon "CTBranch" (PVar "h") (PVar "sub"))) (EApp (EApp (EVar "dTree") (EApp (EApp (EVar "dSwitchHead") (EVar "acc")) (EVar "h"))) (EVar "sub")))
(DTypeSig false "dSwitchHead" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CHead") (TyCon "DemandAcc"))))
(DFunDef false "dSwitchHead" ((PVar "acc") (PCon "HCons")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseList")))
(DFunDef false "dSwitchHead" ((PVar "acc") (PCon "HNil")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseList")))
(DFunDef false "dSwitchHead" ((PVar "acc") (PCon "HTuple" (PVar "n"))) (EApp (EApp (EVar "noteArity") (EVar "acc")) (EVar "n")))
(DFunDef false "dSwitchHead" ((PVar "acc") PWild) (EVar "acc"))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Pat" true))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CArm" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CField" true) (mem "CGuard" true) (mem "CHead" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CStmt" true) (mem "CTBranch" true) (mem "CTree" true))))
(DUse false (UseGroup ("backend" "extern_catalog") ((mem "WasmUse" true) (mem "fileBoundHostKeys" false) (mem "wasmHostKeys" false) (mem "wasmTupleArities" false) (mem "wasmUses" false))))
(DUse false (UseGroup ("backend" "core_validate") ((mem "Backend" true) (mem "backendName" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omKeys" false) (mem "omFromNames" false) (mem "omFromPairs" false))))
(DUse false (UseGroup ("support" "util") ((mem "lenKey" false) (mem "reverseL" false) (mem "filterList" false) (mem "listLen" false))))
(DUse false (UseGroup ("backend" "wasm_reach") ((mem "wasmReachFilter" false))))
(DUse false (UseGroup ("backend" "emit_support") ((mem "eagerReachMap" false) (mem "lazyGlobalNames" false))))
(DUse false (UseGroup ("backend" "trmc_analysis") ((mem "SelfRef" true) (mem "flattenApp" false) (mem "DispGroup" false) (mem "trmcEligible" false) (mem "detectDispatchGroups" false) (mem "dictUniformClauses" false) (mem "methodSelf" false) (mem "clauseArityOf" false) (mem "bindName" false))))
(DData Public "EmitPlan" () ((variant "EmitPlan" (ConNamed (field "target" (TyCon "Backend")) (field "wasmOnlyReach" (TyApp (TyCon "Option") (TyCon "ReachUnits"))) (field "lazyGlobals" (TyApp (TyCon "List") (TyCon "String"))) (field "eagerReach" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "trmc" (TyCon "TrmcVerdicts")) (field "dispGroups" (TyApp (TyCon "List") (TyCon "DispGroup"))) (field "wasmDemand" (TyCon "WasmDemand")) (field "hostKeys" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DData Public "ReachUnits" () ((variant "ReachUnits" (ConNamed (field "total" (TyCon "Int")) (field "kept" (TyCon "Int"))))) ())
(DData Public "WasmDemand" () ((variant "WasmDemand" (ConNamed (field "uses" (TyApp (TyCon "List") (TyCon "WasmUse"))) (field "refBox" (TyCon "Bool")) (field "divGuard" (TyCon "Bool")) (field "tupleArities" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DData Public "TrmcVerdicts" () ((variant "TrmcVerdicts" (ConNamed (field "eligibleFns" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "eligibleImpls" (TyApp (TyCon "OrdMap") (TyCon "Unit")))))) ())
(DTypeSig true "buildEmitPlan" (TyFun (TyCon "Backend") (TyFun (TyCon "CProgram") (TyCon "EmitPlan"))))
(DFunDef false "buildEmitPlan" ((PVar "target") (PVar "prog")) (EApp (EApp (EApp (EVar "planOver") (EVar "target")) (EVar "None")) (EVar "prog")))
(DTypeSig true "buildEmitPlanReached" (TyFun (TyCon "CProgram") (TyTuple (TyCon "EmitPlan") (TyCon "CProgram"))))
(DFunDef false "buildEmitPlanReached" ((PVar "prog")) (EBlock (DoLet false false (PVar "reached") (EApp (EVar "wasmReachFilter") (EVar "prog"))) (DoLet false false (PVar "units") (ERecordCreate "ReachUnits" ((fa "total" (EApp (EVar "programUnitCount") (EVar "prog"))) (fa "kept" (EApp (EVar "programUnitCount") (EVar "reached")))))) (DoExpr (ETuple (EApp (EApp (EApp (EVar "planOver") (EVar "WasmBackend")) (EApp (EVar "Some") (EVar "units"))) (EVar "reached")) (EVar "reached")))))
(DTypeSig false "programUnitCount" (TyFun (TyCon "CProgram") (TyCon "Int")))
(DFunDef false "programUnitCount" ((PCon "CProgram" (PVar "groups") PWild PWild (PVar "impls") PWild PWild)) (EBinOp "+" (EApp (EVar "listLen") (EVar "groups")) (EApp (EVar "listLen") (EVar "impls"))))
(DTypeSig false "planOver" (TyFun (TyCon "Backend") (TyFun (TyApp (TyCon "Option") (TyCon "ReachUnits")) (TyFun (TyCon "CProgram") (TyCon "EmitPlan")))))
(DFunDef false "planOver" ((PVar "target") (PVar "reach") (PCon "CProgram" (PVar "groups") (PVar "ctorArs") PWild (PVar "impls") PWild PWild)) (EBlock (DoLet false false (PVar "ctors") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "ctorArs"))) (EVar "omEmpty"))) (DoLet false false (PVar "fns") (EApp (EApp (EVar "filterList") (EVar "isTopFn")) (EVar "groups"))) (DoLet false false (PTuple (PVar "demand") (PVar "keys")) (EMatch (EVar "target") (arm (PCon "WasmBackend") () (EApp (EApp (EVar "wasmDemandOf") (EVar "groups")) (EVar "impls"))) (arm (PCon "LlvmBackend") () (ETuple (EVar "noDemand") (EListLit))))) (DoExpr (ERecordCreate "EmitPlan" ((fa "target" (EVar "target")) (fa "wasmOnlyReach" (EVar "reach")) (fa "lazyGlobals" (EApp (EVar "lazyGlobalNames") (EVar "groups"))) (fa "eagerReach" (EApp (EVar "eagerReachMap") (EVar "groups"))) (fa "trmc" (ERecordCreate "TrmcVerdicts" ((fa "eligibleFns" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "bindName")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EApp (EVar "selfTrmcBind") (EVar "ctors")) (EVar "b")))) (EVar "fns")))) (EVar "omEmpty"))) (fa "eligibleImpls" (EApp (EApp (EVar "trmcImplKeys") (EVar "ctors")) (EVar "impls")))))) (fa "dispGroups" (EApp (EApp (EApp (EApp (EVar "planDispatchGroups") (EVar "ctors")) (EVar "fns")) (EVar "groups")) (EVar "impls"))) (fa "wasmDemand" (EVar "demand")) (fa "hostKeys" (EVar "keys")))))))
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
(DTypeSig false "noDemand" (TyCon "WasmDemand"))
(DFunDef false "noDemand" () (ERecordCreate "WasmDemand" ((fa "uses" (EListLit)) (fa "refBox" (EVar "False")) (fa "divGuard" (EVar "False")) (fa "tupleArities" (EListLit)))))
(DData Private "DemandAcc" () ((variant "DemandAcc" (ConNamed (field "seenUses" (TyApp (TyCon "List") (TyCon "WasmUse"))) (field "seenKeys" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "seenRefBox" (TyCon "Bool")) (field "seenDivGuard" (TyCon "Bool")) (field "seenArities" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DTypeSig false "wasmDemandOf" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyTuple (TyCon "WasmDemand") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "wasmDemandOf" ((PVar "groups") (PVar "impls")) (EBlock (DoLet false false (PVar "start") (ERecordCreate "DemandAcc" ((fa "seenUses" (EListLit)) (fa "seenKeys" (EVar "omEmpty")) (fa "seenRefBox" (EVar "False")) (fa "seenDivGuard" (EVar "False")) (fa "seenArities" (EListLit))))) (DoLet false false (PVar "acc") (EApp (EApp (EApp (EVar "walkEach") (EVar "dImpl")) (EApp (EApp (EApp (EVar "walkEach") (EVar "dBind")) (EVar "start")) (EVar "groups"))) (EVar "impls"))) (DoExpr (ETuple (ERecordCreate "WasmDemand" ((fa "uses" (EApp (EVar "reverseL") (EFieldAccess (EVar "acc") "seenUses"))) (fa "refBox" (EFieldAccess (EVar "acc") "seenRefBox")) (fa "divGuard" (EFieldAccess (EVar "acc") "seenDivGuard")) (fa "tupleArities" (EApp (EVar "reverseL") (EFieldAccess (EVar "acc") "seenArities"))))) (EApp (EVar "omKeys") (EFieldAccess (EVar "acc") "seenKeys"))))))
(DTypeSig false "walkEach" (TyFun (TyFun (TyCon "DemandAcc") (TyFun (TyVar "a") (TyCon "DemandAcc"))) (TyFun (TyCon "DemandAcc") (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "DemandAcc")))))
(DFunDef false "walkEach" (PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "walkEach" ((PVar "f") (PVar "acc") (PCons (PVar "x") (PVar "xs"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "f")) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "x"))) (EVar "xs")))
(DTypeSig false "noteUse" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "WasmUse") (TyCon "DemandAcc"))))
(DFunDef false "noteUse" ((PVar "acc") (PVar "u")) (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "u")))) (EFieldAccess (EVar "acc") "seenUses")) (EVar "acc") (ERecordUpdate (EVar "acc") ((fa "seenUses" (EBinOp "::" (EVar "u") (EFieldAccess (EVar "acc") "seenUses")))))))
(DTypeSig false "noteKey" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "String") (TyCon "DemandAcc"))))
(DFunDef false "noteKey" ((PVar "acc") (PVar "k")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "k")) (EFieldAccess (EVar "acc") "seenKeys")) (EVar "acc") (ERecordUpdate (EVar "acc") ((fa "seenKeys" (EApp (EApp (EApp (EVar "omInsert") (EVar "k")) (ELit LUnit)) (EFieldAccess (EVar "acc") "seenKeys")))))))
(DTypeSig false "noteArity" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "Int") (TyCon "DemandAcc"))))
(DFunDef false "noteArity" ((PVar "acc") (PVar "n")) (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "n")))) (EFieldAccess (EVar "acc") "seenArities")) (EVar "acc") (ERecordUpdate (EVar "acc") ((fa "seenArities" (EBinOp "::" (EVar "n") (EFieldAccess (EVar "acc") "seenArities")))))))
(DTypeSig false "noteRefBox" (TyFun (TyCon "DemandAcc") (TyCon "DemandAcc")))
(DFunDef false "noteRefBox" ((PVar "acc")) (EIf (EFieldAccess (EVar "acc") "seenRefBox") (EVar "acc") (ERecordUpdate (EVar "acc") ((fa "seenRefBox" (EVar "True"))))))
(DTypeSig false "noteName" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "String") (TyCon "DemandAcc"))))
(DFunDef false "noteName" ((PVar "acc") (PLit (LString "Ref"))) (EApp (EVar "noteRefBox") (EVar "acc")))
(DFunDef false "noteName" ((PVar "acc") (PLit (LString "$withFileReadBound"))) (EApp (EVar "noteFileBound") (EVar "acc")))
(DFunDef false "noteName" ((PVar "acc") (PLit (LString "$withFileWriteBound"))) (EApp (EVar "noteFileBound") (EVar "acc")))
(DFunDef false "noteName" ((PVar "acc") (PVar "name")) (EApp (EApp (EApp (EVar "walkEach") (EVar "noteArity")) (EApp (EApp (EApp (EVar "walkEach") (EVar "noteKey")) (EApp (EApp (EApp (EVar "walkEach") (EVar "noteUse")) (EVar "acc")) (EApp (EVar "wasmUses") (EVar "name")))) (EApp (EVar "wasmHostKeys") (EVar "name")))) (EApp (EVar "wasmTupleArities") (EVar "name"))))
(DTypeSig false "noteFileBound" (TyFun (TyCon "DemandAcc") (TyCon "DemandAcc")))
(DFunDef false "noteFileBound" ((PVar "acc")) (EApp (EApp (EApp (EVar "walkEach") (EVar "noteKey")) (EApp (EApp (EVar "noteUse") (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseStr"))) (EVar "UseList"))) (EVar "fileBoundHostKeys")))
(DTypeSig false "noteTag" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "String") (TyCon "DemandAcc"))))
(DFunDef false "noteTag" ((PVar "acc") (PLit (LString "U64"))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseU64")))
(DFunDef false "noteTag" ((PVar "acc") (PLit (LString "I64"))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseI64")))
(DFunDef false "noteTag" ((PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "noteBinop" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "String") (TyCon "DemandAcc"))))
(DFunDef false "noteBinop" ((PVar "acc") (PLit (LString "++"))) (EApp (EApp (EVar "noteUse") (EApp (EApp (EVar "noteUse") (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseStrLeaf"))) (EVar "UseStr"))) (EVar "UseList")))
(DFunDef false "noteBinop" ((PVar "acc") (PLit (LString "::"))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseList")))
(DFunDef false "noteBinop" ((PVar "acc") (PLit (LString "/"))) (ERecordUpdate (EVar "acc") ((fa "seenDivGuard" (EVar "True")))))
(DFunDef false "noteBinop" ((PVar "acc") (PLit (LString "%"))) (ERecordUpdate (EVar "acc") ((fa "seenDivGuard" (EVar "True")))))
(DFunDef false "noteBinop" ((PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "dBind" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CBind") (TyCon "DemandAcc"))))
(DFunDef false "dBind" ((PVar "acc") (PCon "CBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EApp (EVar "walkEach") (EVar "dClause")) (EVar "acc")) (EVar "clauses")))
(DTypeSig false "dClause" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CClause") (TyCon "DemandAcc"))))
(DFunDef false "dClause" ((PVar "acc") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "dExpr") (EApp (EApp (EApp (EVar "walkEach") (EVar "dPat")) (EVar "acc")) (EVar "pats"))) (EVar "body")))
(DTypeSig false "dImpl" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CImplEntry") (TyCon "DemandAcc"))))
(DFunDef false "dImpl" ((PVar "acc") (PCon "CImplEntry" PWild PWild PWild (PCon "CImplTagged" PWild PWild PWild PWild PWild (PVar "pats") (PVar "b")))) (EApp (EApp (EVar "dExpr") (EApp (EApp (EApp (EVar "walkEach") (EVar "dPat")) (EVar "acc")) (EVar "pats"))) (EVar "b")))
(DFunDef false "dImpl" ((PVar "acc") (PCon "CImplEntry" PWild PWild PWild (PCon "CImplDefault" PWild PWild PWild PWild PWild (PVar "pats") (PVar "b")))) (EApp (EApp (EVar "dExpr") (EApp (EApp (EApp (EVar "walkEach") (EVar "dPat")) (EVar "acc")) (EVar "pats"))) (EVar "b")))
(DTypeSig false "dExpr" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CExpr") (TyCon "DemandAcc"))))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CList" (PVar "es"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dExpr")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseList"))) (EVar "es")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseList"))) (EVar "lo"))) (EVar "hi")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CTuple" (PVar "es"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dExpr")) (EApp (EApp (EVar "noteArity") (EVar "acc")) (EApp (EVar "listLen") (EVar "es")))) (EVar "es")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CArray" (PVar "es"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dExpr")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseArray"))) (EVar "es")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseArray"))) (EVar "lo"))) (EVar "hi")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseArray"))) (EVar "a"))) (EVar "i")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseArray"))) (EVar "a"))) (EVar "lo"))) (EVar "hi")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CRecord" PWild (PVar "fields"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dField")) (EVar "acc")) (EVar "fields")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CFieldAccess" (PVar "ex") PWild PWild PWild)) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "ex")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CRecordUpdate" PWild (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dField")) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "base"))) (EVar "fields")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CVariantUpdate" PWild (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dField")) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "base"))) (EVar "fields")))
(DFunDef false "dExpr" ((PVar "acc") (PAs "app" (PCon "CApp" PWild PWild PWild))) (EBlock (DoLet false false (PTuple (PVar "hd") (PVar "args")) (EApp (EApp (EVar "flattenApp") (EVar "app")) (EListLit))) (DoExpr (EApp (EApp (EApp (EVar "walkEach") (EVar "dExpr")) (EApp (EApp (EVar "dAppHead") (EVar "acc")) (EVar "hd"))) (EVar "args")))))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CVar" (PVar "x") PWild)) (EApp (EApp (EVar "noteName") (EVar "acc")) (EVar "x")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CLit" (PCon "LFloat" PWild))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseFloat")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CLit" (PCon "LU64" PWild PWild))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseU64")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CLit" (PCon "LI64" PWild PWild))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseI64")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CLit" (PCon "LString" PWild))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseStr")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CLit" (PCon "LChar" PWild))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseStr")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CLam" PWild (PVar "b"))) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "b")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") PWild)) (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "noteBinop") (EApp (EApp (EVar "noteTag") (EVar "acc")) (EVar "tag"))) (EVar "op"))) (EVar "l"))) (EVar "r")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CUnOp" PWild (PVar "x"))) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "x")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "c"))) (EVar "t"))) (EVar "f")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CLet" PWild (PVar "pat") (PVar "a") (PVar "b"))) (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dPat") (EVar "acc")) (EVar "pat"))) (EVar "a"))) (EVar "b")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dStmt")) (EVar "acc")) (EVar "stmts")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EVar "dTree") (EApp (EApp (EApp (EVar "walkEach") (EVar "dArm")) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "scrut"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dArm")) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "scrut"))) (EVar "arms")))
(DFunDef false "dExpr" ((PVar "acc") (PCon "CLetGroup" (PVar "binds") (PVar "b"))) (EApp (EApp (EVar "dExpr") (EApp (EApp (EApp (EVar "walkEach") (EVar "dBind")) (EVar "acc")) (EVar "binds"))) (EVar "b")))
(DFunDef false "dExpr" ((PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "dAppHead" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CExpr") (TyCon "DemandAcc"))))
(DFunDef false "dAppHead" ((PVar "acc") (PCon "CVar" (PLit (LString "setRef")) PWild)) (EApp (EVar "noteRefBox") (EVar "acc")))
(DFunDef false "dAppHead" ((PVar "acc") (PCon "CVar" (PVar "f") PWild)) (EApp (EApp (EVar "noteName") (EVar "acc")) (EVar "f")))
(DFunDef false "dAppHead" ((PVar "acc") (PVar "h")) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "h")))
(DTypeSig false "dField" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CField") (TyCon "DemandAcc"))))
(DFunDef false "dField" ((PVar "acc") (PCon "CField" PWild PWild (PVar "e"))) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "e")))
(DTypeSig false "dArm" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CArm") (TyCon "DemandAcc"))))
(DFunDef false "dArm" ((PVar "acc") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EVar "dExpr") (EApp (EApp (EApp (EVar "walkEach") (EVar "dGuard")) (EApp (EApp (EVar "dPat") (EVar "acc")) (EVar "pat"))) (EVar "guards"))) (EVar "body")))
(DTypeSig false "dGuard" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CGuard") (TyCon "DemandAcc"))))
(DFunDef false "dGuard" ((PVar "acc") (PCon "CGBool" (PVar "g"))) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "g")))
(DFunDef false "dGuard" ((PVar "acc") (PCon "CGBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dPat") (EVar "acc")) (EVar "p"))) (EVar "e")))
(DTypeSig false "dStmt" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CStmt") (TyCon "DemandAcc"))))
(DFunDef false "dStmt" ((PVar "acc") (PCon "CSExpr" (PVar "e"))) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "e")))
(DFunDef false "dStmt" ((PVar "acc") (PCon "CSLet" PWild (PVar "pat") (PVar "e"))) (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "dPat") (EVar "acc")) (EVar "pat"))) (EVar "e")))
(DFunDef false "dStmt" ((PVar "acc") (PCon "CSAssign" PWild (PVar "e"))) (EApp (EApp (EVar "dExpr") (EVar "acc")) (EVar "e")))
(DTypeSig false "dPat" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "Pat") (TyCon "DemandAcc"))))
(DFunDef false "dPat" ((PVar "acc") (PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "dPat") (EApp (EApp (EVar "dPat") (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseList"))) (EVar "h"))) (EVar "t")))
(DFunDef false "dPat" ((PVar "acc") (PCon "PList" (PVar "ps"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dPat")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseList"))) (EVar "ps")))
(DFunDef false "dPat" ((PVar "acc") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dPat")) (EApp (EApp (EVar "noteArity") (EVar "acc")) (EApp (EVar "listLen") (EVar "ps")))) (EVar "ps")))
(DFunDef false "dPat" ((PVar "acc") (PCon "PCon" PWild (PVar "args"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dPat")) (EVar "acc")) (EVar "args")))
(DFunDef false "dPat" ((PVar "acc") (PCon "PAs" PWild PWild PWild (PVar "p"))) (EApp (EApp (EVar "dPat") (EVar "acc")) (EVar "p")))
(DFunDef false "dPat" ((PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "dTree" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CTree") (TyCon "DemandAcc"))))
(DFunDef false "dTree" ((PVar "acc") (PCon "CTGuard" PWild (PVar "fail"))) (EApp (EApp (EVar "dTree") (EVar "acc")) (EVar "fail")))
(DFunDef false "dTree" ((PVar "acc") (PCon "CTDrop" (PVar "sub"))) (EApp (EApp (EVar "dTree") (EVar "acc")) (EMethodRef "sub")))
(DFunDef false "dTree" ((PVar "acc") (PCon "CTSwitch" (PVar "branches") (PVar "dft"))) (EApp (EApp (EVar "dTree") (EApp (EApp (EApp (EVar "walkEach") (EVar "dBranch")) (EVar "acc")) (EVar "branches"))) (EVar "dft")))
(DFunDef false "dTree" ((PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "dBranch" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CTBranch") (TyCon "DemandAcc"))))
(DFunDef false "dBranch" ((PVar "acc") (PCon "CTBranch" (PVar "h") (PVar "sub"))) (EApp (EApp (EVar "dTree") (EApp (EApp (EVar "dSwitchHead") (EVar "acc")) (EVar "h"))) (EMethodRef "sub")))
(DTypeSig false "dSwitchHead" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CHead") (TyCon "DemandAcc"))))
(DFunDef false "dSwitchHead" ((PVar "acc") (PCon "HCons")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseList")))
(DFunDef false "dSwitchHead" ((PVar "acc") (PCon "HNil")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseList")))
(DFunDef false "dSwitchHead" ((PVar "acc") (PCon "HTuple" (PVar "n"))) (EApp (EApp (EVar "noteArity") (EVar "acc")) (EVar "n")))
(DFunDef false "dSwitchHead" ((PVar "acc") PWild) (EVar "acc"))
