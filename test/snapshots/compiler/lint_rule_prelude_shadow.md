# META
source_lines=105
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-prelude-shadow: a module declares a top-level `isOk`/`isErr`/`isSome`/`isNone`, shadowing the prelude function of that name (suggest-only).

import frontend.ast.{Loc(..), Decl(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import list.{lookup}
import support.util.{contains}
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
  mkRule,
}
import tools.lint_shared.{
  dedupeNamesLoc,
  declLocList,
  ruleNamePreludeShadow,
  topDefNameL,
}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNamePreludeShadow,
      summary =
        "a module declares a top-level `isOk`/`isErr`/`isSome`/`isNone`, shadowing the prelude function of that name (suggest-only)",
      doc =
        "A module that declares a top-level `isOk`, `isErr`, `isSome` or `isNone` shadows the prelude function of that name for the rest of the file, while every other module keeps calling the prelude one. A module that declares the `Option` or `Result` type itself, as the prelude does, is not shadowing the names over that type. Suggest-only. Delete the local copy when it behaves like the prelude one; otherwise rename it to say what it tests.\n\nBefore:\n  isSome o = o == 1\nAfter:\n  isOne o = o == 1",
      category = Suspicious,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    rulePreludeShadow
    None

-- ── rule: prelude-shadow ─────────────────────────────────────────────────
-- A top-level `isOk`/`isErr`/`isSome`/`isNone` shadows the prelude function of
-- that name for the rest of its file, while every OTHER
-- module in the program — a `deriving`-generated impl body included — keeps
-- calling the prelude one.  Two functions of one name then answer the same
-- question and no diagnostic ever fires, because both spellings are individually
-- well-typed.
--
-- A declaration is the original rather than a shadow in the module that declares
-- the type it tests: the prelude declares `Option` and `Result`, so its `isSome`
-- and `isOk` are exempt.  The test reads the declarations, not the file name, so
-- it holds from any working directory and for a file merely named `core.mdk`.
--
-- Suggest-only (`fix = None`), for two independent reasons: (a) the local body
-- may not be the prelude's body, so deleting it changes behaviour rather than
-- preserving it, and lint has no type environment to prove otherwise; (b) `fix`
-- rewrites ONE `Decl`, and a binding's `name : Type` signature is a SEPARATE
-- `Decl`, so any deletion this rule could express leaves an orphan signature.
-- Each shadowed name with the prelude type it tests.
preludeShadowedNames : List (String, String)
preludeShadowedNames = [
  ("isOk", "Result"),
  ("isErr", "Result"),
  ("isSome", "Option"),
  ("isNone", "Option"),
]

rulePreludeShadow : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
rulePreludeShadow _ _ _ pos prog =
  flatMap
    (preludeShadowHit (declaredTypes prog))
    (dedupeNamesLoc (flatMap topDefNameL (declLocList pos prog)))

declaredTypes : List Decl -> List String
declaredTypes prog = flatMap declaredType prog

declaredType : Decl -> List String
declaredType (DData { dataName = n }) = [n]
declaredType _ = []

preludeShadowHit : List String -> (String, Option Loc) -> List Finding
preludeShadowHit owned (name, loc) = match lookup name preludeShadowedNames
  Some ty => if contains ty owned then [] else [preludeShadowFinding name loc]
  None => []

preludeShadowFinding : String -> Option Loc -> Finding
preludeShadowFinding name loc = Finding {
  rule = ruleNamePreludeShadow,
  message =
    "top-level `\{name}` shadows the prelude function of that name for this file only; other modules, and any `deriving` impl, keep calling the prelude one. Remove the local declaration",
  severity = SevWarning,
  loc = loc,
  fix = None,
}
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("list") ((mem "lookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "dedupeNamesLoc" false) (mem "declLocList" false) (mem "ruleNamePreludeShadow" false) (mem "topDefNameL" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNamePreludeShadow")) (fa "summary" (ELit (LString "a module declares a top-level `isOk`/`isErr`/`isSome`/`isNone`, shadowing the prelude function of that name (suggest-only)"))) (fa "doc" (ELit (LString "A module that declares a top-level `isOk`, `isErr`, `isSome` or `isNone` shadows the prelude function of that name for the rest of the file, while every other module keeps calling the prelude one. A module that declares the `Option` or `Result` type itself, as the prelude does, is not shadowing the names over that type. Suggest-only. Delete the local copy when it behaves like the prelude one; otherwise rename it to say what it tests.\n\nBefore:\n  isSome o = o == 1\nAfter:\n  isOne o = o == 1"))) (fa "category" (EVar "Suspicious")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "rulePreludeShadow")) (EVar "None")))
(DTypeSig false "preludeShadowedNames" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "preludeShadowedNames" () (EListLit (ETuple (ELit (LString "isOk")) (ELit (LString "Result"))) (ETuple (ELit (LString "isErr")) (ELit (LString "Result"))) (ETuple (ELit (LString "isSome")) (ELit (LString "Option"))) (ETuple (ELit (LString "isNone")) (ELit (LString "Option")))))
(DTypeSig false "rulePreludeShadow" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "rulePreludeShadow" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EApp (EVar "preludeShadowHit") (EApp (EVar "declaredTypes") (EVar "prog")))) (EApp (EVar "dedupeNamesLoc") (EApp (EApp (EVar "flatMap") (EVar "topDefNameL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))))
(DTypeSig false "declaredTypes" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declaredTypes" ((PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "declaredType")) (EVar "prog")))
(DTypeSig false "declaredType" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declaredType" ((PRec "DData" ((rf "dataName" (PVar "n"))) false)) (EListLit (EVar "n")))
(DFunDef false "declaredType" (PWild) (EListLit))
(DTypeSig false "preludeShadowHit" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "preludeShadowHit" ((PVar "owned") (PTuple (PVar "name") (PVar "loc"))) (EMatch (EApp (EApp (EVar "lookup") (EVar "name")) (EVar "preludeShadowedNames")) (arm (PCon "Some" (PVar "ty")) () (EIf (EApp (EApp (EVar "contains") (EVar "ty")) (EVar "owned")) (EListLit) (EListLit (EApp (EApp (EVar "preludeShadowFinding") (EVar "name")) (EVar "loc"))))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "preludeShadowFinding" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Finding"))))
(DFunDef false "preludeShadowFinding" ((PVar "name") (PVar "loc")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNamePreludeShadow")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "top-level `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` shadows the prelude function of that name for this file only; other modules, and any `deriving` impl, keep calling the prelude one. Remove the local declaration")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("list") ((mem "lookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "dedupeNamesLoc" false) (mem "declLocList" false) (mem "ruleNamePreludeShadow" false) (mem "topDefNameL" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNamePreludeShadow")) (fa "summary" (ELit (LString "a module declares a top-level `isOk`/`isErr`/`isSome`/`isNone`, shadowing the prelude function of that name (suggest-only)"))) (fa "doc" (ELit (LString "A module that declares a top-level `isOk`, `isErr`, `isSome` or `isNone` shadows the prelude function of that name for the rest of the file, while every other module keeps calling the prelude one. A module that declares the `Option` or `Result` type itself, as the prelude does, is not shadowing the names over that type. Suggest-only. Delete the local copy when it behaves like the prelude one; otherwise rename it to say what it tests.\n\nBefore:\n  isSome o = o == 1\nAfter:\n  isOne o = o == 1"))) (fa "category" (EVar "Suspicious")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "rulePreludeShadow")) (EVar "None")))
(DTypeSig false "preludeShadowedNames" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "preludeShadowedNames" () (EListLit (ETuple (ELit (LString "isOk")) (ELit (LString "Result"))) (ETuple (ELit (LString "isErr")) (ELit (LString "Result"))) (ETuple (ELit (LString "isSome")) (ELit (LString "Option"))) (ETuple (ELit (LString "isNone")) (ELit (LString "Option")))))
(DTypeSig false "rulePreludeShadow" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "rulePreludeShadow" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "preludeShadowHit") (EApp (EVar "declaredTypes") (EVar "prog")))) (EApp (EVar "dedupeNamesLoc") (EApp (EApp (EDictApp "flatMap") (EVar "topDefNameL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))))
(DTypeSig false "declaredTypes" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declaredTypes" ((PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "declaredType")) (EVar "prog")))
(DTypeSig false "declaredType" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "declaredType" ((PRec "DData" ((rf "dataName" (PVar "n"))) false)) (EListLit (EVar "n")))
(DFunDef false "declaredType" (PWild) (EListLit))
(DTypeSig false "preludeShadowHit" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "preludeShadowHit" ((PVar "owned") (PTuple (PVar "name") (PVar "loc"))) (EMatch (EApp (EApp (EVar "lookup") (EVar "name")) (EVar "preludeShadowedNames")) (arm (PCon "Some" (PVar "ty")) () (EIf (EApp (EApp (EVar "contains") (EVar "ty")) (EVar "owned")) (EListLit) (EListLit (EApp (EApp (EVar "preludeShadowFinding") (EVar "name")) (EVar "loc"))))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "preludeShadowFinding" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Finding"))))
(DFunDef false "preludeShadowFinding" ((PVar "name") (PVar "loc")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNamePreludeShadow")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "top-level `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` shadows the prelude function of that name for this file only; other modules, and any `deriving` impl, keep calling the prelude one. Remove the local declaration")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
