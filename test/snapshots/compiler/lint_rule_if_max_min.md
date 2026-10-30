# META
source_lines=156
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-if-max-min: an `if` that selects the larger or smaller of two operands. Prefer `max`/`min`.

import frontend.ast.{Loc(..), Expr(..), Decl(..)}
import frontend.ast_walk.{ExprKind(..)}
import frontend.parser.{Positions(..)}
import ir.sexp.{exprSexp}
import driver.diagnostics.{Severity(..)}
import tools.printer.{exprToString}
import frontend.exhaust.{Oracle}
import tools.lint_core.{
  Category(..),
  Ctx(..),
  FileFacts(..),
  Finding(..),
  Fixability(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  Visitor(..),
  mkVisitorRule,
}
import tools.lint_shared.{
  detApply,
  exprRuleFix,
  noExcl,
  ruleNameIfMaxMin,
  unwrapLoc,
}

export
rule : Rule
rule =
  mkVisitorRule
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
-- Only `EIf` nodes can match, so only those are visited.
ruleIfMaxMin : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleIfMaxMin _ _ _ _ _ = [OnExpr [KIf] ifMaxMinAt]

ifMaxMinAt : Ctx -> Expr -> List Finding
ifMaxMinAt ctx (EIf cond t el) = match ifMaxMinOf cond t el
  Some hit => [ifMaxMinFinding ctx.ctxDeclLoc hit]
  None => []
ifMaxMinAt _ _ = []

ifMaxMinFinding : Option Loc -> (String, Expr, Expr) -> Finding
ifMaxMinFinding loc (fn, a, b) = Finding {
  rule = ruleNameIfMaxMin,
  message =
    "if-then-else selects the \{if fn == "max" then "larger" else "smaller"} of the same two operands. Rewrite as '\{exprToString (EApp (EApp (EVar fn) a) b)}'",
  severity = SevWarning,
  loc = loc,
  fix = None,
}

-- ── autofix ───────────────────────────────────────────────────────────────────
-- Bottom-up: every eligible `if` becomes a `max`/`min` application.
ifMaxMinFix : Oracle -> Decl -> Option (List Decl)
ifMaxMinFix _ d = exprRuleFix noExcl (detApply ifMaxMinRewrite) d

ifMaxMinRewrite : Expr -> Option Expr
ifMaxMinRewrite (EIf cond t el) =
  map ((fn, a, b) => EApp (EApp (EVar fn) a) b) (ifMaxMinOf cond t el)
ifMaxMinRewrite _ = None
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleFix" false) (mem "noExcl" false) (mem "ruleNameIfMaxMin" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameIfMaxMin")) (fa "summary" (ELit (LString "if-then-else selects the larger/smaller of the same two operands. Prefer `max`/`min`"))) (fa "doc" (ELit (LString "An `if` that picks the larger or smaller of two operands is `max` or `min`.\n\nBefore:\n  if a > b then a else b\nAfter:\n  max a b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleIfMaxMin")) (EApp (EVar "Some") (EVar "ifMaxMinFix"))))
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
(DTypeSig false "ruleIfMaxMin" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleIfMaxMin" (PWild PWild PWild PWild PWild) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KIf"))) (EVar "ifMaxMinAt"))))
(DTypeSig false "ifMaxMinAt" (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "ifMaxMinAt" ((PVar "ctx") (PCon "EIf" (PVar "cond") (PVar "t") (PVar "el"))) (EMatch (EApp (EApp (EApp (EVar "ifMaxMinOf") (EVar "cond")) (EVar "t")) (EVar "el")) (arm (PCon "Some" (PVar "hit")) () (EListLit (EApp (EApp (EVar "ifMaxMinFinding") (EFieldAccess (EVar "ctx") "ctxDeclLoc")) (EVar "hit")))) (arm (PCon "None") () (EListLit))))
(DFunDef false "ifMaxMinAt" (PWild PWild) (EListLit))
(DTypeSig false "ifMaxMinFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")) (TyCon "Finding"))))
(DFunDef false "ifMaxMinFinding" ((PVar "loc") (PTuple (PVar "fn") (PVar "a") (PVar "b"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameIfMaxMin")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if-then-else selects the ")) (EApp (EVar "display") (EIf (EBinOp "==" (EVar "fn") (ELit (LString "max"))) (ELit (LString "larger")) (ELit (LString "smaller"))))) (ELit (LString " of the same two operands. Rewrite as '"))) (EApp (EVar "display") (EApp (EVar "exprToString") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EVar "a"))) (EVar "b"))))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "ifMaxMinFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "ifMaxMinFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "ifMaxMinRewrite"))) (EVar "d")))
(DTypeSig false "ifMaxMinRewrite" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "ifMaxMinRewrite" ((PCon "EIf" (PVar "cond") (PVar "t") (PVar "el"))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "fn") (PVar "a") (PVar "b"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EVar "a"))) (EVar "b")))) (EApp (EApp (EApp (EVar "ifMaxMinOf") (EVar "cond")) (EVar "t")) (EVar "el"))))
(DFunDef false "ifMaxMinRewrite" (PWild) (EVar "None"))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleFix" false) (mem "noExcl" false) (mem "ruleNameIfMaxMin" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameIfMaxMin")) (fa "summary" (ELit (LString "if-then-else selects the larger/smaller of the same two operands. Prefer `max`/`min`"))) (fa "doc" (ELit (LString "An `if` that picks the larger or smaller of two operands is `max` or `min`.\n\nBefore:\n  if a > b then a else b\nAfter:\n  max a b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleIfMaxMin")) (EApp (EVar "Some") (EVar "ifMaxMinFix"))))
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
(DTypeSig false "ruleIfMaxMin" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleIfMaxMin" (PWild PWild PWild PWild PWild) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KIf"))) (EVar "ifMaxMinAt"))))
(DTypeSig false "ifMaxMinAt" (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "ifMaxMinAt" ((PVar "ctx") (PCon "EIf" (PVar "cond") (PVar "t") (PVar "el"))) (EMatch (EApp (EApp (EApp (EVar "ifMaxMinOf") (EVar "cond")) (EVar "t")) (EVar "el")) (arm (PCon "Some" (PVar "hit")) () (EListLit (EApp (EApp (EVar "ifMaxMinFinding") (EFieldAccess (EVar "ctx") "ctxDeclLoc")) (EVar "hit")))) (arm (PCon "None") () (EListLit))))
(DFunDef false "ifMaxMinAt" (PWild PWild) (EListLit))
(DTypeSig false "ifMaxMinFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "String") (TyCon "Expr") (TyCon "Expr")) (TyCon "Finding"))))
(DFunDef false "ifMaxMinFinding" ((PVar "loc") (PTuple (PVar "fn") (PVar "a") (PVar "b"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameIfMaxMin")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "if-then-else selects the ")) (EApp (EMethodRef "display") (EIf (EBinOp "==" (EVar "fn") (ELit (LString "max"))) (ELit (LString "larger")) (ELit (LString "smaller"))))) (ELit (LString " of the same two operands. Rewrite as '"))) (EApp (EMethodRef "display") (EApp (EVar "exprToString") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EVar "a"))) (EVar "b"))))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "ifMaxMinFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "ifMaxMinFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "ifMaxMinRewrite"))) (EVar "d")))
(DTypeSig false "ifMaxMinRewrite" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "ifMaxMinRewrite" ((PCon "EIf" (PVar "cond") (PVar "t") (PVar "el"))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "fn") (PVar "a") (PVar "b"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "fn"))) (EVar "a"))) (EVar "b")))) (EApp (EApp (EApp (EVar "ifMaxMinOf") (EVar "cond")) (EVar "t")) (EVar "el"))))
(DFunDef false "ifMaxMinRewrite" (PWild) (EVar "None"))
