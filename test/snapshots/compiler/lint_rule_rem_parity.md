# META
source_lines=102
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-rem-parity: `n % 2 == 0` and `n % 2 /= 0` parity tests. Prefer `isEven n` / `isOdd n`.

import frontend.ast.{Loc(..), Lit(..), Expr(..), Decl(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import tools.printer.{exprToString}
import frontend.exhaust.{Oracle}
import tools.lint_core.{
  Category(..),
  FileFacts,
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
  detApply,
  exprRuleFindings,
  exprRuleFix,
  ruleNameRemParity,
  unwrapLoc,
}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameRemParity,
      summary =
        "`n % 2 == 0` / `n % 2 /= 0` parity test. Prefer `isEven n` / `isOdd n`",
      doc =
        "A remainder-by-two comparison against zero is a parity test; the prelude names it.\n\nBefore:\n  n % 2 == 0\nAfter:\n  isEven n",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleRemParity
    (Some remParityFix)

-- `e` is the integer literal `k` — either an `ELit (LInt k)` or a Num-poly
-- `ENumLit k …` (the parser emits the latter for expression int literals; sexp
-- renders both identically, so both must be recognised).
isIntLit : Int -> Expr -> Bool
isIntLit k e = match unwrapLoc e
  ELit (LInt n) => n == k
  ENumLit n _ _ => n == k
  _ => False

-- `n % 2 == 0` → `isEven n`; `n % 2 /= 0` → `isOdd n` (either operand order).
-- ONLY the `== 0` / `/= 0` comparisons: Medaka's `%` follows the DIVIDEND's sign
-- (`-3 % 2 = -1`), so `n % 2 == 1` is FALSE for negative odd `n` — excluded.
-- Excludes the `isEven`/`isOdd` definitions themselves (their bodies ARE this
-- idiom; rewriting them would produce `isEven n = isEven n`).
remParityExcl : String -> Bool
remParityExcl name = name == "isEven" || name == "isOdd"

remParityOf : Expr -> Option Expr
remParityOf (EBinOp op a b _)
  | op == "==" || op == "/=" =
    if isIntLit 0 b then
      remParityFrom op (unwrapLoc a)
    else if isIntLit 0 a then
      remParityFrom op (unwrapLoc b)
    else
      None
remParityOf _ = None

remParityFrom : String -> Expr -> Option Expr
remParityFrom op (EBinOp "%" n two _)
  | isIntLit 2 two = Some (EApp (EVar (parityFn op)) n)
remParityFrom _ _ = None

parityFn : String -> String
parityFn op = if op == "==" then "isEven" else "isOdd"

ruleRemParity : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleRemParity _ _ _ pos prog =
  exprRuleFindings remParityExcl remParityOf remParityFinding pos prog

remParityFinding : Option Loc -> Expr -> Finding
remParityFinding loc rewritten = Finding {
  rule = ruleNameRemParity,
  message = "parity test. Rewrite as '" ++ exprToString rewritten ++ "'",
  severity = SevWarning,
  loc = loc,
}

remParityFix : Oracle -> Decl -> Option (List Decl)
remParityFix _ d = exprRuleFix remParityExcl (detApply remParityOf) d
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleFindings" false) (mem "exprRuleFix" false) (mem "ruleNameRemParity" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameRemParity")) (fa "summary" (ELit (LString "`n % 2 == 0` / `n % 2 /= 0` parity test. Prefer `isEven n` / `isOdd n`"))) (fa "doc" (ELit (LString "A remainder-by-two comparison against zero is a parity test; the prelude names it.\n\nBefore:\n  n % 2 == 0\nAfter:\n  isEven n"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleRemParity")) (EApp (EVar "Some") (EVar "remParityFix"))))
(DTypeSig false "isIntLit" (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isIntLit" ((PVar "k") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELit" (PCon "LInt" (PVar "n"))) () (EBinOp "==" (EVar "n") (EVar "k"))) (arm (PCon "ENumLit" (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "k"))) (arm PWild () (EVar "False"))))
(DTypeSig false "remParityExcl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "remParityExcl" ((PVar "name")) (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "isEven"))) (EBinOp "==" (EVar "name") (ELit (LString "isOdd")))))
(DTypeSig false "remParityOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "remParityOf" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "=="))) (EBinOp "==" (EVar "op") (ELit (LString "/=")))) (EIf (EApp (EApp (EVar "isIntLit") (ELit (LInt 0))) (EVar "b")) (EApp (EApp (EVar "remParityFrom") (EVar "op")) (EApp (EVar "unwrapLoc") (EVar "a"))) (EIf (EApp (EApp (EVar "isIntLit") (ELit (LInt 0))) (EVar "a")) (EApp (EApp (EVar "remParityFrom") (EVar "op")) (EApp (EVar "unwrapLoc") (EVar "b"))) (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "remParityOf" (PWild) (EVar "None"))
(DTypeSig false "remParityFrom" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "remParityFrom" ((PVar "op") (PCon "EBinOp" (PLit (LString "%")) (PVar "n") (PVar "two") PWild)) (EIf (EApp (EApp (EVar "isIntLit") (ELit (LInt 2))) (EVar "two")) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EApp (EVar "parityFn") (EVar "op")))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "remParityFrom" (PWild PWild) (EVar "None"))
(DTypeSig false "parityFn" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "parityFn" ((PVar "op")) (EIf (EBinOp "==" (EVar "op") (ELit (LString "=="))) (ELit (LString "isEven")) (ELit (LString "isOdd"))))
(DTypeSig false "ruleRemParity" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleRemParity" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "remParityExcl")) (EVar "remParityOf")) (EVar "remParityFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "remParityFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "remParityFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameRemParity")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "parity test. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "remParityFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "remParityFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "remParityExcl")) (EApp (EVar "detApply") (EVar "remParityOf"))) (EVar "d")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleFindings" false) (mem "exprRuleFix" false) (mem "ruleNameRemParity" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameRemParity")) (fa "summary" (ELit (LString "`n % 2 == 0` / `n % 2 /= 0` parity test. Prefer `isEven n` / `isOdd n`"))) (fa "doc" (ELit (LString "A remainder-by-two comparison against zero is a parity test; the prelude names it.\n\nBefore:\n  n % 2 == 0\nAfter:\n  isEven n"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleRemParity")) (EApp (EVar "Some") (EVar "remParityFix"))))
(DTypeSig false "isIntLit" (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isIntLit" ((PVar "k") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "ELit" (PCon "LInt" (PVar "n"))) () (EBinOp "==" (EVar "n") (EVar "k"))) (arm (PCon "ENumLit" (PVar "n") PWild PWild) () (EBinOp "==" (EVar "n") (EVar "k"))) (arm PWild () (EVar "False"))))
(DTypeSig false "remParityExcl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "remParityExcl" ((PVar "name")) (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "isEven"))) (EBinOp "==" (EVar "name") (ELit (LString "isOdd")))))
(DTypeSig false "remParityOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "remParityOf" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "=="))) (EBinOp "==" (EVar "op") (ELit (LString "/=")))) (EIf (EApp (EApp (EVar "isIntLit") (ELit (LInt 0))) (EVar "b")) (EApp (EApp (EVar "remParityFrom") (EVar "op")) (EApp (EVar "unwrapLoc") (EVar "a"))) (EIf (EApp (EApp (EVar "isIntLit") (ELit (LInt 0))) (EVar "a")) (EApp (EApp (EVar "remParityFrom") (EVar "op")) (EApp (EVar "unwrapLoc") (EVar "b"))) (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "remParityOf" (PWild) (EVar "None"))
(DTypeSig false "remParityFrom" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "remParityFrom" ((PVar "op") (PCon "EBinOp" (PLit (LString "%")) (PVar "n") (PVar "two") PWild)) (EIf (EApp (EApp (EVar "isIntLit") (ELit (LInt 2))) (EVar "two")) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EApp (EVar "parityFn") (EVar "op")))) (EVar "n"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "remParityFrom" (PWild PWild) (EVar "None"))
(DTypeSig false "parityFn" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "parityFn" ((PVar "op")) (EIf (EBinOp "==" (EVar "op") (ELit (LString "=="))) (ELit (LString "isEven")) (ELit (LString "isOdd"))))
(DTypeSig false "ruleRemParity" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleRemParity" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "remParityExcl")) (EVar "remParityOf")) (EVar "remParityFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "remParityFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "remParityFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameRemParity")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "parity test. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "remParityFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "remParityFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "remParityExcl")) (EApp (EVar "detApply") (EVar "remParityOf"))) (EVar "d")))
