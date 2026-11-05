# META
source_lines=413
stages=DESUGAR,MARK
# SOURCE
-- The binding of every bare lowercase name in one module, by scope alone: the
-- module's own top level, its explicit imports, its wildcard imports and the
-- prelude, innermost first (docs/spec/SHADOW-SEMANTICS.md, clauses L2 to L4).
-- No type, impl, constraint or syntactic position takes part, so the answer
-- needs nothing above the frontend.  Local binders (rung 1) belong to the
-- consumer's own walk and are not represented here.
--
-- A declaration is identified by its declaring module and the name it is
-- declared under there, so one declaration reached through two import paths is
-- one binding, and two declarations at one rung are an ambiguity.  The module
-- being scoped names its own declarations with the module id `""`: it is not
-- told its own id, and no import can reach it.

import frontend.ast.{
  Decl(..),
  ExternDecl(..),
  IfaceMethod(..),
  LetBind(..),
  Loc(..),
  UseMember(..),
  UsePath(..),
  useMemberLocal,
  useMemberOrigin,
}
import frontend.visibility.{ModuleExports, useModId}
import list.{last}
import support.ordmap.{OrdMap, omEmpty, omInsert, omLookup}
import support.util.{dedup, listLen, reverseL}

-- The rungs a module-level binding can come from, innermost first.
public export data NameRung =
  | RungOwn
  | RungExplicit
  | RungWild
  | RungPrelude
  deriving (Eq, Debug)

-- A declaration: a value by (declaring module, declared name), a method by
-- (declaring module, interface, method).
public export data NameTarget =
  | TargetValue String String
  | TargetMethod String String String
  deriving (Eq, Debug)

-- What a bare name denotes: the one declaration of the innermost rung that
-- binds it, or every distinct declaration that rung binds it to.
public export data NameBinding =
  | Bound NameRung NameTarget
  | Ambiguous NameRung (List NameTarget)
  deriving (Eq, Debug)

-- One import declaration of the module with the export surface of the module
-- it names.
public export data ImportedSurface = ImportedSurface Decl ModuleExports

-- A name bound twice where the ladder allows only one: an explicit import of a
-- name the module declares (rungs own and explicit, at the import member), or
-- an interface method and a top-level binding of one module (rungs own and own,
-- at the later declaration).
public export data NameCollision = NameCollision {
  ncName : String,
  ncFirst : NameTarget,
  ncSecond : NameTarget,
  ncRungs : (NameRung, NameRung),
  ncLoc : Loc,
}

-- `scBound` holds rungs 2 to 4; the prelude rung is read from `scPrelude` on
-- demand.  `scImporters` holds, for a name an import answers, the importing
-- module of each declaration that rung binds it to, in import order.
export data NameScope = NameScope {
  scBound : OrdMap NameBinding,
  scImporters : OrdMap (List String),
  scCollisions : List NameCollision,
  scPrelude : ModuleExports,
}

-- One name an import binds, with the declarations it denotes there.
data ImportBind = ImportBind {
  ibName : String,
  ibRung : NameRung,
  ibTargets : List NameTarget,
  ibLoc : Loc,
  ibModule : String,
}

-- The scope of a module from its declarations, its import declarations with
-- the surfaces they name, and the prelude's surface.
export
nameScopeOf : List Decl -> List ImportedSurface -> ModuleExports -> NameScope
nameScopeOf prog surfaces prelude =
  let (own, ownClashes) = ownBindings prog
  let preludeMethods = methodOrigins prelude
  let binds = flatMap (surfaceBinds preludeMethods) surfaces
  let explicit = rungTargets RungExplicit binds
  let wild = rungTargets RungWild binds
  -- Each inner rung is inserted over the outer one, so it answers.
  let imported =
    fold
      (insertRung RungExplicit)
      (fold (insertRung RungWild) omEmpty wild)
      explicit
  let bound = fold (m (n, b) => omInsert n b m) imported own
  let importers =
    fold insertImporters (fold insertImporters omEmpty wild) explicit
  NameScope {
    scBound = bound,
    scImporters = importers,
    scCollisions = ownClashes ++ importClashes bound binds,
    scPrelude = prelude,
  }

-- The binding of bare [n], if any rung binds it.
export
bareBinding : NameScope -> String -> Option NameBinding
bareBinding scope n = match omLookup n scope.scBound
  Some b => Some b
  None => preludeBinding scope.scPrelude n

-- Every collision in the module, the duplicate declarations first and then the
-- explicit imports of an own name, each in source order.
export
scopeCollisions : NameScope -> List NameCollision
scopeCollisions scope = scope.scCollisions

-- The importing module of each declaration bare [n] denotes, in import order,
-- when an import answers it; empty when the module or the prelude does.
export
bindingImporters : NameScope -> String -> List String
bindingImporters scope n = match omLookup n scope.scBound
  Some (Bound RungOwn _) => []
  Some (Ambiguous RungOwn _) => []
  Some _ => match omLookup n scope.scImporters
    Some ms => ms
    None => []
  None => []

-- ── rung 2: the module's own declarations ──────────────────────────────────

-- The own binding of every name the module declares, and a collision for each
-- name declared both as an interface method and as a top-level binding.
ownBindings : List Decl -> (List (String, NameBinding), List NameCollision)
ownBindings prog =
  let walk = fold ownStep emptyOwnWalk (flatMap declBinders prog)
  let clashed = fold (m c => omInsert c.ncName c m) omEmpty walk.owClashes
  let bindingOf n t = match omLookup n clashed
    Some c => (n, Ambiguous RungOwn [c.ncFirst, c.ncSecond])
    None => (n, Bound RungOwn t)
  (
    map (e => bindingOf (fst e) (fst (snd e))) (reverseL walk.owOrder),
    reverseL walk.owClashes,
  )

-- Each name's first declaration, by name and in source order, and the
-- collisions found so far, latest first.
data OwnWalk = OwnWalk {
  owFirst : OrdMap (NameTarget, Option Loc),
  owOrder : List (String, (NameTarget, Option Loc)),
  owClashes : List NameCollision,
}

emptyOwnWalk : OwnWalk
emptyOwnWalk = OwnWalk { owFirst = omEmpty, owOrder = [], owClashes = [] }

ownStep : OwnWalk -> (String, NameTarget, Option Loc) -> OwnWalk
ownStep walk (n, t, l) = match omLookup n walk.owFirst
  None => { walk |
    owFirst = omInsert n (t, l) walk.owFirst,
    owOrder = (n, (t, l)) :: walk.owOrder,
  }
  Some (first, firstLoc) =>
    if isMethod first /= isMethod t && not (anyClash n walk.owClashes) then
      let clash = NameCollision {
        ncName = n,
        ncFirst = first,
        ncSecond = t,
        ncRungs = (RungOwn, RungOwn),
        ncLoc = locOr l firstLoc,
      }
      { walk | owClashes = clash :: walk.owClashes }
    else
      walk

anyClash : String -> List NameCollision -> Bool
anyClash n clashes = any (c => c.ncName == n) clashes

isMethod : NameTarget -> Bool
isMethod (TargetMethod _ _ _) = True
isMethod (TargetValue _ _) = False

-- The later declaration's span, else the earlier one's: an interface method
-- parsed without a span still reports at a real declaration.
locOr : Option Loc -> Option Loc -> Loc
locOr (Some l) _ = l
locOr None (Some l) = l
locOr None None = Loc "" 0 0 0 0

-- The names one top-level declaration binds, each with its declaration and
-- span.  A signature counts as a declaration of its name, so a signature
-- without a body still keeps an import from answering for it.
declBinders : Decl -> List (String, NameTarget, Option Loc)
declBinders (DFunDef _ n _ _ loc _) = [ownValue n (Some loc)]
declBinders (DTypeSig _ n _ loc) = [ownValue n (Some loc)]
declBinders (DExtern ed) = [ownValue ed.edName (Some ed.edLoc)]
declBinders (DLetGroup _ binds) = map letBinder binds
declBinders (DInterface { name = i, methods, ifaceNameLoc, ... }) =
  map (methodBinder i ifaceNameLoc) methods
declBinders (DAttrib _ d) = declBinders d
declBinders _ = []

ownValue : String -> Option Loc -> (String, NameTarget, Option Loc)
ownValue n l = (n, TargetValue "" n, l)

letBinder : LetBind -> (String, NameTarget, Option Loc)
letBinder (LetBind n _ loc _) = ownValue n (Some loc)

methodBinder : String ->
  Option Loc ->
  IfaceMethod ->
  (String, NameTarget, Option Loc)
methodBinder i _ (IfaceMethod m _ _ (Some loc)) =
  (m, TargetMethod "" i m, Some loc)
methodBinder i nameLoc (IfaceMethod m _ _ None) =
  (m, TargetMethod "" i m, nameLoc)

-- ── rungs 3 and 4: explicit and wildcard imports ───────────────────────────

-- The names one import declaration binds.  A member list and a single dotted
-- name bind at the explicit rung, a wildcard at the wildcard rung; a module
-- alias and a bare module import bind no bare name.  A member that names no
-- exported value (a type, a constructor, an interface) binds no value here.
surfaceBinds : OrdMap (List (String, String)) ->
  ImportedSurface ->
  List ImportBind
surfaceBinds preludeMethods (ImportedSurface (DAttrib _ d) exp) =
  surfaceBinds preludeMethods (ImportedSurface d exp)
surfaceBinds preludeMethods (ImportedSurface (DUse _ path useLoc) exp) =
  let decls = declsByName exp
  let methods = methodOrigins exp
  let mid = useModId path
  let bindAt rung local origin loc = match omLookup origin decls
    Some ds => [
      ImportBind {
        ibName = local,
        ibRung = rung,
        ibTargets = map (classify preludeMethods methods) ds,
        ibLoc = loc,
        ibModule = mid,
      },
    ]
    None => []
  match path
    UseGroup _ members =>
      flatMap
        (m =>
          bindAt
            RungExplicit
            (useMemberLocal m)
            (useMemberOrigin m)
            (memberLoc m))
        members
    UseName ns =>
      if listLen ns > 1 then
        let n = optionOr "" (last ns)
        bindAt RungExplicit n n useLoc
      else
        []
    UseWild _ => flatMap (v => bindAt RungWild v v useLoc) (dedup exp.expValues)
    UseAlias _ _ => []
surfaceBinds _ _ = []

memberLoc : UseMember -> Loc
memberLoc (UseMember _ _ loc _) = loc

-- Each exported value name with the distinct declarations it denotes, read
-- from the whole origin list: a hub that re-exports two declarations under
-- one name keeps both.
declsByName : ModuleExports -> OrdMap (List (String, String))
declsByName exp =
  fold
    (m (n, d) => match omLookup n m
      Some ds => if any (== d) ds then m else omInsert n (ds ++ [d]) m
      None => omInsert n [d] m)
    omEmpty
    exp.expValueOrigins

-- Each method name of the surface's interfaces with every (interface,
-- declaring module) pair that declares it.
methodOrigins : ModuleExports -> OrdMap (List (String, String))
methodOrigins exp =
  fold
    (m (i, ms) =>
      let owners = map snd (filter (o => fst o == i) exp.expIfaceOrigins)
      fold
        (acc meth => match omLookup meth acc
          Some ps => omInsert meth (ps ++ map (o => (i, o)) owners) acc
          None => omInsert meth (map (o => (i, o)) owners) acc)
        m
        ms)
    omEmpty
    exp.expIfaceMethods

-- A declaration is a method when an interface of the surface declares it in its
-- declaring module.  A prelude method re-exported without its interface is
-- still found through the prelude's own interfaces.
classify : OrdMap (List (String, String)) ->
  OrdMap (List (String, String)) ->
  (String, String) ->
  NameTarget
classify preludeMethods methods (m, d) = match declaringIface m d methods
  Some i => TargetMethod m i d
  None => classifyPrelude preludeMethods (m, d)

classifyPrelude : OrdMap (List (String, String)) ->
  (String, String) ->
  NameTarget
classifyPrelude preludeMethods (m, d)
  | m == "core" = match declaringIface m d preludeMethods
    Some i => TargetMethod m i d
    None => TargetValue m d
  | otherwise = TargetValue m d

-- The interface of [methods] that declares method [d] in module [m].
declaringIface : String ->
  String ->
  OrdMap (List (String, String)) ->
  Option String
declaringIface m d methods =
  map fst (find (p => snd p == m) (methodsNamed d methods))

methodsNamed : String -> OrdMap (List (String, String)) -> List (String, String)
methodsNamed d methods = match omLookup d methods
  Some ps => ps
  None => []

-- Every name the imports of [rung] bind, in first-binding order, with its
-- distinct declarations and the importing module that first brought each.
rungTargets : NameRung ->
  List ImportBind ->
  List (String, List (NameTarget, String))
rungTargets rung binds =
  let (m, order) =
    fold
      (acc b => if b.ibRung == rung then addBind acc b else acc)
      (omEmpty, [])
      binds
  map (n => (n, targetsOf n m)) (reverseL order)

addBind : (OrdMap (List (NameTarget, String)), List String) ->
  ImportBind ->
  (OrdMap (List (NameTarget, String)), List String)
addBind (m, order) b =
  let fresh known = filter (t => not (any (p => fst p == t) known)) b.ibTargets
  match omLookup b.ibName m
    Some known => (
      omInsert b.ibName (known ++ map (t => (t, b.ibModule)) (fresh known)) m,
      order,
    )
    None => (
      omInsert b.ibName (map (t => (t, b.ibModule)) (fresh [])) m,
      b.ibName :: order,
    )

targetsOf : String ->
  OrdMap (List (NameTarget, String)) ->
  List (NameTarget, String)
targetsOf n m = match omLookup n m
  Some ts => ts
  None => []

insertRung : NameRung ->
  OrdMap NameBinding ->
  (String, List (NameTarget, String)) ->
  OrdMap NameBinding
insertRung rung m (n, ts) = omInsert n (rungBinding rung ts) m

insertImporters : OrdMap (List String) ->
  (String, List (NameTarget, String)) ->
  OrdMap (List String)
insertImporters m (n, ts) = omInsert n (map snd ts) m

rungBinding : NameRung -> List (NameTarget, String) -> NameBinding
rungBinding rung [(t, _)] = Bound rung t
rungBinding rung ts = Ambiguous rung (map fst ts)

-- An explicit import of a name the module declares, at the import member.
importClashes : OrdMap NameBinding -> List ImportBind -> List NameCollision
importClashes bound binds =
  flatMap
    (b => match (b.ibRung, omLookup b.ibName bound, b.ibTargets)
      (RungExplicit, Some (Bound RungOwn own), t :: _) => [ownClash b own t]
      (RungExplicit, Some (Ambiguous RungOwn (own :: _)), t :: _) =>
        [ownClash b own t]
      _ => [])
    binds

ownClash : ImportBind -> NameTarget -> NameTarget -> NameCollision
ownClash b own t = NameCollision {
  ncName = b.ibName,
  ncFirst = own,
  ncSecond = t,
  ncRungs = (RungOwn, RungExplicit),
  ncLoc = b.ibLoc,
}

-- ── rung 5: the prelude ────────────────────────────────────────────────────

preludeBinding : ModuleExports -> String -> Option NameBinding
preludeBinding prelude n = match omLookup n (declsByName prelude)
  Some (d :: _) =>
    let methods = methodOrigins prelude
    Some (Bound RungPrelude (classify methods methods d))
  _ => None
# DESUGAR
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "ExternDecl" true) (mem "IfaceMethod" true) (mem "LetBind" true) (mem "Loc" true) (mem "UseMember" true) (mem "UsePath" true) (mem "useMemberLocal" false) (mem "useMemberOrigin" false))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "ModuleExports" false) (mem "useModId" false))))
(DUse false (UseGroup ("list") ((mem "last" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "dedup" false) (mem "listLen" false) (mem "reverseL" false))))
(DData Public "NameRung" () ((variant "RungOwn" (ConPos)) (variant "RungExplicit" (ConPos)) (variant "RungWild" (ConPos)) (variant "RungPrelude" (ConPos))) ())
(DImpl true "Eq" ((TyCon "NameRung")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RungOwn") (PCon "RungOwn")) () (EVar "True")) (arm (PTuple (PCon "RungExplicit") (PCon "RungExplicit")) () (EVar "True")) (arm (PTuple (PCon "RungWild") (PCon "RungWild")) () (EVar "True")) (arm (PTuple (PCon "RungPrelude") (PCon "RungPrelude")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "NameRung")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "RungOwn") () (ELit (LString "RungOwn"))) (arm (PCon "RungExplicit") () (ELit (LString "RungExplicit"))) (arm (PCon "RungWild") () (ELit (LString "RungWild"))) (arm (PCon "RungPrelude") () (ELit (LString "RungPrelude")))))))
(DData Public "NameTarget" () ((variant "TargetValue" (ConPos (TyCon "String") (TyCon "String"))) (variant "TargetMethod" (ConPos (TyCon "String") (TyCon "String") (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "NameTarget")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TargetValue" (PVar "__a0") (PVar "__a1")) (PCon "TargetValue" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "$core.eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "$core.eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "TargetMethod" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "TargetMethod" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "$core.eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "$core.eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "$core.eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "NameTarget")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "TargetValue" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "TargetValue ")) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a1"))))) (arm (PCon "TargetMethod" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "TargetMethod ")) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a2")))))))))
(DData Public "NameBinding" () ((variant "Bound" (ConPos (TyCon "NameRung") (TyCon "NameTarget"))) (variant "Ambiguous" (ConPos (TyCon "NameRung") (TyApp (TyCon "List") (TyCon "NameTarget"))))) ())
(DImpl true "Eq" ((TyCon "NameBinding")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Bound" (PVar "__a0") (PVar "__a1")) (PCon "Bound" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "$core.eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "$core.eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "Ambiguous" (PVar "__a0") (PVar "__a1")) (PCon "Ambiguous" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "$core.eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "$core.eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "NameBinding")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Bound" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Bound ")) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a1"))))) (arm (PCon "Ambiguous" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Ambiguous ")) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a1")))))))))
(DData Public "ImportedSurface" () ((variant "ImportedSurface" (ConPos (TyCon "Decl") (TyCon "ModuleExports")))) ())
(DData Public "NameCollision" () ((variant "NameCollision" (ConNamed (field "ncName" (TyCon "String")) (field "ncFirst" (TyCon "NameTarget")) (field "ncSecond" (TyCon "NameTarget")) (field "ncRungs" (TyTuple (TyCon "NameRung") (TyCon "NameRung"))) (field "ncLoc" (TyCon "Loc"))))) ())
(DData Abstract "NameScope" () ((variant "NameScope" (ConNamed (field "scBound" (TyApp (TyCon "OrdMap") (TyCon "NameBinding"))) (field "scImporters" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "scCollisions" (TyApp (TyCon "List") (TyCon "NameCollision"))) (field "scPrelude" (TyCon "ModuleExports"))))) ())
(DData Private "ImportBind" () ((variant "ImportBind" (ConNamed (field "ibName" (TyCon "String")) (field "ibRung" (TyCon "NameRung")) (field "ibTargets" (TyApp (TyCon "List") (TyCon "NameTarget"))) (field "ibLoc" (TyCon "Loc")) (field "ibModule" (TyCon "String"))))) ())
(DTypeSig true "nameScopeOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "ImportedSurface")) (TyFun (TyCon "ModuleExports") (TyCon "NameScope")))))
(DFunDef false "nameScopeOf" ((PVar "prog") (PVar "surfaces") (PVar "prelude")) (EBlock (DoLet false false (PTuple (PVar "own") (PVar "ownClashes")) (EApp (EVar "ownBindings") (EVar "prog"))) (DoLet false false (PVar "preludeMethods") (EApp (EVar "methodOrigins") (EVar "prelude"))) (DoLet false false (PVar "binds") (EApp (EApp (EVar "flatMap") (EApp (EVar "surfaceBinds") (EVar "preludeMethods"))) (EVar "surfaces"))) (DoLet false false (PVar "explicit") (EApp (EApp (EVar "rungTargets") (EVar "RungExplicit")) (EVar "binds"))) (DoLet false false (PVar "wild") (EApp (EApp (EVar "rungTargets") (EVar "RungWild")) (EVar "binds"))) (DoLet false false (PVar "imported") (EApp (EApp (EApp (EVar "fold") (EApp (EVar "insertRung") (EVar "RungExplicit"))) (EApp (EApp (EApp (EVar "fold") (EApp (EVar "insertRung") (EVar "RungWild"))) (EVar "omEmpty")) (EVar "wild"))) (EVar "explicit"))) (DoLet false false (PVar "bound") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PTuple (PVar "n") (PVar "b"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "b")) (EVar "m")))) (EVar "imported")) (EVar "own"))) (DoLet false false (PVar "importers") (EApp (EApp (EApp (EVar "fold") (EVar "insertImporters")) (EApp (EApp (EApp (EVar "fold") (EVar "insertImporters")) (EVar "omEmpty")) (EVar "wild"))) (EVar "explicit"))) (DoExpr (ERecordCreate "NameScope" ((fa "scBound" (EVar "bound")) (fa "scImporters" (EVar "importers")) (fa "scCollisions" (EBinOp "++" (EVar "ownClashes") (EApp (EApp (EVar "importClashes") (EVar "bound")) (EVar "binds")))) (fa "scPrelude" (EVar "prelude")))))))
(DTypeSig true "bareBinding" (TyFun (TyCon "NameScope") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "NameBinding")))))
(DFunDef false "bareBinding" ((PVar "scope") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EVar "scope") "scBound")) (arm (PCon "Some" (PVar "b")) () (EApp (EVar "Some") (EVar "b"))) (arm (PCon "None") () (EApp (EApp (EVar "preludeBinding") (EFieldAccess (EVar "scope") "scPrelude")) (EVar "n")))))
(DTypeSig true "scopeCollisions" (TyFun (TyCon "NameScope") (TyApp (TyCon "List") (TyCon "NameCollision"))))
(DFunDef false "scopeCollisions" ((PVar "scope")) (EFieldAccess (EVar "scope") "scCollisions"))
(DTypeSig true "bindingImporters" (TyFun (TyCon "NameScope") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "bindingImporters" ((PVar "scope") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EVar "scope") "scBound")) (arm (PCon "Some" (PCon "Bound" (PCon "RungOwn") PWild)) () (EListLit)) (arm (PCon "Some" (PCon "Ambiguous" (PCon "RungOwn") PWild)) () (EListLit)) (arm (PCon "Some" PWild) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EVar "scope") "scImporters")) (arm (PCon "Some" (PVar "ms")) () (EVar "ms")) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "ownBindings" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "NameBinding"))) (TyApp (TyCon "List") (TyCon "NameCollision")))))
(DFunDef false "ownBindings" ((PVar "prog")) (EBlock (DoLet false false (PVar "walk") (EApp (EApp (EApp (EVar "fold") (EVar "ownStep")) (EVar "emptyOwnWalk")) (EApp (EApp (EVar "flatMap") (EVar "declBinders")) (EVar "prog")))) (DoLet false false (PVar "clashed") (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "c")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "c") "ncName")) (EVar "c")) (EVar "m")))) (EVar "omEmpty")) (EFieldAccess (EVar "walk") "owClashes"))) (DoLet false true (PVar "bindingOf") (ELam ((PVar "n")) (ELam ((PVar "t")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "clashed")) (arm (PCon "Some" (PVar "c")) () (ETuple (EVar "n") (EApp (EApp (EVar "Ambiguous") (EVar "RungOwn")) (EListLit (EFieldAccess (EVar "c") "ncFirst") (EFieldAccess (EVar "c") "ncSecond"))))) (arm (PCon "None") () (ETuple (EVar "n") (EApp (EApp (EVar "Bound") (EVar "RungOwn")) (EVar "t")))))))) (DoExpr (ETuple (EApp (EApp (EVar "map") (ELam ((PVar "e")) (EApp (EApp (EVar "bindingOf") (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "fst") (EApp (EVar "snd") (EVar "e")))))) (EApp (EVar "reverseL") (EFieldAccess (EVar "walk") "owOrder"))) (EApp (EVar "reverseL") (EFieldAccess (EVar "walk") "owClashes"))))))
(DData Private "OwnWalk" () ((variant "OwnWalk" (ConNamed (field "owFirst" (TyApp (TyCon "OrdMap") (TyTuple (TyCon "NameTarget") (TyApp (TyCon "Option") (TyCon "Loc"))))) (field "owOrder" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "NameTarget") (TyApp (TyCon "Option") (TyCon "Loc")))))) (field "owClashes" (TyApp (TyCon "List") (TyCon "NameCollision")))))) ())
(DTypeSig false "emptyOwnWalk" (TyCon "OwnWalk"))
(DFunDef false "emptyOwnWalk" () (ERecordCreate "OwnWalk" ((fa "owFirst" (EVar "omEmpty")) (fa "owOrder" (EListLit)) (fa "owClashes" (EListLit)))))
(DTypeSig false "ownStep" (TyFun (TyCon "OwnWalk") (TyFun (TyTuple (TyCon "String") (TyCon "NameTarget") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "OwnWalk"))))
(DFunDef false "ownStep" ((PVar "walk") (PTuple (PVar "n") (PVar "t") (PVar "l"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EVar "walk") "owFirst")) (arm (PCon "None") () (ERecordUpdate (EVar "walk") ((fa "owFirst" (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ETuple (EVar "t") (EVar "l"))) (EFieldAccess (EVar "walk") "owFirst"))) (fa "owOrder" (EBinOp "::" (ETuple (EVar "n") (ETuple (EVar "t") (EVar "l"))) (EFieldAccess (EVar "walk") "owOrder")))))) (arm (PCon "Some" (PTuple (PVar "first") (PVar "firstLoc"))) () (EIf (EBinOp "&&" (EBinOp "/=" (EApp (EVar "isMethod") (EVar "first")) (EApp (EVar "isMethod") (EVar "t"))) (EApp (EVar "not") (EApp (EApp (EVar "anyClash") (EVar "n")) (EFieldAccess (EVar "walk") "owClashes")))) (EBlock (DoLet false false (PVar "clash") (ERecordCreate "NameCollision" ((fa "ncName" (EVar "n")) (fa "ncFirst" (EVar "first")) (fa "ncSecond" (EVar "t")) (fa "ncRungs" (ETuple (EVar "RungOwn") (EVar "RungOwn"))) (fa "ncLoc" (EApp (EApp (EVar "locOr") (EVar "l")) (EVar "firstLoc")))))) (DoExpr (ERecordUpdate (EVar "walk") ((fa "owClashes" (EBinOp "::" (EVar "clash") (EFieldAccess (EVar "walk") "owClashes"))))))) (EVar "walk")))))
(DTypeSig false "anyClash" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "NameCollision")) (TyCon "Bool"))))
(DFunDef false "anyClash" ((PVar "n") (PVar "clashes")) (EApp (EApp (EVar "any") (ELam ((PVar "c")) (EBinOp "==" (EFieldAccess (EVar "c") "ncName") (EVar "n")))) (EVar "clashes")))
(DTypeSig false "isMethod" (TyFun (TyCon "NameTarget") (TyCon "Bool")))
(DFunDef false "isMethod" ((PCon "TargetMethod" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isMethod" ((PCon "TargetValue" PWild PWild)) (EVar "False"))
(DTypeSig false "locOr" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Loc"))))
(DFunDef false "locOr" ((PCon "Some" (PVar "l")) PWild) (EVar "l"))
(DFunDef false "locOr" ((PCon "None") (PCon "Some" (PVar "l"))) (EVar "l"))
(DFunDef false "locOr" ((PCon "None") (PCon "None")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "declBinders" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "NameTarget") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "declBinders" ((PCon "DFunDef" PWild (PVar "n") PWild PWild (PVar "loc") PWild)) (EListLit (EApp (EApp (EVar "ownValue") (EVar "n")) (EApp (EVar "Some") (EVar "loc")))))
(DFunDef false "declBinders" ((PCon "DTypeSig" PWild (PVar "n") PWild (PVar "loc"))) (EListLit (EApp (EApp (EVar "ownValue") (EVar "n")) (EApp (EVar "Some") (EVar "loc")))))
(DFunDef false "declBinders" ((PCon "DExtern" (PVar "ed"))) (EListLit (EApp (EApp (EVar "ownValue") (EFieldAccess (EVar "ed") "edName")) (EApp (EVar "Some") (EFieldAccess (EVar "ed") "edLoc")))))
(DFunDef false "declBinders" ((PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EVar "map") (EVar "letBinder")) (EVar "binds")))
(DFunDef false "declBinders" ((PRec "DInterface" ((rf "name" (PVar "i")) (rf "methods" None) (rf "ifaceNameLoc" None)) true)) (EApp (EApp (EVar "map") (EApp (EApp (EVar "methodBinder") (EVar "i")) (EVar "ifaceNameLoc"))) (EVar "methods")))
(DFunDef false "declBinders" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declBinders") (EVar "d")))
(DFunDef false "declBinders" (PWild) (EListLit))
(DTypeSig false "ownValue" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyTuple (TyCon "String") (TyCon "NameTarget") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "ownValue" ((PVar "n") (PVar "l")) (ETuple (EVar "n") (EApp (EApp (EVar "TargetValue") (ELit (LString ""))) (EVar "n")) (EVar "l")))
(DTypeSig false "letBinder" (TyFun (TyCon "LetBind") (TyTuple (TyCon "String") (TyCon "NameTarget") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "letBinder" ((PCon "LetBind" (PVar "n") PWild (PVar "loc") PWild)) (EApp (EApp (EVar "ownValue") (EVar "n")) (EApp (EVar "Some") (EVar "loc"))))
(DTypeSig false "methodBinder" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "IfaceMethod") (TyTuple (TyCon "String") (TyCon "NameTarget") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "methodBinder" ((PVar "i") PWild (PCon "IfaceMethod" (PVar "m") PWild PWild (PCon "Some" (PVar "loc")))) (ETuple (EVar "m") (EApp (EApp (EApp (EVar "TargetMethod") (ELit (LString ""))) (EVar "i")) (EVar "m")) (EApp (EVar "Some") (EVar "loc"))))
(DFunDef false "methodBinder" ((PVar "i") (PVar "nameLoc") (PCon "IfaceMethod" (PVar "m") PWild PWild (PCon "None"))) (ETuple (EVar "m") (EApp (EApp (EApp (EVar "TargetMethod") (ELit (LString ""))) (EVar "i")) (EVar "m")) (EVar "nameLoc")))
(DTypeSig false "surfaceBinds" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "ImportedSurface") (TyApp (TyCon "List") (TyCon "ImportBind")))))
(DFunDef false "surfaceBinds" ((PVar "preludeMethods") (PCon "ImportedSurface" (PCon "DAttrib" PWild (PVar "d")) (PVar "exp"))) (EApp (EApp (EVar "surfaceBinds") (EVar "preludeMethods")) (EApp (EApp (EVar "ImportedSurface") (EVar "d")) (EVar "exp"))))
(DFunDef false "surfaceBinds" ((PVar "preludeMethods") (PCon "ImportedSurface" (PCon "DUse" PWild (PVar "path") (PVar "useLoc")) (PVar "exp"))) (EBlock (DoLet false false (PVar "decls") (EApp (EVar "declsByName") (EVar "exp"))) (DoLet false false (PVar "methods") (EApp (EVar "methodOrigins") (EVar "exp"))) (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoLet false true (PVar "bindAt") (ELam ((PVar "rung")) (ELam ((PVar "local")) (ELam ((PVar "origin")) (ELam ((PVar "loc")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "origin")) (EVar "decls")) (arm (PCon "Some" (PVar "ds")) () (EListLit (ERecordCreate "ImportBind" ((fa "ibName" (EVar "local")) (fa "ibRung" (EVar "rung")) (fa "ibTargets" (EApp (EApp (EVar "map") (EApp (EApp (EVar "classify") (EVar "preludeMethods")) (EVar "methods"))) (EVar "ds"))) (fa "ibLoc" (EVar "loc")) (fa "ibModule" (EVar "mid")))))) (arm (PCon "None") () (EListLit)))))))) (DoExpr (EMatch (EVar "path") (arm (PCon "UseGroup" PWild (PVar "members")) () (EApp (EApp (EVar "flatMap") (ELam ((PVar "m")) (EApp (EApp (EApp (EApp (EVar "bindAt") (EVar "RungExplicit")) (EApp (EVar "useMemberLocal") (EVar "m"))) (EApp (EVar "useMemberOrigin") (EVar "m"))) (EApp (EVar "memberLoc") (EVar "m"))))) (EVar "members"))) (arm (PCon "UseName" (PVar "ns")) () (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EVar "last") (EVar "ns")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "bindAt") (EVar "RungExplicit")) (EVar "n")) (EVar "n")) (EVar "useLoc")))) (EListLit))) (arm (PCon "UseWild" PWild) () (EApp (EApp (EVar "flatMap") (ELam ((PVar "v")) (EApp (EApp (EApp (EApp (EVar "bindAt") (EVar "RungWild")) (EVar "v")) (EVar "v")) (EVar "useLoc")))) (EApp (EVar "dedup") (EFieldAccess (EVar "exp") "expValues")))) (arm (PCon "UseAlias" PWild PWild) () (EListLit))))))
(DFunDef false "surfaceBinds" (PWild PWild) (EListLit))
(DTypeSig false "memberLoc" (TyFun (TyCon "UseMember") (TyCon "Loc")))
(DFunDef false "memberLoc" ((PCon "UseMember" PWild PWild (PVar "loc") PWild)) (EVar "loc"))
(DTypeSig false "declsByName" (TyFun (TyCon "ModuleExports") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "declsByName" ((PVar "exp")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PTuple (PVar "n") (PVar "d"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "m")) (arm (PCon "Some" (PVar "ds")) () (EIf (EApp (EApp (EVar "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "d")))) (EVar "ds")) (EVar "m") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EBinOp "++" (EVar "ds") (EListLit (EVar "d")))) (EVar "m")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EListLit (EVar "d"))) (EVar "m")))))) (EVar "omEmpty")) (EFieldAccess (EVar "exp") "expValueOrigins")))
(DTypeSig false "methodOrigins" (TyFun (TyCon "ModuleExports") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "methodOrigins" ((PVar "exp")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PTuple (PVar "i") (PVar "ms"))) (EBlock (DoLet false false (PVar "owners") (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EApp (EVar "filter") (ELam ((PVar "o")) (EBinOp "==" (EApp (EVar "fst") (EVar "o")) (EVar "i")))) (EFieldAccess (EVar "exp") "expIfaceOrigins")))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "meth")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "meth")) (EVar "acc")) (arm (PCon "Some" (PVar "ps")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "meth")) (EBinOp "++" (EVar "ps") (EApp (EApp (EVar "map") (ELam ((PVar "o")) (ETuple (EVar "i") (EVar "o")))) (EVar "owners")))) (EVar "acc"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "omInsert") (EVar "meth")) (EApp (EApp (EVar "map") (ELam ((PVar "o")) (ETuple (EVar "i") (EVar "o")))) (EVar "owners"))) (EVar "acc")))))) (EVar "m")) (EVar "ms")))))) (EVar "omEmpty")) (EFieldAccess (EVar "exp") "expIfaceMethods")))
(DTypeSig false "classify" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "NameTarget")))))
(DFunDef false "classify" ((PVar "preludeMethods") (PVar "methods") (PTuple (PVar "m") (PVar "d"))) (EMatch (EApp (EApp (EApp (EVar "declaringIface") (EVar "m")) (EVar "d")) (EVar "methods")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "TargetMethod") (EVar "m")) (EVar "i")) (EVar "d"))) (arm (PCon "None") () (EApp (EApp (EVar "classifyPrelude") (EVar "preludeMethods")) (ETuple (EVar "m") (EVar "d"))))))
(DTypeSig false "classifyPrelude" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "NameTarget"))))
(DFunDef false "classifyPrelude" ((PVar "preludeMethods") (PTuple (PVar "m") (PVar "d"))) (EIf (EBinOp "==" (EVar "m") (ELit (LString "core"))) (EMatch (EApp (EApp (EApp (EVar "declaringIface") (EVar "m")) (EVar "d")) (EVar "preludeMethods")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "TargetMethod") (EVar "m")) (EVar "i")) (EVar "d"))) (arm (PCon "None") () (EApp (EApp (EVar "TargetValue") (EVar "m")) (EVar "d")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "TargetValue") (EVar "m")) (EVar "d")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declaringIface" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "declaringIface" ((PVar "m") (PVar "d") (PVar "methods")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "find") (ELam ((PVar "p")) (EBinOp "==" (EApp (EVar "snd") (EVar "p")) (EVar "m")))) (EApp (EApp (EVar "methodsNamed") (EVar "d")) (EVar "methods")))))
(DTypeSig false "methodsNamed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "methodsNamed" ((PVar "d") (PVar "methods")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "d")) (EVar "methods")) (arm (PCon "Some" (PVar "ps")) () (EVar "ps")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "rungTargets" (TyFun (TyCon "NameRung") (TyFun (TyApp (TyCon "List") (TyCon "ImportBind")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "NameTarget") (TyCon "String"))))))))
(DFunDef false "rungTargets" ((PVar "rung") (PVar "binds")) (EBlock (DoLet false false (PTuple (PVar "m") (PVar "order")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "b")) (EIf (EBinOp "==" (EFieldAccess (EVar "b") "ibRung") (EVar "rung")) (EApp (EApp (EVar "addBind") (EVar "acc")) (EVar "b")) (EVar "acc")))) (ETuple (EVar "omEmpty") (EListLit))) (EVar "binds"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EApp (EVar "targetsOf") (EVar "n")) (EVar "m"))))) (EApp (EVar "reverseL") (EVar "order"))))))
(DTypeSig false "addBind" (TyFun (TyTuple (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "NameTarget") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "ImportBind") (TyTuple (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "NameTarget") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "addBind" ((PTuple (PVar "m") (PVar "order")) (PVar "b")) (EBlock (DoLet false true (PVar "fresh") (ELam ((PVar "known")) (EApp (EApp (EVar "filter") (ELam ((PVar "t")) (EApp (EVar "not") (EApp (EApp (EVar "any") (ELam ((PVar "p")) (EBinOp "==" (EApp (EVar "fst") (EVar "p")) (EVar "t")))) (EVar "known"))))) (EFieldAccess (EVar "b") "ibTargets")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "b") "ibName")) (EVar "m")) (arm (PCon "Some" (PVar "known")) () (ETuple (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "b") "ibName")) (EBinOp "++" (EVar "known") (EApp (EApp (EVar "map") (ELam ((PVar "t")) (ETuple (EVar "t") (EFieldAccess (EVar "b") "ibModule")))) (EApp (EVar "fresh") (EVar "known"))))) (EVar "m")) (EVar "order"))) (arm (PCon "None") () (ETuple (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "b") "ibName")) (EApp (EApp (EVar "map") (ELam ((PVar "t")) (ETuple (EVar "t") (EFieldAccess (EVar "b") "ibModule")))) (EApp (EVar "fresh") (EListLit)))) (EVar "m")) (EBinOp "::" (EFieldAccess (EVar "b") "ibName") (EVar "order"))))))))
(DTypeSig false "targetsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "NameTarget") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "NameTarget") (TyCon "String"))))))
(DFunDef false "targetsOf" ((PVar "n") (PVar "m")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "m")) (arm (PCon "Some" (PVar "ts")) () (EVar "ts")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "insertRung" (TyFun (TyCon "NameRung") (TyFun (TyApp (TyCon "OrdMap") (TyCon "NameBinding")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "NameTarget") (TyCon "String")))) (TyApp (TyCon "OrdMap") (TyCon "NameBinding"))))))
(DFunDef false "insertRung" ((PVar "rung") (PVar "m") (PTuple (PVar "n") (PVar "ts"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EApp (EVar "rungBinding") (EVar "rung")) (EVar "ts"))) (EVar "m")))
(DTypeSig false "insertImporters" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "NameTarget") (TyCon "String")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "insertImporters" ((PVar "m") (PTuple (PVar "n") (PVar "ts"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EApp (EVar "map") (EVar "snd")) (EVar "ts"))) (EVar "m")))
(DTypeSig false "rungBinding" (TyFun (TyCon "NameRung") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "NameTarget") (TyCon "String"))) (TyCon "NameBinding"))))
(DFunDef false "rungBinding" ((PVar "rung") (PList (PTuple (PVar "t") PWild))) (EApp (EApp (EVar "Bound") (EVar "rung")) (EVar "t")))
(DFunDef false "rungBinding" ((PVar "rung") (PVar "ts")) (EApp (EApp (EVar "Ambiguous") (EVar "rung")) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "ts"))))
(DTypeSig false "importClashes" (TyFun (TyApp (TyCon "OrdMap") (TyCon "NameBinding")) (TyFun (TyApp (TyCon "List") (TyCon "ImportBind")) (TyApp (TyCon "List") (TyCon "NameCollision")))))
(DFunDef false "importClashes" ((PVar "bound") (PVar "binds")) (EApp (EApp (EVar "flatMap") (ELam ((PVar "b")) (EMatch (ETuple (EFieldAccess (EVar "b") "ibRung") (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "b") "ibName")) (EVar "bound")) (EFieldAccess (EVar "b") "ibTargets")) (arm (PTuple (PCon "RungExplicit") (PCon "Some" (PCon "Bound" (PCon "RungOwn") (PVar "own"))) (PCons (PVar "t") PWild)) () (EListLit (EApp (EApp (EApp (EVar "ownClash") (EVar "b")) (EVar "own")) (EVar "t")))) (arm (PTuple (PCon "RungExplicit") (PCon "Some" (PCon "Ambiguous" (PCon "RungOwn") (PCons (PVar "own") PWild))) (PCons (PVar "t") PWild)) () (EListLit (EApp (EApp (EApp (EVar "ownClash") (EVar "b")) (EVar "own")) (EVar "t")))) (arm PWild () (EListLit))))) (EVar "binds")))
(DTypeSig false "ownClash" (TyFun (TyCon "ImportBind") (TyFun (TyCon "NameTarget") (TyFun (TyCon "NameTarget") (TyCon "NameCollision")))))
(DFunDef false "ownClash" ((PVar "b") (PVar "own") (PVar "t")) (ERecordCreate "NameCollision" ((fa "ncName" (EFieldAccess (EVar "b") "ibName")) (fa "ncFirst" (EVar "own")) (fa "ncSecond" (EVar "t")) (fa "ncRungs" (ETuple (EVar "RungOwn") (EVar "RungExplicit"))) (fa "ncLoc" (EFieldAccess (EVar "b") "ibLoc")))))
(DTypeSig false "preludeBinding" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "NameBinding")))))
(DFunDef false "preludeBinding" ((PVar "prelude") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EApp (EVar "declsByName") (EVar "prelude"))) (arm (PCon "Some" (PCons (PVar "d") PWild)) () (EBlock (DoLet false false (PVar "methods") (EApp (EVar "methodOrigins") (EVar "prelude"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EVar "Bound") (EVar "RungPrelude")) (EApp (EApp (EApp (EVar "classify") (EVar "methods")) (EVar "methods")) (EVar "d"))))))) (arm PWild () (EVar "None"))))
# MARK
(DUse false (UseAlias ("core") "$core"))
(DUse false (UseGroup ("frontend" "ast") ((mem "Decl" true) (mem "ExternDecl" true) (mem "IfaceMethod" true) (mem "LetBind" true) (mem "Loc" true) (mem "UseMember" true) (mem "UsePath" true) (mem "useMemberLocal" false) (mem "useMemberOrigin" false))))
(DUse false (UseGroup ("frontend" "visibility") ((mem "ModuleExports" false) (mem "useModId" false))))
(DUse false (UseGroup ("list") ((mem "last" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false))))
(DUse false (UseGroup ("support" "util") ((mem "dedup" false) (mem "listLen" false) (mem "reverseL" false))))
(DData Public "NameRung" () ((variant "RungOwn" (ConPos)) (variant "RungExplicit" (ConPos)) (variant "RungWild" (ConPos)) (variant "RungPrelude" (ConPos))) ())
(DImpl true "Eq" ((TyCon "NameRung")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RungOwn") (PCon "RungOwn")) () (EVar "True")) (arm (PTuple (PCon "RungExplicit") (PCon "RungExplicit")) () (EVar "True")) (arm (PTuple (PCon "RungWild") (PCon "RungWild")) () (EVar "True")) (arm (PTuple (PCon "RungPrelude") (PCon "RungPrelude")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "NameRung")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "RungOwn") () (ELit (LString "RungOwn"))) (arm (PCon "RungExplicit") () (ELit (LString "RungExplicit"))) (arm (PCon "RungWild") () (ELit (LString "RungWild"))) (arm (PCon "RungPrelude") () (ELit (LString "RungPrelude")))))))
(DData Public "NameTarget" () ((variant "TargetValue" (ConPos (TyCon "String") (TyCon "String"))) (variant "TargetMethod" (ConPos (TyCon "String") (TyCon "String") (TyCon "String")))) ())
(DImpl true "Eq" ((TyCon "NameTarget")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "TargetValue" (PVar "__a0") (PVar "__a1")) (PCon "TargetValue" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "$core.eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "$core.eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "TargetMethod" (PVar "__a0") (PVar "__a1") (PVar "__a2")) (PCon "TargetMethod" (PVar "__b0") (PVar "__b1") (PVar "__b2"))) () (EBinOp "&&" (EBinOp "&&" (EApp (EApp (EVar "$core.eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "$core.eq") (EVar "__a1")) (EVar "__b1"))) (EApp (EApp (EVar "$core.eq") (EVar "__a2")) (EVar "__b2")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "NameTarget")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "TargetValue" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "TargetValue ")) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a1"))))) (arm (PCon "TargetMethod" (PVar "__a0") (PVar "__a1") (PVar "__a2")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "TargetMethod ")) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a1")))) (ELit (LString " "))) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a2")))))))))
(DData Public "NameBinding" () ((variant "Bound" (ConPos (TyCon "NameRung") (TyCon "NameTarget"))) (variant "Ambiguous" (ConPos (TyCon "NameRung") (TyApp (TyCon "List") (TyCon "NameTarget"))))) ())
(DImpl true "Eq" ((TyCon "NameBinding")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "Bound" (PVar "__a0") (PVar "__a1")) (PCon "Bound" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "$core.eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "$core.eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple (PCon "Ambiguous" (PVar "__a0") (PVar "__a1")) (PCon "Ambiguous" (PVar "__b0") (PVar "__b1"))) () (EBinOp "&&" (EApp (EApp (EVar "$core.eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "$core.eq") (EVar "__a1")) (EVar "__b1")))) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DImpl true "Debug" ((TyCon "NameBinding")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PCon "Bound" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Bound ")) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a1"))))) (arm (PCon "Ambiguous" (PVar "__a0") (PVar "__a1")) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "Ambiguous ")) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a0")))) (ELit (LString " "))) (EApp (EVar "$core.derivedShowWrap") (EApp (EVar "$core.debug") (EVar "__a1")))))))))
(DData Public "ImportedSurface" () ((variant "ImportedSurface" (ConPos (TyCon "Decl") (TyCon "ModuleExports")))) ())
(DData Public "NameCollision" () ((variant "NameCollision" (ConNamed (field "ncName" (TyCon "String")) (field "ncFirst" (TyCon "NameTarget")) (field "ncSecond" (TyCon "NameTarget")) (field "ncRungs" (TyTuple (TyCon "NameRung") (TyCon "NameRung"))) (field "ncLoc" (TyCon "Loc"))))) ())
(DData Abstract "NameScope" () ((variant "NameScope" (ConNamed (field "scBound" (TyApp (TyCon "OrdMap") (TyCon "NameBinding"))) (field "scImporters" (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (field "scCollisions" (TyApp (TyCon "List") (TyCon "NameCollision"))) (field "scPrelude" (TyCon "ModuleExports"))))) ())
(DData Private "ImportBind" () ((variant "ImportBind" (ConNamed (field "ibName" (TyCon "String")) (field "ibRung" (TyCon "NameRung")) (field "ibTargets" (TyApp (TyCon "List") (TyCon "NameTarget"))) (field "ibLoc" (TyCon "Loc")) (field "ibModule" (TyCon "String"))))) ())
(DTypeSig true "nameScopeOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "ImportedSurface")) (TyFun (TyCon "ModuleExports") (TyCon "NameScope")))))
(DFunDef false "nameScopeOf" ((PVar "prog") (PVar "surfaces") (PVar "prelude")) (EBlock (DoLet false false (PTuple (PVar "own") (PVar "ownClashes")) (EApp (EVar "ownBindings") (EVar "prog"))) (DoLet false false (PVar "preludeMethods") (EApp (EVar "methodOrigins") (EVar "prelude"))) (DoLet false false (PVar "binds") (EApp (EApp (EDictApp "flatMap") (EApp (EVar "surfaceBinds") (EVar "preludeMethods"))) (EVar "surfaces"))) (DoLet false false (PVar "explicit") (EApp (EApp (EVar "rungTargets") (EVar "RungExplicit")) (EVar "binds"))) (DoLet false false (PVar "wild") (EApp (EApp (EVar "rungTargets") (EVar "RungWild")) (EVar "binds"))) (DoLet false false (PVar "imported") (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "insertRung") (EVar "RungExplicit"))) (EApp (EApp (EApp (EMethodRef "fold") (EApp (EVar "insertRung") (EVar "RungWild"))) (EVar "omEmpty")) (EVar "wild"))) (EVar "explicit"))) (DoLet false false (PVar "bound") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PTuple (PVar "n") (PVar "b"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "b")) (EVar "m")))) (EVar "imported")) (EVar "own"))) (DoLet false false (PVar "importers") (EApp (EApp (EApp (EMethodRef "fold") (EVar "insertImporters")) (EApp (EApp (EApp (EMethodRef "fold") (EVar "insertImporters")) (EVar "omEmpty")) (EVar "wild"))) (EVar "explicit"))) (DoExpr (ERecordCreate "NameScope" ((fa "scBound" (EVar "bound")) (fa "scImporters" (EVar "importers")) (fa "scCollisions" (EBinOp "++" (EVar "ownClashes") (EApp (EApp (EVar "importClashes") (EVar "bound")) (EVar "binds")))) (fa "scPrelude" (EVar "prelude")))))))
(DTypeSig true "bareBinding" (TyFun (TyCon "NameScope") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "NameBinding")))))
(DFunDef false "bareBinding" ((PVar "scope") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EVar "scope") "scBound")) (arm (PCon "Some" (PVar "b")) () (EApp (EVar "Some") (EVar "b"))) (arm (PCon "None") () (EApp (EApp (EVar "preludeBinding") (EFieldAccess (EVar "scope") "scPrelude")) (EVar "n")))))
(DTypeSig true "scopeCollisions" (TyFun (TyCon "NameScope") (TyApp (TyCon "List") (TyCon "NameCollision"))))
(DFunDef false "scopeCollisions" ((PVar "scope")) (EFieldAccess (EVar "scope") "scCollisions"))
(DTypeSig true "bindingImporters" (TyFun (TyCon "NameScope") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "bindingImporters" ((PVar "scope") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EVar "scope") "scBound")) (arm (PCon "Some" (PCon "Bound" (PCon "RungOwn") PWild)) () (EListLit)) (arm (PCon "Some" (PCon "Ambiguous" (PCon "RungOwn") PWild)) () (EListLit)) (arm (PCon "Some" PWild) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EVar "scope") "scImporters")) (arm (PCon "Some" (PVar "ms")) () (EVar "ms")) (arm (PCon "None") () (EListLit)))) (arm (PCon "None") () (EListLit))))
(DTypeSig false "ownBindings" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyTuple (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "NameBinding"))) (TyApp (TyCon "List") (TyCon "NameCollision")))))
(DFunDef false "ownBindings" ((PVar "prog")) (EBlock (DoLet false false (PVar "walk") (EApp (EApp (EApp (EMethodRef "fold") (EVar "ownStep")) (EVar "emptyOwnWalk")) (EApp (EApp (EDictApp "flatMap") (EVar "declBinders")) (EVar "prog")))) (DoLet false false (PVar "clashed") (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "c")) (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "c") "ncName")) (EVar "c")) (EVar "m")))) (EVar "omEmpty")) (EFieldAccess (EVar "walk") "owClashes"))) (DoLet false true (PVar "bindingOf") (ELam ((PVar "n")) (ELam ((PVar "t")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "clashed")) (arm (PCon "Some" (PVar "c")) () (ETuple (EVar "n") (EApp (EApp (EVar "Ambiguous") (EVar "RungOwn")) (EListLit (EFieldAccess (EVar "c") "ncFirst") (EFieldAccess (EVar "c") "ncSecond"))))) (arm (PCon "None") () (ETuple (EVar "n") (EApp (EApp (EVar "Bound") (EVar "RungOwn")) (EVar "t")))))))) (DoExpr (ETuple (EApp (EApp (EMethodRef "map") (ELam ((PVar "e")) (EApp (EApp (EVar "bindingOf") (EApp (EVar "fst") (EVar "e"))) (EApp (EVar "fst") (EApp (EVar "snd") (EVar "e")))))) (EApp (EVar "reverseL") (EFieldAccess (EVar "walk") "owOrder"))) (EApp (EVar "reverseL") (EFieldAccess (EVar "walk") "owClashes"))))))
(DData Private "OwnWalk" () ((variant "OwnWalk" (ConNamed (field "owFirst" (TyApp (TyCon "OrdMap") (TyTuple (TyCon "NameTarget") (TyApp (TyCon "Option") (TyCon "Loc"))))) (field "owOrder" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyTuple (TyCon "NameTarget") (TyApp (TyCon "Option") (TyCon "Loc")))))) (field "owClashes" (TyApp (TyCon "List") (TyCon "NameCollision")))))) ())
(DTypeSig false "emptyOwnWalk" (TyCon "OwnWalk"))
(DFunDef false "emptyOwnWalk" () (ERecordCreate "OwnWalk" ((fa "owFirst" (EVar "omEmpty")) (fa "owOrder" (EListLit)) (fa "owClashes" (EListLit)))))
(DTypeSig false "ownStep" (TyFun (TyCon "OwnWalk") (TyFun (TyTuple (TyCon "String") (TyCon "NameTarget") (TyApp (TyCon "Option") (TyCon "Loc"))) (TyCon "OwnWalk"))))
(DFunDef false "ownStep" ((PVar "walk") (PTuple (PVar "n") (PVar "t") (PVar "l"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EFieldAccess (EVar "walk") "owFirst")) (arm (PCon "None") () (ERecordUpdate (EVar "walk") ((fa "owFirst" (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (ETuple (EVar "t") (EVar "l"))) (EFieldAccess (EVar "walk") "owFirst"))) (fa "owOrder" (EBinOp "::" (ETuple (EVar "n") (ETuple (EVar "t") (EVar "l"))) (EFieldAccess (EVar "walk") "owOrder")))))) (arm (PCon "Some" (PTuple (PVar "first") (PVar "firstLoc"))) () (EIf (EBinOp "&&" (EBinOp "/=" (EApp (EVar "isMethod") (EVar "first")) (EApp (EVar "isMethod") (EVar "t"))) (EApp (EVar "not") (EApp (EApp (EVar "anyClash") (EVar "n")) (EFieldAccess (EVar "walk") "owClashes")))) (EBlock (DoLet false false (PVar "clash") (ERecordCreate "NameCollision" ((fa "ncName" (EVar "n")) (fa "ncFirst" (EVar "first")) (fa "ncSecond" (EVar "t")) (fa "ncRungs" (ETuple (EVar "RungOwn") (EVar "RungOwn"))) (fa "ncLoc" (EApp (EApp (EVar "locOr") (EVar "l")) (EVar "firstLoc")))))) (DoExpr (ERecordUpdate (EVar "walk") ((fa "owClashes" (EBinOp "::" (EVar "clash") (EFieldAccess (EVar "walk") "owClashes"))))))) (EVar "walk")))))
(DTypeSig false "anyClash" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "NameCollision")) (TyCon "Bool"))))
(DFunDef false "anyClash" ((PVar "n") (PVar "clashes")) (EApp (EApp (EDictApp "any") (ELam ((PVar "c")) (EBinOp "==" (EFieldAccess (EVar "c") "ncName") (EVar "n")))) (EVar "clashes")))
(DTypeSig false "isMethod" (TyFun (TyCon "NameTarget") (TyCon "Bool")))
(DFunDef false "isMethod" ((PCon "TargetMethod" PWild PWild PWild)) (EVar "True"))
(DFunDef false "isMethod" ((PCon "TargetValue" PWild PWild)) (EVar "False"))
(DTypeSig false "locOr" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "Loc"))))
(DFunDef false "locOr" ((PCon "Some" (PVar "l")) PWild) (EVar "l"))
(DFunDef false "locOr" ((PCon "None") (PCon "Some" (PVar "l"))) (EVar "l"))
(DFunDef false "locOr" ((PCon "None") (PCon "None")) (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (ELit (LString ""))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))) (ELit (LInt 0))))
(DTypeSig false "declBinders" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "NameTarget") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "declBinders" ((PCon "DFunDef" PWild (PVar "n") PWild PWild (PVar "loc") PWild)) (EListLit (EApp (EApp (EVar "ownValue") (EVar "n")) (EApp (EVar "Some") (EVar "loc")))))
(DFunDef false "declBinders" ((PCon "DTypeSig" PWild (PVar "n") PWild (PVar "loc"))) (EListLit (EApp (EApp (EVar "ownValue") (EVar "n")) (EApp (EVar "Some") (EVar "loc")))))
(DFunDef false "declBinders" ((PCon "DExtern" (PVar "ed"))) (EListLit (EApp (EApp (EVar "ownValue") (EFieldAccess (EVar "ed") "edName")) (EApp (EVar "Some") (EFieldAccess (EVar "ed") "edLoc")))))
(DFunDef false "declBinders" ((PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EMethodRef "map") (EVar "letBinder")) (EVar "binds")))
(DFunDef false "declBinders" ((PRec "DInterface" ((rf "name" (PVar "i")) (rf "methods" None) (rf "ifaceNameLoc" None)) true)) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "methodBinder") (EVar "i")) (EVar "ifaceNameLoc"))) (EVar "methods")))
(DFunDef false "declBinders" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declBinders") (EVar "d")))
(DFunDef false "declBinders" (PWild) (EListLit))
(DTypeSig false "ownValue" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyTuple (TyCon "String") (TyCon "NameTarget") (TyApp (TyCon "Option") (TyCon "Loc"))))))
(DFunDef false "ownValue" ((PVar "n") (PVar "l")) (ETuple (EVar "n") (EApp (EApp (EVar "TargetValue") (ELit (LString ""))) (EVar "n")) (EVar "l")))
(DTypeSig false "letBinder" (TyFun (TyCon "LetBind") (TyTuple (TyCon "String") (TyCon "NameTarget") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "letBinder" ((PCon "LetBind" (PVar "n") PWild (PVar "loc") PWild)) (EApp (EApp (EVar "ownValue") (EVar "n")) (EApp (EVar "Some") (EVar "loc"))))
(DTypeSig false "methodBinder" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "IfaceMethod") (TyTuple (TyCon "String") (TyCon "NameTarget") (TyApp (TyCon "Option") (TyCon "Loc")))))))
(DFunDef false "methodBinder" ((PVar "i") PWild (PCon "IfaceMethod" (PVar "m") PWild PWild (PCon "Some" (PVar "loc")))) (ETuple (EVar "m") (EApp (EApp (EApp (EVar "TargetMethod") (ELit (LString ""))) (EVar "i")) (EVar "m")) (EApp (EVar "Some") (EVar "loc"))))
(DFunDef false "methodBinder" ((PVar "i") (PVar "nameLoc") (PCon "IfaceMethod" (PVar "m") PWild PWild (PCon "None"))) (ETuple (EVar "m") (EApp (EApp (EApp (EVar "TargetMethod") (ELit (LString ""))) (EVar "i")) (EVar "m")) (EVar "nameLoc")))
(DTypeSig false "surfaceBinds" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyCon "ImportedSurface") (TyApp (TyCon "List") (TyCon "ImportBind")))))
(DFunDef false "surfaceBinds" ((PVar "preludeMethods") (PCon "ImportedSurface" (PCon "DAttrib" PWild (PVar "d")) (PVar "exp"))) (EApp (EApp (EVar "surfaceBinds") (EVar "preludeMethods")) (EApp (EApp (EVar "ImportedSurface") (EVar "d")) (EVar "exp"))))
(DFunDef false "surfaceBinds" ((PVar "preludeMethods") (PCon "ImportedSurface" (PCon "DUse" PWild (PVar "path") (PVar "useLoc")) (PVar "exp"))) (EBlock (DoLet false false (PVar "decls") (EApp (EVar "declsByName") (EVar "exp"))) (DoLet false false (PVar "methods") (EApp (EVar "methodOrigins") (EVar "exp"))) (DoLet false false (PVar "mid") (EApp (EVar "useModId") (EVar "path"))) (DoLet false true (PVar "bindAt") (ELam ((PVar "rung")) (ELam ((PVar "local")) (ELam ((PVar "origin")) (ELam ((PVar "loc")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "origin")) (EVar "decls")) (arm (PCon "Some" (PVar "ds")) () (EListLit (ERecordCreate "ImportBind" ((fa "ibName" (EVar "local")) (fa "ibRung" (EVar "rung")) (fa "ibTargets" (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "classify") (EVar "preludeMethods")) (EVar "methods"))) (EVar "ds"))) (fa "ibLoc" (EVar "loc")) (fa "ibModule" (EVar "mid")))))) (arm (PCon "None") () (EListLit)))))))) (DoExpr (EMatch (EVar "path") (arm (PCon "UseGroup" PWild (PVar "members")) () (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "m")) (EApp (EApp (EApp (EApp (EVar "bindAt") (EVar "RungExplicit")) (EApp (EVar "useMemberLocal") (EVar "m"))) (EApp (EVar "useMemberOrigin") (EVar "m"))) (EApp (EVar "memberLoc") (EVar "m"))))) (EVar "members"))) (arm (PCon "UseName" (PVar "ns")) () (EIf (EBinOp ">" (EApp (EVar "listLen") (EVar "ns")) (ELit (LInt 1))) (EBlock (DoLet false false (PVar "n") (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EVar "last") (EVar "ns")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "bindAt") (EVar "RungExplicit")) (EVar "n")) (EVar "n")) (EVar "useLoc")))) (EListLit))) (arm (PCon "UseWild" PWild) () (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "v")) (EApp (EApp (EApp (EApp (EVar "bindAt") (EVar "RungWild")) (EVar "v")) (EVar "v")) (EVar "useLoc")))) (EApp (EVar "dedup") (EFieldAccess (EVar "exp") "expValues")))) (arm (PCon "UseAlias" PWild PWild) () (EListLit))))))
(DFunDef false "surfaceBinds" (PWild PWild) (EListLit))
(DTypeSig false "memberLoc" (TyFun (TyCon "UseMember") (TyCon "Loc")))
(DFunDef false "memberLoc" ((PCon "UseMember" PWild PWild (PVar "loc") PWild)) (EVar "loc"))
(DTypeSig false "declsByName" (TyFun (TyCon "ModuleExports") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "declsByName" ((PVar "exp")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PTuple (PVar "n") (PVar "d"))) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "m")) (arm (PCon "Some" (PVar "ds")) () (EIf (EApp (EApp (EDictApp "any") (ELam ((PVar "_s")) (EBinOp "==" (EVar "_s") (EVar "d")))) (EVar "ds")) (EVar "m") (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EBinOp "++" (EVar "ds") (EListLit (EVar "d")))) (EVar "m")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EListLit (EVar "d"))) (EVar "m")))))) (EVar "omEmpty")) (EFieldAccess (EVar "exp") "expValueOrigins")))
(DTypeSig false "methodOrigins" (TyFun (TyCon "ModuleExports") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "methodOrigins" ((PVar "exp")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PTuple (PVar "i") (PVar "ms"))) (EBlock (DoLet false false (PVar "owners") (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "o")) (EBinOp "==" (EApp (EVar "fst") (EVar "o")) (EVar "i")))) (EFieldAccess (EVar "exp") "expIfaceOrigins")))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "meth")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "meth")) (EVar "acc")) (arm (PCon "Some" (PVar "ps")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "meth")) (EBinOp "++" (EVar "ps") (EApp (EApp (EMethodRef "map") (ELam ((PVar "o")) (ETuple (EVar "i") (EVar "o")))) (EVar "owners")))) (EVar "acc"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "omInsert") (EVar "meth")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "o")) (ETuple (EVar "i") (EVar "o")))) (EVar "owners"))) (EVar "acc")))))) (EVar "m")) (EVar "ms")))))) (EVar "omEmpty")) (EFieldAccess (EVar "exp") "expIfaceMethods")))
(DTypeSig false "classify" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "NameTarget")))))
(DFunDef false "classify" ((PVar "preludeMethods") (PVar "methods") (PTuple (PVar "m") (PVar "d"))) (EMatch (EApp (EApp (EApp (EVar "declaringIface") (EVar "m")) (EVar "d")) (EVar "methods")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "TargetMethod") (EVar "m")) (EVar "i")) (EVar "d"))) (arm (PCon "None") () (EApp (EApp (EVar "classifyPrelude") (EVar "preludeMethods")) (ETuple (EVar "m") (EVar "d"))))))
(DTypeSig false "classifyPrelude" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "NameTarget"))))
(DFunDef false "classifyPrelude" ((PVar "preludeMethods") (PTuple (PVar "m") (PVar "d"))) (EIf (EBinOp "==" (EVar "m") (ELit (LString "core"))) (EMatch (EApp (EApp (EApp (EVar "declaringIface") (EVar "m")) (EVar "d")) (EVar "preludeMethods")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "TargetMethod") (EVar "m")) (EVar "i")) (EVar "d"))) (arm (PCon "None") () (EApp (EApp (EVar "TargetValue") (EVar "m")) (EVar "d")))) (EIf (EVar "otherwise") (EApp (EApp (EVar "TargetValue") (EVar "m")) (EVar "d")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "declaringIface" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "declaringIface" ((PVar "m") (PVar "d") (PVar "methods")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EDictApp "find") (ELam ((PVar "p")) (EBinOp "==" (EApp (EVar "snd") (EVar "p")) (EVar "m")))) (EApp (EApp (EVar "methodsNamed") (EVar "d")) (EVar "methods")))))
(DTypeSig false "methodsNamed" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "String"))))))
(DFunDef false "methodsNamed" ((PVar "d") (PVar "methods")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "d")) (EVar "methods")) (arm (PCon "Some" (PVar "ps")) () (EVar "ps")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "rungTargets" (TyFun (TyCon "NameRung") (TyFun (TyApp (TyCon "List") (TyCon "ImportBind")) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "NameTarget") (TyCon "String"))))))))
(DFunDef false "rungTargets" ((PVar "rung") (PVar "binds")) (EBlock (DoLet false false (PTuple (PVar "m") (PVar "order")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "b")) (EIf (EBinOp "==" (EFieldAccess (EVar "b") "ibRung") (EVar "rung")) (EApp (EApp (EVar "addBind") (EVar "acc")) (EVar "b")) (EVar "acc")))) (ETuple (EVar "omEmpty") (EListLit))) (EVar "binds"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "n")) (ETuple (EVar "n") (EApp (EApp (EVar "targetsOf") (EVar "n")) (EVar "m"))))) (EApp (EVar "reverseL") (EVar "order"))))))
(DTypeSig false "addBind" (TyFun (TyTuple (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "NameTarget") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "ImportBind") (TyTuple (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "NameTarget") (TyCon "String")))) (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "addBind" ((PTuple (PVar "m") (PVar "order")) (PVar "b")) (EBlock (DoLet false true (PVar "fresh") (ELam ((PVar "known")) (EApp (EApp (EMethodRef "filter") (ELam ((PVar "t")) (EApp (EVar "not") (EApp (EApp (EDictApp "any") (ELam ((PVar "p")) (EBinOp "==" (EApp (EVar "fst") (EVar "p")) (EVar "t")))) (EVar "known"))))) (EFieldAccess (EVar "b") "ibTargets")))) (DoExpr (EMatch (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "b") "ibName")) (EVar "m")) (arm (PCon "Some" (PVar "known")) () (ETuple (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "b") "ibName")) (EBinOp "++" (EVar "known") (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (ETuple (EVar "t") (EFieldAccess (EVar "b") "ibModule")))) (EApp (EVar "fresh") (EVar "known"))))) (EVar "m")) (EVar "order"))) (arm (PCon "None") () (ETuple (EApp (EApp (EApp (EVar "omInsert") (EFieldAccess (EVar "b") "ibName")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (ETuple (EVar "t") (EFieldAccess (EVar "b") "ibModule")))) (EApp (EVar "fresh") (EListLit)))) (EVar "m")) (EBinOp "::" (EFieldAccess (EVar "b") "ibName") (EVar "order"))))))))
(DTypeSig false "targetsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "NameTarget") (TyCon "String")))) (TyApp (TyCon "List") (TyTuple (TyCon "NameTarget") (TyCon "String"))))))
(DFunDef false "targetsOf" ((PVar "n") (PVar "m")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "m")) (arm (PCon "Some" (PVar "ts")) () (EVar "ts")) (arm (PCon "None") () (EListLit))))
(DTypeSig false "insertRung" (TyFun (TyCon "NameRung") (TyFun (TyApp (TyCon "OrdMap") (TyCon "NameBinding")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "NameTarget") (TyCon "String")))) (TyApp (TyCon "OrdMap") (TyCon "NameBinding"))))))
(DFunDef false "insertRung" ((PVar "rung") (PVar "m") (PTuple (PVar "n") (PVar "ts"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EApp (EVar "rungBinding") (EVar "rung")) (EVar "ts"))) (EVar "m")))
(DTypeSig false "insertImporters" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyTuple (TyCon "NameTarget") (TyCon "String")))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "insertImporters" ((PVar "m") (PTuple (PVar "n") (PVar "ts"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EVar "ts"))) (EVar "m")))
(DTypeSig false "rungBinding" (TyFun (TyCon "NameRung") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "NameTarget") (TyCon "String"))) (TyCon "NameBinding"))))
(DFunDef false "rungBinding" ((PVar "rung") (PList (PTuple (PVar "t") PWild))) (EApp (EApp (EVar "Bound") (EVar "rung")) (EVar "t")))
(DFunDef false "rungBinding" ((PVar "rung") (PVar "ts")) (EApp (EApp (EVar "Ambiguous") (EVar "rung")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "ts"))))
(DTypeSig false "importClashes" (TyFun (TyApp (TyCon "OrdMap") (TyCon "NameBinding")) (TyFun (TyApp (TyCon "List") (TyCon "ImportBind")) (TyApp (TyCon "List") (TyCon "NameCollision")))))
(DFunDef false "importClashes" ((PVar "bound") (PVar "binds")) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "b")) (EMatch (ETuple (EFieldAccess (EVar "b") "ibRung") (EApp (EApp (EVar "omLookup") (EFieldAccess (EVar "b") "ibName")) (EVar "bound")) (EFieldAccess (EVar "b") "ibTargets")) (arm (PTuple (PCon "RungExplicit") (PCon "Some" (PCon "Bound" (PCon "RungOwn") (PVar "own"))) (PCons (PVar "t") PWild)) () (EListLit (EApp (EApp (EApp (EVar "ownClash") (EVar "b")) (EVar "own")) (EVar "t")))) (arm (PTuple (PCon "RungExplicit") (PCon "Some" (PCon "Ambiguous" (PCon "RungOwn") (PCons (PVar "own") PWild))) (PCons (PVar "t") PWild)) () (EListLit (EApp (EApp (EApp (EVar "ownClash") (EVar "b")) (EVar "own")) (EVar "t")))) (arm PWild () (EListLit))))) (EVar "binds")))
(DTypeSig false "ownClash" (TyFun (TyCon "ImportBind") (TyFun (TyCon "NameTarget") (TyFun (TyCon "NameTarget") (TyCon "NameCollision")))))
(DFunDef false "ownClash" ((PVar "b") (PVar "own") (PVar "t")) (ERecordCreate "NameCollision" ((fa "ncName" (EFieldAccess (EVar "b") "ibName")) (fa "ncFirst" (EVar "own")) (fa "ncSecond" (EVar "t")) (fa "ncRungs" (ETuple (EVar "RungOwn") (EVar "RungExplicit"))) (fa "ncLoc" (EFieldAccess (EVar "b") "ibLoc")))))
(DTypeSig false "preludeBinding" (TyFun (TyCon "ModuleExports") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyCon "NameBinding")))))
(DFunDef false "preludeBinding" ((PVar "prelude") (PVar "n")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EApp (EVar "declsByName") (EVar "prelude"))) (arm (PCon "Some" (PCons (PVar "d") PWild)) () (EBlock (DoLet false false (PVar "methods") (EApp (EVar "methodOrigins") (EVar "prelude"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EVar "Bound") (EVar "RungPrelude")) (EApp (EApp (EApp (EVar "classify") (EVar "methods")) (EVar "methods")) (EVar "d"))))))) (arm PWild () (EVar "None"))))
