# META
source_lines=211
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-orelse-staircase: a nested first-match probe staircase of `None`/`Err` fall-throughs. Prefer the lazy `orElseWith` / `findMap` (suggest-only).

import frontend.ast.{
  Loc(..),
  Pat(..),
  Arm(..),
  Expr(..),
  Decl(..),
  declBinderNames,
}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import support.util.{anyList, isEmptyL}
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
import tools.lint_shared.{
  ctorVarPassthru,
  declHeadHits,
  isEVarNamed,
  isNilPCon,
  matchScrutOf,
  mentionsVar,
  ruleNameOrElseStaircase,
  unwrapLoc,
}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameOrElseStaircase,
      summary =
        "first-match probe staircase (≥2 nested `None`/`Err` fallthrough re-probes, each success arm handing its payload straight back). Where the probes are pure and cheap, rewrite with the lazy `orElseWith` / `findMap` (suggest-only)",
      doc =
        "Two or more nested `None`/`Err` fall-through re-probes, each success arm handing its payload straight back, are a first-match search. Suggest-only.\n\n`orElse a b` takes VALUES, so every probe runs. Use the lazy forms for each probe after the first: `orElseWith a (_ => probe)` for `Option`, `optionOrElse (_ => probe) opt`, `resultOrElse (err => probe) res` for `Result`, or `findMap` when the probes are one function over a list.\n\nNo rewrite applies when a later probe is expensive, effectful, or the enclosing function's own recursion; a staircase whose later probe calls the enclosing function is not reported.\n\nBefore:\n  match probeA x\n    Some v => Some v\n    None => match probeB x\n      Some v => Some v\n      None => probeC x\nAfter:\n  orElseWith (probeA x) (_ => orElseWith (probeB x) (_ => probeC x))",
      category = Complexity,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = NotFixable,
      needs = [],
    }
    ruleOrElseStaircase
    None

-- Flag a first-match PROBE STAIRCASE: nested `match`es where every level tries a
-- fresh probe, hands that probe's own payload straight back on success, and falls
-- through to the next probe on failure:
--   Option:  match <probe> { Some v => v  (or `Some v`) ; None  => <next level> }
--   Result:  match <probe> { Ok   v => v  (or `Ok   v`) ; Err _ => <next level> }
-- Two or more such levels — a probe, at least one re-probe, then a fallback — is
-- the staircase `orElse` and `findMap` exist for.  A single level is a
-- `withDefault`, not a staircase, and does not fire.
-- Arm order is either way; the chain must be all-Option or all-Result.
--
-- This is the DUAL of rule-bind-chain-to-do: there the FAILURE arm is the verbatim
-- passthrough and the SUCCESS arm continues the chain; here the SUCCESS arm is the
-- verbatim passthrough and the FAILURE arm continues.  The two shapes are disjoint,
-- so one chain can never fire both rules.
--
-- The passthrough demand is what keeps the rule true rather than merely plausible.
-- A level whose success arm CONSUMES its payload (`Some (a, b) => f a b`) is a
-- heterogeneous probe chain: the levels do not share a result type, so `orElse`
-- does not even typecheck over them, and Medaka being strict, an eager rewrite
-- would run every probe rather than stopping at the first hit.  #2565 scopes those
-- out; requiring the identity success arm excludes them syntactically, with no type
-- environment (which the linter does not have).
--
-- Deliberately NOT matched: a fallthrough continuation reached through interspersed
-- `let`s (an `EBlock`), and an `Err e` failure arm that binds its payload — both are
-- rarer shapes whose rewrite is not the plain combinator.

-- one staircase level rooted at `e`; returns the failure-arm continuation.
orElseLevel : Bool -> Expr -> Option Expr
orElseLevel isResult e = match unwrapLoc e
  EMatch _ arms => match arms
    [a1, a2] => match orElseTry isResult a1 a2
      Some c => Some c
      None => orElseTry isResult a2 a1
    _ => None
  _ => None

-- (candidate success arm, candidate failure arm) → the failure continuation.
orElseTry : Bool -> Arm -> Arm -> Option Expr
orElseTry isResult (Arm okP okGs okBody) (Arm failP failGs failBody)
  | isEmptyL okGs
    && isEmptyL failGs
    && orElseOkPassthru isResult okP okBody
    && orElseFailPat isResult failP = Some failBody
  | otherwise = None

-- success arm hands the probe's payload straight back: `Some v => v` (unwrapping
-- staircase) or `Some v => Some v` (Option-returning staircase).
orElseOkPassthru : Bool -> Pat -> Expr -> Bool
orElseOkPassthru isResult p body =
  let ctor = if isResult then "Ok" else "Some"
  orElseBareVarArm ctor p body || ctorVarPassthru ctor p body

orElseBareVarArm : String -> Pat -> Expr -> Bool
orElseBareVarArm ctor (PCon c [PVar v _ _]) body =
  c == ctor && isEVarNamed v body
orElseBareVarArm _ _ _ = False

-- failure arm falls through WITHOUT inspecting the failure: `None` / `Err _`.
orElseFailPat : Bool -> Pat -> Bool
orElseFailPat isResult p =
  if isResult then orElseErrWildPat p else isNilPCon "None" p

orElseErrWildPat : Pat -> Bool
orElseErrWildPat (PCon "Err" [PWild]) = True
orElseErrWildPat _ = False

-- number of staircase levels rooted at `e` for the chosen monad, 0 if `e` is not
-- a level at all.
orElseDepth : Bool -> Expr -> Int
orElseDepth isResult e = match orElseLevel isResult e
  Some cont => 1 + orElseDepth isResult cont
  None => 0

-- off-chain sub-exprs of a staircase: every level's probe, plus the final fallback
-- the last failure arm lands on.  The fallthrough continuations are consumed by
-- the recursion, so a level of THIS staircase is never re-reported as its own head.
orElseOffChain : Bool -> Expr -> List Expr
orElseOffChain isResult e = match orElseLevel isResult e
  Some cont => matchScrutOf e :: orElseOffChain isResult cont
  None => [e]

-- A node is a staircase HEAD iff its depth (in whichever monad) is >= 2; the
-- chain is then consumed and only its off-chain parts are searched further.
-- Each head is paired with the monad it was read in (`True` = Result), because
-- the two monads have different rewrites and only this pick knows which one a
-- given head is.
orElsePick : Expr -> Option ((Bool, Expr), List Expr)
orElsePick e =
  let rd = orElseDepth True e
  let od = orElseDepth False e
  if rd >= 2 || od >= 2 then
    Some ((rd >= od, e), orElseOffChain (rd >= od) e)
  else
    None

ruleOrElseStaircase : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleOrElseStaircase _ _ _ _ _ = [OnDecl orElseAt]

orElseAt : Ctx -> Decl -> List Finding
orElseAt ctx d =
  map
    (orElseHeadFinding ctx.ctxSpan)
    (filter
      (orElseNotSelfRecursive (declBinderNames d))
      (declHeadHits orElsePick d))

-- A staircase whose later probe (or final fallback) calls the enclosing function
-- cannot be turned into value-taking `orElse` without eager recursion; with
-- `orElseWith` the call still has to stay behind the earlier probes, so the rule
-- stays silent rather than guess.  The first probe is not a later probe.
orElseNotSelfRecursive : List String -> (Bool, Expr) -> Bool
orElseNotSelfRecursive names (isResult, e) =
  let laterProbes = match orElseOffChain isResult e
    [] => []
    _ :: rest => rest
  not (anyList (n => anyList (mentionsVar n) laterProbes) names)

orElseHeadFinding : Option Loc -> (Bool, Expr) -> Finding
orElseHeadFinding declLoc (isResult, e) =
  orElseFinding isResult (orElseHeadLoc declLoc e)

-- the staircase's OWN location where the head carries one (the `ELoc` the
-- traversal reaches before its raw `EMatch`), else the enclosing decl's — a
-- staircase buried in a long function is not usefully reported at the decl head.
orElseHeadLoc : Option Loc -> Expr -> Option Loc
orElseHeadLoc _ (ELoc l _) = Some l
orElseHeadLoc declLoc _ = declLoc

-- The rewrite differs by monad, so the message does too.  `orElse`, `orElseWith`
-- and `findMap` come from `Alternative`, which `stdlib/core.mdk` implements for
-- `List` and `Option` only -- there is no `Alternative Result`, but `resultOrElse`
-- takes a lazy handler.  `orElse` itself takes values and is eager, so the
-- message recommends the lazy forms.
orElseFinding : Bool -> Option Loc -> Finding
orElseFinding isResult loc = Finding {
  rule = ruleNameOrElseStaircase,
  message = orElseMessage isResult,
  severity = SevWarning,
  loc = loc,
  fix = None,
}

orElseMessage : Bool -> String
orElseMessage True =
  "first-match probe staircase (≥2 `Err` fallthrough re-probes). There is no `Alternative Result`; if the probes are pure and cheap, chain them lazily with `resultOrElse (_ => probe)` -- never the value-taking `orElse`, which runs every probe. An expensive, effectful or self-recursive later probe disqualifies any rewrite"
orElseMessage False =
  "first-match probe staircase (≥2 `None` fallthrough re-probes). If the probes are pure and cheap, rewrite with the lazy `orElseWith a (_ => probe)` / `optionOrElse (_ => probe)` for each probe after the first, or `findMap` over a list -- never the value-taking `orElse`, which runs every probe. An expensive, effectful or self-recursive later probe disqualifies any rewrite"
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "Arm" true) (mem "Expr" true) (mem "Decl" true) (mem "declBinderNames" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "isEmptyL" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ctorVarPassthru" false) (mem "declHeadHits" false) (mem "isEVarNamed" false) (mem "isNilPCon" false) (mem "matchScrutOf" false) (mem "mentionsVar" false) (mem "ruleNameOrElseStaircase" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameOrElseStaircase")) (fa "summary" (ELit (LString "first-match probe staircase (≥2 nested `None`/`Err` fallthrough re-probes, each success arm handing its payload straight back). Where the probes are pure and cheap, rewrite with the lazy `orElseWith` / `findMap` (suggest-only)"))) (fa "doc" (ELit (LString "Two or more nested `None`/`Err` fall-through re-probes, each success arm handing its payload straight back, are a first-match search. Suggest-only.\n\n`orElse a b` takes VALUES, so every probe runs. Use the lazy forms for each probe after the first: `orElseWith a (_ => probe)` for `Option`, `optionOrElse (_ => probe) opt`, `resultOrElse (err => probe) res` for `Result`, or `findMap` when the probes are one function over a list.\n\nNo rewrite applies when a later probe is expensive, effectful, or the enclosing function's own recursion; a staircase whose later probe calls the enclosing function is not reported.\n\nBefore:\n  match probeA x\n    Some v => Some v\n    None => match probeB x\n      Some v => Some v\n      None => probeC x\nAfter:\n  orElseWith (probeA x) (_ => orElseWith (probeB x) (_ => probeC x))"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleOrElseStaircase")) (EVar "None")))
(DTypeSig false "orElseLevel" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "orElseLevel" ((PVar "isResult") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EMatch" PWild (PVar "arms")) () (EMatch (EVar "arms") (arm (PList (PVar "a1") (PVar "a2")) () (EMatch (EApp (EApp (EApp (EVar "orElseTry") (EVar "isResult")) (EVar "a1")) (EVar "a2")) (arm (PCon "Some" (PVar "c")) () (EApp (EVar "Some") (EVar "c"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "orElseTry") (EVar "isResult")) (EVar "a2")) (EVar "a1"))))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "orElseTry" (TyFun (TyCon "Bool") (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "orElseTry" ((PVar "isResult") (PCon "Arm" (PVar "okP") (PVar "okGs") (PVar "okBody")) (PCon "Arm" (PVar "failP") (PVar "failGs") (PVar "failBody"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "okGs")) (EApp (EVar "isEmptyL") (EVar "failGs"))) (EApp (EApp (EApp (EVar "orElseOkPassthru") (EVar "isResult")) (EVar "okP")) (EVar "okBody"))) (EApp (EApp (EVar "orElseFailPat") (EVar "isResult")) (EVar "failP"))) (EApp (EVar "Some") (EVar "failBody")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "orElseOkPassthru" (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "orElseOkPassthru" ((PVar "isResult") (PVar "p") (PVar "body")) (EBlock (DoLet false false (PVar "ctor") (EIf (EVar "isResult") (ELit (LString "Ok")) (ELit (LString "Some")))) (DoExpr (EBinOp "||" (EApp (EApp (EApp (EVar "orElseBareVarArm") (EVar "ctor")) (EVar "p")) (EVar "body")) (EApp (EApp (EApp (EVar "ctorVarPassthru") (EVar "ctor")) (EVar "p")) (EVar "body"))))))
(DTypeSig false "orElseBareVarArm" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "orElseBareVarArm" ((PVar "ctor") (PCon "PCon" (PVar "c") (PList (PCon "PVar" (PVar "v") PWild PWild))) (PVar "body")) (EBinOp "&&" (EBinOp "==" (EVar "c") (EVar "ctor")) (EApp (EApp (EVar "isEVarNamed") (EVar "v")) (EVar "body"))))
(DFunDef false "orElseBareVarArm" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "orElseFailPat" (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "orElseFailPat" ((PVar "isResult") (PVar "p")) (EIf (EVar "isResult") (EApp (EVar "orElseErrWildPat") (EVar "p")) (EApp (EApp (EVar "isNilPCon") (ELit (LString "None"))) (EVar "p"))))
(DTypeSig false "orElseErrWildPat" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "orElseErrWildPat" ((PCon "PCon" (PLit (LString "Err")) (PList (PCon "PWild")))) (EVar "True"))
(DFunDef false "orElseErrWildPat" (PWild) (EVar "False"))
(DTypeSig false "orElseDepth" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyCon "Int"))))
(DFunDef false "orElseDepth" ((PVar "isResult") (PVar "e")) (EMatch (EApp (EApp (EVar "orElseLevel") (EVar "isResult")) (EVar "e")) (arm (PCon "Some" (PVar "cont")) () (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "orElseDepth") (EVar "isResult")) (EVar "cont")))) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig false "orElseOffChain" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "orElseOffChain" ((PVar "isResult") (PVar "e")) (EMatch (EApp (EApp (EVar "orElseLevel") (EVar "isResult")) (EVar "e")) (arm (PCon "Some" (PVar "cont")) () (EBinOp "::" (EApp (EVar "matchScrutOf") (EVar "e")) (EApp (EApp (EVar "orElseOffChain") (EVar "isResult")) (EVar "cont")))) (arm (PCon "None") () (EListLit (EVar "e")))))
(DTypeSig false "orElsePick" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyTuple (TyCon "Bool") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "orElsePick" ((PVar "e")) (EBlock (DoLet false false (PVar "rd") (EApp (EApp (EVar "orElseDepth") (EVar "True")) (EVar "e"))) (DoLet false false (PVar "od") (EApp (EApp (EVar "orElseDepth") (EVar "False")) (EVar "e"))) (DoExpr (EIf (EBinOp "||" (EBinOp ">=" (EVar "rd") (ELit (LInt 2))) (EBinOp ">=" (EVar "od") (ELit (LInt 2)))) (EApp (EVar "Some") (ETuple (ETuple (EBinOp ">=" (EVar "rd") (EVar "od")) (EVar "e")) (EApp (EApp (EVar "orElseOffChain") (EBinOp ">=" (EVar "rd") (EVar "od"))) (EVar "e")))) (EVar "None")))))
(DTypeSig false "ruleOrElseStaircase" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleOrElseStaircase" (PWild PWild PWild PWild PWild) (EListLit (EApp (EVar "OnDecl") (EVar "orElseAt"))))
(DTypeSig false "orElseAt" (TyFun (TyCon "Ctx") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "orElseAt" ((PVar "ctx") (PVar "d")) (EApp (EApp (EVar "map") (EApp (EVar "orElseHeadFinding") (EFieldAccess (EVar "ctx") "ctxSpan"))) (EApp (EApp (EVar "filter") (EApp (EVar "orElseNotSelfRecursive") (EApp (EVar "declBinderNames") (EVar "d")))) (EApp (EApp (EVar "declHeadHits") (EVar "orElsePick")) (EVar "d")))))
(DTypeSig false "orElseNotSelfRecursive" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "Bool") (TyCon "Expr")) (TyCon "Bool"))))
(DFunDef false "orElseNotSelfRecursive" ((PVar "names") (PTuple (PVar "isResult") (PVar "e"))) (EBlock (DoLet false false (PVar "laterProbes") (EMatch (EApp (EApp (EVar "orElseOffChain") (EVar "isResult")) (EVar "e")) (arm (PList) () (EListLit)) (arm (PCons PWild (PVar "rest")) () (EVar "rest")))) (DoExpr (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "n")) (EApp (EApp (EVar "anyList") (EApp (EVar "mentionsVar") (EVar "n"))) (EVar "laterProbes")))) (EVar "names"))))))
(DTypeSig false "orElseHeadFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "Bool") (TyCon "Expr")) (TyCon "Finding"))))
(DFunDef false "orElseHeadFinding" ((PVar "declLoc") (PTuple (PVar "isResult") (PVar "e"))) (EApp (EApp (EVar "orElseFinding") (EVar "isResult")) (EApp (EApp (EVar "orElseHeadLoc") (EVar "declLoc")) (EVar "e"))))
(DTypeSig false "orElseHeadLoc" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "orElseHeadLoc" (PWild (PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "orElseHeadLoc" ((PVar "declLoc") PWild) (EVar "declLoc"))
(DTypeSig false "orElseFinding" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Finding"))))
(DFunDef false "orElseFinding" ((PVar "isResult") (PVar "loc")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameOrElseStaircase")) (fa "message" (EApp (EVar "orElseMessage") (EVar "isResult"))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "orElseMessage" (TyFun (TyCon "Bool") (TyCon "String")))
(DFunDef false "orElseMessage" ((PCon "True")) (ELit (LString "first-match probe staircase (≥2 `Err` fallthrough re-probes). There is no `Alternative Result`; if the probes are pure and cheap, chain them lazily with `resultOrElse (_ => probe)` -- never the value-taking `orElse`, which runs every probe. An expensive, effectful or self-recursive later probe disqualifies any rewrite")))
(DFunDef false "orElseMessage" ((PCon "False")) (ELit (LString "first-match probe staircase (≥2 `None` fallthrough re-probes). If the probes are pure and cheap, rewrite with the lazy `orElseWith a (_ => probe)` / `optionOrElse (_ => probe)` for each probe after the first, or `findMap` over a list -- never the value-taking `orElse`, which runs every probe. An expensive, effectful or self-recursive later probe disqualifies any rewrite")))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "Arm" true) (mem "Expr" true) (mem "Decl" true) (mem "declBinderNames" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "isEmptyL" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "ctorVarPassthru" false) (mem "declHeadHits" false) (mem "isEVarNamed" false) (mem "isNilPCon" false) (mem "matchScrutOf" false) (mem "mentionsVar" false) (mem "ruleNameOrElseStaircase" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameOrElseStaircase")) (fa "summary" (ELit (LString "first-match probe staircase (≥2 nested `None`/`Err` fallthrough re-probes, each success arm handing its payload straight back). Where the probes are pure and cheap, rewrite with the lazy `orElseWith` / `findMap` (suggest-only)"))) (fa "doc" (ELit (LString "Two or more nested `None`/`Err` fall-through re-probes, each success arm handing its payload straight back, are a first-match search. Suggest-only.\n\n`orElse a b` takes VALUES, so every probe runs. Use the lazy forms for each probe after the first: `orElseWith a (_ => probe)` for `Option`, `optionOrElse (_ => probe) opt`, `resultOrElse (err => probe) res` for `Result`, or `findMap` when the probes are one function over a list.\n\nNo rewrite applies when a later probe is expensive, effectful, or the enclosing function's own recursion; a staircase whose later probe calls the enclosing function is not reported.\n\nBefore:\n  match probeA x\n    Some v => Some v\n    None => match probeB x\n      Some v => Some v\n      None => probeC x\nAfter:\n  orElseWith (probeA x) (_ => orElseWith (probeB x) (_ => probeC x))"))) (fa "category" (EVar "Complexity")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "NotFixable")) (fa "needs" (EListLit))))) (EVar "ruleOrElseStaircase")) (EVar "None")))
(DTypeSig false "orElseLevel" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "orElseLevel" ((PVar "isResult") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EMatch" PWild (PVar "arms")) () (EMatch (EVar "arms") (arm (PList (PVar "a1") (PVar "a2")) () (EMatch (EApp (EApp (EApp (EVar "orElseTry") (EVar "isResult")) (EVar "a1")) (EVar "a2")) (arm (PCon "Some" (PVar "c")) () (EApp (EVar "Some") (EVar "c"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "orElseTry") (EVar "isResult")) (EVar "a2")) (EVar "a1"))))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig false "orElseTry" (TyFun (TyCon "Bool") (TyFun (TyCon "Arm") (TyFun (TyCon "Arm") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "orElseTry" ((PVar "isResult") (PCon "Arm" (PVar "okP") (PVar "okGs") (PVar "okBody")) (PCon "Arm" (PVar "failP") (PVar "failGs") (PVar "failBody"))) (EIf (EBinOp "&&" (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmptyL") (EVar "okGs")) (EApp (EVar "isEmptyL") (EVar "failGs"))) (EApp (EApp (EApp (EVar "orElseOkPassthru") (EVar "isResult")) (EVar "okP")) (EVar "okBody"))) (EApp (EApp (EVar "orElseFailPat") (EVar "isResult")) (EVar "failP"))) (EApp (EVar "Some") (EVar "failBody")) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "orElseOkPassthru" (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "orElseOkPassthru" ((PVar "isResult") (PVar "p") (PVar "body")) (EBlock (DoLet false false (PVar "ctor") (EIf (EVar "isResult") (ELit (LString "Ok")) (ELit (LString "Some")))) (DoExpr (EBinOp "||" (EApp (EApp (EApp (EVar "orElseBareVarArm") (EVar "ctor")) (EVar "p")) (EVar "body")) (EApp (EApp (EApp (EVar "ctorVarPassthru") (EVar "ctor")) (EVar "p")) (EVar "body"))))))
(DTypeSig false "orElseBareVarArm" (TyFun (TyCon "String") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "orElseBareVarArm" ((PVar "ctor") (PCon "PCon" (PVar "c") (PList (PCon "PVar" (PVar "v") PWild PWild))) (PVar "body")) (EBinOp "&&" (EBinOp "==" (EVar "c") (EVar "ctor")) (EApp (EApp (EVar "isEVarNamed") (EVar "v")) (EVar "body"))))
(DFunDef false "orElseBareVarArm" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "orElseFailPat" (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "orElseFailPat" ((PVar "isResult") (PVar "p")) (EIf (EVar "isResult") (EApp (EVar "orElseErrWildPat") (EVar "p")) (EApp (EApp (EVar "isNilPCon") (ELit (LString "None"))) (EVar "p"))))
(DTypeSig false "orElseErrWildPat" (TyFun (TyCon "Pat") (TyCon "Bool")))
(DFunDef false "orElseErrWildPat" ((PCon "PCon" (PLit (LString "Err")) (PList (PCon "PWild")))) (EVar "True"))
(DFunDef false "orElseErrWildPat" (PWild) (EVar "False"))
(DTypeSig false "orElseDepth" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyCon "Int"))))
(DFunDef false "orElseDepth" ((PVar "isResult") (PVar "e")) (EMatch (EApp (EApp (EVar "orElseLevel") (EVar "isResult")) (EVar "e")) (arm (PCon "Some" (PVar "cont")) () (EBinOp "+" (ELit (LInt 1)) (EApp (EApp (EVar "orElseDepth") (EVar "isResult")) (EVar "cont")))) (arm (PCon "None") () (ELit (LInt 0)))))
(DTypeSig false "orElseOffChain" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr")))))
(DFunDef false "orElseOffChain" ((PVar "isResult") (PVar "e")) (EMatch (EApp (EApp (EVar "orElseLevel") (EVar "isResult")) (EVar "e")) (arm (PCon "Some" (PVar "cont")) () (EBinOp "::" (EApp (EVar "matchScrutOf") (EVar "e")) (EApp (EApp (EVar "orElseOffChain") (EVar "isResult")) (EVar "cont")))) (arm (PCon "None") () (EListLit (EVar "e")))))
(DTypeSig false "orElsePick" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyTuple (TyCon "Bool") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "orElsePick" ((PVar "e")) (EBlock (DoLet false false (PVar "rd") (EApp (EApp (EVar "orElseDepth") (EVar "True")) (EVar "e"))) (DoLet false false (PVar "od") (EApp (EApp (EVar "orElseDepth") (EVar "False")) (EVar "e"))) (DoExpr (EIf (EBinOp "||" (EBinOp ">=" (EVar "rd") (ELit (LInt 2))) (EBinOp ">=" (EVar "od") (ELit (LInt 2)))) (EApp (EVar "Some") (ETuple (ETuple (EBinOp ">=" (EVar "rd") (EVar "od")) (EVar "e")) (EApp (EApp (EVar "orElseOffChain") (EBinOp ">=" (EVar "rd") (EVar "od"))) (EVar "e")))) (EVar "None")))))
(DTypeSig false "ruleOrElseStaircase" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleOrElseStaircase" (PWild PWild PWild PWild PWild) (EListLit (EApp (EVar "OnDecl") (EVar "orElseAt"))))
(DTypeSig false "orElseAt" (TyFun (TyCon "Ctx") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "orElseAt" ((PVar "ctx") (PVar "d")) (EApp (EApp (EMethodRef "map") (EApp (EVar "orElseHeadFinding") (EFieldAccess (EVar "ctx") "ctxSpan"))) (EApp (EApp (EMethodRef "filter") (EApp (EVar "orElseNotSelfRecursive") (EApp (EVar "declBinderNames") (EVar "d")))) (EApp (EApp (EVar "declHeadHits") (EVar "orElsePick")) (EVar "d")))))
(DTypeSig false "orElseNotSelfRecursive" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyTuple (TyCon "Bool") (TyCon "Expr")) (TyCon "Bool"))))
(DFunDef false "orElseNotSelfRecursive" ((PVar "names") (PTuple (PVar "isResult") (PVar "e"))) (EBlock (DoLet false false (PVar "laterProbes") (EMatch (EApp (EApp (EVar "orElseOffChain") (EVar "isResult")) (EVar "e")) (arm (PList) () (EListLit)) (arm (PCons PWild (PVar "rest")) () (EVar "rest")))) (DoExpr (EApp (EVar "not") (EApp (EApp (EVar "anyList") (ELam ((PVar "n")) (EApp (EApp (EVar "anyList") (EApp (EVar "mentionsVar") (EVar "n"))) (EVar "laterProbes")))) (EVar "names"))))))
(DTypeSig false "orElseHeadFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyTuple (TyCon "Bool") (TyCon "Expr")) (TyCon "Finding"))))
(DFunDef false "orElseHeadFinding" ((PVar "declLoc") (PTuple (PVar "isResult") (PVar "e"))) (EApp (EApp (EVar "orElseFinding") (EVar "isResult")) (EApp (EApp (EVar "orElseHeadLoc") (EVar "declLoc")) (EVar "e"))))
(DTypeSig false "orElseHeadLoc" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "orElseHeadLoc" (PWild (PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "orElseHeadLoc" ((PVar "declLoc") PWild) (EVar "declLoc"))
(DTypeSig false "orElseFinding" (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Finding"))))
(DFunDef false "orElseFinding" ((PVar "isResult") (PVar "loc")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameOrElseStaircase")) (fa "message" (EApp (EVar "orElseMessage") (EVar "isResult"))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "None")))))
(DTypeSig false "orElseMessage" (TyFun (TyCon "Bool") (TyCon "String")))
(DFunDef false "orElseMessage" ((PCon "True")) (ELit (LString "first-match probe staircase (≥2 `Err` fallthrough re-probes). There is no `Alternative Result`; if the probes are pure and cheap, chain them lazily with `resultOrElse (_ => probe)` -- never the value-taking `orElse`, which runs every probe. An expensive, effectful or self-recursive later probe disqualifies any rewrite")))
(DFunDef false "orElseMessage" ((PCon "False")) (ELit (LString "first-match probe staircase (≥2 `None` fallthrough re-probes). If the probes are pure and cheap, rewrite with the lazy `orElseWith a (_ => probe)` / `optionOrElse (_ => probe)` for each probe after the first, or `findMap` over a list -- never the value-taking `orElse`, which runs every probe. An expensive, effectful or self-recursive later probe disqualifies any rewrite")))
