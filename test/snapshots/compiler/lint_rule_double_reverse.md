# META
source_lines=108
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-double-reverse: `reverse (reverse x)` is `x`. Drop the double reversal.

import frontend.ast.{Loc(..), Expr(..), Decl(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import tools.printer.{exprToString}
import tools.lint_core.{
  Category(..),
  Ctx(..),
  FileFacts(..),
  Finding(..),
  Fix,
  Fixability(..),
  Need(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  Visitor,
  mkVisitorRule,
}
import tools.lint_shared.{
  bindingOf,
  exprRuleEditVisitors,
  isEVarNamed,
  nodeSpan,
  noExcl,
  replaceFix,
  ruleNameDoubleReverse,
  unwrapLoc,
  usesPreludeName,
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
      needs = [NeedsScopes],
    }
    ruleDoubleReverse
    None

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
ruleDoubleReverse _ _ facts _ _ =
  exprRuleEditVisitors
    noExcl
    doubleReverseOf
    (doubleReverseFix facts)
    doubleReverseFinding

doubleReverseFinding : Option Loc -> Expr -> Option Fix -> Finding
doubleReverseFinding loc rewritten fix = Finding {
  rule = ruleNameDoubleReverse,
  message =
    "`reverse (reverse …)` is a no-op. Rewrite as '"
      ++ exprToString rewritten
      ++ "'",
  severity = SevWarning,
  loc = loc,
  fix = fix,
}

-- The rewrite drops both `reverse` calls, so each must be the one the file
-- resolves to the prelude's: a `reverse` the file binds is not the list
-- involution the rule knows, and its fix is withheld.
doubleReverseFix : FileFacts -> Ctx -> Expr -> Expr -> Option Fix
doubleReverseFix facts ctx e rewritten =
  if reversesArePrelude facts e then
    replaceFix
      "drop the double reversal"
      (nodeSpan ctx e)
      (bindingOf rewritten)
      ctx
      (exprToString rewritten)
  else
    None

-- Both `reverse` heads of the matched pair resolve to the prelude's.
reversesArePrelude : FileFacts -> Expr -> Bool
reversesArePrelude facts (EApp hd1 arg1) = match unwrapLoc arg1
  EApp hd2 _ => usesPreludeName facts hd1 && usesPreludeName facts hd2
  _ => False
reversesArePrelude _ _ = False
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "bindingOf" false) (mem "exprRuleEditVisitors" false) (mem "isEVarNamed" false) (mem "nodeSpan" false) (mem "noExcl" false) (mem "replaceFix" false) (mem "ruleNameDoubleReverse" false) (mem "unwrapLoc" false) (mem "usesPreludeName" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDoubleReverse")) (fa "summary" (ELit (LString "`reverse (reverse x)` is `x`. Drop the double reversal"))) (fa "doc" (ELit (LString "Reversing a list twice returns the original list after two traversals.\n\nBefore:\n  reverse (reverse xs)\nAfter:\n  xs"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleDoubleReverse")) (EVar "None")))
(DTypeSig false "doubleReverseOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "doubleReverseOf" ((PCon "EApp" (PVar "hd1") (PVar "arg1"))) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "reverse"))) (EVar "hd1")) (EMatch (EApp (EVar "unwrapLoc") (EVar "arg1")) (arm (PCon "EApp" (PVar "hd2") (PVar "inner")) () (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "reverse"))) (EVar "hd2")) (EApp (EVar "Some") (EVar "inner")) (EVar "None"))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "doubleReverseOf" (PWild) (EVar "None"))
(DTypeSig false "ruleDoubleReverse" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleDoubleReverse" (PWild PWild (PVar "facts") PWild PWild) (EApp (EApp (EApp (EApp (EVar "exprRuleEditVisitors") (EVar "noExcl")) (EVar "doubleReverseOf")) (EApp (EVar "doubleReverseFix") (EVar "facts"))) (EVar "doubleReverseFinding")))
(DTypeSig false "doubleReverseFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "doubleReverseFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDoubleReverse")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`reverse (reverse …)` is a no-op. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "doubleReverseFix" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix")))))))
(DFunDef false "doubleReverseFix" ((PVar "facts") (PVar "ctx") (PVar "e") (PVar "rewritten")) (EIf (EApp (EApp (EVar "reversesArePrelude") (EVar "facts")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "replaceFix") (ELit (LString "drop the double reversal"))) (EApp (EApp (EVar "nodeSpan") (EVar "ctx")) (EVar "e"))) (EApp (EVar "bindingOf") (EVar "rewritten"))) (EVar "ctx")) (EApp (EVar "exprToString") (EVar "rewritten"))) (EVar "None")))
(DTypeSig false "reversesArePrelude" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "reversesArePrelude" ((PVar "facts") (PCon "EApp" (PVar "hd1") (PVar "arg1"))) (EMatch (EApp (EVar "unwrapLoc") (EVar "arg1")) (arm (PCon "EApp" (PVar "hd2") PWild) () (EBinOp "&&" (EApp (EApp (EVar "usesPreludeName") (EVar "facts")) (EVar "hd1")) (EApp (EApp (EVar "usesPreludeName") (EVar "facts")) (EVar "hd2")))) (arm PWild () (EVar "False"))))
(DFunDef false "reversesArePrelude" (PWild PWild) (EVar "False"))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "bindingOf" false) (mem "exprRuleEditVisitors" false) (mem "isEVarNamed" false) (mem "nodeSpan" false) (mem "noExcl" false) (mem "replaceFix" false) (mem "ruleNameDoubleReverse" false) (mem "unwrapLoc" false) (mem "usesPreludeName" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDoubleReverse")) (fa "summary" (ELit (LString "`reverse (reverse x)` is `x`. Drop the double reversal"))) (fa "doc" (ELit (LString "Reversing a list twice returns the original list after two traversals.\n\nBefore:\n  reverse (reverse xs)\nAfter:\n  xs"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleDoubleReverse")) (EVar "None")))
(DTypeSig false "doubleReverseOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "doubleReverseOf" ((PCon "EApp" (PVar "hd1") (PVar "arg1"))) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "reverse"))) (EVar "hd1")) (EMatch (EApp (EVar "unwrapLoc") (EVar "arg1")) (arm (PCon "EApp" (PVar "hd2") (PVar "inner")) () (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "reverse"))) (EVar "hd2")) (EApp (EVar "Some") (EVar "inner")) (EVar "None"))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "doubleReverseOf" (PWild) (EVar "None"))
(DTypeSig false "ruleDoubleReverse" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleDoubleReverse" (PWild PWild (PVar "facts") PWild PWild) (EApp (EApp (EApp (EApp (EVar "exprRuleEditVisitors") (EVar "noExcl")) (EVar "doubleReverseOf")) (EApp (EVar "doubleReverseFix") (EVar "facts"))) (EVar "doubleReverseFinding")))
(DTypeSig false "doubleReverseFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "doubleReverseFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDoubleReverse")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`reverse (reverse …)` is a no-op. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "doubleReverseFix" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix")))))))
(DFunDef false "doubleReverseFix" ((PVar "facts") (PVar "ctx") (PVar "e") (PVar "rewritten")) (EIf (EApp (EApp (EVar "reversesArePrelude") (EVar "facts")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "replaceFix") (ELit (LString "drop the double reversal"))) (EApp (EApp (EVar "nodeSpan") (EVar "ctx")) (EVar "e"))) (EApp (EVar "bindingOf") (EVar "rewritten"))) (EVar "ctx")) (EApp (EVar "exprToString") (EVar "rewritten"))) (EVar "None")))
(DTypeSig false "reversesArePrelude" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "reversesArePrelude" ((PVar "facts") (PCon "EApp" (PVar "hd1") (PVar "arg1"))) (EMatch (EApp (EVar "unwrapLoc") (EVar "arg1")) (arm (PCon "EApp" (PVar "hd2") PWild) () (EBinOp "&&" (EApp (EApp (EVar "usesPreludeName") (EVar "facts")) (EVar "hd1")) (EApp (EApp (EVar "usesPreludeName") (EVar "facts")) (EVar "hd2")))) (arm PWild () (EVar "False"))))
(DFunDef false "reversesArePrelude" (PWild PWild) (EVar "False"))
