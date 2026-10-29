# META
source_lines=137
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-self-shadow-extern: a top-level binding unconditionally forwards to itself (`f s = f s`, `x = x`), an infinite self-recursion.

import frontend.ast.{Loc(..), Pat(..), Expr(..), Decl(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{allList, filterList, dedupBy}
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
import tools.lint_shared.{declLocList, ruleNameSelfShadowExtern}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameSelfShadowExtern,
      summary =
        "top-level binding unconditionally forwards to itself (`f s = f s`, `x = x`) — an infinite self-recursion, not a forward to a same-named extern (#266)",
      doc =
        "A top-level binding that unconditionally forwards to itself (`f s = f s`, `x = x`) is an infinite recursion, usually an extern wrapper that forgot it shadows the extern it meant to call (#266).\n\nBefore:\n  strLen s = strLen s\nAfter:\n  call the extern under its real name",
      category = Correctness,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleSelfShadowExtern
    None

-- ── rule: self-shadow-extern (#266) ───────────────────────────────────────────
-- A top-level binding that UNCONDITIONALLY forwards to itself, with no branch that
-- could supply a base case.  The classic shape is an extern re-export written under
-- the SAME name — `stringLength s = stringLength s`, intending to forward to the
-- `stringLength` extern but in fact recursing into the local binding forever — and
-- its value-level sibling `x = x`.  Both typecheck with ZERO diagnostics and
-- stack-overflow at runtime (#266, the repo's #1 check-green/run-dies class).
--
-- The predicate is extern-AGNOSTIC — decided from the raw AST alone:
--   * NULLARY binding `x = <body>` fires iff `<body>` is EXACTLY the bare self
--     reference `EVar x` (after stripping ELoc/EAnnot).  That is the forcing loop
--     `x = x`.  `x = f x` / `x = x + 1` are NOT flagged (head isn't the bare self).
--   * N-ARY binding `f a… = <body>` fires iff `<body>` is an application SPINE
--     whose head (after stripping wrappers) is `EVar f` — `f s = f s`,
--     `stringLength s = stringLength s`, `f s = f (s + 1)`: every one loops forever
--     because nothing between the `=` and the self-call can terminate it.
-- A body headed by `if`/`match`/`EGuards`/`let`/lambda is NOT an unconditional
-- self-call (the self-call, if any, sits inside a branch that may also NOT be
-- taken), so legitimate recursion — `fac`, `map`, ANY base-case recursion — is
-- skipped: it never has a bare self-call at the head.  `f x = f` (returns a partial
-- application, no loop) is skipped too — its body is an `EVar`, not an `EApp`.
--
-- To stay sound under MULTI-CLAUSE definitions, a name fires only when EVERY clause
-- of that name is an unconditional self-call: a single non-self clause is a
-- candidate base case (`f [] = 0` beside `f xs = f (tail xs)`), so the whole name
-- is spared.  Purely syntactic, no false-fire risk beyond genuinely-looping code.
ruleSelfShadowExtern : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleSelfShadowExtern _ _ _ pos prog =
  selfShadowFindings (flatMap selfShadowClauseL (declLocList pos prog))

selfShadowFindings : List (String, List Pat, Expr, Option Loc) -> List Finding
selfShadowFindings clauses =
  map
    selfShadowFinding
    (filterList
      (allClausesSelfCall clauses)
      (dedupBy fst (map clauseNameLoc clauses)))

-- one (name, params, body, loc) tuple per top-level DFunDef (through DAttrib)
selfShadowClauseL : (Decl, Option Loc) ->
  List (String, List Pat, Expr, Option Loc)
selfShadowClauseL (DFunDef _ name pats body _ _, loc) =
  [(name, pats, body, loc)]
selfShadowClauseL (DAttrib _ d, loc) = selfShadowClauseL (d, loc)
selfShadowClauseL _ = []

clauseNameLoc : (String, List Pat, Expr, Option Loc) -> (String, Option Loc)
clauseNameLoc (n, _, _, l) = (n, l)

-- every clause defining `name` is an unconditional self-call
allClausesSelfCall : List (String, List Pat, Expr, Option Loc) ->
  (String, Option Loc) ->
  Bool
allClausesSelfCall clauses (name, _) =
  allList (clauseSelfCallOrOther name) clauses

clauseSelfCallOrOther : String -> (String, List Pat, Expr, Option Loc) -> Bool
clauseSelfCallOrOther name (cn, pats, body, _) =
  cn /= name || unconditionalSelfCall name pats body

-- nullary: body is exactly the bare self reference; n-ary: body is an application
-- spine whose head is the bare self reference.
unconditionalSelfCall : String -> List Pat -> Expr -> Bool
unconditionalSelfCall name [] body = isBareSelf name (stripWrap body)
unconditionalSelfCall name _ body = isHeadSelfApp name (stripWrap body)

stripWrap : Expr -> Expr
stripWrap (ELoc _ e) = stripWrap e
stripWrap (EAnnot e _) = stripWrap e
stripWrap e = e

isBareSelf : String -> Expr -> Bool
isBareSelf name (EVar w) = name == w
isBareSelf _ _ = False

isHeadSelfApp : String -> Expr -> Bool
isHeadSelfApp name (EApp f a) = isBareSelf name (appHead (stripWrap f))
isHeadSelfApp _ _ = False

appHead : Expr -> Expr
appHead e = match stripWrap e
  EApp f _ => appHead f
  x => x

selfShadowFinding : (String, Option Loc) -> Finding
selfShadowFinding (name, loc) = Finding {
  rule = ruleNameSelfShadowExtern,
  message =
    "top-level '\{name}' unconditionally calls itself with no base case — an infinite self-recursion, not a forward to a same-named extern/definition. Rename the binding (give it a distinct name) or add a terminating `match`/`if`/guard",
  severity = SevWarning,
  loc = loc,
}
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "filterList" false) (mem "dedupBy" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "declLocList" false) (mem "ruleNameSelfShadowExtern" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameSelfShadowExtern")) (fa "summary" (ELit (LString "top-level binding unconditionally forwards to itself (`f s = f s`, `x = x`) — an infinite self-recursion, not a forward to a same-named extern (#266)"))) (fa "doc" (ELit (LString "A top-level binding that unconditionally forwards to itself (`f s = f s`, `x = x`) is an infinite recursion, usually an extern wrapper that forgot it shadows the extern it meant to call (#266).\n\nBefore:\n  strLen s = strLen s\nAfter:\n  call the extern under its real name"))) (fa "category" (EVar "Correctness")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleSelfShadowExtern")) (EVar "None")))
(DTypeSig false "ruleSelfShadowExtern" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleSelfShadowExtern" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EVar "selfShadowFindings") (EApp (EApp (EVar "flatMap") (EVar "selfShadowClauseL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog")))))
(DTypeSig false "selfShadowFindings" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "selfShadowFindings" ((PVar "clauses")) (EApp (EApp (EVar "map") (EVar "selfShadowFinding")) (EApp (EApp (EVar "filterList") (EApp (EVar "allClausesSelfCall") (EVar "clauses"))) (EApp (EApp (EVar "dedupBy") (EVar "fst")) (EApp (EApp (EVar "map") (EVar "clauseNameLoc")) (EVar "clauses"))))))
(DTypeSig false "selfShadowClauseL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "selfShadowClauseL" ((PTuple (PCon "DFunDef" PWild (PVar "name") (PVar "pats") (PVar "body") PWild PWild) (PVar "loc"))) (EListLit (ETuple (EVar "name") (EVar "pats") (EVar "body") (EVar "loc"))))
(DFunDef false "selfShadowClauseL" ((PTuple (PCon "DAttrib" PWild (PVar "d")) (PVar "loc"))) (EApp (EVar "selfShadowClauseL") (ETuple (EVar "d") (EVar "loc"))))
(DFunDef false "selfShadowClauseL" (PWild) (EListLit))
(DTypeSig false "clauseNameLoc" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "clauseNameLoc" ((PTuple (PVar "n") PWild PWild (PVar "l"))) (ETuple (EVar "n") (EVar "l")))
(DTypeSig false "allClausesSelfCall" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "allClausesSelfCall" ((PVar "clauses") (PTuple (PVar "name") PWild)) (EApp (EApp (EVar "allList") (EApp (EVar "clauseSelfCallOrOther") (EVar "name"))) (EVar "clauses")))
(DTypeSig false "clauseSelfCallOrOther" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "clauseSelfCallOrOther" ((PVar "name") (PTuple (PVar "cn") (PVar "pats") (PVar "body") PWild)) (EBinOp "||" (EBinOp "/=" (EVar "cn") (EVar "name")) (EApp (EApp (EApp (EVar "unconditionalSelfCall") (EVar "name")) (EVar "pats")) (EVar "body"))))
(DTypeSig false "unconditionalSelfCall" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "unconditionalSelfCall" ((PVar "name") (PList) (PVar "body")) (EApp (EApp (EVar "isBareSelf") (EVar "name")) (EApp (EVar "stripWrap") (EVar "body"))))
(DFunDef false "unconditionalSelfCall" ((PVar "name") PWild (PVar "body")) (EApp (EApp (EVar "isHeadSelfApp") (EVar "name")) (EApp (EVar "stripWrap") (EVar "body"))))
(DTypeSig false "stripWrap" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "stripWrap" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "stripWrap") (EVar "e")))
(DFunDef false "stripWrap" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "stripWrap") (EVar "e")))
(DFunDef false "stripWrap" ((PVar "e")) (EVar "e"))
(DTypeSig false "isBareSelf" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isBareSelf" ((PVar "name") (PCon "EVar" (PVar "w"))) (EBinOp "==" (EVar "name") (EVar "w")))
(DFunDef false "isBareSelf" (PWild PWild) (EVar "False"))
(DTypeSig false "isHeadSelfApp" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isHeadSelfApp" ((PVar "name") (PCon "EApp" (PVar "f") (PVar "a"))) (EApp (EApp (EVar "isBareSelf") (EVar "name")) (EApp (EVar "appHead") (EApp (EVar "stripWrap") (EVar "f")))))
(DFunDef false "isHeadSelfApp" (PWild PWild) (EVar "False"))
(DTypeSig false "appHead" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "appHead" ((PVar "e")) (EMatch (EApp (EVar "stripWrap") (EVar "e")) (arm (PCon "EApp" (PVar "f") PWild) () (EApp (EVar "appHead") (EVar "f"))) (arm (PVar "x") () (EVar "x"))))
(DTypeSig false "selfShadowFinding" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Finding")))
(DFunDef false "selfShadowFinding" ((PTuple (PVar "name") (PVar "loc"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameSelfShadowExtern")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "top-level '")) (EApp (EVar "display") (EVar "name"))) (ELit (LString "' unconditionally calls itself with no base case — an infinite self-recursion, not a forward to a same-named extern/definition. Rename the binding (give it a distinct name) or add a terminating `match`/`if`/guard")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "allList" false) (mem "filterList" false) (mem "dedupBy" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "declLocList" false) (mem "ruleNameSelfShadowExtern" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameSelfShadowExtern")) (fa "summary" (ELit (LString "top-level binding unconditionally forwards to itself (`f s = f s`, `x = x`) — an infinite self-recursion, not a forward to a same-named extern (#266)"))) (fa "doc" (ELit (LString "A top-level binding that unconditionally forwards to itself (`f s = f s`, `x = x`) is an infinite recursion, usually an extern wrapper that forgot it shadows the extern it meant to call (#266).\n\nBefore:\n  strLen s = strLen s\nAfter:\n  call the extern under its real name"))) (fa "category" (EVar "Correctness")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleSelfShadowExtern")) (EVar "None")))
(DTypeSig false "ruleSelfShadowExtern" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleSelfShadowExtern" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EVar "selfShadowFindings") (EApp (EApp (EDictApp "flatMap") (EVar "selfShadowClauseL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog")))))
(DTypeSig false "selfShadowFindings" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "selfShadowFindings" ((PVar "clauses")) (EApp (EApp (EMethodRef "map") (EVar "selfShadowFinding")) (EApp (EApp (EVar "filterList") (EApp (EVar "allClausesSelfCall") (EVar "clauses"))) (EApp (EApp (EVar "dedupBy") (EVar "fst")) (EApp (EApp (EMethodRef "map") (EVar "clauseNameLoc")) (EVar "clauses"))))))
(DTypeSig false "selfShadowClauseL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "selfShadowClauseL" ((PTuple (PCon "DFunDef" PWild (PVar "name") (PVar "pats") (PVar "body") PWild PWild) (PVar "loc"))) (EListLit (ETuple (EVar "name") (EVar "pats") (EVar "body") (EVar "loc"))))
(DFunDef false "selfShadowClauseL" ((PTuple (PCon "DAttrib" PWild (PVar "d")) (PVar "loc"))) (EApp (EVar "selfShadowClauseL") (ETuple (EVar "d") (EVar "loc"))))
(DFunDef false "selfShadowClauseL" (PWild) (EListLit))
(DTypeSig false "clauseNameLoc" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "clauseNameLoc" ((PTuple (PVar "n") PWild PWild (PVar "l"))) (ETuple (EVar "n") (EVar "l")))
(DTypeSig false "allClausesSelfCall" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc")))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "allClausesSelfCall" ((PVar "clauses") (PTuple (PVar "name") PWild)) (EApp (EApp (EVar "allList") (EApp (EVar "clauseSelfCallOrOther") (EVar "name"))) (EVar "clauses")))
(DTypeSig false "clauseSelfCallOrOther" (TyFun (TyCon "String") (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Bool"))))
(DFunDef false "clauseSelfCallOrOther" ((PVar "name") (PTuple (PVar "cn") (PVar "pats") (PVar "body") PWild)) (EBinOp "||" (EBinOp "/=" (EVar "cn") (EVar "name")) (EApp (EApp (EApp (EVar "unconditionalSelfCall") (EVar "name")) (EVar "pats")) (EVar "body"))))
(DTypeSig false "unconditionalSelfCall" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "unconditionalSelfCall" ((PVar "name") (PList) (PVar "body")) (EApp (EApp (EVar "isBareSelf") (EVar "name")) (EApp (EVar "stripWrap") (EVar "body"))))
(DFunDef false "unconditionalSelfCall" ((PVar "name") PWild (PVar "body")) (EApp (EApp (EVar "isHeadSelfApp") (EVar "name")) (EApp (EVar "stripWrap") (EVar "body"))))
(DTypeSig false "stripWrap" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "stripWrap" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "stripWrap") (EVar "e")))
(DFunDef false "stripWrap" ((PCon "EAnnot" (PVar "e") PWild)) (EApp (EVar "stripWrap") (EVar "e")))
(DFunDef false "stripWrap" ((PVar "e")) (EVar "e"))
(DTypeSig false "isBareSelf" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isBareSelf" ((PVar "name") (PCon "EVar" (PVar "w"))) (EBinOp "==" (EVar "name") (EVar "w")))
(DFunDef false "isBareSelf" (PWild PWild) (EVar "False"))
(DTypeSig false "isHeadSelfApp" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "isHeadSelfApp" ((PVar "name") (PCon "EApp" (PVar "f") (PVar "a"))) (EApp (EApp (EVar "isBareSelf") (EVar "name")) (EApp (EVar "appHead") (EApp (EVar "stripWrap") (EVar "f")))))
(DFunDef false "isHeadSelfApp" (PWild PWild) (EVar "False"))
(DTypeSig false "appHead" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "appHead" ((PVar "e")) (EMatch (EApp (EVar "stripWrap") (EVar "e")) (arm (PCon "EApp" (PVar "f") PWild) () (EApp (EVar "appHead") (EVar "f"))) (arm (PVar "x") () (EVar "x"))))
(DTypeSig false "selfShadowFinding" (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "Finding")))
(DFunDef false "selfShadowFinding" ((PTuple (PVar "name") (PVar "loc"))) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameSelfShadowExtern")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "top-level '")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString "' unconditionally calls itself with no base case — an infinite self-recursion, not a forward to a same-named extern/definition. Rename the binding (give it a distinct name) or add a terminating `match`/`if`/guard")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
