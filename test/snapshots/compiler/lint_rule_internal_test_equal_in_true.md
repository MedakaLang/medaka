# META
source_lines=106
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-test-equal-in-true: an `==`/`/=` wrapped in `expectTrue`/`expectFalse`. Prefer `expectEqual`/`expectNotEqual`.

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
  isEVarNamed,
  noExcl,
  ruleNameTestEqualInTrue,
  unwrapLoc,
}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameTestEqualInTrue,
      summary =
        "an `==`/`/=` comparison wrapped in `expectTrue`/`expectFalse`. Prefer `expectEqual a b` / `expectNotEqual a b`, which report both operands on failure",
      doc =
        "An `==`/`/=` comparison wrapped in `expectTrue`/`expectFalse` reports neither operand on failure; use `expectEqual`/`expectNotEqual`. `--fix` rewrites it only where every verb involved is `test`'s own import: a verb that resolves to a local or top-level binding, or to another module's import, is left alone.\n\nBefore:\n  expectTrue (a == b)\nAfter:\n  expectEqual a b",
      category = Style,
      scope = Internal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [NeedsScopes],
    }
    ruleTestEqualInTrue
    (Some testEqualInTrueFix)

-- ── rule: test-equal-in-true ──────────────────────────────────────────────────
-- `expectTrue (a == b)` → `expectEqual a b`, `expectTrue (a /= b)` →
-- `expectNotEqual a b`, and the `expectFalse` forms with the verb's polarity
-- flipped.  The point is the FAILURE MESSAGE, not the assertion: `expectTrue`
-- can only report "expected True, got False", where the equality verbs render
-- both operands.
--
-- ONLY `==`/`/=`, for the same reason `rule-not-eq` excludes the orderings: a
-- rewrite of `expectTrue (a < b)` would need an ordering-aware verb, a
-- different one per operator, and the `expectFalse` polarity flip of an
-- ordering is unsound for `Float` (NaN makes `not (a < b)` ≠ `a >= b`).
--
-- `expectEqual`/`expectNotEqual` carry a `Debug a` obligation that `expectTrue`
-- does not, and a lint rule has no type environment to discharge it, so `--fix`
-- on a comparison of a type with no `Debug` impl produces a file that no longer
-- typechecks.  That failure is LOUD (the next `check` rejects it), which is what
-- licenses shipping the fix at all.
testEqInTrueOf : Expr -> Option Expr
testEqInTrueOf (EApp hd arg)
  | isEVarNamed "expectTrue" hd = testEqVerbOf False (unwrapLoc arg)
  | isEVarNamed "expectFalse" hd = testEqVerbOf True (unwrapLoc arg)
testEqInTrueOf _ = None

-- `negated` = the wrapper was `expectFalse`, so the verb the operator names is
-- replaced by its complement.
testEqVerbOf : Bool -> Expr -> Option Expr
testEqVerbOf negated (EBinOp "==" a b _) =
  Some (testEqCall (if negated then "expectNotEqual" else "expectEqual") a b)
testEqVerbOf negated (EBinOp "/=" a b _) =
  Some (testEqCall (if negated then "expectEqual" else "expectNotEqual") a b)
testEqVerbOf _ _ = None

testEqCall : String -> Expr -> Expr -> Expr
testEqCall nm a b = EApp (EApp (EVar nm) a) b

ruleTestEqualInTrue : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleTestEqualInTrue _ _ _ _ _ =
  exprRuleVisitors noExcl testEqInTrueOf testEqInTrueFinding

testEqInTrueFinding : Option Loc -> Expr -> Finding
testEqInTrueFinding loc rewritten = Finding {
  rule = ruleNameTestEqualInTrue,
  message =
    "an equality comparison inside `expectTrue`/`expectFalse` reports neither operand on failure. Rewrite as '\{exprToString rewritten}'",
  severity = SevWarning,
  loc = loc,
}

testEqualInTrueFix : Oracle -> Decl -> Option (List Decl)
testEqualInTrueFix _ d = exprRuleFixTestDecls noExcl (detApply testEqInTrueOf) d
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleVisitors" false) (mem "exprRuleFixTestDecls" false) (mem "isEVarNamed" false) (mem "noExcl" false) (mem "ruleNameTestEqualInTrue" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameTestEqualInTrue")) (fa "summary" (ELit (LString "an `==`/`/=` comparison wrapped in `expectTrue`/`expectFalse`. Prefer `expectEqual a b` / `expectNotEqual a b`, which report both operands on failure"))) (fa "doc" (ELit (LString "An `==`/`/=` comparison wrapped in `expectTrue`/`expectFalse` reports neither operand on failure; use `expectEqual`/`expectNotEqual`. `--fix` rewrites it only where every verb involved is `test`'s own import: a verb that resolves to a local or top-level binding, or to another module's import, is left alone.\n\nBefore:\n  expectTrue (a == b)\nAfter:\n  expectEqual a b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleTestEqualInTrue")) (EApp (EVar "Some") (EVar "testEqualInTrueFix"))))
(DTypeSig false "testEqInTrueOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "testEqInTrueOf" ((PCon "EApp" (PVar "hd") (PVar "arg"))) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "expectTrue"))) (EVar "hd")) (EApp (EApp (EVar "testEqVerbOf") (EVar "False")) (EApp (EVar "unwrapLoc") (EVar "arg"))) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "expectFalse"))) (EVar "hd")) (EApp (EApp (EVar "testEqVerbOf") (EVar "True")) (EApp (EVar "unwrapLoc") (EVar "arg"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "testEqInTrueOf" (PWild) (EVar "None"))
(DTypeSig false "testEqVerbOf" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "testEqVerbOf" ((PVar "negated") (PCon "EBinOp" (PLit (LString "==")) (PVar "a") (PVar "b") PWild)) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "testEqCall") (EIf (EVar "negated") (ELit (LString "expectNotEqual")) (ELit (LString "expectEqual")))) (EVar "a")) (EVar "b"))))
(DFunDef false "testEqVerbOf" ((PVar "negated") (PCon "EBinOp" (PLit (LString "/=")) (PVar "a") (PVar "b") PWild)) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "testEqCall") (EIf (EVar "negated") (ELit (LString "expectEqual")) (ELit (LString "expectNotEqual")))) (EVar "a")) (EVar "b"))))
(DFunDef false "testEqVerbOf" (PWild PWild) (EVar "None"))
(DTypeSig false "testEqCall" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "testEqCall" ((PVar "nm") (PVar "a") (PVar "b")) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "nm"))) (EVar "a"))) (EVar "b")))
(DTypeSig false "ruleTestEqualInTrue" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleTestEqualInTrue" (PWild PWild PWild PWild PWild) (EApp (EApp (EApp (EVar "exprRuleVisitors") (EVar "noExcl")) (EVar "testEqInTrueOf")) (EVar "testEqInTrueFinding")))
(DTypeSig false "testEqInTrueFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "testEqInTrueFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameTestEqualInTrue")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "an equality comparison inside `expectTrue`/`expectFalse` reports neither operand on failure. Rewrite as '")) (EApp (EVar "display") (EApp (EVar "exprToString") (EVar "rewritten")))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "testEqualInTrueFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "testEqualInTrueFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFixTestDecls") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "testEqInTrueOf"))) (EVar "d")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleVisitors" false) (mem "exprRuleFixTestDecls" false) (mem "isEVarNamed" false) (mem "noExcl" false) (mem "ruleNameTestEqualInTrue" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameTestEqualInTrue")) (fa "summary" (ELit (LString "an `==`/`/=` comparison wrapped in `expectTrue`/`expectFalse`. Prefer `expectEqual a b` / `expectNotEqual a b`, which report both operands on failure"))) (fa "doc" (ELit (LString "An `==`/`/=` comparison wrapped in `expectTrue`/`expectFalse` reports neither operand on failure; use `expectEqual`/`expectNotEqual`. `--fix` rewrites it only where every verb involved is `test`'s own import: a verb that resolves to a local or top-level binding, or to another module's import, is left alone.\n\nBefore:\n  expectTrue (a == b)\nAfter:\n  expectEqual a b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "ruleTestEqualInTrue")) (EApp (EVar "Some") (EVar "testEqualInTrueFix"))))
(DTypeSig false "testEqInTrueOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "testEqInTrueOf" ((PCon "EApp" (PVar "hd") (PVar "arg"))) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "expectTrue"))) (EVar "hd")) (EApp (EApp (EVar "testEqVerbOf") (EVar "False")) (EApp (EVar "unwrapLoc") (EVar "arg"))) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "expectFalse"))) (EVar "hd")) (EApp (EApp (EVar "testEqVerbOf") (EVar "True")) (EApp (EVar "unwrapLoc") (EVar "arg"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "testEqInTrueOf" (PWild) (EVar "None"))
(DTypeSig false "testEqVerbOf" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "testEqVerbOf" ((PVar "negated") (PCon "EBinOp" (PLit (LString "==")) (PVar "a") (PVar "b") PWild)) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "testEqCall") (EIf (EVar "negated") (ELit (LString "expectNotEqual")) (ELit (LString "expectEqual")))) (EVar "a")) (EVar "b"))))
(DFunDef false "testEqVerbOf" ((PVar "negated") (PCon "EBinOp" (PLit (LString "/=")) (PVar "a") (PVar "b") PWild)) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "testEqCall") (EIf (EVar "negated") (ELit (LString "expectEqual")) (ELit (LString "expectNotEqual")))) (EVar "a")) (EVar "b"))))
(DFunDef false "testEqVerbOf" (PWild PWild) (EVar "None"))
(DTypeSig false "testEqCall" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "testEqCall" ((PVar "nm") (PVar "a") (PVar "b")) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (EVar "nm"))) (EVar "a"))) (EVar "b")))
(DTypeSig false "ruleTestEqualInTrue" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleTestEqualInTrue" (PWild PWild PWild PWild PWild) (EApp (EApp (EApp (EVar "exprRuleVisitors") (EVar "noExcl")) (EVar "testEqInTrueOf")) (EVar "testEqInTrueFinding")))
(DTypeSig false "testEqInTrueFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "testEqInTrueFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameTestEqualInTrue")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "an equality comparison inside `expectTrue`/`expectFalse` reports neither operand on failure. Rewrite as '")) (EApp (EMethodRef "display") (EApp (EVar "exprToString") (EVar "rewritten")))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "testEqualInTrueFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "testEqualInTrueFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFixTestDecls") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "testEqInTrueOf"))) (EVar "d")))
