# META
source_lines=318
stages=DESUGAR,MARK
# SOURCE
-- compiler/ir/core_walk.mdk — exhaustive traversal of Core IR: a bottom-up
-- rewrite, a pre-order fold, and the pattern-binder collector.
--
-- Every `CExpr` constructor is named in `mapChildren` and `children`, and
-- neither ends in a catch-all, so a constructor added to `ir/core_ir.mdk` cannot
-- be skipped silently.  The walk visits the expressions a node holds: guard
-- expressions, arm bodies, let-group clause bodies, block statements and record
-- fields.  Patterns, decision trees, routes and call sites are data it carries
-- along unchanged.  A `CDecision` rewrites its scrutinee and its arms; its tree
-- refers to arms by index, and the walk keeps every arm in place, so the tree
-- stays valid.

import frontend.ast.{Pat, patBindings}
import support.ordmap.{OrdMap, omEmpty, omFromNames}
import ir.core_ir.{
  CArm(..),
  CBind(..),
  CClause(..),
  CExpr(..),
  CField(..),
  CGuard(..),
  CImplBody(..),
  CImplEntry(..),
  CProgram(..),
  CStmt(..),
}

-- Rewrite every node bottom-up: a node's children first, then [f] at the node.
export
rewriteExpr : (CExpr -> CExpr) -> CExpr -> CExpr
rewriteExpr f e = f (mapChildren (rewriteExpr f) e)

-- Rewrite every clause body, impl entry body and local binding of a program.
export
rewriteProgram : (CExpr -> CExpr) -> CProgram -> CProgram
rewriteProgram f (CProgram binds ctorArs ctorTypes impls mctx facts) =
  CProgram
    (map (mapBindBodies (rewriteExpr f)) binds)
    ctorArs
    ctorTypes
    (map (rewriteImpl f) impls)
    mctx
    facts

-- Rewrite bottom-up like `rewriteExpr`; [f] also receives the names bound by
-- the binders enclosing the node.  A top-level name is not in the scope, and
-- the binding rules are `core_lint.scopeFaults`'s: a recursive `let` binds its
-- pattern in its own right-hand side, a guard pattern binds for the later
-- guards and the arm body, a let-group name binds in every clause.
export
rewriteExprScoped : (OrdMap Unit -> CExpr -> CExpr) ->
  OrdMap Unit ->
  CExpr ->
  CExpr
rewriteExprScoped f s e = f s (mapChildrenScoped f s e)

-- `rewriteProgram` with the scope: clause and impl parameters seed it.
export
rewriteProgramScoped : (OrdMap Unit -> CExpr -> CExpr) -> CProgram -> CProgram
rewriteProgramScoped f (CProgram binds ctorArs ctorTypes impls mctx facts) =
  CProgram
    (map (scopedBind f omEmpty) binds)
    ctorArs
    ctorTypes
    (map (scopedImpl f) impls)
    mctx
    facts

-- Fold [f] over every node, a node before its children, children left to right.
export
foldExpr : (a -> CExpr -> a) -> a -> CExpr -> a
foldExpr f acc e = fold (foldExpr f) (f acc e) (children e)

-- Every name a pattern binds, in source order: `PRec` puns included, an or-pattern
-- by its first alternative.  Total over `Pat`: `ast.patBindings` names every
-- constructor.
export
patBinders : Pat -> List String
patBinders p = patBindings p

rewriteImpl : (CExpr -> CExpr) -> CImplEntry -> CImplEntry
rewriteImpl f = mapImplBody (_ body => rewriteExpr f body)

-- Rebuild an impl entry with [g] applied to its body; [g] also sees the entry's
-- parameter patterns.
mapImplBody : (List Pat -> CExpr -> CExpr) -> CImplEntry -> CImplEntry
mapImplBody g (CImplEntry n s d (CImplTagged tag key iface sym ps pats body)) =
  CImplEntry n s d (CImplTagged tag key iface sym ps pats (g pats body))
mapImplBody g (CImplEntry n s d (CImplDefault ifaceId tag key sym ps pats body)) =
  CImplEntry n s d (CImplDefault ifaceId tag key sym ps pats (g pats body))

-- One-level rebuild: [g] on each immediate sub-expression.
mapChildren : (CExpr -> CExpr) -> CExpr -> CExpr
mapChildren _ (CLit l) = CLit l
mapChildren _ (CVar x addr) = CVar x addr
mapChildren g (CApp h args site) = CApp (g h) (map g args) site
mapChildren g (CLam pats body) = CLam pats (g body)
mapChildren g (CLet r pat rhs body) = CLet r pat (g rhs) (g body)
mapChildren g (CLetGroup binds body) =
  CLetGroup (map (mapBindBodies g) binds) (g body)
mapChildren g (CMatch scrut arms) = CMatch (g scrut) (map (mapArm g) arms)
mapChildren g (CDecision scrut arms tree) =
  CDecision (g scrut) (map (mapArm g) arms) tree
mapChildren g (CIf c t e) = CIf (g c) (g t) (g e)
mapChildren g (CBinPrim op l r tag site) = CBinPrim op (g l) (g r) tag site
mapChildren g (CUnOp op x) = CUnOp op (g x)
mapChildren g (CTuple es) = CTuple (map g es)
mapChildren g (CList es) = CList (map g es)
mapChildren g (CRecord name fields) = CRecord name (map (mapField g) fields)
mapChildren g (CFieldAccess x label name ord) =
  CFieldAccess (g x) label name ord
mapChildren g (CRecordUpdate name base fields) =
  CRecordUpdate name (g base) (map (mapField g) fields)
mapChildren g (CVariantUpdate con base fields) =
  CVariantUpdate con (g base) (map (mapField g) fields)
mapChildren g (CArray es) = CArray (map g es)
mapChildren g (CRangeList lo hi incl) = CRangeList (g lo) (g hi) incl
mapChildren g (CRangeArray lo hi incl) = CRangeArray (g lo) (g hi) incl
mapChildren g (CBlock stmts) = CBlock (map (mapStmt g) stmts)
mapChildren _ (CMethod name ev) = CMethod name ev
mapChildren _ (CDict name rs) = CDict name rs

mapBindBodies : (CExpr -> CExpr) -> CBind -> CBind
mapBindBodies g (CBind n clauses site bid) =
  CBind n (map (mapClauseBody g) clauses) site bid

mapClauseBody : (CExpr -> CExpr) -> CClause -> CClause
mapClauseBody g (CClause pats body) = CClause pats (g body)

mapArm : (CExpr -> CExpr) -> CArm -> CArm
mapArm g (CArm pat guards body) = CArm pat (map (mapGuard g) guards) (g body)
mapArm g (CArmAlt pat guards owner) =
  CArmAlt pat (map (mapGuard g) guards) owner

mapGuard : (CExpr -> CExpr) -> CGuard -> CGuard
mapGuard g (CGBool e) = CGBool (g e)
mapGuard g (CGBind p e) = CGBind p (g e)

mapStmt : (CExpr -> CExpr) -> CStmt -> CStmt
mapStmt g (CSExpr e) = CSExpr (g e)
mapStmt g (CSLet r pat e) = CSLet r pat (g e)
mapStmt g (CSAssign x e) = CSAssign x (g e)

mapField : (CExpr -> CExpr) -> CField -> CField
mapField g (CField k o e) = CField k o (g e)

-- The immediate sub-expressions, in the order `mapChildren` rebuilds them.
children : CExpr -> List CExpr
children (CLit _) = []
children (CVar _ _) = []
children (CApp h args _) = h :: args
children (CLam _ body) = [body]
children (CLet _ _ rhs body) = [rhs, body]
children (CLetGroup binds body) = flatMap bindBodies binds ++ [body]
children (CMatch scrut arms) = scrut :: flatMap armChildren arms
children (CDecision scrut arms _) = scrut :: flatMap armChildren arms
children (CIf c t e) = [c, t, e]
children (CBinPrim _ l r _ _) = [l, r]
children (CUnOp _ x) = [x]
children (CTuple es) = es
children (CList es) = es
children (CRecord _ fields) = map fieldExpr fields
children (CFieldAccess x _ _ _) = [x]
children (CRecordUpdate _ base fields) = base :: map fieldExpr fields
children (CVariantUpdate _ base fields) = base :: map fieldExpr fields
children (CArray es) = es
children (CRangeList lo hi _) = [lo, hi]
children (CRangeArray lo hi _) = [lo, hi]
children (CBlock stmts) = map stmtExpr stmts
children (CMethod _ _) = []
children (CDict _ _) = []

bindBodies : CBind -> List CExpr
bindBodies (CBind _ clauses _ _) = map clauseBody clauses

export
clauseBody : CClause -> CExpr
clauseBody (CClause _ body) = body

export
bindName : CBind -> String
bindName (CBind n _ _ _) = n

export
bindNames : List CBind -> List String
bindNames binds = map bindName binds

export
implName : CImplEntry -> String
implName (CImplEntry n _ _ _) = n

armChildren : CArm -> List CExpr
armChildren (CArm _ guards body) = map guardExpr guards ++ [body]
armChildren (CArmAlt _ guards _) = map guardExpr guards

guardExpr : CGuard -> CExpr
guardExpr (CGBool e) = e
guardExpr (CGBind _ e) = e

stmtExpr : CStmt -> CExpr
stmtExpr (CSExpr e) = e
stmtExpr (CSLet _ _ e) = e
stmtExpr (CSAssign _ e) = e

fieldExpr : CField -> CExpr
fieldExpr (CField _ _ e) = e

-- The scope extended with every name the patterns bind.
export
bindPats : List Pat -> OrdMap Unit -> OrdMap Unit
bindPats pats scope = omFromNames (flatMap patBinders pats) scope

scopedBind : (OrdMap Unit -> CExpr -> CExpr) -> OrdMap Unit -> CBind -> CBind
scopedBind f s (CBind n clauses site bid) =
  CBind n (map (scopedClause f s) clauses) site bid

scopedClause : (OrdMap Unit -> CExpr -> CExpr) ->
  OrdMap Unit ->
  CClause ->
  CClause
scopedClause f s (CClause pats body) =
  CClause pats (rewriteExprScoped f (bindPats pats s) body)

scopedImpl : (OrdMap Unit -> CExpr -> CExpr) -> CImplEntry -> CImplEntry
scopedImpl f =
  mapImplBody (pats body => rewriteExprScoped f (bindPats pats omEmpty) body)

-- One-level rebuild with the scope each sub-expression sees.
mapChildrenScoped : (OrdMap Unit -> CExpr -> CExpr) ->
  OrdMap Unit ->
  CExpr ->
  CExpr
mapChildrenScoped _ _ (CLit l) = CLit l
mapChildrenScoped _ _ (CVar x addr) = CVar x addr
mapChildrenScoped f s (CApp h args site) =
  CApp (rewriteExprScoped f s h) (map (rewriteExprScoped f s) args) site
mapChildrenScoped f s (CLam pats body) =
  CLam pats (rewriteExprScoped f (bindPats pats s) body)
mapChildrenScoped f s (CLet isRec pat rhs body) =
  let inner = bindPats [pat] s
  CLet
    isRec
    pat
    (rewriteExprScoped f (if isRec then inner else s) rhs)
    (rewriteExprScoped f inner body)
mapChildrenScoped f s (CLetGroup binds body) =
  let inner = omFromNames (bindNames binds) s
  CLetGroup (map (scopedBind f inner) binds) (rewriteExprScoped f inner body)
mapChildrenScoped f s (CMatch scrut arms) =
  CMatch (rewriteExprScoped f s scrut) (map (scopedArm f s) arms)
mapChildrenScoped f s (CDecision scrut arms tree) =
  CDecision (rewriteExprScoped f s scrut) (map (scopedArm f s) arms) tree
mapChildrenScoped f s (CIf c t e) =
  CIf
    (rewriteExprScoped f s c)
    (rewriteExprScoped f s t)
    (rewriteExprScoped f s e)
mapChildrenScoped f s (CBinPrim op l r tag site) =
  CBinPrim op (rewriteExprScoped f s l) (rewriteExprScoped f s r) tag site
mapChildrenScoped f s (CUnOp op x) = CUnOp op (rewriteExprScoped f s x)
mapChildrenScoped f s (CTuple es) = CTuple (map (rewriteExprScoped f s) es)
mapChildrenScoped f s (CList es) = CList (map (rewriteExprScoped f s) es)
mapChildrenScoped f s (CRecord name fields) =
  CRecord name (map (mapField (rewriteExprScoped f s)) fields)
mapChildrenScoped f s (CFieldAccess x label name ord) =
  CFieldAccess (rewriteExprScoped f s x) label name ord
mapChildrenScoped f s (CRecordUpdate name base fields) =
  CRecordUpdate
    name
    (rewriteExprScoped f s base)
    (map (mapField (rewriteExprScoped f s)) fields)
mapChildrenScoped f s (CVariantUpdate con base fields) =
  CVariantUpdate
    con
    (rewriteExprScoped f s base)
    (map (mapField (rewriteExprScoped f s)) fields)
mapChildrenScoped f s (CArray es) = CArray (map (rewriteExprScoped f s) es)
mapChildrenScoped f s (CRangeList lo hi incl) =
  CRangeList (rewriteExprScoped f s lo) (rewriteExprScoped f s hi) incl
mapChildrenScoped f s (CRangeArray lo hi incl) =
  CRangeArray (rewriteExprScoped f s lo) (rewriteExprScoped f s hi) incl
mapChildrenScoped f s (CBlock stmts) = CBlock (scopedStmts f s stmts)
mapChildrenScoped _ _ (CMethod name ev) = CMethod name ev
mapChildrenScoped _ _ (CDict name rs) = CDict name rs

-- A guard pattern binds for the guards after it and for the body.
scopedArm : (OrdMap Unit -> CExpr -> CExpr) -> OrdMap Unit -> CArm -> CArm
scopedArm f s (CArm pat guards body) =
  let (guards2, inner) = scopedGuards f (bindPats [pat] s) guards
  CArm pat guards2 (rewriteExprScoped f inner body)
scopedArm f s (CArmAlt pat guards owner) =
  CArmAlt pat (fst (scopedGuards f (bindPats [pat] s) guards)) owner

scopedGuards : (OrdMap Unit -> CExpr -> CExpr) ->
  OrdMap Unit ->
  List CGuard ->
  (List CGuard, OrdMap Unit)
scopedGuards _ s [] = ([], s)
scopedGuards f s ((CGBool e) :: rest) =
  let (more, out) = scopedGuards f s rest
  (CGBool (rewriteExprScoped f s e) :: more, out)
scopedGuards f s ((CGBind p e) :: rest) =
  let (more, out) = scopedGuards f (bindPats [p] s) rest
  (CGBind p (rewriteExprScoped f s e) :: more, out)

scopedStmts : (OrdMap Unit -> CExpr -> CExpr) ->
  OrdMap Unit ->
  List CStmt ->
  List CStmt
scopedStmts _ _ [] = []
scopedStmts f s ((CSExpr e) :: rest) =
  CSExpr (rewriteExprScoped f s e) :: scopedStmts f s rest
scopedStmts f s ((CSAssign x e) :: rest) =
  CSAssign x (rewriteExprScoped f s e) :: scopedStmts f s rest
scopedStmts f s ((CSLet isRec pat e) :: rest) =
  let inner = bindPats [pat] s
  CSLet isRec pat (rewriteExprScoped f (if isRec then inner else s) e)
    :: scopedStmts f inner rest
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Pat" false) (mem "patBindings" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromNames" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CArm" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CField" true) (mem "CGuard" true) (mem "CImplBody" true) (mem "CImplEntry" true) (mem "CProgram" true) (mem "CStmt" true))))
(DTypeSig true "rewriteExpr" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "rewriteExpr" ((PVar "f") (PVar "e")) (EApp (EVar "f") (EApp (EApp (EVar "mapChildren") (EApp (EVar "rewriteExpr") (EVar "f"))) (EVar "e"))))
(DTypeSig true "rewriteProgram" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CProgram") (TyCon "CProgram"))))
(DFunDef false "rewriteProgram" ((PVar "f") (PCon "CProgram" (PVar "binds") (PVar "ctorArs") (PVar "ctorTypes") (PVar "impls") (PVar "mctx") (PVar "facts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EVar "map") (EApp (EVar "mapBindBodies") (EApp (EVar "rewriteExpr") (EVar "f")))) (EVar "binds"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteImpl") (EVar "f"))) (EVar "impls"))) (EVar "mctx")) (EVar "facts")))
(DTypeSig true "rewriteExprScoped" (TyFun (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr")))))
(DFunDef false "rewriteExprScoped" ((PVar "f") (PVar "s") (PVar "e")) (EApp (EApp (EVar "f") (EVar "s")) (EApp (EApp (EApp (EVar "mapChildrenScoped") (EVar "f")) (EVar "s")) (EVar "e"))))
(DTypeSig true "rewriteProgramScoped" (TyFun (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))) (TyFun (TyCon "CProgram") (TyCon "CProgram"))))
(DFunDef false "rewriteProgramScoped" ((PVar "f") (PCon "CProgram" (PVar "binds") (PVar "ctorArs") (PVar "ctorTypes") (PVar "impls") (PVar "mctx") (PVar "facts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EVar "map") (EApp (EApp (EVar "scopedBind") (EVar "f")) (EVar "omEmpty"))) (EVar "binds"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EApp (EApp (EVar "map") (EApp (EVar "scopedImpl") (EVar "f"))) (EVar "impls"))) (EVar "mctx")) (EVar "facts")))
(DTypeSig true "foldExpr" (TyFun (TyFun (TyVar "a") (TyFun (TyCon "CExpr") (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyCon "CExpr") (TyVar "a")))))
(DFunDef false "foldExpr" ((PVar "f") (PVar "acc") (PVar "e")) (EApp (EApp (EApp (EVar "fold") (EApp (EVar "foldExpr") (EVar "f"))) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "e"))) (EApp (EVar "children") (EVar "e"))))
(DTypeSig true "patBinders" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patBinders" ((PVar "p")) (EApp (EVar "patBindings") (EVar "p")))
(DTypeSig false "rewriteImpl" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "rewriteImpl" ((PVar "f")) (EApp (EVar "mapImplBody") (ELam (PWild (PVar "body")) (EApp (EApp (EVar "rewriteExpr") (EVar "f")) (EVar "body")))))
(DTypeSig false "mapImplBody" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))) (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "mapImplBody" ((PVar "g") (PCon "CImplEntry" (PVar "n") (PVar "s") (PVar "d") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "sym") (PVar "ps") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EVar "d")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "iface")) (EVar "sym")) (EVar "ps")) (EVar "pats")) (EApp (EApp (EVar "g") (EVar "pats")) (EVar "body")))))
(DFunDef false "mapImplBody" ((PVar "g") (PCon "CImplEntry" (PVar "n") (PVar "s") (PVar "d") (PCon "CImplDefault" (PVar "ifaceId") (PVar "tag") (PVar "key") (PVar "sym") (PVar "ps") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EVar "d")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplDefault") (EVar "ifaceId")) (EVar "tag")) (EVar "key")) (EVar "sym")) (EVar "ps")) (EVar "pats")) (EApp (EApp (EVar "g") (EVar "pats")) (EVar "body")))))
(DTypeSig false "mapChildren" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "mapChildren" (PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "mapChildren" (PWild (PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr")))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CApp" (PVar "h") (PVar "args") (PVar "site"))) (EApp (EApp (EApp (EVar "CApp") (EApp (EVar "g") (EVar "h"))) (EApp (EApp (EVar "map") (EVar "g")) (EVar "args"))) (EVar "site")))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EVar "pats")) (EApp (EVar "g") (EVar "body"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CLet" (PVar "r") (PVar "pat") (PVar "rhs") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "r")) (EVar "pat")) (EApp (EVar "g") (EVar "rhs"))) (EApp (EVar "g") (EVar "body"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EVar "map") (EApp (EVar "mapBindBodies") (EVar "g"))) (EVar "binds"))) (EApp (EVar "g") (EVar "body"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "CMatch") (EApp (EVar "g") (EVar "scrut"))) (EApp (EApp (EVar "map") (EApp (EVar "mapArm") (EVar "g"))) (EVar "arms"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EVar "CDecision") (EApp (EVar "g") (EVar "scrut"))) (EApp (EApp (EVar "map") (EApp (EVar "mapArm") (EVar "g"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EVar "g") (EVar "c"))) (EApp (EVar "g") (EVar "t"))) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EVar "g") (EVar "l"))) (EApp (EVar "g") (EVar "r"))) (EVar "tag")) (EVar "site")))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EVar "g") (EVar "x"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EVar "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EVar "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EVar "mapField") (EVar "g"))) (EVar "fields"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CFieldAccess" (PVar "x") (PVar "label") (PVar "name") (PVar "ord"))) (EApp (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EVar "g") (EVar "x"))) (EVar "label")) (EVar "name")) (EVar "ord")))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "name")) (EApp (EVar "g") (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EVar "mapField") (EVar "g"))) (EVar "fields"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EVar "g") (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EVar "mapField") (EVar "g"))) (EVar "fields"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EVar "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EVar "g") (EVar "lo"))) (EApp (EVar "g") (EVar "hi"))) (EVar "incl")))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EVar "g") (EVar "lo"))) (EApp (EVar "g") (EVar "hi"))) (EVar "incl")))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EVar "map") (EApp (EVar "mapStmt") (EVar "g"))) (EVar "stmts"))))
(DFunDef false "mapChildren" (PWild (PCon "CMethod" (PVar "name") (PVar "ev"))) (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "ev")))
(DFunDef false "mapChildren" (PWild (PCon "CDict" (PVar "name") (PVar "rs"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EVar "rs")))
(DTypeSig false "mapBindBodies" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "mapBindBodies" ((PVar "g") (PCon "CBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "CBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "mapClauseBody") (EVar "g"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "mapClauseBody" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CClause") (TyCon "CClause"))))
(DFunDef false "mapClauseBody" ((PVar "g") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EVar "g") (EVar "body"))))
(DTypeSig false "mapArm" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CArm") (TyCon "CArm"))))
(DFunDef false "mapArm" ((PVar "g") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EApp (EApp (EVar "map") (EApp (EVar "mapGuard") (EVar "g"))) (EVar "guards"))) (EApp (EVar "g") (EVar "body"))))
(DFunDef false "mapArm" ((PVar "g") (PCon "CArmAlt" (PVar "pat") (PVar "guards") (PVar "owner"))) (EApp (EApp (EApp (EVar "CArmAlt") (EVar "pat")) (EApp (EApp (EVar "map") (EApp (EVar "mapGuard") (EVar "g"))) (EVar "guards"))) (EVar "owner")))
(DTypeSig false "mapGuard" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CGuard") (TyCon "CGuard"))))
(DFunDef false "mapGuard" ((PVar "g") (PCon "CGBool" (PVar "e"))) (EApp (EVar "CGBool") (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapGuard" ((PVar "g") (PCon "CGBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "CGBind") (EVar "p")) (EApp (EVar "g") (EVar "e"))))
(DTypeSig false "mapStmt" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CStmt") (TyCon "CStmt"))))
(DFunDef false "mapStmt" ((PVar "g") (PCon "CSExpr" (PVar "e"))) (EApp (EVar "CSExpr") (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapStmt" ((PVar "g") (PCon "CSLet" (PVar "r") (PVar "pat") (PVar "e"))) (EApp (EApp (EApp (EVar "CSLet") (EVar "r")) (EVar "pat")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapStmt" ((PVar "g") (PCon "CSAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EVar "g") (EVar "e"))))
(DTypeSig false "mapField" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CField") (TyCon "CField"))))
(DFunDef false "mapField" ((PVar "g") (PCon "CField" (PVar "k") (PVar "o") (PVar "e"))) (EApp (EApp (EApp (EVar "CField") (EVar "k")) (EVar "o")) (EApp (EVar "g") (EVar "e"))))
(DTypeSig false "children" (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "CExpr"))))
(DFunDef false "children" ((PCon "CLit" PWild)) (EListLit))
(DFunDef false "children" ((PCon "CVar" PWild PWild)) (EListLit))
(DFunDef false "children" ((PCon "CApp" (PVar "h") (PVar "args") PWild)) (EBinOp "::" (EVar "h") (EVar "args")))
(DFunDef false "children" ((PCon "CLam" PWild (PVar "body"))) (EListLit (EVar "body")))
(DFunDef false "children" ((PCon "CLet" PWild PWild (PVar "rhs") (PVar "body"))) (EListLit (EVar "rhs") (EVar "body")))
(DFunDef false "children" ((PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "bindBodies")) (EVar "binds")) (EListLit (EVar "body"))))
(DFunDef false "children" ((PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EBinOp "::" (EVar "scrut") (EApp (EApp (EVar "flatMap") (EVar "armChildren")) (EVar "arms"))))
(DFunDef false "children" ((PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EBinOp "::" (EVar "scrut") (EApp (EApp (EVar "flatMap") (EVar "armChildren")) (EVar "arms"))))
(DFunDef false "children" ((PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EListLit (EVar "c") (EVar "t") (EVar "e")))
(DFunDef false "children" ((PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild PWild)) (EListLit (EVar "l") (EVar "r")))
(DFunDef false "children" ((PCon "CUnOp" PWild (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "children" ((PCon "CTuple" (PVar "es"))) (EVar "es"))
(DFunDef false "children" ((PCon "CList" (PVar "es"))) (EVar "es"))
(DFunDef false "children" ((PCon "CRecord" PWild (PVar "fields"))) (EApp (EApp (EVar "map") (EVar "fieldExpr")) (EVar "fields")))
(DFunDef false "children" ((PCon "CFieldAccess" (PVar "x") PWild PWild PWild)) (EListLit (EVar "x")))
(DFunDef false "children" ((PCon "CRecordUpdate" PWild (PVar "base") (PVar "fields"))) (EBinOp "::" (EVar "base") (EApp (EApp (EVar "map") (EVar "fieldExpr")) (EVar "fields"))))
(DFunDef false "children" ((PCon "CVariantUpdate" PWild (PVar "base") (PVar "fields"))) (EBinOp "::" (EVar "base") (EApp (EApp (EVar "map") (EVar "fieldExpr")) (EVar "fields"))))
(DFunDef false "children" ((PCon "CArray" (PVar "es"))) (EVar "es"))
(DFunDef false "children" ((PCon "CRangeList" (PVar "lo") (PVar "hi") PWild)) (EListLit (EVar "lo") (EVar "hi")))
(DFunDef false "children" ((PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EListLit (EVar "lo") (EVar "hi")))
(DFunDef false "children" ((PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EVar "map") (EVar "stmtExpr")) (EVar "stmts")))
(DFunDef false "children" ((PCon "CMethod" PWild PWild)) (EListLit))
(DFunDef false "children" ((PCon "CDict" PWild PWild)) (EListLit))
(DTypeSig false "bindBodies" (TyFun (TyCon "CBind") (TyApp (TyCon "List") (TyCon "CExpr"))))
(DFunDef false "bindBodies" ((PCon "CBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "map") (EVar "clauseBody")) (EVar "clauses")))
(DTypeSig true "clauseBody" (TyFun (TyCon "CClause") (TyCon "CExpr")))
(DFunDef false "clauseBody" ((PCon "CClause" PWild (PVar "body"))) (EVar "body"))
(DTypeSig true "bindName" (TyFun (TyCon "CBind") (TyCon "String")))
(DFunDef false "bindName" ((PCon "CBind" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig true "bindNames" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "bindNames" ((PVar "binds")) (EApp (EApp (EVar "map") (EVar "bindName")) (EVar "binds")))
(DTypeSig true "implName" (TyFun (TyCon "CImplEntry") (TyCon "String")))
(DFunDef false "implName" ((PCon "CImplEntry" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig false "armChildren" (TyFun (TyCon "CArm") (TyApp (TyCon "List") (TyCon "CExpr"))))
(DFunDef false "armChildren" ((PCon "CArm" PWild (PVar "guards") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "map") (EVar "guardExpr")) (EVar "guards")) (EListLit (EVar "body"))))
(DFunDef false "armChildren" ((PCon "CArmAlt" PWild (PVar "guards") PWild)) (EApp (EApp (EVar "map") (EVar "guardExpr")) (EVar "guards")))
(DTypeSig false "guardExpr" (TyFun (TyCon "CGuard") (TyCon "CExpr")))
(DFunDef false "guardExpr" ((PCon "CGBool" (PVar "e"))) (EVar "e"))
(DFunDef false "guardExpr" ((PCon "CGBind" PWild (PVar "e"))) (EVar "e"))
(DTypeSig false "stmtExpr" (TyFun (TyCon "CStmt") (TyCon "CExpr")))
(DFunDef false "stmtExpr" ((PCon "CSExpr" (PVar "e"))) (EVar "e"))
(DFunDef false "stmtExpr" ((PCon "CSLet" PWild PWild (PVar "e"))) (EVar "e"))
(DFunDef false "stmtExpr" ((PCon "CSAssign" PWild (PVar "e"))) (EVar "e"))
(DTypeSig false "fieldExpr" (TyFun (TyCon "CField") (TyCon "CExpr")))
(DFunDef false "fieldExpr" ((PCon "CField" PWild PWild (PVar "e"))) (EVar "e"))
(DTypeSig true "bindPats" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindPats" ((PVar "pats") (PVar "scope")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "flatMap") (EVar "patBinders")) (EVar "pats"))) (EVar "scope")))
(DTypeSig false "scopedBind" (TyFun (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CBind") (TyCon "CBind")))))
(DFunDef false "scopedBind" ((PVar "f") (PVar "s") (PCon "CBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "CBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "scopedClause") (EVar "f")) (EVar "s"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "scopedClause" (TyFun (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CClause") (TyCon "CClause")))))
(DFunDef false "scopedClause" ((PVar "f") (PVar "s") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "s"))) (EVar "body"))))
(DTypeSig false "scopedImpl" (TyFun (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))) (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "scopedImpl" ((PVar "f")) (EApp (EVar "mapImplBody") (ELam ((PVar "pats") (PVar "body")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "omEmpty"))) (EVar "body")))))
(DTypeSig false "mapChildrenScoped" (TyFun (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr")))))
(DFunDef false "mapChildrenScoped" (PWild PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "mapChildrenScoped" (PWild PWild (PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr")))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CApp" (PVar "h") (PVar "args") (PVar "site"))) (EApp (EApp (EApp (EVar "CApp") (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "h"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s"))) (EVar "args"))) (EVar "site")))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EVar "pats")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "s"))) (EVar "body"))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CLet" (PVar "isRec") (PVar "pat") (PVar "rhs") (PVar "body"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindPats") (EListLit (EVar "pat"))) (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "isRec")) (EVar "pat")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EIf (EVar "isRec") (EVar "inner") (EVar "s"))) (EVar "rhs"))) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "inner")) (EVar "body"))))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "omFromNames") (EApp (EVar "bindNames") (EVar "binds"))) (EVar "s"))) (DoExpr (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EVar "map") (EApp (EApp (EVar "scopedBind") (EVar "f")) (EVar "inner"))) (EVar "binds"))) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "inner")) (EVar "body"))))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "CMatch") (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "scrut"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "scopedArm") (EVar "f")) (EVar "s"))) (EVar "arms"))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EVar "CDecision") (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "scrut"))) (EApp (EApp (EVar "map") (EApp (EApp (EVar "scopedArm") (EVar "f")) (EVar "s"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "c"))) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "t"))) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "e"))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "l"))) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "r"))) (EVar "tag")) (EVar "site")))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "x"))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EVar "map") (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s"))) (EVar "es"))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EVar "map") (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s"))) (EVar "es"))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EVar "map") (EApp (EVar "mapField") (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")))) (EVar "fields"))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CFieldAccess" (PVar "x") (PVar "label") (PVar "name") (PVar "ord"))) (EApp (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "x"))) (EVar "label")) (EVar "name")) (EVar "ord")))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "name")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EVar "mapField") (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")))) (EVar "fields"))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "base"))) (EApp (EApp (EVar "map") (EApp (EVar "mapField") (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")))) (EVar "fields"))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EVar "map") (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s"))) (EVar "es"))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "lo"))) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "lo"))) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EApp (EVar "scopedStmts") (EVar "f")) (EVar "s")) (EVar "stmts"))))
(DFunDef false "mapChildrenScoped" (PWild PWild (PCon "CMethod" (PVar "name") (PVar "ev"))) (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "ev")))
(DFunDef false "mapChildrenScoped" (PWild PWild (PCon "CDict" (PVar "name") (PVar "rs"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EVar "rs")))
(DTypeSig false "scopedArm" (TyFun (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CArm") (TyCon "CArm")))))
(DFunDef false "scopedArm" ((PVar "f") (PVar "s") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "guards2") (PVar "inner")) (EApp (EApp (EApp (EVar "scopedGuards") (EVar "f")) (EApp (EApp (EVar "bindPats") (EListLit (EVar "pat"))) (EVar "s"))) (EVar "guards"))) (DoExpr (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EVar "guards2")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "inner")) (EVar "body"))))))
(DFunDef false "scopedArm" ((PVar "f") (PVar "s") (PCon "CArmAlt" (PVar "pat") (PVar "guards") (PVar "owner"))) (EApp (EApp (EApp (EVar "CArmAlt") (EVar "pat")) (EApp (EVar "fst") (EApp (EApp (EApp (EVar "scopedGuards") (EVar "f")) (EApp (EApp (EVar "bindPats") (EListLit (EVar "pat"))) (EVar "s"))) (EVar "guards")))) (EVar "owner")))
(DTypeSig false "scopedGuards" (TyFun (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyTuple (TyApp (TyCon "List") (TyCon "CGuard")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "scopedGuards" (PWild (PVar "s") (PList)) (ETuple (EListLit) (EVar "s")))
(DFunDef false "scopedGuards" ((PVar "f") (PVar "s") (PCons (PCon "CGBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "more") (PVar "out")) (EApp (EApp (EApp (EVar "scopedGuards") (EVar "f")) (EVar "s")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "CGBool") (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "e"))) (EVar "more")) (EVar "out")))))
(DFunDef false "scopedGuards" ((PVar "f") (PVar "s") (PCons (PCon "CGBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "more") (PVar "out")) (EApp (EApp (EApp (EVar "scopedGuards") (EVar "f")) (EApp (EApp (EVar "bindPats") (EListLit (EVar "p"))) (EVar "s"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "CGBind") (EVar "p")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "e"))) (EVar "more")) (EVar "out")))))
(DTypeSig false "scopedStmts" (TyFun (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyApp (TyCon "List") (TyCon "CStmt"))))))
(DFunDef false "scopedStmts" (PWild PWild (PList)) (EListLit))
(DFunDef false "scopedStmts" ((PVar "f") (PVar "s") (PCons (PCon "CSExpr" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "CSExpr") (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "e"))) (EApp (EApp (EApp (EVar "scopedStmts") (EVar "f")) (EVar "s")) (EVar "rest"))))
(DFunDef false "scopedStmts" ((PVar "f") (PVar "s") (PCons (PCon "CSAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "e"))) (EApp (EApp (EApp (EVar "scopedStmts") (EVar "f")) (EVar "s")) (EVar "rest"))))
(DFunDef false "scopedStmts" ((PVar "f") (PVar "s") (PCons (PCon "CSLet" (PVar "isRec") (PVar "pat") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindPats") (EListLit (EVar "pat"))) (EVar "s"))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EVar "CSLet") (EVar "isRec")) (EVar "pat")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EIf (EVar "isRec") (EVar "inner") (EVar "s"))) (EVar "e"))) (EApp (EApp (EApp (EVar "scopedStmts") (EVar "f")) (EVar "inner")) (EVar "rest"))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Pat" false) (mem "patBindings" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromNames" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CArm" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CField" true) (mem "CGuard" true) (mem "CImplBody" true) (mem "CImplEntry" true) (mem "CProgram" true) (mem "CStmt" true))))
(DTypeSig true "rewriteExpr" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "rewriteExpr" ((PVar "f") (PVar "e")) (EApp (EVar "f") (EApp (EApp (EVar "mapChildren") (EApp (EVar "rewriteExpr") (EVar "f"))) (EVar "e"))))
(DTypeSig true "rewriteProgram" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CProgram") (TyCon "CProgram"))))
(DFunDef false "rewriteProgram" ((PVar "f") (PCon "CProgram" (PVar "binds") (PVar "ctorArs") (PVar "ctorTypes") (PVar "impls") (PVar "mctx") (PVar "facts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapBindBodies") (EApp (EVar "rewriteExpr") (EVar "f")))) (EVar "binds"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteImpl") (EVar "f"))) (EVar "impls"))) (EVar "mctx")) (EVar "facts")))
(DTypeSig true "rewriteExprScoped" (TyFun (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr")))))
(DFunDef false "rewriteExprScoped" ((PVar "f") (PVar "s") (PVar "e")) (EApp (EApp (EVar "f") (EVar "s")) (EApp (EApp (EApp (EVar "mapChildrenScoped") (EVar "f")) (EVar "s")) (EVar "e"))))
(DTypeSig true "rewriteProgramScoped" (TyFun (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))) (TyFun (TyCon "CProgram") (TyCon "CProgram"))))
(DFunDef false "rewriteProgramScoped" ((PVar "f") (PCon "CProgram" (PVar "binds") (PVar "ctorArs") (PVar "ctorTypes") (PVar "impls") (PVar "mctx") (PVar "facts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "scopedBind") (EVar "f")) (EVar "omEmpty"))) (EVar "binds"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EApp (EApp (EMethodRef "map") (EApp (EVar "scopedImpl") (EVar "f"))) (EVar "impls"))) (EVar "mctx")) (EVar "facts")))
(DTypeSig true "foldExpr" (TyFun (TyFun (TyVar "a") (TyFun (TyCon "CExpr") (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyCon "CExpr") (TyVar "a")))))
(DFunDef false "foldExpr" ((PVar "f") (PVar "acc") (PVar "e")) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "foldExpr") (EVar "f"))) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "e"))) (EApp (EVar "children") (EVar "e"))))
(DTypeSig true "patBinders" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patBinders" ((PVar "p")) (EApp (EVar "patBindings") (EVar "p")))
(DTypeSig false "rewriteImpl" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "rewriteImpl" ((PVar "f")) (EApp (EVar "mapImplBody") (ELam (PWild (PVar "body")) (EApp (EApp (EVar "rewriteExpr") (EVar "f")) (EVar "body")))))
(DTypeSig false "mapImplBody" (TyFun (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))) (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "mapImplBody" ((PVar "g") (PCon "CImplEntry" (PVar "n") (PVar "s") (PVar "d") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "sym") (PVar "ps") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EVar "d")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "iface")) (EVar "sym")) (EVar "ps")) (EVar "pats")) (EApp (EApp (EVar "g") (EVar "pats")) (EVar "body")))))
(DFunDef false "mapImplBody" ((PVar "g") (PCon "CImplEntry" (PVar "n") (PVar "s") (PVar "d") (PCon "CImplDefault" (PVar "ifaceId") (PVar "tag") (PVar "key") (PVar "sym") (PVar "ps") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EVar "d")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplDefault") (EVar "ifaceId")) (EVar "tag")) (EVar "key")) (EVar "sym")) (EVar "ps")) (EVar "pats")) (EApp (EApp (EVar "g") (EVar "pats")) (EVar "body")))))
(DTypeSig false "mapChildren" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "mapChildren" (PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "mapChildren" (PWild (PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr")))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CApp" (PVar "h") (PVar "args") (PVar "site"))) (EApp (EApp (EApp (EVar "CApp") (EApp (EVar "g") (EVar "h"))) (EApp (EApp (EMethodRef "map") (EVar "g")) (EVar "args"))) (EVar "site")))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EVar "pats")) (EApp (EVar "g") (EVar "body"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CLet" (PVar "r") (PVar "pat") (PVar "rhs") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "r")) (EVar "pat")) (EApp (EVar "g") (EVar "rhs"))) (EApp (EVar "g") (EVar "body"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapBindBodies") (EVar "g"))) (EVar "binds"))) (EApp (EVar "g") (EVar "body"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "CMatch") (EApp (EVar "g") (EVar "scrut"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapArm") (EVar "g"))) (EVar "arms"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EVar "CDecision") (EApp (EVar "g") (EVar "scrut"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapArm") (EVar "g"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EVar "g") (EVar "c"))) (EApp (EVar "g") (EVar "t"))) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EVar "g") (EVar "l"))) (EApp (EVar "g") (EVar "r"))) (EVar "tag")) (EVar "site")))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EVar "g") (EVar "x"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EMethodRef "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EMethodRef "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapField") (EVar "g"))) (EVar "fields"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CFieldAccess" (PVar "x") (PVar "label") (PVar "name") (PVar "ord"))) (EApp (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EVar "g") (EVar "x"))) (EVar "label")) (EVar "name")) (EVar "ord")))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "name")) (EApp (EVar "g") (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapField") (EVar "g"))) (EVar "fields"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EVar "g") (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapField") (EVar "g"))) (EVar "fields"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EMethodRef "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EVar "g") (EVar "lo"))) (EApp (EVar "g") (EVar "hi"))) (EVar "incl")))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EVar "g") (EVar "lo"))) (EApp (EVar "g") (EVar "hi"))) (EVar "incl")))
(DFunDef false "mapChildren" ((PVar "g") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapStmt") (EVar "g"))) (EVar "stmts"))))
(DFunDef false "mapChildren" (PWild (PCon "CMethod" (PVar "name") (PVar "ev"))) (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "ev")))
(DFunDef false "mapChildren" (PWild (PCon "CDict" (PVar "name") (PVar "rs"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EVar "rs")))
(DTypeSig false "mapBindBodies" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "mapBindBodies" ((PVar "g") (PCon "CBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "CBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapClauseBody") (EVar "g"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "mapClauseBody" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CClause") (TyCon "CClause"))))
(DFunDef false "mapClauseBody" ((PVar "g") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EVar "g") (EVar "body"))))
(DTypeSig false "mapArm" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CArm") (TyCon "CArm"))))
(DFunDef false "mapArm" ((PVar "g") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapGuard") (EVar "g"))) (EVar "guards"))) (EApp (EVar "g") (EVar "body"))))
(DFunDef false "mapArm" ((PVar "g") (PCon "CArmAlt" (PVar "pat") (PVar "guards") (PVar "owner"))) (EApp (EApp (EApp (EVar "CArmAlt") (EVar "pat")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapGuard") (EVar "g"))) (EVar "guards"))) (EVar "owner")))
(DTypeSig false "mapGuard" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CGuard") (TyCon "CGuard"))))
(DFunDef false "mapGuard" ((PVar "g") (PCon "CGBool" (PVar "e"))) (EApp (EVar "CGBool") (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapGuard" ((PVar "g") (PCon "CGBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "CGBind") (EVar "p")) (EApp (EVar "g") (EVar "e"))))
(DTypeSig false "mapStmt" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CStmt") (TyCon "CStmt"))))
(DFunDef false "mapStmt" ((PVar "g") (PCon "CSExpr" (PVar "e"))) (EApp (EVar "CSExpr") (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapStmt" ((PVar "g") (PCon "CSLet" (PVar "r") (PVar "pat") (PVar "e"))) (EApp (EApp (EApp (EVar "CSLet") (EVar "r")) (EVar "pat")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapStmt" ((PVar "g") (PCon "CSAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EVar "g") (EVar "e"))))
(DTypeSig false "mapField" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CField") (TyCon "CField"))))
(DFunDef false "mapField" ((PVar "g") (PCon "CField" (PVar "k") (PVar "o") (PVar "e"))) (EApp (EApp (EApp (EVar "CField") (EVar "k")) (EVar "o")) (EApp (EVar "g") (EVar "e"))))
(DTypeSig false "children" (TyFun (TyCon "CExpr") (TyApp (TyCon "List") (TyCon "CExpr"))))
(DFunDef false "children" ((PCon "CLit" PWild)) (EListLit))
(DFunDef false "children" ((PCon "CVar" PWild PWild)) (EListLit))
(DFunDef false "children" ((PCon "CApp" (PVar "h") (PVar "args") PWild)) (EBinOp "::" (EVar "h") (EVar "args")))
(DFunDef false "children" ((PCon "CLam" PWild (PVar "body"))) (EListLit (EVar "body")))
(DFunDef false "children" ((PCon "CLet" PWild PWild (PVar "rhs") (PVar "body"))) (EListLit (EVar "rhs") (EVar "body")))
(DFunDef false "children" ((PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "bindBodies")) (EVar "binds")) (EListLit (EVar "body"))))
(DFunDef false "children" ((PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EBinOp "::" (EVar "scrut") (EApp (EApp (EDictApp "flatMap") (EVar "armChildren")) (EVar "arms"))))
(DFunDef false "children" ((PCon "CDecision" (PVar "scrut") (PVar "arms") PWild)) (EBinOp "::" (EVar "scrut") (EApp (EApp (EDictApp "flatMap") (EVar "armChildren")) (EVar "arms"))))
(DFunDef false "children" ((PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EListLit (EVar "c") (EVar "t") (EVar "e")))
(DFunDef false "children" ((PCon "CBinPrim" PWild (PVar "l") (PVar "r") PWild PWild)) (EListLit (EVar "l") (EVar "r")))
(DFunDef false "children" ((PCon "CUnOp" PWild (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "children" ((PCon "CTuple" (PVar "es"))) (EVar "es"))
(DFunDef false "children" ((PCon "CList" (PVar "es"))) (EVar "es"))
(DFunDef false "children" ((PCon "CRecord" PWild (PVar "fields"))) (EApp (EApp (EMethodRef "map") (EVar "fieldExpr")) (EVar "fields")))
(DFunDef false "children" ((PCon "CFieldAccess" (PVar "x") PWild PWild PWild)) (EListLit (EVar "x")))
(DFunDef false "children" ((PCon "CRecordUpdate" PWild (PVar "base") (PVar "fields"))) (EBinOp "::" (EVar "base") (EApp (EApp (EMethodRef "map") (EVar "fieldExpr")) (EVar "fields"))))
(DFunDef false "children" ((PCon "CVariantUpdate" PWild (PVar "base") (PVar "fields"))) (EBinOp "::" (EVar "base") (EApp (EApp (EMethodRef "map") (EVar "fieldExpr")) (EVar "fields"))))
(DFunDef false "children" ((PCon "CArray" (PVar "es"))) (EVar "es"))
(DFunDef false "children" ((PCon "CRangeList" (PVar "lo") (PVar "hi") PWild)) (EListLit (EVar "lo") (EVar "hi")))
(DFunDef false "children" ((PCon "CRangeArray" (PVar "lo") (PVar "hi") PWild)) (EListLit (EVar "lo") (EVar "hi")))
(DFunDef false "children" ((PCon "CBlock" (PVar "stmts"))) (EApp (EApp (EMethodRef "map") (EVar "stmtExpr")) (EVar "stmts")))
(DFunDef false "children" ((PCon "CMethod" PWild PWild)) (EListLit))
(DFunDef false "children" ((PCon "CDict" PWild PWild)) (EListLit))
(DTypeSig false "bindBodies" (TyFun (TyCon "CBind") (TyApp (TyCon "List") (TyCon "CExpr"))))
(DFunDef false "bindBodies" ((PCon "CBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EMethodRef "map") (EVar "clauseBody")) (EVar "clauses")))
(DTypeSig true "clauseBody" (TyFun (TyCon "CClause") (TyCon "CExpr")))
(DFunDef false "clauseBody" ((PCon "CClause" PWild (PVar "body"))) (EVar "body"))
(DTypeSig true "bindName" (TyFun (TyCon "CBind") (TyCon "String")))
(DFunDef false "bindName" ((PCon "CBind" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig true "bindNames" (TyFun (TyApp (TyCon "List") (TyCon "CBind")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "bindNames" ((PVar "binds")) (EApp (EApp (EMethodRef "map") (EVar "bindName")) (EVar "binds")))
(DTypeSig true "implName" (TyFun (TyCon "CImplEntry") (TyCon "String")))
(DFunDef false "implName" ((PCon "CImplEntry" (PVar "n") PWild PWild PWild)) (EVar "n"))
(DTypeSig false "armChildren" (TyFun (TyCon "CArm") (TyApp (TyCon "List") (TyCon "CExpr"))))
(DFunDef false "armChildren" ((PCon "CArm" PWild (PVar "guards") (PVar "body"))) (EBinOp "++" (EApp (EApp (EMethodRef "map") (EVar "guardExpr")) (EVar "guards")) (EListLit (EVar "body"))))
(DFunDef false "armChildren" ((PCon "CArmAlt" PWild (PVar "guards") PWild)) (EApp (EApp (EMethodRef "map") (EVar "guardExpr")) (EVar "guards")))
(DTypeSig false "guardExpr" (TyFun (TyCon "CGuard") (TyCon "CExpr")))
(DFunDef false "guardExpr" ((PCon "CGBool" (PVar "e"))) (EVar "e"))
(DFunDef false "guardExpr" ((PCon "CGBind" PWild (PVar "e"))) (EVar "e"))
(DTypeSig false "stmtExpr" (TyFun (TyCon "CStmt") (TyCon "CExpr")))
(DFunDef false "stmtExpr" ((PCon "CSExpr" (PVar "e"))) (EVar "e"))
(DFunDef false "stmtExpr" ((PCon "CSLet" PWild PWild (PVar "e"))) (EVar "e"))
(DFunDef false "stmtExpr" ((PCon "CSAssign" PWild (PVar "e"))) (EVar "e"))
(DTypeSig false "fieldExpr" (TyFun (TyCon "CField") (TyCon "CExpr")))
(DFunDef false "fieldExpr" ((PCon "CField" PWild PWild (PVar "e"))) (EVar "e"))
(DTypeSig true "bindPats" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))
(DFunDef false "bindPats" ((PVar "pats") (PVar "scope")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EDictApp "flatMap") (EVar "patBinders")) (EVar "pats"))) (EVar "scope")))
(DTypeSig false "scopedBind" (TyFun (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CBind") (TyCon "CBind")))))
(DFunDef false "scopedBind" ((PVar "f") (PVar "s") (PCon "CBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "CBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "scopedClause") (EVar "f")) (EVar "s"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "scopedClause" (TyFun (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CClause") (TyCon "CClause")))))
(DFunDef false "scopedClause" ((PVar "f") (PVar "s") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "s"))) (EVar "body"))))
(DTypeSig false "scopedImpl" (TyFun (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))) (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "scopedImpl" ((PVar "f")) (EApp (EVar "mapImplBody") (ELam ((PVar "pats") (PVar "body")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "omEmpty"))) (EVar "body")))))
(DTypeSig false "mapChildrenScoped" (TyFun (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr")))))
(DFunDef false "mapChildrenScoped" (PWild PWild (PCon "CLit" (PVar "l"))) (EApp (EVar "CLit") (EVar "l")))
(DFunDef false "mapChildrenScoped" (PWild PWild (PCon "CVar" (PVar "x") (PVar "addr"))) (EApp (EApp (EVar "CVar") (EVar "x")) (EVar "addr")))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CApp" (PVar "h") (PVar "args") (PVar "site"))) (EApp (EApp (EApp (EVar "CApp") (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "h"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s"))) (EVar "args"))) (EVar "site")))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CLam" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CLam") (EVar "pats")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EApp (EApp (EVar "bindPats") (EVar "pats")) (EVar "s"))) (EVar "body"))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CLet" (PVar "isRec") (PVar "pat") (PVar "rhs") (PVar "body"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindPats") (EListLit (EVar "pat"))) (EVar "s"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "CLet") (EVar "isRec")) (EVar "pat")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EIf (EVar "isRec") (EVar "inner") (EVar "s"))) (EVar "rhs"))) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "inner")) (EVar "body"))))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CLetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "omFromNames") (EApp (EVar "bindNames") (EVar "binds"))) (EVar "s"))) (DoExpr (EApp (EApp (EVar "CLetGroup") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "scopedBind") (EVar "f")) (EVar "inner"))) (EVar "binds"))) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "inner")) (EVar "body"))))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CMatch" (PVar "scrut") (PVar "arms"))) (EApp (EApp (EVar "CMatch") (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "scrut"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "scopedArm") (EVar "f")) (EVar "s"))) (EVar "arms"))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CDecision" (PVar "scrut") (PVar "arms") (PVar "tree"))) (EApp (EApp (EApp (EVar "CDecision") (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "scrut"))) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "scopedArm") (EVar "f")) (EVar "s"))) (EVar "arms"))) (EVar "tree")))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CIf" (PVar "c") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "CIf") (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "c"))) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "t"))) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "e"))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CBinPrim" (PVar "op") (PVar "l") (PVar "r") (PVar "tag") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "CBinPrim") (EVar "op")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "l"))) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "r"))) (EVar "tag")) (EVar "site")))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CUnOp" (PVar "op") (PVar "x"))) (EApp (EApp (EVar "CUnOp") (EVar "op")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "x"))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CTuple" (PVar "es"))) (EApp (EVar "CTuple") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s"))) (EVar "es"))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CList" (PVar "es"))) (EApp (EVar "CList") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s"))) (EVar "es"))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CRecord" (PVar "name") (PVar "fields"))) (EApp (EApp (EVar "CRecord") (EVar "name")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapField") (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")))) (EVar "fields"))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CFieldAccess" (PVar "x") (PVar "label") (PVar "name") (PVar "ord"))) (EApp (EApp (EApp (EApp (EVar "CFieldAccess") (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "x"))) (EVar "label")) (EVar "name")) (EVar "ord")))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CRecordUpdate" (PVar "name") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CRecordUpdate") (EVar "name")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapField") (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")))) (EVar "fields"))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CVariantUpdate" (PVar "con") (PVar "base") (PVar "fields"))) (EApp (EApp (EApp (EVar "CVariantUpdate") (EVar "con")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "base"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapField") (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")))) (EVar "fields"))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CArray" (PVar "es"))) (EApp (EVar "CArray") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s"))) (EVar "es"))))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CRangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeList") (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "lo"))) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CRangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "CRangeArray") (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "lo"))) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "mapChildrenScoped" ((PVar "f") (PVar "s") (PCon "CBlock" (PVar "stmts"))) (EApp (EVar "CBlock") (EApp (EApp (EApp (EVar "scopedStmts") (EVar "f")) (EVar "s")) (EVar "stmts"))))
(DFunDef false "mapChildrenScoped" (PWild PWild (PCon "CMethod" (PVar "name") (PVar "ev"))) (EApp (EApp (EVar "CMethod") (EVar "name")) (EVar "ev")))
(DFunDef false "mapChildrenScoped" (PWild PWild (PCon "CDict" (PVar "name") (PVar "rs"))) (EApp (EApp (EVar "CDict") (EVar "name")) (EVar "rs")))
(DTypeSig false "scopedArm" (TyFun (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CArm") (TyCon "CArm")))))
(DFunDef false "scopedArm" ((PVar "f") (PVar "s") (PCon "CArm" (PVar "pat") (PVar "guards") (PVar "body"))) (EBlock (DoLet false false (PTuple (PVar "guards2") (PVar "inner")) (EApp (EApp (EApp (EVar "scopedGuards") (EVar "f")) (EApp (EApp (EVar "bindPats") (EListLit (EVar "pat"))) (EVar "s"))) (EVar "guards"))) (DoExpr (EApp (EApp (EApp (EVar "CArm") (EVar "pat")) (EVar "guards2")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "inner")) (EVar "body"))))))
(DFunDef false "scopedArm" ((PVar "f") (PVar "s") (PCon "CArmAlt" (PVar "pat") (PVar "guards") (PVar "owner"))) (EApp (EApp (EApp (EVar "CArmAlt") (EVar "pat")) (EApp (EVar "fst") (EApp (EApp (EApp (EVar "scopedGuards") (EVar "f")) (EApp (EApp (EVar "bindPats") (EListLit (EVar "pat"))) (EVar "s"))) (EVar "guards")))) (EVar "owner")))
(DTypeSig false "scopedGuards" (TyFun (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CGuard")) (TyTuple (TyApp (TyCon "List") (TyCon "CGuard")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "scopedGuards" (PWild (PVar "s") (PList)) (ETuple (EListLit) (EVar "s")))
(DFunDef false "scopedGuards" ((PVar "f") (PVar "s") (PCons (PCon "CGBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "more") (PVar "out")) (EApp (EApp (EApp (EVar "scopedGuards") (EVar "f")) (EVar "s")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "CGBool") (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "e"))) (EVar "more")) (EVar "out")))))
(DFunDef false "scopedGuards" ((PVar "f") (PVar "s") (PCons (PCon "CGBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PTuple (PVar "more") (PVar "out")) (EApp (EApp (EApp (EVar "scopedGuards") (EVar "f")) (EApp (EApp (EVar "bindPats") (EListLit (EVar "p"))) (EVar "s"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "CGBind") (EVar "p")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "e"))) (EVar "more")) (EVar "out")))))
(DTypeSig false "scopedStmts" (TyFun (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyApp (TyCon "List") (TyCon "CStmt")) (TyApp (TyCon "List") (TyCon "CStmt"))))))
(DFunDef false "scopedStmts" (PWild PWild (PList)) (EListLit))
(DFunDef false "scopedStmts" ((PVar "f") (PVar "s") (PCons (PCon "CSExpr" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "CSExpr") (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "e"))) (EApp (EApp (EApp (EVar "scopedStmts") (EVar "f")) (EVar "s")) (EVar "rest"))))
(DFunDef false "scopedStmts" ((PVar "f") (PVar "s") (PCons (PCon "CSAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "CSAssign") (EVar "x")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EVar "s")) (EVar "e"))) (EApp (EApp (EApp (EVar "scopedStmts") (EVar "f")) (EVar "s")) (EVar "rest"))))
(DFunDef false "scopedStmts" ((PVar "f") (PVar "s") (PCons (PCon "CSLet" (PVar "isRec") (PVar "pat") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "inner") (EApp (EApp (EVar "bindPats") (EListLit (EVar "pat"))) (EVar "s"))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EVar "CSLet") (EVar "isRec")) (EVar "pat")) (EApp (EApp (EApp (EVar "rewriteExprScoped") (EVar "f")) (EIf (EVar "isRec") (EVar "inner") (EVar "s"))) (EVar "e"))) (EApp (EApp (EApp (EVar "scopedStmts") (EVar "f")) (EVar "inner")) (EVar "rest"))))))
