# META
source_lines=732
stages=DESUGAR,MARK
# SOURCE
-- The declaration index lint rules query about modules other than the one they
-- are linting.
--
-- One `IndexRow` per declared name: a value, a constructor, a type, an
-- interface or an interface method, keyed by (module id, namespace, name).  A
-- row carries the DECLARED signature as the parser wrote it, never an inferred
-- type, so an unsigned binding is a row with no signature and a rule must
-- abstain on it.  Ambiguity is kept: a lookup returns every candidate, and
-- there is deliberately no "the row for X".
--
-- Rows are extracted from a file's parse (`rowsOfDecls`) and cached per file in
-- a sexp shard keyed by (format version, stamp, path, content hash).  A shard
-- that does not answer for exactly this content is a miss and the file is
-- parsed again, so a stale, corrupt or foreign shard can cost time and never
-- an answer.  A shard's signatures are kept as text and decoded when a lookup
-- asks for one (`rowSig`), because a run reads thousands of rows and asks about
-- a handful of signatures.
--
-- The stdlib's rows are stored exported-only: an unexported stdlib row answers
-- no query a user's code can make.  The index is a per-run value; nothing here
-- keeps rows alive after the run that built them.
--
-- This module reads no inferred types and imports nothing from `types/`.

import frontend.ast.{
  Loc(..),
  Ty(..),
  Decl(..),
  DataVis(..),
  Variant(..),
  ConPayload(..),
  Field(..),
  IfaceMethod(..),
  ExternDecl(..),
  LetBind(..),
  tyConUnresolved,
}
import frontend.ast_codec.{sexpTy, readTy}
import support.sexp_value.{
  SExp(..),
  SexpCursor,
  renderSExp,
  cursorOf,
  cursorFailed,
  cursorAtEnd,
  cursorOpen,
  cursorClose,
  cursorInt,
  cursorAtom,
  cursorChar,
  cursorList,
  cursorPeek,
  cursorAdvance,
  cursorFail,
  cursorSkipText,
  isCloseByte,
}
import support.util.{joinWith, splitOnChar, listLen, filterList, anyList}
import hash_map.{HashMap, new, setInPlace, has, findWithDefault}
import list.{sortBy}
import frontend.parser.{Positions, ParseError}

-- ── rows ────────────────────────────────────────────────────────────────────

public export data RowKind =
  | RkValue
  | RkCtor
  | RkType
  | RkIface
  | RkMethod
  deriving (Eq)

-- Two namespaces, as the reference index keys binders: a type and a
-- constructor of the same name never collide.
public export data Ns = NsValue | NsType deriving (Eq)

-- A declared signature: absent (an unsigned binding), a parsed type, or the
-- text of a shard's type, which `rowSig` decodes on demand.
public export data SigSlot = NoSig | SigVal Ty | SigRaw String

-- `ixrModule` is the module id (the stdlib's dotted relative path, or
-- `moduleIdOfPath` for a project file).  `ixrParent` is a constructor's type or
-- a method's interface and "" otherwise.  `ixrFields` names a record
-- constructor's fields.  `ixrArity` is a constructor's field count and a type's
-- or interface's parameter count.  `ixrLoc` is the definition site and is not
-- part of a row's digest.
public export data IndexRow = IndexRow {
  ixrModule : String,
  ixrName : String,
  ixrKind : RowKind,
  ixrSig : SigSlot,
  ixrParent : String,
  ixrFields : List String,
  ixrArity : Int,
  ixrExported : Bool,
  ixrLoc : Option Loc,
}

export
rowNs : RowKind -> Ns
rowNs RkValue = NsValue
rowNs RkCtor = NsValue
rowNs RkMethod = NsValue
rowNs RkType = NsType
rowNs RkIface = NsType

-- The declared signature, decoded if the row holds it as text.  A text that
-- does not decode answers `None`: a rule abstains rather than act on a half
-- type.
export
rowSig : IndexRow -> Option Ty
rowSig r = sigOfSlot r.ixrSig

sigOfSlot : SigSlot -> Option Ty
sigOfSlot NoSig = None
sigOfSlot (SigVal t) = Some t
sigOfSlot (SigRaw text) =
  let cur = cursorOf text
  let t = readOptTy cur
  if cursorFailed cur || not (cursorAtEnd cur) then None else t

export
rowHasSig : IndexRow -> Bool
rowHasSig r = match r.ixrSig
  NoSig => False
  SigVal _ => True
  SigRaw _ => True

mkRow : String ->
  String ->
  RowKind ->
  SigSlot ->
  String ->
  List String ->
  Int ->
  Bool ->
  Option Loc ->
  IndexRow
mkRow m n k sig parent fields arity exp loc = IndexRow {
  ixrModule = m,
  ixrName = n,
  ixrKind = k,
  ixrSig = sig,
  ixrParent = parent,
  ixrFields = fields,
  ixrArity = arity,
  ixrExported = exp,
  ixrLoc = loc,
}

-- ── rows of one parsed file ─────────────────────────────────────────────────

-- Signatured declarations first (in source order), then the values that have a
-- body and no signature.
export
rowsOfDecls : String -> List Decl -> List IndexRow
rowsOfDecls modId decls =
  let signed = new ()
  let sigRows = flatMap (sigRowsOf modId signed) decls
  let seen = new ()
  sigRows ++ flatMap (unsignedRowsOf modId signed seen) decls

sigOf : Ty -> SigSlot
sigOf t = SigVal (stripTy t)

sigRowsOf : String -> HashMap String Unit -> Decl -> List IndexRow
sigRowsOf m signed (DTypeSig pub name ty loc) =
  let _ = setInPlace name () signed
  [mkRow m name RkValue (sigOf ty) "" [] 0 pub (Some loc)]
sigRowsOf m signed (DExtern (ExternDecl { edPub = pub, edName = name, edTy = ty, edLoc = loc, ... })) =
  let _ = setInPlace name () signed
  [mkRow m name RkValue (sigOf ty) "" [] 0 pub (Some loc)]
sigRowsOf m signed (DAttrib _ d) = sigRowsOf m signed d
sigRowsOf m _ (DData { dataVis = vis, dataName = name, dataParams = ps, dataCtors = ctors, dataNameLoc = loc, ... }) =
  mkRow m name RkType NoSig "" [] (listLen ps) (visExported vis) loc
    :: map (ctorRow m name ps (isPublicVis vis) loc) ctors
sigRowsOf m _ (DNewtype { newtypePub = pub, newtypeName = name, newtypeParams = ps, newtypeCtor = c, newtypeFieldTy = fty, newtypeNameLoc = loc, ... }) = [
  mkRow m name RkType NoSig "" [] (listLen ps) pub loc,
  mkRow m c RkCtor (sigOf (TyFun fty (resultTy name ps))) name [] 1 pub loc,
]
sigRowsOf m _ (DTypeAlias { tyAliasPub = pub, tyAliasName = name, tyAliasParams = ps, tyAliasRhs = rhs, tyAliasNameLoc = loc, ... }) =
  [mkRow m name RkType (sigOf rhs) "" [] (listLen ps) pub loc]
sigRowsOf m _ (DInterface { pub = pub, name = name, typarams = ps, methods = ms, ifaceNameLoc = loc, ... }) =
  mkRow m name RkIface NoSig "" [] (listLen ps) pub loc
    :: map (methodRow m name pub) ms
sigRowsOf _ _ _ = []

isPublicVis : DataVis -> Bool
isPublicVis VisPublic = True
isPublicVis VisAbstract = False
isPublicVis VisPrivate = False

visExported : DataVis -> Bool
visExported VisPrivate = False
visExported VisAbstract = True
visExported VisPublic = True

-- `T a b` for a type named `T` with parameters `a b`.
resultTy : String -> List String -> Ty
resultTy name params = applyVars (tyConUnresolved name None) params

applyVars : Ty -> List String -> Ty
applyVars t [] = t
applyVars t (p :: rest) = applyVars (TyApp t (TyVar p)) rest

-- `f1 -> f2 -> ... -> result`.
funTy : List Ty -> Ty -> Ty
funTy [] result = result
funTy (t :: rest) result = TyFun t (funTy rest result)

ctorRow : String ->
  String ->
  List String ->
  Bool ->
  Option Loc ->
  Variant ->
  IndexRow
ctorRow m parent ps exp loc (Variant c (ConPos tys)) =
  mkRow
    m
    c
    RkCtor
    (sigOf (funTy tys (resultTy parent ps)))
    parent
    []
    (listLen tys)
    exp
    loc
ctorRow m parent ps exp loc (Variant c (ConNamed fields _)) =
  mkRow
    m
    c
    RkCtor
    (sigOf (funTy (map fieldTy fields) (resultTy parent ps)))
    parent
    (map fieldName fields)
    (listLen fields)
    exp
    loc

fieldTy : Field -> Ty
fieldTy (Field _ t) = t

fieldName : Field -> String
fieldName (Field n _) = n

methodRow : String -> String -> Bool -> IfaceMethod -> IndexRow
methodRow m iface pub (IfaceMethod n ty _ loc) =
  mkRow m n RkMethod (sigOf ty) iface [] 0 pub loc

-- A value with a body and no signature: a row with no signature.
unsignedRowsOf : String ->
  HashMap String Unit ->
  HashMap String Unit ->
  Decl ->
  List IndexRow
unsignedRowsOf m signed seen (DFunDef pub name _ _ loc _) =
  unsignedRow m signed seen pub name loc
unsignedRowsOf m signed seen (DLetGroup pub binds) =
  flatMap (b => letRow m signed seen pub b) binds
unsignedRowsOf m signed seen (DAttrib _ d) = unsignedRowsOf m signed seen d
unsignedRowsOf _ _ _ _ = []

letRow : String ->
  HashMap String Unit ->
  HashMap String Unit ->
  Bool ->
  LetBind ->
  List IndexRow
letRow m signed seen pub (LetBind n _ loc _) =
  unsignedRow m signed seen pub n loc

unsignedRow : String ->
  HashMap String Unit ->
  HashMap String Unit ->
  Bool ->
  String ->
  Loc ->
  List IndexRow
unsignedRow m signed seen pub name loc
  | has name signed || has name seen = []
  | otherwise =
    let _ = setInPlace name () seen
    [mkRow m name RkValue NoSig "" [] 0 pub (Some loc)]

-- A signature's own spans point into the file that declared it and answer
-- nothing an index query asks, so a row's type carries none.  This keeps a
-- body-only edit that moves lines from changing any row's digest.
export
stripTy : Ty -> Ty
stripTy (TyCon { tyConName = n, tyConOrigin = o, ... }) =
  TyCon { tyConName = n, tyConLoc = None, tyConOrigin = o }
stripTy (TyVar v) = TyVar v
stripTy (TyApp a b) = TyApp (stripTy a) (stripTy b)
stripTy (TyFun a b) = TyFun (stripTy a) (stripTy b)
stripTy (TyTuple ts) = TyTuple (map stripTy ts)
stripTy (TyEffect atoms vs t) = TyEffect atoms vs (stripTy t)
stripTy (TyConstrained cs t) = TyConstrained cs (stripTy t)
stripTy (TyNamed n t e) = TyNamed n (stripTy t) e
stripTy (TyQual t ps _) = TyQual (stripTy t) ps None
stripTy (TyRow atoms vs _) = TyRow atoms vs None
stripTy (TyAuth ps _) = TyAuth ps None

-- Rows whose module is visible from outside: the stdlib as a user sees it.
export
exportedRows : List IndexRow -> List IndexRow
exportedRows rows = filterList rowIsExported rows

rowIsExported : IndexRow -> Bool
rowIsExported r = r.ixrExported

-- ── the row digest ──────────────────────────────────────────────────────────

kindTag : RowKind -> String
kindTag RkValue = "v"
kindTag RkCtor = "c"
kindTag RkType = "t"
kindTag RkIface = "i"
kindTag RkMethod = "m"

kindOfTag : Int -> Option RowKind
kindOfTag 118 = Some RkValue
kindOfTag 99 = Some RkCtor
kindOfTag 116 = Some RkType
kindOfTag 105 = Some RkIface
kindOfTag 109 = Some RkMethod
kindOfTag _ = None

-- The text of a signature slot as stored: `()` for none, `(<ty>)` otherwise.
slotText : SigSlot -> String
slotText NoSig = "()"
slotText (SigVal t) = renderSExp (SList [sexpTy t])
slotText (SigRaw text) = text

-- Everything about a row except where it is defined.
rowKeyText : IndexRow -> String
rowKeyText r = joinWith "\t" [
  r.ixrModule,
  r.ixrName,
  kindTag r.ixrKind,
  slotText r.ixrSig,
  r.ixrParent,
  joinWith "," r.ixrFields,
  intToString r.ixrArity,
  if r.ixrExported then "t" else "f",
]

-- A digest of a file's rows that moves when a name, kind, signature, arity,
-- field list or export changes, and does not move when only a position does.
export
rowsDigest : List IndexRow -> String
rowsDigest rows =
  let joined = joinWith "\n" (sortBy stringCompare (map rowKeyText rows))
  let n = stringLength joined
  let lane2 = if n == 0 then 0 else hashString (stringSlice 1 n joined)
  "\{hashString joined}.\{lane2}.\{n}"

-- ── shard codec ─────────────────────────────────────────────────────────────

-- Bump when the shard schema changes in a way an old shard would decode into
-- something wrong rather than fail to decode.
rowFormatVersion : Int
rowFormatVersion = 1

sexpOptLoc : Option Loc -> SExp
sexpOptLoc None = SList []
sexpOptLoc (Some (Loc _ a b c d)) = SList [
  SAtom (intToString a),
  SAtom (intToString b),
  SAtom (intToString c),
  SAtom (intToString d),
]

-- The location's file is the shard's own path, restored on load.
readOptLoc : String -> SexpCursor -> Option Loc
readOptLoc path cur =
  let _ = cursorOpen cur
  if isCloseByte (cursorPeek cur) then
    let _ = cursorAdvance cur
    None
  else
    let a = cursorInt cur
    let b = cursorInt cur
    let c = cursorInt cur
    let d = cursorInt cur
    let _ = cursorClose cur
    Some (Loc path a b c d)

-- The shard text: version, stamp, path, content hash, module id, rows digest,
-- rows.  A row that holds its signature as text is written with that text.
export
encodeRowShard : String -> String -> String -> String -> List IndexRow -> String
encodeRowShard stamp path hash modId rows =
  renderShard stamp path hash modId (rowsDigest rows) (map rowText rows)

-- The signature is already text, so it is written into the row verbatim.
rowText : IndexRow -> String
rowText r =
  "(\{quoted r.ixrName} \{kindTag r.ixrKind} \{slotText r.ixrSig} \{quoted r.ixrParent} \{renderSExp (SList (map SAtom r.ixrFields))} \{intToString r.ixrArity} \{if r.ixrExported then "t" else "f"} \{renderSExp (sexpOptLoc r.ixrLoc)})"

renderShard : String ->
  String ->
  String ->
  String ->
  String ->
  List String ->
  String
renderShard stamp path hash modId digest rowTexts =
  "(\{intToString rowFormatVersion} \{quoted stamp} \{quoted path} \{quoted hash} \{quoted modId} \{quoted digest} (\{joinWith " " rowTexts}))"

quoted : String -> String
quoted s = renderSExp (SAtom s)

readBoolTF : SexpCursor -> Bool
readBoolTF cur =
  let c = cursorChar cur
  if c == 116 then True else if c == 102 then False else cursorFail cur False

-- A signature slot is left as text; `()` is no signature.
readSlot : SexpCursor -> SigSlot
readSlot cur =
  let text = cursorSkipText cur
  if text == "()" then NoSig else SigRaw text

readRow : String -> String -> SexpCursor -> IndexRow
readRow path m cur =
  let _ = cursorOpen cur
  let n = cursorAtom cur
  let k = match kindOfTag (cursorChar cur)
    Some kk => kk
    None => cursorFail cur RkValue
  let sig = readSlot cur
  let parent = cursorAtom cur
  let fields = cursorList cursorAtom cur
  let arity = cursorInt cur
  let exp = readBoolTF cur
  let loc = readOptLoc path cur
  let _ = cursorClose cur
  mkRow m n k sig parent fields arity exp loc

readOptTy : SexpCursor -> Option Ty
readOptTy cur =
  let _ = cursorOpen cur
  if isCloseByte (cursorPeek cur) then
    let _ = cursorAdvance cur
    None
  else
    let t = readTy cur
    let _ = cursorClose cur
    Some t

-- (module id, rows digest, rows), or `None` on any doubt: a wrong version,
-- stamp, path or content hash, a malformed body, or trailing text.
export
decodeRowShard : String ->
  String ->
  String ->
  String ->
  Option (String, String, List IndexRow)
decodeRowShard stamp path hash text =
  let cur = cursorOf text
  let _ = cursorOpen cur
  let v = cursorInt cur
  let st = cursorAtom cur
  let p = cursorAtom cur
  let h = cursorAtom cur
  if cursorFailed cur
    || v /= rowFormatVersion
    || st /= stamp
    || p /= path
    || h /= hash then
    None
  else
    let m = cursorAtom cur
    let digest = cursorAtom cur
    let rows = cursorList (readRow path m) cur
    let _ = cursorClose cur
    if cursorFailed cur || not (cursorAtEnd cur) then
      None
    else
      Some (m, digest, rows)

-- ── the per-file row cache ──────────────────────────────────────────────────

-- The directory name of the row cache.  Stdlib rows live under
-- `${XDG_CACHE_HOME:-$HOME/.cache}/medaka/<indexCacheDir>`; a project's under
-- `<project root>/.medaka/<indexCacheDir>`.  `medaka lint` writes both without
-- being asked (docs/ops/CLI-CONFORMANCE.md).
export
indexCacheDir : String
indexCacheDir = "lint-index"

-- Where the stdlib's shards go, or "" when there is no home to put them in.
export
stdlibShardDir : Unit -> <IO> String
stdlibShardDir _ =
  let xdg = optionOr "" (getEnv "XDG_CACHE_HOME")
  let home = optionOr "" (getEnv "HOME")
  if xdg /= "" then
    "\{xdg}/medaka/\{indexCacheDir}"
  else if home /= "" then
    "\{home}/.cache/medaka/\{indexCacheDir}"
  else
    ""

export
projectShardDir : String -> String
projectShardDir root = "\{root}/.medaka/\{indexCacheDir}"

-- The shard of `path` in `dir`.  The name is the file's own name plus a hash
-- of its full path; the path is also stored in the shard and checked on load,
-- so a name collision costs a miss and never a wrong answer.
export
rowShardPath : String -> String -> String
rowShardPath dir path =
  "\{dir}/\{lastSegment "" (splitOnChar '/' path)}.\{intToString (hashString path)}.sx"

lastSegment : String -> List String -> String
lastSegment acc [] = acc
lastSegment _ (x :: rest) = lastSegment x rest

-- The content key a shard is checked against: one hash lane plus the length.
export
rowContentHash : String -> String
rowContentHash src = "\{hashString src}.\{stringLength src}"

-- A file's rows and their digest, from its shard when the shard answers for
-- this exact content, else from a parse (and the shard is rewritten).  `Err`
-- carries the source and the parse error for the caller's diagnostic.  An
-- unreadable file has no rows.  `dir` "" means no cache.  `exportedOnly` keeps
-- only the exported rows, in the shard and in the result.
export
fileRows : Bool ->
  (String -> Result ParseError (List Decl, Positions)) ->
  String ->
  String ->
  String ->
  String ->
  <IO> Result (String, ParseError) (String, List IndexRow)
fileRows exportedOnly parse dir stamp modId path = match readFile path
  Err _ => Ok ("", [])
  Ok src =>
    let hash = rowContentHash src
    let shardStamp = if exportedOnly then "\{stamp}/x" else stamp
    let sp = rowShardPath dir path
    let cached =
      if dir == "" then
        None
      else match readFile sp
        Ok text => decodeRowShard shardStamp path hash text
        Err _ => None
    match cached
      Some (_, digest, rows) => Ok (digest, rows)
      None => match parse src
        Err e => Err (src, e)
        Ok (decls, _) =>
          let all = map (atPath path) (rowsOfDecls modId decls)
          let rows = if exportedOnly then exportedRows all else all
          let _ =
            if dir == "" then
              ()
            else
              writeShard dir sp (encodeRowShard shardStamp path hash modId rows)
          Ok (rowsDigest rows, rows)

-- A row's location is in the file the shard describes.
atPath : String -> IndexRow -> IndexRow
atPath path r = match r.ixrLoc
  Some (Loc _ a b c d) => { r | ixrLoc = Some (Loc path a b c d) }
  None => r

writeShard : String -> String -> String -> <IO> Unit
writeShard dir sp text =
  let _ = makeDirs dir
  let tmp = "\{sp}.tmp"
  match writeFile tmp text
    Err _ => ()
    Ok _ => match rename tmp sp
      Err _ => ()
      Ok _ => ()

-- `mkdir -p`: every missing ancestor of `dir`, then `dir`.
makeDirs : String -> <IO> Unit
makeDirs dir =
  let parts = splitOnChar '/' dir
  makeDirsGo "" parts

makeDirsGo : String -> List String -> <IO> Unit
makeDirsGo _ [] = ()
makeDirsGo acc (p :: rest)
  | p == "" = makeDirsGo acc rest
  | otherwise =
    let next = "\{acc}/\{p}"
    let _ = makeDir next
    makeDirsGo next rest

-- ── the index ───────────────────────────────────────────────────────────────

-- One scope's rows, grouped by name in input order.  `ixsNames` and
-- `ixsModules` describe the exported signed values only: the names and modules
-- a rule can ask `rowsNamed` about with a signature in hand.
data IndexScope = IndexScope {
  ixsByName : HashMap String (List IndexRow),
  ixsRows : List IndexRow,
  ixsNames : List String,
  ixsModules : List String,
}

-- The stdlib's rows and the project's.  A project index holds both, and a
-- rule that wants the stdlib alone asks the stdlib scope.
public export data ProjectIndex = ProjectIndex IndexScope IndexScope

emptyScope : IndexScope
emptyScope = IndexScope {
  ixsByName = new (),
  ixsRows = [],
  ixsNames = [],
  ixsModules = [],
}

export
emptyProjectIndex : ProjectIndex
emptyProjectIndex = ProjectIndex emptyScope emptyScope

-- The index of the stdlib's rows and the project's rows.
export
mkProjectIndex : List IndexRow -> List IndexRow -> ProjectIndex
mkProjectIndex stdlibRows projectRows =
  ProjectIndex (mkScope stdlibRows) (mkScope projectRows)

mkScope : List IndexRow -> IndexScope
mkScope rows =
  let m = new ()
  let _ = groupInto (reverseRows rows []) m
  let signed = filterList isExportedSigValue rows
  IndexScope {
    ixsByName = m,
    ixsRows = rows,
    ixsNames = sortedUnique (map rowName signed),
    ixsModules = sortedUnique (map rowModule signed),
  }

isExportedSigValue : IndexRow -> Bool
isExportedSigValue r = r.ixrKind == RkValue && r.ixrExported && rowHasSig r

rowName : IndexRow -> String
rowName r = r.ixrName

rowModule : IndexRow -> String
rowModule r = r.ixrModule

reverseRows : List IndexRow -> List IndexRow -> List IndexRow
reverseRows [] acc = acc
reverseRows (r :: rest) acc = reverseRows rest (r :: acc)

-- Prepending the rows last-first keeps each name's rows in input order.
groupInto : List IndexRow -> HashMap String (List IndexRow) -> Unit
groupInto [] _ = ()
groupInto (r :: rest) m =
  let _ = setInPlace r.ixrName (r :: findWithDefault [] r.ixrName m) m
  groupInto rest m

sortedUnique : List String -> List String
sortedUnique xs = dropRepeats (sortBy stringCompare xs)

-- The input is sorted, so equal names are adjacent.
dropRepeats : List String -> List String
dropRepeats [] = []
dropRepeats [x] = [x]
dropRepeats (a :: b :: rest) =
  if a == b then dropRepeats (b :: rest) else a :: dropRepeats (b :: rest)

scopeNamed : IndexScope -> Ns -> String -> List IndexRow
scopeNamed s ns name =
  filterList (r => rowNs r.ixrKind == ns) (findWithDefault [] name s.ixsByName)

-- Every candidate for `name` in `ns`: the project's rows, then the stdlib's.
export
rowsNamed : ProjectIndex -> Ns -> String -> List IndexRow
rowsNamed (ProjectIndex std proj) ns name =
  scopeNamed proj ns name ++ scopeNamed std ns name

-- The stdlib's candidates alone.
export
stdlibRowsNamed : ProjectIndex -> Ns -> String -> List IndexRow
stdlibRowsNamed (ProjectIndex std _) ns name = scopeNamed std ns name

-- The project's candidates alone.
export
projectRowsNamed : ProjectIndex -> Ns -> String -> List IndexRow
projectRowsNamed (ProjectIndex _ proj) ns name = scopeNamed proj ns name

-- Candidates for `name` declared in module `modId` (still a list: a name can
-- be a value and a constructor, or be declared twice).
export
rowsIn : ProjectIndex -> String -> Ns -> String -> List IndexRow
rowsIn idx modId ns name =
  filterList (r => r.ixrModule == modId) (rowsNamed idx ns name)

-- Every row of module `modId`, in file order.
export
rowsOfModule : ProjectIndex -> String -> List IndexRow
rowsOfModule (ProjectIndex std proj) modId =
  filterList (r => r.ixrModule == modId) (proj.ixsRows ++ std.ixsRows)

-- Every row of a scope, in file order.
export
stdlibRows : ProjectIndex -> List IndexRow
stdlibRows (ProjectIndex std _) = std.ixsRows

export
projectRows : ProjectIndex -> List IndexRow
projectRows (ProjectIndex _ proj) = proj.ixsRows

-- The sorted names of the stdlib's exported signed values.
export
stdlibValueNames : ProjectIndex -> List String
stdlibValueNames (ProjectIndex std _) = std.ixsNames

-- The stdlib modules that export a signed value; a module outside this list
-- has nothing the index can vouch for.
export
stdlibValueModules : ProjectIndex -> List String
stdlibValueModules (ProjectIndex std _) = std.ixsModules

-- Whether any row of module `modId` is in the index: an abstain test for a
-- module the index never read.
export
indexKnowsModule : ProjectIndex -> String -> Bool
indexKnowsModule (ProjectIndex std proj) modId =
  anyList (r => r.ixrModule == modId) proj.ixsRows
    || anyList (r => r.ixrModule == modId) std.ixsRows
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Ty" true) (mem "Decl" true) (mem "DataVis" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Field" true) (mem "IfaceMethod" true) (mem "ExternDecl" true) (mem "LetBind" true) (mem "tyConUnresolved" false))))
(DUse false (UseGroup ("frontend" "ast_codec") ((mem "sexpTy" false) (mem "readTy" false))))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "SexpCursor" false) (mem "renderSExp" false) (mem "cursorOf" false) (mem "cursorFailed" false) (mem "cursorAtEnd" false) (mem "cursorOpen" false) (mem "cursorClose" false) (mem "cursorInt" false) (mem "cursorAtom" false) (mem "cursorChar" false) (mem "cursorList" false) (mem "cursorPeek" false) (mem "cursorAdvance" false) (mem "cursorFail" false) (mem "cursorSkipText" false) (mem "isCloseByte" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "splitOnChar" false) (mem "listLen" false) (mem "filterList" false) (mem "anyList" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "setInPlace" false) (mem "has" false) (mem "findWithDefault" false))))
(DUse false (UseGroup ("list") ((mem "sortBy" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" false) (mem "ParseError" false))))
(DData Public "RowKind" () ((variant "RkValue" (ConPos)) (variant "RkCtor" (ConPos)) (variant "RkType" (ConPos)) (variant "RkIface" (ConPos)) (variant "RkMethod" (ConPos))) ())
(DImpl true "Eq" ((TyCon "RowKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RkValue") (PCon "RkValue")) () (EVar "True")) (arm (PTuple (PCon "RkCtor") (PCon "RkCtor")) () (EVar "True")) (arm (PTuple (PCon "RkType") (PCon "RkType")) () (EVar "True")) (arm (PTuple (PCon "RkIface") (PCon "RkIface")) () (EVar "True")) (arm (PTuple (PCon "RkMethod") (PCon "RkMethod")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "Ns" () ((variant "NsValue" (ConPos)) (variant "NsType" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Ns")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "NsValue") (PCon "NsValue")) () (EVar "True")) (arm (PTuple (PCon "NsType") (PCon "NsType")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "SigSlot" () ((variant "NoSig" (ConPos)) (variant "SigVal" (ConPos (TyCon "Ty"))) (variant "SigRaw" (ConPos (TyCon "String")))) ())
(DData Public "IndexRow" () ((variant "IndexRow" (ConNamed (field "ixrModule" (TyCon "String")) (field "ixrName" (TyCon "String")) (field "ixrKind" (TyCon "RowKind")) (field "ixrSig" (TyCon "SigSlot")) (field "ixrParent" (TyCon "String")) (field "ixrFields" (TyApp (TyCon "List") (TyCon "String"))) (field "ixrArity" (TyCon "Int")) (field "ixrExported" (TyCon "Bool")) (field "ixrLoc" (TyApp (TyCon "Option") (TyCon "Loc")))))) ())
(DTypeSig true "rowNs" (TyFun (TyCon "RowKind") (TyCon "Ns")))
(DFunDef false "rowNs" ((PCon "RkValue")) (EVar "NsValue"))
(DFunDef false "rowNs" ((PCon "RkCtor")) (EVar "NsValue"))
(DFunDef false "rowNs" ((PCon "RkMethod")) (EVar "NsValue"))
(DFunDef false "rowNs" ((PCon "RkType")) (EVar "NsType"))
(DFunDef false "rowNs" ((PCon "RkIface")) (EVar "NsType"))
(DTypeSig true "rowSig" (TyFun (TyCon "IndexRow") (TyApp (TyCon "Option") (TyCon "Ty"))))
(DFunDef false "rowSig" ((PVar "r")) (EApp (EVar "sigOfSlot") (EFieldAccess (EVar "r") "ixrSig")))
(DTypeSig false "sigOfSlot" (TyFun (TyCon "SigSlot") (TyApp (TyCon "Option") (TyCon "Ty"))))
(DFunDef false "sigOfSlot" ((PCon "NoSig")) (EVar "None"))
(DFunDef false "sigOfSlot" ((PCon "SigVal" (PVar "t"))) (EApp (EVar "Some") (EVar "t")))
(DFunDef false "sigOfSlot" ((PCon "SigRaw" (PVar "text"))) (EBlock (DoLet false false (PVar "cur") (EApp (EVar "cursorOf") (EVar "text"))) (DoLet false false (PVar "t") (EApp (EVar "readOptTy") (EVar "cur"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "cursorFailed") (EVar "cur")) (EApp (EVar "not") (EApp (EVar "cursorAtEnd") (EVar "cur")))) (EVar "None") (EVar "t")))))
(DTypeSig true "rowHasSig" (TyFun (TyCon "IndexRow") (TyCon "Bool")))
(DFunDef false "rowHasSig" ((PVar "r")) (EMatch (EFieldAccess (EVar "r") "ixrSig") (arm (PCon "NoSig") () (EVar "False")) (arm (PCon "SigVal" PWild) () (EVar "True")) (arm (PCon "SigRaw" PWild) () (EVar "True"))))
(DTypeSig false "mkRow" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "RowKind") (TyFun (TyCon "SigSlot") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "IndexRow")))))))))))
(DFunDef false "mkRow" ((PVar "m") (PVar "n") (PVar "k") (PVar "sig") (PVar "parent") (PVar "fields") (PVar "arity") (PVar "exp") (PVar "loc")) (ERecordCreate "IndexRow" ((fa "ixrModule" (EVar "m")) (fa "ixrName" (EVar "n")) (fa "ixrKind" (EVar "k")) (fa "ixrSig" (EVar "sig")) (fa "ixrParent" (EVar "parent")) (fa "ixrFields" (EVar "fields")) (fa "ixrArity" (EVar "arity")) (fa "ixrExported" (EVar "exp")) (fa "ixrLoc" (EVar "loc")))))
(DTypeSig true "rowsOfDecls" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "IndexRow")))))
(DFunDef false "rowsOfDecls" ((PVar "modId") (PVar "decls")) (EBlock (DoLet false false (PVar "signed") (EApp (EVar "new") (ELit LUnit))) (DoLet false false (PVar "sigRows") (EApp (EApp (EVar "flatMap") (EApp (EApp (EVar "sigRowsOf") (EVar "modId")) (EVar "signed"))) (EVar "decls"))) (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EBinOp "++" (EVar "sigRows") (EApp (EApp (EVar "flatMap") (EApp (EApp (EApp (EVar "unsignedRowsOf") (EVar "modId")) (EVar "signed")) (EVar "seen"))) (EVar "decls"))))))
(DTypeSig false "sigOf" (TyFun (TyCon "Ty") (TyCon "SigSlot")))
(DFunDef false "sigOf" ((PVar "t")) (EApp (EVar "SigVal") (EApp (EVar "stripTy") (EVar "t"))))
(DTypeSig false "sigRowsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "IndexRow"))))))
(DFunDef false "sigRowsOf" ((PVar "m") (PVar "signed") (PCon "DTypeSig" (PVar "pub") (PVar "name") (PVar "ty") (PVar "loc"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "name")) (ELit LUnit)) (EVar "signed"))) (DoExpr (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "name")) (EVar "RkValue")) (EApp (EVar "sigOf") (EVar "ty"))) (ELit (LString ""))) (EListLit)) (ELit (LInt 0))) (EVar "pub")) (EApp (EVar "Some") (EVar "loc")))))))
(DFunDef false "sigRowsOf" ((PVar "m") (PVar "signed") (PCon "DExtern" (PRec "ExternDecl" ((rf "edPub" (PVar "pub")) (rf "edName" (PVar "name")) (rf "edTy" (PVar "ty")) (rf "edLoc" (PVar "loc"))) true))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "name")) (ELit LUnit)) (EVar "signed"))) (DoExpr (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "name")) (EVar "RkValue")) (EApp (EVar "sigOf") (EVar "ty"))) (ELit (LString ""))) (EListLit)) (ELit (LInt 0))) (EVar "pub")) (EApp (EVar "Some") (EVar "loc")))))))
(DFunDef false "sigRowsOf" ((PVar "m") (PVar "signed") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EVar "sigRowsOf") (EVar "m")) (EVar "signed")) (EVar "d")))
(DFunDef false "sigRowsOf" ((PVar "m") PWild (PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "name")) (rf "dataParams" (PVar "ps")) (rf "dataCtors" (PVar "ctors")) (rf "dataNameLoc" (PVar "loc"))) true)) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "name")) (EVar "RkType")) (EVar "NoSig")) (ELit (LString ""))) (EListLit)) (EApp (EVar "listLen") (EVar "ps"))) (EApp (EVar "visExported") (EVar "vis"))) (EVar "loc")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EApp (EApp (EVar "ctorRow") (EVar "m")) (EVar "name")) (EVar "ps")) (EApp (EVar "isPublicVis") (EVar "vis"))) (EVar "loc"))) (EVar "ctors"))))
(DFunDef false "sigRowsOf" ((PVar "m") PWild (PRec "DNewtype" ((rf "newtypePub" (PVar "pub")) (rf "newtypeName" (PVar "name")) (rf "newtypeParams" (PVar "ps")) (rf "newtypeCtor" (PVar "c")) (rf "newtypeFieldTy" (PVar "fty")) (rf "newtypeNameLoc" (PVar "loc"))) true)) (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "name")) (EVar "RkType")) (EVar "NoSig")) (ELit (LString ""))) (EListLit)) (EApp (EVar "listLen") (EVar "ps"))) (EVar "pub")) (EVar "loc")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "c")) (EVar "RkCtor")) (EApp (EVar "sigOf") (EApp (EApp (EVar "TyFun") (EVar "fty")) (EApp (EApp (EVar "resultTy") (EVar "name")) (EVar "ps"))))) (EVar "name")) (EListLit)) (ELit (LInt 1))) (EVar "pub")) (EVar "loc"))))
(DFunDef false "sigRowsOf" ((PVar "m") PWild (PRec "DTypeAlias" ((rf "tyAliasPub" (PVar "pub")) (rf "tyAliasName" (PVar "name")) (rf "tyAliasParams" (PVar "ps")) (rf "tyAliasRhs" (PVar "rhs")) (rf "tyAliasNameLoc" (PVar "loc"))) true)) (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "name")) (EVar "RkType")) (EApp (EVar "sigOf") (EVar "rhs"))) (ELit (LString ""))) (EListLit)) (EApp (EVar "listLen") (EVar "ps"))) (EVar "pub")) (EVar "loc"))))
(DFunDef false "sigRowsOf" ((PVar "m") PWild (PRec "DInterface" ((rf "pub" (PVar "pub")) (rf "name" (PVar "name")) (rf "typarams" (PVar "ps")) (rf "methods" (PVar "ms")) (rf "ifaceNameLoc" (PVar "loc"))) true)) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "name")) (EVar "RkIface")) (EVar "NoSig")) (ELit (LString ""))) (EListLit)) (EApp (EVar "listLen") (EVar "ps"))) (EVar "pub")) (EVar "loc")) (EApp (EApp (EVar "map") (EApp (EApp (EApp (EVar "methodRow") (EVar "m")) (EVar "name")) (EVar "pub"))) (EVar "ms"))))
(DFunDef false "sigRowsOf" (PWild PWild PWild) (EListLit))
(DTypeSig false "isPublicVis" (TyFun (TyCon "DataVis") (TyCon "Bool")))
(DFunDef false "isPublicVis" ((PCon "VisPublic")) (EVar "True"))
(DFunDef false "isPublicVis" ((PCon "VisAbstract")) (EVar "False"))
(DFunDef false "isPublicVis" ((PCon "VisPrivate")) (EVar "False"))
(DTypeSig false "visExported" (TyFun (TyCon "DataVis") (TyCon "Bool")))
(DFunDef false "visExported" ((PCon "VisPrivate")) (EVar "False"))
(DFunDef false "visExported" ((PCon "VisAbstract")) (EVar "True"))
(DFunDef false "visExported" ((PCon "VisPublic")) (EVar "True"))
(DTypeSig false "resultTy" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty"))))
(DFunDef false "resultTy" ((PVar "name") (PVar "params")) (EApp (EApp (EVar "applyVars") (EApp (EApp (EVar "tyConUnresolved") (EVar "name")) (EVar "None"))) (EVar "params")))
(DTypeSig false "applyVars" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty"))))
(DFunDef false "applyVars" ((PVar "t") (PList)) (EVar "t"))
(DFunDef false "applyVars" ((PVar "t") (PCons (PVar "p") (PVar "rest"))) (EApp (EApp (EVar "applyVars") (EApp (EApp (EVar "TyApp") (EVar "t")) (EApp (EVar "TyVar") (EVar "p")))) (EVar "rest")))
(DTypeSig false "funTy" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "funTy" ((PList) (PVar "result")) (EVar "result"))
(DFunDef false "funTy" ((PCons (PVar "t") (PVar "rest")) (PVar "result")) (EApp (EApp (EVar "TyFun") (EVar "t")) (EApp (EApp (EVar "funTy") (EVar "rest")) (EVar "result"))))
(DTypeSig false "ctorRow" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Variant") (TyCon "IndexRow"))))))))
(DFunDef false "ctorRow" ((PVar "m") (PVar "parent") (PVar "ps") (PVar "exp") (PVar "loc") (PCon "Variant" (PVar "c") (PCon "ConPos" (PVar "tys")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "c")) (EVar "RkCtor")) (EApp (EVar "sigOf") (EApp (EApp (EVar "funTy") (EVar "tys")) (EApp (EApp (EVar "resultTy") (EVar "parent")) (EVar "ps"))))) (EVar "parent")) (EListLit)) (EApp (EVar "listLen") (EVar "tys"))) (EVar "exp")) (EVar "loc")))
(DFunDef false "ctorRow" ((PVar "m") (PVar "parent") (PVar "ps") (PVar "exp") (PVar "loc") (PCon "Variant" (PVar "c") (PCon "ConNamed" (PVar "fields") PWild))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "c")) (EVar "RkCtor")) (EApp (EVar "sigOf") (EApp (EApp (EVar "funTy") (EApp (EApp (EVar "map") (EVar "fieldTy")) (EVar "fields"))) (EApp (EApp (EVar "resultTy") (EVar "parent")) (EVar "ps"))))) (EVar "parent")) (EApp (EApp (EVar "map") (EVar "fieldName")) (EVar "fields"))) (EApp (EVar "listLen") (EVar "fields"))) (EVar "exp")) (EVar "loc")))
(DTypeSig false "fieldTy" (TyFun (TyCon "Field") (TyCon "Ty")))
(DFunDef false "fieldTy" ((PCon "Field" PWild (PVar "t"))) (EVar "t"))
(DTypeSig false "fieldName" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldName" ((PCon "Field" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "methodRow" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "IfaceMethod") (TyCon "IndexRow"))))))
(DFunDef false "methodRow" ((PVar "m") (PVar "iface") (PVar "pub") (PCon "IfaceMethod" (PVar "n") (PVar "ty") PWild (PVar "loc"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "n")) (EVar "RkMethod")) (EApp (EVar "sigOf") (EVar "ty"))) (EVar "iface")) (EListLit)) (ELit (LInt 0))) (EVar "pub")) (EVar "loc")))
(DTypeSig false "unsignedRowsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "IndexRow")))))))
(DFunDef false "unsignedRowsOf" ((PVar "m") (PVar "signed") (PVar "seen") (PCon "DFunDef" (PVar "pub") (PVar "name") PWild PWild (PVar "loc") PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "unsignedRow") (EVar "m")) (EVar "signed")) (EVar "seen")) (EVar "pub")) (EVar "name")) (EVar "loc")))
(DFunDef false "unsignedRowsOf" ((PVar "m") (PVar "signed") (PVar "seen") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "flatMap") (ELam ((PVar "b")) (EApp (EApp (EApp (EApp (EApp (EVar "letRow") (EVar "m")) (EVar "signed")) (EVar "seen")) (EVar "pub")) (EVar "b")))) (EVar "binds")))
(DFunDef false "unsignedRowsOf" ((PVar "m") (PVar "signed") (PVar "seen") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "unsignedRowsOf") (EVar "m")) (EVar "signed")) (EVar "seen")) (EVar "d")))
(DFunDef false "unsignedRowsOf" (PWild PWild PWild PWild) (EListLit))
(DTypeSig false "letRow" (TyFun (TyCon "String") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "IndexRow"))))))))
(DFunDef false "letRow" ((PVar "m") (PVar "signed") (PVar "seen") (PVar "pub") (PCon "LetBind" (PVar "n") PWild (PVar "loc") PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "unsignedRow") (EVar "m")) (EVar "signed")) (EVar "seen")) (EVar "pub")) (EVar "n")) (EVar "loc")))
(DTypeSig false "unsignedRow" (TyFun (TyCon "String") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyApp (TyCon "List") (TyCon "IndexRow")))))))))
(DFunDef false "unsignedRow" ((PVar "m") (PVar "signed") (PVar "seen") (PVar "pub") (PVar "name") (PVar "loc")) (EIf (EBinOp "||" (EApp (EApp (EVar "has") (EVar "name")) (EVar "signed")) (EApp (EApp (EVar "has") (EVar "name")) (EVar "seen"))) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "name")) (ELit LUnit)) (EVar "seen"))) (DoExpr (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "name")) (EVar "RkValue")) (EVar "NoSig")) (ELit (LString ""))) (EListLit)) (ELit (LInt 0))) (EVar "pub")) (EApp (EVar "Some") (EVar "loc")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "stripTy" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "stripTy" ((PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) true)) (ERecordCreate "TyCon" ((fa "tyConName" (EVar "n")) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "o")))))
(DFunDef false "stripTy" ((PCon "TyVar" (PVar "v"))) (EApp (EVar "TyVar") (EVar "v")))
(DFunDef false "stripTy" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyApp") (EApp (EVar "stripTy") (EVar "a"))) (EApp (EVar "stripTy") (EVar "b"))))
(DFunDef false "stripTy" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyFun") (EApp (EVar "stripTy") (EVar "a"))) (EApp (EVar "stripTy") (EVar "b"))))
(DFunDef false "stripTy" ((PCon "TyTuple" (PVar "ts"))) (EApp (EVar "TyTuple") (EApp (EApp (EVar "map") (EVar "stripTy")) (EVar "ts"))))
(DFunDef false "stripTy" ((PCon "TyEffect" (PVar "atoms") (PVar "vs") (PVar "t"))) (EApp (EApp (EApp (EVar "TyEffect") (EVar "atoms")) (EVar "vs")) (EApp (EVar "stripTy") (EVar "t"))))
(DFunDef false "stripTy" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EApp (EVar "TyConstrained") (EVar "cs")) (EApp (EVar "stripTy") (EVar "t"))))
(DFunDef false "stripTy" ((PCon "TyNamed" (PVar "n") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "TyNamed") (EVar "n")) (EApp (EVar "stripTy") (EVar "t"))) (EVar "e")))
(DFunDef false "stripTy" ((PCon "TyQual" (PVar "t") (PVar "ps") PWild)) (EApp (EApp (EApp (EVar "TyQual") (EApp (EVar "stripTy") (EVar "t"))) (EVar "ps")) (EVar "None")))
(DFunDef false "stripTy" ((PCon "TyRow" (PVar "atoms") (PVar "vs") PWild)) (EApp (EApp (EApp (EVar "TyRow") (EVar "atoms")) (EVar "vs")) (EVar "None")))
(DFunDef false "stripTy" ((PCon "TyAuth" (PVar "ps") PWild)) (EApp (EApp (EVar "TyAuth") (EVar "ps")) (EVar "None")))
(DTypeSig true "exportedRows" (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyApp (TyCon "List") (TyCon "IndexRow"))))
(DFunDef false "exportedRows" ((PVar "rows")) (EApp (EApp (EVar "filterList") (EVar "rowIsExported")) (EVar "rows")))
(DTypeSig false "rowIsExported" (TyFun (TyCon "IndexRow") (TyCon "Bool")))
(DFunDef false "rowIsExported" ((PVar "r")) (EFieldAccess (EVar "r") "ixrExported"))
(DTypeSig false "kindTag" (TyFun (TyCon "RowKind") (TyCon "String")))
(DFunDef false "kindTag" ((PCon "RkValue")) (ELit (LString "v")))
(DFunDef false "kindTag" ((PCon "RkCtor")) (ELit (LString "c")))
(DFunDef false "kindTag" ((PCon "RkType")) (ELit (LString "t")))
(DFunDef false "kindTag" ((PCon "RkIface")) (ELit (LString "i")))
(DFunDef false "kindTag" ((PCon "RkMethod")) (ELit (LString "m")))
(DTypeSig false "kindOfTag" (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "RowKind"))))
(DFunDef false "kindOfTag" ((PLit (LInt 118))) (EApp (EVar "Some") (EVar "RkValue")))
(DFunDef false "kindOfTag" ((PLit (LInt 99))) (EApp (EVar "Some") (EVar "RkCtor")))
(DFunDef false "kindOfTag" ((PLit (LInt 116))) (EApp (EVar "Some") (EVar "RkType")))
(DFunDef false "kindOfTag" ((PLit (LInt 105))) (EApp (EVar "Some") (EVar "RkIface")))
(DFunDef false "kindOfTag" ((PLit (LInt 109))) (EApp (EVar "Some") (EVar "RkMethod")))
(DFunDef false "kindOfTag" (PWild) (EVar "None"))
(DTypeSig false "slotText" (TyFun (TyCon "SigSlot") (TyCon "String")))
(DFunDef false "slotText" ((PCon "NoSig")) (ELit (LString "()")))
(DFunDef false "slotText" ((PCon "SigVal" (PVar "t"))) (EApp (EVar "renderSExp") (EApp (EVar "SList") (EListLit (EApp (EVar "sexpTy") (EVar "t"))))))
(DFunDef false "slotText" ((PCon "SigRaw" (PVar "text"))) (EVar "text"))
(DTypeSig false "rowKeyText" (TyFun (TyCon "IndexRow") (TyCon "String")))
(DFunDef false "rowKeyText" ((PVar "r")) (EApp (EApp (EVar "joinWith") (ELit (LString "\t"))) (EListLit (EFieldAccess (EVar "r") "ixrModule") (EFieldAccess (EVar "r") "ixrName") (EApp (EVar "kindTag") (EFieldAccess (EVar "r") "ixrKind")) (EApp (EVar "slotText") (EFieldAccess (EVar "r") "ixrSig")) (EFieldAccess (EVar "r") "ixrParent") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EFieldAccess (EVar "r") "ixrFields")) (EApp (EVar "intToString") (EFieldAccess (EVar "r") "ixrArity")) (EIf (EFieldAccess (EVar "r") "ixrExported") (ELit (LString "t")) (ELit (LString "f"))))))
(DTypeSig true "rowsDigest" (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyCon "String")))
(DFunDef false "rowsDigest" ((PVar "rows")) (EBlock (DoLet false false (PVar "joined") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EVar "sortBy") (EVar "stringCompare")) (EApp (EApp (EVar "map") (EVar "rowKeyText")) (EVar "rows"))))) (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "joined"))) (DoLet false false (PVar "lane2") (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EVar "hashString") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EVar "n")) (EVar "joined"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "hashString") (EVar "joined")))) (ELit (LString "."))) (EApp (EVar "display") (EVar "lane2"))) (ELit (LString "."))) (EApp (EVar "display") (EVar "n"))) (ELit (LString ""))))))
(DTypeSig false "rowFormatVersion" (TyCon "Int"))
(DFunDef false "rowFormatVersion" () (ELit (LInt 1)))
(DTypeSig false "sexpOptLoc" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "SExp")))
(DFunDef false "sexpOptLoc" ((PCon "None")) (EApp (EVar "SList") (EListLit)))
(DFunDef false "sexpOptLoc" ((PCon "Some" (PCon "Loc" PWild (PVar "a") (PVar "b") (PVar "c") (PVar "d")))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "a"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "b"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "c"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "d"))))))
(DTypeSig false "readOptLoc" (TyFun (TyCon "String") (TyFun (TyCon "SexpCursor") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "readOptLoc" ((PVar "path") (PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoExpr (EIf (EApp (EVar "isCloseByte") (EApp (EVar "cursorPeek") (EVar "cur"))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoExpr (EVar "None"))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "b") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "c") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "d") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "path")) (EVar "a")) (EVar "b")) (EVar "c")) (EVar "d")))))))))
(DTypeSig true "encodeRowShard" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyCon "String")))))))
(DFunDef false "encodeRowShard" ((PVar "stamp") (PVar "path") (PVar "hash") (PVar "modId") (PVar "rows")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renderShard") (EVar "stamp")) (EVar "path")) (EVar "hash")) (EVar "modId")) (EApp (EVar "rowsDigest") (EVar "rows"))) (EApp (EApp (EVar "map") (EVar "rowText")) (EVar "rows"))))
(DTypeSig false "rowText" (TyFun (TyCon "IndexRow") (TyCon "String")))
(DFunDef false "rowText" ((PVar "r")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EVar "quoted") (EFieldAccess (EVar "r") "ixrName")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "kindTag") (EFieldAccess (EVar "r") "ixrKind")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "slotText") (EFieldAccess (EVar "r") "ixrSig")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "quoted") (EFieldAccess (EVar "r") "ixrParent")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "renderSExp") (EApp (EVar "SList") (EApp (EApp (EVar "map") (EVar "SAtom")) (EFieldAccess (EVar "r") "ixrFields")))))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "intToString") (EFieldAccess (EVar "r") "ixrArity")))) (ELit (LString " "))) (EApp (EVar "display") (EIf (EFieldAccess (EVar "r") "ixrExported") (ELit (LString "t")) (ELit (LString "f"))))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "renderSExp") (EApp (EVar "sexpOptLoc") (EFieldAccess (EVar "r") "ixrLoc"))))) (ELit (LString ")"))))
(DTypeSig false "renderShard" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))))
(DFunDef false "renderShard" ((PVar "stamp") (PVar "path") (PVar "hash") (PVar "modId") (PVar "digest") (PVar "rowTexts")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EVar "display") (EApp (EVar "intToString") (EVar "rowFormatVersion")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "quoted") (EVar "stamp")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "quoted") (EVar "path")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "quoted") (EVar "hash")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "quoted") (EVar "modId")))) (ELit (LString " "))) (EApp (EVar "display") (EApp (EVar "quoted") (EVar "digest")))) (ELit (LString " ("))) (EApp (EVar "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "rowTexts")))) (ELit (LString "))"))))
(DTypeSig false "quoted" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoted" ((PVar "s")) (EApp (EVar "renderSExp") (EApp (EVar "SAtom") (EVar "s"))))
(DTypeSig false "readBoolTF" (TyFun (TyCon "SexpCursor") (TyCon "Bool")))
(DFunDef false "readBoolTF" ((PVar "cur")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "cursorChar") (EVar "cur"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LInt 116))) (EVar "True") (EIf (EBinOp "==" (EVar "c") (ELit (LInt 102))) (EVar "False") (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "False")))))))
(DTypeSig false "readSlot" (TyFun (TyCon "SexpCursor") (TyCon "SigSlot")))
(DFunDef false "readSlot" ((PVar "cur")) (EBlock (DoLet false false (PVar "text") (EApp (EVar "cursorSkipText") (EVar "cur"))) (DoExpr (EIf (EBinOp "==" (EVar "text") (ELit (LString "()"))) (EVar "NoSig") (EApp (EVar "SigRaw") (EVar "text"))))))
(DTypeSig false "readRow" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "SexpCursor") (TyCon "IndexRow")))))
(DFunDef false "readRow" ((PVar "path") (PVar "m") (PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "n") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "k") (EMatch (EApp (EVar "kindOfTag") (EApp (EVar "cursorChar") (EVar "cur"))) (arm (PCon "Some" (PVar "kk")) () (EVar "kk")) (arm (PCon "None") () (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "RkValue"))))) (DoLet false false (PVar "sig") (EApp (EVar "readSlot") (EVar "cur"))) (DoLet false false (PVar "parent") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "fields") (EApp (EApp (EVar "cursorList") (EVar "cursorAtom")) (EVar "cur"))) (DoLet false false (PVar "arity") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "exp") (EApp (EVar "readBoolTF") (EVar "cur"))) (DoLet false false (PVar "loc") (EApp (EApp (EVar "readOptLoc") (EVar "path")) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "n")) (EVar "k")) (EVar "sig")) (EVar "parent")) (EVar "fields")) (EVar "arity")) (EVar "exp")) (EVar "loc")))))
(DTypeSig false "readOptTy" (TyFun (TyCon "SexpCursor") (TyApp (TyCon "Option") (TyCon "Ty"))))
(DFunDef false "readOptTy" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoExpr (EIf (EApp (EVar "isCloseByte") (EApp (EVar "cursorPeek") (EVar "cur"))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoExpr (EVar "None"))) (EBlock (DoLet false false (PVar "t") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EVar "Some") (EVar "t"))))))))
(DTypeSig true "decodeRowShard" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "IndexRow")))))))))
(DFunDef false "decodeRowShard" ((PVar "stamp") (PVar "path") (PVar "hash") (PVar "text")) (EBlock (DoLet false false (PVar "cur") (EApp (EVar "cursorOf") (EVar "text"))) (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "st") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "p") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "h") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "cursorFailed") (EVar "cur")) (EBinOp "/=" (EVar "v") (EVar "rowFormatVersion"))) (EBinOp "/=" (EVar "st") (EVar "stamp"))) (EBinOp "/=" (EVar "p") (EVar "path"))) (EBinOp "/=" (EVar "h") (EVar "hash"))) (EVar "None") (EBlock (DoLet false false (PVar "m") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "digest") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "rows") (EApp (EApp (EVar "cursorList") (EApp (EApp (EVar "readRow") (EVar "path")) (EVar "m"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "cursorFailed") (EVar "cur")) (EApp (EVar "not") (EApp (EVar "cursorAtEnd") (EVar "cur")))) (EVar "None") (EApp (EVar "Some") (ETuple (EVar "m") (EVar "digest") (EVar "rows"))))))))))
(DTypeSig true "indexCacheDir" (TyCon "String"))
(DFunDef false "indexCacheDir" () (ELit (LString "lint-index")))
(DTypeSig true "stdlibShardDir" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "stdlibShardDir" (PWild) (EBlock (DoLet false false (PVar "xdg") (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EVar "getEnv") (ELit (LString "XDG_CACHE_HOME"))))) (DoLet false false (PVar "home") (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EVar "getEnv") (ELit (LString "HOME"))))) (DoExpr (EIf (EBinOp "/=" (EVar "xdg") (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "xdg"))) (ELit (LString "/medaka/"))) (EApp (EVar "display") (EVar "indexCacheDir"))) (ELit (LString ""))) (EIf (EBinOp "/=" (EVar "home") (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "home"))) (ELit (LString "/.cache/medaka/"))) (EApp (EVar "display") (EVar "indexCacheDir"))) (ELit (LString ""))) (ELit (LString "")))))))
(DTypeSig true "projectShardDir" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "projectShardDir" ((PVar "root")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "root"))) (ELit (LString "/.medaka/"))) (EApp (EVar "display") (EVar "indexCacheDir"))) (ELit (LString ""))))
(DTypeSig true "rowShardPath" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "rowShardPath" ((PVar "dir") (PVar "path")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EVar "display") (EApp (EApp (EVar "lastSegment") (ELit (LString ""))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "path"))))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "intToString") (EApp (EVar "hashString") (EVar "path"))))) (ELit (LString ".sx"))))
(DTypeSig false "lastSegment" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "lastSegment" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "lastSegment" (PWild (PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EVar "lastSegment") (EVar "x")) (EVar "rest")))
(DTypeSig true "rowContentHash" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "rowContentHash" ((PVar "src")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "hashString") (EVar "src")))) (ELit (LString "."))) (EApp (EVar "display") (EApp (EVar "stringLength") (EVar "src")))) (ELit (LString ""))))
(DTypeSig true "fileRows" (TyFun (TyCon "Bool") (TyFun (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyTuple (TyCon "String") (TyCon "ParseError"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "IndexRow"))))))))))))
(DFunDef false "fileRows" ((PVar "exportedOnly") (PVar "parse") (PVar "dir") (PVar "stamp") (PVar "modId") (PVar "path")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" PWild) () (EApp (EVar "Ok") (ETuple (ELit (LString "")) (EListLit)))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PVar "hash") (EApp (EVar "rowContentHash") (EVar "src"))) (DoLet false false (PVar "shardStamp") (EIf (EVar "exportedOnly") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "stamp"))) (ELit (LString "/x"))) (EVar "stamp"))) (DoLet false false (PVar "sp") (EApp (EApp (EVar "rowShardPath") (EVar "dir")) (EVar "path"))) (DoLet false false (PVar "cached") (EIf (EBinOp "==" (EVar "dir") (ELit (LString ""))) (EVar "None") (EMatch (EApp (EVar "readFile") (EVar "sp")) (arm (PCon "Ok" (PVar "text")) () (EApp (EApp (EApp (EApp (EVar "decodeRowShard") (EVar "shardStamp")) (EVar "path")) (EVar "hash")) (EVar "text"))) (arm (PCon "Err" PWild) () (EVar "None"))))) (DoExpr (EMatch (EVar "cached") (arm (PCon "Some" (PTuple PWild (PVar "digest") (PVar "rows"))) () (EApp (EVar "Ok") (ETuple (EVar "digest") (EVar "rows")))) (arm (PCon "None") () (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (ETuple (EVar "src") (EVar "e")))) (arm (PCon "Ok" (PTuple (PVar "decls") PWild)) () (EBlock (DoLet false false (PVar "all") (EApp (EApp (EVar "map") (EApp (EVar "atPath") (EVar "path"))) (EApp (EApp (EVar "rowsOfDecls") (EVar "modId")) (EVar "decls")))) (DoLet false false (PVar "rows") (EIf (EVar "exportedOnly") (EApp (EVar "exportedRows") (EVar "all")) (EVar "all"))) (DoLet false false PWild (EIf (EBinOp "==" (EVar "dir") (ELit (LString ""))) (ELit LUnit) (EApp (EApp (EApp (EVar "writeShard") (EVar "dir")) (EVar "sp")) (EApp (EApp (EApp (EApp (EApp (EVar "encodeRowShard") (EVar "shardStamp")) (EVar "path")) (EVar "hash")) (EVar "modId")) (EVar "rows"))))) (DoExpr (EApp (EVar "Ok") (ETuple (EApp (EVar "rowsDigest") (EVar "rows")) (EVar "rows"))))))))))))))
(DTypeSig false "atPath" (TyFun (TyCon "String") (TyFun (TyCon "IndexRow") (TyCon "IndexRow"))))
(DFunDef false "atPath" ((PVar "path") (PVar "r")) (EMatch (EFieldAccess (EVar "r") "ixrLoc") (arm (PCon "Some" (PCon "Loc" PWild (PVar "a") (PVar "b") (PVar "c") (PVar "d"))) () (ERecordUpdate (EVar "r") ((fa "ixrLoc" (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "path")) (EVar "a")) (EVar "b")) (EVar "c")) (EVar "d"))))))) (arm (PCon "None") () (EVar "r"))))
(DTypeSig false "writeShard" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "writeShard" ((PVar "dir") (PVar "sp") (PVar "text")) (EBlock (DoLet false false PWild (EApp (EVar "makeDirs") (EVar "dir"))) (DoLet false false (PVar "tmp") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "sp"))) (ELit (LString ".tmp")))) (DoExpr (EMatch (EApp (EApp (EVar "writeFile") (EVar "tmp")) (EVar "text")) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "rename") (EVar "tmp")) (EVar "sp")) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" PWild) () (ELit LUnit))))))))
(DTypeSig false "makeDirs" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "makeDirs" ((PVar "dir")) (EBlock (DoLet false false (PVar "parts") (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "dir"))) (DoExpr (EApp (EApp (EVar "makeDirsGo") (ELit (LString ""))) (EVar "parts")))))
(DTypeSig false "makeDirsGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "makeDirsGo" (PWild (PList)) (ELit LUnit))
(DFunDef false "makeDirsGo" ((PVar "acc") (PCons (PVar "p") (PVar "rest"))) (EIf (EBinOp "==" (EVar "p") (ELit (LString ""))) (EApp (EApp (EVar "makeDirsGo") (EVar "acc")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "next") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EVar "acc"))) (ELit (LString "/"))) (EApp (EVar "display") (EVar "p"))) (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "makeDir") (EVar "next"))) (DoExpr (EApp (EApp (EVar "makeDirsGo") (EVar "next")) (EVar "rest")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DData Private "IndexScope" () ((variant "IndexScope" (ConNamed (field "ixsByName" (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "IndexRow")))) (field "ixsRows" (TyApp (TyCon "List") (TyCon "IndexRow"))) (field "ixsNames" (TyApp (TyCon "List") (TyCon "String"))) (field "ixsModules" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DData Public "ProjectIndex" () ((variant "ProjectIndex" (ConPos (TyCon "IndexScope") (TyCon "IndexScope")))) ())
(DTypeSig false "emptyScope" (TyCon "IndexScope"))
(DFunDef false "emptyScope" () (ERecordCreate "IndexScope" ((fa "ixsByName" (EApp (EVar "new") (ELit LUnit))) (fa "ixsRows" (EListLit)) (fa "ixsNames" (EListLit)) (fa "ixsModules" (EListLit)))))
(DTypeSig true "emptyProjectIndex" (TyCon "ProjectIndex"))
(DFunDef false "emptyProjectIndex" () (EApp (EApp (EVar "ProjectIndex") (EVar "emptyScope")) (EVar "emptyScope")))
(DTypeSig true "mkProjectIndex" (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyCon "ProjectIndex"))))
(DFunDef false "mkProjectIndex" ((PVar "stdlibRows") (PVar "projectRows")) (EApp (EApp (EVar "ProjectIndex") (EApp (EVar "mkScope") (EVar "stdlibRows"))) (EApp (EVar "mkScope") (EVar "projectRows"))))
(DTypeSig false "mkScope" (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyCon "IndexScope")))
(DFunDef false "mkScope" ((PVar "rows")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "groupInto") (EApp (EApp (EVar "reverseRows") (EVar "rows")) (EListLit))) (EVar "m"))) (DoLet false false (PVar "signed") (EApp (EApp (EVar "filterList") (EVar "isExportedSigValue")) (EVar "rows"))) (DoExpr (ERecordCreate "IndexScope" ((fa "ixsByName" (EVar "m")) (fa "ixsRows" (EVar "rows")) (fa "ixsNames" (EApp (EVar "sortedUnique") (EApp (EApp (EVar "map") (EVar "rowName")) (EVar "signed")))) (fa "ixsModules" (EApp (EVar "sortedUnique") (EApp (EApp (EVar "map") (EVar "rowModule")) (EVar "signed")))))))))
(DTypeSig false "isExportedSigValue" (TyFun (TyCon "IndexRow") (TyCon "Bool")))
(DFunDef false "isExportedSigValue" ((PVar "r")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "r") "ixrKind") (EVar "RkValue")) (EFieldAccess (EVar "r") "ixrExported")) (EApp (EVar "rowHasSig") (EVar "r"))))
(DTypeSig false "rowName" (TyFun (TyCon "IndexRow") (TyCon "String")))
(DFunDef false "rowName" ((PVar "r")) (EFieldAccess (EVar "r") "ixrName"))
(DTypeSig false "rowModule" (TyFun (TyCon "IndexRow") (TyCon "String")))
(DFunDef false "rowModule" ((PVar "r")) (EFieldAccess (EVar "r") "ixrModule"))
(DTypeSig false "reverseRows" (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyApp (TyCon "List") (TyCon "IndexRow")))))
(DFunDef false "reverseRows" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseRows" ((PCons (PVar "r") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "reverseRows") (EVar "rest")) (EBinOp "::" (EVar "r") (EVar "acc"))))
(DTypeSig false "groupInto" (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "IndexRow"))) (TyCon "Unit"))))
(DFunDef false "groupInto" ((PList) PWild) (ELit LUnit))
(DFunDef false "groupInto" ((PCons (PVar "r") (PVar "rest")) (PVar "m")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EFieldAccess (EVar "r") "ixrName")) (EBinOp "::" (EVar "r") (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EFieldAccess (EVar "r") "ixrName")) (EVar "m")))) (EVar "m"))) (DoExpr (EApp (EApp (EVar "groupInto") (EVar "rest")) (EVar "m")))))
(DTypeSig false "sortedUnique" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "sortedUnique" ((PVar "xs")) (EApp (EVar "dropRepeats") (EApp (EApp (EVar "sortBy") (EVar "stringCompare")) (EVar "xs"))))
(DTypeSig false "dropRepeats" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dropRepeats" ((PList)) (EListLit))
(DFunDef false "dropRepeats" ((PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "dropRepeats" ((PCons (PVar "a") (PCons (PVar "b") (PVar "rest")))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EApp (EVar "dropRepeats") (EBinOp "::" (EVar "b") (EVar "rest"))) (EBinOp "::" (EVar "a") (EApp (EVar "dropRepeats") (EBinOp "::" (EVar "b") (EVar "rest"))))))
(DTypeSig false "scopeNamed" (TyFun (TyCon "IndexScope") (TyFun (TyCon "Ns") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "IndexRow"))))))
(DFunDef false "scopeNamed" ((PVar "s") (PVar "ns") (PVar "name")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EBinOp "==" (EApp (EVar "rowNs") (EFieldAccess (EVar "r") "ixrKind")) (EVar "ns")))) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "name")) (EFieldAccess (EVar "s") "ixsByName"))))
(DTypeSig true "rowsNamed" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "Ns") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "IndexRow"))))))
(DFunDef false "rowsNamed" ((PCon "ProjectIndex" (PVar "std") (PVar "proj")) (PVar "ns") (PVar "name")) (EBinOp "++" (EApp (EApp (EApp (EVar "scopeNamed") (EVar "proj")) (EVar "ns")) (EVar "name")) (EApp (EApp (EApp (EVar "scopeNamed") (EVar "std")) (EVar "ns")) (EVar "name"))))
(DTypeSig true "stdlibRowsNamed" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "Ns") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "IndexRow"))))))
(DFunDef false "stdlibRowsNamed" ((PCon "ProjectIndex" (PVar "std") PWild) (PVar "ns") (PVar "name")) (EApp (EApp (EApp (EVar "scopeNamed") (EVar "std")) (EVar "ns")) (EVar "name")))
(DTypeSig true "projectRowsNamed" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "Ns") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "IndexRow"))))))
(DFunDef false "projectRowsNamed" ((PCon "ProjectIndex" PWild (PVar "proj")) (PVar "ns") (PVar "name")) (EApp (EApp (EApp (EVar "scopeNamed") (EVar "proj")) (EVar "ns")) (EVar "name")))
(DTypeSig true "rowsIn" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "String") (TyFun (TyCon "Ns") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "IndexRow")))))))
(DFunDef false "rowsIn" ((PVar "idx") (PVar "modId") (PVar "ns") (PVar "name")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EBinOp "==" (EFieldAccess (EVar "r") "ixrModule") (EVar "modId")))) (EApp (EApp (EApp (EVar "rowsNamed") (EVar "idx")) (EVar "ns")) (EVar "name"))))
(DTypeSig true "rowsOfModule" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "IndexRow")))))
(DFunDef false "rowsOfModule" ((PCon "ProjectIndex" (PVar "std") (PVar "proj")) (PVar "modId")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EBinOp "==" (EFieldAccess (EVar "r") "ixrModule") (EVar "modId")))) (EBinOp "++" (EFieldAccess (EVar "proj") "ixsRows") (EFieldAccess (EVar "std") "ixsRows"))))
(DTypeSig true "stdlibRows" (TyFun (TyCon "ProjectIndex") (TyApp (TyCon "List") (TyCon "IndexRow"))))
(DFunDef false "stdlibRows" ((PCon "ProjectIndex" (PVar "std") PWild)) (EFieldAccess (EVar "std") "ixsRows"))
(DTypeSig true "projectRows" (TyFun (TyCon "ProjectIndex") (TyApp (TyCon "List") (TyCon "IndexRow"))))
(DFunDef false "projectRows" ((PCon "ProjectIndex" PWild (PVar "proj"))) (EFieldAccess (EVar "proj") "ixsRows"))
(DTypeSig true "stdlibValueNames" (TyFun (TyCon "ProjectIndex") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "stdlibValueNames" ((PCon "ProjectIndex" (PVar "std") PWild)) (EFieldAccess (EVar "std") "ixsNames"))
(DTypeSig true "stdlibValueModules" (TyFun (TyCon "ProjectIndex") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "stdlibValueModules" ((PCon "ProjectIndex" (PVar "std") PWild)) (EFieldAccess (EVar "std") "ixsModules"))
(DTypeSig true "indexKnowsModule" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "indexKnowsModule" ((PCon "ProjectIndex" (PVar "std") (PVar "proj")) (PVar "modId")) (EBinOp "||" (EApp (EApp (EVar "anyList") (ELam ((PVar "r")) (EBinOp "==" (EFieldAccess (EVar "r") "ixrModule") (EVar "modId")))) (EFieldAccess (EVar "proj") "ixsRows")) (EApp (EApp (EVar "anyList") (ELam ((PVar "r")) (EBinOp "==" (EFieldAccess (EVar "r") "ixrModule") (EVar "modId")))) (EFieldAccess (EVar "std") "ixsRows"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Loc" true) (mem "Ty" true) (mem "Decl" true) (mem "DataVis" true) (mem "Variant" true) (mem "ConPayload" true) (mem "Field" true) (mem "IfaceMethod" true) (mem "ExternDecl" true) (mem "LetBind" true) (mem "tyConUnresolved" false))))
(DUse false (UseGroup ("frontend" "ast_codec") ((mem "sexpTy" false) (mem "readTy" false))))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "SexpCursor" false) (mem "renderSExp" false) (mem "cursorOf" false) (mem "cursorFailed" false) (mem "cursorAtEnd" false) (mem "cursorOpen" false) (mem "cursorClose" false) (mem "cursorInt" false) (mem "cursorAtom" false) (mem "cursorChar" false) (mem "cursorList" false) (mem "cursorPeek" false) (mem "cursorAdvance" false) (mem "cursorFail" false) (mem "cursorSkipText" false) (mem "isCloseByte" false))))
(DUse false (UseGroup ("support" "util") ((mem "joinWith" false) (mem "splitOnChar" false) (mem "listLen" false) (mem "filterList" false) (mem "anyList" false))))
(DUse false (UseGroup ("hash_map") ((mem "HashMap" false) (mem "new" false) (mem "setInPlace" false) (mem "has" false) (mem "findWithDefault" false))))
(DUse false (UseGroup ("list") ((mem "sortBy" false))))
(DUse false (UseGroup ("frontend" "parser") ((mem "Positions" false) (mem "ParseError" false))))
(DData Public "RowKind" () ((variant "RkValue" (ConPos)) (variant "RkCtor" (ConPos)) (variant "RkType" (ConPos)) (variant "RkIface" (ConPos)) (variant "RkMethod" (ConPos))) ())
(DImpl true "Eq" ((TyCon "RowKind")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "RkValue") (PCon "RkValue")) () (EVar "True")) (arm (PTuple (PCon "RkCtor") (PCon "RkCtor")) () (EVar "True")) (arm (PTuple (PCon "RkType") (PCon "RkType")) () (EVar "True")) (arm (PTuple (PCon "RkIface") (PCon "RkIface")) () (EVar "True")) (arm (PTuple (PCon "RkMethod") (PCon "RkMethod")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "Ns" () ((variant "NsValue" (ConPos)) (variant "NsType" (ConPos))) ())
(DImpl true "Eq" ((TyCon "Ns")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PCon "NsValue") (PCon "NsValue")) () (EVar "True")) (arm (PTuple (PCon "NsType") (PCon "NsType")) () (EVar "True")) (arm (PTuple PWild PWild) () (EVar "False"))))))
(DData Public "SigSlot" () ((variant "NoSig" (ConPos)) (variant "SigVal" (ConPos (TyCon "Ty"))) (variant "SigRaw" (ConPos (TyCon "String")))) ())
(DData Public "IndexRow" () ((variant "IndexRow" (ConNamed (field "ixrModule" (TyCon "String")) (field "ixrName" (TyCon "String")) (field "ixrKind" (TyCon "RowKind")) (field "ixrSig" (TyCon "SigSlot")) (field "ixrParent" (TyCon "String")) (field "ixrFields" (TyApp (TyCon "List") (TyCon "String"))) (field "ixrArity" (TyCon "Int")) (field "ixrExported" (TyCon "Bool")) (field "ixrLoc" (TyApp (TyCon "Option") (TyCon "Loc")))))) ())
(DTypeSig true "rowNs" (TyFun (TyCon "RowKind") (TyCon "Ns")))
(DFunDef false "rowNs" ((PCon "RkValue")) (EVar "NsValue"))
(DFunDef false "rowNs" ((PCon "RkCtor")) (EVar "NsValue"))
(DFunDef false "rowNs" ((PCon "RkMethod")) (EVar "NsValue"))
(DFunDef false "rowNs" ((PCon "RkType")) (EVar "NsType"))
(DFunDef false "rowNs" ((PCon "RkIface")) (EVar "NsType"))
(DTypeSig true "rowSig" (TyFun (TyCon "IndexRow") (TyApp (TyCon "Option") (TyCon "Ty"))))
(DFunDef false "rowSig" ((PVar "r")) (EApp (EVar "sigOfSlot") (EFieldAccess (EVar "r") "ixrSig")))
(DTypeSig false "sigOfSlot" (TyFun (TyCon "SigSlot") (TyApp (TyCon "Option") (TyCon "Ty"))))
(DFunDef false "sigOfSlot" ((PCon "NoSig")) (EVar "None"))
(DFunDef false "sigOfSlot" ((PCon "SigVal" (PVar "t"))) (EApp (EVar "Some") (EVar "t")))
(DFunDef false "sigOfSlot" ((PCon "SigRaw" (PVar "text"))) (EBlock (DoLet false false (PVar "cur") (EApp (EVar "cursorOf") (EVar "text"))) (DoLet false false (PVar "t") (EApp (EVar "readOptTy") (EVar "cur"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "cursorFailed") (EVar "cur")) (EApp (EVar "not") (EApp (EVar "cursorAtEnd") (EVar "cur")))) (EVar "None") (EVar "t")))))
(DTypeSig true "rowHasSig" (TyFun (TyCon "IndexRow") (TyCon "Bool")))
(DFunDef false "rowHasSig" ((PVar "r")) (EMatch (EFieldAccess (EVar "r") "ixrSig") (arm (PCon "NoSig") () (EVar "False")) (arm (PCon "SigVal" PWild) () (EVar "True")) (arm (PCon "SigRaw" PWild) () (EVar "True"))))
(DTypeSig false "mkRow" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "RowKind") (TyFun (TyCon "SigSlot") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Int") (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "IndexRow")))))))))))
(DFunDef false "mkRow" ((PVar "m") (PVar "n") (PVar "k") (PVar "sig") (PVar "parent") (PVar "fields") (PVar "arity") (PVar "exp") (PVar "loc")) (ERecordCreate "IndexRow" ((fa "ixrModule" (EVar "m")) (fa "ixrName" (EVar "n")) (fa "ixrKind" (EVar "k")) (fa "ixrSig" (EVar "sig")) (fa "ixrParent" (EVar "parent")) (fa "ixrFields" (EVar "fields")) (fa "ixrArity" (EVar "arity")) (fa "ixrExported" (EVar "exp")) (fa "ixrLoc" (EVar "loc")))))
(DTypeSig true "rowsOfDecls" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "IndexRow")))))
(DFunDef false "rowsOfDecls" ((PVar "modId") (PVar "decls")) (EBlock (DoLet false false (PVar "signed") (EApp (EVar "new") (ELit LUnit))) (DoLet false false (PVar "sigRows") (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EVar "sigRowsOf") (EVar "modId")) (EVar "signed"))) (EVar "decls"))) (DoLet false false (PVar "seen") (EApp (EVar "new") (ELit LUnit))) (DoExpr (EBinOp "++" (EVar "sigRows") (EApp (EApp (EDictApp "flatMap") (EApp (EApp (EApp (EVar "unsignedRowsOf") (EVar "modId")) (EVar "signed")) (EVar "seen"))) (EVar "decls"))))))
(DTypeSig false "sigOf" (TyFun (TyCon "Ty") (TyCon "SigSlot")))
(DFunDef false "sigOf" ((PVar "t")) (EApp (EVar "SigVal") (EApp (EVar "stripTy") (EVar "t"))))
(DTypeSig false "sigRowsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "IndexRow"))))))
(DFunDef false "sigRowsOf" ((PVar "m") (PVar "signed") (PCon "DTypeSig" (PVar "pub") (PVar "name") (PVar "ty") (PVar "loc"))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "name")) (ELit LUnit)) (EVar "signed"))) (DoExpr (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "name")) (EVar "RkValue")) (EApp (EVar "sigOf") (EVar "ty"))) (ELit (LString ""))) (EListLit)) (ELit (LInt 0))) (EVar "pub")) (EApp (EVar "Some") (EVar "loc")))))))
(DFunDef false "sigRowsOf" ((PVar "m") (PVar "signed") (PCon "DExtern" (PRec "ExternDecl" ((rf "edPub" (PVar "pub")) (rf "edName" (PVar "name")) (rf "edTy" (PVar "ty")) (rf "edLoc" (PVar "loc"))) true))) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "name")) (ELit LUnit)) (EVar "signed"))) (DoExpr (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "name")) (EVar "RkValue")) (EApp (EVar "sigOf") (EVar "ty"))) (ELit (LString ""))) (EListLit)) (ELit (LInt 0))) (EVar "pub")) (EApp (EVar "Some") (EVar "loc")))))))
(DFunDef false "sigRowsOf" ((PVar "m") (PVar "signed") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EVar "sigRowsOf") (EVar "m")) (EVar "signed")) (EVar "d")))
(DFunDef false "sigRowsOf" ((PVar "m") PWild (PRec "DData" ((rf "dataVis" (PVar "vis")) (rf "dataName" (PVar "name")) (rf "dataParams" (PVar "ps")) (rf "dataCtors" (PVar "ctors")) (rf "dataNameLoc" (PVar "loc"))) true)) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "name")) (EVar "RkType")) (EVar "NoSig")) (ELit (LString ""))) (EListLit)) (EApp (EVar "listLen") (EVar "ps"))) (EApp (EVar "visExported") (EVar "vis"))) (EVar "loc")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EApp (EApp (EVar "ctorRow") (EVar "m")) (EVar "name")) (EVar "ps")) (EApp (EVar "isPublicVis") (EVar "vis"))) (EVar "loc"))) (EVar "ctors"))))
(DFunDef false "sigRowsOf" ((PVar "m") PWild (PRec "DNewtype" ((rf "newtypePub" (PVar "pub")) (rf "newtypeName" (PVar "name")) (rf "newtypeParams" (PVar "ps")) (rf "newtypeCtor" (PVar "c")) (rf "newtypeFieldTy" (PVar "fty")) (rf "newtypeNameLoc" (PVar "loc"))) true)) (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "name")) (EVar "RkType")) (EVar "NoSig")) (ELit (LString ""))) (EListLit)) (EApp (EVar "listLen") (EVar "ps"))) (EVar "pub")) (EVar "loc")) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "c")) (EVar "RkCtor")) (EApp (EVar "sigOf") (EApp (EApp (EVar "TyFun") (EVar "fty")) (EApp (EApp (EVar "resultTy") (EVar "name")) (EVar "ps"))))) (EVar "name")) (EListLit)) (ELit (LInt 1))) (EVar "pub")) (EVar "loc"))))
(DFunDef false "sigRowsOf" ((PVar "m") PWild (PRec "DTypeAlias" ((rf "tyAliasPub" (PVar "pub")) (rf "tyAliasName" (PVar "name")) (rf "tyAliasParams" (PVar "ps")) (rf "tyAliasRhs" (PVar "rhs")) (rf "tyAliasNameLoc" (PVar "loc"))) true)) (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "name")) (EVar "RkType")) (EApp (EVar "sigOf") (EVar "rhs"))) (ELit (LString ""))) (EListLit)) (EApp (EVar "listLen") (EVar "ps"))) (EVar "pub")) (EVar "loc"))))
(DFunDef false "sigRowsOf" ((PVar "m") PWild (PRec "DInterface" ((rf "pub" (PVar "pub")) (rf "name" (PVar "name")) (rf "typarams" (PVar "ps")) (rf "methods" (PVar "ms")) (rf "ifaceNameLoc" (PVar "loc"))) true)) (EBinOp "::" (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "name")) (EVar "RkIface")) (EVar "NoSig")) (ELit (LString ""))) (EListLit)) (EApp (EVar "listLen") (EVar "ps"))) (EVar "pub")) (EVar "loc")) (EApp (EApp (EMethodRef "map") (EApp (EApp (EApp (EVar "methodRow") (EVar "m")) (EVar "name")) (EVar "pub"))) (EVar "ms"))))
(DFunDef false "sigRowsOf" (PWild PWild PWild) (EListLit))
(DTypeSig false "isPublicVis" (TyFun (TyCon "DataVis") (TyCon "Bool")))
(DFunDef false "isPublicVis" ((PCon "VisPublic")) (EVar "True"))
(DFunDef false "isPublicVis" ((PCon "VisAbstract")) (EVar "False"))
(DFunDef false "isPublicVis" ((PCon "VisPrivate")) (EVar "False"))
(DTypeSig false "visExported" (TyFun (TyCon "DataVis") (TyCon "Bool")))
(DFunDef false "visExported" ((PCon "VisPrivate")) (EVar "False"))
(DFunDef false "visExported" ((PCon "VisAbstract")) (EVar "True"))
(DFunDef false "visExported" ((PCon "VisPublic")) (EVar "True"))
(DTypeSig false "resultTy" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty"))))
(DFunDef false "resultTy" ((PVar "name") (PVar "params")) (EApp (EApp (EVar "applyVars") (EApp (EApp (EVar "tyConUnresolved") (EVar "name")) (EVar "None"))) (EVar "params")))
(DTypeSig false "applyVars" (TyFun (TyCon "Ty") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "Ty"))))
(DFunDef false "applyVars" ((PVar "t") (PList)) (EVar "t"))
(DFunDef false "applyVars" ((PVar "t") (PCons (PVar "p") (PVar "rest"))) (EApp (EApp (EVar "applyVars") (EApp (EApp (EVar "TyApp") (EVar "t")) (EApp (EVar "TyVar") (EVar "p")))) (EVar "rest")))
(DTypeSig false "funTy" (TyFun (TyApp (TyCon "List") (TyCon "Ty")) (TyFun (TyCon "Ty") (TyCon "Ty"))))
(DFunDef false "funTy" ((PList) (PVar "result")) (EVar "result"))
(DFunDef false "funTy" ((PCons (PVar "t") (PVar "rest")) (PVar "result")) (EApp (EApp (EVar "TyFun") (EVar "t")) (EApp (EApp (EVar "funTy") (EVar "rest")) (EVar "result"))))
(DTypeSig false "ctorRow" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyFun (TyCon "Bool") (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyFun (TyCon "Variant") (TyCon "IndexRow"))))))))
(DFunDef false "ctorRow" ((PVar "m") (PVar "parent") (PVar "ps") (PVar "exp") (PVar "loc") (PCon "Variant" (PVar "c") (PCon "ConPos" (PVar "tys")))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "c")) (EVar "RkCtor")) (EApp (EVar "sigOf") (EApp (EApp (EVar "funTy") (EVar "tys")) (EApp (EApp (EVar "resultTy") (EVar "parent")) (EVar "ps"))))) (EVar "parent")) (EListLit)) (EApp (EVar "listLen") (EVar "tys"))) (EVar "exp")) (EVar "loc")))
(DFunDef false "ctorRow" ((PVar "m") (PVar "parent") (PVar "ps") (PVar "exp") (PVar "loc") (PCon "Variant" (PVar "c") (PCon "ConNamed" (PVar "fields") PWild))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "c")) (EVar "RkCtor")) (EApp (EVar "sigOf") (EApp (EApp (EVar "funTy") (EApp (EApp (EMethodRef "map") (EVar "fieldTy")) (EVar "fields"))) (EApp (EApp (EVar "resultTy") (EVar "parent")) (EVar "ps"))))) (EVar "parent")) (EApp (EApp (EMethodRef "map") (EVar "fieldName")) (EVar "fields"))) (EApp (EVar "listLen") (EVar "fields"))) (EVar "exp")) (EVar "loc")))
(DTypeSig false "fieldTy" (TyFun (TyCon "Field") (TyCon "Ty")))
(DFunDef false "fieldTy" ((PCon "Field" PWild (PVar "t"))) (EVar "t"))
(DTypeSig false "fieldName" (TyFun (TyCon "Field") (TyCon "String")))
(DFunDef false "fieldName" ((PCon "Field" (PVar "n") PWild)) (EVar "n"))
(DTypeSig false "methodRow" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "Bool") (TyFun (TyCon "IfaceMethod") (TyCon "IndexRow"))))))
(DFunDef false "methodRow" ((PVar "m") (PVar "iface") (PVar "pub") (PCon "IfaceMethod" (PVar "n") (PVar "ty") PWild (PVar "loc"))) (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "n")) (EVar "RkMethod")) (EApp (EVar "sigOf") (EVar "ty"))) (EVar "iface")) (EListLit)) (ELit (LInt 0))) (EVar "pub")) (EVar "loc")))
(DTypeSig false "unsignedRowsOf" (TyFun (TyCon "String") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "Decl") (TyApp (TyCon "List") (TyCon "IndexRow")))))))
(DFunDef false "unsignedRowsOf" ((PVar "m") (PVar "signed") (PVar "seen") (PCon "DFunDef" (PVar "pub") (PVar "name") PWild PWild (PVar "loc") PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "unsignedRow") (EVar "m")) (EVar "signed")) (EVar "seen")) (EVar "pub")) (EVar "name")) (EVar "loc")))
(DFunDef false "unsignedRowsOf" ((PVar "m") (PVar "signed") (PVar "seen") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EDictApp "flatMap") (ELam ((PVar "b")) (EApp (EApp (EApp (EApp (EApp (EVar "letRow") (EVar "m")) (EVar "signed")) (EVar "seen")) (EVar "pub")) (EVar "b")))) (EVar "binds")))
(DFunDef false "unsignedRowsOf" ((PVar "m") (PVar "signed") (PVar "seen") (PCon "DAttrib" PWild (PVar "d"))) (EApp (EApp (EApp (EApp (EVar "unsignedRowsOf") (EVar "m")) (EVar "signed")) (EVar "seen")) (EVar "d")))
(DFunDef false "unsignedRowsOf" (PWild PWild PWild PWild) (EListLit))
(DTypeSig false "letRow" (TyFun (TyCon "String") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyCon "LetBind") (TyApp (TyCon "List") (TyCon "IndexRow"))))))))
(DFunDef false "letRow" ((PVar "m") (PVar "signed") (PVar "seen") (PVar "pub") (PCon "LetBind" (PVar "n") PWild (PVar "loc") PWild)) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "unsignedRow") (EVar "m")) (EVar "signed")) (EVar "seen")) (EVar "pub")) (EVar "n")) (EVar "loc")))
(DTypeSig false "unsignedRow" (TyFun (TyCon "String") (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyCon "Unit")) (TyFun (TyCon "Bool") (TyFun (TyCon "String") (TyFun (TyCon "Loc") (TyApp (TyCon "List") (TyCon "IndexRow")))))))))
(DFunDef false "unsignedRow" ((PVar "m") (PVar "signed") (PVar "seen") (PVar "pub") (PVar "name") (PVar "loc")) (EIf (EBinOp "||" (EApp (EApp (EVar "has") (EVar "name")) (EVar "signed")) (EApp (EApp (EVar "has") (EVar "name")) (EVar "seen"))) (EListLit) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EVar "name")) (ELit LUnit)) (EVar "seen"))) (DoExpr (EListLit (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "name")) (EVar "RkValue")) (EVar "NoSig")) (ELit (LString ""))) (EListLit)) (ELit (LInt 0))) (EVar "pub")) (EApp (EVar "Some") (EVar "loc")))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "stripTy" (TyFun (TyCon "Ty") (TyCon "Ty")))
(DFunDef false "stripTy" ((PRec "TyCon" ((rf "tyConName" (PVar "n")) (rf "tyConOrigin" (PVar "o"))) true)) (ERecordCreate "TyCon" ((fa "tyConName" (EVar "n")) (fa "tyConLoc" (EVar "None")) (fa "tyConOrigin" (EVar "o")))))
(DFunDef false "stripTy" ((PCon "TyVar" (PVar "v"))) (EApp (EVar "TyVar") (EVar "v")))
(DFunDef false "stripTy" ((PCon "TyApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyApp") (EApp (EVar "stripTy") (EVar "a"))) (EApp (EVar "stripTy") (EVar "b"))))
(DFunDef false "stripTy" ((PCon "TyFun" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "TyFun") (EApp (EVar "stripTy") (EVar "a"))) (EApp (EVar "stripTy") (EVar "b"))))
(DFunDef false "stripTy" ((PCon "TyTuple" (PVar "ts"))) (EApp (EVar "TyTuple") (EApp (EApp (EMethodRef "map") (EVar "stripTy")) (EVar "ts"))))
(DFunDef false "stripTy" ((PCon "TyEffect" (PVar "atoms") (PVar "vs") (PVar "t"))) (EApp (EApp (EApp (EVar "TyEffect") (EVar "atoms")) (EVar "vs")) (EApp (EVar "stripTy") (EVar "t"))))
(DFunDef false "stripTy" ((PCon "TyConstrained" (PVar "cs") (PVar "t"))) (EApp (EApp (EVar "TyConstrained") (EVar "cs")) (EApp (EVar "stripTy") (EVar "t"))))
(DFunDef false "stripTy" ((PCon "TyNamed" (PVar "n") (PVar "t") (PVar "e"))) (EApp (EApp (EApp (EVar "TyNamed") (EVar "n")) (EApp (EVar "stripTy") (EVar "t"))) (EVar "e")))
(DFunDef false "stripTy" ((PCon "TyQual" (PVar "t") (PVar "ps") PWild)) (EApp (EApp (EApp (EVar "TyQual") (EApp (EVar "stripTy") (EVar "t"))) (EVar "ps")) (EVar "None")))
(DFunDef false "stripTy" ((PCon "TyRow" (PVar "atoms") (PVar "vs") PWild)) (EApp (EApp (EApp (EVar "TyRow") (EVar "atoms")) (EVar "vs")) (EVar "None")))
(DFunDef false "stripTy" ((PCon "TyAuth" (PVar "ps") PWild)) (EApp (EApp (EVar "TyAuth") (EVar "ps")) (EVar "None")))
(DTypeSig true "exportedRows" (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyApp (TyCon "List") (TyCon "IndexRow"))))
(DFunDef false "exportedRows" ((PVar "rows")) (EApp (EApp (EVar "filterList") (EVar "rowIsExported")) (EVar "rows")))
(DTypeSig false "rowIsExported" (TyFun (TyCon "IndexRow") (TyCon "Bool")))
(DFunDef false "rowIsExported" ((PVar "r")) (EFieldAccess (EVar "r") "ixrExported"))
(DTypeSig false "kindTag" (TyFun (TyCon "RowKind") (TyCon "String")))
(DFunDef false "kindTag" ((PCon "RkValue")) (ELit (LString "v")))
(DFunDef false "kindTag" ((PCon "RkCtor")) (ELit (LString "c")))
(DFunDef false "kindTag" ((PCon "RkType")) (ELit (LString "t")))
(DFunDef false "kindTag" ((PCon "RkIface")) (ELit (LString "i")))
(DFunDef false "kindTag" ((PCon "RkMethod")) (ELit (LString "m")))
(DTypeSig false "kindOfTag" (TyFun (TyCon "Int") (TyApp (TyCon "Option") (TyCon "RowKind"))))
(DFunDef false "kindOfTag" ((PLit (LInt 118))) (EApp (EVar "Some") (EVar "RkValue")))
(DFunDef false "kindOfTag" ((PLit (LInt 99))) (EApp (EVar "Some") (EVar "RkCtor")))
(DFunDef false "kindOfTag" ((PLit (LInt 116))) (EApp (EVar "Some") (EVar "RkType")))
(DFunDef false "kindOfTag" ((PLit (LInt 105))) (EApp (EVar "Some") (EVar "RkIface")))
(DFunDef false "kindOfTag" ((PLit (LInt 109))) (EApp (EVar "Some") (EVar "RkMethod")))
(DFunDef false "kindOfTag" (PWild) (EVar "None"))
(DTypeSig false "slotText" (TyFun (TyCon "SigSlot") (TyCon "String")))
(DFunDef false "slotText" ((PCon "NoSig")) (ELit (LString "()")))
(DFunDef false "slotText" ((PCon "SigVal" (PVar "t"))) (EApp (EVar "renderSExp") (EApp (EVar "SList") (EListLit (EApp (EVar "sexpTy") (EVar "t"))))))
(DFunDef false "slotText" ((PCon "SigRaw" (PVar "text"))) (EVar "text"))
(DTypeSig false "rowKeyText" (TyFun (TyCon "IndexRow") (TyCon "String")))
(DFunDef false "rowKeyText" ((PVar "r")) (EApp (EApp (EVar "joinWith") (ELit (LString "\t"))) (EListLit (EFieldAccess (EVar "r") "ixrModule") (EFieldAccess (EVar "r") "ixrName") (EApp (EVar "kindTag") (EFieldAccess (EVar "r") "ixrKind")) (EApp (EVar "slotText") (EFieldAccess (EVar "r") "ixrSig")) (EFieldAccess (EVar "r") "ixrParent") (EApp (EApp (EVar "joinWith") (ELit (LString ","))) (EFieldAccess (EVar "r") "ixrFields")) (EApp (EVar "intToString") (EFieldAccess (EVar "r") "ixrArity")) (EIf (EFieldAccess (EVar "r") "ixrExported") (ELit (LString "t")) (ELit (LString "f"))))))
(DTypeSig true "rowsDigest" (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyCon "String")))
(DFunDef false "rowsDigest" ((PVar "rows")) (EBlock (DoLet false false (PVar "joined") (EApp (EApp (EVar "joinWith") (ELit (LString "\n"))) (EApp (EApp (EVar "sortBy") (EVar "stringCompare")) (EApp (EApp (EMethodRef "map") (EVar "rowKeyText")) (EVar "rows"))))) (DoLet false false (PVar "n") (EApp (EVar "stringLength") (EVar "joined"))) (DoLet false false (PVar "lane2") (EIf (EBinOp "==" (EVar "n") (ELit (LInt 0))) (ELit (LInt 0)) (EApp (EVar "hashString") (EApp (EApp (EApp (EVar "stringSlice") (ELit (LInt 1))) (EVar "n")) (EVar "joined"))))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "hashString") (EVar "joined")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "lane2"))) (ELit (LString "."))) (EApp (EMethodRef "display") (EVar "n"))) (ELit (LString ""))))))
(DTypeSig false "rowFormatVersion" (TyCon "Int"))
(DFunDef false "rowFormatVersion" () (ELit (LInt 1)))
(DTypeSig false "sexpOptLoc" (TyFun (TyApp (TyCon "Option") (TyCon "Loc")) (TyCon "SExp")))
(DFunDef false "sexpOptLoc" ((PCon "None")) (EApp (EVar "SList") (EListLit)))
(DFunDef false "sexpOptLoc" ((PCon "Some" (PCon "Loc" PWild (PVar "a") (PVar "b") (PVar "c") (PVar "d")))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "a"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "b"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "c"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "d"))))))
(DTypeSig false "readOptLoc" (TyFun (TyCon "String") (TyFun (TyCon "SexpCursor") (TyApp (TyCon "Option") (TyCon "Loc")))))
(DFunDef false "readOptLoc" ((PVar "path") (PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoExpr (EIf (EApp (EVar "isCloseByte") (EApp (EVar "cursorPeek") (EVar "cur"))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoExpr (EVar "None"))) (EBlock (DoLet false false (PVar "a") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "b") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "c") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "d") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "path")) (EVar "a")) (EVar "b")) (EVar "c")) (EVar "d")))))))))
(DTypeSig true "encodeRowShard" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyCon "String")))))))
(DFunDef false "encodeRowShard" ((PVar "stamp") (PVar "path") (PVar "hash") (PVar "modId") (PVar "rows")) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "renderShard") (EVar "stamp")) (EVar "path")) (EMethodRef "hash")) (EVar "modId")) (EApp (EVar "rowsDigest") (EVar "rows"))) (EApp (EApp (EMethodRef "map") (EVar "rowText")) (EVar "rows"))))
(DTypeSig false "rowText" (TyFun (TyCon "IndexRow") (TyCon "String")))
(DFunDef false "rowText" ((PVar "r")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EVar "quoted") (EFieldAccess (EVar "r") "ixrName")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "kindTag") (EFieldAccess (EVar "r") "ixrKind")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "slotText") (EFieldAccess (EVar "r") "ixrSig")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "quoted") (EFieldAccess (EVar "r") "ixrParent")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "renderSExp") (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (EVar "SAtom")) (EFieldAccess (EVar "r") "ixrFields")))))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EFieldAccess (EVar "r") "ixrArity")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EIf (EFieldAccess (EVar "r") "ixrExported") (ELit (LString "t")) (ELit (LString "f"))))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "renderSExp") (EApp (EVar "sexpOptLoc") (EFieldAccess (EVar "r") "ixrLoc"))))) (ELit (LString ")"))))
(DTypeSig false "renderShard" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))))))
(DFunDef false "renderShard" ((PVar "stamp") (PVar "path") (PVar "hash") (PVar "modId") (PVar "digest") (PVar "rowTexts")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "(")) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EVar "rowFormatVersion")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "quoted") (EVar "stamp")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "quoted") (EVar "path")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "quoted") (EMethodRef "hash")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "quoted") (EVar "modId")))) (ELit (LString " "))) (EApp (EMethodRef "display") (EApp (EVar "quoted") (EVar "digest")))) (ELit (LString " ("))) (EApp (EMethodRef "display") (EApp (EApp (EVar "joinWith") (ELit (LString " "))) (EVar "rowTexts")))) (ELit (LString "))"))))
(DTypeSig false "quoted" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "quoted" ((PVar "s")) (EApp (EVar "renderSExp") (EApp (EVar "SAtom") (EVar "s"))))
(DTypeSig false "readBoolTF" (TyFun (TyCon "SexpCursor") (TyCon "Bool")))
(DFunDef false "readBoolTF" ((PVar "cur")) (EBlock (DoLet false false (PVar "c") (EApp (EVar "cursorChar") (EVar "cur"))) (DoExpr (EIf (EBinOp "==" (EVar "c") (ELit (LInt 116))) (EVar "True") (EIf (EBinOp "==" (EVar "c") (ELit (LInt 102))) (EVar "False") (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "False")))))))
(DTypeSig false "readSlot" (TyFun (TyCon "SexpCursor") (TyCon "SigSlot")))
(DFunDef false "readSlot" ((PVar "cur")) (EBlock (DoLet false false (PVar "text") (EApp (EVar "cursorSkipText") (EVar "cur"))) (DoExpr (EIf (EBinOp "==" (EVar "text") (ELit (LString "()"))) (EVar "NoSig") (EApp (EVar "SigRaw") (EVar "text"))))))
(DTypeSig false "readRow" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "SexpCursor") (TyCon "IndexRow")))))
(DFunDef false "readRow" ((PVar "path") (PVar "m") (PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "n") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "k") (EMatch (EApp (EVar "kindOfTag") (EApp (EVar "cursorChar") (EVar "cur"))) (arm (PCon "Some" (PVar "kk")) () (EVar "kk")) (arm (PCon "None") () (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "RkValue"))))) (DoLet false false (PVar "sig") (EApp (EVar "readSlot") (EVar "cur"))) (DoLet false false (PVar "parent") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "fields") (EApp (EApp (EVar "cursorList") (EVar "cursorAtom")) (EVar "cur"))) (DoLet false false (PVar "arity") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "exp") (EApp (EVar "readBoolTF") (EVar "cur"))) (DoLet false false (PVar "loc") (EApp (EApp (EVar "readOptLoc") (EVar "path")) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EApp (EVar "mkRow") (EVar "m")) (EVar "n")) (EVar "k")) (EVar "sig")) (EVar "parent")) (EVar "fields")) (EVar "arity")) (EVar "exp")) (EVar "loc")))))
(DTypeSig false "readOptTy" (TyFun (TyCon "SexpCursor") (TyApp (TyCon "Option") (TyCon "Ty"))))
(DFunDef false "readOptTy" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoExpr (EIf (EApp (EVar "isCloseByte") (EApp (EVar "cursorPeek") (EVar "cur"))) (EBlock (DoLet false false PWild (EApp (EVar "cursorAdvance") (EVar "cur"))) (DoExpr (EVar "None"))) (EBlock (DoLet false false (PVar "t") (EApp (EVar "readTy") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EVar "Some") (EVar "t"))))))))
(DTypeSig true "decodeRowShard" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String") (TyApp (TyCon "List") (TyCon "IndexRow")))))))))
(DFunDef false "decodeRowShard" ((PVar "stamp") (PVar "path") (PVar "hash") (PVar "text")) (EBlock (DoLet false false (PVar "cur") (EApp (EVar "cursorOf") (EVar "text"))) (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "v") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false (PVar "st") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "p") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "h") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoExpr (EIf (EBinOp "||" (EBinOp "||" (EBinOp "||" (EBinOp "||" (EApp (EVar "cursorFailed") (EVar "cur")) (EBinOp "/=" (EVar "v") (EVar "rowFormatVersion"))) (EBinOp "/=" (EVar "st") (EVar "stamp"))) (EBinOp "/=" (EVar "p") (EVar "path"))) (EBinOp "/=" (EVar "h") (EMethodRef "hash"))) (EVar "None") (EBlock (DoLet false false (PVar "m") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "digest") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "rows") (EApp (EApp (EVar "cursorList") (EApp (EApp (EVar "readRow") (EVar "path")) (EVar "m"))) (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EIf (EBinOp "||" (EApp (EVar "cursorFailed") (EVar "cur")) (EApp (EVar "not") (EApp (EVar "cursorAtEnd") (EVar "cur")))) (EVar "None") (EApp (EVar "Some") (ETuple (EVar "m") (EVar "digest") (EVar "rows"))))))))))
(DTypeSig true "indexCacheDir" (TyCon "String"))
(DFunDef false "indexCacheDir" () (ELit (LString "lint-index")))
(DTypeSig true "stdlibShardDir" (TyFun (TyCon "Unit") (TyEffect ("IO") None (TyCon "String"))))
(DFunDef false "stdlibShardDir" (PWild) (EBlock (DoLet false false (PVar "xdg") (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EVar "getEnv") (ELit (LString "XDG_CACHE_HOME"))))) (DoLet false false (PVar "home") (EApp (EApp (EVar "optionOr") (ELit (LString ""))) (EApp (EVar "getEnv") (ELit (LString "HOME"))))) (DoExpr (EIf (EBinOp "/=" (EVar "xdg") (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "xdg"))) (ELit (LString "/medaka/"))) (EApp (EMethodRef "display") (EVar "indexCacheDir"))) (ELit (LString ""))) (EIf (EBinOp "/=" (EVar "home") (ELit (LString ""))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "home"))) (ELit (LString "/.cache/medaka/"))) (EApp (EMethodRef "display") (EVar "indexCacheDir"))) (ELit (LString ""))) (ELit (LString "")))))))
(DTypeSig true "projectShardDir" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "projectShardDir" ((PVar "root")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "root"))) (ELit (LString "/.medaka/"))) (EApp (EMethodRef "display") (EVar "indexCacheDir"))) (ELit (LString ""))))
(DTypeSig true "rowShardPath" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyCon "String"))))
(DFunDef false "rowShardPath" ((PVar "dir") (PVar "path")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "dir"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EApp (EApp (EVar "lastSegment") (ELit (LString ""))) (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "path"))))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "intToString") (EApp (EVar "hashString") (EVar "path"))))) (ELit (LString ".sx"))))
(DTypeSig false "lastSegment" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyCon "String"))))
(DFunDef false "lastSegment" ((PVar "acc") (PList)) (EVar "acc"))
(DFunDef false "lastSegment" (PWild (PCons (PVar "x") (PVar "rest"))) (EApp (EApp (EVar "lastSegment") (EVar "x")) (EVar "rest")))
(DTypeSig true "rowContentHash" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "rowContentHash" ((PVar "src")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "hashString") (EVar "src")))) (ELit (LString "."))) (EApp (EMethodRef "display") (EApp (EVar "stringLength") (EVar "src")))) (ELit (LString ""))))
(DTypeSig true "fileRows" (TyFun (TyCon "Bool") (TyFun (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "ParseError")) (TyTuple (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Positions")))) (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyApp (TyApp (TyCon "Result") (TyTuple (TyCon "String") (TyCon "ParseError"))) (TyTuple (TyCon "String") (TyApp (TyCon "List") (TyCon "IndexRow"))))))))))))
(DFunDef false "fileRows" ((PVar "exportedOnly") (PVar "parse") (PVar "dir") (PVar "stamp") (PVar "modId") (PVar "path")) (EMatch (EApp (EVar "readFile") (EVar "path")) (arm (PCon "Err" PWild) () (EApp (EVar "Ok") (ETuple (ELit (LString "")) (EListLit)))) (arm (PCon "Ok" (PVar "src")) () (EBlock (DoLet false false (PVar "hash") (EApp (EVar "rowContentHash") (EVar "src"))) (DoLet false false (PVar "shardStamp") (EIf (EVar "exportedOnly") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "stamp"))) (ELit (LString "/x"))) (EVar "stamp"))) (DoLet false false (PVar "sp") (EApp (EApp (EVar "rowShardPath") (EVar "dir")) (EVar "path"))) (DoLet false false (PVar "cached") (EIf (EBinOp "==" (EVar "dir") (ELit (LString ""))) (EVar "None") (EMatch (EApp (EVar "readFile") (EVar "sp")) (arm (PCon "Ok" (PVar "text")) () (EApp (EApp (EApp (EApp (EVar "decodeRowShard") (EVar "shardStamp")) (EVar "path")) (EMethodRef "hash")) (EVar "text"))) (arm (PCon "Err" PWild) () (EVar "None"))))) (DoExpr (EMatch (EVar "cached") (arm (PCon "Some" (PTuple PWild (PVar "digest") (PVar "rows"))) () (EApp (EVar "Ok") (ETuple (EVar "digest") (EVar "rows")))) (arm (PCon "None") () (EMatch (EApp (EVar "parse") (EVar "src")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "Err") (ETuple (EVar "src") (EVar "e")))) (arm (PCon "Ok" (PTuple (PVar "decls") PWild)) () (EBlock (DoLet false false (PVar "all") (EApp (EApp (EMethodRef "map") (EApp (EVar "atPath") (EVar "path"))) (EApp (EApp (EVar "rowsOfDecls") (EVar "modId")) (EVar "decls")))) (DoLet false false (PVar "rows") (EIf (EVar "exportedOnly") (EApp (EVar "exportedRows") (EDictApp "all")) (EDictApp "all"))) (DoLet false false PWild (EIf (EBinOp "==" (EVar "dir") (ELit (LString ""))) (ELit LUnit) (EApp (EApp (EApp (EVar "writeShard") (EVar "dir")) (EVar "sp")) (EApp (EApp (EApp (EApp (EApp (EVar "encodeRowShard") (EVar "shardStamp")) (EVar "path")) (EMethodRef "hash")) (EVar "modId")) (EVar "rows"))))) (DoExpr (EApp (EVar "Ok") (ETuple (EApp (EVar "rowsDigest") (EVar "rows")) (EVar "rows"))))))))))))))
(DTypeSig false "atPath" (TyFun (TyCon "String") (TyFun (TyCon "IndexRow") (TyCon "IndexRow"))))
(DFunDef false "atPath" ((PVar "path") (PVar "r")) (EMatch (EFieldAccess (EVar "r") "ixrLoc") (arm (PCon "Some" (PCon "Loc" PWild (PVar "a") (PVar "b") (PVar "c") (PVar "d"))) () (ERecordUpdate (EVar "r") ((fa "ixrLoc" (EApp (EVar "Some") (EApp (EApp (EApp (EApp (EApp (EVar "Loc") (EVar "path")) (EVar "a")) (EVar "b")) (EVar "c")) (EVar "d"))))))) (arm (PCon "None") () (EVar "r"))))
(DTypeSig false "writeShard" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))))
(DFunDef false "writeShard" ((PVar "dir") (PVar "sp") (PVar "text")) (EBlock (DoLet false false PWild (EApp (EVar "makeDirs") (EVar "dir"))) (DoLet false false (PVar "tmp") (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "sp"))) (ELit (LString ".tmp")))) (DoExpr (EMatch (EApp (EApp (EVar "writeFile") (EVar "tmp")) (EVar "text")) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" PWild) () (EMatch (EApp (EApp (EVar "rename") (EVar "tmp")) (EVar "sp")) (arm (PCon "Err" PWild) () (ELit LUnit)) (arm (PCon "Ok" PWild) () (ELit LUnit))))))))
(DTypeSig false "makeDirs" (TyFun (TyCon "String") (TyEffect ("IO") None (TyCon "Unit"))))
(DFunDef false "makeDirs" ((PVar "dir")) (EBlock (DoLet false false (PVar "parts") (EApp (EApp (EVar "splitOnChar") (ELit (LChar "/"))) (EVar "dir"))) (DoExpr (EApp (EApp (EVar "makeDirsGo") (ELit (LString ""))) (EVar "parts")))))
(DTypeSig false "makeDirsGo" (TyFun (TyCon "String") (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyEffect ("IO") None (TyCon "Unit")))))
(DFunDef false "makeDirsGo" (PWild (PList)) (ELit LUnit))
(DFunDef false "makeDirsGo" ((PVar "acc") (PCons (PVar "p") (PVar "rest"))) (EIf (EBinOp "==" (EVar "p") (ELit (LString ""))) (EApp (EApp (EVar "makeDirsGo") (EVar "acc")) (EVar "rest")) (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "next") (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EVar "acc"))) (ELit (LString "/"))) (EApp (EMethodRef "display") (EVar "p"))) (ELit (LString "")))) (DoLet false false PWild (EApp (EVar "makeDir") (EVar "next"))) (DoExpr (EApp (EApp (EVar "makeDirsGo") (EVar "next")) (EVar "rest")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DData Private "IndexScope" () ((variant "IndexScope" (ConNamed (field "ixsByName" (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "IndexRow")))) (field "ixsRows" (TyApp (TyCon "List") (TyCon "IndexRow"))) (field "ixsNames" (TyApp (TyCon "List") (TyCon "String"))) (field "ixsModules" (TyApp (TyCon "List") (TyCon "String")))))) ())
(DData Public "ProjectIndex" () ((variant "ProjectIndex" (ConPos (TyCon "IndexScope") (TyCon "IndexScope")))) ())
(DTypeSig false "emptyScope" (TyCon "IndexScope"))
(DFunDef false "emptyScope" () (ERecordCreate "IndexScope" ((fa "ixsByName" (EApp (EVar "new") (ELit LUnit))) (fa "ixsRows" (EListLit)) (fa "ixsNames" (EListLit)) (fa "ixsModules" (EListLit)))))
(DTypeSig true "emptyProjectIndex" (TyCon "ProjectIndex"))
(DFunDef false "emptyProjectIndex" () (EApp (EApp (EVar "ProjectIndex") (EVar "emptyScope")) (EVar "emptyScope")))
(DTypeSig true "mkProjectIndex" (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyCon "ProjectIndex"))))
(DFunDef false "mkProjectIndex" ((PVar "stdlibRows") (PVar "projectRows")) (EApp (EApp (EVar "ProjectIndex") (EApp (EVar "mkScope") (EVar "stdlibRows"))) (EApp (EVar "mkScope") (EVar "projectRows"))))
(DTypeSig false "mkScope" (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyCon "IndexScope")))
(DFunDef false "mkScope" ((PVar "rows")) (EBlock (DoLet false false (PVar "m") (EApp (EVar "new") (ELit LUnit))) (DoLet false false PWild (EApp (EApp (EVar "groupInto") (EApp (EApp (EVar "reverseRows") (EVar "rows")) (EListLit))) (EVar "m"))) (DoLet false false (PVar "signed") (EApp (EApp (EVar "filterList") (EVar "isExportedSigValue")) (EVar "rows"))) (DoExpr (ERecordCreate "IndexScope" ((fa "ixsByName" (EVar "m")) (fa "ixsRows" (EVar "rows")) (fa "ixsNames" (EApp (EVar "sortedUnique") (EApp (EApp (EMethodRef "map") (EVar "rowName")) (EVar "signed")))) (fa "ixsModules" (EApp (EVar "sortedUnique") (EApp (EApp (EMethodRef "map") (EVar "rowModule")) (EVar "signed")))))))))
(DTypeSig false "isExportedSigValue" (TyFun (TyCon "IndexRow") (TyCon "Bool")))
(DFunDef false "isExportedSigValue" ((PVar "r")) (EBinOp "&&" (EBinOp "&&" (EBinOp "==" (EFieldAccess (EVar "r") "ixrKind") (EVar "RkValue")) (EFieldAccess (EVar "r") "ixrExported")) (EApp (EVar "rowHasSig") (EVar "r"))))
(DTypeSig false "rowName" (TyFun (TyCon "IndexRow") (TyCon "String")))
(DFunDef false "rowName" ((PVar "r")) (EFieldAccess (EVar "r") "ixrName"))
(DTypeSig false "rowModule" (TyFun (TyCon "IndexRow") (TyCon "String")))
(DFunDef false "rowModule" ((PVar "r")) (EFieldAccess (EVar "r") "ixrModule"))
(DTypeSig false "reverseRows" (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyApp (TyCon "List") (TyCon "IndexRow")))))
(DFunDef false "reverseRows" ((PList) (PVar "acc")) (EVar "acc"))
(DFunDef false "reverseRows" ((PCons (PVar "r") (PVar "rest")) (PVar "acc")) (EApp (EApp (EVar "reverseRows") (EVar "rest")) (EBinOp "::" (EVar "r") (EVar "acc"))))
(DTypeSig false "groupInto" (TyFun (TyApp (TyCon "List") (TyCon "IndexRow")) (TyFun (TyApp (TyApp (TyCon "HashMap") (TyCon "String")) (TyApp (TyCon "List") (TyCon "IndexRow"))) (TyCon "Unit"))))
(DFunDef false "groupInto" ((PList) PWild) (ELit LUnit))
(DFunDef false "groupInto" ((PCons (PVar "r") (PVar "rest")) (PVar "m")) (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "setInPlace") (EFieldAccess (EVar "r") "ixrName")) (EBinOp "::" (EVar "r") (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EFieldAccess (EVar "r") "ixrName")) (EVar "m")))) (EVar "m"))) (DoExpr (EApp (EApp (EVar "groupInto") (EVar "rest")) (EVar "m")))))
(DTypeSig false "sortedUnique" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "sortedUnique" ((PVar "xs")) (EApp (EVar "dropRepeats") (EApp (EApp (EVar "sortBy") (EVar "stringCompare")) (EVar "xs"))))
(DTypeSig false "dropRepeats" (TyFun (TyApp (TyCon "List") (TyCon "String")) (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "dropRepeats" ((PList)) (EListLit))
(DFunDef false "dropRepeats" ((PList (PVar "x"))) (EListLit (EVar "x")))
(DFunDef false "dropRepeats" ((PCons (PVar "a") (PCons (PVar "b") (PVar "rest")))) (EIf (EBinOp "==" (EVar "a") (EVar "b")) (EApp (EVar "dropRepeats") (EBinOp "::" (EVar "b") (EVar "rest"))) (EBinOp "::" (EVar "a") (EApp (EVar "dropRepeats") (EBinOp "::" (EVar "b") (EVar "rest"))))))
(DTypeSig false "scopeNamed" (TyFun (TyCon "IndexScope") (TyFun (TyCon "Ns") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "IndexRow"))))))
(DFunDef false "scopeNamed" ((PVar "s") (PVar "ns") (PVar "name")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EBinOp "==" (EApp (EVar "rowNs") (EFieldAccess (EVar "r") "ixrKind")) (EVar "ns")))) (EApp (EApp (EApp (EVar "findWithDefault") (EListLit)) (EVar "name")) (EFieldAccess (EVar "s") "ixsByName"))))
(DTypeSig true "rowsNamed" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "Ns") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "IndexRow"))))))
(DFunDef false "rowsNamed" ((PCon "ProjectIndex" (PVar "std") (PVar "proj")) (PVar "ns") (PVar "name")) (EBinOp "++" (EApp (EApp (EApp (EVar "scopeNamed") (EVar "proj")) (EVar "ns")) (EVar "name")) (EApp (EApp (EApp (EVar "scopeNamed") (EVar "std")) (EVar "ns")) (EVar "name"))))
(DTypeSig true "stdlibRowsNamed" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "Ns") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "IndexRow"))))))
(DFunDef false "stdlibRowsNamed" ((PCon "ProjectIndex" (PVar "std") PWild) (PVar "ns") (PVar "name")) (EApp (EApp (EApp (EVar "scopeNamed") (EVar "std")) (EVar "ns")) (EVar "name")))
(DTypeSig true "projectRowsNamed" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "Ns") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "IndexRow"))))))
(DFunDef false "projectRowsNamed" ((PCon "ProjectIndex" PWild (PVar "proj")) (PVar "ns") (PVar "name")) (EApp (EApp (EApp (EVar "scopeNamed") (EVar "proj")) (EVar "ns")) (EVar "name")))
(DTypeSig true "rowsIn" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "String") (TyFun (TyCon "Ns") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "IndexRow")))))))
(DFunDef false "rowsIn" ((PVar "idx") (PVar "modId") (PVar "ns") (PVar "name")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EBinOp "==" (EFieldAccess (EVar "r") "ixrModule") (EVar "modId")))) (EApp (EApp (EApp (EVar "rowsNamed") (EVar "idx")) (EVar "ns")) (EVar "name"))))
(DTypeSig true "rowsOfModule" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "String") (TyApp (TyCon "List") (TyCon "IndexRow")))))
(DFunDef false "rowsOfModule" ((PCon "ProjectIndex" (PVar "std") (PVar "proj")) (PVar "modId")) (EApp (EApp (EVar "filterList") (ELam ((PVar "r")) (EBinOp "==" (EFieldAccess (EVar "r") "ixrModule") (EVar "modId")))) (EBinOp "++" (EFieldAccess (EVar "proj") "ixsRows") (EFieldAccess (EVar "std") "ixsRows"))))
(DTypeSig true "stdlibRows" (TyFun (TyCon "ProjectIndex") (TyApp (TyCon "List") (TyCon "IndexRow"))))
(DFunDef false "stdlibRows" ((PCon "ProjectIndex" (PVar "std") PWild)) (EFieldAccess (EVar "std") "ixsRows"))
(DTypeSig true "projectRows" (TyFun (TyCon "ProjectIndex") (TyApp (TyCon "List") (TyCon "IndexRow"))))
(DFunDef false "projectRows" ((PCon "ProjectIndex" PWild (PVar "proj"))) (EFieldAccess (EVar "proj") "ixsRows"))
(DTypeSig true "stdlibValueNames" (TyFun (TyCon "ProjectIndex") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "stdlibValueNames" ((PCon "ProjectIndex" (PVar "std") PWild)) (EFieldAccess (EVar "std") "ixsNames"))
(DTypeSig true "stdlibValueModules" (TyFun (TyCon "ProjectIndex") (TyApp (TyCon "List") (TyCon "String"))))
(DFunDef false "stdlibValueModules" ((PCon "ProjectIndex" (PVar "std") PWild)) (EFieldAccess (EVar "std") "ixsModules"))
(DTypeSig true "indexKnowsModule" (TyFun (TyCon "ProjectIndex") (TyFun (TyCon "String") (TyCon "Bool"))))
(DFunDef false "indexKnowsModule" ((PCon "ProjectIndex" (PVar "std") (PVar "proj")) (PVar "modId")) (EBinOp "||" (EApp (EApp (EVar "anyList") (ELam ((PVar "r")) (EBinOp "==" (EFieldAccess (EVar "r") "ixrModule") (EVar "modId")))) (EFieldAccess (EVar "proj") "ixsRows")) (EApp (EApp (EVar "anyList") (ELam ((PVar "r")) (EBinOp "==" (EFieldAccess (EVar "r") "ixrModule") (EVar "modId")))) (EFieldAccess (EVar "std") "ixsRows"))))
