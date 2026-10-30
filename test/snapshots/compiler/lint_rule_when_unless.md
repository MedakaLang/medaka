# META
source_lines=117
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-when-unless: an `if` with a `pure ()` branch. Prefer `when` / `unless`.

import frontend.ast.{Loc(..), Lit(..), Expr(..), Decl(..)}
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
  bindsName,
  exprRuleEditVisitors,
  isEVarNamed,
  nodeSpan,
  replaceFix,
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
      needs = [NeedsScopes],
    }
    ruleWhenUnless
    None

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
ruleWhenUnless _ _ facts _ _ =
  exprRuleEditVisitors
    whenUnlessExcl
    whenUnlessOf
    (whenUnlessFix facts)
    whenUnlessFinding

whenUnlessFinding : Option Loc -> Expr -> Option Fix -> Finding
whenUnlessFinding loc rewritten fix = Finding {
  rule = ruleNameWhenUnless,
  message =
    "conditional effect with a `pure ()` branch. Rewrite as '"
      ++ exprToString rewritten
      ++ "'",
  severity = SevWarning,
  loc = loc,
  fix = fix,
}

-- The rewrite reads `pure` (the dropped `pure ()`) and calls `when` or `unless`.
-- A binding of any of the three names in the file withholds the fix.
whenUnlessFix : FileFacts -> Ctx -> Expr -> Expr -> Option Fix
whenUnlessFix facts ctx e rewritten =
  if bindsName facts "pure"
    || bindsName facts "when"
    || bindsName facts "unless" then
    None
  else
    replaceFix
      "use when / unless"
      (nodeSpan ctx e)
      (bindingOf rewritten)
      ctx
      (exprToString rewritten)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "bindingOf" false) (mem "bindsName" false) (mem "exprRuleEditVisitors" false) (mem "isEVarNamed" false) (mem "nodeSpan" false) (mem "replaceFix" false) (mem "ruleNameWhenUnless" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameWhenUnless")) (fa "summary" (ELit (LString "`if b then m else pure ()` / `if b then pure () else m`. Prefer `when b m` / `unless b m`"))) (fa "doc" (ELit (LString "An `if` with `pure ()` in one branch is `when` or `unless`.\n\nBefore:\n  if b then act else pure ()\nAfter:\n  when b act"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleWhenUnless")) (EVar "None")))
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
(DFunDef false "ruleWhenUnless" (PWild PWild (PVar "facts") PWild PWild) (EApp (EApp (EApp (EApp (EVar "exprRuleEditVisitors") (EVar "whenUnlessExcl")) (EVar "whenUnlessOf")) (EApp (EVar "whenUnlessFix") (EVar "facts"))) (EVar "whenUnlessFinding")))
(DTypeSig false "whenUnlessFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "whenUnlessFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameWhenUnless")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "conditional effect with a `pure ()` branch. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "whenUnlessFix" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix")))))))
(DFunDef false "whenUnlessFix" ((PVar "facts") (PVar "ctx") (PVar "e") (PVar "rewritten")) (EIf (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "bindsName") (EVar "facts")) (ELit (LString "pure"))) (EApp (EApp (EVar "bindsName") (EVar "facts")) (ELit (LString "when")))) (EApp (EApp (EVar "bindsName") (EVar "facts")) (ELit (LString "unless")))) (EVar "None") (EApp (EApp (EApp (EApp (EApp (EVar "replaceFix") (ELit (LString "use when / unless"))) (EApp (EApp (EVar "nodeSpan") (EVar "ctx")) (EVar "e"))) (EApp (EVar "bindingOf") (EVar "rewritten"))) (EVar "ctx")) (EApp (EVar "exprToString") (EVar "rewritten")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Lit" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "bindingOf" false) (mem "bindsName" false) (mem "exprRuleEditVisitors" false) (mem "isEVarNamed" false) (mem "nodeSpan" false) (mem "replaceFix" false) (mem "ruleNameWhenUnless" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameWhenUnless")) (fa "summary" (ELit (LString "`if b then m else pure ()` / `if b then pure () else m`. Prefer `when b m` / `unless b m`"))) (fa "doc" (ELit (LString "An `if` with `pure ()` in one branch is `when` or `unless`.\n\nBefore:\n  if b then act else pure ()\nAfter:\n  when b act"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleWhenUnless")) (EVar "None")))
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
(DFunDef false "ruleWhenUnless" (PWild PWild (PVar "facts") PWild PWild) (EApp (EApp (EApp (EApp (EVar "exprRuleEditVisitors") (EVar "whenUnlessExcl")) (EVar "whenUnlessOf")) (EApp (EVar "whenUnlessFix") (EVar "facts"))) (EVar "whenUnlessFinding")))
(DTypeSig false "whenUnlessFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "whenUnlessFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameWhenUnless")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "conditional effect with a `pure ()` branch. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "whenUnlessFix" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix")))))))
(DFunDef false "whenUnlessFix" ((PVar "facts") (PVar "ctx") (PVar "e") (PVar "rewritten")) (EIf (EBinOp "||" (EBinOp "||" (EApp (EApp (EVar "bindsName") (EVar "facts")) (ELit (LString "pure"))) (EApp (EApp (EVar "bindsName") (EVar "facts")) (ELit (LString "when")))) (EApp (EApp (EVar "bindsName") (EVar "facts")) (ELit (LString "unless")))) (EVar "None") (EApp (EApp (EApp (EApp (EApp (EVar "replaceFix") (ELit (LString "use when / unless"))) (EApp (EApp (EVar "nodeSpan") (EVar "ctx")) (EVar "e"))) (EApp (EVar "bindingOf") (EVar "rewritten"))) (EVar "ctx")) (EApp (EVar "exprToString") (EVar "rewritten")))))
