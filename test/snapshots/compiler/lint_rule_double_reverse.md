# META
source_lines=80
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-double-reverse: `reverse (reverse x)` is `x`. Drop the double reversal.

import frontend.ast.{Loc(..), Expr(..), Decl(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import tools.printer.{exprToString}
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
  Visitor,
  mkVisitorRule,
}
import tools.lint_shared.{
  detApply,
  exprRuleVisitors,
  exprRuleFix,
  isEVarNamed,
  noExcl,
  ruleNameDoubleReverse,
  unwrapLoc,
}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameDoubleReverse,
      summary = "`reverse (reverse x)` is `x`. Drop the double reversal",
      doc =
        "Reversing a list twice returns the original list after two traversals.\n\nBefore:\n  reverse (reverse xs)\nAfter:\n  xs",
      category = Complexity,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleDoubleReverse
    (Some doubleReverseFix)

-- ── rule: double-reverse ──────────────────────────────────────────────────────
-- `reverse (reverse x)` → `x` (`reverse` is an involution).
doubleReverseOf : Expr -> Option Expr
doubleReverseOf (EApp hd1 arg1)
  | isEVarNamed "reverse" hd1 = match unwrapLoc arg1
    EApp hd2 inner => if isEVarNamed "reverse" hd2 then Some inner else None
    _ => None
doubleReverseOf _ = None

ruleDoubleReverse : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleDoubleReverse _ _ _ _ _ =
  exprRuleVisitors noExcl doubleReverseOf doubleReverseFinding

doubleReverseFinding : Option Loc -> Expr -> Finding
doubleReverseFinding loc rewritten = Finding {
  rule = ruleNameDoubleReverse,
  message =
    "`reverse (reverse …)` is a no-op. Rewrite as '"
      ++ exprToString rewritten
      ++ "'",
  severity = SevWarning,
  loc = loc,
}

doubleReverseFix : Oracle -> Decl -> Option (List Decl)
doubleReverseFix _ d = exprRuleFix noExcl (detApply doubleReverseOf) d
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleVisitors" false) (mem "exprRuleFix" false) (mem "isEVarNamed" false) (mem "noExcl" false) (mem "ruleNameDoubleReverse" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDoubleReverse")) (fa "summary" (ELit (LString "`reverse (reverse x)` is `x`. Drop the double reversal"))) (fa "doc" (ELit (LString "Reversing a list twice returns the original list after two traversals.\n\nBefore:\n  reverse (reverse xs)\nAfter:\n  xs"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleDoubleReverse")) (EApp (EVar "Some") (EVar "doubleReverseFix"))))
(DTypeSig false "doubleReverseOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "doubleReverseOf" ((PCon "EApp" (PVar "hd1") (PVar "arg1"))) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "reverse"))) (EVar "hd1")) (EMatch (EApp (EVar "unwrapLoc") (EVar "arg1")) (arm (PCon "EApp" (PVar "hd2") (PVar "inner")) () (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "reverse"))) (EVar "hd2")) (EApp (EVar "Some") (EVar "inner")) (EVar "None"))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "doubleReverseOf" (PWild) (EVar "None"))
(DTypeSig false "ruleDoubleReverse" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleDoubleReverse" (PWild PWild PWild PWild PWild) (EApp (EApp (EApp (EVar "exprRuleVisitors") (EVar "noExcl")) (EVar "doubleReverseOf")) (EVar "doubleReverseFinding")))
(DTypeSig false "doubleReverseFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "doubleReverseFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDoubleReverse")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`reverse (reverse …)` is a no-op. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "doubleReverseFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "doubleReverseFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "doubleReverseOf"))) (EVar "d")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleVisitors" false) (mem "exprRuleFix" false) (mem "isEVarNamed" false) (mem "noExcl" false) (mem "ruleNameDoubleReverse" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDoubleReverse")) (fa "summary" (ELit (LString "`reverse (reverse x)` is `x`. Drop the double reversal"))) (fa "doc" (ELit (LString "Reversing a list twice returns the original list after two traversals.\n\nBefore:\n  reverse (reverse xs)\nAfter:\n  xs"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleDoubleReverse")) (EApp (EVar "Some") (EVar "doubleReverseFix"))))
(DTypeSig false "doubleReverseOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "doubleReverseOf" ((PCon "EApp" (PVar "hd1") (PVar "arg1"))) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "reverse"))) (EVar "hd1")) (EMatch (EApp (EVar "unwrapLoc") (EVar "arg1")) (arm (PCon "EApp" (PVar "hd2") (PVar "inner")) () (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "reverse"))) (EVar "hd2")) (EApp (EVar "Some") (EVar "inner")) (EVar "None"))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "doubleReverseOf" (PWild) (EVar "None"))
(DTypeSig false "ruleDoubleReverse" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleDoubleReverse" (PWild PWild PWild PWild PWild) (EApp (EApp (EApp (EVar "exprRuleVisitors") (EVar "noExcl")) (EVar "doubleReverseOf")) (EVar "doubleReverseFinding")))
(DTypeSig false "doubleReverseFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "doubleReverseFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDoubleReverse")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`reverse (reverse …)` is a no-op. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "doubleReverseFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "doubleReverseFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "doubleReverseOf"))) (EVar "d")))
