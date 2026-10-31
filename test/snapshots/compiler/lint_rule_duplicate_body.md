# META
source_lines=62
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-duplicate-body: a top-level function body structurally identical to one in another file (cross-file copy-paste).

import frontend.ast.{Decl(..)}
import frontend.parser.{Positions(..)}
import tools.lint_index.{ProjectIndex}
import driver.diagnostics.{Severity(..)}
import tools.lint_core.{
  Category(..),
  Finding(..),
  Fixability(..),
  Ratchet(..),
  RuleMeta(..),
  Scope(..),
  FileFacts,
  ProjectRule,
  Summary(..),
  factDupClauses,
  mkProjectRule,
}
import tools.lint_shared.{ruleNameDuplicateBody}
import tools.lint_dup.{dupJoin, dupOccsOfClauses}

export
rule : ProjectRule
rule =
  mkProjectRule
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
    summarizeDuplicateBody
    evaluateDuplicateBody

-- The file's body-key occurrences, which is all the join needs of it.
summarizeDuplicateBody : String ->
  FileFacts ->
  Positions ->
  List Decl ->
  Summary
summarizeDuplicateBody path facts _ _ =
  DupOccs (map dropPath (dupOccsOfClauses path (factDupClauses facts)))

dropPath : (String, Int, String, String) -> (Int, String, String)
dropPath (_, line, name, key) = (line, name, key)

evaluateDuplicateBody : ProjectIndex -> List (String, Summary) -> List Finding
evaluateDuplicateBody _ files = dupJoin (flatMap occsOfFile files)

occsOfFile : (String, Summary) -> List (String, Int, String, String)
occsOfFile (path, DupOccs occs) = map (withPath path) occs

withPath : String -> (Int, String, String) -> (String, Int, String, String)
withPath path (line, name, key) = (path, line, name, key)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("tools" "lint_index") ((mem "ProjectIndex" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "RuleMeta" true) (mem "Scope" true) (mem "FileFacts" false) (mem "ProjectRule" false) (mem "Summary" true) (mem "factDupClauses" false) (mem "mkProjectRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameDuplicateBody" false))))
(DUse false (UseGroup ("tools" "lint_dup") ((mem "dupJoin" false) (mem "dupOccsOfClauses" false))))
(DTypeSig true "rule" (TyCon "ProjectRule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkProjectRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDuplicateBody")) (fa "summary" (ELit (LString "top-level function body is structurally identical to one in another file (copy-paste; consolidate)"))) (fa "doc" (ELit (LString "A top-level function whose body is structurally identical to one in another file (location-stripped, above a complexity floor) is copy-paste across modules. Consolidate into one module and import it. The same-file arm of the rule covers duplicates inside one file.\n\nBefore:\n  a.mdk: f x = big x\n  b.mdk: g y = big y   -- same body shape\nAfter:\n  one definition, imported where needed"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "summarizeDuplicateBody")) (EVar "evaluateDuplicateBody")))
(DTypeSig false "summarizeDuplicateBody" (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Summary"))))))
(DFunDef false "summarizeDuplicateBody" ((PVar "path") (PVar "facts") PWild PWild) (EApp (EVar "DupOccs") (EApp (EApp (EVar "map") (EVar "dropPath")) (EApp (EApp (EVar "dupOccsOfClauses") (EVar "path")) (EApp (EVar "factDupClauses") (EVar "facts"))))))
(DTypeSig false "dropPath" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyTuple (TyCon "Int") (TyCon "String") (TyCon "String"))))
(DFunDef false "dropPath" ((PTuple PWild (PVar "line") (PVar "name") (PVar "key"))) (ETuple (EVar "line") (EVar "name") (EVar "key")))
(DTypeSig false "evaluateDuplicateBody" (TyFun (TyCon "ProjectIndex") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Summary"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "evaluateDuplicateBody" (PWild (PVar "files")) (EApp (EVar "dupJoin") (EApp (EApp (EVar "flatMap") (EVar "occsOfFile")) (EVar "files"))))
(DTypeSig false "occsOfFile" (TyFun (TyTuple (TyCon "String") (TyCon "Summary")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")))))
(DFunDef false "occsOfFile" ((PTuple (PVar "path") (PCon "DupOccs" (PVar "occs")))) (EApp (EApp (EVar "map") (EApp (EVar "withPath") (EVar "path"))) (EVar "occs")))
(DTypeSig false "withPath" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Int") (TyCon "String") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")))))
(DFunDef false "withPath" ((PVar "path") (PTuple (PVar "line") (PVar "name") (PVar "key"))) (ETuple (EVar "path") (EVar "line") (EVar "name") (EVar "key")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("tools" "lint_index") ((mem "ProjectIndex" false))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "RuleMeta" true) (mem "Scope" true) (mem "FileFacts" false) (mem "ProjectRule" false) (mem "Summary" true) (mem "factDupClauses" false) (mem "mkProjectRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ruleNameDuplicateBody" false))))
(DUse false (UseGroup ("tools" "lint_dup") ((mem "dupJoin" false) (mem "dupOccsOfClauses" false))))
(DTypeSig true "rule" (TyCon "ProjectRule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkProjectRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameDuplicateBody")) (fa "summary" (ELit (LString "top-level function body is structurally identical to one in another file (copy-paste; consolidate)"))) (fa "doc" (ELit (LString "A top-level function whose body is structurally identical to one in another file (location-stripped, above a complexity floor) is copy-paste across modules. Consolidate into one module and import it. The same-file arm of the rule covers duplicates inside one file.\n\nBefore:\n  a.mdk: f x = big x\n  b.mdk: g y = big y   -- same body shape\nAfter:\n  one definition, imported where needed"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "summarizeDuplicateBody")) (EVar "evaluateDuplicateBody")))
(DTypeSig false "summarizeDuplicateBody" (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Summary"))))))
(DFunDef false "summarizeDuplicateBody" ((PVar "path") (PVar "facts") PWild PWild) (EApp (EVar "DupOccs") (EApp (EApp (EMethodRef "map") (EVar "dropPath")) (EApp (EApp (EVar "dupOccsOfClauses") (EVar "path")) (EApp (EVar "factDupClauses") (EVar "facts"))))))
(DTypeSig false "dropPath" (TyFun (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")) (TyTuple (TyCon "Int") (TyCon "String") (TyCon "String"))))
(DFunDef false "dropPath" ((PTuple PWild (PVar "line") (PVar "name") (PVar "key"))) (ETuple (EVar "line") (EVar "name") (EVar "key")))
(DTypeSig false "evaluateDuplicateBody" (TyFun (TyCon "ProjectIndex") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Summary"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "evaluateDuplicateBody" (PWild (PVar "files")) (EApp (EVar "dupJoin") (EApp (EApp (EDictApp "flatMap") (EVar "occsOfFile")) (EVar "files"))))
(DTypeSig false "occsOfFile" (TyFun (TyTuple (TyCon "String") (TyCon "Summary")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")))))
(DFunDef false "occsOfFile" ((PTuple (PVar "path") (PCon "DupOccs" (PVar "occs")))) (EApp (EApp (EMethodRef "map") (EApp (EVar "withPath") (EVar "path"))) (EVar "occs")))
(DTypeSig false "withPath" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "Int") (TyCon "String") (TyCon "String")) (TyTuple (TyCon "String") (TyCon "Int") (TyCon "String") (TyCon "String")))))
(DFunDef false "withPath" ((PVar "path") (PTuple (PVar "line") (PVar "name") (PVar "key"))) (ETuple (EVar "path") (EVar "line") (EVar "name") (EVar "key")))
