# META
source_lines=374
stages=DESUGAR,MARK
# SOURCE
-- The prelude's elaborated trees as a value, an on-disk file and a process
-- cache.
--
-- `PreludeElab` is core after the tree arm's elaboration with no user module:
-- the dict-passed declarations, the evidence rows those trees reference, the
-- binder rows, and four counters.  Every id in it is core's own, so every
-- `EvId` and `BinderId` carries the module `""`.  A drive that takes the value
-- must start its id interners past the counters: `peEvCounter` is one past the
-- highest evidence ordinal the elaboration minted, `peLocalCounter` one past
-- the highest `$k$lb` local-abstraction suffix its trees hold, `peBinderCount`
-- the number of binder rows and `peBinderBase` the first binder ordinal (binder
-- ordinals are relocated by offset, never restored).
--
-- File grammar: the first line is the header, then three lines (declarations,
-- evidence rows, binder rows), each one list.
--   (medaka-elab <version> (sources ((<path> <hash>) ...)) (compiler <id>)
--     (counters <K> <L> <N> <B0>) (digest <hex>))
-- The digest is the SHA-256 of the bytes after the header line and is checked
-- before any of them is decoded, so a flipped or cut byte never reaches the
-- cursor.  The header's own fields are not under the digest: a flip there reads
-- as a different key (stale on comparison) or a refused header.  A binder row
-- is `(<id> <name> <type> (<type>?) <t|f>)`; an id of module `""` is its bare
-- ordinal, any other is `(<module> <ordinal>)`.
--
-- The body is never built as an `SExp`: the cursor readers of
-- `frontend.ast_codec` and the binder reader below take it off the bytes.

import frontend.ast.{BinderId(..), Decl, EvEntry(..), EvId(..)}
import frontend.ast_codec.{declsSExp, evEntriesSExp, readDecls, readEvEntries}
import list.{reverse}
import string as S
import support.sexp_value.{
  SExp(..), SexpError(..), SexpCursor, atomInt, cursorAtEnd, cursorAtom,
  cursorClose, cursorFail, cursorFailed, cursorInt, cursorList, cursorOf,
  cursorOffset, cursorOpen, cursorPeek, cursorChar, expectAtom, parseSExp,
  renderSExp
}
import support.util.{splitOnChar}
import types.evidence_coverage.{EvidenceFault(..), evidenceFaults}
import types.interface_sexp.{InterfaceFault(..), sha256Hex}
import types.prelude_interface.{InterfaceKey(..)}
import types.runtime_types.{
  BinderRow(..), RuntimeType(..), binderOrdinal, runtimeTypeName,
  runtimeTypeFromName
}

-- ── the value ───────────────────────────────────────────────────────────────

public export data PreludeElab = PreludeElab {
  peDecls : List Decl,
  peEvidence : List EvEntry,
  peBinders : List BinderRow,
  peEvCounter : Int,
  peLocalCounter : Int,
  peBinderCount : Int,
  peBinderBase : Int,
}

-- The value of an elaboration of core with no user module: [evidence] is the
-- whole published table, of which only the rows a tree references are kept.
-- The counters are read off the elaboration's own output.
export
preludeElabOf : List Decl -> List EvEntry -> List BinderRow -> PreludeElab
preludeElabOf decls evidence binders = PreludeElab {
  peDecls = decls,
  peEvidence = referencedRows decls evidence,
  peBinders = binders,
  peEvCounter = evidenceHighWater evidence,
  peLocalCounter = localHighWater (declsSExp decls),
  peBinderCount = length binders,
  peBinderBase = binderBase binders,
}

evidenceHighWater : List EvEntry -> Int
evidenceHighWater rows =
  fold (acc (EvEntry (EvId _ i) _) => max acc (i + 1)) 0 rows

binderBase : List BinderRow -> Int
binderBase [] = 0
binderBase (r :: rest) =
  fold (acc row => min acc (binderOrdinal row.brId)) (binderOrdinal r.brId) rest

-- A table with no row faults at every site its trees carry, so the faults name
-- exactly the ids the trees reference.
referencedRows : List Decl -> List EvEntry -> List EvEntry
referencedRows decls rows =
  let size = evidenceHighWater rows
  let marks = arrayMake size False
  let _ = markReferenced marks (evidenceFaults (Some (decls, [])) [])
  filter (isMarked marks) rows

markReferenced : Array Bool -> List EvidenceFault -> Unit
markReferenced _ [] = ()
markReferenced marks ((MissingEntry _ i _) :: rest) =
  let _ = if i >= 0 && i < arrayLength marks then arraySetUnsafe i True marks
  markReferenced marks rest
markReferenced marks (_ :: rest) = markReferenced marks rest

isMarked : Array Bool -> EvEntry -> Bool
isMarked marks (EvEntry (EvId _ i) _) =
  i >= 0 && i < arrayLength marks && arrayGetUnsafe i marks

-- One past the highest k of any `<name>$<k>$lb` atom.
localHighWater : SExp -> Int
localHighWater (SAtom s) = localSuffix s
localHighWater (SList items) =
  fold (acc n => max acc (localHighWater n)) 0 items

localSuffix : String -> Int
localSuffix s
  | S.endsWith "$lb" s = match reverse (splitOnChar '$' s)
    _ :: k :: _ => match stringToInt k
      Some n => n + 1
      None => 0
    _ => 0
  | otherwise = 0

-- ── the file ────────────────────────────────────────────────────────────────

export
formatVersion : Int
formatVersion = 1

-- The key an elaborated-trees file is validated against: the interface file's
-- key with this file's own format version.
export
elabKeyOf : InterfaceKey -> InterfaceKey
elabKeyOf key = InterfaceKey {
  ikFormat = formatVersion,
  ikSources = key.ikSources,
  ikCompiler = key.ikCompiler,
}

sexpBinderId : BinderId -> SExp
sexpBinderId (BinderId "" n) = SAtom (intToString n)
sexpBinderId (BinderId m n) = SList [SAtom m, SAtom (intToString n)]

sexpBinder : BinderRow -> SExp
sexpBinder row = SList [
  sexpBinderId row.brId,
  SAtom row.brName,
  SAtom (runtimeTypeName row.brType),
  SList
    (map
      (t => SAtom (runtimeTypeName t))
      (match row.brReturns
        Some t => [t]
        None => [])),
  SAtom (if row.brSigned then "t" else "f"),
]

binderLine : List BinderRow -> String
binderLine rows = renderSExp (SList (map sexpBinder rows))

headerNode : InterfaceKey -> PreludeElab -> String -> SExp
headerNode key pe digest = SList [
  SAtom "medaka-elab",
  SAtom (intToString formatVersion),
  SList [
    SAtom "sources",
    SList (map (s => SList [SAtom (fst s), SAtom (snd s)]) key.ikSources),
  ],
  SList [SAtom "compiler", SAtom key.ikCompiler],
  SList [
    SAtom "counters",
    SAtom (intToString pe.peEvCounter),
    SAtom (intToString pe.peLocalCounter),
    SAtom (intToString pe.peBinderCount),
    SAtom (intToString pe.peBinderBase),
  ],
  SList [SAtom "digest", SAtom digest],
]

bodyText : PreludeElab -> String
bodyText pe =
  "\{renderSExp (declsSExp pe.peDecls)}\n\{renderSExp (evEntriesSExp pe.peEvidence)}\n\{binderLine pe.peBinders}\n"

-- The whole file for [pe] under [key]; the key's own format field is not
-- written, the header always carries `formatVersion`.
export
encodeElabFile : InterfaceKey -> PreludeElab -> String
encodeElabFile key pe =
  let body = bodyText pe
  "\{renderSExp (headerNode key pe (sha256Hex body))}\n\{body}"

-- The digest a file's body has: the SHA-256 of the bytes after the first line.
export
elabDigestOf : String -> String
elabDigestOf text = match S.indexOf "\n" text
  Some i => sha256Hex (S.drop (i + 1) text)
  None => sha256Hex ""

export
renderElabFault : InterfaceFault -> String
renderElabFault (WrongFormat v) =
  "elaborated-trees format version \{v}, this compiler reads \{formatVersion}"
renderElabFault (Malformed e) = "\{e.sePath}: \{e.seWhat} (elaborated trees)"

refuse : String -> String -> Result InterfaceFault a
refuse path what =
  Err (Malformed SexpError { seOffset = 0, sePath = path, seWhat = what })

failure : SexpError -> Result InterfaceFault a
failure e = Err (Malformed e)

-- The version the header declares, when it declares one.
declaredVersion : SExp -> Option Int
declaredVersion (SList ((SAtom "medaka-elab") :: v :: _)) = match atomInt "" v
  Ok n => Some n
  Err _ => None
declaredVersion _ = None

-- The key, the four counters and the digest a header claims.
data Header = Header {
  hKey : InterfaceKey,
  hCounters : (Int, Int, Int, Int),
  hDigest : String,
}

headerOf : SExp -> Result SexpError Header
headerOf (SList [SAtom "medaka-elab", v, SList [SAtom "sources", srcs], SList [SAtom "compiler", c], SList [SAtom "counters", k, l, n, b], SList [SAtom "digest", d]]) =
  do
    version <- atomInt "header/version" v
    sources <- traverse sourceOf (listItems srcs)
    compiler <- expectAtom "header/compiler" c
    kk <- atomInt "header/counters" k
    ll <- atomInt "header/counters" l
    nn <- atomInt "header/counters" n
    bb <- atomInt "header/counters" b
    digest <- expectAtom "header/digest" d
    Ok Header {
      hKey = InterfaceKey {
        ikFormat = version,
        ikSources = sources,
        ikCompiler = compiler,
      },
      hCounters = (kk, ll, nn, bb),
      hDigest = digest,
    }
headerOf node = Err SexpError {
  seOffset = 0,
  sePath = "header",
  seWhat = "expected a medaka-elab header of five fields",
}

listItems : SExp -> List SExp
listItems (SList items) = items
listItems _ = []

sourceOf : SExp -> Result SexpError (String, String)
sourceOf (SList [SAtom p, SAtom h]) = Ok (p, h)
sourceOf _ = Err SexpError {
  seOffset = 0,
  sePath = "header/sources",
  seWhat = "expected a (path hash) pair",
}

readBinderId : SexpCursor -> BinderId
readBinderId cur =
  if cursorPeek cur == 40 then
    let _ = cursorOpen cur
    let m = cursorAtom cur
    let n = cursorInt cur
    let _ = cursorClose cur
    BinderId m n
  else
    BinderId "" (cursorInt cur)

readRuntimeType : SexpCursor -> RuntimeType
readRuntimeType cur = match runtimeTypeFromName (cursorAtom cur)
  Some t => t
  None => cursorFail cur RTValue

readBinder : SexpCursor -> BinderRow
readBinder cur =
  let _ = cursorOpen cur
  let bid = readBinderId cur
  let name = cursorAtom cur
  let ty = readRuntimeType cur
  let returns = match cursorList readRuntimeType cur
    [] => None
    [t] => Some t
    _ => cursorFail cur None
  let flag = cursorChar cur
  let signed =
    if flag == 116 then
      True
    else if flag == 102 then
      False
    else
      cursorFail cur False
  let _ = cursorClose cur
  BinderRow {
    brId = bid,
    brName = name,
    brType = ty,
    brReturns = returns,
    brSigned = signed,
  }

-- The value of a file, or why it is refused: the version first, then the
-- header, then the digest of the body, and only then the body.  The key is the
-- one the header carries.
export
readElabFile : String -> Result InterfaceFault (InterfaceKey, PreludeElab)
readElabFile text = match S.indexOf "\n" text
  None => refuse "file" "no header line"
  Some i => match parseSExp (S.take i text)
    Err e => failure e
    Ok node => match declaredVersion node
      Some v if v /= formatVersion => Err (WrongFormat v)
      _ => match headerOf node
        Err e => failure e
        Ok h =>
          let body = S.drop (i + 1) text
          if sha256Hex body /= h.hDigest then
            refuse "header/digest" "the body does not match the digest"
          else
            decodeBody h body

decodeBody : Header ->
  String ->
  Result InterfaceFault (InterfaceKey, PreludeElab)
decodeBody h body =
  let cur = cursorOf body
  match readDecls cur
    Err e => failure e
    Ok decls => match readEvEntries cur
      Err e => failure e
      Ok evidence =>
        let binders = cursorList readBinder cur
        if cursorFailed cur then
          refuse "binders" "malformed or truncated encoding"
        else if not (cursorAtEnd cur) then
          failure SexpError {
            seOffset = cursorOffset cur,
            sePath = "",
            seWhat = "trailing text after the binder rows",
          }
        else
          let (k, l, n, b) = h.hCounters
          if n /= length binders || b /= binderBase binders then
            refuse
              "header/counters"
              "the binder count or base disagrees with the rows"
          else
            Ok (
              h.hKey,
              PreludeElab {
                peDecls = decls,
                peEvidence = evidence,
                peBinders = binders,
                peEvCounter = k,
                peLocalCounter = l,
                peBinderCount = n,
                peBinderBase = b,
              },
            )

-- ── the process cache ───────────────────────────────────────────────────────

-- One value for one compiler generation, the pair `preludeCacheHit` keys by.
preludeElabCacheRef : Ref (Option ((Int, Int), PreludeElab))
preludeElabCacheRef = Ref None

export
seedPreludeElab : (Int, Int) -> PreludeElab -> Unit
seedPreludeElab generation pe = preludeElabCacheRef := Some (generation, pe)

export
preludeElabHit : (Int, Int) -> Option PreludeElab
preludeElabHit generation = match !preludeElabCacheRef
  Some (seen, pe) if seen == generation => Some pe
  _ => None
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "BinderId" true) (mem "Decl" false) (mem "EvEntry" true) (mem "EvId" true))))
(DUse false (UseGroup ("frontend" "ast_codec") ((mem "declsSExp" false) (mem "evEntriesSExp" false) (mem "readDecls" false) (mem "readEvEntries" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseAlias ("string") "S"))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "SexpError" true) (mem "SexpCursor" false) (mem "atomInt" false) (mem "cursorAtEnd" false) (mem "cursorAtom" false) (mem "cursorClose" false) (mem "cursorFail" false) (mem "cursorFailed" false) (mem "cursorInt" false) (mem "cursorList" false) (mem "cursorOf" false) (mem "cursorOffset" false) (mem "cursorOpen" false) (mem "cursorPeek" false) (mem "cursorChar" false) (mem "expectAtom" false) (mem "parseSExp" false) (mem "renderSExp" false))))
(DUse false (UseGroup ("support" "util") ((mem "splitOnChar" false))))
(DUse false (UseGroup ("types" "evidence_coverage") ((mem "EvidenceFault" true) (mem "evidenceFaults" false))))
(DUse false (UseGroup ("types" "interface_sexp") ((mem "InterfaceFault" true) (mem "sha256Hex" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "InterfaceKey" true))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" true) (mem "RuntimeType" true) (mem "binderOrdinal" false) (mem "runtimeTypeName" false) (mem "runtimeTypeFromName" false))))
(DData Public "PreludeElab" () ((variant "PreludeElab" (ConNamed (field "peDecls" (TyApp (TyCon "List") (TyCon "Decl"))) (field "peEvidence" (TyApp (TyCon "List") (TyCon "EvEntry"))) (field "peBinders" (TyApp (TyCon "List") (TyCon "BinderRow"))) (field "peEvCounter" (TyCon "Int")) (field "peLocalCounter" (TyCon "Int")) (field "peBinderCount" (TyCon "Int")) (field "peBinderBase" (TyCon "Int"))))) ())
(DTypeSig true "preludeElabOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "EvEntry")) (TyFun (TyApp (TyCon "List") (TyCon "BinderRow")) (TyCon "PreludeElab")))))
(DFunDef false "preludeElabOf" ((PVar "decls") (PVar "evidence") (PVar "binders")) (ERecordCreate "PreludeElab" ((fa "peDecls" (EVar "decls")) (fa "peEvidence" (EApp (EApp (EVar "referencedRows") (EVar "decls")) (EVar "evidence"))) (fa "peBinders" (EVar "binders")) (fa "peEvCounter" (EApp (EVar "evidenceHighWater") (EVar "evidence"))) (fa "peLocalCounter" (EApp (EVar "localHighWater") (EApp (EVar "declsSExp") (EVar "decls")))) (fa "peBinderCount" (EApp (EVar "length") (EVar "binders"))) (fa "peBinderBase" (EApp (EVar "binderBase") (EVar "binders"))))))
(DTypeSig false "evidenceHighWater" (TyFun (TyApp (TyCon "List") (TyCon "EvEntry")) (TyCon "Int")))
(DFunDef false "evidenceHighWater" ((PVar "rows")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild)) (EApp (EApp (EVar "max") (EVar "acc")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (ELit (LInt 0))) (EVar "rows")))
(DTypeSig false "binderBase" (TyFun (TyApp (TyCon "List") (TyCon "BinderRow")) (TyCon "Int")))
(DFunDef false "binderBase" ((PList)) (ELit (LInt 0)))
(DFunDef false "binderBase" ((PCons (PVar "r") (PVar "rest"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "row")) (EApp (EApp (EVar "min") (EVar "acc")) (EApp (EVar "binderOrdinal") (EFieldAccess (EVar "row") "brId"))))) (EApp (EVar "binderOrdinal") (EFieldAccess (EVar "r") "brId"))) (EVar "rest")))
(DTypeSig false "referencedRows" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "EvEntry")) (TyApp (TyCon "List") (TyCon "EvEntry")))))
(DFunDef false "referencedRows" ((PVar "decls") (PVar "rows")) (EBlock (DoLet false false (PVar "size") (EApp (EVar "evidenceHighWater") (EVar "rows"))) (DoLet false false (PVar "marks") (EApp (EApp (EVar "arrayMake") (EVar "size")) (EVar "False"))) (DoLet false false PWild (EApp (EApp (EVar "markReferenced") (EVar "marks")) (EApp (EApp (EVar "evidenceFaults") (EApp (EVar "Some") (ETuple (EVar "decls") (EListLit)))) (EListLit)))) (DoExpr (EApp (EApp (EVar "filter") (EApp (EVar "isMarked") (EVar "marks"))) (EVar "rows")))))
(DTypeSig false "markReferenced" (TyFun (TyApp (TyCon "Array") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyCon "Unit"))))
(DFunDef false "markReferenced" (PWild (PList)) (ELit LUnit))
(DFunDef false "markReferenced" ((PVar "marks") (PCons (PCon "MissingEntry" PWild (PVar "i") PWild) (PVar "rest"))) (EBlock (DoLet false false PWild (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "marks")))) (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "True")) (EVar "marks")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "markReferenced") (EVar "marks")) (EVar "rest")))))
(DFunDef false "markReferenced" ((PVar "marks") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "markReferenced") (EVar "marks")) (EVar "rest")))
(DTypeSig false "isMarked" (TyFun (TyApp (TyCon "Array") (TyCon "Bool")) (TyFun (TyCon "EvEntry") (TyCon "Bool"))))
(DFunDef false "isMarked" ((PVar "marks") (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild)) (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "marks")))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "marks"))))
(DTypeSig false "localHighWater" (TyFun (TyCon "SExp") (TyCon "Int")))
(DFunDef false "localHighWater" ((PCon "SAtom" (PVar "s"))) (EApp (EVar "localSuffix") (EVar "s")))
(DFunDef false "localHighWater" ((PCon "SList" (PVar "items"))) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "n")) (EApp (EApp (EVar "max") (EVar "acc")) (EApp (EVar "localHighWater") (EVar "n"))))) (ELit (LInt 0))) (EVar "items")))
(DTypeSig false "localSuffix" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "localSuffix" ((PVar "s")) (EIf (EApp (EApp (EVar "S.endsWith") (ELit (LString "$lb"))) (EVar "s")) (EMatch (EApp (EVar "reverse") (EApp (EApp (EVar "splitOnChar") (ELit (LChar "$"))) (EVar "s"))) (arm (PCons PWild (PCons (PVar "k") PWild)) () (EMatch (EApp (EVar "stringToInt") (EVar "k")) (arm (PCon "Some" (PVar "n")) () (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (arm (PCon "None") () (ELit (LInt 0))))) (arm PWild () (ELit (LInt 0)))) (EIf (EVar "otherwise") (ELit (LInt 0)) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "formatVersion" (TyCon "Int"))
(DFunDef false "formatVersion" () (ELit (LInt 1)))
(DTypeSig true "elabKeyOf" (TyFun (TyCon "InterfaceKey") (TyCon "InterfaceKey")))
(DFunDef false "elabKeyOf" ((PVar "key")) (ERecordCreate "InterfaceKey" ((fa "ikFormat" (EVar "formatVersion")) (fa "ikSources" (EFieldAccess (EVar "key") "ikSources")) (fa "ikCompiler" (EFieldAccess (EVar "key") "ikCompiler")))))
(DTypeSig false "sexpBinderId" (TyFun (TyCon "BinderId") (TyCon "SExp")))
(DFunDef false "sexpBinderId" ((PCon "BinderId" (PLit (LString "")) (PVar "n"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "sexpBinderId" ((PCon "BinderId" (PVar "m") (PVar "n"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EVar "m")) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "n"))))))
(DTypeSig false "sexpBinder" (TyFun (TyCon "BinderRow") (TyCon "SExp")))
(DFunDef false "sexpBinder" ((PVar "row")) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpBinderId") (EFieldAccess (EVar "row") "brId")) (EApp (EVar "SAtom") (EFieldAccess (EVar "row") "brName")) (EApp (EVar "SAtom") (EApp (EVar "runtimeTypeName") (EFieldAccess (EVar "row") "brType"))) (EApp (EVar "SList") (EApp (EApp (EVar "map") (ELam ((PVar "t")) (EApp (EVar "SAtom") (EApp (EVar "runtimeTypeName") (EVar "t"))))) (EMatch (EFieldAccess (EVar "row") "brReturns") (arm (PCon "Some" (PVar "t")) () (EListLit (EVar "t"))) (arm (PCon "None") () (EListLit))))) (EApp (EVar "SAtom") (EIf (EFieldAccess (EVar "row") "brSigned") (ELit (LString "t")) (ELit (LString "f")))))))
(DTypeSig false "binderLine" (TyFun (TyApp (TyCon "List") (TyCon "BinderRow")) (TyCon "String")))
(DFunDef false "binderLine" ((PVar "rows")) (EApp (EVar "renderSExp") (EApp (EVar "SList") (EApp (EApp (EVar "map") (EVar "sexpBinder")) (EVar "rows")))))
(DTypeSig false "headerNode" (TyFun (TyCon "InterfaceKey") (TyFun (TyCon "PreludeElab") (TyFun (TyCon "String") (TyCon "SExp")))))
(DFunDef false "headerNode" ((PVar "key") (PVar "pe") (PVar "digest")) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "medaka-elab"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "formatVersion"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "sources"))) (EApp (EVar "SList") (EApp (EApp (EVar "map") (ELam ((PVar "s")) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EApp (EVar "fst") (EVar "s"))) (EApp (EVar "SAtom") (EApp (EVar "snd") (EVar "s"))))))) (EFieldAccess (EVar "key") "ikSources"))))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "compiler"))) (EApp (EVar "SAtom") (EFieldAccess (EVar "key") "ikCompiler")))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "counters"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pe") "peEvCounter"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pe") "peLocalCounter"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pe") "peBinderCount"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pe") "peBinderBase"))))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "digest"))) (EApp (EVar "SAtom") (EVar "digest")))))))
(DTypeSig false "bodyText" (TyFun (TyCon "PreludeElab") (TyCon "String")))
(DFunDef false "bodyText" ((PVar "pe")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "renderSExp") (EApp (EVar "declsSExp") (EFieldAccess (EVar "pe") "peDecls"))))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EVar "renderSExp") (EApp (EVar "evEntriesSExp") (EFieldAccess (EVar "pe") "peEvidence"))))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EVar "binderLine") (EFieldAccess (EVar "pe") "peBinders")))) (ELit (LString "\n"))))
(DTypeSig true "encodeElabFile" (TyFun (TyCon "InterfaceKey") (TyFun (TyCon "PreludeElab") (TyCon "String"))))
(DFunDef false "encodeElabFile" ((PVar "key") (PVar "pe")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "bodyText") (EVar "pe"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "renderSExp") (EApp (EApp (EApp (EVar "headerNode") (EVar "key")) (EVar "pe")) (EApp (EVar "sha256Hex") (EVar "body")))))) (ELit (LString "\n"))) (EApp (EVar "display") (EVar "body"))) (ELit (LString ""))))))
(DTypeSig true "elabDigestOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "elabDigestOf" ((PVar "text")) (EMatch (EApp (EApp (EVar "S.indexOf") (ELit (LString "\n"))) (EVar "text")) (arm (PCon "Some" (PVar "i")) () (EApp (EVar "sha256Hex") (EApp (EApp (EVar "S.drop") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "text")))) (arm (PCon "None") () (EApp (EVar "sha256Hex") (ELit (LString ""))))))
(DTypeSig true "renderElabFault" (TyFun (TyCon "InterfaceFault") (TyCon "String")))
(DFunDef false "renderElabFault" ((PCon "WrongFormat" (PVar "v"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "elaborated-trees format version ")) (EApp (EVar "display") (EVar "v"))) (ELit (LString ", this compiler reads "))) (EApp (EVar "display") (EVar "formatVersion"))) (ELit (LString ""))))
(DFunDef false "renderElabFault" ((PCon "Malformed" (PVar "e"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EFieldAccess (EVar "e") "sePath"))) (ELit (LString ": "))) (EApp (EVar "display") (EFieldAccess (EVar "e") "seWhat"))) (ELit (LString " (elaborated trees)"))))
(DTypeSig false "refuse" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyVar "a")))))
(DFunDef false "refuse" ((PVar "path") (PVar "what")) (EApp (EVar "Err") (EApp (EVar "Malformed") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (EVar "path")) (fa "seWhat" (EVar "what")))))))
(DTypeSig false "failure" (TyFun (TyCon "SexpError") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyVar "a"))))
(DFunDef false "failure" ((PVar "e")) (EApp (EVar "Err") (EApp (EVar "Malformed") (EVar "e"))))
(DTypeSig false "declaredVersion" (TyFun (TyCon "SExp") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "declaredVersion" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "medaka-elab"))) (PCons (PVar "v") PWild)))) (EMatch (EApp (EApp (EVar "atomInt") (ELit (LString ""))) (EVar "v")) (arm (PCon "Ok" (PVar "n")) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "Err" PWild) () (EVar "None"))))
(DFunDef false "declaredVersion" (PWild) (EVar "None"))
(DData Private "Header" () ((variant "Header" (ConNamed (field "hKey" (TyCon "InterfaceKey")) (field "hCounters" (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))) (field "hDigest" (TyCon "String"))))) ())
(DTypeSig false "headerOf" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Header"))))
(DFunDef false "headerOf" ((PCon "SList" (PList (PCon "SAtom" (PLit (LString "medaka-elab"))) (PVar "v") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sources"))) (PVar "srcs"))) (PCon "SList" (PList (PCon "SAtom" (PLit (LString "compiler"))) (PVar "c"))) (PCon "SList" (PList (PCon "SAtom" (PLit (LString "counters"))) (PVar "k") (PVar "l") (PVar "n") (PVar "b"))) (PCon "SList" (PList (PCon "SAtom" (PLit (LString "digest"))) (PVar "d")))))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "header/version"))) (EVar "v"))) (ELam ((PVar "version")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "traverse") (EVar "sourceOf")) (EApp (EVar "listItems") (EVar "srcs")))) (ELam ((PVar "sources")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (ELit (LString "header/compiler"))) (EVar "c"))) (ELam ((PVar "compiler")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "header/counters"))) (EVar "k"))) (ELam ((PVar "kk")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "header/counters"))) (EVar "l"))) (ELam ((PVar "ll")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "header/counters"))) (EVar "n"))) (ELam ((PVar "nn")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "header/counters"))) (EVar "b"))) (ELam ((PVar "bb")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "expectAtom") (ELit (LString "header/digest"))) (EVar "d"))) (ELam ((PVar "digest")) (EApp (EVar "Ok") (ERecordCreate "Header" ((fa "hKey" (ERecordCreate "InterfaceKey" ((fa "ikFormat" (EVar "version")) (fa "ikSources" (EVar "sources")) (fa "ikCompiler" (EVar "compiler"))))) (fa "hCounters" (ETuple (EVar "kk") (EVar "ll") (EVar "nn") (EVar "bb"))) (fa "hDigest" (EVar "digest"))))))))))))))))))))))
(DFunDef false "headerOf" ((PVar "node")) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "header"))) (fa "seWhat" (ELit (LString "expected a medaka-elab header of five fields")))))))
(DTypeSig false "listItems" (TyFun (TyCon "SExp") (TyApp (TyCon "List") (TyCon "SExp"))))
(DFunDef false "listItems" ((PCon "SList" (PVar "items"))) (EVar "items"))
(DFunDef false "listItems" (PWild) (EListLit))
(DTypeSig false "sourceOf" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "sourceOf" ((PCon "SList" (PList (PCon "SAtom" (PVar "p")) (PCon "SAtom" (PVar "h"))))) (EApp (EVar "Ok") (ETuple (EVar "p") (EVar "h"))))
(DFunDef false "sourceOf" (PWild) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "header/sources"))) (fa "seWhat" (ELit (LString "expected a (path hash) pair")))))))
(DTypeSig false "readBinderId" (TyFun (TyCon "SexpCursor") (TyCon "BinderId")))
(DFunDef false "readBinderId" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "m") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "n") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "BinderId") (EVar "m")) (EVar "n")))) (EApp (EApp (EVar "BinderId") (ELit (LString ""))) (EApp (EVar "cursorInt") (EVar "cur")))))
(DTypeSig false "readRuntimeType" (TyFun (TyCon "SexpCursor") (TyCon "RuntimeType")))
(DFunDef false "readRuntimeType" ((PVar "cur")) (EMatch (EApp (EVar "runtimeTypeFromName") (EApp (EVar "cursorAtom") (EVar "cur"))) (arm (PCon "Some" (PVar "t")) () (EVar "t")) (arm (PCon "None") () (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "RTValue")))))
(DTypeSig false "readBinder" (TyFun (TyCon "SexpCursor") (TyCon "BinderRow")))
(DFunDef false "readBinder" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "bid") (EApp (EVar "readBinderId") (EVar "cur"))) (DoLet false false (PVar "name") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "ty") (EApp (EVar "readRuntimeType") (EVar "cur"))) (DoLet false false (PVar "returns") (EMatch (EApp (EApp (EVar "cursorList") (EVar "readRuntimeType")) (EVar "cur")) (arm (PList) () (EVar "None")) (arm (PList (PVar "t")) () (EApp (EVar "Some") (EVar "t"))) (arm PWild () (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "None"))))) (DoLet false false (PVar "flag") (EApp (EVar "cursorChar") (EVar "cur"))) (DoLet false false (PVar "signed") (EIf (EBinOp "==" (EVar "flag") (ELit (LInt 116))) (EVar "True") (EIf (EBinOp "==" (EVar "flag") (ELit (LInt 102))) (EVar "False") (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "False"))))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ERecordCreate "BinderRow" ((fa "brId" (EVar "bid")) (fa "brName" (EVar "name")) (fa "brType" (EVar "ty")) (fa "brReturns" (EVar "returns")) (fa "brSigned" (EVar "signed")))))))
(DTypeSig true "readElabFile" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "PreludeElab")))))
(DFunDef false "readElabFile" ((PVar "text")) (EMatch (EApp (EApp (EVar "S.indexOf") (ELit (LString "\n"))) (EVar "text")) (arm (PCon "None") () (EApp (EApp (EVar "refuse") (ELit (LString "file"))) (ELit (LString "no header line")))) (arm (PCon "Some" (PVar "i")) () (EMatch (EApp (EVar "parseSExp") (EApp (EApp (EVar "S.take") (EVar "i")) (EVar "text"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "node")) () (EMatch (EApp (EVar "declaredVersion") (EVar "node")) (arm (PCon "Some" (PVar "v")) ((GBool (EBinOp "/=" (EVar "v") (EVar "formatVersion")))) (EApp (EVar "Err") (EApp (EVar "WrongFormat") (EVar "v")))) (arm PWild () (EMatch (EApp (EVar "headerOf") (EVar "node")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "h")) () (EBlock (DoLet false false (PVar "body") (EApp (EApp (EVar "S.drop") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "text"))) (DoExpr (EIf (EBinOp "/=" (EApp (EVar "sha256Hex") (EVar "body")) (EFieldAccess (EVar "h") "hDigest")) (EApp (EApp (EVar "refuse") (ELit (LString "header/digest"))) (ELit (LString "the body does not match the digest"))) (EApp (EApp (EVar "decodeBody") (EVar "h")) (EVar "body"))))))))))))))
(DTypeSig false "decodeBody" (TyFun (TyCon "Header") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "PreludeElab"))))))
(DFunDef false "decodeBody" ((PVar "h") (PVar "body")) (EBlock (DoLet false false (PVar "cur") (EApp (EVar "cursorOf") (EVar "body"))) (DoExpr (EMatch (EApp (EVar "readDecls") (EVar "cur")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "decls")) () (EMatch (EApp (EVar "readEvEntries") (EVar "cur")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "evidence")) () (EBlock (DoLet false false (PVar "binders") (EApp (EApp (EVar "cursorList") (EVar "readBinder")) (EVar "cur"))) (DoExpr (EIf (EApp (EVar "cursorFailed") (EVar "cur")) (EApp (EApp (EVar "refuse") (ELit (LString "binders"))) (ELit (LString "malformed or truncated encoding"))) (EIf (EApp (EVar "not") (EApp (EVar "cursorAtEnd") (EVar "cur"))) (EApp (EVar "failure") (ERecordCreate "SexpError" ((fa "seOffset" (EApp (EVar "cursorOffset") (EVar "cur"))) (fa "sePath" (ELit (LString ""))) (fa "seWhat" (ELit (LString "trailing text after the binder rows")))))) (EBlock (DoLet false false (PTuple (PVar "k") (PVar "l") (PVar "n") (PVar "b")) (EFieldAccess (EVar "h") "hCounters")) (DoExpr (EIf (EBinOp "||" (EBinOp "/=" (EVar "n") (EApp (EVar "length") (EVar "binders"))) (EBinOp "/=" (EVar "b") (EApp (EVar "binderBase") (EVar "binders")))) (EApp (EApp (EVar "refuse") (ELit (LString "header/counters"))) (ELit (LString "the binder count or base disagrees with the rows"))) (EApp (EVar "Ok") (ETuple (EFieldAccess (EVar "h") "hKey") (ERecordCreate "PreludeElab" ((fa "peDecls" (EVar "decls")) (fa "peEvidence" (EVar "evidence")) (fa "peBinders" (EVar "binders")) (fa "peEvCounter" (EVar "k")) (fa "peLocalCounter" (EVar "l")) (fa "peBinderCount" (EVar "n")) (fa "peBinderBase" (EVar "b"))))))))))))))))))))
(DTypeSig false "preludeElabCacheRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "PreludeElab")))))
(DFunDef false "preludeElabCacheRef" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "seedPreludeElab" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "PreludeElab") (TyCon "Unit"))))
(DFunDef false "seedPreludeElab" ((PVar "generation") (PVar "pe")) (EApp (EApp (EVar "setRef") (EVar "preludeElabCacheRef")) (EApp (EVar "Some") (ETuple (EVar "generation") (EVar "pe")))))
(DTypeSig true "preludeElabHit" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "PreludeElab"))))
(DFunDef false "preludeElabHit" ((PVar "generation")) (EMatch (EUnOp "!" (EVar "preludeElabCacheRef")) (arm (PCon "Some" (PTuple (PVar "seen") (PVar "pe"))) ((GBool (EBinOp "==" (EVar "seen") (EVar "generation")))) (EApp (EVar "Some") (EVar "pe"))) (arm PWild () (EVar "None"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "BinderId" true) (mem "Decl" false) (mem "EvEntry" true) (mem "EvId" true))))
(DUse false (UseGroup ("frontend" "ast_codec") ((mem "declsSExp" false) (mem "evEntriesSExp" false) (mem "readDecls" false) (mem "readEvEntries" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseAlias ("string") "S"))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "SexpError" true) (mem "SexpCursor" false) (mem "atomInt" false) (mem "cursorAtEnd" false) (mem "cursorAtom" false) (mem "cursorClose" false) (mem "cursorFail" false) (mem "cursorFailed" false) (mem "cursorInt" false) (mem "cursorList" false) (mem "cursorOf" false) (mem "cursorOffset" false) (mem "cursorOpen" false) (mem "cursorPeek" false) (mem "cursorChar" false) (mem "expectAtom" false) (mem "parseSExp" false) (mem "renderSExp" false))))
(DUse false (UseGroup ("support" "util") ((mem "splitOnChar" false))))
(DUse false (UseGroup ("types" "evidence_coverage") ((mem "EvidenceFault" true) (mem "evidenceFaults" false))))
(DUse false (UseGroup ("types" "interface_sexp") ((mem "InterfaceFault" true) (mem "sha256Hex" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "InterfaceKey" true))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" true) (mem "RuntimeType" true) (mem "binderOrdinal" false) (mem "runtimeTypeName" false) (mem "runtimeTypeFromName" false))))
(DData Public "PreludeElab" () ((variant "PreludeElab" (ConNamed (field "peDecls" (TyApp (TyCon "List") (TyCon "Decl"))) (field "peEvidence" (TyApp (TyCon "List") (TyCon "EvEntry"))) (field "peBinders" (TyApp (TyCon "List") (TyCon "BinderRow"))) (field "peEvCounter" (TyCon "Int")) (field "peLocalCounter" (TyCon "Int")) (field "peBinderCount" (TyCon "Int")) (field "peBinderBase" (TyCon "Int"))))) ())
(DTypeSig true "preludeElabOf" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "EvEntry")) (TyFun (TyApp (TyCon "List") (TyCon "BinderRow")) (TyCon "PreludeElab")))))
(DFunDef false "preludeElabOf" ((PVar "decls") (PVar "evidence") (PVar "binders")) (ERecordCreate "PreludeElab" ((fa "peDecls" (EVar "decls")) (fa "peEvidence" (EApp (EApp (EVar "referencedRows") (EVar "decls")) (EVar "evidence"))) (fa "peBinders" (EVar "binders")) (fa "peEvCounter" (EApp (EVar "evidenceHighWater") (EVar "evidence"))) (fa "peLocalCounter" (EApp (EVar "localHighWater") (EApp (EVar "declsSExp") (EVar "decls")))) (fa "peBinderCount" (EApp (EMethodRef "length") (EVar "binders"))) (fa "peBinderBase" (EApp (EVar "binderBase") (EVar "binders"))))))
(DTypeSig false "evidenceHighWater" (TyFun (TyApp (TyCon "List") (TyCon "EvEntry")) (TyCon "Int")))
(DFunDef false "evidenceHighWater" ((PVar "rows")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild)) (EApp (EApp (EMethodRef "max") (EVar "acc")) (EBinOp "+" (EVar "i") (ELit (LInt 1)))))) (ELit (LInt 0))) (EVar "rows")))
(DTypeSig false "binderBase" (TyFun (TyApp (TyCon "List") (TyCon "BinderRow")) (TyCon "Int")))
(DFunDef false "binderBase" ((PList)) (ELit (LInt 0)))
(DFunDef false "binderBase" ((PCons (PVar "r") (PVar "rest"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "row")) (EApp (EApp (EMethodRef "min") (EVar "acc")) (EApp (EVar "binderOrdinal") (EFieldAccess (EVar "row") "brId"))))) (EApp (EVar "binderOrdinal") (EFieldAccess (EVar "r") "brId"))) (EVar "rest")))
(DTypeSig false "referencedRows" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyFun (TyApp (TyCon "List") (TyCon "EvEntry")) (TyApp (TyCon "List") (TyCon "EvEntry")))))
(DFunDef false "referencedRows" ((PVar "decls") (PVar "rows")) (EBlock (DoLet false false (PVar "size") (EApp (EVar "evidenceHighWater") (EVar "rows"))) (DoLet false false (PVar "marks") (EApp (EApp (EVar "arrayMake") (EVar "size")) (EVar "False"))) (DoLet false false PWild (EApp (EApp (EVar "markReferenced") (EVar "marks")) (EApp (EApp (EVar "evidenceFaults") (EApp (EVar "Some") (ETuple (EVar "decls") (EListLit)))) (EListLit)))) (DoExpr (EApp (EApp (EMethodRef "filter") (EApp (EVar "isMarked") (EVar "marks"))) (EVar "rows")))))
(DTypeSig false "markReferenced" (TyFun (TyApp (TyCon "Array") (TyCon "Bool")) (TyFun (TyApp (TyCon "List") (TyCon "EvidenceFault")) (TyCon "Unit"))))
(DFunDef false "markReferenced" (PWild (PList)) (ELit LUnit))
(DFunDef false "markReferenced" ((PVar "marks") (PCons (PCon "MissingEntry" PWild (PVar "i") PWild) (PVar "rest"))) (EBlock (DoLet false false PWild (EIf (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "marks")))) (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "True")) (EVar "marks")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "markReferenced") (EVar "marks")) (EVar "rest")))))
(DFunDef false "markReferenced" ((PVar "marks") (PCons PWild (PVar "rest"))) (EApp (EApp (EVar "markReferenced") (EVar "marks")) (EVar "rest")))
(DTypeSig false "isMarked" (TyFun (TyApp (TyCon "Array") (TyCon "Bool")) (TyFun (TyCon "EvEntry") (TyCon "Bool"))))
(DFunDef false "isMarked" ((PVar "marks") (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild)) (EBinOp "&&" (EBinOp "&&" (EBinOp ">=" (EVar "i") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EApp (EVar "arrayLength") (EVar "marks")))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "marks"))))
(DTypeSig false "localHighWater" (TyFun (TyCon "SExp") (TyCon "Int")))
(DFunDef false "localHighWater" ((PCon "SAtom" (PVar "s"))) (EApp (EVar "localSuffix") (EVar "s")))
(DFunDef false "localHighWater" ((PCon "SList" (PVar "items"))) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "n")) (EApp (EApp (EMethodRef "max") (EVar "acc")) (EApp (EVar "localHighWater") (EVar "n"))))) (ELit (LInt 0))) (EVar "items")))
(DTypeSig false "localSuffix" (TyFun (TyCon "String") (TyCon "Int")))
(DFunDef false "localSuffix" ((PVar "s")) (EIf (EApp (EApp (EVar "S.endsWith") (ELit (LString "$lb"))) (EVar "s")) (EMatch (EApp (EVar "reverse") (EApp (EApp (EVar "splitOnChar") (ELit (LChar "$"))) (EVar "s"))) (arm (PCons PWild (PCons (PVar "k") PWild)) () (EMatch (EApp (EVar "stringToInt") (EVar "k")) (arm (PCon "Some" (PVar "n")) () (EBinOp "+" (EVar "n") (ELit (LInt 1)))) (arm (PCon "None") () (ELit (LInt 0))))) (arm PWild () (ELit (LInt 0)))) (EIf (EVar "otherwise") (ELit (LInt 0)) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "formatVersion" (TyCon "Int"))
(DFunDef false "formatVersion" () (ELit (LInt 1)))
(DTypeSig true "elabKeyOf" (TyFun (TyCon "InterfaceKey") (TyCon "InterfaceKey")))
(DFunDef false "elabKeyOf" ((PVar "key")) (ERecordCreate "InterfaceKey" ((fa "ikFormat" (EVar "formatVersion")) (fa "ikSources" (EFieldAccess (EVar "key") "ikSources")) (fa "ikCompiler" (EFieldAccess (EVar "key") "ikCompiler")))))
(DTypeSig false "sexpBinderId" (TyFun (TyCon "BinderId") (TyCon "SExp")))
(DFunDef false "sexpBinderId" ((PCon "BinderId" (PLit (LString "")) (PVar "n"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "n"))))
(DFunDef false "sexpBinderId" ((PCon "BinderId" (PVar "m") (PVar "n"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EVar "m")) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "n"))))))
(DTypeSig false "sexpBinder" (TyFun (TyCon "BinderRow") (TyCon "SExp")))
(DFunDef false "sexpBinder" ((PVar "row")) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpBinderId") (EFieldAccess (EVar "row") "brId")) (EApp (EVar "SAtom") (EFieldAccess (EVar "row") "brName")) (EApp (EVar "SAtom") (EApp (EVar "runtimeTypeName") (EFieldAccess (EVar "row") "brType"))) (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (EApp (EVar "SAtom") (EApp (EVar "runtimeTypeName") (EVar "t"))))) (EMatch (EFieldAccess (EVar "row") "brReturns") (arm (PCon "Some" (PVar "t")) () (EListLit (EVar "t"))) (arm (PCon "None") () (EListLit))))) (EApp (EVar "SAtom") (EIf (EFieldAccess (EVar "row") "brSigned") (ELit (LString "t")) (ELit (LString "f")))))))
(DTypeSig false "binderLine" (TyFun (TyApp (TyCon "List") (TyCon "BinderRow")) (TyCon "String")))
(DFunDef false "binderLine" ((PVar "rows")) (EApp (EVar "renderSExp") (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (EVar "sexpBinder")) (EVar "rows")))))
(DTypeSig false "headerNode" (TyFun (TyCon "InterfaceKey") (TyFun (TyCon "PreludeElab") (TyFun (TyCon "String") (TyCon "SExp")))))
(DFunDef false "headerNode" ((PVar "key") (PVar "pe") (PVar "digest")) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "medaka-elab"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EVar "formatVersion"))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "sources"))) (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (ELam ((PVar "s")) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (EApp (EVar "fst") (EVar "s"))) (EApp (EVar "SAtom") (EApp (EVar "snd") (EVar "s"))))))) (EFieldAccess (EVar "key") "ikSources"))))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "compiler"))) (EApp (EVar "SAtom") (EFieldAccess (EVar "key") "ikCompiler")))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "counters"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pe") "peEvCounter"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pe") "peLocalCounter"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pe") "peBinderCount"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pe") "peBinderBase"))))) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "digest"))) (EApp (EVar "SAtom") (EVar "digest")))))))
(DTypeSig false "bodyText" (TyFun (TyCon "PreludeElab") (TyCon "String")))
(DFunDef false "bodyText" ((PVar "pe")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "renderSExp") (EApp (EVar "declsSExp") (EFieldAccess (EVar "pe") "peDecls"))))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EVar "renderSExp") (EApp (EVar "evEntriesSExp") (EFieldAccess (EVar "pe") "peEvidence"))))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EVar "binderLine") (EFieldAccess (EVar "pe") "peBinders")))) (ELit (LString "\n"))))
(DTypeSig true "encodeElabFile" (TyFun (TyCon "InterfaceKey") (TyFun (TyCon "PreludeElab") (TyCon "String"))))
(DFunDef false "encodeElabFile" ((PVar "key") (PVar "pe")) (EBlock (DoLet false false (PVar "body") (EApp (EVar "bodyText") (EVar "pe"))) (DoExpr (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "renderSExp") (EApp (EApp (EApp (EVar "headerNode") (EVar "key")) (EVar "pe")) (EApp (EVar "sha256Hex") (EVar "body")))))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EVar "body"))) (ELit (LString ""))))))
(DTypeSig true "elabDigestOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "elabDigestOf" ((PVar "text")) (EMatch (EApp (EApp (EVar "S.indexOf") (ELit (LString "\n"))) (EVar "text")) (arm (PCon "Some" (PVar "i")) () (EApp (EVar "sha256Hex") (EApp (EApp (EVar "S.drop") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "text")))) (arm (PCon "None") () (EApp (EVar "sha256Hex") (ELit (LString ""))))))
(DTypeSig true "renderElabFault" (TyFun (TyCon "InterfaceFault") (TyCon "String")))
(DFunDef false "renderElabFault" ((PCon "WrongFormat" (PVar "v"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "elaborated-trees format version ")) (EApp (EMethodRef "display") (EVar "v"))) (ELit (LString ", this compiler reads "))) (EApp (EMethodRef "display") (EVar "formatVersion"))) (ELit (LString ""))))
(DFunDef false "renderElabFault" ((PCon "Malformed" (PVar "e"))) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EFieldAccess (EVar "e") "sePath"))) (ELit (LString ": "))) (EApp (EMethodRef "display") (EFieldAccess (EVar "e") "seWhat"))) (ELit (LString " (elaborated trees)"))))
(DTypeSig false "refuse" (TyFun (TyCon "String") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyVar "a")))))
(DFunDef false "refuse" ((PVar "path") (PVar "what")) (EApp (EVar "Err") (EApp (EVar "Malformed") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (EVar "path")) (fa "seWhat" (EVar "what")))))))
(DTypeSig false "failure" (TyFun (TyCon "SexpError") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyVar "a"))))
(DFunDef false "failure" ((PVar "e")) (EApp (EVar "Err") (EApp (EVar "Malformed") (EVar "e"))))
(DTypeSig false "declaredVersion" (TyFun (TyCon "SExp") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "declaredVersion" ((PCon "SList" (PCons (PCon "SAtom" (PLit (LString "medaka-elab"))) (PCons (PVar "v") PWild)))) (EMatch (EApp (EApp (EVar "atomInt") (ELit (LString ""))) (EVar "v")) (arm (PCon "Ok" (PVar "n")) () (EApp (EVar "Some") (EVar "n"))) (arm (PCon "Err" PWild) () (EVar "None"))))
(DFunDef false "declaredVersion" (PWild) (EVar "None"))
(DData Private "Header" () ((variant "Header" (ConNamed (field "hKey" (TyCon "InterfaceKey")) (field "hCounters" (TyTuple (TyCon "Int") (TyCon "Int") (TyCon "Int") (TyCon "Int"))) (field "hDigest" (TyCon "String"))))) ())
(DTypeSig false "headerOf" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Header"))))
(DFunDef false "headerOf" ((PCon "SList" (PList (PCon "SAtom" (PLit (LString "medaka-elab"))) (PVar "v") (PCon "SList" (PList (PCon "SAtom" (PLit (LString "sources"))) (PVar "srcs"))) (PCon "SList" (PList (PCon "SAtom" (PLit (LString "compiler"))) (PVar "c"))) (PCon "SList" (PList (PCon "SAtom" (PLit (LString "counters"))) (PVar "k") (PVar "l") (PVar "n") (PVar "b"))) (PCon "SList" (PList (PCon "SAtom" (PLit (LString "digest"))) (PVar "d")))))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "header/version"))) (EVar "v"))) (ELam ((PVar "version")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EMethodRef "traverse") (EVar "sourceOf")) (EApp (EVar "listItems") (EVar "srcs")))) (ELam ((PVar "sources")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (ELit (LString "header/compiler"))) (EVar "c"))) (ELam ((PVar "compiler")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "header/counters"))) (EVar "k"))) (ELam ((PVar "kk")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "header/counters"))) (EVar "l"))) (ELam ((PVar "ll")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "header/counters"))) (EVar "n"))) (ELam ((PVar "nn")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "header/counters"))) (EVar "b"))) (ELam ((PVar "bb")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "expectAtom") (ELit (LString "header/digest"))) (EVar "d"))) (ELam ((PVar "digest")) (EApp (EVar "Ok") (ERecordCreate "Header" ((fa "hKey" (ERecordCreate "InterfaceKey" ((fa "ikFormat" (EVar "version")) (fa "ikSources" (EVar "sources")) (fa "ikCompiler" (EVar "compiler"))))) (fa "hCounters" (ETuple (EVar "kk") (EVar "ll") (EVar "nn") (EVar "bb"))) (fa "hDigest" (EVar "digest"))))))))))))))))))))))
(DFunDef false "headerOf" ((PVar "node")) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "header"))) (fa "seWhat" (ELit (LString "expected a medaka-elab header of five fields")))))))
(DTypeSig false "listItems" (TyFun (TyCon "SExp") (TyApp (TyCon "List") (TyCon "SExp"))))
(DFunDef false "listItems" ((PCon "SList" (PVar "items"))) (EVar "items"))
(DFunDef false "listItems" (PWild) (EListLit))
(DTypeSig false "sourceOf" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "sourceOf" ((PCon "SList" (PList (PCon "SAtom" (PVar "p")) (PCon "SAtom" (PVar "h"))))) (EApp (EVar "Ok") (ETuple (EVar "p") (EVar "h"))))
(DFunDef false "sourceOf" (PWild) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "header/sources"))) (fa "seWhat" (ELit (LString "expected a (path hash) pair")))))))
(DTypeSig false "readBinderId" (TyFun (TyCon "SexpCursor") (TyCon "BinderId")))
(DFunDef false "readBinderId" ((PVar "cur")) (EIf (EBinOp "==" (EApp (EVar "cursorPeek") (EVar "cur")) (ELit (LInt 40))) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "m") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "n") (EApp (EVar "cursorInt") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (EApp (EApp (EVar "BinderId") (EVar "m")) (EVar "n")))) (EApp (EApp (EVar "BinderId") (ELit (LString ""))) (EApp (EVar "cursorInt") (EVar "cur")))))
(DTypeSig false "readRuntimeType" (TyFun (TyCon "SexpCursor") (TyCon "RuntimeType")))
(DFunDef false "readRuntimeType" ((PVar "cur")) (EMatch (EApp (EVar "runtimeTypeFromName") (EApp (EVar "cursorAtom") (EVar "cur"))) (arm (PCon "Some" (PVar "t")) () (EVar "t")) (arm (PCon "None") () (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "RTValue")))))
(DTypeSig false "readBinder" (TyFun (TyCon "SexpCursor") (TyCon "BinderRow")))
(DFunDef false "readBinder" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "bid") (EApp (EVar "readBinderId") (EVar "cur"))) (DoLet false false (PVar "name") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "ty") (EApp (EVar "readRuntimeType") (EVar "cur"))) (DoLet false false (PVar "returns") (EMatch (EApp (EApp (EVar "cursorList") (EVar "readRuntimeType")) (EVar "cur")) (arm (PList) () (EVar "None")) (arm (PList (PVar "t")) () (EApp (EVar "Some") (EVar "t"))) (arm PWild () (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "None"))))) (DoLet false false (PVar "flag") (EApp (EVar "cursorChar") (EVar "cur"))) (DoLet false false (PVar "signed") (EIf (EBinOp "==" (EVar "flag") (ELit (LInt 116))) (EVar "True") (EIf (EBinOp "==" (EVar "flag") (ELit (LInt 102))) (EVar "False") (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "False"))))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ERecordCreate "BinderRow" ((fa "brId" (EVar "bid")) (fa "brName" (EVar "name")) (fa "brType" (EVar "ty")) (fa "brReturns" (EVar "returns")) (fa "brSigned" (EVar "signed")))))))
(DTypeSig true "readElabFile" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "PreludeElab")))))
(DFunDef false "readElabFile" ((PVar "text")) (EMatch (EApp (EApp (EVar "S.indexOf") (ELit (LString "\n"))) (EVar "text")) (arm (PCon "None") () (EApp (EApp (EVar "refuse") (ELit (LString "file"))) (ELit (LString "no header line")))) (arm (PCon "Some" (PVar "i")) () (EMatch (EApp (EVar "parseSExp") (EApp (EApp (EVar "S.take") (EVar "i")) (EVar "text"))) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "node")) () (EMatch (EApp (EVar "declaredVersion") (EVar "node")) (arm (PCon "Some" (PVar "v")) ((GBool (EBinOp "/=" (EVar "v") (EVar "formatVersion")))) (EApp (EVar "Err") (EApp (EVar "WrongFormat") (EVar "v")))) (arm PWild () (EMatch (EApp (EVar "headerOf") (EVar "node")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "h")) () (EBlock (DoLet false false (PVar "body") (EApp (EApp (EVar "S.drop") (EBinOp "+" (EVar "i") (ELit (LInt 1)))) (EVar "text"))) (DoExpr (EIf (EBinOp "/=" (EApp (EVar "sha256Hex") (EVar "body")) (EFieldAccess (EVar "h") "hDigest")) (EApp (EApp (EVar "refuse") (ELit (LString "header/digest"))) (ELit (LString "the body does not match the digest"))) (EApp (EApp (EVar "decodeBody") (EVar "h")) (EVar "body"))))))))))))))
(DTypeSig false "decodeBody" (TyFun (TyCon "Header") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "PreludeElab"))))))
(DFunDef false "decodeBody" ((PVar "h") (PVar "body")) (EBlock (DoLet false false (PVar "cur") (EApp (EVar "cursorOf") (EVar "body"))) (DoExpr (EMatch (EApp (EVar "readDecls") (EVar "cur")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "decls")) () (EMatch (EApp (EVar "readEvEntries") (EVar "cur")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "evidence")) () (EBlock (DoLet false false (PVar "binders") (EApp (EApp (EVar "cursorList") (EVar "readBinder")) (EVar "cur"))) (DoExpr (EIf (EApp (EVar "cursorFailed") (EVar "cur")) (EApp (EApp (EVar "refuse") (ELit (LString "binders"))) (ELit (LString "malformed or truncated encoding"))) (EIf (EApp (EVar "not") (EApp (EVar "cursorAtEnd") (EVar "cur"))) (EApp (EVar "failure") (ERecordCreate "SexpError" ((fa "seOffset" (EApp (EVar "cursorOffset") (EVar "cur"))) (fa "sePath" (ELit (LString ""))) (fa "seWhat" (ELit (LString "trailing text after the binder rows")))))) (EBlock (DoLet false false (PTuple (PVar "k") (PVar "l") (PVar "n") (PVar "b")) (EFieldAccess (EVar "h") "hCounters")) (DoExpr (EIf (EBinOp "||" (EBinOp "/=" (EVar "n") (EApp (EMethodRef "length") (EVar "binders"))) (EBinOp "/=" (EVar "b") (EApp (EVar "binderBase") (EVar "binders")))) (EApp (EApp (EVar "refuse") (ELit (LString "header/counters"))) (ELit (LString "the binder count or base disagrees with the rows"))) (EApp (EVar "Ok") (ETuple (EFieldAccess (EVar "h") "hKey") (ERecordCreate "PreludeElab" ((fa "peDecls" (EVar "decls")) (fa "peEvidence" (EVar "evidence")) (fa "peBinders" (EVar "binders")) (fa "peEvCounter" (EVar "k")) (fa "peLocalCounter" (EVar "l")) (fa "peBinderCount" (EVar "n")) (fa "peBinderBase" (EVar "b"))))))))))))))))))))
(DTypeSig false "preludeElabCacheRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "PreludeElab")))))
(DFunDef false "preludeElabCacheRef" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "seedPreludeElab" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "PreludeElab") (TyCon "Unit"))))
(DFunDef false "seedPreludeElab" ((PVar "generation") (PVar "pe")) (EApp (EApp (EVar "setRef") (EVar "preludeElabCacheRef")) (EApp (EVar "Some") (ETuple (EVar "generation") (EVar "pe")))))
(DTypeSig true "preludeElabHit" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "PreludeElab"))))
(DFunDef false "preludeElabHit" ((PVar "generation")) (EMatch (EUnOp "!" (EVar "preludeElabCacheRef")) (arm (PCon "Some" (PTuple (PVar "seen") (PVar "pe"))) ((GBool (EBinOp "==" (EVar "seen") (EVar "generation")))) (EApp (EVar "Some") (EVar "pe"))) (arm PWild () (EVar "None"))))
