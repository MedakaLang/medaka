# META
source_lines=114
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-let-underscore-unit: `let _ = e` on a call whose declared result is Unit, in a plain block. Write the bare statement `e`.

import driver.diagnostics.{Severity(..)}
import frontend.ast.{Decl, DoStmt, Expr(..), Loc(..)}
import frontend.parser.{Positions(..)}
import tools.lint_calls.{
  DiscardClass(..),
  discardOf,
  plainBlockVisitors,
}
import tools.lint_core.{
  Applicability(..),
  Category(..),
  FileFacts,
  Finding(..),
  Fix(..),
  FixEdit(..),
  Fixability(..),
  Memo,
  Need(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  Visitor(..),
  fixLater,
  mkVisitorRule,
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
ruleLetUnderscoreUnit = plainBlockVisitors unitStmt

unitStmt : ProjectIndex -> FileScopes -> String -> DoStmt -> List Finding
unitStmt ix scopes path s = match discardOf ix scopes path s
  Some (loc@(Loc f sl sc _ _), rhs, ClassUnit) =>
    [finding loc (fixLater (_ => dropFix f sl sc rhs))]
  _ => []

finding : Loc -> Memo (Option Fix) -> Finding
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
dropFix f sl sc rhs = do
  (Loc _ rl rc _ _) <- callStart rhs
  if rl > sl || rc > sc then
    Some Fix {
      fixApplicability = Safe,
      fixEdits = [FixEdit (Loc f sl sc rl rc) ""],
      fixMessage = "drop the `let _ =`",
    }
  else
    None

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
    if al < bl || al == bl && ac <= bc then a else b
# DESUGAR
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DoStmt" false) (mem "Expr" true) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("tools" "lint_calls") ((mem "DiscardClass" true) (mem "discardOf" false) (mem "plainBlockVisitors" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fix" true) (mem "FixEdit" true) (mem "Fixability" true) (mem "Memo" false) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "fixLater" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_index") ((mem "ProjectIndex" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "FileScopes" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameLetUnderscoreUnit" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameLetUnderscoreUnit")) (fa "summary" (ELit (LString "`let _ = e` on a call that returns Unit, in a plain block. Write the bare statement `e`"))) (fa "doc" (ELit (LString "A call whose declared result is Unit has no value to bind, so `let _ =` in front of it says nothing. In a plain block the call is a statement on its own; `do` blocks keep `let _ =`. Only a saturated call to a signed function is checked: the declared result decides, so a partial application, a method, a shadowed name and an unsigned function are not reported.\n\nBefore:\n  let _ = writeLine out \"done\"\n  count xs\nAfter:\n  writeLine out \"done\"\n  count xs"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsProjectIndex")))))) (EVar "ruleLetUnderscoreUnit")) (EVar "None")))
(DTypeSig false "ruleLetUnderscoreUnit" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleLetUnderscoreUnit" () (EApp (EVar "plainBlockVisitors") (EVar "unitStmt")))
(DTypeSig false "unitStmt" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "unitStmt" ((PVar "ix") (PVar "scopes") (PVar "path") (PVar "s")) (EMatch (EApp (EApp (EApp (EApp (EVar "discardOf") (EVar "ix")) (EVar "scopes")) (EVar "path")) (EVar "s")) (arm (PCon "Some" (PTuple (PAs "loc" (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") PWild PWild)) (PVar "rhs") (PCon "ClassUnit"))) () (EListLit (EApp (EApp (EVar "finding") (EVar "loc")) (EApp (EVar "fixLater") (ELam (PWild) (EApp (EApp (EApp (EApp (EVar "dropFix") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "rhs"))))))) (arm PWild () (EListLit))))
(DTypeSig false "finding" (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "Memo") (TyApp (TyCon "Option") (TyCon "Fix"))) (TyCon "Finding"))))
(DFunDef false "finding" ((PVar "loc") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameLetUnderscoreUnit")) (fa "message" (ELit (LString "`let _ = e` binds a Unit result to nothing. In a plain block write the bare statement `e` (`do` blocks keep `let _ =`). Before: `let _ = f x`; after: `f x`"))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EVar "loc"))) (fa "fix" (EVar "fix")))))
(DTypeSig false "dropFix" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix")))))))
(DFunDef false "dropFix" ((PVar "f") (PVar "sl") (PVar "sc") (PVar "rhs")) (EApp (EApp (EVar "$core.andThen") (EApp (EVar "callStart") (EVar "rhs"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "Loc" PWild (PVar "rl") (PVar "rc") PWild PWild) () (EIf (EBinOp "||" (EBinOp ">" (EVar "rl") (EVar "sl")) (EBinOp ">" (EVar "rc") (EVar "sc"))) (EApp (EVar "Some") (ERecordCreate "Fix" ((fa "fixApplicability" (EVar "Safe")) (fa "fixEdits" (EListLit (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "rl")) (EVar "rc"))) (ELit (LString ""))))) (fa "fixMessage" (ELit (LString "drop the `let _ =`")))))) (EVar "None")))))))
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
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" false) (mem "DoStmt" false) (mem "Expr" true) (mem "Loc" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("tools" "lint_calls") ((mem "DiscardClass" true) (mem "discardOf" false) (mem "plainBlockVisitors" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fix" true) (mem "FixEdit" true) (mem "Fixability" true) (mem "Memo" false) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "fixLater" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_index") ((mem "ProjectIndex" false))))
(DUse false (UseGroup ("tools" "lint_scope") ((mem "FileScopes" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameLetUnderscoreUnit" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameLetUnderscoreUnit")) (fa "summary" (ELit (LString "`let _ = e` on a call that returns Unit, in a plain block. Write the bare statement `e`"))) (fa "doc" (ELit (LString "A call whose declared result is Unit has no value to bind, so `let _ =` in front of it says nothing. In a plain block the call is a statement on its own; `do` blocks keep `let _ =`. Only a saturated call to a signed function is checked: the declared result decides, so a partial application, a method, a shadowed name and an unsigned function are not reported.\n\nBefore:\n  let _ = writeLine out \"done\"\n  count xs\nAfter:\n  writeLine out \"done\"\n  count xs"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsProjectIndex")))))) (EVar "ruleLetUnderscoreUnit")) (EVar "None")))
(DTypeSig false "ruleLetUnderscoreUnit" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleLetUnderscoreUnit" () (EApp (EVar "plainBlockVisitors") (EVar "unitStmt")))
(DTypeSig false "unitStmt" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "unitStmt" ((PVar "ix") (PVar "scopes") (PVar "path") (PVar "s")) (EMatch (EApp (EApp (EApp (EApp (EVar "discardOf") (EVar "ix")) (EVar "scopes")) (EVar "path")) (EVar "s")) (arm (PCon "Some" (PTuple (PAs "loc" (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") PWild PWild)) (PVar "rhs") (PCon "ClassUnit"))) () (EListLit (EApp (EApp (EVar "finding") (EVar "loc")) (EApp (EVar "fixLater") (ELam (PWild) (EApp (EApp (EApp (EApp (EVar "dropFix") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "rhs"))))))) (arm PWild () (EListLit))))
(DTypeSig false "finding" (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "Memo") (TyApp (TyCon "Option") (TyCon "Fix"))) (TyCon "Finding"))))
(DFunDef false "finding" ((PVar "loc") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameLetUnderscoreUnit")) (fa "message" (ELit (LString "`let _ = e` binds a Unit result to nothing. In a plain block write the bare statement `e` (`do` blocks keep `let _ =`). Before: `let _ = f x`; after: `f x`"))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EApp (EVar "Some") (EVar "loc"))) (fa "fix" (EVar "fix")))))
(DTypeSig false "dropFix" (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix")))))))
(DFunDef false "dropFix" ((PVar "f") (PVar "sl") (PVar "sc") (PVar "rhs")) (EApp (EApp (EVar "$core.andThen") (EApp (EVar "callStart") (EVar "rhs"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PCon "Loc" PWild (PVar "rl") (PVar "rc") PWild PWild) () (EIf (EBinOp "||" (EBinOp ">" (EVar "rl") (EVar "sl")) (EBinOp ">" (EVar "rc") (EVar "sc"))) (EApp (EVar "Some") (ERecordCreate "Fix" ((fa "fixApplicability" (EVar "Safe")) (fa "fixEdits" (EListLit (EApp (EApp (EVar "FixEdit") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "rl")) (EVar "rc"))) (ELit (LString ""))))) (fa "fixMessage" (ELit (LString "drop the `let _ =`")))))) (EVar "None")))))))
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
