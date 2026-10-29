# META
source_lines=302
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-if-max-min: an `if` that selects the larger or smaller of two operands. Prefer `max`/`min`.

import frontend.ast.{
  Loc(..), Guard(..), Arm(..), ImplMethod(..), DoStmt(..), Section(..),
  InterpPart(..), GuardArm(..), FieldAssign(..), LetBind(..), FunClause(..),
  Expr(..), Decl(..)
}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import tools.printer.{exprToString}
import ir.sexp.{exprSexp}
import frontend.exhaust.{Oracle}
import tools.lint_core.{
  Category(..),
  FileFacts(..),
  Finding(..),
  Fixability(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  mkRule,
}
import tools.lint_shared.{
  childExprs,
  declLocList,
  implMethodsBodyKey,
  ruleNameIfMaxMin,
  unwrapLoc,
}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameIfMaxMin,
      summary =
        "if-then-else selects the larger/smaller of the same two operands. Prefer `max`/`min`",
      doc =
        "An `if` that picks the larger or smaller of two operands is `max` or `min`.\n\nBefore:\n  if a > b then a else b\nAfter:\n  max a b",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleIfMaxMin
    (Some ifMaxMinFix)

-- ── rule: if-max-min (an `if` selecting the larger/smaller of two operands) ────
-- `if a > b then a else b` (and the >=/</<=/reversed-branch variants) select the
-- SAME two operands as the comparison — rewritable to the canonical `max`/`min`
-- prelude methods (always in-scope `Ord` methods).
--
-- CONSERVATISM (a false positive here CORRUPTS code):
--   * the condition must be a comparison `EBinOp` with op in {>, >=, <, <=} —
--     symbolic ops only (backtick `EInfix` comparisons are a DIFFERENT node and
--     are not handled).
--   * `then`/`else` must each be STRUCTURALLY EQUAL (via `ir.sexp.exprSexp`,
--     which already strips source locations — the same comparator
--     `rule-duplicate-body` uses) to one of the two comparison operands, and
--     together must cover BOTH operands (one branch keys to `a`, the other to
--     `b`) — so `if x < 0 then 0 else x` (0 is not an operand) and
--     `if a > b then a else c` (c isn't b) both skip.
--   * if the two operands are themselves structurally identical, skip (the
--     rewrite is a no-op / degenerate — nothing to gain, and it hides which
--     operand the rule "picked").
-- The check walks the WHOLE decl expression tree (an `if` can nest anywhere) —
-- including impl-method bodies; the fix rebuilds the tree converting every
-- eligible `if` to a `max`/`min` application.

-- true for the four symbolic comparison operators this rule handles.
ifMaxMinCompareOp : String -> Bool
ifMaxMinCompareOp op = op == ">" || op == ">=" || op == "<" || op == "<="

-- which prelude fn the idiom collapses to when `then` keys to the LEFT operand
-- and `else` keys to the RIGHT operand (the "normal" orientation).
ifMaxMinFnNormal : String -> String
ifMaxMinFnNormal op
  | op == ">" || op == ">=" = "max"
  | otherwise = "min"

-- ...and when the branches are REVERSED (`then` keys to the right operand).
ifMaxMinFnReversed : String -> String
ifMaxMinFnReversed op
  | op == ">" || op == ">=" = "min"
  | otherwise = "max"

-- a bare literal operand (`ELit`/`ENumLit`) disqualifies the idiom — a
-- clamp-to-constant shape like `if x < 0 then 0 else x` (max x 0) reads as a
-- deliberate clamp, not the "same two operands" max/min idiom this rule
-- targets, so it is conservatively left alone.
isLiteralExpr : Expr -> Bool
isLiteralExpr e = match unwrapLoc e
  ELit _ => True
  ENumLit _ _ _ => True
  EWideLit _ _ _ _ => True
  _ => False

-- does `EIf cond t el` match the idiom?  Returns the prelude fn name plus the
-- comparison's left/right operands (always emitted left-then-right, regardless
-- of which branch order matched) — or `None` if not eligible.
ifMaxMinOf : Expr -> Expr -> Expr -> Option (String, Expr, Expr)
ifMaxMinOf cond t el = match unwrapLoc cond
  EBinOp op a b _ if ifMaxMinCompareOp op =>
    let aK = exprSexp a
    let bK = exprSexp b
    let tK = exprSexp t
    let eK = exprSexp el
    if aK == bK || isLiteralExpr a || isLiteralExpr b then
      None
    else if tK == aK && eK == bK then
      Some (ifMaxMinFnNormal op, a, b)
    else if tK == bK && eK == aK then
      Some (ifMaxMinFnReversed op, a, b)
    else
      None
  _ => None

-- ── check ─────────────────────────────────────────────────────────────────────
ruleIfMaxMin : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleIfMaxMin _ _ _ pos prog = flatMap ifMaxMinDeclL (declLocList pos prog)

ifMaxMinDeclL : (Decl, Option Loc) -> List Finding
ifMaxMinDeclL (d, loc) = map (ifMaxMinFinding loc) (declIfMaxMinHits d)

declIfMaxMinHits : Decl -> List (String, Expr, Expr)
declIfMaxMinHits (DFunDef _ _ _ body _ _) = collectIfMaxMinHits body
declIfMaxMinHits (DImpl { methods, ... }) =
  flatMap implMethodIfMaxMinHits methods
declIfMaxMinHits (DAttrib _ d) = declIfMaxMinHits d
declIfMaxMinHits _ = []

implMethodIfMaxMinHits : ImplMethod -> List (String, Expr, Expr)
implMethodIfMaxMinHits (ImplMethod _ _ body) = collectIfMaxMinHits body

-- every eligible `if` anywhere in the expression tree (order irrelevant).
collectIfMaxMinHits : Expr -> List (String, Expr, Expr)
collectIfMaxMinHits e =
  ifMaxMinHitOf e ++ flatMap collectIfMaxMinHits (childExprs e)

ifMaxMinHitOf : Expr -> List (String, Expr, Expr)
ifMaxMinHitOf (EIf cond t el) = optHitToList (ifMaxMinOf cond t el)
ifMaxMinHitOf _ = []

optHitToList : Option (String, Expr, Expr) -> List (String, Expr, Expr)
optHitToList (Some h) = [h]
optHitToList None = []

ifMaxMinFinding : Option Loc -> (String, Expr, Expr) -> Finding
ifMaxMinFinding loc (fn, a, b) = Finding {
  rule = ruleNameIfMaxMin,
  message =
    "if-then-else selects the \{if fn == "max" then "larger" else "smaller"} of the same two operands. Rewrite as '\{exprToString (EApp (EApp (EVar fn) a) b)}'",
  severity = SevWarning,
  loc = loc,
}

-- ── autofix ───────────────────────────────────────────────────────────────────
-- Rebuild the decl body converting every eligible `if` to a `max`/`min` call.
-- Detects "did anything change" by comparing the location-stripped sexp of old
-- vs new (same technique `lambdaSectionFix` uses).
ifMaxMinFix : Oracle -> Decl -> Option (List Decl)
ifMaxMinFix _ (DFunDef vis name pats body site bid) =
  let body2 = rewriteIfMaxMinExpr body
  if exprSexp body2 == exprSexp body then
    None
  else
    Some [DFunDef vis name pats body2 site bid]
ifMaxMinFix orc (DAttrib a d) = match ifMaxMinFix orc d
  Some [d2] => Some [DAttrib a d2]
  _ => None
ifMaxMinFix _ (d@(DImpl { implOrigin = _, methods })) =
  let methods2 = map fixImplMethodIfMaxMin methods
  if implMethodsBodyKey methods2 == implMethodsBodyKey methods then
    None
  else
    -- #1110: record UPDATE — re-synthesising would reset the acquired identity.
    Some [DImpl { d | methods = methods2 }]
ifMaxMinFix _ _ = None

fixImplMethodIfMaxMin : ImplMethod -> ImplMethod
fixImplMethodIfMaxMin (ImplMethod nm ps body) =
  ImplMethod nm ps (rewriteIfMaxMinExpr body)

-- if a rewritten `if` is an eligible max/min shape, collapse it; else keep it.
tryIfMaxMin : Expr -> Expr -> Expr -> Expr
tryIfMaxMin cond t el = match ifMaxMinOf cond t el
  Some (fn, a, b) => EApp (EApp (EVar fn) a) b
  None => EIf cond t el

-- recursively rewrite children (bottom-up), then collapse THIS `if` if eligible.
rewriteIfMaxMinExpr : Expr -> Expr
rewriteIfMaxMinExpr (ELoc l e) = ELoc l (rewriteIfMaxMinExpr e)
rewriteIfMaxMinExpr (EDoOrigin l e) = EDoOrigin l (rewriteIfMaxMinExpr e)
rewriteIfMaxMinExpr (EApp f x) =
  EApp (rewriteIfMaxMinExpr f) (rewriteIfMaxMinExpr x)
rewriteIfMaxMinExpr (ELam ps b) = ELam ps (rewriteIfMaxMinExpr b)
rewriteIfMaxMinExpr (ELet m isf p e1 e2) =
  ELet m isf p (rewriteIfMaxMinExpr e1) (rewriteIfMaxMinExpr e2)
rewriteIfMaxMinExpr (EMatch s arms) =
  EMatch (rewriteIfMaxMinExpr s) (map rewriteIfMaxMinArm arms)
rewriteIfMaxMinExpr (EIf c t el) =
  tryIfMaxMin
    (rewriteIfMaxMinExpr c)
    (rewriteIfMaxMinExpr t)
    (rewriteIfMaxMinExpr el)
rewriteIfMaxMinExpr (EBinOp op a b r) =
  EBinOp op (rewriteIfMaxMinExpr a) (rewriteIfMaxMinExpr b) r
rewriteIfMaxMinExpr (EUnOp op a r) = EUnOp op (rewriteIfMaxMinExpr a) r
rewriteIfMaxMinExpr (EInfix op a b) =
  EInfix op (rewriteIfMaxMinExpr a) (rewriteIfMaxMinExpr b)
rewriteIfMaxMinExpr (EFieldAccess e f r) =
  EFieldAccess (rewriteIfMaxMinExpr e) f r
rewriteIfMaxMinExpr (ETuple es) = ETuple (map rewriteIfMaxMinExpr es)
rewriteIfMaxMinExpr (EListLit es) = EListLit (map rewriteIfMaxMinExpr es)
rewriteIfMaxMinExpr (EArrayLit es) = EArrayLit (map rewriteIfMaxMinExpr es)
rewriteIfMaxMinExpr (ERangeList lo hi i) =
  ERangeList (rewriteIfMaxMinExpr lo) (rewriteIfMaxMinExpr hi) i
rewriteIfMaxMinExpr (ERangeArray lo hi i) =
  ERangeArray (rewriteIfMaxMinExpr lo) (rewriteIfMaxMinExpr hi) i
rewriteIfMaxMinExpr (ESlice e lo hi i) =
  ESlice
    (rewriteIfMaxMinExpr e)
    (rewriteIfMaxMinExpr lo)
    (rewriteIfMaxMinExpr hi)
    i
rewriteIfMaxMinExpr (ELetGroup binds body) =
  ELetGroup (map rewriteIfMaxMinLet binds) (rewriteIfMaxMinExpr body)
rewriteIfMaxMinExpr (ESection s) = ESection (rewriteIfMaxMinSection s)
rewriteIfMaxMinExpr (EIndex a i) =
  EIndex (rewriteIfMaxMinExpr a) (rewriteIfMaxMinExpr i)
rewriteIfMaxMinExpr (EAnnot e t) = EAnnot (rewriteIfMaxMinExpr e) t
rewriteIfMaxMinExpr (EHeadAnnot e t) = EHeadAnnot (rewriteIfMaxMinExpr e) t
rewriteIfMaxMinExpr (EBlock stmts) = EBlock (map rewriteIfMaxMinStmt stmts)
rewriteIfMaxMinExpr (EDo d stmts) = EDo d (map rewriteIfMaxMinStmt stmts)
rewriteIfMaxMinExpr (EStringInterp parts) =
  EStringInterp (map rewriteIfMaxMinInterp parts)
rewriteIfMaxMinExpr (EGuards arms) = EGuards (map rewriteIfMaxMinGuardArm arms)
rewriteIfMaxMinExpr (ERecordCreate n fs) =
  ERecordCreate n (map rewriteIfMaxMinField fs)
rewriteIfMaxMinExpr (ERecordUpdate e fs r) =
  ERecordUpdate (rewriteIfMaxMinExpr e) (map rewriteIfMaxMinField fs) r
rewriteIfMaxMinExpr (EVariantUpdate c e fs) =
  EVariantUpdate c (rewriteIfMaxMinExpr e) (map rewriteIfMaxMinField fs)
rewriteIfMaxMinExpr (EMapLit n kvs) = EMapLit n (map rewriteIfMaxMinKv kvs)
rewriteIfMaxMinExpr (ESetLit n es) = ESetLit n (map rewriteIfMaxMinExpr es)
rewriteIfMaxMinExpr (EAsPat x e) = EAsPat x (rewriteIfMaxMinExpr e)
rewriteIfMaxMinExpr (EOrPat es) = EOrPat (map rewriteIfMaxMinExpr es)
rewriteIfMaxMinExpr e = e

rewriteIfMaxMinStmt : DoStmt -> DoStmt
rewriteIfMaxMinStmt (DoExpr e) = DoExpr (rewriteIfMaxMinExpr e)
rewriteIfMaxMinStmt (DoBind p e) = DoBind p (rewriteIfMaxMinExpr e)
rewriteIfMaxMinStmt (DoLet m r p e site) =
  DoLet m r p (rewriteIfMaxMinExpr e) site
rewriteIfMaxMinStmt (DoAssign x e) = DoAssign x (rewriteIfMaxMinExpr e)
rewriteIfMaxMinStmt (DoFieldAssign x fs e) =
  DoFieldAssign x fs (rewriteIfMaxMinExpr e)

rewriteIfMaxMinArm : Arm -> Arm
rewriteIfMaxMinArm (Arm p gs body) =
  Arm p (map rewriteIfMaxMinGuard gs) (rewriteIfMaxMinExpr body)

rewriteIfMaxMinGuard : Guard -> Guard
rewriteIfMaxMinGuard (GBool e) = GBool (rewriteIfMaxMinExpr e)
rewriteIfMaxMinGuard (GBind p e) = GBind p (rewriteIfMaxMinExpr e)

rewriteIfMaxMinLet : LetBind -> LetBind
rewriteIfMaxMinLet (LetBind n clauses site bid) =
  LetBind n (map rewriteIfMaxMinClause clauses) site bid

rewriteIfMaxMinClause : FunClause -> FunClause
rewriteIfMaxMinClause (FunClause ps body) =
  FunClause ps (rewriteIfMaxMinExpr body)

rewriteIfMaxMinSection : Section -> Section
rewriteIfMaxMinSection (SecBare op) = SecBare op
rewriteIfMaxMinSection (SecRight op e) = SecRight op (rewriteIfMaxMinExpr e)
rewriteIfMaxMinSection (SecLeft e op) = SecLeft (rewriteIfMaxMinExpr e) op

rewriteIfMaxMinInterp : InterpPart -> InterpPart
rewriteIfMaxMinInterp (InterpStr s) = InterpStr s
rewriteIfMaxMinInterp (InterpExpr e) = InterpExpr (rewriteIfMaxMinExpr e)

rewriteIfMaxMinGuardArm : GuardArm -> GuardArm
rewriteIfMaxMinGuardArm (GuardArm gs body) =
  GuardArm (map rewriteIfMaxMinGuard gs) (rewriteIfMaxMinExpr body)

rewriteIfMaxMinField : FieldAssign -> FieldAssign
rewriteIfMaxMinField (FieldAssign n e) = FieldAssign n (rewriteIfMaxMinExpr e)

rewriteIfMaxMinKv : (Expr, Expr) -> (Expr, Expr)
rewriteIfMaxMinKv (k, v) = (rewriteIfMaxMinExpr k, rewriteIfMaxMinExpr v)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Guard" true) (mem "Arm" true) (mem "ImplMethod" true) (mem "DoStmt" true) (mem "Section" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "LetBind" true) (mem "FunClause" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "childExprs" false) (mem "declLocList" false) (mem "implMethodsBodyKey" false) (mem "ruleNameIfMaxMin" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameIfMaxMin")) (fa "summary" (ELit (LString "if-then-else selects the larger/smaller of the same two operands. Prefer `max`/`min`"))) (fa "doc" (ELit (LString "An `if` that picks the larger or smaller of two operands is `max` or `min`.\n\nBefore:\n  if a > b then a else b\nAfter:\n  max a b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleIfMaxMin")) (EApp (EVar "Some") (EVar "ifMaxMinFix"))))
(DTypeSig false "ifMaxMinCompareOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "ifMaxMinCompareOp" ((PVar "op")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EBinOp "==" (EVar "op") (ELit (LString ">=")))) (EBinOp "==" (EVar "op") (ELit (LString "<")))) (EBinOp "==" (EVar "op") (ELit (LString "<=")))))
(DTypeSig false "ifMaxMinFnNormal" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ifMaxMinFnNormal" ((PVar "op")) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EBinOp "==" (EVar "op") (ELit (LString ">=")))) (ELit (LString "max")) (EIf (EVar "otherwise") (ELit (LString "min")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ifMaxMinFnReversed" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ifMaxMinFnReversed" ((PVar "op")) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EBinOp "==" (EVar "op") (ELit (LString ">=")))) (ELit (LString "min")) (EIf (EVar "otherwise") (ELit (LString "max")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isLiteralExpr" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isLiteralExpr" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELit" PWild) () (EVar "True")) (arm (PCon "ENumLit" PWild PWild PWild) () (EVar "True")) (arm (PCon "EWideLit" PWild PWild PWild PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "ifMaxMinOf" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))))
(DFunDef false "ifMaxMinOf" ((PVar "cond") (PVar "t") (PVar "el")) (EMatch (EApp (EVar "unwrapLoc") (EVar "cond")) (arm (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild) ((GBool (EApp (EVar "ifMaxMinCompareOp") (EVar "op")))) (EBlock (DoLet false false (PVar "aK") (EApp (EVar "exprSexp") (EVar "a"))) (DoLet false false (PVar "bK") (EApp (EVar "exprSexp") (EVar "b"))) (DoLet false false (PVar "tK") (EApp (EVar "exprSexp") (EVar "t"))) (DoLet false false (PVar "eK") (EApp (EVar "exprSexp") (EVar "el"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "aK") (EVar "bK")) (EApp (EVar "isLiteralExpr") (EVar "a"))) (EApp (EVar "isLiteralExpr") (EVar "b"))) (EVar "None") (EIf (EBinOp "&&" (EBinOp "==" (EVar "tK") (EVar "aK")) (EBinOp "==" (EVar "eK") (EVar "bK"))) (EApp (EVar "Some") (ETuple (EApp (EVar "ifMaxMinFnNormal") (EVar "op")) (EVar "a") (EVar "b"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "tK") (EVar "bK")) (EBinOp "==" (EVar "eK") (EVar "aK"))) (EApp (EVar "Some") (ETuple (EApp (EVar "ifMaxMinFnReversed") (EVar "op")) (EVar "a") (EVar "b"))) (EVar "None"))))))) (arm PWild () (EVar "None"))))
(DTypeSig false "ruleIfMaxMin" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleIfMaxMin" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "ifMaxMinDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "ifMaxMinDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "ifMaxMinDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EVar "map") (EApp (EVar "ifMaxMinFinding") (EVar "loc"))) (EApp (EVar "declIfMaxMinHits") (EVar "d"))))
(DTypeSig false "declIfMaxMinHits" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "declIfMaxMinHits" ((PCon "DFunDef" PWild PWild PWild (PVar "body") PWild PWild)) (EApp (EVar "collectIfMaxMinHits") (EVar "body")))
(DFunDef false "declIfMaxMinHits" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EVar "implMethodIfMaxMinHits")) (EVar "methods")))
(DFunDef false "declIfMaxMinHits" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declIfMaxMinHits") (EVar "d")))
(DFunDef false "declIfMaxMinHits" (PWild) (EListLit))
(DTypeSig false "implMethodIfMaxMinHits" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "implMethodIfMaxMinHits" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "collectIfMaxMinHits") (EVar "body")))
(DTypeSig false "collectIfMaxMinHits" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "collectIfMaxMinHits" ((PVar "e")) (EBinOp "++" (EApp (EVar "ifMaxMinHitOf") (EVar "e")) (EApp (EApp (EVar "flatMap") (EVar "collectIfMaxMinHits")) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "ifMaxMinHitOf" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "ifMaxMinHitOf" ((PCon "EIf" (PVar "cond") (PVar "t") (PVar "el"))) (EApp (EVar "optHitToList") (EApp (EApp (EApp (EVar "ifMaxMinOf") (EVar "cond")) (EVar "t")) (EVar "el"))))
(DFunDef false "ifMaxMinHitOf" (PWild) (EListLit))
(DTypeSig false "optHitToList" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "optHitToList" ((PCon "Some" (PVar "h"))) (EListLit (EVar "h")))
(DFunDef false "optHitToList" ((PCon "None")) (EListLit))
(DTypeSig false "ifMaxMinFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")) (TyCon "Finding"))))
(DFunDef false "ifMaxMinFinding" ((PVar "loc") (PTuple (PVar "fn") (PVar "a") (PVar "b"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameIfMaxMin")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if-then-else selects the ")) (EApp (EVar "display") (EIf (EBinOp "==" (EVar "fn") (ELit (LString "max"))) (ELit (LString "larger")) (ELit (LString "smaller"))))) (ELit (LString " of the same two operands. Rewrite as '"))) (EApp (EVar "display") (EApp (EVar "exprToString") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EVar "a"))) (EVar "b"))))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "ifMaxMinFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "ifMaxMinFix" (PWild (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body") (PVar "site") (PVar "bid"))) (EBlock (DoLet false false (PVar "body2") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2")) (EVar "site")) (EVar "bid"))))))))
(DFunDef false "ifMaxMinFix" ((PVar "orc") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EVar "ifMaxMinFix") (EVar "orc")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "ifMaxMinFix" (PWild (PAs "d" (PRec "DImpl" ((rf "implOrigin" PWild) (rf "methods" None)) false))) (EBlock (DoLet false false (PVar "methods2") (EApp (EApp (EVar "map") (EVar "fixImplMethodIfMaxMin")) (EVar "methods"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "implMethodsBodyKey") (EVar "methods2")) (EApp (EVar "implMethodsBodyKey") (EVar "methods"))) (EVar "None") (EApp (EVar "Some") (EListLit (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EVar "methods2"))))))))))
(DFunDef false "ifMaxMinFix" (PWild PWild) (EVar "None"))
(DTypeSig false "fixImplMethodIfMaxMin" (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))
(DFunDef false "fixImplMethodIfMaxMin" ((PCon "ImplMethod" (PVar "nm") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "ps")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))))
(DTypeSig false "tryIfMaxMin" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "tryIfMaxMin" ((PVar "cond") (PVar "t") (PVar "el")) (EMatch (EApp (EApp (EApp (EVar "ifMaxMinOf") (EVar "cond")) (EVar "t")) (EVar "el")) (arm (PCon "Some" (PTuple (PVar "fn") (PVar "a") (PVar "b"))) () (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EVar "a"))) (EVar "b"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "EIf") (EVar "cond")) (EVar "t")) (EVar "el")))))
(DTypeSig false "rewriteIfMaxMinExpr" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "f"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "x"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "b"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ELet" (PVar "m") (PVar "isf") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isf")) (EVar "p")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e1"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e2"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EMatch" (PVar "s") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "s"))) (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinArm")) (EVar "arms"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "tryIfMaxMin") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "c"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "t"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "el"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "a"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "b"))) (EVar "r")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "a"))) (EVar "r")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "a"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "b"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EVar "f")) (EVar "r")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinExpr")) (EVar "es"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinExpr")) (EVar "es"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinExpr")) (EVar "es"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "lo"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "lo"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "lo"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinLet")) (EVar "binds"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EVar "rewriteIfMaxMinSection") (EVar "s"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "EIndex") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "a"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "i"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EHeadAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinStmt")) (EVar "stmts"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "d")) (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinStmt")) (EVar "stmts"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinInterp")) (EVar "parts"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinGuardArm")) (EVar "arms"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinField")) (EVar "fs"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinField")) (EVar "fs"))) (EVar "r")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinField")) (EVar "fs"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinKv")) (EVar "kvs"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinExpr")) (EVar "es"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EOrPat" (PVar "es"))) (EApp (EVar "EOrPat") (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinExpr")) (EVar "es"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PVar "e")) (EVar "e"))
(DTypeSig false "rewriteIfMaxMinStmt" (TyFun (TyCon "DoStmt") (TyCon "DoStmt")))
(DFunDef false "rewriteIfMaxMinStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinStmt" ((PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinStmt" ((PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EVar "site")))
(DFunDef false "rewriteIfMaxMinStmt" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinStmt" ((PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DTypeSig false "rewriteIfMaxMinArm" (TyFun (TyCon "Arm") (TyCon "Arm")))
(DFunDef false "rewriteIfMaxMinArm" ((PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinGuard")) (EVar "gs"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))))
(DTypeSig false "rewriteIfMaxMinGuard" (TyFun (TyCon "Guard") (TyCon "Guard")))
(DFunDef false "rewriteIfMaxMinGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinGuard" ((PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DTypeSig false "rewriteIfMaxMinLet" (TyFun (TyCon "LetBind") (TyCon "LetBind")))
(DFunDef false "rewriteIfMaxMinLet" ((PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinClause")) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "rewriteIfMaxMinClause" (TyFun (TyCon "FunClause") (TyCon "FunClause")))
(DFunDef false "rewriteIfMaxMinClause" ((PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))))
(DTypeSig false "rewriteIfMaxMinSection" (TyFun (TyCon "Section") (TyCon "Section")))
(DFunDef false "rewriteIfMaxMinSection" ((PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "rewriteIfMaxMinSection" ((PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinSection" ((PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EVar "op")))
(DTypeSig false "rewriteIfMaxMinInterp" (TyFun (TyCon "InterpPart") (TyCon "InterpPart")))
(DFunDef false "rewriteIfMaxMinInterp" ((PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "rewriteIfMaxMinInterp" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DTypeSig false "rewriteIfMaxMinGuardArm" (TyFun (TyCon "GuardArm") (TyCon "GuardArm")))
(DFunDef false "rewriteIfMaxMinGuardArm" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EVar "map") (EVar "rewriteIfMaxMinGuard")) (EVar "gs"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))))
(DTypeSig false "rewriteIfMaxMinField" (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign")))
(DFunDef false "rewriteIfMaxMinField" ((PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DTypeSig false "rewriteIfMaxMinKv" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteIfMaxMinKv" ((PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EVar "rewriteIfMaxMinExpr") (EVar "k")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "v"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Guard" true) (mem "Arm" true) (mem "ImplMethod" true) (mem "DoStmt" true) (mem "Section" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "LetBind" true) (mem "FunClause" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "childExprs" false) (mem "declLocList" false) (mem "implMethodsBodyKey" false) (mem "ruleNameIfMaxMin" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameIfMaxMin")) (fa "summary" (ELit (LString "if-then-else selects the larger/smaller of the same two operands. Prefer `max`/`min`"))) (fa "doc" (ELit (LString "An `if` that picks the larger or smaller of two operands is `max` or `min`.\n\nBefore:\n  if a > b then a else b\nAfter:\n  max a b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleIfMaxMin")) (EApp (EVar "Some") (EVar "ifMaxMinFix"))))
(DTypeSig false "ifMaxMinCompareOp" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "ifMaxMinCompareOp" ((PVar "op")) (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EBinOp "==" (EVar "op") (ELit (LString ">=")))) (EBinOp "==" (EVar "op") (ELit (LString "<")))) (EBinOp "==" (EVar "op") (ELit (LString "<=")))))
(DTypeSig false "ifMaxMinFnNormal" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ifMaxMinFnNormal" ((PVar "op")) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EBinOp "==" (EVar "op") (ELit (LString ">=")))) (ELit (LString "max")) (EIf (EVar "otherwise") (ELit (LString "min")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "ifMaxMinFnReversed" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "ifMaxMinFnReversed" ((PVar "op")) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString ">"))) (EBinOp "==" (EVar "op") (ELit (LString ">=")))) (ELit (LString "min")) (EIf (EVar "otherwise") (ELit (LString "max")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "isLiteralExpr" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isLiteralExpr" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELit" PWild) () (EVar "True")) (arm (PCon "ENumLit" PWild PWild PWild) () (EVar "True")) (arm (PCon "EWideLit" PWild PWild PWild PWild) () (EVar "True")) (arm PWild () (EVar "False"))))
(DTypeSig false "ifMaxMinOf" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))))
(DFunDef false "ifMaxMinOf" ((PVar "cond") (PVar "t") (PVar "el")) (EMatch (EApp (EVar "unwrapLoc") (EVar "cond")) (arm (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild) ((GBool (EApp (EVar "ifMaxMinCompareOp") (EVar "op")))) (EBlock (DoLet false false (PVar "aK") (EApp (EVar "exprSexp") (EVar "a"))) (DoLet false false (PVar "bK") (EApp (EVar "exprSexp") (EVar "b"))) (DoLet false false (PVar "tK") (EApp (EVar "exprSexp") (EVar "t"))) (DoLet false false (PVar "eK") (EApp (EVar "exprSexp") (EVar "el"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "==" (EVar "aK") (EVar "bK")) (EApp (EVar "isLiteralExpr") (EVar "a"))) (EApp (EVar "isLiteralExpr") (EVar "b"))) (EVar "None") (EIf (EBinOp "&&" (EBinOp "==" (EVar "tK") (EVar "aK")) (EBinOp "==" (EVar "eK") (EVar "bK"))) (EApp (EVar "Some") (ETuple (EApp (EVar "ifMaxMinFnNormal") (EVar "op")) (EVar "a") (EVar "b"))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "tK") (EVar "bK")) (EBinOp "==" (EVar "eK") (EVar "aK"))) (EApp (EVar "Some") (ETuple (EApp (EVar "ifMaxMinFnReversed") (EVar "op")) (EVar "a") (EVar "b"))) (EVar "None"))))))) (arm PWild () (EVar "None"))))
(DTypeSig false "ruleIfMaxMin" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleIfMaxMin" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "ifMaxMinDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "ifMaxMinDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "ifMaxMinDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "ifMaxMinFinding") (EVar "loc"))) (EApp (EVar "declIfMaxMinHits") (EVar "d"))))
(DTypeSig false "declIfMaxMinHits" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "declIfMaxMinHits" ((PCon "DFunDef" PWild PWild PWild (PVar "body") PWild PWild)) (EApp (EVar "collectIfMaxMinHits") (EVar "body")))
(DFunDef false "declIfMaxMinHits" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EVar "implMethodIfMaxMinHits")) (EVar "methods")))
(DFunDef false "declIfMaxMinHits" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declIfMaxMinHits") (EVar "d")))
(DFunDef false "declIfMaxMinHits" (PWild) (EListLit))
(DTypeSig false "implMethodIfMaxMinHits" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "implMethodIfMaxMinHits" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "collectIfMaxMinHits") (EVar "body")))
(DTypeSig false "collectIfMaxMinHits" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "collectIfMaxMinHits" ((PVar "e")) (EBinOp "++" (EApp (EVar "ifMaxMinHitOf") (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EVar "collectIfMaxMinHits")) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "ifMaxMinHitOf" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "ifMaxMinHitOf" ((PCon "EIf" (PVar "cond") (PVar "t") (PVar "el"))) (EApp (EVar "optHitToList") (EApp (EApp (EApp (EVar "ifMaxMinOf") (EVar "cond")) (EVar "t")) (EVar "el"))))
(DFunDef false "ifMaxMinHitOf" (PWild) (EListLit))
(DTypeSig false "optHitToList" (TyFun (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "optHitToList" ((PCon "Some" (PVar "h"))) (EListLit (EVar "h")))
(DFunDef false "optHitToList" ((PCon "None")) (EListLit))
(DTypeSig false "ifMaxMinFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")) (TyCon "Finding"))))
(DFunDef false "ifMaxMinFinding" ((PVar "loc") (PTuple (PVar "fn") (PVar "a") (PVar "b"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameIfMaxMin")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if-then-else selects the ")) (EApp (EMethodRef "display") (EIf (EBinOp "==" (EVar "fn") (ELit (LString "max"))) (ELit (LString "larger")) (ELit (LString "smaller"))))) (ELit (LString " of the same two operands. Rewrite as '"))) (EApp (EMethodRef "display") (EApp (EVar "exprToString") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EVar "a"))) (EVar "b"))))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "ifMaxMinFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "ifMaxMinFix" (PWild (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body") (PVar "site") (PVar "bid"))) (EBlock (DoLet false false (PVar "body2") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2")) (EVar "site")) (EVar "bid"))))))))
(DFunDef false "ifMaxMinFix" ((PVar "orc") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EVar "ifMaxMinFix") (EVar "orc")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "ifMaxMinFix" (PWild (PAs "d" (PRec "DImpl" ((rf "implOrigin" PWild) (rf "methods" None)) false))) (EBlock (DoLet false false (PVar "methods2") (EApp (EApp (EMethodRef "map") (EVar "fixImplMethodIfMaxMin")) (EVar "methods"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "implMethodsBodyKey") (EVar "methods2")) (EApp (EVar "implMethodsBodyKey") (EVar "methods"))) (EVar "None") (EApp (EVar "Some") (EListLit (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EVar "methods2"))))))))))
(DFunDef false "ifMaxMinFix" (PWild PWild) (EVar "None"))
(DTypeSig false "fixImplMethodIfMaxMin" (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))
(DFunDef false "fixImplMethodIfMaxMin" ((PCon "ImplMethod" (PVar "nm") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "ps")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))))
(DTypeSig false "tryIfMaxMin" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "tryIfMaxMin" ((PVar "cond") (PVar "t") (PVar "el")) (EMatch (EApp (EApp (EApp (EVar "ifMaxMinOf") (EVar "cond")) (EVar "t")) (EVar "el")) (arm (PCon "Some" (PTuple (PVar "fn") (PVar "a") (PVar "b"))) () (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EVar "a"))) (EVar "b"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "EIf") (EVar "cond")) (EVar "t")) (EVar "el")))))
(DTypeSig false "rewriteIfMaxMinExpr" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "f"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "x"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "b"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ELet" (PVar "m") (PVar "isf") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isf")) (EVar "p")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e1"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e2"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EMatch" (PVar "s") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "s"))) (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinArm")) (EVar "arms"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "tryIfMaxMin") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "c"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "t"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "el"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "a"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "b"))) (EVar "r")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "a"))) (EVar "r")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "a"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "b"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EVar "f")) (EVar "r")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinExpr")) (EVar "es"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinExpr")) (EVar "es"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinExpr")) (EVar "es"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "lo"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "lo"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "lo"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinLet")) (EVar "binds"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EVar "rewriteIfMaxMinSection") (EVar "s"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "EIndex") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "a"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "i"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EHeadAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinStmt")) (EVar "stmts"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "d")) (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinStmt")) (EVar "stmts"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinInterp")) (EVar "parts"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinGuardArm")) (EVar "arms"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinField")) (EVar "fs"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinField")) (EVar "fs"))) (EVar "r")))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinField")) (EVar "fs"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinKv")) (EVar "kvs"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinExpr")) (EVar "es"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PCon "EOrPat" (PVar "es"))) (EApp (EVar "EOrPat") (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinExpr")) (EVar "es"))))
(DFunDef false "rewriteIfMaxMinExpr" ((PVar "e")) (EVar "e"))
(DTypeSig false "rewriteIfMaxMinStmt" (TyFun (TyCon "DoStmt") (TyCon "DoStmt")))
(DFunDef false "rewriteIfMaxMinStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinStmt" ((PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinStmt" ((PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EVar "site")))
(DFunDef false "rewriteIfMaxMinStmt" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinStmt" ((PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DTypeSig false "rewriteIfMaxMinArm" (TyFun (TyCon "Arm") (TyCon "Arm")))
(DFunDef false "rewriteIfMaxMinArm" ((PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinGuard")) (EVar "gs"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))))
(DTypeSig false "rewriteIfMaxMinGuard" (TyFun (TyCon "Guard") (TyCon "Guard")))
(DFunDef false "rewriteIfMaxMinGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinGuard" ((PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DTypeSig false "rewriteIfMaxMinLet" (TyFun (TyCon "LetBind") (TyCon "LetBind")))
(DFunDef false "rewriteIfMaxMinLet" ((PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinClause")) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "rewriteIfMaxMinClause" (TyFun (TyCon "FunClause") (TyCon "FunClause")))
(DFunDef false "rewriteIfMaxMinClause" ((PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))))
(DTypeSig false "rewriteIfMaxMinSection" (TyFun (TyCon "Section") (TyCon "Section")))
(DFunDef false "rewriteIfMaxMinSection" ((PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "rewriteIfMaxMinSection" ((PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DFunDef false "rewriteIfMaxMinSection" ((PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))) (EVar "op")))
(DTypeSig false "rewriteIfMaxMinInterp" (TyFun (TyCon "InterpPart") (TyCon "InterpPart")))
(DFunDef false "rewriteIfMaxMinInterp" ((PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "rewriteIfMaxMinInterp" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DTypeSig false "rewriteIfMaxMinGuardArm" (TyFun (TyCon "GuardArm") (TyCon "GuardArm")))
(DFunDef false "rewriteIfMaxMinGuardArm" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EMethodRef "map") (EVar "rewriteIfMaxMinGuard")) (EVar "gs"))) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "body"))))
(DTypeSig false "rewriteIfMaxMinField" (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign")))
(DFunDef false "rewriteIfMaxMinField" ((PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "e"))))
(DTypeSig false "rewriteIfMaxMinKv" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteIfMaxMinKv" ((PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EVar "rewriteIfMaxMinExpr") (EVar "k")) (EApp (EVar "rewriteIfMaxMinExpr") (EVar "v"))))
