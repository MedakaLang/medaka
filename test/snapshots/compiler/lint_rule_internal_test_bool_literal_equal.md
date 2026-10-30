# META
source_lines=104
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-test-bool-literal-equal: `expectEqual` against a `True`/`False` literal. Prefer `expectTrue` / `expectFalse`.

import frontend.ast.{
  Loc(..),
  Expr(..),
  Decl(..),
}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import tools.printer.{exprToString}
import frontend.exhaust.{Oracle}
import tools.lint_core.{
  Category(..),
  FileFacts(..),
  Finding(..),
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
  detApply,
  exprRuleVisitors,
  exprRuleFixTestDecls,
  isBoolLit,
  isEVarNamed,
  isFalseLit,
  isTrueLit,
  noExcl,
  ruleNameTestBoolLiteralEqual,
  unwrapLoc,
}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameTestBoolLiteralEqual,
      summary =
        "`expectEqual` against a `True`/`False` literal (either side). Prefer `expectTrue e` / `expectFalse e`",
      doc =
        "`expectEqual` against a `True`/`False` literal loses the operand in the failure message; use `expectTrue`/`expectFalse`. `--fix` rewrites it only where every verb involved is `test`'s own import: a verb that resolves to a local or top-level binding, or to another module's import, is left alone.\n\nBefore:\n  expectEqual True (a == 1)\nAfter:\n  expectTrue (a == 1)",
      category = Style,
      scope = Internal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [NeedsScopes],
    }
    ruleTestBoolLiteralEqual
    (Some testBoolLiteralEqualFix)

-- `expectEqual True e` → `expectTrue e`; `expectEqual False e` → `expectFalse e`,
-- and the same with the literal on the RIGHT.  The rewrite is total: `expectTrue`
-- and `expectFalse` are `Bool -> Expectation`, so the literal operand carries no
-- information the named verb does not already carry, and dropping it also drops
-- `expectEqual`'s `Debug` obligation rather than adding one.
--
-- A literal on BOTH sides (`expectEqual True False`) is left alone: neither
-- operand is the subject under test, so there is no `e` to hand the named verb.
testBoolLitEqOf : Expr -> Option Expr
testBoolLitEqOf (EApp hd b) = match unwrapLoc hd
  EApp f a =>
    if isEVarNamed "expectEqual" f then testBoolLitEqSwap a b else None
  _ => None
testBoolLitEqOf _ = None

testBoolLitEqSwap : Expr -> Expr -> Option Expr
testBoolLitEqSwap a b
  | isBoolLit (unwrapLoc a) && isBoolLit (unwrapLoc b) = None
  | isTrueLit (unwrapLoc a) = Some (EApp (EVar "expectTrue") b)
  | isFalseLit (unwrapLoc a) = Some (EApp (EVar "expectFalse") b)
  | isTrueLit (unwrapLoc b) = Some (EApp (EVar "expectTrue") a)
  | isFalseLit (unwrapLoc b) = Some (EApp (EVar "expectFalse") a)
  | otherwise = None

ruleTestBoolLiteralEqual : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleTestBoolLiteralEqual _ _ _ _ _ =
  exprRuleVisitors noExcl testBoolLitEqOf testBoolLitEqFinding

testBoolLitEqFinding : Option Loc -> Expr -> Finding
testBoolLitEqFinding loc rewritten = Finding {
  rule = ruleNameTestBoolLiteralEqual,
  message =
    "`expectEqual` against a boolean literal. Rewrite as '\{exprToString rewritten}'",
  severity = SevWarning,
  loc = loc,
  fix = None,
}

testBoolLiteralEqualFix : Oracle -> Decl -> Option (List Decl)
testBoolLiteralEqualFix _ d =
  exprRuleFixTestDecls noExcl (detApply testBoolLitEqOf) d
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleVisitors" false) (mem "exprRuleFixTestDecls" false) (mem "isBoolLit" false) (mem "isEVarNamed" false) (mem "isFalseLit" false) (mem "isTrueLit" false) (mem "noExcl" false) (mem "ruleNameTestBoolLiteralEqual" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameTestBoolLiteralEqual")) (fa "summary" (ELit (LString "`expectEqual` against a `True`/`False` literal (either side). Prefer `expectTrue e` / `expectFalse e`"))) (fa "doc" (ELit (LString "`expectEqual` against a `True`/`False` literal loses the operand in the failure message; use `expectTrue`/`expectFalse`. `--fix` rewrites it only where every verb involved is `test`'s own import: a verb that resolves to a local or top-level binding, or to another module's import, is left alone.\n\nBefore:\n  expectEqual True (a == 1)\nAfter:\n  expectTrue (a == 1)"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleTestBoolLiteralEqual")) (EApp (EVar "Some") (EVar "testBoolLiteralEqualFix"))))
(DTypeSig false "testBoolLitEqOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "testBoolLitEqOf" ((PCon "EApp" (PVar "hd") (PVar "b"))) (EMatch (EApp (EVar "unwrapLoc") (EVar "hd")) (arm (PCon "EApp" (PVar "f") (PVar "a")) () (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "expectEqual"))) (EVar "f")) (EApp (EApp (EVar "testBoolLitEqSwap") (EVar "a")) (EVar "b")) (EVar "None"))) (arm PWild () (EVar "None"))))
(DFunDef false "testBoolLitEqOf" (PWild) (EVar "None"))
(DTypeSig false "testBoolLitEqSwap" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "testBoolLitEqSwap" ((PVar "a") (PVar "b")) (EIf (EBinOp "&&" (EApp (EVar "isBoolLit") (EApp (EVar "unwrapLoc") (EVar "a"))) (EApp (EVar "isBoolLit") (EApp (EVar "unwrapLoc") (EVar "b")))) (EVar "None") (EIf (EApp (EVar "isTrueLit") (EApp (EVar "unwrapLoc") (EVar "a"))) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "expectTrue")))) (EVar "b"))) (EIf (EApp (EVar "isFalseLit") (EApp (EVar "unwrapLoc") (EVar "a"))) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "expectFalse")))) (EVar "b"))) (EIf (EApp (EVar "isTrueLit") (EApp (EVar "unwrapLoc") (EVar "b"))) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "expectTrue")))) (EVar "a"))) (EIf (EApp (EVar "isFalseLit") (EApp (EVar "unwrapLoc") (EVar "b"))) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "expectFalse")))) (EVar "a"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "ruleTestBoolLiteralEqual" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleTestBoolLiteralEqual" (PWild PWild PWild PWild PWild) (EApp (EApp (EApp (EVar "exprRuleVisitors") (EVar "noExcl")) (EVar "testBoolLitEqOf")) (EVar "testBoolLitEqFinding")))
(DTypeSig false "testBoolLitEqFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "testBoolLitEqFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameTestBoolLiteralEqual")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`expectEqual` against a boolean literal. Rewrite as '")) (EApp (EVar "display") (EApp (EVar "exprToString") (EVar "rewritten")))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "testBoolLiteralEqualFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "testBoolLiteralEqualFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFixTestDecls") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "testBoolLitEqOf"))) (EVar "d")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleVisitors" false) (mem "exprRuleFixTestDecls" false) (mem "isBoolLit" false) (mem "isEVarNamed" false) (mem "isFalseLit" false) (mem "isTrueLit" false) (mem "noExcl" false) (mem "ruleNameTestBoolLiteralEqual" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameTestBoolLiteralEqual")) (fa "summary" (ELit (LString "`expectEqual` against a `True`/`False` literal (either side). Prefer `expectTrue e` / `expectFalse e`"))) (fa "doc" (ELit (LString "`expectEqual` against a `True`/`False` literal loses the operand in the failure message; use `expectTrue`/`expectFalse`. `--fix` rewrites it only where every verb involved is `test`'s own import: a verb that resolves to a local or top-level binding, or to another module's import, is left alone.\n\nBefore:\n  expectEqual True (a == 1)\nAfter:\n  expectTrue (a == 1)"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleTestBoolLiteralEqual")) (EApp (EVar "Some") (EVar "testBoolLiteralEqualFix"))))
(DTypeSig false "testBoolLitEqOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "testBoolLitEqOf" ((PCon "EApp" (PVar "hd") (PVar "b"))) (EMatch (EApp (EVar "unwrapLoc") (EVar "hd")) (arm (PCon "EApp" (PVar "f") (PVar "a")) () (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "expectEqual"))) (EVar "f")) (EApp (EApp (EVar "testBoolLitEqSwap") (EVar "a")) (EVar "b")) (EVar "None"))) (arm PWild () (EVar "None"))))
(DFunDef false "testBoolLitEqOf" (PWild) (EVar "None"))
(DTypeSig false "testBoolLitEqSwap" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "testBoolLitEqSwap" ((PVar "a") (PVar "b")) (EIf (EBinOp "&&" (EApp (EVar "isBoolLit") (EApp (EVar "unwrapLoc") (EVar "a"))) (EApp (EVar "isBoolLit") (EApp (EVar "unwrapLoc") (EVar "b")))) (EVar "None") (EIf (EApp (EVar "isTrueLit") (EApp (EVar "unwrapLoc") (EVar "a"))) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "expectTrue")))) (EVar "b"))) (EIf (EApp (EVar "isFalseLit") (EApp (EVar "unwrapLoc") (EVar "a"))) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "expectFalse")))) (EVar "b"))) (EIf (EApp (EVar "isTrueLit") (EApp (EVar "unwrapLoc") (EVar "b"))) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "expectTrue")))) (EVar "a"))) (EIf (EApp (EVar "isFalseLit") (EApp (EVar "unwrapLoc") (EVar "b"))) (EApp (EVar "Some") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "expectFalse")))) (EVar "a"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))))))
(DTypeSig false "ruleTestBoolLiteralEqual" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleTestBoolLiteralEqual" (PWild PWild PWild PWild PWild) (EApp (EApp (EApp (EVar "exprRuleVisitors") (EVar "noExcl")) (EVar "testBoolLitEqOf")) (EVar "testBoolLitEqFinding")))
(DTypeSig false "testBoolLitEqFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "testBoolLitEqFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameTestBoolLiteralEqual")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "`expectEqual` against a boolean literal. Rewrite as '")) (EApp (EMethodRef "display") (EApp (EVar "exprToString") (EVar "rewritten")))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "testBoolLiteralEqualFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "testBoolLiteralEqualFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFixTestDecls") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "testBoolLitEqOf"))) (EVar "d")))
