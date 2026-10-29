# META
source_lines=333
stages=DESUGAR,MARK
# SOURCE
-- lint rule bind-then-destructure: a do-bind immediately destructured by an irrefutable single-arm `match`. Inline the pattern into the bind.

-- ── rule: bind-then-destructure ───────────────────────────────────────────────
-- Inside any do/bare block, a `v <- e` bind immediately followed by a FINAL
-- statement `match v { pat => body }` (exactly one arm, no guards) where `pat` is
-- IRREFUTABLE (tuple/record/var/wildcard, recursively — OR a single-constructor
-- pattern `PCon c subps` where `c` is the SOLE constructor of its datatype, as
-- decided by the syntactic constructor `Oracle`, with all sub-patterns
-- recursively irrefutable) and `v` does NOT appear free in `body`.  Such a pair
-- is just `pat <- e` with `body` inlined.  Detection recurses into every nested
-- do/bare block in the decl body; the autofix is a pure AST rewrite (the
-- framework re-renders the returned Decl via the printer).
--
-- The `Oracle` is `frontend.exhaust.buildOracle` over the whole target file's
-- decls — a purely SYNTACTIC scan of constructor declarations (no typecheck),
-- so multi-ctor wrappers (`Some v <-`, `Ok x <-`, `Cons`/`Nil`) stay refutable
-- and are skipped, while genuine newtype/single-variant wrappers collapse.
--
-- `v`-not-free-in-`body` uses the same conservative printed whole-word scan the
-- §8 fixer relies on (`wholeWordIn`): it can only over-bail (suppress a real
-- finding), never produce an unsound fix.

import frontend.ast.{
  Loc(..),
  Pat(..),
  RecPatField(..),
  Guard(..),
  Arm(..),
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
import support.util.{anyList, reverseL}
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
  StdlibIndex(..),
  mkRule,
  factOracle,
}
import tools.lint_shared.{
  childExprs,
  ctorIsSingle,
  declLocList,
  ruleNameBindThenDestructure,
  unwrapLoc,
  wholeWordIn,
}

export
rule : Rule
rule =
  mkRule
    RuleMeta {
      name = ruleNameBindThenDestructure,
      summary =
        "do-bind then immediately destructures the bound var with an irrefutable single-arm `match`. Inline the pattern into the bind",
      doc =
        "A `do` bind that immediately destructures the bound variable with an irrefutable single-arm `match` can put the pattern in the bind itself.\n\nBefore:\n  p <- getPair\n  match p\n    (a, b) => use a b\nAfter:\n  (a, b) <- getPair\n  use a b",
      category = Style,
      scope = Universal,
      ratchet = Gated,
      defaultSeverity = SevWarning,
      fixability = Fixable,
      needs = [],
    }
    ruleBindThenDestructure
    (Some bindThenDestructureFix)

-- a pattern is irrefutable iff it is a var/wildcard, a tuple/record whose
-- sub-patterns are all themselves irrefutable, or a single-constructor pattern
-- (the constructor is the only one of its datatype, per the syntactic oracle)
-- whose sub-patterns are all irrefutable.  Everything else (multi-ctor, cons,
-- list, literal, range, as-pattern) is refutable for this rule's purposes.
irrefutablePat : Oracle -> Pat -> Bool
irrefutablePat _ (PVar _ _ _) = True
irrefutablePat _ PWild = True
irrefutablePat orc (PTuple ps) = not (anyList (refutablePat orc) ps)
irrefutablePat orc (PRec _ fields _) = not (anyList (refutableField orc) fields)
irrefutablePat orc (PCon c subps) =
  ctorIsSingle orc c && not (anyList (refutablePat orc) subps)
irrefutablePat _ _ = False

refutablePat : Oracle -> Pat -> Bool
refutablePat orc p = not (irrefutablePat orc p)

refutableField : Oracle -> RecPatField -> Bool
refutableField _ (RecPatField _ _ _ None) = False
refutableField orc (RecPatField _ _ _ (Some p)) = refutablePat orc p

-- the bound-var/pattern/expr/body of a collapsible bind-then-match tail, plus the
-- statements preceding it.  Returns None when the last two statements don't form
-- the irrefutable single-arm shape.
bindMatchTail : Oracle ->
  List DoStmt ->
  Option (List DoStmt, String, Pat, Expr, Expr)
bindMatchTail orc stmts = match splitTail2 stmts
  Some (prefix, DoBind (PVar v _ _) boundE, DoExpr matchE) =>
    bindMatchArm orc prefix v boundE (unwrapLoc matchE)
  _ => None

bindMatchArm : Oracle ->
  List DoStmt ->
  String ->
  Expr ->
  Expr ->
  Option (List DoStmt, String, Pat, Expr, Expr)
bindMatchArm orc prefix v boundE (EMatch scrut [Arm pat [] body])
  | scrutIsVar v (unwrapLoc scrut)
    && irrefutablePat orc pat
    && not (wholeWordIn v (exprToString body)) =
    Some (prefix, v, pat, boundE, body)
  | otherwise = None
bindMatchArm _ _ _ _ _ = None

scrutIsVar : String -> Expr -> Bool
scrutIsVar v (EVar w) = v == w
scrutIsVar _ _ = False

-- last two statements (prefix, second-to-last, last), or None if fewer than 2.
splitTail2 : List DoStmt -> Option (List DoStmt, DoStmt, DoStmt)
splitTail2 stmts = match reverseL stmts
  lst :: scd :: restRev => Some (reverseL restRev, scd, lst)
  _ => None

-- ── check ────────────────────────────────────────────────────────────────────
ruleBindThenDestructure : StdlibIndex ->
  String ->
  FileFacts ->
  Positions ->
  List Decl ->
  List Finding
ruleBindThenDestructure _ _ facts pos prog =
  let orc = factOracle facts
  flatMap (bindDestructureDeclL orc) (declLocList pos prog)

bindDestructureDeclL : Oracle -> (Decl, Option Loc) -> List Finding
bindDestructureDeclL orc (d, loc) =
  map (bindDestructureFinding loc) (declBindHits orc d)

declBindHits : Oracle -> Decl -> List String
declBindHits orc (DFunDef _ _ _ body _ _) = collectBindHits orc body
declBindHits orc (DAttrib _ d) = declBindHits orc d
declBindHits _ _ = []

bindDestructureFinding : Option Loc -> String -> Finding
bindDestructureFinding loc v = Finding {
  rule = ruleNameBindThenDestructure,
  message =
    "binds '"
      ++ v
      ++ "' then immediately destructures it in a final `match`. Inline the pattern into the bind",
  severity = SevWarning,
  loc = loc,
}

-- collect every collapsible tail's bound-var name, recursing into all sub-exprs.
collectBindHits : Oracle -> Expr -> List String
collectBindHits orc e =
  tailHitOf orc e ++ flatMap (collectBindHits orc) (childExprs e)

tailHitOf : Oracle -> Expr -> List String
tailHitOf orc (EDo _ stmts) = hitNameOf orc stmts
tailHitOf orc (EBlock stmts) = hitNameOf orc stmts
tailHitOf _ _ = []

hitNameOf : Oracle -> List DoStmt -> List String
hitNameOf orc stmts = match bindMatchTail orc stmts
  Some (_, v, _, _, _) => [v]
  None => []

-- ── autofix ──────────────────────────────────────────────────────────────────
-- Rebuild the decl body with every collapsible bind-then-match tail inlined.
-- The rewrite is structural (rebuilds every node), so we detect "did anything
-- change" by comparing the location-stripped sexp of the old vs new body — only
-- then do we return `Some [newDecl]` (the printer re-renders it).
bindThenDestructureFix : Oracle -> Decl -> Option (List Decl)
bindThenDestructureFix orc (DFunDef vis name pats body site bid) =
  let body2 = rewriteBindExpr orc body
  if exprSexp body2 == exprSexp body then
    None
  else
    Some [DFunDef vis name pats body2 site bid]
bindThenDestructureFix orc (DAttrib a d) = match bindThenDestructureFix orc d
  Some [d2] => Some [DAttrib a d2]
  _ => None
bindThenDestructureFix _ _ = None

-- recursively rewrite, then collapse the tail of each do/bare block.
rewriteBindExpr : Oracle -> Expr -> Expr
rewriteBindExpr orc (ELoc l e) = ELoc l (rewriteBindExpr orc e)
rewriteBindExpr orc (EDoOrigin l e) = EDoOrigin l (rewriteBindExpr orc e)
rewriteBindExpr orc (EApp f x) =
  EApp (rewriteBindExpr orc f) (rewriteBindExpr orc x)
rewriteBindExpr orc (ELam ps b) = ELam ps (rewriteBindExpr orc b)
rewriteBindExpr orc (ELet m isf p e1 e2) =
  ELet m isf p (rewriteBindExpr orc e1) (rewriteBindExpr orc e2)
rewriteBindExpr orc (EMatch s arms) =
  EMatch (rewriteBindExpr orc s) (map (rewriteBindArm orc) arms)
rewriteBindExpr orc (EIf c t el) =
  EIf (rewriteBindExpr orc c) (rewriteBindExpr orc t) (rewriteBindExpr orc el)
rewriteBindExpr orc (EBinOp op a b r) =
  EBinOp op (rewriteBindExpr orc a) (rewriteBindExpr orc b) r
rewriteBindExpr orc (EUnOp op a r) = EUnOp op (rewriteBindExpr orc a) r
rewriteBindExpr orc (EInfix op a b) =
  EInfix op (rewriteBindExpr orc a) (rewriteBindExpr orc b)
rewriteBindExpr orc (EFieldAccess e f r) =
  EFieldAccess (rewriteBindExpr orc e) f r
rewriteBindExpr orc (ETuple es) = ETuple (map (rewriteBindExpr orc) es)
rewriteBindExpr orc (EListLit es) = EListLit (map (rewriteBindExpr orc) es)
rewriteBindExpr orc (EArrayLit es) = EArrayLit (map (rewriteBindExpr orc) es)
rewriteBindExpr orc (ERangeList lo hi i) =
  ERangeList (rewriteBindExpr orc lo) (rewriteBindExpr orc hi) i
rewriteBindExpr orc (ERangeArray lo hi i) =
  ERangeArray (rewriteBindExpr orc lo) (rewriteBindExpr orc hi) i
rewriteBindExpr orc (ESlice e lo hi i) =
  ESlice
    (rewriteBindExpr orc e)
    (rewriteBindExpr orc lo)
    (rewriteBindExpr orc hi)
    i
rewriteBindExpr orc (ELetGroup binds body) =
  ELetGroup (map (rewriteBindLet orc) binds) (rewriteBindExpr orc body)
rewriteBindExpr orc (ESection s) = ESection (rewriteBindSection orc s)
rewriteBindExpr orc (EIndex a i) =
  EIndex (rewriteBindExpr orc a) (rewriteBindExpr orc i)
rewriteBindExpr orc (EAnnot e t) = EAnnot (rewriteBindExpr orc e) t
rewriteBindExpr orc (EHeadAnnot e t) = EHeadAnnot (rewriteBindExpr orc e) t
rewriteBindExpr orc (EBlock stmts) =
  EBlock (collapseBindTail orc False (map (rewriteBindStmt orc) stmts))
rewriteBindExpr orc (EDo d stmts) =
  EDo d (collapseBindTail orc d (map (rewriteBindStmt orc) stmts))
rewriteBindExpr orc (EStringInterp parts) =
  EStringInterp (map (rewriteBindInterp orc) parts)
rewriteBindExpr orc (EGuards arms) =
  EGuards (map (rewriteBindGuardArm orc) arms)
rewriteBindExpr orc (ERecordCreate n fs) =
  ERecordCreate n (map (rewriteBindField orc) fs)
rewriteBindExpr orc (ERecordUpdate e fs r) =
  ERecordUpdate (rewriteBindExpr orc e) (map (rewriteBindField orc) fs) r
rewriteBindExpr orc (EVariantUpdate c e fs) =
  EVariantUpdate c (rewriteBindExpr orc e) (map (rewriteBindField orc) fs)
rewriteBindExpr orc (EMapLit n kvs) = EMapLit n (map (rewriteBindKv orc) kvs)
rewriteBindExpr orc (ESetLit n es) = ESetLit n (map (rewriteBindExpr orc) es)
rewriteBindExpr orc (EAsPat x e) = EAsPat x (rewriteBindExpr orc e)
rewriteBindExpr orc (EOrPat es) = EOrPat (map (rewriteBindExpr orc) es)
rewriteBindExpr _ e = e

-- collapse a (already child-rewritten) statement list: if its last two statements
-- are the irrefutable bind-then-match shape, replace them with `pat <- e` plus the
-- arm body's statements spliced inline.
collapseBindTail : Oracle -> Bool -> List DoStmt -> List DoStmt
collapseBindTail orc host stmts = match bindMatchTail orc stmts
  Some (prefix, _, pat, boundE, body) =>
    prefix ++ (DoBind pat boundE :: bodyToStmts host body)
  None => stmts

-- the arm body as statements: a bare block, or a monadic block heralded the SAME
-- way as the host (`host`: the enclosing block's deferred flag), contributes its
-- own statements flattened into the outer block; anything else — including a
-- `defer` block inside a `do` block or vice versa, whose statements bind through
-- a different interface family (#824) — becomes a final expr-statement.
bodyToStmts : Bool -> Expr -> List DoStmt
bodyToStmts host e = match unwrapLoc e
  EDo d stmts => whenSameHerald host d stmts e
  EBlock stmts => stmts
  _ => [DoExpr e]

whenSameHerald : Bool -> Bool -> List DoStmt -> Expr -> List DoStmt
whenSameHerald host d stmts e
  | host == d = stmts
  | otherwise = [DoExpr e]

rewriteBindStmt : Oracle -> DoStmt -> DoStmt
rewriteBindStmt orc (DoExpr e) = DoExpr (rewriteBindExpr orc e)
rewriteBindStmt orc (DoBind p e) = DoBind p (rewriteBindExpr orc e)
rewriteBindStmt orc (DoLet m r p e site) =
  DoLet m r p (rewriteBindExpr orc e) site
rewriteBindStmt orc (DoAssign x e) = DoAssign x (rewriteBindExpr orc e)
rewriteBindStmt orc (DoFieldAssign x fs e) =
  DoFieldAssign x fs (rewriteBindExpr orc e)

rewriteBindArm : Oracle -> Arm -> Arm
rewriteBindArm orc (Arm p gs body) =
  Arm p (map (rewriteBindGuard orc) gs) (rewriteBindExpr orc body)

rewriteBindGuard : Oracle -> Guard -> Guard
rewriteBindGuard orc (GBool e) = GBool (rewriteBindExpr orc e)
rewriteBindGuard orc (GBind p e) = GBind p (rewriteBindExpr orc e)

rewriteBindLet : Oracle -> LetBind -> LetBind
rewriteBindLet orc (LetBind n clauses site bid) =
  LetBind n (map (rewriteBindClause orc) clauses) site bid

rewriteBindClause : Oracle -> FunClause -> FunClause
rewriteBindClause orc (FunClause ps body) =
  FunClause ps (rewriteBindExpr orc body)

rewriteBindSection : Oracle -> Section -> Section
rewriteBindSection _ (SecBare op) = SecBare op
rewriteBindSection orc (SecRight op e) = SecRight op (rewriteBindExpr orc e)
rewriteBindSection orc (SecLeft e op) = SecLeft (rewriteBindExpr orc e) op

rewriteBindInterp : Oracle -> InterpPart -> InterpPart
rewriteBindInterp _ (InterpStr s) = InterpStr s
rewriteBindInterp orc (InterpExpr e) = InterpExpr (rewriteBindExpr orc e)

rewriteBindGuardArm : Oracle -> GuardArm -> GuardArm
rewriteBindGuardArm orc (GuardArm gs body) =
  GuardArm (map (rewriteBindGuard orc) gs) (rewriteBindExpr orc body)

rewriteBindField : Oracle -> FieldAssign -> FieldAssign
rewriteBindField orc (FieldAssign n e) = FieldAssign n (rewriteBindExpr orc e)

rewriteBindKv : Oracle -> (Expr, Expr) -> (Expr, Expr)
rewriteBindKv orc (k, v) = (rewriteBindExpr orc k, rewriteBindExpr orc v)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "Section" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "LetBind" true) (mem "FunClause" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "reverseL" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" true) (mem "mkRule" false) (mem "factOracle" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "childExprs" false) (mem "ctorIsSingle" false) (mem "declLocList" false) (mem "ruleNameBindThenDestructure" false) (mem "unwrapLoc" false) (mem "wholeWordIn" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameBindThenDestructure")) (fa "summary" (ELit (LString "do-bind then immediately destructures the bound var with an irrefutable single-arm `match`. Inline the pattern into the bind"))) (fa "doc" (ELit (LString "A `do` bind that immediately destructures the bound variable with an irrefutable single-arm `match` can put the pattern in the bind itself.\n\nBefore:\n  p <- getPair\n  match p\n    (a, b) => use a b\nAfter:\n  (a, b) <- getPair\n  use a b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleBindThenDestructure")) (EApp (EVar "Some") (EVar "bindThenDestructureFix"))))
(DTypeSig false "irrefutablePat" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "irrefutablePat" (PWild (PCon "PVar" PWild PWild PWild)) (EVar "True"))
(DFunDef false "irrefutablePat" (PWild (PCon "PWild")) (EVar "True"))
(DFunDef false "irrefutablePat" ((PVar "orc") (PCon "PTuple" (PVar "ps"))) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "refutablePat") (EVar "orc"))) (EVar "ps"))))
(DFunDef false "irrefutablePat" ((PVar "orc") (PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "refutableField") (EVar "orc"))) (EVar "fields"))))
(DFunDef false "irrefutablePat" ((PVar "orc") (PCon "PCon" (PVar "c") (PVar "subps"))) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSingle") (EVar "orc")) (EVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "refutablePat") (EVar "orc"))) (EVar "subps")))))
(DFunDef false "irrefutablePat" (PWild PWild) (EVar "False"))
(DTypeSig false "refutablePat" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "refutablePat" ((PVar "orc") (PVar "p")) (EApp (EVar "not") (EApp (EApp (EVar "irrefutablePat") (EVar "orc")) (EVar "p"))))
(DTypeSig false "refutableField" (TyFun (TyCon "Oracle") (TyFun (TyCon "RecPatField") (TyCon "Bool"))))
(DFunDef false "refutableField" (PWild (PCon "RecPatField" PWild PWild PWild (PCon "None"))) (EVar "False"))
(DFunDef false "refutableField" ((PVar "orc") (PCon "RecPatField" PWild PWild PWild (PCon "Some" (PVar "p")))) (EApp (EApp (EVar "refutablePat") (EVar "orc")) (EVar "p")))
(DTypeSig false "bindMatchTail" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "String") (TyCon "Pat") (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "bindMatchTail" ((PVar "orc") (PVar "stmts")) (EMatch (EApp (EVar "splitTail2") (EVar "stmts")) (arm (PCon "Some" (PTuple (PVar "prefix") (PCon "DoBind" (PCon "PVar" (PVar "v") PWild PWild) (PVar "boundE")) (PCon "DoExpr" (PVar "matchE")))) () (EApp (EApp (EApp (EApp (EApp (EVar "bindMatchArm") (EVar "orc")) (EVar "prefix")) (EVar "v")) (EVar "boundE")) (EApp (EVar "unwrapLoc") (EVar "matchE")))) (arm PWild () (EVar "None"))))
(DTypeSig false "bindMatchArm" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "String") (TyCon "Pat") (TyCon "Expr") (TyCon "Expr")))))))))
(DFunDef false "bindMatchArm" ((PVar "orc") (PVar "prefix") (PVar "v") (PVar "boundE") (PCon "EMatch" (PVar "scrut") (PList (PCon "Arm" (PVar "pat") (PList) (PVar "body"))))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "scrutIsVar") (EVar "v")) (EApp (EVar "unwrapLoc") (EVar "scrut"))) (EApp (EApp (EVar "irrefutablePat") (EVar "orc")) (EVar "pat"))) (EApp (EVar "not") (EApp (EApp (EVar "wholeWordIn") (EVar "v")) (EApp (EVar "exprToString") (EVar "body"))))) (EApp (EVar "Some") (ETuple (EVar "prefix") (EVar "v") (EVar "pat") (EVar "boundE") (EVar "body"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "bindMatchArm" (PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "scrutIsVar" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "scrutIsVar" ((PVar "v") (PCon "EVar" (PVar "w"))) (EBinOp "==" (EVar "v") (EVar "w")))
(DFunDef false "scrutIsVar" (PWild PWild) (EVar "False"))
(DTypeSig false "splitTail2" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "DoStmt") (TyCon "DoStmt")))))
(DFunDef false "splitTail2" ((PVar "stmts")) (EMatch (EApp (EVar "reverseL") (EVar "stmts")) (arm (PCons (PVar "lst") (PCons (PVar "scd") (PVar "restRev"))) () (EApp (EVar "Some") (ETuple (EApp (EVar "reverseL") (EVar "restRev")) (EVar "scd") (EVar "lst")))) (arm PWild () (EVar "None"))))
(DTypeSig false "ruleBindThenDestructure" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleBindThenDestructure" (PWild PWild (PVar "facts") (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "orc") (EApp (EVar "factOracle") (EVar "facts"))) (DoExpr (EApp (EApp (EVar "flatMap") (EApp (EVar "bindDestructureDeclL") (EVar "orc"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))))
(DTypeSig false "bindDestructureDeclL" (TyFun (TyCon "Oracle") (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "bindDestructureDeclL" ((PVar "orc") (PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EVar "map") (EApp (EVar "bindDestructureFinding") (EVar "loc"))) (EApp (EApp (EVar "declBindHits") (EVar "orc")) (EVar "d"))))
(DTypeSig false "declBindHits" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declBindHits" ((PVar "orc") (PCon "DFunDef" PWild PWild PWild (PVar "body") PWild PWild)) (EApp (EApp (EVar "collectBindHits") (EVar "orc")) (EVar "body")))
(DFunDef false "declBindHits" ((PVar "orc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declBindHits") (EVar "orc")) (EVar "d")))
(DFunDef false "declBindHits" (PWild PWild) (EListLit))
(DTypeSig false "bindDestructureFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Finding"))))
(DFunDef false "bindDestructureFinding" ((PVar "loc") (PVar "v")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameBindThenDestructure")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "binds '")) (EVar "v")) (ELit (LString "' then immediately destructures it in a final `match`. Inline the pattern into the bind")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "collectBindHits" (TyFun (TyCon "Oracle") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectBindHits" ((PVar "orc") (PVar "e")) (EBinOp "++" (EApp (EApp (EVar "tailHitOf") (EVar "orc")) (EVar "e")) (EApp (EApp (EVar "flatMap") (EApp (EVar "collectBindHits") (EVar "orc"))) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "tailHitOf" (TyFun (TyCon "Oracle") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tailHitOf" ((PVar "orc") (PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EVar "hitNameOf") (EVar "orc")) (EVar "stmts")))
(DFunDef false "tailHitOf" ((PVar "orc") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "hitNameOf") (EVar "orc")) (EVar "stmts")))
(DFunDef false "tailHitOf" (PWild PWild) (EListLit))
(DTypeSig false "hitNameOf" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "hitNameOf" ((PVar "orc") (PVar "stmts")) (EMatch (EApp (EApp (EVar "bindMatchTail") (EVar "orc")) (EVar "stmts")) (arm (PCon "Some" (PTuple PWild (PVar "v") PWild PWild PWild)) () (EListLit (EVar "v"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "bindThenDestructureFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "bindThenDestructureFix" ((PVar "orc") (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body") (PVar "site") (PVar "bid"))) (EBlock (DoLet false false (PVar "body2") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2")) (EVar "site")) (EVar "bid"))))))))
(DFunDef false "bindThenDestructureFix" ((PVar "orc") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EVar "bindThenDestructureFix") (EVar "orc")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "bindThenDestructureFix" (PWild PWild) (EVar "None"))
(DTypeSig false "rewriteBindExpr" (TyFun (TyCon "Oracle") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "f"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "x"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "b"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ELet" (PVar "m") (PVar "isf") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isf")) (EVar "p")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e1"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e2"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EMatch" (PVar "s") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "s"))) (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindArm") (EVar "orc"))) (EVar "arms"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "c"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "t"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "el"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "a"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "b"))) (EVar "r")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "a"))) (EVar "r")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "a"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "b"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EVar "f")) (EVar "r")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindExpr") (EVar "orc"))) (EVar "es"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindExpr") (EVar "orc"))) (EVar "es"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindExpr") (EVar "orc"))) (EVar "es"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "lo"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "lo"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "lo"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindLet") (EVar "orc"))) (EVar "binds"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "body"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EApp (EVar "rewriteBindSection") (EVar "orc")) (EVar "s"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "EIndex") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "a"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "i"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EHeadAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EApp (EVar "collapseBindTail") (EVar "orc")) (EVar "False")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindStmt") (EVar "orc"))) (EVar "stmts")))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "d")) (EApp (EApp (EApp (EVar "collapseBindTail") (EVar "orc")) (EVar "d")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindStmt") (EVar "orc"))) (EVar "stmts")))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindInterp") (EVar "orc"))) (EVar "parts"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindGuardArm") (EVar "orc"))) (EVar "arms"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindField") (EVar "orc"))) (EVar "fs"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ERecordUpdate" (PVar "e") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindField") (EVar "orc"))) (EVar "fs"))) (EVar "r")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindField") (EVar "orc"))) (EVar "fs"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindKv") (EVar "orc"))) (EVar "kvs"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindExpr") (EVar "orc"))) (EVar "es"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EOrPat" (PVar "es"))) (EApp (EVar "EOrPat") (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindExpr") (EVar "orc"))) (EVar "es"))))
(DFunDef false "rewriteBindExpr" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "collapseBindTail" (TyFun (TyCon "Oracle") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "DoStmt"))))))
(DFunDef false "collapseBindTail" ((PVar "orc") (PVar "host") (PVar "stmts")) (EMatch (EApp (EApp (EVar "bindMatchTail") (EVar "orc")) (EVar "stmts")) (arm (PCon "Some" (PTuple (PVar "prefix") PWild (PVar "pat") (PVar "boundE") (PVar "body"))) () (EBinOp "++" (EVar "prefix") (EBinOp "::" (EApp (EApp (EVar "DoBind") (EVar "pat")) (EVar "boundE")) (EApp (EApp (EVar "bodyToStmts") (EVar "host")) (EVar "body"))))) (arm (PCon "None") () (EVar "stmts"))))
(DTypeSig false "bodyToStmts" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "bodyToStmts" ((PVar "host") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EDo" (PVar "d") (PVar "stmts")) () (EApp (EApp (EApp (EApp (EVar "whenSameHerald") (EVar "host")) (EVar "d")) (EVar "stmts")) (EVar "e"))) (arm (PCon "EBlock" (PVar "stmts")) () (EVar "stmts")) (arm PWild () (EListLit (EApp (EVar "DoExpr") (EVar "e"))))))
(DTypeSig false "whenSameHerald" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "DoStmt")))))))
(DFunDef false "whenSameHerald" ((PVar "host") (PVar "d") (PVar "stmts") (PVar "e")) (EIf (EBinOp "==" (EVar "host") (EVar "d")) (EVar "stmts") (EIf (EVar "otherwise") (EListLit (EApp (EVar "DoExpr") (EVar "e"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "rewriteBindStmt" (TyFun (TyCon "Oracle") (TyFun (TyCon "DoStmt") (TyCon "DoStmt"))))
(DFunDef false "rewriteBindStmt" ((PVar "orc") (PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindStmt" ((PVar "orc") (PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindStmt" ((PVar "orc") (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EVar "site")))
(DFunDef false "rewriteBindStmt" ((PVar "orc") (PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindStmt" ((PVar "orc") (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DTypeSig false "rewriteBindArm" (TyFun (TyCon "Oracle") (TyFun (TyCon "Arm") (TyCon "Arm"))))
(DFunDef false "rewriteBindArm" ((PVar "orc") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindGuard") (EVar "orc"))) (EVar "gs"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "body"))))
(DTypeSig false "rewriteBindGuard" (TyFun (TyCon "Oracle") (TyFun (TyCon "Guard") (TyCon "Guard"))))
(DFunDef false "rewriteBindGuard" ((PVar "orc") (PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindGuard" ((PVar "orc") (PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DTypeSig false "rewriteBindLet" (TyFun (TyCon "Oracle") (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "rewriteBindLet" ((PVar "orc") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindClause") (EVar "orc"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "rewriteBindClause" (TyFun (TyCon "Oracle") (TyFun (TyCon "FunClause") (TyCon "FunClause"))))
(DFunDef false "rewriteBindClause" ((PVar "orc") (PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "body"))))
(DTypeSig false "rewriteBindSection" (TyFun (TyCon "Oracle") (TyFun (TyCon "Section") (TyCon "Section"))))
(DFunDef false "rewriteBindSection" (PWild (PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "rewriteBindSection" ((PVar "orc") (PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindSection" ((PVar "orc") (PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EVar "op")))
(DTypeSig false "rewriteBindInterp" (TyFun (TyCon "Oracle") (TyFun (TyCon "InterpPart") (TyCon "InterpPart"))))
(DFunDef false "rewriteBindInterp" (PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "rewriteBindInterp" ((PVar "orc") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DTypeSig false "rewriteBindGuardArm" (TyFun (TyCon "Oracle") (TyFun (TyCon "GuardArm") (TyCon "GuardArm"))))
(DFunDef false "rewriteBindGuardArm" ((PVar "orc") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EVar "map") (EApp (EVar "rewriteBindGuard") (EVar "orc"))) (EVar "gs"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "body"))))
(DTypeSig false "rewriteBindField" (TyFun (TyCon "Oracle") (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign"))))
(DFunDef false "rewriteBindField" ((PVar "orc") (PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DTypeSig false "rewriteBindKv" (TyFun (TyCon "Oracle") (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "rewriteBindKv" ((PVar "orc") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "k")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "v"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Guard" true) (mem "Arm" true) (mem "DoStmt" true) (mem "Section" true) (mem "InterpPart" true) (mem "GuardArm" true) (mem "FieldAssign" true) (mem "LetBind" true) (mem "FunClause" true) (mem "Expr" true) (mem "Decl" true))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" true))))
(DUse false (UseGroup ("driver" "diagnostics") ((mem "Severity" true))))
(DUse false (UseGroup ("support" "util") ((mem "anyList" false) (mem "reverseL" false))))
(DUse false (UseGroup ("tools" "printer") ((mem "exprToString" false))))
(DUse false (UseGroup ("ir" "sexp") ((mem "exprSexp" false))))
(DUse false (UseGroup ("frontend" "exhaust") ((mem "Oracle" false))))
(DUse false (UseGroup ("tools" "lint_core") ((mem "Category" true) (mem "FileFacts" true) (mem "Finding" true) (mem "Fixability" true) (mem "Ratchet" true) (mem "Rule" false) (mem "RuleMeta" true) (mem "Scope" true) (mem "StdlibIndex" true) (mem "mkRule" false) (mem "factOracle" false))))
(DUse false (UseGroup ("tools" "lint_shared") ((mem "childExprs" false) (mem "ctorIsSingle" false) (mem "declLocList" false) (mem "ruleNameBindThenDestructure" false) (mem "unwrapLoc" false) (mem "wholeWordIn" false))))
(DTypeSig true "rule" (TyCon "Rule"))
(DFunDef false "rule" () (EApp (EApp (EApp (EVar "mkRule") (ERecordCreate "RuleMeta" ((fa "name" (EVar "ruleNameBindThenDestructure")) (fa "summary" (ELit (LString "do-bind then immediately destructures the bound var with an irrefutable single-arm `match`. Inline the pattern into the bind"))) (fa "doc" (ELit (LString "A `do` bind that immediately destructures the bound variable with an irrefutable single-arm `match` can put the pattern in the bind itself.\n\nBefore:\n  p <- getPair\n  match p\n    (a, b) => use a b\nAfter:\n  (a, b) <- getPair\n  use a b"))) (fa "category" (EVar "Style")) (fa "scope" (EVar "Universal")) (fa "ratchet" (EVar "Gated")) (fa "defaultSeverity" (EVar "SevWarning")) (fa "fixability" (EVar "Fixable")) (fa "needs" (EListLit))))) (EVar "ruleBindThenDestructure")) (EApp (EVar "Some") (EVar "bindThenDestructureFix"))))
(DTypeSig false "irrefutablePat" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "irrefutablePat" (PWild (PCon "PVar" PWild PWild PWild)) (EVar "True"))
(DFunDef false "irrefutablePat" (PWild (PCon "PWild")) (EVar "True"))
(DFunDef false "irrefutablePat" ((PVar "orc") (PCon "PTuple" (PVar "ps"))) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "refutablePat") (EVar "orc"))) (EVar "ps"))))
(DFunDef false "irrefutablePat" ((PVar "orc") (PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "refutableField") (EVar "orc"))) (EVar "fields"))))
(DFunDef false "irrefutablePat" ((PVar "orc") (PCon "PCon" (PVar "c") (PVar "subps"))) (EBinOp "&&" (EApp (EApp (EVar "ctorIsSingle") (EVar "orc")) (EVar "c")) (EApp (EVar "not") (EApp (EApp (EVar "anyList") (EApp (EVar "refutablePat") (EVar "orc"))) (EVar "subps")))))
(DFunDef false "irrefutablePat" (PWild PWild) (EVar "False"))
(DTypeSig false "refutablePat" (TyFun (TyCon "Oracle") (TyFun (TyCon "Pat") (TyCon "Bool"))))
(DFunDef false "refutablePat" ((PVar "orc") (PVar "p")) (EApp (EVar "not") (EApp (EApp (EVar "irrefutablePat") (EVar "orc")) (EVar "p"))))
(DTypeSig false "refutableField" (TyFun (TyCon "Oracle") (TyFun (TyCon "RecPatField") (TyCon "Bool"))))
(DFunDef false "refutableField" (PWild (PCon "RecPatField" PWild PWild PWild (PCon "None"))) (EVar "False"))
(DFunDef false "refutableField" ((PVar "orc") (PCon "RecPatField" PWild PWild PWild (PCon "Some" (PVar "p")))) (EApp (EApp (EVar "refutablePat") (EVar "orc")) (EVar "p")))
(DTypeSig false "bindMatchTail" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "String") (TyCon "Pat") (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "bindMatchTail" ((PVar "orc") (PVar "stmts")) (EMatch (EApp (EVar "splitTail2") (EVar "stmts")) (arm (PCon "Some" (PTuple (PVar "prefix") (PCon "DoBind" (PCon "PVar" (PVar "v") PWild PWild) (PVar "boundE")) (PCon "DoExpr" (PVar "matchE")))) () (EApp (EApp (EApp (EApp (EApp (EVar "bindMatchArm") (EVar "orc")) (EVar "prefix")) (EVar "v")) (EVar "boundE")) (EApp (EVar "unwrapLoc") (EVar "matchE")))) (arm PWild () (EVar "None"))))
(DTypeSig false "bindMatchArm" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "String") (TyCon "Pat") (TyCon "Expr") (TyCon "Expr")))))))))
(DFunDef false "bindMatchArm" ((PVar "orc") (PVar "prefix") (PVar "v") (PVar "boundE") (PCon "EMatch" (PVar "scrut") (PList (PCon "Arm" (PVar "pat") (PList) (PVar "body"))))) (EIf (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "scrutIsVar") (EVar "v")) (EApp (EVar "unwrapLoc") (EVar "scrut"))) (EApp (EApp (EVar "irrefutablePat") (EVar "orc")) (EVar "pat"))) (EApp (EVar "not") (EApp (EApp (EVar "wholeWordIn") (EVar "v")) (EApp (EVar "exprToString") (EVar "body"))))) (EApp (EVar "Some") (ETuple (EVar "prefix") (EVar "v") (EVar "pat") (EVar "boundE") (EVar "body"))) (EIf (EVar "otherwise") (EVar "None") (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DFunDef false "bindMatchArm" (PWild PWild PWild PWild PWild) (EVar "None"))
(DTypeSig false "scrutIsVar" (TyFun (TyCon "String") (TyFun (TyCon "Expr") (TyCon "Bool"))))
(DFunDef false "scrutIsVar" ((PVar "v") (PCon "EVar" (PVar "w"))) (EBinOp "==" (EVar "v") (EVar "w")))
(DFunDef false "scrutIsVar" (PWild PWild) (EVar "False"))
(DTypeSig false "splitTail2" (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "Option") (TyTuple (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "DoStmt") (TyCon "DoStmt")))))
(DFunDef false "splitTail2" ((PVar "stmts")) (EMatch (EApp (EVar "reverseL") (EVar "stmts")) (arm (PCons (PVar "lst") (PCons (PVar "scd") (PVar "restRev"))) () (EApp (EVar "Some") (ETuple (EApp (EVar "reverseL") (EVar "restRev")) (EVar "scd") (EVar "lst")))) (arm PWild () (EVar "None"))))
(DTypeSig false "ruleBindThenDestructure" (TyFun (TyCon "StdlibIndex") (TyFun (TyCon "String") (TyFun (TyCon "FileFacts") (TyFun (TyCon "Positions") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Finding"))))))))
(DFunDef false "ruleBindThenDestructure" (PWild PWild (PVar "facts") (PVar "pos") (PVar "prog")) (EBlock (DoLet false false (PVar "orc") (EApp (EVar "factOracle") (EVar "facts"))) (DoExpr (EApp (EApp (EDictApp "flatMap") (EApp (EVar "bindDestructureDeclL") (EVar "orc"))) (EApp (EApp (EVar "declLocList") (EVar "pos")) (EVar "prog"))))))
(DTypeSig false "bindDestructureDeclL" (TyFun (TyCon "Oracle") (TyFun (TyTuple (TyCon "Decl") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyApp (TyCon "List") (TyCon "Finding")))))
(DFunDef false "bindDestructureDeclL" ((PVar "orc") (PTuple (PVar "d") (PVar "loc"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "bindDestructureFinding") (EVar "loc"))) (EApp (EApp (EVar "declBindHits") (EVar "orc")) (EVar "d"))))
(DTypeSig false "declBindHits" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "declBindHits" ((PVar "orc") (PCon "DFunDef" PWild PWild PWild (PVar "body") PWild PWild)) (EApp (EApp (EVar "collectBindHits") (EVar "orc")) (EVar "body")))
(DFunDef false "declBindHits" ((PVar "orc") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declBindHits") (EVar "orc")) (EVar "d")))
(DFunDef false "declBindHits" (PWild PWild) (EListLit))
(DTypeSig false "bindDestructureFinding" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "String") (TyCon "Finding"))))
(DFunDef false "bindDestructureFinding" ((PVar "loc") (PVar "v")) (ERecordCreate "Finding" ((fa "rule" (EVar "ruleNameBindThenDestructure")) (fa "message" (EBinOp "++" (EBinOp "++" (ELit (LString "binds '")) (EVar "v")) (ELit (LString "' then immediately destructures it in a final `match`. Inline the pattern into the bind")))) (fa "severity" (EVar "SevWarning")) (fa "loc" (EVar "loc")))))
(DTypeSig false "collectBindHits" (TyFun (TyCon "Oracle") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "collectBindHits" ((PVar "orc") (PVar "e")) (EBinOp "++" (EApp (EApp (EVar "tailHitOf") (EVar "orc")) (EVar "e")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "collectBindHits") (EVar "orc"))) (EApp (EVar "childExprs") (EVar "e")))))
(DTypeSig false "tailHitOf" (TyFun (TyCon "Oracle") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "tailHitOf" ((PVar "orc") (PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EVar "hitNameOf") (EVar "orc")) (EVar "stmts")))
(DFunDef false "tailHitOf" ((PVar "orc") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "hitNameOf") (EVar "orc")) (EVar "stmts")))
(DFunDef false "tailHitOf" (PWild PWild) (EListLit))
(DTypeSig false "hitNameOf" (TyFun (TyCon "Oracle") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "hitNameOf" ((PVar "orc") (PVar "stmts")) (EMatch (EApp (EApp (EVar "bindMatchTail") (EVar "orc")) (EVar "stmts")) (arm (PCon "Some" (PTuple PWild (PVar "v") PWild PWild PWild)) () (EListLit (EVar "v"))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "bindThenDestructureFix" (TyFun (TyCon "Oracle") (TyFun (TyCon "Decl") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "Decl"))))))
(DFunDef false "bindThenDestructureFix" ((PVar "orc") (PCon "DFunDef" (PVar "vis") (PVar "name") (PVar "pats") (PVar "body") (PVar "site") (PVar "bid"))) (EBlock (DoLet false false (PVar "body2") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "body"))) (DoExpr (EIf (EBinOp "==" (EApp (EVar "exprSexp") (EVar "body2")) (EApp (EVar "exprSexp") (EVar "body"))) (EVar "None") (EApp (EVar "Some") (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "vis")) (EVar "name")) (EVar "pats")) (EVar "body2")) (EVar "site")) (EVar "bid"))))))))
(DFunDef false "bindThenDestructureFix" ((PVar "orc") (PCon "DAttrib" (PVar "a") (PVar "d"))) (EMatch (EApp (EApp (EVar "bindThenDestructureFix") (EVar "orc")) (EVar "d")) (arm (PCon "Some" (PList (PVar "d2"))) () (EApp (EVar "Some") (EListLit (EApp (EApp (EVar "DAttrib") (EVar "a")) (EVar "d2"))))) (arm PWild () (EVar "None"))))
(DFunDef false "bindThenDestructureFix" (PWild PWild) (EVar "None"))
(DTypeSig false "rewriteBindExpr" (TyFun (TyCon "Oracle") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "f"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "x"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "b"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ELet" (PVar "m") (PVar "isf") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "isf")) (EVar "p")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e1"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e2"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EMatch" (PVar "s") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "s"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindArm") (EVar "orc"))) (EVar "arms"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "c"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "t"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "el"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "a"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "b"))) (EVar "r")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "a"))) (EVar "r")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "a"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "b"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EFieldAccess" (PVar "e") (PVar "f") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EVar "f")) (EVar "r")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindExpr") (EVar "orc"))) (EVar "es"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindExpr") (EVar "orc"))) (EVar "es"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindExpr") (EVar "orc"))) (EVar "es"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "lo"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "lo"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") (PVar "i"))) (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "lo"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "hi"))) (EVar "i")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindLet") (EVar "orc"))) (EVar "binds"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "body"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EApp (EVar "rewriteBindSection") (EVar "orc")) (EVar "s"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EIndex" (PVar "a") (PVar "i"))) (EApp (EApp (EVar "EIndex") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "a"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "i"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EHeadAnnot" (PVar "e") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EVar "t")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EApp (EVar "collapseBindTail") (EVar "orc")) (EVar "False")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindStmt") (EVar "orc"))) (EVar "stmts")))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "d")) (EApp (EApp (EApp (EVar "collapseBindTail") (EVar "orc")) (EVar "d")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindStmt") (EVar "orc"))) (EVar "stmts")))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindInterp") (EVar "orc"))) (EVar "parts"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindGuardArm") (EVar "orc"))) (EVar "arms"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindField") (EVar "orc"))) (EVar "fs"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ERecordUpdate" (PVar "e") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindField") (EVar "orc"))) (EVar "fs"))) (EVar "r")))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EVariantUpdate" (PVar "c") (PVar "e") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindField") (EVar "orc"))) (EVar "fs"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindKv") (EVar "orc"))) (EVar "kvs"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindExpr") (EVar "orc"))) (EVar "es"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindExpr" ((PVar "orc") (PCon "EOrPat" (PVar "es"))) (EApp (EVar "EOrPat") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindExpr") (EVar "orc"))) (EVar "es"))))
(DFunDef false "rewriteBindExpr" (PWild (PVar "e")) (EVar "e"))
(DTypeSig false "collapseBindTail" (TyFun (TyCon "Oracle") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "DoStmt"))))))
(DFunDef false "collapseBindTail" ((PVar "orc") (PVar "host") (PVar "stmts")) (EMatch (EApp (EApp (EVar "bindMatchTail") (EVar "orc")) (EVar "stmts")) (arm (PCon "Some" (PTuple (PVar "prefix") PWild (PVar "pat") (PVar "boundE") (PVar "body"))) () (EBinOp "++" (EVar "prefix") (EBinOp "::" (EApp (EApp (EVar "DoBind") (EVar "pat")) (EVar "boundE")) (EApp (EApp (EVar "bodyToStmts") (EVar "host")) (EVar "body"))))) (arm (PCon "None") () (EVar "stmts"))))
(DTypeSig false "bodyToStmts" (TyFun (TyCon "Bool") (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "DoStmt")))))
(DFunDef false "bodyToStmts" ((PVar "host") (PVar "e")) (EMatch (EApp (EVar "unwrapLoc") (EVar "e")) (arm (PCon "EDo" (PVar "d") (PVar "stmts")) () (EApp (EApp (EApp (EApp (EVar "whenSameHerald") (EVar "host")) (EVar "d")) (EVar "stmts")) (EVar "e"))) (arm (PCon "EBlock" (PVar "stmts")) () (EVar "stmts")) (arm PWild () (EListLit (EApp (EVar "DoExpr") (EVar "e"))))))
(DTypeSig false "whenSameHerald" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "DoStmt")))))))
(DFunDef false "whenSameHerald" ((PVar "host") (PVar "d") (PVar "stmts") (PVar "e")) (EIf (EBinOp "==" (EVar "host") (EVar "d")) (EVar "stmts") (EIf (EVar "otherwise") (EListLit (EApp (EVar "DoExpr") (EVar "e"))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "rewriteBindStmt" (TyFun (TyCon "Oracle") (TyFun (TyCon "DoStmt") (TyCon "DoStmt"))))
(DFunDef false "rewriteBindStmt" ((PVar "orc") (PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindStmt" ((PVar "orc") (PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindStmt" ((PVar "orc") (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EVar "site")))
(DFunDef false "rewriteBindStmt" ((PVar "orc") (PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindStmt" ((PVar "orc") (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DTypeSig false "rewriteBindArm" (TyFun (TyCon "Oracle") (TyFun (TyCon "Arm") (TyCon "Arm"))))
(DFunDef false "rewriteBindArm" ((PVar "orc") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindGuard") (EVar "orc"))) (EVar "gs"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "body"))))
(DTypeSig false "rewriteBindGuard" (TyFun (TyCon "Oracle") (TyFun (TyCon "Guard") (TyCon "Guard"))))
(DFunDef false "rewriteBindGuard" ((PVar "orc") (PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindGuard" ((PVar "orc") (PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DTypeSig false "rewriteBindLet" (TyFun (TyCon "Oracle") (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "rewriteBindLet" ((PVar "orc") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindClause") (EVar "orc"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "rewriteBindClause" (TyFun (TyCon "Oracle") (TyFun (TyCon "FunClause") (TyCon "FunClause"))))
(DFunDef false "rewriteBindClause" ((PVar "orc") (PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "body"))))
(DTypeSig false "rewriteBindSection" (TyFun (TyCon "Oracle") (TyFun (TyCon "Section") (TyCon "Section"))))
(DFunDef false "rewriteBindSection" (PWild (PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "rewriteBindSection" ((PVar "orc") (PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DFunDef false "rewriteBindSection" ((PVar "orc") (PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))) (EVar "op")))
(DTypeSig false "rewriteBindInterp" (TyFun (TyCon "Oracle") (TyFun (TyCon "InterpPart") (TyCon "InterpPart"))))
(DFunDef false "rewriteBindInterp" (PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "rewriteBindInterp" ((PVar "orc") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DTypeSig false "rewriteBindGuardArm" (TyFun (TyCon "Oracle") (TyFun (TyCon "GuardArm") (TyCon "GuardArm"))))
(DFunDef false "rewriteBindGuardArm" ((PVar "orc") (PCon "GuardArm" (PVar "gs") (PVar "body"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBindGuard") (EVar "orc"))) (EVar "gs"))) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "body"))))
(DTypeSig false "rewriteBindField" (TyFun (TyCon "Oracle") (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign"))))
(DFunDef false "rewriteBindField" ((PVar "orc") (PCon "FieldAssign" (PVar "n") (PVar "e"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "e"))))
(DTypeSig false "rewriteBindKv" (TyFun (TyCon "Oracle") (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "rewriteBindKv" ((PVar "orc") (PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "k")) (EApp (EApp (EVar "rewriteBindExpr") (EVar "orc")) (EVar "v"))))
