# META
source_lines=2283
stages=DESUGAR,MARK
# SOURCE
import frontend.ast.{
  Lit(..), Pat(..), Addr(..), BinderId(..), Loc(..), isTaggedFixedHead
}
import ir.core_ir.{
  CProgram(..), DeclFacts(..), EntryFact(..), CBind(..), CClause(..), CExpr(..),
  CField(..), CGuard(..), CImplEntry(..), CImplBody(..), CStmt(..), CArm(..),
  CHead(..), CTree(..), CTBranch(..), CallSite(..), CallMode(..), FailSite(..),
  litRuntimeType, siteSentinelName
}
import ir.extern_types.{ExternDeclFact(..)}
import ir.extern_lower.{externRuntimeKey}
import backend.extern_requirements.{
  ExternRequirements, RequirementBinding(..), requirementHostRows,
  requirementFacts
}
import backend.extern_catalog.{
  WasmUse(..), WasmFamily(..), Disposition(..), wasmUses, wasmHostKeys,
  wasmTupleArities, wasmFamily, isWasmExternFamily, fileBoundHostKeys
}
import backend.global_plan.{GlobalInitPlan}
import backend.trmc_analysis.{
  TrmcVerdicts, DispGroup, patVarsList, patVars, bindName, clauseBodyOf,
  armBody, flattenApp
}
import backend.emit_support.{appParts, isExactCall}
import types.runtime_types.{BinderRow(..), RuntimeType(..), binderOrdinal}
import types.private_mangle.{injectiveIdent}
import support.ordmap.{
  OrdMap, omEmpty, omInsert, omLookup, omHasKey, omKeys, omFromNames,
  omFromPairs, omDelete
}
import support.util.{
  reverseL, filterList, listLen, contains, startsWith, isEmptyL, isNonEmptyL,
  anyList, lookupAssoc, joinWith, lenKey
}

-- A reached user extern's `js` binding (docs/spec/WASM-SEMANTICS.md section
-- 3.1): its Medaka name, the JS name it binds, and its declared parameter and
-- result heads (`Array` is `Array Int`).
public export data JsImport = JsImport {
  medakaName : String,
  jsName : String,
  params : List String,
  result : String,
} deriving (Eq, Debug)

-- One walk of every binding and impl body (`wasmDemandOf`).  `uses` holds, once
-- each, the catalog demands (`wasmUses`) of every runtime extern the program
-- names and the demands its literals, collection forms and `++`/`::` make.
-- `refBox` is a `Ref` cell, `divGuard` a `/` or `%`, and `tupleArities` the
-- distinct tuple arities, first seen first.  A name demands what its extern
-- does only where the emitter would lower it as that extern (`DemandScope`), so a
-- binder that shares an extern's name demands nothing.
public export data WasmDemand = WasmDemand {
  uses : List WasmUse,
  refBox : Bool,
  divGuard : Bool,
  tupleArities : List Int,
} deriving (Eq, Debug)

-- ── the wasm demand walk ────────────────────────────────────────────────────

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

wasmDemandOf : OrdMap ExternDeclFact ->
  OrdMap (String, (List String, String)) ->
  List CBind ->
  List CImplEntry ->
  (WasmDemand, List String, List JsImport)
wasmDemandOf externFacts jsBinds groups impls =
  let start = DemandAcc {
    seenUses = [],
    seenKeys = omEmpty,
    seenJs = omEmpty,
    seenRefBox = False,
    seenDivGuard = False,
    seenArities = [],
  }
  let tops = filterList (b => bindName b /= "main") groups
  let sc = DemandScope {
    locals = omEmpty,
    topFns =
      omFromNames
        (map bindName (filterList (b => not (isValBind b)) tops))
        omEmpty,
    topVals = omFromNames (map bindName (filterList isValBind tops)) omEmpty,
    jsBinds = jsBinds,
    externFacts = externFacts,
  }
  let acc = walkEach (dImpl sc) (walkEach (dBind sc) start groups) impls
  (
    WasmDemand {
      uses = reverseL acc.seenUses,
      refBox = acc.seenRefBox,
      divGuard = acc.seenDivGuard,
      tupleArities = reverseL acc.seenArities,
    },
    omKeys acc.seenKeys,
    filterMap (k => omLookup k acc.seenJs) (omKeys acc.seenJs),
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
noteName acc "$withFileReadBound" = noteFileBound acc
noteName acc "$withFileWriteBound" = noteFileBound acc
noteName acc name =
  let acc = match wasmFamily name
    Some WasmRefCell => noteRefBox acc
    _ => acc
  walkEach
    noteArity
    (walkEach
      noteKey
      (walkEach noteUse acc (wasmUses name))
      (wasmHostKeys name))
    (wasmTupleArities name)

-- a name the emitter lowers as an extern: a user `js` binding, else a catalog
-- extern
noteExtern : DemandScope -> DemandAcc -> String -> DemandAcc
noteExtern sc acc name = match omLookup name sc.jsBinds
  None => match externRuntimeKey sc.externFacts name
    Some key => noteName acc key
    None =>
      if name == "$withFileReadBound" || name == "$withFileWriteBound" then
        noteFileBound acc
      else
        acc
  Some (js, (params, result)) =>
    if omHasKey name acc.seenJs then
      acc
    else
      let imp = JsImport {
        medakaName = name,
        jsName = js,
        params = params,
        result = result,
      }
      noteJsResult
        (walkEach
          noteJsParam
          { acc | seenJs = omInsert name imp acc.seenJs }
          params)
        result

-- What one parameter head of a `js` import needs (WASM-SEMANTICS section 3.1): a
-- `String` or `Array` crosses on the path channel, an `Array` comes back on the
-- result channel, and a boxed head needs its type.
noteJsParam : DemandAcc -> String -> DemandAcc
noteJsParam acc "String" = walkEach noteKey (noteUse acc UseStr) jsPathKeys
noteJsParam acc "Array" =
  walkEach noteKey (noteUse acc UseArray) (jsPathKeys ++ jsResultKeys)
noteJsParam acc head = noteJsBoxed acc head

-- What a `js` import's result head needs: a `String` comes back on the result
-- channel.
noteJsResult : DemandAcc -> String -> DemandAcc
noteJsResult acc "String" = walkEach noteKey (noteUse acc UseStr) jsResultKeys
noteJsResult acc head = noteJsBoxed acc head

noteJsBoxed : DemandAcc -> String -> DemandAcc
noteJsBoxed acc "Float" = noteUse acc UseFloat
noteJsBoxed acc "U64" = noteUse acc UseU64
noteJsBoxed acc "I64" = noteUse acc UseI64
noteJsBoxed acc _ = acc

jsPathKeys : List String
jsPathKeys = ["mdk_path_reset", "mdk_path_push"]

jsResultKeys : List String
jsResultKeys = ["mdk_result_len", "mdk_result_byte"]

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

-- the emitter's value-global partition (`isValBind` in wasm_emit.mdk)
isValBind : CBind -> Bool
isValBind (CBind name [CClause [] _] _ _) = name /= "main"
isValBind _ = False

-- [sc] with every variable [pats] bind in scope
bindIn : DemandScope -> List Pat -> DemandScope
bindIn sc pats = match patVarsList pats
  [] => sc
  names => { sc | locals = omFromNames names sc.locals }

isLocal : DemandScope -> String -> Bool
isLocal sc x = omHasKey x sc.locals

isCoreFn : DemandScope -> String -> Bool
isCoreFn sc x = omHasKey ("core__" ++ x) sc.topFns

-- a name read as a value
dVar : DemandScope -> DemandAcc -> String -> DemandAcc
dVar sc acc x =
  if isLocal sc x
    || omHasKey x sc.topVals
    || omHasKey x sc.topFns
    || isCoreFn sc x then
    acc
  else
    noteExtern sc acc x

dBind : DemandScope -> DemandAcc -> CBind -> DemandAcc
dBind sc acc (CBind _ clauses _ _) = walkEach (dClause sc) acc clauses

-- a clause's parameter patterns, then its body with them in scope
dClause : DemandScope -> DemandAcc -> CClause -> DemandAcc
dClause sc acc (CClause pats body) =
  dExpr (bindIn sc pats) (walkEach dPat acc pats) body

dImpl : DemandScope -> DemandAcc -> CImplEntry -> DemandAcc
dImpl sc acc (CImplEntry _ _ _ (CImplTagged _ _ _ _ _ pats b)) =
  dExpr (bindIn sc pats) (walkEach dPat acc pats) b
dImpl sc acc (CImplEntry _ _ _ (CImplDefault _ _ _ _ _ pats b)) =
  dExpr (bindIn sc pats) (walkEach dPat acc pats) b

dExpr : DemandScope -> DemandAcc -> CExpr -> DemandAcc
dExpr sc acc (CList es) = walkEach (dExpr sc) (noteUse acc UseList) es
dExpr sc acc (CRangeList lo hi _) =
  dExpr sc (dExpr sc (noteUse acc UseList) lo) hi
dExpr sc acc (CTuple es) = walkEach (dExpr sc) (noteArity acc (listLen es)) es
dExpr sc acc (CArray es) = walkEach (dExpr sc) (noteUse acc UseArray) es
dExpr sc acc (CRangeArray lo hi _) =
  dExpr sc (dExpr sc (noteUse acc UseArray) lo) hi
dExpr sc acc (CIndex a i) = dExpr sc (dExpr sc (noteUse acc UseArray) a) i
dExpr sc acc (CSlice a lo hi _) =
  dExpr sc (dExpr sc (dExpr sc (noteUse acc UseArray) a) lo) hi
dExpr sc acc (CRecord _ fields) = walkEach (dField sc) acc fields
dExpr sc acc (CFieldAccess ex _ _ _) = dExpr sc acc ex
dExpr sc acc (CRecordUpdate _ base fields) =
  walkEach (dField sc) (dExpr sc acc base) fields
dExpr sc acc (CVariantUpdate _ base fields) =
  walkEach (dField sc) (dExpr sc acc base) fields
dExpr sc acc (app@(CApp _ _ _)) =
  let (hd, args) = flattenApp app []
  walkEach (dExpr sc) (dAppHead sc acc hd) args
dExpr sc acc (CVar x _) = dVar sc acc x
dExpr _ acc (CLit (LFloat _)) = noteUse acc UseFloat
dExpr _ acc (CLit (LU64 _ _)) = noteUse acc UseU64
dExpr _ acc (CLit (LI64 _ _)) = noteUse acc UseI64
dExpr _ acc (CLit (LString _)) = noteUse acc UseStr
dExpr _ acc (CLit (LChar _)) = noteUse acc UseStr
dExpr sc acc (CLam pats b) = dExpr (bindIn sc pats) acc b
dExpr sc acc (CBinPrim op l r tag _) =
  dExpr sc (dExpr sc (noteBinop (noteTag acc tag) op) l) r
dExpr sc acc (CUnOp _ x) = dExpr sc acc x
dExpr sc acc (CIf c t f) = dExpr sc (dExpr sc (dExpr sc acc c) t) f
dExpr sc acc (CLet r pat a b) =
  let inner = bindIn sc [pat]
  dExpr inner (dExpr (if r then inner else sc) (dPat acc pat) a) b
dExpr sc acc (CBlock stmts) = dStmts sc acc stmts
dExpr sc acc (CDecision scrut arms tree) =
  dTree (walkEach (dArm sc) (dExpr sc acc scrut) arms) tree
dExpr sc acc (CMatch scrut arms) = walkEach (dArm sc) (dExpr sc acc scrut) arms
dExpr sc acc (CLetGroup binds b) =
  let inner = { sc | locals = omFromNames (map bindName binds) sc.locals }
  dExpr inner (walkEach (dBind inner) acc binds) b
dExpr _ acc _ = acc

-- an applied name: a local is a closure call, a `core__` function a call to it
dAppHead : DemandScope -> DemandAcc -> CExpr -> DemandAcc
dAppHead sc acc (CVar f _) =
  if isLocal sc f || not (omHasKey f sc.topFns) && isCoreFn sc f then
    acc
  else
    noteExtern sc acc f
dAppHead sc acc h = dExpr sc acc h

dField : DemandScope -> DemandAcc -> CField -> DemandAcc
dField sc acc (CField _ _ e) = dExpr sc acc e

-- an arm's pattern binds its guards and body; a `Pat <- e` guard binds the
-- guards after it and the body
dArm : DemandScope -> DemandAcc -> CArm -> DemandAcc
dArm sc acc (CArm pat guards body) =
  dGuarded (bindIn sc [pat]) (dPat acc pat) guards body

dGuarded : DemandScope -> DemandAcc -> List CGuard -> CExpr -> DemandAcc
dGuarded sc acc [] body = dExpr sc acc body
dGuarded sc acc ((CGBool g) :: rest) body =
  dGuarded sc (dExpr sc acc g) rest body
dGuarded sc acc ((CGBind p e) :: rest) body =
  dGuarded (bindIn sc [p]) (dExpr sc (dPat acc p) e) rest body

-- a block's `let` binds the statements after it, and its own right side when
-- it is `rec`
dStmts : DemandScope -> DemandAcc -> List CStmt -> DemandAcc
dStmts _ acc [] = acc
dStmts sc acc ((CSExpr e) :: rest) = dStmts sc (dExpr sc acc e) rest
dStmts sc acc ((CSLet r pat e) :: rest) =
  let inner = bindIn sc [pat]
  dStmts inner (dExpr (if r then inner else sc) (dPat acc pat) e) rest
dStmts sc acc ((CSAssign _ e) :: rest) = dStmts sc (dExpr sc acc e) rest

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

-- ── W6: does the program use strings? ────────────────────────────────────────
-- True if any body contains a String/Char literal, or applies an extern whose
-- catalog wasm family is `WasmStr` (intToString/putStrLn/stringConcat/…).  Any of
-- these forces the §3.3 $str rep + the byte-write runtime + ref-mode.  Detected
-- structurally over every clause body.
-- Local spellings retain legacy mode eligibility; extern binding uses facts.
programUsesStr : OrdMap ExternDeclFact -> List CBind -> Bool
programUsesStr facts groups = anyBind (bindUsesStr facts) groups

bindUsesStr : OrdMap ExternDeclFact -> CBind -> Bool
bindUsesStr facts (CBind _ clauses _ _) =
  anyList (c => exprUsesStr facts (clauseBodyOf c)) clauses

exprUsesStr : OrdMap ExternDeclFact -> CExpr -> Bool
exprUsesStr _ (CLit (LString _)) = True
exprUsesStr _ (CLit (LChar _)) = True
exprUsesStr _ (CLit _) = False
exprUsesStr facts (CVar symbol AGlobal) =
  isStrModeNameW symbol
    || (match externRuntimeKey facts symbol
      Some key => isStrModeNameW key
      None => False)
exprUsesStr _ (CVar symbol _) = isStrModeNameW symbol
exprUsesStr facts (app@(CApp _ _ _)) =
  let (hd, args) = flattenApp app []
  headUsesStr facts hd || anyList (exprUsesStr facts) args
exprUsesStr facts (CLam _ b) = exprUsesStr facts b
exprUsesStr facts (CBinPrim _ l r _ _) =
  exprUsesStr facts l || exprUsesStr facts r
exprUsesStr facts (CUnOp _ x) = exprUsesStr facts x
exprUsesStr facts (CIf c t f) =
  exprUsesStr facts c || exprUsesStr facts t || exprUsesStr facts f
exprUsesStr facts (CLet _ _ a b) = exprUsesStr facts a || exprUsesStr facts b
exprUsesStr facts (CBlock stmts) = anyList (stmtUsesStr facts) stmts
exprUsesStr facts (CDecision scrut arms _) =
  exprUsesStr facts scrut || anyList (a => exprUsesStr facts (armBody a)) arms
exprUsesStr facts (CMatch scrut arms) =
  exprUsesStr facts scrut || anyList (a => exprUsesStr facts (armBody a)) arms
exprUsesStr _ _ = False

stmtUsesStr : OrdMap ExternDeclFact -> CStmt -> Bool
stmtUsesStr facts (CSExpr e) = exprUsesStr facts e
stmtUsesStr facts (CSLet _ _ e) = exprUsesStr facts e
stmtUsesStr _ _ = False

headUsesStr : OrdMap ExternDeclFact -> CExpr -> Bool
headUsesStr facts h = exprUsesStr facts h

isStrModeNameW : String -> Bool
isStrModeNameW name = match wasmFamily name
  Some WasmStr => True
  _ => False

bindUsesClosures : OrdMap Unit -> List (String, Int) -> CBind -> Bool
bindUsesClosures fnNames ctorArs (CBind _ clauses _ _) =
  multiOrPatternClauses clauses
    || anyList (clauseUsesClosures fnNames ctorArs) clauses

-- a fn binding needs clause-dispatch coalescing (W4) if it has >1 clause or any
-- non-PVar/PWild parameter (an inner-match on the args).
multiOrPatternClauses : List CClause -> Bool
multiOrPatternClauses [] = False
multiOrPatternClauses [CClause pats _] =
  anyList (p => not (isPlainParam p)) pats
multiOrPatternClauses _ = True

isPlainParam : Pat -> Bool
isPlainParam (PVar _ _ _) = True
isPlainParam PWild = True
isPlainParam _ = False

clauseUsesClosures : OrdMap Unit -> List (String, Int) -> CClause -> Bool
clauseUsesClosures fnNames ctorArs (CClause pats body) =
  exprUsesClosures fnNames ctorArs (flatMap patVars pats) body

-- a CLam anywhere; an application whose head is not a saturated known-fn/ctor call;
-- a bare CVar referencing a top-level fn in NON-call (value) position.
-- `locals` = the in-scope LOCALLY-BOUND names (clause params, let/lambda binders).
-- A CVar matching a local SHADOWS any same-named top-level fn / ctor, so applying it
-- is an INDIRECT (closure) call — the analysis MUST agree with emitAppRef/emitTailCallW's
-- `contains f0 env`-first guard, else a shadowing-local call (`applyEq eq x y = eq x y`
-- with a top-level `eq` in scope) is mis-judged "saturated direct call, no closure" and
-- the closure types are never emitted though emit uses them (parse/validate failure).
exprUsesClosures : OrdMap Unit ->
  List (String, Int) ->
  List String ->
  CExpr ->
  Bool
exprUsesClosures fnNames ctorArs locals (CLam _ _) = True
exprUsesClosures fnNames ctorArs locals (app@(CApp _ _ _)) =
  appUsesClosures fnNames ctorArs locals app
exprUsesClosures fnNames ctorArs locals (CVar x _) =
  not (contains x locals) && fnMemberIndexW fnNames x
exprUsesClosures fnNames ctorArs locals (CLit _) = False
exprUsesClosures fnNames ctorArs locals (CBinPrim _ l r _ _) =
  exprUsesClosures fnNames ctorArs locals l
    || exprUsesClosures fnNames ctorArs locals r
exprUsesClosures fnNames ctorArs locals (CUnOp _ x) =
  exprUsesClosures fnNames ctorArs locals x
exprUsesClosures fnNames ctorArs locals (CIf c t f) =
  exprUsesClosures fnNames ctorArs locals c
    || exprUsesClosures fnNames ctorArs locals t
    || exprUsesClosures fnNames ctorArs locals f
exprUsesClosures fnNames ctorArs locals (CLet _ pat a b) =
  exprUsesClosures fnNames ctorArs locals a
    || exprUsesClosures fnNames ctorArs (patVars pat ++ locals) b
exprUsesClosures fnNames ctorArs locals (CBlock stmts) =
  blockUsesClosures fnNames ctorArs locals stmts
exprUsesClosures fnNames ctorArs locals (CDecision scrut arms _) =
  exprUsesClosures fnNames ctorArs locals scrut
    || anyList (a => exprUsesClosures fnNames ctorArs locals (armBody a)) arms
exprUsesClosures fnNames ctorArs locals (CMatch scrut arms) =
  exprUsesClosures fnNames ctorArs locals scrut
    || anyList (a => exprUsesClosures fnNames ctorArs locals (armBody a)) arms
exprUsesClosures fnNames ctorArs locals _ = False

-- thread let-bound names through a block so a later statement's shadowing local is seen.
blockUsesClosures : OrdMap Unit ->
  List (String, Int) ->
  List String ->
  List CStmt ->
  Bool
blockUsesClosures _ _ _ [] = False
blockUsesClosures fnNames ctorArs locals ((CSLet _ pat e) :: rest) =
  exprUsesClosures fnNames ctorArs locals e
    || blockUsesClosures fnNames ctorArs (patVars pat ++ locals) rest
blockUsesClosures fnNames ctorArs locals ((CSExpr e) :: rest) =
  exprUsesClosures fnNames ctorArs locals e
    || blockUsesClosures fnNames ctorArs locals rest
blockUsesClosures fnNames ctorArs locals (_ :: rest) =
  blockUsesClosures fnNames ctorArs locals rest

-- an application uses closures unless it is a saturated direct call to a known
-- top-level fn (exact arity) or a ctor application.  Over/under application of a
-- known fn, or a non-variable / non-fn / non-ctor head, is a closure use.  The args
-- are also scanned (a saturated call passing a lambda is still a closure use).
appUsesClosures : OrdMap Unit ->
  List (String, Int) ->
  List String ->
  CExpr ->
  Bool
appUsesClosures fnNames ctorArs locals app =
  let (hd, args, mode) = appParts app
  let argsClos = anyList (exprUsesClosures fnNames ctorArs locals) args
  match hd
    CVar f _ =>
      if contains f locals then
        True  -- a shadowing local/param head → indirect (closure) call
      else if fnMemberIndexW fnNames f then
        not (isExactCall mode) || argsClos
      else if isSome (lookupAssoc f ctorArs) || isReservedCtor f then
        argsClos
      else
        True  -- a local/param/let-bound head → an indirect (closure) call
    _ => True

-- a program uses ADTs if it has any user constructor (the ctor table is non-empty
-- once a `data` decl exists) OR any `CDecision` in any body.  The reserved
-- Option/Result/Ordering ctors only enter the table when actually used, and a
-- bare scalar program (the W2 corpus) has an empty ctor table + no CDecision.
programUsesAdt : List CBind -> List (String, Int) -> Bool
programUsesAdt groups ctorArs =
  listLen ctorArs /= 0 || anyBindHasDecision groups

anyBindHasDecision : List CBind -> Bool
anyBindHasDecision [] = False
anyBindHasDecision ((CBind _ clauses _ _) :: rest) =
  if anyClauseHasDecision clauses then True else anyBindHasDecision rest

anyClauseHasDecision : List CClause -> Bool
anyClauseHasDecision [] = False
anyClauseHasDecision ((CClause _ body) :: rest) =
  if exprHasDecision body then True else anyClauseHasDecision rest

exprHasDecision : CExpr -> Bool
exprHasDecision (CDecision _ _ _) = True
exprHasDecision (CMatch _ _) = True
exprHasDecision (CIf c t f) =
  exprHasDecision c || exprHasDecision t || exprHasDecision f
exprHasDecision (CLet _ _ a b) = exprHasDecision a || exprHasDecision b
exprHasDecision (CBinPrim _ a b _ _) = exprHasDecision a || exprHasDecision b
exprHasDecision (CUnOp _ a) = exprHasDecision a
exprHasDecision (CApp f args _) =
  exprHasDecision f || anyList exprHasDecision args
exprHasDecision (CBlock stmts) = anyList stmtHasDecision stmts
exprHasDecision _ = False

stmtHasDecision : CStmt -> Bool
stmtHasDecision (CSExpr e) = exprHasDecision e
stmtHasDecision (CSLet _ _ e) = exprHasDecision e
stmtHasDecision _ = False

anyBind : (CBind -> Bool) -> List CBind -> Bool
anyBind _ [] = False
anyBind p (b :: rest) = p b || anyBind p rest

fnMemberIndexW : OrdMap Unit -> String -> Bool
fnMemberIndexW names n = omHasKey n names

isReservedCtor : String -> Bool
isReservedCtor n = contains n ["Some", "None", "Ok", "Err", "Lt", "Eq", "Gt"]

public export data WasmTypeContext = WasmTypeContext {
  rows : OrdMap BinderRow,
  tops : OrdMap BinderRow,
  fnNames : OrdMap Unit,
  valNames : OrdMap Unit,
  externFacts : OrdMap ExternDeclFact,
  ctorFloatFields : OrdMap (List Int),
  ctorArities : List (String, Int),
}

export
wasmTypeContext : OrdMap (List Int) -> CProgram -> WasmTypeContext
wasmTypeContext ctorFields (CProgram groups ctorArs _ _ _ facts) =
  let rows =
    omFromPairs
      (reverseL
        (map
          (row => (intToString (binderOrdinal row.brId), row))
          facts.factBinders))
      omEmpty
  WasmTypeContext {
    rows = rows,
    tops =
      omFromPairs
        (reverseL
          (filterMap
            ((CBind n _ _ bid) =>
              map
                (row => (n, row))
                (omLookup (intToString (binderOrdinal bid)) rows))
            groups))
        omEmpty,
    fnNames =
      omFromNames
        (map
          bindName
          (filterList (b => bindName b /= "main" && not (isValBind b)) groups))
        omEmpty,
    valNames =
      omFromNames
        (map
          bindName
          (filterList (b => bindName b /= "main" && isValBind b) groups))
        omEmpty,
    externFacts = facts.factExterns,
    ctorFloatFields = ctorFields,
    ctorArities = ctorArs,
  }

runtimeKeyD : WasmTypeContext -> String -> String
runtimeKeyD ctx symbol = optionOr "" (externRuntimeKey ctx.externFacts symbol)

-- the env entry that says the local `x` is the binder with ordinal [bid]'s
export
envMark : String -> BinderId -> String
envMark x bid = "\{x}@\{intToString (binderOrdinal bid)}"

-- [env] extended with the stamped binder [x]
export
envBind : String -> BinderId -> List String -> List String
envBind x bid env = x :: envMark x bid :: env

-- the env entries of a function's plain parameters, in order
export
paramEnv : List Pat -> List String
paramEnv pats = flatMap paramEntries pats

export
paramEntries : Pat -> List String
paramEntries (PVar x _ bid) = [x, envMark x bid]
paramEntries _ = ["_"]

-- every variable a pattern binds, with its id
export
patBinders : Pat -> List (String, BinderId)
patBinders (PVar x _ bid) = [(x, bid)]
patBinders (PAs x _ bid p) = (x, bid) :: patBinders p
patBinders (PCon _ args) = flatMap patBinders args
patBinders (PTuple ps) = flatMap patBinders ps
patBinders (PCons h t) = patBinders h ++ patBinders t
patBinders (PList ps) = flatMap patBinders ps
patBinders _ = []

-- [env] extended with every variable [pat] binds
export
envBindPat : Pat -> List String -> List String
envBindPat pat env =
  fold (acc b => envBind (fst b) (snd b) acc) env (patBinders pat)

-- the entries of [env] that name the binders behind [names], for a lifted body
-- that captures them
export
envMarksOf : List String -> List String -> List String
envMarksOf names env = flatMap (x => envMarkOf x env) names

-- [names] as env entries, each followed by its entry in [marks] when it has one
export
envWithMarks : List String -> List String -> List String
envWithMarks names marks =
  flatMap (x => x :: filterList (startsWith "\{x}@") marks) names

export
envMarkOf : String -> List String -> List String
envMarkOf x env = match envLookup x env
  LocalBinder ord => ["\{x}@\{ord}"]
  _ => []

-- what a name denotes inside `env`
public export data EnvRef = NotLocal | LocalUnstamped | LocalBinder String

export
envLookup : String -> List String -> EnvRef
envLookup _ [] = NotLocal
envLookup x (e :: rest) =
  if e == x then match rest
    m :: _ =>
      if startsWith "\{x}@" m then
        LocalBinder (stringSlice (stringLength x + 1) (stringLength m) m)
      else
        LocalUnstamped
    [] => LocalUnstamped
  else
    envLookup x rest

stampRowOf : WasmTypeContext -> String -> Option BinderRow
stampRowOf prog ord = omLookup ord prog.rows

-- the stamp row of the binder a reference to [x] reaches: its local binder when
-- [x] is bound in [env], else the top-level binding of that name
export
varRow : WasmTypeContext -> List String -> String -> Option BinderRow
varRow prog env x = match envLookup x env
  LocalBinder ord => stampRowOf prog ord
  LocalUnstamped => None
  NotLocal => omLookup x prog.tops

-- what a reference to [x] holds; RTValue where no row states it
export
varStamp : WasmTypeContext -> List String -> String -> RuntimeType
varStamp prog env x = match varRow prog env x
  Some row => row.brType
  None => RTValue

-- what a call to [fn] returns once saturated: its return stamp, or for a runtime
-- extern (a name no binder in the program has) the result type its declaration in
-- `stdlib/runtime.mdk` gives
export
returnStamp : WasmTypeContext -> List String -> String -> RuntimeType
returnStamp prog env fn = match varRow prog env fn
  Some row => optionOr RTValue row.brReturns
  None =>
    if contains fn env
      || omHasKey fn prog.fnNames
      || omHasKey fn prog.valNames then
      RTValue
    else
      externResultStamp (runtimeKeyD prog fn)

-- The result type of the runtime extern [fn], for the externs whose result
-- decides how a value is printed or computed on.  RTValue where it is none of
-- them.
externResultStamp : String -> RuntimeType
externResultStamp fn =
  if contains fn [
    "intToString",
    "charToStr",
    "stringConcat",
    "stringSlice",
    "stringToUpper",
    "stringToLower",
    "floatToString",
    "stringFromChars",
    "stringFromUtf8Bytes",
  ] then
    RTString
  else if contains fn [
    "randomBool",
    "charIsAlpha",
    "charIsSpace",
    "charIsUpper",
    "charIsLower",
    "charIsPunct",
  ] then
    RTBool
  else if contains fn ["randomChar", "charToUpper", "charToLower"] then
    RTChar
  else if contains fn ["intToFloat", "randomFloat"] then
    RTFloat
  else if contains fn [
    "putStr", "putStrLn", "ePutStr", "ePutStrLn", "flushStdout"
  ] then
    RTUnit
  else
    RTValue

-- The static type of [e], read off stamped Core without emitting it: a literal
-- states its own type, a variable its binder's stamp, an operator node its
-- stamped scalar tag (or its operands'), and a saturated call its callee's
-- return stamp.  RTValue where nothing states it.
export
cexprStamp : WasmTypeContext -> List String -> CExpr -> RuntimeType
cexprStamp _ _ (CLit l) = litRuntimeType l
cexprStamp _ _ (CVar "True" _) = RTBool
cexprStamp _ _ (CVar "False" _) = RTBool
cexprStamp prog env (CVar x _) =
  if runtimeKeyD prog x == "pi" || runtimeKeyD prog x == "e" then
    RTFloat
  else
    varStamp prog env x
cexprStamp prog env (CBinPrim op l r tag _) =
  if isCmpOp op then
    RTBool
  else if op == "::" then
    RTCon
  else if isArithOp op then
    arithStamp prog env tag l r
  else
    appendStamp (cexprStamp prog env l) (cexprStamp prog env r)
cexprStamp prog env (CUnOp "-" x) = cexprStamp prog env x
cexprStamp prog env (CIf _ t f) =
  stampOrElse (cexprStamp prog env t) (cexprStamp prog env f)
cexprStamp prog env (CLet _ pat _ b) = cexprStamp prog (envBindPat pat env) b
cexprStamp prog env (CLetGroup binds b) =
  cexprStamp prog (envBindGroups binds env) b
cexprStamp prog env (CBlock stmts) = blockStamp prog env stmts
cexprStamp prog env (CDecision _ arms _) = armsStamp prog env arms
cexprStamp prog env (CMatch _ arms) = armsStamp prog env arms
cexprStamp prog env (app@(CApp _ _ (CallSite mode _))) = match mode
  CallPartial _ => RTValue
  CallOver _ => RTValue
  _ => match appHead app
    CVar fn _ => returnStamp prog env fn
    CDict fn _ => returnStamp prog env fn
    _ => RTValue
cexprStamp prog _ (CFieldAccess _ _ recName ord) =
  if ord >= 0
    && any (== ord) (optionOr [] (omLookup recName prog.ctorFloatFields)) then
    RTFloat
  else
    RTValue
cexprStamp _ _ _ = RTValue

-- `++` appends two Strings or two Lists.  Where neither operand states which,
-- the result prints as a String: a List-valued `main` has no print.
appendStamp : RuntimeType -> RuntimeType -> RuntimeType
appendStamp RTValue RTValue = RTString
appendStamp a RTValue = a
appendStamp _ b = b

-- the arithmetic result of two operands: the typechecker's scalar tag where it
-- states one, else a Float operand makes a Float result
arithStamp : WasmTypeContext ->
  List String ->
  String ->
  CExpr ->
  CExpr ->
  RuntimeType
arithStamp prog env tag l r =
  if tag == "Float" then
    RTFloat
  else if tag == "U64" then
    RTU64
  else if tag == "I64" then
    RTI64
  else if isTaggedFixedHead tag then
    RTInt
  else
    stampOrElse (cexprStamp prog env l) (cexprStamp prog env r)

-- [a] where it states a type, else [b]
stampOrElse : RuntimeType -> RuntimeType -> RuntimeType
stampOrElse RTValue b = b
stampOrElse a _ = a

export
envBindGroup : CBind -> List String -> List String
envBindGroup (CBind name _ _ bid) env = envBind name bid env

export
envBindGroups : List CBind -> List String -> List String
envBindGroups binds env = fold (acc g => envBindGroup g acc) env binds

-- the env entry naming a let-group member's binder
export
groupBindMark : CBind -> String
groupBindMark (CBind name _ _ bid) = envMark name bid

blockStamp : WasmTypeContext -> List String -> List CStmt -> RuntimeType
blockStamp _ _ [] = RTValue
blockStamp prog env [CSExpr e] = cexprStamp prog env e
blockStamp prog env ((CSLet _ pat _) :: rest) =
  blockStamp prog (envBindPat pat env) rest
blockStamp prog env (_ :: rest) = blockStamp prog env rest

armsStamp : WasmTypeContext -> List String -> List CArm -> RuntimeType
armsStamp _ _ [] = RTValue
armsStamp prog env ((CArm pat _ body) :: rest) =
  stampOrElse
    (cexprStamp prog (envBindPat pat env) body)
    (armsStamp prog env rest)

export
isPolyNumBinop : WasmTypeContext -> List String -> CExpr -> CExpr -> Bool
isPolyNumBinop prog env l r =
  isPolyNumOperand prog env l || isPolyNumOperand prog env r

isPolyNumOperand : WasmTypeContext -> List String -> CExpr -> Bool
isPolyNumOperand prog env (CVar x _) = match varRow prog env x
  Some row => row.brType == RTValue
  None => False
isPolyNumOperand _ _ _ = False

isArithOp : String -> Bool
isArithOp op = contains op ["+", "-", "*", "/", "%"]

export
isCmpOp : String -> Bool
isCmpOp op = contains op ["==", "/=", "<", ">", "<=", ">="]

appHead : CExpr -> CExpr
appHead (CApp f _ _) = appHead f
appHead e = e

public export data WasmDemandInputs = WasmDemandInputs {
  ctorFloatFields : OrdMap (List Int),
  lazyGlobals : List String,
  globalInit : GlobalInitPlan,
  trmcVerdicts : TrmcVerdicts,
  dispatchGroups : List DispGroup,
}

public export data PlannedImport = PlannedImport {
  namespace : String,
  field : String,
  watSymbol : String,
  signature : String,
} deriving (Eq, Debug)

public export data WasmDemandPlan = WasmDemandPlan {
  sourceDemand : WasmDemand,
  sourceHostKeys : List String,
  jsImports : List JsImport,
  useRef : Bool,
  useClos : Bool,
  stringOps : Bool,
  representation : WasmDemand,
  representationTypes : List String,
  helpers : List String,
  intHelpers : List String,
  censusHelpers : List String,
  censusIntHelpers : List String,
  siteRuntime : Bool,
  nonexhaustiveRuntime : Bool,
  imports : List PlannedImport,
  catalogFamilies : List (String, WasmFamily),
}

data HelperAcc = HelperAcc {
  helpers : OrdMap Unit,
  ints : OrdMap Unit,
  site : Bool,
  nonexh : Bool,
  patternTuples : OrdMap Int,
  patternList : Bool,
  refRead : Bool,
}

emptyHelpers : HelperAcc
emptyHelpers = HelperAcc {
  helpers = omEmpty,
  ints = omEmpty,
  site = False,
  nonexh = False,
  patternTuples = omEmpty,
  patternList = False,
  refRead = False,
}

need : HelperAcc -> String -> HelperAcc
need acc name = { acc | helpers = omInsert name () acc.helpers }

needMany : HelperAcc -> List String -> HelperAcc
needMany = fold need

needTrap : HelperAcc -> HelperAcc
needTrap acc = need acc "stderrByteImportLines"

needSite : HelperAcc -> HelperAcc
needSite acc = { needMany acc ["siteRuntimeLines", "trapIntRuntimeLines", "stderrByteImportLines"] |
  site = True,
}

needInt : HelperAcc -> String -> HelperAcc
needInt acc name = { needSite (need acc "intRuntimeLines") |
  ints = omInsert name () acc.ints,
}

export
wasmFamilyTag : WasmFamily -> String
wasmFamilyTag WasmStr = "str"
wasmFamilyTag WasmLeaf = "leaf"
wasmFamilyTag WasmArray = "array"
wasmFamilyTag WasmByteBlock = "bytes"
wasmFamilyTag WasmRefCell = "ref"
wasmFamilyTag WasmConstant = "constant"
wasmFamilyTag WasmFallthrough = "fallthrough"

catalogFamilies : ExternRequirements -> List (String, WasmFamily)
catalogFamilies req =
  filterMap
    (row => match row.selectedBinding
      RuntimeRequirement key => map (family => (key, family)) (wasmFamily key)
      _ => None)
    req.rows

export
planWasmDemand : WasmDemandInputs ->
  CProgram ->
  ExternRequirements ->
  WasmDemandPlan
planWasmDemand inputs (cp@(CProgram groups ctorArs _ impls _ facts)) req =
  let (source, hostKeys, _) =
    wasmDemandOf
      (requirementFacts req)
      (omFromPairs (reverseL (requirementHostRows req)) omEmpty)
      groups
      impls
  let js =
    map
      ((symbol, (host, (params, result))) => JsImport {
        medakaName = symbol,
        jsName = host,
        params = params,
        result = result,
      })
      (requirementHostRows req)
  let str =
    programUsesStr facts.factExterns groups
      || hasUse source UseStr
      || hasUse source UseFloat
  let ctx = wasmTypeContext inputs.ctorFloatFields cp
  let clos = anyBind (bindUsesClosures ctx.fnNames ctorArs) groups
  let refMode =
    isNonEmptyL inputs.lazyGlobals
      || clos
      || programUsesAdt groups ctorArs
      || isNonEmptyL impls
      || str
      || source.refBox
      || isNonEmptyL source.tupleArities
      || any (hasUse source) [
        UseList, UseArray, UseRng, UseHash, UseFloat, UseU64, UseI64,
        UseStrSearch, UseCharClass
      ]
      || isNonEmptyL hostKeys
      || isNonEmptyL js
  let roots = need emptyHelpers "ioRuntimeLines"
  let roots =
    if refMode then sourceRoots source str clos hostKeys js roots else roots
  let roots = fold (hBind ctx refMode str) roots groups
  let roots = fold (hImpl ctx refMode str) roots impls
  let roots = if refMode then implFailureRoots roots impls else roots
  let roots =
    if refMode && isNonEmptyL inputs.lazyGlobals then needTrap roots else roots
  let roots =
    if refMode then
      printRoots ctx facts.factEntryOutcome groups roots
    else
      roots
  let families = catalogFamilies req
  let closed = closeHelpers (hasUse source UseI64) roots
  let census =
    if refMode then
      closed
    else
      closeHelpers
        (hasUse source UseI64)
        (fold
          (hImpl ctx True str)
          (fold (hBind ctx True str) closed groups)
          impls)
  let renderClos = clos || omHasKey "closApplyLines" closed.helpers
  let representation = representationOf source str closed
  let imports = physicalImports closed hostKeys js
  WasmDemandPlan {
    sourceDemand = source,
    sourceHostKeys = hostKeys,
    jsImports = js,
    useRef = refMode,
    useClos = renderClos,
    stringOps = str,
    representation = representation,
    representationTypes = physicalTypes cp refMode renderClos representation,
    helpers = omKeys closed.helpers,
    intHelpers = omKeys closed.ints,
    censusHelpers = omKeys census.helpers,
    censusIntHelpers = omKeys census.ints,
    siteRuntime = closed.site,
    nonexhaustiveRuntime = closed.nonexh,
    imports = imports,
    catalogFamilies = families,
  }

hasUse : WasmDemand -> WasmUse -> Bool
hasUse demand u = any (== u) demand.uses

sourceRoots : WasmDemand ->
  Bool ->
  Bool ->
  List String ->
  List JsImport ->
  HelperAcc ->
  HelperAcc
sourceRoots source str clos keys js acc =
  let acc = if clos then need acc "closApplyLines" else acc
  let acc = if str then need acc "ioStrRuntimeLines" else acc
  let acc =
    fold
      (a (u, block) => if hasUse source u then need a block else a)
      acc
      [
        (UseStrLeaf, "strLeafRuntimeLines"),
        (UseRng, "rngRuntimeLines"),
        (UseHash, "hashRuntimeLines"),
        (UseFloatHash, "hashFloatRuntimeLines"),
        (UseFloatRng, "randomFloatRuntimeLines"),
        (UseFloat, "floatRuntimeLines"),
        (UseU64, "u64RuntimeLines"),
        (UseI64, "i64RuntimeLines"),
        (UseStrSearch, "strSearchRuntimeLines"),
        (UseStrToInt, "strToIntRuntimeLines"),
        (UseStrReverse, "strReverseRuntimeLines"),
        (UseStrJoin, "strJoinRuntimeLines"),
        (UseStrCodec, "strCodecRuntimeLines"),
        (UseByteBlock, "byteBlockRuntimeLines"),
        (UseCharFromCode, "charFromCodeRuntimeLines"),
        (UseCharClass, "charClassRuntimeLines"),
        (UseEPut, "stderrRuntimeLines"),
      ]
  let acc =
    if hasUse source UseStrLeaf && hasUse source UseList then
      needMany acc ["strConcatRuntimeLines", "appendRuntimeLines"]
    else
      acc
  let acc =
    if hasUse source UseHash && str then
      need acc "hashStringRuntimeLines"
    else
      acc
  let acc =
    if hasUse source UseFloat then need acc "floatRemRuntimeLines" else acc
  let acc =
    fold
      (a (key, block) => if contains key keys then need a block else a)
      acc
      hostHelperRoots
  let acc =
    if contains "mdk_file_exists" keys
      || contains "mdk_canonicalize_path" keys
      || contains "mdk_os_entropy" keys then
      need acc "ioRefusedPanicLines"
    else
      acc
  let acc =
    if contains "mdk_os_entropy" keys then need acc "osEntropyLines" else acc
  let acc =
    if contains "mdk_read_file" keys && hasUse source UseFileBytes then
      need acc "readFileBytesLines"
    else
      acc
  let acc =
    if contains "mdk_write_file_commit" keys then
      need acc "writeFileBytesLines"
    else
      acc
  let heads = flatMap (imp => imp.params) js
  let acc =
    if any (h => h == "String" || h == "Array") heads then
      need acc "ioPushPathMoreLines"
    else
      acc
  let acc = if contains "Array" heads then need acc "jsffiArrayLines" else acc
  let acc =
    if any (imp => imp.result == "String") js then
      need acc "jsffiResultStrLines"
    else
      acc
  let acc =
    if any
      (imp =>
        imp.result == "Int"
          || imp.result == "Char"
          || contains "Array" imp.params)
      js then
      needTrap acc
    else
      acc
  if contains "mdk_write_err_byte" keys then needTrap acc else acc

hostHelperRoots : List (String, String)
hostHelperRoots = [
  ("mdk_path_push", "ioPushPathLines"),
  ("mdk_rename", "ioPushPathMoreLines"),
  ("mdk_grant_push", "ioPushGrantLines"),
  ("mdk_rename", "ioPushGrantMoreLines"),
  ("mdk_result_len", "ioResultLines"),
  ("mdk_read_file", "ioReadFileLines"),
  ("mdk_fetch_text", "ioFetchTextLines"),
  ("mdk_file_exists", "ioFileExistsLines"),
  ("mdk_canonicalize_path", "ioCanonicalizeLines"),
  ("mdk_write_file", "ioWriteFileLines"),
  ("mdk_append_file", "ioAppendFileLines"),
  ("mdk_rename", "ioRenameLines"),
  ("mdk_list_dir", "ioListDirLines"),
  ("mdk_stat_file", "ioStatFileLines"),
  ("mdk_make_dir", "ioMakeDirLines"),
  ("mdk_remove_file", "ioRemoveFileLines"),
  ("mdk_remove_dir", "ioRemoveDirLines"),
  ("mdk_fsync", "ioFsyncLines"),
  ("mdk_file_mode", "ioFileModeLines"),
  ("mdk_write_file_mode", "ioWriteFileModeLines"),
  ("mdk_get_env", "ioGetEnvLines"),
  ("mdk_read_line", "ioReadLineLines"),
  ("mdk_read_all", "ioReadAllLines"),
  ("mdk_read_exactly", "ioReadExactlyLines"),
  ("mdk_executable_path", "ioExecutablePathLines"),
  ("mdk_args_count", "ioArgsLines"),
  ("mdk_str_to_float", "floatStrLines"),
]

export
hasWasmHelper : WasmDemandPlan -> String -> Bool
hasWasmHelper plan name = contains name plan.helpers

-- The gap census walks reference bodies even for a scalar module. Its checks
-- use this planned allowance only after the ordinary module gateway succeeds.
export
censusWasmDemand : WasmDemandPlan -> WasmDemandPlan
censusWasmDemand plan = { plan |
  helpers = plan.censusHelpers,
  intHelpers = plan.censusIntHelpers,
}

export
selectWasmBin : WasmTypeContext ->
  Bool ->
  List String ->
  String ->
  CExpr ->
  CExpr ->
  String ->
  String
selectWasmBin ctx str env op l r tag =
  if isArithOp op && isTaggedFixedHead tag then
    "int-fixed"
  else if (isArithOp op || isCmpOp op) && tag == "U64" then
    "u64"
  else if (isArithOp op || isCmpOp op) && tag == "I64" then
    "i64"
  else if (isArithOp op || isCmpOp op)
    && (tag == "Float"
      || cexprStamp ctx env l == RTFloat
      || cexprStamp ctx env r == RTFloat) then
    "float"
  else if isCmpOp op && str then
    "compare"
  else if isCmpOp op && isPolyNumBinop ctx env l r then
    "compare-number"
  else if isArithOp op && isPolyNumBinop ctx env l r then
    "value-" ++ op
  else
    "int"

hBind : WasmTypeContext -> Bool -> Bool -> HelperAcc -> CBind -> HelperAcc
hBind ctx refMode str acc (CBind name clauses loc _) =
  let acc =
    if refMode
      && name /= "main"
      && (multiOrPatternClauses clauses
        || any (c => exprHasFallthrough (clauseBodyOf c)) clauses) then
      locatedNonexh acc loc
    else
      acc
  fold (hClause ctx refMode str) acc clauses

hClause : WasmTypeContext -> Bool -> Bool -> HelperAcc -> CClause -> HelperAcc
hClause ctx refMode str acc (CClause pats body) =
  hExpr
    ctx
    refMode
    str
    (fold (hPat refMode) acc pats)
    (fold (flip envBindPat) [] pats)
    body

hImpl : WasmTypeContext -> Bool -> Bool -> HelperAcc -> CImplEntry -> HelperAcc
hImpl ctx refMode str acc (CImplEntry _ _ _ body) = match body
  CImplTagged _ _ _ _ _ pats b => hClause ctx refMode str acc (CClause pats b)
  CImplDefault _ _ _ _ _ pats b => hClause ctx refMode str acc (CClause pats b)

implFailureRoots : HelperAcc -> List CImplEntry -> HelperAcc
implFailureRoots acc entries =
  let groups =
    fold
      (index (CImplEntry method _ _ body) =>
        let (key, clause) = match body
          CImplTagged _ key _ _ _ pats b => (key, CClause pats b)
          CImplDefault _ _ key _ _ pats b => (key, CClause pats b)
        let groupKey = lenKey method ++ key
        omInsert
          groupKey
          (clause :: optionOr [] (omLookup groupKey index))
          index)
      omEmpty
      entries
  fold
    (a key =>
      let clauses = optionOr [] (omLookup key groups)
      if multiOrPatternClauses clauses
        || any (c => exprHasFallthrough (clauseBodyOf c)) clauses then
        needTrap a
      else
        a)
    acc
    (omKeys groups)

localFunctionRoots : Bool -> HelperAcc -> List Pat -> CExpr -> HelperAcc
localFunctionRoots refMode acc pats body =
  if refMode
    && (multiOrPatternClauses [CClause pats body]
      || exprHasFallthrough body) then
    needTrap acc
  else
    acc

hPat : Bool -> HelperAcc -> Pat -> HelperAcc
hPat True acc (PLit (LString _)) = needMany acc [
  "strSearchRuntimeLines", "strLeafRuntimeLines", "ioStrRuntimeLines"
]
hPat refMode acc (PCon _ ps) = fold (hPat refMode) acc ps
hPat refMode acc (PTuple ps) =
  fold
    (hPat refMode)
    { acc |
      patternTuples =
        omInsert (intToString (listLen ps)) (listLen ps) acc.patternTuples,
    }
    ps
hPat refMode acc (PList ps) =
  fold (hPat refMode) { acc | patternList = True } ps
hPat refMode acc (PCons a b) =
  hPat refMode (hPat refMode { acc | patternList = True } a) b
hPat refMode acc (PAs _ _ _ p) = hPat refMode acc p
hPat _ acc _ = acc

hExpr : WasmTypeContext ->
  Bool ->
  Bool ->
  HelperAcc ->
  List String ->
  CExpr ->
  HelperAcc
hExpr ctx refMode str acc env (CBinPrim op l r tag _) =
  let branch = if refMode then selectWasmBin ctx str env op l r tag else "int"
  let acc =
    if branch == "compare" then
      need acc "valueEqRuntimeLines"
    else if branch == "compare-number" then
      need acc "valueCmpNumRuntimeLines"
    else
      acc
  let acc =
    if startsWith "value-" branch then
      need acc ("value" ++ valueOpBlock op ++ "RuntimeLines")
    else
      acc
  let acc =
    if (branch == "int" && not (isTaggedFixedHead tag)
        || startsWith "value-" branch)
      && contains op ["+", "-", "*", "/"] then
      needInt acc (intOpName op)
    else
      acc
  let acc =
    if (op == "/" || op == "%") && branch /= "float" then needTrap acc else acc
  hExpr ctx refMode str (hExpr ctx refMode str acc env l) env r
hExpr ctx refMode str acc env (CUnOp "-" x) =
  let acc =
    if refMode && cexprStamp ctx env x == RTFloat then
      acc
    else
      needInt acc "neg"
  hExpr ctx refMode str acc env x
hExpr ctx refMode str acc env (app@(CApp f args _)) =
  let acc =
    if refMode && appUsesClosures ctx.fnNames ctx.ctorArities env app then
      need acc "closApplyLines"
    else
      acc
  let acc = match f
    CVar name _ => runtimeRoots ctx acc name args
    _ => acc
  fold
    (a x => hExpr ctx refMode str a env x)
    (match f
      CVar _ _ => acc
      _ => hExpr ctx refMode str acc env f)
    args
hExpr ctx refMode str acc env (CVar name _) =
  let acc =
    if refMode
      && not (contains name env)
      && (omHasKey name ctx.fnNames || externNeedsClosure ctx name) then
      need acc "closApplyLines"
    else
      acc
  runtimeRoots ctx acc name []
hExpr _ True _ acc _ (CMethod _ _) = need acc "closApplyLines"
hExpr _ True _ acc _ (CDict _ _) = need acc "closApplyLines"
hExpr ctx refMode str acc env (CLam pats b) =
  hExpr
    ctx
    refMode
    str
    (fold
      (hPat refMode)
      (if refMode then need acc "closApplyLines" else acc)
      pats)
    (fold (flip envBindPat) env pats)
    b
hExpr ctx refMode str acc env (CIf c t f) =
  fold (a x => hExpr ctx refMode str a env x) acc [c, t, f]
hExpr ctx refMode str acc env (CLet recFlag pat a b) =
  let inner = envBindPat pat env
  let acc = match (recFlag, pat, a)
    (True, PVar _ _ _, CLam pats body) =>
      localFunctionRoots refMode acc pats body
    _ => acc
  hExpr
    ctx
    refMode
    str
    (hExpr
      ctx
      refMode
      str
      (hPat refMode acc pat)
      (if recFlag then inner else env)
      a)
    inner
    b
hExpr ctx refMode str acc env (CLetGroup binds b) =
  let inner = envBindGroups binds env
  let acc =
    fold
      (a (CBind _ cs loc bid) =>
        hBind ctx refMode str a (CBind "$local" cs loc bid))
      acc
      binds
  hExpr ctx refMode str acc inner b
hExpr ctx refMode str acc env (CBlock stmts) =
  hStmts ctx refMode str acc env stmts
hExpr ctx refMode str acc env (CDecision scrut arms tree) =
  hTree
    refMode
    (fold (hArm ctx refMode str env) (hExpr ctx refMode str acc env scrut) arms)
    tree
hExpr ctx refMode str acc env (CMatch scrut arms) =
  fold (hArm ctx refMode str env) (hExpr ctx refMode str acc env scrut) arms
hExpr ctx refMode str acc env (CIndex a i) =
  hExpr
    ctx
    refMode
    str
    (hExpr ctx refMode str (if refMode then needTrap acc else acc) env a)
    env
    i
hExpr ctx refMode str acc env (CSlice a lo hi _) =
  fold
    (a x => hExpr ctx refMode str a env x)
    (if refMode then needTrap acc else acc)
    [a, lo, hi]
hExpr ctx refMode str acc env (CTuple xs) =
  fold (a x => hExpr ctx refMode str a env x) acc xs
hExpr ctx refMode str acc env (CList xs) =
  fold (a x => hExpr ctx refMode str a env x) acc xs
hExpr ctx refMode str acc env (CArray xs) =
  fold (a x => hExpr ctx refMode str a env x) acc xs
hExpr ctx refMode str acc env (CRangeList lo hi _) =
  fold (a x => hExpr ctx refMode str a env x) acc [lo, hi]
hExpr ctx refMode str acc env (CRangeArray lo hi _) =
  fold (a x => hExpr ctx refMode str a env x) acc [lo, hi]
hExpr ctx refMode str acc env (CRecord _ fs) =
  fold (a (CField _ _ x) => hExpr ctx refMode str a env x) acc fs
hExpr ctx refMode str acc env (CFieldAccess x "value" _ _) =
  hExpr ctx refMode str { acc | refRead = True } env x
hExpr ctx refMode str acc env (CFieldAccess x _ _ _) =
  hExpr ctx refMode str acc env x
hExpr ctx refMode str acc env (CRecordUpdate _ x fs) =
  fold
    (a (CField _ _ e) => hExpr ctx refMode str a env e)
    (hExpr ctx refMode str acc env x)
    fs
hExpr ctx refMode str acc env (CVariantUpdate _ x fs) =
  fold
    (a (CField _ _ e) => hExpr ctx refMode str a env e)
    (hExpr ctx refMode str acc env x)
    fs
hExpr _ _ _ acc _ _ = acc

externNeedsClosure : WasmTypeContext -> String -> Bool
externNeedsClosure ctx symbol = match omLookup symbol ctx.externFacts
  Some fact => match (
    externRuntimeKey ctx.externFacts symbol,
    fact.callableShape,
  )
    (Some key, Some shape) =>
      shape.loweredCoreArity > 0
        && (match wasmFamily key
          Some family => isWasmExternFamily family
          None => False)
    (None, _) => True
    _ => False
  None => False

hStmts : WasmTypeContext ->
  Bool ->
  Bool ->
  HelperAcc ->
  List String ->
  List CStmt ->
  HelperAcc
hStmts _ _ _ acc _ [] = acc
hStmts ctx refMode str acc env ((CSLet recFlag (pat@(PVar _ _ _)) (lam@(CLam pats body))) :: rest) =
  let inner = envBindPat pat env
  hStmts
    ctx
    refMode
    str
    (hExpr
      ctx
      refMode
      str
      (localFunctionRoots refMode acc pats body)
      (if recFlag then inner else env)
      lam)
    inner
    rest
hStmts ctx refMode str acc env ((CSLet recFlag pat x) :: rest) =
  let inner = envBindPat pat env
  hStmts
    ctx
    refMode
    str
    (hExpr
      ctx
      refMode
      str
      (hPat refMode acc pat)
      (if recFlag then inner else env)
      x)
    inner
    rest
hStmts ctx refMode str acc env ((CSExpr x) :: rest) =
  hStmts ctx refMode str (hExpr ctx refMode str acc env x) env rest
hStmts ctx refMode str acc env ((CSAssign _ x) :: rest) =
  hStmts ctx refMode str (hExpr ctx refMode str acc env x) env rest

hArm : WasmTypeContext ->
  Bool ->
  Bool ->
  List String ->
  HelperAcc ->
  CArm ->
  HelperAcc
hArm ctx refMode str env acc (CArm pat guards b) =
  let (acc, inner) =
    fold
      ((a, scope) g => match g
        CGBool x => (hExpr ctx refMode str a scope x, scope)
        CGBind p x => (
          hExpr ctx refMode str (hPat refMode a p) scope x,
          envBindPat p scope,
        ))
      (hPat refMode acc pat, envBindPat pat env)
      guards
  hExpr ctx refMode str acc inner b

hTree : Bool -> HelperAcc -> CTree -> HelperAcc
hTree True acc (CTFail (LetRefuted loc)) = locatedTrap acc loc
hTree True acc (CTFail (NoArm loc)) = locatedNonexh acc loc
hTree refMode acc (CTGuard _ t) = hTree refMode acc t
hTree refMode acc (CTDrop t) = hTree refMode acc t
hTree refMode acc (CTSwitch branches dft) =
  hTree refMode (fold (hBranch refMode) acc branches) dft
hTree _ acc _ = acc

hBranch : Bool -> HelperAcc -> CTBranch -> HelperAcc
hBranch refMode acc (CTBranch head tree) =
  let acc = match head
    HLit lit => hPat refMode acc (PLit lit)
    HCons => { acc | patternList = True }
    HNil => { acc | patternList = True }
    HTuple n =>
      { acc | patternTuples = omInsert (intToString n) n acc.patternTuples }
    _ => acc
  hTree refMode acc tree

locatedTrap : HelperAcc -> Loc -> HelperAcc
locatedTrap acc loc = if hasLocation loc then needSite acc else needTrap acc

locatedNonexh : HelperAcc -> Loc -> HelperAcc
locatedNonexh acc loc =
  if hasLocation loc then { needSite acc | nonexh = True } else needTrap acc

hasLocation : Loc -> Bool
hasLocation (Loc f sl sc el ec) =
  f /= ""
    && not (sl == 1 && sc == 0 && el == 1 && ec == 0)
    && sl >= 0
    && sl < 16777216
    && sc >= 0
    && sc < 1048576

runtimeRoots : WasmTypeContext -> HelperAcc -> String -> List CExpr -> HelperAcc
runtimeRoots ctx acc symbol args = match externRuntimeKey ctx.externFacts symbol
  Some key if contains key ["shiftLeft", "intShiftLeft"] => needInt acc "left"
  Some key if contains key ["shiftRight", "intShiftRight"] =>
    needInt acc "right"
  Some key if contains key ["panic", "indexError", "sliceError"] => needTrap acc
  Some "indexErrorAt" => need (needTrap acc) "trapIntRuntimeLines"
  Some key if key == "indexErrorAtSite" || key == "panicAt" =>
    let acc =
      if key == "indexErrorAtSite" then
        need (needTrap acc) "trapIntRuntimeLines"
      else
        needTrap acc
    match args
      (CLit (LInt 0)) :: _ => acc
      _ => needSite acc
  _ => acc

intOpName : String -> String
intOpName "+" = "add"
intOpName "-" = "sub"
intOpName "*" = "mul"
intOpName _ = "div"

valueOpBlock : String -> String
valueOpBlock "+" = "Add"
valueOpBlock "-" = "Sub"
valueOpBlock "*" = "Mul"
valueOpBlock "/" = "Div"
valueOpBlock _ = "Mod"

printRoots : WasmTypeContext ->
  Option EntryFact ->
  List CBind ->
  HelperAcc ->
  HelperAcc
printRoots ctx outcome groups acc =
  let body = filterMap mainBodyD groups
  match body
    e :: _ =>
      let own = varStamp ctx [] "main"
      let stamp = match outcome
        Some fact if fact.entryMainIsUnit => RTUnit
        Some fact if fact.entryMainIsFloat => RTFloat
        _ => if own == RTValue then cexprStamp ctx [] e else own
      if stamp == RTFloat then
        needMany acc ["floatRuntimeLines", "ioStrRuntimeLines"]
      else if stamp == RTChar then
        needMany acc ["ioStrRuntimeLines", "strLeafRuntimeLines"]
      else
        acc
    [] => acc

mainBodyD : CBind -> Option CExpr
mainBodyD (CBind "main" [CClause [] e] _ _) = Some e
mainBodyD _ = None

representationOf : WasmDemand -> Bool -> HelperAcc -> WasmDemand
representationOf source str acc =
  let types = flatMap helperTypes (omKeys acc.helpers)
  let uses =
    if str || contains "str" types || contains "u8arr" types then
      addUse source.uses UseStr
    else
      source.uses
  let uses = if contains "arr" types then addUse uses UseArray else uses
  let uses =
    if acc.patternList || contains "C_Cons" types then
      addUse uses UseList
    else
      uses
  let seen = omFromNames (map intToString source.tupleArities) omEmpty
  let extraTuples =
    filterMap
      (k => if omHasKey k seen then None else omLookup k acc.patternTuples)
      (omKeys acc.patternTuples)
  { source |
    uses = uses,
    refBox = source.refBox || acc.refRead,
    tupleArities = source.tupleArities ++ extraTuples,
  }

physicalTypes : CProgram -> Bool -> Bool -> WasmDemand -> List String
physicalTypes _ False _ _ = ["boxint", "float"]
physicalTypes (CProgram _ ctorArs ctorTypes _ _ _) True clos rep =
  let ctorIndex = omFromPairs (reverseL ctorArs) omEmpty
  omKeys
    (omFromNames
      ([
          "boxint", "float", "dictarr", "dictcell", "T_Option", "C_Some",
          "T_Result", "C_Ok", "C_Err", "T_Ordering"
        ]
        ++ (if clos then ["argarr", "codety", "clos"] else [])
        ++ (if hasUse rep UseStr then ["str", "u8arr"] else [])
        ++ (if hasUse rep UseList then ["T_List", "C_Cons"] else [])
        ++ flatMap
          (n => ["T_Tup" ++ intToString n, "C_Tup" ++ intToString n])
          rep.tupleArities
        ++ (if hasUse rep UseArray then ["arr"] else [])
        ++ (if rep.refBox then ["refbox"] else [])
        ++ (if hasUse rep UseU64 then ["u64"] else [])
        ++ (if hasUse rep UseI64 then ["i64"] else [])
        ++ flatMap
          ((ctor, ty) =>
            if contains ty ["Option", "Result", "Ordering"] then
              []
            else
              ["T_" ++ injectiveIdent ty]
                ++ (if optionOr 0 (omLookup ctor ctorIndex) > 0 then
                  [
                    if ctor == "Cons" || ctor == "Nil" then
                      "CU_" ++ ctor
                    else
                      "C_" ++ ctor,
                  ]
                else
                  []))
          ctorTypes)
      omEmpty)

addUse : List WasmUse -> WasmUse -> List WasmUse
addUse uses use = if any (== use) uses then uses else use :: uses

export
helperOrder : List String
helperOrder = [
  "closApplyLines",
  "ioRuntimeLines",
  "ioStrRuntimeLines",
  "strLeafRuntimeLines",
  "strConcatRuntimeLines",
  "appendRuntimeLines",
  "valueEqRuntimeLines",
  "valueAddRuntimeLines",
  "valueSubRuntimeLines",
  "valueMulRuntimeLines",
  "valueDivRuntimeLines",
  "valueModRuntimeLines",
  "valueCmpNumRuntimeLines",
  "u64RuntimeLines",
  "i64RuntimeLines",
  "stderrRuntimeLines",
  "rngRuntimeLines",
  "hashRuntimeLines",
  "hashStringRuntimeLines",
  "floatRemRuntimeLines",
  "floatRuntimeLines",
  "hashFloatRuntimeLines",
  "randomFloatRuntimeLines",
  "strSearchRuntimeLines",
  "strToIntRuntimeLines",
  "strReverseRuntimeLines",
  "strJoinRuntimeLines",
  "utf8LossyRuntimeLines",
  "strCodecRuntimeLines",
  "byteBlockRuntimeLines",
  "charFromCodeRuntimeLines",
  "charClassRuntimeLines",
  "ioPushPathLines",
  "ioPushPathMoreLines",
  "ioPushGrantLines",
  "ioPushGrantMoreLines",
  "ioResultLines",
  "ioRefusedPanicLines",
  "ioReadFileLines",
  "ioFetchTextLines",
  "ioFileExistsLines",
  "ioCanonicalizeLines",
  "ioWriteFileLines",
  "ioAppendFileLines",
  "ioRenameLines",
  "ioListDirLines",
  "ioStatFileLines",
  "ioMakeDirLines",
  "ioRemoveFileLines",
  "ioRemoveDirLines",
  "ioFsyncLines",
  "ioFileModeLines",
  "ioWriteFileModeLines",
  "ioGetEnvLines",
  "ioReadLineLines",
  "ioReadAllLines",
  "ioReadExactlyLines",
  "ioExecutablePathLines",
  "jsffiArrayLines",
  "jsffiResultStrLines",
  "ioArgsLines",
  "writeFileBytesLines",
  "osEntropyLines",
  "readFileBytesLines",
  "floatStrLines",
  "trapIntRuntimeLines",
  "intRuntimeLines",
  "siteRuntimeLines",
]

helperDependencies : Bool -> String -> List String
helperDependencies _ "appendRuntimeLines" = ["strLeafRuntimeLines"]
helperDependencies _ "byteBlockRuntimeLines" =
  ["ioByteImportLines", "ioRuntimeLines", "utf8LossyRuntimeLines"]
helperDependencies _ "floatRuntimeLines" = ["floatFmtImportLines"]
helperDependencies _ "hashFloatRuntimeLines" = ["hashRuntimeLines"]
helperDependencies _ "intRuntimeLines" =
  ["siteRuntimeLines", "stderrByteImportLines", "trapIntRuntimeLines"]
helperDependencies _ "ioAppendFileLines" =
  ["ioPushGrantLines", "ioPushPathLines", "ioResultLines"]
helperDependencies _ "ioArgsLines" = ["utf8LossyRuntimeLines"]
helperDependencies _ "ioCanonicalizeLines" = [
  "ioPushGrantLines", "ioPushPathLines", "ioRefusedPanicLines", "ioResultLines"
]
helperDependencies _ "ioExecutablePathLines" = ["ioResultLines"]
helperDependencies _ "ioFetchTextLines" = ["ioPushPathLines", "ioResultLines"]
helperDependencies _ "ioFileExistsLines" =
  ["ioPushGrantLines", "ioPushPathLines", "ioRefusedPanicLines"]
helperDependencies _ "ioFileModeLines" =
  ["ioPushGrantLines", "ioPushPathLines", "ioResultLines", "ioRuntimeLines"]
helperDependencies _ "ioFsyncLines" =
  ["ioPushGrantLines", "ioPushPathLines", "ioResultLines"]
helperDependencies _ "ioGetEnvLines" = ["ioPushPathLines", "ioResultLines"]
helperDependencies _ "ioListDirLines" = [
  "ioPushGrantLines", "ioPushPathLines", "ioResultLines",
  "utf8LossyRuntimeLines"
]
helperDependencies _ "ioMakeDirLines" =
  ["ioPushGrantLines", "ioPushPathLines", "ioResultLines"]
helperDependencies _ "ioReadAllLines" = ["ioResultLines"]
helperDependencies _ "ioReadExactlyLines" = ["ioResultLines"]
helperDependencies _ "ioReadFileLines" = [
  "ioPushGrantLines", "ioPushPathLines", "ioResultLines",
  "utf8LossyRuntimeLines"
]
helperDependencies _ "ioReadLineLines" = ["ioResultLines"]
helperDependencies _ "ioRefusedPanicLines" =
  ["ioResultLines", "stderrByteImportLines"]
helperDependencies _ "ioRemoveDirLines" =
  ["ioPushGrantLines", "ioPushPathLines", "ioResultLines"]
helperDependencies _ "ioRemoveFileLines" =
  ["ioPushGrantLines", "ioPushPathLines", "ioResultLines"]
helperDependencies _ "ioRenameLines" = [
  "ioPushGrantLines", "ioPushGrantMoreLines", "ioPushPathLines",
  "ioPushPathMoreLines", "ioResultLines"
]
helperDependencies _ "ioResultLines" = ["utf8LossyRuntimeLines"]
helperDependencies _ "ioRuntimeLines" = ["ioByteImportLines"]
helperDependencies _ "ioStatFileLines" =
  ["ioPushGrantLines", "ioPushPathLines", "ioResultLines", "ioRuntimeLines"]
helperDependencies _ "ioStrRuntimeLines" = ["ioByteImportLines"]
helperDependencies _ "ioWriteFileLines" =
  ["ioPushGrantLines", "ioPushPathLines", "ioResultLines"]
helperDependencies _ "ioWriteFileModeLines" =
  ["ioPushGrantLines", "ioPushPathLines", "ioResultLines", "ioRuntimeLines"]
helperDependencies _ "jsffiArrayLines" = ["ioRuntimeLines"]
helperDependencies _ "jsffiResultStrLines" = ["utf8LossyRuntimeLines"]
helperDependencies _ "osEntropyLines" = ["ioRefusedPanicLines"]
helperDependencies _ "randomFloatRuntimeLines" = ["rngRuntimeLines"]
helperDependencies _ "readFileBytesLines" =
  ["ioPushGrantLines", "ioPushPathLines", "ioResultLines"]
helperDependencies _ "siteRuntimeLines" =
  ["stderrByteImportLines", "trapIntRuntimeLines"]
helperDependencies _ "stderrRuntimeLines" = ["stderrByteImportLines"]
helperDependencies _ "strCodecRuntimeLines" = ["utf8LossyRuntimeLines"]
helperDependencies _ "strSearchRuntimeLines" = ["strLeafRuntimeLines"]
helperDependencies _ "strToIntRuntimeLines" = ["ioRuntimeLines"]
helperDependencies _ "trapIntRuntimeLines" = ["stderrByteImportLines"]
helperDependencies _ "valueAddRuntimeLines" =
  ["intRuntimeLines", "ioRuntimeLines"]
helperDependencies _ "valueCmpNumRuntimeLines" = ["ioRuntimeLines"]
helperDependencies wide "valueDivRuntimeLines" =
  ["intRuntimeLines", "ioRuntimeLines", "stderrByteImportLines"]
    ++ (if wide then ["i64RuntimeLines"] else [])
helperDependencies _ "valueEqRuntimeLines" =
  ["ioRuntimeLines", "strSearchRuntimeLines"]
helperDependencies _ "valueModRuntimeLines" =
  ["floatRemRuntimeLines", "ioRuntimeLines", "stderrByteImportLines"]
helperDependencies _ "valueMulRuntimeLines" =
  ["intRuntimeLines", "ioRuntimeLines"]
helperDependencies _ "valueSubRuntimeLines" =
  ["intRuntimeLines", "ioRuntimeLines"]
helperDependencies _ "writeFileBytesLines" =
  ["ioPushGrantLines", "ioPushPathLines", "ioResultLines"]
helperDependencies _ _ = []

helperHostKeys : String -> List String
helperHostKeys "floatFmtImportLines" = ["mdk_float_fmt", "mdk_float_fmt_byte"]
helperHostKeys "floatStrLines" =
  ["mdk_path_push", "mdk_path_reset", "mdk_str_to_float", "mdk_str_to_float_ok"]
helperHostKeys "ioAppendFileLines" =
  ["mdk_append_file", "mdk_write_file_push", "mdk_write_file_reset"]
helperHostKeys "ioArgsLines" = ["mdk_arg_byte", "mdk_arg_len", "mdk_args_count"]
helperHostKeys "ioByteImportLines" = ["mdk_write_byte"]
helperHostKeys "ioCanonicalizeLines" = ["mdk_canonicalize_path"]
helperHostKeys "ioExecutablePathLines" = ["mdk_executable_path"]
helperHostKeys "ioFetchTextLines" = ["mdk_fetch_text"]
helperHostKeys "ioFileExistsLines" = ["mdk_file_exists"]
helperHostKeys "ioFileModeLines" = ["mdk_file_mode", "mdk_stat_field"]
helperHostKeys "ioFsyncLines" = ["mdk_fsync"]
helperHostKeys "ioGetEnvLines" = ["mdk_get_env"]
helperHostKeys "ioListDirLines" = ["mdk_list_dir"]
helperHostKeys "ioMakeDirLines" = ["mdk_make_dir"]
helperHostKeys "ioPushGrantLines" = ["mdk_grant_push", "mdk_grant_reset"]
helperHostKeys "ioPushGrantMoreLines" = ["mdk_grant_push"]
helperHostKeys "ioPushPathLines" = ["mdk_path_push", "mdk_path_reset"]
helperHostKeys "ioPushPathMoreLines" = ["mdk_path_push"]
helperHostKeys "ioReadAllLines" = ["mdk_read_all"]
helperHostKeys "ioReadExactlyLines" = ["mdk_read_exactly"]
helperHostKeys "ioReadFileLines" = ["mdk_read_file"]
helperHostKeys "ioReadLineLines" = ["mdk_read_line"]
helperHostKeys "ioRemoveDirLines" = ["mdk_remove_dir"]
helperHostKeys "ioRemoveFileLines" = ["mdk_remove_file"]
helperHostKeys "ioRenameLines" = ["mdk_grant_push", "mdk_rename"]
helperHostKeys "ioResultLines" = ["mdk_result_byte", "mdk_result_len"]
helperHostKeys "ioStatFileLines" = ["mdk_stat_field", "mdk_stat_file"]
helperHostKeys "ioWriteFileLines" =
  ["mdk_write_file", "mdk_write_file_push", "mdk_write_file_reset"]
helperHostKeys "ioWriteFileModeLines" =
  ["mdk_write_file_mode", "mdk_write_file_push", "mdk_write_file_reset"]
helperHostKeys "jsffiArrayLines" = ["mdk_path_push", "mdk_result_byte"]
helperHostKeys "jsffiResultStrLines" = ["mdk_result_byte", "mdk_result_len"]
helperHostKeys "osEntropyLines" =
  ["mdk_os_entropy", "mdk_result_byte", "mdk_result_len"]
helperHostKeys "readFileBytesLines" =
  ["mdk_read_file", "mdk_result_byte", "mdk_result_len"]
helperHostKeys "stderrByteImportLines" = ["mdk_write_err_byte"]
helperHostKeys "writeFileBytesLines" =
  ["mdk_write_file_commit", "mdk_write_file_push", "mdk_write_file_reset"]
helperHostKeys _ = []

helperTypes : String -> List String
helperTypes "appendRuntimeLines" = ["C_Cons", "str"]
helperTypes "byteBlockRuntimeLines" = ["arr", "str", "u8arr"]
helperTypes "charFromCodeRuntimeLines" = ["C_Some"]
helperTypes "closApplyLines" = ["argarr", "clos"]
helperTypes "floatRuntimeLines" = ["float", "str", "u8arr"]
helperTypes "floatStrLines" = ["C_Some", "float", "str", "u8arr"]
helperTypes "hashFloatRuntimeLines" = ["float"]
helperTypes "hashStringRuntimeLines" = ["str", "u8arr"]
helperTypes "ioAppendFileLines" = ["C_Err", "C_Ok", "str", "u8arr"]
helperTypes "ioArgsLines" = ["C_Cons", "str", "u8arr"]
helperTypes "ioCanonicalizeLines" = ["str"]
helperTypes "ioFetchTextLines" = ["C_Err", "C_Ok", "str"]
helperTypes "ioFileExistsLines" = ["str"]
helperTypes "ioFileModeLines" = ["C_Err", "C_Ok", "str"]
helperTypes "ioFsyncLines" = ["C_Err", "C_Ok", "str"]
helperTypes "ioGetEnvLines" = ["C_Some", "str"]
helperTypes "ioListDirLines" = ["C_Cons", "C_Err", "C_Ok", "str", "u8arr"]
helperTypes "ioMakeDirLines" = ["C_Err", "C_Ok", "str"]
helperTypes "ioPushGrantLines" = ["C_Cons", "str", "u8arr"]
helperTypes "ioPushGrantMoreLines" = ["C_Cons", "str", "u8arr"]
helperTypes "ioPushPathLines" = ["str", "u8arr"]
helperTypes "ioPushPathMoreLines" = ["str", "u8arr"]
helperTypes "ioReadExactlyLines" = ["C_Some"]
helperTypes "ioReadFileLines" = ["C_Err", "C_Ok", "str", "u8arr"]
helperTypes "ioReadLineLines" = ["C_Some"]
helperTypes "ioRefusedPanicLines" = ["u8arr"]
helperTypes "ioRemoveDirLines" = ["C_Err", "C_Ok", "str"]
helperTypes "ioRemoveFileLines" = ["C_Err", "C_Ok", "str"]
helperTypes "ioRenameLines" = ["C_Err", "C_Ok", "str"]
helperTypes "ioResultLines" = ["str", "u8arr"]
helperTypes "ioRuntimeLines" = ["boxint"]
helperTypes "ioStatFileLines" = ["C_Err", "C_Ok", "C_Tup4", "float", "str"]
helperTypes "ioStrRuntimeLines" = ["str", "u8arr"]
helperTypes "ioWriteFileLines" = ["C_Err", "C_Ok", "str", "u8arr"]
helperTypes "ioWriteFileModeLines" = ["C_Err", "C_Ok", "str", "u8arr"]
helperTypes "jsffiArrayLines" = ["arr"]
helperTypes "jsffiResultStrLines" = ["str", "u8arr"]
helperTypes "osEntropyLines" = ["arr"]
helperTypes "randomFloatRuntimeLines" = ["float"]
helperTypes "readFileBytesLines" = ["C_Err", "C_Ok", "arr", "str"]
helperTypes "stderrRuntimeLines" = ["str", "u8arr"]
helperTypes "strCodecRuntimeLines" = ["arr", "str", "u8arr"]
helperTypes "strConcatRuntimeLines" = ["C_Cons", "str", "u8arr"]
helperTypes "strJoinRuntimeLines" = ["C_Cons", "str", "u8arr"]
helperTypes "strLeafRuntimeLines" = ["str", "u8arr"]
helperTypes "strReverseRuntimeLines" = ["str", "u8arr"]
helperTypes "strSearchRuntimeLines" = ["C_Some", "str", "u8arr"]
helperTypes "strToIntRuntimeLines" = ["C_Some", "str", "u8arr"]
helperTypes "utf8LossyRuntimeLines" = ["str", "u8arr"]
helperTypes "valueAddRuntimeLines" = ["float"]
helperTypes "valueCmpNumRuntimeLines" = ["float"]
helperTypes "valueDivRuntimeLines" = ["float"]
helperTypes "valueEqRuntimeLines" = ["boxint", "float", "str"]
helperTypes "valueModRuntimeLines" = ["float"]
helperTypes "valueMulRuntimeLines" = ["float"]
helperTypes "valueSubRuntimeLines" = ["float"]
helperTypes "writeFileBytesLines" = ["C_Err", "C_Ok", "arr", "str"]
helperTypes _ = []

closeHelpers : Bool -> HelperAcc -> HelperAcc
closeHelpers wide acc =
  let next =
    fold
      (a h => needMany a (helperDependencies wide h))
      acc
      (omKeys acc.helpers)
  if omKeys next.helpers == omKeys acc.helpers then
    next
  else
    closeHelpers wide next

physicalImports : HelperAcc ->
  List String ->
  List JsImport ->
  List PlannedImport
physicalImports acc sourceKeys js =
  let keys =
    omKeys
      (omFromNames
        (sourceKeys ++ flatMap helperHostKeys (omKeys acc.helpers))
        omEmpty)
  let first =
    ["mdk_write_byte"]
      ++ (if contains "mdk_float_fmt" keys then
        ["mdk_float_fmt", "mdk_float_fmt_byte"]
      else
        [])
  let rest =
    filterList
      (k =>
        not
          (contains k [
            "mdk_write_byte", "mdk_float_fmt", "mdk_float_fmt_byte",
            "mdk_write_err_byte"
          ]))
      keys
  map plannedEnv (first ++ rest)
    ++ map plannedJs js
    ++ (if contains "mdk_write_err_byte" keys then
      [plannedEnv "mdk_write_err_byte"]
    else
      [])

plannedEnv : String -> PlannedImport
plannedEnv key = PlannedImport {
  namespace = "env",
  field = key,
  watSymbol = key,
  signature = optionOr "" (hostImportSigOf key),
}

plannedJs : JsImport -> PlannedImport
plannedJs imp = PlannedImport {
  namespace = "jsffi",
  field = "\{imp.jsName}:\{joinWith "," imp.params}->\{imp.result}",
  watSymbol = "jsffi.import.\{injectiveIdent imp.medakaName}",
  signature =
    joinWith "" (map jsWireParam imp.params) ++ jsWireResult imp.result,
}

export
hostImportSigOf : String -> Option String
hostImportSigOf "mdk_write_byte" = Some " (param i32)"
hostImportSigOf "mdk_write_err_byte" = Some " (param i32)"
hostImportSigOf "mdk_float_fmt" = Some " (param f64) (result i32)"
hostImportSigOf "mdk_float_fmt_byte" = Some " (param i32) (result i32)"
hostImportSigOf "mdk_exit" = Some " (param i32)"
hostImportSigOf "mdk_wall_time_sec" = Some " (result f64)"
hostImportSigOf "mdk_monotonic_sec" = Some " (result f64)"
hostImportSigOf "mdk_sleep_ms" = Some " (param i64)"
hostImportSigOf "mdk_fetch_text" = Some " (result i32)"
hostImportSigOf "mdk_cbrt" = Some unaryF64Sig
hostImportSigOf "mdk_exp" = Some unaryF64Sig
hostImportSigOf "mdk_log" = Some unaryF64Sig
hostImportSigOf "mdk_log2" = Some unaryF64Sig
hostImportSigOf "mdk_log10" = Some unaryF64Sig
hostImportSigOf "mdk_sin" = Some unaryF64Sig
hostImportSigOf "mdk_cos" = Some unaryF64Sig
hostImportSigOf "mdk_tan" = Some unaryF64Sig
hostImportSigOf "mdk_asin" = Some unaryF64Sig
hostImportSigOf "mdk_acos" = Some unaryF64Sig
hostImportSigOf "mdk_atan" = Some unaryF64Sig
hostImportSigOf "mdk_sinh" = Some unaryF64Sig
hostImportSigOf "mdk_cosh" = Some unaryF64Sig
hostImportSigOf "mdk_tanh" = Some unaryF64Sig
hostImportSigOf "mdk_pow" = Some binaryF64Sig
hostImportSigOf "mdk_atan2" = Some binaryF64Sig
hostImportSigOf "mdk_hypot" = Some binaryF64Sig
hostImportSigOf "mdk_path_reset" = Some ""
hostImportSigOf "mdk_path_push" = Some " (param i32)"
hostImportSigOf "mdk_read_file" = Some " (result i32)"
hostImportSigOf "mdk_file_exists" = Some " (result i32)"
hostImportSigOf "mdk_get_env" = Some " (result i32)"
hostImportSigOf "mdk_read_line" = Some " (result i32)"
hostImportSigOf "mdk_read_all" = Some ""
hostImportSigOf "mdk_read_exactly" = Some " (param i64) (result i32)"
hostImportSigOf "mdk_os_entropy" = Some " (param i64) (result i32)"
hostImportSigOf "mdk_executable_path" = Some " (result i32)"
hostImportSigOf "mdk_args_count" = Some " (result i32)"
hostImportSigOf "mdk_arg_len" = Some " (param i32) (result i32)"
hostImportSigOf "mdk_arg_byte" = Some " (param i32) (param i32) (result i32)"
hostImportSigOf "mdk_result_len" = Some " (result i32)"
hostImportSigOf "mdk_result_byte" = Some " (param i32) (result i32)"
hostImportSigOf "mdk_write_file_reset" = Some ""
hostImportSigOf "mdk_write_file_push" = Some " (param i32)"
hostImportSigOf "mdk_write_file_commit" = Some " (result i32)"
hostImportSigOf "mdk_str_to_float" = Some " (result f64)"
hostImportSigOf "mdk_str_to_float_ok" = Some " (result i32)"
hostImportSigOf "mdk_grant_reset" = Some ""
hostImportSigOf "mdk_grant_push" = Some " (param i32)"
hostImportSigOf "mdk_canonicalize_path" = Some " (result i32)"
hostImportSigOf "mdk_write_file" = Some " (result i32)"
hostImportSigOf "mdk_append_file" = Some " (result i32)"
hostImportSigOf "mdk_make_dir" = Some " (result i32)"
hostImportSigOf "mdk_remove_file" = Some " (result i32)"
hostImportSigOf "mdk_remove_dir" = Some " (result i32)"
hostImportSigOf "mdk_fsync" = Some " (result i32)"
hostImportSigOf "mdk_file_mode" = Some " (result i32)"
hostImportSigOf "mdk_write_file_mode" = Some " (param i32) (result i32)"
hostImportSigOf "mdk_rename" = Some " (param i32) (result i32)"
hostImportSigOf "mdk_list_dir" = Some " (result i32)"
hostImportSigOf "mdk_stat_file" = Some " (result i32)"
hostImportSigOf "mdk_stat_field" = Some " (param i32) (result f64)"
hostImportSigOf "mdk_file_bound_enter" =
  Some " (param i32) (param i32) (result i32)"
hostImportSigOf "mdk_file_bound_exit" = Some ""
hostImportSigOf _ = None

unaryF64Sig : String
unaryF64Sig = " (param f64) (result f64)"

binaryF64Sig : String
binaryF64Sig = " (param f64) (param f64) (result f64)"

export
jsWireParam : String -> String
jsWireParam "Unit" = ""
jsWireParam head = " (param \{jsWireTy head})"

-- The wasm result a head comes back as; a `String` comes back on the result
-- channel and a `Unit` as nothing.
export
jsWireResult : String -> String
jsWireResult "Unit" = ""
jsWireResult "String" = ""
jsWireResult head = " (result \{jsWireTy head})"

jsWireTy : String -> String
jsWireTy "Int" = "i64"
jsWireTy "U64" = "i64"
jsWireTy "I64" = "i64"
jsWireTy "Float" = "f64"
jsWireTy _ = "i32"

export
validateWasmDemand : WasmDemandInputs ->
  CProgram ->
  ExternRequirements ->
  WasmDemandPlan ->
  List String
validateWasmDemand inputs cp requirements actual =
  let expected = planWasmDemand inputs cp requirements
  let actualTypes = omFromNames actual.representationTypes omEmpty
  let expectedKeys = map (i => "\{i.namespace}:\{i.field}") expected.imports
  let actualKeys = map (i => "\{i.namespace}:\{i.field}") actual.imports
  let expectedSet = omFromNames expectedKeys omEmpty
  let actualSet = omFromNames actualKeys omEmpty
  (if expected.useRef /= actual.useRef
      || expected.useClos /= actual.useClos
      || expected.stringOps /= actual.stringOps then
      ["wasm-mode-mismatch"]
    else
      [])
    ++ (if expected.sourceDemand /= actual.sourceDemand
      || expected.representation /= actual.representation
      || expected.intHelpers /= actual.intHelpers
      || expected.siteRuntime /= actual.siteRuntime
      || expected.nonexhaustiveRuntime /= actual.nonexhaustiveRuntime then
      ["missing-wasm-helper-prerequisite: physical branches"]
    else
      [])
    ++ (if expected.censusHelpers /= actual.censusHelpers
      || expected.censusIntHelpers /= actual.censusIntHelpers then
      ["wasm-census-demand-mismatch"]
    else
      [])
    ++ flatMap
      (name =>
        if omHasKey name actualTypes then
          []
        else
          ["missing-wasm-type-prerequisite: " ++ name])
      expected.representationTypes
    ++ (if expected.representationTypes == actual.representationTypes then
      []
    else
      ["wasm-representation-types-mismatch"])
    ++ flatMap
      (h =>
        if contains h actual.helpers then
          []
        else
          ["missing-wasm-helper-prerequisite: " ++ h])
      expected.helpers
    ++ (if expected.helpers == actual.helpers then
      []
    else if all (h => contains h actual.helpers) expected.helpers then
      ["unexpected-wasm-helper"]
    else
      [])
    ++ (if map
        ((key, family) => (key, wasmFamilyTag family))
        expected.catalogFamilies
      /= map
        ((key, family) => (key, wasmFamilyTag family))
        actual.catalogFamilies then
      ["wasm-catalog-disposition-mismatch"]
    else
      [])
    ++ flatMap
      (key =>
        if omHasKey key actualSet then
          []
        else
          ["missing-wasm-host-key: " ++ key])
      expectedKeys
    ++ flatMap
      (key =>
        if omHasKey key expectedSet then
          []
        else
          ["unexpected-wasm-host-key: " ++ key])
      actualKeys
    ++ (if expected.imports == actual.imports then
      []
    else
      ["wasm-import-order"])
    ++ (if expected.sourceHostKeys == actual.sourceHostKeys
      && expected.jsImports == actual.jsImports then
      []
    else
      ["wasm-source-demand-mismatch"])

ctorToFloatIdxs : (String, List String) -> (String, List Int)
ctorToFloatIdxs (ctor, typeNames) = (ctor, floatFieldIndices typeNames 0)

-- collect the 0-based indices of "Float" fields from a type-head list.
floatFieldIndices : List String -> Int -> List Int
floatFieldIndices [] _ = []
floatFieldIndices ("Float" :: rest) i = i :: floatFieldIndices rest (i + 1)
floatFieldIndices (_ :: rest) i = floatFieldIndices rest (i + 1)

export
ctorFloatFieldIndex : List (String, List String) -> OrdMap (List Int)
ctorFloatFieldIndex fields =
  omFromPairs (reverseL (map ctorToFloatIdxs fields)) omEmpty

export
exprHasFallthrough : CExpr -> Bool
exprHasFallthrough (CVar x _) = x == "__fallthrough__"
exprHasFallthrough (CApp f args _) =
  exprHasFallthrough f || anyList exprHasFallthrough args
exprHasFallthrough (CIf c t f) =
  exprHasFallthrough c || exprHasFallthrough t || exprHasFallthrough f
exprHasFallthrough (CLet _ _ e1 e2) =
  exprHasFallthrough e1 || exprHasFallthrough e2
exprHasFallthrough (CLetGroup _ body) = exprHasFallthrough body
exprHasFallthrough (CBlock stmts) = anyList stmtHasFallthrough stmts
exprHasFallthrough (CDecision scrut arms _) =
  exprHasFallthrough scrut || anyList (a => exprHasFallthrough (armBody a)) arms
exprHasFallthrough _ = False

stmtHasFallthrough : CStmt -> Bool
stmtHasFallthrough (CSExpr e) = exprHasFallthrough e
stmtHasFallthrough (CSLet _ _ e) = exprHasFallthrough e
stmtHasFallthrough (CSAssign _ e) = exprHasFallthrough e
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Pat" true) (mem "Addr" true) (mem "BinderId" true) (mem "Loc" true) (mem "isTaggedFixedHead" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "DeclFacts" true) (mem "EntryFact" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CField" true) (mem "CGuard" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CStmt" true) (mem "CArm" true) (mem "CHead" true) (mem "CTree" true) (mem "CTBranch" true) (mem "CallSite" true) (mem "CallMode" true) (mem "FailSite" true) (mem "litRuntimeType" false) (mem "siteSentinelName" false))))
(DUse false (UseGroup ("ir" "extern_types") ((mem "ExternDeclFact" true))))
(DUse false (UseGroup ("ir" "extern_lower") ((mem "externRuntimeKey" false))))
(DUse false (UseGroup ("backend" "extern_requirements") ((mem "ExternRequirements" false) (mem "RequirementBinding" true) (mem "requirementHostRows" false) (mem "requirementFacts" false))))
(DUse false (UseGroup ("backend" "extern_catalog") ((mem "WasmUse" true) (mem "WasmFamily" true) (mem "Disposition" true) (mem "wasmUses" false) (mem "wasmHostKeys" false) (mem "wasmTupleArities" false) (mem "wasmFamily" false) (mem "isWasmExternFamily" false) (mem "fileBoundHostKeys" false))))
(DUse false (UseGroup ("backend" "global_plan") ((mem "GlobalInitPlan" false))))
(DUse false (UseGroup ("backend" "trmc_analysis") ((mem "TrmcVerdicts" false) (mem "DispGroup" false) (mem "patVarsList" false) (mem "patVars" false) (mem "bindName" false) (mem "clauseBodyOf" false) (mem "armBody" false) (mem "flattenApp" false))))
(DUse false (UseGroup ("backend" "emit_support") ((mem "appParts" false) (mem "isExactCall" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" true) (mem "RuntimeType" true) (mem "binderOrdinal" false))))
(DUse false (UseGroup ("types" "private_mangle") ((mem "injectiveIdent" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omKeys" false) (mem "omFromNames" false) (mem "omFromPairs" false) (mem "omDelete" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "filterList" false) (mem "listLen" false) (mem "contains" false) (mem "startsWith" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "anyList" false) (mem "lookupAssoc" false) (mem "joinWith" false) (mem "lenKey" false))))
(DData Public "JsImport" () ((variant "JsImport" (ConNamed (field "medakaName" (TyCon "String")) (field "jsName" (TyCon "String")) (field "params" (TyApp (TyCon "List") (TyCon "String"))) (field "result" (TyCon "String"))))) ())
(DImpl true "Eq" ((TyCon "JsImport")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "JsImport" ((rf "medakaName" (PVar "__a0")) (rf "jsName" (PVar "__a1")) (rf "params" (PVar "__a2")) (rf "result" (PVar "__a3"))) false) (PRec "JsImport" ((rf "medakaName" (PVar "__b0")) (rf "jsName" (PVar "__b1")) (rf "params" (PVar "__b2")) (rf "result" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "JsImport")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "JsImport" ((rf "medakaName" (PVar "__a0")) (rf "jsName" (PVar "__a1")) (rf "params" (PVar "__a2")) (rf "result" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "JsImport {")) (ELit (LString " medakaName = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", jsName = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", params = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString ", result = "))) (EApp (EVar "debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DData Public "WasmDemand" () ((variant "WasmDemand" (ConNamed (field "uses" (TyApp (TyCon "List") (TyCon "WasmUse"))) (field "refBox" (TyCon "Bool")) (field "divGuard" (TyCon "Bool")) (field "tupleArities" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DImpl true "Eq" ((TyCon "WasmDemand")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "WasmDemand" ((rf "uses" (PVar "__a0")) (rf "refBox" (PVar "__a1")) (rf "divGuard" (PVar "__a2")) (rf "tupleArities" (PVar "__a3"))) false) (PRec "WasmDemand" ((rf "uses" (PVar "__b0")) (rf "refBox" (PVar "__b1")) (rf "divGuard" (PVar "__b2")) (rf "tupleArities" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "WasmDemand")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "WasmDemand" ((rf "uses" (PVar "__a0")) (rf "refBox" (PVar "__a1")) (rf "divGuard" (PVar "__a2")) (rf "tupleArities" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "WasmDemand {")) (ELit (LString " uses = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", refBox = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", divGuard = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString ", tupleArities = "))) (EApp (EVar "debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DData Private "DemandAcc" () ((variant "DemandAcc" (ConNamed (field "seenUses" (TyApp (TyCon "List") (TyCon "WasmUse"))) (field "seenKeys" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "seenJs" (TyApp (TyCon "OrdMap") (TyCon "JsImport"))) (field "seenRefBox" (TyCon "Bool")) (field "seenDivGuard" (TyCon "Bool")) (field "seenArities" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DData Private "DemandScope" () ((variant "DemandScope" (ConNamed (field "locals" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "topFns" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "topVals" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "jsBinds" (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))) (field "externFacts" (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")))))) ())
(DTypeSig false "wasmDemandOf" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")) (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyTuple (TyCon "WasmDemand") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "JsImport"))))))))
(DFunDef false "wasmDemandOf" ((PVar "externFacts") (PVar "jsBinds") (PVar "groups") (PVar "impls")) (EBlock (DoLet false false (PVar "start") (ERecordCreate "DemandAcc" ((fa "seenUses" (EListLit)) (fa "seenKeys" (EVar "omEmpty")) (fa "seenJs" (EVar "omEmpty")) (fa "seenRefBox" (EVar "False")) (fa "seenDivGuard" (EVar "False")) (fa "seenArities" (EListLit))))) (DoLet false false (PVar "tops") (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EBinOp "/=" (EApp (EVar "bindName") (EVar "b")) (ELit (LString "main"))))) (EVar "groups"))) (DoLet false false (PVar "sc") (ERecordCreate "DemandScope" ((fa "locals" (EVar "omEmpty")) (fa "topFns" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "bindName")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EVar "not") (EApp (EVar "isValBind") (EVar "b"))))) (EVar "tops")))) (EVar "omEmpty"))) (fa "topVals" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "bindName")) (EApp (EApp (EVar "filterList") (EVar "isValBind")) (EVar "tops")))) (EVar "omEmpty"))) (fa "jsBinds" (EVar "jsBinds")) (fa "externFacts" (EVar "externFacts"))))) (DoLet false false (PVar "acc") (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dImpl") (EVar "sc"))) (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dBind") (EVar "sc"))) (EVar "start")) (EVar "groups"))) (EVar "impls"))) (DoExpr (ETuple (ERecordCreate "WasmDemand" ((fa "uses" (EApp (EVar "reverseL") (EFieldAccess (EVar "acc") "seenUses"))) (fa "refBox" (EFieldAccess (EVar "acc") "seenRefBox")) (fa "divGuard" (EFieldAccess (EVar "acc") "seenDivGuard")) (fa "tupleArities" (EApp (EVar "reverseL") (EFieldAccess (EVar "acc") "seenArities"))))) (EApp (EVar "omKeys") (EFieldAccess (EVar "acc") "seenKeys")) (EApp (EApp (EVar "filterMap") (ELam ((PVar "k")) (EApp (EApp (EVar "omLookup") (EVar "k")) (EFieldAccess (EVar "acc") "seenJs")))) (EApp (EVar "omKeys") (EFieldAccess (EVar "acc") "seenJs")))))))
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
(DFunDef false "noteName" ((PVar "acc") (PLit (LString "$withFileReadBound"))) (EApp (EVar "noteFileBound") (EVar "acc")))
(DFunDef false "noteName" ((PVar "acc") (PLit (LString "$withFileWriteBound"))) (EApp (EVar "noteFileBound") (EVar "acc")))
(DFunDef false "noteName" ((PVar "acc") (PVar "name")) (EBlock (DoLet false false (PVar "acc") (EMatch (EApp (EVar "wasmFamily") (EVar "name")) (arm (PCon "Some" (PCon "WasmRefCell")) () (EApp (EVar "noteRefBox") (EVar "acc"))) (arm PWild () (EVar "acc")))) (DoExpr (EApp (EApp (EApp (EVar "walkEach") (EVar "noteArity")) (EApp (EApp (EApp (EVar "walkEach") (EVar "noteKey")) (EApp (EApp (EApp (EVar "walkEach") (EVar "noteUse")) (EVar "acc")) (EApp (EVar "wasmUses") (EVar "name")))) (EApp (EVar "wasmHostKeys") (EVar "name")))) (EApp (EVar "wasmTupleArities") (EVar "name"))))))
(DTypeSig false "noteExtern" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyCon "String") (TyCon "DemandAcc")))))
(DFunDef false "noteExtern" ((PVar "sc") (PVar "acc") (PVar "name")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "sc") "jsBinds")) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "externRuntimeKey") (EFieldAccess (EVar "sc") "externFacts")) (EVar "name")) (arm (PCon "Some" (PVar "key")) () (EApp (EApp (EVar "noteName") (EVar "acc")) (EVar "key"))) (arm (PCon "None") () (EIf (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "$withFileReadBound"))) (EBinOp "==" (EVar "name") (ELit (LString "$withFileWriteBound")))) (EApp (EVar "noteFileBound") (EVar "acc")) (EVar "acc"))))) (arm (PCon "Some" (PTuple (PVar "js") (PTuple (PVar "params") (PVar "result")))) () (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "acc") "seenJs")) (EVar "acc") (EBlock (DoLet false false (PVar "imp") (ERecordCreate "JsImport" ((fa "medakaName" (EVar "name")) (fa "jsName" (EVar "js")) (fa "params" (EVar "params")) (fa "result" (EVar "result"))))) (DoExpr (EApp (EApp (EVar "noteJsResult") (EApp (EApp (EApp (EVar "walkEach") (EVar "noteJsParam")) (ERecordUpdate (EVar "acc") ((fa "seenJs" (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "imp")) (EFieldAccess (EVar "acc") "seenJs")))))) (EVar "params"))) (EVar "result"))))))))
(DTypeSig false "noteJsParam" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "String") (TyCon "DemandAcc"))))
(DFunDef false "noteJsParam" ((PVar "acc") (PLit (LString "String"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "noteKey")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseStr"))) (EVar "jsPathKeys")))
(DFunDef false "noteJsParam" ((PVar "acc") (PLit (LString "Array"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "noteKey")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseArray"))) (EBinOp "++" (EVar "jsPathKeys") (EVar "jsResultKeys"))))
(DFunDef false "noteJsParam" ((PVar "acc") (PVar "head")) (EApp (EApp (EVar "noteJsBoxed") (EVar "acc")) (EVar "head")))
(DTypeSig false "noteJsResult" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "String") (TyCon "DemandAcc"))))
(DFunDef false "noteJsResult" ((PVar "acc") (PLit (LString "String"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "noteKey")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseStr"))) (EVar "jsResultKeys")))
(DFunDef false "noteJsResult" ((PVar "acc") (PVar "head")) (EApp (EApp (EVar "noteJsBoxed") (EVar "acc")) (EVar "head")))
(DTypeSig false "noteJsBoxed" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "String") (TyCon "DemandAcc"))))
(DFunDef false "noteJsBoxed" ((PVar "acc") (PLit (LString "Float"))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseFloat")))
(DFunDef false "noteJsBoxed" ((PVar "acc") (PLit (LString "U64"))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseU64")))
(DFunDef false "noteJsBoxed" ((PVar "acc") (PLit (LString "I64"))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseI64")))
(DFunDef false "noteJsBoxed" ((PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "jsPathKeys" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "jsPathKeys" () (EListLit (ELit (LString "mdk_path_reset")) (ELit (LString "mdk_path_push"))))
(DTypeSig false "jsResultKeys" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "jsResultKeys" () (EListLit (ELit (LString "mdk_result_len")) (ELit (LString "mdk_result_byte"))))
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
(DTypeSig false "isValBind" (TyFun (TyCon "CBind") (TyCon "Bool")))
(DFunDef false "isValBind" ((PCon "CBind" (PVar "name") (PList (PCon "CClause" (PList) PWild)) PWild PWild)) (EBinOp "/=" (EVar "name") (ELit (LString "main"))))
(DFunDef false "isValBind" (PWild) (EVar "False"))
(DTypeSig false "bindIn" (TyFun (TyCon "DemandScope") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "DemandScope"))))
(DFunDef false "bindIn" ((PVar "sc") (PVar "pats")) (EMatch (EApp (EVar "patVarsList") (EVar "pats")) (arm (PList) () (EVar "sc")) (arm (PVar "names") () (ERecordUpdate (EVar "sc") ((fa "locals" (EApp (EApp (EVar "omFromNames") (EVar "names")) (EFieldAccess (EVar "sc") "locals"))))))))
(DTypeSig false "isLocal" (TyFun (TyCon "DemandScope") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isLocal" ((PVar "sc") (PVar "x")) (EApp (EApp (EVar "omHasKey") (EVar "x")) (EFieldAccess (EVar "sc") "locals")))
(DTypeSig false "isCoreFn" (TyFun (TyCon "DemandScope") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isCoreFn" ((PVar "sc") (PVar "x")) (EApp (EApp (EVar "omHasKey") (EBinOp "++" (ELit (LString "core__")) (EVar "x"))) (EFieldAccess (EVar "sc") "topFns")))
(DTypeSig false "dVar" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyCon "String") (TyCon "DemandAcc")))))
(DFunDef false "dVar" ((PVar "sc") (PVar "acc") (PVar "x")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "isLocal") (EVar "sc")) (EVar "x")) (EApp (EApp (EVar "omHasKey") (EVar "x")) (EFieldAccess (EVar "sc") "topVals"))) (EApp (EApp (EVar "omHasKey") (EVar "x")) (EFieldAccess (EVar "sc") "topFns"))) (EApp (EApp (EVar "isCoreFn") (EVar "sc")) (EVar "x"))) (EVar "acc") (EApp (EApp (EApp (EVar "noteExtern") (EVar "sc")) (EVar "acc")) (EVar "x"))))
(DTypeSig false "dBind" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CBind") (TyCon "DemandAcc")))))
(DFunDef false "dBind" ((PVar "sc") (PVar "acc") (PCon "CBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dClause") (EVar "sc"))) (EVar "acc")) (EVar "clauses")))
(DTypeSig false "dClause" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CClause") (TyCon "DemandAcc")))))
(DFunDef false "dClause" ((PVar "sc") (PVar "acc") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "bindIn") (EVar "sc")) (EVar "pats"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dPat")) (EVar "acc")) (EVar "pats"))) (EVar "body")))
(DTypeSig false "dImpl" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CImplEntry") (TyCon "DemandAcc")))))
(DFunDef false "dImpl" ((PVar "sc") (PVar "acc") (PCon "CImplEntry" PWild PWild PWild (PCon "CImplTagged" PWild PWild PWild PWild PWild (PVar "pats") (PVar "b")))) (EApp (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "bindIn") (EVar "sc")) (EVar "pats"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dPat")) (EVar "acc")) (EVar "pats"))) (EVar "b")))
(DFunDef false "dImpl" ((PVar "sc") (PVar "acc") (PCon "CImplEntry" PWild PWild PWild (PCon "CImplDefault" PWild PWild PWild PWild PWild (PVar "pats") (PVar "b")))) (EApp (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "bindIn") (EVar "sc")) (EVar "pats"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dPat")) (EVar "acc")) (EVar "pats"))) (EVar "b")))
(DTypeSig false "dExpr" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CExpr") (TyCon "DemandAcc")))))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CList" (PVar "es"))) (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dExpr") (EVar "sc"))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseList"))) (EVar "es")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseList"))) (EVar "lo"))) (EVar "hi")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CTuple" (PVar "es"))) (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dExpr") (EVar "sc"))) (EApp (EApp (EVar "noteArity") (EVar "acc")) (EApp (EVar "listLen") (EVar "es")))) (EVar "es")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CArray" (PVar "es"))) (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dExpr") (EVar "sc"))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseArray"))) (EVar "es")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseArray"))) (EVar "lo"))) (EVar "hi")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseArray"))) (EVar "a"))) (EVar "i")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseArray"))) (EVar "a"))) (EVar "lo"))) (EVar "hi")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CRecord" PWild (PVar "fields"))) (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dField") (EVar "sc"))) (EVar "acc")) (EVar "fields")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CFieldAccess" (PVar "ex") PWild PWild PWild)) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "ex")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CRecordUpdate" PWild (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dField") (EVar "sc"))) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "base"))) (EVar "fields")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CVariantUpdate" PWild (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dField") (EVar "sc"))) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "base"))) (EVar "fields")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PAs "app" (PCon "CApp" PWild PWild PWild))) (EBlock (DoLet false false (PTuple (PVar "hd") (PVar "args")) (EApp (EApp (EVar "flattenApp") (EVar "app")) (EListLit))) (DoExpr (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dExpr") (EVar "sc"))) (EApp (EApp (EApp (EVar "dAppHead") (EVar "sc")) (EVar "acc")) (EVar "hd"))) (EVar "args")))))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CVar" (PVar "x") PWild)) (EApp (EApp (EApp (EVar "dVar") (EVar "sc")) (EVar "acc")) (EVar "x")))
(DFunDef false "dExpr" (PWild (PVar "acc") (PCon "CLit" (PCon "LFloat" PWild))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseFloat")))
(DFunDef false "dExpr" (PWild (PVar "acc") (PCon "CLit" (PCon "LU64" PWild PWild))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseU64")))
(DFunDef false "dExpr" (PWild (PVar "acc") (PCon "CLit" (PCon "LI64" PWild PWild))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseI64")))
(DFunDef false "dExpr" (PWild (PVar "acc") (PCon "CLit" (PCon "LString" PWild))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseStr")))
(DFunDef false "dExpr" (PWild (PVar "acc") (PCon "CLit" (PCon "LChar" PWild))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseStr")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CLam" (PVar "pats") (PVar "b"))) (EApp (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "bindIn") (EVar "sc")) (EVar "pats"))) (EVar "acc")) (EVar "b")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") PWild)) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EVar "noteBinop") (EApp (EApp (EVar "noteTag") (EVar "acc")) (EVar "tag"))) (EVar "op"))) (EVar "l"))) (EVar "r")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CUnOp" PWild (PVar "x"))) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "x")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "c"))) (EVar "t"))) (EVar "f")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CLet" (PVar "r") (PVar "pat") (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindIn") (EVar "sc")) (EListLit (EVar "pat")))) (DoExpr (EApp (EApp (EApp (EVar "dExpr") (EVar "inner")) (EApp (EApp (EApp (EVar "dExpr") (EIf (EVar "r") (EVar "inner") (EVar "sc"))) (EApp (EApp (EVar "dPat") (EVar "acc")) (EVar "pat"))) (EVar "a"))) (EVar "b")))))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EApp (EVar "dStmts") (EVar "sc")) (EVar "acc")) (EVar "stmts")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EVar "dTree") (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dArm") (EVar "sc"))) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "scrut"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dArm") (EVar "sc"))) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "scrut"))) (EVar "arms")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CLetGroup" (PVar "binds") (PVar "b"))) (EBlock (DoLet false false (PVar "inner") (ERecordUpdate (EVar "sc") ((fa "locals" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "bindName")) (EVar "binds"))) (EFieldAccess (EVar "sc") "locals")))))) (DoExpr (EApp (EApp (EApp (EVar "dExpr") (EVar "inner")) (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dBind") (EVar "inner"))) (EVar "acc")) (EVar "binds"))) (EVar "b")))))
(DFunDef false "dExpr" (PWild (PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "dAppHead" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CExpr") (TyCon "DemandAcc")))))
(DFunDef false "dAppHead" ((PVar "sc") (PVar "acc") (PCon "CVar" (PVar "f") PWild)) (EIf (EBinOp "||" (EApp (EApp (EVar "isLocal") (EVar "sc")) (EVar "f")) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "f")) (EFieldAccess (EVar "sc") "topFns"))) (EApp (EApp (EVar "isCoreFn") (EVar "sc")) (EVar "f")))) (EVar "acc") (EApp (EApp (EApp (EVar "noteExtern") (EVar "sc")) (EVar "acc")) (EVar "f"))))
(DFunDef false "dAppHead" ((PVar "sc") (PVar "acc") (PVar "h")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "h")))
(DTypeSig false "dField" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CField") (TyCon "DemandAcc")))))
(DFunDef false "dField" ((PVar "sc") (PVar "acc") (PCon "CField" PWild PWild (PVar "e"))) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "e")))
(DTypeSig false "dArm" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CArm") (TyCon "DemandAcc")))))
(DFunDef false "dArm" ((PVar "sc") (PVar "acc") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "dGuarded") (EApp (EApp (EVar "bindIn") (EVar "sc")) (EListLit (EVar "pat")))) (EApp (EApp (EVar "dPat") (EVar "acc")) (EVar "pat"))) (EVar "guards")) (EVar "body")))
(DTypeSig false "dGuarded" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyFun (TyCon "CExpr") (TyCon "DemandAcc"))))))
(DFunDef false "dGuarded" ((PVar "sc") (PVar "acc") (PList) (PVar "body")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "body")))
(DFunDef false "dGuarded" ((PVar "sc") (PVar "acc") (PCons (PCon "CGBool" (PVar "g")) (PVar "rest")) (PVar "body")) (EApp (EApp (EApp (EApp (EVar "dGuarded") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "g"))) (EVar "rest")) (EVar "body")))
(DFunDef false "dGuarded" ((PVar "sc") (PVar "acc") (PCons (PCon "CGBind" (PVar "p") (PVar "e")) (PVar "rest")) (PVar "body")) (EApp (EApp (EApp (EApp (EVar "dGuarded") (EApp (EApp (EVar "bindIn") (EVar "sc")) (EListLit (EVar "p")))) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EVar "dPat") (EVar "acc")) (EVar "p"))) (EVar "e"))) (EVar "rest")) (EVar "body")))
(DTypeSig false "dStmts" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyCon "DemandAcc")))))
(DFunDef false "dStmts" (PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "dStmts" ((PVar "sc") (PVar "acc") (PCons (PCon "CSExpr" (PVar "e")) (PVar "rest"))) (EApp (EApp (EApp (EVar "dStmts") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "e"))) (EVar "rest")))
(DFunDef false "dStmts" ((PVar "sc") (PVar "acc") (PCons (PCon "CSLet" (PVar "r") (PVar "pat") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindIn") (EVar "sc")) (EListLit (EVar "pat")))) (DoExpr (EApp (EApp (EApp (EVar "dStmts") (EVar "inner")) (EApp (EApp (EApp (EVar "dExpr") (EIf (EVar "r") (EVar "inner") (EVar "sc"))) (EApp (EApp (EVar "dPat") (EVar "acc")) (EVar "pat"))) (EVar "e"))) (EVar "rest")))))
(DFunDef false "dStmts" ((PVar "sc") (PVar "acc") (PCons (PCon "CSAssign" PWild (PVar "e")) (PVar "rest"))) (EApp (EApp (EApp (EVar "dStmts") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "e"))) (EVar "rest")))
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
(DTypeSig false "programUsesStr" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyCon "Bool"))))
(DFunDef false "programUsesStr" ((PVar "facts") (PVar "groups")) (EApp (EApp (EVar "anyBind") (EApp (EVar "bindUsesStr") (EVar "facts"))) (EVar "groups")))
(DTypeSig false "bindUsesStr" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")) (TyFun (TyCon "CBind") (TyCon "Bool"))))
(DFunDef false "bindUsesStr" ((PVar "facts") (PCon "CBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "anyList") (ELam ((PVar "c")) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EApp (EVar "clauseBodyOf") (EVar "c"))))) (EVar "clauses")))
(DTypeSig false "exprUsesStr" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")) (TyFun (TyCon "CExpr") (TyCon "Bool"))))
(DFunDef false "exprUsesStr" (PWild (PCon "CLit" (PCon "LString" PWild))) (EVar "True"))
(DFunDef false "exprUsesStr" (PWild (PCon "CLit" (PCon "LChar" PWild))) (EVar "True"))
(DFunDef false "exprUsesStr" (PWild (PCon "CLit" PWild)) (EVar "False"))
(DFunDef false "exprUsesStr" ((PVar "facts") (PCon "CVar" (PVar "symbol") (PCon "AGlobal"))) (EBinOp "||" (EApp (EVar "isStrModeNameW") (EVar "symbol")) (EMatch (EApp (EApp (EVar "externRuntimeKey") (EVar "facts")) (EVar "symbol")) (arm (PCon "Some" (PVar "key")) () (EApp (EVar "isStrModeNameW") (EVar "key"))) (arm (PCon "None") () (EVar "False")))))
(DFunDef false "exprUsesStr" (PWild (PCon "CVar" (PVar "symbol") PWild)) (EApp (EVar "isStrModeNameW") (EVar "symbol")))
(DFunDef false "exprUsesStr" ((PVar "facts") (PAs "app" (PCon "CApp" PWild PWild PWild))) (EBlock (DoLet false false (PTuple (PVar "hd") (PVar "args")) (EApp (EApp (EVar "flattenApp") (EVar "app")) (EListLit))) (DoExpr (EBinOp "||" (EApp (EApp (EVar "headUsesStr") (EVar "facts")) (EVar "hd")) (EApp (EApp (EVar "anyList") (EApp (EVar "exprUsesStr") (EVar "facts"))) (EVar "args"))))))
(DFunDef false "exprUsesStr" ((PVar "facts") (PCon "CLam" PWild (PVar "b"))) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "b")))
(DFunDef false "exprUsesStr" ((PVar "facts") (PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild PWild)) (EBinOp "||" (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "l")) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "r"))))
(DFunDef false "exprUsesStr" ((PVar "facts") (PCon "CUnOp" PWild (PVar "x"))) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "x")))
(DFunDef false "exprUsesStr" ((PVar "facts") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "c")) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "t"))) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "f"))))
(DFunDef false "exprUsesStr" ((PVar "facts") (PCon "CLet" PWild PWild (PVar "a") (PVar "b"))) (EBinOp "||" (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "a")) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "b"))))
(DFunDef false "exprUsesStr" ((PVar "facts") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EVar "anyList") (EApp (EVar "stmtUsesStr") (EVar "facts"))) (EVar "stmts")))
(DFunDef false "exprUsesStr" ((PVar "facts") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EBinOp "||" (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "scrut")) (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EApp (EVar "armBody") (EVar "a"))))) (EVar "arms"))))
(DFunDef false "exprUsesStr" ((PVar "facts") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EBinOp "||" (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "scrut")) (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EApp (EVar "armBody") (EVar "a"))))) (EVar "arms"))))
(DFunDef false "exprUsesStr" (PWild PWild) (EVar "False"))
(DTypeSig false "stmtUsesStr" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")) (TyFun (TyCon "CStmt") (TyCon "Bool"))))
(DFunDef false "stmtUsesStr" ((PVar "facts") (PCon "CSExpr" (PVar "e"))) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "e")))
(DFunDef false "stmtUsesStr" ((PVar "facts") (PCon "CSLet" PWild PWild (PVar "e"))) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "e")))
(DFunDef false "stmtUsesStr" (PWild PWild) (EVar "False"))
(DTypeSig false "headUsesStr" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")) (TyFun (TyCon "CExpr") (TyCon "Bool"))))
(DFunDef false "headUsesStr" ((PVar "facts") (PVar "h")) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "h")))
(DTypeSig false "isStrModeNameW" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isStrModeNameW" ((PVar "name")) (EMatch (EApp (EVar "wasmFamily") (EVar "name")) (arm (PCon "Some" (PCon "WasmStr")) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "bindUsesClosures" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "CBind") (TyCon "Bool")))))
(DFunDef false "bindUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PCon "CBind" PWild (PVar "clauses") PWild PWild)) (EBinOp "||" (EApp (EVar "multiOrPatternClauses") (EVar "clauses")) (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "clauseUsesClosures") (EVar "fnNames")) (EVar "ctorArs"))) (EVar "clauses"))))
(DTypeSig false "multiOrPatternClauses" (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyCon "Bool")))
(DFunDef false "multiOrPatternClauses" ((PList)) (EVar "False"))
(DFunDef false "multiOrPatternClauses" ((PList (PCon "CClause" (PVar "pats") PWild))) (EApp (EApp (EVar "anyList") (ELam ((PVar "p")) (EApp (EVar "not") (EApp (EVar "isPlainParam") (EVar "p"))))) (EVar "pats")))
(DFunDef false "multiOrPatternClauses" (PWild) (EVar "True"))
(DTypeSig false "isPlainParam" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "isPlainParam" ((PCon "PVar" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isPlainParam" ((PCon "PWild")) (EVar "True"))
(DFunDef false "isPlainParam" (PWild) (EVar "False"))
(DTypeSig false "clauseUsesClosures" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "CClause") (TyCon "Bool")))))
(DFunDef false "clauseUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EApp (EApp (EVar "flatMap") (EVar "patVars")) (EVar "pats"))) (EVar "body")))
(DTypeSig false "exprUsesClosures" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CExpr") (TyCon "Bool"))))))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCon "CLam" PWild PWild)) (EVar "True"))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PAs "app" (PCon "CApp" PWild PWild PWild))) (EApp (EApp (EApp (EApp (EVar "appUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "app")))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCon "CVar" (PVar "x") PWild)) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "x")) (EVar "locals"))) (EApp (EApp (EVar "fnMemberIndexW") (EVar "fnNames")) (EVar "x"))))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCon "CLit" PWild)) (EVar "False"))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild PWild)) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "l")) (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "r"))))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCon "CUnOp" PWild (PVar "x"))) (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "x")))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "c")) (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "t"))) (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "f"))))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCon "CLet" PWild (PVar "pat") (PVar "a") (PVar "b"))) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EBinOp "++" (EApp (EVar "patVars") (EVar "pat")) (EVar "locals"))) (EVar "b"))))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EVar "blockUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "stmts")))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "scrut")) (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EApp (EVar "armBody") (EVar "a"))))) (EVar "arms"))))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "scrut")) (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EApp (EVar "armBody") (EVar "a"))))) (EVar "arms"))))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") PWild) (EVar "False"))
(DTypeSig false "blockUsesClosures" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyCon "Bool"))))))
(DFunDef false "blockUsesClosures" (PWild PWild PWild (PList)) (EVar "False"))
(DFunDef false "blockUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCons (PCon "CSLet" PWild (PVar "pat") (PVar "e")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "e")) (EApp (EApp (EApp (EApp (EVar "blockUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EBinOp "++" (EApp (EVar "patVars") (EVar "pat")) (EVar "locals"))) (EVar "rest"))))
(DFunDef false "blockUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCons (PCon "CSExpr" (PVar "e")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "e")) (EApp (EApp (EApp (EApp (EVar "blockUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "rest"))))
(DFunDef false "blockUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "blockUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "rest")))
(DTypeSig false "appUsesClosures" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CExpr") (TyCon "Bool"))))))
(DFunDef false "appUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PVar "app")) (EBlock (DoLet false false (PTuple (PVar "hd") (PVar "args") (PVar "mode")) (EApp (EVar "appParts") (EVar "app"))) (DoLet false false (PVar "argsClos") (EApp (EApp (EVar "anyList") (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals"))) (EVar "args"))) (DoExpr (EMatch (EVar "hd") (arm (PCon "CVar" (PVar "f") PWild) () (EIf (EApp (EApp (EVar "contains") (EVar "f")) (EVar "locals")) (EVar "True") (EIf (EApp (EApp (EVar "fnMemberIndexW") (EVar "fnNames")) (EVar "f")) (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isExactCall") (EVar "mode"))) (EVar "argsClos")) (EIf (EBinOp "||" (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "f")) (EVar "ctorArs"))) (EApp (EVar "isReservedCtor") (EVar "f"))) (EVar "argsClos") (EVar "True"))))) (arm PWild () (EVar "True"))))))
(DTypeSig false "programUsesAdt" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "Bool"))))
(DFunDef false "programUsesAdt" ((PVar "groups") (PVar "ctorArs")) (EBinOp "||" (EBinOp "/=" (EApp (EVar "listLen") (EVar "ctorArs")) (ELit (LInt 0))) (EApp (EVar "anyBindHasDecision") (EVar "groups"))))
(DTypeSig false "anyBindHasDecision" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyCon "Bool")))
(DFunDef false "anyBindHasDecision" ((PList)) (EVar "False"))
(DFunDef false "anyBindHasDecision" ((PCons (PCon "CBind" PWild (PVar "clauses") PWild PWild) (PVar "rest"))) (EIf (EApp (EVar "anyClauseHasDecision") (EVar "clauses")) (EVar "True") (EApp (EVar "anyBindHasDecision") (EVar "rest"))))
(DTypeSig false "anyClauseHasDecision" (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyCon "Bool")))
(DFunDef false "anyClauseHasDecision" ((PList)) (EVar "False"))
(DFunDef false "anyClauseHasDecision" ((PCons (PCon "CClause" PWild (PVar "body")) (PVar "rest"))) (EIf (EApp (EVar "exprHasDecision") (EVar "body")) (EVar "True") (EApp (EVar "anyClauseHasDecision") (EVar "rest"))))
(DTypeSig false "exprHasDecision" (TyFun (TyCon "CExpr") (TyCon "Bool")))
(DFunDef false "exprHasDecision" ((PCon "CDecision" PWild PWild PWild)) (EVar "True"))
(DFunDef false "exprHasDecision" ((PCon "CMatch" PWild PWild)) (EVar "True"))
(DFunDef false "exprHasDecision" ((PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "||" (EBinOp "||" (EApp (EVar "exprHasDecision") (EVar "c")) (EApp (EVar "exprHasDecision") (EVar "t"))) (EApp (EVar "exprHasDecision") (EVar "f"))))
(DFunDef false "exprHasDecision" ((PCon "CLet" PWild PWild (PVar "a") (PVar "b"))) (EBinOp "||" (EApp (EVar "exprHasDecision") (EVar "a")) (EApp (EVar "exprHasDecision") (EVar "b"))))
(DFunDef false "exprHasDecision" ((PCon "CBinPrim" PWild (PVar "a") (PVar "b") PWild PWild)) (EBinOp "||" (EApp (EVar "exprHasDecision") (EVar "a")) (EApp (EVar "exprHasDecision") (EVar "b"))))
(DFunDef false "exprHasDecision" ((PCon "CUnOp" PWild (PVar "a"))) (EApp (EVar "exprHasDecision") (EVar "a")))
(DFunDef false "exprHasDecision" ((PCon "CApp" (PVar "f") (PVar "args") PWild)) (EBinOp "||" (EApp (EVar "exprHasDecision") (EVar "f")) (EApp (EApp (EVar "anyList") (EVar "exprHasDecision")) (EVar "args"))))
(DFunDef false "exprHasDecision" ((PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EVar "anyList") (EVar "stmtHasDecision")) (EVar "stmts")))
(DFunDef false "exprHasDecision" (PWild) (EVar "False"))
(DTypeSig false "stmtHasDecision" (TyFun (TyCon "CStmt") (TyCon "Bool")))
(DFunDef false "stmtHasDecision" ((PCon "CSExpr" (PVar "e"))) (EApp (EVar "exprHasDecision") (EVar "e")))
(DFunDef false "stmtHasDecision" ((PCon "CSLet" PWild PWild (PVar "e"))) (EApp (EVar "exprHasDecision") (EVar "e")))
(DFunDef false "stmtHasDecision" (PWild) (EVar "False"))
(DTypeSig false "anyBind" (TyFun (TyFun (TyCon "CBind") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyCon "Bool"))))
(DFunDef false "anyBind" (PWild (PList)) (EVar "False"))
(DFunDef false "anyBind" ((PVar "p") (PCons (PVar "b") (PVar "rest"))) (EBinOp "||" (EApp (EVar "p") (EVar "b")) (EApp (EApp (EVar "anyBind") (EVar "p")) (EVar "rest"))))
(DTypeSig false "fnMemberIndexW" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "fnMemberIndexW" ((PVar "names") (PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "names")))
(DTypeSig false "isReservedCtor" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isReservedCtor" ((PVar "n")) (EApp (EApp (EVar "contains") (EVar "n")) (EListLit (ELit (LString "Some")) (ELit (LString "None")) (ELit (LString "Ok")) (ELit (LString "Err")) (ELit (LString "Lt")) (ELit (LString "Eq")) (ELit (LString "Gt")))))
(DData Public "WasmTypeContext" () ((variant "WasmTypeContext" (ConNamed (field "rows" (TyApp (TyCon "OrdMap") (TyCon "BinderRow"))) (field "tops" (TyApp (TyCon "OrdMap") (TyCon "BinderRow"))) (field "fnNames" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "valNames" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "externFacts" (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact"))) (field "ctorFloatFields" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int")))) (field "ctorArities" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))) ())
(DTypeSig true "wasmTypeContext" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "CProgram") (TyCon "WasmTypeContext"))))
(DFunDef false "wasmTypeContext" ((PVar "ctorFields") (PCon "CProgram" (PVar "groups") (PVar "ctorArs") PWild PWild PWild (PVar "facts"))) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EVar "map") (ELam ((PVar "row")) (ETuple (EApp (EVar "intToString") (EApp (EVar "binderOrdinal") (EFieldAccess (EVar "row") "brId"))) (EVar "row")))) (EFieldAccess (EVar "facts") "factBinders")))) (EVar "omEmpty"))) (DoExpr (ERecordCreate "WasmTypeContext" ((fa "rows" (EVar "rows")) (fa "tops" (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EVar "filterMap") (ELam ((PCon "CBind" (PVar "n") PWild PWild (PVar "bid"))) (EApp (EApp (EVar "map") (ELam ((PVar "row")) (ETuple (EVar "n") (EVar "row")))) (EApp (EApp (EVar "omLookup") (EApp (EVar "intToString") (EApp (EVar "binderOrdinal") (EVar "bid")))) (EVar "rows"))))) (EVar "groups")))) (EVar "omEmpty"))) (fa "fnNames" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "bindName")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EBinOp "&&" (EBinOp "/=" (EApp (EVar "bindName") (EVar "b")) (ELit (LString "main"))) (EApp (EVar "not") (EApp (EVar "isValBind") (EVar "b")))))) (EVar "groups")))) (EVar "omEmpty"))) (fa "valNames" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "bindName")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EBinOp "&&" (EBinOp "/=" (EApp (EVar "bindName") (EVar "b")) (ELit (LString "main"))) (EApp (EVar "isValBind") (EVar "b"))))) (EVar "groups")))) (EVar "omEmpty"))) (fa "externFacts" (EFieldAccess (EVar "facts") "factExterns")) (fa "ctorFloatFields" (EVar "ctorFields")) (fa "ctorArities" (EVar "ctorArs")))))))
(DTypeSig false "runtimeKeyD" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "runtimeKeyD" ((PVar "ctx") (PVar "symbol")) (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EApp (EVar "externRuntimeKey") (EFieldAccess (EVar "ctx") "externFacts")) (EVar "symbol"))))
(DTypeSig true "envMark" (TyFun (TyCon "String") (TyFun (TyCon "BinderId") (TyCon "String"))))
(DFunDef false "envMark" ((PVar "x") (PVar "bid")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString "@"))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "binderOrdinal") (EVar "bid"))))) (ELit (LString ""))))
(DTypeSig true "envBind" (TyFun (TyCon "String") (TyFun (TyCon "BinderId") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "envBind" ((PVar "x") (PVar "bid") (PVar "env")) (EBinOp "::" (EVar "x") (EBinOp "::" (EApp (EApp (EVar "envMark") (EVar "x")) (EVar "bid")) (EVar "env"))))
(DTypeSig true "paramEnv" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "paramEnv" ((PVar "pats")) (EApp (EApp (EVar "flatMap") (EVar "paramEntries")) (EVar "pats")))
(DTypeSig true "paramEntries" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "paramEntries" ((PCon "PVar" (PVar "x") PWild (PVar "bid"))) (EListLit (EVar "x") (EApp (EApp (EVar "envMark") (EVar "x")) (EVar "bid"))))
(DFunDef false "paramEntries" (PWild) (EListLit (ELit (LString "_"))))
(DTypeSig true "patBinders" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "BinderId")))))
(DFunDef false "patBinders" ((PCon "PVar" (PVar "x") PWild (PVar "bid"))) (EListLit (ETuple (EVar "x") (EVar "bid"))))
(DFunDef false "patBinders" ((PCon "PAs" (PVar "x") PWild (PVar "bid") (PVar "p"))) (EBinOp "::" (ETuple (EVar "x") (EVar "bid")) (EApp (EVar "patBinders") (EVar "p"))))
(DFunDef false "patBinders" ((PCon "PCon" PWild (PVar "args"))) (EApp (EApp (EVar "flatMap") (EVar "patBinders")) (EVar "args")))
(DFunDef false "patBinders" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patBinders")) (EVar "ps")))
(DFunDef false "patBinders" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "++" (EApp (EVar "patBinders") (EVar "h")) (EApp (EVar "patBinders") (EVar "t"))))
(DFunDef false "patBinders" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EVar "patBinders")) (EVar "ps")))
(DFunDef false "patBinders" (PWild) (EListLit))
(DTypeSig true "envBindPat" (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "envBindPat" ((PVar "pat") (PVar "env")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "b")) (EApp (EApp (EApp (EVar "envBind") (EApp (EVar "fst") (EVar "b"))) (EApp (EVar "snd") (EVar "b"))) (EVar "acc")))) (EVar "env")) (EApp (EVar "patBinders") (EVar "pat"))))
(DTypeSig true "envMarksOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "envMarksOf" ((PVar "names") (PVar "env")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "x")) (EApp (EApp (EVar "envMarkOf") (EVar "x")) (EVar "env")))) (EVar "names")))
(DTypeSig true "envWithMarks" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "envWithMarks" ((PVar "names") (PVar "marks")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "x")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "filterList") (EApp (EVar "startsWith") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString "@"))))) (EVar "marks"))))) (EVar "names")))
(DTypeSig true "envMarkOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "envMarkOf" ((PVar "x") (PVar "env")) (EMatch (EApp (EApp (EVar "envLookup") (EVar "x")) (EVar "env")) (arm (PCon "LocalBinder" (PVar "ord")) () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString "@"))) (EApp (EVar "display") (EVar "ord"))) (ELit (LString ""))))) (arm PWild () (EListLit))))
(DData Public "EnvRef" () ((variant "NotLocal" (ConPos)) (variant "LocalUnstamped" (ConPos)) (variant "LocalBinder" (ConPos (TyCon "String")))) ())
(DTypeSig true "envLookup" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "EnvRef"))))
(DFunDef false "envLookup" (PWild (PList)) (EVar "NotLocal"))
(DFunDef false "envLookup" ((PVar "x") (PCons (PVar "e") (PVar "rest"))) (EIf (EBinOp "==" (EVar "e") (EVar "x")) (EMatch (EVar "rest") (arm (PCons (PVar "m") PWild) () (EIf (EApp (EApp (EVar "startsWith") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "x"))) (ELit (LString "@")))) (EVar "m")) (EApp (EVar "LocalBinder") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EApp (EVar "stringLength") (EVar "x")) (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "m"))) (EVar "m"))) (EVar "LocalUnstamped"))) (arm (PList) () (EVar "LocalUnstamped"))) (EApp (EApp (EVar "envLookup") (EVar "x")) (EVar "rest"))))
(DTypeSig false "stampRowOf" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "BinderRow")))))
(DFunDef false "stampRowOf" ((PVar "prog") (PVar "ord")) (EApp (EApp (EVar "omLookup") (EVar "ord")) (EFieldAccess (EVar "prog") "rows")))
(DTypeSig true "varRow" (TyFun (TyCon "WasmTypeContext") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "BinderRow"))))))
(DFunDef false "varRow" ((PVar "prog") (PVar "env") (PVar "x")) (EMatch (EApp (EApp (EVar "envLookup") (EVar "x")) (EVar "env")) (arm (PCon "LocalBinder" (PVar "ord")) () (EApp (EApp (EVar "stampRowOf") (EVar "prog")) (EVar "ord"))) (arm (PCon "LocalUnstamped") () (EVar "None")) (arm (PCon "NotLocal") () (EApp (EApp (EVar "omLookup") (EVar "x")) (EFieldAccess (EVar "prog") "tops")))))
(DTypeSig true "varStamp" (TyFun (TyCon "WasmTypeContext") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "RuntimeType")))))
(DFunDef false "varStamp" ((PVar "prog") (PVar "env") (PVar "x")) (EMatch (EApp (EApp (EApp (EVar "varRow") (EVar "prog")) (EVar "env")) (EVar "x")) (arm (PCon "Some" (PVar "row")) () (EFieldAccess (EVar "row") "brType")) (arm (PCon "None") () (EVar "RTValue"))))
(DTypeSig true "returnStamp" (TyFun (TyCon "WasmTypeContext") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "RuntimeType")))))
(DFunDef false "returnStamp" ((PVar "prog") (PVar "env") (PVar "fn")) (EMatch (EApp (EApp (EApp (EVar "varRow") (EVar "prog")) (EVar "env")) (EVar "fn")) (arm (PCon "Some" (PVar "row")) () (EApp (EApp (EVar "optionOr") (EVar "RTValue")) (EFieldAccess (EVar "row") "brReturns"))) (arm (PCon "None") () (EIf (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "fn")) (EVar "env")) (EApp (EApp (EVar "omHasKey") (EVar "fn")) (EFieldAccess (EVar "prog") "fnNames"))) (EApp (EApp (EVar "omHasKey") (EVar "fn")) (EFieldAccess (EVar "prog") "valNames"))) (EVar "RTValue") (EApp (EVar "externResultStamp") (EApp (EApp (EVar "runtimeKeyD") (EVar "prog")) (EVar "fn")))))))
(DTypeSig false "externResultStamp" (TyFun (TyCon "String") (TyCon "RuntimeType")))
(DFunDef false "externResultStamp" ((PVar "fn")) (EIf (EApp (EApp (EVar "contains") (EVar "fn")) (EListLit (ELit (LString "intToString")) (ELit (LString "charToStr")) (ELit (LString "stringConcat")) (ELit (LString "stringSlice")) (ELit (LString "stringToUpper")) (ELit (LString "stringToLower")) (ELit (LString "floatToString")) (ELit (LString "stringFromChars")) (ELit (LString "stringFromUtf8Bytes")))) (EVar "RTString") (EIf (EApp (EApp (EVar "contains") (EVar "fn")) (EListLit (ELit (LString "randomBool")) (ELit (LString "charIsAlpha")) (ELit (LString "charIsSpace")) (ELit (LString "charIsUpper")) (ELit (LString "charIsLower")) (ELit (LString "charIsPunct")))) (EVar "RTBool") (EIf (EApp (EApp (EVar "contains") (EVar "fn")) (EListLit (ELit (LString "randomChar")) (ELit (LString "charToUpper")) (ELit (LString "charToLower")))) (EVar "RTChar") (EIf (EApp (EApp (EVar "contains") (EVar "fn")) (EListLit (ELit (LString "intToFloat")) (ELit (LString "randomFloat")))) (EVar "RTFloat") (EIf (EApp (EApp (EVar "contains") (EVar "fn")) (EListLit (ELit (LString "putStr")) (ELit (LString "putStrLn")) (ELit (LString "ePutStr")) (ELit (LString "ePutStrLn")) (ELit (LString "flushStdout")))) (EVar "RTUnit") (EVar "RTValue")))))))
(DTypeSig true "cexprStamp" (TyFun (TyCon "WasmTypeContext") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CExpr") (TyCon "RuntimeType")))))
(DFunDef false "cexprStamp" (PWild PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "litRuntimeType") (EVar "l")))
(DFunDef false "cexprStamp" (PWild PWild (PCon "CVar" (PLit (LString "True")) PWild)) (EVar "RTBool"))
(DFunDef false "cexprStamp" (PWild PWild (PCon "CVar" (PLit (LString "False")) PWild)) (EVar "RTBool"))
(DFunDef false "cexprStamp" ((PVar "prog") (PVar "env") (PCon "CVar" (PVar "x") PWild)) (EIf (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "runtimeKeyD") (EVar "prog")) (EVar "x")) (ELit (LString "pi"))) (EBinOp "==" (EApp (EApp (EVar "runtimeKeyD") (EVar "prog")) (EVar "x")) (ELit (LString "e")))) (EVar "RTFloat") (EApp (EApp (EApp (EVar "varStamp") (EVar "prog")) (EVar "env")) (EVar "x"))))
(DFunDef false "cexprStamp" ((PVar "prog") (PVar "env") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") PWild)) (EIf (EApp (EVar "isCmpOp") (EVar "op")) (EVar "RTBool") (EIf (EBinOp "==" (EVar "op") (ELit (LString "::"))) (EVar "RTCon") (EIf (EApp (EVar "isArithOp") (EVar "op")) (EApp (EApp (EApp (EApp (EApp (EVar "arithStamp") (EVar "prog")) (EVar "env")) (EVar "tag")) (EVar "l")) (EVar "r")) (EApp (EApp (EVar "appendStamp") (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EVar "env")) (EVar "l"))) (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EVar "env")) (EVar "r")))))))
(DFunDef false "cexprStamp" ((PVar "prog") (PVar "env") (PCon "CUnOp" (PLit (LString "-")) (PVar "x"))) (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EVar "env")) (EVar "x")))
(DFunDef false "cexprStamp" ((PVar "prog") (PVar "env") (PCon "CIf" PWild (PVar "t") (PVar "f"))) (EApp (EApp (EVar "stampOrElse") (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EVar "env")) (EVar "t"))) (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EVar "env")) (EVar "f"))))
(DFunDef false "cexprStamp" ((PVar "prog") (PVar "env") (PCon "CLet" PWild (PVar "pat") PWild (PVar "b"))) (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EApp (EApp (EVar "envBindPat") (EVar "pat")) (EVar "env"))) (EVar "b")))
(DFunDef false "cexprStamp" ((PVar "prog") (PVar "env") (PCon "CLetGroup" (PVar "binds") (PVar "b"))) (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EApp (EApp (EVar "envBindGroups") (EVar "binds")) (EVar "env"))) (EVar "b")))
(DFunDef false "cexprStamp" ((PVar "prog") (PVar "env") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EApp (EVar "blockStamp") (EVar "prog")) (EVar "env")) (EVar "stmts")))
(DFunDef false "cexprStamp" ((PVar "prog") (PVar "env") (PCon "CDecision" PWild (PVar "arms") PWild)) (EApp (EApp (EApp (EVar "armsStamp") (EVar "prog")) (EVar "env")) (EVar "arms")))
(DFunDef false "cexprStamp" ((PVar "prog") (PVar "env") (PCon "CMatch" PWild (PVar "arms"))) (EApp (EApp (EApp (EVar "armsStamp") (EVar "prog")) (EVar "env")) (EVar "arms")))
(DFunDef false "cexprStamp" ((PVar "prog") (PVar "env") (PAs "app" (PCon "CApp" PWild PWild (PCon "CallSite" (PVar "mode") PWild)))) (EMatch (EVar "mode") (arm (PCon "CallPartial" PWild) () (EVar "RTValue")) (arm (PCon "CallOver" PWild) () (EVar "RTValue")) (arm PWild () (EMatch (EApp (EVar "appHead") (EVar "app")) (arm (PCon "CVar" (PVar "fn") PWild) () (EApp (EApp (EApp (EVar "returnStamp") (EVar "prog")) (EVar "env")) (EVar "fn"))) (arm (PCon "CDict" (PVar "fn") PWild) () (EApp (EApp (EApp (EVar "returnStamp") (EVar "prog")) (EVar "env")) (EVar "fn"))) (arm PWild () (EVar "RTValue"))))))
(DFunDef false "cexprStamp" ((PVar "prog") PWild (PCon "CFieldAccess" PWild PWild (PVar "recName") (PVar "ord"))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "ord") (ELit (LInt 0))) (EApp (EApp (EVar "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "ord")))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "recName")) (EFieldAccess (EVar "prog") "ctorFloatFields"))))) (EVar "RTFloat") (EVar "RTValue")))
(DFunDef false "cexprStamp" (PWild PWild PWild) (EVar "RTValue"))
(DTypeSig false "appendStamp" (TyFun (TyCon "RuntimeType") (TyFun (TyCon "RuntimeType") (TyCon "RuntimeType"))))
(DFunDef false "appendStamp" ((PCon "RTValue") (PCon "RTValue")) (EVar "RTString"))
(DFunDef false "appendStamp" ((PVar "a") (PCon "RTValue")) (EVar "a"))
(DFunDef false "appendStamp" (PWild (PVar "b")) (EVar "b"))
(DTypeSig false "arithStamp" (TyFun (TyCon "WasmTypeContext") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "CExpr") (TyFun (TyCon "CExpr") (TyCon "RuntimeType")))))))
(DFunDef false "arithStamp" ((PVar "prog") (PVar "env") (PVar "tag") (PVar "l") (PVar "r")) (EIf (EBinOp "==" (EVar "tag") (ELit (LString "Float"))) (EVar "RTFloat") (EIf (EBinOp "==" (EVar "tag") (ELit (LString "U64"))) (EVar "RTU64") (EIf (EBinOp "==" (EVar "tag") (ELit (LString "I64"))) (EVar "RTI64") (EIf (EApp (EVar "isTaggedFixedHead") (EVar "tag")) (EVar "RTInt") (EApp (EApp (EVar "stampOrElse") (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EVar "env")) (EVar "l"))) (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EVar "env")) (EVar "r"))))))))
(DTypeSig false "stampOrElse" (TyFun (TyCon "RuntimeType") (TyFun (TyCon "RuntimeType") (TyCon "RuntimeType"))))
(DFunDef false "stampOrElse" ((PCon "RTValue") (PVar "b")) (EVar "b"))
(DFunDef false "stampOrElse" ((PVar "a") PWild) (EVar "a"))
(DTypeSig true "envBindGroup" (TyFun (TyCon "CBind") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "envBindGroup" ((PCon "CBind" (PVar "name") PWild PWild (PVar "bid")) (PVar "env")) (EApp (EApp (EApp (EVar "envBind") (EVar "name")) (EVar "bid")) (EVar "env")))
(DTypeSig true "envBindGroups" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "envBindGroups" ((PVar "binds") (PVar "env")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "g")) (EApp (EApp (EVar "envBindGroup") (EVar "g")) (EVar "acc")))) (EVar "env")) (EVar "binds")))
(DTypeSig true "groupBindMark" (TyFun (TyCon "CBind") (TyCon "String")))
(DFunDef false "groupBindMark" ((PCon "CBind" (PVar "name") PWild PWild (PVar "bid"))) (EApp (EApp (EVar "envMark") (EVar "name")) (EVar "bid")))
(DTypeSig false "blockStamp" (TyFun (TyCon "WasmTypeContext") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyCon "RuntimeType")))))
(DFunDef false "blockStamp" (PWild PWild (PList)) (EVar "RTValue"))
(DFunDef false "blockStamp" ((PVar "prog") (PVar "env") (PList (PCon "CSExpr" (PVar "e")))) (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EVar "env")) (EVar "e")))
(DFunDef false "blockStamp" ((PVar "prog") (PVar "env") (PCons (PCon "CSLet" PWild (PVar "pat") PWild) (PVar "rest"))) (EApp (EApp (EApp (EVar "blockStamp") (EVar "prog")) (EApp (EApp (EVar "envBindPat") (EVar "pat")) (EVar "env"))) (EVar "rest")))
(DFunDef false "blockStamp" ((PVar "prog") (PVar "env") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EVar "blockStamp") (EVar "prog")) (EVar "env")) (EVar "rest")))
(DTypeSig false "armsStamp" (TyFun (TyCon "WasmTypeContext") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyCon "RuntimeType")))))
(DFunDef false "armsStamp" (PWild PWild (PList)) (EVar "RTValue"))
(DFunDef false "armsStamp" ((PVar "prog") (PVar "env") (PCons (PCon "CArm" (PVar "pat") PWild (PVar "body")) (PVar "rest"))) (EApp (EApp (EVar "stampOrElse") (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EApp (EApp (EVar "envBindPat") (EVar "pat")) (EVar "env"))) (EVar "body"))) (EApp (EApp (EApp (EVar "armsStamp") (EVar "prog")) (EVar "env")) (EVar "rest"))))
(DTypeSig true "isPolyNumBinop" (TyFun (TyCon "WasmTypeContext") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CExpr") (TyFun (TyCon "CExpr") (TyCon "Bool"))))))
(DFunDef false "isPolyNumBinop" ((PVar "prog") (PVar "env") (PVar "l") (PVar "r")) (EBinOp "||" (EApp (EApp (EApp (EVar "isPolyNumOperand") (EVar "prog")) (EVar "env")) (EVar "l")) (EApp (EApp (EApp (EVar "isPolyNumOperand") (EVar "prog")) (EVar "env")) (EVar "r"))))
(DTypeSig false "isPolyNumOperand" (TyFun (TyCon "WasmTypeContext") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CExpr") (TyCon "Bool")))))
(DFunDef false "isPolyNumOperand" ((PVar "prog") (PVar "env") (PCon "CVar" (PVar "x") PWild)) (EMatch (EApp (EApp (EApp (EVar "varRow") (EVar "prog")) (EVar "env")) (EVar "x")) (arm (PCon "Some" (PVar "row")) () (EBinOp "==" (EFieldAccess (EVar "row") "brType") (EVar "RTValue"))) (arm (PCon "None") () (EVar "False"))))
(DFunDef false "isPolyNumOperand" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "isArithOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isArithOp" ((PVar "op")) (EApp (EApp (EVar "contains") (EVar "op")) (EListLit (ELit (LString "+")) (ELit (LString "-")) (ELit (LString "*")) (ELit (LString "/")) (ELit (LString "%")))))
(DTypeSig true "isCmpOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isCmpOp" ((PVar "op")) (EApp (EApp (EVar "contains") (EVar "op")) (EListLit (ELit (LString "==")) (ELit (LString "/=")) (ELit (LString "<")) (ELit (LString ">")) (ELit (LString "<=")) (ELit (LString ">=")))))
(DTypeSig false "appHead" (TyFun (TyCon "CExpr") (TyCon "CExpr")))
(DFunDef false "appHead" ((PCon "CApp" (PVar "f") PWild PWild)) (EApp (EVar "appHead") (EVar "f")))
(DFunDef false "appHead" ((PVar "e")) (EVar "e"))
(DData Public "WasmDemandInputs" () ((variant "WasmDemandInputs" (ConNamed (field "ctorFloatFields" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int")))) (field "lazyGlobals" (TyApp (TyCon "List") (TyCon "String"))) (field "globalInit" (TyCon "GlobalInitPlan")) (field "trmcVerdicts" (TyCon "TrmcVerdicts")) (field "dispatchGroups" (TyApp (TyCon "List") (TyCon "DispGroup")))))) ())
(DData Public "PlannedImport" () ((variant "PlannedImport" (ConNamed (field "namespace" (TyCon "String")) (field "field" (TyCon "String")) (field "watSymbol" (TyCon "String")) (field "signature" (TyCon "String"))))) ())
(DImpl true "Eq" ((TyCon "PlannedImport")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "PlannedImport" ((rf "namespace" (PVar "__a0")) (rf "field" (PVar "__a1")) (rf "watSymbol" (PVar "__a2")) (rf "signature" (PVar "__a3"))) false) (PRec "PlannedImport" ((rf "namespace" (PVar "__b0")) (rf "field" (PVar "__b1")) (rf "watSymbol" (PVar "__b2")) (rf "signature" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EVar "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "PlannedImport")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "PlannedImport" ((rf "namespace" (PVar "__a0")) (rf "field" (PVar "__a1")) (rf "watSymbol" (PVar "__a2")) (rf "signature" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "PlannedImport {")) (ELit (LString " namespace = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", field = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString ", watSymbol = "))) (EApp (EVar "debug") (EVar "__a2"))) (ELit (LString ", signature = "))) (EApp (EVar "debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DData Public "WasmDemandPlan" () ((variant "WasmDemandPlan" (ConNamed (field "sourceDemand" (TyCon "WasmDemand")) (field "sourceHostKeys" (TyApp (TyCon "List") (TyCon "String"))) (field "jsImports" (TyApp (TyCon "List") (TyCon "JsImport"))) (field "useRef" (TyCon "Bool")) (field "useClos" (TyCon "Bool")) (field "stringOps" (TyCon "Bool")) (field "representation" (TyCon "WasmDemand")) (field "representationTypes" (TyApp (TyCon "List") (TyCon "String"))) (field "helpers" (TyApp (TyCon "List") (TyCon "String"))) (field "intHelpers" (TyApp (TyCon "List") (TyCon "String"))) (field "censusHelpers" (TyApp (TyCon "List") (TyCon "String"))) (field "censusIntHelpers" (TyApp (TyCon "List") (TyCon "String"))) (field "siteRuntime" (TyCon "Bool")) (field "nonexhaustiveRuntime" (TyCon "Bool")) (field "imports" (TyApp (TyCon "List") (TyCon "PlannedImport"))) (field "catalogFamilies" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "WasmFamily"))))))) ())
(DData Private "HelperAcc" () ((variant "HelperAcc" (ConNamed (field "helpers" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "ints" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "site" (TyCon "Bool")) (field "nonexh" (TyCon "Bool")) (field "patternTuples" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "patternList" (TyCon "Bool")) (field "refRead" (TyCon "Bool"))))) ())
(DTypeSig false "emptyHelpers" (TyCon "HelperAcc"))
(DFunDef false "emptyHelpers" () (ERecordCreate "HelperAcc" ((fa "helpers" (EVar "omEmpty")) (fa "ints" (EVar "omEmpty")) (fa "site" (EVar "False")) (fa "nonexh" (EVar "False")) (fa "patternTuples" (EVar "omEmpty")) (fa "patternList" (EVar "False")) (fa "refRead" (EVar "False")))))
(DTypeSig false "need" (TyFun (TyCon "HelperAcc") (TyFun (TyCon "String") (TyCon "HelperAcc"))))
(DFunDef false "need" ((PVar "acc") (PVar "name")) (ERecordUpdate (EVar "acc") ((fa "helpers" (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EFieldAccess (EVar "acc") "helpers"))))))
(DTypeSig false "needMany" (TyFun (TyCon "HelperAcc") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "HelperAcc"))))
(DFunDef false "needMany" () (EApp (EVar "fold") (EVar "need")))
(DTypeSig false "needTrap" (TyFun (TyCon "HelperAcc") (TyCon "HelperAcc")))
(DFunDef false "needTrap" ((PVar "acc")) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "stderrByteImportLines"))))
(DTypeSig false "needSite" (TyFun (TyCon "HelperAcc") (TyCon "HelperAcc")))
(DFunDef false "needSite" ((PVar "acc")) (ERecordUpdate (EApp (EApp (EVar "needMany") (EVar "acc")) (EListLit (ELit (LString "siteRuntimeLines")) (ELit (LString "trapIntRuntimeLines")) (ELit (LString "stderrByteImportLines")))) ((fa "site" (EVar "True")))))
(DTypeSig false "needInt" (TyFun (TyCon "HelperAcc") (TyFun (TyCon "String") (TyCon "HelperAcc"))))
(DFunDef false "needInt" ((PVar "acc") (PVar "name")) (ERecordUpdate (EApp (EVar "needSite") (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "intRuntimeLines")))) ((fa "ints" (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EFieldAccess (EVar "acc") "ints"))))))
(DTypeSig true "wasmFamilyTag" (TyFun (TyCon "WasmFamily") (TyCon "String")))
(DFunDef false "wasmFamilyTag" ((PCon "WasmStr")) (ELit (LString "str")))
(DFunDef false "wasmFamilyTag" ((PCon "WasmLeaf")) (ELit (LString "leaf")))
(DFunDef false "wasmFamilyTag" ((PCon "WasmArray")) (ELit (LString "array")))
(DFunDef false "wasmFamilyTag" ((PCon "WasmByteBlock")) (ELit (LString "bytes")))
(DFunDef false "wasmFamilyTag" ((PCon "WasmRefCell")) (ELit (LString "ref")))
(DFunDef false "wasmFamilyTag" ((PCon "WasmConstant")) (ELit (LString "constant")))
(DFunDef false "wasmFamilyTag" ((PCon "WasmFallthrough")) (ELit (LString "fallthrough")))
(DTypeSig false "catalogFamilies" (TyFun (TyCon "ExternRequirements") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "WasmFamily")))))
(DFunDef false "catalogFamilies" ((PVar "req")) (EApp (EApp (EVar "filterMap") (ELam ((PVar "row")) (EMatch (EFieldAccess (EVar "row") "selectedBinding") (arm (PCon "RuntimeRequirement" (PVar "key")) () (EApp (EApp (EVar "map") (ELam ((PVar "family")) (ETuple (EVar "key") (EVar "family")))) (EApp (EVar "wasmFamily") (EVar "key")))) (arm PWild () (EVar "None"))))) (EFieldAccess (EVar "req") "rows")))
(DTypeSig true "planWasmDemand" (TyFun (TyCon "WasmDemandInputs") (TyFun (TyCon "CProgram") (TyFun (TyCon "ExternRequirements") (TyCon "WasmDemandPlan")))))
(DFunDef false "planWasmDemand" ((PVar "inputs") (PAs "cp" (PCon "CProgram" (PVar "groups") (PVar "ctorArs") PWild (PVar "impls") PWild (PVar "facts"))) (PVar "req")) (EBlock (DoLet false false (PTuple (PVar "source") (PVar "hostKeys") PWild) (EApp (EApp (EApp (EApp (EVar "wasmDemandOf") (EApp (EVar "requirementFacts") (EVar "req"))) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EVar "requirementHostRows") (EVar "req")))) (EVar "omEmpty"))) (EVar "groups")) (EVar "impls"))) (DoLet false false (PVar "js") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "symbol") (PTuple (PVar "host") (PTuple (PVar "params") (PVar "result"))))) (ERecordCreate "JsImport" ((fa "medakaName" (EVar "symbol")) (fa "jsName" (EVar "host")) (fa "params" (EVar "params")) (fa "result" (EVar "result")))))) (EApp (EVar "requirementHostRows") (EVar "req")))) (DoLet false false (PVar "str") (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "programUsesStr") (EFieldAccess (EVar "facts") "factExterns")) (EVar "groups")) (EApp (EApp (EVar "hasUse") (EVar "source")) (EVar "UseStr"))) (EApp (EApp (EVar "hasUse") (EVar "source")) (EVar "UseFloat")))) (DoLet false false (PVar "ctx") (EApp (EApp (EVar "wasmTypeContext") (EFieldAccess (EVar "inputs") "ctorFloatFields")) (EVar "cp"))) (DoLet false false (PVar "clos") (EApp (EApp (EVar "anyBind") (EApp (EApp (EVar "bindUsesClosures") (EFieldAccess (EVar "ctx") "fnNames")) (EVar "ctorArs"))) (EVar "groups"))) (DoLet false false (PVar "refMode") (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isNonEmptyL") (EFieldAccess (EVar "inputs") "lazyGlobals")) (EVar "clos")) (EApp (EApp (EVar "programUsesAdt") (EVar "groups")) (EVar "ctorArs"))) (EApp (EVar "isNonEmptyL") (EVar "impls"))) (EVar "str")) (EFieldAccess (EVar "source") "refBox")) (EApp (EVar "isNonEmptyL") (EFieldAccess (EVar "source") "tupleArities"))) (EApp (EApp (EVar "any") (EApp (EVar "hasUse") (EVar "source"))) (EListLit (EVar "UseList") (EVar "UseArray") (EVar "UseRng") (EVar "UseHash") (EVar "UseFloat") (EVar "UseU64") (EVar "UseI64") (EVar "UseStrSearch") (EVar "UseCharClass")))) (EApp (EVar "isNonEmptyL") (EVar "hostKeys"))) (EApp (EVar "isNonEmptyL") (EVar "js")))) (DoLet false false (PVar "roots") (EApp (EApp (EVar "need") (EVar "emptyHelpers")) (ELit (LString "ioRuntimeLines")))) (DoLet false false (PVar "roots") (EIf (EVar "refMode") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "sourceRoots") (EVar "source")) (EVar "str")) (EVar "clos")) (EVar "hostKeys")) (EVar "js")) (EVar "roots")) (EVar "roots"))) (DoLet false false (PVar "roots") (EApp (EApp (EApp (EVar "fold") (EApp (EApp (EApp (EVar "hBind") (EVar "ctx")) (EVar "refMode")) (EVar "str"))) (EVar "roots")) (EVar "groups"))) (DoLet false false (PVar "roots") (EApp (EApp (EApp (EVar "fold") (EApp (EApp (EApp (EVar "hImpl") (EVar "ctx")) (EVar "refMode")) (EVar "str"))) (EVar "roots")) (EVar "impls"))) (DoLet false false (PVar "roots") (EIf (EVar "refMode") (EApp (EApp (EVar "implFailureRoots") (EVar "roots")) (EVar "impls")) (EVar "roots"))) (DoLet false false (PVar "roots") (EIf (EBinOp "&&" (EVar "refMode") (EApp (EVar "isNonEmptyL") (EFieldAccess (EVar "inputs") "lazyGlobals"))) (EApp (EVar "needTrap") (EVar "roots")) (EVar "roots"))) (DoLet false false (PVar "roots") (EIf (EVar "refMode") (EApp (EApp (EApp (EApp (EVar "printRoots") (EVar "ctx")) (EFieldAccess (EVar "facts") "factEntryOutcome")) (EVar "groups")) (EVar "roots")) (EVar "roots"))) (DoLet false false (PVar "families") (EApp (EVar "catalogFamilies") (EVar "req"))) (DoLet false false (PVar "closed") (EApp (EApp (EVar "closeHelpers") (EApp (EApp (EVar "hasUse") (EVar "source")) (EVar "UseI64"))) (EVar "roots"))) (DoLet false false (PVar "census") (EIf (EVar "refMode") (EVar "closed") (EApp (EApp (EVar "closeHelpers") (EApp (EApp (EVar "hasUse") (EVar "source")) (EVar "UseI64"))) (EApp (EApp (EApp (EVar "fold") (EApp (EApp (EApp (EVar "hImpl") (EVar "ctx")) (EVar "True")) (EVar "str"))) (EApp (EApp (EApp (EVar "fold") (EApp (EApp (EApp (EVar "hBind") (EVar "ctx")) (EVar "True")) (EVar "str"))) (EVar "closed")) (EVar "groups"))) (EVar "impls"))))) (DoLet false false (PVar "renderClos") (EBinOp "||" (EVar "clos") (EApp (EApp (EVar "omHasKey") (ELit (LString "closApplyLines"))) (EFieldAccess (EVar "closed") "helpers")))) (DoLet false false (PVar "representation") (EApp (EApp (EApp (EVar "representationOf") (EVar "source")) (EVar "str")) (EVar "closed"))) (DoLet false false (PVar "imports") (EApp (EApp (EApp (EVar "physicalImports") (EVar "closed")) (EVar "hostKeys")) (EVar "js"))) (DoExpr (ERecordCreate "WasmDemandPlan" ((fa "sourceDemand" (EVar "source")) (fa "sourceHostKeys" (EVar "hostKeys")) (fa "jsImports" (EVar "js")) (fa "useRef" (EVar "refMode")) (fa "useClos" (EVar "renderClos")) (fa "stringOps" (EVar "str")) (fa "representation" (EVar "representation")) (fa "representationTypes" (EApp (EApp (EApp (EApp (EVar "physicalTypes") (EVar "cp")) (EVar "refMode")) (EVar "renderClos")) (EVar "representation"))) (fa "helpers" (EApp (EVar "omKeys") (EFieldAccess (EVar "closed") "helpers"))) (fa "intHelpers" (EApp (EVar "omKeys") (EFieldAccess (EVar "closed") "ints"))) (fa "censusHelpers" (EApp (EVar "omKeys") (EFieldAccess (EVar "census") "helpers"))) (fa "censusIntHelpers" (EApp (EVar "omKeys") (EFieldAccess (EVar "census") "ints"))) (fa "siteRuntime" (EFieldAccess (EVar "closed") "site")) (fa "nonexhaustiveRuntime" (EFieldAccess (EVar "closed") "nonexh")) (fa "imports" (EVar "imports")) (fa "catalogFamilies" (EVar "families")))))))
(DTypeSig false "hasUse" (TyFun (TyCon "WasmDemand") (TyFun (TyCon "WasmUse") (TyCon "Bool"))))
(DFunDef false "hasUse" ((PVar "demand") (PVar "u")) (EApp (EApp (EVar "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "u")))) (EFieldAccess (EVar "demand") "uses")))
(DTypeSig false "sourceRoots" (TyFun (TyCon "WasmDemand") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "JsImport")) (TyFun (TyCon "HelperAcc") (TyCon "HelperAcc"))))))))
(DFunDef false "sourceRoots" ((PVar "source") (PVar "str") (PVar "clos") (PVar "keys") (PVar "js") (PVar "acc")) (EBlock (DoLet false false (PVar "acc") (EIf (EVar "clos") (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "closApplyLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EVar "str") (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "ioStrRuntimeLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PTuple (PVar "u") (PVar "block"))) (EIf (EApp (EApp (EVar "hasUse") (EVar "source")) (EVar "u")) (EApp (EApp (EVar "need") (EVar "a")) (EVar "block")) (EVar "a")))) (EVar "acc")) (EListLit (ETuple (EVar "UseStrLeaf") (ELit (LString "strLeafRuntimeLines"))) (ETuple (EVar "UseRng") (ELit (LString "rngRuntimeLines"))) (ETuple (EVar "UseHash") (ELit (LString "hashRuntimeLines"))) (ETuple (EVar "UseFloatHash") (ELit (LString "hashFloatRuntimeLines"))) (ETuple (EVar "UseFloatRng") (ELit (LString "randomFloatRuntimeLines"))) (ETuple (EVar "UseFloat") (ELit (LString "floatRuntimeLines"))) (ETuple (EVar "UseU64") (ELit (LString "u64RuntimeLines"))) (ETuple (EVar "UseI64") (ELit (LString "i64RuntimeLines"))) (ETuple (EVar "UseStrSearch") (ELit (LString "strSearchRuntimeLines"))) (ETuple (EVar "UseStrToInt") (ELit (LString "strToIntRuntimeLines"))) (ETuple (EVar "UseStrReverse") (ELit (LString "strReverseRuntimeLines"))) (ETuple (EVar "UseStrJoin") (ELit (LString "strJoinRuntimeLines"))) (ETuple (EVar "UseStrCodec") (ELit (LString "strCodecRuntimeLines"))) (ETuple (EVar "UseByteBlock") (ELit (LString "byteBlockRuntimeLines"))) (ETuple (EVar "UseCharFromCode") (ELit (LString "charFromCodeRuntimeLines"))) (ETuple (EVar "UseCharClass") (ELit (LString "charClassRuntimeLines"))) (ETuple (EVar "UseEPut") (ELit (LString "stderrRuntimeLines")))))) (DoLet false false (PVar "acc") (EIf (EBinOp "&&" (EApp (EApp (EVar "hasUse") (EVar "source")) (EVar "UseStrLeaf")) (EApp (EApp (EVar "hasUse") (EVar "source")) (EVar "UseList"))) (EApp (EApp (EVar "needMany") (EVar "acc")) (EListLit (ELit (LString "strConcatRuntimeLines")) (ELit (LString "appendRuntimeLines")))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EBinOp "&&" (EApp (EApp (EVar "hasUse") (EVar "source")) (EVar "UseHash")) (EVar "str")) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "hashStringRuntimeLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EApp (EApp (EVar "hasUse") (EVar "source")) (EVar "UseFloat")) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "floatRemRuntimeLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PTuple (PVar "key") (PVar "block"))) (EIf (EApp (EApp (EVar "contains") (EVar "key")) (EVar "keys")) (EApp (EApp (EVar "need") (EVar "a")) (EVar "block")) (EVar "a")))) (EVar "acc")) (EVar "hostHelperRoots"))) (DoLet false false (PVar "acc") (EIf (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (ELit (LString "mdk_file_exists"))) (EVar "keys")) (EApp (EApp (EVar "contains") (ELit (LString "mdk_canonicalize_path"))) (EVar "keys"))) (EApp (EApp (EVar "contains") (ELit (LString "mdk_os_entropy"))) (EVar "keys"))) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "ioRefusedPanicLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EApp (EApp (EVar "contains") (ELit (LString "mdk_os_entropy"))) (EVar "keys")) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "osEntropyLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EBinOp "&&" (EApp (EApp (EVar "contains") (ELit (LString "mdk_read_file"))) (EVar "keys")) (EApp (EApp (EVar "hasUse") (EVar "source")) (EVar "UseFileBytes"))) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "readFileBytesLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EApp (EApp (EVar "contains") (ELit (LString "mdk_write_file_commit"))) (EVar "keys")) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "writeFileBytesLines"))) (EVar "acc"))) (DoLet false false (PVar "heads") (EApp (EApp (EVar "flatMap") (ELam ((PVar "imp")) (EFieldAccess (EVar "imp") "params"))) (EVar "js"))) (DoLet false false (PVar "acc") (EIf (EApp (EApp (EVar "any") (ELam ((PVar "h")) (EBinOp "||" (EBinOp "==" (EVar "h") (ELit (LString "String"))) (EBinOp "==" (EVar "h") (ELit (LString "Array")))))) (EVar "heads")) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "ioPushPathMoreLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EApp (EApp (EVar "contains") (ELit (LString "Array"))) (EVar "heads")) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "jsffiArrayLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EApp (EApp (EVar "any") (ELam ((PVar "imp")) (EBinOp "==" (EFieldAccess (EVar "imp") "result") (ELit (LString "String"))))) (EVar "js")) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "jsffiResultStrLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EApp (EApp (EVar "any") (ELam ((PVar "imp")) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "imp") "result") (ELit (LString "Int"))) (EBinOp "==" (EFieldAccess (EVar "imp") "result") (ELit (LString "Char")))) (EApp (EApp (EVar "contains") (ELit (LString "Array"))) (EFieldAccess (EVar "imp") "params"))))) (EVar "js")) (EApp (EVar "needTrap") (EVar "acc")) (EVar "acc"))) (DoExpr (EIf (EApp (EApp (EVar "contains") (ELit (LString "mdk_write_err_byte"))) (EVar "keys")) (EApp (EVar "needTrap") (EVar "acc")) (EVar "acc")))))
(DTypeSig false "hostHelperRoots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "hostHelperRoots" () (EListLit (ETuple (ELit (LString "mdk_path_push")) (ELit (LString "ioPushPathLines"))) (ETuple (ELit (LString "mdk_rename")) (ELit (LString "ioPushPathMoreLines"))) (ETuple (ELit (LString "mdk_grant_push")) (ELit (LString "ioPushGrantLines"))) (ETuple (ELit (LString "mdk_rename")) (ELit (LString "ioPushGrantMoreLines"))) (ETuple (ELit (LString "mdk_result_len")) (ELit (LString "ioResultLines"))) (ETuple (ELit (LString "mdk_read_file")) (ELit (LString "ioReadFileLines"))) (ETuple (ELit (LString "mdk_fetch_text")) (ELit (LString "ioFetchTextLines"))) (ETuple (ELit (LString "mdk_file_exists")) (ELit (LString "ioFileExistsLines"))) (ETuple (ELit (LString "mdk_canonicalize_path")) (ELit (LString "ioCanonicalizeLines"))) (ETuple (ELit (LString "mdk_write_file")) (ELit (LString "ioWriteFileLines"))) (ETuple (ELit (LString "mdk_append_file")) (ELit (LString "ioAppendFileLines"))) (ETuple (ELit (LString "mdk_rename")) (ELit (LString "ioRenameLines"))) (ETuple (ELit (LString "mdk_list_dir")) (ELit (LString "ioListDirLines"))) (ETuple (ELit (LString "mdk_stat_file")) (ELit (LString "ioStatFileLines"))) (ETuple (ELit (LString "mdk_make_dir")) (ELit (LString "ioMakeDirLines"))) (ETuple (ELit (LString "mdk_remove_file")) (ELit (LString "ioRemoveFileLines"))) (ETuple (ELit (LString "mdk_remove_dir")) (ELit (LString "ioRemoveDirLines"))) (ETuple (ELit (LString "mdk_fsync")) (ELit (LString "ioFsyncLines"))) (ETuple (ELit (LString "mdk_file_mode")) (ELit (LString "ioFileModeLines"))) (ETuple (ELit (LString "mdk_write_file_mode")) (ELit (LString "ioWriteFileModeLines"))) (ETuple (ELit (LString "mdk_get_env")) (ELit (LString "ioGetEnvLines"))) (ETuple (ELit (LString "mdk_read_line")) (ELit (LString "ioReadLineLines"))) (ETuple (ELit (LString "mdk_read_all")) (ELit (LString "ioReadAllLines"))) (ETuple (ELit (LString "mdk_read_exactly")) (ELit (LString "ioReadExactlyLines"))) (ETuple (ELit (LString "mdk_executable_path")) (ELit (LString "ioExecutablePathLines"))) (ETuple (ELit (LString "mdk_args_count")) (ELit (LString "ioArgsLines"))) (ETuple (ELit (LString "mdk_str_to_float")) (ELit (LString "floatStrLines")))))
(DTypeSig true "hasWasmHelper" (TyFun (TyCon "WasmDemandPlan") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "hasWasmHelper" ((PVar "plan") (PVar "name")) (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "plan") "helpers")))
(DTypeSig true "censusWasmDemand" (TyFun (TyCon "WasmDemandPlan") (TyCon "WasmDemandPlan")))
(DFunDef false "censusWasmDemand" ((PVar "plan")) (ERecordUpdate (EVar "plan") ((fa "helpers" (EFieldAccess (EVar "plan") "censusHelpers")) (fa "intHelpers" (EFieldAccess (EVar "plan") "censusIntHelpers")))))
(DTypeSig true "selectWasmBin" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "CExpr") (TyFun (TyCon "CExpr") (TyFun (TyCon "String") (TyCon "String")))))))))
(DFunDef false "selectWasmBin" ((PVar "ctx") (PVar "str") (PVar "env") (PVar "op") (PVar "l") (PVar "r") (PVar "tag")) (EIf (EBinOp "&&" (EApp (EVar "isArithOp") (EVar "op")) (EApp (EVar "isTaggedFixedHead") (EVar "tag"))) (ELit (LString "int-fixed")) (EIf (EBinOp "&&" (EBinOp "||" (EApp (EVar "isArithOp") (EVar "op")) (EApp (EVar "isCmpOp") (EVar "op"))) (EBinOp "==" (EVar "tag") (ELit (LString "U64")))) (ELit (LString "u64")) (EIf (EBinOp "&&" (EBinOp "||" (EApp (EVar "isArithOp") (EVar "op")) (EApp (EVar "isCmpOp") (EVar "op"))) (EBinOp "==" (EVar "tag") (ELit (LString "I64")))) (ELit (LString "i64")) (EIf (EBinOp "&&" (EBinOp "||" (EApp (EVar "isArithOp") (EVar "op")) (EApp (EVar "isCmpOp") (EVar "op"))) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "tag") (ELit (LString "Float"))) (EBinOp "==" (EApp (EApp (EApp (EVar "cexprStamp") (EVar "ctx")) (EVar "env")) (EVar "l")) (EVar "RTFloat"))) (EBinOp "==" (EApp (EApp (EApp (EVar "cexprStamp") (EVar "ctx")) (EVar "env")) (EVar "r")) (EVar "RTFloat")))) (ELit (LString "float")) (EIf (EBinOp "&&" (EApp (EVar "isCmpOp") (EVar "op")) (EVar "str")) (ELit (LString "compare")) (EIf (EBinOp "&&" (EApp (EVar "isCmpOp") (EVar "op")) (EApp (EApp (EApp (EApp (EVar "isPolyNumBinop") (EVar "ctx")) (EVar "env")) (EVar "l")) (EVar "r"))) (ELit (LString "compare-number")) (EIf (EBinOp "&&" (EApp (EVar "isArithOp") (EVar "op")) (EApp (EApp (EApp (EApp (EVar "isPolyNumBinop") (EVar "ctx")) (EVar "env")) (EVar "l")) (EVar "r"))) (EBinOp "++" (ELit (LString "value-")) (EVar "op")) (ELit (LString "int"))))))))))
(DTypeSig false "hBind" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyFun (TyCon "CBind") (TyCon "HelperAcc")))))))
(DFunDef false "hBind" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PCon "CBind" (PVar "name") (PVar "clauses") (PVar "loc") PWild)) (EBlock (DoLet false false (PVar "acc") (EIf (EBinOp "&&" (EBinOp "&&" (EVar "refMode") (EBinOp "/=" (EVar "name") (ELit (LString "main")))) (EBinOp "||" (EApp (EVar "multiOrPatternClauses") (EVar "clauses")) (EApp (EApp (EVar "any") (ELam ((PVar "c")) (EApp (EVar "exprHasFallthrough") (EApp (EVar "clauseBodyOf") (EVar "c"))))) (EVar "clauses")))) (EApp (EApp (EVar "locatedNonexh") (EVar "acc")) (EVar "loc")) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (EApp (EApp (EApp (EVar "hClause") (EVar "ctx")) (EVar "refMode")) (EVar "str"))) (EVar "acc")) (EVar "clauses")))))
(DTypeSig false "hClause" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyFun (TyCon "CClause") (TyCon "HelperAcc")))))))
(DFunDef false "hClause" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EVar "fold") (EApp (EVar "hPat") (EVar "refMode"))) (EVar "acc")) (EVar "pats"))) (EApp (EApp (EApp (EVar "fold") (EApp (EVar "flip") (EVar "envBindPat"))) (EListLit)) (EVar "pats"))) (EVar "body")))
(DTypeSig false "hImpl" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyFun (TyCon "CImplEntry") (TyCon "HelperAcc")))))))
(DFunDef false "hImpl" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PCon "CImplEntry" PWild PWild PWild (PVar "body"))) (EMatch (EVar "body") (arm (PCon "CImplTagged" PWild PWild PWild PWild PWild (PVar "pats") (PVar "b")) () (EApp (EApp (EApp (EApp (EApp (EVar "hClause") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EApp (EApp (EVar "CClause") (EVar "pats")) (EVar "b")))) (arm (PCon "CImplDefault" PWild PWild PWild PWild PWild (PVar "pats") (PVar "b")) () (EApp (EApp (EApp (EApp (EApp (EVar "hClause") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EApp (EApp (EVar "CClause") (EVar "pats")) (EVar "b"))))))
(DTypeSig false "implFailureRoots" (TyFun (TyCon "HelperAcc") (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyCon "HelperAcc"))))
(DFunDef false "implFailureRoots" ((PVar "acc") (PVar "entries")) (EBlock (DoLet false false (PVar "groups") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "index") (PCon "CImplEntry" (PVar "method") PWild PWild (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "key") (PVar "clause")) (EMatch (EVar "body") (arm (PCon "CImplTagged" PWild (PVar "key") PWild PWild PWild (PVar "pats") (PVar "b")) () (ETuple (EVar "key") (EApp (EApp (EVar "CClause") (EVar "pats")) (EVar "b")))) (arm (PCon "CImplDefault" PWild PWild (PVar "key") PWild PWild (PVar "pats") (PVar "b")) () (ETuple (EVar "key") (EApp (EApp (EVar "CClause") (EVar "pats")) (EVar "b")))))) (DoLet false false (PVar "groupKey") (EBinOp "++" (EApp (EVar "lenKey") (EVar "method")) (EVar "key"))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EVar "groupKey")) (EBinOp "::" (EVar "clause") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "groupKey")) (EVar "index"))))) (EVar "index")))))) (EVar "omEmpty")) (EVar "entries"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PVar "key")) (EBlock (DoLet false false (PVar "clauses") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "groups")))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "multiOrPatternClauses") (EVar "clauses")) (EApp (EApp (EVar "any") (ELam ((PVar "c")) (EApp (EVar "exprHasFallthrough") (EApp (EVar "clauseBodyOf") (EVar "c"))))) (EVar "clauses"))) (EApp (EVar "needTrap") (EVar "a")) (EVar "a")))))) (EVar "acc")) (EApp (EVar "omKeys") (EVar "groups"))))))
(DTypeSig false "localFunctionRoots" (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "CExpr") (TyCon "HelperAcc"))))))
(DFunDef false "localFunctionRoots" ((PVar "refMode") (PVar "acc") (PVar "pats") (PVar "body")) (EIf (EBinOp "&&" (EVar "refMode") (EBinOp "||" (EApp (EVar "multiOrPatternClauses") (EListLit (EApp (EApp (EVar "CClause") (EVar "pats")) (EVar "body")))) (EApp (EVar "exprHasFallthrough") (EVar "body")))) (EApp (EVar "needTrap") (EVar "acc")) (EVar "acc")))
(DTypeSig false "hPat" (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyFun (TyCon "Pat") (TyCon "HelperAcc")))))
(DFunDef false "hPat" ((PCon "True") (PVar "acc") (PCon "PLit" (PCon "LString" PWild))) (EApp (EApp (EVar "needMany") (EVar "acc")) (EListLit (ELit (LString "strSearchRuntimeLines")) (ELit (LString "strLeafRuntimeLines")) (ELit (LString "ioStrRuntimeLines")))))
(DFunDef false "hPat" ((PVar "refMode") (PVar "acc") (PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EApp (EVar "fold") (EApp (EVar "hPat") (EVar "refMode"))) (EVar "acc")) (EVar "ps")))
(DFunDef false "hPat" ((PVar "refMode") (PVar "acc") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EApp (EVar "fold") (EApp (EVar "hPat") (EVar "refMode"))) (ERecordUpdate (EVar "acc") ((fa "patternTuples" (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "ps")))) (EApp (EVar "listLen") (EVar "ps"))) (EFieldAccess (EVar "acc") "patternTuples")))))) (EVar "ps")))
(DFunDef false "hPat" ((PVar "refMode") (PVar "acc") (PCon "PList" (PVar "ps"))) (EApp (EApp (EApp (EVar "fold") (EApp (EVar "hPat") (EVar "refMode"))) (ERecordUpdate (EVar "acc") ((fa "patternList" (EVar "True"))))) (EVar "ps")))
(DFunDef false "hPat" ((PVar "refMode") (PVar "acc") (PCon "PCons" (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "hPat") (EVar "refMode")) (EApp (EApp (EApp (EVar "hPat") (EVar "refMode")) (ERecordUpdate (EVar "acc") ((fa "patternList" (EVar "True"))))) (EVar "a"))) (EVar "b")))
(DFunDef false "hPat" ((PVar "refMode") (PVar "acc") (PCon "PAs" PWild PWild PWild (PVar "p"))) (EApp (EApp (EApp (EVar "hPat") (EVar "refMode")) (EVar "acc")) (EVar "p")))
(DFunDef false "hPat" (PWild (PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "hExpr" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CExpr") (TyCon "HelperAcc"))))))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") PWild)) (EBlock (DoLet false false (PVar "branch") (EIf (EVar "refMode") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "selectWasmBin") (EVar "ctx")) (EVar "str")) (EVar "env")) (EVar "op")) (EVar "l")) (EVar "r")) (EVar "tag")) (ELit (LString "int")))) (DoLet false false (PVar "acc") (EIf (EBinOp "==" (EVar "branch") (ELit (LString "compare"))) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "valueEqRuntimeLines"))) (EIf (EBinOp "==" (EVar "branch") (ELit (LString "compare-number"))) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "valueCmpNumRuntimeLines"))) (EVar "acc")))) (DoLet false false (PVar "acc") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "value-"))) (EVar "branch")) (EApp (EApp (EVar "need") (EVar "acc")) (EBinOp "++" (EBinOp "++" (ELit (LString "value")) (EApp (EVar "valueOpBlock") (EVar "op"))) (ELit (LString "RuntimeLines")))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EVar "branch") (ELit (LString "int"))) (EApp (EVar "not") (EApp (EVar "isTaggedFixedHead") (EVar "tag")))) (EApp (EApp (EVar "startsWith") (ELit (LString "value-"))) (EVar "branch"))) (EApp (EApp (EVar "contains") (EVar "op")) (EListLit (ELit (LString "+")) (ELit (LString "-")) (ELit (LString "*")) (ELit (LString "/"))))) (EApp (EApp (EVar "needInt") (EVar "acc")) (EApp (EVar "intOpName") (EVar "op"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "/"))) (EBinOp "==" (EVar "op") (ELit (LString "%")))) (EBinOp "/=" (EVar "branch") (ELit (LString "float")))) (EApp (EVar "needTrap") (EVar "acc")) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "l"))) (EVar "env")) (EVar "r")))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CUnOp" (PLit (LString "-")) (PVar "x"))) (EBlock (DoLet false false (PVar "acc") (EIf (EBinOp "&&" (EVar "refMode") (EBinOp "==" (EApp (EApp (EApp (EVar "cexprStamp") (EVar "ctx")) (EVar "env")) (EVar "x")) (EVar "RTFloat"))) (EVar "acc") (EApp (EApp (EVar "needInt") (EVar "acc")) (ELit (LString "neg"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "x")))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PAs "app" (PCon "CApp" (PVar "f") (PVar "args") PWild))) (EBlock (DoLet false false (PVar "acc") (EIf (EBinOp "&&" (EVar "refMode") (EApp (EApp (EApp (EApp (EVar "appUsesClosures") (EFieldAccess (EVar "ctx") "fnNames")) (EFieldAccess (EVar "ctx") "ctorArities")) (EVar "env")) (EVar "app"))) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "closApplyLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EMatch (EVar "f") (arm (PCon "CVar" (PVar "name") PWild) () (EApp (EApp (EApp (EApp (EVar "runtimeRoots") (EVar "ctx")) (EVar "acc")) (EVar "name")) (EVar "args"))) (arm PWild () (EVar "acc")))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PVar "x")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "x")))) (EMatch (EVar "f") (arm (PCon "CVar" PWild PWild) () (EVar "acc")) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "f"))))) (EVar "args")))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CVar" (PVar "name") PWild)) (EBlock (DoLet false false (PVar "acc") (EIf (EBinOp "&&" (EBinOp "&&" (EVar "refMode") (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "name")) (EVar "env")))) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "ctx") "fnNames")) (EApp (EApp (EVar "externNeedsClosure") (EVar "ctx")) (EVar "name")))) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "closApplyLines"))) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "runtimeRoots") (EVar "ctx")) (EVar "acc")) (EVar "name")) (EListLit)))))
(DFunDef false "hExpr" (PWild (PCon "True") PWild (PVar "acc") PWild (PCon "CMethod" PWild PWild)) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "closApplyLines"))))
(DFunDef false "hExpr" (PWild (PCon "True") PWild (PVar "acc") PWild (PCon "CDict" PWild PWild)) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "closApplyLines"))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CLam" (PVar "pats") (PVar "b"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EVar "fold") (EApp (EVar "hPat") (EVar "refMode"))) (EIf (EVar "refMode") (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "closApplyLines"))) (EVar "acc"))) (EVar "pats"))) (EApp (EApp (EApp (EVar "fold") (EApp (EVar "flip") (EVar "envBindPat"))) (EVar "env")) (EVar "pats"))) (EVar "b")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PVar "x")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "x")))) (EVar "acc")) (EListLit (EVar "c") (EVar "t") (EVar "f"))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CLet" (PVar "recFlag") (PVar "pat") (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "envBindPat") (EVar "pat")) (EVar "env"))) (DoLet false false (PVar "acc") (EMatch (ETuple (EVar "recFlag") (EVar "pat") (EVar "a")) (arm (PTuple (PCon "True") (PCon "PVar" PWild PWild PWild) (PCon "CLam" (PVar "pats") (PVar "body"))) () (EApp (EApp (EApp (EApp (EVar "localFunctionRoots") (EVar "refMode")) (EVar "acc")) (EVar "pats")) (EVar "body"))) (arm PWild () (EVar "acc")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EVar "hPat") (EVar "refMode")) (EVar "acc")) (EVar "pat"))) (EIf (EVar "recFlag") (EVar "inner") (EVar "env"))) (EVar "a"))) (EVar "inner")) (EVar "b")))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CLetGroup" (PVar "binds") (PVar "b"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "envBindGroups") (EVar "binds")) (EVar "env"))) (DoLet false false (PVar "acc") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PCon "CBind" PWild (PVar "cs") (PVar "loc") (PVar "bid"))) (EApp (EApp (EApp (EApp (EApp (EVar "hBind") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "CBind") (ELit (LString "$local"))) (EVar "cs")) (EVar "loc")) (EVar "bid"))))) (EVar "acc")) (EVar "binds"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "inner")) (EVar "b")))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hStmts") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "stmts")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EVar "hTree") (EVar "refMode")) (EApp (EApp (EApp (EVar "fold") (EApp (EApp (EApp (EApp (EVar "hArm") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "env"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "scrut"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EApp (EVar "fold") (EApp (EApp (EApp (EApp (EVar "hArm") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "env"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "scrut"))) (EVar "arms")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EIf (EVar "refMode") (EApp (EVar "needTrap") (EVar "acc")) (EVar "acc"))) (EVar "env")) (EVar "a"))) (EVar "env")) (EVar "i")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PVar "x")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "x")))) (EIf (EVar "refMode") (EApp (EVar "needTrap") (EVar "acc")) (EVar "acc"))) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CTuple" (PVar "xs"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PVar "x")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "x")))) (EVar "acc")) (EVar "xs")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CList" (PVar "xs"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PVar "x")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "x")))) (EVar "acc")) (EVar "xs")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CArray" (PVar "xs"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PVar "x")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "x")))) (EVar "acc")) (EVar "xs")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PVar "x")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "x")))) (EVar "acc")) (EListLit (EVar "lo") (EVar "hi"))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PVar "x")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "x")))) (EVar "acc")) (EListLit (EVar "lo") (EVar "hi"))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CRecord" PWild (PVar "fs"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PCon "CField" PWild PWild (PVar "x"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "x")))) (EVar "acc")) (EVar "fs")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CFieldAccess" (PVar "x") (PLit (LString "value")) PWild PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (ERecordUpdate (EVar "acc") ((fa "refRead" (EVar "True"))))) (EVar "env")) (EVar "x")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CFieldAccess" (PVar "x") PWild PWild PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "x")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CRecordUpdate" PWild (PVar "x") (PVar "fs"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PCon "CField" PWild PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "e")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "x"))) (EVar "fs")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CVariantUpdate" PWild (PVar "x") (PVar "fs"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PCon "CField" PWild PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "e")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "x"))) (EVar "fs")))
(DFunDef false "hExpr" (PWild PWild PWild (PVar "acc") PWild PWild) (EVar "acc"))
(DTypeSig false "externNeedsClosure" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "externNeedsClosure" ((PVar "ctx") (PVar "symbol")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "symbol")) (EFieldAccess (EVar "ctx") "externFacts")) (arm (PCon "Some" (PVar "fact")) () (EMatch (ETuple (EApp (EApp (EVar "externRuntimeKey") (EFieldAccess (EVar "ctx") "externFacts")) (EVar "symbol")) (EFieldAccess (EVar "fact") "callableShape")) (arm (PTuple (PCon "Some" (PVar "key")) (PCon "Some" (PVar "shape"))) () (EBinOp "&&" (EBinOp ">" (EFieldAccess (EVar "shape") "loweredCoreArity") (ELit (LInt 0))) (EMatch (EApp (EVar "wasmFamily") (EVar "key")) (arm (PCon "Some" (PVar "family")) () (EApp (EVar "isWasmExternFamily") (EVar "family"))) (arm (PCon "None") () (EVar "False"))))) (arm (PTuple (PCon "None") PWild) () (EVar "True")) (arm PWild () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "hStmts" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyCon "HelperAcc"))))))))
(DFunDef false "hStmts" (PWild PWild PWild (PVar "acc") PWild (PList)) (EVar "acc"))
(DFunDef false "hStmts" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCons (PCon "CSLet" (PVar "recFlag") (PAs "pat" (PCon "PVar" PWild PWild PWild)) (PAs "lam" (PCon "CLam" (PVar "pats") (PVar "body")))) (PVar "rest"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "envBindPat") (EVar "pat")) (EVar "env"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hStmts") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EApp (EVar "localFunctionRoots") (EVar "refMode")) (EVar "acc")) (EVar "pats")) (EVar "body"))) (EIf (EVar "recFlag") (EVar "inner") (EVar "env"))) (EVar "lam"))) (EVar "inner")) (EVar "rest")))))
(DFunDef false "hStmts" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCons (PCon "CSLet" (PVar "recFlag") (PVar "pat") (PVar "x")) (PVar "rest"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "envBindPat") (EVar "pat")) (EVar "env"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hStmts") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EVar "hPat") (EVar "refMode")) (EVar "acc")) (EVar "pat"))) (EIf (EVar "recFlag") (EVar "inner") (EVar "env"))) (EVar "x"))) (EVar "inner")) (EVar "rest")))))
(DFunDef false "hStmts" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCons (PCon "CSExpr" (PVar "x")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hStmts") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "x"))) (EVar "env")) (EVar "rest")))
(DFunDef false "hStmts" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCons (PCon "CSAssign" PWild (PVar "x")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hStmts") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "x"))) (EVar "env")) (EVar "rest")))
(DTypeSig false "hArm" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "HelperAcc") (TyFun (TyCon "CArm") (TyCon "HelperAcc"))))))))
(DFunDef false "hArm" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "env") (PVar "acc") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "b"))) (EBlock (DoLet false false (PTuple (PVar "acc") (PVar "inner")) (EApp (EApp (EApp (EVar "fold") (ELam ((PTuple (PVar "a") (PVar "scope")) (PVar "g")) (EMatch (EVar "g") (arm (PCon "CGBool" (PVar "x")) () (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "scope")) (EVar "x")) (EVar "scope"))) (arm (PCon "CGBind" (PVar "p") (PVar "x")) () (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EVar "hPat") (EVar "refMode")) (EVar "a")) (EVar "p"))) (EVar "scope")) (EVar "x")) (EApp (EApp (EVar "envBindPat") (EVar "p")) (EVar "scope"))))))) (ETuple (EApp (EApp (EApp (EVar "hPat") (EVar "refMode")) (EVar "acc")) (EVar "pat")) (EApp (EApp (EVar "envBindPat") (EVar "pat")) (EVar "env")))) (EVar "guards"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "inner")) (EVar "b")))))
(DTypeSig false "hTree" (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyFun (TyCon "CTree") (TyCon "HelperAcc")))))
(DFunDef false "hTree" ((PCon "True") (PVar "acc") (PCon "CTFail" (PCon "LetRefuted" (PVar "loc")))) (EApp (EApp (EVar "locatedTrap") (EVar "acc")) (EVar "loc")))
(DFunDef false "hTree" ((PCon "True") (PVar "acc") (PCon "CTFail" (PCon "NoArm" (PVar "loc")))) (EApp (EApp (EVar "locatedNonexh") (EVar "acc")) (EVar "loc")))
(DFunDef false "hTree" ((PVar "refMode") (PVar "acc") (PCon "CTGuard" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "hTree") (EVar "refMode")) (EVar "acc")) (EVar "t")))
(DFunDef false "hTree" ((PVar "refMode") (PVar "acc") (PCon "CTDrop" (PVar "t"))) (EApp (EApp (EApp (EVar "hTree") (EVar "refMode")) (EVar "acc")) (EVar "t")))
(DFunDef false "hTree" ((PVar "refMode") (PVar "acc") (PCon "CTSwitch" (PVar "branches") (PVar "dft"))) (EApp (EApp (EApp (EVar "hTree") (EVar "refMode")) (EApp (EApp (EApp (EVar "fold") (EApp (EVar "hBranch") (EVar "refMode"))) (EVar "acc")) (EVar "branches"))) (EVar "dft")))
(DFunDef false "hTree" (PWild (PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "hBranch" (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyFun (TyCon "CTBranch") (TyCon "HelperAcc")))))
(DFunDef false "hBranch" ((PVar "refMode") (PVar "acc") (PCon "CTBranch" (PVar "head") (PVar "tree"))) (EBlock (DoLet false false (PVar "acc") (EMatch (EVar "head") (arm (PCon "HLit" (PVar "lit")) () (EApp (EApp (EApp (EVar "hPat") (EVar "refMode")) (EVar "acc")) (EApp (EVar "PLit") (EVar "lit")))) (arm (PCon "HCons") () (ERecordUpdate (EVar "acc") ((fa "patternList" (EVar "True"))))) (arm (PCon "HNil") () (ERecordUpdate (EVar "acc") ((fa "patternList" (EVar "True"))))) (arm (PCon "HTuple" (PVar "n")) () (ERecordUpdate (EVar "acc") ((fa "patternTuples" (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "intToString") (EVar "n"))) (EVar "n")) (EFieldAccess (EVar "acc") "patternTuples")))))) (arm PWild () (EVar "acc")))) (DoExpr (EApp (EApp (EApp (EVar "hTree") (EVar "refMode")) (EVar "acc")) (EVar "tree")))))
(DTypeSig false "locatedTrap" (TyFun (TyCon "HelperAcc") (TyFun (TyCon "Loc") (TyCon "HelperAcc"))))
(DFunDef false "locatedTrap" ((PVar "acc") (PVar "loc")) (EIf (EApp (EVar "hasLocation") (EVar "loc")) (EApp (EVar "needSite") (EVar "acc")) (EApp (EVar "needTrap") (EVar "acc"))))
(DTypeSig false "locatedNonexh" (TyFun (TyCon "HelperAcc") (TyFun (TyCon "Loc") (TyCon "HelperAcc"))))
(DFunDef false "locatedNonexh" ((PVar "acc") (PVar "loc")) (EIf (EApp (EVar "hasLocation") (EVar "loc")) (ERecordUpdate (EApp (EVar "needSite") (EVar "acc")) ((fa "nonexh" (EVar "True")))) (EApp (EVar "needTrap") (EVar "acc"))))
(DTypeSig false "hasLocation" (TyFun (TyCon "Loc") (TyCon "Bool")))
(DFunDef false "hasLocation" ((PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "f") (ELit (LString ""))) (EApp (EVar "not") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "sl") (ELit (LInt 1))) (EBinOp "==" (EVar "sc") (ELit (LInt 0)))) (EBinOp "==" (EVar "el") (ELit (LInt 1)))) (EBinOp "==" (EVar "ec") (ELit (LInt 0)))))) (EBinOp ">=" (EVar "sl") (ELit (LInt 0)))) (EBinOp "<" (EVar "sl") (ELit (LInt 16777216)))) (EBinOp ">=" (EVar "sc") (ELit (LInt 0)))) (EBinOp "<" (EVar "sc") (ELit (LInt 1048576)))))
(DTypeSig false "runtimeRoots" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "HelperAcc") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyCon "HelperAcc"))))))
(DFunDef false "runtimeRoots" ((PVar "ctx") (PVar "acc") (PVar "symbol") (PVar "args")) (EMatch (EApp (EApp (EVar "externRuntimeKey") (EFieldAccess (EVar "ctx") "externFacts")) (EVar "symbol")) (arm (PCon "Some" (PVar "key")) ((GBool (EApp (EApp (EVar "contains") (EVar "key")) (EListLit (ELit (LString "shiftLeft")) (ELit (LString "intShiftLeft")))))) (EApp (EApp (EVar "needInt") (EVar "acc")) (ELit (LString "left")))) (arm (PCon "Some" (PVar "key")) ((GBool (EApp (EApp (EVar "contains") (EVar "key")) (EListLit (ELit (LString "shiftRight")) (ELit (LString "intShiftRight")))))) (EApp (EApp (EVar "needInt") (EVar "acc")) (ELit (LString "right")))) (arm (PCon "Some" (PVar "key")) ((GBool (EApp (EApp (EVar "contains") (EVar "key")) (EListLit (ELit (LString "panic")) (ELit (LString "indexError")) (ELit (LString "sliceError")))))) (EApp (EVar "needTrap") (EVar "acc"))) (arm (PCon "Some" (PLit (LString "indexErrorAt"))) () (EApp (EApp (EVar "need") (EApp (EVar "needTrap") (EVar "acc"))) (ELit (LString "trapIntRuntimeLines")))) (arm (PCon "Some" (PVar "key")) ((GBool (EBinOp "||" (EBinOp "==" (EVar "key") (ELit (LString "indexErrorAtSite"))) (EBinOp "==" (EVar "key") (ELit (LString "panicAt")))))) (EBlock (DoLet false false (PVar "acc") (EIf (EBinOp "==" (EVar "key") (ELit (LString "indexErrorAtSite"))) (EApp (EApp (EVar "need") (EApp (EVar "needTrap") (EVar "acc"))) (ELit (LString "trapIntRuntimeLines"))) (EApp (EVar "needTrap") (EVar "acc")))) (DoExpr (EMatch (EVar "args") (arm (PCons (PCon "CLit" (PCon "LInt" (PLit (LInt 0)))) PWild) () (EVar "acc")) (arm PWild () (EApp (EVar "needSite") (EVar "acc"))))))) (arm PWild () (EVar "acc"))))
(DTypeSig false "intOpName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "intOpName" ((PLit (LString "+"))) (ELit (LString "add")))
(DFunDef false "intOpName" ((PLit (LString "-"))) (ELit (LString "sub")))
(DFunDef false "intOpName" ((PLit (LString "*"))) (ELit (LString "mul")))
(DFunDef false "intOpName" (PWild) (ELit (LString "div")))
(DTypeSig false "valueOpBlock" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "valueOpBlock" ((PLit (LString "+"))) (ELit (LString "Add")))
(DFunDef false "valueOpBlock" ((PLit (LString "-"))) (ELit (LString "Sub")))
(DFunDef false "valueOpBlock" ((PLit (LString "*"))) (ELit (LString "Mul")))
(DFunDef false "valueOpBlock" ((PLit (LString "/"))) (ELit (LString "Div")))
(DFunDef false "valueOpBlock" (PWild) (ELit (LString "Mod")))
(DTypeSig false "printRoots" (TyFun (TyCon "WasmTypeContext") (TyFun (TyApp (TyCon "Option") (TyCon "EntryFact")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyCon "HelperAcc") (TyCon "HelperAcc"))))))
(DFunDef false "printRoots" ((PVar "ctx") (PVar "outcome") (PVar "groups") (PVar "acc")) (EBlock (DoLet false false (PVar "body") (EApp (EApp (EVar "filterMap") (EVar "mainBodyD")) (EVar "groups"))) (DoExpr (EMatch (EVar "body") (arm (PCons (PVar "e") PWild) () (EBlock (DoLet false false (PVar "own") (EApp (EApp (EApp (EVar "varStamp") (EVar "ctx")) (EListLit)) (ELit (LString "main")))) (DoLet false false (PVar "stamp") (EMatch (EVar "outcome") (arm (PCon "Some" (PVar "fact")) ((GBool (EFieldAccess (EVar "fact") "entryMainIsUnit"))) (EVar "RTUnit")) (arm (PCon "Some" (PVar "fact")) ((GBool (EFieldAccess (EVar "fact") "entryMainIsFloat"))) (EVar "RTFloat")) (arm PWild () (EIf (EBinOp "==" (EVar "own") (EVar "RTValue")) (EApp (EApp (EApp (EVar "cexprStamp") (EVar "ctx")) (EListLit)) (EVar "e")) (EVar "own"))))) (DoExpr (EIf (EBinOp "==" (EVar "stamp") (EVar "RTFloat")) (EApp (EApp (EVar "needMany") (EVar "acc")) (EListLit (ELit (LString "floatRuntimeLines")) (ELit (LString "ioStrRuntimeLines")))) (EIf (EBinOp "==" (EVar "stamp") (EVar "RTChar")) (EApp (EApp (EVar "needMany") (EVar "acc")) (EListLit (ELit (LString "ioStrRuntimeLines")) (ELit (LString "strLeafRuntimeLines")))) (EVar "acc")))))) (arm (PList) () (EVar "acc"))))))
(DTypeSig false "mainBodyD" (TyFun (TyCon "CBind") (TyApp (TyCon "Option") (TyCon "CExpr"))))
(DFunDef false "mainBodyD" ((PCon "CBind" (PLit (LString "main")) (PList (PCon "CClause" (PList) (PVar "e"))) PWild PWild)) (EApp (EVar "Some") (EVar "e")))
(DFunDef false "mainBodyD" (PWild) (EVar "None"))
(DTypeSig false "representationOf" (TyFun (TyCon "WasmDemand") (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyCon "WasmDemand")))))
(DFunDef false "representationOf" ((PVar "source") (PVar "str") (PVar "acc")) (EBlock (DoLet false false (PVar "types") (EApp (EApp (EVar "flatMap") (EVar "helperTypes")) (EApp (EVar "omKeys") (EFieldAccess (EVar "acc") "helpers")))) (DoLet false false (PVar "uses") (EIf (EBinOp "||" (EBinOp "||" (EVar "str") (EApp (EApp (EVar "contains") (ELit (LString "str"))) (EVar "types"))) (EApp (EApp (EVar "contains") (ELit (LString "u8arr"))) (EVar "types"))) (EApp (EApp (EVar "addUse") (EFieldAccess (EVar "source") "uses")) (EVar "UseStr")) (EFieldAccess (EVar "source") "uses"))) (DoLet false false (PVar "uses") (EIf (EApp (EApp (EVar "contains") (ELit (LString "arr"))) (EVar "types")) (EApp (EApp (EVar "addUse") (EVar "uses")) (EVar "UseArray")) (EVar "uses"))) (DoLet false false (PVar "uses") (EIf (EBinOp "||" (EFieldAccess (EVar "acc") "patternList") (EApp (EApp (EVar "contains") (ELit (LString "C_Cons"))) (EVar "types"))) (EApp (EApp (EVar "addUse") (EVar "uses")) (EVar "UseList")) (EVar "uses"))) (DoLet false false (PVar "seen") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "intToString")) (EFieldAccess (EVar "source") "tupleArities"))) (EVar "omEmpty"))) (DoLet false false (PVar "extraTuples") (EApp (EApp (EVar "filterMap") (ELam ((PVar "k")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "seen")) (EVar "None") (EApp (EApp (EVar "omLookup") (EVar "k")) (EFieldAccess (EVar "acc") "patternTuples"))))) (EApp (EVar "omKeys") (EFieldAccess (EVar "acc") "patternTuples")))) (DoExpr (ERecordUpdate (EVar "source") ((fa "uses" (EVar "uses")) (fa "refBox" (EBinOp "||" (EFieldAccess (EVar "source") "refBox") (EFieldAccess (EVar "acc") "refRead"))) (fa "tupleArities" (EBinOp "++" (EFieldAccess (EVar "source") "tupleArities") (EVar "extraTuples"))))))))
(DTypeSig false "physicalTypes" (TyFun (TyCon "CProgram") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "WasmDemand") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "physicalTypes" (PWild (PCon "False") PWild PWild) (EListLit (ELit (LString "boxint")) (ELit (LString "float"))))
(DFunDef false "physicalTypes" ((PCon "CProgram" PWild (PVar "ctorArs") (PVar "ctorTypes") PWild PWild PWild) (PCon "True") (PVar "clos") (PVar "rep")) (EBlock (DoLet false false (PVar "ctorIndex") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "ctorArs"))) (EVar "omEmpty"))) (DoExpr (EApp (EVar "omKeys") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "boxint")) (ELit (LString "float")) (ELit (LString "dictarr")) (ELit (LString "dictcell")) (ELit (LString "T_Option")) (ELit (LString "C_Some")) (ELit (LString "T_Result")) (ELit (LString "C_Ok")) (ELit (LString "C_Err")) (ELit (LString "T_Ordering"))) (EIf (EVar "clos") (EListLit (ELit (LString "argarr")) (ELit (LString "codety")) (ELit (LString "clos"))) (EListLit))) (EIf (EApp (EApp (EVar "hasUse") (EVar "rep")) (EVar "UseStr")) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))) (EListLit))) (EIf (EApp (EApp (EVar "hasUse") (EVar "rep")) (EVar "UseList")) (EListLit (ELit (LString "T_List")) (ELit (LString "C_Cons"))) (EListLit))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "n")) (EListLit (EBinOp "++" (ELit (LString "T_Tup")) (EApp (EVar "intToString") (EVar "n"))) (EBinOp "++" (ELit (LString "C_Tup")) (EApp (EVar "intToString") (EVar "n")))))) (EFieldAccess (EVar "rep") "tupleArities"))) (EIf (EApp (EApp (EVar "hasUse") (EVar "rep")) (EVar "UseArray")) (EListLit (ELit (LString "arr"))) (EListLit))) (EIf (EFieldAccess (EVar "rep") "refBox") (EListLit (ELit (LString "refbox"))) (EListLit))) (EIf (EApp (EApp (EVar "hasUse") (EVar "rep")) (EVar "UseU64")) (EListLit (ELit (LString "u64"))) (EListLit))) (EIf (EApp (EApp (EVar "hasUse") (EVar "rep")) (EVar "UseI64")) (EListLit (ELit (LString "i64"))) (EListLit))) (EApp (EApp (EVar "flatMap") (ELam ((PTuple (PVar "ctor") (PVar "ty"))) (EIf (EApp (EApp (EVar "contains") (EVar "ty")) (EListLit (ELit (LString "Option")) (ELit (LString "Result")) (ELit (LString "Ordering")))) (EListLit) (EBinOp "++" (EListLit (EBinOp "++" (ELit (LString "T_")) (EApp (EVar "injectiveIdent") (EVar "ty")))) (EIf (EBinOp ">" (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "ctor")) (EVar "ctorIndex"))) (ELit (LInt 0))) (EListLit (EIf (EBinOp "||" (EBinOp "==" (EVar "ctor") (ELit (LString "Cons"))) (EBinOp "==" (EVar "ctor") (ELit (LString "Nil")))) (EBinOp "++" (ELit (LString "CU_")) (EVar "ctor")) (EBinOp "++" (ELit (LString "C_")) (EVar "ctor")))) (EListLit)))))) (EVar "ctorTypes")))) (EVar "omEmpty"))))))
(DTypeSig false "addUse" (TyFun (TyApp (TyCon "List") (TyCon "WasmUse")) (TyFun (TyCon "WasmUse") (TyApp (TyCon "List") (TyCon "WasmUse")))))
(DFunDef false "addUse" ((PVar "uses") (PVar "use")) (EIf (EApp (EApp (EVar "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "use")))) (EVar "uses")) (EVar "uses") (EBinOp "::" (EVar "use") (EVar "uses"))))
(DTypeSig true "helperOrder" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "helperOrder" () (EListLit (ELit (LString "closApplyLines")) (ELit (LString "ioRuntimeLines")) (ELit (LString "ioStrRuntimeLines")) (ELit (LString "strLeafRuntimeLines")) (ELit (LString "strConcatRuntimeLines")) (ELit (LString "appendRuntimeLines")) (ELit (LString "valueEqRuntimeLines")) (ELit (LString "valueAddRuntimeLines")) (ELit (LString "valueSubRuntimeLines")) (ELit (LString "valueMulRuntimeLines")) (ELit (LString "valueDivRuntimeLines")) (ELit (LString "valueModRuntimeLines")) (ELit (LString "valueCmpNumRuntimeLines")) (ELit (LString "u64RuntimeLines")) (ELit (LString "i64RuntimeLines")) (ELit (LString "stderrRuntimeLines")) (ELit (LString "rngRuntimeLines")) (ELit (LString "hashRuntimeLines")) (ELit (LString "hashStringRuntimeLines")) (ELit (LString "floatRemRuntimeLines")) (ELit (LString "floatRuntimeLines")) (ELit (LString "hashFloatRuntimeLines")) (ELit (LString "randomFloatRuntimeLines")) (ELit (LString "strSearchRuntimeLines")) (ELit (LString "strToIntRuntimeLines")) (ELit (LString "strReverseRuntimeLines")) (ELit (LString "strJoinRuntimeLines")) (ELit (LString "utf8LossyRuntimeLines")) (ELit (LString "strCodecRuntimeLines")) (ELit (LString "byteBlockRuntimeLines")) (ELit (LString "charFromCodeRuntimeLines")) (ELit (LString "charClassRuntimeLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioPushPathMoreLines")) (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushGrantMoreLines")) (ELit (LString "ioResultLines")) (ELit (LString "ioRefusedPanicLines")) (ELit (LString "ioReadFileLines")) (ELit (LString "ioFetchTextLines")) (ELit (LString "ioFileExistsLines")) (ELit (LString "ioCanonicalizeLines")) (ELit (LString "ioWriteFileLines")) (ELit (LString "ioAppendFileLines")) (ELit (LString "ioRenameLines")) (ELit (LString "ioListDirLines")) (ELit (LString "ioStatFileLines")) (ELit (LString "ioMakeDirLines")) (ELit (LString "ioRemoveFileLines")) (ELit (LString "ioRemoveDirLines")) (ELit (LString "ioFsyncLines")) (ELit (LString "ioFileModeLines")) (ELit (LString "ioWriteFileModeLines")) (ELit (LString "ioGetEnvLines")) (ELit (LString "ioReadLineLines")) (ELit (LString "ioReadAllLines")) (ELit (LString "ioReadExactlyLines")) (ELit (LString "ioExecutablePathLines")) (ELit (LString "jsffiArrayLines")) (ELit (LString "jsffiResultStrLines")) (ELit (LString "ioArgsLines")) (ELit (LString "writeFileBytesLines")) (ELit (LString "osEntropyLines")) (ELit (LString "readFileBytesLines")) (ELit (LString "floatStrLines")) (ELit (LString "trapIntRuntimeLines")) (ELit (LString "intRuntimeLines")) (ELit (LString "siteRuntimeLines"))))
(DTypeSig false "helperDependencies" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "appendRuntimeLines"))) (EListLit (ELit (LString "strLeafRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "byteBlockRuntimeLines"))) (EListLit (ELit (LString "ioByteImportLines")) (ELit (LString "ioRuntimeLines")) (ELit (LString "utf8LossyRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "floatRuntimeLines"))) (EListLit (ELit (LString "floatFmtImportLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "hashFloatRuntimeLines"))) (EListLit (ELit (LString "hashRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "intRuntimeLines"))) (EListLit (ELit (LString "siteRuntimeLines")) (ELit (LString "stderrByteImportLines")) (ELit (LString "trapIntRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioAppendFileLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioArgsLines"))) (EListLit (ELit (LString "utf8LossyRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioCanonicalizeLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioRefusedPanicLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioExecutablePathLines"))) (EListLit (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioFetchTextLines"))) (EListLit (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioFileExistsLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioRefusedPanicLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioFileModeLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines")) (ELit (LString "ioRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioFsyncLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioGetEnvLines"))) (EListLit (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioListDirLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines")) (ELit (LString "utf8LossyRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioMakeDirLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioReadAllLines"))) (EListLit (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioReadExactlyLines"))) (EListLit (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioReadFileLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines")) (ELit (LString "utf8LossyRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioReadLineLines"))) (EListLit (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioRefusedPanicLines"))) (EListLit (ELit (LString "ioResultLines")) (ELit (LString "stderrByteImportLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioRemoveDirLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioRemoveFileLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioRenameLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushGrantMoreLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioPushPathMoreLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioResultLines"))) (EListLit (ELit (LString "utf8LossyRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioRuntimeLines"))) (EListLit (ELit (LString "ioByteImportLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioStatFileLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines")) (ELit (LString "ioRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioStrRuntimeLines"))) (EListLit (ELit (LString "ioByteImportLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioWriteFileLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioWriteFileModeLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines")) (ELit (LString "ioRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "jsffiArrayLines"))) (EListLit (ELit (LString "ioRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "jsffiResultStrLines"))) (EListLit (ELit (LString "utf8LossyRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "osEntropyLines"))) (EListLit (ELit (LString "ioRefusedPanicLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "randomFloatRuntimeLines"))) (EListLit (ELit (LString "rngRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "readFileBytesLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "siteRuntimeLines"))) (EListLit (ELit (LString "stderrByteImportLines")) (ELit (LString "trapIntRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "stderrRuntimeLines"))) (EListLit (ELit (LString "stderrByteImportLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "strCodecRuntimeLines"))) (EListLit (ELit (LString "utf8LossyRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "strSearchRuntimeLines"))) (EListLit (ELit (LString "strLeafRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "strToIntRuntimeLines"))) (EListLit (ELit (LString "ioRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "trapIntRuntimeLines"))) (EListLit (ELit (LString "stderrByteImportLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "valueAddRuntimeLines"))) (EListLit (ELit (LString "intRuntimeLines")) (ELit (LString "ioRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "valueCmpNumRuntimeLines"))) (EListLit (ELit (LString "ioRuntimeLines"))))
(DFunDef false "helperDependencies" ((PVar "wide") (PLit (LString "valueDivRuntimeLines"))) (EBinOp "++" (EListLit (ELit (LString "intRuntimeLines")) (ELit (LString "ioRuntimeLines")) (ELit (LString "stderrByteImportLines"))) (EIf (EVar "wide") (EListLit (ELit (LString "i64RuntimeLines"))) (EListLit))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "valueEqRuntimeLines"))) (EListLit (ELit (LString "ioRuntimeLines")) (ELit (LString "strSearchRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "valueModRuntimeLines"))) (EListLit (ELit (LString "floatRemRuntimeLines")) (ELit (LString "ioRuntimeLines")) (ELit (LString "stderrByteImportLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "valueMulRuntimeLines"))) (EListLit (ELit (LString "intRuntimeLines")) (ELit (LString "ioRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "valueSubRuntimeLines"))) (EListLit (ELit (LString "intRuntimeLines")) (ELit (LString "ioRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "writeFileBytesLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild PWild) (EListLit))
(DTypeSig false "helperHostKeys" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "helperHostKeys" ((PLit (LString "floatFmtImportLines"))) (EListLit (ELit (LString "mdk_float_fmt")) (ELit (LString "mdk_float_fmt_byte"))))
(DFunDef false "helperHostKeys" ((PLit (LString "floatStrLines"))) (EListLit (ELit (LString "mdk_path_push")) (ELit (LString "mdk_path_reset")) (ELit (LString "mdk_str_to_float")) (ELit (LString "mdk_str_to_float_ok"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioAppendFileLines"))) (EListLit (ELit (LString "mdk_append_file")) (ELit (LString "mdk_write_file_push")) (ELit (LString "mdk_write_file_reset"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioArgsLines"))) (EListLit (ELit (LString "mdk_arg_byte")) (ELit (LString "mdk_arg_len")) (ELit (LString "mdk_args_count"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioByteImportLines"))) (EListLit (ELit (LString "mdk_write_byte"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioCanonicalizeLines"))) (EListLit (ELit (LString "mdk_canonicalize_path"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioExecutablePathLines"))) (EListLit (ELit (LString "mdk_executable_path"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioFetchTextLines"))) (EListLit (ELit (LString "mdk_fetch_text"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioFileExistsLines"))) (EListLit (ELit (LString "mdk_file_exists"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioFileModeLines"))) (EListLit (ELit (LString "mdk_file_mode")) (ELit (LString "mdk_stat_field"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioFsyncLines"))) (EListLit (ELit (LString "mdk_fsync"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioGetEnvLines"))) (EListLit (ELit (LString "mdk_get_env"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioListDirLines"))) (EListLit (ELit (LString "mdk_list_dir"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioMakeDirLines"))) (EListLit (ELit (LString "mdk_make_dir"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioPushGrantLines"))) (EListLit (ELit (LString "mdk_grant_push")) (ELit (LString "mdk_grant_reset"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioPushGrantMoreLines"))) (EListLit (ELit (LString "mdk_grant_push"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioPushPathLines"))) (EListLit (ELit (LString "mdk_path_push")) (ELit (LString "mdk_path_reset"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioPushPathMoreLines"))) (EListLit (ELit (LString "mdk_path_push"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioReadAllLines"))) (EListLit (ELit (LString "mdk_read_all"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioReadExactlyLines"))) (EListLit (ELit (LString "mdk_read_exactly"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioReadFileLines"))) (EListLit (ELit (LString "mdk_read_file"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioReadLineLines"))) (EListLit (ELit (LString "mdk_read_line"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioRemoveDirLines"))) (EListLit (ELit (LString "mdk_remove_dir"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioRemoveFileLines"))) (EListLit (ELit (LString "mdk_remove_file"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioRenameLines"))) (EListLit (ELit (LString "mdk_grant_push")) (ELit (LString "mdk_rename"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioResultLines"))) (EListLit (ELit (LString "mdk_result_byte")) (ELit (LString "mdk_result_len"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioStatFileLines"))) (EListLit (ELit (LString "mdk_stat_field")) (ELit (LString "mdk_stat_file"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioWriteFileLines"))) (EListLit (ELit (LString "mdk_write_file")) (ELit (LString "mdk_write_file_push")) (ELit (LString "mdk_write_file_reset"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioWriteFileModeLines"))) (EListLit (ELit (LString "mdk_write_file_mode")) (ELit (LString "mdk_write_file_push")) (ELit (LString "mdk_write_file_reset"))))
(DFunDef false "helperHostKeys" ((PLit (LString "jsffiArrayLines"))) (EListLit (ELit (LString "mdk_path_push")) (ELit (LString "mdk_result_byte"))))
(DFunDef false "helperHostKeys" ((PLit (LString "jsffiResultStrLines"))) (EListLit (ELit (LString "mdk_result_byte")) (ELit (LString "mdk_result_len"))))
(DFunDef false "helperHostKeys" ((PLit (LString "osEntropyLines"))) (EListLit (ELit (LString "mdk_os_entropy")) (ELit (LString "mdk_result_byte")) (ELit (LString "mdk_result_len"))))
(DFunDef false "helperHostKeys" ((PLit (LString "readFileBytesLines"))) (EListLit (ELit (LString "mdk_read_file")) (ELit (LString "mdk_result_byte")) (ELit (LString "mdk_result_len"))))
(DFunDef false "helperHostKeys" ((PLit (LString "stderrByteImportLines"))) (EListLit (ELit (LString "mdk_write_err_byte"))))
(DFunDef false "helperHostKeys" ((PLit (LString "writeFileBytesLines"))) (EListLit (ELit (LString "mdk_write_file_commit")) (ELit (LString "mdk_write_file_push")) (ELit (LString "mdk_write_file_reset"))))
(DFunDef false "helperHostKeys" (PWild) (EListLit))
(DTypeSig false "helperTypes" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "helperTypes" ((PLit (LString "appendRuntimeLines"))) (EListLit (ELit (LString "C_Cons")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "byteBlockRuntimeLines"))) (EListLit (ELit (LString "arr")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "charFromCodeRuntimeLines"))) (EListLit (ELit (LString "C_Some"))))
(DFunDef false "helperTypes" ((PLit (LString "closApplyLines"))) (EListLit (ELit (LString "argarr")) (ELit (LString "clos"))))
(DFunDef false "helperTypes" ((PLit (LString "floatRuntimeLines"))) (EListLit (ELit (LString "float")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "floatStrLines"))) (EListLit (ELit (LString "C_Some")) (ELit (LString "float")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "hashFloatRuntimeLines"))) (EListLit (ELit (LString "float"))))
(DFunDef false "helperTypes" ((PLit (LString "hashStringRuntimeLines"))) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioAppendFileLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioArgsLines"))) (EListLit (ELit (LString "C_Cons")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioCanonicalizeLines"))) (EListLit (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioFetchTextLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioFileExistsLines"))) (EListLit (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioFileModeLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioFsyncLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioGetEnvLines"))) (EListLit (ELit (LString "C_Some")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioListDirLines"))) (EListLit (ELit (LString "C_Cons")) (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioMakeDirLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioPushGrantLines"))) (EListLit (ELit (LString "C_Cons")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioPushGrantMoreLines"))) (EListLit (ELit (LString "C_Cons")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioPushPathLines"))) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioPushPathMoreLines"))) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioReadExactlyLines"))) (EListLit (ELit (LString "C_Some"))))
(DFunDef false "helperTypes" ((PLit (LString "ioReadFileLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioReadLineLines"))) (EListLit (ELit (LString "C_Some"))))
(DFunDef false "helperTypes" ((PLit (LString "ioRefusedPanicLines"))) (EListLit (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioRemoveDirLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioRemoveFileLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioRenameLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioResultLines"))) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioRuntimeLines"))) (EListLit (ELit (LString "boxint"))))
(DFunDef false "helperTypes" ((PLit (LString "ioStatFileLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "C_Tup4")) (ELit (LString "float")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioStrRuntimeLines"))) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioWriteFileLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioWriteFileModeLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "jsffiArrayLines"))) (EListLit (ELit (LString "arr"))))
(DFunDef false "helperTypes" ((PLit (LString "jsffiResultStrLines"))) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "osEntropyLines"))) (EListLit (ELit (LString "arr"))))
(DFunDef false "helperTypes" ((PLit (LString "randomFloatRuntimeLines"))) (EListLit (ELit (LString "float"))))
(DFunDef false "helperTypes" ((PLit (LString "readFileBytesLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "arr")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "stderrRuntimeLines"))) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "strCodecRuntimeLines"))) (EListLit (ELit (LString "arr")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "strConcatRuntimeLines"))) (EListLit (ELit (LString "C_Cons")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "strJoinRuntimeLines"))) (EListLit (ELit (LString "C_Cons")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "strLeafRuntimeLines"))) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "strReverseRuntimeLines"))) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "strSearchRuntimeLines"))) (EListLit (ELit (LString "C_Some")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "strToIntRuntimeLines"))) (EListLit (ELit (LString "C_Some")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "utf8LossyRuntimeLines"))) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "valueAddRuntimeLines"))) (EListLit (ELit (LString "float"))))
(DFunDef false "helperTypes" ((PLit (LString "valueCmpNumRuntimeLines"))) (EListLit (ELit (LString "float"))))
(DFunDef false "helperTypes" ((PLit (LString "valueDivRuntimeLines"))) (EListLit (ELit (LString "float"))))
(DFunDef false "helperTypes" ((PLit (LString "valueEqRuntimeLines"))) (EListLit (ELit (LString "boxint")) (ELit (LString "float")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "valueModRuntimeLines"))) (EListLit (ELit (LString "float"))))
(DFunDef false "helperTypes" ((PLit (LString "valueMulRuntimeLines"))) (EListLit (ELit (LString "float"))))
(DFunDef false "helperTypes" ((PLit (LString "valueSubRuntimeLines"))) (EListLit (ELit (LString "float"))))
(DFunDef false "helperTypes" ((PLit (LString "writeFileBytesLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "arr")) (ELit (LString "str"))))
(DFunDef false "helperTypes" (PWild) (EListLit))
(DTypeSig false "closeHelpers" (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyCon "HelperAcc"))))
(DFunDef false "closeHelpers" ((PVar "wide") (PVar "acc")) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "a") (PVar "h")) (EApp (EApp (EVar "needMany") (EVar "a")) (EApp (EApp (EVar "helperDependencies") (EVar "wide")) (EVar "h"))))) (EVar "acc")) (EApp (EVar "omKeys") (EFieldAccess (EVar "acc") "helpers")))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "omKeys") (EFieldAccess (EVar "next") "helpers")) (EApp (EVar "omKeys") (EFieldAccess (EVar "acc") "helpers"))) (EVar "next") (EApp (EApp (EVar "closeHelpers") (EVar "wide")) (EVar "next"))))))
(DTypeSig false "physicalImports" (TyFun (TyCon "HelperAcc") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "JsImport")) (TyApp (TyCon "List") (TyCon "PlannedImport"))))))
(DFunDef false "physicalImports" ((PVar "acc") (PVar "sourceKeys") (PVar "js")) (EBlock (DoLet false false (PVar "keys") (EApp (EVar "omKeys") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EVar "sourceKeys") (EApp (EApp (EVar "flatMap") (EVar "helperHostKeys")) (EApp (EVar "omKeys") (EFieldAccess (EVar "acc") "helpers"))))) (EVar "omEmpty")))) (DoLet false false (PVar "first") (EBinOp "++" (EListLit (ELit (LString "mdk_write_byte"))) (EIf (EApp (EApp (EVar "contains") (ELit (LString "mdk_float_fmt"))) (EVar "keys")) (EListLit (ELit (LString "mdk_float_fmt")) (ELit (LString "mdk_float_fmt_byte"))) (EListLit)))) (DoLet false false (PVar "rest") (EApp (EApp (EVar "filterList") (ELam ((PVar "k")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "k")) (EListLit (ELit (LString "mdk_write_byte")) (ELit (LString "mdk_float_fmt")) (ELit (LString "mdk_float_fmt_byte")) (ELit (LString "mdk_write_err_byte"))))))) (EVar "keys"))) (DoExpr (EBinOp "++" (EBinOp "++" (EApp (EApp (EVar "map") (EVar "plannedEnv")) (EBinOp "++" (EVar "first") (EVar "rest"))) (EApp (EApp (EVar "map") (EVar "plannedJs")) (EVar "js"))) (EIf (EApp (EApp (EVar "contains") (ELit (LString "mdk_write_err_byte"))) (EVar "keys")) (EListLit (EApp (EVar "plannedEnv") (ELit (LString "mdk_write_err_byte")))) (EListLit))))))
(DTypeSig false "plannedEnv" (TyFun (TyCon "String") (TyCon "PlannedImport")))
(DFunDef false "plannedEnv" ((PVar "key")) (ERecordCreate "PlannedImport" ((fa "namespace" (ELit (LString "env"))) (fa "field" (EVar "key")) (fa "watSymbol" (EVar "key")) (fa "signature" (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EVar "hostImportSigOf") (EVar "key")))))))
(DTypeSig false "plannedJs" (TyFun (TyCon "JsImport") (TyCon "PlannedImport")))
(DFunDef false "plannedJs" ((PVar "imp")) (ERecordCreate "PlannedImport" ((fa "namespace" (ELit (LString "jsffi"))) (fa "field" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "imp") "jsName"))) (ELit (LString ":"))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EFieldAccess (EVar "imp") "params")))) (ELit (LString "->"))) (EApp (EVar "display") (EFieldAccess (EVar "imp") "result"))) (ELit (LString "")))) (fa "watSymbol" (EBinOp "++" (EBinOp "++" (ELit (LString "jsffi.import.")) (EApp (EVar "display") (EApp (EVar "injectiveIdent") (EFieldAccess (EVar "imp") "medakaName")))) (ELit (LString "")))) (fa "signature" (EBinOp "++" (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EVar "map") (EVar "jsWireParam")) (EFieldAccess (EVar "imp") "params"))) (EApp (EVar "jsWireResult") (EFieldAccess (EVar "imp") "result")))))))
(DTypeSig true "hostImportSigOf" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_byte"))) (EApp (EVar "Some") (ELit (LString " (param i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_err_byte"))) (EApp (EVar "Some") (ELit (LString " (param i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_float_fmt"))) (EApp (EVar "Some") (ELit (LString " (param f64) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_float_fmt_byte"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_exit"))) (EApp (EVar "Some") (ELit (LString " (param i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_wall_time_sec"))) (EApp (EVar "Some") (ELit (LString " (result f64)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_monotonic_sec"))) (EApp (EVar "Some") (ELit (LString " (result f64)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_sleep_ms"))) (EApp (EVar "Some") (ELit (LString " (param i64)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_fetch_text"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_cbrt"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_exp"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_log"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_log2"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_log10"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_sin"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_cos"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_tan"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_asin"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_acos"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_atan"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_sinh"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_cosh"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_tanh"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_pow"))) (EApp (EVar "Some") (EVar "binaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_atan2"))) (EApp (EVar "Some") (EVar "binaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_hypot"))) (EApp (EVar "Some") (EVar "binaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_path_reset"))) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_path_push"))) (EApp (EVar "Some") (ELit (LString " (param i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_read_file"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_file_exists"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_get_env"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_read_line"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_read_all"))) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_read_exactly"))) (EApp (EVar "Some") (ELit (LString " (param i64) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_os_entropy"))) (EApp (EVar "Some") (ELit (LString " (param i64) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_executable_path"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_args_count"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_arg_len"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_arg_byte"))) (EApp (EVar "Some") (ELit (LString " (param i32) (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_result_len"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_result_byte"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_file_reset"))) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_file_push"))) (EApp (EVar "Some") (ELit (LString " (param i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_file_commit"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_str_to_float"))) (EApp (EVar "Some") (ELit (LString " (result f64)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_str_to_float_ok"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_grant_reset"))) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_grant_push"))) (EApp (EVar "Some") (ELit (LString " (param i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_canonicalize_path"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_file"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_append_file"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_make_dir"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_remove_file"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_remove_dir"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_fsync"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_file_mode"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_file_mode"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_rename"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_list_dir"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_stat_file"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_stat_field"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result f64)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_file_bound_enter"))) (EApp (EVar "Some") (ELit (LString " (param i32) (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_file_bound_exit"))) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "hostImportSigOf" (PWild) (EVar "None"))
(DTypeSig false "unaryF64Sig" (TyCon "String"))
(DFunDef false "unaryF64Sig" () (ELit (LString " (param f64) (result f64)")))
(DTypeSig false "binaryF64Sig" (TyCon "String"))
(DFunDef false "binaryF64Sig" () (ELit (LString " (param f64) (param f64) (result f64)")))
(DTypeSig true "jsWireParam" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "jsWireParam" ((PLit (LString "Unit"))) (ELit (LString "")))
(DFunDef false "jsWireParam" ((PVar "head")) (EBinOp "++" (EBinOp "++" (ELit (LString " (param ")) (EApp (EVar "display") (EApp (EVar "jsWireTy") (EVar "head")))) (ELit (LString ")"))))
(DTypeSig true "jsWireResult" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "jsWireResult" ((PLit (LString "Unit"))) (ELit (LString "")))
(DFunDef false "jsWireResult" ((PLit (LString "String"))) (ELit (LString "")))
(DFunDef false "jsWireResult" ((PVar "head")) (EBinOp "++" (EBinOp "++" (ELit (LString " (result ")) (EApp (EVar "display") (EApp (EVar "jsWireTy") (EVar "head")))) (ELit (LString ")"))))
(DTypeSig false "jsWireTy" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "jsWireTy" ((PLit (LString "Int"))) (ELit (LString "i64")))
(DFunDef false "jsWireTy" ((PLit (LString "U64"))) (ELit (LString "i64")))
(DFunDef false "jsWireTy" ((PLit (LString "I64"))) (ELit (LString "i64")))
(DFunDef false "jsWireTy" ((PLit (LString "Float"))) (ELit (LString "f64")))
(DFunDef false "jsWireTy" (PWild) (ELit (LString "i32")))
(DTypeSig true "validateWasmDemand" (TyFun (TyCon "WasmDemandInputs") (TyFun (TyCon "CProgram") (TyFun (TyCon "ExternRequirements") (TyFun (TyCon "WasmDemandPlan") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "validateWasmDemand" ((PVar "inputs") (PVar "cp") (PVar "requirements") (PVar "actual")) (EBlock (DoLet false false (PVar "expected") (EApp (EApp (EApp (EVar "planWasmDemand") (EVar "inputs")) (EVar "cp")) (EVar "requirements"))) (DoLet false false (PVar "actualTypes") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "actual") "representationTypes")) (EVar "omEmpty"))) (DoLet false false (PVar "expectedKeys") (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "i") "namespace"))) (ELit (LString ":"))) (EApp (EVar "display") (EFieldAccess (EVar "i") "field"))) (ELit (LString ""))))) (EFieldAccess (EVar "expected") "imports"))) (DoLet false false (PVar "actualKeys") (EApp (EApp (EVar "map") (ELam ((PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "i") "namespace"))) (ELit (LString ":"))) (EApp (EVar "display") (EFieldAccess (EVar "i") "field"))) (ELit (LString ""))))) (EFieldAccess (EVar "actual") "imports"))) (DoLet false false (PVar "expectedSet") (EApp (EApp (EVar "omFromNames") (EVar "expectedKeys")) (EVar "omEmpty"))) (DoLet false false (PVar "actualSet") (EApp (EApp (EVar "omFromNames") (EVar "actualKeys")) (EVar "omEmpty"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EIf (EBinOp "||" (EBinOp "||" (EBinOp "/=" (EFieldAccess (EVar "expected") "useRef") (EFieldAccess (EVar "actual") "useRef")) (EBinOp "/=" (EFieldAccess (EVar "expected") "useClos") (EFieldAccess (EVar "actual") "useClos"))) (EBinOp "/=" (EFieldAccess (EVar "expected") "stringOps") (EFieldAccess (EVar "actual") "stringOps"))) (EListLit (ELit (LString "wasm-mode-mismatch"))) (EListLit)) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "/=" (EFieldAccess (EVar "expected") "sourceDemand") (EFieldAccess (EVar "actual") "sourceDemand")) (EBinOp "/=" (EFieldAccess (EVar "expected") "representation") (EFieldAccess (EVar "actual") "representation"))) (EBinOp "/=" (EFieldAccess (EVar "expected") "intHelpers") (EFieldAccess (EVar "actual") "intHelpers"))) (EBinOp "/=" (EFieldAccess (EVar "expected") "siteRuntime") (EFieldAccess (EVar "actual") "siteRuntime"))) (EBinOp "/=" (EFieldAccess (EVar "expected") "nonexhaustiveRuntime") (EFieldAccess (EVar "actual") "nonexhaustiveRuntime"))) (EListLit (ELit (LString "missing-wasm-helper-prerequisite: physical branches"))) (EListLit))) (EIf (EBinOp "||" (EBinOp "/=" (EFieldAccess (EVar "expected") "censusHelpers") (EFieldAccess (EVar "actual") "censusHelpers")) (EBinOp "/=" (EFieldAccess (EVar "expected") "censusIntHelpers") (EFieldAccess (EVar "actual") "censusIntHelpers"))) (EListLit (ELit (LString "wasm-census-demand-mismatch"))) (EListLit))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "actualTypes")) (EListLit) (EListLit (EBinOp "++" (ELit (LString "missing-wasm-type-prerequisite: ")) (EVar "name")))))) (EFieldAccess (EVar "expected") "representationTypes"))) (EIf (EBinOp "==" (EFieldAccess (EVar "expected") "representationTypes") (EFieldAccess (EVar "actual") "representationTypes")) (EListLit) (EListLit (ELit (LString "wasm-representation-types-mismatch"))))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "h")) (EIf (EApp (EApp (EVar "contains") (EVar "h")) (EFieldAccess (EVar "actual") "helpers")) (EListLit) (EListLit (EBinOp "++" (ELit (LString "missing-wasm-helper-prerequisite: ")) (EVar "h")))))) (EFieldAccess (EVar "expected") "helpers"))) (EIf (EBinOp "==" (EFieldAccess (EVar "expected") "helpers") (EFieldAccess (EVar "actual") "helpers")) (EListLit) (EIf (EApp (EApp (EVar "all") (ELam ((PVar "h")) (EApp (EApp (EVar "contains") (EVar "h")) (EFieldAccess (EVar "actual") "helpers")))) (EFieldAccess (EVar "expected") "helpers")) (EListLit (ELit (LString "unexpected-wasm-helper"))) (EListLit)))) (EIf (EBinOp "/=" (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "key") (PVar "family"))) (ETuple (EVar "key") (EApp (EVar "wasmFamilyTag") (EVar "family"))))) (EFieldAccess (EVar "expected") "catalogFamilies")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "key") (PVar "family"))) (ETuple (EVar "key") (EApp (EVar "wasmFamilyTag") (EVar "family"))))) (EFieldAccess (EVar "actual") "catalogFamilies"))) (EListLit (ELit (LString "wasm-catalog-disposition-mismatch"))) (EListLit))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "key")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "key")) (EVar "actualSet")) (EListLit) (EListLit (EBinOp "++" (ELit (LString "missing-wasm-host-key: ")) (EVar "key")))))) (EVar "expectedKeys"))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "key")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "key")) (EVar "expectedSet")) (EListLit) (EListLit (EBinOp "++" (ELit (LString "unexpected-wasm-host-key: ")) (EVar "key")))))) (EVar "actualKeys"))) (EIf (EBinOp "==" (EFieldAccess (EVar "expected") "imports") (EFieldAccess (EVar "actual") "imports")) (EListLit) (EListLit (ELit (LString "wasm-import-order"))))) (EIf (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "expected") "sourceHostKeys") (EFieldAccess (EVar "actual") "sourceHostKeys")) (EBinOp "==" (EFieldAccess (EVar "expected") "jsImports") (EFieldAccess (EVar "actual") "jsImports"))) (EListLit) (EListLit (ELit (LString "wasm-source-demand-mismatch"))))))))
(DTypeSig false "ctorToFloatIdxs" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "ctorToFloatIdxs" ((PTuple (PVar "ctor") (PVar "typeNames"))) (ETuple (EVar "ctor") (EApp (EApp (EVar "floatFieldIndices") (EVar "typeNames")) (ELit (LInt 0)))))
(DTypeSig false "floatFieldIndices" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "floatFieldIndices" ((PList) PWild) (EListLit))
(DFunDef false "floatFieldIndices" ((PCons (PLit (LString "Float")) (PVar "rest")) (PVar "i")) (EBinOp "::" (EVar "i") (EApp (EApp (EVar "floatFieldIndices") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "floatFieldIndices" ((PCons PWild (PVar "rest")) (PVar "i")) (EApp (EApp (EVar "floatFieldIndices") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))
(DTypeSig true "ctorFloatFieldIndex" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "ctorFloatFieldIndex" ((PVar "fields")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EVar "map") (EVar "ctorToFloatIdxs")) (EVar "fields")))) (EVar "omEmpty")))
(DTypeSig true "exprHasFallthrough" (TyFun (TyCon "CExpr") (TyCon "Bool")))
(DFunDef false "exprHasFallthrough" ((PCon "CVar" (PVar "x") PWild)) (EBinOp "==" (EVar "x") (ELit (LString "__fallthrough__"))))
(DFunDef false "exprHasFallthrough" ((PCon "CApp" (PVar "f") (PVar "args") PWild)) (EBinOp "||" (EApp (EVar "exprHasFallthrough") (EVar "f")) (EApp (EApp (EVar "anyList") (EVar "exprHasFallthrough")) (EVar "args"))))
(DFunDef false "exprHasFallthrough" ((PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "||" (EBinOp "||" (EApp (EVar "exprHasFallthrough") (EVar "c")) (EApp (EVar "exprHasFallthrough") (EVar "t"))) (EApp (EVar "exprHasFallthrough") (EVar "f"))))
(DFunDef false "exprHasFallthrough" ((PCon "CLet" PWild PWild (PVar "e1") (PVar "e2"))) (EBinOp "||" (EApp (EVar "exprHasFallthrough") (EVar "e1")) (EApp (EVar "exprHasFallthrough") (EVar "e2"))))
(DFunDef false "exprHasFallthrough" ((PCon "CLetGroup" PWild (PVar "body"))) (EApp (EVar "exprHasFallthrough") (EVar "body")))
(DFunDef false "exprHasFallthrough" ((PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EVar "anyList") (EVar "stmtHasFallthrough")) (EVar "stmts")))
(DFunDef false "exprHasFallthrough" ((PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EBinOp "||" (EApp (EVar "exprHasFallthrough") (EVar "scrut")) (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EApp (EVar "exprHasFallthrough") (EApp (EVar "armBody") (EVar "a"))))) (EVar "arms"))))
(DFunDef false "exprHasFallthrough" (PWild) (EVar "False"))
(DTypeSig false "stmtHasFallthrough" (TyFun (TyCon "CStmt") (TyCon "Bool")))
(DFunDef false "stmtHasFallthrough" ((PCon "CSExpr" (PVar "e"))) (EApp (EVar "exprHasFallthrough") (EVar "e")))
(DFunDef false "stmtHasFallthrough" ((PCon "CSLet" PWild PWild (PVar "e"))) (EApp (EVar "exprHasFallthrough") (EVar "e")))
(DFunDef false "stmtHasFallthrough" ((PCon "CSAssign" PWild (PVar "e"))) (EApp (EVar "exprHasFallthrough") (EVar "e")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Lit" true) (mem "Pat" true) (mem "Addr" true) (mem "BinderId" true) (mem "Loc" true) (mem "isTaggedFixedHead" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "DeclFacts" true) (mem "EntryFact" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CField" true) (mem "CGuard" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CStmt" true) (mem "CArm" true) (mem "CHead" true) (mem "CTree" true) (mem "CTBranch" true) (mem "CallSite" true) (mem "CallMode" true) (mem "FailSite" true) (mem "litRuntimeType" false) (mem "siteSentinelName" false))))
(DUse false (UseGroup ("ir" "extern_types") ((mem "ExternDeclFact" true))))
(DUse false (UseGroup ("ir" "extern_lower") ((mem "externRuntimeKey" false))))
(DUse false (UseGroup ("backend" "extern_requirements") ((mem "ExternRequirements" false) (mem "RequirementBinding" true) (mem "requirementHostRows" false) (mem "requirementFacts" false))))
(DUse false (UseGroup ("backend" "extern_catalog") ((mem "WasmUse" true) (mem "WasmFamily" true) (mem "Disposition" true) (mem "wasmUses" false) (mem "wasmHostKeys" false) (mem "wasmTupleArities" false) (mem "wasmFamily" false) (mem "isWasmExternFamily" false) (mem "fileBoundHostKeys" false))))
(DUse false (UseGroup ("backend" "global_plan") ((mem "GlobalInitPlan" false))))
(DUse false (UseGroup ("backend" "trmc_analysis") ((mem "TrmcVerdicts" false) (mem "DispGroup" false) (mem "patVarsList" false) (mem "patVars" false) (mem "bindName" false) (mem "clauseBodyOf" false) (mem "armBody" false) (mem "flattenApp" false))))
(DUse false (UseGroup ("backend" "emit_support") ((mem "appParts" false) (mem "isExactCall" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" true) (mem "RuntimeType" true) (mem "binderOrdinal" false))))
(DUse false (UseGroup ("types" "private_mangle") ((mem "injectiveIdent" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omKeys" false) (mem "omFromNames" false) (mem "omFromPairs" false) (mem "omDelete" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "filterList" false) (mem "listLen" false) (mem "contains" false) (mem "startsWith" false) (mem "isEmptyL" false) (mem "isNonEmptyL" false) (mem "anyList" false) (mem "lookupAssoc" false) (mem "joinWith" false) (mem "lenKey" false))))
(DData Public "JsImport" () ((variant "JsImport" (ConNamed (field "medakaName" (TyCon "String")) (field "jsName" (TyCon "String")) (field "params" (TyApp (TyCon "List") (TyCon "String"))) (field "result" (TyCon "String"))))) ())
(DImpl true "Eq" ((TyCon "JsImport")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "JsImport" ((rf "medakaName" (PVar "__a0")) (rf "jsName" (PVar "__a1")) (rf "params" (PVar "__a2")) (rf "result" (PVar "__a3"))) false) (PRec "JsImport" ((rf "medakaName" (PVar "__b0")) (rf "jsName" (PVar "__b1")) (rf "params" (PVar "__b2")) (rf "result" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "JsImport")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "JsImport" ((rf "medakaName" (PVar "__a0")) (rf "jsName" (PVar "__a1")) (rf "params" (PVar "__a2")) (rf "result" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "JsImport {")) (ELit (LString " medakaName = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", jsName = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", params = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString ", result = "))) (EApp (EMethodRef "debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DData Public "WasmDemand" () ((variant "WasmDemand" (ConNamed (field "uses" (TyApp (TyCon "List") (TyCon "WasmUse"))) (field "refBox" (TyCon "Bool")) (field "divGuard" (TyCon "Bool")) (field "tupleArities" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DImpl true "Eq" ((TyCon "WasmDemand")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "WasmDemand" ((rf "uses" (PVar "__a0")) (rf "refBox" (PVar "__a1")) (rf "divGuard" (PVar "__a2")) (rf "tupleArities" (PVar "__a3"))) false) (PRec "WasmDemand" ((rf "uses" (PVar "__b0")) (rf "refBox" (PVar "__b1")) (rf "divGuard" (PVar "__b2")) (rf "tupleArities" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "WasmDemand")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "WasmDemand" ((rf "uses" (PVar "__a0")) (rf "refBox" (PVar "__a1")) (rf "divGuard" (PVar "__a2")) (rf "tupleArities" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "WasmDemand {")) (ELit (LString " uses = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", refBox = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", divGuard = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString ", tupleArities = "))) (EApp (EMethodRef "debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DData Private "DemandAcc" () ((variant "DemandAcc" (ConNamed (field "seenUses" (TyApp (TyCon "List") (TyCon "WasmUse"))) (field "seenKeys" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "seenJs" (TyApp (TyCon "OrdMap") (TyCon "JsImport"))) (field "seenRefBox" (TyCon "Bool")) (field "seenDivGuard" (TyCon "Bool")) (field "seenArities" (TyApp (TyCon "List") (TyCon "Int")))))) ())
(DData Private "DemandScope" () ((variant "DemandScope" (ConNamed (field "locals" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "topFns" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "topVals" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "jsBinds" (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))) (field "externFacts" (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")))))) ())
(DTypeSig false "wasmDemandOf" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")) (TyFun (TyApp (TyCon "OrdMap") (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyTuple (TyCon "WasmDemand") (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "JsImport"))))))))
(DFunDef false "wasmDemandOf" ((PVar "externFacts") (PVar "jsBinds") (PVar "groups") (PVar "impls")) (EBlock (DoLet false false (PVar "start") (ERecordCreate "DemandAcc" ((fa "seenUses" (EListLit)) (fa "seenKeys" (EVar "omEmpty")) (fa "seenJs" (EVar "omEmpty")) (fa "seenRefBox" (EVar "False")) (fa "seenDivGuard" (EVar "False")) (fa "seenArities" (EListLit))))) (DoLet false false (PVar "tops") (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EBinOp "/=" (EApp (EVar "bindName") (EVar "b")) (ELit (LString "main"))))) (EVar "groups"))) (DoLet false false (PVar "sc") (ERecordCreate "DemandScope" ((fa "locals" (EVar "omEmpty")) (fa "topFns" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "bindName")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EApp (EVar "not") (EApp (EVar "isValBind") (EVar "b"))))) (EVar "tops")))) (EVar "omEmpty"))) (fa "topVals" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "bindName")) (EApp (EApp (EVar "filterList") (EVar "isValBind")) (EVar "tops")))) (EVar "omEmpty"))) (fa "jsBinds" (EVar "jsBinds")) (fa "externFacts" (EVar "externFacts"))))) (DoLet false false (PVar "acc") (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dImpl") (EVar "sc"))) (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dBind") (EVar "sc"))) (EVar "start")) (EVar "groups"))) (EVar "impls"))) (DoExpr (ETuple (ERecordCreate "WasmDemand" ((fa "uses" (EApp (EVar "reverseL") (EFieldAccess (EVar "acc") "seenUses"))) (fa "refBox" (EFieldAccess (EVar "acc") "seenRefBox")) (fa "divGuard" (EFieldAccess (EVar "acc") "seenDivGuard")) (fa "tupleArities" (EApp (EVar "reverseL") (EFieldAccess (EVar "acc") "seenArities"))))) (EApp (EVar "omKeys") (EFieldAccess (EVar "acc") "seenKeys")) (EApp (EApp (EMethodRef "filterMap") (ELam ((PVar "k")) (EApp (EApp (EVar "omLookup") (EVar "k")) (EFieldAccess (EVar "acc") "seenJs")))) (EApp (EVar "omKeys") (EFieldAccess (EVar "acc") "seenJs")))))))
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
(DFunDef false "noteName" ((PVar "acc") (PLit (LString "$withFileReadBound"))) (EApp (EVar "noteFileBound") (EVar "acc")))
(DFunDef false "noteName" ((PVar "acc") (PLit (LString "$withFileWriteBound"))) (EApp (EVar "noteFileBound") (EVar "acc")))
(DFunDef false "noteName" ((PVar "acc") (PVar "name")) (EBlock (DoLet false false (PVar "acc") (EMatch (EApp (EVar "wasmFamily") (EVar "name")) (arm (PCon "Some" (PCon "WasmRefCell")) () (EApp (EVar "noteRefBox") (EVar "acc"))) (arm PWild () (EVar "acc")))) (DoExpr (EApp (EApp (EApp (EVar "walkEach") (EVar "noteArity")) (EApp (EApp (EApp (EVar "walkEach") (EVar "noteKey")) (EApp (EApp (EApp (EVar "walkEach") (EVar "noteUse")) (EVar "acc")) (EApp (EVar "wasmUses") (EVar "name")))) (EApp (EVar "wasmHostKeys") (EVar "name")))) (EApp (EVar "wasmTupleArities") (EVar "name"))))))
(DTypeSig false "noteExtern" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyCon "String") (TyCon "DemandAcc")))))
(DFunDef false "noteExtern" ((PVar "sc") (PVar "acc") (PVar "name")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "sc") "jsBinds")) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "externRuntimeKey") (EFieldAccess (EVar "sc") "externFacts")) (EVar "name")) (arm (PCon "Some" (PVar "key")) () (EApp (EApp (EVar "noteName") (EVar "acc")) (EVar "key"))) (arm (PCon "None") () (EIf (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "$withFileReadBound"))) (EBinOp "==" (EVar "name") (ELit (LString "$withFileWriteBound")))) (EApp (EVar "noteFileBound") (EVar "acc")) (EVar "acc"))))) (arm (PCon "Some" (PTuple (PVar "js") (PTuple (PVar "params") (PVar "result")))) () (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "acc") "seenJs")) (EVar "acc") (EBlock (DoLet false false (PVar "imp") (ERecordCreate "JsImport" ((fa "medakaName" (EVar "name")) (fa "jsName" (EVar "js")) (fa "params" (EVar "params")) (fa "result" (EVar "result"))))) (DoExpr (EApp (EApp (EVar "noteJsResult") (EApp (EApp (EApp (EVar "walkEach") (EVar "noteJsParam")) (ERecordUpdate (EVar "acc") ((fa "seenJs" (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "imp")) (EFieldAccess (EVar "acc") "seenJs")))))) (EVar "params"))) (EVar "result"))))))))
(DTypeSig false "noteJsParam" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "String") (TyCon "DemandAcc"))))
(DFunDef false "noteJsParam" ((PVar "acc") (PLit (LString "String"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "noteKey")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseStr"))) (EVar "jsPathKeys")))
(DFunDef false "noteJsParam" ((PVar "acc") (PLit (LString "Array"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "noteKey")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseArray"))) (EBinOp "++" (EVar "jsPathKeys") (EVar "jsResultKeys"))))
(DFunDef false "noteJsParam" ((PVar "acc") (PVar "head")) (EApp (EApp (EVar "noteJsBoxed") (EVar "acc")) (EVar "head")))
(DTypeSig false "noteJsResult" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "String") (TyCon "DemandAcc"))))
(DFunDef false "noteJsResult" ((PVar "acc") (PLit (LString "String"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "noteKey")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseStr"))) (EVar "jsResultKeys")))
(DFunDef false "noteJsResult" ((PVar "acc") (PVar "head")) (EApp (EApp (EVar "noteJsBoxed") (EVar "acc")) (EVar "head")))
(DTypeSig false "noteJsBoxed" (TyFun (TyCon "DemandAcc") (TyFun (TyCon "String") (TyCon "DemandAcc"))))
(DFunDef false "noteJsBoxed" ((PVar "acc") (PLit (LString "Float"))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseFloat")))
(DFunDef false "noteJsBoxed" ((PVar "acc") (PLit (LString "U64"))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseU64")))
(DFunDef false "noteJsBoxed" ((PVar "acc") (PLit (LString "I64"))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseI64")))
(DFunDef false "noteJsBoxed" ((PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "jsPathKeys" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "jsPathKeys" () (EListLit (ELit (LString "mdk_path_reset")) (ELit (LString "mdk_path_push"))))
(DTypeSig false "jsResultKeys" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "jsResultKeys" () (EListLit (ELit (LString "mdk_result_len")) (ELit (LString "mdk_result_byte"))))
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
(DTypeSig false "isValBind" (TyFun (TyCon "CBind") (TyCon "Bool")))
(DFunDef false "isValBind" ((PCon "CBind" (PVar "name") (PList (PCon "CClause" (PList) PWild)) PWild PWild)) (EBinOp "/=" (EVar "name") (ELit (LString "main"))))
(DFunDef false "isValBind" (PWild) (EVar "False"))
(DTypeSig false "bindIn" (TyFun (TyCon "DemandScope") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "DemandScope"))))
(DFunDef false "bindIn" ((PVar "sc") (PVar "pats")) (EMatch (EApp (EVar "patVarsList") (EVar "pats")) (arm (PList) () (EVar "sc")) (arm (PVar "names") () (ERecordUpdate (EVar "sc") ((fa "locals" (EApp (EApp (EVar "omFromNames") (EVar "names")) (EFieldAccess (EVar "sc") "locals"))))))))
(DTypeSig false "isLocal" (TyFun (TyCon "DemandScope") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isLocal" ((PVar "sc") (PVar "x")) (EApp (EApp (EVar "omHasKey") (EVar "x")) (EFieldAccess (EVar "sc") "locals")))
(DTypeSig false "isCoreFn" (TyFun (TyCon "DemandScope") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "isCoreFn" ((PVar "sc") (PVar "x")) (EApp (EApp (EVar "omHasKey") (EBinOp "++" (ELit (LString "core__")) (EVar "x"))) (EFieldAccess (EVar "sc") "topFns")))
(DTypeSig false "dVar" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyCon "String") (TyCon "DemandAcc")))))
(DFunDef false "dVar" ((PVar "sc") (PVar "acc") (PVar "x")) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "isLocal") (EVar "sc")) (EVar "x")) (EApp (EApp (EVar "omHasKey") (EVar "x")) (EFieldAccess (EVar "sc") "topVals"))) (EApp (EApp (EVar "omHasKey") (EVar "x")) (EFieldAccess (EVar "sc") "topFns"))) (EApp (EApp (EVar "isCoreFn") (EVar "sc")) (EVar "x"))) (EVar "acc") (EApp (EApp (EApp (EVar "noteExtern") (EVar "sc")) (EVar "acc")) (EVar "x"))))
(DTypeSig false "dBind" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CBind") (TyCon "DemandAcc")))))
(DFunDef false "dBind" ((PVar "sc") (PVar "acc") (PCon "CBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dClause") (EVar "sc"))) (EVar "acc")) (EVar "clauses")))
(DTypeSig false "dClause" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CClause") (TyCon "DemandAcc")))))
(DFunDef false "dClause" ((PVar "sc") (PVar "acc") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "bindIn") (EVar "sc")) (EVar "pats"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dPat")) (EVar "acc")) (EVar "pats"))) (EVar "body")))
(DTypeSig false "dImpl" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CImplEntry") (TyCon "DemandAcc")))))
(DFunDef false "dImpl" ((PVar "sc") (PVar "acc") (PCon "CImplEntry" PWild PWild PWild (PCon "CImplTagged" PWild PWild PWild PWild PWild (PVar "pats") (PVar "b")))) (EApp (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "bindIn") (EVar "sc")) (EVar "pats"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dPat")) (EVar "acc")) (EVar "pats"))) (EVar "b")))
(DFunDef false "dImpl" ((PVar "sc") (PVar "acc") (PCon "CImplEntry" PWild PWild PWild (PCon "CImplDefault" PWild PWild PWild PWild PWild (PVar "pats") (PVar "b")))) (EApp (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "bindIn") (EVar "sc")) (EVar "pats"))) (EApp (EApp (EApp (EVar "walkEach") (EVar "dPat")) (EVar "acc")) (EVar "pats"))) (EVar "b")))
(DTypeSig false "dExpr" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CExpr") (TyCon "DemandAcc")))))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CList" (PVar "es"))) (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dExpr") (EVar "sc"))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseList"))) (EVar "es")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseList"))) (EVar "lo"))) (EVar "hi")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CTuple" (PVar "es"))) (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dExpr") (EVar "sc"))) (EApp (EApp (EVar "noteArity") (EVar "acc")) (EApp (EVar "listLen") (EVar "es")))) (EVar "es")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CArray" (PVar "es"))) (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dExpr") (EVar "sc"))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseArray"))) (EVar "es")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseArray"))) (EVar "lo"))) (EVar "hi")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseArray"))) (EVar "a"))) (EVar "i")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseArray"))) (EVar "a"))) (EVar "lo"))) (EVar "hi")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CRecord" PWild (PVar "fields"))) (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dField") (EVar "sc"))) (EVar "acc")) (EVar "fields")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CFieldAccess" (PVar "ex") PWild PWild PWild)) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "ex")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CRecordUpdate" PWild (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dField") (EVar "sc"))) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "base"))) (EVar "fields")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CVariantUpdate" PWild (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dField") (EVar "sc"))) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "base"))) (EVar "fields")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PAs "app" (PCon "CApp" PWild PWild PWild))) (EBlock (DoLet false false (PTuple (PVar "hd") (PVar "args")) (EApp (EApp (EVar "flattenApp") (EVar "app")) (EListLit))) (DoExpr (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dExpr") (EVar "sc"))) (EApp (EApp (EApp (EVar "dAppHead") (EVar "sc")) (EVar "acc")) (EVar "hd"))) (EVar "args")))))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CVar" (PVar "x") PWild)) (EApp (EApp (EApp (EVar "dVar") (EVar "sc")) (EVar "acc")) (EVar "x")))
(DFunDef false "dExpr" (PWild (PVar "acc") (PCon "CLit" (PCon "LFloat" PWild))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseFloat")))
(DFunDef false "dExpr" (PWild (PVar "acc") (PCon "CLit" (PCon "LU64" PWild PWild))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseU64")))
(DFunDef false "dExpr" (PWild (PVar "acc") (PCon "CLit" (PCon "LI64" PWild PWild))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseI64")))
(DFunDef false "dExpr" (PWild (PVar "acc") (PCon "CLit" (PCon "LString" PWild))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseStr")))
(DFunDef false "dExpr" (PWild (PVar "acc") (PCon "CLit" (PCon "LChar" PWild))) (EApp (EApp (EVar "noteUse") (EVar "acc")) (EVar "UseStr")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CLam" (PVar "pats") (PVar "b"))) (EApp (EApp (EApp (EVar "dExpr") (EApp (EApp (EVar "bindIn") (EVar "sc")) (EVar "pats"))) (EVar "acc")) (EVar "b")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") PWild)) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EVar "noteBinop") (EApp (EApp (EVar "noteTag") (EVar "acc")) (EVar "tag"))) (EVar "op"))) (EVar "l"))) (EVar "r")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CUnOp" PWild (PVar "x"))) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "x")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "c"))) (EVar "t"))) (EVar "f")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CLet" (PVar "r") (PVar "pat") (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindIn") (EVar "sc")) (EListLit (EVar "pat")))) (DoExpr (EApp (EApp (EApp (EVar "dExpr") (EVar "inner")) (EApp (EApp (EApp (EVar "dExpr") (EIf (EVar "r") (EVar "inner") (EVar "sc"))) (EApp (EApp (EVar "dPat") (EVar "acc")) (EVar "pat"))) (EVar "a"))) (EVar "b")))))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EApp (EVar "dStmts") (EVar "sc")) (EVar "acc")) (EVar "stmts")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EVar "dTree") (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dArm") (EVar "sc"))) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "scrut"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dArm") (EVar "sc"))) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "scrut"))) (EVar "arms")))
(DFunDef false "dExpr" ((PVar "sc") (PVar "acc") (PCon "CLetGroup" (PVar "binds") (PVar "b"))) (EBlock (DoLet false false (PVar "inner") (ERecordUpdate (EVar "sc") ((fa "locals" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "bindName")) (EVar "binds"))) (EFieldAccess (EVar "sc") "locals")))))) (DoExpr (EApp (EApp (EApp (EVar "dExpr") (EVar "inner")) (EApp (EApp (EApp (EVar "walkEach") (EApp (EVar "dBind") (EVar "inner"))) (EVar "acc")) (EVar "binds"))) (EVar "b")))))
(DFunDef false "dExpr" (PWild (PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "dAppHead" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CExpr") (TyCon "DemandAcc")))))
(DFunDef false "dAppHead" ((PVar "sc") (PVar "acc") (PCon "CVar" (PVar "f") PWild)) (EIf (EBinOp "||" (EApp (EApp (EVar "isLocal") (EVar "sc")) (EVar "f")) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "f")) (EFieldAccess (EVar "sc") "topFns"))) (EApp (EApp (EVar "isCoreFn") (EVar "sc")) (EVar "f")))) (EVar "acc") (EApp (EApp (EApp (EVar "noteExtern") (EVar "sc")) (EVar "acc")) (EVar "f"))))
(DFunDef false "dAppHead" ((PVar "sc") (PVar "acc") (PVar "h")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "h")))
(DTypeSig false "dField" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CField") (TyCon "DemandAcc")))))
(DFunDef false "dField" ((PVar "sc") (PVar "acc") (PCon "CField" PWild PWild (PVar "e"))) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "e")))
(DTypeSig false "dArm" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyCon "CArm") (TyCon "DemandAcc")))))
(DFunDef false "dArm" ((PVar "sc") (PVar "acc") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "dGuarded") (EApp (EApp (EVar "bindIn") (EVar "sc")) (EListLit (EVar "pat")))) (EApp (EApp (EVar "dPat") (EVar "acc")) (EVar "pat"))) (EVar "guards")) (EVar "body")))
(DTypeSig false "dGuarded" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyFun (TyCon "CExpr") (TyCon "DemandAcc"))))))
(DFunDef false "dGuarded" ((PVar "sc") (PVar "acc") (PList) (PVar "body")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "body")))
(DFunDef false "dGuarded" ((PVar "sc") (PVar "acc") (PCons (PCon "CGBool" (PVar "g")) (PVar "rest")) (PVar "body")) (EApp (EApp (EApp (EApp (EVar "dGuarded") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "g"))) (EVar "rest")) (EVar "body")))
(DFunDef false "dGuarded" ((PVar "sc") (PVar "acc") (PCons (PCon "CGBind" (PVar "p") (PVar "e")) (PVar "rest")) (PVar "body")) (EApp (EApp (EApp (EApp (EVar "dGuarded") (EApp (EApp (EVar "bindIn") (EVar "sc")) (EListLit (EVar "p")))) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EApp (EApp (EVar "dPat") (EVar "acc")) (EVar "p"))) (EVar "e"))) (EVar "rest")) (EVar "body")))
(DTypeSig false "dStmts" (TyFun (TyCon "DemandScope") (TyFun (TyCon "DemandAcc") (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyCon "DemandAcc")))))
(DFunDef false "dStmts" (PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "dStmts" ((PVar "sc") (PVar "acc") (PCons (PCon "CSExpr" (PVar "e")) (PVar "rest"))) (EApp (EApp (EApp (EVar "dStmts") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "e"))) (EVar "rest")))
(DFunDef false "dStmts" ((PVar "sc") (PVar "acc") (PCons (PCon "CSLet" (PVar "r") (PVar "pat") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindIn") (EVar "sc")) (EListLit (EVar "pat")))) (DoExpr (EApp (EApp (EApp (EVar "dStmts") (EVar "inner")) (EApp (EApp (EApp (EVar "dExpr") (EIf (EVar "r") (EVar "inner") (EVar "sc"))) (EApp (EApp (EVar "dPat") (EVar "acc")) (EVar "pat"))) (EVar "e"))) (EVar "rest")))))
(DFunDef false "dStmts" ((PVar "sc") (PVar "acc") (PCons (PCon "CSAssign" PWild (PVar "e")) (PVar "rest"))) (EApp (EApp (EApp (EVar "dStmts") (EVar "sc")) (EApp (EApp (EApp (EVar "dExpr") (EVar "sc")) (EVar "acc")) (EVar "e"))) (EVar "rest")))
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
(DTypeSig false "programUsesStr" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyCon "Bool"))))
(DFunDef false "programUsesStr" ((PVar "facts") (PVar "groups")) (EApp (EApp (EVar "anyBind") (EApp (EVar "bindUsesStr") (EVar "facts"))) (EVar "groups")))
(DTypeSig false "bindUsesStr" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")) (TyFun (TyCon "CBind") (TyCon "Bool"))))
(DFunDef false "bindUsesStr" ((PVar "facts") (PCon "CBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "anyList") (ELam ((PVar "c")) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EApp (EVar "clauseBodyOf") (EVar "c"))))) (EVar "clauses")))
(DTypeSig false "exprUsesStr" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")) (TyFun (TyCon "CExpr") (TyCon "Bool"))))
(DFunDef false "exprUsesStr" (PWild (PCon "CLit" (PCon "LString" PWild))) (EVar "True"))
(DFunDef false "exprUsesStr" (PWild (PCon "CLit" (PCon "LChar" PWild))) (EVar "True"))
(DFunDef false "exprUsesStr" (PWild (PCon "CLit" PWild)) (EVar "False"))
(DFunDef false "exprUsesStr" ((PVar "facts") (PCon "CVar" (PVar "symbol") (PCon "AGlobal"))) (EBinOp "||" (EApp (EVar "isStrModeNameW") (EVar "symbol")) (EMatch (EApp (EApp (EVar "externRuntimeKey") (EVar "facts")) (EVar "symbol")) (arm (PCon "Some" (PVar "key")) () (EApp (EVar "isStrModeNameW") (EVar "key"))) (arm (PCon "None") () (EVar "False")))))
(DFunDef false "exprUsesStr" (PWild (PCon "CVar" (PVar "symbol") PWild)) (EApp (EVar "isStrModeNameW") (EVar "symbol")))
(DFunDef false "exprUsesStr" ((PVar "facts") (PAs "app" (PCon "CApp" PWild PWild PWild))) (EBlock (DoLet false false (PTuple (PVar "hd") (PVar "args")) (EApp (EApp (EVar "flattenApp") (EVar "app")) (EListLit))) (DoExpr (EBinOp "||" (EApp (EApp (EVar "headUsesStr") (EVar "facts")) (EVar "hd")) (EApp (EApp (EVar "anyList") (EApp (EVar "exprUsesStr") (EVar "facts"))) (EVar "args"))))))
(DFunDef false "exprUsesStr" ((PVar "facts") (PCon "CLam" PWild (PVar "b"))) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "b")))
(DFunDef false "exprUsesStr" ((PVar "facts") (PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild PWild)) (EBinOp "||" (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "l")) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "r"))))
(DFunDef false "exprUsesStr" ((PVar "facts") (PCon "CUnOp" PWild (PVar "x"))) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "x")))
(DFunDef false "exprUsesStr" ((PVar "facts") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "c")) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "t"))) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "f"))))
(DFunDef false "exprUsesStr" ((PVar "facts") (PCon "CLet" PWild PWild (PVar "a") (PVar "b"))) (EBinOp "||" (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "a")) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "b"))))
(DFunDef false "exprUsesStr" ((PVar "facts") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EVar "anyList") (EApp (EVar "stmtUsesStr") (EVar "facts"))) (EVar "stmts")))
(DFunDef false "exprUsesStr" ((PVar "facts") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EBinOp "||" (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "scrut")) (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EApp (EVar "armBody") (EVar "a"))))) (EVar "arms"))))
(DFunDef false "exprUsesStr" ((PVar "facts") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EBinOp "||" (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "scrut")) (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EApp (EVar "armBody") (EVar "a"))))) (EVar "arms"))))
(DFunDef false "exprUsesStr" (PWild PWild) (EVar "False"))
(DTypeSig false "stmtUsesStr" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")) (TyFun (TyCon "CStmt") (TyCon "Bool"))))
(DFunDef false "stmtUsesStr" ((PVar "facts") (PCon "CSExpr" (PVar "e"))) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "e")))
(DFunDef false "stmtUsesStr" ((PVar "facts") (PCon "CSLet" PWild PWild (PVar "e"))) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "e")))
(DFunDef false "stmtUsesStr" (PWild PWild) (EVar "False"))
(DTypeSig false "headUsesStr" (TyFun (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact")) (TyFun (TyCon "CExpr") (TyCon "Bool"))))
(DFunDef false "headUsesStr" ((PVar "facts") (PVar "h")) (EApp (EApp (EVar "exprUsesStr") (EVar "facts")) (EVar "h")))
(DTypeSig false "isStrModeNameW" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isStrModeNameW" ((PVar "name")) (EMatch (EApp (EVar "wasmFamily") (EVar "name")) (arm (PCon "Some" (PCon "WasmStr")) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "bindUsesClosures" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "CBind") (TyCon "Bool")))))
(DFunDef false "bindUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PCon "CBind" PWild (PVar "clauses") PWild PWild)) (EBinOp "||" (EApp (EVar "multiOrPatternClauses") (EVar "clauses")) (EApp (EApp (EVar "anyList") (EApp (EApp (EVar "clauseUsesClosures") (EVar "fnNames")) (EVar "ctorArs"))) (EVar "clauses"))))
(DTypeSig false "multiOrPatternClauses" (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyCon "Bool")))
(DFunDef false "multiOrPatternClauses" ((PList)) (EVar "False"))
(DFunDef false "multiOrPatternClauses" ((PList (PCon "CClause" (PVar "pats") PWild))) (EApp (EApp (EVar "anyList") (ELam ((PVar "p")) (EApp (EVar "not") (EApp (EVar "isPlainParam") (EVar "p"))))) (EVar "pats")))
(DFunDef false "multiOrPatternClauses" (PWild) (EVar "True"))
(DTypeSig false "isPlainParam" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "isPlainParam" ((PCon "PVar" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isPlainParam" ((PCon "PWild")) (EVar "True"))
(DFunDef false "isPlainParam" (PWild) (EVar "False"))
(DTypeSig false "clauseUsesClosures" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "CClause") (TyCon "Bool")))))
(DFunDef false "clauseUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EApp (EApp (EDictApp "flatMap") (EVar "patVars")) (EVar "pats"))) (EVar "body")))
(DTypeSig false "exprUsesClosures" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CExpr") (TyCon "Bool"))))))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCon "CLam" PWild PWild)) (EVar "True"))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PAs "app" (PCon "CApp" PWild PWild PWild))) (EApp (EApp (EApp (EApp (EVar "appUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "app")))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCon "CVar" (PVar "x") PWild)) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "x")) (EVar "locals"))) (EApp (EApp (EVar "fnMemberIndexW") (EVar "fnNames")) (EVar "x"))))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCon "CLit" PWild)) (EVar "False"))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild PWild)) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "l")) (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "r"))))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCon "CUnOp" PWild (PVar "x"))) (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "x")))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "||" (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "c")) (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "t"))) (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "f"))))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCon "CLet" PWild (PVar "pat") (PVar "a") (PVar "b"))) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EBinOp "++" (EApp (EVar "patVars") (EVar "pat")) (EVar "locals"))) (EVar "b"))))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EVar "blockUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "stmts")))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "scrut")) (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EApp (EVar "armBody") (EVar "a"))))) (EVar "arms"))))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "scrut")) (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EApp (EVar "armBody") (EVar "a"))))) (EVar "arms"))))
(DFunDef false "exprUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") PWild) (EVar "False"))
(DTypeSig false "blockUsesClosures" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyCon "Bool"))))))
(DFunDef false "blockUsesClosures" (PWild PWild PWild (PList)) (EVar "False"))
(DFunDef false "blockUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCons (PCon "CSLet" PWild (PVar "pat") (PVar "e")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "e")) (EApp (EApp (EApp (EApp (EVar "blockUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EBinOp "++" (EApp (EVar "patVars") (EVar "pat")) (EVar "locals"))) (EVar "rest"))))
(DFunDef false "blockUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCons (PCon "CSExpr" (PVar "e")) (PVar "rest"))) (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "e")) (EApp (EApp (EApp (EApp (EVar "blockUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "rest"))))
(DFunDef false "blockUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EApp (EVar "blockUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals")) (EVar "rest")))
(DTypeSig false "appUsesClosures" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CExpr") (TyCon "Bool"))))))
(DFunDef false "appUsesClosures" ((PVar "fnNames") (PVar "ctorArs") (PVar "locals") (PVar "app")) (EBlock (DoLet false false (PTuple (PVar "hd") (PVar "args") (PVar "mode")) (EApp (EVar "appParts") (EVar "app"))) (DoLet false false (PVar "argsClos") (EApp (EApp (EVar "anyList") (EApp (EApp (EApp (EVar "exprUsesClosures") (EVar "fnNames")) (EVar "ctorArs")) (EVar "locals"))) (EVar "args"))) (DoExpr (EMatch (EVar "hd") (arm (PCon "CVar" (PVar "f") PWild) () (EIf (EApp (EApp (EVar "contains") (EVar "f")) (EVar "locals")) (EVar "True") (EIf (EApp (EApp (EVar "fnMemberIndexW") (EVar "fnNames")) (EVar "f")) (EBinOp "||" (EApp (EVar "not") (EApp (EVar "isExactCall") (EVar "mode"))) (EVar "argsClos")) (EIf (EBinOp "||" (EApp (EVar "isSome") (EApp (EApp (EVar "lookupAssoc") (EVar "f")) (EVar "ctorArs"))) (EApp (EVar "isReservedCtor") (EVar "f"))) (EVar "argsClos") (EVar "True"))))) (arm PWild () (EVar "True"))))))
(DTypeSig false "programUsesAdt" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyCon "Bool"))))
(DFunDef false "programUsesAdt" ((PVar "groups") (PVar "ctorArs")) (EBinOp "||" (EBinOp "/=" (EApp (EVar "listLen") (EVar "ctorArs")) (ELit (LInt 0))) (EApp (EVar "anyBindHasDecision") (EVar "groups"))))
(DTypeSig false "anyBindHasDecision" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyCon "Bool")))
(DFunDef false "anyBindHasDecision" ((PList)) (EVar "False"))
(DFunDef false "anyBindHasDecision" ((PCons (PCon "CBind" PWild (PVar "clauses") PWild PWild) (PVar "rest"))) (EIf (EApp (EVar "anyClauseHasDecision") (EVar "clauses")) (EVar "True") (EApp (EVar "anyBindHasDecision") (EVar "rest"))))
(DTypeSig false "anyClauseHasDecision" (TyFun (TyApp (TyCon "List") (TyCon "CClause")) (TyCon "Bool")))
(DFunDef false "anyClauseHasDecision" ((PList)) (EVar "False"))
(DFunDef false "anyClauseHasDecision" ((PCons (PCon "CClause" PWild (PVar "body")) (PVar "rest"))) (EIf (EApp (EVar "exprHasDecision") (EVar "body")) (EVar "True") (EApp (EVar "anyClauseHasDecision") (EVar "rest"))))
(DTypeSig false "exprHasDecision" (TyFun (TyCon "CExpr") (TyCon "Bool")))
(DFunDef false "exprHasDecision" ((PCon "CDecision" PWild PWild PWild)) (EVar "True"))
(DFunDef false "exprHasDecision" ((PCon "CMatch" PWild PWild)) (EVar "True"))
(DFunDef false "exprHasDecision" ((PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "||" (EBinOp "||" (EApp (EVar "exprHasDecision") (EVar "c")) (EApp (EVar "exprHasDecision") (EVar "t"))) (EApp (EVar "exprHasDecision") (EVar "f"))))
(DFunDef false "exprHasDecision" ((PCon "CLet" PWild PWild (PVar "a") (PVar "b"))) (EBinOp "||" (EApp (EVar "exprHasDecision") (EVar "a")) (EApp (EVar "exprHasDecision") (EVar "b"))))
(DFunDef false "exprHasDecision" ((PCon "CBinPrim" PWild (PVar "a") (PVar "b") PWild PWild)) (EBinOp "||" (EApp (EVar "exprHasDecision") (EVar "a")) (EApp (EVar "exprHasDecision") (EVar "b"))))
(DFunDef false "exprHasDecision" ((PCon "CUnOp" PWild (PVar "a"))) (EApp (EVar "exprHasDecision") (EVar "a")))
(DFunDef false "exprHasDecision" ((PCon "CApp" (PVar "f") (PVar "args") PWild)) (EBinOp "||" (EApp (EVar "exprHasDecision") (EVar "f")) (EApp (EApp (EVar "anyList") (EVar "exprHasDecision")) (EVar "args"))))
(DFunDef false "exprHasDecision" ((PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EVar "anyList") (EVar "stmtHasDecision")) (EVar "stmts")))
(DFunDef false "exprHasDecision" (PWild) (EVar "False"))
(DTypeSig false "stmtHasDecision" (TyFun (TyCon "CStmt") (TyCon "Bool")))
(DFunDef false "stmtHasDecision" ((PCon "CSExpr" (PVar "e"))) (EApp (EVar "exprHasDecision") (EVar "e")))
(DFunDef false "stmtHasDecision" ((PCon "CSLet" PWild PWild (PVar "e"))) (EApp (EVar "exprHasDecision") (EVar "e")))
(DFunDef false "stmtHasDecision" (PWild) (EVar "False"))
(DTypeSig false "anyBind" (TyFun (TyFun (TyCon "CBind") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyCon "Bool"))))
(DFunDef false "anyBind" (PWild (PList)) (EVar "False"))
(DFunDef false "anyBind" ((PVar "p") (PCons (PVar "b") (PVar "rest"))) (EBinOp "||" (EApp (EVar "p") (EVar "b")) (EApp (EApp (EVar "anyBind") (EVar "p")) (EVar "rest"))))
(DTypeSig false "fnMemberIndexW" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "fnMemberIndexW" ((PVar "names") (PVar "n")) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "names")))
(DTypeSig false "isReservedCtor" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isReservedCtor" ((PVar "n")) (EApp (EApp (EVar "contains") (EVar "n")) (EListLit (ELit (LString "Some")) (ELit (LString "None")) (ELit (LString "Ok")) (ELit (LString "Err")) (ELit (LString "Lt")) (ELit (LString "Eq")) (ELit (LString "Gt")))))
(DData Public "WasmTypeContext" () ((variant "WasmTypeContext" (ConNamed (field "rows" (TyApp (TyCon "OrdMap") (TyCon "BinderRow"))) (field "tops" (TyApp (TyCon "OrdMap") (TyCon "BinderRow"))) (field "fnNames" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "valNames" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "externFacts" (TyApp (TyCon "OrdMap") (TyCon "ExternDeclFact"))) (field "ctorFloatFields" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int")))) (field "ctorArities" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))))) ())
(DTypeSig true "wasmTypeContext" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int"))) (TyFun (TyCon "CProgram") (TyCon "WasmTypeContext"))))
(DFunDef false "wasmTypeContext" ((PVar "ctorFields") (PCon "CProgram" (PVar "groups") (PVar "ctorArs") PWild PWild PWild (PVar "facts"))) (EBlock (DoLet false false (PVar "rows") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EMethodRef "map") (ELam ((PVar "row")) (ETuple (EApp (EVar "intToString") (EApp (EVar "binderOrdinal") (EFieldAccess (EVar "row") "brId"))) (EVar "row")))) (EFieldAccess (EVar "facts") "factBinders")))) (EVar "omEmpty"))) (DoExpr (ERecordCreate "WasmTypeContext" ((fa "rows" (EVar "rows")) (fa "tops" (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EMethodRef "filterMap") (ELam ((PCon "CBind" (PVar "n") PWild PWild (PVar "bid"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "row")) (ETuple (EVar "n") (EVar "row")))) (EApp (EApp (EVar "omLookup") (EApp (EVar "intToString") (EApp (EVar "binderOrdinal") (EVar "bid")))) (EVar "rows"))))) (EVar "groups")))) (EVar "omEmpty"))) (fa "fnNames" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "bindName")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EBinOp "&&" (EBinOp "/=" (EApp (EVar "bindName") (EVar "b")) (ELit (LString "main"))) (EApp (EVar "not") (EApp (EVar "isValBind") (EVar "b")))))) (EVar "groups")))) (EVar "omEmpty"))) (fa "valNames" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "bindName")) (EApp (EApp (EVar "filterList") (ELam ((PVar "b")) (EBinOp "&&" (EBinOp "/=" (EApp (EVar "bindName") (EVar "b")) (ELit (LString "main"))) (EApp (EVar "isValBind") (EVar "b"))))) (EVar "groups")))) (EVar "omEmpty"))) (fa "externFacts" (EFieldAccess (EVar "facts") "factExterns")) (fa "ctorFloatFields" (EVar "ctorFields")) (fa "ctorArities" (EVar "ctorArs")))))))
(DTypeSig false "runtimeKeyD" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "runtimeKeyD" ((PVar "ctx") (PVar "symbol")) (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EApp (EVar "externRuntimeKey") (EFieldAccess (EVar "ctx") "externFacts")) (EVar "symbol"))))
(DTypeSig true "envMark" (TyFun (TyCon "String") (TyFun (TyCon "BinderId") (TyCon "String"))))
(DFunDef false "envMark" ((PVar "x") (PVar "bid")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "binderOrdinal") (EVar "bid"))))) (ELit (LString ""))))
(DTypeSig true "envBind" (TyFun (TyCon "String") (TyFun (TyCon "BinderId") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "envBind" ((PVar "x") (PVar "bid") (PVar "env")) (EBinOp "::" (EVar "x") (EBinOp "::" (EApp (EApp (EVar "envMark") (EVar "x")) (EVar "bid")) (EVar "env"))))
(DTypeSig true "paramEnv" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "paramEnv" ((PVar "pats")) (EApp (EApp (EDictApp "flatMap") (EVar "paramEntries")) (EVar "pats")))
(DTypeSig true "paramEntries" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "paramEntries" ((PCon "PVar" (PVar "x") PWild (PVar "bid"))) (EListLit (EVar "x") (EApp (EApp (EVar "envMark") (EVar "x")) (EVar "bid"))))
(DFunDef false "paramEntries" (PWild) (EListLit (ELit (LString "_"))))
(DTypeSig true "patBinders" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "BinderId")))))
(DFunDef false "patBinders" ((PCon "PVar" (PVar "x") PWild (PVar "bid"))) (EListLit (ETuple (EVar "x") (EVar "bid"))))
(DFunDef false "patBinders" ((PCon "PAs" (PVar "x") PWild (PVar "bid") (PVar "p"))) (EBinOp "::" (ETuple (EVar "x") (EVar "bid")) (EApp (EVar "patBinders") (EVar "p"))))
(DFunDef false "patBinders" ((PCon "PCon" PWild (PVar "args"))) (EApp (EApp (EDictApp "flatMap") (EVar "patBinders")) (EVar "args")))
(DFunDef false "patBinders" ((PCon "PTuple" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patBinders")) (EVar "ps")))
(DFunDef false "patBinders" ((PCon "PCons" (PVar "h") (PVar "t"))) (EBinOp "++" (EApp (EVar "patBinders") (EVar "h")) (EApp (EVar "patBinders") (EVar "t"))))
(DFunDef false "patBinders" ((PCon "PList" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EVar "patBinders")) (EVar "ps")))
(DFunDef false "patBinders" (PWild) (EListLit))
(DTypeSig true "envBindPat" (TyFun (TyCon "Pat") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "envBindPat" ((PVar "pat") (PVar "env")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "b")) (EApp (EApp (EApp (EVar "envBind") (EApp (EVar "fst") (EVar "b"))) (EApp (EVar "snd") (EVar "b"))) (EVar "acc")))) (EVar "env")) (EApp (EVar "patBinders") (EVar "pat"))))
(DTypeSig true "envMarksOf" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "envMarksOf" ((PVar "names") (PVar "env")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "x")) (EApp (EApp (EVar "envMarkOf") (EVar "x")) (EVar "env")))) (EVar "names")))
(DTypeSig true "envWithMarks" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "envWithMarks" ((PVar "names") (PVar "marks")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "x")) (EBinOp "::" (EVar "x") (EApp (EApp (EVar "filterList") (EApp (EVar "startsWith") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString "@"))))) (EVar "marks"))))) (EVar "names")))
(DTypeSig true "envMarkOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "envMarkOf" ((PVar "x") (PVar "env")) (EMatch (EApp (EApp (EVar "envLookup") (EVar "x")) (EVar "env")) (arm (PCon "LocalBinder" (PVar "ord")) () (EListLit (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString "@"))) (EApp (EMethodRef "display") (EVar "ord"))) (ELit (LString ""))))) (arm PWild () (EListLit))))
(DData Public "EnvRef" () ((variant "NotLocal" (ConPos)) (variant "LocalUnstamped" (ConPos)) (variant "LocalBinder" (ConPos (TyCon "String")))) ())
(DTypeSig true "envLookup" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "EnvRef"))))
(DFunDef false "envLookup" (PWild (PList)) (EVar "NotLocal"))
(DFunDef false "envLookup" ((PVar "x") (PCons (PVar "e") (PVar "rest"))) (EIf (EBinOp "==" (EVar "e") (EVar "x")) (EMatch (EVar "rest") (arm (PCons (PVar "m") PWild) () (EIf (EApp (EApp (EVar "startsWith") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "x"))) (ELit (LString "@")))) (EVar "m")) (EApp (EVar "LocalBinder") (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EApp (EVar "stringLength") (EVar "x")) (ELit (LInt 1)))) (EApp (EVar "stringLength") (EVar "m"))) (EVar "m"))) (EVar "LocalUnstamped"))) (arm (PList) () (EVar "LocalUnstamped"))) (EApp (EApp (EVar "envLookup") (EVar "x")) (EVar "rest"))))
(DTypeSig false "stampRowOf" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "BinderRow")))))
(DFunDef false "stampRowOf" ((PVar "prog") (PVar "ord")) (EApp (EApp (EVar "omLookup") (EVar "ord")) (EFieldAccess (EVar "prog") "rows")))
(DTypeSig true "varRow" (TyFun (TyCon "WasmTypeContext") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "BinderRow"))))))
(DFunDef false "varRow" ((PVar "prog") (PVar "env") (PVar "x")) (EMatch (EApp (EApp (EVar "envLookup") (EVar "x")) (EVar "env")) (arm (PCon "LocalBinder" (PVar "ord")) () (EApp (EApp (EVar "stampRowOf") (EVar "prog")) (EVar "ord"))) (arm (PCon "LocalUnstamped") () (EVar "None")) (arm (PCon "NotLocal") () (EApp (EApp (EVar "omLookup") (EVar "x")) (EFieldAccess (EVar "prog") "tops")))))
(DTypeSig true "varStamp" (TyFun (TyCon "WasmTypeContext") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "RuntimeType")))))
(DFunDef false "varStamp" ((PVar "prog") (PVar "env") (PVar "x")) (EMatch (EApp (EApp (EApp (EVar "varRow") (EVar "prog")) (EVar "env")) (EVar "x")) (arm (PCon "Some" (PVar "row")) () (EFieldAccess (EVar "row") "brType")) (arm (PCon "None") () (EVar "RTValue"))))
(DTypeSig true "returnStamp" (TyFun (TyCon "WasmTypeContext") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "RuntimeType")))))
(DFunDef false "returnStamp" ((PVar "prog") (PVar "env") (PVar "fn")) (EMatch (EApp (EApp (EApp (EVar "varRow") (EVar "prog")) (EVar "env")) (EVar "fn")) (arm (PCon "Some" (PVar "row")) () (EApp (EApp (EVar "optionOr") (EVar "RTValue")) (EFieldAccess (EVar "row") "brReturns"))) (arm (PCon "None") () (EIf (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (EVar "fn")) (EVar "env")) (EApp (EApp (EVar "omHasKey") (EVar "fn")) (EFieldAccess (EVar "prog") "fnNames"))) (EApp (EApp (EVar "omHasKey") (EVar "fn")) (EFieldAccess (EVar "prog") "valNames"))) (EVar "RTValue") (EApp (EVar "externResultStamp") (EApp (EApp (EVar "runtimeKeyD") (EVar "prog")) (EVar "fn")))))))
(DTypeSig false "externResultStamp" (TyFun (TyCon "String") (TyCon "RuntimeType")))
(DFunDef false "externResultStamp" ((PVar "fn")) (EIf (EApp (EApp (EVar "contains") (EVar "fn")) (EListLit (ELit (LString "intToString")) (ELit (LString "charToStr")) (ELit (LString "stringConcat")) (ELit (LString "stringSlice")) (ELit (LString "stringToUpper")) (ELit (LString "stringToLower")) (ELit (LString "floatToString")) (ELit (LString "stringFromChars")) (ELit (LString "stringFromUtf8Bytes")))) (EVar "RTString") (EIf (EApp (EApp (EVar "contains") (EVar "fn")) (EListLit (ELit (LString "randomBool")) (ELit (LString "charIsAlpha")) (ELit (LString "charIsSpace")) (ELit (LString "charIsUpper")) (ELit (LString "charIsLower")) (ELit (LString "charIsPunct")))) (EVar "RTBool") (EIf (EApp (EApp (EVar "contains") (EVar "fn")) (EListLit (ELit (LString "randomChar")) (ELit (LString "charToUpper")) (ELit (LString "charToLower")))) (EVar "RTChar") (EIf (EApp (EApp (EVar "contains") (EVar "fn")) (EListLit (ELit (LString "intToFloat")) (ELit (LString "randomFloat")))) (EVar "RTFloat") (EIf (EApp (EApp (EVar "contains") (EVar "fn")) (EListLit (ELit (LString "putStr")) (ELit (LString "putStrLn")) (ELit (LString "ePutStr")) (ELit (LString "ePutStrLn")) (ELit (LString "flushStdout")))) (EVar "RTUnit") (EVar "RTValue")))))))
(DTypeSig true "cexprStamp" (TyFun (TyCon "WasmTypeContext") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CExpr") (TyCon "RuntimeType")))))
(DFunDef false "cexprStamp" (PWild PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "litRuntimeType") (EVar "l")))
(DFunDef false "cexprStamp" (PWild PWild (PCon "CVar" (PLit (LString "True")) PWild)) (EVar "RTBool"))
(DFunDef false "cexprStamp" (PWild PWild (PCon "CVar" (PLit (LString "False")) PWild)) (EVar "RTBool"))
(DFunDef false "cexprStamp" ((PVar "prog") (PVar "env") (PCon "CVar" (PVar "x") PWild)) (EIf (EBinOp "||" (EBinOp "==" (EApp (EApp (EVar "runtimeKeyD") (EVar "prog")) (EVar "x")) (ELit (LString "pi"))) (EBinOp "==" (EApp (EApp (EVar "runtimeKeyD") (EVar "prog")) (EVar "x")) (ELit (LString "e")))) (EVar "RTFloat") (EApp (EApp (EApp (EVar "varStamp") (EVar "prog")) (EVar "env")) (EVar "x"))))
(DFunDef false "cexprStamp" ((PVar "prog") (PVar "env") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") PWild)) (EIf (EApp (EVar "isCmpOp") (EVar "op")) (EVar "RTBool") (EIf (EBinOp "==" (EVar "op") (ELit (LString "::"))) (EVar "RTCon") (EIf (EApp (EVar "isArithOp") (EVar "op")) (EApp (EApp (EApp (EApp (EApp (EVar "arithStamp") (EVar "prog")) (EVar "env")) (EVar "tag")) (EVar "l")) (EVar "r")) (EApp (EApp (EVar "appendStamp") (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EVar "env")) (EVar "l"))) (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EVar "env")) (EVar "r")))))))
(DFunDef false "cexprStamp" ((PVar "prog") (PVar "env") (PCon "CUnOp" (PLit (LString "-")) (PVar "x"))) (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EVar "env")) (EVar "x")))
(DFunDef false "cexprStamp" ((PVar "prog") (PVar "env") (PCon "CIf" PWild (PVar "t") (PVar "f"))) (EApp (EApp (EVar "stampOrElse") (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EVar "env")) (EVar "t"))) (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EVar "env")) (EVar "f"))))
(DFunDef false "cexprStamp" ((PVar "prog") (PVar "env") (PCon "CLet" PWild (PVar "pat") PWild (PVar "b"))) (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EApp (EApp (EVar "envBindPat") (EVar "pat")) (EVar "env"))) (EVar "b")))
(DFunDef false "cexprStamp" ((PVar "prog") (PVar "env") (PCon "CLetGroup" (PVar "binds") (PVar "b"))) (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EApp (EApp (EVar "envBindGroups") (EVar "binds")) (EVar "env"))) (EVar "b")))
(DFunDef false "cexprStamp" ((PVar "prog") (PVar "env") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EApp (EVar "blockStamp") (EVar "prog")) (EVar "env")) (EVar "stmts")))
(DFunDef false "cexprStamp" ((PVar "prog") (PVar "env") (PCon "CDecision" PWild (PVar "arms") PWild)) (EApp (EApp (EApp (EVar "armsStamp") (EVar "prog")) (EVar "env")) (EVar "arms")))
(DFunDef false "cexprStamp" ((PVar "prog") (PVar "env") (PCon "CMatch" PWild (PVar "arms"))) (EApp (EApp (EApp (EVar "armsStamp") (EVar "prog")) (EVar "env")) (EVar "arms")))
(DFunDef false "cexprStamp" ((PVar "prog") (PVar "env") (PAs "app" (PCon "CApp" PWild PWild (PCon "CallSite" (PVar "mode") PWild)))) (EMatch (EVar "mode") (arm (PCon "CallPartial" PWild) () (EVar "RTValue")) (arm (PCon "CallOver" PWild) () (EVar "RTValue")) (arm PWild () (EMatch (EApp (EVar "appHead") (EVar "app")) (arm (PCon "CVar" (PVar "fn") PWild) () (EApp (EApp (EApp (EVar "returnStamp") (EVar "prog")) (EVar "env")) (EVar "fn"))) (arm (PCon "CDict" (PVar "fn") PWild) () (EApp (EApp (EApp (EVar "returnStamp") (EVar "prog")) (EVar "env")) (EVar "fn"))) (arm PWild () (EVar "RTValue"))))))
(DFunDef false "cexprStamp" ((PVar "prog") PWild (PCon "CFieldAccess" PWild PWild (PVar "recName") (PVar "ord"))) (EIf (EBinOp "&&" (EBinOp ">=" (EVar "ord") (ELit (LInt 0))) (EApp (EApp (EDictApp "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "ord")))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "recName")) (EFieldAccess (EVar "prog") "ctorFloatFields"))))) (EVar "RTFloat") (EVar "RTValue")))
(DFunDef false "cexprStamp" (PWild PWild PWild) (EVar "RTValue"))
(DTypeSig false "appendStamp" (TyFun (TyCon "RuntimeType") (TyFun (TyCon "RuntimeType") (TyCon "RuntimeType"))))
(DFunDef false "appendStamp" ((PCon "RTValue") (PCon "RTValue")) (EVar "RTString"))
(DFunDef false "appendStamp" ((PVar "a") (PCon "RTValue")) (EVar "a"))
(DFunDef false "appendStamp" (PWild (PVar "b")) (EVar "b"))
(DTypeSig false "arithStamp" (TyFun (TyCon "WasmTypeContext") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "CExpr") (TyFun (TyCon "CExpr") (TyCon "RuntimeType")))))))
(DFunDef false "arithStamp" ((PVar "prog") (PVar "env") (PVar "tag") (PVar "l") (PVar "r")) (EIf (EBinOp "==" (EVar "tag") (ELit (LString "Float"))) (EVar "RTFloat") (EIf (EBinOp "==" (EVar "tag") (ELit (LString "U64"))) (EVar "RTU64") (EIf (EBinOp "==" (EVar "tag") (ELit (LString "I64"))) (EVar "RTI64") (EIf (EApp (EVar "isTaggedFixedHead") (EVar "tag")) (EVar "RTInt") (EApp (EApp (EVar "stampOrElse") (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EVar "env")) (EVar "l"))) (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EVar "env")) (EVar "r"))))))))
(DTypeSig false "stampOrElse" (TyFun (TyCon "RuntimeType") (TyFun (TyCon "RuntimeType") (TyCon "RuntimeType"))))
(DFunDef false "stampOrElse" ((PCon "RTValue") (PVar "b")) (EVar "b"))
(DFunDef false "stampOrElse" ((PVar "a") PWild) (EVar "a"))
(DTypeSig true "envBindGroup" (TyFun (TyCon "CBind") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "envBindGroup" ((PCon "CBind" (PVar "name") PWild PWild (PVar "bid")) (PVar "env")) (EApp (EApp (EApp (EVar "envBind") (EVar "name")) (EVar "bid")) (EVar "env")))
(DTypeSig true "envBindGroups" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "envBindGroups" ((PVar "binds") (PVar "env")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "g")) (EApp (EApp (EVar "envBindGroup") (EVar "g")) (EVar "acc")))) (EVar "env")) (EVar "binds")))
(DTypeSig true "groupBindMark" (TyFun (TyCon "CBind") (TyCon "String")))
(DFunDef false "groupBindMark" ((PCon "CBind" (PVar "name") PWild PWild (PVar "bid"))) (EApp (EApp (EVar "envMark") (EVar "name")) (EVar "bid")))
(DTypeSig false "blockStamp" (TyFun (TyCon "WasmTypeContext") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyCon "RuntimeType")))))
(DFunDef false "blockStamp" (PWild PWild (PList)) (EVar "RTValue"))
(DFunDef false "blockStamp" ((PVar "prog") (PVar "env") (PList (PCon "CSExpr" (PVar "e")))) (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EVar "env")) (EVar "e")))
(DFunDef false "blockStamp" ((PVar "prog") (PVar "env") (PCons (PCon "CSLet" PWild (PVar "pat") PWild) (PVar "rest"))) (EApp (EApp (EApp (EVar "blockStamp") (EVar "prog")) (EApp (EApp (EVar "envBindPat") (EVar "pat")) (EVar "env"))) (EVar "rest")))
(DFunDef false "blockStamp" ((PVar "prog") (PVar "env") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EVar "blockStamp") (EVar "prog")) (EVar "env")) (EVar "rest")))
(DTypeSig false "armsStamp" (TyFun (TyCon "WasmTypeContext") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CArm")) (TyCon "RuntimeType")))))
(DFunDef false "armsStamp" (PWild PWild (PList)) (EVar "RTValue"))
(DFunDef false "armsStamp" ((PVar "prog") (PVar "env") (PCons (PCon "CArm" (PVar "pat") PWild (PVar "body")) (PVar "rest"))) (EApp (EApp (EVar "stampOrElse") (EApp (EApp (EApp (EVar "cexprStamp") (EVar "prog")) (EApp (EApp (EVar "envBindPat") (EVar "pat")) (EVar "env"))) (EVar "body"))) (EApp (EApp (EApp (EVar "armsStamp") (EVar "prog")) (EVar "env")) (EVar "rest"))))
(DTypeSig true "isPolyNumBinop" (TyFun (TyCon "WasmTypeContext") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CExpr") (TyFun (TyCon "CExpr") (TyCon "Bool"))))))
(DFunDef false "isPolyNumBinop" ((PVar "prog") (PVar "env") (PVar "l") (PVar "r")) (EBinOp "||" (EApp (EApp (EApp (EVar "isPolyNumOperand") (EVar "prog")) (EVar "env")) (EVar "l")) (EApp (EApp (EApp (EVar "isPolyNumOperand") (EVar "prog")) (EVar "env")) (EVar "r"))))
(DTypeSig false "isPolyNumOperand" (TyFun (TyCon "WasmTypeContext") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CExpr") (TyCon "Bool")))))
(DFunDef false "isPolyNumOperand" ((PVar "prog") (PVar "env") (PCon "CVar" (PVar "x") PWild)) (EMatch (EApp (EApp (EApp (EVar "varRow") (EVar "prog")) (EVar "env")) (EVar "x")) (arm (PCon "Some" (PVar "row")) () (EBinOp "==" (EFieldAccess (EVar "row") "brType") (EVar "RTValue"))) (arm (PCon "None") () (EVar "False"))))
(DFunDef false "isPolyNumOperand" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "isArithOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isArithOp" ((PVar "op")) (EApp (EApp (EVar "contains") (EVar "op")) (EListLit (ELit (LString "+")) (ELit (LString "-")) (ELit (LString "*")) (ELit (LString "/")) (ELit (LString "%")))))
(DTypeSig true "isCmpOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isCmpOp" ((PVar "op")) (EApp (EApp (EVar "contains") (EVar "op")) (EListLit (ELit (LString "==")) (ELit (LString "/=")) (ELit (LString "<")) (ELit (LString ">")) (ELit (LString "<=")) (ELit (LString ">=")))))
(DTypeSig false "appHead" (TyFun (TyCon "CExpr") (TyCon "CExpr")))
(DFunDef false "appHead" ((PCon "CApp" (PVar "f") PWild PWild)) (EApp (EVar "appHead") (EVar "f")))
(DFunDef false "appHead" ((PVar "e")) (EVar "e"))
(DData Public "WasmDemandInputs" () ((variant "WasmDemandInputs" (ConNamed (field "ctorFloatFields" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int")))) (field "lazyGlobals" (TyApp (TyCon "List") (TyCon "String"))) (field "globalInit" (TyCon "GlobalInitPlan")) (field "trmcVerdicts" (TyCon "TrmcVerdicts")) (field "dispatchGroups" (TyApp (TyCon "List") (TyCon "DispGroup")))))) ())
(DData Public "PlannedImport" () ((variant "PlannedImport" (ConNamed (field "namespace" (TyCon "String")) (field "field" (TyCon "String")) (field "watSymbol" (TyCon "String")) (field "signature" (TyCon "String"))))) ())
(DImpl true "Eq" ((TyCon "PlannedImport")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "PlannedImport" ((rf "namespace" (PVar "__a0")) (rf "field" (PVar "__a1")) (rf "watSymbol" (PVar "__a2")) (rf "signature" (PVar "__a3"))) false) (PRec "PlannedImport" ((rf "namespace" (PVar "__b0")) (rf "field" (PVar "__b1")) (rf "watSymbol" (PVar "__b2")) (rf "signature" (PVar "__b3"))) false)) () (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EMethodRef "eq") (EVar "__a2")) (EVar "__b2"))) (EApp (EApp (EMethodRef "eq") (EVar "__a3")) (EVar "__b3"))))))))
(DImpl true "Debug" ((TyCon "PlannedImport")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "PlannedImport" ((rf "namespace" (PVar "__a0")) (rf "field" (PVar "__a1")) (rf "watSymbol" (PVar "__a2")) (rf "signature" (PVar "__a3"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "PlannedImport {")) (ELit (LString " namespace = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", field = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString ", watSymbol = "))) (EApp (EMethodRef "debug") (EVar "__a2"))) (ELit (LString ", signature = "))) (EApp (EMethodRef "debug") (EVar "__a3"))) (ELit (LString " }"))))))))
(DData Public "WasmDemandPlan" () ((variant "WasmDemandPlan" (ConNamed (field "sourceDemand" (TyCon "WasmDemand")) (field "sourceHostKeys" (TyApp (TyCon "List") (TyCon "String"))) (field "jsImports" (TyApp (TyCon "List") (TyCon "JsImport"))) (field "useRef" (TyCon "Bool")) (field "useClos" (TyCon "Bool")) (field "stringOps" (TyCon "Bool")) (field "representation" (TyCon "WasmDemand")) (field "representationTypes" (TyApp (TyCon "List") (TyCon "String"))) (field "helpers" (TyApp (TyCon "List") (TyCon "String"))) (field "intHelpers" (TyApp (TyCon "List") (TyCon "String"))) (field "censusHelpers" (TyApp (TyCon "List") (TyCon "String"))) (field "censusIntHelpers" (TyApp (TyCon "List") (TyCon "String"))) (field "siteRuntime" (TyCon "Bool")) (field "nonexhaustiveRuntime" (TyCon "Bool")) (field "imports" (TyApp (TyCon "List") (TyCon "PlannedImport"))) (field "catalogFamilies" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "WasmFamily"))))))) ())
(DData Private "HelperAcc" () ((variant "HelperAcc" (ConNamed (field "helpers" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "ints" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "site" (TyCon "Bool")) (field "nonexh" (TyCon "Bool")) (field "patternTuples" (TyApp (TyCon "OrdMap") (TyCon "Int"))) (field "patternList" (TyCon "Bool")) (field "refRead" (TyCon "Bool"))))) ())
(DTypeSig false "emptyHelpers" (TyCon "HelperAcc"))
(DFunDef false "emptyHelpers" () (ERecordCreate "HelperAcc" ((fa "helpers" (EVar "omEmpty")) (fa "ints" (EVar "omEmpty")) (fa "site" (EVar "False")) (fa "nonexh" (EVar "False")) (fa "patternTuples" (EVar "omEmpty")) (fa "patternList" (EVar "False")) (fa "refRead" (EVar "False")))))
(DTypeSig false "need" (TyFun (TyCon "HelperAcc") (TyFun (TyCon "String") (TyCon "HelperAcc"))))
(DFunDef false "need" ((PVar "acc") (PVar "name")) (ERecordUpdate (EVar "acc") ((fa "helpers" (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EFieldAccess (EVar "acc") "helpers"))))))
(DTypeSig false "needMany" (TyFun (TyCon "HelperAcc") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "HelperAcc"))))
(DFunDef false "needMany" () (EApp (EMethodRef "fold") (EVar "need")))
(DTypeSig false "needTrap" (TyFun (TyCon "HelperAcc") (TyCon "HelperAcc")))
(DFunDef false "needTrap" ((PVar "acc")) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "stderrByteImportLines"))))
(DTypeSig false "needSite" (TyFun (TyCon "HelperAcc") (TyCon "HelperAcc")))
(DFunDef false "needSite" ((PVar "acc")) (ERecordUpdate (EApp (EApp (EVar "needMany") (EVar "acc")) (EListLit (ELit (LString "siteRuntimeLines")) (ELit (LString "trapIntRuntimeLines")) (ELit (LString "stderrByteImportLines")))) ((fa "site" (EVar "True")))))
(DTypeSig false "needInt" (TyFun (TyCon "HelperAcc") (TyFun (TyCon "String") (TyCon "HelperAcc"))))
(DFunDef false "needInt" ((PVar "acc") (PVar "name")) (ERecordUpdate (EApp (EVar "needSite") (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "intRuntimeLines")))) ((fa "ints" (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EFieldAccess (EVar "acc") "ints"))))))
(DTypeSig true "wasmFamilyTag" (TyFun (TyCon "WasmFamily") (TyCon "String")))
(DFunDef false "wasmFamilyTag" ((PCon "WasmStr")) (ELit (LString "str")))
(DFunDef false "wasmFamilyTag" ((PCon "WasmLeaf")) (ELit (LString "leaf")))
(DFunDef false "wasmFamilyTag" ((PCon "WasmArray")) (ELit (LString "array")))
(DFunDef false "wasmFamilyTag" ((PCon "WasmByteBlock")) (ELit (LString "bytes")))
(DFunDef false "wasmFamilyTag" ((PCon "WasmRefCell")) (ELit (LString "ref")))
(DFunDef false "wasmFamilyTag" ((PCon "WasmConstant")) (ELit (LString "constant")))
(DFunDef false "wasmFamilyTag" ((PCon "WasmFallthrough")) (ELit (LString "fallthrough")))
(DTypeSig false "catalogFamilies" (TyFun (TyCon "ExternRequirements") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "WasmFamily")))))
(DFunDef false "catalogFamilies" ((PVar "req")) (EApp (EApp (EMethodRef "filterMap") (ELam ((PVar "row")) (EMatch (EFieldAccess (EVar "row") "selectedBinding") (arm (PCon "RuntimeRequirement" (PVar "key")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "family")) (ETuple (EVar "key") (EVar "family")))) (EApp (EVar "wasmFamily") (EVar "key")))) (arm PWild () (EVar "None"))))) (EFieldAccess (EVar "req") "rows")))
(DTypeSig true "planWasmDemand" (TyFun (TyCon "WasmDemandInputs") (TyFun (TyCon "CProgram") (TyFun (TyCon "ExternRequirements") (TyCon "WasmDemandPlan")))))
(DFunDef false "planWasmDemand" ((PVar "inputs") (PAs "cp" (PCon "CProgram" (PVar "groups") (PVar "ctorArs") PWild (PVar "impls") PWild (PVar "facts"))) (PVar "req")) (EBlock (DoLet false false (PTuple (PVar "source") (PVar "hostKeys") PWild) (EApp (EApp (EApp (EApp (EVar "wasmDemandOf") (EApp (EVar "requirementFacts") (EVar "req"))) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EVar "requirementHostRows") (EVar "req")))) (EVar "omEmpty"))) (EVar "groups")) (EVar "impls"))) (DoLet false false (PVar "js") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "symbol") (PTuple (PVar "host") (PTuple (PVar "params") (PVar "result"))))) (ERecordCreate "JsImport" ((fa "medakaName" (EVar "symbol")) (fa "jsName" (EVar "host")) (fa "params" (EVar "params")) (fa "result" (EVar "result")))))) (EApp (EVar "requirementHostRows") (EVar "req")))) (DoLet false false (PVar "str") (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "programUsesStr") (EFieldAccess (EVar "facts") "factExterns")) (EVar "groups")) (EApp (EApp (EVar "hasUse") (EVar "source")) (EVar "UseStr"))) (EApp (EApp (EVar "hasUse") (EVar "source")) (EVar "UseFloat")))) (DoLet false false (PVar "ctx") (EApp (EApp (EVar "wasmTypeContext") (EFieldAccess (EVar "inputs") "ctorFloatFields")) (EVar "cp"))) (DoLet false false (PVar "clos") (EApp (EApp (EVar "anyBind") (EApp (EApp (EVar "bindUsesClosures") (EFieldAccess (EVar "ctx") "fnNames")) (EVar "ctorArs"))) (EVar "groups"))) (DoLet false false (PVar "refMode") (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "isNonEmptyL") (EFieldAccess (EVar "inputs") "lazyGlobals")) (EVar "clos")) (EApp (EApp (EVar "programUsesAdt") (EVar "groups")) (EVar "ctorArs"))) (EApp (EVar "isNonEmptyL") (EVar "impls"))) (EVar "str")) (EFieldAccess (EVar "source") "refBox")) (EApp (EVar "isNonEmptyL") (EFieldAccess (EVar "source") "tupleArities"))) (EApp (EApp (EDictApp "any") (EApp (EVar "hasUse") (EVar "source"))) (EListLit (EVar "UseList") (EVar "UseArray") (EVar "UseRng") (EVar "UseHash") (EVar "UseFloat") (EVar "UseU64") (EVar "UseI64") (EVar "UseStrSearch") (EVar "UseCharClass")))) (EApp (EVar "isNonEmptyL") (EVar "hostKeys"))) (EApp (EVar "isNonEmptyL") (EVar "js")))) (DoLet false false (PVar "roots") (EApp (EApp (EVar "need") (EVar "emptyHelpers")) (ELit (LString "ioRuntimeLines")))) (DoLet false false (PVar "roots") (EIf (EVar "refMode") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "sourceRoots") (EVar "source")) (EVar "str")) (EVar "clos")) (EVar "hostKeys")) (EVar "js")) (EVar "roots")) (EVar "roots"))) (DoLet false false (PVar "roots") (EApp (EApp (EApp (EMethodRef "fold") (EApp (EApp (EApp (EVar "hBind") (EVar "ctx")) (EVar "refMode")) (EVar "str"))) (EVar "roots")) (EVar "groups"))) (DoLet false false (PVar "roots") (EApp (EApp (EApp (EMethodRef "fold") (EApp (EApp (EApp (EVar "hImpl") (EVar "ctx")) (EVar "refMode")) (EVar "str"))) (EVar "roots")) (EVar "impls"))) (DoLet false false (PVar "roots") (EIf (EVar "refMode") (EApp (EApp (EVar "implFailureRoots") (EVar "roots")) (EVar "impls")) (EVar "roots"))) (DoLet false false (PVar "roots") (EIf (EBinOp "&&" (EVar "refMode") (EApp (EVar "isNonEmptyL") (EFieldAccess (EVar "inputs") "lazyGlobals"))) (EApp (EVar "needTrap") (EVar "roots")) (EVar "roots"))) (DoLet false false (PVar "roots") (EIf (EVar "refMode") (EApp (EApp (EApp (EApp (EVar "printRoots") (EVar "ctx")) (EFieldAccess (EVar "facts") "factEntryOutcome")) (EVar "groups")) (EVar "roots")) (EVar "roots"))) (DoLet false false (PVar "families") (EApp (EVar "catalogFamilies") (EVar "req"))) (DoLet false false (PVar "closed") (EApp (EApp (EVar "closeHelpers") (EApp (EApp (EVar "hasUse") (EVar "source")) (EVar "UseI64"))) (EVar "roots"))) (DoLet false false (PVar "census") (EIf (EVar "refMode") (EVar "closed") (EApp (EApp (EVar "closeHelpers") (EApp (EApp (EVar "hasUse") (EVar "source")) (EVar "UseI64"))) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EApp (EApp (EVar "hImpl") (EVar "ctx")) (EVar "True")) (EVar "str"))) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EApp (EApp (EVar "hBind") (EVar "ctx")) (EVar "True")) (EVar "str"))) (EVar "closed")) (EVar "groups"))) (EVar "impls"))))) (DoLet false false (PVar "renderClos") (EBinOp "||" (EVar "clos") (EApp (EApp (EVar "omHasKey") (ELit (LString "closApplyLines"))) (EFieldAccess (EVar "closed") "helpers")))) (DoLet false false (PVar "representation") (EApp (EApp (EApp (EVar "representationOf") (EVar "source")) (EVar "str")) (EVar "closed"))) (DoLet false false (PVar "imports") (EApp (EApp (EApp (EVar "physicalImports") (EVar "closed")) (EVar "hostKeys")) (EVar "js"))) (DoExpr (ERecordCreate "WasmDemandPlan" ((fa "sourceDemand" (EVar "source")) (fa "sourceHostKeys" (EVar "hostKeys")) (fa "jsImports" (EVar "js")) (fa "useRef" (EVar "refMode")) (fa "useClos" (EVar "renderClos")) (fa "stringOps" (EVar "str")) (fa "representation" (EVar "representation")) (fa "representationTypes" (EApp (EApp (EApp (EApp (EVar "physicalTypes") (EVar "cp")) (EVar "refMode")) (EVar "renderClos")) (EVar "representation"))) (fa "helpers" (EApp (EVar "omKeys") (EFieldAccess (EVar "closed") "helpers"))) (fa "intHelpers" (EApp (EVar "omKeys") (EFieldAccess (EVar "closed") "ints"))) (fa "censusHelpers" (EApp (EVar "omKeys") (EFieldAccess (EVar "census") "helpers"))) (fa "censusIntHelpers" (EApp (EVar "omKeys") (EFieldAccess (EVar "census") "ints"))) (fa "siteRuntime" (EFieldAccess (EVar "closed") "site")) (fa "nonexhaustiveRuntime" (EFieldAccess (EVar "closed") "nonexh")) (fa "imports" (EVar "imports")) (fa "catalogFamilies" (EVar "families")))))))
(DTypeSig false "hasUse" (TyFun (TyCon "WasmDemand") (TyFun (TyCon "WasmUse") (TyCon "Bool"))))
(DFunDef false "hasUse" ((PVar "demand") (PVar "u")) (EApp (EApp (EDictApp "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "u")))) (EFieldAccess (EVar "demand") "uses")))
(DTypeSig false "sourceRoots" (TyFun (TyCon "WasmDemand") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "JsImport")) (TyFun (TyCon "HelperAcc") (TyCon "HelperAcc"))))))))
(DFunDef false "sourceRoots" ((PVar "source") (PVar "str") (PVar "clos") (PVar "keys") (PVar "js") (PVar "acc")) (EBlock (DoLet false false (PVar "acc") (EIf (EVar "clos") (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "closApplyLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EVar "str") (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "ioStrRuntimeLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PTuple (PVar "u") (PVar "block"))) (EIf (EApp (EApp (EVar "hasUse") (EVar "source")) (EVar "u")) (EApp (EApp (EVar "need") (EVar "a")) (EVar "block")) (EVar "a")))) (EVar "acc")) (EListLit (ETuple (EVar "UseStrLeaf") (ELit (LString "strLeafRuntimeLines"))) (ETuple (EVar "UseRng") (ELit (LString "rngRuntimeLines"))) (ETuple (EVar "UseHash") (ELit (LString "hashRuntimeLines"))) (ETuple (EVar "UseFloatHash") (ELit (LString "hashFloatRuntimeLines"))) (ETuple (EVar "UseFloatRng") (ELit (LString "randomFloatRuntimeLines"))) (ETuple (EVar "UseFloat") (ELit (LString "floatRuntimeLines"))) (ETuple (EVar "UseU64") (ELit (LString "u64RuntimeLines"))) (ETuple (EVar "UseI64") (ELit (LString "i64RuntimeLines"))) (ETuple (EVar "UseStrSearch") (ELit (LString "strSearchRuntimeLines"))) (ETuple (EVar "UseStrToInt") (ELit (LString "strToIntRuntimeLines"))) (ETuple (EVar "UseStrReverse") (ELit (LString "strReverseRuntimeLines"))) (ETuple (EVar "UseStrJoin") (ELit (LString "strJoinRuntimeLines"))) (ETuple (EVar "UseStrCodec") (ELit (LString "strCodecRuntimeLines"))) (ETuple (EVar "UseByteBlock") (ELit (LString "byteBlockRuntimeLines"))) (ETuple (EVar "UseCharFromCode") (ELit (LString "charFromCodeRuntimeLines"))) (ETuple (EVar "UseCharClass") (ELit (LString "charClassRuntimeLines"))) (ETuple (EVar "UseEPut") (ELit (LString "stderrRuntimeLines")))))) (DoLet false false (PVar "acc") (EIf (EBinOp "&&" (EApp (EApp (EVar "hasUse") (EVar "source")) (EVar "UseStrLeaf")) (EApp (EApp (EVar "hasUse") (EVar "source")) (EVar "UseList"))) (EApp (EApp (EVar "needMany") (EVar "acc")) (EListLit (ELit (LString "strConcatRuntimeLines")) (ELit (LString "appendRuntimeLines")))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EBinOp "&&" (EApp (EApp (EVar "hasUse") (EVar "source")) (EVar "UseHash")) (EVar "str")) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "hashStringRuntimeLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EApp (EApp (EVar "hasUse") (EVar "source")) (EVar "UseFloat")) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "floatRemRuntimeLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PTuple (PVar "key") (PVar "block"))) (EIf (EApp (EApp (EVar "contains") (EVar "key")) (EVar "keys")) (EApp (EApp (EVar "need") (EVar "a")) (EVar "block")) (EVar "a")))) (EVar "acc")) (EVar "hostHelperRoots"))) (DoLet false false (PVar "acc") (EIf (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "contains") (ELit (LString "mdk_file_exists"))) (EVar "keys")) (EApp (EApp (EVar "contains") (ELit (LString "mdk_canonicalize_path"))) (EVar "keys"))) (EApp (EApp (EVar "contains") (ELit (LString "mdk_os_entropy"))) (EVar "keys"))) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "ioRefusedPanicLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EApp (EApp (EVar "contains") (ELit (LString "mdk_os_entropy"))) (EVar "keys")) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "osEntropyLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EBinOp "&&" (EApp (EApp (EVar "contains") (ELit (LString "mdk_read_file"))) (EVar "keys")) (EApp (EApp (EVar "hasUse") (EVar "source")) (EVar "UseFileBytes"))) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "readFileBytesLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EApp (EApp (EVar "contains") (ELit (LString "mdk_write_file_commit"))) (EVar "keys")) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "writeFileBytesLines"))) (EVar "acc"))) (DoLet false false (PVar "heads") (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "imp")) (EFieldAccess (EVar "imp") "params"))) (EVar "js"))) (DoLet false false (PVar "acc") (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "h")) (EBinOp "||" (EBinOp "==" (EVar "h") (ELit (LString "String"))) (EBinOp "==" (EVar "h") (ELit (LString "Array")))))) (EVar "heads")) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "ioPushPathMoreLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EApp (EApp (EVar "contains") (ELit (LString "Array"))) (EVar "heads")) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "jsffiArrayLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "imp")) (EBinOp "==" (EFieldAccess (EVar "imp") "result") (ELit (LString "String"))))) (EVar "js")) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "jsffiResultStrLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "imp")) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EFieldAccess (EVar "imp") "result") (ELit (LString "Int"))) (EBinOp "==" (EFieldAccess (EVar "imp") "result") (ELit (LString "Char")))) (EApp (EApp (EVar "contains") (ELit (LString "Array"))) (EFieldAccess (EVar "imp") "params"))))) (EVar "js")) (EApp (EVar "needTrap") (EVar "acc")) (EVar "acc"))) (DoExpr (EIf (EApp (EApp (EVar "contains") (ELit (LString "mdk_write_err_byte"))) (EVar "keys")) (EApp (EVar "needTrap") (EVar "acc")) (EVar "acc")))))
(DTypeSig false "hostHelperRoots" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "hostHelperRoots" () (EListLit (ETuple (ELit (LString "mdk_path_push")) (ELit (LString "ioPushPathLines"))) (ETuple (ELit (LString "mdk_rename")) (ELit (LString "ioPushPathMoreLines"))) (ETuple (ELit (LString "mdk_grant_push")) (ELit (LString "ioPushGrantLines"))) (ETuple (ELit (LString "mdk_rename")) (ELit (LString "ioPushGrantMoreLines"))) (ETuple (ELit (LString "mdk_result_len")) (ELit (LString "ioResultLines"))) (ETuple (ELit (LString "mdk_read_file")) (ELit (LString "ioReadFileLines"))) (ETuple (ELit (LString "mdk_fetch_text")) (ELit (LString "ioFetchTextLines"))) (ETuple (ELit (LString "mdk_file_exists")) (ELit (LString "ioFileExistsLines"))) (ETuple (ELit (LString "mdk_canonicalize_path")) (ELit (LString "ioCanonicalizeLines"))) (ETuple (ELit (LString "mdk_write_file")) (ELit (LString "ioWriteFileLines"))) (ETuple (ELit (LString "mdk_append_file")) (ELit (LString "ioAppendFileLines"))) (ETuple (ELit (LString "mdk_rename")) (ELit (LString "ioRenameLines"))) (ETuple (ELit (LString "mdk_list_dir")) (ELit (LString "ioListDirLines"))) (ETuple (ELit (LString "mdk_stat_file")) (ELit (LString "ioStatFileLines"))) (ETuple (ELit (LString "mdk_make_dir")) (ELit (LString "ioMakeDirLines"))) (ETuple (ELit (LString "mdk_remove_file")) (ELit (LString "ioRemoveFileLines"))) (ETuple (ELit (LString "mdk_remove_dir")) (ELit (LString "ioRemoveDirLines"))) (ETuple (ELit (LString "mdk_fsync")) (ELit (LString "ioFsyncLines"))) (ETuple (ELit (LString "mdk_file_mode")) (ELit (LString "ioFileModeLines"))) (ETuple (ELit (LString "mdk_write_file_mode")) (ELit (LString "ioWriteFileModeLines"))) (ETuple (ELit (LString "mdk_get_env")) (ELit (LString "ioGetEnvLines"))) (ETuple (ELit (LString "mdk_read_line")) (ELit (LString "ioReadLineLines"))) (ETuple (ELit (LString "mdk_read_all")) (ELit (LString "ioReadAllLines"))) (ETuple (ELit (LString "mdk_read_exactly")) (ELit (LString "ioReadExactlyLines"))) (ETuple (ELit (LString "mdk_executable_path")) (ELit (LString "ioExecutablePathLines"))) (ETuple (ELit (LString "mdk_args_count")) (ELit (LString "ioArgsLines"))) (ETuple (ELit (LString "mdk_str_to_float")) (ELit (LString "floatStrLines")))))
(DTypeSig true "hasWasmHelper" (TyFun (TyCon "WasmDemandPlan") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "hasWasmHelper" ((PVar "plan") (PVar "name")) (EApp (EApp (EVar "contains") (EVar "name")) (EFieldAccess (EVar "plan") "helpers")))
(DTypeSig true "censusWasmDemand" (TyFun (TyCon "WasmDemandPlan") (TyCon "WasmDemandPlan")))
(DFunDef false "censusWasmDemand" ((PVar "plan")) (ERecordUpdate (EVar "plan") ((fa "helpers" (EFieldAccess (EVar "plan") "censusHelpers")) (fa "intHelpers" (EFieldAccess (EVar "plan") "censusIntHelpers")))))
(DTypeSig true "selectWasmBin" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyFun (TyCon "CExpr") (TyFun (TyCon "CExpr") (TyFun (TyCon "String") (TyCon "String")))))))))
(DFunDef false "selectWasmBin" ((PVar "ctx") (PVar "str") (PVar "env") (PVar "op") (PVar "l") (PVar "r") (PVar "tag")) (EIf (EBinOp "&&" (EApp (EVar "isArithOp") (EVar "op")) (EApp (EVar "isTaggedFixedHead") (EVar "tag"))) (ELit (LString "int-fixed")) (EIf (EBinOp "&&" (EBinOp "||" (EApp (EVar "isArithOp") (EVar "op")) (EApp (EVar "isCmpOp") (EVar "op"))) (EBinOp "==" (EVar "tag") (ELit (LString "U64")))) (ELit (LString "u64")) (EIf (EBinOp "&&" (EBinOp "||" (EApp (EVar "isArithOp") (EVar "op")) (EApp (EVar "isCmpOp") (EVar "op"))) (EBinOp "==" (EVar "tag") (ELit (LString "I64")))) (ELit (LString "i64")) (EIf (EBinOp "&&" (EBinOp "||" (EApp (EVar "isArithOp") (EVar "op")) (EApp (EVar "isCmpOp") (EVar "op"))) (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "tag") (ELit (LString "Float"))) (EBinOp "==" (EApp (EApp (EApp (EVar "cexprStamp") (EVar "ctx")) (EVar "env")) (EVar "l")) (EVar "RTFloat"))) (EBinOp "==" (EApp (EApp (EApp (EVar "cexprStamp") (EVar "ctx")) (EVar "env")) (EVar "r")) (EVar "RTFloat")))) (ELit (LString "float")) (EIf (EBinOp "&&" (EApp (EVar "isCmpOp") (EVar "op")) (EVar "str")) (ELit (LString "compare")) (EIf (EBinOp "&&" (EApp (EVar "isCmpOp") (EVar "op")) (EApp (EApp (EApp (EApp (EVar "isPolyNumBinop") (EVar "ctx")) (EVar "env")) (EVar "l")) (EVar "r"))) (ELit (LString "compare-number")) (EIf (EBinOp "&&" (EApp (EVar "isArithOp") (EVar "op")) (EApp (EApp (EApp (EApp (EVar "isPolyNumBinop") (EVar "ctx")) (EVar "env")) (EVar "l")) (EVar "r"))) (EBinOp "++" (ELit (LString "value-")) (EVar "op")) (ELit (LString "int"))))))))))
(DTypeSig false "hBind" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyFun (TyCon "CBind") (TyCon "HelperAcc")))))))
(DFunDef false "hBind" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PCon "CBind" (PVar "name") (PVar "clauses") (PVar "loc") PWild)) (EBlock (DoLet false false (PVar "acc") (EIf (EBinOp "&&" (EBinOp "&&" (EVar "refMode") (EBinOp "/=" (EVar "name") (ELit (LString "main")))) (EBinOp "||" (EApp (EVar "multiOrPatternClauses") (EVar "clauses")) (EApp (EApp (EDictApp "any") (ELam ((PVar "c")) (EApp (EVar "exprHasFallthrough") (EApp (EVar "clauseBodyOf") (EVar "c"))))) (EVar "clauses")))) (EApp (EApp (EVar "locatedNonexh") (EVar "acc")) (EVar "loc")) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (EApp (EApp (EApp (EVar "hClause") (EVar "ctx")) (EVar "refMode")) (EVar "str"))) (EVar "acc")) (EVar "clauses")))))
(DTypeSig false "hClause" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyFun (TyCon "CClause") (TyCon "HelperAcc")))))))
(DFunDef false "hClause" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "hPat") (EVar "refMode"))) (EVar "acc")) (EVar "pats"))) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "flip") (EVar "envBindPat"))) (EListLit)) (EVar "pats"))) (EVar "body")))
(DTypeSig false "hImpl" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyFun (TyCon "CImplEntry") (TyCon "HelperAcc")))))))
(DFunDef false "hImpl" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PCon "CImplEntry" PWild PWild PWild (PVar "body"))) (EMatch (EVar "body") (arm (PCon "CImplTagged" PWild PWild PWild PWild PWild (PVar "pats") (PVar "b")) () (EApp (EApp (EApp (EApp (EApp (EVar "hClause") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EApp (EApp (EVar "CClause") (EVar "pats")) (EVar "b")))) (arm (PCon "CImplDefault" PWild PWild PWild PWild PWild (PVar "pats") (PVar "b")) () (EApp (EApp (EApp (EApp (EApp (EVar "hClause") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EApp (EApp (EVar "CClause") (EVar "pats")) (EVar "b"))))))
(DTypeSig false "implFailureRoots" (TyFun (TyCon "HelperAcc") (TyFun (TyApp (TyCon "List") (TyCon "CImplEntry")) (TyCon "HelperAcc"))))
(DFunDef false "implFailureRoots" ((PVar "acc") (PVar "entries")) (EBlock (DoLet false false (PVar "groups") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "index") (PCon "CImplEntry" (PVar "method") PWild PWild (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "key") (PVar "clause")) (EMatch (EVar "body") (arm (PCon "CImplTagged" PWild (PVar "key") PWild PWild PWild (PVar "pats") (PVar "b")) () (ETuple (EVar "key") (EApp (EApp (EVar "CClause") (EVar "pats")) (EVar "b")))) (arm (PCon "CImplDefault" PWild PWild (PVar "key") PWild PWild (PVar "pats") (PVar "b")) () (ETuple (EVar "key") (EApp (EApp (EVar "CClause") (EVar "pats")) (EVar "b")))))) (DoLet false false (PVar "groupKey") (EBinOp "++" (EApp (EVar "lenKey") (EVar "method")) (EVar "key"))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EVar "groupKey")) (EBinOp "::" (EVar "clause") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "groupKey")) (EMethodRef "index"))))) (EMethodRef "index")))))) (EVar "omEmpty")) (EVar "entries"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PVar "key")) (EBlock (DoLet false false (PVar "clauses") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "key")) (EVar "groups")))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "multiOrPatternClauses") (EVar "clauses")) (EApp (EApp (EDictApp "any") (ELam ((PVar "c")) (EApp (EVar "exprHasFallthrough") (EApp (EVar "clauseBodyOf") (EVar "c"))))) (EVar "clauses"))) (EApp (EVar "needTrap") (EVar "a")) (EVar "a")))))) (EVar "acc")) (EApp (EVar "omKeys") (EVar "groups"))))))
(DTypeSig false "localFunctionRoots" (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "CExpr") (TyCon "HelperAcc"))))))
(DFunDef false "localFunctionRoots" ((PVar "refMode") (PVar "acc") (PVar "pats") (PVar "body")) (EIf (EBinOp "&&" (EVar "refMode") (EBinOp "||" (EApp (EVar "multiOrPatternClauses") (EListLit (EApp (EApp (EVar "CClause") (EVar "pats")) (EVar "body")))) (EApp (EVar "exprHasFallthrough") (EVar "body")))) (EApp (EVar "needTrap") (EVar "acc")) (EVar "acc")))
(DTypeSig false "hPat" (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyFun (TyCon "Pat") (TyCon "HelperAcc")))))
(DFunDef false "hPat" ((PCon "True") (PVar "acc") (PCon "PLit" (PCon "LString" PWild))) (EApp (EApp (EVar "needMany") (EVar "acc")) (EListLit (ELit (LString "strSearchRuntimeLines")) (ELit (LString "strLeafRuntimeLines")) (ELit (LString "ioStrRuntimeLines")))))
(DFunDef false "hPat" ((PVar "refMode") (PVar "acc") (PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "hPat") (EVar "refMode"))) (EVar "acc")) (EVar "ps")))
(DFunDef false "hPat" ((PVar "refMode") (PVar "acc") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "hPat") (EVar "refMode"))) (ERecordUpdate (EVar "acc") ((fa "patternTuples" (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "intToString") (EApp (EVar "listLen") (EVar "ps")))) (EApp (EVar "listLen") (EVar "ps"))) (EFieldAccess (EVar "acc") "patternTuples")))))) (EVar "ps")))
(DFunDef false "hPat" ((PVar "refMode") (PVar "acc") (PCon "PList" (PVar "ps"))) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "hPat") (EVar "refMode"))) (ERecordUpdate (EVar "acc") ((fa "patternList" (EVar "True"))))) (EVar "ps")))
(DFunDef false "hPat" ((PVar "refMode") (PVar "acc") (PCon "PCons" (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "hPat") (EVar "refMode")) (EApp (EApp (EApp (EVar "hPat") (EVar "refMode")) (ERecordUpdate (EVar "acc") ((fa "patternList" (EVar "True"))))) (EVar "a"))) (EVar "b")))
(DFunDef false "hPat" ((PVar "refMode") (PVar "acc") (PCon "PAs" PWild PWild PWild (PVar "p"))) (EApp (EApp (EApp (EVar "hPat") (EVar "refMode")) (EVar "acc")) (EVar "p")))
(DFunDef false "hPat" (PWild (PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "hExpr" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "CExpr") (TyCon "HelperAcc"))))))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") PWild)) (EBlock (DoLet false false (PVar "branch") (EIf (EVar "refMode") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "selectWasmBin") (EVar "ctx")) (EVar "str")) (EVar "env")) (EVar "op")) (EVar "l")) (EVar "r")) (EVar "tag")) (ELit (LString "int")))) (DoLet false false (PVar "acc") (EIf (EBinOp "==" (EVar "branch") (ELit (LString "compare"))) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "valueEqRuntimeLines"))) (EIf (EBinOp "==" (EVar "branch") (ELit (LString "compare-number"))) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "valueCmpNumRuntimeLines"))) (EVar "acc")))) (DoLet false false (PVar "acc") (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "value-"))) (EVar "branch")) (EApp (EApp (EVar "need") (EVar "acc")) (EBinOp "++" (EBinOp "++" (ELit (LString "value")) (EApp (EVar "valueOpBlock") (EVar "op"))) (ELit (LString "RuntimeLines")))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "&&" (EBinOp "==" (EVar "branch") (ELit (LString "int"))) (EApp (EVar "not") (EApp (EVar "isTaggedFixedHead") (EVar "tag")))) (EApp (EApp (EVar "startsWith") (ELit (LString "value-"))) (EVar "branch"))) (EApp (EApp (EVar "contains") (EVar "op")) (EListLit (ELit (LString "+")) (ELit (LString "-")) (ELit (LString "*")) (ELit (LString "/"))))) (EApp (EApp (EVar "needInt") (EVar "acc")) (EApp (EVar "intOpName") (EVar "op"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EIf (EBinOp "&&" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "/"))) (EBinOp "==" (EVar "op") (ELit (LString "%")))) (EBinOp "/=" (EVar "branch") (ELit (LString "float")))) (EApp (EVar "needTrap") (EVar "acc")) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "l"))) (EVar "env")) (EVar "r")))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CUnOp" (PLit (LString "-")) (PVar "x"))) (EBlock (DoLet false false (PVar "acc") (EIf (EBinOp "&&" (EVar "refMode") (EBinOp "==" (EApp (EApp (EApp (EVar "cexprStamp") (EVar "ctx")) (EVar "env")) (EVar "x")) (EVar "RTFloat"))) (EVar "acc") (EApp (EApp (EVar "needInt") (EVar "acc")) (ELit (LString "neg"))))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "x")))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PAs "app" (PCon "CApp" (PVar "f") (PVar "args") PWild))) (EBlock (DoLet false false (PVar "acc") (EIf (EBinOp "&&" (EVar "refMode") (EApp (EApp (EApp (EApp (EVar "appUsesClosures") (EFieldAccess (EVar "ctx") "fnNames")) (EFieldAccess (EVar "ctx") "ctorArities")) (EVar "env")) (EVar "app"))) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "closApplyLines"))) (EVar "acc"))) (DoLet false false (PVar "acc") (EMatch (EVar "f") (arm (PCon "CVar" (PVar "name") PWild) () (EApp (EApp (EApp (EApp (EVar "runtimeRoots") (EVar "ctx")) (EVar "acc")) (EVar "name")) (EVar "args"))) (arm PWild () (EVar "acc")))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PVar "x")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "x")))) (EMatch (EVar "f") (arm (PCon "CVar" PWild PWild) () (EVar "acc")) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "f"))))) (EVar "args")))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CVar" (PVar "name") PWild)) (EBlock (DoLet false false (PVar "acc") (EIf (EBinOp "&&" (EBinOp "&&" (EVar "refMode") (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "name")) (EVar "env")))) (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "ctx") "fnNames")) (EApp (EApp (EVar "externNeedsClosure") (EVar "ctx")) (EVar "name")))) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "closApplyLines"))) (EVar "acc"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "runtimeRoots") (EVar "ctx")) (EVar "acc")) (EVar "name")) (EListLit)))))
(DFunDef false "hExpr" (PWild (PCon "True") PWild (PVar "acc") PWild (PCon "CMethod" PWild PWild)) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "closApplyLines"))))
(DFunDef false "hExpr" (PWild (PCon "True") PWild (PVar "acc") PWild (PCon "CDict" PWild PWild)) (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "closApplyLines"))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CLam" (PVar "pats") (PVar "b"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "hPat") (EVar "refMode"))) (EIf (EVar "refMode") (EApp (EApp (EVar "need") (EVar "acc")) (ELit (LString "closApplyLines"))) (EVar "acc"))) (EVar "pats"))) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "flip") (EVar "envBindPat"))) (EVar "env")) (EVar "pats"))) (EVar "b")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PVar "x")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "x")))) (EVar "acc")) (EListLit (EVar "c") (EVar "t") (EVar "f"))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CLet" (PVar "recFlag") (PVar "pat") (PVar "a") (PVar "b"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "envBindPat") (EVar "pat")) (EVar "env"))) (DoLet false false (PVar "acc") (EMatch (ETuple (EVar "recFlag") (EVar "pat") (EVar "a")) (arm (PTuple (PCon "True") (PCon "PVar" PWild PWild PWild) (PCon "CLam" (PVar "pats") (PVar "body"))) () (EApp (EApp (EApp (EApp (EVar "localFunctionRoots") (EVar "refMode")) (EVar "acc")) (EVar "pats")) (EVar "body"))) (arm PWild () (EVar "acc")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EVar "hPat") (EVar "refMode")) (EVar "acc")) (EVar "pat"))) (EIf (EVar "recFlag") (EVar "inner") (EVar "env"))) (EVar "a"))) (EVar "inner")) (EVar "b")))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CLetGroup" (PVar "binds") (PVar "b"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "envBindGroups") (EVar "binds")) (EVar "env"))) (DoLet false false (PVar "acc") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PCon "CBind" PWild (PVar "cs") (PVar "loc") (PVar "bid"))) (EApp (EApp (EApp (EApp (EApp (EVar "hBind") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EApp (EApp (EApp (EApp (EVar "CBind") (ELit (LString "$local"))) (EVar "cs")) (EVar "loc")) (EVar "bid"))))) (EVar "acc")) (EVar "binds"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "inner")) (EVar "b")))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hStmts") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "stmts")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EVar "hTree") (EVar "refMode")) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EApp (EApp (EApp (EVar "hArm") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "env"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "scrut"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EApp (EApp (EApp (EVar "hArm") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "env"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "scrut"))) (EVar "arms")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EIf (EVar "refMode") (EApp (EVar "needTrap") (EVar "acc")) (EVar "acc"))) (EVar "env")) (EVar "a"))) (EVar "env")) (EVar "i")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CSlice" (PVar "a") (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PVar "x")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "x")))) (EIf (EVar "refMode") (EApp (EVar "needTrap") (EVar "acc")) (EVar "acc"))) (EListLit (EVar "a") (EVar "lo") (EVar "hi"))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CTuple" (PVar "xs"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PVar "x")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "x")))) (EVar "acc")) (EVar "xs")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CList" (PVar "xs"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PVar "x")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "x")))) (EVar "acc")) (EVar "xs")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CArray" (PVar "xs"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PVar "x")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "x")))) (EVar "acc")) (EVar "xs")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PVar "x")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "x")))) (EVar "acc")) (EListLit (EVar "lo") (EVar "hi"))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PVar "x")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "x")))) (EVar "acc")) (EListLit (EVar "lo") (EVar "hi"))))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CRecord" PWild (PVar "fs"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PCon "CField" PWild PWild (PVar "x"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "x")))) (EVar "acc")) (EVar "fs")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CFieldAccess" (PVar "x") (PLit (LString "value")) PWild PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (ERecordUpdate (EVar "acc") ((fa "refRead" (EVar "True"))))) (EVar "env")) (EVar "x")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CFieldAccess" (PVar "x") PWild PWild PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "x")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CRecordUpdate" PWild (PVar "x") (PVar "fs"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PCon "CField" PWild PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "e")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "x"))) (EVar "fs")))
(DFunDef false "hExpr" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCon "CVariantUpdate" PWild (PVar "x") (PVar "fs"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PCon "CField" PWild PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "env")) (EVar "e")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "x"))) (EVar "fs")))
(DFunDef false "hExpr" (PWild PWild PWild (PVar "acc") PWild PWild) (EVar "acc"))
(DTypeSig false "externNeedsClosure" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "externNeedsClosure" ((PVar "ctx") (PVar "symbol")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "symbol")) (EFieldAccess (EVar "ctx") "externFacts")) (arm (PCon "Some" (PVar "fact")) () (EMatch (ETuple (EApp (EApp (EVar "externRuntimeKey") (EFieldAccess (EVar "ctx") "externFacts")) (EVar "symbol")) (EFieldAccess (EVar "fact") "callableShape")) (arm (PTuple (PCon "Some" (PVar "key")) (PCon "Some" (PVar "shape"))) () (EBinOp "&&" (EBinOp ">" (EFieldAccess (EVar "shape") "loweredCoreArity") (ELit (LInt 0))) (EMatch (EApp (EVar "wasmFamily") (EVar "key")) (arm (PCon "Some" (PVar "family")) () (EApp (EVar "isWasmExternFamily") (EVar "family"))) (arm (PCon "None") () (EVar "False"))))) (arm (PTuple (PCon "None") PWild) () (EVar "True")) (arm PWild () (EVar "False")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "hStmts" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyCon "HelperAcc"))))))))
(DFunDef false "hStmts" (PWild PWild PWild (PVar "acc") PWild (PList)) (EVar "acc"))
(DFunDef false "hStmts" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCons (PCon "CSLet" (PVar "recFlag") (PAs "pat" (PCon "PVar" PWild PWild PWild)) (PAs "lam" (PCon "CLam" (PVar "pats") (PVar "body")))) (PVar "rest"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "envBindPat") (EVar "pat")) (EVar "env"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hStmts") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EApp (EVar "localFunctionRoots") (EVar "refMode")) (EVar "acc")) (EVar "pats")) (EVar "body"))) (EIf (EVar "recFlag") (EVar "inner") (EVar "env"))) (EVar "lam"))) (EVar "inner")) (EVar "rest")))))
(DFunDef false "hStmts" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCons (PCon "CSLet" (PVar "recFlag") (PVar "pat") (PVar "x")) (PVar "rest"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "envBindPat") (EVar "pat")) (EVar "env"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hStmts") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EVar "hPat") (EVar "refMode")) (EVar "acc")) (EVar "pat"))) (EIf (EVar "recFlag") (EVar "inner") (EVar "env"))) (EVar "x"))) (EVar "inner")) (EVar "rest")))))
(DFunDef false "hStmts" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCons (PCon "CSExpr" (PVar "x")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hStmts") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "x"))) (EVar "env")) (EVar "rest")))
(DFunDef false "hStmts" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "acc") (PVar "env") (PCons (PCon "CSAssign" PWild (PVar "x")) (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hStmts") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "env")) (EVar "x"))) (EVar "env")) (EVar "rest")))
(DTypeSig false "hArm" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "HelperAcc") (TyFun (TyCon "CArm") (TyCon "HelperAcc"))))))))
(DFunDef false "hArm" ((PVar "ctx") (PVar "refMode") (PVar "str") (PVar "env") (PVar "acc") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "b"))) (EBlock (DoLet false false (PTuple (PVar "acc") (PVar "inner")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PTuple (PVar "a") (PVar "scope")) (PVar "g")) (EMatch (EVar "g") (arm (PCon "CGBool" (PVar "x")) () (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "a")) (EVar "scope")) (EVar "x")) (EVar "scope"))) (arm (PCon "CGBind" (PVar "p") (PVar "x")) () (ETuple (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EApp (EApp (EApp (EVar "hPat") (EVar "refMode")) (EVar "a")) (EVar "p"))) (EVar "scope")) (EVar "x")) (EApp (EApp (EVar "envBindPat") (EVar "p")) (EVar "scope"))))))) (ETuple (EApp (EApp (EApp (EVar "hPat") (EVar "refMode")) (EVar "acc")) (EVar "pat")) (EApp (EApp (EVar "envBindPat") (EVar "pat")) (EVar "env")))) (EVar "guards"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "hExpr") (EVar "ctx")) (EVar "refMode")) (EVar "str")) (EVar "acc")) (EVar "inner")) (EVar "b")))))
(DTypeSig false "hTree" (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyFun (TyCon "CTree") (TyCon "HelperAcc")))))
(DFunDef false "hTree" ((PCon "True") (PVar "acc") (PCon "CTFail" (PCon "LetRefuted" (PVar "loc")))) (EApp (EApp (EVar "locatedTrap") (EVar "acc")) (EVar "loc")))
(DFunDef false "hTree" ((PCon "True") (PVar "acc") (PCon "CTFail" (PCon "NoArm" (PVar "loc")))) (EApp (EApp (EVar "locatedNonexh") (EVar "acc")) (EVar "loc")))
(DFunDef false "hTree" ((PVar "refMode") (PVar "acc") (PCon "CTGuard" PWild (PVar "t"))) (EApp (EApp (EApp (EVar "hTree") (EVar "refMode")) (EVar "acc")) (EVar "t")))
(DFunDef false "hTree" ((PVar "refMode") (PVar "acc") (PCon "CTDrop" (PVar "t"))) (EApp (EApp (EApp (EVar "hTree") (EVar "refMode")) (EVar "acc")) (EVar "t")))
(DFunDef false "hTree" ((PVar "refMode") (PVar "acc") (PCon "CTSwitch" (PVar "branches") (PVar "dft"))) (EApp (EApp (EApp (EVar "hTree") (EVar "refMode")) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "hBranch") (EVar "refMode"))) (EVar "acc")) (EVar "branches"))) (EVar "dft")))
(DFunDef false "hTree" (PWild (PVar "acc") PWild) (EVar "acc"))
(DTypeSig false "hBranch" (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyFun (TyCon "CTBranch") (TyCon "HelperAcc")))))
(DFunDef false "hBranch" ((PVar "refMode") (PVar "acc") (PCon "CTBranch" (PVar "head") (PVar "tree"))) (EBlock (DoLet false false (PVar "acc") (EMatch (EVar "head") (arm (PCon "HLit" (PVar "lit")) () (EApp (EApp (EApp (EVar "hPat") (EVar "refMode")) (EVar "acc")) (EApp (EVar "PLit") (EVar "lit")))) (arm (PCon "HCons") () (ERecordUpdate (EVar "acc") ((fa "patternList" (EVar "True"))))) (arm (PCon "HNil") () (ERecordUpdate (EVar "acc") ((fa "patternList" (EVar "True"))))) (arm (PCon "HTuple" (PVar "n")) () (ERecordUpdate (EVar "acc") ((fa "patternTuples" (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "intToString") (EVar "n"))) (EVar "n")) (EFieldAccess (EVar "acc") "patternTuples")))))) (arm PWild () (EVar "acc")))) (DoExpr (EApp (EApp (EApp (EVar "hTree") (EVar "refMode")) (EVar "acc")) (EVar "tree")))))
(DTypeSig false "locatedTrap" (TyFun (TyCon "HelperAcc") (TyFun (TyCon "Loc") (TyCon "HelperAcc"))))
(DFunDef false "locatedTrap" ((PVar "acc") (PVar "loc")) (EIf (EApp (EVar "hasLocation") (EVar "loc")) (EApp (EVar "needSite") (EVar "acc")) (EApp (EVar "needTrap") (EVar "acc"))))
(DTypeSig false "locatedNonexh" (TyFun (TyCon "HelperAcc") (TyFun (TyCon "Loc") (TyCon "HelperAcc"))))
(DFunDef false "locatedNonexh" ((PVar "acc") (PVar "loc")) (EIf (EApp (EVar "hasLocation") (EVar "loc")) (ERecordUpdate (EApp (EVar "needSite") (EVar "acc")) ((fa "nonexh" (EVar "True")))) (EApp (EVar "needTrap") (EVar "acc"))))
(DTypeSig false "hasLocation" (TyFun (TyCon "Loc") (TyCon "Bool")))
(DFunDef false "hasLocation" ((PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "/=" (EVar "f") (ELit (LString ""))) (EApp (EVar "not") (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EVar "sl") (ELit (LInt 1))) (EBinOp "==" (EVar "sc") (ELit (LInt 0)))) (EBinOp "==" (EVar "el") (ELit (LInt 1)))) (EBinOp "==" (EVar "ec") (ELit (LInt 0)))))) (EBinOp ">=" (EVar "sl") (ELit (LInt 0)))) (EBinOp "<" (EVar "sl") (ELit (LInt 16777216)))) (EBinOp ">=" (EVar "sc") (ELit (LInt 0)))) (EBinOp "<" (EVar "sc") (ELit (LInt 1048576)))))
(DTypeSig false "runtimeRoots" (TyFun (TyCon "WasmTypeContext") (TyFun (TyCon "HelperAcc") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyCon "HelperAcc"))))))
(DFunDef false "runtimeRoots" ((PVar "ctx") (PVar "acc") (PVar "symbol") (PVar "args")) (EMatch (EApp (EApp (EVar "externRuntimeKey") (EFieldAccess (EVar "ctx") "externFacts")) (EVar "symbol")) (arm (PCon "Some" (PVar "key")) ((GBool (EApp (EApp (EVar "contains") (EVar "key")) (EListLit (ELit (LString "shiftLeft")) (ELit (LString "intShiftLeft")))))) (EApp (EApp (EVar "needInt") (EVar "acc")) (ELit (LString "left")))) (arm (PCon "Some" (PVar "key")) ((GBool (EApp (EApp (EVar "contains") (EVar "key")) (EListLit (ELit (LString "shiftRight")) (ELit (LString "intShiftRight")))))) (EApp (EApp (EVar "needInt") (EVar "acc")) (ELit (LString "right")))) (arm (PCon "Some" (PVar "key")) ((GBool (EApp (EApp (EVar "contains") (EVar "key")) (EListLit (ELit (LString "panic")) (ELit (LString "indexError")) (ELit (LString "sliceError")))))) (EApp (EVar "needTrap") (EVar "acc"))) (arm (PCon "Some" (PLit (LString "indexErrorAt"))) () (EApp (EApp (EVar "need") (EApp (EVar "needTrap") (EVar "acc"))) (ELit (LString "trapIntRuntimeLines")))) (arm (PCon "Some" (PVar "key")) ((GBool (EBinOp "||" (EBinOp "==" (EVar "key") (ELit (LString "indexErrorAtSite"))) (EBinOp "==" (EVar "key") (ELit (LString "panicAt")))))) (EBlock (DoLet false false (PVar "acc") (EIf (EBinOp "==" (EVar "key") (ELit (LString "indexErrorAtSite"))) (EApp (EApp (EVar "need") (EApp (EVar "needTrap") (EVar "acc"))) (ELit (LString "trapIntRuntimeLines"))) (EApp (EVar "needTrap") (EVar "acc")))) (DoExpr (EMatch (EVar "args") (arm (PCons (PCon "CLit" (PCon "LInt" (PLit (LInt 0)))) PWild) () (EVar "acc")) (arm PWild () (EApp (EVar "needSite") (EVar "acc"))))))) (arm PWild () (EVar "acc"))))
(DTypeSig false "intOpName" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "intOpName" ((PLit (LString "+"))) (ELit (LString "add")))
(DFunDef false "intOpName" ((PLit (LString "-"))) (ELit (LString "sub")))
(DFunDef false "intOpName" ((PLit (LString "*"))) (ELit (LString "mul")))
(DFunDef false "intOpName" (PWild) (ELit (LString "div")))
(DTypeSig false "valueOpBlock" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "valueOpBlock" ((PLit (LString "+"))) (ELit (LString "Add")))
(DFunDef false "valueOpBlock" ((PLit (LString "-"))) (ELit (LString "Sub")))
(DFunDef false "valueOpBlock" ((PLit (LString "*"))) (ELit (LString "Mul")))
(DFunDef false "valueOpBlock" ((PLit (LString "/"))) (ELit (LString "Div")))
(DFunDef false "valueOpBlock" (PWild) (ELit (LString "Mod")))
(DTypeSig false "printRoots" (TyFun (TyCon "WasmTypeContext") (TyFun (TyApp (TyCon "Option") (TyCon "EntryFact")) (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyFun (TyCon "HelperAcc") (TyCon "HelperAcc"))))))
(DFunDef false "printRoots" ((PVar "ctx") (PVar "outcome") (PVar "groups") (PVar "acc")) (EBlock (DoLet false false (PVar "body") (EApp (EApp (EMethodRef "filterMap") (EVar "mainBodyD")) (EVar "groups"))) (DoExpr (EMatch (EVar "body") (arm (PCons (PVar "e") PWild) () (EBlock (DoLet false false (PVar "own") (EApp (EApp (EApp (EVar "varStamp") (EVar "ctx")) (EListLit)) (ELit (LString "main")))) (DoLet false false (PVar "stamp") (EMatch (EVar "outcome") (arm (PCon "Some" (PVar "fact")) ((GBool (EFieldAccess (EVar "fact") "entryMainIsUnit"))) (EVar "RTUnit")) (arm (PCon "Some" (PVar "fact")) ((GBool (EFieldAccess (EVar "fact") "entryMainIsFloat"))) (EVar "RTFloat")) (arm PWild () (EIf (EBinOp "==" (EVar "own") (EVar "RTValue")) (EApp (EApp (EApp (EVar "cexprStamp") (EVar "ctx")) (EListLit)) (EVar "e")) (EVar "own"))))) (DoExpr (EIf (EBinOp "==" (EVar "stamp") (EVar "RTFloat")) (EApp (EApp (EVar "needMany") (EVar "acc")) (EListLit (ELit (LString "floatRuntimeLines")) (ELit (LString "ioStrRuntimeLines")))) (EIf (EBinOp "==" (EVar "stamp") (EVar "RTChar")) (EApp (EApp (EVar "needMany") (EVar "acc")) (EListLit (ELit (LString "ioStrRuntimeLines")) (ELit (LString "strLeafRuntimeLines")))) (EVar "acc")))))) (arm (PList) () (EVar "acc"))))))
(DTypeSig false "mainBodyD" (TyFun (TyCon "CBind") (TyApp (TyCon "Option") (TyCon "CExpr"))))
(DFunDef false "mainBodyD" ((PCon "CBind" (PLit (LString "main")) (PList (PCon "CClause" (PList) (PVar "e"))) PWild PWild)) (EApp (EVar "Some") (EVar "e")))
(DFunDef false "mainBodyD" (PWild) (EVar "None"))
(DTypeSig false "representationOf" (TyFun (TyCon "WasmDemand") (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyCon "WasmDemand")))))
(DFunDef false "representationOf" ((PVar "source") (PVar "str") (PVar "acc")) (EBlock (DoLet false false (PVar "types") (EApp (EApp (EDictApp "flatMap") (EVar "helperTypes")) (EApp (EVar "omKeys") (EFieldAccess (EVar "acc") "helpers")))) (DoLet false false (PVar "uses") (EIf (EBinOp "||" (EBinOp "||" (EVar "str") (EApp (EApp (EVar "contains") (ELit (LString "str"))) (EVar "types"))) (EApp (EApp (EVar "contains") (ELit (LString "u8arr"))) (EVar "types"))) (EApp (EApp (EVar "addUse") (EFieldAccess (EVar "source") "uses")) (EVar "UseStr")) (EFieldAccess (EVar "source") "uses"))) (DoLet false false (PVar "uses") (EIf (EApp (EApp (EVar "contains") (ELit (LString "arr"))) (EVar "types")) (EApp (EApp (EVar "addUse") (EVar "uses")) (EVar "UseArray")) (EVar "uses"))) (DoLet false false (PVar "uses") (EIf (EBinOp "||" (EFieldAccess (EVar "acc") "patternList") (EApp (EApp (EVar "contains") (ELit (LString "C_Cons"))) (EVar "types"))) (EApp (EApp (EVar "addUse") (EVar "uses")) (EVar "UseList")) (EVar "uses"))) (DoLet false false (PVar "seen") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "intToString")) (EFieldAccess (EVar "source") "tupleArities"))) (EVar "omEmpty"))) (DoLet false false (PVar "extraTuples") (EApp (EApp (EMethodRef "filterMap") (ELam ((PVar "k")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "k")) (EVar "seen")) (EVar "None") (EApp (EApp (EVar "omLookup") (EVar "k")) (EFieldAccess (EVar "acc") "patternTuples"))))) (EApp (EVar "omKeys") (EFieldAccess (EVar "acc") "patternTuples")))) (DoExpr (ERecordUpdate (EVar "source") ((fa "uses" (EVar "uses")) (fa "refBox" (EBinOp "||" (EFieldAccess (EVar "source") "refBox") (EFieldAccess (EVar "acc") "refRead"))) (fa "tupleArities" (EBinOp "++" (EFieldAccess (EVar "source") "tupleArities") (EVar "extraTuples"))))))))
(DTypeSig false "physicalTypes" (TyFun (TyCon "CProgram") (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "WasmDemand") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "physicalTypes" (PWild (PCon "False") PWild PWild) (EListLit (ELit (LString "boxint")) (ELit (LString "float"))))
(DFunDef false "physicalTypes" ((PCon "CProgram" PWild (PVar "ctorArs") (PVar "ctorTypes") PWild PWild PWild) (PCon "True") (PVar "clos") (PVar "rep")) (EBlock (DoLet false false (PVar "ctorIndex") (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EVar "ctorArs"))) (EVar "omEmpty"))) (DoExpr (EApp (EVar "omKeys") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EListLit (ELit (LString "boxint")) (ELit (LString "float")) (ELit (LString "dictarr")) (ELit (LString "dictcell")) (ELit (LString "T_Option")) (ELit (LString "C_Some")) (ELit (LString "T_Result")) (ELit (LString "C_Ok")) (ELit (LString "C_Err")) (ELit (LString "T_Ordering"))) (EIf (EVar "clos") (EListLit (ELit (LString "argarr")) (ELit (LString "codety")) (ELit (LString "clos"))) (EListLit))) (EIf (EApp (EApp (EVar "hasUse") (EVar "rep")) (EVar "UseStr")) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))) (EListLit))) (EIf (EApp (EApp (EVar "hasUse") (EVar "rep")) (EVar "UseList")) (EListLit (ELit (LString "T_List")) (ELit (LString "C_Cons"))) (EListLit))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "n")) (EListLit (EBinOp "++" (ELit (LString "T_Tup")) (EApp (EVar "intToString") (EVar "n"))) (EBinOp "++" (ELit (LString "C_Tup")) (EApp (EVar "intToString") (EVar "n")))))) (EFieldAccess (EVar "rep") "tupleArities"))) (EIf (EApp (EApp (EVar "hasUse") (EVar "rep")) (EVar "UseArray")) (EListLit (ELit (LString "arr"))) (EListLit))) (EIf (EFieldAccess (EVar "rep") "refBox") (EListLit (ELit (LString "refbox"))) (EListLit))) (EIf (EApp (EApp (EVar "hasUse") (EVar "rep")) (EVar "UseU64")) (EListLit (ELit (LString "u64"))) (EListLit))) (EIf (EApp (EApp (EVar "hasUse") (EVar "rep")) (EVar "UseI64")) (EListLit (ELit (LString "i64"))) (EListLit))) (EApp (EApp (EDictApp "flatMap") (ELam ((PTuple (PVar "ctor") (PVar "ty"))) (EIf (EApp (EApp (EVar "contains") (EVar "ty")) (EListLit (ELit (LString "Option")) (ELit (LString "Result")) (ELit (LString "Ordering")))) (EListLit) (EBinOp "++" (EListLit (EBinOp "++" (ELit (LString "T_")) (EApp (EVar "injectiveIdent") (EVar "ty")))) (EIf (EBinOp ">" (EApp (EApp (EVar "optionOr") (ELit (LInt 0))) (EApp (EApp (EVar "omLookup") (EVar "ctor")) (EVar "ctorIndex"))) (ELit (LInt 0))) (EListLit (EIf (EBinOp "||" (EBinOp "==" (EVar "ctor") (ELit (LString "Cons"))) (EBinOp "==" (EVar "ctor") (ELit (LString "Nil")))) (EBinOp "++" (ELit (LString "CU_")) (EVar "ctor")) (EBinOp "++" (ELit (LString "C_")) (EVar "ctor")))) (EListLit)))))) (EVar "ctorTypes")))) (EVar "omEmpty"))))))
(DTypeSig false "addUse" (TyFun (TyApp (TyCon "List") (TyCon "WasmUse")) (TyFun (TyCon "WasmUse") (TyApp (TyCon "List") (TyCon "WasmUse")))))
(DFunDef false "addUse" ((PVar "uses") (PVar "use")) (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "use")))) (EVar "uses")) (EVar "uses") (EBinOp "::" (EVar "use") (EVar "uses"))))
(DTypeSig true "helperOrder" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "helperOrder" () (EListLit (ELit (LString "closApplyLines")) (ELit (LString "ioRuntimeLines")) (ELit (LString "ioStrRuntimeLines")) (ELit (LString "strLeafRuntimeLines")) (ELit (LString "strConcatRuntimeLines")) (ELit (LString "appendRuntimeLines")) (ELit (LString "valueEqRuntimeLines")) (ELit (LString "valueAddRuntimeLines")) (ELit (LString "valueSubRuntimeLines")) (ELit (LString "valueMulRuntimeLines")) (ELit (LString "valueDivRuntimeLines")) (ELit (LString "valueModRuntimeLines")) (ELit (LString "valueCmpNumRuntimeLines")) (ELit (LString "u64RuntimeLines")) (ELit (LString "i64RuntimeLines")) (ELit (LString "stderrRuntimeLines")) (ELit (LString "rngRuntimeLines")) (ELit (LString "hashRuntimeLines")) (ELit (LString "hashStringRuntimeLines")) (ELit (LString "floatRemRuntimeLines")) (ELit (LString "floatRuntimeLines")) (ELit (LString "hashFloatRuntimeLines")) (ELit (LString "randomFloatRuntimeLines")) (ELit (LString "strSearchRuntimeLines")) (ELit (LString "strToIntRuntimeLines")) (ELit (LString "strReverseRuntimeLines")) (ELit (LString "strJoinRuntimeLines")) (ELit (LString "utf8LossyRuntimeLines")) (ELit (LString "strCodecRuntimeLines")) (ELit (LString "byteBlockRuntimeLines")) (ELit (LString "charFromCodeRuntimeLines")) (ELit (LString "charClassRuntimeLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioPushPathMoreLines")) (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushGrantMoreLines")) (ELit (LString "ioResultLines")) (ELit (LString "ioRefusedPanicLines")) (ELit (LString "ioReadFileLines")) (ELit (LString "ioFetchTextLines")) (ELit (LString "ioFileExistsLines")) (ELit (LString "ioCanonicalizeLines")) (ELit (LString "ioWriteFileLines")) (ELit (LString "ioAppendFileLines")) (ELit (LString "ioRenameLines")) (ELit (LString "ioListDirLines")) (ELit (LString "ioStatFileLines")) (ELit (LString "ioMakeDirLines")) (ELit (LString "ioRemoveFileLines")) (ELit (LString "ioRemoveDirLines")) (ELit (LString "ioFsyncLines")) (ELit (LString "ioFileModeLines")) (ELit (LString "ioWriteFileModeLines")) (ELit (LString "ioGetEnvLines")) (ELit (LString "ioReadLineLines")) (ELit (LString "ioReadAllLines")) (ELit (LString "ioReadExactlyLines")) (ELit (LString "ioExecutablePathLines")) (ELit (LString "jsffiArrayLines")) (ELit (LString "jsffiResultStrLines")) (ELit (LString "ioArgsLines")) (ELit (LString "writeFileBytesLines")) (ELit (LString "osEntropyLines")) (ELit (LString "readFileBytesLines")) (ELit (LString "floatStrLines")) (ELit (LString "trapIntRuntimeLines")) (ELit (LString "intRuntimeLines")) (ELit (LString "siteRuntimeLines"))))
(DTypeSig false "helperDependencies" (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "appendRuntimeLines"))) (EListLit (ELit (LString "strLeafRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "byteBlockRuntimeLines"))) (EListLit (ELit (LString "ioByteImportLines")) (ELit (LString "ioRuntimeLines")) (ELit (LString "utf8LossyRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "floatRuntimeLines"))) (EListLit (ELit (LString "floatFmtImportLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "hashFloatRuntimeLines"))) (EListLit (ELit (LString "hashRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "intRuntimeLines"))) (EListLit (ELit (LString "siteRuntimeLines")) (ELit (LString "stderrByteImportLines")) (ELit (LString "trapIntRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioAppendFileLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioArgsLines"))) (EListLit (ELit (LString "utf8LossyRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioCanonicalizeLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioRefusedPanicLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioExecutablePathLines"))) (EListLit (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioFetchTextLines"))) (EListLit (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioFileExistsLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioRefusedPanicLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioFileModeLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines")) (ELit (LString "ioRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioFsyncLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioGetEnvLines"))) (EListLit (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioListDirLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines")) (ELit (LString "utf8LossyRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioMakeDirLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioReadAllLines"))) (EListLit (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioReadExactlyLines"))) (EListLit (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioReadFileLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines")) (ELit (LString "utf8LossyRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioReadLineLines"))) (EListLit (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioRefusedPanicLines"))) (EListLit (ELit (LString "ioResultLines")) (ELit (LString "stderrByteImportLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioRemoveDirLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioRemoveFileLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioRenameLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushGrantMoreLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioPushPathMoreLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioResultLines"))) (EListLit (ELit (LString "utf8LossyRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioRuntimeLines"))) (EListLit (ELit (LString "ioByteImportLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioStatFileLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines")) (ELit (LString "ioRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioStrRuntimeLines"))) (EListLit (ELit (LString "ioByteImportLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioWriteFileLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "ioWriteFileModeLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines")) (ELit (LString "ioRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "jsffiArrayLines"))) (EListLit (ELit (LString "ioRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "jsffiResultStrLines"))) (EListLit (ELit (LString "utf8LossyRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "osEntropyLines"))) (EListLit (ELit (LString "ioRefusedPanicLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "randomFloatRuntimeLines"))) (EListLit (ELit (LString "rngRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "readFileBytesLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "siteRuntimeLines"))) (EListLit (ELit (LString "stderrByteImportLines")) (ELit (LString "trapIntRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "stderrRuntimeLines"))) (EListLit (ELit (LString "stderrByteImportLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "strCodecRuntimeLines"))) (EListLit (ELit (LString "utf8LossyRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "strSearchRuntimeLines"))) (EListLit (ELit (LString "strLeafRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "strToIntRuntimeLines"))) (EListLit (ELit (LString "ioRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "trapIntRuntimeLines"))) (EListLit (ELit (LString "stderrByteImportLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "valueAddRuntimeLines"))) (EListLit (ELit (LString "intRuntimeLines")) (ELit (LString "ioRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "valueCmpNumRuntimeLines"))) (EListLit (ELit (LString "ioRuntimeLines"))))
(DFunDef false "helperDependencies" ((PVar "wide") (PLit (LString "valueDivRuntimeLines"))) (EBinOp "++" (EListLit (ELit (LString "intRuntimeLines")) (ELit (LString "ioRuntimeLines")) (ELit (LString "stderrByteImportLines"))) (EIf (EVar "wide") (EListLit (ELit (LString "i64RuntimeLines"))) (EListLit))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "valueEqRuntimeLines"))) (EListLit (ELit (LString "ioRuntimeLines")) (ELit (LString "strSearchRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "valueModRuntimeLines"))) (EListLit (ELit (LString "floatRemRuntimeLines")) (ELit (LString "ioRuntimeLines")) (ELit (LString "stderrByteImportLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "valueMulRuntimeLines"))) (EListLit (ELit (LString "intRuntimeLines")) (ELit (LString "ioRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "valueSubRuntimeLines"))) (EListLit (ELit (LString "intRuntimeLines")) (ELit (LString "ioRuntimeLines"))))
(DFunDef false "helperDependencies" (PWild (PLit (LString "writeFileBytesLines"))) (EListLit (ELit (LString "ioPushGrantLines")) (ELit (LString "ioPushPathLines")) (ELit (LString "ioResultLines"))))
(DFunDef false "helperDependencies" (PWild PWild) (EListLit))
(DTypeSig false "helperHostKeys" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "helperHostKeys" ((PLit (LString "floatFmtImportLines"))) (EListLit (ELit (LString "mdk_float_fmt")) (ELit (LString "mdk_float_fmt_byte"))))
(DFunDef false "helperHostKeys" ((PLit (LString "floatStrLines"))) (EListLit (ELit (LString "mdk_path_push")) (ELit (LString "mdk_path_reset")) (ELit (LString "mdk_str_to_float")) (ELit (LString "mdk_str_to_float_ok"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioAppendFileLines"))) (EListLit (ELit (LString "mdk_append_file")) (ELit (LString "mdk_write_file_push")) (ELit (LString "mdk_write_file_reset"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioArgsLines"))) (EListLit (ELit (LString "mdk_arg_byte")) (ELit (LString "mdk_arg_len")) (ELit (LString "mdk_args_count"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioByteImportLines"))) (EListLit (ELit (LString "mdk_write_byte"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioCanonicalizeLines"))) (EListLit (ELit (LString "mdk_canonicalize_path"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioExecutablePathLines"))) (EListLit (ELit (LString "mdk_executable_path"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioFetchTextLines"))) (EListLit (ELit (LString "mdk_fetch_text"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioFileExistsLines"))) (EListLit (ELit (LString "mdk_file_exists"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioFileModeLines"))) (EListLit (ELit (LString "mdk_file_mode")) (ELit (LString "mdk_stat_field"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioFsyncLines"))) (EListLit (ELit (LString "mdk_fsync"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioGetEnvLines"))) (EListLit (ELit (LString "mdk_get_env"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioListDirLines"))) (EListLit (ELit (LString "mdk_list_dir"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioMakeDirLines"))) (EListLit (ELit (LString "mdk_make_dir"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioPushGrantLines"))) (EListLit (ELit (LString "mdk_grant_push")) (ELit (LString "mdk_grant_reset"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioPushGrantMoreLines"))) (EListLit (ELit (LString "mdk_grant_push"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioPushPathLines"))) (EListLit (ELit (LString "mdk_path_push")) (ELit (LString "mdk_path_reset"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioPushPathMoreLines"))) (EListLit (ELit (LString "mdk_path_push"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioReadAllLines"))) (EListLit (ELit (LString "mdk_read_all"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioReadExactlyLines"))) (EListLit (ELit (LString "mdk_read_exactly"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioReadFileLines"))) (EListLit (ELit (LString "mdk_read_file"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioReadLineLines"))) (EListLit (ELit (LString "mdk_read_line"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioRemoveDirLines"))) (EListLit (ELit (LString "mdk_remove_dir"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioRemoveFileLines"))) (EListLit (ELit (LString "mdk_remove_file"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioRenameLines"))) (EListLit (ELit (LString "mdk_grant_push")) (ELit (LString "mdk_rename"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioResultLines"))) (EListLit (ELit (LString "mdk_result_byte")) (ELit (LString "mdk_result_len"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioStatFileLines"))) (EListLit (ELit (LString "mdk_stat_field")) (ELit (LString "mdk_stat_file"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioWriteFileLines"))) (EListLit (ELit (LString "mdk_write_file")) (ELit (LString "mdk_write_file_push")) (ELit (LString "mdk_write_file_reset"))))
(DFunDef false "helperHostKeys" ((PLit (LString "ioWriteFileModeLines"))) (EListLit (ELit (LString "mdk_write_file_mode")) (ELit (LString "mdk_write_file_push")) (ELit (LString "mdk_write_file_reset"))))
(DFunDef false "helperHostKeys" ((PLit (LString "jsffiArrayLines"))) (EListLit (ELit (LString "mdk_path_push")) (ELit (LString "mdk_result_byte"))))
(DFunDef false "helperHostKeys" ((PLit (LString "jsffiResultStrLines"))) (EListLit (ELit (LString "mdk_result_byte")) (ELit (LString "mdk_result_len"))))
(DFunDef false "helperHostKeys" ((PLit (LString "osEntropyLines"))) (EListLit (ELit (LString "mdk_os_entropy")) (ELit (LString "mdk_result_byte")) (ELit (LString "mdk_result_len"))))
(DFunDef false "helperHostKeys" ((PLit (LString "readFileBytesLines"))) (EListLit (ELit (LString "mdk_read_file")) (ELit (LString "mdk_result_byte")) (ELit (LString "mdk_result_len"))))
(DFunDef false "helperHostKeys" ((PLit (LString "stderrByteImportLines"))) (EListLit (ELit (LString "mdk_write_err_byte"))))
(DFunDef false "helperHostKeys" ((PLit (LString "writeFileBytesLines"))) (EListLit (ELit (LString "mdk_write_file_commit")) (ELit (LString "mdk_write_file_push")) (ELit (LString "mdk_write_file_reset"))))
(DFunDef false "helperHostKeys" (PWild) (EListLit))
(DTypeSig false "helperTypes" (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "helperTypes" ((PLit (LString "appendRuntimeLines"))) (EListLit (ELit (LString "C_Cons")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "byteBlockRuntimeLines"))) (EListLit (ELit (LString "arr")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "charFromCodeRuntimeLines"))) (EListLit (ELit (LString "C_Some"))))
(DFunDef false "helperTypes" ((PLit (LString "closApplyLines"))) (EListLit (ELit (LString "argarr")) (ELit (LString "clos"))))
(DFunDef false "helperTypes" ((PLit (LString "floatRuntimeLines"))) (EListLit (ELit (LString "float")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "floatStrLines"))) (EListLit (ELit (LString "C_Some")) (ELit (LString "float")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "hashFloatRuntimeLines"))) (EListLit (ELit (LString "float"))))
(DFunDef false "helperTypes" ((PLit (LString "hashStringRuntimeLines"))) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioAppendFileLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioArgsLines"))) (EListLit (ELit (LString "C_Cons")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioCanonicalizeLines"))) (EListLit (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioFetchTextLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioFileExistsLines"))) (EListLit (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioFileModeLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioFsyncLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioGetEnvLines"))) (EListLit (ELit (LString "C_Some")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioListDirLines"))) (EListLit (ELit (LString "C_Cons")) (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioMakeDirLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioPushGrantLines"))) (EListLit (ELit (LString "C_Cons")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioPushGrantMoreLines"))) (EListLit (ELit (LString "C_Cons")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioPushPathLines"))) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioPushPathMoreLines"))) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioReadExactlyLines"))) (EListLit (ELit (LString "C_Some"))))
(DFunDef false "helperTypes" ((PLit (LString "ioReadFileLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioReadLineLines"))) (EListLit (ELit (LString "C_Some"))))
(DFunDef false "helperTypes" ((PLit (LString "ioRefusedPanicLines"))) (EListLit (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioRemoveDirLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioRemoveFileLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioRenameLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioResultLines"))) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioRuntimeLines"))) (EListLit (ELit (LString "boxint"))))
(DFunDef false "helperTypes" ((PLit (LString "ioStatFileLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "C_Tup4")) (ELit (LString "float")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "ioStrRuntimeLines"))) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioWriteFileLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "ioWriteFileModeLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "jsffiArrayLines"))) (EListLit (ELit (LString "arr"))))
(DFunDef false "helperTypes" ((PLit (LString "jsffiResultStrLines"))) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "osEntropyLines"))) (EListLit (ELit (LString "arr"))))
(DFunDef false "helperTypes" ((PLit (LString "randomFloatRuntimeLines"))) (EListLit (ELit (LString "float"))))
(DFunDef false "helperTypes" ((PLit (LString "readFileBytesLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "arr")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "stderrRuntimeLines"))) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "strCodecRuntimeLines"))) (EListLit (ELit (LString "arr")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "strConcatRuntimeLines"))) (EListLit (ELit (LString "C_Cons")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "strJoinRuntimeLines"))) (EListLit (ELit (LString "C_Cons")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "strLeafRuntimeLines"))) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "strReverseRuntimeLines"))) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "strSearchRuntimeLines"))) (EListLit (ELit (LString "C_Some")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "strToIntRuntimeLines"))) (EListLit (ELit (LString "C_Some")) (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "utf8LossyRuntimeLines"))) (EListLit (ELit (LString "str")) (ELit (LString "u8arr"))))
(DFunDef false "helperTypes" ((PLit (LString "valueAddRuntimeLines"))) (EListLit (ELit (LString "float"))))
(DFunDef false "helperTypes" ((PLit (LString "valueCmpNumRuntimeLines"))) (EListLit (ELit (LString "float"))))
(DFunDef false "helperTypes" ((PLit (LString "valueDivRuntimeLines"))) (EListLit (ELit (LString "float"))))
(DFunDef false "helperTypes" ((PLit (LString "valueEqRuntimeLines"))) (EListLit (ELit (LString "boxint")) (ELit (LString "float")) (ELit (LString "str"))))
(DFunDef false "helperTypes" ((PLit (LString "valueModRuntimeLines"))) (EListLit (ELit (LString "float"))))
(DFunDef false "helperTypes" ((PLit (LString "valueMulRuntimeLines"))) (EListLit (ELit (LString "float"))))
(DFunDef false "helperTypes" ((PLit (LString "valueSubRuntimeLines"))) (EListLit (ELit (LString "float"))))
(DFunDef false "helperTypes" ((PLit (LString "writeFileBytesLines"))) (EListLit (ELit (LString "C_Err")) (ELit (LString "C_Ok")) (ELit (LString "arr")) (ELit (LString "str"))))
(DFunDef false "helperTypes" (PWild) (EListLit))
(DTypeSig false "closeHelpers" (TyFun (TyCon "Bool") (TyFun (TyCon "HelperAcc") (TyCon "HelperAcc"))))
(DFunDef false "closeHelpers" ((PVar "wide") (PVar "acc")) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "a") (PVar "h")) (EApp (EApp (EVar "needMany") (EVar "a")) (EApp (EApp (EVar "helperDependencies") (EVar "wide")) (EVar "h"))))) (EVar "acc")) (EApp (EVar "omKeys") (EFieldAccess (EVar "acc") "helpers")))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "omKeys") (EFieldAccess (EVar "next") "helpers")) (EApp (EVar "omKeys") (EFieldAccess (EVar "acc") "helpers"))) (EVar "next") (EApp (EApp (EVar "closeHelpers") (EVar "wide")) (EVar "next"))))))
(DTypeSig false "physicalImports" (TyFun (TyCon "HelperAcc") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "List") (TyCon "JsImport")) (TyApp (TyCon "List") (TyCon "PlannedImport"))))))
(DFunDef false "physicalImports" ((PVar "acc") (PVar "sourceKeys") (PVar "js")) (EBlock (DoLet false false (PVar "keys") (EApp (EVar "omKeys") (EApp (EApp (EVar "omFromNames") (EBinOp "++" (EVar "sourceKeys") (EApp (EApp (EDictApp "flatMap") (EVar "helperHostKeys")) (EApp (EVar "omKeys") (EFieldAccess (EVar "acc") "helpers"))))) (EVar "omEmpty")))) (DoLet false false (PVar "first") (EBinOp "++" (EListLit (ELit (LString "mdk_write_byte"))) (EIf (EApp (EApp (EVar "contains") (ELit (LString "mdk_float_fmt"))) (EVar "keys")) (EListLit (ELit (LString "mdk_float_fmt")) (ELit (LString "mdk_float_fmt_byte"))) (EListLit)))) (DoLet false false (PVar "rest") (EApp (EApp (EVar "filterList") (ELam ((PVar "k")) (EApp (EVar "not") (EApp (EApp (EVar "contains") (EVar "k")) (EListLit (ELit (LString "mdk_write_byte")) (ELit (LString "mdk_float_fmt")) (ELit (LString "mdk_float_fmt_byte")) (ELit (LString "mdk_write_err_byte"))))))) (EVar "keys"))) (DoExpr (EBinOp "++" (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "plannedEnv")) (EBinOp "++" (EVar "first") (EVar "rest"))) (EApp (EApp (EMethodRef "map") (EVar "plannedJs")) (EVar "js"))) (EIf (EApp (EApp (EVar "contains") (ELit (LString "mdk_write_err_byte"))) (EVar "keys")) (EListLit (EApp (EVar "plannedEnv") (ELit (LString "mdk_write_err_byte")))) (EListLit))))))
(DTypeSig false "plannedEnv" (TyFun (TyCon "String") (TyCon "PlannedImport")))
(DFunDef false "plannedEnv" ((PVar "key")) (ERecordCreate "PlannedImport" ((fa "namespace" (ELit (LString "env"))) (fa "field" (EVar "key")) (fa "watSymbol" (EVar "key")) (fa "signature" (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EVar "hostImportSigOf") (EVar "key")))))))
(DTypeSig false "plannedJs" (TyFun (TyCon "JsImport") (TyCon "PlannedImport")))
(DFunDef false "plannedJs" ((PVar "imp")) (ERecordCreate "PlannedImport" ((fa "namespace" (ELit (LString "jsffi"))) (fa "field" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "imp") "jsName"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EFieldAccess (EVar "imp") "params")))) (ELit (LString "->"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "imp") "result"))) (ELit (LString "")))) (fa "watSymbol" (EBinOp "++" (EBinOp "++" (ELit (LString "jsffi.import.")) (EApp (EMethodRef "display") (EApp (EVar "injectiveIdent") (EFieldAccess (EVar "imp") "medakaName")))) (ELit (LString "")))) (fa "signature" (EBinOp "++" (EApp (EApp (EVar "joinWith") (ELit (LString ""))) (EApp (EApp (EMethodRef "map") (EVar "jsWireParam")) (EFieldAccess (EVar "imp") "params"))) (EApp (EVar "jsWireResult") (EFieldAccess (EVar "imp") "result")))))))
(DTypeSig true "hostImportSigOf" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_byte"))) (EApp (EVar "Some") (ELit (LString " (param i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_err_byte"))) (EApp (EVar "Some") (ELit (LString " (param i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_float_fmt"))) (EApp (EVar "Some") (ELit (LString " (param f64) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_float_fmt_byte"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_exit"))) (EApp (EVar "Some") (ELit (LString " (param i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_wall_time_sec"))) (EApp (EVar "Some") (ELit (LString " (result f64)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_monotonic_sec"))) (EApp (EVar "Some") (ELit (LString " (result f64)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_sleep_ms"))) (EApp (EVar "Some") (ELit (LString " (param i64)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_fetch_text"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_cbrt"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_exp"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_log"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_log2"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_log10"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_sin"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_cos"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_tan"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_asin"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_acos"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_atan"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_sinh"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_cosh"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_tanh"))) (EApp (EVar "Some") (EVar "unaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_pow"))) (EApp (EVar "Some") (EVar "binaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_atan2"))) (EApp (EVar "Some") (EVar "binaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_hypot"))) (EApp (EVar "Some") (EVar "binaryF64Sig")))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_path_reset"))) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_path_push"))) (EApp (EVar "Some") (ELit (LString " (param i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_read_file"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_file_exists"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_get_env"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_read_line"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_read_all"))) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_read_exactly"))) (EApp (EVar "Some") (ELit (LString " (param i64) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_os_entropy"))) (EApp (EVar "Some") (ELit (LString " (param i64) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_executable_path"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_args_count"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_arg_len"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_arg_byte"))) (EApp (EVar "Some") (ELit (LString " (param i32) (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_result_len"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_result_byte"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_file_reset"))) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_file_push"))) (EApp (EVar "Some") (ELit (LString " (param i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_file_commit"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_str_to_float"))) (EApp (EVar "Some") (ELit (LString " (result f64)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_str_to_float_ok"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_grant_reset"))) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_grant_push"))) (EApp (EVar "Some") (ELit (LString " (param i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_canonicalize_path"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_file"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_append_file"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_make_dir"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_remove_file"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_remove_dir"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_fsync"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_file_mode"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_write_file_mode"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_rename"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_list_dir"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_stat_file"))) (EApp (EVar "Some") (ELit (LString " (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_stat_field"))) (EApp (EVar "Some") (ELit (LString " (param i32) (result f64)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_file_bound_enter"))) (EApp (EVar "Some") (ELit (LString " (param i32) (param i32) (result i32)"))))
(DFunDef false "hostImportSigOf" ((PLit (LString "mdk_file_bound_exit"))) (EApp (EVar "Some") (ELit (LString ""))))
(DFunDef false "hostImportSigOf" (PWild) (EVar "None"))
(DTypeSig false "unaryF64Sig" (TyCon "String"))
(DFunDef false "unaryF64Sig" () (ELit (LString " (param f64) (result f64)")))
(DTypeSig false "binaryF64Sig" (TyCon "String"))
(DFunDef false "binaryF64Sig" () (ELit (LString " (param f64) (param f64) (result f64)")))
(DTypeSig true "jsWireParam" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "jsWireParam" ((PLit (LString "Unit"))) (ELit (LString "")))
(DFunDef false "jsWireParam" ((PVar "head")) (EBinOp "++" (EBinOp "++" (ELit (LString " (param ")) (EApp (EMethodRef "display") (EApp (EVar "jsWireTy") (EVar "head")))) (ELit (LString ")"))))
(DTypeSig true "jsWireResult" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "jsWireResult" ((PLit (LString "Unit"))) (ELit (LString "")))
(DFunDef false "jsWireResult" ((PLit (LString "String"))) (ELit (LString "")))
(DFunDef false "jsWireResult" ((PVar "head")) (EBinOp "++" (EBinOp "++" (ELit (LString " (result ")) (EApp (EMethodRef "display") (EApp (EVar "jsWireTy") (EVar "head")))) (ELit (LString ")"))))
(DTypeSig false "jsWireTy" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "jsWireTy" ((PLit (LString "Int"))) (ELit (LString "i64")))
(DFunDef false "jsWireTy" ((PLit (LString "U64"))) (ELit (LString "i64")))
(DFunDef false "jsWireTy" ((PLit (LString "I64"))) (ELit (LString "i64")))
(DFunDef false "jsWireTy" ((PLit (LString "Float"))) (ELit (LString "f64")))
(DFunDef false "jsWireTy" (PWild) (ELit (LString "i32")))
(DTypeSig true "validateWasmDemand" (TyFun (TyCon "WasmDemandInputs") (TyFun (TyCon "CProgram") (TyFun (TyCon "ExternRequirements") (TyFun (TyCon "WasmDemandPlan") (TyApp (TyCon "List") (TyCon "String")))))))
(DFunDef false "validateWasmDemand" ((PVar "inputs") (PVar "cp") (PVar "requirements") (PVar "actual")) (EBlock (DoLet false false (PVar "expected") (EApp (EApp (EApp (EVar "planWasmDemand") (EVar "inputs")) (EVar "cp")) (EVar "requirements"))) (DoLet false false (PVar "actualTypes") (EApp (EApp (EVar "omFromNames") (EFieldAccess (EVar "actual") "representationTypes")) (EVar "omEmpty"))) (DoLet false false (PVar "expectedKeys") (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "i") "namespace"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "i") "field"))) (ELit (LString ""))))) (EFieldAccess (EVar "expected") "imports"))) (DoLet false false (PVar "actualKeys") (EApp (EApp (EMethodRef "map") (ELam ((PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "i") "namespace"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "i") "field"))) (ELit (LString ""))))) (EFieldAccess (EVar "actual") "imports"))) (DoLet false false (PVar "expectedSet") (EApp (EApp (EVar "omFromNames") (EVar "expectedKeys")) (EVar "omEmpty"))) (DoLet false false (PVar "actualSet") (EApp (EApp (EVar "omFromNames") (EVar "actualKeys")) (EVar "omEmpty"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EIf (EBinOp "||" (EBinOp "||" (EBinOp "/=" (EFieldAccess (EVar "expected") "useRef") (EFieldAccess (EVar "actual") "useRef")) (EBinOp "/=" (EFieldAccess (EVar "expected") "useClos") (EFieldAccess (EVar "actual") "useClos"))) (EBinOp "/=" (EFieldAccess (EVar "expected") "stringOps") (EFieldAccess (EVar "actual") "stringOps"))) (EListLit (ELit (LString "wasm-mode-mismatch"))) (EListLit)) (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "/=" (EFieldAccess (EVar "expected") "sourceDemand") (EFieldAccess (EVar "actual") "sourceDemand")) (EBinOp "/=" (EFieldAccess (EVar "expected") "representation") (EFieldAccess (EVar "actual") "representation"))) (EBinOp "/=" (EFieldAccess (EVar "expected") "intHelpers") (EFieldAccess (EVar "actual") "intHelpers"))) (EBinOp "/=" (EFieldAccess (EVar "expected") "siteRuntime") (EFieldAccess (EVar "actual") "siteRuntime"))) (EBinOp "/=" (EFieldAccess (EVar "expected") "nonexhaustiveRuntime") (EFieldAccess (EVar "actual") "nonexhaustiveRuntime"))) (EListLit (ELit (LString "missing-wasm-helper-prerequisite: physical branches"))) (EListLit))) (EIf (EBinOp "||" (EBinOp "/=" (EFieldAccess (EVar "expected") "censusHelpers") (EFieldAccess (EVar "actual") "censusHelpers")) (EBinOp "/=" (EFieldAccess (EVar "expected") "censusIntHelpers") (EFieldAccess (EVar "actual") "censusIntHelpers"))) (EListLit (ELit (LString "wasm-census-demand-mismatch"))) (EListLit))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EVar "actualTypes")) (EListLit) (EListLit (EBinOp "++" (ELit (LString "missing-wasm-type-prerequisite: ")) (EVar "name")))))) (EFieldAccess (EVar "expected") "representationTypes"))) (EIf (EBinOp "==" (EFieldAccess (EVar "expected") "representationTypes") (EFieldAccess (EVar "actual") "representationTypes")) (EListLit) (EListLit (ELit (LString "wasm-representation-types-mismatch"))))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "h")) (EIf (EApp (EApp (EVar "contains") (EVar "h")) (EFieldAccess (EVar "actual") "helpers")) (EListLit) (EListLit (EBinOp "++" (ELit (LString "missing-wasm-helper-prerequisite: ")) (EVar "h")))))) (EFieldAccess (EVar "expected") "helpers"))) (EIf (EBinOp "==" (EFieldAccess (EVar "expected") "helpers") (EFieldAccess (EVar "actual") "helpers")) (EListLit) (EIf (EApp (EApp (EDictApp "all") (ELam ((PVar "h")) (EApp (EApp (EVar "contains") (EVar "h")) (EFieldAccess (EVar "actual") "helpers")))) (EFieldAccess (EVar "expected") "helpers")) (EListLit (ELit (LString "unexpected-wasm-helper"))) (EListLit)))) (EIf (EBinOp "/=" (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "key") (PVar "family"))) (ETuple (EVar "key") (EApp (EVar "wasmFamilyTag") (EVar "family"))))) (EFieldAccess (EVar "expected") "catalogFamilies")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "key") (PVar "family"))) (ETuple (EVar "key") (EApp (EVar "wasmFamilyTag") (EVar "family"))))) (EFieldAccess (EVar "actual") "catalogFamilies"))) (EListLit (ELit (LString "wasm-catalog-disposition-mismatch"))) (EListLit))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "key")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "key")) (EVar "actualSet")) (EListLit) (EListLit (EBinOp "++" (ELit (LString "missing-wasm-host-key: ")) (EVar "key")))))) (EVar "expectedKeys"))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "key")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "key")) (EVar "expectedSet")) (EListLit) (EListLit (EBinOp "++" (ELit (LString "unexpected-wasm-host-key: ")) (EVar "key")))))) (EVar "actualKeys"))) (EIf (EBinOp "==" (EFieldAccess (EVar "expected") "imports") (EFieldAccess (EVar "actual") "imports")) (EListLit) (EListLit (ELit (LString "wasm-import-order"))))) (EIf (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "expected") "sourceHostKeys") (EFieldAccess (EVar "actual") "sourceHostKeys")) (EBinOp "==" (EFieldAccess (EVar "expected") "jsImports") (EFieldAccess (EVar "actual") "jsImports"))) (EListLit) (EListLit (ELit (LString "wasm-source-demand-mismatch"))))))))
(DTypeSig false "ctorToFloatIdxs" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "ctorToFloatIdxs" ((PTuple (PVar "ctor") (PVar "typeNames"))) (ETuple (EVar "ctor") (EApp (EApp (EVar "floatFieldIndices") (EVar "typeNames")) (ELit (LInt 0)))))
(DTypeSig false "floatFieldIndices" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "floatFieldIndices" ((PList) PWild) (EListLit))
(DFunDef false "floatFieldIndices" ((PCons (PLit (LString "Float")) (PVar "rest")) (PVar "i")) (EBinOp "::" (EVar "i") (EApp (EApp (EVar "floatFieldIndices") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1))))))
(DFunDef false "floatFieldIndices" ((PCons PWild (PVar "rest")) (PVar "i")) (EApp (EApp (EVar "floatFieldIndices") (EVar "rest")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))
(DTypeSig true "ctorFloatFieldIndex" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "Int")))))
(DFunDef false "ctorFloatFieldIndex" ((PVar "fields")) (EApp (EApp (EVar "omFromPairs") (EApp (EVar "reverseL") (EApp (EApp (EMethodRef "map") (EVar "ctorToFloatIdxs")) (EVar "fields")))) (EVar "omEmpty")))
(DTypeSig true "exprHasFallthrough" (TyFun (TyCon "CExpr") (TyCon "Bool")))
(DFunDef false "exprHasFallthrough" ((PCon "CVar" (PVar "x") PWild)) (EBinOp "==" (EVar "x") (ELit (LString "__fallthrough__"))))
(DFunDef false "exprHasFallthrough" ((PCon "CApp" (PVar "f") (PVar "args") PWild)) (EBinOp "||" (EApp (EVar "exprHasFallthrough") (EVar "f")) (EApp (EApp (EVar "anyList") (EVar "exprHasFallthrough")) (EVar "args"))))
(DFunDef false "exprHasFallthrough" ((PCon "CIf" (PVar "c") (PVar "t") (PVar "f"))) (EBinOp "||" (EBinOp "||" (EApp (EVar "exprHasFallthrough") (EVar "c")) (EApp (EVar "exprHasFallthrough") (EVar "t"))) (EApp (EVar "exprHasFallthrough") (EVar "f"))))
(DFunDef false "exprHasFallthrough" ((PCon "CLet" PWild PWild (PVar "e1") (PVar "e2"))) (EBinOp "||" (EApp (EVar "exprHasFallthrough") (EVar "e1")) (EApp (EVar "exprHasFallthrough") (EVar "e2"))))
(DFunDef false "exprHasFallthrough" ((PCon "CLetGroup" PWild (PVar "body"))) (EApp (EVar "exprHasFallthrough") (EVar "body")))
(DFunDef false "exprHasFallthrough" ((PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EVar "anyList") (EVar "stmtHasFallthrough")) (EVar "stmts")))
(DFunDef false "exprHasFallthrough" ((PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EBinOp "||" (EApp (EVar "exprHasFallthrough") (EVar "scrut")) (EApp (EApp (EVar "anyList") (ELam ((PVar "a")) (EApp (EVar "exprHasFallthrough") (EApp (EVar "armBody") (EVar "a"))))) (EVar "arms"))))
(DFunDef false "exprHasFallthrough" (PWild) (EVar "False"))
(DTypeSig false "stmtHasFallthrough" (TyFun (TyCon "CStmt") (TyCon "Bool")))
(DFunDef false "stmtHasFallthrough" ((PCon "CSExpr" (PVar "e"))) (EApp (EVar "exprHasFallthrough") (EVar "e")))
(DFunDef false "stmtHasFallthrough" ((PCon "CSLet" PWild PWild (PVar "e"))) (EApp (EVar "exprHasFallthrough") (EVar "e")))
(DFunDef false "stmtHasFallthrough" ((PCon "CSAssign" PWild (PVar "e"))) (EApp (EVar "exprHasFallthrough") (EVar "e")))
