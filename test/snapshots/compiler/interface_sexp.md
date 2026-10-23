# META
source_lines=1623
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
--
-- The prelude interface's other components.  A container decoder takes its
-- element decoders and the path it reads at, as `atomInt` does; `nested` lets
-- a component's own decoder stand as an element.  A map is written as its
-- pairs in key order, and a decoded map whose keys do not ascend strictly is
-- refused.  A surface type is written without its locations, which decode as
-- `None`, so two types that differ only in a location encode alike.  A
-- record, a slot and a method slot are one value each for the cell rule above,
-- as their freeze zonks each from an empty state; a population's payloads are
-- one value each.
--   (<x> ...) | (<a> <b>) | (<a> <b> <c>)    list, pair, triple
--   none | (some <x>)                         `Option`
--   ()                                        `Unit`
--   ((<key> <v>) ...)                         `OrdMap`, `Map Int`, key order
--   (scon <name> <origin>) | (svar <name>)    surface type heads
--   (sapp <ty> <ty>) | (sfun <ty> <ty>) | (stuple (<ty> ...))
--   (seffect (<seat> ...) (<name> ...) <ty>)  effect atoms, tails, the type
--   (sconstrained (<constraint> ...) <ty>)
--   (snamed <name> <ty> <seat-opt>)           a binder and its domain
--   (squal <ty> (<sparam> ...)) | (sauth (<sparam> ...))
--   (srow (<seat> ...) (<name> ...))          a bare row
--   (seat <name> <origin> <sparam> <bool>)    label, origin, parameter, pattern
--   stop | (slit <str>) | (sname <name>)      `EffParamTy`
--   (sset (<str> ...)) | (sproduct ((<name> <sparam>) ...))
--   (constraint <name> (<ty> ...) <origin>)   a surface predicate
--   (variant <name> <payload>)                `Variant`
--   (pos (<ty> ...)) | (named ((field <name> <ty>) ...) <bool>)
--   (ident <ns> <origin> <name>)              never `unresolved`
--   type | iface | method | ctor | field | value     `Ns`
--   (tkident <ident>) | (tkbare <ns> <name>)  `TabKey`
--   private | abstract | public               `DataVis`
--   (record (<id> ...) (<id> ...) <mono> ((<name> <mono>) ...) <map>)
--   (slot <iface> <args> (<id> ...))          `PredicateSlot`
--   psunknown | (psknown (<mono> ...))        its arguments
--   (mslot <slot> (<int> ...))                `MethodPredicateSlot`
--   cdpunknown | (cdplen <int>)               `CDeclaredPrefix`
--   (classes <origin> x4 <bool> x5)           `BuiltinClasses`, field order
--   (pop <map> <map> (<name> ...))            rows, floor, collided spellings
--   (sprow <ident> <name> <payload>)          one row: identity, owner
--
-- The whole file: the header on its own first line, then one line per section.
--   (medaka-interface <version> (sources ((<path> <hash>) ...)) (compiler <id>)
--     (sections <n>) (digest <hex>))
--   (section (joins (<join> ...)) <interface>)   a join is a list of `atom` nodes
--   (interface <field> x19)                   `PreludeInterface`, field order
-- `digest` is the SHA-256, in lower-case hex, of the file's bytes after the
-- header line, the newline that ends it excluded: every section line with its
-- own newline.  The reader hashes those bytes as they are, so no section is
-- decoded and rendered again to be checked; the header key hashes source files,
-- so only the digest sees a byte changed inside a section.
-- A section's joins are written in the order of their rendered text.  A header
-- whose version is not `formatVersion` (read before the header's shape), a
-- digest that differs from the nodes present, a missing, truncated or extra
-- node, a section count that differs from the nodes present, or any component
-- refusal is an `Err`, never a partial record.
import list.{mapAccumL, sortOn}
import crypto.sha256.{sha256}
import hex as Hex
import bytes.{encodeUtf8}
import string as S
import map as IdMap
import map.{Map}
import support.ordmap.{OrdMap, omEmpty, omInsert, omLookup, omKeys}
import support.util.{dedupBy}
import support.sexp_value.{
  SExp(..), SexpError(..), renderSExp, parseSExp, expectAtom, atomInt, atomBool
}
import types.prelude_interface.{PreludeInterface(..), InterfaceKey(..)}
import types.publish.{
  PubScheme(..), ZState(..), LiveCell(..), emptyZonk, zonkMono, zonkRow,
  zonkAuthority, zonkVecObl, zonkScheme, freezePub, liveCells
}
import types.registry.{
  SpellingPop, spRows, spFloor, spCollided, spFromProjections
}
import types.repr.{
  Mono(..), Tyvar(..), Scheme(..), AuthResidual(..), VecObl(..), IfaceRef(..)
}
import types.tc_types.{
  RecordInfo(..), PredicateSlot(..), PredicateSlotArgs(..),
  MethodPredicateSlot(..), CDeclaredPrefix(..), BuiltinClasses(..)
}
import types.effect_rows.{EffRow(..), Effvar(..), Atom(..), EffLabel(..)}
import types.effect_authority.{Authority(..), Authvar(..)}
import types.effect_domain.{Param(..)}
import frontend.ast.{
  TyConOrigin(..), Ty(..), EffAtomTy(..), EffParamTy(..), Constraint(..),
  Variant(..), ConPayload(..), Field(..), Ident(..), Ns(..), TabKey(..),
  DataVis(..), identOriginFold, mkIdent
}

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
optNode o = optionSExp SAtom o

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
paramNode (PProduct axes) =
  tagged "product" [listSExp (pairSExp SAtom paramNode) axes]

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
authNode (AProduct axes) =
  tagged "aproduct" [listSExp (pairSExp SAtom authNode) axes]

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

-- ── writing the other components ────────────────────────────────────────────

export
listSExp : (a -> SExp) -> List a -> SExp
listSExp f xs = SList (map f xs)

export
pairSExp : (a -> SExp) -> (b -> SExp) -> (a, b) -> SExp
pairSExp f g (a, b) = SList [f a, g b]

export
tripleSExp : (a -> SExp) -> (b -> SExp) -> (c -> SExp) -> (a, b, c) -> SExp
tripleSExp f g h (a, b, c) = SList [f a, g b, h c]

export
optionSExp : (a -> SExp) -> Option a -> SExp
optionSExp _ None = SAtom "none"
optionSExp f (Some x) = tagged "some" [f x]

export
unitSExp : Unit -> SExp
unitSExp _ = SList []

mapNode : (k -> SExp) -> (v -> SExp) -> Map k v -> SExp
mapNode key value m = listSExp (pairSExp key value) (IdMap.entries m)

export
ordMapSExp : (a -> SExp) -> OrdMap a -> SExp
ordMapSExp value m = mapNode SAtom value m

export
intMapSExp : (a -> SExp) -> Map Int a -> SExp
intMapSExp value m = mapNode intNode value m

surfaceNode : Ty -> SExp
surfaceNode (TyCon { tyConName = name, tyConOrigin = origin }) =
  tagged "scon" [SAtom name, originNode origin]
surfaceNode (TyVar name) = tagged "svar" [SAtom name]
surfaceNode (TyApp f a) = tagged "sapp" [surfaceNode f, surfaceNode a]
surfaceNode (TyFun a b) = tagged "sfun" [surfaceNode a, surfaceNode b]
surfaceNode (TyTuple tys) = tagged "stuple" [listSExp surfaceNode tys]
surfaceNode (TyEffect atoms tails t) = tagged "seffect" [
  listSExp effAtomNode atoms,
  listSExp SAtom tails,
  surfaceNode t,
]
surfaceNode (TyConstrained cs t) =
  tagged "sconstrained" [listSExp constraintNode cs, surfaceNode t]
surfaceNode (TyNamed name t domain) = tagged "snamed" [
  SAtom name,
  surfaceNode t,
  optionSExp effAtomNode domain,
]
surfaceNode (TyQual t params _) =
  tagged "squal" [surfaceNode t, listSExp effParamNode params]
surfaceNode (TyRow atoms tails _) =
  tagged "srow" [listSExp effAtomNode atoms, listSExp SAtom tails]
surfaceNode (TyAuth params _) = tagged "sauth" [listSExp effParamNode params]

effAtomNode : EffAtomTy -> SExp
effAtomNode a = tagged "seat" [
  SAtom a.eatLabel,
  originNode a.eatOrigin,
  effParamNode a.eatParam,
  boolNode a.eatPattern,
]

effParamNode : EffParamTy -> SExp
effParamNode EPTop = SAtom "stop"
effParamNode (EPLit s) = tagged "slit" [SAtom s]
effParamNode (EPName s) = tagged "sname" [SAtom s]
effParamNode (EPSet members) = tagged "sset" [listSExp SAtom members]
effParamNode (EPProduct axes) =
  tagged "sproduct" [listSExp (pairSExp SAtom effParamNode) axes]

constraintNode : Constraint -> SExp
constraintNode c = tagged "constraint" [
  SAtom c.constraintHead,
  listSExp surfaceNode c.constraintArgs,
  originNode c.constraintOrigin,
]

variantNode : Variant -> SExp
variantNode (Variant name payload) =
  tagged "variant" [SAtom name, payloadNode payload]

payloadNode : ConPayload -> SExp
payloadNode (ConPos tys) = tagged "pos" [listSExp surfaceNode tys]
payloadNode (ConNamed fields nameOmitted) =
  tagged "named" [listSExp fieldNode fields, boolNode nameOmitted]

fieldNode : Field -> SExp
fieldNode (Field name t) = tagged "field" [SAtom name, surfaceNode t]

nsNode : Ns -> SExp
nsNode NsType = SAtom "type"
nsNode NsIface = SAtom "iface"
nsNode NsMethod = SAtom "method"
nsNode NsCtor = SAtom "ctor"
nsNode NsField = SAtom "field"
nsNode NsValue = SAtom "value"

identNode : Ident -> SExp
identNode (Ident ns origin name) = tagged "ident" [
  nsNode ns,
  originNode (identOriginFold OriginBuiltin OriginModule origin),
  SAtom name,
]

tabKeyNode : TabKey -> SExp
tabKeyNode (TkIdent ident) = tagged "tkident" [identNode ident]
tabKeyNode (TkBare ns name) = tagged "tkbare" [nsNode ns, SAtom name]

dataVisNode : DataVis -> SExp
dataVisNode VisPrivate = SAtom "private"
dataVisNode VisAbstract = SAtom "abstract"
dataVisNode VisPublic = SAtom "public"

recordNode : RecordInfo -> SExp
recordNode (RecordInfo ids authIds result fields index) = tagged "record" [
  idsNode ids,
  idsNode authIds,
  monoNode result,
  listSExp (pairSExp SAtom monoNode) fields,
  ordMapSExp monoNode index,
]

slotNode : PredicateSlot -> SExp
slotNode s = tagged "slot" [
  ifaceNode s.psIface,
  slotArgsNode s.psArgs,
  idsNode s.psBoundIds,
]

slotArgsNode : PredicateSlotArgs -> SExp
slotArgsNode PSArgsUnknown = SAtom "psunknown"
slotArgsNode (PSArgsKnown args) = tagged "psknown" [listSExp monoNode args]

methodSlotNode : MethodPredicateSlot -> SExp
methodSlotNode m =
  tagged "mslot" [slotNode m.mpsPredicate, idsNode m.mpsPositions]

prefixNode : CDeclaredPrefix -> SExp
prefixNode CDPUnknown = SAtom "cdpunknown"
prefixNode (CDPLen n) = tagged "cdplen" [intNode n]

classesNode : BuiltinClasses -> SExp
classesNode b = tagged "classes" [
  originNode b.bcNum,
  originNode b.bcEq,
  originNode b.bcOrd,
  originNode b.bcSemigroup,
  boolNode b.bcNumPresent,
  boolNode b.bcEqPresent,
  boolNode b.bcOrdPresent,
  boolNode b.bcSemigroupPresent,
  boolNode b.bcPreludeSeeded,
]

popRowNode : (a -> SExp) -> (Ident, String, a) -> SExp
popRowNode payload (ident, owner, p) =
  tagged "sprow" [identNode ident, SAtom owner, payload p]

zonkNamed : ZState -> (String, Mono) -> (ZState, (String, Mono))
zonkNamed z (name, m) =
  let (z1, m1) = zonkMono z m
  (z1, (name, m1))

zonkSlotArgs : PredicateSlot -> PredicateSlot
zonkSlotArgs s = match s.psArgs
  PSArgsUnknown => s
  PSArgsKnown args =>
    { s | psArgs = PSArgsKnown (snd (mapAccumL zonkMono emptyZonk args)) }

export
surfaceTySExp : Ty -> SExp
surfaceTySExp = surfaceNode

export
variantSExp : Variant -> SExp
variantSExp = variantNode

export
tabKeySExp : TabKey -> SExp
tabKeySExp = tabKeyNode

export
dataVisSExp : DataVis -> SExp
dataVisSExp = dataVisNode

-- The result, the fields and the index zonked from one state, as the freeze
-- zonks a record, so the fields and the index keep sharing their variables.
export
recordInfoSExp : RecordInfo -> SExp
recordInfoSExp (RecordInfo ids authIds result fields index) =
  let (z1, result1) = zonkMono emptyZonk result
  let (z2, fields1) = mapAccumL zonkNamed z1 fields
  let (_, index1) = mapAccumL zonkNamed z2 (IdMap.entries index)
  recordNode (RecordInfo ids authIds result1 fields1 (IdMap.fromList index1))

export
predicateSlotSExp : PredicateSlot -> SExp
predicateSlotSExp s = slotNode (zonkSlotArgs s)

export
methodPredicateSlotSExp : MethodPredicateSlot -> SExp
methodPredicateSlotSExp m =
  methodSlotNode { m | mpsPredicate = zonkSlotArgs m.mpsPredicate }

export
cDeclaredPrefixSExp : CDeclaredPrefix -> SExp
cDeclaredPrefixSExp = prefixNode

export
builtinClassesSExp : BuiltinClasses -> SExp
builtinClassesSExp = classesNode

export
spellingPopSExp : (a -> SExp) -> SpellingPop a -> SExp
spellingPopSExp payload pop = tagged "pop" [
  ordMapSExp (listSExp (popRowNode payload)) (spRows pop),
  ordMapSExp payload (spFloor pop),
  listSExp SAtom (spCollided pop),
]

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

-- A two-element list holding a name and a value; [what] is the refusal's text
-- for any other shape.
decNamed : String ->
  (ZState -> String -> SExp -> Dec a) ->
  ZState ->
  String ->
  SExp ->
  Dec (String, a)
decNamed _ f z path (SList [n, x]) = do
  name <- expectAtom "\{path}/0" n
  (z1, v) <- f z "\{path}/1" x
  Ok (z1, (name, v))
decNamed what _ _ path node = refuse path node what

-- A repeated id must be written as its first occurrence was.
same : String -> SExp -> SExp -> a -> Result SexpError a
same path node first v =
  if node == first then
    Ok v
  else
    refuse path node "this id was written differently before"

decOpt : String -> SExp -> Result SexpError (Option String)
decOpt path node = optionOfSExp expectAtom path node

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
decParamAxis path node =
  map
    snd
    (decNamed
      "expected an axis (NAME PARAM)"
      (stateless decParam)
      emptyZonk
      path
      node)

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
decAuthAxis = decNamed "expected an axis (NAME AUTH)" decAuth

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

-- ── reading the other components ────────────────────────────────────────────

type Reader a = String -> SExp -> Result SexpError a

-- [dec] read at [path]: its refusal's path is put under [path].
export
nested : (SExp -> Result SexpError a) -> Reader a
nested dec path node =
  mapErr (e => { e | sePath = "\{path}/\{e.sePath}" }) (dec node)

export
listOfSExp : Reader a -> Reader (List a)
listOfSExp item path node = decList item path node

export
pairOfSExp : Reader a -> Reader b -> Reader (a, b)
pairOfSExp first second path (SList [a, b]) = do
  x <- first "\{path}/0" a
  y <- second "\{path}/1" b
  Ok (x, y)
pairOfSExp _ _ path node = refuse path node "expected a pair"

export
tripleOfSExp : Reader a -> Reader b -> Reader c -> Reader (a, b, c)
tripleOfSExp first second third path (SList [a, b, c]) = do
  x <- first "\{path}/0" a
  y <- second "\{path}/1" b
  w <- third "\{path}/2" c
  Ok (x, y, w)
tripleOfSExp _ _ _ path node = refuse path node "expected a triple"

export
optionOfSExp : Reader a -> Reader (Option a)
optionOfSExp _ _ (SAtom "none") = Ok None
optionOfSExp item path (SList [SAtom "some", x]) =
  map Some (item (at path "some" 1) x)
optionOfSExp _ path node = misfit path [("none", 0), ("some", 1)] node

export
unitOfSExp : Reader Unit
unitOfSExp _ (SList []) = Ok ()
unitOfSExp path node = refuse path node "expected ()"

ascending : Ord a => List a -> Bool
ascending (a :: rest@(b :: _)) = a < b && ascending rest
ascending _ = True

-- The pairs of [node] as a map, refused unless their keys ascend strictly,
-- the order the writer uses.
keyed : Ord k => String -> SExp -> List (k, v) -> Result SexpError (Map k v)
keyed path node pairs =
  if ascending (map fst pairs) then
    Ok (IdMap.fromList pairs)
  else
    refuse path node "keys must ascend strictly"

decMap : Ord k => Reader k -> Reader v -> Reader (Map k v)
decMap key value path node = do
  pairs <- decList (pairOfSExp key value) path node
  keyed path node pairs

export
ordMapOfSExp : Reader a -> Reader (OrdMap a)
ordMapOfSExp value path node = decMap expectAtom value path node

export
intMapOfSExp : Reader a -> Reader (Map Int a)
intMapOfSExp value path node = decMap atomInt value path node

surfaceHeads : List (String, Int)
surfaceHeads = [
  ("scon", 2),
  ("svar", 1),
  ("sapp", 2),
  ("sfun", 2),
  ("stuple", 1),
  ("seffect", 3),
  ("sconstrained", 2),
  ("snamed", 3),
  ("squal", 2),
  ("srow", 2),
  ("sauth", 1),
]

decSurface : Reader Ty
decSurface path (SList [SAtom "scon", n, o]) = do
  name <- expectAtom (at path "scon" 1) n
  origin <- decOrigin (at path "scon" 2) o
  Ok TyCon { tyConName = name, tyConLoc = None, tyConOrigin = origin }
decSurface path (SList [SAtom "svar", n]) =
  map TyVar (expectAtom (at path "svar" 1) n)
decSurface path (SList [SAtom "sapp", f, a]) = do
  f1 <- decSurface (at path "sapp" 1) f
  a1 <- decSurface (at path "sapp" 2) a
  Ok (TyApp f1 a1)
decSurface path (SList [SAtom "sfun", a, b]) = do
  a1 <- decSurface (at path "sfun" 1) a
  b1 <- decSurface (at path "sfun" 2) b
  Ok (TyFun a1 b1)
decSurface path (SList [SAtom "stuple", tys]) =
  map TyTuple (decList decSurface (at path "stuple" 1) tys)
decSurface path (SList [SAtom "seffect", atoms, tails, t]) = do
  atoms1 <- decList decEffAtom (at path "seffect" 1) atoms
  tails1 <- decList expectAtom (at path "seffect" 2) tails
  t1 <- decSurface (at path "seffect" 3) t
  Ok (TyEffect atoms1 tails1 t1)
decSurface path (SList [SAtom "sconstrained", cs, t]) = do
  cs1 <- decList decConstraint (at path "sconstrained" 1) cs
  t1 <- decSurface (at path "sconstrained" 2) t
  Ok (TyConstrained cs1 t1)
decSurface path (SList [SAtom "snamed", n, t, d]) = do
  name <- expectAtom (at path "snamed" 1) n
  t1 <- decSurface (at path "snamed" 2) t
  domain <- optionOfSExp decEffAtom (at path "snamed" 3) d
  Ok (TyNamed name t1 domain)
decSurface path (SList [SAtom "squal", t, ps]) = do
  t1 <- decSurface (at path "squal" 1) t
  ps1 <- decList decEffParam (at path "squal" 2) ps
  Ok (TyQual t1 ps1 None)
decSurface path (SList [SAtom "srow", atoms, tails]) = do
  atoms1 <- decList decEffAtom (at path "srow" 1) atoms
  tails1 <- decList expectAtom (at path "srow" 2) tails
  Ok (TyRow atoms1 tails1 None)
decSurface path (SList [SAtom "sauth", ps]) =
  map (ps1 => TyAuth ps1 None) (decList decEffParam (at path "sauth" 1) ps)
decSurface path node = misfit path surfaceHeads node

decEffAtom : Reader EffAtomTy
decEffAtom path (SList [SAtom "seat", l, o, p, pat]) = do
  label <- expectAtom (at path "seat" 1) l
  origin <- decOrigin (at path "seat" 2) o
  param <- decEffParam (at path "seat" 3) p
  patterned <- atomBool (at path "seat" 4) pat
  Ok EffAtomTy {
    eatLabel = label,
    eatOrigin = origin,
    eatParam = param,
    eatLoc = None,
    eatPattern = patterned,
  }
decEffAtom path node = misfit path [("seat", 4)] node

effParamHeads : List (String, Int)
effParamHeads =
  [("stop", 0), ("slit", 1), ("sname", 1), ("sset", 1), ("sproduct", 1)]

decEffParam : Reader EffParamTy
decEffParam _ (SAtom "stop") = Ok EPTop
decEffParam path (SList [SAtom "slit", s]) =
  map EPLit (expectAtom (at path "slit" 1) s)
decEffParam path (SList [SAtom "sname", s]) =
  map EPName (expectAtom (at path "sname" 1) s)
decEffParam path (SList [SAtom "sset", members]) =
  map EPSet (decList expectAtom (at path "sset" 1) members)
decEffParam path (SList [SAtom "sproduct", axes]) =
  map
    EPProduct
    (decList (pairOfSExp expectAtom decEffParam) (at path "sproduct" 1) axes)
decEffParam path node = misfit path effParamHeads node

decConstraint : Reader Constraint
decConstraint path (SList [SAtom "constraint", h, args, o]) = do
  name <- expectAtom (at path "constraint" 1) h
  args1 <- decList decSurface (at path "constraint" 2) args
  origin <- decOrigin (at path "constraint" 3) o
  Ok Constraint {
    constraintHead = name,
    constraintArgs = args1,
    constraintOrigin = origin,
  }
decConstraint path node = misfit path [("constraint", 3)] node

decVariant : Reader Variant
decVariant path (SList [SAtom "variant", n, p]) = do
  name <- expectAtom (at path "variant" 1) n
  payload <- decPayload (at path "variant" 2) p
  Ok (Variant name payload)
decVariant path node = misfit path [("variant", 2)] node

decPayload : Reader ConPayload
decPayload path (SList [SAtom "pos", tys]) =
  map ConPos (decList decSurface (at path "pos" 1) tys)
decPayload path (SList [SAtom "named", fs, omitted]) = do
  fields <- decList decField (at path "named" 1) fs
  nameOmitted <- atomBool (at path "named" 2) omitted
  Ok (ConNamed fields nameOmitted)
decPayload path node = misfit path [("pos", 1), ("named", 2)] node

decField : Reader Field
decField path (SList [SAtom "field", n, t]) = do
  name <- expectAtom (at path "field" 1) n
  t1 <- decSurface (at path "field" 2) t
  Ok (Field name t1)
decField path node = misfit path [("field", 2)] node

nsHeads : List (String, Int)
nsHeads = [
  ("type", 0),
  ("iface", 0),
  ("method", 0),
  ("ctor", 0),
  ("field", 0),
  ("value", 0),
]

decNs : Reader Ns
decNs _ (SAtom "type") = Ok NsType
decNs _ (SAtom "iface") = Ok NsIface
decNs _ (SAtom "method") = Ok NsMethod
decNs _ (SAtom "ctor") = Ok NsCtor
decNs _ (SAtom "field") = Ok NsField
decNs _ (SAtom "value") = Ok NsValue
decNs path node = misfit path nsHeads node

decIdent : Reader Ident
decIdent path (SList [SAtom "ident", ns, o, n]) = do
  ns1 <- decNs (at path "ident" 1) ns
  origin <- decOrigin (at path "ident" 2) o
  name <- expectAtom (at path "ident" 3) n
  match mkIdent ns1 origin name
    Some ident => Ok ident
    None => refuse (at path "ident" 2) o "an identity names a module or builtin"
decIdent path node = misfit path [("ident", 3)] node

decTabKey : Reader TabKey
decTabKey path (SList [SAtom "tkident", i]) =
  map TkIdent (decIdent (at path "tkident" 1) i)
decTabKey path (SList [SAtom "tkbare", ns, n]) = do
  ns1 <- decNs (at path "tkbare" 1) ns
  name <- expectAtom (at path "tkbare" 2) n
  Ok (TkBare ns1 name)
decTabKey path node = misfit path [("tkident", 1), ("tkbare", 2)] node

decDataVis : Reader DataVis
decDataVis _ (SAtom "private") = Ok VisPrivate
decDataVis _ (SAtom "abstract") = Ok VisAbstract
decDataVis _ (SAtom "public") = Ok VisPublic
decDataVis path node =
  misfit path [("private", 0), ("abstract", 0), ("public", 0)] node

decNamedMono : ZState -> String -> SExp -> Dec (String, Mono)
decNamedMono = decNamed "expected a pair (NAME MONO)" decMono

decRecord : ZState -> String -> SExp -> Dec RecordInfo
decRecord z path (SList [SAtom "record", ids, authIds, r, fs, ix]) = do
  ids1 <- decList atomInt (at path "record" 1) ids
  authIds1 <- decList atomInt (at path "record" 2) authIds
  (z1, result) <- decMono z (at path "record" 3) r
  (z2, fields) <- decEach decNamedMono z1 (at path "record" 4) fs
  (z3, pairs) <- decEach decNamedMono z2 (at path "record" 5) ix
  index <- keyed (at path "record" 5) ix pairs
  Ok (z3, RecordInfo ids1 authIds1 result fields index)
decRecord _ path node = misfit path [("record", 5)] node

decSlotArgs : ZState -> String -> SExp -> Dec PredicateSlotArgs
decSlotArgs z _ (SAtom "psunknown") = Ok (z, PSArgsUnknown)
decSlotArgs z path (SList [SAtom "psknown", args]) =
  map
    (r => (fst r, PSArgsKnown (snd r)))
    (decEach decMono z (at path "psknown" 1) args)
decSlotArgs _ path node = misfit path [("psunknown", 0), ("psknown", 1)] node

decSlot : ZState -> String -> SExp -> Dec PredicateSlot
decSlot z path (SList [SAtom "slot", i, a, ids]) = do
  iface <- decIface (at path "slot" 1) i
  (z1, args) <- decSlotArgs z (at path "slot" 2) a
  ids1 <- decList atomInt (at path "slot" 3) ids
  Ok (z1, PredicateSlot { psIface = iface, psArgs = args, psBoundIds = ids1 })
decSlot _ path node = misfit path [("slot", 3)] node

decMethodSlot : ZState -> String -> SExp -> Dec MethodPredicateSlot
decMethodSlot z path (SList [SAtom "mslot", s, ps]) = do
  (z1, slot) <- decSlot z (at path "mslot" 1) s
  positions <- decList atomInt (at path "mslot" 2) ps
  Ok (z1, MethodPredicateSlot { mpsPredicate = slot, mpsPositions = positions })
decMethodSlot _ path node = misfit path [("mslot", 2)] node

decPrefix : Reader CDeclaredPrefix
decPrefix _ (SAtom "cdpunknown") = Ok CDPUnknown
decPrefix path (SList [SAtom "cdplen", n]) =
  map CDPLen (atomInt (at path "cdplen" 1) n)
decPrefix path node = misfit path [("cdpunknown", 0), ("cdplen", 1)] node

decClasses : Reader BuiltinClasses
decClasses path (SList [SAtom "classes", num, eq, ord, semi, numP, eqP, ordP, semiP, seeded]) =
  do
    numO <- decOrigin (at path "classes" 1) num
    eqO <- decOrigin (at path "classes" 2) eq
    ordO <- decOrigin (at path "classes" 3) ord
    semiO <- decOrigin (at path "classes" 4) semi
    numB <- atomBool (at path "classes" 5) numP
    eqB <- atomBool (at path "classes" 6) eqP
    ordB <- atomBool (at path "classes" 7) ordP
    semiB <- atomBool (at path "classes" 8) semiP
    seededB <- atomBool (at path "classes" 9) seeded
    Ok BuiltinClasses {
      bcNum = numO,
      bcEq = eqO,
      bcOrd = ordO,
      bcSemigroup = semiO,
      bcNumPresent = numB,
      bcEqPresent = eqB,
      bcOrdPresent = ordB,
      bcSemigroupPresent = semiB,
      bcPreludeSeeded = seededB,
    }
decClasses path node = misfit path [("classes", 9)] node

decPopRow : Reader a -> Reader (Ident, String, a)
decPopRow payload path (SList [SAtom "sprow", i, o, p]) = do
  ident <- decIdent (at path "sprow" 1) i
  owner <- expectAtom (at path "sprow" 2) o
  p1 <- payload (at path "sprow" 3) p
  Ok (ident, owner, p1)
decPopRow _ path node = misfit path [("sprow", 3)] node

export
spellingPopOfSExp : Reader a -> Reader (SpellingPop a)
spellingPopOfSExp payload path (SList [SAtom "pop", rows, floor, collided]) = do
  rows1 <- ordMapOfSExp (decList (decPopRow payload)) (at path "pop" 1) rows
  floor1 <- ordMapOfSExp payload (at path "pop" 2) floor
  collided1 <- decList expectAtom (at path "pop" 3) collided
  Ok (spFromProjections rows1 floor1 collided1)
spellingPopOfSExp _ path node = misfit path [("pop", 3)] node

export
surfaceTyOfSExp : SExp -> Result SexpError Ty
surfaceTyOfSExp = decSurface "ty"

export
variantOfSExp : SExp -> Result SexpError Variant
variantOfSExp = decVariant "variant"

export
tabKeyOfSExp : SExp -> Result SexpError TabKey
tabKeyOfSExp = decTabKey "tabkey"

export
dataVisOfSExp : SExp -> Result SexpError DataVis
dataVisOfSExp = decDataVis "vis"

export
recordInfoOfSExp : SExp -> Result SexpError RecordInfo
recordInfoOfSExp = rooted decRecord "record"

export
predicateSlotOfSExp : SExp -> Result SexpError PredicateSlot
predicateSlotOfSExp = rooted decSlot "slot"

export
methodPredicateSlotOfSExp : SExp -> Result SexpError MethodPredicateSlot
methodPredicateSlotOfSExp = rooted decMethodSlot "mslot"

export
cDeclaredPrefixOfSExp : SExp -> Result SexpError CDeclaredPrefix
cDeclaredPrefixOfSExp = decPrefix "prefix"

export
builtinClassesOfSExp : SExp -> Result SexpError BuiltinClasses
builtinClassesOfSExp = decClasses "classes"

-- ── the whole file ──────────────────────────────────────────────────────────

-- [isJoins] are the IO joins the section's interface is valid for.
public export data InterfaceSection = InterfaceSection {
  isJoins : List (List Atom),
  isInterface : PreludeInterface,
}

public export data PreludeInterfaceFile = PreludeInterfaceFile {
  ifKey : InterfaceKey,
  ifSections : List InterfaceSection,
}

export
formatVersion : Int
formatVersion = 2

export
sectionsOfCache : List (List (List Atom), PreludeInterface) ->
  List InterfaceSection
sectionsOfCache = map (s => InterfaceSection {
  isJoins = fst s,
  isInterface = snd s,
})

export
cacheOfSections : List InterfaceSection ->
  List (List (List Atom), PreludeInterface)
cacheOfSections = map (s => (s.isJoins, s.isInterface))

-- One section per distinct interface text.  [drives] pairs a join with the
-- interface a drive under it produced; the sections come in order of first
-- appearance, each listing its joins sorted as the encoder writes them, once.
export
mergeSections : List (List Atom, PreludeInterface) -> List InterfaceSection
mergeSections drives =
  let keyed = map (d => (renderSExp (interfaceNode (snd d)), d)) drives
  let joinsByText = fold addJoin omEmpty keyed
  map
    (k => InterfaceSection {
      isJoins = sortedJoins (optionOr [] (omLookup (fst k) joinsByText)),
      isInterface = snd (snd k),
    })
    (dedupBy fst keyed)

addJoin : OrdMap (List (List Atom)) ->
  (String, (List Atom, PreludeInterface)) ->
  OrdMap (List (List Atom))
addJoin acc (text, (join, _)) =
  omInsert text (join :: optionOr [] (omLookup text acc)) acc

sortedJoins : List (List Atom) -> List (List Atom)
sortedJoins joins = dedupBy joinText (sortOn joinText joins)

joinText : List Atom -> String
joinText j = renderSExp (joinNode j)

pairAtoms : (String, String) -> SExp
pairAtoms = pairSExp SAtom SAtom

-- The SHA-256 of a text, in lower-case hex.
export
sha256Hex : String -> String
sha256Hex text = Hex.encode (sha256 (encodeUtf8 text))

headerNode : InterfaceKey -> Int -> String -> SExp
headerNode key count digest = tagged "medaka-interface" [
  intNode formatVersion,
  tagged "sources" [listSExp pairAtoms key.ikSources],
  tagged "compiler" [SAtom key.ikCompiler],
  tagged "sections" [intNode count],
  tagged "digest" [SAtom digest],
]

-- What the digest covers: the file's text after its first line.
bodyOf : String -> String
bodyOf text = match S.indexOf "\n" text
  Some i => S.drop (i + 1) text
  None => ""

joinNode : List Atom -> SExp
joinNode = listSExp atomSExp

sectionLine : InterfaceSection -> String
sectionLine s = renderSExp (sectionNode s) ++ "\n"

sectionNode : InterfaceSection -> SExp
sectionNode s = tagged "section" [
  tagged "joins" [listSExp joinNode (sortOn joinText s.isJoins)],
  interfaceNode s.isInterface,
]

-- A constructor call over every field, so a field added to the record is a
-- build error here until it has an arm.
interfaceNode : PreludeInterface -> SExp
interfaceNode (PreludeInterface funNames dispatch ctors ctorPop recordPop classes funSlots funSlotsQual declared declaredQual methodSlots methodSlotsQual ctorEx anyEx externs tyvarNext effvarNext core standalone) = tagged
  "interface"
  [
    ordMapSExp unitSExp funNames,
    listSExp (pairSExp (pairSExp ifaceRefSExp SAtom) intNode) dispatch,
    listSExp
      (pairSExp
        tabKeySExp
        (tripleSExp dataVisSExp (listSExp SAtom) (listSExp variantSExp)))
      ctors,
    spellingPopSExp pubSchemeSExp ctorPop,
    spellingPopSExp recordInfoSExp recordPop,
    builtinClassesSExp classes,
    listSExp (pairSExp SAtom (listSExp predicateSlotSExp)) funSlots,
    listSExp (pairSExp pairAtoms (listSExp predicateSlotSExp)) funSlotsQual,
    listSExp (pairSExp SAtom cDeclaredPrefixSExp) declared,
    listSExp (pairSExp pairAtoms cDeclaredPrefixSExp) declaredQual,
    listSExp (pairSExp SAtom (listSExp methodPredicateSlotSExp)) methodSlots,
    listSExp
      (pairSExp pairAtoms (listSExp methodPredicateSlotSExp))
      methodSlotsQual,
    intMapSExp unitSExp ctorEx,
    boolNode anyEx,
    ordMapSExp
      (pairSExp surfaceTySExp (listSExp (pairSExp SAtom intNode)))
      externs,
    intNode tyvarNext,
    intNode effvarNext,
    listSExp (pairSExp SAtom pubSchemeSExp) core,
    ordMapSExp unitSExp standalone,
  ]

-- The live cells a published row of the interface holds that a frozen row
-- cannot: a link or an open summary.
export
interfaceFaults : PreludeInterface -> List LiveCell
interfaceFaults pi =
  filter
    notFrozen
    (flatMap (row => liveCells (fst row) (snd row)) pi.piCore
      ++ popFaults "ctor" pi.piCtorPop)

popFaults : String -> SpellingPop PubScheme -> List LiveCell
popFaults label pop =
  flatMap
      (k => match omLookup k (spFloor pop)
        Some p => liveCells "\{label} \{k}" p
        None => [])
      (omKeys (spFloor pop))
    ++ flatMap
      (k => match omLookup k (spRows pop)
        Some rows => flatMap (r => liveCells "\{label} \{k}" (thd3 r)) rows
        None => [])
      (omKeys (spRows pop))

thd3 : (a, b, c) -> c
thd3 (_, _, c) = c

-- Panics, naming the row, on a section whose interface holds a live link.  The
-- file's header always carries `formatVersion`; `ikFormat` is not written, and
-- `decodeInterface` sets it.
export
encodeInterface : PreludeInterfaceFile -> String
encodeInterface f =
  match flatMap (s => interfaceFaults s.isInterface) f.ifSections
    [] =>
      let body = stringJoin "" (map sectionLine f.ifSections)
      let header = headerNode f.ifKey (length f.ifSections) (sha256Hex body)
      "\{renderSExp header}\n\{body}"
    faults => panic "interface row is not frozen: \{debug faults}"

decPairAtoms : Reader (String, String)
decPairAtoms = pairOfSExp expectAtom expectAtom

decInterface : Reader PreludeInterface
decInterface path (SList [SAtom "interface", n1, n2, n3, n4, n5, n6, n7, n8, n9, n10, n11, n12, n13, n14, n15, n16, n17, n18, n19]) =
  do
    let p = at path "interface"
    funNames <- ordMapOfSExp unitOfSExp (p 1) n1
    dispatch <- listOfSExp
      (pairOfSExp (pairOfSExp (nested ifaceRefOfSExp) expectAtom) atomInt)
      (p 2)
      n2
    ctors <- listOfSExp
      (pairOfSExp
        (nested tabKeyOfSExp)
        (tripleOfSExp
          (nested dataVisOfSExp)
          (listOfSExp expectAtom)
          (listOfSExp (nested variantOfSExp))))
      (p 3)
      n3
    ctorPop <- spellingPopOfSExp (nested pubSchemeOfSExp) (p 4) n4
    recordPop <- spellingPopOfSExp (nested recordInfoOfSExp) (p 5) n5
    classes <- decClasses (p 6) n6
    funSlots <- listOfSExp
      (pairOfSExp expectAtom (listOfSExp (nested predicateSlotOfSExp)))
      (p 7)
      n7
    funSlotsQual <- listOfSExp
      (pairOfSExp decPairAtoms (listOfSExp (nested predicateSlotOfSExp)))
      (p 8)
      n8
    declared <- listOfSExp
      (pairOfSExp expectAtom (nested cDeclaredPrefixOfSExp))
      (p 9)
      n9
    declaredQual <- listOfSExp
      (pairOfSExp decPairAtoms (nested cDeclaredPrefixOfSExp))
      (p 10)
      n10
    methodSlots <- listOfSExp
      (pairOfSExp expectAtom (listOfSExp (nested methodPredicateSlotOfSExp)))
      (p 11)
      n11
    methodSlotsQual <- listOfSExp
      (pairOfSExp decPairAtoms (listOfSExp (nested methodPredicateSlotOfSExp)))
      (p 12)
      n12
    ctorEx <- intMapOfSExp unitOfSExp (p 13) n13
    anyEx <- atomBool (p 14) n14
    externs <- ordMapOfSExp
      (pairOfSExp
        (nested surfaceTyOfSExp)
        (listOfSExp (pairOfSExp expectAtom atomInt)))
      (p 15)
      n15
    tyvarNext <- atomInt (p 16) n16
    effvarNext <- atomInt (p 17) n17
    core <- listOfSExp
      (pairOfSExp expectAtom (nested pubSchemeOfSExp))
      (p 18)
      n18
    standalone <- ordMapOfSExp unitOfSExp (p 19) n19
    Ok
      (PreludeInterface
        funNames
        dispatch
        ctors
        ctorPop
        recordPop
        classes
        funSlots
        funSlotsQual
        declared
        declaredQual
        methodSlots
        methodSlotsQual
        ctorEx
        anyEx
        externs
        tyvarNext
        effvarNext
        core
        standalone)
decInterface path node = misfit path [("interface", 19)] node

decJoins : Reader (List (List Atom))
decJoins path (SList [SAtom "joins", js]) =
  listOfSExp (listOfSExp (nested atomOfSExp)) (at path "joins" 1) js
decJoins path node = misfit path [("joins", 1)] node

decSection : Reader InterfaceSection
decSection path (SList [SAtom "section", js, i]) = do
  joins <- decJoins (at path "section" 1) js
  value <- decInterface (at path "section" 2) i
  Ok InterfaceSection { isJoins = joins, isInterface = value }
decSection path node = misfit path [("section", 2)] node

-- The key, the number of section nodes the file claims to hold and the digest
-- it claims.  The version is read before the shape.
decHeader : Reader (InterfaceKey, Int, String)
decHeader path (SList ((SAtom "medaka-interface") :: v :: rest)) = do
  version <- atomInt (at path "medaka-interface" 1) v
  if version == formatVersion then match rest
    [SList [SAtom "sources", srcs], SList [SAtom "compiler", c], SList [SAtom "sections", cnt], SList [SAtom "digest", d]] =>
      do
        sources <- listOfSExp decPairAtoms (at path "sources" 1) srcs
        compiler <- expectAtom (at path "compiler" 1) c
        count <- atomInt (at path "sections" 1) cnt
        claimed <- expectAtom (at path "digest" 1) d
        Ok (
          InterfaceKey {
            ikFormat = version,
            ikSources = sources,
            ikCompiler = compiler,
          },
          count,
          claimed,
        )
    _ =>
      misfit
        path
        [("medaka-interface", 5)]
        (SList (SAtom "medaka-interface" :: v :: rest))
  else
    refuse
      (at path "medaka-interface" 1)
      v
      "format version \{version}, this compiler reads \{formatVersion}"
decHeader path node = misfit path [("medaka-interface", 5)] node

-- The text is read as the items of one list, since a parse reads one node.
-- The header's section count must equal the section nodes present, and the
-- digest must match the bytes after the header line, so a file cut anywhere,
-- its final newline included, is refused.
export
decodeInterface : String -> Result SexpError PreludeInterfaceFile
decodeInterface text = do
  top <- parseSExp ("(" ++ text ++ ")")
  map fst (decodeParsed (bodyOf text) top)

-- Why a file did not decode: its header declares a format version other than
-- the one this compiler reads, or it is malformed in some other way.
-- lint-disable-next-line rule-clone-type
public export data InterfaceFault = WrongFormat Int | Malformed SexpError

export
renderFault : InterfaceFault -> String
renderFault (WrongFormat v) =
  "format version \{v}, this compiler reads \{formatVersion}"
renderFault (Malformed e) = "\{e.sePath}: \{e.seWhat}"

-- The decoded file with the digest its header claims, or why it is refused.
export
readInterface : String -> Result InterfaceFault (PreludeInterfaceFile, String)
readInterface text = match parseSExp ("(" ++ text ++ ")")
  Err e => Err (Malformed e)
  Ok top => match declaredVersion top
    Some v if v /= formatVersion => Err (WrongFormat v)
    _ => mapErr Malformed (decodeParsed (bodyOf text) top)

-- The version the first node declares, when it declares one.
declaredVersion : SExp -> Option Int
declaredVersion (SList ((SList ((SAtom "medaka-interface") :: v :: _)) :: _)) =
  match atomInt "" v
    Ok n => Some n
    Err _ => None
declaredVersion _ = None

decodeParsed : String -> SExp -> Result SexpError (PreludeInterfaceFile, String)
decodeParsed body (SList (header :: sections)) = do
  (key, count, claimed) <- decHeader "header" header
  secs <- decList decSection "file" (SList sections)
  let found = sha256Hex body
  if length secs /= count then
    refuse
      "header/sections.1"
      header
      "header counts \{count} section(s), the file holds \{length secs}"
  else if found /= claimed then
    refuse
      "header/digest.1"
      header
      "digest \{S.take 12 claimed} expected, \{S.take 12 found} found"
  else
    Ok (PreludeInterfaceFile { ifKey = key, ifSections = secs }, claimed)
decodeParsed _ top = refuse "file" top "expected a header node"
# DESUGAR
(DUse false (UseGroup ("list") ((mem "mapAccumL" false) (mem "sortOn" false))))
(DUse false (UseGroup ("crypto" "sha256") ((mem "sha256" false))))
(DUse false (UseAlias ("hex") "Hex"))
(DUse false (UseGroup ("bytes") ((mem "encodeUtf8" false))))
(DUse false (UseAlias ("string") "S"))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("map") ((mem "Map" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omKeys" false))))
(DUse false (UseGroup ("support" "util") ((mem "dedupBy" false))))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "SexpError" true) (mem "renderSExp" false) (mem "parseSExp" false) (mem "expectAtom" false) (mem "atomInt" false) (mem "atomBool" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "PreludeInterface" true) (mem "InterfaceKey" true))))
(DUse false (UseGroup ("types" "publish") ((mem "PubScheme" true) (mem "ZState" true) (mem "LiveCell" true) (mem "emptyZonk" false) (mem "zonkMono" false) (mem "zonkRow" false) (mem "zonkAuthority" false) (mem "zonkVecObl" false) (mem "zonkScheme" false) (mem "freezePub" false) (mem "liveCells" false))))
(DUse false (UseGroup ("types" "registry") ((mem "SpellingPop" false) (mem "spRows" false) (mem "spFloor" false) (mem "spCollided" false) (mem "spFromProjections" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "Tyvar" true) (mem "Scheme" true) (mem "AuthResidual" true) (mem "VecObl" true) (mem "IfaceRef" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "RecordInfo" true) (mem "PredicateSlot" true) (mem "PredicateSlotArgs" true) (mem "MethodPredicateSlot" true) (mem "CDeclaredPrefix" true) (mem "BuiltinClasses" true))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "Effvar" true) (mem "Atom" true) (mem "EffLabel" true))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "TyConOrigin" true) (mem "Ty" true) (mem "EffAtomTy" true) (mem "EffParamTy" true) (mem "Constraint" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Field" true) (mem "Ident" true) (mem "Ns" true) (mem "TabKey" true) (mem "DataVis" true) (mem "identOriginFold" false) (mem "mkIdent" false))))
(DTypeSig false "tagged" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "SExp")) (TyCon "SExp"))))
(DFunDef false "tagged" ((PVar "head") (PVar "fields")) (EApp (EVar "SList") (EBinOp "::" (EApp (EVar "SAtom") (EVar "head")) (EVar "fields"))))
(DTypeSig false "intNode" (TyFun (TyCon "Int") (TyCon "SExp")))
(DFunDef false "intNode" ((PVar "n")) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "n"))))
(DTypeSig false "boolNode" (TyFun (TyCon "Bool") (TyCon "SExp")))
(DFunDef false "boolNode" ((PVar "b")) (EApp (EVar "SAtom") (EIf (EVar "b") (ELit (LString "true")) (ELit (LString "false")))))
(DTypeSig false "idsNode" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "SExp")))
(DFunDef false "idsNode" ((PVar "ids")) (EApp (EVar "SList") (EApp (EApp (EVar "map") (EVar "intNode")) (EVar "ids"))))
(DTypeSig false "optNode" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "SExp")))
(DFunDef false "optNode" ((PVar "o")) (EApp (EApp (EVar "optionSExp") (EVar "SAtom")) (EVar "o")))
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
(DFunDef false "paramNode" ((PCon "PProduct" (PVar "axes"))) (EApp (EApp (EVar "tagged") (ELit (LString "product"))) (EListLit (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "paramNode"))) (EVar "axes")))))
(DTypeSig false "unzonked" (TyFun (TyCon "String") (TyVar "a")))
(DFunDef false "unzonked" ((PVar "what")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "interface_sexp: ")) (EApp (EVar "display") (EVar "what"))) (ELit (LString " reached the printer unzonked")))))
(DTypeSig false "authNode" (TyFun (TyCon "Authority") (TyCon "SExp")))
(DFunDef false "authNode" ((PCon "AConst" (PVar "p"))) (EApp (EApp (EVar "tagged") (ELit (LString "const"))) (EListLit (EApp (EVar "paramNode") (EVar "p")))))
(DFunDef false "authNode" ((PCon "AVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" (PVar "id") (PVar "lvl") (PVar "top") (PVar "pat") (PVar "name")) () (EApp (EApp (EVar "tagged") (ELit (LString "av"))) (EListLit (EApp (EVar "intNode") (EVar "id")) (EApp (EVar "intNode") (EVar "lvl")) (EApp (EVar "paramNode") (EVar "top")) (EApp (EVar "boolNode") (EVar "pat")) (EApp (EVar "optNode") (EVar "name"))))) (arm (PCon "ALink" (PVar "id") PWild PWild) () (EApp (EVar "unzonked") (EBinOp "++" (EBinOp "++" (ELit (LString "the linked authority variable ")) (EApp (EVar "display") (EVar "id"))) (ELit (LString "")))))))
(DFunDef false "authNode" ((PCon "AJoin" (PVar "members"))) (EApp (EApp (EVar "tagged") (ELit (LString "ajoin"))) (EListLit (EApp (EVar "SList") (EApp (EApp (EVar "map") (EVar "authNode")) (EVar "members"))))))
(DFunDef false "authNode" ((PCon "AProduct" (PVar "axes"))) (EApp (EApp (EVar "tagged") (ELit (LString "aproduct"))) (EListLit (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "authNode"))) (EVar "axes")))))
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
(DTypeSig true "listSExp" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "SExp"))))
(DFunDef false "listSExp" ((PVar "f") (PVar "xs")) (EApp (EVar "SList") (EApp (EApp (EVar "map") (EVar "f")) (EVar "xs"))))
(DTypeSig true "pairSExp" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyFun (TyVar "b") (TyCon "SExp")) (TyFun (TyTuple (TyVar "a") (TyVar "b")) (TyCon "SExp")))))
(DFunDef false "pairSExp" ((PVar "f") (PVar "g") (PTuple (PVar "a") (PVar "b"))) (EApp (EVar "SList") (EListLit (EApp (EVar "f") (EVar "a")) (EApp (EVar "g") (EVar "b")))))
(DTypeSig true "tripleSExp" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyFun (TyVar "b") (TyCon "SExp")) (TyFun (TyFun (TyVar "c") (TyCon "SExp")) (TyFun (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")) (TyCon "SExp"))))))
(DFunDef false "tripleSExp" ((PVar "f") (PVar "g") (PVar "h") (PTuple (PVar "a") (PVar "b") (PVar "c"))) (EApp (EVar "SList") (EListLit (EApp (EVar "f") (EVar "a")) (EApp (EVar "g") (EVar "b")) (EApp (EVar "h") (EVar "c")))))
(DTypeSig true "optionSExp" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyCon "SExp"))))
(DFunDef false "optionSExp" (PWild (PCon "None")) (EApp (EVar "SAtom") (ELit (LString "none"))))
(DFunDef false "optionSExp" ((PVar "f") (PCon "Some" (PVar "x"))) (EApp (EApp (EVar "tagged") (ELit (LString "some"))) (EListLit (EApp (EVar "f") (EVar "x")))))
(DTypeSig true "unitSExp" (TyFun (TyCon "Unit") (TyCon "SExp")))
(DFunDef false "unitSExp" (PWild) (EApp (EVar "SList") (EListLit)))
(DTypeSig false "mapNode" (TyFun (TyFun (TyVar "k") (TyCon "SExp")) (TyFun (TyFun (TyVar "v") (TyCon "SExp")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "SExp")))))
(DFunDef false "mapNode" ((PVar "key") (PVar "value") (PVar "m")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "key")) (EVar "value"))) (EApp (EVar "IdMap.entries") (EVar "m"))))
(DTypeSig true "ordMapSExp" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyCon "SExp"))))
(DFunDef false "ordMapSExp" ((PVar "value") (PVar "m")) (EApp (EApp (EApp (EVar "mapNode") (EVar "SAtom")) (EVar "value")) (EVar "m")))
(DTypeSig true "intMapSExp" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyVar "a")) (TyCon "SExp"))))
(DFunDef false "intMapSExp" ((PVar "value") (PVar "m")) (EApp (EApp (EApp (EVar "mapNode") (EVar "intNode")) (EVar "value")) (EVar "m")))
(DTypeSig false "surfaceNode" (TyFun (TyCon "Ty") (TyCon "SExp")))
(DFunDef false "surfaceNode" ((PRec "TyCon" ((rf "tyConName" (PVar "name")) (rf "tyConOrigin" (PVar "origin"))) false)) (EApp (EApp (EVar "tagged") (ELit (LString "scon"))) (EListLit (EApp (EVar "SAtom") (EVar "name")) (EApp (EVar "originNode") (EVar "origin")))))
(DFunDef false "surfaceNode" ((PCon "TyVar" (PVar "name"))) (EApp (EApp (EVar "tagged") (ELit (LString "svar"))) (EListLit (EApp (EVar "SAtom") (EVar "name")))))
(DFunDef false "surfaceNode" ((PCon "TyApp" (PVar "f") (PVar "a"))) (EApp (EApp (EVar "tagged") (ELit (LString "sapp"))) (EListLit (EApp (EVar "surfaceNode") (EVar "f")) (EApp (EVar "surfaceNode") (EVar "a")))))
(DFunDef false "surfaceNode" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "tagged") (ELit (LString "sfun"))) (EListLit (EApp (EVar "surfaceNode") (EVar "a")) (EApp (EVar "surfaceNode") (EVar "b")))))
(DFunDef false "surfaceNode" ((PCon "TyTuple" (PVar "tys"))) (EApp (EApp (EVar "tagged") (ELit (LString "stuple"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "surfaceNode")) (EVar "tys")))))
(DFunDef false "surfaceNode" ((PCon "TyEffect" (PVar "atoms") (PVar "tails") (PVar "t"))) (EApp (EApp (EVar "tagged") (ELit (LString "seffect"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "effAtomNode")) (EVar "atoms")) (EApp (EApp (EVar "listSExp") (EVar "SAtom")) (EVar "tails")) (EApp (EVar "surfaceNode") (EVar "t")))))
(DFunDef false "surfaceNode" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EApp (EVar "tagged") (ELit (LString "sconstrained"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "constraintNode")) (EVar "cs")) (EApp (EVar "surfaceNode") (EVar "t")))))
(DFunDef false "surfaceNode" ((PCon "TyNamed" (PVar "name") (PVar "t") (PVar "domain"))) (EApp (EApp (EVar "tagged") (ELit (LString "snamed"))) (EListLit (EApp (EVar "SAtom") (EVar "name")) (EApp (EVar "surfaceNode") (EVar "t")) (EApp (EApp (EVar "optionSExp") (EVar "effAtomNode")) (EVar "domain")))))
(DFunDef false "surfaceNode" ((PCon "TyQual" (PVar "t") (PVar "params") PWild)) (EApp (EApp (EVar "tagged") (ELit (LString "squal"))) (EListLit (EApp (EVar "surfaceNode") (EVar "t")) (EApp (EApp (EVar "listSExp") (EVar "effParamNode")) (EVar "params")))))
(DFunDef false "surfaceNode" ((PCon "TyRow" (PVar "atoms") (PVar "tails") PWild)) (EApp (EApp (EVar "tagged") (ELit (LString "srow"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "effAtomNode")) (EVar "atoms")) (EApp (EApp (EVar "listSExp") (EVar "SAtom")) (EVar "tails")))))
(DFunDef false "surfaceNode" ((PCon "TyAuth" (PVar "params") PWild)) (EApp (EApp (EVar "tagged") (ELit (LString "sauth"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "effParamNode")) (EVar "params")))))
(DTypeSig false "effAtomNode" (TyFun (TyCon "EffAtomTy") (TyCon "SExp")))
(DFunDef false "effAtomNode" ((PVar "a")) (EApp (EApp (EVar "tagged") (ELit (LString "seat"))) (EListLit (EApp (EVar "SAtom") (EFieldAccess (EVar "a") "eatLabel")) (EApp (EVar "originNode") (EFieldAccess (EVar "a") "eatOrigin")) (EApp (EVar "effParamNode") (EFieldAccess (EVar "a") "eatParam")) (EApp (EVar "boolNode") (EFieldAccess (EVar "a") "eatPattern")))))
(DTypeSig false "effParamNode" (TyFun (TyCon "EffParamTy") (TyCon "SExp")))
(DFunDef false "effParamNode" ((PCon "EPTop")) (EApp (EVar "SAtom") (ELit (LString "stop"))))
(DFunDef false "effParamNode" ((PCon "EPLit" (PVar "s"))) (EApp (EApp (EVar "tagged") (ELit (LString "slit"))) (EListLit (EApp (EVar "SAtom") (EVar "s")))))
(DFunDef false "effParamNode" ((PCon "EPName" (PVar "s"))) (EApp (EApp (EVar "tagged") (ELit (LString "sname"))) (EListLit (EApp (EVar "SAtom") (EVar "s")))))
(DFunDef false "effParamNode" ((PCon "EPSet" (PVar "members"))) (EApp (EApp (EVar "tagged") (ELit (LString "sset"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "SAtom")) (EVar "members")))))
(DFunDef false "effParamNode" ((PCon "EPProduct" (PVar "axes"))) (EApp (EApp (EVar "tagged") (ELit (LString "sproduct"))) (EListLit (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "effParamNode"))) (EVar "axes")))))
(DTypeSig false "constraintNode" (TyFun (TyCon "Constraint") (TyCon "SExp")))
(DFunDef false "constraintNode" ((PVar "c")) (EApp (EApp (EVar "tagged") (ELit (LString "constraint"))) (EListLit (EApp (EVar "SAtom") (EFieldAccess (EVar "c") "constraintHead")) (EApp (EApp (EVar "listSExp") (EVar "surfaceNode")) (EFieldAccess (EVar "c") "constraintArgs")) (EApp (EVar "originNode") (EFieldAccess (EVar "c") "constraintOrigin")))))
(DTypeSig false "variantNode" (TyFun (TyCon "Variant") (TyCon "SExp")))
(DFunDef false "variantNode" ((PCon "Variant" (PVar "name") (PVar "payload"))) (EApp (EApp (EVar "tagged") (ELit (LString "variant"))) (EListLit (EApp (EVar "SAtom") (EVar "name")) (EApp (EVar "payloadNode") (EVar "payload")))))
(DTypeSig false "payloadNode" (TyFun (TyCon "ConPayload") (TyCon "SExp")))
(DFunDef false "payloadNode" ((PCon "ConPos" (PVar "tys"))) (EApp (EApp (EVar "tagged") (ELit (LString "pos"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "surfaceNode")) (EVar "tys")))))
(DFunDef false "payloadNode" ((PCon "ConNamed" (PVar "fields") (PVar "nameOmitted"))) (EApp (EApp (EVar "tagged") (ELit (LString "named"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "fieldNode")) (EVar "fields")) (EApp (EVar "boolNode") (EVar "nameOmitted")))))
(DTypeSig false "fieldNode" (TyFun (TyCon "Field") (TyCon "SExp")))
(DFunDef false "fieldNode" ((PCon "Field" (PVar "name") (PVar "t"))) (EApp (EApp (EVar "tagged") (ELit (LString "field"))) (EListLit (EApp (EVar "SAtom") (EVar "name")) (EApp (EVar "surfaceNode") (EVar "t")))))
(DTypeSig false "nsNode" (TyFun (TyCon "Ns") (TyCon "SExp")))
(DFunDef false "nsNode" ((PCon "NsType")) (EApp (EVar "SAtom") (ELit (LString "type"))))
(DFunDef false "nsNode" ((PCon "NsIface")) (EApp (EVar "SAtom") (ELit (LString "iface"))))
(DFunDef false "nsNode" ((PCon "NsMethod")) (EApp (EVar "SAtom") (ELit (LString "method"))))
(DFunDef false "nsNode" ((PCon "NsCtor")) (EApp (EVar "SAtom") (ELit (LString "ctor"))))
(DFunDef false "nsNode" ((PCon "NsField")) (EApp (EVar "SAtom") (ELit (LString "field"))))
(DFunDef false "nsNode" ((PCon "NsValue")) (EApp (EVar "SAtom") (ELit (LString "value"))))
(DTypeSig false "identNode" (TyFun (TyCon "Ident") (TyCon "SExp")))
(DFunDef false "identNode" ((PCon "Ident" (PVar "ns") (PVar "origin") (PVar "name"))) (EApp (EApp (EVar "tagged") (ELit (LString "ident"))) (EListLit (EApp (EVar "nsNode") (EVar "ns")) (EApp (EVar "originNode") (EApp (EApp (EApp (EVar "identOriginFold") (EVar "OriginBuiltin")) (EVar "OriginModule")) (EVar "origin"))) (EApp (EVar "SAtom") (EVar "name")))))
(DTypeSig false "tabKeyNode" (TyFun (TyCon "TabKey") (TyCon "SExp")))
(DFunDef false "tabKeyNode" ((PCon "TkIdent" (PVar "ident"))) (EApp (EApp (EVar "tagged") (ELit (LString "tkident"))) (EListLit (EApp (EVar "identNode") (EVar "ident")))))
(DFunDef false "tabKeyNode" ((PCon "TkBare" (PVar "ns") (PVar "name"))) (EApp (EApp (EVar "tagged") (ELit (LString "tkbare"))) (EListLit (EApp (EVar "nsNode") (EVar "ns")) (EApp (EVar "SAtom") (EVar "name")))))
(DTypeSig false "dataVisNode" (TyFun (TyCon "DataVis") (TyCon "SExp")))
(DFunDef false "dataVisNode" ((PCon "VisPrivate")) (EApp (EVar "SAtom") (ELit (LString "private"))))
(DFunDef false "dataVisNode" ((PCon "VisAbstract")) (EApp (EVar "SAtom") (ELit (LString "abstract"))))
(DFunDef false "dataVisNode" ((PCon "VisPublic")) (EApp (EVar "SAtom") (ELit (LString "public"))))
(DTypeSig false "recordNode" (TyFun (TyCon "RecordInfo") (TyCon "SExp")))
(DFunDef false "recordNode" ((PCon "RecordInfo" (PVar "ids") (PVar "authIds") (PVar "result") (PVar "fields") (PVar "index"))) (EApp (EApp (EVar "tagged") (ELit (LString "record"))) (EListLit (EApp (EVar "idsNode") (EVar "ids")) (EApp (EVar "idsNode") (EVar "authIds")) (EApp (EVar "monoNode") (EVar "result")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "monoNode"))) (EVar "fields")) (EApp (EApp (EVar "ordMapSExp") (EVar "monoNode")) (EVar "index")))))
(DTypeSig false "slotNode" (TyFun (TyCon "PredicateSlot") (TyCon "SExp")))
(DFunDef false "slotNode" ((PVar "s")) (EApp (EApp (EVar "tagged") (ELit (LString "slot"))) (EListLit (EApp (EVar "ifaceNode") (EFieldAccess (EVar "s") "psIface")) (EApp (EVar "slotArgsNode") (EFieldAccess (EVar "s") "psArgs")) (EApp (EVar "idsNode") (EFieldAccess (EVar "s") "psBoundIds")))))
(DTypeSig false "slotArgsNode" (TyFun (TyCon "PredicateSlotArgs") (TyCon "SExp")))
(DFunDef false "slotArgsNode" ((PCon "PSArgsUnknown")) (EApp (EVar "SAtom") (ELit (LString "psunknown"))))
(DFunDef false "slotArgsNode" ((PCon "PSArgsKnown" (PVar "args"))) (EApp (EApp (EVar "tagged") (ELit (LString "psknown"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "monoNode")) (EVar "args")))))
(DTypeSig false "methodSlotNode" (TyFun (TyCon "MethodPredicateSlot") (TyCon "SExp")))
(DFunDef false "methodSlotNode" ((PVar "m")) (EApp (EApp (EVar "tagged") (ELit (LString "mslot"))) (EListLit (EApp (EVar "slotNode") (EFieldAccess (EVar "m") "mpsPredicate")) (EApp (EVar "idsNode") (EFieldAccess (EVar "m") "mpsPositions")))))
(DTypeSig false "prefixNode" (TyFun (TyCon "CDeclaredPrefix") (TyCon "SExp")))
(DFunDef false "prefixNode" ((PCon "CDPUnknown")) (EApp (EVar "SAtom") (ELit (LString "cdpunknown"))))
(DFunDef false "prefixNode" ((PCon "CDPLen" (PVar "n"))) (EApp (EApp (EVar "tagged") (ELit (LString "cdplen"))) (EListLit (EApp (EVar "intNode") (EVar "n")))))
(DTypeSig false "classesNode" (TyFun (TyCon "BuiltinClasses") (TyCon "SExp")))
(DFunDef false "classesNode" ((PVar "b")) (EApp (EApp (EVar "tagged") (ELit (LString "classes"))) (EListLit (EApp (EVar "originNode") (EFieldAccess (EVar "b") "bcNum")) (EApp (EVar "originNode") (EFieldAccess (EVar "b") "bcEq")) (EApp (EVar "originNode") (EFieldAccess (EVar "b") "bcOrd")) (EApp (EVar "originNode") (EFieldAccess (EVar "b") "bcSemigroup")) (EApp (EVar "boolNode") (EFieldAccess (EVar "b") "bcNumPresent")) (EApp (EVar "boolNode") (EFieldAccess (EVar "b") "bcEqPresent")) (EApp (EVar "boolNode") (EFieldAccess (EVar "b") "bcOrdPresent")) (EApp (EVar "boolNode") (EFieldAccess (EVar "b") "bcSemigroupPresent")) (EApp (EVar "boolNode") (EFieldAccess (EVar "b") "bcPreludeSeeded")))))
(DTypeSig false "popRowNode" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyTuple (TyCon "Ident") (TyCon "String") (TyVar "a")) (TyCon "SExp"))))
(DFunDef false "popRowNode" ((PVar "payload") (PTuple (PVar "ident") (PVar "owner") (PVar "p"))) (EApp (EApp (EVar "tagged") (ELit (LString "sprow"))) (EListLit (EApp (EVar "identNode") (EVar "ident")) (EApp (EVar "SAtom") (EVar "owner")) (EApp (EVar "payload") (EVar "p")))))
(DTypeSig false "zonkNamed" (TyFun (TyCon "ZState") (TyFun (TyTuple (TyCon "String") (TyCon "Mono")) (TyTuple (TyCon "ZState") (TyTuple (TyCon "String") (TyCon "Mono"))))))
(DFunDef false "zonkNamed" ((PVar "z") (PTuple (PVar "name") (PVar "m"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "m1")) (EApp (EApp (EVar "zonkMono") (EVar "z")) (EVar "m"))) (DoExpr (ETuple (EVar "z1") (ETuple (EVar "name") (EVar "m1"))))))
(DTypeSig false "zonkSlotArgs" (TyFun (TyCon "PredicateSlot") (TyCon "PredicateSlot")))
(DFunDef false "zonkSlotArgs" ((PVar "s")) (EMatch (EFieldAccess (EVar "s") "psArgs") (arm (PCon "PSArgsUnknown") () (EVar "s")) (arm (PCon "PSArgsKnown" (PVar "args")) () (ERecordUpdate (EVar "s") ((fa "psArgs" (EApp (EVar "PSArgsKnown") (EApp (EVar "snd") (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkMono")) (EVar "emptyZonk")) (EVar "args"))))))))))
(DTypeSig true "surfaceTySExp" (TyFun (TyCon "Ty") (TyCon "SExp")))
(DFunDef false "surfaceTySExp" () (EVar "surfaceNode"))
(DTypeSig true "variantSExp" (TyFun (TyCon "Variant") (TyCon "SExp")))
(DFunDef false "variantSExp" () (EVar "variantNode"))
(DTypeSig true "tabKeySExp" (TyFun (TyCon "TabKey") (TyCon "SExp")))
(DFunDef false "tabKeySExp" () (EVar "tabKeyNode"))
(DTypeSig true "dataVisSExp" (TyFun (TyCon "DataVis") (TyCon "SExp")))
(DFunDef false "dataVisSExp" () (EVar "dataVisNode"))
(DTypeSig true "recordInfoSExp" (TyFun (TyCon "RecordInfo") (TyCon "SExp")))
(DFunDef false "recordInfoSExp" ((PCon "RecordInfo" (PVar "ids") (PVar "authIds") (PVar "result") (PVar "fields") (PVar "index"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "result1")) (EApp (EApp (EVar "zonkMono") (EVar "emptyZonk")) (EVar "result"))) (DoLet false false (PTuple (PVar "z2") (PVar "fields1")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkNamed")) (EVar "z1")) (EVar "fields"))) (DoLet false false (PTuple PWild (PVar "index1")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkNamed")) (EVar "z2")) (EApp (EVar "IdMap.entries") (EVar "index")))) (DoExpr (EApp (EVar "recordNode") (EApp (EApp (EApp (EApp (EApp (EVar "RecordInfo") (EVar "ids")) (EVar "authIds")) (EVar "result1")) (EVar "fields1")) (EApp (EVar "IdMap.fromList") (EVar "index1")))))))
(DTypeSig true "predicateSlotSExp" (TyFun (TyCon "PredicateSlot") (TyCon "SExp")))
(DFunDef false "predicateSlotSExp" ((PVar "s")) (EApp (EVar "slotNode") (EApp (EVar "zonkSlotArgs") (EVar "s"))))
(DTypeSig true "methodPredicateSlotSExp" (TyFun (TyCon "MethodPredicateSlot") (TyCon "SExp")))
(DFunDef false "methodPredicateSlotSExp" ((PVar "m")) (EApp (EVar "methodSlotNode") (ERecordUpdate (EVar "m") ((fa "mpsPredicate" (EApp (EVar "zonkSlotArgs") (EFieldAccess (EVar "m") "mpsPredicate")))))))
(DTypeSig true "cDeclaredPrefixSExp" (TyFun (TyCon "CDeclaredPrefix") (TyCon "SExp")))
(DFunDef false "cDeclaredPrefixSExp" () (EVar "prefixNode"))
(DTypeSig true "builtinClassesSExp" (TyFun (TyCon "BuiltinClasses") (TyCon "SExp")))
(DFunDef false "builtinClassesSExp" () (EVar "classesNode"))
(DTypeSig true "spellingPopSExp" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyApp (TyCon "SpellingPop") (TyVar "a")) (TyCon "SExp"))))
(DFunDef false "spellingPopSExp" ((PVar "payload") (PVar "pop")) (EApp (EApp (EVar "tagged") (ELit (LString "pop"))) (EListLit (EApp (EApp (EVar "ordMapSExp") (EApp (EVar "listSExp") (EApp (EVar "popRowNode") (EVar "payload")))) (EApp (EVar "spRows") (EVar "pop"))) (EApp (EApp (EVar "ordMapSExp") (EVar "payload")) (EApp (EVar "spFloor") (EVar "pop"))) (EApp (EApp (EVar "listSExp") (EVar "SAtom")) (EApp (EVar "spCollided") (EVar "pop"))))))
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
(DTypeSig false "decNamed" (TyFun (TyCon "String") (TyFun (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyVar "a"))))) (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyTuple (TyCon "String") (TyVar "a")))))))))
(DFunDef false "decNamed" (PWild (PVar "f") (PVar "z") (PVar "path") (PCon "SList" (PList (PVar "n") (PVar "x")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "/0")))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "f") (EVar "z")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "/1")))) (EVar "x"))) (ELam ((PTuple (PVar "z1") (PVar "v"))) (EApp (EVar "Ok") (ETuple (EVar "z1") (ETuple (EVar "name") (EVar "v")))))))))
(DFunDef false "decNamed" ((PVar "what") PWild PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (EVar "what")))
(DTypeSig false "same" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyFun (TyCon "SExp") (TyFun (TyVar "a") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))))))
(DFunDef false "same" ((PVar "path") (PVar "node") (PVar "first") (PVar "v")) (EIf (EBinOp "==" (EVar "node") (EVar "first")) (EApp (EVar "Ok") (EVar "v")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "this id was written differently before")))))
(DTypeSig false "decOpt" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "decOpt" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "optionOfSExp") (EVar "expectAtom")) (EVar "path")) (EVar "node")))
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
(DFunDef false "decParamAxis" ((PVar "path") (PVar "node")) (EApp (EApp (EVar "map") (EVar "snd")) (EApp (EApp (EApp (EApp (EApp (EVar "decNamed") (ELit (LString "expected an axis (NAME PARAM)"))) (EApp (EVar "stateless") (EVar "decParam"))) (EVar "emptyZonk")) (EVar "path")) (EVar "node"))))
(DTypeSig false "authHeads" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "authHeads" () (EListLit (ETuple (ELit (LString "const")) (ELit (LInt 1))) (ETuple (ELit (LString "av")) (ELit (LInt 5))) (ETuple (ELit (LString "ajoin")) (ELit (LInt 1))) (ETuple (ELit (LString "aproduct")) (ELit (LInt 1)))))
(DTypeSig false "decAuth" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "Authority"))))))
(DFunDef false "decAuth" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "const"))) (PVar "p")))) (EApp (EApp (EVar "map") (ELam ((PVar "q")) (ETuple (EVar "z") (EApp (EVar "AConst") (EVar "q"))))) (EApp (EApp (EVar "decParam") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "const"))) (ELit (LInt 1)))) (EVar "p"))))
(DFunDef false "decAuth" ((PVar "z") (PVar "path") (PAs "node" (PCon "SList" (PList (PCon "SAtom" (PLit (LString "av"))) (PVar "i") (PVar "l") (PVar "top") (PVar "pat") (PVar "name"))))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "av"))) (ELit (LInt 1)))) (EVar "i"))) (ELam ((PVar "id")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "av"))) (ELit (LInt 2)))) (EVar "l"))) (ELam ((PVar "lvl")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decParam") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "av"))) (ELit (LInt 3)))) (EVar "top"))) (ELam ((PVar "domain")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "av"))) (ELit (LInt 4)))) (EVar "pat"))) (ELam ((PVar "patterned")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decOpt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "av"))) (ELit (LInt 5)))) (EVar "name"))) (ELam ((PVar "binder")) (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EVar "z") "zAuths")) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EVar "same") (EVar "path")) (EVar "node")) (EApp (EVar "authNode") (EApp (EVar "AVar") (EVar "c")))) (ETuple (EVar "z") (EApp (EVar "AVar") (EVar "c"))))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "c") (EApp (EVar "Ref") (EApp (EApp (EApp (EApp (EApp (EVar "AUnbound") (EVar "id")) (EVar "lvl")) (EVar "domain")) (EVar "patterned")) (EVar "binder")))) (DoExpr (EApp (EVar "Ok") (ETuple (ERecordUpdate (EVar "z") ((fa "zAuths" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "c")) (EFieldAccess (EVar "z") "zAuths"))))) (EApp (EVar "AVar") (EVar "c")))))))))))))))))))
(DFunDef false "decAuth" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "ajoin"))) (PVar "members")))) (EApp (EApp (EVar "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "fst") (EVar "r")) (EApp (EVar "AJoin") (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decAuth")) (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ajoin"))) (ELit (LInt 1)))) (EVar "members"))))
(DFunDef false "decAuth" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "aproduct"))) (PVar "axes")))) (EApp (EApp (EVar "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "fst") (EVar "r")) (EApp (EVar "AProduct") (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decAuthAxis")) (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "aproduct"))) (ELit (LInt 1)))) (EVar "axes"))))
(DFunDef false "decAuth" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EVar "authHeads")) (EVar "node")))
(DTypeSig false "decAuthAxis" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyTuple (TyCon "String") (TyCon "Authority")))))))
(DFunDef false "decAuthAxis" () (EApp (EApp (EVar "decNamed") (ELit (LString "expected an axis (NAME AUTH)"))) (EVar "decAuth")))
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
(DTypeAlias false "Reader" ("a") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))))
(DTypeSig true "nested" (TyFun (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a"))) (TyApp (TyCon "Reader") (TyVar "a"))))
(DFunDef false "nested" ((PVar "dec") (PVar "path") (PVar "node")) (EApp (EApp (EVar "mapErr") (ELam ((PVar "e")) (ERecordUpdate (EVar "e") ((fa "sePath" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "/"))) (EApp (EVar "display") (EFieldAccess (EVar "e") "sePath"))) (ELit (LString "")))))))) (EApp (EVar "dec") (EVar "node"))))
(DTypeSig true "listOfSExp" (TyFun (TyApp (TyCon "Reader") (TyVar "a")) (TyApp (TyCon "Reader") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "listOfSExp" ((PVar "item") (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "decList") (EVar "item")) (EVar "path")) (EVar "node")))
(DTypeSig true "pairOfSExp" (TyFun (TyApp (TyCon "Reader") (TyVar "a")) (TyFun (TyApp (TyCon "Reader") (TyVar "b")) (TyApp (TyCon "Reader") (TyTuple (TyVar "a") (TyVar "b"))))))
(DFunDef false "pairOfSExp" ((PVar "first") (PVar "second") (PVar "path") (PCon "SList" (PList (PVar "a") (PVar "b")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "first") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "/0")))) (EVar "a"))) (ELam ((PVar "x")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "second") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "/1")))) (EVar "b"))) (ELam ((PVar "y")) (EApp (EVar "Ok") (ETuple (EVar "x") (EVar "y"))))))))
(DFunDef false "pairOfSExp" (PWild PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "expected a pair"))))
(DTypeSig true "tripleOfSExp" (TyFun (TyApp (TyCon "Reader") (TyVar "a")) (TyFun (TyApp (TyCon "Reader") (TyVar "b")) (TyFun (TyApp (TyCon "Reader") (TyVar "c")) (TyApp (TyCon "Reader") (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")))))))
(DFunDef false "tripleOfSExp" ((PVar "first") (PVar "second") (PVar "third") (PVar "path") (PCon "SList" (PList (PVar "a") (PVar "b") (PVar "c")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "first") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "/0")))) (EVar "a"))) (ELam ((PVar "x")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "second") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "/1")))) (EVar "b"))) (ELam ((PVar "y")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "third") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "path"))) (ELit (LString "/2")))) (EVar "c"))) (ELam ((PVar "w")) (EApp (EVar "Ok") (ETuple (EVar "x") (EVar "y") (EVar "w"))))))))))
(DFunDef false "tripleOfSExp" (PWild PWild PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "expected a triple"))))
(DTypeSig true "optionOfSExp" (TyFun (TyApp (TyCon "Reader") (TyVar "a")) (TyApp (TyCon "Reader") (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "optionOfSExp" (PWild PWild (PCon "SAtom" (PLit (LString "none")))) (EApp (EVar "Ok") (EVar "None")))
(DFunDef false "optionOfSExp" ((PVar "item") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "some"))) (PVar "x")))) (EApp (EApp (EVar "map") (EVar "Some")) (EApp (EApp (EVar "item") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "some"))) (ELit (LInt 1)))) (EVar "x"))))
(DFunDef false "optionOfSExp" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "none")) (ELit (LInt 0))) (ETuple (ELit (LString "some")) (ELit (LInt 1))))) (EVar "node")))
(DTypeSig true "unitOfSExp" (TyApp (TyCon "Reader") (TyCon "Unit")))
(DFunDef false "unitOfSExp" (PWild (PCon "SList" (PList))) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "unitOfSExp" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "expected ()"))))
(DTypeSig false "ascending" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "ascending" ((PCons (PVar "a") (PAs "rest" (PCons (PVar "b") PWild)))) (EBinOp "&&" (EBinOp "<" (EVar "a") (EVar "b")) (EApp (EVar "ascending") (EVar "rest"))))
(DFunDef false "ascending" (PWild) (EVar "True"))
(DTypeSig false "keyed" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))))
(DFunDef false "keyed" ((PVar "path") (PVar "node") (PVar "pairs")) (EIf (EApp (EVar "ascending") (EApp (EApp (EVar "map") (EVar "fst")) (EVar "pairs"))) (EApp (EVar "Ok") (EApp (EVar "IdMap.fromList") (EVar "pairs"))) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "keys must ascend strictly")))))
(DTypeSig false "decMap" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyCon "Reader") (TyVar "k")) (TyFun (TyApp (TyCon "Reader") (TyVar "v")) (TyApp (TyCon "Reader") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "decMap" ((PVar "key") (PVar "value") (PVar "path") (PVar "node")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decList") (EApp (EApp (EVar "pairOfSExp") (EVar "key")) (EVar "value"))) (EVar "path")) (EVar "node"))) (ELam ((PVar "pairs")) (EApp (EApp (EApp (EVar "keyed") (EVar "path")) (EVar "node")) (EVar "pairs")))))
(DTypeSig true "ordMapOfSExp" (TyFun (TyApp (TyCon "Reader") (TyVar "a")) (TyApp (TyCon "Reader") (TyApp (TyCon "OrdMap") (TyVar "a")))))
(DFunDef false "ordMapOfSExp" ((PVar "value") (PVar "path") (PVar "node")) (EApp (EApp (EApp (EApp (EVar "decMap") (EVar "expectAtom")) (EVar "value")) (EVar "path")) (EVar "node")))
(DTypeSig true "intMapOfSExp" (TyFun (TyApp (TyCon "Reader") (TyVar "a")) (TyApp (TyCon "Reader") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyVar "a")))))
(DFunDef false "intMapOfSExp" ((PVar "value") (PVar "path") (PVar "node")) (EApp (EApp (EApp (EApp (EVar "decMap") (EVar "atomInt")) (EVar "value")) (EVar "path")) (EVar "node")))
(DTypeSig false "surfaceHeads" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "surfaceHeads" () (EListLit (ETuple (ELit (LString "scon")) (ELit (LInt 2))) (ETuple (ELit (LString "svar")) (ELit (LInt 1))) (ETuple (ELit (LString "sapp")) (ELit (LInt 2))) (ETuple (ELit (LString "sfun")) (ELit (LInt 2))) (ETuple (ELit (LString "stuple")) (ELit (LInt 1))) (ETuple (ELit (LString "seffect")) (ELit (LInt 3))) (ETuple (ELit (LString "sconstrained")) (ELit (LInt 2))) (ETuple (ELit (LString "snamed")) (ELit (LInt 3))) (ETuple (ELit (LString "squal")) (ELit (LInt 2))) (ETuple (ELit (LString "srow")) (ELit (LInt 2))) (ETuple (ELit (LString "sauth")) (ELit (LInt 1)))))
(DTypeSig false "decSurface" (TyApp (TyCon "Reader") (TyCon "Ty")))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "scon"))) (PVar "n") (PVar "o")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "scon"))) (ELit (LInt 1)))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "scon"))) (ELit (LInt 2)))) (EVar "o"))) (ELam ((PVar "origin")) (EApp (EVar "Ok") (ERecordCreate "TyCon" ((fa "tyConName" (EVar "name")) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "origin"))))))))))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "svar"))) (PVar "n")))) (EApp (EApp (EVar "map") (EVar "TyVar")) (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "svar"))) (ELit (LInt 1)))) (EVar "n"))))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sapp"))) (PVar "f") (PVar "a")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decSurface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sapp"))) (ELit (LInt 1)))) (EVar "f"))) (ELam ((PVar "f1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decSurface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sapp"))) (ELit (LInt 2)))) (EVar "a"))) (ELam ((PVar "a1")) (EApp (EVar "Ok") (EApp (EApp (EVar "TyApp") (EVar "f1")) (EVar "a1"))))))))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sfun"))) (PVar "a") (PVar "b")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decSurface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sfun"))) (ELit (LInt 1)))) (EVar "a"))) (ELam ((PVar "a1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decSurface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sfun"))) (ELit (LInt 2)))) (EVar "b"))) (ELam ((PVar "b1")) (EApp (EVar "Ok") (EApp (EApp (EVar "TyFun") (EVar "a1")) (EVar "b1"))))))))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "stuple"))) (PVar "tys")))) (EApp (EApp (EVar "map") (EVar "TyTuple")) (EApp (EApp (EApp (EVar "decList") (EVar "decSurface")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "stuple"))) (ELit (LInt 1)))) (EVar "tys"))))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "seffect"))) (PVar "atoms") (PVar "tails") (PVar "t")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "decEffAtom")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "seffect"))) (ELit (LInt 1)))) (EVar "atoms"))) (ELam ((PVar "atoms1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "expectAtom")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "seffect"))) (ELit (LInt 2)))) (EVar "tails"))) (ELam ((PVar "tails1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decSurface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "seffect"))) (ELit (LInt 3)))) (EVar "t"))) (ELam ((PVar "t1")) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "TyEffect") (EVar "atoms1")) (EVar "tails1")) (EVar "t1"))))))))))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sconstrained"))) (PVar "cs") (PVar "t")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "decConstraint")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sconstrained"))) (ELit (LInt 1)))) (EVar "cs"))) (ELam ((PVar "cs1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decSurface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sconstrained"))) (ELit (LInt 2)))) (EVar "t"))) (ELam ((PVar "t1")) (EApp (EVar "Ok") (EApp (EApp (EVar "TyConstrained") (EVar "cs1")) (EVar "t1"))))))))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "snamed"))) (PVar "n") (PVar "t") (PVar "d")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "snamed"))) (ELit (LInt 1)))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decSurface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "snamed"))) (ELit (LInt 2)))) (EVar "t"))) (ELam ((PVar "t1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "optionOfSExp") (EVar "decEffAtom")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "snamed"))) (ELit (LInt 3)))) (EVar "d"))) (ELam ((PVar "domain")) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "TyNamed") (EVar "name")) (EVar "t1")) (EVar "domain"))))))))))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "squal"))) (PVar "t") (PVar "ps")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decSurface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "squal"))) (ELit (LInt 1)))) (EVar "t"))) (ELam ((PVar "t1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "decEffParam")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "squal"))) (ELit (LInt 2)))) (EVar "ps"))) (ELam ((PVar "ps1")) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "TyQual") (EVar "t1")) (EVar "ps1")) (EVar "None"))))))))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "srow"))) (PVar "atoms") (PVar "tails")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "decEffAtom")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "srow"))) (ELit (LInt 1)))) (EVar "atoms"))) (ELam ((PVar "atoms1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "expectAtom")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "srow"))) (ELit (LInt 2)))) (EVar "tails"))) (ELam ((PVar "tails1")) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "TyRow") (EVar "atoms1")) (EVar "tails1")) (EVar "None"))))))))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sauth"))) (PVar "ps")))) (EApp (EApp (EVar "map") (ELam ((PVar "ps1")) (EApp (EApp (EVar "TyAuth") (EVar "ps1")) (EVar "None")))) (EApp (EApp (EApp (EVar "decList") (EVar "decEffParam")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sauth"))) (ELit (LInt 1)))) (EVar "ps"))))
(DFunDef false "decSurface" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EVar "surfaceHeads")) (EVar "node")))
(DTypeSig false "decEffAtom" (TyApp (TyCon "Reader") (TyCon "EffAtomTy")))
(DFunDef false "decEffAtom" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "seat"))) (PVar "l") (PVar "o") (PVar "p") (PVar "pat")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "seat"))) (ELit (LInt 1)))) (EVar "l"))) (ELam ((PVar "label")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "seat"))) (ELit (LInt 2)))) (EVar "o"))) (ELam ((PVar "origin")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decEffParam") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "seat"))) (ELit (LInt 3)))) (EVar "p"))) (ELam ((PVar "param")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "seat"))) (ELit (LInt 4)))) (EVar "pat"))) (ELam ((PVar "patterned")) (EApp (EVar "Ok") (ERecordCreate "EffAtomTy" ((fa "eatLabel" (EVar "label")) (fa "eatOrigin" (EVar "origin")) (fa "eatParam" (EVar "param")) (fa "eatLoc" (EVar "None")) (fa "eatPattern" (EVar "patterned"))))))))))))))
(DFunDef false "decEffAtom" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "seat")) (ELit (LInt 4))))) (EVar "node")))
(DTypeSig false "effParamHeads" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "effParamHeads" () (EListLit (ETuple (ELit (LString "stop")) (ELit (LInt 0))) (ETuple (ELit (LString "slit")) (ELit (LInt 1))) (ETuple (ELit (LString "sname")) (ELit (LInt 1))) (ETuple (ELit (LString "sset")) (ELit (LInt 1))) (ETuple (ELit (LString "sproduct")) (ELit (LInt 1)))))
(DTypeSig false "decEffParam" (TyApp (TyCon "Reader") (TyCon "EffParamTy")))
(DFunDef false "decEffParam" (PWild (PCon "SAtom" (PLit (LString "stop")))) (EApp (EVar "Ok") (EVar "EPTop")))
(DFunDef false "decEffParam" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "slit"))) (PVar "s")))) (EApp (EApp (EVar "map") (EVar "EPLit")) (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "slit"))) (ELit (LInt 1)))) (EVar "s"))))
(DFunDef false "decEffParam" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sname"))) (PVar "s")))) (EApp (EApp (EVar "map") (EVar "EPName")) (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sname"))) (ELit (LInt 1)))) (EVar "s"))))
(DFunDef false "decEffParam" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sset"))) (PVar "members")))) (EApp (EApp (EVar "map") (EVar "EPSet")) (EApp (EApp (EApp (EVar "decList") (EVar "expectAtom")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sset"))) (ELit (LInt 1)))) (EVar "members"))))
(DFunDef false "decEffParam" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sproduct"))) (PVar "axes")))) (EApp (EApp (EVar "map") (EVar "EPProduct")) (EApp (EApp (EApp (EVar "decList") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EVar "decEffParam"))) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sproduct"))) (ELit (LInt 1)))) (EVar "axes"))))
(DFunDef false "decEffParam" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EVar "effParamHeads")) (EVar "node")))
(DTypeSig false "decConstraint" (TyApp (TyCon "Reader") (TyCon "Constraint")))
(DFunDef false "decConstraint" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "constraint"))) (PVar "h") (PVar "args") (PVar "o")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "constraint"))) (ELit (LInt 1)))) (EVar "h"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "decSurface")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "constraint"))) (ELit (LInt 2)))) (EVar "args"))) (ELam ((PVar "args1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "constraint"))) (ELit (LInt 3)))) (EVar "o"))) (ELam ((PVar "origin")) (EApp (EVar "Ok") (ERecordCreate "Constraint" ((fa "constraintHead" (EVar "name")) (fa "constraintArgs" (EVar "args1")) (fa "constraintOrigin" (EVar "origin"))))))))))))
(DFunDef false "decConstraint" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "constraint")) (ELit (LInt 3))))) (EVar "node")))
(DTypeSig false "decVariant" (TyApp (TyCon "Reader") (TyCon "Variant")))
(DFunDef false "decVariant" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "variant"))) (PVar "n") (PVar "p")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "variant"))) (ELit (LInt 1)))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decPayload") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "variant"))) (ELit (LInt 2)))) (EVar "p"))) (ELam ((PVar "payload")) (EApp (EVar "Ok") (EApp (EApp (EVar "Variant") (EVar "name")) (EVar "payload"))))))))
(DFunDef false "decVariant" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "variant")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "decPayload" (TyApp (TyCon "Reader") (TyCon "ConPayload")))
(DFunDef false "decPayload" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "pos"))) (PVar "tys")))) (EApp (EApp (EVar "map") (EVar "ConPos")) (EApp (EApp (EApp (EVar "decList") (EVar "decSurface")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "pos"))) (ELit (LInt 1)))) (EVar "tys"))))
(DFunDef false "decPayload" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "named"))) (PVar "fs") (PVar "omitted")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "decField")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "named"))) (ELit (LInt 1)))) (EVar "fs"))) (ELam ((PVar "fields")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "named"))) (ELit (LInt 2)))) (EVar "omitted"))) (ELam ((PVar "nameOmitted")) (EApp (EVar "Ok") (EApp (EApp (EVar "ConNamed") (EVar "fields")) (EVar "nameOmitted"))))))))
(DFunDef false "decPayload" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "pos")) (ELit (LInt 1))) (ETuple (ELit (LString "named")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "decField" (TyApp (TyCon "Reader") (TyCon "Field")))
(DFunDef false "decField" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "field"))) (PVar "n") (PVar "t")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "field"))) (ELit (LInt 1)))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decSurface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "field"))) (ELit (LInt 2)))) (EVar "t"))) (ELam ((PVar "t1")) (EApp (EVar "Ok") (EApp (EApp (EVar "Field") (EVar "name")) (EVar "t1"))))))))
(DFunDef false "decField" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "field")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "nsHeads" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "nsHeads" () (EListLit (ETuple (ELit (LString "type")) (ELit (LInt 0))) (ETuple (ELit (LString "iface")) (ELit (LInt 0))) (ETuple (ELit (LString "method")) (ELit (LInt 0))) (ETuple (ELit (LString "ctor")) (ELit (LInt 0))) (ETuple (ELit (LString "field")) (ELit (LInt 0))) (ETuple (ELit (LString "value")) (ELit (LInt 0)))))
(DTypeSig false "decNs" (TyApp (TyCon "Reader") (TyCon "Ns")))
(DFunDef false "decNs" (PWild (PCon "SAtom" (PLit (LString "type")))) (EApp (EVar "Ok") (EVar "NsType")))
(DFunDef false "decNs" (PWild (PCon "SAtom" (PLit (LString "iface")))) (EApp (EVar "Ok") (EVar "NsIface")))
(DFunDef false "decNs" (PWild (PCon "SAtom" (PLit (LString "method")))) (EApp (EVar "Ok") (EVar "NsMethod")))
(DFunDef false "decNs" (PWild (PCon "SAtom" (PLit (LString "ctor")))) (EApp (EVar "Ok") (EVar "NsCtor")))
(DFunDef false "decNs" (PWild (PCon "SAtom" (PLit (LString "field")))) (EApp (EVar "Ok") (EVar "NsField")))
(DFunDef false "decNs" (PWild (PCon "SAtom" (PLit (LString "value")))) (EApp (EVar "Ok") (EVar "NsValue")))
(DFunDef false "decNs" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EVar "nsHeads")) (EVar "node")))
(DTypeSig false "decIdent" (TyApp (TyCon "Reader") (TyCon "Ident")))
(DFunDef false "decIdent" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "ident"))) (PVar "ns") (PVar "o") (PVar "n")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decNs") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ident"))) (ELit (LInt 1)))) (EVar "ns"))) (ELam ((PVar "ns1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ident"))) (ELit (LInt 2)))) (EVar "o"))) (ELam ((PVar "origin")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ident"))) (ELit (LInt 3)))) (EVar "n"))) (ELam ((PVar "name")) (EMatch (EApp (EApp (EApp (EVar "mkIdent") (EVar "ns1")) (EVar "origin")) (EVar "name")) (arm (PCon "Some" (PVar "ident")) () (EApp (EVar "Ok") (EVar "ident"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "refuse") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ident"))) (ELit (LInt 2)))) (EVar "o")) (ELit (LString "an identity names a module or builtin"))))))))))))
(DFunDef false "decIdent" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "ident")) (ELit (LInt 3))))) (EVar "node")))
(DTypeSig false "decTabKey" (TyApp (TyCon "Reader") (TyCon "TabKey")))
(DFunDef false "decTabKey" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "tkident"))) (PVar "i")))) (EApp (EApp (EVar "map") (EVar "TkIdent")) (EApp (EApp (EVar "decIdent") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tkident"))) (ELit (LInt 1)))) (EVar "i"))))
(DFunDef false "decTabKey" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "tkbare"))) (PVar "ns") (PVar "n")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decNs") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tkbare"))) (ELit (LInt 1)))) (EVar "ns"))) (ELam ((PVar "ns1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tkbare"))) (ELit (LInt 2)))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EVar "Ok") (EApp (EApp (EVar "TkBare") (EVar "ns1")) (EVar "name"))))))))
(DFunDef false "decTabKey" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "tkident")) (ELit (LInt 1))) (ETuple (ELit (LString "tkbare")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "decDataVis" (TyApp (TyCon "Reader") (TyCon "DataVis")))
(DFunDef false "decDataVis" (PWild (PCon "SAtom" (PLit (LString "private")))) (EApp (EVar "Ok") (EVar "VisPrivate")))
(DFunDef false "decDataVis" (PWild (PCon "SAtom" (PLit (LString "abstract")))) (EApp (EVar "Ok") (EVar "VisAbstract")))
(DFunDef false "decDataVis" (PWild (PCon "SAtom" (PLit (LString "public")))) (EApp (EVar "Ok") (EVar "VisPublic")))
(DFunDef false "decDataVis" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "private")) (ELit (LInt 0))) (ETuple (ELit (LString "abstract")) (ELit (LInt 0))) (ETuple (ELit (LString "public")) (ELit (LInt 0))))) (EVar "node")))
(DTypeSig false "decNamedMono" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "decNamedMono" () (EApp (EApp (EVar "decNamed") (ELit (LString "expected a pair (NAME MONO)"))) (EVar "decMono")))
(DTypeSig false "decRecord" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "RecordInfo"))))))
(DFunDef false "decRecord" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "record"))) (PVar "ids") (PVar "authIds") (PVar "r") (PVar "fs") (PVar "ix")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "atomInt")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "record"))) (ELit (LInt 1)))) (EVar "ids"))) (ELam ((PVar "ids1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "atomInt")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "record"))) (ELit (LInt 2)))) (EVar "authIds"))) (ELam ((PVar "authIds1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decMono") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "record"))) (ELit (LInt 3)))) (EVar "r"))) (ELam ((PTuple (PVar "z1") (PVar "result"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decNamedMono")) (EVar "z1")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "record"))) (ELit (LInt 4)))) (EVar "fs"))) (ELam ((PTuple (PVar "z2") (PVar "fields"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decNamedMono")) (EVar "z2")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "record"))) (ELit (LInt 5)))) (EVar "ix"))) (ELam ((PTuple (PVar "z3") (PVar "pairs"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "keyed") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "record"))) (ELit (LInt 5)))) (EVar "ix")) (EVar "pairs"))) (ELam ((PVar "index")) (EApp (EVar "Ok") (ETuple (EVar "z3") (EApp (EApp (EApp (EApp (EApp (EVar "RecordInfo") (EVar "ids1")) (EVar "authIds1")) (EVar "result")) (EVar "fields")) (EVar "index")))))))))))))))))
(DFunDef false "decRecord" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "record")) (ELit (LInt 5))))) (EVar "node")))
(DTypeSig false "decSlotArgs" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "PredicateSlotArgs"))))))
(DFunDef false "decSlotArgs" ((PVar "z") PWild (PCon "SAtom" (PLit (LString "psunknown")))) (EApp (EVar "Ok") (ETuple (EVar "z") (EVar "PSArgsUnknown"))))
(DFunDef false "decSlotArgs" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "psknown"))) (PVar "args")))) (EApp (EApp (EVar "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "fst") (EVar "r")) (EApp (EVar "PSArgsKnown") (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decMono")) (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "psknown"))) (ELit (LInt 1)))) (EVar "args"))))
(DFunDef false "decSlotArgs" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "psunknown")) (ELit (LInt 0))) (ETuple (ELit (LString "psknown")) (ELit (LInt 1))))) (EVar "node")))
(DTypeSig false "decSlot" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "PredicateSlot"))))))
(DFunDef false "decSlot" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "slot"))) (PVar "i") (PVar "a") (PVar "ids")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decIface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "slot"))) (ELit (LInt 1)))) (EVar "i"))) (ELam ((PVar "iface")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decSlotArgs") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "slot"))) (ELit (LInt 2)))) (EVar "a"))) (ELam ((PTuple (PVar "z1") (PVar "args"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "atomInt")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "slot"))) (ELit (LInt 3)))) (EVar "ids"))) (ELam ((PVar "ids1")) (EApp (EVar "Ok") (ETuple (EVar "z1") (ERecordCreate "PredicateSlot" ((fa "psIface" (EVar "iface")) (fa "psArgs" (EVar "args")) (fa "psBoundIds" (EVar "ids1")))))))))))))
(DFunDef false "decSlot" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "slot")) (ELit (LInt 3))))) (EVar "node")))
(DTypeSig false "decMethodSlot" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "MethodPredicateSlot"))))))
(DFunDef false "decMethodSlot" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "mslot"))) (PVar "s") (PVar "ps")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decSlot") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "mslot"))) (ELit (LInt 1)))) (EVar "s"))) (ELam ((PTuple (PVar "z1") (PVar "slot"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "atomInt")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "mslot"))) (ELit (LInt 2)))) (EVar "ps"))) (ELam ((PVar "positions")) (EApp (EVar "Ok") (ETuple (EVar "z1") (ERecordCreate "MethodPredicateSlot" ((fa "mpsPredicate" (EVar "slot")) (fa "mpsPositions" (EVar "positions")))))))))))
(DFunDef false "decMethodSlot" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "mslot")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "decPrefix" (TyApp (TyCon "Reader") (TyCon "CDeclaredPrefix")))
(DFunDef false "decPrefix" (PWild (PCon "SAtom" (PLit (LString "cdpunknown")))) (EApp (EVar "Ok") (EVar "CDPUnknown")))
(DFunDef false "decPrefix" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "cdplen"))) (PVar "n")))) (EApp (EApp (EVar "map") (EVar "CDPLen")) (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "cdplen"))) (ELit (LInt 1)))) (EVar "n"))))
(DFunDef false "decPrefix" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "cdpunknown")) (ELit (LInt 0))) (ETuple (ELit (LString "cdplen")) (ELit (LInt 1))))) (EVar "node")))
(DTypeSig false "decClasses" (TyApp (TyCon "Reader") (TyCon "BuiltinClasses")))
(DFunDef false "decClasses" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "classes"))) (PVar "num") (PVar "eq") (PVar "ord") (PVar "semi") (PVar "numP") (PVar "eqP") (PVar "ordP") (PVar "semiP") (PVar "seeded")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "classes"))) (ELit (LInt 1)))) (EVar "num"))) (ELam ((PVar "numO")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "classes"))) (ELit (LInt 2)))) (EVar "eq"))) (ELam ((PVar "eqO")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "classes"))) (ELit (LInt 3)))) (EVar "ord"))) (ELam ((PVar "ordO")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "classes"))) (ELit (LInt 4)))) (EVar "semi"))) (ELam ((PVar "semiO")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "classes"))) (ELit (LInt 5)))) (EVar "numP"))) (ELam ((PVar "numB")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "classes"))) (ELit (LInt 6)))) (EVar "eqP"))) (ELam ((PVar "eqB")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "classes"))) (ELit (LInt 7)))) (EVar "ordP"))) (ELam ((PVar "ordB")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "classes"))) (ELit (LInt 8)))) (EVar "semiP"))) (ELam ((PVar "semiB")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "classes"))) (ELit (LInt 9)))) (EVar "seeded"))) (ELam ((PVar "seededB")) (EApp (EVar "Ok") (ERecordCreate "BuiltinClasses" ((fa "bcNum" (EVar "numO")) (fa "bcEq" (EVar "eqO")) (fa "bcOrd" (EVar "ordO")) (fa "bcSemigroup" (EVar "semiO")) (fa "bcNumPresent" (EVar "numB")) (fa "bcEqPresent" (EVar "eqB")) (fa "bcOrdPresent" (EVar "ordB")) (fa "bcSemigroupPresent" (EVar "semiB")) (fa "bcPreludeSeeded" (EVar "seededB"))))))))))))))))))))))))
(DFunDef false "decClasses" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "classes")) (ELit (LInt 9))))) (EVar "node")))
(DTypeSig false "decPopRow" (TyFun (TyApp (TyCon "Reader") (TyVar "a")) (TyApp (TyCon "Reader") (TyTuple (TyCon "Ident") (TyCon "String") (TyVar "a")))))
(DFunDef false "decPopRow" ((PVar "payload") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sprow"))) (PVar "i") (PVar "o") (PVar "p")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decIdent") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sprow"))) (ELit (LInt 1)))) (EVar "i"))) (ELam ((PVar "ident")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sprow"))) (ELit (LInt 2)))) (EVar "o"))) (ELam ((PVar "owner")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "payload") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sprow"))) (ELit (LInt 3)))) (EVar "p"))) (ELam ((PVar "p1")) (EApp (EVar "Ok") (ETuple (EVar "ident") (EVar "owner") (EVar "p1"))))))))))
(DFunDef false "decPopRow" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "sprow")) (ELit (LInt 3))))) (EVar "node")))
(DTypeSig true "spellingPopOfSExp" (TyFun (TyApp (TyCon "Reader") (TyVar "a")) (TyApp (TyCon "Reader") (TyApp (TyCon "SpellingPop") (TyVar "a")))))
(DFunDef false "spellingPopOfSExp" ((PVar "payload") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "pop"))) (PVar "rows") (PVar "floor") (PVar "collided")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "ordMapOfSExp") (EApp (EVar "decList") (EApp (EVar "decPopRow") (EVar "payload")))) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "pop"))) (ELit (LInt 1)))) (EVar "rows"))) (ELam ((PVar "rows1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "ordMapOfSExp") (EVar "payload")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "pop"))) (ELit (LInt 2)))) (EVar "floor"))) (ELam ((PVar "floor1")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "expectAtom")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "pop"))) (ELit (LInt 3)))) (EVar "collided"))) (ELam ((PVar "collided1")) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "spFromProjections") (EVar "rows1")) (EVar "floor1")) (EVar "collided1"))))))))))
(DFunDef false "spellingPopOfSExp" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "pop")) (ELit (LInt 3))))) (EVar "node")))
(DTypeSig true "surfaceTyOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Ty"))))
(DFunDef false "surfaceTyOfSExp" () (EApp (EVar "decSurface") (ELit (LString "ty"))))
(DTypeSig true "variantOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Variant"))))
(DFunDef false "variantOfSExp" () (EApp (EVar "decVariant") (ELit (LString "variant"))))
(DTypeSig true "tabKeyOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "TabKey"))))
(DFunDef false "tabKeyOfSExp" () (EApp (EVar "decTabKey") (ELit (LString "tabkey"))))
(DTypeSig true "dataVisOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "DataVis"))))
(DFunDef false "dataVisOfSExp" () (EApp (EVar "decDataVis") (ELit (LString "vis"))))
(DTypeSig true "recordInfoOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "RecordInfo"))))
(DFunDef false "recordInfoOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decRecord")) (ELit (LString "record"))))
(DTypeSig true "predicateSlotOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "PredicateSlot"))))
(DFunDef false "predicateSlotOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decSlot")) (ELit (LString "slot"))))
(DTypeSig true "methodPredicateSlotOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "MethodPredicateSlot"))))
(DFunDef false "methodPredicateSlotOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decMethodSlot")) (ELit (LString "mslot"))))
(DTypeSig true "cDeclaredPrefixOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "CDeclaredPrefix"))))
(DFunDef false "cDeclaredPrefixOfSExp" () (EApp (EVar "decPrefix") (ELit (LString "prefix"))))
(DTypeSig true "builtinClassesOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "BuiltinClasses"))))
(DFunDef false "builtinClassesOfSExp" () (EApp (EVar "decClasses") (ELit (LString "classes"))))
(DData Public "InterfaceSection" () ((variant "InterfaceSection" (ConNamed (field "isJoins" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))) (field "isInterface" (TyCon "PreludeInterface"))))) ())
(DData Public "PreludeInterfaceFile" () ((variant "PreludeInterfaceFile" (ConNamed (field "ifKey" (TyCon "InterfaceKey")) (field "ifSections" (TyApp (TyCon "List") (TyCon "InterfaceSection")))))) ())
(DTypeSig true "formatVersion" (TyCon "Int"))
(DFunDef false "formatVersion" () (ELit (LInt 2)))
(DTypeSig true "sectionsOfCache" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyCon "PreludeInterface"))) (TyApp (TyCon "List") (TyCon "InterfaceSection"))))
(DFunDef false "sectionsOfCache" () (EApp (EVar "map") (ELam ((PVar "s")) (ERecordCreate "InterfaceSection" ((fa "isJoins" (EApp (EVar "fst") (EVar "s"))) (fa "isInterface" (EApp (EVar "snd") (EVar "s"))))))))
(DTypeSig true "cacheOfSections" (TyFun (TyApp (TyCon "List") (TyCon "InterfaceSection")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyCon "PreludeInterface")))))
(DFunDef false "cacheOfSections" () (EApp (EVar "map") (ELam ((PVar "s")) (ETuple (EFieldAccess (EVar "s") "isJoins") (EFieldAccess (EVar "s") "isInterface")))))
(DTypeSig true "mergeSections" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "PreludeInterface"))) (TyApp (TyCon "List") (TyCon "InterfaceSection"))))
(DFunDef false "mergeSections" ((PVar "drives")) (EBlock (DoLet false false (PVar "keyed") (EApp (EApp (EVar "map") (ELam ((PVar "d")) (ETuple (EApp (EVar "renderSExp") (EApp (EVar "interfaceNode") (EApp (EVar "snd") (EVar "d")))) (EVar "d")))) (EVar "drives"))) (DoLet false false (PVar "joinsByText") (EApp (EApp (EApp (EVar "fold") (EVar "addJoin")) (EVar "omEmpty")) (EVar "keyed"))) (DoExpr (EApp (EApp (EVar "map") (ELam ((PVar "k")) (ERecordCreate "InterfaceSection" ((fa "isJoins" (EApp (EVar "sortedJoins") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EApp (EVar "fst") (EVar "k"))) (EVar "joinsByText"))))) (fa "isInterface" (EApp (EVar "snd") (EApp (EVar "snd") (EVar "k")))))))) (EApp (EApp (EVar "dedupBy") (EVar "fst")) (EVar "keyed"))))))
(DTypeSig false "addJoin" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "PreludeInterface"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "addJoin" ((PVar "acc") (PTuple (PVar "text") (PTuple (PVar "join") PWild))) (EApp (EApp (EApp (EVar "omInsert") (EVar "text")) (EBinOp "::" (EVar "join") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "text")) (EVar "acc"))))) (EVar "acc")))
(DTypeSig false "sortedJoins" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "sortedJoins" ((PVar "joins")) (EApp (EApp (EVar "dedupBy") (EVar "joinText")) (EApp (EApp (EVar "sortOn") (EVar "joinText")) (EVar "joins"))))
(DTypeSig false "joinText" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "joinText" ((PVar "j")) (EApp (EVar "renderSExp") (EApp (EVar "joinNode") (EVar "j"))))
(DTypeSig false "pairAtoms" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "SExp")))
(DFunDef false "pairAtoms" () (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "SAtom")))
(DTypeSig true "sha256Hex" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sha256Hex" ((PVar "text")) (EApp (EVar "Hex.encode") (EApp (EVar "sha256") (EApp (EVar "encodeUtf8") (EVar "text")))))
(DTypeSig false "headerNode" (TyFun (TyCon "InterfaceKey") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "SExp")))))
(DFunDef false "headerNode" ((PVar "key") (PVar "count") (PVar "digest")) (EApp (EApp (EVar "tagged") (ELit (LString "medaka-interface"))) (EListLit (EApp (EVar "intNode") (EVar "formatVersion")) (EApp (EApp (EVar "tagged") (ELit (LString "sources"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "pairAtoms")) (EFieldAccess (EVar "key") "ikSources")))) (EApp (EApp (EVar "tagged") (ELit (LString "compiler"))) (EListLit (EApp (EVar "SAtom") (EFieldAccess (EVar "key") "ikCompiler")))) (EApp (EApp (EVar "tagged") (ELit (LString "sections"))) (EListLit (EApp (EVar "intNode") (EVar "count")))) (EApp (EApp (EVar "tagged") (ELit (LString "digest"))) (EListLit (EApp (EVar "SAtom") (EVar "digest")))))))
(DTypeSig false "bodyOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "bodyOf" ((PVar "text")) (EMatch (EApp (EApp (EVar "S.indexOf") (ELit (LString "\n"))) (EVar "text")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EVar "S.drop") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "text"))) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig false "joinNode" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "SExp")))
(DFunDef false "joinNode" () (EApp (EVar "listSExp") (EVar "atomSExp")))
(DTypeSig false "sectionLine" (TyFun (TyCon "InterfaceSection") (TyCon "String")))
(DFunDef false "sectionLine" ((PVar "s")) (EBinOp "++" (EApp (EVar "renderSExp") (EApp (EVar "sectionNode") (EVar "s"))) (ELit (LString "\n"))))
(DTypeSig false "sectionNode" (TyFun (TyCon "InterfaceSection") (TyCon "SExp")))
(DFunDef false "sectionNode" ((PVar "s")) (EApp (EApp (EVar "tagged") (ELit (LString "section"))) (EListLit (EApp (EApp (EVar "tagged") (ELit (LString "joins"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "joinNode")) (EApp (EApp (EVar "sortOn") (EVar "joinText")) (EFieldAccess (EVar "s") "isJoins"))))) (EApp (EVar "interfaceNode") (EFieldAccess (EVar "s") "isInterface")))))
(DTypeSig false "interfaceNode" (TyFun (TyCon "PreludeInterface") (TyCon "SExp")))
(DFunDef false "interfaceNode" ((PCon "PreludeInterface" (PVar "funNames") (PVar "dispatch") (PVar "ctors") (PVar "ctorPop") (PVar "recordPop") (PVar "classes") (PVar "funSlots") (PVar "funSlotsQual") (PVar "declared") (PVar "declaredQual") (PVar "methodSlots") (PVar "methodSlotsQual") (PVar "ctorEx") (PVar "anyEx") (PVar "externs") (PVar "tyvarNext") (PVar "effvarNext") (PVar "core") (PVar "standalone"))) (EApp (EApp (EVar "tagged") (ELit (LString "interface"))) (EListLit (EApp (EApp (EVar "ordMapSExp") (EVar "unitSExp")) (EVar "funNames")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EApp (EApp (EVar "pairSExp") (EVar "ifaceRefSExp")) (EVar "SAtom"))) (EVar "intNode"))) (EVar "dispatch")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "tabKeySExp")) (EApp (EApp (EApp (EVar "tripleSExp") (EVar "dataVisSExp")) (EApp (EVar "listSExp") (EVar "SAtom"))) (EApp (EVar "listSExp") (EVar "variantSExp"))))) (EVar "ctors")) (EApp (EApp (EVar "spellingPopSExp") (EVar "pubSchemeSExp")) (EVar "ctorPop")) (EApp (EApp (EVar "spellingPopSExp") (EVar "recordInfoSExp")) (EVar "recordPop")) (EApp (EVar "builtinClassesSExp") (EVar "classes")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EApp (EVar "listSExp") (EVar "predicateSlotSExp")))) (EVar "funSlots")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "pairAtoms")) (EApp (EVar "listSExp") (EVar "predicateSlotSExp")))) (EVar "funSlotsQual")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "cDeclaredPrefixSExp"))) (EVar "declared")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "pairAtoms")) (EVar "cDeclaredPrefixSExp"))) (EVar "declaredQual")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EApp (EVar "listSExp") (EVar "methodPredicateSlotSExp")))) (EVar "methodSlots")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "pairAtoms")) (EApp (EVar "listSExp") (EVar "methodPredicateSlotSExp")))) (EVar "methodSlotsQual")) (EApp (EApp (EVar "intMapSExp") (EVar "unitSExp")) (EVar "ctorEx")) (EApp (EVar "boolNode") (EVar "anyEx")) (EApp (EApp (EVar "ordMapSExp") (EApp (EApp (EVar "pairSExp") (EVar "surfaceTySExp")) (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "intNode"))))) (EVar "externs")) (EApp (EVar "intNode") (EVar "tyvarNext")) (EApp (EVar "intNode") (EVar "effvarNext")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "pubSchemeSExp"))) (EVar "core")) (EApp (EApp (EVar "ordMapSExp") (EVar "unitSExp")) (EVar "standalone")))))
(DTypeSig true "interfaceFaults" (TyFun (TyCon "PreludeInterface") (TyApp (TyCon "List") (TyCon "LiveCell"))))
(DFunDef false "interfaceFaults" ((PVar "pi")) (EApp (EApp (EVar "filter") (EVar "notFrozen")) (EBinOp "++" (EApp (EApp (EVar "flatMap") (ELam ((PVar "row")) (EApp (EApp (EVar "liveCells") (EApp (EVar "fst") (EVar "row"))) (EApp (EVar "snd") (EVar "row"))))) (EFieldAccess (EVar "pi") "piCore")) (EApp (EApp (EVar "popFaults") (ELit (LString "ctor"))) (EFieldAccess (EVar "pi") "piCtorPop")))))
(DTypeSig false "popFaults" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "SpellingPop") (TyCon "PubScheme")) (TyApp (TyCon "List") (TyCon "LiveCell")))))
(DFunDef false "popFaults" ((PVar "label") (PVar "pop")) (EBinOp "++" (EApp (EApp (EVar "flatMap") (ELam ((PVar "k")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EApp (EVar "spFloor") (EVar "pop"))) (arm (PCon "Some" (PVar "p")) () (EApp (EApp (EVar "liveCells") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "k"))) (ELit (LString "")))) (EVar "p"))) (arm (PCon "None") () (EListLit))))) (EApp (EVar "omKeys") (EApp (EVar "spFloor") (EVar "pop")))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "k")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EApp (EVar "spRows") (EVar "pop"))) (arm (PCon "Some" (PVar "rows")) () (EApp (EApp (EVar "flatMap") (ELam ((PVar "r")) (EApp (EApp (EVar "liveCells") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "label"))) (ELit (LString " "))) (EApp (EVar "display") (EVar "k"))) (ELit (LString "")))) (EApp (EVar "thd3") (EVar "r"))))) (EVar "rows"))) (arm (PCon "None") () (EListLit))))) (EApp (EVar "omKeys") (EApp (EVar "spRows") (EVar "pop"))))))
(DTypeSig false "thd3" (TyFun (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")) (TyVar "c")))
(DFunDef false "thd3" ((PTuple PWild PWild (PVar "c"))) (EVar "c"))
(DTypeSig true "encodeInterface" (TyFun (TyCon "PreludeInterfaceFile") (TyCon "String")))
(DFunDef false "encodeInterface" ((PVar "f")) (EMatch (EApp (EApp (EVar "flatMap") (ELam ((PVar "s")) (EApp (EVar "interfaceFaults") (EFieldAccess (EVar "s") "isInterface")))) (EFieldAccess (EVar "f") "ifSections")) (arm (PList) () (EBlock (DoLet false false (PVar "body") (EApp (EApp (EVar "stringJoin") (ELit (LString ""))) (EApp (EApp (EVar "map") (EVar "sectionLine")) (EFieldAccess (EVar "f") "ifSections")))) (DoLet false false (PVar "header") (EApp (EApp (EApp (EVar "headerNode") (EFieldAccess (EVar "f") "ifKey")) (EApp (EVar "length") (EFieldAccess (EVar "f") "ifSections"))) (EApp (EVar "sha256Hex") (EVar "body")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "renderSExp") (EVar "header")))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "body"))) (ELit (LString "")))))) (arm (PVar "faults") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "interface row is not frozen: ")) (EApp (EVar "display") (EApp (EVar "debug") (EVar "faults")))) (ELit (LString "")))))))
(DTypeSig false "decPairAtoms" (TyApp (TyCon "Reader") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "decPairAtoms" () (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EVar "expectAtom")))
(DTypeSig false "decInterface" (TyApp (TyCon "Reader") (TyCon "PreludeInterface")))
(DFunDef false "decInterface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "interface"))) (PVar "n1") (PVar "n2") (PVar "n3") (PVar "n4") (PVar "n5") (PVar "n6") (PVar "n7") (PVar "n8") (PVar "n9") (PVar "n10") (PVar "n11") (PVar "n12") (PVar "n13") (PVar "n14") (PVar "n15") (PVar "n16") (PVar "n17") (PVar "n18") (PVar "n19")))) (ELet false (PVar "p") (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "interface"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "ordMapOfSExp") (EVar "unitOfSExp")) (EApp (EVar "p") (ELit (LInt 1)))) (EVar "n1"))) (ELam ((PVar "funNames")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EApp (EApp (EVar "pairOfSExp") (EApp (EVar "nested") (EVar "ifaceRefOfSExp"))) (EVar "expectAtom"))) (EVar "atomInt"))) (EApp (EVar "p") (ELit (LInt 2)))) (EVar "n2"))) (ELam ((PVar "dispatch")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EApp (EVar "nested") (EVar "tabKeyOfSExp"))) (EApp (EApp (EApp (EVar "tripleOfSExp") (EApp (EVar "nested") (EVar "dataVisOfSExp"))) (EApp (EVar "listOfSExp") (EVar "expectAtom"))) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "variantOfSExp")))))) (EApp (EVar "p") (ELit (LInt 3)))) (EVar "n3"))) (ELam ((PVar "ctors")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "spellingPopOfSExp") (EApp (EVar "nested") (EVar "pubSchemeOfSExp"))) (EApp (EVar "p") (ELit (LInt 4)))) (EVar "n4"))) (ELam ((PVar "ctorPop")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "spellingPopOfSExp") (EApp (EVar "nested") (EVar "recordInfoOfSExp"))) (EApp (EVar "p") (ELit (LInt 5)))) (EVar "n5"))) (ELam ((PVar "recordPop")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decClasses") (EApp (EVar "p") (ELit (LInt 6)))) (EVar "n6"))) (ELam ((PVar "classes")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "predicateSlotOfSExp"))))) (EApp (EVar "p") (ELit (LInt 7)))) (EVar "n7"))) (ELam ((PVar "funSlots")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "decPairAtoms")) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "predicateSlotOfSExp"))))) (EApp (EVar "p") (ELit (LInt 8)))) (EVar "n8"))) (ELam ((PVar "funSlotsQual")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EApp (EVar "nested") (EVar "cDeclaredPrefixOfSExp")))) (EApp (EVar "p") (ELit (LInt 9)))) (EVar "n9"))) (ELam ((PVar "declared")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "decPairAtoms")) (EApp (EVar "nested") (EVar "cDeclaredPrefixOfSExp")))) (EApp (EVar "p") (ELit (LInt 10)))) (EVar "n10"))) (ELam ((PVar "declaredQual")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "methodPredicateSlotOfSExp"))))) (EApp (EVar "p") (ELit (LInt 11)))) (EVar "n11"))) (ELam ((PVar "methodSlots")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "decPairAtoms")) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "methodPredicateSlotOfSExp"))))) (EApp (EVar "p") (ELit (LInt 12)))) (EVar "n12"))) (ELam ((PVar "methodSlotsQual")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "intMapOfSExp") (EVar "unitOfSExp")) (EApp (EVar "p") (ELit (LInt 13)))) (EVar "n13"))) (ELam ((PVar "ctorEx")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomBool") (EApp (EVar "p") (ELit (LInt 14)))) (EVar "n14"))) (ELam ((PVar "anyEx")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "ordMapOfSExp") (EApp (EApp (EVar "pairOfSExp") (EApp (EVar "nested") (EVar "surfaceTyOfSExp"))) (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EVar "atomInt"))))) (EApp (EVar "p") (ELit (LInt 15)))) (EVar "n15"))) (ELam ((PVar "externs")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EVar "p") (ELit (LInt 16)))) (EVar "n16"))) (ELam ((PVar "tyvarNext")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EVar "p") (ELit (LInt 17)))) (EVar "n17"))) (ELam ((PVar "effvarNext")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EApp (EVar "nested") (EVar "pubSchemeOfSExp")))) (EApp (EVar "p") (ELit (LInt 18)))) (EVar "n18"))) (ELam ((PVar "core")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "ordMapOfSExp") (EVar "unitOfSExp")) (EApp (EVar "p") (ELit (LInt 19)))) (EVar "n19"))) (ELam ((PVar "standalone")) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PreludeInterface") (EVar "funNames")) (EVar "dispatch")) (EVar "ctors")) (EVar "ctorPop")) (EVar "recordPop")) (EVar "classes")) (EVar "funSlots")) (EVar "funSlotsQual")) (EVar "declared")) (EVar "declaredQual")) (EVar "methodSlots")) (EVar "methodSlotsQual")) (EVar "ctorEx")) (EVar "anyEx")) (EVar "externs")) (EVar "tyvarNext")) (EVar "effvarNext")) (EVar "core")) (EVar "standalone")))))))))))))))))))))))))))))))))))))))))))
(DFunDef false "decInterface" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "interface")) (ELit (LInt 19))))) (EVar "node")))
(DTypeSig false "decJoins" (TyApp (TyCon "Reader") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "decJoins" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "joins"))) (PVar "js")))) (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "atomOfSExp")))) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "joins"))) (ELit (LInt 1)))) (EVar "js")))
(DFunDef false "decJoins" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "joins")) (ELit (LInt 1))))) (EVar "node")))
(DTypeSig false "decSection" (TyApp (TyCon "Reader") (TyCon "InterfaceSection")))
(DFunDef false "decSection" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "section"))) (PVar "js") (PVar "i")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decJoins") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "section"))) (ELit (LInt 1)))) (EVar "js"))) (ELam ((PVar "joins")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decInterface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "section"))) (ELit (LInt 2)))) (EVar "i"))) (ELam ((PVar "value")) (EApp (EVar "Ok") (ERecordCreate "InterfaceSection" ((fa "isJoins" (EVar "joins")) (fa "isInterface" (EVar "value"))))))))))
(DFunDef false "decSection" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "section")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "decHeader" (TyApp (TyCon "Reader") (TyTuple (TyCon "InterfaceKey") (TyCon "Int") (TyCon "String"))))
(DFunDef false "decHeader" ((PVar "path") (PCon "SList" (PCons (PCon "SAtom" (PLit (LString "medaka-interface"))) (PCons (PVar "v") (PVar "rest"))))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "medaka-interface"))) (ELit (LInt 1)))) (EVar "v"))) (ELam ((PVar "version")) (EIf (EBinOp "==" (EVar "version") (EVar "formatVersion")) (EMatch (EVar "rest") (arm (PList (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sources"))) (PVar "srcs"))) (PCon "SList" (PList (PCon "SAtom" (PLit (LString "compiler"))) (PVar "c"))) (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sections"))) (PVar "cnt"))) (PCon "SList" (PList (PCon "SAtom" (PLit (LString "digest"))) (PVar "d")))) () (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "decPairAtoms")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sources"))) (ELit (LInt 1)))) (EVar "srcs"))) (ELam ((PVar "sources")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "compiler"))) (ELit (LInt 1)))) (EVar "c"))) (ELam ((PVar "compiler")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sections"))) (ELit (LInt 1)))) (EVar "cnt"))) (ELam ((PVar "count")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "digest"))) (ELit (LInt 1)))) (EVar "d"))) (ELam ((PVar "claimed")) (EApp (EVar "Ok") (ETuple (ERecordCreate "InterfaceKey" ((fa "ikFormat" (EVar "version")) (fa "ikSources" (EVar "sources")) (fa "ikCompiler" (EVar "compiler")))) (EVar "count") (EVar "claimed")))))))))))) (arm PWild () (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "medaka-interface")) (ELit (LInt 5))))) (EApp (EVar "SList") (EBinOp "::" (EApp (EVar "SAtom") (ELit (LString "medaka-interface"))) (EBinOp "::" (EVar "v") (EVar "rest"))))))) (EApp (EApp (EApp (EVar "refuse") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "medaka-interface"))) (ELit (LInt 1)))) (EVar "v")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "format version ")) (EApp (EVar "display") (EVar "version"))) (ELit (LString ", this compiler reads "))) (EApp (EVar "display") (EVar "formatVersion"))) (ELit (LString ""))))))))
(DFunDef false "decHeader" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "medaka-interface")) (ELit (LInt 5))))) (EVar "node")))
(DTypeSig true "decodeInterface" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "PreludeInterfaceFile"))))
(DFunDef false "decodeInterface" ((PVar "text")) (EApp (EApp (EVar "andThen") (EApp (EVar "parseSExp") (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "text")) (ELit (LString ")"))))) (ELam ((PVar "top")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "decodeParsed") (EApp (EVar "bodyOf") (EVar "text"))) (EVar "top"))))))
(DData Public "InterfaceFault" () ((variant "WrongFormat" (ConPos (TyCon "Int"))) (variant "Malformed" (ConPos (TyCon "SexpError")))) ())
(DTypeSig true "renderFault" (TyFun (TyCon "InterfaceFault") (TyCon "String")))
(DFunDef false "renderFault" ((PCon "WrongFormat" (PVar "v"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "format version ")) (EApp (EVar "display") (EVar "v"))) (ELit (LString ", this compiler reads "))) (EApp (EVar "display") (EVar "formatVersion"))) (ELit (LString ""))))
(DFunDef false "renderFault" ((PCon "Malformed" (PVar "e"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "e") "sePath"))) (ELit (LString ": "))) (EApp (EVar "display") (EFieldAccess (EVar "e") "seWhat"))) (ELit (LString ""))))
(DTypeSig true "readInterface" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "PreludeInterfaceFile") (TyCon "String")))))
(DFunDef false "readInterface" ((PVar "text")) (EMatch (EApp (EVar "parseSExp") (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "text")) (ELit (LString ")")))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "Malformed") (EVar "e")))) (arm (PCon "Ok" (PVar "top")) () (EMatch (EApp (EVar "declaredVersion") (EVar "top")) (arm (PCon "Some" (PVar "v")) ((GBool (EBinOp "/=" (EVar "v") (EVar "formatVersion")))) (EApp (EVar "Err") (EApp (EVar "WrongFormat") (EVar "v")))) (arm PWild () (EApp (EApp (EVar "mapErr") (EVar "Malformed")) (EApp (EApp (EVar "decodeParsed") (EApp (EVar "bodyOf") (EVar "text"))) (EVar "top"))))))))
(DTypeSig false "declaredVersion" (TyFun (TyCon "SExp") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "declaredVersion" ((PCon "SList" (PCons (PCon "SList" (PCons (PCon "SAtom" (PLit (LString "medaka-interface"))) (PCons (PVar "v") PWild))) PWild))) (EMatch (EApp (EApp (EVar "atomInt") (ELit (LString ""))) (EVar "v")) (arm (PCon "Ok" (PVar "n")) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "Err" PWild) () (EVar "None"))))
(DFunDef false "declaredVersion" (PWild) (EVar "None"))
(DTypeSig false "decodeParsed" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "PreludeInterfaceFile") (TyCon "String"))))))
(DFunDef false "decodeParsed" ((PVar "body") (PCon "SList" (PCons (PVar "header") (PVar "sections")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "decHeader") (ELit (LString "header"))) (EVar "header"))) (ELam ((PTuple (PVar "key") (PVar "count") (PVar "claimed"))) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "decSection")) (ELit (LString "file"))) (EApp (EVar "SList") (EVar "sections")))) (ELam ((PVar "secs")) (ELet false (PVar "found") (EApp (EVar "sha256Hex") (EVar "body")) (EIf (EBinOp "/=" (EApp (EVar "length") (EVar "secs")) (EVar "count")) (EApp (EApp (EApp (EVar "refuse") (ELit (LString "header/sections.1"))) (EVar "header")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "header counts ")) (EApp (EVar "display") (EVar "count"))) (ELit (LString " section(s), the file holds "))) (EApp (EVar "display") (EApp (EVar "length") (EVar "secs")))) (ELit (LString "")))) (EIf (EBinOp "/=" (EVar "found") (EVar "claimed")) (EApp (EApp (EApp (EVar "refuse") (ELit (LString "header/digest.1"))) (EVar "header")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "digest ")) (EApp (EVar "display") (EApp (EApp (EVar "S.take") (ELit (LInt 12))) (EVar "claimed")))) (ELit (LString " expected, "))) (EApp (EVar "display") (EApp (EApp (EVar "S.take") (ELit (LInt 12))) (EVar "found")))) (ELit (LString " found")))) (EApp (EVar "Ok") (ETuple (ERecordCreate "PreludeInterfaceFile" ((fa "ifKey" (EVar "key")) (fa "ifSections" (EVar "secs")))) (EVar "claimed")))))))))))
(DFunDef false "decodeParsed" (PWild (PVar "top")) (EApp (EApp (EApp (EVar "refuse") (ELit (LString "file"))) (EVar "top")) (ELit (LString "expected a header node"))))
# MARK
(DUse false (UseGroup ("list") ((mem "mapAccumL" false) (mem "sortOn" false))))
(DUse false (UseGroup ("crypto" "sha256") ((mem "sha256" false))))
(DUse false (UseAlias ("hex") "Hex"))
(DUse false (UseGroup ("bytes") ((mem "encodeUtf8" false))))
(DUse false (UseAlias ("string") "S"))
(DUse false (UseAlias ("map") "IdMap"))
(DUse false (UseGroup ("map") ((mem "Map" false))))
(DUse false (UseGroup ("support" "ordmap") ((mem "OrdMap" false) (mem "omEmpty" false) (mem "omInsert" false) (mem "omLookup" false) (mem "omKeys" false))))
(DUse false (UseGroup ("support" "util") ((mem "dedupBy" false))))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "SexpError" true) (mem "renderSExp" false) (mem "parseSExp" false) (mem "expectAtom" false) (mem "atomInt" false) (mem "atomBool" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "PreludeInterface" true) (mem "InterfaceKey" true))))
(DUse false (UseGroup ("types" "publish") ((mem "PubScheme" true) (mem "ZState" true) (mem "LiveCell" true) (mem "emptyZonk" false) (mem "zonkMono" false) (mem "zonkRow" false) (mem "zonkAuthority" false) (mem "zonkVecObl" false) (mem "zonkScheme" false) (mem "freezePub" false) (mem "liveCells" false))))
(DUse false (UseGroup ("types" "registry") ((mem "SpellingPop" false) (mem "spRows" false) (mem "spFloor" false) (mem "spCollided" false) (mem "spFromProjections" false))))
(DUse false (UseGroup ("types" "repr") ((mem "Mono" true) (mem "Tyvar" true) (mem "Scheme" true) (mem "AuthResidual" true) (mem "VecObl" true) (mem "IfaceRef" true))))
(DUse false (UseGroup ("types" "tc_types") ((mem "RecordInfo" true) (mem "PredicateSlot" true) (mem "PredicateSlotArgs" true) (mem "MethodPredicateSlot" true) (mem "CDeclaredPrefix" true) (mem "BuiltinClasses" true))))
(DUse false (UseGroup ("types" "effect_rows") ((mem "EffRow" true) (mem "Effvar" true) (mem "Atom" true) (mem "EffLabel" true))))
(DUse false (UseGroup ("types" "effect_authority") ((mem "Authority" true) (mem "Authvar" true))))
(DUse false (UseGroup ("types" "effect_domain") ((mem "Param" true))))
(DUse false (UseGroup ("frontend" "ast") ((mem "TyConOrigin" true) (mem "Ty" true) (mem "EffAtomTy" true) (mem "EffParamTy" true) (mem "Constraint" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Field" true) (mem "Ident" true) (mem "Ns" true) (mem "TabKey" true) (mem "DataVis" true) (mem "identOriginFold" false) (mem "mkIdent" false))))
(DTypeSig false "tagged" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "SExp")) (TyCon "SExp"))))
(DFunDef false "tagged" ((PVar "head") (PVar "fields")) (EApp (EVar "SList") (EBinOp "::" (EApp (EVar "SAtom") (EVar "head")) (EVar "fields"))))
(DTypeSig false "intNode" (TyFun (TyCon "Int") (TyCon "SExp")))
(DFunDef false "intNode" ((PVar "n")) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "n"))))
(DTypeSig false "boolNode" (TyFun (TyCon "Bool") (TyCon "SExp")))
(DFunDef false "boolNode" ((PVar "b")) (EApp (EVar "SAtom") (EIf (EVar "b") (ELit (LString "true")) (ELit (LString "false")))))
(DTypeSig false "idsNode" (TyFun (TyApp (TyCon "List") (TyCon "Int")) (TyCon "SExp")))
(DFunDef false "idsNode" ((PVar "ids")) (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (EVar "intNode")) (EVar "ids"))))
(DTypeSig false "optNode" (TyFun (TyApp (TyCon "Option") (TyCon "String")) (TyCon "SExp")))
(DFunDef false "optNode" ((PVar "o")) (EApp (EApp (EVar "optionSExp") (EVar "SAtom")) (EVar "o")))
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
(DFunDef false "paramNode" ((PCon "PProduct" (PVar "axes"))) (EApp (EApp (EVar "tagged") (ELit (LString "product"))) (EListLit (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "paramNode"))) (EVar "axes")))))
(DTypeSig false "unzonked" (TyFun (TyCon "String") (TyVar "a")))
(DFunDef false "unzonked" ((PVar "what")) (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "interface_sexp: ")) (EApp (EMethodRef "display") (EVar "what"))) (ELit (LString " reached the printer unzonked")))))
(DTypeSig false "authNode" (TyFun (TyCon "Authority") (TyCon "SExp")))
(DFunDef false "authNode" ((PCon "AConst" (PVar "p"))) (EApp (EApp (EVar "tagged") (ELit (LString "const"))) (EListLit (EApp (EVar "paramNode") (EVar "p")))))
(DFunDef false "authNode" ((PCon "AVar" (PVar "cell"))) (EMatch (EUnOp "!" (EVar "cell")) (arm (PCon "AUnbound" (PVar "id") (PVar "lvl") (PVar "top") (PVar "pat") (PVar "name")) () (EApp (EApp (EVar "tagged") (ELit (LString "av"))) (EListLit (EApp (EVar "intNode") (EVar "id")) (EApp (EVar "intNode") (EVar "lvl")) (EApp (EVar "paramNode") (EVar "top")) (EApp (EVar "boolNode") (EVar "pat")) (EApp (EVar "optNode") (EVar "name"))))) (arm (PCon "ALink" (PVar "id") PWild PWild) () (EApp (EVar "unzonked") (EBinOp "++" (EBinOp "++" (ELit (LString "the linked authority variable ")) (EApp (EMethodRef "display") (EVar "id"))) (ELit (LString "")))))))
(DFunDef false "authNode" ((PCon "AJoin" (PVar "members"))) (EApp (EApp (EVar "tagged") (ELit (LString "ajoin"))) (EListLit (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (EVar "authNode")) (EVar "members"))))))
(DFunDef false "authNode" ((PCon "AProduct" (PVar "axes"))) (EApp (EApp (EVar "tagged") (ELit (LString "aproduct"))) (EListLit (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "authNode"))) (EVar "axes")))))
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
(DTypeSig true "listSExp" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "SExp"))))
(DFunDef false "listSExp" ((PVar "f") (PVar "xs")) (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (EVar "f")) (EVar "xs"))))
(DTypeSig true "pairSExp" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyFun (TyVar "b") (TyCon "SExp")) (TyFun (TyTuple (TyVar "a") (TyVar "b")) (TyCon "SExp")))))
(DFunDef false "pairSExp" ((PVar "f") (PVar "g") (PTuple (PVar "a") (PVar "b"))) (EApp (EVar "SList") (EListLit (EApp (EVar "f") (EVar "a")) (EApp (EVar "g") (EVar "b")))))
(DTypeSig true "tripleSExp" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyFun (TyVar "b") (TyCon "SExp")) (TyFun (TyFun (TyVar "c") (TyCon "SExp")) (TyFun (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")) (TyCon "SExp"))))))
(DFunDef false "tripleSExp" ((PVar "f") (PVar "g") (PVar "h") (PTuple (PVar "a") (PVar "b") (PVar "c"))) (EApp (EVar "SList") (EListLit (EApp (EVar "f") (EVar "a")) (EApp (EVar "g") (EVar "b")) (EApp (EVar "h") (EVar "c")))))
(DTypeSig true "optionSExp" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyApp (TyCon "Option") (TyVar "a")) (TyCon "SExp"))))
(DFunDef false "optionSExp" (PWild (PCon "None")) (EApp (EVar "SAtom") (ELit (LString "none"))))
(DFunDef false "optionSExp" ((PVar "f") (PCon "Some" (PVar "x"))) (EApp (EApp (EVar "tagged") (ELit (LString "some"))) (EListLit (EApp (EVar "f") (EVar "x")))))
(DTypeSig true "unitSExp" (TyFun (TyCon "Unit") (TyCon "SExp")))
(DFunDef false "unitSExp" (PWild) (EApp (EVar "SList") (EListLit)))
(DTypeSig false "mapNode" (TyFun (TyFun (TyVar "k") (TyCon "SExp")) (TyFun (TyFun (TyVar "v") (TyCon "SExp")) (TyFun (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")) (TyCon "SExp")))))
(DFunDef false "mapNode" ((PVar "key") (PVar "value") (PVar "m")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "key")) (EVar "value"))) (EApp (EVar "IdMap.entries") (EVar "m"))))
(DTypeSig true "ordMapSExp" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyApp (TyCon "OrdMap") (TyVar "a")) (TyCon "SExp"))))
(DFunDef false "ordMapSExp" ((PVar "value") (PVar "m")) (EApp (EApp (EApp (EVar "mapNode") (EVar "SAtom")) (EVar "value")) (EVar "m")))
(DTypeSig true "intMapSExp" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyVar "a")) (TyCon "SExp"))))
(DFunDef false "intMapSExp" ((PVar "value") (PVar "m")) (EApp (EApp (EApp (EVar "mapNode") (EVar "intNode")) (EVar "value")) (EVar "m")))
(DTypeSig false "surfaceNode" (TyFun (TyCon "Ty") (TyCon "SExp")))
(DFunDef false "surfaceNode" ((PRec "TyCon" ((rf "tyConName" (PVar "name")) (rf "tyConOrigin" (PVar "origin"))) false)) (EApp (EApp (EVar "tagged") (ELit (LString "scon"))) (EListLit (EApp (EVar "SAtom") (EVar "name")) (EApp (EVar "originNode") (EVar "origin")))))
(DFunDef false "surfaceNode" ((PCon "TyVar" (PVar "name"))) (EApp (EApp (EVar "tagged") (ELit (LString "svar"))) (EListLit (EApp (EVar "SAtom") (EVar "name")))))
(DFunDef false "surfaceNode" ((PCon "TyApp" (PVar "f") (PVar "a"))) (EApp (EApp (EVar "tagged") (ELit (LString "sapp"))) (EListLit (EApp (EVar "surfaceNode") (EVar "f")) (EApp (EVar "surfaceNode") (EVar "a")))))
(DFunDef false "surfaceNode" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "tagged") (ELit (LString "sfun"))) (EListLit (EApp (EVar "surfaceNode") (EVar "a")) (EApp (EVar "surfaceNode") (EVar "b")))))
(DFunDef false "surfaceNode" ((PCon "TyTuple" (PVar "tys"))) (EApp (EApp (EVar "tagged") (ELit (LString "stuple"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "surfaceNode")) (EVar "tys")))))
(DFunDef false "surfaceNode" ((PCon "TyEffect" (PVar "atoms") (PVar "tails") (PVar "t"))) (EApp (EApp (EVar "tagged") (ELit (LString "seffect"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "effAtomNode")) (EVar "atoms")) (EApp (EApp (EVar "listSExp") (EVar "SAtom")) (EVar "tails")) (EApp (EVar "surfaceNode") (EVar "t")))))
(DFunDef false "surfaceNode" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EApp (EVar "tagged") (ELit (LString "sconstrained"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "constraintNode")) (EVar "cs")) (EApp (EVar "surfaceNode") (EVar "t")))))
(DFunDef false "surfaceNode" ((PCon "TyNamed" (PVar "name") (PVar "t") (PVar "domain"))) (EApp (EApp (EVar "tagged") (ELit (LString "snamed"))) (EListLit (EApp (EVar "SAtom") (EVar "name")) (EApp (EVar "surfaceNode") (EVar "t")) (EApp (EApp (EVar "optionSExp") (EVar "effAtomNode")) (EVar "domain")))))
(DFunDef false "surfaceNode" ((PCon "TyQual" (PVar "t") (PVar "params") PWild)) (EApp (EApp (EVar "tagged") (ELit (LString "squal"))) (EListLit (EApp (EVar "surfaceNode") (EVar "t")) (EApp (EApp (EVar "listSExp") (EVar "effParamNode")) (EVar "params")))))
(DFunDef false "surfaceNode" ((PCon "TyRow" (PVar "atoms") (PVar "tails") PWild)) (EApp (EApp (EVar "tagged") (ELit (LString "srow"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "effAtomNode")) (EVar "atoms")) (EApp (EApp (EVar "listSExp") (EVar "SAtom")) (EVar "tails")))))
(DFunDef false "surfaceNode" ((PCon "TyAuth" (PVar "params") PWild)) (EApp (EApp (EVar "tagged") (ELit (LString "sauth"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "effParamNode")) (EVar "params")))))
(DTypeSig false "effAtomNode" (TyFun (TyCon "EffAtomTy") (TyCon "SExp")))
(DFunDef false "effAtomNode" ((PVar "a")) (EApp (EApp (EVar "tagged") (ELit (LString "seat"))) (EListLit (EApp (EVar "SAtom") (EFieldAccess (EVar "a") "eatLabel")) (EApp (EVar "originNode") (EFieldAccess (EVar "a") "eatOrigin")) (EApp (EVar "effParamNode") (EFieldAccess (EVar "a") "eatParam")) (EApp (EVar "boolNode") (EFieldAccess (EVar "a") "eatPattern")))))
(DTypeSig false "effParamNode" (TyFun (TyCon "EffParamTy") (TyCon "SExp")))
(DFunDef false "effParamNode" ((PCon "EPTop")) (EApp (EVar "SAtom") (ELit (LString "stop"))))
(DFunDef false "effParamNode" ((PCon "EPLit" (PVar "s"))) (EApp (EApp (EVar "tagged") (ELit (LString "slit"))) (EListLit (EApp (EVar "SAtom") (EVar "s")))))
(DFunDef false "effParamNode" ((PCon "EPName" (PVar "s"))) (EApp (EApp (EVar "tagged") (ELit (LString "sname"))) (EListLit (EApp (EVar "SAtom") (EVar "s")))))
(DFunDef false "effParamNode" ((PCon "EPSet" (PVar "members"))) (EApp (EApp (EVar "tagged") (ELit (LString "sset"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "SAtom")) (EVar "members")))))
(DFunDef false "effParamNode" ((PCon "EPProduct" (PVar "axes"))) (EApp (EApp (EVar "tagged") (ELit (LString "sproduct"))) (EListLit (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "effParamNode"))) (EVar "axes")))))
(DTypeSig false "constraintNode" (TyFun (TyCon "Constraint") (TyCon "SExp")))
(DFunDef false "constraintNode" ((PVar "c")) (EApp (EApp (EVar "tagged") (ELit (LString "constraint"))) (EListLit (EApp (EVar "SAtom") (EFieldAccess (EVar "c") "constraintHead")) (EApp (EApp (EVar "listSExp") (EVar "surfaceNode")) (EFieldAccess (EVar "c") "constraintArgs")) (EApp (EVar "originNode") (EFieldAccess (EVar "c") "constraintOrigin")))))
(DTypeSig false "variantNode" (TyFun (TyCon "Variant") (TyCon "SExp")))
(DFunDef false "variantNode" ((PCon "Variant" (PVar "name") (PVar "payload"))) (EApp (EApp (EVar "tagged") (ELit (LString "variant"))) (EListLit (EApp (EVar "SAtom") (EVar "name")) (EApp (EVar "payloadNode") (EVar "payload")))))
(DTypeSig false "payloadNode" (TyFun (TyCon "ConPayload") (TyCon "SExp")))
(DFunDef false "payloadNode" ((PCon "ConPos" (PVar "tys"))) (EApp (EApp (EVar "tagged") (ELit (LString "pos"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "surfaceNode")) (EVar "tys")))))
(DFunDef false "payloadNode" ((PCon "ConNamed" (PVar "fields") (PVar "nameOmitted"))) (EApp (EApp (EVar "tagged") (ELit (LString "named"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "fieldNode")) (EVar "fields")) (EApp (EVar "boolNode") (EVar "nameOmitted")))))
(DTypeSig false "fieldNode" (TyFun (TyCon "Field") (TyCon "SExp")))
(DFunDef false "fieldNode" ((PCon "Field" (PVar "name") (PVar "t"))) (EApp (EApp (EVar "tagged") (ELit (LString "field"))) (EListLit (EApp (EVar "SAtom") (EVar "name")) (EApp (EVar "surfaceNode") (EVar "t")))))
(DTypeSig false "nsNode" (TyFun (TyCon "Ns") (TyCon "SExp")))
(DFunDef false "nsNode" ((PCon "NsType")) (EApp (EVar "SAtom") (ELit (LString "type"))))
(DFunDef false "nsNode" ((PCon "NsIface")) (EApp (EVar "SAtom") (ELit (LString "iface"))))
(DFunDef false "nsNode" ((PCon "NsMethod")) (EApp (EVar "SAtom") (ELit (LString "method"))))
(DFunDef false "nsNode" ((PCon "NsCtor")) (EApp (EVar "SAtom") (ELit (LString "ctor"))))
(DFunDef false "nsNode" ((PCon "NsField")) (EApp (EVar "SAtom") (ELit (LString "field"))))
(DFunDef false "nsNode" ((PCon "NsValue")) (EApp (EVar "SAtom") (ELit (LString "value"))))
(DTypeSig false "identNode" (TyFun (TyCon "Ident") (TyCon "SExp")))
(DFunDef false "identNode" ((PCon "Ident" (PVar "ns") (PVar "origin") (PVar "name"))) (EApp (EApp (EVar "tagged") (ELit (LString "ident"))) (EListLit (EApp (EVar "nsNode") (EVar "ns")) (EApp (EVar "originNode") (EApp (EApp (EApp (EVar "identOriginFold") (EVar "OriginBuiltin")) (EVar "OriginModule")) (EVar "origin"))) (EApp (EVar "SAtom") (EVar "name")))))
(DTypeSig false "tabKeyNode" (TyFun (TyCon "TabKey") (TyCon "SExp")))
(DFunDef false "tabKeyNode" ((PCon "TkIdent" (PVar "ident"))) (EApp (EApp (EVar "tagged") (ELit (LString "tkident"))) (EListLit (EApp (EVar "identNode") (EVar "ident")))))
(DFunDef false "tabKeyNode" ((PCon "TkBare" (PVar "ns") (PVar "name"))) (EApp (EApp (EVar "tagged") (ELit (LString "tkbare"))) (EListLit (EApp (EVar "nsNode") (EVar "ns")) (EApp (EVar "SAtom") (EVar "name")))))
(DTypeSig false "dataVisNode" (TyFun (TyCon "DataVis") (TyCon "SExp")))
(DFunDef false "dataVisNode" ((PCon "VisPrivate")) (EApp (EVar "SAtom") (ELit (LString "private"))))
(DFunDef false "dataVisNode" ((PCon "VisAbstract")) (EApp (EVar "SAtom") (ELit (LString "abstract"))))
(DFunDef false "dataVisNode" ((PCon "VisPublic")) (EApp (EVar "SAtom") (ELit (LString "public"))))
(DTypeSig false "recordNode" (TyFun (TyCon "RecordInfo") (TyCon "SExp")))
(DFunDef false "recordNode" ((PCon "RecordInfo" (PVar "ids") (PVar "authIds") (PVar "result") (PVar "fields") (PVar "index"))) (EApp (EApp (EVar "tagged") (ELit (LString "record"))) (EListLit (EApp (EVar "idsNode") (EVar "ids")) (EApp (EVar "idsNode") (EVar "authIds")) (EApp (EVar "monoNode") (EVar "result")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "monoNode"))) (EVar "fields")) (EApp (EApp (EVar "ordMapSExp") (EVar "monoNode")) (EMethodRef "index")))))
(DTypeSig false "slotNode" (TyFun (TyCon "PredicateSlot") (TyCon "SExp")))
(DFunDef false "slotNode" ((PVar "s")) (EApp (EApp (EVar "tagged") (ELit (LString "slot"))) (EListLit (EApp (EVar "ifaceNode") (EFieldAccess (EVar "s") "psIface")) (EApp (EVar "slotArgsNode") (EFieldAccess (EVar "s") "psArgs")) (EApp (EVar "idsNode") (EFieldAccess (EVar "s") "psBoundIds")))))
(DTypeSig false "slotArgsNode" (TyFun (TyCon "PredicateSlotArgs") (TyCon "SExp")))
(DFunDef false "slotArgsNode" ((PCon "PSArgsUnknown")) (EApp (EVar "SAtom") (ELit (LString "psunknown"))))
(DFunDef false "slotArgsNode" ((PCon "PSArgsKnown" (PVar "args"))) (EApp (EApp (EVar "tagged") (ELit (LString "psknown"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "monoNode")) (EVar "args")))))
(DTypeSig false "methodSlotNode" (TyFun (TyCon "MethodPredicateSlot") (TyCon "SExp")))
(DFunDef false "methodSlotNode" ((PVar "m")) (EApp (EApp (EVar "tagged") (ELit (LString "mslot"))) (EListLit (EApp (EVar "slotNode") (EFieldAccess (EVar "m") "mpsPredicate")) (EApp (EVar "idsNode") (EFieldAccess (EVar "m") "mpsPositions")))))
(DTypeSig false "prefixNode" (TyFun (TyCon "CDeclaredPrefix") (TyCon "SExp")))
(DFunDef false "prefixNode" ((PCon "CDPUnknown")) (EApp (EVar "SAtom") (ELit (LString "cdpunknown"))))
(DFunDef false "prefixNode" ((PCon "CDPLen" (PVar "n"))) (EApp (EApp (EVar "tagged") (ELit (LString "cdplen"))) (EListLit (EApp (EVar "intNode") (EVar "n")))))
(DTypeSig false "classesNode" (TyFun (TyCon "BuiltinClasses") (TyCon "SExp")))
(DFunDef false "classesNode" ((PVar "b")) (EApp (EApp (EVar "tagged") (ELit (LString "classes"))) (EListLit (EApp (EVar "originNode") (EFieldAccess (EVar "b") "bcNum")) (EApp (EVar "originNode") (EFieldAccess (EVar "b") "bcEq")) (EApp (EVar "originNode") (EFieldAccess (EVar "b") "bcOrd")) (EApp (EVar "originNode") (EFieldAccess (EVar "b") "bcSemigroup")) (EApp (EVar "boolNode") (EFieldAccess (EVar "b") "bcNumPresent")) (EApp (EVar "boolNode") (EFieldAccess (EVar "b") "bcEqPresent")) (EApp (EVar "boolNode") (EFieldAccess (EVar "b") "bcOrdPresent")) (EApp (EVar "boolNode") (EFieldAccess (EVar "b") "bcSemigroupPresent")) (EApp (EVar "boolNode") (EFieldAccess (EVar "b") "bcPreludeSeeded")))))
(DTypeSig false "popRowNode" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyTuple (TyCon "Ident") (TyCon "String") (TyVar "a")) (TyCon "SExp"))))
(DFunDef false "popRowNode" ((PVar "payload") (PTuple (PVar "ident") (PVar "owner") (PVar "p"))) (EApp (EApp (EVar "tagged") (ELit (LString "sprow"))) (EListLit (EApp (EVar "identNode") (EVar "ident")) (EApp (EVar "SAtom") (EVar "owner")) (EApp (EVar "payload") (EVar "p")))))
(DTypeSig false "zonkNamed" (TyFun (TyCon "ZState") (TyFun (TyTuple (TyCon "String") (TyCon "Mono")) (TyTuple (TyCon "ZState") (TyTuple (TyCon "String") (TyCon "Mono"))))))
(DFunDef false "zonkNamed" ((PVar "z") (PTuple (PVar "name") (PVar "m"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "m1")) (EApp (EApp (EVar "zonkMono") (EVar "z")) (EVar "m"))) (DoExpr (ETuple (EVar "z1") (ETuple (EVar "name") (EVar "m1"))))))
(DTypeSig false "zonkSlotArgs" (TyFun (TyCon "PredicateSlot") (TyCon "PredicateSlot")))
(DFunDef false "zonkSlotArgs" ((PVar "s")) (EMatch (EFieldAccess (EVar "s") "psArgs") (arm (PCon "PSArgsUnknown") () (EVar "s")) (arm (PCon "PSArgsKnown" (PVar "args")) () (ERecordUpdate (EVar "s") ((fa "psArgs" (EApp (EVar "PSArgsKnown") (EApp (EVar "snd") (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkMono")) (EVar "emptyZonk")) (EVar "args"))))))))))
(DTypeSig true "surfaceTySExp" (TyFun (TyCon "Ty") (TyCon "SExp")))
(DFunDef false "surfaceTySExp" () (EVar "surfaceNode"))
(DTypeSig true "variantSExp" (TyFun (TyCon "Variant") (TyCon "SExp")))
(DFunDef false "variantSExp" () (EVar "variantNode"))
(DTypeSig true "tabKeySExp" (TyFun (TyCon "TabKey") (TyCon "SExp")))
(DFunDef false "tabKeySExp" () (EVar "tabKeyNode"))
(DTypeSig true "dataVisSExp" (TyFun (TyCon "DataVis") (TyCon "SExp")))
(DFunDef false "dataVisSExp" () (EVar "dataVisNode"))
(DTypeSig true "recordInfoSExp" (TyFun (TyCon "RecordInfo") (TyCon "SExp")))
(DFunDef false "recordInfoSExp" ((PCon "RecordInfo" (PVar "ids") (PVar "authIds") (PVar "result") (PVar "fields") (PVar "index"))) (EBlock (DoLet false false (PTuple (PVar "z1") (PVar "result1")) (EApp (EApp (EVar "zonkMono") (EVar "emptyZonk")) (EVar "result"))) (DoLet false false (PTuple (PVar "z2") (PVar "fields1")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkNamed")) (EVar "z1")) (EVar "fields"))) (DoLet false false (PTuple PWild (PVar "index1")) (EApp (EApp (EApp (EVar "mapAccumL") (EVar "zonkNamed")) (EVar "z2")) (EApp (EVar "IdMap.entries") (EMethodRef "index")))) (DoExpr (EApp (EVar "recordNode") (EApp (EApp (EApp (EApp (EApp (EVar "RecordInfo") (EVar "ids")) (EVar "authIds")) (EVar "result1")) (EVar "fields1")) (EApp (EVar "IdMap.fromList") (EVar "index1")))))))
(DTypeSig true "predicateSlotSExp" (TyFun (TyCon "PredicateSlot") (TyCon "SExp")))
(DFunDef false "predicateSlotSExp" ((PVar "s")) (EApp (EVar "slotNode") (EApp (EVar "zonkSlotArgs") (EVar "s"))))
(DTypeSig true "methodPredicateSlotSExp" (TyFun (TyCon "MethodPredicateSlot") (TyCon "SExp")))
(DFunDef false "methodPredicateSlotSExp" ((PVar "m")) (EApp (EVar "methodSlotNode") (ERecordUpdate (EVar "m") ((fa "mpsPredicate" (EApp (EVar "zonkSlotArgs") (EFieldAccess (EVar "m") "mpsPredicate")))))))
(DTypeSig true "cDeclaredPrefixSExp" (TyFun (TyCon "CDeclaredPrefix") (TyCon "SExp")))
(DFunDef false "cDeclaredPrefixSExp" () (EVar "prefixNode"))
(DTypeSig true "builtinClassesSExp" (TyFun (TyCon "BuiltinClasses") (TyCon "SExp")))
(DFunDef false "builtinClassesSExp" () (EVar "classesNode"))
(DTypeSig true "spellingPopSExp" (TyFun (TyFun (TyVar "a") (TyCon "SExp")) (TyFun (TyApp (TyCon "SpellingPop") (TyVar "a")) (TyCon "SExp"))))
(DFunDef false "spellingPopSExp" ((PVar "payload") (PVar "pop")) (EApp (EApp (EVar "tagged") (ELit (LString "pop"))) (EListLit (EApp (EApp (EVar "ordMapSExp") (EApp (EVar "listSExp") (EApp (EVar "popRowNode") (EVar "payload")))) (EApp (EVar "spRows") (EVar "pop"))) (EApp (EApp (EVar "ordMapSExp") (EVar "payload")) (EApp (EVar "spFloor") (EVar "pop"))) (EApp (EApp (EVar "listSExp") (EVar "SAtom")) (EApp (EVar "spCollided") (EVar "pop"))))))
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
(DTypeSig false "decNamed" (TyFun (TyCon "String") (TyFun (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyVar "a"))))) (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyTuple (TyCon "String") (TyVar "a")))))))))
(DFunDef false "decNamed" (PWild (PVar "f") (PVar "z") (PVar "path") (PCon "SList" (PList (PVar "n") (PVar "x")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "/0")))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "f") (EVar "z")) (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "/1")))) (EVar "x"))) (ELam ((PTuple (PVar "z1") (PVar "v"))) (EApp (EVar "Ok") (ETuple (EVar "z1") (ETuple (EVar "name") (EVar "v")))))))))
(DFunDef false "decNamed" ((PVar "what") PWild PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (EVar "what")))
(DTypeSig false "same" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyFun (TyCon "SExp") (TyFun (TyVar "a") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))))))
(DFunDef false "same" ((PVar "path") (PVar "node") (PVar "first") (PVar "v")) (EIf (EBinOp "==" (EVar "node") (EVar "first")) (EApp (EVar "Ok") (EVar "v")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "this id was written differently before")))))
(DTypeSig false "decOpt" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "decOpt" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "optionOfSExp") (EVar "expectAtom")) (EVar "path")) (EVar "node")))
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
(DFunDef false "decParamAxis" ((PVar "path") (PVar "node")) (EApp (EApp (EMethodRef "map") (EVar "snd")) (EApp (EApp (EApp (EApp (EApp (EVar "decNamed") (ELit (LString "expected an axis (NAME PARAM)"))) (EApp (EVar "stateless") (EVar "decParam"))) (EVar "emptyZonk")) (EVar "path")) (EVar "node"))))
(DTypeSig false "authHeads" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "authHeads" () (EListLit (ETuple (ELit (LString "const")) (ELit (LInt 1))) (ETuple (ELit (LString "av")) (ELit (LInt 5))) (ETuple (ELit (LString "ajoin")) (ELit (LInt 1))) (ETuple (ELit (LString "aproduct")) (ELit (LInt 1)))))
(DTypeSig false "decAuth" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "Authority"))))))
(DFunDef false "decAuth" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "const"))) (PVar "p")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "q")) (ETuple (EVar "z") (EApp (EVar "AConst") (EVar "q"))))) (EApp (EApp (EVar "decParam") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "const"))) (ELit (LInt 1)))) (EVar "p"))))
(DFunDef false "decAuth" ((PVar "z") (PVar "path") (PAs "node" (PCon "SList" (PList (PCon "SAtom" (PLit (LString "av"))) (PVar "i") (PVar "l") (PVar "top") (PVar "pat") (PVar "name"))))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "av"))) (ELit (LInt 1)))) (EVar "i"))) (ELam ((PVar "id")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "av"))) (ELit (LInt 2)))) (EVar "l"))) (ELam ((PVar "lvl")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decParam") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "av"))) (ELit (LInt 3)))) (EVar "top"))) (ELam ((PVar "domain")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "av"))) (ELit (LInt 4)))) (EVar "pat"))) (ELam ((PVar "patterned")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decOpt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "av"))) (ELit (LInt 5)))) (EVar "name"))) (ELam ((PVar "binder")) (EMatch (EApp (EApp (EVar "IdMap.get") (EVar "id")) (EFieldAccess (EVar "z") "zAuths")) (arm (PCon "Some" (PVar "c")) () (EApp (EApp (EApp (EApp (EVar "same") (EVar "path")) (EVar "node")) (EApp (EVar "authNode") (EApp (EVar "AVar") (EVar "c")))) (ETuple (EVar "z") (EApp (EVar "AVar") (EVar "c"))))) (arm (PCon "None") () (EBlock (DoLet false false (PVar "c") (EApp (EVar "Ref") (EApp (EApp (EApp (EApp (EApp (EVar "AUnbound") (EVar "id")) (EVar "lvl")) (EVar "domain")) (EVar "patterned")) (EVar "binder")))) (DoExpr (EApp (EVar "Ok") (ETuple (ERecordUpdate (EVar "z") ((fa "zAuths" (EApp (EApp (EApp (EVar "IdMap.set") (EVar "id")) (EVar "c")) (EFieldAccess (EVar "z") "zAuths"))))) (EApp (EVar "AVar") (EVar "c")))))))))))))))))))
(DFunDef false "decAuth" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "ajoin"))) (PVar "members")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "fst") (EVar "r")) (EApp (EVar "AJoin") (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decAuth")) (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ajoin"))) (ELit (LInt 1)))) (EVar "members"))))
(DFunDef false "decAuth" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "aproduct"))) (PVar "axes")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "fst") (EVar "r")) (EApp (EVar "AProduct") (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decAuthAxis")) (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "aproduct"))) (ELit (LInt 1)))) (EVar "axes"))))
(DFunDef false "decAuth" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EVar "authHeads")) (EVar "node")))
(DTypeSig false "decAuthAxis" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyTuple (TyCon "String") (TyCon "Authority")))))))
(DFunDef false "decAuthAxis" () (EApp (EApp (EVar "decNamed") (ELit (LString "expected an axis (NAME AUTH)"))) (EVar "decAuth")))
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
(DTypeAlias false "Reader" ("a") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a")))))
(DTypeSig true "nested" (TyFun (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyVar "a"))) (TyApp (TyCon "Reader") (TyVar "a"))))
(DFunDef false "nested" ((PVar "dec") (PVar "path") (PVar "node")) (EApp (EApp (EVar "mapErr") (ELam ((PVar "e")) (ERecordUpdate (EVar "e") ((fa "sePath" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EFieldAccess (EVar "e") "sePath"))) (ELit (LString "")))))))) (EApp (EVar "dec") (EVar "node"))))
(DTypeSig true "listOfSExp" (TyFun (TyApp (TyCon "Reader") (TyVar "a")) (TyApp (TyCon "Reader") (TyApp (TyCon "List") (TyVar "a")))))
(DFunDef false "listOfSExp" ((PVar "item") (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "decList") (EVar "item")) (EVar "path")) (EVar "node")))
(DTypeSig true "pairOfSExp" (TyFun (TyApp (TyCon "Reader") (TyVar "a")) (TyFun (TyApp (TyCon "Reader") (TyVar "b")) (TyApp (TyCon "Reader") (TyTuple (TyVar "a") (TyVar "b"))))))
(DFunDef false "pairOfSExp" ((PVar "first") (PVar "second") (PVar "path") (PCon "SList" (PList (PVar "a") (PVar "b")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "first") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "/0")))) (EVar "a"))) (ELam ((PVar "x")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "second") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "/1")))) (EVar "b"))) (ELam ((PVar "y")) (EApp (EVar "Ok") (ETuple (EVar "x") (EVar "y"))))))))
(DFunDef false "pairOfSExp" (PWild PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "expected a pair"))))
(DTypeSig true "tripleOfSExp" (TyFun (TyApp (TyCon "Reader") (TyVar "a")) (TyFun (TyApp (TyCon "Reader") (TyVar "b")) (TyFun (TyApp (TyCon "Reader") (TyVar "c")) (TyApp (TyCon "Reader") (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")))))))
(DFunDef false "tripleOfSExp" ((PVar "first") (PVar "second") (PVar "third") (PVar "path") (PCon "SList" (PList (PVar "a") (PVar "b") (PVar "c")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "first") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "/0")))) (EVar "a"))) (ELam ((PVar "x")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "second") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "/1")))) (EVar "b"))) (ELam ((PVar "y")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "third") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "path"))) (ELit (LString "/2")))) (EVar "c"))) (ELam ((PVar "w")) (EApp (EVar "Ok") (ETuple (EVar "x") (EVar "y") (EVar "w"))))))))))
(DFunDef false "tripleOfSExp" (PWild PWild PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "expected a triple"))))
(DTypeSig true "optionOfSExp" (TyFun (TyApp (TyCon "Reader") (TyVar "a")) (TyApp (TyCon "Reader") (TyApp (TyCon "Option") (TyVar "a")))))
(DFunDef false "optionOfSExp" (PWild PWild (PCon "SAtom" (PLit (LString "none")))) (EApp (EVar "Ok") (EVar "None")))
(DFunDef false "optionOfSExp" ((PVar "item") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "some"))) (PVar "x")))) (EApp (EApp (EMethodRef "map") (EVar "Some")) (EApp (EApp (EVar "item") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "some"))) (ELit (LInt 1)))) (EVar "x"))))
(DFunDef false "optionOfSExp" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "none")) (ELit (LInt 0))) (ETuple (ELit (LString "some")) (ELit (LInt 1))))) (EVar "node")))
(DTypeSig true "unitOfSExp" (TyApp (TyCon "Reader") (TyCon "Unit")))
(DFunDef false "unitOfSExp" (PWild (PCon "SList" (PList))) (EApp (EVar "Ok") (ELit LUnit)))
(DFunDef false "unitOfSExp" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "expected ()"))))
(DTypeSig false "ascending" (TyConstrained ((cstr "Ord" (TyVar "a"))) (TyFun (TyApp (TyCon "List") (TyVar "a")) (TyCon "Bool"))))
(DFunDef false "ascending" ((PCons (PVar "a") (PAs "rest" (PCons (PVar "b") PWild)))) (EBinOp "&&" (EBinOp "<" (EVar "a") (EVar "b")) (EApp (EDictApp "ascending") (EVar "rest"))))
(DFunDef false "ascending" (PWild) (EVar "True"))
(DTypeSig false "keyed" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyFun (TyApp (TyCon "List") (TyTuple (TyVar "k") (TyVar "v"))) (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v"))))))))
(DFunDef false "keyed" ((PVar "path") (PVar "node") (PVar "pairs")) (EIf (EApp (EDictApp "ascending") (EApp (EApp (EMethodRef "map") (EVar "fst")) (EVar "pairs"))) (EApp (EVar "Ok") (EApp (EVar "IdMap.fromList") (EVar "pairs"))) (EApp (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "node")) (ELit (LString "keys must ascend strictly")))))
(DTypeSig false "decMap" (TyConstrained ((cstr "Ord" (TyVar "k"))) (TyFun (TyApp (TyCon "Reader") (TyVar "k")) (TyFun (TyApp (TyCon "Reader") (TyVar "v")) (TyApp (TyCon "Reader") (TyApp (TyApp (TyCon "Map") (TyVar "k")) (TyVar "v")))))))
(DFunDef false "decMap" ((PVar "key") (PVar "value") (PVar "path") (PVar "node")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decList") (EApp (EApp (EVar "pairOfSExp") (EVar "key")) (EVar "value"))) (EVar "path")) (EVar "node"))) (ELam ((PVar "pairs")) (EApp (EApp (EApp (EDictApp "keyed") (EVar "path")) (EVar "node")) (EVar "pairs")))))
(DTypeSig true "ordMapOfSExp" (TyFun (TyApp (TyCon "Reader") (TyVar "a")) (TyApp (TyCon "Reader") (TyApp (TyCon "OrdMap") (TyVar "a")))))
(DFunDef false "ordMapOfSExp" ((PVar "value") (PVar "path") (PVar "node")) (EApp (EApp (EApp (EApp (EDictApp "decMap") (EVar "expectAtom")) (EVar "value")) (EVar "path")) (EVar "node")))
(DTypeSig true "intMapOfSExp" (TyFun (TyApp (TyCon "Reader") (TyVar "a")) (TyApp (TyCon "Reader") (TyApp (TyApp (TyCon "Map") (TyCon "Int")) (TyVar "a")))))
(DFunDef false "intMapOfSExp" ((PVar "value") (PVar "path") (PVar "node")) (EApp (EApp (EApp (EApp (EDictApp "decMap") (EVar "atomInt")) (EVar "value")) (EVar "path")) (EVar "node")))
(DTypeSig false "surfaceHeads" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "surfaceHeads" () (EListLit (ETuple (ELit (LString "scon")) (ELit (LInt 2))) (ETuple (ELit (LString "svar")) (ELit (LInt 1))) (ETuple (ELit (LString "sapp")) (ELit (LInt 2))) (ETuple (ELit (LString "sfun")) (ELit (LInt 2))) (ETuple (ELit (LString "stuple")) (ELit (LInt 1))) (ETuple (ELit (LString "seffect")) (ELit (LInt 3))) (ETuple (ELit (LString "sconstrained")) (ELit (LInt 2))) (ETuple (ELit (LString "snamed")) (ELit (LInt 3))) (ETuple (ELit (LString "squal")) (ELit (LInt 2))) (ETuple (ELit (LString "srow")) (ELit (LInt 2))) (ETuple (ELit (LString "sauth")) (ELit (LInt 1)))))
(DTypeSig false "decSurface" (TyApp (TyCon "Reader") (TyCon "Ty")))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "scon"))) (PVar "n") (PVar "o")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "scon"))) (ELit (LInt 1)))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "scon"))) (ELit (LInt 2)))) (EVar "o"))) (ELam ((PVar "origin")) (EApp (EVar "Ok") (ERecordCreate "TyCon" ((fa "tyConName" (EVar "name")) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "origin"))))))))))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "svar"))) (PVar "n")))) (EApp (EApp (EMethodRef "map") (EVar "TyVar")) (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "svar"))) (ELit (LInt 1)))) (EVar "n"))))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sapp"))) (PVar "f") (PVar "a")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decSurface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sapp"))) (ELit (LInt 1)))) (EVar "f"))) (ELam ((PVar "f1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decSurface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sapp"))) (ELit (LInt 2)))) (EVar "a"))) (ELam ((PVar "a1")) (EApp (EVar "Ok") (EApp (EApp (EVar "TyApp") (EVar "f1")) (EVar "a1"))))))))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sfun"))) (PVar "a") (PVar "b")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decSurface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sfun"))) (ELit (LInt 1)))) (EVar "a"))) (ELam ((PVar "a1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decSurface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sfun"))) (ELit (LInt 2)))) (EVar "b"))) (ELam ((PVar "b1")) (EApp (EVar "Ok") (EApp (EApp (EVar "TyFun") (EVar "a1")) (EVar "b1"))))))))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "stuple"))) (PVar "tys")))) (EApp (EApp (EMethodRef "map") (EVar "TyTuple")) (EApp (EApp (EApp (EVar "decList") (EVar "decSurface")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "stuple"))) (ELit (LInt 1)))) (EVar "tys"))))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "seffect"))) (PVar "atoms") (PVar "tails") (PVar "t")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "decEffAtom")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "seffect"))) (ELit (LInt 1)))) (EVar "atoms"))) (ELam ((PVar "atoms1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "expectAtom")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "seffect"))) (ELit (LInt 2)))) (EVar "tails"))) (ELam ((PVar "tails1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decSurface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "seffect"))) (ELit (LInt 3)))) (EVar "t"))) (ELam ((PVar "t1")) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "TyEffect") (EVar "atoms1")) (EVar "tails1")) (EVar "t1"))))))))))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sconstrained"))) (PVar "cs") (PVar "t")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "decConstraint")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sconstrained"))) (ELit (LInt 1)))) (EVar "cs"))) (ELam ((PVar "cs1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decSurface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sconstrained"))) (ELit (LInt 2)))) (EVar "t"))) (ELam ((PVar "t1")) (EApp (EVar "Ok") (EApp (EApp (EVar "TyConstrained") (EVar "cs1")) (EVar "t1"))))))))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "snamed"))) (PVar "n") (PVar "t") (PVar "d")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "snamed"))) (ELit (LInt 1)))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decSurface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "snamed"))) (ELit (LInt 2)))) (EVar "t"))) (ELam ((PVar "t1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "optionOfSExp") (EVar "decEffAtom")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "snamed"))) (ELit (LInt 3)))) (EVar "d"))) (ELam ((PVar "domain")) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "TyNamed") (EVar "name")) (EVar "t1")) (EVar "domain"))))))))))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "squal"))) (PVar "t") (PVar "ps")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decSurface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "squal"))) (ELit (LInt 1)))) (EVar "t"))) (ELam ((PVar "t1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "decEffParam")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "squal"))) (ELit (LInt 2)))) (EVar "ps"))) (ELam ((PVar "ps1")) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "TyQual") (EVar "t1")) (EVar "ps1")) (EVar "None"))))))))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "srow"))) (PVar "atoms") (PVar "tails")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "decEffAtom")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "srow"))) (ELit (LInt 1)))) (EVar "atoms"))) (ELam ((PVar "atoms1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "expectAtom")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "srow"))) (ELit (LInt 2)))) (EVar "tails"))) (ELam ((PVar "tails1")) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "TyRow") (EVar "atoms1")) (EVar "tails1")) (EVar "None"))))))))
(DFunDef false "decSurface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sauth"))) (PVar "ps")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "ps1")) (EApp (EApp (EVar "TyAuth") (EVar "ps1")) (EVar "None")))) (EApp (EApp (EApp (EVar "decList") (EVar "decEffParam")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sauth"))) (ELit (LInt 1)))) (EVar "ps"))))
(DFunDef false "decSurface" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EVar "surfaceHeads")) (EVar "node")))
(DTypeSig false "decEffAtom" (TyApp (TyCon "Reader") (TyCon "EffAtomTy")))
(DFunDef false "decEffAtom" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "seat"))) (PVar "l") (PVar "o") (PVar "p") (PVar "pat")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "seat"))) (ELit (LInt 1)))) (EVar "l"))) (ELam ((PVar "label")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "seat"))) (ELit (LInt 2)))) (EVar "o"))) (ELam ((PVar "origin")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decEffParam") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "seat"))) (ELit (LInt 3)))) (EVar "p"))) (ELam ((PVar "param")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "seat"))) (ELit (LInt 4)))) (EVar "pat"))) (ELam ((PVar "patterned")) (EApp (EVar "Ok") (ERecordCreate "EffAtomTy" ((fa "eatLabel" (EVar "label")) (fa "eatOrigin" (EVar "origin")) (fa "eatParam" (EVar "param")) (fa "eatLoc" (EVar "None")) (fa "eatPattern" (EVar "patterned"))))))))))))))
(DFunDef false "decEffAtom" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "seat")) (ELit (LInt 4))))) (EVar "node")))
(DTypeSig false "effParamHeads" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "effParamHeads" () (EListLit (ETuple (ELit (LString "stop")) (ELit (LInt 0))) (ETuple (ELit (LString "slit")) (ELit (LInt 1))) (ETuple (ELit (LString "sname")) (ELit (LInt 1))) (ETuple (ELit (LString "sset")) (ELit (LInt 1))) (ETuple (ELit (LString "sproduct")) (ELit (LInt 1)))))
(DTypeSig false "decEffParam" (TyApp (TyCon "Reader") (TyCon "EffParamTy")))
(DFunDef false "decEffParam" (PWild (PCon "SAtom" (PLit (LString "stop")))) (EApp (EVar "Ok") (EVar "EPTop")))
(DFunDef false "decEffParam" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "slit"))) (PVar "s")))) (EApp (EApp (EMethodRef "map") (EVar "EPLit")) (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "slit"))) (ELit (LInt 1)))) (EVar "s"))))
(DFunDef false "decEffParam" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sname"))) (PVar "s")))) (EApp (EApp (EMethodRef "map") (EVar "EPName")) (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sname"))) (ELit (LInt 1)))) (EVar "s"))))
(DFunDef false "decEffParam" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sset"))) (PVar "members")))) (EApp (EApp (EMethodRef "map") (EVar "EPSet")) (EApp (EApp (EApp (EVar "decList") (EVar "expectAtom")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sset"))) (ELit (LInt 1)))) (EVar "members"))))
(DFunDef false "decEffParam" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sproduct"))) (PVar "axes")))) (EApp (EApp (EMethodRef "map") (EVar "EPProduct")) (EApp (EApp (EApp (EVar "decList") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EVar "decEffParam"))) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sproduct"))) (ELit (LInt 1)))) (EVar "axes"))))
(DFunDef false "decEffParam" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EVar "effParamHeads")) (EVar "node")))
(DTypeSig false "decConstraint" (TyApp (TyCon "Reader") (TyCon "Constraint")))
(DFunDef false "decConstraint" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "constraint"))) (PVar "h") (PVar "args") (PVar "o")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "constraint"))) (ELit (LInt 1)))) (EVar "h"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "decSurface")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "constraint"))) (ELit (LInt 2)))) (EVar "args"))) (ELam ((PVar "args1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "constraint"))) (ELit (LInt 3)))) (EVar "o"))) (ELam ((PVar "origin")) (EApp (EVar "Ok") (ERecordCreate "Constraint" ((fa "constraintHead" (EVar "name")) (fa "constraintArgs" (EVar "args1")) (fa "constraintOrigin" (EVar "origin"))))))))))))
(DFunDef false "decConstraint" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "constraint")) (ELit (LInt 3))))) (EVar "node")))
(DTypeSig false "decVariant" (TyApp (TyCon "Reader") (TyCon "Variant")))
(DFunDef false "decVariant" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "variant"))) (PVar "n") (PVar "p")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "variant"))) (ELit (LInt 1)))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decPayload") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "variant"))) (ELit (LInt 2)))) (EVar "p"))) (ELam ((PVar "payload")) (EApp (EVar "Ok") (EApp (EApp (EVar "Variant") (EVar "name")) (EVar "payload"))))))))
(DFunDef false "decVariant" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "variant")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "decPayload" (TyApp (TyCon "Reader") (TyCon "ConPayload")))
(DFunDef false "decPayload" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "pos"))) (PVar "tys")))) (EApp (EApp (EMethodRef "map") (EVar "ConPos")) (EApp (EApp (EApp (EVar "decList") (EVar "decSurface")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "pos"))) (ELit (LInt 1)))) (EVar "tys"))))
(DFunDef false "decPayload" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "named"))) (PVar "fs") (PVar "omitted")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "decField")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "named"))) (ELit (LInt 1)))) (EVar "fs"))) (ELam ((PVar "fields")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "named"))) (ELit (LInt 2)))) (EVar "omitted"))) (ELam ((PVar "nameOmitted")) (EApp (EVar "Ok") (EApp (EApp (EVar "ConNamed") (EVar "fields")) (EVar "nameOmitted"))))))))
(DFunDef false "decPayload" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "pos")) (ELit (LInt 1))) (ETuple (ELit (LString "named")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "decField" (TyApp (TyCon "Reader") (TyCon "Field")))
(DFunDef false "decField" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "field"))) (PVar "n") (PVar "t")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "field"))) (ELit (LInt 1)))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decSurface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "field"))) (ELit (LInt 2)))) (EVar "t"))) (ELam ((PVar "t1")) (EApp (EVar "Ok") (EApp (EApp (EVar "Field") (EVar "name")) (EVar "t1"))))))))
(DFunDef false "decField" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "field")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "nsHeads" (TyApp (TyCon "List") (TyTuple (TyCon "String") (TyCon "Int"))))
(DFunDef false "nsHeads" () (EListLit (ETuple (ELit (LString "type")) (ELit (LInt 0))) (ETuple (ELit (LString "iface")) (ELit (LInt 0))) (ETuple (ELit (LString "method")) (ELit (LInt 0))) (ETuple (ELit (LString "ctor")) (ELit (LInt 0))) (ETuple (ELit (LString "field")) (ELit (LInt 0))) (ETuple (ELit (LString "value")) (ELit (LInt 0)))))
(DTypeSig false "decNs" (TyApp (TyCon "Reader") (TyCon "Ns")))
(DFunDef false "decNs" (PWild (PCon "SAtom" (PLit (LString "type")))) (EApp (EVar "Ok") (EVar "NsType")))
(DFunDef false "decNs" (PWild (PCon "SAtom" (PLit (LString "iface")))) (EApp (EVar "Ok") (EVar "NsIface")))
(DFunDef false "decNs" (PWild (PCon "SAtom" (PLit (LString "method")))) (EApp (EVar "Ok") (EVar "NsMethod")))
(DFunDef false "decNs" (PWild (PCon "SAtom" (PLit (LString "ctor")))) (EApp (EVar "Ok") (EVar "NsCtor")))
(DFunDef false "decNs" (PWild (PCon "SAtom" (PLit (LString "field")))) (EApp (EVar "Ok") (EVar "NsField")))
(DFunDef false "decNs" (PWild (PCon "SAtom" (PLit (LString "value")))) (EApp (EVar "Ok") (EVar "NsValue")))
(DFunDef false "decNs" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EVar "nsHeads")) (EVar "node")))
(DTypeSig false "decIdent" (TyApp (TyCon "Reader") (TyCon "Ident")))
(DFunDef false "decIdent" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "ident"))) (PVar "ns") (PVar "o") (PVar "n")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decNs") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ident"))) (ELit (LInt 1)))) (EVar "ns"))) (ELam ((PVar "ns1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ident"))) (ELit (LInt 2)))) (EVar "o"))) (ELam ((PVar "origin")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ident"))) (ELit (LInt 3)))) (EVar "n"))) (ELam ((PVar "name")) (EMatch (EApp (EApp (EApp (EVar "mkIdent") (EVar "ns1")) (EVar "origin")) (EVar "name")) (arm (PCon "Some" (PVar "ident")) () (EApp (EVar "Ok") (EVar "ident"))) (arm (PCon "None") () (EApp (EApp (EApp (EVar "refuse") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "ident"))) (ELit (LInt 2)))) (EVar "o")) (ELit (LString "an identity names a module or builtin"))))))))))))
(DFunDef false "decIdent" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "ident")) (ELit (LInt 3))))) (EVar "node")))
(DTypeSig false "decTabKey" (TyApp (TyCon "Reader") (TyCon "TabKey")))
(DFunDef false "decTabKey" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "tkident"))) (PVar "i")))) (EApp (EApp (EMethodRef "map") (EVar "TkIdent")) (EApp (EApp (EVar "decIdent") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tkident"))) (ELit (LInt 1)))) (EVar "i"))))
(DFunDef false "decTabKey" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "tkbare"))) (PVar "ns") (PVar "n")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decNs") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tkbare"))) (ELit (LInt 1)))) (EVar "ns"))) (ELam ((PVar "ns1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "tkbare"))) (ELit (LInt 2)))) (EVar "n"))) (ELam ((PVar "name")) (EApp (EVar "Ok") (EApp (EApp (EVar "TkBare") (EVar "ns1")) (EVar "name"))))))))
(DFunDef false "decTabKey" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "tkident")) (ELit (LInt 1))) (ETuple (ELit (LString "tkbare")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "decDataVis" (TyApp (TyCon "Reader") (TyCon "DataVis")))
(DFunDef false "decDataVis" (PWild (PCon "SAtom" (PLit (LString "private")))) (EApp (EVar "Ok") (EVar "VisPrivate")))
(DFunDef false "decDataVis" (PWild (PCon "SAtom" (PLit (LString "abstract")))) (EApp (EVar "Ok") (EVar "VisAbstract")))
(DFunDef false "decDataVis" (PWild (PCon "SAtom" (PLit (LString "public")))) (EApp (EVar "Ok") (EVar "VisPublic")))
(DFunDef false "decDataVis" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "private")) (ELit (LInt 0))) (ETuple (ELit (LString "abstract")) (ELit (LInt 0))) (ETuple (ELit (LString "public")) (ELit (LInt 0))))) (EVar "node")))
(DTypeSig false "decNamedMono" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyTuple (TyCon "String") (TyCon "Mono")))))))
(DFunDef false "decNamedMono" () (EApp (EApp (EVar "decNamed") (ELit (LString "expected a pair (NAME MONO)"))) (EVar "decMono")))
(DTypeSig false "decRecord" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "RecordInfo"))))))
(DFunDef false "decRecord" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "record"))) (PVar "ids") (PVar "authIds") (PVar "r") (PVar "fs") (PVar "ix")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "atomInt")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "record"))) (ELit (LInt 1)))) (EVar "ids"))) (ELam ((PVar "ids1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "atomInt")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "record"))) (ELit (LInt 2)))) (EVar "authIds"))) (ELam ((PVar "authIds1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decMono") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "record"))) (ELit (LInt 3)))) (EVar "r"))) (ELam ((PTuple (PVar "z1") (PVar "result"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decNamedMono")) (EVar "z1")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "record"))) (ELit (LInt 4)))) (EVar "fs"))) (ELam ((PTuple (PVar "z2") (PVar "fields"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decNamedMono")) (EVar "z2")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "record"))) (ELit (LInt 5)))) (EVar "ix"))) (ELam ((PTuple (PVar "z3") (PVar "pairs"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EDictApp "keyed") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "record"))) (ELit (LInt 5)))) (EVar "ix")) (EVar "pairs"))) (ELam ((PVar "index")) (EApp (EVar "Ok") (ETuple (EVar "z3") (EApp (EApp (EApp (EApp (EApp (EVar "RecordInfo") (EVar "ids1")) (EVar "authIds1")) (EVar "result")) (EVar "fields")) (EMethodRef "index")))))))))))))))))
(DFunDef false "decRecord" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "record")) (ELit (LInt 5))))) (EVar "node")))
(DTypeSig false "decSlotArgs" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "PredicateSlotArgs"))))))
(DFunDef false "decSlotArgs" ((PVar "z") PWild (PCon "SAtom" (PLit (LString "psunknown")))) (EApp (EVar "Ok") (ETuple (EVar "z") (EVar "PSArgsUnknown"))))
(DFunDef false "decSlotArgs" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "psknown"))) (PVar "args")))) (EApp (EApp (EMethodRef "map") (ELam ((PVar "r")) (ETuple (EApp (EVar "fst") (EVar "r")) (EApp (EVar "PSArgsKnown") (EApp (EVar "snd") (EVar "r")))))) (EApp (EApp (EApp (EApp (EVar "decEach") (EVar "decMono")) (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "psknown"))) (ELit (LInt 1)))) (EVar "args"))))
(DFunDef false "decSlotArgs" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "psunknown")) (ELit (LInt 0))) (ETuple (ELit (LString "psknown")) (ELit (LInt 1))))) (EVar "node")))
(DTypeSig false "decSlot" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "PredicateSlot"))))))
(DFunDef false "decSlot" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "slot"))) (PVar "i") (PVar "a") (PVar "ids")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decIface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "slot"))) (ELit (LInt 1)))) (EVar "i"))) (ELam ((PVar "iface")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decSlotArgs") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "slot"))) (ELit (LInt 2)))) (EVar "a"))) (ELam ((PTuple (PVar "z1") (PVar "args"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "atomInt")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "slot"))) (ELit (LInt 3)))) (EVar "ids"))) (ELam ((PVar "ids1")) (EApp (EVar "Ok") (ETuple (EVar "z1") (ERecordCreate "PredicateSlot" ((fa "psIface" (EVar "iface")) (fa "psArgs" (EVar "args")) (fa "psBoundIds" (EVar "ids1")))))))))))))
(DFunDef false "decSlot" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "slot")) (ELit (LInt 3))))) (EVar "node")))
(DTypeSig false "decMethodSlot" (TyFun (TyCon "ZState") (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyCon "Dec") (TyCon "MethodPredicateSlot"))))))
(DFunDef false "decMethodSlot" ((PVar "z") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "mslot"))) (PVar "s") (PVar "ps")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decSlot") (EVar "z")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "mslot"))) (ELit (LInt 1)))) (EVar "s"))) (ELam ((PTuple (PVar "z1") (PVar "slot"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "atomInt")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "mslot"))) (ELit (LInt 2)))) (EVar "ps"))) (ELam ((PVar "positions")) (EApp (EVar "Ok") (ETuple (EVar "z1") (ERecordCreate "MethodPredicateSlot" ((fa "mpsPredicate" (EVar "slot")) (fa "mpsPositions" (EVar "positions")))))))))))
(DFunDef false "decMethodSlot" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "mslot")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "decPrefix" (TyApp (TyCon "Reader") (TyCon "CDeclaredPrefix")))
(DFunDef false "decPrefix" (PWild (PCon "SAtom" (PLit (LString "cdpunknown")))) (EApp (EVar "Ok") (EVar "CDPUnknown")))
(DFunDef false "decPrefix" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "cdplen"))) (PVar "n")))) (EApp (EApp (EMethodRef "map") (EVar "CDPLen")) (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "cdplen"))) (ELit (LInt 1)))) (EVar "n"))))
(DFunDef false "decPrefix" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "cdpunknown")) (ELit (LInt 0))) (ETuple (ELit (LString "cdplen")) (ELit (LInt 1))))) (EVar "node")))
(DTypeSig false "decClasses" (TyApp (TyCon "Reader") (TyCon "BuiltinClasses")))
(DFunDef false "decClasses" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "classes"))) (PVar "num") (PVar "eq") (PVar "ord") (PVar "semi") (PVar "numP") (PVar "eqP") (PVar "ordP") (PVar "semiP") (PVar "seeded")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "classes"))) (ELit (LInt 1)))) (EVar "num"))) (ELam ((PVar "numO")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "classes"))) (ELit (LInt 2)))) (EMethodRef "eq"))) (ELam ((PVar "eqO")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "classes"))) (ELit (LInt 3)))) (EVar "ord"))) (ELam ((PVar "ordO")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decOrigin") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "classes"))) (ELit (LInt 4)))) (EVar "semi"))) (ELam ((PVar "semiO")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "classes"))) (ELit (LInt 5)))) (EVar "numP"))) (ELam ((PVar "numB")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "classes"))) (ELit (LInt 6)))) (EVar "eqP"))) (ELam ((PVar "eqB")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "classes"))) (ELit (LInt 7)))) (EVar "ordP"))) (ELam ((PVar "ordB")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "classes"))) (ELit (LInt 8)))) (EVar "semiP"))) (ELam ((PVar "semiB")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomBool") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "classes"))) (ELit (LInt 9)))) (EVar "seeded"))) (ELam ((PVar "seededB")) (EApp (EVar "Ok") (ERecordCreate "BuiltinClasses" ((fa "bcNum" (EVar "numO")) (fa "bcEq" (EVar "eqO")) (fa "bcOrd" (EVar "ordO")) (fa "bcSemigroup" (EVar "semiO")) (fa "bcNumPresent" (EVar "numB")) (fa "bcEqPresent" (EVar "eqB")) (fa "bcOrdPresent" (EVar "ordB")) (fa "bcSemigroupPresent" (EVar "semiB")) (fa "bcPreludeSeeded" (EVar "seededB"))))))))))))))))))))))))
(DFunDef false "decClasses" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "classes")) (ELit (LInt 9))))) (EVar "node")))
(DTypeSig false "decPopRow" (TyFun (TyApp (TyCon "Reader") (TyVar "a")) (TyApp (TyCon "Reader") (TyTuple (TyCon "Ident") (TyCon "String") (TyVar "a")))))
(DFunDef false "decPopRow" ((PVar "payload") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sprow"))) (PVar "i") (PVar "o") (PVar "p")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decIdent") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sprow"))) (ELit (LInt 1)))) (EVar "i"))) (ELam ((PVar "ident")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sprow"))) (ELit (LInt 2)))) (EVar "o"))) (ELam ((PVar "owner")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "payload") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sprow"))) (ELit (LInt 3)))) (EVar "p"))) (ELam ((PVar "p1")) (EApp (EVar "Ok") (ETuple (EVar "ident") (EVar "owner") (EVar "p1"))))))))))
(DFunDef false "decPopRow" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "sprow")) (ELit (LInt 3))))) (EVar "node")))
(DTypeSig true "spellingPopOfSExp" (TyFun (TyApp (TyCon "Reader") (TyVar "a")) (TyApp (TyCon "Reader") (TyApp (TyCon "SpellingPop") (TyVar "a")))))
(DFunDef false "spellingPopOfSExp" ((PVar "payload") (PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "pop"))) (PVar "rows") (PVar "floor") (PVar "collided")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "ordMapOfSExp") (EApp (EVar "decList") (EApp (EVar "decPopRow") (EVar "payload")))) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "pop"))) (ELit (LInt 1)))) (EVar "rows"))) (ELam ((PVar "rows1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "ordMapOfSExp") (EVar "payload")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "pop"))) (ELit (LInt 2)))) (EVar "floor"))) (ELam ((PVar "floor1")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "expectAtom")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "pop"))) (ELit (LInt 3)))) (EVar "collided"))) (ELam ((PVar "collided1")) (EApp (EVar "Ok") (EApp (EApp (EApp (EVar "spFromProjections") (EVar "rows1")) (EVar "floor1")) (EVar "collided1"))))))))))
(DFunDef false "spellingPopOfSExp" (PWild (PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "pop")) (ELit (LInt 3))))) (EVar "node")))
(DTypeSig true "surfaceTyOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Ty"))))
(DFunDef false "surfaceTyOfSExp" () (EApp (EVar "decSurface") (ELit (LString "ty"))))
(DTypeSig true "variantOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Variant"))))
(DFunDef false "variantOfSExp" () (EApp (EVar "decVariant") (ELit (LString "variant"))))
(DTypeSig true "tabKeyOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "TabKey"))))
(DFunDef false "tabKeyOfSExp" () (EApp (EVar "decTabKey") (ELit (LString "tabkey"))))
(DTypeSig true "dataVisOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "DataVis"))))
(DFunDef false "dataVisOfSExp" () (EApp (EVar "decDataVis") (ELit (LString "vis"))))
(DTypeSig true "recordInfoOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "RecordInfo"))))
(DFunDef false "recordInfoOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decRecord")) (ELit (LString "record"))))
(DTypeSig true "predicateSlotOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "PredicateSlot"))))
(DFunDef false "predicateSlotOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decSlot")) (ELit (LString "slot"))))
(DTypeSig true "methodPredicateSlotOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "MethodPredicateSlot"))))
(DFunDef false "methodPredicateSlotOfSExp" () (EApp (EApp (EVar "rooted") (EVar "decMethodSlot")) (ELit (LString "mslot"))))
(DTypeSig true "cDeclaredPrefixOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "CDeclaredPrefix"))))
(DFunDef false "cDeclaredPrefixOfSExp" () (EApp (EVar "decPrefix") (ELit (LString "prefix"))))
(DTypeSig true "builtinClassesOfSExp" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "BuiltinClasses"))))
(DFunDef false "builtinClassesOfSExp" () (EApp (EVar "decClasses") (ELit (LString "classes"))))
(DData Public "InterfaceSection" () ((variant "InterfaceSection" (ConNamed (field "isJoins" (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))) (field "isInterface" (TyCon "PreludeInterface"))))) ())
(DData Public "PreludeInterfaceFile" () ((variant "PreludeInterfaceFile" (ConNamed (field "ifKey" (TyCon "InterfaceKey")) (field "ifSections" (TyApp (TyCon "List") (TyCon "InterfaceSection")))))) ())
(DTypeSig true "formatVersion" (TyCon "Int"))
(DFunDef false "formatVersion" () (ELit (LInt 2)))
(DTypeSig true "sectionsOfCache" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyCon "PreludeInterface"))) (TyApp (TyCon "List") (TyCon "InterfaceSection"))))
(DFunDef false "sectionsOfCache" () (EApp (EMethodRef "map") (ELam ((PVar "s")) (ERecordCreate "InterfaceSection" ((fa "isJoins" (EApp (EVar "fst") (EVar "s"))) (fa "isInterface" (EApp (EVar "snd") (EVar "s"))))))))
(DTypeSig true "cacheOfSections" (TyFun (TyApp (TyCon "List") (TyCon "InterfaceSection")) (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyCon "PreludeInterface")))))
(DFunDef false "cacheOfSections" () (EApp (EMethodRef "map") (ELam ((PVar "s")) (ETuple (EFieldAccess (EVar "s") "isJoins") (EFieldAccess (EVar "s") "isInterface")))))
(DTypeSig true "mergeSections" (TyFun (TyApp (TyCon "List") (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "PreludeInterface"))) (TyApp (TyCon "List") (TyCon "InterfaceSection"))))
(DFunDef false "mergeSections" ((PVar "drives")) (EBlock (DoLet false false (PVar "keyed") (EApp (EApp (EMethodRef "map") (ELam ((PVar "d")) (ETuple (EApp (EVar "renderSExp") (EApp (EVar "interfaceNode") (EApp (EVar "snd") (EVar "d")))) (EVar "d")))) (EVar "drives"))) (DoLet false false (PVar "joinsByText") (EApp (EApp (EApp (EMethodRef "fold") (EVar "addJoin")) (EVar "omEmpty")) (EDictApp "keyed"))) (DoExpr (EApp (EApp (EMethodRef "map") (ELam ((PVar "k")) (ERecordCreate "InterfaceSection" ((fa "isJoins" (EApp (EVar "sortedJoins") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EApp (EVar "fst") (EVar "k"))) (EVar "joinsByText"))))) (fa "isInterface" (EApp (EVar "snd") (EApp (EVar "snd") (EVar "k")))))))) (EApp (EApp (EVar "dedupBy") (EVar "fst")) (EDictApp "keyed"))))))
(DTypeSig false "addJoin" (TyFun (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))) (TyFun (TyTuple (TyCon "String") (TyTuple (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "PreludeInterface"))) (TyApp (TyCon "OrdMap") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))))))
(DFunDef false "addJoin" ((PVar "acc") (PTuple (PVar "text") (PTuple (PVar "join") PWild))) (EApp (EApp (EApp (EVar "omInsert") (EVar "text")) (EBinOp "::" (EVar "join") (EApp (EApp (EVar "optionOr") (EListLit)) (EApp (EApp (EVar "omLookup") (EVar "text")) (EVar "acc"))))) (EVar "acc")))
(DTypeSig false "sortedJoins" (TyFun (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom"))) (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "sortedJoins" ((PVar "joins")) (EApp (EApp (EVar "dedupBy") (EVar "joinText")) (EApp (EApp (EVar "sortOn") (EVar "joinText")) (EVar "joins"))))
(DTypeSig false "joinText" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "String")))
(DFunDef false "joinText" ((PVar "j")) (EApp (EVar "renderSExp") (EApp (EVar "joinNode") (EVar "j"))))
(DTypeSig false "pairAtoms" (TyFun (TyTuple (TyCon "String") (TyCon "String")) (TyCon "SExp")))
(DFunDef false "pairAtoms" () (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "SAtom")))
(DTypeSig true "sha256Hex" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "sha256Hex" ((PVar "text")) (EApp (EVar "Hex.encode") (EApp (EVar "sha256") (EApp (EVar "encodeUtf8") (EVar "text")))))
(DTypeSig false "headerNode" (TyFun (TyCon "InterfaceKey") (TyFun (TyCon "Int") (TyFun (TyCon "String") (TyCon "SExp")))))
(DFunDef false "headerNode" ((PVar "key") (PVar "count") (PVar "digest")) (EApp (EApp (EVar "tagged") (ELit (LString "medaka-interface"))) (EListLit (EApp (EVar "intNode") (EVar "formatVersion")) (EApp (EApp (EVar "tagged") (ELit (LString "sources"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "pairAtoms")) (EFieldAccess (EVar "key") "ikSources")))) (EApp (EApp (EVar "tagged") (ELit (LString "compiler"))) (EListLit (EApp (EVar "SAtom") (EFieldAccess (EVar "key") "ikCompiler")))) (EApp (EApp (EVar "tagged") (ELit (LString "sections"))) (EListLit (EApp (EVar "intNode") (EDictApp "count")))) (EApp (EApp (EVar "tagged") (ELit (LString "digest"))) (EListLit (EApp (EVar "SAtom") (EVar "digest")))))))
(DTypeSig false "bodyOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "bodyOf" ((PVar "text")) (EMatch (EApp (EApp (EVar "S.indexOf") (ELit (LString "\n"))) (EVar "text")) (arm (PCon "Some" (PVar "i")) () (EApp (EApp (EVar "S.drop") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "text"))) (arm (PCon "None") () (ELit (LString "")))))
(DTypeSig false "joinNode" (TyFun (TyApp (TyCon "List") (TyCon "Atom")) (TyCon "SExp")))
(DFunDef false "joinNode" () (EApp (EVar "listSExp") (EVar "atomSExp")))
(DTypeSig false "sectionLine" (TyFun (TyCon "InterfaceSection") (TyCon "String")))
(DFunDef false "sectionLine" ((PVar "s")) (EBinOp "++" (EApp (EVar "renderSExp") (EApp (EVar "sectionNode") (EVar "s"))) (ELit (LString "\n"))))
(DTypeSig false "sectionNode" (TyFun (TyCon "InterfaceSection") (TyCon "SExp")))
(DFunDef false "sectionNode" ((PVar "s")) (EApp (EApp (EVar "tagged") (ELit (LString "section"))) (EListLit (EApp (EApp (EVar "tagged") (ELit (LString "joins"))) (EListLit (EApp (EApp (EVar "listSExp") (EVar "joinNode")) (EApp (EApp (EVar "sortOn") (EVar "joinText")) (EFieldAccess (EVar "s") "isJoins"))))) (EApp (EVar "interfaceNode") (EFieldAccess (EVar "s") "isInterface")))))
(DTypeSig false "interfaceNode" (TyFun (TyCon "PreludeInterface") (TyCon "SExp")))
(DFunDef false "interfaceNode" ((PCon "PreludeInterface" (PVar "funNames") (PVar "dispatch") (PVar "ctors") (PVar "ctorPop") (PVar "recordPop") (PVar "classes") (PVar "funSlots") (PVar "funSlotsQual") (PVar "declared") (PVar "declaredQual") (PVar "methodSlots") (PVar "methodSlotsQual") (PVar "ctorEx") (PVar "anyEx") (PVar "externs") (PVar "tyvarNext") (PVar "effvarNext") (PVar "core") (PVar "standalone"))) (EApp (EApp (EVar "tagged") (ELit (LString "interface"))) (EListLit (EApp (EApp (EVar "ordMapSExp") (EVar "unitSExp")) (EVar "funNames")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EApp (EApp (EVar "pairSExp") (EVar "ifaceRefSExp")) (EVar "SAtom"))) (EVar "intNode"))) (EVar "dispatch")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "tabKeySExp")) (EApp (EApp (EApp (EVar "tripleSExp") (EVar "dataVisSExp")) (EApp (EVar "listSExp") (EVar "SAtom"))) (EApp (EVar "listSExp") (EVar "variantSExp"))))) (EVar "ctors")) (EApp (EApp (EVar "spellingPopSExp") (EVar "pubSchemeSExp")) (EVar "ctorPop")) (EApp (EApp (EVar "spellingPopSExp") (EVar "recordInfoSExp")) (EVar "recordPop")) (EApp (EVar "builtinClassesSExp") (EVar "classes")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EApp (EVar "listSExp") (EVar "predicateSlotSExp")))) (EVar "funSlots")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "pairAtoms")) (EApp (EVar "listSExp") (EVar "predicateSlotSExp")))) (EVar "funSlotsQual")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "cDeclaredPrefixSExp"))) (EVar "declared")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "pairAtoms")) (EVar "cDeclaredPrefixSExp"))) (EVar "declaredQual")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EApp (EVar "listSExp") (EVar "methodPredicateSlotSExp")))) (EVar "methodSlots")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "pairAtoms")) (EApp (EVar "listSExp") (EVar "methodPredicateSlotSExp")))) (EVar "methodSlotsQual")) (EApp (EApp (EVar "intMapSExp") (EVar "unitSExp")) (EVar "ctorEx")) (EApp (EVar "boolNode") (EVar "anyEx")) (EApp (EApp (EVar "ordMapSExp") (EApp (EApp (EVar "pairSExp") (EVar "surfaceTySExp")) (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "intNode"))))) (EVar "externs")) (EApp (EVar "intNode") (EVar "tyvarNext")) (EApp (EVar "intNode") (EVar "effvarNext")) (EApp (EApp (EVar "listSExp") (EApp (EApp (EVar "pairSExp") (EVar "SAtom")) (EVar "pubSchemeSExp"))) (EVar "core")) (EApp (EApp (EVar "ordMapSExp") (EVar "unitSExp")) (EVar "standalone")))))
(DTypeSig true "interfaceFaults" (TyFun (TyCon "PreludeInterface") (TyApp (TyCon "List") (TyCon "LiveCell"))))
(DFunDef false "interfaceFaults" ((PVar "pi")) (EApp (EApp (EMethodRef "filter") (EVar "notFrozen")) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "row")) (EApp (EApp (EVar "liveCells") (EApp (EVar "fst") (EVar "row"))) (EApp (EVar "snd") (EVar "row"))))) (EFieldAccess (EVar "pi") "piCore")) (EApp (EApp (EVar "popFaults") (ELit (LString "ctor"))) (EFieldAccess (EVar "pi") "piCtorPop")))))
(DTypeSig false "popFaults" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "SpellingPop") (TyCon "PubScheme")) (TyApp (TyCon "List") (TyCon "LiveCell")))))
(DFunDef false "popFaults" ((PVar "label") (PVar "pop")) (EBinOp "++" (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "k")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EApp (EVar "spFloor") (EVar "pop"))) (arm (PCon "Some" (PVar "p")) () (EApp (EApp (EVar "liveCells") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString "")))) (EVar "p"))) (arm (PCon "None") () (EListLit))))) (EApp (EVar "omKeys") (EApp (EVar "spFloor") (EVar "pop")))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "k")) (EMatch (EApp (EApp (EVar "omLookup") (EVar "k")) (EApp (EVar "spRows") (EVar "pop"))) (arm (PCon "Some" (PVar "rows")) () (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "r")) (EApp (EApp (EVar "liveCells") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "label"))) (ELit (LString " "))) (EApp (EMethodRef "display") (EVar "k"))) (ELit (LString "")))) (EApp (EVar "thd3") (EVar "r"))))) (EVar "rows"))) (arm (PCon "None") () (EListLit))))) (EApp (EVar "omKeys") (EApp (EVar "spRows") (EVar "pop"))))))
(DTypeSig false "thd3" (TyFun (TyTuple (TyVar "a") (TyVar "b") (TyVar "c")) (TyVar "c")))
(DFunDef false "thd3" ((PTuple PWild PWild (PVar "c"))) (EVar "c"))
(DTypeSig true "encodeInterface" (TyFun (TyCon "PreludeInterfaceFile") (TyCon "String")))
(DFunDef false "encodeInterface" ((PVar "f")) (EMatch (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "s")) (EApp (EVar "interfaceFaults") (EFieldAccess (EVar "s") "isInterface")))) (EFieldAccess (EVar "f") "ifSections")) (arm (PList) () (EBlock (DoLet false false (PVar "body") (EApp (EApp (EVar "stringJoin") (ELit (LString ""))) (EApp (EApp (EMethodRef "map") (EVar "sectionLine")) (EFieldAccess (EVar "f") "ifSections")))) (DoLet false false (PVar "header") (EApp (EApp (EApp (EVar "headerNode") (EFieldAccess (EVar "f") "ifKey")) (EApp (EMethodRef "length") (EFieldAccess (EVar "f") "ifSections"))) (EApp (EVar "sha256Hex") (EVar "body")))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "renderSExp") (EVar "header")))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "body"))) (ELit (LString "")))))) (arm (PVar "faults") () (EApp (EVar "panic") (EBinOp "++" (EBinOp "++" (ELit (LString "interface row is not frozen: ")) (EApp (EMethodRef "display") (EApp (EMethodRef "debug") (EVar "faults")))) (ELit (LString "")))))))
(DTypeSig false "decPairAtoms" (TyApp (TyCon "Reader") (TyTuple (TyCon "String") (TyCon "String"))))
(DFunDef false "decPairAtoms" () (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EVar "expectAtom")))
(DTypeSig false "decInterface" (TyApp (TyCon "Reader") (TyCon "PreludeInterface")))
(DFunDef false "decInterface" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "interface"))) (PVar "n1") (PVar "n2") (PVar "n3") (PVar "n4") (PVar "n5") (PVar "n6") (PVar "n7") (PVar "n8") (PVar "n9") (PVar "n10") (PVar "n11") (PVar "n12") (PVar "n13") (PVar "n14") (PVar "n15") (PVar "n16") (PVar "n17") (PVar "n18") (PVar "n19")))) (ELet false (PVar "p") (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "interface"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "ordMapOfSExp") (EVar "unitOfSExp")) (EApp (EVar "p") (ELit (LInt 1)))) (EVar "n1"))) (ELam ((PVar "funNames")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EApp (EApp (EVar "pairOfSExp") (EApp (EVar "nested") (EVar "ifaceRefOfSExp"))) (EVar "expectAtom"))) (EVar "atomInt"))) (EApp (EVar "p") (ELit (LInt 2)))) (EVar "n2"))) (ELam ((PVar "dispatch")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EApp (EVar "nested") (EVar "tabKeyOfSExp"))) (EApp (EApp (EApp (EVar "tripleOfSExp") (EApp (EVar "nested") (EVar "dataVisOfSExp"))) (EApp (EVar "listOfSExp") (EVar "expectAtom"))) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "variantOfSExp")))))) (EApp (EVar "p") (ELit (LInt 3)))) (EVar "n3"))) (ELam ((PVar "ctors")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "spellingPopOfSExp") (EApp (EVar "nested") (EVar "pubSchemeOfSExp"))) (EApp (EVar "p") (ELit (LInt 4)))) (EVar "n4"))) (ELam ((PVar "ctorPop")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "spellingPopOfSExp") (EApp (EVar "nested") (EVar "recordInfoOfSExp"))) (EApp (EVar "p") (ELit (LInt 5)))) (EVar "n5"))) (ELam ((PVar "recordPop")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decClasses") (EApp (EVar "p") (ELit (LInt 6)))) (EVar "n6"))) (ELam ((PVar "classes")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "predicateSlotOfSExp"))))) (EApp (EVar "p") (ELit (LInt 7)))) (EVar "n7"))) (ELam ((PVar "funSlots")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "decPairAtoms")) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "predicateSlotOfSExp"))))) (EApp (EVar "p") (ELit (LInt 8)))) (EVar "n8"))) (ELam ((PVar "funSlotsQual")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EApp (EVar "nested") (EVar "cDeclaredPrefixOfSExp")))) (EApp (EVar "p") (ELit (LInt 9)))) (EVar "n9"))) (ELam ((PVar "declared")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "decPairAtoms")) (EApp (EVar "nested") (EVar "cDeclaredPrefixOfSExp")))) (EApp (EVar "p") (ELit (LInt 10)))) (EVar "n10"))) (ELam ((PVar "declaredQual")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "methodPredicateSlotOfSExp"))))) (EApp (EVar "p") (ELit (LInt 11)))) (EVar "n11"))) (ELam ((PVar "methodSlots")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "decPairAtoms")) (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "methodPredicateSlotOfSExp"))))) (EApp (EVar "p") (ELit (LInt 12)))) (EVar "n12"))) (ELam ((PVar "methodSlotsQual")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "intMapOfSExp") (EVar "unitOfSExp")) (EApp (EVar "p") (ELit (LInt 13)))) (EVar "n13"))) (ELam ((PVar "ctorEx")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomBool") (EApp (EVar "p") (ELit (LInt 14)))) (EVar "n14"))) (ELam ((PVar "anyEx")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "ordMapOfSExp") (EApp (EApp (EVar "pairOfSExp") (EApp (EVar "nested") (EVar "surfaceTyOfSExp"))) (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EVar "atomInt"))))) (EApp (EVar "p") (ELit (LInt 15)))) (EVar "n15"))) (ELam ((PVar "externs")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EVar "p") (ELit (LInt 16)))) (EVar "n16"))) (ELam ((PVar "tyvarNext")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EVar "p") (ELit (LInt 17)))) (EVar "n17"))) (ELam ((PVar "effvarNext")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EApp (EVar "pairOfSExp") (EVar "expectAtom")) (EApp (EVar "nested") (EVar "pubSchemeOfSExp")))) (EApp (EVar "p") (ELit (LInt 18)))) (EVar "n18"))) (ELam ((PVar "core")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "ordMapOfSExp") (EVar "unitOfSExp")) (EApp (EVar "p") (ELit (LInt 19)))) (EVar "n19"))) (ELam ((PVar "standalone")) (EApp (EVar "Ok") (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "PreludeInterface") (EVar "funNames")) (EVar "dispatch")) (EVar "ctors")) (EVar "ctorPop")) (EVar "recordPop")) (EVar "classes")) (EVar "funSlots")) (EVar "funSlotsQual")) (EVar "declared")) (EVar "declaredQual")) (EVar "methodSlots")) (EVar "methodSlotsQual")) (EVar "ctorEx")) (EVar "anyEx")) (EVar "externs")) (EVar "tyvarNext")) (EVar "effvarNext")) (EVar "core")) (EVar "standalone")))))))))))))))))))))))))))))))))))))))))))
(DFunDef false "decInterface" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "interface")) (ELit (LInt 19))))) (EVar "node")))
(DTypeSig false "decJoins" (TyApp (TyCon "Reader") (TyApp (TyCon "List") (TyApp (TyCon "List") (TyCon "Atom")))))
(DFunDef false "decJoins" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "joins"))) (PVar "js")))) (EApp (EApp (EApp (EVar "listOfSExp") (EApp (EVar "listOfSExp") (EApp (EVar "nested") (EVar "atomOfSExp")))) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "joins"))) (ELit (LInt 1)))) (EVar "js")))
(DFunDef false "decJoins" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "joins")) (ELit (LInt 1))))) (EVar "node")))
(DTypeSig false "decSection" (TyApp (TyCon "Reader") (TyCon "InterfaceSection")))
(DFunDef false "decSection" ((PVar "path") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "section"))) (PVar "js") (PVar "i")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decJoins") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "section"))) (ELit (LInt 1)))) (EVar "js"))) (ELam ((PVar "joins")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decInterface") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "section"))) (ELit (LInt 2)))) (EVar "i"))) (ELam ((PVar "value")) (EApp (EVar "Ok") (ERecordCreate "InterfaceSection" ((fa "isJoins" (EVar "joins")) (fa "isInterface" (EVar "value"))))))))))
(DFunDef false "decSection" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "section")) (ELit (LInt 2))))) (EVar "node")))
(DTypeSig false "decHeader" (TyApp (TyCon "Reader") (TyTuple (TyCon "InterfaceKey") (TyCon "Int") (TyCon "String"))))
(DFunDef false "decHeader" ((PVar "path") (PCon "SList" (PCons (PCon "SAtom" (PLit (LString "medaka-interface"))) (PCons (PVar "v") (PVar "rest"))))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "medaka-interface"))) (ELit (LInt 1)))) (EVar "v"))) (ELam ((PVar "version")) (EIf (EBinOp "==" (EVar "version") (EVar "formatVersion")) (EMatch (EVar "rest") (arm (PList (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sources"))) (PVar "srcs"))) (PCon "SList" (PList (PCon "SAtom" (PLit (LString "compiler"))) (PVar "c"))) (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sections"))) (PVar "cnt"))) (PCon "SList" (PList (PCon "SAtom" (PLit (LString "digest"))) (PVar "d")))) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "listOfSExp") (EVar "decPairAtoms")) (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sources"))) (ELit (LInt 1)))) (EVar "srcs"))) (ELam ((PVar "sources")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "compiler"))) (ELit (LInt 1)))) (EVar "c"))) (ELam ((PVar "compiler")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "sections"))) (ELit (LInt 1)))) (EVar "cnt"))) (ELam ((PVar "count")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "digest"))) (ELit (LInt 1)))) (EVar "d"))) (ELam ((PVar "claimed")) (EApp (EVar "Ok") (ETuple (ERecordCreate "InterfaceKey" ((fa "ikFormat" (EVar "version")) (fa "ikSources" (EVar "sources")) (fa "ikCompiler" (EVar "compiler")))) (EDictApp "count") (EVar "claimed")))))))))))) (arm PWild () (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "medaka-interface")) (ELit (LInt 5))))) (EApp (EVar "SList") (EBinOp "::" (EApp (EVar "SAtom") (ELit (LString "medaka-interface"))) (EBinOp "::" (EVar "v") (EVar "rest"))))))) (EApp (EApp (EApp (EVar "refuse") (EApp (EApp (EApp (EVar "at") (EVar "path")) (ELit (LString "medaka-interface"))) (ELit (LInt 1)))) (EVar "v")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "format version ")) (EApp (EMethodRef "display") (EVar "version"))) (ELit (LString ", this compiler reads "))) (EApp (EMethodRef "display") (EVar "formatVersion"))) (ELit (LString ""))))))))
(DFunDef false "decHeader" ((PVar "path") (PVar "node")) (EApp (EApp (EApp (EVar "misfit") (EVar "path")) (EListLit (ETuple (ELit (LString "medaka-interface")) (ELit (LInt 5))))) (EVar "node")))
(DTypeSig true "decodeInterface" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "PreludeInterfaceFile"))))
(DFunDef false "decodeInterface" ((PVar "text")) (EApp (EApp (EMethodRef "andThen") (EApp (EVar "parseSExp") (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "text")) (ELit (LString ")"))))) (ELam ((PVar "top")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "decodeParsed") (EApp (EVar "bodyOf") (EVar "text"))) (EVar "top"))))))
(DData Public "InterfaceFault" () ((variant "WrongFormat" (ConPos (TyCon "Int"))) (variant "Malformed" (ConPos (TyCon "SexpError")))) ())
(DTypeSig true "renderFault" (TyFun (TyCon "InterfaceFault") (TyCon "String")))
(DFunDef false "renderFault" ((PCon "WrongFormat" (PVar "v"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "format version ")) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString ", this compiler reads "))) (EApp (EMethodRef "display") (EVar "formatVersion"))) (ELit (LString ""))))
(DFunDef false "renderFault" ((PCon "Malformed" (PVar "e"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "e") "sePath"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "e") "seWhat"))) (ELit (LString ""))))
(DTypeSig true "readInterface" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "PreludeInterfaceFile") (TyCon "String")))))
(DFunDef false "readInterface" ((PVar "text")) (EMatch (EApp (EVar "parseSExp") (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EVar "text")) (ELit (LString ")")))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (EApp (EVar "Malformed") (EVar "e")))) (arm (PCon "Ok" (PVar "top")) () (EMatch (EApp (EVar "declaredVersion") (EVar "top")) (arm (PCon "Some" (PVar "v")) ((GBool (EBinOp "/=" (EVar "v") (EVar "formatVersion")))) (EApp (EVar "Err") (EApp (EVar "WrongFormat") (EVar "v")))) (arm PWild () (EApp (EApp (EVar "mapErr") (EVar "Malformed")) (EApp (EApp (EVar "decodeParsed") (EApp (EVar "bodyOf") (EVar "text"))) (EVar "top"))))))))
(DTypeSig false "declaredVersion" (TyFun (TyCon "SExp") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "declaredVersion" ((PCon "SList" (PCons (PCon "SList" (PCons (PCon "SAtom" (PLit (LString "medaka-interface"))) (PCons (PVar "v") PWild))) PWild))) (EMatch (EApp (EApp (EVar "atomInt") (ELit (LString ""))) (EVar "v")) (arm (PCon "Ok" (PVar "n")) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "Err" PWild) () (EVar "None"))))
(DFunDef false "declaredVersion" (PWild) (EVar "None"))
(DTypeSig false "decodeParsed" (TyFun (TyCon "String") (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "PreludeInterfaceFile") (TyCon "String"))))))
(DFunDef false "decodeParsed" ((PVar "body") (PCon "SList" (PCons (PVar "header") (PVar "sections")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "decHeader") (ELit (LString "header"))) (EVar "header"))) (ELam ((PTuple (PVar "key") (PVar "count") (PVar "claimed"))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "decList") (EVar "decSection")) (ELit (LString "file"))) (EApp (EVar "SList") (EVar "sections")))) (ELam ((PVar "secs")) (ELet false (PVar "found") (EApp (EVar "sha256Hex") (EVar "body")) (EIf (EBinOp "/=" (EApp (EMethodRef "length") (EVar "secs")) (EDictApp "count")) (EApp (EApp (EApp (EVar "refuse") (ELit (LString "header/sections.1"))) (EVar "header")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "header counts ")) (EApp (EMethodRef "display") (EDictApp "count"))) (ELit (LString " section(s), the file holds "))) (EApp (EMethodRef "display") (EApp (EMethodRef "length") (EVar "secs")))) (ELit (LString "")))) (EIf (EBinOp "/=" (EVar "found") (EVar "claimed")) (EApp (EApp (EApp (EVar "refuse") (ELit (LString "header/digest.1"))) (EVar "header")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "digest ")) (EApp (EMethodRef "display") (EApp (EApp (EVar "S.take") (ELit (LInt 12))) (EVar "claimed")))) (ELit (LString " expected, "))) (EApp (EMethodRef "display") (EApp (EApp (EVar "S.take") (ELit (LInt 12))) (EVar "found")))) (ELit (LString " found")))) (EApp (EVar "Ok") (ETuple (ERecordCreate "PreludeInterfaceFile" ((fa "ifKey" (EVar "key")) (fa "ifSections" (EVar "secs")))) (EVar "claimed")))))))))))
(DFunDef false "decodeParsed" (PWild (PVar "top")) (EApp (EApp (EApp (EVar "refuse") (ELit (LString "file"))) (EVar "top")) (ELit (LString "expected a header node"))))
