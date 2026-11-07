# META
source_lines=79
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-discarded-result: `let _ = e` on a call whose declared result is a Result or an Option, in a plain block. The value is propagated, handled or named.

import driver.diagnostics.{Severity(..)}
import frontend.ast.{Decl, DoStmt, Loc}
import frontend.parser.{Positions(..)}
import tools.lint_calls.{
  DiscardClass(..),
  discardOf,
  plainBlockVisitors,
}
import tools.lint_core.{
  Category(..),
  FileFacts,
  Finding(..),
  Fixability(..),
  Need(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  Visitor(..),
  mkVisitorRule,
  noFix,
}
import tools.lint_index.{ProjectIndex}
import tools.lint_scope.{FileScopes}
import tools.lint_shared.{ruleNameDiscardedResult}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameDiscardedResult,
      summary =
        "`let _ = e` on a call that returns a Result or an Option, in a plain block. Propagate it, handle it or name the discard",
      doc =
        "A call whose declared result is a `Result` or an `Option` carries a failure or an absence, and `let _ =` throws it away unread. In a plain block the error must be propagated (the enclosing function's type permits `?`, a match or `andThen`, or its signature changes with its callers), or the discard named with `bestEffort \"<reason>\"`, whose reason says why this error is ignorable. A discarded `Option` has a `None` case to handle, or the call is rewritten so the result is not discarded. `do` blocks are not checked. Only a saturated call to a signed function is checked: the declared result decides, so a partial application, a method, a shadowed name and an unsigned function are not reported.\n\nBefore:\n  let _ = writeFile path text\n  next ()\nAfter:\n  bestEffort \"the scratch file is advisory\" (writeFile path text)\n  next ()",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [NeedsScopes, NeedsProjectIndex],
    }
    ruleDiscardedResult
    None

ruleDiscardedResult : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleDiscardedResult = plainBlockVisitors resultStmt

resultStmt : ProjectIndex -> FileScopes -> String -> DoStmt -> List Finding
resultStmt ix scopes path s = match discardOf ix scopes path s
  Some (loc, _, ClassResult) => [finding resultMessage loc]
  Some (loc, _, ClassOption) => [finding optionMessage loc]
  _ => []

finding : String -> Loc -> Finding
finding message loc = Finding {
  rule = ruleNameDiscardedResult,
  message = message,
  severity = SevWarning,
  loc = Some loc,
  fix = noFix,
}

resultMessage : String
resultMessage =
  "`let _ = e` throws away a Result, and with it the error. Propagate the error (`?`, a match, `andThen`, or change the signature and its callers), or name the discard: `bestEffort \"<why this error is ignorable>\" (e)`"

optionMessage : String
optionMessage =
  "`let _ = e` throws away an Option, and with it the `None` case. Handle `None` in a match that says what absence means, or rewrite the call so the result is not discarded"
# DESUGAR
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DoStmt" false) (mem "Loc" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("tools" "lint_calls") ((mem "DiscardClass" true) (mem "discardOf" false) (mem "plainBlockVisitors" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false) (mem "noFix" false))))
(DUse false (UseGroup ("tools" "lint_index") ((mem "ProjectIndex" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "FileScopes" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameDiscardedResult" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDiscardedResult")) (fa "summary" (ELit (LString "`let _ = e` on a call that returns a Result or an Option, in a plain block. Propagate it, handle it or name the discard"))) (fa "doc" (ELit (LString "A call whose declared result is a `Result` or an `Option` carries a failure or an absence, and `let _ =` throws it away unread. In a plain block the error must be propagated (the enclosing function's type permits `?`, a match or `andThen`, or its signature changes with its callers), or the discard named with `bestEffort \"<reason>\"`, whose reason says why this error is ignorable. A discarded `Option` has a `None` case to handle, or the call is rewritten so the result is not discarded. `do` blocks are not checked. Only a saturated call to a signed function is checked: the declared result decides, so a partial application, a method, a shadowed name and an unsigned function are not reported.\n\nBefore:\n  let _ = writeFile path text\n  next ()\nAfter:\n  bestEffort \"the scratch file is advisory\" (writeFile path text)\n  next ()"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsProjectIndex")))))) (EVar "ruleDiscardedResult")) (EVar "None")))
(DTypeSig false "ruleDiscardedResult" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleDiscardedResult" () (EApp (EVar "plainBlockVisitors") (EVar "resultStmt")))
(DTypeSig false "resultStmt" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "resultStmt" ((PVar "ix") (PVar "scopes") (PVar "path") (PVar "s")) (EMatch (EApp (EApp (EApp (EApp (EVar "discardOf") (EVar "ix")) (EVar "scopes")) (EVar "path")) (EVar "s")) (arm (PCon "Some" (PTuple (PVar "loc") PWild (PCon "ClassResult"))) () (EListLit (EApp (EApp (EVar "finding") (EVar "resultMessage")) (EVar "loc")))) (arm (PCon "Some" (PTuple (PVar "loc") PWild (PCon "ClassOption"))) () (EListLit (EApp (EApp (EVar "finding") (EVar "optionMessage")) (EVar "loc")))) (arm PWild () (EListLit))))
(DTypeSig false "finding" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "Finding"))))
(DFunDef false "finding" ((PVar "message") (PVar "loc")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDiscardedResult")) (fa "message" (EVar "message")) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EVar "loc"))) (fa "fix" (EVar "noFix")))))
(DTypeSig false "resultMessage" (TyCon "String"))
(DFunDef false "resultMessage" () (ELit (LString "`let _ = e` throws away a Result, and with it the error. Propagate the error (`?`, a match, `andThen`, or change the signature and its callers), or name the discard: `bestEffort \"<why this error is ignorable>\" (e)`")))
(DTypeSig false "optionMessage" (TyCon "String"))
(DFunDef false "optionMessage" () (ELit (LString "`let _ = e` throws away an Option, and with it the `None` case. Handle `None` in a match that says what absence means, or rewrite the call so the result is not discarded")))
# MARK
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DoStmt" false) (mem "Loc" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("tools" "lint_calls") ((mem "DiscardClass" true) (mem "discardOf" false) (mem "plainBlockVisitors" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false) (mem "noFix" false))))
(DUse false (UseGroup ("tools" "lint_index") ((mem "ProjectIndex" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "FileScopes" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameDiscardedResult" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDiscardedResult")) (fa "summary" (ELit (LString "`let _ = e` on a call that returns a Result or an Option, in a plain block. Propagate it, handle it or name the discard"))) (fa "doc" (ELit (LString "A call whose declared result is a `Result` or an `Option` carries a failure or an absence, and `let _ =` throws it away unread. In a plain block the error must be propagated (the enclosing function's type permits `?`, a match or `andThen`, or its signature changes with its callers), or the discard named with `bestEffort \"<reason>\"`, whose reason says why this error is ignorable. A discarded `Option` has a `None` case to handle, or the call is rewritten so the result is not discarded. `do` blocks are not checked. Only a saturated call to a signed function is checked: the declared result decides, so a partial application, a method, a shadowed name and an unsigned function are not reported.\n\nBefore:\n  let _ = writeFile path text\n  next ()\nAfter:\n  bestEffort \"the scratch file is advisory\" (writeFile path text)\n  next ()"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsProjectIndex")))))) (EVar "ruleDiscardedResult")) (EVar "None")))
(DTypeSig false "ruleDiscardedResult" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleDiscardedResult" () (EApp (EVar "plainBlockVisitors") (EVar "resultStmt")))
(DTypeSig false "resultStmt" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "resultStmt" ((PVar "ix") (PVar "scopes") (PVar "path") (PVar "s")) (EMatch (EApp (EApp (EApp (EApp (EVar "discardOf") (EVar "ix")) (EVar "scopes")) (EVar "path")) (EVar "s")) (arm (PCon "Some" (PTuple (PVar "loc") PWild (PCon "ClassResult"))) () (EListLit (EApp (EApp (EVar "finding") (EVar "resultMessage")) (EVar "loc")))) (arm (PCon "Some" (PTuple (PVar "loc") PWild (PCon "ClassOption"))) () (EListLit (EApp (EApp (EVar "finding") (EVar "optionMessage")) (EVar "loc")))) (arm PWild () (EListLit))))
(DTypeSig false "finding" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyCon "Finding"))))
(DFunDef false "finding" ((PVar "message") (PVar "loc")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameDiscardedResult")) (fa "message" (EVar "message")) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EVar "loc"))) (fa "fix" (EVar "noFix")))))
(DTypeSig false "resultMessage" (TyCon "String"))
(DFunDef false "resultMessage" () (ELit (LString "`let _ = e` throws away a Result, and with it the error. Propagate the error (`?`, a match, `andThen`, or change the signature and its callers), or name the discard: `bestEffort \"<why this error is ignorable>\" (e)`")))
(DTypeSig false "optionMessage" (TyCon "String"))
(DFunDef false "optionMessage" () (ELit (LString "`let _ = e` throws away an Option, and with it the `None` case. Handle `None` in a match that says what absence means, or rewrite the call so the result is not discarded")))
