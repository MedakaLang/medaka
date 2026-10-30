# META
source_lines=96
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-when-unless: an `if` with a `pure ()` branch. Prefer `when` / `unless`.

import frontend.ast.{Loc(..), Lit(..), Expr(..), Decl(..)}
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
  ruleNameWhenUnless,
  unwrapLoc,
}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameWhenUnless,
      summary =
        "`if b then m else pure ()` / `if b then pure () else m`. Prefer `when b m` / `unless b m`",
      doc =
        "An `if` with `pure ()` in one branch is `when` or `unless`.\n\nBefore:\n  if b then act else pure ()\nAfter:\n  when b act",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleWhenUnless
    (Some whenUnlessFix)

-- ── rule: when-unless ─────────────────────────────────────────────────────────
-- `if b then m else pure ()` → `when b m`; `if b then pure () else m` → `unless b
-- m`.  Fires ONLY when the OTHER branch is EXACTLY `pure ()` (`EApp (EVar "pure")
-- (ELit LUnit)`).  Excludes the `when`/`unless` definitions themselves (their
-- bodies ARE this idiom → rewriting them would yield `when b m = when b m`).
whenUnlessExcl : String -> Bool
whenUnlessExcl name = name == "when" || name == "unless"

isPureUnit : Expr -> Bool
isPureUnit e = match unwrapLoc e
  EApp hd arg => isEVarNamed "pure" hd && isUnitLit (unwrapLoc arg)
  _ => False

isUnitLit : Expr -> Bool
isUnitLit (ELit LUnit) = True
isUnitLit _ = False

whenUnlessOf : Expr -> Option Expr
whenUnlessOf (EIf c t el)
  | isPureUnit el = Some (EApp (EApp (EVar "when") c) t)
  | isPureUnit t = Some (EApp (EApp (EVar "unless") c) el)
  | otherwise = None
whenUnlessOf _ = None

ruleWhenUnless : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleWhenUnless _ _ _ _ _ =
  exprRuleVisitors whenUnlessExcl whenUnlessOf whenUnlessFinding

whenUnlessFinding : Option Loc -> Expr -> Finding
whenUnlessFinding loc rewritten = Finding {
  rule = ruleNameWhenUnless,
  message =
    "conditional effect with a `pure ()` branch. Rewrite as '"
      ++ exprToString rewritten
      ++ "'",
  severity = SevWarning,
  loc = loc,
  fix = None,
}

whenUnlessFix : Oracle -> Decl -> Option (List Decl)
whenUnlessFix _ d = exprRuleFix whenUnlessExcl (detApply whenUnlessOf) d
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleVisitors" false) (mem "exprRuleFix" false) (mem "isEVarNamed" false) (mem "ruleNameWhenUnless" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameWhenUnless")) (fa "summary" (ELit (LString "`if b then m else pure ()` / `if b then pure () else m`. Prefer `when b m` / `unless b m`"))) (fa "doc" (ELit (LString "An `if` with `pure ()` in one branch is `when` or `unless`.\n\nBefore:\n  if b then act else pure ()\nAfter:\n  when b act"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleWhenUnless")) (EApp (EVar "Some") (EVar "whenUnlessFix"))))
(DTypeSig false "whenUnlessExcl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "whenUnlessExcl" ((PVar "name")) (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "when"))) (EBinOp "==" (EVar "name") (ELit (LString "unless")))))
(DTypeSig false "isPureUnit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isPureUnit" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "hd") (PVar "arg")) () (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (ELit (LString "pure"))) (EVar "hd")) (EApp (EVar "isUnitLit") (EApp (EVar "unwrapLoc") (EVar "arg"))))) (arm PWild () (EVar "False"))))
(DTypeSig false "isUnitLit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isUnitLit" ((PCon "ELit" (PCon "LUnit"))) (EVar "True"))
(DFunDef false "isUnitLit" (PWild) (EVar "False"))
(DTypeSig false "whenUnlessOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "whenUnlessOf" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EIf (EApp (EVar "isPureUnit") (EVar "el")) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "when")))) (EVar "c"))) (EVar "t"))) (EIf (EApp (EVar "isPureUnit") (EVar "t")) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "unless")))) (EVar "c"))) (EVar "el"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "whenUnlessOf" (PWild) (EVar "None"))
(DTypeSig false "ruleWhenUnless" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleWhenUnless" (PWild PWild PWild PWild PWild) (EApp (EApp (EApp (EVar "exprRuleVisitors") (EVar "whenUnlessExcl")) (EVar "whenUnlessOf")) (EVar "whenUnlessFinding")))
(DTypeSig false "whenUnlessFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "whenUnlessFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameWhenUnless")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "conditional effect with a `pure ()` branch. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "whenUnlessFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "whenUnlessFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "whenUnlessExcl")) (EApp (EVar "detApply") (EVar "whenUnlessOf"))) (EVar "d")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleVisitors" false) (mem "exprRuleFix" false) (mem "isEVarNamed" false) (mem "ruleNameWhenUnless" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameWhenUnless")) (fa "summary" (ELit (LString "`if b then m else pure ()` / `if b then pure () else m`. Prefer `when b m` / `unless b m`"))) (fa "doc" (ELit (LString "An `if` with `pure ()` in one branch is `when` or `unless`.\n\nBefore:\n  if b then act else pure ()\nAfter:\n  when b act"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleWhenUnless")) (EApp (EVar "Some") (EVar "whenUnlessFix"))))
(DTypeSig false "whenUnlessExcl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "whenUnlessExcl" ((PVar "name")) (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "when"))) (EBinOp "==" (EVar "name") (ELit (LString "unless")))))
(DTypeSig false "isPureUnit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isPureUnit" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "hd") (PVar "arg")) () (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (ELit (LString "pure"))) (EVar "hd")) (EApp (EVar "isUnitLit") (EApp (EVar "unwrapLoc") (EVar "arg"))))) (arm PWild () (EVar "False"))))
(DTypeSig false "isUnitLit" (TyFun (TyCon "Expr") (TyCon "Bool")))
(DFunDef false "isUnitLit" ((PCon "ELit" (PCon "LUnit"))) (EVar "True"))
(DFunDef false "isUnitLit" (PWild) (EVar "False"))
(DTypeSig false "whenUnlessOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "whenUnlessOf" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EIf (EApp (EVar "isPureUnit") (EVar "el")) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "when")))) (EVar "c"))) (EVar "t"))) (EIf (EApp (EVar "isPureUnit") (EVar "t")) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "unless")))) (EVar "c"))) (EVar "el"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DFunDef false "whenUnlessOf" (PWild) (EVar "None"))
(DTypeSig false "ruleWhenUnless" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleWhenUnless" (PWild PWild PWild PWild PWild) (EApp (EApp (EApp (EVar "exprRuleVisitors") (EVar "whenUnlessExcl")) (EVar "whenUnlessOf")) (EVar "whenUnlessFinding")))
(DTypeSig false "whenUnlessFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "whenUnlessFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameWhenUnless")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "conditional effect with a `pure ()` branch. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "whenUnlessFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "whenUnlessFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "whenUnlessExcl")) (EApp (EVar "detApply") (EVar "whenUnlessOf"))) (EVar "d")))
