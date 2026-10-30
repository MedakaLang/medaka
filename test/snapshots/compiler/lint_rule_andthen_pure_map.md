# META
source_lines=189
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-andthen-pure-map: a monadic bind whose continuation only wraps a pure transformation (`andThen m (x => pure body)`). Prefer `map`.

import frontend.ast.{noBinderId, Loc(..), Pat(..), Expr(..), Decl(..)}
import frontend.ast_walk.{ExprKind(..)}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
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
  Visitor(..),
  mkVisitorRule,
}
import tools.lint_shared.{
  andThenEtaFn,
  rebinds,
  childExprs,
  isEVarNamed,
  replaceNodeFix,
  ruleNameAndThenPureMap,
  unwrapLoc,
  usesPreludeName,
}

export
rule : Rule
rule =
  mkVisitorRule
    RuleMeta {
      name = ruleNameAndThenPureMap,
      summary =
        "monadic bind whose continuation just wraps a pure transformation (`andThen m (x => pure body)`). Prefer `map` (functor law: m >>= (pure . f) ≡ fmap f m)",
      doc =
        "A monadic bind whose continuation only wraps a pure transformation in `pure` is `map`, by the functor law `m >>= (pure . f) == fmap f m`.\n\nBefore:\n  andThen m (x => pure (f x))\nAfter:\n  map f m",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [NeedsScopes, NeedsStdlibIndex],
    }
    ruleAndThenPureMap
    None

-- `andThen m (x => pure body)` re-wraps a PURE transformation of `m`'s result
-- back into the monad — exactly the functor law `m >>= (pure . f) ≡ fmap f m`.
-- In Medaka the bind is `andThen`, the wrap is `pure`, and the functor map is
-- `map`, so the idiom collapses to `map (x => body) m`.  When `body` is exactly
-- `f x` (x as `f`'s sole final argument, `f` not mentioning x) it eta-reduces
-- further to `map f m`.
--
-- SOUNDNESS: `Thenable m requires Applicative m`, `Applicative f requires
-- Mappable f` (stdlib/core.mdk), so ANY type with `andThen`/`pure` necessarily
-- has a `map` instance — the rewrite always has a `map` to resolve to.
--
-- CONSERVATISM (a false positive here CORRUPTS code):
--   * the continuation must be a SINGLE-param, plain-`PVar`, guard-free lambda
--     `(x => …)` (an `ELam [PVar x] body`; multi-param / destructuring /
--     `function` forms skip).
--   * the lambda body must be EXACTLY `pure <expr>` — a single application of the
--     bare name `pure` to one argument (an over-applied `pure a b` skips).
--   * the lambda param `x` must occur at most once in `<expr>` (so `x => pure
--     (g x x)` — "x used twice" — is left alone; the general rewrite would still
--     be sound but we stay conservative and, for the eta case, linear).
-- The check walks the WHOLE decl expression tree (the bind can nest anywhere) —
-- including impl-method bodies; the fix rebuilds the tree converting every
-- eligible bind to a `map` application, bottom-up.

-- occurrences of the variable name `x` in `e` (conservative: counts every EVar
-- leaf; a nested binder RE-BINDING x only OVER-counts → since we only rewrite
-- when the count is ≤ 1, over-counting is always SAFE — it can only suppress).
countVar : String -> Expr -> Int
countVar x e = match unwrapLoc e
  EVar w => if w == x then 1 else 0
  e2 => countVarList x (childExprs e2)

countVarList : String -> List Expr -> Int
countVarList _ [] = 0
countVarList x (e :: es) = countVar x e + countVarList x es

-- build the `map …` replacement for `andThen m (x => pure arg)`: eta-reduce to
-- `map f m` when `arg` is `f x`, else `map (x => arg) m`.
buildAndThenMap : String -> Expr -> Expr -> Expr
buildAndThenMap x arg m = match andThenEtaFn x arg
  Some f => EApp (EApp (EVar "map") f) m
  None =>
    EApp (EApp (EVar "map") (ELam [PVar x (Loc "" 0 0 0 0) noBinderId] arg)) m

-- `andThen m (x => pure ARG)` with x occurring ≤ 1× in ARG → Some (the rewritten
-- `map …` expression); anything else → None.
andThenPureMapOf : Expr -> Option Expr
andThenPureMapOf e = match unwrapLoc e
  EApp inner cont => andThenPureMapApp (unwrapLoc inner) cont
  _ => None

andThenPureMapApp : Expr -> Expr -> Option Expr
andThenPureMapApp (EApp hd m) cont
  | isEVarNamed "andThen" hd = andThenPureMapCont m (unwrapLoc cont)
andThenPureMapApp _ _ = None

andThenPureMapCont : Expr -> Expr -> Option Expr
andThenPureMapCont m (ELam [PVar x _ _] body) =
  andThenPureMapBody m x (unwrapLoc body)
andThenPureMapCont _ _ = None

andThenPureMapBody : Expr -> String -> Expr -> Option Expr
andThenPureMapBody m x (EApp pureHd arg)
  | isEVarNamed "pure" pureHd && countVar x arg <= 1 =
    Some (buildAndThenMap x arg m)
andThenPureMapBody _ _ _ = None

-- ── check ─────────────────────────────────────────────────────────────────────
-- The detector matches the raw `EApp`, never an `ELoc` wrapper, so a
-- location-wrapped bind is counted once.
ruleAndThenPureMap : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Visitor
ruleAndThenPureMap idx _ facts _ _ =
  [OnExpr [KApp] (andThenPureMapAt idx facts)]

andThenPureMapAt : StdlibIndex -> FileFacts -> Ctx -> Expr -> List Finding
andThenPureMapAt idx facts ctx e = match andThenPureMapOf e
  Some rewritten => [
    andThenPureMapFinding
      ctx.ctxDeclLoc
      rewritten
      (andThenPureMapFix idx facts ctx e rewritten),
  ]
  None => []

andThenPureMapFinding : Option Loc -> Expr -> Option Fix -> Finding
andThenPureMapFinding loc rewritten fix = Finding {
  rule = ruleNameAndThenPureMap,
  message =
    "monadic bind wraps a pure transformation of its result — rewrite as '"
      ++ exprToString rewritten
      ++ "'",
  severity = SevWarning,
  loc = loc,
  fix = fix,
}

-- ── autofix ───────────────────────────────────────────────────────────────────
-- The fix replaces the bind's own span.  It is withheld where the bind's `andThen`
-- or `pure` is a file binding (the call is then not the prelude's), and where the
-- file binds `map`: the replacement calls `map`, which such a binding would capture.
andThenPureMapFix : StdlibIndex ->
  FileFacts ->
  Ctx ->
  Expr ->
  Expr ->
  Option Fix
andThenPureMapFix idx facts ctx e rewritten =
  if andThenPureMapUsesPrelude idx facts e
    && not (rebinds idx facts ctx "map") then
    replaceNodeFix Safe "rewrite the bind as a map" ctx e rewritten
  else
    None

andThenPureMapUsesPrelude : StdlibIndex -> FileFacts -> Expr -> Bool
andThenPureMapUsesPrelude idx facts e = match andThenPureHeads e
  Some (andHd, pureHd) =>
    usesPreludeName idx facts andHd && usesPreludeName idx facts pureHd
  None => False

-- The `andThen` head and the `pure` head of a bind `andThen m (x => pure …)`, the
-- two names the rewrite consumes.  The shape is the one `andThenPureMapOf` matched.
andThenPureHeads : Expr -> Option (Expr, Expr)
andThenPureHeads e = match unwrapLoc e
  EApp inner cont => match (unwrapLoc inner, unwrapLoc cont)
    (EApp andHd _, ELam [PVar _ _ _] body) => match unwrapLoc body
      EApp pureHd _ => Some (andHd, pureHd)
      _ => None
    _ => None
  _ => None
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "noBinderId" false) (mem "Loc" true) (mem "Pat" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "andThenEtaFn" false) (mem "rebinds" false) (mem "childExprs" false) (mem "isEVarNamed" false) (mem "replaceNodeFix" false) (mem "ruleNameAndThenPureMap" false) (mem "unwrapLoc" false) (mem "usesPreludeName" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameAndThenPureMap")) (fa "summary" (ELit (LString "monadic bind whose continuation just wraps a pure transformation (`andThen m (x => pure body)`). Prefer `map` (functor law: m >>= (pure . f) ≡ fmap f m)"))) (fa "doc" (ELit (LString "A monadic bind whose continuation only wraps a pure transformation in `pure` is `map`, by the functor law `m >>= (pure . f) == fmap f m`.\n\nBefore:\n  andThen m (x => pure (f x))\nAfter:\n  map f m"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsStdlibIndex")))))) (EVar "ruleAndThenPureMap")) (EVar "None")))
(DTypeSig false "countVar" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Int"))))
(DFunDef false "countVar" ((PVar "x") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "w")) () (EIf (EBinOp "==" (EVar "w") (EVar "x")) (ELit (LInt 1)) (ELit (LInt 0)))) (arm (PVar "e2") () (EApp (EApp (EVar "countVarList") (EVar "x")) (EApp (EVar "childExprs") (EVar "e2"))))))
(DTypeSig false "countVarList" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Int"))))
(DFunDef false "countVarList" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "countVarList" ((PVar "x") (PCons (PVar "e") (PVar "es"))) (EBinOp "+" (EApp (EApp (EVar "countVar") (EVar "x")) (EVar "e")) (EApp (EApp (EVar "countVarList") (EVar "x")) (EVar "es"))))
(DTypeSig false "buildAndThenMap" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "buildAndThenMap" ((PVar "x") (PVar "arg") (PVar "m")) (EMatch (EApp (EApp (EVar "andThenEtaFn") (EVar "x")) (EVar "arg")) (arm (PCon "Some" (PVar "f")) () (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "map")))) (EVar "f"))) (EVar "m"))) (arm (PCon "None") () (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "map")))) (EApp (EApp (EVar "ELam") (EListLit (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")))) (EVar "arg")))) (EVar "m")))))
(DTypeSig false "andThenPureMapOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "andThenPureMapOf" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "inner") (PVar "cont")) () (EApp (EApp (EVar "andThenPureMapApp") (EApp (EVar "unwrapLoc") (EVar "inner"))) (EVar "cont"))) (arm PWild () (EVar "None"))))
(DTypeSig false "andThenPureMapApp" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "andThenPureMapApp" ((PCon "EApp" (PVar "hd") (PVar "m")) (PVar "cont")) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "andThen"))) (EVar "hd")) (EApp (EApp (EVar "andThenPureMapCont") (EVar "m")) (EApp (EVar "unwrapLoc") (EVar "cont"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "andThenPureMapApp" (PWild PWild) (EVar "None"))
(DTypeSig false "andThenPureMapCont" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "andThenPureMapCont" ((PVar "m") (PCon "ELam" (PList (PCon "PVar" (PVar "x") PWild PWild)) (PVar "body"))) (EApp (EApp (EApp (EVar "andThenPureMapBody") (EVar "m")) (EVar "x")) (EApp (EVar "unwrapLoc") (EVar "body"))))
(DFunDef false "andThenPureMapCont" (PWild PWild) (EVar "None"))
(DTypeSig false "andThenPureMapBody" (TyFun (TyCon "Expr") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "andThenPureMapBody" ((PVar "m") (PVar "x") (PCon "EApp" (PVar "pureHd") (PVar "arg"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (ELit (LString "pure"))) (EVar "pureHd")) (EBinOp "<=" (EApp (EApp (EVar "countVar") (EVar "x")) (EVar "arg")) (ELit (LInt 1)))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "buildAndThenMap") (EVar "x")) (EVar "arg")) (EVar "m"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "andThenPureMapBody" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "ruleAndThenPureMap" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleAndThenPureMap" ((PVar "idx") PWild (PVar "facts") PWild PWild) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KApp"))) (EApp (EApp (EVar "andThenPureMapAt") (EVar "idx")) (EVar "facts")))))
(DTypeSig false "andThenPureMapAt" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "andThenPureMapAt" ((PVar "idx") (PVar "facts") (PVar "ctx") (PVar "e")) (EMatch (EApp (EVar "andThenPureMapOf") (EVar "e")) (arm (PCon "Some" (PVar "rewritten")) () (EListLit (EApp (EApp (EApp (EVar "andThenPureMapFinding") (EFieldAccess (EVar "ctx") "ctxDeclLoc")) (EVar "rewritten")) (EApp (EApp (EApp (EApp (EApp (EVar "andThenPureMapFix") (EVar "idx")) (EVar "facts")) (EVar "ctx")) (EVar "e")) (EVar "rewritten"))))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "andThenPureMapFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "andThenPureMapFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameAndThenPureMap")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "monadic bind wraps a pure transformation of its result — rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "andThenPureMapFix" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix"))))))))
(DFunDef false "andThenPureMapFix" ((PVar "idx") (PVar "facts") (PVar "ctx") (PVar "e") (PVar "rewritten")) (EIf (EBinOp "&&" (EApp (EApp (EApp (EVar "andThenPureMapUsesPrelude") (EVar "idx")) (EVar "facts")) (EVar "e")) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "rebinds") (EVar "idx")) (EVar "facts")) (EVar "ctx")) (ELit (LString "map"))))) (EApp (EApp (EApp (EApp (EApp (EVar "replaceNodeFix") (EVar "Safe")) (ELit (LString "rewrite the bind as a map"))) (EVar "ctx")) (EVar "e")) (EVar "rewritten")) (EVar "None")))
(DTypeSig false "andThenPureMapUsesPrelude" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "andThenPureMapUsesPrelude" ((PVar "idx") (PVar "facts") (PVar "e")) (EMatch (EApp (EVar "andThenPureHeads") (EVar "e")) (arm (PCon "Some" (PTuple (PVar "andHd") (PVar "pureHd"))) () (EBinOp "&&" (EApp (EApp (EApp (EVar "usesPreludeName") (EVar "idx")) (EVar "facts")) (EVar "andHd")) (EApp (EApp (EApp (EVar "usesPreludeName") (EVar "idx")) (EVar "facts")) (EVar "pureHd")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "andThenPureHeads" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "andThenPureHeads" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "inner") (PVar "cont")) () (EMatch (ETuple (EApp (EVar "unwrapLoc") (EVar "inner")) (EApp (EVar "unwrapLoc") (EVar "cont"))) (arm (PTuple (PCon "EApp" (PVar "andHd") PWild) (PCon "ELam" (PList (PCon "PVar" PWild PWild PWild)) (PVar "body"))) () (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EApp" (PVar "pureHd") PWild) () (EApp (EVar "Some") (ETuple (EVar "andHd") (EVar "pureHd")))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "noBinderId" false) (mem "Loc" true) (mem "Pat" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "ExprKind" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Applicability" true) (mem "Category" true) (mem "Ctx" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fix" false) (mem "Fixability" true) (mem "Need" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "Visitor" true) (mem "mkVisitorRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "andThenEtaFn" false) (mem "rebinds" false) (mem "childExprs" false) (mem "isEVarNamed" false) (mem "replaceNodeFix" false) (mem "ruleNameAndThenPureMap" false) (mem "unwrapLoc" false) (mem "usesPreludeName" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkVisitorRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameAndThenPureMap")) (fa "summary" (ELit (LString "monadic bind whose continuation just wraps a pure transformation (`andThen m (x => pure body)`). Prefer `map` (functor law: m >>= (pure . f) ≡ fmap f m)"))) (fa "doc" (ELit (LString "A monadic bind whose continuation only wraps a pure transformation in `pure` is `map`, by the functor law `m >>= (pure . f) == fmap f m`.\n\nBefore:\n  andThen m (x => pure (f x))\nAfter:\n  map f m"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit (EVar "NeedsScopes") (EVar "NeedsStdlibIndex")))))) (EVar "ruleAndThenPureMap")) (EVar "None")))
(DTypeSig false "countVar" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Int"))))
(DFunDef false "countVar" ((PVar "x") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EVar" (PVar "w")) () (EIf (EBinOp "==" (EVar "w") (EVar "x")) (ELit (LInt 1)) (ELit (LInt 0)))) (arm (PVar "e2") () (EApp (EApp (EVar "countVarList") (EVar "x")) (EApp (EVar "childExprs") (EVar "e2"))))))
(DTypeSig false "countVarList" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Int"))))
(DFunDef false "countVarList" (PWild (PList)) (ELit (LInt 0)))
(DFunDef false "countVarList" ((PVar "x") (PCons (PVar "e") (PVar "es"))) (EBinOp "+" (EApp (EApp (EVar "countVar") (EVar "x")) (EVar "e")) (EApp (EApp (EVar "countVarList") (EVar "x")) (EVar "es"))))
(DTypeSig false "buildAndThenMap" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "buildAndThenMap" ((PVar "x") (PVar "arg") (PVar "m")) (EMatch (EApp (EApp (EVar "andThenEtaFn") (EVar "x")) (EVar "arg")) (arm (PCon "Some" (PVar "f")) () (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "map")))) (EVar "f"))) (EVar "m"))) (arm (PCon "None") () (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "EApp") (EApp (EVar "EVar") (ELit (LString "map")))) (EApp (EApp (EVar "ELam") (EListLit (EApp (EApp (EApp (EVar "PVar") (EVar "x")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0)))) (EVar "noBinderId")))) (EVar "arg")))) (EVar "m")))))
(DTypeSig false "andThenPureMapOf" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))
(DFunDef false "andThenPureMapOf" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "inner") (PVar "cont")) () (EApp (EApp (EVar "andThenPureMapApp") (EApp (EVar "unwrapLoc") (EVar "inner"))) (EVar "cont"))) (arm PWild () (EVar "None"))))
(DTypeSig false "andThenPureMapApp" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "andThenPureMapApp" ((PCon "EApp" (PVar "hd") (PVar "m")) (PVar "cont")) (EIf (EApp (EApp (EVar "isEVarNamed") (ELit (LString "andThen"))) (EVar "hd")) (EApp (EApp (EVar "andThenPureMapCont") (EVar "m")) (EApp (EVar "unwrapLoc") (EVar "cont"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "andThenPureMapApp" (PWild PWild) (EVar "None"))
(DTypeSig false "andThenPureMapCont" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr")))))
(DFunDef false "andThenPureMapCont" ((PVar "m") (PCon "ELam" (PList (PCon "PVar" (PVar "x") PWild PWild)) (PVar "body"))) (EApp (EApp (EApp (EVar "andThenPureMapBody") (EVar "m")) (EVar "x")) (EApp (EVar "unwrapLoc") (EVar "body"))))
(DFunDef false "andThenPureMapCont" (PWild PWild) (EVar "None"))
(DTypeSig false "andThenPureMapBody" (TyFun (TyCon "Expr") (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Expr"))))))
(DFunDef false "andThenPureMapBody" ((PVar "m") (PVar "x") (PCon "EApp" (PVar "pureHd") (PVar "arg"))) (EIf (EBinOp "&&" (EApp (EApp (EVar "isEVarNamed") (ELit (LString "pure"))) (EVar "pureHd")) (EBinOp "<=" (EApp (EApp (EVar "countVar") (EVar "x")) (EVar "arg")) (ELit (LInt 1)))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "buildAndThenMap") (EVar "x")) (EVar "arg")) (EVar "m"))) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "andThenPureMapBody" (PWild PWild PWild) (EVar "None"))
(DTypeSig false "ruleAndThenPureMap" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Visitor"))))))))
(DFunDef false "ruleAndThenPureMap" ((PVar "idx") PWild (PVar "facts") PWild PWild) (EListLit (EApp (EApp (EVar "OnExpr") (EListLit (EVar "KApp"))) (EApp (EApp (EVar "andThenPureMapAt") (EVar "idx")) (EVar "facts")))))
(DTypeSig false "andThenPureMapAt" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Finding")))))))
(DFunDef false "andThenPureMapAt" ((PVar "idx") (PVar "facts") (PVar "ctx") (PVar "e")) (EMatch (EApp (EVar "andThenPureMapOf") (EVar "e")) (arm (PCon "Some" (PVar "rewritten")) () (EListLit (EApp (EApp (EApp (EVar "andThenPureMapFinding") (EFieldAccess (EVar "ctx") "ctxDeclLoc")) (EVar "rewritten")) (EApp (EApp (EApp (EApp (EApp (EVar "andThenPureMapFix") (EVar "idx")) (EVar "facts")) (EVar "ctx")) (EVar "e")) (EVar "rewritten"))))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "andThenPureMapFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "Option") (TyCon "Fix")) (TyCon "Finding")))))
(DFunDef false "andThenPureMapFinding" ((PVar "loc") (PVar "rewritten") (PVar "fix")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameAndThenPureMap")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "monadic bind wraps a pure transformation of its result — rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")) (fa "fix" (EVar "fix")))))
(DTypeSig false "andThenPureMapFix" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Ctx") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Fix"))))))))
(DFunDef false "andThenPureMapFix" ((PVar "idx") (PVar "facts") (PVar "ctx") (PVar "e") (PVar "rewritten")) (EIf (EBinOp "&&" (EApp (EApp (EApp (EVar "andThenPureMapUsesPrelude") (EVar "idx")) (EVar "facts")) (EVar "e")) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EVar "rebinds") (EVar "idx")) (EVar "facts")) (EVar "ctx")) (ELit (LString "map"))))) (EApp (EApp (EApp (EApp (EApp (EVar "replaceNodeFix") (EVar "Safe")) (ELit (LString "rewrite the bind as a map"))) (EVar "ctx")) (EVar "e")) (EVar "rewritten")) (EVar "None")))
(DTypeSig false "andThenPureMapUsesPrelude" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Expr") (TyCon "Bool")))))
(DFunDef false "andThenPureMapUsesPrelude" ((PVar "idx") (PVar "facts") (PVar "e")) (EMatch (EApp (EVar "andThenPureHeads") (EVar "e")) (arm (PCon "Some" (PTuple (PVar "andHd") (PVar "pureHd"))) () (EBinOp "&&" (EApp (EApp (EApp (EVar "usesPreludeName") (EVar "idx")) (EVar "facts")) (EVar "andHd")) (EApp (EApp (EApp (EVar "usesPreludeName") (EVar "idx")) (EVar "facts")) (EVar "pureHd")))) (arm (PCon "None") () (EVar "False"))))
(DTypeSig false "andThenPureHeads" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "andThenPureHeads" ((PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EApp" (PVar "inner") (PVar "cont")) () (EMatch (ETuple (EApp (EVar "unwrapLoc") (EVar "inner")) (EApp (EVar "unwrapLoc") (EVar "cont"))) (arm (PTuple (PCon "EApp" (PVar "andHd") PWild) (PCon "ELam" (PList (PCon "PVar" PWild PWild PWild)) (PVar "body"))) () (EMatch (EApp (EVar "unwrapLoc") (EVar "body")) (arm (PCon "EApp" (PVar "pureHd") PWild) () (EApp (EVar "Some") (ETuple (EVar "andHd") (EVar "pureHd")))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
