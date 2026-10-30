# META
source_lines=105
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-missing-signature: a top-level value or function binding with no sibling type signature. Add one.

import frontend.ast.{
  Loc(..),
  Decl(..),
}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import hash_map.{HashMap, has, new, setInPlace}
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
import tools.lint_shared.{nameSetOf, ruleNameMissingSignature, topDefNameL}

export
rule : Rule
rule =
  mkVisitorRule
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
    missingSigVisitors
    None

-- Flag a top-level value/function binding (`DFunDef`, incl. through `DAttrib`)
-- whose name has NO sibling top-level `name : Type` signature (`DTypeSig`) in the
-- same file — Haskell's -Wmissing-signatures.  Purely syntactic: the signed
-- names are collected once per file, then each declaration is judged as the walk
-- reaches it.  `impl`/`interface` method bodies are nested inside their own decl
-- (not top-level `Decl`s), so a declaration visitor never sees them;
-- `prop`/`test`/`extern` are their own decl kinds, not `DFunDef`, so they are
-- excluded automatically.  `main` is exempt by name (entry-point boilerplate).
-- Only the first clause of a name is judged, so a multi-clause def yields one
-- finding; `seen` is that per-file record, fresh for every file.
missingSigVisitors : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
missingSigVisitors _ _ _ _ prog =
  -- HashMap-as-set: `contains n sigNames` over the signed-name LIST was O(signs)
  -- per def, i.e. O(defs x signs) across the file — and in the common case
  -- where most defs ARE signed, signs grows with defs, so this was quadratic. It
  -- is a PURE SCAN (no extra allocation), so the alloc signal is blind to it and
  -- only the `manydefs` shape's lint-stage TIME catches it (the issue-#110 class).
  let signed = nameSetOf (flatMap topSigNameL prog)
  let seen = new ()
  [OnDecl (missingSigAt signed seen)]

missingSigAt : HashMap String Unit ->
  HashMap String Unit ->
  Ctx ->
  Decl ->
  List Finding
missingSigAt signed seen ctx d =
  flatMap (firstUnsigned signed seen) (topDefNameL (d, ctx.ctxSpan))

firstUnsigned : HashMap String Unit ->
  HashMap String Unit ->
  (String, Option Loc) ->
  List Finding
firstUnsigned signed seen (n, loc)
  | has n seen = []
  | otherwise =
    let _ = setInPlace n () seen
    if missingSigPair signed (n, loc) then [missingSigFinding (n, loc)] else []

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
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "has" false) (mem "new" false) (mem "setInPlace" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "nameSetOf" false) (mem "ruleNameMissingSignature" false) (mem "topDefNameL" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameMissingSignature")) (fa "summary" (ELit (LString "top-level value/function binding has no sibling type signature (name : Type). Add one (Haskell -Wmissing-signatures)"))) (fa "doc" (ELit (LString "A top-level binding without a sibling type signature has an inferred type that changes silently when its body does. Write the signature (Haskell -Wmissing-signatures).\n\nBefore:\n  double x = x * 2\nAfter:\n  double : Int -> Int\n  double x = x * 2"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "missingSigVisitors")) (EVar "None")))
(DTypeSig false "missingSigVisitors" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "missingSigVisitors" (PWild PWild PWild PWild (PVar "prog")) (EBlock (DoLet false false (PVar "signed") (EApp (EVar "nameSetOf") (EApp (EApp (EVar "flatMap") (EVar "topSigNameL")) (EVar "prog")))) (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EListLit (EApp (EVar "OnDecl") (EApp (EApp (EVar "missingSigAt") (EVar "signed")) (EVar "seen")))))))
(DTypeSig false "missingSigAt" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "Ctx") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "missingSigAt" ((PVar "signed") (PVar "seen") (PVar "ctx") (PVar "d")) (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "firstUnsigned") (EVar "signed")) (EVar "seen"))) (EApp (EVar "topDefNameL") (ETuple (EVar "d") (EFieldAccess (EVar "ctx") "ctxSpan")))))
(DTypeSig false "firstUnsigned" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "firstUnsigned" ((PVar "signed") (PVar "seen") (PTuple (PVar "n") (PVar "loc"))) (EIf (EApp (EApp (EVar "has") (EVar "n")) (EVar "seen")) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (ELit LUnit)) (EVar "seen"))) (DoExpr (EIf (EApp (EApp (EVar "missingSigPair") (EVar "signed")) (ETuple (EVar "n") (EVar "loc"))) (EListLit (EApp (EVar "missingSigFinding") (ETuple (EVar "n") (EVar "loc")))) (EListLit)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
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
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "has" false) (mem "new" false) (mem "setInPlace" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "nameSetOf" false) (mem "ruleNameMissingSignature" false) (mem "topDefNameL" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameMissingSignature")) (fa "summary" (ELit (LString "top-level value/function binding has no sibling type signature (name : Type). Add one (Haskell -Wmissing-signatures)"))) (fa "doc" (ELit (LString "A top-level binding without a sibling type signature has an inferred type that changes silently when its body does. Write the signature (Haskell -Wmissing-signatures).\n\nBefore:\n  double x = x * 2\nAfter:\n  double : Int -> Int\n  double x = x * 2"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "missingSigVisitors")) (EVar "None")))
(DTypeSig false "missingSigVisitors" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "missingSigVisitors" (PWild PWild PWild PWild (PVar "prog")) (EBlock (DoLet false false (PVar "signed") (EApp (EVar "nameSetOf") (EApp (EApp (EDictApp "flatMap") (EVar "topSigNameL")) (EVar "prog")))) (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EListLit (EApp (EVar "OnDecl") (EApp (EApp (EVar "missingSigAt") (EVar "signed")) (EVar "seen")))))))
(DTypeSig false "missingSigAt" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "Ctx") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "missingSigAt" ((PVar "signed") (PVar "seen") (PVar "ctx") (PVar "d")) (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "firstUnsigned") (EVar "signed")) (EVar "seen"))) (EApp (EVar "topDefNameL") (ETuple (EVar "d") (EFieldAccess (EVar "ctx") "ctxSpan")))))
(DTypeSig false "firstUnsigned" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))))
(DFunDef false "firstUnsigned" ((PVar "signed") (PVar "seen") (PTuple (PVar "n") (PVar "loc"))) (EIf (EApp (EApp (EVar "has") (EVar "n")) (EVar "seen")) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "n")) (ELit LUnit)) (EVar "seen"))) (DoExpr (EIf (EApp (EApp (EVar "missingSigPair") (EVar "signed")) (ETuple (EVar "n") (EVar "loc"))) (EListLit (EApp (EVar "missingSigFinding") (ETuple (EVar "n") (EVar "loc")))) (EListLit)))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "topSigNameL" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "topSigNameL" ((PCon "DTypeSig" PWild (PVar "name") PWild PWild)) (EListLit (EVar "name")))
(DFunDef false "topSigNameL" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "topSigNameL") (EVar "d")))
(DFunDef false "topSigNameL" (PWild) (EListLit))
(DTypeSig false "missingSigPair" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "missingSigPair" ((PVar "sigNames") (PTuple (PVar "n") PWild)) (EApp (EVar "not") (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "main"))) (EApp (EApp (EVar "has") (EVar "n")) (EVar "sigNames")))))
(DTypeSig false "missingSigFinding" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Finding")))
(DFunDef false "missingSigFinding" ((PTuple (PVar "name") (PVar "loc"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameMissingSignature")) (fa "message" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "top-level '")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "' has no type signature. Add a `"))) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " : …` declaration")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
