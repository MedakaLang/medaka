# META
source_lines=90
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-not-eq: a negated equality `not (a == b)` / `not (a /= b)`; prefer the operator.

import frontend.ast.{Loc(..), Expr(..), Decl(..)}
import frontend.ast_walk.{ExprKind(..)}
import frontend.parser.{Positions(..)}
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
  notArgOf,
  ruleNameNotEq,
  unwrapLoc,
}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameNotEq,
      summary =
        "negated equality `not (a == b)` / `not (a /= b)`. Prefer `a /= b` / `a == b`",
      doc =
        "A negated equality test has a direct operator.\n\nBefore:\n  not (a == b)\nAfter:\n  a /= b",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    notEqVisitors
    (Some notEqFix)

-- ── rule: not-eq ──────────────────────────────────────────────────────────────
-- `not (a == b)` → `a /= b`; `not (a /= b)` → `a == b` (also the unary-`!` forms).
-- ONLY `==`/`/=` — they are TOTAL, so De Morgan applies unconditionally.  `<`/`>`
-- &c. are deliberately excluded: their complement is unsound for `Float` (NaN
-- makes `not (a < b)` ≠ `a >= b`).  The flipped `EBinOp` reuses the original's
-- site id (the parser's `unminted`; lint output is never typechecked).
notEqOf : Expr -> Option Expr
notEqOf e = match notArgOf e
  Some inner => match unwrapLoc inner
    EBinOp "==" a b r => Some (EBinOp "/=" a b r)
    EBinOp "/=" a b r => Some (EBinOp "==" a b r)
    _ => None
  None => None

-- `notArgOf` matches an application only, so only `EApp` nodes are visited.
notEqVisitors : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
notEqVisitors _ _ _ _ _ = [OnExpr [KApp] notEqAt]

notEqAt : Ctx -> Expr -> List Finding
notEqAt ctx e = match notEqOf e
  Some rewritten => [notEqFinding ctx.ctxSpan rewritten]
  None => []

notEqFinding : Option Loc -> Expr -> Finding
notEqFinding loc rewritten = Finding {
  rule = ruleNameNotEq,
  message = "negated equality. Rewrite as '" ++ exprToString rewritten ++ "'",
  severity = SevWarning,
  loc = loc,
  fix = None,
}

notEqFix : Oracle -> Decl -> Option (List Decl)
notEqFix _ d = exprRuleFix noExcl (detApply notEqOf) d
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleFix" false) (mem "noExcl" false) (mem "notArgOf" false) (mem "ruleNameNotEq" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameNotEq")) (fa "summary" (ELit (LString "negated equality `not (a == b)` / `not (a /= b)`. Prefer `a /= b` / `a == b`"))) (fa "doc" (ELit (LString "A negated equality test has a direct operator.\n\nBefore:\n  not (a == b)\nAfter:\n  a /= b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "notEqVisitors")) (EApp (EVar "Some") (EVar "notEqFix"))))
(DTypeSig false "notEqOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "notEqOf" ((PVar "e")) (EMatch (EApp (EVar "notArgOf") (EVar "e")) (arm (PCon "Some" (PVar "inner")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "inner")) (arm (PCon "EBinOp" (PLit (LString "==")) (PVar "a") (PVar "b") (PVar "r")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString "/="))) (EVar "a")) (EVar "b")) (EVar "r")))) (arm (PCon "EBinOp" (PLit (LString "/=")) (PVar "a") (PVar "b") (PVar "r")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString "=="))) (EVar "a")) (EVar "b")) (EVar "r")))) (arm PWild () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "notEqVisitors" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "notEqVisitors" (PWild PWild PWild PWild PWild) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KApp"))) (EVar "notEqAt"))))
(DTypeSig false "notEqAt" (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "notEqAt" ((PVar "ctx") (PVar "e")) (EMatch (EApp (EVar "notEqOf") (EVar "e")) (arm (PCon "Some" (PVar "rewritten")) () (EListLit (EApp (EApp (EVar "notEqFinding") (EFieldAccess (EVar "ctx") "ctxSpan")) (EVar "rewritten")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "notEqFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "notEqFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameNotEq")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "negated equality. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "notEqFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "notEqFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "notEqOf"))) (EVar "d")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleFix" false) (mem "noExcl" false) (mem "notArgOf" false) (mem "ruleNameNotEq" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameNotEq")) (fa "summary" (ELit (LString "negated equality `not (a == b)` / `not (a /= b)`. Prefer `a /= b` / `a == b`"))) (fa "doc" (ELit (LString "A negated equality test has a direct operator.\n\nBefore:\n  not (a == b)\nAfter:\n  a /= b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "notEqVisitors")) (EApp (EVar "Some") (EVar "notEqFix"))))
(DTypeSig false "notEqOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "notEqOf" ((PVar "e")) (EMatch (EApp (EVar "notArgOf") (EVar "e")) (arm (PCon "Some" (PVar "inner")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "inner")) (arm (PCon "EBinOp" (PLit (LString "==")) (PVar "a") (PVar "b") (PVar "r")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString "/="))) (EVar "a")) (EVar "b")) (EVar "r")))) (arm (PCon "EBinOp" (PLit (LString "/=")) (PVar "a") (PVar "b") (PVar "r")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString "=="))) (EVar "a")) (EVar "b")) (EVar "r")))) (arm PWild () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "notEqVisitors" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "notEqVisitors" (PWild PWild PWild PWild PWild) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KApp"))) (EVar "notEqAt"))))
(DTypeSig false "notEqAt" (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "notEqAt" ((PVar "ctx") (PVar "e")) (EMatch (EApp (EVar "notEqOf") (EVar "e")) (arm (PCon "Some" (PVar "rewritten")) () (EListLit (EApp (EApp (EVar "notEqFinding") (EFieldAccess (EVar "ctx") "ctxSpan")) (EVar "rewritten")))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "notEqFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "notEqFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameNotEq")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "negated equality. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "notEqFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "notEqFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "notEqOf"))) (EVar "d")))
