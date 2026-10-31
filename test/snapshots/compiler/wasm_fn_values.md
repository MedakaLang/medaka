# META
source_lines=225
stages=DESUGAR,MARK
# SOURCE
import frontend.ast.{Pat(..), Route(..), patBoundNames}
import ir.core_ir.{
  CProgram(..), CBind(..), CClause(..), CExpr(..), CImplEntry(..),
  CImplBody(..), CArm(..), CGuard(..), CStmt(..), CField(..),
  MethodEvidence(..), CallSite(..), CallMode(..)
}
import support.ordmap.{
  OrdMap, omEmpty, omInsert, omLookup, omHasKey, omFromNames
}
import support.symbol_encoding.{encodePair}
import support.util.{startsWith}

data ValueScope = ValueScope {
  functions : OrdMap String,
  coreFunctions : OrdMap String,
  selected : OrdMap Unit,
  locals : OrdMap Unit,
}

-- The selected set is supplied by the catalog adapter; this leaf only follows
-- the boxed renderer's precedence and lexical environments.
export
fnValueUses : OrdMap Unit -> CProgram -> OrdMap Unit
fnValueUses selected (CProgram binds _ _ impls _ _) =
  let prefix = encodePair "core" ""
  let (functions, coreFunctions) =
    fold
      ((direct, core) bind =>
        let name = bindName bind
        if name == "main" || isValue bind then
          (direct, core)
        else
          (
            omInsert name name direct,
            if startsWith prefix name then
              omInsert
                (stringSlice (stringLength prefix) (stringLength name) name)
                name
                core
            else
              core,
          ))
      (omEmpty, omEmpty)
      binds
  let scope = ValueScope {
    functions = functions,
    coreFunctions = coreFunctions,
    selected = selected,
    locals = omEmpty,
  }
  fold (walkImpl scope) (fold (walkBind scope) omEmpty binds) impls

bindName : CBind -> String
bindName (CBind name _ _ _) = name

isValue : CBind -> Bool
isValue (CBind _ [CClause [] _] _ _) = True
isValue _ = False

withPats : ValueScope -> List Pat -> ValueScope
withPats scope pats = { scope |
  locals = omFromNames (flatMap patBoundNames pats) scope.locals,
}

withBinds : ValueScope -> List CBind -> ValueScope
withBinds scope binds = { scope |
  locals = omFromNames (map bindName binds) scope.locals,
}

rawSentinel : String -> Bool
rawSentinel name = name == "__fallthrough__" || startsWith "__ft__" name

noteName : ValueScope -> OrdMap Unit -> String -> OrdMap Unit
noteName scope acc name =
  if omHasKey name scope.locals then
    acc
  else match omLookup name scope.functions
    Some symbol => omInsert symbol () acc
    None => match omLookup name scope.coreFunctions
      Some symbol => omInsert symbol () acc
      None => acc

walkBind : ValueScope -> OrdMap Unit -> CBind -> OrdMap Unit
walkBind scope acc (CBind _ clauses _ _) =
  fold
    (seen (CClause pats body) => walkExpr (withPats scope pats) seen body)
    acc
    clauses

walkImpl : ValueScope -> OrdMap Unit -> CImplEntry -> OrdMap Unit
walkImpl scope acc (CImplEntry _ _ _ (CImplTagged _ _ _ _ _ pats body)) =
  walkExpr (withPats scope pats) acc body
walkImpl scope acc (CImplEntry _ _ _ (CImplDefault _ _ _ _ _ pats body)) =
  walkExpr (withPats scope pats) acc body

walkExprs : ValueScope -> OrdMap Unit -> List CExpr -> OrdMap Unit
walkExprs scope = fold (walkExpr scope)

walkFields : ValueScope -> OrdMap Unit -> List CField -> OrdMap Unit
walkFields scope = fold (acc (CField _ _ expr) => walkExpr scope acc expr)

-- Flattened arguments inherit the outer application mode, as in appParts.
walkApp : ValueScope ->
  OrdMap Unit ->
  Bool ->
  CExpr ->
  List (List CExpr) ->
  OrdMap Unit
walkApp scope acc exact (CApp head args _) pending =
  walkApp scope acc exact head (args :: pending)
walkApp scope acc exact (CVar name _) pending =
  if rawSentinel name || omHasKey name scope.selected then
    acc
  else
    fold
      (walkExprs scope)
      (if exact then acc else noteName scope acc name)
      pending
walkApp scope acc exact (CMethod method (MethodEvidence _ _ (RLocal sym dicts) _ _)) pending =
  let target = if sym == "" then method else sym
  let headUses = match dicts
    [] =>
      if not exact && omHasKey target scope.functions then
        omInsert target () acc
      else
        acc
    _ => acc
  fold (walkExprs scope) headUses pending
walkApp scope acc _ head pending =
  fold (walkExprs scope) (walkExpr scope acc head) pending

walkExpr : ValueScope -> OrdMap Unit -> CExpr -> OrdMap Unit
walkExpr _ acc (CLit _) = acc
walkExpr scope acc (CVar name _) =
  if rawSentinel name
    || not (omHasKey name scope.locals) && omHasKey name scope.selected then
    acc
  else
    noteName scope acc name
walkExpr scope acc (CApp head args (CallSite mode _)) =
  let exact = match mode
    CallExact => True
    CallPartial _ => False
    CallOver _ => False
    CallDynamic => False
  walkApp scope acc exact head [args]
walkExpr scope acc (CLam pats body) = walkExpr (withPats scope pats) acc body
walkExpr scope acc (CLet recursive pat rhs body) =
  let inner = withPats scope [pat]
  let rhsScope = if recursive then inner else scope
  walkExpr inner (walkExpr rhsScope acc rhs) body
walkExpr scope acc (CLetGroup binds body) =
  let inner = withBinds scope binds
  let functions = filter (b => not (isValue b)) binds
  let values = filter isValue binds
  let seen = fold (walkBind inner) acc functions
  let (_, seenValues) =
    fold
      ((current, seen) bind => (
        withBinds current [bind],
        walkBind current seen bind,
      ))
      (scope, seen)
      values
  walkExpr inner seenValues body
walkExpr scope acc (CMatch scrut arms) =
  fold (walkArm scope) (walkExpr scope acc scrut) arms
walkExpr scope acc (CDecision scrut arms _) =
  fold (walkArm scope) (walkExpr scope acc scrut) arms
walkExpr scope acc (CIf cond yes no) = walkExprs scope acc [cond, yes, no]
walkExpr scope acc (CBinPrim _ left right _ _) =
  walkExprs scope acc [left, right]
walkExpr scope acc (CUnOp _ expr) = walkExpr scope acc expr
walkExpr scope acc (CTuple exprs) = walkExprs scope acc exprs
walkExpr scope acc (CList exprs) = walkExprs scope acc exprs
walkExpr scope acc (CArray exprs) = walkExprs scope acc exprs
walkExpr scope acc (CRecord _ fields) = walkFields scope acc fields
walkExpr scope acc (CFieldAccess base _ _ _) = walkExpr scope acc base
walkExpr scope acc (CRecordUpdate _ base fields) =
  walkFields scope (walkExpr scope acc base) fields
walkExpr scope acc (CVariantUpdate _ base fields) =
  walkFields scope (walkExpr scope acc base) fields
walkExpr scope acc (CRangeList lo hi _) = walkExprs scope acc [lo, hi]
walkExpr scope acc (CRangeArray lo hi _) = walkExprs scope acc [lo, hi]
walkExpr scope acc (CIndex base index) = walkExprs scope acc [base, index]
walkExpr scope acc (CSlice base lo hi _) = walkExprs scope acc [base, lo, hi]
walkExpr scope acc (CStringIndex base index) = walkExprs scope acc [base, index]
walkExpr scope acc (CStringSlice base lo hi _) =
  walkExprs scope acc [base, lo, hi]
walkExpr scope acc (CListIndex base index) = walkExprs scope acc [base, index]
walkExpr scope acc (CListSlice base lo hi _) =
  walkExprs scope acc [base, lo, hi]
walkExpr scope acc (CBlock stmts) = walkBlock scope acc stmts
walkExpr _ acc (CMethod _ _) = acc
walkExpr _ acc (CDict _ _) = acc

walkGuards : ValueScope ->
  OrdMap Unit ->
  List CGuard ->
  (ValueScope, OrdMap Unit)
walkGuards scope acc [] = (scope, acc)
walkGuards scope acc ((CGBool expr) :: rest) =
  walkGuards scope (walkExpr scope acc expr) rest
walkGuards scope acc ((CGBind pat expr) :: rest) =
  walkGuards (withPats scope [pat]) (walkExpr scope acc expr) rest

walkArm : ValueScope -> OrdMap Unit -> CArm -> OrdMap Unit
walkArm scope acc (CArm pat guards body) =
  let (inner, seen) = walkGuards (withPats scope [pat]) acc guards
  walkExpr inner seen body
walkArm scope acc (CArmAlt pat guards _) =
  snd (walkGuards (withPats scope [pat]) acc guards)

walkBlock : ValueScope -> OrdMap Unit -> List CStmt -> OrdMap Unit
walkBlock _ acc [] = acc
walkBlock scope acc ((CSExpr expr) :: rest) =
  walkBlock scope (walkExpr scope acc expr) rest
walkBlock scope acc ((CSAssign _ expr) :: rest) =
  walkBlock scope (walkExpr scope acc expr) rest
walkBlock scope acc ((CSLet _ pat expr) :: rest) =
  let inner = withPats scope [pat]
  let rhsScope = match (pat, expr)
    (PVar _ _ _, CLam _ _) => inner
    _ => scope
  walkBlock inner (walkExpr rhsScope acc expr) rest
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Pat" true) (mem "Route" true) (mem "patBoundNames" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CField" true) (mem "MethodEvidence" true) (mem "CallSite" true) (mem "CallMode" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omFromNames" false))))
(DUse false (UseGroup ("support" "symbol_encoding") ((mem "encodePair" false))))
(DUse false (UseGroup ("support" "util") ((mem "startsWith" false))))
(DData Private "ValueScope" () ((variant "ValueScope" (ConNamed (field "functions" (TyApp (TyCon "OrdMap") (TyCon "String"))) (field "coreFunctions" (TyApp (TyCon "OrdMap") (TyCon "String"))) (field "selected" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "locals" (TyApp (TyCon "OrdMap") (TyCon "Unit")))))) ())
(DTypeSig true "fnValueUses" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CProgram") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "fnValueUses" ((PVar "selected") (PCon "CProgram" (PVar "binds") PWild PWild (PVar "impls") PWild PWild)) (EBlock (DoLet false false (PVar "prefix") (EApp (EApp (EVar "encodePair") (ELit (LString "core"))) (ELit (LString "")))) (DoLet false false (PTuple (PVar "functions") (PVar "coreFunctions")) (EApp (EApp (EApp (EVar "fold") (ELam ((PTuple (PVar "direct") (PVar "core")) (PVar "bind")) (EBlock (DoLet false false (PVar "name") (EApp (EVar "bindName") (EVar "bind"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "main"))) (EApp (EVar "isValue") (EVar "bind"))) (ETuple (EVar "direct") (EVar "core")) (ETuple (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "name")) (EVar "direct")) (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "name")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "name"))) (EVar "name"))) (EVar "name")) (EVar "core")) (EVar "core")))))))) (ETuple (EVar "omEmpty") (EVar "omEmpty"))) (EVar "binds"))) (DoLet false false (PVar "scope") (ERecordCreate "ValueScope" ((fa "functions" (EVar "functions")) (fa "coreFunctions" (EVar "coreFunctions")) (fa "selected" (EVar "selected")) (fa "locals" (EVar "omEmpty"))))) (DoExpr (EApp (EApp (EApp (EVar "fold") (EApp (EVar "walkImpl") (EVar "scope"))) (EApp (EApp (EApp (EVar "fold") (EApp (EVar "walkBind") (EVar "scope"))) (EVar "omEmpty")) (EVar "binds"))) (EVar "impls")))))
(DTypeSig false "bindName" (TyFun (TyCon "CBind") (TyCon "String")))
(DFunDef false "bindName" ((PCon "CBind" (PVar "name") PWild PWild PWild)) (EVar "name"))
(DTypeSig false "isValue" (TyFun (TyCon "CBind") (TyCon "Bool")))
(DFunDef false "isValue" ((PCon "CBind" PWild (PList (PCon "CClause" (PList) PWild)) PWild PWild)) (EVar "True"))
(DFunDef false "isValue" (PWild) (EVar "False"))
(DTypeSig false "withPats" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "ValueScope"))))
(DFunDef false "withPats" ((PVar "scope") (PVar "pats")) (ERecordUpdate (EVar "scope") ((fa "locals" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "flatMap") (EVar "patBoundNames")) (EVar "pats"))) (EFieldAccess (EVar "scope") "locals"))))))
(DTypeSig false "withBinds" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyCon "ValueScope"))))
(DFunDef false "withBinds" ((PVar "scope") (PVar "binds")) (ERecordUpdate (EVar "scope") ((fa "locals" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "bindName")) (EVar "binds"))) (EFieldAccess (EVar "scope") "locals"))))))
(DTypeSig false "rawSentinel" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "rawSentinel" ((PVar "name")) (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "__fallthrough__"))) (EApp (EApp (EVar "startsWith") (ELit (LString "__ft__"))) (EVar "name"))))
(DTypeSig false "noteName" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "noteName" ((PVar "scope") (PVar "acc") (PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "scope") "locals")) (EVar "acc") (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "scope") "functions")) (arm (PCon "Some" (PVar "symbol")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "symbol")) (ELit LUnit)) (EVar "acc"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "scope") "coreFunctions")) (arm (PCon "Some" (PVar "symbol")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "symbol")) (ELit LUnit)) (EVar "acc"))) (arm (PCon "None") () (EVar "acc")))))))
(DTypeSig false "walkBind" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CBind") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "walkBind" ((PVar "scope") (PVar "acc") (PCon "CBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "seen") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "walkExpr") (EApp (EApp (EVar "withPats") (EVar "scope")) (EVar "pats"))) (EVar "seen")) (EVar "body")))) (EVar "acc")) (EVar "clauses")))
(DTypeSig false "walkImpl" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CImplEntry") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "walkImpl" ((PVar "scope") (PVar "acc") (PCon "CImplEntry" PWild PWild PWild (PCon "CImplTagged" PWild PWild PWild PWild PWild (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "walkExpr") (EApp (EApp (EVar "withPats") (EVar "scope")) (EVar "pats"))) (EVar "acc")) (EVar "body")))
(DFunDef false "walkImpl" ((PVar "scope") (PVar "acc") (PCon "CImplEntry" PWild PWild PWild (PCon "CImplDefault" PWild PWild PWild PWild PWild (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "walkExpr") (EApp (EApp (EVar "withPats") (EVar "scope")) (EVar "pats"))) (EVar "acc")) (EVar "body")))
(DTypeSig false "walkExprs" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "walkExprs" ((PVar "scope")) (EApp (EVar "fold") (EApp (EVar "walkExpr") (EVar "scope"))))
(DTypeSig false "walkFields" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "walkFields" ((PVar "scope")) (EApp (EVar "fold") (ELam ((PVar "acc") (PCon "CField" PWild PWild (PVar "expr"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "expr")))))
(DTypeSig false "walkApp" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "CExpr"))) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))))
(DFunDef false "walkApp" ((PVar "scope") (PVar "acc") (PVar "exact") (PCon "CApp" (PVar "head") (PVar "args") PWild) (PVar "pending")) (EApp (EApp (EApp (EApp (EApp (EVar "walkApp") (EVar "scope")) (EVar "acc")) (EVar "exact")) (EVar "head")) (EBinOp "::" (EVar "args") (EVar "pending"))))
(DFunDef false "walkApp" ((PVar "scope") (PVar "acc") (PVar "exact") (PCon "CVar" (PVar "name") PWild) (PVar "pending")) (EIf (EBinOp "||" (EApp (EVar "rawSentinel") (EVar "name")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "scope") "selected"))) (EVar "acc") (EApp (EApp (EApp (EVar "fold") (EApp (EVar "walkExprs") (EVar "scope"))) (EIf (EVar "exact") (EVar "acc") (EApp (EApp (EApp (EVar "noteName") (EVar "scope")) (EVar "acc")) (EVar "name")))) (EVar "pending"))))
(DFunDef false "walkApp" ((PVar "scope") (PVar "acc") (PVar "exact") (PCon "CMethod" (PVar "method") (PCon "MethodEvidence" PWild PWild (PCon "RLocal" (PVar "sym") (PVar "dicts")) PWild PWild)) (PVar "pending")) (EBlock (DoLet false false (PVar "target") (EIf (EBinOp "==" (EVar "sym") (ELit (LString ""))) (EVar "method") (EVar "sym"))) (DoLet false false (PVar "headUses") (EMatch (EVar "dicts") (arm (PList) () (EIf (EBinOp "&&" (EApp (EVar "not") (EVar "exact")) (EApp (EApp (EVar "omHasKey") (EVar "target")) (EFieldAccess (EVar "scope") "functions"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "target")) (ELit LUnit)) (EVar "acc")) (EVar "acc"))) (arm PWild () (EVar "acc")))) (DoExpr (EApp (EApp (EApp (EVar "fold") (EApp (EVar "walkExprs") (EVar "scope"))) (EVar "headUses")) (EVar "pending")))))
(DFunDef false "walkApp" ((PVar "scope") (PVar "acc") PWild (PVar "head") (PVar "pending")) (EApp (EApp (EApp (EVar "fold") (EApp (EVar "walkExprs") (EVar "scope"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "head"))) (EVar "pending")))
(DTypeSig false "walkExpr" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "walkExpr" (PWild (PVar "acc") (PCon "CLit" PWild)) (EVar "acc"))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CVar" (PVar "name") PWild)) (EIf (EBinOp "||" (EApp (EVar "rawSentinel") (EVar "name")) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "scope") "locals"))) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "scope") "selected")))) (EVar "acc") (EApp (EApp (EApp (EVar "noteName") (EVar "scope")) (EVar "acc")) (EVar "name"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CApp" (PVar "head") (PVar "args") (PCon "CallSite" (PVar "mode") PWild))) (EBlock (DoLet false false (PVar "exact") (EMatch (EVar "mode") (arm (PCon "CallExact") () (EVar "True")) (arm (PCon "CallPartial" PWild) () (EVar "False")) (arm (PCon "CallOver" PWild) () (EVar "False")) (arm (PCon "CallDynamic") () (EVar "False")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "walkApp") (EVar "scope")) (EVar "acc")) (EVar "exact")) (EVar "head")) (EListLit (EVar "args"))))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "walkExpr") (EApp (EApp (EVar "withPats") (EVar "scope")) (EVar "pats"))) (EVar "acc")) (EVar "body")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CLet" (PVar "recursive") (PVar "pat") (PVar "rhs") (PVar "body"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "withPats") (EVar "scope")) (EListLit (EVar "pat")))) (DoLet false false (PVar "rhsScope") (EIf (EVar "recursive") (EVar "inner") (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EVar "walkExpr") (EVar "inner")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "rhsScope")) (EVar "acc")) (EVar "rhs"))) (EVar "body")))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "withBinds") (EVar "scope")) (EVar "binds"))) (DoLet false false (PVar "functions") (EApp (EApp (EVar "filter") (ELam ((PVar "b")) (EApp (EVar "not") (EApp (EVar "isValue") (EVar "b"))))) (EVar "binds"))) (DoLet false false (PVar "values") (EApp (EApp (EVar "filter") (EVar "isValue")) (EVar "binds"))) (DoLet false false (PVar "seen") (EApp (EApp (EApp (EVar "fold") (EApp (EVar "walkBind") (EVar "inner"))) (EVar "acc")) (EVar "functions"))) (DoLet false false (PTuple PWild (PVar "seenValues")) (EApp (EApp (EApp (EVar "fold") (ELam ((PTuple (PVar "current") (PVar "seen")) (PVar "bind")) (ETuple (EApp (EApp (EVar "withBinds") (EVar "current")) (EListLit (EVar "bind"))) (EApp (EApp (EApp (EVar "walkBind") (EVar "current")) (EVar "seen")) (EVar "bind"))))) (ETuple (EVar "scope") (EVar "seen"))) (EVar "values"))) (DoExpr (EApp (EApp (EApp (EVar "walkExpr") (EVar "inner")) (EVar "seenValues")) (EVar "body")))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EApp (EVar "fold") (EApp (EVar "walkArm") (EVar "scope"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "scrut"))) (EVar "arms")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EApp (EApp (EApp (EVar "fold") (EApp (EVar "walkArm") (EVar "scope"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "scrut"))) (EVar "arms")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CIf" (PVar "cond") (PVar "yes") (PVar "no"))) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EListLit (EVar "cond") (EVar "yes") (EVar "no"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CBinPrim" PWild (PVar "left") (PVar "right") PWild PWild)) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EListLit (EVar "left") (EVar "right"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CUnOp" PWild (PVar "expr"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "expr")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CTuple" (PVar "exprs"))) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EVar "exprs")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CList" (PVar "exprs"))) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EVar "exprs")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CArray" (PVar "exprs"))) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EVar "exprs")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CRecord" PWild (PVar "fields"))) (EApp (EApp (EApp (EVar "walkFields") (EVar "scope")) (EVar "acc")) (EVar "fields")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CFieldAccess" (PVar "base") PWild PWild PWild)) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "base")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CRecordUpdate" PWild (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "walkFields") (EVar "scope")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "base"))) (EVar "fields")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CVariantUpdate" PWild (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "walkFields") (EVar "scope")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "base"))) (EVar "fields")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EListLit (EVar "lo") (EVar "hi"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EListLit (EVar "lo") (EVar "hi"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CIndex" (PVar "base") (PVar "index"))) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EListLit (EVar "base") (EVar "index"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CSlice" (PVar "base") (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EListLit (EVar "base") (EVar "lo") (EVar "hi"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CStringIndex" (PVar "base") (PVar "index"))) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EListLit (EVar "base") (EVar "index"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CStringSlice" (PVar "base") (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EListLit (EVar "base") (EVar "lo") (EVar "hi"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CListIndex" (PVar "base") (PVar "index"))) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EListLit (EVar "base") (EVar "index"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CListSlice" (PVar "base") (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EListLit (EVar "base") (EVar "lo") (EVar "hi"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EApp (EVar "walkBlock") (EVar "scope")) (EVar "acc")) (EVar "stmts")))
(DFunDef false "walkExpr" (PWild (PVar "acc") (PCon "CMethod" PWild PWild)) (EVar "acc"))
(DFunDef false "walkExpr" (PWild (PVar "acc") (PCon "CDict" PWild PWild)) (EVar "acc"))
(DTypeSig false "walkGuards" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyTuple (TyCon "ValueScope") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "walkGuards" ((PVar "scope") (PVar "acc") (PList)) (ETuple (EVar "scope") (EVar "acc")))
(DFunDef false "walkGuards" ((PVar "scope") (PVar "acc") (PCons (PCon "CGBool" (PVar "expr")) (PVar "rest"))) (EApp (EApp (EApp (EVar "walkGuards") (EVar "scope")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "expr"))) (EVar "rest")))
(DFunDef false "walkGuards" ((PVar "scope") (PVar "acc") (PCons (PCon "CGBind" (PVar "pat") (PVar "expr")) (PVar "rest"))) (EApp (EApp (EApp (EVar "walkGuards") (EApp (EApp (EVar "withPats") (EVar "scope")) (EListLit (EVar "pat")))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "expr"))) (EVar "rest")))
(DTypeSig false "walkArm" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CArm") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "walkArm" ((PVar "scope") (PVar "acc") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "inner") (PVar "seen")) (EApp (EApp (EApp (EVar "walkGuards") (EApp (EApp (EVar "withPats") (EVar "scope")) (EListLit (EVar "pat")))) (EVar "acc")) (EVar "guards"))) (DoExpr (EApp (EApp (EApp (EVar "walkExpr") (EVar "inner")) (EVar "seen")) (EVar "body")))))
(DFunDef false "walkArm" ((PVar "scope") (PVar "acc") (PCon "CArmAlt" (PVar "pat") (PVar "guards") PWild)) (EApp (EVar "snd") (EApp (EApp (EApp (EVar "walkGuards") (EApp (EApp (EVar "withPats") (EVar "scope")) (EListLit (EVar "pat")))) (EVar "acc")) (EVar "guards"))))
(DTypeSig false "walkBlock" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "walkBlock" (PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "walkBlock" ((PVar "scope") (PVar "acc") (PCons (PCon "CSExpr" (PVar "expr")) (PVar "rest"))) (EApp (EApp (EApp (EVar "walkBlock") (EVar "scope")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "expr"))) (EVar "rest")))
(DFunDef false "walkBlock" ((PVar "scope") (PVar "acc") (PCons (PCon "CSAssign" PWild (PVar "expr")) (PVar "rest"))) (EApp (EApp (EApp (EVar "walkBlock") (EVar "scope")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "expr"))) (EVar "rest")))
(DFunDef false "walkBlock" ((PVar "scope") (PVar "acc") (PCons (PCon "CSLet" PWild (PVar "pat") (PVar "expr")) (PVar "rest"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "withPats") (EVar "scope")) (EListLit (EVar "pat")))) (DoLet false false (PVar "rhsScope") (EMatch (ETuple (EVar "pat") (EVar "expr")) (arm (PTuple (PCon "PVar" PWild PWild PWild) (PCon "CLam" PWild PWild)) () (EVar "inner")) (arm PWild () (EVar "scope")))) (DoExpr (EApp (EApp (EApp (EVar "walkBlock") (EVar "inner")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "rhsScope")) (EVar "acc")) (EVar "expr"))) (EVar "rest")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Pat" true) (mem "Route" true) (mem "patBoundNames" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CProgram" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CImplEntry" true) (mem "CImplBody" true) (mem "CArm" true) (mem "CGuard" true) (mem "CStmt" true) (mem "CField" true) (mem "MethodEvidence" true) (mem "CallSite" true) (mem "CallMode" true))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omHasKey" false) (mem "omFromNames" false))))
(DUse false (UseGroup ("support" "symbol_encoding") ((mem "encodePair" false))))
(DUse false (UseGroup ("support" "util") ((mem "startsWith" false))))
(DData Private "ValueScope" () ((variant "ValueScope" (ConNamed (field "functions" (TyApp (TyCon "OrdMap") (TyCon "String"))) (field "coreFunctions" (TyApp (TyCon "OrdMap") (TyCon "String"))) (field "selected" (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (field "locals" (TyApp (TyCon "OrdMap") (TyCon "Unit")))))) ())
(DTypeSig true "fnValueUses" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CProgram") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "fnValueUses" ((PVar "selected") (PCon "CProgram" (PVar "binds") PWild PWild (PVar "impls") PWild PWild)) (EBlock (DoLet false false (PVar "prefix") (EApp (EApp (EVar "encodePair") (ELit (LString "core"))) (ELit (LString "")))) (DoLet false false (PTuple (PVar "functions") (PVar "coreFunctions")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PTuple (PVar "direct") (PVar "core")) (PVar "bind")) (EBlock (DoLet false false (PVar "name") (EApp (EVar "bindName") (EVar "bind"))) (DoExpr (EIf (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "main"))) (EApp (EVar "isValue") (EVar "bind"))) (ETuple (EVar "direct") (EVar "core")) (ETuple (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EVar "name")) (EVar "direct")) (EIf (EApp (EApp (EVar "startsWith") (EVar "prefix")) (EVar "name")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EApp (EApp (EVar "stringSlice") (EApp (EVar "stringLength") (EVar "prefix"))) (EApp (EVar "stringLength") (EVar "name"))) (EVar "name"))) (EVar "name")) (EVar "core")) (EVar "core")))))))) (ETuple (EVar "omEmpty") (EVar "omEmpty"))) (EVar "binds"))) (DoLet false false (PVar "scope") (ERecordCreate "ValueScope" ((fa "functions" (EVar "functions")) (fa "coreFunctions" (EVar "coreFunctions")) (fa "selected" (EVar "selected")) (fa "locals" (EVar "omEmpty"))))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "walkImpl") (EVar "scope"))) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "walkBind") (EVar "scope"))) (EVar "omEmpty")) (EVar "binds"))) (EVar "impls")))))
(DTypeSig false "bindName" (TyFun (TyCon "CBind") (TyCon "String")))
(DFunDef false "bindName" ((PCon "CBind" (PVar "name") PWild PWild PWild)) (EVar "name"))
(DTypeSig false "isValue" (TyFun (TyCon "CBind") (TyCon "Bool")))
(DFunDef false "isValue" ((PCon "CBind" PWild (PList (PCon "CClause" (PList) PWild)) PWild PWild)) (EVar "True"))
(DFunDef false "isValue" (PWild) (EVar "False"))
(DTypeSig false "withPats" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "ValueScope"))))
(DFunDef false "withPats" ((PVar "scope") (PVar "pats")) (ERecordUpdate (EVar "scope") ((fa "locals" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EDictApp "flatMap") (EVar "patBoundNames")) (EVar "pats"))) (EFieldAccess (EVar "scope") "locals"))))))
(DTypeSig false "withBinds" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyCon "ValueScope"))))
(DFunDef false "withBinds" ((PVar "scope") (PVar "binds")) (ERecordUpdate (EVar "scope") ((fa "locals" (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "bindName")) (EVar "binds"))) (EFieldAccess (EVar "scope") "locals"))))))
(DTypeSig false "rawSentinel" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "rawSentinel" ((PVar "name")) (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "__fallthrough__"))) (EApp (EApp (EVar "startsWith") (ELit (LString "__ft__"))) (EVar "name"))))
(DTypeSig false "noteName" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "String") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "noteName" ((PVar "scope") (PVar "acc") (PVar "name")) (EIf (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "scope") "locals")) (EVar "acc") (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "scope") "functions")) (arm (PCon "Some" (PVar "symbol")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "symbol")) (ELit LUnit)) (EVar "acc"))) (arm (PCon "None") () (EMatch (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "scope") "coreFunctions")) (arm (PCon "Some" (PVar "symbol")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "symbol")) (ELit LUnit)) (EVar "acc"))) (arm (PCon "None") () (EVar "acc")))))))
(DTypeSig false "walkBind" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CBind") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "walkBind" ((PVar "scope") (PVar "acc") (PCon "CBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "seen") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "walkExpr") (EApp (EApp (EVar "withPats") (EVar "scope")) (EVar "pats"))) (EVar "seen")) (EVar "body")))) (EVar "acc")) (EVar "clauses")))
(DTypeSig false "walkImpl" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CImplEntry") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "walkImpl" ((PVar "scope") (PVar "acc") (PCon "CImplEntry" PWild PWild PWild (PCon "CImplTagged" PWild PWild PWild PWild PWild (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "walkExpr") (EApp (EApp (EVar "withPats") (EVar "scope")) (EVar "pats"))) (EVar "acc")) (EVar "body")))
(DFunDef false "walkImpl" ((PVar "scope") (PVar "acc") (PCon "CImplEntry" PWild PWild PWild (PCon "CImplDefault" PWild PWild PWild PWild PWild (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EVar "walkExpr") (EApp (EApp (EVar "withPats") (EVar "scope")) (EVar "pats"))) (EVar "acc")) (EVar "body")))
(DTypeSig false "walkExprs" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CExpr")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "walkExprs" ((PVar "scope")) (EApp (EMethodRef "fold") (EApp (EVar "walkExpr") (EVar "scope"))))
(DTypeSig false "walkFields" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CField")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "walkFields" ((PVar "scope")) (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PCon "CField" PWild PWild (PVar "expr"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "expr")))))
(DTypeSig false "walkApp" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyCon "CExpr") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "CExpr"))) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))))
(DFunDef false "walkApp" ((PVar "scope") (PVar "acc") (PVar "exact") (PCon "CApp" (PVar "head") (PVar "args") PWild) (PVar "pending")) (EApp (EApp (EApp (EApp (EApp (EVar "walkApp") (EVar "scope")) (EVar "acc")) (EVar "exact")) (EVar "head")) (EBinOp "::" (EVar "args") (EVar "pending"))))
(DFunDef false "walkApp" ((PVar "scope") (PVar "acc") (PVar "exact") (PCon "CVar" (PVar "name") PWild) (PVar "pending")) (EIf (EBinOp "||" (EApp (EVar "rawSentinel") (EVar "name")) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "scope") "selected"))) (EVar "acc") (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "walkExprs") (EVar "scope"))) (EIf (EVar "exact") (EVar "acc") (EApp (EApp (EApp (EVar "noteName") (EVar "scope")) (EVar "acc")) (EVar "name")))) (EVar "pending"))))
(DFunDef false "walkApp" ((PVar "scope") (PVar "acc") (PVar "exact") (PCon "CMethod" (PVar "method") (PCon "MethodEvidence" PWild PWild (PCon "RLocal" (PVar "sym") (PVar "dicts")) PWild PWild)) (PVar "pending")) (EBlock (DoLet false false (PVar "target") (EIf (EBinOp "==" (EVar "sym") (ELit (LString ""))) (EVar "method") (EVar "sym"))) (DoLet false false (PVar "headUses") (EMatch (EVar "dicts") (arm (PList) () (EIf (EBinOp "&&" (EApp (EVar "not") (EVar "exact")) (EApp (EApp (EVar "omHasKey") (EVar "target")) (EFieldAccess (EVar "scope") "functions"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "target")) (ELit LUnit)) (EVar "acc")) (EVar "acc"))) (arm PWild () (EVar "acc")))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "walkExprs") (EVar "scope"))) (EVar "headUses")) (EVar "pending")))))
(DFunDef false "walkApp" ((PVar "scope") (PVar "acc") PWild (PVar "head") (PVar "pending")) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "walkExprs") (EVar "scope"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "head"))) (EVar "pending")))
(DTypeSig false "walkExpr" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "walkExpr" (PWild (PVar "acc") (PCon "CLit" PWild)) (EVar "acc"))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CVar" (PVar "name") PWild)) (EIf (EBinOp "||" (EApp (EVar "rawSentinel") (EVar "name")) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "scope") "locals"))) (EApp (EApp (EVar "omHasKey") (EVar "name")) (EFieldAccess (EVar "scope") "selected")))) (EVar "acc") (EApp (EApp (EApp (EVar "noteName") (EVar "scope")) (EVar "acc")) (EVar "name"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CApp" (PVar "head") (PVar "args") (PCon "CallSite" (PVar "mode") PWild))) (EBlock (DoLet false false (PVar "exact") (EMatch (EVar "mode") (arm (PCon "CallExact") () (EVar "True")) (arm (PCon "CallPartial" PWild) () (EVar "False")) (arm (PCon "CallOver" PWild) () (EVar "False")) (arm (PCon "CallDynamic") () (EVar "False")))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "walkApp") (EVar "scope")) (EVar "acc")) (EVar "exact")) (EVar "head")) (EListLit (EVar "args"))))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EApp (EVar "walkExpr") (EApp (EApp (EVar "withPats") (EVar "scope")) (EVar "pats"))) (EVar "acc")) (EVar "body")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CLet" (PVar "recursive") (PVar "pat") (PVar "rhs") (PVar "body"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "withPats") (EVar "scope")) (EListLit (EVar "pat")))) (DoLet false false (PVar "rhsScope") (EIf (EVar "recursive") (EVar "inner") (EVar "scope"))) (DoExpr (EApp (EApp (EApp (EVar "walkExpr") (EVar "inner")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "rhsScope")) (EVar "acc")) (EVar "rhs"))) (EVar "body")))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "withBinds") (EVar "scope")) (EVar "binds"))) (DoLet false false (PVar "functions") (EApp (EApp (EMethodRef "filter") (ELam ((PVar "b")) (EApp (EVar "not") (EApp (EVar "isValue") (EVar "b"))))) (EVar "binds"))) (DoLet false false (PVar "values") (EApp (EApp (EMethodRef "filter") (EVar "isValue")) (EVar "binds"))) (DoLet false false (PVar "seen") (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "walkBind") (EVar "inner"))) (EVar "acc")) (EVar "functions"))) (DoLet false false (PTuple PWild (PVar "seenValues")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PTuple (PVar "current") (PVar "seen")) (PVar "bind")) (ETuple (EApp (EApp (EVar "withBinds") (EVar "current")) (EListLit (EVar "bind"))) (EApp (EApp (EApp (EVar "walkBind") (EVar "current")) (EVar "seen")) (EVar "bind"))))) (ETuple (EVar "scope") (EVar "seen"))) (EVar "values"))) (DoExpr (EApp (EApp (EApp (EVar "walkExpr") (EVar "inner")) (EVar "seenValues")) (EVar "body")))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "walkArm") (EVar "scope"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "scrut"))) (EVar "arms")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "walkArm") (EVar "scope"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "scrut"))) (EVar "arms")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CIf" (PVar "cond") (PVar "yes") (PVar "no"))) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EListLit (EVar "cond") (EVar "yes") (EVar "no"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CBinPrim" PWild (PVar "left") (PVar "right") PWild PWild)) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EListLit (EVar "left") (EVar "right"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CUnOp" PWild (PVar "expr"))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "expr")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CTuple" (PVar "exprs"))) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EVar "exprs")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CList" (PVar "exprs"))) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EVar "exprs")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CArray" (PVar "exprs"))) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EVar "exprs")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CRecord" PWild (PVar "fields"))) (EApp (EApp (EApp (EVar "walkFields") (EVar "scope")) (EVar "acc")) (EVar "fields")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CFieldAccess" (PVar "base") PWild PWild PWild)) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "base")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CRecordUpdate" PWild (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "walkFields") (EVar "scope")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "base"))) (EVar "fields")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CVariantUpdate" PWild (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "walkFields") (EVar "scope")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "base"))) (EVar "fields")))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CRangeList" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EListLit (EVar "lo") (EVar "hi"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EListLit (EVar "lo") (EVar "hi"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CIndex" (PVar "base") (PVar "index"))) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EListLit (EVar "base") (EMethodRef "index"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CSlice" (PVar "base") (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EListLit (EVar "base") (EVar "lo") (EVar "hi"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CStringIndex" (PVar "base") (PVar "index"))) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EListLit (EVar "base") (EMethodRef "index"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CStringSlice" (PVar "base") (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EListLit (EVar "base") (EVar "lo") (EVar "hi"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CListIndex" (PVar "base") (PVar "index"))) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EListLit (EVar "base") (EMethodRef "index"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CListSlice" (PVar "base") (PVar "lo") (PVar "hi") PWild)) (EApp (EApp (EApp (EVar "walkExprs") (EVar "scope")) (EVar "acc")) (EListLit (EVar "base") (EVar "lo") (EVar "hi"))))
(DFunDef false "walkExpr" ((PVar "scope") (PVar "acc") (PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EApp (EVar "walkBlock") (EVar "scope")) (EVar "acc")) (EVar "stmts")))
(DFunDef false "walkExpr" (PWild (PVar "acc") (PCon "CMethod" PWild PWild)) (EVar "acc"))
(DFunDef false "walkExpr" (PWild (PVar "acc") (PCon "CDict" PWild PWild)) (EVar "acc"))
(DTypeSig false "walkGuards" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyTuple (TyCon "ValueScope") (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "walkGuards" ((PVar "scope") (PVar "acc") (PList)) (ETuple (EVar "scope") (EVar "acc")))
(DFunDef false "walkGuards" ((PVar "scope") (PVar "acc") (PCons (PCon "CGBool" (PVar "expr")) (PVar "rest"))) (EApp (EApp (EApp (EVar "walkGuards") (EVar "scope")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "expr"))) (EVar "rest")))
(DFunDef false "walkGuards" ((PVar "scope") (PVar "acc") (PCons (PCon "CGBind" (PVar "pat") (PVar "expr")) (PVar "rest"))) (EApp (EApp (EApp (EVar "walkGuards") (EApp (EApp (EVar "withPats") (EVar "scope")) (EListLit (EVar "pat")))) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "expr"))) (EVar "rest")))
(DTypeSig false "walkArm" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CArm") (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "walkArm" ((PVar "scope") (PVar "acc") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "inner") (PVar "seen")) (EApp (EApp (EApp (EVar "walkGuards") (EApp (EApp (EVar "withPats") (EVar "scope")) (EListLit (EVar "pat")))) (EVar "acc")) (EVar "guards"))) (DoExpr (EApp (EApp (EApp (EVar "walkExpr") (EVar "inner")) (EVar "seen")) (EVar "body")))))
(DFunDef false "walkArm" ((PVar "scope") (PVar "acc") (PCon "CArmAlt" (PVar "pat") (PVar "guards") PWild)) (EApp (EVar "snd") (EApp (EApp (EApp (EVar "walkGuards") (EApp (EApp (EVar "withPats") (EVar "scope")) (EListLit (EVar "pat")))) (EVar "acc")) (EVar "guards"))))
(DTypeSig false "walkBlock" (TyFun (TyCon "ValueScope") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyApp (TyCon "OrdMap") (TyCon "Unit"))))))
(DFunDef false "walkBlock" (PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "walkBlock" ((PVar "scope") (PVar "acc") (PCons (PCon "CSExpr" (PVar "expr")) (PVar "rest"))) (EApp (EApp (EApp (EVar "walkBlock") (EVar "scope")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "expr"))) (EVar "rest")))
(DFunDef false "walkBlock" ((PVar "scope") (PVar "acc") (PCons (PCon "CSAssign" PWild (PVar "expr")) (PVar "rest"))) (EApp (EApp (EApp (EVar "walkBlock") (EVar "scope")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "scope")) (EVar "acc")) (EVar "expr"))) (EVar "rest")))
(DFunDef false "walkBlock" ((PVar "scope") (PVar "acc") (PCons (PCon "CSLet" PWild (PVar "pat") (PVar "expr")) (PVar "rest"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "withPats") (EVar "scope")) (EListLit (EVar "pat")))) (DoLet false false (PVar "rhsScope") (EMatch (ETuple (EVar "pat") (EVar "expr")) (arm (PTuple (PCon "PVar" PWild PWild PWild) (PCon "CLam" PWild PWild)) () (EVar "inner")) (arm PWild () (EVar "scope")))) (DoExpr (EApp (EApp (EApp (EVar "walkBlock") (EVar "inner")) (EApp (EApp (EApp (EVar "walkExpr") (EVar "rhsScope")) (EVar "acc")) (EVar "expr"))) (EVar "rest")))))
