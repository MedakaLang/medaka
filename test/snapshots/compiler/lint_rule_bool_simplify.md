# META
source_lines=116
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-bool-simplify: a redundant boolean shape (`if c then True else False`, `x == True`, `not (not x)`). Simplify.

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
  isBoolLit,
  isFalseLit,
  isTrueLit,
  noExcl,
  notArgOf,
  ruleNameBoolSimplify,
  unwrapLoc,
}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameBoolSimplify,
      summary =
        "redundant boolean shape (`if c then True else False`, `x == True`, `not (not x)`, …). Simplify",
      doc =
        "A boolean expression with a redundant shape: `if c then True else False`, `x == True`, `not (not x)`. Each simplifies to a shorter equivalent.\n\nBefore:\n  if ok then True else False\nAfter:\n  ok",
      category = Complexity,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleBoolSimplify
    (Some boolSimplifyFix)

-- build `not e` in the canonical `not <e>` (prelude fn) form the printer renders.
mkNot : Expr -> Expr
mkNot e = EApp (EVar "not") e

-- ── rule: bool-simplify ───────────────────────────────────────────────────────
-- Redundant boolean shapes, each rewritten to an EXACTLY equivalent one:
--   if c then True else False → c        if c then False else True → not c
--   x == True → x        x == False → not x        (also True/False on the LEFT)
--   x /= True → not x    x /= False → x
--   not (not x) → x
-- Excluded (per spec): `if c then True else e` → `c || e` (short-circuit/effect
-- risk).  A comparison with bool literals on BOTH sides is left alone.
boolSimplifyOf : Expr -> Option Expr
boolSimplifyOf (EIf c t el) = boolSimplifyIf c (unwrapLoc t) (unwrapLoc el)
boolSimplifyOf (EBinOp op a b _)
  | op == "==" || op == "/=" = boolSimplifyEq op a b
boolSimplifyOf e = match notArgOf e
  Some inner => map (y => y) (notArgOf (unwrapLoc inner))
  None => None

boolSimplifyIf : Expr -> Expr -> Expr -> Option Expr
boolSimplifyIf c t el
  | isTrueLit t && isFalseLit el = Some c
  | isFalseLit t && isTrueLit el = Some (mkNot c)
  | otherwise = None

boolSimplifyEq : String -> Expr -> Expr -> Option Expr
boolSimplifyEq op a b
  | isBoolLit a && isBoolLit b = None
  | isTrueLit b = Some (boolEqResult op a True)
  | isFalseLit b = Some (boolEqResult op a False)
  | isTrueLit a = Some (boolEqResult op b True)
  | isFalseLit a = Some (boolEqResult op b False)
  | otherwise = None

-- the value operand `v`, negated iff (`==` against `False`) or (`/=` against
-- `True`): `keepPositive = (op == "==") == constIsTrue`.
boolEqResult : String -> Expr -> Bool -> Expr
boolEqResult op v constIsTrue = if op == "==" == constIsTrue then v else mkNot v

ruleBoolSimplify : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleBoolSimplify _ _ _ _ _ =
  exprRuleVisitors noExcl boolSimplifyOf boolSimplifyFinding

boolSimplifyFinding : Option Loc -> Expr -> Finding
boolSimplifyFinding loc rewritten = Finding {
  rule = ruleNameBoolSimplify,
  message =
    "redundant boolean expression — rewrite as '"
      ++ exprToString rewritten
      ++ "'",
  severity = SevWarning,
  loc = loc,
  fix = None,
}

boolSimplifyFix : Oracle -> Decl -> Option (List Decl)
boolSimplifyFix _ d = exprRuleFix noExcl (detApply boolSimplifyOf) d
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleVisitors" false) (mem "exprRuleFix" false) (mem "isBoolLit" false) (mem "isFalseLit" false) (mem "isTrueLit" false) (mem "noExcl" false) (mem "notArgOf" false) (mem "ruleNameBoolSimplify" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameBoolSimplify")) (fa "summary" (ELit (LString "redundant boolean shape (`if c then True else False`, `x == True`, `not (not x)`, …). Simplify"))) (fa "doc" (ELit (LString "A boolean expression with a redundant shape: `if c then True else False`, `x == True`, `not (not x)`. Each simplifies to a shorter equivalent.\n\nBefore:\n  if ok then True else False\nAfter:\n  ok"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleBoolSimplify")) (EApp (EVar "Some") (EVar "boolSimplifyFix"))))
(DTypeSig false "mkNot" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "mkNot" ((PVar "e")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "not")))) (EVar "e")))
(DTypeSig false "boolSimplifyOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "boolSimplifyOf" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "boolSimplifyIf") (EVar "c")) (EApp (EVar "unwrapLoc") (EVar "t"))) (EApp (EVar "unwrapLoc") (EVar "el"))))
(DFunDef false "boolSimplifyOf" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "=="))) (EBinOp "==" (EVar "op") (ELit (LString "/=")))) (EApp (EApp (EApp (EVar "boolSimplifyEq") (EVar "op")) (EVar "a")) (EVar "b")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "boolSimplifyOf" ((PVar "e")) (EMatch (EApp (EVar "notArgOf") (EVar "e")) (arm (PCon "Some" (PVar "inner")) () (EApp (EApp (EVar "map") (ELam ((PVar "y")) (EVar "y"))) (EApp (EVar "notArgOf") (EApp (EVar "unwrapLoc") (EVar "inner"))))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "boolSimplifyIf" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "boolSimplifyIf" ((PVar "c") (PVar "t") (PVar "el")) (EIf (EBinOp "&&" (EApp (EVar "isTrueLit") (EVar "t")) (EApp (EVar "isFalseLit") (EVar "el"))) (EApp (EVar "Some") (EVar "c")) (EIf (EBinOp "&&" (EApp (EVar "isFalseLit") (EVar "t")) (EApp (EVar "isTrueLit") (EVar "el"))) (EApp (EVar "Some") (EApp (EVar "mkNot") (EVar "c"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "boolSimplifyEq" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "boolSimplifyEq" ((PVar "op") (PVar "a") (PVar "b")) (EIf (EBinOp "&&" (EApp (EVar "isBoolLit") (EVar "a")) (EApp (EVar "isBoolLit") (EVar "b"))) (EVar "None") (EIf (EApp (EVar "isTrueLit") (EVar "b")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "boolEqResult") (EVar "op")) (EVar "a")) (EVar "True"))) (EIf (EApp (EVar "isFalseLit") (EVar "b")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "boolEqResult") (EVar "op")) (EVar "a")) (EVar "False"))) (EIf (EApp (EVar "isTrueLit") (EVar "a")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "boolEqResult") (EVar "op")) (EVar "b")) (EVar "True"))) (EIf (EApp (EVar "isFalseLit") (EVar "a")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "boolEqResult") (EVar "op")) (EVar "b")) (EVar "False"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "boolEqResult" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Bool") (TyCon "Expr")))))
(DFunDef false "boolEqResult" ((PVar "op") (PVar "v") (PVar "constIsTrue")) (EIf (EBinOp "==" (EBinOp "==" (EVar "op") (ELit (LString "=="))) (EVar "constIsTrue")) (EVar "v") (EApp (EVar "mkNot") (EVar "v"))))
(DTypeSig false "ruleBoolSimplify" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleBoolSimplify" (PWild PWild PWild PWild PWild) (EApp (EApp (EApp (EVar "exprRuleVisitors") (EVar "noExcl")) (EVar "boolSimplifyOf")) (EVar "boolSimplifyFinding")))
(DTypeSig false "boolSimplifyFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "boolSimplifyFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameBoolSimplify")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "redundant boolean expression — rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "boolSimplifyFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "boolSimplifyFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "boolSimplifyOf"))) (EVar "d")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleVisitors" false) (mem "exprRuleFix" false) (mem "isBoolLit" false) (mem "isFalseLit" false) (mem "isTrueLit" false) (mem "noExcl" false) (mem "notArgOf" false) (mem "ruleNameBoolSimplify" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameBoolSimplify")) (fa "summary" (ELit (LString "redundant boolean shape (`if c then True else False`, `x == True`, `not (not x)`, …). Simplify"))) (fa "doc" (ELit (LString "A boolean expression with a redundant shape: `if c then True else False`, `x == True`, `not (not x)`. Each simplifies to a shorter equivalent.\n\nBefore:\n  if ok then True else False\nAfter:\n  ok"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleBoolSimplify")) (EApp (EVar "Some") (EVar "boolSimplifyFix"))))
(DTypeSig false "mkNot" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "mkNot" ((PVar "e")) (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "not")))) (EVar "e")))
(DTypeSig false "boolSimplifyOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "boolSimplifyOf" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "boolSimplifyIf") (EVar "c")) (EApp (EVar "unwrapLoc") (EVar "t"))) (EApp (EVar "unwrapLoc") (EVar "el"))))
(DFunDef false "boolSimplifyOf" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") PWild)) (EIf (EBinOp "||" (EBinOp "==" (EVar "op") (ELit (LString "=="))) (EBinOp "==" (EVar "op") (ELit (LString "/=")))) (EApp (EApp (EApp (EVar "boolSimplifyEq") (EVar "op")) (EVar "a")) (EVar "b")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "boolSimplifyOf" ((PVar "e")) (EMatch (EApp (EVar "notArgOf") (EVar "e")) (arm (PCon "Some" (PVar "inner")) () (EApp (EApp (EMethodRef "map") (ELam ((PVar "y")) (EVar "y"))) (EApp (EVar "notArgOf") (EApp (EVar "unwrapLoc") (EVar "inner"))))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "boolSimplifyIf" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "boolSimplifyIf" ((PVar "c") (PVar "t") (PVar "el")) (EIf (EBinOp "&&" (EApp (EVar "isTrueLit") (EVar "t")) (EApp (EVar "isFalseLit") (EVar "el"))) (EApp (EVar "Some") (EVar "c")) (EIf (EBinOp "&&" (EApp (EVar "isFalseLit") (EVar "t")) (EApp (EVar "isTrueLit") (EVar "el"))) (EApp (EVar "Some") (EApp (EVar "mkNot") (EVar "c"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "boolSimplifyEq" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "boolSimplifyEq" ((PVar "op") (PVar "a") (PVar "b")) (EIf (EBinOp "&&" (EApp (EVar "isBoolLit") (EVar "a")) (EApp (EVar "isBoolLit") (EVar "b"))) (EVar "None") (EIf (EApp (EVar "isTrueLit") (EVar "b")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "boolEqResult") (EVar "op")) (EVar "a")) (EVar "True"))) (EIf (EApp (EVar "isFalseLit") (EVar "b")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "boolEqResult") (EVar "op")) (EVar "a")) (EVar "False"))) (EIf (EApp (EVar "isTrueLit") (EVar "a")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "boolEqResult") (EVar "op")) (EVar "b")) (EVar "True"))) (EIf (EApp (EVar "isFalseLit") (EVar "a")) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "boolEqResult") (EVar "op")) (EVar "b")) (EVar "False"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "boolEqResult" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Bool") (TyCon "Expr")))))
(DFunDef false "boolEqResult" ((PVar "op") (PVar "v") (PVar "constIsTrue")) (EIf (EBinOp "==" (EBinOp "==" (EVar "op") (ELit (LString "=="))) (EVar "constIsTrue")) (EVar "v") (EApp (EVar "mkNot") (EVar "v"))))
(DTypeSig false "ruleBoolSimplify" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleBoolSimplify" (PWild PWild PWild PWild PWild) (EApp (EApp (EApp (EVar "exprRuleVisitors") (EVar "noExcl")) (EVar "boolSimplifyOf")) (EVar "boolSimplifyFinding")))
(DTypeSig false "boolSimplifyFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "boolSimplifyFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameBoolSimplify")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "redundant boolean expression — rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "boolSimplifyFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "boolSimplifyFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "boolSimplifyOf"))) (EVar "d")))
