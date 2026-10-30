# META
source_lines=350
stages=DESUGAR,MARK
# SOURCE
-- lint rule rule-andthen-pure-map: a monadic bind whose continuation only wraps a pure transformation (`andThen m (x => pure body)`). Prefer `map`.

import frontend.ast.{
  noBinderId,
  Loc(..),
  Pat(..),
  Guard(..),
  Arm(..),
  ImplMethod(..),
  DoStmt(..),
  Section(..),
  InterpPart(..),
  GuardArm(..),
  FieldAssign(..),
  LetBind(..),
  FunClause(..),
  Expr(..),
  Decl(..),
}
import frontend.parser.{Positions(..)}
import driver.diagnostics.{Severity(..)}
import tools.printer.{exprToString}
import ir.sexp.{exprSexp}
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
  childExprs,
  declLocList,
  implMethodsBodyKey,
  isEVarNamed,
  ruleNameAndThenPureMap,
  unwrapLoc,
}

export
rule : Rule
rule =
  mkRule
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
      needs = [],
    }
    ruleAndThenPureMap
    (Some andThenPureMapFix)

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
ruleAndThenPureMap : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleAndThenPureMap _ _ _ pos prog =
  flatMap andThenPureMapDeclL (declLocList pos prog)

andThenPureMapDeclL : (Decl, Option Loc) -> List Finding
andThenPureMapDeclL (d, loc) =
  map (andThenPureMapFinding loc) (declAndThenPureMapHits d)

declAndThenPureMapHits : Decl -> List Expr
declAndThenPureMapHits (DFunDef _ _ _ body _ _) = collectAndThenPureMapHits body
declAndThenPureMapHits (DImpl { methods, ... }) =
  flatMap implMethodAndThenPureMapHits methods
declAndThenPureMapHits (DAttrib _ d) = declAndThenPureMapHits d
declAndThenPureMapHits _ = []

implMethodAndThenPureMapHits : ImplMethod -> List Expr
implMethodAndThenPureMapHits (ImplMethod _ _ body) =
  collectAndThenPureMapHits body

-- every eligible bind anywhere in the expression tree (order irrelevant).  The
-- hit detector matches the RAW `EApp` (never an `ELoc` wrapper) so a location-
-- wrapped bind is counted exactly once — at the unwrapped node the tree walk
-- reaches — rather than twice (mirrors `lamHitOf` / `ifMaxMinHitOf`).
collectAndThenPureMapHits : Expr -> List Expr
collectAndThenPureMapHits e =
  andThenPureMapHitOf e ++ flatMap collectAndThenPureMapHits (childExprs e)

andThenPureMapHitOf : Expr -> List Expr
andThenPureMapHitOf (EApp inner cont) =
  optExprToList (andThenPureMapOf (EApp inner cont))
andThenPureMapHitOf _ = []

optExprToList : Option Expr -> List Expr
optExprToList (Some x) = [x]
optExprToList None = []

andThenPureMapFinding : Option Loc -> Expr -> Finding
andThenPureMapFinding loc rewritten = Finding {
  rule = ruleNameAndThenPureMap,
  message =
    "monadic bind wraps a pure transformation of its result — rewrite as '"
      ++ exprToString rewritten
      ++ "'",
  severity = SevWarning,
  loc = loc,
}

-- ── autofix ───────────────────────────────────────────────────────────────────
-- Rebuild the decl body converting every eligible bind to a `map` call.  Detects
-- "did anything change" by comparing the location-stripped sexp of old vs new
-- (same technique `lambdaSectionFix` / `ifMaxMinFix` use).
andThenPureMapFix : Oracle -> Decl -> Option (List Decl)
andThenPureMapFix _ (DFunDef vis name pats body site bid) =
  let body2 = rewriteAndThenPureMapExpr body
  if exprSexp body2 == exprSexp body then
    None
  else
    Some [DFunDef vis name pats body2 site bid]
andThenPureMapFix orc (DAttrib a d) = match andThenPureMapFix orc d
  Some [d2] => Some [DAttrib a d2]
  _ => None
andThenPureMapFix _ (d@(DImpl { implOrigin = _, methods })) =
  let methods2 = map fixImplMethodAndThenPureMap methods
  if implMethodsBodyKey methods2 == implMethodsBodyKey methods then
    None
  else
    -- #1110: record UPDATE — re-synthesising would reset the acquired identity.
    Some [DImpl { d | methods = methods2 }]
andThenPureMapFix _ _ = None

fixImplMethodAndThenPureMap : ImplMethod -> ImplMethod
fixImplMethodAndThenPureMap (ImplMethod nm ps body) =
  ImplMethod nm ps (rewriteAndThenPureMapExpr body)

-- if a rewritten application is an eligible bind, collapse it; else keep it.
tryAndThenPureMap : Expr -> Expr
tryAndThenPureMap e = match andThenPureMapOf e
  Some rewritten => rewritten
  None => e

-- recursively rewrite children (bottom-up), then collapse THIS node if eligible.
rewriteAndThenPureMapExpr : Expr -> Expr
rewriteAndThenPureMapExpr (ELoc l e) = ELoc l (rewriteAndThenPureMapExpr e)
rewriteAndThenPureMapExpr (EDoOrigin l e) =
  EDoOrigin l (rewriteAndThenPureMapExpr e)
rewriteAndThenPureMapExpr (EApp f x) =
  tryAndThenPureMap
    (EApp (rewriteAndThenPureMapExpr f) (rewriteAndThenPureMapExpr x))
rewriteAndThenPureMapExpr (ELam ps b) = ELam ps (rewriteAndThenPureMapExpr b)
rewriteAndThenPureMapExpr (ELet m isf p e1 e2) =
  ELet m isf p (rewriteAndThenPureMapExpr e1) (rewriteAndThenPureMapExpr e2)
rewriteAndThenPureMapExpr (EMatch s arms) =
  EMatch (rewriteAndThenPureMapExpr s) (map rewriteAndThenPureMapArm arms)
rewriteAndThenPureMapExpr (EIf c t el) =
  EIf
    (rewriteAndThenPureMapExpr c)
    (rewriteAndThenPureMapExpr t)
    (rewriteAndThenPureMapExpr el)
rewriteAndThenPureMapExpr (EBinOp op a b r) =
  EBinOp op (rewriteAndThenPureMapExpr a) (rewriteAndThenPureMapExpr b) r
rewriteAndThenPureMapExpr (EUnOp op a r) =
  EUnOp op (rewriteAndThenPureMapExpr a) r
rewriteAndThenPureMapExpr (EInfix op a b) =
  EInfix op (rewriteAndThenPureMapExpr a) (rewriteAndThenPureMapExpr b)
rewriteAndThenPureMapExpr (EFieldAccess e f r) =
  EFieldAccess (rewriteAndThenPureMapExpr e) f r
rewriteAndThenPureMapExpr (ETuple es) =
  ETuple (map rewriteAndThenPureMapExpr es)
rewriteAndThenPureMapExpr (EListLit es) =
  EListLit (map rewriteAndThenPureMapExpr es)
rewriteAndThenPureMapExpr (EArrayLit es) =
  EArrayLit (map rewriteAndThenPureMapExpr es)
rewriteAndThenPureMapExpr (ERangeList lo hi i) =
  ERangeList (rewriteAndThenPureMapExpr lo) (rewriteAndThenPureMapExpr hi) i
rewriteAndThenPureMapExpr (ERangeArray lo hi i) =
  ERangeArray (rewriteAndThenPureMapExpr lo) (rewriteAndThenPureMapExpr hi) i
rewriteAndThenPureMapExpr (ESlice e lo hi i) =
  ESlice
    (rewriteAndThenPureMapExpr e)
    (rewriteAndThenPureMapExpr lo)
    (rewriteAndThenPureMapExpr hi)
    i
rewriteAndThenPureMapExpr (ELetGroup binds body) =
  ELetGroup
    (map rewriteAndThenPureMapLet binds)
    (rewriteAndThenPureMapExpr body)
rewriteAndThenPureMapExpr (ESection s) =
  ESection (rewriteAndThenPureMapSection s)
rewriteAndThenPureMapExpr (EIndex a i) =
  EIndex (rewriteAndThenPureMapExpr a) (rewriteAndThenPureMapExpr i)
rewriteAndThenPureMapExpr (EAnnot e t) = EAnnot (rewriteAndThenPureMapExpr e) t
rewriteAndThenPureMapExpr (EHeadAnnot e t) =
  EHeadAnnot (rewriteAndThenPureMapExpr e) t
rewriteAndThenPureMapExpr (EBlock stmts) =
  EBlock (map rewriteAndThenPureMapStmt stmts)
rewriteAndThenPureMapExpr (EDo d stmts) =
  EDo d (map rewriteAndThenPureMapStmt stmts)
rewriteAndThenPureMapExpr (EStringInterp parts) =
  EStringInterp (map rewriteAndThenPureMapInterp parts)
rewriteAndThenPureMapExpr (EGuards arms) =
  EGuards (map rewriteAndThenPureMapGuardArm arms)
rewriteAndThenPureMapExpr (ERecordCreate n fs) =
  ERecordCreate n (map rewriteAndThenPureMapField fs)
rewriteAndThenPureMapExpr (ERecordUpdate e fs r) =
  ERecordUpdate
    (rewriteAndThenPureMapExpr e)
    (map rewriteAndThenPureMapField fs)
    r
rewriteAndThenPureMapExpr (EVariantUpdate c e fs) =
  EVariantUpdate
    c
    (rewriteAndThenPureMapExpr e)
    (map rewriteAndThenPureMapField fs)
rewriteAndThenPureMapExpr (EMapLit n kvs) =
  EMapLit n (map rewriteAndThenPureMapKv kvs)
rewriteAndThenPureMapExpr (ESetLit n es) =
  ESetLit n (map rewriteAndThenPureMapExpr es)
rewriteAndThenPureMapExpr (EAsPat x e) = EAsPat x (rewriteAndThenPureMapExpr e)
rewriteAndThenPureMapExpr (EOrPat es) =
  EOrPat (map rewriteAndThenPureMapExpr es)
rewriteAndThenPureMapExpr e = e

rewriteAndThenPureMapStmt : DoStmt -> DoStmt
rewriteAndThenPureMapStmt (DoExpr e) = DoExpr (rewriteAndThenPureMapExpr e)
rewriteAndThenPureMapStmt (DoBind p e) = DoBind p (rewriteAndThenPureMapExpr e)
rewriteAndThenPureMapStmt (DoLet m r p e site) =
  DoLet m r p (rewriteAndThenPureMapExpr e) site
rewriteAndThenPureMapStmt (DoAssign x e) =
  DoAssign x (rewriteAndThenPureMapExpr e)
rewriteAndThenPureMapStmt (DoFieldAssign x fs e) =
  DoFieldAssign x fs (rewriteAndThenPureMapExpr e)

rewriteAndThenPureMapArm : Arm -> Arm
rewriteAndThenPureMapArm (Arm p gs body) =
  Arm p (map rewriteAndThenPureMapGuard gs) (rewriteAndThenPureMapExpr body)

rewriteAndThenPureMapGuard : Guard -> Guard
rewriteAndThenPureMapGuard (GBool e) = GBool (rewriteAndThenPureMapExpr e)
rewriteAndThenPureMapGuard (GBind p e) = GBind p (rewriteAndThenPureMapExpr e)

rewriteAndThenPureMapLet : LetBind -> LetBind
rewriteAndThenPureMapLet (LetBind n clauses site bid) =
  LetBind n (map rewriteAndThenPureMapClause clauses) site bid

rewriteAndThenPureMapClause : FunClause -> FunClause
rewriteAndThenPureMapClause (FunClause ps body) =
  FunClause ps (rewriteAndThenPureMapExpr body)

rewriteAndThenPureMapSection : Section -> Section
rewriteAndThenPureMapSection (SecBare op) = SecBare op
rewriteAndThenPureMapSection (SecRight op e) =
  SecRight op (rewriteAndThenPureMapExpr e)
rewriteAndThenPureMapSection (SecLeft e op) =
  SecLeft (rewriteAndThenPureMapExpr e) op

rewriteAndThenPureMapInterp : InterpPart -> InterpPart
rewriteAndThenPureMapInterp (InterpStr s) = InterpStr s
rewriteAndThenPureMapInterp (InterpExpr e) =
  InterpExpr (rewriteAndThenPureMapExpr e)

rewriteAndThenPureMapGuardArm : GuardArm -> GuardArm
rewriteAndThenPureMapGuardArm (GuardArm gs body) =
  GuardArm (map rewriteAndThenPureMapGuard gs) (rewriteAndThenPureMapExpr body)

rewriteAndThenPureMapField : FieldAssign -> FieldAssign
rewriteAndThenPureMapField (FieldAssign n e) =
  FieldAssign n (rewriteAndThenPureMapExpr e)

rewriteAndThenPureMapKv : (Expr, Expr) -> (Expr, Expr)
rewriteAndThenPureMapKv (k, v) =
  (rewriteAndThenPureMapExpr k, rewriteAndThenPureMapExpr v)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "noBinderId" false) (mem "Loc" true) (mem "Pat" true) (mem "Guard" true) (mem "Arm" true) (mem "ImplMethod" true) (mem "DoStmt" true) (mem "Section" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "LetBind" true) (mem "FunClause" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "andThenEtaFn" false) (mem "childExprs" false) (mem "declLocList" false) (mem "implMethodsBodyKey" false) (mem "isEVarNamed" false) (mem "ruleNameAndThenPureMap" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameAndThenPureMap")) (fa "summary" (ELit (LString "monadic bind whose continuation just wraps a pure transformation (`andThen m (x => pure body)`). Prefer `map` (functor law: m >>= (pure . f) ≡ fmap f m)"))) (fa "doc" (ELit (LString "A monadic bind whose continuation only wraps a pure transformation in `pure` is `map`, by the functor law `m >>= (pure . f) == fmap f m`.\n\nBefore:\n  andThen m (x => pure (f x))\nAfter:\n  map f m"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleAndThenPureMap")) (EApp (EVar "Some") (EVar "andThenPureMapFix"))))
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
(DTypeSig false "ruleAndThenPureMap" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleAndThenPureMap" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EVar "flatMap") (EVar "andThenPureMapDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "andThenPureMapDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "andThenPureMapDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EVar "map") (EApp (EVar "andThenPureMapFinding") (EVar "loc"))) (EApp (EVar "declAndThenPureMapHits") (EVar "d"))))
(DTypeSig false "declAndThenPureMapHits" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "declAndThenPureMapHits" ((PCon "DFunDef" PWild PWild PWild (PVar "body") PWild PWild)) (EApp (EVar "collectAndThenPureMapHits") (EVar "body")))
(DFunDef false "declAndThenPureMapHits" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EVar "implMethodAndThenPureMapHits")) (EVar "methods")))
(DFunDef false "declAndThenPureMapHits" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declAndThenPureMapHits") (EVar "d")))
(DFunDef false "declAndThenPureMapHits" (PWild) (EListLit))
(DTypeSig false "implMethodAndThenPureMapHits" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "implMethodAndThenPureMapHits" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "collectAndThenPureMapHits") (EVar "body")))
(DTypeSig false "collectAndThenPureMapHits" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "collectAndThenPureMapHits" ((PVar "e")) (EBinOp "++" (EApp (EVar "andThenPureMapHitOf") (EVar "e")) (EApp (EApp (EVar "flatMap") (EVar "collectAndThenPureMapHits")) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "andThenPureMapHitOf" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "andThenPureMapHitOf" ((PCon "EApp" (PVar "inner") (PVar "cont"))) (EApp (EVar "optExprToList") (EApp (EVar "andThenPureMapOf") (EApp (EApp (EVar "EApp") (EVar "inner")) (EVar "cont")))))
(DFunDef false "andThenPureMapHitOf" (PWild) (EListLit))
(DTypeSig false "optExprToList" (TyFun (TyApp (TyCon "Option") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "optExprToList" ((PCon "Some" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "optExprToList" ((PCon "None")) (EListLit))
(DTypeSig false "andThenPureMapFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "andThenPureMapFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameAndThenPureMap")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "monadic bind wraps a pure transformation of its result — rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "andThenPureMapFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "andThenPureMapFix" (PWild (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body") (PVar "site") (PVar "bid"))) (EBlock (DoLet false false (PVar "body2") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2")) (EVar "site")) (EVar "bid"))))))))
(DFunDef false "andThenPureMapFix" ((PVar "orc") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EVar "andThenPureMapFix") (EVar "orc")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "andThenPureMapFix" (PWild (PAs "d" (PRec "DImpl" ((rf "implOrigin" PWild) (rf "methods" None)) false))) (EBlock (DoLet false false (PVar "methods2") (EApp (EApp (EVar "map") (EVar "fixImplMethodAndThenPureMap")) (EVar "methods"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "implMethodsBodyKey") (EVar "methods2")) (EApp (EVar "implMethodsBodyKey") (EVar "methods"))) (EVar "None") (EApp (EVar "Some") (EListLit (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EVar "methods2"))))))))))
(DFunDef false "andThenPureMapFix" (PWild PWild) (EVar "None"))
(DTypeSig false "fixImplMethodAndThenPureMap" (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))
(DFunDef false "fixImplMethodAndThenPureMap" ((PCon "ImplMethod" (PVar "nm") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "ps")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))))
(DTypeSig false "tryAndThenPureMap" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "tryAndThenPureMap" ((PVar "e")) (EMatch (EApp (EVar "andThenPureMapOf") (EVar "e")) (arm (PCon "Some" (PVar "rewritten")) () (EVar "rewritten")) (arm (PCon "None") () (EVar "e"))))
(DTypeSig false "rewriteAndThenPureMapExpr" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EVar "tryAndThenPureMap") (EApp (EApp (EVar "EApp") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "f"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "x")))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "b"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ELet" (PVar "m") (PVar "isf") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isf")) (EVar "p")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e1"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e2"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EMatch" (PVar "s") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "s"))) (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapArm")) (EVar "arms"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "c"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "t"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "el"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "a"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "b"))) (EVar "r")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "a"))) (EVar "r")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "a"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "b"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EVar "f")) (EVar "r")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapExpr")) (EVar "es"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapExpr")) (EVar "es"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapExpr")) (EVar "es"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "lo"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "lo"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "lo"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapLet")) (EVar "binds"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EVar "rewriteAndThenPureMapSection") (EVar "s"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "EIndex") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "a"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "i"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EHeadAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapStmt")) (EVar "stmts"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "d")) (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapStmt")) (EVar "stmts"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapInterp")) (EVar "parts"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapGuardArm")) (EVar "arms"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapField")) (EVar "fs"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapField")) (EVar "fs"))) (EVar "r")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapField")) (EVar "fs"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapKv")) (EVar "kvs"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapExpr")) (EVar "es"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EOrPat" (PVar "es"))) (EApp (EVar "EOrPat") (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapExpr")) (EVar "es"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PVar "e")) (EVar "e"))
(DTypeSig false "rewriteAndThenPureMapStmt" (TyFun (TyCon "DoStmt") (TyCon "DoStmt")))
(DFunDef false "rewriteAndThenPureMapStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapStmt" ((PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapStmt" ((PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EVar "site")))
(DFunDef false "rewriteAndThenPureMapStmt" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapStmt" ((PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DTypeSig false "rewriteAndThenPureMapArm" (TyFun (TyCon "Arm") (TyCon "Arm")))
(DFunDef false "rewriteAndThenPureMapArm" ((PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapGuard")) (EVar "gs"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))))
(DTypeSig false "rewriteAndThenPureMapGuard" (TyFun (TyCon "Guard") (TyCon "Guard")))
(DFunDef false "rewriteAndThenPureMapGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapGuard" ((PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DTypeSig false "rewriteAndThenPureMapLet" (TyFun (TyCon "LetBind") (TyCon "LetBind")))
(DFunDef false "rewriteAndThenPureMapLet" ((PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapClause")) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "rewriteAndThenPureMapClause" (TyFun (TyCon "FunClause") (TyCon "FunClause")))
(DFunDef false "rewriteAndThenPureMapClause" ((PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))))
(DTypeSig false "rewriteAndThenPureMapSection" (TyFun (TyCon "Section") (TyCon "Section")))
(DFunDef false "rewriteAndThenPureMapSection" ((PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "rewriteAndThenPureMapSection" ((PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapSection" ((PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EVar "op")))
(DTypeSig false "rewriteAndThenPureMapInterp" (TyFun (TyCon "InterpPart") (TyCon "InterpPart")))
(DFunDef false "rewriteAndThenPureMapInterp" ((PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "rewriteAndThenPureMapInterp" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DTypeSig false "rewriteAndThenPureMapGuardArm" (TyFun (TyCon "GuardArm") (TyCon "GuardArm")))
(DFunDef false "rewriteAndThenPureMapGuardArm" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EVar "map") (EVar "rewriteAndThenPureMapGuard")) (EVar "gs"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))))
(DTypeSig false "rewriteAndThenPureMapField" (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign")))
(DFunDef false "rewriteAndThenPureMapField" ((PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DTypeSig false "rewriteAndThenPureMapKv" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteAndThenPureMapKv" ((PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "k")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "v"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "noBinderId" false) (mem "Loc" true) (mem "Pat" true) (mem "Guard" true) (mem "Arm" true) (mem "ImplMethod" true) (mem "DoStmt" true) (mem "Section" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "LetBind" true) (mem "FunClause" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" false) (mem "mkRule" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "andThenEtaFn" false) (mem "childExprs" false) (mem "declLocList" false) (mem "implMethodsBodyKey" false) (mem "isEVarNamed" false) (mem "ruleNameAndThenPureMap" false) (mem "unwrapLoc" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameAndThenPureMap")) (fa "summary" (ELit (LString "monadic bind whose continuation just wraps a pure transformation (`andThen m (x => pure body)`). Prefer `map` (functor law: m >>= (pure . f) ≡ fmap f m)"))) (fa "doc" (ELit (LString "A monadic bind whose continuation only wraps a pure transformation in `pure` is `map`, by the functor law `m >>= (pure . f) == fmap f m`.\n\nBefore:\n  andThen m (x => pure (f x))\nAfter:\n  map f m"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleAndThenPureMap")) (EApp (EVar "Some") (EVar "andThenPureMapFix"))))
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
(DTypeSig false "ruleAndThenPureMap" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleAndThenPureMap" (PWild PWild PWild (PVar "pos") (PVar "prog")) (EApp (EApp (EDictApp "flatMap") (EVar "andThenPureMapDeclL")) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))
(DTypeSig false "andThenPureMapDeclL" (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding"))))
(DFunDef false "andThenPureMapDeclL" ((PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "andThenPureMapFinding") (EVar "loc"))) (EApp (EVar "declAndThenPureMapHits") (EVar "d"))))
(DTypeSig false "declAndThenPureMapHits" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "declAndThenPureMapHits" ((PCon "DFunDef" PWild PWild PWild (PVar "body") PWild PWild)) (EApp (EVar "collectAndThenPureMapHits") (EVar "body")))
(DFunDef false "declAndThenPureMapHits" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EVar "implMethodAndThenPureMapHits")) (EVar "methods")))
(DFunDef false "declAndThenPureMapHits" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declAndThenPureMapHits") (EVar "d")))
(DFunDef false "declAndThenPureMapHits" (PWild) (EListLit))
(DTypeSig false "implMethodAndThenPureMapHits" (TyFun (TyCon "ImplMethod") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "implMethodAndThenPureMapHits" ((PCon "ImplMethod" PWild PWild (PVar "body"))) (EApp (EVar "collectAndThenPureMapHits") (EVar "body")))
(DTypeSig false "collectAndThenPureMapHits" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "collectAndThenPureMapHits" ((PVar "e")) (EBinOp "++" (EApp (EVar "andThenPureMapHitOf") (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EVar "collectAndThenPureMapHits")) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "andThenPureMapHitOf" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "andThenPureMapHitOf" ((PCon "EApp" (PVar "inner") (PVar "cont"))) (EApp (EVar "optExprToList") (EApp (EVar "andThenPureMapOf") (EApp (EApp (EVar "EApp") (EVar "inner")) (EVar "cont")))))
(DFunDef false "andThenPureMapHitOf" (PWild) (EListLit))
(DTypeSig false "optExprToList" (TyFun (TyApp (TyCon "Option") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "optExprToList" ((PCon "Some" (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "optExprToList" ((PCon "None")) (EListLit))
(DTypeSig false "andThenPureMapFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Expr") (TyCon "Finding"))))
(DFunDef false "andThenPureMapFinding" ((PVar "loc") (PVar "rewritten")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameAndThenPureMap")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "monadic bind wraps a pure transformation of its result — rewrite as '")) (EApp (EVar "exprToString") (EVar "rewritten"))) (ELit (LString "'")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "andThenPureMapFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "andThenPureMapFix" (PWild (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body") (PVar "site") (PVar "bid"))) (EBlock (DoLet false false (PVar "body2") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2")) (EVar "site")) (EVar "bid"))))))))
(DFunDef false "andThenPureMapFix" ((PVar "orc") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EVar "andThenPureMapFix") (EVar "orc")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "andThenPureMapFix" (PWild (PAs "d" (PRec "DImpl" ((rf "implOrigin" PWild) (rf "methods" None)) false))) (EBlock (DoLet false false (PVar "methods2") (EApp (EApp (EMethodRef "map") (EVar "fixImplMethodAndThenPureMap")) (EVar "methods"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "implMethodsBodyKey") (EVar "methods2")) (EApp (EVar "implMethodsBodyKey") (EVar "methods"))) (EVar "None") (EApp (EVar "Some") (EListLit (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EVar "methods2"))))))))))
(DFunDef false "andThenPureMapFix" (PWild PWild) (EVar "None"))
(DTypeSig false "fixImplMethodAndThenPureMap" (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod")))
(DFunDef false "fixImplMethodAndThenPureMap" ((PCon "ImplMethod" (PVar "nm") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "nm")) (EVar "ps")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))))
(DTypeSig false "tryAndThenPureMap" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "tryAndThenPureMap" ((PVar "e")) (EMatch (EApp (EVar "andThenPureMapOf") (EVar "e")) (arm (PCon "Some" (PVar "rewritten")) () (EVar "rewritten")) (arm (PCon "None") () (EVar "e"))))
(DTypeSig false "rewriteAndThenPureMapExpr" (TyFun (TyCon "Expr") (TyCon "Expr")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EVar "tryAndThenPureMap") (EApp (EApp (EVar "EApp") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "f"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "x")))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "b"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ELet" (PVar "m") (PVar "isf") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isf")) (EVar "p")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e1"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e2"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EMatch" (PVar "s") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "s"))) (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapArm")) (EVar "arms"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "c"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "t"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "el"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "a"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "b"))) (EVar "r")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "a"))) (EVar "r")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "a"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "b"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EVar "f")) (EVar "r")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapExpr")) (EVar "es"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapExpr")) (EVar "es"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapExpr")) (EVar "es"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "lo"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "lo"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "lo"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapLet")) (EVar "binds"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EVar "rewriteAndThenPureMapSection") (EVar "s"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "EIndex") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "a"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "i"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EHeadAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapStmt")) (EVar "stmts"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "d")) (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapStmt")) (EVar "stmts"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapInterp")) (EVar "parts"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapGuardArm")) (EVar "arms"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapField")) (EVar "fs"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapField")) (EVar "fs"))) (EVar "r")))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapField")) (EVar "fs"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapKv")) (EVar "kvs"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapExpr")) (EVar "es"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PCon "EOrPat" (PVar "es"))) (EApp (EVar "EOrPat") (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapExpr")) (EVar "es"))))
(DFunDef false "rewriteAndThenPureMapExpr" ((PVar "e")) (EVar "e"))
(DTypeSig false "rewriteAndThenPureMapStmt" (TyFun (TyCon "DoStmt") (TyCon "DoStmt")))
(DFunDef false "rewriteAndThenPureMapStmt" ((PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapStmt" ((PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapStmt" ((PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EVar "site")))
(DFunDef false "rewriteAndThenPureMapStmt" ((PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapStmt" ((PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DTypeSig false "rewriteAndThenPureMapArm" (TyFun (TyCon "Arm") (TyCon "Arm")))
(DFunDef false "rewriteAndThenPureMapArm" ((PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapGuard")) (EVar "gs"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))))
(DTypeSig false "rewriteAndThenPureMapGuard" (TyFun (TyCon "Guard") (TyCon "Guard")))
(DFunDef false "rewriteAndThenPureMapGuard" ((PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapGuard" ((PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DTypeSig false "rewriteAndThenPureMapLet" (TyFun (TyCon "LetBind") (TyCon "LetBind")))
(DFunDef false "rewriteAndThenPureMapLet" ((PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapClause")) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "rewriteAndThenPureMapClause" (TyFun (TyCon "FunClause") (TyCon "FunClause")))
(DFunDef false "rewriteAndThenPureMapClause" ((PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))))
(DTypeSig false "rewriteAndThenPureMapSection" (TyFun (TyCon "Section") (TyCon "Section")))
(DFunDef false "rewriteAndThenPureMapSection" ((PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "rewriteAndThenPureMapSection" ((PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DFunDef false "rewriteAndThenPureMapSection" ((PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))) (EVar "op")))
(DTypeSig false "rewriteAndThenPureMapInterp" (TyFun (TyCon "InterpPart") (TyCon "InterpPart")))
(DFunDef false "rewriteAndThenPureMapInterp" ((PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "rewriteAndThenPureMapInterp" ((PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DTypeSig false "rewriteAndThenPureMapGuardArm" (TyFun (TyCon "GuardArm") (TyCon "GuardArm")))
(DFunDef false "rewriteAndThenPureMapGuardArm" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EMethodRef "map") (EVar "rewriteAndThenPureMapGuard")) (EVar "gs"))) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "body"))))
(DTypeSig false "rewriteAndThenPureMapField" (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign")))
(DFunDef false "rewriteAndThenPureMapField" ((PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "e"))))
(DTypeSig false "rewriteAndThenPureMapKv" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteAndThenPureMapKv" ((PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "k")) (EApp (EVar "rewriteAndThenPureMapExpr") (EVar "v"))))
