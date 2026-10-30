# META
source_lines=117
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-complement-predicate: `not (p x)` where `p` has a defined complement predicate. Call the complement directly.

import frontend.ast.{Loc(..), Expr(..), Decl(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import tools.printer.{exprToString}
import frontend.exhaust.{Oracle}
import tools.lint_core.{
  Category(..),
  FileFacts,
  Finding(..),
  Fixability(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  Visitor,
  mkVisitorRule,
}
import tools.lint_shared.{
  detApply,
  exprRuleVisitors,
  exprRuleFix,
  notArgOf,
  ruleNameComplementPredicate,
  unwrapLoc,
}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameComplementPredicate,
      summary =
        "`not (p x)` where `p` has a defined complement predicate (`isEmptyL`/`isSome`/`isOk` & inverses). Call the complement directly",
      doc =
        "Negating a predicate that has a defined complement (`isEmptyL`/`isSome`/`isOk` and their inverses) is clearer as a call to the complement.\n\nBefore:\n  not (isSome x)\nAfter:\n  isNone x",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleComplementPredicate
    (Some complementPredicateFix)

-- `not (p args…)` where `p` is a registered predicate with a defined complement
-- `q`, rewritten to `q args…` (the args carried verbatim).  Curated BIDIRECTIONAL
-- pairs only — the complement must actually exist:
--   isEmptyL ↔ isNonEmptyL   (compiler `support/util.mdk`)
--   isEmptyList ↔ isNonEmptyList  (a List helper pair some modules define locally)
--   isSome ↔ isNone          (prelude `core.mdk`)
--   isOk ↔ isErr             (prelude `core.mdk`)
-- Matches the `not` prelude-fn form only (see `notArgOf`).  Purely syntactic —
-- only the exact registered names fire; anything else (`not (isEmptyL x && …)`,
-- `not (someOtherPred x)`) is left alone.  Excludes the complement helpers' OWN
-- definitions (`isNonEmptyL xs = not (isEmptyL xs)`) — their bodies ARE this idiom,
-- so rewriting would produce `isNonEmptyL xs = isNonEmptyL xs`.
complementExcl : String -> Bool
complementExcl name = name == "isNonEmptyL" || name == "isNonEmptyList"

complementOf : String -> Option String
complementOf "isEmptyL" = Some "isNonEmptyL"
complementOf "isNonEmptyL" = Some "isEmptyL"
complementOf "isEmptyList" = Some "isNonEmptyList"
complementOf "isNonEmptyList" = Some "isEmptyList"
complementOf "isSome" = Some "isNone"
complementOf "isNone" = Some "isSome"
complementOf "isOk" = Some "isErr"
complementOf "isErr" = Some "isOk"
complementOf _ = None

-- head var name of a (possibly curried multi-arg) application spine.
appSpineHead : Expr -> Option String
appSpineHead e = match unwrapLoc e
  EVar n => Some n
  EApp hd _ => appSpineHead (unwrapLoc hd)
  _ => None

-- rebuild the spine, renaming only the head var; every arg carried verbatim.
renameSpineHead : String -> Expr -> Expr
renameSpineHead newName e = match unwrapLoc e
  EVar _ => EVar newName
  EApp hd arg => EApp (renameSpineHead newName hd) arg
  _ => e

complementPredOf : Expr -> Option Expr
complementPredOf e = do
  inner <- notArgOf e
  name <- appSpineHead (unwrapLoc inner)
  comp <- complementOf name
  Some (renameSpineHead comp (unwrapLoc inner))

ruleComplementPredicate : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleComplementPredicate _ _ _ _ _ =
  exprRuleVisitors complementExcl complementPredOf complementPredicateFinding

complementPredicateFinding : Option Loc -> Expr -> Finding
complementPredicateFinding loc rewritten = Finding {
  rule = ruleNameComplementPredicate,
  message = "negated predicate. Rewrite as '" ++ exprToString rewritten ++ "'",
  severity = SevWarning,
  loc = loc,
  fix = None,
}

complementPredicateFix : Oracle -> Decl -> Option (List Decl)
complementPredicateFix _ d =
  exprRuleFix complementExcl (detApply complementPredOf) d
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleVisitors" false) (mem "exprRuleFix" false) (mem "notArgOf" false) (mem "ruleNameComplementPredicate" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameComplementPredicate")) (fa "summary" (ELit (LString "`not (p x)` where `p` has a defined complement predicate (`isEmptyL`/`isSome`/`isOk` & inverses). Call the complement directly"))) (fa "doc" (ELit (LString "Negating a predicate that has a defined complement (`isEmptyL`/`isSome`/`isOk` and their inverses) is clearer as a call to the complement.\n\nBefore:\n  not (isSome x)\nAfter:\n  isNone x"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleComplementPredicate")) (EApp (EVar "Some") (EVar "complementPredicateFix"))))
(DTypeSig false "complementExcl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "complementExcl" ((PVar "name")) (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "isNonEmptyL"))) (EBinOp "==" (EVar "name") (ELit (LString "isNonEmptyList")))))
(DTypeSig false "complementOf" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "complementOf" ((PLit (LString "isEmptyL"))) (EApp (EVar "Some") (ELit (LString "isNonEmptyL"))))
(DFunDef false "complementOf" ((PLit (LString "isNonEmptyL"))) (EApp (EVar "Some") (ELit (LString "isEmptyL"))))
(DFunDef false "complementOf" ((PLit (LString "isEmptyList"))) (EApp (EVar "Some") (ELit (LString "isNonEmptyList"))))
(DFunDef false "complementOf" ((PLit (LString "isNonEmptyList"))) (EApp (EVar "Some") (ELit (LString "isEmptyList"))))
(DFunDef false "complementOf" ((PLit (LString "isSome"))) (EApp (EVar "Some") (ELit (LString "isNone"))))
(DFunDef false "complementOf" ((PLit (LString "isNone"))) (EApp (EVar "Some") (ELit (LString "isSome"))))
(DFunDef false "complementOf" ((PLit (LString "isOk"))) (EApp (EVar "Some") (ELit (LString "isErr"))))
(DFunDef false "complementOf" ((PLit (LString "isErr"))) (EApp (EVar "Some") (ELit (LString "isOk"))))
(DFunDef false "complementOf" (PWild) (EVar "None"))
(DTypeSig false "appSpineHead" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "appSpineHead" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "n")) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "EApp" (PVar "hd") PWild) () (EApp (EVar "appSpineHead") (EApp (EVar "unwrapLoc") (EVar "hd")))) (arm PWild () (EVar "None"))))
(DTypeSig false "renameSpineHead" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "renameSpineHead" ((PVar "newName") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" PWild) () (EApp (EVar "EVar") (EVar "newName"))) (arm (PCon "EApp" (PVar "hd") (PVar "arg")) () (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "renameSpineHead") (EVar "newName")) (EVar "hd"))) (EVar "arg"))) (arm PWild () (EVar "e"))))
(DTypeSig false "complementPredOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "complementPredOf" ((PVar "e")) (EApp (EApp (EVar "andThen") (EApp (EVar "notArgOf") (EVar "e"))) (ELam ((PVar "inner")) (EApp (EApp (EVar "andThen") (EApp (EVar "appSpineHead") (EApp (EVar "unwrapLoc") (EVar "inner")))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EVar "complementOf") (EVar "name"))) (ELam ((PVar "comp")) (EApp (EVar "Some") (EApp (EApp (EVar "renameSpineHead") (EVar "comp")) (EApp (EVar "unwrapLoc") (EVar "inner")))))))))))
(DTypeSig false "ruleComplementPredicate" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleComplementPredicate" (PWild PWild PWild PWild PWild) (EApp (EApp (EApp (EVar "exprRuleVisitors") (EVar "complementExcl")) (EVar "complementPredOf")) (EVar "complementPredicateFinding")))
(DTypeSig false "complementPredicateFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "complementPredicateFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameComplementPredicate")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "negated predicate. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "complementPredicateFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "complementPredicateFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "complementExcl")) (EApp (EVar "detApply") (EVar "complementPredOf"))) (EVar "d")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" false) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "detApply" false) (mem "exprRuleVisitors" false) (mem "exprRuleFix" false) (mem "notArgOf" false) (mem "ruleNameComplementPredicate" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameComplementPredicate")) (fa "summary" (ELit (LString "`not (p x)` where `p` has a defined complement predicate (`isEmptyL`/`isSome`/`isOk` & inverses). Call the complement directly"))) (fa "doc" (ELit (LString "Negating a predicate that has a defined complement (`isEmptyL`/`isSome`/`isOk` and their inverses) is clearer as a call to the complement.\n\nBefore:\n  not (isSome x)\nAfter:\n  isNone x"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleComplementPredicate")) (EApp (EVar "Some") (EVar "complementPredicateFix"))))
(DTypeSig false "complementExcl" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "complementExcl" ((PVar "name")) (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "isNonEmptyL"))) (EBinOp "==" (EVar "name") (ELit (LString "isNonEmptyList")))))
(DTypeSig false "complementOf" (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "complementOf" ((PLit (LString "isEmptyL"))) (EApp (EVar "Some") (ELit (LString "isNonEmptyL"))))
(DFunDef false "complementOf" ((PLit (LString "isNonEmptyL"))) (EApp (EVar "Some") (ELit (LString "isEmptyL"))))
(DFunDef false "complementOf" ((PLit (LString "isEmptyList"))) (EApp (EVar "Some") (ELit (LString "isNonEmptyList"))))
(DFunDef false "complementOf" ((PLit (LString "isNonEmptyList"))) (EApp (EVar "Some") (ELit (LString "isEmptyList"))))
(DFunDef false "complementOf" ((PLit (LString "isSome"))) (EApp (EVar "Some") (ELit (LString "isNone"))))
(DFunDef false "complementOf" ((PLit (LString "isNone"))) (EApp (EVar "Some") (ELit (LString "isSome"))))
(DFunDef false "complementOf" ((PLit (LString "isOk"))) (EApp (EVar "Some") (ELit (LString "isErr"))))
(DFunDef false "complementOf" ((PLit (LString "isErr"))) (EApp (EVar "Some") (ELit (LString "isOk"))))
(DFunDef false "complementOf" (PWild) (EVar "None"))
(DTypeSig false "appSpineHead" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "appSpineHead" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "n")) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "EApp" (PVar "hd") PWild) () (EApp (EVar "appSpineHead") (EApp (EVar "unwrapLoc") (EVar "hd")))) (arm PWild () (EVar "None"))))
(DTypeSig false "renameSpineHead" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "renameSpineHead" ((PVar "newName") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" PWild) () (EApp (EVar "EVar") (EVar "newName"))) (arm (PCon "EApp" (PVar "hd") (PVar "arg")) () (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "renameSpineHead") (EVar "newName")) (EVar "hd"))) (EVar "arg"))) (arm PWild () (EVar "e"))))
(DTypeSig false "complementPredOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "complementPredOf" ((PVar "e")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "notArgOf") (EVar "e"))) (ELam ((PVar "inner")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "appSpineHead") (EApp (EVar "unwrapLoc") (EVar "inner")))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "complementOf") (EVar "name"))) (ELam ((PVar "comp")) (EApp (EVar "Some") (EApp (EApp (EVar "renameSpineHead") (EVar "comp")) (EApp (EVar "unwrapLoc") (EVar "inner")))))))))))
(DTypeSig false "ruleComplementPredicate" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleComplementPredicate" (PWild PWild PWild PWild PWild) (EApp (EApp (EApp (EVar "exprRuleVisitors") (EVar "complementExcl")) (EVar "complementPredOf")) (EVar "complementPredicateFinding")))
(DTypeSig false "complementPredicateFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "complementPredicateFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameComplementPredicate")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "negated predicate. Rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "complementPredicateFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "complementPredicateFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "complementExcl")) (EApp (EVar "detApply") (EVar "complementPredOf"))) (EVar "d")))
