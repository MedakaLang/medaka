# META
source_lines=678
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
-- the highest `$m$k$lb` local-abstraction suffix its trees hold, `peBinderCount`
-- the number of binder rows and `peBinderBase` the first binder ordinal (binder
-- ordinals are relocated by offset, never restored).
--
-- File grammar: the first line is the header, then the counters line, then
-- three lines (declarations, evidence rows, binder rows), each one list.
--   (medaka-elab <version> (sources ((<path> <hash>) ...)) (compiler <id>)
--     (digest <hex>))
--   (counters <K> <L> <N> <B0>)
-- The digest is the SHA-256 of the bytes after the header line, the counters
-- line included, and is checked before any of them is decoded, so a flipped or
-- cut byte never reaches the cursor.  The header's own fields are not under the
-- digest: a flip there reads as a different key (stale on comparison) or a
-- refused header.  The counters are further checked against the rows they
-- describe, because they size the table `seedPreludeElab` writes unchecked.  A
-- binder row is `(<id> <name> <type> (<type>?) <t|f>)`; an id of module `""` is
-- its bare ordinal, any other is `(<module> <ordinal>)`.
--
-- The body is never built as an `SExp`: the cursor readers of
-- `frontend.ast_codec` and the binder reader below take it off the bytes.

import frontend.ast.{
  Arm(..), BinderId(..), Decl(..), DoStmt(..), EvEntry(..), EvId(..), EvTable,
  Expr(..), FieldAssign(..), FunClause(..), Guard(..), GuardArm(..),
  IfaceMethod(..), ImplMethod(..), InterpPart(..), LetBind(..),
  MethodDefault(..), Pat(..), RecPatField(..), Section(..)
}
import frontend.ast_codec.{
  declsSExp, evEntriesSExp, readBinderId, readBool, readDecls, readEvEntries,
  sexpBinderId, sexpBool
}
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
import types.interface_frame.{
  InterfaceFault(..), KeyGate, bodyOf, checkedFramed, failure, firstLine,
  framedFile, keyFields, noGate, refuse, renderFramedFault, sha256Hex
}
import types.prelude_interface.{InterfaceKey(..)}
import types.route_key.{setPreludeEvidence}
import types.runtime_types.{
  BinderRow(..), BinderTypeTable, RuntimeType(..), addBinderRow, binderOrdinal,
  runtimeTypeName, runtimeTypeFromName
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

-- One past the highest k of any `<name>$<module>$<k>$lb` atom.
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
formatVersion = 3

-- The key an elaborated-trees file is validated against: the interface file's
-- key with this file's own format version.
export
elabKeyOf : InterfaceKey -> InterfaceKey
elabKeyOf key = InterfaceKey {
  ikFormat = formatVersion,
  ikSources = key.ikSources,
  ikCompiler = key.ikCompiler,
}

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
  sexpBool row.brSigned,
]

binderLine : List BinderRow -> String
binderLine rows = renderSExp (SList (map sexpBinder rows))

countersNode : PreludeElab -> SExp
countersNode pe = SList [
  SAtom "counters",
  SAtom (intToString pe.peEvCounter),
  SAtom (intToString pe.peLocalCounter),
  SAtom (intToString pe.peBinderCount),
  SAtom (intToString pe.peBinderBase),
]

-- The bytes the digest covers: the counters line and the three body lines.
coveredText : PreludeElab -> String
coveredText pe =
  "\{renderSExp (countersNode pe)}\n\{renderSExp (declsSExp pe.peDecls)}\n\{renderSExp (evEntriesSExp pe.peEvidence)}\n\{binderLine pe.peBinders}\n"

-- The whole file for [pe] under [key]; the key's own format field is not
-- written, the header always carries `formatVersion`.
export
encodeElabFile : InterfaceKey -> PreludeElab -> String
encodeElabFile key pe =
  let covered = coveredText pe
  framedFile "medaka-elab" formatVersion (keyFields key) covered

-- The digest a framed file's covered text has: the SHA-256 of the bytes after
-- the first line.
export
framedDigestOf : String -> String
framedDigestOf text = sha256Hex (bodyOf text)

export
renderElabFault : InterfaceFault -> String
renderElabFault fault = renderFramedFault "elaborated trees" formatVersion fault

-- The four counters of the counters line.
data Counters = Counters {
  cEvidence : Int,
  cLocal : Int,
  cBinders : Int,
  cBinderBase : Int,
}

countersOf : SExp -> Result SexpError Counters
countersOf (SList [SAtom "counters", k, l, n, b]) = do
  kk <- atomInt "counters" k
  ll <- atomInt "counters" l
  nn <- atomInt "counters" n
  bb <- atomInt "counters" b
  Ok Counters {
    cEvidence = kk,
    cLocal = ll,
    cBinders = nn,
    cBinderBase = bb,
  }
countersOf _ = Err SexpError {
  seOffset = 0,
  sePath = "counters",
  seWhat = "expected a counters line of four numbers",
}

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
  let signed = readBool cur
  let _ = cursorClose cur
  BinderRow {
    brId = bid,
    brName = name,
    brType = ty,
    brReturns = returns,
    brSigned = signed,
  }

-- The value of a file, or why it is refused: the version first, then the
-- header, then the digest, then the counters line, then the body, and last the
-- counters against the rows they describe.  The key is the one the header
-- carries.
export
readElabFile : String -> Result InterfaceFault (InterfaceKey, PreludeElab)
readElabFile = readElabFileGated noGate

-- `readElabFile` for a file [gate] has to find fresh: a stale key is refused
-- before the digest is checked or any body is decoded.
export
readElabFileGated : KeyGate ->
  String ->
  Result InterfaceFault (InterfaceKey, PreludeElab)
readElabFileGated gate text = do
  (key, covered) <- checkedElab gate text
  decodeCovered key covered

checkedElab : KeyGate -> String -> Result InterfaceFault (InterfaceKey, String)
checkedElab = checkedFramed "medaka-elab" formatVersion

decodeCovered : InterfaceKey ->
  String ->
  Result InterfaceFault (InterfaceKey, PreludeElab)
decodeCovered key covered = do
  (node, rest) <- firstLine "counters" "no counters line" covered
  counters <- mapErr Malformed (countersOf node)
  decodeBody key counters rest

decodeBody : InterfaceKey ->
  Counters ->
  String ->
  Result InterfaceFault (InterfaceKey, PreludeElab)
decodeBody key counters body =
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
          let pe = PreludeElab {
            peDecls = decls,
            peEvidence = evidence,
            peBinders = binders,
            peEvCounter = counters.cEvidence,
            peLocalCounter = counters.cLocal,
            peBinderCount = counters.cBinders,
            peBinderBase = counters.cBinderBase,
          }
          match countersProblem pe
            Some (path, what) => refuse path what
            None => Ok (key, pe)

-- Why the counters of [pe] do not describe its rows, if they do not.  The
-- evidence counter sizes the table `seedPreludeElab` writes with unchecked
-- indexing, so no row, and no tree site of module `""`, may lie outside it.
countersProblem : PreludeElab -> Option (String, String)
countersProblem pe
  | pe.peBinderCount /= length pe.peBinders
    || pe.peBinderBase /= binderBase pe.peBinders = Some (
    "counters/binders",
    "the binder count or base disagrees with the rows",
  )
  | pe.peLocalCounter < 0
    || pe.peLocalCounter < localHighWater (declsSExp pe.peDecls) = Some (
    "counters/local",
    "the local-abstraction counter is not above every local name of the trees",
  )
  | otherwise = match evidenceRowsProblem pe.peEvCounter pe.peEvidence
    Some what => Some ("counters/evidence", what)
    None => treeSitesProblem pe

-- The largest evidence counter a file may claim: core's is a few thousand.
maxEvidenceCounter : Int
maxEvidenceCounter = 4194304

-- Why [rows] are not a set of distinct ordinals in `[0, counter)`, if they are
-- not.
evidenceRowsProblem : Int -> List EvEntry -> Option String
evidenceRowsProblem counter rows
  | counter < 0 || counter > maxEvidenceCounter =
    Some "the evidence counter is out of range"
  | otherwise = rowsProblem (arrayMake counter False) counter rows

rowsProblem : Array Bool -> Int -> List EvEntry -> Option String
rowsProblem _ _ [] = None
rowsProblem seen counter ((EvEntry (EvId _ i) _) :: rest)
  | i < 0 = Some "an evidence row has a negative ordinal"
  | i >= counter = Some "an evidence row is at or above the evidence counter"
  | arrayGetUnsafe i seen = Some "two evidence rows share one ordinal"
  | otherwise =
    let _ = arraySetUnsafe i True seen
    rowsProblem seen counter rest

-- Whether a tree site of module `""` names an ordinal at or above the counter.
treeSitesProblem : PreludeElab -> Option (String, String)
treeSitesProblem pe =
  if any
    (aboveCounter pe.peEvCounter)
    (evidenceFaults (Some (pe.peDecls, [])) []) then
    Some (
      "counters/evidence",
      "a tree site is at or above the evidence counter",
    )
  else
    None

aboveCounter : Int -> EvidenceFault -> Bool
aboveCounter counter (MissingEntry "" i _) = i >= counter
aboveCounter _ _ = False

-- The key a file's header claims, after its version, header and digest are
-- checked, without decoding the body: what a process that will not take the
-- trees itself needs to say whether they are fresh.  A file whose counters lie
-- under a recomputed digest reads as fresh here; `readElabFile` refuses it.
export
readElabKey : String -> Result InterfaceFault InterfaceKey
readElabKey = readElabKeyGated noGate

-- `readElabKey` for a file [gate] has to find fresh.
export
readElabKeyGated : KeyGate -> String -> Result InterfaceFault InterfaceKey
readElabKeyGated gate text = map fst (checkedElab gate text)

-- ── binder relocation ───────────────────────────────────────────────────────
-- The file's binder ordinals are the writer's; a reading process minted its own
-- for core when it desugared it, and every table it publishes is keyed by those.
-- The value is moved onto them by one offset: the reader's first core ordinal
-- less the file's.  Desugar mints core's ordinals in one contiguous run, so the
-- reader's core holds exactly the file's count of them from its first.

-- [decls] with [f] applied to every binder id they carry, minted or not.  The
-- walkers name every constructor, so one added to the AST is a non-exhaustive
-- match here until it is placed: the arms that carry no binder hand their node
-- back unchanged.
mapBinders : (BinderId -> BinderId) -> List Decl -> List Decl
mapBinders f decls = map (relocDecl f) decls

-- A minted ordinal moved by [offset]; an unminted id stays unminted.
relocId : Int -> BinderId -> BinderId
relocId offset (BinderId m i) =
  if i < 0 then BinderId m i else BinderId m (i + offset)

relocDecl : (BinderId -> BinderId) -> Decl -> Decl
relocDecl o (DFunDef pub n ps e site bid) =
  DFunDef pub n (map (relocPat o) ps) (relocExpr o e) site (o bid)
relocDecl o (DLetGroup pub binds) = DLetGroup pub (map (relocBind o) binds)
relocDecl o (d@(DInterface { methods, ... })) =
  DInterface { d | methods = map (relocIfaceMethod o) methods }
relocDecl o (d@(DImpl { methods, ... })) =
  DImpl { d | methods = map (relocImplMethod o) methods }
relocDecl o (DProp pub name params body) =
  DProp pub name params (relocExpr o body)
relocDecl o (DTest pub name body) = DTest pub name (relocExpr o body)
relocDecl o (DAttrib attrs d) = DAttrib attrs (relocDecl o d)
relocDecl _ (d@(DTypeSig _ _ _ _)) = d
relocDecl _ (d@(DExtern _)) = d
relocDecl _ (d@(DData {  })) = d
relocDecl _ (d@(DUse _ _ _)) = d
relocDecl _ (d@(DEffect _ _ _ _ _ _)) = d
relocDecl _ (d@(DTypeAlias {  })) = d
relocDecl _ (d@(DNewtype {  })) = d

relocIfaceMethod : (BinderId -> BinderId) -> IfaceMethod -> IfaceMethod
relocIfaceMethod o (IfaceMethod n ty (Some (MethodDefault ps e)) mloc) =
  IfaceMethod
    n
    ty
    (Some (MethodDefault (map (relocPat o) ps) (relocExpr o e)))
    mloc
relocIfaceMethod _ (m@(IfaceMethod _ _ None _)) = m

relocImplMethod : (BinderId -> BinderId) -> ImplMethod -> ImplMethod
relocImplMethod o (ImplMethod n ps e) =
  ImplMethod n (map (relocPat o) ps) (relocExpr o e)

relocBind : (BinderId -> BinderId) -> LetBind -> LetBind
relocBind o (LetBind n clauses site bid) =
  LetBind n (map (relocClause o) clauses) site (o bid)

relocClause : (BinderId -> BinderId) -> FunClause -> FunClause
relocClause o (FunClause ps b) = FunClause (map (relocPat o) ps) (relocExpr o b)

relocPat : (BinderId -> BinderId) -> Pat -> Pat
relocPat o (PVar n l bid) = PVar n l (o bid)
relocPat o (PAs n l bid p) = PAs n l (o bid) (relocPat o p)
relocPat o (PCon c ps) = PCon c (map (relocPat o) ps)
relocPat o (PCons h t) = PCons (relocPat o h) (relocPat o t)
relocPat o (PTuple ps) = PTuple (map (relocPat o) ps)
relocPat o (PList ps) = PList (map (relocPat o) ps)
relocPat o (PRec c fields open) = PRec c (map (relocField o) fields) open
relocPat _ PWild = PWild
relocPat _ (p@(PLit _)) = p
relocPat _ (p@(PRng _ _ _)) = p

relocField : (BinderId -> BinderId) -> RecPatField -> RecPatField
relocField o (RecPatField n l bid sub) =
  RecPatField n l (o bid) (map (relocPat o) sub)

relocExpr : (BinderId -> BinderId) -> Expr -> Expr
relocExpr o (ELam ps b) = ELam (map (relocPat o) ps) (relocExpr o b)
relocExpr o (ELet l r p e1 e2) =
  ELet l r (relocPat o p) (relocExpr o e1) (relocExpr o e2)
relocExpr o (ELetGroup bs e2) =
  ELetGroup (map (relocBind o) bs) (relocExpr o e2)
relocExpr o (EMatch e0 arms) = EMatch (relocExpr o e0) (map (relocArm o) arms)
relocExpr o (EGuards arms) = EGuards (map (relocGuardArm o) arms)
relocExpr o (EBlock stmts) = EBlock (map (relocStmt o) stmts)
relocExpr o (EDo d stmts) = EDo d (map (relocStmt o) stmts)
relocExpr o (ELoc l x) = ELoc l (relocExpr o x)
relocExpr o (EDoOrigin l x) = EDoOrigin l (relocExpr o x)
relocExpr o (EApp a b) = EApp (relocExpr o a) (relocExpr o b)
relocExpr o (EIf c t el) = EIf (relocExpr o c) (relocExpr o t) (relocExpr o el)
relocExpr o (EBinOp op a b r) = EBinOp op (relocExpr o a) (relocExpr o b) r
relocExpr o (EUnOp op a r) = EUnOp op (relocExpr o a) r
relocExpr o (EInfix op a b) = EInfix op (relocExpr o a) (relocExpr o b)
relocExpr o (EFieldAccess x n r) = EFieldAccess (relocExpr o x) n r
relocExpr o (ERecordCreate n fs) = ERecordCreate n (map (relocAssign o) fs)
relocExpr o (ERecordUpdate x fs r) =
  ERecordUpdate (relocExpr o x) (map (relocAssign o) fs) r
relocExpr o (EVariantUpdate c x fs) =
  EVariantUpdate c (relocExpr o x) (map (relocAssign o) fs)
relocExpr o (EArrayLit es) = EArrayLit (map (relocExpr o) es)
relocExpr o (EListLit es) = EListLit (map (relocExpr o) es)
relocExpr o (ETuple es) = ETuple (map (relocExpr o) es)
relocExpr o (EIndex x i) = EIndex (relocExpr o x) (relocExpr o i)
relocExpr o (ERangeList lo hi incl) =
  ERangeList (relocExpr o lo) (relocExpr o hi) incl
relocExpr o (ERangeArray lo hi incl) =
  ERangeArray (relocExpr o lo) (relocExpr o hi) incl
relocExpr o (ESlice x lo hi incl) =
  ESlice (relocExpr o x) (relocExpr o lo) (relocExpr o hi) incl
relocExpr o (EAnnot x t) = EAnnot (relocExpr o x) t
relocExpr o (EHeadAnnot x t) = EHeadAnnot (relocExpr o x) t
relocExpr o (EStringInterp parts) = EStringInterp (map (relocInterp o) parts)
relocExpr o (ESection (SecRight op x)) = ESection (SecRight op (relocExpr o x))
relocExpr o (ESection (SecLeft x op)) = ESection (SecLeft (relocExpr o x) op)
relocExpr o (EMapLit n kvs) =
  EMapLit n (map ((k, v) => (relocExpr o k, relocExpr o v)) kvs)
relocExpr o (ESetLit n es) = ESetLit n (map (relocExpr o) es)
relocExpr o (EAsPat n x) = EAsPat n (relocExpr o x)
relocExpr _ (e@(ELit _)) = e
relocExpr _ (e@(EVar _)) = e
relocExpr _ (e@(ESection (SecBare _))) = e
relocExpr _ (e@(EMethodRef _)) = e
relocExpr _ (e@(EDictApp _)) = e
relocExpr _ (e@(EVarAt _ _)) = e
relocExpr _ (e@(EVarId _ _)) = e
relocExpr _ (e@(EMethodAt _ _ _)) = e
relocExpr _ (e@(EDictAt _ _)) = e
relocExpr _ (e@(ENumLit _ _ _)) = e
relocExpr _ (e@(EWideLit _ _ _ _)) = e

relocArm : (BinderId -> BinderId) -> Arm -> Arm
relocArm o (Arm p gs b) =
  Arm (relocPat o p) (map (relocGuard o) gs) (relocExpr o b)

relocGuard : (BinderId -> BinderId) -> Guard -> Guard
relocGuard o (GBool e) = GBool (relocExpr o e)
relocGuard o (GBind p e) = GBind (relocPat o p) (relocExpr o e)

relocGuardArm : (BinderId -> BinderId) -> GuardArm -> GuardArm
relocGuardArm o (GuardArm gs b) =
  GuardArm (map (relocGuard o) gs) (relocExpr o b)

relocStmt : (BinderId -> BinderId) -> DoStmt -> DoStmt
relocStmt o (DoExpr e) = DoExpr (relocExpr o e)
relocStmt o (DoBind p e) = DoBind (relocPat o p) (relocExpr o e)
relocStmt o (DoLet m r p e site) = DoLet m r (relocPat o p) (relocExpr o e) site
relocStmt o (DoAssign x e) = DoAssign x (relocExpr o e)
relocStmt o (DoFieldAssign x fs e) = DoFieldAssign x fs (relocExpr o e)

relocAssign : (BinderId -> BinderId) -> FieldAssign -> FieldAssign
relocAssign o (FieldAssign n v) = FieldAssign n (relocExpr o v)

relocInterp : (BinderId -> BinderId) -> InterpPart -> InterpPart
relocInterp o (InterpExpr e) = InterpExpr (relocExpr o e)
relocInterp _ (p@(InterpStr _)) = p

-- The ordinals a tree minted: the first of them and how many there are.
public export data BinderRun = BinderRun {
  brFirst : Int,
  brCount : Int,
} deriving (Eq, Debug)

-- The run [decls] minted (`BinderRun 0 0` for none), or `None` when the minted
-- ordinals are not one contiguous run.  The walk that relocates is the census:
-- [note] hands every id back unchanged.
export
binderSpan : List Decl -> Option BinderRun
binderSpan decls =
  let lo = Ref (0 - 1)
  let hi = Ref (0 - 1)
  let count = Ref 0
  let note =
    bid => match bid
      BinderId _ i if i >= 0 =>
        let _ = if lo.value < 0 || i < lo.value then lo := i
        let _ = if i > hi.value then hi := i
        count := count.value + 1
        bid
      _ => bid
  let _ = mapBinders note decls
  if count.value == 0 then
    Some BinderRun { brFirst = 0, brCount = 0 }
  else if hi.value - lo.value + 1 == count.value then
    Some BinderRun { brFirst = lo.value, brCount = count.value }
  else
    None

-- The longest binder run a file may claim, checked before the run's bitmap is
-- allocated: the prelude mints a few thousand.
maxBinderRun : Int
maxBinderRun = 4194304

-- Whether the minted binder ordinals of [decls] are exactly [run]'s ordinals,
-- each once: in range, no repeat, and so no gap.  `binderSpan` sees only the
-- run's ends and its size, which a changed or duplicated id leaves alone.
export
binderRunIs : BinderRun -> List Decl -> Bool
binderRunIs run decls
  | run.brCount < 0 || run.brCount > maxBinderRun = False
  | otherwise =
    let count = run.brCount
    let base = run.brFirst
    let seen = arrayMake count False
    let ok = Ref True
    let taken = Ref 0
    let note =
      bid => match bid
        BinderId _ i if i >= 0 =>
          let j = i - base
          let _ =
            if j < 0 || j >= count || arrayGetUnsafe j seen then
              ok := False
            else
              arraySetUnsafe j True seen
          taken := taken.value + 1
          bid
        _ => bid
    let _ = mapBinders note decls
    ok.value && taken.value == count

-- [decls] with every minted binder ordinal moved by [offset].
export
relocDecls : Int -> List Decl -> List Decl
relocDecls offset decls = mapBinders (relocId offset) decls

relocated : Int -> PreludeElab -> PreludeElab
relocated offset pe =
  if offset == 0 then
    pe
  else
    { pe |
      peDecls = mapBinders (relocId offset) pe.peDecls,
      peBinders =
        map (row => { row | brId = relocId offset row.brId }) pe.peBinders,
      peBinderBase = pe.peBinderBase + offset,
    }

-- ── the process cache ───────────────────────────────────────────────────────

-- One value for one compiler generation, the pair `preludeCacheHit` keys by, and
-- whether its binders are already the generation's own (relocated).
preludeElabCacheRef : Ref (Option ((Int, Int), PreludeElab, Bool))
preludeElabCacheRef = Ref None

-- Holding a value also indexes its evidence as the process's prelude segment
-- (`types/route_key.mdk`), whose ids every later drive mints past.
-- A value whose rows do not fit its counter is not held: the segment is written
-- with unchecked indexing.
export
seedPreludeElab : (Int, Int) -> PreludeElab -> Unit
seedPreludeElab generation pe =
  match evidenceRowsProblem pe.peEvCounter pe.peEvidence
    Some _ => ()
    None =>
      let _ = setPreludeEvidence pe.peEvCounter pe.peEvidence
      preludeElabCacheRef := Some (generation, pe, False)

export
preludeElabHit : (Int, Int) -> Option PreludeElab
preludeElabHit generation = match !preludeElabCacheRef
  Some (seen, pe, _) if seen == generation => Some pe
  _ => None

-- The value of [generation] with its binders moved onto [core]'s, the process's
-- own desugar of that generation's core; `None` when nothing is held for it or
-- [core]'s binders are not a run of the file's count.
export
preludeElabFor : (Int, Int) -> List Decl -> Option PreludeElab
preludeElabFor generation core = match !preludeElabCacheRef
  Some (seen, pe, True) if seen == generation => Some pe
  Some (seen, pe, False) if seen == generation => match binderSpan core
    Some run if run.brCount == pe.peBinderCount =>
      let moved = relocated (run.brFirst - pe.peBinderBase) pe
      preludeElabCacheRef := Some (generation, moved, True)
      Some moved
    _ => None
  _ => None

-- A tree-arm drive's published evidence and binder rows, with the rows of the
-- shipped trees it continued from joined to them.  Every id the drive minted is
-- past the shipped ones, so neither table already holds one of them.
export
withShippedRows : Option PreludeElab ->
  EvTable ->
  BinderTypeTable ->
  (EvTable, BinderTypeTable)
withShippedRows None evidence binders = (evidence, binders)
withShippedRows (Some pe) evidence binders = (
  pe.peEvidence ++ evidence,
  fold (acc row => addBinderRow row acc) binders pe.peBinders,
)

-- The evidence counter of the value this process holds, if any: every drive of
-- the process starts its interners past it.
export
heldPreludeEvCounter : Unit -> Option Int
heldPreludeEvCounter _ = map ((_, pe, _) => pe.peEvCounter) !preludeElabCacheRef
# DESUGAR
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "BinderId" true) (mem "Decl" true) (mem "DoStmt" true) (mem "EvEntry" true) (mem "EvId" true) (mem "EvTable" false) (mem "Expr" true) (mem "FieldAssign" true) (mem "FunClause" true) (mem "Guard" true) (mem "GuardArm" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "InterpPart" true) (mem "LetBind" true) (mem "MethodDefault" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Section" true))))
(DUse false (UseGroup ("frontend" "ast_codec") ((mem "declsSExp" false) (mem "evEntriesSExp" false) (mem "readBinderId" false) (mem "readBool" false) (mem "readDecls" false) (mem "readEvEntries" false) (mem "sexpBinderId" false) (mem "sexpBool" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseAlias ("string") "S"))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "SexpError" true) (mem "SexpCursor" false) (mem "atomInt" false) (mem "cursorAtEnd" false) (mem "cursorAtom" false) (mem "cursorClose" false) (mem "cursorFail" false) (mem "cursorFailed" false) (mem "cursorInt" false) (mem "cursorList" false) (mem "cursorOf" false) (mem "cursorOffset" false) (mem "cursorOpen" false) (mem "cursorPeek" false) (mem "cursorChar" false) (mem "expectAtom" false) (mem "parseSExp" false) (mem "renderSExp" false))))
(DUse false (UseGroup ("support" "util") ((mem "splitOnChar" false))))
(DUse false (UseGroup ("types" "evidence_coverage") ((mem "EvidenceFault" true) (mem "evidenceFaults" false))))
(DUse false (UseGroup ("types" "interface_frame") ((mem "InterfaceFault" true) (mem "KeyGate" false) (mem "bodyOf" false) (mem "checkedFramed" false) (mem "failure" false) (mem "firstLine" false) (mem "framedFile" false) (mem "keyFields" false) (mem "noGate" false) (mem "refuse" false) (mem "renderFramedFault" false) (mem "sha256Hex" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "InterfaceKey" true))))
(DUse false (UseGroup ("types" "route_key") ((mem "setPreludeEvidence" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" true) (mem "BinderTypeTable" false) (mem "RuntimeType" true) (mem "addBinderRow" false) (mem "binderOrdinal" false) (mem "runtimeTypeName" false) (mem "runtimeTypeFromName" false))))
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
(DFunDef false "formatVersion" () (ELit (LInt 3)))
(DTypeSig true "elabKeyOf" (TyFun (TyCon "InterfaceKey") (TyCon "InterfaceKey")))
(DFunDef false "elabKeyOf" ((PVar "key")) (ERecordCreate "InterfaceKey" ((fa "ikFormat" (EVar "formatVersion")) (fa "ikSources" (EFieldAccess (EVar "key") "ikSources")) (fa "ikCompiler" (EFieldAccess (EVar "key") "ikCompiler")))))
(DTypeSig false "sexpBinder" (TyFun (TyCon "BinderRow") (TyCon "SExp")))
(DFunDef false "sexpBinder" ((PVar "row")) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpBinderId") (EFieldAccess (EVar "row") "brId")) (EApp (EVar "SAtom") (EFieldAccess (EVar "row") "brName")) (EApp (EVar "SAtom") (EApp (EVar "runtimeTypeName") (EFieldAccess (EVar "row") "brType"))) (EApp (EVar "SList") (EApp (EApp (EVar "map") (ELam ((PVar "t")) (EApp (EVar "SAtom") (EApp (EVar "runtimeTypeName") (EVar "t"))))) (EMatch (EFieldAccess (EVar "row") "brReturns") (arm (PCon "Some" (PVar "t")) () (EListLit (EVar "t"))) (arm (PCon "None") () (EListLit))))) (EApp (EVar "sexpBool") (EFieldAccess (EVar "row") "brSigned")))))
(DTypeSig false "binderLine" (TyFun (TyApp (TyCon "List") (TyCon "BinderRow")) (TyCon "String")))
(DFunDef false "binderLine" ((PVar "rows")) (EApp (EVar "renderSExp") (EApp (EVar "SList") (EApp (EApp (EVar "map") (EVar "sexpBinder")) (EVar "rows")))))
(DTypeSig false "countersNode" (TyFun (TyCon "PreludeElab") (TyCon "SExp")))
(DFunDef false "countersNode" ((PVar "pe")) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "counters"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pe") "peEvCounter"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pe") "peLocalCounter"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pe") "peBinderCount"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pe") "peBinderBase"))))))
(DTypeSig false "coveredText" (TyFun (TyCon "PreludeElab") (TyCon "String")))
(DFunDef false "coveredText" ((PVar "pe")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EVar "display") (EApp (EVar "renderSExp") (EApp (EVar "countersNode") (EVar "pe"))))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EVar "renderSExp") (EApp (EVar "declsSExp") (EFieldAccess (EVar "pe") "peDecls"))))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EVar "renderSExp") (EApp (EVar "evEntriesSExp") (EFieldAccess (EVar "pe") "peEvidence"))))) (ELit (LString "\n"))) (EApp (EVar "display") (EApp (EVar "binderLine") (EFieldAccess (EVar "pe") "peBinders")))) (ELit (LString "\n"))))
(DTypeSig true "encodeElabFile" (TyFun (TyCon "InterfaceKey") (TyFun (TyCon "PreludeElab") (TyCon "String"))))
(DFunDef false "encodeElabFile" ((PVar "key") (PVar "pe")) (EBlock (DoLet false false (PVar "covered") (EApp (EVar "coveredText") (EVar "pe"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "framedFile") (ELit (LString "medaka-elab"))) (EVar "formatVersion")) (EApp (EVar "keyFields") (EVar "key"))) (EVar "covered")))))
(DTypeSig true "framedDigestOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "framedDigestOf" ((PVar "text")) (EApp (EVar "sha256Hex") (EApp (EVar "bodyOf") (EVar "text"))))
(DTypeSig true "renderElabFault" (TyFun (TyCon "InterfaceFault") (TyCon "String")))
(DFunDef false "renderElabFault" ((PVar "fault")) (EApp (EApp (EApp (EVar "renderFramedFault") (ELit (LString "elaborated trees"))) (EVar "formatVersion")) (EVar "fault")))
(DData Private "Counters" () ((variant "Counters" (ConNamed (field "cEvidence" (TyCon "Int")) (field "cLocal" (TyCon "Int")) (field "cBinders" (TyCon "Int")) (field "cBinderBase" (TyCon "Int"))))) ())
(DTypeSig false "countersOf" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Counters"))))
(DFunDef false "countersOf" ((PCon "SList" (PList (PCon "SAtom" (PLit (LString "counters"))) (PVar "k") (PVar "l") (PVar "n") (PVar "b")))) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "k"))) (ELam ((PVar "kk")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "l"))) (ELam ((PVar "ll")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "n"))) (ELam ((PVar "nn")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "b"))) (ELam ((PVar "bb")) (EApp (EVar "Ok") (ERecordCreate "Counters" ((fa "cEvidence" (EVar "kk")) (fa "cLocal" (EVar "ll")) (fa "cBinders" (EVar "nn")) (fa "cBinderBase" (EVar "bb"))))))))))))))
(DFunDef false "countersOf" (PWild) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "counters"))) (fa "seWhat" (ELit (LString "expected a counters line of four numbers")))))))
(DTypeSig false "readRuntimeType" (TyFun (TyCon "SexpCursor") (TyCon "RuntimeType")))
(DFunDef false "readRuntimeType" ((PVar "cur")) (EMatch (EApp (EVar "runtimeTypeFromName") (EApp (EVar "cursorAtom") (EVar "cur"))) (arm (PCon "Some" (PVar "t")) () (EVar "t")) (arm (PCon "None") () (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "RTValue")))))
(DTypeSig false "readBinder" (TyFun (TyCon "SexpCursor") (TyCon "BinderRow")))
(DFunDef false "readBinder" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "bid") (EApp (EVar "readBinderId") (EVar "cur"))) (DoLet false false (PVar "name") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "ty") (EApp (EVar "readRuntimeType") (EVar "cur"))) (DoLet false false (PVar "returns") (EMatch (EApp (EApp (EVar "cursorList") (EVar "readRuntimeType")) (EVar "cur")) (arm (PList) () (EVar "None")) (arm (PList (PVar "t")) () (EApp (EVar "Some") (EVar "t"))) (arm PWild () (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "None"))))) (DoLet false false (PVar "signed") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ERecordCreate "BinderRow" ((fa "brId" (EVar "bid")) (fa "brName" (EVar "name")) (fa "brType" (EVar "ty")) (fa "brReturns" (EVar "returns")) (fa "brSigned" (EVar "signed")))))))
(DTypeSig true "readElabFile" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "PreludeElab")))))
(DFunDef false "readElabFile" () (EApp (EVar "readElabFileGated") (EVar "noGate")))
(DTypeSig true "readElabFileGated" (TyFun (TyCon "KeyGate") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "PreludeElab"))))))
(DFunDef false "readElabFileGated" ((PVar "gate") (PVar "text")) (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "checkedElab") (EVar "gate")) (EVar "text"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "key") (PVar "covered")) () (EApp (EApp (EVar "decodeCovered") (EVar "key")) (EVar "covered")))))))
(DTypeSig false "checkedElab" (TyFun (TyCon "KeyGate") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "String"))))))
(DFunDef false "checkedElab" () (EApp (EApp (EVar "checkedFramed") (ELit (LString "medaka-elab"))) (EVar "formatVersion")))
(DTypeSig false "decodeCovered" (TyFun (TyCon "InterfaceKey") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "PreludeElab"))))))
(DFunDef false "decodeCovered" ((PVar "key") (PVar "covered")) (EApp (EApp (EVar "andThen") (EApp (EApp (EApp (EVar "firstLine") (ELit (LString "counters"))) (ELit (LString "no counters line"))) (EVar "covered"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "node") (PVar "rest")) () (EApp (EApp (EVar "andThen") (EApp (EApp (EVar "mapErr") (EVar "Malformed")) (EApp (EVar "countersOf") (EVar "node")))) (ELam ((PVar "counters")) (EApp (EApp (EApp (EVar "decodeBody") (EVar "key")) (EVar "counters")) (EVar "rest")))))))))
(DTypeSig false "decodeBody" (TyFun (TyCon "InterfaceKey") (TyFun (TyCon "Counters") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "PreludeElab")))))))
(DFunDef false "decodeBody" ((PVar "key") (PVar "counters") (PVar "body")) (EBlock (DoLet false false (PVar "cur") (EApp (EVar "cursorOf") (EVar "body"))) (DoExpr (EMatch (EApp (EVar "readDecls") (EVar "cur")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "decls")) () (EMatch (EApp (EVar "readEvEntries") (EVar "cur")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "evidence")) () (EBlock (DoLet false false (PVar "binders") (EApp (EApp (EVar "cursorList") (EVar "readBinder")) (EVar "cur"))) (DoExpr (EIf (EApp (EVar "cursorFailed") (EVar "cur")) (EApp (EApp (EVar "refuse") (ELit (LString "binders"))) (ELit (LString "malformed or truncated encoding"))) (EIf (EApp (EVar "not") (EApp (EVar "cursorAtEnd") (EVar "cur"))) (EApp (EVar "failure") (ERecordCreate "SexpError" ((fa "seOffset" (EApp (EVar "cursorOffset") (EVar "cur"))) (fa "sePath" (ELit (LString ""))) (fa "seWhat" (ELit (LString "trailing text after the binder rows")))))) (EBlock (DoLet false false (PVar "pe") (ERecordCreate "PreludeElab" ((fa "peDecls" (EVar "decls")) (fa "peEvidence" (EVar "evidence")) (fa "peBinders" (EVar "binders")) (fa "peEvCounter" (EFieldAccess (EVar "counters") "cEvidence")) (fa "peLocalCounter" (EFieldAccess (EVar "counters") "cLocal")) (fa "peBinderCount" (EFieldAccess (EVar "counters") "cBinders")) (fa "peBinderBase" (EFieldAccess (EVar "counters") "cBinderBase"))))) (DoExpr (EMatch (EApp (EVar "countersProblem") (EVar "pe")) (arm (PCon "Some" (PTuple (PVar "path") (PVar "what"))) () (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "what"))) (arm (PCon "None") () (EApp (EVar "Ok") (ETuple (EVar "key") (EVar "pe"))))))))))))))))))
(DTypeSig false "countersProblem" (TyFun (TyCon "PreludeElab") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "countersProblem" ((PVar "pe")) (EIf (EBinOp "||" (EBinOp "/=" (EFieldAccess (EVar "pe") "peBinderCount") (EApp (EVar "length") (EFieldAccess (EVar "pe") "peBinders"))) (EBinOp "/=" (EFieldAccess (EVar "pe") "peBinderBase") (EApp (EVar "binderBase") (EFieldAccess (EVar "pe") "peBinders")))) (EApp (EVar "Some") (ETuple (ELit (LString "counters/binders")) (ELit (LString "the binder count or base disagrees with the rows")))) (EIf (EBinOp "||" (EBinOp "<" (EFieldAccess (EVar "pe") "peLocalCounter") (ELit (LInt 0))) (EBinOp "<" (EFieldAccess (EVar "pe") "peLocalCounter") (EApp (EVar "localHighWater") (EApp (EVar "declsSExp") (EFieldAccess (EVar "pe") "peDecls"))))) (EApp (EVar "Some") (ETuple (ELit (LString "counters/local")) (ELit (LString "the local-abstraction counter is not above every local name of the trees")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "evidenceRowsProblem") (EFieldAccess (EVar "pe") "peEvCounter")) (EFieldAccess (EVar "pe") "peEvidence")) (arm (PCon "Some" (PVar "what")) () (EApp (EVar "Some") (ETuple (ELit (LString "counters/evidence")) (EVar "what")))) (arm (PCon "None") () (EApp (EVar "treeSitesProblem") (EVar "pe")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "maxEvidenceCounter" (TyCon "Int"))
(DFunDef false "maxEvidenceCounter" () (ELit (LInt 4194304)))
(DTypeSig false "evidenceRowsProblem" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "EvEntry")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "evidenceRowsProblem" ((PVar "counter") (PVar "rows")) (EIf (EBinOp "||" (EBinOp "<" (EVar "counter") (ELit (LInt 0))) (EBinOp ">" (EVar "counter") (EVar "maxEvidenceCounter"))) (EApp (EVar "Some") (ELit (LString "the evidence counter is out of range"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "rowsProblem") (EApp (EApp (EVar "arrayMake") (EVar "counter")) (EVar "False"))) (EVar "counter")) (EVar "rows")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "rowsProblem" (TyFun (TyApp (TyCon "Array") (TyCon "Bool")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "EvEntry")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "rowsProblem" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "rowsProblem" ((PVar "seen") (PVar "counter") (PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest"))) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EApp (EVar "Some") (ELit (LString "an evidence row has a negative ordinal"))) (EIf (EBinOp ">=" (EVar "i") (EVar "counter")) (EApp (EVar "Some") (ELit (LString "an evidence row is at or above the evidence counter"))) (EIf (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "seen")) (EApp (EVar "Some") (ELit (LString "two evidence rows share one ordinal"))) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "True")) (EVar "seen"))) (DoExpr (EApp (EApp (EApp (EVar "rowsProblem") (EVar "seen")) (EVar "counter")) (EVar "rest")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "treeSitesProblem" (TyFun (TyCon "PreludeElab") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "treeSitesProblem" ((PVar "pe")) (EIf (EApp (EApp (EVar "any") (EApp (EVar "aboveCounter") (EFieldAccess (EVar "pe") "peEvCounter"))) (EApp (EApp (EVar "evidenceFaults") (EApp (EVar "Some") (ETuple (EFieldAccess (EVar "pe") "peDecls") (EListLit)))) (EListLit))) (EApp (EVar "Some") (ETuple (ELit (LString "counters/evidence")) (ELit (LString "a tree site is at or above the evidence counter")))) (EVar "None")))
(DTypeSig false "aboveCounter" (TyFun (TyCon "Int") (TyFun (TyCon "EvidenceFault") (TyCon "Bool"))))
(DFunDef false "aboveCounter" ((PVar "counter") (PCon "MissingEntry" (PLit (LString "")) (PVar "i") PWild)) (EBinOp ">=" (EVar "i") (EVar "counter")))
(DFunDef false "aboveCounter" (PWild PWild) (EVar "False"))
(DTypeSig true "readElabKey" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "InterfaceKey"))))
(DFunDef false "readElabKey" () (EApp (EVar "readElabKeyGated") (EVar "noGate")))
(DTypeSig true "readElabKeyGated" (TyFun (TyCon "KeyGate") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "InterfaceKey")))))
(DFunDef false "readElabKeyGated" ((PVar "gate") (PVar "text")) (EApp (EApp (EVar "map") (EVar "fst")) (EApp (EApp (EVar "checkedElab") (EVar "gate")) (EVar "text"))))
(DTypeSig false "mapBinders" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "mapBinders" ((PVar "f") (PVar "decls")) (EApp (EApp (EVar "map") (EApp (EVar "relocDecl") (EVar "f"))) (EVar "decls")))
(DTypeSig false "relocId" (TyFun (TyCon "Int") (TyFun (TyCon "BinderId") (TyCon "BinderId"))))
(DFunDef false "relocId" ((PVar "offset") (PCon "BinderId" (PVar "m") (PVar "i"))) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EApp (EApp (EVar "BinderId") (EVar "m")) (EVar "i")) (EApp (EApp (EVar "BinderId") (EVar "m")) (EBinOp "+" (EVar "i") (EVar "offset")))))
(DTypeSig false "relocDecl" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "relocDecl" ((PVar "o") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "e") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "relocPat") (EVar "o"))) (EVar "ps"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))) (EVar "site")) (EApp (EVar "o") (EVar "bid"))))
(DFunDef false "relocDecl" ((PVar "o") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EVar "map") (EApp (EVar "relocBind") (EVar "o"))) (EVar "binds"))))
(DFunDef false "relocDecl" ((PVar "o") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (EApp (EVar "relocIfaceMethod") (EVar "o"))) (EVar "methods"))))))
(DFunDef false "relocDecl" ((PVar "o") (PAs "d" (PRec "DImpl" ((rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EVar "map") (EApp (EVar "relocImplMethod") (EVar "o"))) (EVar "methods"))))))
(DFunDef false "relocDecl" ((PVar "o") (PCon "DProp" (PVar "pub") (PVar "name") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "body"))))
(DFunDef false "relocDecl" ((PVar "o") (PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "body"))))
(DFunDef false "relocDecl" ((PVar "o") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "relocDecl") (EVar "o")) (EVar "d"))))
(DFunDef false "relocDecl" (PWild (PAs "d" (PCon "DTypeSig" PWild PWild PWild PWild))) (EVar "d"))
(DFunDef false "relocDecl" (PWild (PAs "d" (PCon "DExtern" PWild))) (EVar "d"))
(DFunDef false "relocDecl" (PWild (PAs "d" (PRec "DData" () false))) (EVar "d"))
(DFunDef false "relocDecl" (PWild (PAs "d" (PCon "DUse" PWild PWild PWild))) (EVar "d"))
(DFunDef false "relocDecl" (PWild (PAs "d" (PCon "DEffect" PWild PWild PWild PWild PWild PWild))) (EVar "d"))
(DFunDef false "relocDecl" (PWild (PAs "d" (PRec "DTypeAlias" () false))) (EVar "d"))
(DFunDef false "relocDecl" (PWild (PAs "d" (PRec "DNewtype" () false))) (EVar "d"))
(DTypeSig false "relocIfaceMethod" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod"))))
(DFunDef false "relocIfaceMethod" ((PVar "o") (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "e"))) (PVar "mloc"))) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EApp (EApp (EVar "map") (EApp (EVar "relocPat") (EVar "o"))) (EVar "ps"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))))) (EVar "mloc")))
(DFunDef false "relocIfaceMethod" (PWild (PAs "m" (PCon "IfaceMethod" PWild PWild (PCon "None") PWild))) (EVar "m"))
(DTypeSig false "relocImplMethod" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod"))))
(DFunDef false "relocImplMethod" ((PVar "o") (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "e"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "relocPat") (EVar "o"))) (EVar "ps"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))))
(DTypeSig false "relocBind" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "relocBind" ((PVar "o") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "relocClause") (EVar "o"))) (EVar "clauses"))) (EVar "site")) (EApp (EVar "o") (EVar "bid"))))
(DTypeSig false "relocClause" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "FunClause") (TyCon "FunClause"))))
(DFunDef false "relocClause" ((PVar "o") (PCon "FunClause" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "FunClause") (EApp (EApp (EVar "map") (EApp (EVar "relocPat") (EVar "o"))) (EVar "ps"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "b"))))
(DTypeSig false "relocPat" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "Pat") (TyCon "Pat"))))
(DFunDef false "relocPat" ((PVar "o") (PCon "PVar" (PVar "n") (PVar "l") (PVar "bid"))) (EApp (EApp (EApp (EVar "PVar") (EVar "n")) (EVar "l")) (EApp (EVar "o") (EVar "bid"))))
(DFunDef false "relocPat" ((PVar "o") (PCon "PAs" (PVar "n") (PVar "l") (PVar "bid") (PVar "p"))) (EApp (EApp (EApp (EApp (EVar "PAs") (EVar "n")) (EVar "l")) (EApp (EVar "o") (EVar "bid"))) (EApp (EApp (EVar "relocPat") (EVar "o")) (EVar "p"))))
(DFunDef false "relocPat" ((PVar "o") (PCon "PCon" (PVar "c") (PVar "ps"))) (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EVar "map") (EApp (EVar "relocPat") (EVar "o"))) (EVar "ps"))))
(DFunDef false "relocPat" ((PVar "o") (PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "PCons") (EApp (EApp (EVar "relocPat") (EVar "o")) (EVar "h"))) (EApp (EApp (EVar "relocPat") (EVar "o")) (EVar "t"))))
(DFunDef false "relocPat" ((PVar "o") (PCon "PTuple" (PVar "ps"))) (EApp (EVar "PTuple") (EApp (EApp (EVar "map") (EApp (EVar "relocPat") (EVar "o"))) (EVar "ps"))))
(DFunDef false "relocPat" ((PVar "o") (PCon "PList" (PVar "ps"))) (EApp (EVar "PList") (EApp (EApp (EVar "map") (EApp (EVar "relocPat") (EVar "o"))) (EVar "ps"))))
(DFunDef false "relocPat" ((PVar "o") (PCon "PRec" (PVar "c") (PVar "fields") (PVar "open"))) (EApp (EApp (EApp (EVar "PRec") (EVar "c")) (EApp (EApp (EVar "map") (EApp (EVar "relocField") (EVar "o"))) (EVar "fields"))) (EVar "open")))
(DFunDef false "relocPat" (PWild (PCon "PWild")) (EVar "PWild"))
(DFunDef false "relocPat" (PWild (PAs "p" (PCon "PLit" PWild))) (EVar "p"))
(DFunDef false "relocPat" (PWild (PAs "p" (PCon "PRng" PWild PWild PWild))) (EVar "p"))
(DTypeSig false "relocField" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "RecPatField") (TyCon "RecPatField"))))
(DFunDef false "relocField" ((PVar "o") (PCon "RecPatField" (PVar "n") (PVar "l") (PVar "bid") (PVar "sub"))) (EApp (EApp (EApp (EApp (EVar "RecPatField") (EVar "n")) (EVar "l")) (EApp (EVar "o") (EVar "bid"))) (EApp (EApp (EVar "map") (EApp (EVar "relocPat") (EVar "o"))) (EVar "sub"))))
(DTypeSig false "relocExpr" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "ELam") (EApp (EApp (EVar "map") (EApp (EVar "relocPat") (EVar "o"))) (EVar "ps"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "b"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ELet" (PVar "l") (PVar "r") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "l")) (EVar "r")) (EApp (EApp (EVar "relocPat") (EVar "o")) (EVar "p"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e1"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e2"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ELetGroup" (PVar "bs") (PVar "e2"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EVar "map") (EApp (EVar "relocBind") (EVar "o"))) (EVar "bs"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e2"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e0"))) (EApp (EApp (EVar "map") (EApp (EVar "relocArm") (EVar "o"))) (EVar "arms"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EVar "map") (EApp (EVar "relocGuardArm") (EVar "o"))) (EVar "arms"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EVar "map") (EApp (EVar "relocStmt") (EVar "o"))) (EVar "stmts"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "d")) (EApp (EApp (EVar "map") (EApp (EVar "relocStmt") (EVar "o"))) (EVar "stmts"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ELoc" (PVar "l") (PVar "x"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EDoOrigin" (PVar "l") (PVar "x"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "a"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "b"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "c"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "t"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "el"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "a"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "b"))) (EVar "r")))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "a"))) (EVar "r")))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "a"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "b"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EFieldAccess" (PVar "x") (PVar "n") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))) (EVar "n")) (EVar "r")))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "relocAssign") (EVar "o"))) (EVar "fs"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ERecordUpdate" (PVar "x") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))) (EApp (EApp (EVar "map") (EApp (EVar "relocAssign") (EVar "o"))) (EVar "fs"))) (EVar "r")))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EVariantUpdate" (PVar "c") (PVar "x") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))) (EApp (EApp (EVar "map") (EApp (EVar "relocAssign") (EVar "o"))) (EVar "fs"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EVar "map") (EApp (EVar "relocExpr") (EVar "o"))) (EVar "es"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EVar "map") (EApp (EVar "relocExpr") (EVar "o"))) (EVar "es"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EVar "map") (EApp (EVar "relocExpr") (EVar "o"))) (EVar "es"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EIndex" (PVar "x") (PVar "i"))) (EApp (EApp (EVar "EIndex") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "i"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "lo"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "lo"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ESlice" (PVar "x") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "lo"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EAnnot" (PVar "x") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))) (EVar "t")))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EHeadAnnot" (PVar "x") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))) (EVar "t")))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EVar "map") (EApp (EVar "relocInterp") (EVar "o"))) (EVar "parts"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "x")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x")))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ESection" (PCon "SecLeft" (PVar "x") (PVar "op")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecLeft") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))) (EVar "op"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EVar "map") (ELam ((PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "k")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "v"))))) (EVar "kvs"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EVar "map") (EApp (EVar "relocExpr") (EVar "o"))) (EVar "es"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EAsPat" (PVar "n") (PVar "x"))) (EApp (EApp (EVar "EAsPat") (EVar "n")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "ELit" PWild))) (EVar "e"))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "EVar" PWild))) (EVar "e"))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "ESection" (PCon "SecBare" PWild)))) (EVar "e"))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "EMethodRef" PWild))) (EVar "e"))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "EDictApp" PWild))) (EVar "e"))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "EVarAt" PWild PWild))) (EVar "e"))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "EVarId" PWild PWild))) (EVar "e"))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "EMethodAt" PWild PWild PWild))) (EVar "e"))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "EDictAt" PWild PWild))) (EVar "e"))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "ENumLit" PWild PWild PWild))) (EVar "e"))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "EWideLit" PWild PWild PWild PWild))) (EVar "e"))
(DTypeSig false "relocArm" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "Arm") (TyCon "Arm"))))
(DFunDef false "relocArm" ((PVar "o") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "b"))) (EApp (EApp (EApp (EVar "Arm") (EApp (EApp (EVar "relocPat") (EVar "o")) (EVar "p"))) (EApp (EApp (EVar "map") (EApp (EVar "relocGuard") (EVar "o"))) (EVar "gs"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "b"))))
(DTypeSig false "relocGuard" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "Guard") (TyCon "Guard"))))
(DFunDef false "relocGuard" ((PVar "o") (PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))))
(DFunDef false "relocGuard" ((PVar "o") (PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EApp (EApp (EVar "relocPat") (EVar "o")) (EVar "p"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))))
(DTypeSig false "relocGuardArm" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "GuardArm") (TyCon "GuardArm"))))
(DFunDef false "relocGuardArm" ((PVar "o") (PCon "GuardArm" (PVar "gs") (PVar "b"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EVar "map") (EApp (EVar "relocGuard") (EVar "o"))) (EVar "gs"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "b"))))
(DTypeSig false "relocStmt" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "DoStmt") (TyCon "DoStmt"))))
(DFunDef false "relocStmt" ((PVar "o") (PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))))
(DFunDef false "relocStmt" ((PVar "o") (PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EApp (EApp (EVar "relocPat") (EVar "o")) (EVar "p"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))))
(DFunDef false "relocStmt" ((PVar "o") (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EApp (EApp (EVar "relocPat") (EVar "o")) (EVar "p"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))) (EVar "site")))
(DFunDef false "relocStmt" ((PVar "o") (PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))))
(DFunDef false "relocStmt" ((PVar "o") (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))))
(DTypeSig false "relocAssign" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign"))))
(DFunDef false "relocAssign" ((PVar "o") (PCon "FieldAssign" (PVar "n") (PVar "v"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "v"))))
(DTypeSig false "relocInterp" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "InterpPart") (TyCon "InterpPart"))))
(DFunDef false "relocInterp" ((PVar "o") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))))
(DFunDef false "relocInterp" (PWild (PAs "p" (PCon "InterpStr" PWild))) (EVar "p"))
(DData Public "BinderRun" () ((variant "BinderRun" (ConNamed (field "brFirst" (TyCon "Int")) (field "brCount" (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "BinderRun")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "BinderRun" ((rf "brFirst" (PVar "__a0")) (rf "brCount" (PVar "__a1"))) false) (PRec "BinderRun" ((rf "brFirst" (PVar "__b0")) (rf "brCount" (PVar "__b1"))) false)) () (EBinOp "&&" (EApp (EApp (EVar "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EVar "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Debug" ((TyCon "BinderRun")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "BinderRun" ((rf "brFirst" (PVar "__a0")) (rf "brCount" (PVar "__a1"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "BinderRun {")) (ELit (LString " brFirst = "))) (EApp (EVar "debug") (EVar "__a0"))) (ELit (LString ", brCount = "))) (EApp (EVar "debug") (EVar "__a1"))) (ELit (LString " }"))))))))
(DTypeSig true "binderSpan" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "BinderRun"))))
(DFunDef false "binderSpan" ((PVar "decls")) (EBlock (DoLet false false (PVar "lo") (EApp (EVar "Ref") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))) (DoLet false false (PVar "hi") (EApp (EVar "Ref") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))) (DoLet false false (PVar "count") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "note") (ELam ((PVar "bid")) (EMatch (EVar "bid") (arm (PCon "BinderId" PWild (PVar "i")) ((GBool (EBinOp ">=" (EVar "i") (ELit (LInt 0))))) (EBlock (DoLet false false PWild (EIf (EBinOp "||" (EBinOp "<" (EFieldAccess (EVar "lo") "value") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EFieldAccess (EVar "lo") "value"))) (EApp (EApp (EVar "setRef") (EVar "lo")) (EVar "i")) (ELit LUnit))) (DoLet false false PWild (EIf (EBinOp ">" (EVar "i") (EFieldAccess (EVar "hi") "value")) (EApp (EApp (EVar "setRef") (EVar "hi")) (EVar "i")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "count")) (EBinOp "+" (EFieldAccess (EVar "count") "value") (ELit (LInt 1))))) (DoExpr (EVar "bid")))) (arm PWild () (EVar "bid"))))) (DoLet false false PWild (EApp (EApp (EVar "mapBinders") (EVar "note")) (EVar "decls"))) (DoExpr (EIf (EBinOp "==" (EFieldAccess (EVar "count") "value") (ELit (LInt 0))) (EApp (EVar "Some") (ERecordCreate "BinderRun" ((fa "brFirst" (ELit (LInt 0))) (fa "brCount" (ELit (LInt 0)))))) (EIf (EBinOp "==" (EBinOp "+" (EBinOp "-" (EFieldAccess (EVar "hi") "value") (EFieldAccess (EVar "lo") "value")) (ELit (LInt 1))) (EFieldAccess (EVar "count") "value")) (EApp (EVar "Some") (ERecordCreate "BinderRun" ((fa "brFirst" (EFieldAccess (EVar "lo") "value")) (fa "brCount" (EFieldAccess (EVar "count") "value"))))) (EVar "None"))))))
(DTypeSig false "maxBinderRun" (TyCon "Int"))
(DFunDef false "maxBinderRun" () (ELit (LInt 4194304)))
(DTypeSig true "binderRunIs" (TyFun (TyCon "BinderRun") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))
(DFunDef false "binderRunIs" ((PVar "run") (PVar "decls")) (EIf (EBinOp "||" (EBinOp "<" (EFieldAccess (EVar "run") "brCount") (ELit (LInt 0))) (EBinOp ">" (EFieldAccess (EVar "run") "brCount") (EVar "maxBinderRun"))) (EVar "False") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "count") (EFieldAccess (EVar "run") "brCount")) (DoLet false false (PVar "base") (EFieldAccess (EVar "run") "brFirst")) (DoLet false false (PVar "seen") (EApp (EApp (EVar "arrayMake") (EVar "count")) (EVar "False"))) (DoLet false false (PVar "ok") (EApp (EVar "Ref") (EVar "True"))) (DoLet false false (PVar "taken") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "note") (ELam ((PVar "bid")) (EMatch (EVar "bid") (arm (PCon "BinderId" PWild (PVar "i")) ((GBool (EBinOp ">=" (EVar "i") (ELit (LInt 0))))) (EBlock (DoLet false false (PVar "j") (EBinOp "-" (EVar "i") (EVar "base"))) (DoLet false false PWild (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "j") (ELit (LInt 0))) (EBinOp ">=" (EVar "j") (EVar "count"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "seen"))) (EApp (EApp (EVar "setRef") (EVar "ok")) (EVar "False")) (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "j")) (EVar "True")) (EVar "seen")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "taken")) (EBinOp "+" (EFieldAccess (EVar "taken") "value") (ELit (LInt 1))))) (DoExpr (EVar "bid")))) (arm PWild () (EVar "bid"))))) (DoLet false false PWild (EApp (EApp (EVar "mapBinders") (EVar "note")) (EVar "decls"))) (DoExpr (EBinOp "&&" (EFieldAccess (EVar "ok") "value") (EBinOp "==" (EFieldAccess (EVar "taken") "value") (EVar "count"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "relocDecls" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "relocDecls" ((PVar "offset") (PVar "decls")) (EApp (EApp (EVar "mapBinders") (EApp (EVar "relocId") (EVar "offset"))) (EVar "decls")))
(DTypeSig false "relocated" (TyFun (TyCon "Int") (TyFun (TyCon "PreludeElab") (TyCon "PreludeElab"))))
(DFunDef false "relocated" ((PVar "offset") (PVar "pe")) (EIf (EBinOp "==" (EVar "offset") (ELit (LInt 0))) (EVar "pe") (ERecordUpdate (EVar "pe") ((fa "peDecls" (EApp (EApp (EVar "mapBinders") (EApp (EVar "relocId") (EVar "offset"))) (EFieldAccess (EVar "pe") "peDecls"))) (fa "peBinders" (EApp (EApp (EVar "map") (ELam ((PVar "row")) (ERecordUpdate (EVar "row") ((fa "brId" (EApp (EApp (EVar "relocId") (EVar "offset")) (EFieldAccess (EVar "row") "brId"))))))) (EFieldAccess (EVar "pe") "peBinders"))) (fa "peBinderBase" (EBinOp "+" (EFieldAccess (EVar "pe") "peBinderBase") (EVar "offset")))))))
(DTypeSig false "preludeElabCacheRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "PreludeElab") (TyCon "Bool")))))
(DFunDef false "preludeElabCacheRef" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "seedPreludeElab" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "PreludeElab") (TyCon "Unit"))))
(DFunDef false "seedPreludeElab" ((PVar "generation") (PVar "pe")) (EMatch (EApp (EApp (EVar "evidenceRowsProblem") (EFieldAccess (EVar "pe") "peEvCounter")) (EFieldAccess (EVar "pe") "peEvidence")) (arm (PCon "Some" PWild) () (ELit LUnit)) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EApp (EVar "setPreludeEvidence") (EFieldAccess (EVar "pe") "peEvCounter")) (EFieldAccess (EVar "pe") "peEvidence"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "preludeElabCacheRef")) (EApp (EVar "Some") (ETuple (EVar "generation") (EVar "pe") (EVar "False")))))))))
(DTypeSig true "preludeElabHit" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "PreludeElab"))))
(DFunDef false "preludeElabHit" ((PVar "generation")) (EMatch (EUnOp "!" (EVar "preludeElabCacheRef")) (arm (PCon "Some" (PTuple (PVar "seen") (PVar "pe") PWild)) ((GBool (EBinOp "==" (EVar "seen") (EVar "generation")))) (EApp (EVar "Some") (EVar "pe"))) (arm PWild () (EVar "None"))))
(DTypeSig true "preludeElabFor" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "PreludeElab")))))
(DFunDef false "preludeElabFor" ((PVar "generation") (PVar "core")) (EMatch (EUnOp "!" (EVar "preludeElabCacheRef")) (arm (PCon "Some" (PTuple (PVar "seen") (PVar "pe") (PCon "True"))) ((GBool (EBinOp "==" (EVar "seen") (EVar "generation")))) (EApp (EVar "Some") (EVar "pe"))) (arm (PCon "Some" (PTuple (PVar "seen") (PVar "pe") (PCon "False"))) ((GBool (EBinOp "==" (EVar "seen") (EVar "generation")))) (EMatch (EApp (EVar "binderSpan") (EVar "core")) (arm (PCon "Some" (PVar "run")) ((GBool (EBinOp "==" (EFieldAccess (EVar "run") "brCount") (EFieldAccess (EVar "pe") "peBinderCount")))) (EBlock (DoLet false false (PVar "moved") (EApp (EApp (EVar "relocated") (EBinOp "-" (EFieldAccess (EVar "run") "brFirst") (EFieldAccess (EVar "pe") "peBinderBase"))) (EVar "pe"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "preludeElabCacheRef")) (EApp (EVar "Some") (ETuple (EVar "generation") (EVar "moved") (EVar "True"))))) (DoExpr (EApp (EVar "Some") (EVar "moved"))))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig true "withShippedRows" (TyFun (TyApp (TyCon "Option") (TyCon "PreludeElab")) (TyFun (TyCon "EvTable") (TyFun (TyCon "BinderTypeTable") (TyTuple (TyCon "EvTable") (TyCon "BinderTypeTable"))))))
(DFunDef false "withShippedRows" ((PCon "None") (PVar "evidence") (PVar "binders")) (ETuple (EVar "evidence") (EVar "binders")))
(DFunDef false "withShippedRows" ((PCon "Some" (PVar "pe")) (PVar "evidence") (PVar "binders")) (ETuple (EBinOp "++" (EFieldAccess (EVar "pe") "peEvidence") (EVar "evidence")) (EApp (EApp (EApp (EVar "fold") (ELam ((PVar "acc") (PVar "row")) (EApp (EApp (EVar "addBinderRow") (EVar "row")) (EVar "acc")))) (EVar "binders")) (EFieldAccess (EVar "pe") "peBinders"))))
(DTypeSig true "heldPreludeEvCounter" (TyFun (TyCon "Unit") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "heldPreludeEvCounter" (PWild) (EApp (EApp (EVar "map") (ELam ((PTuple PWild (PVar "pe") PWild)) (EFieldAccess (EVar "pe") "peEvCounter"))) (EUnOp "!" (EVar "preludeElabCacheRef"))))
# MARK
(DUse false (UseGroup ("frontend" "ast") ((mem "Arm" true) (mem "BinderId" true) (mem "Decl" true) (mem "DoStmt" true) (mem "EvEntry" true) (mem "EvId" true) (mem "EvTable" false) (mem "Expr" true) (mem "FieldAssign" true) (mem "FunClause" true) (mem "Guard" true) (mem "GuardArm" true) (mem "IfaceMethod" true) (mem "ImplMethod" true) (mem "InterpPart" true) (mem "LetBind" true) (mem "MethodDefault" true) (mem "Pat" true) (mem "RecPatField" true) (mem "Section" true))))
(DUse false (UseGroup ("frontend" "ast_codec") ((mem "declsSExp" false) (mem "evEntriesSExp" false) (mem "readBinderId" false) (mem "readBool" false) (mem "readDecls" false) (mem "readEvEntries" false) (mem "sexpBinderId" false) (mem "sexpBool" false))))
(DUse false (UseGroup ("list") ((mem "reverse" false))))
(DUse false (UseAlias ("string") "S"))
(DUse false (UseGroup ("support" "sexp_value") ((mem "SExp" true) (mem "SexpError" true) (mem "SexpCursor" false) (mem "atomInt" false) (mem "cursorAtEnd" false) (mem "cursorAtom" false) (mem "cursorClose" false) (mem "cursorFail" false) (mem "cursorFailed" false) (mem "cursorInt" false) (mem "cursorList" false) (mem "cursorOf" false) (mem "cursorOffset" false) (mem "cursorOpen" false) (mem "cursorPeek" false) (mem "cursorChar" false) (mem "expectAtom" false) (mem "parseSExp" false) (mem "renderSExp" false))))
(DUse false (UseGroup ("support" "util") ((mem "splitOnChar" false))))
(DUse false (UseGroup ("types" "evidence_coverage") ((mem "EvidenceFault" true) (mem "evidenceFaults" false))))
(DUse false (UseGroup ("types" "interface_frame") ((mem "InterfaceFault" true) (mem "KeyGate" false) (mem "bodyOf" false) (mem "checkedFramed" false) (mem "failure" false) (mem "firstLine" false) (mem "framedFile" false) (mem "keyFields" false) (mem "noGate" false) (mem "refuse" false) (mem "renderFramedFault" false) (mem "sha256Hex" false))))
(DUse false (UseGroup ("types" "prelude_interface") ((mem "InterfaceKey" true))))
(DUse false (UseGroup ("types" "route_key") ((mem "setPreludeEvidence" false))))
(DUse false (UseGroup ("types" "runtime_types") ((mem "BinderRow" true) (mem "BinderTypeTable" false) (mem "RuntimeType" true) (mem "addBinderRow" false) (mem "binderOrdinal" false) (mem "runtimeTypeName" false) (mem "runtimeTypeFromName" false))))
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
(DFunDef false "formatVersion" () (ELit (LInt 3)))
(DTypeSig true "elabKeyOf" (TyFun (TyCon "InterfaceKey") (TyCon "InterfaceKey")))
(DFunDef false "elabKeyOf" ((PVar "key")) (ERecordCreate "InterfaceKey" ((fa "ikFormat" (EVar "formatVersion")) (fa "ikSources" (EFieldAccess (EVar "key") "ikSources")) (fa "ikCompiler" (EFieldAccess (EVar "key") "ikCompiler")))))
(DTypeSig false "sexpBinder" (TyFun (TyCon "BinderRow") (TyCon "SExp")))
(DFunDef false "sexpBinder" ((PVar "row")) (EApp (EVar "SList") (EListLit (EApp (EVar "sexpBinderId") (EFieldAccess (EVar "row") "brId")) (EApp (EVar "SAtom") (EFieldAccess (EVar "row") "brName")) (EApp (EVar "SAtom") (EApp (EVar "runtimeTypeName") (EFieldAccess (EVar "row") "brType"))) (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (ELam ((PVar "t")) (EApp (EVar "SAtom") (EApp (EVar "runtimeTypeName") (EVar "t"))))) (EMatch (EFieldAccess (EVar "row") "brReturns") (arm (PCon "Some" (PVar "t")) () (EListLit (EVar "t"))) (arm (PCon "None") () (EListLit))))) (EApp (EVar "sexpBool") (EFieldAccess (EVar "row") "brSigned")))))
(DTypeSig false "binderLine" (TyFun (TyApp (TyCon "List") (TyCon "BinderRow")) (TyCon "String")))
(DFunDef false "binderLine" ((PVar "rows")) (EApp (EVar "renderSExp") (EApp (EVar "SList") (EApp (EApp (EMethodRef "map") (EVar "sexpBinder")) (EVar "rows")))))
(DTypeSig false "countersNode" (TyFun (TyCon "PreludeElab") (TyCon "SExp")))
(DFunDef false "countersNode" ((PVar "pe")) (EApp (EVar "SList") (EListLit (EApp (EVar "SAtom") (ELit (LString "counters"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pe") "peEvCounter"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pe") "peLocalCounter"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pe") "peBinderCount"))) (EApp (EVar "SAtom") (EApp (EVar "intToString") (EFieldAccess (EVar "pe") "peBinderBase"))))))
(DTypeSig false "coveredText" (TyFun (TyCon "PreludeElab") (TyCon "String")))
(DFunDef false "coveredText" ((PVar "pe")) (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "")) (EApp (EMethodRef "display") (EApp (EVar "renderSExp") (EApp (EVar "countersNode") (EVar "pe"))))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EVar "renderSExp") (EApp (EVar "declsSExp") (EFieldAccess (EVar "pe") "peDecls"))))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EVar "renderSExp") (EApp (EVar "evEntriesSExp") (EFieldAccess (EVar "pe") "peEvidence"))))) (ELit (LString "\n"))) (EApp (EMethodRef "display") (EApp (EVar "binderLine") (EFieldAccess (EVar "pe") "peBinders")))) (ELit (LString "\n"))))
(DTypeSig true "encodeElabFile" (TyFun (TyCon "InterfaceKey") (TyFun (TyCon "PreludeElab") (TyCon "String"))))
(DFunDef false "encodeElabFile" ((PVar "key") (PVar "pe")) (EBlock (DoLet false false (PVar "covered") (EApp (EVar "coveredText") (EVar "pe"))) (DoExpr (EApp (EApp (EApp (EApp (EVar "framedFile") (ELit (LString "medaka-elab"))) (EVar "formatVersion")) (EApp (EVar "keyFields") (EVar "key"))) (EVar "covered")))))
(DTypeSig true "framedDigestOf" (TyFun (TyCon "String") (TyCon "String")))
(DFunDef false "framedDigestOf" ((PVar "text")) (EApp (EVar "sha256Hex") (EApp (EVar "bodyOf") (EVar "text"))))
(DTypeSig true "renderElabFault" (TyFun (TyCon "InterfaceFault") (TyCon "String")))
(DFunDef false "renderElabFault" ((PVar "fault")) (EApp (EApp (EApp (EVar "renderFramedFault") (ELit (LString "elaborated trees"))) (EVar "formatVersion")) (EVar "fault")))
(DData Private "Counters" () ((variant "Counters" (ConNamed (field "cEvidence" (TyCon "Int")) (field "cLocal" (TyCon "Int")) (field "cBinders" (TyCon "Int")) (field "cBinderBase" (TyCon "Int"))))) ())
(DTypeSig false "countersOf" (TyFun (TyCon "SExp") (TyApp (TyApp (TyCon "Result") (TyCon "SexpError")) (TyCon "Counters"))))
(DFunDef false "countersOf" ((PCon "SList" (PList (PCon "SAtom" (PLit (LString "counters"))) (PVar "k") (PVar "l") (PVar "n") (PVar "b")))) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "k"))) (ELam ((PVar "kk")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "l"))) (ELam ((PVar "ll")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "n"))) (ELam ((PVar "nn")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "atomInt") (ELit (LString "counters"))) (EVar "b"))) (ELam ((PVar "bb")) (EApp (EVar "Ok") (ERecordCreate "Counters" ((fa "cEvidence" (EVar "kk")) (fa "cLocal" (EVar "ll")) (fa "cBinders" (EVar "nn")) (fa "cBinderBase" (EVar "bb"))))))))))))))
(DFunDef false "countersOf" (PWild) (EApp (EVar "Err") (ERecordCreate "SexpError" ((fa "seOffset" (ELit (LInt 0))) (fa "sePath" (ELit (LString "counters"))) (fa "seWhat" (ELit (LString "expected a counters line of four numbers")))))))
(DTypeSig false "readRuntimeType" (TyFun (TyCon "SexpCursor") (TyCon "RuntimeType")))
(DFunDef false "readRuntimeType" ((PVar "cur")) (EMatch (EApp (EVar "runtimeTypeFromName") (EApp (EVar "cursorAtom") (EVar "cur"))) (arm (PCon "Some" (PVar "t")) () (EVar "t")) (arm (PCon "None") () (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "RTValue")))))
(DTypeSig false "readBinder" (TyFun (TyCon "SexpCursor") (TyCon "BinderRow")))
(DFunDef false "readBinder" ((PVar "cur")) (EBlock (DoLet false false PWild (EApp (EVar "cursorOpen") (EVar "cur"))) (DoLet false false (PVar "bid") (EApp (EVar "readBinderId") (EVar "cur"))) (DoLet false false (PVar "name") (EApp (EVar "cursorAtom") (EVar "cur"))) (DoLet false false (PVar "ty") (EApp (EVar "readRuntimeType") (EVar "cur"))) (DoLet false false (PVar "returns") (EMatch (EApp (EApp (EVar "cursorList") (EVar "readRuntimeType")) (EVar "cur")) (arm (PList) () (EVar "None")) (arm (PList (PVar "t")) () (EApp (EVar "Some") (EVar "t"))) (arm PWild () (EApp (EApp (EVar "cursorFail") (EVar "cur")) (EVar "None"))))) (DoLet false false (PVar "signed") (EApp (EVar "readBool") (EVar "cur"))) (DoLet false false PWild (EApp (EVar "cursorClose") (EVar "cur"))) (DoExpr (ERecordCreate "BinderRow" ((fa "brId" (EVar "bid")) (fa "brName" (EVar "name")) (fa "brType" (EVar "ty")) (fa "brReturns" (EVar "returns")) (fa "brSigned" (EVar "signed")))))))
(DTypeSig true "readElabFile" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "PreludeElab")))))
(DFunDef false "readElabFile" () (EApp (EVar "readElabFileGated") (EVar "noGate")))
(DTypeSig true "readElabFileGated" (TyFun (TyCon "KeyGate") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "PreludeElab"))))))
(DFunDef false "readElabFileGated" ((PVar "gate") (PVar "text")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "checkedElab") (EVar "gate")) (EVar "text"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "key") (PVar "covered")) () (EApp (EApp (EVar "decodeCovered") (EVar "key")) (EVar "covered")))))))
(DTypeSig false "checkedElab" (TyFun (TyCon "KeyGate") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "String"))))))
(DFunDef false "checkedElab" () (EApp (EApp (EVar "checkedFramed") (ELit (LString "medaka-elab"))) (EVar "formatVersion")))
(DTypeSig false "decodeCovered" (TyFun (TyCon "InterfaceKey") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "PreludeElab"))))))
(DFunDef false "decodeCovered" ((PVar "key") (PVar "covered")) (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EApp (EVar "firstLine") (ELit (LString "counters"))) (ELit (LString "no counters line"))) (EVar "covered"))) (ELam ((PVar "__do_x")) (EMatch (EVar "__do_x") (arm (PTuple (PVar "node") (PVar "rest")) () (EApp (EApp (EMethodRef "andThen") (EApp (EApp (EVar "mapErr") (EVar "Malformed")) (EApp (EVar "countersOf") (EVar "node")))) (ELam ((PVar "counters")) (EApp (EApp (EApp (EVar "decodeBody") (EVar "key")) (EVar "counters")) (EVar "rest")))))))))
(DTypeSig false "decodeBody" (TyFun (TyCon "InterfaceKey") (TyFun (TyCon "Counters") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyTuple (TyCon "InterfaceKey") (TyCon "PreludeElab")))))))
(DFunDef false "decodeBody" ((PVar "key") (PVar "counters") (PVar "body")) (EBlock (DoLet false false (PVar "cur") (EApp (EVar "cursorOf") (EVar "body"))) (DoExpr (EMatch (EApp (EVar "readDecls") (EVar "cur")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "decls")) () (EMatch (EApp (EVar "readEvEntries") (EVar "cur")) (arm (PCon "Err" (PVar "e")) () (EApp (EVar "failure") (EVar "e"))) (arm (PCon "Ok" (PVar "evidence")) () (EBlock (DoLet false false (PVar "binders") (EApp (EApp (EVar "cursorList") (EVar "readBinder")) (EVar "cur"))) (DoExpr (EIf (EApp (EVar "cursorFailed") (EVar "cur")) (EApp (EApp (EVar "refuse") (ELit (LString "binders"))) (ELit (LString "malformed or truncated encoding"))) (EIf (EApp (EVar "not") (EApp (EVar "cursorAtEnd") (EVar "cur"))) (EApp (EVar "failure") (ERecordCreate "SexpError" ((fa "seOffset" (EApp (EVar "cursorOffset") (EVar "cur"))) (fa "sePath" (ELit (LString ""))) (fa "seWhat" (ELit (LString "trailing text after the binder rows")))))) (EBlock (DoLet false false (PVar "pe") (ERecordCreate "PreludeElab" ((fa "peDecls" (EVar "decls")) (fa "peEvidence" (EVar "evidence")) (fa "peBinders" (EVar "binders")) (fa "peEvCounter" (EFieldAccess (EVar "counters") "cEvidence")) (fa "peLocalCounter" (EFieldAccess (EVar "counters") "cLocal")) (fa "peBinderCount" (EFieldAccess (EVar "counters") "cBinders")) (fa "peBinderBase" (EFieldAccess (EVar "counters") "cBinderBase"))))) (DoExpr (EMatch (EApp (EVar "countersProblem") (EVar "pe")) (arm (PCon "Some" (PTuple (PVar "path") (PVar "what"))) () (EApp (EApp (EVar "refuse") (EVar "path")) (EVar "what"))) (arm (PCon "None") () (EApp (EVar "Ok") (ETuple (EVar "key") (EVar "pe"))))))))))))))))))
(DTypeSig false "countersProblem" (TyFun (TyCon "PreludeElab") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "countersProblem" ((PVar "pe")) (EIf (EBinOp "||" (EBinOp "/=" (EFieldAccess (EVar "pe") "peBinderCount") (EApp (EMethodRef "length") (EFieldAccess (EVar "pe") "peBinders"))) (EBinOp "/=" (EFieldAccess (EVar "pe") "peBinderBase") (EApp (EVar "binderBase") (EFieldAccess (EVar "pe") "peBinders")))) (EApp (EVar "Some") (ETuple (ELit (LString "counters/binders")) (ELit (LString "the binder count or base disagrees with the rows")))) (EIf (EBinOp "||" (EBinOp "<" (EFieldAccess (EVar "pe") "peLocalCounter") (ELit (LInt 0))) (EBinOp "<" (EFieldAccess (EVar "pe") "peLocalCounter") (EApp (EVar "localHighWater") (EApp (EVar "declsSExp") (EFieldAccess (EVar "pe") "peDecls"))))) (EApp (EVar "Some") (ETuple (ELit (LString "counters/local")) (ELit (LString "the local-abstraction counter is not above every local name of the trees")))) (EIf (EVar "otherwise") (EMatch (EApp (EApp (EVar "evidenceRowsProblem") (EFieldAccess (EVar "pe") "peEvCounter")) (EFieldAccess (EVar "pe") "peEvidence")) (arm (PCon "Some" (PVar "what")) () (EApp (EVar "Some") (ETuple (ELit (LString "counters/evidence")) (EVar "what")))) (arm (PCon "None") () (EApp (EVar "treeSitesProblem") (EVar "pe")))) (EApp (EVar "__fallthrough__") (ELit LUnit))))))
(DTypeSig false "maxEvidenceCounter" (TyCon "Int"))
(DFunDef false "maxEvidenceCounter" () (ELit (LInt 4194304)))
(DTypeSig false "evidenceRowsProblem" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "EvEntry")) (TyApp (TyCon "Option") (TyCon "String")))))
(DFunDef false "evidenceRowsProblem" ((PVar "counter") (PVar "rows")) (EIf (EBinOp "||" (EBinOp "<" (EVar "counter") (ELit (LInt 0))) (EBinOp ">" (EVar "counter") (EVar "maxEvidenceCounter"))) (EApp (EVar "Some") (ELit (LString "the evidence counter is out of range"))) (EIf (EVar "otherwise") (EApp (EApp (EApp (EVar "rowsProblem") (EApp (EApp (EVar "arrayMake") (EVar "counter")) (EVar "False"))) (EVar "counter")) (EVar "rows")) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig false "rowsProblem" (TyFun (TyApp (TyCon "Array") (TyCon "Bool")) (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "EvEntry")) (TyApp (TyCon "Option") (TyCon "String"))))))
(DFunDef false "rowsProblem" (PWild PWild (PList)) (EVar "None"))
(DFunDef false "rowsProblem" ((PVar "seen") (PVar "counter") (PCons (PCon "EvEntry" (PCon "EvId" PWild (PVar "i")) PWild) (PVar "rest"))) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EApp (EVar "Some") (ELit (LString "an evidence row has a negative ordinal"))) (EIf (EBinOp ">=" (EVar "i") (EVar "counter")) (EApp (EVar "Some") (ELit (LString "an evidence row is at or above the evidence counter"))) (EIf (EApp (EApp (EVar "arrayGetUnsafe") (EVar "i")) (EVar "seen")) (EApp (EVar "Some") (ELit (LString "two evidence rows share one ordinal"))) (EIf (EVar "otherwise") (EBlock (DoLet false false PWild (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "i")) (EVar "True")) (EVar "seen"))) (DoExpr (EApp (EApp (EApp (EVar "rowsProblem") (EVar "seen")) (EVar "counter")) (EVar "rest")))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))))
(DTypeSig false "treeSitesProblem" (TyFun (TyCon "PreludeElab") (TyApp (TyCon "Option") (TyTuple (TyCon "String") (TyCon "String")))))
(DFunDef false "treeSitesProblem" ((PVar "pe")) (EIf (EApp (EApp (EDictApp "any") (EApp (EVar "aboveCounter") (EFieldAccess (EVar "pe") "peEvCounter"))) (EApp (EApp (EVar "evidenceFaults") (EApp (EVar "Some") (ETuple (EFieldAccess (EVar "pe") "peDecls") (EListLit)))) (EListLit))) (EApp (EVar "Some") (ETuple (ELit (LString "counters/evidence")) (ELit (LString "a tree site is at or above the evidence counter")))) (EVar "None")))
(DTypeSig false "aboveCounter" (TyFun (TyCon "Int") (TyFun (TyCon "EvidenceFault") (TyCon "Bool"))))
(DFunDef false "aboveCounter" ((PVar "counter") (PCon "MissingEntry" (PLit (LString "")) (PVar "i") PWild)) (EBinOp ">=" (EVar "i") (EVar "counter")))
(DFunDef false "aboveCounter" (PWild PWild) (EVar "False"))
(DTypeSig true "readElabKey" (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "InterfaceKey"))))
(DFunDef false "readElabKey" () (EApp (EVar "readElabKeyGated") (EVar "noGate")))
(DTypeSig true "readElabKeyGated" (TyFun (TyCon "KeyGate") (TyFun (TyCon "String") (TyApp (TyApp (TyCon "Result") (TyCon "InterfaceFault")) (TyCon "InterfaceKey")))))
(DFunDef false "readElabKeyGated" ((PVar "gate") (PVar "text")) (EApp (EApp (EMethodRef "map") (EVar "fst")) (EApp (EApp (EVar "checkedElab") (EVar "gate")) (EVar "text"))))
(DTypeSig false "mapBinders" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "mapBinders" ((PVar "f") (PVar "decls")) (EApp (EApp (EMethodRef "map") (EApp (EVar "relocDecl") (EVar "f"))) (EVar "decls")))
(DTypeSig false "relocId" (TyFun (TyCon "Int") (TyFun (TyCon "BinderId") (TyCon "BinderId"))))
(DFunDef false "relocId" ((PVar "offset") (PCon "BinderId" (PVar "m") (PVar "i"))) (EIf (EBinOp "<" (EVar "i") (ELit (LInt 0))) (EApp (EApp (EVar "BinderId") (EVar "m")) (EVar "i")) (EApp (EApp (EVar "BinderId") (EVar "m")) (EBinOp "+" (EVar "i") (EVar "offset")))))
(DTypeSig false "relocDecl" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "Decl") (TyCon "Decl"))))
(DFunDef false "relocDecl" ((PVar "o") (PCon "DFunDef" (PVar "pub") (PVar "n") (PVar "ps") (PVar "e") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EApp (EApp (EVar "DFunDef") (EVar "pub")) (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "relocPat") (EVar "o"))) (EVar "ps"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))) (EVar "site")) (EApp (EVar "o") (EVar "bid"))))
(DFunDef false "relocDecl" ((PVar "o") (PCon "DLetGroup" (PVar "pub") (PVar "binds"))) (EApp (EApp (EVar "DLetGroup") (EVar "pub")) (EApp (EApp (EMethodRef "map") (EApp (EVar "relocBind") (EVar "o"))) (EVar "binds"))))
(DFunDef false "relocDecl" ((PVar "o") (PAs "d" (PRec "DInterface" ((rf "methods" None)) true))) (EVariantUpdate "DInterface" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (EApp (EVar "relocIfaceMethod") (EVar "o"))) (EVar "methods"))))))
(DFunDef false "relocDecl" ((PVar "o") (PAs "d" (PRec "DImpl" ((rf "methods" None)) true))) (EVariantUpdate "DImpl" (EVar "d") ((fa "methods" (EApp (EApp (EMethodRef "map") (EApp (EVar "relocImplMethod") (EVar "o"))) (EVar "methods"))))))
(DFunDef false "relocDecl" ((PVar "o") (PCon "DProp" (PVar "pub") (PVar "name") (PVar "params") (PVar "body"))) (EApp (EApp (EApp (EApp (EVar "DProp") (EVar "pub")) (EVar "name")) (EVar "params")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "body"))))
(DFunDef false "relocDecl" ((PVar "o") (PCon "DTest" (PVar "pub") (PVar "name") (PVar "body"))) (EApp (EApp (EApp (EVar "DTest") (EVar "pub")) (EVar "name")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "body"))))
(DFunDef false "relocDecl" ((PVar "o") (PCon "DAttrib" (PVar "attrs") (PVar "d"))) (EApp (EApp (EVar "DAttrib") (EVar "attrs")) (EApp (EApp (EVar "relocDecl") (EVar "o")) (EVar "d"))))
(DFunDef false "relocDecl" (PWild (PAs "d" (PCon "DTypeSig" PWild PWild PWild PWild))) (EVar "d"))
(DFunDef false "relocDecl" (PWild (PAs "d" (PCon "DExtern" PWild))) (EVar "d"))
(DFunDef false "relocDecl" (PWild (PAs "d" (PRec "DData" () false))) (EVar "d"))
(DFunDef false "relocDecl" (PWild (PAs "d" (PCon "DUse" PWild PWild PWild))) (EVar "d"))
(DFunDef false "relocDecl" (PWild (PAs "d" (PCon "DEffect" PWild PWild PWild PWild PWild PWild))) (EVar "d"))
(DFunDef false "relocDecl" (PWild (PAs "d" (PRec "DTypeAlias" () false))) (EVar "d"))
(DFunDef false "relocDecl" (PWild (PAs "d" (PRec "DNewtype" () false))) (EVar "d"))
(DTypeSig false "relocIfaceMethod" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "IfaceMethod") (TyCon "IfaceMethod"))))
(DFunDef false "relocIfaceMethod" ((PVar "o") (PCon "IfaceMethod" (PVar "n") (PVar "ty") (PCon "Some" (PCon "MethodDefault" (PVar "ps") (PVar "e"))) (PVar "mloc"))) (EApp (EApp (EApp (EApp (EVar "IfaceMethod") (EVar "n")) (EVar "ty")) (EApp (EVar "Some") (EApp (EApp (EVar "MethodDefault") (EApp (EApp (EMethodRef "map") (EApp (EVar "relocPat") (EVar "o"))) (EVar "ps"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))))) (EVar "mloc")))
(DFunDef false "relocIfaceMethod" (PWild (PAs "m" (PCon "IfaceMethod" PWild PWild (PCon "None") PWild))) (EVar "m"))
(DTypeSig false "relocImplMethod" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "ImplMethod") (TyCon "ImplMethod"))))
(DFunDef false "relocImplMethod" ((PVar "o") (PCon "ImplMethod" (PVar "n") (PVar "ps") (PVar "e"))) (EApp (EApp (EApp (EVar "ImplMethod") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "relocPat") (EVar "o"))) (EVar "ps"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))))
(DTypeSig false "relocBind" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "LetBind") (TyCon "LetBind"))))
(DFunDef false "relocBind" ((PVar "o") (PCon "LetBind" (PVar "n") (PVar "clauses") (PVar "site") (PVar "bid"))) (EApp (EApp (EApp (EApp (EVar "LetBind") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "relocClause") (EVar "o"))) (EVar "clauses"))) (EVar "site")) (EApp (EVar "o") (EVar "bid"))))
(DTypeSig false "relocClause" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "FunClause") (TyCon "FunClause"))))
(DFunDef false "relocClause" ((PVar "o") (PCon "FunClause" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "FunClause") (EApp (EApp (EMethodRef "map") (EApp (EVar "relocPat") (EVar "o"))) (EVar "ps"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "b"))))
(DTypeSig false "relocPat" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "Pat") (TyCon "Pat"))))
(DFunDef false "relocPat" ((PVar "o") (PCon "PVar" (PVar "n") (PVar "l") (PVar "bid"))) (EApp (EApp (EApp (EVar "PVar") (EVar "n")) (EVar "l")) (EApp (EVar "o") (EVar "bid"))))
(DFunDef false "relocPat" ((PVar "o") (PCon "PAs" (PVar "n") (PVar "l") (PVar "bid") (PVar "p"))) (EApp (EApp (EApp (EApp (EVar "PAs") (EVar "n")) (EVar "l")) (EApp (EVar "o") (EVar "bid"))) (EApp (EApp (EVar "relocPat") (EVar "o")) (EVar "p"))))
(DFunDef false "relocPat" ((PVar "o") (PCon "PCon" (PVar "c") (PVar "ps"))) (EApp (EApp (EVar "PCon") (EVar "c")) (EApp (EApp (EMethodRef "map") (EApp (EVar "relocPat") (EVar "o"))) (EVar "ps"))))
(DFunDef false "relocPat" ((PVar "o") (PCon "PCons" (PVar "h") (PVar "t"))) (EApp (EApp (EVar "PCons") (EApp (EApp (EVar "relocPat") (EVar "o")) (EVar "h"))) (EApp (EApp (EVar "relocPat") (EVar "o")) (EVar "t"))))
(DFunDef false "relocPat" ((PVar "o") (PCon "PTuple" (PVar "ps"))) (EApp (EVar "PTuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "relocPat") (EVar "o"))) (EVar "ps"))))
(DFunDef false "relocPat" ((PVar "o") (PCon "PList" (PVar "ps"))) (EApp (EVar "PList") (EApp (EApp (EMethodRef "map") (EApp (EVar "relocPat") (EVar "o"))) (EVar "ps"))))
(DFunDef false "relocPat" ((PVar "o") (PCon "PRec" (PVar "c") (PVar "fields") (PVar "open"))) (EApp (EApp (EApp (EVar "PRec") (EVar "c")) (EApp (EApp (EMethodRef "map") (EApp (EVar "relocField") (EVar "o"))) (EVar "fields"))) (EVar "open")))
(DFunDef false "relocPat" (PWild (PCon "PWild")) (EVar "PWild"))
(DFunDef false "relocPat" (PWild (PAs "p" (PCon "PLit" PWild))) (EVar "p"))
(DFunDef false "relocPat" (PWild (PAs "p" (PCon "PRng" PWild PWild PWild))) (EVar "p"))
(DTypeSig false "relocField" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "RecPatField") (TyCon "RecPatField"))))
(DFunDef false "relocField" ((PVar "o") (PCon "RecPatField" (PVar "n") (PVar "l") (PVar "bid") (PVar "sub"))) (EApp (EApp (EApp (EApp (EVar "RecPatField") (EVar "n")) (EVar "l")) (EApp (EVar "o") (EVar "bid"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "relocPat") (EVar "o"))) (EMethodRef "sub"))))
(DTypeSig false "relocExpr" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "Expr") (TyCon "Expr"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ELam" (PVar "ps") (PVar "b"))) (EApp (EApp (EVar "ELam") (EApp (EApp (EMethodRef "map") (EApp (EVar "relocPat") (EVar "o"))) (EVar "ps"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "b"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ELet" (PVar "l") (PVar "r") (PVar "p") (PVar "e1") (PVar "e2"))) (EApp (EApp (EApp (EApp (EApp (EVar "ELet") (EVar "l")) (EVar "r")) (EApp (EApp (EVar "relocPat") (EVar "o")) (EVar "p"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e1"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e2"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ELetGroup" (PVar "bs") (PVar "e2"))) (EApp (EApp (EVar "ELetGroup") (EApp (EApp (EMethodRef "map") (EApp (EVar "relocBind") (EVar "o"))) (EVar "bs"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e2"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EMatch" (PVar "e0") (PVar "arms"))) (EApp (EApp (EVar "EMatch") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e0"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "relocArm") (EVar "o"))) (EVar "arms"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EGuards" (PVar "arms"))) (EApp (EVar "EGuards") (EApp (EApp (EMethodRef "map") (EApp (EVar "relocGuardArm") (EVar "o"))) (EVar "arms"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EBlock" (PVar "stmts"))) (EApp (EVar "EBlock") (EApp (EApp (EMethodRef "map") (EApp (EVar "relocStmt") (EVar "o"))) (EVar "stmts"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EDo" (PVar "d") (PVar "stmts"))) (EApp (EApp (EVar "EDo") (EVar "d")) (EApp (EApp (EMethodRef "map") (EApp (EVar "relocStmt") (EVar "o"))) (EVar "stmts"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ELoc" (PVar "l") (PVar "x"))) (EApp (EApp (EVar "ELoc") (EVar "l")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EDoOrigin" (PVar "l") (PVar "x"))) (EApp (EApp (EVar "EDoOrigin") (EVar "l")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EApp" (PVar "a") (PVar "b"))) (EApp (EApp (EVar "EApp") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "a"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "b"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EIf" (PVar "c") (PVar "t") (PVar "el"))) (EApp (EApp (EApp (EVar "EIf") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "c"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "t"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "el"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EBinOp" (PVar "op") (PVar "a") (PVar "b") (PVar "r"))) (EApp (EApp (EApp (EApp (EVar "EBinOp") (EVar "op")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "a"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "b"))) (EVar "r")))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EUnOp" (PVar "op") (PVar "a") (PVar "r"))) (EApp (EApp (EApp (EVar "EUnOp") (EVar "op")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "a"))) (EVar "r")))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EInfix" (PVar "op") (PVar "a") (PVar "b"))) (EApp (EApp (EApp (EVar "EInfix") (EVar "op")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "a"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "b"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EFieldAccess" (PVar "x") (PVar "n") (PVar "r"))) (EApp (EApp (EApp (EVar "EFieldAccess") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))) (EVar "n")) (EVar "r")))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ERecordCreate" (PVar "n") (PVar "fs"))) (EApp (EApp (EVar "ERecordCreate") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "relocAssign") (EVar "o"))) (EVar "fs"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ERecordUpdate" (PVar "x") (PVar "fs") (PVar "r"))) (EApp (EApp (EApp (EVar "ERecordUpdate") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "relocAssign") (EVar "o"))) (EVar "fs"))) (EVar "r")))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EVariantUpdate" (PVar "c") (PVar "x") (PVar "fs"))) (EApp (EApp (EApp (EVar "EVariantUpdate") (EVar "c")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "relocAssign") (EVar "o"))) (EVar "fs"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EArrayLit" (PVar "es"))) (EApp (EVar "EArrayLit") (EApp (EApp (EMethodRef "map") (EApp (EVar "relocExpr") (EVar "o"))) (EVar "es"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EListLit" (PVar "es"))) (EApp (EVar "EListLit") (EApp (EApp (EMethodRef "map") (EApp (EVar "relocExpr") (EVar "o"))) (EVar "es"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ETuple" (PVar "es"))) (EApp (EVar "ETuple") (EApp (EApp (EMethodRef "map") (EApp (EVar "relocExpr") (EVar "o"))) (EVar "es"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EIndex" (PVar "x") (PVar "i"))) (EApp (EApp (EVar "EIndex") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "i"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ERangeList" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "ERangeList") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "lo"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ERangeArray" (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EVar "ERangeArray") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "lo"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ESlice" (PVar "x") (PVar "lo") (PVar "hi") (PVar "incl"))) (EApp (EApp (EApp (EApp (EVar "ESlice") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "lo"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "hi"))) (EVar "incl")))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EAnnot" (PVar "x") (PVar "t"))) (EApp (EApp (EVar "EAnnot") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))) (EVar "t")))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EHeadAnnot" (PVar "x") (PVar "t"))) (EApp (EApp (EVar "EHeadAnnot") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))) (EVar "t")))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EStringInterp" (PVar "parts"))) (EApp (EVar "EStringInterp") (EApp (EApp (EMethodRef "map") (EApp (EVar "relocInterp") (EVar "o"))) (EVar "parts"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ESection" (PCon "SecRight" (PVar "op") (PVar "x")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecRight") (EVar "op")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x")))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ESection" (PCon "SecLeft" (PVar "x") (PVar "op")))) (EApp (EVar "ESection") (EApp (EApp (EVar "SecLeft") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))) (EVar "op"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EMapLit" (PVar "n") (PVar "kvs"))) (EApp (EApp (EVar "EMapLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (ELam ((PTuple (PVar "k") (PVar "v"))) (ETuple (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "k")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "v"))))) (EVar "kvs"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "ESetLit" (PVar "n") (PVar "es"))) (EApp (EApp (EVar "ESetLit") (EVar "n")) (EApp (EApp (EMethodRef "map") (EApp (EVar "relocExpr") (EVar "o"))) (EVar "es"))))
(DFunDef false "relocExpr" ((PVar "o") (PCon "EAsPat" (PVar "n") (PVar "x"))) (EApp (EApp (EVar "EAsPat") (EVar "n")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "x"))))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "ELit" PWild))) (EVar "e"))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "EVar" PWild))) (EVar "e"))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "ESection" (PCon "SecBare" PWild)))) (EVar "e"))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "EMethodRef" PWild))) (EVar "e"))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "EDictApp" PWild))) (EVar "e"))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "EVarAt" PWild PWild))) (EVar "e"))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "EVarId" PWild PWild))) (EVar "e"))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "EMethodAt" PWild PWild PWild))) (EVar "e"))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "EDictAt" PWild PWild))) (EVar "e"))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "ENumLit" PWild PWild PWild))) (EVar "e"))
(DFunDef false "relocExpr" (PWild (PAs "e" (PCon "EWideLit" PWild PWild PWild PWild))) (EVar "e"))
(DTypeSig false "relocArm" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "Arm") (TyCon "Arm"))))
(DFunDef false "relocArm" ((PVar "o") (PCon "Arm" (PVar "p") (PVar "gs") (PVar "b"))) (EApp (EApp (EApp (EVar "Arm") (EApp (EApp (EVar "relocPat") (EVar "o")) (EVar "p"))) (EApp (EApp (EMethodRef "map") (EApp (EVar "relocGuard") (EVar "o"))) (EVar "gs"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "b"))))
(DTypeSig false "relocGuard" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "Guard") (TyCon "Guard"))))
(DFunDef false "relocGuard" ((PVar "o") (PCon "GBool" (PVar "e"))) (EApp (EVar "GBool") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))))
(DFunDef false "relocGuard" ((PVar "o") (PCon "GBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "GBind") (EApp (EApp (EVar "relocPat") (EVar "o")) (EVar "p"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))))
(DTypeSig false "relocGuardArm" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "GuardArm") (TyCon "GuardArm"))))
(DFunDef false "relocGuardArm" ((PVar "o") (PCon "GuardArm" (PVar "gs") (PVar "b"))) (EApp (EApp (EVar "GuardArm") (EApp (EApp (EMethodRef "map") (EApp (EVar "relocGuard") (EVar "o"))) (EVar "gs"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "b"))))
(DTypeSig false "relocStmt" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "DoStmt") (TyCon "DoStmt"))))
(DFunDef false "relocStmt" ((PVar "o") (PCon "DoExpr" (PVar "e"))) (EApp (EVar "DoExpr") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))))
(DFunDef false "relocStmt" ((PVar "o") (PCon "DoBind" (PVar "p") (PVar "e"))) (EApp (EApp (EVar "DoBind") (EApp (EApp (EVar "relocPat") (EVar "o")) (EVar "p"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))))
(DFunDef false "relocStmt" ((PVar "o") (PCon "DoLet" (PVar "m") (PVar "r") (PVar "p") (PVar "e") (PVar "site"))) (EApp (EApp (EApp (EApp (EApp (EVar "DoLet") (EVar "m")) (EVar "r")) (EApp (EApp (EVar "relocPat") (EVar "o")) (EVar "p"))) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))) (EVar "site")))
(DFunDef false "relocStmt" ((PVar "o") (PCon "DoAssign" (PVar "x") (PVar "e"))) (EApp (EApp (EVar "DoAssign") (EVar "x")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))))
(DFunDef false "relocStmt" ((PVar "o") (PCon "DoFieldAssign" (PVar "x") (PVar "fs") (PVar "e"))) (EApp (EApp (EApp (EVar "DoFieldAssign") (EVar "x")) (EVar "fs")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))))
(DTypeSig false "relocAssign" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "FieldAssign") (TyCon "FieldAssign"))))
(DFunDef false "relocAssign" ((PVar "o") (PCon "FieldAssign" (PVar "n") (PVar "v"))) (EApp (EApp (EVar "FieldAssign") (EVar "n")) (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "v"))))
(DTypeSig false "relocInterp" (TyFun (TyFun (TyCon "BinderId") (TyCon "BinderId")) (TyFun (TyCon "InterpPart") (TyCon "InterpPart"))))
(DFunDef false "relocInterp" ((PVar "o") (PCon "InterpExpr" (PVar "e"))) (EApp (EVar "InterpExpr") (EApp (EApp (EVar "relocExpr") (EVar "o")) (EVar "e"))))
(DFunDef false "relocInterp" (PWild (PAs "p" (PCon "InterpStr" PWild))) (EVar "p"))
(DData Public "BinderRun" () ((variant "BinderRun" (ConNamed (field "brFirst" (TyCon "Int")) (field "brCount" (TyCon "Int"))))) ())
(DImpl true "Eq" ((TyCon "BinderRun")) () ((im "eq" ((PVar "__x") (PVar "__y")) (EMatch (ETuple (EVar "__x") (EVar "__y")) (arm (PTuple (PRec "BinderRun" ((rf "brFirst" (PVar "__a0")) (rf "brCount" (PVar "__a1"))) false) (PRec "BinderRun" ((rf "brFirst" (PVar "__b0")) (rf "brCount" (PVar "__b1"))) false)) () (EBinOp "&&" (EApp (EApp (EMethodRef "eq") (EVar "__a0")) (EVar "__b0")) (EApp (EApp (EMethodRef "eq") (EVar "__a1")) (EVar "__b1"))))))))
(DImpl true "Debug" ((TyCon "BinderRun")) () ((im "debug" ((PVar "__x")) (EMatch (EVar "__x") (arm (PRec "BinderRun" ((rf "brFirst" (PVar "__a0")) (rf "brCount" (PVar "__a1"))) false) () (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (EBinOp "++" (ELit (LString "BinderRun {")) (ELit (LString " brFirst = "))) (EApp (EMethodRef "debug") (EVar "__a0"))) (ELit (LString ", brCount = "))) (EApp (EMethodRef "debug") (EVar "__a1"))) (ELit (LString " }"))))))))
(DTypeSig true "binderSpan" (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "BinderRun"))))
(DFunDef false "binderSpan" ((PVar "decls")) (EBlock (DoLet false false (PVar "lo") (EApp (EVar "Ref") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))) (DoLet false false (PVar "hi") (EApp (EVar "Ref") (EBinOp "-" (ELit (LInt 0)) (ELit (LInt 1))))) (DoLet false false (PVar "count") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "note") (ELam ((PVar "bid")) (EMatch (EVar "bid") (arm (PCon "BinderId" PWild (PVar "i")) ((GBool (EBinOp ">=" (EVar "i") (ELit (LInt 0))))) (EBlock (DoLet false false PWild (EIf (EBinOp "||" (EBinOp "<" (EFieldAccess (EVar "lo") "value") (ELit (LInt 0))) (EBinOp "<" (EVar "i") (EFieldAccess (EVar "lo") "value"))) (EApp (EApp (EVar "setRef") (EVar "lo")) (EVar "i")) (ELit LUnit))) (DoLet false false PWild (EIf (EBinOp ">" (EVar "i") (EFieldAccess (EVar "hi") "value")) (EApp (EApp (EVar "setRef") (EVar "hi")) (EVar "i")) (ELit LUnit))) (DoExpr (EApp (EApp (EVar "setRef") (EDictApp "count")) (EBinOp "+" (EFieldAccess (EDictApp "count") "value") (ELit (LInt 1))))) (DoExpr (EVar "bid")))) (arm PWild () (EVar "bid"))))) (DoLet false false PWild (EApp (EApp (EVar "mapBinders") (EVar "note")) (EVar "decls"))) (DoExpr (EIf (EBinOp "==" (EFieldAccess (EDictApp "count") "value") (ELit (LInt 0))) (EApp (EVar "Some") (ERecordCreate "BinderRun" ((fa "brFirst" (ELit (LInt 0))) (fa "brCount" (ELit (LInt 0)))))) (EIf (EBinOp "==" (EBinOp "+" (EBinOp "-" (EFieldAccess (EVar "hi") "value") (EFieldAccess (EVar "lo") "value")) (ELit (LInt 1))) (EFieldAccess (EDictApp "count") "value")) (EApp (EVar "Some") (ERecordCreate "BinderRun" ((fa "brFirst" (EFieldAccess (EVar "lo") "value")) (fa "brCount" (EFieldAccess (EDictApp "count") "value"))))) (EVar "None"))))))
(DTypeSig false "maxBinderRun" (TyCon "Int"))
(DFunDef false "maxBinderRun" () (ELit (LInt 4194304)))
(DTypeSig true "binderRunIs" (TyFun (TyCon "BinderRun") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyCon "Bool"))))
(DFunDef false "binderRunIs" ((PVar "run") (PVar "decls")) (EIf (EBinOp "||" (EBinOp "<" (EFieldAccess (EVar "run") "brCount") (ELit (LInt 0))) (EBinOp ">" (EFieldAccess (EVar "run") "brCount") (EVar "maxBinderRun"))) (EVar "False") (EIf (EVar "otherwise") (EBlock (DoLet false false (PVar "count") (EFieldAccess (EVar "run") "brCount")) (DoLet false false (PVar "base") (EFieldAccess (EVar "run") "brFirst")) (DoLet false false (PVar "seen") (EApp (EApp (EVar "arrayMake") (EDictApp "count")) (EVar "False"))) (DoLet false false (PVar "ok") (EApp (EVar "Ref") (EVar "True"))) (DoLet false false (PVar "taken") (EApp (EVar "Ref") (ELit (LInt 0)))) (DoLet false false (PVar "note") (ELam ((PVar "bid")) (EMatch (EVar "bid") (arm (PCon "BinderId" PWild (PVar "i")) ((GBool (EBinOp ">=" (EVar "i") (ELit (LInt 0))))) (EBlock (DoLet false false (PVar "j") (EBinOp "-" (EVar "i") (EVar "base"))) (DoLet false false PWild (EIf (EBinOp "||" (EBinOp "||" (EBinOp "<" (EVar "j") (ELit (LInt 0))) (EBinOp ">=" (EVar "j") (EDictApp "count"))) (EApp (EApp (EVar "arrayGetUnsafe") (EVar "j")) (EVar "seen"))) (EApp (EApp (EVar "setRef") (EVar "ok")) (EVar "False")) (EApp (EApp (EApp (EVar "arraySetUnsafe") (EVar "j")) (EVar "True")) (EVar "seen")))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "taken")) (EBinOp "+" (EFieldAccess (EVar "taken") "value") (ELit (LInt 1))))) (DoExpr (EVar "bid")))) (arm PWild () (EVar "bid"))))) (DoLet false false PWild (EApp (EApp (EVar "mapBinders") (EVar "note")) (EVar "decls"))) (DoExpr (EBinOp "&&" (EFieldAccess (EVar "ok") "value") (EBinOp "==" (EFieldAccess (EVar "taken") "value") (EDictApp "count"))))) (EApp (EVar "__fallthrough__") (ELit LUnit)))))
(DTypeSig true "relocDecls" (TyFun (TyCon "Int") (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "List") (TyCon "Decl")))))
(DFunDef false "relocDecls" ((PVar "offset") (PVar "decls")) (EApp (EApp (EVar "mapBinders") (EApp (EVar "relocId") (EVar "offset"))) (EVar "decls")))
(DTypeSig false "relocated" (TyFun (TyCon "Int") (TyFun (TyCon "PreludeElab") (TyCon "PreludeElab"))))
(DFunDef false "relocated" ((PVar "offset") (PVar "pe")) (EIf (EBinOp "==" (EVar "offset") (ELit (LInt 0))) (EVar "pe") (ERecordUpdate (EVar "pe") ((fa "peDecls" (EApp (EApp (EVar "mapBinders") (EApp (EVar "relocId") (EVar "offset"))) (EFieldAccess (EVar "pe") "peDecls"))) (fa "peBinders" (EApp (EApp (EMethodRef "map") (ELam ((PVar "row")) (ERecordUpdate (EVar "row") ((fa "brId" (EApp (EApp (EVar "relocId") (EVar "offset")) (EFieldAccess (EVar "row") "brId"))))))) (EFieldAccess (EVar "pe") "peBinders"))) (fa "peBinderBase" (EBinOp "+" (EFieldAccess (EVar "pe") "peBinderBase") (EVar "offset")))))))
(DTypeSig false "preludeElabCacheRef" (TyApp (TyCon "Ref") (TyApp (TyCon "Option") (TyTuple (TyTuple (TyCon "Int") (TyCon "Int")) (TyCon "PreludeElab") (TyCon "Bool")))))
(DFunDef false "preludeElabCacheRef" () (EApp (EVar "Ref") (EVar "None")))
(DTypeSig true "seedPreludeElab" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyCon "PreludeElab") (TyCon "Unit"))))
(DFunDef false "seedPreludeElab" ((PVar "generation") (PVar "pe")) (EMatch (EApp (EApp (EVar "evidenceRowsProblem") (EFieldAccess (EVar "pe") "peEvCounter")) (EFieldAccess (EVar "pe") "peEvidence")) (arm (PCon "Some" PWild) () (ELit LUnit)) (arm (PCon "None") () (EBlock (DoLet false false PWild (EApp (EApp (EVar "setPreludeEvidence") (EFieldAccess (EVar "pe") "peEvCounter")) (EFieldAccess (EVar "pe") "peEvidence"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "preludeElabCacheRef")) (EApp (EVar "Some") (ETuple (EVar "generation") (EVar "pe") (EVar "False")))))))))
(DTypeSig true "preludeElabHit" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyApp (TyCon "Option") (TyCon "PreludeElab"))))
(DFunDef false "preludeElabHit" ((PVar "generation")) (EMatch (EUnOp "!" (EVar "preludeElabCacheRef")) (arm (PCon "Some" (PTuple (PVar "seen") (PVar "pe") PWild)) ((GBool (EBinOp "==" (EVar "seen") (EVar "generation")))) (EApp (EVar "Some") (EVar "pe"))) (arm PWild () (EVar "None"))))
(DTypeSig true "preludeElabFor" (TyFun (TyTuple (TyCon "Int") (TyCon "Int")) (TyFun (TyApp (TyCon "List") (TyCon "Decl")) (TyApp (TyCon "Option") (TyCon "PreludeElab")))))
(DFunDef false "preludeElabFor" ((PVar "generation") (PVar "core")) (EMatch (EUnOp "!" (EVar "preludeElabCacheRef")) (arm (PCon "Some" (PTuple (PVar "seen") (PVar "pe") (PCon "True"))) ((GBool (EBinOp "==" (EVar "seen") (EVar "generation")))) (EApp (EVar "Some") (EVar "pe"))) (arm (PCon "Some" (PTuple (PVar "seen") (PVar "pe") (PCon "False"))) ((GBool (EBinOp "==" (EVar "seen") (EVar "generation")))) (EMatch (EApp (EVar "binderSpan") (EVar "core")) (arm (PCon "Some" (PVar "run")) ((GBool (EBinOp "==" (EFieldAccess (EVar "run") "brCount") (EFieldAccess (EVar "pe") "peBinderCount")))) (EBlock (DoLet false false (PVar "moved") (EApp (EApp (EVar "relocated") (EBinOp "-" (EFieldAccess (EVar "run") "brFirst") (EFieldAccess (EVar "pe") "peBinderBase"))) (EVar "pe"))) (DoExpr (EApp (EApp (EVar "setRef") (EVar "preludeElabCacheRef")) (EApp (EVar "Some") (ETuple (EVar "generation") (EVar "moved") (EVar "True"))))) (DoExpr (EApp (EVar "Some") (EVar "moved"))))) (arm PWild () (EVar "None")))) (arm PWild () (EVar "None"))))
(DTypeSig true "withShippedRows" (TyFun (TyApp (TyCon "Option") (TyCon "PreludeElab")) (TyFun (TyCon "EvTable") (TyFun (TyCon "BinderTypeTable") (TyTuple (TyCon "EvTable") (TyCon "BinderTypeTable"))))))
(DFunDef false "withShippedRows" ((PCon "None") (PVar "evidence") (PVar "binders")) (ETuple (EVar "evidence") (EVar "binders")))
(DFunDef false "withShippedRows" ((PCon "Some" (PVar "pe")) (PVar "evidence") (PVar "binders")) (ETuple (EBinOp "++" (EFieldAccess (EVar "pe") "peEvidence") (EVar "evidence")) (EApp (EApp (EApp (EMethodRef "fold") (ELam ((PVar "acc") (PVar "row")) (EApp (EApp (EVar "addBinderRow") (EVar "row")) (EVar "acc")))) (EVar "binders")) (EFieldAccess (EVar "pe") "peBinders"))))
(DTypeSig true "heldPreludeEvCounter" (TyFun (TyCon "Unit") (TyApp (TyCon "Option") (TyCon "Int"))))
(DFunDef false "heldPreludeEvCounter" (PWild) (EApp (EApp (EMethodRef "map") (ELam ((PTuple PWild (PVar "pe") PWild)) (EFieldAccess (EVar "pe") "peEvCounter"))) (EUnOp "!" (EVar "preludeElabCacheRef"))))
