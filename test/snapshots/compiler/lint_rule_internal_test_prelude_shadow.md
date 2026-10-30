# META
source_lines=92
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-test-prelude-shadow: a `*_test.mdk` file declares a top-level `isOk`/`isErr`/`isSome`/`isNone`, shadowing the prelude function of that name (suggest-only).

import frontend.ast.{Loc(..), Decl(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{contains, endsWith}
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
  ruleNameTestPreludeShadow,
  topDefNameL,
}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameTestPreludeShadow,
      summary =
        "a `*_test.mdk` file declares a top-level `isOk`/`isErr`/`isSome`/`isNone`, shadowing the prelude function of that name (suggest-only)",
      doc =
        "A `*_test.mdk` file that declares a top-level `isOk`, `isErr`, `isSome` or `isNone` shadows the prelude function of that name for the rest of the file. Suggest-only; this guards the repository test-helper convention.\n\nBefore:\n  isOk r = ...   -- in foo_test.mdk\nAfter:\n  rename the helper",
      category = Suspicious,
      scope = Internal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleTestPreludeShadow
    None

-- ── rule: test-prelude-shadow ─────────────────────────────────────────────────
-- A top-level `isOk`/`isErr`/`isSome`/`isNone` in a `*_test.mdk` file shadows the
-- prelude function of that name for the rest of that file, while every OTHER
-- module in the program — a `deriving`-generated impl body included — keeps
-- calling the prelude one.  Two functions of one name then answer the same
-- question and no diagnostic ever fires, because both spellings are individually
-- well-typed.
--
-- Scoped to `*_test.mdk`: a non-test module that redeclares one of these names is
-- making a considered choice about its own namespace, where a test file's copy is
-- an author who did not know the prelude already had it.
--
-- Suggest-only (`fix = None`), for two independent reasons: (a) the local body
-- may not be the prelude's body, so deleting it changes behaviour rather than
-- preserving it, and lint has no type environment to prove otherwise; (b) `fix`
-- rewrites ONE `Decl`, and a binding's `name : Type` signature is a SEPARATE
-- `Decl`, so any deletion this rule could express leaves an orphan signature.
preludeShadowedNames : List String
preludeShadowedNames = ["isOk", "isErr", "isSome", "isNone"]

ruleTestPreludeShadow : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleTestPreludeShadow _ path _ pos prog
  | not (endsWith "_test.mdk" path) = []
  | otherwise =
    flatMap
      preludeShadowHit
      (dedupeNamesLoc (flatMap topDefNameL (declLocList pos prog)))

preludeShadowHit : (String, Option Loc) -> List Finding
preludeShadowHit (name, loc)
  | contains name preludeShadowedNames = [preludeShadowFinding name loc]
  | otherwise = []

preludeShadowFinding : String -> Option Loc -> Finding
preludeShadowFinding name loc = Finding {
  rule = ruleNameTestPreludeShadow,
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
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "endsWith" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "dedupeNamesLoc" false) (mem "declLocList" false) (mem "ruleNameTestPreludeShadow" false) (mem "topDefNameL" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameTestPreludeShadow")) (fa "summary" (ELit (LString "a `*_test.mdk` file declares a top-level `isOk`/`isErr`/`isSome`/`isNone`, shadowing the prelude function of that name (suggest-only)"))) (fa "doc" (ELit (LString "A `*_test.mdk` file that declares a top-level `isOk`, `isErr`, `isSome` or `isNone` shadows the prelude function of that name for the rest of the file. Suggest-only; this guards the repository test-helper convention.\n\nBefore:\n  isOk r = ...   -- in foo_test.mdk\nAfter:\n  rename the helper"))) (fa "category" (EVar "Suspicious")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleTestPreludeShadow")) (EVar "None")))
(DTypeSig false "preludeShadowedNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "preludeShadowedNames" () (EListLit (ELit (LString "isOk")) (ELit (LString "isErr")) (ELit (LString "isSome")) (ELit (LString "isNone"))))
(DTypeSig false "ruleTestPreludeShadow" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleTestPreludeShadow" (PWild (PVar "path") PWild (PVar "pos") (PVar "prog")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "endsWith") (ELit (LString "_test.mdk"))) (EVar "path"))) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EVar "flatMap") (EVar "preludeShadowHit")) (EApp (EVar "dedupeNamesLoc") (EApp (EApp (EVar "flatMap") (EVar "topDefNameL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "preludeShadowHit" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "preludeShadowHit" ((PTuple (PVar "name") (PVar "loc"))) (EIf (EApp (EApp (EVar "contains") (EVar "name")) (EVar "preludeShadowedNames")) (EListLit (EApp (EApp (EVar "preludeShadowFinding") (EVar "name")) (EVar "loc"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "preludeShadowFinding" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Finding"))))
(DFunDef false "preludeShadowFinding" ((PVar "name") (PVar "loc")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameTestPreludeShadow")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "top-level `")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "` shadows the prelude function of that name for this file only; other modules, and any `deriving` impl, keep calling the prelude one. Remove the local declaration")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "contains" false) (mem "endsWith" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "dedupeNamesLoc" false) (mem "declLocList" false) (mem "ruleNameTestPreludeShadow" false) (mem "topDefNameL" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameTestPreludeShadow")) (fa "summary" (ELit (LString "a `*_test.mdk` file declares a top-level `isOk`/`isErr`/`isSome`/`isNone`, shadowing the prelude function of that name (suggest-only)"))) (fa "doc" (ELit (LString "A `*_test.mdk` file that declares a top-level `isOk`, `isErr`, `isSome` or `isNone` shadows the prelude function of that name for the rest of the file. Suggest-only; this guards the repository test-helper convention.\n\nBefore:\n  isOk r = ...   -- in foo_test.mdk\nAfter:\n  rename the helper"))) (fa "category" (EVar "Suspicious")) (fa "scope" (EVar "Internal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleTestPreludeShadow")) (EVar "None")))
(DTypeSig false "preludeShadowedNames" (TyApp (TyCon "List") (TyCon "String")))
(DFunDef false "preludeShadowedNames" () (EListLit (ELit (LString "isOk")) (ELit (LString "isErr")) (ELit (LString "isSome")) (ELit (LString "isNone"))))
(DTypeSig false "ruleTestPreludeShadow" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleTestPreludeShadow" (PWild (PVar "path") PWild (PVar "pos") (PVar "prog")) (EIf (EApp (EVar "not") (EApp (EApp (EVar "endsWith") (ELit (LString "_test.mdk"))) (EVar "path"))) (EListLit) (EIf (EVar "otherwise") (EApp (EApp (EDictApp "flatMap") (EVar "preludeShadowHit")) (EApp (EVar "dedupeNamesLoc") (EApp (EApp (EDictApp "flatMap") (EVar "topDefNameL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "preludeShadowHit" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "preludeShadowHit" ((PTuple (PVar "name") (PVar "loc"))) (EIf (EApp (EApp (EVar "contains") (EVar "name")) (EVar "preludeShadowedNames")) (EListLit (EApp (EApp (EVar "preludeShadowFinding") (EVar "name")) (EVar "loc"))) (EIf (EVar "otherwise") (EListLit) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "preludeShadowFinding" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Finding"))))
(DFunDef false "preludeShadowFinding" ((PVar "name") (PVar "loc")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameTestPreludeShadow")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "top-level `")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "` shadows the prelude function of that name for this file only; other modules, and any `deriving` impl, keep calling the prelude one. Remove the local declaration")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
