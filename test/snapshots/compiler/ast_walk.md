# META
source_lines=411
stages=DESUGAR,MARK
# SOURCE
-- compiler/frontend/ast_walk.mdk — exhaustive traversal of the raw (pre-desugar)
-- AST: a node's kind, its immediate sub-expressions and their one-level rebuild,
-- every expression body a declaration holds (named by its owner), and a node's
-- span derived from its `ELoc` leaves.
--
-- Every constructor of `Expr`, `Decl`, `DoStmt`, `Arm`, `Guard`, `GuardArm`,
-- `Section`, `InterpPart`, `LetBind`, `FunClause` and `FieldAssign` is named
-- here, leaves included, and no function ends in a catch-all.  Exhaustiveness
-- is only a warning, so `ast_walk_test.mdk` fails when `medaka check` of this
-- module reports one: a constructor added to `frontend/ast.mdk` cannot be
-- skipped silently.  There is no `Stmt` type; `DoStmt` is the statement form.

import frontend.ast.{
  Arm(..),
  Decl(..),
  DoStmt(..),
  Expr(..),
  FieldAssign(..),
  FunClause(..),
  Guard(..),
  GuardArm(..),
  IfaceMethod(..),
  ImplMethod(..),
  InterpPart(..),
  LetBind(..),
  Loc(..),
  MethodDefault(..),
  Pat,
  PropParam,
  Section(..),
}

-- lint-disable-file rule-duplicate-body
-- The one-level rebuilders below are structural twins of frontend.desugar's
-- mapChildren family; desugar adopts this module in #4649, where the move gets
-- its own Ir measurement (desugar maps EAsPat/EOrPat as identity).

-- One constructor per `Expr` constructor, for selecting nodes by kind.
public export data ExprKind =
  | KLit
  | KVar
  | KApp
  | KLam
  | KLet
  | KMatch
  | KIf
  | KBinOp
  | KUnOp
  | KInfix
  | KFieldAccess
  | KTuple
  | KListLit
  | KArrayLit
  | KRangeList
  | KRangeArray
  | KSlice
  | KLetGroup
  | KSection
  | KIndex
  | KAnnot
  | KHeadAnnot
  | KBlock
  | KDo
  | KStringInterp
  | KGuards
  | KRecordCreate
  | KRecordUpdate
  | KVariantUpdate
  | KMapLit
  | KSetLit
  | KAsPat
  | KOrPat
  | KMethodRef
  | KDictApp
  | KVarAt
  | KVarId
  | KMethodAt
  | KDictAt
  | KLoc
  | KDoOrigin
  | KNumLit
  | KWideLit
  deriving (Eq, Debug)

export
exprKind : Expr -> ExprKind
exprKind (ELit _) = KLit
exprKind (EVar _) = KVar
exprKind (EApp _ _) = KApp
exprKind (ELam _ _) = KLam
exprKind (ELet _ _ _ _ _) = KLet
exprKind (EMatch _ _) = KMatch
exprKind (EIf _ _ _) = KIf
exprKind (EBinOp _ _ _ _) = KBinOp
exprKind (EUnOp _ _ _) = KUnOp
exprKind (EInfix _ _ _) = KInfix
exprKind (EFieldAccess _ _ _) = KFieldAccess
exprKind (ETuple _) = KTuple
exprKind (EListLit _) = KListLit
exprKind (EArrayLit _) = KArrayLit
exprKind (ERangeList _ _ _) = KRangeList
exprKind (ERangeArray _ _ _) = KRangeArray
exprKind (ESlice _ _ _ _) = KSlice
exprKind (ELetGroup _ _) = KLetGroup
exprKind (ESection _) = KSection
exprKind (EIndex _ _) = KIndex
exprKind (EAnnot _ _) = KAnnot
exprKind (EHeadAnnot _ _) = KHeadAnnot
exprKind (EBlock _) = KBlock
exprKind (EDo _ _) = KDo
exprKind (EStringInterp _) = KStringInterp
exprKind (EGuards _) = KGuards
exprKind (ERecordCreate _ _) = KRecordCreate
exprKind (ERecordUpdate _ _ _) = KRecordUpdate
exprKind (EVariantUpdate _ _ _) = KVariantUpdate
exprKind (EMapLit _ _) = KMapLit
exprKind (ESetLit _ _) = KSetLit
exprKind (EAsPat _ _) = KAsPat
exprKind (EOrPat _) = KOrPat
exprKind (EMethodRef _) = KMethodRef
exprKind (EDictApp _) = KDictApp
exprKind (EVarAt _ _) = KVarAt
exprKind (EVarId _ _) = KVarId
exprKind (EMethodAt _ _ _) = KMethodAt
exprKind (EDictAt _ _) = KDictAt
exprKind (ELoc _ _) = KLoc
exprKind (EDoOrigin _ _) = KDoOrigin
exprKind (ENumLit _ _ _) = KNumLit
exprKind (EWideLit _ _ _ _) = KWideLit

-- The immediate sub-expressions of a node, in source order.
export
childExprs : Expr -> List Expr
childExprs (ELit _) = []
childExprs (EVar _) = []
childExprs (EApp f x) = [f, x]
childExprs (ELam _ b) = [b]
childExprs (ELet _ _ _ e1 e2) = [e1, e2]
childExprs (EMatch s arms) = s :: flatMap armExprs arms
childExprs (EIf c t el) = [c, t, el]
childExprs (EBinOp _ a b _) = [a, b]
childExprs (EUnOp _ a _) = [a]
childExprs (EInfix _ a b) = [a, b]
childExprs (EFieldAccess e _ _) = [e]
childExprs (ETuple es) = es
childExprs (EListLit es) = es
childExprs (EArrayLit es) = es
childExprs (ERangeList lo hi _) = [lo, hi]
childExprs (ERangeArray lo hi _) = [lo, hi]
childExprs (ESlice e lo hi _) = [e, lo, hi]
childExprs (ELetGroup binds body) = flatMap letBindExprs binds ++ [body]
childExprs (ESection s) = sectionExprs s
childExprs (EIndex a i) = [a, i]
childExprs (EAnnot e _) = [e]
childExprs (EHeadAnnot e _) = [e]
childExprs (EBlock stmts) = flatMap stmtExprs stmts
childExprs (EDo _ stmts) = flatMap stmtExprs stmts
childExprs (EStringInterp parts) = flatMap interpPartExprs parts
childExprs (EGuards arms) = flatMap guardArmExprs arms
childExprs (ERecordCreate _ fs) = map fieldAssignExpr fs
childExprs (ERecordUpdate e fs _) = e :: map fieldAssignExpr fs
childExprs (EVariantUpdate _ e fs) = e :: map fieldAssignExpr fs
childExprs (EMapLit _ kvs) = flatMap kvExprs kvs
childExprs (ESetLit _ es) = es
childExprs (EAsPat _ e) = [e]
childExprs (EOrPat es) = es
childExprs (EMethodRef _) = []
childExprs (EDictApp _) = []
childExprs (EVarAt _ _) = []
childExprs (EVarId _ _) = []
childExprs (EMethodAt _ _ _) = []
childExprs (EDictAt _ _) = []
childExprs (ELoc _ e) = [e]
childExprs (EDoOrigin _ e) = [e]
childExprs (ENumLit _ _ _) = []
childExprs (EWideLit _ _ _ _) = []

armExprs : Arm -> List Expr
armExprs (Arm _ gs body) = flatMap guardExprs gs ++ [body]

guardExprs : Guard -> List Expr
guardExprs (GBool e) = [e]
guardExprs (GBind _ e) = [e]

export
stmtExprs : DoStmt -> List Expr
stmtExprs (DoExpr e) = [e]
stmtExprs (DoBind _ e) = [e]
stmtExprs (DoLet _ _ _ e _) = [e]
stmtExprs (DoAssign _ e) = [e]
stmtExprs (DoFieldAssign _ _ e) = [e]

letBindExprs : LetBind -> List Expr
letBindExprs (LetBind _ clauses _ _) = map ((FunClause _ body) => body) clauses

sectionExprs : Section -> List Expr
sectionExprs (SecBare _) = []
sectionExprs (SecRight _ e) = [e]
sectionExprs (SecLeft e _) = [e]

interpPartExprs : InterpPart -> List Expr
interpPartExprs (InterpStr _) = []
interpPartExprs (InterpExpr e) = [e]

guardArmExprs : GuardArm -> List Expr
guardArmExprs (GuardArm gs body) = flatMap guardExprs gs ++ [body]

fieldAssignExpr : FieldAssign -> Expr
fieldAssignExpr (FieldAssign _ e) = e

kvExprs : (Expr, Expr) -> List Expr
kvExprs (k, v) = [k, v]

-- Rebuild a node with `g` applied to each immediate sub-expression, recursing
-- no further; every other field, `ELoc` spans included, is kept.
export
mapChildExprs : (Expr -> Expr) -> Expr -> Expr
mapChildExprs _ (ELit l) = ELit l
mapChildExprs _ (EVar n) = EVar n
mapChildExprs g (EApp a b) = EApp (g a) (g b)
mapChildExprs g (ELam ps b) = ELam ps (g b)
mapChildExprs g (ELet m r p e1 e2) = ELet m r p (g e1) (g e2)
mapChildExprs g (EMatch e0 arms) = EMatch (g e0) (map (mapArm g) arms)
mapChildExprs g (EIf c t el) = EIf (g c) (g t) (g el)
mapChildExprs g (EBinOp op a b r) = EBinOp op (g a) (g b) r
mapChildExprs g (EUnOp op a r) = EUnOp op (g a) r
mapChildExprs g (EInfix op a b) = EInfix op (g a) (g b)
mapChildExprs g (EFieldAccess e0 n r) = EFieldAccess (g e0) n r
mapChildExprs g (ETuple es) = ETuple (map g es)
mapChildExprs g (EListLit es) = EListLit (map g es)
mapChildExprs g (EArrayLit es) = EArrayLit (map g es)
mapChildExprs g (ERangeList lo hi incl) = ERangeList (g lo) (g hi) incl
mapChildExprs g (ERangeArray lo hi incl) = ERangeArray (g lo) (g hi) incl
mapChildExprs g (ESlice e0 lo hi incl) = ESlice (g e0) (g lo) (g hi) incl
mapChildExprs g (ELetGroup bs e2) = ELetGroup (map (mapLetBind g) bs) (g e2)
mapChildExprs g (ESection s) = ESection (mapSection g s)
mapChildExprs g (EIndex e0 i) = EIndex (g e0) (g i)
mapChildExprs g (EAnnot e0 t) = EAnnot (g e0) t
mapChildExprs g (EHeadAnnot e0 t) = EHeadAnnot (g e0) t
mapChildExprs g (EBlock stmts) = EBlock (map (mapDoStmt g) stmts)
mapChildExprs g (EDo d stmts) = EDo d (map (mapDoStmt g) stmts)
mapChildExprs g (EStringInterp parts) = EStringInterp (map (mapInterp g) parts)
mapChildExprs g (EGuards arms) = EGuards (map (mapGuardArm g) arms)
mapChildExprs g (ERecordCreate n fs) =
  ERecordCreate n (map (mapFieldAssign g) fs)
mapChildExprs g (ERecordUpdate e0 fs r) =
  ERecordUpdate (g e0) (map (mapFieldAssign g) fs) r
mapChildExprs g (EVariantUpdate c e0 fs) =
  EVariantUpdate c (g e0) (map (mapFieldAssign g) fs)
mapChildExprs g (EMapLit n kvs) =
  EMapLit n (map (kv => (g (fst kv), g (snd kv))) kvs)
mapChildExprs g (ESetLit n es) = ESetLit n (map g es)
mapChildExprs g (EAsPat x e) = EAsPat x (g e)
mapChildExprs g (EOrPat es) = EOrPat (map g es)
mapChildExprs _ (EMethodRef n) = EMethodRef n
mapChildExprs _ (EDictApp n) = EDictApp n
mapChildExprs _ (EVarAt n a) = EVarAt n a
mapChildExprs _ (EVarId n i) = EVarId n i
mapChildExprs _ (EMethodAt n s ev) = EMethodAt n s ev
mapChildExprs _ (EDictAt n ev) = EDictAt n ev
mapChildExprs g (ELoc l e) = ELoc l (g e)
mapChildExprs g (EDoOrigin l e) = EDoOrigin l (g e)
mapChildExprs _ (ENumLit n ev lexeme) = ENumLit n ev lexeme
mapChildExprs _ (EWideLit hi lo ev lexeme) = EWideLit hi lo ev lexeme

mapArm : (Expr -> Expr) -> Arm -> Arm
mapArm g (Arm p gs b) = Arm p (map (mapGuard g) gs) (g b)

mapGuard : (Expr -> Expr) -> Guard -> Guard
mapGuard g (GBool e) = GBool (g e)
mapGuard g (GBind p e) = GBind p (g e)

mapGuardArm : (Expr -> Expr) -> GuardArm -> GuardArm
mapGuardArm g (GuardArm gs b) = GuardArm (map (mapGuard g) gs) (g b)

mapLetBind : (Expr -> Expr) -> LetBind -> LetBind
mapLetBind g (LetBind n clauses site bid) =
  LetBind n (map (mapFunClause g) clauses) site bid

mapFunClause : (Expr -> Expr) -> FunClause -> FunClause
mapFunClause g (FunClause ps b) = FunClause ps (g b)

mapSection : (Expr -> Expr) -> Section -> Section
mapSection _ (SecBare op) = SecBare op
mapSection g (SecRight op e) = SecRight op (g e)
mapSection g (SecLeft e op) = SecLeft (g e) op

mapFieldAssign : (Expr -> Expr) -> FieldAssign -> FieldAssign
mapFieldAssign g (FieldAssign n v) = FieldAssign n (g v)

mapDoStmt : (Expr -> Expr) -> DoStmt -> DoStmt
mapDoStmt g (DoExpr e) = DoExpr (g e)
mapDoStmt g (DoBind p e) = DoBind p (g e)
mapDoStmt g (DoLet m r p e site) = DoLet m r p (g e) site
mapDoStmt g (DoAssign x e) = DoAssign x (g e)
mapDoStmt g (DoFieldAssign x fs e) = DoFieldAssign x fs (g e)

mapInterp : (Expr -> Expr) -> InterpPart -> InterpPart
mapInterp _ (InterpStr s) = InterpStr s
mapInterp g (InterpExpr e) = InterpExpr (g e)

-- Who owns an expression body: a function clause, an `impl` method or an
-- interface default (interface name, method name), a `test` or `prop` (its
-- description), or one clause of a top-level `let rec … with …` binding.
public export data BodyOwner =
  | OwnerClause String (List Pat)
  | OwnerImplMethod String String (List Pat)
  | OwnerIfaceDefault String String (List Pat)
  | OwnerTest String
  | OwnerProp String (List PropParam)
  | OwnerLetGroup String (List Pat)

public export data DeclBody = DeclBody BodyOwner Expr

-- Every expression body directly held by one top-level declaration, in source
-- order; an attributed declaration yields the bodies of the one it wraps.
export
declBodies : Decl -> List DeclBody
declBodies (DTypeSig _ _ _ _) = []
declBodies (DExtern _) = []
declBodies (DFunDef _ name ps body _ _) = [DeclBody (OwnerClause name ps) body]
declBodies (DData { dataName = _, ... }) = []
declBodies (DUse _ _ _) = []
declBodies (DEffect _ _ _ _ _ _) = []
declBodies (DProp _ name params body) = [DeclBody (OwnerProp name params) body]
declBodies (DTest _ name body) = [DeclBody (OwnerTest name) body]
declBodies (DInterface { ifaceOrigin = _, name, methods, ... }) =
  flatMap (ifaceDefaultBody name) methods
declBodies (DImpl { implOrigin = _, iface, methods, ... }) =
  map (implMethodBody iface) methods
declBodies (DTypeAlias { tyAliasName = _, ... }) = []
declBodies (DNewtype { newtypeName = _, ... }) = []
declBodies (DLetGroup _ binds) = flatMap letGroupBodies binds
declBodies (DAttrib _ d) = declBodies d

ifaceDefaultBody : String -> IfaceMethod -> List DeclBody
ifaceDefaultBody _ (IfaceMethod _ _ None _) = []
ifaceDefaultBody iface (IfaceMethod m _ (Some (MethodDefault ps body)) _) =
  [DeclBody (OwnerIfaceDefault iface m ps) body]

implMethodBody : String -> ImplMethod -> DeclBody
implMethodBody iface (ImplMethod m ps body) =
  DeclBody (OwnerImplMethod iface m ps) body

letGroupBodies : LetBind -> List DeclBody
letGroupBodies (LetBind name clauses _ _) =
  map ((FunClause ps body) => DeclBody (OwnerLetGroup name ps) body) clauses

-- The span of a node's own `ELoc` wrapper, if it is one.
nodeLoc : Expr -> Option Loc
nodeLoc (ELit _) = None
nodeLoc (EVar _) = None
nodeLoc (EApp _ _) = None
nodeLoc (ELam _ _) = None
nodeLoc (ELet _ _ _ _ _) = None
nodeLoc (EMatch _ _) = None
nodeLoc (EIf _ _ _) = None
nodeLoc (EBinOp _ _ _ _) = None
nodeLoc (EUnOp _ _ _) = None
nodeLoc (EInfix _ _ _) = None
nodeLoc (EFieldAccess _ _ _) = None
nodeLoc (ETuple _) = None
nodeLoc (EListLit _) = None
nodeLoc (EArrayLit _) = None
nodeLoc (ERangeList _ _ _) = None
nodeLoc (ERangeArray _ _ _) = None
nodeLoc (ESlice _ _ _ _) = None
nodeLoc (ELetGroup _ _) = None
nodeLoc (ESection _) = None
nodeLoc (EIndex _ _) = None
nodeLoc (EAnnot _ _) = None
nodeLoc (EHeadAnnot _ _) = None
nodeLoc (EBlock _) = None
nodeLoc (EDo _ _) = None
nodeLoc (EStringInterp _) = None
nodeLoc (EGuards _) = None
nodeLoc (ERecordCreate _ _) = None
nodeLoc (ERecordUpdate _ _ _) = None
nodeLoc (EVariantUpdate _ _ _) = None
nodeLoc (EMapLit _ _) = None
nodeLoc (ESetLit _ _) = None
nodeLoc (EAsPat _ _) = None
nodeLoc (EOrPat _) = None
nodeLoc (EMethodRef _) = None
nodeLoc (EDictApp _) = None
nodeLoc (EVarAt _ _) = None
nodeLoc (EVarId _ _) = None
nodeLoc (EMethodAt _ _ _) = None
nodeLoc (EDictAt _ _) = None
nodeLoc (ELoc l _) = Some l
nodeLoc (EDoOrigin _ _) = None
nodeLoc (ENumLit _ _ _) = None
nodeLoc (EWideLit _ _ _ _) = None

-- A node's source span: its own `ELoc` span, or else the span from the
-- earliest start to the latest end among the `ELoc`s nearest its leaves.  The
-- parser leaves application and operator nodes unwrapped, so this is how their
-- extent is recovered.  `None` for a tree with no `ELoc` at all.
export
exprSpan : Expr -> Option Loc
exprSpan e = match nodeLoc e
  Some l => Some l
  None => fold joinSpan None (map exprSpan (childExprs e))

joinSpan : Option Loc -> Option Loc -> Option Loc
joinSpan None b = b
joinSpan a None = a
joinSpan (Some (Loc f sl sc el ec)) (Some (Loc _ sl2 sc2 el2 ec2)) =
  let (l1, c1) = min (sl, sc) (sl2, sc2)
  let (l2, c2) = max (el, ec) (el2, ec2)
  Some (Loc f l1 c1 l2 c2)
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" true) (mem "DoStmt" true) (mem "Expr" true) (mem "FieldAssign" true) (mem "FunClause" true) (mem "Guard" true) (mem "GuardArm" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "InterpPart" true) (mem "LetBind" true) (mem "Loc" true) (mem "MethodDefault" true) (mem "Pat" false) (mem "PropParam" false) (mem "Section" true))))
(DData Public "ExprKind" () ((variant "KLit" (ConPos)) (variant "KVar" (ConPos)) (variant "KApp" (ConPos)) (variant "KLam" (ConPos)) (variant "KLet" (ConPos)) (variant "KMatch" (ConPos)) (variant "KIf" (ConPos)) (variant "KBinOp" (ConPos)) (variant "KUnOp" (ConPos)) (variant "KInfix" (ConPos)) (variant "KFieldAccess" (ConPos)) (variant "KTuple" (ConPos)) (variant "KListLit" (ConPos)) (variant "KArrayLit" (ConPos)) (variant "KRangeList" (ConPos)) (variant "KRangeArray" (ConPos)) (variant "KSlice" (ConPos)) (variant "KLetGroup" (ConPos)) (variant "KSection" (ConPos)) (variant "KIndex" (ConPos)) (variant "KAnnot" (ConPos)) (variant "KHeadAnnot" (ConPos)) (variant "KBlock" (ConPos)) (variant "KDo" (ConPos)) (variant "KStringInterp" (ConPos)) (variant "KGuards" (ConPos)) (variant "KRecordCreate" (ConPos)) (variant "KRecordUpdate" (ConPos)) (variant "KVariantUpdate" (ConPos)) (variant "KMapLit" (ConPos)) (variant "KSetLit" (ConPos)) (variant "KAsPat" (ConPos)) (variant "KOrPat" (ConPos)) (variant "KMethodRef" (ConPos)) (variant "KDictApp" (ConPos)) (variant "KVarAt" (ConPos)) (variant "KVarId" (ConPos)) (variant "KMethodAt" (ConPos)) (variant "KDictAt" (ConPos)) (variant "KLoc" (ConPos)) (variant "KDoOrigin" (ConPos)) (variant "KNumLit" (ConPos)) (variant "KWideLit" (ConPos))) ())
(DImpl true "Eq" ((TyCon "ExprKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "KLit") (PCon "KLit")) () (EVar "True")) (arm (PTuple (PCon "KVar") (PCon "KVar")) () (EVar "True")) (arm (PTuple (PCon "KApp") (PCon "KApp")) () (EVar "True")) (arm (PTuple (PCon "KLam") (PCon "KLam")) () (EVar "True")) (arm (PTuple (PCon "KLet") (PCon "KLet")) () (EVar "True")) (arm (PTuple (PCon "KMatch") (PCon "KMatch")) () (EVar "True")) (arm (PTuple (PCon "KIf") (PCon "KIf")) () (EVar "True")) (arm (PTuple (PCon "KBinOp") (PCon "KBinOp")) () (EVar "True")) (arm (PTuple (PCon "KUnOp") (PCon "KUnOp")) () (EVar "True")) (arm (PTuple (PCon "KInfix") (PCon "KInfix")) () (EVar "True")) (arm (PTuple (PCon "KFieldAccess") (PCon "KFieldAccess")) () (EVar "True")) (arm (PTuple (PCon "KTuple") (PCon "KTuple")) () (EVar "True")) (arm (PTuple (PCon "KListLit") (PCon "KListLit")) () (EVar "True")) (arm (PTuple (PCon "KArrayLit") (PCon "KArrayLit")) () (EVar "True")) (arm (PTuple (PCon "KRangeList") (PCon "KRangeList")) () (EVar "True")) (arm (PTuple (PCon "KRangeArray") (PCon "KRangeArray")) () (EVar "True")) (arm (PTuple (PCon "KSlice") (PCon "KSlice")) () (EVar "True")) (arm (PTuple (PCon "KLetGroup") (PCon "KLetGroup")) () (EVar "True")) (arm (PTuple (PCon "KSection") (PCon "KSection")) () (EVar "True")) (arm (PTuple (PCon "KIndex") (PCon "KIndex")) () (EVar "True")) (arm (PTuple (PCon "KAnnot") (PCon "KAnnot")) () (EVar "True")) (arm (PTuple (PCon "KHeadAnnot") (PCon "KHeadAnnot")) () (EVar "True")) (arm (PTuple (PCon "KBlock") (PCon "KBlock")) () (EVar "True")) (arm (PTuple (PCon "KDo") (PCon "KDo")) () (EVar "True")) (arm (PTuple (PCon "KStringInterp") (PCon "KStringInterp")) () (EVar "True")) (arm (PTuple (PCon "KGuards") (PCon "KGuards")) () (EVar "True")) (arm (PTuple (PCon "KRecordCreate") (PCon "KRecordCreate")) () (EVar "True")) (arm (PTuple (PCon "KRecordUpdate") (PCon "KRecordUpdate")) () (EVar "True")) (arm (PTuple (PCon "KVariantUpdate") (PCon "KVariantUpdate")) () (EVar "True")) (arm (PTuple (PCon "KMapLit") (PCon "KMapLit")) () (EVar "True")) (arm (PTuple (PCon "KSetLit") (PCon "KSetLit")) () (EVar "True")) (arm (PTuple (PCon "KAsPat") (PCon "KAsPat")) () (EVar "True")) (arm (PTuple (PCon "KOrPat") (PCon "KOrPat")) () (EVar "True")) (arm (PTuple (PCon "KMethodRef") (PCon "KMethodRef")) () (EVar "True")) (arm (PTuple (PCon "KDictApp") (PCon "KDictApp")) () (EVar "True")) (arm (PTuple (PCon "KVarAt") (PCon "KVarAt")) () (EVar "True")) (arm (PTuple (PCon "KVarId") (PCon "KVarId")) () (EVar "True")) (arm (PTuple (PCon "KMethodAt") (PCon "KMethodAt")) () (EVar "True")) (arm (PTuple (PCon "KDictAt") (PCon "KDictAt")) () (EVar "True")) (arm (PTuple (PCon "KLoc") (PCon "KLoc")) () (EVar "True")) (arm (PTuple (PCon "KDoOrigin") (PCon "KDoOrigin")) () (EVar "True")) (arm (PTuple (PCon "KNumLit") (PCon "KNumLit")) () (EVar "True")) (arm (PTuple (PCon "KWideLit") (PCon "KWideLit")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "ExprKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "KLit") () (ELit (LString "KLit"))) (arm (PCon "KVar") () (ELit (LString "KVar"))) (arm (PCon "KApp") () (ELit (LString "KApp"))) (arm (PCon "KLam") () (ELit (LString "KLam"))) (arm (PCon "KLet") () (ELit (LString "KLet"))) (arm (PCon "KMatch") () (ELit (LString "KMatch"))) (arm (PCon "KIf") () (ELit (LString "KIf"))) (arm (PCon "KBinOp") () (ELit (LString "KBinOp"))) (arm (PCon "KUnOp") () (ELit (LString "KUnOp"))) (arm (PCon "KInfix") () (ELit (LString "KInfix"))) (arm (PCon "KFieldAccess") () (ELit (LString "KFieldAccess"))) (arm (PCon "KTuple") () (ELit (LString "KTuple"))) (arm (PCon "KListLit") () (ELit (LString "KListLit"))) (arm (PCon "KArrayLit") () (ELit (LString "KArrayLit"))) (arm (PCon "KRangeList") () (ELit (LString "KRangeList"))) (arm (PCon "KRangeArray") () (ELit (LString "KRangeArray"))) (arm (PCon "KSlice") () (ELit (LString "KSlice"))) (arm (PCon "KLetGroup") () (ELit (LString "KLetGroup"))) (arm (PCon "KSection") () (ELit (LString "KSection"))) (arm (PCon "KIndex") () (ELit (LString "KIndex"))) (arm (PCon "KAnnot") () (ELit (LString "KAnnot"))) (arm (PCon "KHeadAnnot") () (ELit (LString "KHeadAnnot"))) (arm (PCon "KBlock") () (ELit (LString "KBlock"))) (arm (PCon "KDo") () (ELit (LString "KDo"))) (arm (PCon "KStringInterp") () (ELit (LString "KStringInterp"))) (arm (PCon "KGuards") () (ELit (LString "KGuards"))) (arm (PCon "KRecordCreate") () (ELit (LString "KRecordCreate"))) (arm (PCon "KRecordUpdate") () (ELit (LString "KRecordUpdate"))) (arm (PCon "KVariantUpdate") () (ELit (LString "KVariantUpdate"))) (arm (PCon "KMapLit") () (ELit (LString "KMapLit"))) (arm (PCon "KSetLit") () (ELit (LString "KSetLit"))) (arm (PCon "KAsPat") () (ELit (LString "KAsPat"))) (arm (PCon "KOrPat") () (ELit (LString "KOrPat"))) (arm (PCon "KMethodRef") () (ELit (LString "KMethodRef"))) (arm (PCon "KDictApp") () (ELit (LString "KDictApp"))) (arm (PCon "KVarAt") () (ELit (LString "KVarAt"))) (arm (PCon "KVarId") () (ELit (LString "KVarId"))) (arm (PCon "KMethodAt") () (ELit (LString "KMethodAt"))) (arm (PCon "KDictAt") () (ELit (LString "KDictAt"))) (arm (PCon "KLoc") () (ELit (LString "KLoc"))) (arm (PCon "KDoOrigin") () (ELit (LString "KDoOrigin"))) (arm (PCon "KNumLit") () (ELit (LString "KNumLit"))) (arm (PCon "KWideLit") () (ELit (LString "KWideLit")))))))
(DTypeSig true "exprKind" (TyFun (TyCon "Expr") (TyCon "ExprKind")))
(DFunDef false "exprKind" ((PCon "ELit" PWild)) (EVar "KLit"))
(DFunDef false "exprKind" ((PCon "EVar" PWild)) (EVar "KVar"))
(DFunDef false "exprKind" ((PCon "EApp" PWild PWild)) (EVar "KApp"))
(DFunDef false "exprKind" ((PCon "ELam" PWild PWild)) (EVar "KLam"))
(DFunDef false "exprKind" ((PCon "ELet" PWild PWild PWild PWild PWild)) (EVar "KLet"))
(DFunDef false "exprKind" ((PCon "EMatch" PWild PWild)) (EVar "KMatch"))
(DFunDef false "exprKind" ((PCon "EIf" PWild PWild PWild)) (EVar "KIf"))
(DFunDef false "exprKind" ((PCon "EBinOp" PWild PWild PWild PWild)) (EVar "KBinOp"))
(DFunDef false "exprKind" ((PCon "EUnOp" PWild PWild PWild)) (EVar "KUnOp"))
(DFunDef false "exprKind" ((PCon "EInfix" PWild PWild PWild)) (EVar "KInfix"))
(DFunDef false "exprKind" ((PCon "EFieldAccess" PWild PWild PWild)) (EVar "KFieldAccess"))
(DFunDef false "exprKind" ((PCon "ETuple" PWild)) (EVar "KTuple"))
(DFunDef false "exprKind" ((PCon "EListLit" PWild)) (EVar "KListLit"))
(DFunDef false "exprKind" ((PCon "EArrayLit" PWild)) (EVar "KArrayLit"))
(DFunDef false "exprKind" ((PCon "ERangeList" PWild PWild PWild)) (EVar "KRangeList"))
(DFunDef false "exprKind" ((PCon "ERangeArray" PWild PWild PWild)) (EVar "KRangeArray"))
(DFunDef false "exprKind" ((PCon "ESlice" PWild PWild PWild PWild)) (EVar "KSlice"))
(DFunDef false "exprKind" ((PCon "ELetGroup" PWild PWild)) (EVar "KLetGroup"))
(DFunDef false "exprKind" ((PCon "ESection" PWild)) (EVar "KSection"))
(DFunDef false "exprKind" ((PCon "EIndex" PWild PWild)) (EVar "KIndex"))
(DFunDef false "exprKind" ((PCon "EAnnot" PWild PWild)) (EVar "KAnnot"))
(DFunDef false "exprKind" ((PCon "EHeadAnnot" PWild PWild)) (EVar "KHeadAnnot"))
(DFunDef false "exprKind" ((PCon "EBlock" PWild)) (EVar "KBlock"))
(DFunDef false "exprKind" ((PCon "EDo" PWild PWild)) (EVar "KDo"))
(DFunDef false "exprKind" ((PCon "EStringInterp" PWild)) (EVar "KStringInterp"))
(DFunDef false "exprKind" ((PCon "EGuards" PWild)) (EVar "KGuards"))
(DFunDef false "exprKind" ((PCon "ERecordCreate" PWild PWild)) (EVar "KRecordCreate"))
(DFunDef false "exprKind" ((PCon "ERecordUpdate" PWild PWild PWild)) (EVar "KRecordUpdate"))
(DFunDef false "exprKind" ((PCon "EVariantUpdate" PWild PWild PWild)) (EVar "KVariantUpdate"))
(DFunDef false "exprKind" ((PCon "EMapLit" PWild PWild)) (EVar "KMapLit"))
(DFunDef false "exprKind" ((PCon "ESetLit" PWild PWild)) (EVar "KSetLit"))
(DFunDef false "exprKind" ((PCon "EAsPat" PWild PWild)) (EVar "KAsPat"))
(DFunDef false "exprKind" ((PCon "EOrPat" PWild)) (EVar "KOrPat"))
(DFunDef false "exprKind" ((PCon "EMethodRef" PWild)) (EVar "KMethodRef"))
(DFunDef false "exprKind" ((PCon "EDictApp" PWild)) (EVar "KDictApp"))
(DFunDef false "exprKind" ((PCon "EVarAt" PWild PWild)) (EVar "KVarAt"))
(DFunDef false "exprKind" ((PCon "EVarId" PWild PWild)) (EVar "KVarId"))
(DFunDef false "exprKind" ((PCon "EMethodAt" PWild PWild PWild)) (EVar "KMethodAt"))
(DFunDef false "exprKind" ((PCon "EDictAt" PWild PWild)) (EVar "KDictAt"))
(DFunDef false "exprKind" ((PCon "ELoc" PWild PWild)) (EVar "KLoc"))
(DFunDef false "exprKind" ((PCon "EDoOrigin" PWild PWild)) (EVar "KDoOrigin"))
(DFunDef false "exprKind" ((PCon "ENumLit" PWild PWild PWild)) (EVar "KNumLit"))
(DFunDef false "exprKind" ((PCon "EWideLit" PWild PWild PWild PWild)) (EVar "KWideLit"))
(DTypeSig true "childExprs" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "childExprs" ((PCon "ELit" PWild)) (EListLit))
(DFunDef false "childExprs" ((PCon "EVar" PWild)) (EListLit))
(DFunDef false "childExprs" ((PCon "EApp" (PVar "f") (PVar "x"))) (EListLit (EVar "f") (EVar "x")))
(DFunDef false "childExprs" ((PCon "ELam" PWild (PVar "b"))) (EListLit (EVar "b")))
(DFunDef false "childExprs" ((PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EListLit (EVar "e1") (EVar "e2")))
(DFunDef false "childExprs" ((PCon "EMatch" (PVar "s") (PVar "arms"))) (EBinOp "::" (EVar "s") (EApp (EApp (EVar "flatMap") (EVar "armExprs")) (EVar "arms"))))
(DFunDef false "childExprs" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EListLit (EVar "c") (EVar "t") (EVar "el")))
(DFunDef false "childExprs" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EListLit (EVar "a") (EVar "b")))
(DFunDef false "childExprs" ((PCon "EUnOp" PWild (PVar "a") PWild)) (EListLit (EVar "a")))
(DFunDef false "childExprs" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EListLit (EVar "a") (EVar "b")))
(DFunDef false "childExprs" ((PCon "EFieldAccess" (PVar "e") PWild PWild)) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "ETuple" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "EListLit" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "EArrayLit" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EListLit (EVar "lo") (EVar "hi")))
(DFunDef false "childExprs" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EListLit (EVar "lo") (EVar "hi")))
(DFunDef false "childExprs" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") PWild)) (EListLit (EVar "e") (EVar "lo") (EVar "hi")))
(DFunDef false "childExprs" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "letBindExprs")) (EVar "binds")) (EListLit (EVar "body"))))
(DFunDef false "childExprs" ((PCon "ESection" (PVar "s"))) (EApp (EVar "sectionExprs") (EVar "s")))
(DFunDef false "childExprs" ((PCon "EIndex" (PVar "a") (PVar "i"))) (EListLit (EVar "a") (EVar "i")))
(DFunDef false "childExprs" ((PCon "EAnnot" (PVar "e") PWild)) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EVar "flatMap") (EVar "stmtExprs")) (EVar "stmts")))
(DFunDef false "childExprs" ((PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EVar "flatMap") (EVar "stmtExprs")) (EVar "stmts")))
(DFunDef false "childExprs" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EVar "flatMap") (EVar "interpPartExprs")) (EVar "parts")))
(DFunDef false "childExprs" ((PCon "EGuards" (PVar "arms"))) (EApp (EApp (EVar "flatMap") (EVar "guardArmExprs")) (EVar "arms")))
(DFunDef false "childExprs" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EVar "map") (EVar "fieldAssignExpr")) (EVar "fs")))
(DFunDef false "childExprs" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") PWild)) (EBinOp "::" (EVar "e") (EApp (EApp (EVar "map") (EVar "fieldAssignExpr")) (EVar "fs"))))
(DFunDef false "childExprs" ((PCon "EVariantUpdate" PWild (PVar "e") (PVar "fs"))) (EBinOp "::" (EVar "e") (EApp (EApp (EVar "map") (EVar "fieldAssignExpr")) (EVar "fs"))))
(DFunDef false "childExprs" ((PCon "EMapLit" PWild (PVar "kvs"))) (EApp (EApp (EVar "flatMap") (EVar "kvExprs")) (EVar "kvs")))
(DFunDef false "childExprs" ((PCon "ESetLit" PWild (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "EAsPat" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EOrPat" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "EMethodRef" PWild)) (EListLit))
(DFunDef false "childExprs" ((PCon "EDictApp" PWild)) (EListLit))
(DFunDef false "childExprs" ((PCon "EVarAt" PWild PWild)) (EListLit))
(DFunDef false "childExprs" ((PCon "EVarId" PWild PWild)) (EListLit))
(DFunDef false "childExprs" ((PCon "EMethodAt" PWild PWild PWild)) (EListLit))
(DFunDef false "childExprs" ((PCon "EDictAt" PWild PWild)) (EListLit))
(DFunDef false "childExprs" ((PCon "ELoc" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EDoOrigin" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "ENumLit" PWild PWild PWild)) (EListLit))
(DFunDef false "childExprs" ((PCon "EWideLit" PWild PWild PWild PWild)) (EListLit))
(DTypeSig false "armExprs" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "armExprs" ((PCon "Arm" PWild (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "guardExprs")) (EVar "gs")) (EListLit (EVar "body"))))
(DTypeSig false "guardExprs" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "guardExprs" ((PCon "GBool" (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "guardExprs" ((PCon "GBind" PWild (PVar "e"))) (EListLit (EVar "e")))
(DTypeSig true "stmtExprs" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "stmtExprs" ((PCon "DoExpr" (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoBind" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoLet" PWild PWild PWild (PVar "e") PWild)) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoAssign" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EListLit (EVar "e")))
(DTypeSig false "letBindExprs" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "letBindExprs" ((PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "map") (ELam ((PCon "FunClause" PWild (PVar "body"))) (EVar "body"))) (EVar "clauses")))
(DTypeSig false "sectionExprs" (TyFun (TyCon "Section") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "sectionExprs" ((PCon "SecBare" PWild)) (EListLit))
(DFunDef false "sectionExprs" ((PCon "SecRight" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "sectionExprs" ((PCon "SecLeft" (PVar "e") PWild)) (EListLit (EVar "e")))
(DTypeSig false "interpPartExprs" (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "interpPartExprs" ((PCon "InterpStr" PWild)) (EListLit))
(DFunDef false "interpPartExprs" ((PCon "InterpExpr" (PVar "e"))) (EListLit (EVar "e")))
(DTypeSig false "guardArmExprs" (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "guardArmExprs" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EVar "flatMap") (EVar "guardExprs")) (EVar "gs")) (EListLit (EVar "body"))))
(DTypeSig false "fieldAssignExpr" (TyFun (TyCon "FieldAssign") (TyCon "Expr")))
(DFunDef false "fieldAssignExpr" ((PCon "FieldAssign" PWild (PVar "e"))) (EVar "e"))
(DTypeSig false "kvExprs" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "kvExprs" ((PTuple (PVar "k") (PVar "v"))) (EListLit (EVar "k") (EVar "v")))
(DTypeSig true "mapChildExprs" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "mapChildExprs" (PWild (PCon "ELit" (PVar "l"))) (EApp (EVar "ELit") (EVar "l")))
(DFunDef false "mapChildExprs" (PWild (PCon "EVar" (PVar "n"))) (EApp (EVar "EVar") (EVar "n")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "EApp") (EApp (EVar "g") (EVar "a"))) (EApp (EVar "g") (EVar "b"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EVar "g") (EVar "b"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ELet" (PVar "m") (PVar "r") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EVar "g") (EVar "e1"))) (EApp (EVar "g") (EVar "e2"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EVar "g") (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EVar "mapArm") (EVar "g"))) (EVar "arms"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EVar "g") (EVar "c"))) (EApp (EVar "g") (EVar "t"))) (EApp (EVar "g") (EVar "el"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EVar "g") (EVar "a"))) (EApp (EVar "g") (EVar "b"))) (EVar "r")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EVar "g") (EVar "a"))) (EVar "r")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EVar "g") (EVar "a"))) (EApp (EVar "g") (EVar "b"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EFieldAccess" (PVar "e0") (PVar "n") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EVar "g") (EVar "e0"))) (EVar "n")) (EVar "r")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EVar "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EVar "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EVar "g") (EVar "lo"))) (EApp (EVar "g") (EVar "hi"))) (EVar "incl")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EVar "g") (EVar "lo"))) (EApp (EVar "g") (EVar "hi"))) (EVar "incl")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EVar "g") (EVar "e0"))) (EApp (EVar "g") (EVar "lo"))) (EApp (EVar "g") (EVar "hi"))) (EVar "incl")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ELetGroup" (PVar "bs") (PVar "e2"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EVar "map") (EApp (EVar "mapLetBind") (EVar "g"))) (EVar "bs"))) (EApp (EVar "g") (EVar "e2"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EApp (EVar "mapSection") (EVar "g")) (EVar "s"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EIndex" (PVar "e0") (PVar "i"))) (EApp (EApp (EVar "EIndex") (EApp (EVar "g") (EVar "e0"))) (EApp (EVar "g") (EVar "i"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EVar "g") (EVar "e0"))) (EVar "t")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EVar "g") (EVar "e0"))) (EVar "t")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EVar "map") (EApp (EVar "mapDoStmt") (EVar "g"))) (EVar "stmts"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "d")) (EApp (EApp (EVar "map") (EApp (EVar "mapDoStmt") (EVar "g"))) (EVar "stmts"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EVar "map") (EApp (EVar "mapInterp") (EVar "g"))) (EVar "parts"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EVar "map") (EApp (EVar "mapGuardArm") (EVar "g"))) (EVar "arms"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "mapFieldAssign") (EVar "g"))) (EVar "fs"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EVar "g") (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EVar "mapFieldAssign") (EVar "g"))) (EVar "fs"))) (EVar "r")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EVariantUpdate" (PVar "c") (PVar "e0") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EVar "g") (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EVar "mapFieldAssign") (EVar "g"))) (EVar "fs"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EVar "map") (ELam ((PVar "kv")) (ETuple (EApp (EVar "g") (EApp (EVar "fst") (EVar "kv"))) (EApp (EVar "g") (EApp (EVar "snd") (EVar "kv")))))) (EVar "kvs"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EVar "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EOrPat" (PVar "es"))) (EApp (EVar "EOrPat") (EApp (EApp (EVar "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildExprs" (PWild (PCon "EMethodRef" (PVar "n"))) (EApp (EVar "EMethodRef") (EVar "n")))
(DFunDef false "mapChildExprs" (PWild (PCon "EDictApp" (PVar "n"))) (EApp (EVar "EDictApp") (EVar "n")))
(DFunDef false "mapChildExprs" (PWild (PCon "EVarAt" (PVar "n") (PVar "a"))) (EApp (EApp (EVar "EVarAt") (EVar "n")) (EVar "a")))
(DFunDef false "mapChildExprs" (PWild (PCon "EVarId" (PVar "n") (PVar "i"))) (EApp (EApp (EVar "EVarId") (EVar "n")) (EVar "i")))
(DFunDef false "mapChildExprs" (PWild (PCon "EMethodAt" (PVar "n") (PVar "s") (PVar "ev"))) (EApp (EApp (EApp (EVar "EMethodAt") (EVar "n")) (EVar "s")) (EVar "ev")))
(DFunDef false "mapChildExprs" (PWild (PCon "EDictAt" (PVar "n") (PVar "ev"))) (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildExprs" (PWild (PCon "ENumLit" (PVar "n") (PVar "ev") (PVar "lexeme"))) (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EVar "ev")) (EVar "lexeme")))
(DFunDef false "mapChildExprs" (PWild (PCon "EWideLit" (PVar "hi") (PVar "lo") (PVar "ev") (PVar "lexeme"))) (EApp (EApp (EApp (EApp (EVar "EWideLit") (EVar "hi")) (EVar "lo")) (EVar "ev")) (EVar "lexeme")))
(DTypeSig false "mapArm" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Arm") (TyCon "Arm"))))
(DFunDef false "mapArm" ((PVar "g") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "b"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EVar "map") (EApp (EVar "mapGuard") (EVar "g"))) (EVar "gs"))) (EApp (EVar "g") (EVar "b"))))
(DTypeSig false "mapGuard" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Guard") (TyCon "Guard"))))
(DFunDef false "mapGuard" ((PVar "g") (PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapGuard" ((PVar "g") (PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EVar "g") (EVar "e"))))
(DTypeSig false "mapGuardArm" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "GuardArm") (TyCon "GuardArm"))))
(DFunDef false "mapGuardArm" ((PVar "g") (PCon "GuardArm" (PVar "gs") (PVar "b"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EVar "map") (EApp (EVar "mapGuard") (EVar "g"))) (EVar "gs"))) (EApp (EVar "g") (EVar "b"))))
(DTypeSig false "mapLetBind" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "mapLetBind" ((PVar "g") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "mapFunClause") (EVar "g"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "mapFunClause" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "FunClause") (TyCon "FunClause"))))
(DFunDef false "mapFunClause" ((PVar "g") (PCon "FunClause" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EVar "g") (EVar "b"))))
(DTypeSig false "mapSection" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Section") (TyCon "Section"))))
(DFunDef false "mapSection" (PWild (PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "mapSection" ((PVar "g") (PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapSection" ((PVar "g") (PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EVar "g") (EVar "e"))) (EVar "op")))
(DTypeSig false "mapFieldAssign" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign"))))
(DFunDef false "mapFieldAssign" ((PVar "g") (PCon "FieldAssign" (PVar "n") (PVar "v"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "g") (EVar "v"))))
(DTypeSig false "mapDoStmt" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "DoStmt") (TyCon "DoStmt"))))
(DFunDef false "mapDoStmt" ((PVar "g") (PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapDoStmt" ((PVar "g") (PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapDoStmt" ((PVar "g") (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EVar "g") (EVar "e"))) (EVar "site")))
(DFunDef false "mapDoStmt" ((PVar "g") (PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapDoStmt" ((PVar "g") (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EVar "g") (EVar "e"))))
(DTypeSig false "mapInterp" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "InterpPart") (TyCon "InterpPart"))))
(DFunDef false "mapInterp" (PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "mapInterp" ((PVar "g") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EVar "g") (EVar "e"))))
(DData Public "BodyOwner" () ((variant "OwnerClause" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")))) (variant "OwnerImplMethod" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")))) (variant "OwnerIfaceDefault" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")))) (variant "OwnerTest" (ConPos (TyCon "String"))) (variant "OwnerProp" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "PropParam")))) (variant "OwnerLetGroup" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat"))))) ())
(DData Public "DeclBody" () ((variant "DeclBody" (ConPos (TyCon "BodyOwner") (TyCon "Expr")))) ())
(DTypeSig true "declBodies" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "DeclBody"))))
(DFunDef false "declBodies" ((PCon "DTypeSig" PWild PWild PWild PWild)) (EListLit))
(DFunDef false "declBodies" ((PCon "DExtern" PWild)) (EListLit))
(DFunDef false "declBodies" ((PCon "DFunDef" PWild (PVar "name") (PVar "ps") (PVar "body") PWild PWild)) (EListLit (EApp (EApp (EVar "DeclBody") (EApp (EApp (EVar "OwnerClause") (EVar "name")) (EVar "ps"))) (EVar "body"))))
(DFunDef false "declBodies" ((PRec "DData" ((rf "dataName" PWild)) true)) (EListLit))
(DFunDef false "declBodies" ((PCon "DUse" PWild PWild PWild)) (EListLit))
(DFunDef false "declBodies" ((PCon "DEffect" PWild PWild PWild PWild PWild PWild)) (EListLit))
(DFunDef false "declBodies" ((PCon "DProp" PWild (PVar "name") (PVar "params") (PVar "body"))) (EListLit (EApp (EApp (EVar "DeclBody") (EApp (EApp (EVar "OwnerProp") (EVar "name")) (EVar "params"))) (EVar "body"))))
(DFunDef false "declBodies" ((PCon "DTest" PWild (PVar "name") (PVar "body"))) (EListLit (EApp (EApp (EVar "DeclBody") (EApp (EVar "OwnerTest") (EVar "name"))) (EVar "body"))))
(DFunDef false "declBodies" ((PRec "DInterface" ((rf "ifaceOrigin" PWild) (rf "name" None) (rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EApp (EVar "ifaceDefaultBody") (EVar "name"))) (EVar "methods")))
(DFunDef false "declBodies" ((PRec "DImpl" ((rf "implOrigin" PWild) (rf "iface" None) (rf "methods" None)) true)) (EApp (EApp (EVar "map") (EApp (EVar "implMethodBody") (EVar "iface"))) (EVar "methods")))
(DFunDef false "declBodies" ((PRec "DTypeAlias" ((rf "tyAliasName" PWild)) true)) (EListLit))
(DFunDef false "declBodies" ((PRec "DNewtype" ((rf "newtypeName" PWild)) true)) (EListLit))
(DFunDef false "declBodies" ((PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EVar "flatMap") (EVar "letGroupBodies")) (EVar "binds")))
(DFunDef false "declBodies" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declBodies") (EVar "d")))
(DTypeSig false "ifaceDefaultBody" (TyFun (TyCon "String") (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "DeclBody")))))
(DFunDef false "ifaceDefaultBody" (PWild (PCon "IfaceMethod" PWild PWild (PCon "None") PWild)) (EListLit))
(DFunDef false "ifaceDefaultBody" ((PVar "iface") (PCon "IfaceMethod" (PVar "m") PWild (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "body"))) PWild)) (EListLit (EApp (EApp (EVar "DeclBody") (EApp (EApp (EApp (EVar "OwnerIfaceDefault") (EVar "iface")) (EVar "m")) (EVar "ps"))) (EVar "body"))))
(DTypeSig false "implMethodBody" (TyFun (TyCon "String") (TyFun (TyCon "ImplMethod") (TyCon "DeclBody"))))
(DFunDef false "implMethodBody" ((PVar "iface") (PCon "ImplMethod" (PVar "m") (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "DeclBody") (EApp (EApp (EApp (EVar "OwnerImplMethod") (EVar "iface")) (EVar "m")) (EVar "ps"))) (EVar "body")))
(DTypeSig false "letGroupBodies" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "DeclBody"))))
(DFunDef false "letGroupBodies" ((PCon "LetBind" (PVar "name") (PVar "clauses") PWild PWild)) (EApp (EApp (EVar "map") (ELam ((PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "DeclBody") (EApp (EApp (EVar "OwnerLetGroup") (EVar "name")) (EVar "ps"))) (EVar "body")))) (EVar "clauses")))
(DTypeSig false "nodeLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "nodeLoc" ((PCon "ELit" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EVar" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EApp" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ELam" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ELet" PWild PWild PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EMatch" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EIf" PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EBinOp" PWild PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EUnOp" PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EInfix" PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EFieldAccess" PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ETuple" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EListLit" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EArrayLit" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ERangeList" PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ERangeArray" PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ESlice" PWild PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ELetGroup" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ESection" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EIndex" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EAnnot" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EHeadAnnot" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EBlock" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EDo" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EStringInterp" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EGuards" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ERecordCreate" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ERecordUpdate" PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EVariantUpdate" PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EMapLit" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ESetLit" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EAsPat" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EOrPat" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EMethodRef" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EDictApp" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EVarAt" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EVarId" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EMethodAt" PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EDictAt" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "nodeLoc" ((PCon "EDoOrigin" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ENumLit" PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EWideLit" PWild PWild PWild PWild)) (EVar "None"))
(DTypeSig true "exprSpan" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "exprSpan" ((PVar "e")) (EMatch (EApp (EVar "nodeLoc") (EVar "e")) (arm (PCon "Some" (PVar "l")) () (EApp (EVar "Some") (EVar "l"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "fold") (EVar "joinSpan")) (EVar "None")) (EApp (EApp (EVar "map") (EVar "exprSpan")) (EApp (EVar "childExprs") (EVar "e")))))))
(DTypeSig false "joinSpan" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "joinSpan" ((PCon "None") (PVar "b")) (EVar "b"))
(DFunDef false "joinSpan" ((PVar "a") (PCon "None")) (EVar "a"))
(DFunDef false "joinSpan" ((PCon "Some" (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (PCon "Some" (PCon "Loc" PWild (PVar "sl2") (PVar "sc2") (PVar "el2") (PVar "ec2")))) (EBlock (DoLet false false (PTuple (PVar "l1") (PVar "c1")) (EApp (EApp (EVar "min") (ETuple (EVar "sl") (EVar "sc"))) (ETuple (EVar "sl2") (EVar "sc2")))) (DoLet false false (PTuple (PVar "l2") (PVar "c2")) (EApp (EApp (EVar "max") (ETuple (EVar "el") (EVar "ec"))) (ETuple (EVar "el2") (EVar "ec2")))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "l1")) (EVar "c1")) (EVar "l2")) (EVar "c2"))))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" true) (mem "DoStmt" true) (mem "Expr" true) (mem "FieldAssign" true) (mem "FunClause" true) (mem "Guard" true) (mem "GuardArm" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "InterpPart" true) (mem "LetBind" true) (mem "Loc" true) (mem "MethodDefault" true) (mem "Pat" false) (mem "PropParam" false) (mem "Section" true))))
(DData Public "ExprKind" () ((variant "KLit" (ConPos)) (variant "KVar" (ConPos)) (variant "KApp" (ConPos)) (variant "KLam" (ConPos)) (variant "KLet" (ConPos)) (variant "KMatch" (ConPos)) (variant "KIf" (ConPos)) (variant "KBinOp" (ConPos)) (variant "KUnOp" (ConPos)) (variant "KInfix" (ConPos)) (variant "KFieldAccess" (ConPos)) (variant "KTuple" (ConPos)) (variant "KListLit" (ConPos)) (variant "KArrayLit" (ConPos)) (variant "KRangeList" (ConPos)) (variant "KRangeArray" (ConPos)) (variant "KSlice" (ConPos)) (variant "KLetGroup" (ConPos)) (variant "KSection" (ConPos)) (variant "KIndex" (ConPos)) (variant "KAnnot" (ConPos)) (variant "KHeadAnnot" (ConPos)) (variant "KBlock" (ConPos)) (variant "KDo" (ConPos)) (variant "KStringInterp" (ConPos)) (variant "KGuards" (ConPos)) (variant "KRecordCreate" (ConPos)) (variant "KRecordUpdate" (ConPos)) (variant "KVariantUpdate" (ConPos)) (variant "KMapLit" (ConPos)) (variant "KSetLit" (ConPos)) (variant "KAsPat" (ConPos)) (variant "KOrPat" (ConPos)) (variant "KMethodRef" (ConPos)) (variant "KDictApp" (ConPos)) (variant "KVarAt" (ConPos)) (variant "KVarId" (ConPos)) (variant "KMethodAt" (ConPos)) (variant "KDictAt" (ConPos)) (variant "KLoc" (ConPos)) (variant "KDoOrigin" (ConPos)) (variant "KNumLit" (ConPos)) (variant "KWideLit" (ConPos))) ())
(DImpl true "Eq" ((TyCon "ExprKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "KLit") (PCon "KLit")) () (EVar "True")) (arm (PTuple (PCon "KVar") (PCon "KVar")) () (EVar "True")) (arm (PTuple (PCon "KApp") (PCon "KApp")) () (EVar "True")) (arm (PTuple (PCon "KLam") (PCon "KLam")) () (EVar "True")) (arm (PTuple (PCon "KLet") (PCon "KLet")) () (EVar "True")) (arm (PTuple (PCon "KMatch") (PCon "KMatch")) () (EVar "True")) (arm (PTuple (PCon "KIf") (PCon "KIf")) () (EVar "True")) (arm (PTuple (PCon "KBinOp") (PCon "KBinOp")) () (EVar "True")) (arm (PTuple (PCon "KUnOp") (PCon "KUnOp")) () (EVar "True")) (arm (PTuple (PCon "KInfix") (PCon "KInfix")) () (EVar "True")) (arm (PTuple (PCon "KFieldAccess") (PCon "KFieldAccess")) () (EVar "True")) (arm (PTuple (PCon "KTuple") (PCon "KTuple")) () (EVar "True")) (arm (PTuple (PCon "KListLit") (PCon "KListLit")) () (EVar "True")) (arm (PTuple (PCon "KArrayLit") (PCon "KArrayLit")) () (EVar "True")) (arm (PTuple (PCon "KRangeList") (PCon "KRangeList")) () (EVar "True")) (arm (PTuple (PCon "KRangeArray") (PCon "KRangeArray")) () (EVar "True")) (arm (PTuple (PCon "KSlice") (PCon "KSlice")) () (EVar "True")) (arm (PTuple (PCon "KLetGroup") (PCon "KLetGroup")) () (EVar "True")) (arm (PTuple (PCon "KSection") (PCon "KSection")) () (EVar "True")) (arm (PTuple (PCon "KIndex") (PCon "KIndex")) () (EVar "True")) (arm (PTuple (PCon "KAnnot") (PCon "KAnnot")) () (EVar "True")) (arm (PTuple (PCon "KHeadAnnot") (PCon "KHeadAnnot")) () (EVar "True")) (arm (PTuple (PCon "KBlock") (PCon "KBlock")) () (EVar "True")) (arm (PTuple (PCon "KDo") (PCon "KDo")) () (EVar "True")) (arm (PTuple (PCon "KStringInterp") (PCon "KStringInterp")) () (EVar "True")) (arm (PTuple (PCon "KGuards") (PCon "KGuards")) () (EVar "True")) (arm (PTuple (PCon "KRecordCreate") (PCon "KRecordCreate")) () (EVar "True")) (arm (PTuple (PCon "KRecordUpdate") (PCon "KRecordUpdate")) () (EVar "True")) (arm (PTuple (PCon "KVariantUpdate") (PCon "KVariantUpdate")) () (EVar "True")) (arm (PTuple (PCon "KMapLit") (PCon "KMapLit")) () (EVar "True")) (arm (PTuple (PCon "KSetLit") (PCon "KSetLit")) () (EVar "True")) (arm (PTuple (PCon "KAsPat") (PCon "KAsPat")) () (EVar "True")) (arm (PTuple (PCon "KOrPat") (PCon "KOrPat")) () (EVar "True")) (arm (PTuple (PCon "KMethodRef") (PCon "KMethodRef")) () (EVar "True")) (arm (PTuple (PCon "KDictApp") (PCon "KDictApp")) () (EVar "True")) (arm (PTuple (PCon "KVarAt") (PCon "KVarAt")) () (EVar "True")) (arm (PTuple (PCon "KVarId") (PCon "KVarId")) () (EVar "True")) (arm (PTuple (PCon "KMethodAt") (PCon "KMethodAt")) () (EVar "True")) (arm (PTuple (PCon "KDictAt") (PCon "KDictAt")) () (EVar "True")) (arm (PTuple (PCon "KLoc") (PCon "KLoc")) () (EVar "True")) (arm (PTuple (PCon "KDoOrigin") (PCon "KDoOrigin")) () (EVar "True")) (arm (PTuple (PCon "KNumLit") (PCon "KNumLit")) () (EVar "True")) (arm (PTuple (PCon "KWideLit") (PCon "KWideLit")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "ExprKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "KLit") () (ELit (LString "KLit"))) (arm (PCon "KVar") () (ELit (LString "KVar"))) (arm (PCon "KApp") () (ELit (LString "KApp"))) (arm (PCon "KLam") () (ELit (LString "KLam"))) (arm (PCon "KLet") () (ELit (LString "KLet"))) (arm (PCon "KMatch") () (ELit (LString "KMatch"))) (arm (PCon "KIf") () (ELit (LString "KIf"))) (arm (PCon "KBinOp") () (ELit (LString "KBinOp"))) (arm (PCon "KUnOp") () (ELit (LString "KUnOp"))) (arm (PCon "KInfix") () (ELit (LString "KInfix"))) (arm (PCon "KFieldAccess") () (ELit (LString "KFieldAccess"))) (arm (PCon "KTuple") () (ELit (LString "KTuple"))) (arm (PCon "KListLit") () (ELit (LString "KListLit"))) (arm (PCon "KArrayLit") () (ELit (LString "KArrayLit"))) (arm (PCon "KRangeList") () (ELit (LString "KRangeList"))) (arm (PCon "KRangeArray") () (ELit (LString "KRangeArray"))) (arm (PCon "KSlice") () (ELit (LString "KSlice"))) (arm (PCon "KLetGroup") () (ELit (LString "KLetGroup"))) (arm (PCon "KSection") () (ELit (LString "KSection"))) (arm (PCon "KIndex") () (ELit (LString "KIndex"))) (arm (PCon "KAnnot") () (ELit (LString "KAnnot"))) (arm (PCon "KHeadAnnot") () (ELit (LString "KHeadAnnot"))) (arm (PCon "KBlock") () (ELit (LString "KBlock"))) (arm (PCon "KDo") () (ELit (LString "KDo"))) (arm (PCon "KStringInterp") () (ELit (LString "KStringInterp"))) (arm (PCon "KGuards") () (ELit (LString "KGuards"))) (arm (PCon "KRecordCreate") () (ELit (LString "KRecordCreate"))) (arm (PCon "KRecordUpdate") () (ELit (LString "KRecordUpdate"))) (arm (PCon "KVariantUpdate") () (ELit (LString "KVariantUpdate"))) (arm (PCon "KMapLit") () (ELit (LString "KMapLit"))) (arm (PCon "KSetLit") () (ELit (LString "KSetLit"))) (arm (PCon "KAsPat") () (ELit (LString "KAsPat"))) (arm (PCon "KOrPat") () (ELit (LString "KOrPat"))) (arm (PCon "KMethodRef") () (ELit (LString "KMethodRef"))) (arm (PCon "KDictApp") () (ELit (LString "KDictApp"))) (arm (PCon "KVarAt") () (ELit (LString "KVarAt"))) (arm (PCon "KVarId") () (ELit (LString "KVarId"))) (arm (PCon "KMethodAt") () (ELit (LString "KMethodAt"))) (arm (PCon "KDictAt") () (ELit (LString "KDictAt"))) (arm (PCon "KLoc") () (ELit (LString "KLoc"))) (arm (PCon "KDoOrigin") () (ELit (LString "KDoOrigin"))) (arm (PCon "KNumLit") () (ELit (LString "KNumLit"))) (arm (PCon "KWideLit") () (ELit (LString "KWideLit")))))))
(DTypeSig true "exprKind" (TyFun (TyCon "Expr") (TyCon "ExprKind")))
(DFunDef false "exprKind" ((PCon "ELit" PWild)) (EVar "KLit"))
(DFunDef false "exprKind" ((PCon "EVar" PWild)) (EVar "KVar"))
(DFunDef false "exprKind" ((PCon "EApp" PWild PWild)) (EVar "KApp"))
(DFunDef false "exprKind" ((PCon "ELam" PWild PWild)) (EVar "KLam"))
(DFunDef false "exprKind" ((PCon "ELet" PWild PWild PWild PWild PWild)) (EVar "KLet"))
(DFunDef false "exprKind" ((PCon "EMatch" PWild PWild)) (EVar "KMatch"))
(DFunDef false "exprKind" ((PCon "EIf" PWild PWild PWild)) (EVar "KIf"))
(DFunDef false "exprKind" ((PCon "EBinOp" PWild PWild PWild PWild)) (EVar "KBinOp"))
(DFunDef false "exprKind" ((PCon "EUnOp" PWild PWild PWild)) (EVar "KUnOp"))
(DFunDef false "exprKind" ((PCon "EInfix" PWild PWild PWild)) (EVar "KInfix"))
(DFunDef false "exprKind" ((PCon "EFieldAccess" PWild PWild PWild)) (EVar "KFieldAccess"))
(DFunDef false "exprKind" ((PCon "ETuple" PWild)) (EVar "KTuple"))
(DFunDef false "exprKind" ((PCon "EListLit" PWild)) (EVar "KListLit"))
(DFunDef false "exprKind" ((PCon "EArrayLit" PWild)) (EVar "KArrayLit"))
(DFunDef false "exprKind" ((PCon "ERangeList" PWild PWild PWild)) (EVar "KRangeList"))
(DFunDef false "exprKind" ((PCon "ERangeArray" PWild PWild PWild)) (EVar "KRangeArray"))
(DFunDef false "exprKind" ((PCon "ESlice" PWild PWild PWild PWild)) (EVar "KSlice"))
(DFunDef false "exprKind" ((PCon "ELetGroup" PWild PWild)) (EVar "KLetGroup"))
(DFunDef false "exprKind" ((PCon "ESection" PWild)) (EVar "KSection"))
(DFunDef false "exprKind" ((PCon "EIndex" PWild PWild)) (EVar "KIndex"))
(DFunDef false "exprKind" ((PCon "EAnnot" PWild PWild)) (EVar "KAnnot"))
(DFunDef false "exprKind" ((PCon "EHeadAnnot" PWild PWild)) (EVar "KHeadAnnot"))
(DFunDef false "exprKind" ((PCon "EBlock" PWild)) (EVar "KBlock"))
(DFunDef false "exprKind" ((PCon "EDo" PWild PWild)) (EVar "KDo"))
(DFunDef false "exprKind" ((PCon "EStringInterp" PWild)) (EVar "KStringInterp"))
(DFunDef false "exprKind" ((PCon "EGuards" PWild)) (EVar "KGuards"))
(DFunDef false "exprKind" ((PCon "ERecordCreate" PWild PWild)) (EVar "KRecordCreate"))
(DFunDef false "exprKind" ((PCon "ERecordUpdate" PWild PWild PWild)) (EVar "KRecordUpdate"))
(DFunDef false "exprKind" ((PCon "EVariantUpdate" PWild PWild PWild)) (EVar "KVariantUpdate"))
(DFunDef false "exprKind" ((PCon "EMapLit" PWild PWild)) (EVar "KMapLit"))
(DFunDef false "exprKind" ((PCon "ESetLit" PWild PWild)) (EVar "KSetLit"))
(DFunDef false "exprKind" ((PCon "EAsPat" PWild PWild)) (EVar "KAsPat"))
(DFunDef false "exprKind" ((PCon "EOrPat" PWild)) (EVar "KOrPat"))
(DFunDef false "exprKind" ((PCon "EMethodRef" PWild)) (EVar "KMethodRef"))
(DFunDef false "exprKind" ((PCon "EDictApp" PWild)) (EVar "KDictApp"))
(DFunDef false "exprKind" ((PCon "EVarAt" PWild PWild)) (EVar "KVarAt"))
(DFunDef false "exprKind" ((PCon "EVarId" PWild PWild)) (EVar "KVarId"))
(DFunDef false "exprKind" ((PCon "EMethodAt" PWild PWild PWild)) (EVar "KMethodAt"))
(DFunDef false "exprKind" ((PCon "EDictAt" PWild PWild)) (EVar "KDictAt"))
(DFunDef false "exprKind" ((PCon "ELoc" PWild PWild)) (EVar "KLoc"))
(DFunDef false "exprKind" ((PCon "EDoOrigin" PWild PWild)) (EVar "KDoOrigin"))
(DFunDef false "exprKind" ((PCon "ENumLit" PWild PWild PWild)) (EVar "KNumLit"))
(DFunDef false "exprKind" ((PCon "EWideLit" PWild PWild PWild PWild)) (EVar "KWideLit"))
(DTypeSig true "childExprs" (TyFun (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "childExprs" ((PCon "ELit" PWild)) (EListLit))
(DFunDef false "childExprs" ((PCon "EVar" PWild)) (EListLit))
(DFunDef false "childExprs" ((PCon "EApp" (PVar "f") (PVar "x"))) (EListLit (EVar "f") (EVar "x")))
(DFunDef false "childExprs" ((PCon "ELam" PWild (PVar "b"))) (EListLit (EVar "b")))
(DFunDef false "childExprs" ((PCon "ELet" PWild PWild PWild (PVar "e1") (PVar "e2"))) (EListLit (EVar "e1") (EVar "e2")))
(DFunDef false "childExprs" ((PCon "EMatch" (PVar "s") (PVar "arms"))) (EBinOp "::" (EVar "s") (EApp (EApp (EDictApp "flatMap") (EVar "armExprs")) (EVar "arms"))))
(DFunDef false "childExprs" ((PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EListLit (EVar "c") (EVar "t") (EVar "el")))
(DFunDef false "childExprs" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EListLit (EVar "a") (EVar "b")))
(DFunDef false "childExprs" ((PCon "EUnOp" PWild (PVar "a") PWild)) (EListLit (EVar "a")))
(DFunDef false "childExprs" ((PCon "EInfix" PWild (PVar "a") (PVar "b"))) (EListLit (EVar "a") (EVar "b")))
(DFunDef false "childExprs" ((PCon "EFieldAccess" (PVar "e") PWild PWild)) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "ETuple" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "EListLit" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "EArrayLit" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "ERangeList" (PVar "lo") (PVar "hi") PWild)) (EListLit (EVar "lo") (EVar "hi")))
(DFunDef false "childExprs" ((PCon "ERangeArray" (PVar "lo") (PVar "hi") PWild)) (EListLit (EVar "lo") (EVar "hi")))
(DFunDef false "childExprs" ((PCon "ESlice" (PVar "e") (PVar "lo") (PVar "hi") PWild)) (EListLit (EVar "e") (EVar "lo") (EVar "hi")))
(DFunDef false "childExprs" ((PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "letBindExprs")) (EVar "binds")) (EListLit (EVar "body"))))
(DFunDef false "childExprs" ((PCon "ESection" (PVar "s"))) (EApp (EVar "sectionExprs") (EVar "s")))
(DFunDef false "childExprs" ((PCon "EIndex" (PVar "a") (PVar "i"))) (EListLit (EVar "a") (EVar "i")))
(DFunDef false "childExprs" ((PCon "EAnnot" (PVar "e") PWild)) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EHeadAnnot" (PVar "e") PWild)) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EDictApp "flatMap") (EVar "stmtExprs")) (EVar "stmts")))
(DFunDef false "childExprs" ((PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EDictApp "flatMap") (EVar "stmtExprs")) (EVar "stmts")))
(DFunDef false "childExprs" ((PCon "EStringInterp" (PVar "parts"))) (EApp (EApp (EDictApp "flatMap") (EVar "interpPartExprs")) (EVar "parts")))
(DFunDef false "childExprs" ((PCon "EGuards" (PVar "arms"))) (EApp (EApp (EDictApp "flatMap") (EVar "guardArmExprs")) (EVar "arms")))
(DFunDef false "childExprs" ((PCon "ERecordCreate" PWild (PVar "fs"))) (EApp (EApp (EMethodRef "map") (EVar "fieldAssignExpr")) (EVar "fs")))
(DFunDef false "childExprs" ((PCon "ERecordUpdate" (PVar "e") (PVar "fs") PWild)) (EBinOp "::" (EVar "e") (EApp (EApp (EMethodRef "map") (EVar "fieldAssignExpr")) (EVar "fs"))))
(DFunDef false "childExprs" ((PCon "EVariantUpdate" PWild (PVar "e") (PVar "fs"))) (EBinOp "::" (EVar "e") (EApp (EApp (EMethodRef "map") (EVar "fieldAssignExpr")) (EVar "fs"))))
(DFunDef false "childExprs" ((PCon "EMapLit" PWild (PVar "kvs"))) (EApp (EApp (EDictApp "flatMap") (EVar "kvExprs")) (EVar "kvs")))
(DFunDef false "childExprs" ((PCon "ESetLit" PWild (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "EAsPat" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EOrPat" (PVar "es"))) (EVar "es"))
(DFunDef false "childExprs" ((PCon "EMethodRef" PWild)) (EListLit))
(DFunDef false "childExprs" ((PCon "EDictApp" PWild)) (EListLit))
(DFunDef false "childExprs" ((PCon "EVarAt" PWild PWild)) (EListLit))
(DFunDef false "childExprs" ((PCon "EVarId" PWild PWild)) (EListLit))
(DFunDef false "childExprs" ((PCon "EMethodAt" PWild PWild PWild)) (EListLit))
(DFunDef false "childExprs" ((PCon "EDictAt" PWild PWild)) (EListLit))
(DFunDef false "childExprs" ((PCon "ELoc" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "EDoOrigin" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "childExprs" ((PCon "ENumLit" PWild PWild PWild)) (EListLit))
(DFunDef false "childExprs" ((PCon "EWideLit" PWild PWild PWild PWild)) (EListLit))
(DTypeSig false "armExprs" (TyFun (TyCon "Arm") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "armExprs" ((PCon "Arm" PWild (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "guardExprs")) (EVar "gs")) (EListLit (EVar "body"))))
(DTypeSig false "guardExprs" (TyFun (TyCon "Guard") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "guardExprs" ((PCon "GBool" (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "guardExprs" ((PCon "GBind" PWild (PVar "e"))) (EListLit (EVar "e")))
(DTypeSig true "stmtExprs" (TyFun (TyCon "DoStmt") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "stmtExprs" ((PCon "DoExpr" (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoBind" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoLet" PWild PWild PWild (PVar "e") PWild)) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoAssign" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "stmtExprs" ((PCon "DoFieldAssign" PWild PWild (PVar "e"))) (EListLit (EVar "e")))
(DTypeSig false "letBindExprs" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "letBindExprs" ((PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EApp (EApp (EMethodRef "map") (ELam ((PCon "FunClause" PWild (PVar "body"))) (EVar "body"))) (EVar "clauses")))
(DTypeSig false "sectionExprs" (TyFun (TyCon "Section") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "sectionExprs" ((PCon "SecBare" PWild)) (EListLit))
(DFunDef false "sectionExprs" ((PCon "SecRight" PWild (PVar "e"))) (EListLit (EVar "e")))
(DFunDef false "sectionExprs" ((PCon "SecLeft" (PVar "e") PWild)) (EListLit (EVar "e")))
(DTypeSig false "interpPartExprs" (TyFun (TyCon "InterpPart") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "interpPartExprs" ((PCon "InterpStr" PWild)) (EListLit))
(DFunDef false "interpPartExprs" ((PCon "InterpExpr" (PVar "e"))) (EListLit (EVar "e")))
(DTypeSig false "guardArmExprs" (TyFun (TyCon "GuardArm") (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "guardArmExprs" ((PCon "GuardArm" (PVar "gs") (PVar "body"))) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (EVar "guardExprs")) (EVar "gs")) (EListLit (EVar "body"))))
(DTypeSig false "fieldAssignExpr" (TyFun (TyCon "FieldAssign") (TyCon "Expr")))
(DFunDef false "fieldAssignExpr" ((PCon "FieldAssign" PWild (PVar "e"))) (EVar "e"))
(DTypeSig false "kvExprs" (TyFun (TyTuple (TyCon "Expr") (TyCon "Expr")) (TyApp (TyCon "List") (TyCon "Expr"))))
(DFunDef false "kvExprs" ((PTuple (PVar "k") (PVar "v"))) (EListLit (EVar "k") (EVar "v")))
(DTypeSig true "mapChildExprs" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "mapChildExprs" (PWild (PCon "ELit" (PVar "l"))) (EApp (EVar "ELit") (EVar "l")))
(DFunDef false "mapChildExprs" (PWild (PCon "EVar" (PVar "n"))) (EApp (EVar "EVar") (EVar "n")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "EApp") (EApp (EVar "g") (EVar "a"))) (EApp (EVar "g") (EVar "b"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EVar "g") (EVar "b"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ELet" (PVar "m") (PVar "r") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EVar "g") (EVar "e1"))) (EApp (EVar "g") (EVar "e2"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EVar "g") (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapArm") (EVar "g"))) (EVar "arms"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EVar "g") (EVar "c"))) (EApp (EVar "g") (EVar "t"))) (EApp (EVar "g") (EVar "el"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EVar "g") (EVar "a"))) (EApp (EVar "g") (EVar "b"))) (EVar "r")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EVar "g") (EVar "a"))) (EVar "r")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EVar "g") (EVar "a"))) (EApp (EVar "g") (EVar "b"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EFieldAccess" (PVar "e0") (PVar "n") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EVar "g") (EVar "e0"))) (EVar "n")) (EVar "r")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EMethodRef "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EMethodRef "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EVar "g") (EVar "lo"))) (EApp (EVar "g") (EVar "hi"))) (EVar "incl")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EVar "g") (EVar "lo"))) (EApp (EVar "g") (EVar "hi"))) (EVar "incl")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ESlice" (PVar "e0") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EVar "g") (EVar "e0"))) (EApp (EVar "g") (EVar "lo"))) (EApp (EVar "g") (EVar "hi"))) (EVar "incl")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ELetGroup" (PVar "bs") (PVar "e2"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapLetBind") (EVar "g"))) (EVar "bs"))) (EApp (EVar "g") (EVar "e2"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ESection" (PVar "s"))) (EApp (EVar "ESection") (EApp (EApp (EVar "mapSection") (EVar "g")) (EVar "s"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EIndex" (PVar "e0") (PVar "i"))) (EApp (EApp (EVar "EIndex") (EApp (EVar "g") (EVar "e0"))) (EApp (EVar "g") (EVar "i"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EVar "g") (EVar "e0"))) (EVar "t")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EHeadAnnot" (PVar "e0") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EVar "g") (EVar "e0"))) (EVar "t")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapDoStmt") (EVar "g"))) (EVar "stmts"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "d")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapDoStmt") (EVar "g"))) (EVar "stmts"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapInterp") (EVar "g"))) (EVar "parts"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapGuardArm") (EVar "g"))) (EVar "arms"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapFieldAssign") (EVar "g"))) (EVar "fs"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ERecordUpdate" (PVar "e0") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EVar "g") (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapFieldAssign") (EVar "g"))) (EVar "fs"))) (EVar "r")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EVariantUpdate" (PVar "c") (PVar "e0") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EVar "g") (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapFieldAssign") (EVar "g"))) (EVar "fs"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "kv")) (ETuple (EApp (EVar "g") (EApp (EVar "fst") (EVar "kv"))) (EApp (EVar "g") (EApp (EVar "snd") (EVar "kv")))))) (EVar "kvs"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EAsPat" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "EAsPat") (EVar "x")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EOrPat" (PVar "es"))) (EApp (EVar "EOrPat") (EApp (EApp (EMethodRef "map") (EVar "g")) (EVar "es"))))
(DFunDef false "mapChildExprs" (PWild (PCon "EMethodRef" (PVar "n"))) (EApp (EVar "EMethodRef") (EVar "n")))
(DFunDef false "mapChildExprs" (PWild (PCon "EDictApp" (PVar "n"))) (EApp (EVar "EDictApp") (EVar "n")))
(DFunDef false "mapChildExprs" (PWild (PCon "EVarAt" (PVar "n") (PVar "a"))) (EApp (EApp (EVar "EVarAt") (EVar "n")) (EVar "a")))
(DFunDef false "mapChildExprs" (PWild (PCon "EVarId" (PVar "n") (PVar "i"))) (EApp (EApp (EVar "EVarId") (EVar "n")) (EVar "i")))
(DFunDef false "mapChildExprs" (PWild (PCon "EMethodAt" (PVar "n") (PVar "s") (PVar "ev"))) (EApp (EApp (EApp (EVar "EMethodAt") (EVar "n")) (EVar "s")) (EVar "ev")))
(DFunDef false "mapChildExprs" (PWild (PCon "EDictAt" (PVar "n") (PVar "ev"))) (EApp (EApp (EVar "EDictAt") (EVar "n")) (EVar "ev")))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildExprs" ((PVar "g") (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapChildExprs" (PWild (PCon "ENumLit" (PVar "n") (PVar "ev") (PVar "lexeme"))) (EApp (EApp (EApp (EVar "ENumLit") (EVar "n")) (EVar "ev")) (EVar "lexeme")))
(DFunDef false "mapChildExprs" (PWild (PCon "EWideLit" (PVar "hi") (PVar "lo") (PVar "ev") (PVar "lexeme"))) (EApp (EApp (EApp (EApp (EVar "EWideLit") (EVar "hi")) (EVar "lo")) (EVar "ev")) (EVar "lexeme")))
(DTypeSig false "mapArm" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Arm") (TyCon "Arm"))))
(DFunDef false "mapArm" ((PVar "g") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "b"))) (EApp (EApp (EApp (EVar "Arm") (EVar "p")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapGuard") (EVar "g"))) (EVar "gs"))) (EApp (EVar "g") (EVar "b"))))
(DTypeSig false "mapGuard" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Guard") (TyCon "Guard"))))
(DFunDef false "mapGuard" ((PVar "g") (PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapGuard" ((PVar "g") (PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EVar "p")) (EApp (EVar "g") (EVar "e"))))
(DTypeSig false "mapGuardArm" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "GuardArm") (TyCon "GuardArm"))))
(DFunDef false "mapGuardArm" ((PVar "g") (PCon "GuardArm" (PVar "gs") (PVar "b"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapGuard") (EVar "g"))) (EVar "gs"))) (EApp (EVar "g") (EVar "b"))))
(DTypeSig false "mapLetBind" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "mapLetBind" ((PVar "g") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "mapFunClause") (EVar "g"))) (EVar "clauses"))) (EVar "site")) (EVar "bid")))
(DTypeSig false "mapFunClause" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "FunClause") (TyCon "FunClause"))))
(DFunDef false "mapFunClause" ((PVar "g") (PCon "FunClause" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EVar "g") (EVar "b"))))
(DTypeSig false "mapSection" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "Section") (TyCon "Section"))))
(DFunDef false "mapSection" (PWild (PCon "SecBare" (PVar "op"))) (EApp (EVar "SecBare") (EVar "op")))
(DFunDef false "mapSection" ((PVar "g") (PCon "SecRight" (PVar "op") (PVar "e"))) (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapSection" ((PVar "g") (PCon "SecLeft" (PVar "e") (PVar "op"))) (EApp (EApp (EVar "SecLeft") (EApp (EVar "g") (EVar "e"))) (EVar "op")))
(DTypeSig false "mapFieldAssign" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign"))))
(DFunDef false "mapFieldAssign" ((PVar "g") (PCon "FieldAssign" (PVar "n") (PVar "v"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EVar "g") (EVar "v"))))
(DTypeSig false "mapDoStmt" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "DoStmt") (TyCon "DoStmt"))))
(DFunDef false "mapDoStmt" ((PVar "g") (PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapDoStmt" ((PVar "g") (PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EVar "p")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapDoStmt" ((PVar "g") (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EVar "p")) (EApp (EVar "g") (EVar "e"))) (EVar "site")))
(DFunDef false "mapDoStmt" ((PVar "g") (PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EVar "g") (EVar "e"))))
(DFunDef false "mapDoStmt" ((PVar "g") (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EVar "g") (EVar "e"))))
(DTypeSig false "mapInterp" (TyFun (TyFun (TyCon "Expr") (TyCon "Expr")) (TyFun (TyCon "InterpPart") (TyCon "InterpPart"))))
(DFunDef false "mapInterp" (PWild (PCon "InterpStr" (PVar "s"))) (EApp (EVar "InterpStr") (EVar "s")))
(DFunDef false "mapInterp" ((PVar "g") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EVar "g") (EVar "e"))))
(DData Public "BodyOwner" () ((variant "OwnerClause" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")))) (variant "OwnerImplMethod" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")))) (variant "OwnerIfaceDefault" (ConPos (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")))) (variant "OwnerTest" (ConPos (TyCon "String"))) (variant "OwnerProp" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "PropParam")))) (variant "OwnerLetGroup" (ConPos (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat"))))) ())
(DData Public "DeclBody" () ((variant "DeclBody" (ConPos (TyCon "BodyOwner") (TyCon "Expr")))) ())
(DTypeSig true "declBodies" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "DeclBody"))))
(DFunDef false "declBodies" ((PCon "DTypeSig" PWild PWild PWild PWild)) (EListLit))
(DFunDef false "declBodies" ((PCon "DExtern" PWild)) (EListLit))
(DFunDef false "declBodies" ((PCon "DFunDef" PWild (PVar "name") (PVar "ps") (PVar "body") PWild PWild)) (EListLit (EApp (EApp (EVar "DeclBody") (EApp (EApp (EVar "OwnerClause") (EVar "name")) (EVar "ps"))) (EVar "body"))))
(DFunDef false "declBodies" ((PRec "DData" ((rf "dataName" PWild)) true)) (EListLit))
(DFunDef false "declBodies" ((PCon "DUse" PWild PWild PWild)) (EListLit))
(DFunDef false "declBodies" ((PCon "DEffect" PWild PWild PWild PWild PWild PWild)) (EListLit))
(DFunDef false "declBodies" ((PCon "DProp" PWild (PVar "name") (PVar "params") (PVar "body"))) (EListLit (EApp (EApp (EVar "DeclBody") (EApp (EApp (EVar "OwnerProp") (EVar "name")) (EVar "params"))) (EVar "body"))))
(DFunDef false "declBodies" ((PCon "DTest" PWild (PVar "name") (PVar "body"))) (EListLit (EApp (EApp (EVar "DeclBody") (EApp (EVar "OwnerTest") (EVar "name"))) (EVar "body"))))
(DFunDef false "declBodies" ((PRec "DInterface" ((rf "ifaceOrigin" PWild) (rf "name" None) (rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "ifaceDefaultBody") (EVar "name"))) (EVar "methods")))
(DFunDef false "declBodies" ((PRec "DImpl" ((rf "implOrigin" PWild) (rf "iface" None) (rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (EApp (EVar "implMethodBody") (EVar "iface"))) (EVar "methods")))
(DFunDef false "declBodies" ((PRec "DTypeAlias" ((rf "tyAliasName" PWild)) true)) (EListLit))
(DFunDef false "declBodies" ((PRec "DNewtype" ((rf "newtypeName" PWild)) true)) (EListLit))
(DFunDef false "declBodies" ((PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EDictApp "flatMap") (EVar "letGroupBodies")) (EVar "binds")))
(DFunDef false "declBodies" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declBodies") (EVar "d")))
(DTypeSig false "ifaceDefaultBody" (TyFun (TyCon "String") (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "DeclBody")))))
(DFunDef false "ifaceDefaultBody" (PWild (PCon "IfaceMethod" PWild PWild (PCon "None") PWild)) (EListLit))
(DFunDef false "ifaceDefaultBody" ((PVar "iface") (PCon "IfaceMethod" (PVar "m") PWild (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "body"))) PWild)) (EListLit (EApp (EApp (EVar "DeclBody") (EApp (EApp (EApp (EVar "OwnerIfaceDefault") (EVar "iface")) (EVar "m")) (EVar "ps"))) (EVar "body"))))
(DTypeSig false "implMethodBody" (TyFun (TyCon "String") (TyFun (TyCon "ImplMethod") (TyCon "DeclBody"))))
(DFunDef false "implMethodBody" ((PVar "iface") (PCon "ImplMethod" (PVar "m") (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "DeclBody") (EApp (EApp (EApp (EVar "OwnerImplMethod") (EVar "iface")) (EVar "m")) (EVar "ps"))) (EVar "body")))
(DTypeSig false "letGroupBodies" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "DeclBody"))))
(DFunDef false "letGroupBodies" ((PCon "LetBind" (PVar "name") (PVar "clauses") PWild PWild)) (EApp (EApp (EMethodRef "map") (ELam ((PCon "FunClause" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "DeclBody") (EApp (EApp (EVar "OwnerLetGroup") (EVar "name")) (EVar "ps"))) (EVar "body")))) (EVar "clauses")))
(DTypeSig false "nodeLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "nodeLoc" ((PCon "ELit" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EVar" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EApp" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ELam" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ELet" PWild PWild PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EMatch" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EIf" PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EBinOp" PWild PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EUnOp" PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EInfix" PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EFieldAccess" PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ETuple" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EListLit" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EArrayLit" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ERangeList" PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ERangeArray" PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ESlice" PWild PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ELetGroup" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ESection" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EIndex" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EAnnot" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EHeadAnnot" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EBlock" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EDo" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EStringInterp" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EGuards" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ERecordCreate" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ERecordUpdate" PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EVariantUpdate" PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EMapLit" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ESetLit" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EAsPat" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EOrPat" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EMethodRef" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EDictApp" PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EVarAt" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EVarId" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EMethodAt" PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EDictAt" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "nodeLoc" ((PCon "EDoOrigin" PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "ENumLit" PWild PWild PWild)) (EVar "None"))
(DFunDef false "nodeLoc" ((PCon "EWideLit" PWild PWild PWild PWild)) (EVar "None"))
(DTypeSig true "exprSpan" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "exprSpan" ((PVar "e")) (EMatch (EApp (EVar "nodeLoc") (EVar "e")) (arm (PCon "Some" (PVar "l")) () (EApp (EVar "Some") (EVar "l"))) (arm (PCon "None") () (EApp (EApp (EApp (EMethodRef "fold") (EVar "joinSpan")) (EVar "None")) (EApp (EApp (EMethodRef "map") (EVar "exprSpan")) (EApp (EVar "childExprs") (EVar "e")))))))
(DTypeSig false "joinSpan" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "joinSpan" ((PCon "None") (PVar "b")) (EVar "b"))
(DFunDef false "joinSpan" ((PVar "a") (PCon "None")) (EVar "a"))
(DFunDef false "joinSpan" ((PCon "Some" (PCon "Loc" (PVar "f") (PVar "sl") (PVar "sc") (PVar "el") (PVar "ec"))) (PCon "Some" (PCon "Loc" PWild (PVar "sl2") (PVar "sc2") (PVar "el2") (PVar "ec2")))) (EBlock (DoLet false false (PTuple (PVar "l1") (PVar "c1")) (EApp (EApp (EMethodRef "min") (ETuple (EVar "sl") (EVar "sc"))) (ETuple (EVar "sl2") (EVar "sc2")))) (DoLet false false (PTuple (PVar "l2") (PVar "c2")) (EApp (EApp (EMethodRef "max") (ETuple (EVar "el") (EVar "ec"))) (ETuple (EVar "el2") (EVar "ec2")))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "f")) (EVar "l1")) (EVar "c1")) (EVar "l2")) (EVar "c2"))))))
