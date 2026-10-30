# META
source_lines=104
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-not-eq: a negated equality `not (a == b)` / `not (a /= b)`; prefer the operator.

import frontend.ast.{Loc(..), Expr(..), Decl(..)}
import frontend.ast_walk.{ExprKind(..)}
import frontend.parser.{Positions(..)}
import tools.lint_fix.{Binding(..)}
import driver.diagnostics.{Severity(..)}
import tools.printer.{exprToString}
import tools.lint_core.{
  Category(..),
  Ctx(..),
  FileFacts(..),
  Finding(..),
  Fixability(..),
  Fix,
  Need(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  Visitor(..),
  mkVisitorRule,
}
import tools.lint_shared.{
  nodeSpan,
  notArgOf,
  replaceFix,
  ruleNameNotEq,
  unwrapLoc,
  usesPreludeName,
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
      needs = [NeedsScopes],
    }
    notEqVisitors
    None

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
-- The fix is withheld where the file rebinds `not`: the call is then the
-- file's own, and the rewrite would change what it computes.
notEqVisitors : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
notEqVisitors _ _ facts _ _ = [OnExpr [KApp] (notEqAt facts)]

notEqAt : FileFacts -> Ctx -> Expr -> List Finding
notEqAt facts ctx e = match (notEqOf e, e)
  (Some rewritten, EApp hd _) =>
    [notEqFinding ctx.ctxSpan rewritten (notEqFix facts ctx e hd rewritten)]
  _ => []

notEqFinding : Option Loc -> Expr -> Option Fix -> Finding
notEqFinding loc rewritten fix = Finding {
  rule = ruleNameNotEq,
  message = "negated equality. Rewrite as '" ++ exprToString rewritten ++ "'",
  severity = SevWarning,
  loc = loc,
  fix = fix,
}

notEqFix : FileFacts -> Ctx -> Expr -> Expr -> Expr -> Option Fix
notEqFix facts ctx e hd rewritten =
  if usesPreludeName facts hd then
    replaceFix
      "use the operator"
      (nodeSpan ctx e)
      Open
      ctx
      (exprToString rewritten)
  else
    None
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("tools" "lint_fix") ((mem "Binding" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Fix" false) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "nodeSpan" false) (mem "notArgOf" false) (mem "replaceFix" false) (mem "ruleNameNotEq" false) (mem "unwrapLoc" false) (mem "usesPreludeName" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameNotEq")) (fa "summary" (ELit (LString "negated equality `not (a == b)` / `not (a /= b)`. Prefer `a /= b` / `a == b`"))) (fa "doc" (ELit (LString "A negated equality test has a direct operator.\n\nBefore:\n  not (a == b)\nAfter:\n  a /= b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "notEqVisitors")) (EVar "None")))
(DTypeSig false "notEqOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "notEqOf" ((PVar "e")) (EMatch (EApp (EVar "notArgOf") (EVar "e")) (arm (PCon "Some" (PVar "inner")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "inner")) (arm (PCon "EBinOp" (PLit (LString "==")) (PVar "a") (PVar "b") (PVar "r")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString "/="))) (EVar "a")) (EVar "b")) (EVar "r")))) (arm (PCon "EBinOp" (PLit (LString "/=")) (PVar "a") (PVar "b") (PVar "r")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString "=="))) (EVar "a")) (EVar "b")) (EVar "r")))) (arm PWild () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "notEqVisitors" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "notEqVisitors" (PWild PWild (PVar "facts") PWild PWild) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KApp"))) (EApp (EVar "notEqAt") (EVar "facts")))))
(DTypeSig false "notEqAt" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "notEqAt" ((PVar "facts") (PVar "ctx") (PVar "e")) (EMatch (ETuple (EApp (EVar "notEqOf") (EVar "e")) (EVar "e")) (arm (PTuple (PCon "Some" (PVar "rewritten")) (PCon "EApp" (PVar "hd") PWild)) () (EListLit (EApp (EApp (EApp (EVar "notEqFinding") (EFieldAccess (EVar "ctx") "ctxSpan")) (EVar "rewritten")) (EApp (EApp (EApp (EApp (EApp (EVar "notEqFix") (EVar "facts")) (EVar "ctx")) (EVar "e")) (EVar "hd")) (EVar "rewritten"))))) (arm PWild () (EListLit))))
(DTypeSig false "notEqFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "notEqFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameNotEq")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "negated equality. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "notEqFix" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix"))))))))
(DFunDef false "notEqFix" ((PVar "facts") (PVar "ctx") (PVar "e") (PVar "hd") (PVar "rewritten")) (EIf (EApp (EApp (EVar "usesPreludeName") (EVar "facts")) (EVar "hd")) (EApp (EApp (EApp (EApp (EApp (EVar "replaceFix") (ELit (LString "use the operator"))) (EApp (EApp (EVar "nodeSpan") (EVar "ctx")) (EVar "e"))) (EVar "Open")) (EVar "ctx")) (EApp (EVar "exprToString") (EVar "rewritten"))) (EVar "None")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("tools" "lint_fix") ((mem "Binding" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Fix" false) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "nodeSpan" false) (mem "notArgOf" false) (mem "replaceFix" false) (mem "ruleNameNotEq" false) (mem "unwrapLoc" false) (mem "usesPreludeName" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameNotEq")) (fa "summary" (ELit (LString "negated equality `not (a == b)` / `not (a /= b)`. Prefer `a /= b` / `a == b`"))) (fa "doc" (ELit (LString "A negated equality test has a direct operator.\n\nBefore:\n  not (a == b)\nAfter:\n  a /= b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes")))))) (EVar "notEqVisitors")) (EVar "None")))
(DTypeSig false "notEqOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "notEqOf" ((PVar "e")) (EMatch (EApp (EVar "notArgOf") (EVar "e")) (arm (PCon "Some" (PVar "inner")) () (EMatch (EApp (EVar "unwrapLoc") (EVar "inner")) (arm (PCon "EBinOp" (PLit (LString "==")) (PVar "a") (PVar "b") (PVar "r")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString "/="))) (EVar "a")) (EVar "b")) (EVar "r")))) (arm (PCon "EBinOp" (PLit (LString "/=")) (PVar "a") (PVar "b") (PVar "r")) () (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EVar "EBinOp") (ELit (LString "=="))) (EVar "a")) (EVar "b")) (EVar "r")))) (arm PWild () (EVar "None")))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "notEqVisitors" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "notEqVisitors" (PWild PWild (PVar "facts") PWild PWild) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KApp"))) (EApp (EVar "notEqAt") (EVar "facts")))))
(DTypeSig false "notEqAt" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "notEqAt" ((PVar "facts") (PVar "ctx") (PVar "e")) (EMatch (ETuple (EApp (EVar "notEqOf") (EVar "e")) (EVar "e")) (arm (PTuple (PCon "Some" (PVar "rewritten")) (PCon "EApp" (PVar "hd") PWild)) () (EListLit (EApp (EApp (EApp (EVar "notEqFinding") (EFieldAccess (EVar "ctx") "ctxSpan")) (EVar "rewritten")) (EApp (EApp (EApp (EApp (EApp (EVar "notEqFix") (EVar "facts")) (EVar "ctx")) (EVar "e")) (EVar "hd")) (EVar "rewritten"))))) (arm PWild () (EListLit))))
(DTypeSig false "notEqFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "notEqFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameNotEq")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "negated equality. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "notEqFix" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix"))))))))
(DFunDef false "notEqFix" ((PVar "facts") (PVar "ctx") (PVar "e") (PVar "hd") (PVar "rewritten")) (EIf (EApp (EApp (EVar "usesPreludeName") (EVar "facts")) (EVar "hd")) (EApp (EApp (EApp (EApp (EApp (EVar "replaceFix") (ELit (LString "use the operator"))) (EApp (EApp (EVar "nodeSpan") (EVar "ctx")) (EVar "e"))) (EVar "Open")) (EVar "ctx")) (EApp (EVar "exprToString") (EVar "rewritten"))) (EVar "None")))
