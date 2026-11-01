# META
source_lines=134
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-let-underscore-unit: `let _ = e` on a call whose declared result is Unit, in a plain block. Write the bare statement `e`.

import driver.diagnostics.{Severity(..)}
import frontend.ast.{Decl, DoStmt(..), Expr(..), Loc(..), Pat(..)}
import frontend.ast_walk.{ExprKind(..)}
import frontend.parser.{Positions(..)}
import tools.lint_calls.{
  BlockKind(..),
  DiscardClass(..),
  Verdict(..),
  blockOf,
  discardClass,
  discardVerdict,
}
import tools.lint_core.{
  Applicability(..),
  Category(..),
  Ctx,
  FileFacts,
  Finding(..),
  Fix(..),
  FixEdit(..),
  Fixability(..),
  Need(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  Visitor(..),
  factScopes,
  mkVisitorRule,
  projectIndexOf,
}
import tools.lint_index.{ProjectIndex}
import tools.lint_scope.{FileScopes}
import tools.lint_shared.{ruleNameLetUnderscoreUnit, unwrapLoc}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameLetUnderscoreUnit,
      summary =
        "`let _ = e` on a call that returns Unit, in a plain block. Write the bare statement `e`",
      doc =
        "A call whose declared result is Unit has no value to bind, so `let _ =` in front of it says nothing. In a plain block the call is a statement on its own; `do` blocks keep `let _ =`. Only a saturated call to a signed function is checked: the declared result decides, so a partial application, a method, a shadowed name and an unsigned function are not reported.\n\nBefore:\n  let _ = writeLine out \"done\"\n  count xs\nAfter:\n  writeLine out \"done\"\n  count xs",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [NeedsScopes, NeedsProjectIndex],
    }
    ruleLetUnderscoreUnit
    None

ruleLetUnderscoreUnit : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleLetUnderscoreUnit idx path facts _ _ = [
  OnExpr [KBlock] (blockAt (projectIndexOf idx) (factScopes facts) path),
]

blockAt : ProjectIndex -> FileScopes -> String -> Ctx -> Expr -> List Finding
blockAt ix scopes path _ e = match blockOf e
  Some (PlainBlock, stmts) => flatMap (stmtFindings ix scopes path) stmts
  _ => []

stmtFindings : ProjectIndex -> FileScopes -> String -> DoStmt -> List Finding
stmtFindings ix scopes path (s@(DoLet _ _ PWild rhs (Loc f sl sc el ec))) =
  if sl == el && sc == ec then
    []
  else match discardVerdict ix scopes path s
    Discard ty =>
      if discardClass ty == ClassUnit then
        [finding (Loc f sl sc el ec) (dropFix f sl sc rhs)]
      else
        []
    Abstain _ => []
stmtFindings _ _ _ _ = []

finding : Loc -> Option Fix -> Finding
finding loc fix = Finding {
  rule = ruleNameLetUnderscoreUnit,
  message =
    "`let _ = e` binds a Unit result to nothing. In a plain block write the bare statement `e` (`do` blocks keep `let _ =`). Before: `let _ = f x`; after: `f x`",
  severity = SevWarning,
  loc = Some loc,
  fix = fix,
}

-- Deleting the text from the `let` keyword to the call leaves the call's own
-- bytes untouched, and the call then starts where the `let` did, so a call on
-- a later line keeps every continuation line deeper than the statement.  The
-- edit is withheld where the call's start is not known.
dropFix : String -> Int -> Int -> Expr -> Option Fix
dropFix f sl sc rhs = match callStart rhs
  Some (Loc _ rl rc _ _) =>
    if rl > sl || rc > sc then
      Some Fix {
        fixApplicability = Safe,
        fixEdits = [FixEdit (Loc f sl sc rl rc) ""],
        fixMessage = "drop the `let _ =`",
      }
    else
      None
  None => None

-- Where the call's text starts: its head, or the enclosing brackets when the
-- call is parenthesised, whichever comes first.
callStart : Expr -> Option Loc
callStart rhs = match (outerStart rhs, headStart (unwrapLoc rhs))
  (Some a, Some b) => Some (earlier a b)
  (Some a, None) => Some a
  (None, b) => b

headStart : Expr -> Option Loc
headStart (EApp f _) = headStart f
headStart (ELoc l _) = Some l
headStart _ = None

outerStart : Expr -> Option Loc
outerStart (ELoc l _) = Some l
outerStart _ = None

earlier : Loc -> Loc -> Loc
earlier a b = match (a, b)
  (Loc _ al ac _ _, Loc _ bl bc _ _) =>
    if al < bl || (al == bl && ac <= bc) then a else b
# DESUGAR
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DoStmt" true) (mem "Expr" true) (mem "Loc" true) (mem "Pat" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("tools" "lint_calls") ((mem "BlockKind" true) (mem "DiscardClass" true) (mem "Verdict" true) (mem "blockOf" false) (mem "discardClass" false) (mem "discardVerdict" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" false) (mem "FileFacts" false) (mem "Finding" true) (mem "Fix" true) (mem "FixEdit" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "factScopes" false) (mem "mkVisitorRule" false) (mem "projectIndexOf" false))))
(DUse false (UseGroup ("tools" "lint_index") ((mem "ProjectIndex" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "FileScopes" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameLetUnderscoreUnit" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameLetUnderscoreUnit")) (fa "summary" (ELit (LString "`let _ = e` on a call that returns Unit, in a plain block. Write the bare statement `e`"))) (fa "doc" (ELit (LString "A call whose declared result is Unit has no value to bind, so `let _ =` in front of it says nothing. In a plain block the call is a statement on its own; `do` blocks keep `let _ =`. Only a saturated call to a signed function is checked: the declared result decides, so a partial application, a method, a shadowed name and an unsigned function are not reported.\n\nBefore:\n  let _ = writeLine out \"done\"\n  count xs\nAfter:\n  writeLine out \"done\"\n  count xs"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsProjectIndex")))))) (EVar "ruleLetUnderscoreUnit")) (EVar "None")))
(DTypeSig false "ruleLetUnderscoreUnit" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleLetUnderscoreUnit" ((PVar "idx") (PVar "path") (PVar "facts") PWild PWild) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KBlock"))) (EApp (EApp (EApp (EVar "blockAt") (EApp (EVar "projectIndexOf") (EVar "idx"))) (EApp (EVar "factScopes") (EVar "facts"))) (EVar "path")))))
(DTypeSig false "blockAt" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "blockAt" ((PVar "ix") (PVar "scopes") (PVar "path") PWild (PVar "e")) (EMatch (EApp (EVar "blockOf") (EVar "e")) (arm (PCon "Some" (PTuple (PCon "PlainBlock") (PVar "stmts"))) () (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "stmtFindings") (EVar "ix")) (EVar "scopes")) (EVar "path"))) (EVar "stmts"))) (arm PWild () (EListLit))))
(DTypeSig false "stmtFindings" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "stmtFindings" ((PVar "ix") (PVar "scopes") (PVar "path") (PAs "s" (PCon "DoLet" PWild PWild (PCon "PWild") (PVar "rhs") (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "sl") (EVar "el")) (EBinOp "==" (EVar "sc") (EVar "ec"))) (EListLit) (EMatch (EApp (EApp (EApp (EApp (EVar "discardVerdict") (EVar "ix")) (EVar "scopes")) (EVar "path")) (EVar "s")) (arm (PCon "Discard" (PVar "ty")) () (EIf (EBinOp "==" (EApp (EVar "discardClass") (EVar "ty")) (EVar "ClassUnit")) (EListLit (EApp (EApp (EVar "finding") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec"))) (EApp (EApp (EApp (EApp (EVar "dropFix") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "rhs")))) (EListLit))) (arm (PCon "Abstain" PWild) () (EListLit)))))
(DFunDef false "stmtFindings" (PWild PWild PWild PWild) (EListLit))
(DTypeSig false "finding" (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding"))))
(DFunDef false "finding" ((PVar "loc") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameLetUnderscoreUnit")) (fa "message" (ELit (LString "`let _ = e` binds a Unit result to nothing. In a plain block write the bare statement `e` (`do` blocks keep `let _ =`). Before: `let _ = f x`; after: `f x`"))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EVar "loc"))) (fa "fix" (EVar "fix")))))
(DTypeSig false "dropFix" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix")))))))
(DFunDef false "dropFix" ((PVar "f") (PVar "sl") (PVar "sc") (PVar "rhs")) (EMatch (EApp (EVar "callStart") (EVar "rhs")) (arm (PCon "Some" (PCon "Loc" PWild (PVar "rl") (PVar "rc") PWild PWild)) () (EIf (EBinOp "||" (EBinOp ">" (EVar "rl") (EVar "sl")) (EBinOp ">" (EVar "rc") (EVar "sc"))) (EApp (EVar "Some") (ERecordCreate "Fix" ((fa "fixApplicability" (EVar "Safe")) (fa "fixEdits" (EListLit (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "rl")) (EVar "rc"))) (ELit (LString ""))))) (fa "fixMessage" (ELit (LString "drop the `let _ =`")))))) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "callStart" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "callStart" ((PVar "rhs")) (EMatch (ETuple (EApp (EVar "outerStart") (EVar "rhs")) (EApp (EVar "headStart") (EApp (EVar "unwrapLoc") (EVar "rhs")))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) () (EApp (EVar "Some") (EApp (EApp (EVar "earlier") (EVar "a")) (EVar "b")))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "None")) () (EApp (EVar "Some") (EVar "a"))) (arm (PTuple (PCon "None") (PVar "b")) () (EVar "b"))))
(DTypeSig false "headStart" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "headStart" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "headStart") (EVar "f")))
(DFunDef false "headStart" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "headStart" (PWild) (EVar "None"))
(DTypeSig false "outerStart" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "outerStart" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "outerStart" (PWild) (EVar "None"))
(DTypeSig false "earlier" (TyFun (TyCon "Loc") (TyFun (TyCon "Loc") (TyCon "Loc"))))
(DFunDef false "earlier" ((PVar "a") (PVar "b")) (EMatch (ETuple (EVar "a") (EVar "b")) (arm (PTuple (PCon "Loc" PWild (PVar "al") (PVar "ac") PWild PWild) (PCon "Loc" PWild (PVar "bl") (PVar "bc") PWild PWild)) () (EIf (EBinOp "||" (EBinOp "<" (EVar "al") (EVar "bl")) (EBinOp "&&" (EBinOp "==" (EVar "al") (EVar "bl")) (EBinOp "<=" (EVar "ac") (EVar "bc")))) (EVar "a") (EVar "b")))))
# MARK
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DoStmt" true) (mem "Expr" true) (mem "Loc" true) (mem "Pat" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("tools" "lint_calls") ((mem "BlockKind" true) (mem "DiscardClass" true) (mem "Verdict" true) (mem "blockOf" false) (mem "discardClass" false) (mem "discardVerdict" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" false) (mem "FileFacts" false) (mem "Finding" true) (mem "Fix" true) (mem "FixEdit" true) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "factScopes" false) (mem "mkVisitorRule" false) (mem "projectIndexOf" false))))
(DUse false (UseGroup ("tools" "lint_index") ((mem "ProjectIndex" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "FileScopes" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameLetUnderscoreUnit" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameLetUnderscoreUnit")) (fa "summary" (ELit (LString "`let _ = e` on a call that returns Unit, in a plain block. Write the bare statement `e`"))) (fa "doc" (ELit (LString "A call whose declared result is Unit has no value to bind, so `let _ =` in front of it says nothing. In a plain block the call is a statement on its own; `do` blocks keep `let _ =`. Only a saturated call to a signed function is checked: the declared result decides, so a partial application, a method, a shadowed name and an unsigned function are not reported.\n\nBefore:\n  let _ = writeLine out \"done\"\n  count xs\nAfter:\n  writeLine out \"done\"\n  count xs"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsProjectIndex")))))) (EVar "ruleLetUnderscoreUnit")) (EVar "None")))
(DTypeSig false "ruleLetUnderscoreUnit" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleLetUnderscoreUnit" ((PVar "idx") (PVar "path") (PVar "facts") PWild PWild) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KBlock"))) (EApp (EApp (EApp (EVar "blockAt") (EApp (EVar "projectIndexOf") (EVar "idx"))) (EApp (EVar "factScopes") (EVar "facts"))) (EVar "path")))))
(DTypeSig false "blockAt" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "blockAt" ((PVar "ix") (PVar "scopes") (PVar "path") PWild (PVar "e")) (EMatch (EApp (EVar "blockOf") (EVar "e")) (arm (PCon "Some" (PTuple (PCon "PlainBlock") (PVar "stmts"))) () (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "stmtFindings") (EVar "ix")) (EVar "scopes")) (EVar "path"))) (EVar "stmts"))) (arm PWild () (EListLit))))
(DTypeSig false "stmtFindings" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "stmtFindings" ((PVar "ix") (PVar "scopes") (PVar "path") (PAs "s" (PCon "DoLet" PWild PWild (PCon "PWild") (PVar "rhs") (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))))) (EIf (EBinOp "&&" (EBinOp "==" (EVar "sl") (EVar "el")) (EBinOp "==" (EVar "sc") (EVar "ec"))) (EListLit) (EMatch (EApp (EApp (EApp (EApp (EVar "discardVerdict") (EVar "ix")) (EVar "scopes")) (EVar "path")) (EVar "s")) (arm (PCon "Discard" (PVar "ty")) () (EIf (EBinOp "==" (EApp (EVar "discardClass") (EVar "ty")) (EVar "ClassUnit")) (EListLit (EApp (EApp (EVar "finding") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec"))) (EApp (EApp (EApp (EApp (EVar "dropFix") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "rhs")))) (EListLit))) (arm (PCon "Abstain" PWild) () (EListLit)))))
(DFunDef false "stmtFindings" (PWild PWild PWild PWild) (EListLit))
(DTypeSig false "finding" (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding"))))
(DFunDef false "finding" ((PVar "loc") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameLetUnderscoreUnit")) (fa "message" (ELit (LString "`let _ = e` binds a Unit result to nothing. In a plain block write the bare statement `e` (`do` blocks keep `let _ =`). Before: `let _ = f x`; after: `f x`"))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EVar "loc"))) (fa "fix" (EVar "fix")))))
(DTypeSig false "dropFix" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix")))))))
(DFunDef false "dropFix" ((PVar "f") (PVar "sl") (PVar "sc") (PVar "rhs")) (EMatch (EApp (EVar "callStart") (EVar "rhs")) (arm (PCon "Some" (PCon "Loc" PWild (PVar "rl") (PVar "rc") PWild PWild)) () (EIf (EBinOp "||" (EBinOp ">" (EVar "rl") (EVar "sl")) (EBinOp ">" (EVar "rc") (EVar "sc"))) (EApp (EVar "Some") (ERecordCreate "Fix" ((fa "fixApplicability" (EVar "Safe")) (fa "fixEdits" (EListLit (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "rl")) (EVar "rc"))) (ELit (LString ""))))) (fa "fixMessage" (ELit (LString "drop the `let _ =`")))))) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "callStart" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "callStart" ((PVar "rhs")) (EMatch (ETuple (EApp (EVar "outerStart") (EVar "rhs")) (EApp (EVar "headStart") (EApp (EVar "unwrapLoc") (EVar "rhs")))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "Some" (PVar "b"))) () (EApp (EVar "Some") (EApp (EApp (EVar "earlier") (EVar "a")) (EVar "b")))) (arm (PTuple (PCon "Some" (PVar "a")) (PCon "None")) () (EApp (EVar "Some") (EVar "a"))) (arm (PTuple (PCon "None") (PVar "b")) () (EVar "b"))))
(DTypeSig false "headStart" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "headStart" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "headStart") (EVar "f")))
(DFunDef false "headStart" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "headStart" (PWild) (EVar "None"))
(DTypeSig false "outerStart" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "outerStart" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "outerStart" (PWild) (EVar "None"))
(DTypeSig false "earlier" (TyFun (TyCon "Loc") (TyFun (TyCon "Loc") (TyCon "Loc"))))
(DFunDef false "earlier" ((PVar "a") (PVar "b")) (EMatch (ETuple (EVar "a") (EVar "b")) (arm (PTuple (PCon "Loc" PWild (PVar "al") (PVar "ac") PWild PWild) (PCon "Loc" PWild (PVar "bl") (PVar "bc") PWild PWild)) () (EIf (EBinOp "||" (EBinOp "<" (EVar "al") (EVar "bl")) (EBinOp "&&" (EBinOp "==" (EVar "al") (EVar "bl")) (EBinOp "<=" (EVar "ac") (EVar "bc")))) (EVar "a") (EVar "b")))))
