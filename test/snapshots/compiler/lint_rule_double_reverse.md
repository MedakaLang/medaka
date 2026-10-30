# META
source_lines=102
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-double-reverse: `reverse (reverse x)` is `x`. Drop the double reversal.

import frontend.ast.{Loc(..), Expr(..), Decl(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import tools.printer.{exprToString}
import tools.lint_core.{
  Applicability(..),
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
  exprRuleEditVisitors,
  isEVarNamed,
  noExcl,
  replaceNodeFix,
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
      needs = [NeedsScopes, NeedsStdlibIndex],
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
ruleDoubleReverse idx _ facts _ _ =
  exprRuleEditVisitors
    noExcl
    doubleReverseOf
    (doubleReverseFix idx facts)
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
doubleReverseFix : StdlibIndex -> FileFacts -> Ctx -> Expr -> Expr -> Option Fix
doubleReverseFix idx facts ctx e rewritten =
  if reversesArePrelude idx facts e then
    replaceNodeFix Safe "drop the double reversal" ctx e rewritten
  else
    None

-- Both `reverse` heads of the matched pair resolve to the prelude's.
reversesArePrelude : StdlibIndex -> FileFacts -> Expr -> Bool
reversesArePrelude idx facts (EApp hd1 arg1) = match unwrapLoc arg1
  EApp hd2 _ => usesPreludeName idx facts hd1 && usesPreludeName idx facts hd2
  _ => False
reversesArePrelude _ _ _ = False
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "exprRuleEditVisitors" false) (mem "isEVarNamed" false) (mem "noExcl" false) (mem "replaceNodeFix" false) (mem "ruleNameDoubleReverse" false) (mem "unwrapLoc" false) (mem "usesPreludeName" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDoubleReverse")) (fa "summary" (ELit (LString "`reverse (reverse x)` is `x`. Drop the double reversal"))) (fa "doc" (ELit (LString "Reversing a list twice returns the original list after two traversals.\n\nBefore:\n  reverse (reverse xs)\nAfter:\n  xs"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsStdlibIndex")))))) (EVar "ruleDoubleReverse")) (EVar "None")))
(DTypeSig false "doubleReverseOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "doubleReverseOf" ((PCon "EApp" (PVar "hd1") (PVar "arg1"))) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "reverse"))) (EVar "hd1")) (EMatch (EApp (EVar "unwrapLoc") (EVar "arg1")) (arm (PCon "EApp" (PVar "hd2") (PVar "inner")) () (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "reverse"))) (EVar "hd2")) (EApp (EVar "Some") (EVar "inner")) (EVar "None"))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "doubleReverseOf" (PWild) (EVar "None"))
(DTypeSig false "ruleDoubleReverse" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleDoubleReverse" ((PVar "idx") PWild (PVar "facts") PWild PWild) (EApp (EApp (EApp (EApp (EVar "exprRuleEditVisitors") (EVar "noExcl")) (EVar "doubleReverseOf")) (EApp (EApp (EVar "doubleReverseFix") (EVar "idx")) (EVar "facts"))) (EVar "doubleReverseFinding")))
(DTypeSig false "doubleReverseFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "doubleReverseFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDoubleReverse")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`reverse (reverse …)` is a no-op. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "doubleReverseFix" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix"))))))))
(DFunDef false "doubleReverseFix" ((PVar "idx") (PVar "facts") (PVar "ctx") (PVar "e") (PVar "rewritten")) (EIf (EApp (EApp (EApp (EVar "reversesArePrelude") (EVar "idx")) (EVar "facts")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "replaceNodeFix") (EVar "Safe")) (ELit (LString "drop the double reversal"))) (EVar "ctx")) (EVar "e")) (EVar "rewritten")) (EVar "None")))
(DTypeSig false "reversesArePrelude" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "reversesArePrelude" ((PVar "idx") (PVar "facts") (PCon "EApp" (PVar "hd1") (PVar "arg1"))) (EMatch (EApp (EVar "unwrapLoc") (EVar "arg1")) (arm (PCon "EApp" (PVar "hd2") PWild) () (EBinOp "&&" (EApp (EApp (EApp (EVar "usesPreludeName") (EVar "idx")) (EVar "facts")) (EVar "hd1")) (EApp (EApp (EApp (EVar "usesPreludeName") (EVar "idx")) (EVar "facts")) (EVar "hd2")))) (arm PWild () (EVar "False"))))
(DFunDef false "reversesArePrelude" (PWild PWild PWild) (EVar "False"))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "exprRuleEditVisitors" false) (mem "isEVarNamed" false) (mem "noExcl" false) (mem "replaceNodeFix" false) (mem "ruleNameDoubleReverse" false) (mem "unwrapLoc" false) (mem "usesPreludeName" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDoubleReverse")) (fa "summary" (ELit (LString "`reverse (reverse x)` is `x`. Drop the double reversal"))) (fa "doc" (ELit (LString "Reversing a list twice returns the original list after two traversals.\n\nBefore:\n  reverse (reverse xs)\nAfter:\n  xs"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsStdlibIndex")))))) (EVar "ruleDoubleReverse")) (EVar "None")))
(DTypeSig false "doubleReverseOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "doubleReverseOf" ((PCon "EApp" (PVar "hd1") (PVar "arg1"))) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "reverse"))) (EVar "hd1")) (EMatch (EApp (EVar "unwrapLoc") (EVar "arg1")) (arm (PCon "EApp" (PVar "hd2") (PVar "inner")) () (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "reverse"))) (EVar "hd2")) (EApp (EVar "Some") (EVar "inner")) (EVar "None"))) (arm PWild () (EVar "None"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "doubleReverseOf" (PWild) (EVar "None"))
(DTypeSig false "ruleDoubleReverse" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleDoubleReverse" ((PVar "idx") PWild (PVar "facts") PWild PWild) (EApp (EApp (EApp (EApp (EVar "exprRuleEditVisitors") (EVar "noExcl")) (EVar "doubleReverseOf")) (EApp (EApp (EVar "doubleReverseFix") (EVar "idx")) (EVar "facts"))) (EVar "doubleReverseFinding")))
(DTypeSig false "doubleReverseFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "doubleReverseFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDoubleReverse")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`reverse (reverse …)` is a no-op. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "doubleReverseFix" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix"))))))))
(DFunDef false "doubleReverseFix" ((PVar "idx") (PVar "facts") (PVar "ctx") (PVar "e") (PVar "rewritten")) (EIf (EApp (EApp (EApp (EVar "reversesArePrelude") (EVar "idx")) (EVar "facts")) (EVar "e")) (EApp (EApp (EApp (EApp (EApp (EVar "replaceNodeFix") (EVar "Safe")) (ELit (LString "drop the double reversal"))) (EVar "ctx")) (EVar "e")) (EVar "rewritten")) (EVar "None")))
(DTypeSig false "reversesArePrelude" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "reversesArePrelude" ((PVar "idx") (PVar "facts") (PCon "EApp" (PVar "hd1") (PVar "arg1"))) (EMatch (EApp (EVar "unwrapLoc") (EVar "arg1")) (arm (PCon "EApp" (PVar "hd2") PWild) () (EBinOp "&&" (EApp (EApp (EApp (EVar "usesPreludeName") (EVar "idx")) (EVar "facts")) (EVar "hd1")) (EApp (EApp (EApp (EVar "usesPreludeName") (EVar "idx")) (EVar "facts")) (EVar "hd2")))) (arm PWild () (EVar "False"))))
(DFunDef false "reversesArePrelude" (PWild PWild PWild) (EVar "False"))
