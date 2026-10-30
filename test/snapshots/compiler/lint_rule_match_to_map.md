# META
source_lines=172
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
import tools.lint_core.{
  Applicability(..),
  Category(..),
  Ctx(..),
  FileFacts(..),
  Finding(..),
  Fix,
  Fixability(..),
  Need(..),
  Ratchet(..),
  Rule,
  RuleMeta(..),
  Scope(..),
  StdlibIndex,
  Visitor,
  mkVisitorRule,
}
import tools.lint_shared.{
  andThenEtaFn,
  bindingOf,
  rebinds,
  exprRuleEditVisitors,
  isEVarNamed,
  isNilPCon,
  matchToMapErrPassthru,
  matchToMapTransform,
  noExcl,
  replaceFix,
  ruleNameMatchToMap,
  sourceLine,
  tightSpan,
}

export
rule : Rule
rule =
  mkVisitorRule
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
      needs = [NeedsScopes, NeedsStdlibIndex],
    }
    ruleMatchToMap
    None

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
  List Visitor
ruleMatchToMap idx _ facts _ _ =
  exprRuleEditVisitors
    noExcl
    matchToMapOf
    (matchToMapEdit idx facts)
    matchToMapFinding

matchToMapFinding : Option Loc -> Expr -> Option Fix -> Finding
matchToMapFinding loc rewritten fix = Finding {
  rule = ruleNameMatchToMap,
  message =
    "2-arm match maps over an Option/Result — rewrite as '"
      ++ exprToString rewritten
      ++ "'",
  severity = SevWarning,
  loc = loc,
  fix = fix,
}

-- The fix replaces the whole `match` with the `map` call.  The call is `map`, so the
-- fix is withheld where the file binds `map`, which would capture it.  The arms'
-- constructors are not rebindable and need no guard.
matchToMapEdit : StdlibIndex -> FileFacts -> Ctx -> Expr -> Expr -> Option Fix
matchToMapEdit idx facts ctx e rewritten =
  if rebinds idx facts ctx "map" then
    None
  else
    replaceFix
      Safe
      "use map"
      (matchSpan facts ctx e)
      (bindingOf rewritten)
      ctx
      (exprToString rewritten)

-- The span the fix replaces.  An unparenthesised `match` starts at its keyword,
-- which its own `ELoc` gives, but that `ELoc` runs to the layout token after the
-- block, past any comment or blank line that follows.  The end is therefore the
-- last arm's last token.  A parenthesised match is wrapped by the parentheses'
-- `ELoc`, which starts at `(` and ends at `)`, so it is exact as it stands.
matchSpan : FileFacts -> Ctx -> Expr -> Option Loc
matchSpan facts ctx (EMatch _ arms) = match (ctx.ctxOwn, lastArmSpan arms)
  (Some (own@(Loc f sl sc _ _)), Some (Loc _ _ _ el ec)) =>
    if stringSlice sc (sc + 1) (sourceLine facts sl) == "(" then
      Some own
    else
      Some (Loc f sl sc el ec)
  _ => None
matchSpan _ _ _ = None

lastArmSpan : List Arm -> Option Loc
lastArmSpan [] = None
lastArmSpan [Arm _ _ body] = tightSpan body
lastArmSpan (_ :: rest) = lastArmSpan rest
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "Arm" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "isEmptyL" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "andThenEtaFn" false) (mem "bindingOf" false) (mem "rebinds" false) (mem "exprRuleEditVisitors" false) (mem "isEVarNamed" false) (mem "isNilPCon" false) (mem "matchToMapErrPassthru" false) (mem "matchToMapTransform" false) (mem "noExcl" false) (mem "replaceFix" false) (mem "ruleNameMatchToMap" false) (mem "sourceLine" false) (mem "tightSpan" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameMatchToMap")) (fa "summary" (ELit (LString "2-arm `match` on Option/Result that reconstructs the failure ctor and re-wraps the success ctor. That IS a functor `map` (hlint 'use fmap')"))) (fa "doc" (ELit (LString "A two-arm `match` on an `Option` or `Result` that passes the failure constructor through and re-wraps the success value is `map` (hlint \"use fmap\").\n\nBefore:\n  match r\n    Ok v => Ok (f v)\n    Err e => Err e\nAfter:\n  map f r"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsStdlibIndex")))))) (EVar "ruleMatchToMap")) (EVar "None")))
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
(DTypeSig false "ruleMatchToMap" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleMatchToMap" ((PVar "idx") PWild (PVar "facts") PWild PWild) (EApp (EApp (EApp (EApp (EVar "exprRuleEditVisitors") (EVar "noExcl")) (EVar "matchToMapOf")) (EApp (EApp (EVar "matchToMapEdit") (EVar "idx")) (EVar "facts"))) (EVar "matchToMapFinding")))
(DTypeSig false "matchToMapFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "matchToMapFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameMatchToMap")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "2-arm match maps over an Option/Result — rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "matchToMapEdit" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix"))))))))
(DFunDef false "matchToMapEdit" ((PVar "idx") (PVar "facts") (PVar "ctx") (PVar "e") (PVar "rewritten")) (EIf (EApp (EApp (EApp (EApp (EVar "rebinds") (EVar "idx")) (EVar "facts")) (EVar "ctx")) (ELit (LString "map"))) (EVar "None") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "replaceFix") (EVar "Safe")) (ELit (LString "use map"))) (EApp (EApp (EApp (EVar "matchSpan") (EVar "facts")) (EVar "ctx")) (EVar "e"))) (EApp (EVar "bindingOf") (EVar "rewritten"))) (EVar "ctx")) (EApp (EVar "exprToString") (EVar "rewritten")))))
(DTypeSig false "matchSpan" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "matchSpan" ((PVar "facts") (PVar "ctx") (PCon "EMatch" PWild (PVar "arms"))) (EMatch (ETuple (EFieldAccess (EVar "ctx") "ctxOwn") (EApp (EVar "lastArmSpan") (EVar "arms"))) (arm (PTuple (PCon "Some" (PAs "own" (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") PWild PWild))) (PCon "Some" (PCon "Loc" PWild PWild PWild (PVar "el") (PVar "ec")))) () (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "sc")) (EBinOp "+" (EVar "sc") (ELit (LInt 1)))) (EApp (EApp (EVar "sourceLine") (EVar "facts")) (EVar "sl"))) (ELit (LString "("))) (EApp (EVar "Some") (EVar "own")) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec"))))) (arm PWild () (EVar "None"))))
(DFunDef false "matchSpan" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "lastArmSpan" (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "lastArmSpan" ((PList)) (EVar "None"))
(DFunDef false "lastArmSpan" ((PList (PCon "Arm" PWild PWild (PVar "body")))) (EApp (EVar "tightSpan") (EVar "body")))
(DFunDef false "lastArmSpan" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastArmSpan") (EVar "rest")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "Arm" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "isEmptyL" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" false) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "andThenEtaFn" false) (mem "bindingOf" false) (mem "rebinds" false) (mem "exprRuleEditVisitors" false) (mem "isEVarNamed" false) (mem "isNilPCon" false) (mem "matchToMapErrPassthru" false) (mem "matchToMapTransform" false) (mem "noExcl" false) (mem "replaceFix" false) (mem "ruleNameMatchToMap" false) (mem "sourceLine" false) (mem "tightSpan" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameMatchToMap")) (fa "summary" (ELit (LString "2-arm `match` on Option/Result that reconstructs the failure ctor and re-wraps the success ctor. That IS a functor `map` (hlint 'use fmap')"))) (fa "doc" (ELit (LString "A two-arm `match` on an `Option` or `Result` that passes the failure constructor through and re-wraps the success value is `map` (hlint \"use fmap\").\n\nBefore:\n  match r\n    Ok v => Ok (f v)\n    Err e => Err e\nAfter:\n  map f r"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsStdlibIndex")))))) (EVar "ruleMatchToMap")) (EVar "None")))
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
(DTypeSig false "ruleMatchToMap" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleMatchToMap" ((PVar "idx") PWild (PVar "facts") PWild PWild) (EApp (EApp (EApp (EApp (EVar "exprRuleEditVisitors") (EVar "noExcl")) (EVar "matchToMapOf")) (EApp (EApp (EVar "matchToMapEdit") (EVar "idx")) (EVar "facts"))) (EVar "matchToMapFinding")))
(DTypeSig false "matchToMapFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "matchToMapFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameMatchToMap")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "2-arm match maps over an Option/Result — rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "matchToMapEdit" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix"))))))))
(DFunDef false "matchToMapEdit" ((PVar "idx") (PVar "facts") (PVar "ctx") (PVar "e") (PVar "rewritten")) (EIf (EApp (EApp (EApp (EApp (EVar "rebinds") (EVar "idx")) (EVar "facts")) (EVar "ctx")) (ELit (LString "map"))) (EVar "None") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "replaceFix") (EVar "Safe")) (ELit (LString "use map"))) (EApp (EApp (EApp (EVar "matchSpan") (EVar "facts")) (EVar "ctx")) (EVar "e"))) (EApp (EVar "bindingOf") (EVar "rewritten"))) (EVar "ctx")) (EApp (EVar "exprToString") (EVar "rewritten")))))
(DTypeSig false "matchSpan" (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "matchSpan" ((PVar "facts") (PVar "ctx") (PCon "EMatch" PWild (PVar "arms"))) (EMatch (ETuple (EFieldAccess (EVar "ctx") "ctxOwn") (EApp (EVar "lastArmSpan") (EVar "arms"))) (arm (PTuple (PCon "Some" (PAs "own" (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") PWild PWild))) (PCon "Some" (PCon "Loc" PWild PWild PWild (PVar "el") (PVar "ec")))) () (EIf (EBinOp "==" (EApp (EApp (EApp (EVar "stringSlice") (EVar "sc")) (EBinOp "+" (EVar "sc") (ELit (LInt 1)))) (EApp (EApp (EVar "sourceLine") (EVar "facts")) (EVar "sl"))) (ELit (LString "("))) (EApp (EVar "Some") (EVar "own")) (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "sl")) (EVar "sc")) (EVar "el")) (EVar "ec"))))) (arm PWild () (EVar "None"))))
(DFunDef false "matchSpan" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "lastArmSpan" (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "lastArmSpan" ((PList)) (EVar "None"))
(DFunDef false "lastArmSpan" ((PList (PCon "Arm" PWild PWild (PVar "body")))) (EApp (EVar "tightSpan") (EVar "body")))
(DFunDef false "lastArmSpan" ((PCons PWild (PVar "rest"))) (EApp (EVar "lastArmSpan") (EVar "rest")))
