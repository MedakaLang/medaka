# META
source_lines=92
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-missing-signature: a top-level value or function binding with no sibling type signature. Add one.

import frontend.ast.{
  Loc(..),
  Decl(..),
}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{filterList}
import hash_map.{HashMap, has}
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
  nameSetOf,
  ruleNameMissingSignature,
  topDefNameL,
}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameMissingSignature,
      summary =
        "top-level value/function binding has no sibling type signature (name : Type). Add one (Haskell -Wmissing-signatures)",
      doc =
        "A top-level binding without a sibling type signature has an inferred type that changes silently when its body does. Write the signature (Haskell -Wmissing-signatures).\n\nBefore:\n  double x = x * 2\nAfter:\n  double : Int -> Int\n  double x = x * 2",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleMissingSignature
    None

-- Flag a top-level value/function binding (`DFunDef`, incl. through `DAttrib`)
-- whose name has NO sibling top-level `name : Type` signature (`DTypeSig`) in the
-- same file — Haskell's -Wmissing-signatures.  Purely syntactic: build the set of
-- signed names, then report `DFunDef` names absent from it.  `impl`/`interface`
-- method bodies are nested inside their own decl (not top-level `Decl`s), so a
-- `List Decl` walk never sees them; `prop`/`test`/`extern` are their own decl
-- kinds, not `DFunDef`, so they are excluded automatically.  `main` is exempt by
-- name (entry-point boilerplate).  Multi-clause defs dedupe to one finding.
ruleMissingSignature : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleMissingSignature _ _ _ pos prog =
  -- HashMap-as-set: `contains n sigNames` over the signed-name LIST was O(signs)
  -- per def, i.e. O(defs x signs) across the filterList — and in the common case
  -- where most defs ARE signed, signs grows with defs, so this was quadratic. It
  -- is a PURE SCAN (no extra allocation), so the alloc signal is blind to it and
  -- only the `manydefs` shape's lint-stage TIME catches it (the issue-#110 class).
  map
    missingSigFinding
    (filterList
      (missingSigPair (nameSetOf (flatMap topSigNameL prog)))
      (dedupeNamesLoc (flatMap topDefNameL (declLocList pos prog))))

topSigNameL : Decl -> List String
topSigNameL (DTypeSig _ name _ _) = [name]
topSigNameL (DAttrib _ d) = topSigNameL d
topSigNameL _ = []

missingSigPair : HashMap String Unit -> (String, Option Loc) -> Bool
missingSigPair sigNames (n, _) = not (n == "main" || has n sigNames)

missingSigFinding : (String, Option Loc) -> Finding
missingSigFinding (name, loc) = Finding {
  rule = ruleNameMissingSignature,
  message =
    "top-level '\{name}' has no type signature. Add a `\{name} : …` declaration",
  severity = SevWarning,
  loc = loc,
}
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "filterList" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "has" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "dedupeNamesLoc" false) (mem "declLocList" false) (mem "nameSetOf" false) (mem "ruleNameMissingSignature" false) (mem "topDefNameL" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameMissingSignature")) (fa "summary" (ELit (LString "top-level value/function binding has no sibling type signature (name : Type). Add one (Haskell -Wmissing-signatures)"))) (fa "doc" (ELit (LString "A top-level binding without a sibling type signature has an inferred type that changes silently when its body does. Write the signature (Haskell -Wmissing-signatures).\n\nBefore:\n  double x = x * 2\nAfter:\n  double : Int -> Int\n  double x = x * 2"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleMissingSignature")) (EVar "None")))
(DTypeSig false "ruleMissingSignature" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleMissingSignature" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "map") (EVar "missingSigFinding")) (EApp (EApp (EVar "filterList") (EApp (EVar "missingSigPair") (EApp (EVar "nameSetOf") (EApp (EApp (EVar "flatMap") (EVar "topSigNameL")) (EVar "prog"))))) (EApp (EVar "dedupeNamesLoc") (EApp (EApp (EVar "flatMap") (EVar "topDefNameL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog")))))))
(DTypeSig false "topSigNameL" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "topSigNameL" ((PCon "DTypeSig" PWild (PVar "name") PWild PWild)) (EListLit (EVar "name")))
(DFunDef false "topSigNameL" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "topSigNameL") (EVar "d")))
(DFunDef false "topSigNameL" (PWild) (EListLit))
(DTypeSig false "missingSigPair" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "missingSigPair" ((PVar "sigNames") (PTuple (PVar "n") PWild)) (EApp (EVar "not") (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "main"))) (EApp (EApp (EVar "has") (EVar "n")) (EVar "sigNames")))))
(DTypeSig false "missingSigFinding" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Finding")))
(DFunDef false "missingSigFinding" ((PTuple (PVar "name") (PVar "loc"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameMissingSignature")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "top-level '")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "' has no type signature. Add a `"))) (EApp (EVar "display") (EVar "name"))) (ELit (LString " : …` declaration")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "filterList" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "has" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "dedupeNamesLoc" false) (mem "declLocList" false) (mem "nameSetOf" false) (mem "ruleNameMissingSignature" false) (mem "topDefNameL" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameMissingSignature")) (fa "summary" (ELit (LString "top-level value/function binding has no sibling type signature (name : Type). Add one (Haskell -Wmissing-signatures)"))) (fa "doc" (ELit (LString "A top-level binding without a sibling type signature has an inferred type that changes silently when its body does. Write the signature (Haskell -Wmissing-signatures).\n\nBefore:\n  double x = x * 2\nAfter:\n  double : Int -> Int\n  double x = x * 2"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleMissingSignature")) (EVar "None")))
(DTypeSig false "ruleMissingSignature" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleMissingSignature" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EMethodRef "map") (EVar "missingSigFinding")) (EApp (EApp (EVar "filterList") (EApp (EVar "missingSigPair") (EApp (EVar "nameSetOf") (EApp (EApp (EDictApp "flatMap") (EVar "topSigNameL")) (EVar "prog"))))) (EApp (EVar "dedupeNamesLoc") (EApp (EApp (EDictApp "flatMap") (EVar "topDefNameL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog")))))))
(DTypeSig false "topSigNameL" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "topSigNameL" ((PCon "DTypeSig" PWild (PVar "name") PWild PWild)) (EListLit (EVar "name")))
(DFunDef false "topSigNameL" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "topSigNameL") (EVar "d")))
(DFunDef false "topSigNameL" (PWild) (EListLit))
(DTypeSig false "missingSigPair" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "missingSigPair" ((PVar "sigNames") (PTuple (PVar "n") PWild)) (EApp (EVar "not") (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "main"))) (EApp (EApp (EVar "has") (EVar "n")) (EVar "sigNames")))))
(DTypeSig false "missingSigFinding" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Finding")))
(DFunDef false "missingSigFinding" ((PTuple (PVar "name") (PVar "loc"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameMissingSignature")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "top-level '")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "' has no type signature. Add a `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " : …` declaration")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
