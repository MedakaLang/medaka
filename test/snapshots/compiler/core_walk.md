# META
source_lines=174
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
    (map (rewriteBind f) binds)
    ctorArs
    ctorTypes
    (map (rewriteImpl f) impls)
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

rewriteBind : (CExpr -> CExpr) -> CBind -> CBind
rewriteBind f (CBind n clauses site bid) =
  CBind n (map (rewriteClause f) clauses) site bid

rewriteClause : (CExpr -> CExpr) -> CClause -> CClause
rewriteClause f (CClause pats body) = CClause pats (rewriteExpr f body)

rewriteImpl : (CExpr -> CExpr) -> CImplEntry -> CImplEntry
rewriteImpl f (CImplEntry n s d (CImplTagged tag key iface sym ps pats body)) =
  CImplEntry n s d (CImplTagged tag key iface sym ps pats (rewriteExpr f body))
rewriteImpl f (CImplEntry n s d (CImplDefault ifaceId tag key sym ps pats body)) =
  CImplEntry
    n
    s
    d
    (CImplDefault ifaceId tag key sym ps pats (rewriteExpr f body))

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

clauseBody : CClause -> CExpr
clauseBody (CClause _ body) = body

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
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Pat" false) (mem "patBindings" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CArm" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CField" true) (mem "CGuard" true) (mem "CImplBody" true) (mem "CImplEntry" true) (mem "CProgram" true) (mem "CStmt" true))))
(DTypeSig true "rewriteExpr" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "rewriteExpr" ((PVar "f") (PVar "e")) (EApp (EVar "f") (EApp (EApp (EVar "mapChildren") (EApp (EVar "rewriteExpr") (EVar "f"))) (EVar "e"))))
(DTypeSig true "rewriteProgram" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CProgram") (TyCon "CProgram"))))
(DFunDef false "rewriteProgram" ((PVar "f") (PCon "CProgram" (PVar "binds") (PVar "ctorArs") (PVar "ctorTypes") (PVar "impls") (PVar "mctx") (PVar "facts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EVar "map") (EApp (EVar "rewriteBind") (EVar "f"))) (EVar "binds"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteImpl") (EVar "f"))) (EVar "impls"))) (EVar "mctx")) (EVar "facts")))
(DTypeSig true "foldExpr" (TyFun (TyFun (TyVar "a") (TyFun (TyCon "CExpr") (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyCon "CExpr") (TyVar "a")))))
(DFunDef false "foldExpr" ((PVar "f") (PVar "acc") (PVar "e")) (EApp (EApp (EApp (EVar "fold") (EApp (EVar "foldExpr") (EVar "f"))) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "e"))) (EApp (EVar "children") (EVar "e"))))
(DTypeSig true "patBinders" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patBinders" ((PVar "p")) (EApp (EVar "patBindings") (EVar "p")))
(DTypeSig false "rewriteBind" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "rewriteBind" ((PVar "f") (PCon "CBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "CBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "rewriteClause") (EVar "f"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "rewriteClause" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CClause") (TyCon "CClause"))))
(DFunDef false "rewriteClause" ((PVar "f") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EApp (EVar "rewriteExpr") (EVar "f")) (EVar "body"))))
(DTypeSig false "rewriteImpl" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "rewriteImpl" ((PVar "f") (PCon "CImplEntry" (PVar "n") (PVar "s") (PVar "d") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "sym") (PVar "ps") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EVar "d")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "iface")) (EVar "sym")) (EVar "ps")) (EVar "pats")) (EApp (EApp (EVar "rewriteExpr") (EVar "f")) (EVar "body")))))
(DFunDef false "rewriteImpl" ((PVar "f") (PCon "CImplEntry" (PVar "n") (PVar "s") (PVar "d") (PCon "CImplDefault" (PVar "ifaceId") (PVar "tag") (PVar "key") (PVar "sym") (PVar "ps") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EVar "d")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplDefault") (EVar "ifaceId")) (EVar "tag")) (EVar "key")) (EVar "sym")) (EVar "ps")) (EVar "pats")) (EApp (EApp (EVar "rewriteExpr") (EVar "f")) (EVar "body")))))
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
(DTypeSig false "clauseBody" (TyFun (TyCon "CClause") (TyCon "CExpr")))
(DFunDef false "clauseBody" ((PCon "CClause" PWild (PVar "body"))) (EVar "body"))
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
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Pat" false) (mem "patBindings" false))))
(DUse false (UseGroup ("ir" "core_ir") ((mem "CArm" true) (mem "CBind" true) (mem "CClause" true) (mem "CExpr" true) (mem "CField" true) (mem "CGuard" true) (mem "CImplBody" true) (mem "CImplEntry" true) (mem "CProgram" true) (mem "CStmt" true))))
(DTypeSig true "rewriteExpr" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CExpr") (TyCon "CExpr"))))
(DFunDef false "rewriteExpr" ((PVar "f") (PVar "e")) (EApp (EVar "f") (EApp (EApp (EVar "mapChildren") (EApp (EVar "rewriteExpr") (EVar "f"))) (EVar "e"))))
(DTypeSig true "rewriteProgram" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CProgram") (TyCon "CProgram"))))
(DFunDef false "rewriteProgram" ((PVar "f") (PCon "CProgram" (PVar "binds") (PVar "ctorArs") (PVar "ctorTypes") (PVar "impls") (PVar "mctx") (PVar "facts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CProgram") (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteBind") (EVar "f"))) (EVar "binds"))) (EVar "ctorArs")) (EVar "ctorTypes")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteImpl") (EVar "f"))) (EVar "impls"))) (EVar "mctx")) (EVar "facts")))
(DTypeSig true "foldExpr" (TyFun (TyFun (TyVar "a") (TyFun (TyCon "CExpr") (TyVar "a"))) (TyFun (TyVar "a") (TyFun (TyCon "CExpr") (TyVar "a")))))
(DFunDef false "foldExpr" ((PVar "f") (PVar "acc") (PVar "e")) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "foldExpr") (EVar "f"))) (EApp (EApp (EVar "f") (EVar "acc")) (EVar "e"))) (EApp (EVar "children") (EVar "e"))))
(DTypeSig true "patBinders" (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "patBinders" ((PVar "p")) (EApp (EVar "patBindings") (EVar "p")))
(DTypeSig false "rewriteBind" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CBind") (TyCon "CBind"))))
(DFunDef false "rewriteBind" ((PVar "f") (PCon "CBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "CBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "rewriteClause") (EVar "f"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "rewriteClause" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CClause") (TyCon "CClause"))))
(DFunDef false "rewriteClause" ((PVar "f") (PCon "CClause" (PVar "pats") (PVar "body"))) (EApp (EApp (EVar "CClause") (EVar "pats")) (EApp (EApp (EVar "rewriteExpr") (EVar "f")) (EVar "body"))))
(DTypeSig false "rewriteImpl" (TyFun (TyFun (TyCon "CExpr") (TyCon "CExpr")) (TyFun (TyCon "CImplEntry") (TyCon "CImplEntry"))))
(DFunDef false "rewriteImpl" ((PVar "f") (PCon "CImplEntry" (PVar "n") (PVar "s") (PVar "d") (PCon "CImplTagged" (PVar "tag") (PVar "key") (PVar "iface") (PVar "sym") (PVar "ps") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EVar "d")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplTagged") (EVar "tag")) (EVar "key")) (EVar "iface")) (EVar "sym")) (EVar "ps")) (EVar "pats")) (EApp (EApp (EVar "rewriteExpr") (EVar "f")) (EVar "body")))))
(DFunDef false "rewriteImpl" ((PVar "f") (PCon "CImplEntry" (PVar "n") (PVar "s") (PVar "d") (PCon "CImplDefault" (PVar "ifaceId") (PVar "tag") (PVar "key") (PVar "sym") (PVar "ps") (PVar "pats") (PVar "body")))) (EApp (EApp (EApp (EApp (EVar "CImplEntry") (EVar "n")) (EVar "s")) (EVar "d")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "CImplDefault") (EVar "ifaceId")) (EVar "tag")) (EVar "key")) (EVar "sym")) (EVar "ps")) (EVar "pats")) (EApp (EApp (EVar "rewriteExpr") (EVar "f")) (EVar "body")))))
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
(DTypeSig false "clauseBody" (TyFun (TyCon "CClause") (TyCon "CExpr")))
(DFunDef false "clauseBody" ((PCon "CClause" PWild (PVar "body"))) (EVar "body"))
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
