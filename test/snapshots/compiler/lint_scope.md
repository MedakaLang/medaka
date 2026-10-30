# META
source_lines=448
stages=DESUGAR,MARK
# SOURCE
-- compiler/tools/lint_scope.mdk — the per-file scope model of the lint rules: every
-- binder of one file with its kind and span, and for every identifier use the
-- binder it resolves to.  Built from the raw (pre-desugar) AST with a frame
-- stack, the walk `tools/refindex.mdk` runs for references, but without its
-- project-wide index tables: one file in, one immutable value out.
--
-- A use resolves to the innermost frame that binds its name; a file's own
-- top-level names shadow its imports.  A name no frame binds is unresolved,
-- which is what an `import m.*` member looks like (`wildImports` lists those
-- modules).  The walk is built on `frontend.ast_walk`: the binding forms are
-- named here and every other node descends through `childExprs`, so a new
-- expression constructor that binds a name is the one case this walk must learn.

import frontend.ast.{
  Arm(..),
  Decl(..),
  DoStmt(..),
  Expr(..),
  ExternDecl(..),
  FunClause(..),
  Guard(..),
  GuardArm(..),
  IfaceMethod(..),
  LetBind(..),
  Loc(..),
  Pat(..),
  PropParam(..),
  RecPatField(..),
  UseMember(..),
  UsePath(..),
  noDeclLoc,
}
import frontend.ast_walk.{BodyOwner(..), DeclBody(..), childExprs, declBodies}
import hash_map.{HashMap, new, setInPlace, get, findWithDefault}
import support.util.{reverseL, startsWith}

-- Where a name is bound.  `BImport` is a member of an `import m.{…}` group,
-- `BTopLevel` a file-level function, extern or interface method, `BLetGroup` a
-- file-level `let rec … with …` binding, `BWhere` a `where` or local
-- `let rec` binding, `BLet` a `let` pattern, `BLambda` a lambda parameter,
-- `BParam` a function, method or `prop` parameter, `BMatchArm` a `match` arm or
-- guard-bind pattern and `BDoBind` a `do` statement's bind pattern.
public export data BinderKind =
  | BParam
  | BLet
  | BLambda
  | BMatchArm
  | BDoBind
  | BWhere
  | BLetGroup
  | BImport
  | BTopLevel
  deriving (Eq, Debug)

-- One bound name.  `binderSpan` is the name token where the parser kept one.
-- `binderFrom` is the module path of an import member and `binderOrigin` the
-- name it has in that module (they differ under `a as b`); both are empty for
-- every other kind.  `binderId` is unique within one file.
public export data Binder = Binder {
  binderName : String,
  binderKind : BinderKind,
  binderSpan : Loc,
  binderId : Int,
  binderFrom : List String,
  binderOrigin : String,
}

-- One identifier use: the name, the span of its nearest enclosing node with
-- one, and the binder it resolved to (`None` = unresolved).
public export data Use = Use {
  useName : String,
  useSite : Loc,
  useBinder : Option Binder,
}

-- Abstract: read through the accessors below.  `fsSites` maps the start
-- position of every binder site, every alternate or-pattern and clause site, and
-- every resolved use to its binder; `fsCounts` is the use count per binder id.
export data FileScopes = FileScopes {
  fsBinders : List Binder,
  fsUses : List Use,
  fsWild : List (List String),
  fsSites : HashMap String Binder,
  fsCounts : HashMap Int Int,
}

-- Walk state: binders and uses newest first, alternate sites, the id counter.
data W =
  W (Ref (List Binder)) (Ref (List Use)) (Ref (List (Loc, Binder))) (Ref Int)

-- (name, name token, kind, import module path, import origin name)
data Site = Site String Loc BinderKind (List String) String

siteKey : Loc -> String
siteKey (Loc _ l c _ _) = "\{l}:\{c}"

-- The binder a position stands for: a use resolves to what it names, a binder
-- site (or an alternate site of the same binder) to itself.
export
binderOf : FileScopes -> Loc -> Option Binder
binderOf fs loc = get (siteKey loc) fs.fsSites

export
allBinders : FileScopes -> List Binder
allBinders fs = fs.fsBinders

export
allUses : FileScopes -> List Use
allUses fs = fs.fsUses

-- The modules a file imports with `import m.*`.
export
wildImports : FileScopes -> List (List String)
wildImports fs = fs.fsWild

-- Every use of `name`, resolved or not, whose position lies on a line in
-- `[fromLine, toLine]`.
export
usesNamedIn : FileScopes -> Int -> Int -> String -> List Use
usesNamedIn fs fromLine toLine name =
  filter
    (u => u.useName == name && lineWithin fromLine toLine u.useSite)
    fs.fsUses

-- Every binder of `name` that sits on a line in `[fromLine, toLine]`.
export
bindersNamedIn : FileScopes -> Int -> Int -> String -> List Binder
bindersNamedIn fs fromLine toLine name =
  filter
    (b => b.binderName == name && lineWithin fromLine toLine b.binderSpan)
    fs.fsBinders

-- Every binder of `name` in the file.
export
bindersNamed : FileScopes -> String -> List Binder
bindersNamed fs name = filter (b => b.binderName == name) fs.fsBinders

lineWithin : Int -> Int -> Loc -> Bool
lineWithin lo hi (Loc _ l _ _ _) = lo <= l && l <= hi

localKind : BinderKind -> Bool
localKind BImport = False
localKind BTopLevel = False
localKind BLetGroup = False
localKind BParam = True
localKind BLet = True
localKind BLambda = True
localKind BMatchArm = True
localKind BDoBind = True
localKind BWhere = True

-- How many uses resolved to the binder.
useCount : FileScopes -> Binder -> Int
useCount fs b = findWithDefault 0 b.binderId fs.fsCounts

-- The local binders nothing uses, in source order.  A name starting with `_` is
-- an intentional discard and is not reported; file-level names and import
-- members are not either, since another module may use them (see `importUses`).
export
unusedBinders : FileScopes -> List Binder
unusedBinders fs =
  filter
    (b =>
      localKind b.binderKind
        && not (isDiscard b.binderName)
        && useCount fs b == 0)
    fs.fsBinders

isDiscard : String -> Bool
isDiscard name = startsWith "_" name

-- Every import member with the number of uses that resolved to it.
export
importUses : FileScopes -> List (Binder, Int)
importUses fs =
  map
    (b => (b, useCount fs b))
    (filter (b => b.binderKind == BImport) fs.fsBinders)

-- ── building ──────────────────────────────────────────────────────────────────
export
buildScopes : List Decl -> FileScopes
buildScopes prog =
  let w = W (Ref []) (Ref []) (Ref []) (Ref 0)
  let imports = mintFrame w (flatMap importSites prog)
  let tops = mintFrame w (flatMap topSites prog)
  let _ = walkDecls w [tops, imports] prog
  finish w (flatMap wildPaths prog)

finish : W -> List (List String) -> FileScopes
finish (W bs us alts _) wild =
  let binders = reverseL !bs
  let uses = reverseL !us
  let sites = new ()
  let counts = new ()
  let _ = setUseSites sites uses
  let _ = setBinderSites sites binders
  let _ = setAltSites sites (reverseL !alts)
  let _ = countUses counts uses
  FileScopes {
    fsBinders = binders,
    fsUses = uses,
    fsWild = wild,
    fsSites = sites,
    fsCounts = counts,
  }

setUseSites : HashMap String Binder -> List Use -> Unit
setUseSites _ [] = ()
setUseSites m ((Use { useSite = loc, useBinder = (Some b), ... }) :: rest) =
  let _ = setInPlace (siteKey loc) b m
  setUseSites m rest
setUseSites m (_ :: rest) = setUseSites m rest

setBinderSites : HashMap String Binder -> List Binder -> Unit
setBinderSites _ [] = ()
setBinderSites m (b :: rest) =
  let _ = setInPlace (siteKey b.binderSpan) b m
  setBinderSites m rest

setAltSites : HashMap String Binder -> List (Loc, Binder) -> Unit
setAltSites _ [] = ()
setAltSites m ((loc, b) :: rest) =
  let _ = setInPlace (siteKey loc) b m
  setAltSites m rest

countUses : HashMap Int Int -> List Use -> Unit
countUses _ [] = ()
countUses m ((Use { useBinder = (Some b), ... }) :: rest) =
  let _ = setInPlace b.binderId (findWithDefault 0 b.binderId m + 1) m
  countUses m rest
countUses m (_ :: rest) = countUses m rest

-- ── binder sites ──────────────────────────────────────────────────────────────
importSites : Decl -> List Site
importSites (DUse _ (UseGroup path members) _) = map (importSite path) members
importSites _ = []

importSite : List String -> UseMember -> Site
importSite path (UseMember n _ loc alias) =
  Site (fromOption n alias) loc BImport path n

fromOption : a -> Option a -> a
fromOption d None = d
fromOption _ (Some x) = x

wildPaths : Decl -> List (List String)
wildPaths (DUse _ (UseWild path) _) = [path]
wildPaths _ = []

topSites : Decl -> List Site
topSites (DFunDef _ n _ _ site _) = [plainSite n site BTopLevel]
topSites (DExtern (ExternDecl { edName = n, edLoc = l, ... })) =
  [plainSite n l BTopLevel]
topSites (DLetGroup _ binds) = map (letBindSite BLetGroup) binds
topSites (DInterface { methods, ... }) = flatMap ifaceMethodSite methods
topSites (DAttrib _ d) = topSites d
topSites _ = []

ifaceMethodSite : IfaceMethod -> List Site
ifaceMethodSite (IfaceMethod n _ _ loc) =
  [plainSite n (fromOption noDeclLoc loc) BTopLevel]

plainSite : String -> Loc -> BinderKind -> Site
plainSite n loc k = Site n loc k [] ""

letBindSite : BinderKind -> LetBind -> Site
letBindSite k (LetBind n _ loc _) = plainSite n loc k

-- The names a pattern binds, with their name tokens.  Every alternative of an
-- or-pattern is listed: the later ones become alternate sites of the first's
-- binder (`mintFrame` joins equal names).
patSites : BinderKind -> Pat -> List Site
patSites k (PVar x l _) = [plainSite x l k]
patSites _ PWild = []
patSites _ (PLit _) = []
patSites k (PCon _ ps) = flatMap (patSites k) ps
patSites k (PCons a b) = patSites k a ++ patSites k b
patSites k (PTuple ps) = flatMap (patSites k) ps
patSites k (PList ps) = flatMap (patSites k) ps
patSites k (PAs x l _ p) = plainSite x l k :: patSites k p
patSites k (POr ps) = flatMap (patSites k) ps
patSites _ (PRng _ _ _) = []
patSites k (PRec _ fields _) = flatMap (recFieldSites k) fields

recFieldSites : BinderKind -> RecPatField -> List Site
recFieldSites k (RecPatField name l _ None) = [plainSite name l k]
recFieldSites k (RecPatField _ _ _ (Some p)) = patSites k p

ownerSites : BodyOwner -> List Site
ownerSites (OwnerClause _ ps) = flatMap (patSites BParam) ps
ownerSites (OwnerImplMethod _ _ ps) = flatMap (patSites BParam) ps
ownerSites (OwnerIfaceDefault _ _ ps) = flatMap (patSites BParam) ps
ownerSites (OwnerTest _) = []
ownerSites (OwnerProp _ params) = map propParamSite params
ownerSites (OwnerLetGroup _ ps) = flatMap (patSites BParam) ps

propParamSite : PropParam -> Site
propParamSite (PropParam n l _) = plainSite n l BParam

-- ── frames ────────────────────────────────────────────────────────────────────
-- One frame from a site list.  A name met again in the same frame is another
-- site of the binder already minted (an or-pattern's later alternative, a later
-- clause of one function), not a new binder.
mintFrame : W -> List Site -> List Binder
mintFrame w sites = reverseL (mintFrameGo w [] sites)

mintFrameGo : W -> List Binder -> List Site -> List Binder
mintFrameGo _ acc [] = acc
mintFrameGo w acc ((Site n l k from origin) :: rest) = match findBinder n acc
  Some b =>
    let _ = pushAlt w l b
    mintFrameGo w acc rest
  None => mintFrameGo w (mintOne w n l k from origin :: acc) rest

pushAlt : W -> Loc -> Binder -> Unit
pushAlt (W _ _ alts _) l b = alts := (l, b) :: !alts

mintOne : W -> String -> Loc -> BinderKind -> List String -> String -> Binder
mintOne (W bs _ _ counter) n l k from origin =
  let id = !counter
  counter := id + 1
  let b = Binder {
    binderName = n,
    binderKind = k,
    binderSpan = l,
    binderId = id,
    binderFrom = from,
    binderOrigin = origin,
  }
  bs := b :: !bs
  b

findBinder : String -> List Binder -> Option Binder
findBinder _ [] = None
findBinder n (b :: rest) =
  if b.binderName == n then Some b else findBinder n rest

lookupFrames : String -> List (List Binder) -> Option Binder
lookupFrames _ [] = None
lookupFrames n (frame :: rest) = match findBinder n frame
  Some b => Some b
  None => lookupFrames n rest

noteUse : W -> List (List Binder) -> Loc -> String -> Unit
noteUse (W _ us _ _) scope loc n =
  us :=
    Use { useName = n, useSite = loc, useBinder = lookupFrames n scope } :: !us

-- ── the walk ──────────────────────────────────────────────────────────────────
walkDecls : W -> List (List Binder) -> List Decl -> Unit
walkDecls _ _ [] = ()
walkDecls w scope (d :: rest) =
  let _ = walkBodies w scope (declBodies d)
  walkDecls w scope rest

walkBodies : W -> List (List Binder) -> List DeclBody -> Unit
walkBodies _ _ [] = ()
walkBodies w scope ((DeclBody owner body) :: rest) =
  let frame = mintFrame w (ownerSites owner)
  let _ = walkExpr w (frame :: scope) noDeclLoc body
  walkBodies w scope rest

walkExpr : W -> List (List Binder) -> Loc -> Expr -> Unit
walkExpr w scope _ (ELoc l e) = walkExpr w scope l e
walkExpr w scope _ (EDoOrigin l e) = walkExpr w scope l e
walkExpr w scope loc (EVar n) = noteUse w scope loc n
walkExpr w scope loc (ELam ps body) =
  let frame = mintFrame w (flatMap (patSites BLambda) ps)
  walkExpr w (frame :: scope) loc body
walkExpr w scope loc (ELet _ isRec p rhs body) =
  let frame = mintFrame w (patSites BLet p)
  let _ = walkExpr w (if isRec then frame :: scope else scope) loc rhs
  walkExpr w (frame :: scope) loc body
walkExpr w scope loc (ELetGroup binds body) =
  let frame = mintFrame w (map (letBindSite BWhere) binds)
  let scope1 = frame :: scope
  let _ = walkClauses w scope1 loc (flatMap letBindClauses binds)
  walkExpr w scope1 loc body
walkExpr w scope loc (EMatch scrut arms) =
  let _ = walkExpr w scope loc scrut
  walkArms w scope loc arms
walkExpr w scope loc (EBlock stmts) = walkStmts w scope loc stmts
walkExpr w scope loc (EDo _ stmts) = walkStmts w scope loc stmts
walkExpr w scope loc (EGuards arms) = walkGuardArms w scope loc arms
walkExpr w scope loc e = walkEach w scope loc (childExprs e)

letBindClauses : LetBind -> List FunClause
letBindClauses (LetBind _ clauses _ _) = clauses

walkEach : W -> List (List Binder) -> Loc -> List Expr -> Unit
walkEach _ _ _ [] = ()
walkEach w scope loc (e :: rest) =
  let _ = walkExpr w scope loc e
  walkEach w scope loc rest

walkClauses : W -> List (List Binder) -> Loc -> List FunClause -> Unit
walkClauses _ _ _ [] = ()
walkClauses w scope loc ((FunClause ps body) :: rest) =
  let frame = mintFrame w (flatMap (patSites BParam) ps)
  let _ = walkExpr w (frame :: scope) loc body
  walkClauses w scope loc rest

walkArms : W -> List (List Binder) -> Loc -> List Arm -> Unit
walkArms _ _ _ [] = ()
walkArms w scope loc ((Arm p gs body) :: rest) =
  let scope1 = mintFrame w (patSites BMatchArm p) :: scope
  let scope2 = walkGuards w scope1 loc gs
  let _ = walkExpr w scope2 loc body
  walkArms w scope loc rest

walkGuardArms : W -> List (List Binder) -> Loc -> List GuardArm -> Unit
walkGuardArms _ _ _ [] = ()
walkGuardArms w scope loc ((GuardArm gs body) :: rest) =
  let scope2 = walkGuards w scope loc gs
  let _ = walkExpr w scope2 loc body
  walkGuardArms w scope loc rest

-- A guard list threads scope: a `Pat <- e` guard binds for the guards after it.
walkGuards : W -> List (List Binder) -> Loc -> List Guard -> List (List Binder)
walkGuards _ scope _ [] = scope
walkGuards w scope loc ((GBool e) :: rest) =
  let _ = walkExpr w scope loc e
  walkGuards w scope loc rest
walkGuards w scope loc ((GBind p e) :: rest) =
  let _ = walkExpr w scope loc e
  walkGuards w (mintFrame w (patSites BMatchArm p) :: scope) loc rest

walkStmts : W -> List (List Binder) -> Loc -> List DoStmt -> Unit
walkStmts _ _ _ [] = ()
walkStmts w scope loc ((DoExpr e) :: rest) =
  let _ = walkExpr w scope loc e
  walkStmts w scope loc rest
walkStmts w scope loc ((DoBind p e) :: rest) =
  let _ = walkExpr w scope loc e
  walkStmts w (mintFrame w (patSites BDoBind p) :: scope) loc rest
walkStmts w scope loc ((DoLet _ isRec p e _) :: rest) =
  let frame = mintFrame w (patSites BLet p)
  let _ = walkExpr w (if isRec then frame :: scope else scope) loc e
  walkStmts w (frame :: scope) loc rest
walkStmts w scope loc ((DoAssign x e) :: rest) =
  let _ = noteUse w scope loc x
  let _ = walkExpr w scope loc e
  walkStmts w scope loc rest
walkStmts w scope loc ((DoFieldAssign x _ e) :: rest) =
  let _ = noteUse w scope loc x
  let _ = walkExpr w scope loc e
  walkStmts w scope loc rest
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" true) (mem "DoStmt" true) (mem "Expr" true) (mem "ExternDecl" true) (mem "FunClause" true) (mem "Guard" true) (mem "GuardArm" true) (mem "IfaceMethod" true) (mem "LetBind" true) (mem "Loc" true) (mem "Pat" true) (mem "PropParam" true) (mem "RecPatField" true) (mem "UseMember" true) (mem "UsePath" true) (mem "noDeclLoc" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "BodyOwner" true) (mem "DeclBody" true) (mem "childExprs" false) (mem "declBodies" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "setInPlace" false) (mem "get" false) (mem "findWithDefault" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "startsWith" false))))
(DData Public "BinderKind" () ((variant "BParam" (ConPos)) (variant "BLet" (ConPos)) (variant "BLambda" (ConPos)) (variant "BMatchArm" (ConPos)) (variant "BDoBind" (ConPos)) (variant "BWhere" (ConPos)) (variant "BLetGroup" (ConPos)) (variant "BImport" (ConPos)) (variant "BTopLevel" (ConPos))) ())
(DImpl true "Eq" ((TyCon "BinderKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "BParam") (PCon "BParam")) () (EVar "True")) (arm (PTuple (PCon "BLet") (PCon "BLet")) () (EVar "True")) (arm (PTuple (PCon "BLambda") (PCon "BLambda")) () (EVar "True")) (arm (PTuple (PCon "BMatchArm") (PCon "BMatchArm")) () (EVar "True")) (arm (PTuple (PCon "BDoBind") (PCon "BDoBind")) () (EVar "True")) (arm (PTuple (PCon "BWhere") (PCon "BWhere")) () (EVar "True")) (arm (PTuple (PCon "BLetGroup") (PCon "BLetGroup")) () (EVar "True")) (arm (PTuple (PCon "BImport") (PCon "BImport")) () (EVar "True")) (arm (PTuple (PCon "BTopLevel") (PCon "BTopLevel")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "BinderKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "BParam") () (ELit (LString "BParam"))) (arm (PCon "BLet") () (ELit (LString "BLet"))) (arm (PCon "BLambda") () (ELit (LString "BLambda"))) (arm (PCon "BMatchArm") () (ELit (LString "BMatchArm"))) (arm (PCon "BDoBind") () (ELit (LString "BDoBind"))) (arm (PCon "BWhere") () (ELit (LString "BWhere"))) (arm (PCon "BLetGroup") () (ELit (LString "BLetGroup"))) (arm (PCon "BImport") () (ELit (LString "BImport"))) (arm (PCon "BTopLevel") () (ELit (LString "BTopLevel")))))))
(DData Public "Binder" () ((variant "Binder" (ConNamed (field "binderName" (TyCon "String")) (field "binderKind" (TyCon "BinderKind")) (field "binderSpan" (TyCon "Loc")) (field "binderId" (TyCon "Int")) (field "binderFrom" (TyApp (TyCon "List") (TyCon "String"))) (field "binderOrigin" (TyCon "String"))))) ())
(DData Public "Use" () ((variant "Use" (ConNamed (field "useName" (TyCon "String")) (field "useSite" (TyCon "Loc")) (field "useBinder" (TyApp (TyCon "Option") (TyCon "Binder")))))) ())
(DData Abstract "FileScopes" () ((variant "FileScopes" (ConNamed (field "fsBinders" (TyApp (TyCon "List") (TyCon "Binder"))) (field "fsUses" (TyApp (TyCon "List") (TyCon "Use"))) (field "fsWild" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))) (field "fsSites" (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Binder"))) (field "fsCounts" (TyApp (TyApp (TyCon "HashMap") (TyCon "Int")) (TyCon "Int")))))) ())
(DData Private "W" () ((variant "W" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Binder"))) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Use"))) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Binder")))) (TyApp (TyCon "Ref") (TyCon "Int"))))) ())
(DData Private "Site" () ((variant "Site" (ConPos (TyCon "String") (TyCon "Loc") (TyCon "BinderKind") (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))) ())
(DTypeSig false "siteKey" (TyFun (TyCon "Loc") (TyCon "String")))
(DFunDef false "siteKey" ((PCon "Loc" PWild (PVar "l") (PVar "c") PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "l"))) (ELit (LString ":"))) (EApp (EVar "display") (EVar "c"))) (ELit (LString ""))))
(DTypeSig true "binderOf" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Loc") (TyApp (TyCon "Option") (TyCon "Binder")))))
(DFunDef false "binderOf" ((PVar "fs") (PVar "loc")) (EApp (EApp (EVar "get") (EApp (EVar "siteKey") (EVar "loc"))) (EFieldAccess (EVar "fs") "fsSites")))
(DTypeSig true "allBinders" (TyFun (TyCon "FileScopes") (TyApp (TyCon "List") (TyCon "Binder"))))
(DFunDef false "allBinders" ((PVar "fs")) (EFieldAccess (EVar "fs") "fsBinders"))
(DTypeSig true "allUses" (TyFun (TyCon "FileScopes") (TyApp (TyCon "List") (TyCon "Use"))))
(DFunDef false "allUses" ((PVar "fs")) (EFieldAccess (EVar "fs") "fsUses"))
(DTypeSig true "wildImports" (TyFun (TyCon "FileScopes") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "wildImports" ((PVar "fs")) (EFieldAccess (EVar "fs") "fsWild"))
(DTypeSig true "usesNamedIn" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Use")))))))
(DFunDef false "usesNamedIn" ((PVar "fs") (PVar "fromLine") (PVar "toLine") (PVar "name")) (EApp (EApp (EVar "filter") (ELam ((PVar "u")) (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "u") "useName") (EVar "name")) (EApp (EApp (EApp (EVar "lineWithin") (EVar "fromLine")) (EVar "toLine")) (EFieldAccess (EVar "u") "useSite"))))) (EFieldAccess (EVar "fs") "fsUses")))
(DTypeSig true "bindersNamedIn" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Binder")))))))
(DFunDef false "bindersNamedIn" ((PVar "fs") (PVar "fromLine") (PVar "toLine") (PVar "name")) (EApp (EApp (EVar "filter") (ELam ((PVar "b")) (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "b") "binderName") (EVar "name")) (EApp (EApp (EApp (EVar "lineWithin") (EVar "fromLine")) (EVar "toLine")) (EFieldAccess (EVar "b") "binderSpan"))))) (EFieldAccess (EVar "fs") "fsBinders")))
(DTypeSig true "bindersNamed" (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Binder")))))
(DFunDef false "bindersNamed" ((PVar "fs") (PVar "name")) (EApp (EApp (EVar "filter") (ELam ((PVar "b")) (EBinOp "==" (EFieldAccess (EVar "b") "binderName") (EVar "name")))) (EFieldAccess (EVar "fs") "fsBinders")))
(DTypeSig false "lineWithin" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Loc") (TyCon "Bool")))))
(DFunDef false "lineWithin" ((PVar "lo") (PVar "hi") (PCon "Loc" PWild (PVar "l") PWild PWild PWild)) (EBinOp "&&" (EBinOp "<=" (EVar "lo") (EVar "l")) (EBinOp "<=" (EVar "l") (EVar "hi"))))
(DTypeSig false "localKind" (TyFun (TyCon "BinderKind") (TyCon "Bool")))
(DFunDef false "localKind" ((PCon "BImport")) (EVar "False"))
(DFunDef false "localKind" ((PCon "BTopLevel")) (EVar "False"))
(DFunDef false "localKind" ((PCon "BLetGroup")) (EVar "False"))
(DFunDef false "localKind" ((PCon "BParam")) (EVar "True"))
(DFunDef false "localKind" ((PCon "BLet")) (EVar "True"))
(DFunDef false "localKind" ((PCon "BLambda")) (EVar "True"))
(DFunDef false "localKind" ((PCon "BMatchArm")) (EVar "True"))
(DFunDef false "localKind" ((PCon "BDoBind")) (EVar "True"))
(DFunDef false "localKind" ((PCon "BWhere")) (EVar "True"))
(DTypeSig false "useCount" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Binder") (TyCon "Int"))))
(DFunDef false "useCount" ((PVar "fs") (PVar "b")) (EApp (EApp (EApp (EVar "findWithDefault") (ELit (LInt 0))) (EFieldAccess (EVar "b") "binderId")) (EFieldAccess (EVar "fs") "fsCounts")))
(DTypeSig true "unusedBinders" (TyFun (TyCon "FileScopes") (TyApp (TyCon "List") (TyCon "Binder"))))
(DFunDef false "unusedBinders" ((PVar "fs")) (EApp (EApp (EVar "filter") (ELam ((PVar "b")) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "localKind") (EFieldAccess (EVar "b") "binderKind")) (EApp (EVar "not") (EApp (EVar "isDiscard") (EFieldAccess (EVar "b") "binderName")))) (EBinOp "==" (EApp (EApp (EVar "useCount") (EVar "fs")) (EVar "b")) (ELit (LInt 0)))))) (EFieldAccess (EVar "fs") "fsBinders")))
(DTypeSig false "isDiscard" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isDiscard" ((PVar "name")) (EApp (EApp (EVar "startsWith") (ELit (LString "_"))) (EVar "name")))
(DTypeSig true "importUses" (TyFun (TyCon "FileScopes") (TyApp (TyCon "List") (TyTuple (TyCon "Binder") (TyCon "Int")))))
(DFunDef false "importUses" ((PVar "fs")) (EApp (EApp (EVar "map") (ELam ((PVar "b")) (ETuple (EVar "b") (EApp (EApp (EVar "useCount") (EVar "fs")) (EVar "b"))))) (EApp (EApp (EVar "filter") (ELam ((PVar "b")) (EBinOp "==" (EFieldAccess (EVar "b") "binderKind") (EVar "BImport")))) (EFieldAccess (EVar "fs") "fsBinders"))))
(DTypeSig true "buildScopes" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "FileScopes")))
(DFunDef false "buildScopes" ((PVar "prog")) (EBlock (DoLet false false (PVar "w") (EApp (EApp (EApp (EApp (EVar "W") (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (ELit (LInt 0))))) (DoLet false false (PVar "imports") (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EApp (EVar "flatMap") (EVar "importSites")) (EVar "prog")))) (DoLet false false (PVar "tops") (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EApp (EVar "flatMap") (EVar "topSites")) (EVar "prog")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "walkDecls") (EVar "w")) (EListLit (EVar "tops") (EVar "imports"))) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "finish") (EVar "w")) (EApp (EApp (EVar "flatMap") (EVar "wildPaths")) (EVar "prog"))))))
(DTypeSig false "finish" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "FileScopes"))))
(DFunDef false "finish" ((PCon "W" (PVar "bs") (PVar "us") (PVar "alts") PWild) (PVar "wild")) (EBlock (DoLet false false (PVar "binders") (EApp (EVar "reverseL") (EUnOp "!" (EVar "bs")))) (DoLet false false (PVar "uses") (EApp (EVar "reverseL") (EUnOp "!" (EVar "us")))) (DoLet false false (PVar "sites") (EApp (EVar "new") (ELit LUnit))) (DoLet false false (PVar "counts") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "setUseSites") (EVar "sites")) (EVar "uses"))) (DoLet false false PWild (EApp (EApp (EVar "setBinderSites") (EVar "sites")) (EVar "binders"))) (DoLet false false PWild (EApp (EApp (EVar "setAltSites") (EVar "sites")) (EApp (EVar "reverseL") (EUnOp "!" (EVar "alts"))))) (DoLet false false PWild (EApp (EApp (EVar "countUses") (EVar "counts")) (EVar "uses"))) (DoExpr (ERecordCreate "FileScopes" ((fa "fsBinders" (EVar "binders")) (fa "fsUses" (EVar "uses")) (fa "fsWild" (EVar "wild")) (fa "fsSites" (EVar "sites")) (fa "fsCounts" (EVar "counts")))))))
(DTypeSig false "setUseSites" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Binder")) (TyFun (TyApp (TyCon "List") (TyCon "Use")) (TyCon "Unit"))))
(DFunDef false "setUseSites" (PWild (PList)) (ELit LUnit))
(DFunDef false "setUseSites" ((PVar "m") (PCons (PRec "Use" ((rf "useSite" (PVar "loc")) (rf "useBinder" (PCon "Some" (PVar "b")))) true) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EApp (EVar "siteKey") (EVar "loc"))) (EVar "b")) (EVar "m"))) (DoExpr (EApp (EApp (EVar "setUseSites") (EVar "m")) (EVar "rest")))))
(DFunDef false "setUseSites" ((PVar "m") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "setUseSites") (EVar "m")) (EVar "rest")))
(DTypeSig false "setBinderSites" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Binder")) (TyFun (TyApp (TyCon "List") (TyCon "Binder")) (TyCon "Unit"))))
(DFunDef false "setBinderSites" (PWild (PList)) (ELit LUnit))
(DFunDef false "setBinderSites" ((PVar "m") (PCons (PVar "b") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EApp (EVar "siteKey") (EFieldAccess (EVar "b") "binderSpan"))) (EVar "b")) (EVar "m"))) (DoExpr (EApp (EApp (EVar "setBinderSites") (EVar "m")) (EVar "rest")))))
(DTypeSig false "setAltSites" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Binder")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Binder"))) (TyCon "Unit"))))
(DFunDef false "setAltSites" (PWild (PList)) (ELit LUnit))
(DFunDef false "setAltSites" ((PVar "m") (PCons (PTuple (PVar "loc") (PVar "b")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EApp (EVar "siteKey") (EVar "loc"))) (EVar "b")) (EVar "m"))) (DoExpr (EApp (EApp (EVar "setAltSites") (EVar "m")) (EVar "rest")))))
(DTypeSig false "countUses" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "Int")) (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Use")) (TyCon "Unit"))))
(DFunDef false "countUses" (PWild (PList)) (ELit LUnit))
(DFunDef false "countUses" ((PVar "m") (PCons (PRec "Use" ((rf "useBinder" (PCon "Some" (PVar "b")))) true) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EFieldAccess (EVar "b") "binderId")) (EBinOp "+" (EApp (EApp (EApp (EVar "findWithDefault") (ELit (LInt 0))) (EFieldAccess (EVar "b") "binderId")) (EVar "m")) (ELit (LInt 1)))) (EVar "m"))) (DoExpr (EApp (EApp (EVar "countUses") (EVar "m")) (EVar "rest")))))
(DFunDef false "countUses" ((PVar "m") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "countUses") (EVar "m")) (EVar "rest")))
(DTypeSig false "importSites" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Site"))))
(DFunDef false "importSites" ((PCon "DUse" PWild (PCon "UseGroup" (PVar "path") (PVar "members")) PWild)) (EApp (EApp (EVar "map") (EApp (EVar "importSite") (EVar "path"))) (EVar "members")))
(DFunDef false "importSites" (PWild) (EListLit))
(DTypeSig false "importSite" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "UseMember") (TyCon "Site"))))
(DFunDef false "importSite" ((PVar "path") (PCon "UseMember" (PVar "n") PWild (PVar "loc") (PVar "alias"))) (EApp (EApp (EApp (EApp (EApp (EVar "Site") (EApp (EApp (EVar "fromOption") (EVar "n")) (EVar "alias"))) (EVar "loc")) (EVar "BImport")) (EVar "path")) (EVar "n")))
(DTypeSig false "fromOption" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyVar "a"))))
(DFunDef false "fromOption" ((PVar "d") (PCon "None")) (EVar "d"))
(DFunDef false "fromOption" (PWild (PCon "Some" (PVar "x"))) (EVar "x"))
(DTypeSig false "wildPaths" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "wildPaths" ((PCon "DUse" PWild (PCon "UseWild" (PVar "path")) PWild)) (EListLit (EVar "path")))
(DFunDef false "wildPaths" (PWild) (EListLit))
(DTypeSig false "topSites" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Site"))))
(DFunDef false "topSites" ((PCon "DFunDef" PWild (PVar "n") PWild PWild (PVar "site") PWild)) (EListLit (EApp (EApp (EApp (EVar "plainSite") (EVar "n")) (EVar "site")) (EVar "BTopLevel"))))
(DFunDef false "topSites" ((PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n")) (rf "edLoc" (PVar "l"))) true))) (EListLit (EApp (EApp (EApp (EVar "plainSite") (EVar "n")) (EVar "l")) (EVar "BTopLevel"))))
(DFunDef false "topSites" ((PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EVar "map") (EApp (EVar "letBindSite") (EVar "BLetGroup"))) (EVar "binds")))
(DFunDef false "topSites" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (EVar "ifaceMethodSite")) (EVar "methods")))
(DFunDef false "topSites" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "topSites") (EVar "d")))
(DFunDef false "topSites" (PWild) (EListLit))
(DTypeSig false "ifaceMethodSite" (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "Site"))))
(DFunDef false "ifaceMethodSite" ((PCon "IfaceMethod" (PVar "n") PWild PWild (PVar "loc"))) (EListLit (EApp (EApp (EApp (EVar "plainSite") (EVar "n")) (EApp (EApp (EVar "fromOption") (EVar "noDeclLoc")) (EVar "loc"))) (EVar "BTopLevel"))))
(DTypeSig false "plainSite" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "BinderKind") (TyCon "Site")))))
(DFunDef false "plainSite" ((PVar "n") (PVar "loc") (PVar "k")) (EApp (EApp (EApp (EApp (EApp (EVar "Site") (EVar "n")) (EVar "loc")) (EVar "k")) (EListLit)) (ELit (LString ""))))
(DTypeSig false "letBindSite" (TyFun (TyCon "BinderKind") (TyFun (TyCon "LetBind") (TyCon "Site"))))
(DFunDef false "letBindSite" ((PVar "k") (PCon "LetBind" (PVar "n") PWild (PVar "loc") PWild)) (EApp (EApp (EApp (EVar "plainSite") (EVar "n")) (EVar "loc")) (EVar "k")))
(DTypeSig false "patSites" (TyFun (TyCon "BinderKind") (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "Site")))))
(DFunDef false "patSites" ((PVar "k") (PCon "PVar" (PVar "x") (PVar "l") PWild)) (EListLit (EApp (EApp (EApp (EVar "plainSite") (EVar "x")) (EVar "l")) (EVar "k"))))
(DFunDef false "patSites" (PWild (PCon "PWild")) (EListLit))
(DFunDef false "patSites" (PWild (PCon "PLit" PWild)) (EListLit))
(DFunDef false "patSites" ((PVar "k") (PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "patSites") (EVar "k"))) (EVar "ps")))
(DFunDef false "patSites" ((PVar "k") (PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "patSites") (EVar "k")) (EVar "a")) (EApp (EApp (EVar "patSites") (EVar "k")) (EVar "b"))))
(DFunDef false "patSites" ((PVar "k") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "patSites") (EVar "k"))) (EVar "ps")))
(DFunDef false "patSites" ((PVar "k") (PCon "PList" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "patSites") (EVar "k"))) (EVar "ps")))
(DFunDef false "patSites" ((PVar "k") (PCon "PAs" (PVar "x") (PVar "l") PWild (PVar "p"))) (EBinOp "::" (EApp (EApp (EApp (EVar "plainSite") (EVar "x")) (EVar "l")) (EVar "k")) (EApp (EApp (EVar "patSites") (EVar "k")) (EVar "p"))))
(DFunDef false "patSites" ((PVar "k") (PCon "POr" (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "patSites") (EVar "k"))) (EVar "ps")))
(DFunDef false "patSites" (PWild (PCon "PRng" PWild PWild PWild)) (EListLit))
(DFunDef false "patSites" ((PVar "k") (PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EVar "flatMap") (EApp (EVar "recFieldSites") (EVar "k"))) (EVar "fields")))
(DTypeSig false "recFieldSites" (TyFun (TyCon "BinderKind") (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "Site")))))
(DFunDef false "recFieldSites" ((PVar "k") (PCon "RecPatField" (PVar "name") (PVar "l") PWild (PCon "None"))) (EListLit (EApp (EApp (EApp (EVar "plainSite") (EVar "name")) (EVar "l")) (EVar "k"))))
(DFunDef false "recFieldSites" ((PVar "k") (PCon "RecPatField" PWild PWild PWild (PCon "Some" (PVar "p")))) (EApp (EApp (EVar "patSites") (EVar "k")) (EVar "p")))
(DTypeSig false "ownerSites" (TyFun (TyCon "BodyOwner") (TyApp (TyCon "List") (TyCon "Site"))))
(DFunDef false "ownerSites" ((PCon "OwnerClause" PWild (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "patSites") (EVar "BParam"))) (EVar "ps")))
(DFunDef false "ownerSites" ((PCon "OwnerImplMethod" PWild PWild (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "patSites") (EVar "BParam"))) (EVar "ps")))
(DFunDef false "ownerSites" ((PCon "OwnerIfaceDefault" PWild PWild (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "patSites") (EVar "BParam"))) (EVar "ps")))
(DFunDef false "ownerSites" ((PCon "OwnerTest" PWild)) (EListLit))
(DFunDef false "ownerSites" ((PCon "OwnerProp" PWild (PVar "params"))) (EApp (EApp (EVar "map") (EVar "propParamSite")) (EVar "params")))
(DFunDef false "ownerSites" ((PCon "OwnerLetGroup" PWild (PVar "ps"))) (EApp (EApp (EVar "flatMap") (EApp (EVar "patSites") (EVar "BParam"))) (EVar "ps")))
(DTypeSig false "propParamSite" (TyFun (TyCon "PropParam") (TyCon "Site")))
(DFunDef false "propParamSite" ((PCon "PropParam" (PVar "n") (PVar "l") PWild)) (EApp (EApp (EApp (EVar "plainSite") (EVar "n")) (EVar "l")) (EVar "BParam")))
(DTypeSig false "mintFrame" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyCon "Site")) (TyApp (TyCon "List") (TyCon "Binder")))))
(DFunDef false "mintFrame" ((PVar "w") (PVar "sites")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "mintFrameGo") (EVar "w")) (EListLit)) (EVar "sites"))))
(DTypeSig false "mintFrameGo" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyCon "Binder")) (TyFun (TyApp (TyCon "List") (TyCon "Site")) (TyApp (TyCon "List") (TyCon "Binder"))))))
(DFunDef false "mintFrameGo" (PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "mintFrameGo" ((PVar "w") (PVar "acc") (PCons (PCon "Site" (PVar "n") (PVar "l") (PVar "k") (PVar "from") (PVar "origin")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "findBinder") (EVar "n")) (EVar "acc")) (arm (PCon "Some" (PVar "b")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "pushAlt") (EVar "w")) (EVar "l")) (EVar "b"))) (DoExpr (EApp (EApp (EApp (EVar "mintFrameGo") (EVar "w")) (EVar "acc")) (EVar "rest"))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "mintFrameGo") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mintOne") (EVar "w")) (EVar "n")) (EVar "l")) (EVar "k")) (EVar "from")) (EVar "origin")) (EVar "acc"))) (EVar "rest")))))
(DTypeSig false "pushAlt" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyCon "Binder") (TyCon "Unit")))))
(DFunDef false "pushAlt" ((PCon "W" PWild PWild (PVar "alts") PWild) (PVar "l") (PVar "b")) (EApp (EApp (EVar "setRef") (EVar "alts")) (EBinOp "::" (ETuple (EVar "l") (EVar "b")) (EUnOp "!" (EVar "alts")))))
(DTypeSig false "mintOne" (TyFun (TyCon "W") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "BinderKind") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Binder"))))))))
(DFunDef false "mintOne" ((PCon "W" (PVar "bs") PWild PWild (PVar "counter")) (PVar "n") (PVar "l") (PVar "k") (PVar "from") (PVar "origin")) (EBlock (DoLet false false (PVar "id") (EUnOp "!" (EVar "counter"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "counter")) (EBinOp "+" (EVar "id") (ELit (LInt 1))))) (DoLet false false (PVar "b") (ERecordCreate "Binder" ((fa "binderName" (EVar "n")) (fa "binderKind" (EVar "k")) (fa "binderSpan" (EVar "l")) (fa "binderId" (EVar "id")) (fa "binderFrom" (EVar "from")) (fa "binderOrigin" (EVar "origin"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "bs")) (EBinOp "::" (EVar "b") (EUnOp "!" (EVar "bs"))))) (DoExpr (EVar "b"))))
(DTypeSig false "findBinder" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Binder")) (TyApp (TyCon "Option") (TyCon "Binder")))))
(DFunDef false "findBinder" (PWild (PList)) (EVar "None"))
(DFunDef false "findBinder" ((PVar "n") (PCons (PVar "b") (PVar "rest"))) (EIf (EBinOp "==" (EFieldAccess (EVar "b") "binderName") (EVar "n")) (EApp (EVar "Some") (EVar "b")) (EApp (EApp (EVar "findBinder") (EVar "n")) (EVar "rest"))))
(DTypeSig false "lookupFrames" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyApp (TyCon "Option") (TyCon "Binder")))))
(DFunDef false "lookupFrames" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupFrames" ((PVar "n") (PCons (PVar "frame") (PVar "rest"))) (EMatch (EApp (EApp (EVar "findBinder") (EVar "n")) (EVar "frame")) (arm (PCon "Some" (PVar "b")) () (EApp (EVar "Some") (EVar "b"))) (arm (PCon "None") () (EApp (EApp (EVar "lookupFrames") (EVar "n")) (EVar "rest")))))
(DTypeSig false "noteUse" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyFun (TyCon "Loc") (TyFun (TyCon "String") (TyCon "Unit"))))))
(DFunDef false "noteUse" ((PCon "W" PWild (PVar "us") PWild PWild) (PVar "scope") (PVar "loc") (PVar "n")) (EApp (EApp (EVar "setRef") (EVar "us")) (EBinOp "::" (ERecordCreate "Use" ((fa "useName" (EVar "n")) (fa "useSite" (EVar "loc")) (fa "useBinder" (EApp (EApp (EVar "lookupFrames") (EVar "n")) (EVar "scope"))))) (EUnOp "!" (EVar "us")))))
(DTypeSig false "walkDecls" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "walkDecls" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkDecls" ((PVar "w") (PVar "scope") (PCons (PVar "d") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkBodies") (EVar "w")) (EVar "scope")) (EApp (EVar "declBodies") (EVar "d")))) (DoExpr (EApp (EApp (EApp (EVar "walkDecls") (EVar "w")) (EVar "scope")) (EVar "rest")))))
(DTypeSig false "walkBodies" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyFun (TyApp (TyCon "List") (TyCon "DeclBody")) (TyCon "Unit")))))
(DFunDef false "walkBodies" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkBodies" ((PVar "w") (PVar "scope") (PCons (PCon "DeclBody" (PVar "owner") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EVar "ownerSites") (EVar "owner")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "noDeclLoc")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EVar "walkBodies") (EVar "w")) (EVar "scope")) (EVar "rest")))))
(DTypeSig false "walkExpr" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyFun (TyCon "Loc") (TyFun (TyCon "Expr") (TyCon "Unit"))))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") PWild (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "l")) (EVar "e")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") PWild (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "l")) (EVar "e")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "loc") (PCon "EVar" (PVar "n"))) (EApp (EApp (EApp (EApp (EVar "noteUse") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "n")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "loc") (PCon "ELam" (PVar "ps") (PVar "body"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EApp (EVar "flatMap") (EApp (EVar "patSites") (EVar "BLambda"))) (EVar "ps")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "loc")) (EVar "body")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "loc") (PCon "ELet" PWild (PVar "isRec") (PVar "p") (PVar "rhs") (PVar "body"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EApp (EVar "patSites") (EVar "BLet")) (EVar "p")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EIf (EVar "isRec") (EBinOp "::" (EVar "frame") (EVar "scope")) (EVar "scope"))) (EVar "loc")) (EVar "rhs"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "loc")) (EVar "body")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "loc") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EApp (EVar "map") (EApp (EVar "letBindSite") (EVar "BWhere"))) (EVar "binds")))) (DoLet false false (PVar "scope1") (EBinOp "::" (EVar "frame") (EVar "scope"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkClauses") (EVar "w")) (EVar "scope1")) (EVar "loc")) (EApp (EApp (EVar "flatMap") (EVar "letBindClauses")) (EVar "binds")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope1")) (EVar "loc")) (EVar "body")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "loc") (PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "scrut"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "arms")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "loc") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "stmts")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "loc") (PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "stmts")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "loc") (PCon "EGuards" (PVar "arms"))) (EApp (EApp (EApp (EApp (EVar "walkGuardArms") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "arms")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "loc") (PVar "e")) (EApp (EApp (EApp (EApp (EVar "walkEach") (EVar "w")) (EVar "scope")) (EVar "loc")) (EApp (EVar "childExprs") (EVar "e"))))
(DTypeSig false "letBindClauses" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "FunClause"))))
(DFunDef false "letBindClauses" ((PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EVar "clauses"))
(DTypeSig false "walkEach" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Unit"))))))
(DFunDef false "walkEach" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkEach" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PVar "e") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkEach") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "rest")))))
(DTypeSig false "walkClauses" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyCon "Unit"))))))
(DFunDef false "walkClauses" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkClauses" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PCon "FunClause" (PVar "ps") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EApp (EVar "flatMap") (EApp (EVar "patSites") (EVar "BParam"))) (EVar "ps")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "loc")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkClauses") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "rest")))))
(DTypeSig false "walkArms" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Unit"))))))
(DFunDef false "walkArms" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkArms" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "scope1") (EBinOp "::" (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EApp (EVar "patSites") (EVar "BMatchArm")) (EVar "p"))) (EVar "scope"))) (DoLet false false (PVar "scope2") (EApp (EApp (EApp (EApp (EVar "walkGuards") (EVar "w")) (EVar "scope1")) (EVar "loc")) (EVar "gs"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope2")) (EVar "loc")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "rest")))))
(DTypeSig false "walkGuardArms" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyCon "Unit"))))))
(DFunDef false "walkGuardArms" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkGuardArms" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PCon "GuardArm" (PVar "gs") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "scope2") (EApp (EApp (EApp (EApp (EVar "walkGuards") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "gs"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope2")) (EVar "loc")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkGuardArms") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "rest")))))
(DTypeSig false "walkGuards" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))))))))
(DFunDef false "walkGuards" (PWild (PVar "scope") PWild (PList)) (EVar "scope"))
(DFunDef false "walkGuards" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkGuards") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "rest")))))
(DFunDef false "walkGuards" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkGuards") (EVar "w")) (EBinOp "::" (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EApp (EVar "patSites") (EVar "BMatchArm")) (EVar "p"))) (EVar "scope"))) (EVar "loc")) (EVar "rest")))))
(DTypeSig false "walkStmts" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "Unit"))))))
(DFunDef false "walkStmts" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkStmts" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "rest")))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EBinOp "::" (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EApp (EVar "patSites") (EVar "BDoBind")) (EVar "p"))) (EVar "scope"))) (EVar "loc")) (EVar "rest")))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PCon "DoLet" PWild (PVar "isRec") (PVar "p") (PVar "e") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EApp (EVar "patSites") (EVar "BLet")) (EVar "p")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EIf (EVar "isRec") (EBinOp "::" (EVar "frame") (EVar "scope")) (EVar "scope"))) (EVar "loc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "loc")) (EVar "rest")))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "noteUse") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "x"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "rest")))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PCon "DoFieldAssign" (PVar "x") PWild (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "noteUse") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "x"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "rest")))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" true) (mem "DoStmt" true) (mem "Expr" true) (mem "ExternDecl" true) (mem "FunClause" true) (mem "Guard" true) (mem "GuardArm" true) (mem "IfaceMethod" true) (mem "LetBind" true) (mem "Loc" true) (mem "Pat" true) (mem "PropParam" true) (mem "RecPatField" true) (mem "UseMember" true) (mem "UsePath" true) (mem "noDeclLoc" false))))
(DUse false (UseGroup ("frontend" "ast_walk") ((mem "BodyOwner" true) (mem "DeclBody" true) (mem "childExprs" false) (mem "declBodies" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "setInPlace" false) (mem "get" false) (mem "findWithDefault" false))))
(DUse false (UseGroup ("support" "util") ((mem "reverseL" false) (mem "startsWith" false))))
(DData Public "BinderKind" () ((variant "BParam" (ConPos)) (variant "BLet" (ConPos)) (variant "BLambda" (ConPos)) (variant "BMatchArm" (ConPos)) (variant "BDoBind" (ConPos)) (variant "BWhere" (ConPos)) (variant "BLetGroup" (ConPos)) (variant "BImport" (ConPos)) (variant "BTopLevel" (ConPos))) ())
(DImpl true "Eq" ((TyCon "BinderKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "BParam") (PCon "BParam")) () (EVar "True")) (arm (PTuple (PCon "BLet") (PCon "BLet")) () (EVar "True")) (arm (PTuple (PCon "BLambda") (PCon "BLambda")) () (EVar "True")) (arm (PTuple (PCon "BMatchArm") (PCon "BMatchArm")) () (EVar "True")) (arm (PTuple (PCon "BDoBind") (PCon "BDoBind")) () (EVar "True")) (arm (PTuple (PCon "BWhere") (PCon "BWhere")) () (EVar "True")) (arm (PTuple (PCon "BLetGroup") (PCon "BLetGroup")) () (EVar "True")) (arm (PTuple (PCon "BImport") (PCon "BImport")) () (EVar "True")) (arm (PTuple (PCon "BTopLevel") (PCon "BTopLevel")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "BinderKind")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "BParam") () (ELit (LString "BParam"))) (arm (PCon "BLet") () (ELit (LString "BLet"))) (arm (PCon "BLambda") () (ELit (LString "BLambda"))) (arm (PCon "BMatchArm") () (ELit (LString "BMatchArm"))) (arm (PCon "BDoBind") () (ELit (LString "BDoBind"))) (arm (PCon "BWhere") () (ELit (LString "BWhere"))) (arm (PCon "BLetGroup") () (ELit (LString "BLetGroup"))) (arm (PCon "BImport") () (ELit (LString "BImport"))) (arm (PCon "BTopLevel") () (ELit (LString "BTopLevel")))))))
(DData Public "Binder" () ((variant "Binder" (ConNamed (field "binderName" (TyCon "String")) (field "binderKind" (TyCon "BinderKind")) (field "binderSpan" (TyCon "Loc")) (field "binderId" (TyCon "Int")) (field "binderFrom" (TyApp (TyCon "List") (TyCon "String"))) (field "binderOrigin" (TyCon "String"))))) ())
(DData Public "Use" () ((variant "Use" (ConNamed (field "useName" (TyCon "String")) (field "useSite" (TyCon "Loc")) (field "useBinder" (TyApp (TyCon "Option") (TyCon "Binder")))))) ())
(DData Abstract "FileScopes" () ((variant "FileScopes" (ConNamed (field "fsBinders" (TyApp (TyCon "List") (TyCon "Binder"))) (field "fsUses" (TyApp (TyCon "List") (TyCon "Use"))) (field "fsWild" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))) (field "fsSites" (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Binder"))) (field "fsCounts" (TyApp (TyApp (TyCon "HashMap") (TyCon "Int")) (TyCon "Int")))))) ())
(DData Private "W" () ((variant "W" (ConPos (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Binder"))) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "Use"))) (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Binder")))) (TyApp (TyCon "Ref") (TyCon "Int"))))) ())
(DData Private "Site" () ((variant "Site" (ConPos (TyCon "String") (TyCon "Loc") (TyCon "BinderKind") (TyApp (TyCon "List") (TyCon "String")) (TyCon "String")))) ())
(DTypeSig false "siteKey" (TyFun (TyCon "Loc") (TyCon "String")))
(DFunDef false "siteKey" ((PCon "Loc" PWild (PVar "l") (PVar "c") PWild PWild)) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "l"))) (ELit (LString ":"))) (EApp (EMethodRef "display") (EVar "c"))) (ELit (LString ""))))
(DTypeSig true "binderOf" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Loc") (TyApp (TyCon "Option") (TyCon "Binder")))))
(DFunDef false "binderOf" ((PVar "fs") (PVar "loc")) (EApp (EApp (EVar "get") (EApp (EVar "siteKey") (EVar "loc"))) (EFieldAccess (EVar "fs") "fsSites")))
(DTypeSig true "allBinders" (TyFun (TyCon "FileScopes") (TyApp (TyCon "List") (TyCon "Binder"))))
(DFunDef false "allBinders" ((PVar "fs")) (EFieldAccess (EVar "fs") "fsBinders"))
(DTypeSig true "allUses" (TyFun (TyCon "FileScopes") (TyApp (TyCon "List") (TyCon "Use"))))
(DFunDef false "allUses" ((PVar "fs")) (EFieldAccess (EVar "fs") "fsUses"))
(DTypeSig true "wildImports" (TyFun (TyCon "FileScopes") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "wildImports" ((PVar "fs")) (EFieldAccess (EVar "fs") "fsWild"))
(DTypeSig true "usesNamedIn" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Use")))))))
(DFunDef false "usesNamedIn" ((PVar "fs") (PVar "fromLine") (PVar "toLine") (PVar "name")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "u")) (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "u") "useName") (EVar "name")) (EApp (EApp (EApp (EVar "lineWithin") (EVar "fromLine")) (EVar "toLine")) (EFieldAccess (EVar "u") "useSite"))))) (EFieldAccess (EVar "fs") "fsUses")))
(DTypeSig true "bindersNamedIn" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Binder")))))))
(DFunDef false "bindersNamedIn" ((PVar "fs") (PVar "fromLine") (PVar "toLine") (PVar "name")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "b")) (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "b") "binderName") (EVar "name")) (EApp (EApp (EApp (EVar "lineWithin") (EVar "fromLine")) (EVar "toLine")) (EFieldAccess (EVar "b") "binderSpan"))))) (EFieldAccess (EVar "fs") "fsBinders")))
(DTypeSig true "bindersNamed" (TyFun (TyCon "FileScopes") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "Binder")))))
(DFunDef false "bindersNamed" ((PVar "fs") (PVar "name")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "b")) (EBinOp "==" (EFieldAccess (EVar "b") "binderName") (EVar "name")))) (EFieldAccess (EVar "fs") "fsBinders")))
(DTypeSig false "lineWithin" (TyFun (TyCon "Int") (TyFun (TyCon "Int") (TyFun (TyCon "Loc") (TyCon "Bool")))))
(DFunDef false "lineWithin" ((PVar "lo") (PVar "hi") (PCon "Loc" PWild (PVar "l") PWild PWild PWild)) (EBinOp "&&" (EBinOp "<=" (EVar "lo") (EVar "l")) (EBinOp "<=" (EVar "l") (EVar "hi"))))
(DTypeSig false "localKind" (TyFun (TyCon "BinderKind") (TyCon "Bool")))
(DFunDef false "localKind" ((PCon "BImport")) (EVar "False"))
(DFunDef false "localKind" ((PCon "BTopLevel")) (EVar "False"))
(DFunDef false "localKind" ((PCon "BLetGroup")) (EVar "False"))
(DFunDef false "localKind" ((PCon "BParam")) (EVar "True"))
(DFunDef false "localKind" ((PCon "BLet")) (EVar "True"))
(DFunDef false "localKind" ((PCon "BLambda")) (EVar "True"))
(DFunDef false "localKind" ((PCon "BMatchArm")) (EVar "True"))
(DFunDef false "localKind" ((PCon "BDoBind")) (EVar "True"))
(DFunDef false "localKind" ((PCon "BWhere")) (EVar "True"))
(DTypeSig false "useCount" (TyFun (TyCon "FileScopes") (TyFun (TyCon "Binder") (TyCon "Int"))))
(DFunDef false "useCount" ((PVar "fs") (PVar "b")) (EApp (EApp (EApp (EVar "findWithDefault") (ELit (LInt 0))) (EFieldAccess (EVar "b") "binderId")) (EFieldAccess (EVar "fs") "fsCounts")))
(DTypeSig true "unusedBinders" (TyFun (TyCon "FileScopes") (TyApp (TyCon "List") (TyCon "Binder"))))
(DFunDef false "unusedBinders" ((PVar "fs")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "b")) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "localKind") (EFieldAccess (EVar "b") "binderKind")) (EApp (EVar "not") (EApp (EVar "isDiscard") (EFieldAccess (EVar "b") "binderName")))) (EBinOp "==" (EApp (EApp (EVar "useCount") (EVar "fs")) (EVar "b")) (ELit (LInt 0)))))) (EFieldAccess (EVar "fs") "fsBinders")))
(DTypeSig false "isDiscard" (TyFun (TyCon "String") (TyCon "Bool")))
(DFunDef false "isDiscard" ((PVar "name")) (EApp (EApp (EVar "startsWith") (ELit (LString "_"))) (EVar "name")))
(DTypeSig true "importUses" (TyFun (TyCon "FileScopes") (TyApp (TyCon "List") (TyTuple (TyCon "Binder") (TyCon "Int")))))
(DFunDef false "importUses" ((PVar "fs")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (ETuple (EVar "b") (EApp (EApp (EVar "useCount") (EVar "fs")) (EVar "b"))))) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "b")) (EBinOp "==" (EFieldAccess (EVar "b") "binderKind") (EVar "BImport")))) (EFieldAccess (EVar "fs") "fsBinders"))))
(DTypeSig true "buildScopes" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "FileScopes")))
(DFunDef false "buildScopes" ((PVar "prog")) (EBlock (DoLet false false (PVar "w") (EApp (EApp (EApp (EApp (EVar "W") (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (EListLit))) (EApp (EVar "Ref") (ELit (LInt 0))))) (DoLet false false (PVar "imports") (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EApp (EDictApp "flatMap") (EVar "importSites")) (EVar "prog")))) (DoLet false false (PVar "tops") (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EApp (EDictApp "flatMap") (EVar "topSites")) (EVar "prog")))) (DoLet false false PWild (EApp (EApp (EApp (EVar "walkDecls") (EVar "w")) (EListLit (EVar "tops") (EVar "imports"))) (EVar "prog"))) (DoExpr (EApp (EApp (EVar "finish") (EVar "w")) (EApp (EApp (EDictApp "flatMap") (EVar "wildPaths")) (EVar "prog"))))))
(DTypeSig false "finish" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String"))) (TyCon "FileScopes"))))
(DFunDef false "finish" ((PCon "W" (PVar "bs") (PVar "us") (PVar "alts") PWild) (PVar "wild")) (EBlock (DoLet false false (PVar "binders") (EApp (EVar "reverseL") (EUnOp "!" (EVar "bs")))) (DoLet false false (PVar "uses") (EApp (EVar "reverseL") (EUnOp "!" (EVar "us")))) (DoLet false false (PVar "sites") (EApp (EVar "new") (ELit LUnit))) (DoLet false false (PVar "counts") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "setUseSites") (EVar "sites")) (EVar "uses"))) (DoLet false false PWild (EApp (EApp (EVar "setBinderSites") (EVar "sites")) (EVar "binders"))) (DoLet false false PWild (EApp (EApp (EVar "setAltSites") (EVar "sites")) (EApp (EVar "reverseL") (EUnOp "!" (EVar "alts"))))) (DoLet false false PWild (EApp (EApp (EVar "countUses") (EVar "counts")) (EVar "uses"))) (DoExpr (ERecordCreate "FileScopes" ((fa "fsBinders" (EVar "binders")) (fa "fsUses" (EVar "uses")) (fa "fsWild" (EVar "wild")) (fa "fsSites" (EVar "sites")) (fa "fsCounts" (EVar "counts")))))))
(DTypeSig false "setUseSites" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Binder")) (TyFun (TyApp (TyCon "List") (TyCon "Use")) (TyCon "Unit"))))
(DFunDef false "setUseSites" (PWild (PList)) (ELit LUnit))
(DFunDef false "setUseSites" ((PVar "m") (PCons (PRec "Use" ((rf "useSite" (PVar "loc")) (rf "useBinder" (PCon "Some" (PVar "b")))) true) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EApp (EVar "siteKey") (EVar "loc"))) (EVar "b")) (EVar "m"))) (DoExpr (EApp (EApp (EVar "setUseSites") (EVar "m")) (EVar "rest")))))
(DFunDef false "setUseSites" ((PVar "m") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "setUseSites") (EVar "m")) (EVar "rest")))
(DTypeSig false "setBinderSites" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Binder")) (TyFun (TyApp (TyCon "List") (TyCon "Binder")) (TyCon "Unit"))))
(DFunDef false "setBinderSites" (PWild (PList)) (ELit LUnit))
(DFunDef false "setBinderSites" ((PVar "m") (PCons (PVar "b") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EApp (EVar "siteKey") (EFieldAccess (EVar "b") "binderSpan"))) (EVar "b")) (EVar "m"))) (DoExpr (EApp (EApp (EVar "setBinderSites") (EVar "m")) (EVar "rest")))))
(DTypeSig false "setAltSites" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Binder")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "Loc") (TyCon "Binder"))) (TyCon "Unit"))))
(DFunDef false "setAltSites" (PWild (PList)) (ELit LUnit))
(DFunDef false "setAltSites" ((PVar "m") (PCons (PTuple (PVar "loc") (PVar "b")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EApp (EVar "siteKey") (EVar "loc"))) (EVar "b")) (EVar "m"))) (DoExpr (EApp (EApp (EVar "setAltSites") (EVar "m")) (EVar "rest")))))
(DTypeSig false "countUses" (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "Int")) (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Use")) (TyCon "Unit"))))
(DFunDef false "countUses" (PWild (PList)) (ELit LUnit))
(DFunDef false "countUses" ((PVar "m") (PCons (PRec "Use" ((rf "useBinder" (PCon "Some" (PVar "b")))) true) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EFieldAccess (EVar "b") "binderId")) (EBinOp "+" (EApp (EApp (EApp (EVar "findWithDefault") (ELit (LInt 0))) (EFieldAccess (EVar "b") "binderId")) (EVar "m")) (ELit (LInt 1)))) (EVar "m"))) (DoExpr (EApp (EApp (EVar "countUses") (EVar "m")) (EVar "rest")))))
(DFunDef false "countUses" ((PVar "m") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "countUses") (EVar "m")) (EVar "rest")))
(DTypeSig false "importSites" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Site"))))
(DFunDef false "importSites" ((PCon "DUse" PWild (PCon "UseGroup" (PVar "path") (PVar "members")) PWild)) (EApp (EApp (EMethodRef "map") (EApp (EVar "importSite") (EVar "path"))) (EVar "members")))
(DFunDef false "importSites" (PWild) (EListLit))
(DTypeSig false "importSite" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "UseMember") (TyCon "Site"))))
(DFunDef false "importSite" ((PVar "path") (PCon "UseMember" (PVar "n") PWild (PVar "loc") (PVar "alias"))) (EApp (EApp (EApp (EApp (EApp (EVar "Site") (EApp (EApp (EVar "fromOption") (EVar "n")) (EVar "alias"))) (EVar "loc")) (EVar "BImport")) (EVar "path")) (EVar "n")))
(DTypeSig false "fromOption" (TyFun (TyVar "a") (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyVar "a"))))
(DFunDef false "fromOption" ((PVar "d") (PCon "None")) (EVar "d"))
(DFunDef false "fromOption" (PWild (PCon "Some" (PVar "x"))) (EVar "x"))
(DTypeSig false "wildPaths" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "wildPaths" ((PCon "DUse" PWild (PCon "UseWild" (PVar "path")) PWild)) (EListLit (EVar "path")))
(DFunDef false "wildPaths" (PWild) (EListLit))
(DTypeSig false "topSites" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "Site"))))
(DFunDef false "topSites" ((PCon "DFunDef" PWild (PVar "n") PWild PWild (PVar "site") PWild)) (EListLit (EApp (EApp (EApp (EVar "plainSite") (EVar "n")) (EVar "site")) (EVar "BTopLevel"))))
(DFunDef false "topSites" ((PCon "DExtern" (PRec "ExternDecl" ((rf "edName" (PVar "n")) (rf "edLoc" (PVar "l"))) true))) (EListLit (EApp (EApp (EApp (EVar "plainSite") (EVar "n")) (EVar "l")) (EVar "BTopLevel"))))
(DFunDef false "topSites" ((PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "letBindSite") (EVar "BLetGroup"))) (EVar "binds")))
(DFunDef false "topSites" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (EVar "ifaceMethodSite")) (EVar "methods")))
(DFunDef false "topSites" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "topSites") (EVar "d")))
(DFunDef false "topSites" (PWild) (EListLit))
(DTypeSig false "ifaceMethodSite" (TyFun (TyCon "IfaceMethod") (TyApp (TyCon "List") (TyCon "Site"))))
(DFunDef false "ifaceMethodSite" ((PCon "IfaceMethod" (PVar "n") PWild PWild (PVar "loc"))) (EListLit (EApp (EApp (EApp (EVar "plainSite") (EVar "n")) (EApp (EApp (EVar "fromOption") (EVar "noDeclLoc")) (EVar "loc"))) (EVar "BTopLevel"))))
(DTypeSig false "plainSite" (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "BinderKind") (TyCon "Site")))))
(DFunDef false "plainSite" ((PVar "n") (PVar "loc") (PVar "k")) (EApp (EApp (EApp (EApp (EApp (EVar "Site") (EVar "n")) (EVar "loc")) (EVar "k")) (EListLit)) (ELit (LString ""))))
(DTypeSig false "letBindSite" (TyFun (TyCon "BinderKind") (TyFun (TyCon "LetBind") (TyCon "Site"))))
(DFunDef false "letBindSite" ((PVar "k") (PCon "LetBind" (PVar "n") PWild (PVar "loc") PWild)) (EApp (EApp (EApp (EVar "plainSite") (EVar "n")) (EVar "loc")) (EVar "k")))
(DTypeSig false "patSites" (TyFun (TyCon "BinderKind") (TyFun (TyCon "Pat") (TyApp (TyCon "List") (TyCon "Site")))))
(DFunDef false "patSites" ((PVar "k") (PCon "PVar" (PVar "x") (PVar "l") PWild)) (EListLit (EApp (EApp (EApp (EVar "plainSite") (EVar "x")) (EVar "l")) (EVar "k"))))
(DFunDef false "patSites" (PWild (PCon "PWild")) (EListLit))
(DFunDef false "patSites" (PWild (PCon "PLit" PWild)) (EListLit))
(DFunDef false "patSites" ((PVar "k") (PCon "PCon" PWild (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "patSites") (EVar "k"))) (EVar "ps")))
(DFunDef false "patSites" ((PVar "k") (PCon "PCons" (PVar "a") (PVar "b"))) (EBinOp "++" (EApp (EApp (EVar "patSites") (EVar "k")) (EVar "a")) (EApp (EApp (EVar "patSites") (EVar "k")) (EVar "b"))))
(DFunDef false "patSites" ((PVar "k") (PCon "PTuple" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "patSites") (EVar "k"))) (EVar "ps")))
(DFunDef false "patSites" ((PVar "k") (PCon "PList" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "patSites") (EVar "k"))) (EVar "ps")))
(DFunDef false "patSites" ((PVar "k") (PCon "PAs" (PVar "x") (PVar "l") PWild (PVar "p"))) (EBinOp "::" (EApp (EApp (EApp (EVar "plainSite") (EVar "x")) (EVar "l")) (EVar "k")) (EApp (EApp (EVar "patSites") (EVar "k")) (EVar "p"))))
(DFunDef false "patSites" ((PVar "k") (PCon "POr" (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "patSites") (EVar "k"))) (EVar "ps")))
(DFunDef false "patSites" (PWild (PCon "PRng" PWild PWild PWild)) (EListLit))
(DFunDef false "patSites" ((PVar "k") (PCon "PRec" PWild (PVar "fields") PWild)) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "recFieldSites") (EVar "k"))) (EVar "fields")))
(DTypeSig false "recFieldSites" (TyFun (TyCon "BinderKind") (TyFun (TyCon "RecPatField") (TyApp (TyCon "List") (TyCon "Site")))))
(DFunDef false "recFieldSites" ((PVar "k") (PCon "RecPatField" (PVar "name") (PVar "l") PWild (PCon "None"))) (EListLit (EApp (EApp (EApp (EVar "plainSite") (EVar "name")) (EVar "l")) (EVar "k"))))
(DFunDef false "recFieldSites" ((PVar "k") (PCon "RecPatField" PWild PWild PWild (PCon "Some" (PVar "p")))) (EApp (EApp (EVar "patSites") (EVar "k")) (EVar "p")))
(DTypeSig false "ownerSites" (TyFun (TyCon "BodyOwner") (TyApp (TyCon "List") (TyCon "Site"))))
(DFunDef false "ownerSites" ((PCon "OwnerClause" PWild (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "patSites") (EVar "BParam"))) (EVar "ps")))
(DFunDef false "ownerSites" ((PCon "OwnerImplMethod" PWild PWild (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "patSites") (EVar "BParam"))) (EVar "ps")))
(DFunDef false "ownerSites" ((PCon "OwnerIfaceDefault" PWild PWild (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "patSites") (EVar "BParam"))) (EVar "ps")))
(DFunDef false "ownerSites" ((PCon "OwnerTest" PWild)) (EListLit))
(DFunDef false "ownerSites" ((PCon "OwnerProp" PWild (PVar "params"))) (EApp (EApp (EMethodRef "map") (EVar "propParamSite")) (EVar "params")))
(DFunDef false "ownerSites" ((PCon "OwnerLetGroup" PWild (PVar "ps"))) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "patSites") (EVar "BParam"))) (EVar "ps")))
(DTypeSig false "propParamSite" (TyFun (TyCon "PropParam") (TyCon "Site")))
(DFunDef false "propParamSite" ((PCon "PropParam" (PVar "n") (PVar "l") PWild)) (EApp (EApp (EApp (EVar "plainSite") (EVar "n")) (EVar "l")) (EVar "BParam")))
(DTypeSig false "mintFrame" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyCon "Site")) (TyApp (TyCon "List") (TyCon "Binder")))))
(DFunDef false "mintFrame" ((PVar "w") (PVar "sites")) (EApp (EVar "reverseL") (EApp (EApp (EApp (EVar "mintFrameGo") (EVar "w")) (EListLit)) (EVar "sites"))))
(DTypeSig false "mintFrameGo" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyCon "Binder")) (TyFun (TyApp (TyCon "List") (TyCon "Site")) (TyApp (TyCon "List") (TyCon "Binder"))))))
(DFunDef false "mintFrameGo" (PWild (PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "mintFrameGo" ((PVar "w") (PVar "acc") (PCons (PCon "Site" (PVar "n") (PVar "l") (PVar "k") (PVar "from") (PVar "origin")) (PVar "rest"))) (EMatch (EApp (EApp (EVar "findBinder") (EVar "n")) (EVar "acc")) (arm (PCon "Some" (PVar "b")) () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "pushAlt") (EVar "w")) (EVar "l")) (EVar "b"))) (DoExpr (EApp (EApp (EApp (EVar "mintFrameGo") (EVar "w")) (EVar "acc")) (EVar "rest"))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "mintFrameGo") (EVar "w")) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mintOne") (EVar "w")) (EVar "n")) (EVar "l")) (EVar "k")) (EVar "from")) (EVar "origin")) (EVar "acc"))) (EVar "rest")))))
(DTypeSig false "pushAlt" (TyFun (TyCon "W") (TyFun (TyCon "Loc") (TyFun (TyCon "Binder") (TyCon "Unit")))))
(DFunDef false "pushAlt" ((PCon "W" PWild PWild (PVar "alts") PWild) (PVar "l") (PVar "b")) (EApp (EApp (EVar "setRef") (EVar "alts")) (EBinOp "::" (ETuple (EVar "l") (EVar "b")) (EUnOp "!" (EVar "alts")))))
(DTypeSig false "mintOne" (TyFun (TyCon "W") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyFun (TyCon "BinderKind") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "String") (TyCon "Binder"))))))))
(DFunDef false "mintOne" ((PCon "W" (PVar "bs") PWild PWild (PVar "counter")) (PVar "n") (PVar "l") (PVar "k") (PVar "from") (PVar "origin")) (EBlock (DoLet false false (PVar "id") (EUnOp "!" (EVar "counter"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "counter")) (EBinOp "+" (EVar "id") (ELit (LInt 1))))) (DoLet false false (PVar "b") (ERecordCreate "Binder" ((fa "binderName" (EVar "n")) (fa "binderKind" (EVar "k")) (fa "binderSpan" (EVar "l")) (fa "binderId" (EVar "id")) (fa "binderFrom" (EVar "from")) (fa "binderOrigin" (EVar "origin"))))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "bs")) (EBinOp "::" (EVar "b") (EUnOp "!" (EVar "bs"))))) (DoExpr (EVar "b"))))
(DTypeSig false "findBinder" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Binder")) (TyApp (TyCon "Option") (TyCon "Binder")))))
(DFunDef false "findBinder" (PWild (PList)) (EVar "None"))
(DFunDef false "findBinder" ((PVar "n") (PCons (PVar "b") (PVar "rest"))) (EIf (EBinOp "==" (EFieldAccess (EVar "b") "binderName") (EVar "n")) (EApp (EVar "Some") (EVar "b")) (EApp (EApp (EVar "findBinder") (EVar "n")) (EVar "rest"))))
(DTypeSig false "lookupFrames" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyApp (TyCon "Option") (TyCon "Binder")))))
(DFunDef false "lookupFrames" (PWild (PList)) (EVar "None"))
(DFunDef false "lookupFrames" ((PVar "n") (PCons (PVar "frame") (PVar "rest"))) (EMatch (EApp (EApp (EVar "findBinder") (EVar "n")) (EVar "frame")) (arm (PCon "Some" (PVar "b")) () (EApp (EVar "Some") (EVar "b"))) (arm (PCon "None") () (EApp (EApp (EVar "lookupFrames") (EVar "n")) (EVar "rest")))))
(DTypeSig false "noteUse" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyFun (TyCon "Loc") (TyFun (TyCon "String") (TyCon "Unit"))))))
(DFunDef false "noteUse" ((PCon "W" PWild (PVar "us") PWild PWild) (PVar "scope") (PVar "loc") (PVar "n")) (EApp (EApp (EVar "setRef") (EVar "us")) (EBinOp "::" (ERecordCreate "Use" ((fa "useName" (EVar "n")) (fa "useSite" (EVar "loc")) (fa "useBinder" (EApp (EApp (EVar "lookupFrames") (EVar "n")) (EVar "scope"))))) (EUnOp "!" (EVar "us")))))
(DTypeSig false "walkDecls" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Unit")))))
(DFunDef false "walkDecls" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkDecls" ((PVar "w") (PVar "scope") (PCons (PVar "d") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "walkBodies") (EVar "w")) (EVar "scope")) (EApp (EVar "declBodies") (EVar "d")))) (DoExpr (EApp (EApp (EApp (EVar "walkDecls") (EVar "w")) (EVar "scope")) (EVar "rest")))))
(DTypeSig false "walkBodies" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyFun (TyApp (TyCon "List") (TyCon "DeclBody")) (TyCon "Unit")))))
(DFunDef false "walkBodies" (PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkBodies" ((PVar "w") (PVar "scope") (PCons (PCon "DeclBody" (PVar "owner") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EVar "ownerSites") (EVar "owner")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "noDeclLoc")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EVar "walkBodies") (EVar "w")) (EVar "scope")) (EVar "rest")))))
(DTypeSig false "walkExpr" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyFun (TyCon "Loc") (TyFun (TyCon "Expr") (TyCon "Unit"))))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") PWild (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "l")) (EVar "e")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") PWild (PCon "EDoOrigin" (PVar "l") (PVar "e"))) (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "l")) (EVar "e")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "loc") (PCon "EVar" (PVar "n"))) (EApp (EApp (EApp (EApp (EVar "noteUse") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "n")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "loc") (PCon "ELam" (PVar "ps") (PVar "body"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "patSites") (EVar "BLambda"))) (EVar "ps")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "loc")) (EVar "body")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "loc") (PCon "ELet" PWild (PVar "isRec") (PVar "p") (PVar "rhs") (PVar "body"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EApp (EVar "patSites") (EVar "BLet")) (EVar "p")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EIf (EVar "isRec") (EBinOp "::" (EVar "frame") (EVar "scope")) (EVar "scope"))) (EVar "loc")) (EVar "rhs"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "loc")) (EVar "body")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "loc") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EApp (EMethodRef "map") (EApp (EVar "letBindSite") (EVar "BWhere"))) (EVar "binds")))) (DoLet false false (PVar "scope1") (EBinOp "::" (EVar "frame") (EVar "scope"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkClauses") (EVar "w")) (EVar "scope1")) (EVar "loc")) (EApp (EApp (EDictApp "flatMap") (EVar "letBindClauses")) (EVar "binds")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope1")) (EVar "loc")) (EVar "body")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "loc") (PCon "EMatch" (PVar "scrut") (PVar "arms"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "scrut"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "arms")))))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "loc") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "stmts")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "loc") (PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "stmts")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "loc") (PCon "EGuards" (PVar "arms"))) (EApp (EApp (EApp (EApp (EVar "walkGuardArms") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "arms")))
(DFunDef false "walkExpr" ((PVar "w") (PVar "scope") (PVar "loc") (PVar "e")) (EApp (EApp (EApp (EApp (EVar "walkEach") (EVar "w")) (EVar "scope")) (EVar "loc")) (EApp (EVar "childExprs") (EVar "e"))))
(DTypeSig false "letBindClauses" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "FunClause"))))
(DFunDef false "letBindClauses" ((PCon "LetBind" PWild (PVar "clauses") PWild PWild)) (EVar "clauses"))
(DTypeSig false "walkEach" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Unit"))))))
(DFunDef false "walkEach" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkEach" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PVar "e") (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkEach") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "rest")))))
(DTypeSig false "walkClauses" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "FunClause")) (TyCon "Unit"))))))
(DFunDef false "walkClauses" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkClauses" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PCon "FunClause" (PVar "ps") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EApp (EDictApp "flatMap") (EApp (EVar "patSites") (EVar "BParam"))) (EVar "ps")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "loc")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkClauses") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "rest")))))
(DTypeSig false "walkArms" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Arm")) (TyCon "Unit"))))))
(DFunDef false "walkArms" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkArms" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PCon "Arm" (PVar "p") (PVar "gs") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "scope1") (EBinOp "::" (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EApp (EVar "patSites") (EVar "BMatchArm")) (EVar "p"))) (EVar "scope"))) (DoLet false false (PVar "scope2") (EApp (EApp (EApp (EApp (EVar "walkGuards") (EVar "w")) (EVar "scope1")) (EVar "loc")) (EVar "gs"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope2")) (EVar "loc")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkArms") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "rest")))))
(DTypeSig false "walkGuardArms" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "GuardArm")) (TyCon "Unit"))))))
(DFunDef false "walkGuardArms" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkGuardArms" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PCon "GuardArm" (PVar "gs") (PVar "body")) (PVar "rest"))) (EBlock (DoLet false false (PVar "scope2") (EApp (EApp (EApp (EApp (EVar "walkGuards") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "gs"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope2")) (EVar "loc")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkGuardArms") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "rest")))))
(DTypeSig false "walkGuards" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))))))))
(DFunDef false "walkGuards" (PWild (PVar "scope") PWild (PList)) (EVar "scope"))
(DFunDef false "walkGuards" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkGuards") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "rest")))))
(DFunDef false "walkGuards" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PCon "GBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkGuards") (EVar "w")) (EBinOp "::" (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EApp (EVar "patSites") (EVar "BMatchArm")) (EVar "p"))) (EVar "scope"))) (EVar "loc")) (EVar "rest")))))
(DTypeSig false "walkStmts" (TyFun (TyCon "W") (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Binder"))) (TyFun (TyCon "Loc") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "Unit"))))))
(DFunDef false "walkStmts" (PWild PWild PWild (PList)) (ELit LUnit))
(DFunDef false "walkStmts" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "rest")))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PCon "DoBind" (PVar "p") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EBinOp "::" (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EApp (EVar "patSites") (EVar "BDoBind")) (EVar "p"))) (EVar "scope"))) (EVar "loc")) (EVar "rest")))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PCon "DoLet" PWild (PVar "isRec") (PVar "p") (PVar "e") PWild) (PVar "rest"))) (EBlock (DoLet false false (PVar "frame") (EApp (EApp (EVar "mintFrame") (EVar "w")) (EApp (EApp (EVar "patSites") (EVar "BLet")) (EVar "p")))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EIf (EVar "isRec") (EBinOp "::" (EVar "frame") (EVar "scope")) (EVar "scope"))) (EVar "loc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EBinOp "::" (EVar "frame") (EVar "scope"))) (EVar "loc")) (EVar "rest")))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PCon "DoAssign" (PVar "x") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "noteUse") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "x"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "rest")))))
(DFunDef false "walkStmts" ((PVar "w") (PVar "scope") (PVar "loc") (PCons (PCon "DoFieldAssign" (PVar "x") PWild (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "noteUse") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "x"))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "walkExpr") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "e"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "walkStmts") (EVar "w")) (EVar "scope")) (EVar "loc")) (EVar "rest")))))
