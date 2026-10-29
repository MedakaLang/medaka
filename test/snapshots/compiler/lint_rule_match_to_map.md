# META
source_lines=127
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-match-to-map: a 2-arm `match` on Option/Result that re-wraps the success constructor and passes the failure through. Prefer `map`.

import frontend.ast.{
  Loc(..),
  Pat(..),
  Arm(..),
  Expr(..),
  Decl(..),
}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{isEmptyL}
import tools.printer.{exprToString}
import frontend.exhaust.{Oracle}
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
  andThenEtaFn,
  detApply,
  exprRuleFindings,
  exprRuleFix,
  isEVarNamed,
  isNilPCon,
  matchToMapErrPassthru,
  matchToMapTransform,
  noExcl,
  ruleNameMatchToMap,
}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameMatchToMap,
      summary =
        "2-arm `match` on Option/Result that reconstructs the failure ctor and re-wraps the success ctor. That IS a functor `map` (hlint 'use fmap')",
      doc =
        "A two-arm `match` on an `Option` or `Result` that passes the failure constructor through and re-wraps the success value is `map` (hlint \"use fmap\").\n\nBefore:\n  match r\n    Ok v => Ok (f v)\n    Err e => Err e\nAfter:\n  map f r",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleMatchToMap
    (Some matchToMapFix)

-- build the map function: eta-reduce `p => f p` to `f` (reusing `andThenEtaFn`),
-- else a lambda over the (possibly non-simple) binder pattern.
matchToMapFn : Pat -> Expr -> Expr
matchToMapFn (PVar x l bid) expr = match andThenEtaFn x expr
  Some f => f
  None => ELam [PVar x l bid] expr
matchToMapFn binder expr = ELam [binder] expr

matchToMapCall : Pat -> Expr -> Expr -> Expr
matchToMapCall binder expr scrut =
  EApp (EApp (EVar "map") (matchToMapFn binder expr)) scrut

-- Option map: (noneArm, someArm) in this order.
matchToMapOption : Expr -> Arm -> Arm -> Option Expr
matchToMapOption scrut (Arm pn gn bn) (Arm ps gs bs)
  | isEmptyL gn && isEmptyL gs && isNilPCon "None" pn && isEVarNamed "None" bn =
    map
      ((binder, expr) => matchToMapCall binder expr scrut)
      (matchToMapTransform "Some" ps bs)
  | otherwise = None

-- Result map: (errArm, okArm) in this order.
matchToMapResult : Expr -> Arm -> Arm -> Option Expr
matchToMapResult scrut (Arm pe ge be) (Arm po go bo)
  | isEmptyL ge && isEmptyL go && matchToMapErrPassthru pe be =
    map
      ((binder, expr) => matchToMapCall binder expr scrut)
      (matchToMapTransform "Ok" po bo)
  | otherwise = None

-- try both ctor-pairs in both arm orders.
matchToMapPair : Expr -> Arm -> Arm -> Option Expr
matchToMapPair scrut a1 a2 =
  orElse
    (matchToMapOption scrut a1 a2)
    (orElse
      (matchToMapOption scrut a2 a1)
      (orElse (matchToMapResult scrut a1 a2) (matchToMapResult scrut a2 a1)))

-- detector (matches the RAW `EMatch`, never its `ELoc` wrapper).
matchToMapOf : Expr -> Option Expr
matchToMapOf (EMatch scrut arms) = match arms
  [a1, a2] => matchToMapPair scrut a1 a2
  _ => None
matchToMapOf _ = None

ruleMatchToMap : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleMatchToMap _ _ _ pos prog =
  exprRuleFindings noExcl matchToMapOf matchToMapFinding pos prog

matchToMapFinding : Option Loc -> Expr -> Finding
matchToMapFinding loc rewritten = Finding {
  rule = ruleNameMatchToMap,
  message =
    "2-arm match maps over an Option/Result — rewrite as '"
      ++ exprToString rewritten
      ++ "'",
  severity = SevWarning,
  loc = loc,
}

matchToMapFix : Oracle -> Decl -> Option (List Decl)
matchToMapFix _ d = exprRuleFix noExcl (detApply matchToMapOf) d
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "Arm" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "isEmptyL" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "andThenEtaFn" false) (mem "detApply" false) (mem "exprRuleFindings" false) (mem "exprRuleFix" false) (mem "isEVarNamed" false) (mem "isNilPCon" false) (mem "matchToMapErrPassthru" false) (mem "matchToMapTransform" false) (mem "noExcl" false) (mem "ruleNameMatchToMap" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameMatchToMap")) (fa "summary" (ELit (LString "2-arm `match` on Option/Result that reconstructs the failure ctor and re-wraps the success ctor. That IS a functor `map` (hlint 'use fmap')"))) (fa "doc" (ELit (LString "A two-arm `match` on an `Option` or `Result` that passes the failure constructor through and re-wraps the success value is `map` (hlint \"use fmap\").\n\nBefore:\n  match r\n    Ok v => Ok (f v)\n    Err e => Err e\nAfter:\n  map f r"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleMatchToMap")) (EApp (EVar "Some") (EVar "matchToMapFix"))))
(DTypeSig false "matchToMapFn" (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "matchToMapFn" ((PCon "PVar" (PVar "x") (PVar "l") (PVar "bid")) (PVar "expr")) (EMatch (EApp (EApp (EVar "andThenEtaFn") (EVar "x")) (EVar "expr")) (arm (PCon "Some" (PVar "f")) () (EVar "f")) (arm (PCon "None") () (EApp (EApp (EVar "ELam") (EListLit (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EVar "l")) (EVar "bid")))) (EVar "expr")))))
(DFunDef false "matchToMapFn" ((PVar "binder") (PVar "expr")) (EApp (EApp (EVar "ELam") (EListLit (EVar "binder"))) (EVar "expr")))
(DTypeSig false "matchToMapCall" (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "matchToMapCall" ((PVar "binder") (PVar "expr") (PVar "scrut")) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "map")))) (EApp (EApp (EVar "matchToMapFn") (EVar "binder")) (EVar "expr")))) (EVar "scrut")))
(DTypeSig false "matchToMapOption" (TyFun (TyCon "Expr") (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "matchToMapOption" ((PVar "scrut") (PCon "Arm" (PVar "pn") (PVar "gn") (PVar "bn")) (PCon "Arm" (PVar "ps") (PVar "gs") (PVar "bs"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "gn")) (EApp (EVar "isEmptyL") (EVar "gs"))) (EApp (EApp (EVar "isNilPCon") (ELit (LString "None"))) (EVar "pn"))) (EApp (EApp (EVar "isEVarNamed") (ELit (LString "None"))) (EVar "bn"))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "binder") (PVar "expr"))) (EApp (EApp (EApp (EVar "matchToMapCall") (EVar "binder")) (EVar "expr")) (EVar "scrut")))) (EApp (EApp (EApp (EVar "matchToMapTransform") (ELit (LString "Some"))) (EVar "ps")) (EVar "bs"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "matchToMapResult" (TyFun (TyCon "Expr") (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "matchToMapResult" ((PVar "scrut") (PCon "Arm" (PVar "pe") (PVar "ge") (PVar "be")) (PCon "Arm" (PVar "po") (PVar "go") (PVar "bo"))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "ge")) (EApp (EVar "isEmptyL") (EVar "go"))) (EApp (EApp (EVar "matchToMapErrPassthru") (EVar "pe")) (EVar "be"))) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "binder") (PVar "expr"))) (EApp (EApp (EApp (EVar "matchToMapCall") (EVar "binder")) (EVar "expr")) (EVar "scrut")))) (EApp (EApp (EApp (EVar "matchToMapTransform") (ELit (LString "Ok"))) (EVar "po")) (EVar "bo"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "matchToMapPair" (TyFun (TyCon "Expr") (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "matchToMapPair" ((PVar "scrut") (PVar "a1") (PVar "a2")) (EApp (EApp (EVar "orElse") (EApp (EApp (EApp (EVar "matchToMapOption") (EVar "scrut")) (EVar "a1")) (EVar "a2"))) (EApp (EApp (EVar "orElse") (EApp (EApp (EApp (EVar "matchToMapOption") (EVar "scrut")) (EVar "a2")) (EVar "a1"))) (EApp (EApp (EVar "orElse") (EApp (EApp (EApp (EVar "matchToMapResult") (EVar "scrut")) (EVar "a1")) (EVar "a2"))) (EApp (EApp (EApp (EVar "matchToMapResult") (EVar "scrut")) (EVar "a2")) (EVar "a1"))))))
(DTypeSig false "matchToMapOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "matchToMapOf" ((PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EMatch (EVar "arms") (arm (PList (PVar "a1") (PVar "a2")) () (EApp (EApp (EApp (EVar "matchToMapPair") (EVar "scrut")) (EVar "a1")) (EVar "a2"))) (arm PWild () (EVar "None"))))
(DFunDef false "matchToMapOf" (PWild) (EVar "None"))
(DTypeSig false "ruleMatchToMap" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleMatchToMap" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "noExcl")) (EVar "matchToMapOf")) (EVar "matchToMapFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "matchToMapFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "matchToMapFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameMatchToMap")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "2-arm match maps over an Option/Result — rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "matchToMapFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "matchToMapFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "matchToMapOf"))) (EVar "d")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "Arm" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "isEmptyL" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "andThenEtaFn" false) (mem "detApply" false) (mem "exprRuleFindings" false) (mem "exprRuleFix" false) (mem "isEVarNamed" false) (mem "isNilPCon" false) (mem "matchToMapErrPassthru" false) (mem "matchToMapTransform" false) (mem "noExcl" false) (mem "ruleNameMatchToMap" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameMatchToMap")) (fa "summary" (ELit (LString "2-arm `match` on Option/Result that reconstructs the failure ctor and re-wraps the success ctor. That IS a functor `map` (hlint 'use fmap')"))) (fa "doc" (ELit (LString "A two-arm `match` on an `Option` or `Result` that passes the failure constructor through and re-wraps the success value is `map` (hlint \"use fmap\").\n\nBefore:\n  match r\n    Ok v => Ok (f v)\n    Err e => Err e\nAfter:\n  map f r"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleMatchToMap")) (EApp (EVar "Some") (EVar "matchToMapFix"))))
(DTypeSig false "matchToMapFn" (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "matchToMapFn" ((PCon "PVar" (PVar "x") (PVar "l") (PVar "bid")) (PVar "expr")) (EMatch (EApp (EApp (EVar "andThenEtaFn") (EVar "x")) (EVar "expr")) (arm (PCon "Some" (PVar "f")) () (EVar "f")) (arm (PCon "None") () (EApp (EApp (EVar "ELam") (EListLit (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EVar "l")) (EVar "bid")))) (EVar "expr")))))
(DFunDef false "matchToMapFn" ((PVar "binder") (PVar "expr")) (EApp (EApp (EVar "ELam") (EListLit (EVar "binder"))) (EVar "expr")))
(DTypeSig false "matchToMapCall" (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "matchToMapCall" ((PVar "binder") (PVar "expr") (PVar "scrut")) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "map")))) (EApp (EApp (EVar "matchToMapFn") (EVar "binder")) (EVar "expr")))) (EVar "scrut")))
(DTypeSig false "matchToMapOption" (TyFun (TyCon "Expr") (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "matchToMapOption" ((PVar "scrut") (PCon "Arm" (PVar "pn") (PVar "gn") (PVar "bn")) (PCon "Arm" (PVar "ps") (PVar "gs") (PVar "bs"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "gn")) (EApp (EVar "isEmptyL") (EVar "gs"))) (EApp (EApp (EVar "isNilPCon") (ELit (LString "None"))) (EVar "pn"))) (EApp (EApp (EVar "isEVarNamed") (ELit (LString "None"))) (EVar "bn"))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "binder") (PVar "expr"))) (EApp (EApp (EApp (EVar "matchToMapCall") (EVar "binder")) (EVar "expr")) (EVar "scrut")))) (EApp (EApp (EApp (EVar "matchToMapTransform") (ELit (LString "Some"))) (EVar "ps")) (EVar "bs"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "matchToMapResult" (TyFun (TyCon "Expr") (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "matchToMapResult" ((PVar "scrut") (PCon "Arm" (PVar "pe") (PVar "ge") (PVar "be")) (PCon "Arm" (PVar "po") (PVar "go") (PVar "bo"))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "ge")) (EApp (EVar "isEmptyL") (EVar "go"))) (EApp (EApp (EVar "matchToMapErrPassthru") (EVar "pe")) (EVar "be"))) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "binder") (PVar "expr"))) (EApp (EApp (EApp (EVar "matchToMapCall") (EVar "binder")) (EVar "expr")) (EVar "scrut")))) (EApp (EApp (EApp (EVar "matchToMapTransform") (ELit (LString "Ok"))) (EVar "po")) (EVar "bo"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "matchToMapPair" (TyFun (TyCon "Expr") (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "matchToMapPair" ((PVar "scrut") (PVar "a1") (PVar "a2")) (EApp (EApp (EMethodRef "orElse") (EApp (EApp (EApp (EVar "matchToMapOption") (EVar "scrut")) (EVar "a1")) (EVar "a2"))) (EApp (EApp (EMethodRef "orElse") (EApp (EApp (EApp (EVar "matchToMapOption") (EVar "scrut")) (EVar "a2")) (EVar "a1"))) (EApp (EApp (EMethodRef "orElse") (EApp (EApp (EApp (EVar "matchToMapResult") (EVar "scrut")) (EVar "a1")) (EVar "a2"))) (EApp (EApp (EApp (EVar "matchToMapResult") (EVar "scrut")) (EVar "a2")) (EVar "a1"))))))
(DTypeSig false "matchToMapOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "matchToMapOf" ((PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EMatch (EVar "arms") (arm (PList (PVar "a1") (PVar "a2")) () (EApp (EApp (EApp (EVar "matchToMapPair") (EVar "scrut")) (EVar "a1")) (EVar "a2"))) (arm PWild () (EVar "None"))))
(DFunDef false "matchToMapOf" (PWild) (EVar "None"))
(DTypeSig false "ruleMatchToMap" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleMatchToMap" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EApp (EApp (EApp (EVar "exprRuleFindings") (EVar "noExcl")) (EVar "matchToMapOf")) (EVar "matchToMapFinding")) (EVar "pos")) (EVar "prog")))
(DTypeSig false "matchToMapFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "matchToMapFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameMatchToMap")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "2-arm match maps over an Option/Result — rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "matchToMapFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "matchToMapFix" (PWild (PVar "d")) (EApp (EApp (EApp (EVar "exprRuleFix") (EVar "noExcl")) (EApp (EVar "detApply") (EVar "matchToMapOf"))) (EVar "d")))
