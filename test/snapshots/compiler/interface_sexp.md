# META
source_lines=600
stages=DESUGAR,MARK
# SOURCE
-- The scheme-level interface codec: every type a published scheme is built
-- from, written as an `SExp` and read back.  Names travel with their identity:
-- a type constructor, effect label and interface carry their defining module.
-- A `Mono` holds type aliases already expanded, so an alias is written
-- expanded, as the renderer prints it.  A variable is written by its kind, its
-- id and every other field of its cell (level, and for an authority variable
-- its domain, pattern flag and source binder name).
--
-- Every encoder zonks its argument first (`types.publish`), so a `Link`, an
-- `ALink` and a row-tail `ELink` are followed exactly as a freeze follows them,
-- and the text is the value a thaw would hold.  What a frozen row holds, per
-- effect-variable constructor: `EUnbound` and `EJoin` anywhere; `ELink` only as
-- a join member, carrying the labelled row it shares; `ESummary` never, since
-- an open summary withholds the checked program.  `bindingSExp` panics, naming
-- the row, when the validator `liveCells` finds a link or an open summary in a
-- row that should be frozen.
--
-- Decoding mints fresh cells, one per (kind, id) within one value, memoized in
-- a `ZState` the way a freeze memoizes them, so a scheme and its context share
-- their variables.  A repeated id must be written exactly as its first
-- occurrence; anything else, a wrong field count or an unknown head is an
-- `Err` naming the path of the node.
--
-- Grammar, one line per node.  `<id>` and `<lvl>` are integer atoms, `<name>`
-- and `<str>` atoms, `<bool>` is `true` or `false`, `<x> ...` a list of `<x>`:
--   (binding <name> <pub>)                    a published row
--   (pub <scheme> (<obl> ...))                `PubScheme`
--   (forall (<id> ...) (<id> ...) (<id> ...) (<residual> ...) <row> <mono>)
--   (residual <auth> <auth> <bool>)           lower, upper, exact
--   (obl <iface> (<id> ...) (<mono> ...))     `VecObl`
--   (iface <name> <origin>)                   `IfaceRef`
--   unresolved | builtin | (module <name>)    `TyConOrigin`
--   (tv <id> <lvl>)                           an unbound type variable
--   (con <name> <origin>) | (rigid <name>)    type heads
--   (app <mono> <mono>)                       application
--   (fun <mono> <row> <mono>)                 arrow
--   (eff <row>) | (qual <mono> <auth>) | (auth <auth>)
--   (row (<atom> ...) <tail>)                 `<tail>`: `closed` or an `<effvar>`
--   (ev <id> <lvl>)                           an unbound effect variable
--   (ej <id> <lvl> (<effvar> ...))            a join of effect variables
--   (el <id> <row>)                           a linked join member
--   (atom <label> <auth>) | (label <name> <origin>)
--   (const <param>) | (ajoin (<auth> ...)) | (aproduct ((<name> <auth>) ...))
--   (av <id> <lvl> <param> <bool> <opt>)      domain top, pattern flag, binder
--   unit | (prefix <opt>) | (path <opt>)      `Param`
--   (set none) | (set (<str> ...)) | (product ((<name> <param>) ...))
--   none | (some <str>)                       an optional string
import map as IdMap
import support.sexp_value.{
  SExp(..), SexpError(..), expectAtom, atomInt, atomBool
}
import types.publish.{
  PubScheme(..), ZState(..), LiveCell(..), emptyZonk, zonkMono, zonkRow,
  zonkAuthority, zonkVecObl, zonkScheme, freezePub, liveCells
}
import types.repr.{
  Mono(..), Tyvar(..), Scheme(..), AuthResidual(..), VecObl(..), IfaceRef(..)
}
import types.effect_rows.{EffRow(..), Effvar(..), Atom(..), EffLabel(..)}
import types.effect_authority.{Authority(..), Authvar(..)}
import types.effect_domain.{Param(..)}
import frontend.ast.{TyConOrigin(..)}

-- ── writing ─────────────────────────────────────────────────────────────────

tagged : String -> List SExp -> SExp
tagged head fields = SList (SAtom head :: fields)

intNode : Int -> SExp
intNode n = SAtom (intToString n)

boolNode : Bool -> SExp
boolNode b = SAtom (if b then "true" else "false")

idsNode : List Int -> SExp
idsNode ids = SList (map intNode ids)

optNode : Option String -> SExp
optNode None = SAtom "none"
optNode (Some s) = tagged "some" [SAtom s]

originNode : TyConOrigin -> SExp
originNode OriginUnresolved = SAtom "unresolved"
originNode OriginBuiltin = SAtom "builtin"
originNode (OriginModule m) = tagged "module" [SAtom m]

paramNode : Param -> SExp
paramNode PUnit = SAtom "unit"
paramNode (PPrefix s) = tagged "prefix" [optNode s]
paramNode (PPath s) = tagged "path" [optNode s]
paramNode (PSet None) = tagged "set" [SAtom "none"]
paramNode (PSet (Some members)) = tagged "set" [SList (map SAtom members)]
paramNode (PProduct axes) = tagged "product" [
  SList (map (axis => SList [SAtom (fst axis), paramNode (snd axis)]) axes),
]

-- The printers below read zonked values only; a link reaching one is a zonk
-- that did not run.
unzonked : String -> a
unzonked what = panic "interface_sexp: \{what} reached the printer unzonked"

authNode : Authority -> SExp
authNode (AConst p) = tagged "const" [paramNode p]
authNode (AVar cell) = match !cell
  AUnbound id lvl top pat name => tagged "av" [
    intNode id,
    intNode lvl,
    paramNode top,
    boolNode pat,
    optNode name,
  ]
  ALink id _ _ => unzonked "the linked authority variable \{id}"
authNode (AJoin members) = tagged "ajoin" [SList (map authNode members)]
authNode (AProduct axes) = tagged "aproduct" [
  SList (map (axis => SList [SAtom (fst axis), authNode (snd axis)]) axes),
]

labelNode : EffLabel -> SExp
labelNode (EffLabel name origin) =
  tagged "label" [SAtom name, originNode origin]

atomNode : Atom -> SExp
atomNode (Atom label auth) = tagged "atom" [labelNode label, authNode auth]

rowNode : EffRow -> SExp
rowNode (EffRow atoms tail) =
  tagged "row" [SList (map atomNode atoms), tailNode tail]

tailNode : Option (Ref Effvar) -> SExp
tailNode None = SAtom "closed"
tailNode (Some cell) = effvarNode cell

effvarNode : Ref Effvar -> SExp
effvarNode cell = match !cell
  EUnbound id lvl => tagged "ev" [intNode id, intNode lvl]
  EJoin id lvl members =>
    tagged "ej" [intNode id, intNode lvl, SList (map effvarNode members)]
  ELink id row => tagged "el" [intNode id, rowNode row]
  ESummary id _ _ =>
    panic
      "interface_sexp: effect summary \{id} is open; a frozen row holds none"

monoNode : Mono -> SExp
monoNode (TVar cell) = match !cell
  Unbound id lvl => tagged "tv" [intNode id, intNode lvl]
  Link _ => unzonked "a linked type variable"
monoNode (TCon name origin) = tagged "con" [SAtom name, originNode origin]
monoNode (TRigid name) = tagged "rigid" [SAtom name]
monoNode (TApp f a) = tagged "app" [monoNode f, monoNode a]
monoNode (TFun a row b) = tagged "fun" [monoNode a, rowNode row, monoNode b]
monoNode (TEff row) = tagged "eff" [rowNode row]
monoNode (TQual m auth) = tagged "qual" [monoNode m, authNode auth]
monoNode (TAuth auth) = tagged "auth" [authNode auth]

residualNode : AuthResidual -> SExp
residualNode (AuthResidual { arLower = lo, arUpper = hi, arExact = exact }) =
  tagged "residual" [authNode lo, authNode hi, boolNode exact]

ifaceNode : IfaceRef -> SExp
ifaceNode iface = tagged "iface" [SAtom iface.irName, originNode iface.irOrigin]

oblNode : VecObl -> SExp
oblNode (VecObl { voIface = iface, voIds = ids, voArgs = args }) =
  tagged "obl" [ifaceNode iface, idsNode ids, SList (map monoNode args)]

schemeNode : Scheme -> SExp
schemeNode (Forall ids effIds authIds residuals row t) = tagged "forall" [
  idsNode ids,
  idsNode effIds,
  idsNode authIds,
  SList (map residualNode residuals),
  rowNode row,
  monoNode t,
]

pubNode : PubScheme -> SExp
pubNode p =
  tagged "pub" [schemeNode p.psScheme, SList (map oblNode p.psContext)]

export
monoSExp : Mono -> SExp
monoSExp m = monoNode (snd (zonkMono emptyZonk m))

export
schemeSExp : Scheme -> SExp
schemeSExp s = schemeNode (snd (zonkScheme emptyZonk s))

export
effRowSExp : EffRow -> SExp
effRowSExp row = rowNode (snd (zonkRow emptyZonk row))

export
atomSExp : Atom -> SExp
atomSExp (Atom label auth) =
  atomNode (Atom label (snd (zonkAuthority emptyZonk auth)))

export
effLabelSExp : EffLabel -> SExp
effLabelSExp = labelNode

export
authoritySExp : Authority -> SExp
authoritySExp auth = authNode (snd (zonkAuthority emptyZonk auth))

export
paramSExp : Param -> SExp
paramSExp = paramNode

export
authResidualSExp : AuthResidual -> SExp
authResidualSExp r =
  let (z1, lo) = zonkAuthority emptyZonk r.arLower
  let (_, hi) = zonkAuthority z1 r.arUpper
  residualNode { r | arLower = lo, arUpper = hi }

export
vecOblSExp : VecObl -> SExp
vecOblSExp o = oblNode (snd (zonkVecObl emptyZonk o))

export
pubSchemeSExp : PubScheme -> SExp
pubSchemeSExp p = pubNode (freezePub p.psScheme p.psContext)

export
ifaceRefSExp : IfaceRef -> SExp
ifaceRefSExp = ifaceNode

export
tyConOriginSExp : TyConOrigin -> SExp
tyConOriginSExp = originNode

-- A weak variable (`FreeMeta`) is a legal frozen inhabitant; a link or an open
-- summary in a published row is a bug in whatever froze it.
notFrozen : LiveCell -> Bool
notFrozen (LinkCell _ _ _) = True
notFrozen (OpenSummary _ _) = True
notFrozen _ = False

export
bindingSExp : String -> PubScheme -> SExp
bindingSExp name p = match filter notFrozen (liveCells name p)
  [] => tagged "binding" [SAtom name, pubSchemeSExp p]
  faults => panic "interface row \{name} is not frozen: \{debug faults}"

-- ── reading ─────────────────────────────────────────────────────────────────

type Dec a = Result SexpError (ZState, a)

headOf : SExp -> String
headOf (SAtom s) = s
headOf (SList ((SAtom h) :: _)) = h
headOf (SList _) = "a list"

refuse : String -> SExp -> String -> Result SexpError a
refuse path node what = Err SexpError {
  seOffset = 0,
  sePath = path,
  seWhat = "\{headOf node}: \{what}",
}

-- [heads] pairs each head a position admits with its field count.
misfit : String -> List (String, Int) -> SExp -> Result SexpError a
misfit path heads node = match find (h => fst h == headOf node) heads
  Some (_, n) => refuse path node "expected \{n} field(s)"
  None =>
    refuse
      path
      node
      "unknown head; expected one of \{stringJoin ", " (map fst heads)}"

at : String -> String -> Int -> String
at path head i = "\{path}/\{head}.\{i}"

stateless : (String -> SExp -> Result SexpError a) ->
  ZState ->
  String ->
  SExp ->
  Dec a
stateless f z path node = map (v => (z, v)) (f path node)

decEach : (ZState -> String -> SExp -> Dec a) ->
  ZState ->
  String ->
  SExp ->
  Dec (List a)
decEach f z path (SList items) = decItems f z path 0 items
decEach _ _ path node = refuse path node "expected a list"

decItems : (ZState -> String -> SExp -> Dec a) ->
  ZState ->
  String ->
  Int ->
  List SExp ->
  Dec (List a)
decItems _ z _ _ [] = Ok (z, [])
decItems f z path i (x :: rest) = do
  (z1, y) <- f z "\{path}/\{i}" x
  (z2, ys) <- decItems f z1 path (i + 1) rest
  Ok (z2, y :: ys)

decList : (String -> SExp -> Result SexpError a) ->
  String ->
  SExp ->
  Result SexpError (List a)
decList f path node = map snd (decEach (stateless f) emptyZonk path node)

-- A repeated id must be written as its first occurrence was.
same : String -> SExp -> SExp -> a -> Result SexpError a
same path node first v =
  if node == first then
    Ok v
  else
    refuse path node "this id was written differently before"

decOpt : String -> SExp -> Result SexpError (Option String)
decOpt _ (SAtom "none") = Ok None
decOpt path (SList [SAtom "some", s]) =
  map Some (expectAtom (at path "some" 1) s)
decOpt path node = misfit path [("none", 0), ("some", 1)] node

decOrigin : String -> SExp -> Result SexpError TyConOrigin
decOrigin _ (SAtom "unresolved") = Ok OriginUnresolved
decOrigin _ (SAtom "builtin") = Ok OriginBuiltin
decOrigin path (SList [SAtom "module", m]) =
  map OriginModule (expectAtom (at path "module" 1) m)
decOrigin path node =
  misfit path [("unresolved", 0), ("builtin", 0), ("module", 1)] node

paramHeads : List (String, Int)
paramHeads =
  [("unit", 0), ("prefix", 1), ("path", 1), ("set", 1), ("product", 1)]

decParam : String -> SExp -> Result SexpError Param
decParam _ (SAtom "unit") = Ok PUnit
decParam path (SList [SAtom "prefix", s]) =
  map PPrefix (decOpt (at path "prefix" 1) s)
decParam path (SList [SAtom "path", s]) =
  map PPath (decOpt (at path "path" 1) s)
decParam _ (SList [SAtom "set", SAtom "none"]) = Ok (PSet None)
decParam path (SList [SAtom "set", members]) =
  map (ms => PSet (Some ms)) (decList expectAtom (at path "set" 1) members)
decParam path (SList [SAtom "product", axes]) =
  map PProduct (decList decParamAxis (at path "product" 1) axes)
decParam path node = misfit path paramHeads node

decParamAxis : String -> SExp -> Result SexpError (String, Param)
decParamAxis path (SList [n, p]) = do
  name <- expectAtom "\{path}/0" n
  param <- decParam "\{path}/1" p
  Ok (name, param)
decParamAxis path node = refuse path node "expected an axis (NAME PARAM)"

authHeads : List (String, Int)
authHeads = [("const", 1), ("av", 5), ("ajoin", 1), ("aproduct", 1)]

decAuth : ZState -> String -> SExp -> Dec Authority
decAuth z path (SList [SAtom "const", p]) =
  map (q => (z, AConst q)) (decParam (at path "const" 1) p)
decAuth z path (node@(SList [SAtom "av", i, l, top, pat, name])) = do
  id <- atomInt (at path "av" 1) i
  lvl <- atomInt (at path "av" 2) l
  domain <- decParam (at path "av" 3) top
  patterned <- atomBool (at path "av" 4) pat
  binder <- decOpt (at path "av" 5) name
  match IdMap.get id z.zAuths
    Some c => same path node (authNode (AVar c)) (z, AVar c)
    None =>
      let c = Ref (AUnbound id lvl domain patterned binder)
      Ok ({ z | zAuths = IdMap.set id c z.zAuths }, AVar c)
decAuth z path (SList [SAtom "ajoin", members]) =
  map
    (r => (fst r, AJoin (snd r)))
    (decEach decAuth z (at path "ajoin" 1) members)
decAuth z path (SList [SAtom "aproduct", axes]) =
  map
    (r => (fst r, AProduct (snd r)))
    (decEach decAuthAxis z (at path "aproduct" 1) axes)
decAuth _ path node = misfit path authHeads node

decAuthAxis : ZState -> String -> SExp -> Dec (String, Authority)
decAuthAxis z path (SList [n, a]) = do
  name <- expectAtom "\{path}/0" n
  (z1, auth) <- decAuth z "\{path}/1" a
  Ok (z1, (name, auth))
decAuthAxis _ path node = refuse path node "expected an axis (NAME AUTH)"

decLabel : String -> SExp -> Result SexpError EffLabel
decLabel path (SList [SAtom "label", n, o]) = do
  name <- expectAtom (at path "label" 1) n
  origin <- decOrigin (at path "label" 2) o
  Ok (EffLabel name origin)
decLabel path node = misfit path [("label", 2)] node

decAtom : ZState -> String -> SExp -> Dec Atom
decAtom z path (SList [SAtom "atom", l, a]) = do
  label <- decLabel (at path "atom" 1) l
  (z1, auth) <- decAuth z (at path "atom" 2) a
  Ok (z1, Atom label auth)
decAtom _ path node = misfit path [("atom", 2)] node

decRow : ZState -> String -> SExp -> Dec EffRow
decRow z path (SList [SAtom "row", atoms, tail]) = do
  (z1, atoms1) <- decEach decAtom z (at path "row" 1) atoms
  (z2, tail1) <- decTail z1 (at path "row" 2) tail
  Ok (z2, EffRow atoms1 tail1)
decRow _ path node = misfit path [("row", 2)] node

decTail : ZState -> String -> SExp -> Dec (Option (Ref Effvar))
decTail z _ (SAtom "closed") = Ok (z, None)
decTail z path node =
  map (r => (fst r, Some (snd r))) (decEffvar False z path node)

-- One cell per effect id: a repeated id must repeat its first node, and only
-- the first is decoded.
memoEff : ZState ->
  String ->
  SExp ->
  Int ->
  (ZState -> Dec Effvar) ->
  Dec (Ref Effvar)
memoEff z path node id build = match IdMap.get id z.zEffs
  Some c => same path node (effvarNode c) (z, c)
  None => do
    (z1, v) <- build z
    let c = Ref v
    Ok ({ z1 | zEffs = IdMap.set id c z1.zEffs }, c)

effvarHeads : List (String, Int)
effvarHeads = [("closed", 0), ("ev", 2), ("ej", 3), ("el", 2)]

-- [member] is True in a join's member list, the one place a link may stand.
decEffvar : Bool -> ZState -> String -> SExp -> Dec (Ref Effvar)
decEffvar _ z path (node@(SList [SAtom "ev", i, l])) = do
  id <- atomInt (at path "ev" 1) i
  lvl <- atomInt (at path "ev" 2) l
  memoEff z path node id (z0 => Ok (z0, EUnbound id lvl))
decEffvar _ z path (node@(SList [SAtom "ej", i, l, members])) = do
  id <- atomInt (at path "ej" 1) i
  lvl <- atomInt (at path "ej" 2) l
  memoEff z path node id (z0 =>
    map
      (r => (fst r, EJoin id lvl (snd r)))
      (decEach (decEffvar True) z0 (at path "ej" 3) members))
decEffvar True z path (node@(SList [SAtom "el", i, row])) = do
  id <- atomInt (at path "el" 1) i
  memoEff z path node id (z0 =>
    map (r => (fst r, ELink id (snd r))) (decRow z0 (at path "el" 2) row))
decEffvar False _ path (node@(SList [SAtom "el", _, _])) =
  refuse path node "a row tail is never a link"
decEffvar _ _ path node = misfit path effvarHeads node

monoHeads : List (String, Int)
monoHeads = [
  ("tv", 2),
  ("con", 2),
  ("rigid", 1),
  ("app", 2),
  ("fun", 3),
  ("eff", 1),
  ("qual", 2),
  ("auth", 1),
]

decMono : ZState -> String -> SExp -> Dec Mono
decMono z path (node@(SList [SAtom "tv", i, l])) = do
  id <- atomInt (at path "tv" 1) i
  lvl <- atomInt (at path "tv" 2) l
  match IdMap.get id z.zTys
    Some c => same path node (monoNode (TVar c)) (z, TVar c)
    None =>
      let c = Ref (Unbound id lvl)
      Ok ({ z | zTys = IdMap.set id c z.zTys }, TVar c)
decMono z path (SList [SAtom "con", n, o]) = do
  name <- expectAtom (at path "con" 1) n
  origin <- decOrigin (at path "con" 2) o
  Ok (z, TCon name origin)
decMono z path (SList [SAtom "rigid", n]) =
  map (name => (z, TRigid name)) (expectAtom (at path "rigid" 1) n)
decMono z path (SList [SAtom "app", f, a]) = do
  (z1, f1) <- decMono z (at path "app" 1) f
  (z2, a1) <- decMono z1 (at path "app" 2) a
  Ok (z2, TApp f1 a1)
decMono z path (SList [SAtom "fun", a, row, b]) = do
  (z1, a1) <- decMono z (at path "fun" 1) a
  (z2, row1) <- decRow z1 (at path "fun" 2) row
  (z3, b1) <- decMono z2 (at path "fun" 3) b
  Ok (z3, TFun a1 row1 b1)
decMono z path (SList [SAtom "eff", row]) =
  map (r => (fst r, TEff (snd r))) (decRow z (at path "eff" 1) row)
decMono z path (SList [SAtom "qual", m, a]) = do
  (z1, m1) <- decMono z (at path "qual" 1) m
  (z2, a1) <- decAuth z1 (at path "qual" 2) a
  Ok (z2, TQual m1 a1)
decMono z path (SList [SAtom "auth", a]) =
  map (r => (fst r, TAuth (snd r))) (decAuth z (at path "auth" 1) a)
decMono _ path node = misfit path monoHeads node

decResidual : ZState -> String -> SExp -> Dec AuthResidual
decResidual z path (SList [SAtom "residual", lo, hi, ex]) = do
  (z1, lower) <- decAuth z (at path "residual" 1) lo
  (z2, upper) <- decAuth z1 (at path "residual" 2) hi
  exact <- atomBool (at path "residual" 3) ex
  Ok (z2, AuthResidual { arLower = lower, arUpper = upper, arExact = exact })
decResidual _ path node = misfit path [("residual", 3)] node

decIface : String -> SExp -> Result SexpError IfaceRef
decIface path (SList [SAtom "iface", n, o]) = do
  name <- expectAtom (at path "iface" 1) n
  origin <- decOrigin (at path "iface" 2) o
  Ok IfaceRef { irName = name, irOrigin = origin }
decIface path node = misfit path [("iface", 2)] node

decObl : ZState -> String -> SExp -> Dec VecObl
decObl z path (SList [SAtom "obl", i, ids, args]) = do
  iface <- decIface (at path "obl" 1) i
  ids1 <- decList atomInt (at path "obl" 2) ids
  (z1, args1) <- decEach decMono z (at path "obl" 3) args
  Ok (z1, VecObl { voIface = iface, voIds = ids1, voArgs = args1 })
decObl _ path node = misfit path [("obl", 3)] node

decScheme : ZState -> String -> SExp -> Dec Scheme
decScheme z path (SList [SAtom "forall", ids, effIds, authIds, rs, row, t]) = do
  ids1 <- decList atomInt (at path "forall" 1) ids
  effIds1 <- decList atomInt (at path "forall" 2) effIds
  authIds1 <- decList atomInt (at path "forall" 3) authIds
  (z1, rs1) <- decEach decResidual z (at path "forall" 4) rs
  (z2, row1) <- decRow z1 (at path "forall" 5) row
  (z3, t1) <- decMono z2 (at path "forall" 6) t
  Ok (z3, Forall ids1 effIds1 authIds1 rs1 row1 t1)
decScheme _ path node = misfit path [("forall", 6)] node

decPub : ZState -> String -> SExp -> Dec PubScheme
decPub z path (SList [SAtom "pub", s, ctx]) = do
  (z1, scheme) <- decScheme z (at path "pub" 1) s
  (z2, obls) <- decEach decObl z1 (at path "pub" 2) ctx
  Ok (z2, PubScheme { psScheme = scheme, psContext = obls })
decPub _ path node = misfit path [("pub", 2)] node

-- A whole value from its root node, its cells minted fresh.
rooted : (ZState -> String -> SExp -> Dec a) ->
  String ->
  SExp ->
  Result SexpError a
rooted dec root node = map snd (dec emptyZonk root node)

export
monoOfSExp : SExp -> Result SexpError Mono
monoOfSExp = rooted decMono "mono"

export
schemeOfSExp : SExp -> Result SexpError Scheme
schemeOfSExp = rooted decScheme "scheme"

export
effRowOfSExp : SExp -> Result SexpError EffRow
effRowOfSExp = rooted decRow "row"

export
atomOfSExp : SExp -> Result SexpError Atom
atomOfSExp = rooted decAtom "atom"

export
effLabelOfSExp : SExp -> Result SexpError EffLabel
effLabelOfSExp = decLabel "label"

export
authorityOfSExp : SExp -> Result SexpError Authority
authorityOfSExp = rooted decAuth "authority"

export
paramOfSExp : SExp -> Result SexpError Param
paramOfSExp = decParam "param"

export
authResidualOfSExp : SExp -> Result SexpError AuthResidual
authResidualOfSExp = rooted decResidual "residual"

export
vecOblOfSExp : SExp -> Result SexpError VecObl
vecOblOfSExp = rooted decObl "obl"

export
pubSchemeOfSExp : SExp -> Result SexpError PubScheme
pubSchemeOfSExp = rooted decPub "pub"

export
ifaceRefOfSExp : SExp -> Result SexpError IfaceRef
ifaceRefOfSExp = decIface "iface"

export
tyConOriginOfSExp : SExp -> Result SexpError TyConOrigin
tyConOriginOfSExp = decOrigin "origin"

export
bindingOfSExp : SExp -> Result SexpError (String, PubScheme)
bindingOfSExp (SList [SAtom "binding", n, p]) = do
  name <- expectAtom (at "binding" "binding" 1) n
  (_, pub) <- decPub emptyZonk (at "binding" "binding" 2) p
  Ok (name, pub)
bindingOfSExp node = misfit "binding" [("binding", 2)] node
# DESUGAR
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "SexpError" true) (mem "expectAtom" false) (mem "atomInt" false) (mem "atomBool" false))))
(DUse false (UseGroup ("types" "publish") ((mem "PubScheme" true) (mem "ZState" true) (mem "LiveCell" true) (mem "emptyZonk" false) (mem "zonkMono" false) (mem "zonkRow" false) (mem "zonkAuthority" false) (mem "zonkVecObl" false) (mem "zonkScheme" false) (mem "freezePub" false) (mem "liveCells" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "Tyvar" true) (mem "Scheme" true) (mem "AuthResidual" true) (mem "VecObl" true) (mem "IfaceRef" true))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "Effvar" true) (mem "Atom" true) (mem "EffLabel" true))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "TyConOrigin" true))))
(DTypeSig false "tagged" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "SExp")) (TyCon "SExp"))))
(DFunDef false "tagged" ((PVar "head") (PVar "fields")) (EApp (EVar "SList") (EBinOp "::" (EApp (EVar "SAtom") (EVar "head")) (EVar "fields"))))
(DTypeSig false "intNode" (TyFun (TyCon "Int") (TyCon "SExp")))
(DFunDef false "intNode" ((PVar "n")) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "n"))))
(DTypeSig false "boolNode" (TyFun (TyCon "Bool") (TyCon "SExp")))
(DFunDef false "boolNode" ((PVar "b")) (EApp (EVar "SAtom") (EIf (EVar "b") (ELit (LString "true")) (ELit (LString "false")))))
(DTypeSig false "idsNode" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "SExp")))
(DFunDef false "idsNode" ((PVar "ids")) (EApp (EVar "SList") (EApp (EApp (EVar "map") (EVar "intNode")) (EVar "ids"))))
(DTypeSig false "optNode" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "SExp")))
(DFunDef false "optNode" ((PCon "None")) (EApp (EVar "SAtom") (ELit (LString "none"))))
(DFunDef false "optNode" ((PCon "Some" (PVar "s"))) (EApp (EApp (EVar "tagged") (ELit (LString "some"))) (EListLit (EApp (EVar "SAtom") (EVar "s")))))
(DTypeSig false "originNode" (TyFun (TyCon "TyConOrigin") (TyCon "SExp")))
(DFunDef false "originNode" ((PCon "OriginUnresolved")) (EApp (EVar "SAtom") (ELit (LString "unresolved"))))
(DFunDef false "originNode" ((PCon "OriginBuiltin")) (EApp (EVar "SAtom") (ELit (LString "builtin"))))
(DFunDef false "originNode" ((PCon "OriginModule" (PVar "m"))) (EApp (EApp (EVar "tagged") (ELit (LString "module"))) (EListLit (EApp (EVar "SAtom") (EVar "m")))))
(DTypeSig false "paramNode" (TyFun (TyCon "Param") (TyCon "SExp")))
(DFunDef false "paramNode" ((PCon "PUnit")) (EApp (EVar "SAtom") (ELit (LString "unit"))))
(DFunDef false "paramNode" ((PCon "PPrefix" (PVar "s"))) (EApp (EApp (EVar "tagged") (ELit (LString "prefix"))) (EListLit (EApp (EVar "optNode") (EVar "s")))))
(DFunDef false "paramNode" ((PCon "PPath" (PVar "s"))) (EApp (EApp (EVar "tagged") (ELit (LString "path"))) (EListLit (EApp (EVar "optNode") (EVar "s")))))
(DFunDef false "paramNode" ((PCon "PSet" (PCon "None"))) (EApp (EApp (EVar "tagged") (ELit (LString "set"))) (EListLit (EApp (EVar "SAtom") (ELit (LString "none"))))))
(DFunDef false "paramNode" ((PCon "PSet" (PCon "Some" (PVar "members")))) (EApp (EApp (EVar "tagged") (ELit (LString "set"))) (EListLit (EApp (EVar "SList") (EApp (EApp (EVar "map") (EVar "SAtom")) (EVar "members"))))))
(DFunDef false "paramNode" ((PCon "PProduct" (PVar "axes"))) (EApp (EApp (EVar "tagged") (ELit (LString "product"))) (EListLit (EApp (EVar "SList") (EApp (EApp (EVar "map") (ELam ((PVar "axis")) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EApp (EVar "fst") (EVar "axis"))) (EApp (EVar "paramNode") (EApp (EVar "snd") (EVar "axis"))))))) (EVar "axes"))))))
(DTypeSig false "unzonked" (TyFun (TyCon "String") (TyVar "a")))
(DFunDef false "unzonked" ((PVar "what")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "interface_sexp: ")) (EApp (EVar "display") (EVar "what"))) (ELit (LString " reached the printer unzonked")))))
(DTypeSig false "authNode" (TyFun (TyCon "Authority") (TyCon "SExp")))
(DFunDef false "authNode" ((PCon "AConst" (PVar "p"))) (EApp (EApp (EVar "tagged") (ELit (LString "const"))) (EListLit (EApp (EVar "paramNode") (EVar "p")))))
(DFunDef false "authNode" ((PCon "AVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" (PVar "id") (PVar "lvl") (PVar "top") (PVar "pat") (PVar "name")) () (EApp (EApp (EVar "tagged") (ELit (LString "av"))) (EListLit (EApp (EVar "intNode") (EVar "id")) (EApp (EVar "intNode") (EVar "lvl")) (EApp (EVar "paramNode") (EVar "top")) (EApp (EVar "boolNode") (EVar "pat")) (EApp (EVar "optNode") (EVar "name"))))) (arm (PCon "ALink" (PVar "id") PWild PWild) () (EApp (EVar "unzonked") (EBinOp "++" (EBinOp "++" (ELit (LString "the linked authority variable ")) (EApp (EVar "display") (EVar "id"))) (ELit (LString "")))))))
(DFunDef false "authNode" ((PCon "AJoin" (PVar "members"))) (EApp (EApp (EVar "tagged") (ELit (LString "ajoin"))) (EListLit (EApp (EVar "SList") (EApp (EApp (EVar "map") (EVar "authNode")) (EVar "members"))))))
(DFunDef false "authNode" ((PCon "AProduct" (PVar "axes"))) (EApp (EApp (EVar "tagged") (ELit (LString "aproduct"))) (EListLit (EApp (EVar "SList") (EApp (EApp (EVar "map") (ELam ((PVar "axis")) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EApp (EVar "fst") (EVar "axis"))) (EApp (EVar "authNode") (EApp (EVar "snd") (EVar "axis"))))))) (EVar "axes"))))))
(DTypeSig false "labelNode" (TyFun (TyCon "EffLabel") (TyCon "SExp")))
(DFunDef false "labelNode" ((PCon "EffLabel" (PVar "name") (PVar "origin"))) (EApp (EApp (EVar "tagged") (ELit (LString "label"))) (EListLit (EApp (EVar "SAtom") (EVar "name")) (EApp (EVar "originNode") (EVar "origin")))))
(DTypeSig false "atomNode" (TyFun (TyCon "Atom") (TyCon "SExp")))
(DFunDef false "atomNode" ((PCon "Atom" (PVar "label") (PVar "auth"))) (EApp (EApp (EVar "tagged") (ELit (LString "atom"))) (EListLit (EApp (EVar "labelNode") (EVar "label")) (EApp (EVar "authNode") (EVar "auth")))))
(DTypeSig false "rowNode" (TyFun (TyCon "EffRow") (TyCon "SExp")))
(DFunDef false "rowNode" ((PCon "EffRow" (PVar "atoms") (PVar "tail"))) (EApp (EApp (EVar "tagged") (ELit (LString "row"))) (EListLit (EApp (EVar "SList") (EApp (EApp (EVar "map") (EVar "atomNode")) (EVar "atoms"))) (EApp (EVar "tailNode") (EVar "tail")))))
(DTypeSig false "tailNode" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyCon "SExp")))
(DFunDef false "tailNode" ((PCon "None")) (EApp (EVar "SAtom") (ELit (LString "closed"))))
(DFunDef false "tailNode" ((PCon "Some" (PVar "cell"))) (EApp (EVar "effvarNode") (EVar "cell")))
(DTypeSig false "effvarNode" (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "SExp")))
(DFunDef false "effvarNode" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") (PVar "lvl")) () (EApp (EApp (EVar "tagged") (ELit (LString "ev"))) (EListLit (EApp (EVar "intNode") (EVar "id")) (EApp (EVar "intNode") (EVar "lvl"))))) (arm (PCon "EJoin" (PVar "id") (PVar "lvl") (PVar "members")) () (EApp (EApp (EVar "tagged") (ELit (LString "ej"))) (EListLit (EApp (EVar "intNode") (EVar "id")) (EApp (EVar "intNode") (EVar "lvl")) (EApp (EVar "SList") (EApp (EApp (EVar "map") (EVar "effvarNode")) (EVar "members")))))) (arm (PCon "ELink" (PVar "id") (PVar "row")) () (EApp (EApp (EVar "tagged") (ELit (LString "el"))) (EListLit (EApp (EVar "intNode") (EVar "id")) (EApp (EVar "rowNode") (EVar "row"))))) (arm (PCon "ESummary" (PVar "id") PWild PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "interface_sexp: effect summary ")) (EApp (EVar "display") (EVar "id"))) (ELit (LString " is open; a frozen row holds none")))))))
(DTypeSig false "monoNode" (TyFun (TyCon "Mono") (TyCon "SExp")))
(DFunDef false "monoNode" ((PCon "TVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" (PVar "id") (PVar "lvl")) () (EApp (EApp (EVar "tagged") (ELit (LString "tv"))) (EListLit (EApp (EVar "intNode") (EVar "id")) (EApp (EVar "intNode") (EVar "lvl"))))) (arm (PCon "Link" PWild) () (EApp (EVar "unzonked") (ELit (LString "a linked type variable"))))))
(DFunDef false "monoNode" ((PCon "TCon" (PVar "name") (PVar "origin"))) (EApp (EApp (EVar "tagged") (ELit (LString "con"))) (EListLit (EApp (EVar "SAtom") (EVar "name")) (EApp (EVar "originNode") (EVar "origin")))))
(DFunDef false "monoNode" ((PCon "TRigid" (PVar "name"))) (EApp (EApp (EVar "tagged") (ELit (LString "rigid"))) (EListLit (EApp (EVar "SAtom") (EVar "name")))))
(DFunDef false "monoNode" ((PCon "TApp" (PVar "f") (PVar "a"))) (EApp (EApp (EVar "tagged") (ELit (LString "app"))) (EListLit (EApp (EVar "monoNode") (EVar "f")) (EApp (EVar "monoNode") (EVar "a")))))
(DFunDef false "monoNode" ((PCon "TFun" (PVar "a") (PVar "row") (PVar "b"))) (EApp (EApp (EVar "tagged") (ELit (LString "fun"))) (EListLit (EApp (EVar "monoNode") (EVar "a")) (EApp (EVar "rowNode") (EVar "row")) (EApp (EVar "monoNode") (EVar "b")))))
(DFunDef false "monoNode" ((PCon "TEff" (PVar "row"))) (EApp (EApp (EVar "tagged") (ELit (LString "eff"))) (EListLit (EApp (EVar "rowNode") (EVar "row")))))
(DFunDef false "monoNode" ((PCon "TQual" (PVar "m") (PVar "auth"))) (EApp (EApp (EVar "tagged") (ELit (LString "qual"))) (EListLit (EApp (EVar "monoNode") (EVar "m")) (EApp (EVar "authNode") (EVar "auth")))))
(DFunDef false "monoNode" ((PCon "TAuth" (PVar "auth"))) (EApp (EApp (EVar "tagged") (ELit (LString "auth"))) (EListLit (EApp (EVar "authNode") (EVar "auth")))))
(DTypeSig false "residualNode" (TyFun (TyCon "AuthResidual") (TyCon "SExp")))
(DFunDef false "residualNode" ((PRec "AuthResidual" ((rf "arLower" (PVar "lo")) (rf "arUpper" (PVar "hi")) (rf "arExact" (PVar "exact"))) false)) (EApp (EApp (EVar "tagged") (ELit (LString "residual"))) (EListLit (EApp (EVar "authNode") (EVar "lo")) (EApp (EVar "authNode") (EVar "hi")) (EApp (EVar "boolNode") (EVar "exact")))))
(DTypeSig false "ifaceNode" (TyFun (TyCon "IfaceRef") (TyCon "SExp")))
(DFunDef false "ifaceNode" ((PVar "iface")) (EApp (EApp (EVar "tagged") (ELit (LString "iface"))) (EListLit (EApp (EVar "SAtom") (EFieldAccess (EVar "iface") "irName")) (EApp (EVar "originNode") (EFieldAccess (EVar "iface") "irOrigin")))))
(DTypeSig false "oblNode" (TyFun (TyCon "VecObl") (TyCon "SExp")))
(DFunDef false "oblNode" ((PRec "VecObl" ((rf "voIface" (PVar "iface")) (rf "voIds" (PVar "ids")) (rf "voArgs" (PVar "args"))) false)) (EApp (EApp (EVar "tagged") (ELit (LString "obl"))) (EListLit (EApp (EVar "ifaceNode") (EVar "iface")) (EApp (EVar "idsNode") (EVar "ids")) (EApp (EVar "SList") (EApp (EApp (EVar "map") (EVar "monoNode")) (EVar "args"))))))
(DTypeSig false "schemeNode" (TyFun (TyCon "Scheme") (TyCon "SExp")))
(DFunDef false "schemeNode" ((PCon "Forall" (PVar "ids") (PVar "effIds") (PVar "authIds") (PVar "residuals") (PVar "row") (PVar "t"))) (EApp (EApp (EVar "tagged") (ELit (LString "forall"))) (EListLit (EApp (EVar "idsNode") (EVar "ids")) (EApp (EVar "idsNode") (EVar "effIds")) (EApp (EVar "idsNode") (EVar "authIds")) (EApp (EVar "SList") (EApp (EApp (EVar "map") (EVar "residualNode")) (EVar "residuals"))) (EApp (EVar "rowNode") (EVar "row")) (EApp (EVar "monoNode") (EVar "t")))))
(DTypeSig false "pubNode" (TyFun (TyCon "PubScheme") (TyCon "SExp")))
(DFunDef false "pubNode" ((PVar "p")) (EApp (EApp (EVar "tagged") (ELit (LString "pub"))) (EListLit (EApp (EVar "schemeNode") (EFieldAccess (EVar "p") "psScheme")) (EApp (EVar "SList") (EApp (EApp (EVar "map") (EVar "oblNode")) (EFieldAccess (EVar "p") "psContext"))))))
(DTypeSig true "monoSExp" (TyFun (TyCon "Mono") (TyCon "SExp")))
(DFunDef false "monoSExp" ((PVar "m")) (EApp (EVar "monoNode") (EApp (EVar "snd") (EApp (EApp (EVar "zonkMono") (EVar "emptyZonk")) (EVar "m")))))
(DTypeSig true "schemeSExp" (TyFun (TyCon "Scheme") (TyCon "SExp")))
(DFunDef false "schemeSExp" ((PVar "s")) (EApp (EVar "schemeNode") (EApp (EVar "snd") (EApp (EApp (EVar "zonkScheme") (EVar "emptyZonk")) (EVar "s")))))
(DTypeSig true "effRowSExp" (TyFun (TyCon "EffRow") (TyCon "SExp")))
(DFunDef false "effRowSExp" ((PVar "row")) (EApp (EVar "rowNode") (EApp (EVar "snd") (EApp (EApp (EVar "zonkRow") (EVar "emptyZonk")) (EVar "row")))))
(DTypeSig true "atomSExp" (TyFun (TyCon "Atom") (TyCon "SExp")))
(DFunDef false "atomSExp" ((PCon "Atom" (PVar "label") (PVar "auth"))) (EApp (EVar "atomNode") (EApp (EApp (EVar "Atom") (EVar "label")) (EApp (EVar "snd") (EApp (EApp (EVar "zonkAuthority") (EVar "emptyZonk")) (EVar "auth"))))))
(DTypeSig true "effLabelSExp" (TyFun (TyCon "EffLabel") (TyCon "SExp")))
(DFunDef false "effLabelSExp" () (EVar "labelNode"))
(DTypeSig true "authoritySExp" (TyFun (TyCon "Authority") (TyCon "SExp")))
(DFunDef false "authoritySExp" ((PVar "auth")) (EApp (EVar "authNode") (EApp (EVar "snd") (EApp (EApp (EVar "zonkAuthority") (EVar "emptyZonk")) (EVar "auth")))))
(DTypeSig true "paramSExp" (TyFun (TyCon "Param") (TyCon "SExp")))
(DFunDef false "paramSExp" () (EVar "paramNode"))
(DTypeSig true "authResidualSExp" (TyFun (TyCon "AuthResidual") (TyCon "SExp")))
(DFunDef false "authResidualSExp" ((PVar "r")) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "lo")) (EApp (EApp (EVar "zonkAuthority") (EVar "emptyZonk")) (EFieldAccess (EVar "r") "arLower"))) (DoLet false false (PTuple PWild (PVar "hi")) (EApp (EApp (EVar "zonkAuthority") (EVar "z1")) (EFieldAccess (EVar "r") "arUpper"))) (DoExpr (EApp (EVar "residualNode") (ERecordUpdate (EVar "r") ((fa "arLower" (EVar "lo")) (fa "arUpper" (EVar "hi"))))))))
(DTypeSig true "vecOblSExp" (TyFun (TyCon "VecObl") (TyCon "SExp")))
(DFunDef false "vecOblSExp" ((PVar "o")) (EApp (EVar "oblNode") (EApp (EVar "snd") (EApp (EApp (EVar "zonkVecObl") (EVar "emptyZonk")) (EVar "o")))))
(DTypeSig true "pubSchemeSExp" (TyFun (TyCon "PubScheme") (TyCon "SExp")))
(DFunDef false "pubSchemeSExp" ((PVar "p")) (EApp (EVar "pubNode") (EApp (EApp (EVar "freezePub") (EFieldAccess (EVar "p") "psScheme")) (EFieldAccess (EVar "p") "psContext"))))
(DTypeSig true "ifaceRefSExp" (TyFun (TyCon "IfaceRef") (TyCon "SExp")))
(DFunDef false "ifaceRefSExp" () (EVar "ifaceNode"))
(DTypeSig true "tyConOriginSExp" (TyFun (TyCon "TyConOrigin") (TyCon "SExp")))
(DFunDef false "tyConOriginSExp" () (EVar "originNode"))
(DTypeSig false "notFrozen" (TyFun (TyCon "LiveCell") (TyCon "Bool")))
(DFunDef false "notFrozen" ((PCon "LinkCell" PWild PWild PWild)) (EVar "True"))
(DFunDef false "notFrozen" ((PCon "OpenSummary" PWild PWild)) (EVar "True"))
(DFunDef false "notFrozen" (PWild) (EVar "False"))
(DTypeSig true "bindingSExp" (TyFun (TyCon "String") (TyFun (TyCon "PubScheme") (TyCon "SExp"))))
(DFunDef false "bindingSExp" ((PVar "name") (PVar "p")) (EMatch (EApp (EApp (EVar "filter") (EVar "notFrozen")) (EApp (EApp (EVar "liveCells") (EVar "name")) (EVar "p"))) (arm (PList) () (EApp (EApp (EVar "tagged") (ELit (LString "binding"))) (EListLit (EApp (EVar "SAtom") (EVar "name")) (EApp (EVar "pubSchemeSExp") (EVar "p"))))) (arm (PVar "faults") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "interface row ")) (EApp (EVar "display") (EVar "name"))) (ELit (LString " is not frozen: "))) (EApp (EVar "display") (EApp (EVar "debug") (EVar "faults")))) (ELit (LString "")))))))
(DTypeAlias false "Dec" ("a") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "ZState") (TyVar "a"))))
(DTypeSig false "headOf" (TyFun (TyCon "SExp") (TyCon "String")))
(DFunDef false "headOf" ((PCon "SAtom" (PVar "s"))) (EVar "s"))
(DFunDef false "headOf" ((PCon "SList" (PCons (PCon "SAtom" (PVar "h")) PWild))) (EVar "h"))
(DFunDef false "headOf" ((PCon "SList" PWild)) (ELit (LString "a list")))
(DTypeSig false "refuse" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a"))))))
(DFunDef false "refuse" ((PVar "path") (PVar "node") (PVar "what")) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (EVar "path")) (fa "seWhat" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "headOf") (EVar "node")))) (ELit (LString ": "))) (EApp (EVar "display") (EVar "what"))) (ELit (LString ""))))))))
(DTypeSig false "misfit" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a"))))))
(DFunDef false "misfit" ((PVar "path") (PVar "heads") (PVar "node")) (EMatch (EApp (EApp (EVar "find") (ELam ((PVar "h")) (EBinOp "==" (EApp (EVar "fst") (EVar "h")) (EApp (EVar "headOf") (EVar "node"))))) (EVar "heads")) (arm (PCon "Some" (PTuple PWild (PVar "n"))) () (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EVar "display") (EVar "n"))) (ELit (LString " field(s)"))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (EBinOp "++" (EBinOp "++" (ELit (LString "unknown head; expected one of ")) (EApp (EVar "display") (EApp (EApp (EVar "stringJoin") (ELit (LString ", "))) (EApp (EApp (EVar "map") (EVar "fst")) (EVar "heads"))))) (ELit (LString "")))))))
(DTypeSig false "at" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "at" ((PVar "path") (PVar "head") (PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "/"))) (EApp (EVar "display") (EVar "head"))) (ELit (LString "."))) (EApp (EVar "display") (EVar "i"))) (ELit (LString ""))))
(DTypeSig false "stateless" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))) (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyVar "a")))))))
(DFunDef false "stateless" ((PVar "f") (PVar "z") (PVar "path") (PVar "node")) (EApp (EApp (EVar "map") (ELam ((PVar "v")) (ETuple (EVar "z") (EVar "v")))) (EApp (EApp (EVar "f") (EVar "path")) (EVar "node"))))
(DTypeSig false "decEach" (TyFun (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyVar "a"))))) (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyApp (TyCon "List") (TyVar "a"))))))))
(DFunDef false "decEach" ((PVar "f") (PVar "z") (PVar "path") (PCon "SList" (PVar "items"))) (EApp (EApp (EApp (EApp (EApp (EVar "decItems") (EVar "f")) (EVar "z")) (EVar "path")) (ELit (LInt 0))) (EVar "items")))
(DFunDef false "decEach" (PWild PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "expected a list"))))
(DTypeSig false "decItems" (TyFun (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyVar "a"))))) (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "SExp")) (TyApp (TyCon "Dec") (TyApp (TyCon "List") (TyVar "a")))))))))
(DFunDef false "decItems" (PWild (PVar "z") PWild PWild (PList)) (EApp (EVar "Ok") (ETuple (EVar "z") (EListLit))))
(DFunDef false "decItems" ((PVar "f") (PVar "z") (PVar "path") (PVar "i") (PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "f") (EVar "z")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "/"))) (EApp (EVar "display") (EVar "i"))) (ELit (LString "")))) (EVar "x"))) (ELam ((PTuple (PVar "z1") (PVar "y"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EApp (EVar "decItems") (EVar "f")) (EVar "z1")) (EVar "path")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))) (ELam ((PTuple (PVar "z2") (PVar "ys"))) (EApp (EVar "Ok") (ETuple (EVar "z2") (EBinOp "::" (EVar "y") (EVar "ys")))))))))
(DTypeSig false "decList" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))) (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "decList" ((PVar "f") (PVar "path") (PVar "node")) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EApp (EApp (EApp (EVar "decEach") (EApp (EVar "stateless") (EVar "f"))) (EVar "emptyZonk")) (EVar "path")) (EVar "node"))))
(DTypeSig false "same" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyFun (TyCon "SExp") (TyFun (TyVar "a") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))))))
(DFunDef false "same" ((PVar "path") (PVar "node") (PVar "first") (PVar "v")) (EIf (EBinOp "==" (EVar "node") (EVar "first")) (EApp (EVar "Ok") (EVar "v")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "this id was written differently before")))))
(DTypeSig false "decOpt" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "decOpt" (PWild (PCon "SAtom" (PLit (LString "none")))) (EApp (EVar "Ok") (EVar "None")))
(DFunDef false "decOpt" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "some"))) (PVar "s")))) (EApp (EApp (EVar "map") (EVar "Some")) (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "some"))) (ELit (LInt 1)))) (EVar "s"))))
(DFunDef false "decOpt" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "none")) (ELit (LInt 0))) (ETuple (ELit (LString "some")) (ELit (LInt 1))))) (EVar "node")))
(DTypeSig false "decOrigin" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "TyConOrigin")))))
(DFunDef false "decOrigin" (PWild (PCon "SAtom" (PLit (LString "unresolved")))) (EApp (EVar "Ok") (EVar "OriginUnresolved")))
(DFunDef false "decOrigin" (PWild (PCon "SAtom" (PLit (LString "builtin")))) (EApp (EVar "Ok") (EVar "OriginBuiltin")))
(DFunDef false "decOrigin" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "module"))) (PVar "m")))) (EApp (EApp (EVar "map") (EVar "OriginModule")) (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "module"))) (ELit (LInt 1)))) (EVar "m"))))
(DFunDef false "decOrigin" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "unresolved")) (ELit (LInt 0))) (ETuple (ELit (LString "builtin")) (ELit (LInt 0))) (ETuple (ELit (LString "module")) (ELit (LInt 1))))) (EVar "node")))
(DTypeSig false "paramHeads" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "paramHeads" () (EListLit (ETuple (ELit (LString "unit")) (ELit (LInt 0))) (ETuple (ELit (LString "prefix")) (ELit (LInt 1))) (ETuple (ELit (LString "path")) (ELit (LInt 1))) (ETuple (ELit (LString "set")) (ELit (LInt 1))) (ETuple (ELit (LString "product")) (ELit (LInt 1)))))
(DTypeSig false "decParam" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Param")))))
(DFunDef false "decParam" (PWild (PCon "SAtom" (PLit (LString "unit")))) (EApp (EVar "Ok") (EVar "PUnit")))
(DFunDef false "decParam" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "prefix"))) (PVar "s")))) (EApp (EApp (EVar "map") (EVar "PPrefix")) (EApp (EApp (EVar "decOpt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "prefix"))) (ELit (LInt 1)))) (EVar "s"))))
(DFunDef false "decParam" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "path"))) (PVar "s")))) (EApp (EApp (EVar "map") (EVar "PPath")) (EApp (EApp (EVar "decOpt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "path"))) (ELit (LInt 1)))) (EVar "s"))))
(DFunDef false "decParam" (PWild (PCon "SList" (PList (PCon "SAtom" (PLit (LString "set"))) (PCon "SAtom" (PLit (LString "none")))))) (EApp (EVar "Ok") (EApp (EVar "PSet") (EVar "None"))))
(DFunDef false "decParam" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "set"))) (PVar "members")))) (EApp (EApp (EVar "map") (ELam ((PVar "ms")) (EApp (EVar "PSet") (EApp (EVar "Some") (EVar "ms"))))) (EApp (EApp (EApp (EVar "decList") (EVar "expectAtom")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "set"))) (ELit (LInt 1)))) (EVar "members"))))
(DFunDef false "decParam" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "product"))) (PVar "axes")))) (EApp (EApp (EVar "map") (EVar "PProduct")) (EApp (EApp (EApp (EVar "decList") (EVar "decParamAxis")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "product"))) (ELit (LInt 1)))) (EVar "axes"))))
(DFunDef false "decParam" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EVar "paramHeads")) (EVar "node")))
(DTypeSig false "decParamAxis" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "decParamAxis" ((PVar "path") (PCon "SList" (PList (PVar "n") (PVar "p")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "/0")))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decParam") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "/1")))) (EVar "p"))) (ELam ((PVar "param")) (EApp (EVar "Ok") (ETuple (EVar "name") (EVar "param"))))))))
(DFunDef false "decParamAxis" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "expected an axis (NAME PARAM)"))))
(DTypeSig false "authHeads" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "authHeads" () (EListLit (ETuple (ELit (LString "const")) (ELit (LInt 1))) (ETuple (ELit (LString "av")) (ELit (LInt 5))) (ETuple (ELit (LString "ajoin")) (ELit (LInt 1))) (ETuple (ELit (LString "aproduct")) (ELit (LInt 1)))))
(DTypeSig false "decAuth" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "Authority"))))))
(DFunDef false "decAuth" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "const"))) (PVar "p")))) (EApp (EApp (EVar "map") (ELam ((PVar "q")) (ETuple (EVar "z") (EApp (EVar "AConst") (EVar "q"))))) (EApp (EApp (EVar "decParam") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "const"))) (ELit (LInt 1)))) (EVar "p"))))
(DFunDef false "decAuth" ((PVar "z") (PVar "path") (PAs "node" (PCon "SList" (PList (PCon "SAtom" (PLit (LString "av"))) (PVar "i") (PVar "l") (PVar "top") (PVar "pat") (PVar "name"))))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "av"))) (ELit (LInt 1)))) (EVar "i"))) (ELam ((PVar "id")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "av"))) (ELit (LInt 2)))) (EVar "l"))) (ELam ((PVar "lvl")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decParam") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "av"))) (ELit (LInt 3)))) (EVar "top"))) (ELam ((PVar "domain")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "av"))) (ELit (LInt 4)))) (EVar "pat"))) (ELam ((PVar "patterned")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decOpt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "av"))) (ELit (LInt 5)))) (EVar "name"))) (ELam ((PVar "binder")) (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EVar "z") "zAuths")) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EVar "same") (EVar "path")) (EVar "node")) (EApp (EVar "authNode") (EApp (EVar "AVar") (EVar "c")))) (ETuple (EVar "z") (EApp (EVar "AVar") (EVar "c"))))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "c") (EApp (EVar "Ref") (EApp (EApp (EApp (EApp (EApp (EVar "AUnbound") (EVar "id")) (EVar "lvl")) (EVar "domain")) (EVar "patterned")) (EVar "binder")))) (DoExpr (EApp (EVar "Ok") (ETuple (ERecordUpdate (EVar "z") ((fa "zAuths" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "c")) (EFieldAccess (EVar "z") "zAuths"))))) (EApp (EVar "AVar") (EVar "c")))))))))))))))))))
(DFunDef false "decAuth" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "ajoin"))) (PVar "members")))) (EApp (EApp (EVar "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "fst") (EVar "r")) (EApp (EVar "AJoin") (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decAuth")) (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ajoin"))) (ELit (LInt 1)))) (EVar "members"))))
(DFunDef false "decAuth" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "aproduct"))) (PVar "axes")))) (EApp (EApp (EVar "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "fst") (EVar "r")) (EApp (EVar "AProduct") (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decAuthAxis")) (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "aproduct"))) (ELit (LInt 1)))) (EVar "axes"))))
(DFunDef false "decAuth" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EVar "authHeads")) (EVar "node")))
(DTypeSig false "decAuthAxis" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyTuple (TyCon "String") (TyCon "Authority")))))))
(DFunDef false "decAuthAxis" ((PVar "z") (PVar "path") (PCon "SList" (PList (PVar "n") (PVar "a")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "/0")))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decAuth") (EVar "z")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "/1")))) (EVar "a"))) (ELam ((PTuple (PVar "z1") (PVar "auth"))) (EApp (EVar "Ok") (ETuple (EVar "z1") (ETuple (EVar "name") (EVar "auth")))))))))
(DFunDef false "decAuthAxis" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "expected an axis (NAME AUTH)"))))
(DTypeSig false "decLabel" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "EffLabel")))))
(DFunDef false "decLabel" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "label"))) (PVar "n") (PVar "o")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "label"))) (ELit (LInt 1)))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "label"))) (ELit (LInt 2)))) (EVar "o"))) (ELam ((PVar "origin")) (EApp (EVar "Ok") (EApp (EApp (EVar "EffLabel") (EVar "name")) (EVar "origin"))))))))
(DFunDef false "decLabel" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "label")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "decAtom" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "Atom"))))))
(DFunDef false "decAtom" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "atom"))) (PVar "l") (PVar "a")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decLabel") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "atom"))) (ELit (LInt 1)))) (EVar "l"))) (ELam ((PVar "label")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decAuth") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "atom"))) (ELit (LInt 2)))) (EVar "a"))) (ELam ((PTuple (PVar "z1") (PVar "auth"))) (EApp (EVar "Ok") (ETuple (EVar "z1") (EApp (EApp (EVar "Atom") (EVar "label")) (EVar "auth")))))))))
(DFunDef false "decAtom" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "atom")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "decRow" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "EffRow"))))))
(DFunDef false "decRow" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "row"))) (PVar "atoms") (PVar "tail")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decAtom")) (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "row"))) (ELit (LInt 1)))) (EVar "atoms"))) (ELam ((PTuple (PVar "z1") (PVar "atoms1"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decTail") (EVar "z1")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "row"))) (ELit (LInt 2)))) (EVar "tail"))) (ELam ((PTuple (PVar "z2") (PVar "tail1"))) (EApp (EVar "Ok") (ETuple (EVar "z2") (EApp (EApp (EVar "EffRow") (EVar "atoms1")) (EVar "tail1")))))))))
(DFunDef false "decRow" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "row")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "decTail" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyCon "Effvar"))))))))
(DFunDef false "decTail" ((PVar "z") PWild (PCon "SAtom" (PLit (LString "closed")))) (EApp (EVar "Ok") (ETuple (EVar "z") (EVar "None"))))
(DFunDef false "decTail" ((PVar "z") (PVar "path") (PVar "node")) (EApp (EApp (EVar "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "fst") (EVar "r")) (EApp (EVar "Some") (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EApp (EApp (EVar "decEffvar") (EVar "False")) (EVar "z")) (EVar "path")) (EVar "node"))))
(DTypeSig false "memoEff" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "ZState") (TyApp (TyCon "Dec") (TyCon "Effvar"))) (TyApp (TyCon "Dec") (TyApp (TyCon "Ref") (TyCon "Effvar")))))))))
(DFunDef false "memoEff" ((PVar "z") (PVar "path") (PVar "node") (PVar "id") (PVar "build")) (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EVar "z") "zEffs")) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EVar "same") (EVar "path")) (EVar "node")) (EApp (EVar "effvarNode") (EVar "c"))) (ETuple (EVar "z") (EVar "c")))) (arm (PCon "None") () (EApp (EApp (EVar "andThen") (EApp (EVar "build") (EVar "z"))) (ELam ((PTuple (PVar "z1") (PVar "v"))) (ELet false (PVar "c") (EApp (EVar "Ref") (EVar "v")) (EApp (EVar "Ok") (ETuple (ERecordUpdate (EVar "z1") ((fa "zEffs" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "c")) (EFieldAccess (EVar "z1") "zEffs"))))) (EVar "c")))))))))
(DTypeSig false "effvarHeads" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "effvarHeads" () (EListLit (ETuple (ELit (LString "closed")) (ELit (LInt 0))) (ETuple (ELit (LString "ev")) (ELit (LInt 2))) (ETuple (ELit (LString "ej")) (ELit (LInt 3))) (ETuple (ELit (LString "el")) (ELit (LInt 2)))))
(DTypeSig false "decEffvar" (TyFun (TyCon "Bool") (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyApp (TyCon "Ref") (TyCon "Effvar"))))))))
(DFunDef false "decEffvar" (PWild (PVar "z") (PVar "path") (PAs "node" (PCon "SList" (PList (PCon "SAtom" (PLit (LString "ev"))) (PVar "i") (PVar "l"))))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ev"))) (ELit (LInt 1)))) (EVar "i"))) (ELam ((PVar "id")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ev"))) (ELit (LInt 2)))) (EVar "l"))) (ELam ((PVar "lvl")) (EApp (EApp (EApp (EApp (EApp (EVar "memoEff") (EVar "z")) (EVar "path")) (EVar "node")) (EVar "id")) (ELam ((PVar "z0")) (EApp (EVar "Ok") (ETuple (EVar "z0") (EApp (EApp (EVar "EUnbound") (EVar "id")) (EVar "lvl")))))))))))
(DFunDef false "decEffvar" (PWild (PVar "z") (PVar "path") (PAs "node" (PCon "SList" (PList (PCon "SAtom" (PLit (LString "ej"))) (PVar "i") (PVar "l") (PVar "members"))))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ej"))) (ELit (LInt 1)))) (EVar "i"))) (ELam ((PVar "id")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ej"))) (ELit (LInt 2)))) (EVar "l"))) (ELam ((PVar "lvl")) (EApp (EApp (EApp (EApp (EApp (EVar "memoEff") (EVar "z")) (EVar "path")) (EVar "node")) (EVar "id")) (ELam ((PVar "z0")) (EApp (EApp (EVar "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "fst") (EVar "r")) (EApp (EApp (EApp (EVar "EJoin") (EVar "id")) (EVar "lvl")) (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EApp (EApp (EVar "decEach") (EApp (EVar "decEffvar") (EVar "True"))) (EVar "z0")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ej"))) (ELit (LInt 3)))) (EVar "members"))))))))))
(DFunDef false "decEffvar" ((PCon "True") (PVar "z") (PVar "path") (PAs "node" (PCon "SList" (PList (PCon "SAtom" (PLit (LString "el"))) (PVar "i") (PVar "row"))))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "el"))) (ELit (LInt 1)))) (EVar "i"))) (ELam ((PVar "id")) (EApp (EApp (EApp (EApp (EApp (EVar "memoEff") (EVar "z")) (EVar "path")) (EVar "node")) (EVar "id")) (ELam ((PVar "z0")) (EApp (EApp (EVar "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "fst") (EVar "r")) (EApp (EApp (EVar "ELink") (EVar "id")) (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EApp (EVar "decRow") (EVar "z0")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "el"))) (ELit (LInt 2)))) (EVar "row"))))))))
(DFunDef false "decEffvar" ((PCon "False") PWild (PVar "path") (PAs "node" (PCon "SList" (PList (PCon "SAtom" (PLit (LString "el"))) PWild PWild)))) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "a row tail is never a link"))))
(DFunDef false "decEffvar" (PWild PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EVar "effvarHeads")) (EVar "node")))
(DTypeSig false "monoHeads" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "monoHeads" () (EListLit (ETuple (ELit (LString "tv")) (ELit (LInt 2))) (ETuple (ELit (LString "con")) (ELit (LInt 2))) (ETuple (ELit (LString "rigid")) (ELit (LInt 1))) (ETuple (ELit (LString "app")) (ELit (LInt 2))) (ETuple (ELit (LString "fun")) (ELit (LInt 3))) (ETuple (ELit (LString "eff")) (ELit (LInt 1))) (ETuple (ELit (LString "qual")) (ELit (LInt 2))) (ETuple (ELit (LString "auth")) (ELit (LInt 1)))))
(DTypeSig false "decMono" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "Mono"))))))
(DFunDef false "decMono" ((PVar "z") (PVar "path") (PAs "node" (PCon "SList" (PList (PCon "SAtom" (PLit (LString "tv"))) (PVar "i") (PVar "l"))))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tv"))) (ELit (LInt 1)))) (EVar "i"))) (ELam ((PVar "id")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tv"))) (ELit (LInt 2)))) (EVar "l"))) (ELam ((PVar "lvl")) (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EVar "z") "zTys")) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EVar "same") (EVar "path")) (EVar "node")) (EApp (EVar "monoNode") (EApp (EVar "TVar") (EVar "c")))) (ETuple (EVar "z") (EApp (EVar "TVar") (EVar "c"))))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "c") (EApp (EVar "Ref") (EApp (EApp (EVar "Unbound") (EVar "id")) (EVar "lvl")))) (DoExpr (EApp (EVar "Ok") (ETuple (ERecordUpdate (EVar "z") ((fa "zTys" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "c")) (EFieldAccess (EVar "z") "zTys"))))) (EApp (EVar "TVar") (EVar "c")))))))))))))
(DFunDef false "decMono" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "con"))) (PVar "n") (PVar "o")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "con"))) (ELit (LInt 1)))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "con"))) (ELit (LInt 2)))) (EVar "o"))) (ELam ((PVar "origin")) (EApp (EVar "Ok") (ETuple (EVar "z") (EApp (EApp (EVar "TCon") (EVar "name")) (EVar "origin")))))))))
(DFunDef false "decMono" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "rigid"))) (PVar "n")))) (EApp (EApp (EVar "map") (ELam ((PVar "name")) (ETuple (EVar "z") (EApp (EVar "TRigid") (EVar "name"))))) (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "rigid"))) (ELit (LInt 1)))) (EVar "n"))))
(DFunDef false "decMono" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "app"))) (PVar "f") (PVar "a")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decMono") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "app"))) (ELit (LInt 1)))) (EVar "f"))) (ELam ((PTuple (PVar "z1") (PVar "f1"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decMono") (EVar "z1")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "app"))) (ELit (LInt 2)))) (EVar "a"))) (ELam ((PTuple (PVar "z2") (PVar "a1"))) (EApp (EVar "Ok") (ETuple (EVar "z2") (EApp (EApp (EVar "TApp") (EVar "f1")) (EVar "a1")))))))))
(DFunDef false "decMono" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "fun"))) (PVar "a") (PVar "row") (PVar "b")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decMono") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "fun"))) (ELit (LInt 1)))) (EVar "a"))) (ELam ((PTuple (PVar "z1") (PVar "a1"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decRow") (EVar "z1")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "fun"))) (ELit (LInt 2)))) (EVar "row"))) (ELam ((PTuple (PVar "z2") (PVar "row1"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decMono") (EVar "z2")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "fun"))) (ELit (LInt 3)))) (EVar "b"))) (ELam ((PTuple (PVar "z3") (PVar "b1"))) (EApp (EVar "Ok") (ETuple (EVar "z3") (EApp (EApp (EApp (EVar "TFun") (EVar "a1")) (EVar "row1")) (EVar "b1")))))))))))
(DFunDef false "decMono" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "eff"))) (PVar "row")))) (EApp (EApp (EVar "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "fst") (EVar "r")) (EApp (EVar "TEff") (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EApp (EVar "decRow") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "eff"))) (ELit (LInt 1)))) (EVar "row"))))
(DFunDef false "decMono" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "qual"))) (PVar "m") (PVar "a")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decMono") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "qual"))) (ELit (LInt 1)))) (EVar "m"))) (ELam ((PTuple (PVar "z1") (PVar "m1"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decAuth") (EVar "z1")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "qual"))) (ELit (LInt 2)))) (EVar "a"))) (ELam ((PTuple (PVar "z2") (PVar "a1"))) (EApp (EVar "Ok") (ETuple (EVar "z2") (EApp (EApp (EVar "TQual") (EVar "m1")) (EVar "a1")))))))))
(DFunDef false "decMono" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "auth"))) (PVar "a")))) (EApp (EApp (EVar "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "fst") (EVar "r")) (EApp (EVar "TAuth") (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EApp (EVar "decAuth") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "auth"))) (ELit (LInt 1)))) (EVar "a"))))
(DFunDef false "decMono" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EVar "monoHeads")) (EVar "node")))
(DTypeSig false "decResidual" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "AuthResidual"))))))
(DFunDef false "decResidual" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "residual"))) (PVar "lo") (PVar "hi") (PVar "ex")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decAuth") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "residual"))) (ELit (LInt 1)))) (EVar "lo"))) (ELam ((PTuple (PVar "z1") (PVar "lower"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decAuth") (EVar "z1")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "residual"))) (ELit (LInt 2)))) (EVar "hi"))) (ELam ((PTuple (PVar "z2") (PVar "upper"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "residual"))) (ELit (LInt 3)))) (EVar "ex"))) (ELam ((PVar "exact")) (EApp (EVar "Ok") (ETuple (EVar "z2") (ERecordCreate "AuthResidual" ((fa "arLower" (EVar "lower")) (fa "arUpper" (EVar "upper")) (fa "arExact" (EVar "exact")))))))))))))
(DFunDef false "decResidual" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "residual")) (ELit (LInt 3))))) (EVar "node")))
(DTypeSig false "decIface" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "IfaceRef")))))
(DFunDef false "decIface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "iface"))) (PVar "n") (PVar "o")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "iface"))) (ELit (LInt 1)))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "iface"))) (ELit (LInt 2)))) (EVar "o"))) (ELam ((PVar "origin")) (EApp (EVar "Ok") (ERecordCreate "IfaceRef" ((fa "irName" (EVar "name")) (fa "irOrigin" (EVar "origin"))))))))))
(DFunDef false "decIface" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "iface")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "decObl" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "VecObl"))))))
(DFunDef false "decObl" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "obl"))) (PVar "i") (PVar "ids") (PVar "args")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decIface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "obl"))) (ELit (LInt 1)))) (EVar "i"))) (ELam ((PVar "iface")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "atomInt")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "obl"))) (ELit (LInt 2)))) (EVar "ids"))) (ELam ((PVar "ids1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decMono")) (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "obl"))) (ELit (LInt 3)))) (EVar "args"))) (ELam ((PTuple (PVar "z1") (PVar "args1"))) (EApp (EVar "Ok") (ETuple (EVar "z1") (ERecordCreate "VecObl" ((fa "voIface" (EVar "iface")) (fa "voIds" (EVar "ids1")) (fa "voArgs" (EVar "args1")))))))))))))
(DFunDef false "decObl" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "obl")) (ELit (LInt 3))))) (EVar "node")))
(DTypeSig false "decScheme" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "Scheme"))))))
(DFunDef false "decScheme" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "forall"))) (PVar "ids") (PVar "effIds") (PVar "authIds") (PVar "rs") (PVar "row") (PVar "t")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "atomInt")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "forall"))) (ELit (LInt 1)))) (EVar "ids"))) (ELam ((PVar "ids1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "atomInt")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "forall"))) (ELit (LInt 2)))) (EVar "effIds"))) (ELam ((PVar "effIds1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "atomInt")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "forall"))) (ELit (LInt 3)))) (EVar "authIds"))) (ELam ((PVar "authIds1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decResidual")) (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "forall"))) (ELit (LInt 4)))) (EVar "rs"))) (ELam ((PTuple (PVar "z1") (PVar "rs1"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decRow") (EVar "z1")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "forall"))) (ELit (LInt 5)))) (EVar "row"))) (ELam ((PTuple (PVar "z2") (PVar "row1"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decMono") (EVar "z2")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "forall"))) (ELit (LInt 6)))) (EVar "t"))) (ELam ((PTuple (PVar "z3") (PVar "t1"))) (EApp (EVar "Ok") (ETuple (EVar "z3") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EVar "ids1")) (EVar "effIds1")) (EVar "authIds1")) (EVar "rs1")) (EVar "row1")) (EVar "t1")))))))))))))))))
(DFunDef false "decScheme" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "forall")) (ELit (LInt 6))))) (EVar "node")))
(DTypeSig false "decPub" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "PubScheme"))))))
(DFunDef false "decPub" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "pub"))) (PVar "s") (PVar "ctx")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decScheme") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "pub"))) (ELit (LInt 1)))) (EVar "s"))) (ELam ((PTuple (PVar "z1") (PVar "scheme"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decObl")) (EVar "z1")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "pub"))) (ELit (LInt 2)))) (EVar "ctx"))) (ELam ((PTuple (PVar "z2") (PVar "obls"))) (EApp (EVar "Ok") (ETuple (EVar "z2") (ERecordCreate "PubScheme" ((fa "psScheme" (EVar "scheme")) (fa "psContext" (EVar "obls")))))))))))
(DFunDef false "decPub" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "pub")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "rooted" (TyFun (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyVar "a"))))) (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a"))))))
(DFunDef false "rooted" ((PVar "dec") (PVar "root") (PVar "node")) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EApp (EApp (EVar "dec") (EVar "emptyZonk")) (EVar "root")) (EVar "node"))))
(DTypeSig true "monoOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Mono"))))
(DFunDef false "monoOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decMono")) (ELit (LString "mono"))))
(DTypeSig true "schemeOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Scheme"))))
(DFunDef false "schemeOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decScheme")) (ELit (LString "scheme"))))
(DTypeSig true "effRowOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "EffRow"))))
(DFunDef false "effRowOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decRow")) (ELit (LString "row"))))
(DTypeSig true "atomOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Atom"))))
(DFunDef false "atomOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decAtom")) (ELit (LString "atom"))))
(DTypeSig true "effLabelOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "EffLabel"))))
(DFunDef false "effLabelOfSExp" () (EApp (EVar "decLabel") (ELit (LString "label"))))
(DTypeSig true "authorityOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Authority"))))
(DFunDef false "authorityOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decAuth")) (ELit (LString "authority"))))
(DTypeSig true "paramOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Param"))))
(DFunDef false "paramOfSExp" () (EApp (EVar "decParam") (ELit (LString "param"))))
(DTypeSig true "authResidualOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "AuthResidual"))))
(DFunDef false "authResidualOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decResidual")) (ELit (LString "residual"))))
(DTypeSig true "vecOblOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "VecObl"))))
(DFunDef false "vecOblOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decObl")) (ELit (LString "obl"))))
(DTypeSig true "pubSchemeOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "PubScheme"))))
(DFunDef false "pubSchemeOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decPub")) (ELit (LString "pub"))))
(DTypeSig true "ifaceRefOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "IfaceRef"))))
(DFunDef false "ifaceRefOfSExp" () (EApp (EVar "decIface") (ELit (LString "iface"))))
(DTypeSig true "tyConOriginOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "TyConOrigin"))))
(DFunDef false "tyConOriginOfSExp" () (EApp (EVar "decOrigin") (ELit (LString "origin"))))
(DTypeSig true "bindingOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "String") (TyCon "PubScheme")))))
(DFunDef false "bindingOfSExp" ((PCon "SList" (PList (PCon "SAtom" (PLit (LString "binding"))) (PVar "n") (PVar "p")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (ELit (LString "binding"))) (ELit (LString "binding"))) (ELit (LInt 1)))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decPub") (EVar "emptyZonk")) (EApp (EApp (EApp (EVar "at") (ELit (LString "binding"))) (ELit (LString "binding"))) (ELit (LInt 2)))) (EVar "p"))) (ELam ((PTuple PWild (PVar "pub"))) (EApp (EVar "Ok") (ETuple (EVar "name") (EVar "pub"))))))))
(DFunDef false "bindingOfSExp" ((PVar "node")) (EApp (EApp (EApp (EVar "misfit") (ELit (LString "binding"))) (EListLit (ETuple (ELit (LString "binding")) (ELit (LInt 2))))) (EVar "node")))
# MARK
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "SexpError" true) (mem "expectAtom" false) (mem "atomInt" false) (mem "atomBool" false))))
(DUse false (UseGroup ("types" "publish") ((mem "PubScheme" true) (mem "ZState" true) (mem "LiveCell" true) (mem "emptyZonk" false) (mem "zonkMono" false) (mem "zonkRow" false) (mem "zonkAuthority" false) (mem "zonkVecObl" false) (mem "zonkScheme" false) (mem "freezePub" false) (mem "liveCells" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "Tyvar" true) (mem "Scheme" true) (mem "AuthResidual" true) (mem "VecObl" true) (mem "IfaceRef" true))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "Effvar" true) (mem "Atom" true) (mem "EffLabel" true))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "TyConOrigin" true))))
(DTypeSig false "tagged" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "SExp")) (TyCon "SExp"))))
(DFunDef false "tagged" ((PVar "head") (PVar "fields")) (EApp (EVar "SList") (EBinOp "::" (EApp (EVar "SAtom") (EVar "head")) (EVar "fields"))))
(DTypeSig false "intNode" (TyFun (TyCon "Int") (TyCon "SExp")))
(DFunDef false "intNode" ((PVar "n")) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "n"))))
(DTypeSig false "boolNode" (TyFun (TyCon "Bool") (TyCon "SExp")))
(DFunDef false "boolNode" ((PVar "b")) (EApp (EVar "SAtom") (EIf (EVar "b") (ELit (LString "true")) (ELit (LString "false")))))
(DTypeSig false "idsNode" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "SExp")))
(DFunDef false "idsNode" ((PVar "ids")) (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (EVar "intNode")) (EVar "ids"))))
(DTypeSig false "optNode" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "SExp")))
(DFunDef false "optNode" ((PCon "None")) (EApp (EVar "SAtom") (ELit (LString "none"))))
(DFunDef false "optNode" ((PCon "Some" (PVar "s"))) (EApp (EApp (EVar "tagged") (ELit (LString "some"))) (EListLit (EApp (EVar "SAtom") (EVar "s")))))
(DTypeSig false "originNode" (TyFun (TyCon "TyConOrigin") (TyCon "SExp")))
(DFunDef false "originNode" ((PCon "OriginUnresolved")) (EApp (EVar "SAtom") (ELit (LString "unresolved"))))
(DFunDef false "originNode" ((PCon "OriginBuiltin")) (EApp (EVar "SAtom") (ELit (LString "builtin"))))
(DFunDef false "originNode" ((PCon "OriginModule" (PVar "m"))) (EApp (EApp (EVar "tagged") (ELit (LString "module"))) (EListLit (EApp (EVar "SAtom") (EVar "m")))))
(DTypeSig false "paramNode" (TyFun (TyCon "Param") (TyCon "SExp")))
(DFunDef false "paramNode" ((PCon "PUnit")) (EApp (EVar "SAtom") (ELit (LString "unit"))))
(DFunDef false "paramNode" ((PCon "PPrefix" (PVar "s"))) (EApp (EApp (EVar "tagged") (ELit (LString "prefix"))) (EListLit (EApp (EVar "optNode") (EVar "s")))))
(DFunDef false "paramNode" ((PCon "PPath" (PVar "s"))) (EApp (EApp (EVar "tagged") (ELit (LString "path"))) (EListLit (EApp (EVar "optNode") (EVar "s")))))
(DFunDef false "paramNode" ((PCon "PSet" (PCon "None"))) (EApp (EApp (EVar "tagged") (ELit (LString "set"))) (EListLit (EApp (EVar "SAtom") (ELit (LString "none"))))))
(DFunDef false "paramNode" ((PCon "PSet" (PCon "Some" (PVar "members")))) (EApp (EApp (EVar "tagged") (ELit (LString "set"))) (EListLit (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (EVar "SAtom")) (EVar "members"))))))
(DFunDef false "paramNode" ((PCon "PProduct" (PVar "axes"))) (EApp (EApp (EVar "tagged") (ELit (LString "product"))) (EListLit (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (ELam ((PVar "axis")) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EApp (EVar "fst") (EVar "axis"))) (EApp (EVar "paramNode") (EApp (EVar "snd") (EVar "axis"))))))) (EVar "axes"))))))
(DTypeSig false "unzonked" (TyFun (TyCon "String") (TyVar "a")))
(DFunDef false "unzonked" ((PVar "what")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "interface_sexp: ")) (EApp (EMethodRef "display") (EVar "what"))) (ELit (LString " reached the printer unzonked")))))
(DTypeSig false "authNode" (TyFun (TyCon "Authority") (TyCon "SExp")))
(DFunDef false "authNode" ((PCon "AConst" (PVar "p"))) (EApp (EApp (EVar "tagged") (ELit (LString "const"))) (EListLit (EApp (EVar "paramNode") (EVar "p")))))
(DFunDef false "authNode" ((PCon "AVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" (PVar "id") (PVar "lvl") (PVar "top") (PVar "pat") (PVar "name")) () (EApp (EApp (EVar "tagged") (ELit (LString "av"))) (EListLit (EApp (EVar "intNode") (EVar "id")) (EApp (EVar "intNode") (EVar "lvl")) (EApp (EVar "paramNode") (EVar "top")) (EApp (EVar "boolNode") (EVar "pat")) (EApp (EVar "optNode") (EVar "name"))))) (arm (PCon "ALink" (PVar "id") PWild PWild) () (EApp (EVar "unzonked") (EBinOp "++" (EBinOp "++" (ELit (LString "the linked authority variable ")) (EApp (EMethodRef "display") (EVar "id"))) (ELit (LString "")))))))
(DFunDef false "authNode" ((PCon "AJoin" (PVar "members"))) (EApp (EApp (EVar "tagged") (ELit (LString "ajoin"))) (EListLit (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (EVar "authNode")) (EVar "members"))))))
(DFunDef false "authNode" ((PCon "AProduct" (PVar "axes"))) (EApp (EApp (EVar "tagged") (ELit (LString "aproduct"))) (EListLit (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (ELam ((PVar "axis")) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EApp (EVar "fst") (EVar "axis"))) (EApp (EVar "authNode") (EApp (EVar "snd") (EVar "axis"))))))) (EVar "axes"))))))
(DTypeSig false "labelNode" (TyFun (TyCon "EffLabel") (TyCon "SExp")))
(DFunDef false "labelNode" ((PCon "EffLabel" (PVar "name") (PVar "origin"))) (EApp (EApp (EVar "tagged") (ELit (LString "label"))) (EListLit (EApp (EVar "SAtom") (EVar "name")) (EApp (EVar "originNode") (EVar "origin")))))
(DTypeSig false "atomNode" (TyFun (TyCon "Atom") (TyCon "SExp")))
(DFunDef false "atomNode" ((PCon "Atom" (PVar "label") (PVar "auth"))) (EApp (EApp (EVar "tagged") (ELit (LString "atom"))) (EListLit (EApp (EVar "labelNode") (EVar "label")) (EApp (EVar "authNode") (EVar "auth")))))
(DTypeSig false "rowNode" (TyFun (TyCon "EffRow") (TyCon "SExp")))
(DFunDef false "rowNode" ((PCon "EffRow" (PVar "atoms") (PVar "tail"))) (EApp (EApp (EVar "tagged") (ELit (LString "row"))) (EListLit (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (EVar "atomNode")) (EVar "atoms"))) (EApp (EVar "tailNode") (EVar "tail")))))
(DTypeSig false "tailNode" (TyFun (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyCon "Effvar"))) (TyCon "SExp")))
(DFunDef false "tailNode" ((PCon "None")) (EApp (EVar "SAtom") (ELit (LString "closed"))))
(DFunDef false "tailNode" ((PCon "Some" (PVar "cell"))) (EApp (EVar "effvarNode") (EVar "cell")))
(DTypeSig false "effvarNode" (TyFun (TyApp (TyCon "Ref") (TyCon "Effvar")) (TyCon "SExp")))
(DFunDef false "effvarNode" ((PVar "cell")) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "EUnbound" (PVar "id") (PVar "lvl")) () (EApp (EApp (EVar "tagged") (ELit (LString "ev"))) (EListLit (EApp (EVar "intNode") (EVar "id")) (EApp (EVar "intNode") (EVar "lvl"))))) (arm (PCon "EJoin" (PVar "id") (PVar "lvl") (PVar "members")) () (EApp (EApp (EVar "tagged") (ELit (LString "ej"))) (EListLit (EApp (EVar "intNode") (EVar "id")) (EApp (EVar "intNode") (EVar "lvl")) (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (EVar "effvarNode")) (EVar "members")))))) (arm (PCon "ELink" (PVar "id") (PVar "row")) () (EApp (EApp (EVar "tagged") (ELit (LString "el"))) (EListLit (EApp (EVar "intNode") (EVar "id")) (EApp (EVar "rowNode") (EVar "row"))))) (arm (PCon "ESummary" (PVar "id") PWild PWild) () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "interface_sexp: effect summary ")) (EApp (EMethodRef "display") (EVar "id"))) (ELit (LString " is open; a frozen row holds none")))))))
(DTypeSig false "monoNode" (TyFun (TyCon "Mono") (TyCon "SExp")))
(DFunDef false "monoNode" ((PCon "TVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "Unbound" (PVar "id") (PVar "lvl")) () (EApp (EApp (EVar "tagged") (ELit (LString "tv"))) (EListLit (EApp (EVar "intNode") (EVar "id")) (EApp (EVar "intNode") (EVar "lvl"))))) (arm (PCon "Link" PWild) () (EApp (EVar "unzonked") (ELit (LString "a linked type variable"))))))
(DFunDef false "monoNode" ((PCon "TCon" (PVar "name") (PVar "origin"))) (EApp (EApp (EVar "tagged") (ELit (LString "con"))) (EListLit (EApp (EVar "SAtom") (EVar "name")) (EApp (EVar "originNode") (EVar "origin")))))
(DFunDef false "monoNode" ((PCon "TRigid" (PVar "name"))) (EApp (EApp (EVar "tagged") (ELit (LString "rigid"))) (EListLit (EApp (EVar "SAtom") (EVar "name")))))
(DFunDef false "monoNode" ((PCon "TApp" (PVar "f") (PVar "a"))) (EApp (EApp (EVar "tagged") (ELit (LString "app"))) (EListLit (EApp (EVar "monoNode") (EVar "f")) (EApp (EVar "monoNode") (EVar "a")))))
(DFunDef false "monoNode" ((PCon "TFun" (PVar "a") (PVar "row") (PVar "b"))) (EApp (EApp (EVar "tagged") (ELit (LString "fun"))) (EListLit (EApp (EVar "monoNode") (EVar "a")) (EApp (EVar "rowNode") (EVar "row")) (EApp (EVar "monoNode") (EVar "b")))))
(DFunDef false "monoNode" ((PCon "TEff" (PVar "row"))) (EApp (EApp (EVar "tagged") (ELit (LString "eff"))) (EListLit (EApp (EVar "rowNode") (EVar "row")))))
(DFunDef false "monoNode" ((PCon "TQual" (PVar "m") (PVar "auth"))) (EApp (EApp (EVar "tagged") (ELit (LString "qual"))) (EListLit (EApp (EVar "monoNode") (EVar "m")) (EApp (EVar "authNode") (EVar "auth")))))
(DFunDef false "monoNode" ((PCon "TAuth" (PVar "auth"))) (EApp (EApp (EVar "tagged") (ELit (LString "auth"))) (EListLit (EApp (EVar "authNode") (EVar "auth")))))
(DTypeSig false "residualNode" (TyFun (TyCon "AuthResidual") (TyCon "SExp")))
(DFunDef false "residualNode" ((PRec "AuthResidual" ((rf "arLower" (PVar "lo")) (rf "arUpper" (PVar "hi")) (rf "arExact" (PVar "exact"))) false)) (EApp (EApp (EVar "tagged") (ELit (LString "residual"))) (EListLit (EApp (EVar "authNode") (EVar "lo")) (EApp (EVar "authNode") (EVar "hi")) (EApp (EVar "boolNode") (EVar "exact")))))
(DTypeSig false "ifaceNode" (TyFun (TyCon "IfaceRef") (TyCon "SExp")))
(DFunDef false "ifaceNode" ((PVar "iface")) (EApp (EApp (EVar "tagged") (ELit (LString "iface"))) (EListLit (EApp (EVar "SAtom") (EFieldAccess (EVar "iface") "irName")) (EApp (EVar "originNode") (EFieldAccess (EVar "iface") "irOrigin")))))
(DTypeSig false "oblNode" (TyFun (TyCon "VecObl") (TyCon "SExp")))
(DFunDef false "oblNode" ((PRec "VecObl" ((rf "voIface" (PVar "iface")) (rf "voIds" (PVar "ids")) (rf "voArgs" (PVar "args"))) false)) (EApp (EApp (EVar "tagged") (ELit (LString "obl"))) (EListLit (EApp (EVar "ifaceNode") (EVar "iface")) (EApp (EVar "idsNode") (EVar "ids")) (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (EVar "monoNode")) (EVar "args"))))))
(DTypeSig false "schemeNode" (TyFun (TyCon "Scheme") (TyCon "SExp")))
(DFunDef false "schemeNode" ((PCon "Forall" (PVar "ids") (PVar "effIds") (PVar "authIds") (PVar "residuals") (PVar "row") (PVar "t"))) (EApp (EApp (EVar "tagged") (ELit (LString "forall"))) (EListLit (EApp (EVar "idsNode") (EVar "ids")) (EApp (EVar "idsNode") (EVar "effIds")) (EApp (EVar "idsNode") (EVar "authIds")) (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (EVar "residualNode")) (EVar "residuals"))) (EApp (EVar "rowNode") (EVar "row")) (EApp (EVar "monoNode") (EVar "t")))))
(DTypeSig false "pubNode" (TyFun (TyCon "PubScheme") (TyCon "SExp")))
(DFunDef false "pubNode" ((PVar "p")) (EApp (EApp (EVar "tagged") (ELit (LString "pub"))) (EListLit (EApp (EVar "schemeNode") (EFieldAccess (EVar "p") "psScheme")) (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (EVar "oblNode")) (EFieldAccess (EVar "p") "psContext"))))))
(DTypeSig true "monoSExp" (TyFun (TyCon "Mono") (TyCon "SExp")))
(DFunDef false "monoSExp" ((PVar "m")) (EApp (EVar "monoNode") (EApp (EVar "snd") (EApp (EApp (EVar "zonkMono") (EVar "emptyZonk")) (EVar "m")))))
(DTypeSig true "schemeSExp" (TyFun (TyCon "Scheme") (TyCon "SExp")))
(DFunDef false "schemeSExp" ((PVar "s")) (EApp (EVar "schemeNode") (EApp (EVar "snd") (EApp (EApp (EVar "zonkScheme") (EVar "emptyZonk")) (EVar "s")))))
(DTypeSig true "effRowSExp" (TyFun (TyCon "EffRow") (TyCon "SExp")))
(DFunDef false "effRowSExp" ((PVar "row")) (EApp (EVar "rowNode") (EApp (EVar "snd") (EApp (EApp (EVar "zonkRow") (EVar "emptyZonk")) (EVar "row")))))
(DTypeSig true "atomSExp" (TyFun (TyCon "Atom") (TyCon "SExp")))
(DFunDef false "atomSExp" ((PCon "Atom" (PVar "label") (PVar "auth"))) (EApp (EVar "atomNode") (EApp (EApp (EVar "Atom") (EVar "label")) (EApp (EVar "snd") (EApp (EApp (EVar "zonkAuthority") (EVar "emptyZonk")) (EVar "auth"))))))
(DTypeSig true "effLabelSExp" (TyFun (TyCon "EffLabel") (TyCon "SExp")))
(DFunDef false "effLabelSExp" () (EVar "labelNode"))
(DTypeSig true "authoritySExp" (TyFun (TyCon "Authority") (TyCon "SExp")))
(DFunDef false "authoritySExp" ((PVar "auth")) (EApp (EVar "authNode") (EApp (EVar "snd") (EApp (EApp (EVar "zonkAuthority") (EVar "emptyZonk")) (EVar "auth")))))
(DTypeSig true "paramSExp" (TyFun (TyCon "Param") (TyCon "SExp")))
(DFunDef false "paramSExp" () (EVar "paramNode"))
(DTypeSig true "authResidualSExp" (TyFun (TyCon "AuthResidual") (TyCon "SExp")))
(DFunDef false "authResidualSExp" ((PVar "r")) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "lo")) (EApp (EApp (EVar "zonkAuthority") (EVar "emptyZonk")) (EFieldAccess (EVar "r") "arLower"))) (DoLet false false (PTuple PWild (PVar "hi")) (EApp (EApp (EVar "zonkAuthority") (EVar "z1")) (EFieldAccess (EVar "r") "arUpper"))) (DoExpr (EApp (EVar "residualNode") (ERecordUpdate (EVar "r") ((fa "arLower" (EVar "lo")) (fa "arUpper" (EVar "hi"))))))))
(DTypeSig true "vecOblSExp" (TyFun (TyCon "VecObl") (TyCon "SExp")))
(DFunDef false "vecOblSExp" ((PVar "o")) (EApp (EVar "oblNode") (EApp (EVar "snd") (EApp (EApp (EVar "zonkVecObl") (EVar "emptyZonk")) (EVar "o")))))
(DTypeSig true "pubSchemeSExp" (TyFun (TyCon "PubScheme") (TyCon "SExp")))
(DFunDef false "pubSchemeSExp" ((PVar "p")) (EApp (EVar "pubNode") (EApp (EApp (EVar "freezePub") (EFieldAccess (EVar "p") "psScheme")) (EFieldAccess (EVar "p") "psContext"))))
(DTypeSig true "ifaceRefSExp" (TyFun (TyCon "IfaceRef") (TyCon "SExp")))
(DFunDef false "ifaceRefSExp" () (EVar "ifaceNode"))
(DTypeSig true "tyConOriginSExp" (TyFun (TyCon "TyConOrigin") (TyCon "SExp")))
(DFunDef false "tyConOriginSExp" () (EVar "originNode"))
(DTypeSig false "notFrozen" (TyFun (TyCon "LiveCell") (TyCon "Bool")))
(DFunDef false "notFrozen" ((PCon "LinkCell" PWild PWild PWild)) (EVar "True"))
(DFunDef false "notFrozen" ((PCon "OpenSummary" PWild PWild)) (EVar "True"))
(DFunDef false "notFrozen" (PWild) (EVar "False"))
(DTypeSig true "bindingSExp" (TyFun (TyCon "String") (TyFun (TyCon "PubScheme") (TyCon "SExp"))))
(DFunDef false "bindingSExp" ((PVar "name") (PVar "p")) (EMatch (EApp (EApp (EMethodRef "filter") (EVar "notFrozen")) (EApp (EApp (EVar "liveCells") (EVar "name")) (EVar "p"))) (arm (PList) () (EApp (EApp (EVar "tagged") (ELit (LString "binding"))) (EListLit (EApp (EVar "SAtom") (EVar "name")) (EApp (EVar "pubSchemeSExp") (EVar "p"))))) (arm (PVar "faults") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "interface row ")) (EApp (EMethodRef "display") (EVar "name"))) (ELit (LString " is not frozen: "))) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "faults")))) (ELit (LString "")))))))
(DTypeAlias false "Dec" ("a") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "ZState") (TyVar "a"))))
(DTypeSig false "headOf" (TyFun (TyCon "SExp") (TyCon "String")))
(DFunDef false "headOf" ((PCon "SAtom" (PVar "s"))) (EVar "s"))
(DFunDef false "headOf" ((PCon "SList" (PCons (PCon "SAtom" (PVar "h")) PWild))) (EVar "h"))
(DFunDef false "headOf" ((PCon "SList" PWild)) (ELit (LString "a list")))
(DTypeSig false "refuse" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a"))))))
(DFunDef false "refuse" ((PVar "path") (PVar "node") (PVar "what")) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (EVar "path")) (fa "seWhat" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "headOf") (EVar "node")))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EVar "what"))) (ELit (LString ""))))))))
(DTypeSig false "misfit" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))) (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a"))))))
(DFunDef false "misfit" ((PVar "path") (PVar "heads") (PVar "node")) (EMatch (EApp (EApp (EDictApp "find") (ELam ((PVar "h")) (EBinOp "==" (EApp (EVar "fst") (EVar "h")) (EApp (EVar "headOf") (EVar "node"))))) (EVar "heads")) (arm (PCon "Some" (PTuple PWild (PVar "n"))) () (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (EBinOp "++" (EBinOp "++" (ELit (LString "expected ")) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString " field(s)"))))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (EBinOp "++" (EBinOp "++" (ELit (LString "unknown head; expected one of ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "stringJoin") (ELit (LString ", "))) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "heads"))))) (ELit (LString "")))))))
(DTypeSig false "at" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyCon "String")))))
(DFunDef false "at" ((PVar "path") (PVar "head") (PVar "i")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EVar "head"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "i"))) (ELit (LString ""))))
(DTypeSig false "stateless" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))) (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyVar "a")))))))
(DFunDef false "stateless" ((PVar "f") (PVar "z") (PVar "path") (PVar "node")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "v")) (ETuple (EVar "z") (EVar "v")))) (EApp (EApp (EVar "f") (EVar "path")) (EVar "node"))))
(DTypeSig false "decEach" (TyFun (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyVar "a"))))) (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyApp (TyCon "List") (TyVar "a"))))))))
(DFunDef false "decEach" ((PVar "f") (PVar "z") (PVar "path") (PCon "SList" (PVar "items"))) (EApp (EApp (EApp (EApp (EApp (EVar "decItems") (EVar "f")) (EVar "z")) (EVar "path")) (ELit (LInt 0))) (EVar "items")))
(DFunDef false "decEach" (PWild PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "expected a list"))))
(DTypeSig false "decItems" (TyFun (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyVar "a"))))) (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "SExp")) (TyApp (TyCon "Dec") (TyApp (TyCon "List") (TyVar "a")))))))))
(DFunDef false "decItems" (PWild (PVar "z") PWild PWild (PList)) (EApp (EVar "Ok") (ETuple (EVar "z") (EListLit))))
(DFunDef false "decItems" ((PVar "f") (PVar "z") (PVar "path") (PVar "i") (PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "f") (EVar "z")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EVar "i"))) (ELit (LString "")))) (EVar "x"))) (ELam ((PTuple (PVar "z1") (PVar "y"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EApp (EVar "decItems") (EVar "f")) (EVar "z1")) (EVar "path")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "rest"))) (ELam ((PTuple (PVar "z2") (PVar "ys"))) (EApp (EVar "Ok") (ETuple (EVar "z2") (EBinOp "::" (EVar "y") (EVar "ys")))))))))
(DTypeSig false "decList" (TyFun (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))) (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyApp (TyCon "List") (TyVar "a")))))))
(DFunDef false "decList" ((PVar "f") (PVar "path") (PVar "node")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EApp (EApp (EApp (EVar "decEach") (EApp (EVar "stateless") (EVar "f"))) (EVar "emptyZonk")) (EVar "path")) (EVar "node"))))
(DTypeSig false "same" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyFun (TyCon "SExp") (TyFun (TyVar "a") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))))))
(DFunDef false "same" ((PVar "path") (PVar "node") (PVar "first") (PVar "v")) (EIf (EBinOp "==" (EVar "node") (EVar "first")) (EApp (EVar "Ok") (EVar "v")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "this id was written differently before")))))
(DTypeSig false "decOpt" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "decOpt" (PWild (PCon "SAtom" (PLit (LString "none")))) (EApp (EVar "Ok") (EVar "None")))
(DFunDef false "decOpt" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "some"))) (PVar "s")))) (EApp (EApp (EMethodRef "map") (EVar "Some")) (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "some"))) (ELit (LInt 1)))) (EVar "s"))))
(DFunDef false "decOpt" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "none")) (ELit (LInt 0))) (ETuple (ELit (LString "some")) (ELit (LInt 1))))) (EVar "node")))
(DTypeSig false "decOrigin" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "TyConOrigin")))))
(DFunDef false "decOrigin" (PWild (PCon "SAtom" (PLit (LString "unresolved")))) (EApp (EVar "Ok") (EVar "OriginUnresolved")))
(DFunDef false "decOrigin" (PWild (PCon "SAtom" (PLit (LString "builtin")))) (EApp (EVar "Ok") (EVar "OriginBuiltin")))
(DFunDef false "decOrigin" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "module"))) (PVar "m")))) (EApp (EApp (EMethodRef "map") (EVar "OriginModule")) (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "module"))) (ELit (LInt 1)))) (EVar "m"))))
(DFunDef false "decOrigin" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "unresolved")) (ELit (LInt 0))) (ETuple (ELit (LString "builtin")) (ELit (LInt 0))) (ETuple (ELit (LString "module")) (ELit (LInt 1))))) (EVar "node")))
(DTypeSig false "paramHeads" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "paramHeads" () (EListLit (ETuple (ELit (LString "unit")) (ELit (LInt 0))) (ETuple (ELit (LString "prefix")) (ELit (LInt 1))) (ETuple (ELit (LString "path")) (ELit (LInt 1))) (ETuple (ELit (LString "set")) (ELit (LInt 1))) (ETuple (ELit (LString "product")) (ELit (LInt 1)))))
(DTypeSig false "decParam" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Param")))))
(DFunDef false "decParam" (PWild (PCon "SAtom" (PLit (LString "unit")))) (EApp (EVar "Ok") (EVar "PUnit")))
(DFunDef false "decParam" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "prefix"))) (PVar "s")))) (EApp (EApp (EMethodRef "map") (EVar "PPrefix")) (EApp (EApp (EVar "decOpt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "prefix"))) (ELit (LInt 1)))) (EVar "s"))))
(DFunDef false "decParam" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "path"))) (PVar "s")))) (EApp (EApp (EMethodRef "map") (EVar "PPath")) (EApp (EApp (EVar "decOpt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "path"))) (ELit (LInt 1)))) (EVar "s"))))
(DFunDef false "decParam" (PWild (PCon "SList" (PList (PCon "SAtom" (PLit (LString "set"))) (PCon "SAtom" (PLit (LString "none")))))) (EApp (EVar "Ok") (EApp (EVar "PSet") (EVar "None"))))
(DFunDef false "decParam" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "set"))) (PVar "members")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "ms")) (EApp (EVar "PSet") (EApp (EVar "Some") (EVar "ms"))))) (EApp (EApp (EApp (EVar "decList") (EVar "expectAtom")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "set"))) (ELit (LInt 1)))) (EVar "members"))))
(DFunDef false "decParam" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "product"))) (PVar "axes")))) (EApp (EApp (EMethodRef "map") (EVar "PProduct")) (EApp (EApp (EApp (EVar "decList") (EVar "decParamAxis")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "product"))) (ELit (LInt 1)))) (EVar "axes"))))
(DFunDef false "decParam" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EVar "paramHeads")) (EVar "node")))
(DTypeSig false "decParamAxis" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "String") (TyCon "Param"))))))
(DFunDef false "decParamAxis" ((PVar "path") (PCon "SList" (PList (PVar "n") (PVar "p")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "/0")))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decParam") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "/1")))) (EVar "p"))) (ELam ((PVar "param")) (EApp (EVar "Ok") (ETuple (EVar "name") (EVar "param"))))))))
(DFunDef false "decParamAxis" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "expected an axis (NAME PARAM)"))))
(DTypeSig false "authHeads" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "authHeads" () (EListLit (ETuple (ELit (LString "const")) (ELit (LInt 1))) (ETuple (ELit (LString "av")) (ELit (LInt 5))) (ETuple (ELit (LString "ajoin")) (ELit (LInt 1))) (ETuple (ELit (LString "aproduct")) (ELit (LInt 1)))))
(DTypeSig false "decAuth" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "Authority"))))))
(DFunDef false "decAuth" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "const"))) (PVar "p")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "q")) (ETuple (EVar "z") (EApp (EVar "AConst") (EVar "q"))))) (EApp (EApp (EVar "decParam") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "const"))) (ELit (LInt 1)))) (EVar "p"))))
(DFunDef false "decAuth" ((PVar "z") (PVar "path") (PAs "node" (PCon "SList" (PList (PCon "SAtom" (PLit (LString "av"))) (PVar "i") (PVar "l") (PVar "top") (PVar "pat") (PVar "name"))))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "av"))) (ELit (LInt 1)))) (EVar "i"))) (ELam ((PVar "id")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "av"))) (ELit (LInt 2)))) (EVar "l"))) (ELam ((PVar "lvl")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decParam") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "av"))) (ELit (LInt 3)))) (EVar "top"))) (ELam ((PVar "domain")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "av"))) (ELit (LInt 4)))) (EVar "pat"))) (ELam ((PVar "patterned")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decOpt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "av"))) (ELit (LInt 5)))) (EVar "name"))) (ELam ((PVar "binder")) (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EVar "z") "zAuths")) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EVar "same") (EVar "path")) (EVar "node")) (EApp (EVar "authNode") (EApp (EVar "AVar") (EVar "c")))) (ETuple (EVar "z") (EApp (EVar "AVar") (EVar "c"))))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "c") (EApp (EVar "Ref") (EApp (EApp (EApp (EApp (EApp (EVar "AUnbound") (EVar "id")) (EVar "lvl")) (EVar "domain")) (EVar "patterned")) (EVar "binder")))) (DoExpr (EApp (EVar "Ok") (ETuple (ERecordUpdate (EVar "z") ((fa "zAuths" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "c")) (EFieldAccess (EVar "z") "zAuths"))))) (EApp (EVar "AVar") (EVar "c")))))))))))))))))))
(DFunDef false "decAuth" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "ajoin"))) (PVar "members")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "fst") (EVar "r")) (EApp (EVar "AJoin") (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decAuth")) (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ajoin"))) (ELit (LInt 1)))) (EVar "members"))))
(DFunDef false "decAuth" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "aproduct"))) (PVar "axes")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "fst") (EVar "r")) (EApp (EVar "AProduct") (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decAuthAxis")) (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "aproduct"))) (ELit (LInt 1)))) (EVar "axes"))))
(DFunDef false "decAuth" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EVar "authHeads")) (EVar "node")))
(DTypeSig false "decAuthAxis" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyTuple (TyCon "String") (TyCon "Authority")))))))
(DFunDef false "decAuthAxis" ((PVar "z") (PVar "path") (PCon "SList" (PList (PVar "n") (PVar "a")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "/0")))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decAuth") (EVar "z")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "/1")))) (EVar "a"))) (ELam ((PTuple (PVar "z1") (PVar "auth"))) (EApp (EVar "Ok") (ETuple (EVar "z1") (ETuple (EVar "name") (EVar "auth")))))))))
(DFunDef false "decAuthAxis" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "expected an axis (NAME AUTH)"))))
(DTypeSig false "decLabel" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "EffLabel")))))
(DFunDef false "decLabel" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "label"))) (PVar "n") (PVar "o")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "label"))) (ELit (LInt 1)))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "label"))) (ELit (LInt 2)))) (EVar "o"))) (ELam ((PVar "origin")) (EApp (EVar "Ok") (EApp (EApp (EVar "EffLabel") (EVar "name")) (EVar "origin"))))))))
(DFunDef false "decLabel" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "label")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "decAtom" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "Atom"))))))
(DFunDef false "decAtom" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "atom"))) (PVar "l") (PVar "a")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decLabel") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "atom"))) (ELit (LInt 1)))) (EVar "l"))) (ELam ((PVar "label")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decAuth") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "atom"))) (ELit (LInt 2)))) (EVar "a"))) (ELam ((PTuple (PVar "z1") (PVar "auth"))) (EApp (EVar "Ok") (ETuple (EVar "z1") (EApp (EApp (EVar "Atom") (EVar "label")) (EVar "auth")))))))))
(DFunDef false "decAtom" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "atom")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "decRow" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "EffRow"))))))
(DFunDef false "decRow" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "row"))) (PVar "atoms") (PVar "tail")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decAtom")) (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "row"))) (ELit (LInt 1)))) (EVar "atoms"))) (ELam ((PTuple (PVar "z1") (PVar "atoms1"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decTail") (EVar "z1")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "row"))) (ELit (LInt 2)))) (EVar "tail"))) (ELam ((PTuple (PVar "z2") (PVar "tail1"))) (EApp (EVar "Ok") (ETuple (EVar "z2") (EApp (EApp (EVar "EffRow") (EVar "atoms1")) (EVar "tail1")))))))))
(DFunDef false "decRow" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "row")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "decTail" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyApp (TyCon "Option") (TyApp (TyCon "Ref") (TyCon "Effvar"))))))))
(DFunDef false "decTail" ((PVar "z") PWild (PCon "SAtom" (PLit (LString "closed")))) (EApp (EVar "Ok") (ETuple (EVar "z") (EVar "None"))))
(DFunDef false "decTail" ((PVar "z") (PVar "path") (PVar "node")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "fst") (EVar "r")) (EApp (EVar "Some") (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EApp (EApp (EVar "decEffvar") (EVar "False")) (EVar "z")) (EVar "path")) (EVar "node"))))
(DTypeSig false "memoEff" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyFun (TyCon "Int") (TyFun (TyFun (TyCon "ZState") (TyApp (TyCon "Dec") (TyCon "Effvar"))) (TyApp (TyCon "Dec") (TyApp (TyCon "Ref") (TyCon "Effvar")))))))))
(DFunDef false "memoEff" ((PVar "z") (PVar "path") (PVar "node") (PVar "id") (PVar "build")) (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EVar "z") "zEffs")) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EVar "same") (EVar "path")) (EVar "node")) (EApp (EVar "effvarNode") (EVar "c"))) (ETuple (EVar "z") (EVar "c")))) (arm (PCon "None") () (EApp (EApp (EMethodRef "andThen") (EApp (EVar "build") (EVar "z"))) (ELam ((PTuple (PVar "z1") (PVar "v"))) (ELet false (PVar "c") (EApp (EVar "Ref") (EVar "v")) (EApp (EVar "Ok") (ETuple (ERecordUpdate (EVar "z1") ((fa "zEffs" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "c")) (EFieldAccess (EVar "z1") "zEffs"))))) (EVar "c")))))))))
(DTypeSig false "effvarHeads" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "effvarHeads" () (EListLit (ETuple (ELit (LString "closed")) (ELit (LInt 0))) (ETuple (ELit (LString "ev")) (ELit (LInt 2))) (ETuple (ELit (LString "ej")) (ELit (LInt 3))) (ETuple (ELit (LString "el")) (ELit (LInt 2)))))
(DTypeSig false "decEffvar" (TyFun (TyCon "Bool") (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyApp (TyCon "Ref") (TyCon "Effvar"))))))))
(DFunDef false "decEffvar" (PWild (PVar "z") (PVar "path") (PAs "node" (PCon "SList" (PList (PCon "SAtom" (PLit (LString "ev"))) (PVar "i") (PVar "l"))))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ev"))) (ELit (LInt 1)))) (EVar "i"))) (ELam ((PVar "id")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ev"))) (ELit (LInt 2)))) (EVar "l"))) (ELam ((PVar "lvl")) (EApp (EApp (EApp (EApp (EApp (EVar "memoEff") (EVar "z")) (EVar "path")) (EVar "node")) (EVar "id")) (ELam ((PVar "z0")) (EApp (EVar "Ok") (ETuple (EVar "z0") (EApp (EApp (EVar "EUnbound") (EVar "id")) (EVar "lvl")))))))))))
(DFunDef false "decEffvar" (PWild (PVar "z") (PVar "path") (PAs "node" (PCon "SList" (PList (PCon "SAtom" (PLit (LString "ej"))) (PVar "i") (PVar "l") (PVar "members"))))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ej"))) (ELit (LInt 1)))) (EVar "i"))) (ELam ((PVar "id")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ej"))) (ELit (LInt 2)))) (EVar "l"))) (ELam ((PVar "lvl")) (EApp (EApp (EApp (EApp (EApp (EVar "memoEff") (EVar "z")) (EVar "path")) (EVar "node")) (EVar "id")) (ELam ((PVar "z0")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "fst") (EVar "r")) (EApp (EApp (EApp (EVar "EJoin") (EVar "id")) (EVar "lvl")) (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EApp (EApp (EVar "decEach") (EApp (EVar "decEffvar") (EVar "True"))) (EVar "z0")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ej"))) (ELit (LInt 3)))) (EVar "members"))))))))))
(DFunDef false "decEffvar" ((PCon "True") (PVar "z") (PVar "path") (PAs "node" (PCon "SList" (PList (PCon "SAtom" (PLit (LString "el"))) (PVar "i") (PVar "row"))))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "el"))) (ELit (LInt 1)))) (EVar "i"))) (ELam ((PVar "id")) (EApp (EApp (EApp (EApp (EApp (EVar "memoEff") (EVar "z")) (EVar "path")) (EVar "node")) (EVar "id")) (ELam ((PVar "z0")) (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "fst") (EVar "r")) (EApp (EApp (EVar "ELink") (EVar "id")) (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EApp (EVar "decRow") (EVar "z0")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "el"))) (ELit (LInt 2)))) (EVar "row"))))))))
(DFunDef false "decEffvar" ((PCon "False") PWild (PVar "path") (PAs "node" (PCon "SList" (PList (PCon "SAtom" (PLit (LString "el"))) PWild PWild)))) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "a row tail is never a link"))))
(DFunDef false "decEffvar" (PWild PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EVar "effvarHeads")) (EVar "node")))
(DTypeSig false "monoHeads" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "monoHeads" () (EListLit (ETuple (ELit (LString "tv")) (ELit (LInt 2))) (ETuple (ELit (LString "con")) (ELit (LInt 2))) (ETuple (ELit (LString "rigid")) (ELit (LInt 1))) (ETuple (ELit (LString "app")) (ELit (LInt 2))) (ETuple (ELit (LString "fun")) (ELit (LInt 3))) (ETuple (ELit (LString "eff")) (ELit (LInt 1))) (ETuple (ELit (LString "qual")) (ELit (LInt 2))) (ETuple (ELit (LString "auth")) (ELit (LInt 1)))))
(DTypeSig false "decMono" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "Mono"))))))
(DFunDef false "decMono" ((PVar "z") (PVar "path") (PAs "node" (PCon "SList" (PList (PCon "SAtom" (PLit (LString "tv"))) (PVar "i") (PVar "l"))))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tv"))) (ELit (LInt 1)))) (EVar "i"))) (ELam ((PVar "id")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tv"))) (ELit (LInt 2)))) (EVar "l"))) (ELam ((PVar "lvl")) (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EVar "z") "zTys")) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EVar "same") (EVar "path")) (EVar "node")) (EApp (EVar "monoNode") (EApp (EVar "TVar") (EVar "c")))) (ETuple (EVar "z") (EApp (EVar "TVar") (EVar "c"))))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "c") (EApp (EVar "Ref") (EApp (EApp (EVar "Unbound") (EVar "id")) (EVar "lvl")))) (DoExpr (EApp (EVar "Ok") (ETuple (ERecordUpdate (EVar "z") ((fa "zTys" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "c")) (EFieldAccess (EVar "z") "zTys"))))) (EApp (EVar "TVar") (EVar "c")))))))))))))
(DFunDef false "decMono" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "con"))) (PVar "n") (PVar "o")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "con"))) (ELit (LInt 1)))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "con"))) (ELit (LInt 2)))) (EVar "o"))) (ELam ((PVar "origin")) (EApp (EVar "Ok") (ETuple (EVar "z") (EApp (EApp (EVar "TCon") (EVar "name")) (EVar "origin")))))))))
(DFunDef false "decMono" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "rigid"))) (PVar "n")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "name")) (ETuple (EVar "z") (EApp (EVar "TRigid") (EVar "name"))))) (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "rigid"))) (ELit (LInt 1)))) (EVar "n"))))
(DFunDef false "decMono" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "app"))) (PVar "f") (PVar "a")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decMono") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "app"))) (ELit (LInt 1)))) (EVar "f"))) (ELam ((PTuple (PVar "z1") (PVar "f1"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decMono") (EVar "z1")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "app"))) (ELit (LInt 2)))) (EVar "a"))) (ELam ((PTuple (PVar "z2") (PVar "a1"))) (EApp (EVar "Ok") (ETuple (EVar "z2") (EApp (EApp (EVar "TApp") (EVar "f1")) (EVar "a1")))))))))
(DFunDef false "decMono" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "fun"))) (PVar "a") (PVar "row") (PVar "b")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decMono") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "fun"))) (ELit (LInt 1)))) (EVar "a"))) (ELam ((PTuple (PVar "z1") (PVar "a1"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decRow") (EVar "z1")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "fun"))) (ELit (LInt 2)))) (EVar "row"))) (ELam ((PTuple (PVar "z2") (PVar "row1"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decMono") (EVar "z2")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "fun"))) (ELit (LInt 3)))) (EVar "b"))) (ELam ((PTuple (PVar "z3") (PVar "b1"))) (EApp (EVar "Ok") (ETuple (EVar "z3") (EApp (EApp (EApp (EVar "TFun") (EVar "a1")) (EVar "row1")) (EVar "b1")))))))))))
(DFunDef false "decMono" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "eff"))) (PVar "row")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "fst") (EVar "r")) (EApp (EVar "TEff") (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EApp (EVar "decRow") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "eff"))) (ELit (LInt 1)))) (EVar "row"))))
(DFunDef false "decMono" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "qual"))) (PVar "m") (PVar "a")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decMono") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "qual"))) (ELit (LInt 1)))) (EVar "m"))) (ELam ((PTuple (PVar "z1") (PVar "m1"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decAuth") (EVar "z1")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "qual"))) (ELit (LInt 2)))) (EVar "a"))) (ELam ((PTuple (PVar "z2") (PVar "a1"))) (EApp (EVar "Ok") (ETuple (EVar "z2") (EApp (EApp (EVar "TQual") (EVar "m1")) (EVar "a1")))))))))
(DFunDef false "decMono" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "auth"))) (PVar "a")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "fst") (EVar "r")) (EApp (EVar "TAuth") (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EApp (EVar "decAuth") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "auth"))) (ELit (LInt 1)))) (EVar "a"))))
(DFunDef false "decMono" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EVar "monoHeads")) (EVar "node")))
(DTypeSig false "decResidual" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "AuthResidual"))))))
(DFunDef false "decResidual" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "residual"))) (PVar "lo") (PVar "hi") (PVar "ex")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decAuth") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "residual"))) (ELit (LInt 1)))) (EVar "lo"))) (ELam ((PTuple (PVar "z1") (PVar "lower"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decAuth") (EVar "z1")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "residual"))) (ELit (LInt 2)))) (EVar "hi"))) (ELam ((PTuple (PVar "z2") (PVar "upper"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "residual"))) (ELit (LInt 3)))) (EVar "ex"))) (ELam ((PVar "exact")) (EApp (EVar "Ok") (ETuple (EVar "z2") (ERecordCreate "AuthResidual" ((fa "arLower" (EVar "lower")) (fa "arUpper" (EVar "upper")) (fa "arExact" (EVar "exact")))))))))))))
(DFunDef false "decResidual" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "residual")) (ELit (LInt 3))))) (EVar "node")))
(DTypeSig false "decIface" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "IfaceRef")))))
(DFunDef false "decIface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "iface"))) (PVar "n") (PVar "o")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "iface"))) (ELit (LInt 1)))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "iface"))) (ELit (LInt 2)))) (EVar "o"))) (ELam ((PVar "origin")) (EApp (EVar "Ok") (ERecordCreate "IfaceRef" ((fa "irName" (EVar "name")) (fa "irOrigin" (EVar "origin"))))))))))
(DFunDef false "decIface" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "iface")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "decObl" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "VecObl"))))))
(DFunDef false "decObl" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "obl"))) (PVar "i") (PVar "ids") (PVar "args")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decIface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "obl"))) (ELit (LInt 1)))) (EVar "i"))) (ELam ((PVar "iface")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "atomInt")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "obl"))) (ELit (LInt 2)))) (EVar "ids"))) (ELam ((PVar "ids1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decMono")) (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "obl"))) (ELit (LInt 3)))) (EVar "args"))) (ELam ((PTuple (PVar "z1") (PVar "args1"))) (EApp (EVar "Ok") (ETuple (EVar "z1") (ERecordCreate "VecObl" ((fa "voIface" (EVar "iface")) (fa "voIds" (EVar "ids1")) (fa "voArgs" (EVar "args1")))))))))))))
(DFunDef false "decObl" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "obl")) (ELit (LInt 3))))) (EVar "node")))
(DTypeSig false "decScheme" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "Scheme"))))))
(DFunDef false "decScheme" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "forall"))) (PVar "ids") (PVar "effIds") (PVar "authIds") (PVar "rs") (PVar "row") (PVar "t")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "atomInt")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "forall"))) (ELit (LInt 1)))) (EVar "ids"))) (ELam ((PVar "ids1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "atomInt")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "forall"))) (ELit (LInt 2)))) (EVar "effIds"))) (ELam ((PVar "effIds1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "atomInt")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "forall"))) (ELit (LInt 3)))) (EVar "authIds"))) (ELam ((PVar "authIds1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decResidual")) (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "forall"))) (ELit (LInt 4)))) (EVar "rs"))) (ELam ((PTuple (PVar "z1") (PVar "rs1"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decRow") (EVar "z1")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "forall"))) (ELit (LInt 5)))) (EVar "row"))) (ELam ((PTuple (PVar "z2") (PVar "row1"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decMono") (EVar "z2")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "forall"))) (ELit (LInt 6)))) (EVar "t"))) (ELam ((PTuple (PVar "z3") (PVar "t1"))) (EApp (EVar "Ok") (ETuple (EVar "z3") (EApp (EApp (EApp (EApp (EApp (EApp (EVar "Forall") (EVar "ids1")) (EVar "effIds1")) (EVar "authIds1")) (EVar "rs1")) (EVar "row1")) (EVar "t1")))))))))))))))))
(DFunDef false "decScheme" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "forall")) (ELit (LInt 6))))) (EVar "node")))
(DTypeSig false "decPub" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "PubScheme"))))))
(DFunDef false "decPub" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "pub"))) (PVar "s") (PVar "ctx")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decScheme") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "pub"))) (ELit (LInt 1)))) (EVar "s"))) (ELam ((PTuple (PVar "z1") (PVar "scheme"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decObl")) (EVar "z1")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "pub"))) (ELit (LInt 2)))) (EVar "ctx"))) (ELam ((PTuple (PVar "z2") (PVar "obls"))) (EApp (EVar "Ok") (ETuple (EVar "z2") (ERecordCreate "PubScheme" ((fa "psScheme" (EVar "scheme")) (fa "psContext" (EVar "obls")))))))))))
(DFunDef false "decPub" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "pub")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "rooted" (TyFun (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyVar "a"))))) (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a"))))))
(DFunDef false "rooted" ((PVar "dec") (PVar "root") (PVar "node")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EApp (EApp (EVar "dec") (EVar "emptyZonk")) (EVar "root")) (EVar "node"))))
(DTypeSig true "monoOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Mono"))))
(DFunDef false "monoOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decMono")) (ELit (LString "mono"))))
(DTypeSig true "schemeOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Scheme"))))
(DFunDef false "schemeOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decScheme")) (ELit (LString "scheme"))))
(DTypeSig true "effRowOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "EffRow"))))
(DFunDef false "effRowOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decRow")) (ELit (LString "row"))))
(DTypeSig true "atomOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Atom"))))
(DFunDef false "atomOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decAtom")) (ELit (LString "atom"))))
(DTypeSig true "effLabelOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "EffLabel"))))
(DFunDef false "effLabelOfSExp" () (EApp (EVar "decLabel") (ELit (LString "label"))))
(DTypeSig true "authorityOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Authority"))))
(DFunDef false "authorityOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decAuth")) (ELit (LString "authority"))))
(DTypeSig true "paramOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Param"))))
(DFunDef false "paramOfSExp" () (EApp (EVar "decParam") (ELit (LString "param"))))
(DTypeSig true "authResidualOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "AuthResidual"))))
(DFunDef false "authResidualOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decResidual")) (ELit (LString "residual"))))
(DTypeSig true "vecOblOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "VecObl"))))
(DFunDef false "vecOblOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decObl")) (ELit (LString "obl"))))
(DTypeSig true "pubSchemeOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "PubScheme"))))
(DFunDef false "pubSchemeOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decPub")) (ELit (LString "pub"))))
(DTypeSig true "ifaceRefOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "IfaceRef"))))
(DFunDef false "ifaceRefOfSExp" () (EApp (EVar "decIface") (ELit (LString "iface"))))
(DTypeSig true "tyConOriginOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "TyConOrigin"))))
(DFunDef false "tyConOriginOfSExp" () (EApp (EVar "decOrigin") (ELit (LString "origin"))))
(DTypeSig true "bindingOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "String") (TyCon "PubScheme")))))
(DFunDef false "bindingOfSExp" ((PCon "SList" (PList (PCon "SAtom" (PLit (LString "binding"))) (PVar "n") (PVar "p")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (ELit (LString "binding"))) (ELit (LString "binding"))) (ELit (LInt 1)))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decPub") (EVar "emptyZonk")) (EApp (EApp (EApp (EVar "at") (ELit (LString "binding"))) (ELit (LString "binding"))) (ELit (LInt 2)))) (EVar "p"))) (ELam ((PTuple PWild (PVar "pub"))) (EApp (EVar "Ok") (ETuple (EVar "name") (EVar "pub"))))))))
(DFunDef false "bindingOfSExp" ((PVar "node")) (EApp (EApp (EApp (EVar "misfit") (ELit (LString "binding"))) (EListLit (ETuple (ELit (LString "binding")) (ELit (LInt 2))))) (EVar "node")))
