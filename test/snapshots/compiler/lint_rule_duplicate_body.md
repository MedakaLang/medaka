# META
source_lines=39
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-duplicate-body: a top-level function body structurally identical to one in another file (cross-file copy-paste).

import frontend.ast.{Decl(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import tools.lint_core.{
  Category(..),
  Finding(..),
  Fixability(..),
  Ratchet(..),
  RuleMeta(..),
  Scope(..),
  CrossFileRule,
  mkCrossFileRule,
}
import tools.lint_shared.{ruleNameDuplicateBody}
import tools.lint_dup.{dupJoin, fileDupOccs}

export
rule : CrossFileRule
rule =
  mkCrossFileRule
    RuleMeta {
      name = ruleNameDuplicateBody,
      summary =
        "top-level function body is structurally identical to one in another file (copy-paste; consolidate)",
      doc =
        "A top-level function whose body is structurally identical to one in another file (location-stripped, above a complexity floor) is copy-paste across modules. Consolidate into one module and import it. The same-file arm of the rule covers duplicates inside one file.\n\nBefore:\n  a.mdk: f x = big x\n  b.mdk: g y = big y   -- same body shape\nAfter:\n  one definition, imported where needed",
      category = Complexity,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleDuplicateBody

ruleDuplicateBody : List (String, Positions, List Decl) -> List Finding
ruleDuplicateBody files = dupJoin (flatMap fileDupOccs files)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "RuleMeta" true) (mem "Scope" true) (mem "CrossFileRule" false) (mem "mkCrossFileRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameDuplicateBody" false))))
(DUse false (UseGroup ("tools" "lint_dup") ((mem "dupJoin" false) (mem "fileDupOccs" false))))
(DTypeSig true "rule" (TyCon "CrossFileRule"))
(DFunDef false "rule" () (EApp (EApp (EVar "mkCrossFileRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDuplicateBody")) (fa "summary" (ELit (LString "top-level function body is structurally identical to one in another file (copy-paste; consolidate)"))) (fa "doc" (ELit (LString "A top-level function whose body is structurally identical to one in another file (location-stripped, above a complexity floor) is copy-paste across modules. Consolidate into one module and import it. The same-file arm of the rule covers duplicates inside one file.\n\nBefore:\n  a.mdk: f x = big x\n  b.mdk: g y = big y   -- same body shape\nAfter:\n  one definition, imported where needed"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleDuplicateBody")))
(DTypeSig false "ruleDuplicateBody" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "ruleDuplicateBody" ((PVar "files")) (EApp (EVar "dupJoin") (EApp (EApp (EVar "flatMap") (EVar "fileDupOccs")) (EVar "files"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "RuleMeta" true) (mem "Scope" true) (mem "CrossFileRule" false) (mem "mkCrossFileRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameDuplicateBody" false))))
(DUse false (UseGroup ("tools" "lint_dup") ((mem "dupJoin" false) (mem "fileDupOccs" false))))
(DTypeSig true "rule" (TyCon "CrossFileRule"))
(DFunDef false "rule" () (EApp (EApp (EVar "mkCrossFileRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDuplicateBody")) (fa "summary" (ELit (LString "top-level function body is structurally identical to one in another file (copy-paste; consolidate)"))) (fa "doc" (ELit (LString "A top-level function whose body is structurally identical to one in another file (location-stripped, above a complexity floor) is copy-paste across modules. Consolidate into one module and import it. The same-file arm of the rule covers duplicates inside one file.\n\nBefore:\n  a.mdk: f x = big x\n  b.mdk: g y = big y   -- same body shape\nAfter:\n  one definition, imported where needed"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleDuplicateBody")))
(DTypeSig false "ruleDuplicateBody" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Positions") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "ruleDuplicateBody" ((PVar "files")) (EApp (EVar "dupJoin") (EApp (EApp (EDictApp "flatMap") (EVar "fileDupOccs")) (EVar "files"))))
