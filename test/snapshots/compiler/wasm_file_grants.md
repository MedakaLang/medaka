# META
source_lines=978
stages=DESUGAR,MARK
# SOURCE
-- Wasm file-capability prerequisites on the elaborated AST, shared by the
-- native modules driver and the compiler running in the browser. The host has
-- no physical path confinement, so reachable narrow grants must be refused
-- before lowering. Entries own diagnostic presentation and output markers.

import frontend.ast.{
  Arm(..),
  Decl(..),
  DoStmt(..),
  Expr(..),
  FunClause(..),
  Guard(..),
  GuardArm(..),
  IfaceMethod(..),
  ImplMethod(..),
  LetBind(..),
  Lit(..),
  Loc,
  MethodDefault(..),
  Pat(..),
  PropParam(..),
  Ty(..),
  TyConOrigin(..),
  Route(..),
  EffAtomTy(..),
  patBoundNames,
  Variant(..),
}
import frontend.desugar.{mapChildren}
import types.typecheck.{TcDiag(..)}
import types.route_key.{evMethodRoutes}
import support.ordmap.{
  OrdMap,
  omEmpty,
  omFromNames,
  omHasKey,
  omInsert,
  omLookup,
}
import backend.wasm_emit.{
  wasmFileGrantArity,
  wasmFileGrantExterns,
  wasmGrantConfined,
  wasmFileGrantMsg,
}
import support.util.{listLen, reverseL, filterList, startsWith}
import list.{findMap}
import string.{indexOf, lastIndexOf}

-- The wasm host cannot confine a file operation to a grant, so the build refuses
-- every grant the program writes whose elements need a runtime check
-- (`wasmGrantConfined`), with one located error per call that writes one.
--
-- A grant reaches a file extern either as a term the grant pass wrote at a call
-- (the whole domain `[]`, a list of the authority's elements, or a join of those
-- with parameters) or as a grant parameter of the enclosing binding, forwarded
-- unchanged or joined.  A parameter holds only what its callers pass, so every
-- grant value a file extern receives is built from terms written at some call
-- site, and refusing each unconfinable written term refuses every unconfinable
-- grant.  A library wrapper that forwards its parameter (`io.readLines`,
-- `fs.isFile`) therefore builds, and the refusal lands where the program wrote
-- the narrow grant.  Only the declarations that survive DCE are read, so an
-- unreached library function does not refuse the program, and a grant written
-- for a callee that can reach no file extern (`fileReach`) is not a file grant
-- at all: a `Handle` constructor's authority, or a user effect's.
export
prepareWasmFileGrants : List Decl ->
  List Decl ->
  List (String, List Decl) ->
  Result (List (String, TcDiag)) (List Decl)
prepareWasmFileGrants runtimeDecls kept modules =
  let live = omFromNames (keptFunNames kept []) omEmpty
  let reach = fileReach (runtimeDecls ++ kept)
  match flatMap (m => moduleGrantDiags reach live m) modules
    [] =>
      Ok (map (mapScopedDeclBodies (scanGrantSites reach (Ref []) None)) kept)
    diags => Err diags

keptFunNames : List Decl -> List String -> List String
keptFunNames [] acc = acc
keptFunNames ((DFunDef _ n _ _ _) :: rest) acc = keptFunNames rest (n :: acc)
keptFunNames ((DAttrib _ d) :: rest) acc = keptFunNames (d :: rest) acc
keptFunNames (_ :: rest) acc = keptFunNames rest acc

-- DCE drops only plain functions, so every other declaration is read.
isLiveDecl : OrdMap Unit -> Decl -> Bool
isLiveDecl live (DFunDef _ n _ _ _) = omHasKey n live
isLiveDecl live (DAttrib _ d) = isLiveDecl live d
isLiveDecl _ _ = True

moduleGrantDiags : Reach ->
  OrdMap Unit ->
  (String, List Decl) ->
  List (String, TcDiag)
moduleGrantDiags reach live (mid, decls) =
  let sites = Ref []
  let _ =
    map
      (d =>
        if isLiveDecl live d then
          mapScopedDeclBodies (scanGrantSites reach sites None) d
        else
          d)
      decls
  map
    (site => match site
      (loc, name, es) => (
        mid,
        TcDiag "T-WASM-FILE-GRANT" 1 loc (wasmFileGrantMsg name es) None None,
      ))
    (reverseL sites.value)

-- Records each application argument that is a written grant needing a runtime
-- check, at the first location among the call's other arguments, else the
-- innermost one around the call.  A spine is read once, at its outermost
-- application, so a leading grant is not seen again from an inner one.
scanGrantSites : Reach ->
  Ref (List (Option Loc, String, List String)) ->
  Option Loc ->
  Scope ->
  Expr ->
  Expr
scanGrantSites reach sites _ bound (ELoc l e) =
  ELoc l (scanGrantSites reach sites (Some l) bound e)
scanGrantSites reach sites around bound (e@(EApp _ _)) =
  let (head, args) = appSpine e []
  match (headName head, args)
    (Some name, [grant, ELam [PWild] body]) =>
      if name == "$withFileReadBound" || name == "$withFileWriteBound" then
        let _ =
          if bodyMayReachFile
            reach
            (name == "$withFileWriteBound")
            bound
            body then match grantElems grant
            Some es =>
              if not (wasmGrantConfined None es) then
                sites :=
                  (orElse (leftLoc body) around, calleeName head, es)
                    :: sites.value
            None => ()
        -- The first pass rejects unsupported bounds before returning any tree.
        -- Accepted Wasm bounds have no runtime instruction; erase the thunk so
        -- locals and match scratch stay in their ordinary enclosing function.
        scanGrantSites reach sites around bound body
      else
        scanOrdinaryGrantSites reach sites around bound e head args
    _ => scanOrdinaryGrantSites reach sites around bound e head args

-- A partial use is saturated under `let`s binding the arguments it was given, so
-- the call inside reads as fresh names: locate it at the first bound argument.
scanGrantSites reach sites around bound (ELet site recursive pat rhs body) =
  let after = letScope False recursive pat rhs bound
  let rhs2 =
    scanGrantSites reach sites around (if recursive then after else bound) rhs
  let body2 =
    scanGrantSites reach sites (orElse (leftLoc rhs) around) after body
  ELet site recursive pat rhs2 body2
scanGrantSites reach sites around bound e =
  mapScopedChildren bound (scanGrantSites reach sites around) e

scanOrdinaryGrantSites : Reach ->
  Ref (List (Option Loc, String, List String)) ->
  Option Loc ->
  Scope ->
  Expr ->
  Expr ->
  List Expr ->
  Expr
scanOrdinaryGrantSites reach sites around bound spine head args =
  let _ =
    if mayReachFile reach bound head (listLen args) then
      let path = leafPath head args
      let values = filterList (a => isNone (grantElems a)) args
      let at = orElse (findMap leftLoc values) around
      map
        (a => match grantElems a
          Some es =>
            if wasmGrantConfined path es then
              ()
            else
              sites := (at, calleeName head, es) :: sites.value
          None => ())
        args
    else
      []
  let f = scanGrantSites reach sites around bound head
  let xs = map (scanGrantSites reach sites around bound) args
  fold EApp (keepSpineLoc spine f) xs
-- ── which callees can reach a file extern ────────────────────────────────────
-- Global bindings and methods sharing an unmangled spelling are combined:
-- every impl/default contributes edges, so that union only checks more. Local
-- occurrences must first be distinguished by their RAW names and exact scope;
-- folding a callback into a same-spelled pure global would erase its file bound.
data Reach = Reach (OrdMap Unit) (OrdMap Unit) (OrdMap Unit) (OrdMap Int)

mayReachFile : Reach -> Scope -> Expr -> Int -> Bool
mayReachFile reach bound head argc =
  callMayReachFile reach False bound head argc
    || callMayReachFile reach True bound head argc

callMayReachFile : Reach -> Bool -> Scope -> Expr -> Int -> Bool
callMayReachFile reach write bound head argc = match localHead bound head
  Some (LocalFunction ps body captured reads writes) =>
    argc > valueParamCount ps
      || localMayReachFile reach write ps body captured (if write then
        writes
      else
        reads)
  Some UnknownBinding => True
  None =>
    let (Reach defined reads writes returns) = reach
    unknownCall returns bound head argc
      || (match headName head
        Some n =>
          if n == "$withFileReadBound" || n == "$withFileWriteBound" then
            False
          else
            omHasKey n (if write then writes else reads)
              || not (omHasKey n defined)
        None => True)

-- Cache each immutable definition's proof once per label. A chain of local
-- helpers that calls each predecessor twice must not expand exponentially.
localMayReachFile : Reach ->
  Bool ->
  List Pat ->
  Expr ->
  Scope ->
  Ref (Option Bool) ->
  Bool
localMayReachFile reach write ps body captured cache = match cache.value
  Some found => found
  None =>
    let found = bodyMayReachFile reach write (addPatScope ps captured) body
    cache := Some found
    found

-- A declared bound constrains only operations of its own label. A pure
-- body, or a body using only the other label, needs no host confinement.
bodyMayReachFile : Reach -> Bool -> Scope -> Expr -> Bool
bodyMayReachFile reach write bound (e@(EApp _ _)) =
  let (head, args) = appSpine e []
  if knownNonFileCall reach write bound head (listLen args) then
    any (evalOnlyMayReachFile reach write bound) args
  else
    bodyMayReachFileChildren reach write bound e
bodyMayReachFile reach write bound e =
  bodyMayReachFileChildren reach write bound e

-- A callback body is deferred when the callee cannot invoke that label. Its
-- construction still runs: a let RHS or immediately applied lambda can read.
-- Returned-value invocation must be ruled out before trusting the callee's row.
knownNonFileCall : Reach -> Bool -> Scope -> Expr -> Int -> Bool
knownNonFileCall reach write bound head argc =
  not (callMayReachFile reach write bound head argc)

evalOnlyMayReachFile : Reach -> Bool -> Scope -> Expr -> Bool
evalOnlyMayReachFile _ _ _ (ELam _ _) = False
evalOnlyMayReachFile reach write bound (e@(EApp _ _)) =
  bodyMayReachFile reach write bound e
evalOnlyMayReachFile reach write bound e =
  let found = Ref False
  let _ =
    mapScopedChildren
      bound
      (scope child =>
        let _ =
          if evalOnlyMayReachFile reach write scope child then found := True
        child)
      e
  found.value

bodyMayReachFileChildren : Reach -> Bool -> Scope -> Expr -> Bool
bodyMayReachFileChildren reach write bound e =
  let found = Ref False
  let _ =
    mapScopedChildren
      bound
      (scope child =>
        let _ = if bodyMayReachFile reach write scope child then found := True
        child)
      e
  found.value
    || (match e
      EApp _ _ =>
        let (head, args) = appSpine e []
        callMayReachFile reach write bound head (listLen args)
      _ => False)

localHead : Scope -> Expr -> Option LocalBinding
localHead bound head = match headRawName head
  Some n => omLookup n bound
  None => None

headName : Expr -> Option String
headName e = map unmangled (headRawName e)

headRawName : Expr -> Option String
headRawName (EVar n) = Some n
headRawName (EDictAt n _) = Some n
headRawName (EMethodAt n _ ev) =
  let (_, _, route, _, _) = evMethodRoutes ev
  Some (match route
    RLocal sym _ => if sym == "" then n else sym
    _ => n)
headRawName (EVarAt n _) = Some n
headRawName (EVarId n _) = Some n
headRawName _ = None

-- Scope is threaded at each occurrence, not collected for a whole declaration:
-- a nested binder must not shadow a later, out-of-scope runtime extern call.
-- Immutable local functions retain their definition-time scope. Parameters,
-- mutable values and recursive references remain unknown; a same-spelled global
-- therefore never supplies a local callback's proof.
data LocalBinding =
  | UnknownBinding
  | LocalFunction (List Pat) Expr (OrdMap LocalBinding) (Ref (Option Bool)) (Ref (Option Bool))
type Scope = OrdMap LocalBinding

localBinding : List Pat -> Expr -> Scope -> LocalBinding
localBinding ps body captured =
  LocalFunction ps body captured (Ref None) (Ref None)

addNamesScope : List String -> Scope -> Scope
addNamesScope names bound =
  fold (m n => omInsert n UnknownBinding m) bound names

addPatScope : List Pat -> Scope -> Scope
addPatScope ps bound = addNamesScope (flatMap patBoundNames ps) bound

letScope : Bool -> Bool -> Pat -> Expr -> Scope -> Scope
letScope False recursive (PVar n _) rhs bound =
  let captured = if recursive then addNamesScope [n] bound else bound
  match localFunction captured rhs
    Some binding => omInsert n binding bound
    None => addNamesScope [n] bound
letScope _ _ pat _ bound = addPatScope [pat] bound

localFunction : Scope -> Expr -> Option LocalBinding
localFunction bound (ELoc _ e) = localFunction bound e
localFunction bound (EAnnot e _) = localFunction bound e
localFunction bound (EHeadAnnot e _) = localFunction bound e
localFunction bound (ELet _ False pat rhs body) =
  -- Grant saturation evaluates supplied arguments before constructing its eta
  -- closure. Keep those binders in the closure's scope; the caller also scans
  -- the construction RHS, including any eager file operations.
  localFunction (letScope False False pat rhs bound) body
localFunction bound (ELam ps body) = Some (localBinding ps body bound)
localFunction _ _ = None

localGroupScope : List LetBind -> Scope -> Scope
localGroupScope binds bound =
  let captured =
    addNamesScope
      (map
        (b => match b
          LetBind n _ _ => n)
        binds)
      bound
  fold
    (m b => match b
      LetBind n [FunClause ps body] _ =>
        omInsert n (localBinding ps body captured) m
      LetBind _ _ _ => m)
    captured
    binds

mapScopedDeclBodies : (Scope -> Expr -> Expr) -> Decl -> Decl
mapScopedDeclBodies f (DFunDef pub n ps body site) =
  DFunDef pub n ps (f (addPatScope ps omEmpty) body) site
mapScopedDeclBodies f (DLetGroup pub binds) =
  DLetGroup pub (map (mapScopedLetBind f omEmpty) binds)
mapScopedDeclBodies f (d@(DImpl { methods, ... })) = DImpl { d |
  methods =
    map
      (m => match m
        ImplMethod n ps body =>
          ImplMethod n ps (f (addPatScope ps omEmpty) body))
      methods,
}
mapScopedDeclBodies f (d@(DInterface { methods, ... })) = DInterface { d |
  methods =
    map
      (m => match m
        IfaceMethod n ty def loc =>
          IfaceMethod
            n
            ty
            (map
              (dm => match dm
                MethodDefault ps body =>
                  MethodDefault ps (f (addPatScope ps omEmpty) body))
              def)
            loc)
      methods,
}
mapScopedDeclBodies f (DProp pub n params body) =
  let bound =
    addNamesScope
      (map
        (p => match p
          PropParam name _ _ => name)
        params)
      omEmpty
  DProp pub n params (f bound body)
mapScopedDeclBodies f (DTest pub n body) = DTest pub n (f omEmpty body)
mapScopedDeclBodies f (DAttrib attrs d) =
  DAttrib attrs (mapScopedDeclBodies f d)
mapScopedDeclBodies _ d = d

mapScopedLetBind : (Scope -> Expr -> Expr) -> Scope -> LetBind -> LetBind
mapScopedLetBind f bound (LetBind n clauses site) =
  LetBind
    n
    (map
      (c => match c
        FunClause ps body => FunClause ps (f (addPatScope ps bound) body))
      clauses)
    site

mapScopedChildren : Scope -> (Scope -> Expr -> Expr) -> Expr -> Expr
mapScopedChildren bound f (ELam ps body) =
  ELam ps (f (addPatScope ps bound) body)
mapScopedChildren bound f (ELet site recursive pat rhs body) =
  let after = letScope False recursive pat rhs bound
  ELet
    site
    recursive
    pat
    (f (if recursive then after else bound) rhs)
    (f after body)
mapScopedChildren bound f (ELetGroup binds body) =
  let after = localGroupScope binds bound
  ELetGroup (map (mapScopedLetBind f after) binds) (f after body)
mapScopedChildren bound f (EMatch e arms) =
  EMatch
    (f bound e)
    (map
      (a => match a
        Arm pat guards body =>
          let (guards2, after) =
            mapScopedGuards f (addPatScope [pat] bound) guards
          Arm pat guards2 (f after body))
      arms)
mapScopedChildren bound f (EGuards arms) =
  EGuards
    (map
      (a => match a
        GuardArm guards body =>
          let (guards2, after) = mapScopedGuards f bound guards
          GuardArm guards2 (f after body))
      arms)
mapScopedChildren bound f (EBlock stmts) = EBlock (mapScopedStmts f bound stmts)
mapScopedChildren bound f (EDo label stmts) =
  EDo label (mapScopedStmts f bound stmts)
mapScopedChildren bound f e = mapChildren (f bound) e

mapScopedGuards : (Scope -> Expr -> Expr) ->
  Scope ->
  List Guard ->
  (List Guard, Scope)
mapScopedGuards _ bound [] = ([], bound)
mapScopedGuards f bound ((GBool e) :: rest) =
  let e2 = f bound e
  let (rest2, after) = mapScopedGuards f bound rest
  (GBool e2 :: rest2, after)
mapScopedGuards f bound ((GBind pat e) :: rest) =
  let e2 = f bound e
  let (rest2, after) = mapScopedGuards f (addPatScope [pat] bound) rest
  (GBind pat e2 :: rest2, after)

mapScopedStmts : (Scope -> Expr -> Expr) -> Scope -> List DoStmt -> List DoStmt
mapScopedStmts _ _ [] = []
mapScopedStmts f bound ((DoExpr e) :: rest) =
  DoExpr (f bound e) :: mapScopedStmts f bound rest
mapScopedStmts f bound ((DoBind pat e) :: rest) =
  DoBind pat (f bound e) :: mapScopedStmts f (addPatScope [pat] bound) rest
mapScopedStmts f bound ((DoLet mutable recursive pat e site) :: rest) =
  let after = letScope mutable recursive pat e bound
  DoLet mutable recursive pat (f (if recursive then after else bound) e) site
    :: mapScopedStmts f after rest
mapScopedStmts f bound ((DoAssign n e) :: rest) =
  DoAssign n (f bound e) :: mapScopedStmts f bound rest
mapScopedStmts f bound ((DoFieldAssign n fields e) :: rest) =
  DoFieldAssign n fields (f bound e) :: mapScopedStmts f bound rest

fileReach : List Decl -> Reach
fileReach decls =
  let bindings = flatMap declBindingBodies decls
  let aliases = omFromNames (flatMap aliasNames decls) omEmpty
  let noRead = declaredNoFile aliases False decls bindings
  let noWrite = declaredNoFile aliases True decls bindings
  -- A closed contract covers every result arrow, including a returned function.
  -- Scalar returns through authority parameters must not seed callback reach.
  let returns =
    returnedBoundaries
      (filterList
        ((n, _, _) =>
          not
            (optionOr False (omLookup (unmangled n) noRead)
              && optionOr False (omLookup (unmangled n) noWrite)))
        bindings)
  let users = Ref omEmpty
  let defined = Ref omEmpty
  let _ = map (d => declDefines defined d) decls
  let _ =
    map ((n, ps, body) => bindingRefs users defined returns n ps body) bindings
  let reads = ["readFile", "fileExists", "canonicalizePath", "readFileBytes"]
  let writes = ["writeFileBytes"]
  Reach
    (omFromNames (map fst wasmFileGrantExterns) defined.value)
    (spread users.value noRead reads (omFromNames reads omEmpty))
    (spread users.value noWrite writes (omFromNames writes omEmpty))
    returns

-- A boundary counts arguments consumed BEFORE a returned lexical value is
-- invoked, rather than counting every arrow in its declared type. Dictionary
-- evidence travels in the head; grant parameters remain ordinary EApp args.
unknownCall : OrdMap Int -> Scope -> Expr -> Int -> Bool
unknownCall returns bound head argc = match localHead bound head
  Some (LocalFunction ps _ _ _ _) => argc > valueParamCount ps
  Some UnknownBinding => True
  None => match headRawName head
    Some n => match omLookup n returns
      Some boundary => argc > boundary
      None => False
    None => True

valueParamCount : List Pat -> Int
valueParamCount ((PVar n _) :: rest)
  | startsWith "$dict" n = valueParamCount rest
valueParamCount ps = listLen ps

declBindingBodies : Decl -> List (String, List Pat, Expr)
declBindingBodies (DFunDef _ n ps body _) = [(n, ps, body)]
declBindingBodies (DLetGroup _ binds) = flatMap letBindBodies binds
declBindingBodies (DImpl { methods, ... }) =
  map
    (m => match m
      ImplMethod n ps body => (n, ps, body))
    methods
declBindingBodies (DInterface { methods, ... }) =
  flatMap
    (m => match m
      IfaceMethod n _ (Some (MethodDefault ps body)) _ => [(n, ps, body)]
      IfaceMethod _ _ None _ => [])
    methods
declBindingBodies (DAttrib _ d) = declBindingBodies d
declBindingBodies _ = []

letBindBodies : LetBind -> List (String, List Pat, Expr)
letBindBodies (LetBind n clauses _) =
  map
    (c => match c
      FunClause ps body => (n, ps, body))
    clauses

-- Each tail reference gives a reverse dependency (owner, consumed args, supplied
-- args). Relax only decreased boundaries, including recursive aliases; a name
-- collision takes the minimum, so it cannot conceal a callback invocation.
-- Keep resolved global symbols intact: a standalone authority-polymorphic `sub`
-- has a different argument boundary from the unrelated prelude `sub` method.
returnedBoundaries : List (String, List Pat, Expr) -> OrdMap Int
returnedBoundaries bindings =
  let seeds = Ref []
  let deps = Ref omEmpty
  let _ =
    map
      ((n, ps, body) =>
        tailReturns
          seeds
          deps
          n
          (valueParamCount ps)
          (addPatScope ps omEmpty)
          body)
      bindings
  relaxReturns deps.value seeds.value omEmpty

relaxReturns : OrdMap (List (String, Int, Int)) ->
  List (String, Int) ->
  OrdMap Int ->
  OrdMap Int
relaxReturns _ [] seen = seen
relaxReturns deps ((n, boundary) :: rest) seen =
  let settled = match omLookup n seen
    Some old => old <= boundary
    None => False
  if settled then
    relaxReturns deps rest seen
  else
    let next =
      map
        ((owner, base, supplied) => (owner, base + max 0 (boundary - supplied)))
        (optionOr [] (omLookup n deps))
    relaxReturns deps (next ++ rest) (omInsert n boundary seen)

tailReturns : Ref (List (String, Int)) ->
  Ref (OrdMap (List (String, Int, Int))) ->
  String ->
  Int ->
  Scope ->
  Expr ->
  Unit
tailReturns seeds deps owner base bound (ELoc _ e) =
  tailReturns seeds deps owner base bound e
tailReturns seeds deps owner base bound (EAnnot e _) =
  tailReturns seeds deps owner base bound e
tailReturns seeds deps owner base bound (EHeadAnnot e _) =
  tailReturns seeds deps owner base bound e
tailReturns seeds deps owner base bound (EDoOrigin _ e) =
  tailReturns seeds deps owner base bound e
tailReturns seeds deps owner base bound (ELam ps body) =
  tailReturns
    seeds
    deps
    owner
    (base + valueParamCount ps)
    (addPatScope ps bound)
    body
tailReturns seeds deps owner base bound (ELet _ _ pat _ body) =
  tailReturns seeds deps owner base (addPatScope [pat] bound) body
tailReturns seeds deps owner base bound (ELetGroup binds body) =
  let after =
    addNamesScope
      (map
        (b => match b
          LetBind n _ _ => n)
        binds)
      bound
  tailReturns seeds deps owner base after body
tailReturns seeds deps owner base bound (EIf _ yes no) =
  tailReturns seeds deps owner base bound yes
  tailReturns seeds deps owner base bound no
tailReturns seeds deps owner base bound (EMatch _ arms) =
  let _ =
    map
      (a => match a
        Arm pat guards body =>
          tailReturns
            seeds
            deps
            owner
            base
            (guardScope guards (addPatScope [pat] bound))
            body)
      arms
  ()
tailReturns seeds deps owner base bound (EGuards arms) =
  let _ =
    map
      (a => match a
        GuardArm guards body =>
          tailReturns seeds deps owner base (guardScope guards bound) body)
      arms
  ()
tailReturns seeds deps owner base bound (EBlock stmts) =
  tailStmtReturns seeds deps owner base bound stmts
tailReturns seeds deps owner base bound (EDo _ stmts) =
  tailStmtReturns seeds deps owner base bound stmts
tailReturns seeds deps owner base bound e =
  let (head, args) = appSpine e []
  match (headName head, args)
    (Some n, [_, ELam [PWild] body]) if n == "$withFileReadBound"
      || n == "$withFileWriteBound" =>
      tailReturns seeds deps owner base bound body
    _ => match headRawName head
      Some raw =>
        if omHasKey raw bound then
          seeds := (owner, base) :: seeds.value
        else
          deps :=
            omInsert
              raw
              ((owner, base, listLen args)
                :: optionOr [] (omLookup raw deps.value))
              deps.value
      None => match e
        ELit _ => ()
        ETuple _ => ()
        EListLit _ => ()
        EArrayLit _ => ()
        ERecordCreate _ _ => ()
        _ => seeds := (owner, base) :: seeds.value

guardScope : List Guard -> Scope -> Scope
guardScope [] bound = bound
guardScope ((GBind pat _) :: rest) bound =
  guardScope rest (addPatScope [pat] bound)
guardScope (_ :: rest) bound = guardScope rest bound

tailStmtReturns : Ref (List (String, Int)) ->
  Ref (OrdMap (List (String, Int, Int))) ->
  String ->
  Int ->
  Scope ->
  List DoStmt ->
  Unit
tailStmtReturns seeds deps owner base bound [DoExpr e] =
  tailReturns seeds deps owner base bound e
tailStmtReturns seeds deps owner base bound ((DoBind pat _) :: rest) =
  tailStmtReturns seeds deps owner base (addPatScope [pat] bound) rest
tailStmtReturns seeds deps owner base bound ((DoLet _ _ pat _ _) :: rest) =
  tailStmtReturns seeds deps owner base (addPatScope [pat] bound) rest
tailStmtReturns seeds deps owner base bound (_ :: rest) =
  tailStmtReturns seeds deps owner base bound rest
tailStmtReturns _ _ _ _ _ [] = ()

-- Closed declared rows can prove one label absent even in a higher-order body.
-- This stops a pure `length` from inheriting fold's unknown callback, and stops
-- a write-only callback from requiring a read guard. Aliases stay unproven here;
-- treating an opaque alias as a pure scalar could hide an IO function type.
aliasNames : Decl -> List String
aliasNames (DTypeAlias { tyAliasName = n }) = [n, unmangled n]
aliasNames (DAttrib _ d) = aliasNames d
aliasNames _ = []

declaredNoFile : OrdMap Unit ->
  Bool ->
  List Decl ->
  List (String, List Pat, Expr) ->
  OrdMap Bool
declaredNoFile aliases write decls bindings =
  let ordinary = fold (signatureNoFile aliases write) omEmpty decls
  let methods = fold (methodNoFile aliases write) omEmpty decls
  let results = Ref omEmpty
  let _ = map (d => bindingNoFile ordinary methods results d) decls
  -- Every colliding binding must have a proof. Missing signatures/defaults
  -- therefore cannot acquire another binding's pure contract by spelling.
  fold
    (m (n, _, _) =>
      let name = unmangled n
      omInsert name (optionOr False (omLookup name results.value)) m)
    omEmpty
    bindings

putNoFile : String -> Bool -> OrdMap Bool -> OrdMap Bool
putNoFile n proof m = omInsert n (proof && optionOr True (omLookup n m)) m

signatureNoFile : OrdMap Unit -> Bool -> OrdMap Bool -> Decl -> OrdMap Bool
signatureNoFile aliases write m (DTypeSig _ n ty) =
  putNoFile n (tyNoFile aliases write ty) m
signatureNoFile aliases write m (DAttrib _ d) =
  signatureNoFile aliases write m d
signatureNoFile _ _ m _ = m

methodNoFile : OrdMap Unit -> Bool -> OrdMap Bool -> Decl -> OrdMap Bool
methodNoFile aliases write m (DInterface { methods, ... }) =
  fold
    (acc method => match method
      IfaceMethod n ty _ _ =>
        putNoFile (unmangled n) (tyNoFile aliases write ty) acc)
    m
    methods
methodNoFile aliases write m (DAttrib _ d) = methodNoFile aliases write m d
methodNoFile _ _ m _ = m

bindingNoFile : OrdMap Bool -> OrdMap Bool -> Ref (OrdMap Bool) -> Decl -> Unit
bindingNoFile ordinary _ results (DFunDef _ n _ _ _) =
  results :=
    putNoFile (unmangled n) (optionOr False (omLookup n ordinary)) results.value
bindingNoFile ordinary _ results (DLetGroup _ binds) =
  let _ =
    map
      (b => match b
        LetBind n _ _ =>
          results :=
            putNoFile
              (unmangled n)
              (optionOr False (omLookup n ordinary))
              results.value)
      binds
  ()
bindingNoFile _ methods results (DImpl { methods = bodies, ... }) =
  let _ =
    map
      (b => match b
        ImplMethod n _ _ =>
          results :=
            putNoFile
              (unmangled n)
              (optionOr False (omLookup (unmangled n) methods))
              results.value)
      bodies
  ()
bindingNoFile _ methods results (DInterface { methods = bodies, ... }) =
  let _ =
    map
      (b => match b
        IfaceMethod n _ (Some _) _ =>
          results :=
            putNoFile
              (unmangled n)
              (optionOr False (omLookup (unmangled n) methods))
              results.value
        IfaceMethod _ _ None _ => ())
      bodies
  ()
bindingNoFile ordinary methods results (DAttrib _ d) =
  bindingNoFile ordinary methods results d
bindingNoFile _ _ _ _ = ()

tyNoFile : OrdMap Unit -> Bool -> Ty -> Bool
tyNoFile aliases write (TyConstrained _ ty) = tyNoFile aliases write ty
tyNoFile aliases write (TyNamed _ ty _) = tyNoFile aliases write ty
tyNoFile aliases write (TyQual ty _ _) = tyNoFile aliases write ty
tyNoFile aliases write (TyEffect atoms tails ty) =
  isEmpty tails && all (atomNoFile write) atoms && tyNoFile aliases write ty
tyNoFile aliases write (TyFun _ result) = tyNoFile aliases write result
tyNoFile aliases _ (TyCon { tyConName = n }) =
  not (omHasKey n aliases || omHasKey (unmangled n) aliases)
tyNoFile aliases write (TyApp head _) = tyNoFile aliases write head
tyNoFile _ _ (TyTuple _) = True
tyNoFile _ _ _ = False

atomNoFile : Bool -> EffAtomTy -> Bool
atomNoFile write (EffAtomTy { eatLabel = label, eatOrigin = OriginBuiltin }) =
  label /= "IO" && label /= (if write then "FileWrite" else "FileRead")
atomNoFile _ (EffAtomTy { eatOrigin = (OriginModule _) }) = True
atomNoFile _ _ = False

-- Breadth-first over "is referenced by", stopping at a closed contract that
-- proves this operation's label absent. Callback-return boundaries are checked
-- separately at the application, before consulting these reachability sets.
spread : OrdMap (List String) ->
  OrdMap Bool ->
  List String ->
  OrdMap Unit ->
  OrdMap Unit
spread _ _ [] seen = seen
spread users noFile (n :: rest) seen =
  let fresh =
    filterList
      (u => not (omHasKey u seen) && not (optionOr False (omLookup u noFile)))
      (optionOr [] (omLookup n users))
  spread users noFile (fresh ++ rest) (omFromNames fresh seen)

declDefines : Ref (OrdMap Unit) -> Decl -> Unit
declDefines defined (DExtern _ n _) =
  defined := omInsert (unmangled n) () defined.value
declDefines defined (DData { dataCtors, ... }) =
  defined :=
    omFromNames
      (map
        (v => match v
          Variant n _ => unmangled n)
        dataCtors)
      defined.value
declDefines defined (DNewtype { newtypeCtor, ... }) =
  defined := omInsert (unmangled newtypeCtor) () defined.value
declDefines defined (DAttrib _ d) = declDefines defined d
declDefines _ _ = ()

-- Attribute unknown calls to their global owner, not to a same-spelled
-- global callee. Plain local value references are not file operations: treating
-- them as such would make scalar methods such as `fromInt` reach both labels.
bindingRefs : Ref (OrdMap (List String)) ->
  Ref (OrdMap Unit) ->
  OrdMap Int ->
  String ->
  List Pat ->
  Expr ->
  Unit
bindingRefs users defined returns b ps body =
  let name = unmangled b
  let refs = Ref []
  let _ = collectRefs returns refs (addPatScope ps omEmpty) body
  defined := omInsert name () defined.value
  users :=
    fold
      (m r => omInsert r (name :: optionOr [] (omLookup r m)) m)
      users.value
      refs.value

collectRefs : OrdMap Int -> Ref (List String) -> Scope -> Expr -> Expr
collectRefs returns refs bound (e@(EApp _ _)) =
  let (head, args) = appSpine e []
  let _ =
    if unknownCall returns bound head (listLen args) then
      refs := "readFile" :: "writeFileBytes" :: refs.value
  let _ = match localHead bound head
    -- Every local definition's body is already visited by the lexical walk.
    -- Re-expanding it here would duplicate its edges at every local call.
    Some (LocalFunction _ _ _ _ _) => ()
    _ =>
      let _ = collectRefs returns refs bound head
      ()
  let _ = map (collectRefs returns refs bound) args
  e
collectRefs returns refs bound e = match headRawName e
  Some n =>
    let _ = if not (omHasKey n bound) then refs := unmangled n :: refs.value
    e
  None => mapScopedChildren bound (collectRefs returns refs) e

-- The location the call's spine started with, which `appSpine` drops, put back
-- on the rebuilt head: a trap site reads the start of a call.
keepSpineLoc : Expr -> Expr -> Expr
keepSpineLoc spine head = match spineLoc spine
  Some l => ELoc l head
  None => head

spineLoc : Expr -> Option Loc
spineLoc (EApp f _) = spineLoc f
spineLoc (ELoc l _) = Some l
spineLoc _ = None

appSpine : Expr -> List Expr -> (Expr, List Expr)
appSpine (EApp f x) args = appSpine f (x :: args)
appSpine (ELoc _ f) args = appSpine f args
appSpine h args = (h, args)

-- The elements a written grant term names: a list the grant pass built, whose
-- elements are bare string literals (a list in source carries a location on
-- each element), or a join of such lists with grant parameters, possibly under
-- the match that lets a whole-domain parameter absorb the join.  None for any
-- other term, a grant parameter alone included.
grantElems : Expr -> Option (List String)
grantElems (EListLit (es@(_ :: _))) = bareStrings es []
grantElems (EBinOp "++" a b _) = match (grantElems a, grantElems b)
  (None, None) => None
  (x, y) => Some (optionOr [] x ++ optionOr [] y)
grantElems (EMatch (EVar _) [_, Arm PWild [] j]) = grantElems j
grantElems _ = None

bareStrings : List Expr -> List String -> Option (List String)
bareStrings [] acc = Some (reverseL acc)
bareStrings ((ELit (LString s)) :: rest) acc = bareStrings rest (s :: acc)
bareStrings _ _ = None

-- A file extern's literal path, when the spine is a saturated file extern call.
leafPath : Expr -> List Expr -> Option String
leafPath (EVar n) (p :: rest) = match wasmFileGrantArity n
  Some arity => if listLen rest == arity then pathLit p else None
  None => None
leafPath _ _ = None

pathLit : Expr -> Option String
pathLit (ELoc _ e) = pathLit e
pathLit (ELit (LString s)) = Some s
pathLit _ = None

-- The callee as the program spells it, without the module prefix mangling adds
-- or the `$` suffix a renamed local carries.
calleeName : Expr -> String
calleeName (EVar "$withFileReadBound") = "declared FileRead bound"
calleeName (EVar "$withFileWriteBound") = "declared FileWrite bound"
calleeName (EVar n) = unmangled n
calleeName (EDictAt n _) = unmangled n
calleeName (EMethodAt n _ _) = unmangled n
calleeName _ = "this call"

unmangled : String -> String
unmangled n =
  let bare = match lastIndexOf "__" n
    Some i => stringSlice (i + 2) (stringLength n) n
    None => n
  match indexOf "$" bare
    Some i => if i > 0 then stringSlice 0 i bare else bare
    None => bare

-- The leftmost location inside an expression, which is where its source text starts.
leftLoc : Expr -> Option Loc
leftLoc (ELoc l _) = Some l
leftLoc (EApp f x) = orElse (leftLoc f) (leftLoc x)
leftLoc (EBinOp _ a b _) = orElse (leftLoc a) (leftLoc b)
leftLoc e =
  let found = Ref None
  let _ =
    mapChildren
      (child =>
        let _ = match found.value
          None => found := leftLoc child
          Some _ => ()
        child)
      e
  found.value
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" true) (mem "DoStmt" true) (mem "Expr" true) (mem "FunClause" true) (mem "Guard" true) (mem "GuardArm" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "LetBind" true) (mem "Lit" true) (mem "Loc" false) (mem "MethodDefault" true) (mem "Pat" true) (mem "PropParam" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "Route" true) (mem "EffAtomTy" true) (mem "patBoundNames" false) (mem "Variant" true))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "mapChildren" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "TcDiag" true))))
(DUse false (UseGroup ("types" "route_key") ((mem "evMethodRoutes" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false))))
(DUse false (UseGroup ("backend" "wasm_emit") ((mem "wasmFileGrantArity" false) (mem "wasmFileGrantExterns" false) (mem "wasmGrantConfined" false) (mem "wasmFileGrantMsg" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "reverseL" false) (mem "filterList" false) (mem "startsWith" false))))
(DUse false (UseGroup ("list") ((mem "findMap" false))))
(DUse false (UseGroup ("string") ((mem "indexOf" false) (mem "lastIndexOf" false))))
(DTypeSig true "prepareWasmFileGrants" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "prepareWasmFileGrants" ((PVar "runtimeDecls") (PVar "kept") (PVar "modules")) (EBlock (DoLet false false (PVar "live") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "keptFunNames") (EVar "kept")) (EListLit))) (EVar "omEmpty"))) (DoLet false false (PVar "reach") (EApp (EVar "fileReach") (EBinOp "++" (EVar "runtimeDecls") (EVar "kept")))) (DoExpr (EMatch (EApp (EApp (EVar "flatMap") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "moduleGrantDiags") (EVar "reach")) (EVar "live")) (EVar "m")))) (EVar "modules")) (arm (PList) () (EApp (EVar "Ok") (EApp (EApp (EVar "map") (EApp (EVar "mapScopedDeclBodies") (EApp (EApp (EApp (EVar "scanGrantSites") (EVar "reach")) (EApp (EVar "Ref") (EListLit))) (EVar "None")))) (EVar "kept")))) (arm (PVar "diags") () (EApp (EVar "Err") (EVar "diags")))))))
(DTypeSig false "keptFunNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "keptFunNames" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "keptFunNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "keptFunNames") (EVar "rest")) (EBinOp "::" (EVar "n") (EVar "acc"))))
(DFunDef false "keptFunNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "keptFunNames") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "keptFunNames" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "keptFunNames") (EVar "rest")) (EVar "acc")))
(DTypeSig false "isLiveDecl" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Decl") (TyCon "Bool"))))
(DFunDef false "isLiveDecl" ((PVar "live") (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild)) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "live")))
(DFunDef false "isLiveDecl" ((PVar "live") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "isLiveDecl") (EVar "live")) (EVar "d")))
(DFunDef false "isLiveDecl" (PWild PWild) (EVar "True"))
(DTypeSig false "moduleGrantDiags" (TyFun (TyCon "Reach") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))))))
(DFunDef false "moduleGrantDiags" ((PVar "reach") (PVar "live") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "sites") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EIf (EApp (EApp (EVar "isLiveDecl") (EVar "live")) (EVar "d")) (EApp (EApp (EVar "mapScopedDeclBodies") (EApp (EApp (EApp (EVar "scanGrantSites") (EVar "reach")) (EVar "sites")) (EVar "None"))) (EVar "d")) (EVar "d")))) (EVar "decls"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "site")) (EMatch (EVar "site") (arm (PTuple (PVar "loc") (PVar "name") (PVar "es")) () (ETuple (EVar "mid") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "T-WASM-FILE-GRANT"))) (ELit (LInt 1))) (EVar "loc")) (EApp (EApp (EVar "wasmFileGrantMsg") (EVar "name")) (EVar "es"))) (EVar "None")) (EVar "None"))))))) (EApp (EVar "reverseL") (EFieldAccess (EVar "sites") "value"))))))
(DTypeSig false "scanGrantSites" (TyFun (TyCon "Reach") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Expr")))))))
(DFunDef false "scanGrantSites" ((PVar "reach") (PVar "sites") PWild (PVar "bound") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EApp (EApp (EApp (EVar "scanGrantSites") (EVar "reach")) (EVar "sites")) (EApp (EVar "Some") (EVar "l"))) (EVar "bound")) (EVar "e"))))
(DFunDef false "scanGrantSites" ((PVar "reach") (PVar "sites") (PVar "around") (PVar "bound") (PAs "e" (PCon "EApp" PWild PWild))) (EBlock (DoLet false false (PTuple (PVar "head") (PVar "args")) (EApp (EApp (EVar "appSpine") (EVar "e")) (EListLit))) (DoExpr (EMatch (ETuple (EApp (EVar "headName") (EVar "head")) (EVar "args")) (arm (PTuple (PCon "Some" (PVar "name")) (PList (PVar "grant") (PCon "ELam" (PList (PCon "PWild")) (PVar "body")))) () (EIf (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "$withFileReadBound"))) (EBinOp "==" (EVar "name") (ELit (LString "$withFileWriteBound")))) (EBlock (DoLet false false PWild (EIf (EApp (EApp (EApp (EApp (EVar "bodyMayReachFile") (EVar "reach")) (EBinOp "==" (EVar "name") (ELit (LString "$withFileWriteBound")))) (EVar "bound")) (EVar "body")) (EMatch (EApp (EVar "grantElems") (EVar "grant")) (arm (PCon "Some" (PVar "es")) () (EIf (EApp (EVar "not") (EApp (EApp (EVar "wasmGrantConfined") (EVar "None")) (EVar "es"))) (EApp (EApp (EVar "setRef") (EVar "sites")) (EBinOp "::" (ETuple (EApp (EApp (EVar "orElse") (EApp (EVar "leftLoc") (EVar "body"))) (EVar "around")) (EApp (EVar "calleeName") (EVar "head")) (EVar "es")) (EFieldAccess (EVar "sites") "value"))) (ELit LUnit))) (arm (PCon "None") () (ELit LUnit))) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "scanGrantSites") (EVar "reach")) (EVar "sites")) (EVar "around")) (EVar "bound")) (EVar "body")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanOrdinaryGrantSites") (EVar "reach")) (EVar "sites")) (EVar "around")) (EVar "bound")) (EVar "e")) (EVar "head")) (EVar "args")))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanOrdinaryGrantSites") (EVar "reach")) (EVar "sites")) (EVar "around")) (EVar "bound")) (EVar "e")) (EVar "head")) (EVar "args")))))))
(DFunDef false "scanGrantSites" ((PVar "reach") (PVar "sites") (PVar "around") (PVar "bound") (PCon "ELet" (PVar "site") (PVar "recursive") (PVar "pat") (PVar "rhs") (PVar "body"))) (EBlock (DoLet false false (PVar "after") (EApp (EApp (EApp (EApp (EApp (EVar "letScope") (EVar "False")) (EVar "recursive")) (EVar "pat")) (EVar "rhs")) (EVar "bound"))) (DoLet false false (PVar "rhs2") (EApp (EApp (EApp (EApp (EApp (EVar "scanGrantSites") (EVar "reach")) (EVar "sites")) (EVar "around")) (EIf (EVar "recursive") (EVar "after") (EVar "bound"))) (EVar "rhs"))) (DoLet false false (PVar "body2") (EApp (EApp (EApp (EApp (EApp (EVar "scanGrantSites") (EVar "reach")) (EVar "sites")) (EApp (EApp (EVar "orElse") (EApp (EVar "leftLoc") (EVar "rhs"))) (EVar "around"))) (EVar "after")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "site")) (EVar "recursive")) (EVar "pat")) (EVar "rhs2")) (EVar "body2")))))
(DFunDef false "scanGrantSites" ((PVar "reach") (PVar "sites") (PVar "around") (PVar "bound") (PVar "e")) (EApp (EApp (EApp (EVar "mapScopedChildren") (EVar "bound")) (EApp (EApp (EApp (EVar "scanGrantSites") (EVar "reach")) (EVar "sites")) (EVar "around"))) (EVar "e")))
(DTypeSig false "scanOrdinaryGrantSites" (TyFun (TyCon "Reach") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr")))))))))
(DFunDef false "scanOrdinaryGrantSites" ((PVar "reach") (PVar "sites") (PVar "around") (PVar "bound") (PVar "spine") (PVar "head") (PVar "args")) (EBlock (DoLet false false PWild (EIf (EApp (EApp (EApp (EApp (EVar "mayReachFile") (EVar "reach")) (EVar "bound")) (EVar "head")) (EApp (EVar "listLen") (EVar "args"))) (EBlock (DoLet false false (PVar "path") (EApp (EApp (EVar "leafPath") (EVar "head")) (EVar "args"))) (DoLet false false (PVar "values") (EApp (EApp (EVar "filterList") (ELam ((PVar "a")) (EApp (EVar "isNone") (EApp (EVar "grantElems") (EVar "a"))))) (EVar "args"))) (DoLet false false (PVar "at") (EApp (EApp (EVar "orElse") (EApp (EApp (EVar "findMap") (EVar "leftLoc")) (EVar "values"))) (EVar "around"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "a")) (EMatch (EApp (EVar "grantElems") (EVar "a")) (arm (PCon "Some" (PVar "es")) () (EIf (EApp (EApp (EVar "wasmGrantConfined") (EVar "path")) (EVar "es")) (ELit LUnit) (EApp (EApp (EVar "setRef") (EVar "sites")) (EBinOp "::" (ETuple (EVar "at") (EApp (EVar "calleeName") (EVar "head")) (EVar "es")) (EFieldAccess (EVar "sites") "value"))))) (arm (PCon "None") () (ELit LUnit))))) (EVar "args")))) (EListLit))) (DoLet false false (PVar "f") (EApp (EApp (EApp (EApp (EApp (EVar "scanGrantSites") (EVar "reach")) (EVar "sites")) (EVar "around")) (EVar "bound")) (EVar "head"))) (DoLet false false (PVar "xs") (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EVar "scanGrantSites") (EVar "reach")) (EVar "sites")) (EVar "around")) (EVar "bound"))) (EVar "args"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (EVar "EApp")) (EApp (EApp (EVar "keepSpineLoc") (EVar "spine")) (EVar "f"))) (EVar "xs")))))
(DData Private "Reach" () ((variant "Reach" (ConPos (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Int"))))) ())
(DTypeSig false "mayReachFile" (TyFun (TyCon "Reach") (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "mayReachFile" ((PVar "reach") (PVar "bound") (PVar "head") (PVar "argc")) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "callMayReachFile") (EVar "reach")) (EVar "False")) (EVar "bound")) (EVar "head")) (EVar "argc")) (EApp (EApp (EApp (EApp (EApp (EVar "callMayReachFile") (EVar "reach")) (EVar "True")) (EVar "bound")) (EVar "head")) (EVar "argc"))))
(DTypeSig false "callMayReachFile" (TyFun (TyCon "Reach") (TyFun (TyCon "Bool") (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "callMayReachFile" ((PVar "reach") (PVar "write") (PVar "bound") (PVar "head") (PVar "argc")) (EMatch (EApp (EApp (EVar "localHead") (EVar "bound")) (EVar "head")) (arm (PCon "Some" (PCon "LocalFunction" (PVar "ps") (PVar "body") (PVar "captured") (PVar "reads") (PVar "writes"))) () (EBinOp "||" (EBinOp ">" (EVar "argc") (EApp (EVar "valueParamCount") (EVar "ps"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "localMayReachFile") (EVar "reach")) (EVar "write")) (EVar "ps")) (EVar "body")) (EVar "captured")) (EIf (EVar "write") (EVar "writes") (EVar "reads"))))) (arm (PCon "Some" (PCon "UnknownBinding")) () (EVar "True")) (arm (PCon "None") () (EBlock (DoLet false false (PCon "Reach" (PVar "defined") (PVar "reads") (PVar "writes") (PVar "returns")) (EVar "reach")) (DoExpr (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "unknownCall") (EVar "returns")) (EVar "bound")) (EVar "head")) (EVar "argc")) (EMatch (EApp (EVar "headName") (EVar "head")) (arm (PCon "Some" (PVar "n")) () (EIf (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "$withFileReadBound"))) (EBinOp "==" (EVar "n") (ELit (LString "$withFileWriteBound")))) (EVar "False") (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "n")) (EIf (EVar "write") (EVar "writes") (EVar "reads"))) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "defined")))))) (arm (PCon "None") () (EVar "True")))))))))
(DTypeSig false "localMayReachFile" (TyFun (TyCon "Reach") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyCon "Scope") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Bool"))) (TyCon "Bool"))))))))
(DFunDef false "localMayReachFile" ((PVar "reach") (PVar "write") (PVar "ps") (PVar "body") (PVar "captured") (PVar "cache")) (EMatch (EFieldAccess (EVar "cache") "value") (arm (PCon "Some" (PVar "found")) () (EVar "found")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "found") (EApp (EApp (EApp (EApp (EVar "bodyMayReachFile") (EVar "reach")) (EVar "write")) (EApp (EApp (EVar "addPatScope") (EVar "ps")) (EVar "captured"))) (EVar "body"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "cache")) (EApp (EVar "Some") (EVar "found")))) (DoExpr (EVar "found"))))))
(DTypeSig false "bodyMayReachFile" (TyFun (TyCon "Reach") (TyFun (TyCon "Bool") (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Bool"))))))
(DFunDef false "bodyMayReachFile" ((PVar "reach") (PVar "write") (PVar "bound") (PAs "e" (PCon "EApp" PWild PWild))) (EBlock (DoLet false false (PTuple (PVar "head") (PVar "args")) (EApp (EApp (EVar "appSpine") (EVar "e")) (EListLit))) (DoExpr (EIf (EApp (EApp (EApp (EApp (EApp (EVar "knownNonFileCall") (EVar "reach")) (EVar "write")) (EVar "bound")) (EVar "head")) (EApp (EVar "listLen") (EVar "args"))) (EApp (EApp (EVar "any") (EApp (EApp (EApp (EVar "evalOnlyMayReachFile") (EVar "reach")) (EVar "write")) (EVar "bound"))) (EVar "args")) (EApp (EApp (EApp (EApp (EVar "bodyMayReachFileChildren") (EVar "reach")) (EVar "write")) (EVar "bound")) (EVar "e"))))))
(DFunDef false "bodyMayReachFile" ((PVar "reach") (PVar "write") (PVar "bound") (PVar "e")) (EApp (EApp (EApp (EApp (EVar "bodyMayReachFileChildren") (EVar "reach")) (EVar "write")) (EVar "bound")) (EVar "e")))
(DTypeSig false "knownNonFileCall" (TyFun (TyCon "Reach") (TyFun (TyCon "Bool") (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "knownNonFileCall" ((PVar "reach") (PVar "write") (PVar "bound") (PVar "head") (PVar "argc")) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EApp (EVar "callMayReachFile") (EVar "reach")) (EVar "write")) (EVar "bound")) (EVar "head")) (EVar "argc"))))
(DTypeSig false "evalOnlyMayReachFile" (TyFun (TyCon "Reach") (TyFun (TyCon "Bool") (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Bool"))))))
(DFunDef false "evalOnlyMayReachFile" (PWild PWild PWild (PCon "ELam" PWild PWild)) (EVar "False"))
(DFunDef false "evalOnlyMayReachFile" ((PVar "reach") (PVar "write") (PVar "bound") (PAs "e" (PCon "EApp" PWild PWild))) (EApp (EApp (EApp (EApp (EVar "bodyMayReachFile") (EVar "reach")) (EVar "write")) (EVar "bound")) (EVar "e")))
(DFunDef false "evalOnlyMayReachFile" ((PVar "reach") (PVar "write") (PVar "bound") (PVar "e")) (EBlock (DoLet false false (PVar "found") (EApp (EVar "Ref") (EVar "False"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "mapScopedChildren") (EVar "bound")) (ELam ((PVar "scope") (PVar "child")) (EBlock (DoLet false false PWild (EIf (EApp (EApp (EApp (EApp (EVar "evalOnlyMayReachFile") (EVar "reach")) (EVar "write")) (EVar "scope")) (EVar "child")) (EApp (EApp (EVar "setRef") (EVar "found")) (EVar "True")) (ELit LUnit))) (DoExpr (EVar "child"))))) (EVar "e"))) (DoExpr (EFieldAccess (EVar "found") "value"))))
(DTypeSig false "bodyMayReachFileChildren" (TyFun (TyCon "Reach") (TyFun (TyCon "Bool") (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Bool"))))))
(DFunDef false "bodyMayReachFileChildren" ((PVar "reach") (PVar "write") (PVar "bound") (PVar "e")) (EBlock (DoLet false false (PVar "found") (EApp (EVar "Ref") (EVar "False"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "mapScopedChildren") (EVar "bound")) (ELam ((PVar "scope") (PVar "child")) (EBlock (DoLet false false PWild (EIf (EApp (EApp (EApp (EApp (EVar "bodyMayReachFile") (EVar "reach")) (EVar "write")) (EVar "scope")) (EVar "child")) (EApp (EApp (EVar "setRef") (EVar "found")) (EVar "True")) (ELit LUnit))) (DoExpr (EVar "child"))))) (EVar "e"))) (DoExpr (EBinOp "||" (EFieldAccess (EVar "found") "value") (EMatch (EVar "e") (arm (PCon "EApp" PWild PWild) () (EBlock (DoLet false false (PTuple (PVar "head") (PVar "args")) (EApp (EApp (EVar "appSpine") (EVar "e")) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "callMayReachFile") (EVar "reach")) (EVar "write")) (EVar "bound")) (EVar "head")) (EApp (EVar "listLen") (EVar "args")))))) (arm PWild () (EVar "False")))))))
(DTypeSig false "localHead" (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "LocalBinding")))))
(DFunDef false "localHead" ((PVar "bound") (PVar "head")) (EMatch (EApp (EVar "headRawName") (EVar "head")) (arm (PCon "Some" (PVar "n")) () (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "bound"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "headName" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "headName" ((PVar "e")) (EApp (EApp (EVar "map") (EVar "unmangled")) (EApp (EVar "headRawName") (EVar "e"))))
(DTypeSig false "headRawName" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "headRawName" ((PCon "EVar" (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "headRawName" ((PCon "EDictAt" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "headRawName" ((PCon "EMethodAt" (PVar "n") PWild (PVar "ev"))) (EBlock (DoLet false false (PTuple PWild PWild (PVar "route") PWild PWild) (EApp (EVar "evMethodRoutes") (EVar "ev"))) (DoExpr (EApp (EVar "Some") (EMatch (EVar "route") (arm (PCon "RLocal" (PVar "sym") PWild) () (EIf (EBinOp "==" (EVar "sym") (ELit (LString ""))) (EVar "n") (EVar "sym"))) (arm PWild () (EVar "n")))))))
(DFunDef false "headRawName" ((PCon "EVarAt" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "headRawName" ((PCon "EVarId" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "headRawName" (PWild) (EVar "None"))
(DData Private "LocalBinding" () ((variant "UnknownBinding" (ConPos)) (variant "LocalFunction" (ConPos (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "OrdMap") (TyCon "LocalBinding")) (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Bool"))) (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Bool")))))) ())
(DTypeAlias false "Scope" () (TyApp (TyCon "OrdMap") (TyCon "LocalBinding")))
(DTypeSig false "localBinding" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyCon "Scope") (TyCon "LocalBinding")))))
(DFunDef false "localBinding" ((PVar "ps") (PVar "body") (PVar "captured")) (EApp (EApp (EApp (EApp (EApp (EVar "LocalFunction") (EVar "ps")) (EVar "body")) (EVar "captured")) (EApp (EVar "Ref") (EVar "None"))) (EApp (EVar "Ref") (EVar "None"))))
(DTypeSig false "addNamesScope" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Scope") (TyCon "Scope"))))
(DFunDef false "addNamesScope" ((PVar "names") (PVar "bound")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "n")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "UnknownBinding")) (EVar "m")))) (EVar "bound")) (EVar "names")))
(DTypeSig false "addPatScope" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Scope") (TyCon "Scope"))))
(DFunDef false "addPatScope" ((PVar "ps") (PVar "bound")) (EApp (EApp (EVar "addNamesScope") (EApp (EApp (EVar "flatMap") (EVar "patBoundNames")) (EVar "ps"))) (EVar "bound")))
(DTypeSig false "letScope" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Scope") (TyCon "Scope")))))))
(DFunDef false "letScope" ((PCon "False") (PVar "recursive") (PCon "PVar" (PVar "n") PWild) (PVar "rhs") (PVar "bound")) (EBlock (DoLet false false (PVar "captured") (EIf (EVar "recursive") (EApp (EApp (EVar "addNamesScope") (EListLit (EVar "n"))) (EVar "bound")) (EVar "bound"))) (DoExpr (EMatch (EApp (EApp (EVar "localFunction") (EVar "captured")) (EVar "rhs")) (arm (PCon "Some" (PVar "binding")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "binding")) (EVar "bound"))) (arm (PCon "None") () (EApp (EApp (EVar "addNamesScope") (EListLit (EVar "n"))) (EVar "bound")))))))
(DFunDef false "letScope" (PWild PWild (PVar "pat") PWild (PVar "bound")) (EApp (EApp (EVar "addPatScope") (EListLit (EVar "pat"))) (EVar "bound")))
(DTypeSig false "localFunction" (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "LocalBinding")))))
(DFunDef false "localFunction" ((PVar "bound") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EVar "localFunction") (EVar "bound")) (EVar "e")))
(DFunDef false "localFunction" ((PVar "bound") (PCon "EAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "localFunction") (EVar "bound")) (EVar "e")))
(DFunDef false "localFunction" ((PVar "bound") (PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "localFunction") (EVar "bound")) (EVar "e")))
(DFunDef false "localFunction" ((PVar "bound") (PCon "ELet" PWild (PCon "False") (PVar "pat") (PVar "rhs") (PVar "body"))) (EApp (EApp (EVar "localFunction") (EApp (EApp (EApp (EApp (EApp (EVar "letScope") (EVar "False")) (EVar "False")) (EVar "pat")) (EVar "rhs")) (EVar "bound"))) (EVar "body")))
(DFunDef false "localFunction" ((PVar "bound") (PCon "ELam" (PVar "ps") (PVar "body"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "localBinding") (EVar "ps")) (EVar "body")) (EVar "bound"))))
(DFunDef false "localFunction" (PWild PWild) (EVar "None"))
(DTypeSig false "localGroupScope" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Scope") (TyCon "Scope"))))
(DFunDef false "localGroupScope" ((PVar "binds") (PVar "bound")) (EBlock (DoLet false false (PVar "captured") (EApp (EApp (EVar "addNamesScope") (EApp (EApp (EVar "map") (ELam ((PVar "b")) (EMatch (EVar "b") (arm (PCon "LetBind" (PVar "n") PWild PWild) () (EVar "n"))))) (EVar "binds"))) (EVar "bound"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "b")) (EMatch (EVar "b") (arm (PCon "LetBind" (PVar "n") (PList (PCon "FunClause" (PVar "ps") (PVar "body"))) PWild) () (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EApp (EApp (EVar "localBinding") (EVar "ps")) (EVar "body")) (EVar "captured"))) (EVar "m"))) (arm (PCon "LetBind" PWild PWild PWild) () (EVar "m"))))) (EVar "captured")) (EVar "binds")))))
(DTypeSig false "mapScopedDeclBodies" (TyFun (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Expr"))) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "mapScopedDeclBodies" ((PVar "f") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "body") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EVar "ps")) (EApp (EApp (EVar "f") (EApp (EApp (EVar "addPatScope") (EVar "ps")) (EVar "omEmpty"))) (EVar "body"))) (EVar "site")))
(DFunDef false "mapScopedDeclBodies" ((PVar "f") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EVar "map") (EApp (EApp (EVar "mapScopedLetBind") (EVar "f")) (EVar "omEmpty"))) (EVar "binds"))))
(DFunDef false "mapScopedDeclBodies" ((PVar "f") (PAs "d" (PRec "DImpl" ((rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "body")) () (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "ps")) (EApp (EApp (EVar "f") (EApp (EApp (EVar "addPatScope") (EVar "ps")) (EVar "omEmpty"))) (EVar "body"))))))) (EVar "methods"))))))
(DFunDef false "mapScopedDeclBodies" ((PVar "f") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PVar "def") (PVar "loc")) () (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EApp (EVar "map") (ELam ((PVar "dm")) (EMatch (EVar "dm") (arm (PCon "MethodDefault" (PVar "ps") (PVar "body")) () (EApp (EApp (EVar "MethodDefault") (EVar "ps")) (EApp (EApp (EVar "f") (EApp (EApp (EVar "addPatScope") (EVar "ps")) (EVar "omEmpty"))) (EVar "body"))))))) (EVar "def"))) (EVar "loc")))))) (EVar "methods"))))))
(DFunDef false "mapScopedDeclBodies" ((PVar "f") (PCon "DProp" (PVar "pub") (PVar "n") (PVar "params") (PVar "body"))) (EBlock (DoLet false false (PVar "bound") (EApp (EApp (EVar "addNamesScope") (EApp (EApp (EVar "map") (ELam ((PVar "p")) (EMatch (EVar "p") (arm (PCon "PropParam" (PVar "name") PWild PWild) () (EVar "name"))))) (EVar "params"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "n")) (EVar "params")) (EApp (EApp (EVar "f") (EVar "bound")) (EVar "body"))))))
(DFunDef false "mapScopedDeclBodies" ((PVar "f") (PCon "DTest" (PVar "pub") (PVar "n") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "n")) (EApp (EApp (EVar "f") (EVar "omEmpty")) (EVar "body"))))
(DFunDef false "mapScopedDeclBodies" ((PVar "f") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "mapScopedDeclBodies") (EVar "f")) (EVar "d"))))
(DFunDef false "mapScopedDeclBodies" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "mapScopedLetBind" (TyFun (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Expr"))) (TyFun (TyCon "Scope") (TyFun (TyCon "LetBind") (TyCon "LetBind")))))
(DFunDef false "mapScopedLetBind" ((PVar "f") (PVar "bound") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site"))) (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (ELam ((PVar "c")) (EMatch (EVar "c") (arm (PCon "FunClause" (PVar "ps") (PVar "body")) () (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EApp (EVar "f") (EApp (EApp (EVar "addPatScope") (EVar "ps")) (EVar "bound"))) (EVar "body"))))))) (EVar "clauses"))) (EVar "site")))
(DTypeSig false "mapScopedChildren" (TyFun (TyCon "Scope") (TyFun (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Expr"))) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "mapScopedChildren" ((PVar "bound") (PVar "f") (PCon "ELam" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EApp (EVar "f") (EApp (EApp (EVar "addPatScope") (EVar "ps")) (EVar "bound"))) (EVar "body"))))
(DFunDef false "mapScopedChildren" ((PVar "bound") (PVar "f") (PCon "ELet" (PVar "site") (PVar "recursive") (PVar "pat") (PVar "rhs") (PVar "body"))) (EBlock (DoLet false false (PVar "after") (EApp (EApp (EApp (EApp (EApp (EVar "letScope") (EVar "False")) (EVar "recursive")) (EVar "pat")) (EVar "rhs")) (EVar "bound"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "site")) (EVar "recursive")) (EVar "pat")) (EApp (EApp (EVar "f") (EIf (EVar "recursive") (EVar "after") (EVar "bound"))) (EVar "rhs"))) (EApp (EApp (EVar "f") (EVar "after")) (EVar "body"))))))
(DFunDef false "mapScopedChildren" ((PVar "bound") (PVar "f") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "after") (EApp (EApp (EVar "localGroupScope") (EVar "binds")) (EVar "bound"))) (DoExpr (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EVar "map") (EApp (EApp (EVar "mapScopedLetBind") (EVar "f")) (EVar "after"))) (EVar "binds"))) (EApp (EApp (EVar "f") (EVar "after")) (EVar "body"))))))
(DFunDef false "mapScopedChildren" ((PVar "bound") (PVar "f") (PCon "EMatch" (PVar "e") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EVar "f") (EVar "bound")) (EVar "e"))) (EApp (EApp (EVar "map") (ELam ((PVar "a")) (EMatch (EVar "a") (arm (PCon "Arm" (PVar "pat") (PVar "guards") (PVar "body")) () (EBlock (DoLet false false (PTuple (PVar "guards2") (PVar "after")) (EApp (EApp (EApp (EVar "mapScopedGuards") (EVar "f")) (EApp (EApp (EVar "addPatScope") (EListLit (EVar "pat"))) (EVar "bound"))) (EVar "guards"))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EVar "pat")) (EVar "guards2")) (EApp (EApp (EVar "f") (EVar "after")) (EVar "body"))))))))) (EVar "arms"))))
(DFunDef false "mapScopedChildren" ((PVar "bound") (PVar "f") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EVar "map") (ELam ((PVar "a")) (EMatch (EVar "a") (arm (PCon "GuardArm" (PVar "guards") (PVar "body")) () (EBlock (DoLet false false (PTuple (PVar "guards2") (PVar "after")) (EApp (EApp (EApp (EVar "mapScopedGuards") (EVar "f")) (EVar "bound")) (EVar "guards"))) (DoExpr (EApp (EApp (EVar "GuardArm") (EVar "guards2")) (EApp (EApp (EVar "f") (EVar "after")) (EVar "body"))))))))) (EVar "arms"))))
(DFunDef false "mapScopedChildren" ((PVar "bound") (PVar "f") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EApp (EVar "mapScopedStmts") (EVar "f")) (EVar "bound")) (EVar "stmts"))))
(DFunDef false "mapScopedChildren" ((PVar "bound") (PVar "f") (PCon "EDo" (PVar "label") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "label")) (EApp (EApp (EApp (EVar "mapScopedStmts") (EVar "f")) (EVar "bound")) (EVar "stmts"))))
(DFunDef false "mapScopedChildren" ((PVar "bound") (PVar "f") (PVar "e")) (EApp (EApp (EVar "mapChildren") (EApp (EVar "f") (EVar "bound"))) (EVar "e")))
(DTypeSig false "mapScopedGuards" (TyFun (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Expr"))) (TyFun (TyCon "Scope") (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyTuple (TyApp (TyCon "List") (TyCon "Guard")) (TyCon "Scope"))))))
(DFunDef false "mapScopedGuards" (PWild (PVar "bound") (PList)) (ETuple (EListLit) (EVar "bound")))
(DFunDef false "mapScopedGuards" ((PVar "f") (PVar "bound") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EVar "f") (EVar "bound")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "after")) (EApp (EApp (EApp (EVar "mapScopedGuards") (EVar "f")) (EVar "bound")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "GBool") (EVar "e2")) (EVar "rest2")) (EVar "after")))))
(DFunDef false "mapScopedGuards" ((PVar "f") (PVar "bound") (PCons (PCon "GBind" (PVar "pat") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EVar "f") (EVar "bound")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "after")) (EApp (EApp (EApp (EVar "mapScopedGuards") (EVar "f")) (EApp (EApp (EVar "addPatScope") (EListLit (EVar "pat"))) (EVar "bound"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "GBind") (EVar "pat")) (EVar "e2")) (EVar "rest2")) (EVar "after")))))
(DTypeSig false "mapScopedStmts" (TyFun (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Expr"))) (TyFun (TyCon "Scope") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "DoStmt"))))))
(DFunDef false "mapScopedStmts" (PWild PWild (PList)) (EListLit))
(DFunDef false "mapScopedStmts" ((PVar "f") (PVar "bound") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "DoExpr") (EApp (EApp (EVar "f") (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "mapScopedStmts") (EVar "f")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "mapScopedStmts" ((PVar "f") (PVar "bound") (PCons (PCon "DoBind" (PVar "pat") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoBind") (EVar "pat")) (EApp (EApp (EVar "f") (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "mapScopedStmts") (EVar "f")) (EApp (EApp (EVar "addPatScope") (EListLit (EVar "pat"))) (EVar "bound"))) (EVar "rest"))))
(DFunDef false "mapScopedStmts" ((PVar "f") (PVar "bound") (PCons (PCon "DoLet" (PVar "mutable") (PVar "recursive") (PVar "pat") (PVar "e") (PVar "site")) (PVar "rest"))) (EBlock (DoLet false false (PVar "after") (EApp (EApp (EApp (EApp (EApp (EVar "letScope") (EVar "mutable")) (EVar "recursive")) (EVar "pat")) (EVar "e")) (EVar "bound"))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "mutable")) (EVar "recursive")) (EVar "pat")) (EApp (EApp (EVar "f") (EIf (EVar "recursive") (EVar "after") (EVar "bound"))) (EVar "e"))) (EVar "site")) (EApp (EApp (EApp (EVar "mapScopedStmts") (EVar "f")) (EVar "after")) (EVar "rest"))))))
(DFunDef false "mapScopedStmts" ((PVar "f") (PVar "bound") (PCons (PCon "DoAssign" (PVar "n") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoAssign") (EVar "n")) (EApp (EApp (EVar "f") (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "mapScopedStmts") (EVar "f")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "mapScopedStmts" ((PVar "f") (PVar "bound") (PCons (PCon "DoFieldAssign" (PVar "n") (PVar "fields") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "n")) (EVar "fields")) (EApp (EApp (EVar "f") (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "mapScopedStmts") (EVar "f")) (EVar "bound")) (EVar "rest"))))
(DTypeSig false "fileReach" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Reach")))
(DFunDef false "fileReach" ((PVar "decls")) (EBlock (DoLet false false (PVar "bindings") (EApp (EApp (EVar "flatMap") (EVar "declBindingBodies")) (EVar "decls"))) (DoLet false false (PVar "aliases") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "flatMap") (EVar "aliasNames")) (EVar "decls"))) (EVar "omEmpty"))) (DoLet false false (PVar "noRead") (EApp (EApp (EApp (EApp (EVar "declaredNoFile") (EVar "aliases")) (EVar "False")) (EVar "decls")) (EVar "bindings"))) (DoLet false false (PVar "noWrite") (EApp (EApp (EApp (EApp (EVar "declaredNoFile") (EVar "aliases")) (EVar "True")) (EVar "decls")) (EVar "bindings"))) (DoLet false false (PVar "returns") (EApp (EVar "returnedBoundaries") (EApp (EApp (EVar "filterList") (ELam ((PTuple (PVar "n") PWild PWild)) (EApp (EVar "not") (EBinOp "&&" (EApp (EApp (EVar "optionOr") (EVar "False")) (EApp (EApp (EVar "omLookup") (EApp (EVar "unmangled") (EVar "n"))) (EVar "noRead"))) (EApp (EApp (EVar "optionOr") (EVar "False")) (EApp (EApp (EVar "omLookup") (EApp (EVar "unmangled") (EVar "n"))) (EVar "noWrite"))))))) (EVar "bindings")))) (DoLet false false (PVar "users") (EApp (EVar "Ref") (EVar "omEmpty"))) (DoLet false false (PVar "defined") (EApp (EVar "Ref") (EVar "omEmpty"))) (DoLet false false PWild (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EApp (EApp (EVar "declDefines") (EVar "defined")) (EVar "d")))) (EVar "decls"))) (DoLet false false PWild (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "n") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "bindingRefs") (EVar "users")) (EVar "defined")) (EVar "returns")) (EVar "n")) (EVar "ps")) (EVar "body")))) (EVar "bindings"))) (DoLet false false (PVar "reads") (EListLit (ELit (LString "readFile")) (ELit (LString "fileExists")) (ELit (LString "canonicalizePath")) (ELit (LString "readFileBytes")))) (DoLet false false (PVar "writes") (EListLit (ELit (LString "writeFileBytes")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "Reach") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "wasmFileGrantExterns"))) (EFieldAccess (EVar "defined") "value"))) (EApp (EApp (EApp (EApp (EVar "spread") (EFieldAccess (EVar "users") "value")) (EVar "noRead")) (EVar "reads")) (EApp (EApp (EVar "omFromNames") (EVar "reads")) (EVar "omEmpty")))) (EApp (EApp (EApp (EApp (EVar "spread") (EFieldAccess (EVar "users") "value")) (EVar "noWrite")) (EVar "writes")) (EApp (EApp (EVar "omFromNames") (EVar "writes")) (EVar "omEmpty")))) (EVar "returns")))))
(DTypeSig false "unknownCall" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "unknownCall" ((PVar "returns") (PVar "bound") (PVar "head") (PVar "argc")) (EMatch (EApp (EApp (EVar "localHead") (EVar "bound")) (EVar "head")) (arm (PCon "Some" (PCon "LocalFunction" (PVar "ps") PWild PWild PWild PWild)) () (EBinOp ">" (EVar "argc") (EApp (EVar "valueParamCount") (EVar "ps")))) (arm (PCon "Some" (PCon "UnknownBinding")) () (EVar "True")) (arm (PCon "None") () (EMatch (EApp (EVar "headRawName") (EVar "head")) (arm (PCon "Some" (PVar "n")) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "returns")) (arm (PCon "Some" (PVar "boundary")) () (EBinOp ">" (EVar "argc") (EVar "boundary"))) (arm (PCon "None") () (EVar "False")))) (arm (PCon "None") () (EVar "True"))))))
(DTypeSig false "valueParamCount" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))
(DFunDef false "valueParamCount" ((PCons (PCon "PVar" (PVar "n") PWild) (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "$dict"))) (EVar "n")) (EApp (EVar "valueParamCount") (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "valueParamCount" ((PVar "ps")) (EApp (EVar "listLen") (EVar "ps")))
(DTypeSig false "declBindingBodies" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "declBindingBodies" ((PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body") PWild)) (EListLit (ETuple (EVar "n") (EVar "ps") (EVar "body"))))
(DFunDef false "declBindingBodies" ((PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EVar "flatMap") (EVar "letBindBodies")) (EVar "binds")))
(DFunDef false "declBindingBodies" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EVar "map") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "body")) () (ETuple (EVar "n") (EVar "ps") (EVar "body")))))) (EVar "methods")))
(DFunDef false "declBindingBodies" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EVar "flatMap") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "IfaceMethod" (PVar "n") PWild (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "body"))) PWild) () (EListLit (ETuple (EVar "n") (EVar "ps") (EVar "body")))) (arm (PCon "IfaceMethod" PWild PWild (PCon "None") PWild) () (EListLit))))) (EVar "methods")))
(DFunDef false "declBindingBodies" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declBindingBodies") (EVar "d")))
(DFunDef false "declBindingBodies" (PWild) (EListLit))
(DTypeSig false "letBindBodies" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "letBindBodies" ((PCon "LetBind" (PVar "n") (PVar "clauses") PWild)) (EApp (EApp (EVar "map") (ELam ((PVar "c")) (EMatch (EVar "c") (arm (PCon "FunClause" (PVar "ps") (PVar "body")) () (ETuple (EVar "n") (EVar "ps") (EVar "body")))))) (EVar "clauses")))
(DTypeSig false "returnedBoundaries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "OrdMap") (TyCon "Int"))))
(DFunDef false "returnedBoundaries" ((PVar "bindings")) (EBlock (DoLet false false (PVar "seeds") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "deps") (EApp (EVar "Ref") (EVar "omEmpty"))) (DoLet false false PWild (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "n") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "n")) (EApp (EVar "valueParamCount") (EVar "ps"))) (EApp (EApp (EVar "addPatScope") (EVar "ps")) (EVar "omEmpty"))) (EVar "body")))) (EVar "bindings"))) (DoExpr (EApp (EApp (EApp (EVar "relaxReturns") (EFieldAccess (EVar "deps") "value")) (EFieldAccess (EVar "seeds") "value")) (EVar "omEmpty")))))
(DTypeSig false "relaxReturns" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int"))))))
(DFunDef false "relaxReturns" (PWild (PList) (PVar "seen")) (EVar "seen"))
(DFunDef false "relaxReturns" ((PVar "deps") (PCons (PTuple (PVar "n") (PVar "boundary")) (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "settled") (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "seen")) (arm (PCon "Some" (PVar "old")) () (EBinOp "<=" (EVar "old") (EVar "boundary"))) (arm (PCon "None") () (EVar "False")))) (DoExpr (EIf (EVar "settled") (EApp (EApp (EApp (EVar "relaxReturns") (EVar "deps")) (EVar "rest")) (EVar "seen")) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "owner") (PVar "base") (PVar "supplied"))) (ETuple (EVar "owner") (EBinOp "+" (EVar "base") (EApp (EApp (EVar "max") (ELit (LInt 0))) (EBinOp "-" (EVar "boundary") (EVar "supplied"))))))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "deps"))))) (DoExpr (EApp (EApp (EApp (EVar "relaxReturns") (EVar "deps")) (EBinOp "++" (EVar "next") (EVar "rest"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "boundary")) (EVar "seen")))))))))
(DTypeSig false "tailReturns" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Int"))))) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Unit"))))))))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "e")))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "EAnnot" (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "e")))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "e")))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "e")))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "ELam" (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EBinOp "+" (EVar "base") (EApp (EVar "valueParamCount") (EVar "ps")))) (EApp (EApp (EVar "addPatScope") (EVar "ps")) (EVar "bound"))) (EVar "body")))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "ELet" PWild PWild (PVar "pat") PWild (PVar "body"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EApp (EApp (EVar "addPatScope") (EListLit (EVar "pat"))) (EVar "bound"))) (EVar "body")))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "after") (EApp (EApp (EVar "addNamesScope") (EApp (EApp (EVar "map") (ELam ((PVar "b")) (EMatch (EVar "b") (arm (PCon "LetBind" (PVar "n") PWild PWild) () (EVar "n"))))) (EVar "binds"))) (EVar "bound"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "after")) (EVar "body")))))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "EIf" PWild (PVar "yes") (PVar "no"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "yes"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "no")))))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "EMatch" PWild (PVar "arms"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "map") (ELam ((PVar "a")) (EMatch (EVar "a") (arm (PCon "Arm" (PVar "pat") (PVar "guards") (PVar "body")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EApp (EApp (EVar "guardScope") (EVar "guards")) (EApp (EApp (EVar "addPatScope") (EListLit (EVar "pat"))) (EVar "bound")))) (EVar "body")))))) (EVar "arms"))) (DoExpr (ELit LUnit))))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "EGuards" (PVar "arms"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "map") (ELam ((PVar "a")) (EMatch (EVar "a") (arm (PCon "GuardArm" (PVar "guards") (PVar "body")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EApp (EApp (EVar "guardScope") (EVar "guards")) (EVar "bound"))) (EVar "body")))))) (EVar "arms"))) (DoExpr (ELit LUnit))))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailStmtReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "stmts")))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailStmtReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "stmts")))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PVar "e")) (EBlock (DoLet false false (PTuple (PVar "head") (PVar "args")) (EApp (EApp (EVar "appSpine") (EVar "e")) (EListLit))) (DoExpr (EMatch (ETuple (EApp (EVar "headName") (EVar "head")) (EVar "args")) (arm (PTuple (PCon "Some" (PVar "n")) (PList PWild (PCon "ELam" (PList (PCon "PWild")) (PVar "body")))) ((GBool (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "$withFileReadBound"))) (EBinOp "==" (EVar "n") (ELit (LString "$withFileWriteBound")))))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "body"))) (arm PWild () (EMatch (EApp (EVar "headRawName") (EVar "head")) (arm (PCon "Some" (PVar "raw")) () (EIf (EApp (EApp (EVar "omHasKey") (EVar "raw")) (EVar "bound")) (EApp (EApp (EVar "setRef") (EVar "seeds")) (EBinOp "::" (ETuple (EVar "owner") (EVar "base")) (EFieldAccess (EVar "seeds") "value"))) (EApp (EApp (EVar "setRef") (EVar "deps")) (EApp (EApp (EApp (EVar "omInsert") (EVar "raw")) (EBinOp "::" (ETuple (EVar "owner") (EVar "base") (EApp (EVar "listLen") (EVar "args"))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "raw")) (EFieldAccess (EVar "deps") "value"))))) (EFieldAccess (EVar "deps") "value"))))) (arm (PCon "None") () (EMatch (EVar "e") (arm (PCon "ELit" PWild) () (ELit LUnit)) (arm (PCon "ETuple" PWild) () (ELit LUnit)) (arm (PCon "EListLit" PWild) () (ELit LUnit)) (arm (PCon "EArrayLit" PWild) () (ELit LUnit)) (arm (PCon "ERecordCreate" PWild PWild) () (ELit LUnit)) (arm PWild () (EApp (EApp (EVar "setRef") (EVar "seeds")) (EBinOp "::" (ETuple (EVar "owner") (EVar "base")) (EFieldAccess (EVar "seeds") "value"))))))))))))
(DTypeSig false "guardScope" (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyFun (TyCon "Scope") (TyCon "Scope"))))
(DFunDef false "guardScope" ((PList) (PVar "bound")) (EVar "bound"))
(DFunDef false "guardScope" ((PCons (PCon "GBind" (PVar "pat") PWild) (PVar "rest")) (PVar "bound")) (EApp (EApp (EVar "guardScope") (EVar "rest")) (EApp (EApp (EVar "addPatScope") (EListLit (EVar "pat"))) (EVar "bound"))))
(DFunDef false "guardScope" ((PCons PWild (PVar "rest")) (PVar "bound")) (EApp (EApp (EVar "guardScope") (EVar "rest")) (EVar "bound")))
(DTypeSig false "tailStmtReturns" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Int"))))) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Scope") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "Unit"))))))))
(DFunDef false "tailStmtReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PList (PCon "DoExpr" (PVar "e")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "e")))
(DFunDef false "tailStmtReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCons (PCon "DoBind" (PVar "pat") PWild) (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailStmtReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EApp (EApp (EVar "addPatScope") (EListLit (EVar "pat"))) (EVar "bound"))) (EVar "rest")))
(DFunDef false "tailStmtReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCons (PCon "DoLet" PWild PWild (PVar "pat") PWild PWild) (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailStmtReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EApp (EApp (EVar "addPatScope") (EListLit (EVar "pat"))) (EVar "bound"))) (EVar "rest")))
(DFunDef false "tailStmtReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailStmtReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "rest")))
(DFunDef false "tailStmtReturns" (PWild PWild PWild PWild PWild (PList)) (ELit LUnit))
(DTypeSig false "aliasNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "aliasNames" ((PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n"))) false)) (EListLit (EVar "n") (EApp (EVar "unmangled") (EVar "n"))))
(DFunDef false "aliasNames" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "aliasNames") (EVar "d")))
(DFunDef false "aliasNames" (PWild) (EListLit))
(DTypeSig false "declaredNoFile" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "OrdMap") (TyCon "Bool")))))))
(DFunDef false "declaredNoFile" ((PVar "aliases") (PVar "write") (PVar "decls") (PVar "bindings")) (EBlock (DoLet false false (PVar "ordinary") (EApp (EApp (EApp (EVar "fold") (EApp (EApp (EVar "signatureNoFile") (EVar "aliases")) (EVar "write"))) (EVar "omEmpty")) (EVar "decls"))) (DoLet false false (PVar "methods") (EApp (EApp (EApp (EVar "fold") (EApp (EApp (EVar "methodNoFile") (EVar "aliases")) (EVar "write"))) (EVar "omEmpty")) (EVar "decls"))) (DoLet false false (PVar "results") (EApp (EVar "Ref") (EVar "omEmpty"))) (DoLet false false PWild (EApp (EApp (EVar "map") (ELam ((PVar "d")) (EApp (EApp (EApp (EApp (EVar "bindingNoFile") (EVar "ordinary")) (EVar "methods")) (EVar "results")) (EVar "d")))) (EVar "decls"))) (DoExpr (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PTuple (PVar "n") PWild PWild)) (EBlock (DoLet false false (PVar "name") (EApp (EVar "unmangled") (EVar "n"))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EApp (EApp (EVar "optionOr") (EVar "False")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "results") "value")))) (EVar "m")))))) (EVar "omEmpty")) (EVar "bindings")))))
(DTypeSig false "putNoFile" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyApp (TyCon "OrdMap") (TyCon "Bool"))))))
(DFunDef false "putNoFile" ((PVar "n") (PVar "proof") (PVar "m")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EBinOp "&&" (EVar "proof") (EApp (EApp (EVar "optionOr") (EVar "True")) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "m"))))) (EVar "m")))
(DTypeSig false "signatureNoFile" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyFun (TyCon "Decl") (TyApp (TyCon "OrdMap") (TyCon "Bool")))))))
(DFunDef false "signatureNoFile" ((PVar "aliases") (PVar "write") (PVar "m") (PCon "DTypeSig" PWild (PVar "n") (PVar "ty"))) (EApp (EApp (EApp (EVar "putNoFile") (EVar "n")) (EApp (EApp (EApp (EVar "tyNoFile") (EVar "aliases")) (EVar "write")) (EVar "ty"))) (EVar "m")))
(DFunDef false "signatureNoFile" ((PVar "aliases") (PVar "write") (PVar "m") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "signatureNoFile") (EVar "aliases")) (EVar "write")) (EVar "m")) (EVar "d")))
(DFunDef false "signatureNoFile" (PWild PWild (PVar "m") PWild) (EVar "m"))
(DTypeSig false "methodNoFile" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyFun (TyCon "Decl") (TyApp (TyCon "OrdMap") (TyCon "Bool")))))))
(DFunDef false "methodNoFile" ((PVar "aliases") (PVar "write") (PVar "m") (PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "method")) (EMatch (EVar "method") (arm (PCon "IfaceMethod" (PVar "n") (PVar "ty") PWild PWild) () (EApp (EApp (EApp (EVar "putNoFile") (EApp (EVar "unmangled") (EVar "n"))) (EApp (EApp (EApp (EVar "tyNoFile") (EVar "aliases")) (EVar "write")) (EVar "ty"))) (EVar "acc")))))) (EVar "m")) (EVar "methods")))
(DFunDef false "methodNoFile" ((PVar "aliases") (PVar "write") (PVar "m") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "methodNoFile") (EVar "aliases")) (EVar "write")) (EVar "m")) (EVar "d")))
(DFunDef false "methodNoFile" (PWild PWild (PVar "m") PWild) (EVar "m"))
(DTypeSig false "bindingNoFile" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Bool"))) (TyFun (TyCon "Decl") (TyCon "Unit"))))))
(DFunDef false "bindingNoFile" ((PVar "ordinary") PWild (PVar "results") (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild)) (EApp (EApp (EVar "setRef") (EVar "results")) (EApp (EApp (EApp (EVar "putNoFile") (EApp (EVar "unmangled") (EVar "n"))) (EApp (EApp (EVar "optionOr") (EVar "False")) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "ordinary")))) (EFieldAccess (EVar "results") "value"))))
(DFunDef false "bindingNoFile" ((PVar "ordinary") PWild (PVar "results") (PCon "DLetGroup" PWild (PVar "binds"))) (EBlock (DoLet false false PWild (EApp (EApp (EVar "map") (ELam ((PVar "b")) (EMatch (EVar "b") (arm (PCon "LetBind" (PVar "n") PWild PWild) () (EApp (EApp (EVar "setRef") (EVar "results")) (EApp (EApp (EApp (EVar "putNoFile") (EApp (EVar "unmangled") (EVar "n"))) (EApp (EApp (EVar "optionOr") (EVar "False")) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "ordinary")))) (EFieldAccess (EVar "results") "value"))))))) (EVar "binds"))) (DoExpr (ELit LUnit))))
(DFunDef false "bindingNoFile" (PWild (PVar "methods") (PVar "results") (PRec "DImpl" ((rf "methods" (PVar "bodies"))) true)) (EBlock (DoLet false false PWild (EApp (EApp (EVar "map") (ELam ((PVar "b")) (EMatch (EVar "b") (arm (PCon "ImplMethod" (PVar "n") PWild PWild) () (EApp (EApp (EVar "setRef") (EVar "results")) (EApp (EApp (EApp (EVar "putNoFile") (EApp (EVar "unmangled") (EVar "n"))) (EApp (EApp (EVar "optionOr") (EVar "False")) (EApp (EApp (EVar "omLookup") (EApp (EVar "unmangled") (EVar "n"))) (EVar "methods")))) (EFieldAccess (EVar "results") "value"))))))) (EVar "bodies"))) (DoExpr (ELit LUnit))))
(DFunDef false "bindingNoFile" (PWild (PVar "methods") (PVar "results") (PRec "DInterface" ((rf "methods" (PVar "bodies"))) true)) (EBlock (DoLet false false PWild (EApp (EApp (EVar "map") (ELam ((PVar "b")) (EMatch (EVar "b") (arm (PCon "IfaceMethod" (PVar "n") PWild (PCon "Some" PWild) PWild) () (EApp (EApp (EVar "setRef") (EVar "results")) (EApp (EApp (EApp (EVar "putNoFile") (EApp (EVar "unmangled") (EVar "n"))) (EApp (EApp (EVar "optionOr") (EVar "False")) (EApp (EApp (EVar "omLookup") (EApp (EVar "unmangled") (EVar "n"))) (EVar "methods")))) (EFieldAccess (EVar "results") "value")))) (arm (PCon "IfaceMethod" PWild PWild (PCon "None") PWild) () (ELit LUnit))))) (EVar "bodies"))) (DoExpr (ELit LUnit))))
(DFunDef false "bindingNoFile" ((PVar "ordinary") (PVar "methods") (PVar "results") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "bindingNoFile") (EVar "ordinary")) (EVar "methods")) (EVar "results")) (EVar "d")))
(DFunDef false "bindingNoFile" (PWild PWild PWild PWild) (ELit LUnit))
(DTypeSig false "tyNoFile" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "tyNoFile" ((PVar "aliases") (PVar "write") (PCon "TyConstrained" PWild (PVar "ty"))) (EApp (EApp (EApp (EVar "tyNoFile") (EVar "aliases")) (EVar "write")) (EVar "ty")))
(DFunDef false "tyNoFile" ((PVar "aliases") (PVar "write") (PCon "TyNamed" PWild (PVar "ty") PWild)) (EApp (EApp (EApp (EVar "tyNoFile") (EVar "aliases")) (EVar "write")) (EVar "ty")))
(DFunDef false "tyNoFile" ((PVar "aliases") (PVar "write") (PCon "TyQual" (PVar "ty") PWild PWild)) (EApp (EApp (EApp (EVar "tyNoFile") (EVar "aliases")) (EVar "write")) (EVar "ty")))
(DFunDef false "tyNoFile" ((PVar "aliases") (PVar "write") (PCon "TyEffect" (PVar "atoms") (PVar "tails") (PVar "ty"))) (EBinOp "&&" (EBinOp "&&" (EApp (EVar "isEmpty") (EVar "tails")) (EApp (EApp (EVar "all") (EApp (EVar "atomNoFile") (EVar "write"))) (EVar "atoms"))) (EApp (EApp (EApp (EVar "tyNoFile") (EVar "aliases")) (EVar "write")) (EVar "ty"))))
(DFunDef false "tyNoFile" ((PVar "aliases") (PVar "write") (PCon "TyFun" PWild (PVar "result"))) (EApp (EApp (EApp (EVar "tyNoFile") (EVar "aliases")) (EVar "write")) (EVar "result")))
(DFunDef false "tyNoFile" ((PVar "aliases") PWild (PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EApp (EVar "not") (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "aliases")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "unmangled") (EVar "n"))) (EVar "aliases")))))
(DFunDef false "tyNoFile" ((PVar "aliases") (PVar "write") (PCon "TyApp" (PVar "head") PWild)) (EApp (EApp (EApp (EVar "tyNoFile") (EVar "aliases")) (EVar "write")) (EVar "head")))
(DFunDef false "tyNoFile" (PWild PWild (PCon "TyTuple" PWild)) (EVar "True"))
(DFunDef false "tyNoFile" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "atomNoFile" (TyFun (TyCon "Bool") (TyFun (TyCon "EffAtomTy") (TyCon "Bool"))))
(DFunDef false "atomNoFile" ((PVar "write") (PRec "EffAtomTy" ((rf "eatLabel" (PVar "label")) (rf "eatOrigin" (PCon "OriginBuiltin"))) false)) (EBinOp "&&" (EBinOp "/=" (EVar "label") (ELit (LString "IO"))) (EBinOp "/=" (EVar "label") (EIf (EVar "write") (ELit (LString "FileWrite")) (ELit (LString "FileRead"))))))
(DFunDef false "atomNoFile" (PWild (PRec "EffAtomTy" ((rf "eatOrigin" (PCon "OriginModule" PWild))) false)) (EVar "True"))
(DFunDef false "atomNoFile" (PWild PWild) (EVar "False"))
(DTypeSig false "spread" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "spread" (PWild PWild (PList) (PVar "seen")) (EVar "seen"))
(DFunDef false "spread" ((PVar "users") (PVar "noFile") (PCons (PVar "n") (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "fresh") (EApp (EApp (EVar "filterList") (ELam ((PVar "u")) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "u")) (EVar "seen"))) (EApp (EVar "not") (EApp (EApp (EVar "optionOr") (EVar "False")) (EApp (EApp (EVar "omLookup") (EVar "u")) (EVar "noFile"))))))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "users"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "spread") (EVar "users")) (EVar "noFile")) (EBinOp "++" (EVar "fresh") (EVar "rest"))) (EApp (EApp (EVar "omFromNames") (EVar "fresh")) (EVar "seen"))))))
(DTypeSig false "declDefines" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "Decl") (TyCon "Unit"))))
(DFunDef false "declDefines" ((PVar "defined") (PCon "DExtern" PWild (PVar "n") PWild)) (EApp (EApp (EVar "setRef") (EVar "defined")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "unmangled") (EVar "n"))) (ELit LUnit)) (EFieldAccess (EVar "defined") "value"))))
(DFunDef false "declDefines" ((PVar "defined") (PRec "DData" ((rf "dataCtors" None)) true)) (EApp (EApp (EVar "setRef") (EVar "defined")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "map") (ELam ((PVar "v")) (EMatch (EVar "v") (arm (PCon "Variant" (PVar "n") PWild) () (EApp (EVar "unmangled") (EVar "n")))))) (EVar "dataCtors"))) (EFieldAccess (EVar "defined") "value"))))
(DFunDef false "declDefines" ((PVar "defined") (PRec "DNewtype" ((rf "newtypeCtor" None)) true)) (EApp (EApp (EVar "setRef") (EVar "defined")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "unmangled") (EVar "newtypeCtor"))) (ELit LUnit)) (EFieldAccess (EVar "defined") "value"))))
(DFunDef false "declDefines" ((PVar "defined") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declDefines") (EVar "defined")) (EVar "d")))
(DFunDef false "declDefines" (PWild PWild) (ELit LUnit))
(DTypeSig false "bindingRefs" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Unit"))))))))
(DFunDef false "bindingRefs" ((PVar "users") (PVar "defined") (PVar "returns") (PVar "b") (PVar "ps") (PVar "body")) (EBlock (DoLet false false (PVar "name") (EApp (EVar "unmangled") (EVar "b"))) (DoLet false false (PVar "refs") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "collectRefs") (EVar "returns")) (EVar "refs")) (EApp (EApp (EVar "addPatScope") (EVar "ps")) (EVar "omEmpty"))) (EVar "body"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "defined")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EFieldAccess (EVar "defined") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "users")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "m") (PVar "r")) (EApp (EApp (EApp (EVar "omInsert") (EVar "r")) (EBinOp "::" (EVar "name") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "r")) (EVar "m"))))) (EVar "m")))) (EFieldAccess (EVar "users") "value")) (EFieldAccess (EVar "refs") "value"))))))
(DTypeSig false "collectRefs" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "collectRefs" ((PVar "returns") (PVar "refs") (PVar "bound") (PAs "e" (PCon "EApp" PWild PWild))) (EBlock (DoLet false false (PTuple (PVar "head") (PVar "args")) (EApp (EApp (EVar "appSpine") (EVar "e")) (EListLit))) (DoLet false false PWild (EIf (EApp (EApp (EApp (EApp (EVar "unknownCall") (EVar "returns")) (EVar "bound")) (EVar "head")) (EApp (EVar "listLen") (EVar "args"))) (EApp (EApp (EVar "setRef") (EVar "refs")) (EBinOp "::" (ELit (LString "readFile")) (EBinOp "::" (ELit (LString "writeFileBytes")) (EFieldAccess (EVar "refs") "value")))) (ELit LUnit))) (DoLet false false PWild (EMatch (EApp (EApp (EVar "localHead") (EVar "bound")) (EVar "head")) (arm (PCon "Some" (PCon "LocalFunction" PWild PWild PWild PWild PWild)) () (ELit LUnit)) (arm PWild () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "collectRefs") (EVar "returns")) (EVar "refs")) (EVar "bound")) (EVar "head"))) (DoExpr (ELit LUnit)))))) (DoLet false false PWild (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "collectRefs") (EVar "returns")) (EVar "refs")) (EVar "bound"))) (EVar "args"))) (DoExpr (EVar "e"))))
(DFunDef false "collectRefs" ((PVar "returns") (PVar "refs") (PVar "bound") (PVar "e")) (EMatch (EApp (EVar "headRawName") (EVar "e")) (arm (PCon "Some" (PVar "n")) () (EBlock (DoLet false false PWild (EIf (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound"))) (EApp (EApp (EVar "setRef") (EVar "refs")) (EBinOp "::" (EApp (EVar "unmangled") (EVar "n")) (EFieldAccess (EVar "refs") "value"))) (ELit LUnit))) (DoExpr (EVar "e")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "mapScopedChildren") (EVar "bound")) (EApp (EApp (EVar "collectRefs") (EVar "returns")) (EVar "refs"))) (EVar "e")))))
(DTypeSig false "keepSpineLoc" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "keepSpineLoc" ((PVar "spine") (PVar "head")) (EMatch (EApp (EVar "spineLoc") (EVar "spine")) (arm (PCon "Some" (PVar "l")) () (EApp (EApp (EVar "ELoc") (EVar "l")) (EVar "head"))) (arm (PCon "None") () (EVar "head"))))
(DTypeSig false "spineLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "spineLoc" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "spineLoc") (EVar "f")))
(DFunDef false "spineLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "spineLoc" (PWild) (EVar "None"))
(DTypeSig false "appSpine" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "appSpine" ((PCon "EApp" (PVar "f") (PVar "x")) (PVar "args")) (EApp (EApp (EVar "appSpine") (EVar "f")) (EBinOp "::" (EVar "x") (EVar "args"))))
(DFunDef false "appSpine" ((PCon "ELoc" PWild (PVar "f")) (PVar "args")) (EApp (EApp (EVar "appSpine") (EVar "f")) (EVar "args")))
(DFunDef false "appSpine" ((PVar "h") (PVar "args")) (ETuple (EVar "h") (EVar "args")))
(DTypeSig false "grantElems" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "grantElems" ((PCon "EListLit" (PAs "es" (PCons PWild PWild)))) (EApp (EApp (EVar "bareStrings") (EVar "es")) (EListLit)))
(DFunDef false "grantElems" ((PCon "EBinOp" (PLit (LString "++")) (PVar "a") (PVar "b") PWild)) (EMatch (ETuple (EApp (EVar "grantElems") (EVar "a")) (EApp (EVar "grantElems") (EVar "b"))) (arm (PTuple (PCon "None") (PCon "None")) () (EVar "None")) (arm (PTuple (PVar "x") (PVar "y")) () (EApp (EVar "Some") (EBinOp "++" (EApp (EApp (EVar "optionOr") (EListLit)) (EVar "x")) (EApp (EApp (EVar "optionOr") (EListLit)) (EVar "y")))))))
(DFunDef false "grantElems" ((PCon "EMatch" (PCon "EVar" PWild) (PList PWild (PCon "Arm" (PCon "PWild") (PList) (PVar "j"))))) (EApp (EVar "grantElems") (EVar "j")))
(DFunDef false "grantElems" (PWild) (EVar "None"))
(DTypeSig false "bareStrings" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "bareStrings" ((PList) (PVar "acc")) (EApp (EVar "Some") (EApp (EVar "reverseL") (EVar "acc"))))
(DFunDef false "bareStrings" ((PCons (PCon "ELit" (PCon "LString" (PVar "s"))) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "bareStrings") (EVar "rest")) (EBinOp "::" (EVar "s") (EVar "acc"))))
(DFunDef false "bareStrings" (PWild PWild) (EVar "None"))
(DTypeSig false "leafPath" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "leafPath" ((PCon "EVar" (PVar "n")) (PCons (PVar "p") (PVar "rest"))) (EMatch (EApp (EVar "wasmFileGrantArity") (EVar "n")) (arm (PCon "Some" (PVar "arity")) () (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "rest")) (EVar "arity")) (EApp (EVar "pathLit") (EVar "p")) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "leafPath" (PWild PWild) (EVar "None"))
(DTypeSig false "pathLit" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "pathLit" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "pathLit") (EVar "e")))
(DFunDef false "pathLit" ((PCon "ELit" (PCon "LString" (PVar "s")))) (EApp (EVar "Some") (EVar "s")))
(DFunDef false "pathLit" (PWild) (EVar "None"))
(DTypeSig false "calleeName" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "calleeName" ((PCon "EVar" (PLit (LString "$withFileReadBound")))) (ELit (LString "declared FileRead bound")))
(DFunDef false "calleeName" ((PCon "EVar" (PLit (LString "$withFileWriteBound")))) (ELit (LString "declared FileWrite bound")))
(DFunDef false "calleeName" ((PCon "EVar" (PVar "n"))) (EApp (EVar "unmangled") (EVar "n")))
(DFunDef false "calleeName" ((PCon "EDictAt" (PVar "n") PWild)) (EApp (EVar "unmangled") (EVar "n")))
(DFunDef false "calleeName" ((PCon "EMethodAt" (PVar "n") PWild PWild)) (EApp (EVar "unmangled") (EVar "n")))
(DFunDef false "calleeName" (PWild) (ELit (LString "this call")))
(DTypeSig false "unmangled" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "unmangled" ((PVar "n")) (EBlock (DoLet false false (PVar "bare") (EMatch (EApp (EApp (EVar "lastIndexOf") (ELit (LString "__"))) (EVar "n")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EApp (EVar "stringLength") (EVar "n"))) (EVar "n"))) (arm (PCon "None") () (EVar "n")))) (DoExpr (EMatch (EApp (EApp (EVar "indexOf") (ELit (LString "$"))) (EVar "bare")) (arm (PCon "Some" (PVar "i")) () (EIf (EBinOp ">" (EVar "i") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "bare")) (EVar "bare"))) (arm (PCon "None") () (EVar "bare"))))))
(DTypeSig false "leftLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "leftLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "leftLoc" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EVar "orElse") (EApp (EVar "leftLoc") (EVar "f"))) (EApp (EVar "leftLoc") (EVar "x"))))
(DFunDef false "leftLoc" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EApp (EApp (EVar "orElse") (EApp (EVar "leftLoc") (EVar "a"))) (EApp (EVar "leftLoc") (EVar "b"))))
(DFunDef false "leftLoc" ((PVar "e")) (EBlock (DoLet false false (PVar "found") (EApp (EVar "Ref") (EVar "None"))) (DoLet false false PWild (EApp (EApp (EVar "mapChildren") (ELam ((PVar "child")) (EBlock (DoLet false false PWild (EMatch (EFieldAccess (EVar "found") "value") (arm (PCon "None") () (EApp (EApp (EVar "setRef") (EVar "found")) (EApp (EVar "leftLoc") (EVar "child")))) (arm (PCon "Some" PWild) () (ELit LUnit)))) (DoExpr (EVar "child"))))) (EVar "e"))) (DoExpr (EFieldAccess (EVar "found") "value"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "Decl" true) (mem "DoStmt" true) (mem "Expr" true) (mem "FunClause" true) (mem "Guard" true) (mem "GuardArm" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "LetBind" true) (mem "Lit" true) (mem "Loc" false) (mem "MethodDefault" true) (mem "Pat" true) (mem "PropParam" true) (mem "Ty" true) (mem "TyConOrigin" true) (mem "Route" true) (mem "EffAtomTy" true) (mem "patBoundNames" false) (mem "Variant" true))))
(DUse false (UseGroup ("frontend" "desugar") ((mem "mapChildren" false))))
(DUse false (UseGroup ("types" "typecheck") ((mem "TcDiag" true))))
(DUse false (UseGroup ("types" "route_key") ((mem "evMethodRoutes" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omFromNames" false) (mem "omHasKey" false) (mem "omInsert" false) (mem "omLookup" false))))
(DUse false (UseGroup ("backend" "wasm_emit") ((mem "wasmFileGrantArity" false) (mem "wasmFileGrantExterns" false) (mem "wasmGrantConfined" false) (mem "wasmFileGrantMsg" false))))
(DUse false (UseGroup ("support" "util") ((mem "listLen" false) (mem "reverseL" false) (mem "filterList" false) (mem "startsWith" false))))
(DUse false (UseGroup ("list") ((mem "findMap" false))))
(DUse false (UseGroup ("string") ((mem "indexOf" false) (mem "lastIndexOf" false))))
(DTypeSig true "prepareWasmFileGrants" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl")))) (TyApp (TyApp (TyCon "Result") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))) (TyApp (TyCon "List") (TyCon "Decl")))))))
(DFunDef false "prepareWasmFileGrants" ((PVar "runtimeDecls") (PVar "kept") (PVar "modules")) (EBlock (DoLet false false (PVar "live") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EVar "keptFunNames") (EVar "kept")) (EListLit))) (EVar "omEmpty"))) (DoLet false false (PVar "reach") (EApp (EVar "fileReach") (EBinOp "++" (EVar "runtimeDecls") (EVar "kept")))) (DoExpr (EMatch (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "m")) (EApp (EApp (EApp (EVar "moduleGrantDiags") (EVar "reach")) (EVar "live")) (EVar "m")))) (EVar "modules")) (arm (PList) () (EApp (EVar "Ok") (EApp (EApp (EMethodRef "map") (EApp (EVar "mapScopedDeclBodies") (EApp (EApp (EApp (EVar "scanGrantSites") (EVar "reach")) (EApp (EVar "Ref") (EListLit))) (EVar "None")))) (EVar "kept")))) (arm (PVar "diags") () (EApp (EVar "Err") (EVar "diags")))))))
(DTypeSig false "keptFunNames" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "keptFunNames" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "keptFunNames" ((PCons (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "keptFunNames") (EVar "rest")) (EBinOp "::" (EVar "n") (EVar "acc"))))
(DFunDef false "keptFunNames" ((PCons (PCon "DAttrib" PWild (PVar "d")) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "keptFunNames") (EBinOp "::" (EVar "d") (EVar "rest"))) (EVar "acc")))
(DFunDef false "keptFunNames" ((PCons PWild (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "keptFunNames") (EVar "rest")) (EVar "acc")))
(DTypeSig false "isLiveDecl" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Decl") (TyCon "Bool"))))
(DFunDef false "isLiveDecl" ((PVar "live") (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild)) (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "live")))
(DFunDef false "isLiveDecl" ((PVar "live") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "isLiveDecl") (EVar "live")) (EVar "d")))
(DFunDef false "isLiveDecl" (PWild PWild) (EVar "True"))
(DTypeSig false "moduleGrantDiags" (TyFun (TyCon "Reach") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Decl"))) (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "TcDiag")))))))
(DFunDef false "moduleGrantDiags" ((PVar "reach") (PVar "live") (PTuple (PVar "mid") (PVar "decls"))) (EBlock (DoLet false false (PVar "sites") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EIf (EApp (EApp (EVar "isLiveDecl") (EVar "live")) (EVar "d")) (EApp (EApp (EVar "mapScopedDeclBodies") (EApp (EApp (EApp (EVar "scanGrantSites") (EVar "reach")) (EVar "sites")) (EVar "None"))) (EVar "d")) (EVar "d")))) (EVar "decls"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "site")) (EMatch (EVar "site") (arm (PTuple (PVar "loc") (PVar "name") (PVar "es")) () (ETuple (EVar "mid") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "TcDiag") (ELit (LString "T-WASM-FILE-GRANT"))) (ELit (LInt 1))) (EVar "loc")) (EApp (EApp (EVar "wasmFileGrantMsg") (EVar "name")) (EVar "es"))) (EVar "None")) (EVar "None"))))))) (EApp (EVar "reverseL") (EFieldAccess (EVar "sites") "value"))))))
(DTypeSig false "scanGrantSites" (TyFun (TyCon "Reach") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Expr")))))))
(DFunDef false "scanGrantSites" ((PVar "reach") (PVar "sites") PWild (PVar "bound") (PCon "ELoc" (PVar "l") (PVar "e"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EApp (EApp (EApp (EVar "scanGrantSites") (EVar "reach")) (EVar "sites")) (EApp (EVar "Some") (EVar "l"))) (EVar "bound")) (EVar "e"))))
(DFunDef false "scanGrantSites" ((PVar "reach") (PVar "sites") (PVar "around") (PVar "bound") (PAs "e" (PCon "EApp" PWild PWild))) (EBlock (DoLet false false (PTuple (PVar "head") (PVar "args")) (EApp (EApp (EVar "appSpine") (EVar "e")) (EListLit))) (DoExpr (EMatch (ETuple (EApp (EVar "headName") (EVar "head")) (EVar "args")) (arm (PTuple (PCon "Some" (PVar "name")) (PList (PVar "grant") (PCon "ELam" (PList (PCon "PWild")) (PVar "body")))) () (EIf (EBinOp "||" (EBinOp "==" (EVar "name") (ELit (LString "$withFileReadBound"))) (EBinOp "==" (EVar "name") (ELit (LString "$withFileWriteBound")))) (EBlock (DoLet false false PWild (EIf (EApp (EApp (EApp (EApp (EVar "bodyMayReachFile") (EVar "reach")) (EBinOp "==" (EVar "name") (ELit (LString "$withFileWriteBound")))) (EVar "bound")) (EVar "body")) (EMatch (EApp (EVar "grantElems") (EVar "grant")) (arm (PCon "Some" (PVar "es")) () (EIf (EApp (EVar "not") (EApp (EApp (EVar "wasmGrantConfined") (EVar "None")) (EVar "es"))) (EApp (EApp (EVar "setRef") (EVar "sites")) (EBinOp "::" (ETuple (EApp (EApp (EMethodRef "orElse") (EApp (EVar "leftLoc") (EVar "body"))) (EVar "around")) (EApp (EVar "calleeName") (EVar "head")) (EVar "es")) (EFieldAccess (EVar "sites") "value"))) (ELit LUnit))) (arm (PCon "None") () (ELit LUnit))) (ELit LUnit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "scanGrantSites") (EVar "reach")) (EVar "sites")) (EVar "around")) (EVar "bound")) (EVar "body")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanOrdinaryGrantSites") (EVar "reach")) (EVar "sites")) (EVar "around")) (EVar "bound")) (EVar "e")) (EVar "head")) (EVar "args")))) (arm PWild () (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "scanOrdinaryGrantSites") (EVar "reach")) (EVar "sites")) (EVar "around")) (EVar "bound")) (EVar "e")) (EVar "head")) (EVar "args")))))))
(DFunDef false "scanGrantSites" ((PVar "reach") (PVar "sites") (PVar "around") (PVar "bound") (PCon "ELet" (PVar "site") (PVar "recursive") (PVar "pat") (PVar "rhs") (PVar "body"))) (EBlock (DoLet false false (PVar "after") (EApp (EApp (EApp (EApp (EApp (EVar "letScope") (EVar "False")) (EVar "recursive")) (EVar "pat")) (EVar "rhs")) (EVar "bound"))) (DoLet false false (PVar "rhs2") (EApp (EApp (EApp (EApp (EApp (EVar "scanGrantSites") (EVar "reach")) (EVar "sites")) (EVar "around")) (EIf (EVar "recursive") (EVar "after") (EVar "bound"))) (EVar "rhs"))) (DoLet false false (PVar "body2") (EApp (EApp (EApp (EApp (EApp (EVar "scanGrantSites") (EVar "reach")) (EVar "sites")) (EApp (EApp (EMethodRef "orElse") (EApp (EVar "leftLoc") (EVar "rhs"))) (EVar "around"))) (EVar "after")) (EVar "body"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "site")) (EVar "recursive")) (EVar "pat")) (EVar "rhs2")) (EVar "body2")))))
(DFunDef false "scanGrantSites" ((PVar "reach") (PVar "sites") (PVar "around") (PVar "bound") (PVar "e")) (EApp (EApp (EApp (EVar "mapScopedChildren") (EVar "bound")) (EApp (EApp (EApp (EVar "scanGrantSites") (EVar "reach")) (EVar "sites")) (EVar "around"))) (EVar "e")))
(DTypeSig false "scanOrdinaryGrantSites" (TyFun (TyCon "Reach") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "String") (TyApp (TyCon "List") (TyCon "String"))))) (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyCon "Expr")))))))))
(DFunDef false "scanOrdinaryGrantSites" ((PVar "reach") (PVar "sites") (PVar "around") (PVar "bound") (PVar "spine") (PVar "head") (PVar "args")) (EBlock (DoLet false false PWild (EIf (EApp (EApp (EApp (EApp (EVar "mayReachFile") (EVar "reach")) (EVar "bound")) (EVar "head")) (EApp (EVar "listLen") (EVar "args"))) (EBlock (DoLet false false (PVar "path") (EApp (EApp (EVar "leafPath") (EVar "head")) (EVar "args"))) (DoLet false false (PVar "values") (EApp (EApp (EVar "filterList") (ELam ((PVar "a")) (EApp (EVar "isNone") (EApp (EVar "grantElems") (EVar "a"))))) (EVar "args"))) (DoLet false false (PVar "at") (EApp (EApp (EMethodRef "orElse") (EApp (EApp (EVar "findMap") (EVar "leftLoc")) (EVar "values"))) (EVar "around"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (EMatch (EApp (EVar "grantElems") (EVar "a")) (arm (PCon "Some" (PVar "es")) () (EIf (EApp (EApp (EVar "wasmGrantConfined") (EVar "path")) (EVar "es")) (ELit LUnit) (EApp (EApp (EVar "setRef") (EVar "sites")) (EBinOp "::" (ETuple (EVar "at") (EApp (EVar "calleeName") (EVar "head")) (EVar "es")) (EFieldAccess (EVar "sites") "value"))))) (arm (PCon "None") () (ELit LUnit))))) (EVar "args")))) (EListLit))) (DoLet false false (PVar "f") (EApp (EApp (EApp (EApp (EApp (EVar "scanGrantSites") (EVar "reach")) (EVar "sites")) (EVar "around")) (EVar "bound")) (EVar "head"))) (DoLet false false (PVar "xs") (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EVar "scanGrantSites") (EVar "reach")) (EVar "sites")) (EVar "around")) (EVar "bound"))) (EVar "args"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (EVar "EApp")) (EApp (EApp (EVar "keepSpineLoc") (EVar "spine")) (EVar "f"))) (EVar "xs")))))
(DData Private "Reach" () ((variant "Reach" (ConPos (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Int"))))) ())
(DTypeSig false "mayReachFile" (TyFun (TyCon "Reach") (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "mayReachFile" ((PVar "reach") (PVar "bound") (PVar "head") (PVar "argc")) (EBinOp "||" (EApp (EApp (EApp (EApp (EApp (EVar "callMayReachFile") (EVar "reach")) (EVar "False")) (EVar "bound")) (EVar "head")) (EVar "argc")) (EApp (EApp (EApp (EApp (EApp (EVar "callMayReachFile") (EVar "reach")) (EVar "True")) (EVar "bound")) (EVar "head")) (EVar "argc"))))
(DTypeSig false "callMayReachFile" (TyFun (TyCon "Reach") (TyFun (TyCon "Bool") (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "callMayReachFile" ((PVar "reach") (PVar "write") (PVar "bound") (PVar "head") (PVar "argc")) (EMatch (EApp (EApp (EVar "localHead") (EVar "bound")) (EVar "head")) (arm (PCon "Some" (PCon "LocalFunction" (PVar "ps") (PVar "body") (PVar "captured") (PVar "reads") (PVar "writes"))) () (EBinOp "||" (EBinOp ">" (EVar "argc") (EApp (EVar "valueParamCount") (EVar "ps"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "localMayReachFile") (EVar "reach")) (EVar "write")) (EVar "ps")) (EVar "body")) (EVar "captured")) (EIf (EVar "write") (EVar "writes") (EVar "reads"))))) (arm (PCon "Some" (PCon "UnknownBinding")) () (EVar "True")) (arm (PCon "None") () (EBlock (DoLet false false (PCon "Reach" (PVar "defined") (PVar "reads") (PVar "writes") (PVar "returns")) (EVar "reach")) (DoExpr (EBinOp "||" (EApp (EApp (EApp (EApp (EVar "unknownCall") (EVar "returns")) (EVar "bound")) (EVar "head")) (EVar "argc")) (EMatch (EApp (EVar "headName") (EVar "head")) (arm (PCon "Some" (PVar "n")) () (EIf (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "$withFileReadBound"))) (EBinOp "==" (EVar "n") (ELit (LString "$withFileWriteBound")))) (EVar "False") (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "n")) (EIf (EVar "write") (EVar "writes") (EVar "reads"))) (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "defined")))))) (arm (PCon "None") () (EVar "True")))))))))
(DTypeSig false "localMayReachFile" (TyFun (TyCon "Reach") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyCon "Scope") (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Bool"))) (TyCon "Bool"))))))))
(DFunDef false "localMayReachFile" ((PVar "reach") (PVar "write") (PVar "ps") (PVar "body") (PVar "captured") (PVar "cache")) (EMatch (EFieldAccess (EVar "cache") "value") (arm (PCon "Some" (PVar "found")) () (EVar "found")) (arm (PCon "None") () (EBlock (DoLet false false (PVar "found") (EApp (EApp (EApp (EApp (EVar "bodyMayReachFile") (EVar "reach")) (EVar "write")) (EApp (EApp (EVar "addPatScope") (EVar "ps")) (EVar "captured"))) (EVar "body"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "cache")) (EApp (EVar "Some") (EVar "found")))) (DoExpr (EVar "found"))))))
(DTypeSig false "bodyMayReachFile" (TyFun (TyCon "Reach") (TyFun (TyCon "Bool") (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Bool"))))))
(DFunDef false "bodyMayReachFile" ((PVar "reach") (PVar "write") (PVar "bound") (PAs "e" (PCon "EApp" PWild PWild))) (EBlock (DoLet false false (PTuple (PVar "head") (PVar "args")) (EApp (EApp (EVar "appSpine") (EVar "e")) (EListLit))) (DoExpr (EIf (EApp (EApp (EApp (EApp (EApp (EVar "knownNonFileCall") (EVar "reach")) (EVar "write")) (EVar "bound")) (EVar "head")) (EApp (EVar "listLen") (EVar "args"))) (EApp (EApp (EDictApp "any") (EApp (EApp (EApp (EVar "evalOnlyMayReachFile") (EVar "reach")) (EVar "write")) (EVar "bound"))) (EVar "args")) (EApp (EApp (EApp (EApp (EVar "bodyMayReachFileChildren") (EVar "reach")) (EVar "write")) (EVar "bound")) (EVar "e"))))))
(DFunDef false "bodyMayReachFile" ((PVar "reach") (PVar "write") (PVar "bound") (PVar "e")) (EApp (EApp (EApp (EApp (EVar "bodyMayReachFileChildren") (EVar "reach")) (EVar "write")) (EVar "bound")) (EVar "e")))
(DTypeSig false "knownNonFileCall" (TyFun (TyCon "Reach") (TyFun (TyCon "Bool") (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyCon "Bool")))))))
(DFunDef false "knownNonFileCall" ((PVar "reach") (PVar "write") (PVar "bound") (PVar "head") (PVar "argc")) (EApp (EVar "not") (EApp (EApp (EApp (EApp (EApp (EVar "callMayReachFile") (EVar "reach")) (EVar "write")) (EVar "bound")) (EVar "head")) (EVar "argc"))))
(DTypeSig false "evalOnlyMayReachFile" (TyFun (TyCon "Reach") (TyFun (TyCon "Bool") (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Bool"))))))
(DFunDef false "evalOnlyMayReachFile" (PWild PWild PWild (PCon "ELam" PWild PWild)) (EVar "False"))
(DFunDef false "evalOnlyMayReachFile" ((PVar "reach") (PVar "write") (PVar "bound") (PAs "e" (PCon "EApp" PWild PWild))) (EApp (EApp (EApp (EApp (EVar "bodyMayReachFile") (EVar "reach")) (EVar "write")) (EVar "bound")) (EVar "e")))
(DFunDef false "evalOnlyMayReachFile" ((PVar "reach") (PVar "write") (PVar "bound") (PVar "e")) (EBlock (DoLet false false (PVar "found") (EApp (EVar "Ref") (EVar "False"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "mapScopedChildren") (EVar "bound")) (ELam ((PVar "scope") (PVar "child")) (EBlock (DoLet false false PWild (EIf (EApp (EApp (EApp (EApp (EVar "evalOnlyMayReachFile") (EVar "reach")) (EVar "write")) (EVar "scope")) (EVar "child")) (EApp (EApp (EVar "setRef") (EVar "found")) (EVar "True")) (ELit LUnit))) (DoExpr (EVar "child"))))) (EVar "e"))) (DoExpr (EFieldAccess (EVar "found") "value"))))
(DTypeSig false "bodyMayReachFileChildren" (TyFun (TyCon "Reach") (TyFun (TyCon "Bool") (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Bool"))))))
(DFunDef false "bodyMayReachFileChildren" ((PVar "reach") (PVar "write") (PVar "bound") (PVar "e")) (EBlock (DoLet false false (PVar "found") (EApp (EVar "Ref") (EVar "False"))) (DoLet false false PWild (EApp (EApp (EApp (EVar "mapScopedChildren") (EVar "bound")) (ELam ((PVar "scope") (PVar "child")) (EBlock (DoLet false false PWild (EIf (EApp (EApp (EApp (EApp (EVar "bodyMayReachFile") (EVar "reach")) (EVar "write")) (EVar "scope")) (EVar "child")) (EApp (EApp (EVar "setRef") (EVar "found")) (EVar "True")) (ELit LUnit))) (DoExpr (EVar "child"))))) (EVar "e"))) (DoExpr (EBinOp "||" (EFieldAccess (EVar "found") "value") (EMatch (EVar "e") (arm (PCon "EApp" PWild PWild) () (EBlock (DoLet false false (PTuple (PVar "head") (PVar "args")) (EApp (EApp (EVar "appSpine") (EVar "e")) (EListLit))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "callMayReachFile") (EVar "reach")) (EVar "write")) (EVar "bound")) (EVar "head")) (EApp (EVar "listLen") (EVar "args")))))) (arm PWild () (EVar "False")))))))
(DTypeSig false "localHead" (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "LocalBinding")))))
(DFunDef false "localHead" ((PVar "bound") (PVar "head")) (EMatch (EApp (EVar "headRawName") (EVar "head")) (arm (PCon "Some" (PVar "n")) () (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "bound"))) (arm (PCon "None") () (EVar "None"))))
(DTypeSig false "headName" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "headName" ((PVar "e")) (EApp (EApp (EMethodRef "map") (EVar "unmangled")) (EApp (EVar "headRawName") (EVar "e"))))
(DTypeSig false "headRawName" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "headRawName" ((PCon "EVar" (PVar "n"))) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "headRawName" ((PCon "EDictAt" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "headRawName" ((PCon "EMethodAt" (PVar "n") PWild (PVar "ev"))) (EBlock (DoLet false false (PTuple PWild PWild (PVar "route") PWild PWild) (EApp (EVar "evMethodRoutes") (EVar "ev"))) (DoExpr (EApp (EVar "Some") (EMatch (EVar "route") (arm (PCon "RLocal" (PVar "sym") PWild) () (EIf (EBinOp "==" (EVar "sym") (ELit (LString ""))) (EVar "n") (EVar "sym"))) (arm PWild () (EVar "n")))))))
(DFunDef false "headRawName" ((PCon "EVarAt" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "headRawName" ((PCon "EVarId" (PVar "n") PWild)) (EApp (EVar "Some") (EVar "n")))
(DFunDef false "headRawName" (PWild) (EVar "None"))
(DData Private "LocalBinding" () ((variant "UnknownBinding" (ConPos)) (variant "LocalFunction" (ConPos (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr") (TyApp (TyCon "OrdMap") (TyCon "LocalBinding")) (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Bool"))) (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyCon "Bool")))))) ())
(DTypeAlias false "Scope" () (TyApp (TyCon "OrdMap") (TyCon "LocalBinding")))
(DTypeSig false "localBinding" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyFun (TyCon "Scope") (TyCon "LocalBinding")))))
(DFunDef false "localBinding" ((PVar "ps") (PVar "body") (PVar "captured")) (EApp (EApp (EApp (EApp (EApp (EVar "LocalFunction") (EVar "ps")) (EVar "body")) (EVar "captured")) (EApp (EVar "Ref") (EVar "None"))) (EApp (EVar "Ref") (EVar "None"))))
(DTypeSig false "addNamesScope" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Scope") (TyCon "Scope"))))
(DFunDef false "addNamesScope" ((PVar "names") (PVar "bound")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "n")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "UnknownBinding")) (EVar "m")))) (EVar "bound")) (EVar "names")))
(DTypeSig false "addPatScope" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Scope") (TyCon "Scope"))))
(DFunDef false "addPatScope" ((PVar "ps") (PVar "bound")) (EApp (EApp (EVar "addNamesScope") (EApp (EApp (EDictApp "flatMap") (EVar "patBoundNames")) (EVar "ps"))) (EVar "bound")))
(DTypeSig false "letScope" (TyFun (TyCon "Bool") (TyFun (TyCon "Bool") (TyFun (TyCon "Pat") (TyFun (TyCon "Expr") (TyFun (TyCon "Scope") (TyCon "Scope")))))))
(DFunDef false "letScope" ((PCon "False") (PVar "recursive") (PCon "PVar" (PVar "n") PWild) (PVar "rhs") (PVar "bound")) (EBlock (DoLet false false (PVar "captured") (EIf (EVar "recursive") (EApp (EApp (EVar "addNamesScope") (EListLit (EVar "n"))) (EVar "bound")) (EVar "bound"))) (DoExpr (EMatch (EApp (EApp (EVar "localFunction") (EVar "captured")) (EVar "rhs")) (arm (PCon "Some" (PVar "binding")) () (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "binding")) (EVar "bound"))) (arm (PCon "None") () (EApp (EApp (EVar "addNamesScope") (EListLit (EVar "n"))) (EVar "bound")))))))
(DFunDef false "letScope" (PWild PWild (PVar "pat") PWild (PVar "bound")) (EApp (EApp (EVar "addPatScope") (EListLit (EVar "pat"))) (EVar "bound")))
(DTypeSig false "localFunction" (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "LocalBinding")))))
(DFunDef false "localFunction" ((PVar "bound") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EVar "localFunction") (EVar "bound")) (EVar "e")))
(DFunDef false "localFunction" ((PVar "bound") (PCon "EAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "localFunction") (EVar "bound")) (EVar "e")))
(DFunDef false "localFunction" ((PVar "bound") (PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EApp (EVar "localFunction") (EVar "bound")) (EVar "e")))
(DFunDef false "localFunction" ((PVar "bound") (PCon "ELet" PWild (PCon "False") (PVar "pat") (PVar "rhs") (PVar "body"))) (EApp (EApp (EVar "localFunction") (EApp (EApp (EApp (EApp (EApp (EVar "letScope") (EVar "False")) (EVar "False")) (EVar "pat")) (EVar "rhs")) (EVar "bound"))) (EVar "body")))
(DFunDef false "localFunction" ((PVar "bound") (PCon "ELam" (PVar "ps") (PVar "body"))) (EApp (EVar "Some") (EApp (EApp (EApp (EVar "localBinding") (EVar "ps")) (EVar "body")) (EVar "bound"))))
(DFunDef false "localFunction" (PWild PWild) (EVar "None"))
(DTypeSig false "localGroupScope" (TyFun (TyApp (TyCon "List") (TyCon "LetBind")) (TyFun (TyCon "Scope") (TyCon "Scope"))))
(DFunDef false "localGroupScope" ((PVar "binds") (PVar "bound")) (EBlock (DoLet false false (PVar "captured") (EApp (EApp (EVar "addNamesScope") (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (EMatch (EVar "b") (arm (PCon "LetBind" (PVar "n") PWild PWild) () (EVar "n"))))) (EVar "binds"))) (EVar "bound"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "b")) (EMatch (EVar "b") (arm (PCon "LetBind" (PVar "n") (PList (PCon "FunClause" (PVar "ps") (PVar "body"))) PWild) () (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EApp (EApp (EApp (EVar "localBinding") (EVar "ps")) (EVar "body")) (EVar "captured"))) (EVar "m"))) (arm (PCon "LetBind" PWild PWild PWild) () (EVar "m"))))) (EVar "captured")) (EVar "binds")))))
(DTypeSig false "mapScopedDeclBodies" (TyFun (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Expr"))) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "mapScopedDeclBodies" ((PVar "f") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "body") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EVar "ps")) (EApp (EApp (EVar "f") (EApp (EApp (EVar "addPatScope") (EVar "ps")) (EVar "omEmpty"))) (EVar "body"))) (EVar "site")))
(DFunDef false "mapScopedDeclBodies" ((PVar "f") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "mapScopedLetBind") (EVar "f")) (EVar "omEmpty"))) (EVar "binds"))))
(DFunDef false "mapScopedDeclBodies" ((PVar "f") (PAs "d" (PRec "DImpl" ((rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "body")) () (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EVar "ps")) (EApp (EApp (EVar "f") (EApp (EApp (EVar "addPatScope") (EVar "ps")) (EVar "omEmpty"))) (EVar "body"))))))) (EVar "methods"))))))
(DFunDef false "mapScopedDeclBodies" ((PVar "f") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PVar "def") (PVar "loc")) () (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "dm")) (EMatch (EVar "dm") (arm (PCon "MethodDefault" (PVar "ps") (PVar "body")) () (EApp (EApp (EVar "MethodDefault") (EVar "ps")) (EApp (EApp (EVar "f") (EApp (EApp (EVar "addPatScope") (EVar "ps")) (EVar "omEmpty"))) (EVar "body"))))))) (EVar "def"))) (EVar "loc")))))) (EVar "methods"))))))
(DFunDef false "mapScopedDeclBodies" ((PVar "f") (PCon "DProp" (PVar "pub") (PVar "n") (PVar "params") (PVar "body"))) (EBlock (DoLet false false (PVar "bound") (EApp (EApp (EVar "addNamesScope") (EApp (EApp (EMethodRef "map") (ELam ((PVar "p")) (EMatch (EVar "p") (arm (PCon "PropParam" (PVar "name") PWild PWild) () (EVar "name"))))) (EVar "params"))) (EVar "omEmpty"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "n")) (EVar "params")) (EApp (EApp (EVar "f") (EVar "bound")) (EVar "body"))))))
(DFunDef false "mapScopedDeclBodies" ((PVar "f") (PCon "DTest" (PVar "pub") (PVar "n") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "n")) (EApp (EApp (EVar "f") (EVar "omEmpty")) (EVar "body"))))
(DFunDef false "mapScopedDeclBodies" ((PVar "f") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "mapScopedDeclBodies") (EVar "f")) (EVar "d"))))
(DFunDef false "mapScopedDeclBodies" (PWild (PVar "d")) (EVar "d"))
(DTypeSig false "mapScopedLetBind" (TyFun (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Expr"))) (TyFun (TyCon "Scope") (TyFun (TyCon "LetBind") (TyCon "LetBind")))))
(DFunDef false "mapScopedLetBind" ((PVar "f") (PVar "bound") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site"))) (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (EMatch (EVar "c") (arm (PCon "FunClause" (PVar "ps") (PVar "body")) () (EApp (EApp (EVar "FunClause") (EVar "ps")) (EApp (EApp (EVar "f") (EApp (EApp (EVar "addPatScope") (EVar "ps")) (EVar "bound"))) (EVar "body"))))))) (EVar "clauses"))) (EVar "site")))
(DTypeSig false "mapScopedChildren" (TyFun (TyCon "Scope") (TyFun (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Expr"))) (TyFun (TyCon "Expr") (TyCon "Expr")))))
(DFunDef false "mapScopedChildren" ((PVar "bound") (PVar "f") (PCon "ELam" (PVar "ps") (PVar "body"))) (EApp (EApp (EVar "ELam") (EVar "ps")) (EApp (EApp (EVar "f") (EApp (EApp (EVar "addPatScope") (EVar "ps")) (EVar "bound"))) (EVar "body"))))
(DFunDef false "mapScopedChildren" ((PVar "bound") (PVar "f") (PCon "ELet" (PVar "site") (PVar "recursive") (PVar "pat") (PVar "rhs") (PVar "body"))) (EBlock (DoLet false false (PVar "after") (EApp (EApp (EApp (EApp (EApp (EVar "letScope") (EVar "False")) (EVar "recursive")) (EVar "pat")) (EVar "rhs")) (EVar "bound"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "site")) (EVar "recursive")) (EVar "pat")) (EApp (EApp (EVar "f") (EIf (EVar "recursive") (EVar "after") (EVar "bound"))) (EVar "rhs"))) (EApp (EApp (EVar "f") (EVar "after")) (EVar "body"))))))
(DFunDef false "mapScopedChildren" ((PVar "bound") (PVar "f") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "after") (EApp (EApp (EVar "localGroupScope") (EVar "binds")) (EVar "bound"))) (DoExpr (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EMethodRef "map") (EApp (EApp (EVar "mapScopedLetBind") (EVar "f")) (EVar "after"))) (EVar "binds"))) (EApp (EApp (EVar "f") (EVar "after")) (EVar "body"))))))
(DFunDef false "mapScopedChildren" ((PVar "bound") (PVar "f") (PCon "EMatch" (PVar "e") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EVar "f") (EVar "bound")) (EVar "e"))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (EMatch (EVar "a") (arm (PCon "Arm" (PVar "pat") (PVar "guards") (PVar "body")) () (EBlock (DoLet false false (PTuple (PVar "guards2") (PVar "after")) (EApp (EApp (EApp (EVar "mapScopedGuards") (EVar "f")) (EApp (EApp (EVar "addPatScope") (EListLit (EVar "pat"))) (EVar "bound"))) (EVar "guards"))) (DoExpr (EApp (EApp (EApp (EVar "Arm") (EVar "pat")) (EVar "guards2")) (EApp (EApp (EVar "f") (EVar "after")) (EVar "body"))))))))) (EVar "arms"))))
(DFunDef false "mapScopedChildren" ((PVar "bound") (PVar "f") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (EMatch (EVar "a") (arm (PCon "GuardArm" (PVar "guards") (PVar "body")) () (EBlock (DoLet false false (PTuple (PVar "guards2") (PVar "after")) (EApp (EApp (EApp (EVar "mapScopedGuards") (EVar "f")) (EVar "bound")) (EVar "guards"))) (DoExpr (EApp (EApp (EVar "GuardArm") (EVar "guards2")) (EApp (EApp (EVar "f") (EVar "after")) (EVar "body"))))))))) (EVar "arms"))))
(DFunDef false "mapScopedChildren" ((PVar "bound") (PVar "f") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EApp (EVar "mapScopedStmts") (EVar "f")) (EVar "bound")) (EVar "stmts"))))
(DFunDef false "mapScopedChildren" ((PVar "bound") (PVar "f") (PCon "EDo" (PVar "label") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "label")) (EApp (EApp (EApp (EVar "mapScopedStmts") (EVar "f")) (EVar "bound")) (EVar "stmts"))))
(DFunDef false "mapScopedChildren" ((PVar "bound") (PVar "f") (PVar "e")) (EApp (EApp (EVar "mapChildren") (EApp (EVar "f") (EVar "bound"))) (EVar "e")))
(DTypeSig false "mapScopedGuards" (TyFun (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Expr"))) (TyFun (TyCon "Scope") (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyTuple (TyApp (TyCon "List") (TyCon "Guard")) (TyCon "Scope"))))))
(DFunDef false "mapScopedGuards" (PWild (PVar "bound") (PList)) (ETuple (EListLit) (EVar "bound")))
(DFunDef false "mapScopedGuards" ((PVar "f") (PVar "bound") (PCons (PCon "GBool" (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EVar "f") (EVar "bound")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "after")) (EApp (EApp (EApp (EVar "mapScopedGuards") (EVar "f")) (EVar "bound")) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EVar "GBool") (EVar "e2")) (EVar "rest2")) (EVar "after")))))
(DFunDef false "mapScopedGuards" ((PVar "f") (PVar "bound") (PCons (PCon "GBind" (PVar "pat") (PVar "e")) (PVar "rest"))) (EBlock (DoLet false false (PVar "e2") (EApp (EApp (EVar "f") (EVar "bound")) (EVar "e"))) (DoLet false false (PTuple (PVar "rest2") (PVar "after")) (EApp (EApp (EApp (EVar "mapScopedGuards") (EVar "f")) (EApp (EApp (EVar "addPatScope") (EListLit (EVar "pat"))) (EVar "bound"))) (EVar "rest"))) (DoExpr (ETuple (EBinOp "::" (EApp (EApp (EVar "GBind") (EVar "pat")) (EVar "e2")) (EVar "rest2")) (EVar "after")))))
(DTypeSig false "mapScopedStmts" (TyFun (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Expr"))) (TyFun (TyCon "Scope") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyApp (TyCon "List") (TyCon "DoStmt"))))))
(DFunDef false "mapScopedStmts" (PWild PWild (PList)) (EListLit))
(DFunDef false "mapScopedStmts" ((PVar "f") (PVar "bound") (PCons (PCon "DoExpr" (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EVar "DoExpr") (EApp (EApp (EVar "f") (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "mapScopedStmts") (EVar "f")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "mapScopedStmts" ((PVar "f") (PVar "bound") (PCons (PCon "DoBind" (PVar "pat") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoBind") (EVar "pat")) (EApp (EApp (EVar "f") (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "mapScopedStmts") (EVar "f")) (EApp (EApp (EVar "addPatScope") (EListLit (EVar "pat"))) (EVar "bound"))) (EVar "rest"))))
(DFunDef false "mapScopedStmts" ((PVar "f") (PVar "bound") (PCons (PCon "DoLet" (PVar "mutable") (PVar "recursive") (PVar "pat") (PVar "e") (PVar "site")) (PVar "rest"))) (EBlock (DoLet false false (PVar "after") (EApp (EApp (EApp (EApp (EApp (EVar "letScope") (EVar "mutable")) (EVar "recursive")) (EVar "pat")) (EVar "e")) (EVar "bound"))) (DoExpr (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "mutable")) (EVar "recursive")) (EVar "pat")) (EApp (EApp (EVar "f") (EIf (EVar "recursive") (EVar "after") (EVar "bound"))) (EVar "e"))) (EVar "site")) (EApp (EApp (EApp (EVar "mapScopedStmts") (EVar "f")) (EVar "after")) (EVar "rest"))))))
(DFunDef false "mapScopedStmts" ((PVar "f") (PVar "bound") (PCons (PCon "DoAssign" (PVar "n") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EVar "DoAssign") (EVar "n")) (EApp (EApp (EVar "f") (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "mapScopedStmts") (EVar "f")) (EVar "bound")) (EVar "rest"))))
(DFunDef false "mapScopedStmts" ((PVar "f") (PVar "bound") (PCons (PCon "DoFieldAssign" (PVar "n") (PVar "fields") (PVar "e")) (PVar "rest"))) (EBinOp "::" (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "n")) (EVar "fields")) (EApp (EApp (EVar "f") (EVar "bound")) (EVar "e"))) (EApp (EApp (EApp (EVar "mapScopedStmts") (EVar "f")) (EVar "bound")) (EVar "rest"))))
(DTypeSig false "fileReach" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Reach")))
(DFunDef false "fileReach" ((PVar "decls")) (EBlock (DoLet false false (PVar "bindings") (EApp (EApp (EDictApp "flatMap") (EVar "declBindingBodies")) (EVar "decls"))) (DoLet false false (PVar "aliases") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EDictApp "flatMap") (EVar "aliasNames")) (EVar "decls"))) (EVar "omEmpty"))) (DoLet false false (PVar "noRead") (EApp (EApp (EApp (EApp (EVar "declaredNoFile") (EVar "aliases")) (EVar "False")) (EVar "decls")) (EVar "bindings"))) (DoLet false false (PVar "noWrite") (EApp (EApp (EApp (EApp (EVar "declaredNoFile") (EVar "aliases")) (EVar "True")) (EVar "decls")) (EVar "bindings"))) (DoLet false false (PVar "returns") (EApp (EVar "returnedBoundaries") (EApp (EApp (EVar "filterList") (ELam ((PTuple (PVar "n") PWild PWild)) (EApp (EVar "not") (EBinOp "&&" (EApp (EApp (EVar "optionOr") (EVar "False")) (EApp (EApp (EVar "omLookup") (EApp (EVar "unmangled") (EVar "n"))) (EVar "noRead"))) (EApp (EApp (EVar "optionOr") (EVar "False")) (EApp (EApp (EVar "omLookup") (EApp (EVar "unmangled") (EVar "n"))) (EVar "noWrite"))))))) (EVar "bindings")))) (DoLet false false (PVar "users") (EApp (EVar "Ref") (EVar "omEmpty"))) (DoLet false false (PVar "defined") (EApp (EVar "Ref") (EVar "omEmpty"))) (DoLet false false PWild (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EApp (EApp (EVar "declDefines") (EVar "defined")) (EVar "d")))) (EVar "decls"))) (DoLet false false PWild (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "n") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "bindingRefs") (EVar "users")) (EVar "defined")) (EVar "returns")) (EVar "n")) (EVar "ps")) (EVar "body")))) (EVar "bindings"))) (DoLet false false (PVar "reads") (EListLit (ELit (LString "readFile")) (ELit (LString "fileExists")) (ELit (LString "canonicalizePath")) (ELit (LString "readFileBytes")))) (DoLet false false (PVar "writes") (EListLit (ELit (LString "writeFileBytes")))) (DoExpr (EApp (EApp (EApp (EApp (EVar "Reach") (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "wasmFileGrantExterns"))) (EFieldAccess (EVar "defined") "value"))) (EApp (EApp (EApp (EApp (EVar "spread") (EFieldAccess (EVar "users") "value")) (EVar "noRead")) (EVar "reads")) (EApp (EApp (EVar "omFromNames") (EVar "reads")) (EVar "omEmpty")))) (EApp (EApp (EApp (EApp (EVar "spread") (EFieldAccess (EVar "users") "value")) (EVar "noWrite")) (EVar "writes")) (EApp (EApp (EVar "omFromNames") (EVar "writes")) (EVar "omEmpty")))) (EVar "returns")))))
(DTypeSig false "unknownCall" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyFun (TyCon "Int") (TyCon "Bool"))))))
(DFunDef false "unknownCall" ((PVar "returns") (PVar "bound") (PVar "head") (PVar "argc")) (EMatch (EApp (EApp (EVar "localHead") (EVar "bound")) (EVar "head")) (arm (PCon "Some" (PCon "LocalFunction" (PVar "ps") PWild PWild PWild PWild)) () (EBinOp ">" (EVar "argc") (EApp (EVar "valueParamCount") (EVar "ps")))) (arm (PCon "Some" (PCon "UnknownBinding")) () (EVar "True")) (arm (PCon "None") () (EMatch (EApp (EVar "headRawName") (EVar "head")) (arm (PCon "Some" (PVar "n")) () (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "returns")) (arm (PCon "Some" (PVar "boundary")) () (EBinOp ">" (EVar "argc") (EVar "boundary"))) (arm (PCon "None") () (EVar "False")))) (arm (PCon "None") () (EVar "True"))))))
(DTypeSig false "valueParamCount" (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Int")))
(DFunDef false "valueParamCount" ((PCons (PCon "PVar" (PVar "n") PWild) (PVar "rest"))) (EIf (EApp (EApp (EVar "startsWith") (ELit (LString "$dict"))) (EVar "n")) (EApp (EVar "valueParamCount") (EVar "rest")) (EApp (EVar "__fallthrough__") (ELit LUnit))))
(DFunDef false "valueParamCount" ((PVar "ps")) (EApp (EVar "listLen") (EVar "ps")))
(DTypeSig false "declBindingBodies" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "declBindingBodies" ((PCon "DFunDef" PWild (PVar "n") (PVar "ps") (PVar "body") PWild)) (EListLit (ETuple (EVar "n") (EVar "ps") (EVar "body"))))
(DFunDef false "declBindingBodies" ((PCon "DLetGroup" PWild (PVar "binds"))) (EApp (EApp (EDictApp "flatMap") (EVar "letBindBodies")) (EVar "binds")))
(DFunDef false "declBindingBodies" ((PRec "DImpl" ((rf "methods" None)) true)) (EApp (EApp (EMethodRef "map") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "body")) () (ETuple (EVar "n") (EVar "ps") (EVar "body")))))) (EVar "methods")))
(DFunDef false "declBindingBodies" ((PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "m")) (EMatch (EVar "m") (arm (PCon "IfaceMethod" (PVar "n") PWild (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "body"))) PWild) () (EListLit (ETuple (EVar "n") (EVar "ps") (EVar "body")))) (arm (PCon "IfaceMethod" PWild PWild (PCon "None") PWild) () (EListLit))))) (EVar "methods")))
(DFunDef false "declBindingBodies" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "declBindingBodies") (EVar "d")))
(DFunDef false "declBindingBodies" (PWild) (EListLit))
(DTypeSig false "letBindBodies" (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr")))))
(DFunDef false "letBindBodies" ((PCon "LetBind" (PVar "n") (PVar "clauses") PWild)) (EApp (EApp (EMethodRef "map") (ELam ((PVar "c")) (EMatch (EVar "c") (arm (PCon "FunClause" (PVar "ps") (PVar "body")) () (ETuple (EVar "n") (EVar "ps") (EVar "body")))))) (EVar "clauses")))
(DTypeSig false "returnedBoundaries" (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "OrdMap") (TyCon "Int"))))
(DFunDef false "returnedBoundaries" ((PVar "bindings")) (EBlock (DoLet false false (PVar "seeds") (EApp (EVar "Ref") (EListLit))) (DoLet false false (PVar "deps") (EApp (EVar "Ref") (EVar "omEmpty"))) (DoLet false false PWild (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "n") (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "n")) (EApp (EVar "valueParamCount") (EVar "ps"))) (EApp (EApp (EVar "addPatScope") (EVar "ps")) (EVar "omEmpty"))) (EVar "body")))) (EVar "bindings"))) (DoExpr (EApp (EApp (EApp (EVar "relaxReturns") (EFieldAccess (EVar "deps") "value")) (EFieldAccess (EVar "seeds") "value")) (EVar "omEmpty")))))
(DTypeSig false "relaxReturns" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Int")))) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyApp (TyCon "OrdMap") (TyCon "Int"))))))
(DFunDef false "relaxReturns" (PWild (PList) (PVar "seen")) (EVar "seen"))
(DFunDef false "relaxReturns" ((PVar "deps") (PCons (PTuple (PVar "n") (PVar "boundary")) (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "settled") (EMatch (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "seen")) (arm (PCon "Some" (PVar "old")) () (EBinOp "<=" (EVar "old") (EVar "boundary"))) (arm (PCon "None") () (EVar "False")))) (DoExpr (EIf (EVar "settled") (EApp (EApp (EApp (EVar "relaxReturns") (EVar "deps")) (EVar "rest")) (EVar "seen")) (EBlock (DoLet false false (PVar "next") (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "owner") (PVar "base") (PVar "supplied"))) (ETuple (EVar "owner") (EBinOp "+" (EVar "base") (EApp (EApp (EMethodRef "max") (ELit (LInt 0))) (EBinOp "-" (EVar "boundary") (EVar "supplied"))))))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "deps"))))) (DoExpr (EApp (EApp (EApp (EVar "relaxReturns") (EVar "deps")) (EBinOp "++" (EVar "next") (EVar "rest"))) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EVar "boundary")) (EVar "seen")))))))))
(DTypeSig false "tailReturns" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Int"))))) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Unit"))))))))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "ELoc" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "e")))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "EAnnot" (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "e")))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "EHeadAnnot" (PVar "e") PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "e")))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "EDoOrigin" PWild (PVar "e"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "e")))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "ELam" (PVar "ps") (PVar "body"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EBinOp "+" (EVar "base") (EApp (EVar "valueParamCount") (EVar "ps")))) (EApp (EApp (EVar "addPatScope") (EVar "ps")) (EVar "bound"))) (EVar "body")))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "ELet" PWild PWild (PVar "pat") PWild (PVar "body"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EApp (EApp (EVar "addPatScope") (EListLit (EVar "pat"))) (EVar "bound"))) (EVar "body")))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "ELetGroup" (PVar "binds") (PVar "body"))) (EBlock (DoLet false false (PVar "after") (EApp (EApp (EVar "addNamesScope") (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (EMatch (EVar "b") (arm (PCon "LetBind" (PVar "n") PWild PWild) () (EVar "n"))))) (EVar "binds"))) (EVar "bound"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "after")) (EVar "body")))))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "EIf" PWild (PVar "yes") (PVar "no"))) (EBlock (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "yes"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "no")))))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "EMatch" PWild (PVar "arms"))) (EBlock (DoLet false false PWild (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (EMatch (EVar "a") (arm (PCon "Arm" (PVar "pat") (PVar "guards") (PVar "body")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EApp (EApp (EVar "guardScope") (EVar "guards")) (EApp (EApp (EVar "addPatScope") (EListLit (EVar "pat"))) (EVar "bound")))) (EVar "body")))))) (EVar "arms"))) (DoExpr (ELit LUnit))))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "EGuards" (PVar "arms"))) (EBlock (DoLet false false PWild (EApp (EApp (EMethodRef "map") (ELam ((PVar "a")) (EMatch (EVar "a") (arm (PCon "GuardArm" (PVar "guards") (PVar "body")) () (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EApp (EApp (EVar "guardScope") (EVar "guards")) (EVar "bound"))) (EVar "body")))))) (EVar "arms"))) (DoExpr (ELit LUnit))))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "EBlock" (PVar "stmts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailStmtReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "stmts")))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCon "EDo" PWild (PVar "stmts"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailStmtReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "stmts")))
(DFunDef false "tailReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PVar "e")) (EBlock (DoLet false false (PTuple (PVar "head") (PVar "args")) (EApp (EApp (EVar "appSpine") (EVar "e")) (EListLit))) (DoExpr (EMatch (ETuple (EApp (EVar "headName") (EVar "head")) (EVar "args")) (arm (PTuple (PCon "Some" (PVar "n")) (PList PWild (PCon "ELam" (PList (PCon "PWild")) (PVar "body")))) ((GBool (EBinOp "||" (EBinOp "==" (EVar "n") (ELit (LString "$withFileReadBound"))) (EBinOp "==" (EVar "n") (ELit (LString "$withFileWriteBound")))))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "body"))) (arm PWild () (EMatch (EApp (EVar "headRawName") (EVar "head")) (arm (PCon "Some" (PVar "raw")) () (EIf (EApp (EApp (EVar "omHasKey") (EVar "raw")) (EVar "bound")) (EApp (EApp (EVar "setRef") (EVar "seeds")) (EBinOp "::" (ETuple (EVar "owner") (EVar "base")) (EFieldAccess (EVar "seeds") "value"))) (EApp (EApp (EVar "setRef") (EVar "deps")) (EApp (EApp (EApp (EVar "omInsert") (EVar "raw")) (EBinOp "::" (ETuple (EVar "owner") (EVar "base") (EApp (EVar "listLen") (EVar "args"))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "raw")) (EFieldAccess (EVar "deps") "value"))))) (EFieldAccess (EVar "deps") "value"))))) (arm (PCon "None") () (EMatch (EVar "e") (arm (PCon "ELit" PWild) () (ELit LUnit)) (arm (PCon "ETuple" PWild) () (ELit LUnit)) (arm (PCon "EListLit" PWild) () (ELit LUnit)) (arm (PCon "EArrayLit" PWild) () (ELit LUnit)) (arm (PCon "ERecordCreate" PWild PWild) () (ELit LUnit)) (arm PWild () (EApp (EApp (EVar "setRef") (EVar "seeds")) (EBinOp "::" (ETuple (EVar "owner") (EVar "base")) (EFieldAccess (EVar "seeds") "value"))))))))))))
(DTypeSig false "guardScope" (TyFun (TyApp (TyCon "List") (TyCon "Guard")) (TyFun (TyCon "Scope") (TyCon "Scope"))))
(DFunDef false "guardScope" ((PList) (PVar "bound")) (EVar "bound"))
(DFunDef false "guardScope" ((PCons (PCon "GBind" (PVar "pat") PWild) (PVar "rest")) (PVar "bound")) (EApp (EApp (EVar "guardScope") (EVar "rest")) (EApp (EApp (EVar "addPatScope") (EListLit (EVar "pat"))) (EVar "bound"))))
(DFunDef false "guardScope" ((PCons PWild (PVar "rest")) (PVar "bound")) (EApp (EApp (EVar "guardScope") (EVar "rest")) (EVar "bound")))
(DTypeSig false "tailStmtReturns" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int") (TyCon "Int"))))) (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyCon "Scope") (TyFun (TyApp (TyCon "List") (TyCon "DoStmt")) (TyCon "Unit"))))))))
(DFunDef false "tailStmtReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PList (PCon "DoExpr" (PVar "e")))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "e")))
(DFunDef false "tailStmtReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCons (PCon "DoBind" (PVar "pat") PWild) (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailStmtReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EApp (EApp (EVar "addPatScope") (EListLit (EVar "pat"))) (EVar "bound"))) (EVar "rest")))
(DFunDef false "tailStmtReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCons (PCon "DoLet" PWild PWild (PVar "pat") PWild PWild) (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailStmtReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EApp (EApp (EVar "addPatScope") (EListLit (EVar "pat"))) (EVar "bound"))) (EVar "rest")))
(DFunDef false "tailStmtReturns" ((PVar "seeds") (PVar "deps") (PVar "owner") (PVar "base") (PVar "bound") (PCons PWild (PVar "rest"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "tailStmtReturns") (EVar "seeds")) (EVar "deps")) (EVar "owner")) (EVar "base")) (EVar "bound")) (EVar "rest")))
(DFunDef false "tailStmtReturns" (PWild PWild PWild PWild PWild (PList)) (ELit LUnit))
(DTypeSig false "aliasNames" (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "aliasNames" ((PRec "DTypeAlias" ((rf "tyAliasName" (PVar "n"))) false)) (EListLit (EVar "n") (EApp (EVar "unmangled") (EVar "n"))))
(DFunDef false "aliasNames" ((PCon "DAttrib" PWild (PVar "d"))) (EApp (EVar "aliasNames") (EVar "d")))
(DFunDef false "aliasNames" (PWild) (EListLit))
(DTypeSig false "declaredNoFile" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "Pat")) (TyCon "Expr"))) (TyApp (TyCon "OrdMap") (TyCon "Bool")))))))
(DFunDef false "declaredNoFile" ((PVar "aliases") (PVar "write") (PVar "decls") (PVar "bindings")) (EBlock (DoLet false false (PVar "ordinary") (EApp (EApp (EApp (EMethodRef "fold") (EApp (EApp (EVar "signatureNoFile") (EVar "aliases")) (EVar "write"))) (EVar "omEmpty")) (EVar "decls"))) (DoLet false false (PVar "methods") (EApp (EApp (EApp (EMethodRef "fold") (EApp (EApp (EVar "methodNoFile") (EVar "aliases")) (EVar "write"))) (EVar "omEmpty")) (EVar "decls"))) (DoLet false false (PVar "results") (EApp (EVar "Ref") (EVar "omEmpty"))) (DoLet false false PWild (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (EApp (EApp (EApp (EApp (EVar "bindingNoFile") (EVar "ordinary")) (EVar "methods")) (EVar "results")) (EVar "d")))) (EVar "decls"))) (DoExpr (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PTuple (PVar "n") PWild PWild)) (EBlock (DoLet false false (PVar "name") (EApp (EVar "unmangled") (EVar "n"))) (DoExpr (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (EApp (EApp (EVar "optionOr") (EVar "False")) (EApp (EApp (EVar "omLookup") (EVar "name")) (EFieldAccess (EVar "results") "value")))) (EVar "m")))))) (EVar "omEmpty")) (EVar "bindings")))))
(DTypeSig false "putNoFile" (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyApp (TyCon "OrdMap") (TyCon "Bool"))))))
(DFunDef false "putNoFile" ((PVar "n") (PVar "proof") (PVar "m")) (EApp (EApp (EApp (EVar "omInsert") (EVar "n")) (EBinOp "&&" (EVar "proof") (EApp (EApp (EVar "optionOr") (EVar "True")) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "m"))))) (EVar "m")))
(DTypeSig false "signatureNoFile" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyFun (TyCon "Decl") (TyApp (TyCon "OrdMap") (TyCon "Bool")))))))
(DFunDef false "signatureNoFile" ((PVar "aliases") (PVar "write") (PVar "m") (PCon "DTypeSig" PWild (PVar "n") (PVar "ty"))) (EApp (EApp (EApp (EVar "putNoFile") (EVar "n")) (EApp (EApp (EApp (EVar "tyNoFile") (EVar "aliases")) (EVar "write")) (EVar "ty"))) (EVar "m")))
(DFunDef false "signatureNoFile" ((PVar "aliases") (PVar "write") (PVar "m") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "signatureNoFile") (EVar "aliases")) (EVar "write")) (EVar "m")) (EVar "d")))
(DFunDef false "signatureNoFile" (PWild PWild (PVar "m") PWild) (EVar "m"))
(DTypeSig false "methodNoFile" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyFun (TyCon "Decl") (TyApp (TyCon "OrdMap") (TyCon "Bool")))))))
(DFunDef false "methodNoFile" ((PVar "aliases") (PVar "write") (PVar "m") (PRec "DInterface" ((rf "methods" None)) true)) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "method")) (EMatch (EVar "method") (arm (PCon "IfaceMethod" (PVar "n") (PVar "ty") PWild PWild) () (EApp (EApp (EApp (EVar "putNoFile") (EApp (EVar "unmangled") (EVar "n"))) (EApp (EApp (EApp (EVar "tyNoFile") (EVar "aliases")) (EVar "write")) (EVar "ty"))) (EVar "acc")))))) (EVar "m")) (EVar "methods")))
(DFunDef false "methodNoFile" ((PVar "aliases") (PVar "write") (PVar "m") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "methodNoFile") (EVar "aliases")) (EVar "write")) (EVar "m")) (EVar "d")))
(DFunDef false "methodNoFile" (PWild PWild (PVar "m") PWild) (EVar "m"))
(DTypeSig false "bindingNoFile" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Bool"))) (TyFun (TyCon "Decl") (TyCon "Unit"))))))
(DFunDef false "bindingNoFile" ((PVar "ordinary") PWild (PVar "results") (PCon "DFunDef" PWild (PVar "n") PWild PWild PWild)) (EApp (EApp (EVar "setRef") (EVar "results")) (EApp (EApp (EApp (EVar "putNoFile") (EApp (EVar "unmangled") (EVar "n"))) (EApp (EApp (EVar "optionOr") (EVar "False")) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "ordinary")))) (EFieldAccess (EVar "results") "value"))))
(DFunDef false "bindingNoFile" ((PVar "ordinary") PWild (PVar "results") (PCon "DLetGroup" PWild (PVar "binds"))) (EBlock (DoLet false false PWild (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (EMatch (EVar "b") (arm (PCon "LetBind" (PVar "n") PWild PWild) () (EApp (EApp (EVar "setRef") (EVar "results")) (EApp (EApp (EApp (EVar "putNoFile") (EApp (EVar "unmangled") (EVar "n"))) (EApp (EApp (EVar "optionOr") (EVar "False")) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "ordinary")))) (EFieldAccess (EVar "results") "value"))))))) (EVar "binds"))) (DoExpr (ELit LUnit))))
(DFunDef false "bindingNoFile" (PWild (PVar "methods") (PVar "results") (PRec "DImpl" ((rf "methods" (PVar "bodies"))) true)) (EBlock (DoLet false false PWild (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (EMatch (EVar "b") (arm (PCon "ImplMethod" (PVar "n") PWild PWild) () (EApp (EApp (EVar "setRef") (EVar "results")) (EApp (EApp (EApp (EVar "putNoFile") (EApp (EVar "unmangled") (EVar "n"))) (EApp (EApp (EVar "optionOr") (EVar "False")) (EApp (EApp (EVar "omLookup") (EApp (EVar "unmangled") (EVar "n"))) (EVar "methods")))) (EFieldAccess (EVar "results") "value"))))))) (EVar "bodies"))) (DoExpr (ELit LUnit))))
(DFunDef false "bindingNoFile" (PWild (PVar "methods") (PVar "results") (PRec "DInterface" ((rf "methods" (PVar "bodies"))) true)) (EBlock (DoLet false false PWild (EApp (EApp (EMethodRef "map") (ELam ((PVar "b")) (EMatch (EVar "b") (arm (PCon "IfaceMethod" (PVar "n") PWild (PCon "Some" PWild) PWild) () (EApp (EApp (EVar "setRef") (EVar "results")) (EApp (EApp (EApp (EVar "putNoFile") (EApp (EVar "unmangled") (EVar "n"))) (EApp (EApp (EVar "optionOr") (EVar "False")) (EApp (EApp (EVar "omLookup") (EApp (EVar "unmangled") (EVar "n"))) (EVar "methods")))) (EFieldAccess (EVar "results") "value")))) (arm (PCon "IfaceMethod" PWild PWild (PCon "None") PWild) () (ELit LUnit))))) (EVar "bodies"))) (DoExpr (ELit LUnit))))
(DFunDef false "bindingNoFile" ((PVar "ordinary") (PVar "methods") (PVar "results") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "bindingNoFile") (EVar "ordinary")) (EVar "methods")) (EVar "results")) (EVar "d")))
(DFunDef false "bindingNoFile" (PWild PWild PWild PWild) (ELit LUnit))
(DTypeSig false "tyNoFile" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyCon "Ty") (TyCon "Bool")))))
(DFunDef false "tyNoFile" ((PVar "aliases") (PVar "write") (PCon "TyConstrained" PWild (PVar "ty"))) (EApp (EApp (EApp (EVar "tyNoFile") (EVar "aliases")) (EVar "write")) (EVar "ty")))
(DFunDef false "tyNoFile" ((PVar "aliases") (PVar "write") (PCon "TyNamed" PWild (PVar "ty") PWild)) (EApp (EApp (EApp (EVar "tyNoFile") (EVar "aliases")) (EVar "write")) (EVar "ty")))
(DFunDef false "tyNoFile" ((PVar "aliases") (PVar "write") (PCon "TyQual" (PVar "ty") PWild PWild)) (EApp (EApp (EApp (EVar "tyNoFile") (EVar "aliases")) (EVar "write")) (EVar "ty")))
(DFunDef false "tyNoFile" ((PVar "aliases") (PVar "write") (PCon "TyEffect" (PVar "atoms") (PVar "tails") (PVar "ty"))) (EBinOp "&&" (EBinOp "&&" (EApp (EMethodRef "isEmpty") (EVar "tails")) (EApp (EApp (EDictApp "all") (EApp (EVar "atomNoFile") (EVar "write"))) (EVar "atoms"))) (EApp (EApp (EApp (EVar "tyNoFile") (EVar "aliases")) (EVar "write")) (EVar "ty"))))
(DFunDef false "tyNoFile" ((PVar "aliases") (PVar "write") (PCon "TyFun" PWild (PVar "result"))) (EApp (EApp (EApp (EVar "tyNoFile") (EVar "aliases")) (EVar "write")) (EVar "result")))
(DFunDef false "tyNoFile" ((PVar "aliases") PWild (PRec "TyCon" ((rf "tyConName" (PVar "n"))) false)) (EApp (EVar "not") (EBinOp "||" (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "aliases")) (EApp (EApp (EVar "omHasKey") (EApp (EVar "unmangled") (EVar "n"))) (EVar "aliases")))))
(DFunDef false "tyNoFile" ((PVar "aliases") (PVar "write") (PCon "TyApp" (PVar "head") PWild)) (EApp (EApp (EApp (EVar "tyNoFile") (EVar "aliases")) (EVar "write")) (EVar "head")))
(DFunDef false "tyNoFile" (PWild PWild (PCon "TyTuple" PWild)) (EVar "True"))
(DFunDef false "tyNoFile" (PWild PWild PWild) (EVar "False"))
(DTypeSig false "atomNoFile" (TyFun (TyCon "Bool") (TyFun (TyCon "EffAtomTy") (TyCon "Bool"))))
(DFunDef false "atomNoFile" ((PVar "write") (PRec "EffAtomTy" ((rf "eatLabel" (PVar "label")) (rf "eatOrigin" (PCon "OriginBuiltin"))) false)) (EBinOp "&&" (EBinOp "/=" (EVar "label") (ELit (LString "IO"))) (EBinOp "/=" (EVar "label") (EIf (EVar "write") (ELit (LString "FileWrite")) (ELit (LString "FileRead"))))))
(DFunDef false "atomNoFile" (PWild (PRec "EffAtomTy" ((rf "eatOrigin" (PCon "OriginModule" PWild))) false)) (EVar "True"))
(DFunDef false "atomNoFile" (PWild PWild) (EVar "False"))
(DTypeSig false "spread" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Unit")) (TyApp (TyCon "OrdMap") (TyCon "Unit")))))))
(DFunDef false "spread" (PWild PWild (PList) (PVar "seen")) (EVar "seen"))
(DFunDef false "spread" ((PVar "users") (PVar "noFile") (PCons (PVar "n") (PVar "rest")) (PVar "seen")) (EBlock (DoLet false false (PVar "fresh") (EApp (EApp (EVar "filterList") (ELam ((PVar "u")) (EBinOp "&&" (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "u")) (EVar "seen"))) (EApp (EVar "not") (EApp (EApp (EVar "optionOr") (EVar "False")) (EApp (EApp (EVar "omLookup") (EVar "u")) (EVar "noFile"))))))) (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "n")) (EVar "users"))))) (DoExpr (EApp (EApp (EApp (EApp (EVar "spread") (EVar "users")) (EVar "noFile")) (EBinOp "++" (EVar "fresh") (EVar "rest"))) (EApp (EApp (EVar "omFromNames") (EVar "fresh")) (EVar "seen"))))))
(DTypeSig false "declDefines" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyCon "Decl") (TyCon "Unit"))))
(DFunDef false "declDefines" ((PVar "defined") (PCon "DExtern" PWild (PVar "n") PWild)) (EApp (EApp (EVar "setRef") (EVar "defined")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "unmangled") (EVar "n"))) (ELit LUnit)) (EFieldAccess (EVar "defined") "value"))))
(DFunDef false "declDefines" ((PVar "defined") (PRec "DData" ((rf "dataCtors" None)) true)) (EApp (EApp (EVar "setRef") (EVar "defined")) (EApp (EApp (EVar "omFromNames") (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (EMatch (EVar "v") (arm (PCon "Variant" (PVar "n") PWild) () (EApp (EVar "unmangled") (EVar "n")))))) (EVar "dataCtors"))) (EFieldAccess (EVar "defined") "value"))))
(DFunDef false "declDefines" ((PVar "defined") (PRec "DNewtype" ((rf "newtypeCtor" None)) true)) (EApp (EApp (EVar "setRef") (EVar "defined")) (EApp (EApp (EApp (EVar "omInsert") (EApp (EVar "unmangled") (EVar "newtypeCtor"))) (ELit LUnit)) (EFieldAccess (EVar "defined") "value"))))
(DFunDef false "declDefines" ((PVar "defined") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EVar "declDefines") (EVar "defined")) (EVar "d")))
(DFunDef false "declDefines" (PWild PWild) (ELit LUnit))
(DTypeSig false "bindingRefs" (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyCon "String")))) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "OrdMap") (TyCon "Unit"))) (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Pat")) (TyFun (TyCon "Expr") (TyCon "Unit"))))))))
(DFunDef false "bindingRefs" ((PVar "users") (PVar "defined") (PVar "returns") (PVar "b") (PVar "ps") (PVar "body")) (EBlock (DoLet false false (PVar "name") (EApp (EVar "unmangled") (EVar "b"))) (DoLet false false (PVar "refs") (EApp (EVar "Ref") (EListLit))) (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "collectRefs") (EVar "returns")) (EVar "refs")) (EApp (EApp (EVar "addPatScope") (EVar "ps")) (EVar "omEmpty"))) (EVar "body"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "defined")) (EApp (EApp (EApp (EVar "omInsert") (EVar "name")) (ELit LUnit)) (EFieldAccess (EVar "defined") "value")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "users")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "m") (PVar "r")) (EApp (EApp (EApp (EVar "omInsert") (EVar "r")) (EBinOp "::" (EVar "name") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "r")) (EVar "m"))))) (EVar "m")))) (EFieldAccess (EVar "users") "value")) (EFieldAccess (EVar "refs") "value"))))))
(DTypeSig false "collectRefs" (TyFun (TyApp (TyCon "OrdMap") (TyCon "Int")) (TyFun (TyApp (TyCon "Ref") (TyApp (TyCon "List") (TyCon "String"))) (TyFun (TyCon "Scope") (TyFun (TyCon "Expr") (TyCon "Expr"))))))
(DFunDef false "collectRefs" ((PVar "returns") (PVar "refs") (PVar "bound") (PAs "e" (PCon "EApp" PWild PWild))) (EBlock (DoLet false false (PTuple (PVar "head") (PVar "args")) (EApp (EApp (EVar "appSpine") (EVar "e")) (EListLit))) (DoLet false false PWild (EIf (EApp (EApp (EApp (EApp (EVar "unknownCall") (EVar "returns")) (EVar "bound")) (EVar "head")) (EApp (EVar "listLen") (EVar "args"))) (EApp (EApp (EVar "setRef") (EVar "refs")) (EBinOp "::" (ELit (LString "readFile")) (EBinOp "::" (ELit (LString "writeFileBytes")) (EFieldAccess (EVar "refs") "value")))) (ELit LUnit))) (DoLet false false PWild (EMatch (EApp (EApp (EVar "localHead") (EVar "bound")) (EVar "head")) (arm (PCon "Some" (PCon "LocalFunction" PWild PWild PWild PWild PWild)) () (ELit LUnit)) (arm PWild () (EBlock (DoLet false false PWild (EApp (EApp (EApp (EApp (EVar "collectRefs") (EVar "returns")) (EVar "refs")) (EVar "bound")) (EVar "head"))) (DoExpr (ELit LUnit)))))) (DoLet false false PWild (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "collectRefs") (EVar "returns")) (EVar "refs")) (EVar "bound"))) (EVar "args"))) (DoExpr (EVar "e"))))
(DFunDef false "collectRefs" ((PVar "returns") (PVar "refs") (PVar "bound") (PVar "e")) (EMatch (EApp (EVar "headRawName") (EVar "e")) (arm (PCon "Some" (PVar "n")) () (EBlock (DoLet false false PWild (EIf (EApp (EVar "not") (EApp (EApp (EVar "omHasKey") (EVar "n")) (EVar "bound"))) (EApp (EApp (EVar "setRef") (EVar "refs")) (EBinOp "::" (EApp (EVar "unmangled") (EVar "n")) (EFieldAccess (EVar "refs") "value"))) (ELit LUnit))) (DoExpr (EVar "e")))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "mapScopedChildren") (EVar "bound")) (EApp (EApp (EVar "collectRefs") (EVar "returns")) (EVar "refs"))) (EVar "e")))))
(DTypeSig false "keepSpineLoc" (TyFun (TyCon "Expr") (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "keepSpineLoc" ((PVar "spine") (PVar "head")) (EMatch (EApp (EVar "spineLoc") (EVar "spine")) (arm (PCon "Some" (PVar "l")) () (EApp (EApp (EVar "ELoc") (EVar "l")) (EVar "head"))) (arm (PCon "None") () (EVar "head"))))
(DTypeSig false "spineLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "spineLoc" ((PCon "EApp" (PVar "f") PWild)) (EApp (EVar "spineLoc") (EVar "f")))
(DFunDef false "spineLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "spineLoc" (PWild) (EVar "None"))
(DTypeSig false "appSpine" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyTuple (TyCon "Expr") (TyApp (TyCon "List") (TyCon "Expr"))))))
(DFunDef false "appSpine" ((PCon "EApp" (PVar "f") (PVar "x")) (PVar "args")) (EApp (EApp (EVar "appSpine") (EVar "f")) (EBinOp "::" (EVar "x") (EVar "args"))))
(DFunDef false "appSpine" ((PCon "ELoc" PWild (PVar "f")) (PVar "args")) (EApp (EApp (EVar "appSpine") (EVar "f")) (EVar "args")))
(DFunDef false "appSpine" ((PVar "h") (PVar "args")) (ETuple (EVar "h") (EVar "args")))
(DTypeSig false "grantElems" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String")))))
(DFunDef false "grantElems" ((PCon "EListLit" (PAs "es" (PCons PWild PWild)))) (EApp (EApp (EVar "bareStrings") (EVar "es")) (EListLit)))
(DFunDef false "grantElems" ((PCon "EBinOp" (PLit (LString "++")) (PVar "a") (PVar "b") PWild)) (EMatch (ETuple (EApp (EVar "grantElems") (EVar "a")) (EApp (EVar "grantElems") (EVar "b"))) (arm (PTuple (PCon "None") (PCon "None")) () (EVar "None")) (arm (PTuple (PVar "x") (PVar "y")) () (EApp (EVar "Some") (EBinOp "++" (EApp (EApp (EVar "optionOr") (EListLit)) (EVar "x")) (EApp (EApp (EVar "optionOr") (EListLit)) (EVar "y")))))))
(DFunDef false "grantElems" ((PCon "EMatch" (PCon "EVar" PWild) (PList PWild (PCon "Arm" (PCon "PWild") (PList) (PVar "j"))))) (EApp (EVar "grantElems") (EVar "j")))
(DFunDef false "grantElems" (PWild) (EVar "None"))
(DTypeSig false "bareStrings" (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "Option") (TyApp (TyCon "List") (TyCon "String"))))))
(DFunDef false "bareStrings" ((PList) (PVar "acc")) (EApp (EVar "Some") (EApp (EVar "reverseL") (EVar "acc"))))
(DFunDef false "bareStrings" ((PCons (PCon "ELit" (PCon "LString" (PVar "s"))) (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "bareStrings") (EVar "rest")) (EBinOp "::" (EVar "s") (EVar "acc"))))
(DFunDef false "bareStrings" (PWild PWild) (EVar "None"))
(DTypeSig false "leafPath" (TyFun (TyCon "Expr") (TyFun (TyApp (TyCon "List") (TyCon "Expr")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "leafPath" ((PCon "EVar" (PVar "n")) (PCons (PVar "p") (PVar "rest"))) (EMatch (EApp (EVar "wasmFileGrantArity") (EVar "n")) (arm (PCon "Some" (PVar "arity")) () (EIf (EBinOp "==" (EApp (EVar "listLen") (EVar "rest")) (EVar "arity")) (EApp (EVar "pathLit") (EVar "p")) (EVar "None"))) (arm (PCon "None") () (EVar "None"))))
(DFunDef false "leafPath" (PWild PWild) (EVar "None"))
(DTypeSig false "pathLit" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "String"))))
(DFunDef false "pathLit" ((PCon "ELoc" PWild (PVar "e"))) (EApp (EVar "pathLit") (EVar "e")))
(DFunDef false "pathLit" ((PCon "ELit" (PCon "LString" (PVar "s")))) (EApp (EVar "Some") (EVar "s")))
(DFunDef false "pathLit" (PWild) (EVar "None"))
(DTypeSig false "calleeName" (TyFun (TyCon "Expr") (TyCon "String")))
(DFunDef false "calleeName" ((PCon "EVar" (PLit (LString "$withFileReadBound")))) (ELit (LString "declared FileRead bound")))
(DFunDef false "calleeName" ((PCon "EVar" (PLit (LString "$withFileWriteBound")))) (ELit (LString "declared FileWrite bound")))
(DFunDef false "calleeName" ((PCon "EVar" (PVar "n"))) (EApp (EVar "unmangled") (EVar "n")))
(DFunDef false "calleeName" ((PCon "EDictAt" (PVar "n") PWild)) (EApp (EVar "unmangled") (EVar "n")))
(DFunDef false "calleeName" ((PCon "EMethodAt" (PVar "n") PWild PWild)) (EApp (EVar "unmangled") (EVar "n")))
(DFunDef false "calleeName" (PWild) (ELit (LString "this call")))
(DTypeSig false "unmangled" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "unmangled" ((PVar "n")) (EBlock (DoLet false false (PVar "bare") (EMatch (EApp (EApp (EVar "lastIndexOf") (ELit (LString "__"))) (EVar "n")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EApp (EVar "stringSlice") (EBinOp "+" (EVar "i") (ELit (LInt 2)))) (EApp (EVar "stringLength") (EVar "n"))) (EVar "n"))) (arm (PCon "None") () (EVar "n")))) (DoExpr (EMatch (EApp (EApp (EVar "indexOf") (ELit (LString "$"))) (EVar "bare")) (arm (PCon "Some" (PVar "i")) () (EIf (EBinOp ">" (EVar "i") (ELit (LInt 0))) (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 0))) (EVar "i")) (EVar "bare")) (EVar "bare"))) (arm (PCon "None") () (EVar "bare"))))))
(DTypeSig false "leftLoc" (TyFun (TyCon "Expr") (TyApp (TyCon "Option") (TyCon "Loc"))))
(DFunDef false "leftLoc" ((PCon "ELoc" (PVar "l") PWild)) (EApp (EVar "Some") (EVar "l")))
(DFunDef false "leftLoc" ((PCon "EApp" (PVar "f") (PVar "x"))) (EApp (EApp (EMethodRef "orElse") (EApp (EVar "leftLoc") (EVar "f"))) (EApp (EVar "leftLoc") (EVar "x"))))
(DFunDef false "leftLoc" ((PCon "EBinOp" PWild (PVar "a") (PVar "b") PWild)) (EApp (EApp (EMethodRef "orElse") (EApp (EVar "leftLoc") (EVar "a"))) (EApp (EVar "leftLoc") (EVar "b"))))
(DFunDef false "leftLoc" ((PVar "e")) (EBlock (DoLet false false (PVar "found") (EApp (EVar "Ref") (EVar "None"))) (DoLet false false PWild (EApp (EApp (EVar "mapChildren") (ELam ((PVar "child")) (EBlock (DoLet false false PWild (EMatch (EFieldAccess (EVar "found") "value") (arm (PCon "None") () (EApp (EApp (EVar "setRef") (EVar "found")) (EApp (EVar "leftLoc") (EVar "child")))) (arm (PCon "Some" PWild) () (ELit LUnit)))) (DoExpr (EVar "child"))))) (EVar "e"))) (DoExpr (EFieldAccess (EVar "found") "value"))))
